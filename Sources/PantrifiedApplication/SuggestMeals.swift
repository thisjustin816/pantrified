import Foundation
import PantrifiedDomain

/// Ranks candidate meals against a Space's active inventory: food that needs attention first,
/// then fewest missing ingredients.
public struct SuggestMeals: Sendable {
    private let useSoon: UseSoon
    private let links: any IngredientLinkRepository

    public init(useSoon: UseSoon, links: any IngredientLinkRepository) {
        self.useSoon = useSoon
        self.links = links
    }

    public func rank(_ candidates: [MealCandidate], in space: SpaceID) async throws -> [RankedMeal] {
        let inventory = try await useSoon.assessments(in: space).map {
            InventoryItem(
                id: $0.package.id,
                name: IngredientName($0.package.name),
                needsAttention: $0.needsAttention
            )
        }
        return MealRanker.rank(candidates, inventory: inventory, links: try await links.links(in: space))
    }

    public func confirm(_ link: IngredientLink, in space: SpaceID) async throws {
        try await links.confirm(link, in: space)
    }
}
