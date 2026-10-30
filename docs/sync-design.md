# Pantrified Sync Design

How a shared Space converges across devices. Code: `Sources/PantrifiedDomain/Sync/` (clock, record schema, per-entity mapping) and `Sources/PantrifiedApplication/Sync/` (transport capability, replica engine). Verification is pure Swift tests on Linux against an in-memory transport; nothing here is compiled against the iOS SDK or exercised against CloudKit.

## Model

Each installation holds a **replica** of each Space it belongs to. A replica stores the Space as a set of records and is the local store for synchronized entities: `SpaceReplica` implements `InventoryRepository` and `ShoppingListRepository`, so saving a package or changing the list records the change for upload in the same atomic step. Reads are built from the merged records, so a local change and a remote change are never two competing copies of an entity.

The replica works fully offline. Sync is a separate step that pushes queued writes and pulls changes; it never blocks a local action.

## Clock

Every write carries a **hybrid logical clock** reading (`HybridTimestamp`): physical milliseconds, a counter, and the replica ID.

- Readings never decrease on a replica, even when the device clock goes backwards.
- On receipt of any record, the replica's clock moves past the record's latest stamp. A write made after seeing another write therefore always orders after it, whatever either device's wall clock says.
- Ordering compares milliseconds, then counter, then replica ID, so two different readings are never equal.
- The clock is persisted with the replica state, so a restarted replica never reissues a stamp.

A pure Lamport clock would also converge. The physical component keeps "latest" close to real time for concurrent writes on devices with roughly correct clocks, and it degrades to Lamport ordering when clocks disagree. Convergence never depends on clocks agreeing; only which of two concurrent writes looks latest does. Vector clocks were not chosen: they grow with the number of replicas and the merge rules here do not need to detect concurrency, only to order it deterministically.

## Record schema

A record (`SyncRecord`) has:

| Part | Meaning |
|---|---|
| `id` | Record kind (an open string) plus the app-owned entity UUID |
| `created` | Stamp of the first write. Orders events and list items. Merge keeps the minimum. |
| `minimumReaderVersion` | Readers below this must not interpret the record. Merge keeps the maximum. |
| `fields` | Name to `FieldEntry` (value plus stamp). Values are null, bool, int, double, string, date, UUID, list or map. |

`SyncFormat.version` is the format this build writes. Domain values use explicit string tags (for example `"usedUp"`, `"bestBy"`), so renaming a Swift case never changes stored data.

### Kinds

| Kind | Fields | Mutability |
|---|---|---|
| `package` | `space`, `addedAt`, `name`, `productID`, `printedDate`, `instruction`, `confirmed`, `location`, `quantity` | Written once: the package's creation facts |
| `packageEvent` | `package`, `at`, and either `change` (map with `type`) or `undoes` | Written once |
| `shoppingItem` | `name`, `category`, `quantity`, `addedAt`, `checkedAt`, `removed` | Field registers |
| `evidenceCrop` | `package`, `region`, `asset` | Written once |

### Forward compatibility

- Unknown fields and unknown record kinds are stored, merged and pushed unchanged. A local edit writes only the fields it changes, so a newer version's fields survive.
- A newer writer that adds something an older reader can safely ignore (an extra field, a new informational event type) leaves `minimumReaderVersion` alone. Older readers skip the unknown event type.
- A newer writer that adds something an older reader would misread (for example a new kind of removal) raises `minimumReaderVersion`. An older reader then withholds the whole entity and reports it (`SpaceReplica.unreadablePackages`) instead of showing a partial reading, such as a removed package as active.
- Local changes never write to a record the replica cannot read. This keeps an unreadable list item from being marked removed just because it could not be shown.

## Merge rules

Merging two copies of a record is a per-field choice: the entry with the later stamp wins, and equal stamps with different values fall back to a fixed value order. The result is the same in any order and any number of times. Entities then apply these rules on top:

| Field kind | Where | Rule |
|---|---|---|
| Write-once fact | `package` header, every `packageEvent`, `evidenceCrop` | Only ever written once with one stamp, so copies agree. |
| Grow-only event set | Package history | Replicas converge on the union of event records, folded in `created` order. |
| Last-writer register | Shopping item `name`, `category`, `quantity`, `checkedAt` | Later stamp wins, per field. Concurrent edits to different fields both survive. |
| Tombstone register | Shopping item `removed` | Removal sets it, restore clears it, later stamp wins. The record is never deleted. |
| Provenance-ranked field | Package `name`, `productID`, `printedDate`, `instruction` | Derived from the event fold: a `corrected` event beats any `recognized` event, before or after it. Among corrections, the later one wins. |

### Packages are event logs

A package never has conflicting records. Its creation facts are one immutable header, and every later change, including name corrections and recognition results, is an immutable event record. A replica that saves a stale copy of a package only adds events, so it cannot erase anyone else's change. The domain fold (`Package`) supplies all precedence; sync only supplies the union and the order.

Events whose package header has not arrived yet wait in the record set; the package appears when the header arrives.

### Shopping items are field registers

Local list changes are captured by comparing the changed list with the merged records inside one atomic repository update, then writing only the fields that differ. An item missing from the list is marked removed. An item that reappears after removal only clears `removed`: restore carries the item as it was when removed, and writing those fields back would undo edits made since.

## Precedence

