# Pantrified AI Runtime

Verified against primary Apple developer documentation on **October 23, 2026**.

## Accepted product direction

Pantrified uses Apple's Foundation Models framework for generative intelligence rather than operating a metered LLM backend.

- On iOS 27+, prefer Apple's `PrivateCloudComputeLanguageModel` (PCC) when Pantrified is eligible and the model is available.
- If PCC is unavailable, fall back to on-device `SystemLanguageModel` when available.
- If neither Apple model is available, Make Something/substitution generation is unavailable while inventory, sourced recipes, shopping, storage guidance, and other core features continue working.
- No third-party model fallback is part of v1.
- Minimum deployment target remains iOS 26; PCC is availability-gated to iOS 27+.

## What Apple currently documents

Apple's Foundation Models documentation exposes `PrivateCloudComputeLanguageModel` to qualifying third-party apps. It conforms to the same `LanguageModel` abstraction as `SystemLanguageModel`, so both can back a `LanguageModelSession` without changing downstream guided-generation/tool APIs.

Apple documents these material differences:

| Capability | On-device `SystemLanguageModel` | `PrivateCloudComputeLanguageModel` |
|---|---|---|
| Network | Works offline | Requires network |
| Context | 4K | 32K |
| Reasoning | Not supported in the same PCC sense | Multiple reasoning levels |
| Usage | Unlimited normal use per Apple's comparison | Per-person daily limit |
| Availability | Requires eligible Apple Intelligence device/settings/model readiness | iOS 27+ plus Apple Intelligence/device/region/service eligibility and PCC access |

Apple states PCC does not require the app developer to manage PCC API keys/authentication; the person uses their Apple Intelligence access and receives a daily request allowance, with additional access available through iCloud+.

Apple's iOS 27 developer materials state that apps enrolled in the App Store Small Business Program with fewer than **2 million total first-time App Store downloads** can access Apple Foundation Models on PCC at **no cloud API cost**. PCC development also has eligibility/managed-entitlement requirements. These are current platform/program conditions, not permanent product assumptions; reverify before release and whenever economics depend on them.

## Availability and errors

Never assume either model exists merely because the OS version supports the framework.

For the on-device model, use `SystemLanguageModel.availability`/`isAvailable`. Apple currently documents unavailable reasons including Apple Intelligence disabled, device not eligible, and model not ready.

PCC must likewise be treated as optional at runtime. Network loss, service/model availability, OS version, Apple Intelligence eligibility, developer entitlement/eligibility, or user allowance may prevent a PCC request.

Application behavior should expose typed outcomes such as:

```text
preferred PCC available → use PCC
PCC unavailable/fails in a fallback-eligible way + on-device available → use SystemLanguageModel
neither available → generativeUnavailable(reason)
```

Do not hide a hard product/validation error by silently switching to an unapproved third-party model.

## Product entitlement

Apple-powered **Make Something** and AI recipe substitutions/adaptations are free core regardless of whether PCC or the on-device model executes them. Pantrified has no AI-credit system.

This supersedes the earlier proposal that cloud generation belonged to Plus. Plus v1 is Smart Restocking + Waste Insights; see `monetization.md`.

## Privacy boundary

Generative requests receive only minimum structured meal context: selected inventory/use-soon facts, selected diners, and directly relevant restrictions/preferences. Exclude package photos/evidence crops, household identities, unrelated inventory, and unrelated history unless a future explicitly accepted feature changes that boundary.

Apple describes both its on-device and PCC Foundation Models paths as privacy-preserving, but that does **not** justify claiming all Pantrified data stays on-device: shared inventory uses CloudKit and product/recipe lookup uses their accepted providers.

## Reading labels with a model (planned, not built)

Batch intake reads photos with Apple's Vision framework only. No learned model looks at a photo, and the
Foundation Models work above is for recipes. This section records the plan for using a model on what
Vision read, checked against Apple's documentation on 2026-11-01.

