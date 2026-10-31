import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain
@testable import Pantrified

@Suite("Package detail text")
struct PackageDetailTextTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(
        quantity: Quantity = .full, location: String? = "Fridge", printed: PrintedDate? = nil
    ) -> PantryEntry {
        let package = Package(
            spaceID: SpaceID(), name: "Milk", location: LocationID(), quantity: quantity,
            printedDate: printed, addedAt: now
        )
        let assessment = AttentionPolicy().assess(package, storageType: .refrigerated, guidance: nil, now: now)
        return PantryEntry(package: package, locationName: location, assessment: assessment)
    }

    private func rows(_ entry: PantryEntry) -> [String: String] {
        Dictionary(uniqueKeysWithValues: PackageDetailText.rows(for: entry, moment: { "at \($0.timeIntervalSince1970)" })
            .map { ($0.label, $0.value) })
    }

    @Test("a food with nothing recorded still says where it is, how much, its date and when it was added")
    func everyFoodHasTheBasics() {
        let shown = rows(entry(quantity: .unknown, location: nil))

        #expect(shown["Where"] == "Somewhere else")
        #expect(shown["How much"] == "Not sure")
        #expect(shown["Date on the package"] == "None")
        #expect(shown["Added"] == "at 1800000000.0")
        #expect(shown.count == 4)
    }

    @Test("the printed date keeps its label and the day it names")
    func printedDate() throws {
        let date = try #require(PrintedDate.onDay(.useBy, year: 2027, month: 3, day: 9))

        let shown = try #require(rows(entry(printed: date))["Date on the package"])
        #expect(shown == "Use by \(AttentionText.day(date.date))")
        #expect(shown.contains("9"))
    }

    @Test("opened, frozen and thawed rows appear only once they have happened")
    func lifecycleRows() throws {
        var package = Package(spaceID: SpaceID(), name: "Peas", location: LocationID(), addedAt: now)
        try package.record(.opened, at: now.addingTimeInterval(60))
        try package.record(.frozen, at: now.addingTimeInterval(120))
        let assessment = AttentionPolicy().assess(package, storageType: .frozen, guidance: nil, now: now)
        let shown = rows(PantryEntry(package: package, locationName: "Freezer", assessment: assessment))

        #expect(shown["Opened"] == "at 1800000060.0")
        #expect(shown["Frozen"] == "at 1800000120.0")
        #expect(shown["Thawed"] == nil)
    }

    // MARK: Storage guidance

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private let mayonnaise = StorageGuidance(
        provenance: GuidanceProvenance(source: "USDA FoodKeeper", version: "test"),
        windows: [
            GuidanceWindow(storageType: .refrigerated, anchor: .opened, days: 60),
            GuidanceWindow(storageType: .roomTemperature, anchor: .added, days: 90),
        ]
    )

    private func guidanceEntry(opened: Bool, guidance: StorageGuidance?, storage: StorageType = .refrigerated) throws -> PantryEntry {
        var package = Package(spaceID: SpaceID(), name: "Mayonnaise", location: LocationID(), addedAt: now)
        if opened { try package.record(.opened, at: now) }
        let assessment = AttentionPolicy(calendar: Self.utc).assess(package, storageType: storage, guidance: guidance, now: now)
        return PantryEntry(package: package, locationName: "Fridge", assessment: assessment, guidance: guidance)
    }

    private func guidanceRows(_ entry: PantryEntry, storage: StorageType?) -> [String]? {
        PackageDetailText.guidance(for: entry, storageType: storage, calendar: Self.utc, day: { "on \($0.timeIntervalSince1970)" })
            .map { $0.rows.map { "\($0.label): \($0.value)" } }
    }

    @Test("an opened food shows the opening window for where it is, and the day that window runs to")
    func openedFood() throws {
        let entry = try guidanceEntry(opened: true, guidance: mayonnaise)
        let end = try #require(Self.utc.date(byAdding: .day, value: 60, to: now))

        #expect(guidanceRows(entry, storage: .refrigerated) == [
            "After opening: About 60 days, about 2 months",
            "Guidance runs to: on \(end.timeIntervalSince1970)",
        ])
        #expect(PackageDetailText.guidance(for: entry, storageType: .refrigerated)?.source == "USDA FoodKeeper")
    }

    @Test("a food that is not open yet shows how long it keeps once opened, with no end day")
    func unopenedFood() throws {
        let entry = try guidanceEntry(opened: false, guidance: mayonnaise)

        #expect(guidanceRows(entry, storage: .refrigerated) == ["After opening: About 60 days, about 2 months"])
    }

    @Test("only the windows for the storage the food is in are shown")
    func onlyThisStorage() throws {
        let entry = try guidanceEntry(opened: false, guidance: mayonnaise, storage: .roomTemperature)

        #expect(guidanceRows(entry, storage: .roomTemperature) == ["Unopened: About 90 days, about 3 months"])
        #expect(guidanceRows(entry, storage: .frozen) == nil)
    }

    @Test("nothing is shown without matched guidance or without a known storage")
    func noGuidance() throws {
        #expect(guidanceRows(try guidanceEntry(opened: true, guidance: nil), storage: .refrigerated) == nil)
        #expect(guidanceRows(try guidanceEntry(opened: true, guidance: mayonnaise), storage: nil) == nil)
    }

    @Test("when the source gives two windows for the same start, the shorter is shown")
    func shorterWins() throws {
        let guidance = StorageGuidance(
            provenance: GuidanceProvenance(source: "USDA FoodKeeper", version: "test"),
            windows: [
                GuidanceWindow(storageType: .refrigerated, anchor: .added, days: 7),
                GuidanceWindow(storageType: .refrigerated, anchor: .added, days: 3),
            ]
        )

        #expect(guidanceRows(try guidanceEntry(opened: false, guidance: guidance), storage: .refrigerated) == ["Unopened: About 3 days"])
    }

    @Test("windows are listed opened, unopened, thawed, whatever order the source gives them")
    func order() throws {
        let guidance = StorageGuidance(
            provenance: GuidanceProvenance(source: "USDA FoodKeeper", version: "test"),
            windows: [
                GuidanceWindow(storageType: .frozen, anchor: .thawed, days: 2),
                GuidanceWindow(storageType: .frozen, anchor: .added, days: 240),
                GuidanceWindow(storageType: .frozen, anchor: .opened, days: 30),
            ]
        )

        #expect(guidanceRows(try guidanceEntry(opened: false, guidance: guidance, storage: .frozen), storage: .frozen) == [
            "After opening: About 30 days",
            "Unopened: About 240 days, about 8 months",
            "After thawing: About 2 days",
        ])
    }

    @Test("a length of time is given in days first, then months or years when long")
    func durations() {
        #expect(PackageDetailText.duration(1) == "About 1 day")
        #expect(PackageDetailText.duration(3) == "About 3 days")
        #expect(PackageDetailText.duration(59) == "About 59 days")
        #expect(PackageDetailText.duration(60) == "About 60 days, about 2 months")
        #expect(PackageDetailText.duration(90) == "About 90 days, about 3 months")
        #expect(PackageDetailText.duration(334) == "About 334 days, about 11 months")
        #expect(PackageDetailText.duration(335) == "About 335 days, about 1 year")
        #expect(PackageDetailText.duration(730) == "About 730 days, about 2 years")
    }
}
