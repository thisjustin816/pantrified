#if canImport(SwiftData)
import Foundation
import SwiftData

/// The first stored schema. A released schema never changes: a change adds a new version and a
/// migration stage. Rows hold app-owned keys and encoded values; the layout is in
/// `docs/persistence.md`.
enum PantrifiedSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [StoredRecord.self, StoredReplicaHeader.self, StoredLocalRow.self]
    }

    @Model
    final class StoredRecord {
        @Attribute(.unique) var rowKey: String
        var spaceID: UUID
        var recordKind: String
        var entityID: UUID
        var payload: Data?
        var queued: Bool
        var serverTag: String?

        init(rowKey: String, spaceID: UUID, recordKind: String, entityID: UUID, payload: Data?, queued: Bool, serverTag: String?) {
            self.rowKey = rowKey
            self.spaceID = spaceID
            self.recordKind = recordKind
            self.entityID = entityID
            self.payload = payload
            self.queued = queued
            self.serverTag = serverTag
        }
    }

    @Model
    final class StoredReplicaHeader {
        @Attribute(.unique) var spaceID: UUID
        var payload: Data

        init(spaceID: UUID, payload: Data) {
            self.spaceID = spaceID
            self.payload = payload
        }
    }

    @Model
    final class StoredLocalRow {
        @Attribute(.unique) var rowKey: String
        var kind: String
        var spaceID: UUID
        var entityKey: String
        var payload: Data

        init(rowKey: String, kind: String, spaceID: UUID, entityKey: String, payload: Data) {
            self.rowKey = rowKey
            self.kind = kind
            self.spaceID = spaceID
            self.entityKey = entityKey
            self.payload = payload
        }
    }
}

/// The schema this build opens. Its major version is `StoreSchema.current`.
typealias CurrentSchema = PantrifiedSchemaV1

enum PantrifiedMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [PantrifiedSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
#endif
