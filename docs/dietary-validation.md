# Pantrified Dietary Validation

How Pantrified decides whether a recipe suits the people eating it. Code: `Sources/PantrifiedDomain/Dietary/` (restrictions, classification data, cooking vocabulary, recipe text, validator), `Sources/PantrifiedDomain/IngredientName.swift`, `Sources/PantrifiedDomain/MakeSomethingContext.swift`, and `Sources/PantrifiedApplication/MakeSomething.swift`. Verification is pure Swift tests on Linux; none of this has been compiled against the iOS SDK.

## Principle

A wrong "safe" is worse than a spurious "Needs review". A recipe is **safe** only when its ingredient list is complete and every ingredient is positively known not to break every active hard restriction. Anything unknown, ambiguous, or unparsed needs review. An ingredient positively known to break a restriction is a **violation**. No model takes part in validation, and provider dietary labels are never evidence.

## Restrictions and preferences

Hard restrictions (`DietaryRestriction`) and soft preferences (`DietaryPreferences`) are separate types. Preferences (likes, dislikes, spice tolerance) shape suggestions and generation and never change a verdict.

Each restriction forbids a set of traits (`DietaryTrait`):

| Restriction | Forbidden traits |
|---|---|
| Allergen: milk, egg, fish, crustacean shellfish, mollusc, tree nut, peanut, wheat, soy, sesame | The matching trait |
| Vegetarian | meat, fish, crustacean shellfish, mollusc, slaughter byproduct (gelatin, animal rennet) |
| Vegan | vegetarian traits plus milk, egg, other animal product (honey, bone char, shellac) |
| Gluten-free | gluten |
| Dairy-free | milk |
| Custom excluded food | None. Matched by food instead, as below |

The allergens a person can declare are the nine U.S. major food allergens plus molluscs. Mustard, celery, lupin and sulphites, which other regions regulate, cannot be declared as allergens: `Allergen` has no case for them and no food is reviewed for them. A person who must avoid one records it as a custom exclusion with the allergy or intolerance severity. The data has no entry for mustard, lupin or sulphites, so a strict exclusion of one makes every recipe need review. Celery has an entry with no covered traits, so a strict exclusion of celery reviews prepared foods that could hide it, such as broth, and passes other known foods.

### Custom exclusions

A custom exclusion names a food and carries an `ExclusionSeverity` the caller must choose; there is no default.

Both severities count a food as the excluded food, a violation, when:

- its name, or a synonym of it, contains the excluded food's name or one of its synonyms ("garbanzo beans" for an excluded chickpea);
- it is made from the excluded food, directly or through other foods (`madeFrom`: bacon from pork, pesto from milk through parmesan);
- the excluded food names a class the food belongs to (`category`: excluding fish excludes salmon, excluding meat excludes gelatin made from pork, excluding tree nuts excludes almonds).

**Allergy or intolerance** (`allergyOrIntolerance`) is strict. These also need review:

- every known food, when the excluded food has no entry, since nothing can be shown not to be it (`exclusionUnverifiable`). An unknown food needs review anyway, so a strict exclusion of a food the data does not know always makes the recipe need review;
- a food that may be the excluded food or set off the same reaction (`mayBeExcluded`): a less specific name for it ("peppers" for bell pepper), a class name it may belong to ("white fish" for cod), or a food that has or may have a trait the excluded food has or may have (crab for an excluded shrimp, walnuts for an excluded almond, chicken for an excluded pork, pasta for an excluded egg). Gelatin and rennet count as coming from meat here, so cheese needs review for an excluded beef;
- a prepared food that could hide it (`compositeMayHideExclusion`);
- an advisory, unless it names only allergens the excluded food is known not to have.

Unknown foods, unparsed lines, notes, titles and instructions are checked as for any restriction.

**Just avoid** (`justAvoid`) is matched by the three rules above in ingredient lines and in known foods the title and instructions name, and by name or synonym in unparsed lines, notes, advisories, titles and instructions. In text the excluded name is looked for anywhere, including inside a longer known food ("cream cheese" is found in "top with cream cheese" although "cream" is a known food) and across hyphens ("pea-nuts"). A recipe that does not name the food passes. On its own it never makes a recipe need review for an unknown food, an unparsed line, a prepared food, a shared or may-contain trait, or an unrecognized word.

## Classification data

`ClassificationDataset.bundled` is a curated seed, shipped in the app and versioned (`provenance.version`, currently 3). Every verdict records the data version it rests on.

