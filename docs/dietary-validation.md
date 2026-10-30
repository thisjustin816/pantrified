# Pantrified Dietary Validation

How Pantrified decides whether a recipe suits the people eating it. Code: `Sources/PantrifiedDomain/Dietary/` (restrictions, classification data, validator), `Sources/PantrifiedDomain/MakeSomethingContext.swift`, and `Sources/PantrifiedApplication/MakeSomething.swift`. Verification is pure Swift tests on Linux.

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
| Custom excluded food | Matched by name and by what foods are made from, not by trait |

## Classification data

`ClassificationDataset.bundled` is a curated seed, shipped in the app and versioned (`provenance.version`). Every verdict records the data version it rests on.

- Each entry lists the traits a food `contains` and the traits it `mayContain` (recipe variation or cross-contact). Every entry is reviewed against every trait in `coveredTraits`, so a trait in neither list is one the food is known not to have.
- A restriction whose traits fall outside `coveredTraits` can never pass.
- `isExhaustive` is always false. A food without an entry is unknown, and unknown always needs review.
- Lookup is exact on the normalized name or a listed synonym. "Peanut sauce" is not "peanut", and "low-sodium chicken broth" is not "chicken broth".
- Entries describe the plain, typical form of a food from general culinary composition, not any product label.
- `isComposite` marks prepared foods made of other foods. `madeFrom` lists what a food is made from, so excluding pork also excludes bacon, ham, and lard.
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
| `advisoryStatement` | "May contain", "traces of", "processed in a facility" and similar text naming a relevant allergen, or naming nothing recognizable |
| `unrecognizedNote` | A parenthetical that is neither a quantity nor an advisory, such as "(such as malt)" |
| `alternativesDisagree` | "X or Y" where not every choice passes |
| `traitNotCovered` | The data was not reviewed for a trait the restriction needs |
| `exclusionUnverifiable` | A custom-excluded food the data does not know, so no other food can be shown not to be it |
| `compositeMayHideExclusion` | A prepared food that could contain a custom-excluded food |
| `mentionedButNotListed` | The instructions use a relevant food the list leaves out |

## Hidden ingredients

- **Prepared foods**: broth and stock, bouillon, soy sauce (wheat), tamari, Worcestershire sauce (anchovy), fish sauce, oyster sauce, pesto (cheese, pine nuts), mayonnaise, curry paste, chocolate, sausage, and bread are composite entries with the traits they contain or may contain.
- **Generic words**: "broth", "sauce", "seasoning", "spice blend", and "natural flavors" may contain nearly any trait, so they need review for almost every restriction.
- **Cross-contact and processing**: oats may contain gluten; vegetable oil may be soybean oil; unqualified vinegar may be malt vinegar; baking powder may contain wheat starch; cane sugar may be refined with bone char.
- **May-contain statements** in the line or a note need review when they name a relevant allergen or nothing recognizable.
- **Alternatives** ("butter or margarine") are a violation only if every choice violates, and safe only if every choice is safe.
- **Unlisted foods**: the instructions are scanned for known foods that matter to the active restrictions and are not in the list ("finish with a knob of butter"). Generic words are skipped, and the longest known name wins, so "peanut butter" is not read as "butter".

## Sourced and generated recipes

- **Sourced recipes** are labeled safe only when the provider adapter states the list is complete and the validator passes. Provider labels are carried for display and ignored.
- **Generated recipes and adaptations** (`MakeSomething`) are validated against the request's own restrictions before presentation. Only `safe` or `noRestrictions` results are presented; a violation or a needs-review result is withheld with its assessment so the app can explain or retry. The generated list is treated as complete; the instruction scan checks it.

## Make Something request context

`MakeSomethingContext` is the only data a generative request receives:

- selected foods: name, use-soon flag, approximate quantity
- diner count
- the selected diners' hard restrictions, combined
- the selected diners' preferences, combined: foods to avoid, foods some diner likes and none dislikes, the lowest spice tolerance

It has no field for identifiers, people's names, dates, locations, photos, evidence crops, unselected inventory, or history. A test enumerates every field a request can carry and checks that none holds an identifier, date, or data. `PrepareMakeSomething` reads only the selected packages.

## Limits

- The seed holds 111 foods (176 names with synonyms). Most real recipes contain something it does not know, so they need review until the data grows.
- Parsing is English only and narrow: leading quantities and common units, parenthetical quantities, "to taste", and comma suffixes made only of preparation words. Anything else is unparsed. Descriptors outside the shared normalization list ("low-sodium", "unsweetened") make a food unknown.
- Plain entries describe plain foods. A brined, injected, or flavored product is not distinguished from the plain food.
- Optional ingredients are checked like any other.
- Quantities are ignored; a trace amount and a cup are treated alike.
- The instruction scan works on words and can raise a spurious review, such as "butter the pan" for a dairy-free recipe that lists oil.
- Custom exclusions know only the names and `madeFrom` links in the data. A synonym the data lacks ("coriander" for "cilantro") is not matched; when the excluded food itself is unknown, every recipe needs review.
- Inventory food names go to generation as the household wrote them. A name that includes personal text, such as "Ana's birthday cake", is only kept out when that package is not selected.
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
5. **A custom exclusion is either an allergy or intolerance, or just avoid.** An allergy or intolerance the data does not know makes every recipe need review. A just-avoid exclusion is matched by name and synonyms in ingredient text only, so a recipe that does not name it passes. The choice is not built: every custom exclusion is currently treated as an allergy or intolerance.
