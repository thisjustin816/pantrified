import Foundation
import Testing
@testable import PantrifiedDomain

private let ana = ConsumerProfile(
    name: "Ana Lopez",
    restrictions: [.allergen(.peanut), .diet(.vegetarian)],
    preferences: DietaryPreferences(
        likes: [IngredientName("mushroom"), IngredientName("cilantro")],
        dislikes: [IngredientName("olive")],
        spiceTolerance: .hot
    )
)
private let ben = ConsumerProfile(
    name: "Ben",
    restrictions: [.diet(.vegetarian), .excluded(IngredientName("pork"))],
    preferences: DietaryPreferences(dislikes: [IngredientName("cilantro")], spiceTolerance: .mild)
)

private func fullRequest() -> MakeSomethingRequest {
    let context = MakeSomethingContext(
        ingredients: [MealContextIngredient(name: " Spinach ", useSoon: true, quantity: .exact(200, unit: "g"))],
        diners: [ana, ben]
    )
    return .adaptation(RecipeToAdapt(title: "Saag", ingredientLines: ["1 lb spinach"]), context)
}

/// Every leaf in a value, by the path of property and case names leading to it. Collection
/// elements and tuple positions add no segment, so paths name fields rather than positions.
private func fields(of value: Any, path: String = "") -> [(path: String, type: String)] {
    let mirror = Mirror(reflecting: value)
    if mirror.children.isEmpty { return [(path, "\(type(of: value))")] }
    let positional = [.collection, .set, .dictionary, .tuple].contains(mirror.displayStyle)
    return mirror.children.flatMap { child -> [(path: String, type: String)] in
        guard !positional, let label = child.label else { return fields(of: child.value, path: path) }
        return fields(of: child.value, path: path.isEmpty ? label : "\(path).\(label)")
    }
}

@Suite("Make Something context")
struct MakeSomethingContextTests {
    @Test("the request carries exactly these fields and nothing that identifies anyone")
    func enumeratesFields() {
        let found = fields(of: fullRequest())
        let paths = Set(found.map(\.path))

        #expect(paths == [
            "adaptation.title",
            "adaptation.ingredientLines",
            "adaptation.ingredients.name",
            "adaptation.ingredients.useSoon",
            "adaptation.ingredients.quantity.exact",
            "adaptation.dinerCount",
            "adaptation.restrictions.allergen",
            "adaptation.restrictions.diet",
            "adaptation.restrictions.excluded.words",
            "adaptation.preferences.avoid.words",
            "adaptation.preferences.favor.words",
            "adaptation.preferences.spiceTolerance.some",
        ])
        let forbidden = ["UUID", "Identifier", "Date", "Data", "URL"]
        for field in found {
            #expect(!forbidden.contains { field.type.contains($0) }, "\(field.path) is \(field.type)")
        }
    }

    @Test("an encoded request contains no diner name or id")
    func noIdentitiesWhenEncoded() throws {
        let json = String(decoding: try JSONEncoder().encode(fullRequest()), as: UTF8.self)

        for diner in [ana, ben] {
            #expect(!json.contains(diner.id.rawValue.uuidString))
        }
        #expect(!json.contains("Ana"))
        #expect(!json.contains("Lopez"))
        #expect(!json.contains("Ben"))
    }

    @Test("diners' needs are combined without saying whose they are")
    func combinesDiners() {
        let context = fullRequest().context

        #expect(context.dinerCount == 2)
        #expect(context.restrictions == [.allergen(.peanut), .diet(.vegetarian), .excluded(IngredientName("pork"))])
        #expect(context.preferences.avoid == [IngredientName("olive"), IngredientName("cilantro")])
        #expect(context.preferences.favor == [IngredientName("mushroom")])
        #expect(context.preferences.spiceTolerance == .mild)
        #expect(context.ingredients.first?.name == "Spinach")
    }
}
