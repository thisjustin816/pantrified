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

/// Locations a person can add to. Saving more than one stores every location or none of them, so a
/// failure part way never leaves a Space with some of its default locations.
public protocol StorageLocationStore: StorageLocationRepository {
    /// Adds locations, or changes the name or type of one already stored.
    func saveAll(_ locations: [StorageLocation], in space: SpaceID) async throws
}

/// Matches a package to sourced storage guidance. Returns nil when nothing matches; a model may
/// assist the matching but never supplies the windows.
public protocol StorageGuidanceRepository: Sendable {
    func guidance(for package: Package) async throws -> StorageGuidance?
    /// Which record the package's guidance comes from and which records the person could choose.
    /// Nil when the repository has no records to choose from.
    func recordQuestion(for package: Package) async throws -> GuidanceRecordQuestion?
}

extension StorageGuidanceRepository {
    public func recordQuestion(for package: Package) async throws -> GuidanceRecordQuestion? { nil }
}

/// Barcodes read from packages, kept on this device as product evidence, per Space. A barcode
/// names a product, so it is kept beside the package it was read from and never identifies one.
public protocol ProductEvidenceStore: Sendable {
    func barcode(of package: PackageID, in space: SpaceID) async throws -> GTIN?
    /// Stores every barcode or none of them. Recording the same barcode again stores nothing new.
    func record(_ barcodes: [PackageID: GTIN], in space: SpaceID) async throws
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
