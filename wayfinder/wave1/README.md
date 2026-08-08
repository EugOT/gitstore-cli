# Wave 1 — the COMPLETE wayfinder launch kit (one journey, Linear-only)

**How TEO-1 and TEO-11 cohere:** one journey, two legs, same team, same `wayfinder:*`
labels, same evidence corpus (`research/`, `wayfinder/`).
[TEO-1](https://linear.app/cellkinetica/issue/TEO-1) makes the **present** true —
estate ground truth, CEL→TEO history migration, identity cleanup, stale surfaces.
[TEO-11](https://linear.app/cellkinetica/issue/TEO-11) decides the **future** — the
z3store vNext specification. They meet at exactly two joints, so nothing is duplicated:
(1) **TEO-13 baseline archaeology** produces the facts that both the estate trunk
decision ([TEO-7](https://linear.app/cellkinetica/issue/TEO-7)) and the vNext
baseline/compatibility/durability tickets consume; (2) **TEO-8/9/10** hold completed
research evidence cited by vNext decision areas. A decision still lives in exactly one
ticket — that is the wayfinder index rule, not a synthetic split.

## Complete Wave 1 — eight independent parallel paths

| # | Path | Ticket(s) | Map leg | Mode | Handoff file |
|---|---|---|---|---|---|
| 1 | Product boundary & first milestone | [TEO-12](https://linear.app/cellkinetica/issue/TEO-12) | vNext | **HITL — operator** | `handoff-36-product-boundary-grilling.md` |
| 2 | Repository baseline archaeology (bridge: also feeds TEO-7) | [TEO-13](https://linear.app/cellkinetica/issue/TEO-13) | both | AFK | `handoff-37-repo-baseline-archaeology.md` |
| 3 | Rust building blocks | [TEO-14](https://linear.app/cellkinetica/issue/TEO-14) | vNext | AFK | `handoff-42-rust-building-blocks.md` |
| 4 | PostgreSQL 18/19 + offline authority patterns | [TEO-15](https://linear.app/cellkinetica/issue/TEO-15) | vNext | AFK | `handoff-43-postgres-authority-plane.md` |
| 5 | Git/JJ/Lore/DVC adapter fact base | [TEO-16](https://linear.app/cellkinetica/issue/TEO-16) | vNext | AFK | `handoff-44-gitjj-lore-dvc-semantics.md` |
| 6 | Data-plane maturity watch | [TEO-17](https://linear.app/cellkinetica/issue/TEO-17) | vNext | AFK | `handoff-45-data-plane-maturity-watch.md` |
| 7 | Estate inventory closure + TEO-5/TEO-6 decision briefs | [TEO-2](https://linear.app/cellkinetica/issue/TEO-2) + [TEO-3](https://linear.app/cellkinetica/issue/TEO-3) | estate | AFK | `handoff-teo2-3-estate-closure.md` |
| 8 | zt BrokenPipe / Nu pipe hygiene evidence + options | [TEO-4](https://linear.app/cellkinetica/issue/TEO-4) | estate | AFK-prep, operator picks | `handoff-teo4-pipe-hygiene.md` |

Independence: no two paths write the same artifact — each resolves only its own
ticket(s) plus clearly-scoped comments (path 7 briefs TEO-5/TEO-6; path 8 cross-links
TEO-18); repos/worktrees are read-only for every path.

## What is deliberately NOT in Wave 1 (blocked or waiting on Wave 1 output)

- Estate grillings [TEO-5](https://linear.app/cellkinetica/issue/TEO-5) (move vs
  recreate), [TEO-6](https://linear.app/cellkinetica/issue/TEO-6) (report-host
  deprecation), [TEO-7](https://linear.app/cellkinetica/issue/TEO-7) (trunk) — each
  becomes a fast operator decision once paths 7 and 2 deliver their briefs/facts.
- vNext Wave 2: [TEO-18](https://linear.app/cellkinetica/issue/TEO-18),
  [TEO-19](https://linear.app/cellkinetica/issue/TEO-19),
  [TEO-20](https://linear.app/cellkinetica/issue/TEO-20),
  [TEO-21](https://linear.app/cellkinetica/issue/TEO-21) — natively blocked in Linear.
- Executing any CEL→TEO issue moves (gated on the TEO-5 decision) and any repo/Drive
  mutation (gated on baseline + durability decisions).

## Launch mechanics

One fresh agent session per handoff file, pasted as the opening prompt — all are
self-contained. Paths 2–8 can start simultaneously right now; run path 1 (TEO-12)
yourself with the agent — it is the single biggest unlock (it opens TEO-19 and
part-opens TEO-21). Everywhere: claim = Linear `save_issue {id, assignee: "me",
state: "In Progress"}`; resolve = one `save_comment` + `state: "Done"` + one-line gist
into the owning map (TEO-1 or TEO-11); at most one non-research ticket resolves per
session; research tickets may resolve in parallel. File names keep their historical
numbering — Linear ticket bodies reference these exact paths.
