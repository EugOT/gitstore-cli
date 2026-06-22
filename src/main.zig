const std = @import("std");
const Io = std.Io;
const File = std.Io.File;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;

const gitstore = @import("gitstore.zig");
const hooks = @import("hooks.zig");
const url_mod = @import("url.zig");
const config_mod = @import("config.zig");
const clone_mod = @import("clone.zig");
const list_mod = @import("list.zig");

const usage_text =
    \\Usage: gitstore <command> [options]
    \\
    \\Run `gitstore <command> --help` (or `-h`) for per-command help.
    \\
    \\Commands:
    \\  get [-u] [-P N] [--no-adopt] [--shallow] [-b BRANCH] <url>...
    \\                    Clone one or more repos via libgitstore
    \\  list [-p] [-e] [--json] [--with-head] [<pattern>]
    \\                    List adopted/unadopted repos under ghq root
    \\  root [--all]      Print configured ghq/gitstore root
    \\  rm [--dry-run] <repo>
    \\                    Remove a repo (detaches adopted pointer first)
    \\  create [--vcs git|jj] <host/owner/name>
    \\                    Create a new git+jj repo and adopt in one shot
    \\  migrate <new-root> [--dry-run]
    \\                    Plan/move adopted repos under a new ghq root
    \\  init [<path>]     Create gitstore dir or init+adopt one-shot
    \\  adopt <path>|--all
    \\                    Migrate existing repo(s) into gitstore
    \\  detach <path>|--all [--keep-backup]
    \\                    Restore an adopted repo (reverse of adopt)
    \\  verify <path>|--all
    \\                    Check pointer/symlink integrity
    \\  status [--json]   Show gitstore disk usage and repo count
    \\  sync <remote> [--dry-run]
    \\                    Sync ghq working trees to rclone remote
    \\  filter            Print rclone filter rules to stdout
    \\  hook --zsh|--bash|--nu
    \\                    Print the shell wrapper for `ghq`->`gitstore`
    \\
    \\Global options:
    \\  --help, -h        Show this help message
    \\
    \\See also: docs/MIGRATION-ghq-to-gitstore.md, https://github.com/EugOT/gitstore-cli
    \\
;

const sub_help_init =
    \\NAME:
    \\   gitstore init — Create gitstore dir or init+adopt a repo in one shot
    \\
    \\USAGE:
    \\   gitstore init                Ensure ~/.local/share/gitstore exists
    \\   gitstore init <path>         git init + jj colocate + adopt at <path>
    \\
    \\OPTIONS:
    \\   --help, -h                   Show this help
    \\
;

const sub_help_hook =
    \\NAME:
    \\   gitstore hook — Print the shell wrapper that delegates ghq → gitstore
    \\
    \\USAGE:
    \\   gitstore hook --zsh          Print zsh wrapper (source from .zshrc)
    \\   gitstore hook --bash         Print bash wrapper (source from .bashrc)
    \\   gitstore hook --nu           Print nushell module (source from config.nu)
    \\
    \\OPTIONS:
    \\   --help, -h                   Show this help
    \\
;

const sub_help_adopt =
    \\NAME:
    \\   gitstore adopt — Migrate an existing repo into gitstore (detach .git)
    \\
    \\USAGE:
    \\   gitstore adopt <path>        Adopt a single repo
    \\   gitstore adopt --all         Adopt every git repo under ghq root
    \\
    \\OPTIONS:
    \\   --dry-run                    Print plan without touching disk
    \\   --all                        Recurse over the entire ghq root
    \\   --help, -h                   Show this help
    \\
;

const sub_help_verify =
    \\NAME:
    \\   gitstore verify — Check pointer/symlink integrity of adopted repos
    \\
    \\USAGE:
    \\   gitstore verify <path>       Verify a single adopted repo
    \\   gitstore verify --all        Verify every adopted repo under ghq root
    \\
    \\OPTIONS:
    \\   --all                        Recurse over the entire ghq root
    \\   --help, -h                   Show this help
    \\
;

const sub_help_detach =
    \\NAME:
    \\   gitstore detach — Reverse adopt: restore .git in the working tree
    \\
    \\USAGE:
    \\   gitstore detach <path>       Detach a single adopted repo
    \\   gitstore detach --all        Detach every adopted repo
    \\
    \\OPTIONS:
    \\   --dry-run                    Print plan without touching disk
    \\   --all                        Recurse over the entire ghq root
    \\   --keep-backup                Rename the gitstore entry instead of deleting
    \\   --help, -h                   Show this help
    \\
;

const sub_help_status =
    \\NAME:
    \\   gitstore status — Show gitstore disk usage and repo counts
    \\
    \\USAGE:
    \\   gitstore status              Plain text summary
    \\   gitstore status --json       Machine-readable JSON
    \\
    \\OPTIONS:
    \\   --json                       Emit JSON instead of text
    \\   --help, -h                   Show this help
    \\
;

const sub_help_sync =
    \\NAME:
    \\   gitstore sync — Push ghq working trees to an rclone remote
    \\
    \\USAGE:
    \\   gitstore sync <remote>       e.g. gdrive:ghq
    \\
    \\OPTIONS:
    \\   --dry-run                    Run rclone with --dry-run (shows what
    \\                                would be transferred without copying)
    \\   --help, -h                   Show this help
    \\
    \\NOTES:
    \\   Excludes .git/.jj internals + build artifacts; see `gitstore filter`.
    \\
;

const sub_help_filter =
    \\NAME:
    \\   gitstore filter — Print rclone filter rules suitable for `--filter-from`
    \\
    \\USAGE:
    \\   gitstore filter > rclone-filter.txt
    \\
    \\OPTIONS:
    \\   --help, -h                   Show this help
    \\
;

