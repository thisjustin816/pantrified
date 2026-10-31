import Foundation
import Testing
import PantrifiedPersistence

private func scratch() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Suite("Lookup pause file")
struct LookupPauseFileTests {
    @Test("a saved time reads back as whole seconds, rounded up, and nil removes the file")
    func roundTrip() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = LookupPauseFile(file: directory.appendingPathComponent("a").appendingPathComponent("lookup-resumes-at"))

        #expect(file.load() == nil)
        file.save(Date(timeIntervalSince1970: 1_800_003_600))
        #expect(file.load() == Date(timeIntervalSince1970: 1_800_003_600))
        #expect(try String(contentsOf: file.file, encoding: .utf8) == "1800003600")
        file.save(Date(timeIntervalSince1970: 1_800_003_600.2))
        #expect(file.load() == Date(timeIntervalSince1970: 1_800_003_601))

        file.save(nil)
        #expect(file.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: file.file.path))
    }

    @Test("anything but up to eleven ASCII digits reads as no time", arguments: [
        "", " ", "abc", "-5", "+5", "1e10", "5.0", "1800003600\n", " 1800003600", "\u{0661}\u{0668}", "\u{FF11}",
        "123456789012", String(repeating: "9", count: 100_000),
    ])
    func unreadable(text: String) throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("lookup-resumes-at")
        try Data(text.utf8).write(to: url)

        #expect(LookupPauseFile(file: url).load() == nil)
    }

    @Test("binary bytes and a directory in the file's place read as no time, and saving does not crash")
    func notAFile() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("binary")
        try Data([0x31, 0x00, 0x32, 0xFF]).write(to: binary)
        let folder = directory.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        #expect(LookupPauseFile(file: binary).load() == nil)
        #expect(LookupPauseFile(file: folder).load() == nil)
        LookupPauseFile(file: folder.appendingPathComponent("inside")).save(Date(timeIntervalSince1970: 5))
        #expect(LookupPauseFile(file: folder.appendingPathComponent("inside")).load() == Date(timeIntervalSince1970: 5))
    }

    @Test("a time before 1970 or past what the file holds is not saved", arguments: [-1.0, 1e11, .infinity, .nan])
    func unsavable(seconds: Double) throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = LookupPauseFile(file: directory.appendingPathComponent("lookup-resumes-at"))
        file.save(Date(timeIntervalSince1970: 60))

        file.save(Date(timeIntervalSince1970: seconds))
        #expect(file.load() == nil)
    }
}
