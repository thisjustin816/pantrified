# Pantrified Product Decisions

This document is the canonical record of **accepted** product decisions. Proposals are not accepted merely because they were discussed. Detailed AI-runtime and monetization rationale live in `docs/ai-runtime.md` and `docs/monetization.md`.

## Product promise

Pantrified helps a household answer three questions with as little maintenance as possible:

1. What food do we have?
2. What should we use soon?
3. What can we make with it?

The product must remain useful when inventory is incomplete, quantities are approximate, package dates are missing, and household members do not maintain records perfectly.

Competitive research reinforced the core execution hypothesis: Pantrified wins only if maintaining a trustworthy inventory is easier than the value the inventory creates. AI by itself is not the differentiator. The first implementation milestone therefore validates the closed loop `capture → correct/put away → use/cook → reconcile → return` before expanding feature breadth.

## Platform and presentation

- iOS only.
- Minimum deployment target: **iOS 26**.
- SwiftUI-first, with UIKit bridges where Apple frameworks/system controllers are better exposed through UIKit.
- Working navigation: **Today / Food / Meals / List**, with Add groceries prominent, a Space switcher at the top, and settings elsewhere.

## Spaces, people, and sharing

- Inventory belongs to a `Space`, not directly to a user.
- Shared household spaces use direct CloudKit sharing with `CKShare`; all participants may edit shared content and the owner manages membership.
- A private space is the same domain concept with one member and no active share.
- Multiple spaces ship in v1 with a simple switcher.
- Use Apple's standard CloudKit sharing UI for invitations/participant management.
- If iCloud is unavailable, local use continues and shared spaces resume synchronization later.
- Non-app household members may exist as lightweight consumer profiles rather than CloudKit participants.
- Consumer profiles may include name/nickname, age group, likes/dislikes, dietary restrictions, spice tolerance, and whether they usually eat household meals. Avoid exact birthdates without a future requirement.
- Meal planning defaults to usual diners but allows quick per-meal diner selection.

## Inventory model

- Product identity is separate from physical package identity. Identical products may have different dates/history; a matching barcode alone never proves two observations are the same package.
- Approximate quantity is the default; exact quantity is optional. Unknown, Full, About half, Low, and exact amounts/counts are valid.
- Missing quantity/date never blocks saving a useful inventory record.
- `openedAt`, `frozenAt`, and `thawedAt` are independent lifecycle facts.
- Printed date, printed label/type, lifecycle dates, explicit package instructions, sourced storage guidance, and derived attention state remain separate facts.
- Pantrified derives an explainable attention/use-soon state rather than inventing one canonical expiration date.
- Clearly applicable package instructions outrank generic guidance.
- Ambiguous regional numeric dates require confirmation when package/locale context cannot resolve them safely.
- Homemade food and leftovers are first-class inventory with simpler capture, including `preparedAt`, location, approximate quantity, freeze/thaw events, and storage-guidance match when available.
- Default locations are Fridge, Freezer, and Pantry. Users may create named locations with a storage type such as refrigerated, frozen, or room-temperature/pantry.
- Moving an item does not silently imply lifecycle. Freezer/thaw prompts may be offered, but skipping them does not block the move.
- Used up and Discarded remove a package from active inventory while retaining structured lifecycle history for undo, sync recovery, and insights.

## Capture, recognition, and evidence

- Primary grocery capture uses a custom continuous AVFoundation camera flow.
- Vision OCR and barcode recognition are the deterministic baseline.
- The capture stream may group front/barcode/date observations into package candidates, but uncertainty must remain visible and reviewable.
- Review/put-away supports reassign, merge, split, field edits, and bulk location assignment.
- Bulk location acceptance has undo, and useful location corrections may inform future defaults.
- Existing photos may be imported with the system Photos picker.
- New captures are temporary app-owned files, not saved to Photos by default.
- Full captures are deleted after processing plus a short recovery window of roughly one day.
- Only useful app-generated evidence crops, such as a printed-date crop, remain with an active package.
- Evidence crops are removed when the package leaves active inventory. Eligible evidence crops may sync through CloudKit; full captures remain device-local.
- Arbitrary/raw user images do not sync.
- Sensitive Content Analysis may be used opportunistically as defense in depth. If a crop is flagged, sync structured extracted data rather than the image. Do not treat SCA as an illegal-content/CSAM detector or legal guarantee.
- Recognition/model output is evidence/proposal, not authoritative package state. User-confirmed corrections win over delayed enrichment.
- Inventory becomes usable immediately after review/put-away while enrichment may continue asynchronously.
- Capture/save works offline; external lookups queue for later. Recognition state and synchronization state are separate.
- Retryable processing and sync work must be idempotent.
- Model self-reported confidence is not treated as a calibrated probability without an independent basis.

