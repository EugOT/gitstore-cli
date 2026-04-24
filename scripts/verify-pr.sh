#!/usr/bin/env bash
# verify-pr.sh — Tier 3 (~10min).
# Runs before opening a PR. Commit gate + cross-target + safety-mode rotation + bounded fuzz + API-surface diff.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

"$ROOT/scripts/verify-commit.sh"
. "$ROOT/scripts/zig-tool.sh"
. "$ROOT/scripts/with-timeout.sh"

cpu_count() {
  if command -v sysctl &>/dev/null; then
    sysctl -n hw.ncpu 2>/dev/null && return 0
  fi
  if command -v nproc &>/dev/null; then
    nproc && return 0
  fi
  echo 4
}

TARGETS=(
  "x86_64-linux-musl"
  "aarch64-linux-gnu"
  "aarch64-macos"
  "x86_64-windows-msvc"
  "wasm32-wasi"
)

echo "== Cross-target build matrix =="
for t in "${TARGETS[@]}"; do
  echo "--- $t"
  zig_cmd build -Dtarget="$t" --summary failures
done

echo "== Safety-mode rotation =="
for mode in Debug ReleaseSafe ReleaseFast ReleaseSmall; do
  echo "--- $mode"
  zig_cmd build test -Doptimize="$mode" --summary failures --test-timeout 60s
done

echo "== Public API surface =="
"$ROOT/scripts/check-public-api.sh"

if zig_cmd build -l 2>&1 | grep -qE '^[[:space:]]+docs[[:space:]]'; then
  echo "== Generated docs =="
  zig_cmd build docs --summary failures
else
  echo "(no docs build step — add one so shipment checks can verify generated API docs)"
fi

if zig_cmd build -l 2>&1 | grep -qE '^[[:space:]]+fuzz[[:space:]]'; then
  if zig_supports_fuzz; then
    PR_FUZZ_LIMIT="${PR_FUZZ_LIMIT:-100K}"
    echo "== Bounded fuzz (300s) =="
    run_with_timeout 300s bash -lc '. "$1"; shift; zig_cmd "$@"' bash "$ROOT/scripts/zig-tool.sh" build fuzz --summary failures "--fuzz=$PR_FUZZ_LIMIT" "-j$(cpu_count)" || {
      status=$?
      # 124 = timeout; any other non-zero is a real crash.
      if [[ $status -ne 124 ]]; then
        echo "verify-pr: fuzz crashed (exit $status)" >&2
        exit $status
      fi
      echo "(fuzz budget elapsed; no crashes)"
    }
  else
    zig_fuzz_skip_message
  fi
else
  echo "(no 'fuzz' build step — skipping fuzz gate; add one per zig-fuzz-target skill)"
fi

echo "verify-pr: OK"
