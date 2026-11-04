import Foundation
import Testing
@testable import PantrifiedDomain

private let fridge = StorageLocation(name: "Fridge", storageType: .refrigerated)

private func review(_ photos: [PhotoObservation], grouping: GroupingResult) -> IntakeReview {
    IntakeReview(space: SpaceID(), observations: photos, grouping: grouping, places: PlaceContext(locations: [fridge]), looksUp: true)
}

@Suite("What a package shows")
struct PackageContentTests {
    let grouper = PhotoGrouper()

    // MARK: Makers and addresses

    @Test("maker, address, origin, contact, website and certification lines are found, also with a letter misread", arguments: [
        "Distributed by", "DISTRIBUTED BY: CHOBANI, LLC", "Distrlbuted by Chobani, Norwich NY", "Manufactured for Kroger Co.",
        "Mfd. by Ferrara Candy Company", "Ferrenu Candy Company", "Ferrara Candy Co., Chicago, IL 60607", "A. LOACKER S.p.A.",
        "Loacker Konfekt GmbH", "Made in Italy", "MADE IN USA", "Product of Austria", "Produced in Canada", "Questions? Call 1-800-328-7172",
        "Questlons or comments", "www.ferrarausa.com", "ferrarausa.com", "Norwich, NY 13815", "9919 HEINFELS, AUSTRIA",
        "123 Main Street", "NON GMO Project VERIFIED", "Imported by Trader Joe's", "Kraft Heinz Foods Compary",
    ])
    func makerLines(text: String) {
        #expect(LabelText.isMakerLine(text))
    }

    @Test("product names, flavors and claims are not maker lines", arguments: [
        "Butterfinger", "Toacker", "Minis", "VANILLA", "Sparkling water", "Greek yogurt", "Baking soda", "2% Reduced fat milk",
        "Made by Nature", "Packed in water", "Chunk light tuna in water", "1st place chili", "Rocky road", "Crispety, crunchety, peanut-buttery!",
        "NET WT 16 OZ", "Product number 4", "Black beans", "Quaker", "Rolled oats", "Lemon lime",
    ])
    func notMakerLines(text: String) {
        #expect(!LabelText.isMakerLine(text))
    }

    @Test("maker lines are never a name or a distinguishing word, and still give label words")
    func makerLinesNotNames() {
        let back = Fixture.photo(0, lines: [
            Fixture.line("Distributed by Chobani, Norwich NY", row: 0.05, size: 0.04),
            Fixture.line("Nutrition Facts", row: 0.2, size: 0.03),
        ], codes: [.product(Fixture.yogurt)])
        #expect(LabelText.prominentName(in: back.lines) == nil)
        #expect(LabelText.nameTokens(of: back).isEmpty)
        #expect(LabelText.significantTokens(of: back).contains("chobani"))

        // So a back naming the brand and its town does not count as a differently named product.
        let front = Fixture.photo(1, seconds: 600, lines: Fixture.front("Greek yogurt", brand: "Chobani"))
        #expect(grouper.evidence(between: back, and: front)?.signals == [.someLabelWords])
    }

