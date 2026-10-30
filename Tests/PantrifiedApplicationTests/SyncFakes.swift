import Foundation
import PantrifiedApplication
import PantrifiedDomain
import PantrifiedTestSupport

struct Unreachable: Error {}

/// The shared server: per-zone current records with version tags and a change log. Like CloudKit,
/// it rejects a write made without having seen the current version and never merges by itself.
actor InMemoryCloud {
    private struct Entry {
        let seq: Int
        let record: SyncRecord
    }

    private var current: [SpaceID: [RecordID: Entry]] = [:]
    private var log: [SpaceID: [Entry]] = [:]
    private var seq = 0

    func push(
        _ outgoing: [OutgoingRecord],
        zone: SpaceID,
        failing: Set<RecordID>,
        unconfirmed: Int
    ) -> (outcomes: [RecordID: PushOutcome], unconfirmed: Int) {
        var unconfirmed = unconfirmed
        var outcomes: [RecordID: PushOutcome] = [:]
        for item in outgoing {
            let id = item.record.id
            if failing.contains(id) {
                outcomes[id] = .failed
                continue
            }
            if let existing = current[zone]?[id], item.knownTag != tag(existing.seq) {
                outcomes[id] = .conflict(current: existing.record, tag: tag(existing.seq))
                continue
            }
            seq += 1
            let entry = Entry(seq: seq, record: item.record)
            current[zone, default: [:]][id] = entry
            log[zone, default: []].append(entry)
            if unconfirmed > 0 {
                unconfirmed -= 1
                outcomes[id] = .failed
            } else {
                outcomes[id] = .saved(tag(seq))
            }
        }
        return (outcomes, unconfirmed)
    }

    func latestSeq() -> Int { seq }

    /// Records changed in `(after, through]`. With `history`, every version written in that range,
    /// including superseded ones; otherwise each changed record once, in its current version, as a
    /// real server returns it.
    func changes(zone: SpaceID, after: Int, through: Int, history: Bool) -> [PulledRecord] {
        let entries = (log[zone] ?? []).filter { $0.seq > after && $0.seq <= through }
        let chosen: [Entry]
        if history {
            chosen = entries
        } else {
            var seen: Set<RecordID> = []
            chosen = entries.compactMap { entry in
                guard seen.insert(entry.record.id).inserted else { return nil }
                return current[zone]?[entry.record.id]
            }
        }
        return chosen.map { PulledRecord(record: $0.record, tag: tag($0.seq)) }
    }

    func records(zone: SpaceID) -> RecordSet {
        var set = RecordSet()
        for entry in (current[zone] ?? [:]).values { set.merge(entry.record) }
        return set
    }

    private func tag(_ seq: Int) -> ServerTag { ServerTag("\(seq)") }
}

/// One replica's connection to the cloud, with the faults that connection suffers.
final class CloudLink: SyncTransport, @unchecked Sendable {
    struct Faults {
        var offline = false
        var pageSize = 50
        /// Shuffles each pull's records, so events can arrive before their package.
        var shuffleSeed: UInt64?
        /// Delivers every pulled record twice.
        var duplicates = false
        /// Delivers every version written, including ones already superseded.
        var history = false
        var failingRecords: Set<RecordID> = []
        /// The next N writes are stored but reported as failed.
        var unconfirmedWrites = 0
        /// Pull pages served before pulls start failing.
        var pullPagesBeforeFailure: Int?
    }

    let cloud: InMemoryCloud
    private let lock = NSLock()
    private var current: Faults
    private var hook: (@Sendable () async -> Void)?

    /// Runs while the replica waits on a push, before the cloud sees it.
    var beforePush: (@Sendable () async -> Void)? {
        get { lock.withLock { hook } }
        set { lock.withLock { hook = newValue } }
    }

    init(_ cloud: InMemoryCloud, faults: Faults = Faults()) {
        self.cloud = cloud
        self.current = faults
    }

    var faults: Faults {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    func push(_ records: [OutgoingRecord], zone: SpaceID) async throws -> [RecordID: PushOutcome] {
        await beforePush?()
        let faults = self.faults
        guard !faults.offline else { throw Unreachable() }
        let result = await cloud.push(
            records, zone: zone, failing: faults.failingRecords, unconfirmed: faults.unconfirmedWrites
        )
        lock.withLock { current.unconfirmedWrites = result.unconfirmed }
        return result.outcomes
    }

    /// Tokens are "base" for a fresh pull or "base:end:offset" inside a paged one, so a resumed pull
    /// continues the same, identically shuffled, delivery.
    func pull(zone: SpaceID, since token: ChangeToken?) async throws -> PullPage {
        let faults = self.faults
        guard !faults.offline else { throw Unreachable() }
        if let remaining = faults.pullPagesBeforeFailure {
            guard remaining > 0 else { throw Unreachable() }
            lock.withLock { current.pullPagesBeforeFailure = remaining - 1 }
        }

        let parts = (token?.rawValue ?? "0").split(separator: ":").compactMap { Int($0) }
        let base = parts[0]
        let end = parts.count == 3 ? parts[1] : await cloud.latestSeq()
        let offset = parts.count == 3 ? parts[2] : 0

        var delivery = await cloud.changes(zone: zone, after: base, through: end, history: faults.history)
        if faults.duplicates { delivery += delivery }
        if let seed = faults.shuffleSeed {
            var rng = SeededGenerator(seed: seed &+ UInt64(base) &* 1_000_003 &+ UInt64(end))
            delivery.shuffle(using: &rng)
        }

        let page = Array(delivery.dropFirst(offset).prefix(faults.pageSize))
        let next = offset + page.count
        if next < delivery.count {
            return PullPage(records: page, token: ChangeToken("\(base):\(end):\(next)"), moreComing: true)
        }
        return PullPage(records: page, token: ChangeToken("\(end)"), moreComing: false)
    }
}

/// Holds the last state a replica saved. `savesBeforeCrash` makes a later save fail as if the
/// process died during it, leaving the previous state stored.
final class InMemoryReplicaStore: ReplicaStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ReplicaState?
    private var remaining: Int?
    private(set) var saves = 0

    init(_ state: ReplicaState? = nil) {
        stored = state
    }

    var state: ReplicaState? { lock.withLock { stored } }

    func crash(afterSaves count: Int?) {
        lock.withLock { remaining = count }
    }

    func load() throws -> ReplicaState? {
        lock.withLock { stored }
    }

    func save(_ state: ReplicaState) throws {
        try lock.withLock {
            if let left = remaining {
                guard left > 0 else { throw FakeFailure() }
                remaining = left - 1
            }
            stored = state
            saves += 1
        }
    }
}
