import Foundation
import PantrifiedDomain

/// The stored form of synchronized records and of the values device-local rows hold. Every value
/// is written bit for bit: doubles and dates by their bit patterns, so NaN payloads, infinities and
/// negative zero survive, and strings by their UTF-8 bytes, so two encodings of one accented
/// string stay different values. Map keys and record fields are written in UTF-8 byte order, so
/// equal values always produce identical bytes.
///
/// The layout is in `docs/persistence.md`.
public enum StoredValueCoding {
    /// The encoding this build writes. Data written with a later one is refused, never guessed at.
    public static let version: UInt8 = 1

    public static func encode(_ record: SyncRecord) -> Data {
        var writer = ByteWriter(version: version)
        writer.record(record)
        return writer.data
    }

    public static func record(from data: Data) throws(PersistenceError) -> SyncRecord {
        var reader = try ByteReader(data, version: version)
        let record = try reader.record()
        try reader.finish()
        return record
    }

    public static func encode(_ value: FieldValue) -> Data {
        var writer = ByteWriter(version: version)
        writer.value(value)
        return writer.data
    }

    public static func value(from data: Data) throws(PersistenceError) -> FieldValue {
        var reader = try ByteReader(data, version: version)
        let value = try reader.value()
        try reader.finish()
        return value
    }
}

private enum ValueTag: UInt8 {
    case null, bool, int, double, string, date, uuid, list, map
}

private func utf8Order(_ a: String, _ b: String) -> Bool {
    a.utf8.lexicographicallyPrecedes(b.utf8)
}

struct ByteWriter {
    private var bytes: [UInt8]

    init(version: UInt8) {
        bytes = [version]
    }

    var data: Data { Data(bytes) }

    mutating func byte(_ value: UInt8) {
        bytes.append(value)
    }

