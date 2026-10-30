import Foundation

/// Words a recipe's title or instructions may use without naming a food. A word outside this
/// vocabulary, the listed foods and the classification data makes the recipe need review.
///
/// No word here may name a food, a dish, a product, or a portion or container that can stand in
/// for one, even when its usual sense is a verb, a utensil or an adjective: "wrap", "roast",
/// "mash", "spread", "rub", "chop", "zest", "tender", "skim" and "double" could each hide an
/// unlisted ingredient, so a recipe that uses them needs review. A test holds every word, its
/// singular and its stems against the classification data and a list of food nouns.
///
/// Words are compared as written, before singular forms are taken, so "fries" is not read as the
/// verb "fry".
enum CookingVocabulary {
    /// True for a word accepted anywhere: vocabulary, or a number.
    static func contains(_ word: String) -> Bool {
        words.contains(word) || word.allSatisfy(\.isNumber)
    }

    /// True for a word of amount or container, such as "cup", "pinch", "slice" or "jar". Alone it
    /// can stand for an unnamed food ("melt a knob in the pan"), so it is accepted only where it
    /// measures a food named right after it ("a knob of butter") or names the shape something is
    /// cut into ("cut into slices").
    static func isMeasure(_ word: String) -> Bool {
        measures.contains(word)
    }

    /// True for a word that describes or counts a food: a descriptor, a food-changing word, or a
    /// number in digits.
    static func describes(_ word: String) -> Bool {
        descriptors.contains(word) || foodChanging.contains(word) || word.allSatisfy(\.isNumber)
    }

    /// The articles a measure may take between "of" and its food: "a cup of the rice".
    static let articles: Set<String> = ["the", "a", "an", "your"]

    /// True for a shape something is cut or divided into, accepted after "into".
    static func isShape(_ word: String) -> Bool {
        shapes.contains(word)
    }

    /// True for a word that may stand between "into" and a shape: "into 1 inch pieces".
    static func sizesShape(_ word: String) -> Bool {
        shapeSizes.contains(word) || word.allSatisfy(\.isNumber)
    }

    /// Multi-word terms accepted as a whole although some of their words are not vocabulary alone:
    /// "baking sheet" is equipment, while "baking" alone can mean baked goods and "sheet" a sheet of
    /// pastry.
    static let phrases: [[String]] = [
        "baking sheet", "baking sheets", "baking dish", "baking pan", "baking tray", "baking paper",
        "sheet pan", "parchment paper", "paper towel", "paper towels", "wire rack", "cooling rack",
        "oven rack", "airtight container", "serving dish", "serving platter", "cutting board",
        "food processor", "on the side", "all sides", "both sides", "each side", "per side",
        "other side", "rolling boil", "single layer", "even layer",
    ].map { $0.split(separator: " ").map(String.init) }.sorted { $0.count > $1.count }

    /// True for a word that, beside a food, can name a different prepared food or add an
    /// ingredient the list leaves out: fried onions are often battered, mashed potatoes hold butter
    /// and milk, baked beans hold pork and sugar, seasoned salt is a blend.
    static func canChangeFood(_ word: String) -> Bool {
        foodChanging.contains(word)
    }

    /// True for a word that can sit in a run of words describing a food, so a food-changing word
    /// at one end of the run still applies to the food at the other: "fried, warm golden onions".
    static func continuesDescription(_ word: String) -> Bool {
        descriptors.contains(word) || foodChanging.contains(word) || conjunctions.contains(word)
    }

    /// True for a determiner that introduces something new, so a generic word after it ("a
    /// sauce") is not taken to mean the listed one.
    static func introducesNew(_ word: String) -> Bool {
        newReferences.contains(word)
    }

    /// True for a determiner. A describing word after one must go on to the thing it describes,
    /// since alone it stands for an unnamed food: "top with the grated", "serve with the hot".
    static func isDeterminer(_ word: String) -> Bool {
        determiners.contains(word)
    }

    /// True for a whole number, in digits or words. Alone it can stand for an unnamed food ("crack 2
    /// into the bowl"), so it must go on to what it counts.
    static func isCount(_ word: String) -> Bool {
        word.allSatisfy(\.isNumber) || counts.contains(word)
    }

    /// True for a vocabulary word other than a function word, such as "pan", "heat" or "minutes",
    /// that a describing word or a count may describe.
    static func isContentWord(_ word: String) -> Bool {
        (contains(word) && !functionWordSet.contains(word)) || measures.contains(word)
    }

    static let foodChanging: Set<String> = [
        "fried", "crispy", "crunchy", "baked", "seasoned", "hot", "brown", "mashed", "roasted",
        "coated", "creamed", "creamy", "toasted", "breaded", "battered", "buttered", "glazed",
        "stuffed", "smoked", "marinated", "candied", "sauced", "dressed", "spiced", "blackened",
        "mixed", "blended", "braised", "caramelized", "caramelised", "sweetened", "honeyed",
        "sugared", "salted", "cured", "pickled", "loaded", "topped", "filled", "smothered",
        "flavored", "flavoured", "infused", "refried", "crumbed", "crusted", "deviled", "devilled",
        "scalloped", "whipped", "frosted", "iced", "dusted", "floured", "barbecued", "bbq",
        "curried", "jerk",
    ]

    private static let conjunctions: Set<String> = ["and", "or", "nor", "but", "also", "very", "too", "not", "so"]

    private static let newReferences: Set<String> = ["a", "an", "another", "other", "some", "any", "more"]

