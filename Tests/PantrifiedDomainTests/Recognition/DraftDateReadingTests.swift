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

private func draft() -> PackageDraft {
    PackageDraft(spaceID: SpaceID())
}

@Suite("Draft date readings")
struct DraftDateReadingTests {
    @Test("a resolved reading is proposed with its label as a recognized value")
    func resolved() {
        var draft = draft()
        draft.apply(parser.parse("BEST BY 2026-12-05"))

        #expect(draft.printedDate.value == PrintedDate(label: .bestBy, date: day(2026, 12, 5)))
        #expect(draft.printedDate.source == .recognized)
        #expect(draft.pendingDateChoice == nil)
    }

    @Test("an ambiguous reading proposes no date and waits for the person's choice")
    func ambiguous() throws {
        var draft = draft()
        draft.apply(parser.parse("USE BY 05/06/26"))

        #expect(draft.printedDate.value == nil)
        let choice = try #require(draft.pendingDateChoice)
        #expect(choice.label == .useBy)
        #expect(choice.monthFirst == day(2026, 5, 6))
        #expect(choice.dayFirst == day(2026, 6, 5))
    }

    @Test("choosing an order confirms that date and clears the question")
    func choosing() {
        var monthFirst = draft()
        monthFirst.apply(parser.parse("USE BY 05/06/26"))
        monthFirst.chooseDateOrder(.monthFirst)

        #expect(monthFirst.printedDate.value == PrintedDate(label: .useBy, date: day(2026, 5, 6)))
        #expect(monthFirst.printedDate.source == .userConfirmed)
        #expect(monthFirst.pendingDateChoice == nil)

        var dayFirst = draft()
        dayFirst.apply(parser.parse("USE BY 05/06/26"))
        dayFirst.chooseDateOrder(.dayFirst)

        #expect(dayFirst.printedDate.value?.date == day(2026, 6, 5))
    }

    @Test("choosing with nothing pending does nothing")
    func chooseNothing() {
        var draft = draft()
        draft.chooseDateOrder(.monthFirst)

        #expect(draft.printedDate.value == nil)
        #expect(draft.printedDate.source == nil)
    }

    @Test("an unknown order cannot settle the choice")
    func unknownOrder() {
        var draft = draft()
        draft.apply(parser.parse("USE BY 05/06/26"))
        draft.chooseDateOrder(.unknown)

        #expect(draft.pendingDateChoice != nil)
        #expect(draft.printedDate.value == nil)
    }

    @Test("a date the person confirmed or cleared is never replaced by a later reading")
    func confirmedWins() {
        var confirmed = draft()
        confirmed.printedDate.confirm(PrintedDate(label: .useBy, date: day(2027, 1, 1)))
        confirmed.apply(parser.parse("BEST BY 2026-12-05"))

        #expect(confirmed.printedDate.value?.date == day(2027, 1, 1))

        var cleared = draft()
        cleared.printedDate.confirm(nil)
        cleared.apply(parser.parse("BEST BY 2026-12-05"))

        #expect(cleared.printedDate.value == nil)
    }

    @Test("a date the person entered settles any pending question")
    func enteredDateClearsQuestion() {
        var draft = draft()
        draft.apply(parser.parse("USE BY 05/06/26"))
        draft.printedDate.confirm(PrintedDate(label: .useBy, date: day(2026, 5, 6)))

        #expect(draft.pendingDateChoice == nil)
    }

    @Test("a later resolved reading replaces a pending question")
    func laterResolved() {
        var draft = draft()
        draft.apply(parser.parse("USE BY 05/06/26"))
        draft.apply(parser.parse("USE BY 2026-06-05"))

        #expect(draft.pendingDateChoice == nil)
        #expect(draft.printedDate.value?.date == day(2026, 6, 5))
    }

    @Test("with several dates the preferred label is proposed")
    func preferredLabel() {
        var draft = draft()
        draft.apply(parser.parse("PACKED 2026-11-01 BEST BY 2026-12-05"))

        #expect(draft.printedDate.value == PrintedDate(label: .bestBy, date: day(2026, 12, 5)))
    }

    @Test("text with no date changes nothing")
    func noDate() {
        var draft = draft()
        draft.apply(parser.parse("NET WT 12 OZ"))

        #expect(draft.printedDate.value == nil)
        #expect(draft.printedDate.source == nil)
        #expect(draft.pendingDateChoice == nil)
    }

    @Test("an unresolved question never blocks put-away")
    func notBlocking() {
        var draft = draft()
        draft.name.confirm("Yogurt")
        draft.location = LocationID()
        draft.apply(parser.parse("USE BY 05/06/26"))

        #expect(draft.readiness == .ready)
    }

    @Test("a month and year proposes the last day of that month")
    func monthOnly() {
        var draft = draft()
        draft.apply(parser.parse("BEST BY DEC 2026"))

        #expect(draft.printedDate.value?.date == day(2026, 12, 31))
    }
}
