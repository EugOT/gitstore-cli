# TEO-2 — CEL → TEO inventory for z3store / `zt` storage tooling

**Ticket:** [TEO-2](https://linear.app/cellkinetica/issue/TEO-2)  
**Parent map:** [TEO-1](https://linear.app/cellkinetica/issue/TEO-1)  
**Workspace:** CellKinetica (CEL) · target personal team **TEO** (Eugedotnet)  
**Scope:** Inventory only — **no bulk Linear moves**, no issue comments, no closes.  
**Date:** 2026-07-31  

## Evidence provenance (read-only)

| Source | What was used |
|--------|----------------|
| Prior Linear MCP issue dumps (CheBoard agent-tools) | Full JSON payloads for many CEL issues including z3store/Drive clusters |
| OpenViking observation | `2026-07-10T180500Z-z3store-migration-complete` (CEL-496/497/499/500) |
| OpenViking entity memory | `z3store.md` (CEL-781 freeze) |
| GitHub API `EugOT/z3store` issues/PRs | Live public surface (#22 open; PR trail maps CEL-496–500, 616, 497) |
| Local repo | `docs/MIGRATION-ghq-to-gitstore.md` (CEL-378), scripts refs (CEL-456), `doc/DVC_INTEGRATION.md` |
| Chezmoi docs | `docs/MIGRATION-ghq-to-z3store.md`, `docs/RELEASE-2026.07-final-stage.md` |

**Limitation:** This subagent session could not call live Linear MCP (`user-linear` requires auth; web Linear shells do not return data). Status fields are **as of last successful MCP dump / agent update** (≈ mid–late July 2026) unless marked *live GitHub*. Re-run `list_issues query=z3store team=CellKinetica` on the parent agent before any move.

### Classification rules

| Verdict | Meaning |
|---------|---------|
| **migrate-to-TEO** | Owns z3store/`zt` product work (CLI, adopt/detach, backing store, lint, identity rename) |
| **stay-CEL** | Mentions zt/z3store only as consumer tooling; real owner is chezmoi, HD, product suite, or shared platform |
| **split/re-scope** | Mixed ownership — keep CEL shell or estate half; migrate product half or clone |
| **archive-only** | Done/canceled history; migrate only if TEO wants closed history continuity |

---

## Inventory table

| ID | Title | Type | Status (evidence) | Project | Parent | Verdict | Rationale |
|----|-------|------|-------------------|---------|--------|---------|-----------|
| **TEO-1** | Wayfinder parent map (CEL→TEO) | Issue | Active (parent of TEO-2) | — | — | **stay-CEL** *(TEO-native)* | Already on TEO; coordination map, not z3store product work. |
| **TEO-2** | This research inventory | Issue | Active | — | TEO-1 | **stay-CEL** *(TEO-native)* | Research/meta ticket; output is this file. |
| **CEL-496** | gitstore → z3store rename / migration epic (repo + brand) | Issue | Done (obs 2026-07-10) | — | — | **archive-only** | Completed rename epic; history for TEO if desired, no open product work. |
| **CEL-497** | z3store identity / CLI `zt` + Lore recognition | Issue | Done (PR #24/#29/#31) | — | CEL-496 (companion) | **archive-only** | Product rename shipped on `dev` via PR #24; docs identity PR #29 closed after #31. |
| **CEL-498** | Homebrew tap Formula/z3store.rb (gitstore.rb deprecate) | Issue | Done (obs 2026-07-10) | — | CEL-496 (companion) | **migrate-to-TEO** | Packaging surface for personal `zt` binary; not CellKinetica product. |
| **CEL-499** | Dotfiles shell wrappers zt-first (PR #446) | Issue | Done (obs 2026-07-10) | — | CEL-496 (companion) | **stay-CEL** | Chezmoi/dotfiles deploy lane; wrappers live in EugOT/dotfiles, not z3store. |
| **CEL-500** | Multi-node zt rollout (andes/minerva/himalayas/sierranevada) | Issue | Partial (3/4 nodes; sierranevada blocked) | — | CEL-496 (companion) | **split/re-scope** | Product binary is TEO; host disk/install remediation is estate/CEL ops. |
| **CEL-616** | z3store (zt) broken estate-wide: verify/status → FileNotFound | Issue | In Review→merged path (PR #30/#31) | — | — | **migrate-to-TEO** | Core two-root contract (`root` vs `backingStoreRoot`); pure z3store product. |
| **CEL-645** | z3store restore zero-finding repo-wide ziglint gate | Issue | In Progress→integrated (#30/#31) | — | — | **migrate-to-TEO** | Repo-local quality gate for EugOT/z3store. |
| **CEL-646** | z3store lint: list module cleanup | Issue | In Progress→integrated | — | CEL-645 | **migrate-to-TEO** | Atomic `src/list.zig` ownership in z3store. |
| **CEL-647** | z3store lint: integration test harness cleanup | Issue | In Progress→integrated | — | CEL-645 | **migrate-to-TEO** | Atomic `src/tests.zig` ownership in z3store. |
| **CEL-648** | z3store lint: clone/cache/log/exec cleanup | Issue | In Progress→integrated | — | CEL-645 | **migrate-to-TEO** | Atomic product modules in z3store. |
| **CEL-649** | z3store lint: config/main/hooks/url and ZON routing cleanup | Issue | In Progress→integrated | — | CEL-645 | **migrate-to-TEO** | Atomic product modules in z3store. |
| **CEL-650** | z3store lint: build/release script cleanup | Issue | Integrated (#30/#31) | — | CEL-645 | **migrate-to-TEO** | Atomic scripts lint for z3store gates. |
| **CEL-781** | safe-adopt (WIP freeze `archive/2026.07/dirty-CEL-781-safe-adopt`) | Issue | Frozen mid-flight (OpenViking) | — | — | **migrate-to-TEO** | Open product work: adopt safety/rollback; archive tip is source of truth. |
| **CEL-378** | gitstore: Native Google Drive sync (replace rclone) | Issue | Backlog | — | — | **migrate-to-TEO** | Feature on z3store/`zt sync` (still referenced in migration doc); not a separate DriveFS product suite. |
| **CEL-381** | Local-to-remote directory tree diff engine | Issue | Backlog | — | CEL-378 | **migrate-to-TEO** | Child of z3store native Drive sync epic. |
| **CEL-382** | Sync engine: execute changeset with progress reporting | Issue | Backlog | — | CEL-378 | **migrate-to-TEO** | Child of z3store native Drive sync epic. |
| **CEL-384** | Native filter rule evaluator (rclone-style glob matching) | Issue | Backlog | — | CEL-378 | **migrate-to-TEO** | Child of z3store native Drive sync epic (unblocks diff). |
| **CEL-379…383,385…** *(if present)* | Other CEL-378 children (OAuth/Drive API/cache — not all IDs confirmed live) | Issue | Backlog (expected) | — | CEL-378 | **migrate-to-TEO** | Re-list with `parentId=CEL-378` before move; treat as same epic. |
| **GH #22** | gitstore get: repos fetched but never adopted… | GitHub issue | Open *(live)* | — | — | **migrate-to-TEO** | Product adopt/reporting defect; residual follow-ups after PR #23. |
| **GH #33** | feat(schema): stores module and gitstore schema | GitHub PR (draft) | Open draft *(live)* | — | — | **migrate-to-TEO** | Product schema/store config WIP; archive-tagged. |
| **GH #32** | Cursor Cloud dev environment for z3store | GitHub PR (draft) | Open draft *(live)* | — | — | **migrate-to-TEO** | Dev-env for product repo; archive-tagged. |
| **doc/DVC_INTEGRATION.md** + workflow | DVC-aware layer for gitstore/z3store | Document / asset | Planning doc in repo | — | (no Linear #36 found) | **migrate-to-TEO** | Product design for `zt` + DVC coexistence; lives in z3store tree. |
| **docs/MIGRATION-ghq-to-gitstore.md** | ghq → z3store migration guide | Document | In-repo | — | — | **migrate-to-TEO** | Product user docs (mentions CEL-378). |
| **docs/LORE.md** | EpicGames Lore coexistence | Document | In-repo | — | CEL-497 | **migrate-to-TEO** | Product behavior docs. |
| **chezmoi `docs/MIGRATION-ghq-to-z3store.md`** | Estate migration playbook | Document | Dotfiles | — | CEL-499 | **stay-CEL** | Chezmoi-owned install/activate guidance. |
| **CEL-465** | Run final multi-repo validation and PR split | Issue | Backlog | Development Workflow Reliability Upgrade | — | **split/re-scope** | Explicitly validates **gitstore-cli/z3store** *and* claude-zig-quality; keep CEL platform half, TEO product half. |
| **CEL-456** (and **CEL-452…455**) | zig-qm-toolkit defects (referenced in z3store scripts) | Issue(s) | Mixed | (toolkit / multi-adopter) | — | **stay-CEL** | Shared quality toolkit adopted by many Zig repos; z3store only consumes. |
| **CEL-592** | chezmoi atomic control-plane PR slice | Issue | (cache) | — | — | **stay-CEL** | Chezmoi dirty-tree work; only *mentions* `zt` inventory counts. |
| **CEL-661 / CEL-679 / CEL-678 / CEL-680** | Chezmoi drift classifier + CheBoard consumer | Issue cluster | Mixed | Dev Workflow / Three-Repo Split | CEL-462 etc. | **stay-CEL** | Control-plane/CheBoard; not z3store product. |
| **CEL-761…768** | HD CONTROL / HD N0–N6 adopt EugOT/hd | Issue cluster | Mixed | Development Workflow Reliability Upgrade | CEL-761 | **stay-CEL** | HD product suite adopt graph; only parallel to z3store worktrees historically. |
| **CEL-369** | Rebuild agent platform / skills root | Issue | High | — | — | **stay-CEL** | Agent platform; mentions z3store only as repo lookup. |
| **CEL-750** | Restore required Zeal PR-contract commands (incl. gitstore/`zt`) | Issue | Urgent (cache) | — | — | **stay-CEL** | Host tooling for Zeal contract; consumer of `zt`, not product. |
| **Project: Development Workflow Reliability Upgrade** | Multi-repo reliability umbrella | Project | Active | — | — | **stay-CEL** | Platform umbrella; hosts CEL-465 and HD, not z3store-only. |
| **Project: Three-Repo Split Reconciliation** | dotfiles / cluster-config / home-cordlab | Project | Active | — | — | **stay-CEL** | Estate split; incidental zt usage. |
| **No dedicated Linear project named “z3store”** | — | Project | n/a | — | — | **migrate-to-TEO** *(create on TEO)* | Recommend creating a TEO project **z3store / zt** for migrated issues. |

---

## Counts (by verdict)

| Verdict | Count (rows in table) |
|---------|------------------------:|
| **migrate-to-TEO** | **22** |
| **stay-CEL** (incl. TEO-native meta + shared CEL) | **14** |
| **split/re-scope** | **2** |
| **archive-only** | **2** |
| **Total classified rows** | **40** |

### Product-core migrate set (recommended first wave)

| ID | Why first |
|----|-----------|
| CEL-616 + CEL-645…650 | Active quality/contract stack (mostly integrated; close/migrate status hygiene) |
| CEL-781 | Only large open product WIP (safe-adopt) |
| CEL-378 + children | Backlog feature epic still on CEL |
| CEL-498 | Tap ownership for personal tooling |
| GH #22 / #33 / #32 | GitHub-native product backlog |

### Explicit non-migrate (stay-CEL) examples

- Chezmoi wrappers and estate playbooks (**CEL-499**, chezmoi migration docs).
- HD adopt DAG (**CEL-761…**).
- Shared zig-qm-toolkit defects (**CEL-452…456**).
- Multi-repo platform gates that only *call* `zt` (**CEL-465** split; **CEL-750**, **CEL-592**).

---

## Local repo anchors (not Linear, but migration-relevant)

| Path | Notes |
|------|--------|
| `/Users/etretiakov/ghq/github.com/EugOT/z3store` | Canonical product repo (`zt`) |
| `docs/MIGRATION-ghq-to-gitstore.md` | Still cites **CEL-378** |
| `scripts/lib/{files,runtime}.ts`, `scripts/zig-*.zig` | Cite **CEL-456** toolkit defects (shared) |
| `workflows/gitstore-gh-compatible-dvc-gdrive.workflow.ts` | DVC/Drive workflow asset |
| `archive/2026.07/dirty-CEL-781-safe-adopt` | Frozen CEL-781 tip (do not merge wholesale) |

---

## Recommended next steps (for parent agent / TEO-1)

1. **Live re-query** Linear:  
   `list_issues query="z3store OR gitstore OR zt " team="CellKinetica" includeArchived=true limit=250`  
   plus `parentId=CEL-378`, `parentId=CEL-645`, `parentId=CEL-496` if any.  
2. Confirm statuses of CEL-616/645–650 after PR #31 merge (likely Done).  
3. Create TEO project **z3store / zt**; move **migrate-to-TEO** issues only (no bulk blind move).  
4. For **split** items (CEL-500, CEL-465): leave CEL issue, add TEO child for product slice or dual-link.  
5. Do **not** move HD, chezmoi, toolkit, or agent-platform issues solely because they mention `zt`.

---

## What was intentionally not done

- No Linear issue moves, status changes, comments, or closes.  
- No exhaustive workspace-wide issue crawl beyond z3store/gitstore/`zt`/Drive-sync/epic-adjacent evidence.  
- No claim of 100% completeness without a live Linear re-query (especially remaining CEL-378 children and any post–July 13 issues).
