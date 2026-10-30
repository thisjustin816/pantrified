import Foundation

/// One food in a sourced storage-guidance dataset. `id` is the source's own identifier, so a record
/// can be traced back to the file it came from.
public struct GuidanceRecord: Sendable, Hashable, Codable {
    public let id: Int
    public let name: String
    /// What distinguishes this record from others of the same name, such as "plain or flavored".
    public let qualifier: String?
    public let category: String?
    /// Other names the source lists for the food.
    public let keywords: [String]
    public let windows: [GuidanceWindow]

    public init(
        id: Int, name: String, qualifier: String?, category: String?, keywords: [String], windows: [GuidanceWindow]
    ) {
        self.id = id
        self.name = name
        self.qualifier = qualifier
        self.category = category
        self.keywords = keywords
        self.windows = windows
    }
}

public enum GuidanceDatasetError: Error, Sendable, Hashable {
    case blankProvenance
    case invalidChecksum
    case duplicateID(Int)
    case invalidDays(record: Int)
    case blankName(record: Int)
}

/// A normalized, versioned snapshot of sourced storage guidance, such as the USDA FoodKeeper. It
/// is data the app bundles and replaces only in a release. Construction and decoding both validate
/// it, so a malformed snapshot cannot be used.
public struct GuidanceDataset: Sendable, Hashable, Codable {
    public struct Provenance: Sendable, Hashable, Codable {
        public let source: String
        /// The source's own version or modified date, when it states one.
        public let sourceVersion: String?
        /// SHA-256 of the source file the snapshot was normalized from, as hex.
        public let sourceChecksum: String?
        /// The version of Pantrified's normalization of the source.
        public let normalizationVersion: String

        public init(source: String, sourceVersion: String?, sourceChecksum: String?, normalizationVersion: String) {
            self.source = source
            self.sourceVersion = sourceVersion
            self.sourceChecksum = sourceChecksum
            self.normalizationVersion = normalizationVersion
        }
    }

    public let provenance: Provenance
    public let records: [GuidanceRecord]

    public init(provenance: Provenance, records: [GuidanceRecord]) throws {
        try Self.validate(provenance, records)
        self.provenance = provenance
        self.records = records
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            provenance: try container.decode(Provenance.self, forKey: .provenance),
            records: try container.decode([GuidanceRecord].self, forKey: .records)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case provenance, records
    }

    /// What the attention engine reports as the basis for a window, naming the source and both
    /// versions so a result can be traced to the snapshot it came from.
    public var attentionProvenance: GuidanceProvenance {
        GuidanceProvenance(
            source: provenance.source,
            version: "source \(provenance.sourceVersion ?? "unknown"), normalization \(provenance.normalizationVersion)"
        )
    }

    private static func validate(_ provenance: Provenance, _ records: [GuidanceRecord]) throws {
        let blank = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !blank(provenance.source), !blank(provenance.normalizationVersion) else {
            throw GuidanceDatasetError.blankProvenance
        }
        if let checksum = provenance.sourceChecksum,
           checksum.count != 64 || !checksum.allSatisfy(\.isHexDigit) {
            throw GuidanceDatasetError.invalidChecksum
        }

        var seen: Set<Int> = []
        for record in records {
            guard seen.insert(record.id).inserted else { throw GuidanceDatasetError.duplicateID(record.id) }
            guard !IngredientName(record.name).isEmpty else { throw GuidanceDatasetError.blankName(record: record.id) }
            guard record.windows.allSatisfy({ $0.days > 0 }) else { throw GuidanceDatasetError.invalidDays(record: record.id) }
        }
    }
}
