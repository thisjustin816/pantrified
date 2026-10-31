# Pantrified Local Persistence

How the app keeps its data across launches. Code: `Sources/PantrifiedPersistence/` (the row mapping, the stores and the in-memory backend, all plain Swift) and `Sources/PantrifiedPersistence/SwiftData/` (the SwiftData schema and backend, compiled only where SwiftData exists). The app opens the store through `App/LocalPersistence.swift`; no screen reads from it yet.

## Design

SwiftData is a thin row store. The synchronized record set is the local source of truth for synchronized entities, and SwiftData holds those records encoded, one row per record, with a few plain columns for keys and sync metadata. Every rule about what a row means lives in plain Swift above SwiftData:

```text
use cases ── InventoryRepository / ShoppingListRepository ── SpaceReplica (merge, clock, outbox)
                                                                │ ReplicaStateStore
                                                     PersistentReplicaStateStore
                                                                │ rows, one batch per save
use cases ── StorageLocationRepository ── PersistentLocations ──┤
use cases ── IngredientLinkRepository ── PersistentIngredientLinks ┤
                                                         StorageBackend
                                              ┌─────────────────┴─────────────────┐
                                     SwiftDataBackend                  InMemoryStorageBackend
                                 (Apple platforms only)              (previews, Linux tests)
```

`StorageBackend` has three operations: read one Space's replica rows, read one kind of device-local row for a Space, and write a batch all or nothing. Both backends apply record writes through the same function (`RecordRowWrite.resolve`), so they merge identically.

### Why not one `@Model` class per domain entity

The alternative maps packages, events, list items and locations to normalized `@Model` classes with relationships. It was not chosen:

- **Two sources of truth.** `SpaceReplica` already owns synchronized entities as records: reads are built from the merged records and every local change is staged as records and queued for upload in one step (`sync-design.md`). Normalized models would be a second copy that has to be kept equal to the records, or the merge and precedence rules would have to be rewritten against SwiftData.
- **Forward compatibility.** Unknown fields, unknown record kinds and records needing a newer reader must be stored and passed on unchanged. An encoded record keeps them with no schema change; normalized models would drop them or need a column for every possible future field.
- **Exact values.** Merge ties compare stored forms bit for bit. A SwiftData attribute does not promise to keep a NaN payload, negative zero or a non-normalized string as written. The binary encoding here does, and tests prove it.
- **Testability.** The mapping, merge-on-write, incremental batches and failure handling run on Linux against the in-memory backend, with red-green tests and mutation checks. Only the row storage needs Apple CI.
- **Migrations.** A record format change is a `SyncFormat` change handled by readers. The SwiftData schema holds only keys and blobs, so it changes rarely.

The cost: SwiftData cannot query inside a record. Reads load a Space's rows and decode them, which is what the replica already does at launch. Any query a screen needs is answered from the materialized entities, not from SwiftData predicates. Indexed columns for such queries can be added in a later schema version when a real need appears.

## What is stored

| State | Where | Stored as | Synchronized |
|---|---|---|---|
| Packages, package events, shopping items, evidence crops | Replica record rows | One row per record: the encoded `SyncRecord`, an upload-queue flag and the last server tag | Yes, through the replica |
| Replica clock and change token | Replica header row, one per Space | The clock's latest reading and the token, encoded | No |
| Storage locations | Local rows, kind `location` | Name, storage type tag and list position, keyed by the location's ID | No (see Limits) |
| Ingredient links | Local rows, kind `ingredientLink` | The two normalized names, keyed by both | No (see Limits) |

Every key is app-owned: Space IDs, record IDs and location IDs are the domain's UUIDs. SwiftData's `PersistentIdentifier` is never stored or used as identity.

Not stored here yet, and where each goes when its capability exists:

- **Drafts** stay on the capturing device and never enter the replica's record set (owner decision 5 in `sync-design.md`). They belong in local rows of their own kind, with capture assets as app-owned files in a capture directory in Application Support and the full captures deleted after the recovery window.
- **Consumer profiles and preferences** have no repository protocol or stored form yet. Profiles become records when they sync; private derived preference signals stay in local rows.
- **Recognition job state** never syncs and is device-local; recognition results reach other devices only as package events.
- **Caches** (lookups, generated text, thumbnails) belong in the Caches directory, never in this store, so clearing them never touches user data.

### Encoding