const sub_help_get =
    \\NAME:
    \\   gitstore get — Clone repo(s); auto-adopt into gitstore unless --no-adopt
    \\
    \\USAGE:
    \\   gitstore get [options] <url>...
    \\
    \\OPTIONS:
    \\   -u, --update                 Pull latest if the repo already exists
    \\   -P, --parallel N             Bounded parallelism (default 1)
    \\   --no-adopt                   Skip auto-adopt after clone
    \\   --shallow                    Pass --depth 1 to git clone
    \\   --no-recursive               Disable submodule init/update (default: on)
    \\   -b, --branch BRANCH          Pass --branch=BRANCH (implies --single-branch)
    \\   --help, -h                   Show this help
    \\
    \\URL FORMS:
    \\   github.com/owner/repo, owner/repo, repo (uses gitstore.user default),
    \\   https://host/owner/repo[.git], git@host:owner/repo, ssh://...,
    \\   file:///abs/path
    \\
;

const sub_help_list =
    \\NAME:
    \\   gitstore list — List repositories under the configured ghq root
    \\
    \\USAGE:
    \\   gitstore list [options] [<pattern>]
    \\
    \\OPTIONS:
    \\   -p, --full-path              Print full filesystem paths
    \\   -e, --exact                  Match <pattern> exactly against the full
    \\                                rel_path (host/owner/repo)
    \\   --json                       Emit JSON array (each entry has rel_path,
    \\                                abs_path, host, owner, name, is_adopted,
    \\                                has_jj, worktrees, head_sha, last_fetched_unix)
    \\   --with-head                  Resolve HEAD sha (slow; shells out per repo)
    \\   --help, -h                   Show this help
    \\
    \\If <pattern> is given without --exact, only repos whose rel_path contains
    \\<pattern> as a substring are listed. With --exact, the match must equal
    \\the full rel_path (host/owner/repo) exactly.
    \\
;

const sub_help_root =
    \\NAME:
    \\   gitstore root — Print the configured ghq/gitstore working-tree root
    \\
    \\USAGE:
    \\   gitstore root                Print the primary root
    \\   gitstore root --all          Print all configured roots (v1: same as primary)
    \\
    \\OPTIONS:
    \\   --all                        Print every root (v1 subset: prints primary)
    \\   --help, -h                   Show this help
    \\
;

const sub_help_rm =
    \\NAME:
    \\   gitstore rm — Remove a repository (detaches adopted pointer first)
    \\
    \\USAGE:
    \\   gitstore rm [--dry-run] <repo>
    \\
    \\OPTIONS:
    \\   --dry-run                    Print plan without touching disk
    \\   --help, -h                   Show this help
    \\
    \\<repo> is matched as exact rel_path or unique substring against
    \\`gitstore list` output. If multiple repos match, the command refuses
    \\to act and asks you to be more specific.
    \\
;

const sub_help_create =
    \\NAME:
    \\   gitstore create — Create a new git+jj repo and adopt in one shot
    \\
    \\USAGE:
    \\   gitstore create <host/owner/name>
    \\   gitstore create <owner/name>     (uses gitstore.user / default_host)
    \\
    \\OPTIONS:
    \\   --vcs git|jj                 (Accepted; v1 always git+jj colocate)
    \\   --help, -h                   Show this help
    \\
;

const sub_help_migrate =
    \\NAME:
    \\   gitstore migrate — Move adopted repos under a new ghq root
    \\
    \\USAGE:
    \\   gitstore migrate <new-root> --dry-run
    \\
    \\OPTIONS:
    \\   --dry-run                    Print move plan without touching disk
    \\   --help, -h                   Show this help
    \\
    \\NOTE: Only --dry-run is implemented in v1; real-mode returns
    \\      error.MigrationNotImplemented pending the WAL replay design.
    \\
;

fn getGitstoreRoot(gpa: Allocator, environ_map: *const std.process.Environ.Map) ![]u8 {
    const home = environ_map.get("HOME") orelse return error.InvalidUserId;
    return std.fmt.allocPrint(gpa, "{s}/.local/share/gitstore", .{home});
}

fn getGhqRoot(gpa: Allocator, io: Io) ![]u8 {
    const ex = @import("exec.zig");
    const result = try ex.exec(gpa, io, &.{ "ghq", "root" }, null);
    defer gpa.free(result.stderr);
    if (!result.succeeded()) {
        gpa.free(result.stdout);
        return error.ProcessFailed;
    }
    // Trim trailing newline from the stdout
    const trimmed = ex.trimTrailingNewline(result.stdout);
    // We need to return owned memory of just the trimmed part
    if (trimmed.len < result.stdout.len) {
        const owned = try gpa.dupe(u8, trimmed);
        gpa.free(result.stdout);
        return owned;
    }
    return result.stdout;
}

/// Best-effort ghq-root resolution used by the newer subcommands. Falls back
/// to `<HOME>/ghq` when the `ghq` binary is unavailable, so `gitstore root`
/// and `gitstore list` can still function without ghq installed.
fn resolveGhqRootOrHome(gpa: Allocator, io: Io, environ_map: *const std.process.Environ.Map) ![]u8 {
    return getGhqRoot(gpa, io) catch {
        const home = environ_map.get("HOME") orelse return error.InvalidUserId;
        return std.fmt.allocPrint(gpa, "{s}/ghq", .{home});
    };
}

// =========================================================
// Unit tests for the private dispatcher helpers (G2).
//
// These live inline in main.zig because the helpers are private — only test
// blocks in the same file can see them, so no `pub` wrapper or seam function
// is needed. The integration test runner collects these via
// `comptime { _ = @import("main.zig"); }` in src/tests.zig. They MUST NOT
// reference `@import("build_options")`: that module is added only to the
// integration module, not to exe_mod (whose root is also main.zig), so a
// build_options import here would break the `gitstore` executable build.
//
// Every test uses std.testing.allocator and frees on the success path so the
// testing allocator's leak detector pins any allocPrint that is not released.
// =========================================================

