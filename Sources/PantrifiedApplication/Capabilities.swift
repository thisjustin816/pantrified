import Foundation
import PantrifiedDomain

/// Source of "now", injected so use cases are deterministic under test.
public protocol TimeSource: Sendable {
    func now() -> Date
}

/// Stores packages as append-only histories. Use cases read a package, change it and save it in
/// separate steps, with other awaits in between, so a save must never lose a change stored after
/// the copy was read:
///
/// - The first save of a package ID stores its creation facts; a later save never changes them.
/// - A save adds the events the store does not hold yet and never removes, reorders or replaces
///   one it holds.
///
/// A check made on a stale copy, such as whether the package is still active, can let through an
/// event that a fresh read would have refused. The fold resolves it as it resolves the same events
/// made on two devices.
public protocol InventoryRepository: Sendable {
    func package(_ id: PackageID) async throws -> Package?
    /// Packages still in active inventory; used up and discarded packages are excluded.
    func activePackages(in space: SpaceID) async throws -> [Package]
    func save(_ package: Package) async throws
    /// Stores every package or none of them.
    func saveAll(_ packages: [Package]) async throws
}

public protocol StorageLocationRepository: Sendable {
    func locations(in space: SpaceID) async throws -> [StorageLocation]
}

/// Matches a package to sourced storage guidance. Returns nil when nothing matches; a model may
/// assist the matching but never supplies the windows.
public protocol StorageGuidanceRepository: Sendable {
    func guidance(for package: Package) async throws -> StorageGuidance?
}

/// User-confirmed equivalences between recipe ingredients and inventory names, per Space.
public protocol IngredientLinkRepository: Sendable {
    func links(in space: SpaceID) async throws -> Set<IngredientLink>
    func confirm(_ link: IngredientLink, in space: SpaceID) async throws
}

public protocol ShoppingListRepository: Sendable {
    func list(in space: SpaceID) async throws -> ShoppingList
    /// Reads, changes and stores the list as one step, so concurrent changes cannot overwrite each
    /// other. Nothing is stored when `change` throws or the store fails.
    func update<Result: Sendable>(
        in space: SpaceID,
        _ change: @Sendable (inout ShoppingList) throws -> Result
    ) async throws -> Result
}

public enum ShoppingExportError: Error, Sendable, Equatable {
    /// The remembered reminders list no longer exists or is not writable. The person is asked to
    /// reconnect; another list is never chosen silently.
    case destinationMissing
}

/// The writable Reminders list remembered for a Space and app user.
public protocol RemindersDestination: Sendable {
    func incompleteReminderTitles() async throws -> [String]
    func add(_ items: [ShoppingExportItem]) async throws
}
