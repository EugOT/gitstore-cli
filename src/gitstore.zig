const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;
const Allocator = std.mem.Allocator;
const ex = @import("exec.zig");
const oplog = @import("log.zig");

pub const Error = error{
    ProcessFailed,
    NotAGitRepo,
    AlreadyAdopted,
    InvalidGhqRoot,
    VerifyFailed,
} || Allocator.Error || ex.ExecError || Dir.WriteFileError || Dir.SymLinkError ||
    Dir.DeleteTreeError || Dir.OpenError || Dir.CreateDirPathError ||
    File.OpenError || File.StatError || Dir.ReadFileAllocError;

/// Set to true to suppress stdout output (used during tests).
pub var quiet: bool = false;

fn info(io: Io, comptime fmt: []const u8, args: anytype) void {
    if (quiet) return;
    var buf: [8192]u8 = undefined;
    var w = File.stdout().writerStreaming(io, &buf);
    w.interface.print(fmt, args) catch {};
    w.flush() catch {};
}

fn warn(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    var w = File.stderr().writerStreaming(io, &buf);
    w.interface.print(fmt, args) catch {};
    w.flush() catch {};
}

/// Create the gitstore root directory if it does not exist.
/// Respects existing symlinks (does not overwrite).
pub fn init(io: Io, gitstore_root: []const u8) !void {
    Dir.cwd().createDirPath(io, gitstore_root) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// Determine the gitstore subpath for a repo given its absolute path and ghq root.
pub fn repoRelativePath(repo_path: []const u8, ghq_root: []const u8) ?[]const u8 {
    if (ghq_root.len == 0) return null;
    var root = ghq_root;
    while (root.len > 1 and root[root.len - 1] == '/') {
        root = root[0 .. root.len - 1];
    }
    if (root.len == 1 and root[0] == '/') {
        if (repo_path.len > 1 and repo_path[0] == '/') {
            return repo_path[1..];
        }
        return null;
    }
    if (std.mem.startsWith(u8, repo_path, root) and
        repo_path.len > root.len and
        repo_path[root.len] == '/')
    {
        return repo_path[root.len + 1 ..];
    }
    return null;
}

/// Check if a repo is already adopted (has .git as a file, not directory).
pub fn isAdopted(io: Io, repo_path: []const u8, gpa: Allocator) bool {
    const git_path = std.fmt.allocPrint(gpa, "{s}/.git", .{repo_path}) catch return false;
    defer gpa.free(git_path);

    const content = Dir.cwd().readFileAlloc(io, git_path, gpa, .unlimited) catch |err| switch (err) {
        error.IsDir => return false,
        else => return false,
    };
    defer gpa.free(content);
    return std.mem.startsWith(u8, content, "gitdir:");
}

/// Initialize a directory as a gitstore-managed repo in one shot.
/// If the directory already has .git, just adopt it.
/// If not, run git init + jj colocate, then adopt.
pub fn initRepo(
    gpa: Allocator,
    io: Io,
    repo_path: []const u8,
    ghq_root: []const u8,
    gitstore_root: []const u8,
) !void {
    try init(io, gitstore_root);
    Dir.cwd().createDirPath(io, repo_path) catch {};

    if (isAdopted(io, repo_path, gpa)) {
        info(io, "skip: {s} (already adopted)\n", .{repo_path});
        return;
    }

    const git_path = try std.fmt.allocPrint(gpa, "{s}/.git", .{repo_path});
    defer gpa.free(git_path);

    const has_git = blk: {
        _ = Dir.cwd().readFileAlloc(io, git_path, gpa, .unlimited) catch |err| switch (err) {
            error.IsDir => break :blk true,
            else => break :blk false,
        };
        break :blk false;
    };

    if (!has_git) {
        info(io, "git init: {s}\n", .{repo_path});
        const git_init = try ex.exec(gpa, io, &.{ "git", "init" }, repo_path);
        gpa.free(git_init.stdout);
        gpa.free(git_init.stderr);
        if (!git_init.succeeded()) return error.ProcessFailed;

        info(io, "jj init: {s}\n", .{repo_path});
        const jj_init = try ex.exec(gpa, io, &.{ "jj", "git", "init", "--colocate" }, repo_path);
        gpa.free(jj_init.stdout);
        gpa.free(jj_init.stderr);
        if (!jj_init.succeeded()) {
            warn(io, "warn: jj init failed (continuing git-only)\n", .{});
        }
    }

    try adopt(gpa, io, repo_path, ghq_root, gitstore_root, false);
}

/// Rewrite .jj/repo/store/git_target to use an absolute path to the git database.
pub fn rewriteJjGitTarget(
    gpa: Allocator,
    io: Io,
    jj_dest: []const u8,
    git_dest: []const u8,
) !void {
    const git_target_path = try std.fmt.allocPrint(gpa, "{s}/repo/store/git_target", .{jj_dest});
    defer gpa.free(git_target_path);

    const new_content = try std.fmt.allocPrint(gpa, "{s}", .{git_dest});
    defer gpa.free(new_content);

    Dir.cwd().writeFile(io, .{
        .sub_path = git_target_path,
        .data = new_content,
    }) catch {};
}

/// Adopt a single repository: move .git and .jj into gitstore.
pub fn adopt(
    gpa: Allocator,
    io: Io,
    repo_path: []const u8,
    ghq_root: []const u8,
    gitstore_root: []const u8,
    dry_run: bool,
) !void {
    const rel_path = repoRelativePath(repo_path, ghq_root) orelse {
        warn(io, "error: {s} is not under ghq root {s}\n", .{ repo_path, ghq_root });
        return error.InvalidGhqRoot;
    };

    if (isAdopted(io, repo_path, gpa)) {
        info(io, "skip: {s} (already adopted)\n", .{repo_path});
        return;
    }

    const git_src = try std.fmt.allocPrint(gpa, "{s}/.git", .{repo_path});
    defer gpa.free(git_src);
    {
        _ = Dir.cwd().statFile(io, git_src, .{}) catch {
            warn(io, "error: {s} has no .git directory\n", .{repo_path});
            return error.NotAGitRepo;
        };
    }

    const git_dest = try std.fmt.allocPrint(gpa, "{s}/{s}/git", .{ gitstore_root, rel_path });
    defer gpa.free(git_dest);
    const jj_dest = try std.fmt.allocPrint(gpa, "{s}/{s}/jj", .{ gitstore_root, rel_path });
    defer gpa.free(jj_dest);
    const log_path = try std.fmt.allocPrint(gpa, "{s}/operations.log", .{gitstore_root});
    defer gpa.free(log_path);

    if (dry_run) {
        info(io, "dry-run: would adopt {s}\n", .{repo_path});
        info(io, "  copy {s} -> {s}\n", .{ git_src, git_dest });
        info(io, "  write pointer {s}/.git -> gitdir: {s}\n", .{ repo_path, git_dest });

        const jj_src = try std.fmt.allocPrint(gpa, "{s}/.jj", .{repo_path});
        defer gpa.free(jj_src);
        const has_jj = blk: {
            _ = Dir.cwd().statFile(io, jj_src, .{}) catch break :blk false;
            break :blk true;
        };
        if (has_jj) {
            info(io, "  copy {s} -> {s}\n", .{ jj_src, jj_dest });
            info(io, "  symlink {s}/.jj -> {s}\n", .{ repo_path, jj_dest });
        } else {
            info(io, "  init jj colocated in {s}\n", .{repo_path});
        }
        return;
    }

    // --- Step 1: Create gitstore directory structure ---
    const repo_store_dir = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ gitstore_root, rel_path });
    defer gpa.free(repo_store_dir);
    try Dir.cwd().createDirPath(io, repo_store_dir);

    // --- Step 2: Copy .git to gitstore ---
    info(io, "copy: {s} -> {s}\n", .{ git_src, git_dest });
    const cp_result = try ex.exec(gpa, io, &.{ "cp", "-a", git_src, git_dest }, null);
    defer {
        gpa.free(cp_result.stdout);
        gpa.free(cp_result.stderr);
    }
    if (!cp_result.succeeded()) {
        warn(io, "error: cp failed: {s}\n", .{cp_result.stderr});
        try oplog.logOperation(io, log_path, .copy, git_src, git_dest, "error: cp failed");
        return error.ProcessFailed;
    }
    try oplog.logOperation(io, log_path, .copy, git_src, git_dest, "ok");

    // --- Step 3: Verify the copy ---
    {
        const verify_result = try ex.exec(
            gpa,
            io,
            &.{ "git", "--git-dir", git_dest, "rev-parse", "--git-dir" },
            null,
        );
        defer {
            gpa.free(verify_result.stdout);
            gpa.free(verify_result.stderr);
        }
        if (!verify_result.succeeded()) {
            warn(io, "error: git verify failed after copy, rolling back\n", .{});
            Dir.cwd().deleteTree(io, git_dest) catch {};
            try oplog.logOperation(io, log_path, .copy, git_src, git_dest, "error: verify failed, rolled back");
            return error.VerifyFailed;
        }
    }

    // --- Step 4: Remove original .git directory and write pointer file ---
    try Dir.cwd().deleteTree(io, git_src);
    try oplog.logOperation(io, log_path, .remove, git_src, "", "ok");

    const pointer_content = try std.fmt.allocPrint(gpa, "gitdir: {s}\n", .{git_dest});
    defer gpa.free(pointer_content);
    try Dir.cwd().writeFile(io, .{ .sub_path = git_src, .data = pointer_content });
    try oplog.logOperation(io, log_path, .write_pointer, git_src, git_dest, "ok");
    info(io, "pointer: {s} -> {s}\n", .{ git_src, git_dest });

    // --- Step 5: Handle .jj ---
    const jj_src = try std.fmt.allocPrint(gpa, "{s}/.jj", .{repo_path});
    defer gpa.free(jj_src);

    const has_jj = blk: {
        _ = Dir.cwd().statFile(io, jj_src, .{}) catch break :blk false;
        break :blk true;
    };

    if (has_jj) {
        info(io, "copy: {s} -> {s}\n", .{ jj_src, jj_dest });
        const jj_cp = try ex.exec(gpa, io, &.{ "cp", "-a", jj_src, jj_dest }, null);
        defer {
            gpa.free(jj_cp.stdout);
            gpa.free(jj_cp.stderr);
        }
        if (!jj_cp.succeeded()) {
            warn(io, "error: cp .jj failed: {s}\n", .{jj_cp.stderr});
            try oplog.logOperation(io, log_path, .copy, jj_src, jj_dest, "error: cp failed");
            return error.ProcessFailed;
        }
        try oplog.logOperation(io, log_path, .copy, jj_src, jj_dest, "ok");

        try rewriteJjGitTarget(gpa, io, jj_dest, git_dest);

        try Dir.cwd().deleteTree(io, jj_src);
        try oplog.logOperation(io, log_path, .remove, jj_src, "", "ok");

        try Dir.symLinkAbsolute(io, jj_dest, jj_src, .{ .is_directory = true });
        try oplog.logOperation(io, log_path, .create_symlink, jj_src, jj_dest, "ok");
        info(io, "symlink: {s} -> {s}\n", .{ jj_src, jj_dest });
    } else {
        info(io, "init: jj colocated in {s}\n", .{repo_path});
        const jj_init = try ex.exec(gpa, io, &.{ "jj", "git", "init", "--colocate" }, repo_path);
        defer {
            gpa.free(jj_init.stdout);
            gpa.free(jj_init.stderr);
        }
        if (jj_init.succeeded()) {
            try oplog.logOperation(io, log_path, .init_jj, repo_path, "", "ok");

            const jj_check = Dir.cwd().statFile(io, jj_src, .{}) catch null;
            if (jj_check != null) {
                const jj_cp2 = try ex.exec(gpa, io, &.{ "cp", "-a", jj_src, jj_dest }, null);
                gpa.free(jj_cp2.stdout);
                gpa.free(jj_cp2.stderr);
                if (jj_cp2.succeeded()) {
                    try rewriteJjGitTarget(gpa, io, jj_dest, git_dest);
                    try Dir.cwd().deleteTree(io, jj_src);
                    try Dir.symLinkAbsolute(io, jj_dest, jj_src, .{ .is_directory = true });
                    try oplog.logOperation(io, log_path, .create_symlink, jj_src, jj_dest, "ok");
                    info(io, "symlink: {s} -> {s}\n", .{ jj_src, jj_dest });
                }
            }
        } else {
            try oplog.logOperation(io, log_path, .init_jj, repo_path, "", "error: jj init failed");
            warn(io, "warn: jj init failed (non-fatal): {s}\n", .{jj_init.stderr});
        }
    }
}

