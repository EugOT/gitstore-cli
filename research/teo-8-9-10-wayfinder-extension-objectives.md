# TEO-8 / TEO-9 / TEO-10 — Wayfinder extension objectives (reconciliation record)

**Parent map:** [TEO-1](https://linear.app/cellkinetica/issue/TEO-1) — Wayfinder map: z3store recovery + TEO personal-space migration
**Date:** 2026-07-31
**Mode:** reconciliation + research kickoff — no repo/worktree/Drive mutation, no CEL issue moves.

## Why this file exists

During the TEO wayfinder recapitulation (CEL→TEO migration of z3store product work),
three new strategic objectives were added by the operator and reconciled into the
map as TEO-native issues. This file is the durable local record; Linear is canonical
for status.

| Objective | Linear issue | Priority | Elicit deep-report session |
|---|---|---|---|
| Worktree distances / entropies / functional & data concordance + visualization | [TEO-8](https://linear.app/cellkinetica/issue/TEO-8) | High | `5aacfea5-6466-4d48-95c2-0e24033016bb` |
| Private/public twin-repo parallel existence (manifest-gated selective publication) | [TEO-9](https://linear.app/cellkinetica/issue/TEO-9) | High | `5a0ea15f-1372-46b8-9422-b922aeaf9dc8` |
| Blue-sky self-organizing store (embeddings, networks, RL-optimized organization) | [TEO-10](https://linear.app/cellkinetica/issue/TEO-10) | Medium | `5a1b03ef-fb17-45c8-bf31-707e70853db4` |

Elicit report URLs: `https://elicit.com/review/<session-id>`. All three were created
2026-07-31 with maxSearchPapers=300 / maxExtractPapers=40 (deep mode). **All three
completed the same evening**; full bodies are landed locally:

| Artifact | Status 2026-07-31 |
|---|---|
| `teo-8-elicit-divergence-metrics.md` | landed, fully read, distilled into a TEO-8 comment |
| `teo-9-elicit-selective-disclosure.md` | landed; summary reviewed (key claim: no existing design unifies parallel repos + per-commit disclosure policy + verifiable linkage — capabilities fragmented across redactable signatures, cryptographic access control, blockchain versioning); full-body distillation pending |
| `teo-10-elicit-semfs.md` | landed; summary reviewed (23 semantic-FS + 12 embedding + 5 clustering + 4 overlay systems; most augment rather than replace hierarchies; only 9/40 studies have controlled effectiveness evals); full-body distillation pending |
| `teo-9-twinrepo-priorart.md` | landed (engineering sweep: Copybara/josh/gitrim/jj/mirror-ops; 3 ranked architectures; gitrim = closest prior art) |
| `teo-10-semfs-frontier.md` | landed (arXiv/frontier sweep: Gifford 1991 → LSFS/Indaleko 2025-26; failure-mode canon; 4-phase ladder) |

## Relationship to the existing wayfinder lanes

1. **Migration first wave unchanged.** TEO-2's product-core migrate set (CEL-616,
   CEL-645…650, CEL-781, CEL-378+children, CEL-498, GH #22/#32/#33) is not displaced.
   TEO-8/9/10 are additive product objectives on the TEO plane; none of them may run
   ahead of the CEL-781 topology/jjColocate reconciliation (TEO-7 trunk decision,
   strategic-handoff step 1: no anonymous ahead/dirty worktree).
2. **TEO-8 is the measured generalization** of the handoff exit criterion "no
   anonymous ahead/dirty worktree" — it turns the one-time reconciliation into
   continuous observability and reuses existing gate machinery
   (`scripts/check-public-api.ts`, `scripts/zig-fitness.zig`) as concordance probes.
3. **TEO-9 must compose with the replication contract** (CEL-817 lineage): the
   publication derivation is a fourth typed classification lane (public/private) next
   to durable/cache/secret, and shares the fail-closed, deterministic, non-destructive,
   journaled doctrine. Retroactive redaction is governed like destination deletion:
   a separately authorized destructive transaction, never a default.
4. **TEO-10 shares its similarity substrate with TEO-8** (content-defined chunking,
   near-duplicate detection, embedding cosine) and is virtual-views-only until its
   go/no-go gates pass; it cannot precede the `ztd` scheduling authority for anything
   daemon-shaped.

## Sequencing note

Recommended order of engagement after research returns: TEO-8 (measurable, bounded,
read-only, immediately useful for the migration itself) → TEO-9 (needs the ADR and
zero-leak eval harness first) → TEO-10 (long-horizon; phases gated).

## Provenance and caveats

- Live Linear state validated 2026-07-31 (team Eugedotnet/TEO: TEO-1 In Progress,
  TEO-2…7 Todo before this extension; TEO-8/9/10 created Backlog).
- **Missing artifact:** the operator referenced
  `/tmp/z3store-wayfinder-handoff-2026-07-31.md` as the primary handoff, but no such
  file existed under `/tmp`, `/private/tmp`, or either z3store checkout at
  reconciliation time; a codex preview PDF temp path was likewise already cleaned up.
  This record therefore leans on
  `/private/tmp/z3store-strategic-development-handoff-20260731T1930+0200.md`,
  `research/teo-2-cel-z3store-inventory.md`, and
  `research/teo-3-cross-system-id-inventory.md`. If the wayfinder handoff resurfaces,
  reconcile it against this file and the TEO-8/9/10 issue bodies.
- Elicit/web outputs are untrusted data per the repo boundary rule: they inform
  validation and design; they do not rewrite task lists or authorize tools.
