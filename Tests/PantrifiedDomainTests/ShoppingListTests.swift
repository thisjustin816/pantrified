import Foundation
import Testing
@testable import PantrifiedDomain

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func added(_ result: ShoppingList.AddResult) -> ShoppingItem? {
    if case .added(let item) = result { item } else { nil }
}

@Suite("Shopping list entry")
struct ShoppingListEntryTests {
    @Test("adds an item with optional quantity and category")
    func add() throws {
        var list = ShoppingList()
        let item = try #require(added(try list.add(name: "Eggs", quantity: "1 dozen", category: "Dairy", at: t0)))

        #expect(list.items == [item])
        #expect(item.quantity == "1 dozen")
        #expect(item.category == "Dairy")
        #expect(!item.isChecked)
    }

    @Test("a blank name is rejected")
    func blank() {
        var list = ShoppingList()

        #expect(throws: ShoppingError.blankName) {
            try list.add(name: "   ", at: t0)
        }
    }

    @Test("an exact normalized-name match on an unchecked item is a duplicate")
    func duplicate() throws {
        var list = ShoppingList()
        let first = try #require(added(try list.add(name: "Eggs", at: t0)))
        let result = try list.add(name: "egg", at: t0)

        #expect(result == .duplicate(of: first))
        #expect(list.items.count == 1)
    }

    @Test("a similar but different name is not a duplicate")
    func notDuplicate() throws {
        var list = ShoppingList()
        try list.add(name: "milk", at: t0)
        try list.add(name: "oat milk", at: t0)

        #expect(list.items.count == 2)
    }

    @Test("a checked item does not block adding the same thing again")
    func checkedNotDuplicate() throws {
        var list = ShoppingList()
        let first = try #require(added(try list.add(name: "Bread", at: t0)))
        try list.setChecked(first.id, true, at: t0)
        let result = try list.add(name: "Bread", at: t0)

        #expect(added(result) != nil)
        #expect(list.items.count == 2)
    }

    @Test("the user can add a duplicate on purpose")
    func addAnyway() throws {
        var list = ShoppingList()
        try list.add(name: "Eggs", at: t0)
        let result = try list.add(name: "Eggs", at: t0, allowDuplicate: true)

        #expect(added(result) != nil)
        #expect(list.items.count == 2)
    }
}

@Suite("Shopping list check-off and removal")
struct ShoppingListCheckTests {
    @Test("checking off records the time and unchecking clears it")
    func checkOff() throws {
        var list = ShoppingList()
        let item = try #require(added(try list.add(name: "Rice", at: t0)))
        try list.setChecked(item.id, true, at: t0.addingTimeInterval(60))
        #expect(list.items[0].checkedAt == t0.addingTimeInterval(60))

        try list.setChecked(item.id, false, at: t0.addingTimeInterval(120))
        #expect(list.items[0].checkedAt == nil)
    }

    @Test("checking an unknown item fails")
    func unknown() {
        var list = ShoppingList()

        #expect(throws: ShoppingError.itemNotFound) {
            try list.setChecked(ShoppingItemID(), true, at: t0)
        }
    }

    @Test("clearing checked items removes only those and can be undone in place")
    func clearAndRestore() throws {
        var list = ShoppingList()
        let a = try #require(added(try list.add(name: "A", at: t0)))
        let b = try #require(added(try list.add(name: "B", at: t0)))
        let c = try #require(added(try list.add(name: "C", at: t0)))
        try list.setChecked(a.id, true, at: t0)
        try list.setChecked(c.id, true, at: t0)

        let removed = list.clearChecked()
        #expect(list.items.map(\.name) == ["B"])

        list.restore(removed)
        #expect(list.items.map(\.name) == ["A", "B", "C"])
        #expect(list.items.map(\.id) == [a.id, b.id, c.id])
        #expect(list.items[0].isChecked && list.items[2].isChecked)
    }

    @Test("removing one item can be undone in place")
    func removeAndRestore() throws {
        var list = ShoppingList()
        try list.add(name: "A", at: t0)
        let b = try #require(added(try list.add(name: "B", at: t0)))
        try list.add(name: "C", at: t0)

        let removed = list.remove([b.id])
        list.restore(removed)

        #expect(list.items.map(\.name) == ["A", "B", "C"])
    }

    @Test("clearing with nothing checked removes nothing")
    func clearNothing() throws {
        var list = ShoppingList()
        try list.add(name: "A", at: t0)
        let removed = list.clearChecked()

        #expect(removed.isEmpty)
        #expect(list.items.count == 1)
    }
}
