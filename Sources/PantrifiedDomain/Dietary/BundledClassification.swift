import Foundation

extension ClassificationDataset {
    /// The classification data shipped with the app. Changes ship in reviewed releases with a new
    /// version. Limits are in docs/dietary-validation.md.
    public static let bundled = ClassificationDataset(
        provenance: ClassificationProvenance(
            source: "Pantrified curated seed. Allergen groups follow the U.S. major food allergens plus molluscs. Entries describe the plain, typical form of each food from general culinary composition, not any product label.",
            version: "3",
            reviewed: "2026-10-30"
        ),
        // Listed by hand: a trait added to DietaryTrait is unknown for every food until each
        // entry has been reviewed for it.
        coveredTraits: [
            .milk, .egg, .fish, .crustaceanShellfish, .mollusc, .treeNut, .peanut, .wheat, .soy, .sesame,
            .gluten, .meat, .slaughterByproduct, .otherAnimalProduct,
        ],
        entries: bundledEntries
    )
}

private let everything = Set(DietaryTrait.allCases)

/// For a processed food whose usual commercial form lists natural flavors or flavorings: every
/// trait the food does not already have, as the natural flavor entry may contain.
private func anythingElse(than contains: Set<DietaryTrait>) -> Set<DietaryTrait> {
    everything.subtracting(contains)
}

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
    // Apples and citrus are often coated with shellac or beeswax.
    ClassificationEntry("lemon", mayContain: [.otherAnimalProduct]),
    ClassificationEntry("lemon juice", mayContain: [.otherAnimalProduct], madeFrom: ["lemon"]),
    ClassificationEntry("lime", mayContain: [.otherAnimalProduct]),
    ClassificationEntry("apple", mayContain: [.otherAnimalProduct]),
    ClassificationEntry("banana"),
    ClassificationEntry("avocado"),
    ClassificationEntry("cilantro", synonyms: ["coriander", "coriander leaves", "cilantro leaves"]),
    ClassificationEntry("basil"),
    ClassificationEntry("parsley"),
    ClassificationEntry("water", synonyms: ["cold water", "warm water", "hot water", "ice water"]),

    // Grains, legumes, starches. Dried pulses and grains can carry stray wheat or barley from
    // shared fields and handling, as oats do; rice and cornstarch are not known for it.
    ClassificationEntry("rice", synonyms: ["white rice", "brown rice", "cooked rice"]),
    ClassificationEntry("quinoa", mayContain: [.gluten, .wheat]),
    ClassificationEntry("black bean", mayContain: [.gluten, .wheat]),
    ClassificationEntry("kidney bean", mayContain: [.gluten, .wheat]),
    ClassificationEntry("chickpea", synonyms: ["garbanzo bean"], mayContain: [.gluten, .wheat]),
    ClassificationEntry("lentil", mayContain: [.gluten, .wheat]),
    ClassificationEntry("soybean", synonyms: ["soy bean", "soya bean", "edamame"], contains: [.soy], mayContain: [.gluten, .wheat]),
    // Alone, "soy" may mean soy sauce.
    ClassificationEntry(
        "soy", synonyms: ["soya"], contains: [.soy], mayContain: [.gluten, .wheat, .otherAnimalProduct], madeFrom: ["soybean"],
        category: [.soy]
    ),
    ClassificationEntry("wheat", synonyms: ["wheat berry"], contains: [.wheat, .gluten], category: [.wheat]),
    ClassificationEntry(
        "gluten", synonyms: ["vital wheat gluten"], contains: [.wheat, .gluten], madeFrom: ["wheat"], category: [.gluten]
    ),
    ClassificationEntry("cornstarch"),
    ClassificationEntry("flour", synonyms: ["all purpose flour", "wheat flour"], contains: [.wheat, .gluten], madeFrom: ["wheat"]),
    ClassificationEntry("barley", contains: [.gluten], mayContain: [.wheat]),
    ClassificationEntry("rye", contains: [.gluten], mayContain: [.wheat]),
    ClassificationEntry("oat", synonyms: ["rolled oat", "oatmeal"], mayContain: [.gluten, .wheat]),
    // Dried pasta is usually flour and water; egg pasta is common enough to need review.
    ClassificationEntry(
        "pasta", synonyms: ["spaghetti", "penne"], contains: [.wheat, .gluten], mayContain: [.egg], madeFrom: ["flour"]
    ),
    // Enriched and bakery breads vary widely: milk, egg, butter or lard, honey or sugar, seeds,
    // nut cross-contact, fish oil in omega-3 breads, and L-cysteine from feathers as a dough
    // conditioner.
    ClassificationEntry(
        "bread", contains: [.wheat, .gluten],
        mayContain: [.milk, .egg, .fish, .soy, .sesame, .treeNut, .peanut, .meat, .slaughterByproduct, .otherAnimalProduct],
        composite: true, madeFrom: ["flour"]
    ),
    ClassificationEntry(
        "toast", contains: [.wheat, .gluten],
        mayContain: [.milk, .egg, .fish, .soy, .sesame, .treeNut, .peanut, .meat, .slaughterByproduct, .otherAnimalProduct],
        composite: true, madeFrom: ["bread"]
    ),
    ClassificationEntry(
        "breadcrumb", synonyms: ["bread crumb", "panko", "panko breadcrumb"], contains: [.wheat, .gluten],
        mayContain: [.milk, .egg, .fish, .soy, .sesame, .treeNut, .peanut, .meat, .slaughterByproduct, .otherAnimalProduct],
        composite: true, madeFrom: ["bread"]
    ),
    ClassificationEntry("corn tortilla", mayContain: [.wheat, .gluten]),
    ClassificationEntry("tofu", contains: [.soy], mayContain: [.gluten, .wheat], madeFrom: ["soybean"]),
    // Packaged plant milks are usually sweetened with cane sugar, list natural flavors, add
    // vitamin D3 from lanolin, and are often made on dairy lines.
    ClassificationEntry(
        "soy milk", contains: [.soy], mayContain: anythingElse(than: [.soy]), madeFrom: ["soybean", "sugar", "natural flavor"]
    ),

    // Meat, fish, shellfish
    ClassificationEntry("chicken", synonyms: ["chicken breast", "chicken thigh"], contains: [.meat]),
    ClassificationEntry("turkey", contains: [.meat]),
    ClassificationEntry("beef", synonyms: ["ground beef", "steak"], contains: [.meat]),
    ClassificationEntry("pork", synonyms: ["pork chop", "pork loin"], contains: [.meat]),
    // Bacon and ham are cured with sugar. Cured and deli ham often has added milk or soy protein,
    // starches and flavorings.
    ClassificationEntry("bacon", contains: [.meat], mayContain: [.otherAnimalProduct], madeFrom: ["pork", "sugar"]),
    ClassificationEntry(
        "ham", contains: [.meat], mayContain: anythingElse(than: [.meat]), madeFrom: ["pork", "sugar", "natural flavor"]
    ),
    ClassificationEntry("lard", contains: [.meat], madeFrom: ["pork"]),
    // Pork is the typical meat; any other still needs review as a composite. Binders include egg,
    // milk and breadcrumbs, some sausages hold pistachios or other nuts, and most list flavorings.
    ClassificationEntry(
        "sausage", contains: [.meat], mayContain: anythingElse(than: [.meat]), composite: true,
        madeFrom: ["pork", "natural flavor"]
    ),
    ClassificationEntry("meat", contains: [.meat], category: [.meat]),
    ClassificationEntry("fish", synonyms: ["white fish", "whitefish"], contains: [.fish], category: [.fish]),
    ClassificationEntry("salmon", contains: [.fish]),
    // Canned tuna is often packed in vegetable broth, which may contain anything, and some brands
    // add casein.
    ClassificationEntry("tuna", contains: [.fish], mayContain: anythingElse(than: [.fish])),
    ClassificationEntry("cod", contains: [.fish]),
    // Often packed in vegetable oil, usually soybean.
    ClassificationEntry("anchovy", contains: [.fish], mayContain: [.soy]),
    ClassificationEntry("shrimp", synonyms: ["prawn"], contains: [.crustaceanShellfish]),
    // Recipes often mean imitation crab, made of fish with egg white, wheat starch and soy.
    ClassificationEntry("crab", contains: [.crustaceanShellfish], mayContain: [.fish, .egg, .wheat, .gluten, .soy]),
    ClassificationEntry("lobster", contains: [.crustaceanShellfish]),
    ClassificationEntry("clam", contains: [.mollusc]),
    ClassificationEntry("mussel", contains: [.mollusc]),
    ClassificationEntry("oyster", contains: [.mollusc]),
    ClassificationEntry("scallop", contains: [.mollusc]),
    ClassificationEntry("squid", contains: [.mollusc]),
    // Either kind, or both; which one is unknown.
    ClassificationEntry(
        "shellfish", mayContain: [.crustaceanShellfish, .mollusc], composite: true, category: [.crustaceanShellfish, .mollusc]
    ),
    ClassificationEntry(
        "crustacean", synonyms: ["crustacean shellfish"], contains: [.crustaceanShellfish], composite: true,
        category: [.crustaceanShellfish]
    ),
    ClassificationEntry("mollusc", synonyms: ["mollusk"], contains: [.mollusc], composite: true, category: [.mollusc]),
    ClassificationEntry(
        "seafood", mayContain: [.fish, .crustaceanShellfish, .mollusc], composite: true,
        category: [.fish, .crustaceanShellfish, .mollusc]
    ),

    // Dairy and eggs. Cheese and cultured dairy may use animal rennet or gelatin, and some cheeses
    // use egg-white lysozyme.
    ClassificationEntry("milk", synonyms: ["whole milk", "skim milk"], contains: [.milk], category: [.milk]),
    ClassificationEntry("dairy", contains: [.milk], composite: true, madeFrom: ["milk"], category: [.milk]),
    ClassificationEntry("buttermilk", contains: [.milk], madeFrom: ["milk"]),
    ClassificationEntry("butter", synonyms: ["unsalted butter", "salted butter"], contains: [.milk], madeFrom: ["cream"]),
    ClassificationEntry("ghee", contains: [.milk], madeFrom: ["butter"]),
    ClassificationEntry("cream", synonyms: ["heavy cream", "whipping cream"], contains: [.milk], madeFrom: ["milk"]),
    ClassificationEntry("half and half", synonyms: ["half half"], contains: [.milk], madeFrom: ["milk", "cream"]),
    ClassificationEntry("sour cream", contains: [.milk], mayContain: [.slaughterByproduct], madeFrom: ["cream"]),
    ClassificationEntry(
        "yogurt", synonyms: ["greek yogurt", "plain yogurt"], contains: [.milk], mayContain: [.slaughterByproduct],
        madeFrom: ["milk"]
    ),
    ClassificationEntry("cheese", contains: [.milk], mayContain: [.egg, .slaughterByproduct], madeFrom: ["milk"]),
    ClassificationEntry(
        "cheddar", synonyms: ["cheddar cheese"], contains: [.milk], mayContain: [.egg, .slaughterByproduct], madeFrom: ["milk"]
    ),
    ClassificationEntry(
        "mozzarella", synonyms: ["mozzarella cheese"], contains: [.milk], mayContain: [.egg, .slaughterByproduct],
        madeFrom: ["milk"]
    ),
    ClassificationEntry(
        "parmesan", synonyms: ["parmesan cheese"], contains: [.milk], mayContain: [.egg, .slaughterByproduct],
        madeFrom: ["milk"]
    ),
    ClassificationEntry("egg", synonyms: ["egg yolk", "egg white"], contains: [.egg], category: [.egg]),

    // Nuts and seeds. Tree nuts, peanuts and sesame are commonly processed on shared equipment.
    ClassificationEntry("almond", contains: [.treeNut], mayContain: [.peanut, .sesame]),
    ClassificationEntry(
        "almond milk", contains: [.treeNut], mayContain: anythingElse(than: [.treeNut]),
        madeFrom: ["almond", "sugar", "natural flavor"]
    ),
    ClassificationEntry("walnut", contains: [.treeNut], mayContain: [.peanut, .sesame]),
    ClassificationEntry("cashew", contains: [.treeNut], mayContain: [.peanut, .sesame]),
    ClassificationEntry("pecan", contains: [.treeNut], mayContain: [.peanut, .sesame]),
    ClassificationEntry("pine nut", contains: [.treeNut], mayContain: [.peanut, .sesame]),
    // Unqualified nuts are usually a mix of tree nuts, often with peanuts; as a class, people mean
    // both.
    ClassificationEntry(
        "nut", synonyms: ["mixed nut"], contains: [.treeNut], mayContain: [.peanut, .sesame], composite: true,
        category: [.treeNut, .peanut]
    ),
    ClassificationEntry(
        "tree nut", contains: [.treeNut], mayContain: [.peanut, .sesame], composite: true, category: [.treeNut]
    ),
    ClassificationEntry("peanut", contains: [.peanut], mayContain: [.treeNut, .sesame], category: [.peanut]),
    // Typical brands add sugar and hydrogenated vegetable oil, usually soybean.
    ClassificationEntry(
        "peanut butter", contains: [.peanut], mayContain: [.treeNut, .sesame, .soy, .otherAnimalProduct],
        madeFrom: ["peanut", "sugar", "vegetable oil"]
    ),
    ClassificationEntry(
        "sesame seed", synonyms: ["sesame"], contains: [.sesame], mayContain: [.peanut, .treeNut], category: [.sesame]
    ),
    ClassificationEntry("tahini", contains: [.sesame], mayContain: [.peanut, .treeNut], madeFrom: ["sesame seed"]),
    ClassificationEntry("sesame oil", contains: [.sesame], mayContain: [.peanut, .treeNut], madeFrom: ["sesame seed"]),

    // Oils, seasonings, sweeteners
    ClassificationEntry("olive oil", synonyms: ["extra virgin olive oil"]),
    ClassificationEntry("canola oil"),
    // Usually soybean oil, sometimes a blend that includes peanut oil.
    ClassificationEntry("vegetable oil", mayContain: [.soy, .peanut]),
    // Unqualified, any cooking oil the cook has.
    ClassificationEntry("oil", synonyms: ["cooking oil"], mayContain: [.soy, .peanut, .sesame, .treeNut], genericTerm: true),
    ClassificationEntry("salt", synonyms: ["kosher salt", "sea salt"]),
    ClassificationEntry("black pepper", synonyms: ["ground black pepper"]),
    // Unqualified, any of black, white, bell or chili pepper. None has a covered trait, and an
    // exclusion of a specific pepper reads this as possibly that pepper.
    ClassificationEntry("pepper"),
    // Ground cumin and paprika have been recalled for undeclared peanut and almond.
    ClassificationEntry("cumin", synonyms: ["ground cumin"], mayContain: [.peanut, .treeNut]),
    // Ground dried sweet or chili pepper.
    ClassificationEntry("paprika", mayContain: [.peanut, .treeNut], madeFrom: ["pepper"]),
    ClassificationEntry("baking soda"),
    // Some baking powders use wheat starch.
    ClassificationEntry("baking powder", mayContain: [.wheat, .gluten]),
    ClassificationEntry("white vinegar", synonyms: ["distilled vinegar"]),
    ClassificationEntry(
        "apple cider vinegar", synonyms: ["cider vinegar"], mayContain: [.otherAnimalProduct], madeFrom: ["apple"]
    ),
    // Unqualified vinegar may be malt vinegar, or spirit vinegar made from wheat.
    ClassificationEntry("vinegar", mayContain: [.gluten, .wheat]),
    // Cane sugar may be refined with bone char.
    ClassificationEntry("sugar", synonyms: ["brown sugar", "granulated sugar"], mayContain: [.otherAnimalProduct]),
    // Some producers still defoam the sap with butter, cream or lard.
    ClassificationEntry("maple syrup", mayContain: [.milk, .meat]),
    ClassificationEntry("honey", contains: [.otherAnimalProduct]),
    // Usually pork or beef; fish gelatin also exists.
    ClassificationEntry("gelatin", contains: [.slaughterByproduct], mayContain: [.fish], madeFrom: ["pork", "beef"]),

    // Prepared foods that hide other foods. Commercial broths add natural flavors, yeast extract
    // and starches, so they may contain anything natural flavors may.
    ClassificationEntry(
        "chicken broth", synonyms: ["chicken stock"], contains: [.meat], mayContain: anythingElse(than: [.meat]),
        composite: true, madeFrom: ["chicken", "natural flavor"]
    ),
    ClassificationEntry(
        "beef broth", synonyms: ["beef stock"], contains: [.meat], mayContain: anythingElse(than: [.meat]),
        composite: true, madeFrom: ["beef", "natural flavor"]
    ),
    ClassificationEntry(
        "vegetable broth", synonyms: ["vegetable stock"], mayContain: everything, composite: true, madeFrom: ["natural flavor"]
    ),
    // Unqualified broth or bouillon may be made from any meat, fish or shellfish.
    ClassificationEntry("broth", synonyms: ["stock"], mayContain: everything, composite: true, genericTerm: true),
    ClassificationEntry("bouillon", synonyms: ["bouillon cube"], mayContain: everything, composite: true),
    // Many soy sauces and other Asian sauces add sugar.
    ClassificationEntry(
        "soy sauce", contains: [.soy, .wheat, .gluten], mayContain: [.otherAnimalProduct], composite: true,
        madeFrom: ["soybean", "wheat"]
    ),
    ClassificationEntry("tamari", contains: [.soy], mayContain: [.wheat, .gluten], composite: true, madeFrom: ["soybean"]),
    // Some brands add hydrolyzed wheat or soy protein.
    ClassificationEntry(
        "fish sauce", contains: [.fish], mayContain: [.crustaceanShellfish, .wheat, .gluten, .soy, .otherAnimalProduct],
        composite: true, madeFrom: ["anchovy"]
    ),
    ClassificationEntry(
        "worcestershire sauce", synonyms: ["worcestershire"], contains: [.fish], mayContain: anythingElse(than: [.fish]),
        composite: true, madeFrom: ["anchovy", "natural flavor"]
    ),
    ClassificationEntry(
        "oyster sauce", contains: [.mollusc], mayContain: [.wheat, .gluten, .soy, .otherAnimalProduct], composite: true,
        madeFrom: ["oyster"]
    ),
    ClassificationEntry(
        "pesto", contains: [.milk, .treeNut], mayContain: [.egg, .peanut, .sesame, .slaughterByproduct], composite: true,
        madeFrom: ["basil", "parmesan", "pine nut", "olive oil", "garlic"]
    ),
    ClassificationEntry(
        "mayonnaise", synonyms: ["mayo"], contains: [.egg], mayContain: anythingElse(than: [.egg]), composite: true,
        madeFrom: ["egg", "natural flavor"]
    ),
    // Thai pastes use shrimp paste and fish sauce; Indian pastes may use cashew, almond, ghee,
    // sesame, or asafoetida cut with wheat flour.
    ClassificationEntry("curry paste", mayContain: everything, composite: true, madeFrom: ["natural flavor"]),
    ClassificationEntry(
        "dark chocolate", synonyms: ["chocolate", "chocolate chip"], mayContain: everything, composite: true,
        madeFrom: ["sugar", "natural flavor"]
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

    // Dishes named only with words that are cooking vocabulary on their own.
    ClassificationEntry(
        "soft serve", contains: [.milk], mayContain: anythingElse(than: [.milk]), composite: true, madeFrom: ["milk", "natural flavor"]
    ),
    ClassificationEntry("hot pot", mayContain: everything, composite: true),
    ClassificationEntry("mixed grill", contains: [.meat], mayContain: anythingElse(than: [.meat]), composite: true),
]
