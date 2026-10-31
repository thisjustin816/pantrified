import Foundation
import PantrifiedApplication

/// Keeps the time product lookups may resume in one small file, as whole seconds since 1970 in
/// ASCII digits and nothing else. Reading is strict: a missing, unreadable, oversized or malformed
/// file is no pause. Whether a time read back is still usable is `PacedProductLookup`'s decision.
public struct LookupPauseFile: LookupPauseStore {
    public let file: URL
    /// Eleven digits reach the year 5138, so anything longer is not a time this file wrote.
    static let longestText = 11

    public init(file: URL) {
        self.file = file
    }

    /// The file in the app's Caches directory: kept across launches, never backed up or restored
    /// to another device, and safe for the system to purge, which only ends a pause early.
    public static func inCaches() -> LookupPauseFile? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return LookupPauseFile(file: caches
            .appendingPathComponent("Pantrified", isDirectory: true)
            .appendingPathComponent("lookup-resumes-at"))
    }

    public func load() -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        // One byte past the longest text, so a longer file is seen as too long without reading it all.
        guard let data = try? handle.read(upToCount: Self.longestText + 1),
              (1...Self.longestText).contains(data.count),
              data.allSatisfy({ (0x30...0x39).contains($0) })
        else { return nil }
        let seconds = data.reduce(0) { $0 * 10 + Int($1 - 0x30) }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    public func save(_ resumesAt: Date?) {
        guard let resumesAt else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        let seconds = resumesAt.timeIntervalSince1970.rounded(.up)
        // Before 1970 or past what the file can hold is not a pause worth keeping.
        guard seconds >= 0, seconds < 1e11 else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(String(Int(seconds)).utf8).write(to: file, options: .atomic)
        } catch {
            // Not remembered: after a relaunch the next lookup may be refused again and pause again.
        }
    }
}
