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
    /// One distinctive word, or two short ones, in common, or a long word one letter off.
    case someLabelWords
    /// Words of the barcode lookup's product name, for the barcode one photo shows, on the other
    /// photo's label.
    case lookupName
    /// Words of one photo's name in the other photo's ingredients list.
    case nameInIngredients
    /// The same lot code printed on both.
    case sameLotCode
    /// Taken one straight after the other, counted only beside other evidence.
    case takenRightAfter
    /// A photo of only a date, taken straight after this one. Grouping never gives it, since the
    /// order of shots is not evidence; it exists so saved reviews that hold it still decode.
    case datePhotoAfter
    /// A photo of only a date, taken straight before this one. Never given, like `datePhotoAfter`.
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
    /// Points when the other photo's label holds `sharedWordsForStrongText` or more words of the
    /// lookup name for this photo's barcode, covering `overlapForStrongText` of that name. Enough to
    /// group alone. Label words and lookup words count once: a pair gets the larger of the two.
    public var lookupNameWords = 60
    /// Points for fewer lookup name words: two, or one of `longWordLetters` letters or more. Also
    /// given, toward a suggestion only, for a name word one letter off a lookup word, and for any
    /// lookup words when the photos showing the barcode have words and none of them is in the
    /// lookup's name, which happens when the lookup describes another product.
    public var someLookupNameWords = 30
    /// Points when `ingredientWordsForLink` or more words of one photo's name, at least half of
    /// them, are in the other photo's ingredients list. Toward a suggestion only, since a panel
    /// never names a product: a "Sparkling water lime" front and a panel listing carbonated water
    /// and lime.
    public var nameInIngredients = 30
    public var ingredientWordsForLink = 2
    /// Points when both photos print the same lot code: a run of letters and digits at least
    /// `lotCodeCharacters` long with at least `lotCodeDigits` digits, such as "LFE282315113". A
    /// suggestion alone, a group with any other evidence.
    public var sameLotCode = 50
    public var lotCodeCharacters = 8
    public var lotCodeDigits = 3
    /// Points when the photos were taken one straight after the other, within `adjacentSeconds`.
    /// Given only when what the photos show already reaches `suggestAt` without points that count
    /// toward a suggestion only, so the order of shots never makes a suggestion or a group by
    /// itself. With `orderCountsTowardGroup` they can turn a suggestion of 45 or more into a group,
    /// such as a front and its back that repeat three of the same words; without it they only rank
    /// a pair above another with the same evidence.
    public var takenRightAfter = 15
    public var orderCountsTowardGroup = true

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

    /// Points when a word of one photo's name is one letter off a word on the other photo, such as
    /// "Toacker" and "Loacker". They count toward `suggestAt` only, never toward `mergeAt`.
    public var nearlySameWord = 20
    /// Both words must have at least this many letters to count as one letter off. Shorter words
    /// one letter apart are too often different products: coffee and toffee, skim and skip.
    public var nearWordLetters = 7
    /// Longer words are not compared one letter off; few product words are this long.
    public var nearWordMaximumLetters = 20
    /// Name words per photo compared one letter off against the other photo's words.
    public var nearWordsPerName = 4
    /// Words per photo that the other photo's name words are compared with.
    public var nearWordsPerPhoto = 64

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

    /// Pairs of photos this result puts in one group or suggests as one, and `earlier` does
    /// neither, such as photos a lookup answer links. Photos of several products are left out.
    /// Each pair once, in a fixed order.
    public func photosLinked(beyond earlier: GroupingResult) -> [(IntakePhotoID, IntakePhotoID)] {
        let before = earlier.linkedPairs
        return linkedPairs.subtracting(before)
            .map { ($0[0], $0[1]) }
            .sorted { ($0.0.rawValue.uuidString, $0.1.rawValue.uuidString) < ($1.0.rawValue.uuidString, $1.1.rawValue.uuidString) }
    }

    private var linkedPairs: Set<[IntakePhotoID]> {
        func own(_ group: PhotoGroup) -> [IntakePhotoID] { group.photos.filter { !group.sharedPhotos.contains($0) } }
        func pair(_ x: IntakePhotoID, _ y: IntakePhotoID) -> [IntakePhotoID] {
            x.rawValue.uuidString < y.rawValue.uuidString ? [x, y] : [y, x]
        }
        var pairs: Set<[IntakePhotoID]> = []
        for group in groups {
            let photos = own(group)
            for (index, x) in photos.enumerated() {
                for y in photos[(index + 1)...] { pairs.insert(pair(x, y)) }
            }
        }
        for suggestion in suggestions where suggestion.first < groups.count && suggestion.second < groups.count {
            for x in own(groups[suggestion.first]) {
                for y in own(groups[suggestion.second]) where x != y { pairs.insert(pair(x, y)) }
            }
        }
        return pairs
    }
}

