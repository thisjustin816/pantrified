#!/usr/bin/env bash
# Checks whether an app executable contains the Evaluation tab. A Release build must not, and an
# Evaluation build must. Usage: verify-evaluation-gating.sh <executable> present|absent
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <executable> present|absent" >&2
  exit 2
fi
binary="$1"
expect="$2"

if [ ! -f "$binary" ]; then
  echo "error: no such file: $binary" >&2
  exit 2
fi

# Type names appear verbatim inside Swift's mangled symbols and metadata.
found=0
for name in EvaluationView EvaluationModel; do
  if grep -aq "$name" "$binary"; then
    found=$((found + 1))
  fi
done

case "$expect" in
  present)
    if [ "$found" -ne 2 ]; then
      echo "error: the Evaluation tab is missing from $binary ($found of 2 types found)" >&2
      exit 1
    fi
    ;;
  absent)
    if [ "$found" -ne 0 ]; then
      echo "error: the Evaluation tab is compiled into $binary ($found of 2 types found)" >&2
      exit 1
    fi
    ;;
  *)
    echo "error: expected present or absent, got $expect" >&2
    exit 2
    ;;
esac
