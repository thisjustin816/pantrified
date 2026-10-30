import SwiftUI

/// The four working areas. Each tab is a placeholder until its feature is wired to the packages.
struct RootView: View {
    var body: some View {
        TabView {
            Tab("Today", systemImage: "sun.max") {
                TodayView()
            }
            Tab("Food", systemImage: "carrot") {
                PlaceholderView(title: "Food", detail: "What you have will appear here.")
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
