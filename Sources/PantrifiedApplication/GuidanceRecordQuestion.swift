import Foundation
import PantrifiedDomain

/// Which record of the sourced storage guidance a food's guidance comes from, and the records a
/// person could choose instead. A food's detail screen builds its "Which FoodKeeper food is this?"
/// row and picker from it.
public struct GuidanceRecordQuestion: Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        /// Matched without a choice for this package: by its name, or by a link confirmed for the
        /// name.
        case matched(GuidanceRecord)
        /// The person chose this record for this package.
        case chosen(GuidanceRecord)
        /// The person said none of the records offered is this food, so it has no sourced guidance.
        case declined
        /// The person chose a record this snapshot no longer holds as it was. The food has no
        /// sourced guidance until the person chooses again or clears the choice.
        case chosenRecordMissing(GuidanceRecordReference)
        /// Several records share the food's name, or none has it, and nothing has been chosen.
        case unanswered
    }

    /// How the detail screen raises the question.
    public enum Prompt: Sendable, Hashable {
        /// Ask which record the food is: a choice is needed before the food can have guidance.
        case ask
        /// Show what the guidance comes from, with a way to change it.
        case review
        /// Say nothing: there is no record to choose from and no choice to clear.
        case hidden
    }

    public let status: Status
    /// The records offered, most likely first. The record the food uses now is always among them.
    public let candidates: [GuidanceRecord]
    /// Where the records come from, such as "USDA FSIS FoodKeeper".
    public let source: String

    public init(status: Status, candidates: [GuidanceRecord], source: String) {
        self.status = status
        self.source = source
        switch status {
        case .matched(let current), .chosen(let current):
            self.candidates = candidates.contains(current) ? candidates : [current] + candidates
        case .declined, .chosenRecordMissing, .unanswered:
            self.candidates = candidates
        }
    }

    public var prompt: Prompt {
        switch status {
        case .matched, .chosen, .declined: .review
        case .chosenRecordMissing: .ask
        case .unanswered: candidates.isEmpty ? .hidden : .ask
        }
    }

    /// What picking `record` records about the food.
    public func choice(for record: GuidanceRecord) -> GuidanceChoice {
        .record(GuidanceRecordReference(record, source: source))
    }

    /// Whether `record` is the one the food's guidance comes from now.
    public func isCurrent(_ record: GuidanceRecord) -> Bool {
        switch status {
        case .matched(let current), .chosen(let current): current == record
        case .declined, .chosenRecordMissing, .unanswered: false
        }
    }

    /// Whether the person said none of the records is this food.
    public var isDeclined: Bool { status == .declined }

    /// Whether the person has made a choice for this food that they could clear, so its guidance
    /// is matched by name again.
    public var canClear: Bool {
        switch status {
        case .chosen, .declined, .chosenRecordMissing: true
        case .matched, .unanswered: false
        }
    }
}
