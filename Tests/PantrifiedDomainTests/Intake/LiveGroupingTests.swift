import Foundation
import Testing
import PantrifiedDomain
import PantrifiedTestSupport

@Suite("Grouping as photos arrive")
struct LiveGroupingTests {
    let grouper = PhotoGrouper()

    /// A batch with every case grouping must keep: front, barcode and date photos taken in turn, a
    /// duplicate, a photo of two products, products that must never merge (different barcodes that
    /// look alike, baking soda and powder, whole and skim milk), and a doubtful pair that stays a
    /// suggestion.
    static let batch: [PhotoObservation] = [
        Fixture.photo(0, lines: Fixture.front("Greek yogurt", brand: "Chobani")),
        Fixture.photo(1, lines: Fixture.back(["Chobani greek yogurt", "Ingredients: cultured nonfat milk"]), codes: [.product(Fixture.yogurt)]),
        Fixture.photo(2, lines: [Fixture.line("BEST BY 12/05/26")]),
        Fixture.photo(3, seconds: 100, lines: Fixture.front("Greek yogurt vanilla", brand: "Chobani"), codes: [.product(Fixture.otherYogurt)], print: Fixture.print(1)),
        Fixture.photo(4, seconds: 140, lines: Fixture.front("Greek yogurt vanilla", brand: "Chobani"), codes: [.product(Fixture.soup)], print: Fixture.print(1)),
        Fixture.photo(5, seconds: 200, lines: Fixture.front("Baking soda", brand: "Arm Hammer")),
        Fixture.photo(6, seconds: 210, lines: Fixture.front("Baking powder", brand: "Arm Hammer")),
        Fixture.photo(7, seconds: 300, lines: Fixture.front("Whole milk", brand: "Horizon")),
        Fixture.photo(8, seconds: 310, lines: Fixture.front("Skim milk", brand: "Horizon")),
        Fixture.photo(9, seconds: 400, lines: Fixture.front("Rice"), digest: "aa11"),
        Fixture.photo(10, seconds: 900, lines: Fixture.front("Rice"), digest: "aa11"),
        Fixture.photo(11, seconds: 1_000, lines: Fixture.back([]), codes: [.product(Fixture.beans)]),
        Fixture.photo(12, seconds: 1_100, lines: Fixture.front("Groceries"), codes: [.product(Fixture.beans), .product(Fixture.yogurt)]),
        Fixture.photo(13, seconds: 1_200, lines: Fixture.front("Sour cream", brand: "Daisy")),
        Fixture.photo(14, seconds: 1_205, lines: Fixture.front("Cream", brand: "Daisy")),
    ]

    /// Pairs of photos (by sequence) that must never share a group at any step.
    static let neverTogether: [(Int, Int)] = [(1, 3), (1, 4), (3, 4), (5, 6), (7, 8), (11, 1)]

    @Test("the fixture has the cases it claims: merges, a suggestion and a photo of two products")
    func fixtureShape() {
        let result = grouper.group(Self.batch)
        let groups = result.sequences(Self.batch)
        #expect(groups.contains([0, 1, 2, 12]))
        #expect(groups.contains([9, 10]))
        #expect(groups.contains([11, 12]))
        #expect(!result.suggestions.isEmpty)
    }

    @Test("after every arrival order the result is the one-shot grouping, and no step joins photos that must stay apart")
    func anyArrivalOrder() {
        let oneShot = grouper.group(Self.batch)
        var generator = SeededGenerator(seed: 2_026)
        for _ in 0..<300 {
            var live = LiveGrouping(grouper: grouper)
            for observation in Self.batch.shuffled(using: &generator) {
                live.add(observation)
                Self.checkStep(live)
            }
            #expect(live.result == oneShot)
        }
    }

    @Test("arriving in reverse, front last, or one photo again changes nothing at the end")
    func namedOrders() {
        let oneShot = grouper.group(Self.batch)
        for order in [Self.batch.reversed(), Array(Self.batch.dropFirst()) + [Self.batch[0]], Self.batch + [Self.batch[3]]] {
            var live = LiveGrouping(grouper: grouper)
            for observation in order { live.add(observation) }
            #expect(live.result == oneShot)
            #expect(live.packagesSoFar == oneShot.groups.count)
        }
    }

