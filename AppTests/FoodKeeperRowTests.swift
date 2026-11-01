import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain
@testable import Pantrified

@Suite("FoodKeeper food row")
struct FoodKeeperRowTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let source = "USDA FSIS FoodKeeper"

    private let lactoseFree = GuidanceRecord(
        id: 543, name: "Milk", qualifier: "lactose-free", category: "Dairy Products & Eggs", keywords: [],
        windows: [GuidanceWindow(storageType: .refrigerated, anchor: .added, days: 30)]
    )
    private let salt = GuidanceRecord(id: 500, name: "Salt", qualifier: nil, category: nil, keywords: [], windows: [])

    private func entry(_ status: GuidanceRecordQuestion.Status?, candidates: [GuidanceRecord] = []) -> PantryEntry {
        let package = Package(spaceID: SpaceID(), name: "Milk", location: LocationID(), addedAt: now)
        let assessment = AttentionPolicy().assess(package, storageType: .refrigerated, guidance: nil, now: now)
        return PantryEntry(
            package: package, locationName: "Fridge", assessment: assessment,
            recordQuestion: status.map { GuidanceRecordQuestion(status: $0, candidates: candidates, source: source) }
        )
    }

    @Test("an unanswered food with candidates asks; one with none, or with no question, shows nothing")
    func asks() {
        let row = PackageDetailText.foodKeeperRow(for: entry(.unanswered, candidates: [lactoseFree]))

        #expect(row?.asks == true)
        #expect(row?.current == nil)
        #expect(row?.note?.contains("guidance, not an expiration date") == true)
        #expect(PackageDetailText.foodKeeperRow(for: entry(.unanswered)) == nil)
        #expect(PackageDetailText.foodKeeperRow(for: entry(nil)) == nil)
    }

    @Test("a matched or chosen food names its record, with its qualifier, and offers a change")
    func names() {
        for status in [GuidanceRecordQuestion.Status.matched(lactoseFree), .chosen(lactoseFree)] {
            let row = PackageDetailText.foodKeeperRow(for: entry(status))
            #expect(row == PackageDetailText.FoodKeeperRow(asks: false, current: "Milk, lactose-free", note: nil))
        }
    }

    @Test("a record with no storage time says so")
    func noWindows() {
        let row = PackageDetailText.foodKeeperRow(for: entry(.chosen(salt)))

        #expect(row?.current == "Salt")
        #expect(row?.note == "FoodKeeper gives no storage time for this food.")
    }

    @Test("a declined food says None, and a choice the guidance no longer holds asks again")
    func declinedAndMissing() {
        #expect(PackageDetailText.foodKeeperRow(for: entry(.declined))?.current == "None")

        let missing = PackageDetailText.foodKeeperRow(
            for: entry(.chosenRecordMissing(GuidanceRecordReference(lactoseFree, source: source)))
        )
        #expect(missing?.asks == true)
        #expect(missing?.note?.contains("not in this version of the guidance") == true)
    }

    @Test("the undo banner names what was chosen")
    func messages() {
        let reference = GuidanceRecordReference(lactoseFree, source: source)

        #expect(PackageDetailText.choiceMessage(.record(reference), name: "Milk") == "Milk now uses FoodKeeper's Milk, lactose-free")
        #expect(PackageDetailText.choiceMessage(.noneOfThese, name: "Milk") == "No FoodKeeper food for Milk")
        #expect(PackageDetailText.choiceMessage(nil, name: "Milk") == "Cleared the FoodKeeper food for Milk")
    }
}
