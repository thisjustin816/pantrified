# TestFlight upload

`.github/workflows/testflight.yml` builds the app signed for App Store distribution and uploads it to App
Store Connect. It runs only when started by hand from `main`, and its signing job runs in the `testflight`
GitHub Environment. Pull requests and pushes never start it, and no other workflow uses secrets.

## What a run does

1. A first job fails unless the run is on `main`. It runs before the Environment asks for approval.
2. A second job, with no secrets and outside the Environment, installs XcodeGen from Homebrew (unpinned),
   generates the Xcode project, and passes it to the signing job as a job output, on a separate runner.
   `Scripts/testflight-project.py` packs it there, and in the signing job checks its SHA-256, refuses
   anything but plain files under `Pantrified.xcodeproj`, and fails if the project has a shell script build
   phase, a build rule, an external build system target, scheme pre- or post-actions, a build setting that
   replaces the compiler, linker or Swift driver, or a compiler plugin flag. The signing job installs no
   third-party tool.
3. In the signing job, after approval, `Scripts/testflight.py check` fails unless the ref is `main`, the
   inputs are valid and each of the six secrets below is set and well formed. It names each problem and never
   prints a value. It also checks the profile against `Config/testflight.json` and the certificate: UUID,
   name, team, bundle identifier, App Store type, TestFlight permission, expiry, and that the profile holds
   the certificate. The generated project is unpacked and checked next.
4. `testflight.py xcconfig` writes `Config/Signing.local.xcconfig` (git-ignored) with manual signing, the team
   and the profile name, so only the app target gets the profile.
5. `testflight.py prepare` writes the certificate and private key into a new directory in `$RUNNER_TEMP`
   (mode 0700, files 0600) and installs the profile as `<UUID>.mobileprovision` in
   `~/Library/MobileDevice/Provisioning Profiles` and `~/Library/Developer/Xcode/UserData/Provisioning Profiles`.
   `Scripts/testflight-keychain.sh setup` joins the certificate and key into a .p12 under a random one-time
   password and deletes the PEM key and the certificate file at once. It imports the .p12 into a new keychain
   in `$RUNNER_TEMP` under another random password, with the key non-extractable (`-x`) and only
   `/usr/bin/codesign` allowed to use it, sets the key's partition list for codesign, and puts the keychain
   first in the search list. Both passwords are masked in the log and never appear on a command line. It
   fails unless the keychain holds exactly one valid Apple Distribution identity.
6. `Scripts/testflight-xcode.sh archive` archives the Release configuration with manual signing and the build
   number. No command passes `-allowProvisioningUpdates`, so Xcode cannot create or change certificates,
   profiles or identifiers in the team.
7. The archived app is checked like the unsigned archives in `ios-build.yml` (Evaluation tab present or absent,
   privacy manifest, icon, export compliance), and its bundle identifier, versions and embedded profile are
   checked against the run.
8. `xcodebuild -exportArchive` exports an .ipa with manual signing. The exported app's signature is verified,
   and its signing certificate, team, entitlements (no `get-task-allow`, `beta-reports-active` set) and embedded
   profile are checked.
9. With **upload** on, `testflight.py write-api-key` writes the App Store Connect key in its own step, and
   `xcrun altool --upload-package` uploads the same .ipa that was checked.
10. A last step, which runs however the job ends, restores the keychain search list, deletes the keychain,
    removes the certificate, keys, installed profiles, `Signing.local.xcconfig`, the archive and the .ipa.
11. A build record (variant, internal-only flag, version, build number, commit, run and upload result) is
    written to the job summary and uploaded as an artifact. It holds no secret and no app binary, because
    the artifacts and logs of a public repository are public.

## Inputs, variants and build numbers

| Input | Values | Effect |
|---|---|---|
| `variant` | `release` (default), `evaluation` | `evaluation` compiles in the Evaluation tab (`docs/evaluation.md`) and exports the build for internal TestFlight testing only |
| `upload` | on (default), off | Off builds, signs, exports and checks the app, then stops before the upload |

The variant appears in the run name, the archive name (`Pantrified-Release` or `Pantrified-Evaluation`), the
step names and the artifact name, for example `testflight-evaluation-0.1-build-12.1`. Both variants use the
same bundle identifier and app record, so they differ in TestFlight only by build number. Do not submit an
evaluation build for review or add it to an external group.

The marketing version is `MARKETING_VERSION` in `project.yml`. The build number is
`<run number>.<run attempt>`, so every new run and every re-run uploads a higher number, and App Store
Connect never sees a repeat. Run numbers restart if the workflow file is renamed. If a build with a higher
number was ever uploaded by hand for the same version, raise `MARKETING_VERSION` instead.

## What the owner sets up in GitHub

### The `testflight` Environment

Create it **before** the workflow reaches `main`. If the workflow runs first, GitHub creates a `testflight`
Environment with no protection rules, and the run proceeds without approval.

In **Settings > Environments**, create an environment named `testflight` and set:

- **Required reviewers:** yourself. Leave **Prevent self-review** off, or you cannot approve your own runs.
- **Deployment branches and tags:** **Selected branches and tags**, with one branch rule: `main`.
- **Allow administrators to bypass configured protection rules:** off, so the approval applies to you too.

### Secrets

Store these as **environment secrets** of `testflight`. The workflow also reads repository secrets of the
same names, but those reach a workflow run on any branch, so the branch rule above would not protect them.
If they are repository secrets now, create them in the Environment and then delete the repository copies.

