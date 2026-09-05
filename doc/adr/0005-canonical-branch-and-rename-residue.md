# ADR 0005: Canonical branch and gitstore rename residue

- **Status:** Accepted
- **Date:** 2026-09-05
- **Deciders:** repo owner (trunk verdict recorded in Linear TEO-7 on
  2026-09-04); this ADR records it in the repository
- **Tags:** branch, rename, compat, ci, docs

## Context

The project was renamed twice. The repository moved from
`EugOT/gitstore-cli` to `Eugene3dotdev/z3store`, and the CLI moved from
`gitstore` to `zt` (commit `33ad447`, PR #24). GitHub still redirects
the old owner slugs (`EugOT/gitstore-cli`, `EugOT/z3store`,
`EugOT/ziglint`) to `Eugene3dotdev/*`, so stale URLs work today and will
break silently the day the redirect is dropped or the old name is
reused.

Two kinds of `gitstore` text remain in the tree and must not be treated
alike:

- **Live compatibility.** `zt` still reads `gitstore.*` git-config keys
  and `GITSTORE_*` environment variables, discovers a legacy backing
  store at `~/.local/share/gitstore`, falls back to a legacy
  `.gitstore/cache/index.json`, and names one store tier `gitstore` in
  `z3store.toml` (that tier is named for git, not for the old product).
  Homebrew reports `z3store` as conflicting with `eugot/tap/gitstore`
  (TEO-843); a cleanup that removed this layer could orphan the git dir
  of any worktree still pointed at the legacy store.
- **Stale public identity.** The old project name in doc titles, review
  prompts, hook output, schema `$id` URLs, and help text; old owner URLs
  in help text, verifier messages, and skill instructions.

The branch state on 2026-09-05: `origin/main` is at `c6a4344`,
`origin/dev` at `39299ea`. `dev` is `main` + 36 commits and `main` has
no commit that `dev` lacks (`git rev-list --count origin/dev..origin/main`
is 0). GitHub's default branch is `main`. Post-rename product work,
the stores schema, and the lint cleanup (TEO-760) all live only on
`dev`. The operator decided in TEO-7 to fast-forward `main` to
`origin/dev`; the push had not happened when this ADR was written.

Draft PR #46 (`test/cel-650-script-lint`) was checked with
`git cherry origin/dev origin/test/cel-650-script-lint`: all six commits
are patch-equivalent to commits already on `dev`, and its three owned
scripts are byte-identical to `dev`. It carries no unintegrated work.

## Decision

### Canonical branch

`main` is the trunk. It is brought level with `origin/dev` by a plain
fast-forward, never a force push:

```bash
git fetch origin dev main
git push origin origin/dev:main
```

Post-condition: `git rev-parse origin/main` equals
`git rev-parse origin/dev` before the next commit lands on `dev`.

Until that push has happened, `origin/dev` is the base for new work and
the target for pull requests, because it is the only ref that holds the
decided trunk content. After the push, new work bases on `main`.
Whether `dev` stays as an integration branch or is retired is follow-on
work and is not decided here.

### Residue disposition

| Class | Disposition | Where |
|---|---|---|
| Config keys `gitstore.root`, `gitstore.backingStoreRoot`, `gitstore.user`, `gitstore.defaultHost`, `gitstore.completeUser`, `gitstore.adoptOnClone`, `gitstore.jjColocate` | Keep | `src/config.zig` |
| Env vars `GITSTORE_ROOT`, `GITSTORE_BACKING_STORE_ROOT`, `GITSTORE_CODESTORE_ROOT` and the exec whitelist | Keep | `src/config.zig`, `src/stores.zig`, `src/exec.zig` |
| Legacy backing store `~/.local/share/gitstore` and cache index `.gitstore/cache/index.json` | Keep | `src/config.zig`, `src/cache.zig` |
| Store tier `gitstore` and `[gitstore]` section in `z3store.toml` | Keep (named for git) | `src/stores.zig`, `src/z3store.schema.json` |
| Legacy-config warning text | Keep | `src/main.zig` `printLegacyConfigHint` |
| Migration guide `docs/MIGRATION-ghq-to-gitstore.md` | Keep (history; linked from `zt --help`) | `docs/` |
| Test fixtures using `EugOT` as an arbitrary owner and `/tmp/gitstore_*` paths | Keep in `src/tests.zig` (allowlisted). The one fixture in `src/lib.zig` moved to `Eugene3dotdev` instead, because `lib.zig` is the live public module and allowlisting it would hide real residue | `src/tests.zig`, `src/*.zig` test blocks |
| Dated records: ADR 0003, `doc/DVC_INTEGRATION.md`, `workflows/*.workflow.ts` | Keep as written | allowlisted by the check |
| Internal identifiers `gitstore_root`, `const gitstore = @import(...)` and error text naming the store root | Keep (not public identity; a rename is a separate refactor) | `src/z3store.zig`, `src/main.zig` |
| Project name `gitstore-cli` in live docs, prompts, hook output, lockfile | Remove | see the check's hit list |
| Owner URLs `github.com/EugOT/...` and slugs `EugOT/{gitstore-cli,z3store,ziglint}` in help text, schema `$id`, verifier output, skills | Remove | see the check's hit list |
| `EugOT/dotfiles` (chezmoi source slug) | Keep the bare slug; the URL form `github.com/EugOT/dotfiles` is still forbidden | not resolvable under either owner, so the slug is not provably stale and the URL is broken either way |

### Recurrence check

`scripts/check-rename-residue.ts` scans every tracked file for the
forbidden set (`gitstore-cli`, `github.com/EugOT/`,
`EugOT/(gitstore-cli|z3store|ziglint)`) and exits 1 with `path:line`
hits. A short path allowlist, each entry with a reason, covers the
dated records and test fixtures above. `scripts/verify-commit.ts` runs
it after the fast gate, so tier 2 and every tier above it inherit the
check. Bare `gitstore` is deliberately not forbidden.

## Consequences

- **Positive:** the compatibility contract survives untouched; a
  reviewer can prove it with `git diff --stat` on the compat files.
- **Positive:** stale identity cannot return unnoticed; the check fails
  the commit gate with the exact line.
- **Negative:** the allowlist must be maintained by hand. Adding a path
  requires a reason string, which keeps the list honest but is one more
  thing to review.
- **Neutral:** `.claude/` and `doc/TIGER_STYLE_ZIG.md` are scaffolded
  from the `zig-qm-toolkit` chezmoi template. The template still carries
  the old adopter name and should be updated there too, or a future
  `ZIG_QM_OVERWRITE=1` re-scaffold will reintroduce it and the check will
  catch it.
- **Follow-on work:** execute the fast-forward (TEO-7 task); decide the
  fate of `dev` afterwards; remove the compatibility layer only after an
  estate-wide check that no `.git`/`.jj` pointer references the legacy
  store (TEO-843).

## Alternatives considered

- **Rewrite every `gitstore` token to `z3store`.** Rejected. It breaks
  the config, env, cache, and store-tier contracts that existing
  installations depend on.
- **Forbid bare `gitstore` with per-line allow markers.** Rejected. It
  would need markers on dozens of compat lines and teaches the next
  agent to add a marker instead of thinking.
- **Run the check in `verify-fast.ts`.** Rejected. Tier 1 is scoped to
  Zig inputs and returns early when none changed; most residue lives in
  Markdown, JSON, and TypeScript.
- **Keep `dev` as trunk.** Rejected in TEO-7. GitHub's default and every
  external link already point at `main`; a fast-forward loses nothing.

## Validation

- `bun scripts/check-rename-residue.ts` exits 0 on the tree.
- `bun test tests/unit/check-rename-residue.test.ts` proves the scanner
  flags each forbidden pattern and honours the allowlist.
- `bun scripts/verify-commit.ts` runs the check on every commit.

## References

- Linear TEO-7 (trunk decision), TEO-843 (this cleanup), TEO-760 (lint
  cleanup shown integrated on `dev`).
- PR #24 (`zt` rename with compat chain), PR #46 (superseded draft).
- ADR 0003 (keeps its historical adopter name).
