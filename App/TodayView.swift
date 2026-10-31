import SwiftUI
import PantrifiedApplication
import PantrifiedDomain

/// What to use first: food past its guidance, then food to use soon.
struct TodayView: View {
    let model: PantryModel

    @Environment(\.scenePhase) private var scenePhase
    @State private var adding: Bool

    init(model: PantryModel, startsAdding: Bool = false) {
        self.model = model
        _adding = State(initialValue: startsAdding)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let snapshot = model.snapshot {
                    content(snapshot)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add food", systemImage: "plus") { adding = true }
                }
            }
            .navigationDestination(for: PackageID.self) { PackageDetailView(model: model, id: $0) }
            .sheet(isPresented: $adding) { AddFoodView(model: model) }
            .pantryChrome(model)
        }
        // The day may have changed while the app was in the background.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.load() } }
        }
    }

    @ViewBuilder
    private func content(_ snapshot: PantrySnapshot) -> some View {
        let past = snapshot.attention.filter { $0.assessment.state == .pastGuidance }
        let soon = snapshot.attention.filter { $0.assessment.state == .useSoon }
        if past.isEmpty && soon.isEmpty {
            ContentUnavailableView {
                Label("Nothing needs attention", systemImage: "checkmark.circle")
            } description: {
                Text(snapshot.entries.isEmpty
                     ? "Add what you bought to see what to use soon."
                     : "Everything you have is fine for now.")
            } actions: {
                Button("Add food") { adding = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            List {
                Section {
                    Button { adding = true } label: {
                        Label("Add food", systemImage: "plus.circle.fill")
                    }
                }
                section("Past guidance", past, snapshot)
                section("Use soon", soon, snapshot)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ entries: [PantryEntry], _ snapshot: PantrySnapshot) -> some View {
        if !entries.isEmpty {
            Section(title) {
                ForEach(entries) { entry in
                    EntryRow(entry: entry, locations: snapshot.locations, showsLocation: true) { action in
                        Task { await model.perform(action, on: entry) }
                    }
                }
            }
        }
    }
}
