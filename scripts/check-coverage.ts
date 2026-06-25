/**
 * Coverage threshold gate (G1). Reads coverage/summary.json (produced by
 * scripts/kcov-coverage.ts) and fails if percent_covered is below the
 * threshold. A `skipped` summary (non-Linux / no kcov) passes with a notice
 * so the gate never blocks on a platform that physically cannot measure.
 *
 * Threshold sources, in precedence order:
 *   1. --threshold <n> CLI arg
 *   2. COVERAGE_THRESHOLD env var
 *   3. DEFAULT_THRESHOLD below (start at 85, ratchet up as groups land)
 *
 * Usage:
 *   bun scripts/check-coverage.ts                 # default threshold
 *   bun scripts/check-coverage.ts --threshold 90
 */
import { resolve } from "node:path";
import type { CoverageSummary } from "./kcov-coverage.ts";
import { repoRoot } from "./lib/runtime.ts";

const DEFAULT_THRESHOLD = 85;

function resolveThreshold(): number {
	const idx = process.argv.indexOf("--threshold");
	if (idx >= 0 && process.argv[idx + 1]) {
		const n = Number(process.argv[idx + 1]);
		if (Number.isFinite(n)) return n;
	}
	const env = process.env.COVERAGE_THRESHOLD;
	if (env) {
		const n = Number(env);
		if (Number.isFinite(n)) return n;
	}
	return DEFAULT_THRESHOLD;
}

async function main(): Promise<number> {
	const summaryPath = resolve(repoRoot(), "coverage", "summary.json");
	let summary: CoverageSummary;
	try {
		summary = (await Bun.file(summaryPath).json()) as CoverageSummary;
	} catch {
		console.error(
			`check-coverage: no coverage/summary.json found (run scripts/kcov-coverage.ts first).`,
		);
		return 1;
	}

	if (summary.status === "skipped") {
		console.log(`check-coverage: SKIPPED — ${summary.reason}`);
		return 0;
	}

	const threshold = resolveThreshold();
	if (summary.percent_covered + 1e-9 < threshold) {
		console.error(
			`check-coverage: FAIL — ${summary.percent_covered}% < ${threshold}% threshold ` +
				`(${summary.lines_covered}/${summary.lines_total} lines).`,
		);
		return 1;
	}
	console.log(
		`check-coverage: OK — ${summary.percent_covered}% >= ${threshold}% ` +
			`(${summary.lines_covered}/${summary.lines_total} lines).`,
	);
	return 0;
}

if (import.meta.main) {
	process.exit(await main());
}
