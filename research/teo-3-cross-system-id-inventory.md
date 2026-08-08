# TEO-3 — Cross-system identifier inventory (CEL-* / z3store / zt)

**Ticket:** [TEO-3](https://linear.app/cellkinetica/issue/TEO-3)  
**Parent map:** [TEO-1](https://linear.app/cellkinetica/issue/TEO-1)  
**Mode:** discovery only (no mutations)  
**Survey date:** 2026-07-31  
**Method:** read-only `rg`/`fd` over local FS, OpenViking volume, report-host data dir, chezmoi source, ghq checkouts; HTTP fetch of `report.cordillera.home` blocked (SSRF/private IP). Tana-local MCP and AgentMemory HTTPS were **not** invokable from this subagent session — status is filesystem evidence + secondary citations only.

## Legend

| Disposition | Meaning |
|---|---|
| **rewrite-to-TEO** | Still treated as live work; identity should migrate from CEL-* / gitstore naming into TEO plane (or explicit successor ticket) |
| **deprecate** | Actively misleading if left as-is; rewrite or retire |
| **keep-historical** | Accurate-as-of snapshot; leave as archive provenance |
| **keep-load-bearing** | On-disk / product path that still works; renaming is dangerous without verify |
| **unknown** | Cited but not re-validated live in this pass |

Freshness: `live` (2026-07-27+ evidence re-read), `stale` (pre-rename or pre-freeze content still presented as current), `mixed`, `unqueried`.

---

## 1. Executive findings

1. **Product rename landed; store path names did not.** Working tree is `…/EugOT/z3store`; detached gitdir remains `/Volumes/Crucial/gitstore/github.com/EugOT/gitstore-cli/git`. This is load-bearing, not a bug to “fix” casually.
2. **CEL-616** outside Linear is mostly *two-root contract* history (`test/cel-616-two-root-contract`) **and** a **conflated** “zt broken estate-wide” claim in Track-2 handoffs — do not treat those as the same acceptance criteria without Linear reconciliation (TEO plane).
3. **CEL-781** is widely mirrored as **frozen mid-flight safe-adopt** at `eb92bcf` / branch `archive/2026.07/dirty-CEL-781-safe-adopt` — OpenViking entity + report-host handoff + release freeze docs agree.
4. **report.cordillera.home surfaces are heavily stale on the default dashboard** (`current.json` = 2026-06-21 pz wave) while **named reports** under `~/.local/share/report-host/reports/` hold the real z3store/CEL material.
5. **Legacy `gitstore` / `gitstore-cli` identifiers still dominate** chezmoi docs, espanso snippets, Nu helpers, home-cordlab sync scripts, PR dashboards, and andes recovery trees.
6. **TEO-*** IDs: **no durable non-Linear hits** found in FS/OpenViking/report-host as of this survey (expected — TEO plane is new).

---

## 2. Inventory table

### 2.1 OpenViking (`viking.cordillera.home` / local OrbStack volume)

| Path / URI | IDs referenced | Freshness | Disposition | Notes |
|---|---|---|---|---|
| `viking://resources/EugOT/z3store` (volume: `…/resources/EugOT/z3store/`) | z3store, zt, gitstore (lockfile/AGENTS text residue) | live resource ingest 2026-07-28 | **keep-load-bearing** (repo mirror) + partial **deprecate** AGENTS residue saying `gitstore-cli` | Indexed project tree + overviews |
| `viking://resources/observations/2026-07-10T180500Z-z3store-migration-complete.md` | CEL-496, CEL-497, CEL-499, CEL-500; z3store; zt v0.3.0; gitstore rename | keep-historical (2026-07-10) | **keep-historical** | Closure observation; sierranevada disk block may be outdated |
| `…/memories/entities/code_repository/z3store.md` | CEL-781; z3store; archive branch `dirty-CEL-781-safe-adopt`; HEAD `eb92bcf`; PRs #32/#33 | mirrors 2026-07-27 handoff | **rewrite-to-TEO** (if TEO owns safe-adopt resume) else **keep-load-bearing** freeze note | **Stale risk:** claims primary checkout *is* archive branch — true as of 2026-07-27, re-check before acting |
| `…/memories/entities/reproducibility_caveat/z3store_reproducibility_caveats.md` | z3store | thin | **keep-load-bearing** | Caveats incomplete vs handoff §7 |
| `…/memories/entities/repository_group/cellkinetica_infra.md` | z3store; tag `v2026.07-final-stage` | live-ish | **keep-historical** | Freeze tag coordinated across infra |
| `…/memories/preferences/user/vcs_workflow.md` | zt, z3store, gt, wt | live | **keep-load-bearing** | Preferred VCS trio |
| Session archive `mcp-store-777017ffa8b6` (CEL-1204 HISTOS map) | z3store/zt “broken estate-wide” (truncated) | 2026-07-28 session | **deprecate** as global truth; **keep-historical** for HISTOS risk framing | Ties zt health to Crucial single-copy risk |
| Session archives `__openviking_resource_reason__` | migration observation URI | historical | **keep-historical** | Repeated reason logs for resource add |
| `…/memories/entities/wayfinding_map/track2_wayfinder.md` | Tana node `pBj_Z7STV7xf` (Track 2 map) | 2026-07-30 | **unknown** for TEO rewrite | Linear deferred; Tana-canonical map |

### 2.2 report.cordillera.home / report-host

Live data root: `~/.local/share/report-host/` (Caddy → report-host :4000).

| Surface / path | IDs | Freshness | Disposition | Notes |
|---|---|---|---|---|
| `https://report.cordillera.home/` (default `current.json`) | none for z3store | **stale** (2026-06-21 pz Wave 3) | **deprecate as estate status** | Does **not** reflect z3store/CEL freeze |
| `…/reports/z3store-drivefs-control-plane.json` → `/r/z3store-drivefs-control-plane` | CEL-945, 1072, 1142–1154, **CEL-752, CEL-781**, CEL-956/957, z3store, zt | 2026-07-22 | **rewrite-to-TEO** (control plane ownership) / **keep-historical** snapshot | Best single operational report for z3store×DriveFS |
| `…/reports/cellkinetica-handoffs-20260727.json` slug `z3store` → `/r/cellkinetica-handoffs-20260727/z3store` | CEL-378,452,454,456,460,497,**616**,645–650,**781**,750; z3store; zt; gitstore-cli path skew | 2026-07-27 **live verified then** | **keep-load-bearing** handoff; **rewrite-to-TEO** for open work list | Documents three PATH `zt` binaries, store path skew, freeze HEAD |
| `…/reports/gitstore-clone-domain.json` | gitstore-cli PR #11/#12 | 2026-06 era | **keep-historical** | Pre-rename product name |
| `…/reports/eugot-fork-reconciliation.json` | gitstore-cli #18–#21; gitstore verify | 2026-06-29–07-02 | **keep-historical** | Tana nodes `2hfo-4dkEbaT`, `CEX3FYsi2cs3` |
| `…/reports/onepassword-op-mcp.json` | gitstore verify --all | mid-2026 | **keep-historical** | Command names pre-`zt` |
| `…/reports/modicum-governance-control-plane-rerun.json` | `/opt/homebrew/bin/gitstore` | mid-2026 | **deprecate** if still shown as current | Binary name likely superseded by `zt` |
| `…/reports/monitor-cellkinetica-reproducibility-20260727.json` | z3store fully-pinned vs peers | 2026-07-27 | **keep-historical** | Infra reproducibility contrast |
| `…/reports/report-platform-v2.json` | gitstore-env-smoke #429 | mid-2026 | **keep-historical** | Dotfiles PR title |
| `…/reports/development-workflow-reliability.json` | gitstore as tier label | mid-2026 | **rewrite-to-TEO** / **deprecate** label | T3 still says “gitstore” |
| `current.json.bak.gitstore-*`, `current.json.bak.split-*` | gitstore×Drive diagnosis | 2026-06 | **keep-historical** | Backups of earlier default dashboards |
| `~/reports/pr_dashboard/priv/status.json` | EugOT/**gitstore-cli** PRs | 2026-06-20 FINAL | **deprecate** | Repo rename not reflected |
| `~/reports/pr_dashboard/priv/tool-decisions.json` | gitstore-cli as canonical Zig tool; brew `gitstore` | 2026-06 | **deprecate** | Should say z3store/`zt` |
| `~/reports/pr_dashboard/priv/gitstore_report.json` | gitstore v0.2.2 hosts | 2026-06-21 | **keep-historical** | DriveFS diagnosis ancestor of z3store-drivefs report |
| `~/reports/pr_dashboard/priv/migration-progress.json` | gitstore-gdrive-sync mention | 2026-06-22 | **keep-historical** | home-cordlab role text |
| `~/srv/ziglint_dash/priv/audit/pr_split_report.json` | gitstore-cli URLs | older | **keep-historical** | Nested session dump |
| home-cordlab `apps/report-host/scripts/publish-report.ts` | title `gitstore-env-smoke` | code fixture | **rewrite-to-TEO** / rename when next touched | Test/example title |
| home-cordlab `apps/report-host/test/.../cheboard_live_test.exs` | `bootstrapCommand: gitstore get` | fixture | **deprecate** when CheBoard contract updates | Fixture string |

### 2.3 Explicit report.cordillera.home surfaces that look **out of date**

These are the surfaces most likely to mislead an agent if treated as current:

1. **Default dashboard** `https://report.cordillera.home/` / `~/.local/share/report-host/current.json` — still **pz Wave 3 (2026-06-21)**; zero z3store/CEL freeze content.
2. **`/r/gitstore-clone-domain`** — product name and PR numbers pre-rename.
3. **`/r/eugot-fork-reconciliation`** — `gitstore-cli` stack narrative; Tana checkpoints from early July only.
4. **`/r/onepassword-op-mcp`** — still documents `gitstore verify` success as current ops language.
5. **`/r/modicum-governance-control-plane-rerun`** — points at `gitstore` binary path.
6. **`/r/development-workflow-reliability`** — tier taxonomy still says “T3 gitstore”.
7. **PR dashboard** `~/reports/pr_dashboard/priv/status.json` + `tool-decisions.json` — still **gitstore-cli** as live repo identity.
8. **Migration dashboard** `migration-progress.json` (2026-06-22 “100% done”) — does not encode CEL-781 freeze or 2026.07 final-stage archive.
9. **Possibly stale relative to later work:** `z3store-drivefs-control-plane` (2026-07-22) vs handoff (2026-07-27) — control plane may lag freeze HEAD `eb92bcf`.

**Still relatively fresh (not on default index):**  
`/r/cellkinetica-handoffs-20260727/z3store`, `/r/monitor-cellkinetica-reproducibility-20260727`.

### 2.4 Tana-local

| Evidence | IDs | Freshness | Disposition | Notes |
|---|---|---|---|---|
| OpenViking entity: Track 2 map node `pBj_Z7STV7xf` (workspace `BJwxYLKeC3`) | Track 2 platform; not TEO | 2026-07-30 | **unknown** | Canonical map claimed in Tana; Linear deferred |
| report `z3store-drivefs-control-plane`: nodes `FRTKde5PgIM6`, `QqwsDzbXan2B` | storage cleanup / Dev_Log | 2026-07-22 | **keep-historical** | Chronology pass recorded |
| report `eugot-fork-reconciliation`: `2hfo-4dkEbaT`, child `CEX3FYsi2cs3` | gitstore-cli PR stack | early July | **keep-historical** | Pre-rename |
| Live Tana MCP search | — | **unqueried this pass** | **unknown** | Re-run with tana-local `search_nodes` for `z3store`, `CEL-616`, `CEL-781`, `TEO-` |

No Tana export dump under `~/Documents` was content-scanned exhaustively (timeout risk); secondary citations only.

### 2.5 AgentMemory (`https://agentmemory.cordillera.home`)

| Evidence | Freshness | Disposition |
|---|---|---|
| No local corpus hits for CEL-616 / CEL-781 / z3store / TEO under common FS roots | unqueried live | **unknown** |
| Eval/report material exists for *AgentMemory vs OpenViking* (`agentmemory-vs-openviking-eval-2026-07-27`) without product ID rewrite | 2026-07-27 | **keep-historical** for eval only |

Policy docs already treat AgentMemory as evaluation companion, not write prerequisite. No evidence of TEO id materialization there.

### 2.6 Local / remote filesystems

#### Load-bearing product & store layout

| Path | IDs | Freshness | Disposition |
|---|---|---|---|
| `/Users/etretiakov/ghq/github.com/EugOT/z3store` (→ Crucial) | z3store, zt, CEL-456, CEL-378, internal `gitstore_*` test temps | live code | **keep-load-bearing** |
| `/Volumes/Crucial/gitstore/github.com/EugOT/gitstore-cli/git` | **gitstore-cli path**, serves z3store worktree | live | **keep-load-bearing** (absolute pointer invariant) |
| `/Volumes/Crucial/gitstore/` (backing store root name) | gitstore directory name | live | **keep-load-bearing** until deliberate migrate |
| Worktrees under `…/gitstore-cli.release-2026.07-final-stage`, `…/gitstore-cli.test-cel-650-script-lint` | gitstore-cli dirname, release/CEL-650 | mixed | **keep-historical** / prune candidates (per handoff) |
| `/Volumes/Crucial/tmp/gitstore-relative-verify` | pre-rename sources | **stale+dirty** (handoff) | **deprecate** / triage |
| `/Volumes/Crucial/tmp/gitstore-verify-relative-status` | relative verify era | stale | **deprecate** |
| `/Volumes/Crucial/worktrees/z3store-stores-schema` | PR #33 | keep until PR | **keep-load-bearing** while PR open |
| Binary names: `zt` (product), legacy `gitstore` still in some zig-out / brew history | zt / gitstore | mixed | **keep-load-bearing** zt; **deprecate** teaching agents to run `gitstore` |

#### Chezmoi / dotfiles source (`~/.local/share/chezmoi`)

| Path | IDs | Freshness | Disposition |
|---|---|---|---|
| `docs/MIGRATION-ghq-to-z3store.md`, `docs/GIT-WORKFLOW-QUICKREF.md`, `docs/JJ-WORKFLOW.md` | zt / z3store | post-rename | **keep-load-bearing** |
| `docs/RELEASE-2026.07-final-stage.md` | z3store PRs #32/#33; **CEL-781** dirty archive; gitstore wording for Crucial edit root | 2026-07 freeze | **keep-historical** + **rewrite-to-TEO** for open dirty list |
| `docs/PLAYBOOK.md`, `docs/GIT-WORKFLOW-SUMMARY.md` | **gitstore** commands | **stale** | **deprecate** → zt |
| `docs/agent-tooling-policy-sources.md` | gitstore --help surface | **stale** | **deprecate** |
| `dot_config/nushell/functions.nu` (`gitstore-cd`, `gitstore-status`, ghq→gitstore) | gitstore | **stale** vs CheBoard AGENTS (“do not invoke gitstore”) | **deprecate** / dual-compat until verified |
| `dot_config/espanso/match/cli-aliases.yml` | `gitstore *` snippets | **stale** | **deprecate** |
| `dot_codex/config.toml.tmpl` | `gitstore verify` in agent checklist | **stale** | **deprecate** |
| `dot_config/nix/darwin-configuration.nix.tmpl` | brew `z3store` | live | **keep-load-bearing** |
| `docs/k3s-mlops-agentops-evolution-plan.md` | gitstore-cli (non-claims disclaimer) | historical | **keep-historical** |

#### Sibling repos (ghq)

| Path | IDs | Disposition |
|---|---|---|
| `CheBoard/AGENTS.md` | z3store replaced gitstore-cli; use **zt** only | **keep-load-bearing** |
| `home-cordlab/README.md`, `bin/build-runners-sync.sh` | allowlist **z3store** | **keep-load-bearing** |
| `home-cordlab/bin/gitstore-gdrive-sync.sh`, `gitstore-filter-rules.txt` | **gitstore** naming | **mixed**: script may still work if binary/filter paths exist → **rewrite-to-TEO** or dual-name |
| `home-cordlab/docs/RELEASE-2026.07-final-stage.md` | `zt list …` | **keep-load-bearing** |
| `hd.test-CEL-763-adoption-validation/workflow/*` | expected_outcomes **zt** | **keep-load-bearing** (hd adoption contract) |
| `cluster-config` octelium docs | domain `zt.secureinfra.ai` (unrelated product token) | **keep-historical** (not z3store) |
| Toolkits still saying **gitstore-cli** as “live adopter” (e.g. older zeal/nullclaw ADRs on Crucial worktrees) | gitstore-cli | **deprecate** in active worktrees; **keep-historical** in backups |

#### Handoffs / journals / recovery

| Path | IDs | Freshness | Disposition |
|---|---|---|---|
| `~/handoffs-20260728/HANDOFF-track2-platform.md` | **CEL-616** as “z3store/zt broken estate-wide” | 2026-07-28 | **rewrite-to-TEO** (clarify identity); **do not** equate to two-root ticket without Linear check |
| `~/Documents/02_areas/2026-07-04-195943-refactor-of-gitstore-into-z3store-wt-new-features.txt` | rename session export | historical | **keep-historical** |
| `~/andes-recovery/**`, `~/andes-rescue/**`, `/Volumes/Crucial/backups/**`, `/Volumes/Crucial/andes-final-backup-*` | gitstore-cli, gitstore | frozen backup | **keep-historical** |
| Claude project memory under andes-rescue for `gitstore-cli` Graphite workflow | gitstore-cli | pre-rename | **keep-historical** / **deprecate** if still in active agent memory load path |

#### Unrelated CEL noise (out of TEO-3 scope but greppable)

Hundreds of **other** `CEL-*` IDs in scientific repos (params CEL-560, histos CEL-546/883/909, Odeon CEL-550, CheBoard CEL-678–680, etc.). Inventory intentionally **does not** rewrite those to TEO unless they name **z3store/zt/gitstore**.

---

## 3. ID-centric rollup

### CEL-616
| Where | Claim | Disposition |
|---|---|---|
| z3store handoff §5–6 | two-root contract separation (`996d049`, branch `test/cel-616-two-root-contract`) | **keep-historical** technical; open config asymmetry still “CEL-616 territory” → **rewrite-to-TEO** if TEO owns root contracts |
| Track-2 handoff + OpenViking HISTOS session | “zt broken estate-wide (CEL-616)” | **deprecate** conflation until Linear proves same ticket |
| Linear | out of scope for this FS survey | parent TEO plane |

### CEL-781
| Where | Claim | Disposition |
|---|---|---|
| OpenViking entity z3store.md | frozen mid-flight at `eb92bcf` | **rewrite-to-TEO** (resume/re-spec) or **keep-load-bearing** freeze |
| report handoff z3store | same + archive branch/tag | same |
| chezmoi/release freeze docs | dirty archive branch listed | **keep-historical** |
| z3store-drivefs control plane | CEL-781 before filter/daemon work | **rewrite-to-TEO** sequencing |

### CEL-496 / 497 / 499 / 500
| Where | Claim | Disposition |
|---|---|---|
| OpenViking migration observation 2026-07-10 | rename + multi-node rollout | **keep-historical** |

### CEL-752 / 945 / 956 / 957 / 107x / 114x (adjacent)
Appear primarily in `z3store-drivefs-control-plane` — operational children of store/Drive recovery, not product rename. Disposition: **rewrite-to-TEO** only if TEO map absorbs DriveFS recovery; else leave under CellKinetica CEL plane.

### z3store / zt (product)
Load-bearing everywhere the CLI and repo are real. Prefer **zt** in agent instructions (CheBoard AGENTS is canonical). Internal Zig still uses `gitstore_root` variable names and `/tmp/gitstore_*` test paths — **keep-load-bearing** code identifiers unless a rename PR is intentional.

### gitstore / gitstore-cli (legacy)
| Class | Disposition |
|---|---|
| Detached store directory names under `/Volumes/Crucial/gitstore/.../gitstore-cli` | **keep-load-bearing** |
| Docs/scripts teaching `gitstore` as current CLI | **deprecate** |
| Historical reports and backups | **keep-historical** |
| Homebrew formula `gitstore.rb` (deprecated per migration observation) | **keep-historical** / confirm tap state separately |

### TEO-*
No non-Linear durable hits. This inventory file is the first local TEO-3 artifact under `z3store/research/`.

---

## 4. Coverage gaps (explicit)

| Surface | Status |
|---|---|
| Live Linear issue bodies for CEL-616/781 vs TEO mapping | not re-fetched (outside “outside Linear” mandate for content, but mapping still needs a TEO-1 follow-up) |
| Live Tana-local `search_nodes` | **not run** (MCP not bound in this subagent) |
| Live AgentMemory HTTP search | **not run** |
| Live `https://report.cordillera.home/*` HTTP | blocked private IP from sandbox fetch; FS backing store used instead |
| Whether PATH still prefers stale `~/.local/bin/zt` (2026-07-10) | reported in 2026-07-27 handoff; **not re-hashed this pass** |
| sierranevada install state from 2026-07-10 observation | **unknown** now |

---

## 5. Recommended rewrite priority (non-mutating advice)

1. **Default report-host `current.json`** — estate agents read this first; currently unrelated pz snapshot.
2. **Chezmoi Nu/espanso/codex “gitstore” command surfaces** vs CheBoard “never invoke gitstore”.
3. **OpenViking z3store entity** — re-stamp after any checkout moves off CEL-781 archive branch.
4. **Track-2 CEL-616 phrasing** — split “two-root contract” vs “estate zt health” before TEO rewrite.
5. **PR dashboard / tool-decisions** — rename identity to `EugOT/z3store` / `zt`.
6. Leave **store path `…/gitstore-cli/git`** alone until a TEO-owned migration with `zt verify --all`.

---

## 6. Provenance

- Discovery-only; no files outside this report were modified except creation of this inventory.
- Primary high-fidelity source for open work: `~/.local/share/report-host/reports/cellkinetica-handoffs-20260727.json` (slug `z3store`).
- Primary operational control plane: `…/reports/z3store-drivefs-control-plane.json`.
- Primary memory entity: OpenViking `memories/entities/code_repository/z3store.md`.
