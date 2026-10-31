import SwiftUI

/// The four working areas. Today and Food are wired to the local store; Meals and List are
/// placeholders until their features are.
struct RootView: View {
    let launch: AppLaunch

    var body: some View {
        Group {
            switch launch.state {
            case .opening:
                ProgressView()
            case .ready(let model):
                MainTabs(model: model)
            case .unavailable(let problem):
                StoreProblemView(problem: problem)
            }
        }
        .task { await launch.start() }
    }
}

private struct MainTabs: View {
    let model: PantryModel

    @State private var selection = StartScreen.current.tab

    var body: some View {
        TabView(selection: $selection) {
            Tab("Today", systemImage: "sun.max", value: AppTab.today) {
                TodayView(model: model, startsAdding: StartScreen.current.addingFood)
            }
            Tab("Food", systemImage: "carrot", value: AppTab.food) {
                FoodView(model: model)
            }
            Tab("Meals", systemImage: "fork.knife", value: AppTab.meals) {
                PlaceholderView(title: "Meals", detail: "Meals that use what you have will appear here.")
            }
            Tab("List", systemImage: "cart", value: AppTab.list) {
                PlaceholderView(title: "List", detail: "Your shared shopping list will appear here.")
            }
            #if DEBUG || EVALUATION
            if StartScreen.current.showsEvaluation {
                Tab("Evaluate", systemImage: "checklist", value: AppTab.evaluate) {
                    EvaluationView()
                }
            }
            #endif
        }
    }
}

/// Shown instead of the app when its data cannot be opened. It offers nothing that deletes data.
private struct StoreProblemView: View {
    let problem: StoreProblem

    var body: some View {
        ContentUnavailableView {
            Label(problem.title, systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 12) {
                Text(problem.message)
                DisclosureGroup("Details") {
                    Text(problem.detail)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }
}

struct PlaceholderView: View {
    let title: String
    let detail: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView(title, systemImage: "tray", description: Text(detail))
                .navigationTitle(title)
        }
    }
}
