import Foundation

/// The temporary files an export is shared from. Each file is written when the person taps Share,
/// in a folder of its own, and deleted when the share sheet closes; whatever a crash leaves is
/// deleted at the next launch. Nothing else is written.
public struct ReadExportFiles: Sendable {
    public static let fileName = "pantrified-what-the-app-read.json"

    /// The folder every export file is written under, and the only one this deletes.
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Under the system's temporary folder, which is not backed up.
    public static var temporary: ReadExportFiles {
        ReadExportFiles(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ReadExport", isDirectory: true))
    }

    /// Writes the export to a new file and returns its URL.
    public func write(_ data: Data) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(Self.fileName)
        #if canImport(Darwin)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        return file
    }

    /// Deletes one file written by `write`, with its folder. A URL outside `directory` is ignored.
    public func remove(_ file: URL) {
        let folder = file.deletingLastPathComponent().standardizedFileURL
        guard folder.deletingLastPathComponent().path == directory.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Deletes every export file.
    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