`StoredValueCoding` writes a version byte, then the value. Values are tagged: null, bool, 64-bit integer, double and date by their 64-bit patterns, string as a length and its UTF-8 bytes, UUID as its 16 bytes, list and map as a count and their elements. Map keys and record fields are written in UTF-8 byte order, so equal values encode to identical bytes. A record is its kind, entity UUID, creation stamp, minimum reader version and its fields, each with its stamp. The replica header is the clock's latest reading and an optional change token.

Decoding refuses rather than repairs: a truncated value, trailing bytes, an unknown tag, invalid UTF-8 or out-of-order keys are `PersistenceError.corrupt`, and a version byte above the one this build writes is `PersistenceError.newerFormat`.

## Atomicity and crash behavior

`SpaceReplica` saves its whole `ReplicaState` after every local change, push step and pull page, and adopts the new state only once the save returns. `PersistentReplicaStateStore` turns each save into one batch holding only what differs from the state it last stored:

- a row write for each record ID whose record, queue flag or server tag changed, carrying the record only when the record itself changed;
- the header when the clock or change token changed.

The SwiftData backend stages the batch in a new `ModelContext` and calls `save()` once, which commits it as one SQLite transaction. So:

- **A failed or interrupted save leaves the previous state.** An error before the commit, including a process killed while the batch is staged, discards the context. SQLite rolls back a transaction interrupted during the commit. Either way the replica keeps its previous state in memory too, so memory and disk agree.
- **A save that committed but reported failure** is confirmed by reading the Space back: when storage holds the new state, the save succeeds and the replica adopts it. Otherwise the store forgets what it last stored and reads it back before the next save. Without the read-back, a retried put-away would restamp a package header storage already held.
- **Record writes merge** into the stored record rather than replacing it. For the one replica that owns a Space this changes nothing, because its records only grow by merging. It means no write path can erase a stored field write.
- **Records are never deleted.** A row is removed only when it would hold no record, no queue flag and no tag.
- **A loaded clock follows every stored stamp.** Loading has the clock observe each stored record. The owning replica has already observed them, so this changes nothing for it; it stops a header written by a second writer that had seen less from making the replica reissue earlier stamps.

On relaunch the replica reloads the last committed state, re-pushes its queue and pulls from its saved token, as `sync-design.md` describes for any crash.

Local rows are written the same way: each save of a location or link is one batch.

## Schema and migration

`PantrifiedSchemaV1` is a `VersionedSchema` with three models: `StoredRecord` (unique row key, Space, kind, entity, payload, queue flag, server tag), `StoredReplicaHeader` (unique Space, payload) and `StoredLocalRow` (unique row key, kind, Space, entity key, payload). `PantrifiedMigrationPlan` lists every schema in order with a stage between each pair. A released schema never changes; a change adds a version and a stage.

The store's directory also holds `schema-version`, the highest schema version that has opened the store. Opening reads it first and refuses a store marked by a newer version with `PersistenceError.newerSchema`, before SwiftData touches the file. This matters because a TestFlight build can install over a newer one and keep its data. The marker is written only after the store has opened and migrated, so a crash in between at worst means the next launch opens the store again before recording it.

## Opening, and a store that cannot be opened

`SwiftDataBackend.open(StoreFiles.applicationSupport())` creates the directory, checks the marker, opens or migrates the store, records the marker and sets the file protection class. Every failure is a typed `PersistenceError`: `cannotOpen` with the underlying reason, `newerSchema`, `newerFormat` or `corrupt`. Nothing in the module deletes, moves or recreates a store it cannot read. What the app shows and offers in that case is an owner decision (below).

## Concurrency

- `SpaceReplica` is an actor and calls its store synchronously, so a Space's saves are serialized and each completes before the replica adopts the new state.
- `SwiftDataBackend` makes a `ModelContext` for each call and finishes with it before returning, so no context crosses threads. A lock serializes its calls, so batches never interleave. The `ModelContainer` is shared.
- `LocalStore` hands out one replica per Space, and the app must open one `LocalStore` per process; nothing enforces that across instances. Two replicas over one Space keep every record (merge-on-write) and the loaded clock stays past every stored stamp, but each would replace the other's server tags and change token, and both would write under one replica ID.
- Everything public is `Sendable` and builds under Swift 6 strict concurrency. Types holding mutable state guard it with a lock and say which fields it guards.
- Store calls block the calling thread for the length of one small SQLite transaction. That is acceptable for the batch sizes the replica produces; a pull page of a few hundred records is one transaction.

## Files, protection and backup

