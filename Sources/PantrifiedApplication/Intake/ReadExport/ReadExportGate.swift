import Foundation

/// Decides whether "Copy what the app read" is offered. It is offered only in an app installed from
/// TestFlight, never in one installed from the App Store, and the decision is made on the device
/// from the name of the app's receipt file, with no network.
///
/// The App Store build is the same binary as the TestFlight build it was promoted from, so no
/// compile-time condition can tell the two apart. What differs is where the app was installed
/// from: iOS names the receipt `sandboxReceipt` in an app installed from TestFlight, or run from
/// Xcode, and `receipt` in an app installed from the App Store. Anything other than
/// `sandboxReceipt`, including no receipt URL at all, keeps the feature hidden. An app under App
/// Review is installed in the sandbox too, so a reviewer would see the menu item.
public enum ReadExportGate {
    public static let testFlightReceiptName = "sandboxReceipt"

    /// `receiptName` is the last path component of `Bundle.main.appStoreReceiptURL`.
    public static func isAvailable(receiptName: String?) -> Bool {
        receiptName == testFlightReceiptName
    }
}
