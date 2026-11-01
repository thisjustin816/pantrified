import Foundation
import Testing
import PantrifiedDomain

@Suite("Photo grouping")
struct PhotoGroupingTests {
    let grouper = PhotoGrouper()

    // MARK: Barcodes

    @Test("the same product photographed twice, far apart in the batch, is one candidate")
    func sameProductTwice() {
        let photos = [
            Fixture.photo(0, lines: Fixture.back(["Chobani"]), codes: [.product(Fixture.yogurt)]),
            Fixture.photo(1, lines: Fixture.front("Black beans", brand: "Goya")),
            Fixture.photo(2, seconds: 600, lines: Fixture.back([]), codes: [.product(Fixture.yogurt)]),
        ]
        let result = grouper.group(photos)
        #expect(result.sequences(photos) == [[0, 2], [1]])
        #expect(result.groups.first?.barcode == Fixture.yogurt)
        #expect(result.groups.first?.links.first?.signals.contains(.sameBarcode) == true)
    }

    @Test("two similar products with different barcodes are never grouped or suggested, however alike")
    func similarProductsDifferentBarcodes() {
        let photos = [
            Fixture.photo(0, lines: Fixture.front("Greek yogurt vanilla", brand: "Chobani"), codes: [.product(Fixture.yogurt)], print: Fixture.print(1)),
            Fixture.photo(1, lines: Fixture.front("Greek yogurt vanilla", brand: "Chobani"), codes: [.product(Fixture.otherYogurt)], print: Fixture.print(1)),
        ]
        let result = grouper.group(photos)
        #expect(result.sequences(photos) == [[0], [1]])
        #expect(result.suggestions.isEmpty)
        #expect(grouper.evidence(between: photos[0], and: photos[1]) == nil)
    }

    @Test("a photo between two products with different barcodes cannot chain them together")
    func noChainAcrossBarcodes() {
        let photos = [
            Fixture.photo(0, lines: Fixture.front("Tomato soup condensed", brand: "Campbells"), codes: [.product(Fixture.soup)]),
            Fixture.photo(1, lines: Fixture.front("Tomato soup condensed", brand: "Campbells")),
            Fixture.photo(2, lines: Fixture.front("Tomato soup condensed", brand: "Campbells"), codes: [.product(Fixture.beans)]),
        ]
        let result = grouper.group(photos)
        #expect(result.groups.count == 2)
        #expect(Set(result.groups.compactMap(\.barcode)) == [Fixture.soup, Fixture.beans])
    }

    // MARK: Fronts and backs

    @Test("a front photo without a barcode joins the barcode photo taken next when their labels share its words")
    func frontThenBack() {
        let photos = [
            Fixture.photo(0, lines: Fixture.front("Greek yogurt", brand: "Chobani")),
            Fixture.photo(1, lines: Fixture.back(["Chobani greek yogurt", "Ingredients: cultured nonfat milk"]), codes: [.product(Fixture.yogurt)]),
        ]
        let result = grouper.group(photos)
        #expect(result.sequences(photos) == [[0, 1]])
        #expect(result.groups.first?.barcode == Fixture.yogurt)
        #expect(result.groups.first?.links.first?.signals.contains(.sharedLabelWords) == true)
    }

    @Test("a barcode photo that shares only one word with the front taken next is a suggestion, not a merge")
    func doubtfulFront() {
        let photos = [
            Fixture.photo(0, lines: Fixture.back(["Distributed by Chobani"]), codes: [.product(Fixture.yogurt)]),
            Fixture.photo(1, lines: Fixture.front("Greek yogurt", brand: "Chobani")),
        ]
        let result = grouper.group(photos)
        #expect(result.sequences(photos) == [[0], [1]])
        #expect(result.suggestions.count == 1)
        #expect(result.suggestions.first?.signals.contains(.someLabelWords) == true)
        #expect(result.suggestions.first?.signals.contains(.takenRightAfter) == true)
    }

    @Test("a similar image adds enough to a weak text match to group the photos")
    func imageHelps() {
        let photos = [
            Fixture.photo(0, lines: Fixture.front("Greek yogurt", brand: "Chobani"), print: Fixture.print(2)),
            Fixture.photo(1, lines: Fixture.back(["Distributed by Chobani"]), codes: [.product(Fixture.yogurt)], print: Fixture.print(2, offset: 0.4)),
        ]
        #expect(grouper.group(photos).sequences(photos) == [[0, 1]])
    }

    @Test("photos taken right after each other with nothing else in common stay apart")
    func timeAloneIsNotEnough() {
        let photos = [
            Fixture.photo(0, lines: Fixture.front("Rolled oats", brand: "Quaker")),
            Fixture.photo(1, lines: Fixture.front("Peanut butter", brand: "Jif")),
        ]
        let result = grouper.group(photos)
        #expect(result.sequences(photos) == [[0], [1]])
        #expect(result.suggestions.isEmpty)
    }

