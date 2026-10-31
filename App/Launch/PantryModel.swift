import Foundation
import Observation
import SwiftUI
import UIKit
import PantrifiedApplication
import PantrifiedDomain

/// What the Today and Food screens show and do for one Space. All rules live in `Pantry`; this
/// holds the last result, the one message to show and the undo that is still on offer.
@MainActor
@Observable
final class PantryModel {
    struct UndoPrompt: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let token: UndoToken
        /// How long the offer stays, so the banner can show the time running out.
        let window: Duration
    }

    private(set) var snapshot: PantrySnapshot?
    /// A failure to tell the person about, once.
    private(set) var problem: String?
    private(set) var undoPrompt: UndoPrompt?

    private let pantry: Pantry
    private let undoWindow: Duration
    private var undoExpiry: Task<Void, Never>?
    /// Nil when product lookup is off, such as in a build without a FoodData Central key.
    private let lookup: (any ProductLookupService)?
    /// Batch intake, or nil when its staging folder could not be opened.
    let intake: IntakeServices?

    init(
        pantry: Pantry,
        undoWindow: Duration = .seconds(8),
        lookup: (any ProductLookupService)? = nil,
        intake: IntakeServices? = nil
    ) {
        self.pantry = pantry
        self.undoWindow = undoWindow
        self.lookup = lookup
        self.intake = intake
    }

    var looksUpProducts: Bool { lookup != nil }

    /// What the product lookup suggests for a scanned barcode, or nil when lookup is off.
    func lookUp(_ barcode: GTIN) async -> ProductLookupResult? {
        await lookup?.lookUp(barcode)
    }

    func load() async {
        do {
            let fresh = try await pantry.snapshot()
            // Inside the animation, so a food that was used up, moved or put back slides out of or
            // into its list instead of jumping.
            animated { snapshot = fresh }
        } catch {
            problem = "Couldn't read your food list. Quit and open Pantrified again."
        }
    }

    /// Adds the food and returns whether it was stored.
    func add(_ food: NewFood) async -> Bool {
        do {
            try await pantry.add(food)
            await load()
            return true
        } catch PantryError.nameRequired {
            problem = "Enter a name for the food."
            return false
        } catch {
            problem = "That didn't save. Check your list, then try again."
            await load()
            return false
        }
    }

    func perform(_ action: PackageAction, on entry: PantryEntry) async {
        do {
            if case .applied(let token) = try await pantry.perform(action, on: entry.id) {
                offerUndo(Self.message(for: action, name: entry.package.name, locations: snapshot?.locations ?? []), token)
            }
        } catch {
            problem = "Couldn't do that. Your list has been refreshed."
        }
        await load()
    }

    func undo() async {
        guard let prompt = undoPrompt else { return }
        clearUndo()
        do {
            try await pantry.undo(prompt.token)
        } catch {
            problem = "Couldn't undo that. Your list has been refreshed."
        }
        await load()
    }

    func dismissProblem() { problem = nil }

    func dismissUndo() { clearUndo() }

    private func offerUndo(_ message: String, _ token: UndoToken) {
        undoExpiry?.cancel()
        let prompt = UndoPrompt(message: message, token: token, window: undoWindow)
        animated { undoPrompt = prompt }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let window = undoWindow
        undoExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled, self?.undoPrompt == prompt else { return }
            self?.animated { self?.undoPrompt = nil }
        }
    }

    private func clearUndo() {
        undoExpiry?.cancel()
        undoExpiry = nil
        animated { undoPrompt = nil }
    }

    /// Makes the change inside an animation, so the banner and the list rows move. The banner sits in
    /// a safe area inset, which ignores an `.animation` modifier on the screen, so the animation has
    /// to start where the change is made. With Reduce Motion on, the change is immediate.
    private func animated(_ change: () -> Void) {
        if UIAccessibility.isReduceMotionEnabled {
            change()
        } else {
            withAnimation(.spring(duration: 0.45, bounce: 0.3), change)
        }
    }

    static func message(for action: PackageAction, name: String, locations: [StorageLocation]) -> String {
        switch action {
        case .opened: "Marked \(name) as opened"
        case .usedUp: "\(name) used up"
        case .discard: "Discarded \(name)"
        case .move(let destination):
            "Moved \(name) to \(locations.first { $0.id == destination }?.name ?? "another place")"
        }
    }
}
