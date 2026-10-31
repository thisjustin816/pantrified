import Foundation
import PantrifiedDomain

/// The words for how much of a food is left. Unknown has no words: the list says nothing rather
/// than "unknown".
enum QuantityText {
    static func label(_ quantity: Quantity) -> String? {
        switch quantity {
        case .unknown:
            return nil
        case .full:
            return "Full"
        case .aboutHalf:
            return "About half"
        case .low:
            return "Almost gone"
        case .exact(let amount, let unit):
            let number = amount.formatted(.number.precision(.fractionLength(0...2)))
            return unit.isEmpty ? number : "\(number) \(unit)"
        }
    }
}
