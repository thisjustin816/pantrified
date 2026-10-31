import Foundation

/// Why stored data cannot be used. Every case leaves the stored data where it is: nothing in this
/// module deletes or replaces a store it cannot read.
public enum PersistenceError: Error, Sendable, Equatable {
    /// The store exists but could not be opened, or its directory could not be prepared.
    case cannotOpen(String)
    /// The store was last opened by a version of the app with a newer schema.
    case newerSchema(found: Int, supported: Int)
    /// A stored value was written in a newer encoding than this version reads.
    case newerFormat(found: Int, supported: Int)
    /// A stored value cannot be decoded.
    case corrupt(String)
}
