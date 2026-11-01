import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain
import PantrifiedPersistence
import PantrifiedTestSupport

private actor MutableLocations: StorageLocationStore {
    private var bySpace: [SpaceID: [StorageLocation]] = [:]
    private(set) var batches: [[StorageLocation]] = []
    var failSaves = false

    init(_ initial: [SpaceID: [StorageLocation]] = [:]) { bySpace = initial }

    func locations(in space: SpaceID) async throws -> [StorageLocation] { bySpace[space] ?? [] }

    func saveAll(_ locations: [StorageLocation], in space: SpaceID) async throws {
        if failSaves { throw FakeFailure() }
        batches.append(locations)
        bySpace[space, default: []].append(contentsOf: locations)
    }

    func failFromNowOn() { failSaves = true }
}

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// A Pantry over one Space, with its clock at `syncEpoch` (15 January 2027) and days counted in UTC.
private struct Setup {
    let pantry: Pantry
    let space: SpaceID
    let locations: MutableLocations
    let inventory: any InventoryRepository
    let evidence = InMemoryProductEvidence()

    init(_ store: InventoryStore, guidance: StorageGuidance? = nil) async throws {
        let world = World()
        let locations = MutableLocations()
        space = world.space
        self.locations = locations
        inventory = try await store.make(world, holding: [])
        pantry = Pantry(
            space: world.space, inventory: inventory, locations: locations, evidence: evidence,
            guidance: FakeGuidance(result: guidance), time: FixedTime(syncEpoch),
            policy: AttentionPolicy(calendar: utc)
        )
    }

    /// The Space's locations once the defaults are in: Fridge, Freezer, Pantry.
    func prepared() async throws -> (fridge: StorageLocation, freezer: StorageLocation, pantry: StorageLocation) {
        try await pantry.prepare()
        let all = try await locations.locations(in: space)
        return (all[0], all[1], all[2])
    }
}

private func date(_ label: PrintedDateLabel, _ day: Int, month: Int = 1) -> PrintedDate {
    PrintedDate.onDay(label, year: 2027, month: month, day: day)!
}

@Suite("Pantry")
struct PantryTests {
    // MARK: Default locations

    @Test("a new Space gets Fridge, Freezer and Pantry with their storage types, in one write", arguments: InventoryStore.allCases)
    func defaultsForANewSpace(store: InventoryStore) async throws {
        let setup = try await Setup(store)

        try await setup.pantry.prepare()

        let saved = try await setup.locations.locations(in: setup.space)
        #expect(saved.map(\.name) == ["Fridge", "Freezer", "Pantry"])
        #expect(saved.map(\.storageType) == [.refrigerated, .frozen, .roomTemperature])
        #expect(await setup.locations.batches.count == 1)
    }

    @Test("preparing twice adds nothing the second time", arguments: InventoryStore.allCases)
    func preparingIsIdempotent(store: InventoryStore) async throws {
        let setup = try await Setup(store)

        try await setup.pantry.prepare()
        try await setup.pantry.prepare()

        #expect(try await setup.locations.locations(in: setup.space).count == 3)
        #expect(await setup.locations.batches.count == 1)
    }

    @Test("a Space that already has any location is left as it is", arguments: InventoryStore.allCases)
    func existingLocationsAreKept(store: InventoryStore) async throws {
        let setup = try await Setup(store)
        let cellar = StorageLocation(name: "Cellar", storageType: .roomTemperature)
        try await setup.locations.saveAll([cellar], in: setup.space)

        try await setup.pantry.prepare()

        #expect(try await setup.locations.locations(in: setup.space) == [cellar])
    }

    @Test("a failed write leaves the Space without locations and the error reaches the caller", arguments: InventoryStore.allCases)
    func failedPrepare(store: InventoryStore) async throws {
        let setup = try await Setup(store)
        await setup.locations.failFromNowOn()

        await #expect(throws: FakeFailure.self) { try await setup.pantry.prepare() }

        #expect(try await setup.locations.locations(in: setup.space).isEmpty)
    }

    // MARK: Adding food

