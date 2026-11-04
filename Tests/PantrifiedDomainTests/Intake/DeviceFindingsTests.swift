import Foundation
import Testing
import PantrifiedDomain
import PantrifiedTestSupport

/// Synthetic readings modeled on the photos of the first device test (docs/batch-intake.md,
/// "Problems found on a device"): what a text reader plausibly returns for a Loacker Minis wafer's
/// front and back and a sparkling water can's front and nutrition side, with boxes as fractions of
/// the photo and the misreads seen on the device. No real photo or recognition result is used.
enum DeviceFixture {
    static let loacker = Fixture.gtin("007658018211")

    private static func line(_ text: String, x: Double, y: Double, width: Double, height: Double, confidence: Double) -> RecognizedTextLine {
        RecognizedTextLine(text: text, box: NormalizedBox(x: x, y: y, width: width, height: height), confidence: confidence)!
    }

    /// The front: the stylized logo read as "Toacker", the script "Minis", the flavor under it and
    /// the description. No barcode.
    static func loackerFront(_ flavor: String = "VANILLA", logo: String = "Toacker") -> [RecognizedTextLine] {
        [
            line(logo, x: 0.35, y: 0.36, width: 0.2, height: 0.04, confidence: 0.62),
            line("Minis", x: 0.36, y: 0.43, width: 0.17, height: 0.05, confidence: 0.81),
            line(flavor, x: 0.38, y: 0.5, width: 0.13, height: 0.016, confidence: 0.96),
            line("CRISPY WAFERS WITH \(flavor) CREAM FILLING", x: 0.24, y: 0.535, width: 0.41, height: 0.012, confidence: 0.9),
        ]
    }

    /// The back: the date in dot matrix with its label printed sideways, the lot code, the barcode's
    /// digits, the maker's address in small print and the top of a nutrition panel.
    static let loackerBack: [RecognizedTextLine] = [
        line("BEST IF USED BY:", x: 0.33, y: 0.26, width: 0.014, height: 0.1, confidence: 0.4),
        line("BB 11.2027", x: 0.47, y: 0.285, width: 0.16, height: 0.022, confidence: 0.55),
        line(">I LFE282315113", x: 0.45, y: 0.315, width: 0.2, height: 0.015, confidence: 0.5),
        line("NON GMO Project VERIFIED", x: 0.74, y: 0.335, width: 0.06, height: 0.008, confidence: 0.6),
        line("0 76580 18211 5", x: 0.39, y: 0.42, width: 0.3, height: 0.015, confidence: 0.9),
        line("MANUFACTURED BY: PRODUCTION PLANT IS INDICATED IN FRONT OF THE LOT NUMBER BY LETTER I OR A",
             x: 0.3, y: 0.435, width: 0.5, height: 0.008, confidence: 0.7),
        line("I: A. LOACKER SPA, 39054 AUNA DI SOTTO (BZ), ITALY. PRODUCT OF ITALY.", x: 0.3, y: 0.443, width: 0.48, height: 0.008, confidence: 0.72),
        line("A: A. LOACKER KONFEKT GMBH, 9919 HEINFELS, AUSTRIA. PRODUCT OF AUSTRIA", x: 0.3, y: 0.452, width: 0.48, height: 0.008, confidence: 0.7),
        line("Serv. size: 1 piece (10g),", x: 0.33, y: 0.47, width: 0.32, height: 0.018, confidence: 0.93),
        line("Amount per serving: Calories 50, Total", x: 0.33, y: 0.51, width: 0.38, height: 0.014, confidence: 0.9),
        line("Fat 2.5g (3% DV), Sat. Fat 2.5g (13% DV), Trans", x: 0.33, y: 0.525, width: 0.38, height: 0.01, confidence: 0.85),
    ]

