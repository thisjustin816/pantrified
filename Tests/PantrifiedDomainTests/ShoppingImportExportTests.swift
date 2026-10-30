import Foundation
import Testing
@testable import PantrifiedDomain

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("Shopping text import")
struct ShoppingTextImportTests {
    @Test("splits lines, drops blanks, and strips list markers")
    func markers() {
        let text = "- milk\n* bread\n• eggs\n[ ] butter\n[x] jam\n1. rice\n2) beans\n\n   \n"
        let lines = ShoppingTextImport.review(text, against: ShoppingList())

        #expect(lines.map(\.name) == ["milk", "bread", "eggs", "butter", "jam", "rice", "beans"])
    }

    @Test("a leading amount becomes the quantity")
    func quantities() {
        let lines = ShoppingTextImport.review("2 eggs\n12 oz pasta\n1/2 gallon milk\n3x apples", against: ShoppingList())

        #expect(lines.map(\.name) == ["eggs", "pasta", "milk", "apples"])
        #expect(lines.map(\.quantity) == ["2", "12 oz", "1/2 gallon", "3x"])
    }

    @Test("numbers that are part of the name are left alone")
    func numbersInName() {
        let lines = ShoppingTextImport.review("2% milk\n7up\n5 spice blend", against: ShoppingList())

        #expect(lines.map(\.name) == ["2% milk", "7up", "spice blend"])
        #expect(lines.map(\.quantity) == [nil, nil, "5"])
    }

    @Test("a lone number is a name, not an empty item")
    func loneNumber() {
        let lines = ShoppingTextImport.review("12", against: ShoppingList())

        #expect(lines.map(\.name) == ["12"])
        #expect(lines[0].quantity == nil)
    }

    @Test("items already on the list are flagged and excluded by default")
    func duplicatesOnList() throws {
        var list = ShoppingList()
        guard case .added(let existing) = try list.add(name: "Milk", at: t0) else { return }
        let lines = ShoppingTextImport.review("milk\nbread", against: list)

        #expect(lines[0].duplicate == .onList(existing.id))
        #expect(!lines[0].isIncluded)
        #expect(lines[1].duplicate == nil)
        #expect(lines[1].isIncluded)
    }

    @Test("a repeat within the pasted text is flagged and excluded by default")
    func duplicatesInPaste() {
        let lines = ShoppingTextImport.review("eggs\nEggs", against: ShoppingList())

        #expect(lines[0].isIncluded)
        #expect(lines[1].duplicate == .inPaste)
        #expect(!lines[1].isIncluded)
    }

    @Test("committing adds the included lines and respects an explicit add-anyway")
    func commit() throws {
        var list = ShoppingList()
        try list.add(name: "Milk", at: t0)
        var lines = ShoppingTextImport.review("milk\nbread\nmilk", against: list)
        lines[2].isIncluded = true

        let added = try list.add(importing: lines, at: t0)

        #expect(list.items.map(\.name) == ["Milk", "bread", "milk"])
        #expect(added.count == 2)
    }
}

@Suite("Shopping export")
struct ShoppingExportTests {
    @Test("plain text is one item per line with the quantity first when present")
    func plainText() {
        let selection = [
            ShoppingExportItem(name: "eggs", quantity: "1 dozen"),
            ShoppingExportItem(name: "bread"),
        ]

        #expect(PlainTextShoppingExport.text(for: selection) == "1 dozen eggs\nbread")
    }

    @Test("an empty selection exports an empty string")
    func empty() {
        #expect(PlainTextShoppingExport.text(for: []) == "")
    }

    @Test("reminders matching an item's exact normalized name are marked already on list")
    func remindersPlan() {
        let eggs = ShoppingExportItem(name: "Eggs")
        let bread = ShoppingExportItem(name: "bread")
        let plan = ReminderExportPlanner.plan([eggs, bread], incompleteReminderTitles: ["egg", "Oat milk"])

        #expect(plan.alreadyOnList == [eggs])
        #expect(plan.toAdd == [bread])
    }

    @Test("similar names are not treated as duplicates")
    func remindersNoFuzzy() {
        let milk = ShoppingExportItem(name: "milk")
        let plan = ReminderExportPlanner.plan([milk], incompleteReminderTitles: ["oat milk"])

        #expect(plan.toAdd == [milk])
        #expect(plan.alreadyOnList.isEmpty)
    }

    @Test("the user can explicitly add a skipped item anyway")
    func addAnyway() {
        let eggs = ShoppingExportItem(name: "eggs")
        let bread = ShoppingExportItem(name: "bread")
        let plan = ReminderExportPlanner.plan([eggs, bread], incompleteReminderTitles: ["eggs"])

        #expect(plan.itemsToWrite(addAnyway: []) == [bread])
        #expect(plan.itemsToWrite(addAnyway: [eggs.id]) == [bread, eggs])
    }
}
