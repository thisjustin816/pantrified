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
}
