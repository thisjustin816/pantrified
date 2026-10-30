import Foundation

/// Unchecked items that match by the add-time duplicate rule. The first item is the one a merge
/// keeps: the earliest added, with ties broken by id so every device picks the same one.
public struct DuplicateGroup: Sendable, Hashable {
    public let items: [ShoppingItem]

    public var keeper: ShoppingItem { items[0] }
}

public struct ShoppingMerge: Sendable, Hashable {
    public let keeper: ShoppingItemID
    public let removed: RemovedShoppingItems
    fileprivate let adoptedQuantity: String?
    fileprivate let adoptedCategory: String?
}

extension ShoppingList {
    /// Duplicates arise when devices add the same item while apart. Nothing is merged automatically;
    /// the groups are shown and the person chooses to merge.
    public var duplicateGroups: [DuplicateGroup] {
        var order: [IngredientName] = []
        var buckets: [IngredientName: [ShoppingItem]] = [:]
        for item in items where !item.isChecked {
            let name = item.normalizedName
            guard !name.isEmpty else { continue }
            if buckets[name] == nil { order.append(name) }
            buckets[name, default: []].append(item)
        }
        return order.compactMap { name in
            guard let members = buckets[name], members.count > 1 else { return nil }
            return DuplicateGroup(items: members.sorted(by: Self.mergeOrder))
        }
    }

    /// Keeps the group's first item and removes the rest. The kept item adopts a quantity or category
    /// it lacks from the first removed item that has one, and never overwrites a value of its own.
    @discardableResult
    public mutating func mergeDuplicates(of id: ShoppingItemID) throws -> ShoppingMerge {
        guard items.contains(where: { $0.id == id }) else { throw ShoppingError.itemNotFound }
        guard let group = duplicateGroups.first(where: { $0.items.contains { $0.id == id } }) else {
            throw ShoppingError.notADuplicate
        }

        let keeper = group.keeper
        let others = Array(group.items.dropFirst())
        let adoptedQuantity = keeper.quantity == nil ? others.lazy.compactMap(\.quantity).first : nil
        let adoptedCategory = keeper.category == nil ? others.lazy.compactMap(\.category).first : nil

        let removed = remove(Set(others.map(\.id)))
        modify(keeper.id) {
            if let adoptedQuantity { $0.quantity = adoptedQuantity }
            if let adoptedCategory { $0.category = adoptedCategory }
        }
        return ShoppingMerge(
            keeper: keeper.id, removed: removed, adoptedQuantity: adoptedQuantity, adoptedCategory: adoptedCategory
        )
    }

    /// Brings the merged items back and takes back what the kept item adopted, unless it has been
    /// changed since.
    public mutating func restore(_ merge: ShoppingMerge) {
        restore(merge.removed)
        modify(merge.keeper) {
            if let adopted = merge.adoptedQuantity, $0.quantity == adopted { $0.quantity = nil }
            if let adopted = merge.adoptedCategory, $0.category == adopted { $0.category = nil }
        }
    }

    private static func mergeOrder(_ a: ShoppingItem, _ b: ShoppingItem) -> Bool {
        a.addedAt != b.addedAt ? a.addedAt < b.addedAt : a.id.rawValue.uuidString < b.id.rawValue.uuidString
    }
}
