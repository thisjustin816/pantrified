import Foundation

/// The record format this build writes and fully understands.
public enum SyncFormat {
    public static let version = 1
}

/// A string rather than a closed enum so a record kind added by a newer version can be stored and
/// passed on by an older one.
public struct RecordKind: RawRepresentable, Sendable, Hashable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let package = RecordKind(rawValue: "package")
    public static let packageEvent = RecordKind(rawValue: "packageEvent")
    public static let shoppingItem = RecordKind(rawValue: "shoppingItem")
    public static let evidenceCrop = RecordKind(rawValue: "evidenceCrop")
}

public struct RecordID: Sendable, Hashable, Codable {
    public let kind: RecordKind
    /// The app-owned identity of the entity the record describes.
    public let entity: UUID

    public init(kind: RecordKind, entity: UUID) {
        self.kind = kind
        self.entity = entity
    }
}

/// Values a transport can store without understanding them.
public indirect enum FieldValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case date(Date)
    case uuid(UUID)
    case list([FieldValue])
    case map([String: FieldValue])

    /// Equal when stored identically: strings by their UTF-8 bytes, doubles and dates by their bits.
    /// Swift's own equality calls two encodings of one accented string equal, and 0 equal to -0,
    /// so replicas could keep different stored forms of one write; and it calls NaN unequal to
    /// itself, so an unchanged NaN would be written again by every local change.
    public static func == (lhs: FieldValue, rhs: FieldValue) -> Bool {
        lhs.compare(rhs) == 0
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rank)
        switch self {
        case .null: break
        case .bool(let value): hasher.combine(value)
        case .int(let value): hasher.combine(value)
        case .double(let value): hasher.combine(value.bitPattern)
        case .string(let value): hasher.combine(bytesOf: value)
        case .date(let value): hasher.combine(value.timeIntervalSinceReferenceDate.bitPattern)
        case .uuid(let value): hasher.combine(value)
        case .list(let values):
            hasher.combine(values.count)
            for value in values { value.hash(into: &hasher) }
        case .map(let values):
            hasher.combine(values.count)
            for (key, value) in values.sortedByKey {
                hasher.combine(bytesOf: key)
                value.hash(into: &hasher)
            }
        }
    }

    /// A total order on stored values, zero exactly when they are equal. It chooses between
    /// different values written with the same stamp, and every version must choose the same
    /// winner, so this order is part of the record format.
    fileprivate func compare(_ other: FieldValue) -> Int {
        switch (self, other) {
        case (.null, .null): 0
        case let (.bool(a), .bool(b)): order(a ? 1 : 0, b ? 1 : 0)
        case let (.int(a), .int(b)): order(a, b)
        case let (.double(a), .double(b)): order(a.bitPattern, b.bitPattern)
        case let (.string(a), .string(b)): order(a.utf8, b.utf8)
        case let (.date(a), .date(b)):
            order(a.timeIntervalSinceReferenceDate.bitPattern, b.timeIntervalSinceReferenceDate.bitPattern)
        case let (.uuid(a), .uuid(b)): order(a.uuidString.utf8, b.uuidString.utf8)
        case let (.list(a), .list(b)): order(a, b) { $0.compare($1) }
        case let (.map(a), .map(b)):
            order(a.sortedByKey, b.sortedByKey) { left, right in
                let key = order(left.key.utf8, right.key.utf8)
                return key != 0 ? key : left.value.compare(right.value)
            }
        default: order(rank, other.rank)
        }
    }

    private var rank: Int {
        switch self {
        case .null: 0
        case .bool: 1
        case .int: 2
        case .double: 3
        case .string: 4
        case .date: 5
        case .uuid: 6
        case .list: 7
        case .map: 8
        }
    }
}

private extension Dictionary where Key == String {
    var sortedByKey: [(key: String, value: Value)] {
        sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
    }
}

private extension Hasher {
    mutating func combine(bytesOf string: String) {
        combine(string.utf8.count)
        for byte in string.utf8 { combine(byte) }
    }
}

private func order<T: Comparable>(_ a: T, _ b: T) -> Int {
    a < b ? -1 : (a == b ? 0 : 1)
}

private func order<S: Sequence>(_ a: S, _ b: S) -> Int where S.Element: Comparable {
    order(a, b) { order($0, $1) }
}

