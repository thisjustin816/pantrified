import Foundation
import Testing
@testable import PantrifiedDomain

private func verdict(
    title: String = "", _ lines: [String], _ instructions: [String], origin: RecipeOrigin = .generated,
    _ restrictions: Set<DietaryRestriction>
) -> DietaryVerdict {
    DietaryValidator().assess(
        RecipeUnderReview(title: title, ingredientLines: lines, instructions: instructions, completeness: .complete, origin: origin),
        against: restrictions
    ).verdict
}

private func unrecognized(_ verdict: DietaryVerdict) -> [String] {
    guard case .needsReview(let reasons) = verdict else { return [] }
    return reasons.compactMap { reason in
        if case .unrecognizedWord(let word) = reason { word } else { nil }
    }
}

private let chickenRice = ["1 lb chicken breast", "2 cups cooked rice", "1 tbsp olive oil", "1 tsp salt"]
private let potatoes = ["2 cups cooked rice", "2 potatoes", "1 onion", "1 tbsp olive oil", "1 tsp salt", "2 cups water"]

/// Nouns that can name a food, a dish, a product, or a portion or container that stands in for an
/// unnamed food. The classification data covers the foods it knows; this covers the rest, written
/// in each form that names a food, since the scan compares words as written.
private let foodNouns: Set<String> = [
    "wrap", "wraps", "roast", "roasts", "rub", "rubs", "mash", "spread", "spreads", "bake", "bakes",
    "fry", "fries", "crisp", "crisps", "shake", "shakes", "fluff", "blend", "blends", "mix", "mixes",
    "chop", "chops", "mince", "peel", "peels", "zest", "drizzle", "scoop", "scoops", "slice", "slices",
    "cube", "cubes", "knob", "splash", "dash", "pinch", "handful", "spoonful", "dollop", "swirl", "jar",
    "jars", "can", "cans", "tin", "tins", "box", "bag", "bottle", "carton", "packet", "package",
    "container", "sheet", "sheets", "clove", "cloves", "layer", "layers", "bite", "bites", "piece",
    "pieces", "pat", "pats", "stick", "sticks", "strip", "strips", "wedge", "wedges", "chunk", "chunks",
    "drop", "drops", "round", "rounds", "ring", "rings", "rack", "racks", "double", "single", "side",
    "sides", "dish", "dishes", "skin", "skins", "paper", "flavor", "flavors", "flavour", "flavours",
    "char", "tender", "tenders", "braise", "braises", "sprinkles", "must", "skim", "whole", "dark",
    "board", "boards", "heart", "hearts", "baking", "skewers", "toast", "roll", "rolls", "bun", "buns",
    "crumb", "crumbs", "dressing", "glaze", "juice", "juices", "seed", "seeds", "dough", "batter",
    "paste", "garnish", "liquid", "topping", "filling", "stuffing", "frosting", "icing", "coating",
    "breading", "gravy", "dip", "snack", "starter", "main", "dessert", "treat", "salad", "soup",
    "stew", "curry", "chip", "chips", "cracker", "wafer", "bar", "cake", "pie", "tart", "biscuit",
    "cookie", "muffin", "pancake", "waffle", "noodle", "noodles", "dumpling", "loaf", "fillet",
    "cutlet", "patty", "burger", "nugget", "finger", "fingers", "jerky", "sweet", "sweets", "savoury",
    "savory", "candy", "gum", "jam", "jelly", "preserves", "custard", "pudding", "sorbet", "ice",
    "float", "punch", "cobbler", "crumble", "trifle", "fool", "brittle", "bark", "fudge", "mousse",
    "flan", "sponge", "scone", "chutney", "relish", "pickle", "slaw", "hash", "salsa", "marinade",
    "brine", "rind", "pith", "pulp", "leaf", "leaves", "herb", "herbs", "spice", "spices", "greens",
    "veg", "veggies", "vegetable", "vegetables", "fruit", "fruits", "poultry", "game", "bean", "beans",
    "pea", "peas", "grain", "grains", "fat", "fats", "drippings", "suet", "tallow", "yolk", "whites",
    "syrup", "wine", "beer", "cider", "spirit", "liqueur", "tea", "coffee", "cocoa", "powder", "starch",
    "meal", "bran", "germ", "yeast", "rennet", "extract", "essence", "food", "foods", "dinner", "lunch",
    "breakfast", "supper", "brunch", "loin", "shank", "breast", "thigh", "wing", "wings", "leg",
    "drumstick", "tail", "tongue", "cheek", "liver", "gizzard", "tripe", "marrow", "bone", "bones",
    "crackling", "flank", "skirt", "brisket", "chuck", "rump", "sirloin", "tenderloin",
]

