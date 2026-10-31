import Foundation
import PantrifiedDomain

/// A product name a lookup suggests for a barcode. It is a proposal for the person to check, never
/// a confirmed fact about the package.
public struct ProductSuggestion: Sendable, Hashable {
    public var name: String
    /// Who suggested it, for the person to see, such as "USDA FoodData Central".
    public var source: String

    public init(name: String, source: String) {
        self.name = name
        self.source = source
    }
}

/// Why a lookup gave no answer. None of these stop the person adding the food by hand.
public enum ProductLookupFailure: Sendable, Hashable {
    case offline
    case timedOut
    /// The provider asked for fewer requests.
    case rateLimited
    /// The provider refused the app's key.
    case keyRejected
    /// The provider answered with an error or something that could not be read.
    case providerError
    case cancelled
}

public enum ProductLookupResult: Sendable, Hashable {
    case found(ProductSuggestion)
    /// The provider has no product with this barcode. This is normal; the barcode is kept and the
    /// person names the food.
    case notFound
    case failed(ProductLookupFailure)
}

/// Looks up what product a barcode names. Provider neutral: the application never sees a
/// provider's response format. A lookup never throws, so nothing that calls it can be blocked by it.
public protocol ProductLookupService: Sendable {
    func lookUp(_ barcode: GTIN) async -> ProductLookupResult
}
