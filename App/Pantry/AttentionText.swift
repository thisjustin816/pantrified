import Foundation
import PantrifiedApplication
import PantrifiedDomain

/// The words for what needs attention and why. Wording stays with the facts: a date or a source,
/// never a claim that food is safe or unsafe.
enum AttentionText {
    static func badge(_ state: AttentionState) -> String? {
        switch state {
        case .pastGuidance: "Past guidance"
        case .useSoon: "Use soon"
        case .fine, .unknown: nil
        }
    }

    static func label(_ label: PrintedDateLabel) -> String {
        switch label {
        case .useBy: "Use by"
        case .bestBy: "Best by"
        case .sellBy: "Sell by"
        case .freezeBy: "Freeze by"
        case .packed: "Packed"
        case .unlabeled: "Dated"
        }
    }

    /// A printed date as the calendar day it names. Printed dates are stored at noon UTC, so they
    /// are shown in UTC; the device's time zone never changes the day on screen.
    static func day(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: TimeZone(identifier: "UTC") ?? .gmt))
    }

    /// The fact the attention date rests on: the printed date when that is the earliest, otherwise
    /// the package's own instruction or the sourced guidance.
    static func reason(for assessment: AttentionAssessment) -> String? {
        let printed = assessment.basis.first {
            if case .printedDate(_, let date) = $0 { date == assessment.attentionDate } else { false }
        }
        let other = assessment.basis.first {
            if case .printedDate = $0 { false } else { true }
        }
        guard let basis = printed ?? other ?? assessment.basis.first else { return nil }
        switch basis {
        case .printedDate(let label, let date):
            return "\(Self.label(label)) \(day(date))"
        case .packageInstruction(let days, let anchor):
            return "Package says use within \(daysText(days)) of \(anchorPhrase(anchor))"
        case .guidance(let provenance, let days, let anchor):
            return "\(provenance.source): about \(daysText(days)) after \(anchorPhrase(anchor))"
        }
    }

    /// The line under a food's name: where it is, then why it is flagged or what it is dated.
    static func detail(for entry: PantryEntry, showsLocation: Bool) -> String {
        var parts: [String] = []
        if showsLocation { parts.append(entry.locationName ?? "Somewhere else") }
        if let reason = reason(for: entry.assessment) { parts.append(reason) }
        return parts.joined(separator: " · ")
    }

    private static func daysText(_ days: Int) -> String {
        days == 1 ? "1 day" : "\(days) days"
    }

    private static func anchorPhrase(_ anchor: WindowAnchor) -> String {
        switch anchor {
        case .added: "adding it"
        case .opened: "opening"
        case .thawed: "thawing"
        }
    }
}