test "getGitstoreRoot returns <HOME>/.local/share/gitstore" {
    const gpa = std.testing.allocator;
    var env_map: std.process.Environ.Map = .init(gpa);
    defer env_map.deinit();
    try env_map.put("HOME", "/test/home");

    const root = try getGitstoreRoot(gpa, &env_map);
    defer gpa.free(root);
    try std.testing.expectEqualStrings("/test/home/.local/share/gitstore", root);
}

test "getGitstoreRoot errors when HOME is absent" {
    const gpa = std.testing.allocator;
    var env_map: std.process.Environ.Map = .init(gpa);
    defer env_map.deinit();
    // Intentionally leave HOME unset.

    try std.testing.expectError(error.InvalidUserId, getGitstoreRoot(gpa, &env_map));
}

// DISCREPANCY vs the task's HELPERS testSpec: `std.testing.io` is a real
// `Io.Threaded` instance (see std/testing.zig: `io_instance: Io.Threaded`).
// It SPAWNS real processes under `zig build test` — exec.zig's own tests run
// real `git`/`echo`/`pwd` through it. The spec assumed ghq exec would always
// fail under testing.io and the HOME fallback would fire deterministically;
// that is not the real behavior when ghq is installed. These tests therefore
// branch on actual ghq availability (probed once via getGhqRoot) so they pin
// the true contract whether or not ghq is on PATH, instead of asserting a
// fallback that never executes on a host that has ghq. main.zig logic is
// unchanged.

/// Probe whether `ghq root` is runnable under the test io. Returns the owned
/// real ghq-root slice on success (caller frees), or null when ghq is absent
/// / fails to produce a clean zero-exit result.
fn probeGhqRoot(gpa: Allocator, io: Io) ?[]u8 {
    return getGhqRoot(gpa, io) catch return null;
}

test "resolveGhqRootOrHome: real ghq root when present, else <HOME>/ghq fallback" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env_map: std.process.Environ.Map = .init(gpa);
    defer env_map.deinit();
    try env_map.put("HOME", "/tmp/testhome");

    const root = try resolveGhqRootOrHome(gpa, io, &env_map);
    defer gpa.free(root);

    if (probeGhqRoot(gpa, io)) |real| {
        defer gpa.free(real);
        // ghq present: resolveGhqRootOrHome must return the real ghq root and
        // must NOT consult HOME, so it never equals the "/tmp/testhome/ghq"
        // fallback.
        try std.testing.expectEqualStrings(real, root);
        try std.testing.expect(!std.mem.eql(u8, "/tmp/testhome/ghq", root));
    } else {
        // ghq absent: the HOME fallback branch fires deterministically.
        try std.testing.expectEqualStrings("/tmp/testhome/ghq", root);
    }
}

test "resolveGhqRootOrHome errors with InvalidUserId only when ghq fails AND HOME absent" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env_map: std.process.Environ.Map = .init(gpa);
    defer env_map.deinit();
    // No HOME set.

    if (probeGhqRoot(gpa, io)) |real| {
        // ghq present: success short-circuits before the HOME lookup, so the
        // missing HOME is irrelevant and a real root is returned.
        defer gpa.free(real);
        const root = try resolveGhqRootOrHome(gpa, io, &env_map);
        defer gpa.free(root);
        try std.testing.expectEqualStrings(real, root);
    } else {
        // ghq absent + HOME absent → the only path that yields InvalidUserId.
        try std.testing.expectError(error.InvalidUserId, resolveGhqRootOrHome(gpa, io, &env_map));
    }
}

test "getGhqRoot returns an absolute newline-trimmed path when ghq is installed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // Success path: absolute, non-empty, trailing newline stripped (the trim
    // contract). Failure path (ghq absent): a value is never returned.
    const result = getGhqRoot(gpa, io) catch |err| {
        try std.testing.expect(err == error.FileNotFound or
            err == error.ProcessFailed or
            err == error.Unexpected);
        return;
    };
    defer gpa.free(result);
    try std.testing.expect(result.len > 0);
    try std.testing.expect(result[0] == '/');
    try std.testing.expect(result[result.len - 1] != '\n');
}

