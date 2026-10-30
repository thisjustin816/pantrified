import Foundation

extension ClassificationDataset {
    /// The classification data shipped with the app. Changes ship in reviewed releases with a new
    /// version. Limits are in docs/dietary-validation.md.
    public static let bundled = ClassificationDataset(
        provenance: ClassificationProvenance(
            source: "Pantrified curated seed. Allergen groups follow the U.S. major food allergens plus molluscs. Entries describe the plain, typical form of each food from general culinary composition, not any product label.",
            version: "1",
            reviewed: "2026-10-30"
        ),
        coveredTraits: Set(DietaryTrait.allCases),
        entries: bundledEntries
    )
}

private let everything = Set(DietaryTrait.allCases)

private let bundledEntries: [ClassificationEntry] = [
    // Vegetables, fruit, herbs
    ClassificationEntry("onion", synonyms: ["yellow onion", "red onion", "white onion"]),
    ClassificationEntry("garlic", synonyms: ["garlic clove"]),
    ClassificationEntry("tomato", synonyms: ["crushed tomato", "canned tomato", "cherry tomato"]),
    ClassificationEntry("carrot"),
    ClassificationEntry("celery"),
    ClassificationEntry("potato"),
    ClassificationEntry("sweet potato"),
    ClassificationEntry("bell pepper", synonyms: ["red bell pepper", "green bell pepper"]),
    ClassificationEntry("spinach", synonyms: ["baby spinach"]),
    ClassificationEntry("broccoli", synonyms: ["broccoli floret"]),
    ClassificationEntry("mushroom"),
    ClassificationEntry("zucchini"),
    ClassificationEntry("lemon"),
    ClassificationEntry("lemon juice", madeFrom: ["lemon"]),
    ClassificationEntry("lime"),
    ClassificationEntry("apple"),
    ClassificationEntry("banana"),
    ClassificationEntry("avocado"),
    ClassificationEntry("cilantro"),
    ClassificationEntry("basil"),
    ClassificationEntry("parsley"),

    // Grains, legumes, starches
    ClassificationEntry("rice", synonyms: ["white rice", "brown rice", "cooked rice"]),
    ClassificationEntry("quinoa"),
    ClassificationEntry("black bean"),
    ClassificationEntry("kidney bean"),
    ClassificationEntry("chickpea", synonyms: ["garbanzo bean"]),
    ClassificationEntry("lentil"),
    ClassificationEntry("cornstarch"),
    ClassificationEntry("flour", synonyms: ["all purpose flour", "wheat flour"], contains: [.wheat, .gluten]),
    ClassificationEntry("barley", contains: [.gluten]),
    ClassificationEntry("rye", contains: [.gluten]),
    // Oats are gluten-free by nature but commonly cross-contacted with wheat.
    ClassificationEntry("oat", synonyms: ["rolled oat", "oatmeal"], mayContain: [.gluten, .wheat]),
    // Dried pasta is usually flour and water; egg pasta is common enough to need review.
    ClassificationEntry(
        "pasta", synonyms: ["spaghetti", "penne"], contains: [.wheat, .gluten], mayContain: [.egg], madeFrom: ["flour"]
    ),
    ClassificationEntry(
        "bread", contains: [.wheat, .gluten], mayContain: [.milk, .egg, .soy, .sesame], composite: true, madeFrom: ["flour"]
    ),
    ClassificationEntry("corn tortilla", mayContain: [.wheat, .gluten]),
    ClassificationEntry("tofu", contains: [.soy], madeFrom: ["soy milk"]),
    ClassificationEntry("soy milk", contains: [.soy]),

    // Meat, fish, shellfish
    ClassificationEntry("chicken", synonyms: ["chicken breast", "chicken thigh"], contains: [.meat]),
    ClassificationEntry("turkey", contains: [.meat]),
    ClassificationEntry("beef", synonyms: ["ground beef", "steak"], contains: [.meat]),
    ClassificationEntry("pork", synonyms: ["pork chop", "pork loin"], contains: [.meat]),
    ClassificationEntry("bacon", contains: [.meat], madeFrom: ["pork"]),
    ClassificationEntry("ham", contains: [.meat], madeFrom: ["pork"]),
    ClassificationEntry("lard", contains: [.meat], madeFrom: ["pork"]),
    // Pork is the typical meat; any other still needs review as a composite.
    ClassificationEntry(
        "sausage", contains: [.meat], mayContain: [.milk, .wheat, .gluten, .soy, .slaughterByproduct], composite: true,
        madeFrom: ["pork"]
    ),
    ClassificationEntry("salmon", contains: [.fish]),
    ClassificationEntry("tuna", contains: [.fish]),
    ClassificationEntry("cod", contains: [.fish]),
    ClassificationEntry("anchovy", contains: [.fish]),
    ClassificationEntry("shrimp", synonyms: ["prawn"], contains: [.crustaceanShellfish]),
    ClassificationEntry("crab", contains: [.crustaceanShellfish]),
    ClassificationEntry("lobster", contains: [.crustaceanShellfish]),
    ClassificationEntry("clam", contains: [.mollusc]),
    ClassificationEntry("mussel", contains: [.mollusc]),
    ClassificationEntry("scallop", contains: [.mollusc]),
    ClassificationEntry("squid", contains: [.mollusc]),

    // Dairy and eggs. Cheese and cultured dairy may use animal rennet or gelatin.
    ClassificationEntry("milk", synonyms: ["whole milk", "skim milk"], contains: [.milk]),
    ClassificationEntry("buttermilk", contains: [.milk], madeFrom: ["milk"]),
    ClassificationEntry("butter", synonyms: ["unsalted butter", "salted butter"], contains: [.milk], madeFrom: ["cream"]),
    ClassificationEntry("ghee", contains: [.milk], madeFrom: ["butter"]),
    ClassificationEntry("cream", synonyms: ["heavy cream", "whipping cream"], contains: [.milk], madeFrom: ["milk"]),
    ClassificationEntry("sour cream", contains: [.milk], mayContain: [.slaughterByproduct], madeFrom: ["cream"]),
    ClassificationEntry(
        "yogurt", synonyms: ["greek yogurt", "plain yogurt"], contains: [.milk], mayContain: [.slaughterByproduct],
        madeFrom: ["milk"]
    ),
    ClassificationEntry("cheese", contains: [.milk], mayContain: [.slaughterByproduct], madeFrom: ["milk"]),
    ClassificationEntry(
        "cheddar", synonyms: ["cheddar cheese"], contains: [.milk], mayContain: [.slaughterByproduct], madeFrom: ["milk"]
    ),
    ClassificationEntry(
        "mozzarella", synonyms: ["mozzarella cheese"], contains: [.milk], mayContain: [.slaughterByproduct], madeFrom: ["milk"]
    ),
    ClassificationEntry(
        "parmesan", synonyms: ["parmesan cheese"], contains: [.milk], mayContain: [.slaughterByproduct], madeFrom: ["milk"]
    ),
    ClassificationEntry("egg", synonyms: ["egg yolk", "egg white"], contains: [.egg]),

    // Nuts and seeds
    ClassificationEntry("almond", contains: [.treeNut]),
    ClassificationEntry("almond milk", contains: [.treeNut], madeFrom: ["almond"]),
    ClassificationEntry("walnut", contains: [.treeNut]),
    ClassificationEntry("cashew", contains: [.treeNut]),
    ClassificationEntry("pecan", contains: [.treeNut]),
    ClassificationEntry("pine nut", contains: [.treeNut]),
    ClassificationEntry("peanut", contains: [.peanut]),
    ClassificationEntry("peanut butter", contains: [.peanut], mayContain: [.treeNut], madeFrom: ["peanut"]),
    ClassificationEntry("sesame seed", contains: [.sesame]),
    ClassificationEntry("tahini", contains: [.sesame], madeFrom: ["sesame seed"]),
    ClassificationEntry("sesame oil", contains: [.sesame], madeFrom: ["sesame seed"]),

    // Oils, seasonings, sweeteners
    ClassificationEntry("olive oil", synonyms: ["extra virgin olive oil"]),
    ClassificationEntry("canola oil"),
    // Usually soybean oil.
    ClassificationEntry("vegetable oil", mayContain: [.soy]),
    ClassificationEntry("salt", synonyms: ["kosher salt", "sea salt"]),
    ClassificationEntry("black pepper", synonyms: ["ground black pepper"]),
    // Unqualified, any of black, white, bell or chili pepper. None has a covered trait, and an
    // exclusion of a specific pepper reads this as possibly that pepper.
    ClassificationEntry("pepper"),
    ClassificationEntry("cumin", synonyms: ["ground cumin"]),
    // Ground dried sweet or chili pepper.
    ClassificationEntry("paprika", madeFrom: ["pepper"]),
    ClassificationEntry("baking soda"),
    // Some baking powders use wheat starch.
    ClassificationEntry("baking powder", mayContain: [.wheat, .gluten]),
    ClassificationEntry("white vinegar", synonyms: ["distilled vinegar"]),
    ClassificationEntry("apple cider vinegar", synonyms: ["cider vinegar"], madeFrom: ["apple"]),
    // Unqualified vinegar may be malt vinegar.
    ClassificationEntry("vinegar", mayContain: [.gluten]),
    // Cane sugar may be refined with bone char.
    ClassificationEntry("sugar", synonyms: ["brown sugar", "granulated sugar"], mayContain: [.otherAnimalProduct]),
    ClassificationEntry("maple syrup"),
    ClassificationEntry("honey", contains: [.otherAnimalProduct]),
    ClassificationEntry("gelatin", contains: [.slaughterByproduct], madeFrom: ["pork", "beef"]),

    // Prepared foods that hide other foods
    ClassificationEntry(
        "chicken broth", synonyms: ["chicken stock"], contains: [.meat],
        mayContain: [.milk, .wheat, .gluten, .soy], composite: true, madeFrom: ["chicken"]
    ),
    ClassificationEntry(
        "beef broth", synonyms: ["beef stock"], contains: [.meat],
        mayContain: [.milk, .wheat, .gluten, .soy], composite: true, madeFrom: ["beef"]
    ),
    ClassificationEntry(
        "vegetable broth", synonyms: ["vegetable stock"], mayContain: [.milk, .wheat, .gluten, .soy], composite: true
    ),
    ClassificationEntry(
        "broth", synonyms: ["stock"],
        mayContain: [.meat, .fish, .crustaceanShellfish, .mollusc, .milk, .wheat, .gluten, .soy],
        composite: true, genericTerm: true
    ),
    ClassificationEntry(
        "bouillon", synonyms: ["bouillon cube"],
        mayContain: [.meat, .fish, .milk, .egg, .wheat, .gluten, .soy], composite: true
    ),
    ClassificationEntry("soy sauce", contains: [.soy, .wheat, .gluten], composite: true),
    ClassificationEntry("tamari", contains: [.soy], mayContain: [.wheat, .gluten], composite: true),
    ClassificationEntry("fish sauce", contains: [.fish], mayContain: [.crustaceanShellfish], composite: true, madeFrom: ["anchovy"]),
    ClassificationEntry(
        "worcestershire sauce", synonyms: ["worcestershire"], contains: [.fish],
        mayContain: [.wheat, .gluten], composite: true, madeFrom: ["anchovy"]
    ),
    ClassificationEntry("oyster sauce", contains: [.mollusc], mayContain: [.wheat, .gluten, .soy], composite: true),
    ClassificationEntry(
        "pesto", contains: [.milk, .treeNut], mayContain: [.slaughterByproduct], composite: true,
        madeFrom: ["basil", "parmesan", "pine nut", "olive oil", "garlic"]
    ),
    ClassificationEntry("mayonnaise", synonyms: ["mayo"], contains: [.egg], mayContain: [.soy], composite: true, madeFrom: ["egg"]),
    ClassificationEntry(
        "curry paste",
        mayContain: [.fish, .crustaceanShellfish, .milk, .wheat, .gluten, .soy, .peanut], composite: true
    ),
    ClassificationEntry(
        "dark chocolate", synonyms: ["chocolate", "chocolate chip"], mayContain: [.milk, .soy, .treeNut, .peanut],
        composite: true, madeFrom: ["sugar"]
    ),
    ClassificationEntry(
        "natural flavor", synonyms: ["natural flavoring", "flavoring", "artificial flavor"],
        mayContain: everything, composite: true, genericTerm: true
    ),
    ClassificationEntry(
        "seasoning", synonyms: ["seasoning blend", "spice blend", "spice mix"],
        mayContain: everything, composite: true, genericTerm: true
    ),
    ClassificationEntry("sauce", mayContain: everything, composite: true, genericTerm: true),
]
