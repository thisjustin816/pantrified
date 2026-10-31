import Foundation
import Testing
@testable import Pantrified

@Suite("Lookup text")
struct LookupTextTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("a pause reads as roughly how long is left", arguments: [
        (1.0, "about a minute"),
        (60.0, "about a minute"),
        (61.0, "about 2 minutes"),
        (9 * 60.0, "about 9 minutes"),
        (40 * 60.0, "about 40 minutes"),
        (37 * 60.0, "about 35 minutes"),
        (54 * 60.0, "about 55 minutes"),
        (55 * 60.0, "about an hour"),
        (60 * 60.0, "about an hour"),
        (89 * 60.0, "about an hour"),
        (90 * 60.0, "about 2 hours"),
        (24 * 3_600.0, "about 24 hours"),
    ])
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
