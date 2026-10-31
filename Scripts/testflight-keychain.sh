#!/usr/bin/env bash
# Holds the distribution identity in a temporary keychain for a signed build, and removes it.
# Usage: testflight-keychain.sh setup|teardown MATERIAL_DIR KEYCHAIN
#
# setup joins MATERIAL_DIR/certificate.der and MATERIAL_DIR/private-key.pem (written by
# testflight.py prepare) into a .p12 under a random one-time password, imports it into a new
# keychain at KEYCHAIN under another random password, lets codesign use the key, and puts the
# keychain first in the search list. The PEM key and the certificate are deleted as soon as the .p12
# is made, and the key is imported as non-extractable (-x) with only codesign allowed to use it.
# It saves the previous search list in MATERIAL_DIR.
# teardown restores that list and deletes the keychain.
#
# Both passwords are masked in the job log, reach openssl through a file and reach security on
# standard input (security -i), so neither appears in any process's arguments. security -i splits
# its input on spaces, so the paths must not contain any. Written for the bash 3.2 macOS ships.
set -euo pipefail

usage() {
  echo "usage: $0 setup|teardown MATERIAL_DIR KEYCHAIN" >&2
  exit 2
}

[ "$#" -eq 3 ] || usage
action="$1"
material="$2"
keychain="$3"
saved_list="$material/original-keychains"

case "$material$keychain" in
  *[[:space:]\"\'\\]*)
    echo "error: the material directory and keychain paths must not contain spaces, quotes or backslashes" >&2
    exit 2
    ;;
esac

# Prints the user keychain search list, one path per line, without the quotes security adds.
search_list() {
  security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//'
}

new_password() {
  local value
  value="$(openssl rand -hex 32)"
  if ! printf '%s' "$value" | grep -Eq '^[0-9a-f]{64}$'; then
    echo "error: openssl did not produce a random password" >&2
    exit 1
  fi
  printf '%s' "$value"
}

setup() {
  local certificate="$material/certificate.der" key="$material/private-key.pem"
  local p12="$material/signing.p12" p12_password_file="$material/p12-password"
  local keychain_password p12_password identities count joined
  local -a original=()

  for file in "$certificate" "$key"; do
    if [ ! -f "$file" ]; then
      echo "error: $file is missing; run testflight.py prepare first" >&2
      exit 1
    fi
  done
  if [ -e "$keychain" ]; then
    echo "error: $keychain already exists; a previous run was not cleaned up" >&2
    exit 1
  fi

  umask 077
  keychain_password="$(new_password)"
  p12_password="$(new_password)"
  echo "::add-mask::$keychain_password"
  echo "::add-mask::$p12_password"
  printf '%s\n' "$p12_password" >"$p12_password_file"

  joined=0
  # The 3DES and SHA-1 choices are the ones every macOS version of security can import.
  if openssl x509 -inform DER -in "$certificate" -out "$material/certificate.pem" &&
    openssl pkcs12 -export -inkey "$key" -in "$material/certificate.pem" -out "$p12" \
      -passout "file:$p12_password_file" -name "Pantrified distribution" \
      -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1; then
    joined=1
  fi
  rm -f "$key" "$certificate" "$material/certificate.pem"
  if [ "$joined" -ne 1 ]; then
    rm -f "$p12" "$p12_password_file"
    echo "error: openssl could not join the certificate and private key; check that" \
      "APPLE_DISTRIBUTION_PRIVATE_KEY is the key of APPLE_DISTRIBUTION_CERTIFICATE_BASE64" >&2
    exit 1
  fi

  search_list >"$saved_list"
  while IFS= read -r line; do
    [ -n "$line" ] && original+=("$line")
  done <"$saved_list"

  # security -i keeps going after a failed command, so each result is checked afterwards.
  printf '%s\n' \
    "create-keychain -p $keychain_password $keychain" \
    "set-keychain-settings -t 3600 $keychain" \
    "unlock-keychain -p $keychain_password $keychain" \
    "import $p12 -k $keychain -f pkcs12 -x -P $p12_password -T /usr/bin/codesign" \
    "set-key-partition-list -S apple-tool:,apple:,codesign: -s -k $keychain_password $keychain" |
    security -i >/dev/null
  rm -f "$p12" "$p12_password_file"

  if [ ! -f "$keychain" ]; then
    echo "error: security did not create $keychain" >&2
    exit 1
  fi
  if [ "${#original[@]}" -gt 0 ]; then
    security list-keychains -d user -s "$keychain" "${original[@]}"
  else
    security list-keychains -d user -s "$keychain"
  fi

  identities="$(security find-identity -v -p codesigning "$keychain")"
  count="$(printf '%s\n' "$identities" | grep -cE '^ *[0-9]+\) [0-9A-F]+ "Apple Distribution: ' || true)"
  if [ "$count" -ne 1 ]; then
    echo "error: expected one valid Apple Distribution identity in the temporary keychain, found $count" >&2
    exit 1
  fi
  echo "The distribution identity is in a temporary keychain at $keychain."
}

teardown() {
  local status=0
  local -a original=()
  if [ -f "$saved_list" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && original+=("$line")
    done <"$saved_list"
    if [ "${#original[@]}" -gt 0 ]; then
      security list-keychains -d user -s "${original[@]}" || status=1
    fi
  fi
  if [ -e "$keychain" ]; then
    if ! security delete-keychain "$keychain"; then
      rm -f "$keychain"
      status=1
    fi
  fi
  if [ "$status" -ne 0 ]; then
    echo "error: the keychain search list or the temporary keychain could not be restored cleanly" >&2
  fi
  return "$status"
}

case "$action" in
  setup) setup ;;
  teardown) teardown ;;
  *) usage ;;
esac
