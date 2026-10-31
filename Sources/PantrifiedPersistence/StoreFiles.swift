import Foundation

/// Where the local store's files live: one directory holding the database files and a schema marker.
public struct StoreFiles: Sendable, Hashable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The database. The database engine keeps companion files beside it in the same directory.
    public var store: URL { directory.appendingPathComponent("Pantrified.store") }

    /// The highest schema version that has opened the store. Kept outside the database so a
    /// version that cannot read the database can still learn that a newer one wrote it.
    var schemaMarker: URL { directory.appendingPathComponent("schema-version") }

    /// Durable user data belongs in Application Support. Caches and temporary capture files live
    /// elsewhere, so clearing them never touches this directory.
    public static func applicationSupport() throws(PersistenceError) -> StoreFiles {
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            return StoreFiles(directory: support
                .appendingPathComponent("Pantrified", isDirectory: true)
                .appendingPathComponent("LocalStore", isDirectory: true))
        } catch {
            throw .cannotOpen("no Application Support directory: \(error)")
        }
    }
}

public enum StoreSchema {
    /// The schema version this build opens and writes.
    public static let current = 1
}

/// Opens a store so that a version of the app never opens a store a newer version has written,
/// and never deletes or replaces a store it cannot open.
enum StoreOpening {
    static func open<Container>(
        _ files: StoreFiles,
        schema: Int = StoreSchema.current,
        container: () throws -> Container
    ) throws(PersistenceError) -> Container {
        try prepareDirectory(files.directory)
        let marked = try readMarker(files)
        if let marked, marked > schema { throw .newerSchema(found: marked, supported: schema) }

        let opened: Container
        do {
            opened = try container()
        } catch {
            throw .cannotOpen(String(describing: error))
        }
        // Written only after the store opened, so an older marker means at worst that the next
        // launch opens the store again before recording it.
        if marked != schema { try writeMarker(schema, files) }
        try protectContents(of: files.directory)
        return opened
    }

    private static func readMarker(_ files: StoreFiles) throws(PersistenceError) -> Int? {
        guard FileManager.default.fileExists(atPath: files.schemaMarker.path) else { return nil }
        guard let data = try? Data(contentsOf: files.schemaMarker),
              let version = Int(String(decoding: data, as: UTF8.self))
        else { throw .cannotOpen("unreadable schema marker") }
        return version
    }

    private static func writeMarker(_ version: Int, _ files: StoreFiles) throws(PersistenceError) {
        do {
            try Data("\(version)".utf8).write(to: files.schemaMarker, options: .atomic)
        } catch {
            throw .cannotOpen("schema marker not written: \(error)")
        }
    }

    #if os(iOS)
    /// Readable once the device has been unlocked after a restart, so syncing and background work
    /// can reach it while the device is locked. New files inherit the directory's class.
    private static var protection: [FileAttributeKey: Any] {
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    }
    #else
    private static var protection: [FileAttributeKey: Any] { [:] }
    #endif

    private static func prepareDirectory(_ directory: URL) throws(PersistenceError) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: protection)
        } catch {
            throw .cannotOpen("store directory not created: \(error)")
        }
    }

    /// Sets the protection class on the directory and every file the database created in it.
    private static func protectContents(of directory: URL) throws(PersistenceError) {
        guard !protection.isEmpty else { return }
        do {
            try FileManager.default.setAttributes(protection, ofItemAtPath: directory.path)
            for file in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
                try FileManager.default.setAttributes(protection, ofItemAtPath: directory.appendingPathComponent(file).path)
            }
        } catch {
            throw .cannotOpen("file protection not set: \(error)")
        }
    }
}
