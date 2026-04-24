# Migrating from ghq to gitstore

`gitstore` is a Zig 0.16 reimplementation of `ghq` that also owns the work of
separating `.git`/`.jj` databases from working trees (so the tree can live on
iCloud/Google Drive/rclone-mounted storage while the git repo stays local).
libgitstore v2 absorbs ghq's role — no more shell-side diff dance.

## Why migrate

- **One tool, one config.** `gitstore.*` keys in `git config` parallel
  `ghq.*` (fallback is automatic for back-compat). No more two-tool split.
- **Structured output.** `gitstore list --json` — nothing like that in ghq.
- **Bounded parallelism.** `gitstore get -P 8` uses a real semaphore
  (`std.Io.Semaphore`) instead of ghq's one-goroutine-per-URL.
- **Worktree awareness on list.** ghq `list` treats linked worktrees as separate
  entries; gitstore nests them under their parent.
- **jj-native.** ghq sees a colocated jj repo as plain git; gitstore colocates
  on clone and round-trips via `jj git`.
- **Zero dependencies.** No Go runtime, no libgit2. Single Zig binary.

## Subcommand parity

| ghq v1.8.0 | gitstore v0.2 | Notes |
|---|---|---|
| `ghq get [-u] [-P N] <url>` | `gitstore get [-u] [-P N] [--no-adopt] <url>` | Auto-adopts unless `--no-adopt` |
| `ghq list [--full-path] [<q>]` | `gitstore list [--full-path] [--json] [<q>]` | `--json` is new |
| `ghq root [--all]` | `gitstore root [--all]` | `--all` is v1 no-op |
| `ghq rm [--dry-run] <repo>` | `gitstore rm [--dry-run] <repo>` | Calls `detach` on adopted repos |
| `ghq create [--vcs git\|jj] <repo>` | `gitstore create <repo>` | Always git+jj colocate |
| `ghq migrate` | `gitstore migrate <new-root> [--dry-run]` | Real-mode v1-pending; dry-run works |

Additions with no ghq analogue: `gitstore init`, `adopt`, `detach`, `verify`,
`status`, `sync`, `filter`, `hook`.

Parked (out of scope for v1): `--vcs hg`, `--vcs svn`, `--vcs bzr`.

## Migration steps

### Phase 0 — Install gitstore

It's installed via the EugOT homebrew tap and/or the chezmoi-managed nix flake.
Verify:

```sh
which gitstore && gitstore root
```

### Phase 1 — Activate the new shell wrapper

The chezmoi-managed shell function `ghq()` in
`~/.config/{zsh,bash,nushell}/functions.*` now forwards directly to
`gitstore` (falling back to the real `ghq` binary if `gitstore` is absent).
`chezmoi apply` brings it in; restart your shell.

Verify:

```sh
type ghq          # should show the passthrough function
ghq root          # should print the same path as `gitstore root`
```

### Phase 2 — Verify your existing repos are discovered

```sh
gitstore list | wc -l         # should match your ghq inventory
gitstore list --json | jq length
```

If the numbers differ, run `gitstore verify --all` to diagnose.

### Phase 3 — (Optional) Rename `ghq.*` git-config keys

libgitstore resolves `gitstore.*` first, then falls back to `ghq.*`. When
`ghq.*` is used, gitstore emits a one-line deprecation hint on stderr.
To suppress the hint, migrate your keys:

```sh
# Preserve existing values
ROOT=$(git config --global --get ghq.root || echo "$HOME/ghq")
USER=$(git config --global --get ghq.user || true)

# Set gitstore.* equivalents
git config --global gitstore.root "$ROOT"
[ -n "$USER" ] && git config --global gitstore.user "$USER"

# Optional — remove the old keys once parity is confirmed
# git config --global --unset ghq.root
# git config --global --unset ghq.user
```

### Config key cross-reference

| Old (`ghq.*`) | New (`gitstore.*`) | Default |
|---|---|---|
| `ghq.root` | `gitstore.root` | `~/ghq` |
| `ghq.user` | `gitstore.user` | `$USER` |
| `ghq.defaultHost` | `gitstore.defaultHost` | `github.com` |
| `ghq.completeUser` | `gitstore.completeUser` | `true` |
| `ghq.<url-pattern>.root` | `gitstore.<url-pattern>.root` | — |
| — | `gitstore.adoptOnClone` | `true` (no ghq analogue) |
| — | `gitstore.jjColocate` | `true` (no ghq analogue) |

Env vars: `$GITSTORE_ROOT` takes precedence over `$GHQ_ROOT`.

## Known gaps in v1

- `gitstore migrate <new-root>` real-mode returns `error.MigrationNotImplemented`; only `--dry-run` works. Full implementation waits for the WAL replay design.
- `gitstore root --all` is a no-op that prints the primary root.
- `gitstore create --vcs hg|svn|bzr` is parked.
- No native Google Drive API sync yet (Linear CEL-378); today shell-outs to `rclone`.

## Troubleshooting

- **`ghq` still runs the Go binary after `chezmoi apply`** — restart your shell or `source ~/.config/zsh/functions.zsh` manually. Shell functions don't re-load automatically.
- **`gitstore list` shows nothing** — check `gitstore root` matches where your repos live; if empty, `git config --global gitstore.root <path>`.
- **Deprecation warning on every run** — indicates `ghq.*` keys are still authoritative; see Phase 3 above.
- **Want to fall back to real ghq for a single invocation** — use `command ghq <args>` (the `command` builtin bypasses the shell function).

## Related

- Canonical plan: `~/.claude/plans/libgitstore-v2.md`
- Research: `~/Downloads/Agentic quality management for Zig projects.md`
- Upstream ghq: https://github.com/x-motemen/ghq (v1.8.0 used as audit reference)
- xit-vcs studied for storage model, parked as Phase-2: https://github.com/xit-vcs/xit
- xitdb (Zig 0.16 MVCC store): https://github.com/radarroark/xitdb
