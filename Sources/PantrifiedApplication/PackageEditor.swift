import Foundation
import PantrifiedDomain

/// One field of an edit: left as it is, or set to a value. For a field that may be empty, such as
/// the date on a package, `set(nil)` clears it.
public enum FieldEdit<Value: Sendable & Hashable>: Sendable, Hashable {
    case keep
    case set(Value)
}

/// What a person changed about a food by hand: its name, how much is left, the date on its
/// package, which record of the storage guidance it is. Where the food is kept changes through
/// Move, and opening it through Opened.
public struct PackageEdit: Sendable, Hashable {
    public var name: FieldEdit<String>
    public var quantity: FieldEdit<Quantity>
    public var printedDate: FieldEdit<PrintedDate?>
    /// `set(nil)` clears the choice, so the food is matched to guidance by its name again.
    public var guidanceRecord: FieldEdit<GuidanceChoice?>

    public init(
        name: FieldEdit<String> = .keep,
        quantity: FieldEdit<Quantity> = .keep,
        printedDate: FieldEdit<PrintedDate?> = .keep,
        guidanceRecord: FieldEdit<GuidanceChoice?> = .keep
    ) {
        self.name = name
        self.quantity = quantity
        self.printedDate = printedDate
        self.guidanceRecord = guidanceRecord
    }
}

public enum EditOutcome: Sendable, Hashable {
    /// One token for each field that changed, to undo together.
    case applied([UndoToken])
    /// The food already held every value, so no history entry was written.
    case unchanged
}

/// Applies a person's edit to one active package. A name, a date and a choice of guidance record are
/// recorded as the person's own corrections, so recognition and lookups never replace them later; a
/// quantity is recorded as a quantity change. Every changed field is one history entry, written and
/// saved together, and the entries undo together.
public struct PackageEditor: Sendable {
    private let inventory: any InventoryRepository
    private let time: any TimeSource

    public init(inventory: any InventoryRepository, time: any TimeSource) {
        self.inventory = inventory
        self.time = time
    }

    public func apply(_ edit: PackageEdit, to id: PackageID) async throws -> EditOutcome {
        guard var package = try await inventory.package(id) else { throw PackageActionError.packageNotFound }
        guard package.status == .active else { throw PackageError.notActive }

        var changes: [PackageChange] = []
        if case .set(let typed) = edit.name {
            let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw PantryError.nameRequired }
            if name != package.name { changes.append(.corrected(.name(name))) }
        }
        if case .set(let quantity) = edit.quantity, quantity != package.quantity {
            changes.append(.quantityChanged(quantity))
        }
        if case .set(let date) = edit.printedDate, date != package.printedDate {
            changes.append(.corrected(.printedDate(date)))
        }
        if case .set(let choice) = edit.guidanceRecord, choice != package.guidanceChoice {
            changes.append(.corrected(.guidanceRecord(choice)))
        }
        guard !changes.isEmpty else { return .unchanged }

        let now = time.now()
        var tokens: [UndoToken] = []
        for change in changes {
            tokens.append(UndoToken(packageID: id, eventID: try package.record(change, at: now)))
        }
        try await inventory.save(package)
        return .applied(tokens)
    }

    /// Undoes every entry of one edit in a single save. The tokens must all belong to one package.
    public func undo(_ tokens: [UndoToken]) async throws {
        guard let first = tokens.first else { return }
        guard tokens.allSatisfy({ $0.packageID == first.packageID }) else {
            throw PackageActionError.undoSpansPackages
        }
        guard var package = try await inventory.package(first.packageID) else {
            throw PackageActionError.packageNotFound
        }
        let now = time.now()
        for token in tokens.reversed() { try package.undo(token.eventID, at: now) }
        try await inventory.save(package)
    }
}