    @Test("food added by hand shows up where it was put, with what was entered", arguments: InventoryStore.allCases)
    func addedFoodAppears(store: InventoryStore) async throws {
        let setup = try await Setup(store)
        let places = try await setup.prepared()

        let id = try await setup.pantry.add(NewFood(
            name: "  Greek yogurt ", location: places.fridge.id, quantity: .aboutHalf,
            printedDate: date(.bestBy, 30)
        ))

        let snapshot = try await setup.pantry.snapshot()
        let entry = try #require(snapshot.entries.first)
        #expect(snapshot.entries.count == 1)
        #expect(entry.id == id)
        #expect(entry.package.name == "Greek yogurt")
        #expect(entry.locationName == "Fridge")
        #expect(entry.package.quantity == .aboutHalf)
        #expect(entry.package.printedDate == date(.bestBy, 30))
        #expect(entry.package.confirmedFields == [.name, .printedDate])
        #expect(entry.package.addedAt == syncEpoch)
    }

    @Test("an edit shows in the snapshot, a corrected date changes what needs attention, and undo reverses it", arguments: InventoryStore.allCases)
    func editShowsInSnapshot(store: InventoryStore) async throws {
        let setup = try await Setup(store)
        let places = try await setup.prepared()
        let id = try await setup.pantry.add(NewFood(name: "Mayo", location: places.fridge.id, printedDate: date(.bestBy, 30)))
        #expect(try await setup.pantry.snapshot().entries.first?.needsAttention == false)

        let outcome = try await setup.pantry.edit(
            PackageEdit(name: .set("Mayonnaise"), printedDate: .set(date(.bestBy, 16))), on: id
        )

        let edited = try #require(try await setup.pantry.snapshot().entries.first)
        #expect(edited.package.name == "Mayonnaise")
        #expect(edited.package.printedDate == date(.bestBy, 16))
        #expect(edited.needsAttention)
        guard case .applied(let tokens) = outcome else { Issue.record("not applied"); return }

        try await setup.pantry.undo(tokens)

        let undone = try #require(try await setup.pantry.snapshot().entries.first)
        #expect(undone.package.name == "Mayo")
        #expect(undone.needsAttention == false)
    }

    @Test("a scanned barcode is kept beside the food as evidence; food without one keeps none", arguments: InventoryStore.allCases)
    func barcodeIsKept(store: InventoryStore) async throws {
        let setup = try await Setup(store)
        let places = try await setup.prepared()
        let gtin = try #require(GTIN("036000291452"))

        let scanned = try await setup.pantry.add(NewFood(name: "Cola", location: places.pantry.id, barcode: gtin))
        let typed = try await setup.pantry.add(NewFood(name: "Rice", location: places.pantry.id))

        #expect(try await setup.evidence.barcode(of: scanned, in: setup.space) == gtin)
        #expect(try await setup.evidence.barcode(of: typed, in: setup.space) == nil)
        #expect(await setup.evidence.writes == 1)
    }

    @Test("two foods with one barcode are two packages, each with the barcode", arguments: InventoryStore.allCases)
    func repeatedBarcodeIsTwoPackages(store: InventoryStore) async throws {
        let setup = try await Setup(store)
        let places = try await setup.prepared()
        let gtin = try #require(GTIN("036000291452"))

        let first = try await setup.pantry.add(NewFood(name: "Cola", location: places.pantry.id, barcode: gtin))
        let second = try await setup.pantry.add(NewFood(name: "Cola", location: places.pantry.id, barcode: gtin))

        #expect(first != second)
        #expect(try await setup.pantry.snapshot().entries.count == 2)
        #expect(try await setup.evidence.barcode(of: second, in: setup.space) == gtin)
    }

    @Test("food is saved even when its barcode cannot be kept", arguments: InventoryStore.allCases)
    func barcodeFailureDoesNotFailTheAdd(store: InventoryStore) async throws {
        let setup = try await Setup(store)
        let places = try await setup.prepared()
        await setup.evidence.setFailWrites(true)

        let id = try await setup.pantry.add(NewFood(name: "Cola", location: places.pantry.id, barcode: GTIN("036000291452")))

        #expect(try await setup.pantry.snapshot().entries.map(\.id) == [id])
        #expect(try await setup.evidence.barcode(of: id, in: setup.space) == nil)
    }

