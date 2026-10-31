#!/usr/bin/env bash
# The Xcode and App Store Connect commands of the signed TestFlight build.
# Usage: testflight-xcode.sh archive|export|inspect|upload
#
# Settings come from the environment, set by .github/workflows/testflight.yml:
#   archive  VARIANT, BUILD_NUMBER, ARCHIVE_PATH, TEAM_ID, SIGNING_IDENTITY
#   export   ARCHIVE_PATH, EXPORT_PATH, EXPORT_OPTIONS
#   inspect  IPA_PATH, INSPECT_DIR: unpacks the .ipa, verifies its signature and writes the signed
#            entitlements and codesign's description of the app into INSPECT_DIR
#   upload   IPA_PATH, APP_APPLE_ID, BUNDLE_ID, MARKETING_VERSION, BUILD_NUMBER,
#            APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID, API_PRIVATE_KEYS_DIR
#
# Signing is manual: no command passes -allowProvisioningUpdates, so Xcode cannot create or change
# certificates, profiles or identifiers in the team. The profile specifier is set only for the app
# target, in Config/Signing.local.xcconfig (testflight.py xcconfig), because a specifier on the
# command line would also apply to the Swift package targets, which take no profile.
set -euo pipefail

require() {
  local name
  for name in "$@"; do
    if [ -z "${!name:-}" ]; then
      echo "error: $name is not set" >&2
      exit 2
    fi
  done
}

archive() {
  require VARIANT BUILD_NUMBER ARCHIVE_PATH TEAM_ID SIGNING_IDENTITY
  local -a args=(
    archive -project Pantrified.xcodeproj -scheme Pantrified -configuration Release
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE_PATH"
    CODE_SIGN_STYLE=Manual "DEVELOPMENT_TEAM=$TEAM_ID" "CODE_SIGN_IDENTITY=$SIGNING_IDENTITY"
    "CURRENT_PROJECT_VERSION=$BUILD_NUMBER"
  )
  case "$VARIANT" in
    release) ;;
    evaluation)
      # The condition make archive-evaluation-unsigned sets, which compiles in the Evaluation tab.
      # $(inherited) is for Xcode to expand, not the shell.
      # shellcheck disable=SC2016
      args+=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) EVALUATION')
      ;;
    *)
      echo "error: VARIANT must be release or evaluation" >&2
      exit 2
      ;;
  esac
  echo "Archiving the $VARIANT variant, build $BUILD_NUMBER"
  xcodebuild "${args[@]}"
}

export_ipa() {
  require ARCHIVE_PATH EXPORT_PATH EXPORT_OPTIONS
  xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS"
  if [ ! -f "$EXPORT_PATH/Pantrified.ipa" ]; then
    echo "error: the export did not produce $EXPORT_PATH/Pantrified.ipa" >&2
    exit 1
  fi
}

inspect() {
  require IPA_PATH INSPECT_DIR
  local app="$INSPECT_DIR/Payload/Pantrified.app"
  mkdir -p "$INSPECT_DIR"
  unzip -q "$IPA_PATH" -d "$INSPECT_DIR"
  if [ ! -d "$app" ]; then
    echo "error: $IPA_PATH has no Payload/Pantrified.app" >&2
    exit 1
  fi
  codesign --verify --deep --strict "$app"
  codesign -d --entitlements - --xml "$app" >"$INSPECT_DIR/entitlements.plist" 2>/dev/null
  codesign -dvv "$app" 2>"$INSPECT_DIR/codesign.txt"
  echo "$app"
}

upload() {
  require IPA_PATH APP_APPLE_ID BUNDLE_ID MARKETING_VERSION BUILD_NUMBER \
    APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID API_PRIVATE_KEYS_DIR
  # altool finds the key by this name in API_PRIVATE_KEYS_DIR; it takes no path to the key.
  if [ ! -f "$API_PRIVATE_KEYS_DIR/AuthKey_$APP_STORE_CONNECT_KEY_ID.p8" ]; then
    echo "error: the App Store Connect key is not in API_PRIVATE_KEYS_DIR; run testflight.py write-api-key first" >&2
    exit 1
  fi
  # altool has no other way to take the key and issuer IDs, so they are arguments. Both are
  # identifiers, masked in the log as secrets; the key itself stays in the file.
  xcrun altool --upload-package "$IPA_PATH" -t ios --apple-id "$APP_APPLE_ID" --bundle-id "$BUNDLE_ID" \
    --bundle-short-version-string "$MARKETING_VERSION" --bundle-version "$BUILD_NUMBER" \
    --apiKey "$APP_STORE_CONNECT_KEY_ID" --apiIssuer "$APP_STORE_CONNECT_ISSUER_ID"
}

if [ "$#" -ne 1 ]; then
  echo "usage: $0 archive|export|inspect|upload" >&2
  exit 2
fi

case "$1" in
  archive) archive ;;
  export) export_ipa ;;
  inspect) inspect ;;
  upload) upload ;;
  *)
    echo "usage: $0 archive|export|inspect|upload" >&2
    exit 2
    ;;
esac
