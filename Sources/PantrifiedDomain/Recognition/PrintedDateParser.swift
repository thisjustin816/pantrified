import Foundation

public enum DatePrecision: Sendable, Hashable {
    case day
    /// Only the month and year were printed; the date is the last day of that month.
    case month
}

/// The order of the first two parts of a numeric date, when the package or locale says.
public enum DateOrderHint: Sendable, Hashable {
    case unknown
    case monthFirst
    case dayFirst
}

public enum PrintedDateValue: Sendable, Hashable {
    case resolved(Date, DatePrecision)
    /// A numeric date that reads two ways. Neither is chosen; the person confirms one.
    case ambiguous(monthFirst: Date, dayFirst: Date)
}

public struct PrintedDateReading: Sendable, Hashable {
    public let label: PrintedDateLabel
    public let value: PrintedDateValue
    /// The text the reading came from, as normalized for matching.
    public let text: String

    public init(label: PrintedDateLabel, value: PrintedDateValue, text: String) {
        self.label = label
        self.value = value
        self.text = text
    }
}

/// Reads printed dates and their labels out of recognized text. Recognition only proposes: a date
/// that could mean two things is reported as ambiguous and never chosen silently.
public struct PrintedDateParser: Sendable {
    private let calendar: Calendar

    public init(calendar: Calendar = PrintedDateParser.utcCalendar) {
        self.calendar = calendar
    }

    public static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    public func parse(_ text: String, hint: DateOrderHint = .unknown) -> [PrintedDateReading] {
        let normalized = Self.correctedDigits(
            text.uppercased().replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        )
        let labels = Self.labelMatches(in: normalized)

        var taken: [NSRange] = []
        var found: [(range: NSRange, value: PrintedDateValue)] = []
        for pattern in Self.datePatterns {
            for match in pattern.regex.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) {
                guard !taken.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
                let parts = (1..<match.numberOfRanges).map { index -> String in
                    Range(match.range(at: index), in: normalized).map { String(normalized[$0]) } ?? ""
                }
                // A match that is not a real date still claims its text, so no other pattern can read
                // part of it, such as "04/2026" out of "31/04/2026".
                taken.append(match.range)
                if let value = value(for: pattern.kind, parts: parts, hint: hint) {
                    found.append((match.range, value))
                }
            }
        }

