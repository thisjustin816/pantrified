# Pantrified Sync Design

How a shared Space converges across devices. Code: `Sources/PantrifiedDomain/Sync/` (clock, record schema, per-entity mapping) and `Sources/PantrifiedApplication/Sync/` (transport capability, replica engine). Verification is pure Swift tests on Linux against an in-memory transport; nothing here is compiled against the iOS SDK or exercised against CloudKit.

## Model

Each installation holds a **replica** of each Space it belongs to. A replica stores the Space as a set of records and is the local store for synchronized entities: `SpaceReplica` implements `InventoryRepository` and `ShoppingListRepository`, so saving a package or changing the list records the change for upload in the same atomic step. Reads are built from the merged records, so a local change and a remote change are never two competing copies of an entity.

The replica works fully offline. Sync is a separate step that pushes queued writes and pulls changes; it never blocks a local action.

## Clock

Every write carries a **hybrid logical clock** reading (`HybridTimestamp`): physical milliseconds, a counter, and the replica ID.

- Readings never decrease on a replica, even when the device clock goes backwards.
- On receipt of any record, the replica's clock moves past the record's latest stamp. A write made after seeing another write therefore always orders after it, whatever either device's wall clock says.
- Ordering compares milliseconds, then counter, then replica ID. Replicas with different IDs never issue equal readings.
- The clock is persisted with the replica state, so a restarted replica never reissues a stamp.
- A received counter at its largest value carries into the milliseconds instead of overflowing. At the largest possible reading the clock repeats that reading.

A pure Lamport clock would also converge. The physical component keeps "latest" close to real time for concurrent writes on devices with roughly correct clocks, and it degrades to Lamport ordering when clocks disagree. Convergence never depends on clocks agreeing; only which of two concurrent writes looks latest does. Vector clocks were not chosen: they grow with the number of replicas and the merge rules here do not need to detect concurrency, only to order it deterministically.

### Shared replica IDs

Two installations can hold the same replica ID and clock: a phone restored from a backup or migrated while the old device stays in use, or two processes running one replica's state. They can then issue equal stamps for different writes. Convergence does not depend on stamps being unique:

- Events and list items with equal creation stamps are ordered by record ID.
- Different values written to one field with equal stamps are decided by a fixed order on values.

A replica that receives a stamp carrying its own ID, later than every reading its clock has issued or observed, knows another installation is using that ID and takes a new one (`HybridClock.wasIssuedElsewhere`). Stamps arriving in one pull page are all checked before any is observed. A false positive only costs a new ID.

Detection is partial. A restored state is identical to the original's state at backup time, so nothing a replica persists tells it at restore that it is a copy. The twin is found only when one of its writes arrives with a stamp later than anything the receiving replica has issued or observed. Until then both can write equal stamps, which the tie-breaks above keep convergent. Detecting the restore at launch would need a marker stored outside the replica state that a backup does not carry; none is built.

## Record schema

A record (`SyncRecord`) has:

| Part | Meaning |
|---|---|
| `id` | Record kind (an open string) plus the app-owned entity UUID |
| `created` | Stamp of the first write. Orders events and list items, with the record ID breaking ties. Merge keeps the minimum. |
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

An addition is ignorable when an older reader that skips it shows every field it displays, and every lifecycle outcome, as a reader that understands it would. Anything else could be misread.

Unknown fields and unknown record kinds are always stored, merged and pushed unchanged. A local edit writes only the fields it changes, and a package save only adds records, so a newer version's data survives an older reader. A skipped record stays in the set and reaches every other replica.

Ignorable additions. A newer writer leaves `minimumReaderVersion` alone, and an older reader skips them:

- A new field on any record.
- A new record kind.
- A new event type that changes nothing an older reader shows.
- A `corrected` or `recognized` event naming a field this version does not know. The event changes only that field, so it is skipped and the package stays readable.
- An unknown field tag in a package header's `confirmed` list.

The person's choice of storage-guidance record (`guidanceRecord`, `storage-guidance.md`) was added as
such a correction, without raising `minimumReaderVersion`. A version before it skips the choice and
matches the food by its name. It shows nothing else differently, but for a name that matches one record
it shows that record's guidance even where the person chose another record or None of these.
Raising it instead would withhold the whole package from such a version.