/// Adopt all repos under ghq root.
pub fn adoptAll(
    gpa: Allocator,
    io: Io,
    ghq_root: []const u8,
    gitstore_root: []const u8,
    dry_run: bool,
) !void {
    var adopted: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;

    const list_result = try ex.exec(gpa, io, &.{ "ghq", "list", "--full-path" }, null);
    defer {
        gpa.free(list_result.stdout);
        gpa.free(list_result.stderr);
    }
    if (!list_result.succeeded()) {
        warn(io, "error: ghq list failed\n", .{});
        return error.ProcessFailed;
    }

    var lines = std.mem.splitScalar(u8, ex.trimTrailingNewline(list_result.stdout), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        if (isAdopted(io, line, gpa)) {
            skipped += 1;
            continue;
        }

        adopt(gpa, io, line, ghq_root, gitstore_root, dry_run) catch {
            failed += 1;
            continue;
        };
        adopted += 1;
    }

    if (dry_run) {
        info(io, "\ndry-run summary: {d} would adopt, {d} already adopted, {d} failed\n", .{ adopted, skipped, failed });
    } else {
        info(io, "\nsummary: {d} adopted, {d} skipped, {d} failed\n", .{ adopted, skipped, failed });
    }
}

/// Verify a single repo's gitstore integrity.
pub fn verify(
    gpa: Allocator,
    io: Io,
    repo_path: []const u8,
) !bool {
    var ok = true;

    const git_path = try std.fmt.allocPrint(gpa, "{s}/.git", .{repo_path});
    defer gpa.free(git_path);

    const content = Dir.cwd().readFileAlloc(io, git_path, gpa, .unlimited) catch |err| switch (err) {
        error.IsDir => {
            warn(io, "FAIL: {s}/.git is a directory (not adopted)\n", .{repo_path});
            return false;
        },
        else => {
            warn(io, "FAIL: {s}/.git not found\n", .{repo_path});
            return false;
        },
    };
    defer gpa.free(content);

    const trimmed = ex.trimTrailingNewline(content);
    if (!std.mem.startsWith(u8, trimmed, "gitdir: ")) {
        warn(io, "FAIL: {s}/.git is not a valid gitdir pointer\n", .{repo_path});
        return false;
    }
    const git_dir = trimmed["gitdir: ".len..];

    _ = Dir.cwd().statFile(io, git_dir, .{}) catch {
        warn(io, "FAIL: gitdir target does not exist: {s}\n", .{git_dir});
        ok = false;
    };

    {
        const git_result = try ex.exec(gpa, io, &.{ "git", "-C", repo_path, "rev-parse", "--git-dir" }, null);
        defer {
            gpa.free(git_result.stdout);
            gpa.free(git_result.stderr);
        }
        if (!git_result.succeeded()) {
            warn(io, "FAIL: git rev-parse --git-dir failed in {s}\n", .{repo_path});
            ok = false;
        }
    }

    const jj_path = try std.fmt.allocPrint(gpa, "{s}/.jj", .{repo_path});
    defer gpa.free(jj_path);

    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const link_len = Dir.readLinkAbsolute(io, jj_path, &link_buf) catch |err| switch (err) {
        error.FileNotFound => {
            if (ok) info(io, "OK: {s} (no .jj)\n", .{repo_path});
            return ok;
        },
        else => {
            warn(io, "FAIL: {s}/.jj is not a symlink\n", .{repo_path});
            return false;
        },
    };
    const link_target = link_buf[0..link_len];

    _ = Dir.cwd().statFile(io, link_target, .{}) catch {
        warn(io, "FAIL: .jj symlink target does not exist: {s}\n", .{link_target});
        ok = false;
    };

    {
        const jj_result = try ex.exec(gpa, io, &.{ "jj", "status", "-R", repo_path }, null);
        defer {
            gpa.free(jj_result.stdout);
            gpa.free(jj_result.stderr);
        }
        if (!jj_result.succeeded()) {
            warn(io, "FAIL: jj status failed in {s}\n", .{repo_path});
            ok = false;
        }
    }

    if (ok) info(io, "OK: {s}\n", .{repo_path});

    return ok;
}

