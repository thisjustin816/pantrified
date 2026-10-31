import Foundation
import Testing
@testable import Pantrified

@Suite("Lookup text")
struct LookupTextTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static let durations: [(TimeInterval, String)] = [
        (0, "about a minute"),
        (1, "about a minute"),
        (60, "about a minute"),
        (61, "about 2 minutes"),
        (9 * 60, "about 9 minutes"),
        (40 * 60, "about 40 minutes"),
        (37 * 60, "about 35 minutes"),
        (54 * 60, "about 55 minutes"),
        (55 * 60, "about an hour"),
        (60 * 60, "about an hour"),
        (89 * 60, "about an hour"),
        (90 * 60, "about 2 hours"),
        (24 * 3_600, "about 24 hours"),
    ]

    @Test("a pause reads as roughly how long is left", arguments: durations)
    func duration(seconds: TimeInterval, expected: String) {
        #expect(LookupText.duration(seconds) == expected)
    }

    @Test("the note names the pause and how to carry on")
    func note() {
        #expect(LookupText.paused(until: now.addingTimeInterval(40 * 60), now: now)
            == "Name lookups are paused for about 40 minutes. Enter a name to add it now, or scan it again later.")
    }

    @Test("without a time still to come, the note says only that lookups are paused")
    func noTime() {
        let expected = "Name lookups are paused for now. Enter a name to add it now, or scan it again later."
        #expect(LookupText.paused(until: nil, now: now) == expected)
        #expect(LookupText.paused(until: now, now: now) == expected)
        #expect(LookupText.paused(until: now.addingTimeInterval(-5), now: now) == expected)
    }
}