    // MARK: Near-identical products

    @Test("products whose names differ by a distinguishing word stay two candidates", arguments: [
        ("Baking soda", "Baking powder"),
        ("Whole milk", "Skim milk"),
        ("Greek yogurt vanilla", "Greek yogurt strawberry"),
        ("Chicken noodle soup", "Chicken rice soup"),
    ])
    func distinguishingWords(first: String, second: String) {
        let photos = [
            Fixture.photo(0, lines: Fixture.front(first, brand: "Kirkland"), print: Fixture.print(3)),
            Fixture.photo(1, lines: Fixture.front(second, brand: "Kirkland"), print: Fixture.print(3, offset: 0.1)),
        ]
        let result = grouper.group(photos)
        #expect(result.groups.count == 2)
        // Alike enough to be worth a look, so the person sees them side by side.
        #expect(result.suggestions.first?.signals.contains(.differentLabelWords) == true)
    }

    @Test("a flavor printed small right under the name tells two fronts of one brand apart")
    func flavorUnderName() {
        func front(_ flavor: String) -> [RecognizedTextLine] {
            [
                Fixture.line("Loacker", row: 0.36, size: 0.04), Fixture.line("Minis", row: 0.43, size: 0.05),
                Fixture.line(flavor, row: 0.5, size: 0.016), Fixture.line("Crispy wafers with \(flavor) cream filling", row: 0.535, size: 0.012),
            ]
        }
        let flavors = [
            Fixture.photo(0, lines: front("VANILLA"), print: Fixture.print(7)),
            Fixture.photo(1, lines: front("CHOCOLATE"), print: Fixture.print(7, offset: 0.1)),
        ]
        #expect(grouper.group(flavors).groups.count == 2)
        let same = [
            Fixture.photo(0, lines: front("VANILLA"), print: Fixture.print(7)),
            Fixture.photo(1, lines: front("VANILLA"), print: Fixture.print(7, offset: 0.1)),
        ]
        #expect(grouper.group(same).groups.count == 1)
    }

    @Test("products that differ by a printed percentage or size stay two candidates", arguments: [
        (["2% Reduced fat milk"], ["1% Low fat milk"]),
        (["2% Milk"], ["1% Milk"]),
        (["Greek yogurt", "NET WT 16 OZ"], ["Greek yogurt", "NET WT 32 OZ"]),
    ])
    func distinguishingAmounts(first: [String], second: [String]) {
        func lines(_ texts: [String]) -> [RecognizedTextLine] {
            texts.enumerated().map { Fixture.line($1, row: 0.1 + Double($0) * 0.3, size: $0 == 0 ? 0.1 : 0.03) }
        }
        let photos = [
            Fixture.photo(0, lines: lines(first) + [Fixture.line("Horizon Organic", row: 0.02, size: 0.09)], print: Fixture.print(4)),
            Fixture.photo(1, lines: lines(second) + [Fixture.line("Horizon Organic", row: 0.02, size: 0.09)], print: Fixture.print(4, offset: 0.1)),
        ]
        #expect(grouper.group(photos).groups.count == 2)
    }

    @Test("a back panel between whole and skim milk cannot chain them together")
    func noChainAcrossDifferentWords() {
        let photos = [
            Fixture.photo(0, lines: Fixture.front("Whole milk", brand: "Organic Valley")),
            Fixture.photo(1, lines: Fixture.back(["Organic Valley whole skim milk", "Pasteurized"])),
            Fixture.photo(2, lines: Fixture.front("Skim milk", brand: "Organic Valley")),
        ]
        let result = grouper.group(photos)
        for group in result.sequences(photos) {
            #expect(!(group.contains(0) && group.contains(2)))
        }
    }

    @Test("a photo of the same label twice is still grouped: shared words are not differences")
    func sameLabelTwice() {
        let photos = [
            Fixture.photo(0, lines: Fixture.front("Baking soda", brand: "Arm and Hammer")),
            Fixture.photo(1, lines: Fixture.front("Baking soda", brand: "Arm and Hammer")),
        ]
        #expect(grouper.group(photos).groups.count == 1)
    }

    // MARK: Several products, no text, duplicates, dates

    @Test("a photo showing two products' barcodes joins each product's candidate")
    func severalProducts() {
        let shelf = Fixture.photo(2, lines: Fixture.front("Groceries"), codes: [.product(Fixture.beans), .product(Fixture.soup)])
        let photos = [
            Fixture.photo(0, lines: Fixture.back([]), codes: [.product(Fixture.beans)]),
            Fixture.photo(1, seconds: 300, lines: Fixture.front("Peanut butter")),
            shelf,
        ]
        let result = grouper.group(photos)
        #expect(result.groups.count == 3)
        let beans = result.groups.first { $0.barcode == Fixture.beans }
        let soup = result.groups.first { $0.barcode == Fixture.soup }
        #expect(beans?.photos.contains(shelf.photo) == true)
        #expect(soup?.photos == [shelf.photo])
        #expect(soup?.sharedPhotos == [shelf.photo])
        #expect(beans?.sharedPhotos == [shelf.photo])
    }

