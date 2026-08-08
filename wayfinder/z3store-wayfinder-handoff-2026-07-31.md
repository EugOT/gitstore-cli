# Handoff — `/wayfinder` session for `EugOT/z3store` (`zt`) vNext

**Generated:** 2026-07-31  
**Next-session mode:** planning and decision discovery, not implementation  
**Repository and issue tracker:** <https://github.com/EugOT/z3store>  
**Canonical handoff path:** `/tmp/z3store-wayfinder-handoff-2026-07-31.md`

## Next-session invocation

Invoke `/wayfinder` with this handoff as context and the following focus:

> Chart the canonical GitHub-issue map for the upcoming development of `z3store`/`zt`. The map must resolve the product boundary, repository baseline, Rust migration, durable state/recovery model, workspace/snapshot semantics, data/analysis architecture, deployment boundary, and evaluation gates until the route to an implementation-ready vNext specification is clear. Do not implement the destination during charting.

If the Matt Pocock tracker operations are not configured for this repository, invoke `/setup-matt-pocock-skills` before creating the map.

---

## Purpose of this handoff

The next session should use `/wayfinder` to create a **shared map of decision tickets** on the repository’s GitHub issue tracker. It should not turn the existing research reports into a large pre-sliced implementation backlog and should not begin a rewrite.

The intended output of the wayfinding effort is a **decision-complete z3store vNext product and migration specification**, represented by:

1. one GitHub issue labelled `wayfinder:map`;
2. child decision issues labelled `wayfinder:research`, `wayfinder:prototype`, `wayfinder:grilling`, or `wayfinder:task`;
3. native blocking/dependency relationships that expose the frontier visually;
4. resolution comments holding each decision in exactly one place;
5. a map whose “Decisions so far” section contains only one-line linked gists;
6. no unresolved decision required before implementation begins.

The effort is planning by default. Repository edits, branch reconciliation, PR merging, schema implementation, language migration, and deployment are outside the charting session unless a narrowly scoped task is required solely to unblock a decision.

---

## Provisional destination to validate first

The next agent must validate or refine this through `/grilling` and `/domain-modeling` before creating the map:

> **A decision-complete, implementation-ready vNext specification and migration route for `z3store`/`zt`: preserve its reliable Git/JJ metadata-separation and workspace-management behavior while evolving it into a Rust-authoritative, crash-safe, reconstructable developer-workspace control plane, with explicit boundaries to the longer-horizon Opportunity Store, PostgreSQL/pgvector temporal memory, DuckDB graph/vector experimentation, Zig mutation workers, artifact storage, and simple homelab deployment.**

The destination is deliberately a **specification and resolved route**, not the completed rewrite.

A likely early decision is whether this is one map or two linked maps:

- **z3store vNext:** developer-workspace control plane and migration from the existing Zig CLI;
- **Opportunity Store:** active temporal memory, evolving schemas, graph/vector learning, and recursive compression–prediction–control.

Do not silently collapse the products. The current preference is that z3store becomes a strong substrate and possible integration point, not that every Opportunity Store research concern enters its first milestone.

---

## Source precedence and supersession

The source material contains several iterations that conflict. Use this precedence order:

1. **The user’s 2026-07-31 architecture update and the immediately following Rust-native synthesis** are authoritative for current stack direction.
2. **`/mnt/data/Video Analysis Request.txt`** is authoritative background for the current `zt` product audit, reconstructable-workspace thesis, safety priorities, and staged roadmap.
3. **`/mnt/data/Designing an Agents-Teams-Native Opportunity Store.pdf`** is authoritative for the fundamental Opportunity Store concept: governed exploration over candidate states, transformations, probabilities, costs, risks, reversibility, provenance, and utility.
4. **`/mnt/data/Novel Agentic Architecture.txt`** remains useful for prompt-to-artifact traces, replay semantics, provenance, evals, and the compiler-like model, but its Zig/Elixir-first stack is superseded.
5. **Caveman/Ponytail artifacts** are background for compression–prediction–control, traceability, eval gates, and compatibility-boundary discipline. Their shared-Zig-core conclusions are not the z3store architecture.
6. Current live repository state and official upstream documentation override stale statements in any report.

### Superseded conclusions that must not be revived without a new decision

