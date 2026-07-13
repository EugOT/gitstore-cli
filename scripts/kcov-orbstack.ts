/**
 * Local Linux coverage parity runner.
 *
 * This intentionally runs the same command sequence as the CI coverage job,
 * but inside an ephemeral Docker container served by OrbStack on macOS. CI
 * remains authoritative; this wrapper is only a local parity lane.
 */
import { existsSync } from "node:fs";
import { resolve } from "node:path";
import { repoRoot, spawnSync } from "./lib/runtime.ts";

const DEFAULT_IMAGE = "z3store-kcov:zig0.16-bun1.3.0";
const DOCKERFILE = "docker/coverage.Dockerfile";
const DOCKER_INFO_TIMEOUT_MS = Number(
	process.env.Z3STORE_DOCKER_INFO_TIMEOUT_MS ?? 15_000,
);
const DOCKER_BUILD_TIMEOUT_MS = Number(
	process.env.Z3STORE_DOCKER_BUILD_TIMEOUT_MS ?? 10 * 60_000,
);
const DOCKER_RUN_TIMEOUT_MS = Number(
	process.env.Z3STORE_DOCKER_RUN_TIMEOUT_MS ?? 15 * 60_000,
);

type Args = {
	build: boolean;
	image: string;
	platform?: string;
	print: boolean;
	threshold?: string;
};

function parseArgs(argv: string[]): Args {
	const args: Args = {
		build: !argv.includes("--no-build"),
		image: process.env.Z3STORE_COVERAGE_IMAGE ?? DEFAULT_IMAGE,
		platform: process.env.Z3STORE_COVERAGE_PLATFORM,
		print: argv.includes("--print"),
	};

	for (let i = 0; i < argv.length; i++) {
		const arg = argv[i];
		if (arg === "--image" && argv[i + 1]) {
			args.image = argv[++i];
		} else if (arg === "--platform" && argv[i + 1]) {
			args.platform = argv[++i];
		} else if (arg === "--threshold" && argv[i + 1]) {
			args.threshold = argv[++i];
		} else if (arg === "--help" || arg === "-h") {
			printHelp();
			process.exit(0);
		}
	}

	return args;
}

function printHelp(): void {
	console.log(`Usage:
  bun scripts/kcov-orbstack.ts [--print] [--threshold <n>] [--platform linux/arm64] [--image <tag>] [--no-build]

Runs CI-equivalent kcov coverage in an ephemeral Docker container. The wrapper
mounts only this repository at /work, sets temporary cache/home directories,
and requires a measured coverage summary.

Environment:
  Z3STORE_COVERAGE_IMAGE     Override Docker image tag
  Z3STORE_COVERAGE_PLATFORM  Override Docker platform`);
}

type CommandResult = {
	code: number | null;
	stdout: string;
	stderr: string;
	timedOut: boolean;
};

async function runBounded(
	cmd: string[],
	opts: { cwd?: string; timeoutMs: number },
): Promise<CommandResult> {
	const controller = new AbortController();
	let timedOut = false;
	const timer = setTimeout(() => {
		timedOut = true;
		controller.abort();
	}, opts.timeoutMs);
	try {
		const proc = Bun.spawn(cmd, {
			cwd: opts.cwd,
			stdout: "pipe",
			stderr: "pipe",
			stdin: "ignore",
			signal: controller.signal,
		});
		const stdoutPromise = new Response(proc.stdout).text();
		const stderrPromise = new Response(proc.stderr).text();
		const code = await proc.exited.catch(() => (timedOut ? 124 : 1));
		const [stdout, stderr] = await Promise.all([
			stdoutPromise.catch(() => ""),
			stderrPromise.catch(() => ""),
		]);
		return { code, stdout, stderr, timedOut };
	} finally {
		clearTimeout(timer);
	}
}

async function requireDocker(): Promise<void> {
	if (Bun.which("docker") === null) {
		throw new Error("docker was not found on PATH; start OrbStack and retry.");
	}
	const info = await runBounded(
		["docker", "info", "--format", "{{.OperatingSystem}}"],
		{ timeoutMs: DOCKER_INFO_TIMEOUT_MS },
	);
	if (info.timedOut) {
		throw new Error(
			`docker info timed out after ${DOCKER_INFO_TIMEOUT_MS}ms; restart OrbStack/Docker and retry.`,
		);
	}
	if (info.code !== 0) {
		throw new Error(
			`docker daemon is unavailable:\n${info.stderr || info.stdout}`,
		);
	}
	if (!info.stdout.toLowerCase().includes("orbstack")) {
		console.warn(
			`WARN: docker daemon does not identify as OrbStack (${info.stdout.trim() || "unknown"}).`,
		);
	}
}