| Secret | Content |
|---|---|
| `APPLE_DISTRIBUTION_CERTIFICATE_BASE64` | Base64 of the Apple Distribution certificate as Apple issues it (DER `.cer`) |
| `APPLE_DISTRIBUTION_PRIVATE_KEY` | The complete PEM text of the certificate's private key, without a passphrase |
| `APPLE_PROVISIONING_PROFILE_BASE64` | Base64 of the App Store `.mobileprovision` |
| `APP_STORE_CONNECT_PRIVATE_KEY` | The complete PEM text of the App Store Connect API key (`.p8`) |
| `APP_STORE_CONNECT_KEY_ID` | The API key's 10-character ID |
| `APP_STORE_CONNECT_ISSUER_ID` | The team's issuer ID, a UUID shown with the API keys |

These names are defined once, in `Config/testflight.json`. `Scripts/tests/test_testflight.py` fails if the
workflow reads any other secret or this page leaves one out.

### Variables

None are required. `MACOS_RUNNER`, as for `ios-build.yml`, overrides the runner (default `xcode-27`, a
GitHub-hosted runner). It must stay a GitHub-hosted runner, which is a fresh machine for each job: the
cleanup step removes what the run wrote, but a self-hosted runner would keep anything a failed cleanup or a
crash left behind, and would share the machine between the job that runs XcodeGen and the signing job. The
identifiers below are not secret and live in `Config/testflight.json`.

## What the guards protect

The `main-only` job, the signing job's `if:` and the ref check in `testflight.py check` refuse a dispatch of
the workflow as it is written. They do not stop a changed copy: anyone who can push a branch can edit the
workflow on that branch, remove all three, and dispatch it there. The protection against that is the
Environment's deployment branch rule, which withholds **Environment** secrets from any run whose ref is not
`main`. Repository secrets are not covered by that rule, which is why the secrets must be Environment
secrets.

Before approving a deployment, open the run and confirm that its branch is `main` and its commit is the
`main` commit you expect.

## Identifiers and signing material

| Item | Value |
|---|---|
| Bundle identifier | `com.thisjustin816.Pantrified` |
| Team ID | `S2TFTKR4CS` |
| App Store Connect app ID | `6829003513` |
| Signing certificate | Apple Distribution |
| Provisioning profile | `Pantrified App Store`, UUID `98c9f99b-5d53-40bc-af18-d953d630993e` |

**The certificate and the profile expire on 30 October 2027.** From 30 days before, each run warns. After
that date the check fails. To renew, create a new Apple Distribution certificate and App Store profile,
replace the three signing secrets, and update `profile_uuid` (and `profile_name` if it changed) in
`Config/testflight.json`.

The profile also allows CloudKit and production push, which the app does not use yet. That is allowed: a
profile lists the entitlements an app may claim, and every entitlement the app's signature claims must be in
that list, but the reverse is not required (Apple, TN3125 "Inside Code Signing: Provisioning Profiles"). The
app claims neither until an entitlements file adds them.

## App Store Connect

- **App record:** app ID `6829003513` for `com.thisjustin816.Pantrified`. The upload fails without it.
- **API key:** a team key with the **Developer** role. It is used only for the upload. App Store Connect Help
  lists Developer among the roles that can upload builds. Whether a Developer-role API key is accepted by
  `altool --upload-package` is not confirmed until the first upload. If it is rejected, the next role up is
  App Manager; change the key's role only with the owner's approval.
- **Export compliance:** answered in the app (`docs/testflight-readiness.md`), so App Store Connect does not
  ask on each build.
- **Testers:** the workflow only uploads. The Internal Testers group has automatic distribution off, so add a
  build to it by hand after App Store Connect finishes processing it.
- **Internal-only evaluation builds:** the evaluation export sets `testFlightInternalTestingOnly`, and the build
  record and job summary show `internal_only: true`. Whether the flag survives an upload made with altool is
  not confirmed. After the first evaluation upload, open the build in App Store Connect's TestFlight tab: an
  internal-only build is labeled as such and cannot be added to an external group or submitted for review.
  If it can be, the flag did not survive, and keeping evaluation builds out of external groups is up to
  whoever distributes them.

## The first run

1. Create the Environment and its secrets as above.
2. Merge the workflow to `main`. GitHub lists a manual workflow only once it is on the default branch.
3. In **Actions > TestFlight > Run workflow**, choose branch `main`, variant `release`, and clear **Upload**.
4. Approve the deployment when GitHub asks.
5. A green run means the secrets are present and match each other, the keychain import worked, the archive
   and the export are signed with the distribution certificate and the profile, and the checks in steps 7 and
   8 above passed. Nothing is uploaded.
6. If the check step fails, its error names the secret and the rule it breaks. If the keychain step fails
   with a mismatch, the private key is not the certificate's key.
7. This run is also the first test of the non-extractable import and the partition list. If the archive
   or export step then fails to sign, look in its log for `errSecInternalComponent`, "User interaction is
   not allowed", or a codesign step that stops until the job times out: each means codesign could not use
   the key without a prompt. Report it before changing the import options.
8. Run again with **Upload** on. Then wait for App Store Connect to process the build and add it to the
   Internal Testers group.

## Limits

- The workflow has not run on a Mac with the secrets. The first run is the first test of the keychain import,
  manual signing with this profile, the export and the upload. The scripts are tested on Linux with stand-ins
  for `security`, `openssl`, `xcodebuild`, `xcrun` and `codesign`.
- The key ID and issuer ID are command-line arguments of `altool`, which has no other way to take them. They
  are masked in the log, and neither authenticates without the private key. The private keys are only ever in
  files of mode 0600 and in the environment of the steps that write them.
- The project check limits what a tampered project could run in the signing job, but it does not prove the
  project is what XcodeGen would generate from `project.yml`: a compromised XcodeGen could still change
  build settings that the check does not list. The checks on the signed app (bundle identifier, versions,
  profile, entitlements and signature) run after the build.
- Run logs of a public repository are public. They show the signing identity's name and the team ID, which
  are not secret.
