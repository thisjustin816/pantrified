import Foundation
import Testing
import PantrifiedTestSupport
@testable import PantrifiedDomain

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func minutes(_ n: Double) -> Date { t0.addingTimeInterval(n * 60) }

private struct Replica {
    var clock = HybridClock(replica: ReplicaID())
    var records = RecordSet()

    var list: ShoppingList { ShoppingRecords.materialize(from: records) }

    /// Applies a local change the way a repository would: read, change, record the difference.
    @discardableResult
    mutating func change(at minute: Double, _ body: (inout ShoppingList) throws -> Void) rethrows -> [SyncRecord] {
        var list = self.list
        try body(&list)
        var clock = self.clock
        let changes = ShoppingRecords.changes(from: list, against: records) { clock.tick(now: minutes(minute)) }
        self.clock = clock
        for change in changes { records.merge(change) }
        return changes
    }

    mutating func receive(_ incoming: [SyncRecord]) {
        for record in incoming {
            clock.observe(record.latestStamp)
            records.merge(record)
        }
    }
}

private func item(_ list: ShoppingList, _ name: String) throws -> ShoppingItem {
    try #require(list.items.first { $0.name == name })
}

@Suite("Shopping item records")
struct ShoppingRecordsTests {
    @Test("added items keep their list order on another replica")
    func addKeepsOrder() throws {
        var a = Replica()
        let changes = try a.change(at: 0) {
            try $0.add(name: "Milk", quantity: "1 gallon", category: "Dairy", at: minutes(0))
            try $0.add(name: "Eggs", at: minutes(0))
        }
        var b = Replica()
        b.receive(changes.reversed())

        #expect(b.list.items == a.list.items)
        #expect(b.list.items.map(\.name) == ["Milk", "Eggs"])
    }

    @Test("an edit writes only the fields that changed")
    func editWritesChangedFields() throws {
        var a = Replica()
        try a.change(at: 0) { try $0.add(name: "Milk", at: minutes(0)) }
        let milk = try item(a.list, "Milk")
        let changes = try a.change(at: 1) { try $0.setChecked(milk.id, true, at: minutes(1)) }

        #expect(changes.count == 1)
        #expect(changes.first.map { Set($0.fields.keys) } == ["checkedAt"])
    }

    @Test("concurrent edits to different fields of one item both survive")
    func concurrentFieldEdits() throws {
        var a = Replica()
        var b = Replica()
        b.receive(try a.change(at: 0) { try $0.add(name: "Milk", at: minutes(0)) })
        let milk = try item(a.list, "Milk")

        let check = try a.change(at: 1) { try $0.setChecked(milk.id, true, at: minutes(1)) }
        let rename = b.change(at: 1) { list in
            var items = list.items
            items[0].name = "Oat milk"
            list = ShoppingList(items: items)
        }
        a.receive(rename)
        b.receive(check)

        #expect(a.list.items == b.list.items)
        #expect(a.list.items.first?.name == "Oat milk")
        #expect(a.list.items.first?.isChecked == true)
    }

