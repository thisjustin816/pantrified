# Pantrified Dietary Validation

How Pantrified decides whether a recipe suits the people eating it. Code: `Sources/PantrifiedDomain/Dietary/` (restrictions, classification data, cooking vocabulary, validator), `Sources/PantrifiedDomain/MakeSomethingContext.swift`, and `Sources/PantrifiedApplication/MakeSomething.swift`. Verification is pure Swift tests on Linux; none of this has been compiled against the iOS SDK.

## Principle

A wrong "safe" is worse than a spurious "Needs review". A recipe is **safe** only when its ingredient list is complete and every ingredient is positively known not to break every active hard restriction. Anything unknown, ambiguous, or unparsed needs review. An ingredient positively known to break a restriction is a **violation**. No model takes part in validation, and provider dietary labels are never evidence.

## Restrictions and preferences

Hard restrictions (`DietaryRestriction`) and soft preferences (`DietaryPreferences`) are separate types. Preferences (likes, dislikes, spice tolerance) shape suggestions and generation and never change a verdict.

Each restriction forbids a set of traits (`DietaryTrait`):

| Restriction | Forbidden traits |
|---|---|
| Allergen: milk, egg, fish, crustacean shellfish, mollusc, tree nut, peanut, wheat, soy, sesame | The matching trait |
| Vegetarian | meat, fish, crustacean shellfish, mollusc, slaughter byproduct (gelatin, animal rennet) |
| Vegan | vegetarian traits plus milk, egg, other animal product (honey, bone char) |
| Gluten-free | gluten |
| Dairy-free | milk |
| Custom excluded food | None. Matched by food instead, as below |

### Custom exclusions

A custom exclusion names a food and carries an `ExclusionSeverity` the caller must choose; there is no default.

Both severities count a food as the excluded food, a violation, when:

- its name, or a synonym of it, contains the excluded food's name or one of its synonyms ("garbanzo beans" for an excluded chickpea);
- it is made from the excluded food, directly or through other foods (`madeFrom`: bacon from pork, pesto from milk through parmesan);
- the excluded food names a class the food belongs to (`category`: excluding fish excludes salmon, excluding meat excludes gelatin made from pork).

**Allergy or intolerance** (`allergyOrIntolerance`) is strict. These also need review:

- every known food, when the excluded food has no entry, since nothing can be shown not to be it (`exclusionUnverifiable`);
- a less specific name for the excluded food ("peppers" for bell pepper), a class name it may belong to ("white fish" for cod), or a food that may contain a trait the excluded food has (pasta, which may contain egg) (`mayBeExcluded`);
- a prepared food that could hide it (`compositeMayHideExclusion`);
- an advisory, unless it names only allergens the excluded food is known not to have.

Unknown foods, unparsed lines, notes and generated text are checked as for any restriction.

**Just avoid** (`justAvoid`) is matched by the three rules above in ingredient lines and in known foods the title and instructions name, and by name or synonym in unparsed lines, notes and advisories. A recipe that does not name the food passes. On its own it never makes a recipe need review for an unknown food, an unparsed line, a prepared food, a may-contain link or an unrecognized word.

## Classification data

`ClassificationDataset.bundled` is a curated seed, shipped in the app and versioned (`provenance.version`, currently 2). Every verdict records the data version it rests on.

- Each entry lists the traits a food `contains` and the traits it `mayContain` (recipe variation or cross-contact). Every entry is reviewed against every trait in `coveredTraits`, so a trait in neither list is one the food is known not to have. Where the review is unsure, the trait is marked may-contain.
- `coveredTraits` is listed by hand. A test fails when `DietaryTrait` has a case that is not in it, so a new trait is unknown for every food until each entry has been reviewed for it.
- A restriction whose traits fall outside `coveredTraits` can never pass.
- `isExhaustive` is always false. A food without an entry is unknown, and unknown always needs review.
- Lookup is exact on the normalized name or a listed synonym. "Peanut sauce" is not "peanut", and "low-sodium chicken broth" is not "chicken broth".
- Entries describe the plain, typical form of a food from general culinary composition, not any product label.
- `isComposite` marks prepared foods made of other foods, and names that could be any of several foods ("nuts", "seafood").
- `madeFrom` lists what a food is made from. Tests check that every link resolves to an entry, that every food containing milk, egg, peanut, sesame, wheat or soy is linked to it, and that a food carries every trait of the foods it is made from.
- `category` marks a name that is also a class of foods (milk, dairy, egg, nut, peanut, sesame, fish, shellfish, seafood, meat, soy, wheat, gluten) by the traits its members have.
- `isGenericTerm` marks words such as "sauce", "broth" and "oil" that in instructions usually refer to a listed food.
- Changes ship in reviewed releases with a new version.

## Verdicts

`DietaryValidator.assess` returns one of:

| Verdict | When |
|---|---|
| `noRestrictions` | No hard restriction applies. There is nothing to label. |
| `violation` | Some ingredient is known to break a restriction. Remaining doubts are kept alongside. |
| `needsReview` | No known violation, but at least one reason below. |
| `safe` | None of the above. |