    mutating func count(_ value: Int) {
        let count = UInt32(value)
        withUnsafeBytes(of: count.littleEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func int64(_ value: Int64) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func bits(_ value: Double) {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func string(_ value: String) {
        count(value.utf8.count)
        bytes.append(contentsOf: value.utf8)
    }

    mutating func uuid(_ value: UUID) {
        withUnsafeBytes(of: value.uuid) { bytes.append(contentsOf: $0) }
    }

    mutating func stamp(_ stamp: HybridTimestamp) {
        int64(stamp.physicalMillis)
        int64(Int64(stamp.counter))
        uuid(stamp.replica.rawValue)
    }

    mutating func value(_ value: FieldValue) {
        switch value {
        case .null:
            byte(ValueTag.null.rawValue)
        case .bool(let flag):
            byte(ValueTag.bool.rawValue)
            byte(flag ? 1 : 0)
        case .int(let number):
            byte(ValueTag.int.rawValue)
            int64(number)
        case .double(let number):
            byte(ValueTag.double.rawValue)
            bits(number)
        case .string(let text):
            byte(ValueTag.string.rawValue)
            string(text)
        case .date(let date):
            byte(ValueTag.date.rawValue)
            bits(date.timeIntervalSinceReferenceDate)
        case .uuid(let id):
            byte(ValueTag.uuid.rawValue)
            uuid(id)
        case .list(let values):
            byte(ValueTag.list.rawValue)
            count(values.count)
            for element in values { self.value(element) }
        case .map(let entries):
            byte(ValueTag.map.rawValue)
            count(entries.count)
            for (key, element) in entries.sorted(by: { utf8Order($0.key, $1.key) }) {
                string(key)
                self.value(element)
            }
        }
    }

    mutating func record(_ record: SyncRecord) {
        string(record.id.kind.rawValue)
        uuid(record.id.entity)
        stamp(record.created)
        int64(Int64(record.minimumReaderVersion))
        count(record.fields.count)
        for (name, entry) in record.fields.sorted(by: { utf8Order($0.key, $1.key) }) {
            string(name)
            value(entry.value)
            stamp(entry.stamp)
        }
    }
}

/// Reads what `ByteWriter` wrote. Any shortfall, trailing byte, unknown tag, invalid UTF-8 or
/// out-of-order key is reported as corruption rather than repaired.
struct ByteReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data, version: UInt8) throws(PersistenceError) {
        bytes = [UInt8](data)
        guard let found = bytes.first else { throw .corrupt("empty value") }
        guard found <= version else { throw .newerFormat(found: Int(found), supported: Int(version)) }
        guard found == version else { throw .corrupt("unknown encoding \(found)") }
        offset = 1
    }

    func finish() throws(PersistenceError) {
        guard offset == bytes.count else { throw .corrupt("trailing bytes") }
    }

    private mutating func take(_ length: Int) throws(PersistenceError) -> ArraySlice<UInt8> {
        guard length <= bytes.count - offset else { throw .corrupt("truncated") }
        defer { offset += length }
        return bytes[offset..<(offset + length)]
    }

    mutating func byte() throws(PersistenceError) -> UInt8 {
        try take(1).first!
    }

    private mutating func uint64() throws(PersistenceError) -> UInt64 {
        try take(8).reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// Nothing is reserved from a count, so a corrupt one fails at the first read past the end
    /// rather than allocating.
    mutating func count() throws(PersistenceError) -> Int {
        Int(try take(4).reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    }

    mutating func int64() throws(PersistenceError) -> Int64 {
        Int64(bitPattern: try uint64())
    }

    mutating func bits() throws(PersistenceError) -> Double {
        Double(bitPattern: try uint64())
    }

    mutating func string() throws(PersistenceError) -> String {
        let raw = try take(try count())
        let text = String(decoding: raw, as: UTF8.self)
        // Decoding repairs invalid UTF-8 rather than failing, so a repair shows as a byte change.
        guard text.utf8.elementsEqual(raw) else { throw .corrupt("invalid UTF-8") }
        return text
    }

    mutating func uuid() throws(PersistenceError) -> UUID {
        var raw: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        let source = try take(16)
        withUnsafeMutableBytes(of: &raw) { $0.copyBytes(from: source) }
        return UUID(uuid: raw)
    }

    mutating func stamp() throws(PersistenceError) -> HybridTimestamp {
        let millis = try int64()
        let counter = try int64()
        return HybridTimestamp(physicalMillis: millis, counter: Int(counter), replica: ReplicaID(try uuid()))
    }

    mutating func value() throws(PersistenceError) -> FieldValue {
        guard let tag = ValueTag(rawValue: try byte()) else { throw .corrupt("unknown value tag") }
        switch tag {
        case .null:
            return .null
        case .bool:
            switch try byte() {
            case 0: return .bool(false)
            case 1: return .bool(true)
            default: throw .corrupt("invalid bool")
            }
        case .int:
            return .int(try int64())
        case .double:
            return .double(try bits())
        case .string:
            return .string(try string())
        case .date:
            return .date(Date(timeIntervalSinceReferenceDate: try bits()))
        case .uuid:
            return .uuid(try uuid())
        case .list:
            var values: [FieldValue] = []
            for _ in 0..<(try count()) { values.append(try value()) }
            return .list(values)
        case .map:
            var entries: [String: FieldValue] = [:]
            var previous: String?
            for _ in 0..<(try count()) {
                let key = try string()
                try requireAscending(key, after: previous)
                previous = key
                entries[key] = try value()
            }
            return .map(entries)
        }
    }

    mutating func record() throws(PersistenceError) -> SyncRecord {
        let kind = RecordKind(rawValue: try string())
        let entity = try uuid()
        let created = try stamp()
        let minimumReaderVersion = Int(try int64())
        var fields: [String: FieldEntry] = [:]
        var previous: String?
        for _ in 0..<(try count()) {
            let name = try string()
            try requireAscending(name, after: previous)
            previous = name
            let value = try value()
            fields[name] = FieldEntry(value: value, stamp: try stamp())
        }
        return SyncRecord(
            id: RecordID(kind: kind, entity: entity),
            created: created,
            minimumReaderVersion: minimumReaderVersion,
            fields: fields
        )
    }

    /// Keys are written in strictly ascending order, which also rules out a repeated key.
    private func requireAscending(_ key: String, after previous: String?) throws(PersistenceError) {
        if let previous, !utf8Order(previous, key) { throw .corrupt("keys out of order") }
    }
}
