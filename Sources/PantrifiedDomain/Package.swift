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
}

public struct PackageEvent: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: Sendable, Hashable, Codable {
        case change(PackageChange)
        case undone(PackageEventID)
    }

    public let id: PackageEventID
    public let at: Date
    public let kind: Kind
}

/// A physical package. Product identity is separate: a matching barcode never proves two packages
/// are the same one, so `productID` is optional and incomplete records are valid.
///
/// Current state is derived from an append-only event history so undo and sync recovery operate on
/// the same log; undone events stay in `events` for history.
public struct Package: Sendable, Identifiable {
    public let id: PackageID
    public let spaceID: SpaceID
    public var productID: ProductID?
    public var name: String
    public var printedDate: PrintedDate?
    public var instruction: PackageInstruction?
    public let addedAt: Date
    public private(set) var events: [PackageEvent] = []

    private let initialLocation: LocationID
    private let initialQuantity: Quantity

    public init(
        id: PackageID = PackageID(),
        spaceID: SpaceID,
        productID: ProductID? = nil,
        name: String,
        location: LocationID,
        quantity: Quantity = .unknown,
        printedDate: PrintedDate? = nil,
        instruction: PackageInstruction? = nil,
        addedAt: Date
    ) {
        self.id = id
        self.spaceID = spaceID
        self.productID = productID
        self.name = name
        self.printedDate = printedDate
        self.instruction = instruction
        self.addedAt = addedAt
        self.initialLocation = location
        self.initialQuantity = quantity
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

    public var location: LocationID {
        effectiveChanges.reduce(initialLocation) { current, entry in
            if case .moved(let destination) = entry.change { return destination }
            return current
        }
    }

    public var quantity: Quantity {
        effectiveChanges.reduce(initialQuantity) { current, entry in
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
