import Foundation

/// How far apart two photos' feature prints are. The seam for the platform's own measure; the
/// default is the Euclidean distance between the vectors.
public protocol ImageDistance: Sendable {
    /// Nil when the two prints cannot be compared, such as vectors of different lengths.
    func distance(_ a: FeaturePrint, _ b: FeaturePrint) -> Double?
}

public struct EuclideanImageDistance: ImageDistance {
    public init() {}

    public func distance(_ a: FeaturePrint, _ b: FeaturePrint) -> Double? {
        guard a.values.count == b.values.count else { return nil }
        var sum: Double = 0
        for index in a.values.indices {
            let difference = Double(a.values[index]) - Double(b.values[index])
            sum += difference * difference
        }
        return sum.squareRoot()
    }
}

/// One reason two photos look like the same package. Shown to the person as provenance, and never
/// carries the recognized text itself.
public enum MatchSignal: String, Sendable, Hashable, Codable, CaseIterable {
    /// Both photos show the same product barcode.
    case sameBarcode
    /// The two files hold the same bytes, such as one photo imported twice.
    case identicalPhoto
    case nearDuplicateImage
    case similarImage
    /// Several distinctive label words in common.
    case sharedLabelWords
    /// One distinctive word, or two short ones, in common.
    case someLabelWords
    /// Taken one straight after the other.
    case takenRightAfter
    /// A photo of only a date, taken straight after this one.
    case datePhotoAfter
    /// A photo of only a date, taken straight before this one.
    case datePhotoBefore
    /// The person merged the candidates.
    case groupedByPerson
    /// The labels share a word but each has a prominent word the other lacks, such as "baking soda"
    /// and "baking powder". Evidence against: the pair is never grouped automatically.
    case differentLabelWords
    /// Different prominent percentages ("2%" and "1%") or net contents. Evidence against.
    case differentAmounts

    /// Whether the signal counts against the photos being one package.
    public var separates: Bool { self == .differentLabelWords || self == .differentAmounts }
}

/// The weights and thresholds that decide grouping, in one place so they can be tuned after trying
/// the app on real groceries. docs/batch-intake.md gives the reasoning for each value. None of
/// them has been checked against real photos yet.
public struct GroupingPolicy: Sendable, Hashable {
    // Points each signal adds to a pair of photos.
    public var sameBarcode = 100
    public var identicalPhoto = 100
    public var nearDuplicateImage = 50
    public var similarImage = 25
    public var sharedLabelWords = 50
    public var someLabelWords = 25
    public var takenRightAfter = 15
    public var datePhotoAfter = 45
    public var datePhotoBefore = 15

    /// A pair at or above this is grouped as one package.
    public var mergeAt = 60
    /// A pair at or above this, but below `mergeAt`, is shown as "might be the same as".
    public var suggestAt = 30

    /// Feature print distances, for Vision's revision 2 feature prints (unit vectors, so 0 to 2).
    public var nearDuplicateDistance = 0.25
    public var similarDistance = 0.5

    public var sharedWordsForStrongText = 3
    /// The share of the shorter photo's words that must be shared for strong text.
    public var overlapForStrongText = 0.5
    /// One shared word counts as some text only when it has at least this many letters.
    public var longWordLetters = 5

    /// Photos taken this close together, one after the other, count as taken right after.
    public var adjacentSeconds: TimeInterval = 20

    /// A word on more photos than both of these is common in the batch, such as a store brand on
    /// every package, and is ignored when matching.
    public var commonWordMinimumPhotos = 4
    public var commonWordFraction = 0.3

    public var suggestionsPerGroup = 3

    public init() {}

    public static let standard = GroupingPolicy()
}

/// Why a photo is in its group: the photo already in the group it matched, and the signals.
public struct GroupLink: Sendable, Hashable, Codable {
    public let photo: IntakePhotoID
    public let matchedWith: IntakePhotoID
    public let signals: [MatchSignal]
    public let score: Int
}

/// Photos grouped as one product. The order is the order they were taken in.
public struct PhotoGroup: Sendable, Hashable, Codable {
    public var photos: [IntakePhotoID]
    public var links: [GroupLink]
    public var barcode: GTIN?
    /// Photos in this group that also show other products' barcodes.
    public var sharedPhotos: [IntakePhotoID]
}