async function buildImage(root: string, args: Args): Promise<void> {
	const dockerfile = resolve(root, DOCKERFILE);
	if (!existsSync(dockerfile)) {
		throw new Error(`coverage Dockerfile not found: ${dockerfile}`);
	}
	const cmd = ["docker", "build", "-f", dockerfile, "-t", args.image];
	if (args.platform) cmd.push("--platform", args.platform);
	cmd.push(root);
	const result = await runBounded(cmd, {
		cwd: root,
		timeoutMs: DOCKER_BUILD_TIMEOUT_MS,
	});
	process.stdout.write(result.stdout);
	process.stderr.write(result.stderr);
	if (result.timedOut) {
		throw new Error(
			`docker build timed out after ${DOCKER_BUILD_TIMEOUT_MS}ms`,
		);
	}
	if (result.code !== 0) {
		throw new Error(`docker build failed with exit ${result.code}`);
	}
}

async function runCoverage(root: string, args: Args): Promise<number> {
	const uid = process.getuid?.() ?? 1000;
	const gid = process.getgid?.() ?? 1000;
	const coverageArgs = ["bun", "scripts/kcov-coverage.ts"];
	if (args.print) coverageArgs.push("--print");
	const checkArgs = ["bun", "scripts/check-coverage.ts", "--require-measured"];
	if (args.threshold) checkArgs.push("--threshold", args.threshold);
	const inner = [
		"set -euo pipefail",
		'mkdir -p "$HOME" "$BUN_INSTALL_CACHE_DIR" "$XDG_CACHE_HOME"',
		"bun ci",
		coverageArgs.map(shellQuote).join(" "),
		checkArgs.map(shellQuote).join(" "),
	].join("; ");

	const cmd = [
		"docker",
		"run",
		"--rm",
		"--init",
		"--cap-add",
		"SYS_PTRACE",
		"--security-opt",
		"seccomp=unconfined",
		"--user",
		`${uid}:${gid}`,
		"-e",
		"HOME=/tmp/z3store-coverage-home",
		"-e",
		"BUN_INSTALL_CACHE_DIR=/tmp/bun-cache",
		"-e",
		"XDG_CACHE_HOME=/tmp/xdg-cache",
		"-e",
		"MISE_TRUSTED_CONFIG_PATHS=/work",
		"-v",
		`${root}:/work`,
		...gitMetadataMount(root),
		"-w",
		"/work",
	];
	if (args.platform) cmd.push("--platform", args.platform);
	cmd.push(args.image, "bash", "-lc", inner);

	const result = await runBounded(cmd, {
		cwd: root,
		timeoutMs: DOCKER_RUN_TIMEOUT_MS,
	});
	process.stdout.write(result.stdout);
	process.stderr.write(result.stderr);
	if (result.timedOut) {
		console.error(`docker run timed out after ${DOCKER_RUN_TIMEOUT_MS}ms`);
		return 124;
	}
	return result.code ?? 1;
}

function gitMetadataMount(root: string): string[] {
	const result = spawnSync(["git", "rev-parse", "--git-dir"], { cwd: root });
	if (result.code !== 0) return [];
	const raw = result.stdout.trim();
	if (raw.length === 0) return [];
	const gitDir = raw.startsWith("/") ? raw : resolve(root, raw);
	if (!existsSync(gitDir) || gitDir.startsWith(`${root}/`)) return [];
	return ["-v", `${gitDir}:${gitDir}:ro`];
}

function shellQuote(value: string): string {
	return `'${value.replaceAll("'", "'\\''")}'`;
}

async function main(): Promise<number> {
	const args = parseArgs(process.argv.slice(2));
	const root = repoRoot();
	await requireDocker();
	if (args.build) await buildImage(root, args);
	return await runCoverage(root, args);
}

if (import.meta.main) {
	try {
		process.exit(await main());
	} catch (err) {
		console.error(err instanceof Error ? err.message : String(err));
		process.exit(1);
	}
}
