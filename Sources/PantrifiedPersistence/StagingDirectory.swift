import Foundation
import PantrifiedApplication

/// The staging folder for batch photos: Application Support/Pantrified/Intake. Not in Caches, which
/// iOS may empty while a batch waits for review, and not in the photo library. On iOS the folder
/// and its files are protected until the device is first unlocked and are excluded from backups,
/// because they are temporary.
///
/// It reads and writes only plain names inside its own folder: a name holding a path separator, or
/// starting with a dot, is refused.
public struct StagingDirectory: StagingFiles {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func applicationSupport() throws -> StagingDirectory {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return StagingDirectory(directory: support
            .appendingPathComponent("Pantrified", isDirectory: true)
            .appendingPathComponent("Intake", isDirectory: true))
    }

    public struct UnsafeName: Error {}

    public func write(_ data: Data, to name: String) throws {
        let url = try file(name)
        try prepare()
        try data.write(to: url, options: Self.writeOptions(for: name))
        if !Self.protection.isEmpty { try FileManager.default.setAttributes(Self.protection, ofItemAtPath: url.path) }
        try Self.markTemporary(url)
    }

    public func read(_ name: String) throws -> Data? {
        let url = try file(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func remove(_ name: String) throws {
        let url = try file(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func names() throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }

    public func url(for name: String) -> URL {
        directory.appendingPathComponent(name, isDirectory: false)
    }

    private func file(_ name: String) throws -> URL {
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
            throw UnsafeName()
        }
        return url(for: name)
    }

    private func prepare() throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: Self.protection)
        try Self.markTemporary(directory)
    }

    /// Record files are replaced atomically, so a crash leaves the old one whole. Photos are written
    /// in place: an atomic write goes through a hidden temporary file that a crash can leave behind,
    /// which the store would never remove, while a half-written photo has a name the store made
    /// and no record naming it, so the next sweep removes it.
    public static func writeOptions(for name: String) -> Data.WritingOptions {
        var options: Data.WritingOptions = name.hasSuffix(".json") ? [.atomic] : []
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        return options
    }

    #if os(iOS)
    private static var protection: [FileAttributeKey: Any] {
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    }
    #else
    private static var protection: [FileAttributeKey: Any] { [:] }
    #endif

    /// Excluded from device backups. Only where the platform supports the flag.
    private static func markTemporary(_ url: URL) throws {
        #if canImport(Darwin)
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #endif
    }
}
