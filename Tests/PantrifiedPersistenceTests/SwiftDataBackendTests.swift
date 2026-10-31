#if canImport(SwiftData)
import Foundation
import SwiftData
import Testing
import PantrifiedApplication
import PantrifiedDomain
import PantrifiedTestSupport
@testable import PantrifiedPersistence

/// A second schema as a later version of the app would add it: the first schema's models with one
/// new optional attribute. Entity names match the first schema's, as a lightweight stage requires.
enum TestSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

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
        var note: String?

        init(rowKey: String, spaceID: UUID, recordKind: String, entityID: UUID, payload: Data?, queued: Bool, serverTag: String?, note: String?) {
            self.rowKey = rowKey
            self.spaceID = spaceID
            self.recordKind = recordKind
            self.entityID = entityID
            self.payload = payload
            self.queued = queued
            self.serverTag = serverTag
            self.note = note
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

enum TestMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [PantrifiedSchemaV1.self, TestSchemaV2.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: PantrifiedSchemaV1.self, toVersion: TestSchemaV2.self)]
    }
}

private struct Rejected: Error {}

@Suite("SwiftData backend")
struct SwiftDataBackendTests {
    private let space = SpaceID()

    private func storedState(in files: StoreFiles) throws -> ReplicaState? {
        try PersistentReplicaStateStore(space: space, backend: SwiftDataBackend.open(files)).load()
    }

    @Test("the store's configuration keeps SwiftData's automatic CloudKit sync off")
    func automaticCloudKitSyncIsOff() throws {
        let none = String(describing: ModelConfiguration.CloudKitDatabase.none)
        let automatic = String(describing: ModelConfiguration.CloudKitDatabase.automatic)
        let backend = try SwiftDataBackend.open(temporaryStoreFiles())

        // The comparison is by description, so it is shown first to tell the two settings apart.
        #expect(none != automatic)
        #expect(!backend.container.configurations.isEmpty)
        for configuration in backend.container.configurations {
            #expect(String(describing: configuration.cloudKitDatabase) == none)
            #expect(configuration.cloudKitContainerIdentifier == nil)
        }
    }

    @Test("the migration plan ends at the schema this build opens, numbered as the store schema")
    func planEndsAtCurrentSchema() {
        let last = PantrifiedMigrationPlan.schemas.last
        #expect(last.map(ObjectIdentifier.init) == ObjectIdentifier(CurrentSchema.self))
        #expect(CurrentSchema.versionIdentifier.major == StoreSchema.current)
        #expect(PantrifiedMigrationPlan.schemas.count == PantrifiedMigrationPlan.stages.count + 1)
    }

    @Test("a replica state saved to disk reads back equal after the container is recreated")
    func stateSurvivesRelaunch() async throws {
        let files = temporaryStoreFiles()
        var state = sampleState(seed: 4, records: 30)
        state.changeToken = ChangeToken("after relaunch")
        let fridge = StorageLocation(name: "Fridge", storageType: .refrigerated)
        do {
            let backend = try SwiftDataBackend.open(files)
            try PersistentReplicaStateStore(space: space, backend: backend).save(state)
            var batch = StorageBatch()
            batch.localWrites[LocalRowKey(kind: .location, space: space, entity: fridge.id.rawValue.uuidString)] =
                .put(StoredValueCoding.encode(.map(["name": .string("Fridge"), "storageType": .string("refrigerated"), "position": .int(0)])))
            try backend.write(batch)
        }

        #expect(try storedState(in: files) == state)
        #expect(try await PersistentLocations(backend: SwiftDataBackend.open(files)).locations(in: space) == [fridge])
    }

    @Test("a save that fails after its rows are staged and before they commit leaves the stored state")
    func failureBeforeCommitKeepsStoredState() throws {
        let files = temporaryStoreFiles()
        let first = sampleState(seed: 5)
        try PersistentReplicaStateStore(space: space, backend: SwiftDataBackend.open(files)).save(first)
        let failing = try SwiftDataBackend.open(files, beforeCommit: { throw Rejected() })
        var second = first
        second.changeToken = ChangeToken("never stored")
        second.outbox.removeAll()

        #expect(throws: Rejected.self) {
            try PersistentReplicaStateStore(space: space, backend: failing).save(second)
        }