## Product and storage data

- USDA FoodKeeper is the preferred sourced storage-guidance dataset.
- v1 bundles a normalized, versioned FoodKeeper snapshot; updates ship through reviewed app releases rather than a runtime updater.
- Preserve USDA source, source modified/version when available, Pantrified normalization version, and checksum.
- FoodKeeper values are guidance, not hard safety/expiration rules.
- A model may help match an item to sourced guidance but must never invent storage windows.
- USDA FoodData Central is the **only remote product-information provider in v1**, behind a provider-neutral capability.
- A FoodData Central miss is normal: retain the barcode and use OCR/recognition + user review to create an incomplete/local product. Never fabricate missing product/nutrition metadata.
- GS1 2D dates may be used when encoded, but ordinary UPC/EAN identifies a product, not a package-specific expiration.

## Inventory maintenance and notifications

- Fast package actions: **Opened today, Used up, Move, Discard**, with undo where appropriate.
- Stale checks are small/adaptive and offer Still have it / Used up / Discarded. Ignoring means no state change.
- Still have it confirms presence but does not reset storage windows.
- Default notifications use one adaptive daily digest only when meaningful, initially early evening and adjustable/disableable.
- Notifications are per person, but acting on a shared item resolves shared state. Support quiet hours/snooze and explain why an item is surfaced.

## Meals, recipes, and preferences

- Meal ranking prioritizes use-soon ingredients, then minimizes missing groceries.
- Missing ingredients are reviewed inline before shopping export. **Have it already** creates a minimal inventory record with lightweight location; quantity/date may remain unknown.
- Recipe strategy is hybrid: sourced/licensed discovery plus generated **Make Something** recipes.
- Recipe providers are abstracted behind a provider-neutral, license-aware interface.
- **Edamam is the primary sourced-recipe provider for v1.** Production commercial/caching/attribution/linking terms must be reverified before release.
- Generated recipes may live inside Pantrified. Sourced recipes open the original publisher unless Pantrified has explicit rights to display the full recipe.
- Apple-powered Make Something generation is **free core**.
- AI substitutions/adaptations that consume use-soon inventory are also **free core** and clearly identified as Pantrified adaptations.
- Generative requests receive only minimum structured meal context: selected inventory/use-soon facts, selected diners, and directly relevant preferences/restrictions. No package photos/evidence crops, household identities, or unrelated data/history.
- Hard restrictions and soft preferences are separate. Generated recipes/adaptations pass deterministic hard-restriction validation before presentation.
- Sourced recipes are labeled safe only with a sufficiently complete ingredient list and passing deterministic checks; incomplete/ambiguous results are **Needs review**. Provider dietary labels are not proof.
- Personal and household preferences are learned primarily from positive signals. A single skip is weak evidence; repeated skips may gradually affect ranking.
- Lightweight derived preference signals may persist while unnecessary raw interaction history ages out. Provide Reset meal preferences.
- Personal taste signals remain private; household-level preference data is aggregate/shared.
- Inventory reconciliation occurs only after an explicit **Mark Cooked** action, using a lightweight batch: Used some / Used up / No change. Never assume recipe quantities equal actual consumption.

## Apple generative runtime

- Pantrified uses Apple's Foundation Models framework rather than a Pantrified-operated metered LLM backend.
- On **iOS 27+**, prefer `PrivateCloudComputeLanguageModel` when Pantrified is eligible and the model is available.
- Fall back automatically to on-device `SystemLanguageModel` when PCC is unavailable and the on-device model is available.
- If neither Apple model is available, generative features are unavailable while inventory, sourced recipes, and other core features continue working.
- Runtime capability differences may be explained where they materially affect results; do not pretend PCC and on-device models are identical.
- No third-party model fallback is part of the accepted v1 design.
- Availability must be checked at runtime; iOS 26 remains supported even though PCC is an iOS 27+ capability.
- As verified against Apple developer documentation in October 2026, PCC is exposed to qualifying third-party apps through Foundation Models, requires managed eligibility/entitlement, uses the person's Apple Intelligence access and network connection, and does not require app-managed PCC API keys/authentication. See `docs/ai-runtime.md` for the verification boundary.

## Shopping list and export

