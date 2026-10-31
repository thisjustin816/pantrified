import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain
import PantrifiedTestSupport
@testable import PantrifiedPersistence

@Suite("Saving several locations at once")
struct LocationBatchTests {
    private let space = SpaceID()
    // The IDs sort in the reverse of the order the locations are saved in, so a store that lost
    // their positions would list them in the wrong order, never by luck in the right one.
    private let cellar = StorageLocation(id: Self.id("F"), name: "Cellar", storageType: .roomTemperature)
    private let fridge = StorageLocation(id: Self.id("C"), name: "Fridge", storageType: .refrigerated)
    private let freezer = StorageLocation(id: Self.id("8"), name: "Freezer", storageType: .frozen)
    private let pantry = StorageLocation(id: Self.id("1"), name: "Pantry", storageType: .roomTemperature)

    private static func id(_ digit: Character) -> LocationID {
        LocationID(UUID(uuidString: "\(String(repeating: digit, count: 8))-0000-0000-0000-000000000000")!)
    }

    @Test("a batch is stored in the order given, after what is already there", arguments: TestStorage.allCases)
    func storedInOrder(storage: TestStorage) async throws {
        let locations = PersistentLocations(backend: try storage.makeBackend())
        try await locations.save(cellar, in: space)

        try await locations.saveAll([fridge, freezer, pantry], in: space)

        #expect(try await locations.locations(in: space) == [cellar, fridge, freezer, pantry])
    }

    @Test("a location already stored keeps its place and takes the new name or type", arguments: TestStorage.allCases)
    func existingKeepsPlace(storage: TestStorage) async throws {
        let locations = PersistentLocations(backend: try storage.makeBackend())
        try await locations.saveAll([fridge, freezer], in: space)
        var renamed = fridge
        renamed.name = "Kitchen fridge"

        try await locations.saveAll([pantry, renamed], in: space)

        #expect(try await locations.locations(in: space) == [renamed, freezer, pantry])
    }

    @Test("a failed write stores none of the batch and leaves what was there", arguments: TestStorage.allCases)
    func failedWriteStoresNothing(storage: TestStorage) async throws {
        let backend = FaultyBackend(try storage.makeBackend())
        let locations = PersistentLocations(backend: backend)
        try await locations.save(pantry, in: space)
        backend.failWrites(after: 0)

        await #expect(throws: InducedFailure.self) {
            try await locations.saveAll([fridge, freezer], in: space)
        }

        #expect(try await locations.locations(in: space) == [pantry])
    }

    @Test("a batch is one write", arguments: TestStorage.allCases)
    func oneWrite(storage: TestStorage) async throws {
        let backend = FaultyBackend(try storage.makeBackend())

        try await PersistentLocations(backend: backend).saveAll([fridge, freezer, pantry], in: space)

        #expect(backend.committedBatches.count == 1)
    }

    @Test("saving nothing changes nothing", arguments: TestStorage.allCases)
    func emptyBatch(storage: TestStorage) async throws {
        let locations = PersistentLocations(backend: try storage.makeBackend())
        try await locations.save(fridge, in: space)

        try await locations.saveAll([], in: space)

        #expect(try await locations.locations(in: space) == [fridge])
    }

    @Test("Spaces are separate", arguments: TestStorage.allCases)
    func spacesAreSeparate(storage: TestStorage) async throws {
        let locations = PersistentLocations(backend: try storage.makeBackend())
        let other = SpaceID()

        try await locations.saveAll([fridge], in: space)
        try await locations.saveAll([pantry], in: other)

        #expect(try await locations.locations(in: space) == [fridge])
        #expect(try await locations.locations(in: other) == [pantry])
    }
}
