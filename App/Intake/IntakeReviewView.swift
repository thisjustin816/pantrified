import SwiftUI
import UniformTypeIdentifiers
import PantrifiedApplication
import PantrifiedDomain

/// The batch's candidates by place, ready to add with one tap. Every proposed field says where it
/// came from and is one tap from being corrected; a card, or a selection of cards, can be dragged to
/// another place; every change can be undone.
struct IntakeReviewView: View {
    let intake: IntakeModel
    let addByHand: () -> Void
    let close: () -> Void

    private struct EditTarget: Identifiable {
        let id: IntakeCandidateID
    }

    @State private var selection = Set<IntakeCandidateID>()
    @State private var selecting = false
    @State private var editing: EditTarget?
    @State private var confirmingDiscard = false
    /// The targets a dragged card is over. Kept as a set because leaving one row and entering the
    /// next can be reported in either order.
    @State private var hovered: Set<DropSpot> = []
    /// A card is being dragged over the list, so empty places grow into large targets. Stays on for
    /// a moment after the last target is left, so they do not shrink while the finger crosses the
    /// gap between two rows.
    @State private var dragging = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The place a dragged card would land in now.
    private var targetedPlace: LocationID? { hovered.lazy.compactMap(\.place).first }

    var body: some View {
        NavigationStack {
            Group {
                if intake.summaries.isEmpty && !intake.isFinishing {
                    finished
                } else {
                    list
                }
            }
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .sheet(item: $editing) { target in
                CandidateEditor(intake: intake, id: target.id)
            }
            .confirmationDialog("Discard this batch?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard Batch", role: .destructive) {
                    Task {
                        await intake.discard()
                        close()
                    }
                }
            } message: {
                Text("The photos and everything read from them are deleted now. Food already added stays.")
            }
            .intakeProblemAlert(intake)
        }
    }

    private var list: some View {
        List {
            if case .finishing(let left) = intake.stage {
                Section {
                    Label(IntakeText.readingLeft(left), systemImage: "hourglass")
                        .font(.subheadline)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            ForEach(intake.sections) { section in
                Section {
                    if section.place == nil {
                        unplacedPrompt(section.candidates.map(\.id))
                    }
                    ForEach(section.candidates) { summary in
                        row(summary, in: section)
                    }
                    if let place = section.place, section.candidates.isEmpty {
                        emptyPlace(place)
                    }
                } header: {
                    header(section)
                }
            }
            Section {
            } footer: {
                Text(IntakeText.photosStayHere)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: dragging)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: targetedPlace)
        .onChange(of: hovered.isEmpty) { _, empty in
            if !empty { dragging = true }
        }
        .task(id: hovered.isEmpty) {
            guard hovered.isEmpty, dragging else { return }
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled, hovered.isEmpty { dragging = false }
        }
    }

    // MARK: Sections

    private func name(of place: LocationID?) -> String {
        place.flatMap { intake.locationName($0) } ?? IntakeText.needsAPlace
    }

    private func header(_ section: PlaceSection) -> some View {
        let targeted = section.place != nil && targetedPlace == section.place
        let count = section.candidates.count
        return HStack(spacing: 8) {
            Image(systemName: Self.symbol(for: section.place.flatMap { place in intake.locations.first { $0.id == place } }))
                .accessibilityHidden(true)
            Text(name(of: section.place))
            Text("\(count)")
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(count)))
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
            Spacer(minLength: 8)
            if targeted {
                Label(IntakeText.dropHere(name(of: section.place)), systemImage: "arrow.down.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.tint)
                    .transition(.opacity)
            }
        }
        .font(.headline)
        .foregroundStyle(targeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name(of: section.place)), \(IntakeText.items(count))")
        .accessibilityAddTraits(.isHeader)
        .modifier(PlaceDrop(place: section.place, target: "header", intake: intake, hovered: $hovered))
    }

    /// The prompt over the candidates that have no place, with one menu to put them all in one place.
    private func unplacedPrompt(_ ids: [IntakeCandidateID]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack { unplacedPromptContent(ids) }
            VStack(alignment: .leading, spacing: 8) { unplacedPromptContent(ids) }
        }
        .disabled(intake.isFinishing)
    }

    @ViewBuilder
    private func unplacedPromptContent(_ ids: [IntakeCandidateID]) -> some View {
        Text(IntakeText.needPlace(ids.count))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        Spacer(minLength: 8)
        Menu {
            ForEach(intake.locations) { place in
                Button(place.name) { Task { await intake.move(ids, to: place.id) } }
            }
        } label: {
            Label("Put All In", systemImage: "tray.and.arrow.down")
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
    }

    /// A place with nothing in it. It grows while a card is dragged, so an empty place is as easy to
    /// drop on as one with cards.
    private func emptyPlace(_ place: LocationID) -> some View {
        let targeted = targetedPlace == place
        return Label(
            dragging ? IntakeText.dropHere(name(of: place)) : "Nothing here yet",
            systemImage: dragging ? "arrow.down.circle" : "tray"
        )
        .font(.subheadline)
        .foregroundStyle(targeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .frame(maxWidth: .infinity, minHeight: dragging ? 88 : 44)
        .background {
            if dragging {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: [6, 4]))
                    .foregroundStyle(targeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
        }
        .contentShape(Rectangle())
        .listRowBackground(targeted ? Color.accentColor.opacity(0.14) : nil)
        .modifier(PlaceDrop(place: place, target: "empty", intake: intake, hovered: $hovered))
    }

    private func row(_ summary: CandidateSummary, in section: PlaceSection) -> some View {
        let carried = PlaceDrag.carried(dragging: summary.id, selection: selecting ? selection : [], order: intake.summaries.map(\.id))
        return CandidateCard(
            summary: summary, intake: intake, selecting: selecting, selected: selection.contains(summary.id),
            toggle: { toggle(summary.id) }, edit: { editing = EditTarget(id: summary.id) }
        )
        // The list before the last photos are read is not the review yet.
        .disabled(intake.isFinishing)
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                Task { await intake.delete([summary.id]) }
            }
            Button("Edit", systemImage: "pencil") { editing = EditTarget(id: summary.id) }
        }
        .listRowBackground(section.place != nil && targetedPlace == section.place ? Color.accentColor.opacity(0.14) : nil)
        .modifier(CardDrag(ids: carried, name: summary.name, enabled: !intake.isFinishing))
        .modifier(PlaceDrop(place: section.place, target: summary.id.rawValue.uuidString, intake: intake, hovered: $hovered))
    }

    private func toggle(_ id: IntakeCandidateID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private static func symbol(for location: StorageLocation?) -> String {
        switch location?.storageType {
        case .refrigerated?: "refrigerator"
        case .frozen?: "snowflake"
        case .roomTemperature?: "cabinet"
        case nil: "questionmark.circle"
        }
    }

    // MARK: Chrome

    private var finished: some View {
        ContentUnavailableView {
            Label("Everything is added", systemImage: "checkmark.circle")
        } description: {
            Text("Your food is in your list. \(IntakeText.photosStayHere)")
        } actions: {
            Button("Done") { close() }
                .buttonStyle(.borderedProminent)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Menu("Close", systemImage: "xmark") {
                Button("Keep for Later", systemImage: "tray.and.arrow.down") { close() }
                Button("Add by Hand", systemImage: "square.and.pencil") { addByHand() }
                Button("Discard Batch", systemImage: "trash", role: .destructive) { confirmingDiscard = true }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Undo", systemImage: "arrow.uturn.backward") { Task { await intake.undoChange() } }
                .disabled(!intake.canUndoChange || intake.isFinishing)
        }
        if !intake.summaries.isEmpty && !intake.isFinishing {
            ToolbarItem(placement: .primaryAction) {
                Button(selecting ? "Done" : "Select") {
                    selection = []
                    selecting.toggle()
                }
            }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let added = intake.added {
                AddedBanner(prompt: added) { Task { await intake.undoAdd() } } dismiss: { intake.dismissAdded() }
            }
            if selecting {
                selectionActions
            } else if !intake.summaries.isEmpty {
                let ready = intake.readyIDs.count
                Button {
                    Task { await intake.addAll() }
                } label: {
                    Text(IntakeText.addAll(ready))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(ready == 0 || intake.isAdding || intake.isFinishing)
                // At accessibility sizes the bar would cover most of the list; the cards say it.
                // Candidates with no place are counted at the top of their own section.
                let nameless = intake.namelessCount
                if nameless > 0 && !typeSize.isAccessibilitySize {
                    Text(IntakeText.waiting(nameless))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding()
        .background(.bar)
    }

    private var selectionActions: some View {
        let chosen = intake.summaries.map(\.id).filter(selection.contains)
        return ViewThatFits(in: .horizontal) {
            HStack { selectionButtons(chosen) }
            VStack { selectionButtons(chosen) }
        }
    }

    @ViewBuilder
    private func selectionButtons(_ chosen: [IntakeCandidateID]) -> some View {
        Menu {
            ForEach(intake.locations) { place in
                Button(place.name) {
                    Task { await intake.move(chosen, to: place.id) }
                }
            }
        } label: {
            Label("Move to", systemImage: "arrow.right.square")
        }
        .disabled(chosen.isEmpty)
        .buttonStyle(.bordered)
        Button("Merge", systemImage: "square.on.square") {
            Task {
                await intake.merge(chosen)
                selection = []
            }
        }
        .disabled(chosen.count < 2)
        .buttonStyle(.bordered)
        Button("Add", systemImage: "plus") {
            Task {
                await intake.add(chosen)
                selection = []
            }
        }
        .disabled(chosen.isEmpty)
        .buttonStyle(.bordered)
        Button("Delete", systemImage: "trash", role: .destructive) {
            Task {
                await intake.delete(Set(chosen))
                selection = []
            }
        }
        .disabled(chosen.isEmpty)
        .buttonStyle(.bordered)
    }
}

// MARK: Dragging

/// What a dragged card carries: the identities of the candidates it moves, never a name or a
/// photo. Its type is declared only by Pantrified, so no other app accepts it.
struct CandidateDrag: Codable, Transferable {
    let ids: [UUID]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pantrifiedCandidates)
    }
}

extension UTType {
    /// Declared in the app's Info.plist.
    static let pantrifiedCandidates = UTType(exportedAs: "com.thisjustin816.pantrified.candidates")
}

/// Lets a card be pressed and dragged, lifted under the finger with its name and how many cards
/// go with it.
private struct CardDrag: ViewModifier {
    let ids: [IntakeCandidateID]
    let name: String?
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.draggable(CandidateDrag(ids: ids.map(\.rawValue))) {
                CardLift(name: name, count: ids.count)
            }
        } else {
            content
        }
    }
}

/// The card under the finger while it is dragged.
private struct CardLift: View {
    let name: String?
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: count > 1 ? "square.stack.3d.up.fill" : "shippingbox.fill")
                .foregroundStyle(.tint)
            Text(name ?? "An item without a name")
                .font(.headline)
                .lineLimit(2)
            if count > 1 {
                Text("\(count)")
                    .font(.subheadline.bold())
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.2), in: Capsule())
            }
        }
        .padding(14)
        .frame(maxWidth: 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
        .scaleEffect(1.04)
    }
}

/// One drop target under a dragged card: a row, the end or the header of one section.
private struct DropSpot: Hashable {
    let place: LocationID?
    let target: String
}

/// Makes a row or header a target for a dragged card. A drop on a place moves what the card
/// carries there; the section of candidates with no place takes no drops, though a card over it
/// still counts as being dragged. What a drop carries is checked against the review: identities
/// that are not candidates under review are ignored.
private struct PlaceDrop: ViewModifier {
    let place: LocationID?
    let target: String
    let intake: IntakeModel
    @Binding var hovered: Set<DropSpot>

    func body(content: Content) -> some View {
        content.dropDestination(for: CandidateDrag.self) { items, _ in
            hovered = []
            guard let place, !intake.isFinishing, let review = intake.review else { return false }
            let ids = review.underReview(items.flatMap(\.ids).map { IntakeCandidateID($0) })
            guard !ids.isEmpty else { return false }
            Task { await intake.move(ids, to: place) }
            return true
        } isTargeted: { over in
            let spot = DropSpot(place: place, target: target)
            if over { hovered.insert(spot) } else { hovered.remove(spot) }
        }
    }
}