- A lightweight shared shopping list is core: fast entry/autocomplete, optional categories, quantity, checkoff, undo/clear, and pasted/imported multiline text with review.
- Duplicate detection is conservative; checking off an item never creates inventory automatically.
- The list works offline and synchronizes with its Space.
- Price comparison, coupons, and aisle mapping are out of scope for baseline v1.
- Pantrified owns a provider-neutral shopping selection used by meal/list flows before external export.
- Apple Reminders export remembers a chosen writable Reminders list per Space and app user. If it disappears, prompt to reconnect rather than silently choosing another list.
- Before Reminders export, exact normalized-name matches among incomplete reminders are shown as Already on list and skipped by default; the user may explicitly add anyway. No fuzzy merge.
- Generic export is newline-separated plain text with quantities when present, available through Copy and the system Share Sheet.
- **No native third-party shopping integrations in v1.**

## Synchronization

- SwiftData is local persistence; SwiftData automatic CloudKit synchronization is **not** the household-sharing architecture.
- Shared Spaces use direct CloudKit records/custom zones with `CKShare` through an app-owned synchronization layer.
- Sync is local-first, resumable, idempotent, and field-level rather than whole-record last-write-wins.
- Destructive lifecycle events such as Used up/Discarded beat ordinary edits while remaining recoverable through history/undo.
- Full captures remain device-local; only approved generated evidence crops are eligible for image sync.

## Identity, privacy, deletion, and export

- No separate Pantrified account in v1.
- iCloud/CloudKit supplies shared-space identity/participants; StoreKit supplies Plus entitlement state.
- Do not require Sign in with Apple merely to duplicate those capabilities.
- Deletion follows Space ownership: private Space owner may delete it; shared Space owner may delete Pantrified-managed shared data; leaving another person's Space removes the participant/local copy but not household data.
- Provide separate **Delete All My Local Data** without implicitly deleting other people's shared Spaces.
- Per-Space export is a ZIP with human-readable CSV plus machine-readable JSON preserving richer relationships, history, metadata, and provenance.
- Export may include active evidence crops but excludes temporary full captures.
- Export formats are stable app-owned representations, not raw SwiftData/CloudKit dumps.

## Insights and waste semantics

- Basic usage/waste history is free core.
- Waste is counted only from explicit discard lifecycle events and optional discard reasons. Missing updates, stale records, or inferred disappearance never count as waste.
- Missing inventory updates are not interpreted as consumption either.

## Monetization

- Pantrified uses **free core + optional Pantrified Plus**.
- v1 Plus is a **$0.99 U.S. one-time non-consumable IAP**, not a subscription.
- Apple Family Sharing is enabled for the Plus purchase.
- One person with a valid Plus entitlement unlocks Plus for the shared Pantrified Space; a private Space uses its sole member's entitlement. Apple Family Sharing and Pantrified Space sharing are separate mechanisms.
- Initial v1 Plus contains exactly two premium areas:
  - **Smart Restocking** — learns recurring run-out/consumption patterns and may suggest item-specific automation. The user must explicitly enable automation per item. Automatic shopping-list additions are convenience predictions, not inventory facts, and never create/alter packages.
  - **Waste Insights** — trends and summaries based only on explicit discard events/reasons.
- Consumption Insights and Smart Stale Checks are deferred from the initial Plus feature set.
- Make Something and AI substitutions are free core regardless of whether PCC or the on-device Apple model executes them.
- Do not weaken ordinary free-core utility to manufacture a paywall.
- The $0.99 launch price is intentionally an early-adopter/validation price. It may increase for **new purchasers** as meaningful premium functionality grows.
- Existing purchasers keep the functionality sold with their purchase. Do not market this as “lifetime Plus” or promise every unknown future recurring-cost service forever.
- Reconsider subscriptions only if future functionality creates tangible recurring costs or ongoing service value that warrants recurring billing.

## v1 sequencing / validation priority

Competitive research completed October 23, 2026 supports proceeding, but identifies inventory-maintenance friction as the highest-risk assumption (see [`market-research.md`](market-research.md)). The first implementation milestone is therefore a real-household vertical slice that proves:

`capture → fast correction/put-away → immediate use-soon/meal value → use/cook → easy reconciliation → repeat`

Primary proposed product-health measure: **weekly closed-loop households** — households that add/capture inventory and subsequently cook/use, consume, discard, or restock within the same rolling week. Repeated-week retention matters more than raw scans or AI generations.

Advanced retailer integrations, broader analytics, and additional AI surfaces should follow evidence that this loop works rather than precede it.

## Open decisions

1. Visual design and branding. The app icon is chosen.
2. Future Plus additions/pricing beyond the accepted v1 $0.99 non-consumable offering.

## Decision discipline

A proposed choice remains a proposal until explicitly accepted. Implementation details that necessarily follow an accepted decision may be documented as architecture constraints, but must not be presented as new product decisions when they materially change behavior or scope.