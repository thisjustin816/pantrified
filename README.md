# Pantrified

Pantrified is an iOS household food app for answering three questions with as little maintenance as possible:

1. What food do we have?
2. What should we use soon?
3. What can we make with it?

The app is designed around imperfect real-world inventory: approximate quantities are valid, dates may be missing, multiple people may update the same household, and recognition/enrichment can happen after an item is already usable.

## Product status

**Specified enough to begin the first validation/implementation slice.** Competitive research reinforced that the main product risk is inventory-maintenance friction, not the availability of AI recipe features. The first milestone therefore validates the household loop:

`capture → correct/put away → use/cook → reconcile → return`

See GitHub issue #1 for the pilot and completion criteria.

## Current direction

- iOS-only, minimum iOS 26.
- Household inventory organized into shareable `Space`s, including private single-member spaces.
- Fast continuous grocery capture using an app-owned AVFoundation camera flow, Vision OCR/barcodes, reviewable package candidates, and optional model enrichment.
- Incomplete records are valid: approximate/unknown quantities and missing dates do not block saving.
- SwiftData for local persistence with an explicit direct CloudKit + `CKShare` synchronization layer for shared spaces.
- Inventory guidance derived from separate evidence: printed package dates, lifecycle events, package instructions, and a bundled/versioned USDA FoodKeeper snapshot. Pantrified does not invent a single expiration date.
- USDA FoodData Central is the only remote product lookup provider in v1; misses fall back to OCR/recognition and user review.
- Meal suggestions prioritize food that should be used soon, then minimize missing ingredients.
- Hybrid recipes: Edamam-backed sourced discovery plus Apple-powered **Make Something** generation.
- Make Something and use-soon substitutions are free core. Pantrified prefers Apple's Private Cloud Compute model on eligible iOS 27+ devices and falls back to the on-device `SystemLanguageModel`; no third-party model fallback is part of v1.
- Lightweight shared shopping list with Apple Reminders and Copy/Share Sheet export; no native third-party shopping integrations in v1.
- Pantrified Plus v1 is a **$0.99 U.S. one-time non-consumable IAP** with Apple Family Sharing. Initial Plus features are Smart Restocking and Waste Insights.

## Documentation

- [`docs/product-decisions.md`](docs/product-decisions.md) — canonical accepted product decisions and remaining open decisions.
- [`docs/architecture.md`](docs/architecture.md) — implementation architecture constraints and the first vertical slice.
- [`docs/ai-runtime.md`](docs/ai-runtime.md) — Apple Foundation Models/PCC runtime and fallback boundary.
- [`docs/monetization.md`](docs/monetization.md) — free/Plus boundary and purchase strategy.
- [`docs/sync-design.md`](docs/sync-design.md): shared-Space record schema, clock, merge rules, and resume behavior.
- [`docs/dietary-validation.md`](docs/dietary-validation.md): hard-restriction validation, classification data and its limits, and the Make Something request context.
- [`docs/branching-and-ci.md`](docs/branching-and-ci.md): how work is branched and verified while the repository is private, and the move to macOS workflows.

## Implementation handoff

Start with issue #1 and the canonical docs above. Do not expand into retailer integrations, broader analytics, or additional AI surfaces before the core inventory loop is demonstrated in repeated household use.

The primary proposed product-health measure is **weekly closed-loop households**: a household captures/adds inventory and subsequently cooks/uses, consumes, discards, or restocks within the same rolling week. Repeated-week retention matters more than raw scans or AI generations.

## Engineering principles

Domain and application behavior must remain independently testable from SwiftUI, SwiftData, CloudKit, Vision, AVFoundation, EventKit, StoreKit, Foundation Models, and network providers. Apple frameworks and remote services live behind capability protocols/adapters. Implementation work should use explicit failure-path tests and distinguish Swift tests, Apple SDK compilation, simulator verification, and physical-device verification.
