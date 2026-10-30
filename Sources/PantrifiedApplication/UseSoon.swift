import Foundation
import PantrifiedDomain

public struct AttentionItem: Sendable {
    public let package: Package
    public let assessment: AttentionAssessment

    public var needsAttention: Bool {
        assessment.state == .useSoon || assessment.state == .pastGuidance
    }
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
        try await assessments(in: space)
            .filter { $0.needsAttention }
            .sorted { a, b in
                if let ad = a.assessment.attentionDate, let bd = b.assessment.attentionDate, ad != bd {
                    return ad < bd
                }
                return a.package.name < b.package.name
            }
    }

    /// Every active package with its assessment, including those with no attention needed.
    public func assessments(in space: SpaceID) async throws -> [AttentionItem] {
        try await assess(try await inventory.activePackages(in: space), in: space)
    }

    /// The named packages that are active in the Space, with their assessments. No other package
    /// is read.
    public func assessments(of ids: Set<PackageID>, in space: SpaceID) async throws -> [AttentionItem] {
        var packages: [Package] = []
        for id in ids {
            if let package = try await inventory.package(id), package.spaceID == space, package.status == .active {
                packages.append(package)
            }
        }
        return try await assess(packages, in: space)
    }

    private func assess(_ packages: [Package], in space: SpaceID) async throws -> [AttentionItem] {
        let now = time.now()
        let storageTypes = Dictionary(
            uniqueKeysWithValues: try await locations.locations(in: space).map { ($0.id, $0.storageType) }
        )

        var items: [AttentionItem] = []
        for package in packages {
            let assessment = policy.assess(
                package,
                storageType: storageTypes[package.location],
                guidance: try await guidance.guidance(for: package),
                now: now
            )
            items.append(AttentionItem(package: package, assessment: assessment))
        }
        return items
    }
}
