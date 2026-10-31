import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain
import PantrifiedTestSupport
@testable import PantrifiedPersistence

@Suite("Device-local repositories")
struct LocalRepositoryTests {
    private let space = SpaceID()

    @Test("locations come back in the order they were first saved, with renames and types kept", arguments: TestStorage.allCases)
    func locationsKeepOrder(storage: TestStorage) async throws {
        let backend = try storage.makeBackend()
        let locations = PersistentLocations(backend: backend)
        let fridge = StorageLocation(name: "Fridge", storageType: .refrigerated)
        let freezer = StorageLocation(name: "Freezer", storageType: .frozen)
        let pantry = StorageLocation(name: "Pantry", storageType: .roomTemperature)
        for location in [fridge, freezer, pantry] { try await locations.save(location, in: space) }

        var renamed = fridge
        renamed.name = "Kitchen fridge"
        try await locations.save(renamed, in: space)

        #expect(try await PersistentLocations(backend: backend).locations(in: space) == [renamed, freezer, pantry])
        #expect(try await locations.locations(in: SpaceID()).isEmpty)
    }

    @Test("every storage type is stored under the tag the sync format uses")
    func storageTypeTags() {
        let tags = [StorageType.refrigerated, .frozen, .roomTemperature].map(\.storedTag)

        #expect(tags == ["refrigerated", "frozen", "roomTemperature"])
        #expect(tags.map(StorageType.init(storedTag:)) == [.refrigerated, .frozen, .roomTemperature])
        #expect(StorageType(storedTag: "cellar") == nil)
    }

    @Test("a location row with a storage type this version does not know is reported, not guessed", arguments: TestStorage.allCases)
    func unknownStorageTypeIsReported(storage: TestStorage) async throws {
        let backend = try storage.makeBackend()
        var batch = StorageBatch()
        batch.localWrites[LocalRowKey(kind: .location, space: space, entity: UUID().uuidString)] = .put(StoredValueCoding.encode(
            .map(["name": .string("Cellar"), "storageType": .string("cellar"), "position": .int(0)])
        ))
        try backend.write(batch)

        await #expect(throws: PersistenceError.self) {
            try await PersistentLocations(backend: backend).locations(in: space)
        }
    }

    @Test("ingredient links persist once each, per Space and in their direction", arguments: TestStorage.allCases)
    func linksPersist(storage: TestStorage) async throws {
        let backend = try storage.makeBackend()
        let links = PersistentIngredientLinks(backend: backend)
        let scallions = IngredientLink(ingredient: IngredientName("Scallions"), inventoryName: IngredientName("green onions"))
        let reverse = IngredientLink(ingredient: IngredientName("green onions"), inventoryName: IngredientName("Scallions"))

        try await links.confirm(scallions, in: space)
        try await links.confirm(scallions, in: space)
        try await links.confirm(reverse, in: space)

        #expect(try await PersistentIngredientLinks(backend: backend).links(in: space) == [scallions, reverse])
        #expect(try await links.links(in: SpaceID()).isEmpty)
    }

    @Test("a failed save leaves stored locations and links unchanged", arguments: TestStorage.allCases)
    func failedSavesChangeNothing(storage: TestStorage) async throws {
        let backend = FaultyBackend(try storage.makeBackend())
        let fridge = StorageLocation(name: "Fridge", storageType: .refrigerated)
        try await PersistentLocations(backend: backend).save(fridge, in: space)

        backend.failWrites(after: 0)
        var renamed = fridge
        renamed.name = "Garage fridge"
        await #expect(throws: InducedFailure.self) { try await PersistentLocations(backend: backend).save(renamed, in: space) }
        await #expect(throws: InducedFailure.self) {
            try await PersistentIngredientLinks(backend: backend).confirm(IngredientLink(ingredient: IngredientName("a"), inventoryName: IngredientName("b")), in: space)
        }

        #expect(try await PersistentLocations(backend: backend).locations(in: space) == [fridge])
        #expect(try await PersistentIngredientLinks(backend: backend).links(in: space).isEmpty)
    }

    @Test("local row keys are unique per Space, kind and entity, whatever the kind contains")
    func localKeysAreUnambiguous() {
        let space = SpaceID()
        let pairs = [("a", "b/c"), ("a/b", "c"), ("ab", "/c"), ("", "a/b/c"), ("a/b/c", "")]
        let keys = Set(pairs.map { RowKey.local(LocalRowKey(kind: LocalRowKind(rawValue: $0.0), space: space, entity: $0.1)) })

        #expect(keys.count == pairs.count)
    }
}
