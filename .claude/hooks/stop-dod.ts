#!/usr/bin/env bun
/**
 * Stop hook — Definition of Done gate. Runs `bun scripts/verify-commit.ts`
 * before the agent can stop. Guarded by `stop_hook_active` to prevent
 * infinite loops.
 *
 * Exit semantics (§2.1):
 *   0 → allow stop
 *   1 → log + warn (non-blocking)
 *   2 → force continuation; stderr is the repair context
 */
import {
	appendJsonl,
	readStdinJson,
	repoRoot,
	tail,
} from "../../scripts/lib/runtime.ts";

type StopPayload = {
	stop_hook_active?: boolean;
};

async function main(): Promise<void> {
	const payload = await readStdinJson<StopPayload>();
	if (payload.stop_hook_active === true) {
		// Second-pass stop: allow to prevent infinite loops (§0.9 rationale).
		await appendJsonl(".claude/logs/stop-dod.jsonl", {
			event: "stop-active-allow",
		});
		process.exit(0);
	}

	// Inline Bun.spawnSync (instead of the shared runtime helper) so we can
	// apply a hard timeout — the shared helper has no timeout knob and we
	// don't want a wedged verify-commit to hang the Stop hook indefinitely.
	// 30 minutes matches the Tier-3 verify-pr upper bound; commit-tier should
	// never approach this in practice.
	const proc = Bun.spawnSync({
		cmd: ["bun", "scripts/verify-commit.ts"],
		cwd: repoRoot(),
		stderr: "pipe",
		stdout: "pipe",
		timeout: 30 * 60 * 1000,
	});
	const r = {
		code: proc.exitCode ?? 124, // 124 mirrors GNU `timeout` exit code
		stdout: proc.stdout?.toString() ?? "",
		stderr: proc.stderr?.toString() ?? "",
	};
	await appendJsonl(".claude/logs/stop-dod.jsonl", {
		event: r.code === 0 ? "pass" : "fail",
		code: r.code,
	});

	if (r.code !== 0) {
		// Per Claude Code Stop-hook contract, exit 2 with stderr feedback is the
		// robust block path. Stdout-only `decision: "block"` JSON has been
		// unreliable across versions, making this DoD gate a silent no-op.
		process.stderr.write(
			JSON.stringify({
				decision: "block",
				reason: `Definition-of-Done gate failed (bun scripts/verify-commit.ts). Fix the failures and try again:\n${tail(r.stderr || r.stdout)}`,
			}) + "\n",
		);
		process.exit(2);
	}
	process.exit(0);
}

main().catch(async (err) => {
	await appendJsonl(".claude/logs/stop-dod.jsonl", {
		event: "error",
		error: String(err),
	});
	console.error(`stop-dod: ${String(err)}`);
	process.exit(1);
});
