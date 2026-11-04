import Foundation
import Testing
import PantrifiedApplication

@Suite("Copy what the app read: the check, the TestFlight gate and the temporary file")
struct ReadExportPrivacyTests {
    @Test("the check flags text shaped like personal details", arguments: [
        ("jane.doe@example.com", SensitiveText.Kind.email), ("Write to us: Help@Brand.co.uk", .email),
        ("(555) 123-4567", .phone), ("+1 555.123.4567", .phone), ("Call 1-800-555-0199", .phone),
        ("+44 20 7946 0958", .phone), ("Tel: 0201234", .phone), ("555-1234", .phone),
        ("123 Main Street", .streetAddress), ("42 W Elm Ave Apt 3", .streetAddress), ("PO Box 1234", .streetAddress),
        ("Norwich, NY 13815", .streetAddress),
        ("4111 1111 1111 1111", .longNumber), ("Acct 123456789", .longNumber), ("0 36000 29145 2", .longNumber),
        ("Mrs Jones", .personName), ("Dr. Patel", .personName), ("MRS JANE DOE", .personName), ("Patient: J Smith", .personName), ("Ship to: Alex", .personName),
    ])
    func flags(text: String, kind: SensitiveText.Kind) {
        #expect(SensitiveText.flag(text) == kind)
    }

    @Test("the check leaves ordinary label text alone", arguments: [
        "GREEK YOGURT", "Plain nonfat", "USE BY 2027-02-01", "BEST BEFORE 05/06/28", "Nutrition Facts",
        "Serving size 1 cup (227g)", "Sodium 65mg 3%", "Net Wt 12 oz (340g)", "12 ct", "KEEP FROZEN", "LOT 2345 0927",
        "Ingredients: black beans, water, salt", "Made in Italy", "BB 11.2027", "2% reduced fat milk",
    ])
    func ordinaryText(text: String) {
        #expect(SensitiveText.flag(text) == nil)
    }

    /// The check works on the text's shape. These pass it, which is why the preview asks the person
    /// to read every line.
    @Test("the check misses a bare name, an address without a number or street word, and a number in words", arguments: [
        "Jane Doe", "Main and Fifth, Springfield", "five five five one two three four", "jane at example dot com",
        "Acct 12345678",
    ])
    func misses(text: String) {
        #expect(SensitiveText.flag(text) == nil)
    }

    @Test("the check also flags some text that is not personal, such as brand names after a title")
    func overFlags() {
        #expect(SensitiveText.flag("Dr Pepper") == .personName)
        #expect(SensitiveText.flag("MISS VICKIE'S") == .personName)
    }

    @Test("the export is offered only with a TestFlight receipt", arguments: [
        ("sandboxReceipt", true), ("receipt", false), ("", false), ("SandboxReceipt", false), ("sandboxReceipt.old", false),
    ])
    func gate(name: String, offered: Bool) {
        #expect(ReadExportGate.isAvailable(receiptName: name) == offered)
    }

    @Test("with no receipt at all the export is not offered")
    func noReceipt() {
        #expect(!ReadExportGate.isAvailable(receiptName: nil))
    }

    private func scratch() -> ReadExportFiles {
        ReadExportFiles(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadExportFilesTests-\(UUID().uuidString)", isDirectory: true))
    }

    @Test("a share writes one file of its own, and removing it deletes it and its folder")
    func writeAndRemove() throws {
        let files = scratch()
        defer { files.removeAll() }
        let first = try files.write(Data("{}".utf8))
        let second = try files.write(Data("[]".utf8))
        #expect(first.lastPathComponent == "pantrified-what-the-app-read.json")
        #expect(first != second)
        #expect(try Data(contentsOf: first) == Data("{}".utf8))
        #expect(first.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path == files.directory.standardizedFileURL.path)
        files.remove(first)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(!FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test("removing ignores a file outside the export folder")
    func removeOutside() throws {
        let files = scratch()
        let other = scratch()
        defer {
            files.removeAll()
            other.removeAll()
        }
        let elsewhere = try other.write(Data("{}".utf8))
        files.remove(elsewhere)
        #expect(FileManager.default.fileExists(atPath: elsewhere.path))
    }

    @Test("at launch every file left behind is deleted")
    func removeAll() throws {
        let files = scratch()
        let written = try files.write(Data("{}".utf8))
        files.removeAll()
        #expect(!FileManager.default.fileExists(atPath: written.path))
        #expect(!FileManager.default.fileExists(atPath: files.directory.path))
    }

    @Test("the shared temporary folder is under the system's temporary folder")
    func temporary() {
        #expect(ReadExportFiles.temporary.directory.deletingLastPathComponent().standardizedFileURL.path
            == FileManager.default.temporaryDirectory.standardizedFileURL.path)
    }
}
