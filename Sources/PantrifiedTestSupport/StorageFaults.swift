import Foundation
import PantrifiedDomain
import PantrifiedPersistence

public struct InducedFailure: Error, Equatable {
    public init() {}
}

/// Passes reads and writes through to `inner`, failing writes on request. A failed write never
/// reaches `inner`, as a process killed before its transaction commits leaves the store as it was.
/// With `reportFailureAfterCommit`, a write reaches `inner` and then throws, as a save that
/// committed but could not confirm it.
public final class FaultyBackend: StorageBackend, @unchecked Sendable {
    public let inner: any StorageBackend
    private let lock = NSLock()
    private var failing: @Sendable (Int) -> Bool = { _ in false }
    private var afterCommit = false
    private var attempts = 0
    private var committed: [StorageBatch] = []

    public init(_ inner: any StorageBackend) {
        self.inner = inner
    }

    /// Counting write attempts from zero from now on, fails attempt `count` and every later one.
    /// Nil stops failing.
    public func failWrites(after count: Int?) {
        failWrites { attempt in count.map { attempt >= $0 } ?? false }
    }

    /// Counting write attempts from zero from now on, fails each attempt `decide` picks.
    public func failWrites(where decide: @escaping @Sendable (Int) -> Bool) {
        lock.withLock {
            attempts = 0
            failing = decide
        }
    }

    public func reportFailureAfterCommit(_ value: Bool) {
        lock.withLock { afterCommit = value }
    }

    /// Every batch that reached `inner`, in order.
    public var committedBatches: [StorageBatch] { lock.withLock { committed } }

    public func replicaRows(in space: SpaceID) throws -> StoredReplicaRows {
        try inner.replicaRows(in: space)
    }

    public func localRows(of kind: LocalRowKind, in space: SpaceID) throws -> [LocalRow] {
        try inner.localRows(of: kind, in: space)
    }

    public func write(_ batch: StorageBatch) throws {
        let (fail, confirmFails) = lock.withLock {
            defer { attempts += 1 }
            return (failing(attempts), afterCommit)
        }
        if fail { throw InducedFailure() }
        try inner.write(batch)
        lock.withLock { committed.append(batch) }
        if confirmFails { throw InducedFailure() }
    }
}

/// The backends durable tests run against. Each `makeBackend` call returns an empty store.
public enum TestStorage: String, CaseIterable, Sendable {
    case memory

    public func makeBackend() throws -> any StorageBackend {
        switch self {
        case .memory:
            return InMemoryStorageBackend()
        }
    }
}
