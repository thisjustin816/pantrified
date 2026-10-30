#!/usr/bin/env bash
# Checks Scripts/verify-repo-hygiene.sh in a throwaway repository: it passes a clean tree and
# fails each kind of file it exists to reject.
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/verify-repo-hygiene.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

new_repo() {
  rm -rf "$work/repo"
  mkdir -p "$work/repo"
  git -C "$work/repo" init -q
}

run() {
  (cd "$work/repo" && "$script" >/dev/null 2>&1)
}

expect_pass() {
  if ! run; then
    echo "FAIL: $1 should pass" >&2
    failures=$((failures + 1))
  fi
}

expect_fail() {
  if run; then
    echo "FAIL: $1 should fail" >&2
    failures=$((failures + 1))
  fi
}

new_repo
echo "plain" >"$work/repo/README.md"
git -C "$work/repo" add -A
expect_pass "a clean tree"

for tracked in "Pantrified.xcodeproj/project.pbxproj" "Config/Signing.local.xcconfig" "AuthKey_ABC.p8" \
  "dist.p12" "app.mobileprovision" "certs/server.pem" ".env"; do
  new_repo
  mkdir -p "$work/repo/$(dirname "$tracked")"
  echo "x" >"$work/repo/$tracked"
  git -C "$work/repo" add -A
  expect_fail "tracked $tracked"
done

new_repo
printf '%s\n' "-----BEGIN PRIVATE KEY-----" "abc" >"$work/repo/notes.txt"
git -C "$work/repo" add -A
expect_fail "private key text in notes.txt"

new_repo
echo "x" >"$work/repo/Config.local.p8"
expect_pass "an untracked signing file, which git ignores here"

exit "$failures"