/// The work one grouping did: photos prepared and pairs of photos scored. Deterministic, unlike a
/// time, so a test can hold it.
public struct GroupingCost: Sendable, Hashable {
    public var photos = 0
    public var pairsScored = 0
    /// Lookups made to find words one letter off, at most `nearLookupsPerPair` for each pair.
    public var nearWordLookups = 0
    /// Lookup names read into words, once for each answer.
    public var lookupNamesPrepared = 0

    public init(photos: Int = 0, pairsScored: Int = 0, nearWordLookups: Int = 0, lookupNamesPrepared: Int = 0) {
        self.photos = photos
        self.pairsScored = pairsScored
        self.nearWordLookups = nearWordLookups
        self.lookupNamesPrepared = lookupNamesPrepared
    }

    public static func + (a: GroupingCost, b: GroupingCost) -> GroupingCost {
        GroupingCost(
            photos: a.photos + b.photos, pairsScored: a.pairsScored + b.pairsScored,
            nearWordLookups: a.nearWordLookups + b.nearWordLookups,
            lookupNamesPrepared: a.lookupNamesPrepared + b.lookupNamesPrepared
        )
    }
}

/// Groups a batch's photos into package candidates. A pure function of the photos and the barcode
/// lookups' names, deterministic for the same photos and names in any order:
///
/// 1. Every pair of photos gets a score from the signals in `GroupingPolicy`, all from what the
///    photos show: barcodes, label words, the lookup name of a barcode a photo shows, ingredients,
///    lot codes and looks. The order of shots only supports pairs those already link. Two photos
///    with different barcodes are different products and can never be grouped. Two photos whose
///    labels, or a label and a lookup name, differ in a distinguishing word or amount are never
///    grouped automatically either.
/// 2. Pairs at or above `mergeAt` join their groups, strongest first, unless that would put two
///    barcodes, or two photos whose labels differ, in one group.
/// 3. Pairs between `suggestAt` and `mergeAt` that end up in different groups are suggestions.
/// 4. A photo showing several product barcodes joins the group of each, or starts one per barcode.
///
/// A doubtful pair stays as two groups with a suggestion rather than one silent merge.
public struct PhotoGrouper: Sendable {
    public let policy: GroupingPolicy
    let distance: any ImageDistance
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

    struct Pair {
        let a: Int
        let b: Int
        let signals: [MatchSignal]
        /// The points each signal added, in the order of `signals`. A signal that counts against
        /// adds 0, and so do label words found only one letter off, whose points are `nearPoints`.
        let signalPoints: [Int]
        let score: Int
        /// Points from a name word one letter off a word on the other photo.
        let nearPoints: Int
        /// Points that count toward a suggestion only, never toward `mergeAt`: `nearPoints`, a name
        /// in the other photo's ingredients, lookup words not to be relied on, and the order of shots
        /// unless `orderCountsTowardGroup`.
        let suggestOnly: Int
        var separated: Bool { signals.contains(where: \.separates) }
        var mergeScore: Int { score - suggestOnly }
    }

