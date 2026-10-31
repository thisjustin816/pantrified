# Branching and merging

- Work happens on a branch named for the change, such as `feature/...`, `fix/...` or `docs/...`.
  A later branch may be cut from an earlier one; squash merge the top of such a stack, not each
  branch, because separate squashes conflict on their shared history.
- Changes reach `main` through a pull request that is squash merged on GitHub. A merge made on
  GitHub takes its author email from the account's settings, which must show the private address
  `41129295+thisjustin816@users.noreply.github.com`. Check the squashed commit's author after a merge.
- Delete a branch after its pull request merges.
- Pull-request checks run without secrets. Signed TestFlight uploads run after a push to `main`, or by
  hand from a branch (`docs/testflight.md`). `docs/ci.md` lists the workflows and what each check
  establishes. A green workflow is not device verification, and results are reported at the level
  actually reached: Linux package tests, an Apple SDK build, a simulator run, or a physical device.
- The repository is public so its workflows can run, but it is not open source: see `LICENSE`.
