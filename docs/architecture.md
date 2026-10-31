# Pantrified Architecture

Current implementation baseline. Product behavior is canonical in `product-decisions.md`; Apple model details are in `ai-runtime.md`; monetization is in `monetization.md`.

## Architecture goals

- Domain/application behavior remains testable without SwiftUI, SwiftData, CloudKit, Vision, AVFoundation, EventKit, StoreKit, Foundation Models, or network access.
- Apple frameworks and remote services sit behind app-owned capability protocols/adapters.
- Preserve user corrections through delayed recognition, sync conflicts, app restarts, cancellation, and service failure.
- Remain useful offline and with incomplete data.
- Repository/module structure should reflect product/domain concepts rather than framework buckets.

## Composition

```text
Pantrified App
│
├─ Presentation
│  ├─ Today / Food / Meals / List
│  ├─ Capture / Review / Put Away
│  └─ Space / Settings / Sharing
│
├─ Application
│  ├─ Capture & review groceries
│  ├─ Maintain inventory/lifecycle
│  ├─ Compute attention/use-soon state
│  ├─ Suggest/discover/generate meals
│  ├─ Mark cooked & reconcile
│  ├─ Maintain/export shopping selection
│  ├─ Insights / opt-in automation
│  └─ Synchronize Space
│
├─ Domain
│  ├─ Spaces / members / consumer profiles
│  ├─ Products / physical packages / locations
│  ├─ Evidence / dates / lifecycle / quantity
│  ├─ Storage guidance / provenance / attention
│  ├─ Meals / recipes / diners / restrictions
│  ├─ Shopping / restocking / waste events
│  └─ Entitlement-independent Plus policies
│
└─ Infrastructure
   ├─ SwiftData
   ├─ CloudKit + CKShare
   ├─ AVFoundation + Vision
   ├─ Foundation Models (PCC / SystemLanguageModel)
   ├─ bundled FoodKeeper
   ├─ FoodData Central
   ├─ Edamam
   ├─ EventKit / notifications / Share Sheet
   └─ StoreKit
```

Dependencies point inward. Domain code imports none of the infrastructure frameworks above.

## Suggested boundaries

### `PantrifiedDomain`

Pure Swift deterministic concepts/policy: `Space`, membership, consumer profiles, `Product`, physical `Package`, `StorageLocation`, quantity/lifecycle, evidence provenance, printed-date semantics, attention policy, restrictions/preferences, normalized recipe ingredients, reconciliation, shopping state, discard events, and smart-restock policy inputs/outputs.

### `PantrifiedApplication`

Use cases and capability protocols. Likely interfaces include:

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
- `EntitlementProvider`

`Pantry` is the facade the Today and Food screens use for one Space. It reads what is in the Space with what needs attention (`UseSoon`), adds food by hand or from a scanned barcode (`PutAway`, which keeps the barcode through `ProductEvidenceStore`), applies Opened, Used up, Move and Discard with undo (`PackageActions`), and gives a new Space its default locations. It holds no rules of its own; the screens hold no logic beyond showing its results.

Application types must not leak provider DTOs or Apple-framework-native objects.

## Persistence and files

SwiftData is local persistence behind repositories. The stored rows, schema, migration and crash behavior are in `persistence.md`.

- Use stable app-owned identifiers; framework/cloud IDs are mappings, not domain identity.
- Separate durable user state from rebuildable caches/temp state.
- App-owned durable files live in Application Support; temp/rebuildable data is separate.
- Treat database + filesystem changes as one failure domain where both participate.
- Persist recognition proposals/evidence separately from confirmed package state so delayed work cannot overwrite user decisions.

### Capture lifecycle

```text
continuous camera / photo import
  → app-owned staging assets
  → Vision OCR/barcodes + normalized evidence
  → optional enrichment
  → package candidates
  → review / merge / split / correct / bulk put-away
  → authoritative package state usable immediately
  → ~1 day recovery window
  → full capture deleted

useful region → generated evidence crop → active package → optional CloudKit sync → delete when package leaves active inventory
```

Never delete an original asset owned by Photos/file providers.

## Recognition pipeline

Recognition produces proposals, never direct authoritative mutations.

```text
Capture assets
  → Vision OCR / barcode
  → normalized evidence + deterministic parsing
  → FoodData Central lookup when useful
  → optional Apple-model enrichment
  → candidate fields + provenance/uncertainty
  → user review
  → authoritative package state
```

Rules:

- Barcode/GTIN identifies product evidence, not physical package identity.
- User-confirmed fields win over delayed results.
- Unknown quantity/date is valid.
- Durable work resumes after restart/network loss and is idempotent.
- Recognition and synchronization are independent state machines.
- Model confidence is not calibrated probability by default.

## Storage / attention engine

Deterministic domain policy consumes separate facts:

- printed date + label semantics
- package instructions
- opened/prepared/frozen/thawed timestamps
- storage type
- matched FoodKeeper record + provenance
- uncertainty/missing data

It emits an explainable attention state/date without rewriting those facts into a fictitious expiration date. FoodKeeper is a bundled normalized/versioned snapshot. Models may assist matching but may not create storage windows.

## Product lookup

`ProductLookupService` is provider-neutral. v1 live adapter is FoodData Central only (`PantrifiedFoodDataCentral`). A miss preserves the barcode and continues with OCR/user review; it is not an error requiring another provider. The barcode slice, its camera flow and the lookup are described in `capture.md`.

