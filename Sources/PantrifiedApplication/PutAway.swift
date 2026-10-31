import Foundation
import PantrifiedDomain

public struct PutAwayResult: Sendable, Hashable {
    public var created: [PackageID]
    /// Drafts whose package already exists, left untouched so a retry cannot undo later changes.
    public var alreadyPresent: [PackageID]
    /// Packages that were put away but whose barcode could not be kept. The package is saved
    /// either way: a barcode is evidence, and losing it never undoes a put-away.
    public var barcodesNotKept: [PackageID] = []
}

public enum PutAwayError: Error, Sendable, Equatable {
    case notReady([PackageID])
    case unknownLocation(PackageID)
}

/// Turns reviewed drafts into authoritative packages, all or nothing. A draft's barcode is kept
/// beside its package as product evidence after the packages are saved.
public struct PutAway: Sendable {
    private let inventory: any InventoryRepository
    private let locations: any StorageLocationRepository
    private let evidence: any ProductEvidenceStore
    private let time: any TimeSource

    public init(
        inventory: any InventoryRepository,
        locations: any StorageLocationRepository,
        evidence: any ProductEvidenceStore,
        time: any TimeSource
    ) {
        self.inventory = inventory
        self.locations = locations
        self.evidence = evidence
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
        var result = PutAwayResult(created: packages.map(\.id), alreadyPresent: alreadyPresent)
        result.barcodesNotKept = await keepBarcodes(of: drafts)
        return result
    }

    /// Records each draft's barcode, including drafts whose package was already present, so a
    /// retry after a failed barcode write still keeps it. Returns the packages whose barcode failed.
    private func keepBarcodes(of drafts: [PackageDraft]) async -> [PackageID] {
        var bySpace: [SpaceID: [PackageID: GTIN]] = [:]
        for draft in drafts {
            if let barcode = draft.barcode { bySpace[draft.spaceID, default: [:]][draft.id] = barcode }
        }
        var failed: [PackageID] = []
        for (space, barcodes) in bySpace {
            do {
                try await evidence.record(barcodes, in: space)
            } catch {
                failed += barcodes.keys
            }
        }
        return failed
    }
}
