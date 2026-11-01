import Foundation
import Testing
import PantrifiedTestSupport
@testable import PantrifiedDomain

private func record(_ id: Int, _ name: String, qualifier: String? = nil, keywords: [String] = []) -> GuidanceRecord {
    GuidanceRecord(
        id: id, name: name, qualifier: qualifier, category: nil, keywords: keywords,
        windows: [GuidanceWindow(storageType: .refrigerated, anchor: .added, days: id)]
    )
}

private func matcher(_ records: [GuidanceRecord], links: [IngredientName: Int] = [:]) throws -> GuidanceMatcher {
    GuidanceMatcher(
        dataset: try GuidanceDataset(
            provenance: GuidanceDataset.Provenance(source: "test", sourceVersion: nil, sourceChecksum: nil, normalizationVersion: "1"),
            records: records
        ),
        confirmedLinks: links
    )
}

@Suite("Guidance matching")
struct GuidanceMatcherTests {
    @Test("an exact normalized name matches")
    func exactName() throws {
        let m = try matcher([record(1, "Chicken breast"), record(2, "Butter")])

        #expect(m.match(IngredientName("Boneless chicken breasts")) == .matched(record(1, "Chicken breast"), via: .name))
    }

    @Test("a keyword never matches by itself, it only suggests")
    func keywordNeverMatches() throws {
        let beef = record(1, "Ground beef", keywords: ["hamburger meat"])
        let m = try matcher([beef])

        #expect(m.match(IngredientName("Hamburger meat")) == .noMatch(candidates: [beef]))
    }

    @Test("a record's exact name beats another record's keyword")
    func nameBeatsKeyword() throws {
        let cheese = record(1, "Cheese", keywords: ["cheddar"])
        let cheddar = record(2, "Cheddar")
        let m = try matcher([cheese, cheddar])

        #expect(m.match(IngredientName("cheddar")) == .matched(cheddar, via: .name))
    }

    @Test("a name that two records share is ambiguous and is not guessed")
    func ambiguous() throws {
        let m = try matcher([record(1, "Milk"), record(2, "Milk"), record(3, "Cream")])

        guard case .ambiguous(let records) = m.match(IngredientName("milk")) else {
            Issue.record("expected an ambiguous match")
            return
        }
        #expect(records.map(\.id) == [1, 2])
    }

    @Test("a partial word overlap is only a candidate, never a match")
    func candidatesOnly() throws {
        let m = try matcher([record(1, "Butter"), record(2, "Peanut butter cookies")])

        guard case .noMatch(let candidates) = m.match(IngredientName("peanut butter")) else {
            Issue.record("expected no match")
            return
        }
        #expect(Set(candidates.map(\.id)) == [1, 2])
    }

    @Test("a food that shares no words has no match and no candidates")
    func noMatch() throws {
        let m = try matcher([record(1, "Butter")])

        #expect(m.match(IngredientName("saffron")) == .noMatch(candidates: []))
    }

    @Test("a confirmed link wins, including over an ambiguous name")
    func confirmedLink() throws {
        let links = [IngredientName("milk"): 2]
        let m = try matcher([record(1, "Milk"), record(2, "Milk")], links: links)

        #expect(m.match(IngredientName("milk")) == .matched(record(2, "Milk"), via: .confirmed))
    }

    @Test("a confirmed link can name a record the food's name would never reach")
    func confirmedLinkToOtherName() throws {
        let m = try matcher([record(7, "Yams or sweet potatoes")], links: [IngredientName("sweet potatoes"): 7])

        #expect(m.match(IngredientName("Sweet potatoes")) == .matched(record(7, "Yams or sweet potatoes"), via: .confirmed))
    }

    @Test("a confirmed link to a record that is not in the dataset is ignored")
    func staleLink() throws {
        let m = try matcher([record(1, "Butter")], links: [IngredientName("butter"): 99])

        #expect(m.match(IngredientName("butter")) == .matched(record(1, "Butter"), via: .name))
    }

    @Test("a blank query has no match")
    func blankQuery() throws {
        let m = try matcher([record(1, "Butter")])

        #expect(m.match(IngredientName(" ")) == .noMatch(candidates: []))
    }