    @Test("removal and a concurrent edit both survive, and restoring brings back the edit")
    func removalKeepsConcurrentEdit() throws {
        var a = Replica()
        var b = Replica()
        b.receive(try a.change(at: 0) { try $0.add(name: "Milk", at: minutes(0)) })
        let milk = try item(a.list, "Milk")

        var removed: RemovedShoppingItems?
        let removal = a.change(at: 1) { removed = $0.remove([milk.id]) }
        let check = try b.change(at: 2) { try $0.setChecked(milk.id, true, at: minutes(2)) }
        a.receive(check)
        b.receive(removal)

        #expect(a.list.items.isEmpty)
        #expect(b.list.items.isEmpty)

        let restore = try a.change(at: 3) { list in
            list.restore(try #require(removed))
        }
        b.receive(restore)

        #expect(b.list.items.first?.isChecked == true)
        #expect(a.list.items == b.list.items)
    }

    @Test("concurrent removal and restore resolve to the later write", arguments: [(2.0, true), (4.0, false)])
    func removeVersusRestore(restoreMinute: Double, removedOnB: Bool) throws {
        var a = Replica()
        var b = Replica()
        b.receive(try a.change(at: 0) { try $0.add(name: "Milk", at: minutes(0)) })
        let milk = try item(a.list, "Milk")

        var removed: RemovedShoppingItems?
        var fromA = a.change(at: 1) { removed = $0.remove([milk.id]) }
        fromA += try a.change(at: restoreMinute) { list in list.restore(try #require(removed)) }
        let fromB = b.change(at: 3) { _ = $0.remove([milk.id]) }
        a.receive(fromB)
        b.receive(fromA)

        #expect(a.list.items.isEmpty == removedOnB)
        #expect(a.list.items == b.list.items)
    }

    @Test("concurrent additions of the same name are both kept")
    func concurrentDuplicates() throws {
        var a = Replica()
        var b = Replica()
        let fromA = try a.change(at: 0) { try $0.add(name: "Milk", at: minutes(0)) }
        let fromB = try b.change(at: 0) { try $0.add(name: "milk", at: minutes(0)) }
        a.receive(fromB)
        b.receive(fromA)

        #expect(a.list.items.count == 2)
        #expect(a.list.items == b.list.items)
    }

    @Test("an item this version cannot read is not marked removed by a local change")
    func unreadableItemIsNotRemoved() throws {
        var a = Replica()
        try a.change(at: 0) { try $0.add(name: "Milk", at: minutes(0)) }
        let stamp = a.clock.tick(now: minutes(1))
        var future = SyncRecord(
            id: RecordID(kind: .shoppingItem, entity: UUID()),
            writing: [
                "name": .string("Bulk rice"), "category": .null, "quantity": .null, "addedAt": .date(minutes(1)),
                "checkedAt": .null, "removed": .bool(false), "unitPrice": .double(2),
            ],
            at: stamp
        )
        future.minimumReaderVersion = SyncFormat.version + 1
        a.records.merge(future)

        let changes = try a.change(at: 2) { try $0.add(name: "Eggs", at: minutes(2)) }

        #expect(!a.list.items.contains { $0.name == "Bulk rice" })
        #expect(!changes.contains { $0.id == future.id })
        #expect(a.records[future.id] == future)
    }

    @Test("fields added by a newer version survive local edits")
    func unknownFieldsSurviveEdits() throws {
        var a = Replica()
        try a.change(at: 0) { try $0.add(name: "Milk", at: minutes(0)) }
        let milk = try item(a.list, "Milk")
        let id = RecordID(kind: .shoppingItem, entity: milk.id.rawValue)
        let stamp = a.clock.tick(now: minutes(1))
        a.records.merge(SyncRecord(id: id, writing: ["aisle": .string("Dairy")], at: stamp, created: try #require(a.records[id]).created))

        try a.change(at: 2) { try $0.setChecked(milk.id, true, at: minutes(2)) }

        #expect(a.records[id]?.value("aisle") == .string("Dairy"))
        #expect(a.list.items.first?.isChecked == true)
    }

    @Test("every delivery order of the same writes builds the same list", arguments: 0..<30)
    func deliveryOrderDoesNotMatter(seed: UInt64) throws {
        var rng = SeededGenerator(seed: seed)
        var a = Replica()
        var b = Replica()
        var c = Replica()
        let setup = try a.change(at: 0) {
            try $0.add(name: "Milk", at: minutes(0))
            try $0.add(name: "Eggs", at: minutes(0))
        }
        b.receive(setup)
        c.receive(setup)
        let milk = try item(a.list, "Milk")
        let eggs = try item(a.list, "Eggs")

        let writes = setup
            + (try a.change(at: 1) { try $0.setChecked(milk.id, true, at: minutes(1)) })
            + b.change(at: 2) { _ = $0.remove([eggs.id]) }
            + (try c.change(at: 1) {
                try $0.add(name: "Bread", at: minutes(1))
                try $0.setChecked(eggs.id, true, at: minutes(1))
            })

        var reference = Replica()
        reference.receive(writes)
        var shuffled = Replica()
        shuffled.receive((writes + writes.suffix(3)).shuffled(using: &rng))

        #expect(shuffled.records == reference.records)
        #expect(shuffled.list.items == reference.list.items)
        #expect(shuffled.list.items.map(\.name) == ["Milk", "Bread"])
    }
}
