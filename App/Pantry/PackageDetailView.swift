import SwiftUI
import PantrifiedApplication
import PantrifiedDomain

/// One food: what is known about it, why it is flagged, and the actions that apply to it.
struct PackageDetailView: View {
    let model: PantryModel
    let id: PackageID

    @Environment(\.dismiss) private var dismiss

    private var entry: PantryEntry? { model.snapshot?.entries.first { $0.id == id } }

    var body: some View {
        Group {
            if let entry {
                content(entry)
            } else {
                ContentUnavailableView(
                    "No longer in your list",
                    systemImage: "tray",
                    description: Text("This food was used up, discarded or removed.")
                )
            }
        }
        .navigationTitle(entry?.package.name ?? "Food")
        .navigationBarTitleDisplayMode(.inline)
        .pantryChrome(model)
    }

    private func content(_ entry: PantryEntry) -> some View {
        let locations = (model.snapshot?.locations ?? []).filter { $0.id != entry.package.location }
        return List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.package.name)
                        .font(.title2.bold())
                    if let badge = AttentionText.badge(entry.assessment.state) {
                        Text(badge)
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(badgeColor(entry).opacity(0.18), in: Capsule())
                    }
                    if let reason = AttentionText.reason(for: entry.assessment) {
                        Text(reason)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Details") {
                ForEach(PackageDetailText.rows(for: entry)) { row in
                    LabeledContent(row.label, value: row.value)
                }
            }
            if let guidance = PackageDetailText.guidance(for: entry, storageType: storageType(of: entry)) {
                Section {
                    ForEach(guidance.rows) { row in
                        LabeledContent(row.label, value: row.value)
                    }
                } header: {
                    Text("How long it keeps")
                } footer: {
                    Text("From \(guidance.source). Guidance, not an expiration date.")
                }
            }
            Section {
                if entry.package.openedAt == nil {
                    Button("Mark as opened", systemImage: "seal") { act(.opened) }
                }
                Button("Used up", systemImage: "checkmark") { act(.usedUp) }
                if !locations.isEmpty {
                    Menu("Move to", systemImage: "arrow.right") {
                        ForEach(locations) { location in
                            Button(location.name) { act(.move(to: location.id)) }
                        }
                    }
                }
                Menu("Discard", systemImage: "trash") {
                    Button("Spoiled") { act(.discard(reason: .spoiled)) }
                    Button("Didn't want it") { act(.discard(reason: .unwanted)) }
                    Button("Other reason") { act(.discard(reason: .other)) }
                    Button("No reason") { act(.discard(reason: nil)) }
                }
                .foregroundStyle(.red)
            }
        }
    }

    /// Runs the action, then leaves the screen when the food is no longer in the list. An undo is
    /// offered on the screen it returns to.
    private func act(_ action: PackageAction) {
        guard let entry else { return }
        Task {
            await model.perform(action, on: entry)
            if model.snapshot?.entries.contains(where: { $0.id == id }) != true { dismiss() }
        }
    }

    /// The storage type of the place the food is kept, from the Space's locations.
    private func storageType(of entry: PantryEntry) -> StorageType? {
        model.snapshot?.locations.first { $0.id == entry.package.location }?.storageType
    }

    private func badgeColor(_ entry: PantryEntry) -> Color {
        entry.assessment.state == .pastGuidance ? .red : .orange
    }
}