/// Two groups that might be one package, with the evidence, for the person to decide.
public struct GroupSuggestion: Sendable, Hashable {
    public let first: Int
    public let second: Int
    public let signals: [MatchSignal]
    public let score: Int
}

public struct GroupingResult: Sendable, Hashable {
    public var groups: [PhotoGroup]
    public var suggestions: [GroupSuggestion]

    public static let empty = GroupingResult(groups: [], suggestions: [])
}

/// The work one grouping did: photos prepared and pairs of photos scored. Deterministic, unlike a
/// time, so a test can hold it.
public struct GroupingCost: Sendable, Hashable {
    public var photos = 0
    public var pairsScored = 0

    public init(photos: Int = 0, pairsScored: Int = 0) {
        self.photos = photos
        self.pairsScored = pairsScored
    }

    public static func + (a: GroupingCost, b: GroupingCost) -> GroupingCost {
        GroupingCost(photos: a.photos + b.photos, pairsScored: a.pairsScored + b.pairsScored)
    }
}

/// Groups a batch's photos into package candidates. Deterministic for the same input in any order:
///
/// 1. Every pair of photos gets a score from the signals in `GroupingPolicy`. Two photos with
///    different barcodes are different products and can never be grouped. Two photos whose labels
///    differ in a distinguishing word or amount are never grouped automatically either.
/// 2. Pairs at or above `mergeAt` join their groups, strongest first, unless that would put two
///    barcodes, or two photos whose labels differ, in one group.
/// 3. Pairs between `suggestAt` and `mergeAt` that end up in different groups are suggestions.
/// 4. A photo showing several product barcodes joins the group of each, or starts one per barcode.
///
/// A doubtful pair stays as two groups with a suggestion rather than one silent merge.
public struct PhotoGrouper: Sendable {
    public let policy: GroupingPolicy
    private let distance: any ImageDistance
    private let dates: any PrintedDateReader

    public init(
        policy: GroupingPolicy = .standard,
        distance: any ImageDistance = EuclideanImageDistance(),
        dates: any PrintedDateReader = PrintedDateRecognition()
    ) {
        self.policy = policy
        self.distance = distance
        self.dates = dates
    }

    private struct Photo {
        let observation: PhotoObservation
        let tokens: Set<String>
        let products: [GTIN]
        let isDateOnly: Bool
        /// The words of the photo's prominent name.
        let prominent: Set<String>
        let percents: Set<String>
        let sizes: Set<String>
        var id: IntakePhotoID { observation.photo }
        var barcode: GTIN? { products.count == 1 ? products[0] : nil }
    }

    struct Pair {
        let a: Int
        let b: Int
        let signals: [MatchSignal]
        let score: Int
        var separated: Bool { signals.contains(where: \.separates) }
    }

    public func group(_ observations: [PhotoObservation]) -> GroupingResult {
        measuredGroup(observations).result
    }

