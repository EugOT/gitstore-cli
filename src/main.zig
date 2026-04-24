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
    \\Commands:
    \\  get [-u] [-P N] [--no-adopt] [--shallow] [-b BRANCH] <url>...
    \\                    Clone one or more repos via libgitstore
    \\  list [--full-path] [--json] [--with-head] [<pattern>]
    \\                    List adopted/unadopted repos under ghq root
    \\  root [--all]      Print configured ghq/gitstore root
    \\  rm [--dry-run] <repo>
    \\                    Remove a repo (detaches adopted pointer first)
    \\  create [--vcs git|jj] <host/owner/name>
    \\                    Create a new git+jj repo and adopt in one shot
    \\  migrate <new-root> [--dry-run]
    \\                    Plan/move adopted repos under a new ghq root
    \\  init              Create gitstore directory structure
    \\  init <path>       Init git+jj repo and adopt into gitstore in one shot
    \\  adopt <path>      Migrate an existing repo into gitstore
    \\  adopt --all       Migrate all repos under ghq root
    \\  detach <path>     Restore an adopted repo (reverse of adopt)
    \\  detach --all      Restore all adopted repos
    \\  verify <path>     Check pointer/symlink integrity
    \\  verify --all      Check all adopted repos
    \\  status            Show gitstore disk usage and repo count
    \\  sync <remote>     Sync ghq working trees to rclone remote
    \\  filter            Print rclone filter rules to stdout
    \\  hook --zsh        Print the zsh hook function
    \\  hook --bash       Print the bash hook function
    \\  hook --nu         Print the nushell hook module
    \\
    \\Options:
    \\  --dry-run         Print planned actions without modifying anything
    \\  --keep-backup     Preserve gitstore entry when detaching (renames it)
    \\  --json            Output status in JSON format
    \\  --help            Show this help message
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

        // init with a path: create git+jj repo and adopt in one shot
        const path_arg = args_iter.next();
        if (path_arg) |p| {
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
        const flag = args_iter.next() orelse {
            try printErr(io, "error: hook requires --zsh, --bash, or --nu\n");
            return 2;
        };
        if (std.mem.eql(u8, flag, "--zsh")) {
            try printOut(io, hooks.zsh_hook);
        } else if (std.mem.eql(u8, flag, "--bash")) {
            try printOut(io, hooks.bash_hook);
        } else if (std.mem.eql(u8, flag, "--nu")) {
            try printOut(io, hooks.nu_hook);
        } else {
            try printErr(io, "error: hook requires --zsh, --bash, or --nu\n");
            return 2;
        }
        return 0;
    }

    if (std.mem.eql(u8, command, "adopt")) {
        const gitstore_root = try getGitstoreRoot(gpa, init.environ_map);
        defer gpa.free(gitstore_root);
        const ghq_root = try getGhqRoot(gpa, io);
        defer gpa.free(ghq_root);

        try gitstore.init(io, gitstore_root);

        var dry_run = false;
        var all = false;
        var path: ?[]const u8 = null;

        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--dry-run")) {
                dry_run = true;
            } else if (std.mem.eql(u8, arg, "--all")) {
                all = true;
            } else if (arg[0] != '-') {
                path = arg;
            }
        }

        if (all) {
            try gitstore.adoptAll(gpa, io, ghq_root, gitstore_root, dry_run);
        } else if (path) |p| {
            try gitstore.adopt(gpa, io, p, ghq_root, gitstore_root, dry_run);
        } else {
            try printErr(io, "error: adopt requires <path> or --all\n");
            return 2;
        }
        return 0;
    }

    if (std.mem.eql(u8, command, "verify")) {
        const gitstore_root = try getGitstoreRoot(gpa, init.environ_map);
        defer gpa.free(gitstore_root);
        const ghq_root = try getGhqRoot(gpa, io);
        defer gpa.free(ghq_root);

        var all = false;
        var path: ?[]const u8 = null;

        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--all")) {
                all = true;
            } else if (arg[0] != '-') {
                path = arg;
            }
        }

        if (all) {
            try gitstore.verifyAll(gpa, io, ghq_root, gitstore_root);
        } else if (path) |p| {
            const ok = try gitstore.verify(gpa, io, p);
            if (!ok) {
                return 1;
            }
        } else {
            try printErr(io, "error: verify requires <path> or --all\n");
            return 2;
        }
        return 0;
    }

    if (std.mem.eql(u8, command, "detach")) {
        const gitstore_root = try getGitstoreRoot(gpa, init.environ_map);
        defer gpa.free(gitstore_root);
        const ghq_root = try getGhqRoot(gpa, io);
        defer gpa.free(ghq_root);

        var dry_run = false;
        var all = false;
        var keep_backup = false;
        var path: ?[]const u8 = null;
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--dry-run")) {
                dry_run = true;
            } else if (std.mem.eql(u8, arg, "--all")) {
                all = true;
            } else if (std.mem.eql(u8, arg, "--keep-backup")) {
                keep_backup = true;
            } else if (arg[0] != '-') {
                path = arg;
            }
        }

        if (all) {
            try gitstore.detachAll(gpa, io, ghq_root, gitstore_root, dry_run, keep_backup);
        } else if (path) |p| {
            try gitstore.detach(gpa, io, p, ghq_root, gitstore_root, dry_run, keep_backup);
        } else {
            try printErr(io, "error: detach requires <path> or --all\n");
            return 2;
        }
        return 0;
    }

    if (std.mem.eql(u8, command, "status")) {
        const gitstore_root = try getGitstoreRoot(gpa, init.environ_map);
        defer gpa.free(gitstore_root);
        const ghq_root = try getGhqRoot(gpa, io);
        defer gpa.free(ghq_root);

        var json_mode = false;
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--json")) {
                json_mode = true;
            }
        }

        try gitstore.status(gpa, io, ghq_root, gitstore_root, json_mode);
        return 0;
    }

    if (std.mem.eql(u8, command, "sync")) {
        const gitstore_root = try getGitstoreRoot(gpa, init.environ_map);
        defer gpa.free(gitstore_root);
        const ghq_root = try getGhqRoot(gpa, io);
        defer gpa.free(ghq_root);

        var dry_run = false;
        var remote: ?[]const u8 = null;
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--dry-run")) {
                dry_run = true;
            } else if (arg[0] != '-') {
                remote = arg;
            }
        }

        if (remote) |r| {
            try gitstore.sync(gpa, io, ghq_root, gitstore_root, r, dry_run);
        } else {
            try printErr(io, "error: sync requires <remote>, e.g. 'gdrive:ghq'\n");
            return 2;
        }
        return 0;
    }

    if (std.mem.eql(u8, command, "filter")) {
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
        if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--update")) {
            opts.update_if_exists = true;
        } else if (std.mem.eql(u8, arg, "--no-adopt")) {
            opts.no_adopt = true;
        } else if (std.mem.eql(u8, arg, "--shallow")) {
            opts.shallow = true;
        } else if (std.mem.eql(u8, arg, "--no-recursive")) {
            opts.recursive = false;
        } else if (std.mem.eql(u8, arg, "-P")) {
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
    var pattern: ?[]const u8 = null;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--full-path") or std.mem.eql(u8, arg, "-p")) {
            full_path = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (std.mem.eql(u8, arg, "--with-head")) {
            with_head = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printOut(
                io,
                "Usage: gitstore list [--full-path] [--json] [--with-head] [<pattern>]",
            );
            return 0;
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

    const entries = try list_mod.walk(gpa, io, ghq_root, gitstore_root, .{
        .pattern = pattern,
        .include_worktrees = true,
        .include_head = with_head,
    });
    defer list_mod.freeEntries(gpa, entries);

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
            try printOut(io, "Usage: gitstore root [--all]");
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
            try printOut(io, "Usage: gitstore rm [--dry-run] <repo>");
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
        try gitstore.detach(gpa, io, target.abs_path, ghq_root, gitstore_root, false, false);
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
            try printOut(io, "Usage: gitstore create [--vcs git|jj] <host/owner/name>");
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
            try printOut(io, "Usage: gitstore migrate <new-root> [--dry-run]");
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