    @Test("a photo taken back is grouped out again")
    func takenBack() {
        var live = LiveGrouping(grouper: grouper, observations: Self.batch)
        let without = Array(Self.batch.dropLast())
        let changed = live.sync(with: without)
        #expect(changed)
        #expect(live.result == grouper.group(without))
        let again = live.sync(with: without)
        #expect(!again)
    }

    /// Two photos with different barcodes, or labels that differ, never share a group.
    static func checkStep(_ live: LiveGrouping) {
        let bySequence = Dictionary(uniqueKeysWithValues: live.observations.values.map { ($0.sequence, $0.photo) })
        for group in live.result.groups {
            let own = group.photos.filter { !group.sharedPhotos.contains($0) }
            let barcodes = Set(own.compactMap { live.observations[$0] }.flatMap(\.products))
            #expect(barcodes.count <= 1)
            for (a, b) in neverTogether {
                guard let x = bySequence[a], let y = bySequence[b] else { continue }
                #expect(!(own.contains(x) && own.contains(y)))
            }
        }
    }

    // MARK: Cost

    /// 60 products, front then back with its barcode: 120 photos.
    static let full: [PhotoObservation] = (0..<60).flatMap { product -> [PhotoObservation] in
        let name = "Product\(Character(UnicodeScalar(65 + product % 26)!))\(String(repeating: "x", count: product / 26 + 3)) special"
        let barcode = Fixture.gtin(String(format: "5012345%05d", product))
        return [
            Fixture.photo(product * 2, seconds: Double(product) * 60, lines: Fixture.front(name), print: Fixture.print(product)),
            Fixture.photo(product * 2 + 1, seconds: Double(product) * 60 + 5, lines: Fixture.back([name]), codes: [.product(barcode)], print: Fixture.print(product, offset: 0.3)),
        ]
    }

    @Test("grouping 120 photos scores each pair once, and grouping after every arrival scores the sum of those")
    func cost() {
        let photos = Self.full.count
        let (result, once) = grouper.measuredGroup(Self.full)
        #expect(result.groups.count == 60)
        #expect(once.photos == photos)
        #expect(once.pairsScored == photos * (photos - 1) / 2)
        #expect(once.nearWordLookups <= once.pairsScored * grouper.nearLookupsPerPair)

        let clock = ContinuousClock()
        var live = LiveGrouping(grouper: grouper)
        let elapsed = clock.measure {
            for observation in Self.full { live.add(observation) }
        }
        let pairs = (1...photos).reduce(0) { $0 + $1 * ($1 - 1) / 2 }
        #expect(live.cost.photos == (1...photos).reduce(0, +))
        #expect(live.cost.pairsScored == pairs)
        #expect(live.cost.nearWordLookups <= pairs * grouper.nearLookupsPerPair)
        #expect(live.result == result)
        // A record for the docs, not a limit: the time depends on the machine.
        print("Grouping 120 photos after every arrival: \(live.cost.pairsScored) pairs, \(live.cost.nearWordLookups) word lookups, in \(elapsed)")
    }

    // MARK: Settling

    @Test("a candidate is settled once nothing has joined it for three shots or fifteen seconds")
    func settling() {
        let photos = [
            Fixture.photo(0, seconds: 0, lines: Fixture.front("Greek yogurt", brand: "Chobani")),
            Fixture.photo(1, seconds: 4, lines: Fixture.back(["Chobani greek yogurt"]), codes: [.product(Fixture.yogurt)]),
            Fixture.photo(2, seconds: 8, lines: Fixture.front("Black beans", brand: "Goya")),
        ]
        let live = LiveGrouping(grouper: grouper, observations: photos)
        let yogurt: Set = [photos[0].photo, photos[1].photo]
        #expect(live.settledPhotos(latestSequence: 2, now: Fixture.start.addingTimeInterval(10)).isEmpty)
        #expect(live.settledPhotos(latestSequence: 4, now: Fixture.start.addingTimeInterval(10)) == yogurt)
        #expect(live.settledPhotos(latestSequence: 2, now: Fixture.start.addingTimeInterval(19)) == yogurt)
        #expect(live.settledPhotos(latestSequence: 2, now: Fixture.start.addingTimeInterval(23)) == yogurt.union([photos[2].photo]))
    }
}
