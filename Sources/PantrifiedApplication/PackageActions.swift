import Foundation
import PantrifiedDomain

public enum PackageAction: Sendable, Hashable {
    case opened
    case usedUp
    case discard(reason: DiscardReason?)
    case move(to: LocationID)
}

public struct UndoToken: Sendable, Hashable {
    public let packageID: PackageID
    public let eventID: PackageEventID

    public init(packageID: PackageID, eventID: PackageEventID) {
        self.packageID = packageID
        self.eventID = eventID
    }
}

public enum ActionOutcome: Sendable, Hashable {
    case applied(UndoToken)
    /// The package already satisfied the action, so no history entry was written.
    case unchanged
}

public enum PackageActionError: Error, Sendable, Equatable {
    case packageNotFound
    case unknownLocation
}

/// Opened / Used up / Move / Discard, each undoable.
public struct PackageActions: Sendable {
    private let inventory: any InventoryRepository
    private let locations: any StorageLocationRepository
    private let time: any TimeSource

    public init(
        inventory: any InventoryRepository,
        locations: any StorageLocationRepository,
        time: any TimeSource
    ) {
        self.inventory = inventory
        self.locations = locations
        self.time = time
    }

    public func apply(_ action: PackageAction, to id: PackageID) async throws -> ActionOutcome {
        var package = try await load(id)
        guard package.status == .active else { throw PackageError.notActive }

        let change: PackageChange
        switch action {
        case .opened:
            guard package.openedAt == nil else { return .unchanged }
            change = .opened
        case .usedUp:
            change = .usedUp
        case .discard(let reason):
            change = .discarded(reason: reason)
        case .move(let destination):
            guard destination != package.location else { return .unchanged }
            let known = try await locations.locations(in: package.spaceID)
            guard known.contains(where: { $0.id == destination }) else {
                throw PackageActionError.unknownLocation
            }
            change = .moved(to: destination)
        }

        let eventID = try package.record(change, at: time.now())
        try await inventory.save(package)
        return .applied(UndoToken(packageID: id, eventID: eventID))
    }

    public func undo(_ token: UndoToken) async throws {
        var package = try await load(token.packageID)
        try package.undo(token.eventID, at: time.now())
        try await inventory.save(package)
    }

    private func load(_ id: PackageID) async throws -> Package {
        guard let package = try await inventory.package(id) else {
            throw PackageActionError.packageNotFound
        }
        return package
    }
}
