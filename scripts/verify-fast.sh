#!/usr/bin/env bash
# verify-fast.sh — Tier 1 (<2s).
# Runs on every saved edit. Format + AST check only.
# Deploy as scripts/verify-fast.sh inside a Zig 0.16 project.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

. "$ROOT/scripts/zig-tool.sh"
zig_cmd version >/dev/null

PATHS=("src")
[[ -f build.zig ]] && PATHS+=("build.zig")
[[ -f build.zig.zon ]] && PATHS+=("build.zig.zon")

echo "== zig fmt --check =="
zig_cmd fmt --check "${PATHS[@]}"

echo "== zig ast-check =="
while IFS= read -r f; do
  zig_cmd ast-check "$f"
done < <(find "${PATHS[@]}" -name '*.zig' -type f 2>/dev/null)

if command -v ziglint &>/dev/null; then
  echo "== ziglint (EugOT/ziglint expected) =="
  ziglint "${PATHS[@]}"
else
  echo "(ziglint not found; install/upgrade github.com/EugOT/ziglint for the lint gate)"
fi

echo "verify-fast: OK"