/// Verify all repos under ghq root.
pub fn verifyAll(
    gpa: Allocator,
    io: Io,
    ghq_root: []const u8,
) !void {
    _ = ghq_root;
    var ok_count: usize = 0;
    var fail_count: usize = 0;

    const list_result = try ex.exec(gpa, io, &.{ "ghq", "list", "--full-path" }, null);
    defer {
        gpa.free(list_result.stdout);
        gpa.free(list_result.stderr);
    }
    if (!list_result.succeeded()) return error.ProcessFailed;

    var lines = std.mem.splitScalar(u8, ex.trimTrailingNewline(list_result.stdout), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (!isAdopted(io, line, gpa)) continue;

        const is_ok = try verify(gpa, io, line);
        if (is_ok) ok_count += 1 else fail_count += 1;
    }

    info(io, "\nverify: {d} ok, {d} failed\n", .{ ok_count, fail_count });
}

/// Show gitstore disk usage, repo count, and broken pointers.
pub fn status(
    gpa: Allocator,
    io: Io,
    ghq_root: []const u8,
    gitstore_root: []const u8,
    json_mode: bool,
) !void {
    _ = ghq_root;

    const du_result = try ex.exec(gpa, io, &.{ "du", "-sh", gitstore_root }, null);
    defer {
        gpa.free(du_result.stdout);
        gpa.free(du_result.stderr);
    }
    const du_line = ex.trimTrailingNewline(du_result.stdout);
    var du_parts = std.mem.splitScalar(u8, du_line, '\t');
    const disk_usage = du_parts.next() orelse "unknown";

    const list_result = try ex.exec(gpa, io, &.{ "ghq", "list", "--full-path" }, null);
    defer {
        gpa.free(list_result.stdout);
        gpa.free(list_result.stderr);
    }

    var total_repos: usize = 0;
    var adopted_count: usize = 0;
    var broken_count: usize = 0;

    if (list_result.succeeded()) {
        var lines = std.mem.splitScalar(u8, ex.trimTrailingNewline(list_result.stdout), '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            total_repos += 1;
            if (isAdopted(io, line, gpa)) {
                adopted_count += 1;
                const git_path = std.fmt.allocPrint(gpa, "{s}/.git", .{line}) catch continue;
                defer gpa.free(git_path);
                const content = Dir.cwd().readFileAlloc(io, git_path, gpa, .unlimited) catch continue;
                defer gpa.free(content);
                const trimmed = ex.trimTrailingNewline(content);
                if (std.mem.startsWith(u8, trimmed, "gitdir: ")) {
                    const git_dir = trimmed["gitdir: ".len..];
                    _ = Dir.cwd().statFile(io, git_dir, .{}) catch {
                        broken_count += 1;
                    };
                }
            }
        }
    }

    if (json_mode) {
        info(io,
            \\{{"disk_usage":"{s}","gitstore_root":"{s}","total_repos":{d},"adopted":{d},"broken":{d}}}
            ++ "\n", .{ disk_usage, gitstore_root, total_repos, adopted_count, broken_count });
    } else {
        info(io, "gitstore: {s}\n", .{gitstore_root});
        info(io, "disk usage: {s}\n", .{disk_usage});
        info(io, "total repos: {d}\n", .{total_repos});
        info(io, "adopted: {d}\n", .{adopted_count});
        if (broken_count > 0) {
            info(io, "broken pointers: {d}\n", .{broken_count});
        }
    }
}

