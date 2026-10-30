import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain

private let space = SpaceID()

private func makeActions(_ time: FixedTime = FixedTime(Date(timeIntervalSince1970: 1_800_000_000))) -> ShoppingListActions {
    ShoppingListActions(repository: InMemoryShopping(), time: time)
}

@Suite("Shopping duplicates")
struct ShoppingDuplicateActionTests {
    @Test("duplicates are listed and merged on the person's request")
    func listAndMerge() async throws {
        let time = FixedTime(Date(timeIntervalSince1970: 1_800_000_000))
        let actions = makeActions(time)
        guard case .added(let first) = try await actions.add(name: "Eggs", in: space) else { return }
        time.advance(hours: 1)
        try await actions.add(name: "eggs", allowDuplicate: true, in: space)

        let groups = try await actions.duplicateGroups(in: space)
        #expect(groups.count == 1)
        #expect(groups[0].keeper.id == first.id)

        try await actions.mergeDuplicates(of: first.id, in: space)

        #expect(try await actions.duplicateGroups(in: space).isEmpty)
        #expect(try await actions.exportSelection(in: space).count == 1)
    }

    @Test("a merge can be undone")
    func undo() async throws {
        let time = FixedTime(Date(timeIntervalSince1970: 1_800_000_000))
        let actions = makeActions(time)
        guard case .added(let first) = try await actions.add(name: "Eggs", in: space) else { return }
        time.advance(hours: 1)
        try await actions.add(name: "Eggs", quantity: "6", allowDuplicate: true, in: space)

        let merge = try await actions.mergeDuplicates(of: first.id, in: space)
        try await actions.undoMerge(merge, in: space)

        #expect(try await actions.duplicateGroups(in: space).count == 1)
        #expect(try await actions.exportSelection(in: space).map(\.quantity) == [nil, "6"])
    }

    @Test("merging an item that has no duplicate fails and changes nothing")
    func notADuplicate() async throws {
        let actions = makeActions()
        guard case .added(let only) = try await actions.add(name: "Eggs", in: space) else { return }

        await #expect(throws: ShoppingError.notADuplicate) {
            try await actions.mergeDuplicates(of: only.id, in: space)
        }
        #expect(try await actions.exportSelection(in: space).count == 1)
    }

    @Test("a failed save surfaces and merges nothing")
    func saveFailure() async throws {
        let repository = InMemoryShopping()
        let time = FixedTime(Date(timeIntervalSince1970: 1_800_000_000))
        let actions = ShoppingListActions(repository: repository, time: time)
        guard case .added(let first) = try await actions.add(name: "Eggs", in: space) else { return }
        time.advance(hours: 1)
        try await actions.add(name: "Eggs", allowDuplicate: true, in: space)
        await repository.setFailOnSave(true)

        await #expect(throws: FakeFailure.self) {
            try await actions.mergeDuplicates(of: first.id, in: space)
        }
        #expect(try await actions.duplicateGroups(in: space).count == 1)
    }
}