    @Test("a name a lookup suggested is kept as a suggestion; a name the person typed is confirmed", arguments: InventoryStore.allCases)
    func suggestedNameIsNotConfirmed(store: InventoryStore) async throws {
        let setup = try await Setup(store)
        let places = try await setup.prepared()

        let suggested = try await setup.pantry.add(NewFood(name: "Cola", nameSource: .lookup, location: places.pantry.id))
        let typed = try await setup.pantry.add(NewFood(name: "Cola", nameSource: .person, location: places.pantry.id))

        let entries = try await setup.pantry.snapshot().entries
        let suggestedEntry = try #require(entries.first { $0.id == suggested })
        let typedEntry = try #require(entries.first { $0.id == typed })
        #expect(suggestedEntry.package.name == "Cola")
        #expect(!suggestedEntry.package.confirmedFields.contains(.name))
        #expect(typedEntry.package.confirmedFields.contains(.name))
    }

    @Test("quantity and date are optional", arguments: InventoryStore.allCases)
    func quantityAndDateAreOptional(store: InventoryStore) async throws {
        let setup = try await Setup(store)
        let places = try await setup.prepared()

        try await setup.pantry.add(NewFood(name: "Rice", location: places.pantry.id))

        let entry = try #require(try await setup.pantry.snapshot().entries.first)
        #expect(entry.package.quantity == .unknown)
        #expect(entry.package.printedDate == nil)
        #expect(entry.assessment.state == .unknown)
    }

    @Test("a name that is empty or only spaces is refused and nothing is stored", arguments: InventoryStore.allCases)
    func blankNameIsRefused(store: InventoryStore) async throws {
        let setup = try await Setup(store)
        let places = try await setup.prepared()

        for name in ["", "   ", "\n\t "] {
            await #expect(throws: PantryError.nameRequired) {
                try await setup.pantry.add(NewFood(name: name, location: places.fridge.id))
            }
        }

