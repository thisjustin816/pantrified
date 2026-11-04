import Foundation
import PantrifiedDomain

/// Everything a replica needs to resume after a crash at any point in a sync.
public struct ReplicaState: Sendable, Hashable, Codable {
    /// The replica's merged copy of every record, including its own unpushed writes.
    public var records = RecordSet()
    public var serverTags: [RecordID: ServerTag] = [:]
    /// Records holding writes the server has not confirmed.
    public var outbox: Set<RecordID> = []
    public var changeToken: ChangeToken?
    /// Persisted so a restarted replica never reissues a stamp it already used.
    public var clock: HybridClock

    public init(replica: ReplicaID) {
        clock = HybridClock(replica: replica)
    }
}

/// Durable storage for a replica's state. Saves are synchronous and all-or-nothing, so every step
/// of the replica completes or leaves the stored state as it was.
public protocol ReplicaStateStore: Sendable {
    func load() throws -> ReplicaState?
    func save(_ state: ReplicaState) throws
}

public enum ReplicaError: Error, Sendable, Equatable {
    case wrongSpace
}

public struct SyncReport: Sendable, Hashable {
    public var pushed = 0
    public var conflicts = 0
    public var failed = 0
    public var pulled = 0
    /// Records still waiting for the server after this sync.
    public var pending = 0
    /// The pull stopped at its page limit with more changes waiting on the server.
    public var morePending = false
}

