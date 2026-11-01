import SwiftUI
import UIKit
import PantrifiedApplication
import PantrifiedDomain

/// The preview of "Copy What the App Read": every line and name the file would hold, grouped by
/// photo, each of which the person can leave out, and Share. The file is written only when Share
/// is tapped, and deleted when the share sheet closes or this screen goes away.
struct ReadExportView: View {
    let source: ReadExportSource

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ReadExportDraft?
    @State private var shared: SharedFile?
    @State private var problem: String?

    private let files = ReadExportFiles.temporary

    var body: some View {
        NavigationStack {
            Group {
                if let draft {
                    preview(draft)
                } else {
                    ProgressView("Gathering what was read")
                }
            }
            .navigationTitle("What the App Read")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Share", systemImage: "square.and.arrow.up") { share() }
                        .disabled(draft == nil)
                        .accessibilityHint("Opens the share sheet with this file. Nothing is sent until you choose where it goes.")
                }
            }
            .alert("Couldn't make the file", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK") {}
            } message: {
                Text(problem ?? "")
            }
        }
        .task {
            guard draft == nil else { return }
            let source = source
            draft = await Task.detached(priority: .userInitiated) { ReadExportDraft(source: source) }.value
        }
        .sheet(item: $shared, onDismiss: { files.removeAll() }) { file in
            ShareSheet(file: file.url) { shared = nil }
                .presentationDetents([.medium, .large])
        }
        .onDisappear { files.removeAll() }
    }

    private func share() {
        guard let draft else { return }
        do {
            files.removeAll()
            shared = SharedFile(url: try files.write(draft.export().encoded()))
        } catch {
            problem = "Pantrified couldn't write the file to share. Try again."
        }
    }

    // MARK: The preview

    private func preview(_ draft: ReadExportDraft) -> some View {
        List {
            Section {
                Label {
                    Text(ReadExportText.publicWarning)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.subheadline.weight(.semibold))
                Text(ReadExportText.whatItIs)
                    .font(.subheadline)
            }
            Section("Left out automatically") {
                Text(ReadExportText.check)
                    .font(.subheadline)
                let leftOut = draft.linesLeftOutByCheck
                if leftOut > 0 {
                    Text(leftOut == 1 ? "1 line is left out by the check." : "\(leftOut) lines are left out by the check.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Also in the file") {
                Text("Pantrified \(source.app.version) (\(source.app.build)), \(source.app.system), \(source.app.device)")
                    .font(.subheadline)
                Text(ReadExportText.alsoIncluded)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(draft.photos) { photo in
                photoSection(photo, draft: draft)
            }
            if !draft.names.isEmpty {
                Section {
                    ForEach(draft.names) { name in
                        nameRow(name, draft: draft)
                    }
                } header: {
                    Text("Names")
                } footer: {
                    Text("A name read from a line you left out is left out too.")
                }
            }
        }
    }

    private func photoSection(_ photo: ReadExportDraft.PhotoItem, draft: ReadExportDraft) -> some View {
        Section {
            Toggle("Include this photo's text and codes", isOn: binding(
                get: { $0.includes(photo: photo.id) }, set: { $0.setIncluded($1, photo: photo.id) }
            ))
            .font(.subheadline.weight(.semibold))
            if draft.includes(photo: photo.id) {
                if photo.lines.isEmpty && photo.codes.isEmpty {
                    Text("No text or codes were read from this photo.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(photo.lines) { line in
                    Toggle(isOn: binding(get: { $0.includes(line.id) }, set: { $0.setIncluded($1, line: line.id) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.text)
                            if let flag = line.flag {
                                Text(ReadExportText.flag(flag))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                ForEach(Array(photo.codes.enumerated()), id: \.offset) { _, code in
                    Label(ReadExportText.code(code), systemImage: code.kind == .product ? "barcode" : "qrcode")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Photo \(photo.id + 1)")
        } footer: {
            Text(ReadExportText.seconds(photo.secondsAfterFirst))
        }
    }

    @ViewBuilder
    private func nameRow(_ name: ReadExportDraft.NameItem, draft: ReadExportDraft) -> some View {
        let leftOutWithLine = !draft.includes(name.id) && !draft.excludedNames.contains(name.id)
        Toggle(isOn: binding(get: { $0.includes(name.id) }, set: { $0.setIncluded($1, name: name.id) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name.text)
                Text(leftOutWithLine ? "Left out with the line or photo it came from" : ReadExportText.nameSource(name))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let flag = name.flag {
                    Text(ReadExportText.flag(flag))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(leftOutWithLine)
    }

    private func binding(get: @escaping (ReadExportDraft) -> Bool, set: @escaping (inout ReadExportDraft, Bool) -> Void) -> Binding<Bool> {
        Binding(
            get: { draft.map(get) ?? false },
            set: { value in
                guard var changed = draft else { return }
                set(&changed, value)
                draft = changed
            }
        )
    }
}

private struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The system share sheet for one file. `finished` runs when the sheet closes, shared or not.
private struct ShareSheet: UIViewControllerRepresentable {
    let file: URL
    let finished: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in finished() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The words of the export preview.
enum ReadExportText {
    static let publicWarning = "Don't post this file anywhere public, such as a GitHub issue or discussion: Pantrified's repository is public. Send it to the developer directly."

    static let whatItIs = "This file holds the text, barcodes and grouping Pantrified read from this batch, so a problem can be turned into a test. It holds no photos. Nothing leaves this iPhone until you tap Share and choose where it goes, and the file is deleted when the share sheet closes."

    static let check = "Lines and names that look like an email address, a phone number, a street address, a long number such as a card or account number, or a name after a title such as Mrs or Dr start out left out. This check goes by the shape of the text and misses a lot, such as a name on its own or an address without a house number. Read every line below and turn off anything you don't want to share."

    static let alsoIncluded = "Barcode numbers and what the lookup answered, how the photos were grouped and scored, the seconds between photos, the day of the batch, and the changes you made. Places appear as fridge, freezer or pantry, never by their names."

    static func flag(_ kind: SensitiveText.Kind) -> String {
        switch kind {
        case .email: "Looks like an email address"
        case .phone: "Looks like a phone number"
        case .streetAddress: "Looks like an address"
        case .longNumber: "Looks like a card or account number"
        case .personName: "Looks like a person's name"
        }
    }

    static func code(_ code: ReadExport.Code) -> String {
        switch code.kind {
        case .product: "Barcode \(code.product ?? "")"
        case .refused: "A barcode that isn't a product's"
        case .link: "A QR code with a link. The link isn't included."
        case .otherQR: "A QR code without a link. Its text isn't included."
        }
    }

    static func seconds(_ value: Double) -> String {
        if value == 0 { return "The first photo." }
        let rounded = Int(value.rounded())
        return rounded == 1 ? "Taken 1 second after the first photo." : "Taken \(rounded) seconds after the first photo."
    }

    static func nameSource(_ name: ReadExportDraft.NameItem) -> String {
        let photos = name.photos.map { String($0 + 1) }.joined(separator: ", ")
        let on = name.photos.isEmpty ? "" : (name.photos.count == 1 ? ", photo \(photos)" : ", photos \(photos)")
        return switch name.id {
        case .label: "Read from the label\(on)"
        case .lookup: "From the product lookup\(on)"
        case .person: "You typed this\(on)"
        }
    }
}
