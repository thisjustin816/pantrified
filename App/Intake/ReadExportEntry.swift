import SwiftUI
import UIKit
import PantrifiedApplication
import PantrifiedDomain

extension View {
    /// TestFlight builds only: "Copy What the App Read" in the review's overflow menu, which opens a
    /// preview of the batch's export. The review screen calls this once; it adds nothing to an App
    /// Store install, and nothing while the batch is still being read.
    func readExportMenu(_ intake: IntakeModel) -> some View {
        modifier(ReadExportMenu(intake: intake))
    }
}

/// Whether this install offers the export. `ReadExportGate` holds the rule; this reads the receipt
/// name on the device and keeps the item out of the Debug screenshots.
enum ReadExportAvailability {
    static var isOffered: Bool {
        #if DEBUG
        if ScreenshotScenario.current != nil { return false }
        #endif
        return ReadExportGate.isAvailable(receiptName: Bundle.main.appStoreReceiptURL?.lastPathComponent)
    }
}

private struct ReadExportMenu: ViewModifier {
    let intake: IntakeModel

    /// Read once: the install source does not change while the app runs.
    @State private var offered = ReadExportAvailability.isOffered
    @State private var source: ReadExportSourceItem?

    func body(content: Content) -> some View {
        content
            .toolbar {
                if offered, intake.stage == .reviewing, intake.review != nil {
                    ToolbarItem(placement: .secondaryAction) {
                        Button("Copy What the App Read", systemImage: "doc.text.magnifyingglass") { open() }
                            .accessibilityHint("Shows what Pantrified read from this batch before you share it. TestFlight builds only.")
                    }
                }
            }
            .sheet(item: $source) { item in
                ReadExportView(source: item.source)
            }
    }

    private func open() {
        guard let review = intake.review else { return }
        source = ReadExportSourceItem(source: ReadExportSource(app: .current, review: review, locations: intake.locations))
    }
}

private struct ReadExportSourceItem: Identifiable {
    let id = UUID()
    let source: ReadExportSource
}

extension ReadExport.AppInfo {
    /// This build and device: the version and build number, the system version and the model
    /// identifier, such as "iPhone17,1".
    @MainActor static var current: ReadExport.AppInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        return ReadExport.AppInfo(
            version: info["CFBundleShortVersionString"] as? String ?? "",
            build: info["CFBundleVersion"] as? String ?? "",
            system: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            device: deviceModel
        )
    }

    private static var deviceModel: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
