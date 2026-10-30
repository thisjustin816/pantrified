import Foundation

public enum MissingIngredientError: Error, Sendable, Equatable {
    case unknownLine
}

public enum MissingDecision: Sendable, Hashable {
    case buy
    /// The person has it; a minimal inventory record is created in this location. Quantity and
    /// date stay unknown.
    case haveItAlready(in: LocationID)
}

public struct HaveItAlready: Sendable, Hashable, Identifiable {
    /// Becomes the identity of the package created for this ingredient.
    public let id: PackageID
    public let ingredient: RecipeIngredient
    public let location: LocationID
}

/// The inline review of what a meal is missing, before anything is exported or added to inventory.
/// Possible matches are not here: those are confirmed as links, not treated as missing.
public struct MissingIngredientReview: Sendable {
    public struct Line: Sendable, Hashable, Identifiable {
        public let id: PackageID
        public let ingredient: RecipeIngredient
        public var decision: MissingDecision
    }

    public private(set) var lines: [Line]

    public init(_ meal: RankedMeal) {
        lines = meal.results
            .filter { $0.match == .missing }
            .map { Line(id: PackageID(), ingredient: $0.ingredient, decision: .buy) }
    }

    public mutating func decide(_ id: PackageID, _ decision: MissingDecision) throws {
        guard let index = lines.firstIndex(where: { $0.id == id }) else {
            throw MissingIngredientError.unknownLine
        }
        lines[index].decision = decision
    }

    /// The provider-neutral shopping selection for what still has to be bought.
    public var toBuy: [ShoppingExportItem] {
        lines.filter { $0.decision == .buy }.map {
            ShoppingExportItem(id: $0.id.rawValue, name: $0.ingredient.name)
        }
    }

    public var haveAlready: [HaveItAlready] {
        lines.compactMap { line in
            guard case .haveItAlready(let location) = line.decision else { return nil }
            return HaveItAlready(id: line.id, ingredient: line.ingredient, location: location)
        }
    }
}
