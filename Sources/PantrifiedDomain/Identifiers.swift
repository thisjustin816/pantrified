import Foundation

/// App-owned identity. CloudKit and SwiftData identifiers map onto these; they are never the identity.
public struct Identifier<Entity>: Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum SpaceTag: Sendable {}
public enum ProductTag: Sendable {}
public enum PackageTag: Sendable {}
public enum LocationTag: Sendable {}
public enum PackageEventTag: Sendable {}

public typealias SpaceID = Identifier<SpaceTag>
public typealias ProductID = Identifier<ProductTag>
public typealias PackageID = Identifier<PackageTag>
public typealias LocationID = Identifier<LocationTag>
public typealias PackageEventID = Identifier<PackageEventTag>
