import Foundation
import PantrifiedApplication
import PantrifiedDomain

struct FakeFailure: Error, Equatable {}

final class FixedTime: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) { current = date }

    func now() -> Date { lock.withLock { current } }
    func advance(hours: Double) { lock.withLock { current = current.addingTimeInterval(hours * 3600) } }
}

actor InMemoryInventory: InventoryRepository {
    private var packages: [PackageID: Package] = [:]
    private(set) var saveCount = 0
    var failOnSave = false
    var failOnRead = false

    init(_ initial: [Package] = []) {
        for package in initial { packages[package.id] = package }
    }

    func setFailOnSave(_ value: Bool) { failOnSave = value }
    func setFailOnRead(_ value: Bool) { failOnRead = value }

    func package(_ id: PackageID) async throws -> Package? {
        if failOnRead { throw FakeFailure() }
        return packages[id]
    }

    func activePackages(in space: SpaceID) async throws -> [Package] {
        if failOnRead { throw FakeFailure() }
        return packages.values.filter { $0.spaceID == space && $0.status == .active }
    }

    func save(_ package: Package) async throws {
        if failOnSave { throw FakeFailure() }
        store(package)
        saveCount += 1
    }

    func saveAll(_ batch: [Package]) async throws {
        if failOnSave { throw FakeFailure() }
        for package in batch { store(package) }
        saveCount += 1
    }

    /// Keeps stored creation facts and adds only events the store does not hold.
    private func store(_ package: Package) {
        guard let stored = packages[package.id] else {
            packages[package.id] = package
            return
        }
        let held = Set(stored.events.map(\.id))
        let added = package.events.filter { !held.contains($0.id) }
        guard !added.isEmpty else { return }
        let origin = stored.origin
        packages[package.id] = Package(
            id: stored.id, spaceID: stored.spaceID, productID: origin.details.productID, name: origin.details.name,
            location: origin.location, quantity: origin.quantity, printedDate: origin.details.printedDate,
            instruction: origin.details.instruction, confirmed: origin.confirmed, addedAt: stored.addedAt,
            events: stored.events + added
        )
    }
}

/// Barcodes kept beside packages, with a switch to fail every write.
actor InMemoryProductEvidence: ProductEvidenceStore {
    private(set) var barcodes: [SpaceID: [PackageID: GTIN]] = [:]
    private(set) var writes = 0
    var failWrites = false

    func setFailWrites(_ value: Bool) { failWrites = value }

    func barcode(of package: PackageID, in space: SpaceID) async throws -> GTIN? {
        barcodes[space]?[package]
    }

    func record(_ new: [PackageID: GTIN], in space: SpaceID) async throws {
        if failWrites { throw FakeFailure() }
        writes += 1
        barcodes[space, default: [:]].merge(new) { $1 }
    }
}

struct InMemoryLocations: StorageLocationRepository {
    let locationsBySpace: [SpaceID: [StorageLocation]]

    func locations(in space: SpaceID) async throws -> [StorageLocation] {
        locationsBySpace[space] ?? []
    }
}

struct FakeGuidance: StorageGuidanceRepository {
    var result: StorageGuidance?
    var fails = false

    func guidance(for package: Package) async throws -> StorageGuidance? {
        if fails { throw FakeFailure() }
        return result
    }
}

actor InMemoryLinks: IngredientLinkRepository {
    private var stored: [SpaceID: Set<IngredientLink>] = [:]
    var failOnRead = false

    init(_ initial: [SpaceID: Set<IngredientLink>] = [:]) { stored = initial }

    func setFailOnRead(_ value: Bool) { failOnRead = value }

    func links(in space: SpaceID) async throws -> Set<IngredientLink> {
        if failOnRead { throw FakeFailure() }
        return stored[space] ?? []
    }

    func confirm(_ link: IngredientLink, in space: SpaceID) async throws {
        stored[space, default: []].insert(link)
    }
}

actor InMemoryShopping: ShoppingListRepository {
    private var lists: [SpaceID: ShoppingList] = [:]
    var failOnSave = false

    func setFailOnSave(_ value: Bool) { failOnSave = value }

    func list(in space: SpaceID) async throws -> ShoppingList { lists[space] ?? ShoppingList() }

    func update<Result: Sendable>(
        in space: SpaceID,
        _ change: @Sendable (inout ShoppingList) throws -> Result
    ) async throws -> Result {
        var list = lists[space] ?? ShoppingList()
        let result = try change(&list)
        if failOnSave { throw FakeFailure() }
        lists[space] = list
        return result
    }
}

actor FakeReminders: RemindersDestination {
    var titles: [String]
    var missing = false
    private(set) var written: [ShoppingExportItem] = []
    private(set) var writeCalls = 0

    init(titles: [String] = [], missing: Bool = false) {
        self.titles = titles
        self.missing = missing
    }

    func incompleteReminderTitles() async throws -> [String] {
        if missing { throw ShoppingExportError.destinationMissing }
        return titles
    }

    func add(_ items: [ShoppingExportItem]) async throws {
        if missing { throw ShoppingExportError.destinationMissing }
        writeCalls += 1
        written += items
    }
}
