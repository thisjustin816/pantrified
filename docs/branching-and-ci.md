# Branching and CI plan

## While the repository is private

- Work happens on feature branches. Nothing merges to `main` in this phase.
- Branches stack: a later branch is cut from an earlier one and contains its commits.
- Verification is `swift test` on Linux for `PantrifiedDomain` and `PantrifiedApplication`. Those tests do not compile against the iOS SDK and say nothing about the simulator or a device. Report results at that level and no higher.

## Moving to macOS

The work moves to macOS when it needs Xcode: the app target, SwiftData, AVFoundation and Vision, CloudKit, EventKit, StoreKit, or Foundation Models.

1. The macOS workflows, modeled on the Press Any workflows, are in `.github/workflows/` and described in `docs/ci.md`.
2. Squash merge the top branch of the stack into `main`. Squashing the branches in a stack separately conflicts on their shared history.
3. Make the repository public so the workflows can run.
4. The first macOS run builds the app against the iOS SDK and runs the package tests against Apple's Foundation, before anything that depends on another Apple framework is added.

Update the "Product status" line in `README.md` as part of the squash merge.
