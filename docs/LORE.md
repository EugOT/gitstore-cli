# EpicGames Lore workspace support in z3store

z3store (`zt`) recognizes, reports on, and safely coexists with
[EpicGames Lore](https://epicgames.github.io/lore/) workspaces. It does **not**
adopt, move, or otherwise mutate Lore's on-disk metadata. This document explains
the integration rationale, the ground truth it rests on, and the recommended way
to keep bulk data out of a Lore worktree.

## What Lore is (and why it is different)

Lore is EpicGames' workspace/VCS system. Each worktree carries its own metadata
directory, `.lore/`, at the worktree root. Its documented contents include:

- `config.toml` — client configuration, including the `[shared_store_to_use]`
  table (`use_shared_store`, `shared_store_path`).
- `instance` — a UUIDv7 identifying the workspace instance.
- `view` — the materialized view state.

Sources (verified 2026-07-04):

- Lore CLI config reference: <https://epicgames.github.io/lore/reference/lore-cli-config/>
- System design, §24.1 (on-disk formats / relocation): <https://epicgames.github.io/lore/explanation/system-design/>

### `.lore/` is NOT relocatable

z3store's core trick for git/jj repos is *adoption*: it moves `.git` into the
store and replaces it with a `gitdir:` pointer file, and symlinks `.jj`. This
works because git and jj both support an out-of-tree gitdir/store via a pointer
or symlink indirection.

**Lore exposes no such indirection for `.lore/`.** There is no pointer file, no
symlink contract, and the on-disk formats are explicitly pre-1.0 and subject to
change (system-design §24.1). Moving or symlinking `.lore/` is unsupported and
would corrupt the workspace. Therefore z3store treats Lore workspaces as
first-class but **immovable**.

## What z3store does

| Command | Behavior on a Lore workspace |
|---------|------------------------------|
| `zt list` | Lore workspaces are enumerated and suffixed with ` [lore]` in plain output; `--json` entries carry `"is_lore": true`. A dir with only `.lore/instance` (no `.git`/`.jj`) still appears. |
| `zt lore <path>` | Prints a read-only report: `instance`/`config.toml` presence and the parsed `[shared_store_to_use]` settings (and whether `shared_store_path` resolves). |
| `zt verify <path>` | On a Lore workspace, in addition to the normal git/jj pointer checks (for git+lore repos), reports instance/config presence and shared-store resolution. A configured-but-missing shared store fails verification. A lore-only workspace skips the git-pointer check (it legitimately has no `.git`). |
| `zt adopt <path>` (lore-only) | **Refuses** with a non-zero exit and a message pointing at `lore shared-store`. **No mutation.** |
| `zt adopt <path>` (git + lore) | Adopts git normally, then prints a one-line note that `.lore/` was left in place. |

z3store **never writes into `.lore/`** under any command.

## Keeping bulk data out of a Lore worktree

Because `.lore/` cannot be relocated, the sanctioned mechanism to keep large
objects out of the worktree is **Lore's own shared store**, configured via the
`[shared_store_to_use]` table in `.lore/config.toml`:

```toml
[shared_store_to_use]
use_shared_store = true
shared_store_path = "/srv/lore/shared"
```

or via the CLI:

```sh
lore shared-store
```

`zt lore <path>` and `zt verify <path>` report whether this is configured and
whether `shared_store_path` currently exists (absolute paths are checked as-is;
relative paths resolve against the worktree root).

## Config scanning

z3store parses **only** the `[shared_store_to_use]` keys with a minimal line
scanner (`src/lore.zig`); it does not depend on a TOML library and ignores all
other tables and keys. This keeps the surface tiny and robust against Lore's
pre-1.0 format churn — z3store reads the two keys it needs and nothing else.
