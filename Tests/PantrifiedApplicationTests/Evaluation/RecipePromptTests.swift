import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain

private func context(
    _ foods: [(String, Bool)],
    restrictions: Set<DietaryRestriction> = [],
    dinerName: String = "Ana",
    preferences: DietaryPreferences = DietaryPreferences()
) throws -> MakeSomethingContext {
    try MakeSomethingContext(
        ingredients: foods.map { MealContextIngredient(name: $0.0, useSoon: $0.1, quantity: .unknown) },
        diners: [ConsumerProfile(name: dinerName, restrictions: .known(restrictions), preferences: preferences)]
    )
}

@Suite("Recipe prompt")
struct RecipePromptTests {
    @Test("the foods on hand are listed in order and use-soon foods are marked")
    func ingredients() throws {
        let prompt = RecipePrompt.render(.newRecipe(try context([("spinach", true), ("rice", false)])))

        #expect(prompt.text.contains("- spinach (use soon)"))
        #expect(prompt.text.contains("- rice\n") || prompt.text.hasSuffix("- rice"))
        #expect(prompt.text.range(of: "spinach")!.lowerBound < prompt.text.range(of: "rice")!.lowerBound)
    }

    @Test("every restriction is stated as something to never include")
    func restrictions() throws {
        let prompt = RecipePrompt.render(.newRecipe(try context(
            [("rice", false)],
            restrictions: [
                .allergen(.milk), .diet(.vegetarian),
                .excluded(IngredientName("cilantro"), severity: .justAvoid),
                .excluded(IngredientName("pork"), severity: .allergyOrIntolerance),
            ]
        )))

        #expect(prompt.text.contains("milk allergy"))
        #expect(prompt.text.contains("vegetarian"))
        #expect(prompt.text.contains("avoid cilantro"))
        #expect(prompt.text.contains("no pork (allergy or intolerance)"))
    }

    @Test("a request with no restrictions says there are none")
    func noRestrictions() throws {
        let prompt = RecipePrompt.render(.newRecipe(try context([("rice", false)])))

        #expect(prompt.text.contains("Restrictions: none"))
    }

    @Test("amounts appear when known")
    func amounts() throws {
        let ingredients = [
            MealContextIngredient(name: "milk", useSoon: false, quantity: .aboutHalf),
            MealContextIngredient(name: "flour", useSoon: false, quantity: .exact(500, unit: "g")),
            MealContextIngredient(name: "eggs", useSoon: false, quantity: .exact(2.5, unit: "dozen")),
        ]
        let context = try MakeSomethingContext(
            ingredients: ingredients,
            diners: [ConsumerProfile(name: "Ana", restrictions: .known([]))]
        )
        let text = RecipePrompt.render(.newRecipe(context)).text

        #expect(text.contains("milk (about half)"))
        #expect(text.contains("flour (500 g)"))
        #expect(text.contains("eggs (2.5 dozen)"))
    }

    @Test("preferences are included without saying who holds them")
    func preferences() throws {
        let prompt = RecipePrompt.render(.newRecipe(try context(
            [("rice", false)],
            preferences: DietaryPreferences(
                likes: [IngredientName("lemon")], dislikes: [IngredientName("mushroom")], spiceTolerance: .mild
            )
        )))

        #expect(prompt.text.contains("Avoid: mushroom"))
        #expect(prompt.text.contains("Prefer: lemon"))
        #expect(prompt.text.contains("Spice: mild"))
    }

    @Test("an adaptation carries the recipe text")
    func adaptation() throws {
        let recipe = RecipeToAdapt(title: "Chicken Alfredo", ingredientLines: ["8 oz fettuccine", "2 cups cream"])
        let prompt = RecipePrompt.render(.adaptation(recipe, try context([("coconut milk", false)])))

        #expect(prompt.text.contains("Chicken Alfredo"))
        #expect(prompt.text.contains("- 8 oz fettuccine"))
        #expect(prompt.text.contains("- coconut milk"))
    }

    @Test("a diner's name never reaches the prompt")
    func noDinerName() throws {
        let prompt = RecipePrompt.render(.newRecipe(try context([("rice", false)], dinerName: "Ana Quintero")))

        #expect(!prompt.text.contains("Ana"))
        #expect(!prompt.instructions.contains("Ana"))
    }

    @Test("the prompt contains no identifier-shaped text")
    func noIdentifiers() throws {
        let prompt = RecipePrompt.render(.newRecipe(try context([("rice", true)], restrictions: [.allergen(.egg)])))
        let uuid = /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/

        #expect(prompt.text.firstMatch(of: uuid) == nil)
    }

    @Test("rendering is deterministic whatever the set order")
    func deterministic() throws {
        let restrictions: Set<DietaryRestriction> = [.allergen(.soy), .allergen(.egg), .diet(.vegan), .allergen(.peanut)]
        let first = RecipePrompt.render(.newRecipe(try context([("rice", false)], restrictions: restrictions)))
        let second = RecipePrompt.render(.newRecipe(try context([("rice", false)], restrictions: restrictions)))

        #expect(first == second)
    }

    @Test("the instructions tell the model to ignore a listed food that breaks a restriction")
    func instructions() throws {
        let prompt = RecipePrompt.render(.newRecipe(try context([("rice", false)])))

        #expect(prompt.instructions.contains("Never include a food that breaks a restriction"))
    }
}
