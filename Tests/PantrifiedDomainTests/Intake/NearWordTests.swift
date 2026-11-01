import Foundation
import Testing
@testable import PantrifiedDomain

@Suite("Words one letter off")
struct NearWordTests {
    let grouper = PhotoGrouper()

    @Test("one letter added, dropped or changed is one letter off; two changes or a swap are not", arguments: [
        ("toacker", "loacker", true), ("sparking", "sparkling", true), ("sparkling", "sparking", true),
        ("crackers", "cracker", true), ("vanilla", "vanllla", true), ("coffee", "toffee", true),
        ("lemon", "melon", false), ("baking", "bakign", false), ("loacker", "loacker", false),
        ("loacker", "toackex", false), ("sparkling", "sparkin", false), ("", "a", true), ("", "", false),
    ])
    func oneEdit(a: String, b: String, expected: Bool) {
        #expect(LabelText.isOneEditApart(a, b) == expected)
    }

    @Test("the prepared keys find exactly the words one letter off, and leave out the batch's common words")
    func keys() {
        var near = NearWords()
        for word in ["loacker", "sparkling", "kirkland"] { near.add(word) }
        var lookups = 0
        for word in ["toacker", "loackers", "loacke", "sparking"] {
            #expect(near.hasNear(.init(word), ignoring: [], lookups: &lookups))
        }
        for word in ["loacker", "lacoker", "toackex", "sparklingly"] {
            #expect(!near.hasNear(.init(word), ignoring: [], lookups: &lookups))
        }
        #expect(!near.hasNear(.init("kirkiand"), ignoring: ["kirkland"], lookups: &lookups))
        #expect(near.hasNear(.init("kirkiand"), ignoring: [], lookups: &lookups))
    }

    @Test("a misread name word on a back photo is not a distinguishing word, and makes a suggestion")
    func misreadOnBack() {
        let photos = [
            Fixture.photo(0, lines: Fixture.front("Sparkling water", brand: "Polar")),
            Fixture.photo(1, seconds: 900, lines: [Fixture.line("Polar sparking water", row: 0.05, size: 0.04)] + Fixture.back([])),
        ]
        let result = grouper.group(photos)
        #expect(result.groups.count == 2)
        #expect(result.suggestions.count == 1)
        #expect(result.suggestions.first?.signals.contains(.differentLabelWords) == false)
    }

    @Test("a misread word and an extra word on either photo are not a difference between the two", arguments: [
        ("Sparkling water", "Polar sparking water lime"), ("Sparkling water lime", "Polar sparking water"),
    ])
    func misreadAndExtraWord(front: String, back: String) {
        let photos = [
            Fixture.photo(0, lines: Fixture.front(front, brand: "Polar")),
            Fixture.photo(1, seconds: 900, lines: [Fixture.line(back, row: 0.05, size: 0.04)] + Fixture.back([])),
        ]
        let signals = grouper.evidence(between: photos[0], and: photos[1])?.signals ?? []
        #expect(!signals.contains(.differentLabelWords))
    }

    @Test("a front's name one letter off a maker's address on the back does not make their names share a word")
    func addressIsNotAName() {
        let photos = [
            Fixture.photo(0, lines: Fixture.front("Minis vanilla", brand: "Toacker")),
            Fixture.photo(1, lines: [
                Fixture.line("Project verified", row: 0.05, size: 0.02),
                Fixture.line("I: A. LOACKER SPA, 39054 AUNA DI SOTTO (BZ), ITALY. PRODUCT OF ITALY.", row: 0.1, size: 0.008),
            ] + Fixture.back([]), codes: [.product(Fixture.beans)]),
        ]
        let signals = grouper.evidence(between: photos[0], and: photos[1])?.signals ?? []
        #expect(signals.contains(.someLabelWords))
        #expect(!signals.contains(.differentLabelWords))
    }

