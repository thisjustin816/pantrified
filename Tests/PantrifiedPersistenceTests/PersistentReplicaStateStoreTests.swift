import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain
import PantrifiedTestSupport
@testable import PantrifiedPersistence

@Suite("Persistent replica state store")
struct PersistentReplicaStateStoreTests {
    private let space = SpaceID()

    private func reopened(_ backend: any StorageBackend) throws -> ReplicaState? {
        try PersistentReplicaStateStore(space: space, backend: backend).load()
    }

    private func adding(_ name: String, to state: ReplicaState) -> ReplicaState {
        var next = state
        let stamp = next.clock.tick(now: Date(timeIntervalSince1970: 1_800_000_000))
        let record = SyncRecord(
            id: RecordID(kind: .shoppingItem, entity: UUID()), created: stamp,
            fields: ["name": FieldEntry(value: .string(name), stamp: stamp)]
        )
        next.records.merge(record)
        next.outbox.insert(record.id)
        return next
    }

    @Test("a store that holds nothing loads nothing")
    func emptyLoadsNothing() throws {
        #expect(try reopened(InMemoryStorageBackend()) == nil)
    }

    @Test("every saved state loads back equal in a new store over the same backend")
    func savesSurviveReopening() throws {
        let backend = InMemoryStorageBackend()
        let store = PersistentReplicaStateStore(space: space, backend: backend)
        var state = sampleState()
        for name in ["Milk", "Eggs", "Rice"] {
            state = adding(name, to: state)
            try store.save(state)
            #expect(try reopened(backend) == state)
        }
    }

    @Test("states of different Spaces in one backend stay apart")
    func spacesStayApart() throws {
        let backend = InMemoryStorageBackend()
        let other = SpaceID()
        let mine = sampleState(seed: 1)
        let theirs = sampleState(seed: 2)
        try PersistentReplicaStateStore(space: space, backend: backend).save(mine)
        try PersistentReplicaStateStore(space: other, backend: backend).save(theirs)

        #expect(try reopened(backend) == mine)
        #expect(try PersistentReplicaStateStore(space: other, backend: backend).load() == theirs)
    }

    @Test("a save writes one batch holding only what changed")
    func savesAreIncremental() throws {
        let backend = FaultyBackend(InMemoryStorageBackend())
        let store = PersistentReplicaStateStore(space: space, backend: backend)
        let first = sampleState(records: 40)
        try store.save(first)

        try store.save(adding("Milk", to: first))

        let last = try #require(backend.committedBatches.last)
        #expect(backend.committedBatches.count == 2)
        #expect(last.recordWrites[space]?.count == 1)
    }

    @Test("saving an unchanged state writes nothing")
    func unchangedSaveWritesNothing() throws {
        let backend = FaultyBackend(InMemoryStorageBackend())
        let store = PersistentReplicaStateStore(space: space, backend: backend)
        let state = sampleState()
        try store.save(state)

        try store.save(state)

        #expect(backend.committedBatches.count == 1)
    }

    @Test("a failed save leaves the previous state stored, and the next save stores everything since")
    func failedSaveKeepsPreviousState() throws {
        let backend = FaultyBackend(InMemoryStorageBackend())
        let store = PersistentReplicaStateStore(space: space, backend: backend)
        let first = sampleState()
        try store.save(first)
        let second = adding("Milk", to: first)

        backend.failWrites(after: 0)
        #expect(throws: InducedFailure.self) { try store.save(second) }
        #expect(try reopened(backend) == first)

        backend.failWrites(after: nil)
        let third = adding("Eggs", to: second)
        try store.save(third)
        #expect(try reopened(backend) == third)
    }

    @Test("a save that committed but reported failure is confirmed by reading it back, so the replica adopts it")
    func committedSaveIsConfirmed() throws {
        let backend = FaultyBackend(InMemoryStorageBackend())
        let store = PersistentReplicaStateStore(space: space, backend: backend)
        var pushed = sampleState()
        try store.save(pushed)
        pushed.outbox.remove(try #require(pushed.outbox.first))

        backend.reportFailureAfterCommit(true)
        try store.save(pushed)
        backend.reportFailureAfterCommit(false)

        let next = adding("Rice", to: pushed)
        try store.save(next)
        #expect(try reopened(backend) == next)
    }

    @Test("concurrent saves of different Spaces into one backend all persist")
    func concurrentSpacesPersist() async throws {
        let backend = InMemoryStorageBackend()
        let spaces = (0..<8).map { _ in SpaceID() }
        let states = try await withThrowingTaskGroup(of: (SpaceID, ReplicaState).self) { group in
            for (index, space) in spaces.enumerated() {
                group.addTask {
                    let store = PersistentReplicaStateStore(space: space, backend: backend)
                    var state = sampleState(seed: UInt64(index + 1))
                    for name in ["a", "b", "c", "d"] {
                        state = self.adding(name, to: state)
                        try store.save(state)
                    }
                    return (space, state)
                }
            }
            return try await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }

        for space in spaces {
            #expect(try PersistentReplicaStateStore(space: space, backend: backend).load() == states[space])
        }
    }
}
