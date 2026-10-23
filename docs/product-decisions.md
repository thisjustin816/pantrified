# Pantrified Product Decisions

This document records **accepted** product decisions. Proposals remain in the Open Decisions section until explicitly chosen.

## Product promise

Pantrified helps a household know what food it has, what should be used soon, and what meals can make good use of it. The product should remain useful when inventory is incomplete, quantities are approximate, and package dates are missing.

## Spaces, people, and sharing

- Inventory belongs to a `Space` rather than directly to a user.
- A household/shared space uses CloudKit sharing. All participating household members can edit shared content; the space owner manages invitations and membership.
- A private space is the same domain concept with one member and no active share.
- Multiple spaces are supported in v1 through a simple space switcher.
- Apple’s standard CloudKit sharing UI is used for invitations and participant management.
- If iCloud is unavailable, Pantrified continues to work locally. Shared spaces resume synchronization when iCloud becomes available.
- Family members who do not use the app can exist as lightweight **consumer profiles** and are not CloudKit participants.
- Consumer profiles can store a nickname/name, age group, likes, dislikes, dietary restrictions, spice tolerance, and whether they usually eat household meals. Avoid exact birthdates unless a future requirement justifies them.
- Meal planning defaults to usual diners but allows quick per-meal diner selection.

## Inventory model

- Product identity is separate from a physical package. Two identical products may have different package dates and lifecycle history.
- Approximate quantity is the default; exact quantity is optional. Valid states include Unknown, Full, About half, Low, or an exact amount/count.
- `openedAt`, `frozenAt`, and `thawedAt` are independent lifecycle events rather than one mutually exclusive status.
- Printed date, printed date label/type, lifecycle dates, explicit package instructions, sourced storage guidance, and derived attention state remain separate facts.
- Pantrified derives an explainable **attention date/state** rather than presenting an invented single expiration date.
- Clearly applicable package storage/use instructions take priority over generic FoodKeeper guidance.
- Ambiguous regional numeric dates use locale/package context but require confirmation when ambiguity remains.
- Homemade food and leftovers are first-class inventory items with simpler capture. They may have `preparedAt`, location, approximate quantity, freeze/thaw events, and a storage-guidance match.
- Default locations are Fridge, Freezer, and Pantry. Users can create named locations, each with a basic storage type such as refrigerated, frozen, or room-temperature/pantry.
- Moving an item does not silently imply lifecycle. A move to a freezer may prompt “Frozen today?” and a frozen-to-fridge move may prompt “Thawed today?”; the move succeeds if the prompt is skipped.
- “Used up” and “Discarded” remove a package from active inventory but retain structured lifecycle history for undo, synchronization recovery, and usage/waste insights.

## Capture and recognition

- Primary grocery capture uses a custom AVFoundation camera flow.
- Existing photos can be imported with the system Photos picker.
- New grocery captures are stored as temporary app-owned files rather than being saved to Photos by default.
- Full capture photos are deleted after processing plus a short recovery window of roughly one day.
- After full captures are removed, Pantrified keeps only useful app-generated evidence crops, such as the crop containing a printed package date.
- Evidence crops remain with a package while it is active and are removed when that package leaves inventory.
- Evidence crops may sync with the shared package through CloudKit; full captures stay device-local.
- Arbitrary/raw user images do not sync. Only Pantrified-generated evidence crops are eligible to sync.
- Apple Sensitive Content Analysis may be used opportunistically as defense in depth. It is not treated as an illegal-content/CSAM detector or legal safety guarantee. If a crop is flagged, Pantrified syncs structured extracted data rather than the image.
- Vision OCR and barcode recognition are the baseline recognition path. Model enrichment is optional and never the only path to a usable inventory record.
- Recognition/enrichment must not overwrite a user-confirmed correction that happened while processing was in flight.
- Inventory becomes usable immediately after review/put-away while enrichment may continue asynchronously.
- Offline capture/save is supported; external lookups can queue for later.

## Storage guidance and provenance

- USDA FoodKeeper is the preferred sourced storage-guidance dataset and should be normalized for local use rather than required as a live runtime service.
- Storage guidance is advice, not a hard safety/expiration rule.
- Guidance retains source/provenance and enough version information to explain where it came from.
- A model may help match an inventory item to an existing guidance record, but it must not invent a storage duration.
- USDA FoodData Central is an appropriate product-information source for GTIN/UPC, branded-food data, ingredients, serving information, and nutrients behind a provider-neutral lookup capability.

## Inventory maintenance

- Fast package actions include Opened today, Used up, Move, and Discard, with undo where appropriate.
- Stale-inventory checks are small and adaptive rather than large cleanup sessions.
- A stale check offers Still have it / Used up / Discarded. Ignoring the check means no change.
- “Still have it” confirms presence; it does not reset a storage window.
- One adaptive daily notification digest is the default, only when there is meaningful content. Default timing is early evening and is user-adjustable/disableable.
- Shared-item actions resolve the shared state rather than generating independent conflicting prompts for each household member.

## Meal planning and recipes

