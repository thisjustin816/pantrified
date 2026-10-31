import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain
import PantrifiedTestSupport
@testable import PantrifiedPersistence

private func stamp(_ millis: Int64, _ replica: ReplicaID = ReplicaID()) -> HybridTimestamp {
    HybridTimestamp(physicalMillis: millis, counter: 0, replica: replica)
}

private let creator = ReplicaID()

private func item(_ entity: UUID = UUID(), name: String, at millis: Int64) -> SyncRecord {
    SyncRecord(
        id: RecordID(kind: .shoppingItem, entity: entity),
        created: stamp(1, creator),
        fields: ["name": FieldEntry(value: .string(name), stamp: stamp(millis))]
    )
}

/// A state as a replica builds it: records, some queued, some with server tags, a token and a clock
/// that has moved.
func sampleState(seed: UInt64 = 1, records count: Int = 12) -> ReplicaState {
    var rng = SeededGenerator(seed: seed)
    var state = ReplicaState(replica: ReplicaID())
    for _ in 0..<count {
        let record = StoredValueCodingTests.randomRecord(using: &rng)
        state.records.merge(record)
        state.clock.observe(record.latestStamp)
        if Bool.random(using: &rng) { state.outbox.insert(record.id) }
        if Bool.random(using: &rng) { state.serverTags[record.id] = ServerTag("tag-\(UInt8.random(in: 0...255, using: &rng))") }
    }
    state.changeToken = ChangeToken("token-\(seed)")
    _ = state.clock.tick(now: Date(timeIntervalSince1970: 1_800_000_000))
    return state
}

@Suite("Replica rows")
struct ReplicaRowMappingTests {
    private let space = SpaceID()

    private func stored(_ state: ReplicaState) throws -> ReplicaState? {
        let backend = InMemoryStorageBackend()
        try backend.write(ReplicaRowMapping.batch(from: nil, to: state, in: space))
        return try ReplicaRowMapping.state(from: backend.replicaRows(in: space))
    }

    @Test("a stored state reads back equal: records, queue, server tags, token and clock", arguments: [UInt64(1), 2, 3])
    func stateRoundTrips(seed: UInt64) throws {
        let state = sampleState(seed: seed)

        #expect(try stored(state) == state)
    }

    @Test("queued records and server tags without a record are kept")
    func metadataWithoutRecordRoundTrips() throws {
        var state = ReplicaState(replica: ReplicaID())
        let orphan = RecordID(kind: .package, entity: UUID())
        state.outbox.insert(orphan)
        state.serverTags[RecordID(kind: .packageEvent, entity: UUID())] = ServerTag("7")

        #expect(try stored(state) == state)
    }

    @Test("a state that was never stored reads as nothing")
    func emptyStoreHasNoState() throws {
        #expect(try ReplicaRowMapping.state(from: InMemoryStorageBackend().replicaRows(in: space)) == nil)
    }

    @Test("a fresh clock and a missing token survive")
    func freshStateRoundTrips() throws {
        let state = ReplicaState(replica: ReplicaID())

        #expect(try stored(state) == state)
    }

    @Test("a save writes only the rows whose record, queue entry or tag changed")
    func batchesAreIncremental() {
        let old = sampleState(records: 50)
        var new = old
        let changed = item(name: "Eggs", at: 9)
        new.records.merge(changed)
        new.outbox.insert(changed.id)
        let pushed = old.outbox.first!
        new.outbox.remove(pushed)
        new.serverTags[pushed] = ServerTag("new")

        let batch = ReplicaRowMapping.batch(from: old, to: new, in: space)

        let writes = batch.recordWrites[space] ?? []
        #expect(Set(writes.map(\.id)) == [changed.id, pushed])
        #expect(writes.first { $0.id == pushed }?.record == nil)
        #expect(batch.replicaHeaders.isEmpty)
    }

