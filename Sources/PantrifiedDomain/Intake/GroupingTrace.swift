import Foundation

/// What a photo looks like it is, from its own text and codes. A description for the record only:
/// grouping never uses it, since what a photo shows links it to another, never its role.
public enum PhotoRole: String, Sendable, Hashable, Codable {
    /// A name and no barcode, date or panel: the front of a package.
    case front
    /// A barcode, date or panel, and no name as big as its biggest text: the back or side.
    case back
    /// Only a printed date.
    case dateOnly
    /// None of these, such as a photo with no text, or one whose name is its biggest text next to a
    /// barcode.
    case other
}

/// How grouping read one photo.
public struct PhotoTrace: Sendable, Hashable {
    public let photo: IntakePhotoID
    public let role: PhotoRole
    /// Whether the photo shows a nutrition, ingredients or similar panel.
    public let showsPanel: Bool
}

/// One signal between two photos and the points it added.
public struct SignalPoints: Sendable, Hashable, Codable {
    public let signal: MatchSignal
    public let points: Int

    public init(signal: MatchSignal, points: Int) {
        self.signal = signal
        self.points = points
    }
}

/// The evidence grouping weighed for one pair of photos.
public struct PairTrace: Sendable, Hashable {
    /// The photo taken first.
    public let first: IntakePhotoID
    public let second: IntakePhotoID
    /// How far apart their feature prints are, when both have one and they can be compared.
    public let distance: Double?
    public let signals: [SignalPoints]
    /// Points from a name word one letter off a word on the other photo. They count toward a
    /// suggestion only. With the signals' points they make the score.
    public let oneLetterOffPoints: Int
    public let score: Int
}

/// A grouping with the evidence behind it, for a record of what the app did with a batch.
public struct GroupingTrace: Sendable, Hashable {
    public let result: GroupingResult
    /// One per photo, in sequence order.
    public let photos: [PhotoTrace]
    /// Every pair any signal links or separates, and every other pair whose feature prints are
    /// within `distanceKeptUpTo`, so a looser image threshold can be tried on the record. Pairs are
    /// in the order of their first photo, then their second.
    public let pairs: [PairTrace]
    public let distanceKeptUpTo: Double
}

extension PhotoGrouper {
    /// Groups the photos with the lookup names as `group` does and keeps the evidence for each pair.
    /// A pair with no signal is kept only for its feature print distance, when it is at most twice
    /// `policy.similarDistance`.
    public func trace(_ observations: [PhotoObservation], lookupNames: [GTIN: String] = [:]) -> GroupingTrace {
        let photos = batch(observations, sequence: \.sequence, photo: \.photo).map(prepare)
        let lookups = lookupNames.mapValues(prepare(lookupName:))
        var cost = GroupingCost()
        var scored: [[Int]: Pair] = [:]
        for pair in scoredPairs(photos, lookups: lookups, cost: &cost) { scored[[pair.a, pair.b]] = pair }
        let keepUpTo = 2 * policy.similarDistance

        let single = photos.indices.filter { photos[$0].products.count < 2 }
        var pairs: [PairTrace] = []
        for (position, i) in single.enumerated() {
            for j in single[(position + 1)...] {
                let (a, b) = (photos[i].observation, photos[j].observation)
                var measured: Double?
                if let x = a.featurePrint, let y = b.featurePrint, let d = distance.distance(x, y), d.isFinite { measured = d }
                let pair = scored[[i, j]]
                guard pair != nil || (measured.map { $0 <= keepUpTo } ?? false) else { continue }
                pairs.append(PairTrace(
                    first: a.photo, second: b.photo, distance: measured,
                    signals: pair.map { pair in
                        zip(pair.signals, pair.signalPoints).map { SignalPoints(signal: $0, points: $1) }
                    } ?? [],
                    oneLetterOffPoints: pair?.nearPoints ?? 0, score: pair?.score ?? 0
                ))
            }
        }

        let traces = photos.map { photo in
            PhotoTrace(photo: photo.id, role: Self.role(of: photo), showsPanel: LabelText.showsPanel(photo.observation.lines))
        }
        return GroupingTrace(
            result: measuredGroup(prepared: photos, lookups: lookups).result, photos: traces, pairs: pairs, distanceKeptUpTo: keepUpTo
        )
    }

    /// A photo whose name, if any, is less tall than this share of its tallest line counts as a back
    /// in the record: a back's biggest print is usually its date or panel.
    static let backNameShare = 0.75

    static func role(of photo: PreparedPhoto) -> PhotoRole {
        let lines = photo.observation.lines
        let panel = LabelText.showsPanel(lines)
        if photo.showsDetails, photo.tokens.isEmpty, photo.products.isEmpty, !panel { return .dateOnly }
        if photo.showsDetails {
            let tallest = lines.map(\.box.height).max() ?? 0
            let nameHeight = LabelText.prominentLine(in: lines)?.height
            if nameHeight.map({ $0 < backNameShare * tallest }) ?? true { return .back }
            return .other
        }
        return photo.prominent.isEmpty ? .other : .front
    }
}
