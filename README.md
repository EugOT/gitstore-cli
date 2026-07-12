# z3store (`zt`)

<!-- badges: build, license, zig-version, zls-version go here -->

A Zig 0.16 project scaffolded from
[`zig-qm-toolkit`](./doc/ARCHITECTURE.md), with a TS/Bun-first
four-tier quality gate.

## Prerequisites

- Zig `0.16.0` and ZLS `0.16.0` (resolved through `mise`).
- Bun `>= 1.1.0` — every quality gate (`scripts/verify-*.ts`) runs under
  Bun. Install via your runtime manager (e.g. `mise install bun`) and
  confirm `bun --version`.

## Quick start

```bash
# Pinned toolchain (chezmoi-managed mise.toml)
mise install zig@0.16.0 zls@0.16.0

# Bun (one-time; pin a version in your runtime manager)
mise install bun

# Build
mise x zig@0.16.0 -- zig build

# Test
mise x zig@0.16.0 -- zig build test

# Quality gates (TS under Bun)
bun scripts/verify-fast.ts        # tier 1 (<2s) — fmt + ast-check
bun scripts/verify-commit.ts      # tier 2 (~30s) — fast + tests + API drift
bun scripts/verify-pr.ts          # tier 3 (~10min) — commit + cross-target + safety + fuzz
```

## Storage roots

z3store keeps two independent roots:

| Root | Purpose | Primary setting |
|---|---|---|
| Working-tree root | `host/owner/repository` checkout namespace used by `root`, `list`, and `get` | `z3store.root` or `Z3STORE_ROOT` |
| Backing-store root | Detached Git/JJ databases, cache, and `operations.log` | `z3store.backingStoreRoot` or `Z3STORE_BACKING_STORE_ROOT` |

```bash
git config --global z3store.root /Volumes/Crucial/ghq
git config --global z3store.backingStoreRoot /Volumes/Crucial/gitstore

zt root
zt status --json
```

Existing absolute `.git` pointer files are not rewritten merely because a
different backing root is selected. Legacy `gitstore.backingStoreRoot` and
`GITSTORE_BACKING_STORE_ROOT` remain supported during migration. See
[`docs/MIGRATION-ghq-to-gitstore.md`](docs/MIGRATION-ghq-to-gitstore.md).

## Quality gates

| Tier | Trigger | Entrypoint | Budget |
|------|---------|------------|--------|
| 1 — per-turn   | PostToolUse hook on `.zig` Write/Edit | `bun scripts/verify-fast.ts` | <2s |
| 2 — per-commit | Stop hook + pre-commit                | `bun scripts/verify-commit.ts` | ~30s |
| 3 — per-PR     | Forgejo `verify-pr.yaml`              | `bun scripts/verify-pr.ts` | ~10min |
| 4 — per-release| Manual `/release`                     | `bun scripts/verify-release.ts` | hours |

Each tier runs every check from the tier below it first, then adds its
own. First failure halts the chain.

## References

- [`doc/ARCHITECTURE.md`](./doc/ARCHITECTURE.md) — full system shape
- [`doc/TIGER_STYLE_ZIG.md`](./doc/TIGER_STYLE_ZIG.md) — Zig style spine
- [`doc/adr/`](./doc/adr/) — binding decisions (Zig 0.16 pinning,
  Darwin fuzz degradation, plan deviations, DORA tracking)
- [`CLAUDE.md`](./CLAUDE.md) — Claude Code instructions
- [`AGENTS.md`](./AGENTS.md) — agents.md spec entry point

## License

See [`LICENSE`](./LICENSE).

---

_Scaffolded from `~/.local/share/chezmoi/.chezmoitemplates/zig-qm-toolkit/`._
_Toolkit version recorded in `.zig-qm/.toolkit-version`._
