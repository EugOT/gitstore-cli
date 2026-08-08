# Handoff — Wave 1: zt stdout BrokenPipe / Nu pipe hygiene (evidence + policy options)

You are working
[Policy: zt stdout BrokenPipe / Nu pipe hygiene (TEO-4)](https://linear.app/cellkinetica/issue/TEO-4),
child of [Wayfinder map: z3store recovery + TEO personal-space migration (TEO-1)](https://linear.app/cellkinetica/issue/TEO-1).
It is labeled grilling (HITL): you prepare the complete evidence and policy options; the
**operator picks**. If the operator is present, run the choice as one question and
resolve; if absent, post the options comment, leave the ticket In Progress with
"awaiting operator choice", and stop.

**First action:** claim via Linear MCP — `save_issue {id: "TEO-4", assignee: "me",
state: "In Progress"}`; stop if already assigned.

## Evidence to gather (read-only)

1. **Reproduce** with strictly read-only zt subcommands (`zt list`, `zt list -p
   --with-head --json`, `zt status`, `zt root`) piped into truncating consumers in BOTH
   shells: Nu (`zt list | first 3`, `| head` via external) and a POSIX shell if
   available via `sh -c 'zt list | head -1'`. Record: exit code, stderr output, whether a
   BrokenPipe error/panic surfaces, and whether output is partial. Never run mutating
   subcommands (`get/adopt/detach/rm/migrate/sync/hook`).
2. **Source check**: `src/main.zig` / writer plumbing — how stdout write errors propagate
   today (Zig 0.16 `std.Io.Writer.Error` path); whether SIGPIPE is touched anywhere.
3. **Prior art** (docs/web, cite): how mature CLIs treat EPIPE — the classic contract
   (die silently with 141 / treat EPIPE on stdout as success), Rust's default
   (`SIGPIPE` ignored → `ErrorKind::BrokenPipe`) and the `unix_sigpipe`/manual-reset
   idiom, Zig's behavior, and Nu's pipeline-termination semantics (does Nu close early on
   `first/take`?).

## Policy options to draft (the operator chooses one)

- **A — EPIPE-on-stdout is success**: catch BrokenPipe on stdout writes, flush what's
  possible, exit 0 silently (stderr still reports real errors). Matches `head`-pipeline
  expectations; recommended default candidate.
- **B — die-like-POSIX**: restore default SIGPIPE (where the runtime allows), exit 141;
  simplest, but exit codes surprise scripts that check them.
- **C — error**: treat as failure with diagnostic; strictest, noisiest in pipelines.
Note for each: impact on Nu scripts in `~/.config/nushell`/estate automation, on CI, and
what the vNext compatibility contract (TEO-18) should inherit.

## Resolution contract

One comment on TEO-4: reproduction table (command × shell × outcome), source findings,
prior-art citations, the three options with a recommendation. If the operator answers:
record the chosen policy in the same thread, set TEO-4 Done, patch a one-line gist into
TEO-1. Also add one cross-link comment line on
[the compatibility contract (TEO-18)](https://linear.app/cellkinetica/issue/TEO-18):
"stdout/EPIPE policy decided in TEO-4 — inherit in the preserved-surface table."
No repo mutations; evidence only.
