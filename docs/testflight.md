# TestFlight

`.github/workflows/testflight.yml` signs a Release archive and uploads it to App Store Connect. It is the
same pipeline as the owner's Press Any project, adapted for Pantrified.

## How it runs

- **Automatically from `main`.** When the **iOS build** workflow passes on a push to `main`, the workflow
  waits for **CI** on the same commit, then archives and uploads the release variant. A push that changes
  only `docs/`, `.github/`, `LICENSE` or Markdown files since the previous upload is skipped. GitHub runs a
  `workflow_run` workflow from `main`'s copy, and the job accepts only pushes to this repository's `main`,
  so pull requests, including ones from forks, never reach the secrets.
- **By hand from any branch.** **Actions > TestFlight > Run workflow**, pick the branch and the inputs. Tags
  do not run the upload job.

| Input | Values | Effect |
|---|---|---|
| `variant` | `release` (default), `evaluation` | `evaluation` compiles in the Evaluation tab (`docs/evaluation.md`) and exports the build for internal testing only |
| `upload` | on (default), off | Off signs, checks and exports the app, then stops before the upload |

Runs share one queue (`concurrency: testflight`), so two never sign at once.

The job installs XcodeGen with Homebrew, generates the project, then runs `Scripts/upload-testflight.sh`.
The script checks the certificate against the private key and the profile against the app, team and
certificate, imports the identity into a temporary keychain, archives with manual signing, checks the
archived app (Evaluation tab present or absent, privacy manifest, icon, export compliance, bundle ID and
build number), exports an .ipa and uploads it with `altool`. It deletes the keychain, the installed
profile, `Config/Signing.local.xcconfig` and every signing file when it exits, however it exits.

Each upload sets **What to Test** from the commits since the previous upload (`Scripts/testflight-notes.py`),
and each `main` upload is tagged `testflight/<build>` by a separate job without the secrets. If the notes
fail to post, the upload still counts; add the text in App Store Connect.

## Secrets

Environment secrets of the `testflight` Environment (**Settings > Environments > testflight**). The upload
job names that Environment, which is how it receives them; a job that does not name it gets nothing. The
tag job does not name it and holds no secrets.

The Environment is set up so that runs go unattended: no required reviewers, and deployment branches
limited to `main` and `feature/*` (**Selected branches and tags**), with administrator bypass off. A run
from any other branch, a tag or a fork is refused before it reaches the secrets, so a manual run from a
branch named outside `feature/` will not work.

| Secret | Value |
|---|---|
| `APPLE_DISTRIBUTION_PRIVATE_KEY` | Entire PEM text of the distribution certificate's private key |
| `APPLE_DISTRIBUTION_CERTIFICATE_BASE64` | Base64 of Apple's `.cer` |
| `APPLE_PROVISIONING_PROFILE_BASE64` | Base64 of the App Store `.mobileprovision` |
| `APP_STORE_CONNECT_KEY_ID` | The API key's Key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | The Issuer ID from the Team Keys page |
| `APP_STORE_CONNECT_PRIVATE_KEY` | Entire `.p8` text |

The API key is a team key with the Developer role. The identifiers are in `Scripts/upload-testflight.sh`:
bundle `com.thisjustin816.Pantrified`, team `S2TFTKR4CS`, profile "Pantrified App Store" with UUID
`98c9f99b-5d53-40bc-af18-d953d630993e`. The App Store Connect app ID is `6829003513`. `MACOS_RUNNER`, an
optional repository variable, overrides the runner (default `xcode-27`).

**The certificate and the profile expire on 30 October 2027.** Replace both, and the three signing
secrets, before then.

## First run

1. Merge the workflow to `main`. GitHub lists a manual workflow only once it is on the default branch,
   and the merge itself starts an automatic upload once the iOS build and CI pass.
2. To check signing without an upload first, run it by hand with **upload** cleared. A green run means the
   secrets match each other and the app signs, passes its checks and exports.
3. Run it with **upload** on, or let the next push to `main` upload.
4. Wait for Apple to process the build, then add it to the Internal Testers group in App Store Connect.
   Turn on **Enable automatic distribution** for that group (**Apps > Pantrified > TestFlight > Internal
   Testing > Internal Testers**) and each processed build reaches it on its own; with it off, nothing
   reaches testers until a build is added by hand.

Confirmed by the first upload, version 0.1 build 4, from `main` on the `xcode-27` runner: signing and export
work, and the Developer-role key can upload with `altool` and set What to Test, so that key needs no wider
role.

Not yet confirmed: that `testFlightInternalTestingOnly` survives an `altool` upload. After the first
evaluation upload, check in App Store Connect that the build cannot be added to an external group. Never add
an evaluation build to an external group.

## Build numbers

The marketing version is `MARKETING_VERSION` in `project.yml`. The build number is the workflow run number,
and a retried run adds its attempt (`57.2`), because Apple refuses a second binary with the same number.
Keep this workflow as the only source of build numbers.

## Accepted risk

There is no approval step. Any workflow that runs from `main` or a `feature/*` branch and names the
`testflight` Environment can read the secrets, and a workflow file on a branch can be changed by whoever can
push to it, so anything that can push such a branch holds the secrets. XcodeGen also comes from Homebrew
unpinned in the same job. The owner is the only person with access and accepts this.

## If a secret may have leaked

1. Revoke the API key in App Store Connect (**Users and Access > Integrations**).
2. Revoke the distribution certificate in the Apple Developer account and create a new one.
3. Regenerate the provisioning profile for the new certificate, and update its UUID in
   `Scripts/upload-testflight.sh`.
4. Replace the six secrets.
5. Check App Store Connect for builds you did not upload, and expire them.

## Removing the XcodeGen risk later

Download a fixed XcodeGen release instead of using Homebrew, and check its SHA-256 against a value committed
here before running it.
