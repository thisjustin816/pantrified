import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain
import PantrifiedPersistence
import PantrifiedTestSupport

/// Records the last state a replica stored successfully, which is the state it holds in memory.
private final class RecordingStore: ReplicaStateStore, @unchecked Sendable {
    let inner: any ReplicaStateStore
    private let lock = NSLock()
    private var stored: ReplicaState?

    init(_ inner: any ReplicaStateStore) { self.inner = inner }

    var lastStored: ReplicaState? { lock.withLock { stored } }

    func load() throws -> ReplicaState? {
        let state = try inner.load()
        lock.withLock { stored = state }
        return state
    }

    func save(_ state: ReplicaState) throws {
        try inner.save(state)
        lock.withLock { stored = state }
    }
}

/// A device whose replica keeps its state in a persistence backend. Restarting drops the replica
/// and its store and opens new ones over the same backend, as a relaunch after a crash does.
private struct StoredDevice {
    let world: World
    let backend: FaultyBackend
    let link: CloudLink
    let time: FixedTime
    let store: RecordingStore
    let replica: SpaceReplica

    static func open(_ world: World, backend: FaultyBackend, link: CloudLink, time: FixedTime) throws -> StoredDevice {
        let store = RecordingStore(PersistentReplicaStateStore(space: world.space, backend: backend))
        let replica = try SpaceReplica(space: world.space, replica: ReplicaID(), transport: link, store: store, time: time)
        return StoredDevice(world: world, backend: backend, link: link, time: time, store: store, replica: replica)
    }

    static func make(_ world: World, storage: TestStorage, faults: CloudLink.Faults = CloudLink.Faults()) throws -> StoredDevice {
        try open(world, backend: FaultyBackend(storage.makeBackend()), link: CloudLink(world.cloud, faults: faults), time: FixedTime(syncEpoch))
    }

    func restarted() throws -> StoredDevice {
        try Self.open(world, backend: backend, link: link, time: time)
    }

    var actions: PackageActions { PackageActions(inventory: replica, locations: world.locations, time: time) }
    var shopping: ShoppingListActions { ShoppingListActions(repository: replica, time: time) }

    /// What a fresh store reads from the backend.
    func reloaded() throws -> ReplicaState? {
        try PersistentReplicaStateStore(space: world.space, backend: backend.inner).load()
    }

    func putAway(_ name: String) async throws -> PackageID {
        var draft = PackageDraft(spaceID: world.space)
        draft.name.confirm(name)
        draft.location = world.fridge.id
        _ = try await PutAway(inventory: replica, locations: world.locations, time: time).putAway([draft])
        return draft.id
    }
}

@Suite("Replica stored durably")
struct DurableReplicaTests {
    @Test("a crash at any save during a sync resumes from storage and converges", arguments: TestStorage.allCases, 0..<6)
    func crashMidSyncResumes(storage: TestStorage, savesBeforeCrash: Int) async throws {
        let world = World()
        let a = try world.device("A")
        var b = try StoredDevice.make(world, storage: storage, faults: CloudLink.Faults(pageSize: 2))
        let id = try await world.putAway("Yogurt", on: a)
        try await a.actions.apply(.opened, to: id)
        try await a.shopping.add(name: "Milk", in: world.space)
        try await a.sync()
        try await b.shopping.add(name: "Eggs", in: world.space)
        try await b.shopping.add(name: "Bread", in: world.space)

        b.backend.failWrites(after: savesBeforeCrash)
        _ = try? await b.replica.sync()
        b.backend.failWrites(after: nil)
        #expect(try b.reloaded() == b.store.lastStored)
        b = try b.restarted()

        for _ in 0..<4 {
            try await a.sync()
            try await b.replica.sync()
        }
        let records = await a.replica.records
        #expect(await b.replica.records == records)
        #expect(await world.cloud.records(zone: world.space) == records)
        #expect(try await b.replica.package(id)?.events.count == 1)
        #expect(try await b.replica.list(in: world.space).items.map(\.name).sorted() == ["Bread", "Eggs", "Milk"])
        #expect(try b.reloaded()?.records == records)
    }

    @Test("duplicated, shuffled, stale and split deliveries are stored as the same records a clean delivery gives", arguments: TestStorage.allCases, [UInt64(3), 11])
    func hostileDeliveryIsStoredExactly(storage: TestStorage, seed: UInt64) async throws {
        let world = World()
        let a = try world.device("A")
        for name in ["Milk", "Eggs", "Rice"] {
            let id = try await world.putAway(name, on: a)
            try await a.actions.apply(.opened, to: id)
            try await a.sync()
        }
        try await a.shopping.add(name: "Beans", in: world.space)
        try await a.sync()
        let hostile = CloudLink.Faults(pageSize: 2, shuffleSeed: seed, duplicates: true, history: true)
        var b = try StoredDevice.make(world, storage: storage, faults: hostile)

        for _ in 0..<6 { try await b.replica.sync() }
        b = try b.restarted()

        let expected = await world.cloud.records(zone: world.space)
        #expect(await b.replica.records == expected)
        #expect(try b.reloaded()?.records == expected)
        #expect(await b.replica.pendingCount == 0)
    }

