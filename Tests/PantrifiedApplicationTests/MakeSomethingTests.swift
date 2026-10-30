import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private final class ScriptedRuntime: GenerationRuntime, @unchecked Sendable {
    let kind: GenerationRuntimeKind
    private let recipe: GeneratedRecipe?
    private let lock = NSLock()
    private var received: [MakeSomethingRequest] = []

    init(_ kind: GenerationRuntimeKind = .onDevice, returning recipe: GeneratedRecipe?) {
        self.kind = kind
        self.recipe = recipe
    }

    var requests: [MakeSomethingRequest] { lock.withLock { received } }

    func availability() async -> RuntimeAvailability {
        recipe == nil ? .unavailable(.modelNotReady) : .available
    }

    func generate(_ request: MakeSomethingRequest) async throws -> GeneratedRecipe {
        lock.withLock { received.append(request) }
        return recipe!
    }
}

private func makeSomething(_ runtime: ScriptedRuntime) -> MakeSomething {
    MakeSomething(router: GenerationRouter(runtimes: [runtime]))
}

private func context(_ restrictions: Set<DietaryRestriction>) throws -> MakeSomethingContext {
    try MakeSomethingContext(
        ingredients: [MealContextIngredient(name: "Spinach", useSoon: true, quantity: .aboutHalf)],
        diners: [ConsumerProfile(name: "Diner", restrictions: .known(restrictions))]
    )
}

private let saag = GeneratedRecipe(
    title: "Spinach rice",
    ingredientLines: ["2 cups cooked rice", "4 cups spinach", "1 onion, diced", "2 tbsp olive oil", "Salt to taste"],
    instructions: ["Soften the onion in the oil.", "Wilt the spinach, then fold in the rice."]
)

@Suite("Make Something")
struct MakeSomethingTests {
    @Test("a recipe that passes validation is ready with its assessment")
    func safeRecipeIsReady() async throws {
        let outcome = try await makeSomething(ScriptedRuntime(returning: saag)).run(.newRecipe(try context([.diet(.vegan)])))

        guard case .ready(let recipe, let assessment, .onDevice) = outcome else {
            Issue.record("expected ready, got \(outcome)")
            return
        }
        #expect(recipe == saag)
        #expect(assessment.verdict == .safe)
    }

    @Test("a recipe that breaks a restriction is withheld")
    func violationIsWithheld() async throws {
        var buttery = saag
        buttery.ingredientLines.append("2 tbsp butter")
        let outcome = try await makeSomething(ScriptedRuntime(returning: buttery)).run(.newRecipe(try context([.diet(.dairyFree)])))

        guard case .withheld(let assessment, _) = outcome, case .violation = assessment.verdict else {
            Issue.record("expected a withheld violation, got \(outcome)")
            return
        }
    }

    @Test("a recipe that needs review is withheld, not presented")
    func needsReviewIsWithheld() async throws {
        var unknown = saag
        unknown.ingredientLines.append("1 tbsp gochujang")
        let outcome = try await makeSomething(ScriptedRuntime(returning: unknown)).run(.newRecipe(try context([.diet(.vegan)])))

        guard case .withheld(let assessment, _) = outcome, case .needsReview = assessment.verdict else {
            Issue.record("expected withheld for review, got \(outcome)")
            return
        }
    }

    @Test("a food used in the instructions but missing from the list is caught")
    func unlistedFoodIsCaught() async throws {
        var sneaky = saag
        sneaky.instructions.append("Finish with a knob of butter.")
        let outcome = try await makeSomething(ScriptedRuntime(returning: sneaky)).run(.newRecipe(try context([.diet(.vegan)])))

        guard case .withheld(let assessment, _) = outcome, case .needsReview(let reasons) = assessment.verdict else {
            Issue.record("expected withheld for review, got \(outcome)")
            return
        }
        #expect(reasons == [.mentionedButNotListed(IngredientName("butter"))])
    }

    @Test("a title naming an unlisted food is withheld")
    func titleIsValidated() async throws {
        let shrimpRice = GeneratedRecipe(
            title: "Garlic shrimp rice",
            ingredientLines: ["1 cup rice", "2 cloves garlic", "1 tbsp olive oil"],
            instructions: ["Cook everything together and serve."]
        )
        let outcome = try await makeSomething(ScriptedRuntime(returning: shrimpRice))
            .run(.newRecipe(try context([.allergen(.crustaceanShellfish)])))

        guard case .withheld(let assessment, _) = outcome, case .needsReview(let reasons) = assessment.verdict else {
            Issue.record("expected withheld for review, got \(outcome)")
            return
        }
        #expect(reasons.contains(.mentionedButNotListed(IngredientName("shrimp"))))
    }

    @Test("a food the data does not know, used only in the instructions, is withheld")
    func unknownUnlistedFoodIsWithheld() async throws {
        var withRicotta = saag
        withRicotta.instructions.append("Fold in the ricotta and serve.")
        let outcome = try await makeSomething(ScriptedRuntime(returning: withRicotta)).run(.newRecipe(try context([.allergen(.milk)])))

        guard case .withheld(let assessment, _) = outcome, case .needsReview(let reasons) = assessment.verdict else {
            Issue.record("expected withheld for review, got \(outcome)")
            return
        }
        #expect(reasons == [.unrecognizedWord("ricotta")])
    }

    @Test("a recipe without instructions is withheld")
    func missingInstructionsAreWithheld() async throws {
        var stepless = saag
        stepless.instructions = []
        let outcome = try await makeSomething(ScriptedRuntime(returning: stepless)).run(.newRecipe(try context([.diet(.vegan)])))

        guard case .withheld(let assessment, _) = outcome, case .needsReview(let reasons) = assessment.verdict else {
            Issue.record("expected withheld for review, got \(outcome)")
            return
        }
        #expect(reasons == [.instructionsMissing])
    }

