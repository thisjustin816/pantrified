import Foundation

public enum DiscardReason: Sendable, Hashable, Codable {
    case spoiled
    case unwanted
    case other
}

public enum PackageError: Error, Sendable, Equatable {
    case notActive
    case eventNotFound
    case alreadyUndone
    case cannotUndoUndo
}

public enum PackageStatus: Sendable, Hashable {
    case active
    case usedUp(at: Date)
    case discarded(at: Date, reason: DiscardReason?)
}

public enum PackageChange: Sendable, Hashable, Codable {
    case opened
    case moved(to: LocationID)
    case frozen
    case thawed
    case quantityChanged(Quantity)
    /// Part of the package was consumed; `resulting` is the quantity afterwards.
    case usedSome(resulting: Quantity)
    case confirmedPresent
    case usedUp
    case discarded(reason: DiscardReason?)
    /// The user decided this field. It keeps its value against recognition recorded before or
    /// after it, until the correction itself is undone or corrected again.
    case corrected(PackageFieldValue)
    /// Recognition or enrichment proposed this value. It applies only while the user has not
    /// decided the field.
    case recognized(PackageFieldValue)
}

public struct PackageEvent: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: Sendable, Hashable, Codable {
        case change(PackageChange)
        case undone(PackageEventID)
    }

    public let id: PackageEventID
    public let at: Date
    public let kind: Kind

    public init(id: PackageEventID, at: Date, kind: Kind) {
        self.id = id
        self.at = at
        self.kind = kind
    }
}

/// A package's descriptive fields, which recognition may propose and the user may correct.
public enum PackageField: Sendable, Hashable, Codable, CaseIterable {
    case name
    case productID
    case printedDate
    case instruction
    /// Which record of the sourced storage guidance the food is. Only the person's own choice
    /// decides it; see `Package.guidanceChoice`.
    case guidanceRecord
}

public enum PackageFieldValue: Sendable, Hashable, Codable {
    case name(String)
    case productID(ProductID?)
    case printedDate(PrintedDate?)
    case instruction(PackageInstruction?)
    /// Nil clears the choice, so the food is matched to guidance by its name again.
    case guidanceRecord(GuidanceChoice?)

    public var field: PackageField {
        switch self {
        case .name: .name
        case .productID: .productID
        case .printedDate: .printedDate
        case .instruction: .instruction
        case .guidanceRecord: .guidanceRecord
        }
    }
}

public struct PackageDetails: Sendable, Hashable {
    public var name: String
    public var productID: ProductID?
    public var printedDate: PrintedDate?
    public var instruction: PackageInstruction?
    /// Never part of a package's creation facts: it is set only by a later event.
    public var guidanceRecord: GuidanceChoice?

    mutating func set(_ value: PackageFieldValue) {
        switch value {
        case .name(let name): self.name = name
        case .productID(let productID): self.productID = productID
        case .printedDate(let printedDate): self.printedDate = printedDate
        case .instruction(let instruction): self.instruction = instruction
        case .guidanceRecord(let choice): guidanceRecord = choice
        }
    }
}

/// What a package was created with. Never changes; later changes are events.
public struct PackageOrigin: Sendable, Hashable {
    public let details: PackageDetails
    /// Fields the user decided before the package existed, such as during draft review.
    public let confirmed: Set<PackageField>
    public let location: LocationID
    public let quantity: Quantity
}

/// A physical package. Product identity is separate: a matching barcode never proves two packages
/// are the same one, so `productID` is optional and incomplete records are valid.
///
/// Current state is derived from an append-only event history so undo and sync recovery operate on
/// the same log; undone events stay in `events` for history. Descriptive fields are part of that
/// history too, so a correction made against a stale copy cannot erase anyone else's change.
public struct Package: Sendable, Identifiable {
    public let id: PackageID
    public let spaceID: SpaceID
    public let addedAt: Date
    public let origin: PackageOrigin
    public private(set) var events: [PackageEvent]

    /// `events` restores a package from persisted or synchronized history and must be in the
    /// order the history is folded.
    public init(
        id: PackageID = PackageID(),
        spaceID: SpaceID,
        productID: ProductID? = nil,
        name: String,
        location: LocationID,
        quantity: Quantity = .unknown,
        printedDate: PrintedDate? = nil,
        instruction: PackageInstruction? = nil,
        confirmed: Set<PackageField> = [],
        addedAt: Date,
        events: [PackageEvent] = []
    ) {
        self.id = id
        self.spaceID = spaceID
        self.addedAt = addedAt
        self.origin = PackageOrigin(
            details: PackageDetails(
                name: name, productID: productID, printedDate: printedDate, instruction: instruction
            ),
            confirmed: confirmed,
            location: location,
            quantity: quantity
        )
        self.events = events
    }

