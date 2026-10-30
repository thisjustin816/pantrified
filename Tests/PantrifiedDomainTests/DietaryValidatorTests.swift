import Foundation
import Testing
@testable import PantrifiedDomain

private func recipe(_ lines: [String], instructions: [String] = []) -> RecipeUnderReview {
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
