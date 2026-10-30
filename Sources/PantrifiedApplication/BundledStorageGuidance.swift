import Foundation
import PantrifiedDomain

/// Storage guidance from a bundled, sourced dataset. A package gets guidance only when its name
/// matches one record exactly or the person has confirmed which record it is; a name several
/// records share gets none, because the wrong record would give the wrong window.
public struct BundledStorageGuidance: StorageGuidanceRepository {
    private let matcher: GuidanceMatcher
    private let provenance: GuidanceProvenance

    public init(dataset: GuidanceDataset, confirmedLinks: [IngredientName: Int] = [:]) {
        matcher = GuidanceMatcher(dataset: dataset, confirmedLinks: confirmedLinks)
        provenance = dataset.attentionProvenance
    }

    public func guidance(for package: Package) async throws -> StorageGuidance? {
        guard case .matched(let record, _) = matcher.match(IngredientName(package.name)),
              !record.windows.isEmpty else { return nil }
        return StorageGuidance(provenance: provenance, windows: record.windows)
    }
}
