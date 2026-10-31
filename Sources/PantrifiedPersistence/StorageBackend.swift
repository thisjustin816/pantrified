import Foundation
import PantrifiedDomain

/// One stored synchronized record and the replica's sync metadata for it.
public struct RecordRow: Sendable, Hashable {
    public let id: RecordID
    /// The record in `StoredValueCoding`. Nil when only sync metadata is stored for the ID.
    public var payload: Data?
    /// The record holds a write the server has not confirmed.
    public var queued: Bool
    public var serverTag: String?

    public init(id: RecordID, payload: Data?, queued: Bool, serverTag: String?) {
        self.id = id
        self.payload = payload
        self.queued = queued
        self.serverTag = serverTag
    }
}

/// A write to one record row. The record is merged into the stored copy rather than replacing it,
/// so a writer holding a stale copy can never erase a field write stored since it read. The queue
/// flag and server tag replace the stored ones.
public struct RecordRowWrite: Sendable, Hashable {
    public let id: RecordID
    /// Nil leaves the stored record as it is.
    public var record: SyncRecord?
    public var queued: Bool
    public var serverTag: String?

    public init(id: RecordID, record: SyncRecord?, queued: Bool, serverTag: String?) {
        self.id = id
        self.record = record
        self.queued = queued
        self.serverTag = serverTag
    }

    /// The row to store in place of `stored`, or nil when the row is left holding nothing and is
    /// removed. Every backend applies writes through this, so they all merge identically.
    public func resolve(over stored: RecordRow?) throws(PersistenceError) -> RecordRow? {
        var payload = stored?.payload
        if let record {
            guard record.id == id else { throw .corrupt("a write holding another record") }
            var merged = record
            if let payload {
                let existing = try StoredValueCoding.record(from: payload)
                guard existing.id == id else { throw .corrupt("a stored row holding another record") }
                merged = existing.merged(with: record)
            }
            payload = StoredValueCoding.encode(merged)
        }
        guard payload != nil || queued || serverTag != nil else { return nil }
        return RecordRow(id: id, payload: payload, queued: queued, serverTag: serverTag)
    }
}

/// A replica's stored rows for one Space.
public struct StoredReplicaRows: Sendable, Hashable {
    /// The encoded clock and change token. Nil when the Space has never been stored.
    public var header: Data?
    public var records: [RecordRow]

    public init(header: Data?, records: [RecordRow]) {
        self.header = header
        self.records = records
    }
}

/// The kind of a device-local row. An open string, so a kind written by a newer version is kept.
public struct LocalRowKind: RawRepresentable, Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let location = LocalRowKind(rawValue: "location")
    public static let ingredientLink = LocalRowKind(rawValue: "ingredientLink")
    public static let packageBarcode = LocalRowKind(rawValue: "packageBarcode")
}

/// Identifies a device-local row: its kind, its Space, and the entity's app-owned key.
public struct LocalRowKey: Sendable, Hashable {
    public let kind: LocalRowKind
    public let space: SpaceID
    public let entity: String

    public init(kind: LocalRowKind, space: SpaceID, entity: String) {
        self.kind = kind
        self.space = space
        self.entity = entity
    }
}

/// A device-local row: state that belongs to this installation and is never synchronized.
public struct LocalRow: Sendable, Hashable {
    public let key: LocalRowKey
    /// A value in `StoredValueCoding`.
    public var payload: Data

    public init(key: LocalRowKey, payload: Data) {
        self.key = key
        self.payload = payload
    }
}

public enum LocalRowWrite: Sendable, Hashable {
    case put(Data)
    case remove
}

/// Changes a backend applies all together or not at all.
public struct StorageBatch: Sendable {
    public var replicaHeaders: [SpaceID: Data] = [:]
    public var recordWrites: [SpaceID: [RecordRowWrite]] = [:]
    public var localWrites: [LocalRowKey: LocalRowWrite] = [:]

    public init() {}

    public var isEmpty: Bool {
        replicaHeaders.isEmpty && recordWrites.isEmpty && localWrites.isEmpty
    }
}

/// Where rows are kept. Reads see only committed writes. `write` applies a whole batch or, when it
/// throws, none of it, and implementations serialize writes so two batches never interleave.
public protocol StorageBackend: Sendable {
    func replicaRows(in space: SpaceID) throws -> StoredReplicaRows
    func localRows(of kind: LocalRowKind, in space: SpaceID) throws -> [LocalRow]
    func write(_ batch: StorageBatch) throws
}

/// The unique keys rows are stored under. Space and entity UUIDs have a fixed length and come
/// first, so an open-ended kind or local key can never make two rows collide.
public enum RowKey {
    public static func record(_ id: RecordID, in space: SpaceID) -> String {
        "\(space.rawValue.uuidString)/\(id.entity.uuidString)/\(id.kind.rawValue)"
    }

    public static func local(_ key: LocalRowKey) -> String {
        "\(key.space.rawValue.uuidString)/\(key.kind.rawValue.utf8.count)/\(key.kind.rawValue)/\(key.entity)"
    }
}

/// Rows kept in memory, with the same merge and all-or-nothing rules as a durable backend. For
/// previews and tests; nothing in it outlives the process.
public final class InMemoryStorageBackend: StorageBackend, @unchecked Sendable {
    private struct Contents {
        var headers: [SpaceID: Data] = [:]
        var records: [SpaceID: [RecordID: RecordRow]] = [:]
        var locals: [LocalRowKey: Data] = [:]
    }

    private let lock = NSLock()
    /// Guarded by `lock`.
    private var contents = Contents()

    public init() {}

    public func replicaRows(in space: SpaceID) throws -> StoredReplicaRows {
        lock.withLock {
            StoredReplicaRows(header: contents.headers[space], records: Array((contents.records[space] ?? [:]).values))
        }
    }

    public func localRows(of kind: LocalRowKind, in space: SpaceID) throws -> [LocalRow] {
        lock.withLock {
            contents.locals
                .filter { $0.key.kind == kind && $0.key.space == space }
                .map { LocalRow(key: $0.key, payload: $0.value) }
        }
    }

    public func write(_ batch: StorageBatch) throws {
        try lock.withLock {
            var next = contents
            for (space, header) in batch.replicaHeaders {
                next.headers[space] = header
            }
            for (space, writes) in batch.recordWrites {
                for write in writes {
                    next.records[space, default: [:]][write.id] = try write.resolve(over: next.records[space]?[write.id])
                }
            }
            for (key, write) in batch.localWrites {
                switch write {
                case .put(let payload): next.locals[key] = payload
                case .remove: next.locals[key] = nil
                }
            }
            contents = next
        }
    }
}
