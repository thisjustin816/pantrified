import Foundation
import PantrifiedApplication
import PantrifiedDomain

/// A replica's state as rows: one header holding the clock and change token, and one row per
/// record ID holding the record, whether it is queued for upload, and its last server tag.
enum ReplicaRowMapping {
    static func header(of state: ReplicaState) -> Data {
        var writer = ByteWriter(version: StoredValueCoding.version)
        writer.stamp(state.clock.latest)
        if let token = state.changeToken {
            writer.byte(1)
            writer.string(token.rawValue)
        } else {
            writer.byte(0)
        }
        return writer.data
    }

    /// Nil when the Space has never been stored.
    static func state(from rows: StoredReplicaRows) throws(PersistenceError) -> ReplicaState? {
        guard let header = rows.header else {
            guard rows.records.isEmpty else { throw .corrupt("records without a replica header") }
            return nil
        }
        var reader = try ByteReader(header, version: StoredValueCoding.version)
        let latest = try reader.stamp()
        var state = ReplicaState(replica: latest.replica)
        state.clock = HybridClock(resuming: latest)
        switch try reader.byte() {
        case 0: break
        case 1: state.changeToken = ChangeToken(try reader.string())
        default: throw .corrupt("invalid replica header")
        }
        try reader.finish()

        for row in rows.records {
            if let payload = row.payload {
                let record = try StoredValueCoding.record(from: payload)
                guard record.id == row.id else { throw .corrupt("a stored row holding another record") }
                state.records.merge(record)
            }
            if row.queued { state.outbox.insert(row.id) }
            if let tag = row.serverTag { state.serverTags[row.id] = ServerTag(tag) }
        }
        // The replica that owns a Space has already observed every stamp it stores, so this
        // changes nothing for it. A header written by a second writer that had seen less would
        // otherwise let the clock reissue stamps earlier than ones already stored.
        for record in state.records.records.values {
            state.clock.observe(record.latestStamp)
        }
        return state
    }

    /// The writes that turn the stored `old` into `new`: the header when the clock or token
    /// changed, and a row write for each ID whose record, queue entry or server tag changed. An
    /// unchanged record is not rewritten. `old` is nil when nothing is stored yet.
    static func batch(from old: ReplicaState?, to new: ReplicaState, in space: SpaceID) -> StorageBatch {
        var batch = StorageBatch()
        if old?.clock != new.clock || old?.changeToken != new.changeToken || old == nil {
            batch.replicaHeaders[space] = header(of: new)
        }

        var ids = Set(new.records.records.keys).union(new.serverTags.keys).union(new.outbox)
        if let old {
            ids.formUnion(old.serverTags.keys)
            ids.formUnion(old.outbox)
        }
        var writes: [RecordRowWrite] = []
        for id in ids {
            let record = new.records[id]
            let queued = new.outbox.contains(id)
            let tag = new.serverTags[id]
            let recordChanged = old?.records[id] != record || old == nil
            guard recordChanged || old?.outbox.contains(id) != queued || old?.serverTags[id] != tag else { continue }
            writes.append(RecordRowWrite(id: id, record: recordChanged ? record : nil, queued: queued, serverTag: tag?.rawValue))
        }
        if !writes.isEmpty { batch.recordWrites[space] = writes }
        return batch
    }
}

/// Keeps one Space's replica state in a backend. Each save writes only the rows that differ from
/// the last state stored, as one batch, so a save either stores the whole new state or leaves the
/// previous one.
///
/// One store, and one replica, owns a Space at a time. Writes merge records into what is stored,
/// so a second writer cannot erase a record, but the queue, tags and clock it writes would
/// replace the owner's.
public final class PersistentReplicaStateStore: ReplicaStateStore, @unchecked Sendable {
    private enum Base {
        case unknown
        case stored(ReplicaState?)
    }

    private let space: SpaceID
    private let backend: any StorageBackend
    private let lock = NSLock()
    /// The state the backend holds, guarded by `lock`. After a failed write it is unknown, since
    /// the write may have committed, and it is read again before the next save.
    private var base = Base.unknown

    public init(space: SpaceID, backend: any StorageBackend) {
        self.space = space
        self.backend = backend
    }

    public func load() throws -> ReplicaState? {
        try lock.withLock {
            let state = try ReplicaRowMapping.state(from: backend.replicaRows(in: space))
            base = .stored(state)
            return state
        }
    }

    public func save(_ state: ReplicaState) throws {
        try lock.withLock {
            let old: ReplicaState?
            switch base {
            case .stored(let stored): old = stored
            case .unknown: old = try ReplicaRowMapping.state(from: backend.replicaRows(in: space))
            }
            let batch = ReplicaRowMapping.batch(from: old, to: state, in: space)
            if !batch.isEmpty {
                do {
                    try backend.write(batch)
                } catch {
                    base = .unknown
                    throw error
                }
            }
            base = .stored(state)
        }
    }
}
