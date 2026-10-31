#!/usr/bin/env bash
# Checks Scripts/upload-testflight.sh on Linux. Real openssl signs with a throwaway key and
# certificate; stand-ins for uname, security, xcodebuild and xcrun record what they were asked to do,
# and every other command the script runs is wrapped to record its arguments, so the test can show
# that no secret reaches a command line and that the signing files are gone however the run ends.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap '[ -n "${KEEP_WORK:-}" ] || rm -rf "$work"' EXIT
failures=0

fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

# Signing material made for the test only.
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/key.pem" -out "$work/cert.pem" -days 30 \
  -subj /CN=Test >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/other-key.pem" -out "$work/other-cert.pem" -days 30 \
  -subj /CN=Other >/dev/null 2>&1
openssl x509 -in "$work/cert.pem" -outform DER -out "$work/cert.der"
openssl x509 -in "$work/other-cert.pem" -outform DER -out "$work/other-cert.der"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$work/api.p8" 2>/dev/null
signing_key="$(cat "$work/key.pem")"
certificate="$(base64 -w0 "$work/cert.der")"
profile="$(printf 'FAKE-CMS-ENVELOPE-%s' "$RANDOM$RANDOM" | base64 -w0)"
api_key="$(cat "$work/api.p8")"
key_id=AB12CD34EF
issuer_id=69a6de70-03db-47e3-e053-5b8c7c11a4d1

# The plist `security cms -D` prints for the profile.
write_profile() {
  python3 -I - "$work/stub/profile.plist" "$1" "$2" "$3" "$4" "$5" <<'PY'
import datetime, plistlib, sys
path, certificate, app_id, uuid, expires_days, kind = sys.argv[1:]
profile = {
    "UUID": uuid,
    "TeamIdentifier": ["S2TFTKR4CS"],
    "ExpirationDate": datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) + datetime.timedelta(days=int(expires_days)),
    "DeveloperCertificates": [open(certificate, "rb").read()],
    "Entitlements": {"application-identifier": app_id, "get-task-allow": kind == "development",
                     "beta-reports-active": True},
}
if kind == "development":
    profile["ProvisionedDevices"] = ["00008110-000A"]
plistlib.dump(profile, open(path, "wb"))
PY
}

mkdir -p "$work/bin" "$work/wrapped"
for tool in uname security xcodebuild xcrun; do
  cat >"$work/bin/$tool" <<'STUB'
#!/usr/bin/env bash
printf '%s\0' "$(basename "$0")" "$@" >>"$STUB_DIR/argv"
printf '\n' >>"$STUB_DIR/argv"
tool="$(basename "$0")"
case "$tool" in
  uname) echo Darwin ;;
  security)
    case "$1" in
      list-keychains)
        if [ "${4:-}" = -s ]; then shift 4; printf '%s\n' "$@" >"$STUB_DIR/keychains"
        else sed 's/.*/    "&"/' "$STUB_DIR/keychains"; fi ;;
      cms) cat "$STUB_DIR/profile.plist" ;;
      create-keychain) : >"${!#}" ;;
      delete-keychain) rm -f "$2" ;;
    esac ;;
  xcodebuild)
    if [ "$1" = -exportArchive ]; then
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -exportPath) mkdir -p "$2"; : >"$2/Pantrified.ipa" ;;
          -exportOptionsPlist) cp "$2" "$STUB_DIR/ExportOptions.plist" ;;
        esac
        shift
      done
    else
      [ ! -f Config/Signing.local.xcconfig ] || cp Config/Signing.local.xcconfig "$STUB_DIR/xcconfig-at-archive"
      [ -z "${STUB_ARCHIVE_FAILS:-}" ] || exit 65
      python3 -I "$STUB_DIR/make-app.py" "$@"
    fi ;;
  xcrun) [ -z "${STUB_UPLOAD_FAILS:-}" ] || exit 1 ;;
esac
STUB
done
cat >"$work/bin/make-app.py" <<'PY'
import os, plistlib, shutil, sys
args = sys.argv[1:]
archive = args[args.index("-archivePath") + 1]
version = next(a.split("=", 1)[1] for a in args if a.startswith("CURRENT_PROJECT_VERSION="))
evaluation = any("EVALUATION" in a for a in args)
app = os.path.join(archive, "Products", "Applications", "Pantrified.app")
os.makedirs(app)
info = {"CFBundleIdentifier": "com.thisjustin816.Pantrified", "CFBundleShortVersionString": "0.1",
        "CFBundleVersion": version, "CFBundleIconName": "AppIcon", "ITSAppUsesNonExemptEncryption": False}
