import Foundation
import PantrifiedDomain

/// Synthetic Make Something requests for measuring a model against the validator. They hold no
/// household data. Several list a food that breaks the diner's restriction, to see whether the
/// model leaves it out.
public enum EvaluationCorpus {
    public static let expectedCount = 12

    public static var cases: [EvaluationCase] {
        definitions.compactMap { definition in
            guard let request = try? definition.request() else { return nil }
            return EvaluationCase(id: definition.id, summary: definition.summary, request: request)
        }
    }

    private struct Definition: Sendable {
        let id: String
        let summary: String
        let request: @Sendable () throws -> MakeSomethingRequest
    }

    private static func food(_ name: String, soon: Bool = false, _ quantity: Quantity = .unknown) -> MealContextIngredient {
        MealContextIngredient(name: name, useSoon: soon, quantity: quantity)
    }

    private static func diner(
        _ restrictions: Set<DietaryRestriction> = [],
        likes: [String] = [],
        dislikes: [String] = [],
        spice: SpiceTolerance? = nil
    ) -> ConsumerProfile {
        ConsumerProfile(
            name: "Diner",
            restrictions: .known(restrictions),
            preferences: DietaryPreferences(
                likes: Set(likes.map(IngredientName.init)),
                dislikes: Set(dislikes.map(IngredientName.init)),
                spiceTolerance: spice
            )
        )
    }

    private static func newRecipe(_ foods: [MealContextIngredient], _ diners: [ConsumerProfile]) throws -> MakeSomethingRequest {
        .newRecipe(try MakeSomethingContext(ingredients: foods, diners: diners))
    }

    private static let definitions: [Definition] = [
        Definition(id: "no-restrictions", summary: "Everyday ingredients, no restrictions, spinach to use soon") {
            try newRecipe([food("rice"), food("eggs"), food("spinach", soon: true), food("cheddar cheese")], [diner()])
        },
        Definition(id: "peanut-allergy", summary: "Peanut allergy with peanut butter on hand") {
            try newRecipe(
                [food("chicken breast"), food("rice"), food("peanut butter"), food("broccoli"), food("soy sauce")],
                [diner([.allergen(.peanut)])]
            )
        },
        Definition(id: "vegetarian", summary: "Vegetarian with chicken on hand") {
            try newRecipe(
                [food("chickpeas"), food("tomatoes"), food("onion"), food("rice"), food("chicken thighs", soon: true)],
                [diner([.diet(.vegetarian)])]
            )
        },
        Definition(id: "gluten-free", summary: "Gluten-free with pasta on hand") {
            try newRecipe(
                [food("pasta"), food("tomatoes"), food("basil"), food("chicken breast"), food("olive oil")],
                [diner([.diet(.glutenFree)])]
            )
        },
        Definition(id: "milk-allergy", summary: "Milk allergy with milk and butter on hand") {
            try newRecipe(
                [food("milk", .aboutHalf), food("butter"), food("potatoes"), food("chicken breast"), food("garlic")],
                [diner([.allergen(.milk)])]
            )
        },
        Definition(id: "vegan-tree-nut", summary: "Vegan with a tree nut allergy, almonds and honey on hand") {
            try newRecipe(
                [food("lentils"), food("carrots"), food("almonds"), food("rice"), food("honey")],
                [diner([.diet(.vegan), .allergen(.treeNut)])]
            )
        },
        Definition(id: "shellfish-and-dairy-free", summary: "Two diners: shellfish allergy and dairy-free, shrimp on hand") {
            try newRecipe(
                [food("shrimp"), food("rice"), food("coconut milk"), food("bell pepper"), food("lime")],
                [diner([.allergen(.crustaceanShellfish)]), diner([.diet(.dairyFree)])]
            )
        },
        Definition(id: "avoid-cilantro", summary: "Just-avoid cilantro with cilantro on hand") {
            try newRecipe(
                [food("salmon"), food("rice"), food("cilantro"), food("limes")],
                [diner([.excluded(IngredientName("cilantro"), severity: .justAvoid)])]
            )
        },
        Definition(id: "pork-intolerance", summary: "Strict pork exclusion with pork on hand") {
            try newRecipe(
                [food("ground beef"), food("onions"), food("tortillas"), food("ground pork"), food("cheddar cheese")],
                [diner([.excluded(IngredientName("pork"), severity: .allergyOrIntolerance)])]
            )
        },
        Definition(id: "two-items", summary: "Almost nothing on hand") {
            try newRecipe([food("eggs"), food("bread")], [diner()])
        },
        Definition(id: "adapt-alfredo", summary: "Adapt a cream-based recipe for a dairy-free diner") {
            .adaptation(
                RecipeToAdapt(
                    title: "Chicken Alfredo",
                    ingredientLines: ["8 oz fettuccine", "1 lb chicken breast", "2 cups heavy cream", "1 cup parmesan"]
                ),
                try MakeSomethingContext(
                    ingredients: [food("coconut milk"), food("garlic"), food("nutritional yeast")],
                    diners: [diner([.diet(.dairyFree)])]
                )
            )
        },
        Definition(id: "use-soon-with-preferences", summary: "Several foods to use soon, hot spice, dislikes mushrooms") {
            try newRecipe(
                [food("spinach", soon: true), food("yogurt", soon: true), food("bananas", soon: true), food("bread"), food("mushrooms")],
                [diner(likes: ["lemon"], dislikes: ["mushrooms"], spice: .hot)]
            )
        },
    ]
}