    @Test("a photo with no text at all is its own candidate")
    func noText() {
        let photos = [Fixture.photo(0, lines: Fixture.front("Bananas")), Fixture.photo(1)]
        let result = grouper.group(photos)
        #expect(result.sequences(photos) == [[0], [1]])
    }

    @Test("the same photo imported twice is grouped, marked as identical")
    func duplicates() {
        let photos = [
            Fixture.photo(0, seconds: 0, lines: Fixture.front("Rice"), digest: "aa11"),
            Fixture.photo(1, seconds: 5_000, lines: Fixture.front("Pasta")),
            Fixture.photo(2, seconds: 9_000, lines: Fixture.front("Rice"), digest: "aa11"),
        ]
        let result = grouper.group(photos)
        #expect(result.sequences(photos) == [[0, 2], [1]])
        #expect(result.groups.first?.links.first?.signals.contains(.identicalPhoto) == true)
    }

    @Test("a photo of only a date joins the photo before it, and is only suggested for the one after")
    func datePhotos() {
        let after = [
            Fixture.photo(0, lines: Fixture.front("Sour cream", brand: "Daisy")),
            Fixture.photo(1, lines: [Fixture.line("BEST BY 12/05/26")]),
        ]
        let joined = grouper.group(after)
        #expect(joined.sequences(after) == [[0, 1]])
        #expect(joined.groups.first?.links.first?.signals.contains(.datePhotoAfter) == true)

        let before = [
            Fixture.photo(0, lines: [Fixture.line("USE BY 2026-11-04")]),
            Fixture.photo(1, lines: Fixture.front("Chicken thighs")),
        ]
        let apart = grouper.group(before)
        #expect(apart.sequences(before) == [[0], [1]])
        #expect(apart.suggestions.first?.signals.contains(.datePhotoBefore) == true)
    }

    @Test("a brand on most photos in the batch does not group different products")
    func commonBrand() {
        let names = ["Rolled oats", "Peanut butter", "Almond milk", "Frozen peas", "Black beans", "Basmati rice"]
        // Printed small, so the names do not share it; taken quickly, so without the rule they would group.
        let photos = names.enumerated().map {
            Fixture.photo($0, seconds: Double($0) * 10, lines: Fixture.front($1, small: ["Kirkland Signature Premium"]))
        }
        #expect(grouper.group(photos).groups.count == names.count)
    }

    // MARK: Determinism and size

    @Test("the result is the same whatever order the observations arrive in")
    func orderIndependent() {
        var generator = SystemRandomNumberGenerator()
        let photos = (0..<12).map { index in
            Fixture.photo(index, lines: Fixture.front(index % 2 == 0 ? "Greek yogurt" : "Greek yogurt plain", brand: "Fage"),
                          codes: index % 3 == 0 ? [.product(Fixture.yogurt)] : [])
        }
        let expected = grouper.group(photos)
        for _ in 0..<5 {
            #expect(grouper.group(photos.shuffled(using: &generator)) == expected)
        }
    }

    @Test("a very large batch is cut to the limit and grouped in reasonable time")
    func largeBatch() {
        // 70 products, each a front and then a back with its barcode: 140 photos, over the limit.
        var photos: [PhotoObservation] = []
        for product in 0..<70 {
            let name = "Product\(Character(UnicodeScalar(65 + product % 26)!))\(String(repeating: "x", count: product / 26 + 3)) special"
            let barcode = Fixture.gtin(String(format: "5012345%05d", product))
            photos.append(Fixture.photo(product * 2, seconds: Double(product) * 60, lines: Fixture.front(name), print: Fixture.print(product)))
            photos.append(Fixture.photo(product * 2 + 1, seconds: Double(product) * 60 + 5, lines: Fixture.back([name]), codes: [.product(barcode)], print: Fixture.print(product, offset: 0.3)))
        }
        let started = Date()
        let result = grouper.group(photos)
        #expect(Date().timeIntervalSince(started) < 20)
        #expect(result.groups.flatMap(\.photos).count == IntakeLimits.photosPerBatch)
        #expect(result.groups.count == IntakeLimits.photosPerBatch / 2)
        #expect(result.groups.allSatisfy { $0.photos.count == 2 && $0.barcode != nil })
    }

    @Test("an observation repeated for one photo is counted once")
    func repeatedObservation() {
        let id = IntakePhotoID()
        let photos = [Fixture.photo(0, lines: Fixture.front("Rice"), id: id), Fixture.photo(0, lines: Fixture.front("Rice"), id: id)]
        #expect(grouper.group(photos).groups.map(\.photos) == [[id]])
    }
}
