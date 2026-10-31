# Market research notes

These notes summarize market research completed on October 23, 2026, reduced for a public repository. Competitor names, download counts, prices, revenue arithmetic and quotes from reviews are left out. They were not independently verified, and none of them changes a design decision. Treat the findings below as the research's conclusions, not as checked facts.

## Conclusions

- The problem is real. The research cites an EPA estimate that food waste costs a typical U.S. household hundreds to thousands of dollars a year (about $728 per person and $2,913 for a household of four). Check the source before quoting it outside this repository.
- Households already use and pay for software in the neighboring categories: pantry tracking, grocery lists and meal planning. The category is real, competition is high, and new entrants keep arriving.
- "AI" no longer sets a product apart. Recipe generation, photo and receipt recognition and AI meal planning are common in new and established apps. AI that removes data-entry work is harder to copy than AI that writes text.
- Verdict: proceed, and treat repeated household use as the proof point. Do not optimize monetization or add costly integrations before that is shown.

## The main risk: keeping the inventory accurate

People like knowing what they own. They stop when logging purchases, quantities and dates becomes a second job. The research found the same failure across store reviews and discussion forums. The table lists each finding with what it means for Pantrified.

| Finding | Consequence for the design |
|---|---|
| Upkeep becomes too much work. | Capture must cost less effort than the value it returns. Unknown quantity and unknown date are valid. A partial inventory is fine. |
| Recognition mistakes cost trust, most of all when correction is hard or work is lost. | Every proposed field is one tap from correction. Undo covers bulk actions. The source of each proposal is visible. Captured work survives a crash or relaunch. |
| Near-identical ingredients get confused, such as baking soda and baking powder. | Matching and grouping treat a differing distinguishing word as evidence that two items differ. A doubtful match stays visible. A name is never invented. |
| Quantities and pantry state must change what the app suggests. | Judge Make Something by one question: can I cook this from what is recorded? |
| Household state matters. | Shared inventory is separate from who owns Plus. Family Sharing of a purchase does not create a shared pantry. |
| People want automation outside the app. | Widgets, Shortcuts and actionable notifications are worth more than another dashboard. They come after the core loop works. |
| Retailer account connections are brittle. | A retailer connection is never the only way to stay accurate, and it is not a v1 dependency. |
| Subscription fatigue is common in this niche. | Plus launches as a one-time purchase (see `monetization.md`). |
| General tools such as Reminders and Notes are the hidden competitor. | Adding food must be faster than typing it into a list. |

## What this means for capture

- Time to a first useful inventory is a first-class goal.
- The core workflow is to photograph what you brought home, let the app group the photos into package candidates, and review them quickly. Barcodes and QR codes are shortcuts for information that needs no image processing.
- The dedicated barcode scanner stays for the one-item case. Live scanning on its own fails too often to be the foundation.
- A receipt photo that yields many items is a likely later capture type. Capture and candidate types should leave room for it.
- See `product-decisions.md` for the capture decisions and `capture.md` for the barcode scanner.

## AI runtime notes

- Apple offers two model paths. The on-device model works offline, has a small context window and normally has no foreground request limit. Private Cloud Compute needs a network, has a much larger context window and reasoning, and has a daily per-user allowance.
- Check availability at runtime. A missing or exhausted path falls back without breaking the feature.
- Background model work can be throttled. Smart Restocking must not depend on a background model call finishing at a set time.
- Keep model routing behind an internal abstraction. Apple's terms and eligibility can change, and the research reports that Private Cloud Compute currently carries no per-request charge to qualifying developers. Check Apple's current terms before relying on that.
- Keep a standing evaluation corpus and run it on both models. It covers grounding in the recorded inventory, omitted ingredients, quantity reasoning, substitutions, valid structured output and respect for stated dietary constraints. See `ai-runtime.md` and `evaluation.md`.

## Positioning and claims

- "AI pantry" is a generic description by late 2026. The working promise is: know what you have, make something from it, and keep the household stocked without another AI subscription.
- Say "one-time Plus at launch". Do not say "lifetime everything", because that implies unknown future services.
- Claim only what the architecture supports. Make Something requests do not go to a third-party AI provider. That does not mean all data stays on the device: a barcode lookup sends the barcode to USDA FoodData Central. `testflight-readiness.md` lists the data flows.

## Measuring success

The primary measure is weekly closed-loop households, as defined in the README. Supporting measures fall into these groups:

- Activation: time to the first item, and time to the first Make Something.
- Inventory health: corrections, stale confirmations, and items left untouched for long periods.
- Retention: day 1, day 7 and day 30, split by solo and shared households.
- AI operations: Private Cloud Compute success and fallback rates, latency, and structured-output failures.
- Plus: conversion, how often Smart Restocking is enabled or undone, and repeat use of Waste Insights.
- Household effects: invitations, acceptance, and changes made by members other than the creator.

Two cautions apply. A falling discard count means nothing if people stopped recording discards. High AI use is not success unless a generation leads to cooking or using food and leaves the inventory more accurate.

The app has no analytics today, and `PRIVACY.md` says so. Any measurement needs a privacy decision first. Until then, measure by hand in TestFlight.

## Questions in order

1. Does a household keep its inventory useful week after week?
2. Do people pay for automation and insight, as opposed to access to AI?
3. Only then revisit pricing or services with ongoing cost.

## Limits of this evidence

- Reviews and forum posts are qualitative and not representative.
- Download counts say nothing about retention.
- The research is dated October 23, 2026. Apple's terms and competitor products change.
