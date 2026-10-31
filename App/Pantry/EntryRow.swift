import SwiftUI
import PantrifiedApplication
import PantrifiedDomain

/// One food in a list, with its quick actions as swipes, a long press menu and accessibility actions.
struct EntryRow: View {
    let entry: PantryEntry
    let locations: [StorageLocation]
    let showsLocation: Bool
    let act: (PackageAction) -> Void

    private var canOpen: Bool { entry.package.openedAt == nil }
    private var otherLocations: [StorageLocation] { locations.filter { $0.id != entry.package.location } }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
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
            Spacer(minLength: 8)
            if let badge = AttentionText.badge(entry.assessment.state) {
                Text(badge)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(badgeColor.opacity(0.18), in: Capsule())
            }
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

    private var badgeColor: Color {
        entry.assessment.state == .pastGuidance ? .red : .orange
    }
}
