import Foundation

/// What the classification data knows about one food.
public struct ClassificationEntry: Sendable, Hashable {
    public let name: IngredientName
    public let synonyms: [IngredientName]
    /// Traits the food has.
    public let contains: Set<DietaryTrait>
    /// Traits some versions of the food have, through recipe variation or cross-contact.
    public let mayContain: Set<DietaryTrait>
    /// True for prepared foods made of other foods, such as broth or pesto. A composite can hide a
    /// custom-excluded ingredient, so it never passes an allergy or intolerance exclusion.
    public let isComposite: Bool
    /// Foods this one is made from, so excluding pork also excludes bacon.
    public let madeFrom: [IngredientName]
    /// Generic words such as "sauce" that, in recipe instructions, usually name the dish's own
    /// component rather than an unlisted ingredient.
    public let isGenericTerm: Bool
    /// For a name that also names a class of foods, such as fish or dairy, the traits that make a
    /// food one of them. Excluding the name excludes every food with one of these traits.
    public let category: Set<DietaryTrait>

    public init(
        _ name: String,
        synonyms: [String] = [],
        contains: Set<DietaryTrait> = [],
        mayContain: Set<DietaryTrait> = [],
        composite: Bool = false,
        madeFrom: [String] = [],
        genericTerm: Bool = false,
        category: Set<DietaryTrait> = []
    ) {
        self.name = IngredientName(name)
        self.synonyms = synonyms.map(IngredientName.init)
        self.contains = contains
        self.mayContain = mayContain
        self.isComposite = composite
        self.madeFrom = madeFrom.map(IngredientName.init)
        self.isGenericTerm = genericTerm
        self.category = category
    }

    var names: [IngredientName] { [name] + synonyms }
}

public struct ClassificationProvenance: Sendable, Hashable {
    public let source: String
    public let version: String
    public let reviewed: String

    public init(source: String, version: String, reviewed: String) {
        self.source = source
        self.version = version
        self.reviewed = reviewed
    }
}

/// Curated, versioned knowledge of which foods have which traits.
///
/// Every entry is reviewed against every trait in `coveredTraits`: a trait in neither `contains`
/// nor `mayContain` is one the food is known not to have. A food without an entry is unknown, and
/// a trait outside `coveredTraits` is unknown for every food. Unknown is never a pass.
public struct ClassificationDataset: Sendable {
    public let provenance: ClassificationProvenance
    public let coveredTraits: Set<DietaryTrait>
    /// Always false: the data is a curated sample of foods, not a complete food database.
    public let isExhaustive = false
    public let entries: [ClassificationEntry]
    private let index: [IngredientName: ClassificationEntry]

    public init(provenance: ClassificationProvenance, coveredTraits: Set<DietaryTrait>, entries: [ClassificationEntry]) {
        self.provenance = provenance
        self.coveredTraits = coveredTraits
        self.entries = entries
        var index: [IngredientName: ClassificationEntry] = [:]
        for entry in entries {
            for name in entry.names {
                precondition(index[name] == nil, "\(name.text) is classified twice")
                index[name] = entry
            }
        }
        self.index = index
    }

    /// The entry for an exact normalized name or synonym. Nothing fuzzier: "peanut sauce" is not
    /// "peanut", and guessing could turn an unknown food into a pass.
    public func entry(for name: IngredientName) -> ClassificationEntry? {
        index[name]
    }

    /// The known foods an entry is made from, directly or through other foods, so pesto reaches
    /// milk through parmesan.
    func ingredients(of entry: ClassificationEntry) -> [ClassificationEntry] {
        var found: [ClassificationEntry] = []
        var pending = entry.madeFrom
        while let name = pending.popLast() {
            guard let next = self.entry(for: name), next != entry, !found.contains(next) else { continue }
            found.append(next)
            pending += next.madeFrom
        }
        return found
    }
}
