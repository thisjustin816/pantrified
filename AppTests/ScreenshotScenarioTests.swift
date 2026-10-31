#if DEBUG
import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain
import PantrifiedGuidanceData
@testable import Pantrified

@Suite("Screenshot scenario")
struct ScreenshotScenarioTests {
    @Test("the sample mode starts only when asked, on the screen asked for")
    func parsing() {
        #expect(ScreenshotScenario(arguments: ["Pantrified"]) == nil)
        #expect(ScreenshotScenario(arguments: ["Pantrified", "-pantrified-scenario", "other"]) == nil)
        #expect(ScreenshotScenario(arguments: ["Pantrified", "-pantrified-scenario"]) == nil)

        func screen(_ arguments: [String]) -> ScreenshotScenario.Screen? {
            ScreenshotScenario(arguments: ["Pantrified", "-pantrified-scenario", "sample"] + arguments)?.screen
        }
        #expect(screen([]) == .today)
        #expect(screen(["-pantrified-screen", "food"]) == .food)
        #expect(screen(["-pantrified-screen", "add"]) == .add)
        #expect(screen(["-pantrified-screen", "nonsense"]) == .today)
        #expect(screen(["-pantrified-screen"]) == .today)
    }

    @Test("each screen opens on its own tab, and only the add screen opens the sheet")
    func startScreens() {
        func start(_ arguments: [String]) -> StartScreen? {
            ScreenshotScenario(arguments: ["Pantrified", "-pantrified-scenario", "sample"] + arguments)?.startScreen
        }
        #expect(start([])?.tab == .today)
        #expect(start(["-pantrified-screen", "food"])?.tab == .food)
        #expect(start(["-pantrified-screen", "add"])?.tab == .today)
        #expect(start(["-pantrified-screen", "add"])?.addingFood == true)
        #expect(start(["-pantrified-screen", "food"])?.addingFood == false)
        #expect(StartScreen().tab == .today)
        #expect(StartScreen().addingFood == false)
    }

    @Test("a screenshot run hides the Evaluate tab and keeps the keyboard down; a normal launch does neither")
    func screenshotRunLooksLikeTheStoreBuild() {
        for screen in ["today", "food", "add"] {
            let start = ScreenshotScenario(arguments: ["Pantrified", "-pantrified-scenario", "sample", "-pantrified-screen", screen])?.startScreen
            #expect(start?.showsEvaluation == false)
            #expect(start?.focusesName == false)
        }
        #expect(StartScreen().showsEvaluation == true)
        #expect(StartScreen().focusesName == true)
    }

    @Test("only the add screen opens Add food with an example filled in")
    func exampleOnlyOnTheAddScreen() {
        func fills(_ screen: String) -> Bool? {
            ScreenshotScenario(arguments: ["Pantrified", "-pantrified-scenario", "sample", "-pantrified-screen", screen])?.startScreen.fillsAddFoodExample
        }
        #expect(fills("add") == true)
        #expect(fills("today") == false)
        #expect(fills("food") == false)
        #expect(StartScreen().fillsAddFoodExample == false)
    }

    @Test("the sample food shows past guidance, use soon with and without a date, fine and unknown")
    func samplesCoverEveryState() async throws {
        let now = Date()
        let repository = BundledStorageGuidance(dataset: try BundledGuidance.dataset())
        var assessments: [String: AttentionAssessment] = [:]
        for sample in ScreenshotScenario.samples {
            let package = Package(
                spaceID: SpaceID(), name: sample.name, location: LocationID(),
                printedDate: sample.date.flatMap { ScreenshotScenario.printedDate($0.label, daysFromNow: $0.daysFromNow, now: now) },
                addedAt: now
            )
            let guidance = try await repository.guidance(for: package)
            assessments[sample.name] = AttentionPolicy().assess(
                package, storageType: Pantry.defaultLocations[sample.place].storageType, guidance: guidance, now: now
            )
        }

        let states = Set(assessments.values.map(\.state))
        #expect(states == [.pastGuidance, .useSoon, .fine, .unknown])
        // One use-soon food has no printed date, so its reason is the sourced guidance.
        #expect(ScreenshotScenario.samples.first { $0.name == "Asparagus" }?.date == nil)
        #expect(assessments["Asparagus"]?.state == .useSoon)
    }

    @Test("every sample is in a location a new Space has")
    func samplesUseDefaultLocations() {
        #expect(ScreenshotScenario.samples.allSatisfy { (0..<Pantry.defaultLocations.count).contains($0.place) })
    }
}
#endif
