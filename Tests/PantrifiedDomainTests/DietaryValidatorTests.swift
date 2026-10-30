import Foundation
import Testing
@testable import PantrifiedDomain

private func recipe(_ lines: [String], instructions: [String] = ["Serve."]) -> RecipeUnderReview {
    RecipeUnderReview(title: "", ingredientLines: lines, instructions: instructions, completeness: .complete, origin: .sourced)
}

@Suite("Dietary validator")
struct DietaryValidatorTests {
    @Test("a restriction whose traits the data does not cover can never pass")
    func uncoveredTrait() {
        let narrow = ClassificationDataset(
            provenance: ClassificationProvenance(source: "test", version: "t", reviewed: "today"),
            coveredTraits: [.milk],
            entries: [ClassificationEntry("rice")]
        )
        let verdict = DietaryValidator(data: narrow).assess(recipe(["1 cup rice"]), against: [.allergen(.sesame)]).verdict

        #expect(verdict == .needsReview([.traitNotCovered(.sesame, restriction: .allergen(.sesame))]))
    }

    @Test("soft preferences never affect the verdict")
    func preferencesAreNotRestrictions() {
        let validator = DietaryValidator()
        let verdict = validator.assess(recipe(["1 cup cooked rice", "1 onion"]), against: [.diet(.vegan)]).verdict

        #expect(verdict == .safe)
    }

    @Test("the verdict names the data version it rests on")
    func dataVersion() {
        let assessment = DietaryValidator().assess(recipe(["1 onion"]), against: [.diet(.vegan)])

        #expect(assessment.dataVersion == ClassificationDataset.bundled.provenance.version)
    }

    @Test("a violation keeps the doubts found alongside it")
    func violationKeepsReviews() {
        let verdict = DietaryValidator().assess(recipe(["2 tbsp butter", "1 tbsp gochujang"]), against: [.diet(.dairyFree)]).verdict

        guard case .violation(let violations, let reviews) = verdict else {
            Issue.record("expected a violation, got \(verdict)")
            return
        }
        #expect(violations.map(\.trait) == [.milk])
        #expect(reviews.map(\.kind) == [.unknownIngredient])
    }

    @Test("an advisory naming only an irrelevant allergen does not need review")
    func irrelevantAdvisory() {
        let verdict = DietaryValidator().assess(
            recipe(["1 cup cooked rice (may contain soy)"]), against: [.allergen(.sesame)]
        ).verdict

        #expect(verdict == .safe)
    }

    @Test("a line that could hold milk is never safe for a milk allergy", arguments: [
        "1/2 cup peanut-free butter", "1 ½ cups milk", "dairy-free cheese", "gluten free soy sauce", "vegan mayo",
        "1 cup rice (no nuts)", "1 cup rice, without egg", "butternut squash", "1 tsp nutmeg", "1 eggplant",
        "cocoa butter", "1 cup rice\n2 tbsp butter", "1 cup rice or 2 tbsp butter", "1 cup rice; 2 tbsp butter",
        "1 cup rice (or butter)", "RICE AND BUTTER", "rice/butter", "1 cup rice, plus butter",
        "1 cup m\u{0456}lk", "rice\u{00A0}and\u{00A0}butter", "2 tbsp but\u{200B}ter", "２ tbsp ｂｕｔｔｅｒ",
        "2 tbsp crème fraîche", "1 cup non-dairy milk", "1 cup rice (contains: milk)", "1 cup Kerrygold",
        "1 cup rice, packed in butter", "1 cup half-and-half",
    ])
    func milkIsNeverHidden(line: String) {
        let verdict = DietaryValidator().assess(recipe([line]), against: [.allergen(.milk)]).verdict

        #expect(verdict != .safe)
    }

