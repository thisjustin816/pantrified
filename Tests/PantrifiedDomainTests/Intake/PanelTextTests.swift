import Foundation
import Testing
@testable import PantrifiedDomain

private let fridge = StorageLocation(name: "Fridge", storageType: .refrigerated)

private func review(_ photos: [PhotoObservation], grouping: GroupingResult? = nil) -> IntakeReview {
    IntakeReview(
        space: SpaceID(), observations: photos, grouping: grouping ?? PhotoGrouper().group(photos),
        places: PlaceContext(locations: [fridge]), looksUp: true
    )
}

/// Each photo its own candidate, so a test can merge them by hand.
private func apart(_ photos: [PhotoObservation]) -> GroupingResult {
    GroupingResult(groups: photos.map { PhotoGroup(photos: [$0.photo], links: [], barcode: $0.products.first, sharedPhotos: []) }, suggestions: [])
}

@Suite("Panel text")
struct PanelTextTests {
    @Test("panel and allergen lines are found, also with a letter misread", arguments: [
        "Nutrition Facts", "NUTRITION FACTS", "Nutritlon Facts", "Nutrition Fact5", "Supplement Facts",
        "Serv. size: 1 piece (10g),", "Serving size 1 can (355mL)", "Servlng size 1 can", "Servings per container about 8",
        "Amount per serving: Calories 50, Total", "Amount per servinq", "Calories 0", "Calorles 50",
        "Fat 2.5g (3% DV), Sat. Fat 2.5g (13% DV), Trans", "Total Carbohydrate 0g 0%", "Sodium 10mg", "% Daily Value*",
        "INGREDIENTS: CARBONATED WATER, NATURAL FLAVOR", "lngredients: wheat flour, sugar", "Ingredlents: water",
        "Contains: milk, soy, hazelnuts", "May contain peanuts", "Allergen information", "sugar, wheat flour, coconut oil, whey",
    ])
    func panelLines(text: String) {
        #expect(LabelText.isPanelLine(text))
    }

    @Test("names, flavors, amounts that tell products apart and front claims are not panel lines", arguments: [
        "Sparkling water", "Sparking water", "Toacker", "Loacker", "Minis", "VANILLA", "CRISPY WAFERS WITH VANILLA CREAM FILLING",
        "2% Reduced fat milk", "1% Low fat milk", "Whole milk", "Baking soda", "Greek yogurt", "NET WT. 0.35OZ (10g)",
        "Serving suggestion", "Contains 12 - 12 fl oz cans", "Protein bar", "Fat free", "BEST IF USED BY: BB 11.2027",
        "Loacker crispy wafers with vanilla cream filling, vanilla", "Lemon lime",
    ])
    func notPanelLines(text: String) {
        #expect(!LabelText.isPanelLine(text))
    }

    @Test("a photo shows a panel by its heading, serving line or ingredients, and not by a front's nutrient claims")
    func photoShowsPanel() {
        #expect(LabelText.showsPanel(Fixture.back([])))
        #expect(LabelText.showsPanel([Fixture.line("Serv. size: 1 piece (10g),"), Fixture.line("Calories 50", row: 0.2)]))
        #expect(!LabelText.showsPanel(Fixture.front("Sparkling water", brand: "Polar", small: ["0 CALORIES", "0g Sugar", "Lime"])))
        #expect(!LabelText.showsPanel(Fixture.front("Greek yogurt", brand: "Chobani")))
    }

    @Test("panel lines give no words to compare and no name, even when they are the biggest text")
    func panelWordsLeftOut() {
        let panel = Fixture.photo(0, lines: [
            Fixture.line("Nutritlon Facts", row: 0.1, size: 0.12),
            Fixture.line("Serv. size: 1 piece (10g),", row: 0.3, size: 0.1),
            Fixture.line("Calorles 50", row: 0.45, size: 0.1),
        ])
        #expect(LabelText.significantTokens(of: panel).isEmpty)
        #expect(LabelText.prominentName(in: panel.lines) == nil)
        #expect(LabelText.nameTokens(of: panel).isEmpty)
    }

