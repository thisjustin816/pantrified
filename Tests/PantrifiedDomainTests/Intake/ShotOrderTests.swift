import Foundation
import Testing
import PantrifiedDomain

/// A back with nothing in common with any front: a barcode, a date or a panel. With a date it also
/// says where it was made, so it is not a photo of only a date.
private func plainBack(_ sequence: Int, seconds: Double? = nil, barcode: GTIN? = nil, panel: Bool = true, date: Bool = false) -> PhotoObservation {
    var lines: [RecognizedTextLine] = []
    if panel { lines += [Fixture.line("Nutrition Facts", row: 0.5), Fixture.line("Calories 50", row: 0.55)] }
    if date { lines += [Fixture.line("BB 11.2027", row: 0.1), Fixture.line("Made in Italy", row: 0.2, size: 0.01)] }
    return Fixture.photo(sequence, seconds: seconds, lines: lines, codes: barcode.map { [.product($0)] } ?? [])
}

/// Ten products, each with a distinct two-word name, a barcode and a lookup name that repeats it.
private let products: [(name: String, brand: String, barcode: GTIN)] = [
    ("Rolled oats", "Quaker"), ("Black beans", "Goya"), ("Peanut butter", "Smucker"), ("Basmati rice", "Tilda"),
    ("Tomato ketchup", "Heinz"), ("Almond milk", "Silk"), ("Sweet peas", "Birdseye"), ("Penne pasta", "Barilla"),
    ("Greek yogurt", "Chobani"), ("Maple syrup", "Kirkland"),
].enumerated().map { index, product in (product.0, product.1, Fixture.gtin(String(format: "5012399%05d", index))) }

@Suite("The order of shots")
struct ShotOrderTests {
    let grouper = PhotoGrouper()

    @Test("a back with a barcode, a panel or a date, taken straight after a front, with nothing in common, stays apart with no suggestion", arguments: [
        (true, true, false), (false, true, false), (true, false, false), (false, false, true),
    ])
    func backAfterFront(barcode: Bool, panel: Bool, date: Bool) {
        let photos = [
            Fixture.photo(0, lines: Fixture.front("Minis", brand: "Toacker")),
            plainBack(1, barcode: barcode ? Fixture.beans : nil, panel: panel, date: date),
        ]
        let result = grouper.group(photos)
        #expect(result.sequences(photos) == [[0], [1]])
        #expect(result.suggestions.isEmpty)
        #expect(grouper.evidence(between: photos[0], and: photos[1]) == nil)
    }

    @Test("a back taken straight before a front, or a photo of only a date next to one, is not suggested")
    func backBeforeFront() {
        let photos = [plainBack(0, barcode: Fixture.beans), Fixture.photo(1, lines: Fixture.front("Minis", brand: "Toacker"))]
        #expect(grouper.group(photos).sequences(photos) == [[0], [1]])
        #expect(grouper.group(photos).suggestions.isEmpty)

        let front = Fixture.photo(0, lines: Fixture.front("Sour cream", brand: "Daisy"))
        let dateOnly = Fixture.photo(1, lines: [Fixture.line("BEST BY 12/05/26")])
        #expect(grouper.evidence(between: front, and: dateOnly) == nil)
    }

    @Test("ten products photographed one after another, front then back, each linked by its lookup name, make ten candidates and no suggestion")
    func tenProductsInTurn() {
        var photos: [PhotoObservation] = []
        for (index, product) in products.enumerated() {
            photos.append(Fixture.photo(index * 2, lines: Fixture.front(product.name, brand: product.brand)))
            photos.append(plainBack(index * 2 + 1, barcode: product.barcode))
        }
        let names = Dictionary(uniqueKeysWithValues: products.map { ($0.barcode, "\($0.brand) \($0.name)") })
        let result = grouper.group(photos, lookupNames: names)
        #expect(result.sequences(photos) == (0..<10).map { [$0 * 2, $0 * 2 + 1] })
        #expect(result.suggestions.isEmpty)

        // Without the answers nothing links a front to a back, and nothing is suggested either.
        let blind = grouper.group(photos)
        #expect(blind.groups.count == 20)
        #expect(blind.suggestions.isEmpty)
    }

    @Test("ten unrelated products, each front and back sharing a word, taken one after another, never join a neighbor")
    func tenProductsSharedWords() {
        var photos: [PhotoObservation] = []
        for (index, product) in products.enumerated() {
            photos.append(Fixture.photo(index * 2, lines: Fixture.front(product.name, brand: product.brand)))
            photos.append(Fixture.photo(index * 2 + 1, lines: [Fixture.line("Distributed by \(product.brand)", row: 0.02, size: 0.012)] + Fixture.back([]),
                                        codes: [.product(product.barcode)]))
        }
        let result = grouper.group(photos)
        for group in result.sequences(photos) {
            #expect(group.count == 1 || (group.count == 2 && group[0] / 2 == group[1] / 2))
        }
        // Each shares only its brand with its own back: neither a group nor a suggestion.
        #expect(result.groups.count == 20)
        #expect(result.suggestions.isEmpty)
    }

