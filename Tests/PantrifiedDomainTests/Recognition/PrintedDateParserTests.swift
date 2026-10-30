import Foundation
import Testing
@testable import PantrifiedDomain

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
    DateComponents(calendar: utc, year: year, month: month, day: day, hour: 12).date!
}

private let parser = PrintedDateParser(calendar: utc)

private func resolved(_ readings: [PrintedDateReading]) -> [(PrintedDateLabel, Date, DatePrecision)] {
    readings.compactMap { reading in
        if case .resolved(let date, let precision) = reading.value { (reading.label, date, precision) } else { nil }
    }
}

@Suite("Printed date labels")
struct PrintedDateLabelTests {
    @Test("label phrases map to the label they mean", arguments: [
        ("BEST BY 2026-12-05", PrintedDateLabel.bestBy),
        ("Best Before 2026-12-05", .bestBy),
        ("BEST IF USED BY 2026-12-05", .bestBy),
        ("BEST IF USED BEFORE 2026-12-05", .bestBy),
        ("BB 2026-12-05", .bestBy),
        ("USE BY 2026-12-05", .useBy),
        ("USE BEFORE 2026-12-05", .useBy),
        ("EXP 2026-12-05", .useBy),
        ("EXP. 2026-12-05", .useBy),
        ("EXPIRES 2026-12-05", .useBy),
        ("EXPIRATION DATE 2026-12-05", .useBy),
        ("SELL BY 2026-12-05", .sellBy),
        ("FREEZE BY 2026-12-05", .freezeBy),
        ("PACKED ON 2026-12-05", .packed),
        ("PKD 2026-12-05", .packed),
        ("MFG 2026-12-05", .packed),
        ("2026-12-05", .unlabeled),
    ])
    func labels(text: String, label: PrintedDateLabel) {
        let readings = resolved(parser.parse(text))

        #expect(readings.count == 1)
        #expect(readings.first?.0 == label)
        #expect(readings.first?.1 == day(2026, 12, 5))
    }

    @Test("a colon, dash or extra space between the label and the date is fine")
    func separators() {
        for text in ["BEST BY: 2026-12-05", "BEST BY - 2026-12-05", "BEST  BY   2026-12-05", "best by:2026-12-05"] {
            #expect(resolved(parser.parse(text)).first?.0 == .bestBy)
        }
    }

    @Test("a label that merely appears inside a word is not a label")
    func notInsideWords() {
        let readings = resolved(parser.parse("NUBBIN 2026-12-05"))

        #expect(readings.first?.0 == .unlabeled)
    }

    @Test("each date takes the label directly before it")
    func twoDates() {
        let readings = resolved(parser.parse("PACKED 11/01/2026 BEST BY 12/05/2026", hint: .monthFirst))

        #expect(readings.map(\.0) == [.packed, .bestBy])
        #expect(readings.map(\.1) == [day(2026, 11, 1), day(2026, 12, 5)])
    }

    @Test("a label on another line still applies when the date follows it")
    func lineBreak() {
        let readings = resolved(parser.parse("USE BY\n2026-12-05"))

        #expect(readings.first?.0 == .useBy)
    }
}

@Suite("Printed date formats")
struct PrintedDateFormatTests {
    @Test("dates that cannot be read two ways resolve", arguments: [
        ("2026-12-05", 2026, 12, 5),
        ("2026/12/05", 2026, 12, 5),
        ("2026.12.05", 2026, 12, 5),
        ("12/25/2026", 2026, 12, 25),
        ("25/12/2026", 2026, 12, 25),
        ("12/25/26", 2026, 12, 25),
        ("05/05/26", 2026, 5, 5),
        ("DEC 05 2026", 2026, 12, 5),
        ("DEC 5, 2026", 2026, 12, 5),
        ("DECEMBER 5 2026", 2026, 12, 5),
        ("Dec. 5th, 2026", 2026, 12, 5),
        ("05 DEC 2026", 2026, 12, 5),
        ("5DEC26", 2026, 12, 5),
        ("05DEC2026", 2026, 12, 5),
        ("5 Sept 2026", 2026, 9, 5),
        ("29 FEB 2028", 2028, 2, 29),
    ])
    func unambiguous(text: String, year: Int, month: Int, dayOfMonth: Int) {
        let readings = resolved(parser.parse(text))

        #expect(readings.count == 1)
        #expect(readings.first?.1 == day(year, month, dayOfMonth))
        #expect(readings.first?.2 == .day)
    }

    @Test("a month and year is read as the last day of the month and marked as month precision")
    func monthOnly() {
        for text in ["BEST BY DEC 2026", "BEST BY DECEMBER 2026", "12/2026"] {
            let readings = resolved(parser.parse(text))

            #expect(readings.first?.1 == day(2026, 12, 31))
            #expect(readings.first?.2 == .month)
        }
        #expect(resolved(parser.parse("FEB 2028")).first?.1 == day(2028, 2, 29))
    }

    @Test("a month and a two-digit number is not read as a date, since it could be a day or a year")
    func monthAndTwoDigits() {
        #expect(parser.parse("DEC 26").isEmpty)
    }

    @Test("impossible dates are rejected", arguments: [
        "2026-13-05", "2026-02-30", "31/04/2026", "00/12/2026", "12/00/2026", "2026-00-10", "30 FEB 2026",
        "12/32/2026", "1999-12-05", "2100-01-01",
    ])
    func impossible(text: String) {
        #expect(parser.parse(text, hint: .monthFirst).isEmpty)
        #expect(parser.parse(text, hint: .dayFirst).isEmpty)
    }

