import Foundation
import Testing
@testable import PantrifiedDomain

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let space = SpaceID()
private let fridge = LocationID()

private func hours(_ n: Double) -> Date { t0.addingTimeInterval(n * 3600) }

private let plainMilk = GuidanceRecordReference(source: "USDA FSIS FoodKeeper", id: 27, name: "Milk", qualifier: "plain or flavored")
private let lactoseFree = GuidanceRecordReference(source: "USDA FSIS FoodKeeper", id: 543, name: "Milk", qualifier: "lactose-free")
private let noQualifier = GuidanceRecordReference(source: "USDA FSIS FoodKeeper", id: 382, name: "Marshmallow crème", qualifier: nil)

private func milk() -> Package {
    Package(spaceID: space, name: "Milk", location: fridge, addedAt: t0)
}

/// The record set a package stages into, and the package read back from it.
private func roundTrip(_ package: Package) throws -> Package {
    var clock = HybridClock(replica: ReplicaID())
    var records = RecordSet()
    for change in PackageRecords.changes(in: package, against: records, stamp: { clock.tick(now: t0) }) {
        records.merge(change)
    }
    return try #require(PackageRecords.materialize(package.id, from: records).entity)
}

@Suite("Choice of guidance record")
struct GuidanceChoiceTests {
    // MARK: The fold

    @Test("a package has no choice until the person makes one")
    func noChoiceByDefault() {
        #expect(milk().guidanceChoice == nil)
    }

    @Test("the person's choice is the package's choice, and a later one replaces it")
    func choiceIsRecorded() throws {
        var package = milk()
        try package.record(.corrected(.guidanceRecord(.record(plainMilk))), at: hours(1))
        #expect(package.guidanceChoice == .record(plainMilk))
        #expect(package.confirmedFields == [.guidanceRecord])

        try package.record(.corrected(.guidanceRecord(.noneOfThese)), at: hours(2))
        #expect(package.guidanceChoice == .noneOfThese)

        try package.record(.corrected(.guidanceRecord(nil)), at: hours(3))
        #expect(package.guidanceChoice == nil)
    }

    @Test("a proposed record never becomes the choice, before or after the person decides")
    func proposalNeverDecides() throws {
        var package = milk()
        try package.record(.recognized(.guidanceRecord(.record(plainMilk))), at: hours(1))
        #expect(package.guidanceChoice == nil)

        try package.record(.corrected(.guidanceRecord(.record(lactoseFree))), at: hours(2))
        try package.record(.recognized(.guidanceRecord(.record(plainMilk))), at: hours(3))
        #expect(package.guidanceChoice == .record(lactoseFree))
    }

    @Test("undoing a choice puts back the one before it")
    func undo() throws {
        var package = milk()
        try package.record(.corrected(.guidanceRecord(.record(plainMilk))), at: hours(1))
        let second = try package.record(.corrected(.guidanceRecord(.record(lactoseFree))), at: hours(2))

        try package.undo(second, at: hours(3))

        #expect(package.guidanceChoice == .record(plainMilk))
    }

    @Test("renaming the food keeps the choice, and the choice leaves the name alone")
    func renameKeepsChoice() throws {
        var package = milk()
        try package.record(.corrected(.guidanceRecord(.record(plainMilk))), at: hours(1))
        try package.record(.corrected(.name("Oat milk")), at: hours(2))

        #expect(package.name == "Oat milk")
        #expect(package.guidanceChoice == .record(plainMilk))
    }

    // MARK: Records

    @Test(
        "every kind of choice survives the round trip through records",
        arguments: [GuidanceChoice?.some(.record(plainMilk)), .some(.record(noQualifier)), .some(.noneOfThese), nil]
    )
    func roundTripsThroughRecords(choice: GuidanceChoice?) throws {
        var package = milk()
        try package.record(.corrected(.guidanceRecord(.record(lactoseFree))), at: hours(1))
        try package.record(.corrected(.guidanceRecord(choice)), at: hours(2))

        let restored = try roundTrip(package)

        #expect(restored.events == package.events)
        #expect(restored.guidanceChoice == choice)
        #expect(restored.confirmedFields == [.guidanceRecord])
    }

