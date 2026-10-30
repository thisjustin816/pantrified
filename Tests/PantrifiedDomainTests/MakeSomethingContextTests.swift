import Foundation
import Testing
@testable import PantrifiedDomain

private let ana = ConsumerProfile(
    name: "Ana Lopez",
    restrictions: .known([.allergen(.peanut), .diet(.vegetarian), .excluded(IngredientName("cilantro"), severity: .justAvoid)]),
    preferences: DietaryPreferences(
        likes: [IngredientName("mushroom"), IngredientName("cilantro")],
        dislikes: [IngredientName("olive")],
        spiceTolerance: .hot
    )
)
private let ben = ConsumerProfile(
    name: "Ben",
    restrictions: .known([.diet(.vegetarian), .excluded(IngredientName("pork"), severity: .allergyOrIntolerance)]),
    preferences: DietaryPreferences(dislikes: [IngredientName("cilantro")], spiceTolerance: .mild)
)

private func fullRequest() throws -> MakeSomethingRequest {
    let context = try MakeSomethingContext(
        ingredients: [MealContextIngredient(name: " Spinach ", useSoon: true, quantity: .exact(200, unit: "g"))],
        diners: [ana, ben]
    )
    return .adaptation(RecipeToAdapt(title: "Saag", ingredientLines: ["1 lb spinach"]), context)
}

/// A request of each kind that between them use every case of every enum a request holds:
/// `MakeSomethingRequest`, `Quantity`, `DietaryRestriction` and `ExclusionSeverity`.
private func everyKindOfRequest() throws -> [MakeSomethingRequest] {
    let quantities: [Quantity] = [.unknown, .full, .aboutHalf, .low, .exact(200, unit: "g")]
    let context = try MakeSomethingContext(
        ingredients: quantities.map { MealContextIngredient(name: "Spinach", useSoon: true, quantity: $0) },
        diners: [ana, ben]
    )
    return [.newRecipe(context), .adaptation(RecipeToAdapt(title: "Saag", ingredientLines: ["1 lb spinach"]), context)]
}

/// The cases a request uses. Every switch here is exhaustive, so a new case fails to compile until
/// it is named here, and then fails `coversEveryCase` until a sample above uses it.
private func caseNames(in request: MakeSomethingRequest) -> Set<String> {
    var names: Set<String> = []
    switch request {
    case .newRecipe: names.insert("newRecipe")
    case .adaptation: names.insert("adaptation")
    }
    for ingredient in request.context.ingredients {
        switch ingredient.quantity {
        case .unknown: names.insert("unknown")
        case .full: names.insert("full")
        case .aboutHalf: names.insert("aboutHalf")
        case .low: names.insert("low")
        case .exact: names.insert("exact")
        }
    }
    for restriction in request.context.restrictions {
        switch restriction {
        case .allergen: names.insert("allergen")
        case .diet: names.insert("diet")
        case .excluded(_, .allergyOrIntolerance): names.insert("allergyOrIntolerance")
        case .excluded(_, .justAvoid): names.insert("justAvoid")
        }
    }
    return names
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
    @Test("the sample requests use every case a request can hold")
    func coversEveryCase() throws {
        let used = try everyKindOfRequest().reduce(into: Set<String>()) { $0.formUnion(caseNames(in: $1)) }

        #expect(used == [
            "newRecipe", "adaptation", "unknown", "full", "aboutHalf", "low", "exact",
            "allergen", "diet", "allergyOrIntolerance", "justAvoid",
        ])
    }

    @Test("the request carries exactly these fields and nothing that identifies anyone")
    func enumeratesFields() throws {
        let found = try everyKindOfRequest().flatMap { fields(of: $0) }
        let paths = Set(found.map(\.path))

        let contextFields = [
            "ingredients.name", "ingredients.useSoon", "ingredients.quantity", "ingredients.quantity.exact",
            "dinerCount", "restrictions.allergen", "restrictions.diet", "restrictions.excluded",
            "restrictions.excluded.words", "preferences.avoid.words", "preferences.favor.words",
            "preferences.spiceTolerance.some",
        ]
        #expect(paths == Set(
            contextFields.map { "newRecipe.\($0)" } + contextFields.map { "adaptation.\($0)" }
                + ["adaptation.title", "adaptation.ingredientLines"]
        ))
        let forbidden = ["UUID", "Identifier", "Date", "Data", "URL"]
        for field in found {
            #expect(!forbidden.contains { field.type.contains($0) }, "\(field.path) is \(field.type)")
        }
    }

    /// These fields carry text as people typed it, unfiltered; docs/dietary-validation.md lists
    /// them as the request's free-text channels.
    @Test("free text reaches a request only through these fields")
    func freeTextFields() throws {
        let text = try everyKindOfRequest().flatMap { fields(of: $0) }.filter { $0.type == "String" }

        #expect(Set(text.map(\.path)) == [
            "newRecipe.ingredients.name", "newRecipe.ingredients.quantity.exact",
            "newRecipe.restrictions.excluded.words",
            "newRecipe.preferences.avoid.words", "newRecipe.preferences.favor.words",
            "adaptation.title", "adaptation.ingredientLines",
            "adaptation.ingredients.name", "adaptation.ingredients.quantity.exact",
            "adaptation.restrictions.excluded.words",
            "adaptation.preferences.avoid.words", "adaptation.preferences.favor.words",
        ])
    }

    @Test("an encoded request contains no diner name or id")
    func noIdentitiesWhenEncoded() throws {
        let json = String(decoding: try JSONEncoder().encode(try fullRequest()), as: UTF8.self)

        for diner in [ana, ben] {
            #expect(!json.contains(diner.id.rawValue.uuidString))
        }
        #expect(!json.contains("Ana"))
        #expect(!json.contains("Lopez"))
        #expect(!json.contains("Ben"))
    }

    @Test("a request cannot be built for nobody, since no one's restrictions would be checked")
    func noDiners() {
        #expect(throws: MakeSomethingContextError.noDiners) {
            try MakeSomethingContext(ingredients: [], diners: [])
        }
    }

    @Test("a diner whose restrictions this device does not have is never read as having none")
    func unknownRestrictions() {
        let guest = ConsumerProfile(name: "Guest", restrictions: .unknown)

        #expect(throws: MakeSomethingContextError.restrictionsUnknown) {
            try MakeSomethingContext(ingredients: [], diners: [ana, guest])
        }
    }

    @Test("a decoded request for nobody is rejected")
    func decodedNoDiners() throws {
        var json = String(decoding: try JSONEncoder().encode(try fullRequest()), as: UTF8.self)
        json = json.replacingOccurrences(of: "\"dinerCount\":2", with: "\"dinerCount\":0")

        #expect(json.contains("\"dinerCount\":0"))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MakeSomethingRequest.self, from: Data(json.utf8))
        }
    }

    @Test("diners' needs are combined without saying whose they are")
    func combinesDiners() throws {
        let context = try fullRequest().context

        #expect(context.dinerCount == 2)
        #expect(context.restrictions == [
            .allergen(.peanut), .diet(.vegetarian),
            .excluded(IngredientName("cilantro"), severity: .justAvoid),
            .excluded(IngredientName("pork"), severity: .allergyOrIntolerance),
        ])
        #expect(context.preferences.avoid == [IngredientName("olive"), IngredientName("cilantro")])
        #expect(context.preferences.favor == [IngredientName("mushroom")])
        #expect(context.preferences.spiceTolerance == .mild)
        #expect(context.ingredients.first?.name == "Spinach")
    }
}