    @Test("text with no date has no readings", arguments: ["", "   ", "NET WT 12 OZ", "LOT 4521A", "BEST BY", "12345"])
    func noDate(text: String) {
        #expect(parser.parse(text).isEmpty)
    }

    @Test("the tail of a part or reference number is not a month and year")
    func notATail() {
        #expect(parser.parse("REF A-12/2026").isEmpty)
        #expect(parser.parse("SKU.12/2026").isEmpty)
    }

    @Test("a date inside other text is found")
    func embedded() {
        let readings = resolved(parser.parse("Organic Milk 1 GAL  BEST BY 2026-12-05  UPC 0123456"))

        #expect(readings.count == 1)
        #expect(readings.first?.1 == day(2026, 12, 5))
    }

    @Test("lower case and mixed case are read")
    func caseInsensitive() {
        #expect(resolved(parser.parse("best by dec 5 2026")).first?.1 == day(2026, 12, 5))
    }
}

@Suite("Ambiguous numeric dates")
struct AmbiguousDateTests {
    @Test("05/06/26 could be May 6 or June 5, so it is not resolved")
    func ambiguous() throws {
        let reading = try #require(parser.parse("BEST BY 05/06/26").first)

        #expect(reading.label == .bestBy)
        #expect(reading.value == .ambiguous(monthFirst: day(2026, 5, 6), dayFirst: day(2026, 6, 5)))
    }

    @Test("a hint from the package or locale resolves it")
    func hints() {
        #expect(resolved(parser.parse("05/06/26", hint: .monthFirst)).first?.1 == day(2026, 5, 6))
        #expect(resolved(parser.parse("05/06/26", hint: .dayFirst)).first?.1 == day(2026, 6, 5))
    }

    @Test("a part above 12 settles the order whatever the hint")
    func partAbove12() {
        #expect(resolved(parser.parse("13/06/26", hint: .monthFirst)).first?.1 == day(2026, 6, 13))
        #expect(resolved(parser.parse("06/13/26", hint: .dayFirst)).first?.1 == day(2026, 6, 13))
    }

    @Test("a reading valid in only one order resolves to it")
    func oneValidOrder() {
        #expect(resolved(parser.parse("31/04/2026")).isEmpty)
        #expect(resolved(parser.parse("04/31/2026")).isEmpty)
        #expect(resolved(parser.parse("02/30/2026")).isEmpty)
        #expect(resolved(parser.parse("30/11/2026")).first?.1 == day(2026, 11, 30))
    }

    @Test("a year first date is never ambiguous")
    func yearFirst() {
        #expect(resolved(parser.parse("2026-05-06")).first?.1 == day(2026, 5, 6))
    }

    @Test("an ambiguous reading keeps its label alongside resolved ones")
    func mixed() {
        let readings = parser.parse("PACKED 2026-11-01 BEST BY 05/06/26")

        #expect(readings.count == 2)
        #expect(resolved(readings).map(\.0) == [.packed])
        #expect(readings.last?.label == .bestBy)
    }
}

@Suite("OCR noise")
struct OCRNoiseTests {
    @Test("a letter O or I standing for a digit inside a date is read as the digit", arguments: [
        ("O5/12/2026", 2026, 5, 12),
        ("2026-1O-05", 2026, 10, 5),
        ("12/O5/2026", 2026, 12, 5),
        ("l2/25/2026", 2026, 12, 25),
    ])
    func digits(text: String, year: Int, month: Int, dayOfMonth: Int) {
        #expect(resolved(parser.parse(text, hint: .monthFirst)).first?.1 == day(year, month, dayOfMonth))
    }

    @Test("a word is not turned into digits")
    func wordsUntouched() {
        #expect(parser.parse("OLIVE OIL").isEmpty)
        #expect(parser.parse("ONION 12 OZ").isEmpty)
    }
}

@Suite("Choosing a date to propose")
struct PrintedDateChoiceTests {
    private func reading(_ label: PrintedDateLabel, _ date: Date) -> PrintedDateReading {
        PrintedDateReading(label: label, value: .resolved(date, .day), text: "")
    }

    @Test("a use-by date is preferred over a best-by, a sell-by and a packed date")
    func priority() {
        let readings = [
            reading(.packed, day(2026, 11, 1)), reading(.sellBy, day(2026, 12, 1)),
            reading(.bestBy, day(2026, 12, 10)), reading(.useBy, day(2026, 12, 5)),
        ]

        #expect(PrintedDateParser.preferred(readings)?.label == .useBy)
    }

    @Test("a best-by comes before a sell-by, a freeze-by, an unlabeled and a packed date")
    func order() {
        let labels: [PrintedDateLabel] = [.bestBy, .sellBy, .freezeBy, .unlabeled, .packed]
        let readings = labels.reversed().map { reading($0, day(2026, 12, 5)) }

        #expect(PrintedDateParser.preferred(readings)?.label == .bestBy)
        #expect(PrintedDateParser.preferred(readings.filter { $0.label != .bestBy })?.label == .sellBy)
    }

    @Test("among readings with the same label the earliest date wins")
    func earliest() {
        let readings = [reading(.useBy, day(2026, 12, 9)), reading(.useBy, day(2026, 12, 2))]

        #expect(PrintedDateParser.preferred(readings)?.value == .resolved(day(2026, 12, 2), .day))
    }

    @Test("no readings means nothing to prefer")
    func none() {
        #expect(PrintedDateParser.preferred([]) == nil)
    }
}
