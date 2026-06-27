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

const DEFAULT_IMAGE = "gitstore-cli-kcov:zig0.16-bun1.3.0";
const DOCKERFILE = "docker/coverage.Dockerfile";

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
		image: process.env.GITSTORE_COVERAGE_IMAGE ?? DEFAULT_IMAGE,
		platform: process.env.GITSTORE_COVERAGE_PLATFORM,
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
  GITSTORE_COVERAGE_IMAGE     Override Docker image tag
  GITSTORE_COVERAGE_PLATFORM  Override Docker platform`);
}

function requireDocker(): void {
	if (Bun.which("docker") === null) {
		throw new Error("docker was not found on PATH; start OrbStack and retry.");
	}
	const info = spawnSync([
		"docker",
		"info",
		"--format",
		"{{.OperatingSystem}}",
	]);
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

function buildImage(root: string, args: Args): void {
	const dockerfile = resolve(root, DOCKERFILE);
	if (!existsSync(dockerfile)) {
		throw new Error(`coverage Dockerfile not found: ${dockerfile}`);
	}
	const cmd = ["docker", "build", "-f", dockerfile, "-t", args.image];
	if (args.platform) cmd.push("--platform", args.platform);
	cmd.push(root);
	const result = spawnSync(cmd, { cwd: root });
	process.stdout.write(result.stdout);
	process.stderr.write(result.stderr);
	if (result.code !== 0) {
		throw new Error(`docker build failed with exit ${result.code}`);
	}
}

function runCoverage(root: string, args: Args): number {
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
		"HOME=/tmp/gitstore-coverage-home",
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

	const result = spawnSync(cmd, { cwd: root });
	process.stdout.write(result.stdout);
	process.stderr.write(result.stderr);
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
	requireDocker();
	if (args.build) buildImage(root, args);
	return runCoverage(root, args);
}

if (import.meta.main) {
	try {
		process.exit(await main());
	} catch (err) {
		console.error(err instanceof Error ? err.message : String(err));
		process.exit(1);
	}
}
