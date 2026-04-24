#!/usr/bin/env bash
# check-public-api.sh — capture or compare the public Zig surface.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

PUBLIC_API_ROOT="${PUBLIC_API_ROOT:-src/lib.zig}"
PUBLIC_API_BASELINE="${PUBLIC_API_BASELINE:-.zig-qm/public-api.txt}"
MODE="${1:-check}"

if [[ ! -f "$PUBLIC_API_ROOT" ]]; then
  echo "(no public API root at $PUBLIC_API_ROOT; skipping public surface check)"
  exit 0
fi

TMP=$(mktemp)
cleanup() {
  rm -f "$TMP"
}
trap cleanup EXIT

{
  echo "# Public API snapshot"
  echo "# root: $PUBLIC_API_ROOT"
  echo
  grep -nE '^[[:space:]]*pub[[:space:]]+(const|fn|var|usingnamespace)\b' "$PUBLIC_API_ROOT" \
    | sed -E 's/[[:space:]]+/ /g'
} > "$TMP"

case "$MODE" in
  --write|write)
    mkdir -p "$(dirname "$PUBLIC_API_BASELINE")"
    cp "$TMP" "$PUBLIC_API_BASELINE"
    echo "public API baseline written to $PUBLIC_API_BASELINE"
    ;;
  *)
    if [[ -f "$PUBLIC_API_BASELINE" ]]; then
      if ! diff -u "$PUBLIC_API_BASELINE" "$TMP"; then
        echo "check-public-api: public surface drifted; review and refresh baseline if intentional" >&2
        exit 1
      fi
      echo "check-public-api: OK"
    else
      echo "(no public API baseline at $PUBLIC_API_BASELINE; current surface follows)"
      cat "$TMP"
    fi
    ;;
esac
