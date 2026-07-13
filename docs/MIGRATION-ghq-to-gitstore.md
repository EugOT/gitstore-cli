# Migrating from ghq to z3store (`zt`)

`zt` (the z3store CLI) is a Zig 0.16 reimplementation of `ghq` that also owns the
work of separating `.git`/`.jj` databases from working trees (so the tree can
live on iCloud/Google Drive/rclone-mounted storage while the git repo stays
local). z3store absorbs ghq's role — no more shell-side diff dance.

> Compat note: `z3store.*` git-config keys and `$Z3STORE_ROOT` are the primary
> source. Legacy `gitstore.*` / `ghq.*` keys and `$GITSTORE_ROOT` / `$GHQ_ROOT`
> still work as fallbacks; using them prints a one-line deprecation hint.

## Two independent roots

| Contract | Contains | Primary config | Primary env |
|---|---|---|---|
| Working-tree root | `host/owner/repository` checkouts | `z3store.root` | `Z3STORE_ROOT` |
| Backing-store root | Detached Git/JJ databases, cache, and `operations.log` | `z3store.backingStoreRoot` | `Z3STORE_BACKING_STORE_ROOT` |

Working-tree precedence:

```text
z3store.root > gitstore.root > ghq.root
> Z3STORE_ROOT > GITSTORE_ROOT > GHQ_ROOT > $HOME/ghq
```

Backing-store precedence:

```text
z3store.backingStoreRoot > gitstore.backingStoreRoot
> Z3STORE_BACKING_STORE_ROOT > GITSTORE_BACKING_STORE_ROOT
> existing $HOME/.local/share/z3store
> existing $HOME/.local/share/gitstore
> $HOME/.local/share/z3store
```

There is no `ghq.backingStoreRoot`: ghq has no detached-metadata contract.
Selecting a backing store does not move repositories or rewrite existing
absolute `.git` pointer files.

## Why migrate

- **One tool, one config.** `z3store.*` keys in `git config` parallel
  `ghq.*` (fallback to legacy `gitstore.*` / `ghq.*` is automatic). No more
  two-tool split.
- **Structured output.** `zt list --json` — nothing like that in ghq.
- **Bounded parallelism.** `zt get -P 8` uses a real semaphore
  (`std.Io.Semaphore`) instead of ghq's one-goroutine-per-URL.
- **Worktree awareness on list.** ghq `list` treats linked worktrees as separate
  entries; z3store nests them under their parent.
- **jj-native.** ghq sees a colocated jj repo as plain git; z3store colocates
  on clone and round-trips via `jj git`.
- **Small runtime footprint.** No Go runtime or libgit2 dependency in the
  `zt` binary.

## Subcommand parity

| ghq v1.8.0 | z3store (`zt`) | Notes |
|---|---|---|
| `ghq get [-u] [-P N] <url>` | `zt get [-u] [-P N] [--no-adopt] <url>` | Auto-adopts unless `--no-adopt` |
| `ghq list [--full-path] [<q>]` | `zt list [--full-path] [--json] [<q>]` | `--json` is new |
| `ghq root [--all]` | `zt root [--all]` | `--all` is v1 no-op |
| `ghq rm [--dry-run] <repo>` | `zt rm [--dry-run] <repo>` | Calls `detach` on adopted repos |
| `ghq create [--vcs git\|jj] <repo>` | `zt create <repo>` | Always git+jj colocate |
| `ghq migrate` | `zt migrate <new-root> [--dry-run]` | Real-mode v1-pending; dry-run works |

Additions with no ghq analogue: `zt init`, `adopt`, `detach`, `verify`,
`status`, `sync`, `filter`, `hook`.

Parked (out of scope for v1): `--vcs hg`, `--vcs svn`, `--vcs bzr`.

## Migration steps

### Phase 0 — Install z3store

It's installed via the EugOT homebrew tap and/or the chezmoi-managed nix flake.
Verify:

```sh
which zt && zt root
```

### Phase 1 — Activate the new shell wrapper

The chezmoi-managed shell function `ghq()` in
`~/.config/{zsh,bash,nushell}/functions.*` now forwards directly to
`zt` (falling back to the real `ghq` binary if `zt` is absent).
`chezmoi apply` brings it in; restart your shell.

Verify:

```sh
type ghq          # should show the passthrough function
ghq root          # should print the same path as `zt root`
```

### Phase 2 — Verify your existing repos are discovered

```sh
zt list | wc -l         # should match your ghq inventory
zt list --json | jq length
```

If the numbers differ, run `zt verify --all` to diagnose.

### Phase 3 — (Optional) Rename legacy git-config keys

z3store resolves `z3store.*` first, then falls back to legacy `gitstore.*` and
`ghq.*`. When a legacy key is used, `zt` emits a one-line deprecation hint on
stderr. To suppress the hint, migrate your keys:

