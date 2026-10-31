import Foundation

enum AppTab: Hashable {
    case today, food, meals, list, evaluate
}

/// Where the app opens. Always Today with nothing presented, except in a Debug screenshot run.
struct StartScreen {
    var tab: AppTab = .today
    var addingFood = false
    /// True in a screenshot run of the scan screen, which opens the scanner over Today.
    var scanning = false
    /// False in a screenshot run, so the tab bar looks as it does in the App Store build.
    var showsEvaluation = true
    /// False in a screenshot run, so the keyboard does not cover the Add food form.
    var focusesName = true
    /// True in a screenshot run of Add food, which opens with an example filled in.
    var fillsAddFoodExample = false

    static var current: StartScreen {
        #if DEBUG
        if let scenario = ScreenshotScenario.current { return scenario.startScreen }
        #endif
        return StartScreen()
    }
}