Additions an older reader would misread. A newer writer raises `minimumReaderVersion`:

- A new event type that changes status, location, quantity, the opened, frozen or thawed state, or a field this version shows, such as a new kind of removal.
- A new value inside a field this version knows: a discard reason, quantity level, printed date label, window anchor or storage type.
- A new encoding of a known field's value, including a correction or recognition of a known field.

An older reader withholds the whole entity when a record needs a newer reader, and also when a record holds a value it cannot decode in a known position even though the writer did not raise `minimumReaderVersion`. Showing a partial reading could present a removed package as active. Withheld packages are reported through `SpaceReplica.unreadablePackages`.

Local changes never write to a record the replica cannot read. This keeps an unreadable list item from being marked removed just because it could not be shown.

## Merge rules

Merging two copies of a record is a per-field choice: the entry with the later stamp wins, and equal stamps with different values fall back to a fixed value order. Values are equal only when stored identically: strings by their UTF-8 bytes, doubles and dates by their bit patterns. Two encodings of one accented string, or 0 and -0, are different values, and NaN equals itself. The result is the same in any order and any number of times, down to the stored form of each value.

The value order and the record ID order used for ties are part of the record format. Every version must apply them unchanged, or replicas on different versions would settle ties differently.

Entities then apply these rules on top:

| Field kind | Where | Rule |
|---|---|---|
| Write-once fact | `package` header, every `packageEvent`, `evidenceCrop` | Only ever written once with one stamp, so copies agree. |
| Grow-only event set | Package history | Replicas converge on the union of event records, folded in `created` order, then record ID order. |
| Last-writer register | Shopping item `name`, `category`, `quantity`, `checkedAt` | Later stamp wins, per field. Concurrent edits to different fields both survive. |
| Tombstone register | Shopping item `removed` | Removal sets it, restore clears it, later stamp wins. At equal stamps removal wins. The record is never deleted. |
| Provenance-ranked field | Package `name`, `productID`, `printedDate`, `instruction`, `guidanceRecord` | Derived from the event fold: a `corrected` event beats any `recognized` event, before or after it. Among corrections, the later one wins. |

### Packages are event logs

A package never has conflicting records. Its creation facts are one immutable header, and every later change, including name corrections and recognition results, is an immutable event record. A replica that saves a stale copy of a package only adds events, so it cannot erase anyone else's change. The domain fold (`Package`) supplies all precedence; sync only supplies the union and the order.

`InventoryRepository` makes the same rule a contract for every package store: the first save of a package ID stores its creation facts, and a later save only adds events the store does not hold. Use cases read a package, change it and save it in separate steps, with other awaits in between (Package Actions looks up locations before saving a move), so a store that replaced whole packages would lose a change saved in that gap. `InventoryContractTests` runs the contract against the in-memory store, the replica, and the replica stored through each persistence backend (`persistence.md`), and any new store must pass it.

A check a use case makes on its copy, such as whether the package is still active or already opened, can be stale. The worst case is an event a fresh read would have refused, such as a second opening or a move after a removal. The fold already resolves those, because two devices can record the same events concurrently. An atomic read-change-save on the repository was not chosen: it would not remove that case across devices, every store would have to hold a transaction across the use case, and the replica already gets the guarantee from its records.

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

- Domain: clock ordering under skew and regression, and at the largest counter and reading; record merge as an order-insensitive, idempotent join over random deliveries; equal stamps with structured values and with values Swift equality cannot tell apart; package and shopping mapping, including events before headers, unreadable records, unknown fields, corrections of unknown fields, and unreadable values in known fields; every arrival order of packages, list items and crops with equal creation stamps, and seeded random histories with colliding stamps.
- Engine: offline use and rejoin, partial push failure, unconfirmed writes, conflicts, writes during an in-flight push, pull failure and resume, page limits, crashes at each save during a sync, clock persistence across restart, hostile delivery, causal order against a lagging wall clock, delayed recognition after a correction, evidence eligibility, records from a newer version, a skipped correction passed on unchanged, a NaN date that is not uploaded again, and two devices restored from one backup: equal-stamp removals, their undo, and detection of the shared ID.
- Inventory contract: stale saves, creation facts written once, concurrent actions, Mark Cooked against an action, recognition against a correction, and a change saved during a move's location lookup, each against the in-memory store, the replica, and the stored replica.
- Convergence: every interleaving of operations and syncs for edit versus Used up, Discard and undo versus Used up, concurrent undo, and a three-device mix (1,260 schedules); and a seeded property test that replays the same offline edits through random sync orders and delivery faults and requires an identical final record set.

