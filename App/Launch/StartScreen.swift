import Foundation

enum AppTab: Hashable {
    case today, food, meals, list, evaluate
}

/// Where the app opens. Always Today with nothing presented, except in a Debug screenshot run.
struct StartScreen {
    var tab: AppTab = .today
    var addingFood = false

    static var current: StartScreen {
        #if DEBUG
        if let scenario = ScreenshotScenario.current { return scenario.startScreen }
        #endif
        return StartScreen()
    }
}