    /// Groups, and counts the work done, so a change that makes grouping costlier shows in a test.
    public func measuredGroup(_ observations: [PhotoObservation]) -> (result: GroupingResult, cost: GroupingCost) {
        let photos = prepare(observations)
        let single = photos.indices.filter { photos[$0].products.count < 2 }
        let common = commonWords(photos)

        var pairs: [Pair] = []
        var cost = GroupingCost(photos: photos.count)
        for (position, i) in single.enumerated() {
            for j in single[(position + 1)...] {
                cost.pairsScored += 1
                if let pair = score(photos, i, j, ignoring: common) { pairs.append(pair) }
            }
        }
        pairs.sort { x, y in
            if x.score != y.score { return x.score > y.score }
            if x.a != y.a { return x.a < y.a }
            return x.b < y.b
        }

        // Union-find over photo indices, with each root's barcode, so no group holds two.
        var parent = Array(photos.indices)
        var barcodeOf = photos.map(\.barcode)
        var members = photos.indices.map { [$0] }
        var separated: Set<[Int]> = []
        for pair in pairs where pair.separated { separated.insert([pair.a, pair.b]) }
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        func compatible(_ x: Int, _ y: Int) -> Bool {
            if let bx = barcodeOf[x], let by = barcodeOf[y], bx != by { return false }
            for i in members[x] {
                for j in members[y] where separated.contains([min(i, j), max(i, j)]) { return false }
            }
            return true
        }
        var links: [Int: [GroupLink]] = [:]
        // A separated pair is refused by `compatible`, which checks every pair across the two groups.
        for pair in pairs where pair.score >= policy.mergeAt {
            let (ra, rb) = (root(pair.a), root(pair.b))
            guard ra != rb, compatible(ra, rb) else { continue }
            let (keep, absorb) = ra < rb ? (ra, rb) : (rb, ra)
            parent[absorb] = keep
            barcodeOf[keep] = barcodeOf[keep] ?? barcodeOf[absorb]
            members[keep] += members[absorb]
            let link = GroupLink(photo: photos[pair.b].id, matchedWith: photos[pair.a].id, signals: pair.signals, score: pair.score)
            links[keep, default: []] += (links.removeValue(forKey: absorb) ?? []) + [link]
        }

        // Groups in the order of their first photo, since photos are sorted by sequence.
        var groupOfRoot: [Int: Int] = [:]
        var groups: [PhotoGroup] = []
        for index in single {
            let r = root(index)
            if let existing = groupOfRoot[r] {
                groups[existing].photos.append(photos[index].id)
            } else {
                groupOfRoot[r] = groups.count
                groups.append(PhotoGroup(photos: [photos[index].id], links: links[r] ?? [], barcode: barcodeOf[r], sharedPhotos: []))
            }
        }

        // A photo of several products joins each product's group, or starts one.
        for index in photos.indices where photos[index].products.count >= 2 {
            for gtin in photos[index].products {
                if let existing = groups.firstIndex(where: { $0.barcode == gtin }) {
                    groups[existing].photos.append(photos[index].id)
                    groups[existing].sharedPhotos.append(photos[index].id)
                } else if groups.count < IntakeLimits.candidatesPerBatch {
                    groups.append(PhotoGroup(photos: [photos[index].id], links: [], barcode: gtin, sharedPhotos: [photos[index].id]))
                }
            }
        }
        let sequence = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0.observation.sequence) })
        for index in groups.indices {
            groups[index].photos.sort { (sequence[$0] ?? 0) < (sequence[$1] ?? 0) }
        }

        let result = GroupingResult(groups: groups, suggestions: suggestions(pairs, photos, groupOfRoot: groupOfRoot, root: root, groups: groups))
        return (result, cost)
    }

    private func suggestions(
        _ pairs: [Pair],
        _ photos: [Photo],
        groupOfRoot: [Int: Int],
        root: (Int) -> Int,
        groups: [PhotoGroup]
    ) -> [GroupSuggestion] {
        var best: [[Int]: Pair] = [:]
        for pair in pairs where pair.score >= policy.suggestAt {
            guard let ga = groupOfRoot[root(pair.a)], let gb = groupOfRoot[root(pair.b)], ga != gb else { continue }
            // Two barcodes mean two products, however alike the photos look.
            if let x = groups[ga].barcode, let y = groups[gb].barcode, x != y { continue }
            let key = [min(ga, gb), max(ga, gb)]
            if best[key] == nil { best[key] = pair }
        }
        var perGroup: [Int: Int] = [:]
        var result: [GroupSuggestion] = []
        for (key, pair) in best.sorted(by: { x, y in
            x.value.score != y.value.score ? x.value.score > y.value.score : x.key.lexicographicallyPrecedes(y.key)
        }) {
            guard perGroup[key[0], default: 0] < policy.suggestionsPerGroup,
                  perGroup[key[1], default: 0] < policy.suggestionsPerGroup else { continue }
            perGroup[key[0], default: 0] += 1
            perGroup[key[1], default: 0] += 1
            result.append(GroupSuggestion(first: key[0], second: key[1], signals: pair.signals, score: pair.score))
        }
        return result.sorted { ($0.first, $0.second) < ($1.first, $1.second) }
    }

    /// One observation per photo, in sequence order, at most a batch's worth.
    private func prepare(_ observations: [PhotoObservation]) -> [Photo] {
        var seen: Set<IntakePhotoID> = []
        let ordered = observations
            .sorted { a, b in
                a.sequence != b.sequence ? a.sequence < b.sequence : a.photo.rawValue.uuidString < b.photo.rawValue.uuidString
            }
            .filter { seen.insert($0.photo).inserted }
            .prefix(IntakeLimits.photosPerBatch)
        return ordered.map { observation in
            let tokens = LabelText.significantTokens(of: observation)
            let products = observation.products
            let isDateOnly = tokens.isEmpty && products.isEmpty && !dates.readings(in: observation.lines, takenAt: observation.capturedAt).isEmpty
            let amounts = LabelText.variantAmounts(of: observation)
            return Photo(
                observation: observation, tokens: tokens, products: products, isDateOnly: isDateOnly,
                prominent: LabelText.nameTokens(of: observation), percents: amounts.percents, sizes: amounts.sizes
            )
        }
    }

    private func commonWords(_ photos: [Photo]) -> Set<String> {
        var counts: [String: Int] = [:]
        for photo in photos {
            for token in photo.tokens { counts[token, default: 0] += 1 }
        }
        let limit = max(policy.commonWordMinimumPhotos, Int((Double(photos.count) * policy.commonWordFraction).rounded(.up)))
        return Set(counts.filter { $0.value > limit }.keys)
    }

    /// The signals and score for two photos on their own, as grouping would weigh them in a batch
    /// of two. Nil when nothing links them, and when their barcodes differ.
    public func evidence(between a: PhotoObservation, and b: PhotoObservation) -> (signals: [MatchSignal], score: Int)? {
        let photos = prepare([a, b])
        guard photos.count == 2, let pair = score(photos, 0, 1, ignoring: []) else { return nil }
        return (pair.signals, pair.score)
    }

    private func score(_ photos: [Photo], _ i: Int, _ j: Int, ignoring common: Set<String>) -> Pair? {
        let (a, b) = (photos[i], photos[j])
        if let x = a.barcode, let y = b.barcode, x != y { return nil }
        var signals: [MatchSignal] = []
        var score = 0
        func add(_ signal: MatchSignal, _ points: Int) {
            signals.append(signal)
            score += points
        }

        if let x = a.barcode, x == b.barcode { add(.sameBarcode, policy.sameBarcode) }
        if let x = a.observation.contentDigest, x == b.observation.contentDigest {
            add(.identicalPhoto, policy.identicalPhoto)
        } else if let x = a.observation.featurePrint, let y = b.observation.featurePrint, let d = distance.distance(x, y), d.isFinite {
            if d <= policy.nearDuplicateDistance {
                add(.nearDuplicateImage, policy.nearDuplicateImage)
            } else if d <= policy.similarDistance {
                add(.similarImage, policy.similarImage)
            }
        }

        let shared = a.tokens.intersection(b.tokens).subtracting(common)
        let smaller = min(a.tokens.subtracting(common).count, b.tokens.subtracting(common).count)
        if shared.count >= policy.sharedWordsForStrongText, smaller > 0,
           Double(shared.count) / Double(smaller) >= policy.overlapForStrongText {
            add(.sharedLabelWords, policy.sharedLabelWords)
        } else if shared.count >= 2 || shared.contains(where: { $0.count >= policy.longWordLetters }) {
            add(.someLabelWords, policy.someLabelWords)
        }

        let gap = abs(b.observation.capturedAt.timeIntervalSince(a.observation.capturedAt))
        if b.observation.sequence - a.observation.sequence == 1, gap <= policy.adjacentSeconds {
            add(.takenRightAfter, policy.takenRightAfter)
            if b.isDateOnly, !a.isDateOnly {
                add(.datePhotoAfter, policy.datePhotoAfter)
            } else if a.isDateOnly, !b.isDateOnly {
                add(.datePhotoBefore, policy.datePhotoBefore)
            }
        }
        // A barcode or identical bytes settle it; otherwise a differing label counts against.
        // Recorded even when nothing links the pair, so a third photo cannot chain the two together.
        if !signals.contains(.sameBarcode), !signals.contains(.identicalPhoto) {
            let sharesProminentWord = !a.prominent.isDisjoint(with: b.prominent)
            if sharesProminentWord, !a.prominent.isSubset(of: b.tokens), !b.prominent.isSubset(of: a.tokens) {
                signals.append(.differentLabelWords)
            }
            let percentsDiffer = !a.percents.isEmpty && !b.percents.isEmpty && a.percents.isDisjoint(with: b.percents)
            let sizesDiffer = !a.sizes.isEmpty && !b.sizes.isEmpty && a.sizes.isDisjoint(with: b.sizes)
            if percentsDiffer || sizesDiffer { signals.append(.differentAmounts) }
        }
        return signals.isEmpty ? nil : Pair(a: i, b: j, signals: signals, score: score)
    }
}
