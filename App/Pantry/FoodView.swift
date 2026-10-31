import SwiftUI
import PantrifiedApplication
import PantrifiedDomain

/// Everything you have, grouped by where it is kept.
struct FoodView: View {
    let model: PantryModel

    @State private var adding = false

    var body: some View {
        NavigationStack {
            Group {
                if let snapshot = model.snapshot {
                    content(snapshot)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Food")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add food", systemImage: "plus") { adding = true }
                }
            }
            .navigationDestination(for: PackageID.self) { PackageDetailView(model: model, id: $0) }
            .sheet(isPresented: $adding) { AddFoodView(model: model) }
            .pantryChrome(model)
        }
    }

    @ViewBuilder
    private func content(_ snapshot: PantrySnapshot) -> some View {
        if snapshot.entries.isEmpty {
            ContentUnavailableView {
                Label("Nothing here yet", systemImage: "carrot")
            } description: {
                Text("What you have will appear here, grouped by where you keep it.")
            } actions: {
                Button("Add food") { adding = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            List {
                ForEach(snapshot.locations) { location in
                    section(location.name, snapshot.entries(in: location.id), snapshot)
                }
                section("Somewhere else", snapshot.unplaced, snapshot)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ entries: [PantryEntry], _ snapshot: PantrySnapshot) -> some View {
        if !entries.isEmpty {
            Section(title) {
                ForEach(entries) { entry in
                    EntryRow(entry: entry, locations: snapshot.locations, showsLocation: false) { action in
                        Task { await model.perform(action, on: entry) }
                    }
                }
            }
        }
    }
}