## Tradeoffs and limits

- **Histories grow.** Event records and tombstones are never compacted. A long-lived package or list keeps every record.
- **Whole-state saves.** The replica hands its entire state to the store after each step. The persistent store writes only the rows that changed, as one transaction, and encodes every double a record holds bit for bit, including NaN and infinities (`persistence.md`).
- **Clock skew is unbounded.** A device whose clock runs far ahead wins concurrent register writes until others observe its readings. No drift limit is enforced. A record stamped at the largest possible reading pins every replica that sees it to that reading: its later writes all tie, and an edit to a field already written at that stamp only takes effect if its value sorts later.
- **Shared replica IDs are found late.** Two installations restored from one backup can write equal stamps until one sees a later write from the other (see Shared replica IDs). Their writes then converge by record ID and value order, so which of two tied removals sets the status, or which of two tied renames is kept, is arbitrary but the same everywhere. A draft restored onto a second device and put away on both produces one package whose creation facts, if both were written with equal stamps, can mix fields from the two drafts.
- **Exact amounts are not validated.** A NaN or infinite exact quantity from another writer is stored and shown as written.
- **Last-writer registers lose concurrent intent.** Two concurrent renames of one list item keep one name. Removal beats a concurrent check or uncheck; the item can be restored.
- **Duplicates are merged only on request.** Two devices adding the same item concurrently produce two items. They are never merged automatically; the merge is a person's action.
- **CloudKit mapping is not built.** Storing each field's stamp alongside its value in a `CKRecord`, mapping `serverRecordChanged` to a conflict outcome, zone and `CKShare` setup, asset upload, change-token expiry (which needs a full refetch), request size limits, and rate limiting are adapter work and unverified.
- **Not synchronized yet:** storage locations, ingredient links, package barcodes (`capture.md`), consumer profiles and restrictions, preferences, Space membership, and deletion of Space data. Tests treat locations as fixed shared configuration.
- **Evidence removal is not implemented.** Crops are not yet removed when their package leaves active inventory, and approved crops have no removal record.

## Owner decisions

1. **Independent removals are undone separately.** When two people remove the same package concurrently, undoing one removal leaves the package removed by the other.
2. **Concurrent Used up and Discard.** The earlier one by clock, or by record ID when their stamps are equal, sets the status and both stay in history. Waste Insights counts one outcome per package, the one that set its final status.
3. **Shopping removal beats a concurrent check or uncheck.** The item stays removed and restorable.
4. **Concurrent duplicate list items are kept and flagged.** Nothing is deleted automatically. Items that match by the add-time duplicate rule are shown as duplicates with a one-tap Merge. A duplicate group is derived from the list, not stored: unchecked items with the same normalized name. A merge keeps the earliest added item, with ties broken by id so every device keeps the same one, and removes the others through the ordinary removal flag. The kept item adopts a quantity or category it lacks from the first removed item that has one and never overwrites its own. Undo restores the removed items and takes back what was adopted unless the kept item has been changed since. Two devices merging at once keep the same item and converge.
5. **Drafts stay on the capturing device.** Review and put-away happen where the capture was made.
6. **Corrections need an active package.** A used-up or discarded package refuses new corrections until its removal is undone. A correction recorded concurrently with a removal, on the same device or another, is kept like any concurrent edit.
7. **Unknown values withhold the package.** A discard reason, quantity level, printed date label or storage type this version does not know makes the package unreadable on this version, instead of being read as the nearest known value. Waste Insights and use-soon guidance never count a guessed reason or window.
8. **Equal-stamp ties favor removal.** When two writes to one shopping item tie exactly, removal beats restore, as it beats a concurrent check (decision 3).
