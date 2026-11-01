import Foundation

/// Which storage sourced guidance gives for a food that is not opened yet.
public protocol UnopenedStorageGuide: Sendable {
    /// The storage types with a window counted from when the food was added, for the one record the
    /// name matches, or the record `choice` names. Empty when no single record matches.
    func unopenedStorage(of name: String, choice: GuidanceChoice?) -> Set<StorageType>
}

/// Where one package the household has had, active or not, was put. Read from the inventory.
public struct PastPlacement: Sendable, Hashable {
    public var package: PackageID
    public var name: String
    public var barcode: GTIN?
    public var location: LocationID
    /// When it was put there: when it was added, or when it was last moved.
    public var at: Date
    public var guidanceChoice: GuidanceChoice?

    public init(
        package: PackageID, name: String, barcode: GTIN?, location: LocationID, at: Date, guidanceChoice: GuidanceChoice? = nil
    ) {
        self.package = package
        self.name = name
        self.barcode = barcode
        self.location = location
        self.at = at
        self.guidanceChoice = guidanceChoice
    }

    public init(_ package: Package, barcode: GTIN?) {
        self.init(
            package: package.id, name: package.name, barcode: barcode, location: package.location, at: package.placedAt,
            guidanceChoice: package.guidanceChoice
        )
    }

    /// Newer first; the package identity settles a tie, so the same placements always give the
    /// same answer.
    fileprivate func isNewer(than other: PastPlacement) -> Bool {
        at != other.at ? at > other.at : package.rawValue.uuidString > other.package.rawValue.uuidString
    }
}

/// A proposed place for a candidate and why.
public struct PlaceProposal: Sendable, Hashable {
    public let location: LocationID?
    public let origin: LocationOrigin

    public init(location: LocationID?, origin: LocationOrigin) {
        self.location = location
        self.origin = origin
    }
}

/// What proposing a place for a candidate reads: the household's locations, where it put each
/// product before, and sourced storage guidance. Built once for a review; nothing here is stored.
public struct PlaceContext: Sendable {
    public let locations: [StorageLocation]
    private let byBarcode: [GTIN: PastPlacement]
    private let byName: [IngredientName: PastPlacement]
    private let choiceByBarcode: [GTIN: PastPlacement]
    private let choiceByName: [IngredientName: PastPlacement]
    private let guide: (any UnopenedStorageGuide)?

    /// Only placements in one of `locations` are remembered as places. A FoodKeeper choice is
    /// remembered from any placement.
    public init(locations: [StorageLocation], placements: [PastPlacement] = [], guide: (any UnopenedStorageGuide)? = nil) {
        self.locations = locations
        self.guide = guide
        let known = Set(locations.map(\.id))
        var byBarcode: [GTIN: PastPlacement] = [:]
        var byName: [IngredientName: PastPlacement] = [:]
        var choiceByBarcode: [GTIN: PastPlacement] = [:]
        var choiceByName: [IngredientName: PastPlacement] = [:]
        func keep<Key: Hashable>(_ placement: PastPlacement, under key: Key, in table: inout [Key: PastPlacement]) {
            if let held = table[key], !placement.isNewer(than: held) { return }
            table[key] = placement
        }
        for placement in placements {
            let name = IngredientName(placement.name)
            if known.contains(placement.location) {
                if let barcode = placement.barcode { keep(placement, under: barcode, in: &byBarcode) }
                if !name.isEmpty { keep(placement, under: name, in: &byName) }
            }
            if placement.guidanceChoice != nil {
                if let barcode = placement.barcode { keep(placement, under: barcode, in: &choiceByBarcode) }
                if !name.isEmpty { keep(placement, under: name, in: &choiceByName) }
            }
        }
        self.byBarcode = byBarcode
        self.byName = byName
        self.choiceByBarcode = choiceByBarcode
        self.choiceByName = choiceByName
    }

    /// Proposes a place, in this order: where the household last put a package with this barcode,
    /// or else with this name; the storage the label states; the storage sourced guidance gives the
    /// unopened food; otherwise no place, for the person to choose.
    public func proposal(barcode: GTIN?, name: String?, labelStorage: StorageType?) -> PlaceProposal {
        let key = name.map(IngredientName.init).flatMap { $0.isEmpty ? nil : $0 }
        if let remembered = barcode.flatMap({ byBarcode[$0] }) ?? key.flatMap({ byName[$0] }) {
            return PlaceProposal(location: remembered.location, origin: .remembered)
        }
        if let labelStorage, let place = location(of: labelStorage) {
            return PlaceProposal(location: place, origin: .label)
        }
        if let name, let guide {
            let choice = (barcode.flatMap { choiceByBarcode[$0] } ?? key.flatMap { choiceByName[$0] })?.guidanceChoice
            if let type = Self.unopenedPlace(guide.unopenedStorage(of: name, choice: choice)), let place = location(of: type) {
                return PlaceProposal(location: place, origin: .foodKeeper)
            }
        }
        return PlaceProposal(location: nil, origin: .unplaced)
    }

    /// The storage to propose from guidance for an unopened food: the one it gives, leaving out the
    /// freezer when it also gives another, since freezing is how most foods are kept longer, not
    /// where they are kept. None when two others remain, such as the pantry and the fridge.
    public static func unopenedPlace(_ types: Set<StorageType>) -> StorageType? {
        let kept = types.count > 1 ? types.subtracting([.frozen]) : types
        return kept.count == 1 ? kept.first : nil
    }

    /// The household's first location of a storage type.
    public func location(of type: StorageType) -> LocationID? {
        locations.first { $0.storageType == type }?.id
    }
}

/// One section of the review: the candidates in one of the household's locations, or those with no
/// place yet (`place` nil).
public struct PlaceSection: Sendable, Hashable, Identifiable {
    public let place: LocationID?
    public let candidates: [CandidateSummary]

    public var id: String { place?.rawValue.uuidString ?? "unplaced" }
}

/// What dragging a card carries.
public enum PlaceDrag {
    /// The whole selection when the dragged card is in it, otherwise the card alone, in review order.
    public static func carried(
        dragging card: IntakeCandidateID, selection: Set<IntakeCandidateID>, order: [IntakeCandidateID]
    ) -> [IntakeCandidateID] {
        guard selection.contains(card) else { return [card] }
        return order.filter(selection.contains)
    }
}
