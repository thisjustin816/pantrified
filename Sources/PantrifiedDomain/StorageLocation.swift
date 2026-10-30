import Foundation

public enum StorageType: Sendable, Hashable, Codable {
    case refrigerated
    case frozen
    case roomTemperature
}

public struct StorageLocation: Sendable, Hashable, Codable, Identifiable {
    public let id: LocationID
    public var name: String
    public var storageType: StorageType

    public init(id: LocationID = LocationID(), name: String, storageType: StorageType) {
        self.id = id
        self.name = name
        self.storageType = storageType
    }
}
