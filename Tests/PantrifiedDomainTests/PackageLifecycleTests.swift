import Foundation
import Testing
@testable import PantrifiedDomain

private let fridge = StorageLocation(name: "Fridge", storageType: .refrigerated)
private let freezer = StorageLocation(name: "Freezer", storageType: .frozen)
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func hours(_ n: Double) -> Date { t0.addingTimeInterval(n * 3600) }

private func makePackage() -> Package {
    Package(
        spaceID: SpaceID(),
        name: "Yogurt",
        location: fridge.id,
        addedAt: t0
    )
}

@Suite("Package creation")
struct PackageCreationTests {
    @Test("a package with no quantity, date, or product is a valid active record")
    func incompleteRecordIsValid() {
        let package = makePackage()

        #expect(package.status == .active)
        #expect(package.quantity == .unknown)
        #expect(package.printedDate == nil)
        #expect(package.productID == nil)
        #expect(package.location == fridge.id)
    }
}

@Suite("Package lifecycle")
struct PackageLifecycleTests {
    @Test("opening records openedAt and keeps the first opening")
    func opened() throws {
        var package = makePackage()
        try package.record(.opened, at: hours(1))
        try package.record(.opened, at: hours(5))

        #expect(package.openedAt == hours(1))
    }

    @Test("moving changes location without implying frozen or thawed")
    func moveDoesNotImplyLifecycle() throws {
        var package = makePackage()
        try package.record(.moved(to: freezer.id), at: hours(1))

        #expect(package.location == freezer.id)
        #expect(package.frozenAt == nil)
        #expect(package.thawedAt == nil)
    }

    @Test("frozenAt and thawedAt are independent facts")
    func frozenAndThawed() throws {
        var package = makePackage()
        try package.record(.frozen, at: hours(1))
        try package.record(.thawed, at: hours(30))

        #expect(package.frozenAt == hours(1))
        #expect(package.thawedAt == hours(30))
    }

    @Test("quantity changes replace the initial quantity")
    func quantityChanged() throws {
        var package = makePackage()
        try package.record(.quantityChanged(.aboutHalf), at: hours(2))

        #expect(package.quantity == .aboutHalf)
    }

    @Test("Used up removes the package from active inventory and keeps history")
    func usedUp() throws {
        var package = makePackage()
        try package.record(.usedUp, at: hours(3))

        #expect(package.status == .usedUp(at: hours(3)))
        #expect(package.events.count == 1)
    }

    @Test("Discard keeps the optional reason")
    func discarded() throws {
        var package = makePackage()
        try package.record(.discarded(reason: .spoiled), at: hours(3))

        #expect(package.status == .discarded(at: hours(3), reason: .spoiled))
    }

    @Test("Discard works without a reason")
    func discardedWithoutReason() throws {
        var package = makePackage()
        try package.record(.discarded(reason: nil), at: hours(3))

        #expect(package.status == .discarded(at: hours(3), reason: nil))
    }

    @Test("an inactive package rejects further changes")
    func inactiveRejectsChanges() throws {
        var package = makePackage()
        try package.record(.usedUp, at: hours(3))

        #expect(throws: PackageError.notActive) {
            try package.record(.opened, at: hours(4))
        }
    }

    @Test("Still have it records presence without touching lifecycle facts")
    func confirmedPresent() throws {
        var package = makePackage()
        try package.record(.opened, at: hours(1))
        try package.record(.confirmedPresent, at: hours(48))

        #expect(package.lastConfirmedAt == hours(48))
        #expect(package.openedAt == hours(1))
    }
}

@Suite("Package undo")
struct PackageUndoTests {
    @Test("undoing Used up returns the package to active inventory")
    func undoUsedUp() throws {
        var package = makePackage()
        let usedUp = try package.record(.usedUp, at: hours(3))
        try package.undo(usedUp, at: hours(3.01))

        #expect(package.status == .active)
    }

    @Test("undoing a move restores the previous location")
    func undoMove() throws {
        var package = makePackage()
        try package.record(.moved(to: freezer.id), at: hours(1))
        let second = try package.record(.moved(to: fridge.id), at: hours(2))
        #expect(package.location == fridge.id)

        try package.undo(second, at: hours(2.01))
        #expect(package.location == freezer.id)
    }

    @Test("undoing a move in the middle of the history leaves later events alone")
    func undoEarlierEvent() throws {
        var package = makePackage()
        let opened = try package.record(.opened, at: hours(1))
        try package.record(.quantityChanged(.low), at: hours(2))
        try package.undo(opened, at: hours(3))

        #expect(package.openedAt == nil)
        #expect(package.quantity == .low)
    }

    @Test("history keeps the undone event and the undo marker")
    func historyRetained() throws {
        var package = makePackage()
        let opened = try package.record(.opened, at: hours(1))
        try package.undo(opened, at: hours(2))

        #expect(package.events.count == 2)
    }

    @Test("undoing an unknown event fails")
    func undoUnknown() {
        var package = makePackage()

        #expect(throws: PackageError.eventNotFound) {
            try package.undo(PackageEventID(), at: hours(1))
        }
    }

    @Test("undoing the same event twice fails")
    func undoTwice() throws {
        var package = makePackage()
        let opened = try package.record(.opened, at: hours(1))
        try package.undo(opened, at: hours(2))

        #expect(throws: PackageError.alreadyUndone) {
            try package.undo(opened, at: hours(3))
        }
    }

    @Test("an undo marker cannot itself be undone")
    func undoOfUndo() throws {
        var package = makePackage()
        let opened = try package.record(.opened, at: hours(1))
        try package.undo(opened, at: hours(2))
        let marker = try #require(package.events.last?.id)

        #expect(throws: PackageError.cannotUndoUndo) {
            try package.undo(marker, at: hours(3))
        }
    }
}
