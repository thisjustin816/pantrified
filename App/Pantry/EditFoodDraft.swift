import Foundation
import PantrifiedApplication
import PantrifiedDomain

/// The form state for editing one food, and the edit it amounts to. A field the person did not
/// change stays out of the edit, so saving an untouched form changes nothing and writes nothing.
struct EditFoodDraft: Equatable {
    var name: String
    var quantity: Quantity
    var hasDate: Bool
    var label: PrintedDateLabel
    /// The calendar day of the date on the package, as a date in the device's time zone.
    var day: Date

    private let originalName: String
    private let originalQuantity: Quantity
    private let originalDate: PrintedDate?

    /// Printed dates are stored at noon UTC and name a calendar day, so the day is read in UTC and
    /// shown in the device's calendar, and the form gives the same day back.
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    init(package: Package, now: Date = Date(), calendar: Calendar = .current) {
        name = package.name
        quantity = package.quantity
        originalName = package.name
        originalQuantity = package.quantity
        originalDate = package.printedDate
        hasDate = package.printedDate != nil
        label = package.printedDate?.label ?? .useBy
        if let printed = package.printedDate {
            let parts = Self.utc.dateComponents([.year, .month, .day], from: printed.date)
            day = calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: 12)) ?? now
        } else {
            day = now
        }
    }

    /// The choices for how much: the usual ones, and the food's own amount when it is an exact one.
    var quantityChoices: [Quantity] {
        var choices: [Quantity] = [.unknown, .full, .aboutHalf, .low]
        if !choices.contains(originalQuantity) { choices.append(originalQuantity) }
        return choices
    }

    /// The date labels the form offers: the usual ones, and the food's own when it is another.
    var labelChoices: [PrintedDateLabel] {
        var choices: [PrintedDateLabel] = [.useBy, .bestBy, .sellBy, .freezeBy, .packed]
        if let original = originalDate?.label, !choices.contains(original) { choices.append(original) }
        return choices
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The date on the package as the form shows it now, or nil when there is none or the day is invalid.
    private func printedDate(calendar: Calendar) -> PrintedDate? {
        guard hasDate else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return PrintedDate.onDay(label, year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }

    func edit(calendar: Calendar = .current) -> PackageEdit {
        var edit = PackageEdit()
        if trimmedName != originalName { edit.name = .set(name) }
        if quantity != originalQuantity { edit.quantity = .set(quantity) }
        // A date the form cannot read as a real day is left as it was, never cleared.
        if !hasDate || printedDate(calendar: calendar) != nil {
            let date = printedDate(calendar: calendar)
            if date != originalDate { edit.printedDate = .set(date) }
        }
        return edit
    }

    /// A name is needed, and something must have changed.
    func canSave(calendar: Calendar = .current) -> Bool {
        !trimmedName.isEmpty && edit(calendar: calendar) != PackageEdit()
    }
}