- Each entry lists the traits a food `contains` and the traits it `mayContain` (recipe variation or cross-contact). Every entry is reviewed against every trait in `coveredTraits`, so a trait in neither list is one the food is known not to have. Where the review is unsure, the trait is marked may-contain.
- `coveredTraits` is listed by hand. A test fails when `DietaryTrait` has a case that is not in it, so a new trait is unknown for every food until each entry has been reviewed for it.
- A restriction whose traits fall outside `coveredTraits` can never pass.
- `isExhaustive` is always false. A food without an entry is unknown, and unknown always needs review.
- Lookup is exact on the normalized name or a listed synonym. "Peanut sauce" is not "peanut", and "low-sodium chicken broth" is not "chicken broth".
- Entries describe the typical form of a food from general culinary composition, not any product label. For a packaged food, typical means the usual commercial form: peanut butter with sugar and hydrogenated vegetable oil, sweetened plant milk.
- A processed food whose usual commercial form lists natural flavors or flavorings (broths, sausage, ham, mayonnaise, plant milks, Worcestershire sauce, chocolate, curry paste) is made from the `natural flavor` entry and may contain every trait natural flavors may: all of them.
- `isComposite` marks prepared foods made of other foods, and names that could be any of several foods ("nuts", "seafood").
- `madeFrom` lists what a food is made from. Tests check that every link resolves to an entry, that every food containing milk, egg, peanut, sesame, wheat or soy is linked to it, and that a food carries every trait of the foods it is made from.
- `category` marks a name that is also a class of foods (milk, dairy, egg, nut, tree nut, peanut, sesame, fish, shellfish, crustacean, mollusc, seafood, meat, soy, wheat, gluten) by the traits its members have.
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

Needs review reasons (`ReviewReason.Kind`). A test fails unless every reason is both expected by some case in the test corpus and produced by the validator when the corpus runs.

| Reason | Cause |
|---|---|
| `emptyIngredientList` | No ingredient lines |
| `incompleteIngredientList` | The source does not state the list is complete |
| `instructionsMissing` | No instructions, so what the cook will be told to use was not checked |
| `unparsedLine` | The line cannot be accounted for word by word |
| `unknownIngredient` | No entry for the food |
| `mayContain` | The food may have a forbidden trait |
| `advisoryStatement` | "May contain", "traces of", "processed in a facility" and similar text that concerns the restriction (see below) |
| `unrecognizedNote` | A parenthetical that is neither a quantity nor an advisory, such as "(such as malt)" |
| `alternativesDisagree` | "X or Y" where not every choice passes |
| `traitNotCovered` | The data was not reviewed for a trait the restriction needs |
| `exclusionUnverifiable` | A strictly excluded food the data does not know, so no other food can be shown not to be it |
| `compositeMayHideExclusion` | A prepared food that could contain a strictly excluded food |
| `mayBeExcluded` | A food that may be the strictly excluded food or share its trait (see Custom exclusions) |
| `mentionedButNotListed` | The title or instructions use a food the list leaves out that would change the verdict |
| `unrecognizedWord` | The title or instructions use a word that is not a listed food, a known food or cooking vocabulary, or a food-changing word beside a food (see below) |

## Text as displayed

Every recipe string (title, ingredient lines, instructions, and so the advisories inside lines) and every `IngredientName`, including custom exclusion names, is read without characters that display as nothing: format characters such as zero-width spaces, joiners, soft hyphens and byte order marks, other default-ignorable code points such as variation selectors and Hangul fillers, and control characters other than tabs and line breaks. They are removed rather than flagged, so the validator reads the word the person sees: "to\u{200B}as\u{200B}t" is "toast", not "to", "as", "t". Look-alike letters from other scripts (a Cyrillic "а" in "аlmonds") are not mapped; the word is unknown instead.

A decoded `IngredientName` is normalized again, as typed text would be, so a stored or synced name such as `{"words":["Cilantro"]}` matches cilantro. Normalizing a normalized name changes nothing, so existing stored names decode unchanged. A decoded `MealContextIngredient` name is trimmed as the initializer trims it.

## Hidden ingredients

