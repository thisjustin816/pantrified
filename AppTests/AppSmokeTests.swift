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
