import Foundation
import Testing
@testable import PantrifiedDomain

/// A realistic recipe and the verdict the validator must reach for it.
struct DietaryCase: Sendable, CustomTestStringConvertible {
    enum Expected: Sendable {
        case safe
        case noRestrictions
        /// The ingredients, by normalized name, that positively violate a restriction.
        case violation(Set<String>)
        /// The review reasons that must all be present.
        case needsReview(Set<ReviewReason.Kind>)
    }

    let name: String
    var title = ""
    let lines: [String]
    var instructions: [String] = []
    var completeness: IngredientListCompleteness = .complete
    var origin: RecipeOrigin = .sourced
    var providerLabels: Set<String> = []
    let restrictions: Set<DietaryRestriction>
    let expected: Expected

    var testDescription: String { name }

    var recipe: RecipeUnderReview {
        RecipeUnderReview(
            title: title, ingredientLines: lines, instructions: instructions,
            completeness: completeness, origin: origin, providerLabels: providerLabels
        )
    }
}

private func strictlyExcluded(_ name: String) -> DietaryRestriction {
    .excluded(IngredientName(name), severity: .allergyOrIntolerance)
}

private func avoided(_ name: String) -> DietaryRestriction { .excluded(IngredientName(name), severity: .justAvoid) }

private let vegetarian = DietaryRestriction.diet(.vegetarian)
private let vegan = DietaryRestriction.diet(.vegan)
private let glutenFree = DietaryRestriction.diet(.glutenFree)
private let dairyFree = DietaryRestriction.diet(.dairyFree)