    @Test("taken one after the other adds its points only to a pair whose content already makes a suggestion")
    func orderOnlySupports() {
        // Three label words in common: a suggestion apart, a group taken in turn.
        let front = Fixture.photo(0, lines: Fixture.front("Greek yogurt", brand: "Chobani"))
        let next = Fixture.photo(1, lines: Fixture.back(["Chobani greek yogurt"]), codes: [.product(Fixture.yogurt)])
        let later = Fixture.photo(1, seconds: 600, lines: next.lines, codes: next.codes)
        #expect(grouper.evidence(between: front, and: next)?.signals == [.sharedLabelWords, .takenRightAfter])
        #expect(grouper.evidence(between: front, and: next)?.score == 65)
        #expect(grouper.group([front, next]).groups.count == 1)
        #expect(grouper.evidence(between: front, and: later)?.score == 50)
        #expect(grouper.group([front, later]).groups.count == 2)

        // Where the order only ranks pairs, the same front and back stay a suggestion.
        var tieBreakOnly = GroupingPolicy()
        tieBreakOnly.orderCountsTowardGroup = false
        let ranking = PhotoGrouper(policy: tieBreakOnly)
        #expect(ranking.evidence(between: front, and: next)?.score == 65)
        #expect(ranking.group([front, next]).groups.count == 2)
        #expect(ranking.group([front, next]).suggestions.count == 1)

        // A brand alone, taken in turn: no points for the order, and no suggestion.
        let brandOnly = Fixture.photo(1, lines: Fixture.back(["Chobani"]), codes: [.product(Fixture.yogurt)])
        #expect(grouper.evidence(between: front, and: brandOnly)?.signals == [.someLabelWords])
        #expect(grouper.evidence(between: front, and: brandOnly)?.score == 25)
    }

    @Test("the order of shots never joins photos whose names differ or whose barcodes differ")
    func separationsStillHold() {
        let differentName = [
            Fixture.photo(0, lines: Fixture.front("Baking soda", brand: "Arm Hammer")),
            Fixture.photo(1, lines: [Fixture.line("Arm Hammer baking powder", row: 0.02, size: 0.01)] + Fixture.back([]), codes: [.product(Fixture.beans)]),
        ]
        #expect(grouper.group(differentName).groups.count == 2)

        let differentBarcode = [
            Fixture.photo(0, lines: Fixture.front("Minis", brand: "Toacker")),
            plainBack(1, barcode: Fixture.beans),
            plainBack(2, barcode: Fixture.soup),
            Fixture.photo(3, lines: Fixture.front("Minis", brand: "Toacker")),
        ]
        let byID = Dictionary(uniqueKeysWithValues: differentBarcode.map { ($0.photo, $0) })
        for group in grouper.group(differentBarcode).groups {
            #expect(Set(group.photos.compactMap { byID[$0] }.flatMap(\.products)).count <= 1)
        }
    }

    // MARK: All fronts first, then all backs

    @Test("fronts first and backs after: with lookup answers each back joins its own front, whatever was taken next to it")
    func frontsThenBacksWithAnswers() {
        let chosen = Array(products.prefix(4))
        var photos = chosen.enumerated().map { Fixture.photo($0, lines: Fixture.front($1.name, brand: $1.brand)) }
        photos += chosen.enumerated().map { plainBack(chosen.count + $0, barcode: $1.barcode) }
        let names = Dictionary(uniqueKeysWithValues: chosen.map { ($0.barcode, "\($0.brand) \($0.name)") })
        #expect(grouper.group(photos, lookupNames: names).sequences(photos) == [[0, 4], [1, 5], [2, 6], [3, 7]])
        #expect(grouper.group(photos, lookupNames: names).suggestions.isEmpty)
    }

    @Test("fronts first and backs that repeat their name in small print: each back is suggested with its own front, and the last front keeps apart from the first back")
    func frontsThenBacks() {
        let names = [("Rolled oats", "Quaker"), ("Black beans", "Goya Foods"), ("Peanut butter", "Jif")]
        let barcodes = [Fixture.yogurt, Fixture.beans, Fixture.soup]
        var photos = names.enumerated().map { Fixture.photo($0, lines: Fixture.front($1.0, brand: $1.1)) }
        photos += names.enumerated().map { index, name in
            Fixture.photo(3 + index, lines: [Fixture.line("\(name.1) \(name.0)", row: 0.02, size: 0.01)] + Fixture.back([]), codes: [.product(barcodes[index])])
        }
        let result = grouper.group(photos)
        #expect(!result.sequences(photos).contains { $0.contains(2) && $0.contains(3) })
        #expect(result.groups.count == 6)
        #expect(result.suggestions.count == 3)
    }

    @Test("fronts first and backs with nothing in common and no answers: every photo stays its own candidate, with no suggestion")
    func frontsThenBlankBacks() {
        var photos = ["Rolled oats", "Black beans", "Peanut butter"].enumerated().map { Fixture.photo($0, lines: Fixture.front($1)) }
        photos += [Fixture.yogurt, Fixture.beans, Fixture.soup].enumerated().map { plainBack(3 + $0, barcode: $1) }
        #expect(grouper.group(photos).sequences(photos) == [[0], [1], [2], [3], [4], [5]])
        #expect(grouper.group(photos).suggestions.isEmpty)
    }
}