    /// What lookups said for the barcodes in a batch, and whether the photos showing each barcode
    /// agree with it.
    struct Bridges {
        let lookups: [GTIN: PreparedLookup]
        /// Barcodes whose photos have label words, none of them in the lookup's name.
        let doubtful: Set<GTIN>

        func lookup(for photo: PreparedPhoto) -> PreparedLookup? {
            photo.barcode.flatMap { lookups[$0] }
        }
    }

    /// Groups the photos. `lookupNames` holds the product name a barcode lookup found, by barcode;
    /// a barcode with no answer, a miss or a failure is simply left out.
    public func group(_ observations: [PhotoObservation], lookupNames: [GTIN: String] = [:]) -> GroupingResult {
        measuredGroup(observations, lookupNames: lookupNames).result
    }

    /// Groups, and counts the work done, so a change that makes grouping costlier shows in a test.
    public func measuredGroup(
        _ observations: [PhotoObservation],
        lookupNames: [GTIN: String] = [:]
    ) -> (result: GroupingResult, cost: GroupingCost) {
        let lookups = lookupNames.mapValues(prepare(lookupName:))
        var measured = measuredGroup(prepared: batch(observations, sequence: \.sequence, photo: \.photo).map(prepare), lookups: lookups)
        measured.cost.lookupNamesPrepared += lookups.count
        return measured
    }

