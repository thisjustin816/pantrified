import Foundation
import PantrifiedPersistence

/// Opens the app's local store. The interface does not read from it yet.
enum LocalPersistence {
    static func open(_ files: StoreFiles) throws(PersistenceError) -> LocalStore {
        LocalStore(backend: try SwiftDataBackend.open(files))
    }
}

#if DEBUG
import PantrifiedApplication
import PantrifiedDomain

extension LocalPersistence {
    struct RelaunchCheck: Sendable {
        let packageName: String?
        let locationNames: [String]
        let protection: String?
        let excludedFromBackup: Bool?
    }

    /// Saves a package and a location, drops the store, opens it again from `directory` and reads
    /// them back, so a hosted test can show the store works inside the app's sandbox.
    static func relaunchCheck(in directory: URL) async throws -> RelaunchCheck {
        let files = StoreFiles(directory: directory)
        let space = SpaceID()
        let fridge = StorageLocation(name: "Fridge", storageType: .refrigerated)
        let package = Package(spaceID: space, name: "Milk", location: fridge.id, addedAt: Date())
        do {
            let store = try open(files)
            try await store.replica(for: space, transport: Offline(), time: SystemTime()).save(package)
            try await store.locations.save(fridge, in: space)
        }

        let reopened = try open(files)
        let name = try await reopened.replica(for: space, transport: Offline(), time: SystemTime()).package(package.id)?.name
        let locations = try await reopened.locations.locations(in: space).map(\.name)
        let values = try files.store.resourceValues(forKeys: [.fileProtectionKey, .isExcludedFromBackupKey])
        return RelaunchCheck(
            packageName: name,
            locationNames: locations,
            protection: values.fileProtection?.rawValue,
            excludedFromBackup: values.isExcludedFromBackup
        )
    }

    private struct Offline: SyncTransport {
        struct Unreachable: Error {}

        func push(_ records: [OutgoingRecord], zone: SpaceID) async throws -> [RecordID: PushOutcome] { throw Unreachable() }
        func pull(zone: SpaceID, since token: ChangeToken?) async throws -> PullPage { throw Unreachable() }
    }

    private struct SystemTime: TimeSource {
        func now() -> Date { Date() }
    }
}
#endif