let dietaryCorpus: [DietaryCase] = [
    // Clear passes
    DietaryCase(
        name: "rice and beans pass vegan, dairy-free and a peanut allergy",
        lines: [
            "2 cups cooked rice", "1 can black beans, drained and rinsed", "1 onion, diced",
            "2 cloves garlic, minced", "1 tbsp olive oil", "Salt and pepper to taste",
        ],
        restrictions: [vegan, dairyFree, .allergen(.peanut)],
        expected: .safe
    ),
    DietaryCase(
        name: "lemon chicken passes gluten-free and dairy-free",
        lines: ["1 lb boneless chicken breasts", "2 cups broccoli florets", "2 tbsp extra virgin olive oil", "1 lemon", "1 tsp kosher salt"],
        restrictions: [glutenFree, dairyFree],
        expected: .safe
    ),
    DietaryCase(
        name: "pasta with parmesan passes a peanut allergy",
        lines: ["8 oz spaghetti", "1 (14 oz) can crushed tomatoes", "2 cloves garlic", "2 tbsp olive oil", "1/4 cup grated parmesan"],
        restrictions: [.allergen(.peanut)],
        expected: .safe
    ),

    DietaryCase(
        name: "a custom exclusion passes foods known to be something else",
        lines: ["2 cups cooked rice", "1 tbsp olive oil", "1/2 tsp paprika"],
        restrictions: [strictlyExcluded("pork")],
        expected: .safe
    ),
    DietaryCase(
        name: "with no hard restrictions there is nothing to label",
        lines: ["2 tbsp butter", "1 cup mystery ingredient"],
        restrictions: [],
        expected: .noRestrictions
    ),

    // Just-avoid exclusions: matched by name, synonym and made-from links only
    DietaryCase(
        name: "a just-avoid exclusion the data does not know passes a recipe that does not name it",
        lines: ["1 potato", "1 tomato"],
        restrictions: [avoided("nightshades")],
        expected: .safe
    ),
    DietaryCase(
        name: "a just-avoid exclusion does not make unknown foods need review",
        lines: ["1 cup jicama", "1 cup cooked rice", "2 tbsp gochujang"],
        restrictions: [avoided("cilantro")],
        expected: .safe
    ),
    DietaryCase(
        name: "a just-avoid exclusion does not make prepared foods or near names need review",
        lines: ["8 oz penne", "1/2 cup pesto", "2 peppers, seeded and diced"],
        restrictions: [avoided("mushroom"), avoided("bell pepper")],
        expected: .safe
    ),
    DietaryCase(
        name: "a just-avoid exclusion ignores advisories and notes that do not name it",
        lines: ["1 cup rice (may contain peanuts) (such as basmati)", "salt, pepper, rice"],
        restrictions: [avoided("pork")],
        expected: .safe
    ),
    DietaryCase(
        name: "generated text is not held to the cooking vocabulary for a just-avoid exclusion alone",
        lines: ["1 cup rice"],
        instructions: ["Fold in the ricotta."],
        origin: .generated,
        restrictions: [avoided("cilantro")],
        expected: .safe
    ),
    DietaryCase(
        name: "a just-avoid exclusion matches by name",
        lines: ["1 bunch cilantro, chopped", "1 cup jicama"],
        restrictions: [avoided("cilantro")],
        expected: .violation(["cilantro"])
    ),
    DietaryCase(
        name: "a just-avoid exclusion matches by synonym",
        lines: ["1 can garbanzo beans, drained"],
        restrictions: [avoided("chickpea")],
        expected: .violation(["garbanzo bean"])
    ),
    DietaryCase(
        name: "a just-avoid exclusion matches through what foods are made from",
        lines: ["4 slices bacon", "1/2 cup pesto"],
        restrictions: [avoided("pork"), avoided("milk")],
        expected: .violation(["bacon", "pesto"])
    ),
    DietaryCase(
        name: "a just-avoid exclusion of wheat excludes soy sauce and pasta through what they are made from",
        lines: ["2 tbsp soy sauce", "8 oz pasta"],
        restrictions: [avoided("wheat")],
        expected: .violation(["soy sauce", "pasta"])
    ),
    DietaryCase(
        name: "a just-avoid exclusion matches a line it cannot parse by name",
        lines: ["salt, pepper, cilantro"],
        restrictions: [avoided("cilantro")],
        expected: .violation(["cilantro"])
    ),
    DietaryCase(
        name: "a just-avoid exclusion still needs review for an advisory naming it",
        lines: ["1 cup rice (may contain peanuts)"],
        restrictions: [avoided("peanut")],
        expected: .needsReview([.advisoryStatement])
    ),
    DietaryCase(
        name: "a just-avoid exclusion is matched in the instructions",
        lines: ["1 cup cooked rice"],
        instructions: ["Top with cilantro."],
        restrictions: [avoided("cilantro")],
        expected: .needsReview([.mentionedButNotListed])
    ),
    DietaryCase(
        name: "a strict exclusion needs review for a prepared food that may be made from it",
        lines: ["1 lb sausage"],
        restrictions: [strictlyExcluded("beef")],
        expected: .needsReview([.compositeMayHideExclusion])
    ),
    DietaryCase(
        name: "a strict exclusion of shrimp needs review for other crustaceans",
        lines: ["1 cup crab", "1 lobster"],
        restrictions: [strictlyExcluded("shrimp")],
        expected: .needsReview([.mayBeExcluded])
    ),
    DietaryCase(
        name: "a strict exclusion of almond needs review for other tree nuts",
        lines: ["1 cup walnuts"],
        restrictions: [strictlyExcluded("almond")],
        expected: .needsReview([.mayBeExcluded])
    ),
    DietaryCase(
        name: "a strict exclusion of cod needs review for other fish",
        lines: ["1 lb salmon"],
        restrictions: [strictlyExcluded("cod")],
        expected: .needsReview([.mayBeExcluded])
    ),
    DietaryCase(
        name: "a strict exclusion of clam needs review for other molluscs",
        lines: ["6 oysters"],
        restrictions: [strictlyExcluded("clam")],
        expected: .needsReview([.mayBeExcluded])
    ),
    DietaryCase(
        name: "a strict exclusion of pork needs review for other meat",
        lines: ["1 lb chicken thighs"],
        restrictions: [strictlyExcluded("pork")],
        expected: .needsReview([.mayBeExcluded])
    ),
    DietaryCase(
        name: "a strict exclusion of beef needs review for cheese, which may use calf rennet",
        lines: ["1 cup cheddar"],
        restrictions: [strictlyExcluded("beef")],
        expected: .needsReview([.mayBeExcluded])
    ),
    DietaryCase(
        name: "a just-avoid exclusion of shrimp still passes other crustaceans",
        lines: ["1 cup crab"],
        restrictions: [avoided("shrimp")],
        expected: .safe
    ),
    DietaryCase(
        name: "a just-avoid exclusion is found in the instructions even inside a longer known food",
        lines: ["1 potato"],
        instructions: ["Top with cream cheese."],
        restrictions: [avoided("cream cheese")],
        expected: .needsReview([.mentionedButNotListed])
    ),
    DietaryCase(
        name: "a just-avoid exclusion is found in generated instructions alongside an allergy",
        lines: ["1 potato"],
        instructions: ["Top with cream cheese."],
        origin: .generated,
        restrictions: [avoided("cream cheese"), .allergen(.peanut)],
        expected: .needsReview([.mentionedButNotListed])
    ),
    DietaryCase(
        name: "a just-avoid exclusion is found when its first word is a known food",
        lines: ["1 cup rice"],
        instructions: ["Stir in almond extract."],
        restrictions: [avoided("almond extract")],
        expected: .needsReview([.mentionedButNotListed])
    ),
    DietaryCase(
        name: "a just-avoid exclusion is found when a known food ends inside it",
        lines: ["1 potato"],
        instructions: ["Sprinkle with black pepper flakes."],
        restrictions: [avoided("pepper flakes")],
        expected: .needsReview([.mentionedButNotListed])
    ),
    DietaryCase(
        name: "a just-avoid exclusion is found when hyphens split it",
        lines: ["1 cup rice"],
        instructions: ["Top with crushed pea-nuts."],
        restrictions: [avoided("peanut")],
        expected: .needsReview([.mentionedButNotListed])
    ),

    // Positive violations, including hidden ones
    DietaryCase(
        name: "butter breaks vegan",
        lines: ["2 tbsp unsalted butter", "1 onion"],
        restrictions: [vegan],
        expected: .violation(["unsalted butter"])
    ),
    DietaryCase(
        name: "a provider's vegan label does not excuse butter",
        lines: ["2 tbsp butter", "1 onion"],
        providerLabels: ["Vegan", "Dairy-Free"],
        restrictions: [vegan],
        expected: .violation(["butter"])
    ),
    DietaryCase(
        name: "soy sauce hides wheat from a gluten-free diet",
        lines: ["1 lb chicken breast", "3 tbsp soy sauce", "1 tbsp sesame oil"],
        restrictions: [glutenFree],
        expected: .violation(["soy sauce"])
    ),
    DietaryCase(
        name: "Worcestershire sauce hides anchovy from a vegetarian",
        lines: ["1 lb mushrooms, sliced", "1 tbsp Worcestershire sauce", "2 tbsp butter"],
        restrictions: [vegetarian],
        expected: .violation(["worcestershire sauce"])
    ),
    DietaryCase(
        name: "gelatin breaks vegetarian",
        lines: ["2 cups plain yogurt", "1 tbsp gelatin", "1/4 cup honey"],
        restrictions: [vegetarian],
        expected: .violation(["gelatin"])
    ),
    DietaryCase(
        name: "honey breaks vegan but not vegetarian",
        lines: ["1/4 cup honey", "1 cup rolled oats"],
        restrictions: [vegan],
        expected: .violation(["honey"])
    ),
    DietaryCase(
        name: "pesto hides pine nuts from a tree nut allergy",
        lines: ["8 oz penne", "1/2 cup pesto"],
        restrictions: [.allergen(.treeNut)],
        expected: .violation(["pesto"])
    ),
    DietaryCase(
        name: "excluding pork excludes bacon",
        lines: ["4 slices bacon", "2 eggs"],
        restrictions: [strictlyExcluded("pork")],
        expected: .violation(["bacon"])
    ),
    DietaryCase(
        name: "a custom exclusion matches by name even for foods the data does not know",
        lines: ["1 bunch cilantro, chopped", "1 cup jicama"],
        restrictions: [strictlyExcluded("cilantro")],
        expected: .violation(["cilantro"])
    ),
    DietaryCase(
        name: "excluding pork excludes gelatin",
        lines: ["1 tbsp gelatin"],
        restrictions: [strictlyExcluded("pork")],
        expected: .violation(["gelatin"])
    ),
    DietaryCase(
        name: "excluding cheese excludes parmesan",
        lines: ["1/2 cup parmesan"],
        restrictions: [strictlyExcluded("cheese")],
        expected: .violation(["parmesan"])
    ),
    DietaryCase(
        name: "excluding milk excludes butter",
        lines: ["2 tbsp butter"],
        restrictions: [strictlyExcluded("milk")],
        expected: .violation(["butter"])
    ),
    DietaryCase(
        name: "excluding milk excludes pesto through the parmesan in it",
        lines: ["1/2 cup pesto"],
        restrictions: [strictlyExcluded("milk")],
        expected: .violation(["pesto"])
    ),
    DietaryCase(
        name: "excluding sesame seed excludes tahini",
        lines: ["2 tbsp tahini"],
        restrictions: [strictlyExcluded("sesame seed")],
        expected: .violation(["tahini"])
    ),
    DietaryCase(
        name: "excluding pepper excludes paprika",
        lines: ["1 tsp paprika"],
        restrictions: [strictlyExcluded("pepper")],
        expected: .violation(["paprika"])
    ),
    DietaryCase(
        name: "excluding a class of foods excludes its members",
        lines: ["2 tbsp butter", "1 cup almonds", "1/2 cup peanut butter", "1 lb cod", "1 cup barley"],
        restrictions: [strictlyExcluded("dairy"), strictlyExcluded("nuts"), strictlyExcluded("seafood"), strictlyExcluded("gluten")],
        expected: .violation(["butter", "almond", "peanut butter", "cod", "barley"])
    ),
    DietaryCase(
        name: "excluding a class of foods excludes a food made from a member",
        lines: ["1 tbsp gelatin"],
        restrictions: [strictlyExcluded("meat")],
        expected: .violation(["gelatin"])
    ),
    DietaryCase(
        name: "a just-avoid exclusion of a class of foods excludes its members",
        lines: ["1 lb salmon", "1 cup cheddar", "1 lb ground beef"],
        restrictions: [avoided("fish"), avoided("dairy"), avoided("meat")],
        expected: .violation(["salmon", "cheddar", "ground beef"])
    ),
    DietaryCase(
        name: "shrimp breaks a shellfish allergy",
        lines: ["1 lb shrimp, peeled", "2 cloves garlic", "2 tbsp olive oil"],
        restrictions: [.allergen(.crustaceanShellfish)],
        expected: .violation(["shrimp"])
    ),
    DietaryCase(
        name: "barley breaks gluten-free",
        lines: ["1 cup barley", "1 carrot"],
        restrictions: [glutenFree],
        expected: .violation(["barley"])
    ),
    DietaryCase(
        name: "when every alternative breaks the restriction it is a violation",
        lines: ["1 cup milk or almond milk"],
        restrictions: [dairyFree, .allergen(.treeNut)],
        expected: .violation(["milk", "almond milk"])
    ),
    DietaryCase(
        name: "a violation is reported even when the list is incomplete",
        lines: ["2 tbsp butter"],
        completeness: .partial,
        restrictions: [dairyFree],
        expected: .violation(["butter"])
    ),

    // Needs review
    DietaryCase(
        name: "an empty ingredient list needs review",
        lines: [" ", ""],
        restrictions: [vegetarian],
        expected: .needsReview([.emptyIngredientList])
    ),
    DietaryCase(
        name: "a list the provider may have truncated needs review",
        lines: ["2 cups cooked rice", "1 onion"],
        completeness: .partial,
        restrictions: [vegan],
        expected: .needsReview([.incompleteIngredientList])
    ),
    DietaryCase(
        name: "a list of unknown completeness needs review",
        lines: ["2 cups cooked rice"],
        completeness: .unknown,
        restrictions: [vegan],
        expected: .needsReview([.incompleteIngredientList])
    ),
    DietaryCase(
        name: "an ingredient the data does not know needs review",
        lines: ["2 tbsp gochujang", "1 cup cooked rice"],
        restrictions: [vegan],
        expected: .needsReview([.unknownIngredient])
    ),
    DietaryCase(
        name: "a line that is only a quantity cannot be parsed",
        lines: ["2 cups", "1 cup cooked rice"],
        restrictions: [vegan],
        expected: .needsReview([.unparsedLine])
    ),
    DietaryCase(
        name: "several ingredients run together with commas cannot be parsed",
        lines: ["salt, pepper, rice"],
        restrictions: [vegan],
        expected: .needsReview([.unparsedLine])
    ),
    DietaryCase(
        name: "generic broth may be meat broth",
        lines: ["4 cups broth", "1 cup lentils"],
        restrictions: [vegetarian],
        expected: .needsReview([.mayContain])
    ),
    DietaryCase(
        name: "chicken broth may contain wheat",
        lines: ["4 cups chicken broth", "1 cup cooked rice"],
        restrictions: [glutenFree],
        expected: .needsReview([.mayContain])
    ),
    DietaryCase(
        name: "natural flavors may be animal-derived",
        lines: ["1 cup cooked rice", "1 tsp natural flavors"],
        restrictions: [vegan],
        expected: .needsReview([.mayContain])
    ),
    DietaryCase(
        name: "a seasoning blend may contain gluten",
        lines: ["1 lb chicken breast", "2 tbsp seasoning"],
        restrictions: [glutenFree],
        expected: .needsReview([.mayContain])
    ),
    DietaryCase(
        name: "an unnamed sauce may contain anything",
        lines: ["1 cup cooked rice", "1/4 cup sauce"],
        restrictions: [.allergen(.sesame)],
        expected: .needsReview([.mayContain])
    ),
    DietaryCase(
        name: "bouillon may be made from shrimp",
        lines: ["1 bouillon cube", "1 cup cooked rice"],
        restrictions: [.allergen(.crustaceanShellfish)],
        expected: .needsReview([.mayContain])
    ),
    DietaryCase(
        name: "generic broth may contain egg",
        lines: ["2 cups broth"],
        restrictions: [.allergen(.egg)],
        expected: .needsReview([.mayContain])
    ),
    DietaryCase(
        name: "curry paste may contain cashew or almond",
        lines: ["2 tbsp curry paste"],
        restrictions: [.allergen(.treeNut)],
        expected: .needsReview([.mayContain])
    ),
    DietaryCase(
        name: "bread may be cross-contacted with tree nuts",
        lines: ["2 slices bread"],
        restrictions: [.allergen(.treeNut)],
        expected: .needsReview([.mayContain])
    ),
    DietaryCase(
        name: "sausage may be bound with egg",
        lines: ["1 lb sausage"],
        restrictions: [.allergen(.egg)],
        expected: .needsReview([.mayContain])
    ),
    DietaryCase(
        name: "cheese may be made with egg lysozyme",
        lines: ["1/2 cup parmesan", "1 cup cheese"],
        restrictions: [.allergen(.egg)],
        expected: .needsReview([.mayContain])
    ),
    DietaryCase(
        name: "gelatin may be made from fish",
        lines: ["1 tbsp gelatin"],
        restrictions: [.allergen(.fish)],
        expected: .needsReview([.mayContain])
    ),
    DietaryCase(
        name: "lentils may carry stray wheat or barley",
        lines: ["1 cup lentils"],
        restrictions: [glutenFree],
        expected: .needsReview([.mayContain])
    ),
    DietaryCase(
        name: "dried beans may carry stray wheat or barley",
        lines: ["1 can black beans, drained and rinsed"],
        restrictions: [glutenFree],
        expected: .needsReview([.mayContain])
    ),
    DietaryCase(
        name: "barley may be cross-contacted with wheat",
        lines: ["1 cup barley", "1 carrot"],
        restrictions: [.allergen(.wheat)],
        expected: .needsReview([.mayContain])
    ),
    DietaryCase(
        name: "maple syrup may be defoamed with butter or lard",
        lines: ["2 tbsp maple syrup", "1 cup rolled oats"],
        restrictions: [vegan],
        expected: .needsReview([.mayContain])
    ),
    DietaryCase(
        name: "ground cumin may be cross-contacted with peanut",
        lines: ["1 tsp ground cumin", "1 cup cooked rice"],
        restrictions: [.allergen(.peanut)],
        expected: .needsReview([.mayContain])
    ),
    DietaryCase(
        name: "unqualified oil may be peanut oil",
        lines: ["1 tbsp oil", "1 cup cooked rice"],
        restrictions: [.allergen(.peanut)],
        expected: .needsReview([.mayContain])
    ),
    DietaryCase(
        name: "oats may be cross-contacted with wheat",
        lines: ["1 cup rolled oats", "1 banana"],
        restrictions: [glutenFree],
        expected: .needsReview([.mayContain])
    ),
    DietaryCase(
        name: "sugar may be refined with bone char",
        lines: ["1 cup sugar", "2 cups flour"],
        restrictions: [vegan],
        expected: .needsReview([.mayContain])
    ),
    DietaryCase(
        name: "a may-contain statement naming a relevant allergen needs review",
        lines: ["1 cup chocolate chips (may contain traces of peanuts)", "1 banana"],
        restrictions: [.allergen(.peanut)],
        expected: .needsReview([.advisoryStatement])
    ),
    DietaryCase(
        name: "a may-contain statement naming nothing recognizable needs review",
        lines: ["1 cup rice, processed in a facility that handles other products"],
        restrictions: [.allergen(.sesame)],
        expected: .needsReview([.advisoryStatement])
    ),
    DietaryCase(
        name: "a may-contain statement naming only the restricted allergen needs review",
        lines: ["1 cup rice (may contain shrimp)"],
        restrictions: [.allergen(.crustaceanShellfish)],
        expected: .needsReview([.advisoryStatement])
    ),
    DietaryCase(
        name: "an advisory naming an allergen and an unrecognized food concerns every restriction",
        lines: ["1 cup rice (may contain milk and shrimp)"],
        restrictions: [.allergen(.crustaceanShellfish)],
        expected: .needsReview([.advisoryStatement])
    ),
    DietaryCase(
        name: "an advisory naming an irrelevant allergen and a tree nut concerns a tree nut allergy",
        lines: ["1 cup rice (may contain wheat and almonds)"],
        restrictions: [.allergen(.treeNut)],
        expected: .needsReview([.advisoryStatement])
    ),
    DietaryCase(
        name: "a may-contain gluten statement concerns a wheat allergy",
        lines: ["1 cup rice (may contain gluten)"],
        restrictions: [.allergen(.wheat)],
        expected: .needsReview([.advisoryStatement])
    ),
    DietaryCase(
        name: "text after an advisory marker cannot hide a food",
        lines: ["2 cups rice, processed in butter with egg"],
        restrictions: [.allergen(.milk)],
        expected: .needsReview([.advisoryStatement])
    ),
    DietaryCase(
        name: "an advisory naming an excluded food needs review",
        lines: ["1 cup rice (may contain peanuts)"],
        restrictions: [strictlyExcluded("peanut")],
        expected: .needsReview([.advisoryStatement])
    ),
    DietaryCase(
        name: "an advisory naming only allergens unrelated to an excluded food passes",
        lines: ["1 cup rice (may contain soy)"],
        restrictions: [strictlyExcluded("pork")],
        expected: .safe
    ),
    DietaryCase(
        name: "an advisory made only of allergen words and filler passes other restrictions",
        lines: ["1 cup rice (processed in a facility that also processes sesame and tree nuts)"],
        restrictions: [.allergen(.milk), vegan],
        expected: .safe
    ),
    DietaryCase(
        name: "a note that could name another ingredient needs review",
        lines: ["1 tbsp vinegar (such as malt)", "1 potato"],
        restrictions: [vegan],
        expected: .needsReview([.unrecognizedNote])
    ),
    DietaryCase(
        name: "alternatives that disagree need review",
        lines: ["1 cup milk or almond milk"],
        restrictions: [dairyFree],
        expected: .needsReview([.alternativesDisagree])
    ),
    DietaryCase(
        name: "an exclusion the data does not know cannot clear other foods",
        lines: ["1 potato", "1 tomato"],
        restrictions: [strictlyExcluded("nightshades")],
        expected: .needsReview([.exclusionUnverifiable])
    ),
    DietaryCase(
        name: "a prepared food may hide an excluded food",
        lines: ["8 oz penne", "1/2 cup pesto"],
        restrictions: [strictlyExcluded("mushroom")],
        expected: .needsReview([.compositeMayHideExclusion])
    ),
    DietaryCase(
        name: "a food that may contain a trait of the excluded food needs review",
        lines: ["8 oz pasta"],
        restrictions: [strictlyExcluded("egg")],
        expected: .needsReview([.mayBeExcluded])
    ),
    DietaryCase(
        name: "a name for a class of foods may be the excluded member",
        lines: ["1 lb white fish"],
        restrictions: [strictlyExcluded("cod")],
        expected: .needsReview([.mayBeExcluded])
    ),
    DietaryCase(
        name: "a less specific name for the excluded food needs review",
        lines: ["2 peppers, seeded and diced"],
        restrictions: [strictlyExcluded("bell pepper")],
        expected: .needsReview([.mayBeExcluded])
    ),
    DietaryCase(
        name: "a different vinegar passes an exclusion of white vinegar",
        lines: ["1 tbsp apple cider vinegar", "1 cup cooked rice"],
        restrictions: [strictlyExcluded("white vinegar")],
        expected: .safe
    ),
    DietaryCase(
        name: "instructions that use an unlisted ingredient need review",
        lines: ["1 lb potatoes", "1 tsp salt"],
        instructions: ["Boil the potatoes until tender.", "Mash with the butter and salt."],
        restrictions: [dairyFree],
        expected: .needsReview([.mentionedButNotListed])
    ),

    // Titles and instructions
    DietaryCase(
        name: "a generated recipe whose instructions use a food the data does not know needs review",
        lines: ["1 cup rice", "1 tbsp olive oil"],
        instructions: ["Fold in the ricotta and serve."],
        origin: .generated,
        restrictions: [.allergen(.milk)],
        expected: .needsReview([.unrecognizedWord])
    ),
    DietaryCase(
        name: "a generated recipe that tops the dish with an unlisted nut needs review",
        lines: ["1 cup rice"],
        instructions: ["Top with toasted hazelnuts."],
        origin: .generated,
        restrictions: [.allergen(.treeNut)],
        expected: .needsReview([.unrecognizedWord])
    ),
    DietaryCase(
        name: "a generated recipe written only in listed foods and cooking words passes",
        title: "Garlic rice",
        lines: ["2 cups cooked rice", "2 cloves garlic, minced", "1 tbsp olive oil"],
        instructions: ["Heat the oil in a large pan over medium heat.", "Add the garlic and cook for 1 minute, then stir in the rice."],
        origin: .generated,
        restrictions: [vegan, .allergen(.peanut)],
        expected: .safe
    ),
    DietaryCase(
        name: "a generated word is checked as written, so fries are not the verb fry",
        lines: ["2 cups cooked rice"],
        instructions: ["Serve with fries."],
        origin: .generated,
        restrictions: [vegan],
        expected: .needsReview([.unrecognizedWord])
    ),
    DietaryCase(
        name: "a generated word that shares only a listed food's first word needs review",
        lines: ["1 can kidney beans, drained"],
        instructions: ["Add the kidneys."],
        origin: .generated,
        restrictions: [vegetarian],
        expected: .needsReview([.unrecognizedWord])
    ),
    DietaryCase(
        name: "a cooking word before a listed food's name can make it a different food",
        lines: ["1 can black beans"],
        instructions: ["Serve with baked beans."],
        origin: .generated,
        restrictions: [vegetarian],
        expected: .needsReview([.unrecognizedWord])
    ),
    DietaryCase(
        name: "a cooking word before a known food can name a prepared food",
        lines: ["1 cup cooked rice", "1 onion"],
        instructions: ["Top with crispy fried onions."],
        origin: .generated,
        restrictions: [.allergen(.wheat)],
        expected: .needsReview([.unrecognizedWord])
    ),
    DietaryCase(
        name: "seasoned salt is not plain salt",
        lines: ["1 cup cooked rice", "1 tsp salt"],
        instructions: ["Sprinkle with seasoned salt."],
        origin: .generated,
        restrictions: [glutenFree],
        expected: .needsReview([.unrecognizedWord])
    ),
    DietaryCase(
        name: "half-and-half is dairy even though each word is a cooking word",
        lines: ["1 cup cooked rice"],
        instructions: ["Stir in the half-and-half."],
        origin: .generated,
        restrictions: [.allergen(.milk)],
        expected: .needsReview([.mentionedButNotListed])
    ),
    DietaryCase(
        name: "toast in sourced instructions is bread",
        lines: ["2 eggs"],
        instructions: ["Serve on toast."],
        restrictions: [.allergen(.wheat)],
        expected: .needsReview([.mentionedButNotListed])
    ),
    DietaryCase(
        name: "an unlisted stock in the instructions needs review",
        lines: ["1 cup rice", "1 onion"],
        instructions: ["Pour in 2 cups of stock and simmer."],
        restrictions: [vegetarian],
        expected: .needsReview([.mentionedButNotListed])
    ),
    DietaryCase(
        name: "an unlisted sauce in the instructions needs review",
        lines: ["1 cup rice"],
        instructions: ["Toss the rice with the sauce."],
        restrictions: [.allergen(.peanut)],
        expected: .needsReview([.mentionedButNotListed])
    ),
    DietaryCase(
        name: "a generic word in the instructions passes when a listed line accounts for it",
        lines: ["1 cup rice", "2 tbsp soy sauce"],
        instructions: ["Toss the rice with the sauce."],
        restrictions: [.allergen(.peanut)],
        expected: .safe
    ),
    DietaryCase(
        name: "a title naming an unlisted food needs review",
        title: "Garlic shrimp rice",
        lines: ["1 cup rice", "2 cloves garlic", "1 tbsp olive oil"],
        restrictions: [.allergen(.crustaceanShellfish)],
        expected: .needsReview([.mentionedButNotListed])
    ),
]

