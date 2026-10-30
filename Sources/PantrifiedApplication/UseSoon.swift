import Foundation
import PantrifiedDomain

public struct AttentionItem: Sendable {
    public let package: Package
    public let assessment: AttentionAssessment
}

/// Active packages that are past guidance or should be used soon, most urgent first.
public struct UseSoon: Sendable {
    private let inventory: any InventoryRepository
    private let locations: any StorageLocationRepository
    private let guidance: any StorageGuidanceRepository
    private let time: any TimeSource
    private let policy: AttentionPolicy

    public init(
        inventory: any InventoryRepository,
        locations: any StorageLocationRepository,
        guidance: any StorageGuidanceRepository,
        time: any TimeSource,
        policy: AttentionPolicy = AttentionPolicy()
    ) {
        self.inventory = inventory
        self.locations = locations
        self.guidance = guidance
        self.time = time
        self.policy = policy
    }

    public func items(in space: SpaceID) async throws -> [AttentionItem] {
        let now = time.now()
        let storageTypes = Dictionary(
            uniqueKeysWithValues: try await locations.locations(in: space).map { ($0.id, $0.storageType) }
        )

        var items: [AttentionItem] = []
        for package in try await inventory.activePackages(in: space) {
            let assessment = policy.assess(
                package,
                storageType: storageTypes[package.location],
                guidance: try await guidance.guidance(for: package),
                now: now
            )
            guard assessment.state == .useSoon || assessment.state == .pastGuidance else { continue }
            items.append(AttentionItem(package: package, assessment: assessment))
        }

        return items.sorted { a, b in
            if let ad = a.assessment.attentionDate, let bd = b.assessment.attentionDate, ad != bd {
                return ad < bd
            }
            return a.package.name < b.package.name
        }
    }
}
