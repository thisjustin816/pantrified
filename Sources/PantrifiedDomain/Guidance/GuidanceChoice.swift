import Foundation

/// A record of a sourced guidance dataset as the person saw it when they chose it. The name and
/// qualifier are kept beside the identifier so that a later snapshot which gives the identifier to a
/// different food, or drops the record, is recognized and the choice is not applied to the wrong food.
public struct GuidanceRecordReference: Sendable, Hashable, Codable {
    /// The dataset's source, such as "USDA FSIS FoodKeeper".
    public let source: String
    public let id: Int
    public let name: String
    public let qualifier: String?

    public init(source: String, id: Int, name: String, qualifier: String?) {
        self.source = source
        self.id = id
        self.name = name
        self.qualifier = qualifier
    }

    public init(_ record: GuidanceRecord, source: String) {
        self.init(source: source, id: record.id, name: record.name, qualifier: record.qualifier)
    }

    /// Whether `record` from a dataset with `source` is the record this names: same source, same
    /// identifier, same name and qualifier.
    public func names(_ record: GuidanceRecord, source: String) -> Bool {
        self.source == source && id == record.id && name == record.name && qualifier == record.qualifier
    }
}

/// Which record of the sourced guidance a person says one food is.
public enum GuidanceChoice: Sendable, Hashable, Codable {
    case record(GuidanceRecordReference)
    /// None of the records offered is this food, so it gets no sourced guidance.
    case noneOfThese
}
