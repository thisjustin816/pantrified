import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private struct Fixture {
    let space = SpaceID()
    let fridge = StorageLocation(name: "Fridge", storageType: .refrigerated)
    let pantry = StorageLocation(name: "Pantry", storageType: .roomTemperature)
    let inventory: InMemoryInventory
    let locations: InMemoryLocations
    let resolver: ResolveMissingIngredients

    init() {
        let space = space
        let fridge = fridge
        let pantry = pantry
        inventory = InMemoryInventory()
        locations = InMemoryLocations(locationsBySpace: [space: [fridge, pantry]])
        resolver = ResolveMissingIngredients(
            putAway: PutAway(inventory: inventory, locations: locations, time: FixedTime(t0))
        )
    }

    func review(_ ingredients: String...) -> MissingIngredientReview {
        let meal = MealCandidate(title: "Dinner", ingredients: ingredients.map(RecipeIngredient.init))
        return MissingIngredientReview(MealRanker.rank([meal], inventory: [], links: [])[0])
    }
}

@Suite("Resolve missing ingredients")
struct ResolveMissingIngredientsTests {
    @Test("Have it already creates a minimal package and the rest become the shopping selection")
    func createsMinimalPackage() async throws {
        let f = Fixture()
        var review = f.review("saffron", "capers")
        try review.decide(review.lines[0].id, .haveItAlready(in: f.pantry.id))

        let resolution = try await f.resolver.resolve(review, in: f.space)

        #expect(resolution.shoppingSelection.map(\.name) == ["capers"])
        let created = try #require(await f.inventory.package(review.lines[0].id))
        #expect(created.name == "saffron")
        #expect(created.location == f.pantry.id)
        #expect(created.quantity == .unknown)
        #expect(created.printedDate == nil)
        #expect(resolution.created == [created.id])
    }

    @Test("a review with only purchases writes nothing to inventory")
    func nothingToCreate() async throws {
        let f = Fixture()
        let resolution = try await f.resolver.resolve(f.review("saffron"), in: f.space)

        #expect(resolution.created.isEmpty)
        #expect(resolution.shoppingSelection.map(\.name) == ["saffron"])
        #expect(await f.inventory.saveCount == 0)
    }

    @Test("a location outside the Space fails and creates nothing")
    func unknownLocation() async throws {
        let f = Fixture()
        var review = f.review("saffron", "capers")
        try review.decide(review.lines[0].id, .haveItAlready(in: f.pantry.id))
        try review.decide(review.lines[1].id, .haveItAlready(in: LocationID()))

        await #expect(throws: PutAwayError.unknownLocation(review.lines[1].id)) {
            try await f.resolver.resolve(review, in: f.space)
        }
        #expect(try await f.inventory.activePackages(in: f.space).isEmpty)
    }

    @Test("resolving the same review twice creates the package once")
    func idempotent() async throws {
        let f = Fixture()
        var review = f.review("saffron")
        try review.decide(review.lines[0].id, .haveItAlready(in: f.pantry.id))

        _ = try await f.resolver.resolve(review, in: f.space)
        let retry = try await f.resolver.resolve(review, in: f.space)

        #expect(retry.created.isEmpty)
        #expect(try await f.inventory.activePackages(in: f.space).count == 1)
    }

    @Test("a failed save surfaces and creates nothing")
    func saveFailure() async throws {
        let f = Fixture()
        var review = f.review("saffron")
        try review.decide(review.lines[0].id, .haveItAlready(in: f.pantry.id))
        await f.inventory.setFailOnSave(true)

        await #expect(throws: FakeFailure.self) {
            try await f.resolver.resolve(review, in: f.space)
        }
        #expect(try await f.inventory.activePackages(in: f.space).isEmpty)
    }

    @Test("the created package satisfies the ingredient in later meal suggestions")
    func countsAsHaveAfterwards() async throws {
        let f = Fixture()
        let meal = MealCandidate(title: "Paella", ingredients: [RecipeIngredient("saffron")])
        var review = MissingIngredientReview(MealRanker.rank([meal], inventory: [], links: [])[0])
        try review.decide(review.lines[0].id, .haveItAlready(in: f.pantry.id))
        _ = try await f.resolver.resolve(review, in: f.space)

        let suggest = SuggestMeals(
            useSoon: UseSoon(
                inventory: f.inventory, locations: f.locations, guidance: FakeGuidance(), time: FixedTime(t0)
            ),
            links: InMemoryLinks()
        )
        let ranked = try await suggest.rank([meal], in: f.space)

        #expect(ranked[0].missingCount == 0)
    }
}
