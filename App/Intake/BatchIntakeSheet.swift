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

    var body: some View {
        Group {
            if let intake {
                flow(intake)
            } else if model.intake == nil {
                unavailable
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
        .sheet(isPresented: $addingByHand) { AddFoodView(model: model) }
    }

    @ViewBuilder
    private func flow(_ intake: IntakeModel) -> some View {
        switch intake.stage {
        case .opening:
            ProgressView()
        case .capturing:
            BatchCaptureView(intake: intake, addByHand: { addingByHand = true }, close: { dismiss() })
        case .reading(let progress):
            ReadingView(progress: progress, close: { dismiss() })
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
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
            }
        case .reviewing:
            IntakeReviewView(intake: intake, addByHand: { addingByHand = true }, close: { dismiss() })
        case .unavailable:
            unavailable
        }
    }

    private var unavailable: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Batches aren't available", systemImage: "photo.stack")
            } description: {
                Text("Pantrified couldn't open its folder for batch photos. You can still add food by hand.")
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

/// While the photos are read. Closing keeps everything read so far.
private struct ReadingView: View {
    let progress: IntakeProgress
    let close: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ProgressView(value: Double(progress.read), total: Double(max(progress.total, 1)))
                    .accessibilityLabel(IntakeText.reading(progress))
                Text(IntakeText.reading(progress))
                    .font(.headline)
                Text("Pantrified is reading the labels and barcodes on this iPhone. You can close this; it carries on next time you open the batch.")
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
                    Button("Close", action: close)
                }
            }
        }
    }
}
