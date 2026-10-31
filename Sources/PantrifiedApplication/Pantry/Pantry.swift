import Foundation
import PantrifiedDomain

/// A food the person adds by hand. Quantity and date are optional: unknown is a valid state.
public struct NewFood: Sendable, Hashable {
    /// Where the name came from. A name a product lookup suggested and the person left as it was
    /// is kept as a suggestion, so it does not count as a name the person decided.
    public enum NameSource: Sendable, Hashable {
        case person
        case lookup
    }

    public var name: String
    public var nameSource: NameSource
    public var location: LocationID
    public var quantity: Quantity
    public var printedDate: PrintedDate?
    /// The barcode scanned from the package, kept as product evidence.
    public var barcode: GTIN?

    public init(
        name: String,
        nameSource: NameSource = .person,
        location: LocationID,
        quantity: Quantity = .unknown,
        printedDate: PrintedDate? = nil,
        barcode: GTIN? = nil
    ) {
        self.name = name
        self.nameSource = nameSource
        self.location = location
        self.quantity = quantity
        self.printedDate = printedDate
        self.barcode = barcode
    }
}

public enum PantryError: Error, Sendable, Equatable {
    case nameRequired
    /// A draft for another Space.
    case otherSpace
}

/// What the Today and Food screens do with one Space: show what is there, add food by hand, and
/// open, use up, move or discard it with an undo. It adds no rules of its own; each step is the
/// use case that already holds them.
public struct Pantry: Sendable {
    public static let defaultLocations: [(name: String, storageType: StorageType)] = [
        ("Fridge", .refrigerated), ("Freezer", .frozen), ("Pantry", .roomTemperature),
    ]

    public let space: SpaceID
    private let inventory: any InventoryRepository
    private let locations: any StorageLocationStore
    private let useSoon: UseSoon
    private let putAway: PutAway
    private let actions: PackageActions

    public init(
        space: SpaceID,
        inventory: any InventoryRepository,
        locations: any StorageLocationStore,
        evidence: any ProductEvidenceStore,
        guidance: any StorageGuidanceRepository,
        time: any TimeSource,
        policy: AttentionPolicy = AttentionPolicy()
    ) {
        self.space = space
        self.inventory = inventory
        self.locations = locations
        useSoon = UseSoon(inventory: inventory, locations: locations, guidance: guidance, time: time, policy: policy)
        putAway = PutAway(inventory: inventory, locations: locations, evidence: evidence, time: time)
        actions = PackageActions(inventory: inventory, locations: locations, time: time)
    }

    /// Gives a new Space its Fridge, Freezer and Pantry, all in one write. A Space that already has
    /// any location is left as it is, so a person's own locations are never added to or reset.
    public func prepare() async throws {
        guard try await locations.locations(in: space).isEmpty else { return }
        try await locations.saveAll(
            Self.defaultLocations.map { StorageLocation(name: $0.name, storageType: $0.storageType) },
            in: space
        )
    }

    public func snapshot() async throws -> PantrySnapshot {
        let known = try await locations.locations(in: space)
        let names = Dictionary(uniqueKeysWithValues: known.map { ($0.id, $0.name) })
        let entries = try await useSoon.assessments(in: space).map {
            PantryEntry(package: $0.package, locationName: names[$0.package.location], assessment: $0.assessment)
        }
        return PantrySnapshot(locations: known, entries: entries.sorted(by: Self.mostUrgentFirst))
    }

    /// Puts one food away and returns its ID. A name that is empty or only spaces is refused. A
    /// barcode that cannot be kept does not fail the add, because the food itself was saved.
    @discardableResult
    public func add(_ food: NewFood) async throws -> PackageID {
        guard !food.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PantryError.nameRequired }
        var draft = PackageDraft(spaceID: space, barcode: food.barcode)
        switch food.nameSource {
        case .person: draft.name.confirm(food.name)
        case .lookup: draft.name.propose(food.name)
        }
        draft.location = food.location
        draft.quantity.confirm(food.quantity)
        if let date = food.printedDate { draft.printedDate.confirm(date) }
        _ = try await putAway.putAway([draft])
        return draft.id
    }

    /// Puts reviewed drafts away together, all or none, as a batch review does. A draft whose
    /// package already exists is left alone, so adding the same drafts again is safe.
    public func putAway(_ drafts: [PackageDraft]) async throws -> PutAwayResult {
        guard drafts.allSatisfy({ $0.spaceID == space }) else { throw PantryError.otherSpace }
        return try await putAway.putAway(drafts)
    }

    /// Whether each package exists and is still in active inventory. Packages that do not exist are
    /// left out.
    public func activity(of ids: [PackageID]) async throws -> [PackageID: Bool] {
        var result: [PackageID: Bool] = [:]
        for id in ids {
            if let package = try await inventory.package(id) { result[id] = package.status == .active }
        }
        return result
    }

    public func perform(_ action: PackageAction, on id: PackageID) async throws -> ActionOutcome {
        try await actions.apply(action, to: id)
    }

    public func undo(_ token: UndoToken) async throws {
        try await actions.undo(token)
    }

    private static func mostUrgentFirst(_ a: PantryEntry, _ b: PantryEntry) -> Bool {
        if a.needsAttention != b.needsAttention { return a.needsAttention }
        if a.needsAttention, let ad = a.assessment.attentionDate, let bd = b.assessment.attentionDate, ad != bd {
            return ad < bd
        }
        let (an, bn) = (a.package.name.lowercased(), b.package.name.lowercased())
        if an != bn { return an < bn }
        return a.package.id.rawValue.uuidString < b.package.id.rawValue.uuidString
    }
}