    @Test("a save that changes only the clock or the token writes only the header")
    func headerChangesAlone() {
        let old = sampleState()
        var ticked = old
        ticked.clock.adopt(ReplicaID())
        var moved = old
        moved.changeToken = ChangeToken("next")

        for new in [ticked, moved] {
            let batch = ReplicaRowMapping.batch(from: old, to: new, in: space)
            #expect(batch.recordWrites.isEmpty)
            #expect(batch.replicaHeaders[space] != nil)
        }
        #expect(ReplicaRowMapping.batch(from: old, to: old, in: space).isEmpty)
    }

    @Test("a record written over a stored copy merges with it, so a stale writer never erases a field")
    func writesMergeWithStoredRecord() throws {
        let entity = UUID()
        let newer = item(entity, name: "Oat milk", at: 20)
        let stale = item(entity, name: "Milk", at: 10)
        let storedRow = RecordRow(id: newer.id, payload: StoredValueCoding.encode(newer), queued: true, serverTag: "3")

        let resolved = try #require(try RecordRowWrite(id: stale.id, record: stale, queued: false, serverTag: "4").resolve(over: storedRow))

        #expect(try StoredValueCoding.record(from: #require(resolved.payload)) == newer)
        #expect(resolved.queued == false)
        #expect(resolved.serverTag == "4")
    }

    @Test("a write without a record keeps the stored record and deletes a row left with nothing")
    func metadataWritesKeepRecords() throws {
        let record = item(name: "Rice", at: 3)
        let row = RecordRow(id: record.id, payload: StoredValueCoding.encode(record), queued: true, serverTag: nil)
        let clear = RecordRowWrite(id: record.id, record: nil, queued: false, serverTag: nil)

        #expect(try clear.resolve(over: row)?.payload == row.payload)
        #expect(try clear.resolve(over: RecordRow(id: record.id, payload: nil, queued: true, serverTag: "1")) == nil)
    }

    @Test("a stored payload holding another record's ID is reported as corrupt")
    func mismatchedPayloadIsCorrupt() throws {
        let record = item(name: "Rice", at: 3)
        let other = RecordID(kind: .shoppingItem, entity: UUID())
        let rows = StoredReplicaRows(
            header: ReplicaRowMapping.header(of: ReplicaState(replica: ReplicaID())),
            records: [RecordRow(id: other, payload: StoredValueCoding.encode(record), queued: false, serverTag: nil)]
        )

        #expect(throws: PersistenceError.self) { try ReplicaRowMapping.state(from: rows) }
        #expect(throws: PersistenceError.self) {
            try RecordRowWrite(id: other, record: item(other.entity, name: "x", at: 1), queued: false, serverTag: nil)
                .resolve(over: rows.records[0])
        }
    }

    @Test("records without a replica header, or a garbled header, are reported as corrupt")
    func missingHeaderIsCorrupt() {
        let record = item(name: "Rice", at: 3)
        let row = RecordRow(id: record.id, payload: StoredValueCoding.encode(record), queued: false, serverTag: nil)

        #expect(throws: PersistenceError.corrupt("records without a replica header")) {
            try ReplicaRowMapping.state(from: StoredReplicaRows(header: nil, records: [row]))
        }
        #expect(throws: PersistenceError.self) {
            try ReplicaRowMapping.state(from: StoredReplicaRows(header: Data([StoredValueCoding.version, 1]), records: []))
        }
    }

    @Test("record row keys are unique per Space, kind and entity, including kinds containing separators")
    func rowKeysAreUnambiguous() {
        let entity = UUID()
        let spaces = [SpaceID(), SpaceID()]
        let kinds = ["package", "packageEvent", "a|b", "a", "|", ""].map(RecordKind.init(rawValue:))
        var keys: Set<String> = []
        for space in spaces {
            for kind in kinds { keys.insert(RowKey.record(RecordID(kind: kind, entity: entity), in: space)) }
        }

        #expect(keys.count == spaces.count * kinds.count)
    }
}
