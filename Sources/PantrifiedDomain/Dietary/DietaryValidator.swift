import Foundation

public enum IngredientListCompleteness: Sendable, Hashable {
    /// The source states this is the recipe's full ingredient list.
    case complete
    case partial
    case unknown
}

/// A recipe as the validator sees it, whether sourced or generated.
public struct RecipeUnderReview: Sendable, Hashable {
    public var ingredientLines: [String]
    /// Scanned for foods the ingredient list leaves out.
    public var instructions: [String]
    public var completeness: IngredientListCompleteness
    /// A provider's own dietary labels. Kept for display; never evidence that a recipe is suitable.
    public var providerLabels: Set<String>

    public init(
        ingredientLines: [String],
        instructions: [String] = [],
        completeness: IngredientListCompleteness,
        providerLabels: Set<String> = []
    ) {
        self.ingredientLines = ingredientLines
        self.instructions = instructions
        self.completeness = completeness
        self.providerLabels = providerLabels
    }
}

public struct DietaryViolation: Sendable, Hashable {
    public let line: String
    public let ingredient: IngredientName
    public let restriction: DietaryRestriction
    /// Nil for a custom exclusion, which matches by name.
    public let trait: DietaryTrait?
}

public enum ReviewReason: Sendable, Hashable {
    case emptyIngredientList
    case incompleteIngredientList(IngredientListCompleteness)
    case unparsedLine(String)
    case unknownIngredient(line: String, ingredient: IngredientName)
    case mayContain(line: String, ingredient: IngredientName, trait: DietaryTrait, restriction: DietaryRestriction)
    case advisoryStatement(line: String, restriction: DietaryRestriction)
    case unrecognizedNote(line: String, note: String)
    case alternativesDisagree(line: String)
    case traitNotCovered(DietaryTrait, restriction: DietaryRestriction)
    /// The excluded food is unknown to the data, so other foods cannot be shown not to be it.
    case exclusionUnverifiable(line: String, ingredient: IngredientName, excluded: IngredientName)
    case compositeMayHideExclusion(line: String, ingredient: IngredientName, excluded: IngredientName)
    /// The instructions use a relevant food the ingredient list leaves out.
    case mentionedButNotListed(IngredientName)

    public enum Kind: Sendable, Hashable, CaseIterable {
        case emptyIngredientList, incompleteIngredientList, unparsedLine, unknownIngredient, mayContain
        case advisoryStatement, unrecognizedNote, alternativesDisagree, traitNotCovered
        case exclusionUnverifiable, compositeMayHideExclusion, mentionedButNotListed
    }

    public var kind: Kind {
        switch self {
        case .emptyIngredientList: .emptyIngredientList
        case .incompleteIngredientList: .incompleteIngredientList
        case .unparsedLine: .unparsedLine
        case .unknownIngredient: .unknownIngredient
        case .mayContain: .mayContain
        case .advisoryStatement: .advisoryStatement
        case .unrecognizedNote: .unrecognizedNote
        case .alternativesDisagree: .alternativesDisagree
        case .traitNotCovered: .traitNotCovered
        case .exclusionUnverifiable: .exclusionUnverifiable
        case .compositeMayHideExclusion: .compositeMayHideExclusion
        case .mentionedButNotListed: .mentionedButNotListed
        }
    }
}

public enum DietaryVerdict: Sendable, Hashable {
    /// No hard restriction applies, so there is nothing to label.
    case noRestrictions
    /// Every ingredient of a complete list is known not to break any active restriction.
    case safe
    case needsReview([ReviewReason])
    /// At least one ingredient is known to break a restriction. Remaining doubts are kept too.
    case violation([DietaryViolation], alsoNeedsReview: [ReviewReason])
}

public struct DietaryAssessment: Sendable, Hashable {
    public let verdict: DietaryVerdict
    /// The classification data version the verdict rests on.
    public let dataVersion: String
}

/// Deterministic hard-restriction checking. A recipe is safe only when its ingredient list is
/// complete and every ingredient is positively known not to break every active restriction;
/// anything unknown, ambiguous or unparsed needs review. No model takes part.
public struct DietaryValidator: Sendable {
    public let data: ClassificationDataset

    public init(data: ClassificationDataset = .bundled) {
        self.data = data
    }

    public func assess(_ recipe: RecipeUnderReview, against restrictions: Set<DietaryRestriction>) -> DietaryAssessment {
        DietaryAssessment(verdict: verdict(recipe, restrictions), dataVersion: data.provenance.version)
    }