test "getGhqRoot trims the trailing newline from `ghq root` stdout" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // The raw `ghq root` stdout ends in a newline; getGhqRoot must dupe-and-free
    // to return the trimmed slice. Pin that the returned slice carries no
    // trailing newline/CR and that the failure path frees the owned stdout (a
    // leak there would trip the testing allocator). Skip cleanly if ghq is not
    // runnable in this environment so the suite stays green on minimal hosts.
    const result = getGhqRoot(gpa, io) catch return error.SkipZigTest;
    defer gpa.free(result);
    try std.testing.expect(result.len > 0);
    try std.testing.expect(result[result.len - 1] != '\n' and result[result.len - 1] != '\r');
    // Re-running yields an identical, independently-owned slice (no aliasing).
    const again = try getGhqRoot(gpa, io);
    defer gpa.free(again);
    try std.testing.expectEqualStrings(result, again);
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_iter.deinit();
    _ = args_iter.next(); // skip argv[0]

    const command = args_iter.next() orelse {
        try printUsage(io);
        return 0;
    };

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage(io);
        return 0;
    }

    if (std.mem.eql(u8, command, "init")) {
        const gitstore_root = try getGitstoreRoot(gpa, init.environ_map);
        defer gpa.free(gitstore_root);

        // init with a path: create git+jj repo and adopt in one shot.
        // Scan ALL args (not just the first) so `init /path --help` and
        // `init --help /path` both surface help, and so unknown flags are
        // caught regardless of position. Any non-flag is treated as the
        // single optional path; multiple paths are rejected.
        var path: ?[]const u8 = null;
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                try printOut(io, sub_help_init);
                return 0;
            }
            if (arg.len > 0 and arg[0] == '-') {
                var buf: [512]u8 = undefined;
                var w = File.stderr().writerStreaming(io, &buf);
                try w.interface.print("error: unknown flag for init: {s}\n", .{arg});
                try w.flush();
                return 2;
            }
            if (path != null) {
                var buf: [512]u8 = undefined;
                var w = File.stderr().writerStreaming(io, &buf);
                try w.interface.print("error: init takes at most one path: {s}\n", .{arg});
                try w.flush();
                return 2;
            }
            path = arg;
        }
        if (path) |p| {
            const ghq_root = try getGhqRoot(gpa, io);
            defer gpa.free(ghq_root);
            try gitstore.initRepo(gpa, io, p, ghq_root, gitstore_root);
        } else {
            // No path: just ensure gitstore root directory exists
            try gitstore.init(io, gitstore_root);
            var buf: [4096]u8 = undefined;
            var w = File.stdout().writerStreaming(io, &buf);
            try w.interface.print("gitstore initialized at {s}\n", .{gitstore_root});
            try w.flush();
        }
        return 0;
    }

    if (std.mem.eql(u8, command, "hook")) {
        // Scan all args so `gitstore hook --zsh --help` (and any reordering)
        // surfaces help instead of printing the wrapper. Round-6 fix per CR
        // major outside-diff.
        var has_help = false;
        var shell: ?[]const u8 = null;
        var first_unknown: ?[]const u8 = null;
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                has_help = true;
            } else if (std.mem.eql(u8, arg, "--zsh") or std.mem.eql(u8, arg, "--bash") or std.mem.eql(u8, arg, "--nu")) {
                if (shell != null and !std.mem.eql(u8, shell.?, arg)) {
                    var buf: [512]u8 = undefined;
                    var w = File.stderr().writerStreaming(io, &buf);
                    try w.interface.print("error: hook accepts only one of --zsh/--bash/--nu (got {s} after {s})\n", .{ arg, shell.? });
                    try w.flush();
                    return 2;
                }
                shell = arg;
            } else if (first_unknown == null) {
                first_unknown = arg;
            }
        }
        if (has_help) {
            try printOut(io, sub_help_hook);
            return 0;
        }
        if (first_unknown) |arg| {
            var buf: [512]u8 = undefined;
            var w = File.stderr().writerStreaming(io, &buf);
            try w.interface.print("error: unknown argument for hook: {s}\n", .{arg});
            try w.flush();
            return 2;
        }
        const which = shell orelse {
            try printErr(io, "error: hook requires --zsh, --bash, or --nu\n");
            return 2;
        };
        if (std.mem.eql(u8, which, "--zsh")) {
            try printOut(io, hooks.zsh_hook);
        } else if (std.mem.eql(u8, which, "--bash")) {
            try printOut(io, hooks.bash_hook);
        } else {
            try printOut(io, hooks.nu_hook);
        }
        return 0;
    }

    if (std.mem.eql(u8, command, "adopt")) {
        var dry_run = false;
        var all = false;
        var path: ?[]const u8 = null;

        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                try printOut(io, sub_help_adopt);
                return 0;
            } else if (std.mem.eql(u8, arg, "--dry-run")) {
                dry_run = true;
            } else if (std.mem.eql(u8, arg, "--all")) {
                all = true;
            } else if (arg.len != 0 and arg[0] == '-') {
                var buf: [512]u8 = undefined;
                var w = File.stderr().writerStreaming(io, &buf);
                try w.interface.print("error: unknown flag for adopt: {s}\n", .{arg});
                try w.flush();
                return 2;
            } else {
                if (path != null) {
                    var buf: [512]u8 = undefined;
                    var w = File.stderr().writerStreaming(io, &buf);
                    try w.interface.print("error: adopt takes at most one path: {s}\n", .{arg});
                    try w.flush();
                    return 2;
                }
                path = arg;
            }
        }

        if (!all and path == null) {
            try printErr(io, "error: adopt requires <path> or --all\n");
            return 2;
        }

        // Resolve roots only after arg parse so `adopt --help` cannot fail
        // with error.ProcessFailed when ghq is not installed.
        const gitstore_root = try getGitstoreRoot(gpa, init.environ_map);
        defer gpa.free(gitstore_root);
        const ghq_root = try getGhqRoot(gpa, io);
        defer gpa.free(ghq_root);
        try gitstore.init(io, gitstore_root);

        if (all) {
            try gitstore.adoptAll(gpa, io, ghq_root, gitstore_root, dry_run);
        } else if (path) |p| {
            try gitstore.adopt(gpa, io, p, ghq_root, gitstore_root, dry_run);
        }
        return 0;
    }

    if (std.mem.eql(u8, command, "verify")) {
        var all = false;
        var path: ?[]const u8 = null;

        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                try printOut(io, sub_help_verify);
                return 0;
            } else if (std.mem.eql(u8, arg, "--all")) {
                all = true;
            } else if (arg.len != 0 and arg[0] == '-') {
                var buf: [512]u8 = undefined;
                var w = File.stderr().writerStreaming(io, &buf);
                try w.interface.print("error: unknown flag for verify: {s}\n", .{arg});
                try w.flush();
                return 2;
            } else {
                if (path != null) {
                    var buf: [512]u8 = undefined;
                    var w = File.stderr().writerStreaming(io, &buf);
                    try w.interface.print("error: verify takes at most one path: {s}\n", .{arg});
                    try w.flush();
                    return 2;
                }
                path = arg;
            }
        }

        if (!all and path == null) {
            try printErr(io, "error: verify requires <path> or --all\n");
            return 2;
        }

        // Resolve roots only after arg parse so `verify --help` cannot fail
        // when ghq is not installed.
        const gitstore_root = try getGitstoreRoot(gpa, init.environ_map);
        defer gpa.free(gitstore_root);
        const ghq_root = try getGhqRoot(gpa, io);
        defer gpa.free(ghq_root);

        if (all) {
            try gitstore.verifyAll(gpa, io, ghq_root, gitstore_root);
        } else if (path) |p| {
            const ok = try gitstore.verify(gpa, io, p);
            if (!ok) {
                return 1;
            }
        }
        return 0;
    }

    if (std.mem.eql(u8, command, "detach")) {
        var dry_run = false;
        var all = false;
        var keep_backup = false;
        var path: ?[]const u8 = null;
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                try printOut(io, sub_help_detach);
                return 0;
            } else if (std.mem.eql(u8, arg, "--dry-run")) {
                dry_run = true;
            } else if (std.mem.eql(u8, arg, "--all")) {
                all = true;
            } else if (std.mem.eql(u8, arg, "--keep-backup")) {
                keep_backup = true;
            } else if (arg.len != 0 and arg[0] == '-') {
                var buf: [512]u8 = undefined;
                var w = File.stderr().writerStreaming(io, &buf);
                try w.interface.print("error: unknown flag for detach: {s}\n", .{arg});
                try w.flush();
                return 2;
            } else {
                if (path != null) {
                    var buf: [512]u8 = undefined;
                    var w = File.stderr().writerStreaming(io, &buf);
                    try w.interface.print("error: detach takes at most one path: {s}\n", .{arg});
                    try w.flush();
                    return 2;
                }
                path = arg;
            }
        }

        if (!all and path == null) {
            try printErr(io, "error: detach requires <path> or --all\n");
            return 2;
        }

        // Resolve roots only after arg parse so `detach --help` cannot fail
        // when ghq is not installed.
        const gitstore_root = try getGitstoreRoot(gpa, init.environ_map);
        defer gpa.free(gitstore_root);
        const ghq_root = try getGhqRoot(gpa, io);
        defer gpa.free(ghq_root);

        if (all) {
            // detachAll swallows per-repo GitDirMalformed and reports it as
            // a `failed` count in the summary, so we don't need a special
            // catch here — only path errors and IO failures propagate.
            try gitstore.detachAll(gpa, io, ghq_root, gitstore_root, dry_run, keep_backup);
        } else if (path) |p| {
            gitstore.detach(gpa, io, p, ghq_root, gitstore_root, dry_run, keep_backup) catch |err| switch (err) {
                error.GitDirMalformed => {
                    var buf: [512]u8 = undefined;
                    var w = File.stderr().writerStreaming(io, &buf);
                    try w.interface.print("error: {s}/.git has a malformed gitdir pointer; refusing to detach\n", .{p});
                    try w.flush();
                    return 1;
                },
                else => return err,
            };
        }
        return 0;
    }

    if (std.mem.eql(u8, command, "status")) {
        var json_mode = false;
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                try printOut(io, sub_help_status);
                return 0;
            } else if (std.mem.eql(u8, arg, "--json")) {
                json_mode = true;
            } else {
                var buf: [512]u8 = undefined;
                var w = File.stderr().writerStreaming(io, &buf);
                try w.interface.print("error: unknown argument for status: {s}\n", .{arg});
                try w.flush();
                return 2;
            }
        }

        // Resolve roots only after arg parse so `status --help` cannot fail
        // when ghq is not installed.
        const gitstore_root = try getGitstoreRoot(gpa, init.environ_map);
        defer gpa.free(gitstore_root);
        const ghq_root = try getGhqRoot(gpa, io);
        defer gpa.free(ghq_root);

        try gitstore.status(gpa, io, ghq_root, gitstore_root, json_mode);
        return 0;
    }

    if (std.mem.eql(u8, command, "sync")) {
        var dry_run = false;
        var remote: ?[]const u8 = null;
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                try printOut(io, sub_help_sync);
                return 0;
            } else if (std.mem.eql(u8, arg, "--dry-run")) {
                dry_run = true;
            } else if (arg.len != 0 and arg[0] == '-') {
                var buf: [512]u8 = undefined;
                var w = File.stderr().writerStreaming(io, &buf);
                try w.interface.print("error: unknown flag for sync: {s}\n", .{arg});
                try w.flush();
                return 2;
            } else {
                if (remote != null) {
                    var buf: [512]u8 = undefined;
                    var w = File.stderr().writerStreaming(io, &buf);
                    try w.interface.print("error: sync takes at most one remote: {s}\n", .{arg});
                    try w.flush();
                    return 2;
                }
                remote = arg;
            }
        }

        if (remote == null) {
            try printErr(io, "error: sync requires <remote>, e.g. 'gdrive:ghq'\n");
            return 2;
        }

        // Resolve roots only after arg parse so `sync --help` cannot fail
        // when ghq is not installed.
        const gitstore_root = try getGitstoreRoot(gpa, init.environ_map);
        defer gpa.free(gitstore_root);
        const ghq_root = try getGhqRoot(gpa, io);
        defer gpa.free(ghq_root);

        try gitstore.sync(gpa, io, ghq_root, gitstore_root, remote.?, dry_run);
        return 0;
    }

    if (std.mem.eql(u8, command, "filter")) {
        // Scan all remaining args. If any is --help/-h, show help (regardless
        // of position). Otherwise, the first non-help argument is rejected.
        // This matches the Copilot finding so `filter foo -h` shows help and
        // `filter foo` errors as unexpected.
        var has_help = false;
        var first_unexpected: ?[]const u8 = null;
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                has_help = true;
            } else if (first_unexpected == null) {
                first_unexpected = arg;
            }
        }
        if (has_help) {
            try printOut(io, sub_help_filter);
            return 0;
        }
        if (first_unexpected) |arg| {
            var buf: [512]u8 = undefined;
            var w = File.stderr().writerStreaming(io, &buf);
            try w.interface.print("error: unexpected argument: {s}\n", .{arg});
            try w.flush();
            return 1;
        }
        try printOut(io, hooks.rclone_filter);
        return 0;
    }

    // --- libgitstore v2 subcommands ---

    if (std.mem.eql(u8, command, "get")) {
        return cmdGet(gpa, io, init.environ_map, &args_iter);
    }

    if (std.mem.eql(u8, command, "list")) {
        return cmdList(gpa, io, init.environ_map, &args_iter);
    }

    if (std.mem.eql(u8, command, "root")) {
        return cmdRoot(gpa, io, init.environ_map, &args_iter);
    }

    if (std.mem.eql(u8, command, "rm")) {
        return cmdRm(gpa, io, init.environ_map, &args_iter);
    }

    if (std.mem.eql(u8, command, "create")) {
        return cmdCreate(gpa, io, init.environ_map, &args_iter);
    }

    if (std.mem.eql(u8, command, "migrate")) {
        return cmdMigrate(gpa, io, init.environ_map, &args_iter);
    }

    try printErr(io, "error: unknown command '");
    try printErr(io, command);
    try printErr(io, "'\n");
    try printUsage(io);
    return 2;
}

