#!/usr/bin/env bash
# Signs a Release archive with the distribution certificate and App Store profile, checks it,
# exports an .ipa and, unless TESTFLIGHT_UPLOAD is false, uploads it to App Store Connect.
# Run by .github/workflows/testflight.yml after `make generate`; docs/testflight.md has the setup.
#
# TESTFLIGHT_VARIANT is release (default) or evaluation, which compiles in the Evaluation tab and
# exports the build for internal testing only. TESTFLIGHT_UPLOAD is true (default) or false, which
# stops after the signed export so signing can be checked without an upload.
set -euo pipefail

# The app's identifiers. Scripts/appstoreconnect.py holds the bundle ID too; a test keeps them equal.
readonly BUNDLE_ID=com.thisjustin816.Pantrified
readonly TEAM_ID=S2TFTKR4CS
readonly PROFILE_UUID=98c9f99b-5d53-40bc-af18-d953d630993e
readonly SCHEME=Pantrified

required=(APPLE_DISTRIBUTION_PRIVATE_KEY APPLE_DISTRIBUTION_CERTIFICATE_BASE64
  APPLE_PROVISIONING_PROFILE_BASE64 APP_STORE_CONNECT_KEY_ID
  APP_STORE_CONNECT_ISSUER_ID APP_STORE_CONNECT_PRIVATE_KEY GITHUB_RUN_NUMBER
  GITHUB_RUN_ATTEMPT RUNNER_TEMP)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    echo "Missing $name. See docs/testflight.md for GitHub secret setup." >&2
    exit 1
  fi
done
if [[ ! $APP_STORE_CONNECT_KEY_ID =~ ^[A-Za-z0-9]+$ ||
      ! $GITHUB_RUN_NUMBER =~ ^[1-9][0-9]{0,5}$ ||
      ! $GITHUB_RUN_ATTEMPT =~ ^[1-9][0-9]?$ ]] || ((GITHUB_RUN_NUMBER > 999899)); then
  echo "Invalid API key ID, run number or run attempt." >&2
  exit 1
fi
variant="${TESTFLIGHT_VARIANT:-release}"
upload="${TESTFLIGHT_UPLOAD:-true}"
if [[ $variant != release && $variant != evaluation ]]; then
  echo "TESTFLIGHT_VARIANT must be release or evaluation." >&2
  exit 1
fi
if [[ $upload != true && $upload != false ]]; then
  echo "TESTFLIGHT_UPLOAD must be true or false." >&2
  exit 1
fi
if [[ "$(uname -s)" != Darwin ]]; then
  echo "TestFlight uploads require macOS/Xcode, provided by the GitHub Actions runner." >&2
  exit 1
fi
if [[ -e Config/Signing.local.xcconfig ]]; then
  echo "Use a clean Actions checkout; Config/Signing.local.xcconfig already exists." >&2
  exit 1
fi

# Prints one top-level value of a property list.
plist_value() {
  python3 -I -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb"))[sys.argv[2]])' "$1" "$2"
}

umask 077
signing_dir="$(mktemp -d "$RUNNER_TEMP/testflight.XXXXXX")"
keychain="$signing_dir/signing.keychain-db"
profile_path=""
local_signing_created=false
original_keychains=()
while IFS= read -r line; do
  line="${line#*\"}"
  original_keychains+=("${line%\"*}")
