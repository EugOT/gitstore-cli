#!/usr/bin/env bash
# verify-release.sh — Tier 4 (hours).
# Runs before tagging a release. PR gate + deep fuzz + reproducibility + SBOM + attestation.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

"$ROOT/scripts/verify-pr.sh"
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

echo "== Clean non-incremental rebuild =="
rm -rf .zig-cache zig-out
zig_cmd build --summary all

if zig_cmd build -l 2>&1 | grep -qE '^[[:space:]]+docs[[:space:]]'; then
  echo "== Release docs =="
  zig_cmd build docs --summary failures
fi

FUZZ_BUDGET="${FUZZ_BUDGET_SECONDS:-2h}"  # tag-day use 72h
if zig_cmd build -l 2>&1 | grep -qE '^[[:space:]]+fuzz[[:space:]]'; then
  if zig_supports_fuzz; then
    RELEASE_FUZZ_LIMIT="${RELEASE_FUZZ_LIMIT:-1G}"
    echo "== Deep fuzz ($FUZZ_BUDGET, limit $RELEASE_FUZZ_LIMIT) =="
    run_with_timeout "$FUZZ_BUDGET" bash -lc '. "$1"; shift; zig_cmd "$@"' bash "$ROOT/scripts/zig-tool.sh" build fuzz --summary failures "--fuzz=$RELEASE_FUZZ_LIMIT" "-j$(cpu_count)" || {
      status=$?
      if [[ $status -ne 124 ]]; then
        echo "verify-release: fuzz crashed (exit $status)" >&2
        exit $status
      fi
      echo "(fuzz budget elapsed; no crashes)"
    }
  else
    zig_fuzz_skip_message
  fi
fi

echo "== Reproducibility check =="
H1=$(shasum -a 256 zig-out/bin/* 2>/dev/null | shasum -a 256 | awk '{print $1}')
rm -rf .zig-cache zig-out
zig_cmd build --summary all
H2=$(shasum -a 256 zig-out/bin/* 2>/dev/null | shasum -a 256 | awk '{print $1}')
if [[ "$H1" != "$H2" ]]; then
  echo "verify-release: rebuild produced different artifact hash" >&2
  echo "  first:  $H1" >&2
  echo "  second: $H2" >&2
  exit 1
fi
echo "(reproducible: $H1)"

echo "== SBOM (CycloneDX) =="
if command -v cyclonedx-cli &>/dev/null; then
  cyclonedx-cli create --input-format zon --input-file build.zig.zon --output-format json --output-file sbom.cdx.json || \
    echo "(cyclonedx-cli does not yet understand .zon; emit manually via build.zig script)"
else
  echo "(install cyclonedx-cli or emit via scripts/emit-sbom.zig)"
fi

echo "== cosign sign artifacts =="
if command -v cosign &>/dev/null; then
  for artifact in zig-out/bin/*; do
    cosign sign-blob --yes "$artifact" > "$artifact.sig" || echo "(cosign sign failed for $artifact)"
  done
else
  echo "(cosign not installed; skipping signing)"
fi

echo "verify-release: OK"