// =========================================================
// libgitstore v2 subcommand implementations
// =========================================================

fn cmdGet(
    gpa: Allocator,
    io: Io,
    environ_map: *std.process.Environ.Map,
    args_iter: *std.process.Args.Iterator,
) !u8 {
    var opts: clone_mod.CloneOptions = .{ .recursive = true };
    var urls: std.ArrayList([]const u8) = .empty;
    defer urls.deinit(gpa);

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printOut(io, sub_help_get);
            return 0;
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--update")) {
            opts.update_if_exists = true;
        } else if (std.mem.eql(u8, arg, "--no-adopt")) {
            opts.no_adopt = true;
        } else if (std.mem.eql(u8, arg, "--shallow")) {
            opts.shallow = true;
        } else if (std.mem.eql(u8, arg, "--no-recursive")) {
            opts.recursive = false;
        } else if (std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--parallel")) {
            const n = args_iter.next() orelse {
                try printErr(io, "error: -P requires N\n");
                return 2;
            };
            opts.parallelism = std.fmt.parseInt(u32, n, 10) catch {
                try printErr(io, "error: -P argument must be a positive integer\n");
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--branch")) {
            opts.branch = args_iter.next() orelse {
                try printErr(io, "error: -b requires BRANCH\n");
                return 2;
            };
        } else if (arg.len == 0 or arg[0] == '-') {
            try printErr(io, "error: unknown flag for get\n");
            return 2;
        } else {
            try urls.append(gpa, arg);
        }
    }

    if (urls.items.len == 0) {
        try printErr(io, "error: get requires at least one <url>\n");
        return 2;
    }

    // Load config for parser defaults.
    var cfg = config_mod.load(gpa, io, environ_map) catch |err| {
        try printErr(io, "error: failed to load config\n");
        return err;
    };
    defer cfg.deinit(gpa);

    if (cfg.used_legacy_ghq_keys) {
        try printErr(
            io,
            "warning: using ghq.* config keys; prefer gitstore.* equivalents\n",
        );
    }

    // Resolve gitstore root (for adoption side effect).
    const gitstore_root = try getGitstoreRoot(gpa, environ_map);
    defer gpa.free(gitstore_root);
    try gitstore.init(io, gitstore_root);

    // Parse URLs into specs.
    var specs: std.ArrayList(url_mod.RepoSpec) = .empty;
    defer {
        for (specs.items) |*s| s.deinit(gpa);
        specs.deinit(gpa);
    }

    const defaults: url_mod.Defaults = .{
        .user = cfg.user,
        .host = cfg.default_host,
    };

    for (urls.items) |u| {
        const spec = url_mod.parse(gpa, u, defaults) catch |err| {
            var buf: [1024]u8 = undefined;
            var w = File.stderr().writerStreaming(io, &buf);
            try w.interface.print("error: cannot parse url {s}: {s}\n", .{ u, @errorName(err) });
            try w.flush();
            return 2;
        };
        try specs.append(gpa, spec);
    }

    const reports = clone_mod.cloneMany(
        gpa,
        io,
        specs.items,
        cfg.root,
        gitstore_root,
        opts,
    ) catch |err| {
        var buf: [512]u8 = undefined;
        var w = File.stderr().writerStreaming(io, &buf);
        try w.interface.print("error: clone failed: {s}\n", .{@errorName(err)});
        try w.flush();
        return 1;
    };
    defer clone_mod.freeReports(gpa, reports);

    var any_failed = false;
    var out_buf: [4096]u8 = undefined;
    var w = File.stdout().writerStreaming(io, &out_buf);
    for (reports) |r| {
        const status_str: []const u8 = switch (r.status) {
            .cloned => "cloned        ",
            .updated => "updated       ",
            .skipped_exists => "skipped_exists",
            .failed => "failed        ",
        };
        if (r.status == .failed) {
            any_failed = true;
            if (r.err) |msg| {
                try w.interface.print("{s} | {s}  ({s})\n", .{ status_str, r.url, msg });
            } else {
                try w.interface.print("{s} | {s}\n", .{ status_str, r.url });
            }
        } else {
            try w.interface.print("{s} | {s}\n", .{ status_str, r.storage_path });
        }
    }
    try w.flush();

    return if (any_failed) @as(u8, 1) else 0;
}