    /// A sparkling water can's front, its name read whole or with the dropped "l" seen on the device.
    static func sparklingFront(_ name: String = "SPARKLING WATER") -> [RecognizedTextLine] {
        [
            line(name, x: 0.3, y: 0.35, width: 0.4, height: 0.06, confidence: 0.9),
            line("LIME", x: 0.42, y: 0.43, width: 0.15, height: 0.03, confidence: 0.95),
            line("0 CALORIES", x: 0.38, y: 0.6, width: 0.2, height: 0.015, confidence: 0.9),
            line("12 FL OZ (355 mL)", x: 0.36, y: 0.75, width: 0.25, height: 0.012, confidence: 0.88),
        ]
    }

    /// The can's nutrition side, close up, so the panel's print is taller than the front's name, with
    /// two panel words misread.
    static let sparklingSide: [RecognizedTextLine] = [
        line("Nutritlon Facts", x: 0.2, y: 0.2, width: 0.6, height: 0.07, confidence: 0.8),
        line("Serving size 1 can (355mL)", x: 0.2, y: 0.3, width: 0.6, height: 0.03, confidence: 0.85),
        line("Calorles 0", x: 0.2, y: 0.36, width: 0.5, height: 0.065, confidence: 0.82),
        line("Total Fat 0g 0%", x: 0.2, y: 0.45, width: 0.5, height: 0.025, confidence: 0.9),
        line("Sodium 0mg 0%", x: 0.2, y: 0.49, width: 0.5, height: 0.025, confidence: 0.9),
        line("INGREDIENTS: CARBONATED WATER, NATURAL LIME FLAVOR", x: 0.2, y: 0.6, width: 0.6, height: 0.02, confidence: 0.88),
    ]

    /// Two fronts of different products that look alike: the same brand and layout, a near-identical
    /// image, taken one right after the other.
    static let lookAlikes: [(String, [RecognizedTextLine], [RecognizedTextLine])] = [
        ("baking soda and baking powder", Fixture.front("Baking soda", brand: "Arm Hammer"), Fixture.front("Baking powder", brand: "Arm Hammer")),
        ("2% and 1% milk", Fixture.front("2% Reduced fat milk", brand: "Horizon Organic"), Fixture.front("1% Low fat milk", brand: "Horizon Organic")),
        ("whole and skim milk", Fixture.front("Whole milk", brand: "Horizon Organic"), Fixture.front("Skim milk", brand: "Horizon Organic")),
        ("coffee and toffee ice cream", Fixture.front("Coffee crunch", brand: "Talenti"), Fixture.front("Toffee crunch", brand: "Talenti")),
        ("Loacker vanilla and chocolate", loackerFront("VANILLA", logo: "Loacker"), loackerFront("CHOCOLATE", logo: "Loacker")),
        ("Loacker vanilla, misread, and chocolate", loackerFront("VANILLA"), loackerFront("CHOCOLATE", logo: "Loacker")),
    ]
}

private let fridge = StorageLocation(name: "Fridge", storageType: .refrigerated)

private func review(_ photos: [PhotoObservation]) -> IntakeReview {
    IntakeReview(
        space: SpaceID(), observations: photos, grouping: PhotoGrouper().group(photos),
        places: PlaceContext(locations: [fridge]), looksUp: true
    )
}

@Suite("First device test")
struct DeviceFindingsTests {
    let grouper = PhotoGrouper()

    // MARK: Loacker front and back

    private var loacker: [PhotoObservation] {
        [
            Fixture.photo(0, seconds: 0, lines: DeviceFixture.loackerFront(), print: Fixture.print(9)),
            Fixture.photo(1, seconds: 8, lines: DeviceFixture.loackerBack, codes: [.product(DeviceFixture.loacker)], print: Fixture.print(10)),
        ]
    }

