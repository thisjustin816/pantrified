import Foundation

/// What a date printed on a package claims to mean. Kept as read from the label; never rewritten
/// into a single expiration date.
public enum PrintedDateLabel: Sendable, Hashable, Codable {
    case useBy
    case bestBy
    case sellBy
    case freezeBy
    case packed
    case unlabeled
}

public struct PrintedDate: Sendable, Hashable, Codable {
    public var label: PrintedDateLabel
    public var date: Date

    public init(label: PrintedDateLabel, date: Date) {
        self.label = label
        self.date = date
    }
}