    private static let determiners: Set<String> = [
        "the", "a", "an", "some", "any", "your", "this", "that", "these", "those", "each", "every", "their",
        "its", "our", "another", "other",
    ]

    static let words = wordSet(functionWords, numbers, sizes, equipment, methods, descriptorWords, qualities, time)
    static let measures = wordSet(measureWords)
    private static let descriptors = wordSet(descriptorWords)
    private static let counts = wordSet([countWords])
    private static let functionWordSet = wordSet(functionWords)

    private static func wordSet(_ groups: [String]...) -> Set<String> {
        Set(groups.joined().flatMap { $0.split(separator: " ").map(String.init) })
    }

    private static let shapes: Set<String> = [
        "piece", "pieces", "slice", "slices", "cube", "cubes", "chunk", "chunks", "strip", "strips",
        "wedge", "wedges", "round", "rounds", "ring", "rings", "dice", "floret", "florets", "half",
        "halves", "quarter", "quarters", "third", "thirds", "portion", "portions", "serving",
        "servings", "matchstick", "matchsticks", "ribbon", "ribbons", "segment", "segments",
    ]

    private static let shapeSizes: Set<String> = [
        "inch", "inches", "cm", "mm", "bite", "size", "sized", "thin", "thick", "small", "large",
        "medium", "even", "equal", "evenly", "roughly", "about", "approximately",
    ]

    private static let functionWords = [
        "a an the and or but nor of to in into on onto at by for from with without over under",
        "until till about around through throughout across between along off out up down then than",
        "as so if when while once after before again also just only very too more most less much",
        "many few little some any all each every both either other another remaining it its them",
        "they their this that these those there here you your we our i is are be been being was",
        "were will would could should may might do does don t s not no now still already well even",
        "together apart aside away back how what which who per via where whichever enough",
    ]

    private static let countWords = "one two three four five six seven eight nine ten eleven twelve fifteen twenty thirty forty fifty sixty"

    private static let numbers = [
        countWords, "half halves halfway third thirds quarter quarters first second next last final finally",
    ]

    private static let sizes = [
        "inch inches cm mm degree degrees f size sized amount quantity batch batches portion",
        "portions serving servings",
    ]

    private static let measureWords = [
        "cup cups tablespoon tablespoons tbsp tbsps tbs teaspoon teaspoons tsp tsps ounce ounces oz",
        "pound pounds lb lbs gram grams g kg kilogram kilograms ml milliliter milliliters millilitre",
        "millilitres l liter liters litre litres c quart quarts pint pints gallon gallons pinch",
        "pinches dash dashes splash splashes knob knobs handful handfuls spoonful spoonfuls scoop",
        "scoops piece pieces slice slices cube cubes chunk chunks clove cloves can cans tin tins jar",
        "jars bottle bottles packet packets package packages bag bags box boxes carton cartons",
        "container containers sheet sheets layer layers drizzle dollop dollops pat pats stick",
        "sticks sprig sprigs bunch bunches head heads stalk stalks rack racks ladle ladles bite",
        "bites drop drops squeeze zest swirl sprinkle skewer skewers wedge wedges strip strips round",
        "rounds ring rings floret florets segment segments dozen",
    ]

    private static let equipment = [
        "pan pans pot pots saucepan saucepans skillet skillets wok oven ovens stove stovetop burner",
        "grill grills broiler microwave bowl bowls plate plates platter platters tray trays lid lids",
        "foil parchment towel towels knife knives cutting spoon spoons spatula tongs whisk blender",
        "processor colander sieve strainer fridge refrigerator freezer surface edge edges center",
        "centre top bottom middle mixture",
    ]

    private static let methods = [
        "add adjust arrange beat blanch boil bring brown brush chill coat combine cook cool cover",
        "crack cut deglaze dice discard dissolve divide drain dust enjoy finish flip fold grate grill",
        "halve heat keep knead lay leave let lift lower make marinate measure melt moisten pile place",
        "plate poach pour preheat prepare press reduce refrigerate reheat remove repeat rest return",
        "rinse saute sauté scatter scrape sear season separate serve set shred sift simmer smash soak",
        "soften steam stir store strain taste tear thicken toss transfer trim turn uncover wash warm",
        "whisk wilt wipe use start begin continue allow check watch wait become becomes look looks",
        "appear reserve save shape form fill stack open close blacken get go need",
    ]

    /// Adjectives, participles and adverbs that describe a food or how it is cooked.
    private static let descriptorWords = [
        "golden soft crispy crunchy smooth thick thin fragrant aromatic translucent opaque bubbling",
        "bubbly hot warm cold cool ready done raw firm dry wet moist light deep shallow large small",
        "medium high low fine finely roughly coarse coarsely thinly halved combined desired fresh",
        "freshly diced grated ripe boneless skinless organic optional optionally evenly gently slowly quickly",
        "carefully lightly thoroughly completely occasionally frequently constantly briefly",
        "immediately added adding baked boiling boiled browned chilled coated cooked cooking cooled",
        "covered fried grilled heated mashed melted mixed placed poached poured preheated pressed",
        "reduced removed rested rinsed roasted sauteed sautéed seared seasoned served simmering",
        "simmered softened steamed stirred stirring thickened toasted tossed turning warmed whisked wilted",
        "using reserved needed blended braised quick easy simple weeknight everyday classic homemade",
        "rustic healthy speedy",
    ]

    private static let qualities = ["room temperature consistency texture color colour aroma preference style"]

    private static let time = [
        "overnight day days ahead later meanwhile minute minutes min mins hour hours hr hrs time",
        "times total approximately instantly",
    ]

}