- The store lives in `Application Support/Pantrified/LocalStore/`: `Pantrified.store` with SQLite's companion files, and `schema-version`.
- On iOS the directory and every file in it get `completeUntilFirstUserAuthentication`, so sync and background work can run while the device is locked after its first unlock. New files inherit the directory's class.
- The store is included in device and iCloud backups. A restore keeps the household's data, including writes not yet uploaded. A backup restored onto a second device while the first stays in use shares a replica ID; `sync-design.md` covers how that converges and how it is detected.
- SwiftData's automatic CloudKit sync is off: the only `ModelConfiguration` passes `cloudKitDatabase: .none`, a Linux test fails any `ModelConfiguration(` in `Sources` or `App` without it, and a macOS test checks the opened container's configuration. The app has no iCloud entitlement either. Sharing uses the app-owned CloudKit layer in `sync-design.md`.

## Privacy and required-reason APIs

The module's code calls no required-reason API: it does not read file timestamps, disk space or boot time, and it does not use `UserDefaults`. It sets file attributes and lists its own directory, neither of which is in Apple's required-reason list. `Scripts/verify-required-reason-apis.py` scans `App` and `Sources` and agrees, and `App/PrivacyInfo.xcprivacy` declares no category.

What is not verified: what SwiftData and Core Data call internally. They are system frameworks, and the scan reads only this repository's Swift source. The archived app's privacy report is still the last check before an upload (`testflight-readiness.md`).

Nothing in the store leaves the device. Synchronized records reach iCloud only through the sync engine.

## What is verified where

| Level | What runs |
|---|---|
| Linux `swift test` | Encoding round trips and refusals; the row mapping; incremental batches; merge-on-write; failed, unconfirmed and cancelled saves; concurrent Spaces; local repositories; the opening sequence and schema marker; one replica per Space; the inventory contract against a stored replica that reads every assertion back from storage; crashes at every sync save; duplicated, shuffled, stale and split delivery; NaN dates across restart; atomic list updates; and a randomized run of failed writes, restarts and another device's changes. All against the in-memory backend. |
| macOS `make test-package` | Everything above against Apple's Foundation, and every storage-parameterized suite again against a SwiftData store on disk. Plus: automatic CloudKit sync off in the opened configuration, relaunch with a recreated container, failure between staging and commit, an unopenable file left untouched, migration from the first schema to a test-only second schema, refusal of a store a newer schema opened, and concurrent writers through one container. |
| Simulator hosted test | The app opens the store in its Application Support, saves a package and a location, opens it again, reads them back, and checks the file protection class and backup inclusion. |
| Device | Nothing. File protection enforcement, real crashes, backup and restore, and long-lived stores are unverified. |

## Limits

- **Reads decode a whole Space.** A replica loads every record of its Space at launch. Event histories are never compacted (`sync-design.md`), so launch time grows with history.
- **Locations and ingredient links do not sync.** They are kept per Space on one device. Until they become records, devices sharing a Space each need the same locations, which `sync-design.md` already lists as not synchronized.
- **No deletion yet.** Leaving a Space and Delete All My Local Data need a backend operation that removes a Space's rows and its files together; it is not built.
- **One process.** The single-replica rule holds within one process. An app extension writing the same store would need coordination that is not built.
- **An unreadable row blocks its whole read.** A record row that cannot be decoded stops its Space's replica from opening, and an undecodable location, or one with a storage type this version does not know, stops the location list (owner decision 5).
- **Real interruption is not tested.** Crash safety rests on staging in one context and committing once; tests fail the write before the commit and recreate the container, but no test kills a process during a commit.

## Owner decisions

Conservative defaults, each changeable:

1. **The store is backed up.** Device and iCloud backups include it, so a restore keeps the household's data. The alternative, excluding it, would lose unsynced changes on restore and avoid shared replica IDs.
2. **Protection class.** `completeUntilFirstUserAuthentication`, so sync can run in the background while locked. `complete` would keep data unreadable while locked at the cost of background sync.
3. **A store that cannot be opened is never deleted.** The app reports it and offers nothing destructive. Whether to offer a reset, an export of what can be read, or a support path is for the owner; none is built.
4. **A store a newer version opened is refused.** An older build never reads or writes it, even if SwiftData could open it.
5. **Rows that cannot be decoded are refused, not skipped.** The read throws `PersistenceError` instead of showing the rest without them, so nothing is shown that could be misread and nothing is silently dropped. Records that decode but hold values this version does not know are a separate case, withheld package by package under owner decision 7 in `sync-design.md`. Skipping undecodable rows with a report would keep the rest usable, at the risk of showing a removed package as active.
