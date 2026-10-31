# Pantrified

Pantrified is an iOS household food app for answering three questions with as little maintenance as possible:

1. What food do we have?
2. What should we use soon?
3. What can we make with it?

The app is designed around imperfect real-world inventory: approximate quantities are valid, dates may be missing, multiple people may update the same household, and recognition/enrichment can happen after an item is already usable.

Join the [public beta on TestFlight](https://testflight.apple.com/join/VMxXhRW8).
It requires iOS 26 or later.

## Product status

**The pure-Swift domain and application layers for the first slice are implemented and tested on Linux, and an app shell and its macOS workflows are in place.** The app opens on a local SwiftData store and has Today and Food screens, an Add food sheet, and Opened, Used up, Move and Discard with an undo. A Scan button reads one product barcode with the camera and opens Add food with it, suggesting a name from USDA FoodData Central in builds with a key. These are tested in the simulator and have been looked at in simulator screenshots, but nothing has been verified on a device, and the simulator has no camera. Date recognition, photo import, continuous capture, the CloudKit adapter, Meals, the shared shopping List and most Apple model adapters are not built. Competitive research reinforced that the main product risk is inventory-maintenance friction, not the availability of AI recipe features. The first milestone therefore validates the household loop:

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

- [Privacy policy](PRIVACY.md)
- [Support](SUPPORT.md)

- [`docs/product-decisions.md`](docs/product-decisions.md) — canonical accepted product decisions and remaining open decisions.
- [`docs/architecture.md`](docs/architecture.md) — implementation architecture constraints and the first vertical slice.
- [`docs/ai-runtime.md`](docs/ai-runtime.md) — Apple Foundation Models/PCC runtime and fallback boundary.
- [`docs/monetization.md`](docs/monetization.md) — free/Plus boundary and purchase strategy.
- [`docs/sync-design.md`](docs/sync-design.md): shared-Space record schema, clock, merge rules, and resume behavior.
- [`docs/persistence.md`](docs/persistence.md): what is stored on the device and how, schema and migration, crash behavior, file protection, and what is verified where.
- [`docs/dietary-validation.md`](docs/dietary-validation.md): hard-restriction validation, classification data and its limits, and the Make Something request context.
- [`docs/branching-and-ci.md`](docs/branching-and-ci.md): how work is branched, merged and verified.
- [`docs/ci.md`](docs/ci.md): the workflows, what each check establishes, and what is not built yet.
- [`docs/capture.md`](docs/capture.md): barcode scanning, camera permission states, GTIN normalization, where barcodes are kept, and the FoodData Central lookup and its key.
- [`docs/date-recognition.md`](docs/date-recognition.md): reading printed dates and labels from recognized text, and how ambiguous dates are handled.
- [`docs/testflight-readiness.md`](docs/testflight-readiness.md): the privacy manifest, what is decided before an upload, and what data leaves the device.
- [`docs/testflight.md`](docs/testflight.md): the TestFlight upload workflow, its secrets and the first run.
- [`docs/evaluation.md`](docs/evaluation.md): the on-device model evaluation, what it measures and where it is compiled.
- [`docs/storage-guidance.md`](docs/storage-guidance.md): the bundled USDA FoodKeeper snapshot, its conversion rules and how foods are matched to it.
- [`docs/market-research.md`](docs/market-research.md): what the market research concluded, and what it means for capture, the AI runtime, positioning and measurement.

## Implementation handoff

Start with issue #1 and the canonical docs above. Do not expand into retailer integrations, broader analytics, or additional AI surfaces before the core inventory loop is demonstrated in repeated household use.

The primary proposed product-health measure is **weekly closed-loop households**: a household captures/adds inventory and subsequently cooks/uses, consumes, discards, or restocks within the same rolling week. Repeated-week retention matters more than raw scans or AI generations.

## Engineering principles

Domain and application behavior must remain independently testable from SwiftUI, SwiftData, CloudKit, Vision, AVFoundation, EventKit, StoreKit, Foundation Models, and network providers. Apple frameworks and remote services live behind capability protocols/adapters. Implementation work should use explicit failure-path tests and distinguish Swift tests, Apple SDK compilation, simulator verification, and physical-device verification.

## License

All rights reserved; see [LICENSE](LICENSE). The repository is public so its workflows can run. That
grants no permission to use, copy, modify or distribute the code or documentation.
