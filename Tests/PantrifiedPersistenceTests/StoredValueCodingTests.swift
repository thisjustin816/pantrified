import Foundation
import Testing
import PantrifiedDomain
import PantrifiedTestSupport
@testable import PantrifiedPersistence

/// Every bit of a stored value must come back as written: merge ties compare stored forms, so a
/// value that changed on its way through storage would sort differently on this device than on
/// every other.
@Suite("Stored value coding")
struct StoredValueCodingTests {
    private static let unusual: [FieldValue] = [
        .null, .bool(true), .bool(false), .int(.min), .int(.max), .int(0),
        .double(.nan), .double(-.nan), .double(Double(nan: 0x1234, signaling: false)), .double(.signalingNaN),
        .double(.infinity), .double(-.infinity), .double(0), .double(-0.0), .double(.leastNonzeroMagnitude),
        .date(Date(timeIntervalSinceReferenceDate: .nan)), .date(Date(timeIntervalSinceReferenceDate: -0.0)),
        .date(.distantPast), .date(Date(timeIntervalSinceReferenceDate: 0.1)),
        .string(""), .string("caf\u{E9}"), .string("cafe\u{301}"), .string("\u{FEFF}leading mark"),
        .string("nul\u{0}inside"), .string("🍅 tomatoes"),
        .uuid(UUID()), .list([]), .map([:]),
        .list([.int(1), .list([.null, .map(["b": .bool(true), "a": .string("x")])])]),
    ]

    /// Iterated rather than passed as arguments: describing a NaN date crashes Linux Foundation,
    /// and the test runner describes every argument.
    @Test("every value comes back with the same stored form")
    func valuesRoundTrip() throws {
        for (index, value) in Self.unusual.enumerated() {
            let encoded = StoredValueCoding.encode(value)
            let decoded = try StoredValueCoding.value(from: encoded)

            #expect(decoded == value, "value \(index)")
            #expect(StoredValueCoding.encode(decoded) == encoded, "value \(index)")
            switch (value, decoded) {
            case let (.double(original), .double(back)):
                #expect(back.bitPattern == original.bitPattern, "value \(index)")
            case let (.date(original), .date(back)):
                #expect(back.timeIntervalSinceReferenceDate.bitPattern == original.timeIntervalSinceReferenceDate.bitPattern, "value \(index)")
            case let (.string(original), .string(back)):
                #expect(Array(back.utf8) == Array(original.utf8), "value \(index)")
            default:
                break
            }
        }
    }

    @Test("two encodings of one accented string stay different values")
    func unicodeFormsStayDistinct() throws {
        let composed = try StoredValueCoding.value(from: StoredValueCoding.encode(.string("caf\u{E9}")))
        let decomposed = try StoredValueCoding.value(from: StoredValueCoding.encode(.string("cafe\u{301}")))

        #expect(composed != decomposed)
    }

    @Test("equal maps encode to identical bytes whatever order their keys were inserted in")
    func encodingIsCanonical() {
        var forward: [String: FieldValue] = [:]
        var backward: [String: FieldValue] = [:]
        let keys = (0..<40).map { "key\($0)" }
        for key in keys { forward[key] = .string(key) }
        for key in keys.reversed() { backward[key] = .string(key) }

        #expect(StoredValueCoding.encode(.map(forward)) == StoredValueCoding.encode(.map(backward)))
    }

    @Test("records with every kind of value, stamp and reader version round trip exactly", arguments: [UInt64(1), 2, 3, 99])
    func randomRecordsRoundTrip(seed: UInt64) throws {
        var rng = SeededGenerator(seed: seed)
        for _ in 0..<200 {
            let record = Self.randomRecord(using: &rng)
            let data = StoredValueCoding.encode(record)

            let decoded = try StoredValueCoding.record(from: data)

            #expect(decoded == record)
            #expect(decoded.created == record.created)
            #expect(decoded.minimumReaderVersion == record.minimumReaderVersion)
            #expect(StoredValueCoding.encode(decoded) == data)
        }
    }

    @Test("a record kind this version does not know is kept as written")
    func unknownKindRoundTrips() throws {
        let record = SyncRecord(
            id: RecordID(kind: RecordKind(rawValue: "mealPlan|v2"), entity: UUID()),
            created: HybridTimestamp(physicalMillis: .min, counter: .max, replica: ReplicaID()),
            minimumReaderVersion: 7,
            fields: ["future": FieldEntry(value: .list([.string("x")]), stamp: HybridTimestamp(physicalMillis: 5, counter: 0, replica: ReplicaID()))]
        )

        #expect(try StoredValueCoding.record(from: StoredValueCoding.encode(record)) == record)
    }

