#!/usr/bin/env bash
# kcov coverage harness — CI-Linux only.
#
# kcov is Linux-only: it relies on ptrace, which macOS SIP blocks even for
# signed binaries, and there is no arm64 build. On Darwin this script exits
# 0 with a skip notice; use `mise x zig@0.16.0 -- zig build test --summary
# all` for statement counts and the mutation matrix (scripts/mutate*) for
# branch adequacy locally. Real line-coverage numbers come from CI-Linux.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"
exec bun scripts/kcov-coverage.ts "$@"
