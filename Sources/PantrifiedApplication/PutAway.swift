import Foundation
import PantrifiedDomain

public struct PutAwayResult: Sendable, Hashable {
    public var created: [PackageID]
    /// Drafts whose package already exists, left untouched so a retry cannot undo later changes.
    public var alreadyPresent: [PackageID]
}

public enum PutAwayError: Error, Sendable, Equatable {
    case notReady([PackageID])
    case unknownLocation(PackageID)
}

/// Turns reviewed drafts into authoritative packages, all or nothing.
public struct PutAway: Sendable {
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

    public func putAway(_ drafts: [PackageDraft]) async throws -> PutAwayResult {
        let unready = drafts.filter { $0.readiness != .ready }.map(\.id)
        guard unready.isEmpty else { throw PutAwayError.notReady(unready) }

        var locationsBySpace: [SpaceID: Set<LocationID>] = [:]
        var packages: [Package] = []
        var alreadyPresent: [PackageID] = []
        let now = time.now()

        for draft in drafts {
            if locationsBySpace[draft.spaceID] == nil {
                locationsBySpace[draft.spaceID] = Set(try await locations.locations(in: draft.spaceID).map(\.id))
            }
            guard let location = draft.location, let name = draft.trimmedName else { continue }
            guard locationsBySpace[draft.spaceID]?.contains(location) == true else {
                throw PutAwayError.unknownLocation(draft.id)
            }
            if try await inventory.package(draft.id) != nil {
                alreadyPresent.append(draft.id)
                continue
            }
            packages.append(Package(
                id: draft.id,
                spaceID: draft.spaceID,
                name: name,
                location: location,
                quantity: draft.quantity.value ?? .unknown,
                printedDate: draft.printedDate.value,
                confirmed: draft.confirmedFields,
                addedAt: now
            ))
        }

        if !packages.isEmpty { try await inventory.saveAll(packages) }
        return PutAwayResult(created: packages.map(\.id), alreadyPresent: alreadyPresent)
    }
}
