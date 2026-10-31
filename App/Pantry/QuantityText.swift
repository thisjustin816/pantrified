import Foundation
import PantrifiedDomain

/// The words for how much of a food is left. Unknown has no words: the list says nothing rather
/// than "unknown".
enum QuantityText {
    static func label(_ quantity: Quantity) -> String? {
        switch quantity {
        case .unknown: nil
        case .full: "Full"
        case .aboutHalf: "About half"
        case .low: "Almost gone"
        case .exact(let amount, let unit):
            let number = amount.formatted(.number.precision(.fractionLength(0...2)))
            unit.isEmpty ? number : "\(number) \(unit)"
        }
    }
}
