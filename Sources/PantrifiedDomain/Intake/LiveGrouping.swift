import Foundation

/// When a candidate looks complete enough while photos are still being taken: nothing has joined it
/// for `shots` photos, or for `seconds`. Only a hint for the screen; nothing depends on it.
public struct SettlingPolicy: Sendable, Hashable {
    public var shots = 3
    public var seconds: TimeInterval = 15

    public init() {}

    public static let standard = SettlingPolicy()
}

/// A batch grouped as its photos are read, in whatever order the readings arrive.
///
/// Each arrival groups every observation read so far again with the same `PhotoGrouper`. Grouping
/// is a pure function of the set of observations, so once every photo has arrived the result is the
/// one-shot grouping of the whole batch, whatever the arrival order. Results before that are
/// tentative: they are shown only as a count, never as candidates the person can change. What
/// grouping reads from each photo is worked out once, when the photo arrives. Two
/// photos with different barcodes, or whose labels differ in a distinguishing word or amount, are
/// never in one group at any step, because those refusals do not depend on the rest of the batch.
public struct LiveGrouping: Sendable {
    public let grouper: PhotoGrouper
    public private(set) var observations: [IntakePhotoID: PhotoObservation] = [:]
    private var prepared: [IntakePhotoID: PreparedPhoto] = [:]
    public private(set) var result = GroupingResult.empty
    /// The work of every grouping so far.
    public private(set) var cost = GroupingCost()

    public init(grouper: PhotoGrouper = PhotoGrouper(), observations: [PhotoObservation] = []) {
        self.grouper = grouper
        sync(with: observations)
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

    /// Makes the set of observations exactly `current`, such as after a photo was taken back, and
    /// groups again only when the set changed. Returns whether anything changed.
    @discardableResult
    public mutating func sync(with current: [PhotoObservation]) -> Bool {
        var wanted: [IntakePhotoID: PhotoObservation] = [:]
        for observation in current where wanted[observation.photo] == nil { wanted[observation.photo] = observation }
        let kept = wanted.merging(observations.filter { wanted[$0.key] != nil }) { _, existing in existing }
        guard kept != observations else { return false }
        observations = kept
        prepared = prepared.filter { kept[$0.key] != nil }
        for (photo, observation) in kept where prepared[photo] == nil { prepared[photo] = grouper.prepare(observation) }
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

    private mutating func regroup() {
        let measured = grouper.measuredGroup(prepared: Array(prepared.values))
        result = measured.result
        cost = cost + measured.cost
    }
}
