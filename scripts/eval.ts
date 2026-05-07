#!/usr/bin/env bun
/**
 * eval.ts — eval harness entry point.
 *
 * `--check` mode validates the fixture skeleton under `tests/evals/`:
 *   1. Every domain under tests/evals/domains/ must have fixtures in
 *      matched pairs: NN-name.zig + NN-name.expect.json
 *   2. Each expect.json must parse as JSON
 *   3. tests/evals/thresholds.json must parse and contain a key for every
 *      domain directory that exists
 *   4. tests/evals/judge-prompt.md must exist
 *   5. tests/evals/trajectories/ must contain at least one .jsonl file
 *
 * Default mode (no `--check`): judge-backed execution is deferred to v1
 * per plan §10.9 — prints a TODO marker and exits 0.
 *
 * Exit codes:
 *   0 — structure valid (check mode) or default TODO mode
 *   1 — structural failure; the specific missing file or parse error is printed
 */
import { readdirSync, statSync } from "node:fs";
import { basename, resolve } from "node:path";
import { appendJsonl, repoRoot } from "./lib/runtime.ts";

const TIER = "eval" as const;

async function finish(code: number, startedAt: number): Promise<never> {
	const durationMs = Date.now() - startedAt;
	await appendJsonl(".claude/logs/verify.jsonl", {
		event: "eval",
		tier: TIER,
		code,
		durationMs,
	});
	process.exit(code);
}

type CheckFailure = { file: string; reason: string };

async function validateExpectJson(
	absPath: string,
): Promise<CheckFailure | null> {
	try {
		const text = await Bun.file(absPath).text();
		JSON.parse(text);
		return null;
	} catch (err) {
		return { file: absPath, reason: `invalid JSON: ${(err as Error).message}` };
	}
}

/**
 * Parse every non-empty line of a `.jsonl` trajectory file. Each line must
 * be a syntactically valid JSON value; the failing line number is reported
 * so the operator can repair the trajectory without `cat | jq | head` games.
 *
 * Returning `null` means the file is well-formed (or contained only blank
 * lines, which is permissive on purpose; an empty trajectory is caught
 * elsewhere via the `trajCount === 0` check).
 */
async function validateJsonl(absPath: string): Promise<CheckFailure | null> {
	let text: string;
	try {
		text = await Bun.file(absPath).text();
	} catch (err) {
		return { file: absPath, reason: `read error: ${(err as Error).message}` };
	}
	const lines = text.split(/\r?\n/);
	for (let i = 0; i < lines.length; i++) {
		const line = lines[i];
		if (!line?.trim()) continue;
		try {
			JSON.parse(line);
		} catch (err) {
			return {
				file: absPath,
				reason: `invalid JSON on line ${i + 1}: ${(err as Error).message}`,
			};
		}
	}
	return null;
}