    @Test("candidates whose name overlaps come before those that only list a keyword")
    func candidateOrder() throws {
        let byKeyword = record(1, "Margarine", keywords: ["peanut butter"])
        let byName = record(9, "Butter")
        let m = try matcher([byKeyword, byName])

        #expect(m.match(IngredientName("peanut butter")) == .noMatch(candidates: [byName, byKeyword]))
    }

    @Test("suggestions are limited and, when equally close, ordered by identifier")
    func candidateLimit() throws {
        let many = (1...15).map { record($0, "Cream \($0)", keywords: []) }
        let m = try matcher(many)

        guard case .noMatch(let candidates) = m.match(IngredientName("cream")) else {
            Issue.record("expected no match")
            return
        }
        #expect(candidates.map(\.id) == Array(1...8))
    }
}

private let source = "test"

private func choose(_ record: GuidanceRecord) -> GuidanceChoice {
    .record(GuidanceRecordReference(record, source: source))
}

@Suite("Guidance matching with the person's choice")
struct GuidanceChoiceMatchingTests {
    @Test("a chosen record is the match, including over an ambiguous name and over another exact name")
    func choiceDecides() throws {
        let whole = record(1, "Milk", qualifier: "plain")
        let lactoseFree = record(2, "Milk", qualifier: "lactose-free")
        let mayo = record(3, "Mayonnaise")
        let m = try matcher([whole, lactoseFree, mayo])

        #expect(m.match(IngredientName("milk"), choice: choose(lactoseFree)) == .matched(lactoseFree, via: .confirmed))
        #expect(m.match(IngredientName("mayonnaise"), choice: choose(whole)) == .matched(whole, via: .confirmed))
        #expect(m.match(IngredientName(""), choice: choose(mayo)) == .matched(mayo, via: .confirmed))
    }

    @Test("None of these gives no match, even for a name that matches one record")
    func declined() throws {
        let m = try matcher([record(3, "Mayonnaise")])

        #expect(m.match(IngredientName("mayonnaise"), choice: .noneOfThese) == .declined)
    }

    @Test(
        "a chosen record the dataset no longer holds as it was gives no match and no fallback to the name",
        arguments: [
            GuidanceRecordReference(source: "test", id: 99, name: "Mayonnaise", qualifier: nil),
            GuidanceRecordReference(source: "test", id: 3, name: "Mustard", qualifier: nil),
            GuidanceRecordReference(source: "test", id: 3, name: "Mayonnaise", qualifier: "homemade"),
            GuidanceRecordReference(source: "Another source", id: 3, name: "Mayonnaise", qualifier: nil),
        ]
    )
    func missingChoice(reference: GuidanceRecordReference) throws {
        let m = try matcher([record(3, "Mayonnaise")])

        #expect(m.match(IngredientName("mayonnaise"), choice: .record(reference)) == .chosenRecordMissing(reference))
    }

    @Test("no choice matches by name as before")
    func noChoice() throws {
        let mayo = record(3, "Mayonnaise")
        let m = try matcher([mayo])

        #expect(m.match(IngredientName("mayonnaise"), choice: nil) == .matched(mayo, via: .name))
    }
}

@Suite("Guidance candidates")
struct GuidanceCandidateTests {
    @Test("records with the food's own name come first, then the closest names, then keywords")
    func ranking() throws {
        let records = [
            record(1, "Milk", qualifier: "plain"),
            record(2, "Soy milk"),
            record(3, "Chocolate milk drink"),
            record(4, "Milk", qualifier: "canned"),
            record(5, "Kefir", keywords: ["fermented milk"]),
            record(6, "Butter"),
            record(7, "Milk chocolate"),
        ]
        let m = try matcher(records)

        #expect(m.candidates(for: "Milk").map(\.id) == [1, 4, 2, 7, 3, 5])
    }

    @Test("more shared words rank higher than fewer unshared ones")
    func sharedWordsFirst() throws {
        let m = try matcher([
            record(1, "Chicken"),
            record(2, "Chicken noodle soup with vegetables, herbs and rice"),
            record(3, "Soup"),
        ])

        #expect(m.candidates(for: "chicken noodle soup").map(\.id) == [2, 1, 3])
    }

