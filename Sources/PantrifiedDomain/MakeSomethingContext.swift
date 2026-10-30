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

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            useSoon: try container.decode(Bool.self, forKey: .useSoon),
            quantity: try container.decode(Quantity.self, forKey: .quantity)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case name, useSoon, quantity
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
///
/// Validation reads an empty `restrictions` as "nobody here has one", so a context exists only for
/// at least one diner, each with restrictions this device knows.
public struct MakeSomethingContext: Sendable, Hashable, Codable {
    public let ingredients: [MealContextIngredient]
    public let dinerCount: Int
    /// Every hard restriction of any selected diner. Validation of the output uses exactly these.
    public let restrictions: Set<DietaryRestriction>
    public let preferences: CombinedPreferences

    public init(ingredients: [MealContextIngredient], diners: [ConsumerProfile]) throws(MakeSomethingContextError) {
        guard !diners.isEmpty else { throw .noDiners }
        var restrictions: Set<DietaryRestriction> = []
        for diner in diners {
            guard case .known(let known) = diner.restrictions else { throw .restrictionsUnknown }
            restrictions.formUnion(known)
        }
        self.ingredients = ingredients
        self.dinerCount = diners.count
        self.restrictions = restrictions
        let dislikes = diners.reduce(into: Set<IngredientName>()) { $0.formUnion($1.preferences.dislikes) }
        let likes = diners.reduce(into: Set<IngredientName>()) { $0.formUnion($1.preferences.likes) }
        self.preferences = CombinedPreferences(
            avoid: dislikes,
            favor: likes.subtracting(dislikes),
            spiceTolerance: diners.compactMap(\.preferences.spiceTolerance).min()
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dinerCount = try container.decode(Int.self, forKey: .dinerCount)
        guard dinerCount > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .dinerCount, in: container, debugDescription: "A request needs at least one diner"
            )
        }
        ingredients = try container.decode([MealContextIngredient].self, forKey: .ingredients)
        restrictions = try container.decode(Set<DietaryRestriction>.self, forKey: .restrictions)
        preferences = try container.decode(CombinedPreferences.self, forKey: .preferences)
    }
}

public enum MakeSomethingContextError: Error, Sendable, Hashable {
    /// Nobody was selected, so there is no one whose restrictions could be checked.
    case noDiners
    /// A selected diner's restrictions are not on this device.
    case restrictionsUnknown
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