async function checkStructure(root: string): Promise<CheckFailure[]> {
	const failures: CheckFailure[] = [];
	const domainsRoot = resolve(root, "tests/evals/domains");
	const thresholdsPath = resolve(root, "tests/evals/thresholds.json");
	const judgePromptPath = resolve(root, "tests/evals/judge-prompt.md");
	const trajectoriesDir = resolve(root, "tests/evals/trajectories");

	if (!(await Bun.file(judgePromptPath).exists())) {
		failures.push({
			file: judgePromptPath,
			reason: "missing tests/evals/judge-prompt.md",
		});
	}

	// Enumerate domains via node:fs (Bun.Glob without onlyFiles still
	// returns files only — readdirSync is the reliable directory listing).
	let entries: string[] = [];
	try {
		entries = readdirSync(domainsRoot);
	} catch {
		failures.push({
			file: domainsRoot,
			reason: "missing tests/evals/domains/",
		});
		return failures;
	}
	const liveDomains: string[] = [];
	for (const entry of entries) {
		const abs = resolve(domainsRoot, entry);
		try {
			if (statSync(abs).isDirectory()) liveDomains.push(entry);
		} catch {
			/* ignore */
		}
	}

	for (const domain of liveDomains) {
		const domainDir = resolve(domainsRoot, domain);
		// Recurse into nested fixture trees (`fixtures/`, `subdomain/`, etc.).
		// The skill docs document `tests/evals/domains/<domain>/fixtures/`,
		// so a non-recursive glob would silently pass any domain that places
		// fixtures one level deep. Pair validation must reach those.
		const fileGlob = new Bun.Glob("**/*.zig");
		const zigFiles: string[] = [];
		for (const f of fileGlob.scanSync({ cwd: domainDir, absolute: true })) {
			zigFiles.push(f);
		}
		for (const zigFile of zigFiles) {
			// Pair lookup uses the directory of the .zig file, not the domain
			// root, so nested .zig + .expect.json siblings still pair correctly.
			const expect = zigFile.replace(/\.zig$/, ".expect.json");
			if (!(await Bun.file(expect).exists())) {
				failures.push({
					file: zigFile,
					reason: `missing pair ${basename(expect)}`,
				});
				continue;
			}
			const parseError = await validateExpectJson(expect);
			if (parseError) failures.push(parseError);
		}
		const expectGlob = new Bun.Glob("**/*.expect.json");
		for (const expect of expectGlob.scanSync({
			cwd: domainDir,
			absolute: true,
		})) {
			const zig = expect.replace(/\.expect\.json$/, ".zig");
			if (!(await Bun.file(zig).exists())) {
				failures.push({
					file: expect,
					reason: `missing pair ${basename(zig)}`,
				});
			}
		}
	}

	if (!(await Bun.file(thresholdsPath).exists())) {
		failures.push({
			file: thresholdsPath,
			reason: "missing tests/evals/thresholds.json",
		});
	} else {
		try {
			const text = await Bun.file(thresholdsPath).text();
			const parsed = JSON.parse(text) as Record<string, unknown>;
			for (const domain of liveDomains) {
				if (!(domain in parsed)) {
					failures.push({
						file: thresholdsPath,
						reason: `thresholds.json missing key for domain '${domain}'`,
					});
				}
			}
		} catch (err) {
			failures.push({
				file: thresholdsPath,
				reason: `invalid JSON: ${(err as Error).message}`,
			});
		}
	}

	let trajCount = 0;
	try {
		const tGlob = new Bun.Glob("*.jsonl");
		for (const traj of tGlob.scanSync({
			cwd: trajectoriesDir,
			absolute: true,
		})) {
			trajCount += 1;
			const parseError = await validateJsonl(traj);
			if (parseError) failures.push(parseError);
		}
	} catch {
		/* handled below */
	}
	if (trajCount === 0) {
		failures.push({
			file: trajectoriesDir,
			reason: "tests/evals/trajectories/ has no *.jsonl files",
		});
	}

	return failures;
}

async function main(): Promise<void> {
	const startedAt = Date.now();
	const root = repoRoot();
	const check = process.argv.includes("--check");
	const report = process.argv.includes("--report");

	// `--report` is advertised in the eval skill but the judge-backed
	// reporter is v1 work. Reject explicitly so callers get a loud failure
	// rather than the TODO path's bogus exit-0.
	if (report) {
		console.error(
			"eval --report is not implemented yet (judge-backed reporter is v1; see plan §10.9)",
		);
		await finish(1, startedAt);
	}

	if (!check) {
		console.log("TODO: judge-backed eval execution pending v1");
		await finish(0, startedAt);
	}

	const failures = await checkStructure(root);
	if (failures.length === 0) {
		console.log("eval --check: OK");
		await finish(0, startedAt);
	}
	for (const f of failures) {
		console.error(`eval --check: ${f.file}: ${f.reason}`);
	}
	await finish(1, startedAt);
}

await main();
