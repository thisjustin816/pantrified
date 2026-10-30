import Foundation

public enum Materialized<Entity: Sendable>: Sendable {
    case entity(Entity)
    /// Records arrived before the one that defines the entity, such as events before their package.
    case incomplete
    /// A record needs a newer reader or cannot be decoded. Showing a partial reading could present
    /// a removed package as active, so the entity is withheld instead.
    case unreadable

    public var entity: Entity? {
        if case .entity(let entity) = self { return entity }
        return nil
    }
}

/// A package is one immutable header record holding its creation facts plus one immutable record
/// per event. Records never conflict: replicas converge on the union of events, folded in creation
/// stamp order, and the domain fold supplies destructive precedence and correction precedence.
public enum PackageRecords {
    private enum Event {
        case known(PackageEvent)
        /// Written by a newer version that declared it safe for older readers to skip.
        case ignorable
    }

    /// Records for whatever in `package` the set does not hold yet: the header the first time, then
    /// each new event in history order, so local order is preserved by increasing stamps.
    public static func changes(
        in package: Package,
        against records: RecordSet,
        stamp: () -> HybridTimestamp
    ) -> [SyncRecord] {
        var changes: [SyncRecord] = []
        let headerID = RecordID(kind: .package, entity: package.id.rawValue)
        if records[headerID] == nil {
            changes.append(SyncRecord(id: headerID, writing: header(package), at: stamp()))
        }
        for event in package.events {
            let id = RecordID(kind: .packageEvent, entity: event.id.rawValue)
            guard records[id] == nil else { continue }
            changes.append(SyncRecord(id: id, writing: encode(event, of: package.id), at: stamp()))
        }
        return changes
    }

    public static func materialize(
        _ id: PackageID,
        from records: RecordSet,
        readerVersion: Int = SyncFormat.version
    ) -> Materialized<Package> {
        let events = records.records(of: .packageEvent).filter { $0.value("package") == id.field }
        return materialize(id, header: records[RecordID(kind: .package, entity: id.rawValue)], events: events, readerVersion: readerVersion)
    }

    /// Every package with a record in the set, whether or not it can be built yet.
    public static func materializeAll(
        from records: RecordSet,
        readerVersion: Int = SyncFormat.version
    ) -> [PackageID: Materialized<Package>] {
        var eventsByPackage: [PackageID: [SyncRecord]] = [:]
        for event in records.records(of: .packageEvent) {
            guard let owner = try? PackageID(field: event.value("package").required()) else { continue }
            eventsByPackage[owner, default: []].append(event)
        }
        let headerIDs = records.records(of: .package).map { PackageID($0.id.entity) }
        var result: [PackageID: Materialized<Package>] = [:]
        for id in Set(headerIDs).union(eventsByPackage.keys) {
            result[id] = materialize(
                id,
                header: records[RecordID(kind: .package, entity: id.rawValue)],
                events: eventsByPackage[id] ?? [],
                readerVersion: readerVersion
            )
        }
        return result
    }

    private static func materialize(
        _ id: PackageID,
        header: SyncRecord?,
        events: [SyncRecord],
        readerVersion: Int
    ) -> Materialized<Package> {
        guard let header else { return .incomplete }
        guard ([header] + events).allSatisfy({ $0.minimumReaderVersion <= readerVersion }) else {
            return .unreadable
        }
        do {
            let ordered = events.sorted { $0.created < $1.created }
            let history = try ordered.compactMap { record -> PackageEvent? in
                if case .known(let event) = try decodeEvent(record) { return event }
                return nil
            }
            return .entity(try decodeHeader(header, id: id, events: history))
        } catch {
            return .unreadable
        }
    }

    // MARK: Header

    private static func header(_ package: Package) -> [String: FieldValue] {
        let origin = package.origin
        return [
            "space": package.spaceID.field,
            "addedAt": .date(package.addedAt),
            "name": .string(origin.details.name),
            "productID": .optional(origin.details.productID, \.field),
            "printedDate": .optional(origin.details.printedDate, DomainCoding.encode),
            "instruction": .optional(origin.details.instruction, DomainCoding.encode),
            "confirmed": .list(origin.confirmed.map(DomainCoding.packageField.tag).sorted().map(FieldValue.string)),
            "location": origin.location.field,
            "quantity": DomainCoding.encode(origin.quantity),
        ]
    }