/// One installation's copy of a shared Space. It is the local store for synchronized entities:
/// saving a package or changing the shopping list records the change for upload in the same step,
/// so a local change can never be lost between being made and being queued. Reads are built from
/// the merged records, so a local change and a remote one are never two competing copies.
public actor SpaceReplica: InventoryRepository, ShoppingListRepository {
    public let space: SpaceID
    private let transport: any SyncTransport
    private let store: any ReplicaStateStore
    private let time: any TimeSource
    private let maxPushRounds: Int
    private let maxPullPages: Int
    private var state: ReplicaState
    private var syncing = false

    /// `replica` identifies a replica whose store holds no state yet; a stored state keeps its own.
    public init(
        space: SpaceID,
        replica: ReplicaID,
        transport: any SyncTransport,
        store: any ReplicaStateStore,
        time: any TimeSource,
        maxPushRounds: Int = 4,
        maxPullPages: Int = 200
    ) throws {
        self.space = space
        self.transport = transport
        self.store = store
        self.time = time
        self.maxPushRounds = maxPushRounds
        self.maxPullPages = maxPullPages
        self.state = try store.load() ?? ReplicaState(replica: replica)
    }

    /// The ID this replica stamps its writes with.
    public var replicaID: ReplicaID { state.clock.replica }
    public var pendingCount: Int { state.outbox.count }
    public var records: RecordSet { state.records }

    /// Entities withheld because a record needs a newer version of the app.
    public var unreadablePackages: [PackageID] {
        PackageRecords.materializeAll(from: state.records).compactMap { id, result in
            if case .unreadable = result { return id }
            return nil
        }
    }

    // MARK: Inventory

    public func package(_ id: PackageID) async throws -> Package? {
        PackageRecords.materialize(id, from: state.records).entity
    }

    public func activePackages(in space: SpaceID) async throws -> [Package] {
        guard space == self.space else { return [] }
        return PackageRecords.materializeAll(from: state.records).values
            .compactMap(\.entity)
            .filter { $0.status == .active }
    }

    public func allPackages(in space: SpaceID) async throws -> [Package] {
        guard space == self.space else { return [] }
        return PackageRecords.materializeAll(from: state.records).values.compactMap(\.entity)
    }

    public func save(_ package: Package) async throws {
        try saveAll([package])
    }

    public func saveAll(_ packages: [Package]) throws {
        guard packages.allSatisfy({ $0.spaceID == space }) else { throw ReplicaError.wrongSpace }
        let now = time.now()
        try commit { state in
            for package in packages {
                state.stage(now: now) { PackageRecords.changes(in: package, against: $0, stamp: $1) }
            }
        }
    }

    // MARK: Shopping

    public func list(in space: SpaceID) async throws -> ShoppingList {
        guard space == self.space else { return ShoppingList() }
        return ShoppingRecords.materialize(from: state.records)
    }

    public func update<Result: Sendable>(
        in space: SpaceID,
        _ change: @Sendable (inout ShoppingList) throws -> Result
    ) async throws -> Result {
        guard space == self.space else { throw ReplicaError.wrongSpace }
        let now = time.now()
        return try commit { state in
            var list = ShoppingRecords.materialize(from: state.records)
            let result = try change(&list)
            state.stage(now: now) { ShoppingRecords.changes(from: list, against: $0, stamp: $1) }
            return result
        }
    }

    // MARK: Evidence

    /// Returns false, and records nothing, for a crop that may not upload its image.
    @discardableResult
    public func share(_ crop: EvidenceCrop) throws -> Bool {
        let now = time.now()
        return try commit { state in
            guard let record = EvidenceRecords.record(for: crop, at: state.clock.tick(now: now)) else { return false }
            state.write([record])
            return true
        }
    }

    public func evidence(for package: PackageID) -> [EvidenceCrop] {
        EvidenceRecords.materialize(from: state.records).filter { $0.packageID == package }
    }

    // MARK: Sync

    /// Pushes queued writes, then pulls everything new. Progress is saved after every exchange,
    /// so a failure or crash at any point resumes from the last saved step. A sync requested while
    /// one is running returns an empty report.
    @discardableResult
    public func sync() async throws -> SyncReport {
        guard !syncing else { return SyncReport() }
        syncing = true
        defer { syncing = false }

        var report = SyncReport()
        try await push(&report)
        try await pull(&report)
        report.pending = state.outbox.count
        return report
    }

    private func push(_ report: inout SyncReport) async throws {
        for _ in 0..<maxPushRounds {
            let outgoing = state.outbox
                .sorted { $0.entity.uuidString < $1.entity.uuidString }
                .compactMap { id in
                    state.records[id].map { OutgoingRecord(record: $0, knownTag: state.serverTags[id]) }
                }
            guard !outgoing.isEmpty else { return }

            let outcomes = try await transport.push(outgoing, zone: space)

            var progressed = false
            var round = report
            try commit { state in
                for sent in outgoing {
                    let id = sent.record.id
                    switch outcomes[id] ?? .failed {
                    case .saved(let tag):
                        state.serverTags[id] = tag
                        // A local write made while the push was in flight is still unconfirmed.
                        if state.records[id] == sent.record { state.outbox.remove(id) }
                        round.pushed += 1
                        progressed = true
                    case .conflict(let current, let tag):
                        state.serverTags[id] = tag
                        state.receive([current])
                        if state.records[id] == current { state.outbox.remove(id) }
                        round.conflicts += 1
                        progressed = true
                    case .failed:
                        round.failed += 1
                    }
                }
            }
            report = round
            guard progressed else { return }
        }
    }

    /// Stops after `maxPullPages` even if the server reports more, so a misbehaving server cannot
    /// hold a sync open forever; the saved token lets the next sync continue.
    private func pull(_ report: inout SyncReport) async throws {
        for _ in 0..<maxPullPages {
            let page = try await transport.pull(zone: space, since: state.changeToken)
            try commit { state in
                state.receive(page.records.map(\.record))
                for pulled in page.records {
                    state.serverTags[pulled.record.id] = pulled.tag
                }
                state.changeToken = page.token
            }
            report.pulled += page.records.count
            guard page.moreComing else { return }
        }
        report.morePending = true
    }

    /// Applies `change` to a copy of the state and adopts it only once it is stored.
    private func commit<Result>(_ change: (inout ReplicaState) throws -> Result) throws -> Result {
        var next = state
        let result = try change(&next)
        if next != state { try store.save(next) }
        state = next
        return result
    }
}

private extension ReplicaState {
    mutating func stage(now: Date, _ changes: (RecordSet, () -> HybridTimestamp) -> [SyncRecord]) {
        var clock = self.clock
        let written = changes(records) { clock.tick(now: now) }
        self.clock = clock
        write(written)
    }

    mutating func write(_ changes: [SyncRecord]) {
        for change in changes {
            records.merge(change)
            outbox.insert(change.id)
        }
    }

    /// Checks every incoming stamp before observing any, since observing one can move the clock
    /// past another installation's stamp and hide it. Taking a new ID stops two installations that
    /// share one from writing equal stamps from then on; stamps they already share are ordered by
    /// the record ID tie-break.
    mutating func receive(_ incoming: [SyncRecord]) {
        if incoming.contains(where: { $0.stamps.contains(where: clock.wasIssuedElsewhere) }) {
            clock.adopt(ReplicaID())
        }
        for record in incoming {
            clock.observe(record.latestStamp)
            records.merge(record)
        }
    }
}
