#!/usr/bin/env bash
# Checks Scripts/testflight-keychain.sh against stand-ins for security and openssl that record how
# they were called, so the test runs without a Mac: the passwords never reach a command line, the
# search list is restored and each failure stops the setup.
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/testflight-keychain.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
keychain_password="$(printf 'a%.0s' {1..64})"
p12_password="$(printf 'b%.0s' {1..64})"

fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

mkdir -p "$work/bin"
cat >"$work/bin/security" <<'STUB'
#!/usr/bin/env bash
printf 'security' >>"$STUB_DIR/argv"
printf ' %s' "$@" >>"$STUB_DIR/argv"
printf '\n' >>"$STUB_DIR/argv"
case "$1" in
  -i)
    while IFS= read -r line; do
      printf '%s\n' "$line" >>"$STUB_DIR/stdin"
      set -- $line
      if [ "$1" = create-keychain ]; then
        : >"${!#}"
      fi
    done
    ;;
  list-keychains)
    if [ "${4:-}" = -s ]; then
      shift 4
      printf '%s\n' "$@" >"$STUB_DIR/list"
    else
      sed 's/.*/    "&"/' "$STUB_DIR/list"
    fi
    ;;
  find-identity) printf '%s\n' "$STUB_IDENTITIES" ;;
  delete-keychain) rm -f "$2" ;;
esac
STUB
cat >"$work/bin/openssl" <<'STUB'
#!/usr/bin/env bash
printf 'openssl' >>"$STUB_DIR/argv"
printf ' %s' "$@" >>"$STUB_DIR/argv"
printf '\n' >>"$STUB_DIR/argv"
case "$1" in
  rand)
    count="$(cat "$STUB_DIR/rand-count" 2>/dev/null || echo 0)"
    echo $((count + 1)) >"$STUB_DIR/rand-count"
    if [ "$count" -eq 0 ]; then printf '%s\n' "$STUB_RAND_1"; else printf '%s\n' "$STUB_RAND_2"; fi
    ;;
  x509 | pkcs12)
    command="$1"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -out) : >"$2" ;;
        -passout) cp "${2#file:}" "$STUB_DIR/p12-password-seen" ;;
      esac
      shift
    done
    if [ "$command" = pkcs12 ]; then exit "${STUB_PKCS12_STATUS:-0}"; fi
    ;;
esac
STUB
chmod +x "$work/bin/security" "$work/bin/openssl"

identity='  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Apple Distribution: Owner (S2TFTKR4CS)"
     1 valid identities found'

reset() {
  rm -rf "$work/stub" "$work/material" "$work/test.keychain-db"
  mkdir -p "$work/stub" "$work/material"
  printf '%s\n' /Users/runner/Library/Keychains/login.keychain-db >"$work/stub/list"
  echo cert >"$work/material/certificate.der"
  echo key >"$work/material/private-key.pem"
  export STUB_DIR="$work/stub" STUB_IDENTITIES="$identity" STUB_PKCS12_STATUS=0
  export STUB_RAND_1="$keychain_password" STUB_RAND_2="$p12_password"
}

run() {
  PATH="$work/bin:$PATH" "$script" "$1" "${2:-$work/material}" "${3:-$work/test.keychain-db}" \
    >"$work/out" 2>&1
}

reset
if ! run setup; then
  fail "setup should succeed: $(cat "$work/out")"
fi
grep -q "::add-mask::$keychain_password" "$work/out" || fail "the keychain password is not masked"
grep -q "::add-mask::$p12_password" "$work/out" || fail "the .p12 password is not masked"
if grep -qE "$keychain_password|$p12_password" "$work/stub/argv"; then
  fail "a password appears in a command line"
fi
grep -q "^create-keychain -p $keychain_password $work/test.keychain-db$" "$work/stub/stdin" ||
  fail "the keychain is not created on standard input"
grep -q "^import $work/material/signing.p12 -k $work/test.keychain-db -f pkcs12 -P $p12_password -T /usr/bin/codesign" \
  "$work/stub/stdin" || fail "the identity is not imported on standard input"
grep -q "^set-key-partition-list -S apple-tool:,apple:,codesign: -s -k $keychain_password " "$work/stub/stdin" ||
  fail "codesign is not given access to the key"
[ "$(cat "$work/stub/p12-password-seen")" = "$p12_password" ] || fail "openssl did not get the .p12 password from a file"
[ "$(head -n 1 "$work/stub/list")" = "$work/test.keychain-db" ] || fail "the keychain is not first in the search list"
grep -qx /Users/runner/Library/Keychains/login.keychain-db "$work/stub/list" || fail "the login keychain left the search list"
for leftover in signing.p12 p12-password certificate.pem; do
  [ ! -e "$work/material/$leftover" ] || fail "$leftover is left behind after setup"
done

if ! run teardown; then
  fail "teardown should succeed: $(cat "$work/out")"
fi
[ "$(cat "$work/stub/list")" = /Users/runner/Library/Keychains/login.keychain-db ] || fail "the search list is not restored"
[ ! -e "$work/test.keychain-db" ] || fail "the keychain is not deleted"

reset
run teardown || fail "teardown with nothing to remove should succeed"

reset
STUB_PKCS12_STATUS=1
if run setup; then fail "a key that does not match the certificate should fail"; fi
grep -q APPLE_DISTRIBUTION_PRIVATE_KEY "$work/out" || fail "the mismatch message does not name the secret"
[ ! -e "$work/test.keychain-db" ] || fail "a keychain is created after the .p12 failed"
[ ! -e "$work/material/p12-password" ] || fail "the .p12 password file is left after a failure"

for identities in "     0 valid identities found" "$identity
  2) FEDCBA9876543210FEDCBA9876543210FEDCBA98 \"Apple Distribution: Other (ABCDE12345)\"" \
  '  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Apple Development: Owner (S2TFTKR4CS)"'; do
  reset
  STUB_IDENTITIES="$identities"
  if run setup; then fail "setup should fail with identities: $identities"; fi
done

reset
rm -rf "$work/with space"
cp -R "$work/material" "$work/with space"
status=0
run setup "$work/with space" || status=$?
[ "$status" -eq 2 ] || fail "a path with a space should be refused before anything runs, got status $status"
if [ -s "$work/stub/argv" ]; then fail "a command ran for a path with a space"; fi

reset
: >"$work/test.keychain-db"
if run setup; then fail "an existing keychain should be refused"; fi

reset
rm "$work/material/certificate.der"
if run setup; then fail "a missing certificate should fail"; fi

reset
STUB_RAND_1="not random"
if run setup; then fail "a password that is not 64 hex digits should fail"; fi

exit "$failures"
