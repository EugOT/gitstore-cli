# DVC Integration

## Purpose

Design a thin DVC-aware layer for gitstore. gitstore should detect DVC projects, surface DVC state where it helps repository hygiene, and shell out to the Python `dvc` binary for DVC-owned behavior. gitstore must not rewrite DVC, replace DVC remotes/cache logic, store credentials, or move large DVC-managed data through `gitstore sync`.

Live tracker note: the planning prompt referenced issue `#36`, but `gh issue view 36` did not resolve in `EugOT/gitstore-cli` during investigation, and `gh issue list --state all` returned no issues. This document preserves the requested issue scope without assuming a visible GitHub issue currently exists.

## In Scope

- DVC project detection in the ghq/gitstore repository listing flow.
- DVC status surfacing in `verify`, `status`, or a dedicated `gitstore dvc status` command.
- A narrow `gitstore dvc <status|pull|push>` passthrough that shells out to `dvc`.
- `GIT_ASKPASS` support and secret redaction for DagShub-style HTTP basic auth.
- rclone filter coexistence so DVC metadata is preserved while DVC cache/tmp data is not double-synced.
- Unit, CLI, and optional live E2E tests.

## Out Of Scope

- Reimplementing DVC commands, cache traversal, remote protocols, or locking.
- Replacing DVC remotes/cache logic.
- MLflow integration.
- Storing tokens or credentials in gitstore config, URLs, logs, or generated files.
- Treating `gitstore sync` as a large-data sync path for DVC outputs.

## Current Integration Points

`list.walk()` is the lowest-cost place to detect DVC metadata. `RepoEntry` already owns per-repo fields such as `rel_path`, `abs_path`, `host`, `owner`, `name`, `is_adopted`, `has_jj`, `worktrees`, `head_sha`, and `last_fetched_unix` (`src/list.zig:21`). `tryAppendRepo()` is reached after host/owner/name traversal and before appending each confirmed repo (`src/list.zig:152`). JSON output is centralized in `renderJson()` (`src/list.zig:335`).

`verify()` checks one repo's adopted `.git` and `.jj` integrity (`src/gitstore.zig:543`). `verifyAll()` iterates entries and skips non-adopted repos (`src/gitstore.zig:628`). `status()` is a natural status-summary extension point, but still shells out to `ghq list --full-path` in current `dev` (`src/gitstore.zig:658`), so DVC status work should avoid deepening that dependency and should be compatible with the planned native-walk cleanup.

CLI help and dispatch live in `src/main.zig`: top-level usage (`src/main.zig:14`), verify dispatch (`src/main.zig:472`), status dispatch (`src/main.zig:588`), sync dispatch (`src/main.zig:616`), and `filter` printing (`src/main.zig:684`). A `gitstore dvc` command should follow these dispatch/help conventions.

Subprocess execution is security-sensitive. `exec.zig` whitelists subprocess environment variables (`src/exec.zig:35`) and documents that children inherit a scrubbed environment rather than the full parent environment (`src/exec.zig:103`, `src/exec.zig:106`). A DVC runner should extend this narrowly instead of widening the global whitelist.

`gitstore sync` writes `hooks.rclone_filter` and calls `rclone sync` (`src/gitstore.zig:767`, `src/gitstore.zig:785`). The filter excludes VCS internals, build/cache outputs, secrets, env files, and logs (`src/hooks.zig:87`). DVC-specific filter additions belong in `src/hooks.zig`, with tests near the existing rclone filter assertions (`src/hooks.zig:275`).

DagShub Git host identity should stay unchanged. Current URL rewriting only has a SourceCraft override (`src/url.zig:179`), and `cloneHost()` returns identity for all non-overridden hosts (`src/url.zig:189`). The existing tests explicitly pin `dagshub.com` identity (`src/url.zig:700`).

## Source Facts

