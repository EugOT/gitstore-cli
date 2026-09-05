import { expect, test } from "bun:test";
import {
	allowlist,
	isAllowed,
	scanRepo,
	scanText,
} from "../../scripts/check-rename-residue.ts";

test("flags the retired project name", () => {
	const hits = scanText("README.md", "# Coverage Baseline — gitstore-cli\n");
	expect(hits).toHaveLength(1);
	expect(hits[0]?.line).toBe(1);
	expect(hits[0]?.reason).toContain("retired project name");
});

test("flags the retired owner URL and slug, one hit per line", () => {
	const text = [
		"ok line",
		"See https://github.com/EugOT/z3store",
		"install EugOT/ziglint for the lint gate",
		"Regression EugOT/gitstore-cli#22",
	].join("\n");
	const hits = scanText("src/main.zig", text);
	expect(hits.map((h) => h.line)).toEqual([2, 3, 4]);
	expect(hits[0]?.reason).toContain("retired owner URL");
	expect(hits[1]?.reason).toContain("retired owner slug");
	expect(hits[2]?.reason).toContain("retired project name");
});

test("leaves the compatibility layer and ambiguous slugs alone", () => {
	const text = [
		'snapshotValue(config_snapshot, "gitstore.root")',
		'env.get("GITSTORE_BACKING_STORE_ROOT")',
		"~/.local/share/gitstore",
		".gitstore/cache/index.json",
		"[gitstore]",
		"sourced from `EugOT/dotfiles`",
		"github.com/Eugene3dotdev/z3store",
	].join("\n");
	expect(scanText("src/config.zig", text)).toEqual([]);
});

test("allowlist matches directories by prefix and files exactly", () => {
	expect(isAllowed("doc/adr/0003-darwin-fuzz-degradation.md")).toBe(true);
	expect(isAllowed("doc/adr")).toBe(false);
	expect(isAllowed("src/tests.zig")).toBe(true);
	expect(isAllowed("src/tests.zig.bak")).toBe(false);
	expect(isAllowed("src/main.zig")).toBe(false);
});

test("every allowlist entry carries a reason", () => {
	for (const [path, reason] of Object.entries(allowlist)) {
		expect(path.length).toBeGreaterThan(0);
		expect(reason.length).toBeGreaterThan(10);
	}
});

test("the tracked tree is clean", () => {
	const { hits, scanned } = scanRepo();
	expect(scanned).toBeGreaterThan(50);
	expect(hits).toEqual([]);
});
