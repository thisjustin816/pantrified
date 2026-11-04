import SwiftUI
import UIKit

/// How the app moves and answers a touch, in one place so every screen feels the same.
@MainActor
enum Motion {
    /// The spring lists and banners settle with.
    static let settle = Animation.spring(duration: 0.45, bounce: 0.3)
    /// The short spring a card dropped in a place settles with.
    static let drop = Animation.spring(duration: 0.3, bounce: 0.2)

    /// Makes the change inside `animation`, so rows and banners move instead of jumping. A banner in
    /// a safe area inset ignores an `.animation` modifier on the screen, so the animation has to
    /// start where the change is made. With Reduce Motion on, the change is immediate.
    static func animated(_ animation: Animation = settle, _ change: () -> Void) {
        if UIAccessibility.isReduceMotionEnabled {
            change()
        } else {
            withAnimation(animation, change)
        }
    }

    /// A light tap, for something the person did that took effect.
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