- **Destructive lifecycle beats ordinary edits.** A package's status is the first effective Used up or Discarded event in fold order. An ordinary edit (move, quantity, open) never reactivates a package; it stays in history and applies if the removal is undone.
- **Undo is an event.** An undo marker names its target event and applies whenever it arrives, before or after the target. Two replicas undoing the same event both keep their markers; the result is one undo.
- **Each removal is undone separately.** If two devices remove the same package independently, undoing one leaves the package removed by the other. The history keeps both.
- **Tombstones are explicit.** Used up and Discarded are retained event records, and the package header is never deleted. Shopping removals are the `removed` register.
- **User corrections beat recognition.** A recognition result recorded on any device, at any time, never replaces a field the user corrected, until the correction itself is undone. Fields the user confirmed during draft review carry into the package as confirmed.

## Recognition and sync

Recognition and sync are independent. Recognition runs on the capturing device, produces proposals, and records them on the package as `recognized` events through `Package.propose`; sync carries those events like any other. No recognition job state is synchronized, and sync state (outbox, token, server tags) never affects recognition.

Drafts do not sync. They belong to device-local captures and become shared state only through put-away.

## Evidence

`EvidenceCrop` describes an app-generated crop kept with a package. A crop produces a record only when it is approved and not flagged by Sensitive Content Analysis; otherwise `SpaceReplica.share` records nothing. Full captures and imported photos have no record form at all. The record names the crop's asset; the transport adapter carries the image bytes.

## Transport

`SyncTransport` is the capability a CloudKit adapter implements, one zone per Space:

- `push` sends records with the server version last seen (`ServerTag`). The outcome is per record: saved, conflict (with the server's current version), or failed. A write the server stored but did not confirm is reported as failed and is safe to retry.
- `pull` returns a page of records after a `ChangeToken`, a new token, and whether more pages follow.

The replica assumes pushes can partly fail, and pulls can repeat records, reorder them, deliver an older version after a newer one, and split related records across pages.

## Sync and resume

`SpaceReplica.sync()` pushes, then pulls.

- **Push**: sends every record in the outbox. A saved record leaves the outbox only if it did not change while the push was in flight. A conflict merges the server version and retries in the next round of the same sync. Failed records stay queued.
- **Pull**: merges each page, stores each record's server tag, and saves the page's token in the same step. The pull stops after a page limit even if the server reports more; the next sync continues from the saved token.

The replica persists `ReplicaState` through `ReplicaStateStore` after every step, all or nothing:

| Field | Purpose |
|---|---|
| `records` | The merged record set, including unpushed local writes |
| `outbox` | Records holding writes the server has not confirmed |
| `serverTags` | Last server version seen per record, for conflict detection |
| `changeToken` | Where the next pull starts |
| `clock` | The last stamp issued or observed |

A crash at any point leaves the last completed step stored. On restart the replica re-pushes its outbox and pulls from its token. Both are idempotent: re-merging a record already held changes nothing, and re-pushing a stored record either saves the same content or conflicts and merges to the same content.

## Tests

- Domain: clock ordering under skew and regression; record merge as an order-insensitive, idempotent join over random deliveries; package and shopping mapping, including events before headers, unreadable records, and unknown fields.
- Engine: offline use and rejoin, partial push failure, unconfirmed writes, conflicts, writes during an in-flight push, pull failure and resume, page limits, crashes at each save during a sync, clock persistence across restart, hostile delivery, causal order against a lagging wall clock, delayed recognition after a correction, evidence eligibility, and records from a newer version.
- Convergence: every interleaving of operations and syncs for edit versus Used up, Discard and undo versus Used up, concurrent undo, and a three-device mix (1,260 schedules); and a seeded property test that replays the same offline edits through random sync orders and delivery faults and requires an identical final record set.

## Tradeoffs and limits

- **Histories grow.** Event records and tombstones are never compacted. A long-lived package or list keeps every record.
- **Whole-state saves.** The replica saves its entire state after each step. A SwiftData-backed store must make the same steps atomic incrementally.
- **Clock skew is unbounded.** A device whose clock runs far ahead wins concurrent register writes until others observe its readings. No drift limit is enforced.
- **Last-writer registers lose concurrent intent.** Two concurrent renames of one list item keep one name. Removal beats a concurrent check or uncheck; the item can be restored.
- **No duplicate merging.** Two devices adding the same item concurrently produce two items.
- **CloudKit mapping is not built.** Storing each field's stamp alongside its value in a `CKRecord`, mapping `serverRecordChanged` to a conflict outcome, zone and `CKShare` setup, asset upload, change-token expiry (which needs a full refetch), request size limits, and rate limiting are adapter work and unverified.
- **Not synchronized yet:** storage locations, ingredient links, consumer profiles and restrictions, preferences, Space membership, and deletion of Space data. Tests treat locations as fixed shared configuration.
- **Evidence removal is not implemented.** Crops are not yet removed when their package leaves active inventory, and approved crops have no removal record.

## Decisions for the owner

These follow the conservative reading of the accepted rules and are open to change:

1. **Independent removals are undone separately.** When two people remove the same package concurrently, undoing one removal leaves the package removed by the other.
2. **Concurrent Used up and Discard.** The earlier one by clock sets the status; both stay in history. Whether an overshadowed Discard counts toward Waste Insights is undecided.
3. **Shopping removal beats a concurrent check or uncheck.** The item stays removed and restorable.
4. **Concurrent duplicate list items are kept.** No automatic merge, consistent with conservative duplicate detection.
5. **Drafts stay on the capturing device.** Review and put-away happen where the capture was made.
6. **Corrections need an active package.** A used-up or discarded package refuses new corrections until its removal is undone.
