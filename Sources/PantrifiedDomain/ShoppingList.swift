import Foundation

public enum ShoppingItemTag: Sendable {}
public typealias ShoppingItemID = Identifier<ShoppingItemTag>

public enum ShoppingError: Error, Sendable, Equatable {
    case blankName
    case itemNotFound
    case notADuplicate
}

public struct ShoppingItem: Sendable, Hashable, Identifiable {
    public let id: ShoppingItemID
    public var name: String
    public var category: String?
    /// Free text such as "1 dozen"; shopping quantities are not inventory quantities.
    public var quantity: String?
    public let addedAt: Date
    public var checkedAt: Date?

    public var isChecked: Bool { checkedAt != nil }
    public var normalizedName: IngredientName { IngredientName(name) }
}

public struct RemovedShoppingItems: Sendable, Hashable {
    fileprivate let entries: [(index: Int, item: ShoppingItem)]

    public var isEmpty: Bool { entries.isEmpty }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entries.map(\.index) == rhs.entries.map(\.index) && lhs.entries.map(\.item) == rhs.entries.map(\.item)
    }

    public func hash(into hasher: inout Hasher) {
        for entry in entries {
            hasher.combine(entry.index)
            hasher.combine(entry.item)
        }
    }
}

/// A Space's shopping list. Checking an item off never creates inventory; that is a separate,
/// explicit step.
public struct ShoppingList: Sendable {
    public enum AddResult: Sendable, Hashable {
        case added(ShoppingItem)
        case duplicate(of: ShoppingItem)
    }

    public private(set) var items: [ShoppingItem]

    public init(items: [ShoppingItem] = []) {
        self.items = items
    }

    /// Duplicates are exact normalized-name matches against unchecked items. Fuzzier overlaps are
    /// not duplicates, and a checked-off item does not block buying the thing again.
    @discardableResult
    public mutating func add(
        name: String,
        quantity: String? = nil,
        category: String? = nil,
        at date: Date,
        allowDuplicate: Bool = false
    ) throws -> AddResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ShoppingError.blankName }

        let normalized = IngredientName(trimmed)
        if !allowDuplicate,
           let existing = items.first(where: { !$0.isChecked && $0.normalizedName == normalized }) {
            return .duplicate(of: existing)
        }

        let item = ShoppingItem(
            id: ShoppingItemID(), name: trimmed, category: category, quantity: quantity, addedAt: date
        )
        items.append(item)
        return .added(item)
    }

    public mutating func setChecked(_ id: ShoppingItemID, _ checked: Bool, at date: Date) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw ShoppingError.itemNotFound }
        items[index].checkedAt = checked ? date : nil
    }

    public mutating func remove(_ ids: Set<ShoppingItemID>) -> RemovedShoppingItems {
        let entries = items.enumerated().filter { ids.contains($0.element.id) }.map { (index: $0.offset, item: $0.element) }
        items.removeAll { ids.contains($0.id) }
        return RemovedShoppingItems(entries: entries)
    }

    public mutating func clearChecked() -> RemovedShoppingItems {
        remove(Set(items.filter(\.isChecked).map(\.id)))
    }

    /// Changes one item in place. Callers that need the change to be undoable keep what they replaced.
    mutating func modify(_ id: ShoppingItemID, _ change: (inout ShoppingItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    /// Puts removed items back at their original positions.
    public mutating func restore(_ removed: RemovedShoppingItems) {
        for entry in removed.entries where !items.contains(where: { $0.id == entry.item.id }) {
            items.insert(entry.item, at: min(entry.index, items.count))
        }
    }
}