        #expect(try await setup.pantry.snapshot().entries.isEmpty)
    }

    @Test("a location the Space does not have is refused and nothing is stored", arguments: InventoryStore.allCases)
    func unknownLocationIsRefused(store: InventoryStore) async throws {
        let setup = try await Setup(store)
        try await setup.pantry.prepare()

        await #expect(throws: PutAwayError.self) {
            try await setup.pantry.add(NewFood(name: "Milk", location: LocationID()))
        }

        #expect(try await setup.pantry.snapshot().entries.isEmpty)
    }

    @Test("the same food added twice is two packages", arguments: InventoryStore.allCases)
    func sameFoodTwice(store: InventoryStore) async throws {
        let setup = try await Setup(store)
        let places = try await setup.prepared()

        let first = try await setup.pantry.add(NewFood(name: "Milk", location: places.fridge.id))
        let second = try await setup.pantry.add(NewFood(name: "Milk", location: places.fridge.id))

        #expect(first != second)
        #expect(try await setup.pantry.snapshot().entries.count == 2)
    }

    // MARK: What needs attention

    @Test("past guidance comes first, then use soon, soonest first, then the rest by name", arguments: InventoryStore.allCases)
    func ordering(store: InventoryStore) async throws {
        let setup = try await Setup(store)
        let places = try await setup.prepared()
        // The clock reads 15 January 2027.
        let foods: [(String, PrintedDate?)] = [
            ("Zucchini", nil), ("Apples", nil), ("Fine cheese", date(.bestBy, 30)),
            ("Soon later", date(.useBy, 18)), ("Soon first", date(.useBy, 16)),
            ("Past recent", date(.useBy, 14)), ("Past older", date(.useBy, 2)),
        ]
        for (name, printed) in foods {
            try await setup.pantry.add(NewFood(name: name, location: places.fridge.id, printedDate: printed))
        }

        let snapshot = try await setup.pantry.snapshot()

        #expect(snapshot.entries.map(\.package.name) == [
            "Past older", "Past recent", "Soon first", "Soon later", "Apples", "Fine cheese", "Zucchini",
        ])
        #expect(snapshot.attention.map(\.package.name) == ["Past older", "Past recent", "Soon first", "Soon later"])
        #expect(snapshot.attention.map(\.assessment.state) == [.pastGuidance, .pastGuidance, .useSoon, .useSoon])
    }

    @Test("a day counts as today until it ends: a date of today is use soon, not past", arguments: InventoryStore.allCases)
    func dateOfTodayIsNotPast(store: InventoryStore) async throws {
        let setup = try await Setup(store)
        let places = try await setup.prepared()

        try await setup.pantry.add(NewFood(name: "Cream", location: places.fridge.id, printedDate: date(.useBy, 15)))

        let entry = try #require(try await setup.pantry.snapshot().entries.first)
        #expect(entry.assessment.state == .useSoon)
    }

    @Test("sourced guidance applies to food added without a date", arguments: InventoryStore.allCases)
    func guidanceApplies(store: InventoryStore) async throws {
        let guidance = StorageGuidance(
            provenance: GuidanceProvenance(source: "test", version: "1"),
            windows: [GuidanceWindow(storageType: .refrigerated, anchor: .added, days: 2)]
        )
        let setup = try await Setup(store, guidance: guidance)
        let places = try await setup.prepared()

        try await setup.pantry.add(NewFood(name: "Chicken", location: places.fridge.id))
        try await setup.pantry.add(NewFood(name: "Beans", location: places.pantry.id))

        let snapshot = try await setup.pantry.snapshot()
        #expect(snapshot.attention.map(\.package.name) == ["Chicken"])
        #expect(snapshot.entries.first { $0.package.name == "Beans" }?.assessment.state == .unknown)
    }

    // MARK: Grouping

    @Test("entries can be read by location, and a package whose location is gone is still shown", arguments: InventoryStore.allCases)
    func groupingByLocation(store: InventoryStore) async throws {
        let setup = try await Setup(store)
        let places = try await setup.prepared()
        try await setup.pantry.add(NewFood(name: "Milk", location: places.fridge.id))
        try await setup.pantry.add(NewFood(name: "Peas", location: places.freezer.id))

        let snapshot = try await setup.pantry.snapshot()
        #expect(snapshot.entries(in: places.fridge.id).map(\.package.name) == ["Milk"])
        #expect(snapshot.entries(in: places.freezer.id).map(\.package.name) == ["Peas"])
        #expect(snapshot.entries(in: places.pantry.id).isEmpty)
        #expect(snapshot.unplaced.isEmpty)
    }

    @Test("a package whose location the Space no longer lists is still shown, without a location name", arguments: InventoryStore.allCases)
    func packageWithUnknownLocation(store: InventoryStore) async throws {
        let setup = try await Setup(store)
        let places = try await setup.prepared()
        try await setup.pantry.add(NewFood(name: "Milk", location: places.fridge.id))
        try await setup.pantry.add(NewFood(name: "Peas", location: places.freezer.id))
        // The same inventory, read by a Pantry whose Space lists only the freezer.
        let narrowed = Pantry(
            space: setup.space, inventory: setup.inventory,
            locations: MutableLocations([setup.space: [places.freezer]]), evidence: setup.evidence,
            guidance: FakeGuidance(result: nil), time: FixedTime(syncEpoch), policy: AttentionPolicy(calendar: utc)
        )

        let snapshot = try await narrowed.snapshot()

        #expect(snapshot.entries.count == 2)
        #expect(snapshot.unplaced.map(\.package.name) == ["Milk"])
        #expect(snapshot.unplaced.first?.locationName == nil)
        #expect(snapshot.entries(in: places.freezer.id).map(\.package.name) == ["Peas"])
    }

    // MARK: Actions and undo

    @Test("opened, used up and discarded each leave their effect and can be undone", arguments: InventoryStore.allCases)
    func actionsAndUndo(store: InventoryStore) async throws {
        let setup = try await Setup(store)
        let places = try await setup.prepared()
        let milk = try await setup.pantry.add(NewFood(name: "Milk", location: places.fridge.id))
        let eggs = try await setup.pantry.add(NewFood(name: "Eggs", location: places.fridge.id))
        let jam = try await setup.pantry.add(NewFood(name: "Jam", location: places.pantry.id))

        guard case .applied(let openedToken) = try await setup.pantry.perform(.opened, on: milk),
              case .applied(let usedToken) = try await setup.pantry.perform(.usedUp, on: eggs),
              case .applied(let discardToken) = try await setup.pantry.perform(.discard(reason: .spoiled), on: jam)
        else { Issue.record("an action was not applied"); return }

        var snapshot = try await setup.pantry.snapshot()
        #expect(snapshot.entries.map(\.package.name) == ["Milk"])
        #expect(snapshot.entries.first?.package.openedAt == syncEpoch)

        try await setup.pantry.undo(usedToken)
        try await setup.pantry.undo(discardToken)
        try await setup.pantry.undo(openedToken)

        snapshot = try await setup.pantry.snapshot()
        #expect(snapshot.entries.map(\.package.name) == ["Eggs", "Jam", "Milk"])
        #expect(snapshot.entries.first { $0.package.name == "Milk" }?.package.openedAt == nil)
    }

    @Test("a package moves to another location and moves back on undo", arguments: InventoryStore.allCases)
    func moveAndUndo(store: InventoryStore) async throws {
        let setup = try await Setup(store)
        let places = try await setup.prepared()
        let peas = try await setup.pantry.add(NewFood(name: "Peas", location: places.fridge.id))

        guard case .applied(let token) = try await setup.pantry.perform(.move(to: places.freezer.id), on: peas) else {
            Issue.record("the move was not applied"); return
        }
        #expect(try await setup.pantry.snapshot().entries.first?.locationName == "Freezer")

        try await setup.pantry.undo(token)
        #expect(try await setup.pantry.snapshot().entries.first?.locationName == "Fridge")
    }

    @Test("an action on a package that is not there is an error and changes nothing", arguments: InventoryStore.allCases)
    func actionOnMissingPackage(store: InventoryStore) async throws {
        let setup = try await Setup(store)
        let places = try await setup.prepared()
        try await setup.pantry.add(NewFood(name: "Milk", location: places.fridge.id))

        await #expect(throws: PackageActionError.packageNotFound) {
            try await setup.pantry.perform(.usedUp, on: PackageID())
        }

        #expect(try await setup.pantry.snapshot().entries.count == 1)
    }

    // MARK: Kept across launches

    @Test("food and locations are there after the app is opened again", arguments: TestStorage.allCases)
    func survivesRelaunch(storage: TestStorage) async throws {
        let backend = try storage.makeBackend()
        let world = World()
        func launch() throws -> Pantry {
            let local = LocalStore(backend: backend)
            let replica = try local.replica(for: world.space, transport: CloudLink(world.cloud), time: FixedTime(syncEpoch))
            return Pantry(
                space: world.space, inventory: replica, locations: local.locations, evidence: local.productEvidence,
                guidance: FakeGuidance(result: nil), time: FixedTime(syncEpoch), policy: AttentionPolicy(calendar: utc)
            )
        }

        let first = try launch()
        try await first.prepare()
        let fridge = try #require(try await first.snapshot().locations.first)
        let milk = try await first.add(NewFood(
            name: "Milk", location: fridge.id, quantity: .low, printedDate: date(.useBy, 16), barcode: GTIN("036000291452")
        ))
        try await first.perform(.opened, on: milk)

        let second = try launch()
        try await second.prepare()
        let snapshot = try await second.snapshot()

        #expect(snapshot.locations.map(\.name) == ["Fridge", "Freezer", "Pantry"])
        let entry = try #require(snapshot.entries.first)
        #expect(snapshot.entries.count == 1)
        #expect(entry.package.name == "Milk")
        #expect(entry.package.quantity == .low)
        #expect(entry.package.openedAt == syncEpoch)
        #expect(entry.assessment.state == .useSoon)
        let barcode = try await LocalStore(backend: backend).productEvidence.barcode(of: milk, in: world.space)
        #expect(barcode == GTIN("036000291452"))
    }
}
