import SwiftUI
import PantrifiedApplication
import PantrifiedDomain

/// The offer to undo the last Add, which stays while the batch is open.
struct AddedBanner: View {
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
/// doubts, each with the one tap that settles it. While selecting, a tap on the card selects it.
struct CandidateCard: View {
    let summary: CandidateSummary
    let intake: IntakeModel
    var selecting = false
    var selected = false
    var toggle: () -> Void = {}
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
        HStack(alignment: .top, spacing: 12) {
            if selecting {
                Button(action: toggle) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(summary.name ?? "No name")
                .accessibilityValue(selected ? "Selected" : "Not selected")
                .accessibilityHint(selected ? "Deselect this item" : "Select this item")
            }
            content
                .allowsHitTesting(!selecting)
        }
        .contentShape(Rectangle())
        .gesture(TapGesture().onEnded { toggle() }, isEnabled: selecting)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "Edit") { edit() }
        .accessibilityAction(named: "Delete") { Task { await intake.delete([summary.id]) } }
        .accessibilityActions {
            ForEach(intake.locations.filter { $0.id != summary.location }) { place in
                Button("Move to \(place.name)") { Task { await intake.move([summary.id], to: place.id) } }
            }
        }
    }

    private var content: some View {
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
                Button(place.name) { Task { await intake.move([summary.id], to: place.id) } }
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
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityLabel("Where it goes: \(intake.locationName(summary.location) ?? "not chosen")")
        .accessibilityValue(IntakeText.locationOrigin(summary.locationOrigin) ?? "")
        .accessibilityHint("Choose another place")
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