    @Test("a choice is written as a correction of the field tagged guidanceRecord, with the record spelled out")
    func wireForm() throws {
        var package = milk()
        try package.record(.corrected(.guidanceRecord(.record(noQualifier))), at: hours(1))
        try package.record(.corrected(.guidanceRecord(.noneOfThese)), at: hours(2))
        var clock = HybridClock(replica: ReplicaID())
        let records = PackageRecords.changes(in: package, against: RecordSet()) { clock.tick(now: t0) }

        let changes = records.compactMap { $0.value("change") }
        #expect(changes == [
            .map([
                "type": .string("corrected"), "field": .string("guidanceRecord"),
                "value": .map([
                    "kind": .string("record"), "source": .string("USDA FSIS FoodKeeper"), "id": .int(382),
                    "name": .string("Marshmallow crème"), "qualifier": .null,
                ]),
            ]),
            .map([
                "type": .string("corrected"), "field": .string("guidanceRecord"),
                "value": .map(["kind": .string("noneOfThese")]),
            ]),
        ])
        #expect(records.allSatisfy { $0.minimumReaderVersion == SyncFormat.version })
    }

    @Test(
        "a choice this version cannot read withholds the package instead of being guessed",
        arguments: [
            FieldValue.map(["kind": .string("bestGuess")]),
            .map(["kind": .string("record"), "source": .string("USDA FSIS FoodKeeper"), "id": .string("27"),
                  "name": .string("Milk"), "qualifier": .null]),
            .map(["kind": .string("record"), "source": .string("USDA FSIS FoodKeeper"), "id": .int(27),
                  "name": .string("Milk")]),
            .string("27"),
        ]
    )
    func unreadableChoice(value: FieldValue) throws {
        let package = milk()
        var clock = HybridClock(replica: ReplicaID())
        var records = RecordSet()
        for change in PackageRecords.changes(in: package, against: records, stamp: { clock.tick(now: t0) }) {
            records.merge(change)
        }
        records.merge(SyncRecord(
            id: RecordID(kind: .packageEvent, entity: UUID()),
            writing: [
                "package": .uuid(package.id.rawValue), "at": .date(hours(1)),
                "change": .map(["type": .string("corrected"), "field": .string("guidanceRecord"), "value": value]),
            ],
            at: clock.tick(now: hours(1))
        ))

        guard case .unreadable = PackageRecords.materialize(package.id, from: records) else {
            Issue.record("expected the package to be withheld")
            return
        }
    }

    // MARK: References

    @Test("a reference names a record only when source, identifier, name and qualifier all agree")
    func referenceNamesRecord() {
        let record = GuidanceRecord(id: 27, name: "Milk", qualifier: "plain or flavored", category: nil, keywords: [], windows: [])
        let source = "USDA FSIS FoodKeeper"

        #expect(plainMilk.names(record, source: source))
        #expect(!plainMilk.names(record, source: "Another source"))
        #expect(!plainMilk.names(
            GuidanceRecord(id: 28, name: "Milk", qualifier: "plain or flavored", category: nil, keywords: [], windows: []),
            source: source
        ))
        #expect(!plainMilk.names(
            GuidanceRecord(id: 27, name: "Buttermilk", qualifier: "plain or flavored", category: nil, keywords: [], windows: []),
            source: source
        ))
        #expect(!plainMilk.names(
            GuidanceRecord(id: 27, name: "Milk", qualifier: "lactose-free", category: nil, keywords: [], windows: []),
            source: source
        ))
        #expect(!plainMilk.names(
            GuidanceRecord(id: 27, name: "Milk", qualifier: nil, category: nil, keywords: [], windows: []),
            source: source
        ))
    }
}