done < <(security list-keychains -d user)
cleanup() {
  if ((${#original_keychains[@]})); then
    security list-keychains -d user -s "${original_keychains[@]}" || true
  fi
  security delete-keychain "$keychain" 2>/dev/null || true
  [[ -z $profile_path ]] || rm -f "$profile_path"
  if [[ $local_signing_created == true ]]; then
    rm -f Config/Signing.local.xcconfig
  fi
  rm -rf "$signing_dir"
}
trap cleanup EXIT

printf '%s' "$APPLE_DISTRIBUTION_PRIVATE_KEY" >"$signing_dir/distribution.key"
printf '%s' "$APPLE_DISTRIBUTION_CERTIFICATE_BASE64" | base64 --decode >"$signing_dir/distribution.cer"
printf '%s' "$APPLE_PROVISIONING_PROFILE_BASE64" | base64 --decode >"$signing_dir/profile.mobileprovision"
printf '%s' "$APP_STORE_CONNECT_PRIVATE_KEY" >"$signing_dir/AuthKey_$APP_STORE_CONNECT_KEY_ID.p8"
unset APPLE_DISTRIBUTION_PRIVATE_KEY APPLE_DISTRIBUTION_CERTIFICATE_BASE64
unset APPLE_PROVISIONING_PROFILE_BASE64 APP_STORE_CONNECT_PRIVATE_KEY

openssl x509 -inform DER -in "$signing_dir/distribution.cer" -out "$signing_dir/distribution.pem"
openssl x509 -in "$signing_dir/distribution.pem" -checkend 0 -noout
if ! cmp -s <(openssl pkey -in "$signing_dir/distribution.key" -pubout) \
    <(openssl x509 -in "$signing_dir/distribution.pem" -pubkey -noout); then
  echo "The distribution certificate does not match the signing private key." >&2
  exit 1
fi
security cms -D -i "$signing_dir/profile.mobileprovision" >"$signing_dir/profile.plist"
# Reject a development or ad hoc profile, or one for another app, team or certificate, before
# touching the keychain.
python3 -I - "$signing_dir/profile.plist" "$signing_dir/distribution.cer" "$BUNDLE_ID" "$TEAM_ID" \
  "$PROFILE_UUID" <<'PY'
import datetime
import plistlib
import sys

profile_path, certificate_path, bundle_id, team_id, profile_uuid = sys.argv[1:]
with open(profile_path, "rb") as source:
    profile = plistlib.load(source)
entitlements = profile["Entitlements"]
if entitlements["application-identifier"] != f"{team_id}.{bundle_id}":
    sys.exit(f"Provisioning profile is not for {bundle_id} in team {team_id}.")
if profile.get("UUID", "").lower() != profile_uuid:
    sys.exit("Provisioning profile is not the one named in Scripts/upload-testflight.sh.")
if (entitlements.get("get-task-allow") or "ProvisionedDevices" in profile
        or profile.get("ProvisionsAllDevices")):
    sys.exit("Select an App Store Connect distribution provisioning profile.")
if profile["ExpirationDate"] <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
    sys.exit("Provisioning profile has expired; regenerate it in Apple Developer.")
with open(certificate_path, "rb") as source:
    if source.read() not in profile["DeveloperCertificates"]:
        sys.exit("Provisioning profile does not include this distribution certificate.")
PY
profile_path="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/$PROFILE_UUID.mobileprovision"
mkdir -p "$(dirname "$profile_path")"
cp "$signing_dir/profile.mobileprovision" "$profile_path"

keychain_password="$(openssl rand -hex 32)"
echo "::add-mask::$keychain_password"
export TESTFLIGHT_KEYCHAIN_PASSWORD="$keychain_password"
openssl pkcs12 -export -inkey "$signing_dir/distribution.key" \
  -in "$signing_dir/distribution.pem" -out "$signing_dir/distribution.p12" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -passout env:TESTFLIGHT_KEYCHAIN_PASSWORD
# The key is in the .p12 now; the PEM copy is not needed for the rest of the run.
rm -f "$signing_dir/distribution.key"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$signing_dir/distribution.p12" -k "$keychain" -P "$keychain_password" \
  -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain"
security list-keychains -d user -s "$keychain" "${original_keychains[@]}"
unset TESTFLIGHT_KEYCHAIN_PASSWORD
rm -f "$signing_dir/distribution.p12"

archive="$RUNNER_TEMP/$SCHEME.xcarchive"
export_dir="$RUNNER_TEMP/$SCHEME-export"
# The build number is the workflow run, so TestFlight reads "0.1 (57)". Apple refuses a second
# binary with the same build number, so a retried run adds its attempt: 57.2, 57.3.
version="$GITHUB_RUN_NUMBER"
if ((GITHUB_RUN_ATTEMPT > 1)); then
  version="$GITHUB_RUN_NUMBER.$GITHUB_RUN_ATTEMPT"
fi
# Signing belongs to the app target's xcconfig: command-line profile settings would also
# reach package resource bundles, which do not support provisioning profiles.
local_signing_created=true
cat >Config/Signing.local.xcconfig <<EOF
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = Apple Distribution
DEVELOPMENT_TEAM = $TEAM_ID
PROVISIONING_PROFILE_SPECIFIER = $PROFILE_UUID
BUNDLE_ID_SUFFIX =
EOF
archive_settings=(CURRENT_PROJECT_VERSION="$version")
evaluation_tab=absent
if [[ $variant == evaluation ]]; then
  # The condition make archive-evaluation-unsigned sets; $(inherited) is for Xcode to expand.
  # shellcheck disable=SC2016
  archive_settings+=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) EVALUATION')
  evaluation_tab=present
fi
echo "Archiving the $variant variant, build $version"
xcodebuild -project "$SCHEME.xcodeproj" -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" archive "${archive_settings[@]}"

app="$archive/Products/Applications/$SCHEME.app"
./Scripts/verify-evaluation-gating.sh "$app/$SCHEME" "$evaluation_tab"
python3 -I Scripts/verify-privacy-manifest.py App/PrivacyInfo.xcprivacy "$app"
python3 -I Scripts/verify-app-icon.py App/Assets.xcassets/AppIcon.appiconset "$app"
python3 -I Scripts/verify-export-compliance.py project.yml "$app"
marketing_version="$(plist_value "$app/Info.plist" CFBundleShortVersionString)"
for key_and_value in "CFBundleIdentifier=$BUNDLE_ID" "CFBundleVersion=$version"; do
  if [[ "$(plist_value "$app/Info.plist" "${key_and_value%%=*}")" != "${key_and_value#*=}" ]]; then
    echo "The archived app's ${key_and_value%%=*} is not ${key_and_value#*=}." >&2
    exit 1
  fi
done

python3 -I - "$signing_dir/ExportOptions.plist" "$TEAM_ID" "$BUNDLE_ID" "$PROFILE_UUID" "$variant" <<'PY'
import plistlib
import sys

output, team_id, bundle_id, profile_uuid, variant = sys.argv[1:]
with open("Config/ExportOptions-TestFlight.plist", "rb") as source:
    options = plistlib.load(source)
options["teamID"] = team_id
options["provisioningProfiles"] = {bundle_id: profile_uuid}
# An evaluation build is for internal testers only.
options["testFlightInternalTestingOnly"] = variant == "evaluation"
with open(output, "wb") as handle:
    plistlib.dump(options, handle)
PY
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$export_dir" \
  -exportOptionsPlist "$signing_dir/ExportOptions.plist"

if [[ $upload == false ]]; then
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    printf 'Signed and exported Pantrified %s (%s), %s variant. Not uploaded.\n' \
      "$marketing_version" "$version" "$variant" >>"$GITHUB_STEP_SUMMARY"
  fi
  echo "Signed and exported $export_dir/$SCHEME.ipa; not uploaded."
  exit 0
fi

API_PRIVATE_KEYS_DIR="$signing_dir" xcrun altool --upload-app --type ios \
  --file "$export_dir/$SCHEME.ipa" --apiKey "$APP_STORE_CONNECT_KEY_ID" \
  --apiIssuer "$APP_STORE_CONNECT_ISSUER_ID"
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  printf 'marketing_version=%s\nbuild=%s\n' "$marketing_version" "$version" >>"$GITHUB_OUTPUT"
fi
if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
  printf 'Uploaded Pantrified %s (%s), %s variant. Apple must process it before it appears in TestFlight.\n' \
    "$marketing_version" "$version" "$variant" >>"$GITHUB_STEP_SUMMARY"
fi
