import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain
import PantrifiedPersistence
import PantrifiedTestSupport

/// Holds each caller of `pass` until `count` callers have arrived.
private actor Gate {
    private let count: Int
    private var arrived = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(_ count: Int) { self.count = count }

    func pass() async {
        arrived += 1
        if arrived >= count {
            waiting.forEach { $0.resume() }
            waiting = []
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }
}

/// Holds every package read at a gate, so concurrent use cases all read before any of them saves.
private struct GatedInventory: InventoryRepository {
    let inner: any InventoryRepository
    let gate: Gate

    func package(_ id: PackageID) async throws -> Package? {
        let package = try await inner.package(id)
        await gate.pass()
        return package
    }

    func activePackages(in space: SpaceID) async throws -> [Package] { try await inner.activePackages(in: space) }
    func save(_ package: Package) async throws { try await inner.save(package) }
    func saveAll(_ packages: [Package]) async throws { try await inner.saveAll(packages) }
}

/// Holds the first locations lookup until released, so another change can be saved while a use
/// case waits between reading a package and saving it.
private actor HeldLocations: StorageLocationRepository {
    private let inner: InMemoryLocations
    private var held: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    private var hasArrived = false
    private var isFinished = false

    init(_ inner: InMemoryLocations) { self.inner = inner }

    func locations(in space: SpaceID) async throws -> [StorageLocation] {
        if !hasArrived {
            hasArrived = true
            arrival?.resume()
            arrival = nil
            await withCheckedContinuation { held = $0 }
        }
        return try await inner.locations(in: space)
    }

    /// Returns once the first lookup is held, or once the use case has ended without making one.
    func arrived() async {
        if hasArrived || isFinished { return }
        await withCheckedContinuation { arrival = $0 }
    }

    /// Called when the use case ends, so a use case that fails before its lookup cannot leave
    /// `arrived()` waiting forever.
    func finish() {
        isFinished = true
        arrival?.resume()
        arrival = nil
    }

    func release() {
        held?.resume()
        held = nil
    }
}

/// Saves through one replica and reads through a replica freshly opened from the stored state, so
/// every read in the contract checks what reached storage.
private struct ReopeningInventory: InventoryRepository {
    let live: SpaceReplica
    let backend: any StorageBackend
    let world: World

    private func reopened() throws -> SpaceReplica {
        try SpaceReplica(
            space: world.space, replica: ReplicaID(), transport: CloudLink(world.cloud),
            store: PersistentReplicaStateStore(space: world.space, backend: backend), time: FixedTime(syncEpoch)
        )
    }

    func package(_ id: PackageID) async throws -> Package? { try await reopened().package(id) }
    func activePackages(in space: SpaceID) async throws -> [Package] { try await reopened().activePackages(in: space) }
    func save(_ package: Package) async throws { try await live.save(package) }
    func saveAll(_ packages: [Package]) async throws { try await live.saveAll(packages) }
}

/// Every package store the use cases run against.
enum InventoryStore: String, CaseIterable, Sendable {
    case inMemory
    case replica
    /// A replica stored in each persistence backend.
    case storedInMemory
    #if canImport(SwiftData)
    case storedInSwiftData
    #endif

    func make(_ world: World, holding packages: [Package]) async throws -> any InventoryRepository {
        switch self {
        case .inMemory:
            return InMemoryInventory(packages)
        case .replica:
            let replica = try SpaceReplica(
                space: world.space, replica: ReplicaID(), transport: CloudLink(world.cloud),
                store: InMemoryReplicaStore(), time: FixedTime(syncEpoch)
            )
            try await replica.saveAll(packages)
            return replica
        case .storedInMemory:
            return try await stored(world, in: TestStorage.memory.makeBackend(), holding: packages)
        #if canImport(SwiftData)
        case .storedInSwiftData:
            return try await stored(world, in: TestStorage.swiftDataFile.makeBackend(), holding: packages)
        #endif
        }
    }

    private func stored(_ world: World, in backend: any StorageBackend, holding packages: [Package]) async throws -> any InventoryRepository {
        let replica = try SpaceReplica(
            space: world.space, replica: ReplicaID(), transport: CloudLink(world.cloud),
            store: PersistentReplicaStateStore(space: world.space, backend: backend), time: FixedTime(syncEpoch)
        )
        try await replica.saveAll(packages)
        return ReopeningInventory(live: replica, backend: backend, world: world)
    }
}

/// Use cases read a package, change it and save it in separate steps, so every store must keep the
/// contract on `InventoryRepository`: a save never loses a change stored since the copy was read.
@Suite("Inventory repository contract")
struct InventoryContractTests {
    private func milk(_ world: World) -> Package {
        Package(spaceID: world.space, name: "Milk", location: world.fridge.id, quantity: .full, addedAt: syncEpoch)
    }

    @Test("saving a stale copy keeps the events saved since it was read", arguments: InventoryStore.allCases)
    func staleSaveKeepsEvents(store: InventoryStore) async throws {
        let world = World()
        let original = milk(world)
        let inventory = try await store.make(world, holding: [original])

        var first = try #require(try await inventory.package(original.id))
        var stale = first
        try first.record(.usedUp, at: syncEpoch)
        try await inventory.save(first)
        try stale.record(.moved(to: world.freezer.id), at: syncEpoch)
        try await inventory.saveAll([stale, original])

        let stored = try #require(try await inventory.package(original.id))
        #expect(stored.status == .usedUp(at: syncEpoch))
        #expect(stored.location == world.freezer.id)
        #expect(stored.events.count == 2)
    }

    @Test("a later save of a package ID never changes its creation facts", arguments: InventoryStore.allCases)
    func creationFactsAreWrittenOnce(store: InventoryStore) async throws {
        let world = World()
        let original = milk(world)
        let inventory = try await store.make(world, holding: [original])

        try await inventory.save(Package(
            id: original.id, spaceID: world.space, name: "Oat milk", location: world.pantry.id, addedAt: syncEpoch
        ))

        let stored = try #require(try await inventory.package(original.id))
        #expect(stored.name == "Milk")
        #expect(stored.location == world.fridge.id)
        #expect(stored.quantity == .full)
    }

    @Test("two actions that both read a package before either saves both take effect", arguments: InventoryStore.allCases)
    func concurrentActionsBothSurvive(store: InventoryStore) async throws {
        let world = World()
        let original = milk(world)
        let inventory = try await store.make(world, holding: [original])
        let actions = PackageActions(
            inventory: GatedInventory(inner: inventory, gate: Gate(2)), locations: world.locations, time: FixedTime(syncEpoch)
        )

        async let opened = actions.apply(.opened, to: original.id)
        async let moved = actions.apply(.move(to: world.freezer.id), to: original.id)
        let outcomes = try await [opened, moved]

        let stored = try #require(try await inventory.package(original.id))
        #expect(stored.openedAt == syncEpoch)
        #expect(stored.location == world.freezer.id)
        for case .applied(let token) in outcomes {
            try await PackageActions(inventory: inventory, locations: world.locations, time: FixedTime(syncEpoch)).undo(token)
        }
        let undone = try #require(try await inventory.package(original.id))
        #expect(undone.openedAt == nil)
        #expect(undone.location == world.fridge.id)
    }

    @Test("Mark Cooked and a quick action on the same package both take effect", arguments: InventoryStore.allCases)
    func markCookedAndActionBothSurvive(store: InventoryStore) async throws {
        let world = World()
        let original = milk(world)
        let inventory = try await store.make(world, holding: [original])
        let gated = GatedInventory(inner: inventory, gate: Gate(2))
        let time = FixedTime(syncEpoch)

        async let cooked = MarkCooked(inventory: gated, time: time)
            .reconcile([IngredientUse(packageID: original.id, outcome: .usedSome)])
        async let opened = PackageActions(inventory: gated, locations: world.locations, time: time)
            .apply(.opened, to: original.id)
        _ = try await (cooked, opened)

        let stored = try #require(try await inventory.package(original.id))
        #expect(stored.quantity == .aboutHalf)
        #expect(stored.openedAt == syncEpoch)
    }

    @Test("a correction saved while recognition is running survives the recognition result", arguments: InventoryStore.allCases)
    func correctionSurvivesConcurrentRecognition(store: InventoryStore) async throws {
        let world = World()
        let original = milk(world)
        let inventory = try await store.make(world, holding: [original])

        var recognizing = try #require(try await inventory.package(original.id))
        var correcting = try #require(try await inventory.package(original.id))
        try correcting.record(.corrected(.name("Skyr")), at: syncEpoch)
        try await inventory.save(correcting)
        try recognizing.propose(PackageProposal(name: "Yogurt"), at: syncEpoch.addingTimeInterval(60))
        try await inventory.save(recognizing)

        let stored = try #require(try await inventory.package(original.id))
        #expect(stored.name == "Skyr")
        #expect(stored.confirmedFields == [.name])
    }

    @Test("a change saved while a move waits for its location lookup survives the move", arguments: InventoryStore.allCases)
    func changeDuringLocationLookupSurvives(store: InventoryStore) async throws {
        let world = World()
        let original = milk(world)
        let inventory = try await store.make(world, holding: [original])
        let held = HeldLocations(world.locations)
        let time = FixedTime(syncEpoch)
        let mover = PackageActions(inventory: inventory, locations: held, time: time)

        let move = Task {
            do {
                let outcome = try await mover.apply(.move(to: world.freezer.id), to: original.id)
                await held.finish()
                return outcome
            } catch {
                await held.finish()
                throw error
            }
        }
        await held.arrived()
        do {
            _ = try await PackageActions(inventory: inventory, locations: world.locations, time: time)
                .apply(.discard(reason: .spoiled), to: original.id)
        } catch {
            await held.release()
            throw error
        }
        await held.release()
        _ = try await move.value

        let stored = try #require(try await inventory.package(original.id))
        #expect(stored.status == .discarded(at: syncEpoch, reason: .spoiled))
        #expect(stored.location == world.freezer.id)
    }
}
