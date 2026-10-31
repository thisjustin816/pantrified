#!/usr/bin/env bash
# Fails when the repository tracks files that must stay out of it: generated Xcode projects,
# per-developer signing settings, signing material, and private keys.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
status=0

fail() {
  echo "error: $1" >&2
  status=1
}

# Case-insensitive, so Dist.P12 or Key.PEM is caught like dist.p12.
shopt -s nocasematch
while IFS= read -r -d '' path; do
  case "$path" in
    *.xcodeproj/*) fail "generated Xcode project is tracked: $path" ;;
    Config/Signing.local.xcconfig) fail "per-developer signing settings are tracked: $path" ;;
    *.p12 | *.pfx | *.p8 | *.cer | *.mobileprovision | *.provisionprofile | *.certSigningRequest | *.pem | *.key | \
      *.keychain | *.keychain-db)
      fail "signing material is tracked: $path" ;;
    .env | .env.* | */.env | */.env.*) fail "environment file is tracked: $path" ;;
  esac
done < <(git ls-files -z)
shopt -u nocasematch

# The patterns below are written here and in the script's test, so both are excluded.
matches="$(git grep -lI -E -e '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----' -- . \
  ':!Scripts/verify-repo-hygiene.sh' ':!Scripts/tests/test_verify_repo_hygiene.sh' || true)"
if [ -n "$matches" ]; then
  while IFS= read -r path; do
    fail "private key text is tracked: $path"
  done <<<"$matches"
fi

exit "$status"