## Recipe architecture

```text
Edamam discovery ───────────────┐
                               ├→ normalized recipe candidate → ranking/filtering → deterministic dietary validation
Apple Foundation Models ───────┘
```

- Edamam remains behind `RecipeDiscoveryService` with rights/provenance metadata.
- `RecipeGenerationService` is an app-owned capability.
- Generated requests contain only minimum structured meal context.
- Deterministic hard-restriction validation is downstream of generated output.
- Sourced recipe safety depends on ingredient completeness; ambiguous results are Needs review.
- Restriction model, classification data, verdict rules, and the request context boundary are in `dietary-validation.md`.

### Apple model adapter

Minimum target is iOS 26.

- `SystemLanguageModel` is the on-device fallback when available.
- On iOS 27+, prefer `PrivateCloudComputeLanguageModel` when Pantrified is eligible and it is available.
- PCC and `SystemLanguageModel` both conform to Apple's `LanguageModel` abstraction, but their capability/availability differs.
- If PCC fails/unavailable, attempt on-device; if neither is available, return a typed unavailable result and leave sourced/core functionality intact.
- Never silently route to a third-party server model in v1.
- Availability/error handling belongs in the adapter/application boundary, not meal-domain logic.

Verified against Apple developer documentation October 23, 2026: Apple documents `PrivateCloudComputeLanguageModel` for third-party apps on iOS 27+, a unified Foundation Models API, 32K PCC context with stronger reasoning, network requirement/daily user limits, and on-device `SystemLanguageModel` with 4K context/offline use. PCC access has developer eligibility/managed-entitlement requirements; Apple's iOS 27 materials state no cloud API cost for qualifying Small Business Program apps below the stated first-time-download threshold. Reverify eligibility before release rather than encoding it as permanent business logic.

## Preferences and reconciliation

Event collection is separate from derived preference state. Strong positives include chosen/cooked/favorited; one skip is weak evidence. Personal derived signals remain private; household preference state is aggregate. Resetting meal preferences must not damage inventory/history.

`Mark Cooked` is the only trigger for expected-ingredient reconciliation. Present Used some / Used up / No change; never infer exact consumption from recipe quantities.

## Shopping and EventKit

Pantrified owns the shared shopping-list state and a provider-neutral shopping selection. External exporters consume that selection.

- EventKit adapter remembers a writable reminder calendar per Space/app user.
- Missing destination → reconnect prompt, never silent fallback.
- Exact normalized-name duplicate check is limited to incomplete reminders in the selected list.
- Generic exporter emits newline-separated text for Copy/Share Sheet.
- No third-party shopping adapters in v1.

## CloudKit synchronization

SwiftData automatic CloudKit sync is intentionally not the sharing model. Pantrified maps local state to direct CloudKit records/custom zones + `CKShare`.

Required properties:

- local-first operation
- resumable/idempotent synchronization
- field-level merge
- explicit destructive lifecycle precedence/tombstone history
- user corrections survive delayed recognition/sync
- full captures never sync
- only approved generated evidence crops may sync

Build/test the sync engine against an in-memory/fake transport before CloudKit integration tests. The record schema, clock, merge and precedence rules, and resume behavior are in `sync-design.md`.

## Plus and StoreKit boundary

StoreKit entitlement is separate from household membership.

- v1 Plus product: $0.99 U.S. non-consumable, Apple Family Sharing enabled.
- An entitled participant unlocks Plus for the shared Space; private Space uses sole member entitlement.
- Free core includes Make Something and AI substitutions.
- Plus v1 contains Smart Restocking and Waste Insights.
- Smart Restocking requires explicit per-item opt-in; predictions may add to the shopping list but never mutate inventory facts.
- Waste Insights consumes explicit discard events only.

Do not place StoreKit checks inside inventory/meal domain rules. Entitlement controls presentation/application access to premium use cases.

## First implementation / validation slice

The first milestone is deliberately vertical rather than feature-complete:

1. Capture a grocery batch.
2. Review/correct/put away incomplete package records quickly.
3. Persist locally/offline and survive restart/delayed enrichment.
4. Surface explainable use-soon value and an inventory-aware meal/Make Something path.
5. Support Opened / Used up / Move / Discard + undo.
6. Mark Cooked and reconcile Used some / Used up / No change.
7. Exercise shared-Space convergence on real devices.
8. Repeat the loop in a real household and measure maintenance friction/inventory drift.

See GitHub issue #1 for pilot completion criteria. Advanced retailer integrations, additional AI surfaces, and broader analytics are intentionally sequenced after this loop is validated.

## Verification strategy

Use red → green → refactor for domain/application behavior.

- Pure Swift tests: deterministic domain/application policy.
- Apple SDK compile: framework integration compiles.
- Simulator: subset of UI/runtime behavior.
- Physical devices: camera, real iCloud/CKShare, Photos/file-provider behavior, notifications, and device/model availability.

Never claim a higher verification level than was actually exercised.

## Remaining intentionally open architecture choices

Implementation planning may still choose exact target/package layout, concrete persistence schema, observation-grouping heuristics, and UI composition details as long as they preserve the accepted behavior above. Visual design/branding remains a product decision.