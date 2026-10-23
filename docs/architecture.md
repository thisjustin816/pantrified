# Pantrified Architecture

This is the current architecture baseline for implementation planning. It records constraints implied by accepted product decisions and the project’s iOS/Clean Architecture guidance. It is not a substitute for future detailed implementation plans.

## Goals

- Keep core inventory, attention, meal-ranking, reconciliation, and preference behavior testable without SwiftUI, SwiftData, CloudKit, Vision, AVFoundation, EventKit, or a network connection.
- Make external providers replaceable: recognition, product lookup, storage guidance, recipe discovery, recipe generation, notification scheduling, and shopping export are capabilities, not domain dependencies.
- Preserve user corrections and user data across asynchronous processing, sync conflicts, app restarts, cancellation, and temporary service failure.
- Let the app remain useful offline and with incomplete data.

## High-level composition

```text
Pantrified App
│
├─ Presentation
│  ├─ Today
│  ├─ Food
│  ├─ Meals
│  ├─ List
│  └─ Capture / Review
│
├─ Application / Use Cases
│  ├─ Capture groceries
│  ├─ Review & put away packages
│  ├─ Update package lifecycle
│  ├─ Compute attention/use-soon state
│  ├─ Check stale inventory
│  ├─ Suggest meals
│  ├─ Generate recipe
│  ├─ Mark meal cooked & reconcile inventory
│  ├─ Maintain shopping list
│  └─ Synchronize space
│
├─ Domain
│  ├─ Spaces & membership
│  ├─ Products & packages
│  ├─ Locations
│  ├─ Dates / lifecycle / evidence
│  ├─ Storage guidance
│  ├─ Meals / recipes / diners
│  ├─ Preferences & restrictions
│  └─ Shopping
│
└─ Infrastructure Adapters
   ├─ SwiftData
   ├─ CloudKit + CKShare
   ├─ AVFoundation camera
   ├─ Vision OCR / barcode
   ├─ Model provider(s)
   ├─ FoodKeeper dataset
   ├─ FoodData Central / product providers
   ├─ Recipe providers
   ├─ Notification APIs
   └─ External shopping exporters
```

Dependencies point inward. The domain does not import Apple frameworks or provider SDKs.

## Suggested module boundaries

Exact Swift package/project layout is still subject to implementation planning, but the code should make these boundaries explicit:

### `PantrifiedDomain`

Pure Swift domain concepts and deterministic policy.

Examples:

- `Space`, `Member`, `ConsumerProfile`
- `Product`, `Package`, `StorageLocation`
- package quantity and lifecycle events
- printed-date semantics and evidence provenance
- attention/use-soon policy inputs and outputs
- hard dietary restrictions vs soft preferences
- meal-ranking inputs
- recipe ingredient representation
- inventory reconciliation rules
- shopping-list domain state

No SwiftUI, SwiftData, CloudKit, Vision, AVFoundation, EventKit, or provider DTOs.

### `PantrifiedApplication`

Use cases and capability protocols. This layer orchestrates domain behavior and defines the interfaces required from infrastructure.

Likely capabilities include:

- `InventoryRepository`
- `SpaceRepository`
- `CaptureStore`
- `RecognitionService`
- `ProductLookupService`
- `StorageGuidanceRepository`
- `RecipeDiscoveryService`
- `RecipeGenerationService`
- `DietaryValidationService`
- `PreferenceStore`
- `NotificationScheduler`
- `SyncEngine`
- `ShoppingExporter`

Application request/response types should not expose provider-native or Apple-framework-native objects.

### App / Infrastructure targets

The shipping app composes live adapters for Apple frameworks and network providers. These adapters translate between infrastructure formats and application/domain types.

## Persistence

SwiftData is the local persistence mechanism, but it is an implementation detail behind repositories.

Important rules:

- Persist stable app-owned identifiers. Do not make CloudKit record IDs, framework object IDs, display names, or filenames the domain identity.
- Keep rebuildable cache data distinct from irreplaceable user state.
- App-owned internal files belong under Application Support, with temporary/rebuildable data separated from durable data.
- Database + filesystem operations must be designed as one failure domain where both are involved. A database rollback cannot undo an already-written file.
- Recognition proposals should be persisted separately from confirmed package state where useful so delayed enrichment cannot overwrite user corrections.

