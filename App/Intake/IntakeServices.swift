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

    init(
        pantry: Pantry,
        files: any StagingFiles,
        lookup: (any ProductLookupService)?,
        recognizer: any PhotoRecognizer = VisionPhotoRecognizer(),
        time: any TimeSource = SystemTime()
    ) {
        space = pantry.space
        store = StagingStore(files: files, time: time)
        pipeline = IntakePipeline(store: store, recognizer: recognizer, lookup: lookup)
        adding = IntakeAdding(pantry: pantry, store: store)
        looksUp = lookup != nil
    }

    /// At launch: deletes what is due, finishes an add or undo a crash cut off, and carries on
    /// reading a batch that was being read. Failures wait for the next launch or for the person
    /// opening the batch; nothing here blocks the app.
    func resume(locations: [StorageLocation]) async {
        _ = try? await store.sweep()
        guard let batch = await store.unfinished(in: space) else { return }
        switch batch.phase {
        case .processing:
            _ = try? await pipeline.process(batch.id, locations: locations, defaultLocation: locations.first?.id)
            await pipeline.lookUpNames(batch.id)
        case .reviewing:
            try? await adding.resume(batch.id)
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