    private func verdict(_ recipe: RecipeUnderReview, _ restrictions: Set<DietaryRestriction>) -> DietaryVerdict {
        guard !restrictions.isEmpty else { return .noRestrictions }
        let ordered = restrictions.sorted { "\($0)" < "\($1)" }
        let lines = recipe.ingredientLines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var finding = Finding()
        if lines.isEmpty { finding.reviews.append(.emptyIngredientList) }
        if recipe.completeness != .complete { finding.reviews.append(.incompleteIngredientList(recipe.completeness)) }
        for restriction in ordered {
            for trait in restriction.forbiddenTraits.subtracting(data.coveredTraits).sorted(by: { "\($0)" < "\($1)" }) {
                finding.reviews.append(.traitNotCovered(trait, restriction: restriction))
            }
        }

        var listed: [IngredientName] = []
        for line in lines {
            guard let parsed = IngredientLine.parse(line) else {
                finding.reviews.append(.unparsedLine(line))
                continue
            }
            for note in parsed.unrecognizedNotes { finding.reviews.append(.unrecognizedNote(line: line, note: note)) }
            for advisory in parsed.advisories {
                finding.reviews += advisoryReviews(advisory, line: line, restrictions: ordered)
            }
            for alternatives in parsed.components {
                listed += alternatives
                finding.merge(choice(alternatives, line: line, restrictions: ordered))
            }
        }
        finding.reviews += unlisted(in: recipe.instructions, listed: listed, restrictions: ordered)

        if !finding.violations.isEmpty { return .violation(finding.violations, alsoNeedsReview: finding.reviews) }
        if !finding.reviews.isEmpty { return .needsReview(finding.reviews) }
        return .safe
    }

    // MARK: Ingredients

    private struct Finding {
        var violations: [DietaryViolation] = []
        var reviews: [ReviewReason] = []

        var isClean: Bool { violations.isEmpty && reviews.isEmpty }

        mutating func merge(_ other: Finding) {
            violations += other.violations
            reviews += other.reviews
        }
    }

    /// A cook may pick any alternative, so the line is clean only if every alternative is, and a
    /// violation only if every alternative is one.
    private func choice(_ alternatives: [IngredientName], line: String, restrictions: [DietaryRestriction]) -> Finding {
        let findings = alternatives.map { assess($0, line: line, restrictions: restrictions) }
        if findings.count == 1 || findings.allSatisfy(\.isClean) { return findings.reduce(into: Finding()) { $0.merge($1) } }
        if findings.allSatisfy({ !$0.violations.isEmpty }) { return findings.reduce(into: Finding()) { $0.merge($1) } }
        var mixed = Finding(reviews: [.alternativesDisagree(line: line)])
        for finding in findings { mixed.reviews += finding.reviews }
        return mixed
    }

    private func assess(_ ingredient: IngredientName, line: String, restrictions: [DietaryRestriction]) -> Finding {
        var finding = Finding()
        let entry = data.entry(for: ingredient)
        if entry == nil { finding.reviews.append(.unknownIngredient(line: line, ingredient: ingredient)) }

        for restriction in restrictions {
            if case .excluded(let excluded) = restriction {
                finding.merge(exclusion(excluded, ingredient: ingredient, entry: entry, line: line, restriction: restriction))
                continue
            }
            guard let entry else { continue }
            let forbidden = restriction.forbiddenTraits.intersection(data.coveredTraits)
            for trait in entry.contains.intersection(forbidden).sorted(by: { "\($0)" < "\($1)" }) {
                finding.violations.append(DietaryViolation(line: line, ingredient: ingredient, restriction: restriction, trait: trait))
            }
            for trait in entry.mayContain.intersection(forbidden).subtracting(entry.contains).sorted(by: { "\($0)" < "\($1)" }) {
                finding.reviews.append(.mayContain(line: line, ingredient: ingredient, trait: trait, restriction: restriction))
            }
        }
        return finding
    }

    private func exclusion(
        _ excluded: IngredientName,
        ingredient: IngredientName,
        entry: ClassificationEntry?,
        line: String,
        restriction: DietaryRestriction
    ) -> Finding {
        let violation = Finding(violations: [
            DietaryViolation(line: line, ingredient: ingredient, restriction: restriction, trait: nil),
        ])
        if ingredient.contains(excluded) { return violation }
        guard let entry else { return Finding() }
        guard let excludedEntry = data.entry(for: excluded) else {
            return Finding(reviews: [.exclusionUnverifiable(line: line, ingredient: ingredient, excluded: excluded)])
        }
        if entry == excludedEntry || entry.madeFrom.contains(where: excludedEntry.names.contains) { return violation }
        if entry.isComposite {
            return Finding(reviews: [.compositeMayHideExclusion(line: line, ingredient: ingredient, excluded: excluded)])
        }
        return Finding()
    }

    // MARK: Advisories and instructions

