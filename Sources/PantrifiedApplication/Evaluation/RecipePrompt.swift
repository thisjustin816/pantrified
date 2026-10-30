import Foundation
import PantrifiedDomain

/// The text a model receives for a Make Something request. It is built only from the request's
/// context, so it carries no names, identifiers or dates.
public struct RecipePrompt: Sendable, Hashable {
    public let instructions: String
    public let text: String

    public static func render(_ request: MakeSomethingRequest) -> RecipePrompt {
        let context = request.context
        var lines: [String] = []

        if case .adaptation(let recipe, _) = request {
            lines.append("Adapt this recipe so it uses the ingredients on hand and follows the restrictions.")
            lines.append("Recipe: \(recipe.title)")
            lines.append(contentsOf: recipe.ingredientLines.map { "- \($0)" })
            lines.append("")
        }

        lines.append("Ingredients on hand:")
        lines.append(contentsOf: context.ingredients.map(describe))
        lines.append("")
        lines.append("People eating: \(context.dinerCount)")

        let restrictions = context.restrictions.map(describe).sorted()
        lines.append("Restrictions: \(restrictions.isEmpty ? "none" : restrictions.joined(separator: "; "))")

        let preferences = context.preferences
        if !preferences.avoid.isEmpty {
            lines.append("Avoid: \(preferences.avoid.map(\.text).sorted().joined(separator: ", "))")
        }
        if !preferences.favor.isEmpty {
            lines.append("Prefer: \(preferences.favor.map(\.text).sorted().joined(separator: ", "))")
        }
        if let spice = preferences.spiceTolerance {
            lines.append("Spice: \(describe(spice))")
        }
        return RecipePrompt(instructions: Self.instructions, text: lines.joined(separator: "\n"))
    }

    private static let instructions = """
        You write simple home recipes for a household. Use the ingredients on hand and keep any others to \
        common staples. Give every ingredient its own line with an amount. Name in the steps only foods \
        that appear on the ingredient list. Never include a food that breaks a restriction, even when it \
        is listed as on hand.
        """

    private static func describe(_ ingredient: MealContextIngredient) -> String {
        var line = "- \(ingredient.name)"
        if let amount = describe(ingredient.quantity) { line += " (\(amount))" }
        if ingredient.useSoon { line += " (use soon)" }
        return line
    }

    private static func describe(_ quantity: Quantity) -> String? {
        switch quantity {
        case .unknown: nil
        case .full: "full"
        case .aboutHalf: "about half"
        case .low: "low"
        case .exact(let value, let unit):
            "\(value == value.rounded() && abs(value) < 1e9 ? String(Int(value)) : String(value)) \(unit)"
        }
    }

    private static func describe(_ restriction: DietaryRestriction) -> String {
        switch restriction {
        case .allergen(let allergen): "\(name(allergen)) allergy"
        case .diet(let diet): name(diet)
        case .excluded(let food, let severity):
            switch severity {
            case .allergyOrIntolerance: "no \(food.text) (allergy or intolerance)"
            case .justAvoid: "avoid \(food.text)"
            }
        }
    }

    private static func name(_ allergen: Allergen) -> String {
        switch allergen {
        case .milk: "milk"
        case .egg: "egg"
        case .fish: "fish"
        case .crustaceanShellfish: "crustacean shellfish"
        case .mollusc: "mollusc"
        case .treeNut: "tree nut"
        case .peanut: "peanut"
        case .wheat: "wheat"
        case .soy: "soy"
        case .sesame: "sesame"
        }
    }

    private static func name(_ diet: Diet) -> String {
        switch diet {
        case .vegetarian: "vegetarian"
        case .vegan: "vegan"
        case .glutenFree: "gluten-free"
        case .dairyFree: "dairy-free"
        }
    }

    private static func describe(_ spice: SpiceTolerance) -> String {
        switch spice {
        case .none: "none"
        case .mild: "mild"
        case .medium: "medium"
        case .hot: "hot"
        }
    }
}