fn cmdList(
    gpa: Allocator,
    io: Io,
    environ_map: *std.process.Environ.Map,
    args_iter: *std.process.Args.Iterator,
) !u8 {
    var full_path = false;
    var json_mode = false;
    var with_head = false;
    var exact = false;
    var pattern: ?[]const u8 = null;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printOut(io, sub_help_list);
            return 0;
        } else if (std.mem.eql(u8, arg, "--full-path") or std.mem.eql(u8, arg, "-p")) {
            full_path = true;
        } else if (std.mem.eql(u8, arg, "--exact") or std.mem.eql(u8, arg, "-e")) {
            exact = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (std.mem.eql(u8, arg, "--with-head")) {
            with_head = true;
        } else if (arg.len == 0 or arg[0] == '-') {
            try printErr(io, "error: unknown flag for list\n");
            return 2;
        } else {
            pattern = arg;
        }
    }

    const gitstore_root = try getGitstoreRoot(gpa, environ_map);
    defer gpa.free(gitstore_root);
    const ghq_root = try resolveGhqRootOrHome(gpa, io, environ_map);
    defer gpa.free(ghq_root);

    const all_entries = try list_mod.walk(gpa, io, ghq_root, gitstore_root, .{
        .pattern = pattern,
        .include_worktrees = true,
        .include_head = with_head,
    });
    defer list_mod.freeEntries(gpa, all_entries);

    // Apply --exact filter (in-place selection) against the full relative
    // repository path (host/owner/repo). Matching e.name in addition to
    // e.rel_path is ambiguous when the same repo name exists under different
    // owners or hosts, so the documented exact semantics restrict to rel_path
    // only.
    var filtered: std.ArrayList(list_mod.RepoEntry) = .empty;
    defer filtered.deinit(gpa);
    const entries = if (exact and pattern != null) blk: {
        const p = pattern.?;
        for (all_entries) |e| {
            if (std.mem.eql(u8, e.rel_path, p)) {
                try filtered.append(gpa, e);
            }
        }
        break :blk filtered.items;
    } else all_entries;

    const text = if (json_mode)
        try list_mod.renderJson(gpa, entries)
    else
        try list_mod.renderPlain(gpa, entries, full_path);
    defer gpa.free(text);

    var buf: [8192]u8 = undefined;
    var w = File.stdout().writerStreaming(io, &buf);
    try w.interface.writeAll(text);
    if (json_mode) {
        // Pretty-printed JSON from std.json.Stringify does not include a
        // trailing newline. Add one so shell pipelines behave.
        try w.interface.writeByte('\n');
    }
    try w.flush();
    return 0;
}

