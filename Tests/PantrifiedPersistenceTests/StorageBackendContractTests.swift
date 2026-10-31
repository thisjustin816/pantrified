import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain
import PantrifiedTestSupport
@testable import PantrifiedPersistence

private let creator = ReplicaID()

private func record(_ name: String, at millis: Int64, entity: UUID = UUID()) -> SyncRecord {
    SyncRecord(
        id: RecordID(kind: .shoppingItem, entity: entity),
        created: HybridTimestamp(physicalMillis: 1, counter: 0, replica: creator),
        fields: ["name": FieldEntry(value: .string(name), stamp: HybridTimestamp(physicalMillis: millis, counter: 0, replica: creator))]
    )
}

private func write(_ record: SyncRecord, queued: Bool = false, tag: String? = nil) -> RecordRowWrite {
    RecordRowWrite(id: record.id, record: record, queued: queued, serverTag: tag)
}

/// What every backend must do, run against each one.
@Suite("Storage backend contract")
struct StorageBackendContractTests {
    private let space = SpaceID()

    @Test("committed rows read back exactly", arguments: TestStorage.allCases)
    func rowsReadBack(storage: TestStorage) throws {
        let backend = try storage.makeBackend()
        let milk = record("Milk", at: 2)
        let link = LocalRowKey(kind: .ingredientLink, space: space, entity: "a\nb")
        var batch = StorageBatch()
        batch.replicaHeaders[space] = Data([1, 2, 3])
        batch.recordWrites[space] = [write(milk, queued: true, tag: "9")]
        batch.localWrites[link] = .put(Data([4]))

        try backend.write(batch)

        let rows = try backend.replicaRows(in: space)
        #expect(rows.header == Data([1, 2, 3]))
        #expect(rows.records == [RecordRow(id: milk.id, payload: StoredValueCoding.encode(milk), queued: true, serverTag: "9")])
        #expect(try backend.localRows(of: .ingredientLink, in: space) == [LocalRow(key: link, payload: Data([4]))])
        #expect(try backend.replicaRows(in: SpaceID()) == StoredReplicaRows(header: nil, records: []))
    }

    @Test("a batch that fails part way applies none of its changes", arguments: TestStorage.allCases)
    func failedBatchAppliesNothing(storage: TestStorage) throws {
        let backend = try storage.makeBackend()
        var first = StorageBatch()
        first.replicaHeaders[space] = Data([1])
        first.recordWrites[space] = [write(record("Milk", at: 2))]
        try backend.write(first)
        let before = try backend.replicaRows(in: space)

        let mismatched = RecordRowWrite(id: RecordID(kind: .shoppingItem, entity: UUID()), record: record("Eggs", at: 3), queued: false, serverTag: nil)
        var failing = StorageBatch()
        failing.replicaHeaders[space] = Data([2])
        failing.recordWrites[space] = [write(record("Rice", at: 4)), mismatched, write(record("Beans", at: 5))]
        failing.localWrites[LocalRowKey(kind: .location, space: space, entity: "x")] = .put(Data([7]))

        #expect(throws: PersistenceError.self) { try backend.write(failing) }

        let after = try backend.replicaRows(in: space)
        #expect(after.header == before.header)
        #expect(Set(after.records) == Set(before.records))
        #expect(try backend.localRows(of: .location, in: space).isEmpty)
    }

    @Test("a stale record write merges into the stored record instead of replacing it", arguments: TestStorage.allCases)
    func recordWritesMerge(storage: TestStorage) throws {
        let backend = try storage.makeBackend()
        let entity = UUID()
        var newer = StorageBatch()
        newer.recordWrites[space] = [write(record("Oat milk", at: 20, entity: entity))]
        try backend.write(newer)
        var stale = StorageBatch()
        stale.recordWrites[space] = [write(record("Milk", at: 10, entity: entity), queued: true)]

        try backend.write(stale)

        let row = try #require(try backend.replicaRows(in: space).records.first)
        #expect(try StoredValueCoding.record(from: #require(row.payload)).value("name") == .string("Oat milk"))
        #expect(row.queued)
    }

    @Test("local rows are replaced, removed and kept apart by kind and Space", arguments: TestStorage.allCases)
    func localRowsByKindAndSpace(storage: TestStorage) throws {
        let backend = try storage.makeBackend()
        let other = SpaceID()
        let keys = [
            LocalRowKey(kind: .location, space: space, entity: "1"),
            LocalRowKey(kind: .location, space: space, entity: "2"),
            LocalRowKey(kind: .ingredientLink, space: space, entity: "1"),
            LocalRowKey(kind: .location, space: other, entity: "1"),
        ]
        var batch = StorageBatch()
        for (index, key) in keys.enumerated() { batch.localWrites[key] = .put(Data([UInt8(index)])) }
        try backend.write(batch)
        var change = StorageBatch()
        change.localWrites[keys[0]] = .put(Data([9]))
        change.localWrites[keys[1]] = .remove

        try backend.write(change)

        #expect(try backend.localRows(of: .location, in: space) == [LocalRow(key: keys[0], payload: Data([9]))])
        #expect(try backend.localRows(of: .ingredientLink, in: space) == [LocalRow(key: keys[2], payload: Data([2]))])
        #expect(try backend.localRows(of: .location, in: other) == [LocalRow(key: keys[3], payload: Data([3]))])
    }

    @Test("concurrent batches from many tasks are all applied", arguments: TestStorage.allCases)
    func concurrentBatchesAllApply(storage: TestStorage) async throws {
        let backend = try storage.makeBackend()
        let space = self.space
        let entity = UUID()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<24 {
                group.addTask {
                    var batch = StorageBatch()
                    batch.recordWrites[space] = [
                        write(record("Item \(index)", at: Int64(index))),
                        write(record("Shared \(index)", at: Int64(index), entity: entity)),
                    ]
                    batch.localWrites[LocalRowKey(kind: .location, space: space, entity: "\(index)")] = .put(Data([UInt8(index)]))
                    try backend.write(batch)
                }
            }
            try await group.waitForAll()
        }

        let rows = try backend.replicaRows(in: space).records
        #expect(rows.count == 25)
        let shared = try #require(rows.first { $0.id.entity == entity })
        #expect(try StoredValueCoding.record(from: #require(shared.payload)).value("name") == .string("Shared 23"))
        #expect(try backend.localRows(of: .location, in: space).count == 24)
    }
}
