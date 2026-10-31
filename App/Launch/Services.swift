import Foundation
import PantrifiedApplication
import PantrifiedDomain

/// Reads the real clock.
struct SystemTime: TimeSource {
    func now() -> Date { Date() }
}

/// The transport until sync exists: every attempt fails as if the device were offline, so a replica
/// built on it keeps everything it is given in the local store and queues it.
struct OfflineTransport: SyncTransport {
    struct Unreachable: Error {}

    func push(_ records: [OutgoingRecord], zone: SpaceID) async throws -> [RecordID: PushOutcome] { throw Unreachable() }
    func pull(zone: SpaceID, since token: ChangeToken?) async throws -> PullPage { throw Unreachable() }
}

/// Storage guidance for a build whose bundled snapshot cannot be read. Nothing is guessed: food
/// then has attention only from its printed date.
struct NoGuidance: StorageGuidanceRepository {
    func guidance(for package: Package) async throws -> StorageGuidance? { nil }
}
