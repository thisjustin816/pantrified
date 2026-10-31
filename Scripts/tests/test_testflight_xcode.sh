#!/usr/bin/env bash
# Checks Scripts/testflight-xcode.sh against stand-ins for xcodebuild, xcrun, codesign and unzip that
# record their arguments: the archive signs manually and compiles the Evaluation tab only for the
# evaluation variant, nothing may change signing assets, and the upload sends the key by file only.
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/testflight-xcode.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

mkdir -p "$work/bin"
for tool in xcodebuild xcrun codesign; do
  cat >"$work/bin/$tool" <<STUB
#!/usr/bin/env bash
printf '%s\n' "$tool" "\$@" >>"\$STUB_DIR/argv"
printf -- '--\n' >>"\$STUB_DIR/argv"
if [ "$tool" = xcodebuild ] && [ "\$1" = -exportArchive ] && [ -n "\${STUB_IPA:-}" ]; then
  : >"\$EXPORT_PATH/Pantrified.ipa"
fi
if [ "$tool" = codesign ] && [ "\$1" = -dvv ]; then
  echo "Authority=Apple Distribution: Owner (S2TFTKR4CS)" >&2
fi
exit "\${STUB_STATUS:-0}"
STUB
done
cat >"$work/bin/unzip" <<'STUB'
#!/usr/bin/env bash
if [ -n "${STUB_APP:-}" ]; then mkdir -p "$4/Payload/Pantrified.app"; fi
STUB
chmod +x "$work/bin/"*

reset() {
  rm -rf "$work/stub" "$work/out" "$work/export" "$work/inspect" "$work/keys"
  mkdir -p "$work/stub" "$work/export" "$work/keys"
  export STUB_DIR="$work/stub" STUB_STATUS=0 STUB_IPA=1 STUB_APP=1
  export VARIANT=release BUILD_NUMBER=12.1 ARCHIVE_PATH="$work/Pantrified-Release.xcarchive" TEAM_ID=S2TFTKR4CS
  export SIGNING_IDENTITY="Apple Distribution" EXPORT_PATH="$work/export" EXPORT_OPTIONS="$work/ExportOptions.plist"
  export IPA_PATH="$work/export/Pantrified.ipa" INSPECT_DIR="$work/inspect" APP_APPLE_ID=6829003513
  export BUNDLE_ID=com.thisjustin816.Pantrified MARKETING_VERSION=0.1 APP_STORE_CONNECT_KEY_ID=AB12CD34EF
  export APP_STORE_CONNECT_ISSUER_ID=69a6de70-03db-47e3-e053-5b8c7c11a4d1 API_PRIVATE_KEYS_DIR="$work/keys"
  : >"$work/keys/AuthKey_AB12CD34EF.p8"
}

run() {
  PATH="$work/bin:$PATH" "$script" "$@" >"$work/out" 2>&1
}

has_argument() {
  grep -qxF -- "$1" "$work/stub/argv"
}

reset
run archive || fail "the release archive should succeed: $(cat "$work/out")"
for argument in archive CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=S2TFTKR4CS "CODE_SIGN_IDENTITY=Apple Distribution" \
  CURRENT_PROJECT_VERSION=12.1 -configuration Release generic/platform=iOS "$work/Pantrified-Release.xcarchive"; do
  has_argument "$argument" || fail "the archive does not pass $argument"
done
if grep -q EVALUATION "$work/stub/argv"; then fail "the release archive compiles the Evaluation tab"; fi
if grep -q PROVISIONING_PROFILE "$work/stub/argv"; then
  fail "a profile on the command line would also apply to the package targets"
fi

reset
VARIANT=evaluation run archive || fail "the evaluation archive should succeed"
# shellcheck disable=SC2016
has_argument 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) EVALUATION' || fail "the evaluation archive lacks the Evaluation tab"

reset
if VARIANT=debug run archive; then fail "an unknown variant should fail"; fi
reset
if BUILD_NUMBER='' run archive; then fail "a missing build number should fail"; fi
reset
if STUB_STATUS=65 run archive; then fail "a failed xcodebuild should fail the archive"; fi

reset
run export || fail "the export should succeed: $(cat "$work/out")"
for argument in -exportArchive "$work/ExportOptions.plist" "$work/export"; do
  has_argument "$argument" || fail "the export does not pass $argument"
done
reset
if STUB_IPA='' run export; then fail "an export without an .ipa should fail"; fi

reset
run inspect || fail "the inspection should succeed: $(cat "$work/out")"
[ "$(cat "$work/out")" = "$work/inspect/Payload/Pantrified.app" ] || fail "the inspection does not print the app path"
grep -q "Apple Distribution" "$work/inspect/codesign.txt" || fail "codesign's description is not saved"
has_argument --strict || fail "the signature is not verified strictly"
reset
if STUB_APP='' run inspect; then fail "an .ipa without the app should fail"; fi
reset
if STUB_STATUS=1 run inspect; then fail "a signature that does not verify should fail"; fi

reset
run upload || fail "the upload should succeed: $(cat "$work/out")"
for argument in altool --upload-package "$work/export/Pantrified.ipa" 6829003513 com.thisjustin816.Pantrified 0.1 12.1 \
  --apiKey AB12CD34EF --apiIssuer; do
  has_argument "$argument" || fail "the upload does not pass $argument"
done
reset
rm "$work/keys/AuthKey_AB12CD34EF.p8"
if run upload; then fail "an upload without the key file should fail"; fi
if [ -s "$work/stub/argv" ]; then fail "altool runs without the key file"; fi
reset
if STUB_STATUS=1 run upload; then fail "a failed upload should fail"; fi

reset
for command in archive export inspect upload; do
  run "$command" || true
done
if grep -qx -- -allowProvisioningUpdates "$work/stub/argv"; then
  fail "a command lets Xcode change signing assets"
fi

reset
if run; then fail "no command should fail"; fi
if run sign; then fail "an unknown command should fail"; fi

exit "$failures"
