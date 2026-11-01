import Foundation
import Testing
import PantrifiedDomain

/// Noon UTC on a calendar day, as the parser stores a printed date.
private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
    PrintedDateParser.utcCalendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth, hour: 12))!
}

/// When the photos were taken.
private let now = day(2026, 10, 31)
private let recognition = PrintedDateRecognition()

private func photo(_ lines: String...) -> RecognizedLines { RecognizedLines(lines: lines) }

private func proposal(_ photos: RecognizedLines...) -> PrintedDateReading? {
    recognition.proposal(in: photos, at: now)
}

private func value(_ reading: PrintedDateReading?) -> PrintedDate? {
    guard let reading, case .resolved(let date, _) = reading.value else { return nil }
    return PrintedDate(label: reading.label, date: date)
}

private let bestByDec5 = PrintedDate(label: .bestBy, date: day(2026, 12, 5))

@Suite("Printed date recognition")
struct PrintedDateRecognitionTests {
    @Test("a label on one line and its date on the next are read together")
    func labelOnItsOwnLine() {
        #expect(value(proposal(photo("NET WT 16 OZ (454g)", "BEST BY", "DEC 05 2026", "LOT 4471"))) == bestByDec5)
    }

    @Test("with several dates in a photo the preferred one is proposed")
    func preferredInOnePhoto() {
        let reading = proposal(photo("PACKED ON 10/20/2026", "BEST BY DEC 05 2026", "USE BY 11/20/2026"))

        #expect(value(reading) == PrintedDate(label: .useBy, date: day(2026, 11, 20)))
    }

    @Test("photos of one package are read together, and the preferred date of all of them is proposed")
    func severalPhotos() {
        let reading = proposal(photo("BEST BY DEC 05 2026"), photo("USE BY 11/20/2026"))

        #expect(value(reading) == PrintedDate(label: .useBy, date: day(2026, 11, 20)))
        #expect(recognition.readings(in: [photo("BEST BY DEC 05 2026"), photo("USE BY 11/20/2026")], at: now).count == 2)
    }

    @Test("a label at the end of one photo does not label a date in the next")
    func photosReadApart() {
        let reading = proposal(photo("INGREDIENTS: MILK", "USE BY"), photo("12/25/2026"))

        #expect(reading?.label == .unlabeled)
    }

    @Test("photos after the limit are not read")
    func photoLimit() {
        let blank = Array(repeating: photo("NET WT 16 OZ"), count: PrintedDateRecognition.maxPhotos - 1)

        #expect(recognition.proposal(in: blank + [photo("BEST BY DEC 05 2026")], at: now) != nil)
        #expect(recognition.proposal(in: blank + [photo("NET WT 16 OZ"), photo("BEST BY DEC 05 2026")], at: now) == nil)
    }

    @Test("no photos, empty photos and text with no date propose nothing")
    func nothingToRead() {
        #expect(recognition.proposal(in: [], at: now) == nil)
        #expect(proposal(RecognizedLines()) == nil)
        #expect(proposal(photo("NET WT 16 OZ", "KEEP REFRIGERATED")) == nil)
    }

    @Test("an ambiguous date is returned with both readings, never chosen")
    func ambiguousIsKept() {
        let reading = proposal(photo("USE BY 05/06/27"))

        #expect(reading?.label == .useBy)
        #expect(reading?.value == .ambiguous(monthFirst: day(2027, 5, 6), dayFirst: day(2027, 6, 5)))
    }

    @Test("an order hint reaches the parser")
    func hintIsUsed() {
        let dayFirst = PrintedDateRecognition(hint: .dayFirst)

        #expect(value(dayFirst.proposal(in: [photo("USE BY 05/06/27")], at: now)) == PrintedDate(label: .useBy, date: day(2027, 6, 5)))
    }

    @Test("dates far in the past or future are not read", arguments: ["BEST BY JAN 01 2021", "BEST BY DEC 31 2040", "EXP 2099-12-31"])
    func implausibleDatesRefused(text: String) {
        #expect(proposal(photo(text)) == nil)
    }

    @Test("the plausible window holds two years back and ten years ahead")
    func plausibleWindowEdges() {
        func line(_ date: Date, plusDays: Int) -> RecognizedLines {
            let parts = PrintedDateParser.utcCalendar.dateComponents([.year, .month, .day], from: date.addingTimeInterval(Double(plusDays) * 86_400))
            return RecognizedLines(lines: [String(format: "USE BY %04d-%02d-%02d", parts.year!, parts.month!, parts.day!)])
        }
        let past = now.addingTimeInterval(-PrintedDateRecognition.plausiblePast)
        let future = now.addingTimeInterval(PrintedDateRecognition.plausibleFuture)

        #expect(proposal(line(past, plusDays: 1)) != nil)
        #expect(proposal(line(past, plusDays: -1)) == nil)
        #expect(proposal(line(future, plusDays: -1)) != nil)
        #expect(proposal(line(future, plusDays: 1)) == nil)
    }

    @Test("an implausible date does not hide a plausible one of lower preference")
    func plausibilityBeforePreference() {
        #expect(value(proposal(photo("USE BY 2001-01-01", "BEST BY DEC 05 2026"))) == bestByDec5)
    }

    @Test("an ambiguous date with one implausible reading is not read")
    func ambiguousNeedsBothPlausible() {
        // 10/11/24 is 11 October 2024, before the two-year window, or 10 November 2024, inside it.
        #expect(proposal(photo("USE BY 10/11/24")) == nil)
    }

