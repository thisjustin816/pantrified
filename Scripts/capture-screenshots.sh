#!/usr/bin/env bash
# Takes screenshots of the app's screens on the largest iPhone simulator, the 6.9-inch size App
# Store Connect asks for: each screen in light and dark mode, at the default text size and at the
# largest accessibility size, on sample food and without the Debug-only Evaluate tab. A simulator
# has no camera, so the scan screen shows its "Camera not available" state, and the batch review
# shows synthetic readings over placeholder photos, in its sections by place: "Needs a place", then
# Fridge, Freezer and Pantry.
#
# Usage: capture-screenshots.sh APP_BUNDLE OUTPUT_DIR
#
# APP_BUNDLE is a Debug simulator build, which holds the sample-data mode (-pantrified-scenario).
# Files are named SCREEN-APPEARANCE-SIZE.png, for example today-dark-xxxl.png.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 APP_BUNDLE OUTPUT_DIR" >&2
  exit 2
fi
app="$1"
out="$2"
[ -d "$app" ] || { echo "error: no such app bundle: $app" >&2; exit 1; }

here="$(cd "$(dirname "$0")" && pwd)"
# The newest "iPhone <number> Pro Max", whose screen is the 6.9-inch size App Store Connect asks
# for; the model select-simulator.sh picks when none is listed.
name="$(xcrun simctl list devices available 2>/dev/null |
  sed -n 's/^ *\(iPhone [0-9][0-9]* Pro Max\) (.*/\1/p' | sort -uV | tail -n 1)"
[ -n "$name" ] || name="$("$here/select-simulator.sh")"
udid="$(xcrun simctl list devices available | sed -n "s/^ *$name (\\([0-9A-F-]\\{36\\}\\)).*/\\1/p" | head -n 1)"
[ -n "$udid" ] || { echo "error: no available simulator named $name" >&2; exit 1; }
bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
mkdir -p "$out"

echo "Simulator: $name ($udid), app: $bundle"
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl install "$udid" "$app"
# A clean, fixed status bar, so screenshots differ only in the app.
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 || true

shoot() {
  local screen="$1" appearance="$2" size_label="$3"
  xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
  xcrun simctl launch "$udid" "$bundle" -pantrified-scenario sample -pantrified-screen "$screen" >/dev/null
  # The store opens and the sample food is added before the first list appears.
  sleep 6
  xcrun simctl io "$udid" screenshot "$out/$screen-$appearance-$size_label.png" >/dev/null 2>&1
  echo "  $screen-$appearance-$size_label.png"
}

for appearance in light dark; do
  xcrun simctl ui "$udid" appearance "$appearance"
  for size in large accessibility-extra-extra-extra-large; do
    xcrun simctl ui "$udid" content_size "$size"
    label=default
    [ "$size" = large ] || label=xxxl
    for screen in today food add scan review; do
      shoot "$screen" "$appearance" "$label"
    done
  done
done

xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
xcrun simctl ui "$udid" appearance light
xcrun simctl ui "$udid" content_size large
xcrun simctl status_bar "$udid" clear || true
for image in "$out"/*.png; do
  echo "$(basename "$image"): $(sips -g pixelWidth -g pixelHeight "$image" | awk '/pixel/ {printf "%s ", $2}')"
done
