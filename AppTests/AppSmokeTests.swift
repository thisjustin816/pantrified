import Foundation
import Testing
@testable import Pantrified

@Suite("App")
struct AppSmokeTests {
    @Test("the app's display name is Pantrified")
    func displayName() {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String

        #expect(name == "Pantrified")
    }

    @Test("the app explains its camera use, and a build without a lookup key carries an empty one")
    func infoPlist() {
        let camera = Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String
        let key = Bundle.main.object(forInfoDictionaryKey: "FoodDataCentralAPIKey") as? String

        #expect(camera?.contains("scan barcodes") == true)
        // CI builds set no key, so the merged Info.plist must hold the expanded, empty setting.
        #expect(key == "")
        #expect(Bundle.main.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption") as? Bool == false)
    }

    @Test("the bundled FoodKeeper snapshot loads inside the app")
    func guidanceSnapshotShips() {
        #expect(AttentionDemo.guidanceRecordCount() == 661)
    }

    @Test("the domain package runs inside the app on the Apple SDK")
    func domainIsLinked() {
        let sample = AttentionDemo.sample()

        #expect(sample.name == "Spinach")
        #expect(sample.stateLabel == "Use soon")
    }
}
