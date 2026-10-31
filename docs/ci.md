# Continuous integration

Workflows live in `.github/workflows/`. Every action is pinned to a commit SHA and every workflow
runs with `contents: read` or less. Only `testflight.yml` uses secrets, and it runs only when started by
hand from `main`. A change that touches only `docs/` or Markdown files starts no run of `ci.yml` or
`ios-build.yml`.

## Implemented

| Workflow | Job | What it runs |
|---|---|---|
| `ci.yml` | Package tests | `swift test` on Linux in the `swift:6.1.2-noble` image. Every test target runs, so a new one needs no change to the workflow |
| `ci.yml` | Repository hygiene | `Scripts/verify-repo-hygiene.sh` (no tracked generated Xcode project, per-developer signing settings, signing material, environment files or private key text), `shellcheck` at error severity, the tests for the shell scripts, the tests for the FoodKeeper converter, a check that the bundled snapshot regenerates unchanged from `Data/FoodKeeper` (`docs/storage-guidance.md`), the tests for the two privacy checks and for the icon check, the check that the source icon is a 1024 by 1024 PNG without transparency, and the checks that the privacy manifest is well formed and declares exactly the required-reason API categories the code uses (`docs/testflight-readiness.md`), the tests for `Scripts/testflight.py`, `Scripts/testflight-project.py` and the export-compliance check, and the check that `project.yml` declares no non-exempt encryption |
| `ios-build.yml` | Xcode build, tests and Release archive | On one macOS runner: `make generate` (XcodeGen), a check that the generated project runs no scripts and fits in a job output (`Scripts/testflight-project.py`, as `testflight.yml` requires), `make build` and `make test` on an iPhone simulator, `make test-package` (the package tests against Apple's Foundation, including the SwiftData store tests, which compile only there), `make archive-unsigned`, a Release archive for a device with signing off, and `make archive-evaluation-unsigned`, the same archive with the Evaluation tab compiled in (`docs/evaluation.md`). `Scripts/verify-evaluation-gating.sh` then checks that the Release app's executable has none of the tab's types and the Evaluation app's has them. `Scripts/verify-privacy-manifest.py` checks that each archived app carries the privacy manifest unchanged, `Scripts/verify-app-icon.py` that each carries the compiled icon, and `Scripts/verify-export-compliance.py` that each declares no non-exempt encryption. The package tests and the archive run even when the build or app tests failed. On failure, a last step repeats only the Xcode error lines in the job summary, and the logs upload as `ios-build-logs` |
| `screenshots.yml` | Screenshots of Today, Food and Add food | Run by hand, and on a change to the capture itself. Builds a Debug app and runs `Scripts/capture-screenshots.sh`, which starts it on sample food (`-pantrified-scenario sample`, Debug builds only) and photographs Today, Food and Add food on the newest iPhone Pro Max simulator (the 6.9-inch size App Store Connect asks for, with the Debug-only Evaluate tab hidden) in light and dark mode at the default text size and the largest accessibility size, 12 images uploaded as the `screenshots` artifact. It checks nothing: it exists so a change to a screen can be looked at without a Mac |
| `testflight.yml` | Signed build and upload | Run by hand from `main` only. A job without secrets generates the Xcode project with XcodeGen and passes it on; the signing job, in the `testflight` Environment, installs no third-party tool, checks the project and the six secrets, archives the `release` or `evaluation` variant with manual signing (Apple Distribution certificate, App Store profile), checks the archive and the exported .ipa, and with `upload` on sends the .ipa to App Store Connect with `altool`. A last step removes the keychain and all signing material. Setup, secrets and the first run: `docs/testflight-upload.md` |

The runner is the `MACOS_RUNNER` repository variable when set, otherwise `xcode-27`. The iOS 27
SDK needs the Xcode 27 image; the app's minimum is iOS 26.

`Scripts/select-simulator.sh` picks the newest available `iPhone <number> Pro` simulator, so the
Makefile does not name a model the runner image may lack. `DESTINATION` overrides it.

## Evidence levels

| Check | What it establishes |
|---|---|
| Linux `swift test` | Domain and application behavior on the Linux toolchain |
| macOS `make test-package` | The same behavior against Apple's Foundation, and the local store on SwiftData (`docs/persistence.md`) |
| `make build` and `make test` | The app compiles for the simulator and its hosted tests pass, including the local store opened, written and read back inside the app's sandbox |
| `make archive-unsigned` | The Release configuration compiles for a device |
| `testflight.yml` with upload off | The secrets match each other and the app signs and exports for App Store distribution on the runner |
| A TestFlight or Debug build on a physical iPhone | Behavior on that device and iOS version, including the Apple models. Nothing in CI runs on a device, and the simulator does not run the Apple models |

A green workflow is not device verification.

## Not built yet

- **A first signed run.** `testflight.yml` has not run with the secrets yet; its scripts are tested
  on Linux only (`docs/testflight-upload.md`).
- **UI tests and screenshots.**
- **A Private Cloud Compute runtime.** Only the on-device model has an adapter.
