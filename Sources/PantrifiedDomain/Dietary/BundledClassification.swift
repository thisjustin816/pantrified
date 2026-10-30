import Foundation

extension ClassificationDataset {
    /// The classification data shipped with the app. Changes ship in reviewed releases with a new
    /// version. Limits are in docs/dietary-validation.md.
    public static let bundled = ClassificationDataset(
        provenance: ClassificationProvenance(
            source: "Pantrified curated seed. Allergen groups follow the U.S. major food allergens plus molluscs. Entries describe the plain, typical form of each food from general culinary composition, not any product label.",
            version: "2",
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
    ClassificationEntry("water", synonyms: ["cold water", "warm water", "hot water", "ice water"]),

    // Grains, legumes, starches. Dried pulses and grains can carry stray wheat or barley from
    // shared fields and handling, as oats do; rice and cornstarch are not known for it.
    ClassificationEntry("rice", synonyms: ["white rice", "brown rice", "cooked rice"]),
    ClassificationEntry("quinoa", mayContain: [.gluten, .wheat]),
    ClassificationEntry("black bean", mayContain: [.gluten, .wheat]),
    ClassificationEntry("kidney bean", mayContain: [.gluten, .wheat]),
    ClassificationEntry("chickpea", synonyms: ["garbanzo bean"], mayContain: [.gluten, .wheat]),
    ClassificationEntry("lentil", mayContain: [.gluten, .wheat]),
    ClassificationEntry("soybean", synonyms: ["soy", "soya", "soy bean", "edamame"], contains: [.soy], mayContain: [.gluten, .wheat]),
    ClassificationEntry("cornstarch"),
    ClassificationEntry("flour", synonyms: ["all purpose flour", "wheat flour"], contains: [.wheat, .gluten]),
    ClassificationEntry("barley", contains: [.gluten], mayContain: [.wheat]),
    ClassificationEntry("rye", contains: [.gluten], mayContain: [.wheat]),
    ClassificationEntry("oat", synonyms: ["rolled oat", "oatmeal"], mayContain: [.gluten, .wheat]),
    // Dried pasta is usually flour and water; egg pasta is common enough to need review.
    ClassificationEntry(
        "pasta", synonyms: ["spaghetti", "penne"], contains: [.wheat, .gluten], mayContain: [.egg], madeFrom: ["flour"]
    ),
    // Enriched and bakery breads vary widely: milk, egg, butter or lard, honey or sugar, seeds,
    // nut cross-contact, and L-cysteine from feathers as a dough conditioner.
    ClassificationEntry(
        "bread", contains: [.wheat, .gluten],
        mayContain: [.milk, .egg, .soy, .sesame, .treeNut, .peanut, .meat, .slaughterByproduct, .otherAnimalProduct],
        composite: true, madeFrom: ["flour"]
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
    // Cured and deli ham often has added milk or soy protein and starches.
    ClassificationEntry("ham", contains: [.meat], mayContain: [.milk, .soy, .wheat, .gluten], madeFrom: ["pork"]),
    ClassificationEntry("lard", contains: [.meat], madeFrom: ["pork"]),
    // Pork is the typical meat; any other still needs review as a composite. Binders include egg,
    // milk and breadcrumbs, and some sausages hold pistachios or other nuts.
    ClassificationEntry(
        "sausage", contains: [.meat], mayContain: [.milk, .egg, .wheat, .gluten, .soy, .treeNut, .slaughterByproduct],
        composite: true, madeFrom: ["pork"]
    ),
    ClassificationEntry("fish", synonyms: ["white fish", "whitefish"], contains: [.fish]),
    ClassificationEntry("salmon", contains: [.fish]),
    // Canned tuna is often packed in vegetable broth that contains soy.
    ClassificationEntry("tuna", contains: [.fish], mayContain: [.soy]),
    ClassificationEntry("cod", contains: [.fish]),
    ClassificationEntry("anchovy", contains: [.fish]),
    ClassificationEntry("shrimp", synonyms: ["prawn"], contains: [.crustaceanShellfish]),
    ClassificationEntry("crab", contains: [.crustaceanShellfish]),
    ClassificationEntry("lobster", contains: [.crustaceanShellfish]),
    ClassificationEntry("clam", contains: [.mollusc]),
    ClassificationEntry("mussel", contains: [.mollusc]),
    ClassificationEntry("oyster", contains: [.mollusc]),
    ClassificationEntry("scallop", contains: [.mollusc]),
    ClassificationEntry("squid", contains: [.mollusc]),
    // Either kind, or both; which one is unknown.
    ClassificationEntry("shellfish", mayContain: [.crustaceanShellfish, .mollusc], composite: true),
    ClassificationEntry("seafood", mayContain: [.fish, .crustaceanShellfish, .mollusc], composite: true),

    // Dairy and eggs. Cheese and cultured dairy may use animal rennet or gelatin, and some cheeses
    // use egg-white lysozyme.
    ClassificationEntry("milk", synonyms: ["whole milk", "skim milk"], contains: [.milk]),
    ClassificationEntry("dairy", contains: [.milk], composite: true, madeFrom: ["milk"]),
    ClassificationEntry("buttermilk", contains: [.milk], madeFrom: ["milk"]),
    ClassificationEntry("butter", synonyms: ["unsalted butter", "salted butter"], contains: [.milk], madeFrom: ["cream"]),
    ClassificationEntry("ghee", contains: [.milk], madeFrom: ["butter"]),
    ClassificationEntry("cream", synonyms: ["heavy cream", "whipping cream"], contains: [.milk], madeFrom: ["milk"]),
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
    ClassificationEntry("egg", synonyms: ["egg yolk", "egg white"], contains: [.egg]),

    // Nuts and seeds. Tree nuts and peanuts are commonly processed on shared equipment.
    ClassificationEntry("almond", contains: [.treeNut], mayContain: [.peanut]),
    ClassificationEntry("almond milk", contains: [.treeNut], mayContain: [.peanut], madeFrom: ["almond"]),
    ClassificationEntry("walnut", contains: [.treeNut], mayContain: [.peanut]),
    ClassificationEntry("cashew", contains: [.treeNut], mayContain: [.peanut]),
    ClassificationEntry("pecan", contains: [.treeNut], mayContain: [.peanut]),
    ClassificationEntry("pine nut", contains: [.treeNut], mayContain: [.peanut]),
    // Unqualified nuts are usually a mix of tree nuts, often with peanuts.
    ClassificationEntry("nut", synonyms: ["mixed nut"], contains: [.treeNut], mayContain: [.peanut], composite: true),
    ClassificationEntry("peanut", contains: [.peanut], mayContain: [.treeNut]),
    ClassificationEntry("peanut butter", contains: [.peanut], mayContain: [.treeNut], madeFrom: ["peanut"]),
    ClassificationEntry("sesame seed", synonyms: ["sesame"], contains: [.sesame]),
    ClassificationEntry("tahini", contains: [.sesame], madeFrom: ["sesame seed"]),
    ClassificationEntry("sesame oil", contains: [.sesame], madeFrom: ["sesame seed"]),

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
    ClassificationEntry("apple cider vinegar", synonyms: ["cider vinegar"], madeFrom: ["apple"]),
    // Unqualified vinegar may be malt vinegar.
    ClassificationEntry("vinegar", mayContain: [.gluten]),
    // Cane sugar may be refined with bone char.
    ClassificationEntry("sugar", synonyms: ["brown sugar", "granulated sugar"], mayContain: [.otherAnimalProduct]),
    // Some producers still defoam the sap with butter, cream or lard.
    ClassificationEntry("maple syrup", mayContain: [.milk, .meat]),
    ClassificationEntry("honey", contains: [.otherAnimalProduct]),
    // Usually pork or beef; fish gelatin also exists.
    ClassificationEntry("gelatin", contains: [.slaughterByproduct], mayContain: [.fish], madeFrom: ["pork", "beef"]),

    // Prepared foods that hide other foods. Commercial broths add flavorings, yeast extract and
    // starches that can carry most allergens.
    ClassificationEntry(
        "chicken broth", synonyms: ["chicken stock"], contains: [.meat],
        mayContain: [.milk, .egg, .wheat, .gluten, .soy, .treeNut, .peanut, .sesame], composite: true, madeFrom: ["chicken"]
    ),
    ClassificationEntry(
        "beef broth", synonyms: ["beef stock"], contains: [.meat],
        mayContain: [.milk, .egg, .wheat, .gluten, .soy, .treeNut, .peanut, .sesame], composite: true, madeFrom: ["beef"]
    ),
    ClassificationEntry(
        "vegetable broth", synonyms: ["vegetable stock"],
        mayContain: [.milk, .egg, .wheat, .gluten, .soy, .treeNut, .peanut, .sesame, .otherAnimalProduct], composite: true
    ),
    // Unqualified broth or bouillon may be made from any meat, fish or shellfish.
    ClassificationEntry("broth", synonyms: ["stock"], mayContain: everything, composite: true, genericTerm: true),
    ClassificationEntry("bouillon", synonyms: ["bouillon cube"], mayContain: everything, composite: true),
    ClassificationEntry("soy sauce", contains: [.soy, .wheat, .gluten], composite: true),
    ClassificationEntry("tamari", contains: [.soy], mayContain: [.wheat, .gluten], composite: true),
    // Some brands add hydrolyzed wheat protein.
    ClassificationEntry(
        "fish sauce", contains: [.fish], mayContain: [.crustaceanShellfish, .wheat, .gluten], composite: true,
        madeFrom: ["anchovy"]
    ),
    ClassificationEntry(
        "worcestershire sauce", synonyms: ["worcestershire"], contains: [.fish],
        mayContain: [.wheat, .gluten, .soy], composite: true, madeFrom: ["anchovy"]
    ),
    ClassificationEntry(
        "oyster sauce", contains: [.mollusc], mayContain: [.wheat, .gluten, .soy], composite: true, madeFrom: ["oyster"]
    ),
    ClassificationEntry(
        "pesto", contains: [.milk, .treeNut], mayContain: [.egg, .peanut, .slaughterByproduct], composite: true,
        madeFrom: ["basil", "parmesan", "pine nut", "olive oil", "garlic"]
    ),
    ClassificationEntry("mayonnaise", synonyms: ["mayo"], contains: [.egg], mayContain: [.soy], composite: true, madeFrom: ["egg"]),
    // Thai pastes use shrimp paste and fish sauce; Indian pastes may use cashew, almond, ghee,
    // sesame, or asafoetida cut with wheat flour.
    ClassificationEntry(
        "curry paste",
        mayContain: [
            .fish, .crustaceanShellfish, .mollusc, .milk, .wheat, .gluten, .soy, .peanut, .treeNut, .sesame, .otherAnimalProduct,
        ],
        composite: true
    ),
    ClassificationEntry(
        "dark chocolate", synonyms: ["chocolate", "chocolate chip"],
        mayContain: [.milk, .egg, .soy, .treeNut, .peanut, .wheat, .gluten, .sesame, .otherAnimalProduct],
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
