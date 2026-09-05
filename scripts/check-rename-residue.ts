#!/usr/bin/env bun
/**
 * Exit codes:
 *   0 — clean
 *   1 — one or more hits, printed as `path:line: text  (reason)`
 *   2 — could not enumerate tracked files
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { repoRoot, spawnSync } from "./lib/runtime.ts";

export type Rule = { pattern: RegExp; reason: string };
export type Hit = { path: string; line: number; text: string; reason: string };

export const rules: readonly Rule[] = [
	{
		pattern: /gitstore-cli/,
		reason: "retired project name; the project is z3store",
	},
	{
		pattern: /github\.com\/EugOT\//,
		reason: "retired owner URL; use github.com/Eugene3dotdev/",
	},
	{
		pattern: /EugOT\/(gitstore-cli|z3store|ziglint)/,
		reason: "retired owner slug; use Eugene3dotdev/",
	},
];

export const allowlist: Readonly<Record<string, string>> = {
	"doc/adr/": "dated decision records keep the names in use when written",
	"doc/DVC_INTEGRATION.md": "pre-rename design snapshot",
	"workflows/": "dated workflow records",
	".audit/": "run audit trails quote the patterns they checked",
	"src/tests.zig": "EugOT is arbitrary owner fixture data",
	"scripts/check-rename-residue.ts": "defines the patterns",
	"tests/unit/check-rename-residue.test.ts": "exercises the patterns",
};

export function isAllowed(path: string): boolean {
	return Object.keys(allowlist).some((entry) =>
		entry.endsWith("/") ? path.startsWith(entry) : path === entry,
	);
}

export function scanText(path: string, text: string): Hit[] {
	const hits: Hit[] = [];
	const lines = text.split("\n");
	for (let i = 0; i < lines.length; i++) {
		const line = lines[i] ?? "";
		const rule = rules.find((r) => r.pattern.test(line));
		if (rule !== undefined) {
			hits.push({ path, line: i + 1, text: line.trim(), reason: rule.reason });
		}
	}
	return hits;
}

function readTrackedFile(absPath: string): Uint8Array | null {
	try {
		return readFileSync(absPath);
	} catch (err) {
		if ((err as NodeJS.ErrnoException).code === "ENOENT") return null;
		throw err;
	}
}

function looksBinary(bytes: Uint8Array): boolean {
	const probe = bytes.subarray(0, 8192);
	return probe.includes(0);
}

export function trackedFiles(root: string): string[] | null {
	const git = spawnSync(["git", "ls-files", "-z"], { cwd: root });
	if (git.code !== 0) return null;
	return git.stdout.split("\0").filter((p) => p.length > 0);
}

export function scanRepo(root = repoRoot()): { hits: Hit[]; scanned: number } {
	const files = trackedFiles(root);
	if (files === null) {
		throw new Error("git ls-files failed; cannot enumerate tracked files");
	}
	const hits: Hit[] = [];
	let scanned = 0;
	for (const path of files) {
		if (isAllowed(path)) continue;
		const bytes = readTrackedFile(resolve(root, path));
		if (bytes === null || looksBinary(bytes)) continue;
		scanned++;
		hits.push(...scanText(path, new TextDecoder().decode(bytes)));
	}
	return { hits, scanned };
}

function main(): void {
	let result: { hits: Hit[]; scanned: number };
	try {
		result = scanRepo();
	} catch (err) {
		console.error(
			`check-rename-residue: ${err instanceof Error ? err.message : String(err)}`,
		);
		process.exit(2);
	}
	for (const h of result.hits) {
		console.error(`${h.path}:${h.line}: ${h.text}  (${h.reason})`);
	}
	if (result.hits.length > 0) {
		console.error(
			`check-rename-residue: ${result.hits.length} hit(s) in ${result.scanned} scanned file(s); see doc/adr/0005-canonical-branch-and-rename-residue.md`,
		);
		process.exit(1);
	}
	console.log(`check-rename-residue: OK (${result.scanned} files scanned)`);
}

if (import.meta.main) {
	main();
}
