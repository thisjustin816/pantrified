import CryptoKit
import Foundation
import ImageIO
import UIKit
import PantrifiedApplication
import PantrifiedDomain
import PantrifiedPersistence

/// Batch intake's parts for one Space, built once at launch.
struct IntakeServices: Sendable {
    let space: SpaceID
    let store: StagingStore
    let pipeline: IntakePipeline
    let adding: IntakeAdding
    let looksUp: Bool
    #if DEBUG
    /// Times each photo read, for the batch screen's timing line in Debug builds.
    let readTimer: ReadTimer
    #endif

    init(
        pantry: Pantry,
        files: any StagingFiles,
        lookup: (any ProductLookupService)?,
        recognizer: any PhotoRecognizer = VisionPhotoRecognizer(),
        time: any TimeSource = SystemTime()
    ) {
        space = pantry.space
        store = StagingStore(files: files, time: time)
        #if DEBUG
        let timer = ReadTimer()
        readTimer = timer
        let reader: any PhotoRecognizer = TimedRecognizer(inner: recognizer, timer: timer)
        #else
        let reader = recognizer
        #endif
        pipeline = IntakePipeline(store: store, recognizer: reader, lookup: lookup, time: time)
        adding = IntakeAdding(pantry: pantry, store: store)
        looksUp = lookup != nil
    }

    /// At launch: deletes what is due, finishes every add or undo a crash cut off, in finished
    /// batches too, and carries on reading a batch that was being read after Done. A batch still in
    /// the camera is read when it opens. Failures wait for the next launch or for the person opening
    /// the batch; nothing here blocks the app. The pipeline is shared with the batch screen, so a
    /// batch is never read by two runs at once.
    func resume(locations: [StorageLocation]) async {
        _ = try? await store.sweep()
        await adding.resumeAll()
        guard let batch = await store.unfinished(in: space) else { return }
        switch batch.phase {
        case .processing:
            _ = try? await pipeline.process(batch.id, locations: locations, defaultLocation: locations.first?.id)
            await pipeline.lookUpNames(batch.id)
        case .reviewing:
            await pipeline.lookUpNames(batch.id)
        case .capturing, .finished:
            break
        }
    }
}

/// What the app needs to know about a photo's bytes. Reads only the image data itself, never the
/// file's dates.
enum PhotoFormat {
    /// jpg, heic or png, from the bytes rather than a name the picker supplied.
    static func fileExtension(of data: Data) -> String {
        let head = [UInt8](data.prefix(12))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if head.count >= 12, head[4...7].elementsEqual(Array("ftyp".utf8)) { return "heic" }
        return "jpg"
    }

    /// A SHA-256 of the bytes, so the same photo imported twice is recognized.
    static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// When the photo was taken, from its EXIF data, for a photo imported from the library.
    static func takenAt(_ data: Data) -> Date? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }

    /// The longest side of a picked photo's copy. Above what reading uses
    /// (`VisionPhotoRecognizer.maximumPixels`), so nothing it reads is lost.
    static let copyPixels = 4_032

    /// A copy of a picked photo with none of its file's metadata: no location, camera or times. The
    /// image is drawn upright, at most `copyPixels` on its longest side, and written as JPEG, so
    /// every format the picker gives is handled the same way. Nil when the bytes are not an image.
    static func withoutLocation(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: copyPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let written = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(written, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? written as Data : nil
    }

    /// Whether the image's properties hold a location.
    static func hasLocation(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        return properties[kCGImagePropertyGPSDictionary] != nil
    }

    /// A small, upright copy for the screen. Made in memory and never written anywhere.
    static func thumbnail(_ source: CGImageSource?, pixels: Int) -> UIImage? {
        guard let source else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }

    static func thumbnail(at url: URL, pixels: Int = 240) -> UIImage? {
        thumbnail(CGImageSourceCreateWithURL(url as CFURL, nil), pixels: pixels)
    }

    static func thumbnail(of data: Data, pixels: Int = 240) -> UIImage? {
        thumbnail(CGImageSourceCreateWithData(data as CFData, nil), pixels: pixels)
    }
}