    @Test("an instruction naming a listed food is not flagged, and a longer name is not read as a shorter one")
    func instructionsMatchListedFoods() {
        let verdict = DietaryValidator().assess(
            recipe(["2 tbsp peanut butter", "2 slices bread"], instructions: ["Spread the peanut butter on the bread."]),
            against: [.diet(.dairyFree)]
        ).verdict

        guard case .needsReview(let reasons) = verdict else {
            Issue.record("expected needs review for the bread, got \(verdict)")
            return
        }
        #expect(!reasons.contains { $0.kind == .mentionedButNotListed })
    }
}

@Suite("Text as displayed")
struct InvisibleCharacterTests {
    private let validator = DietaryValidator()

    private func verdict(title: String = "", _ lines: [String], instructions: [String] = ["Serve."],
                         _ restrictions: Set<DietaryRestriction>) -> DietaryVerdict {
        validator.assess(
            RecipeUnderReview(title: title, ingredientLines: lines, instructions: instructions, completeness: .complete, origin: .generated),
            against: restrictions
        ).verdict
    }

    @Test("a character that displays as nothing cannot split a word into cooking words or hide a name", arguments: [
        "\u{200B}", "\u{00AD}", "\u{2060}", "\u{FEFF}", "\u{180E}", "\u{200C}", "\u{200D}", "\u{034F}", "\u{FE0F}", "\u{0007}",
    ])
    func invisible(mark: String) {
        let toast = "to\(mark)as\(mark)t"
        let rice = ["2 cups cooked rice"]

        #expect(verdict(title: "Rice on \(toast)", rice, [.allergen(.wheat)]) != .safe, "title")
        #expect(verdict(rice, instructions: ["Serve on \(toast)."], [.allergen(.wheat)]) != .safe, "instructions")
        #expect(verdict(rice + ["1 bunch cilan\(mark)tro"], [.excluded(IngredientName("cilantro"), severity: .justAvoid)]) != .safe,
                "ingredient line")
        #expect(verdict(["1 cup rice (may contain pea\(mark)nuts)"], [.excluded(IngredientName("peanut"), severity: .justAvoid)]) != .safe,
                "advisory")
        #expect(verdict(rice + ["1 bunch cilantro"], [.excluded(IngredientName("cilan\(mark)tro"), severity: .justAvoid)]) != .safe,
                "excluded name")
    }

    @Test("line breaks and tabs still separate words")
    func whitespaceKept() {
        #expect("rice\tand\nbeans".withoutInvisibleCharacters == "rice\tand\nbeans")
        #expect(IngredientName("black\tbeans") == IngredientName("black beans"))
    }
}

@Suite("Earlier false safes")
struct EarlierFalseSafeTests {
    private static func avoided(_ name: String) -> DietaryRestriction { .excluded(IngredientName(name), severity: .justAvoid) }
    private static func strictlyExcluded(_ name: String) -> DietaryRestriction {
        .excluded(IngredientName(name), severity: .allergyOrIntolerance)
    }

