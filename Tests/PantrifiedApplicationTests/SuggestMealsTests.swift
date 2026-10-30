import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func day(_ offset: Int) -> Date {
    let base = DateComponents(calendar: utc, year: 2026, month: 11, day: 1, hour: 12).date!
    return utc.date(byAdding: .day, value: offset, to: base)!
}

private let space = SpaceID()
private let fridge = StorageLocation(name: "Fridge", storageType: .refrigerated)

private func package(_ name: String, useBy: Int? = nil, in spaceID: SpaceID = space) -> Package {
    Package(
        spaceID: spaceID,
        name: name,
        location: fridge.id,
        printedDate: useBy.map { PrintedDate(label: .useBy, date: day($0)) },
        addedAt: day(0)
    )
}

private func suggester(
    _ packages: [Package],
    links: InMemoryLinks = InMemoryLinks(),
    inventory: InMemoryInventory? = nil
) -> SuggestMeals {
    let inventory = inventory ?? InMemoryInventory(packages)
    return SuggestMeals(
        useSoon: UseSoon(
            inventory: inventory,
            locations: InMemoryLocations(locationsBySpace: [space: [fridge]]),
            guidance: FakeGuidance(),
            time: FixedTime(day(0)),
            policy: AttentionPolicy(calendar: utc, useSoonWithinDays: 3)
        ),
        links: links
    )
}

private func meal(_ title: String, _ ingredients: String...) -> MealCandidate {
    MealCandidate(title: title, ingredients: ingredients.map(RecipeIngredient.init))
}

@Suite("Suggest meals")
struct SuggestMealsTests {
    @Test("meals that use food needing attention rank first")
    func ranksByAttention() async throws {
        let ranked = try await suggester([
            package("spinach", useBy: 1),
            package("rice", useBy: 90),
        ]).rank(
            [meal("Rice bowl", "rice"), meal("Spinach salad", "spinach", "feta")],
            in: space
        )

        #expect(ranked.map(\.meal.title) == ["Spinach salad", "Rice bowl"])
        #expect(ranked[0].usesSoonCount == 1)
    }

    @Test("a package with no date or guidance still counts as available, just not urgent")
    func unknownAttentionIsAvailable() async throws {
        let ranked = try await suggester([package("rice")]).rank([meal("Rice", "rice")], in: space)

        #expect(ranked[0].missingCount == 0)
        #expect(ranked[0].usesSoonCount == 0)
    }

    @Test("used up packages do not satisfy ingredients")
    func inactiveIgnored() async throws {
        var gone = package("butter")
        try gone.record(.usedUp, at: day(0))
        let ranked = try await suggester([gone]).rank([meal("Toast", "butter")], in: space)

        #expect(ranked[0].missingCount == 1)
    }

    @Test("other spaces are ignored")
    func spaceScoped() async throws {
        let ranked = try await suggester([package("rice", in: SpaceID())]).rank([meal("Rice", "rice")], in: space)

        #expect(ranked[0].missingCount == 1)
    }

    @Test("a confirmed link makes a non-matching ingredient available")
    func confirmedLink() async throws {
        let link = IngredientLink(ingredient: IngredientName("broth"), inventoryName: IngredientName("chicken stock"))
        let links = InMemoryLinks([space: [link]])
        let ranked = try await suggester([package("chicken stock")], links: links)
            .rank([meal("Soup", "broth")], in: space)

        #expect(ranked[0].missingCount == 0)
    }

    @Test("confirming a link persists it for later suggestions")
    func confirmPersists() async throws {
        let links = InMemoryLinks()
        let suggest = suggester([package("chicken stock")], links: links)
        let candidates = [meal("Soup", "broth")]
        #expect(try await suggest.rank(candidates, in: space)[0].missingCount == 1)

        try await suggest.confirm(
            IngredientLink(ingredient: IngredientName("broth"), inventoryName: IngredientName("chicken stock")),
            in: space
        )

        #expect(try await suggest.rank(candidates, in: space)[0].missingCount == 0)
    }

    @Test("a repository failure surfaces")
    func failure() async {
        let inventory = InMemoryInventory()
        await inventory.setFailOnRead(true)

        await #expect(throws: FakeFailure.self) {
            try await suggester([], inventory: inventory).rank([meal("Rice", "rice")], in: space)
        }
    }

    @Test("a link failure surfaces")
    func linkFailure() async {
        let links = InMemoryLinks()
        await links.setFailOnRead(true)

        await #expect(throws: FakeFailure.self) {
            try await suggester([], links: links).rank([meal("Rice", "rice")], in: space)
        }
    }
}