        #expect(try storedState(in: files) == first)
    }

    @Test("a file that is not a store is reported as unopenable and left byte for byte")
    func unopenableStoreIsKept() throws {
        let files = temporaryStoreFiles()
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        let garbage = Data("not a database, and not to be deleted".utf8)
        try garbage.write(to: files.store)

        #expect {
            _ = try SwiftDataBackend.open(files)
        } throws: { error in
            if case PersistenceError.cannotOpen = error { return true }
            return false
        }

        #expect(try Data(contentsOf: files.store) == garbage)
    }

    @Test("a store migrates from the first schema to a later one with every row intact")
    func migratesFromFirstSchema() throws {
        let files = temporaryStoreFiles()
        let state = sampleState(seed: 6)
        try PersistentReplicaStateStore(space: space, backend: SwiftDataBackend.open(files)).save(state)

        let container = try ModelContainer(
            for: Schema(versionedSchema: TestSchemaV2.self),
            migrationPlan: TestMigrationPlan.self,
            configurations: [ModelConfiguration(schema: Schema(versionedSchema: TestSchemaV2.self), url: files.store, cloudKitDatabase: .none)]
        )
        let rows = try ModelContext(container).fetch(FetchDescriptor<TestSchemaV2.StoredRecord>())

        #expect(rows.count == Set(state.records.records.keys).union(state.outbox).union(state.serverTags.keys).count)
        #expect(rows.allSatisfy { $0.note == nil })
        for row in rows {
            let id = RecordID(kind: RecordKind(rawValue: row.recordKind), entity: row.entityID)
            #expect(try row.payload.map(StoredValueCoding.record(from:)) == state.records[id])
            #expect(row.queued == state.outbox.contains(id))
        }
    }

    @Test("a store a newer schema has opened is refused, and the newer version still reads it")
    func newerSchemaIsRefused() throws {
        let files = temporaryStoreFiles()
        let state = sampleState(seed: 7)
        try PersistentReplicaStateStore(space: space, backend: SwiftDataBackend.open(files)).save(state)
        let configuration = ModelConfiguration(schema: Schema(versionedSchema: TestSchemaV2.self), url: files.store, cloudKitDatabase: .none)
        _ = try StoreOpening.open(files, schema: 2) {
            try ModelContainer(for: Schema(versionedSchema: TestSchemaV2.self), migrationPlan: TestMigrationPlan.self, configurations: [configuration])
        }

        #expect(throws: PersistenceError.newerSchema(found: 2, supported: StoreSchema.current)) {
            try SwiftDataBackend.open(files)
        }

        let newer = try ModelContainer(for: Schema(versionedSchema: TestSchemaV2.self), migrationPlan: TestMigrationPlan.self, configurations: [configuration])
        #expect(try ModelContext(newer).fetchCount(FetchDescriptor<TestSchemaV2.StoredRecord>()) == state.records.records.count)
    }

    @Test("concurrent saves of several Spaces and local rows through one container all persist")
    func concurrentWritersPersist() async throws {
        let files = temporaryStoreFiles()
        let backend = try SwiftDataBackend.open(files)
        let spaces = (0..<6).map { _ in SpaceID() }
        let states = try await withThrowingTaskGroup(of: (SpaceID, ReplicaState).self) { group in
            for (index, space) in spaces.enumerated() {
                group.addTask {
                    let store = PersistentReplicaStateStore(space: space, backend: backend)
                    var state = sampleState(seed: UInt64(index + 10), records: 4)
                    try store.save(state)
                    state.changeToken = ChangeToken("second")
                    try store.save(state)
                    try await PersistentLocations(backend: backend).save(StorageLocation(name: "Shelf \(index)", storageType: .roomTemperature), in: space)
                    return (space, state)
                }
            }
            return try await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }

        let reopened = try SwiftDataBackend.open(files)
        for space in spaces {
            #expect(try PersistentReplicaStateStore(space: space, backend: reopened).load() == states[space])
            #expect(try reopened.localRows(of: .location, in: space).count == 1)
        }
    }
}

#endif
