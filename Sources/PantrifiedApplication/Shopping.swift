import Foundation
import PantrifiedDomain

public struct ShoppingListActions: Sendable {
    private let repository: any ShoppingListRepository
    private let time: any TimeSource

    public init(repository: any ShoppingListRepository, time: any TimeSource) {
        self.repository = repository
        self.time = time
    }

    @discardableResult
    public func add(
        name: String,
        quantity: String? = nil,
        category: String? = nil,
        allowDuplicate: Bool = false,
        in space: SpaceID
    ) async throws -> ShoppingList.AddResult {
        try await mutate(space) {
            try $0.add(name: name, quantity: quantity, category: category, at: time.now(), allowDuplicate: allowDuplicate)
        }
    }

    public func setChecked(_ id: ShoppingItemID, _ checked: Bool, in space: SpaceID) async throws {
        try await mutate(space) { try $0.setChecked(id, checked, at: time.now()) }
    }

    public func clearChecked(in space: SpaceID) async throws -> RemovedShoppingItems {
        try await mutate(space) { $0.clearChecked() }
    }

    public func remove(_ ids: Set<ShoppingItemID>, in space: SpaceID) async throws -> RemovedShoppingItems {
        try await mutate(space) { $0.remove(ids) }
    }

    public func restore(_ removed: RemovedShoppingItems, in space: SpaceID) async throws {
        try await mutate(space) { $0.restore(removed) }
    }

    public func reviewImport(_ text: String, in space: SpaceID) async throws -> [ShoppingImportLine] {
        ShoppingTextImport.review(text, against: try await repository.list(in: space))
    }

    @discardableResult
    public func commitImport(_ lines: [ShoppingImportLine], in space: SpaceID) async throws -> [ShoppingItem] {
        try await mutate(space) { try $0.add(importing: lines, at: time.now()) }
    }

    /// What is still to buy. Checked-off items are already bought.
    public func exportSelection(in space: SpaceID) async throws -> [ShoppingExportItem] {
        try await repository.list(in: space).items
            .filter { !$0.isChecked }
            .map { ShoppingExportItem(name: $0.name, quantity: $0.quantity) }
    }

    private func mutate<Result>(
        _ space: SpaceID,
        _ change: (inout ShoppingList) throws -> Result
    ) async throws -> Result {
        var list = try await repository.list(in: space)
        let result = try change(&list)
        try await repository.save(list, in: space)
        return result
    }
}

public struct RemindersExport: Sendable {
    public init() {}

    public func prepare(
        _ selection: [ShoppingExportItem],
        destination: any RemindersDestination
    ) async throws -> ReminderExportPlan {
        ReminderExportPlanner.plan(selection, incompleteReminderTitles: try await destination.incompleteReminderTitles())
    }

    public func commit(
        _ plan: ReminderExportPlan,
        addAnyway: Set<UUID>,
        destination: any RemindersDestination
    ) async throws {
        let items = plan.itemsToWrite(addAnyway: addAnyway)
        guard !items.isEmpty else { return }
        try await destination.add(items)
    }
}
