#if DEBUG
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Testing
import UIKit
import PantrifiedApplication
import PantrifiedDomain
import PantrifiedPersistence
@testable import Pantrified

/// A Pantry on a throwaway local store, and batch intake over a throwaway staging folder, the way
/// the app builds them at launch.
@MainActor
private struct Harness {
    let root: URL
    let pantry: Pantry
    let intake: IntakeServices
    let space: SpaceID

    init(recognizer: any PhotoRecognizer = ScreenshotScenario.NoRecognizer()) async throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        root = support.appendingPathComponent("BatchIntakeAppTests", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        let files = StoreFiles(directory: root)
        let store = try LocalPersistence.open(files)
        space = try LocalSpace.id(in: files)
        let replica = try store.replica(for: space, transport: OfflineTransport(), time: SystemTime())
        pantry = Pantry(
            space: space, inventory: replica, locations: store.locations, evidence: store.productEvidence,
            guidance: NoGuidance(), time: SystemTime()
        )
        try await pantry.prepare()
        intake = IntakeServices(
            pantry: pantry, files: StagingDirectory(directory: root.appendingPathComponent("Intake", isDirectory: true)),
            lookup: nil, recognizer: recognizer
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite("Batch intake in the app")
@MainActor
struct BatchIntakeAppTests {
    @Test("the camera usage description says when photos are deleted and that they are never saved to the photo library")
    func usageDescription() {
        let text = Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String ?? ""
        #expect(text.contains("scan barcodes"))
        #expect(text.contains("3 days after you last used an unfinished one"))
        #expect(text.contains("never saved to your photo library"))
        #expect(IntakeText.photosStayHere.contains("3 days after you last use it"))
        #expect(IntakeText.photosStayHere.contains("never saved to your photo library"))
    }

    @Test("the damaged batch notice says its photos are kept for a day before they are deleted")
    func damagedBatchNotice() {
        #expect(IntakeText.damagedBatch.hasSuffix("Its photos are kept for a day, then deleted."))
    }

    @Test("the review screenshot opens batch intake over Today, and no other screen does")
    func screenshotScreen() {
        func start(_ screen: String) -> StartScreen? {
            ScreenshotScenario(arguments: ["Pantrified", "-pantrified-scenario", "sample", "-pantrified-screen", screen])?.startScreen
        }
        #expect(start("review")?.batchIntake == true)
        #expect(start("review")?.tab == .today)
        #expect(start("review")?.scanning == false)
        for screen in ["today", "food", "add", "scan"] {
            #expect(start(screen)?.batchIntake == false)
        }
        #expect(StartScreen().batchIntake == false)
    }

    @Test("the review sample makes each kind of candidate, and adding and undoing work on the real store")
    func reviewSample() async throws {
        let harness = try await Harness()
        defer { harness.remove() }
        let scenario = try #require(ScreenshotScenario(arguments: ["Pantrified", "-pantrified-scenario", "sample", "-pantrified-screen", "review"]))
        let locations = try await harness.pantry.snapshot().locations
        try await scenario.seedBatch(harness.intake, locations: locations)

        let batch = try #require(await harness.intake.store.unfinished(in: harness.space))
        let review = try #require(batch.review)
        let summaries = review.summaries
        #expect(summaries.count == 7)
        #expect(summaries[0].name == "Chobani greek yogurt")
        #expect(summaries[0].photos.count == 2)
        #expect(summaries[0].date?.label == .useBy)
        #expect(summaries[1].notes.contains(.mightBeSameAs([summaries[2].id])))
        #expect(summaries[3].pendingDate != nil)
        let freezer = locations.first(where: { $0.storageType == .frozen })?.id
        #expect(summaries[4].location == freezer)
        #expect(summaries[5].nameOrigin == .lookup(source: "USDA FoodData Central"))
        #expect(summaries[6].notes.contains(.noName))

        // Staged files are protected and kept out of backups.
        let photo = try #require(batch.photos.first)
        let url = try #require(await harness.intake.store.url(of: photo.id, in: batch.id))
        let values = try url.resourceValues(forKeys: [.fileProtectionKey, .isExcludedFromBackupKey])
        #expect(values.fileProtection == .completeUntilFirstUserAuthentication)
        #expect(values.isExcludedFromBackup == true)

        let addition = try await harness.intake.adding.add(review.readyToAdd, in: batch.id)
        #expect(addition.packages.count == 6)
        #expect(try await harness.pantry.snapshot().entries.count == 6)
        try await harness.intake.adding.undo(addition)
        #expect(try await harness.pantry.snapshot().entries.isEmpty)
    }

    @Test("the Vision recognizer reads a label's text and a QR code's GS1 Digital Link from a still")
    func visionReadsAStill() async throws {
        let harness = try await Harness()
        defer { harness.remove() }
        let file = harness.root.appendingPathComponent("still.png")
        try FileManager.default.createDirectory(at: harness.root, withIntermediateDirectories: true)
        try Self.drawnLabel(text: "BAKING SODA", qr: "https://id.gs1.org/01/09506000134352").write(to: file)

        let reading = try await VisionPhotoRecognizer().read(file)
        let readsName = reading.lines.contains { $0.text.uppercased().contains("BAKING") }
        #expect(readsName)
        let gtin = GTIN("09506000134352")!
        // Whatever is read is never anything but this product.
        #expect(reading.codes.allSatisfy { $0 == .product(gtin) })
        // In the CI simulator Vision found no code and logged a model load failure, so nothing may
        // be found there. On a device this is expected to pass.
        withKnownIssue("Vision barcode detection does not run in the simulator", isIntermittent: true) {
            #expect(reading.codes.contains(.product(gtin)))
        }
        #expect(reading.lines.allSatisfy { $0.box.y >= 0 && $0.box.y <= 1 })
    }

    @Test("a QR code with any other link is noted as a link and nothing else")
    func visionNotesOtherLinks() async throws {
        let harness = try await Harness()
        defer { harness.remove() }
        let file = harness.root.appendingPathComponent("link.png")
        try FileManager.default.createDirectory(at: harness.root, withIntermediateDirectories: true)
        try Self.drawnLabel(text: "RICE", qr: "https://example.com/promo?id=01").write(to: file)

        let reading = try await VisionPhotoRecognizer().read(file)
        #expect(reading.codes.allSatisfy { $0 == .link })
        withKnownIssue("Vision barcode detection does not run in the simulator", isIntermittent: true) {
            #expect(reading.codes == [.link])
        }
    }

    @Test("photo bytes are recognized by their content, and a digest identifies a duplicate")
    func photoFormat() throws {
        let png = try Self.drawnLabel(text: "A", qr: nil)
        #expect(PhotoFormat.fileExtension(of: png) == "png")
        #expect(PhotoFormat.fileExtension(of: Data([0xFF, 0xD8, 0xFF, 0xE0])) == "jpg")
        #expect(PhotoFormat.digest(of: png) == PhotoFormat.digest(of: png))
        #expect(PhotoFormat.digest(of: png).count == 64)
        #expect(PhotoFormat.thumbnail(of: png) != nil)
    }

    @Test("a picked photo's copy keeps its image and none of its file's metadata")
    func withoutLocation() throws {
        let png = try Self.drawnLabel(text: "A", qr: nil)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let tagged = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(tagged, "public.jpeg" as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 47.6, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:30 18:05:00"],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let original = tagged as Data
        #expect(PhotoFormat.hasLocation(original))
        #expect(PhotoFormat.takenAt(original) != nil)

        let copy = try #require(PhotoFormat.withoutLocation(original))
        #expect(!PhotoFormat.hasLocation(copy))
        #expect(PhotoFormat.takenAt(copy) == nil)
        #expect(PhotoFormat.fileExtension(of: copy) == "jpg")
        let copied = try #require(CGImageSourceCreateWithData(copy as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(copied.width == image.width && copied.height == image.height)
        #expect(PhotoFormat.withoutLocation(Data("not an image".utf8)) == nil)
    }

    @Test("the review's wording names where each proposal came from")
    func wording() {
        #expect(IntakeText.nameOrigin(.label) == "Read from the label. Check it.")
        #expect(IntakeText.nameOrigin(.lookup(source: "USDA FoodData Central")) == "From USDA FoodData Central")
        #expect(IntakeText.nameOrigin(.person) == nil)
        #expect(IntakeText.addAll(1) == "Add 1 food")
        #expect(IntakeText.addAll(4) == "Add all 4")
        #expect(IntakeText.note(.linkSeen, name: { _ in nil }) == "A QR code with a link was seen. It wasn't opened.")
        #expect(IntakeText.signals([.sameBarcode, .takenRightAfter]) == "Grouped by the same barcode and taken one after another.")
        #expect(IntakeText.signals([.differentLabelWords]) == nil)
    }

    /// Black text on white with an optional QR code under it, as PNG bytes.
    static func drawnLabel(text: String, qr: String?) throws -> Data {
        let size = CGSize(width: 1200, height: 1200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        var code: CGImage?
        if let qr {
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(qr.utf8)
            filter.correctionLevel = "M"
            let scaled = try #require(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 16, y: 16))
            code = CIContext().createCGImage(scaled, from: scaled.extent)
        }
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 120, weight: .bold),
                .foregroundColor: UIColor.black,
            ]
            (text as NSString).draw(at: CGPoint(x: 60, y: 60), withAttributes: attributes)
            if let code {
                UIImage(cgImage: code).draw(in: CGRect(x: 300, y: 400, width: 600, height: 600))
            }
        }
        return try #require(image.pngData())
    }
}
#endif