    @Test("a NaN date pulled into storage is not uploaded again after a restart", arguments: TestStorage.allCases)
    func notANumberSurvivesRestart(storage: TestStorage) async throws {
        let world = World()
        let a = try world.device("A")
        try await a.shopping.add(name: "Rice", in: world.space)
        try await a.sync()
        let rice = try #require(try await a.replica.list(in: world.space).items.first)
        let id = RecordID(kind: .shoppingItem, entity: rice.id.rawValue)
        var odd = try #require(await world.cloud.records(zone: world.space)[id])
        let stamp = HybridTimestamp(physicalMillis: odd.latestStamp.physicalMillis + 1, counter: 0, replica: ReplicaID())
        odd.fields["checkedAt"] = FieldEntry(value: .date(Date(timeIntervalSinceReferenceDate: .nan)), stamp: stamp)
        _ = await world.cloud.push([OutgoingRecord(record: odd, knownTag: ServerTag("1"))], zone: world.space, failing: [], unconfirmed: 0)
        var b = try StoredDevice.make(world, storage: storage)
        try await b.replica.sync()

        b = try b.restarted()
        try await b.shopping.add(name: "Eggs", in: world.space)
        try await b.replica.sync()
        let batches = b.backend.committedBatches.count
        try await b.replica.sync()

        #expect(b.backend.committedBatches.count == batches)
        #expect(await b.replica.pendingCount == 0)
        #expect(try b.reloaded()?.records[id] == odd)
    }

    @Test("a restarted replica keeps issuing stamps after the ones it stored", arguments: TestStorage.allCases)
    func clockSurvivesRestart(storage: TestStorage) async throws {
        let world = World()
        var device = try StoredDevice.make(world, storage: storage)
        try await device.shopping.add(name: "Milk", in: world.space)
        let before = try #require(await device.replica.records.records.values.first?.latestStamp)

        device.time.advance(hours: -10)
        device = try device.restarted()
        try await device.shopping.add(name: "Eggs", in: world.space)

        let stamps = await device.replica.records.records.values.map(\.latestStamp)
        #expect(stamps.allSatisfy { $0 >= before })
        #expect(Set(stamps).count == 2)
    }

