#!/usr/bin/env bash
# verify-commit.sh — Tier 2 (~30s).
# Runs before every commit. Fast gate + full test suite.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

"$ROOT/scripts/verify-fast.sh"
. "$ROOT/scripts/zig-tool.sh"

echo "== zig build test (Debug, --test-timeout 30s) =="
zig_cmd build test --summary failures --test-timeout 30s

echo "verify-commit: OK"