    @Test("data cut short anywhere is reported as corrupt")
    func truncatedDataIsCorrupt() {
        var rng = SeededGenerator(seed: 5)
        let data = StoredValueCoding.encode(Self.randomRecord(using: &rng))
        for length in 0..<data.count {
            #expect(throws: PersistenceError.self) {
                try StoredValueCoding.record(from: data.prefix(length))
            }
        }
    }

    @Test("trailing bytes after a value are reported as corrupt")
    func trailingBytesAreCorrupt() {
        var data = StoredValueCoding.encode(.int(4))
        data.append(0)

        #expect(throws: PersistenceError.corrupt("trailing bytes")) {
            try StoredValueCoding.value(from: data)
        }
    }

    @Test("a value written in a newer encoding is refused with both versions named")
    func newerEncodingIsRefused() {
        var data = StoredValueCoding.encode(.int(4))
        data[data.startIndex] = StoredValueCoding.version + 1

        #expect(throws: PersistenceError.newerFormat(found: Int(StoredValueCoding.version) + 1, supported: Int(StoredValueCoding.version))) {
            try StoredValueCoding.value(from: data)
        }
    }

    @Test("an unknown value tag, invalid UTF-8 or a repeated map key is reported as corrupt")
    func malformedValuesAreCorrupt() {
        let version = StoredValueCoding.version
        let unknownTag = Data([version, 0xEE])
        let invalidUTF8 = Data([version, 4, 1, 0, 0, 0, 0xFF])
        let repeatedKey = Data([version, 8, 2, 0, 0, 0, 1, 0, 0, 0, 0x61, 0, 1, 0, 0, 0, 0x61, 0])
        let unsortedKeys = Data([version, 8, 2, 0, 0, 0, 1, 0, 0, 0, 0x62, 0, 1, 0, 0, 0, 0x61, 0])
        let hugeCount = Data([version, 7, 0xFF, 0xFF, 0xFF, 0x7F])

        for data in [unknownTag, invalidUTF8, repeatedKey, unsortedKeys, hugeCount] {
            #expect(throws: PersistenceError.self) { try StoredValueCoding.value(from: data) }
        }
    }

    // MARK: Generators

    static func randomRecord(using rng: inout SeededGenerator) -> SyncRecord {
        let kinds: [RecordKind] = [.package, .packageEvent, .shoppingItem, .evidenceCrop, RecordKind(rawValue: "x")]
        var fields: [String: FieldEntry] = [:]
        for index in 0..<Int.random(in: 0...6, using: &rng) {
            fields["f\(index)\(Bool.random(using: &rng) ? "é" : "")"] = FieldEntry(
                value: randomValue(depth: 0, using: &rng), stamp: randomStamp(using: &rng)
            )
        }
        return SyncRecord(
            id: RecordID(kind: kinds.randomElement(using: &rng)!, entity: UUID()),
            created: randomStamp(using: &rng),
            minimumReaderVersion: Int.random(in: -2...9, using: &rng),
            fields: fields
        )
    }

    static func randomStamp(using rng: inout SeededGenerator) -> HybridTimestamp {
        HybridTimestamp(
            physicalMillis: [Int64.min, .max, 0, Int64.random(in: 0...2_000_000_000_000, using: &rng)].randomElement(using: &rng)!,
            counter: [0, 1, Int.max, Int.random(in: 0...100, using: &rng)].randomElement(using: &rng)!,
            replica: ReplicaID()
        )
    }

    static func randomValue(depth: Int, using rng: inout SeededGenerator) -> FieldValue {
        let pick = Int.random(in: 0...(depth < 2 ? 8 : 6), using: &rng)
        switch pick {
        case 0: return .null
        case 1: return .bool(Bool.random(using: &rng))
        case 2: return .int(Int64.random(in: .min ... .max, using: &rng))
        case 3: return .double(Double(bitPattern: UInt64.random(in: 0 ... .max, using: &rng)))
        case 4: return .string(String((0..<Int.random(in: 0...8, using: &rng)).map { _ in "aé🍅\u{301}\u{0}z".randomElement(using: &rng)! }))
        case 5: return .date(Date(timeIntervalSinceReferenceDate: Double(bitPattern: UInt64.random(in: 0 ... .max, using: &rng))))
        case 6: return .uuid(UUID())
        case 7: return .list((0..<Int.random(in: 0...3, using: &rng)).map { _ in randomValue(depth: depth + 1, using: &rng) })
        default:
            var map: [String: FieldValue] = [:]
            for index in 0..<Int.random(in: 0...3, using: &rng) { map["k\(index)"] = randomValue(depth: depth + 1, using: &rng) }
            return .map(map)
        }
    }
}
