import Foundation

/// A window is written as plain strings and a day count, so a data file can be read and checked by
/// eye. An unknown storage type or anchor is a decoding error and never a guess.
extension GuidanceWindow: Codable {
    private enum CodingKeys: String, CodingKey {
        case storageType, anchor, days
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storageName = try container.decode(String.self, forKey: .storageType)
        let anchorName = try container.decode(String.self, forKey: .anchor)
        guard let storage = Self.storageTypes[storageName] else {
            throw DecodingError.dataCorruptedError(
                forKey: .storageType, in: container, debugDescription: "Unknown storage type \(storageName)"
            )
        }
        guard let anchor = Self.anchors[anchorName] else {
            throw DecodingError.dataCorruptedError(
                forKey: .anchor, in: container, debugDescription: "Unknown anchor \(anchorName)"
            )
        }
        self.init(storageType: storage, anchor: anchor, days: try container.decode(Int.self, forKey: .days))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.name(of: storageType), forKey: .storageType)
        try container.encode(Self.name(of: anchor), forKey: .anchor)
        try container.encode(days, forKey: .days)
    }

    private static let storageTypes: [String: StorageType] = [
        "refrigerated": .refrigerated, "frozen": .frozen, "roomTemperature": .roomTemperature,
    ]
    private static let anchors: [String: WindowAnchor] = [
        "added": .added, "opened": .opened, "thawed": .thawed,
    ]

    private static func name(of storage: StorageType) -> String {
        switch storage {
        case .refrigerated: "refrigerated"
        case .frozen: "frozen"
        case .roomTemperature: "roomTemperature"
        }
    }

    private static func name(of anchor: WindowAnchor) -> String {
        switch anchor {
        case .added: "added"
        case .opened: "opened"
        case .thawed: "thawed"
        }
    }
}
