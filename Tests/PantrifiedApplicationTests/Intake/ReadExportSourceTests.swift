import Foundation
import Testing

/// The export's app code builds only on macOS, so these read its sources: the menu item is behind
/// the TestFlight gate and reachable from one place, and nothing in the export sends, stores or
/// logs what it holds.
@Suite("Copy what the app read: the app's sources")
struct ReadExportSourceTests {
    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static let entry = "App/Intake/ReadExportEntry.swift"
    static let screen = "App/Intake/ReadExportView.swift"
    static let exportSources = [
        entry, screen,
        "Sources/PantrifiedApplication/Intake/ReadExport/ReadExport.swift",
        "Sources/PantrifiedApplication/Intake/ReadExport/ReadExportBuilder.swift",
        "Sources/PantrifiedApplication/Intake/ReadExport/ReadExportDraft.swift",
        "Sources/PantrifiedApplication/Intake/ReadExport/ReadExportFiles.swift",
        "Sources/PantrifiedApplication/Intake/ReadExport/ReadExportGate.swift",
        "Sources/PantrifiedApplication/Intake/ReadExport/SensitiveText.swift",
    ]

    /// Network, analytics, logging, stored settings, the pasteboard and file writes other than
    /// `ReadExportFiles`.
    static let forbidden = [
        #"URLSession"#, #"URLRequest"#, #"NWConnection"#, #"import\s+(Network|CloudKit|os|OSLog|MetricKit)\b"#,
        #"CKContainer"#, #"\bLogger\s*\("#, #"os_log"#, #"NSLog"#, #"\bprint\s*\("#, #"debugPrint"#, #"UserDefaults"#,
        #"@AppStorage"#, #"@SceneStorage"#, #"UIPasteboard"#, #"Keychain"#, #"SecItem"#, #"\bopenURL\b"#,
    ]

    static func read(_ path: String) throws -> String {
        try String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8)
    }

    static func violations(in text: String) -> [String] {
        forbidden.filter { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// Every Swift file under App, by path.
    static func appSources() throws -> [(path: String, text: String)] {
        let app = repository.appendingPathComponent("App")
        let paths = FileManager.default.enumerator(atPath: app.path)?.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") } ?? []
        return try paths.sorted().map { ("App/\($0)", try read("App/\($0)")) }
    }

    @Test("the check finds code that sends, logs or stores")
    func detector() {
        for line in ["URLSession.shared.upload(for: request, from: data)", "Logger(subsystem: \"a\", category: \"b\")",
                     "print(text)", "UserDefaults.standard.set(data, forKey: \"k\")", "UIPasteboard.general.string = text",
                     "import OSLog"] {
            #expect(!Self.violations(in: line).isEmpty, "\(line)")
        }
        #expect(Self.violations(in: "let files = ReadExportFiles.temporary").isEmpty)
    }

    @Test("no export source sends, logs or stores what it holds")
    func nothingLeaves() throws {
        for path in Self.exportSources {
            #expect(Self.violations(in: try Self.read(path)) == [], "\(path)")
        }
    }

    @Test("the menu item is offered only behind the TestFlight receipt check")
    func gated() throws {
        let text = try Self.read(Self.entry)
        #expect(text.contains("ReadExportGate.isAvailable(receiptName: Bundle.main.appStoreReceiptURL?.lastPathComponent)"))
        #expect(text.contains("@State private var offered = ReadExportAvailability.isOffered"))
        #expect(text.contains("if offered, intake.stage == .reviewing, intake.review != nil {"))
        #expect(text.components(separatedBy: "ToolbarItem(").count == 2)
    }

    @Test("only the gated entry opens the preview, and the review screen calls the entry once")
    func oneEntry() throws {
        for (path, text) in try Self.appSources() {
            let opens = text.components(separatedBy: "ReadExportView(").count - 1
            let calls = text.components(separatedBy: ".readExportMenu(").count - 1
            switch path {
            case Self.entry:
                #expect(opens == 1, "\(path)")
            case "App/Intake/IntakeReviewView.swift":
                #expect(opens == 0 && calls == 1, "\(path)")
            case Self.screen:
                #expect(calls == 0, "\(path)")
            default:
                #expect(opens == 0 && calls == 0, "\(path)")
            }
        }
    }

    @Test("only the preview writes the file, through ReadExportFiles, and the app deletes leftovers at launch")
    func temporaryFile() throws {
        for (path, text) in try Self.appSources() where path != Self.screen {
            #expect(!text.contains("files.write("), "\(path)")
        }
        #expect(try Self.read(Self.screen).contains("ReadExportFiles.temporary"))
        #expect(try Self.read("App/Launch/AppLaunch.swift").contains("ReadExportFiles.temporary.removeAll()"))
    }
}
