import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain

let syncEpoch = Date(timeIntervalSince1970: 1_800_000_000)

/// One household device: a replica of the Space with the real use cases running against it.
struct Device {
    let name: String
    let replica: SpaceReplica
    let link: CloudLink
    let store: InMemoryReplicaStore
    let time: FixedTime
    let actions: PackageActions
    let putAway: PutAway
    let markCooked: MarkCooked
    let shopping: ShoppingListActions

    @discardableResult
    func sync() async throws -> SyncReport {
        try await replica.sync()
    }

    /// Syncs, ignoring a failure such as being offline; the attempt is the point.
    func trySync() async {
        _ = try? await replica.sync()
    }

    func package(_ id: PackageID) async throws -> Package {
        try #require(await replica.package(id))
    }
}

/// A Space shared through one in-memory cloud. Device clocks are deliberately skewed so nothing
/// can depend on wall clocks agreeing.
struct World {
    let space = SpaceID()
    let fridge = StorageLocation(name: "Fridge", storageType: .refrigerated)
    let freezer = StorageLocation(name: "Freezer", storageType: .frozen)
    let pantry = StorageLocation(name: "Pantry", storageType: .roomTemperature)
    private(set) var cloud = InMemoryCloud()

    /// The same Space and locations behind an empty server.
    func withEmptyCloud() -> World {
        var world = self
        world.cloud = InMemoryCloud()
        return world
    }

    var locations: InMemoryLocations {
        InMemoryLocations(locationsBySpace: [space: [fridge, freezer, pantry]])
    }

    func device(
        _ name: String,
        skewHours: Double = 0,
        faults: CloudLink.Faults = CloudLink.Faults(),
        replicaID: ReplicaID = ReplicaID(),
        store: InMemoryReplicaStore = InMemoryReplicaStore()
    ) throws -> Device {
        let time = FixedTime(syncEpoch.addingTimeInterval(skewHours * 3600))
        let link = CloudLink(cloud, faults: faults)
        return try attach(name, link: link, store: store, time: time, replicaID: replicaID)
    }

    /// A fresh process for an existing device: same store, link and clock, new replica actor.
    func restart(_ device: Device) throws -> Device {
        try attach(device.name, link: device.link, store: device.store, time: device.time, replicaID: ReplicaID())
    }

    /// A second installation restored from `device`'s backup: the same stored state, replica ID and
    /// clock, on a device whose wall clock reads the same.
    func restore(_ device: Device, as name: String) throws -> Device {
        let time = FixedTime(device.time.now())
        let link = CloudLink(cloud)
        return try attach(name, link: link, store: InMemoryReplicaStore(device.store.state), time: time, replicaID: ReplicaID())
    }

    private func attach(
        _ name: String,
        link: CloudLink,
        store: InMemoryReplicaStore,
        time: FixedTime,
        replicaID: ReplicaID
    ) throws -> Device {
        let replica = try SpaceReplica(space: space, replica: replicaID, transport: link, store: store, time: time)
        return Device(
            name: name,
            replica: replica,
            link: link,
            store: store,
            time: time,
            actions: PackageActions(inventory: replica, locations: locations, time: time),
            putAway: PutAway(inventory: replica, locations: locations, time: time),
            markCooked: MarkCooked(inventory: replica, time: time),
            shopping: ShoppingListActions(repository: replica, time: time)
        )
    }

    /// A package put away on `device`, with a recognized name unless `confirmedName` is set.
    func putAway(_ name: String, on device: Device, confirmedName: Bool = true) async throws -> PackageID {
        var draft = PackageDraft(spaceID: space)
        if confirmedName { draft.name.confirm(name) } else { draft.apply(PackageProposal(name: name)) }
        draft.apply(PackageProposal(quantity: .full))
        draft.location = fridge.id
        _ = try await device.putAway.putAway([draft])
        return draft.id
    }

    /// Syncs every device in turn until nothing is pending and a full round pulls nothing new.
    func settle(_ devices: [Device], rounds: Int = 8) async throws {
        for _ in 0..<rounds {
            var pulled = 0
            var pending = 0
            for device in devices {
                let report = try await device.replica.sync()
                pulled += report.pulled
                pending += report.pending
            }
            if pulled == 0 && pending == 0 { return }
        }
        Issue.record("devices did not settle")
    }
}

/// What a person can see on a device, for comparing replicas.
struct ReplicaSnapshot: Equatable {
    struct PackageView: Equatable {
        let name: String
        let status: PackageStatus
        let location: LocationID
        let quantity: Quantity
        let openedAt: Date?
        let confirmed: Set<PackageField>
        let events: [PackageEvent]
    }

    let records: RecordSet
    let packages: [PackageID: PackageView]
    let shopping: [ShoppingItem]

    static func of(_ device: Device, space: SpaceID) async throws -> ReplicaSnapshot {
        let records = await device.replica.records
        var packages: [PackageID: PackageView] = [:]
        for (id, result) in PackageRecords.materializeAll(from: records) {
            guard let package = result.entity else { continue }
            packages[id] = PackageView(
                name: package.name, status: package.status, location: package.location,
                quantity: package.quantity, openedAt: package.openedAt,
                confirmed: package.confirmedFields, events: package.events
            )
        }
        return ReplicaSnapshot(
            records: records, packages: packages, shopping: try await device.replica.list(in: space).items
        )
    }
}

/// Asserts every device shows the same state, and returns it.
@discardableResult
func expectConverged(_ devices: [Device], in world: World) async throws -> ReplicaSnapshot {
    let first = try await ReplicaSnapshot.of(devices[0], space: world.space)
    for device in devices.dropFirst() {
        let snapshot = try await ReplicaSnapshot.of(device, space: world.space)
        #expect(snapshot == first, "\(device.name) differs from \(devices[0].name)")
    }
    #expect(await world.cloud.records(zone: world.space) == first.records)
    return first
}

/// Field-level differences between two record sets, for readable failure messages.
func differences(_ left: RecordSet, _ right: RecordSet) -> [String] {
    let ids = Set(left.records.keys).union(right.records.keys)
    return ids.flatMap { id -> [String] in
        guard let l = left[id], let r = right[id] else { return ["\(id.kind.rawValue) only on one side"] }
        var found: [String] = []
        if l.created != r.created { found.append("\(id.kind.rawValue).created") }
        for name in Set(l.fields.keys).union(r.fields.keys) where l.fields[name] != r.fields[name] {
            found.append("\(id.kind.rawValue).\(name): \(String(describing: l.fields[name]?.value)) vs \(String(describing: r.fields[name]?.value))")
        }
        return found
    }
}
