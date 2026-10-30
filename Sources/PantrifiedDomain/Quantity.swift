import Foundation

/// Approximate amounts are the default; exact amounts are optional. Every case is a valid saved state.
public enum Quantity: Sendable, Hashable, Codable {
    case unknown
    case full
    case aboutHalf
    case low
    case exact(Double, unit: String)
}
