import Foundation
import PantrifiedApplication
import PantrifiedDomain

/// The app's durable stores over one backend. It hands out a single replica per Space, because two
/// replicas writing one Space's rows would each replace the other's queue, server tags and clock.
public final class LocalStore: @unchecked Sendable {
    public let backend: any StorageBackend
    private let lock = NSLock()
    /// Guarded by `lock`.
    private var replicas: [SpaceID: SpaceReplica] = [:]

    public init(backend: any StorageBackend) {
        self.backend = backend
    }

    /// The Space's replica, opened from storage on first use. Later calls return the same replica
    /// and ignore their `transport` and `time`.
    public func replica(for space: SpaceID, transport: any SyncTransport, time: any TimeSource) throws -> SpaceReplica {
        try lock.withLock {
            if let open = replicas[space] { return open }
            let replica = try SpaceReplica(
                space: space, replica: ReplicaID(), transport: transport,
                store: PersistentReplicaStateStore(space: space, backend: backend), time: time
            )
            replicas[space] = replica
            return replica
        }
    }

    public var locations: PersistentLocations { PersistentLocations(backend: backend) }
    public var ingredientLinks: PersistentIngredientLinks { PersistentIngredientLinks(backend: backend) }
}