- Meal ranking prioritizes ingredients that should be used soon, then minimizes missing ingredients.
- Missing-ingredient review is inline. A user can keep an ingredient missing, remove it from export selection, or choose **Have it already**.
- “Have it already” immediately creates a minimal inventory record and asks only for lightweight location information. Quantity/date may remain unknown.
- Recipe strategy is hybrid: sourced/licensed recipe discovery plus generated **Make Something** recipes.
- Sourced recipe support is provider-neutral and license-aware. Each adapter defines what recipe content may legally be stored and displayed.
- **Edamam is the primary sourced-recipe provider for v1.** It is implemented behind the provider-neutral recipe interface rather than treated as a permanent domain dependency. Production use must comply with the exact commercial plan, caching, attribution, and linking terms in force when the app ships.
- In v1, generated recipes may live entirely inside Pantrified. Sourced recipes are discovery results that open the original publisher unless Pantrified has explicit rights to display the full recipe.
- “Make Something” generation is **cloud-model first** because output quality is the priority. The model provider is abstracted behind an application capability rather than embedded in meal-domain logic.
- Cloud recipe generation receives only the minimum structured context needed for the request: selected inventory, use-soon information, selected diners, and directly relevant preference/restriction context. It does not receive package photos, evidence crops, household identities, or unrelated inventory/history.
- Hard dietary restrictions and soft food preferences are separate. Hard restrictions must be enforced; likes/dislikes and spice tolerance affect ranking rather than act as hard blocks.
- Generated recipes must pass deterministic dietary/allergen validation before being shown. If output conflicts with a hard restriction or cannot be validated confidently, Pantrified rejects or flags it instead of trusting the model alone.
- Sourced recipes are labeled **safe** only when Pantrified has a sufficiently complete ingredient list and its deterministic restriction checks pass. Incomplete or ambiguous recipes may still appear, but are labeled **Needs review** rather than safe. Provider/publisher dietary labels may inform the UI but are not treated as sufficient proof on their own.
- Pantrified can use AI to suggest **recipe substitutions that consume more use-soon inventory**, for both sourced and generated recipes. The adaptation must be clearly identified as a Pantrified suggestion rather than attributed to the original publisher, and the adapted ingredient set must pass the same hard-restriction validation before presentation.
- Pantrified learns both personal and household recipe preferences.
- Meal learning is primarily positive-signal driven. Choosing, cooking, or favoriting is strong evidence; a single skip is weak evidence, while repeated skips can gradually reduce similar suggestions.
- Lightweight derived preference signals can be retained long-term while unnecessary raw interaction history ages out. Users receive a clear **Reset meal preferences** control.
- Personal taste signals remain private to the person; household-level preference data is aggregate/shared.
- Post-cooking inventory reconciliation happens only after the user explicitly marks a meal **Cooked**.
- The reconciliation is a lightweight batch over expected ingredients: Used some / Used up / No change. Pantrified never assumes the recipe quantity equals actual consumption.

## Synchronization behavior

- SwiftData is the local persistence mechanism, but SwiftData automatic CloudKit synchronization is not the household-sharing architecture.
- Shared spaces use direct CloudKit records/custom zones with `CKShare`, mediated by an explicit Pantrified synchronization layer.
- Synchronization uses field-level merge rather than whole-record last-write-wins.
- Destructive lifecycle actions such as Used up or Discarded take precedence over ordinary field edits while remaining recoverable through retained history/undo.
- Recognition state and synchronization state are separate concerns.
- Retryable processing/sync work must be idempotent.

## Presentation and platform baseline

- Pantrified is **SwiftUI-first**, with UIKit bridges where Apple frameworks or system controllers are better exposed through UIKit. The architecture should not force camera, CloudKit sharing UI, or similar integrations into pure SwiftUI when a bridge is more appropriate.
- The minimum deployment target is **iOS 26**. Newer OS capabilities can be adopted behind availability checks without making iOS 27 a launch requirement.

## Shopping list

Accepted product scope:

- A lightweight shared shopping list is part of Pantrified.
- It supports fast entry/autocomplete, optional categories, quantity, checkoff, undo/clear, and pasted/imported text with review.
- Checking off a shopping item does **not** automatically create inventory.
- The list must work offline and synchronize with its space.
- Price comparison, coupons, and aisle mapping are out of scope for the baseline product.

Specific external-export architecture is still open below.

## Open decisions

These items are intentionally **not** recorded as accepted yet:

1. External shopping export details: internal `ShoppingSelection` abstraction, Apple Reminders destination persistence/recovery, duplicate handling, generic newline-text export, and whether any third-party list integrations ship in v1.
2. Exact FoodKeeper dataset update/versioning mechanism.
3. Product lookup fallback providers beyond FoodData Central.
4. Monetization and entitlement boundaries.
5. Privacy/account deletion/export behavior beyond the storage/sync choices already listed.
6. Visual design, branding, and app icon.

## Decision discipline

When a product choice is proposed in planning, it stays a proposal until explicitly accepted. Implementation details that are necessary consequences of an accepted decision can be documented as architecture constraints, but should not be presented as separate product decisions unless they materially affect behavior or scope.