## Capture file lifecycle

Capture photos are temporary app-owned resources.

Conceptual lifecycle:

```text
Camera capture
  -> app-owned staging/full capture
  -> recognition / review
  -> package committed and usable
  -> optional short recovery retention (~1 day)
  -> full capture deleted

Useful region
  -> app-generated evidence crop
  -> associated with active package
  -> optionally synced if allowed
  -> deleted when package leaves active inventory
```

A capture/import operation must clean up files it owns on success, cancellation, and error while never deleting an original image owned by Photos/a file provider.

## Recognition pipeline

Recognition must produce **evidence/proposals**, not directly mutate authoritative package fields.

A practical boundary is:

```text
Capture assets
  -> deterministic Vision OCR/barcodes
  -> normalized evidence
  -> deterministic parsing where possible
  -> optional cloud/on-device enrichment
  -> candidate package fields + provenance
  -> review / user confirmation
  -> authoritative package state
```

Important constraints:

- Same barcode/GTIN is product evidence, not proof that two photos belong to the same physical package.
- User-confirmed/corrected fields win over delayed recognition results.
- Processing work is durable/idempotent and can resume after restart/network loss.
- Recognition progress and synchronization progress are separate state machines.
- Model-generated confidence must not be treated as a calibrated probability without an independent basis.

## Attention / use-soon engine

The attention engine should be deterministic domain policy over separate inputs, for example:

- printed package date + label semantics
- package instructions
- opened/prepared/frozen/thawed timestamps
- current storage type
- matched FoodKeeper guidance + provenance
- uncertainty/missing information

Output should explain *why* an item is being surfaced. It should not rewrite these inputs into a fictitious canonical expiration date.

## Recipe architecture

Recipe sources share an app-owned internal representation but retain provider/source metadata and rights constraints.

```text
Recipe discovery provider(s) ─┐
                              ├─> normalized recipe candidate -> ranking/filtering
Cloud generation provider ────┘
```

Generated “Make Something” requests send minimum structured context only. Package photos/evidence imagery and household identities stay out of the generation request.

Cloud generation should be provider-neutral. A future provider switch must not require rewriting meal-domain behavior.

Generated recipes cross a deterministic dietary-validation boundary before they can be presented as satisfying hard restrictions. Sourced recipes require their own policy based on data completeness; that decision is still open.

## Preference learning

Keep event collection separate from derived preference state.

- Strong positive events: chosen, cooked, favorited.
- Weak negative evidence: a single skip/dismissal.
- Repeated negative patterns may lower ranking.
- Derived personal signals remain private to that person.
- Shared household preference data is aggregate rather than exposing another person’s raw interaction stream.
- A reset operation must be able to clear learned meal preferences without damaging unrelated inventory/history.

## CloudKit synchronization

SwiftData automatic CloudKit sync is intentionally not the sharing model.

Pantrified owns a synchronization boundary that maps local records to direct CloudKit records/custom zones and `CKShare`.

Required properties:

- local-first operation
- resumable synchronization
- idempotent retries
- field-level merge
- explicit handling of destructive lifecycle events
- tombstone/history strategy sufficient for recovery and convergence
- user corrections survive delayed recognition and sync
- full grocery captures remain device-local
- only approved generated evidence crops are eligible for image sync

The sync engine should be testable with an in-memory/fake transport before CloudKit integration tests.

## Verification strategy

Implementation plans should follow red → green → refactor for domain/application behavior.

Different verification levels prove different things:

- Pure Swift package tests prove deterministic domain/application behavior.
- Apple SDK compilation proves Apple-framework integration compiles.
- Simulator tests prove a subset of runtime/UI behavior.
- Physical-device checks are required for claims that depend on camera, real iCloud sharing, Photos/file-provider behavior, notifications, or device-specific model capability.

Do not describe a feature as verified beyond the level actually exercised.

## Decisions intentionally deferred

The architecture should keep these choices cheap to change until product decisions lock them:

- minimum iOS deployment target
- final presentation framework details
- cloud model vendor
- recipe provider(s)
- additional product lookup provider(s)
- external shopping-list integrations
- monetization/StoreKit design