/// The word, its singular, and the stems it could be formed from. Plurals of a vocabulary word
/// are not needed: the scan compares words as written, so "leaves" is outside the vocabulary even
/// though "leave" is in it.
private func forms(of word: String) -> Set<String> {
    var forms: Set<String> = [word, IngredientName(word).text]
    func doubled(_ stem: Substring) -> String? {
        guard let last = stem.last, stem.dropLast().last == last else { return nil }
        return String(stem.dropLast())
    }
    for suffix in ["ed", "ing"] where word.hasSuffix(suffix) {
        let stem = word.dropLast(suffix.count)
        forms.formUnion([String(stem), String(stem) + "e"])
        if let single = doubled(stem) { forms.insert(single) }
    }
    if word.hasSuffix("ied") { forms.insert(String(word.dropLast(3)) + "y") }
    if word.hasSuffix("ly") { forms.insert(String(word.dropLast(2))) }
    if word.hasSuffix("y") { forms.insert(String(word.dropLast())) }
    return forms
}

@Suite("Cooking vocabulary")
struct CookingVocabularyTests {
    /// The vocabulary is the only thing that lets a generated or sourced recipe use a word
    /// without it being checked as a food, so a food word that slips in turns an unlisted food
    /// into a pass. Food-changing words are allowed a food stem ("toasted"), because every use of
    /// one beside a food is flagged; their own form still may not be a food.
    @Test("no vocabulary word, its singular or its stem names a food")
    func noWordNamesAFood() {
        let dataNames = Set(ClassificationDataset.bundled.entries.flatMap(\.names).map(\.text))
        let phrases = CookingVocabulary.phrases.map { $0.joined(separator: " ") }
        for word in CookingVocabulary.words.union(phrases) {
            let checked = CookingVocabulary.canChangeFood(word) ? [word, IngredientName(word).text] : forms(of: word)
            let foods = checked.filter { dataNames.contains($0) || dataNames.contains(IngredientName($0).text) || foodNouns.contains($0) }
            #expect(foods.isEmpty, "\(word) can be read as the food \(foods.sorted())")
        }
    }

    @Test("a measure alone is not accepted, since it can stand for an unnamed food",
          arguments: CookingVocabulary.measures.sorted())
    func measureAlone(measure: String) {
        let alone = verdict(potatoes, ["Melt a \(measure) in the pan."], [.allergen(.milk)])
        let measuring = verdict(potatoes, ["Add a \(measure) of the cooked rice to the pan."], [.allergen(.milk)])

        #expect(unrecognized(alone) == [measure])
        #expect(measuring == .safe)
    }

    @Test("a measure is not accepted across punctuation, or before a word that is not a food")
    func measureNeedsAFoodRightAfter() {
        #expect(unrecognized(verdict(potatoes, ["Top with a slice, the rice and the onion."], [.allergen(.milk)])) == ["slice"])
        #expect(unrecognized(verdict(potatoes, ["Spread 2 tbsp on the potatoes."], [.allergen(.milk)])) == ["spread", "tbsp"])
    }

    @Test("a shape after into is accepted, and the same word elsewhere is not")
    func shapes() {
        #expect(verdict(potatoes, ["Cut the potatoes into bite-size pieces."], [.allergen(.milk)]) == .safe)
        #expect(unrecognized(verdict(potatoes, ["Serve with the strips."], [.allergen(.milk)])) == ["strips"])
        #expect(unrecognized(verdict(potatoes, ["Stir the rice into the slices."], [.allergen(.milk)])) == ["slices"])
    }

