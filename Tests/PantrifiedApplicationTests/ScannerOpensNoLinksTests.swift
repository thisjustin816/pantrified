import Foundation
import Testing

/// A QR code's text comes from whoever printed it, so the scanner must never open, fetch or
/// preview a link. This reads the shipped scanner sources, so it runs where the app does not
/// build. The scan screen's only link is the system Settings page, allowed by its exact text.
@Suite("The scanner opens no links")
struct ScannerOpensNoLinksTests {
    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Every file a scanned payload passes through.
    static let scannerSources = [
        "App/Capture/BarcodeCamera.swift",
        "App/Capture/ScannerModel.swift",
        "App/Capture/ScanView.swift",
        "Sources/PantrifiedApplication/BarcodeScan.swift",
        "Sources/PantrifiedDomain/Intake/PhotoObservation.swift",
        "Sources/PantrifiedDomain/GTIN.swift",
    ]

    static let allowed = [
        "@Environment(\\.openURL) private var openURL",
        "let settings = URL(string: UIApplication.openSettingsURLString)",
        "openURL(settings)",
    ]

    /// Calls and types that open, load, resolve or preview a URL, and the frameworks that do.
    static let forbidden = [
        #"\bopen\s*\("#, #"openURL"#, #"canOpenURL"#, #"\bURL\s*\("#, #"URLComponents"#, #"\bNSURL\b"#,
        #"URLSession"#, #"URLRequest"#, #"contentsOf"#, #"WKWebView"#, #"SFSafariViewController"#,
        #"ASWebAuthenticationSession"#, #"LPMetadataProvider"#, #"LPLinkView"#, #"NSDataDetector"#,
        #"\bLink\s*\("#, #"ShareLink"#, #"NWConnection"#, #"CFNetwork"#,
        #"import\s+(WebKit|SafariServices|LinkPresentation|Network|AuthenticationServices)\b"#,
    ]

    static func violations(in text: String) -> [String] {
        var rest = text
        for allowance in allowed { rest = rest.replacingOccurrences(of: allowance, with: "") }
        return forbidden.filter { rest.range(of: $0, options: .regularExpression) != nil }
    }

    @Test("the check finds code that opens or loads a link, and allows the Settings button")
    func detector() {
        let opening = [
            "UIApplication.shared.open(url)",
            "UIApplication.shared.open (url, options: [:])",
            "openURL(link)",
            "let link = URL(string: read.payload)",
            "URLSession.shared.dataTask(with: link)",
            "let page = WKWebView()",
            "Link(\"Open\", destination: link)",
            "LPMetadataProvider().startFetchingMetadata(for: link) { _, _ in }",
            "import SafariServices",
            "let data = try Data(contentsOf: link)",
        ]
        for line in opening {
            #expect(!Self.violations(in: line).isEmpty, "\(line)")
        }
        #expect(Self.violations(in: Self.allowed.joined(separator: "\n")).isEmpty)
        #expect(!Self.violations(in: "let settings = URL(string: read.payload)").isEmpty)
    }

    @Test("no scanner source opens, loads or previews a link")
    func scannerOpensNoLinks() throws {
        for path in Self.scannerSources {
            let text = try String(contentsOf: Self.repository.appendingPathComponent(path), encoding: .utf8)
            #expect(Self.violations(in: text) == [], "\(path)")
        }
    }
}
