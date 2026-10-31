import CoreGraphics
import CoreVideo
import ImageIO
import Vision
import PantrifiedDomain

/// Reads the printed text in one still image with Vision, on the device. The image belongs to the
/// caller: no reference to it, the request or its results outlives the call, and nothing is
/// written, logged or sent. Only the recognized lines come back, bounded as they are taken from
/// Vision's results (`RecognizedText`). The call blocks while Vision works, so make it off the main
/// thread.
///
/// Nothing calls this yet; a photo capture flow will, once one is built.
enum TextRecognizer {
    static func text(in image: CGImage, orientation: CGImagePropertyOrientation = .up) throws -> RecognizedText {
        try recognize(with: VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:]))
    }

    static func text(in pixels: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up) throws -> RecognizedText {
        try recognize(with: VNImageRequestHandler(cvPixelBuffer: pixels, orientation: orientation, options: [:]))
    }

    /// Accurate recognition reads the small and dot-matrix print dates use, which fast recognition
    /// often misses. Language correction is off because it turns codes such as "5DEC26" into words.
    private static func recognize(with handler: VNImageRequestHandler) throws -> RecognizedText {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = false
        request.recognitionLanguages = ["en-US"]
        try handler.perform([request])
        var text = RecognizedText()
        for observation in request.results ?? [] {
            guard let line = observation.topCandidates(1).first?.string else { continue }
            guard text.add(line) else { break }
        }
        return text
    }
}