**What Apple's models accept.** `SystemLanguageModel` is documented for text generation on iOS 26. Image
input (`Attachment`) starts at iOS 27, on the device model and, per Apple's own sample, on Private Cloud
Compute. On iOS 26, the minimum deployment target, no Apple model accepts an image. The on-device context
is about 4K tokens (Apple's pages disagree: one says 4,096, a WWDC26 sample prints 8192), so a call covers
one candidate or one doubtful pair, never a whole batch.

**Accepted direction (owner, 2026-11-01).**
- Text first. Send what Vision already read (recognized lines with positions and confidence, product
  numbers, the lookup name when there is one) to a model and ask for proposals. Image input is a later
  option, only if fronts that show a logo alone still fail on the text path.
- Proposals only. A model may raise a "Might be the same as" suggestion, propose a name chosen from the
  recognized lines, label a photo as front, back, nutrition panel or date close-up, and propose a place. It
  never merges, never confirms, never changes a date, and never invents text: a proposed name must equal a
  recognized line or the lookup name, and code checks that. A spelling correction such as a misread brand is
  allowed only when the corrected word appears on another photo of the same candidate or in the lookup
  name. The card says where a proposal came from.
- The rule-based grouping stays the fast path and the fallback. A model runs after Done, on doubtful items
  only, in the foreground, capped per batch, and skips when the device is hot or in Low Power Mode. The
  review never waits for it. With no model available the result is the same as without one.
- Where it runs: on the device by default. The owner chose to allow Private Cloud Compute for recognized
  label text on iOS 27 and later as an opt-in the household turns on, not a default. It is not built, and
  it does not ship until all of this is done: this document, `PRIVACY.md`, the TestFlight data-flow table
  and the App Privacy answers say that label text can go to Apple's cloud model when the setting is on;
  the setting is off until the person turns it on; and the daily Private Cloud Compute allowance it
  shares with Make Something is stated where it is turned on. Label text can still identify a household
  (a pharmacy label, an address on a box). Package photos stay on the device either way, as the privacy
  boundary above says.

**When.** After the grouping, naming and date rules have been measured on real batches, and only if doubtful
pairs, wrong names or unplaced items are still above the shipping gates in the plan. Measurement comes from
a TestFlight-only export of what the app read, with no images (`batch-intake.md`).

**Measuring.** The same corpus-and-report approach as the Evaluation tab: text-level cases from real
failures, run on Linux for the rule-based result and on a device for the model. Suggested gates, for the
owner to set: the model adds at least 15 points of true-pair suggestion recall or 10 points of name accuracy
over rules alone; at most 1 wrong suggestion in 20; no invented name after validation; the review never
waits; model updates finish within 5 seconds after Done for 10 packages on the oldest supported device.
Model behavior changes with each OS update, so the corpus runs again on each.

## Architecture and testing

Keep generation behind `RecipeGenerationService` (or equivalent app-owned capability). The Apple adapter owns model availability, routing, error mapping, and framework-specific types.

Maintain an evaluation corpus for both Apple runtimes covering:

- inventory grounding and omission errors
- use-soon prioritization
- quantity reasoning
- substitutions
- structured-output validity
- hard dietary restriction handling

Model behavior may change with OS updates, so evaluate supported runtimes separately rather than assuming identical quality.

## Primary Apple sources

- Foundation Models updates: https://developer.apple.com/documentation/Updates/FoundationModels
- Adding server-side intelligence with Private Cloud Compute: https://developer.apple.com/documentation/FoundationModels/adding-server-side-intelligence-with-private-cloud-compute
- `PrivateCloudComputeLanguageModel`: https://developer.apple.com/documentation/foundationmodels/privatecloudcomputelanguagemodel
- `SystemLanguageModel.availability`: https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability-swift.property
- iOS 27 developer overview / PCC program condition: https://developer.apple.com/ios/whats-new/
- WWDC26 Foundation Models update: https://developer.apple.com/videos/play/wwdc2026/241/

If these sources and this document diverge at implementation/release time, the current Apple documentation wins and the product decision should be revisited if behavior/economics materially change.