- **Prepared foods**: broth and stock, bouillon, soy sauce (wheat), tamari, Worcestershire sauce (anchovy), fish sauce, oyster sauce, pesto (cheese, pine nuts), mayonnaise, curry paste, chocolate, sausage, bread, toast and breadcrumbs are composite entries with the traits they contain or may contain.
- **Unqualified names**: "broth", "stock", "bouillon", "sauce", "seasoning", "spice blend" and "natural flavors" may contain any trait. "Oil" may be peanut, soy, sesame or nut oil, and "nuts" and "seafood" may be any of several foods.
- **Cross-contact and processing**: oats, lentils, beans, chickpeas, soybeans and quinoa may carry wheat or barley, and barley and rye may carry wheat; tree nuts, peanuts and sesame may carry each other; ground cumin and paprika have been recalled for undeclared peanut and almond; vegetable oil may be soybean or peanut oil; unqualified vinegar may be malt or wheat vinegar; baking powder may contain wheat starch; cane sugar may be refined with bone char, so foods sweetened with it (peanut butter, plant milks, soy sauce, bacon) may carry it too; apples and citrus may be coated with shellac or beeswax; maple syrup may be defoamed with butter or lard; cheeses may use egg lysozyme; gelatin may be fish; bread may contain lard, honey, fish oil or L-cysteine; canned tuna may be packed in broth or with casein; anchovies may be packed in soybean oil; "crab" may be imitation crab made of fish, egg, wheat and soy.
- **Advisories**: an advisory made only of recognized allergen words ("milk", "tree nuts", "shellfish", "gluten") and filler ("may contain traces of", "processed in a facility that also handles") concerns only the restrictions those allergens touch; "gluten" counts for a wheat allergy too. Any other word could name a food, so it concerns every restriction, and so does an advisory that names no allergen. Text after a marker in the line itself ("processed in butter") is kept whole as an advisory, so a food named there cannot narrow it. A just-avoid exclusion is concerned only by an advisory that names it.
- **Alternatives** ("butter or margarine") are a violation only if every choice violates, and safe only if every choice is safe.
- **Unlisted foods**: the title and instructions are scanned for known foods the list leaves out that would change the verdict had they been listed ("finish with a knob of butter", "Garlic shrimp rice"). The longest known name wins, so "peanut butter" is not read as "butter", but a name never runs across punctuation, so "peanut, butter" is two foods. "&" reads as "and". A generic word counts as the listed one only when a listed line contains it and nothing right before it marks a different one: "the sauce" passes when soy sauce is listed, while "a sauce", "a dark sauce" and "peanut sauce" do not.

## The word scan

The title and instructions of every recipe, sourced or generated, are checked word by word whenever some restriction relies on classification (any restriction other than a just-avoid exclusion). Every word must be a listed food, a known food, or cooking vocabulary (`CookingVocabulary`); anything else, such as "ricotta", "hazelnuts", "satay" or a food emoji, needs review (`unrecognizedWord`).

- **The vocabulary holds no word that can name a food**, a dish, a product, or a portion or container that stands in for an unnamed food, even when its usual sense is a verb, a utensil or an adjective. "Wrap", "roast", "mash", "rub", "spread", "bake", "fry", "chop", "mince", "peel", "zest", "blend", "mix", "shake", "crisp", "tender", "skim", "whole", "dark", "double", "single", "side", "dish", "skin" and "flavor" are all left out, so "Bake for 20 minutes" or "Chop the onion" needs review. A test holds every vocabulary word, its singular and its stems against the classification data and a list of food nouns kept in the test, and fails on a match. A food-changing participle such as "toasted" may have a food stem, because every use of it beside a food is flagged.
- **Measures and containers** ("cup", "tbsp", "pinch", "knob", "splash", "slice", "can", "jar", "clove", "dozen") are accepted only where they measure a food named right after them, through "of", an article and describing words: "a knob of cold butter" passes the word check and the butter is then checked as a food, while "melt a knob in the pan" needs review. A test checks this for every measure. A shape after "into" ("cut into 1-inch pieces") is accepted.
- **Phrases** such as "baking sheet", "parchment paper", "cutting board" and "on the side" are accepted as a whole; their words alone ("baking", "sheet", "paper", "board", "side") are not.
- **Words standing in for a food**: a describing word right after a determiner must go on to what it describes ("the cooked rice", "a large pan"), so "top with the grated" needs review. A whole number must go on to what it counts ("2 cups", "20 minutes"), so "crack 2 into the bowl" needs review.
- **Food-changing words** ("fried", "baked", "mashed", "roasted", "toasted", "seasoned", "hot", "brown", "crispy", "breaded", "buttered", "glazed", "creamed", "smoked", "stuffed", "candied" and others that add an ingredient or name a different product) flag a food they describe, on either side and through any run of describing words, commas and "and": "fried golden onions", "fried, warm golden onions", "the potatoes, mashed".
- A listed food may be called by its last word alone ("the beans" for black beans), but not by another of its words ("the kidneys"). Words are compared as written, so "fries" is not the verb "fry".

## Sourced and generated recipes

`RecipeOrigin` does not change the verdict; both kinds get every check above. It decides what the app does with a recipe that needs review.

- **Sourced recipes** are labeled safe only when the provider adapter states the list is complete and the validator passes. Provider labels are carried for display and ignored. A sourced recipe that needs review is shown with a Needs review label. A sourced recipe that arrives without instructions needs review (`instructionsMissing`).
- **Generated recipes and adaptations** (`MakeSomething`) are validated against the request's own restrictions before presentation, with `RecipeOrigin.generated` and the list treated as complete. Only `safe` or `noRestrictions` results are presented; a violation or a needs-review result is withheld with its assessment so the app can explain or retry. The list is treated as complete only because the title and instructions pass the word scan.

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
- an encoded request contains no diner name or id;
- a decoded request equals the encoded one, with every restriction and severity, and names are normalized again.

