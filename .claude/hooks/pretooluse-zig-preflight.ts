#!/usr/bin/env bun
/**
 * PreToolUse(Write|Edit|MultiEdit) — validate proposed .zig content via a
 * temporary file + `zig ast-check` before the edit lands. Exit 2 blocks the
 * edit; exit 0 allows it.
 *
 * Only fires for .zig files. All others pass through with exit 0.
 */
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import {
	appendJsonl,
	emitPreTool,
	readStdinJson,
	tail,
} from "../../scripts/lib/runtime.ts";
import { zig } from "../../scripts/lib/zig.ts";

type PreToolPayload = {
	tool_name?: string;
	tool_input?: {
		file_path?: string;
		content?: string;
		old_string?: string;
		new_string?: string;
		edits?: Array<{ old_string?: string; new_string?: string }>;
	};
};

async function readOriginalOrUndefined(
	path: string,
): Promise<string | undefined> {
	try {
		const f = Bun.file(path);
		if (!(await f.exists())) return undefined;
		return await f.text();
	} catch {
		return undefined;
	}
}

async function main(): Promise<void> {
	const payload = await readStdinJson<PreToolPayload>();
	const tool = payload.tool_name ?? "";
	const file = payload.tool_input?.file_path ?? "";
	if (!file.endsWith(".zig")) {
		emitPreTool({ kind: "allow" });
	}

	// Obtain the proposed POST-EDIT file content. ast-check requires complete
	// syntactically-valid input; running it on a bare Edit/MultiEdit replacement
	// snippet always fails because the snippet is a fragment. Apply the
	// replacements in memory against the original file so the checker sees the
	// merged result (CEL-452).
	let proposed: string | undefined;
	if (tool === "Write") {
		proposed = payload.tool_input?.content;
	} else if (tool === "Edit") {
		const oldStr = payload.tool_input?.old_string ?? "";
		const newStr = payload.tool_input?.new_string ?? "";
		const original = await readOriginalOrUndefined(file);
		if (
			original === undefined ||
			oldStr.length === 0 ||
			!original.includes(oldStr)
		) {
			// Let the actual tool surface a real error (file missing, no match)
			emitPreTool({ kind: "allow" });
		}
		proposed = original!.replace(oldStr, newStr);
	} else if (tool === "MultiEdit") {
		const edits = payload.tool_input?.edits ?? [];
		const original = await readOriginalOrUndefined(file);
		if (original === undefined) emitPreTool({ kind: "allow" });
		let working = original!;
		for (const e of edits) {
			const oldStr = e.old_string ?? "";
			const newStr = e.new_string ?? "";
			if (oldStr.length === 0 || !working.includes(oldStr)) {
				emitPreTool({ kind: "allow" });
			}
			working = working.replace(oldStr, newStr);
		}
		proposed = working;
	}

	if (!proposed || proposed.length === 0) {
		emitPreTool({ kind: "allow" });
	}

	// Dump to temp file and run zig ast-check (0.16 accepts a path)
	const tmp = resolve(tmpdir(), `preflight-${Date.now()}.zig`);
	await Bun.write(tmp, proposed!);
	const r = zig(["ast-check", tmp]);

	await appendJsonl(".claude/logs/zig-preflight.jsonl", {
		event: r.code === 0 ? "pass" : "fail",
		file,
		tool,
		code: r.code,
	});

	if (r.code !== 0) {
		emitPreTool({
			kind: "pre-tool-decision",
			permissionDecision: "deny",
			permissionDecisionReason: `zig ast-check failed on proposed edit to ${file}:\n${tail(r.stderr || r.stdout, 1500)}`,
		});
		return;
	}
	emitPreTool({ kind: "allow" });
}

main().catch(async (err) => {
	await appendJsonl(".claude/logs/zig-preflight.jsonl", {
		event: "error",
		error: String(err),
	});
	console.error(`pretooluse-zig-preflight: ${String(err)}`);
	process.exit(1);
});
