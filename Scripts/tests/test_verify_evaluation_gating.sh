#!/usr/bin/env bash
# Checks Scripts/verify-evaluation-gating.sh against stand-in executables.
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/verify-evaluation-gating.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

expect_exit() {
  local description="$1" expected="$2"
  shift 2
  local actual=0
  "$@" >/dev/null 2>&1 || actual=$?
  if [ "$actual" -ne "$expected" ]; then
    echo "FAIL: $description: expected exit $expected, got $actual" >&2
    failures=$((failures + 1))
  fi
}

printf 'binary\0\0$s14PantrifiedEvaluationViewV\0$s14PantrifiedEvaluationModelC\0more' >"$work/with-tab"
printf 'binary\0\0$s14PantrifiedRootViewV\0$s21PantrifiedEvaluationRunnerV\0more' >"$work/without-tab"
printf 'binary\0\0EvaluationView only' >"$work/half-tab"

expect_exit "a binary with the tab passes present" 0 "$script" "$work/with-tab" present
expect_exit "a binary with the tab fails absent" 1 "$script" "$work/with-tab" absent
expect_exit "a binary without the tab passes absent" 0 "$script" "$work/without-tab" absent
expect_exit "a binary without the tab fails present" 1 "$script" "$work/without-tab" present
expect_exit "a binary with only one of the two types fails absent" 1 "$script" "$work/half-tab" absent
expect_exit "a binary with only one of the two types fails present" 1 "$script" "$work/half-tab" present
expect_exit "a missing file is a usage error" 2 "$script" "$work/nothing" absent
expect_exit "an unknown expectation is a usage error" 2 "$script" "$work/with-tab" maybe
expect_exit "missing arguments are a usage error" 2 "$script"

exit "$failures"
