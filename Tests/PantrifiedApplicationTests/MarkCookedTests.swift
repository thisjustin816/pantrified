import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private struct Fixture {
    let space = SpaceID()
    let location = LocationID()
    let inventory: InMemoryInventory
    let markCooked: MarkCooked
    let packages: [Package]

    init(_ quantities: [Quantity]) {
        let space = space
        let location = location
        let packages = quantities.enumerated().map { index, quantity in
            Package(spaceID: space, name: "Item \(index)", location: location, quantity: quantity, addedAt: t0)
        }
        self.packages = packages
        inventory = InMemoryInventory(packages)
        markCooked = MarkCooked(inventory: inventory, time: FixedTime(t0.addingTimeInterval(3600)))
    }

    func stored(_ index: Int) async throws -> Package {
        try #require(await inventory.package(packages[index].id))
    }
}

@Suite("Mark cooked")
struct MarkCookedTests {
    @Test("Used some steps the quantity down, Used up removes the package, No change leaves it alone")
    func mixedOutcomes() async throws {
        let f = Fixture([.full, .aboutHalf, .low])
        let receipt = try await f.markCooked.reconcile([
            IngredientUse(packageID: f.packages[0].id, outcome: .usedSome),
            IngredientUse(packageID: f.packages[1].id, outcome: .usedUp),
            IngredientUse(packageID: f.packages[2].id, outcome: .noChange),
        ])

        #expect(try await f.stored(0).quantity == .aboutHalf)
        #expect(try await f.stored(1).status == .usedUp(at: t0.addingTimeInterval(3600)))
        #expect(try await f.stored(2).events.isEmpty)
        #expect(receipt.tokens.count == 2)
    }

    @Test("an exact amount is flagged for correction instead of being guessed")
    func exactFlagged() async throws {
        let exact = Quantity.exact(500, unit: "g")
        let f = Fixture([exact])
        let receipt = try await f.markCooked.reconcile([
            IngredientUse(packageID: f.packages[0].id, outcome: .usedSome),
        ])

        #expect(try await f.stored(0).quantity == exact)
        #expect(receipt.needsQuantityCheck == [f.packages[0].id])
    }

    @Test("a package that is missing or already used up is skipped, not an error")
    func skipsUnavailable() async throws {
        let f = Fixture([.full, .full])
        var gone = try await f.stored(1)
        try gone.record(.usedUp, at: t0)
        try await f.inventory.save(gone)
        let unknown = PackageID()

        let receipt = try await f.markCooked.reconcile([
            IngredientUse(packageID: f.packages[0].id, outcome: .usedSome),
            IngredientUse(packageID: f.packages[1].id, outcome: .usedSome),
            IngredientUse(packageID: unknown, outcome: .usedUp),
        ])

        #expect(receipt.skipped == [f.packages[1].id, unknown])
        #expect(try await f.stored(0).quantity == .aboutHalf)
    }

    @Test("when a package is listed twice the last choice wins")
    func duplicateEntries() async throws {
        let f = Fixture([.full])
        let id = f.packages[0].id
        _ = try await f.markCooked.reconcile([
            IngredientUse(packageID: id, outcome: .usedUp),
            IngredientUse(packageID: id, outcome: .usedSome),
        ])

        #expect(try await f.stored(0).status == .active)
        #expect(try await f.stored(0).quantity == .aboutHalf)
    }

    @Test("a failed save changes nothing")
    func saveFailure() async throws {
        let f = Fixture([.full, .full])
        await f.inventory.setFailOnSave(true)

        await #expect(throws: FakeFailure.self) {
            try await f.markCooked.reconcile([
                IngredientUse(packageID: f.packages[0].id, outcome: .usedUp),
                IngredientUse(packageID: f.packages[1].id, outcome: .usedSome),
            ])
        }
        #expect(try await f.stored(0).status == .active)
        #expect(try await f.stored(1).quantity == .full)
    }

    @Test("an all-No-change reconcile writes nothing")
    func nothingToWrite() async throws {
        let f = Fixture([.full])
        let receipt = try await f.markCooked.reconcile([
            IngredientUse(packageID: f.packages[0].id, outcome: .noChange),
        ])

        #expect(receipt.tokens.isEmpty)
        #expect(await f.inventory.saveCount == 0)
    }
}

@Suite("Undo mark cooked")
struct UndoMarkCookedTests {
    @Test("undoing the receipt restores every package")
    func undoAll() async throws {
        let f = Fixture([.full, .aboutHalf])
        let receipt = try await f.markCooked.reconcile([
            IngredientUse(packageID: f.packages[0].id, outcome: .usedSome),
            IngredientUse(packageID: f.packages[1].id, outcome: .usedUp),
        ])
        try await f.markCooked.undo(receipt)

        #expect(try await f.stored(0).quantity == .full)
        #expect(try await f.stored(1).status == .active)
    }

    @Test("undoing twice fails and leaves the restored state alone")
    func undoTwice() async throws {
        let f = Fixture([.full])
        let receipt = try await f.markCooked.reconcile([
            IngredientUse(packageID: f.packages[0].id, outcome: .usedSome),
        ])
        try await f.markCooked.undo(receipt)

        await #expect(throws: PackageError.alreadyUndone) {
            try await f.markCooked.undo(receipt)
        }
        #expect(try await f.stored(0).quantity == .full)
    }
}