private func kinds(_ reasons: [ReviewReason]) -> Set<ReviewReason.Kind> { Set(reasons.map(\.kind)) }

@Suite("Dietary validation corpus")
struct DietaryValidationCorpusTests {
    private let validator = DietaryValidator()

    @Test("each case reaches its verdict", arguments: dietaryCorpus)
    func corpus(_ testCase: DietaryCase) {
        let verdict = validator.assess(testCase.recipe, against: testCase.restrictions).verdict

        switch (testCase.expected, verdict) {
        case (.safe, .safe), (.noRestrictions, .noRestrictions):
            break
        case (.violation(let expected), .violation(let violations, _)):
            #expect(Set(violations.map(\.ingredient.text)) == expected)
        case (.needsReview(let expected), .needsReview(let reasons)):
            #expect(expected.isSubset(of: kinds(reasons)), "\(reasons)")
        default:
            Issue.record("expected \(testCase.expected), got \(verdict)")
        }
    }

    @Test("the corpus exercises every needs-review reason")
    func everyReviewPathIsCovered() {
        var seen: Set<ReviewReason.Kind> = []
        for testCase in dietaryCorpus {
            if case .needsReview(let expected) = testCase.expected { seen.formUnion(expected) }
        }
        seen.insert(.traitNotCovered)

        #expect(seen == Set(ReviewReason.Kind.allCases))
    }
}
