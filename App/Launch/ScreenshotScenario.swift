#if DEBUG
import Foundation
import UIKit
import PantrifiedApplication
import PantrifiedDomain
import PantrifiedPersistence

/// A Debug build started with `-pantrified-scenario sample` runs on a throwaway store that holds
/// sample food, and `-pantrified-screen today|food|add|scan|review` picks the screen it opens on. A CI job
/// uses it to take screenshots of the screens. It is compiled out of Release builds.
struct ScreenshotScenario {
    enum Screen: String {
        case today, food, add, scan, review
    }

    let screen: Screen

    static let current = ScreenshotScenario()

    init?(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard Self.value(after: "-pantrified-scenario", in: arguments) == "sample" else { return nil }
        screen = Self.value(after: "-pantrified-screen", in: arguments).flatMap(Screen.init(rawValue:)) ?? .today
    }

    var startScreen: StartScreen {
        switch screen {
        case .today: StartScreen(tab: .today, addingFood: false, showsEvaluation: false, focusesName: false)
        case .food: StartScreen(tab: .food, addingFood: false, showsEvaluation: false, focusesName: false)
        case .add: StartScreen(tab: .today, addingFood: true, showsEvaluation: false, focusesName: false, fillsAddFoodExample: true)
        case .scan: StartScreen(tab: .today, scanning: true, showsEvaluation: false, focusesName: false)
        case .review: StartScreen(tab: .today, batchIntake: true, showsEvaluation: false, focusesName: false)
        }
    }

