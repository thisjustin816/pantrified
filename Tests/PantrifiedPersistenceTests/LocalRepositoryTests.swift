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

    @Test("package barcodes persist per Space and package, all of a batch in one write", arguments: TestStorage.allCases)
    func barcodesPersist(storage: TestStorage) async throws {
        let backend = FaultyBackend(try storage.makeBackend())
        let evidence = PersistentProductEvidence(backend: backend)
        let (milk, cola) = (PackageID(), PackageID())
        let ean = try #require(GTIN("4006381333931"))
        let upc = try #require(GTIN("036000291452"))

        try await evidence.record([milk: ean, cola: upc], in: space)
        try await evidence.record([milk: ean], in: space)

        let reopened = PersistentProductEvidence(backend: backend)
        #expect(try await reopened.barcode(of: milk, in: space) == ean)
        #expect(try await reopened.barcode(of: cola, in: space) == upc)
        #expect(try await reopened.barcode(of: PackageID(), in: space) == nil)
        #expect(try await reopened.barcode(of: milk, in: SpaceID()) == nil)

        backend.failWrites(after: 0)
        let soup = PackageID()
        await #expect(throws: InducedFailure.self) { try await evidence.record([soup: ean, milk: upc], in: space) }
        #expect(try await reopened.barcode(of: soup, in: space) == nil)
        #expect(try await reopened.barcode(of: milk, in: space) == ean)
    }

    @Test("a barcode is stored as its 14 digits, and a stored value that is not a GTIN is reported", arguments: TestStorage.allCases)
    func barcodeRows(storage: TestStorage) async throws {
        let backend = try storage.makeBackend()
        let package = PackageID()
        try await PersistentProductEvidence(backend: backend).record([package: try #require(GTIN("036000291452"))], in: space)
        let row = try #require(try backend.localRows(of: .packageBarcode, in: space).first)
        #expect(row.key.entity == package.rawValue.uuidString)
        #expect(try StoredValueCoding.value(from: row.payload) == .map(["gtin": .string("00036000291452")]))

        for stored in ["036000291452", "00036000291453", "notdigits"] {
            let broken = PackageID()
            var batch = StorageBatch()
            batch.localWrites[LocalRowKey(kind: .packageBarcode, space: space, entity: broken.rawValue.uuidString)] =
                .put(StoredValueCoding.encode(.map(["gtin": .string(stored)])))
            try backend.write(batch)
            await #expect(throws: PersistenceError.self, "\(stored)") {
                try await PersistentProductEvidence(backend: backend).barcode(of: broken, in: space)
            }
        }
    }

    @Test("local row keys are unique per Space, kind and entity, whatever the kind contains")
    func localKeysAreUnambiguous() {
        let space = SpaceID()
        let pairs = [("a", "b/c"), ("a/b", "c"), ("ab", "/c"), ("", "a/b/c"), ("a/b/c", "")]
        let keys = Set(pairs.map { RowKey.local(LocalRowKey(kind: LocalRowKind(rawValue: $0.0), space: space, entity: $0.1)) })

        #expect(keys.count == pairs.count)
    }
}
