# Release 2026.07 final-stage — z3store (`zt`)

Final-stage **reference** freeze before a bare-minimum restart on `dev`.

## Release tip (`release/2026.07-final-stage`)

Base: `origin/dev` @ freeze (includes converge PR #31).

Additive on this branch: this manifest only. Implementation WIP lives on archive refs.

Tag: `v2026.07-final-stage` (annotated).

## Archive-only refs (preserve; do not merge wholesale)

| Ref | Purpose |
|---|---|
| `archive/2026.07/origin-dev-at-freeze` | `origin/dev` tip at freeze |
| `archive/2026.07/dirty-CEL-781-safe-adopt` / `…-freeze` | Local CEL-781 safe-adopt + `verify.yml` WIP (`eb92bcf`) |
| `archive/2026.07/pr-33-stores-schema` | Inbox draft PR #33 tip |
| `archive/2026.07/pr-32-cursor-cloud-env` | Inbox draft PR #32 tip |

## Tooling

- `zt list -p --with-head z3store`
- `wt switch --create release/2026.07-final-stage --base origin/dev`
- `gt track --parent dev` — never squash-merge

## Fresh-start policy

Rebuild `zt` from bare minimum on `dev`. Reintroduce from archive tips only when needed.