    @Test("maker line detection stays bounded on very long and hostile text")
    func hostileMakerLines() {
        let started = Date()
        #expect(LabelText.isMakerLine(String(repeating: "distributed by company ", count: 40_000)))
        #expect(!LabelText.isMakerLine(String(repeating: "\u{202E}x\u{0301}", count: 100_000)))
        #expect(!LabelText.isMakerLine(String(repeating: "a", count: 1_000_000)))
        #expect(!LabelText.isMakerLine(String(repeating: "1", count: 1_000_000)))
        #expect(!LabelText.isMakerLine(""))
        // Only a recognized line's length is read.
        #expect(!LabelText.isMakerLine(String(repeating: "x ", count: IntakeLimits.charactersPerLine / 2) + "Distributed by Chobani"))
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test("a front's name wins over a name read from a photo with a barcode or date, however tall")
    func frontNameWins() throws {
        let photos = [
            Fixture.photo(0, lines: Fixture.front("Butterfinger")),
            Fixture.photo(1, seconds: 600, lines: [Fixture.line("Crunchy bar", row: 0.1, size: 0.2)], codes: [.product(Fixture.beans)]),
        ]
        var apart = review(photos, grouping: grouper.group(photos))
        try #require(apart.summaries.count == 2)
        let merged = try apart.merge(apart.summaries.reversed().map(\.id))
        #expect(apart.summary(of: merged)?.name == "Butterfinger")
    }

    // MARK: Ingredients

    @Test("a name found in an ingredients list is a suggestion only, even taken right after and looking alike")
    func ingredientsSuggestOnly() {
        let front = Fixture.photo(0, lines: Fixture.front("Sparkling water lime"), print: Fixture.print(3))
        let side = Fixture.photo(1, lines: [
            Fixture.line("Nutrition Facts", row: 0.1, size: 0.05),
            Fixture.line("INGREDIENTS: CARBONATED WATER, NATURAL LIME FLAVOR", row: 0.3, size: 0.03),
        ], print: Fixture.print(3, offset: 0.4))
        let evidence = grouper.evidence(between: front, and: side)
        #expect(evidence?.signals == [.similarImage, .nameInIngredients])
        #expect(grouper.group([front, side]).groups.count == 2)
        #expect(grouper.group([front, side]).suggestions.count == 1)
    }

    @Test("one name word in another product's ingredients is nothing")
    func oneIngredientWord() {
        let front = Fixture.photo(0, lines: Fixture.front("Peanut butter cups", brand: "Reeses"))
        let panel = Fixture.photo(1, lines: [
            Fixture.line("Nutrition Facts", row: 0.1, size: 0.05),
            Fixture.line("INGREDIENTS: CORN SYRUP, SUGAR, GROUND ROASTED PEANUTS, BUTTER", row: 0.3, size: 0.03),
        ])
        #expect(grouper.evidence(between: front, and: panel) == nil)
    }

    // MARK: The lookup bridge

    @Test("lookup words for a barcode never reach a photo with another barcode, and differing amounts in the name keep two milks apart")
    func lookupRefusals() {
        let front = Fixture.photo(0, lines: Fixture.front("1% Low fat milk", brand: "Horizon"))
        let back = Fixture.photo(1, lines: Fixture.back([]), codes: [.product(Fixture.beans)])
        let name = [Fixture.beans: "Horizon 1% low fat milk"]
        #expect(grouper.group([front, back], lookupNames: name).groups.count == 1)
        let twoPercent = [Fixture.beans: "Horizon 2% reduced fat milk"]
        let signals = grouper.evidence(between: front, and: back, lookupNames: twoPercent)?.signals ?? []
        #expect(signals.contains(.differentAmounts))
        #expect(grouper.group([front, back], lookupNames: twoPercent).groups.count == 2)

        let otherBarcode = Fixture.photo(0, lines: Fixture.front("1% Low fat milk", brand: "Horizon"), codes: [.product(Fixture.soup)])
        #expect(grouper.evidence(between: otherBarcode, and: back, lookupNames: name) == nil)
    }

    @Test("label words and lookup words count once: a brand on the back and in the lookup's name is still only a suggestion")
    func wordsCountOnce() {
        let photos = [
            Fixture.photo(0, lines: Fixture.front("Chobani")),
            Fixture.photo(1, lines: [Fixture.line("Distributed by Chobani", row: 0.02, size: 0.012)] + Fixture.back([]), codes: [.product(Fixture.yogurt)]),
        ]
        let names = [Fixture.yogurt: "Chobani greek yogurt"]
        #expect(grouper.evidence(between: photos[0], and: photos[1], lookupNames: names)?.score == 45)
        let result = grouper.group(photos, lookupNames: names)
        #expect(result.groups.count == 2)
        #expect(result.suggestions.count == 1)
    }

    @Test("lookup words are never label words: the lookup's name is not the photo's name")
    func lookupIsNotLabel() throws {
        let back = Fixture.photo(0, lines: Fixture.back([]), codes: [.product(Fixture.beans)])
        let front = Fixture.photo(1, seconds: 600, lines: Fixture.front("Black beans", brand: "Goya"))
        let result = grouper.group([back, front], lookupNames: [Fixture.beans: "Goya black beans"])
        let made = review([back, front], grouping: result)
        let candidate = try #require(made.summaries.first)
        #expect(made.summaries.count == 1)
        // With no answer kept in the review, the name is still read from the front's label.
        #expect(candidate.name == "Goya Black beans")
        #expect(candidate.nameOrigin == .label)
    }

    // MARK: Suggestions after the review

    @Test("photos a later grouping links are suggested both ways, never merged, kept by an undo, and not across two barcodes")
    func suggestAfterReview() throws {
        let photos = [
            Fixture.photo(0, lines: Fixture.front("Black beans", brand: "Goya")),
            Fixture.photo(1, seconds: 600, lines: Fixture.back([]), codes: [.product(Fixture.beans)]),
            Fixture.photo(2, seconds: 1_200, lines: Fixture.back([]), codes: [.product(Fixture.soup)]),
        ]
        let before = grouper.group(photos)
        let after = grouper.group(photos, lookupNames: [Fixture.beans: "Goya black beans"])
        let linked = after.photosLinked(beyond: before)
        #expect(linked.count == 1)
        #expect(after.photosLinked(beyond: after).isEmpty)

        var made = review(photos, grouping: before)
        let ids = made.summaries.map(\.id)
        try made.setCount(3, for: ids[2])
        let soupAndBeans = (photos[2].photo, photos[1].photo)
        let added = made.suggest(linkedPhotos: linked + [soupAndBeans])
        #expect(added == 1)
        #expect(made.summaries[0].notes.contains(.mightBeSameAs([ids[1]])))
        #expect(made.summaries[1].notes.contains(.mightBeSameAs([ids[0]])))
        #expect(!made.summaries[2].notes.contains { if case .mightBeSameAs = $0 { true } else { false } })
        #expect(made.summaries.count == 3)
        let again = made.suggest(linkedPhotos: linked)
        #expect(again == 0)
        let undone = made.undo()
        #expect(undone)
        #expect(made.summaries[0].notes.contains(.mightBeSameAs([ids[1]])))
    }
}