    @Test("digits that are not plain ASCII digits are not read as a date")
    func onlyASCIIDigits() {
        #expect(proposal(photo("BEST BY \u{0661}\u{0662}/\u{0660}\u{0665}/\u{0662}\u{0660}\u{0662}\u{0666}")) == nil)
        #expect(proposal(photo("BEST BY \u{FF11}\u{FF12}/\u{FF10}\u{FF15}/\u{FF12}\u{FF10}\u{FF12}\u{FF16}")) == nil)
        #expect(proposal(photo("BEST BY DEC \u{FF10}\u{FF15} 2026")) == nil)
    }
}

@Suite("Printed date recognition on a draft")
struct PrintedDateRecognitionDraftTests {
    private func readings(_ lines: String...) -> [PrintedDateReading] {
        recognition.readings(in: [RecognizedLines(lines: lines)], at: now)
    }

    @Test("a recognized date is proposed, not confirmed")
    func proposed() {
        var draft = PackageDraft(spaceID: SpaceID())

        draft.apply(readings("BEST BY", "DEC 05 2026"))

        #expect(draft.printedDate.value == bestByDec5)
        #expect(draft.printedDate.source == .recognized)
        #expect(!draft.confirmedFields.contains(.printedDate))
    }

    @Test("a date the person confirmed or cleared is never replaced")
    func confirmedKept() {
        let own = PrintedDate(label: .useBy, date: day(2026, 11, 20))
        var confirmed = PackageDraft(spaceID: SpaceID())
        confirmed.printedDate.confirm(own)
        var cleared = PackageDraft(spaceID: SpaceID())
        cleared.printedDate.confirm(nil)

        confirmed.apply(readings("BEST BY DEC 05 2026"))
        confirmed.apply(readings("USE BY 05/06/27"))
        cleared.apply(readings("BEST BY DEC 05 2026"))

        #expect(confirmed.printedDate.value == own)
        #expect(confirmed.pendingDateChoice == nil)
        #expect(cleared.printedDate.value == nil)
        #expect(cleared.printedDate.source == .userConfirmed)
    }

    @Test("an ambiguous date becomes the draft's pending choice and proposes no date")
    func ambiguousPending() {
        var draft = PackageDraft(spaceID: SpaceID())

        draft.apply(readings("USE BY 05/06/27"))

        #expect(draft.printedDate.value == nil)
        #expect(draft.pendingDateChoice?.monthFirst == day(2027, 5, 6))
        #expect(draft.pendingDateChoice?.dayFirst == day(2027, 6, 5))
    }
}

@Suite("Recognized text limits")
struct RecognizedLinesTests {
    private static let date = "BEST BY DEC 05 2026"

    private func reads(_ text: RecognizedLines) -> Bool {
        recognition.proposal(in: [text], at: now) != nil
    }

    @Test("lines after the line limit are not looked at")
    func lineLimit() {
        let filler = Array(repeating: "NET WT 16 OZ", count: RecognizedLines.maxLines - 1)

        #expect(reads(RecognizedLines(lines: filler + [Self.date])))
        #expect(!reads(RecognizedLines(lines: filler + ["NET WT 16 OZ", Self.date])))
        #expect(RecognizedLines(lines: filler + ["NET WT 16 OZ", Self.date]).lines.count == RecognizedLines.maxLines)
    }

    @Test("dropped lines count toward the line limit")
    func droppedLinesCount() {
        let long = String(repeating: "X", count: RecognizedLines.maxLineBytes + 1)

        #expect(!reads(RecognizedLines(lines: Array(repeating: long, count: RecognizedLines.maxLines) + [Self.date])))
    }

    @Test("a line over the byte limit is dropped whole, not cut")
    func longLineDropped() {
        let padding = String(repeating: " ", count: RecognizedLines.maxLineBytes - Self.date.utf8.count)

        #expect(reads(RecognizedLines(lines: [Self.date + padding])))
        #expect(!reads(RecognizedLines(lines: [Self.date + padding + " "])))
        #expect(RecognizedLines(lines: [Self.date + padding + "1"]).lines.isEmpty)
    }

    @Test("the line limit counts UTF-8 bytes, not characters")
    func bytesNotCharacters() {
        // Each "é" is one character and two bytes, so the line is under the limit in characters
        // and over it in bytes.
        let line = Self.date + " " + String(repeating: "\u{E9}", count: RecognizedLines.maxLineBytes / 2)

        #expect(line.count <= RecognizedLines.maxLineBytes)
        #expect(!reads(RecognizedLines(lines: [line])))
    }

    @Test("a photo stops taking lines at its byte limit")
    func photoByteLimit() {
        let filler = String(repeating: "N", count: RecognizedLines.maxLineBytes)
        let fits = RecognizedLines.maxBytes / RecognizedLines.maxLineBytes
        let room = RecognizedLines.maxBytes - fits * RecognizedLines.maxLineBytes

        #expect(fits < RecognizedLines.maxLines)
        #expect(Self.date.utf8.count <= room)
        #expect(reads(RecognizedLines(lines: Array(repeating: filler, count: fits) + [Self.date])))
        #expect(!reads(RecognizedLines(lines: Array(repeating: filler, count: fits + 1) + [Self.date])))
    }

    @Test("adding reports when the photo is full, so a reader can stop")
    func addReportsFull() {
        var text = RecognizedLines()
        for _ in 0..<RecognizedLines.maxLines {
            #expect(text.add("A") == true)
        }
        #expect(text.add("A") == false)
        #expect(text.lines.count == RecognizedLines.maxLines)

        var big = RecognizedLines()
        let filler = String(repeating: "N", count: RecognizedLines.maxLineBytes)
        while big.add(filler) {}
        #expect(big.lines.joined().utf8.count <= RecognizedLines.maxBytes)
        #expect(big.add("A") == false)
    }

    @Test("empty lines are not kept")
    func emptyLines() {
        #expect(RecognizedLines(lines: ["", Self.date, ""]).lines == [Self.date])
    }
}
