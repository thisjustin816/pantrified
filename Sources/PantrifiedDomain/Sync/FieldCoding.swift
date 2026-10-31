import Foundation

/// The wire form of domain values. Tags are written out explicitly so renaming a Swift case never
/// changes what is stored or what other replicas can read.
struct RecordDecodingError: Error {}

/// Tags for an enum without payloads. Decoding an unknown tag throws.
struct TagTable<Value: Hashable & Sendable>: Sendable {
    private let tags: [Value: String]
    private let values: [String: Value]

    init(_ pairs: [(Value, String)]) {
        tags = Dictionary(uniqueKeysWithValues: pairs)
        values = Dictionary(uniqueKeysWithValues: pairs.map { ($0.1, $0.0) })
    }

    func tag(_ value: Value) -> String { tags[value]! }

    func encode(_ value: Value) -> FieldValue { .string(tag(value)) }

    func decode(_ field: FieldValue?) throws -> Value {
        guard case .string(let tag) = field, let value = values[tag] else { throw RecordDecodingError() }
        return value
    }

    func decodeIfKnown(_ field: FieldValue) -> Value? {
        guard case .string(let tag) = field else { return nil }
        return values[tag]
    }
}

extension FieldValue {
    func string() throws -> String {
        guard case .string(let value) = self else { throw RecordDecodingError() }
        return value
    }

    func date() throws -> Date {
        guard case .date(let value) = self else { throw RecordDecodingError() }
        return value
    }

    func uuid() throws -> UUID {
        guard case .uuid(let value) = self else { throw RecordDecodingError() }
        return value
    }

    func int() throws -> Int64 {
        guard case .int(let value) = self else { throw RecordDecodingError() }
        return value
    }

    func bool() throws -> Bool {
        guard case .bool(let value) = self else { throw RecordDecodingError() }
        return value
    }

    func map() throws -> [String: FieldValue] {
        guard case .map(let value) = self else { throw RecordDecodingError() }
        return value
    }

    /// Nil for `.null`, otherwise the decoded value.
    func optional<T>(_ decode: (FieldValue) throws -> T) throws -> T? {
        self == .null ? nil : try decode(self)
    }

    static func optional<T>(_ value: T?, _ encode: (T) -> FieldValue) -> FieldValue {
        value.map(encode) ?? .null
    }
}

extension Optional where Wrapped == FieldValue {
    func required() throws -> FieldValue {
        guard let self else { throw RecordDecodingError() }
        return self
    }
}

extension Identifier {
    var field: FieldValue { .uuid(rawValue) }

    init(field: FieldValue) throws {
        self.init(try field.uuid())
    }
}

extension StorageType {
    /// The tag every app-owned format stores, so renaming a case never changes stored data.
    public var storedTag: String { DomainCoding.storageType.tag(self) }

    /// Nil for a tag this version does not know.
    public init?(storedTag: String) {
        guard let type = DomainCoding.storageType.decodeIfKnown(.string(storedTag)) else { return nil }
        self = type
    }
}

enum DomainCoding {
    static let printedDateLabel = TagTable<PrintedDateLabel>([
        (.useBy, "useBy"), (.bestBy, "bestBy"), (.sellBy, "sellBy"),
        (.freezeBy, "freezeBy"), (.packed, "packed"), (.unlabeled, "unlabeled"),
    ])
    static let windowAnchor = TagTable<WindowAnchor>([(.added, "added"), (.opened, "opened"), (.thawed, "thawed")])
    static let storageType = TagTable<StorageType>([
        (.refrigerated, "refrigerated"), (.frozen, "frozen"), (.roomTemperature, "roomTemperature"),
    ])
    static let discardReason = TagTable<DiscardReason>([(.spoiled, "spoiled"), (.unwanted, "unwanted"), (.other, "other")])
    static let packageField = TagTable<PackageField>([
        (.name, "name"), (.productID, "productID"), (.printedDate, "printedDate"), (.instruction, "instruction"),
    ])

    static func encode(_ quantity: Quantity) -> FieldValue {
        switch quantity {
        case .unknown: .map(["level": .string("unknown")])
        case .full: .map(["level": .string("full")])
        case .aboutHalf: .map(["level": .string("aboutHalf")])
        case .low: .map(["level": .string("low")])
        case .exact(let amount, let unit):
            .map(["level": .string("exact"), "amount": .double(amount), "unit": .string(unit)])
        }
    }

    static func quantity(_ field: FieldValue) throws -> Quantity {
        let map = try field.map()
        switch try map["level"].required().string() {
        case "unknown": return .unknown
        case "full": return .full
        case "aboutHalf": return .aboutHalf
        case "low": return .low
        case "exact":
            guard case .double(let amount) = map["amount"] else { throw RecordDecodingError() }
            return .exact(amount, unit: try map["unit"].required().string())
        default: throw RecordDecodingError()
        }
    }

    static func encode(_ printed: PrintedDate) -> FieldValue {
        .map(["label": printedDateLabel.encode(printed.label), "date": .date(printed.date)])
    }

    static func printedDate(_ field: FieldValue) throws -> PrintedDate {
        let map = try field.map()
        return PrintedDate(label: try printedDateLabel.decode(map["label"]), date: try map["date"].required().date())
    }

    static func encode(_ instruction: PackageInstruction) -> FieldValue {
        .map([
            "days": .int(Int64(instruction.days)),
            "anchor": windowAnchor.encode(instruction.anchor),
            "storage": .optional(instruction.storageType, storageType.encode),
        ])
    }

    static func instruction(_ field: FieldValue) throws -> PackageInstruction {
        let map = try field.map()
        return PackageInstruction(
            days: Int(try map["days"].required().int()),
            anchor: try windowAnchor.decode(map["anchor"]),
            storageType: try map["storage"].required().optional(storageType.decode)
        )
    }

    static func encode(_ value: PackageFieldValue) -> (field: FieldValue, value: FieldValue) {
        let encoded: FieldValue = switch value {
        case .name(let name): .string(name)
        case .productID(let id): .optional(id, \.field)
        case .printedDate(let printed): .optional(printed, encode)
        case .instruction(let instruction): .optional(instruction, encode)
        }
        return (packageField.encode(value.field), encoded)
    }

    static func packageFieldValue(field: FieldValue?, value: FieldValue?) throws -> PackageFieldValue {
        let value = try value.required()
        return switch try packageField.decode(field) {
        case .name: .name(try value.string())
        case .productID: .productID(try value.optional(ProductID.init(field:)))
        case .printedDate: .printedDate(try value.optional(printedDate))
        case .instruction: .instruction(try value.optional(instruction))
        }
    }
}
