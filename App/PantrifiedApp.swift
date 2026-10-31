import SwiftUI

@main
struct PantrifiedApp: App {
    @State private var launch = AppLaunch()

    var body: some Scene {
        WindowGroup {
            RootView(launch: launch)
        }
    }
}
