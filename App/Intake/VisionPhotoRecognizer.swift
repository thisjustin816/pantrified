import CoreGraphics
import Foundation
import ImageIO
import Vision
import PantrifiedApplication
import PantrifiedDomain

/// Reads one staged photo with Vision, on the device, in one pass: its text (with the same request
/// as `TextRecognizer`), its product barcodes and QR codes, and an image feature print for telling
/// photos of the same package apart. Nothing is written, logged or sent, and a link in a QR code is
/// only classified, never opened. The work runs off the main thread.
struct VisionPhotoRecognizer: PhotoRecognizer {
    struct Unreadable: Error {}

    /// The longest side the photo is scaled to before reading. Large enough for small date print,
    /// small enough to keep two reads at once well inside memory.
    static let maximumPixels = 3_000

    func read(_ file: URL) async throws -> PhotoReading {
        try Task.checkCancellation()
        return try await Task.detached(priority: .utility) { try Self.readNow(file) }.value
    }

    static func readNow(_ file: URL) throws -> PhotoReading {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { throw Unreadable() }
        // The thumbnail applies the photo's orientation, so Vision reads it upright.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw Unreadable() }

        let text = TextRecognizer.makeRequest()
        let codes = VNDetectBarcodesRequest()
        codes.symbologies = [.ean13, .ean8, .upce, .qr]
        let print = VNGenerateImageFeaturePrintRequest()
        // Fixed, so distances keep the scale GroupingPolicy's thresholds assume.
        print.revision = VNGenerateImageFeaturePrintRequestRevision2
        print.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([text, codes])
        // Grouping works without a feature print, so a failure here loses only that signal.
        let featurePrint = (try? handler.perform([print])) == nil ? nil : print.results?.first.flatMap(values)

        var lines: [RecognizedTextLine] = []
        for observation in text.results ?? [] {
            guard lines.count < IntakeLimits.linesPerPhoto else { break }
            guard let candidate = observation.topCandidates(1).first else { continue }
            // Vision's origin is the bottom left; observations use the top left.
            let box = observation.boundingBox
            let normalized = NormalizedBox(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            if let line = RecognizedTextLine(text: candidate.string, box: normalized, confidence: Double(candidate.confidence)) {
                lines.append(line)
            }
        }

        let meanings = (codes.results ?? []).prefix(IntakeLimits.codesPerPhoto).compactMap { observation -> CodeMeaning? in
            guard let payload = observation.payloadStringValue, let symbology = symbology(observation.symbology) else { return nil }
            return CodeMeaning.classify(payload: payload, symbology: symbology)
        }

        return PhotoReading(lines: lines, codes: meanings, featurePrint: featurePrint)
    }

    /// Vision reports UPC-A as EAN-13 with a leading zero; GTIN normalization makes both one product.
    private static func symbology(_ symbology: VNBarcodeSymbology) -> CodeSymbology? {
        switch symbology {
        case .ean13: .ean13
        case .ean8: .ean8
        case .upce: .upcE
        case .qr: .qr
        default: nil
        }
    }

    /// The feature print's vector, copied out of Vision's buffer.
    private static func values(_ observation: VNFeaturePrintObservation) -> FeaturePrint? {
        let count = observation.elementCount
        guard count > 0, count <= IntakeLimits.featurePrintValues else { return nil }
        switch observation.elementType {
        case .float:
            var values = [Float](repeating: 0, count: count)
            let copied = values.withUnsafeMutableBytes { observation.data.copyBytes(to: $0) }
            return copied == count * MemoryLayout<Float>.size ? FeaturePrint(values) : nil
        case .double:
            var values = [Double](repeating: 0, count: count)
            let copied = values.withUnsafeMutableBytes { observation.data.copyBytes(to: $0) }
            return copied == count * MemoryLayout<Double>.size ? FeaturePrint(values.map(Float.init)) : nil
        default:
            return nil
        }
    }
}
