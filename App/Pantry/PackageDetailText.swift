import Foundation
import PantrifiedApplication
import PantrifiedDomain

/// The facts on a food's detail screen, as label and value pairs. A row appears only when the food has
/// that fact, apart from the ones every food has.
enum PackageDetailText {
    struct Row: Identifiable, Equatable {
        let label: String
        let value: String
        var id: String { label }
    }

    static func rows(for entry: PantryEntry, moment: (Date) -> String = PackageDetailText.moment) -> [Row] {
        let package = entry.package
        var rows = [
            Row(label: "Where", value: entry.locationName ?? "Somewhere else"),
            Row(label: "How much", value: QuantityText.label(package.quantity) ?? "Not sure"),
            Row(label: "Date on the package", value: package.printedDate.map(printed) ?? "None"),
            Row(label: "Added", value: moment(package.addedAt)),
        ]
        if let opened = package.openedAt { rows.append(Row(label: "Opened", value: moment(opened))) }
        if let frozen = package.frozenAt { rows.append(Row(label: "Frozen", value: moment(frozen))) }
        if let thawed = package.thawedAt { rows.append(Row(label: "Thawed", value: moment(thawed))) }
        return rows
    }

    /// What the sourced storage guidance says for where the food is kept now.
    struct Guidance: Equatable {
        /// Who the guidance comes from, such as "USDA FoodKeeper".
        let source: String
        let rows: [Row]
    }

    /// The windows the source gives for the storage the food is in, shortest first when it gives
    /// more than one for the same starting point, with the day the one that applies now runs to. Nil
    /// when nothing matched, the storage is unknown, or the source has no window for this storage.
    /// Guidance, not an expiration date.
    static func guidance(
        for entry: PantryEntry,
        storageType: StorageType?,
        calendar: Calendar = .current,
        day: (Date) -> String = PackageDetailText.day
    ) -> Guidance? {
        guard let guidance = entry.guidance, let storageType else { return nil }
        let order: [WindowAnchor] = [.opened, .added, .thawed]
        let windows = order.compactMap { anchor -> GuidanceWindow? in
            guidance.windows.filter { $0.storageType == storageType && $0.anchor == anchor }.min { $0.days < $1.days }
        }
        guard !windows.isEmpty else { return nil }
        var rows = windows.map { Row(label: startLabel($0.anchor), value: duration($0.days)) }
        // The window the attention check is using now, as the day it runs to.
        for case .guidance(_, let days, let anchor) in entry.assessment.basis {
            if let start = anchorDate(anchor, of: entry.package),
               let end = calendar.date(byAdding: .day, value: days, to: start) {
                rows.append(Row(label: "Guidance runs to", value: day(end)))
            }
        }
        return Guidance(source: guidance.provenance.source, rows: rows)
    }

    private static func startLabel(_ anchor: WindowAnchor) -> String {
        switch anchor {
        case .opened: "After opening"
        case .added: "Unopened"
        case .thawed: "After thawing"
        }
    }

    private static func anchorDate(_ anchor: WindowAnchor, of package: Package) -> Date? {
        switch anchor {
        case .added: package.addedAt
        case .opened: package.openedAt
        case .thawed: package.thawedAt
        }
    }

    /// "About 60 days, about 2 months". The source gives days, so the days come first.
    static func duration(_ days: Int) -> String {
        let count = days == 1 ? "1 day" : "\(days) days"
        switch days {
        case ..<60:
            return "About \(count)"
        case ..<335:
            return "About \(count), about \(Int((Double(days) / 30.4).rounded())) months"
        default:
            let years = Int((Double(days) / 365).rounded())
            return "About \(count), about \(years) \(years == 1 ? "year" : "years")"
        }
    }

    /// A calendar day the app computed, in the device's time zone.
    static func day(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    static func printed(_ date: PrintedDate) -> String {
        "\(AttentionText.label(date.label)) \(AttentionText.day(date.date))"
    }

    /// A moment the app recorded, in the device's time zone.
    static func moment(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