fn cmdRoot(
    gpa: Allocator,
    io: Io,
    environ_map: *std.process.Environ.Map,
    args_iter: *std.process.Args.Iterator,
) !u8 {
    // `--all` is accepted for ghq parity but behaves as the single-root
    // case in v1; per-URL overrides are future work.
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--all")) {
            // Multi-root enumeration is a v1 subset — no-op for now.
            continue;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printOut(io, sub_help_root);
            return 0;
        } else {
            try printErr(io, "error: unknown flag for root\n");
            return 2;
        }
    }

    var cfg = config_mod.load(gpa, io, environ_map) catch |err| {
        try printErr(io, "error: failed to load config\n");
        return err;
    };
    defer cfg.deinit(gpa);

    var buf: [4096]u8 = undefined;
    var w = File.stdout().writerStreaming(io, &buf);
    try w.interface.print("{s}\n", .{cfg.root});
    try w.flush();
    return 0;
}

fn cmdRm(
    gpa: Allocator,
    io: Io,
    environ_map: *std.process.Environ.Map,
    args_iter: *std.process.Args.Iterator,
) !u8 {
    var dry_run = false;
    var repo_arg: ?[]const u8 = null;
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printOut(io, sub_help_rm);
            return 0;
        } else if (arg.len != 0 and arg[0] != '-') {
            repo_arg = arg;
        } else {
            try printErr(io, "error: unknown flag for rm\n");
            return 2;
        }
    }

    const needle = repo_arg orelse {
        try printErr(io, "error: rm requires <repo> (substring or host/owner/name)\n");
        return 2;
    };

    const gitstore_root = try getGitstoreRoot(gpa, environ_map);
    defer gpa.free(gitstore_root);
    const ghq_root = try resolveGhqRootOrHome(gpa, io, environ_map);
    defer gpa.free(ghq_root);

    const entries = try list_mod.walk(gpa, io, ghq_root, gitstore_root, .{
        .include_worktrees = false,
        .include_head = false,
    });
    defer list_mod.freeEntries(gpa, entries);

    // Exact rel_path match first; else unique substring.
    var exact_idx: ?usize = null;
    var sub_idx: ?usize = null;
    var sub_count: usize = 0;
    for (entries, 0..) |e, i| {
        if (std.mem.eql(u8, e.rel_path, needle)) {
            exact_idx = i;
            break;
        }
        if (std.mem.indexOf(u8, e.rel_path, needle) != null) {
            sub_idx = i;
            sub_count += 1;
        }
    }

    const idx = exact_idx orelse blk: {
        if (sub_count == 0) {
            var buf: [1024]u8 = undefined;
            var w = File.stderr().writerStreaming(io, &buf);
            try w.interface.print("error: no repo matches {s}\n", .{needle});
            try w.flush();
            return 1;
        }
        if (sub_count > 1) {
            var buf: [1024]u8 = undefined;
            var w = File.stderr().writerStreaming(io, &buf);
            try w.interface.print("error: ambiguous repo match {s} ({d} candidates)\n", .{ needle, sub_count });
            try w.flush();
            return 1;
        }
        break :blk sub_idx.?;
    };

    const target = entries[idx];
    var out_buf: [4096]u8 = undefined;
    var ow = File.stdout().writerStreaming(io, &out_buf);

    if (dry_run) {
        if (target.is_adopted) {
            try ow.interface.print("would detach+remove {s}\n", .{target.abs_path});
        } else {
            try ow.interface.print("would remove {s}\n", .{target.abs_path});
        }
        try ow.flush();
        return 0;
    }

    if (target.is_adopted) {
        gitstore.detach(gpa, io, target.abs_path, ghq_root, gitstore_root, false, false) catch |err| switch (err) {
            error.GitDirMalformed => {
                var ebuf: [512]u8 = undefined;
                var ew = File.stderr().writerStreaming(io, &ebuf);
                try ew.interface.print("error: {s}/.git has a malformed gitdir pointer; refusing to remove\n", .{target.abs_path});
                try ew.flush();
                return 1;
            },
            else => return err,
        };
    } else {
        try Dir.cwd().deleteTree(io, target.abs_path);
    }
    try ow.interface.print("removed {s}\n", .{target.abs_path});
    try ow.flush();
    return 0;
}

