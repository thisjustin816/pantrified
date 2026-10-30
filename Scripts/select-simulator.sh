#!/usr/bin/env bash
# Prints the name of the newest available "iPhone <number> Pro" simulator, or a default when none
# is listed, so the Makefile does not hard-code a model the runner image may not have.
# With "-" as the argument, reads a `simctl list devices available` listing from standard input.
set -euo pipefail

default_name="iPhone 17 Pro"

if [ "${1:-}" = "-" ]; then
  listing="$(cat)"
else
  listing="$(xcrun simctl list devices available 2>/dev/null || true)"
fi

# "iPhone 17 Pro Max (...)" does not match: the pattern needs " (" right after "Pro".
name="$(printf '%s\n' "$listing" |
  sed -n 's/^ *\(iPhone [0-9][0-9]* Pro\) (.*/\1/p' |
  sort -uV | tail -n 1)"

printf '%s\n' "${name:-$default_name}"
