import SwiftUI
import PantrifiedApplication
import PantrifiedDomain

/// Adds one food by hand. Only the name and where it goes are needed; how much and a date on the
/// package are optional, because unknown is a fine state. Opened from a scan, it carries the
/// barcode and may suggest a name from a product lookup, which the person checks before adding.
struct AddFoodView: View {
    let model: PantryModel
    let barcode: GTIN?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var location: LocationID?
    @State private var quantity: Quantity = .unknown
    @State private var hasDate = false
    @State private var label: PrintedDateLabel = .useBy
    @State private var day = Date()
    @State private var saving = false
    @State private var lookup = LookupState.off
    @FocusState private var nameFocused: Bool

    private enum LookupState: Equatable {
        case off
        case looking
        case suggested(ProductSuggestion)
        case notFound
        case failed
    }

    init(model: PantryModel, barcode: GTIN? = nil) {
        self.model = model
        self.barcode = barcode
        // A screenshot run opens with an example in the form; a normal launch opens it empty.
        let example = StartScreen.current.fillsAddFoodExample
        _name = State(initialValue: example ? "Greek yogurt" : "")
        _quantity = State(initialValue: example ? .full : .unknown)
        _hasDate = State(initialValue: example)
        _label = State(initialValue: example ? .bestBy : .useBy)
        _day = State(initialValue: example ? Date().addingTimeInterval(10 * 86_400) : Date())
    }

    private static let labels: [PrintedDateLabel] = [.useBy, .bestBy, .sellBy, .freezeBy, .packed]
    /// 1 January 2000 to 31 December 2099, the days a printed date can name.
    private static let days = Date(timeIntervalSince1970: 946_684_800)...Date(timeIntervalSince1970: 4_102_358_400)

    private var locations: [StorageLocation] { model.snapshot?.locations ?? [] }
    private var canAdd: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && location != nil && !saving
    }
    /// The name is the lookup's suggestion, unchanged by the person.
    private var nameIsSuggested: Bool {
        if case .suggested(let suggestion) = lookup { return name == suggestion.name }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .focused($nameFocused)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                } header: {
                    Text("What is it?")
                } footer: {
                    lookupNote
                }
                if let barcode {
                    Section {
                        LabeledContent("Barcode", value: barcode.issuedForm)
                            .monospacedDigit()
                    } footer: {
                        Text("A barcode names the product, not this package. It's kept with this food on this device.")
                    }
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
                nameFocused = StartScreen.current.focusesName
            }
            .task { await lookUpName() }
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
        let food = NewFood(
            name: name, nameSource: nameIsSuggested ? .lookup : .person, location: location,
            quantity: quantity, printedDate: printed, barcode: barcode
        )
        if await model.add(food) { dismiss() }
    }

    @ViewBuilder
    private var lookupNote: some View {
        switch lookup {
        case .off:
            EmptyView()
        case .looking:
            Label {
                Text("Looking up this barcode with USDA FoodData Central. You can add the food without waiting.")
            } icon: {
                ProgressView()
            }
        case .suggested(let suggestion):
            if nameIsSuggested {
                Label("Name suggested by \(suggestion.source). Check it before adding.", systemImage: "info.circle")
            }
        case .notFound:
            Text("No product found for this barcode. Enter a name.")
        case .failed:
            Text("Couldn't look this up. Enter a name.")
        }
    }

    /// Fills an empty name with the lookup's suggestion. A name the person has started typing is
    /// never replaced, and leaving the form cancels the lookup.
    private func lookUpName() async {
        guard let barcode, model.looksUpProducts, lookup == .off else { return }
        lookup = .looking
        switch await model.lookUp(barcode) {
        case .found(let suggestion)?:
            lookup = .suggested(suggestion)
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = suggestion.name }
        case .notFound?:
            lookup = .notFound
        case .failed(.cancelled)?, nil:
            lookup = .off
        case .failed?:
            lookup = .failed
        }
    }
}