- Zig is **not** the authoritative core language for vNext. Rust is the strong current choice.
- Elixir/Phoenix is not automatically the primary orchestration/backend stack.
- Kubernetes/K3s is not an initial requirement.
- MinIO is not a default dependency.
- RustFS is not mandatory merely because the project uses Rust.
- DuckDB is not the sole durable authority merely because graph and vector extensions exist.
- A rigid human-designed semantic memory schema is not acceptable as the permanent ontology.
- The old “memory triad” must not be implemented as three disconnected services.

---

## Settled decisions and strong standing preferences

Treat these as map Notes/constraints unless the user explicitly reopens them.

### Product thesis

- `zt` should become a **control plane for reconstructable developer workspaces**, not merely another Git wrapper or live two-way folder synchronizer.
- “Same folder everywhere” means the same logical namespace and declared state, not uncontrolled replication of identical mutable bytes.
- Source history remains delegated to Git/JJ where appropriate; `zt` owns composition, topology, materialization, workspace identity, lifecycle, recovery, and policy.
- Work in progress should move toward immutable/versioned snapshots rather than last-writer-wins synchronization.
- Every meaningful source state must be durably identifiable and recoverable after conflict, crash, power loss, machine replacement, or concurrent agent work—or explicitly reported unavailable.

### Language and runtime

- **Rust** is the intended authoritative implementation language for the long-running core/control kernel.
- Existing Zig functionality must not be discarded casually. Migration requires behavior capture, differential tests, and an explicit compatibility route.
- **Zig** may remain as a sandboxed, bounded mutation/search worker where `comptime` demonstrates measurable advantage over Rust alternatives.
- **Julia** remains preferred for statistical, probabilistic, graph, tensor, and manifold analysis.
- Avoid Python in the core. Keep JavaScript/TypeScript only at unavoidable host/plugin boundaries.

### Data authority

- **PostgreSQL 18 + pgvector** is the safe current production baseline for durable temporal, transactional, policy, provenance, evaluation, and vector state where a server authority is justified.
- PostgreSQL 19 is currently Beta 2 and planned for September 2026. It is a canary/research target, not a production dependency. Its SQL/PGQ property graphs and `FOR PORTION OF` temporal operations are relevant.
- The wayfinder must resolve the authority split between:
  - local/offline `zt` state needed for a portable CLI and crash recovery;
  - PostgreSQL-backed shared/control-plane state;
  - rebuildable analytical projections.
- **DuckDB** is the preferred analytical/epistemic laboratory: disposable and reproducible from canonical evidence. It may host graph/vector/trace experiments, but it must not accidentally become the only authority.
- DuckPGQ remains an ongoing research/community extension. Vector-index persistence and extension-version compatibility must be evaluated rather than assumed.
- Turso’s newly announced PostgreSQL-compatible Rust frontend is strategically interesting but too early to be a dependency. Treat it as a watch/research item.

### Memory and schema model

- Memory is active: it predicts and controls future behavior by shaping context, priors, retrieval, compression resolution, and mutation—not merely by storing observations.
- The inner loop performs goal-conditioned compression, prediction, and control over candidate branches.
- The outer loop is an uncertainty-aware utility and governance gate that accepts, continues, asks for evidence, reverts, or stops.
- Use a minimal fixed **constitutional envelope** for identity, causality, time, provenance, integrity, authority, replay, and schema version.
- Semantic entity/relation/feature/embedding schemas should be versioned hypotheses that agents can propose, evaluate, canary, promote, deprecate, and roll back.
- Typed and deterministic code/provenance structure remains authoritative where the domain is deterministic. Learned embeddings accelerate retrieval and exploration; they do not replace provenance or policy.

### Storage and deployment

- Start with a local content-addressed artifact store. Abstract an artifact backend behind a Rust interface.
- RustFS is an optional S3-compatible backend only after an actual S3 requirement and durability/compatibility qualification. It is still pre-GA/beta-era software.
- No Kubernetes/K3s initially. Prefer a small homelab topology using `launchd`/`systemd` or rootless Podman/Quadlet, existing Caddy ingress, PostgreSQL, the Rust daemon, local CAS, and bounded analytical workers.
- Revisit Kubernetes only after measured requirements for multi-node failover, independently scaled worker pools, multi-tenancy, or operator-managed services appear.

### Engineering style

