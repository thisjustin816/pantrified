import Foundation
import Testing
@testable import PantrifiedDomain

@Suite("Ingredient name normalization")
struct IngredientNameTests {
    @Test("case, spacing, and punctuation do not matter")
    func caseAndPunctuation() {
        #expect(IngredientName("  Half-and-Half ").text == "half and half")
        #expect(IngredientName("Soy Sauce,").text == "soy sauce")
    }

    @Test("simple plurals reduce to the singular")
    func plurals() {
        #expect(IngredientName("Eggs").text == "egg")
        #expect(IngredientName("tomatoes").text == "tomato")
        #expect(IngredientName("cherries").text == "cherry")
        #expect(IngredientName("peaches").text == "peach")
        #expect(IngredientName("lentils").text == "lentil")
    }

    @Test("words that only look plural are left alone")
    func notPlurals() {
        #expect(IngredientName("hummus").text == "hummus")
        #expect(IngredientName("asparagus").text == "asparagus")
        #expect(IngredientName("swiss").text == "swiss")
    }

    @Test("preparation and size descriptors are dropped")
    func descriptors() {
        #expect(IngredientName("boneless, skinless chicken breasts").text == "chicken breast")
        #expect(IngredientName("Fresh chopped parsley").text == "parsley")
        #expect(IngredientName("Large ripe avocados").text == "avocado")
    }

    @Test("a name made only of descriptors keeps its words")
    func onlyDescriptors() {
        #expect(IngredientName("fresh").text == "fresh")
    }

    @Test("whole is kept because it changes the product")
    func wholeKept() {
        #expect(IngredientName("whole milk").text == "whole milk")
    }

    @Test("blank input is empty")
    func blank() {
        #expect(IngredientName("  ,, ").isEmpty)
    }

    @Test("word order is preserved")
    func order() {
        #expect(IngredientName("breast chicken").text == "breast chicken")
    }

    @Test("a decoded name is normalized as typed text would be")
    func decodedNameIsNormalized() throws {
        let decoded = try JSONDecoder().decode(IngredientName.self, from: Data(#"{"words":["Fresh Cilantro","leaves\u200B"]}"#.utf8))

        #expect(decoded == IngredientName("cilantro leaves"))
    }

    @Test("a decoded just-avoid exclusion matches the food it names")
    func decodedExclusionMatches() throws {
        let json = #"{"excluded":{"_0":{"words":["Cilantro"]},"severity":{"justAvoid":{}}}}"#
        let restriction = try JSONDecoder().decode(DietaryRestriction.self, from: Data(json.utf8))
        let recipe = RecipeUnderReview(
            title: "", ingredientLines: ["1 bunch cilantro"], instructions: ["Serve."], completeness: .complete, origin: .sourced
        )

        #expect(restriction == .excluded(IngredientName("cilantro"), severity: .justAvoid))
        guard case .violation = DietaryValidator().assess(recipe, against: [restriction]).verdict else {
            Issue.record("the decoded exclusion did not match cilantro")
            return
        }
    }

    @Test("normalizing a normalized name changes nothing, so stored names decode unchanged")
    func normalizationIsIdempotent() throws {
        let raw = ClassificationDataset.bundled.entries.flatMap(\.names).map(\.text) + [
            "Boneless, skinless chicken breasts", "organics milk", "Fresh", "glasses", "molasses", "kiwis",
            "tomatoes", "cherries", "Half-and-Half", "  ,, ", "ri\u{200B}ce", "ＢＵＴＴＥＲ", "crème fraîche",
        ]
        for text in raw {
            let name = IngredientName(text)
            #expect(IngredientName(name.text) == name, "\(text)")
            #expect(try JSONDecoder().decode(IngredientName.self, from: JSONEncoder().encode(name)) == name, "\(text)")
        }
    }
}
