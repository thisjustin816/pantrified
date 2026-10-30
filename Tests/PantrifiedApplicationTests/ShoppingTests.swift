import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let space = SpaceID()

private func makeActions(_ repository: InMemoryShopping = InMemoryShopping()) -> (ShoppingListActions, InMemoryShopping) {
    (ShoppingListActions(repository: repository, time: FixedTime(t0)), repository)
}

@Suite("Shopping list actions")
struct ShoppingListActionsTests {
    @Test("an added item is stored and reported")
    func add() async throws {
        let (actions, repository) = makeActions()
        let result = try await actions.add(name: "Eggs", quantity: "1 dozen", in: space)

        guard case .added(let item) = result else {
            Issue.record("expected an added item")
            return
        }
        #expect(try await repository.list(in: space).items == [item])
    }

    @Test("a duplicate is reported and not stored twice")
    func duplicate() async throws {
        let (actions, repository) = makeActions()
        try await actions.add(name: "Eggs", in: space)
        let result = try await actions.add(name: "eggs", in: space)

        guard case .duplicate = result else {
            Issue.record("expected a duplicate")
            return
        }
        #expect(try await repository.list(in: space).items.count == 1)
    }

    @Test("a failed save surfaces and stores nothing")
    func saveFailure() async throws {
        let (actions, repository) = makeActions()
        await repository.setFailOnSave(true)

        await #expect(throws: FakeFailure.self) {
            try await actions.add(name: "Eggs", in: space)
        }
        #expect(try await repository.list(in: space).items.isEmpty)
    }

    @Test("checking off and clearing can be undone")
    func clearAndUndo() async throws {
        let (actions, repository) = makeActions()
        guard case .added(let a) = try await actions.add(name: "A", in: space) else { return }
        try await actions.add(name: "B", in: space)
        try await actions.setChecked(a.id, true, in: space)

        let removed = try await actions.clearChecked(in: space)
        #expect(try await repository.list(in: space).items.map(\.name) == ["B"])

        try await actions.restore(removed, in: space)
        #expect(try await repository.list(in: space).items.map(\.name) == ["A", "B"])
    }

    @Test("pasted text is added only for the lines the user kept")
    func importReview() async throws {
        let (actions, repository) = makeActions()
        try await actions.add(name: "Milk", in: space)
        let lines = try await actions.reviewImport("milk\n2 eggs\nbread", in: space)
        let kept = lines.filter(\.isIncluded)

        let added = try await actions.commitImport(kept, in: space)

        #expect(added.map(\.name) == ["eggs", "bread"])
        #expect(try await repository.list(in: space).items.map(\.name) == ["Milk", "eggs", "bread"])
    }

    @Test("the export selection is the unchecked items")
    func selection() async throws {
        let (actions, _) = makeActions()
        guard case .added(let a) = try await actions.add(name: "A", quantity: "2", in: space) else { return }
        try await actions.add(name: "B", in: space)
        try await actions.setChecked(a.id, true, in: space)

        let selection = try await actions.exportSelection(in: space)

        #expect(selection.map(\.name) == ["B"])
    }
}

@Suite("Reminders export")
struct RemindersExportTests {
    private let eggs = ShoppingExportItem(name: "Eggs")
    private let bread = ShoppingExportItem(name: "Bread")

    @Test("only items not already on the reminders list are written by default")
    func skipsExisting() async throws {
        let reminders = FakeReminders(titles: ["eggs"])
        let export = RemindersExport()
        let plan = try await export.prepare([eggs, bread], destination: reminders)

        try await export.commit(plan, addAnyway: [], destination: reminders)

        #expect(await reminders.written == [bread])
    }

    @Test("an explicit add-anyway writes the skipped item too")
    func addAnyway() async throws {
        let reminders = FakeReminders(titles: ["eggs"])
        let export = RemindersExport()
        let plan = try await export.prepare([eggs, bread], destination: reminders)

        try await export.commit(plan, addAnyway: [eggs.id], destination: reminders)

        #expect(await reminders.written == [bread, eggs])
    }

    @Test("a missing destination asks to reconnect and writes nothing")
    func missingDestination() async {
        let reminders = FakeReminders(missing: true)

        await #expect(throws: ShoppingExportError.destinationMissing) {
            try await RemindersExport().prepare([eggs], destination: reminders)
        }
        #expect(await reminders.writeCalls == 0)
    }

    @Test("nothing to write makes no destination call")
    func nothingToWrite() async throws {
        let reminders = FakeReminders(titles: ["eggs"])
        let export = RemindersExport()
        let plan = try await export.prepare([eggs], destination: reminders)

        try await export.commit(plan, addAnyway: [], destination: reminders)

        #expect(await reminders.writeCalls == 0)
    }
}
