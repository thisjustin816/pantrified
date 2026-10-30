import Foundation

public enum MealTag: Sendable {}
public typealias MealID = Identifier<MealTag>

public struct RecipeIngredient: Sendable, Hashable {
    public let name: String
    public let normalized: IngredientName

    public init(_ name: String) {
        self.name = name
        self.normalized = IngredientName(name)
    }
}

public struct MealCandidate: Sendable, Hashable, Identifiable {
    public let id: MealID
    public var title: String
    public var ingredients: [RecipeIngredient]

    public init(id: MealID = MealID(), title: String, ingredients: [RecipeIngredient]) {
        self.id = id
        self.title = title
        self.ingredients = ingredients
    }
}

/// An active package reduced to what matching needs.
public struct InventoryItem: Sendable, Hashable {
    public let id: PackageID
    public let name: IngredientName
    /// The package is past guidance or should be used soon.
    public let needsAttention: Bool

    public init(id: PackageID, name: IngredientName, needsAttention: Bool) {
        self.id = id
        self.name = name
        self.needsAttention = needsAttention
    }
}

/// A user-confirmed equivalence: this recipe ingredient is satisfied by inventory with that name.
/// It applies only in that direction.
public struct IngredientLink: Sendable, Hashable, Codable {
    public let ingredient: IngredientName
    public let inventoryName: IngredientName

    public init(ingredient: IngredientName, inventoryName: IngredientName) {
        self.ingredient = ingredient
        self.inventoryName = inventoryName
    }
}

public enum IngredientMatch: Sendable, Hashable {
    case have([PackageID])
    /// Overlapping words but no exact or confirmed match; the user decides.
    case possible([PackageID])
    case missing
}

public struct IngredientResult: Sendable, Hashable {
    public let ingredient: RecipeIngredient
    public let match: IngredientMatch
    /// Some confirmed-matching package needs attention.
    public let usesAttention: Bool
}

public struct RankedMeal: Sendable, Hashable {
    public let meal: MealCandidate
    public let results: [IngredientResult]

    public var usesSoonCount: Int { results.filter(\.usesAttention).count }
    public var missingCount: Int { results.filter { $0.match == .missing }.count }
    public var possibleCount: Int {
        results.filter { if case .possible = $0.match { true } else { false } }.count
    }
}

/// Orders meals by how much food that needs attention they use, then by how little is missing.
public enum MealRanker {
    public static func rank(
        _ meals: [MealCandidate],
        inventory: [InventoryItem],
        links: Set<IngredientLink>
    ) -> [RankedMeal] {
        meals.map { meal in
            RankedMeal(
                meal: meal,
                results: meal.ingredients
                    .filter { !$0.normalized.isEmpty }
                    .map { result(for: $0, inventory: inventory, links: links) }
            )
        }
        .sorted { a, b in
            if a.usesSoonCount != b.usesSoonCount { return a.usesSoonCount > b.usesSoonCount }
            if a.missingCount != b.missingCount { return a.missingCount < b.missingCount }
            if a.possibleCount != b.possibleCount { return a.possibleCount < b.possibleCount }
            return a.meal.title < b.meal.title
        }
    }

    private static func result(
        for ingredient: RecipeIngredient,
        inventory: [InventoryItem],
        links: Set<IngredientLink>
    ) -> IngredientResult {
        let name = ingredient.normalized
        let have = inventory.filter {
            $0.name == name || links.contains(IngredientLink(ingredient: name, inventoryName: $0.name))
        }
        if !have.isEmpty {
            return IngredientResult(
                ingredient: ingredient,
                match: .have(have.map(\.id)),
                usesAttention: have.contains(where: \.needsAttention)
            )
        }
        let possible = inventory.filter { overlaps($0.name, name) }
        return IngredientResult(
            ingredient: ingredient,
            match: possible.isEmpty ? .missing : .possible(possible.map(\.id)),
            usesAttention: false
        )
    }

    private static func overlaps(_ a: IngredientName, _ b: IngredientName) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        let (left, right) = (Set(a.words), Set(b.words))
        return left.isSubset(of: right) || right.isSubset(of: left)
    }
}
