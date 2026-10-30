#!/usr/bin/env bash
# Checks Scripts/select-simulator.sh against sample `simctl list` output.
set -euo pipefail

script="$(dirname "$0")/../select-simulator.sh"
failures=0

expect() {
  local description="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL: $description: expected '$expected', got '$actual'" >&2
    failures=$((failures + 1))
  fi
}

listing='== Devices ==
-- iOS 26.0 --
    iPhone 16e (AAAAAAAA-0000) (Shutdown)
    iPhone 17 (BBBBBBBB-0000) (Shutdown)
    iPhone 17 Pro (CCCCCCCC-0000) (Shutdown)
    iPhone 17 Pro Max (DDDDDDDD-0000) (Shutdown)
-- iOS 27.0 --
    iPhone 18 Pro (EEEEEEEE-0000) (Shutdown)
    iPhone 9 Pro (FFFFFFFF-0000) (Shutdown)
    iPad Pro 13-inch (GGGGGGGG-0000) (Shutdown)'

expect "newest numbered Pro wins, compared as a version" "iPhone 18 Pro" "$("$script" - <<<"$listing")"
expect "Pro Max alone is not chosen" "iPhone 17 Pro" "$("$script" - <<<"    iPhone 17 Pro Max (DDDD) (Shutdown)
    iPhone 17 Pro (CCCC) (Shutdown)")"
expect "no Pro model falls back to the default" "iPhone 17 Pro" "$("$script" - <<<"    iPhone 17 (BBBB) (Shutdown)")"
expect "empty listing falls back to the default" "iPhone 17 Pro" "$("$script" - <<<"")"

exit "$failures"
