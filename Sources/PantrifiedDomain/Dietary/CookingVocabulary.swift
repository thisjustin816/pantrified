import Foundation

/// Words a generated title or instruction may use without naming a food. A word outside this
/// list, the listed foods and the classification data makes a generated recipe need review.
///
/// Words are compared as written, before singular forms are taken, so "fries" is not read as the
/// verb "fry". A word that can also name a food is left out even when its usual sense is a verb or
/// a utensil: "toast", "roll", "crumb", "grease", "dressing", "glaze", "juice", "seeds", "dough",
/// "batter", "paste", "garnish" and "liquid" could all hide an unlisted ingredient.
enum CookingVocabulary {
    static func contains(_ word: String) -> Bool {
        words.contains(word) || word.allSatisfy(\.isNumber)
    }

    /// True for a cooking word that, placed before a food, can name a different prepared food:
    /// fried onions are often battered, baked beans hold pork and sugar, seasoned salt is a blend.
    static func canChangeFood(_ word: String) -> Bool {
        foodChanging.contains(word)
    }

    private static let foodChanging: Set<String> = [
        "fried", "crispy", "crisp", "crunchy", "baked", "seasoned", "hot", "brown",
    ]

    private static let words: Set<String> = {
        let groups: [[String]] = [functionWords, numbers, measures, equipment, methods, states, time, dishes]
        return Set(groups.joined().flatMap { $0.split(separator: " ").map(String.init) })
    }()

    private static let functionWords = [
        "a an the and or but nor of to in into on onto at by for from with without over under",
        "until till about around through throughout across between along off out up down then than",
        "as so if when while once after before again also just only very too more most less much",
        "many few little some any all each every both either other another remaining it its them",
        "they their this that these those there here you your we our i is are be been being was",
        "were will would can could should may might must do does don t s not no now still already",
        "well even evenly gently slowly quickly carefully lightly thoroughly completely occasionally",
        "frequently constantly briefly immediately together apart aside away back how what which",
        "who per via where whichever enough",
    ]

    private static let numbers = [
        "one two three four five six seven eight nine ten eleven twelve fifteen twenty thirty",
        "forty fifty sixty half halves halfway third thirds quarter quarters dozen double single",
        "first second third next last final finally",
    ]

    private static let measures = [
        "cup cups tablespoon tablespoons tbsp teaspoon teaspoons tsp ounce ounces oz pound pounds",
        "lb lbs gram grams g kg ml l liter liters litre litres inch inches cm mm degree degrees f c",
        "pinch pinches dash dashes handful handfuls piece pieces slice slices clove cloves can cans",
        "batch batches portion portions serving servings amount size sized bite bites layer layers",
        "knob splash spoonful spoonfuls quantity",
    ]

    private static let equipment = [
        "pan pans pot pots saucepan skillet wok oven stove stovetop burner grill broiler microwave",
        "bowl bowls plate plates platter dish dishes baking sheet tray rack lid foil parchment paper",
        "towel towels knife board cutting spoon spoons ladle spatula tongs whisk blender processor",
        "colander sieve strainer jar container airtight fridge refrigerator freezer surface edge",
        "edges side sides center centre top bottom middle mixture skewer skewers",
    ]

    private static let methods = [
        "add added adding adjust arrange bake baked beat blanch blend blended boil boiling boiled",
        "braise braised bring brown browned brush char charred chill chilled chop coat coated",
        "combine combined cook cooked cooking cool cooled cover covered crack cube cubed cut",
        "deglaze dice discard dissolve divide drain drizzle drizzled dust enjoy finish flip fluff",
        "fold fry fried frying grate grill grilled halve heat heated keep knead ladle lay layer leave",
        "let lift lower make marinate mash mashed measure melt melted mince mix mixed moisten pat",
        "peel peeled pile place placed plate poach poached pour poured preheat preheated prepare",
        "press pressed reduce reduced refrigerate reheat remove removed repeat rest rested return",
        "rinse rinsed roast roasted rub saute sauté sautéed sauteed scatter scoop scrape sear seared",
        "season seasoned separate serve served set shake shred sift simmer simmering simmered skim",
        "smash soak soften softened spread sprinkle squeeze steam steamed stir stirred stirring",
        "store strain swirl taste tear thicken thickened toss tossed transfer trim turn turning",
        "uncover wash warm warmed whisked wilt wilted wipe wrap zest use using start begin continue",
        "allow check watch wait become becomes look looks appear reserve reserved save shape form",
        "fill stack open close toasted blacken get go need needed",
    ]

    private static let states = [
        "golden tender soft crisp crispy crunchy smooth thick thin fluffy fragrant aromatic",
        "translucent opaque bubbling bubbly hot warm cold cool room temperature ready done raw firm",
        "dry wet moist light dark deep shallow large small medium high low fine finely roughly",
        "coarse coarsely thinly whole halved combined desired consistency texture color colour",
        "flavor flavors flavour flavours aroma skin fresh freshly chopped diced minced sliced grated",
        "ripe boneless skinless organic optional optionally preference",
    ]

    private static let time = [
        "overnight day days ahead later meanwhile minute minutes min mins hour hours hr hrs time",
        "times total approximately instantly",
    ]

    private static let dishes = [
        "quick easy simple weeknight everyday classic homemade rustic hearty healthy speedy style",
        "bake",
    ]
}
