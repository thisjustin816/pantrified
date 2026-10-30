import Foundation

/// One selected inventory food, reduced to what generation needs.
public struct MealContextIngredient: Sendable, Hashable, Codable {
    public let name: String
    /// The food is past guidance or should be used soon.
    public let useSoon: Bool
    public let quantity: Quantity

    public init(name: String, useSoon: Bool, quantity: Quantity) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.useSoon = useSoon
        self.quantity = quantity
    }
}

/// The selected diners' soft preferences, combined.
public struct CombinedPreferences: Sendable, Hashable, Codable {
    /// Foods any selected diner dislikes.
    public let avoid: Set<IngredientName>
    /// Foods some selected diner likes and none dislikes.
    public let favor: Set<IngredientName>
    /// The lowest tolerance any selected diner stated.
    public let spiceTolerance: SpiceTolerance?
}

/// The minimum structured meal context a generative request receives.
///
/// It holds selected foods, how many people are eating, and the selected diners' restrictions and
/// preferences combined so nothing says which person has which need. It has no field for
/// identifiers, people's names, dates, locations, photos, evidence crops or history, so a request
/// built from it cannot carry them.
public struct MakeSomethingContext: Sendable, Hashable, Codable {
    public let ingredients: [MealContextIngredient]
    public let dinerCount: Int
    /// Every hard restriction of any selected diner. Validation of the output uses exactly these.
    public let restrictions: Set<DietaryRestriction>
    public let preferences: CombinedPreferences

    public init(ingredients: [MealContextIngredient], diners: [ConsumerProfile]) {
        self.ingredients = ingredients
        self.dinerCount = diners.count
        self.restrictions = diners.reduce(into: []) { $0.formUnion($1.restrictions) }
        let dislikes = diners.reduce(into: Set<IngredientName>()) { $0.formUnion($1.preferences.dislikes) }
        let likes = diners.reduce(into: Set<IngredientName>()) { $0.formUnion($1.preferences.likes) }
        self.preferences = CombinedPreferences(
            avoid: dislikes,
            favor: likes.subtracting(dislikes),
            spiceTolerance: diners.compactMap(\.preferences.spiceTolerance).min()
        )
    }
}

/// A recipe the person asked Pantrified to adapt, as text only.
public struct RecipeToAdapt: Sendable, Hashable, Codable {
    public let title: String
    public let ingredientLines: [String]

    public init(title: String, ingredientLines: [String]) {
        self.title = title
        self.ingredientLines = ingredientLines
    }
}

public enum MakeSomethingRequest: Sendable, Hashable, Codable {
    case newRecipe(MakeSomethingContext)
    /// Substitutions or changes that use selected inventory, clearly a Pantrified adaptation.
    case adaptation(RecipeToAdapt, MakeSomethingContext)

    public var context: MakeSomethingContext {
        switch self {
        case .newRecipe(let context), .adaptation(_, let context): context
        }
    }
}