    @Test("words one letter off never reach a merge on their own points")
    func nearNeverMerges() {
        // Some words in common and a similar image: 50 points, then 20 for the word one letter off.
        let photos = [
            Fixture.photo(0, lines: Fixture.front("Toacker Minis", brand: "Wafers"), print: Fixture.print(5)),
            Fixture.photo(1, seconds: 900, lines: [Fixture.line("Loacker minis", row: 0.05, size: 0.04)] + Fixture.back([]),
                          codes: [.product(Fixture.beans)], print: Fixture.print(5, offset: 0.4)),
        ]
        let evidence = grouper.evidence(between: photos[0], and: photos[1])
        #expect(evidence?.score == 70)
        let result = grouper.group(photos)
        #expect(result.groups.count == 2)
        #expect(result.suggestions.count == 1)
    }

    @Test("short words one letter apart stay different words, even against a back photo", arguments: [
        ("Coffee crunch", "Toffee crunch"), ("Skim milk", "Skip milk"), ("Lemon tart", "Melon tart"),
    ])
    func shortWordsStayApart(front: String, back: String) {
        let photos = [
            Fixture.photo(0, lines: Fixture.front(front, brand: "Kirkland")),
            Fixture.photo(1, lines: [Fixture.line("Kirkland " + back, row: 0.05, size: 0.05)] + Fixture.back([]), codes: [.product(Fixture.beans)]),
        ]
        let signals = grouper.evidence(between: photos[0], and: photos[1])?.signals ?? []
        #expect(signals.contains(.differentLabelWords))
    }

    @Test("a word one letter off does not hide a real difference in flavor")
    func flavorsStayApart() {
        let photos = [
            Fixture.photo(0, lines: Fixture.front("Vanilla", brand: "Toacker")),
            Fixture.photo(1, lines: [Fixture.line("Loacker Chocolate", row: 0.05, size: 0.05)] + Fixture.back([]), codes: [.product(Fixture.beans)]),
        ]
        let signals = grouper.evidence(between: photos[0], and: photos[1])?.signals ?? []
        #expect(signals.contains(.differentLabelWords))
    }

    @Test("two fronts one letter apart in a long word stay apart as a suggestion, since they could be two products")
    func frontsCompareExactly() {
        let photos = [
            Fixture.photo(0, lines: Fixture.front("Mustard", brand: "Heinz"), print: Fixture.print(6)),
            Fixture.photo(1, lines: Fixture.front("Custard", brand: "Heinz"), print: Fixture.print(6, offset: 0.1)),
        ]
        let result = grouper.group(photos)
        #expect(result.groups.count == 2)
        #expect(result.suggestions.first?.signals.contains(.differentLabelWords) == true)
    }

    @Test("finding words one letter off stays within its bound on long, hostile text")
    func hostileBound() {
        var generator = SeededLetters(seed: 7)
        let photos = (0..<IntakeLimits.photosPerBatch).map { index in
            // A name of two lines, each as long as a name line may be, full of long words.
            let name = [0.02, 0.12].map { row in
                Fixture.line((0..<6).map { _ in generator.word(7) }.joined(separator: " "), row: row, size: 0.1 - row / 10)
            }
            let lines = name + (0..<148).map { row in
                Fixture.line((0..<7).map { _ in generator.word(grouper.policy.nearWordMaximumLetters) }.joined(separator: " "), row: 0.2 + Double(row) * 0.005, size: 0.004)
            }
            return Fixture.photo(index, lines: lines)
        }
        let (result, cost) = grouper.measuredGroup(photos)
        #expect(result.groups.count == photos.count)
        #expect(cost.nearWordLookups <= cost.pairsScored * grouper.nearLookupsPerPair)
        let prepared = grouper.prepare(photos[0])
        #expect(prepared.near.words.count <= grouper.policy.nearWordsPerPhoto)
        #expect(prepared.near.queries.count <= grouper.policy.nearWordsPerName)
    }
}

/// Deterministic lowercase words for hostile inputs.
private struct SeededLetters {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func word(_ length: Int) -> String {
        String((0..<length).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Character(UnicodeScalar(UInt8(97 + (state >> 33) % 26)))
        })
    }
}
