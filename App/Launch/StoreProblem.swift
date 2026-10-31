import Foundation
import PantrifiedPersistence

/// Why the app could not open its data, in words for the person using it. Every case leaves the
/// data where it is, and none offers to delete it.
struct StoreProblem: Equatable {
    enum Kind: Equatable {
        case newerVersion
        case cannotOpen
    }

    let kind: Kind
    let title: String
    let message: String
    /// The underlying error, for a person who needs to report it.
    let detail: String

    init(_ error: Error) {
        detail = String(describing: error)
        if case PersistenceError.newerSchema = error {
            kind = .newerVersion
            title = "Update Pantrified"
            message = "Your food list was saved by a newer version of Pantrified. Update the app to open it. Nothing has been changed."
        } else {
            kind = .cannotOpen
            title = "Pantrified can't open your food list"
            message = "Your data is still on this device and has not been changed or deleted. Quit and open Pantrified again. If it keeps happening, update the app."
        }
    }
}
