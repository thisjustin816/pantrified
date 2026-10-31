import Foundation

/// The words for a product lookup that cannot run yet. Adding food never waits for a lookup.
enum LookupText {
    /// The note for lookups paused after a rate limit, saying roughly how long the pause has left:
    /// whole minutes, at least one, under ten minutes; the nearest five minutes under 55 minutes;
    /// "about an hour" under 90 minutes; whole hours past that. Without a time it says only that
    /// lookups are paused.
    static func paused(until resumesAt: Date?, now: Date) -> String {
        let action = "Enter a name to add it now, or scan it again later."
        guard let resumesAt, resumesAt > now else { return "Name lookups are paused for now. \(action)" }
        return "Name lookups are paused for \(duration(resumesAt.timeIntervalSince(now))). \(action)"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = seconds / 60
        if minutes < 10 {
            let whole = max(1, Int(minutes.rounded(.up)))
            return whole == 1 ? "about a minute" : "about \(whole) minutes"
        }
        if minutes < 55 { return "about \(Int((minutes / 5).rounded()) * 5) minutes" }
        if minutes < 90 { return "about an hour" }
        return "about \(Int((minutes / 60).rounded())) hours"
    }
}