    /// An empty directory of its own, so the sample never mixes with a person's data. Earlier
    /// sample directories are removed first.
    func freshFiles() throws -> StoreFiles {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = support.appendingPathComponent("ScreenshotScenario", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        return StoreFiles(directory: root.appendingPathComponent(UUID().uuidString, isDirectory: true))
    }

    /// One food to add, in the location at `place` (0 Fridge, 1 Freezer, 2 Pantry).
    struct Sample: Equatable {
        let name: String
        let place: Int
        var quantity: Quantity = .unknown
        var date: (label: PrintedDateLabel, daysFromNow: Int)?

        static func == (a: Sample, b: Sample) -> Bool {
            a.name == b.name && a.place == b.place && a.quantity == b.quantity
                && a.date?.label == b.date?.label && a.date?.daysFromNow == b.date?.daysFromNow
        }
    }

    /// Enough variety to show every state: past guidance, use soon from a printed date, use soon
    /// from sourced guidance with no date, fine, and unknown, with one long name to test wrapping.
    static let samples: [Sample] = [
        Sample(name: "Chicken thighs", place: 0, date: (.useBy, -1)),
        Sample(name: "Spinach", place: 0, quantity: .aboutHalf, date: (.useBy, 2)),
        Sample(name: "Asparagus", place: 0),
        Sample(name: "Organic whole milk Greek yogurt with honey and vanilla, family size", place: 0, quantity: .full, date: (.bestBy, 12)),
        Sample(name: "Eggs", place: 0, quantity: .aboutHalf),
        Sample(name: "Frozen peas", place: 1, quantity: .full),
        Sample(name: "Rice", place: 2, quantity: .aboutHalf),
        Sample(name: "Canned tomatoes", place: 2, date: (.bestBy, 400)),
    ]

    func seed(_ pantry: Pantry, now: Date = Date()) async throws {
        let locations = try await pantry.snapshot().locations
        for sample in Self.samples where sample.place < locations.count {
            try await pantry.add(NewFood(
                name: sample.name,
                location: locations[sample.place].id,
                quantity: sample.quantity,
                printedDate: sample.date.flatMap { Self.printedDate($0.label, daysFromNow: $0.daysFromNow, now: now) }
            ))
        }
    }

    static func printedDate(_ label: PrintedDateLabel, daysFromNow days: Int, now: Date) -> PrintedDate? {
        let day = Calendar.current.date(byAdding: .day, value: days, to: now) ?? now
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
        return PrintedDate.onDay(label, year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }

    // MARK: Batch review

    /// Never called: the batch it seeds is already read. A simulator has no camera, so the
    /// screenshots show synthetic readings over placeholder photos.
    struct NoRecognizer: PhotoRecognizer {
        func read(_ file: URL) async throws -> PhotoReading { PhotoReading() }
    }

    /// One synthetic photo: what it would have read, and how long after the last photo it was taken.
    struct SamplePhoto {
        var lines: [(text: String, row: Double, size: Double)] = []
        var codes: [CodeMeaning] = []
        var secondsAfterLast: Double = 5
    }

    static let yogurt = GTIN("4006381333931")!
    static let beans = GTIN("036000291452")!

    /// A batch that shows each kind of candidate: a front, back and barcode grouped with a date read
    /// from the label, two near-identical products kept apart and flagged, a date that reads two
    /// ways, a place read from "Keep frozen", a name from the barcode lookup, and a photo with no name.
    static func samplePhotos(now: Date) -> [SamplePhoto] {
        let useBy = Calendar.current.date(byAdding: .day, value: 12, to: now) ?? now
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: useBy)
        // Year first, so the sample's use-by date reads only one way.
        let printed = String(format: "USE BY %04d-%02d-%02d", parts.year ?? 2027, parts.month ?? 1, parts.day ?? 1)
        let nextYear = (Calendar.current.component(.year, from: now) + 1) % 100
        return [
            SamplePhoto(lines: [("CHOBANI", 0.08, 0.09), ("GREEK YOGURT", 0.2, 0.1), ("Plain nonfat", 0.6, 0.03)], secondsAfterLast: 0),
            SamplePhoto(lines: [("Chobani greek yogurt", 0.1, 0.03), ("Plain nonfat", 0.2, 0.03), (printed, 0.8, 0.02)], codes: [.product(yogurt)]),
            SamplePhoto(lines: [("ARM & HAMMER", 0.08, 0.09), ("BAKING SODA", 0.2, 0.1)], secondsAfterLast: 40),
            SamplePhoto(lines: [("CLABBER GIRL", 0.08, 0.09), ("BAKING POWDER", 0.2, 0.1)], secondsAfterLast: 12),
            SamplePhoto(lines: [("Basmati rice", 0.2, 0.1), (String(format: "BEST BEFORE 05/06/%02d", nextYear), 0.85, 0.02)], secondsAfterLast: 40),
            SamplePhoto(lines: [("Birds Eye", 0.08, 0.08), ("Sweet peas", 0.2, 0.1), ("KEEP FROZEN", 0.9, 0.02)], secondsAfterLast: 40),
            SamplePhoto(lines: [("Ingredients: black beans, water, salt", 0.5, 0.02)], codes: [.product(beans)], secondsAfterLast: 40),
            SamplePhoto(secondsAfterLast: 40),
        ]
    }

    /// Seeds an already-read batch for the review screenshot. Other screens get no batch.
    func seedBatch(_ intake: IntakeServices, locations: [StorageLocation], now: Date = Date()) async throws {
        guard screen == .review else { return }
        let batch = try await intake.store.open(in: intake.space)
        var time = now.addingTimeInterval(-600)
        for (index, sample) in Self.samplePhotos(now: now).enumerated() {
            time = time.addingTimeInterval(sample.secondsAfterLast)
            let photo = try await intake.store.stage(Self.placeholder(index), fileExtension: "png", source: .camera, capturedAt: time, in: batch.id)
            let lines = sample.lines.compactMap { line in
                RecognizedTextLine(text: line.text, box: NormalizedBox(x: 0.1, y: line.row, width: 0.7, height: line.size), confidence: 0.9)
            }
            try await intake.store.record(PhotoObservation(
                photo: photo.id, sequence: photo.sequence, capturedAt: time, lines: lines, codes: sample.codes
            ), in: batch.id)
        }
        _ = try await intake.pipeline.process(batch.id, locations: locations, defaultLocation: locations.first?.id)
        try await intake.store.updateReview(batch.id) {
            $0.record(.found(rawName: "Black beans", source: "USDA FoodData Central"), for: Self.beans)
        }
    }

    /// A plain tinted square standing in for a photo.
    static func placeholder(_ index: Int) -> Data {
        let colors: [UIColor] = [.systemTeal, .systemTeal, .systemOrange, .systemRed, .systemYellow, .systemGreen, .systemBrown, .systemGray]
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 240))
        return renderer.pngData { context in
            colors[index % colors.count].withAlphaComponent(0.55).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
#endif
