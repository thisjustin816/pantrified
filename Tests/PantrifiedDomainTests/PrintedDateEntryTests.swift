import Foundation
import Testing
@testable import PantrifiedDomain

@Suite("Printed dates entered by day")
struct PrintedDateEntryTests {
    private func components(_ date: Date, in zone: String) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar.dateComponents([.year, .month, .day, .hour], from: date)
    }

    @Test("a real day is kept with its label, at noon UTC")
    func realDay() throws {
        let printed = try #require(PrintedDate.onDay(.useBy, year: 2026, month: 11, day: 2))

        #expect(printed.label == .useBy)
        let utc = components(printed.date, in: "UTC")
        #expect((utc.year, utc.month, utc.day, utc.hour) == (2026, 11, 2, 12))
    }

    @Test("the day is the same in every time zone from UTC-11 to UTC+11", arguments: [
        "Pacific/Pago_Pago", "Pacific/Honolulu", "America/Los_Angeles", "America/New_York", "UTC",
        "Europe/Berlin", "Asia/Kolkata", "Asia/Tokyo", "Pacific/Noumea",
    ])
    func sameDayInEveryUsualZone(zone: String) throws {
        let printed = try #require(PrintedDate.onDay(.bestBy, year: 2026, month: 11, day: 2))

        let local = components(printed.date, in: zone)
        #expect((local.year, local.month, local.day) == (2026, 11, 2))
    }

    @Test("a day that does not exist, or is outside 2000 to 2099, is refused", arguments: [
        (2026, 2, 30), (2027, 2, 29), (2026, 13, 1), (2026, 0, 10), (2026, 4, 31), (2026, 6, 0), (1999, 12, 31), (2100, 1, 1),
    ])
    func impossibleDays(year: Int, month: Int, day: Int) {
        #expect(PrintedDate.onDay(.useBy, year: year, month: month, day: day) == nil)
    }

    @Test("the edges of the range and a leap day are accepted")
    func edges() {
        #expect(PrintedDate.onDay(.useBy, year: 2000, month: 1, day: 1) != nil)
        #expect(PrintedDate.onDay(.useBy, year: 2099, month: 12, day: 31) != nil)
        #expect(PrintedDate.onDay(.useBy, year: 2028, month: 2, day: 29) != nil)
    }

    @Test("it is the same date the parser reads from the same text")
    func matchesTheParser() throws {
        let readings = PrintedDateParser().parse("USE BY 2026-11-02")
        let reading = try #require(PrintedDateParser.preferred(readings))
        guard case .resolved(let parsed, _) = reading.value else { Issue.record("not resolved"); return }

        #expect(PrintedDate.onDay(reading.label, year: 2026, month: 11, day: 2)?.date == parsed)
    }
}
