import Foundation

/// When a candidate looks complete enough while photos are still being taken: nothing has joined it
/// for `shots` photos, or for `seconds`. Only a hint for the screen; nothing depends on it.
public struct SettlingPolicy: Sendable, Hashable {
    public var shots = 3
    public var seconds: TimeInterval = 15

    public init() {}

    public static let standard = SettlingPolicy()
}

/// A batch grouped as its photos are read and its barcodes are looked up, in whatever order the
/// readings and the answers arrive.
///
/// Each arrival of a photo or of a lookup's product name groups again with the same
/// `PhotoGrouper`. Grouping is a pure function of the set of observations and the set of names, so
/// once every photo and answer has arrived the result is the one-shot grouping of them all, whatever
/// the order. Results before that are tentative: they are shown only as a count, never as
/// candidates the person can change. What grouping reads from each photo, and from each name, is
/// worked out once, when it arrives. Two photos with different barcodes, or whose labels differ in
/// a distinguishing word or amount, are never in one group at any step, because those refusals do
/// not depend on the rest of the batch.
public struct LiveGrouping: Sendable {
    public let grouper: PhotoGrouper
    public private(set) var observations: [IntakePhotoID: PhotoObservation] = [:]
    private var prepared: [IntakePhotoID: PreparedPhoto] = [:]
    /// The product names lookups found, by barcode.
    public private(set) var lookupNames: [GTIN: String] = [:]
    private var preparedLookups: [GTIN: PreparedLookup] = [:]
    public private(set) var result = GroupingResult.empty
    /// The work of every grouping so far.
    public private(set) var cost = GroupingCost()

    public init(grouper: PhotoGrouper = PhotoGrouper(), observations: [PhotoObservation] = [], lookupNames: [GTIN: String] = [:]) {
        self.grouper = grouper
        sync(with: observations, lookupNames: lookupNames)
    }

    /// Candidates so far, for a tentative count while photos are taken.
    public var packagesSoFar: Int { result.groups.count }

    /// Adds a photo's observation and groups again. A photo already here keeps its first
    /// observation, as the staging store does. Returns whether anything changed.
    @discardableResult
    public mutating func add(_ observation: PhotoObservation) -> Bool {
        guard observations[observation.photo] == nil else { return false }
        observations[observation.photo] = observation
        prepared[observation.photo] = grouper.prepare(observation)
        regroup()
        return true
    }

    /// Keeps the product name a lookup found for a barcode, or forgets it with nil, and groups again
    /// when it changed. Returns whether anything changed.
    @discardableResult
    public mutating func setLookupName(_ name: String?, for barcode: GTIN) -> Bool {
        guard lookupNames[barcode] != name else { return false }
        lookupNames[barcode] = name
        if let name {
            preparedLookups[barcode] = prepareLookup(name)
        } else {
            preparedLookups[barcode] = nil
        }
        regroup()
        return true
    }

    /// Makes the set of observations exactly `current`, such as after a photo was taken back, and,
    /// when given, the lookup names exactly `lookupNames`. Groups again only when something
    /// changed. Returns whether anything changed.
    @discardableResult
    public mutating func sync(with current: [PhotoObservation], lookupNames names: [GTIN: String]? = nil) -> Bool {
        var wanted: [IntakePhotoID: PhotoObservation] = [:]
        for observation in current where wanted[observation.photo] == nil { wanted[observation.photo] = observation }
        let kept = wanted.merging(observations.filter { wanted[$0.key] != nil }) { _, existing in existing }
        let namesChanged = names.map { $0 != lookupNames } ?? false
        guard kept != observations || namesChanged else { return false }
        if kept != observations {
            observations = kept
            prepared = prepared.filter { kept[$0.key] != nil }
            for (photo, observation) in kept where prepared[photo] == nil { prepared[photo] = grouper.prepare(observation) }
        }
        if let names, namesChanged {
            preparedLookups = preparedLookups.filter { names[$0.key] == lookupNames[$0.key] && names[$0.key] != nil }
            lookupNames = names
            for (barcode, name) in names where preparedLookups[barcode] == nil { preparedLookups[barcode] = prepareLookup(name) }
        }
        regroup()
        return true
    }

    /// Photos whose candidate nothing has joined for `policy.shots` photos taken since its newest
    /// photo, or for `policy.seconds` since that photo was taken. `latestSequence` is the newest
    /// photo taken, read or not.
    public func settledPhotos(latestSequence: Int, now: Date, policy: SettlingPolicy = .standard) -> Set<IntakePhotoID> {
        var settled: Set<IntakePhotoID> = []
        for group in result.groups {
            let members = group.photos.compactMap { observations[$0] }
            guard let newest = members.max(by: { $0.sequence < $1.sequence }) else { continue }
            if latestSequence - newest.sequence >= policy.shots || now.timeIntervalSince(newest.capturedAt) >= policy.seconds {
                settled.formUnion(group.photos)
            }
        }
        return settled
    }

    private mutating func prepareLookup(_ name: String) -> PreparedLookup {
        cost.lookupNamesPrepared += 1
        return grouper.prepare(lookupName: name)
    }

    private mutating func regroup() {
        let measured = grouper.measuredGroup(prepared: Array(prepared.values), lookups: preparedLookups)
        result = measured.result
        cost = cost + measured.cost
    }
}
