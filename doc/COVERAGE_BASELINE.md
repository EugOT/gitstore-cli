# Coverage Baseline — z3store

This file records the line-coverage baseline measured by the kcov harness
(`scripts/kcov-coverage.ts`) so coverage progress is auditable as the
test-coverage plan (`~/.claude/plans/2026-06-22-gitstore-test-coverage.md`)
lands group by group.

## How coverage is measured

- **CI-Linux (authoritative):** the `coverage` job in
  `.forgejo/workflows/verify-pr.yaml` installs `kcov`, runs
  `bun scripts/kcov-coverage.ts --print`, and enforces a threshold via
  `bun scripts/check-coverage.ts`. The report is uploaded as the `coverage`
  artifact.
- **Local (Darwin):** kcov is **Linux-only** — it relies on `ptrace`, which
  macOS SIP blocks even for signed binaries, and there is no arm64 build. On
  macOS the harness writes a `skipped` summary and exits 0. Use
  `mise x zig@0.16.0 -- zig build test --summary all` for statement counts and
  the mutation matrix (`scripts/mutate*`, plan G14) for branch adequacy.

## Threshold

`scripts/check-coverage.ts` defaults to **85%** and is ratcheted upward as
coverage groups land. Override with `--threshold <n>` or
`COVERAGE_THRESHOLD`. Target end-state per the plan: every public fn + every
error-set branch covered (≈ 90%+ line coverage once G2–G16 are complete).

## Baseline (pre-plan, 2026-06-22)

Existing tests at plan start: **205** test blocks.

| Module            | Inline tests | Expected line coverage (pre-work) |
|-------------------|-------------:|-----------------------------------|
| `src/url.zig`     | 38           | ~100% (heavily tested)            |
| `src/exec.zig`    | 26           | high                              |
| `src/hooks.zig`   | 17           | high                              |
| `src/list.zig`    | 13           | moderate                          |
| `src/config.zig`  | 12           | moderate                          |
| `src/cache.zig`   | 9            | moderate                          |
| `src/log.zig`     | 7            | moderate                          |
| `src/clone.zig`   | 6            | partial                           |
| `src/lib.zig`     | 1            | n/a (re-export surface, excluded) |
| `src/gitstore.zig`| 0 inline     | **~partial** (covered only via tests.zig integration) |
| `src/main.zig`    | 0            | **~5%** (CLI dispatch, untested)  |
| `src/tests.zig`   | 76           | n/a (the test file, excluded)     |

> The first real per-module line-coverage numbers will be filled in here
> after the kcov `coverage` job runs once on CI-Linux. Until then the
> right-hand column is the audit's expectation, not a measurement.

## Update procedure

1. Land a coverage group (G2–G16).
2. CI-Linux `coverage` job reports the new `percent_covered`.
3. When a milestone is crossed, raise the threshold in `check-coverage.ts`
   (or `COVERAGE_THRESHOLD`) and record the new per-module table here with
   the measured numbers + the commit/PR that achieved them.
