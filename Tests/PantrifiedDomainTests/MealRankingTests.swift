import Foundation
import Testing
@testable import PantrifiedDomain

private func item(_ name: String, attention: Bool = false) -> InventoryItem {
    InventoryItem(id: PackageID(), name: IngredientName(name), needsAttention: attention)
}

private func meal(_ title: String, _ ingredients: String...) -> MealCandidate {
    MealCandidate(title: title, ingredients: ingredients.map(RecipeIngredient.init))
}

private func rank(
    _ meals: [MealCandidate],
    _ inventory: [InventoryItem],
    links: Set<IngredientLink> = []
) -> [RankedMeal] {
    MealRanker.rank(meals, inventory: inventory, links: links)
}

@Suite("Ingredient matching")
struct IngredientMatchingTests {
    @Test("an exact normalized match counts as have")
    func exact() {
        let chicken = item("Chicken breasts")
        let ranked = rank([meal("Roast", "boneless chicken breast")], [chicken])

        #expect(ranked[0].results[0].match == .have([chicken.id]))
    }

    @Test("a partial word overlap is only a possible match")
    func possible() {
        let milk = item("coconut milk")
        let ranked = rank([meal("Latte", "milk")], [milk])

        #expect(ranked[0].results[0].match == .possible([milk.id]))
        #expect(ranked[0].missingCount == 0)
        #expect(ranked[0].possibleCount == 1)
    }

    @Test("no overlap is missing")
    func missing() {
        let ranked = rank([meal("Salad", "lettuce")], [item("rice")])

        #expect(ranked[0].results[0].match == .missing)
        #expect(ranked[0].missingCount == 1)
    }

    @Test("a confirmed link turns a non-match into have")
    func confirmedLink() {
        let stock = item("chicken stock")
        let link = IngredientLink(ingredient: IngredientName("broth"), inventoryName: stock.name)
        let ranked = rank([meal("Soup", "broth")], [stock], links: [link])

        #expect(ranked[0].results[0].match == .have([stock.id]))
    }

    @Test("a confirmed link applies in one direction only")
    func linkIsDirectional() {
        let broth = item("broth")
        let link = IngredientLink(ingredient: IngredientName("broth"), inventoryName: IngredientName("chicken stock"))
        let ranked = rank([meal("Soup", "chicken stock")], [broth], links: [link])

        #expect(ranked[0].results[0].match == .missing)
    }

    @Test("several packages of one ingredient are all reported")
    func severalPackages() {
        let a = item("milk")
        let b = item("milk")
        let ranked = rank([meal("Pancakes", "milk")], [a, b])

        #expect(ranked[0].results[0].match == .have([a.id, b.id]))
    }

    @Test("blank recipe ingredients are ignored")
    func blankIgnored() {
        let ranked = rank([meal("Odd", "rice", " , ")], [item("rice")])

        #expect(ranked[0].results.count == 1)
    }
}

@Suite("Meal ranking")
struct MealRankingTests {
    @Test("meals using food that needs attention come first, even with more missing")
    func useSoonFirst() {
        let spinach = item("spinach", attention: true)
        let rice = item("rice")
        let ranked = rank(
            [
                meal("Rice bowl", "rice", "beans"),
                meal("Spinach pie", "spinach", "feta", "dough", "eggs"),
            ],
            [spinach, rice]
        )

        #expect(ranked.map(\.meal.title) == ["Spinach pie", "Rice bowl"])
    }

    @Test("among equal use-soon counts, fewer missing ingredients wins")
    func fewerMissing() {
        let spinach = item("spinach", attention: true)
        let ranked = rank(
            [
                meal("Big", "spinach", "feta", "dough"),
                meal("Small", "spinach", "feta"),
            ],
            [spinach]
        )

        #expect(ranked.map(\.meal.title) == ["Small", "Big"])
    }

    @Test("a possible match ranks below a confirmed one when the rest is equal")
    func possibleBelowHave() {
        let ranked = rank(
            [
                meal("Maybe", "milk"),
                meal("Sure", "oat milk"),
            ],
            [item("oat milk")]
        )

        #expect(ranked.map(\.meal.title) == ["Sure", "Maybe"])
    }

    @Test("use-soon counts ingredients, not packages")
    func countsIngredients() {
        let ranked = rank(
            [meal("Pancakes", "milk")],
            [item("milk", attention: true), item("milk", attention: true)]
        )

        #expect(ranked[0].usesSoonCount == 1)
    }

    @Test("a possible match never counts as using food that needs attention")
    func possibleNotUseSoon() {
        let ranked = rank([meal("Latte", "milk")], [item("coconut milk", attention: true)])

        #expect(ranked[0].usesSoonCount == 0)
    }

    @Test("ties are ordered by title so results are stable")
    func stableTies() {
        let ranked = rank([meal("Beta", "rice"), meal("Alpha", "rice")], [item("rice")])

        #expect(ranked.map(\.meal.title) == ["Alpha", "Beta"])
    }

    @Test("a meal with nothing available is still listed, last")
    func allMissingListed() {
        let ranked = rank([meal("Nothing", "truffle"), meal("Rice", "rice")], [item("rice")])

        #expect(ranked.map(\.meal.title) == ["Rice", "Nothing"])
    }
}
