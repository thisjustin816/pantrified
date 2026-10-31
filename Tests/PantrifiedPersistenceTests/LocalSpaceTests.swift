import Foundation
import Testing
import PantrifiedDomain
import PantrifiedTestSupport
@testable import PantrifiedPersistence

@Suite("The device's own Space")
struct LocalSpaceTests {
    private func marker(_ files: StoreFiles) -> URL { LocalSpace.marker(files) }

    @Test("the first call chooses an ID and creates the directory; later calls return the same one")
    func chosenOnceAndKept() throws {
        let files = temporaryStoreFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }

        let first = try LocalSpace.id(in: files)
        let second = try LocalSpace.id(in: files)

        #expect(first == second)
        #expect(FileManager.default.fileExists(atPath: marker(files).path))
    }

    @Test("separate stores get separate Spaces")
    func separateStores() throws {
        let one = temporaryStoreFiles()
        let two = temporaryStoreFiles()
        defer {
            try? FileManager.default.removeItem(at: one.directory)
            try? FileManager.default.removeItem(at: two.directory)
        }

        #expect(try LocalSpace.id(in: one) != LocalSpace.id(in: two))
    }

    @Test("the ID survives the process: a copy of the files reads the same one")
    func survivesRestart() throws {
        let files = temporaryStoreFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let id = try LocalSpace.id(in: files)

        #expect(try LocalSpace.id(in: StoreFiles(directory: files.directory)) == id)
    }

    @Test("a marker with trailing whitespace is read", arguments: ["\n", " ", "\r\n"])
    func tolerantOfTrailingWhitespace(suffix: String) throws {
        let files = temporaryStoreFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let id = try LocalSpace.id(in: files)
        try Data((id.rawValue.uuidString + suffix).utf8).write(to: marker(files))

        #expect(try LocalSpace.id(in: files) == id)
    }

    @Test("a marker that cannot be read is an error and is left exactly as it was", arguments: ["", "not a uuid", "{\"id\": 1}", "1234"])
    func unreadableMarkerIsNeverReplaced(contents: String) throws {
        let files = temporaryStoreFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: marker(files))

        #expect(throws: PersistenceError.corrupt("unreadable local space marker")) {
            try LocalSpace.id(in: files)
        }
        #expect(try Data(contentsOf: marker(files)) == Data(contents.utf8))
    }

    @Test("a marker that cannot be written is reported, not hidden")
    func unwritableDirectory() throws {
        // A parent of its own, so cleaning up never touches the temporary stores other tests use.
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("pantrified-local-space-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // A file where the store directory should be.
        let files = StoreFiles(directory: parent.appendingPathComponent("store"))
        try Data("x".utf8).write(to: files.directory)

        do {
            _ = try LocalSpace.id(in: files)
            Issue.record("expected an error")
        } catch {
            guard case .cannotOpen = error else { Issue.record("wrong error: \(error)"); return }
        }
    }
}
