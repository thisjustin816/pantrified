#if canImport(SwiftData)
import Foundation
import PantrifiedDomain
import SwiftData

/// Rows kept in a SwiftData store. SwiftData holds keys, flags and encoded values only; what the
/// rows mean is decided by the plain Swift mapping above it.
///
/// Every call makes its own `ModelContext` and finishes with it before returning, so no context
/// is shared across threads, and calls are serialized so two batches never interleave. A write
/// stages a whole batch in one context and saves it once, which commits it as one transaction;
/// a failure before or during the save discards the context and stores nothing.
public final class SwiftDataBackend: StorageBackend {
    let container: ModelContainer
    private let lock = NSLock()
    /// Runs after a batch is staged and before it is saved. Tests use it to fail at that point.
    private let beforeCommit: (@Sendable () throws -> Void)?

    private typealias Record = CurrentSchema.StoredRecord
    private typealias Header = CurrentSchema.StoredReplicaHeader
    private typealias Local = CurrentSchema.StoredLocalRow

    private init(configuration: ModelConfiguration, beforeCommit: (@Sendable () throws -> Void)?) throws {
        container = try ModelContainer(
            for: Schema(versionedSchema: CurrentSchema.self),
            migrationPlan: PantrifiedMigrationPlan.self,
            configurations: [configuration]
        )
        self.beforeCommit = beforeCommit
    }

    /// Opens or creates the store in `files`, migrating it to the current schema. A store that
    /// cannot be opened is reported and left in place; it is never deleted or recreated.
    public static func open(_ files: StoreFiles) throws(PersistenceError) -> SwiftDataBackend {
        try open(files, beforeCommit: nil)
    }

    static func open(_ files: StoreFiles, beforeCommit: (@Sendable () throws -> Void)?) throws(PersistenceError) -> SwiftDataBackend {
        try StoreOpening.open(files) {
            try SwiftDataBackend(
                configuration: ModelConfiguration(
                    schema: Schema(versionedSchema: CurrentSchema.self),
                    url: files.store,
                    cloudKitDatabase: .none
                ),
                beforeCommit: beforeCommit
            )
        }
    }

    public func replicaRows(in space: SpaceID) throws -> StoredReplicaRows {
        try lock.withLock {
            let context = ModelContext(container)
            let id = space.rawValue
            let header = try context.fetch(FetchDescriptor<Header>(predicate: #Predicate { $0.spaceID == id })).first
            let records = try context.fetch(FetchDescriptor<Record>(predicate: #Predicate { $0.spaceID == id }))
            return StoredReplicaRows(header: header?.payload, records: records.map(Self.row))
        }
    }

    public func localRows(of kind: LocalRowKind, in space: SpaceID) throws -> [LocalRow] {
        try lock.withLock {
            let context = ModelContext(container)
            let id = space.rawValue
            let name = kind.rawValue
            let rows = try context.fetch(FetchDescriptor<Local>(predicate: #Predicate { $0.spaceID == id && $0.kind == name }))
            return rows.map { LocalRow(key: LocalRowKey(kind: kind, space: space, entity: $0.entityKey), payload: $0.payload) }
        }
    }

    public func write(_ batch: StorageBatch) throws {
        guard !batch.isEmpty else { return }
        try lock.withLock {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            for (space, payload) in batch.replicaHeaders {
                try stageHeader(payload, for: space, in: context)
            }
            for (space, writes) in batch.recordWrites {
                try stage(writes, in: space, context: context)
            }
            try stageLocal(batch.localWrites, in: context)
            try beforeCommit?()
            try context.save()
        }
    }

    private func stageHeader(_ payload: Data, for space: SpaceID, in context: ModelContext) throws {
        let id = space.rawValue
        if let header = try context.fetch(FetchDescriptor<Header>(predicate: #Predicate { $0.spaceID == id })).first {
            header.payload = payload
        } else {
            context.insert(Header(spaceID: id, payload: payload))
        }
    }

    private func stage(_ writes: [RecordRowWrite], in space: SpaceID, context: ModelContext) throws {
        var stored = try fetch(Record.self, keys: writes.map { RowKey.record($0.id, in: space) }, in: context)
        for write in writes {
            let key = RowKey.record(write.id, in: space)
            let model = stored[key]
            switch try write.resolve(over: model.map(Self.row)) {
            case nil:
                if let model {
                    context.delete(model)
                    stored[key] = nil
                }
            case let row?:
                if let model {
                    model.payload = row.payload
                    model.queued = row.queued
                    model.serverTag = row.serverTag
                } else {
                    let inserted = Record(
                        rowKey: key, spaceID: space.rawValue, recordKind: row.id.kind.rawValue, entityID: row.id.entity,
                        payload: row.payload, queued: row.queued, serverTag: row.serverTag
                    )
                    context.insert(inserted)
                    stored[key] = inserted
                }
            }
        }
    }

    private func stageLocal(_ writes: [LocalRowKey: LocalRowWrite], in context: ModelContext) throws {
        guard !writes.isEmpty else { return }
        let stored = try fetch(Local.self, keys: writes.keys.map(RowKey.local), in: context)
        for (key, write) in writes {
            let rowKey = RowKey.local(key)
            switch (write, stored[rowKey]) {
            case (.put(let payload), let model?):
                model.payload = payload
            case (.put(let payload), nil):
                context.insert(Local(rowKey: rowKey, kind: key.kind.rawValue, spaceID: key.space.rawValue, entityKey: key.entity, payload: payload))
            case (.remove, let model?):
                context.delete(model)
            case (.remove, nil):
                break
            }
        }
    }

    /// The stored models with these unique keys, fetched in chunks small enough for one query.
    private func fetch<Model: KeyedRow>(_ type: Model.Type, keys: [String], in context: ModelContext) throws -> [String: Model] {
        var found: [String: Model] = [:]
        let unique = Array(Set(keys))
        for start in stride(from: 0, to: unique.count, by: 500) {
            let chunk = Array(unique[start..<min(start + 500, unique.count)])
            for model in try context.fetch(FetchDescriptor<Model>(predicate: Model.matching(chunk))) {
                found[model.rowKey] = model
            }
        }
        return found
    }

    private static func row(_ model: Record) -> RecordRow {
        RecordRow(
            id: RecordID(kind: RecordKind(rawValue: model.recordKind), entity: model.entityID),
            payload: model.payload, queued: model.queued, serverTag: model.serverTag
        )
    }
}

/// A model stored under a unique row key.
private protocol KeyedRow: PersistentModel {
    var rowKey: String { get }
    static func matching(_ keys: [String]) -> Predicate<Self>
}

extension CurrentSchema.StoredRecord: KeyedRow {
    fileprivate static func matching(_ keys: [String]) -> Predicate<CurrentSchema.StoredRecord> {
        #Predicate { keys.contains($0.rowKey) }
    }
}

extension CurrentSchema.StoredLocalRow: KeyedRow {
    fileprivate static func matching(_ keys: [String]) -> Predicate<CurrentSchema.StoredLocalRow> {
        #Predicate { keys.contains($0.rowKey) }
    }
}
#endif
