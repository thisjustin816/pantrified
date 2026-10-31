import SwiftUI

/// The undo offer shown over the bottom of a screen after an action.
struct UndoBanner: View {
    let prompt: PantryModel.UndoPrompt
    let undo: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 1 when the offer appears, 0 when it expires.
    @State private var remaining: CGFloat = 1

    var body: some View {
        HStack {
            Text(prompt.message)
                .font(.subheadline)
                .lineLimit(2)
            Spacer(minLength: 12)
            Button("Undo", action: undo)
                .font(.subheadline.bold())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .bottom) { countdown }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: prompt.window.seconds)) { remaining = 0 }
        }
    }

    /// A thin line that runs out as the offer does. Hidden with Reduce Motion.
    @ViewBuilder
    private var countdown: some View {
        if !reduceMotion {
            Capsule()
                .fill(.tint.opacity(0.7))
                .frame(height: 3)
                .scaleEffect(x: remaining, anchor: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
        }
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

extension View {
    /// Shows the model's failure message once, as an alert.
    func problemAlert(_ model: PantryModel) -> some View {
        alert(
            "Something went wrong",
            isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.dismissProblem() } })
        ) {
            Button("OK") {}
        } message: {
            Text(model.problem ?? "")
        }
    }

    /// The undo offer and the failure alert that every list screen shows.
    func pantryChrome(_ model: PantryModel) -> some View {
        safeAreaInset(edge: .bottom) {
            if let prompt = model.undoPrompt {
                // A new offer replaces the old banner, so its countdown starts again.
                UndoBanner(prompt: prompt) { Task { await model.undo() } }
                    .id(prompt.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .problemAlert(model)
    }
}
