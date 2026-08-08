# Handoff — Wave 1: product boundary & first milestone (HITL grilling; run WITH the operator)

You are resolving one wayfinder grilling ticket:
[Decide: z3store vNext product boundary and first user-visible milestone (TEO-12)](https://linear.app/cellkinetica/issue/TEO-12),
child of [Wayfinder map: z3store vNext (TEO-11)](https://linear.app/cellkinetica/issue/TEO-11)
on the Linear TEO team. The map is canonical on Linear; the GitHub twin (#36) is closed.

**First action:** claim the ticket via Linear MCP — `save_issue {id: "TEO-12",
assignee: "me", state: "In Progress"}`. This is a HITL ticket: invoke `/grilling` and
`/domain-modeling`, ask the operator **one question at a time**, and never answer a
question on their behalf. If the operator is absent, stop — this ticket cannot be
resolved AFK.

## What is already settled (do not re-litigate)

Destination confirmed verbatim (Rust-authoritative, crash-safe, reconstructable
workspace control plane with explicit boundaries). One map for now; the Opportunity
Store split trigger is decided HERE. `zt` is a control plane for reconstructable
workspaces, not a Git wrapper or live two-way folder sync; snapshots over
last-writer-wins; source history stays delegated to Git/JJ. Language policy: Python,
Ruby, Perl, Bash fully excluded; Julia/Rust/Odin-or-Zig/Nu per case. No K8s initially;
PG18+pgvector server baseline; DuckDB is a disposable lab. All wayfinding lives on
Linear (2026-08-01 operator decision).

## Evidence to load before the first question

TEO-12 body; TEO-11 Notes; `wayfinder/preview.pdf` (Opportunity Store concept: governed
exploration over candidate states; mutation/state/projection/witness/belief/archive-cell
entities; four-layer acceptance gate; reprojection-not-rollback);
`research/teo-10-semfs-frontier.md` (virtual-views-only rail, PIM failure canon);
[TEO-10](https://linear.app/cellkinetica/issue/TEO-10).

## Grilling agenda (breadth-first; one question at a time; push for falsifiable answers)

1. **Identity**: complete the sentences "z3store vNext IS …" and "z3store vNext IS NOT …"
   against the five candidate identities in the ticket. Force explicit rejection of each
   non-chosen identity.
2. **First user-visible milestone** — make the operator choose and defend ONE:
   (a) crash-safe atomic adopt/get transaction (kills the
   [GitHub issue #22](https://github.com/EugOT/z3store/issues/22) class), (b) clean-machine
   workspace reconstruction from declared state, (c) Rust kernel behind the existing CLI
   surface with differential parity, (d) snapshot/WIP durability, or (e) operator's own.
   Grill: who observes it, what demo proves it, what is explicitly absent from it.
3. **Opportunity Store boundary**: which of the PDF's entities (typed event log, archive
   cells, beliefs, projections) enter z3store's constitutional envelope vs stay in a
   separate product? What concrete condition triggers spawning the second map?
4. **Separable crates/services**: single binary, or kernel + adapters + workers from the
   start?
5. **Non-goals confirmation**: re-state TEO-11's Out-of-scope list; ask what is missing.

## Resolution contract

One resolution comment on TEO-12 (Linear `save_comment`): product statement, non-goals,
first milestone with acceptance demo, Opportunity Store boundary + split trigger,
crate/service shape. Set TEO-12 to Done; patch a one-line gist into TEO-11's "Decisions
so far"; graduate any fog this clears (likely: workspace/manifest semantics and
graph/vector boundary tickets become specifiable — create them as new TEO-11 children
with native blocking). Resolving TEO-12 natively unblocks
[local vs PostgreSQL authority split (TEO-19)](https://linear.app/cellkinetica/issue/TEO-19)
and part-unblocks [Rust migration shape (TEO-21)](https://linear.app/cellkinetica/issue/TEO-21).
This is the ONLY non-research ticket this session may resolve.