    @Test("a list change that throws, or whose save fails, stores nothing and changes nothing", arguments: TestStorage.allCases)
    func shoppingUpdateIsAtomic(storage: TestStorage) async throws {
        let world = World()
        let device = try StoredDevice.make(world, storage: storage)
        try await device.shopping.add(name: "Milk", in: world.space)
        let stored = try device.reloaded()

        await #expect(throws: InducedFailure.self) {
            try await device.replica.update(in: world.space) { list in
                _ = try list.add(name: "Eggs", at: syncEpoch)
                throw InducedFailure()
            }
        }
        device.backend.failWrites(after: 0)
        await #expect(throws: InducedFailure.self) {
            try await device.shopping.add(name: "Bread", in: world.space)
        }
        device.backend.failWrites(after: nil)

        #expect(try device.reloaded() == stored)
        #expect(try await device.replica.list(in: world.space).items.map(\.name) == ["Milk"])
        try await device.shopping.add(name: "Rice", in: world.space)
        #expect(try await device.restarted().replica.list(in: world.space).items.map(\.name) == ["Milk", "Rice"])
    }

    @Test("cancelled saves leave storage equal to what the replica holds", arguments: TestStorage.allCases)
    func cancellationKeepsStorageConsistent(storage: TestStorage) async throws {
        let world = World()
        let device = try StoredDevice.make(world, storage: storage)
        let tasks = (0..<20).map { index in
            Task { try await device.shopping.add(name: "Item \(index)", in: world.space) }
        }
        for task in tasks.enumerated() where task.offset.isMultiple(of: 2) { task.element.cancel() }
        for task in tasks { _ = await task.result }

        let reloaded = try #require(try device.reloaded())
        #expect(reloaded == device.store.lastStored)
        #expect(reloaded.records == (await device.replica.records))
        #expect(try await device.restarted().replica.list(in: world.space).items.count == (try await device.replica.list(in: world.space).items.count))
    }

    /// Adversarial: every change the replica reported as saved must survive failed writes,
    /// restarts and another device's concurrent changes. Nothing may be lost, duplicated or
    /// brought back after removal, and storage must equal what the replica holds after every step.
    @Test("random changes, syncs, failed writes and restarts never lose, duplicate or resurrect anything", arguments: TestStorage.allCases, [UInt64(1), 2, 3, 4, 5])
    func randomFaultsLoseNothing(storage: TestStorage, seed: UInt64) async throws {
        let world = World()
        let a = try world.device("A", skewHours: 1)
        var b = try StoredDevice.make(world, storage: storage, faults: CloudLink.Faults(pageSize: 3))
        b.backend.failWrites { attempt in
            var draw = SeededGenerator(seed: seed &* 7919 &+ UInt64(attempt))
            return draw.next() % 4 == 0
        }
        var rng = SeededGenerator(seed: seed)
        var putAway: [PackageID] = []
        var applied: [UndoToken] = []
        var undone: Set<PackageEventID> = []
        var listed: [ShoppingItemID: String] = [:]
        var removed: Set<ShoppingItemID> = []
        let locations = [world.fridge.id, world.freezer.id, world.pantry.id]

        for step in 0..<80 {
            do {
                switch Int.random(in: 0...8, using: &rng) {
                case 0:
                    putAway.append(try await b.putAway("Food \(step)"))
                case 1, 2:
                    guard let id = putAway.randomElement(using: &rng) else { continue }
                    let action: PackageAction = [.opened, .usedUp, .discard(reason: .spoiled), .move(to: locations.randomElement(using: &rng)!)]
                        .randomElement(using: &rng)!
                    if case .applied(let token) = try await b.actions.apply(action, to: id) { applied.append(token) }
                case 3:
                    guard let token = applied.filter({ !undone.contains($0.eventID) }).randomElement(using: &rng) else { continue }
                    try await b.actions.undo(token)
                    undone.insert(token.eventID)
                case 4:
                    if case .added(let item) = try await b.shopping.add(name: "Item \(step)", in: world.space) {
                        listed[item.id] = item.name
                    }
                case 5:
                    guard let id = listed.keys.filter({ !removed.contains($0) }).randomElement(using: &rng) else { continue }
                    _ = try await b.shopping.remove([id], in: world.space)
                    removed.insert(id)
                case 6:
                    try await b.replica.sync()
                case 7:
                    try await a.sync()
                    if let id = try await a.replica.activePackages(in: world.space).randomElement(using: &rng)?.id {
                        _ = try await a.actions.apply(.opened, to: id)
                    }
                    try await a.sync()
                default:
                    b = try b.restarted()
                }
            } catch {
                // A failed write or a refused action changes nothing; the checks below say so.
            }
            let stored = try b.reloaded()
            #expect(stored == b.store.lastStored, "step \(step)")
            #expect(stored?.records ?? RecordSet() == (await b.replica.records), "step \(step)")
        }

        b.backend.failWrites(after: nil)
        b = try b.restarted()
        for _ in 0..<6 {
            try await b.replica.sync()
            try await a.sync()
        }
        let records = await b.replica.records
        #expect(await a.replica.records == records)
        #expect(await world.cloud.records(zone: world.space) == records)
        #expect(Set(PackageRecords.materializeAll(from: records).keys) == Set(putAway))
        for token in applied {
            let events = try #require(try await b.replica.package(token.packageID)).events
            #expect(events.contains { $0.id == token.eventID })
            if undone.contains(token.eventID) {
                #expect(events.contains { $0.kind == .undone(token.eventID) })
            }
        }
        let list = Set(try await b.replica.list(in: world.space).items.map(\.id))
        #expect(list == Set(listed.keys).subtracting(removed))
    }

    /// Adversarial: two replicas opened over one Space's storage, as a second `LocalStore` in one
    /// process would. Their records merge, but the last header written can hold the clock of the
    /// replica that has seen less.
    @Test("two replicas writing one Space's storage lose no record, and a reopened clock follows every stored stamp", arguments: TestStorage.allCases)
    func twoWritersKeepRecordsAndClock(storage: TestStorage) async throws {
        let world = World()
        let backend = try storage.makeBackend()
        let time = FixedTime(syncEpoch)
        let lagging = FixedTime(syncEpoch)
        func open(_ time: FixedTime) throws -> SpaceReplica {
            try SpaceReplica(
                space: world.space, replica: ReplicaID(), transport: CloudLink(world.cloud),
                store: PersistentReplicaStateStore(space: world.space, backend: backend), time: time
            )
        }
        let seed = try open(time)
        try await ShoppingListActions(repository: seed, time: time).add(name: "Milk", in: world.space)
        let first = try open(time)
        let second = try open(lagging)

        for name in ["Eggs", "Rice", "Beans"] {
            time.advance(hours: 1)
            try await ShoppingListActions(repository: first, time: time).add(name: name, in: world.space)
        }
        try await ShoppingListActions(repository: second, time: lagging).add(name: "Bread", in: world.space)

        let reopened = try open(time)
        let stored = await reopened.records
        #expect(Set(try await reopened.list(in: world.space).items.map(\.name)) == ["Milk", "Eggs", "Rice", "Beans", "Bread"])
        #expect(await reopened.pendingCount == 5)
        time.advance(hours: -10)
        try await ShoppingListActions(repository: reopened, time: time).add(name: "Kale", in: world.space)
        let latest = stored.records.values.map(\.latestStamp).max()!
        let kale = try #require(await reopened.records.records.values.first { $0.value("name") == .string("Kale") })
        #expect(kale.created > latest)
    }
}
