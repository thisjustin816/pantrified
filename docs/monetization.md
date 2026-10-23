# Pantrified Monetization

## Accepted direction

Pantrified uses a **free core + optional Pantrified Plus** model, but Apple-powered generative recipe intelligence is part of the free core.

### Free core

The free product includes the core household utility already specified: inventory, household sharing, grocery capture/OCR/barcodes, FoodKeeper-backed use-soon/storage guidance, the shared shopping list, sourced-recipe discovery, normal meal ranking, basic usage/waste history, Apple-powered **Make Something** recipe generation, and AI recipe substitutions/adaptations that help consume use-soon inventory.

Make Something prefers Apple's Private Cloud Compute model when available and falls back to Apple's on-device model. Apple's own model availability and PCC usage limits apply. Pantrified does not impose a separate AI credit system.

### Pantrified Plus

**Pantrified Plus remains in the v1 launch plan, but only for features that provide compelling premium value.** The free core must not be artificially weakened or have ordinary household utility moved behind a paywall merely to justify a subscription.

The primary Plus value is **advanced household insights and automation**. Free users retain basic usage/waste history and the ordinary inventory, shopping, and meal-planning experience.

Plus automation is **user-approved rather than autonomous by default**. Pantrified may identify a useful recurring behavior or automation and offer it, but the user explicitly enables that behavior before Pantrified begins acting on it. This allows meaningful automation without silently changing shared household state based only on inferred patterns.

The first v1 Plus automation is **smart restocking**. Pantrified can learn recurring consumption/run-out patterns for products and suggest an item-specific automation, such as adding milk to the shared shopping list when the household is likely running low. The user must explicitly enable smart restocking for that item before Pantrified may add it automatically. Predictions are household convenience signals, not authoritative inventory facts, and an automated shopping-list addition does not create or alter an inventory package.

The first v1 Plus insight is **waste insights**. Pantrified can summarize what the household explicitly records as discarded, including frequently discarded foods/categories, discard frequency and trends, and changes over time. Waste insights must be based on explicit lifecycle events and optional discard reasons; missing inventory updates, stale records, or inferred disappearance must never be counted as waste.

**The v1 Plus feature set intentionally launches with these two premium features: Smart Restocking and Waste Insights.** Consumption Insights and Smart Stale Checks are not required for the initial Plus launch and can be evaluated as later additions.

### Pricing strategy

Plus should launch **cheap while the premium feature set is small**, then increase in price as meaningful Plus functionality is added. The launch price should reflect the actual launch value rather than charging today for a future roadmap.

Price changes should use App Store subscription pricing capabilities deliberately. The exact introductory price, later price points, treatment of existing subscribers when prices increase, and trial terms remain open decisions.

If Plus is sold at the `Space` level, the previously accepted household entitlement rule remains: one active Plus subscriber unlocks Plus for the shared Space; a private Space uses its sole member's entitlement. Apple subscription Family Sharing is separate from this Pantrified Space rule.

## Superseded decisions

Earlier planning treated Make Something and AI substitutions as Plus features because cloud inference was assumed to create an ongoing Pantrified API cost. That assumption no longer applies after choosing Apple's Foundation Models / Private Cloud Compute architecture. The later explicit decision to make Apple-powered recipe generation part of the free core supersedes that earlier Plus boundary.

An earlier proposal to defer Plus until after launch was rejected in favor of keeping Plus in v1 when the premium feature set is genuinely compelling.