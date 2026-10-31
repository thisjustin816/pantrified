import Foundation
import PantrifiedApplication
import PantrifiedDomain

/// Storage locations kept on this device, per Space. Each is stored under its app-owned ID with its
/// name, storage type tag and the position it was first saved at, which orders the list.
public struct PersistentLocations: StorageLocationStore {
    private let backend: any StorageBackend

    public init(backend: any StorageBackend) {
        self.backend = backend
    }

    public func locations(in space: SpaceID) async throws -> [StorageLocation] {
        try stored(in: space)
            .sorted { ($0.position, $0.location.id.rawValue.uuidString) < ($1.position, $1.location.id.rawValue.uuidString) }
            .map(\.location)
    }

    /// Adds a location, or changes the name or type of one already stored and keeps its position.
    /// Two locations added at once can share a position; their IDs then order them.
    public func save(_ location: StorageLocation, in space: SpaceID) async throws {
        try await saveAll([location], in: space)
    }

    /// Adds or changes several locations in one write. New ones take the next positions in order.
    public func saveAll(_ locations: [StorageLocation], in space: SpaceID) async throws {
        let existing = try stored(in: space)
        var next = (existing.map(\.position).max() ?? -1) + 1
        var batch = StorageBatch()
        for location in locations {
            let position: Int64
            if let known = existing.first(where: { $0.location.id == location.id }) {
                position = known.position
            } else {
                position = next
                next += 1
            }
            batch.localWrites[Self.key(location.id, in: space)] = .put(StoredValueCoding.encode(.map([
                "name": .string(location.name),
                "storageType": .string(location.storageType.storedTag),
                "position": .int(position),
            ])))
        }
        try backend.write(batch)
    }

    private static func key(_ id: LocationID, in space: SpaceID) -> LocalRowKey {
        LocalRowKey(kind: .location, space: space, entity: id.rawValue.uuidString)
    }

    private func stored(in space: SpaceID) throws -> [(location: StorageLocation, position: Int64)] {
        try backend.localRows(of: .location, in: space).map { row throws(PersistenceError) in
            guard let id = UUID(uuidString: row.key.entity),
                  case .map(let fields) = try StoredValueCoding.value(from: row.payload),
                  case .string(let name)? = fields["name"],
                  case .string(let tag)? = fields["storageType"],
                  case .int(let position)? = fields["position"]
            else { throw .corrupt("an unreadable location") }
            guard let type = StorageType(storedTag: tag) else { throw .corrupt("an unknown storage type \(tag)") }
            return (StorageLocation(id: LocationID(id), name: name, storageType: type), position)
        }
    }
}

/// Ingredient links kept on this device, per Space. A link is identified by its two names, so
/// confirming it again stores nothing new.
public struct PersistentIngredientLinks: IngredientLinkRepository {
    private let backend: any StorageBackend

    public init(backend: any StorageBackend) {
        self.backend = backend
    }

    public func links(in space: SpaceID) async throws -> Set<IngredientLink> {
        Set(try backend.localRows(of: .ingredientLink, in: space).map { row throws(PersistenceError) in
            guard case .map(let fields) = try StoredValueCoding.value(from: row.payload),
                  case .string(let ingredient)? = fields["ingredient"],
                  case .string(let inventory)? = fields["inventory"]
            else { throw .corrupt("an unreadable ingredient link") }
            return IngredientLink(ingredient: IngredientName(ingredient), inventoryName: IngredientName(inventory))
        })
    }

    public func confirm(_ link: IngredientLink, in space: SpaceID) async throws {
        var batch = StorageBatch()
        // Normalized names hold only letters, digits and spaces, so a line break separates them.
        let key = LocalRowKey(kind: .ingredientLink, space: space, entity: "\(link.ingredient.text)\n\(link.inventoryName.text)")
        batch.localWrites[key] = .put(StoredValueCoding.encode(.map([
            "ingredient": .string(link.ingredient.text),
            "inventory": .string(link.inventoryName.text),
        ])))
        try backend.write(batch)
    }
}
