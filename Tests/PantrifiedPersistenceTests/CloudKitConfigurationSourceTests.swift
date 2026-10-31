import Foundation
import Testing

/// SwiftData's automatic CloudKit sync is not how Spaces are shared, and it is on by default. This
/// reads the shipped sources, so it runs where SwiftData does not exist; the SwiftData backend
/// tests check the opened store's configuration.
@Suite("Automatic CloudKit sync stays off")
struct CloudKitConfigurationSourceTests {
    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Each `ModelConfiguration(` call in `text`, from its opening parenthesis to its matching close.
    static func configurationCalls(in text: String) -> [Substring] {
        var calls: [Substring] = []
        var search = text.startIndex
        while let start = text.range(of: "ModelConfiguration(", range: search..<text.endIndex) {
            var depth = 0
            var end = start.upperBound
            for index in text.indices[text.index(before: start.upperBound)...] {
                if text[index] == "(" { depth += 1 }
                if text[index] == ")" { depth -= 1 }
                if depth == 0 { end = text.index(after: index); break }
            }
            calls.append(text[start.lowerBound..<end])
            search = end
        }
        return calls
    }

    static func violations(in text: String) -> Int {
        configurationCalls(in: text).filter { !$0.contains("cloudKitDatabase: .none") }.count
    }

    @Test("the check finds a configuration that leaves the default on")
    func detectorFindsDefault() {
        #expect(Self.violations(in: "let c = ModelConfiguration(schema: s, url: u)") == 1)
        #expect(Self.violations(in: "ModelConfiguration(schema: Schema(v), url: u, cloudKitDatabase: .automatic)") == 1)
        #expect(Self.violations(in: "ModelConfiguration(schema: Schema(v), url: u, cloudKitDatabase: .none)") == 0)
    }

    @Test("every SwiftData configuration in the app and its packages turns automatic CloudKit sync off")
    func shippedConfigurationsTurnSyncOff() throws {
        var calls = 0
        for root in ["Sources", "App"] {
            let directory = Self.repository.appendingPathComponent(root)
            let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                calls += Self.configurationCalls(in: text).count
                #expect(Self.violations(in: text) == 0, "\(file.lastPathComponent)")
            }
        }
        #expect(calls > 0)
    }
}