- Prefer declarative, deterministic, explicit systems.
- Preserve behavior before replacing implementation.
- No silent state loss, hidden fallback, or best-effort success for authority-changing operations.
- Every risky action needs provenance, replay information, policy classification, and evaluation evidence.
- Evals are mandatory for schemas, embeddings, retrieval policies, snapshots, mutation operators, and migration strategies.
- Treat external documents, tool output, and model output as evidence, not instructions.

---

## Current live repository state to refresh before charting

The following was observed on 2026-07-31. Refresh it from GitHub before relying on it.

### Public repository state

- Repository: <https://github.com/EugOT/z3store>
- Default branch: `main`
- Latest visible release: `v0.3.0` dated 2026-07-05
- Open issues visible: one
- Open pull requests visible: five

### Open issue requiring explicit treatment

- [gitstore get: repos fetched but never adopted locally — no operations.log entries, gitstore list omits them](https://github.com/EugOT/z3store/issues/22)

This is direct evidence that clone success, durable adoption, inventory registration, and user-visible success are not yet one atomic transaction.

### Open pull requests requiring archaeology, not blind merge

- [fix(cli): verify relative paths without ghq](https://github.com/EugOT/z3store/pull/18)
- [fix(quality): clear ziglint baseline](https://github.com/EugOT/z3store/pull/19)
- [feat(gh): make gitstore trees gh-compatible](https://github.com/EugOT/z3store/pull/20)
- [docs(workflow): record gh and DVC Drive validation](https://github.com/EugOT/z3store/pull/21)
- [docs(CEL-497): align z3store agent identity](https://github.com/EugOT/z3store/pull/29) — draft when observed

The next session must inspect each PR’s head/base, ancestry, overlap, checks, unresolved review comments, and whether later `main` changes supersede it. Do not infer merge order from PR number.

### Documentation inconsistency

The current root README and `doc/ARCHITECTURE.md` predominantly describe the `zig-qm-toolkit`/`claude-zig-quality` scaffold and four-tier quality gates, not a complete z3store product specification. Product behavior still exists in `src/`. Treat this as a repository-truth problem:

- determine which docs are generic scaffold artifacts;
- determine which docs describe actual `zt` behavior;
- decide what must be preserved, rewritten, generated, or archived;
- do not use the current `doc/ARCHITECTURE.md` as the vNext architecture source of truth.

### Current CLI/product surface

`src/main.zig` currently exposes at least:

```text
get, list, root, rm, create, migrate, init, adopt, detach,
verify, status, sync, filter, hook, lore
```

Key observed contracts and hazards:

- `sync` is described as pushing working trees to an rclone remote; it is not a bidirectional, conflict-aware workspace protocol.
- Real `migrate` mode is intentionally unimplemented pending a WAL/replay design; only dry-run exists.
- Existing adopted repositories may contain absolute `gitdir:` pointers into the legacy `~/.local/share/gitstore`; migration must not strand them.
- Lore workspace metadata is treated as non-relocatable and read-only by `zt`.
- Git/JJ linked-worktree behavior is a current compatibility concern.
- `src/z3store.zig` states that operation-log writes become best-effort observability after a destructive swap begins. This is not a durable transaction journal.

Relevant source links:

- <https://raw.githubusercontent.com/EugOT/z3store/main/src/main.zig>
- <https://raw.githubusercontent.com/EugOT/z3store/main/src/z3store.zig>
- <https://raw.githubusercontent.com/EugOT/z3store/main/src/log.zig>
- <https://raw.githubusercontent.com/EugOT/z3store/main/src/cache.zig>
- <https://raw.githubusercontent.com/EugOT/z3store/main/src/clone.zig>
- <https://raw.githubusercontent.com/EugOT/z3store/main/src/list.zig>
- <https://raw.githubusercontent.com/EugOT/z3store/main/src/lore.zig>
- <https://raw.githubusercontent.com/EugOT/z3store/main/docs/MIGRATION-ghq-to-gitstore.md>

---

## Decisions the wayfinder must expose

These are **candidate decision areas**, not a command to pre-create all tickets. Apply the fog-of-war rule: create a ticket only when the question is already precise.

### 1. Product boundary

Resolve what `z3store vNext` is and is not:

- workspace control plane;
- local repository manager;
- shared memory/control service;
- Opportunity Store substrate;
- or a composition of separable products/crates/services.

The outcome must state the first user-visible milestone and the boundary to later Opportunity Store research.

### 2. Authoritative repository baseline

Determine which current code, open PRs, releases, docs, and branch histories form the baseline to preserve. Produce an explicit reconciliation decision before any migration plan.

### 3. Rust migration strategy

Rust is the target authority language; the open decision is **how**:

- incremental strangler around the Zig CLI;
- shared protocol with Rust daemon and retained Zig client;
- command-by-command replacement;
- new Rust core with compatibility wrapper;
- or another evidence-backed route.

The decision must define golden behavior capture, differential tests, fallback/rollback, and when the Zig binary can cease to be authoritative.

### 4. Local/server authority split

Resolve how a local-first CLI remains usable and recoverable when PostgreSQL is unavailable while still gaining PostgreSQL/pgvector temporal and shared-memory capabilities.

Questions include:

- Which state is local constitutional truth?
- Which state is PostgreSQL authority?
- What is replicated, projected, cached, or reconstructed?
- Can `zt` perform core repository operations offline?
- What consistency and conflict model applies across machines?

### 5. Durable mutation and recovery semantics

Define the transaction model for `get`, `adopt`, `detach`, `rm`, `migrate`, snapshot application, and inventory updates:

- write-ahead journal;
- locks and leases;
- staged paths;
- commit points;
- fsync/durability requirements;
- crash recovery;
- idempotent replay;
- operator-visible repair/doctor commands;
- interaction with PostgreSQL transactions, if any.

Issue #22 and the unimplemented real migration are primary evidence.

### 6. Workspace, manifest, and snapshot semantics

Define:

- workspace identity;
- machine/agent identity;
- component topology;
- logical mounts;
- Git/JJ/Lore/DVC adapters;
- revision and WIP representation;
- immutable snapshot structure;
- conflict semantics;
- platform overlays;
- secret/environment references;
- materialization policy;
- retention and garbage collection.

### 7. Synchronization and materialization boundary

Resolve the transition from the current one-way `rclone sync` command toward explicit operations such as mirror, snapshot, hydrate, pin, evict, and offline check.

A new filesystem, new VCS, and raw two-way live synchronization should remain out of the first milestone unless research proves they are necessary.

### 8. Graph, vector, and evolving-schema boundary

Resolve what belongs in z3store itself versus a separate Opportunity Store service:

- deterministic provenance/code/workspace graphs;
- semantic hypothesis graphs;
- pgvector embeddings;
- DuckDB/DuckPGQ analytical projections;
- input/output/transition embedding spaces;
- agent-generated schema lifecycle;
- retrieval-policy evaluation.

### 9. Artifact storage

Choose the first durable artifact model and qualification path:

- local BLAKE3/SHA content-addressed store;
- PostgreSQL metadata;
- optional RustFS/S3 adapter;
- replication and backup;
- integrity verification;
- lifecycle and garbage collection.

### 10. Homelab deployment

Define the smallest reliable topology for the simplified `home-cordlab` environment:

- process supervision;
- service boundaries;
- ingress;
- authentication;
- backup/restore;
- observability;
- upgrades and rollback;
- no Kubernetes unless a requirement proves otherwise.

### 11. Evaluation and promotion gates

Define measurable acceptance criteria for:

- behavioral parity during Rust migration;
- crash recovery;
- clean-machine reconstruction;
- idempotence;
- offline operation;
- divergent edits;
- secret containment;
- agent isolation;
- schema and embedding promotion;
- graph/retrieval usefulness;
- cost, latency, storage growth, and maintenance burden.

---

## Candidate first frontier

The first charting session should probably expose only the questions needed to make subsequent tickets precise. A plausible frontier—subject to grilling—is:

1. **Define the z3store vNext destination and product boundary** — HITL grilling/domain modeling before map creation.
2. **Establish the authoritative repository baseline** — AFK research plus repository archaeology.
3. **Define the compatibility contract that vNext must preserve** — HITL grilling informed by baseline research.
4. **Choose the Rust migration shape** — research/grilling after the baseline and compatibility contract.
5. **Define the local/server authority split** — research/grilling; likely blocks the data and deployment maps.
6. **Define durable mutation and recovery semantics** — research/prototype after current failure modes are inventoried.

Do not automatically create later tickets until these decisions clear the fog.

### Research tickets worth firing in parallel once the map exists

- Current repository/PR/branch archaeology and executable behavior inventory.
- Rust implementation options for transaction journals, filesystem-safe atomic operations, SQLx/PostgreSQL, DuckDB/Arrow/Parquet, and content-addressed storage.
- PostgreSQL 18/19, pgvector, temporal data, and SQL/PGQ compatibility.
- Git/JJ worktree, operation-log, snapshot, and recovery semantics; Lore and DVC adapter constraints.
- DuckDB graph/vector extension maturity and reproducibility boundaries.
- RustFS readiness and S3 compatibility/durability qualification.
- Turso PostgreSQL-in-Rust maturity and whether it should remain a watch item.

Research findings belong in resolution comments or linked throwaway research branches/assets, not pasted into the map body.

---

## Provisional map seed

This is a seed for the wayfinder, not a canonical issue body until the destination is validated.

```markdown
## Destination

An implementation-ready vNext specification and migration route for z3store/zt that preserves its reliable Git/JJ workspace behavior while defining a Rust-authoritative, crash-safe, reconstructable developer-workspace control plane and explicit integration boundaries to Opportunity Store memory, PostgreSQL/pgvector, DuckDB analytics, Zig mutation workers, artifact storage, and homelab deployment.

## Notes

- Planning only by default; no rewrite or PR merge during wayfinding.
- Use `/grilling` and `/domain-modeling` to settle product boundaries.
- Use `/research` subagents for live repository state and version-sensitive technology questions.
- Use `/prototype` only to raise decision fidelity, such as rough manifest, transaction, CLI, or topology shapes.
- Rust is the intended authority language; migration shape remains to decide.
- Preserve existing behavior before replacement; issue #22 and crash recovery are first-class evidence.
- PostgreSQL 18 is production-safe; PostgreSQL 19 remains a canary until GA and compatibility gates pass.
- DuckDB projections are rebuildable experiments, not constitutional authority.
- Start with local CAS; RustFS is optional after qualification.
- No Kubernetes initially.
- Refer to issues by linked title, never bare issue number, in human-facing text.

## Decisions so far

<!-- Empty at map creation. Pre-existing user constraints remain in Notes; ticket resolutions are appended here one line at a time. -->

## Not yet specified

- Exact product split between z3store vNext and Opportunity Store.
- Final local/server state authority and offline model.
- Manifest/snapshot/component schema after the product boundary is fixed.
- Dynamic schema and embedding lifecycle after the authority model is fixed.
- Materialization and synchronization roadmap after snapshot semantics are fixed.
- Deployment topology after service boundaries are fixed.

## Out of scope

- Implementing the rewrite during the charting session.
- A new general-purpose filesystem in the first milestone.
- A new version-control system in the first milestone.
- Raw last-writer-wins synchronization of active worktrees.
- Mandatory RustFS/S3 infrastructure before a requirement exists.
- Kubernetes-first deployment.
- Production use of PostgreSQL 19 beta.
- Fully autonomous self-promotion of schemas, models, or core runtime changes.
```

---

## Wayfinder operating rules for the next agent

1. Read the map at low resolution; open ticket bodies only as needed.
2. Refer to every issue by its linked title in narration and in “Decisions so far.”
3. Keep the map as an index. A decision lives in exactly one ticket resolution comment.
4. Claim a ticket by assignment before working it.
5. Use native GitHub sub-issues/child relationships and blocking dependencies where available.
6. Create tickets first, then wire dependencies in a second pass.
7. Never resolve more than one non-research ticket per session.
8. Research tickets may run in parallel on isolated throwaway branches/assets.
9. Do not fabricate the user’s answer in HITL grilling or prototype tickets.
10. Keep uncertain future areas in “Not yet specified” until a precise question can be stated.
11. Close and move mis-scoped work to “Out of scope” rather than pretending it was a route decision.
12. Expect concurrent sessions and refresh issue/assignment state before claiming work.

Required labels if absent:

```text
wayfinder:map
wayfinder:research
wayfinder:prototype
wayfinder:grilling
wayfinder:task
```

---

## Definition of done for the entire wayfinding effort

The map is complete only when a fresh implementation agent can proceed without making an unrecorded architectural decision about:

- product boundary and first milestone;
- repository/branch/PR baseline;
- preserved compatibility surface;
- Rust migration and Zig residual boundary;
- local versus PostgreSQL authority;
- durable transaction/recovery semantics;
- workspace, component, manifest, snapshot, and identity model;
- Git/JJ/Lore/DVC adapter contracts;
- mirror/snapshot/materialization semantics;
- graph/vector/schema boundaries;
- artifact storage and backup;
- homelab deployment;
- evaluation, promotion, rollback, security, and provenance gates;
- staged roadmap and explicit out-of-scope research.

The final route should point to specifications, ADRs, prototypes, research assets, and resolved issue comments rather than duplicating their contents in the map.

---

## First actions for the next session

1. Read this handoff and invoke `/wayfinder`.
2. Refresh repository HEAD, tags, branches, open PRs, issue #22, checks, and review state.
3. Inspect `README.md`, `doc/ARCHITECTURE.md`, `docs/`, `src/main.zig`, `src/z3store.zig`, `src/log.zig`, and relevant tests to separate scaffold from product truth.
4. Run `/grilling` and `/domain-modeling` to validate the destination and decide whether one or two maps are required.
5. Confirm GitHub tracker operations and create missing wayfinder labels if authorized.
6. Create the map and only the first precise frontier tickets; wire dependencies after issue creation.
7. Fire parallel `/research` subagents for repository archaeology and version-sensitive architecture questions.
8. Stop after charting. Do not implement or merge code in the same session.

---

## Suggested skills

- **`/wayfinder`** — mandatory; create and evolve the decision map.
- **`/grilling`** — mandatory for destination and major HITL architectural choices.
- **`/domain-modeling`** — mandatory alongside grilling to stabilize vocabulary, boundaries, invariants, and entities.
- **`/research`** — use as AFK subagents for repository archaeology and version-sensitive technology facts.
- **`/prototype`** — use only when a rough manifest, transaction protocol, CLI, schema, or topology is needed to make a decision concrete.
- **`/setup-matt-pocock-skills`** — invoke if GitHub tracker-specific wayfinding operations are not configured.
- **`/handoff`** — invoke at the end of each substantial wayfinder session so another agent can continue without rereading all prior work.

Also read and obey repository-local `AGENTS.md`, `CLAUDE.md`, skills, and quality gates before any later implementation session. Verify whether those files describe the product or merely the scaffold.

---

## Source artifacts and references

### Local artifacts

- `/mnt/data/Video Analysis Request.txt` — z3store static audit, reconstructable-workspace architecture, roadmap, and completion gates.
- `/mnt/data/Designing an Agents-Teams-Native Opportunity Store.pdf` — fundamental Opportunity Store concept and formal foundations.
- `/mnt/data/Novel Agentic Architecture.txt` — trace compiler, replay, provenance, eval, and graph/modeling concepts; stack sections partly superseded.
- `/mnt/data/System architecture deep dive.txt` — Caveman/Ponytail triad and control/eval background; not the z3store stack authority.
- `/mnt/data/Assisted Coding Session Analysis for EugOT_caveman and EugOT_ponytail.pdf` — verification, compatibility-island, and independent-gate lessons.

### Skills

- Handoff: <https://raw.githubusercontent.com/mattpocock/skills/refs/heads/main/skills/productivity/handoff/SKILL.md>
- Wayfinder: <https://raw.githubusercontent.com/mattpocock/skills/refs/heads/main/skills/engineering/wayfinder/SKILL.md>

### Current primary technical references

- PostgreSQL 19 Beta 2: <https://www.postgresql.org/about/news/postgresql-19-beta-2-released-3350/>
- PostgreSQL roadmap: <https://www.postgresql.org/developer/roadmap/>
- PostgreSQL 19 property graphs: <https://www.postgresql.org/docs/19/ddl-property-graphs.html>
- PostgreSQL 19 temporal updates/deletes: <https://www.postgresql.org/docs/19/dml-application-time-update-delete.html>
- Turso PostgreSQL-in-Rust announcement: <https://turso.tech/blog/a-new-modern-version-of-postgres-in-rust>
- DuckPGQ extension: <https://duckdb.org/community_extensions/extensions/duckpgq>
- RustFS current project/download state: <https://rustfs.com/download/>

---

## Security and redaction

No credentials, tokens, private endpoints, personal identifiers, or secret values are included in this handoff. The next session must keep secrets out of GitHub issue bodies, research branches, logs, manifests, and generated artifacts. Refer to secret locations and providers, never secret values.
