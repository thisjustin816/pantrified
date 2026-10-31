import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain
@testable import PantrifiedFoodDataCentral

/// Sun, 06 Nov 1994 08:49:37 GMT.
private let now = Date(timeIntervalSince1970: 784_111_777)

@Suite("Rate limit headers")
struct RateLimitHeadersTests {
    @Test("Retry-After in seconds is read strictly and held between a second and a day", arguments: [
        ("120", 120.0 as TimeInterval?),
        ("1", 1),
        ("0", 1),
        ("3600", 3_600),
        (" 30\t", 30),
        ("0030", 30),
        ("86400", 86_400),
        ("86401", 86_400),
        ("604800", 86_400),
        ("604801", nil),
        ("999999999", nil),
        ("9999999999", nil),
        ("99999999999999999999999", nil),
        ("", nil),
        ("   ", nil),
        ("-1", nil),
        ("-30", nil),
        ("+30", nil),
        ("30s", nil),
        ("30 seconds", nil),
        ("30.5", nil),
        ("1e3", nil),
        ("NaN", nil),
        ("nan", nil),
        ("inf", nil),
        ("Infinity", nil),
        ("0x10", nil),
        ("3\u{0660}", nil),
        ("\u{0663}\u{0660}", nil),
        ("\u{FF13}\u{FF10}", nil),
        ("30, 60", nil),
        ("30,30", nil),
        ("30\r\n60", nil),
    ])
    func retryAfterSeconds(text: String, expected: TimeInterval?) {
        #expect(RateLimitHeaders.retryAfter(text, now: now) == expected)
    }

    @Test("a missing Retry-After is nil")
    func retryAfterMissing() {
        #expect(RateLimitHeaders.retryAfter(nil, now: now) == nil)
    }

    @Test("Retry-After as an HTTP date is measured from the answer's Date, or from now without one", arguments: [
        ("Sun, 06 Nov 1994 09:49:37 GMT", nil as String?, 3_600.0 as TimeInterval?),
        ("Sun, 06 Nov 1994 08:50:07 GMT", nil, 30),
        ("Sun, 06 Nov 1994 08:49:37 GMT", nil, 1),
        ("Sat, 05 Nov 1994 08:49:37 GMT", nil, 1),
        ("Mon, 07 Nov 1994 08:49:37 GMT", nil, 86_400),
        ("Wed, 30 Nov 1994 08:49:37 GMT", nil, nil),
        // The answer's own clock: an hour after its Date, whatever the device's clock says.
        ("Fri, 01 Jan 2010 01:00:00 GMT", "Fri, 01 Jan 2010 00:00:00 GMT", 3_600),
        ("Fri, 01 Jan 2010 01:00:00 GMT", "  Fri, 01 Jan 2010 00:00:00 GMT ", 3_600),
        // An unreadable Date falls back to now.
        ("Sun, 06 Nov 1994 09:49:37 GMT", "yesterday", 3_600),
        ("Sun, 06 Nov 1994 09:49:37 GMT", "Sun, 06 Nov 1994 09:49:37 GMT extra", 3_600),
        ("Thu, 29 Feb 1996 08:49:37 GMT", "Thu, 29 Feb 1996 08:48:37 GMT", 60),
        ("Sun, 06 Nov 1994 09:49:37 UTC", nil, nil),
        ("Sun, 06 Nov 1994 09:49:37 gmt", nil, nil),
        ("Sun, 6 Nov 1994 09:49:37 GMT", nil, nil),
        ("Sun, 06 Nov 1994 09:49:37 GMT extra", nil, nil),
        ("Sunday, 06-Nov-94 09:49:37 GMT", nil, nil),
        ("Sun Nov  6 09:49:37 1994", nil, nil),
        ("Sun, 31 Nov 1994 09:49:37 GMT", nil, nil),
        ("Sun, 29 Feb 1995 09:49:37 GMT", nil, nil),
        ("Sun, 00 Nov 1994 09:49:37 GMT", nil, nil),
        ("Sun, 06 Nov 1994 24:49:37 GMT", nil, nil),
        ("Sun, 06 Nov 1994 09:60:37 GMT", nil, nil),
        ("Xyz, 06 Nov 1994 09:49:37 GMT", nil, nil),
        ("Sun, 06 Foo 1994 09:49:37 GMT", nil, nil),
        ("Sun, 06 Nov 1994 0\u{0669}:49:37 GMT", nil, nil),
        ("Sun, 06 Nov +994 09:49:37 GMT", nil, nil),
    ])
    func retryAfterDate(text: String, date: String?, expected: TimeInterval?) {
        #expect(RateLimitHeaders.retryAfter(text, date: date, now: now) == expected)
    }

    @Test("an HTTP date reads as the instant it names")
    func httpDate() {
        #expect(RateLimitHeaders.httpDate("Sun, 06 Nov 1994 08:49:37 GMT") == now)
        #expect(RateLimitHeaders.httpDate("Thu, 01 Jan 1970 00:00:00 GMT") == Date(timeIntervalSince1970: 0))
        #expect(RateLimitHeaders.httpDate("Tue, 29 Feb 2000 12:00:00 GMT") == Date(timeIntervalSince1970: 951_825_600))
        #expect(RateLimitHeaders.httpDate("Fri, 31 Dec 2099 23:59:59 GMT") == Date(timeIntervalSince1970: 4_102_444_799))
    }

    @Test("X-RateLimit-Remaining is a whole number from 0 to 10,000,000", arguments: [
        ("3593", 3_593 as Int?),
        ("0", 0),
        ("1000", 1_000),
        ("10000000", 10_000_000),
        (" 42 ", 42),
        ("10000001", nil),
        ("99999999", nil),
        ("999999999999999999999", nil),
        ("", nil),
        ("-1", nil),
        ("+5", nil),
        ("5.0", nil),
        ("1e3", nil),
        ("NaN", nil),
        ("inf", nil),
        ("12abc", nil),
        ("\u{0665}", nil),
        ("\u{FF15}", nil),
        ("5, 6", nil),
        ("5 6", nil),
    ])
    func remaining(text: String, expected: Int?) {
        #expect(RateLimitHeaders.remaining(text) == expected)
    }

    @Test("a missing X-RateLimit-Remaining is nil")
    func remainingMissing() {
        #expect(RateLimitHeaders.remaining(nil) == nil)
    }

    @Test("a header is found whatever its case, and not when it appears twice or is not text")
    func headerLookup() {
        #expect(RateLimitHeaders.value("Retry-After", in: ["retry-after": "30"]) == "30")
        #expect(RateLimitHeaders.value("Retry-After", in: ["RETRY-AFTER": "30", "Date": "x"]) == "30")
        #expect(RateLimitHeaders.value("x-ratelimit-remaining", in: ["X-RateLimit-Remaining": "7"]) == "7")
        #expect(RateLimitHeaders.value("Retry-After", in: ["Retry-After": "30", "retry-after": "60"]) == nil)
        #expect(RateLimitHeaders.value("Retry-After", in: ["Retry-After-Extra": "30"]) == nil)
        #expect(RateLimitHeaders.value("Retry-After", in: ["Retry-After": 30]) == nil)
        #expect(RateLimitHeaders.value("Retry-After", in: [:]) == nil)
    }
}
