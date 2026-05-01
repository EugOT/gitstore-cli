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
    NotAdopted,
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

/// Determine the gitstore subpath for a repo relative to ghq root.
/// Returns null if repo is not under ghq root.
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

/// Determine gitstore storage path for any absolute repo path.
/// - If under ghq_root, returns the ghq-relative path (e.g. "github.com/Org/repo").
/// - Otherwise returns the absolute path with leading "/" stripped (e.g. "Users/x/dabest_neuropeptides").
/// Returns null only if repo_path is not absolute.
pub fn repoStoragePath(repo_path: []const u8, ghq_root: []const u8) ?[]const u8 {
    if (repoRelativePath(repo_path, ghq_root)) |rel| return rel;
    if (repo_path.len > 1 and repo_path[0] == '/') return repo_path[1..];
    return null;
}

/// Check if a repo is already adopted: .git is a pointer file with gitdir target inside gitstore_root.
pub fn isAdopted(io: Io, repo_path: []const u8, gitstore_root: []const u8, gpa: Allocator) bool {
    const git_path = std.fmt.allocPrint(gpa, "{s}/.git", .{repo_path}) catch return false;
    defer gpa.free(git_path);

    const content = Dir.cwd().readFileAlloc(io, git_path, gpa, .unlimited) catch |err| switch (err) {
        error.IsDir => return false,
        else => return false,
    };
    defer gpa.free(content);
    if (!std.mem.startsWith(u8, content, "gitdir:")) return false;
    // Must be a gitstore pointer, not a normal linked worktree pointer.
    // Enforce path-boundary match: "/a/store-old" must not match root "/a/store".
    const trimmed = ex.trimTrailingNewline(content);
    const prefix = "gitdir: ";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return false;
    const gitdir = trimmed[prefix.len..];
    // Strip trailing slashes from the root for comparison
    var root = gitstore_root;
    while (root.len > 1 and root[root.len - 1] == '/') root = root[0 .. root.len - 1];
    if (!std.mem.startsWith(u8, gitdir, root)) return false;
    // Require exactly-equal or next char must be '/'
    return gitdir.len == root.len or gitdir[root.len] == '/';
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
    Dir.cwd().createDirPath(io, repo_path) catch |err| {
        warn(io, "error: cannot create directory {s}: {s}\n", .{ repo_path, @errorName(err) });
        return err;
    };

    if (isAdopted(io, repo_path, gitstore_root, gpa)) {
        info(io, "skip: {s} (already adopted)\n", .{repo_path});
        return;
    }

    const git_path = try std.fmt.allocPrint(gpa, "{s}/.git", .{repo_path});
    defer gpa.free(git_path);

    // Treat .git as "present" whether it's a directory OR a pointer file
    // (a linked worktree or submodule has .git as a file — still a real repo).
    const has_git = blk: {
        var dir = Dir.openDirAbsolute(io, git_path, .{}) catch |err| switch (err) {
            error.NotDir => break :blk true, // .git is a pointer file — a real repo
            error.FileNotFound => break :blk false,
            else => break :blk false,
        };
        dir.close(io);
        break :blk true;
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
    }) catch {
        warn(io, "warn: could not rewrite jj git_target at {s}\n", .{git_target_path});
    };
}

/// Rewrite .jj/repo/store/git_target back to the relative path used by a colocated
/// jj repo when .jj lives next to .git in the working tree.
pub fn rewriteJjGitTargetRelative(gpa: Allocator, io: Io, jj_dir: []const u8) !void {
    const git_target_path = try std.fmt.allocPrint(gpa, "{s}/repo/store/git_target", .{jj_dir});
    defer gpa.free(git_target_path);
    Dir.cwd().writeFile(io, .{
        .sub_path = git_target_path,
        .data = "../../../.git",
    }) catch {
        warn(io, "warn: could not rewrite jj git_target at {s}\n", .{git_target_path});
    };
}

/// Enumerate linked worktrees of a repo by calling `git worktree list --porcelain`.
/// Returns heap-allocated slice of absolute paths of LINKED worktrees only (excludes the main).
/// Caller frees each path and the outer slice via `freeWorktreePaths`.
pub fn enumerateLinkedWorktrees(gpa: Allocator, io: Io, repo_path: []const u8) ![][]u8 {
    const result = try ex.exec(gpa, io, &.{ "git", "-C", repo_path, "worktree", "list", "--porcelain" }, null);
    defer {
        gpa.free(result.stdout);
        gpa.free(result.stderr);
    }
    if (!result.succeeded()) return error.ProcessFailed;

    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |p| gpa.free(p);
        list.deinit(gpa);
    }

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "worktree ")) continue;
        const path = line["worktree ".len..];
        if (first) {
            first = false; // skip main worktree
            continue;
        }
        const owned = try gpa.dupe(u8, path);
        try list.append(gpa, owned);
    }
    return try list.toOwnedSlice(gpa);
}

