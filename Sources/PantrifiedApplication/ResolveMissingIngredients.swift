import Foundation
import PantrifiedDomain

public struct MissingIngredientResolution: Sendable, Hashable {
    /// What still has to be bought, ready for the shopping list or an exporter.
    public var shoppingSelection: [ShoppingExportItem]
    public var created: [PackageID]
}

/// Applies the inline review of a meal's missing ingredients: ingredients the person already has
/// become minimal inventory records with a location and nothing else, and the rest are returned as
/// the shopping selection.
public struct ResolveMissingIngredients: Sendable {
    private let putAway: PutAway

    public init(putAway: PutAway) {
        self.putAway = putAway
    }

    public func resolve(
        _ review: MissingIngredientReview,
        in space: SpaceID
    ) async throws -> MissingIngredientResolution {
        let drafts = review.haveAlready.map { entry in
            var draft = PackageDraft(id: entry.id, spaceID: space)
            draft.name.confirm(entry.ingredient.name)
            draft.location = entry.location
            return draft
        }
        let result = try await putAway.putAway(drafts)
        return MissingIngredientResolution(shoppingSelection: review.toBuy, created: result.created)
    }
}
