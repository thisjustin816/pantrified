# Pantrified AI Runtime

## Accepted direction

Pantrified uses Apple's Foundation Models framework for generative intelligence rather than operating its own metered LLM backend.

For cloud-quality generation on iOS 27+, the primary runtime is Apple's `PrivateCloudComputeLanguageModel` (Private Cloud Compute / PCC). Pantrified does not require a user to supply an API key, sign into a third-party AI account, or consume a Pantrified-owned token allowance for this path.

Apple documents PCC as using the person's Apple Intelligence access: requests have a per-person daily limit, and additional access can be available through iCloud+. Pantrified therefore does not create its own monthly AI-credit system for PCC.

PCC is available only on eligible Apple Intelligence devices/regions and requires network access. Pantrified must check model availability at runtime and treat unavailability as a normal supported state.

The app's minimum deployment target remains iOS 26. `PrivateCloudComputeLanguageModel` is an iOS 27+ capability and must be availability-gated.

The behavior when PCC is unavailable — for example, whether to fall back to the on-device `SystemLanguageModel` or disable cloud-quality generation — remains a product decision.

## Privacy boundary

The previously accepted minimum-data rule still applies. Generative recipe requests receive only the structured meal context needed for the request: selected inventory/use-soon information, selected diners, and directly relevant restrictions/preferences. Package photos, evidence crops, household identities, unrelated inventory, and unrelated history are excluded.

## Architecture

Keep generative recipe behavior behind an application capability so domain/application logic remains independently testable. The Apple Foundation Models adapter owns availability checks and selection between supported Apple model runtimes. Do not introduce a Pantrified server-side LLM provider merely to meter or proxy PCC.

## Source basis

Verified against Apple's current Foundation Models documentation in October 2026. Apple documents `PrivateCloudComputeLanguageModel` as an iOS 27+ server-based Apple Intelligence model with stronger reasoning and a 32K context window, no developer-managed authentication/API keys for the PCC call path, and per-person daily request limits.