        return found.sorted { $0.range.location < $1.range.location }.map { item in
            let start = item.range.location
            let label = labels
                .filter { $0.end <= start && Self.isSeparator(normalized, from: $0.end, to: start) }
                .max { $0.end < $1.end }?.label ?? .unlabeled
            let text = Range(item.range, in: normalized).map { String(normalized[$0]) } ?? ""
            return PrintedDateReading(label: label, value: item.value, text: text)
        }
    }

    /// The reading to propose for a package: a use-by date first, then best-by, sell-by, freeze-by,
    /// an unlabeled date and a packed date last. Among equal labels the earliest date wins.
    public static func preferred(_ readings: [PrintedDateReading]) -> PrintedDateReading? {
        readings.min { a, b in
            let (rankA, rankB) = (rank(a.label), rank(b.label))
            return rankA != rankB ? rankA < rankB : earliest(a.value) < earliest(b.value)
        }
    }

    // MARK: Dates

    private enum Kind {
        case yearFirst, numeric, dayMonthName, monthNameDay, monthNameYear, monthYear
    }

    private struct DatePattern {
        let kind: Kind
        let regex: NSRegularExpression
    }

    private static let monthNames: [(String, Int)] = [
        ("JANUARY", 1), ("JAN", 1), ("FEBRUARY", 2), ("FEB", 2), ("MARCH", 3), ("MAR", 3), ("APRIL", 4), ("APR", 4),
        ("MAY", 5), ("JUNE", 6), ("JUN", 6), ("JULY", 7), ("JUL", 7), ("AUGUST", 8), ("AUG", 8),
        ("SEPTEMBER", 9), ("SEPT", 9), ("SEP", 9), ("OCTOBER", 10), ("OCT", 10), ("NOVEMBER", 11), ("NOV", 11),
        ("DECEMBER", 12), ("DEC", 12),
    ]
    private static let monthPattern = "(" + monthNames.map(\.0).joined(separator: "|") + ")"

    private static let datePatterns: [DatePattern] = [
        (.yearFirst, #"(?<![0-9])(\d{4})[/.\-](\d{1,2})[/.\-](\d{1,2})(?![0-9])"#),
        (.numeric, #"(?<![0-9])(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{4}|\d{2})(?![0-9])"#),
        (.dayMonthName, #"(?<![0-9])(\d{1,2})\s*"# + monthPattern + #"(?![A-Z])\.?\s*,?\s*(\d{4}|\d{2})(?![0-9])"#),
        (.monthNameDay, #"(?<![A-Z])"# + monthPattern + #"(?![A-Z])\.?\s*(\d{1,2})(?![0-9])(?:ST|ND|RD|TH)?\s*,?\s*(\d{4}|\d{2})(?![0-9])"#),
        (.monthNameYear, #"(?<![A-Z])"# + monthPattern + #"(?![A-Z])\.?\s*,?\s*(\d{4})(?![0-9])"#),
        (.monthYear, #"(?<![0-9/.\-])(\d{1,2})/(\d{4})(?![0-9])"#),
    ].compactMap { kind, pattern in
        (try? NSRegularExpression(pattern: pattern)).map { DatePattern(kind: kind, regex: $0) }
    }

    private func value(for kind: Kind, parts: [String], hint: DateOrderHint) -> PrintedDateValue? {
        switch kind {
        case .yearFirst:
            guard let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2]) else { return nil }
            return date(year, month, dayOfMonth).map { .resolved($0, .day) }
        case .numeric:
            guard let first = Int(parts[0]), let second = Int(parts[1]), let year = fullYear(parts[2]) else { return nil }
            return numeric(first, second, year, hint: hint)
        case .dayMonthName:
            guard let dayOfMonth = Int(parts[0]), let month = Self.month(parts[1]), let year = fullYear(parts[2]) else { return nil }
            return date(year, month, dayOfMonth).map { .resolved($0, .day) }
        case .monthNameDay:
            guard let month = Self.month(parts[0]), let dayOfMonth = Int(parts[1]), let year = fullYear(parts[2]) else { return nil }
            return date(year, month, dayOfMonth).map { .resolved($0, .day) }
        case .monthNameYear:
            guard let month = Self.month(parts[0]), let year = Int(parts[1]) else { return nil }
            return endOfMonth(year, month).map { .resolved($0, .month) }
        case .monthYear:
            guard let month = Int(parts[0]), let year = Int(parts[1]) else { return nil }
            return endOfMonth(year, month).map { .resolved($0, .month) }
        }
    }

    private func numeric(_ first: Int, _ second: Int, _ year: Int, hint: DateOrderHint) -> PrintedDateValue? {
        let monthFirst = date(year, first, second)
        let dayFirst = date(year, second, first)
        switch (monthFirst, dayFirst) {
        case (nil, nil):
            return nil
        case (let only?, nil), (nil, let only?):
            return .resolved(only, .day)
        case (let m?, let d?):
            if m == d || hint == .monthFirst { return .resolved(m, .day) }
            if hint == .dayFirst { return .resolved(d, .day) }
            return .ambiguous(monthFirst: m, dayFirst: d)
        }
    }

    private func fullYear(_ text: String) -> Int? {
        guard let value = Int(text) else { return nil }
        return text.count == 2 ? 2000 + value : value
    }

    /// A real calendar date between 2000 and 2099, at noon so time zones cannot move its day.
    private func date(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date? {
        guard (2000...2099).contains(year), (1...12).contains(month), dayOfMonth >= 1 else { return nil }
        let components = DateComponents(year: year, month: month, day: dayOfMonth, hour: 12)
        guard let date = calendar.date(from: components) else { return nil }
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        return check.year == year && check.month == month && check.day == dayOfMonth ? date : nil
    }

    private func endOfMonth(_ year: Int, _ month: Int) -> Date? {
        guard (2000...2099).contains(year), (1...12).contains(month),
              let first = calendar.date(from: DateComponents(year: year, month: month, day: 1, hour: 12)),
              let days = calendar.range(of: .day, in: .month, for: first)?.count else { return nil }
        return date(year, month, days)
    }

    private static func month(_ name: String) -> Int? {
        monthNames.first { $0.0 == name }?.1
    }

    // MARK: Labels

    private struct LabelMatch {
        let label: PrintedDateLabel
        let end: Int
    }

    private static let labelRegex: NSRegularExpression? = {
        let phrases = [
            #"BEST\s+IF\s+USED\s+(?:BY|BEFORE)"#, #"BEST\s+IF\s+(?:BY|BEFORE)"#, #"BEST\s+(?:BY|BEFORE)"#, #"BB"#,
            #"USE\s+(?:BY|BEFORE)"#, #"SELL\s+BY"#, #"FREEZE\s+BY"#,
            #"EXPIRATION(?:\s+DATE)?"#, #"EXPIRES?(?:\s+ON)?"#, #"EXP"#,
            #"PACKED(?:\s+ON)?"#, #"PKD"#, #"MFG"#, #"MANUFACTURED(?:\s+ON)?"#, #"PKG\s+DATE"#,
        ]
        return try? NSRegularExpression(pattern: #"(?<![A-Z0-9])(?:"# + phrases.joined(separator: "|") + #")(?![A-Z0-9])\.?"#)
    }()

    private static func labelMatches(in text: String) -> [LabelMatch] {
        guard let regex = labelRegex else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return LabelMatch(label: label(for: String(text[range])), end: match.range.location + match.range.length)
        }
    }

    private static func label(for phrase: String) -> PrintedDateLabel {
        if phrase.hasPrefix("BEST") || phrase.hasPrefix("BB") { return .bestBy }
        if phrase.hasPrefix("USE") || phrase.hasPrefix("EXP") { return .useBy }
        if phrase.hasPrefix("SELL") { return .sellBy }
        if phrase.hasPrefix("FREEZE") { return .freezeBy }
        return .packed
    }

    private static func isSeparator(_ text: String, from start: Int, to end: Int) -> Bool {
        guard start <= end, let range = Range(NSRange(location: start, length: end - start), in: text) else { return false }
        return text[range].allSatisfy { $0 == " " || $0 == ":" || $0 == "." || $0 == "-" }
    }

    // MARK: OCR digits

    private static let numericToken = try? NSRegularExpression(
        pattern: #"(?<![A-Z0-9])[0-9OIL]{1,4}[/.\-][0-9OIL]{1,4}[/.\-][0-9OIL]{2,4}(?![A-Z0-9])"#
    )

    /// Recognition often reads a 0 as O and a 1 as I or L. Inside a token shaped like a numeric date
    /// that has at least one real digit, those letters are read as the digits.
    private static func correctedDigits(_ text: String) -> String {
        guard let regex = numericToken else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let token = String(result[range])
            guard token.contains(where: \.isNumber) else { continue }
            let fixed = String(token.map { character -> Character in
                switch character {
                case "O": "0"
                case "I", "L": "1"
                default: character
                }
            })
            result.replaceSubrange(range, with: fixed)
        }
        return result
    }

    // MARK: Preference

    private static func rank(_ label: PrintedDateLabel) -> Int {
        switch label {
        case .useBy: 0
        case .bestBy: 1
        case .sellBy: 2
        case .freezeBy: 3
        case .unlabeled: 4
        case .packed: 5
        }
    }

    private static func earliest(_ value: PrintedDateValue) -> Date {
        switch value {
        case .resolved(let date, _): date
        case .ambiguous(let monthFirst, let dayFirst): min(monthFirst, dayFirst)
        }
    }
}
