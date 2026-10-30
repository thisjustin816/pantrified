import SwiftUI

struct TodayView: View {
    var body: some View {
        NavigationStack {
            List {
                ContentUnavailableView(
                    "Nothing needs attention",
                    systemImage: "checkmark.circle",
                    description: Text("Add groceries to see what to use soon.")
                )
                #if DEBUG
                Section("Debug") {
                    let sample = AttentionDemo.sample()
                    LabeledContent(sample.name, value: sample.stateLabel)
                }
                #endif
            }
            .navigationTitle("Today")
        }
    }
}