/// Write the rclone filter file to gitstore root and run rclone sync.
pub fn sync(
    gpa: Allocator,
    io: Io,
    ghq_root: []const u8,
    gitstore_root: []const u8,
    remote: []const u8,
    dry_run: bool,
) !void {
    const hooks = @import("hooks.zig");

    // Write filter file
    const filter_path = try std.fmt.allocPrint(gpa, "{s}/rclone-filter.txt", .{gitstore_root});
    defer gpa.free(filter_path);
    try Dir.cwd().writeFile(io, .{
        .sub_path = filter_path,
        .data = hooks.rclone_filter,
    });
    info(io, "filter: {s}\n", .{filter_path});

    // Build rclone command
    if (dry_run) {
        info(io, "dry-run: rclone sync {s} {s} --filter-from {s} --dry-run\n", .{ ghq_root, remote, filter_path });
        const result = try ex.exec(gpa, io, &.{
            "rclone", "sync",
            ghq_root, remote,
            "--filter-from", filter_path,
            "--dry-run",
            "-v",
        }, null);
        defer {
            gpa.free(result.stdout);
            gpa.free(result.stderr);
        }
        info(io, "{s}", .{result.stdout});
        if (result.stderr.len > 0) info(io, "{s}", .{result.stderr});
    } else {
        info(io, "sync: {s} -> {s}\n", .{ ghq_root, remote });
        const result = try ex.exec(gpa, io, &.{
            "rclone", "sync",
            ghq_root, remote,
            "--filter-from", filter_path,
            "-v",
            "--stats-one-line",
        }, null);
        defer {
            gpa.free(result.stdout);
            gpa.free(result.stderr);
        }
        if (!result.succeeded()) {
            warn(io, "error: rclone sync failed\n{s}\n", .{result.stderr});
            return error.ProcessFailed;
        }
        info(io, "{s}", .{result.stderr}); // rclone stats go to stderr
    }
}
