import Foundation

public enum ReplicaTag: Sendable {}
/// One installation's copy of a Space. Distinct from people: a person may have several replicas.
public typealias ReplicaID = Identifier<ReplicaTag>

/// A hybrid logical clock reading. Ordering compares physical milliseconds, then the counter, then
/// the replica, so two readings are equal only if they are the same reading.
public struct HybridTimestamp: Sendable, Hashable, Codable, Comparable {
    public let physicalMillis: Int64
    public let counter: Int
    public let replica: ReplicaID

    public init(physicalMillis: Int64, counter: Int, replica: ReplicaID) {
        self.physicalMillis = physicalMillis
        self.counter = counter
        self.replica = replica
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.physicalMillis != rhs.physicalMillis { return lhs.physicalMillis < rhs.physicalMillis }
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.replica.rawValue.uuidString < rhs.replica.rawValue.uuidString
    }
}

/// Issues readings that never decrease locally and always follow every reading this replica has
/// observed, whatever the device's wall clock says. Wall-clock agreement between devices only
/// affects which of two concurrent writes looks latest, never whether replicas converge.
public struct HybridClock: Sendable, Hashable, Codable {
    public private(set) var replica: ReplicaID
    private var physicalMillis: Int64 = .min
    private var counter = 0

    public init(replica: ReplicaID) {
        self.replica = replica
    }

    public mutating func tick(now: Date) -> HybridTimestamp {
        let physical = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        if physical > physicalMillis {
            physicalMillis = physical
            counter = 0
        } else {
            counter += 1
        }
        return HybridTimestamp(physicalMillis: physicalMillis, counter: counter, replica: replica)
    }

    /// True when `stamp` carries this clock's replica ID but is later than every reading this clock
    /// has issued or observed. Another installation is then issuing readings under the same ID,
    /// such as a device restored from this one's backup.
    public func wasIssuedElsewhere(_ stamp: HybridTimestamp) -> Bool {
        stamp.replica == replica
            && (stamp.physicalMillis, stamp.counter) > (physicalMillis, counter)
    }

    /// Continues under `replica`. Later readings still follow every earlier one.
    public mutating func adopt(_ replica: ReplicaID) {
        self.replica = replica
    }

    public mutating func observe(_ remote: HybridTimestamp) {
        if remote.physicalMillis > physicalMillis
            || (remote.physicalMillis == physicalMillis && remote.counter > counter) {
            physicalMillis = remote.physicalMillis
            counter = remote.counter
        }
    }
}
