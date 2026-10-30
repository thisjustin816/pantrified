import Foundation

/// Approximate amounts are the default; exact amounts are optional. Every case is a valid saved state.
public enum Quantity: Sendable, Hashable, Codable {
    case unknown
    case full
    case aboutHalf
    case low
    case exact(Double, unit: String)
}

public struct UsedSomeResult: Sendable, Hashable {
    public var quantity: Quantity
    /// True when the amount could not be adjusted and the user should correct it.
    public var needsCorrection: Bool
}

extension Quantity {
    /// "Used some" never infers an exact amount: approximate levels step down once, unknown stays
    /// unknown, and an exact amount is left as it is and flagged.
    public var afterUsingSome: UsedSomeResult {
        switch self {
        case .full: UsedSomeResult(quantity: .aboutHalf, needsCorrection: false)
        case .aboutHalf, .low: UsedSomeResult(quantity: .low, needsCorrection: false)
        case .unknown: UsedSomeResult(quantity: .unknown, needsCorrection: false)
        case .exact: UsedSomeResult(quantity: self, needsCorrection: true)
        }
    }
}
