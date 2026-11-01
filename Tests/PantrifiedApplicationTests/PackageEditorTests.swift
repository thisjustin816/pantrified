import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain
import PantrifiedTestSupport

@Suite("Package editor")
struct PackageEditorTests {
    private func useBy(_ month: Int, _ day: Int) throws -> PrintedDate {
        try #require(PrintedDate.onDay(.useBy, year: 2027, month: month, day: day))
    }

    /// A stored jar of mayonnaise with a printed date and half left, and an editor over its store.
    private func setup(_ store: InventoryStore) async throws -> (editor: PackageEditor, inventory: any InventoryRepository, id: PackageID) {
        let world = World()
        let jar = Package(
            spaceID: world.space, name: "Mayonnaise", location: world.fridge.id,
            quantity: .aboutHalf, printedDate: try useBy(3, 1), addedAt: syncEpoch
        )
        let inventory = try await store.make(world, holding: [jar])
        return (PackageEditor(inventory: inventory, time: FixedTime(syncEpoch)), inventory, jar.id)
    }

    private func stored(_ setup: (editor: PackageEditor, inventory: any InventoryRepository, id: PackageID)) async throws -> Package {
        try #require(try await setup.inventory.package(setup.id))
    }

    @Test("a name, an amount and a date change together, as the person's own corrections", arguments: InventoryStore.allCases)
    func editsEveryField(store: InventoryStore) async throws {
        let s = try await setup(store)
        let before = try await stored(s).events.count

        let outcome = try await s.editor.apply(
            PackageEdit(name: .set("Hellmann's mayonnaise"), quantity: .set(.low), printedDate: .set(try useBy(4, 9))), to: s.id
        )

        guard case .applied(let tokens) = outcome else { Issue.record("not applied"); return }
        let package = try await stored(s)
        #expect(tokens.count == 3)
        #expect(package.events.count == before + 3)
        #expect(package.name == "Hellmann's mayonnaise")
        #expect(package.quantity == .low)
        #expect(package.printedDate == (try useBy(4, 9)))
        #expect(package.confirmedFields.isSuperset(of: [.name, .printedDate]))
    }

    @Test("a name is stored without the spaces around it", arguments: InventoryStore.allCases)
    func nameIsTrimmed(store: InventoryStore) async throws {
        let s = try await setup(store)

        _ = try await s.editor.apply(PackageEdit(name: .set("  Light mayo \n")), to: s.id)

        #expect(try await stored(s).name == "Light mayo")
    }

    @Test("values the food already holds write nothing", arguments: InventoryStore.allCases)
    func unchangedWritesNothing(store: InventoryStore) async throws {
        let s = try await setup(store)
        let before = try await stored(s).events.count

        let same = PackageEdit(name: .set(" Mayonnaise "), quantity: .set(.aboutHalf), printedDate: .set(try useBy(3, 1)))
        #expect(try await s.editor.apply(same, to: s.id) == .unchanged)
        #expect(try await s.editor.apply(PackageEdit(), to: s.id) == .unchanged)
        #expect(try await stored(s).events.count == before)
    }

    @Test("only the fields that differ are written", arguments: InventoryStore.allCases)
    func onlyChangedFields(store: InventoryStore) async throws {
        let s = try await setup(store)
        let before = try await stored(s).events.count

        let outcome = try await s.editor.apply(
            PackageEdit(name: .set("Mayonnaise"), quantity: .set(.full), printedDate: .keep), to: s.id
        )

        guard case .applied(let tokens) = outcome else { Issue.record("not applied"); return }
        #expect(tokens.count == 1)
        #expect(try await stored(s).events.count == before + 1)
        #expect(try await stored(s).quantity == .full)
    }

    @Test("an empty name is refused and nothing is stored", arguments: InventoryStore.allCases)
    func emptyNameRefused(store: InventoryStore) async throws {
        let s = try await setup(store)
        let before = try await stored(s)

        await #expect(throws: PantryError.nameRequired) {
            try await s.editor.apply(PackageEdit(name: .set("  \t"), quantity: .set(.low)), to: s.id)
        }

        let after = try await stored(s)
        #expect(after.events.count == before.events.count)
        #expect(after.name == before.name)
        #expect(after.quantity == before.quantity)
    }

    @Test("the date can be cleared, and clearing it is the person's decision too", arguments: InventoryStore.allCases)
    func dateCleared(store: InventoryStore) async throws {
        let s = try await setup(store)

        _ = try await s.editor.apply(PackageEdit(printedDate: .set(nil)), to: s.id)

        let package = try await stored(s)
        #expect(package.printedDate == nil)
        #expect(package.confirmedFields.contains(.printedDate))
    }

    @Test("a later recognition or lookup does not replace what the person set", arguments: InventoryStore.allCases)
    func recognitionDoesNotReplaceEdits(store: InventoryStore) async throws {
        let s = try await setup(store)
        _ = try await s.editor.apply(PackageEdit(name: .set("My mayo"), printedDate: .set(try useBy(4, 9))), to: s.id)

        var package = try await stored(s)
        try package.propose(
            PackageProposal(name: "HELLMANN'S REAL MAYONNAISE", printedDate: try useBy(8, 1)),
            at: syncEpoch.addingTimeInterval(60)
        )
        try await s.inventory.save(package)

        let after = try await stored(s)
        #expect(after.name == "My mayo")
        #expect(after.printedDate == (try useBy(4, 9)))
    }

    @Test("undo puts every field of one edit back in a single step", arguments: InventoryStore.allCases)
    func undoRestoresAll(store: InventoryStore) async throws {
        let s = try await setup(store)
        let original = try await stored(s)
        let outcome = try await s.editor.apply(
            PackageEdit(name: .set("Other"), quantity: .set(.low), printedDate: .set(nil)), to: s.id
        )
        guard case .applied(let tokens) = outcome else { Issue.record("not applied"); return }

        try await s.editor.undo(tokens)

        let package = try await stored(s)
        #expect(package.name == original.name)
        #expect(package.quantity == original.quantity)
        #expect(package.printedDate == original.printedDate)
        #expect(package.confirmedFields == original.confirmedFields)
    }

    @Test("a food that is no longer active cannot be edited, and an unknown one is not found", arguments: InventoryStore.allCases)
    func inactiveAndUnknown(store: InventoryStore) async throws {
        let s = try await setup(store)
        var package = try await stored(s)
        try package.record(.usedUp, at: syncEpoch)
        try await s.inventory.save(package)

        await #expect(throws: PackageError.notActive) {
            try await s.editor.apply(PackageEdit(quantity: .set(.low)), to: s.id)
        }
        // Even an edit that would change nothing is refused for a food that is gone.
        await #expect(throws: PackageError.notActive) {
            try await s.editor.apply(PackageEdit(), to: s.id)
        }
        await #expect(throws: PackageActionError.packageNotFound) {
            try await s.editor.apply(PackageEdit(quantity: .set(.low)), to: PackageID())
        }
    }

    @Test("tokens from two foods are refused together and change nothing", arguments: InventoryStore.allCases)
    func mixedTokens(store: InventoryStore) async throws {
        let s = try await setup(store)
        let outcome = try await s.editor.apply(PackageEdit(quantity: .set(.low)), to: s.id)
        guard case .applied(let tokens) = outcome else { Issue.record("not applied"); return }
        let stray = UndoToken(packageID: PackageID(), eventID: PackageEventID())

        await #expect(throws: PackageActionError.undoSpansPackages) { try await s.editor.undo(tokens + [stray]) }

        #expect(try await stored(s).quantity == .low)
        try await s.editor.undo([])
    }
}
