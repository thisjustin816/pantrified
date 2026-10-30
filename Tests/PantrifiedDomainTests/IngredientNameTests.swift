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
}
