import Foundation
import Testing
import PantrifiedDomain

/// A back with nothing in common with any front: a barcode, a date or a panel. With a date it also
/// says where it was made, so it is not a photo of only a date.
private func plainBack(_ sequence: Int, seconds: Double? = nil, barcode: GTIN? = nil, panel: Bool = true, date: Bool = false) -> PhotoObservation {
    var lines: [RecognizedTextLine] = []
    if panel { lines += [Fixture.line("Nutrition Facts", row: 0.5), Fixture.line("Calories 50", row: 0.55)] }
    if date { lines += [Fixture.line("BB 11.2027", row: 0.1), Fixture.line("Made in Italy", row: 0.2)] }
    return Fixture.photo(sequence, seconds: seconds, lines: lines, codes: barcode.map { [.product($0)] } ?? [])
}

@Suite("Fronts and backs by the order they were taken")
struct ShotOrderTests {
    let grouper = PhotoGrouper()

    @Test("a back with a barcode, a panel or a date, taken straight after a front, joins it with nothing in common", arguments: [
        (true, true, false), (false, true, false), (true, false, false), (false, false, true),
    ])
    func backAfterFront(barcode: Bool, panel: Bool, date: Bool) {
        let photos = [
            Fixture.photo(0, lines: Fixture.front("Minis", brand: "Toacker")),
            plainBack(1, barcode: barcode ? Fixture.beans : nil, panel: panel, date: date),
        ]
        let result = grouper.group(photos)
        #expect(result.sequences(photos) == [[0, 1]])
        #expect(result.groups.first?.links.first?.signals == [.takenRightAfter])
        #expect(grouper.evidence(between: photos[0], and: photos[1])?.score == 60)
    }

    @Test("a back taken straight before a front is only a suggestion")
    func backBeforeFront() {
        let photos = [plainBack(0, barcode: Fixture.beans), Fixture.photo(1, lines: Fixture.front("Minis", brand: "Toacker"))]
        let result = grouper.group(photos)
        #expect(result.sequences(photos) == [[0], [1]])
        #expect(result.suggestions.count == 1)
    }

    @Test("a photo of only a date keeps its own rule, and a photo with no name is not taken for a front")
    func notFronts() {
        let front = Fixture.photo(0, lines: Fixture.front("Sour cream", brand: "Daisy"))
        let dateOnly = Fixture.photo(1, lines: [Fixture.line("BEST BY 12/05/26")])
        #expect(grouper.evidence(between: front, and: dateOnly)?.score == 60)

        let blank = [Fixture.photo(0), plainBack(1, barcode: Fixture.beans)]
        #expect(grouper.group(blank).groups.count == 2)
    }

    @Test("a back taken long after the front, two backs, or two fronts, with nothing in common, stay apart")
    func noOrderEvidence() {
        let late = [Fixture.photo(0, lines: Fixture.front("Minis", brand: "Toacker")), plainBack(1, seconds: 60, barcode: Fixture.beans)]
        #expect(grouper.group(late).groups.count == 2)
        #expect(grouper.group(late).suggestions.isEmpty)

        let backs = [plainBack(0, barcode: Fixture.beans), plainBack(1, panel: true, date: true)]
        #expect(grouper.group(backs).groups.count == 2)
        #expect(grouper.group(backs).suggestions.isEmpty)
    }

    @Test("a back that shares words with the front after it joins that front, not the lone front before it")
    func backBelongsToNextFront() {
        let photos = [
            Fixture.photo(0, lines: Fixture.front("Rolled oats", brand: "Quaker")),
            Fixture.photo(1, lines: [Fixture.line("Goya Foods black beans", row: 0.05)] + Fixture.back([]), codes: [.product(Fixture.beans)]),
            Fixture.photo(2, lines: Fixture.front("Black beans", brand: "Goya Foods")),
        ]
        #expect(grouper.group(photos).sequences(photos) == [[0], [1, 2]])
    }

    @Test("a brand alone shared with another front does not take a back away from the front taken right before it")
    func brandAloneDoesNotCompete() {
        let photos = [
            Fixture.photo(0, lines: Fixture.front("Minis", brand: "Toacker")),
            Fixture.photo(1, lines: [Fixture.line("I: A. LOACKER SPA, 39054 AUNA DI SOTTO (BZ), ITALY. PRODUCT OF ITALY.", row: 0.1, size: 0.01)] + Fixture.back([]), codes: [.product(Fixture.beans)]),
            Fixture.photo(2, seconds: 300, lines: Fixture.front("Napolitaner wafers", brand: "Loacker")),
        ]
        #expect(grouper.group(photos).sequences(photos) == [[0, 1], [2]])
    }

    @Test("a front whose own back comes later does not take the other product's back taken right after it")
    func frontKeepsItsOwnBack() {
        let photos = [
            Fixture.photo(0, lines: Fixture.front("Creamy peanut butter", brand: "Jif")),
            plainBack(1, barcode: Fixture.beans),
            Fixture.photo(2, seconds: 30, lines: [Fixture.line("Jif creamy peanut butter", row: 0.05)] + Fixture.back([]), codes: [.product(Fixture.soup)]),
        ]
        let groups = grouper.group(photos).sequences(photos)
        #expect(!groups.contains { $0.contains(0) && $0.contains(1) })
    }

    @Test("the order bonus never joins photos whose names differ or whose barcodes differ")
    func separationsStillHold() {
        let differentName = [
            Fixture.photo(0, lines: Fixture.front("Baking soda", brand: "Arm Hammer")),
            Fixture.photo(1, lines: [Fixture.line("Arm Hammer baking powder", row: 0.05)] + Fixture.back([]), codes: [.product(Fixture.beans)]),
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

    @Test("fronts first and backs after: a back that shares words with its front is suggested with it, and the last front keeps apart from the first back")
    func frontsThenBacks() {
        let names = [("Rolled oats", "Quaker"), ("Black beans", "Goya Foods"), ("Peanut butter", "Jif")]
        let barcodes = [Fixture.yogurt, Fixture.beans, Fixture.soup]
        var photos = names.enumerated().map { Fixture.photo($0, lines: Fixture.front($1.0, brand: $1.1)) }
        photos += names.enumerated().map { index, name in
            Fixture.photo(3 + index, lines: [Fixture.line("\(name.1) \(name.0)", row: 0.05)] + Fixture.back([]), codes: [.product(barcodes[index])])
        }
        let result = grouper.group(photos)
        // The last front and the first back are taken one after the other, but the back's words
        // point to the first front.
        #expect(!result.sequences(photos).contains { $0.contains(2) && $0.contains(3) })
        #expect(result.groups.count == 6)
        #expect(result.suggestions.count == 3)
    }

    @Test("fronts first and backs with nothing in common: only the last front and the first back are put together")
    func frontsThenBlankBacks() {
        var photos = ["Rolled oats", "Black beans", "Peanut butter"].enumerated().map { Fixture.photo($0, lines: Fixture.front($1)) }
        photos += [Fixture.yogurt, Fixture.beans, Fixture.soup].enumerated().map { plainBack(3 + $0, barcode: $1) }
        #expect(grouper.group(photos).sequences(photos) == [[0], [1], [2, 3], [4], [5]])
    }
}
