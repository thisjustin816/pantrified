import Foundation

/// One record per shopping item, each field an independent register. Removal is a `removed`
/// register rather than a deleted record, so a removal and a concurrent edit both survive and a
/// restore brings the edited item back.
public enum ShoppingRecords {
    private struct Stored {
        let record: SyncRecord
        let item: ShoppingItem
        let removed: Bool
    }

    public static func materialize(
        from records: RecordSet,
        readerVersion: Int = SyncFormat.version
    ) -> ShoppingList {
        ShoppingList(items: stored(in: records, readerVersion: readerVersion)
            .filter { !$0.removed }
            .sorted { $0.record.precedes($1.record) }
            .map(\.item))
    }

    /// Field writes that turn the stored items into `list`. An item missing from `list` is marked
    /// removed. Records this version cannot read are never written: they are absent from `list`
    /// only because they could not be shown, not because anyone removed them.
    public static func changes(
        from list: ShoppingList,
        against records: RecordSet,
        readerVersion: Int = SyncFormat.version,
        stamp: () -> HybridTimestamp
    ) -> [SyncRecord] {
        let known = Dictionary(
            uniqueKeysWithValues: stored(in: records, readerVersion: readerVersion).map { ($0.item.id, $0) }
        )
        var changes: [SyncRecord] = []

        for item in list.items {
            let id = recordID(item.id)
            guard let existing = known[item.id] else {
                if records[id] == nil {
                    changes.append(SyncRecord(id: id, writing: fields(item, removed: false), at: stamp()))
                }
                continue
            }
            // A removed item can only reappear through restore, which carries the item as it was
            // when removed; writing those fields back would undo edits made since by others.
            let changed = existing.removed
                ? ["removed": .bool(false)]
                : fields(item, removed: false).filter { name, value in
                    name != "addedAt" && existing.record.value(name) != value
                }
            if !changed.isEmpty {
                changes.append(SyncRecord(id: id, writing: changed, at: stamp(), created: existing.record.created))
            }
        }

        let present = Set(list.items.map(\.id))
        for entry in known.values.sorted(by: { $0.record.precedes($1.record) })
        where !entry.removed && !present.contains(entry.item.id) {
            changes.append(SyncRecord(
                id: entry.record.id, writing: ["removed": .bool(true)], at: stamp(), created: entry.record.created
            ))
        }
        return changes
    }

    private static func recordID(_ id: ShoppingItemID) -> RecordID {
        RecordID(kind: .shoppingItem, entity: id.rawValue)
    }

    private static func fields(_ item: ShoppingItem, removed: Bool) -> [String: FieldValue] {
        [
            "name": .string(item.name),
            "category": .optional(item.category, FieldValue.string),
            "quantity": .optional(item.quantity, FieldValue.string),
            "addedAt": .date(item.addedAt),
            "checkedAt": .optional(item.checkedAt, FieldValue.date),
            "removed": .bool(removed),
        ]
    }

    private static func stored(in records: RecordSet, readerVersion: Int) -> [Stored] {
        records.records(of: .shoppingItem).compactMap { record in
            guard record.minimumReaderVersion <= readerVersion else { return nil }
            do {
                let item = ShoppingItem(
                    id: ShoppingItemID(record.id.entity),
                    name: try record.value("name").required().string(),
                    category: try record.value("category").required().optional { try $0.string() },
                    quantity: try record.value("quantity").required().optional { try $0.string() },
                    addedAt: try record.value("addedAt").required().date(),
                    checkedAt: try record.value("checkedAt").required().optional { try $0.date() }
                )
                return Stored(record: record, item: item, removed: try record.value("removed").required().bool())
            } catch {
                return nil
            }
        }
    }
}