fn cmdCreate(
    gpa: Allocator,
    io: Io,
    environ_map: *std.process.Environ.Map,
    args_iter: *std.process.Args.Iterator,
) !u8 {
    var repo_arg: ?[]const u8 = null;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--vcs")) {
            const vcs = args_iter.next() orelse {
                try printErr(io, "error: --vcs requires git|jj\n");
                return 2;
            };
            if (!std.mem.eql(u8, vcs, "git") and !std.mem.eql(u8, vcs, "jj")) {
                try printErr(io, "error: --vcs must be 'git' or 'jj'\n");
                return 2;
            }
            // The flag is accepted for forward-compatibility; initRepo
            // performs the canonical git+jj path unconditionally.
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printOut(io, sub_help_create);
            return 0;
        } else if (arg.len != 0 and arg[0] != '-') {
            repo_arg = arg;
        } else {
            try printErr(io, "error: unknown flag for create\n");
            return 2;
        }
    }

    const name = repo_arg orelse {
        try printErr(io, "error: create requires <host/owner/name> or <owner/name>\n");
        return 2;
    };

    var cfg = config_mod.load(gpa, io, environ_map) catch |err| {
        try printErr(io, "error: failed to load config\n");
        return err;
    };
    defer cfg.deinit(gpa);

    // Parse via url.parse to canonicalize host/owner/name.
    var spec = url_mod.parse(gpa, name, .{
        .user = cfg.user,
        .host = cfg.default_host,
    }) catch |err| {
        var buf: [1024]u8 = undefined;
        var w = File.stderr().writerStreaming(io, &buf);
        try w.interface.print("error: cannot parse {s}: {s}\n", .{ name, @errorName(err) });
        try w.flush();
        return 2;
    };
    defer spec.deinit(gpa);

    const repo_path = try spec.toStoragePath(gpa, cfg.root);
    defer gpa.free(repo_path);

    const gitstore_root = try getGitstoreRoot(gpa, environ_map);
    defer gpa.free(gitstore_root);

    // initRepo already handles: git init, optional jj colocate, adopt.
    try gitstore.initRepo(gpa, io, repo_path, cfg.root, gitstore_root);

    var buf: [4096]u8 = undefined;
    var w = File.stdout().writerStreaming(io, &buf);
    try w.interface.print("created {s}\n", .{repo_path});
    try w.flush();
    return 0;
}

fn cmdMigrate(
    gpa: Allocator,
    io: Io,
    environ_map: *std.process.Environ.Map,
    args_iter: *std.process.Args.Iterator,
) !u8 {
    var dry_run = false;
    var new_root: ?[]const u8 = null;
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printOut(io, sub_help_migrate);
            return 0;
        } else if (arg.len != 0 and arg[0] != '-') {
            new_root = arg;
        } else {
            try printErr(io, "error: unknown flag for migrate\n");
            return 2;
        }
    }

    const target_root = new_root orelse {
        try printErr(io, "error: migrate requires <new-root>\n");
        return 2;
    };

    const gitstore_root = try getGitstoreRoot(gpa, environ_map);
    defer gpa.free(gitstore_root);
    const ghq_root = try resolveGhqRootOrHome(gpa, io, environ_map);
    defer gpa.free(ghq_root);

    const entries = try list_mod.walk(gpa, io, ghq_root, gitstore_root, .{
        .include_worktrees = true,
        .include_head = false,
    });
    defer list_mod.freeEntries(gpa, entries);

    var buf: [8192]u8 = undefined;
    var w = File.stdout().writerStreaming(io, &buf);
    try w.interface.print("migrate plan: {s} -> {s}\n", .{ ghq_root, target_root });

    var adopted_count: usize = 0;
    var worktree_count: usize = 0;
    for (entries) |e| {
        if (!e.is_adopted) continue;
        adopted_count += 1;
        const new_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ target_root, e.rel_path });
        defer gpa.free(new_path);
        try w.interface.print("  move    {s}\n          -> {s}\n", .{ e.abs_path, new_path });
        for (e.worktrees) |wt| {
            worktree_count += 1;
            try w.interface.print("  repair  worktree {s}\n", .{wt});
        }
    }

    try w.interface.print(
        "summary: {d} adopted repo(s), {d} linked worktree(s)\n",
        .{ adopted_count, worktree_count },
    );
    try w.flush();

    if (dry_run) return 0;

    // Real-mode migration is intentionally deferred: moving gitstore_root
    // entries, rewriting .git pointers, and running `git worktree repair`
    // require the WAL-backed operation log to stay crash-consistent. The
    // libgitstore v2 plan explicitly permits a dry-run-only v1 subset.
    try printErr(
        io,
        "error: migrate real-mode not implemented; rerun with --dry-run\n",
    );
    return error.MigrationNotImplemented;
}

fn printUsage(io: Io) !void {
    var buf: [4096]u8 = undefined;
    var w = File.stderr().writerStreaming(io, &buf);
    try w.interface.print("{s}", .{usage_text});
    try w.flush();
}

fn printOut(io: Io, text: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = File.stdout().writerStreaming(io, &buf);
    try w.interface.print("{s}\n", .{text});
    try w.flush();
}

fn printErr(io: Io, text: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = File.stderr().writerStreaming(io, &buf);
    try w.interface.print("{s}", .{text});
    try w.flush();
}
