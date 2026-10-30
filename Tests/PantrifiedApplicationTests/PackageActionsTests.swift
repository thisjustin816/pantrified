import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private struct Fixture {
    let space = SpaceID()
    let fridge = StorageLocation(name: "Fridge", storageType: .refrigerated)
    let freezer = StorageLocation(name: "Freezer", storageType: .frozen)
    let package: Package
    let inventory: InMemoryInventory
    let time = FixedTime(t0)
    let actions: PackageActions

    init() {
        let space = space
        let fridge = fridge
        let package = Package(spaceID: space, name: "Milk", location: fridge.id, addedAt: t0)
        self.package = package
        let inventory = InMemoryInventory([package])
        self.inventory = inventory
        let locations = InMemoryLocations(locationsBySpace: [space: [fridge, freezer]])
        self.actions = PackageActions(inventory: inventory, locations: locations, time: time)
    }

    func stored() async throws -> Package {
        try #require(await inventory.package(package.id))
    }
}

@Suite("Fast package actions")
struct PackageActionsTests {
    @Test("Opened today records the opening at the current time")
    func opened() async throws {
        let f = Fixture()
        f.time.advance(hours: 5)
        _ = try await f.actions.apply(.opened, to: f.package.id)

        #expect(try await f.stored().openedAt == t0.addingTimeInterval(5 * 3600))
    }

    @Test("opening an already-opened package changes nothing")
    func openedTwice() async throws {
        let f = Fixture()
        _ = try await f.actions.apply(.opened, to: f.package.id)
        let outcome = try await f.actions.apply(.opened, to: f.package.id)

        #expect(outcome == .unchanged)
        #expect(try await f.stored().events.count == 1)
    }

    @Test("Move changes the location")
    func move() async throws {
        let f = Fixture()
        _ = try await f.actions.apply(.move(to: f.freezer.id), to: f.package.id)

        #expect(try await f.stored().location == f.freezer.id)
    }

    @Test("moving to the current location changes nothing")
    func moveToSameLocation() async throws {
        let f = Fixture()
        let outcome = try await f.actions.apply(.move(to: f.fridge.id), to: f.package.id)

        #expect(outcome == .unchanged)
        #expect(await f.inventory.saveCount == 0)
    }

    @Test("moving to a location outside the space fails and leaves the package alone")
    func moveToUnknownLocation() async throws {
        let f = Fixture()

        await #expect(throws: PackageActionError.unknownLocation) {
            try await f.actions.apply(.move(to: LocationID()), to: f.package.id)
        }
        #expect(try await f.stored().location == f.fridge.id)
    }

    @Test("Used up and Discard take the package out of active inventory")
    func removal() async throws {
        let f = Fixture()
        _ = try await f.actions.apply(.discard(reason: .spoiled), to: f.package.id)

        #expect(try await f.stored().status == .discarded(at: t0, reason: .spoiled))
        #expect(try await f.inventory.activePackages(in: f.space).isEmpty)
    }

    @Test("an unknown package fails")
    func unknownPackage() async {
        let f = Fixture()

        await #expect(throws: PackageActionError.packageNotFound) {
            try await f.actions.apply(.usedUp, to: PackageID())
        }
    }

    @Test("acting on an inactive package surfaces the domain error")
    func inactivePackage() async throws {
        let f = Fixture()
        _ = try await f.actions.apply(.usedUp, to: f.package.id)

        await #expect(throws: PackageError.notActive) {
            try await f.actions.apply(.opened, to: f.package.id)
        }
    }

    @Test("a failed save surfaces the error and does not claim success")
    func saveFailure() async throws {
        let f = Fixture()
        await f.inventory.setFailOnSave(true)

        await #expect(throws: FakeFailure.self) {
            try await f.actions.apply(.usedUp, to: f.package.id)
        }
        #expect(try await f.stored().status == .active)
    }
}

@Suite("Undo")
struct PackageUndoUseCaseTests {
    @Test("undoing Used up restores the package to active inventory")
    func undoUsedUp() async throws {
        let f = Fixture()
        guard case .applied(let token) = try await f.actions.apply(.usedUp, to: f.package.id) else {
            Issue.record("expected an applied outcome")
            return
        }
        try await f.actions.undo(token)

        #expect(try await f.stored().status == .active)
        #expect(try await f.inventory.activePackages(in: f.space).count == 1)
    }

    @Test("undoing a move restores the earlier location")
    func undoMove() async throws {
        let f = Fixture()
        guard case .applied(let token) = try await f.actions.apply(.move(to: f.freezer.id), to: f.package.id) else {
            Issue.record("expected an applied outcome")
            return
        }
        try await f.actions.undo(token)

        #expect(try await f.stored().location == f.fridge.id)
    }

    @Test("undoing twice fails")
    func undoTwice() async throws {
        let f = Fixture()
        guard case .applied(let token) = try await f.actions.apply(.opened, to: f.package.id) else {
            Issue.record("expected an applied outcome")
            return
        }
        try await f.actions.undo(token)

        await #expect(throws: PackageError.alreadyUndone) {
            try await f.actions.undo(token)
        }
    }

    @Test("undoing for a package that no longer exists fails")
    func undoMissingPackage() async {
        let f = Fixture()
        let token = UndoToken(packageID: PackageID(), eventID: PackageEventID())

        await #expect(throws: PackageActionError.packageNotFound) {
            try await f.actions.undo(token)
        }
    }
}