Needs review reasons (`ReviewReason.Kind`), each exercised by the test corpus:

| Reason | Cause |
|---|---|
| `emptyIngredientList` | No ingredient lines |
| `incompleteIngredientList` | The source does not state the list is complete |
| `unparsedLine` | The line cannot be accounted for word by word |
| `unknownIngredient` | No entry for the food |
| `mayContain` | The food may have a forbidden trait |
| `advisoryStatement` | "May contain", "traces of", "processed in a facility" and similar text that concerns the restriction (see below) |
| `unrecognizedNote` | A parenthetical that is neither a quantity nor an advisory, such as "(such as malt)" |
| `alternativesDisagree` | "X or Y" where not every choice passes |
| `traitNotCovered` | The data was not reviewed for a trait the restriction needs |
| `exclusionUnverifiable` | A strictly excluded food the data does not know, so no other food can be shown not to be it |
| `compositeMayHideExclusion` | A prepared food that could contain a strictly excluded food |
| `mayBeExcluded` | A food that may be the strictly excluded food: a less specific name, a class it may belong to, or a may-contain trait it has |
| `mentionedButNotListed` | The title or instructions use a food the list leaves out that would change the verdict |
| `unrecognizedWord` | Generated text uses a word that is not a listed food, a known food, or cooking vocabulary |

## Hidden ingredients

- **Prepared foods**: broth and stock, bouillon, soy sauce (wheat), tamari, Worcestershire sauce (anchovy), fish sauce, oyster sauce, pesto (cheese, pine nuts), mayonnaise, curry paste, chocolate, sausage, bread, toast and breadcrumbs are composite entries with the traits they contain or may contain.
- **Unqualified names**: "broth", "stock", "bouillon", "sauce", "seasoning", "spice blend" and "natural flavors" may contain any trait. "Oil" may be peanut, soy, sesame or nut oil, and "nuts" and "seafood" may be any of several foods.
- **Cross-contact and processing**: oats, lentils, beans, chickpeas, soybeans and quinoa may carry wheat or barley, and barley and rye may carry wheat; tree nuts and peanuts may carry each other; ground cumin and paprika have been recalled for undeclared peanut and almond; vegetable oil may be soybean or peanut oil; unqualified vinegar may be malt vinegar; baking powder may contain wheat starch; cane sugar may be refined with bone char; maple syrup may be defoamed with butter or lard; cheeses may use egg lysozyme; gelatin may be fish; bread may contain lard, honey or L-cysteine.
- **Advisories**: an advisory made only of recognized allergen words ("milk", "tree nuts", "shellfish", "gluten") and filler ("may contain traces of", "processed in a facility that also handles") concerns only the restrictions those allergens touch; "gluten" counts for a wheat allergy too. Any other word could name a food, so it concerns every restriction, and so does an advisory that names no allergen. Text after a marker in the line itself ("processed in butter") is kept whole as an advisory, so a food named there cannot narrow it. A just-avoid exclusion is concerned only by an advisory that names it.
- **Alternatives** ("butter or margarine") are a violation only if every choice violates, and safe only if every choice is safe.
- **Unlisted foods**: the title and instructions are scanned for known foods the list leaves out that would change the verdict had they been listed ("finish with a knob of butter", "Garlic shrimp rice"). A generic word counts unless a listed line contains it ("the sauce" passes when soy sauce is listed). The longest known name wins, so "peanut butter" is not read as "butter".

## Sourced and generated recipes

- **Sourced recipes** are labeled safe only when the provider adapter states the list is complete and the validator passes. Provider labels are carried for display and ignored. Their title and instructions are scanned for known foods only.
- **Generated recipes and adaptations** (`MakeSomething`) are validated against the request's own restrictions before presentation, with `RecipeOrigin.generated`. Only `safe` or `noRestrictions` results are presented; a violation or a needs-review result is withheld with its assessment so the app can explain or retry. The generated list is treated as complete only because generated text is checked word by word: every word of the title and instructions must be a known food, a listed food, or a word in `CookingVocabulary`, a closed list of words that do not name a food. Anything else, such as "ricotta" or "hazelnuts", withholds the recipe. A listed food may be called by its last word alone ("the beans" for black beans), but not by another of its words ("the kidneys"), and not after a cooking word that can make a different food ("baked beans", "fried onions", "seasoned salt", "hot sauce"). Words are compared as written, so "fries" is not the verb "fry". This check applies when some restriction relies on classification; a just-avoid exclusion alone does not trigger it.

## Make Something request context

`MakeSomethingContext` is the only data a generative request receives:

- selected foods: name, use-soon flag, approximate quantity
- diner count
- the selected diners' hard restrictions, combined
- the selected diners' preferences, combined: foods to avoid, foods some diner likes and none dislikes, the lowest spice tolerance