    @Test("a noun that names a food is never cooking vocabulary", arguments: [
        ("", chickenRice, "Serve the chicken and rice in a wrap.", DietaryRestriction.allergen(.wheat)),
        ("Chicken Rice Wrap", chickenRice, "Cook the chicken and rice.", .diet(.glutenFree)),
        ("", potatoes, "Dissolve one cube in the water and add the rice.", .diet(.vegetarian)),
        ("", chickenRice, "Serve the chicken with mash.", .allergen(.milk)),
        ("", potatoes, "Serve with the roast.", .diet(.vegetarian)),
        ("Rice for the Roast", potatoes, "Cook the rice.", .diet(.vegetarian)),
        ("", chickenRice, "Coat the chicken with the rub and grill.", .allergen(.peanut)),
        ("", potatoes, "Serve with toasted slices.", .allergen(.wheat)),
        ("", potatoes, "Boil the potatoes and top with a spread.", .allergen(.milk)),
        ("", potatoes, "Melt a knob in the pan.", .allergen(.milk)),
        ("", potatoes, "Top each potato with a slice and grill until melted.", .allergen(.milk)),
        ("", chickenRice, "Stir in half the jar.", .allergen(.peanut)),
        ("", potatoes, "Add a splash to loosen the rice.", .allergen(.milk)),
        ("", potatoes, "Serve with a shake.", .allergen(.milk)),
        ("", potatoes, "Top with fluff.", .allergen(.egg)),
        ("", potatoes, "Stir in a little double.", .allergen(.milk)),
        ("", potatoes, "Stir in the skim.", .allergen(.milk)),
        ("", potatoes, "Serve as a fry.", .allergen(.milk)),
        ("", potatoes, "Serve with the bake.", .allergen(.milk)),
        ("", potatoes, "Serve with a crisp.", .allergen(.milk)),
        ("", potatoes, "Finish with a drizzle.", .allergen(.sesame)),
        ("", potatoes, "Add the zest.", .allergen(.milk)),
        ("", potatoes, "Stir in the can.", .allergen(.milk)),
        ("", potatoes, "Lay a sheet over the potatoes.", .allergen(.wheat)),
        ("", potatoes, "Add a dash.", .allergen(.fish)),
        ("", potatoes, "Serve with a tender.", .allergen(.wheat)),
        ("", potatoes, "Serve with a side.", .diet(.vegetarian)),
        ("", potatoes, "Serve with a chop.", .diet(.vegetarian)),
        ("", potatoes, "Melt the dark over the potatoes.", .allergen(.milk)),
        ("", potatoes, "Add the cloves.", .allergen(.milk)),
        ("", chickenRice, "Roll the chicken in rice paper.", .allergen(.wheat)),
        ("", potatoes, "Serve on a board.", .allergen(.milk)),
        ("", potatoes, "Top with the grated.", .allergen(.milk)),
        ("", potatoes, "Serve with the hot.", .allergen(.wheat)),
        ("", potatoes, "Serve with a light.", .allergen(.milk)),
        ("", potatoes, "Top with the golden and crispy.", .allergen(.wheat)),
        ("", potatoes, "Crack 2 into the bowl.", .allergen(.egg)),
        ("", potatoes, "Add the two.", .allergen(.milk)),
        ("", potatoes, "Crack a dozen into the bowl.", .allergen(.egg)),
        ("", potatoes, "Top with 🧈.", .allergen(.milk)),
        ("Rice with 🥜", potatoes, "Cook the rice.", .allergen(.peanut)),
    ] as [(String, [String], String, DietaryRestriction)])
    func foodNounsNeedReview(title: String, lines: [String], instruction: String, restriction: DietaryRestriction) {
        for origin in [RecipeOrigin.generated, .sourced] {
            #expect(verdict(title: title, lines, [instruction], origin: origin, [restriction]) != .safe, "\(origin)")
        }
    }

    @Test("the harness sees safe recipes as safe")
    func controls() {
        #expect(verdict(chickenRice, ["Cook the chicken and rice."], [.allergen(.wheat)]) == .safe)
        #expect(verdict(potatoes, ["Heat the oil in a large pan for 2 minutes, then add the cooked rice."], [.allergen(.milk)]) == .safe)
        #expect(verdict(potatoes, ["Boil the potatoes."], [.diet(.vegetarian)]) == .safe)
        #expect(verdict(potatoes, ["Boil the potatoes."], origin: .sourced, [.diet(.vegetarian)]) == .safe)
    }

    @Test("a step that uses a word that can name a dish needs review, even when it means the method")
    func methodNamesThatAreDishes() {
        #expect(unrecognized(verdict(potatoes, ["Bake at 200 degrees for 20 minutes."], [.allergen(.milk)])) == ["bake"])
        #expect(unrecognized(verdict(potatoes, ["Chop the onion."], [.allergen(.milk)])) == ["chop"])
    }
}
