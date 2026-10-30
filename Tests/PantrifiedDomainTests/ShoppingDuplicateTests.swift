import Foundation
import Testing
@testable import PantrifiedDomain

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

@discardableResult
private func add(
    _ list: inout ShoppingList,
    _ name: String,
    quantity: String? = nil,
    category: String? = nil,
    at date: Date
) throws -> ShoppingItem {
    guard case .added(let item) = try list.add(
        name: name, quantity: quantity, category: category, at: date, allowDuplicate: true
    ) else { throw ShoppingError.itemNotFound }
    return item
}

@Suite("Shopping duplicate groups")
struct ShoppingDuplicateGroupTests {
    @Test("unchecked items with the same normalized name form a group, earliest first")
    func groupsEarliestFirst() throws {
        var list = ShoppingList()
        let later = try add(&list, "Eggs", at: at(20))
        let earlier = try add(&list, "egg", at: at(10))

        let groups = list.duplicateGroups

        #expect(groups.count == 1)
        #expect(groups[0].items.map(\.id) == [earlier.id, later.id])
    }

    @Test("items added at the same moment are ordered by id, so every device agrees")
    func tiesOrderedByID() throws {
        var list = ShoppingList()
        let a = try add(&list, "Milk", at: at(5))
        let b = try add(&list, "Milk", at: at(5))
        let expected = [a, b].sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }.map(\.id)

        #expect(list.duplicateGroups[0].items.map(\.id) == expected)
    }

    @Test("a checked-off item is not a duplicate")
    func checkedExcluded() throws {
        var list = ShoppingList()
        let first = try add(&list, "Bread", at: at(1))
        try add(&list, "Bread", at: at(2))
        try list.setChecked(first.id, true, at: at(3))

        #expect(list.duplicateGroups.isEmpty)
    }

    @Test("similar but different names are not duplicates")
    func notSimilar() throws {
        var list = ShoppingList()
        try add(&list, "milk", at: at(1))
        try add(&list, "oat milk", at: at(2))

        #expect(list.duplicateGroups.isEmpty)
    }

    @Test("separate names make separate groups in list order")
    func separateGroups() throws {
        var list = ShoppingList()
        try add(&list, "Eggs", at: at(1))
        try add(&list, "Milk", at: at(2))
        try add(&list, "eggs", at: at(3))
        try add(&list, "milk", at: at(4))

        #expect(list.duplicateGroups.map { $0.items[0].name } == ["Eggs", "Milk"])
    }

    @Test("a list without repeats has no groups")
    func none() throws {
        var list = ShoppingList()
        try add(&list, "Eggs", at: at(1))

        #expect(list.duplicateGroups.isEmpty)
    }
}

@Suite("Shopping duplicate merge")
struct ShoppingDuplicateMergeTests {
    @Test("merging keeps the earliest item and removes the others")
    func keepsEarliest() throws {
        var list = ShoppingList()
        let later = try add(&list, "Eggs", at: at(20))
        let earlier = try add(&list, "Eggs", at: at(10))

        _ = try list.mergeDuplicates(of: later.id)

        #expect(list.items.map(\.id) == [earlier.id])
        #expect(list.duplicateGroups.isEmpty)
    }

    @Test("tapping any member of the group merges the whole group")
    func anyMemberMerges() throws {
        var list = ShoppingList()
        let a = try add(&list, "Eggs", at: at(1))
        try add(&list, "Eggs", at: at(2))
        try add(&list, "Eggs", at: at(3))

        _ = try list.mergeDuplicates(of: a.id)

        #expect(list.items.count == 1)
    }

    @Test("the kept item adopts a missing quantity and category but never overwrites its own")
    func adoptsMissingFields() throws {
        var list = ShoppingList()
        let keeper = try add(&list, "Eggs", quantity: "1 dozen", at: at(1))
        try add(&list, "Eggs", quantity: "6", category: "Dairy", at: at(2))

        _ = try list.mergeDuplicates(of: keeper.id)

        #expect(list.items[0].quantity == "1 dozen")
        #expect(list.items[0].category == "Dairy")
    }

    @Test("the first removed item that has a value supplies it")
    func firstValueWins() throws {
        var list = ShoppingList()
        let keeper = try add(&list, "Eggs", at: at(1))
        try add(&list, "Eggs", at: at(2))
        try add(&list, "Eggs", quantity: "12", at: at(3))
        try add(&list, "Eggs", quantity: "6", at: at(4))

        _ = try list.mergeDuplicates(of: keeper.id)

        #expect(list.items[0].quantity == "12")
    }

    @Test("an item that is not part of a duplicate group cannot be merged")
    func notADuplicate() throws {
        var list = ShoppingList()
        let only = try add(&list, "Eggs", at: at(1))

        #expect(throws: ShoppingError.notADuplicate) {
            try list.mergeDuplicates(of: only.id)
        }
    }

    @Test("an unknown item cannot be merged")
    func unknown() {
        var list = ShoppingList()

        #expect(throws: ShoppingError.itemNotFound) {
            try list.mergeDuplicates(of: ShoppingItemID())
        }
    }

    @Test("undo restores the removed items in place and takes back adopted fields")
    func undo() throws {
        var list = ShoppingList()
        let keeper = try add(&list, "Eggs", at: at(1))
        try add(&list, "Milk", at: at(2))
        let removed = try add(&list, "Eggs", quantity: "6", category: "Dairy", at: at(3))
        let before = list.items

        let merge = try list.mergeDuplicates(of: keeper.id)
        #expect(list.items.map(\.name) == ["Eggs", "Milk"])

        list.restore(merge)

        #expect(list.items == before)
        #expect(list.items.map(\.id).contains(removed.id))
    }

    @Test("undo leaves a quantity changed since the merge alone")
    func undoKeepsLaterEdit() throws {
        var list = ShoppingList()
        let keeper = try add(&list, "Eggs", at: at(1))
        try add(&list, "Eggs", quantity: "6", at: at(2))
        let merge = try list.mergeDuplicates(of: keeper.id)

        var edited = list.items
        edited[0].quantity = "18"
        list = ShoppingList(items: edited)
        list.restore(merge)

        #expect(list.items.first { $0.id == keeper.id }?.quantity == "18")
        #expect(list.items.count == 2)
    }
}