DVC `status` supports local workspace/cache checks, remote/cache checks, `--json`, `--no-updates`, `--remote`, and `--cloud`; remote/cache differences are synchronized with `dvc pull` or `dvc push` ([DVC status](https://doc.dvc.org/command-reference/status)).

DVC `pull` downloads tracked data from a configured DVC remote to the cache and then links or copies it into the workspace; it does not update code or DVC metadata, which remain Git-owned ([DVC pull](https://doc.dvc.org/command-reference/pull)).

DVC `push` uploads cache data to a DVC remote and likewise does not update code, `dvc.yaml`, or `.dvc` files ([DVC push](https://doc.dvc.org/command-reference/push)).

DVC internal files include `.dvc/config`, `.dvc/config.local`, `.dvc/cache`, `.dvc/cache/runs`, and `.dvc/tmp`. DVC documents `.dvc/config.local` as Git-ignored and appropriate for private remote config, and states that no DVC-tracked data should be pushed to Git ([DVC internal files](https://doc.dvc.org/user-guide/project-structure/internal-files)).

DVC `remote modify --local` writes to `.dvc/config.local`, which is the correct place for private remote config such as credentials ([DVC remote modify](https://doc.dvc.org/command-reference/remote/modify)).

DagShub's DVC integration provides DVC-managed storage, supports S3-compatible storage, uses DVC pointer/lock metadata for display, and documents `dvc pull -r origin` / `dvc push -r origin` flows. DagShub's example keeps access keys in local DVC config with `--local` ([DagShub DVC integration](https://dagshub.com/docs/integration_guide/dvc/)).

Git uses `GIT_ASKPASS` by invoking the configured program to answer credential prompts before falling back to other askpass/config/terminal options ([Git credentials](https://git-scm.com/docs/gitcredentials)).

Local shell evidence on 2026-06-25: `dvc` was not on `PATH`; `pixi` was available; this repository did not expose DVC via a repo-local pixi environment. Prior empirical facts to preserve from the investigation are: `dvc version` had been verified in the observed environment, DagShub native DVC storage worked, `dvc pull` previously fetched 481 files, DagShub auth should use username/token HTTP basic auth via `GIT_ASKPASS`, and credentials must not be embedded in URLs because email-like usernames break URL parsing.

DagShub DVC remote URL forms to support without rewriting the Git host include S3-style remotes such as `s3://dvc@dagshub.com/<org>/<repo>.s3` and HTTP-style remotes such as `https://dagshub.com/<org>/<repo>.dvc`.

## Proposed Thin Layer

### Detection

Add `has_dvc: bool` to `RepoEntry`. Compute it in `tryAppendRepo()` using cheap filesystem checks for `.dvc/`, `dvc.yaml`, and root-level `*.dvc`. Do not spawn `dvc` during default `list.walk()`.

Expose `has_dvc` in `gitstore list --json`. Plain list output should remain unchanged by default.

### Status Surfacing

Keep normal `gitstore status` fast and DVC-binary independent. Add one explicit path first:

- `gitstore dvc status [repo] [-- <dvc args>]`

A later optional extension may add `gitstore status --dvc` after the command semantics are proven.

Recommended summary fields for JSON-facing code are `present`, `dvc_binary`, `workspace_dirty`, `cache_remote_dirty`, `remote_name`, and `error`. The first implementation can preserve raw `dvc status --json --no-updates` output under a nested `dvc` object instead of inventing a full status schema.

### Passthrough Commands

Implement only these initial subcommands:

- `gitstore dvc status [repo] [-- <extra dvc args>]`
- `gitstore dvc pull [repo] [-- <extra dvc args>]`
- `gitstore dvc push [repo] [-- <extra dvc args>]`

Resolve `repo` as an explicit path or current working directory first. Avoid ghq-relative shortcuts until ambiguity and tests are settled. Run `dvc` with `cwd` set to the target repo. Reject unknown subcommands.

Do not add an arbitrary `gitstore dvc -- <anything>` escape hatch in the first pass. Add `remote list` later if inspection is needed.

### Auth And Secret Handling

Create a dedicated DVC subprocess helper. Start from the existing scrubbed env model, then allow only narrowly justified DVC auth variables. `GIT_ASKPASS` is allowed when present because the DagShub path relies on it. Do not add `GH_TOKEN`, `GITHUB_TOKEN`, arbitrary `DVC_*`, or broad parent-env passthrough without tests.

Never print askpass script contents, token values, or credential-bearing URLs. Redact userinfo in URLs before logging. Reject or warn on `://<userinfo>@host` DVC remote URLs; credentials belong in askpass or `.dvc/config.local`.

### DagShub Notes

Do not special-case DagShub in URL parsing or clone host rewriting. `dagshub.com` must remain the Git host identity. Treat DagShub DVC URLs as DVC remote data that DVC owns.

DagShub-specific handling should be documentation and redaction only: describe known S3-style and HTTP-style DVC remote shapes, warn against credentials in URLs, and preserve username/token auth through askpass or local DVC config.

### Rclone Coexistence

DVC metadata should be syncable as normal repository metadata: `.dvc/config`, `.dvcignore`, `dvc.yaml`, `dvc.lock`, and `*.dvc` files should not be excluded by gitstore's rclone filter.

DVC cache and temp state should be excluded to avoid double-syncing large data that DVC already manages and to avoid copying lock/tmp state:

```text
- .dvc/cache/**
- .dvc/cache/runs/**
- .dvc/tmp/**
```

Do not try to exclude all DVC outputs from `gitstore sync`; gitstore cannot reliably know DVC outs without asking DVC, and large-data movement is explicitly DVC's job. The documented safe pattern is Git for code/metadata, DVC for data cache/remotes, and gitstore/rclone only for non-DVC working tree backup semantics.

## Implementation Tasks

### 1. Add Detection Metadata

- Add `has_dvc` to `RepoEntry` and deinit/render paths.
- Add a cheap detection helper with `.dvc/`, `dvc.yaml`, and `*.dvc` fixtures.
- Acceptance: `gitstore list --json` includes `has_dvc`; normal list output is unchanged.

### 2. Add DVC Command Help And Dispatch

- Add top-level usage line and `sub_help_dvc`.
- Add `gitstore dvc status|pull|push` parser with unknown-subcommand rejection.
- Acceptance: CLI tests cover help, missing subcommand, unknown subcommand, and passthrough args after `--`.

### 3. Add DVC Runner

- Add a runner module or helper using scrubbed env plus narrowly allowed `GIT_ASKPASS`.
- Run DVC in the target repo cwd.
- Redact credential URLs and never log secrets.
- Acceptance: fake-DVC tests assert argv, cwd, env allowlist, and redaction.

### 4. Add Status Surfacing

- Implement `gitstore dvc status` with `dvc status --json --no-updates` by default.
- Handle absent DVC binary with a clear exit/error.
- Acceptance: DVC-absent tests skip or fail deterministically depending on explicit command use; normal `gitstore status` does not require DVC.

### 5. Add Pull/Push Passthrough

- Implement `gitstore dvc pull` and `gitstore dvc push` as thin wrappers.
- Do not alter `.dvc/config` or remotes.
- Acceptance: fake-DVC tests prove no credential leakage and correct cwd/argv.

### 6. Update Rclone Filter

- Add `.dvc/cache/**`, `.dvc/cache/runs/**`, and `.dvc/tmp/**` excludes.
- Add tests in `src/hooks.zig` near existing rclone filter tests.
- Acceptance: filter excludes DVC cache/tmp and does not exclude `.dvc/config`, `.dvcignore`, `dvc.yaml`, `dvc.lock`, or `*.dvc`.

### 7. Optional DagShub E2E

- Add an opt-in live test gated by env vars such as `GITSTORE_DVC_DAGSHUB_E2E=1`, `GIT_ASKPASS`, and non-secret repo identifiers.
- Acceptance: skipped by default; no token printing; no credentials in URLs; verifies status and a safe pull path against a small fixture repo.

## E2E Test Strategy

Use fake binaries for deterministic command tests. Use real `dvc` only when available. Skip DVC-dependent tests when `dvc` is absent unless the test is specifically validating the absent-binary error path.

DagShub-backed tests must be optional and secret-gated. They must not depend on credentials in URLs. Logs should be scanned for token-like values, askpass script contents, and credential-bearing URL forms.

## Risks And Open Decisions

- Normal `status` can become slow if it spawns `dvc` per repo; keep DVC status explicit first.
- DVC output schemas can change; prefer preserving raw JSON initially.
- Passing too much environment to DVC can weaken the existing subprocess safety model.
- Syncing `.dvc/cache` duplicates data and risks copying lock/temp state.
- Repo argument semantics need a decision: explicit path only first, ghq-relative later if needed.
- `gitstore status` still uses `ghq list` on current `dev`; DVC work should not make that harder to replace with native `list.walk()`.

## Rollback

The feature should be removable without data migration: remove `gitstore dvc` dispatch/help, remove `has_dvc` from list JSON if necessary, and revert rclone filter additions. DVC repositories remain valid because all DVC cache, remote, and metadata semantics stay DVC-owned.
