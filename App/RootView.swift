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

    var body: some View {
        TabView {
            Tab("Today", systemImage: "sun.max") {
                TodayView(model: model)
            }
            Tab("Food", systemImage: "carrot") {
                FoodView(model: model)
            }
            Tab("Meals", systemImage: "fork.knife") {
                PlaceholderView(title: "Meals", detail: "Meals that use what you have will appear here.")
            }
            Tab("List", systemImage: "cart") {
                PlaceholderView(title: "List", detail: "Your shared shopping list will appear here.")
            }
            #if DEBUG || EVALUATION
            Tab("Evaluate", systemImage: "checklist") {
                EvaluationView()
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
