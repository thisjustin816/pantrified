import Foundation
import PantrifiedDomain

public enum IngredientOutcome: Sendable, Hashable {
    case usedSome
    case usedUp
    case noChange
}

public struct IngredientUse: Sendable, Hashable {
    public let packageID: PackageID
    public let outcome: IngredientOutcome

    public init(packageID: PackageID, outcome: IngredientOutcome) {
        self.packageID = packageID
        self.outcome = outcome
    }
}

public struct CookedReceipt: Sendable, Hashable {
    public var tokens: [UndoToken]
    /// Packages whose exact quantity could not be adjusted and should be corrected by the user.
    public var needsQuantityCheck: [PackageID]
    /// Packages that were missing or no longer active, such as one a housemate already used up.
    public var skipped: [PackageID]
}

/// Reconciles inventory after an explicit Mark Cooked. Nothing here is inferred from recipe
/// quantities: each package changes only as the person said.
public struct MarkCooked: Sendable {
    private let inventory: any InventoryRepository
    private let time: any TimeSource

    public init(inventory: any InventoryRepository, time: any TimeSource) {
        self.inventory = inventory
        self.time = time
    }

    public func reconcile(_ uses: [IngredientUse]) async throws -> CookedReceipt {
        let now = time.now()
        var receipt = CookedReceipt(tokens: [], needsQuantityCheck: [], skipped: [])
        var changed: [Package] = []

        for use in lastChoices(uses) {
            guard use.outcome != .noChange else { continue }
            guard var package = try await inventory.package(use.packageID), package.status == .active else {
                receipt.skipped.append(use.packageID)
                continue
            }

            let change: PackageChange
            switch use.outcome {
            case .usedUp:
                change = .usedUp
            case .usedSome:
                let result = package.quantity.afterUsingSome
                if result.needsCorrection { receipt.needsQuantityCheck.append(package.id) }
                change = .usedSome(resulting: result.quantity)
            case .noChange:
                continue
            }

            let eventID = try package.record(change, at: now)
            receipt.tokens.append(UndoToken(packageID: package.id, eventID: eventID))
            changed.append(package)
        }

        if !changed.isEmpty { try await inventory.saveAll(changed) }
        return receipt
    }

    public func undo(_ receipt: CookedReceipt) async throws {
        let now = time.now()
        var restored: [Package] = []
        for token in receipt.tokens {
            guard var package = try await inventory.package(token.packageID) else {
                throw PackageActionError.packageNotFound
            }
            try package.undo(token.eventID, at: now)
            restored.append(package)
        }
        if !restored.isEmpty { try await inventory.saveAll(restored) }
    }

    /// One entry per package, in first-seen order, carrying the last outcome chosen for it.
    private func lastChoices(_ uses: [IngredientUse]) -> [IngredientUse] {
        var latest: [PackageID: IngredientUse] = [:]
        var order: [PackageID] = []
        for use in uses {
            if latest[use.packageID] == nil { order.append(use.packageID) }
            latest[use.packageID] = use
        }
        return order.compactMap { latest[$0] }
    }
}