    @Test("inputs that were once wrongly safe stay non-safe for sourced and generated recipes", arguments: [
        (["1 cup rice (may contain milk and shrimp)"], [String](), Set([DietaryRestriction.allergen(.crustaceanShellfish)])),
        (["1 cup rice (may contain wheat and almonds)"], [], [.allergen(.treeNut)]),
        (["1 cup rice (may contain gluten)"], [], [.allergen(.wheat)]),
        (["2 cups rice, processed in butter with egg"], [], [.allergen(.milk)]),
        (["1 cup rice (may contain peanuts)"], [], [strictlyExcluded("peanut")]),
        (["1 cup rice (may contain peanuts)"], [], [avoided("peanut")]),
        (["1 cup rice", "1 tbsp olive oil"], ["Fold in the ricotta and serve."], [.allergen(.milk)]),
        (["1 cup rice"], ["Top with toasted hazelnuts."], [.allergen(.treeNut)]),
        (["1 tbsp gelatin"], [], [strictlyExcluded("pork")]),
        (["1 tbsp gelatin"], [], [avoided("pork")]),
        (["1/2 cup parmesan"], [], [strictlyExcluded("cheese")]),
        (["1/2 cup parmesan"], [], [avoided("cheese")]),
        (["2 tbsp butter"], [], [strictlyExcluded("milk")]),
        (["2 tbsp butter"], [], [avoided("milk")]),
        (["8 oz pasta"], [], [strictlyExcluded("egg")]),
        (["2 tbsp tahini"], [], [strictlyExcluded("sesame seed")]),
        (["2 tbsp tahini"], [], [avoided("sesame seed")]),
        (["2 peppers, seeded and diced"], [], [strictlyExcluded("bell pepper")]),
        (["1 bouillon cube"], [], [.allergen(.crustaceanShellfish)]),
        (["2 cups broth"], [], [.allergen(.egg)]),
        (["2 tbsp curry paste"], [], [.allergen(.treeNut)]),
        (["2 slices bread"], [], [.allergen(.treeNut)]),
        (["1 lb sausage"], [], [.allergen(.egg)]),
        (["1 cup rice", "1 onion"], ["Pour in 2 cups of stock and simmer."], [.diet(.vegetarian)]),
        (["1 cup rice"], ["Toss the rice with the sauce."], [.allergen(.peanut)]),
    ] as [([String], [String], Set<DietaryRestriction>)])
    func staysNonSafe(lines: [String], instructions: [String], restrictions: Set<DietaryRestriction>) {
        for origin in [RecipeOrigin.sourced, .generated] {
            let recipe = RecipeUnderReview(
                title: "", ingredientLines: lines, instructions: instructions.isEmpty ? ["Serve."] : instructions,
                completeness: .complete, origin: origin
            )
            #expect(DietaryValidator().assess(recipe, against: restrictions).verdict != .safe, "\(origin)")
        }
    }

    @Test("a title naming an unlisted food is not safe for either origin")
    func titleShrimp() {
        for origin in [RecipeOrigin.sourced, .generated] {
            let recipe = RecipeUnderReview(
                title: "Garlic shrimp rice", ingredientLines: ["1 cup rice", "2 cloves garlic", "1 tbsp olive oil"],
                instructions: ["Cook everything together and serve."], completeness: .complete, origin: origin
            )
            #expect(DietaryValidator().assess(recipe, against: [.allergen(.crustaceanShellfish)]).verdict != .safe, "\(origin)")
        }
    }
}

@Suite("Ingredient line parsing")
struct IngredientLineTests {
    @Test("quantities, units, notes and preparation are removed", arguments: [
        ("2 cups cooked rice", [["cooked rice"]]),
        ("1 (14 oz) can crushed tomatoes", [["crushed tomato"]]),
        ("1½ tbsp olive oil", [["olive oil"]]),
        ("2-3 cloves garlic, minced", [["garlic"]]),
        ("a pinch of salt", [["salt"]]),
        ("1 apple", [["apple"]]),
        ("Salt and pepper to taste", [["salt"], ["pepper"]]),
        ("1 cup milk or almond milk", [["milk", "almond milk"]]),
        ("1 can black beans, drained and rinsed", [["black bean"]]),
    ])
    func parses(line: String, expected: [[String]]) throws {
        let parsed = try #require(IngredientLine.parse(line))

        #expect(parsed.components.map { $0.map(\.text) } == expected)
    }

    @Test("lines that cannot be accounted for are not guessed at", arguments: [
        "", "2 cups", "salt, pepper, rice", "1 cup (rice", "1 tbsp oil, from the jar",
    ])
    func rejects(line: String) {
        #expect(IngredientLine.parse(line) == nil)
    }

    @Test("advisories and unrecognized notes are kept")
    func notes() throws {
        let parsed = try #require(IngredientLine.parse("1 cup chocolate chips (may contain milk) (such as dark)"))

        #expect(parsed.advisories == ["may contain milk"])
        #expect(parsed.unrecognizedNotes == ["such as dark"])
    }
}
