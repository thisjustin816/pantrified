import Foundation

public enum IngredientListCompleteness: Sendable, Hashable {
    /// The source states this is the recipe's full ingredient list.
    case complete
    case partial
    case unknown
}

/// Who wrote a recipe's title and instructions, which decides how far the validator trusts them
/// to name only the listed foods.
public enum RecipeOrigin: Sendable, Hashable {
    /// A provider's recipe. Its title and instructions are scanned for known foods the list
    /// leaves out.
    case sourced
    /// A model's recipe. Every word of its title and instructions must also be a listed food, a
    /// known food, or known cooking vocabulary, because a model can use a food without listing it.
    case generated
}

/// A recipe as the validator sees it, whether sourced or generated.
public struct RecipeUnderReview: Sendable, Hashable {
    /// Scanned like the instructions, since a title can name a food the list leaves out.
    public var title: String
    public var ingredientLines: [String]
    /// Scanned for foods the ingredient list leaves out.
    public var instructions: [String]
    public var completeness: IngredientListCompleteness
    public var origin: RecipeOrigin
    /// A provider's own dietary labels. Kept for display; never evidence that a recipe is suitable.
    public var providerLabels: Set<String>

    public init(
        title: String,
        ingredientLines: [String],
        instructions: [String] = [],
        completeness: IngredientListCompleteness,
        origin: RecipeOrigin,
        providerLabels: Set<String> = []
    ) {
        self.title = title
        self.ingredientLines = ingredientLines
        self.instructions = instructions
        self.completeness = completeness
        self.origin = origin
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
    /// The title or instructions use a relevant food the ingredient list leaves out.
    case mentionedButNotListed(IngredientName)
    /// A generated title or instructions use a word that is not a listed food, a known food or
    /// known cooking vocabulary, so it may name a food the list leaves out.
    case unrecognizedWord(String)

    public enum Kind: Sendable, Hashable, CaseIterable {
        case emptyIngredientList, incompleteIngredientList, unparsedLine, unknownIngredient, mayContain
        case advisoryStatement, unrecognizedNote, alternativesDisagree, traitNotCovered
        case exclusionUnverifiable, compositeMayHideExclusion, mentionedButNotListed, unrecognizedWord
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
        case .unrecognizedWord: .unrecognizedWord
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
        finding.reviews += unlisted(
            in: [recipe.title] + recipe.instructions, listed: listed, origin: recipe.origin, restrictions: ordered
        )

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

    /// Foods the title and instructions use that the list leaves out, when they would change the
    /// verdict had they been listed. A generic word such as "sauce" counts only when no listed line
    /// accounts for it. Generated text must also use only listed foods, known foods and cooking
    /// vocabulary.
    private func unlisted(
        in texts: [String],
        listed: [IngredientName],
        origin: RecipeOrigin,
        restrictions: [DietaryRestriction]
    ) -> [ReviewReason] {
        let listedEntries = listed.compactMap { data.entry(for: $0) }
        let listedWords = Set(listed.flatMap(\.words) + listedEntries.flatMap { $0.names.flatMap(\.words) })
        let exclusions = restrictions.compactMap { if case .excluded(let name) = $0 { name } else { nil } }
        let candidates = data.entries.flatMap { entry in entry.names.map { ($0, entry) } }
            .sorted { $0.0.words.count > $1.0.words.count }

        var found: [IngredientName] = []
        var unrecognized: [String] = []
        for text in texts {
            let written = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            let words = written.map { IngredientName($0).words.first ?? $0 }
            var index = 0
            while index < words.count {
                let rest = words[index...]
                if let (name, entry) = candidates.first(where: { rest.starts(with: $0.0.words) }) {
                    index += name.words.count
                    let accounted = listedEntries.contains(entry)
                        || (entry.isGenericTerm && name.words.allSatisfy(listedWords.contains))
                    if !accounted, !assess(name, line: text, restrictions: restrictions).isClean, !found.contains(name) {
                        found.append(name)
                    }
                    continue
                }
                if let excluded = exclusions.first(where: { rest.starts(with: $0.words) }) {
                    index += excluded.words.count
                    if !listed.contains(where: { $0.contains(excluded) }), !found.contains(excluded) { found.append(excluded) }
                    continue
                }
                if origin == .generated, !CookingVocabulary.contains(written[index]), !listedWords.contains(words[index]),
                   !unrecognized.contains(written[index]) {
                    unrecognized.append(written[index])
                }
                index += 1
            }
        }
        return found.map(ReviewReason.mentionedButNotListed) + unrecognized.map(ReviewReason.unrecognizedWord)
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
