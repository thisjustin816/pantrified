import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain
import PantrifiedTestSupport
@testable import PantrifiedPersistence

private struct ContainerFailure: Error {}

@Suite("Store opening")
struct StoreOpeningTests {
    private func marker(_ files: StoreFiles) -> String? {
        (try? Data(contentsOf: files.schemaMarker)).map { String(decoding: $0, as: UTF8.self) }
    }

    private func writeMarker(_ text: String, _ files: StoreFiles) throws {
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: files.schemaMarker)
    }

    @Test("a first open creates the directory, opens the store and records the schema version")
    func firstOpen() throws {
        let files = temporaryStoreFiles()
        var opened = 0

        let result = try StoreOpening.open(files) { opened += 1; return "store" }

        #expect(result == "store")
        #expect(opened == 1)
        #expect(marker(files) == "\(StoreSchema.current)")
    }

    @Test("a store marked by a newer schema is refused before it is opened, and left as it is")
    func newerSchemaIsRefused() throws {
        let files = temporaryStoreFiles()
        try writeMarker("\(StoreSchema.current + 1)", files)
        var opened = false

        #expect(throws: PersistenceError.newerSchema(found: StoreSchema.current + 1, supported: StoreSchema.current)) {
            try StoreOpening.open(files) { opened = true }
        }
        #expect(!opened)
        #expect(marker(files) == "\(StoreSchema.current + 1)")
    }

    @Test("a store that fails to open is reported and its marker is not advanced")
    func containerFailureIsReported() throws {
        let files = temporaryStoreFiles()
        try writeMarker("0", files)

        #expect(throws: PersistenceError.self) {
            try StoreOpening.open(files) { () throws -> Int in throw ContainerFailure() }
        }
        #expect(marker(files) == "0")
    }

    @Test("an older marker is advanced once the store has opened")
    func olderMarkerAdvances() throws {
        let files = temporaryStoreFiles()
        try writeMarker("0", files)

        _ = try StoreOpening.open(files) { 1 }

        #expect(marker(files) == "\(StoreSchema.current)")
    }

    @Test("an unreadable marker refuses the store rather than guessing its version")
    func unreadableMarkerIsRefused() throws {
        let files = temporaryStoreFiles()
        try writeMarker("two", files)
        var opened = false

        #expect(throws: PersistenceError.cannotOpen("unreadable schema marker")) {
            try StoreOpening.open(files) { opened = true }
        }
        #expect(!opened)
    }

    @Test("a directory that cannot be created is reported")
    func directoryFailureIsReported() throws {
        let blocker = temporaryStoreFiles().directory
        try FileManager.default.createDirectory(at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: blocker)

        #expect(throws: PersistenceError.self) {
            try StoreOpening.open(StoreFiles(directory: blocker.appendingPathComponent("store"))) { 1 }
        }
    }

    @Test("the default store lives in Application Support, apart from caches and temporary files")
    func defaultLocation() throws {
        let files = try StoreFiles.applicationSupport()
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)

        #expect(files.directory.path.hasPrefix(support.path))
        #expect(files.directory.pathComponents.suffix(2) == ["Pantrified", "LocalStore"])
        #expect(files.store.deletingLastPathComponent() == files.directory)
    }
}

@Suite("Local store")
struct LocalStoreTests {
    private struct Offline: SyncTransport {
        func push(_ records: [OutgoingRecord], zone: SpaceID) async throws -> [RecordID: PushOutcome] { throw InducedFailure() }
        func pull(zone: SpaceID, since token: ChangeToken?) async throws -> PullPage { throw InducedFailure() }
    }

    private struct Clock: TimeSource {
        func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    }

    @Test("one replica serves each Space, however often it is asked for")
    func oneReplicaPerSpace() throws {
        let store = LocalStore(backend: InMemoryStorageBackend())
        let space = SpaceID()

        let first = try store.replica(for: space, transport: Offline(), time: Clock())
        let second = try store.replica(for: space, transport: Offline(), time: Clock())
        let other = try store.replica(for: SpaceID(), transport: Offline(), time: Clock())

        #expect(first === second)
        #expect(first !== other)
    }

    @Test("a replica opened from the store after a relaunch holds what was saved")
    func replicaSurvivesRelaunch() async throws {
        let backend = InMemoryStorageBackend()
        let space = SpaceID()
        let fridge = StorageLocation(name: "Fridge", storageType: .refrigerated)
        let package = Package(spaceID: space, name: "Milk", location: fridge.id, addedAt: Clock().now())
        let first = LocalStore(backend: backend)
        try await first.replica(for: space, transport: Offline(), time: Clock()).save(package)
        try await first.locations.save(fridge, in: space)

        let relaunched = LocalStore(backend: backend)

        #expect(try await relaunched.replica(for: space, transport: Offline(), time: Clock()).package(package.id)?.name == "Milk")
        #expect(try await relaunched.locations.locations(in: space) == [fridge])
    }
}
