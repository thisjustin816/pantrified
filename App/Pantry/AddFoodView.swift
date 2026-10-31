import SwiftUI
import PantrifiedApplication
import PantrifiedDomain

/// Adds one food by hand. Only the name and where it goes are needed; how much and a date on the
/// package are optional, because unknown is a fine state.
struct AddFoodView: View {
    let model: PantryModel

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var location: LocationID?
    @State private var quantity: Quantity = .unknown
    @State private var hasDate = false
    @State private var label: PrintedDateLabel = .useBy
    @State private var day = Date()
    @State private var saving = false
    @FocusState private var nameFocused: Bool

    private static let labels: [PrintedDateLabel] = [.useBy, .bestBy, .sellBy, .freezeBy, .packed]
    /// 1 January 2000 to 31 December 2099, the days a printed date can name.
    private static let days = Date(timeIntervalSince1970: 946_684_800)...Date(timeIntervalSince1970: 4_102_358_400)

    private var locations: [StorageLocation] { model.snapshot?.locations ?? [] }
    private var canAdd: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && location != nil && !saving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What is it?") {
                    TextField("Name", text: $name)
                        .focused($nameFocused)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                }
                Section("Where does it go?") {
                    Picker("Where", selection: $location) {
                        ForEach(locations) { place in
                            Text(place.name).tag(Optional(place.id))
                        }
                    }
                }
                Section("How much is there?") {
                    Picker("How much", selection: $quantity) {
                        Text("Not sure").tag(Quantity.unknown)
                        Text("Full").tag(Quantity.full)
                        Text("About half").tag(Quantity.aboutHalf)
                        Text("Almost gone").tag(Quantity.low)
                    }
                }
                Section {
                    Toggle("There's a date on it", isOn: $hasDate)
                    if hasDate {
                        Picker("The date is a", selection: $label) {
                            ForEach(Self.labels, id: \.self) { Text(AttentionText.label($0)).tag($0) }
                        }
                        DatePicker("Date", selection: $day, in: Self.days, displayedComponents: .date)
                    }
                } header: {
                    Text("Date on the package")
                } footer: {
                    Text("Use by and best by dates are used to flag food. Other dates are kept but not used.")
                }
            }
            .navigationTitle("Add food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save() } }
                        .disabled(!canAdd)
                }
            }
            .onAppear {
                if location == nil { location = locations.first?.id }
                nameFocused = true
            }
            .problemAlert(model)
        }
    }

    private func save() async {
        guard let location else { return }
        saving = true
        defer { saving = false }
        var printed: PrintedDate?
        if hasDate {
            let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
            printed = PrintedDate.onDay(label, year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
        }
        let food = NewFood(name: name, location: location, quantity: quantity, printedDate: printed)
        if await model.add(food) { dismiss() }
    }
}