/// Lexicographic, with a shorter sequence ordered before any longer one it is a prefix of.
private func order<S: Sequence>(_ a: S, _ b: S, by compare: (S.Element, S.Element) -> Int) -> Int {
    var left = a.makeIterator()
    var right = b.makeIterator()
    while true {
        switch (left.next(), right.next()) {
        case (nil, nil): return 0
        case (nil, _): return -1
        case (_, nil): return 1
        case let (l?, r?):
            let result = compare(l, r)
            if result != 0 { return result }
        }
    }
}

public struct FieldEntry: Sendable, Hashable, Codable {
    public var value: FieldValue
    public var stamp: HybridTimestamp

    public init(value: FieldValue, stamp: HybridTimestamp) {
        self.value = value
        self.stamp = stamp
    }

    fileprivate func wins(over other: FieldEntry) -> Bool {
        if stamp != other.stamp { return stamp > other.stamp }
        return value.compare(other.value) > 0
    }
}

/// One synchronized record. Every field is a register holding its latest write, so merging two
/// copies is a per-field choice that gives the same result in any order and any number of times.
public struct SyncRecord: Sendable, Hashable, Codable {
    public let id: RecordID
    /// When the entity was first written. Orders events and list items identically on every replica.
    public var created: HybridTimestamp
    /// Readers older than this must not interpret the record. Writers raise it only for changes an
    /// older reader cannot safely ignore.
    public var minimumReaderVersion: Int
    public var fields: [String: FieldEntry]

    public init(
        id: RecordID,
        created: HybridTimestamp,
        minimumReaderVersion: Int = SyncFormat.version,
        fields: [String: FieldEntry]
    ) {
        self.id = id
        self.created = created
        self.minimumReaderVersion = minimumReaderVersion
        self.fields = fields
    }

    /// A write of `values` at one stamp. `created` defaults to that stamp for a new record; a change
    /// to an existing record passes the record's own creation stamp.
    init(id: RecordID, writing values: [String: FieldValue], at stamp: HybridTimestamp, created: HybridTimestamp? = nil) {
        self.init(id: id, created: created ?? stamp, fields: values.mapValues { FieldEntry(value: $0, stamp: stamp) })
    }

    public func merged(with other: SyncRecord) -> SyncRecord {
        precondition(id == other.id, "merging records of different entities")
        var result = self
        result.created = min(created, other.created)
        result.minimumReaderVersion = max(minimumReaderVersion, other.minimumReaderVersion)
        for (name, entry) in other.fields {
            if let existing = result.fields[name], !entry.wins(over: existing) { continue }
            result.fields[name] = entry
        }
        return result
    }

    /// Every stamp in the record: its creation stamp and each field's.
    public var stamps: [HybridTimestamp] {
        [created] + fields.values.map(\.stamp)
    }

    /// The latest stamp anywhere in the record, which a replica's clock must move past on receipt.
    public var latestStamp: HybridTimestamp {
        fields.values.map(\.stamp).reduce(created, max)
    }

    public func value(_ field: String) -> FieldValue? {
        fields[field]?.value
    }

    /// The order events are folded in and list items are shown in: creation stamp, then record ID.
    /// Two installations that share a replica ID and clock can write different records with equal
    /// creation stamps, and the record ID keeps the order the same on every replica.
    func precedes(_ other: SyncRecord) -> Bool {
        if created != other.created { return created < other.created }
        let kind = order(id.kind.rawValue.utf8, other.id.kind.rawValue.utf8)
        if kind != 0 { return kind < 0 }
        return order(id.entity.uuidString.utf8, other.id.entity.uuidString.utf8) < 0
    }
}

/// A replica's view of every record in a Space.
public struct RecordSet: Sendable, Hashable, Codable {
    public private(set) var records: [RecordID: SyncRecord] = [:]

    public init() {}

    public subscript(id: RecordID) -> SyncRecord? {
        records[id]
    }

    /// Returns whether the stored record changed.
    @discardableResult
    public mutating func merge(_ record: SyncRecord) -> Bool {
        let merged = records[record.id].map { $0.merged(with: record) } ?? record
        guard merged != records[record.id] else { return false }
        records[record.id] = merged
        return true
    }

    public func records(of kind: RecordKind) -> [SyncRecord] {
        records.values.filter { $0.id.kind == kind }
    }
}
