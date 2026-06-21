/**
 * kcov coverage harness for gitstore-cli (G1 of the test-coverage plan).
 *
 * Builds the three test binaries (test-unit, test-lib, test-integration) in
 * Debug, runs each under kcov, merges the runs, and writes a normalized
 * `coverage/summary.json` with { percent_covered, lines_covered, lines_total,
 * per_binary }. `scripts/check-coverage.ts` enforces a threshold against it.
 *
 * Darwin degradation (mirrors the fuzz gate in lib/zig.ts): kcov is Linux-only
 * (ptrace; macOS SIP blocks it, no arm64 build). On non-Linux this exits 0
 * with a skip notice and writes a `skipped` summary so downstream tooling can
 * distinguish "not measured" from "0%". Set KCOV_FORCE=1 to attempt anyway.
 *
 * Usage:
 *   bun scripts/kcov-coverage.ts            # build + measure, write summary
 *   bun scripts/kcov-coverage.ts --print    # also print the human summary
 */
import { mkdirSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { repoRoot, spawnSync, tail } from "./lib/runtime.ts";
import { zig } from "./lib/zig.ts";

const TEST_STEPS = ["test-unit", "test-lib", "test-integration"] as const;

// Paths excluded from coverage accounting: toolchain std, system dirs, the
// test files themselves, and the re-export surface (no logic to cover).
const EXCLUDE_PATTERNS = [
	"/nix",
	"/usr",
	"/opt/homebrew",
	`${process.env.HOME ?? ""}/.cache`,
	"src/tests.zig",
	"src/lib.zig",
].filter((p) => p.length > 0);

export type CoverageSummary =
	| {
			status: "measured";
			percent_covered: number;
			lines_covered: number;
			lines_total: number;
			per_binary: Record<
				string,
				{ percent: number; covered: number; total: number }
			>;
	  }
	| { status: "skipped"; reason: string };

function isLinux(): boolean {
	return process.platform === "linux";
}

function kcovAvailable(): boolean {
	return Bun.which("kcov") !== null;
}

/**
 * Build a test step in Debug and return the path to its emitted test binary.
 * Zig writes test binaries under `.zig-cache/o/<hash>/test`; we locate the
 * freshest one produced for the step via `--verbose` argv echo, falling back
 * to a cache scan. Returns null if the build fails.
 */
function buildTestBinary(step: string): { binary: string | null; log: string } {
	// `-femit-bin` is implied; we ask zig build to print the compile so we can
	// recover the artifact path deterministically rather than guessing the hash.
	const r = zig(["build", step, "-Doptimize=Debug", "--verbose"]);
	const log = `${r.stdout}\n${r.stderr}`;
	if (r.code !== 0) return { binary: null, log };
	// The test binary path appears in the verbose output as an absolute path
	// ending in `/test` (the run step invokes it). Grab the last such match.
	const matches = [...log.matchAll(/(\S*\.zig-cache\/o\/[0-9a-f]+\/test)\b/g)];
	if (matches.length > 0) {
		return { binary: matches[matches.length - 1][1], log };
	}
	// Fallback: scan the cache for the newest `test` artifact.
	const found = newestTestArtifact();
	return { binary: found, log };
}

function newestTestArtifact(): string | null {
	const oDir = resolve(repoRoot(), ".zig-cache", "o");
	try {
		let best: { path: string; mtime: number } | null = null;
		for (const hash of readdirSync(oDir)) {
			const candidate = resolve(oDir, hash, "test");
			try {
				const f = Bun.file(candidate);
				// lastModified is ms epoch; 0 if missing.
				const st = (f as unknown as { lastModified: number }).lastModified;
				if (st && (best === null || st > best.mtime)) {
					best = { path: candidate, mtime: st };
				}
			} catch {
				// not present for this hash
			}
		}
		return best?.path ?? null;
	} catch {
		return null;
	}
}

function runKcov(
	outDir: string,
	binary: string,
): { code: number; log: string } {
	const args = [
		`--exclude-pattern=${EXCLUDE_PATTERNS.join(",")}`,
		"--timeout=120000",
		outDir,
		binary,
	];
	const r = spawnSync(["kcov", ...args]);
	return { code: r.code ?? 1, log: `${r.stdout}\n${r.stderr}` };
}

/**
 * Parse kcov's `<outDir>/<binary>/coverage.json` (the per-run report). kcov
 * writes a top-level object with a `percent_covered` string and a `files`
 * array; we sum covered/total lines across files for a stable number.
 */
async function readKcovRun(
	outDir: string,
): Promise<{ covered: number; total: number; percent: number } | null> {
	// kcov nests the report one directory deep (named after the binary). Scan.
	let dir: string;
	try {
		const entries = readdirSync(outDir);
		const sub = entries.find((e) => e !== "kcov-merged");
		dir = sub ? resolve(outDir, sub) : outDir;
	} catch {
		return null;
	}
	const jsonPath = resolve(dir, "coverage.json");
	try {
		const data = (await Bun.file(jsonPath).json()) as {
			files?: Array<{ covered_lines?: number; total_lines?: number }>;
			percent_covered?: string;
		};
		let covered = 0;
		let total = 0;
		for (const f of data.files ?? []) {
			covered += Number(f.covered_lines ?? 0);
			total += Number(f.total_lines ?? 0);
		}
		const percent = total > 0 ? (covered / total) * 100 : 0;
		return { covered, total, percent };
	} catch {
		return null;
	}
}

export async function measure(): Promise<CoverageSummary> {
	if (!isLinux() && process.env.KCOV_FORCE !== "1") {
		return {
			status: "skipped",
			reason: `kcov is Linux-only; ${process.platform} cannot run it (ptrace/SIP). Use 'zig build test' + mutation matrix locally.`,
		};
	}
	if (!kcovAvailable()) {
		return {
			status: "skipped",
			reason: "kcov not found on PATH (install via apt/nix on CI-Linux).",
		};
	}

	const covRoot = resolve(repoRoot(), "coverage");
	rmSync(covRoot, { recursive: true, force: true });
	mkdirSync(covRoot, { recursive: true });

	const perBinary: Record<
		string,
		{ percent: number; covered: number; total: number }
	> = {};
	let totalCovered = 0;
	let totalLines = 0;

	for (const step of TEST_STEPS) {
		const { binary, log } = buildTestBinary(step);
		if (!binary) {
			throw new Error(`failed to build ${step}:\n${tail(log)}`);
		}
		const outDir = resolve(covRoot, step);
		mkdirSync(outDir, { recursive: true });
		const { code, log: klog } = runKcov(outDir, binary);
		if (code !== 0) {
			throw new Error(`kcov failed on ${step} (exit ${code}):\n${tail(klog)}`);
		}
		const run = await readKcovRun(outDir);
		if (run) {
			perBinary[step] = {
				percent: Number(run.percent.toFixed(2)),
				covered: run.covered,
				total: run.total,
			};
			totalCovered += run.covered;
			totalLines += run.total;
		}
	}

	const percent = totalLines > 0 ? (totalCovered / totalLines) * 100 : 0;
	return {
		status: "measured",
		percent_covered: Number(percent.toFixed(2)),
		lines_covered: totalCovered,
		lines_total: totalLines,
		per_binary: perBinary,
	};
}

async function main(): Promise<number> {
	const summary = await measure();
	const covRoot = resolve(repoRoot(), "coverage");
	mkdirSync(covRoot, { recursive: true });
	const summaryPath = resolve(covRoot, "summary.json");
	writeFileSync(summaryPath, `${JSON.stringify(summary, null, 2)}\n`);

	if (summary.status === "skipped") {
		console.log(`kcov-coverage: skipped — ${summary.reason}`);
		console.log(`kcov-coverage: wrote ${summaryPath}`);
		return 0;
	}

	console.log(
		`kcov-coverage: ${summary.percent_covered}% (${summary.lines_covered}/${summary.lines_total} lines)`,
	);
	if (process.argv.includes("--print")) {
		for (const [step, b] of Object.entries(summary.per_binary)) {
			console.log(`  ${step}: ${b.percent}% (${b.covered}/${b.total})`);
		}
	}
	console.log(`kcov-coverage: wrote ${summaryPath}`);
	return 0;
}

if (import.meta.main) {
	process.exit(await main());
}
