import Foundation

/// What a date printed on a package claims to mean. Kept as read from the label; never rewritten
/// into a single expiration date.
public enum PrintedDateLabel: Sendable, Hashable, Codable {
    case useBy
    case bestBy
    case sellBy
    case freezeBy
    case packed
    case unlabeled
}

public struct PrintedDate: Sendable, Hashable, Codable {
    public var label: PrintedDateLabel
    public var date: Date

    public init(label: PrintedDateLabel, date: Date) {
        self.label = label
        self.date = date
    }

    /// A date the person picked by calendar day. It is stored at noon UTC, as a date read from text
    /// is, so a time zone from UTC-11 to UTC+11 keeps its day; one further ahead reads it as the next
    /// day. Nil for a day that does not exist or is outside 2000 to 2099.
    public static func onDay(_ label: PrintedDateLabel, year: Int, month: Int, day: Int) -> PrintedDate? {
        guard (2000...2099).contains(year) else { return nil }
        let calendar = PrintedDateParser.utcCalendar
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) else { return nil }
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        guard check.year == year, check.month == month, check.day == day else { return nil }
        return PrintedDate(label: label, date: date)
    }
}
