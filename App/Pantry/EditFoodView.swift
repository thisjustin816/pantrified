import SwiftUI
import PantrifiedApplication
import PantrifiedDomain

/// Changes what a food is called, how much is left and the date on its package. Where it is kept
/// changes through Move, and Undo after saving puts back everything changed.
struct EditFoodView: View {
    let model: PantryModel
    let entry: PantryEntry

    @Environment(\.dismiss) private var dismiss
    @State private var draft: EditFoodDraft
    @State private var saving = false

    /// 1 January 2000 to 31 December 2099, the days a printed date can name.
    private static let days = Date(timeIntervalSince1970: 946_684_800)...Date(timeIntervalSince1970: 4_102_358_400)

    init(model: PantryModel, entry: PantryEntry) {
        self.model = model
        self.entry = entry
        _draft = State(initialValue: EditFoodDraft(package: entry.package))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What is it?") {
                    TextField("Name", text: $draft.name)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                }
                Section("How much is there?") {
                    Picker("How much", selection: $draft.quantity) {
                        ForEach(draft.quantityChoices, id: \.self) { choice in
                            Text(QuantityText.label(choice) ?? "Not sure").tag(choice)
                        }
                    }
                }
                Section {
                    Toggle("There's a date on it", isOn: $draft.hasDate)
                    if draft.hasDate {
                        Picker("The date is a", selection: $draft.label) {
                            ForEach(draft.labelChoices, id: \.self) { Text(AttentionText.label($0)).tag($0) }
                        }
                        DatePicker("Date", selection: $draft.day, in: Self.days, displayedComponents: .date)
                    }
                } header: {
                    Text("Date on the package")
                } footer: {
                    Text("Use by and best by dates are used to flag food. Other dates are kept but not used.")
                }
            }
            .navigationTitle("Edit food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!draft.canSave() || saving)
                }
            }
            .problemAlert(model)
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        if await model.edit(draft.edit(), on: entry) { dismiss() }
    }
}