    @Test("the Loacker front and back taken one after the other are one candidate, named by the lookup, with the printed date")
    func loackerFrontThenBack() throws {
        let photos = loacker
        #expect(grouper.group(photos).sequences(photos) == [[0, 1]])

        var review = review(photos)
        let waiting = try #require(review.summaries.first)
        #expect(waiting.name == "Toacker Minis")
        #expect(waiting.nameOrigin == .label)
        review.record(.found(rawName: "LOACKER CRISPY WAFERS WITH VANILLA CREAM FILLING, VANILLA", source: "USDA FoodData Central"), for: DeviceFixture.loacker)
        let candidate = try #require(review.summaries.first)
        #expect(review.summaries.count == 1)
        #expect(candidate.name == "Loacker crispy wafers with vanilla cream filling, vanilla")
        #expect(candidate.date == PrintedDate.onDay(.bestBy, year: 2027, month: 11, day: 30))
        #expect(candidate.dateOrigin == .label)
        #expect(review.drafts(for: [candidate.id]).isEmpty)

        review.assignLocation(fridge.id, to: [candidate.id])
        let draft = try #require(review.drafts(for: [candidate.id]).first)
        #expect(draft.printedDate.value == PrintedDate.onDay(.bestBy, year: 2027, month: 11, day: 30))
        #expect(draft.printedDate.source == .recognized)
        #expect(draft.confirmedFields.isEmpty)
    }

    @Test("the Loacker back taken first is suggested with the front, and merging keeps the lookup's name")
    func loackerBackThenFront() throws {
        let photos = [
            Fixture.photo(0, seconds: 0, lines: DeviceFixture.loackerBack, codes: [.product(DeviceFixture.loacker)]),
            Fixture.photo(1, seconds: 7, lines: DeviceFixture.loackerFront()),
        ]
        var review = review(photos)
        try #require(review.summaries.count == 2)
        #expect(review.summaries[0].notes.contains(.mightBeSameAs([review.summaries[1].id])))
        review.record(.found(rawName: "LOACKER CRISPY WAFERS", source: "USDA FoodData Central"), for: DeviceFixture.loacker)
        let merged = try review.merge(review.summaries.map(\.id))
        #expect(review.summary(of: merged)?.name == "Loacker crispy wafers")
    }

    @Test("the misread logo matches the maker's name on the back one letter off")
    func loackerMisreadMatches() {
        let photos = [
            Fixture.photo(0, seconds: 0, lines: DeviceFixture.loackerFront()),
            Fixture.photo(1, seconds: 600, lines: DeviceFixture.loackerBack, codes: [.product(DeviceFixture.loacker)]),
        ]
        let evidence = grouper.evidence(between: photos[0], and: photos[1])
        #expect(evidence?.signals.contains(.someLabelWords) == true)
        #expect(evidence?.signals.contains(.differentLabelWords) == false)
    }

    // MARK: Sparkling water

    @Test("the sparkling water front and its nutrition side are one candidate named from the front")
    func sparklingFrontThenSide() throws {
        let photos = [
            Fixture.photo(0, seconds: 0, lines: DeviceFixture.sparklingFront()),
            Fixture.photo(1, seconds: 5, lines: DeviceFixture.sparklingSide),
        ]
        #expect(grouper.group(photos).sequences(photos) == [[0, 1]])
        let candidate = try #require(review(photos).summaries.first)
        #expect(candidate.name == "Sparkling water")
    }

    @Test("merged by hand, the sparkling water is still named from the front, never from the nutrition side")
    func sparklingMergedByHand() throws {
        let photos = [
            Fixture.photo(0, seconds: 0, lines: DeviceFixture.sparklingSide),
            Fixture.photo(1, seconds: 400, lines: DeviceFixture.sparklingFront()),
        ]
        var review = review(photos)
        try #require(review.summaries.count == 2)
        #expect(review.summaries[0].name == nil)
        let merged = try review.merge(review.summaries.map(\.id))
        #expect(review.summary(of: merged)?.name == "Sparkling water")
    }

