import Foundation
import PantrifiedDomain

/// Storage guidance from a bundled, sourced dataset. A package gets guidance when the person has
/// chosen which record it is, or, without a choice, when its name matches one record exactly. A name
/// several records share gets none, because the wrong record would give the wrong window.
public struct BundledStorageGuidance: StorageGuidanceRepository {
    private let matcher: GuidanceMatcher
    private let provenance: GuidanceProvenance
    private let source: String

    public init(dataset: GuidanceDataset, confirmedLinks: [IngredientName: Int] = [:]) {
        matcher = GuidanceMatcher(dataset: dataset, confirmedLinks: confirmedLinks)
        provenance = dataset.attentionProvenance
        source = dataset.provenance.source
    }

    public func guidance(for package: Package) async throws -> StorageGuidance? {
        guard case .matched(let record, _) = match(package), !record.windows.isEmpty else { return nil }
        return StorageGuidance(provenance: provenance, windows: record.windows)
    }

    public func recordQuestion(for package: Package) async throws -> GuidanceRecordQuestion? {
        let status: GuidanceRecordQuestion.Status = switch match(package) {
        case .matched(let record, _): package.guidanceChoice == nil ? .matched(record) : .chosen(record)
        case .declined: .declined
        case .chosenRecordMissing(let reference): .chosenRecordMissing(reference)
        case .ambiguous, .noMatch: .unanswered
        }
        return GuidanceRecordQuestion(status: status, candidates: matcher.candidates(for: package.name), source: source)
    }

    public func unopenedStorage(of name: String, choice: GuidanceChoice?) -> Set<StorageType> {
        matcher.unopenedStorage(of: name, choice: choice)
    }

    private func match(_ package: Package) -> GuidanceMatch {
        matcher.match(IngredientName(package.name), choice: package.guidanceChoice)
    }
}