    /// Groups photos and lookup names prepared earlier, so a batch grouped again as each photo or
    /// answer arrives reads each photo and each name once. The same as grouping their observations
    /// with those names.
    public func measuredGroup(
        prepared: [PreparedPhoto],
        lookups: [GTIN: PreparedLookup] = [:]
    ) -> (result: GroupingResult, cost: GroupingCost) {
        let photos = batch(prepared, sequence: \.observation.sequence, photo: \.id)
        let single = photos.indices.filter { photos[$0].products.count < 2 }
        var cost = GroupingCost(photos: photos.count)
        var pairs = scoredPairs(photos, lookups: lookups, cost: &cost)
        pairs.sort { x, y in
            if x.mergeScore != y.mergeScore { return x.mergeScore > y.mergeScore }
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
        for pair in pairs where pair.mergeScore >= policy.mergeAt {
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

    /// Every pair of photos showing at most one product that any signal links or separates.
    /// `photos` are in sequence order, as `batch` gives them.
    func scoredPairs(_ photos: [PreparedPhoto], lookups: [GTIN: PreparedLookup], cost: inout GroupingCost) -> [Pair] {
        let single = photos.indices.filter { photos[$0].products.count < 2 }
        let common = commonWords(photos)
        let bridges = self.bridges(photos, lookups)
        var pairs: [Pair] = []
        for (position, i) in single.enumerated() {
            for j in single[(position + 1)...] {
                cost.pairsScored += 1
                if let pair = score(photos, i, j, ignoring: common, bridges: bridges, lookups: &cost.nearWordLookups) {
                    pairs.append(pair)
                }
            }
        }
        return pairs
    }

    private func suggestions(
        _ pairs: [Pair],
        _ photos: [PreparedPhoto],
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

    /// One item per photo, in sequence order, at most a batch's worth.
    func batch<Item>(_ items: [Item], sequence: (Item) -> Int, photo: (Item) -> IntakePhotoID) -> [Item] {
        var seen: Set<IntakePhotoID> = []
        return Array(items
            .sorted { a, b in
                sequence(a) != sequence(b) ? sequence(a) < sequence(b) : photo(a).rawValue.uuidString < photo(b).rawValue.uuidString
            }
            .filter { seen.insert(photo($0)).inserted }
            .prefix(IntakeLimits.photosPerBatch))
    }

    /// What grouping reads from one photo. It depends on the photo alone, never on the rest of
    /// the batch, so it can be kept while the batch grows.
    public func prepare(_ observation: PhotoObservation) -> PreparedPhoto {
        // Each line outside a panel with its words, read once for the label words and the words
        // compared one letter off. A panel's words are kept apart and only ever looked in for a
        // name.
        var labelLines: [(line: RecognizedTextLine, words: [String])] = []
        var panelWords: Set<String> = []
        for line in observation.lines {
            let words = LabelText.significantTokens(line.text)
            if LabelText.isPanelLine(line.text) {
                panelWords.formUnion(words)
            } else {
                labelLines.append((line, words))
            }
        }
        let products = observation.products
        let showsDetails = !products.isEmpty || LabelText.showsPanel(observation.lines)
            || !dates.readings(in: observation.lines, takenAt: observation.capturedAt).isEmpty
        let amounts = LabelText.variantAmounts(of: observation)
        let prominent = LabelText.nameTokens(of: observation)
        return PreparedPhoto(
            observation: observation, tokens: Set(labelLines.flatMap(\.words)), products: products,
            showsDetails: showsDetails, prominent: prominent, percents: amounts.percents, sizes: amounts.sizes,
            near: nearWords(labelLines, prominent: prominent), panelWords: panelWords,
            lotCodes: LabelText.lotCodes(in: observation.lines, characters: policy.lotCodeCharacters, digits: policy.lotCodeDigits)
        )
    }

    /// What grouping reads from a lookup's product name: its words, ready for finding words one
    /// letter off, and its percentages. Made once for each answer, never for each pair.
    public func prepare(lookupName: String) -> PreparedLookup {
        let name = BoundedText.clean(lookupName, characters: IntakeLimits.nameCharacters, bytes: IntakeLimits.nameBytes)
        let words = LabelText.significantTokens(name)
        let range = policy.nearWordLetters...policy.nearWordMaximumLetters
        var near = NearWords()
        for word in words where range.contains(word.unicodeScalars.count) { near.add(word) }
        let percents = LabelText.amounts(in: name).filter { $0.unit == "%" }.map { $0.number + "%" }
        return PreparedLookup(tokens: Set(words), near: near, percents: Set(percents))
    }

    /// The product names lookups found, by barcode. Misses, failures, deferrals and barcodes not
    /// asked yet give no name.
    public static func lookupNames(_ answers: [GTIN: LookupAnswer]) -> [GTIN: String] {
        answers.compactMapValues { answer in
            if case .found(let name, _) = answer { return name }
            return nil
        }
    }

    /// Which barcodes' lookup names the photos showing them contradict: those photos have label
    /// words and none of them is in the name.
    private func bridges(_ photos: [PreparedPhoto], _ lookups: [GTIN: PreparedLookup]) -> Bridges {
        var speaks: Set<GTIN> = []
        var agrees: Set<GTIN> = []
        for photo in photos {
            guard let barcode = photo.barcode, let lookup = lookups[barcode], !photo.tokens.isEmpty else { continue }
            speaks.insert(barcode)
            if !photo.tokens.isDisjoint(with: lookup.tokens) { agrees.insert(barcode) }
        }
        return Bridges(lookups: lookups, doubtful: speaks.subtracting(agrees))
    }


    /// The photo's words ready for finding words one letter off. Only words of `nearWordLetters` to
    /// `nearWordMaximumLetters` letters outside a panel take part: at most `nearWordsPerPhoto` of
    /// them, from the tallest lines first, where a brand is printed, and at most `nearWordsPerName`
    /// name words in alphabetical order.
    private func nearWords(_ lines: [(line: RecognizedTextLine, words: [String])], prominent: Set<String>) -> NearWords {
        let range = policy.nearWordLetters...policy.nearWordMaximumLetters
        let tallestFirst = lines.enumerated().sorted { x, y in
            let (hx, hy) = (x.element.line.box.height, y.element.line.box.height)
            return hx != hy ? hx > hy : x.offset < y.offset
        }
        var near = NearWords()
        lines: for entry in tallestFirst {
            for word in entry.element.words where range.contains(word.unicodeScalars.count) {
                guard near.words.count < policy.nearWordsPerPhoto else { break lines }
                near.add(word)
            }
        }
        near.queries = prominent.filter { range.contains($0.unicodeScalars.count) }.sorted()
            .prefix(policy.nearWordsPerName).map(NearWords.Query.init)
        return near
    }

    /// The most lookups one pair can make: every name word of both photos, each looked up whole and
    /// with two keys a letter in the other photo's words, the name words of the photo without a
    /// barcode looked up the same way in the lookup name for the other's barcode, and every name
    /// word of one photo compared with every name word of the other.
    public var nearLookupsPerPair: Int {
        3 * policy.nearWordsPerName * (1 + 2 * policy.nearWordMaximumLetters) + policy.nearWordsPerName * policy.nearWordsPerName
    }

    private func commonWords(_ photos: [PreparedPhoto]) -> Set<String> {
        var counts: [String: Int] = [:]
        for photo in photos {
            for token in photo.tokens.union(photo.lotCodes) { counts[token, default: 0] += 1 }
        }
        let limit = max(policy.commonWordMinimumPhotos, Int((Double(photos.count) * policy.commonWordFraction).rounded(.up)))
        return Set(counts.filter { $0.value > limit }.keys)
    }

    /// The signals and score for two photos on their own, as grouping would weigh them in a batch
    /// of two with these lookup names. Nil when nothing links them, and when their barcodes differ.
    public func evidence(
        between a: PhotoObservation,
        and b: PhotoObservation,
        lookupNames: [GTIN: String] = [:]
    ) -> (signals: [MatchSignal], score: Int)? {
        let photos = batch([a, b], sequence: \.sequence, photo: \.photo).map(prepare)
        guard photos.count == 2 else { return nil }
        var lookups = 0
        let bridges = self.bridges(photos, lookupNames.mapValues(prepare(lookupName:)))
        guard let pair = score(photos, 0, 1, ignoring: [], bridges: bridges, lookups: &lookups) else { return nil }
        return (pair.signals, pair.score)
    }

    /// How a lookup name for one photo's barcode meets a photo without a barcode.
    private struct LookupMatch {
        let lookup: PreparedLookup
        let other: PreparedPhoto
        /// Lookup words on the other photo's label, outside its panel.
        let exact: Set<String>
        /// The other photo's name words one letter off a lookup word, and the lookup words they match.
        let nearName: Set<String>
        let nearLookup: Set<String>
        let doubtful: Bool
    }

    private func match(
        _ lookup: PreparedLookup,
        doubtful: Bool,
        other: PreparedPhoto,
        ignoring common: Set<String>,
        lookups: inout Int
    ) -> LookupMatch {
        var nearName: Set<String> = []
        var nearLookup: Set<String> = []
        for query in other.near.queries where !lookup.tokens.contains(query.word) && !common.contains(query.word) {
            lookups += 1 + query.removals.count + query.replacements.count
            let found = lookup.near.near(query).subtracting(common)
            if !found.isEmpty {
                nearName.insert(query.word)
                nearLookup.formUnion(found)
            }
        }
        return LookupMatch(
            lookup: lookup, other: other, exact: lookup.tokens.subtracting(common).intersection(other.tokens),
            nearName: nearName, nearLookup: nearLookup, doubtful: doubtful
        )
    }

    /// Whether `ingredientWordsForLink` or more of the photo's name words, at least half of them,
    /// are among the panel words of another photo.
    private func nameIsIn(_ photo: PreparedPhoto, _ panelWords: Set<String>, ignoring common: Set<String>) -> Bool {
        let name = photo.prominent.subtracting(common)
        let found = name.intersection(panelWords).count
        return found >= policy.ingredientWordsForLink && found * 2 >= name.count
    }

    private func score(
        _ photos: [PreparedPhoto],
        _ i: Int,
        _ j: Int,
        ignoring common: Set<String>,
        bridges: Bridges,
        lookups: inout Int
    ) -> Pair? {
        let (a, b) = (photos[i], photos[j])
        if let x = a.barcode, let y = b.barcode, x != y { return nil }
        var signals: [MatchSignal] = []
        var points: [Int] = []
        var score = 0
        var suggestOnly = 0
        func add(_ signal: MatchSignal, _ added: Int) {
            signals.append(signal)
            points.append(added)
            score += added
        }
        func mark(_ signal: MatchSignal) {
            if !signals.contains(signal) { add(signal, 0) }
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

        // Words, from the labels and from the lookup name of a barcode one photo shows. They count
        // once: the pair gets the larger of the two.
        var words = 0
        let shared = a.tokens.intersection(b.tokens).subtracting(common)
        let smaller = min(a.tokens.subtracting(common).count, b.tokens.subtracting(common).count)
        if shared.count >= policy.sharedWordsForStrongText, smaller > 0,
           Double(shared.count) / Double(smaller) >= policy.overlapForStrongText {
            add(.sharedLabelWords, policy.sharedLabelWords)
            words = policy.sharedLabelWords
        } else if shared.count >= 2 || shared.contains(where: { $0.count >= policy.longWordLetters }) {
            add(.someLabelWords, policy.someLabelWords)
            words = policy.someLabelWords
        }

        // Name words one letter off a word on the other photo, such as a misread "Toacker" for
        // "Loacker". A word the other photo shows exactly is not looked for.
        var nearA: Set<String> = []
        var nearB: Set<String> = []
        for query in a.near.queries where !b.tokens.contains(query.word) && b.near.hasNear(query, ignoring: common, lookups: &lookups) {
            nearA.insert(query.word)
        }
        for query in b.near.queries where !a.tokens.contains(query.word) && a.near.hasNear(query, ignoring: common, lookups: &lookups) {
            nearB.insert(query.word)
        }
        var nearPoints = 0
        if !nearA.isEmpty || !nearB.isEmpty {
            if !signals.contains(.sharedLabelWords) { mark(.someLabelWords) }
            nearPoints = policy.nearlySameWord
            score += nearPoints
            suggestOnly += nearPoints
        }

        // The lookup name stands in for the words a back shares with its front: a front has no
        // barcode, and its back often repeats nothing of its name.
        var bridge: LookupMatch?
        if let barcode = a.barcode, b.products.isEmpty, let lookup = bridges.lookup(for: a) {
            bridge = match(lookup, doubtful: bridges.doubtful.contains(barcode), other: b, ignoring: common, lookups: &lookups)
        } else if let barcode = b.barcode, a.products.isEmpty, let lookup = bridges.lookup(for: b) {
            bridge = match(lookup, doubtful: bridges.doubtful.contains(barcode), other: a, ignoring: common, lookups: &lookups)
        }
        if let bridge {
            let named = bridge.lookup.tokens.subtracting(common)
            let strong = bridge.exact.count >= policy.sharedWordsForStrongText && !named.isEmpty
                && Double(bridge.exact.count) / Double(named.count) >= policy.overlapForStrongText
            let some = bridge.exact.count >= 2 || bridge.exact.contains { $0.count >= policy.longWordLetters }
            if strong || some || !bridge.nearName.isEmpty {
                if bridge.doubtful || !(strong || some) {
                    add(.lookupName, policy.someLookupNameWords)
                    suggestOnly += policy.someLookupNameWords
                } else {
                    // Only what the lookup adds beyond the label words.
                    add(.lookupName, max(0, (strong ? policy.lookupNameWords : policy.someLookupNameWords) - words))
                }
            }
        }

        if nameIsIn(a, b.panelWords, ignoring: common) || nameIsIn(b, a.panelWords, ignoring: common) {
            add(.nameInIngredients, policy.nameInIngredients)
            suggestOnly += policy.nameInIngredients
        }
        if !a.lotCodes.intersection(b.lotCodes).subtracting(common).isEmpty { add(.sameLotCode, policy.sameLotCode) }

        // The order of shots supports a pair the photos already link, and never stands in for what
        // they show.
        let gap = abs(b.observation.capturedAt.timeIntervalSince(a.observation.capturedAt))
        if b.observation.sequence - a.observation.sequence == 1, gap <= policy.adjacentSeconds,
           score - suggestOnly >= policy.suggestAt {
            add(.takenRightAfter, policy.takenRightAfter)
            if !policy.orderCountsTowardGroup { suggestOnly += policy.takenRightAfter }
        }

        // A barcode or identical bytes settle it; otherwise a differing label counts against.
        // Recorded even when nothing links the pair, so a third photo cannot chain the two together.
        if !signals.contains(.sameBarcode), !signals.contains(.identicalPhoto) {
            // When a photo shows a package's details, a name word one letter off a word on the
            // other photo is taken for a misread of that word. Two fronts are compared on exact
            // words only, since "mustard" and "custard" could be two products.
            let bothFronts = !a.showsDetails && !b.showsDetails
            let nearly = bothFronts ? (Set<String>(), Set<String>()) : (nearA, nearB)
            var sharesProminentWord = !a.prominent.isDisjoint(with: b.prominent)
            if !sharesProminentWord, !bothFronts {
                sharesProminentWord = a.near.queries.contains { x in
                    b.near.queries.contains { y in
                        lookups += 1
                        return LabelText.isOneEditApart(x.word, y.word)
                    }
                }
            }
            let aLacks = a.prominent.subtracting(b.tokens).subtracting(nearly.0)
            let bLacks = b.prominent.subtracting(a.tokens).subtracting(nearly.1)
            if sharesProminentWord, !aLacks.isEmpty, !bLacks.isEmpty {
                mark(.differentLabelWords)
            }
            let percentsDiffer = !a.percents.isEmpty && !b.percents.isEmpty && a.percents.isDisjoint(with: b.percents)
            let sizesDiffer = !a.sizes.isEmpty && !b.sizes.isEmpty && a.sizes.isDisjoint(with: b.sizes)
            if percentsDiffer || sizesDiffer { mark(.differentAmounts) }

            // The lookup name read as the back's name: a front that shares a word with it, while
            // each has a word the other lacks, is another version of the product ("Vanilla" and
            // "Chocolate", baking soda and baking powder), as is a different prominent percentage.
            if let bridge {
                let other = bridge.other
                let sharesName = !other.prominent.isDisjoint(with: bridge.lookup.tokens) || !bridge.nearName.isEmpty
                let otherLacks = other.prominent.subtracting(bridge.lookup.tokens).subtracting(bridge.nearName)
                let lookupLacks = bridge.lookup.tokens.subtracting(other.tokens).subtracting(bridge.nearLookup)
                if sharesName, !otherLacks.isEmpty, !lookupLacks.isEmpty { mark(.differentLabelWords) }
                if !bridge.lookup.percents.isEmpty, !other.percents.isEmpty, bridge.lookup.percents.isDisjoint(with: other.percents) {
                    mark(.differentAmounts)
                }
            }
        }
        return signals.isEmpty ? nil : Pair(
            a: i, b: j, signals: signals, signalPoints: points, score: score, nearPoints: nearPoints, suggestOnly: suggestOnly
        )
    }
}

/// What grouping reads from one photo, worked out once by `PhotoGrouper.prepare`.
public struct PreparedPhoto: Sendable {
    let observation: PhotoObservation
    let tokens: Set<String>
    let products: [GTIN]
    /// Shows a barcode, a printed date or a panel: what the back or side of a package shows.
    let showsDetails: Bool
    /// The words of the photo's prominent name.
    let prominent: Set<String>
    let percents: Set<String>
    let sizes: Set<String>
    let near: NearWords
    /// The words of the photo's panel lines. Only ever searched for another photo's name; never
    /// label words or a name.
    let panelWords: Set<String>
    let lotCodes: Set<String>
    public var id: IntakePhotoID { observation.photo }
    var barcode: GTIN? { products.count == 1 ? products[0] : nil }
}

/// What grouping reads from one lookup answer's product name, worked out once by
/// `PhotoGrouper.prepare(lookupName:)`.
public struct PreparedLookup: Sendable {
    let tokens: Set<String>
    let near: NearWords
    let percents: Set<String>
}
