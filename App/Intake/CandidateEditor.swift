import SwiftUI
import PantrifiedApplication
import PantrifiedDomain

/// Corrects one candidate: name, date, place and how many, and its photos, any of which can be moved
/// out to an item of its own. Only fields the person changes are saved as theirs.
struct CandidateEditor: View {
    let intake: IntakeModel
    let id: IntakeCandidateID

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var hasDate: Bool
    @State private var label: PrintedDateLabel
    @State private var day: Date
    @State private var confirmingDelete = false
    @FocusState private var nameFocused: Bool
    @ScaledMetric(relativeTo: .body) private var thumbnailSize: CGFloat = 72

    private let original: CandidateSummary?

    init(intake: IntakeModel, id: IntakeCandidateID) {
        self.intake = intake
        self.id = id
        let summary = intake.review?.summary(of: id)
        original = summary
        _name = State(initialValue: summary?.name ?? "")
        _hasDate = State(initialValue: summary?.date != nil)
        _label = State(initialValue: summary?.date?.label ?? summary?.pendingDate?.label ?? .useBy)
        _day = State(initialValue: summary?.date?.date ?? Date())
    }

    private static let labels: [PrintedDateLabel] = [.useBy, .bestBy, .sellBy, .freezeBy, .packed]
    private static let days = Date(timeIntervalSince1970: 946_684_800)...Date(timeIntervalSince1970: 4_102_358_400)

    private var summary: CandidateSummary? { intake.review?.summary(of: id) }

    var body: some View {
        NavigationStack {
            Form {
                if let summary {
                    nameSection(summary)
                    dateSection(summary)
                    Section {
                        Picker("Where", selection: Binding(
                            get: { summary.location },
                            set: { place in if let place { Task { await intake.move([id], to: place) } } }
                        )) {
                            if summary.location == nil {
                                Text("Choose where").tag(LocationID?.none)
                            }
                            ForEach(intake.locations) { place in
                                Text(place.name).tag(Optional(place.id))
                            }
                        }
                    } header: {
                        Text("Where does it go?")
                    } footer: {
                        if let origin = IntakeText.locationOrigin(summary.locationOrigin) {
                            Text(origin)
                        }
                    }
                    Section {
                        Stepper(
                            "How many: \(summary.count)",
                            value: Binding(get: { summary.count }, set: { count in Task { await intake.setCount(count, for: id) } }),
                            in: 1...IntakeLimits.packagesPerCandidate
                        )
                    } footer: {
                        Text("Each one is added as its own package, with the same name and date.")
                    }
                    photosSection(summary)
                    Section {
                        Button("Delete This Item", role: .destructive) { confirmingDelete = true }
                    }
                } else {
                    Text("This item is no longer in the batch.")
                }
            }
            .navigationTitle("Edit item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Task {
                            await save()
                            dismiss()
                        }
                    }
                }
            }
            .confirmationDialog("Delete this item?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Task {
                        await intake.delete([id])
                        dismiss()
                    }
                }
            } message: {
                Text("You can undo this from the review.")
            }
        }
    }

    private func nameSection(_ summary: CandidateSummary) -> some View {
        Section {
            TextField("Name", text: $name)
                .focused($nameFocused)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.done)
        } header: {
            Text("What is it?")
        } footer: {
            if name == (original?.name ?? ""), let origin = IntakeText.nameOrigin(summary.nameOrigin) {
                Text(origin)
            } else if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("An item needs a name before it can be added.")
            }
        }
    }

    @ViewBuilder
    private func dateSection(_ summary: CandidateSummary) -> some View {
        Section {
            if let choice = summary.pendingDate {
                Button("\(AttentionText.label(choice.label)) \(AttentionText.day(choice.monthFirst))") {
                    Task { await intake.chooseDateOrder(.monthFirst, for: id) }
                    adopt(choice.monthFirst, choice.label)
                }
                Button("\(AttentionText.label(choice.label)) \(AttentionText.day(choice.dayFirst))") {
                    Task { await intake.chooseDateOrder(.dayFirst, for: id) }
                    adopt(choice.dayFirst, choice.label)
                }
            }
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
            if summary.pendingDate != nil {
                Text("The label's date reads two ways. Pick the one printed, or set it yourself.")
            } else if let origin = IntakeText.dateOrigin(summary.dateOrigin), hasDate == (original?.date != nil) {
                Text(origin)
            }
        }
    }

    private func photosSection(_ summary: CandidateSummary) -> some View {
        Section {
            ForEach(summary.photos, id: \.self) { photo in
                HStack {
                    Thumbnail(image: intake.thumbnails[photo], size: thumbnailSize)
                        .task { await intake.loadThumbnail(photo) }
                    Spacer()
                    if summary.photos.count > 1 {
                        Button("Make Separate Item") {
                            Task { await intake.split(photo, from: id) }
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .accessibilityElement(children: .contain)
            }
        } header: {
            Text("Photos")
        } footer: {
            if let reason = IntakeText.signals(summary.signals) {
                Text(reason)
            }
        }
    }

    private func adopt(_ date: Date, _ printed: PrintedDateLabel) {
        hasDate = true
        label = printed
        day = date
    }

    /// Saves only what changed, so an untouched proposal stays a proposal.
    private func save() async {
        guard let original else { return }
        if name != (original.name ?? "") {
            await intake.setName(name, for: id)
        }
        let wanted: PrintedDate? = hasDate ? Self.printedDate(label, day) : nil
        let before = original.date
        let changed = hasDate != (before != nil) || (hasDate && (wanted?.label != before?.label || !Self.sameDay(wanted?.date, before?.date)))
        if changed, intake.review?.summary(of: id)?.pendingDate == nil || hasDate {
            await intake.setDate(wanted, for: id)
        }
    }

    private static func printedDate(_ label: PrintedDateLabel, _ day: Date) -> PrintedDate? {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
        return PrintedDate.onDay(label, year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }

    private static func sameDay(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return utc.isDate(a, inSameDayAs: b)
    }
}
