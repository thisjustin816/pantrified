import Foundation

public enum GuidanceMatchKind: Sendable, Hashable {
    case name
    /// The person confirmed that this food is that record.
    case confirmed
}

public enum GuidanceMatch: Sendable, Hashable {
    case matched(GuidanceRecord, via: GuidanceMatchKind)
    /// More than one record has this name. Nothing is picked; the person can confirm one.
    case ambiguous([GuidanceRecord])
    /// No record has this name. `candidates` share words with the food and are only suggestions.
    case noMatch(candidates: [GuidanceRecord])
}

/// Matches a food to sourced guidance deterministically. Only an exact normalized record name, or a
/// link the person confirmed, counts as a match. A source's keywords are loose search terms, often
/// fragments of a longer description, so they never decide a match, and neither does a partial
/// overlap: the wrong record would give the wrong storage window. They only suggest candidates.
/// No model takes part.
public struct GuidanceMatcher: Sendable {
    private let records: [GuidanceRecord]
    private let byID: [Int: GuidanceRecord]
    private let byName: [IngredientName: [Int]]
    private let confirmedLinks: [IngredientName: Int]
    private static let candidateLimit = 10

    public init(dataset: GuidanceDataset, confirmedLinks: [IngredientName: Int] = [:]) {
        records = dataset.records
        byID = Dictionary(uniqueKeysWithValues: dataset.records.map { ($0.id, $0) })
        var names: [IngredientName: [Int]] = [:]
        for record in dataset.records {
            names[IngredientName(record.name), default: []].append(record.id)
        }
        byName = names
        self.confirmedLinks = confirmedLinks
    }

    public func match(_ food: IngredientName) -> GuidanceMatch {
        guard !food.isEmpty else { return .noMatch(candidates: []) }

        if let id = confirmedLinks[food], let record = byID[id] {
            return .matched(record, via: .confirmed)
        }

        let hits = (byName[food] ?? []).sorted()
        switch hits.count {
        case 0:
            return .noMatch(candidates: candidates(for: food))
        case 1:
            guard let record = byID[hits[0]] else { return .noMatch(candidates: []) }
            return .matched(record, via: .name)
        default:
            return .ambiguous(hits.compactMap { byID[$0] })
        }
    }

    /// Records whose name shares words with the food come before those that only list such words as
    /// keywords; each group is ordered by identifier so the suggestions are stable.
    private func candidates(for food: IngredientName) -> [GuidanceRecord] {
        let query = Set(food.words)
        func overlaps(_ text: String) -> Bool {
            let words = Set(IngredientName(text).words)
            return !words.isEmpty && (query.isSubset(of: words) || words.isSubset(of: query))
        }
        let byNameOverlap = records.filter { overlaps($0.name) }
        let byKeywordOnly = records.filter { record in
            !overlaps(record.name) && record.keywords.contains(where: overlaps)
        }
        return (byNameOverlap.sorted { $0.id < $1.id } + byKeywordOnly.sorted { $0.id < $1.id })
            .prefix(Self.candidateLimit)
            .map { $0 }
    }
}