    private static let advisoryAllergens: [String: Set<DietaryTrait>] = normalizedKeys([
        "milk": [.milk], "dairy": [.milk],
        "egg": [.egg],
        "fish": [.fish],
        "shellfish": [.crustaceanShellfish, .mollusc],
        "crustacean": [.crustaceanShellfish],
        "mollusc": [.mollusc], "mollusk": [.mollusc],
        "tree": [.treeNut],
        "nut": [.treeNut, .peanut],
        "peanut": [.peanut],
        // Gluten is named on labels for wheat as often as for barley or rye.
        "wheat": [.wheat, .gluten], "gluten": [.gluten, .wheat],
        "soy": [.soy], "soya": [.soy],
        "sesame": [.sesame],
    ])

    /// Words an advisory uses around the allergens it names. Nothing here may name a food.
    private static let advisoryFiller = Set([
        "may", "contain", "contains", "trace", "traces", "of", "and", "or", "other", "processed",
        "process", "processes", "in", "on", "a", "an", "the", "facility", "facilities", "that",
        "which", "also", "handle", "handles", "product", "products", "made", "manufactured",
        "shared", "equipment", "line", "lines", "with", "cross", "contact", "produced", "same",
        "plant", "packed", "packaged", "including", "small", "amount", "amounts",
    ].flatMap { IngredientName($0).words })

    private static func normalizedKeys(_ raw: [String: Set<DietaryTrait>]) -> [String: Set<DietaryTrait>] {
        Dictionary(raw.map { (IngredientName($0.key).text, $0.value) }, uniquingKeysWith: { $0.union($1) })
    }

    /// An advisory made only of allergen words and filler concerns the restrictions those
    /// allergens touch. Any other word could name a food the advisory hides, and an advisory that
    /// names no allergen says nothing about which, so either concerns every restriction.
    private func advisoryReviews(_ advisory: String, line: String, restrictions: [DietaryRestriction]) -> [ReviewReason] {
        let text = IngredientName(advisory)
        var named: Set<DietaryTrait> = []
        var narrowed = true
        for word in text.words where !Self.advisoryFiller.contains(word) {
            guard let traits = Self.advisoryAllergens[word] else {
                narrowed = false
                break
            }
            named.formUnion(traits)
        }
        narrowed = narrowed && !named.isEmpty
        return restrictions
            .filter { !narrowed || advisoryConcerns($0, naming: named, in: text) }
            .map { .advisoryStatement(line: line, restriction: $0) }
    }

    private func advisoryConcerns(_ restriction: DietaryRestriction, naming named: Set<DietaryTrait>, in text: IngredientName) -> Bool {
        guard case .excluded(let excluded) = restriction else {
            return !restriction.forbiddenTraits.isDisjoint(with: named)
        }
        guard let entry = data.entry(for: excluded) else { return true }
        return entry.names.contains(where: text.contains)
            || !entry.contains.union(entry.mayContain).isDisjoint(with: named)
    }

    /// Foods the instructions name that the list leaves out, when they could matter: a relevant
    /// trait, a prepared food, or a custom exclusion. Generic words such as "sauce" are skipped.
    private func unlisted(
        in instructions: [String],
        listed: [IngredientName],
        restrictions: [DietaryRestriction]
    ) -> [ReviewReason] {
        let listedEntries = listed.compactMap { data.entry(for: $0) }
        let forbidden = restrictions.reduce(into: Set<DietaryTrait>()) { $0.formUnion($1.forbiddenTraits) }
        let exclusions = restrictions.compactMap { if case .excluded(let name) = $0 { name } else { nil } }
        let candidates = data.entries.filter { !$0.isGenericTerm }.flatMap { entry in entry.names.map { ($0, entry) } }
            .sorted { $0.0.words.count > $1.0.words.count }

        var found: [IngredientName] = []
        for instruction in instructions {
            var words = IngredientName(instruction).words[...]
            while !words.isEmpty {
                if let (name, entry) = candidates.first(where: { words.starts(with: $0.0.words) }) {
                    words = words.dropFirst(name.words.count)
                    let relevant = !entry.contains.union(entry.mayContain).isDisjoint(with: forbidden) || entry.isComposite
                    if relevant, !listedEntries.contains(entry), !found.contains(entry.name) { found.append(entry.name) }
                    continue
                }
                for excluded in exclusions where words.starts(with: excluded.words)
                    && !listed.contains(where: { $0.contains(excluded) }) && !found.contains(excluded) {
                    found.append(excluded)
                }
                words = words.dropFirst()
            }
        }
        return found.map(ReviewReason.mentionedButNotListed)
    }
}

extension IngredientName {
    /// True when `other`'s words appear in order, together, within this name.
    func contains(_ other: IngredientName) -> Bool {
        guard !other.words.isEmpty, other.words.count <= words.count else { return false }
        return (0...(words.count - other.words.count)).contains { start in
            Array(words[start..<(start + other.words.count)]) == other.words
        }
    }
}
