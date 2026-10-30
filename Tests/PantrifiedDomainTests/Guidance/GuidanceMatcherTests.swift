import Foundation
import Testing
@testable import PantrifiedDomain

private func record(_ id: Int, _ name: String, keywords: [String] = []) -> GuidanceRecord {
    GuidanceRecord(
        id: id, name: name, qualifier: nil, category: nil, keywords: keywords,
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

    @Test("suggestions are limited and ordered by identifier")
    func candidateLimit() throws {
        let many = (1...15).map { record($0, "Cream \($0)", keywords: []) }
        let m = try matcher(many)

        guard case .noMatch(let candidates) = m.match(IngredientName("cream")) else {
            Issue.record("expected no match")
            return
        }
        #expect(candidates.map(\.id) == Array(1...10))
    }
}
