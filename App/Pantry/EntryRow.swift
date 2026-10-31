import SwiftUI
import PantrifiedApplication
import PantrifiedDomain

/// One food in a list, with its quick actions as swipes, a long press menu and accessibility actions.
struct EntryRow: View {
    let entry: PantryEntry
    let locations: [StorageLocation]
    let showsLocation: Bool
    let act: (PackageAction) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    private var canOpen: Bool { entry.package.openedAt == nil }
    private var otherLocations: [StorageLocation] { locations.filter { $0.id != entry.package.location } }

    var body: some View {
        NavigationLink(value: entry.id) {
            // Beside the text at ordinary sizes. At accessibility sizes there is no room beside it, so
            // the badge goes underneath rather than being squeezed until its words break.
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        summary
                        badge
                    }
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        summary
                        Spacer(minLength: 8)
                        badge
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .swipeActions(edge: .leading) {
            if canOpen {
                Button("Opened", systemImage: "seal") { act(.opened) }.tint(.blue)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Used up", systemImage: "checkmark") { act(.usedUp) }.tint(.green)
            Button("Discard", systemImage: "trash") { act(.discard(reason: nil)) }.tint(.red)
        }
        .contextMenu {
            if canOpen {
                Button("Opened", systemImage: "seal") { act(.opened) }
            }
            Button("Used up", systemImage: "checkmark") { act(.usedUp) }
            if !otherLocations.isEmpty {
                Menu("Move to", systemImage: "arrow.right") {
                    ForEach(otherLocations) { location in
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
        }
        .accessibilityAction(named: "Used up") { act(.usedUp) }
        .accessibilityAction(named: "Discard") { act(.discard(reason: nil)) }
        .accessibilityAction(named: "Opened") { if canOpen { act(.opened) } }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.package.name)
                .font(.headline)
            let detail = AttentionText.detail(for: entry, showsLocation: showsLocation)
            if !detail.isEmpty {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var badge: some View {
        if let text = AttentionText.badge(entry.assessment.state) {
            Text(text)
                .font(.caption.bold())
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(badgeColor.opacity(0.18), in: Capsule())
        }
    }

    private var badgeColor: Color {
        entry.assessment.state == .pastGuidance ? .red : .orange
    }
}