```sh
# Preserve existing values (z3store first, then legacy fallbacks)
ROOT=$(git config --global --get z3store.root \
  || git config --global --get gitstore.root \
  || git config --global --get ghq.root || echo "$HOME/ghq")
USER=$(git config --global --get z3store.user \
  || git config --global --get gitstore.user \
  || git config --global --get ghq.user || true)
DEFAULT_HOST=$(git config --global --get z3store.defaultHost \
  || git config --global --get gitstore.defaultHost \
  || git config --global --get ghq.defaultHost || echo "github.com")
COMPLETE_USER=$(git config --global --get z3store.completeUser \
  || git config --global --get gitstore.completeUser \
  || git config --global --get ghq.completeUser || echo "true")
ADOPT_ON_CLONE=$(git config --global --get z3store.adoptOnClone \
  || git config --global --get gitstore.adoptOnClone || echo "true")
JJ_COLOCATE=$(git config --global --get z3store.jjColocate \
  || git config --global --get gitstore.jjColocate || echo "true")
BACKING_STORE_ROOT=$(git config --global --get z3store.backingStoreRoot \
  || git config --global --get gitstore.backingStoreRoot \
  || { [ -n "${Z3STORE_BACKING_STORE_ROOT:-}" ] && echo "$Z3STORE_BACKING_STORE_ROOT"; } \
  || { [ -n "${GITSTORE_BACKING_STORE_ROOT:-}" ] && echo "$GITSTORE_BACKING_STORE_ROOT"; } \
  || { [ -d "$HOME/.local/share/z3store" ] && echo "$HOME/.local/share/z3store"; } \
  || { [ -d "$HOME/.local/share/gitstore" ] && echo "$HOME/.local/share/gitstore"; } \
  || echo "$HOME/.local/share/z3store")

# Set z3store.* equivalents
git config --global z3store.root "$ROOT"
[ -n "$USER" ] && git config --global z3store.user "$USER"
git config --global z3store.defaultHost "$DEFAULT_HOST"
git config --global z3store.completeUser "$COMPLETE_USER"
git config --global z3store.adoptOnClone "$ADOPT_ON_CLONE"
git config --global z3store.jjColocate "$JJ_COLOCATE"
git config --global z3store.backingStoreRoot "$BACKING_STORE_ROOT"

# Optional — remove the old keys once parity is confirmed
# git config --global --unset ghq.root
# git config --global --unset ghq.user
# git config --global --unset ghq.defaultHost
# git config --global --unset ghq.completeUser
# git config --global --unset gitstore.root
# git config --global --unset gitstore.user
# git config --global --unset gitstore.defaultHost
# git config --global --unset gitstore.completeUser
# git config --global --unset gitstore.adoptOnClone
# git config --global --unset gitstore.jjColocate
# git config --global --unset gitstore.backingStoreRoot
```

### Config key cross-reference

| Legacy (`ghq.*` / `gitstore.*`) | New (`z3store.*`) | Default |
|---|---|---|
| `ghq.root` / `gitstore.root` | `z3store.root` | `~/ghq` |
| `ghq.user` / `gitstore.user` | `z3store.user` | `$USER` |
| `ghq.defaultHost` / `gitstore.defaultHost` | `z3store.defaultHost` | `github.com` |
| `ghq.completeUser` / `gitstore.completeUser` | `z3store.completeUser` | `true` |
| `ghq.<url-pattern>.root` / `gitstore.<url-pattern>.root` | `z3store.<url-pattern>.root` | — |
| `gitstore.adoptOnClone` | `z3store.adoptOnClone` | `true` (no ghq analogue) |
| `gitstore.jjColocate` | `z3store.jjColocate` | `true` (no ghq analogue) |
| `gitstore.backingStoreRoot` | `z3store.backingStoreRoot` | Existing `~/.local/share/z3store`, then existing `~/.local/share/gitstore`, then `~/.local/share/z3store` |

Env vars: `$Z3STORE_ROOT` takes precedence over `$GITSTORE_ROOT`, which takes
precedence over `$GHQ_ROOT` for the working-tree root.
`$Z3STORE_BACKING_STORE_ROOT` takes precedence over
`$GITSTORE_BACKING_STORE_ROOT` for the detached backing store.

## Known gaps in v1

- `zt migrate <new-root>` real-mode returns `error.MigrationNotImplemented`; only `--dry-run` works. Full implementation waits for the WAL replay design.
- `zt root --all` is a no-op that prints the primary root.
- `zt create --vcs hg|svn|bzr` is parked.
- No native Google Drive API sync yet (Linear CEL-378); today shell-outs to `rclone`.

## Troubleshooting

- **`ghq` still runs the Go binary after `chezmoi apply`** — reload the shell function/command cache for your shell. zsh: restart the shell or `source ~/.config/zsh/functions.zsh`. bash: `source ~/.bashrc` and `hash -r`. Nushell: `exec nu` or re-source the config that defines the alias/function. Shell functions don't re-load automatically.
- **`zt list` shows nothing** — check `zt root` matches where your repos live; if empty, `git config --global z3store.root <path>`.
- **`zt list` reports adopted repositories as false** — check `z3store.backingStoreRoot` points to the store referenced by those checkouts' `.git` pointer files.
- **Legacy config warning on every run** — indicates a `z3store.*` key is absent and the matching legacy `gitstore.*` / `ghq.*` key or environment variable is being used; see Phase 3 above.
- **Existing legacy backing-store warning** — no backing-store key is configured and z3store preserved an existing `~/.local/share/gitstore` because checkout pointers may contain absolute paths into it. Configure `z3store.backingStoreRoot` explicitly; do not move the store until those pointers are migrated.
- **Want to fall back to real ghq for a single invocation** — use `command ghq <args>` (the `command` builtin bypasses the shell function).

## Related

- Canonical plan: `~/.claude/plans/libgitstore-v2.md`
- Research: `~/Downloads/Agentic quality management for Zig projects.md`
- Upstream ghq: https://github.com/x-motemen/ghq (v1.8.0 used as audit reference)
- xit-vcs studied for storage model, parked as Phase-2: https://github.com/xit-vcs/xit
- xitdb (Zig 0.16 MVCC store): https://github.com/radarroark/xitdb