    @Test("two fronts of the can, one read Sparking, stay apart but are suggested as one")
    func sparklingTwoFronts() {
        let photos = [
            Fixture.photo(0, seconds: 0, lines: DeviceFixture.sparklingFront(), print: Fixture.print(11)),
            Fixture.photo(1, seconds: 4, lines: DeviceFixture.sparklingFront("SPARKING WATER"), print: Fixture.print(11, offset: 0.1)),
        ]
        let result = grouper.group(photos)
        #expect(result.groups.count == 2)
        #expect(result.suggestions.count == 1)
    }

    // MARK: Look-alike products

    @Test("look-alike products taken one after the other with near-identical images stay two candidates",
          arguments: DeviceFixture.lookAlikes.indices)
    func lookAlikesStayApart(index: Int) {
        let (_, first, second) = DeviceFixture.lookAlikes[index]
        let photos = [
            Fixture.photo(0, lines: first, print: Fixture.print(12)),
            Fixture.photo(1, lines: second, print: Fixture.print(12, offset: 0.1)),
        ]
        #expect(grouper.group(photos).groups.count == 2)
    }

    @Test("a look-alike's back with its barcode, taken right after the other product's front, does not join it",
          arguments: DeviceFixture.lookAlikes.indices)
    func lookAlikeBackStaysApart(index: Int) {
        let (_, first, second) = DeviceFixture.lookAlikes[index]
        // The back repeats its product's name in small print above a nutrition panel.
        let back = second.map { Fixture.line($0.text, row: 0.05 + $0.box.y / 3, size: $0.box.height / 3) } + Fixture.back([])
        let photos = [Fixture.photo(0, lines: first), Fixture.photo(1, lines: back, codes: [.product(Fixture.beans)])]
        #expect(grouper.group(photos).groups.count == 2)
    }

    // MARK: The whole batch in any order

    static var batch: [PhotoObservation] {
        var photos: [PhotoObservation] = [
            Fixture.photo(0, seconds: 0, lines: DeviceFixture.loackerFront()),
            Fixture.photo(1, seconds: 8, lines: DeviceFixture.loackerBack, codes: [.product(DeviceFixture.loacker)]),
            Fixture.photo(2, seconds: 60, lines: DeviceFixture.sparklingFront()),
            Fixture.photo(3, seconds: 66, lines: DeviceFixture.sparklingSide),
            Fixture.photo(4, seconds: 70, lines: DeviceFixture.sparklingFront("SPARKING WATER")),
        ]
        for (index, pair) in DeviceFixture.lookAlikes.enumerated() {
            let seconds = 200 + Double(index) * 100
            photos.append(Fixture.photo(photos.count, seconds: seconds, lines: pair.1, print: Fixture.print(index)))
            photos.append(Fixture.photo(photos.count, seconds: seconds + 4, lines: pair.2, print: Fixture.print(index, offset: 0.1)))
        }
        return photos
    }

    @Test("the device batch groups the same after every arrival order, and look-alikes never share a group")
    func anyArrivalOrder() {
        let batch = Self.batch
        let oneShot = grouper.group(batch)
        let groups = oneShot.sequences(batch)
        #expect(groups.contains([0, 1]))
        #expect(groups.contains([2, 3]))
        var generator = SeededGenerator(seed: 1_107)
        for _ in 0..<100 {
            var live = LiveGrouping(grouper: grouper)
            for observation in batch.shuffled(using: &generator) {
                live.add(observation)
                let bySequence = Dictionary(uniqueKeysWithValues: live.observations.values.map { ($0.photo, $0.sequence) })
                for group in live.result.groups {
                    let sequences = Set(group.photos.compactMap { bySequence[$0] })
                    for first in stride(from: 5, to: batch.count, by: 2) {
                        #expect(!(sequences.contains(first) && sequences.contains(first + 1)))
                    }
                }
            }
            #expect(live.result == oneShot)
        }
    }
}
