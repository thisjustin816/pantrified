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
    /// Lookups are paused because the provider asked for fewer requests or its allowance ran out.
    /// No request is sent until `resumesAt`, which is nil when the provider did not say and no
    /// pacing decided it. The barcode stays with the caller, who can look it up again then.
    case rateLimited(resumesAt: Date?)
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

/// What a provider said about its request allowance alongside one answer. Each field is nil when
/// the provider said nothing usable about it.
public struct RateLimitReport: Sendable, Hashable {
    /// Requests left in the provider's current allowance.
    public var remaining: Int?
    /// How long the provider asked for no further requests, already bounded by the adapter.
    public var retryAfter: TimeInterval?

    public init(remaining: Int? = nil, retryAfter: TimeInterval? = nil) {
        self.remaining = remaining
        self.retryAfter = retryAfter
    }
}

/// One lookup's result with the rate limit report that came with it.
public struct ReportedLookup: Sendable, Hashable {
    public var result: ProductLookupResult
    public var rateLimit: RateLimitReport

    public init(_ result: ProductLookupResult, rateLimit: RateLimitReport = RateLimitReport()) {
        self.result = result
        self.rateLimit = rateLimit
    }
}

/// A product lookup that also passes on what the provider said about its rate limit, so
/// `PacedProductLookup` can pace requests and pause after a refusal.
public protocol RateLimitReportingLookup: Sendable {
    func lookUpReportingRateLimit(_ barcode: GTIN) async -> ReportedLookup
}
