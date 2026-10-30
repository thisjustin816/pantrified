import Foundation
import PantrifiedDomain

/// Source of "now", injected so use cases are deterministic under test.
public protocol TimeSource: Sendable {
    func now() -> Date
}

public protocol InventoryRepository: Sendable {
    func package(_ id: PackageID) async throws -> Package?
    /// Packages still in active inventory; used up and discarded packages are excluded.
    func activePackages(in space: SpaceID) async throws -> [Package]
    func save(_ package: Package) async throws
}

public protocol StorageLocationRepository: Sendable {
    func locations(in space: SpaceID) async throws -> [StorageLocation]
}

/// Matches a package to sourced storage guidance. Returns nil when nothing matches; a model may
/// assist the matching but never supplies the windows.
public protocol StorageGuidanceRepository: Sendable {
    func guidance(for package: Package) async throws -> StorageGuidance?
}