It has no field for identifiers, people's names, dates, locations, photos, evidence crops, unselected inventory, or history. `PrepareMakeSomething` reads only the selected packages, one at a time, and keeps those still active in the Space; it never lists the Space's inventory.

A context cannot be built for nobody (`MakeSomethingContextError.noDiners`), since an empty restriction set would read as "no restrictions" and the recipe would be presented unchecked. Decoding a context with a diner count below one fails too. A diner's restrictions are `ProfileRestrictions.known` (an empty set means the person has none) or `unknown`, and a context cannot be built for a diner whose restrictions are unknown (`restrictionsUnknown`). Consumer profiles and restrictions are not synchronized yet (see `sync-design.md`), so today every profile is local; `unknown` is for a profile whose restrictions have not reached this device.

Tests on the request:

- requests of both kinds, between them using every case of `MakeSomethingRequest`, `Quantity`, `DietaryRestriction` and `ExclusionSeverity`, produce exactly the expected field paths, and none of those fields has an identifier, date, URL or data type. The cases are named in exhaustive switches, so a new case stops the test compiling until it is handled;
- the fields holding free text are exactly the ones listed under Limits;
- an encoded request contains no diner name or id.

The tests check field names and types. They do not inspect what people typed.

## Limits

- The seed holds 129 foods (212 names with synonyms). Most real recipes contain something it does not know, so they need review until the data grows.
- Parsing is English only and narrow: leading quantities and common units, parenthetical quantities, "to taste", and comma suffixes made only of preparation words. Anything else is unparsed. Descriptors outside the shared normalization list ("low-sodium", "unsweetened") make a food unknown.
- Plain entries describe plain foods. A brined, injected, or flavored product is not distinguished from the plain food.
- Optional ingredients are checked like any other.
- Quantities are ignored; a trace amount and a cup are treated alike.
- The title and instruction scan works on words and can raise a spurious review, such as "butter the pan" for a dairy-free recipe that lists oil, or "toast the seeds" for a wheat allergy.
- For sourced recipes the scan finds only foods the data knows. "Chicken Satay" or "serve with crackers" passes the scan when the list is otherwise safe.
- The cooking vocabulary is English and deliberately small, so many sound generated recipes are withheld. A listed food's last word is accepted alone, so "serve with the beans" passes when black beans are listed even if the model meant another kind.
- Custom exclusions know only the names, synonyms, `madeFrom` links and classes in the data. A synonym the data lacks ("coriander" for "cilantro") is not matched. A just-avoid exclusion ignores may-contain links, advisories that do not name it, and prepared foods, by design.
- **Free text in a request.** These fields carry text as people typed it and are not filtered: inventory food names (`ingredients.name`), the recipe to adapt (`RecipeToAdapt.title` and `ingredientLines`), the unit of an exact quantity (`Quantity.exact`), custom exclusion names (`restrictions.excluded`), and the likes and dislikes typed for each diner (`preferences.avoid` and `preferences.favor`). A name that includes personal text, such as "Ana's birthday cake", reaches the model when that package is selected, and the same holds for any of these fields.
- No recipe discovery adapter exists yet. Sourced labeling is the validator called with the completeness the future adapter reports.
- Cross-contact is recorded only where the seed says so. A "safe" verdict reflects typical ingredients, not a specific product's manufacturing.

## Owner decisions

1. **Generated recipes that need review are withheld**, not shown with a Needs review label as sourced recipes are.
2. **Diners' needs are combined.** The request does not say how many diners have each restriction or preference.
3. **Restrictions are strict for allergens and for diets alike.** Anything that could plausibly breach a restriction needs review, so the cases below apply to every diner who has the restriction.
   - Animal rennet and gelatin count against vegetarian, so cheese, yogurt, and sour cream need review.
   - Processing aids count against vegan, so cane sugar needs review because of possible bone char.
   - Highly refined oils are not exempt, so vegetable oil needs review for a soy allergy.
   - Oats need review for gluten-free unless a future entry distinguishes certified gluten-free oats.
4. **Molluscs are a separate allergen**, and "shellfish" in a may-contain statement is read as both crustaceans and molluscs.
5. **A custom exclusion is either an allergy or intolerance, or just avoid**, as described under Custom exclusions. The caller must choose; nothing defaults to just avoid.

The following were not settled by the owner and were taken the conservative way, pending confirmation:

6. **Cross-contact in staples counts.** Dried pulses, soybeans and quinoa need review for gluten-free and wheat, and barley and rye for wheat, like oats. Bread needs review for vegetarians and vegans because of possible lard and L-cysteine, and maple syrup because of defoamers.
7. **Generated text is held to a closed vocabulary** rather than to structured steps that reference listed lines. A structured step still carries free text in which a model can name an unlisted food, so the word check would be needed either way.
8. **A just-avoid exclusion still needs review** for an incomplete or empty list and for an advisory that names the food.
9. **"Nuts" as an excluded class includes peanuts.**
10. **A diner whose restrictions this device does not have blocks the request** rather than being treated as having none.
