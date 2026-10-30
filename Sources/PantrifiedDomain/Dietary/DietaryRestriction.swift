import Foundation

/// Allergens a person can declare. The first nine are the U.S. major food allergens; molluscs are
/// included because many people with a shellfish allergy avoid them too.
public enum Allergen: Sendable, Hashable, Codable, CaseIterable {
    case milk
    case egg
    case fish
    case crustaceanShellfish
    case mollusc
    case treeNut
    case peanut
    case wheat
    case soy
    case sesame
}

/// How strictly a custom exclusion is applied. There is no default: whoever records an exclusion
/// chooses, so the weaker reading is never applied by accident.
public enum ExclusionSeverity: Sendable, Hashable, Codable, CaseIterable {
    /// Strict, like an allergen: a food that could be or hide the excluded food needs review, and
    /// an excluded food the data does not know makes every recipe need review.
    case allergyOrIntolerance
    /// Only a food named as the excluded food, by name or synonym, or known to be made from it,
    /// counts. Nothing else about the recipe needs review because of it.
    case justAvoid
}

public enum Diet: Sendable, Hashable, Codable, CaseIterable {
    case vegetarian
    case vegan
    case glutenFree
    case dairyFree
}

/// A hard restriction: a recipe that breaks it must never be presented as suitable. Likes,
/// dislikes and spice tolerance are `DietaryPreferences` and never make a recipe unsafe.
public enum DietaryRestriction: Sendable, Hashable, Codable {
    case allergen(Allergen)
    case diet(Diet)
    /// A food the person never eats, matched by name, synonyms and what the classification data
    /// knows foods are made from. The severity says how far doubt counts against a recipe.
    case excluded(IngredientName, severity: ExclusionSeverity)

    /// The traits an ingredient must be known not to have. Empty for a custom exclusion, which is
    /// matched by name instead.
    public var forbiddenTraits: Set<DietaryTrait> {
        switch self {
        case .allergen(let allergen): [DietaryTrait(allergen)]
        case .diet(.vegetarian): Self.slaughter
        case .diet(.vegan): Self.slaughter.union([.milk, .egg, .otherAnimalProduct])
        case .diet(.glutenFree): [.gluten]
        case .diet(.dairyFree): [.milk]
        case .excluded: []
        }
    }

    private static let slaughter: Set<DietaryTrait> = [
        .meat, .fish, .crustaceanShellfish, .mollusc, .slaughterByproduct,
    ]
}

/// A property of a food that a restriction can forbid.
public enum DietaryTrait: Sendable, Hashable, Codable, CaseIterable {
    case milk
    case egg
    case fish
    case crustaceanShellfish
    case mollusc
    case treeNut
    case peanut
    case wheat
    case soy
    case sesame
    /// Wheat, barley, rye and their relatives. Wheat implies gluten; gluten does not imply wheat.
    case gluten
    /// Flesh of land animals, including poultry and animal fat such as lard.
    case meat
    /// Gelatin, animal rennet and similar products of slaughter.
    case slaughterByproduct
    /// Animal products that do not require slaughter, such as honey, and animal-derived
    /// processing aids such as bone char.
    case otherAnimalProduct

    public init(_ allergen: Allergen) {
        self = switch allergen {
        case .milk: .milk
        case .egg: .egg
        case .fish: .fish
        case .crustaceanShellfish: .crustaceanShellfish
        case .mollusc: .mollusc
        case .treeNut: .treeNut
        case .peanut: .peanut
        case .wheat: .wheat
        case .soy: .soy
        case .sesame: .sesame
        }
    }
}

public enum SpiceTolerance: Sendable, Hashable, Codable, Comparable {
    case none
    case mild
    case medium
    case hot
}

/// Soft preferences. They may shape suggestions and generation; they never make a recipe unsafe.
public struct DietaryPreferences: Sendable, Hashable, Codable {
    public var likes: Set<IngredientName>
    public var dislikes: Set<IngredientName>
    public var spiceTolerance: SpiceTolerance?

    public init(likes: Set<IngredientName> = [], dislikes: Set<IngredientName> = [], spiceTolerance: SpiceTolerance? = nil) {
        self.likes = likes
        self.dislikes = dislikes
        self.spiceTolerance = spiceTolerance
    }
}

public enum ConsumerProfileTag: Sendable {}
public typealias ConsumerProfileID = Identifier<ConsumerProfileTag>

/// What this device knows of a person's hard restrictions.
public enum ProfileRestrictions: Sendable, Hashable {
    /// The person's restrictions as recorded. An empty set means they have none.
    case known(Set<DietaryRestriction>)
    /// This device does not have the person's restrictions. Never read as none.
    case unknown
}

/// Someone who eats household meals, whether or not they use the app.
public struct ConsumerProfile: Sendable, Hashable, Identifiable {
    public let id: ConsumerProfileID
    public var name: String
    public var restrictions: ProfileRestrictions
    public var preferences: DietaryPreferences

    public init(
        id: ConsumerProfileID = ConsumerProfileID(),
        name: String,
        restrictions: ProfileRestrictions,
        preferences: DietaryPreferences = DietaryPreferences()
    ) {
        self.id = id
        self.name = name
        self.restrictions = restrictions
        self.preferences = preferences
    }
}
