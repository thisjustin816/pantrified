#if canImport(SwiftData)
import Foundation
import PantrifiedDomain
import SwiftData

public final class SwiftDataBackend: StorageBackend {
    let container: ModelContainer
    private let lock = NSLock()
    private let beforeCommit: (@Sendable () throws -> Void)?

    init(configuration: ModelConfiguration, beforeCommit: (@Sendable () throws -> Void)? = nil) throws {
        container = try ModelContainer(
            for: Schema(versionedSchema: CurrentSchema.self),
            migrationPlan: PantrifiedMigrationPlan.self,
            configurations: [configuration]
        )
        self.beforeCommit = beforeCommit
    }

    public static func open(_ files: StoreFiles) throws(PersistenceError) -> SwiftDataBackend {
        try open(files, beforeCommit: nil)
    }

    static func open(_ files: StoreFiles, beforeCommit: (@Sendable () throws -> Void)?) throws(PersistenceError) -> SwiftDataBackend {
        try StoreOpening.open(files) {
            try SwiftDataBackend(configuration: configuration(storingAt: files.store), beforeCommit: beforeCommit)
        }
    }

    static func configuration(storingAt url: URL) -> ModelConfiguration {
        ModelConfiguration(schema: Schema(versionedSchema: CurrentSchema.self), url: url, cloudKitDatabase: .none)
    }

    public func replicaRows(in space: SpaceID) throws -> StoredReplicaRows {
        StoredReplicaRows(header: nil, records: [])
    }

    public func localRows(of kind: LocalRowKind, in space: SpaceID) throws -> [LocalRow] {
        []
    }

    public func write(_ batch: StorageBatch) throws {}
}
#endif