info.update(dict(item.split("=", 1) for item in os.environ.get("STUB_INFO", "").split(",") if item))
plistlib.dump(info, open(os.path.join(app, "Info.plist"), "wb"), fmt=plistlib.FMT_BINARY)
open(os.path.join(app, "Assets.car"), "wb").write(b"car")
shutil.copy("App/PrivacyInfo.xcprivacy", app)
body = b"main" + (b"\0EvaluationView\0EvaluationModel\0" if evaluation else b"")
open(os.path.join(app, "Pantrified"), "wb").write(body)
PY
mv "$work/bin/make-app.py" "$work/make-app.py"
for tool in openssl base64 python3 cmp mktemp rm mkdir cp cat dirname sed grep; do
  real="$(command -v "$tool")"
  cat >"$work/wrapped/$tool" <<STUB
#!/usr/bin/env bash
printf '%s\0' "$tool" "\$@" >>"\$STUB_DIR/argv"
printf '\n' >>"\$STUB_DIR/argv"
exec "$real" "\$@"
STUB
done
chmod +x "$work/bin/"* "$work/wrapped/"*

reset() {
  rm -rf "${work:?}/repo" "${work:?}/stub" "${work:?}/temp" "${work:?}/home"
  mkdir -p "$work/repo/App" "$work/stub" "$work/temp" "$work/home"
  cp -R "$root/Scripts" "$root/Config" "$root/project.yml" "$work/repo/"
  cp -R "$root/App/PrivacyInfo.xcprivacy" "$root/App/Assets.xcassets" "$work/repo/App/"
  rm -f "$work/repo/Config/Signing.local.xcconfig"
  cp "$work/make-app.py" "$work/stub/"
  : >"$work/stub/argv"
  echo /Users/runner/Library/Keychains/login.keychain-db >"$work/stub/keychains"
  write_profile "$work/cert.der" S2TFTKR4CS.com.thisjustin816.Pantrified 98c9f99b-5d53-40bc-af18-d953d630993e 300 store
}

run() {
  (
    cd "$work/repo"
    env -i PATH="$work/bin:$work/wrapped:/usr/bin:/bin" HOME="$work/home" STUB_DIR="$work/stub" \
      RUNNER_TEMP="$work/temp" GITHUB_RUN_NUMBER="${RUN_NUMBER:-57}" GITHUB_RUN_ATTEMPT="${RUN_ATTEMPT:-1}" \
      GITHUB_OUTPUT="$work/stub/output" GITHUB_STEP_SUMMARY="$work/stub/summary" PYTHONDONTWRITEBYTECODE=1 \
      APPLE_DISTRIBUTION_PRIVATE_KEY="${SIGNING_KEY-$signing_key}" \
      APPLE_DISTRIBUTION_CERTIFICATE_BASE64="${CERTIFICATE-$certificate}" \
      APPLE_PROVISIONING_PROFILE_BASE64="${PROFILE-$profile}" \
      APP_STORE_CONNECT_PRIVATE_KEY="${API_KEY-$api_key}" \
      APP_STORE_CONNECT_KEY_ID="${KEY_ID-$key_id}" APP_STORE_CONNECT_ISSUER_ID="${ISSUER_ID-$issuer_id}" \
      ${TESTFLIGHT_VARIANT+TESTFLIGHT_VARIANT="$TESTFLIGHT_VARIANT"} \
      ${TESTFLIGHT_UPLOAD+TESTFLIGHT_UPLOAD="$TESTFLIGHT_UPLOAD"} \
      ${STUB_ARCHIVE_FAILS+STUB_ARCHIVE_FAILS=1} ${STUB_UPLOAD_FAILS+STUB_UPLOAD_FAILS=1} \
      ${STUB_INFO+STUB_INFO="$STUB_INFO"} \
      ./Scripts/upload-testflight.sh
  ) >"$work/out" 2>&1
}

# Arguments of every command that was not altool, one command per line.
non_altool_argv() {
  tr '\0' ' ' <"$work/stub/argv" | grep -v '^xcrun altool ' || true
}

