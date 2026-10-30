import Foundation
import Testing
@testable import PantrifiedDomain

private func item(_ name: String) -> InventoryItem {
    InventoryItem(id: PackageID(), name: IngredientName(name), needsAttention: false)
}

private func ranked(_ ingredients: [String], inventory: [InventoryItem]) -> RankedMeal {
    let meal = MealCandidate(title: "Dinner", ingredients: ingredients.map(RecipeIngredient.init))
    return MealRanker.rank([meal], inventory: inventory, links: [])[0]
}

@Suite("Missing ingredient review")
struct MissingIngredientReviewTests {
    @Test("only ingredients that are missing are reviewed")
    func onlyMissing() {
        let meal = ranked(["rice", "milk", "saffron"], inventory: [item("rice"), item("coconut milk")])
        let review = MissingIngredientReview(meal)

        #expect(review.lines.map(\.ingredient.name) == ["saffron"])
    }

    @Test("a meal with nothing missing has nothing to review")
    func nothingMissing() {
        let review = MissingIngredientReview(ranked(["rice"], inventory: [item("rice")]))

        #expect(review.lines.isEmpty)
        #expect(review.toBuy.isEmpty)
    }

    @Test("every line defaults to needing to buy it")
    func defaultsToBuy() {
        let review = MissingIngredientReview(ranked(["saffron", "capers"], inventory: []))

        #expect(review.toBuy.map(\.name) == ["saffron", "capers"])
        #expect(review.haveAlready.isEmpty)
    }

    @Test("marking Have it already moves the line out of the shopping selection")
    func haveItAlready() throws {
        var review = MissingIngredientReview(ranked(["saffron", "capers"], inventory: []))
        let location = LocationID()
        try review.decide(review.lines[0].id, .haveItAlready(in: location))

        #expect(review.toBuy.map(\.name) == ["capers"])
        #expect(review.haveAlready.map(\.ingredient.name) == ["saffron"])
        #expect(review.haveAlready.map(\.location) == [location])
    }

    @Test("a decision can be changed back to buying")
    func changeMind() throws {
        var review = MissingIngredientReview(ranked(["saffron"], inventory: []))
        let id = review.lines[0].id
        try review.decide(id, .haveItAlready(in: LocationID()))
        try review.decide(id, .buy)

        #expect(review.toBuy.map(\.name) == ["saffron"])
        #expect(review.haveAlready.isEmpty)
    }

    @Test("deciding an unknown line fails")
    func unknownLine() {
        var review = MissingIngredientReview(ranked(["saffron"], inventory: []))

        #expect(throws: MissingIngredientError.unknownLine) {
            try review.decide(PackageID(), .buy)
        }
    }

    @Test("blank ingredients never become lines")
    func blankIgnored() {
        let review = MissingIngredientReview(ranked(["saffron", " , "], inventory: []))

        #expect(review.lines.count == 1)
    }

    @Test("the line id is the identity of the package it would create")
    func lineIDIsPackageID() {
        let review = MissingIngredientReview(ranked(["saffron", "capers"], inventory: []))

        #expect(Set(review.lines.map(\.id)).count == 2)
    }
}
