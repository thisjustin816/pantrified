import SwiftUI

/// The undo offer shown over the bottom of a screen after an action.
struct UndoBanner: View {
    let prompt: PantryModel.UndoPrompt
    let undo: () -> Void

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
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
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
                UndoBanner(prompt: prompt) { Task { await model.undo() } }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: model.undoPrompt)
        .problemAlert(model)
    }
}