assert_clean() {
  local when="$1"
  [ -z "$(find "$work/temp" -maxdepth 1 -name 'testflight.*')" ] || fail "$when: the signing directory is left behind"
  [ ! -e "$work/repo/Config/Signing.local.xcconfig" ] || fail "$when: Signing.local.xcconfig is left behind"
  [ -z "$(find "$work/home" -name '*.mobileprovision')" ] || fail "$when: the installed profile is left behind"
  [ "$(cat "$work/stub/keychains")" = /Users/runner/Library/Keychains/login.keychain-db ] ||
    fail "$when: the keychain search list is not restored"
}

assert_quiet() {
  local when="$1" argv
  argv="$(tr '\0' ' ' <"$work/stub/argv")"
  # The second line of each PEM is key material; the key used may be the mismatched one.
  for secret in "$certificate" "$profile" "$(sed -n 2p <<<"${SIGNING_KEY-$signing_key}")" \
    "$(sed -n 2p "$work/api.p8")"; do
    [ -n "$secret" ] || continue
    if grep -qF -- "$secret" <<<"$argv"; then fail "$when: a secret appears in a command's arguments"; fi
    if grep -qF -- "$secret" "$work/out"; then fail "$when: a secret appears in the output"; fi
  done
  if grep -qF -- "$key_id" <<<"$(non_altool_argv)"; then fail "$when: the key ID reaches a command other than altool"; fi
  if grep -qF -- "$issuer_id" <<<"$(non_altool_argv)"; then fail "$when: the issuer ID reaches a command other than altool"; fi
}

# A release upload.
reset
run || fail "a release upload should succeed: $(tail -5 "$work/out")"
grep -qx 'build=57' "$work/stub/output" || fail "the build number is not reported"
grep -qx 'marketing_version=0.1' "$work/stub/output" || fail "the marketing version is not reported"
grep -q 'xcrun.altool.--upload-app' <(tr '\0' '.' <"$work/stub/argv") || fail "the build is not uploaded"
if grep -q EVALUATION "$work/stub/argv"; then fail "the release archive compiles the Evaluation tab"; fi
grep -qx 'CODE_SIGN_STYLE = Manual' "$work/stub/xcconfig-at-archive" || fail "the archive is not signed manually"
grep -qx 'PROVISIONING_PROFILE_SPECIFIER = 98c9f99b-5d53-40bc-af18-d953d630993e' "$work/stub/xcconfig-at-archive" ||
  fail "the archive does not name the profile"
python3 -I -c 'import plistlib,sys; o=plistlib.load(open(sys.argv[1],"rb")); sys.exit(o["testFlightInternalTestingOnly"] is not False or o["provisioningProfiles"] != {"com.thisjustin816.Pantrified": "98c9f99b-5d53-40bc-af18-d953d630993e"} or o["teamID"] != "S2TFTKR4CS")' \
  "$work/stub/ExportOptions.plist" || fail "the release export options are wrong"
grep -q 'security.list-keychains.-d.user.-s.*signing.keychain-db' <(tr '\0' '.' <"$work/stub/argv") ||
  fail "the temporary keychain is not added to the search list"
# The record of commands must hold what ran, or the checks below prove nothing.
for tool in openssl base64 python3 security xcodebuild; do
  grep -q "^$tool " <(tr '\0' ' ' <"$work/stub/argv") || fail "the $tool calls were not recorded"
done
assert_clean "after an upload"
assert_quiet "after an upload"

# A retried run adds its attempt.
reset
RUN_ATTEMPT=2 run || fail "a retried upload should succeed"
grep -qx 'build=57.2' "$work/stub/output" || fail "a retried run does not add its attempt"

# The evaluation variant.
reset
TESTFLIGHT_VARIANT=evaluation run || fail "an evaluation upload should succeed: $(tail -5 "$work/out")"
# shellcheck disable=SC2016
grep -q 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) EVALUATION' <(tr '\0' '\n' <"$work/stub/argv") ||
  fail "the evaluation archive does not compile the Evaluation tab"
python3 -I -c 'import plistlib,sys; sys.exit(plistlib.load(open(sys.argv[1],"rb"))["testFlightInternalTestingOnly"] is not True)' \
  "$work/stub/ExportOptions.plist" || fail "the evaluation export is not internal only"
assert_clean "after an evaluation upload"

