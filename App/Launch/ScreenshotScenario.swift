#if DEBUG
import Foundation
import PantrifiedApplication
import PantrifiedDomain
import PantrifiedPersistence

/// A Debug build started with `-pantrified-scenario sample` runs on a throwaway store that holds
/// sample food, and `-pantrified-screen today|food|add` picks the screen it opens on. A CI job
/// uses it to take screenshots of the screens. It is compiled out of Release builds.
struct ScreenshotScenario {
    enum Screen: String {
        case today, food, add
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

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
#endif