    @Test("among keyword suggestions, more shared words come first")
    func keywordOrder() throws {
        let m = try matcher([
            record(1, "Kefir", keywords: ["goat"]),
            record(2, "Feta", keywords: ["goat cheese", "brine"]),
        ])

        #expect(m.candidates(for: "goat cheese").map(\.id) == [2, 1])
    }

    @Test("every record with the food's own name is listed, beyond the limit; suggestions are capped")
    func exactNeverCut() throws {
        let hams = (1...12).map { record($0, "Ham", qualifier: "cut \($0)") }
        let others = (20...40).map { record($0, "Ham dish \($0)") }
        let m = try matcher(hams + others)

        let ids = m.candidates(for: "ham").map(\.id)

        #expect(ids == Array(1...12) + Array(20...27))
        #expect(GuidanceMatcher.candidateLimit == 8)
    }

    @Test("the order does not depend on the order of the dataset")
    func stableOrder() throws {
        let records = [
            record(5, "Milk"), record(3, "Soy milk"), record(9, "Rice milk"), record(1, "Milk shake"),
            record(7, "Oat milk"), record(2, "Kefir", keywords: ["milk"]), record(4, "Milk"),
        ]
        var generator = SeededGenerator(seed: 7)
        let expected = try matcher(records).candidates(for: "milk").map(\.id)

        for _ in 0..<10 {
            #expect(try matcher(records.shuffled(using: &generator)).candidates(for: "milk").map(\.id) == expected)
        }
        #expect(expected == [4, 5, 1, 3, 7, 9, 2])
    }

    @Test("case, accents, letter width and invisible characters do not hide a record")
    func unicodeAndCase() throws {
        let creme = record(1, "Marshmallow crème")
        let milk = record(2, "Milk")
        let m = try matcher([creme, milk])

        #expect(m.candidates(for: "MARSHMALLOW CREME").first == creme)
        #expect(m.candidates(for: "marshmallow cre\u{0300}me").first == creme)
        #expect(m.candidates(for: "ＭＩＬＫ") == [milk])
        #expect(m.candidates(for: "mi\u{200B}lk") == [milk])
    }

    @Test("an empty, blank or punctuation-only name has no candidates", arguments: ["", "   ", "\n\t", "!!!", "\u{200B}"])
    func emptyName(name: String) throws {
        let m = try matcher([record(1, "Milk"), record(2, "Butter")])

        #expect(m.candidates(for: name).isEmpty)
    }

    @Test("joining words such as and, or and with suggest nothing by themselves")
    func connectivesIgnored() throws {
        let m = try matcher([record(1, "Yams or sweet potatoes"), record(2, "Fish and chips")])

        #expect(m.candidates(for: "rice or beans with salt and pepper").isEmpty)
        #expect(m.candidates(for: "sweet potato").map(\.id) == [1])
    }

    @Test("a food that shares no word with any record has no candidates")
    func nothingShared() throws {
        let m = try matcher([record(1, "Milk")])

        #expect(m.candidates(for: "saffron").isEmpty)
    }

    @Test("only the start of a very long name is read, in characters and then in words")
    func longNameCapped() throws {
        let m = try matcher([record(1, "Milk")])
        let padding = String(repeating: "x", count: GuidanceMatcher.longestQuery - 5)

        #expect(m.candidates(for: padding + " milk").map(\.id) == [1])
        #expect(m.candidates(for: padding + "  milk").isEmpty)

        let words = (1..<GuidanceMatcher.mostQueryWords).map { "w\($0)" }.joined(separator: " ")
        #expect(m.candidates(for: words + " milk").map(\.id) == [1])
        #expect(m.candidates(for: words + " w99 milk").isEmpty)
    }

    @Test("hostile names return only records from the dataset", arguments: [
        String(repeating: "milk ", count: 50_000),
        "m" + String(repeating: "\u{0301}", count: 100_000),
        String(repeating: "\u{1F95B}", count: 10_000),
        "milk\u{0000}butter\u{FEFF}",
        "'; DROP TABLE records; -- milk",
    ])
    func hostileNames(name: String) throws {
        let records = [record(1, "Milk"), record(2, "Butter")]
        let m = try matcher(records)

        let found = m.candidates(for: name)

        #expect(found.allSatisfy(records.contains))
        #expect(Set(found.map(\.id)).count == found.count)
    }
}