pub fn freeWorktreePaths(gpa: Allocator, paths: [][]u8) void {
    for (paths) |p| gpa.free(p);
    gpa.free(paths);
}

/// Rewrite a linked worktree's .git pointer file to use a new main-.git location.
/// Extracts the worktree name from the existing pointer, so this works for any
/// target main-.git path (gitstore or original).
fn rewriteLinkedWorktreePointer(
    gpa: Allocator,
    io: Io,
    linked_wt_path: []const u8,
    new_main_git: []const u8,
) !void {
    const wt_git_file = try std.fmt.allocPrint(gpa, "{s}/.git", .{linked_wt_path});
    defer gpa.free(wt_git_file);

    const content = Dir.cwd().readFileAlloc(io, wt_git_file, gpa, .unlimited) catch |err| {
        warn(io, "warn: cannot read {s}: {s}\n", .{ wt_git_file, @errorName(err) });
        return err;
    };
    defer gpa.free(content);

    const trimmed = ex.trimTrailingNewline(content);
    const prefix = "gitdir: ";
    if (!std.mem.startsWith(u8, trimmed, prefix)) {
        warn(io, "warn: {s} is not a gitdir pointer\n", .{wt_git_file});
        return error.NotAGitRepo;
    }
    const old_target = trimmed[prefix.len..];
    // Extract worktree name (last path component)
    var name_start: usize = old_target.len;
    while (name_start > 0 and old_target[name_start - 1] != '/') name_start -= 1;
    const name = old_target[name_start..];

    const new_pointer = try std.fmt.allocPrint(gpa, "gitdir: {s}/worktrees/{s}\n", .{ new_main_git, name });
    defer gpa.free(new_pointer);
    try Dir.cwd().writeFile(io, .{ .sub_path = wt_git_file, .data = new_pointer });
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
    const rel_path = repoStoragePath(repo_path, ghq_root) orelse {
        warn(io, "error: {s} is not an absolute path\n", .{repo_path});
        return error.InvalidGhqRoot;
    };

    if (isAdopted(io, repo_path, gitstore_root, gpa)) {
        info(io, "skip: {s} (already adopted)\n", .{repo_path});
        return;
    }

    const git_src = try std.fmt.allocPrint(gpa, "{s}/.git", .{repo_path});
    defer gpa.free(git_src);
    {
        // Verify .git is a directory. openDir fails with NotDir if it's a file.
        var dir = Dir.openDirAbsolute(io, git_src, .{}) catch |err| switch (err) {
            error.NotDir => {
                warn(io, "error: {s}/.git is a file (likely a linked worktree or submodule); adopt the main repo instead\n", .{repo_path});
                return error.NotAGitRepo;
            },
            else => {
                warn(io, "error: {s} has no .git directory\n", .{repo_path});
                return error.NotAGitRepo;
            },
        };
        dir.close(io);
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

    // --- Step 0: Enumerate linked worktrees BEFORE moving .git/ ---
    const worktrees: [][]u8 = enumerateLinkedWorktrees(gpa, io, repo_path) catch |err| blk: {
        warn(io, "warn: could not enumerate worktrees ({s})\n", .{@errorName(err)});
        break :blk try gpa.alloc([]u8, 0);
    };
    defer freeWorktreePaths(gpa, worktrees);
    if (worktrees.len > 0) {
        info(io, "found {d} linked worktree(s)\n", .{worktrees.len});
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
    Dir.cwd().writeFile(io, .{ .sub_path = git_src, .data = pointer_content }) catch |err| {
        // Critical: .git deleted but pointer write failed. Restore from gitstore copy.
        warn(io, "error: pointer write failed, restoring .git from gitstore copy\n", .{});
        const restore = ex.exec(gpa, io, &.{ "cp", "-a", git_dest, git_src }, null) catch {
            warn(io, "CRITICAL: restore exec failed — .git at {s}, pointer missing\n", .{git_dest});
            return err;
        };
        defer {
            gpa.free(restore.stdout);
            gpa.free(restore.stderr);
        }
        if (!restore.succeeded()) {
            warn(io, "CRITICAL: restore cp exited non-zero — .git at {s}, pointer missing: {s}\n", .{ git_dest, restore.stderr });
            return err;
        }
        // Remove the gitstore copy since we restored the original
        Dir.cwd().deleteTree(io, git_dest) catch {};
        return err;
    };
    try oplog.logOperation(io, log_path, .write_pointer, git_src, git_dest, "ok");
    info(io, "pointer: {s} -> {s}\n", .{ git_src, git_dest });

    // --- Step 4b: Rewrite linked worktree .git pointers ---
    for (worktrees) |wt| {
        rewriteLinkedWorktreePointer(gpa, io, wt, git_dest) catch |err| {
            warn(io, "warn: could not rewrite worktree pointer at {s}: {s}\n", .{ wt, @errorName(err) });
            try oplog.logOperation(io, log_path, .write_pointer, wt, git_dest, "error: worktree rewrite failed");
            continue;
        };
        try oplog.logOperation(io, log_path, .write_pointer, wt, git_dest, "ok: worktree");
        info(io, "worktree: {s}/.git -> {s}/worktrees/...\n", .{ wt, git_dest });
    }

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

        if (isAdopted(io, line, gitstore_root, gpa)) {
            skipped += 1;
            continue;
        }

        adopt(gpa, io, line, ghq_root, gitstore_root, dry_run) catch |err| {
            warn(io, "error: failed to adopt {s}: {s}\n", .{ line, @errorName(err) });
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

/// Verify all adopted repos under ghq root.
pub fn verifyAll(
    gpa: Allocator,
    io: Io,
    ghq_root: []const u8,
    gitstore_root: []const u8,
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
        if (!isAdopted(io, line, gitstore_root, gpa)) continue;

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
            if (isAdopted(io, line, gitstore_root, gpa)) {
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

/// Create a uniquely-named filter file under /tmp using O_CREAT|O_EXCL
/// (`exclusive = true`) and write the supplied contents to it. Returns the
/// caller-owned absolute path. Retries on EPATHALREADYEXISTS / collisions
/// with a fresh random suffix; bails after a small bound to avoid a poisoned
/// tmp directory becoming an infinite loop.
fn createExclusiveFilterTmp(gpa: Allocator, io: Io, contents: []const u8) ![]u8 {
    var attempt: u32 = 0;
    while (attempt < 64) : (attempt += 1) {
        const ns = Io.Clock.real.now(io).nanoseconds;
        const path = try std.fmt.allocPrint(
            gpa,
            "/tmp/gitstore-rclone-filter.dryrun.{d}.{d}.txt",
            .{ ns, attempt },
        );

        var file = Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                gpa.free(path);
                continue;
            },
            else => |e| {
                gpa.free(path);
                return e;
            },
        };
        // Clean up file + heap-allocated path on write failures. errdefer
        // only runs on error returns, so a successful `return path` transfers
        // ownership cleanly without unlinking.
        defer file.close(io);
        errdefer {
            Dir.cwd().deleteFile(io, path) catch {};
            gpa.free(path);
        }

        var buf: [4096]u8 = undefined;
        var w = file.writerStreaming(io, &buf);
        try w.interface.writeAll(contents);
        try w.flush();
        return path;
    }
    return error.TempFileCollision;
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

    // Ensure gitstore root exists
    try init(io, gitstore_root);

    // Write filter file. For dry-run, use an exclusively-created temp file
    // (O_CREAT|O_EXCL) under /tmp so concurrent dry-runs on a shared host
    // can't race or collide. For real syncs, write the canonical
    // <gitstore_root>/rclone-filter.txt path.
    const filter_path = if (dry_run)
        try createExclusiveFilterTmp(gpa, io, hooks.rclone_filter)
    else blk: {
        const p = try std.fmt.allocPrint(gpa, "{s}/rclone-filter.txt", .{gitstore_root});
        try Dir.cwd().writeFile(io, .{ .sub_path = p, .data = hooks.rclone_filter });
        break :blk p;
    };
    defer gpa.free(filter_path);
    info(io, "filter: {s}\n", .{filter_path});
    defer if (dry_run) {
        Dir.cwd().deleteFile(io, filter_path) catch {};
    };

    // Build rclone command
    if (dry_run) {
        info(io, "dry-run: rclone sync {s} {s} --filter-from {s} --dry-run\n", .{ ghq_root, remote, filter_path });
        const result = try ex.exec(gpa, io, &.{
            "rclone",        "sync",
            ghq_root,        remote,
            "--filter-from", filter_path,
            "--dry-run",     "-v",
        }, null);
        defer {
            gpa.free(result.stdout);
            gpa.free(result.stderr);
        }
        if (!result.succeeded()) {
            warn(io, "error: rclone dry-run failed\n{s}\n", .{result.stderr});
            return error.ProcessFailed;
        }
        info(io, "{s}", .{result.stdout});
        if (result.stderr.len > 0) info(io, "{s}", .{result.stderr});
    } else {
        info(io, "sync: {s} -> {s}\n", .{ ghq_root, remote });
        const result = try ex.exec(gpa, io, &.{
            "rclone",        "sync",
            ghq_root,        remote,
            "--filter-from", filter_path,
            "-v",            "--stats-one-line",
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

/// Detach an adopted repo: restore .git/.jj from gitstore to working tree,
/// rewrite linked worktree pointers back, optionally archive the gitstore entry.
/// `ghq_root` is kept for API symmetry with adopt() but is not needed for detach
/// (the gitstore location is encoded in the pointer file).
pub fn detach(
    gpa: Allocator,
    io: Io,
    repo_path: []const u8,
    ghq_root: []const u8,
    gitstore_root: []const u8,
    dry_run: bool,
    keep_backup: bool,
) !void {
    _ = ghq_root;

    if (!isAdopted(io, repo_path, gitstore_root, gpa)) {
        warn(io, "error: {s} is not adopted into {s}\n", .{ repo_path, gitstore_root });
        return error.NotAdopted;
    }

    const git_pointer_path = try std.fmt.allocPrint(gpa, "{s}/.git", .{repo_path});
    defer gpa.free(git_pointer_path);

    // Read the pointer to discover the gitstore location
    const pointer_content = try Dir.cwd().readFileAlloc(io, git_pointer_path, gpa, .unlimited);
    defer gpa.free(pointer_content);
    const trimmed = ex.trimTrailingNewline(pointer_content);
    const prefix = "gitdir: ";
    const git_src = trimmed[prefix.len..]; // e.g. /gitstore/.../git

    // Validate that git_src has the canonical gitstore shape:
    //   "<gitstore_root>/<repo>/git"
    // We require:
    //   1. trailing "/git" segment (so we know we're looking at a git_src
    //      pointer, not e.g. the gitstore root itself);
    //   2. a slash before "<repo>" with non-empty root and non-empty repo
    //      segments (so neither slice underflows).
    // Anything else is malformed and could cause repo_store_dir to point
    // somewhere unexpected (worst case: the gitstore root, which a later
    // archive-rename would mangle).
    const git_suffix = "/git";
    if (git_src.len < git_suffix.len + 2 or !std.mem.endsWith(u8, git_src, git_suffix)) {
        warn(io, "error: gitdir pointer in {s}/.git is not a gitstore git_src (missing /git suffix): {s}\n", .{ repo_path, git_src });
        return error.GitDirMalformed;
    }
    // Slash immediately before the "git" segment.
    const repo_end = git_src.len - git_suffix.len;
    // Find the slash before "<repo>". After endsWith("/git") we know
    // git_src[repo_end] == '/'. Scan backwards to the next '/'.
    var root_end = repo_end;
    while (root_end > 0 and git_src[root_end - 1] != '/') root_end -= 1;
    // Need: non-empty root (root_end > 1, since root_end-1 is the slash and
    // we want at least one byte before it) and non-empty repo segment.
    if (root_end <= 1 or repo_end <= root_end) {
        warn(io, "error: gitdir pointer in {s}/.git is malformed: {s}\n", .{ repo_path, git_src });
        return error.GitDirMalformed;
    }
    const repo_store_dir = git_src[0..repo_end];
    const jj_src = try std.fmt.allocPrint(gpa, "{s}/jj", .{repo_store_dir});
    defer gpa.free(jj_src);

    const log_path = try std.fmt.allocPrint(gpa, "{s}/operations.log", .{gitstore_root});
    defer gpa.free(log_path);

    const jj_pointer_path = try std.fmt.allocPrint(gpa, "{s}/.jj", .{repo_path});
    defer gpa.free(jj_pointer_path);
    const has_jj_link = blk: {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        _ = Dir.readLinkAbsolute(io, jj_pointer_path, &buf) catch break :blk false;
        break :blk true;
    };

    // Enumerate linked worktrees from the gitstore git_src perspective
    const worktrees: [][]u8 = enumerateLinkedWorktrees(gpa, io, repo_path) catch |err| blk: {
        warn(io, "warn: could not enumerate worktrees ({s})\n", .{@errorName(err)});
        break :blk try gpa.alloc([]u8, 0);
    };
    defer freeWorktreePaths(gpa, worktrees);

    if (dry_run) {
        info(io, "dry-run: would detach {s}\n", .{repo_path});
        info(io, "  restore {s} -> {s}/.git\n", .{ git_src, repo_path });
        if (has_jj_link) info(io, "  restore {s} -> {s}/.jj\n", .{ jj_src, repo_path });
        for (worktrees) |wt| info(io, "  rewrite worktree pointer {s}/.git -> {s}/.git/worktrees/...\n", .{ wt, repo_path });
        if (keep_backup) {
            info(io, "  rename gitstore entry {s} -> {s}.detached-<ts>\n", .{ repo_store_dir, repo_store_dir });
        } else {
            info(io, "  remove gitstore entry {s}\n", .{repo_store_dir});
        }
        return;
    }

    // --- Step 1: Stage-copy .git back ---
    const git_new = try std.fmt.allocPrint(gpa, "{s}/.git.gs-new", .{repo_path});
    defer gpa.free(git_new);
    Dir.cwd().deleteTree(io, git_new) catch {};
    info(io, "copy: {s} -> {s}\n", .{ git_src, git_new });
    const cp = try ex.exec(gpa, io, &.{ "cp", "-a", git_src, git_new }, null);
    defer {
        gpa.free(cp.stdout);
        gpa.free(cp.stderr);
    }
    if (!cp.succeeded()) {
        warn(io, "error: cp failed: {s}\n", .{cp.stderr});
        try oplog.logOperation(io, log_path, .copy, git_src, git_new, "error: cp failed (detach)");
        Dir.cwd().deleteTree(io, git_new) catch {};
        return error.ProcessFailed;
    }
    try oplog.logOperation(io, log_path, .copy, git_src, git_new, "ok: detach stage");

    // --- Step 2: Verify staged copy ---
    const vr = try ex.exec(gpa, io, &.{ "git", "--git-dir", git_new, "rev-parse", "--git-dir" }, null);
    defer {
        gpa.free(vr.stdout);
        gpa.free(vr.stderr);
    }
    if (!vr.succeeded()) {
        warn(io, "error: staged .git verify failed\n", .{});
        Dir.cwd().deleteTree(io, git_new) catch {};
        try oplog.logOperation(io, log_path, .copy, git_src, git_new, "error: verify failed");
        return error.VerifyFailed;
    }

    // --- Step 3: Swap — delete pointer file, rename staged dir ---
    try Dir.cwd().deleteFile(io, git_pointer_path);
    try oplog.logOperation(io, log_path, .remove, git_pointer_path, "", "ok: detach pointer");
    try Dir.rename(Dir.cwd(), git_new, Dir.cwd(), git_pointer_path, io);
    try oplog.logOperation(io, log_path, .write_pointer, git_src, git_pointer_path, "ok: detach restore .git");
    info(io, "restored: {s}/.git\n", .{repo_path});

    // --- Step 4: Handle .jj ---
    if (has_jj_link) {
        const jj_new = try std.fmt.allocPrint(gpa, "{s}/.jj.gs-new", .{repo_path});
        defer gpa.free(jj_new);
        Dir.cwd().deleteTree(io, jj_new) catch {};
        info(io, "copy: {s} -> {s}\n", .{ jj_src, jj_new });
        const jcp = try ex.exec(gpa, io, &.{ "cp", "-aL", jj_src, jj_new }, null);
        gpa.free(jcp.stdout);
        gpa.free(jcp.stderr);
        if (jcp.succeeded()) {
            // Rename the symlink aside first — do NOT delete it until the new .jj is in place.
            const jj_backup = try std.fmt.allocPrint(gpa, "{s}/.jj.gs-old", .{repo_path});
            defer gpa.free(jj_backup);
            Dir.rename(Dir.cwd(), jj_pointer_path, Dir.cwd(), jj_backup, io) catch |err| {
                warn(io, "warn: could not rename .jj symlink ({s}); leaving symlink in place\n", .{@errorName(err)});
                Dir.cwd().deleteTree(io, jj_new) catch {};
                return;
            };
            // Now rename staged copy into place. On failure restore the symlink.
            Dir.rename(Dir.cwd(), jj_new, Dir.cwd(), jj_pointer_path, io) catch |err| {
                warn(io, "error: rename staged .jj failed ({s}); restoring symlink\n", .{@errorName(err)});
                Dir.rename(Dir.cwd(), jj_backup, Dir.cwd(), jj_pointer_path, io) catch {};
                Dir.cwd().deleteTree(io, jj_new) catch {};
                return err;
            };
            // Success — delete the old symlink backup.
            Dir.cwd().deleteFile(io, jj_backup) catch {};
            try rewriteJjGitTargetRelative(gpa, io, jj_pointer_path);
            try oplog.logOperation(io, log_path, .create_symlink, jj_src, jj_pointer_path, "ok: detach restore .jj");
            info(io, "restored: {s}/.jj\n", .{repo_path});
        } else {
            warn(io, "warn: cp .jj failed; leaving symlink in place\n", .{});
            Dir.cwd().deleteTree(io, jj_new) catch {};
        }
    }

    // --- Step 5: Rewrite linked worktree pointers back ---
    const restored_git = try std.fmt.allocPrint(gpa, "{s}/.git", .{repo_path});
    defer gpa.free(restored_git);
    for (worktrees) |wt| {
        rewriteLinkedWorktreePointer(gpa, io, wt, restored_git) catch |err| {
            warn(io, "warn: could not rewrite worktree pointer {s}: {s}\n", .{ wt, @errorName(err) });
            continue;
        };
        try oplog.logOperation(io, log_path, .write_pointer, wt, restored_git, "ok: detach worktree");
        info(io, "worktree: {s}/.git -> {s}/worktrees/...\n", .{ wt, restored_git });
    }

    // --- Step 6: Archive or remove gitstore entry ---
    if (keep_backup) {
        var ts_buf: [30]u8 = undefined;
        const ts = oplog.timestamp(io, &ts_buf);
        // Use nanosecond clock for uniqueness — archives in the same second never collide
        const ns_raw = Io.Clock.real.now(io).nanoseconds;
        const ns_sub: u64 = @intCast(@mod(ns_raw, 1_000_000_000));
        const archived = try std.fmt.allocPrint(
            gpa,
            "{s}.detached-{s}-{d:0>9}",
            .{ repo_store_dir, ts, ns_sub },
        );
        defer gpa.free(archived);
        Dir.rename(Dir.cwd(), repo_store_dir, Dir.cwd(), archived, io) catch |err| {
            warn(io, "warn: could not archive gitstore entry ({s}); left in place\n", .{@errorName(err)});
        };
        try oplog.logOperation(io, log_path, .remove, repo_store_dir, archived, "ok: detach archived");
        info(io, "archived: {s} -> {s}\n", .{ repo_store_dir, archived });
    } else {
        Dir.cwd().deleteTree(io, repo_store_dir) catch |err| {
            warn(io, "warn: could not remove gitstore entry ({s})\n", .{@errorName(err)});
        };
        try oplog.logOperation(io, log_path, .remove, repo_store_dir, "", "ok: detach removed");
        info(io, "removed gitstore entry: {s}\n", .{repo_store_dir});
    }
}

/// Detach all adopted repos under ghq root.
pub fn detachAll(
    gpa: Allocator,
    io: Io,
    ghq_root: []const u8,
    gitstore_root: []const u8,
    dry_run: bool,
    keep_backup: bool,
) !void {
    var detached: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;

    const list_result = try ex.exec(gpa, io, &.{ "ghq", "list", "--full-path" }, null);
    defer {
        gpa.free(list_result.stdout);
        gpa.free(list_result.stderr);
    }
    if (!list_result.succeeded()) return error.ProcessFailed;

    var lines = std.mem.splitScalar(u8, ex.trimTrailingNewline(list_result.stdout), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (!isAdopted(io, line, gitstore_root, gpa)) {
            skipped += 1;
            continue;
        }
        detach(gpa, io, line, ghq_root, gitstore_root, dry_run, keep_backup) catch |err| {
            warn(io, "error: failed to detach {s}: {s}\n", .{ line, @errorName(err) });
            failed += 1;
            continue;
        };
        detached += 1;
    }

    if (dry_run) {
        info(io, "\ndry-run detach summary: {d} would detach, {d} not adopted, {d} failed\n", .{ detached, skipped, failed });
    } else {
        info(io, "\ndetach summary: {d} detached, {d} not adopted, {d} failed\n", .{ detached, skipped, failed });
    }
}
