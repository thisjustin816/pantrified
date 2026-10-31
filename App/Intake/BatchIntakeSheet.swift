import SwiftUI
import PantrifiedApplication
import PantrifiedDomain

/// Batch intake in one sheet: take or pick photos, Done, review, Add all. Closing keeps the batch,
/// and opening it again carries on where it was left.
struct BatchIntakeSheet: View {
    let model: PantryModel

    @Environment(\.dismiss) private var dismiss
    @State private var intake: IntakeModel?
    @State private var addingByHand = false
    @State private var confirmingDiscard = false

    var body: some View {
        Group {
            if let intake {
                flow(intake)
            } else if model.intake == nil {
                unavailable(nil)
            } else {
                ProgressView()
            }
        }
        .task {
            guard intake == nil, let services = model.intake else { return }
            let opened = IntakeModel(services: services, pantry: model)
            intake = opened
            await opened.start()
        }
        .onDisappear {
            guard let intake else { return }
            Task { await intake.leave() }
        }
        .sheet(isPresented: $addingByHand) { AddFoodView(model: model) }
    }

    @ViewBuilder
    private func flow(_ intake: IntakeModel) -> some View {
        switch intake.stage {
        case .opening:
            ProgressView()
        case .capturing:
            BatchCaptureView(intake: intake, covered: addingByHand, addByHand: { addingByHand = true }, close: { dismiss() })
        case .reading(let progress):
            ReadingView(progress: progress, close: { dismiss() }, discard: { discard(intake) })
        case .finishing:
            IntakeReviewView(intake: intake, addByHand: { addingByHand = true }, close: { dismiss() })
        case .readingStopped:
            NavigationStack {
                ContentUnavailableView {
                    Label("Reading stopped", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Some photos couldn't be read yet. Your photos are kept. Try again, or add food by hand.")
                } actions: {
                    Button("Try Again") { Task { await intake.read() } }
                        .buttonStyle(.borderedProminent)
                    Button("Add by Hand") { addingByHand = true }
                        .buttonStyle(.bordered)
                    Button("Discard Photos", role: .destructive) { confirmingDiscard = true }
                        .buttonStyle(.bordered)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
                .discardConfirmation(isPresented: $confirmingDiscard) { discard(intake) }
            }
        case .reviewing:
            IntakeReviewView(intake: intake, addByHand: { addingByHand = true }, close: { dismiss() })
        case .unavailable:
            unavailable(intake.unavailableDetail)
        }
    }

    private func discard(_ intake: IntakeModel) {
        Task {
            await intake.discard()
            dismiss()
        }
    }

    private func unavailable(_ detail: String?) -> some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Batches aren't available", systemImage: "photo.stack")
            } description: {
                Text(detail ?? "Pantrified couldn't open its folder for batch photos. Try again later. You can still add food by hand.")
            } actions: {
                Button("Add by Hand") { addingByHand = true }
                    .buttonStyle(.borderedProminent)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

extension View {
    /// Asks before deleting a batch's photos while they are being read.
    func discardConfirmation(isPresented: Binding<Bool>, discard: @escaping () -> Void) -> some View {
        confirmationDialog("Discard this batch?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Discard Photos", role: .destructive, action: discard)
        } message: {
            Text("The photos and everything read from them are deleted now. Nothing is added.")
        }
    }

    /// Tells the person about a failure once.
    func intakeProblemAlert(_ intake: IntakeModel) -> some View {
        alert(
            "Something went wrong",
            isPresented: Binding(get: { intake.problem != nil }, set: { if !$0 { intake.dismissProblem() } })
        ) {
            Button("OK") {}
        } message: {
            Text(intake.problem ?? "")
        }
    }
}

/// While the photos are read. Closing keeps everything read so far.
private struct ReadingView: View {
    let progress: IntakeProgress
    let close: () -> Void
    let discard: () -> Void

    @State private var confirmingDiscard = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ProgressView(value: Double(progress.read), total: Double(max(progress.total, 1)))
                    .accessibilityLabel(IntakeText.reading(progress))
                Text(IntakeText.reading(progress))
                    .font(.headline)
                Text("Pantrified is reading the labels and barcodes on this iPhone. You can close this: it carries on while Pantrified is open, and your list is ready next time you open the batch.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Reading photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Menu("Close", systemImage: "xmark") {
                        Button("Keep for Later", systemImage: "tray.and.arrow.down", action: close)
                        Button("Discard Photos", systemImage: "trash", role: .destructive) { confirmingDiscard = true }
                    }
                }
            }
            .discardConfirmation(isPresented: $confirmingDiscard, discard: discard)
        }
    }
}
