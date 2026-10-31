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

    static func printed(_ date: PrintedDate) -> String {
        "\(AttentionText.label(date.label)) \(AttentionText.day(date.date))"
    }

    /// A moment the app recorded, in the device's time zone.
    static func moment(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