    private static func decodeHeader(_ record: SyncRecord, id: PackageID, events: [PackageEvent]) throws -> Package {
        guard case .list(let confirmed) = record.value("confirmed") else { throw RecordDecodingError() }
        return Package(
            id: id,
            spaceID: try SpaceID(field: record.value("space").required()),
            productID: try record.value("productID").required().optional(ProductID.init(field:)),
            name: try record.value("name").required().string(),
            location: try LocationID(field: record.value("location").required()),
            quantity: try DomainCoding.quantity(record.value("quantity").required()),
            printedDate: try record.value("printedDate").required().optional(DomainCoding.printedDate),
            instruction: try record.value("instruction").required().optional(DomainCoding.instruction),
            // A field a newer version added is not one this version can protect, so it is skipped.
            confirmed: Set(confirmed.compactMap(DomainCoding.packageField.decodeIfKnown)),
            addedAt: try record.value("addedAt").required().date(),
            events: events
        )
    }

    // MARK: Events

    private static func encode(_ event: PackageEvent, of package: PackageID) -> [String: FieldValue] {
        var fields: [String: FieldValue] = ["package": package.field, "at": .date(event.at)]
        switch event.kind {
        case .undone(let target): fields["undoes"] = target.field
        case .change(let change): fields["change"] = encode(change)
        }
        return fields
    }

    private static func encode(_ change: PackageChange) -> FieldValue {
        func type(_ name: String, _ payload: [String: FieldValue] = [:]) -> FieldValue {
            .map(payload.merging(["type": .string(name)]) { $1 })
        }
        switch change {
        case .opened: return type("opened")
        case .moved(let destination): return type("moved", ["to": destination.field])
        case .frozen: return type("frozen")
        case .thawed: return type("thawed")
        case .quantityChanged(let quantity): return type("quantityChanged", ["quantity": DomainCoding.encode(quantity)])
        case .usedSome(let quantity): return type("usedSome", ["quantity": DomainCoding.encode(quantity)])
        case .confirmedPresent: return type("confirmedPresent")
        case .usedUp: return type("usedUp")
        case .discarded(let reason):
            return type("discarded", ["reason": .optional(reason, DomainCoding.discardReason.encode)])
        case .corrected(let value):
            let encoded = DomainCoding.encode(value)
            return type("corrected", ["field": encoded.field, "value": encoded.value])
        case .recognized(let value):
            let encoded = DomainCoding.encode(value)
            return type("recognized", ["field": encoded.field, "value": encoded.value])
        }
    }

    private static func decodeEvent(_ record: SyncRecord) throws -> Event {
        let id = PackageEventID(record.id.entity)
        let at = try record.value("at").required().date()
        if let target = record.value("undoes") {
            return .known(PackageEvent(id: id, at: at, kind: .undone(try PackageEventID(field: target))))
        }
        let map = try record.value("change").required().map()
        let change: PackageChange
        switch try map["type"].required().string() {
        case "opened": change = .opened
        case "moved": change = .moved(to: try LocationID(field: map["to"].required()))
        case "frozen": change = .frozen
        case "thawed": change = .thawed
        case "quantityChanged": change = .quantityChanged(try DomainCoding.quantity(map["quantity"].required()))
        case "usedSome": change = .usedSome(resulting: try DomainCoding.quantity(map["quantity"].required()))
        case "confirmedPresent": change = .confirmedPresent
        case "usedUp": change = .usedUp
        case "discarded":
            change = .discarded(reason: try map["reason"].required().optional(DomainCoding.discardReason.decode))
        case "corrected":
            change = .corrected(try DomainCoding.packageFieldValue(field: map["field"], value: map["value"]))
        case "recognized":
            change = .recognized(try DomainCoding.packageFieldValue(field: map["field"], value: map["value"]))
        default:
            // Only reached when the record's minimum reader version admits this reader.
            return .ignorable
        }
        return .known(PackageEvent(id: id, at: at, kind: .change(change)))
    }
}