    @Test("two different products' panels taken one after the other are not suggested as one by their panel words")
    func panelsDoNotSuggest() {
        func panel(_ sequence: Int) -> PhotoObservation {
            Fixture.photo(sequence, lines: [
                Fixture.line("Serv. size: 1 piece (10g),", row: 0.1, size: 0.04),
                Fixture.line("Amount per serving: Calories 50, Total", row: 0.2, size: 0.03),
                Fixture.line("Ingredlents: wheat flour, sugar, palm oil, cocoa", row: 0.3, size: 0.02),
            ])
        }
        let photos = [panel(0), panel(1)]
        #expect(PhotoGrouper().group(photos).suggestions.isEmpty)
        #expect(PhotoGrouper().group(photos).groups.count == 2)
    }

    @Test("a panel photo with a date is not taken for a photo of only a date")
    func panelWithDateIsNotDateOnly() {
        let front = Fixture.photo(0, lines: Fixture.front("Sparkling water", brand: "Polar"))
        let panel = Fixture.photo(1, lines: [Fixture.line("Nutrition Facts"), Fixture.line("Calories 0", row: 0.2), Fixture.line("BEST BY 11.2027", row: 0.4)])
        let signals = PhotoGrouper().evidence(between: front, and: panel)?.signals ?? []
        #expect(!signals.contains(.datePhotoAfter))
    }

    @Test("panel detection stays bounded on very long and hostile text")
    func hostile() {
        let long = String(repeating: "nutrition facts calories 50g, ", count: 40_000)
        let started = Date()
        #expect(LabelText.isPanelLine(long))
        #expect(!LabelText.isPanelLine(String(repeating: "\u{202E}x\u{0301}", count: 100_000)))
        #expect(!LabelText.isPanelLine(String(repeating: "a", count: 1_000_000)))
        #expect(!LabelText.isPanelLine(""))
        // Only a recognized line's length is read.
        #expect(!LabelText.isPanelLine(String(repeating: "x ", count: IntakeLimits.charactersPerLine / 2) + "Nutrition Facts"))
        #expect(Date().timeIntervalSince(started) < 10)
    }

    // MARK: Names

    @Test("a merged candidate takes its name from the front, never from the panel photo's bigger text")
    func mergeKeepsFrontName() throws {
        let photos = [
            Fixture.photo(0, lines: Fixture.front("Sparkling water", brand: "Polar")),
            Fixture.photo(1, seconds: 900, lines: [
                Fixture.line("Nutritlon Facts", row: 0.1, size: 0.15),
                Fixture.line("Calorles 0", row: 0.3, size: 0.14),
                Fixture.line("INGREDIENTS: CARBONATED WATER, NATURAL LIME FLAVOR", row: 0.5, size: 0.05),
                Fixture.line("Polar seltzer", row: 0.7, size: 0.12),
            ]),
        ]
        var review = review(photos, grouping: apart(photos))
        #expect(review.summaries[1].name == "Polar seltzer")
        let merged = try review.merge(review.summaries.reversed().map(\.id))
        #expect(review.summary(of: merged)?.name == "Polar Sparkling water")
        #expect(review.summary(of: merged)?.nameOrigin == .label)
    }

    @Test("a candidate of only a panel photo has no name rather than a panel line")
    func panelOnlyHasNoName() throws {
        let photos = [Fixture.photo(0, lines: [
            Fixture.line("Nutritlon Facts", size: 0.15),
            Fixture.line("Serving size 1 can (355mL)", row: 0.3, size: 0.06),
            Fixture.line("Calories 0", row: 0.4, size: 0.1),
        ])]
        let summary = try #require(review(photos).summaries.first)
        #expect(summary.name == nil)
        #expect(summary.notes.contains(.noName))
    }

    @Test("a barcode lookup's name wins over any name read from the photos")
    func lookupWins() throws {
        let photos = [
            Fixture.photo(0, lines: Fixture.front("Toacker Minis")),
            Fixture.photo(1, lines: Fixture.back(["Loacker"]), codes: [.product(Fixture.beans)]),
        ]
        var review = review(photos, grouping: apart(photos))
        review.record(.found(rawName: "LOACKER CRISPY WAFERS", source: "USDA FoodData Central"), for: Fixture.beans)
        let merged = try review.merge(review.summaries.map(\.id))
        #expect(review.summary(of: merged)?.name == "Loacker crispy wafers")
        #expect(review.summary(of: merged)?.nameOrigin == .lookup(source: "USDA FoodData Central"))
    }
}