The tests check field names and types. They do not inspect what people typed.

## Limits

- The seed holds 135 foods (224 names with synonyms). Most real recipes contain something it does not know, so they need review until the data grows.
- The word scan withholds most sound generated recipes and labels most sourced ones Needs review. In a sample of 20 plain recipes written only in listed foods and checked for a peanut allergy, 3 pass. Common steps such as "Bake for 20 minutes", "Chop the onion" and "Serve with lemon wedges" need review.
- The scan cannot tell what a pronoun or quantifier refers to. "Stir it in", "add the rest", "add some", "add half", "stir in the mixture" and "add the dry to the wet" pass, and would pass even if the food they mean was never named. "Pan" is accepted as the utensil although it is Spanish for bread.
- An advisory is read for the allergens it names, not for what those allergens may carry: "processed with peanuts" does not concern a tree nut allergy.
- Parsing is English only and narrow: leading quantities and common units, parenthetical quantities, "to taste", and comma suffixes made only of preparation words. Anything else is unparsed. Descriptors outside the shared normalization list ("low-sodium", "unsweetened") make a food unknown.
- Plain entries describe plain foods. A brined, injected, or flavored product (chicken injected with broth) is not distinguished from the plain food. Olive oil adulteration and spice cross-contact beyond cumin and paprika are not recorded.
- Optional ingredients are checked like any other.
- Quantities are ignored; a trace amount and a cup are treated alike.
- The title and instruction scan works on words and can raise a spurious review, such as "butter the pan" for a dairy-free recipe that lists oil, "toast the seeds" for a wheat allergy, or "serve the rice hot".
- The cooking vocabulary is English. A listed food's last word is accepted alone, so "serve with the beans" passes when black beans are listed even if the model meant another kind.
- Custom exclusions know only the names, synonyms, `madeFrom` links and classes in the data. A name the data lacks ("poultry", "nightshades") is matched only as written, so a just-avoid exclusion of poultry does not catch chicken, and a look-alike letter in a line ("mіlk" with a Cyrillic "і") is not matched. A just-avoid exclusion ignores may-contain links, shared traits, advisories that do not name it, and prepared foods, by design.
- **Free text in a request.** These fields carry text as people typed it and are not filtered: inventory food names (`ingredients.name`), the recipe to adapt (`RecipeToAdapt.title` and `ingredientLines`), the unit of an exact quantity (`Quantity.exact`), custom exclusion names (`restrictions.excluded`), and the likes and dislikes typed for each diner (`preferences.avoid` and `preferences.favor`). A name that includes personal text, such as "Ana's birthday cake", reaches the model when that package is selected, and the same holds for any of these fields.
- No recipe discovery adapter exists yet. Sourced labeling is the validator called with the completeness and instructions the future adapter reports.
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
6. **Sourced titles and instructions get the same word scan as generated ones.** An unrecognized word makes a sourced recipe need review, shown with the Needs review label. Until the classification data and the vocabulary grow, this labels many ordinary sourced recipes Needs review, as the Limits figures show.
7. **Cross-contact in staples counts.** Dried pulses, soybeans and quinoa need review for gluten-free and wheat, and barley and rye for wheat, like oats. Bread needs review for vegetarians and vegans because of possible lard and L-cysteine, and maple syrup because of defoamers.
8. **Recipe text is held to a closed vocabulary** rather than to structured steps that reference listed lines. A structured step still carries free text in which a model can name an unlisted food, so the word check would be needed either way.
9. **A just-avoid exclusion still needs review** for an incomplete or empty list, missing instructions, and an advisory that names the food.
10. **"Nuts" as an excluded class includes peanuts.**
11. **A diner whose restrictions this device does not have blocks the request** rather than being treated as having none.
12. **A recipe without instructions needs review**, sourced or generated. Sourced recipes open the original publisher unless Pantrified has rights to display them, so a provider adapter may supply no instructions; every such recipe will be labeled Needs review until its steps can be checked.
13. **No food word in the vocabulary, even as a verb.** Words such as "bake", "chop" and "slice" are left out although their usual sense is a method, because each can also name a food or stand for one. Measures and shapes are accepted only in the narrow positions described under The word scan.
14. **A strict exclusion reviews any food that shares a trait with the excluded food**, contained or may-contain, so an allergy to pork reviews chicken, and an allergy to shrimp reviews crab.
15. **Packaged foods are read as their usual commercial form**: processed foods that usually list natural flavors may contain anything, plant milks and peanut butter carry sugar and its bone char, "crab" may be imitation crab, and apples and citrus may be coated with shellac.
16. **Invisible characters are removed, not flagged**, so the validator reads what the person sees.
