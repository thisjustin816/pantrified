# Pantrified

Pantrified is an iOS household food app for answering three questions with as little maintenance as possible:

1. What food do we have?
2. What should we use soon?
3. What can we make with it?

The app is being designed around imperfect real-world inventory: approximate quantities are valid, dates may be missing, multiple people may update the same household, and recognition/enrichment can happen after an item is already usable.

## Product status

**Exploring / product specification.** The repository is intentionally documentation-first while core product and architecture decisions are settled.

## Current direction

- iOS-only application.
- Household inventory organized into shareable spaces, including private single-member spaces.
- Fast grocery capture using an app-owned camera flow, Vision-based text/barcode recognition, and optional model enrichment.
- SwiftData for local persistence with an explicit CloudKit + `CKShare` synchronization layer for shared spaces.
- Inventory guidance derived from separate evidence: printed package dates, lifecycle events, package instructions, and sourced storage guidance. Pantrified does not invent a single expiration date.
- Meal suggestions prioritize food that should be used soon, then minimize missing ingredients.
- Hybrid recipes: sourced recipe discovery plus cloud-generated “Make Something” recipes.
- AI-assisted recipe substitutions can adapt sourced or generated recipes to use more food that needs attention soon, while preserving hard dietary restrictions.
- Lightweight shared shopping list with external export planned separately.

## Documentation

- [`docs/product-decisions.md`](docs/product-decisions.md) — accepted product decisions and open questions.
- [`docs/architecture.md`](docs/architecture.md) — architecture constraints and component boundaries.

## Engineering principles

Domain and application behavior must remain independently testable from SwiftUI, SwiftData, CloudKit, Vision, camera APIs, and model providers. Apple frameworks and remote services live behind capability protocols/adapters, and implementation work should include explicit failure-path testing and verification evidence.
