---
description: Run the tiered Zig quality gate. Usage — /verify [fast|commit|pr|release] (default: fast).
argument-hint: "[fast|commit|pr|release]"
allowed-tools: Bash(./scripts/verify-fast.sh:*), Bash(./scripts/verify-commit.sh:*), Bash(./scripts/verify-pr.sh:*), Bash(./scripts/verify-release.sh:*), Bash(git:*)
---

# /verify

Tiered Zig 0.16 quality gate. Four tiers, each runs the tier below it first.

| Tier | Budget | What it runs |
|---|---|---|
| `fast` (default) | <2s | `zig fmt --check` + `zig ast-check` |
| `commit` | ~30s | fast + `zig build test --test-timeout 30000` |
| `pr` | ~10min | commit + cross-target matrix + safety-mode rotation + bounded fuzz + API-surface diff |
| `release` | hours | pr + clean non-incremental rebuild + reproducibility check + deep fuzz + SBOM + cosign sign |

## Contract

- Scripts live under `scripts/verify-{fast,commit,pr,release}.sh` in the project root.
- Each script exits 0 on success, non-zero on any failure. First failure halts the chain.
- A project without the scripts is not toolkit-ready — run the setup from the `zig-qm-toolkit` template before invoking `/verify`.

## Steps

1. Parse $ARGUMENTS:
   - Empty or `fast` → run `./scripts/verify-fast.sh`
   - `commit` → `./scripts/verify-commit.sh`
   - `pr` → `./scripts/verify-pr.sh`
   - `release` → `./scripts/verify-release.sh`
   - Anything else → refuse and print the usage table above.
2. Execute via Bash tool and stream output.
3. On non-zero exit, summarize what failed (which tier, which step, top 10 lines of stderr) and stop — do not proceed to higher tiers.
4. On success, report the tier that ran, wall-clock time, and what the next higher tier would additionally cover.

## When to use which tier

- **Per edit (PostToolUse hook covers this automatically):** hooks already run the fmt/ast-check equivalents. `/verify fast` is rarely needed manually.
- **Before committing:** `/verify commit`.
- **Before `gt submit` or `gh pr create`:** `/verify pr`.
- **Before tagging a release:** `/verify release`.

## Notes

- All timings are indicative. Cross-target builds dominate `pr` time; fuzz dominates `release`.
- `pr` and `release` require `zig build fuzz` step in `build.zig`; if absent, fuzz is skipped with a notice.
- `release` requires `cosign` and optionally `cyclonedx-cli` — install via nix-darwin if you intend to publish signed artifacts.
