import Foundation

enum AppTab: Hashable {
    case today, food, meals, list, evaluate
}

/// Where the app opens. Always Today with nothing presented, except in a Debug screenshot run.
struct StartScreen {
    var tab: AppTab = .today
    var addingFood = false
    /// False in a screenshot run, so the tab bar looks as it does in the App Store build.
    var showsEvaluation = true

    static var current: StartScreen {
        #if DEBUG
        if let scenario = ScreenshotScenario.current { return scenario.startScreen }
        #endif
        return StartScreen()
    }
}