    @Test("adaptations are validated the same way")
    func adaptationIsValidated() async throws {
        var withFishSauce = saag
        withFishSauce.ingredientLines.append("1 tbsp fish sauce")
        let original = RecipeToAdapt(title: "Fried rice", ingredientLines: ["2 cups cooked rice", "2 eggs"])
        let outcome = try await makeSomething(ScriptedRuntime(returning: withFishSauce))
            .run(.adaptation(original, try context([.diet(.vegetarian)])))

        guard case .withheld(let assessment, _) = outcome, case .violation = assessment.verdict else {
            Issue.record("expected a withheld violation, got \(outcome)")
            return
        }
    }

    @Test("with no hard restrictions the recipe is ready without a safety label")
    func noRestrictions() async throws {
        let outcome = try await makeSomething(ScriptedRuntime(returning: saag)).run(.newRecipe(try context([])))

        guard case .ready(_, let assessment, _) = outcome else {
            Issue.record("expected ready, got \(outcome)")
            return
        }
        #expect(assessment.verdict == .noRestrictions)
    }

    @Test("no available runtime is reported as unavailable")
    func unavailable() async throws {
        let outcome = try await makeSomething(ScriptedRuntime(returning: nil)).run(.newRecipe(try context([])))

        #expect(outcome == .unavailable([SkippedRuntime(kind: .onDevice, reason: .modelNotReady)]))
    }
}

/// Records which packages a use case reads.
private actor ReadRecordingInventory: InventoryRepository {
    private let inner: InMemoryInventory
    private(set) var readIDs: [PackageID] = []
    private(set) var listedSpaces: [SpaceID] = []

    init(_ packages: [Package]) { inner = InMemoryInventory(packages) }

    func package(_ id: PackageID) async throws -> Package? {
        readIDs.append(id)
        return try await inner.package(id)
    }

    func activePackages(in space: SpaceID) async throws -> [Package] {
        listedSpaces.append(space)
        return try await inner.activePackages(in: space)
    }

    func save(_ package: Package) async throws { try await inner.save(package) }
    func saveAll(_ packages: [Package]) async throws { try await inner.saveAll(packages) }
}

@Suite("Prepare Make Something")
struct PrepareMakeSomethingTests {
    @Test("only the selected packages are read, and a selected package that is used up or elsewhere is left out")
    func readsOnlySelected() async throws {
        let space = SpaceID()
        let fridge = StorageLocation(name: "Fridge", storageType: .refrigerated)
        let rice = Package(spaceID: space, name: "Rice", location: fridge.id, quantity: .full, addedAt: t0)
        let other = Package(spaceID: space, name: "Birthday cake for Ana", location: fridge.id, addedAt: t0)
        var usedUp = Package(spaceID: space, name: "Milk", location: fridge.id, addedAt: t0)
        try usedUp.record(.usedUp, at: t0)
        let elsewhere = Package(spaceID: SpaceID(), name: "Beans", location: fridge.id, addedAt: t0)
        let inventory = ReadRecordingInventory([rice, other, usedUp, elsewhere])
        let useSoon = UseSoon(
            inventory: inventory,
            locations: InMemoryLocations(locationsBySpace: [space: [fridge]]),
            guidance: FakeGuidance(result: nil),
            time: FixedTime(t0)
        )
        let diner = ConsumerProfile(name: "Diner", restrictions: .known([]))

        let context = try await PrepareMakeSomething(useSoon: useSoon)
            .context(selecting: [rice.id, usedUp.id, elsewhere.id], diners: [diner], in: space)

        #expect(context.ingredients.map(\.name) == ["Rice"])
        #expect(await inventory.listedSpaces.isEmpty)
        #expect(Set(await inventory.readIDs) == [rice.id, usedUp.id, elsewhere.id])
    }

    @Test("only the selected foods reach the context, use-soon first, with no diner identity")
    func selectedOnly() async throws {
        let space = SpaceID()
        let fridge = StorageLocation(name: "Fridge", storageType: .refrigerated)
        let spinach = Package(spaceID: space, name: "Spinach", location: fridge.id, quantity: .low,
                              printedDate: PrintedDate(label: .useBy, date: t0.addingTimeInterval(86_400)), addedAt: t0)
        let rice = Package(spaceID: space, name: "Rice", location: fridge.id, quantity: .full, addedAt: t0)
        let secret = Package(spaceID: space, name: "Birthday cake for Ana", location: fridge.id, addedAt: t0)
        let useSoon = UseSoon(
            inventory: InMemoryInventory([spinach, rice, secret]),
            locations: InMemoryLocations(locationsBySpace: [space: [fridge]]),
            guidance: FakeGuidance(result: nil),
            time: FixedTime(t0)
        )
        let ana = ConsumerProfile(name: "Ana", restrictions: .known([.allergen(.peanut)]))

        let context = try await PrepareMakeSomething(useSoon: useSoon)
            .context(selecting: [rice.id, spinach.id], diners: [ana], in: space)

        #expect(context.ingredients == [
            MealContextIngredient(name: "Spinach", useSoon: true, quantity: .low),
            MealContextIngredient(name: "Rice", useSoon: false, quantity: .full),
        ])
        #expect(context.restrictions == [.allergen(.peanut)])
        await #expect(throws: MakeSomethingContextError.noDiners) {
            try await PrepareMakeSomething(useSoon: useSoon).context(selecting: [rice.id], diners: [], in: space)
        }
        let json = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
        #expect(!json.contains("Ana"))
        #expect(!json.contains("cake"))
        #expect(!json.contains(spinach.id.rawValue.uuidString))
    }
}
