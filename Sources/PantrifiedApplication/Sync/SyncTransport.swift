import Foundation
import PantrifiedDomain

/// Where the server is in a zone's change history. Opaque to the replica.
public struct ChangeToken: Sendable, Hashable, Codable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// The server's version of one record, presented back on the next push so the server can detect a
/// write the replica has not seen.
public struct ServerTag: Sendable, Hashable, Codable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct OutgoingRecord: Sendable, Hashable {
    public let record: SyncRecord
    /// Nil when the replica has never seen a server version of the record.
    public let knownTag: ServerTag?

    public init(record: SyncRecord, knownTag: ServerTag?) {
        self.record = record
        self.knownTag = knownTag
    }
}

public enum PushOutcome: Sendable, Hashable {
    case saved(ServerTag)
    /// The server holds a version the replica has not seen. Nothing was written.
    case conflict(current: SyncRecord, tag: ServerTag)
    /// Not written, or not confirmed. Retrying is always safe.
    case failed
}

public struct PulledRecord: Sendable, Hashable {
    public let record: SyncRecord
    public let tag: ServerTag

    public init(record: SyncRecord, tag: ServerTag) {
        self.record = record
        self.tag = tag
    }
}

public struct PullPage: Sendable, Hashable {
    public let records: [PulledRecord]
    /// Resuming from this token continues after this page.
    public let token: ChangeToken
    public let moreComing: Bool

    public init(records: [PulledRecord], token: ChangeToken, moreComing: Bool) {
        self.records = records
        self.token = token
        self.moreComing = moreComing
    }
}

/// A Space's shared store, one zone per Space. The replica assumes nothing about delivery beyond
/// this contract: pushes may partly fail or succeed without confirmation, and pulls may repeat
/// records, deliver them in any order, deliver an older version after a newer one, and split
/// related records across pages.
public protocol SyncTransport: Sendable {
    /// Outcomes are per record; a record without an outcome is treated as failed.
    func push(_ records: [OutgoingRecord], zone: SpaceID) async throws -> [RecordID: PushOutcome]
    /// Changes after `token`, or every record when `token` is nil.
    func pull(zone: SpaceID, since token: ChangeToken?) async throws -> PullPage
}
