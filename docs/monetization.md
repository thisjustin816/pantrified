# Pantrified Monetization

## Accepted direction

Pantrified uses a **free core + optional Pantrified Plus** model, but Apple-powered generative recipe intelligence is part of the free core.

### Free core

The free product includes the core household utility already specified: inventory, household sharing, grocery capture/OCR/barcodes, FoodKeeper-backed use-soon/storage guidance, the shared shopping list, sourced-recipe discovery, normal meal ranking, basic usage/waste history, Apple-powered **Make Something** recipe generation, and AI recipe substitutions/adaptations that help consume use-soon inventory.

Make Something prefers Apple's Private Cloud Compute model when available and falls back to Apple's on-device model. Apple's own model availability and PCC usage limits apply. Pantrified does not impose a separate AI credit system.

### Pantrified Plus

**Pantrified Plus remains in the v1 launch plan, but only for features that provide compelling premium value.** The free core must not be artificially weakened or have ordinary household utility moved behind a paywall merely to justify a purchase.

The primary Plus value is **advanced household insights and automation**. Free users retain basic usage/waste history and the ordinary inventory, shopping, and meal-planning experience.

Plus automation is **user-approved rather than autonomous by default**. Pantrified may identify a useful recurring behavior or automation and offer it, but the user explicitly enables that behavior before Pantrified begins acting on it. This allows meaningful automation without silently changing shared household state based only on inferred patterns.

The first v1 Plus automation is **smart restocking**. Pantrified can learn recurring consumption/run-out patterns for products and suggest an item-specific automation, such as adding milk to the shared shopping list when the household is likely running low. The user must explicitly enable smart restocking for that item before Pantrified may add it automatically. Predictions are household convenience signals, not authoritative inventory facts, and an automated shopping-list addition does not create or alter an inventory package.

The first v1 Plus insight is **waste insights**. Pantrified can summarize what the household explicitly records as discarded, including frequently discarded foods/categories, discard frequency and trends, and changes over time. Waste insights must be based on explicit lifecycle events and optional discard reasons; missing inventory updates, stale records, or inferred disappearance must never be counted as waste.

**The v1 Plus feature set intentionally launches with these two premium features: Smart Restocking and Waste Insights.** Consumption Insights and Smart Stale Checks are not required for the initial Plus launch and can be evaluated as later additions.

### Purchase and pricing strategy

Plus v1 is a **one-time non-consumable in-app purchase**, not a subscription. The launch feature set does not currently create enough Plus-specific recurring operating cost to justify recurring billing.

The **U.S. launch price is $0.99**. This intentionally low early price reflects the small initial premium feature set. The one-time purchase price can increase for new purchasers as meaningful included Plus functionality is added.

The purchase permanently unlocks the Plus functionality sold with that purchase. Pantrified should not market this as “lifetime Plus” or promise that every future service will be included forever. If future functionality introduces tangible recurring costs or ongoing service value that warrants a subscription, a subscription can be introduced later without removing the features existing purchasers already bought.

Existing purchasers keep the functionality they purchased; the exact policy for whether later non-recurring Plus features are included automatically or sold separately can be decided when those features exist. Subscription pricing, trials, and grandfathering are not v1 decisions unless the monetization model changes before launch.

If Plus is unlocked at the `Space` level, the previously accepted household entitlement rule remains: one purchaser with the Plus entitlement unlocks Plus for the shared Space; a private Space uses its sole member's entitlement. Apple Family Sharing of the non-consumable purchase, if enabled, is separate from this Pantrified Space rule.

## Superseded decisions

Earlier planning treated Make Something and AI substitutions as Plus features because cloud inference was assumed to create an ongoing Pantrified API cost. That assumption no longer applies after choosing Apple's Foundation Models / Private Cloud Compute architecture. The later explicit decision to make Apple-powered recipe generation part of the free core supersedes that earlier Plus boundary.

An earlier proposal to defer Plus until after launch was rejected in favor of keeping Plus in v1 when the premium feature set is genuinely compelling.

The earlier subscription-at-launch direction is superseded by the decision to sell v1 Plus as a one-time non-consumable purchase until tangible recurring costs or ongoing service value justify recurring billing.