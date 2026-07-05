const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;
const Allocator = std.mem.Allocator;
const ex = @import("exec.zig");
const oplog = @import("log.zig");
const list_mod = @import("list.zig");

pub const Error = error{
    ProcessFailed,
    NotAGitRepo,
    AlreadyAdopted,
    NotAdopted,
    InvalidGhqRoot,
    VerifyFailed,
    GitDirMalformed,
    TempFileCollision,
} || Allocator.Error || ex.ExecError || Dir.WriteFileError || Dir.SymLinkError ||
    Dir.DeleteTreeError || Dir.OpenError || Dir.CreateDirPathError ||
    File.OpenError || File.StatError || Dir.ReadFileAllocError;

// Git pointer files are tiny; cap reads to avoid unbounded allocations on
// malformed repos while still allowing far more than a real pointer needs.
const max_git_pointer_file_bytes = 64 * 1024;

fn info(io: Io, comptime fmt: []const u8, args: anytype) void {
    if (builtin.is_test) return;
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

fn uniqueSidePath(gpa: Allocator, io: Io, base_path: []const u8, label: []const u8) ![]u8 {
    const ns = Io.Clock.real.now(io).nanoseconds;
    return std.fmt.allocPrint(gpa, "{s}.{s}-{d}", .{ base_path, label, ns });
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

    const content = Dir.cwd().readFileAlloc(io, git_path, gpa, .limited(max_git_pointer_file_bytes)) catch |err| switch (err) {
        error.IsDir => return false,
        error.StreamTooLong => return false,
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
            // Transient probe failures must not silently trigger `git init`
            // inside an existing repo — propagate them.
            else => return err,
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
        // #22 parity with adopt(): a missing jj binary is best-effort here
        // too — the git repo is already initialized, so continue git-only.
        const jj_init: ?ex.ExecResult = ex.exec(gpa, io, &.{ "jj", "git", "init", "--colocate" }, repo_path) catch |err| switch (err) {
            error.FileNotFound => blk: {
                warn(io, "warn: jj init unavailable (non-fatal): jj not found\n", .{});
                break :blk null;
            },
            else => return err,
        };
        if (jj_init) |ji| {
            gpa.free(ji.stdout);
            gpa.free(ji.stderr);
            if (!ji.succeeded()) {
                warn(io, "warn: jj init failed (continuing git-only)\n", .{});
            }
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
    }) catch |err| {
        warn(io, "warn: could not rewrite jj git_target at {s}: {s}\n", .{ git_target_path, @errorName(err) });
        return err;
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
    }) catch |err| {
        warn(io, "warn: could not rewrite jj git_target at {s}: {s}\n", .{ git_target_path, @errorName(err) });
        return err;
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
        errdefer gpa.free(owned);
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

    const content = Dir.cwd().readFileAlloc(io, wt_git_file, gpa, .limited(max_git_pointer_file_bytes)) catch |err| {
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
    return adoptWithJjBinary(gpa, io, repo_path, ghq_root, gitstore_root, dry_run, "jj");
}

/// Like `adopt`, but with the jj executable injected as a parameter. Production
/// callers use `adopt` (which passes `"jj"`); the explicit binary path exists
/// only so tests can exercise the spawn-failure branch by pointing at a
/// nonexistent path — no shared mutable state, safe under concurrent adopts.
pub fn adoptWithJjBinary(
    gpa: Allocator,
    io: Io,
    repo_path: []const u8,
    ghq_root: []const u8,
    gitstore_root: []const u8,
    dry_run: bool,
    jj_binary: []const u8,
) !void {
    const rel_path = repoStoragePath(repo_path, ghq_root) orelse {
        warn(io, "error: {s} is not an absolute path\n", .{repo_path});
        return error.InvalidGhqRoot;
    };

    // Round-5 hardening: parity with detach. Refuse insecure gitstore_root,
    // reject empty / "." / ".." segments, and canonicalize existing store
    // components so a symlinked ancestor cannot redirect createDirPath/cp
    // outside gitstore_root.
    var root_norm = gitstore_root;
    {
        while (root_norm.len > 1 and root_norm[root_norm.len - 1] == '/') root_norm = root_norm[0 .. root_norm.len - 1];
        if (root_norm.len < 2) {
            warn(io, "error: refusing to adopt with insecure gitstore_root: {s}\n", .{gitstore_root});
            return error.GitDirMalformed;
        }
        var comps = std.mem.splitScalar(u8, rel_path, '/');
        while (comps.next()) |seg| {
            if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) {
                warn(io, "error: rel_path has invalid segments under gitstore_root: {s}\n", .{rel_path});
                return error.GitDirMalformed;
            }
        }
    }

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
    const repo_store_dir = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ gitstore_root, rel_path });
    defer gpa.free(repo_store_dir);

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
    try Dir.cwd().createDirPath(io, root_norm);
    {
        var canon_root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var canon_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const canon_root_len = Dir.cwd().realPathFile(io, root_norm, &canon_root_buf) catch |err| {
            warn(io, "error: could not canonicalize gitstore root {s}: {s}\n", .{ root_norm, @errorName(err) });
            return error.GitDirMalformed;
        };
        const canon_root = canon_root_buf[0..canon_root_len];

        var current = try gpa.dupe(u8, root_norm);
        defer gpa.free(current);
        var comps = std.mem.splitScalar(u8, rel_path, '/');
        while (comps.next()) |seg| {
            const next = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ current, seg });
            const real_len = Dir.cwd().realPathFile(io, next, &canon_path_buf) catch |err| switch (err) {
                error.FileNotFound => {
                    gpa.free(next);
                    break;
                },
                else => {
                    warn(io, "error: could not canonicalize gitstore path {s}: {s}\n", .{ next, @errorName(err) });
                    gpa.free(next);
                    return error.GitDirMalformed;
                },
            };
            const canon_path = canon_path_buf[0..real_len];
            if (!std.mem.startsWith(u8, canon_path, canon_root) or
                canon_path.len <= canon_root.len or
                canon_path[canon_root.len] != '/')
            {
                warn(io, "error: canonicalized gitstore path {s} escapes canonicalized gitstore root {s}\n", .{ canon_path, canon_root });
                gpa.free(next);
                return error.GitDirMalformed;
            }
            gpa.free(current);
            current = next;
        }
    }
    try Dir.cwd().createDirPath(io, repo_store_dir);

    // Refuse a pre-existing store target: `cp -a` would merge into a stale
    // git dir from an earlier adopt and can silently mix refs/objects.
    if (Dir.openDirAbsolute(io, git_dest, .{})) |d| {
        var dd = d;
        dd.close(io);
        warn(io, "error: store target already exists: {s} (verify or remove it first)\n", .{git_dest});
        try oplog.logOperation(io, log_path, .copy, git_src, git_dest, "error: target exists");
        return error.AlreadyAdopted;
    } else |probe_err| switch (probe_err) {
        error.FileNotFound => {},
        error.NotDir => {
            warn(io, "error: store target exists as a file: {s}\n", .{git_dest});
            return error.GitDirMalformed;
        },
        else => return probe_err,
    }

    // --- Step 2: Copy .git to gitstore ---
    info(io, "copy: {s} -> {s}\n", .{ git_src, git_dest });
    const cp_result = try ex.exec(gpa, io, &.{ "cp", "-a", git_src, git_dest }, null);
    defer {
        gpa.free(cp_result.stdout);
        gpa.free(cp_result.stderr);
    }
    if (!cp_result.succeeded()) {
        warn(io, "error: cp failed: {s}\n", .{cp_result.stderr});
        Dir.cwd().deleteTree(io, git_dest) catch {};
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
            oplog.logOperation(io, log_path, .write_pointer, wt, git_dest, "error: worktree rewrite failed") catch |log_err| {
                warn(io, "warn: could not write operations.log entry: {s}\n", .{@errorName(log_err)});
            };
            return err;
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

        // Move the original .jj aside instead of deleting it before the
        // symlink exists — restore it on failure so there is no window
        // where the worktree has no .jj at all.
        const jj_aside = try uniqueSidePath(gpa, io, jj_src, "gs-old");
        defer gpa.free(jj_aside);
        try Dir.rename(Dir.cwd(), jj_src, Dir.cwd(), jj_aside, io);
        Dir.symLinkAbsolute(io, jj_dest, jj_src, .{ .is_directory = true }) catch |err| {
            warn(io, "error: .jj symlink failed ({s}); restoring original .jj\n", .{@errorName(err)});
            Dir.rename(Dir.cwd(), jj_aside, Dir.cwd(), jj_src, io) catch {};
            return err;
        };
        try Dir.cwd().deleteTree(io, jj_aside);
        try oplog.logOperation(io, log_path, .remove, jj_src, "", "ok");
        try oplog.logOperation(io, log_path, .create_symlink, jj_src, jj_dest, "ok");
        info(io, "symlink: {s} -> {s}\n", .{ jj_src, jj_dest });
    } else {
        info(io, "init: jj colocated in {s}\n", .{repo_path});
        const jj_init = ex.exec(gpa, io, &.{ jj_binary, "git", "init", "--colocate" }, repo_path) catch |err| switch (err) {
            // Missing jj binary (absent from PATH) is the only spawn failure
            // treated as best-effort: git-level adoption is already complete,
            // so record it and finish instead of failing the whole adoption
            // (#22) — the same leniency the non-zero-exit path below gets.
            // A failed log write must not resurrect the fatal path either.
            error.FileNotFound => {
                oplog.logOperation(io, log_path, .init_jj, repo_path, "", "error: jj spawn failed") catch |log_err| {
                    warn(io, "warn: could not write operations.log entry: {s}\n", .{@errorName(log_err)});
                };
                warn(io, "warn: jj init unavailable (non-fatal): jj not found\n", .{});
                return;
            },
            // Every other spawn failure (OutOfMemory, permission, exec
            // errors) is unexpected — propagate rather than mask it.
            else => return err,
        };
        defer {
            gpa.free(jj_init.stdout);
            gpa.free(jj_init.stderr);
        }
        if (jj_init.succeeded()) {
            try oplog.logOperation(io, log_path, .init_jj, repo_path, "", "ok");

            const jj_check = Dir.cwd().statFile(io, jj_src, .{}) catch null;
            if (jj_check != null) {
                const jj_cp2 = try ex.exec(gpa, io, &.{ "cp", "-a", jj_src, jj_dest }, null);
                defer {
                    gpa.free(jj_cp2.stdout);
                    gpa.free(jj_cp2.stderr);
                }
                if (!jj_cp2.succeeded()) {
                    warn(io, "error: cp auto-created .jj failed: {s}\n", .{jj_cp2.stderr});
                    Dir.cwd().deleteTree(io, jj_dest) catch {};
                    try oplog.logOperation(io, log_path, .copy, jj_src, jj_dest, "error: cp .jj failed");
                    return error.ProcessFailed;
                }

                rewriteJjGitTarget(gpa, io, jj_dest, git_dest) catch |err| {
                    warn(io, "error: could not rewrite optional jj git_target at {s}: {s}\n", .{ jj_dest, @errorName(err) });
                    Dir.cwd().deleteTree(io, jj_dest) catch {};
                    return err;
                };

                const jj_aside = try uniqueSidePath(gpa, io, jj_src, "gs-old");
                defer gpa.free(jj_aside);
                try Dir.rename(Dir.cwd(), jj_src, Dir.cwd(), jj_aside, io);
                Dir.symLinkAbsolute(io, jj_dest, jj_src, .{ .is_directory = true }) catch |err| {
                    warn(io, "error: auto-created .jj symlink failed ({s}); restoring original .jj\n", .{@errorName(err)});
                    Dir.rename(Dir.cwd(), jj_aside, Dir.cwd(), jj_src, io) catch {};
                    Dir.cwd().deleteTree(io, jj_dest) catch {};
                    return err;
                };
                try Dir.cwd().deleteTree(io, jj_aside);
                try oplog.logOperation(io, log_path, .create_symlink, jj_src, jj_dest, "ok");
                info(io, "symlink: {s} -> {s}\n", .{ jj_src, jj_dest });
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

    const entries = list_mod.walk(gpa, io, ghq_root, gitstore_root, .{}) catch |err| {
        warn(io, "error: ghq enumeration failed: {s}\n", .{@errorName(err)});
        return error.ProcessFailed;
    };
    defer list_mod.freeEntries(gpa, entries);

    for (entries) |e| {
        // `e.is_adopted` is precomputed by walk(); no redundant isAdopted() call.
        if (e.is_adopted) {
            skipped += 1;
            continue;
        }

        adopt(gpa, io, e.abs_path, ghq_root, gitstore_root, dry_run) catch |err| {
            warn(io, "error: failed to adopt {s}: {s}\n", .{ e.abs_path, @errorName(err) });
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

    const content = Dir.cwd().readFileAlloc(io, git_path, gpa, .limited(max_git_pointer_file_bytes)) catch |err| switch (err) {
        error.IsDir => {
            warn(io, "FAIL: {s}/.git is a directory (not adopted)\n", .{repo_path});
            return false;
        },
        error.StreamTooLong => {
            warn(io, "FAIL: {s}/.git is too large to be a gitdir pointer\n", .{repo_path});
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
    const link_len = Dir.cwd().readLink(io, jj_path, &link_buf) catch |err| switch (err) {
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

    jj_check: {
        const jj_result = ex.exec(gpa, io, &.{ "jj", "status", "-R", repo_path }, null) catch |err| switch (err) {
            error.FileNotFound => {
                warn(io, "SKIP: jj status skipped in {s} (jj not found on PATH)\n", .{repo_path});
                break :jj_check;
            },
            else => return err,
        };
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
    var ok_count: usize = 0;
    var fail_count: usize = 0;

    const entries = list_mod.walk(gpa, io, ghq_root, gitstore_root, .{}) catch return error.ProcessFailed;
    defer list_mod.freeEntries(gpa, entries);

    for (entries) |e| {
        // `e.is_adopted` is precomputed by walk(); skip non-adopted repos.
        if (!e.is_adopted) continue;

        const is_ok = try verify(gpa, io, e.abs_path);
        if (is_ok) ok_count += 1 else fail_count += 1;
    }

    info(io, "\nverify: {d} ok, {d} failed\n", .{ ok_count, fail_count });
}

/// Show gitstore disk usage, repo count, and broken pointers.
fn adoptedGitPointerBroken(gpa: Allocator, io: Io, repo_path: []const u8) bool {
    const git_path = std.fmt.allocPrint(gpa, "{s}/.git", .{repo_path}) catch return false;
    defer gpa.free(git_path);

    const content = Dir.cwd().readFileAlloc(io, git_path, gpa, .limited(max_git_pointer_file_bytes)) catch return false;
    defer gpa.free(content);

    const trimmed = ex.trimTrailingNewline(content);
    const prefix = "gitdir: ";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return false;

    const git_dir = trimmed[prefix.len..];
    _ = Dir.cwd().statFile(io, git_dir, .{}) catch return true;
    return false;
}

pub fn status(
    gpa: Allocator,
    io: Io,
    ghq_root: []const u8,
    gitstore_root: []const u8,
    json_mode: bool,
) !void {
    const du_result = try ex.exec(gpa, io, &.{ "du", "-sh", gitstore_root }, null);
    defer {
        gpa.free(du_result.stdout);
        gpa.free(du_result.stderr);
    }
    const du_line = ex.trimTrailingNewline(du_result.stdout);
    var du_parts = std.mem.splitScalar(u8, du_line, '\t');
    const disk_usage = du_parts.next() orelse "unknown";

    var total_repos: usize = 0;
    var adopted_count: usize = 0;
    var broken_count: usize = 0;

    const entries = list_mod.walk(gpa, io, ghq_root, gitstore_root, .{}) catch return error.ProcessFailed;
    defer list_mod.freeEntries(gpa, entries);

    for (entries) |e| {
        total_repos += 1;
        if (e.is_adopted) {
            adopted_count += 1;
            if (adoptedGitPointerBroken(gpa, io, e.abs_path)) broken_count += 1;
        }
    }

    if (json_mode) {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer };
        try s.beginObject();
        try s.objectField("disk_usage");
        try s.write(disk_usage);
        try s.objectField("z3store_root");
        try s.write(gitstore_root);
        try s.objectField("total_repos");
        try s.write(total_repos);
        try s.objectField("adopted");
        try s.write(adopted_count);
        try s.objectField("broken");
        try s.write(broken_count);
        try s.endObject();
        try aw.writer.writeByte('\n');
        info(io, "{s}", .{aw.written()});
    } else {
        info(io, "z3store: {s}\n", .{gitstore_root});
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
        errdefer gpa.free(p);
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
/// rewrite linked worktree pointers back, optionally archive the z3store entry.
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

    // Read the pointer to discover the gitstore location.
    // Round-6 (CR major outside-diff): re-validate the "gitdir: " prefix on
    // this second read. isAdopted() already checked the prefix on its own
    // read, but if .git is swapped or truncated between the two reads we
    // would slice past the buffer. Refusing here turns malformed input into
    // error.GitDirMalformed instead of a panic.
    const pointer_content = Dir.cwd().readFileAlloc(io, git_pointer_path, gpa, .limited(max_git_pointer_file_bytes)) catch |err| switch (err) {
        error.StreamTooLong => {
            warn(io, "error: gitdir pointer in {s}/.git is too large to be valid\n", .{repo_path});
            return error.GitDirMalformed;
        },
        else => return err,
    };
    defer gpa.free(pointer_content);
    const trimmed = ex.trimTrailingNewline(pointer_content);
    const prefix = "gitdir: ";
    if (!std.mem.startsWith(u8, trimmed, prefix)) {
        warn(io, "error: gitdir pointer in {s}/.git lost its 'gitdir: ' prefix between reads: {s}\n", .{ repo_path, trimmed });
        return error.GitDirMalformed;
    }
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
    // Defense-in-depth (CR critical post-efc8ce6): re-validate that git_src is
    // rooted under the configured gitstore_root and that no path component is
    // "..", ".", or empty. Without this check, a hand-crafted gitdir pointer
    // could resolve repo_store_dir outside the store and have detach's
    // archive/remove ops mangle unrelated directories.
    var root_norm = gitstore_root;
    while (root_norm.len > 1 and root_norm[root_norm.len - 1] == '/') root_norm = root_norm[0 .. root_norm.len - 1];
    // Refuse insecure roots like "/" or "" — with such a root any absolute
    // git_src would pass the prefix check, defeating the boundary guarantee.
    if (root_norm.len < 2) {
        warn(io, "error: refusing to detach with insecure gitstore_root: {s}\n", .{gitstore_root});
        return error.GitDirMalformed;
    }
    if (!std.mem.startsWith(u8, git_src, root_norm) or
        git_src.len <= root_norm.len or
        git_src[root_norm.len] != '/')
    {
        warn(io, "error: gitdir pointer in {s}/.git escapes gitstore root: {s}\n", .{ repo_path, git_src });
        return error.GitDirMalformed;
    }
    // v0.2.2 hardening: bounds-check the rel slice.
    // The earlier `repo_end <= root_end` check uses a root_end derived by
    // scanning backward for the last '/' before /git, which can match a slash
    // INSIDE root_norm (e.g. for "/tmp/gitstore/git" root_end becomes 5 from
    // the slash in "/tmp/", not 14 from end-of-root). That left an empty repo
    // segment ("<root_norm>/git") slipping past the textual check and crashing
    // when the rel slice computes start > end. Guard explicitly here.
    if (repo_end <= root_norm.len + 1) {
        warn(io, "error: gitdir pointer in {s}/.git has empty repo segment: {s}\n", .{ repo_path, git_src });
        return error.GitDirMalformed;
    }
    {
        const rel = git_src[root_norm.len + 1 .. repo_end];
        var comps = std.mem.splitScalar(u8, rel, '/');
        while (comps.next()) |seg| {
            if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) {
                warn(io, "error: gitdir pointer in {s}/.git has invalid path components: {s}\n", .{ repo_path, git_src });
                return error.GitDirMalformed;
            }
        }
    }
    const repo_store_dir = git_src[0..repo_end];
    // Defense-in-depth (round-5, supersedes round-4 readLinkAbsolute leaf
    // check): canonicalize both gitstore_root and repo_store_dir via
    // std.fs.realpath so any symlink in the path — leaf OR ancestor — is
    // resolved before we verify the canonical repo path is still rooted
    // under the canonical gitstore root. Without this, an attacker could
    // bypass the textual ".." check by symlinking an ancestor (e.g.
    // <gitstore_root>/github.com -> /Users/victim/.ssh) so the textual
    // prefix matches but the actual on-disk path resolves elsewhere.
    {
        var canon_root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var canon_repo_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const canon_root_len = Dir.cwd().realPathFile(io, root_norm, &canon_root_buf) catch |err| {
            warn(io, "error: could not canonicalize gitstore root {s}: {s}\n", .{ root_norm, @errorName(err) });
            return error.GitDirMalformed;
        };
        const canon_root = canon_root_buf[0..canon_root_len];
        const canon_repo_len = Dir.cwd().realPathFile(io, repo_store_dir, &canon_repo_buf) catch |err| {
            warn(io, "error: could not canonicalize gitstore repo dir {s}: {s}\n", .{ repo_store_dir, @errorName(err) });
            return error.GitDirMalformed;
        };
        const canon_repo = canon_repo_buf[0..canon_repo_len];
        if (!std.mem.startsWith(u8, canon_repo, canon_root) or
            canon_repo.len <= canon_root.len or
            canon_repo[canon_root.len] != '/')
        {
            warn(io, "error: canonicalized gitdir target {s} escapes canonicalized gitstore root {s}\n", .{ canon_repo, canon_root });
            return error.GitDirMalformed;
        }
    }
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
            info(io, "  rename z3store entry {s} -> {s}.detached-<ts>\n", .{ repo_store_dir, repo_store_dir });
        } else {
            info(io, "  remove z3store entry {s}\n", .{repo_store_dir});
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

    // --- Step 3: Swap — rename pointer aside, rename staged dir, then delete aside ---
    const git_pointer_aside = try uniqueSidePath(gpa, io, git_pointer_path, "gs-old");
    defer gpa.free(git_pointer_aside);
    try Dir.rename(Dir.cwd(), git_pointer_path, Dir.cwd(), git_pointer_aside, io);
    try oplog.logOperation(io, log_path, .remove, git_pointer_path, git_pointer_aside, "ok: detach pointer aside");
    Dir.rename(Dir.cwd(), git_new, Dir.cwd(), git_pointer_path, io) catch |err| {
        warn(io, "error: restoring .git pointer after staged rename failed ({s})\n", .{@errorName(err)});
        Dir.rename(Dir.cwd(), git_pointer_aside, Dir.cwd(), git_pointer_path, io) catch {};
        Dir.cwd().deleteTree(io, git_new) catch {};
        return err;
    };
    try Dir.cwd().deleteFile(io, git_pointer_aside);
    try oplog.logOperation(io, log_path, .write_pointer, git_src, git_pointer_path, "ok: detach restore .git");
    info(io, "restored: {s}/.git\n", .{repo_path});

    // --- Step 4: Handle .jj ---
    if (has_jj_link) {
        const jj_new = try std.fmt.allocPrint(gpa, "{s}/.jj.gs-new", .{repo_path});
        defer gpa.free(jj_new);
        Dir.cwd().deleteTree(io, jj_new) catch {};
        info(io, "copy: {s} -> {s}\n", .{ jj_src, jj_new });
        const jcp = try ex.exec(gpa, io, &.{ "cp", "-aL", jj_src, jj_new }, null);
        // Freed via defer — the failure branch below still reads jcp.stderr.
        defer {
            gpa.free(jcp.stdout);
            gpa.free(jcp.stderr);
        }
        if (jcp.succeeded()) {
            // Rename the symlink aside first — do NOT delete it until the new .jj is in place.
            const jj_backup = try uniqueSidePath(gpa, io, jj_pointer_path, "gs-old");
            defer gpa.free(jj_backup);
            Dir.rename(Dir.cwd(), jj_pointer_path, Dir.cwd(), jj_backup, io) catch |err| {
                warn(io, "warn: could not rename .jj symlink ({s}); leaving symlink in place\n", .{@errorName(err)});
                Dir.cwd().deleteTree(io, jj_new) catch {};
                return err;
            };
            // Now rename staged copy into place. On failure restore the symlink.
            Dir.rename(Dir.cwd(), jj_new, Dir.cwd(), jj_pointer_path, io) catch |err| {
                warn(io, "error: rename staged .jj failed ({s}); restoring symlink\n", .{@errorName(err)});
                Dir.rename(Dir.cwd(), jj_backup, Dir.cwd(), jj_pointer_path, io) catch {};
                Dir.cwd().deleteTree(io, jj_new) catch {};
                return err;
            };
            rewriteJjGitTargetRelative(gpa, io, jj_pointer_path) catch |err| {
                warn(io, "error: rewrite restored .jj git_target failed ({s}); restoring symlink\n", .{@errorName(err)});
                Dir.cwd().deleteTree(io, jj_pointer_path) catch {};
                Dir.rename(Dir.cwd(), jj_backup, Dir.cwd(), jj_pointer_path, io) catch {};
                return err;
            };
            // Success — delete the old symlink backup.
            Dir.cwd().deleteFile(io, jj_backup) catch {};
            try oplog.logOperation(io, log_path, .create_symlink, jj_src, jj_pointer_path, "ok: detach restore .jj");
            info(io, "restored: {s}/.jj\n", .{repo_path});
        } else {
            warn(io, "error: cp .jj failed: {s}\n", .{jcp.stderr});
            Dir.cwd().deleteTree(io, jj_new) catch {};
            try oplog.logOperation(io, log_path, .copy, jj_src, jj_new, "error: cp .jj failed (detach)");
            return error.ProcessFailed;
        }
    }

    // --- Step 5: Rewrite linked worktree pointers back ---
    const restored_git = try std.fmt.allocPrint(gpa, "{s}/.git", .{repo_path});
    defer gpa.free(restored_git);
    for (worktrees) |wt| {
        rewriteLinkedWorktreePointer(gpa, io, wt, restored_git) catch |err| {
            warn(io, "warn: could not rewrite worktree pointer {s}: {s}\n", .{ wt, @errorName(err) });
            oplog.logOperation(io, log_path, .write_pointer, wt, restored_git, "error: detach worktree rewrite failed") catch |log_err| {
                warn(io, "warn: could not write operations.log entry: {s}\n", .{@errorName(log_err)});
            };
            return err;
        };
        try oplog.logOperation(io, log_path, .write_pointer, wt, restored_git, "ok: detach worktree");
        info(io, "worktree: {s}/.git -> {s}/worktrees/...\n", .{ wt, restored_git });
    }

    // --- Step 6: Archive or remove z3store entry ---
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
            warn(io, "error: could not archive z3store entry ({s}); left in place\n", .{@errorName(err)});
            try oplog.logOperation(io, log_path, .remove, repo_store_dir, archived, "error: archive failed (left in place)");
            return err;
        };
        try oplog.logOperation(io, log_path, .remove, repo_store_dir, archived, "ok: detach archived");
        info(io, "archived: {s} -> {s}\n", .{ repo_store_dir, archived });
    } else {
        Dir.cwd().deleteTree(io, repo_store_dir) catch |err| {
            warn(io, "error: could not remove z3store entry ({s})\n", .{@errorName(err)});
            try oplog.logOperation(io, log_path, .remove, repo_store_dir, "", "error: remove failed (left in place)");
            return err;
        };
        try oplog.logOperation(io, log_path, .remove, repo_store_dir, "", "ok: detach removed");
        info(io, "removed z3store entry: {s}\n", .{repo_store_dir});
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

    const entries = list_mod.walk(gpa, io, ghq_root, gitstore_root, .{}) catch return error.ProcessFailed;
    defer list_mod.freeEntries(gpa, entries);

    for (entries) |e| {
        // `e.is_adopted` is precomputed by walk(); skip non-adopted repos.
        if (!e.is_adopted) {
            skipped += 1;
            continue;
        }
        detach(gpa, io, e.abs_path, ghq_root, gitstore_root, dry_run, keep_backup) catch |err| {
            warn(io, "error: failed to detach {s}: {s}\n", .{ e.abs_path, @errorName(err) });
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
