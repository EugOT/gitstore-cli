# Wayfinder reconciliation — whole-picture read of the three source artifacts

> **Supersession (2026-08-01).** The operator consolidated ALL wayfinding on Linear.
> The GitHub decision map and tickets (EugOT/z3store #35–#45) described below were
> recreated as Linear [TEO-11](https://linear.app/cellkinetica/issue/TEO-11) (map) with
> children TEO-12…TEO-21 (native sub-issues + native blocking), and the GitHub issues
> were closed with `[moved to Linear TEO-…]` pointers. The charter's "GitHub-native map"
> clause is superseded; everything else in this file stands. GitHub keeps only code
> artifacts (PRs; product bug #22). Wave 1 handoffs in `wayfinder/wave1/` are rewired to
> the Linear tickets. ID mapping: #35→TEO-11, #36→TEO-12, #37→TEO-13, #42→TEO-14,
> #43→TEO-15, #44→TEO-16, #45→TEO-17, #38→TEO-18, #40→TEO-19, #41→TEO-20, #39→TEO-21.

**Date:** 2026-07-31 (late evening pass, after the three files landed in `wayfinder/`)
**Sources reconciled:**
1. `z3store-wayfinder-handoff-2026-07-31.md` — the canonical `/wayfinder` charter (previously missing from disk; now recovered)
2. `z3store-strategic-development-handoff-20260731T1930+0200.md` — byte-identical (md5 `3bd88589…`) to the copy already processed earlier this evening; no re-read needed
3. `preview.pdf` — "Designing an Agents-Teams-Native Opportunity Store" (8 pp., read in full)

This file records how the three artifacts compose, where they conflict, and what changes
for work already done on the TEO plane. It is an index; decisions will live in the map's
tickets once the map exists.

---

## 1. What the wayfinder actually is (correction of earlier assumption)

Earlier today, before the wayfinder handoff resurfaced, "wayfinder" was reconciled as the
**Linear TEO-1 parent map**. The recovered handoff defines it differently and more
specifically:

- The wayfinder map is a **GitHub-issue decision map on github.com/EugOT/z3store**:
  one `wayfinder:map` issue + child decision issues (`wayfinder:research`,
  `wayfinder:prototype`, `wayfinder:grilling`, `wayfinder:task`) with native
  blocking/dependency wiring, per the Matt Pocock wayfinder skill.
- Its output is a **decision-complete z3store vNext specification and migration route**,
  not an implementation backlog and not a rewrite.
- Mode is **planning and decision discovery**. No PR merging, branch reconciliation, or
  implementation during charting.
- Fog-of-war rule: create a ticket only when the question is already precise.
- Destination must be validated via **HITL grilling + domain modeling before the map is
  created**; the user's answers must not be fabricated.

The Linear TEO-1 map (with its own `wayfinder:*` labels) and the GitHub decision map are
therefore **two planes**: TEO-1 governs the CEL→TEO migration/recapitulation estate work;
the GitHub map will govern the vNext product specification. How tightly they mirror is
itself a question for the user (posed in §6).

## 2. Source precedence, as mandated by the handoff

1. User's 2026-07-31 architecture update + Rust-native synthesis — **stack authority**.
2. Video Analysis Request.txt — product audit / reconstructable-workspace thesis
   (not present locally; referenced as `/mnt/data/...` from the originating session).
3. `preview.pdf` (Opportunity Store) — **concept authority only**: governed exploration
   over candidate states, transformations, probabilities, costs, risks, reversibility,
   provenance, utility; event sourcing + typed graphs + semiring provenance + PSDDs +
   MAP-Elites archives; acceptance as a four-layer governed pipeline (hard validity →
   task evidence → causal/interpretability evidence → archive logic); "undo" as
   reprojection, not rollback.
4. Novel Agentic Architecture.txt — traces/replay/eval concepts; Zig/Elixir stack superseded.
5. Caveman/Ponytail artifacts — background only.
6. Live repository state + upstream docs override every stale statement.

**Conflict resolution inside the PDF itself:** its stack recommendations (Python research
lane, Ray+Temporal, Tauri/TS desktop shell, RocksDB-first) are *not* automatically adopted —
the handoff's settled preferences say Rust authoritative core, **avoid Python in the core**,
Julia for statistical/graph/tensor analysis, JS/TS only at unavoidable host boundaries,
PostgreSQL 18 + pgvector as durable server authority where justified, DuckDB as disposable
analytical lab, local CAS first, no Kubernetes initially. The PDF's *concepts* survive; its
*stack* is filtered through the handoff.

## 3. Superseded conclusions (must not be revived without a new decision)

Zig as authoritative vNext core; Elixir/Phoenix as default backend; K8s/K3s initially;
MinIO; mandatory RustFS; DuckDB as sole durable authority; rigid human-designed permanent
semantic schema; the disconnected "memory triad."

### Impact on work done earlier today (TEO plane)

- **TEO-8 / TEO-9 / TEO-10 issue bodies and research artifacts used Zig-first phrasing**
  ("`zt wt metrics` in Zig", "gitrim model in Zig", "Zig scanner + usearch C API"). Under
  the recovered charter, implementation language for any vNext subsystem is governed by
  the Rust-authoritative direction and the Rust-migration decision area. The three
  objectives themselves are unchanged; their *implementation-language assumptions* are
  demoted to "candidate, pending the migration-shape decision." Linear issues annotated
  accordingly (2026-07-31 comments).
- **Mapping of the three objectives into the handoff's decision areas:**
  - TEO-8 (worktree observatory) → decision area 11 (evaluation/promotion gates) plus the
    observability substrate; also direct evidence input to area 2 (repository baseline:
    "no anonymous ahead/dirty worktree").
  - TEO-9 (twin-repo manifest publication) → decision areas 6 (workspace/manifest/snapshot
    semantics) and 7 (synchronization/materialization boundary). The private/public
    derivation is a *materialization policy*, and its append-only/redaction split matches
    the handoff's "no silent state loss" and snapshot-not-LWW doctrine.
  - TEO-10 (self-organizing store) → decision area 8 (graph/vector/evolving-schema
    boundary) and substantially the **Opportunity Store** product half. The PDF is its
    concept anchor; the earlier semfs-frontier sweep's "dueling convex optimization over
    view parameters, virtual views only" conclusion is consistent with the PDF's
    governed-acceptance and reprojection principles.
- **None of TEO-8/9/10 enters the first vNext milestone by default.** They wait behind the
  product-boundary and baseline decisions (fog-of-war).

## 4. Internal inconsistencies between the artifacts (flagged, to refresh live)

- **Open-PR count conflict:** the wayfinder handoff lists five open PRs (#18, #19, #20,
  #21, #29) as "observed 2026-07-31", while the same-day 19:30 strategic handoff states
  only two are open (#32 draft, #33 draft) and that the five-PR claim is stale (July 22
  vintage). These lists don't even overlap — the wayfinder handoff's repository-state
  section appears to predate the strategic handoff's live GitHub query. **Live refresh is
  mandatory before the baseline decision; treat the wayfinder handoff's PR archaeology
  list as the *superset to investigate* (merged/closed PRs still need archaeology for the
  baseline decision), not as open-PR truth.**
- **Default branch:** wayfinder handoff says `main` with release v0.3.0; strategic handoff
  works from the CEL-781 archive branch and TEO-7 (promote origin/dev vs catch main up)
  is still open. Both are consistent — `main` is default upstream, but which line becomes
  the vNext baseline is exactly decision area 2.
- **Issue #22** (clone-without-adopt atomicity) is named by both handoffs as first-class
  evidence for durable mutation/recovery semantics (area 5). Consistent.
- **Doc-truth problem:** root README/`doc/ARCHITECTURE.md` describe the zig-qm scaffold,
  not the product. Confirmed by direct inspection (this repo's CLAUDE.md context is the
  scaffold). The vNext architecture source of truth must not be `doc/ARCHITECTURE.md`.

## 5. Process gaps found

- No `/wayfinder` or `/setup-matt-pocock-skills` skill is installed in this harness
  (grilling, domain-modeling, research, prototype **are** installed). The map must
  therefore be created with direct GitHub tooling following the handoff's rules, or the
  wayfinder skill must be installed first (`bunx skills add mattpocock/skills` lane per
  agent-tooling policy). Flagged to the user.
- `wayfinder:*` labels do not exist yet on the GitHub repo (live check pending at write
  time; creation is authorized by handoff step 5 once tracker operations are confirmed).
- Observation-stamp / OpenViking durable write for this reconciliation: pending; the
  19:30 handoff notes `observation-stamp` was broken (retired chezmoi path). Record the
  blocker if it still fails.

## 6. Questions that block map creation (HITL — for the user, not to be fabricated)

1. **One map or two?** z3store vNext (workspace control plane) vs Opportunity Store
   (temporal memory / governed exploration): single map with an explicit boundary
   decision ticket, or two linked maps from day one?
2. **Destination wording:** confirm or amend the provisional destination (Rust-authoritative,
   crash-safe, reconstructable workspace control plane with explicit boundaries to
   Opportunity Store / PostgreSQL / DuckDB / Zig workers / artifact CAS / homelab deploy).
3. **Plane relationship:** GitHub decision map (handoff-canonical) vs Linear TEO plane —
   GitHub-only for vNext decisions with Linear for estate/migration work, or mirrored?
4. **TEO-8/9/10 placement:** keep as Linear research anchors feeding the map's research
   tickets, or re-home them as GitHub `wayfinder:research` children once the map exists?

## 7. Charting outcome (completed 2026-07-31, same session)

1. ✅ Read all three artifacts as a whole; this reconciliation file.
2. ✅ Live GitHub refresh (via GitHub MCP; local `gh` hangs in the sandbox): only PRs
   #32/#33 open (drafts), issue #22 sole open issue, no pre-existing wayfinder labels.
3. ✅ Annotated TEO-1/8/9/10 in Linear with the supersession + plane-split notes.
4. ✅ HITL grilling answered by operator: destination confirmed verbatim; **one map
   now, Opportunity-Store split deferred to the boundary ticket**; **GitHub = vNext
   decisions, Linear TEO = estate, cross-linked never mirrored**; TEO-8/9/10 stay as
   Linear evidence anchors.
5. ✅ Map created — [EugOT/z3store#35](https://github.com/EugOT/z3store/issues/35)
   (`wayfinder:map`) — with the four decisions recorded in "Decisions so far" and six
   frontier sub-issues wired natively:
   #36 product boundary (grilling) · #37 repository baseline (research) ·
   #38 compatibility contract (grilling) · #39 Rust migration shape ·
   #40 local/PG authority split · #41 durable mutation/recovery semantics.
   Labels `wayfinder:map|research|grilling` auto-created on first use;
   `wayfinder:prototype|task` will auto-create when first used.
6. ⏭ Next sessions: fire the parallel research tickets' work (repository archaeology;
   Rust journal/atomic-fs/SQLx/DuckDB/CAS options; PG18/19+pgvector+SQL/PGQ; Git/JJ
   worktree/op-log semantics; DuckPGQ maturity; RustFS readiness; Turso watch item)
   using Elicit/Context7/greptile/graphite/github_copilot; resolve at most one
   non-research ticket per session; charting stopped here per the charter — no
   implementation, no PR merges.