# Signing without uploading.
reset
TESTFLIGHT_UPLOAD=false run || fail "a run without upload should succeed: $(tail -5 "$work/out")"
if grep -q altool "$work/stub/argv"; then fail "a run without upload calls altool"; fi
[ ! -s "$work/stub/output" ] || fail "a run without upload reports a build to tag"
grep -q 'Not uploaded' "$work/stub/summary" || fail "a run without upload does not say so"
[ -f "$work/stub/ExportOptions.plist" ] || fail "a run without upload does not export"
assert_clean "after a run without upload"

# Bad switches.
for setting in TESTFLIGHT_VARIANT=debug TESTFLIGHT_UPLOAD=yes; do
  reset
  if (export "${setting?}"; run); then fail "$setting should be refused"; fi
  grep -q 'must be' "$work/out" || fail "$setting is refused without saying why"
done

# Each missing secret is named and nothing is written.
for name in SIGNING_KEY CERTIFICATE PROFILE API_KEY KEY_ID ISSUER_ID; do
  reset
  if (export "$name="; run); then fail "an empty $name should be refused"; fi
  grep -q '^Missing APP\|^Missing APPLE' "$work/out" || fail "an empty $name is not named"
  [ ! -s "$work/stub/argv" ] || fail "commands ran with $name empty"
  assert_quiet "with $name empty"
done

# Profiles and certificates that must be refused before the keychain.
refuse() {
  local why="$1"
  if run; then fail "$why should be refused"; fi
  if grep -q '^security.create-keychain' <(tr '\0' '.' <"$work/stub/argv"); then fail "$why reached the keychain"; fi
  assert_clean "after refusing $why"
  assert_quiet "after refusing $why"
}
reset; write_profile "$work/cert.der" S2TFTKR4CS.com.example 98c9f99b-5d53-40bc-af18-d953d630993e 300 store
refuse "a profile for another app"
reset; write_profile "$work/cert.der" ABCDE12345.com.thisjustin816.Pantrified 98c9f99b-5d53-40bc-af18-d953d630993e 300 store
refuse "a profile for another team"
reset; write_profile "$work/cert.der" S2TFTKR4CS.com.thisjustin816.Pantrified 00000000-0000-0000-0000-000000000000 300 store
refuse "another profile"
reset; write_profile "$work/cert.der" S2TFTKR4CS.com.thisjustin816.Pantrified 98c9f99b-5d53-40bc-af18-d953d630993e 300 development
refuse "a development profile"
reset; write_profile "$work/cert.der" S2TFTKR4CS.com.thisjustin816.Pantrified 98c9f99b-5d53-40bc-af18-d953d630993e -1 store
refuse "an expired profile"
reset; write_profile "$work/other-cert.der" S2TFTKR4CS.com.thisjustin816.Pantrified 98c9f99b-5d53-40bc-af18-d953d630993e 300 store
refuse "a profile without the certificate"
reset; SIGNING_KEY="$(cat "$work/other-key.pem")" refuse "a key that does not match the certificate"
grep -q 'does not match the signing private key' "$work/out" || fail "a mismatched key is not reported as such"

# Failures after the keychain is built still remove everything.
reset
if STUB_ARCHIVE_FAILS=1 run; then fail "a failed archive should fail the run"; fi
assert_clean "after a failed archive"
reset
if STUB_UPLOAD_FAILS=1 run; then fail "a failed upload should fail the run"; fi
assert_clean "after a failed upload"
assert_quiet "after a failed upload"
reset
if STUB_INFO=CFBundleIdentifier=com.example run; then fail "an archive with another bundle ID should fail"; fi
if grep -q altool "$work/stub/argv"; then fail "an archive with another bundle ID is uploaded"; fi
assert_clean "after a wrong bundle ID"
reset
if STUB_INFO=ITSAppUsesNonExemptEncryption=1 run; then fail "an archive without the export-compliance answer should fail"; fi

# A developer's own signing settings are never replaced or removed.
reset
echo "DEVELOPMENT_TEAM = MINE" >"$work/repo/Config/Signing.local.xcconfig"
if run; then fail "an existing Signing.local.xcconfig should be refused"; fi
[ "$(cat "$work/repo/Config/Signing.local.xcconfig")" = "DEVELOPMENT_TEAM = MINE" ] ||
  fail "an existing Signing.local.xcconfig was changed"

exit "$failures"
