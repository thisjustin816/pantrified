import Foundation
import PantrifiedDomain

public enum BundledGuidanceError: Error, Sendable, Equatable {
    case missingResource
}

/// The USDA FoodKeeper snapshot that ships with the app. Updates arrive with a reviewed release;
/// there is no runtime updater.
public enum BundledGuidance {
    /// Decodes and validates the snapshot, which fails when the bundled file is malformed.
    public static func dataset() throws -> GuidanceDataset {
        guard let url = Bundle.module.url(forResource: "foodkeeper.normalized", withExtension: "json") else {
            throw BundledGuidanceError.missingResource
        }
        return try JSONDecoder().decode(GuidanceDataset.self, from: Data(contentsOf: url))
    }
}
