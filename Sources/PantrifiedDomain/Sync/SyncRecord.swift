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

    /// A total order used only to break ties between different values written with the same stamp,
    /// which a correctly persisted clock never produces.
    fileprivate var canonical: String {
        switch self {
        case .null: "n"
        case .bool(let value): "b\(value)"
        case .int(let value): "i\(value)"
        case .double(let value): "d\(value)"
        case .string(let value): "s\(value)"
        case .date(let value): "t\(value.timeIntervalSinceReferenceDate)"
        case .uuid(let value): "u\(value.uuidString)"
        case .list(let values): "l[" + values.map(\.canonical).joined(separator: ",") + "]"
        case .map(let values):
            "m{" + values.keys.sorted().map { "\($0)=\(values[$0]!.canonical)" }.joined(separator: ",") + "}"
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
        return value.canonical > other.value.canonical
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

    /// The latest stamp anywhere in the record, which a replica's clock must move past on receipt.
    public var latestStamp: HybridTimestamp {
        fields.values.map(\.stamp).reduce(created, max)
    }

    public func value(_ field: String) -> FieldValue? {
        fields[field]?.value
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