    // MARK: Recording

    @discardableResult
    public mutating func record(
        _ change: PackageChange,
        at date: Date,
        id: PackageEventID = PackageEventID()
    ) throws -> PackageEventID {
        guard status == .active else { throw PackageError.notActive }
        events.append(PackageEvent(id: id, at: date, kind: .change(change)))
        return id
    }

    public mutating func undo(_ target: PackageEventID, at date: Date) throws {
        guard let event = events.first(where: { $0.id == target }) else {
            throw PackageError.eventNotFound
        }
        if case .undone = event.kind { throw PackageError.cannotUndoUndo }
        guard !undoneIDs.contains(target) else { throw PackageError.alreadyUndone }
        events.append(PackageEvent(id: PackageEventID(), at: date, kind: .undone(target)))
    }

    /// Records recognition for each proposed field the user has not decided. Quantity is not
    /// proposed after put-away: from then on it is lifecycle state the household maintains.
    @discardableResult
    public mutating func propose(_ proposal: PackageProposal, at date: Date) throws -> [PackageEventID] {
        let values: [PackageFieldValue] = [
            proposal.name.map { .name($0) },
            proposal.printedDate.map { .printedDate($0) },
        ].compactMap { $0 }
        let confirmed = confirmedFields
        var recorded: [PackageEventID] = []
        for value in values where !confirmed.contains(value.field) {
            recorded.append(try record(.recognized(value), at: date))
        }
        return recorded
    }

    // MARK: Derived state

    private var undoneIDs: Set<PackageEventID> {
        Set(events.compactMap { event in
            if case .undone(let target) = event.kind { return target }
            return nil
        })
    }

    /// Changes still in effect, oldest first.
    private var effectiveChanges: [(at: Date, change: PackageChange)] {
        let undone = undoneIDs
        return events.compactMap { event in
            guard !undone.contains(event.id), case .change(let change) = event.kind else { return nil }
            return (event.at, change)
        }
    }

    public var status: PackageStatus {
        for (at, change) in effectiveChanges {
            switch change {
            case .usedUp: return .usedUp(at: at)
            case .discarded(let reason): return .discarded(at: at, reason: reason)
            default: continue
            }
        }
        return .active
    }

    private var described: (details: PackageDetails, confirmed: Set<PackageField>) {
        var details = origin.details
        var confirmed = origin.confirmed
        for (_, change) in effectiveChanges {
            switch change {
            case .corrected(let value):
                details.set(value)
                confirmed.insert(value.field)
            case .recognized(let value) where !confirmed.contains(value.field):
                details.set(value)
            default:
                continue
            }
        }
        return (details, confirmed)
    }

    public var details: PackageDetails { described.details }
    public var name: String { details.name }
    public var productID: ProductID? { details.productID }
    public var printedDate: PrintedDate? { details.printedDate }
    public var instruction: PackageInstruction? { details.instruction }
    /// Fields the user has decided, which recognition does not change.
    public var confirmedFields: Set<PackageField> { described.confirmed }

    /// The record of sourced storage guidance the person said this food is, or that none of the
    /// records offered is. Only the person's own choice counts: a proposed value never decides which
    /// guidance applies. The choice belongs to the package, so renaming the food keeps it.
    public var guidanceChoice: GuidanceChoice? {
        let described = described
        return described.confirmed.contains(.guidanceRecord) ? described.details.guidanceRecord : nil
    }

    public var location: LocationID {
        effectiveChanges.reduce(origin.location) { current, entry in
            if case .moved(let destination) = entry.change { return destination }
            return current
        }
    }

    public var quantity: Quantity {
        effectiveChanges.reduce(origin.quantity) { current, entry in
            switch entry.change {
            case .quantityChanged(let quantity), .usedSome(let quantity): return quantity
            default: return current
            }
        }
    }

    /// The first opening wins; opening again does not restart the clock.
    public var openedAt: Date? {
        effectiveChanges.first { $0.change == .opened }?.at
    }

    public var frozenAt: Date? {
        effectiveChanges.last { $0.change == .frozen }?.at
    }

    public var thawedAt: Date? {
        effectiveChanges.last { $0.change == .thawed }?.at
    }

    /// Presence confirmations never reset storage windows, so nothing else reads this.
    public var lastConfirmedAt: Date? {
        effectiveChanges.last { $0.change == .confirmedPresent }?.at
    }
}
