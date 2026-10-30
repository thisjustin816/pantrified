import Foundation
import Testing
@testable import PantrifiedDomain

private func record(
    _ id: Int, _ name: String, keywords: [String] = [], windows: [GuidanceWindow] = [
        GuidanceWindow(storageType: .refrigerated, anchor: .added, days: 3),
    ]
) -> GuidanceRecord {
    GuidanceRecord(id: id, name: name, qualifier: nil, category: nil, keywords: keywords, windows: windows)
}

private func provenance(checksum: String? = String(repeating: "a", count: 64)) -> GuidanceDataset.Provenance {
    GuidanceDataset.Provenance(
        source: "USDA FSIS FoodKeeper", sourceVersion: "2026-01-15", sourceChecksum: checksum, normalizationVersion: "1"
    )
}

@Suite("Guidance dataset validation")
struct GuidanceDatasetValidationTests {
    @Test("a well-formed dataset is accepted")
    func valid() throws {
        let dataset = try GuidanceDataset(provenance: provenance(), records: [record(1, "Butter"), record(2, "Milk")])

        #expect(dataset.records.count == 2)
    }

    @Test("duplicate record ids are rejected")
    func duplicateIDs() {
        #expect(throws: GuidanceDatasetError.duplicateID(1)) {
            try GuidanceDataset(provenance: provenance(), records: [record(1, "Butter"), record(1, "Milk")])
        }
    }

    @Test("a window must be a positive number of days")
    func badDays() {
        let zero = [GuidanceWindow(storageType: .frozen, anchor: .added, days: 0)]
        let negative = [GuidanceWindow(storageType: .frozen, anchor: .added, days: -5)]

        #expect(throws: GuidanceDatasetError.invalidDays(record: 1)) {
            try GuidanceDataset(provenance: provenance(), records: [record(1, "Butter", windows: zero)])
        }
        #expect(throws: GuidanceDatasetError.invalidDays(record: 2)) {
            try GuidanceDataset(provenance: provenance(), records: [record(2, "Milk", windows: negative)])
        }
    }

    @Test("a record needs a name that normalizes to something")
    func blankName() {
        #expect(throws: GuidanceDatasetError.blankName(record: 3)) {
            try GuidanceDataset(provenance: provenance(), records: [record(3, " , ")])
        }
    }

    @Test("a source checksum must be a SHA-256 hex digest when present")
    func checksumShape() {
        #expect(throws: GuidanceDatasetError.invalidChecksum) {
            try GuidanceDataset(provenance: provenance(checksum: "not-a-digest"), records: [])
        }
        #expect(throws: Never.self) {
            try GuidanceDataset(provenance: provenance(checksum: nil), records: [])
        }
    }

    @Test("the normalization version and source cannot be blank")
    func provenanceRequired() {
        let blank = GuidanceDataset.Provenance(source: " ", sourceVersion: nil, sourceChecksum: nil, normalizationVersion: "1")

        #expect(throws: GuidanceDatasetError.blankProvenance) {
            try GuidanceDataset(provenance: blank, records: [])
        }
    }

    @Test("a dataset survives a JSON round trip and decoding re-validates it")
    func roundTrip() throws {
        let dataset = try GuidanceDataset(provenance: provenance(), records: [record(1, "Butter", keywords: ["unsalted butter"])])
        let data = try JSONEncoder().encode(dataset)

        #expect(try JSONDecoder().decode(GuidanceDataset.self, from: data) == dataset)

        let broken = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"days\":3", with: "\"days\":0")
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(GuidanceDataset.self, from: Data(broken.utf8))
        }
    }

    @Test("the provenance the attention engine reports names the source and both versions")
    func attentionProvenance() throws {
        let dataset = try GuidanceDataset(provenance: provenance(), records: [])

        #expect(dataset.attentionProvenance.source == "USDA FSIS FoodKeeper")
        #expect(dataset.attentionProvenance.version.contains("2026-01-15"))
        #expect(dataset.attentionProvenance.version.contains("1"))
    }
}

@Suite("Guidance data encoding")
struct GuidanceEncodingTests {
    @Test("a window is written as plain strings and a day count")
    func windowEncoding() throws {
        let window = GuidanceWindow(storageType: .roomTemperature, anchor: .opened, days: 14)
        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(window)) as? [String: Any]
        )

        #expect(object["storageType"] as? String == "roomTemperature")
        #expect(object["anchor"] as? String == "opened")
        #expect(object["days"] as? Int == 14)
    }

    @Test("every storage type and anchor survives a round trip")
    func windowRoundTrip() throws {
        for storage in [StorageType.refrigerated, .frozen, .roomTemperature] {
            for anchor in [WindowAnchor.added, .opened, .thawed] {
                let window = GuidanceWindow(storageType: storage, anchor: anchor, days: 7)

                #expect(try JSONDecoder().decode(GuidanceWindow.self, from: JSONEncoder().encode(window)) == window)
            }
        }
    }

    @Test("an unknown storage type or anchor is a decoding error, not a guess")
    func unknownValues() {
        let badStorage = Data(#"{"storageType":"cellar","anchor":"added","days":3}"#.utf8)
        let badAnchor = Data(#"{"storageType":"frozen","anchor":"sometime","days":3}"#.utf8)

        #expect(throws: (any Error).self) { try JSONDecoder().decode(GuidanceWindow.self, from: badStorage) }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(GuidanceWindow.self, from: badAnchor) }
    }

    @Test("a record keeps the source's qualifier and decodes one that is absent")
    func qualifier() throws {
        let withQualifier = GuidanceRecord(
            id: 27, name: "Milk", qualifier: "plain or flavored", category: "Dairy", keywords: [], windows: []
        )
        let data = try JSONEncoder().encode(withQualifier)

        #expect(try JSONDecoder().decode(GuidanceRecord.self, from: data).qualifier == "plain or flavored")

        let json = Data(#"{"id":1,"name":"Butter","keywords":[],"windows":[]}"#.utf8)
        #expect(try JSONDecoder().decode(GuidanceRecord.self, from: json).qualifier == nil)
    }
}
