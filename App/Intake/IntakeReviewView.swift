import SwiftUI
import PantrifiedApplication
import PantrifiedDomain

/// The batch's candidates, ready to add with one tap. Every proposed field says where it came from
/// and is one tap from being corrected; every change can be undone.
struct IntakeReviewView: View {
    let intake: IntakeModel
    let addByHand: () -> Void
    let close: () -> Void

    private struct EditTarget: Identifiable {
        let id: IntakeCandidateID
    }

    @State private var selection = Set<IntakeCandidateID>()
    @State private var editMode = EditMode.inactive
    @State private var editing: EditTarget?
    @State private var confirmingDiscard = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private var selecting: Bool { editMode.isEditing }

    var body: some View {
        NavigationStack {
            Group {
                if intake.summaries.isEmpty {
                    finished
                } else {
                    list
                }
            }
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .environment(\.editMode, $editMode)
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
        List(selection: $selection) {
            Section {
                ForEach(intake.summaries) { summary in
                    CandidateCard(summary: summary, intake: intake) { editing = EditTarget(id: summary.id) }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task { await intake.delete([summary.id]) }
                            }
                            Button("Edit", systemImage: "pencil") { editing = EditTarget(id: summary.id) }
                        }
                }
            } footer: {
                Text(IntakeText.photosStayHere)
            }
        }
    }

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
                .disabled(!intake.canUndoChange)
        }
        if !intake.summaries.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Button(selecting ? "Done" : "Select") {
                    selection = []
                    editMode = selecting ? .inactive : .active
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
                .disabled(ready == 0 || intake.isAdding)
                let waiting = intake.summaries.count - ready
                // At accessibility sizes the bar would cover most of the list; the cards say it.
                if waiting > 0 && !typeSize.isAccessibilitySize {
                    Text(IntakeText.waiting(waiting))
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
                    Task { await intake.assign(place.id, to: Set(chosen)) }
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

/// The offer to undo the last Add, which stays while the batch is open.
private struct AddedBanner: View {
    let prompt: IntakeModel.AddedPrompt
    let undo: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack {
            Label(prompt.message, systemImage: "checkmark.circle.fill")
                .font(.subheadline)
            Spacer(minLength: 12)
            Button("Undo", action: undo)
                .font(.subheadline.bold())
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// One candidate: its photos, its proposed name, date and place with where each came from, and its
/// doubts, each with the one tap that settles it.
struct CandidateCard: View {
    let summary: CandidateSummary
    let intake: IntakeModel
    let edit: () -> Void

    @ScaledMetric(relativeTo: .body) private var thumbnailSize: CGFloat = 64
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Photo beside the text, or above it at accessibility sizes so the name keeps the full width.
    private var layout: AnyLayout {
        typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            layout {
                photo
                VStack(alignment: .leading, spacing: 6) {
                    nameRow
                    dateRow
                    placeRow
                    if summary.count > 1 || summary.notes.contains(.maybeSeveralPackages) {
                        Stepper(
                            "How many: \(summary.count)",
                            value: Binding(
                                get: { summary.count },
                                set: { count in Task { await intake.setCount(count, for: summary.id) } }
                            ),
                            in: 1...IntakeLimits.packagesPerCandidate
                        )
                        .font(.subheadline)
                    }
                }
            }
            ForEach(Array(summary.notes.enumerated()), id: \.offset) { _, note in
                noteRow(note)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Edit") { edit() }
        .accessibilityAction(named: "Delete") { Task { await intake.delete([summary.id]) } }
    }

    private var photo: some View {
        ZStack(alignment: .bottomTrailing) {
            Thumbnail(image: summary.photos.first.flatMap { intake.thumbnails[$0] }, size: min(thumbnailSize, 96))
            if summary.photos.count > 1 {
                Text("\(summary.photos.count)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.thinMaterial, in: Capsule())
                    .padding(3)
            }
        }
        .task(id: summary.photos.first) {
            if let first = summary.photos.first { await intake.loadThumbnail(first) }
        }
        .accessibilityHidden(true)
    }

    private var nameRow: some View {
        Button(action: edit) {
            VStack(alignment: .leading, spacing: 2) {
                if let name = summary.name {
                    Text(name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                } else {
                    Label("Add a name", systemImage: "pencil")
                        .font(.headline)
                }
                if let origin = IntakeText.nameOrigin(summary.nameOrigin) {
                    Text(origin)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(summary.name ?? "No name")
        .accessibilityValue(IntakeText.nameOrigin(summary.nameOrigin) ?? "")
        .accessibilityHint("Edit this item")
    }

    @ViewBuilder
    private var dateRow: some View {
        if let choice = summary.pendingDate {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(AttentionText.label(choice.label)): which date?")
                    .font(.subheadline)
                ViewThatFits(in: .horizontal) {
                    HStack { dateChoices(choice) }
                    VStack(alignment: .leading) { dateChoices(choice) }
                }
            }
        } else if let date = summary.date {
            VStack(alignment: .leading, spacing: 2) {
                Text(IntakeText.date(date))
                    .font(.subheadline)
                if let origin = IntakeText.dateOrigin(summary.dateOrigin) {
                    Text(origin)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        } else {
            Button("Add a date", systemImage: "calendar.badge.plus", action: edit)
                .font(.subheadline)
                .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func dateChoices(_ choice: PendingDateChoice) -> some View {
        Button(AttentionText.day(choice.monthFirst)) {
            Task { await intake.chooseDateOrder(.monthFirst, for: summary.id) }
        }
        .buttonStyle(.bordered)
        Button(AttentionText.day(choice.dayFirst)) {
            Task { await intake.chooseDateOrder(.dayFirst, for: summary.id) }
        }
        .buttonStyle(.bordered)
    }

    private var placeRow: some View {
        Menu {
            ForEach(intake.locations) { place in
                Button(place.name) { Task { await intake.assign(place.id, to: [summary.id]) } }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Label(intake.locationName(summary.location) ?? "Choose where", systemImage: "mappin.and.ellipse")
                    .font(.subheadline)
                if let origin = IntakeText.locationOrigin(summary.locationOrigin) {
                    Text(origin)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Where it goes: \(intake.locationName(summary.location) ?? "not chosen")")
    }

    @ViewBuilder
    private func noteRow(_ note: CandidateNote) -> some View {
        if let text = IntakeText.note(note, name: { intake.name(of: $0) }) {
            VStack(alignment: .leading, spacing: 6) {
                Label(text, systemImage: Self.symbol(note))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if case .mightBeSameAs(let others) = note, let other = others.first {
                    ViewThatFits(in: .horizontal) {
                        HStack { sameActions(other) }
                        VStack(alignment: .leading) { sameActions(other) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sameActions(_ other: IntakeCandidateID) -> some View {
        Button("Merge", systemImage: "square.on.square") {
            Task { await intake.merge([summary.id, other]) }
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Merge with \(intake.name(of: other) ?? "the other item")")
        Button("Not the same") {
            Task { await intake.keepApart(summary.id, other) }
        }
        .buttonStyle(.bordered)
    }

    private static func symbol(_ note: CandidateNote) -> String {
        switch note {
        case .mightBeSameAs: "square.on.square"
        case .noName: "questionmark.circle"
        case .dateUnclear, .datesDisagree, .dateMatchedByOrder: "calendar.badge.exclamationmark"
        case .lookingUp: "magnifyingglass"
        case .linkSeen: "qrcode"
        default: "exclamationmark.circle"
        }
    }
}
