# z3Store strategic-development handoff — 2026-07-31

## Next-session purpose

Re-plan z3Store strategically from current ground truth. The next session should first reconcile repository/PR/Linear topology, then reduce the existing issue graph into a coherent development roadmap for a reliable background repository-coherence service. Do not begin by implementing another isolated filter or sync patch.

## Original goal

Stop recurring Google Drive “Files not synced / Lost and Found” events without putting terabytes on the internal 250 GB system disk and without treating the permanently attached Crucial NVMe as disposable media.

z3Store/`zt` should become the ownership boundary for development repositories:

- repositories and durable state live on Crucial;
- Git/JJ metadata communicates through VCS remotes, not Google Drive;
- cache, build, temporary, secret, and package-manager artifacts never enter Drive replication;
- durable source, plans, configuration, documentation, and scientific metadata are preserved;
- replication runs reliably in the background and converges without operator attention;
- default behavior is non-destructive, source-authoritative, per-repository, observable, resumable, and fail-closed;
- Google Drive recovery is proven by repeated zero-new-event restart/reboot cycles, not by dismissing notifications;
- `jjColocate=false` is honored, and a z3Store adoption defect must not block unrelated CellKinetica applications.

## Canonical control surfaces

- Storage/Drive controller: [CEL-817](https://linear.app/cellkinetica/issue/CEL-817/z3store-external-nvme-and-google-drive-storagesync-safety-contract)
- Interactive report controller: [CEL-945](https://linear.app/cellkinetica/issue/CEL-945/reportstorage-interactive-z3storedrivefs-issue-pr-repository-graph-and)
- jj adoption owner: [CEL-781](https://linear.app/cellkinetica/issue/CEL-781/z3store-honor-jjcolocate-during-adopt-and-preserve-indexuntracked)
- Legacy aggregate: [CEL-415](https://linear.app/cellkinetica/issue/CEL-415/eugotgitstore-cli)
- Future native Drive backend: [CEL-378](https://linear.app/cellkinetica/issue/CEL-378/gitstore-native-google-drive-sync-replace-rclone)
- Live report: https://report.cordillera.home/r/z3store-drivefs-control-plane

Linear is canonical for issue state. The report is a presentation layer and is stale until rebuilt from the July 31 observations below.

## July 31 live ground truth

### Storage

`duf --json`:

- internal APFS container: 245,107,195,904 bytes total; 15,325,630,464 bytes free (14.3 GiB);
- Crucial: 2,000,189,177,856 bytes total; 129,237,118,976 bytes free (120.4 GiB).

The previous monitor’s 9.3/298.4 GiB values are stale. No cleanup or Drive mutation occurred during this handoff.

### z3Store inventory

`zt list -p --with-head --json` returned:

- 198 rows;
- 37 adopted rows;
- 23 rows reporting JJ;
- 137 absolute-path rows representing listed worktrees/secondary paths as repository-shaped entries.

Selected originals:

| Repository | Adopted | JJ | Listed worktrees | Current reported head |
|---|---:|---:|---:|---|
| EugOT/z3store | yes | yes | 5 (native `wt list` displays 6 rows including the primary) | `eb92bcf596e861424fb2b1bd1e7acc075e7ef0cd` |
| EugOT/dotfiles | yes | yes | 2 | `74c0a614396e53bda366f8cc4f6803fd84598bec` |
| EugOT/modicum_container | yes | yes | 17 | `c46b6137e5701296e5fef6593a9c76c66f198b9e` |
| EugOT/home-cordlab | yes | yes | 10 | `82660b1e1074693282d4f0cb4a9bf00760a32e45` |

This is not a stable topology: zt’s 198 rows and the original/worktree representation differ from the July 22 report’s 192 rows.

### z3Store repository discontinuity

At `/Users/etretiakov/ghq/github.com/EugOT/z3store`:

- Git branch: `archive/2026.07/dirty-CEL-781-safe-adopt` at `eb92bcf5`;
- Git status: only untracked `research/`;
- `wt list`: 6 rows, 1 with changes, 5 ahead; four status calculations fail for the archive row because Git discovery resolves through `/Volumes` and stops at the filesystem boundary;
- JJ status is not equivalent to Git status: it reports a very large working-copy change set at working copy `8b7f7a23`, parent `c901a195`, covering the v2 architecture, scripts, docs, tests, and Zig source.

Therefore **do not call the primary clean**, do not run adoption/sync, and do not delete or repurpose any z3Store worktree until Git common-dir, JJ workspace, physical/logical root, branch ownership, and remote reachability are reconciled.

Current z3Store worktree rows from `wt list`:

- primary/archive `archive/2026.07/dirty-CEL-781-safe-adopt`;
- `release/2026.07-final-stage` at `c540d70c`;
- `feat/stores-schema` at `fca28d1a` (changes marker);
- `test/cel-650-script-lint` at `03ed8ca5`;
- `test/gitstore-verify-relative-status` at `9b8a5f6c`;
- `test/gitstore-relative-verify` at `c901a195` (dirty marker).

### Live GitHub PR inventory

Only two z3Store PRs are currently open; the July 22 claim of five open PRs is stale:

- [#33](https://github.com/EugOT/z3store/pull/33) — `feat/stores-schema`, draft, merge-state CLEAN, head `fca28d1a`, updated 2026-07-31;
- [#32](https://github.com/EugOT/z3store/pull/32) — Cursor Cloud development environment, draft, merge-state UNSTABLE, head `6d5d56ea`, updated 2026-07-31.

The other ahead worktrees currently have no open PR returned by GitHub. They require explicit Linear/branch/commit ownership classification before continuation or cleanup.

## Linear state

- CEL-817: **Backlog**, updated 2026-07-31; 13 active blockers: CEL-1136, CEL-1127, CEL-1126, CEL-1089, CEL-827, CEL-946, CEL-958, CEL-956, CEL-957, CEL-832, CEL-830, CEL-824, CEL-825.
- CEL-945: **In Progress**, blocked by CEL-1153, CEL-1149, CEL-1141, CEL-1072.
- CEL-781: **In Progress**; blocks CEL-811, CEL-770, CEL-772. Its historical preserved implementation/review evidence must be reconciled with the current archive/JJ state rather than assumed current.
- CEL-378 and CEL-415: **Backlog**.
- Report-host provenance branch CEL-1145 remains **In Progress** and is a side lane, not proof that z3Store/Drive is fixed.

The approved July 22 architecture decomposition on CEL-817 remains useful, but every status/head/count must be refreshed:

- filter lane: CEL-1076 → CEL-1075 → CEL-1077 → CEL-1079 → CEL-1078 → CEL-957 integration;
- replication lane: CEL-1080 through CEL-1088 with CEL-956 integration;
- scientific-data authority/comparison: CEL-1089, CEL-1127, CEL-1128 → CEL-1129 → CEL-1130;
- historical Drive attestation/recovery: CEL-1124 → CEL-1123 → CEL-1014 → CEL-946;
- activation remains disabled until the explicit restart/rollback authority and zero-event gates pass.

## Architecture already agreed in principle

The intended daemon is not one whole-GHQ-root `rclone sync`:

1. A per-repository manifest classifies durable content and exclusions.
2. Planning is a strictly zero-write phase with stable machine-readable events.
3. Replication uses non-destructive copy semantics and independent one-way checking; destination deletion is not an unattended default.
4. Each repository has a completion marker plus durable journal/lease, bounded retries, and resumable reconciliation.
5. Local filesystem events are hints; periodic full reconciliation is authoritative.
6. One scheduling authority runs `ztd` directly as a nix-darwin LaunchAgent, with state/cache on Crucial and no Bash/Zsh wrapper.
7. Git, JJ, z3Store metadata, caches, build outputs, temporary files, and secrets are excluded by typed policy.
8. Mixed directories are classified narrowly: for example exclude `.clj-kondo/.cache/**`, not all `.clj-kondo`; preserve durable `.agent`, `.claude`, `.cursor`, and `.vscode` content unless a typed leaf rule proves it disposable.
9. DVC is a baseline, not a commitment. Compare DVC, lakeFS, Oxen, Xet, restic, and Kopia by separate roles: dataset versioning/lineage, object serving, and encrypted backup.

Official sources are already linked in CEL-817; reuse them rather than duplicating research notes. Critical references include rclone copy/check/bisync/Drive semantics, Google Drive resumable uploads/error handling/change feed, Apple launchd guidance, and candidate data-backend architecture docs.

## Immediate strategic sequence for the next session

### 1. Rebuild the control graph before changing code

- Fetch CEL-817 and all direct/indirect children with current status, relations, PR links, and last evidence.
- Fetch all open/merged/closed z3Store PRs updated after 2026-07-22.
- Map every z3Store worktree row to exactly one branch, head, PR, Linear issue, Git status, JJ status/workspace, and disposition.
- Mark stale historical claims explicitly; update the interactive report only after its source snapshot is rebuilt.

Exit criterion: no anonymous ahead/dirty worktree and no issue with missing or contradictory PR ownership.

### 2. Decide the product boundary

Write one concise architecture decision that separates:

- repository adoption and Git/JJ topology;
- durable-content classification;
- replication planning/execution/checking;
- daemon scheduling/journaling/recovery;
- Drive API/backend evolution;
- scientific dataset versioning;
- backup/retention/legal hold.

Exit criterion: each concern has one owner and no issue is blocked by an unrelated subsystem.

### 3. Re-sequence into measurable vertical slices

Recommended order:

1. CEL-781 topology/jjColocate recovery and an installed-version acceptance probe.
2. Pure typed filter evaluator with golden fixtures for Zig, Nu/mise/pixi/vite+, Clojure, editors/agents, Git/JJ, secrets, and mixed durable/cache directories.
3. Per-repository manifest plus plan-only CLI; zero remote writes.
4. One non-destructive copy + independent one-way check slice against an isolated test remote.
5. Durable journal/lease/retry/reconciliation slice, still manually invoked.
6. Disabled-by-default `ztd` LaunchAgent with Crucial state and observability.
7. Historical Drive recovery/quarantine, then two separately observed zero-new-event restart/reboot cycles.
8. Native Drive API backend only after behavior is stable behind the same manifest/evaluator contracts.

Each slice should have an exact Linear owner, one narrow PR (or an explicit stack), fixture-based acceptance, rollback, and a prohibition on destructive Drive mutation.

### 4. Define success metrics

- zero new Lost-and-Found events across two approved restart/reboot cycles;
- zero Git/JJ/z3Store metadata and zero declared cache/build artifacts copied;
- no durable-source false exclusions in the golden corpus;
- deterministic plan output for unchanged source/manifest/toolchain;
- interrupted replication resumes without duplicate/corrupt journal state;
- copy/check mismatch is observable and never silently converted to success;
- no destination deletion unless a separately authorized retention transaction says so;
- internal disk use remains bounded; all build/cache/runtime state is explicitly rooted on Crucial where macOS permits it.

## Important side-lane preservation: home-cordlab CEL-1145

Do not lose this work, but do not let it drive the z3Store strategy session.

- Local worktree: `/Volumes/Crucial/gitstore/github.com/EugOT/home-cordlab.test-CEL-1145-source-identity`
- Local branch/head: `test/CEL-1145-source-identity` at `37bfb32f06f519733bdfa5ef0d4b88f5a9160ac5`
- Local status: two modified files, 57 insertions, `git diff --check` passes.
- Purpose of uncommitted patch: bound the existing-artifact raw read to 250 ms and add a FIFO-path regression after review proved an open could otherwise wait indefinitely.
- The first task-based implementation failed because a raw Erlang file descriptor was used outside its controlling process. The uncommitted revision moves the complete open/classify/read/close operation into the bounded task. **It has not been retested after that correction.**
- Remote PR [#22](https://github.com/EugOT/home-cordlab/pull/22) advanced independently to `796323f510fc221897e6b33435c84438d1ece6a8`; local is behind by one commit.
- PR #22 is OPEN and no longer draft, reviewDecision APPROVED, but merge state UNSTABLE because Kilo Code Review failed. CodeRabbit status is SUCCESS.
- Remote commit `796323f` updates README/toolchain pins and adds Elixir 1.20.2 to the allowlist. It touches `release_step.ex`, so do not pull/rebase/stash/apply blindly over the local patch.

Safe continuation: preserve a patch fingerprint, inspect remote `37bfb32..796323f`, rebase/reapply the two-file local change deliberately, rerun focused/full/deterministic-release gates, then request independent review. Do not merge/deploy as part of the z3Store strategy session.

## Stale artifacts

- The live report JSON was last written 2026-07-22T21:23:09Z and still claims 192 zt rows, old free-space values, old worktree counts, and active review at `37bfb32`.
- Earlier handoff hashes in that report are stale.
- `observation-stamp` exists but failed because it still expects the retired chezmoi path `/Users/etretiakov/.local/share/chezmoi`; this handoff uses direct live command evidence and makes no observation-stamp success claim.

## Safety boundary

- No DriveFS, CloudStorage, rclone, Google Drive object, daemon, launchd, cleanup, package, worktree, branch, PR, or Linear mutation was performed while preparing this handoff.
- Do not run `rclone sync`, destination deletion, broad cleanup, Drive replay, `git worktree prune`, or JJ recovery from this document alone.
- Preserve all unrelated user changes and all ambiguous worktrees.

## Suggested skills and tools

- `linear:linear` — rebuild current issue/dependency/PR ownership graph.
- `github:github` — inspect PR history, current heads, reviews, and branch ownership.
- `browser:control-in-app-browser` — validate the rebuilt interactive report visually and dynamically.
- `google-drive:google-drive` — read-only Drive evidence only, with no object mutation until separately authorized.
- `codex-security:threat-model` — define trust boundaries for repository metadata, manifests, journals, and remote writes.
- `elicit-research` — compare scientific-data/versioning alternatives from primary literature and authoritative technical sources.
- Context7 — current Nu, Zig, rclone, Elixir, and backend library contracts where applicable.
- CLIs: `nu`, `zt`, `wt`, `git`, `jj`, `gt`, `gh`, `duf`, and `dust`; use Nu for orchestration.

## First prompt for the next session

“Use this handoff only as an index. Validate all state live. Start with CEL-817, the two current z3Store PRs, all six `wt list` rows, and Git/JJ status for each. Produce a corrected issue/PR/worktree architecture graph and a prioritized, measurable z3Store roadmap before any implementation or Drive mutation.”
