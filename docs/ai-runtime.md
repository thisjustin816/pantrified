# Pantrified AI Runtime

## Accepted direction

Pantrified uses Apple's Foundation Models framework for generative intelligence rather than operating its own metered LLM backend.

For cloud-quality generation on iOS 27+, the primary runtime is Apple's `PrivateCloudComputeLanguageModel` (Private Cloud Compute / PCC). Pantrified does not require a user to supply an API key, sign into a third-party AI account, or consume a Pantrified-owned token allowance for this path.

Apple documents PCC as using the person's Apple Intelligence access: requests have a per-person daily limit, and additional access can be available through iCloud+. Pantrified therefore does not create its own monthly AI-credit system for PCC.

PCC is available only on eligible Apple Intelligence devices/regions and requires network access. Pantrified must check model availability at runtime and treat unavailability as a normal supported state.

The app's minimum deployment target remains iOS 26. `PrivateCloudComputeLanguageModel` is an iOS 27+ capability and must be availability-gated.

When PCC is unavailable — including because of OS version, network state, Apple Intelligence/model availability, or PCC allowance — Pantrified falls back to Apple's on-device `SystemLanguageModel` when that model is available. The app should make the capability difference understandable where it materially affects results rather than pretending the runtimes are identical. If neither Apple model is available, generative features become unavailable while the free/core and sourced-recipe paths continue to work.

## Plus entitlement

`Make Something` and Pantrified's AI recipe substitutions/adaptations are **Pantrified Plus features regardless of which Apple model runtime serves the request**. Plus unlocks the product capability; PCC versus on-device `SystemLanguageModel` is an availability/runtime choice, not a free-versus-paid boundary.

A fallback from PCC to the on-device model therefore does not remove the Plus requirement. Likewise, a free user does not gain `Make Something` merely because an on-device Apple model is available.

## Privacy boundary

The previously accepted minimum-data rule still applies. Generative recipe requests receive only the structured meal context needed for the request: selected inventory/use-soon information, selected diners, and directly relevant restrictions/preferences. Package photos, evidence crops, household identities, unrelated inventory, and unrelated history are excluded.

## Architecture

Keep generative recipe behavior behind an application capability so domain/application logic remains independently testable. The Apple Foundation Models adapter owns availability checks and selection between supported Apple model runtimes. Prefer PCC when available and fall back to `SystemLanguageModel`; do not introduce a Pantrified server-side LLM provider merely to meter or proxy PCC.

Entitlement checks sit above the runtime adapter: authorization to use a Plus capability is decided before choosing the available Apple model runtime.

## Source basis

Verified against Apple's current Foundation Models documentation in October 2026. Apple documents `PrivateCloudComputeLanguageModel` as an iOS 27+ server-based Apple Intelligence model with stronger reasoning and a 32K context window, no developer-managed authentication/API keys for the PCC call path, and per-person daily request limits.