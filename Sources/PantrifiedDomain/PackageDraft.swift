import Foundation

public enum FieldSource: Sendable, Hashable, Codable {
    case recognized
    case userConfirmed
}

/// A reviewable value that remembers whether the user has decided it. Once confirmed, including
/// confirmed as empty, delayed recognition can no longer change it.
public struct DraftField<Value: Sendable & Hashable & Codable>: Sendable, Hashable, Codable {
    public private(set) var value: Value?
    /// Nil only while the field has never been proposed or confirmed.
    public private(set) var source: FieldSource?

    public init() {}

    public mutating func propose(_ proposed: Value) {
        guard source != .userConfirmed else { return }
        value = proposed
        source = .recognized
    }

    public mutating func confirm(_ confirmed: Value?) {
        value = confirmed
        source = .userConfirmed
    }
}

/// What recognition or enrichment suggests for a package. Absent fields are left alone.
public struct PackageProposal: Sendable, Hashable {
    public var name: String?
    public var quantity: Quantity?
    public var printedDate: PrintedDate?

    public init(name: String? = nil, quantity: Quantity? = nil, printedDate: PrintedDate? = nil) {
        self.name = name
        self.quantity = quantity
        self.printedDate = printedDate
    }
}

/// A recognized numeric date that reads two ways. The draft holds both until the person picks one.
public struct PrintedDateChoice: Sendable, Hashable {
    public let label: PrintedDateLabel
    public let monthFirst: Date
    public let dayFirst: Date
}

public enum DraftRequirement: Sendable, Hashable {
    case name
    case location
}

public enum DraftReadiness: Sendable, Hashable {
    case ready
    case needs([DraftRequirement])
}

/// A package candidate under review. Becomes authoritative inventory only through put-away.
/// Quantity and date are never required: unknown is a valid saved state.
public struct PackageDraft: Sendable, Hashable, Identifiable {
    /// Becomes the package's identity, so putting the same draft away twice is recognizably one package.
    public let id: PackageID
    public let spaceID: SpaceID
    /// Product evidence only. A repeated barcode is not proof of the same physical package.
    public var barcode: GTIN?
    public var name = DraftField<String>()
    public var quantity = DraftField<Quantity>()
    public var printedDate = DraftField<PrintedDate>()
    public var location: LocationID?
    private var recognizedDateChoice: PrintedDateChoice?

    /// A recognized date that could be read two ways and has not been settled. A date the person
    /// entered or cleared settles it, and it never blocks put-away.
    public var pendingDateChoice: PrintedDateChoice? {
        printedDate.source == .userConfirmed ? nil : recognizedDateChoice
    }

    public init(id: PackageID = PackageID(), spaceID: SpaceID, barcode: GTIN? = nil) {
        self.id = id
        self.spaceID = spaceID
        self.barcode = barcode
    }

    public mutating func apply(_ proposal: PackageProposal) {
        if let name = proposal.name { self.name.propose(name) }
        if let quantity = proposal.quantity { self.quantity.propose(quantity) }
        if let printedDate = proposal.printedDate { self.printedDate.propose(printedDate) }
    }

    /// Proposes the preferred date read from recognized text. A date that could mean two things is
    /// held as a pending choice and not proposed; a date the person confirmed is never replaced.
    public mutating func apply(_ readings: [PrintedDateReading]) {
        guard let reading = PrintedDateParser.preferred(readings) else { return }
        switch reading.value {
        case .resolved(let date, _):
            recognizedDateChoice = nil
            apply(PackageProposal(printedDate: PrintedDate(label: reading.label, date: date)))
        case .ambiguous(let monthFirst, let dayFirst):
            recognizedDateChoice = PrintedDateChoice(label: reading.label, monthFirst: monthFirst, dayFirst: dayFirst)
        }
    }

    /// Settles a pending choice as the person's own confirmed date. An unknown order settles nothing.
    public mutating func chooseDateOrder(_ order: DateOrderHint) {
        guard let choice = pendingDateChoice else { return }
        switch order {
        case .monthFirst: printedDate.confirm(PrintedDate(label: choice.label, date: choice.monthFirst))
        case .dayFirst: printedDate.confirm(PrintedDate(label: choice.label, date: choice.dayFirst))
        case .unknown: return
        }
        recognizedDateChoice = nil
    }

    public var trimmedName: String? {
        guard let trimmed = name.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Fields the user decided during review, which the package keeps against later recognition.
    public var confirmedFields: Set<PackageField> {
        var confirmed: Set<PackageField> = []
        if name.source == .userConfirmed { confirmed.insert(.name) }
        if printedDate.source == .userConfirmed { confirmed.insert(.printedDate) }
        return confirmed
    }

    public var readiness: DraftReadiness {
        var missing: [DraftRequirement] = []
        if trimmedName == nil { missing.append(.name) }
        if location == nil { missing.append(.location) }
        return missing.isEmpty ? .ready : .needs(missing)
    }
}

public struct LocationAssignmentUndo: Sendable, Hashable {
    fileprivate let previous: [PackageID: LocationID?]
}

public struct DraftBatch: Sendable {
    public private(set) var drafts: [PackageDraft]

    public init(_ drafts: [PackageDraft]) {
        self.drafts = drafts
    }

    public mutating func assignLocation(_ location: LocationID, to ids: Set<PackageID>) -> LocationAssignmentUndo {
        var previous: [PackageID: LocationID?] = [:]
        for index in drafts.indices where ids.contains(drafts[index].id) {
            previous[drafts[index].id] = drafts[index].location
            drafts[index].location = location
        }
        return LocationAssignmentUndo(previous: previous)
    }

    public mutating func undo(_ assignment: LocationAssignmentUndo) {
        for index in drafts.indices {
            if let location = assignment.previous[drafts[index].id] {
                drafts[index].location = location
            }
        }
    }
}
