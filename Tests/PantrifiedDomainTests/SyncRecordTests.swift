import Foundation
import Testing
import PantrifiedTestSupport
@testable import PantrifiedDomain

private let a = ReplicaID()
private let b = ReplicaID()

private func stamp(_ millis: Int64, _ replica: ReplicaID = a, counter: Int = 0) -> HybridTimestamp {
    HybridTimestamp(physicalMillis: millis, counter: counter, replica: replica)
}

private let itemID = RecordID(kind: .shoppingItem, entity: UUID())

private func record(_ fields: [String: (FieldValue, HybridTimestamp)], created: HybridTimestamp = stamp(0)) -> SyncRecord {
    SyncRecord(
        id: itemID,
        created: created,
        fields: fields.mapValues { FieldEntry(value: $0.0, stamp: $0.1) }
    )
}

@Suite("Sync record merge")
struct SyncRecordMergeTests {
    @Test("each field keeps its own latest write")
    func fieldLevelMerge() {
        let left = record(["name": (.string("Milk"), stamp(1)), "checked": (.bool(true), stamp(5))])
        let right = record(["name": (.string("Oat milk"), stamp(3)), "checked": (.bool(false), stamp(2))])
        let merged = left.merged(with: right)

        #expect(merged.fields["name"]?.value == .string("Oat milk"))
        #expect(merged.fields["checked"]?.value == .bool(true))
    }

    @Test("fields this version does not know are kept")
    func unknownFieldsSurvive() {
        let newer = record(["name": (.string("Milk"), stamp(1)), "aisle": (.string("Dairy"), stamp(1))])
        let local = record(["name": (.string("Whole milk"), stamp(2))])
        let merged = local.merged(with: newer)

        #expect(merged.fields["aisle"]?.value == .string("Dairy"))
        #expect(merged.fields["name"]?.value == .string("Whole milk"))
    }

    @Test("two different values with the same stamp merge to the same winner in either order")
    func equalStampsAreDeterministic() {
        let left = record(["name": (.string("Milk"), stamp(1))])
        let right = record(["name": (.string("Oat milk"), stamp(1))])

        #expect(left.merged(with: right) == right.merged(with: left))
    }

    @Test("the higher minimum reader version and the earliest creation stamp are kept")
    func recordMetadata() {
        var newer = record([:], created: stamp(4))
        newer.minimumReaderVersion = 2
        let older = record([:], created: stamp(2))
        let merged = older.merged(with: newer)

        #expect(merged.minimumReaderVersion == 2)
        #expect(merged.created == stamp(2))
    }

    @Test("merging into a record set reports whether anything changed")
    func recordSetReportsChange() {
        var set = RecordSet()
        let first = record(["name": (.string("Milk"), stamp(1))])

        let added = set.merge(first)
        let repeated = set.merge(first)
        let newer = set.merge(record(["name": (.string("Oat milk"), stamp(2))]))
        let stale = set.merge(first)

        #expect(added && newer)
        #expect(!repeated && !stale)
        #expect(set[itemID]?.fields["name"]?.value == .string("Oat milk"))
    }

    @Test("merge is order-insensitive and idempotent over random deliveries", arguments: 0..<50)
    func mergeIsAJoin(seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        let names = ["name", "quantity", "checked", "removed"]
        let values: [FieldValue] = [.string("x"), .string("y"), .bool(true), .null, .int(3)]
        let writes = (0..<12).map { _ in
            record(
                [names.randomElement(using: &rng)!: (
                    values.randomElement(using: &rng)!,
                    stamp(Int64.random(in: 0..<4, using: &rng), Bool.random(using: &rng) ? a : b)
                )],
                created: stamp(Int64.random(in: 0..<3, using: &rng))
            )
        }

        var reference = RecordSet()
        for write in writes { reference.merge(write) }

        var shuffled = RecordSet()
        for write in (writes + writes.prefix(5)).shuffled(using: &rng) { shuffled.merge(write) }

        #expect(shuffled == reference)
    }
}
