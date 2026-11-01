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
    /// The person said none of the records offered is this food.
    case declined
    /// The person chose a record this dataset does not hold, or holds under a different name, such
    /// as after a newer snapshot dropped or renumbered it. Nothing is matched in its place.
    case chosenRecordMissing(GuidanceRecordReference)
}

/// Matches a food to sourced guidance deterministically. Only an exact normalized record name, or a
/// record the person chose, counts as a match. A source's keywords are loose search terms, often
/// fragments of a longer description, so they never decide a match, and neither does a partial
/// overlap: the wrong record would give the wrong storage window. They only suggest candidates.
/// No model takes part.
public struct GuidanceMatcher: Sendable {
    /// How many records `candidates(for:)` suggests beyond those whose name is the food's own.
    public static let candidateLimit = 8
    /// How much of a food's name is read when suggesting candidates, in Unicode scalars and then in
    /// words. A name longer than any food's costs no more than this to search.
    static let longestQuery = 256
    static let mostQueryWords = 12
    /// Words that join others in a record's name, such as "Yams or sweet potatoes". Sharing one says
    /// nothing about whether two foods are alike.
    static let connectives: Set<String> = ["a", "an", "and", "for", "in", "of", "or", "the", "to", "with"]

    private let source: String
    private let records: [GuidanceRecord]
    private let byID: [Int: GuidanceRecord]
    private let byName: [IngredientName: [Int]]
    private let confirmedLinks: [IngredientName: Int]
    /// For each record, in `records` order, the words its name and its keywords are searched by.
    private let nameWords: [Set<String>]
    private let keywordWords: [Set<String>]
    /// Search word to the positions in `records` of the records whose name or keywords hold it.
    private let index: [String: [Int]]

    public init(dataset: GuidanceDataset, confirmedLinks: [IngredientName: Int] = [:]) {
        source = dataset.provenance.source
        records = dataset.records
        byID = Dictionary(uniqueKeysWithValues: dataset.records.map { ($0.id, $0) })
        var names: [IngredientName: [Int]] = [:]
        for record in dataset.records {
            names[IngredientName(record.name), default: []].append(record.id)
        }
        byName = names
        self.confirmedLinks = confirmedLinks

        nameWords = dataset.records.map { Set(Self.searchWords($0.name)) }
        keywordWords = dataset.records.map { Set($0.keywords.flatMap(Self.searchWords)) }
        var index: [String: [Int]] = [:]
        for position in dataset.records.indices {
            for word in nameWords[position].union(keywordWords[position]) {
                index[word, default: []].append(position)
            }
        }
        self.index = index
    }

    /// Matches a food by its name, unless the person has chosen a record for it. A choice always
    /// decides: a chosen record that this dataset no longer holds gives no match, instead of falling
    /// back to the name, which could give the very record the person turned down.
    public func match(_ food: IngredientName, choice: GuidanceChoice? = nil) -> GuidanceMatch {
        switch choice {
        case .record(let reference):
            guard let record = byID[reference.id], reference.names(record, source: source) else {
                return .chosenRecordMissing(reference)
            }
            return .matched(record, via: .confirmed)
        case .noneOfThese:
            return .declined
        case nil:
            break
        }
        guard !food.isEmpty else { return .noMatch(candidates: []) }

        if let id = confirmedLinks[food], let record = byID[id] {
            return .matched(record, via: .confirmed)
        }

        let hits = (byName[food] ?? []).sorted()
        switch hits.count {
        case 0:
            return .noMatch(candidates: candidates(for: food.text))
        case 1:
            guard let record = byID[hits[0]] else { return .noMatch(candidates: []) }
            return .matched(record, via: .name)
        default:
            return .ambiguous(hits.compactMap { byID[$0] })
        }
    }

    /// The records a person could choose for a food called `name`, most likely first:
    ///
    /// 1. every record whose normalized name is the food's own, by identifier, since any of them
    ///    could be the right one;
    /// 2. then records whose name shares words with the food's, most shared words first, then fewest
    ///    words the two do not share, then by identifier;
    /// 3. then records that share words only through their keywords, most shared first, then by
    ///    identifier.
    ///
    /// The second and third groups together fill the list up to `candidateLimit`. Case, accents,
    /// letter width and invisible characters are ignored for the suggestions, and only the start of
    /// a very long name is read. Every record returned comes from the dataset.
    public func candidates(for name: String) -> [GuidanceRecord] {
        let capped = String(String.UnicodeScalarView(name.unicodeScalars.prefix(Self.longestQuery)))
        let food = IngredientName(capped)
        let query = Set(Self.searchWords(capped).prefix(Self.mostQueryWords))

        let exact = (food.isEmpty ? [] : byName[food] ?? []).sorted()
        let exactIDs = Set(exact)

        var positions: Set<Int> = []
        for word in query { positions.formUnion(index[word] ?? []) }

        var close: [(shared: Int, unshared: Int, id: Int, position: Int)] = []
        var byKeyword: [(shared: Int, id: Int, position: Int)] = []
        for position in positions where !exactIDs.contains(records[position].id) {
            let id = records[position].id
            let shared = nameWords[position].intersection(query).count
            if shared > 0 {
                close.append((shared, nameWords[position].symmetricDifference(query).count, id, position))
            } else {
                byKeyword.append((keywordWords[position].intersection(query).count, id, position))
            }
        }
        close.sort { a, b in
            if a.shared != b.shared { return a.shared > b.shared }
            if a.unshared != b.unshared { return a.unshared < b.unshared }
            return a.id < b.id
        }
        byKeyword.sort { a, b in a.shared != b.shared ? a.shared > b.shared : a.id < b.id }

        let suggestions = (close.map(\.position) + byKeyword.map(\.position))
            .prefix(Self.candidateLimit)
            .map { records[$0] }
        return exact.compactMap { byID[$0] } + suggestions
    }

    /// The words a text is searched by, in the order they first appear: its normalized words with
    /// accents and letter width folded, leaving out connectives.
    private static func searchWords(_ text: String) -> [String] {
        let folded = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        var seen: Set<String> = []
        return IngredientName(folded).words.filter { !connectives.contains($0) && seen.insert($0).inserted }
    }
}

extension GuidanceMatcher: UnopenedStorageGuide {
    public func unopenedStorage(of name: String, choice: GuidanceChoice?) -> Set<StorageType> {
        guard case .matched(let record, _) = match(IngredientName(name), choice: choice) else { return [] }
        return Set(record.windows.filter { $0.anchor == .added }.map(\.storageType))
    }
}
