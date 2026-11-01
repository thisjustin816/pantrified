import SwiftUI
import PantrifiedApplication
import PantrifiedDomain

/// Lists the USDA FoodKeeper foods a food could be. Picking one, or None of these, is saved at once
/// and can be undone from the banner.
struct FoodKeeperPickerView: View {
    let model: PantryModel
    let entry: PantryEntry
    let question: GuidanceRecordQuestion

    @Environment(\.dismiss) private var dismiss
    @State private var saving = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(question.candidates, id: \.id) { record in
                        choiceRow(
                            PackageDetailText.recordName(record), detail: record.category, selected: question.isCurrent(record)
                        ) {
                            choose(question.choice(for: record))
                        }
                    }
                } header: {
                    Text("Which FoodKeeper food is this?")
                } footer: {
                    Text("From \(question.source). Guidance, not an expiration date.")
                }
                Section {
                    choiceRow("None of these", detail: nil, selected: question.isDeclined) { choose(.noneOfThese) }
                    if question.canClear {
                        Button("Clear my choice", role: .destructive) { choose(nil) }
                    }
                } footer: {
                    Text(question.canClear
                        ? "None of these leaves the food without FoodKeeper guidance. Clearing your choice matches it by its name again."
                        : "None of these leaves the food without FoodKeeper guidance.")
                }
            }
            .disabled(saving)
            .navigationTitle(entry.package.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .problemAlert(model)
        }
    }

    /// One choice: its name, what tells it apart, and a check mark on the one in use. VoiceOver reads
    /// the row as one button and reports the one in use as selected.
    private func choiceRow(_ title: String, detail: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func choose(_ choice: GuidanceChoice?) {
        saving = true
        Task {
            if await model.chooseGuidance(choice, on: entry) { dismiss() }
            saving = false
        }
    }
}
