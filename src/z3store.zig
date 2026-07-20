const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;
const Allocator = std.mem.Allocator;
const ex = @import("exec.zig");
const hooks = @import("hooks.zig");
const oplog = @import("log.zig");
const list_mod = @import("list.zig");
const url_mod = @import("url.zig");

pub const Error = error{
    ProcessFailed,
    NotAGitRepo,
    AlreadyAdopted,
    NotAdopted,
    InvalidGhqRoot,
    VerifyFailed,
    GitDirMalformed,
    TempFileCollision,
    BatchFailures,
    PartialRestore,
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
    w.interface.print(fmt, args) catch return;
    w.flush() catch return;
}

fn warn(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    var w = File.stderr().writerStreaming(io, &buf);
    w.interface.print(fmt, args) catch return;
    w.flush() catch return;
}

/// Adopt/detach policy: real filesystem/process failures propagate. Once a
/// destructive swap has started, operation-log writes are observability only:
/// warn on log failure, but never abort a half-completed swap.
fn logOperationBestEffort(
    io: Io,
    log_path: []const u8,
    action: oplog.Action,
    source: []const u8,
    destination: []const u8,
    op_status: []const u8,
) void {
    oplog.logOperation(io, log_path, action, source, destination, op_status) catch |err| {
        warn(io, "warn: could not write operations.log entry: {s}\n", .{@errorName(err)});
    };
}

/// Remove a path whose type is genuinely variable. Prefer the type-specific
/// helpers below whenever the operation created the path itself.
fn deletePathByTypeBestEffort(io: Io, path: []const u8) void {
    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (Dir.cwd().readLink(io, path, &link_buf)) |_| {
        Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => warn(io, "warn: could not delete symlink {s}: {s}\n", .{ path, @errorName(err) }),
        };
        return;
    } else |err| switch (err) {
        error.FileNotFound => return,
        else => {},
    }

    Dir.cwd().deleteTree(io, path) catch |tree_err| switch (tree_err) {
        // No FileNotFound prong: Zig 0.16 deleteTree treats a missing path
        // as success, so DeleteTreeError has no such member.
        error.NotDir => Dir.cwd().deleteFile(io, path) catch |file_err| switch (file_err) {
            error.FileNotFound => {},
            else => warn(io, "warn: could not delete file {s}: {s}\n", .{ path, @errorName(file_err) }),
        },
        else => warn(io, "warn: could not delete tree {s}: {s}\n", .{ path, @errorName(tree_err) }),
    };
}

fn deleteFileBestEffort(io: Io, path: []const u8) void {
    Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => warn(io, "warn: could not delete file {s}: {s}\n", .{ path, @errorName(err) }),
    };
}

fn deleteTreeBestEffort(io: Io, path: []const u8) void {
    Dir.cwd().deleteTree(io, path) catch |err| {
        warn(io, "warn: could not delete tree {s}: {s}\n", .{ path, @errorName(err) });
    };
}

/// Refuse an existing store leaf without following a symlink at the leaf.
/// The caller must run this before arming cleanup for paths it does not yet own.
fn requireStoreLeafAbsent(io: Io, path: []const u8) !void {
    var link_buf: [Dir.max_path_bytes]u8 = undefined;
    if (Dir.readLinkAbsolute(io, path, &link_buf)) |_| {
        warn(io, "error: store target exists as a symlink: {s} (verify or remove it first)\n", .{path});
        return error.AlreadyAdopted;
    } else |link_err| switch (link_err) {
        error.NotLink => {},
        error.FileNotFound => return,
        else => return link_err,
    }

    if (Dir.openDirAbsolute(io, path, .{})) |opened| {
        var dir = opened;
        dir.close(io);
        warn(io, "error: store target already exists: {s} (verify or remove it first)\n", .{path});
        return error.AlreadyAdopted;
    } else |probe_err| switch (probe_err) {
        error.FileNotFound => return,
        error.NotDir => {
            warn(io, "error: store target exists as a file: {s}\n", .{path});
            return error.GitDirMalformed;
        },
        else => return probe_err,
    }
}

/// Revalidate source metadata immediately before a copy/rename boundary.
/// This rejects a leaf symlink and requires a real directory.
fn requireSourceMetadataDirectory(io: Io, path: []const u8) !void {
    var link_buf: [Dir.max_path_bytes]u8 = undefined;
    if (Dir.readLinkAbsolute(io, path, &link_buf)) |_| {
        warn(io, "error: refusing source metadata symlink outside z3store containment: {s}\n", .{path});
        return error.SourceMetadataSymlink;
    } else |link_err| switch (link_err) {
        error.NotLink => {},
        error.FileNotFound => return error.FileNotFound,
        else => return link_err,
    }

    var dir = Dir.openDirAbsolute(io, path, .{}) catch |err| switch (err) {
        error.NotDir => return error.GitDirMalformed,
        else => return err,
    };
    dir.close(io);
}

/// Inspect a leaf without treating a dangling symlink as absent.
fn pathExistsNoFollow(io: Io, path: []const u8) !bool {
    var link_buf: [Dir.max_path_bytes]u8 = undefined;
    if (Dir.readLinkAbsolute(io, path, &link_buf)) |_| {
        return true;
    } else |link_err| switch (link_err) {
        error.NotLink => {},
        error.FileNotFound => return false,
        else => return link_err,
    }
    _ = Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

/// Adoption copies metadata recursively and may invoke jj against the copy.
/// Reject internal symlinks so copied Git/JJ metadata cannot route those writes
/// outside the transaction-owned trees.
fn rejectMetadataTreeSymlinks(gpa: Allocator, io: Io, root: []const u8) !void {
    var dir = try Dir.openDirAbsolute(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .sym_link) {
            warn(io, "error: refusing symlink inside metadata tree {s}: {s}\n", .{ root, entry.path });
            return error.SourceMetadataSymlink;
        }
    }
}

fn renameBestEffort(io: Io, old_path: []const u8, new_path: []const u8) void {
    Dir.rename(Dir.cwd(), old_path, Dir.cwd(), new_path, io) catch |err| {
        warn(io, "warn: could not restore {s} -> {s}: {s}\n", .{ old_path, new_path, @errorName(err) });
    };
}

fn restoreGitDirFromStoreBestEffort(gpa: Allocator, io: Io, git_src: []const u8, git_dest: []const u8) void {
    if (Dir.openDirAbsolute(io, git_src, .{})) |d| {
        var dir = d;
        dir.close(io);
    } else |err| switch (err) {
        error.FileNotFound => {},
        error.NotDir => Dir.cwd().deleteFile(io, git_src) catch |delete_err| switch (delete_err) {
            error.FileNotFound => {},
            else => warn(io, "warn: could not remove .git pointer during rollback: {s}\n", .{@errorName(delete_err)}),
        },
        else => warn(io, "warn: could not inspect .git during rollback: {s}\n", .{@errorName(err)}),
    }

    if (Dir.openDirAbsolute(io, git_src, .{})) |d| {
        var dir = d;
        dir.close(io);
        return;
    } else |_| {}

    const restore = ex.exec(gpa, io, &.{ "cp", "-a", git_dest, git_src }, null) catch |err| {
        warn(io, "CRITICAL: could not restore .git from {s}: {s}\n", .{ git_dest, @errorName(err) });
        return;
    };
    defer {
        gpa.free(restore.stdout);
        gpa.free(restore.stderr);
    }
    if (!restore.succeeded()) {
        warn(io, "CRITICAL: restore cp failed from {s}: {s}\n", .{ git_dest, restore.stderr });
    }
}

fn rollbackAdoptAfterGitSwap(
    gpa: Allocator,
    io: Io,
    git_src: []const u8,
    git_dest: []const u8,
    jj_src: []const u8,
    jj_dest: []const u8,
    repo_store_dir: []const u8,
    repo_store_preexisting: bool,
    worktrees: [][]u8,
    remove_jj_src: bool,
    retain_store_on_error: *bool,
    log_path: []const u8,
) void {
    var backup_buf: [Dir.max_path_bytes]u8 = undefined;
    const git_backup = std.fmt.bufPrint(&backup_buf, "{s}.zt-adopt-backup", .{git_src}) catch {
        warn(io, "CRITICAL: pristine .git backup path exceeds platform limit; rollback unavailable\n", .{});
        return;
    };
    if (Dir.openDirAbsolute(io, git_backup, .{})) |d| {
        var backup_dir = d;
        backup_dir.close(io);
    } else |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => {
            warn(io, "CRITICAL: could not inspect pristine .git backup {s}: {s}\n", .{ git_backup, @errorName(err) });
            return;
        },
    }

    warn(io, "error: post-adopt failure; rolling back .git swap for {s}\n", .{git_src});
    var linked_pointer_restore_failed = false;
    for (worktrees) |wt| {
        rewriteLinkedWorktreePointer(gpa, io, wt, git_src) catch |err| {
            warn(io, "warn: could not restore worktree pointer at {s}: {s}\n", .{ wt, @errorName(err) });
            linked_pointer_restore_failed = true;
        };
    }
    if (remove_jj_src) deletePathByTypeBestEffort(io, jj_src);
    deleteTreeBestEffort(io, jj_dest);
    deletePathByTypeBestEffort(io, git_src);
    Dir.rename(Dir.cwd(), git_backup, Dir.cwd(), git_src, io) catch |err| {
        warn(
            io,
            "CRITICAL: could not restore pristine .git backup {s}: {s}; falling back to store copy\n",
            .{ git_backup, @errorName(err) },
        );
        restoreGitDirFromStoreBestEffort(gpa, io, git_src, git_dest);
    };
    if (linked_pointer_restore_failed) {
        retain_store_on_error.* = true;
        warn(
            io,
            "CRITICAL: retaining backing metadata at {s} because a linked-worktree pointer could not be restored\n",
            .{git_dest},
        );
        logOperationBestEffort(
            io,
            log_path,
            .write_pointer,
            git_src,
            git_dest,
            "error: partial rollback, backing metadata retained",
        );
    } else {
        deleteTreeBestEffort(io, git_dest);
        if (!repo_store_preexisting) deleteTreeBestEffort(io, repo_store_dir);
    }
    logOperationBestEffort(io, log_path, .write_pointer, git_src, git_dest, "error: post-adopt failure, rolled back");
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

/// Format a GitHub CLI GH_REPO value from host/owner/name parts.
///
/// GitHub CLI accepts `[HOST/]OWNER/REPO`; omit the default public host so the
/// common case matches `owner/repo`, but preserve Enterprise/custom hosts.
/// Caller owns the returned slice and must free it with `gpa`.
pub const FormatGhRepoError = error{
    OutOfMemory,
    InvalidGhRepoComponent,
};

pub fn formatGhRepo(
    gpa: Allocator,
    host: []const u8,
    owner: []const u8,
    name: []const u8,
) FormatGhRepoError![]u8 {
    if (!isValidGhRepoComponent(host) or
        !isValidGhRepoComponent(owner) or
        !isValidGhRepoComponent(name))
    {
        return error.InvalidGhRepoComponent;
    }
    if (std.ascii.eqlIgnoreCase(host, "github.com")) {
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ owner, name });
    }
    return std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ host, owner, name });
}

fn isValidGhRepoComponent(component: []const u8) bool {
    if (component.len == 0) return false;
    for (component) |byte| {
        if (byte == '/' or byte == '\\' or std.ascii.isWhitespace(byte) or std.ascii.isControl(byte)) return false;
    }
    return true;
}

/// Parse a git remote URL into GitHub CLI's GH_REPO format.
/// Unsupported or malformed remotes return null instead of failing command
/// dispatch; allocation failures still propagate.
/// When non-null, caller owns the returned slice and must free it with `gpa`.
pub fn ghRepoFromRemoteUrl(gpa: Allocator, remote_url: []const u8) !?[]u8 {
    var spec = url_mod.parse(gpa, remote_url, .{}) catch |err| switch (err) {
        error.EmptyInput,
        error.InvalidFormat,
        error.MissingUser,
        error.DoubleSlash,
        error.InvalidHost,
        => return null,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer spec.deinit(gpa);
    if (spec.scheme == .file or spec.host.len == 0) return null;
    return formatGhRepo(gpa, spec.host, spec.owner, spec.name) catch |err| switch (err) {
        error.InvalidGhRepoComponent => return null,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

/// Derive GH_REPO from an absolute path under the configured ghq/z3store root.
/// Subdirectories inside a repo are accepted; only the first host/owner/name
/// components are used.
/// When non-null, caller owns the returned slice and must free it with `gpa`.
pub fn ghRepoFromGhqPath(gpa: Allocator, abs_path: []const u8, ghq_root: []const u8) !?[]u8 {
    const rel = repoRelativePath(abs_path, ghq_root) orelse return null;
    var rel_segments = std.mem.splitScalar(u8, rel, '/');
    while (rel_segments.next()) |seg| {
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return null;
    }

    var parts = std.mem.splitScalar(u8, rel, '/');
    const host = parts.next() orelse return null;
    const owner = parts.next() orelse return null;
    const name = parts.next() orelse return null;
    if (host.len == 0 or owner.len == 0 or name.len == 0) return null;
    const repo_name = if (std.mem.endsWith(u8, name, ".git"))
        name[0 .. name.len - ".git".len]
    else
        name;
    if (repo_name.len == 0) return null;
    return formatGhRepo(gpa, host, owner, repo_name) catch |err| switch (err) {
        error.InvalidGhRepoComponent => return null,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn realPathFileOrMissing(io: Io, path: []const u8, buf: []u8) !?[]const u8 {
    const len = Dir.cwd().realPathFile(io, path, buf) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    return buf[0..len];
}

fn pathUnderRootCanonical(io: Io, path: []const u8, root: []const u8) !bool {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const canon_path = (try realPathFileOrMissing(io, path, &path_buf)) orelse return false;
    const canon_root = (try realPathFileOrMissing(io, root, &root_buf)) orelse return false;
    if (canon_root.len == 1 and canon_root[0] == '/') {
        return canon_path.len > 1 and canon_path[0] == '/';
    }
    return std.mem.startsWith(u8, canon_path, canon_root) and
        canon_path.len > canon_root.len and
        canon_path[canon_root.len] == '/';
}

fn ghRepoFromCanonicalGhqPath(gpa: Allocator, io: Io, abs_path: []const u8, ghq_root: []const u8) !?[]u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const canon_path = (try realPathFileOrMissing(io, abs_path, &path_buf)) orelse return null;
    const canon_root = (try realPathFileOrMissing(io, ghq_root, &root_buf)) orelse return null;
    return ghRepoFromGhqPath(gpa, canon_path, canon_root);
}

/// Resolve GH_REPO for GitHub CLI. Prefer real git metadata when available,
/// then fall back to the ghq path shape. The fallback is what makes
/// rclone/GDrive-synced working trees without a `.git` file still usable with
/// `GH_REPO=$(zt gh-repo) gh ...`.
/// When non-null, caller owns the returned slice and must free it with `gpa`.
pub fn resolveGhRepo(
    gpa: Allocator,
    io: Io,
    abs_path: []const u8,
    ghq_root: []const u8,
) !?[]u8 {
    const path_under_ghq = try pathUnderRootCanonical(io, abs_path, ghq_root);
    var git_top = ex.exec(
        gpa,
        io,
        &.{ "git", "-C", abs_path, "rev-parse", "--show-toplevel" },
        null,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            if (!path_under_ghq) return null;
            return ghRepoFromCanonicalGhqPath(gpa, io, abs_path, ghq_root);
        },
    };
    defer git_top.deinit(gpa);
    const top_under_ghq = if (git_top.succeeded())
        try pathUnderRootCanonical(
            io,
            ex.trimTrailingNewline(git_top.stdout),
            ghq_root,
        )
    else
        false;
    if (git_top.succeeded() and (!path_under_ghq or top_under_ghq)) {
        var remote = ex.exec(
            gpa,
            io,
            &.{ "git", "-C", abs_path, "remote", "get-url", "origin" },
            null,
        ) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                if (!path_under_ghq) return null;
                return ghRepoFromCanonicalGhqPath(gpa, io, abs_path, ghq_root);
            },
        };
        defer remote.deinit(gpa);
        if (remote.succeeded()) {
            const trimmed = ex.trimTrailingNewline(remote.stdout);
            if (try ghRepoFromRemoteUrl(gpa, trimmed)) |repo| return repo;
        }
    }
    if (!path_under_ghq) return null;
    return ghRepoFromCanonicalGhqPath(gpa, io, abs_path, ghq_root);
}

/// Check if a repo is already adopted: .git is a pointer file with gitdir target inside gitstore_root.
// ziglint-ignore: Z023 - public compatibility API predates allocator-first
// ordering; changing it breaks downstream callers.
pub fn isAdopted(io: Io, repo_path: []const u8, gitstore_root: []const u8, gpa: Allocator) bool {
    return isAdoptedInternal(gpa, io, repo_path, gitstore_root);
}

fn isAdoptedInternal(gpa: Allocator, io: Io, repo_path: []const u8, gitstore_root: []const u8) bool {
    const git_path = std.fmt.allocPrint(gpa, "{s}/.git", .{repo_path}) catch return false;
    defer gpa.free(git_path);

    const content = Dir.cwd().readFileAlloc(
        io,
        git_path,
        gpa,
        .limited(max_git_pointer_file_bytes),
    ) catch |err| switch (err) {
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

fn absoluteRepoPath(gpa: Allocator, io: Io, repo_path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(repo_path)) return gpa.dupe(u8, repo_path);

    var cwd_buf: [Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try Dir.cwd().realPathFile(io, ".", &cwd_buf);
    return std.fs.path.resolve(gpa, &.{ cwd_buf[0..cwd_len], repo_path });
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

    if (isAdoptedInternal(gpa, io, repo_path, gitstore_root)) {
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
        const jj_init: ?ex.ExecResult = ex.exec(
            gpa,
            io,
            &.{ "jj", "git", "init", "--colocate" },
            repo_path,
        ) catch |err| switch (err) {
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

fn replaceJjGitTarget(
    gpa: Allocator,
    io: Io,
    jj_dest: []const u8,
    new_content: []const u8,
) !void {
    try requireSourceMetadataDirectory(io, jj_dest);
    const repo_dir = try std.fmt.allocPrint(gpa, "{s}/repo", .{jj_dest});
    defer gpa.free(repo_dir);
    try requireSourceMetadataDirectory(io, repo_dir);
    const store_dir = try std.fmt.allocPrint(gpa, "{s}/store", .{repo_dir});
    defer gpa.free(store_dir);
    try requireSourceMetadataDirectory(io, store_dir);

    const git_target_path = try std.fmt.allocPrint(gpa, "{s}/repo/store/git_target", .{jj_dest});
    defer gpa.free(git_target_path);
    var link_buf: [Dir.max_path_bytes]u8 = undefined;
    if (Dir.readLinkAbsolute(io, git_target_path, &link_buf)) |_| {
        warn(io, "warn: refusing symlinked jj git_target at {s}\n", .{git_target_path});
        return error.SourceMetadataSymlink;
    } else |link_err| switch (link_err) {
        error.NotLink => {},
        error.FileNotFound => return error.FileNotFound,
        else => return link_err,
    }
    var existing = try Dir.cwd().openFile(io, git_target_path, .{});
    defer existing.close(io);
    const target_stat = try existing.stat(io);
    if (target_stat.kind != .file) return error.GitDirMalformed;

    const temp_path = try uniqueSidePath(gpa, io, git_target_path, "zt-new");
    defer gpa.free(temp_path);
    errdefer deleteFileBestEffort(io, temp_path);
    {
        var temp = try Dir.cwd().createFile(io, temp_path, .{ .exclusive = true });
        defer temp.close(io);
        var buf: [4096]u8 = undefined;
        var writer = temp.writerStreaming(io, &buf);
        try writer.interface.writeAll(new_content);
        try writer.flush();
    }
    try Dir.rename(Dir.cwd(), temp_path, Dir.cwd(), git_target_path, io);
}

/// Rewrite .jj/repo/store/git_target to use an absolute path to the git database.
pub fn rewriteJjGitTarget(
    gpa: Allocator,
    io: Io,
    jj_dest: []const u8,
    git_dest: []const u8,
) !void {
    replaceJjGitTarget(gpa, io, jj_dest, git_dest) catch |err| {
        warn(io, "warn: could not rewrite jj git_target under {s}: {s}\n", .{ jj_dest, @errorName(err) });
        return err;
    };
}

/// Rewrite .jj/repo/store/git_target back to the relative path used by a colocated
/// jj repo when .jj lives next to .git in the working tree.
pub fn rewriteJjGitTargetRelative(gpa: Allocator, io: Io, jj_dir: []const u8) !void {
    replaceJjGitTarget(gpa, io, jj_dir, "../../../.git") catch |err| {
        warn(io, "warn: could not rewrite jj git_target under {s}: {s}\n", .{ jj_dir, @errorName(err) });
        return err;
    };
}

/// Keep the pristine recovery directory and z3store-created jj metadata out of
/// jj's Git snapshot and plain Git status without changing tracked
/// `.gitignore`. The copied Git directory owns this local exclude update; the
/// pristine adoption backup restores the original bytes on rollback.
fn ensureAdoptLocalExcludes(gpa: Allocator, io: Io, repo_path: []const u8, git_dest: []const u8) !void {
    try requireSourceMetadataDirectory(io, git_dest);
    const info_dir = try std.fmt.allocPrint(gpa, "{s}/info", .{git_dest});
    defer gpa.free(info_dir);
    try requireSourceMetadataDirectory(io, info_dir);
    const exclude_path = try std.fmt.allocPrint(gpa, "{s}/exclude", .{info_dir});
    defer gpa.free(exclude_path);
    const existing = Dir.cwd().readFileAlloc(io, exclude_path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => try gpa.dupe(u8, ""),
        else => return err,
    };
    defer gpa.free(existing);

    const separator: []const u8 = if (existing.len == 0 or existing[existing.len - 1] == '\n') "" else "\n";
    const updated = try std.fmt.allocPrint(
        gpa,
        "{s}{s}/.git.zt-adopt-backup/\n/.jj\n",
        .{ existing, separator },
    );
    defer gpa.free(updated);
    const temp_path = try uniqueSidePath(gpa, io, exclude_path, "zt-new");
    defer gpa.free(temp_path);
    errdefer deleteFileBestEffort(io, temp_path);
    {
        var temp = try Dir.cwd().createFile(io, temp_path, .{ .exclusive = true });
        defer temp.close(io);
        var buf: [4096]u8 = undefined;
        var writer = temp.writerStreaming(io, &buf);
        try writer.interface.writeAll(updated);
        try writer.flush();
    }
    try Dir.rename(Dir.cwd(), temp_path, Dir.cwd(), exclude_path, io);

    const protected_paths = [_][]const u8{ ".git.zt-adopt-backup", ".jj" };
    for (protected_paths) |path| {
        var verified = try ex.exec(gpa, io, &.{ "git", "check-ignore", "--no-index", "-q", "--", path }, repo_path);
        defer verified.deinit(gpa);
        if (!verified.succeeded()) {
            warn(io, "error: local exclude did not hide adoption metadata {s} in {s}\n", .{ path, repo_path });
            return error.VerifyFailed;
        }
    }
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
    return list.toOwnedSlice(gpa);
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

    var link_buf: [Dir.max_path_bytes]u8 = undefined;
    if (Dir.readLinkAbsolute(io, wt_git_file, &link_buf)) |_| {
        warn(io, "warn: refusing symlinked linked-worktree pointer: {s}\n", .{wt_git_file});
        return error.SourceMetadataSymlink;
    } else |link_err| switch (link_err) {
        error.NotLink => {},
        error.FileNotFound => return error.FileNotFound,
        else => return link_err,
    }
    var pointer_file = try Dir.cwd().openFile(io, wt_git_file, .{});
    defer pointer_file.close(io);
    const pointer_stat = try pointer_file.stat(io);
    if (pointer_stat.kind != .file) return error.GitDirMalformed;

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
    while (name_start > 0 and old_target[name_start - 1] != '/' and old_target[name_start - 1] != '\\') name_start -= 1;
    const name = old_target[name_start..];
    if (name.len == 0 or
        std.mem.eql(u8, name, ".") or
        std.mem.eql(u8, name, "..") or
        std.mem.indexOfAny(u8, name, "/\\") != null)
    {
        warn(io, "warn: unsafe linked-worktree metadata name in {s}\n", .{wt_git_file});
        return error.GitDirMalformed;
    }

    const new_pointer = try std.fmt.allocPrint(gpa, "gitdir: {s}/worktrees/{s}\n", .{ new_main_git, name });
    defer gpa.free(new_pointer);
    const temp_path = try uniqueSidePath(gpa, io, wt_git_file, "zt-new");
    defer gpa.free(temp_path);
    errdefer deleteFileBestEffort(io, temp_path);
    {
        var temp = try Dir.cwd().createFile(io, temp_path, .{ .exclusive = true });
        defer temp.close(io);
        var buf: [4096]u8 = undefined;
        var writer = temp.writerStreaming(io, &buf);
        try writer.interface.writeAll(new_pointer);
        try writer.flush();
    }
    try Dir.rename(Dir.cwd(), temp_path, Dir.cwd(), wt_git_file, io);
}

pub const AdoptOptions = struct {
    dry_run: bool = false,
    jj_colocate: bool = true,
    jj_binary: []const u8 = "jj",
};

/// Adopt a single repository: move .git and .jj into gitstore.
pub fn adopt(
    gpa: Allocator,
    io: Io,
    repo_path: []const u8,
    ghq_root: []const u8,
    gitstore_root: []const u8,
    dry_run: bool,
) !void {
    return adoptWithOptions(gpa, io, repo_path, ghq_root, gitstore_root, .{ .dry_run = dry_run });
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
    return adoptWithOptions(gpa, io, repo_path, ghq_root, gitstore_root, .{
        .dry_run = dry_run,
        .jj_binary = jj_binary,
    });
}

/// Adopt with an explicit policy for dry-run and optional jj initialization.
/// Existing jj metadata is always preserved; `jj_colocate = false` only
/// prevents creating new jj metadata for a git-only repository.
pub fn adoptWithOptions(
    gpa: Allocator,
    io: Io,
    repo_path: []const u8,
    ghq_root: []const u8,
    gitstore_root: []const u8,
    options: AdoptOptions,
) !void {
    const dry_run = options.dry_run;
    const jj_binary = options.jj_binary;
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

    if (isAdoptedInternal(gpa, io, repo_path, gitstore_root)) {
        info(io, "skip: {s} (already adopted)\n", .{repo_path});
        return;
    }

    const git_src = try std.fmt.allocPrint(gpa, "{s}/.git", .{repo_path});
    defer gpa.free(git_src);
    {
        var link_buf: [Dir.max_path_bytes]u8 = undefined;
        if (Dir.readLinkAbsolute(io, git_src, &link_buf)) |_| {
            warn(io, "error: refusing source .git symlink outside z3store containment: {s}\n", .{git_src});
            return error.SourceMetadataSymlink;
        } else |err| switch (err) {
            error.NotLink, error.FileNotFound => {},
            else => return err,
        }

        // Verify .git is a directory. openDir fails with NotDir if it's a file.
        var dir = Dir.openDirAbsolute(io, git_src, .{}) catch |err| switch (err) {
            error.NotDir => {
                warn(
                    io,
                    "error: {s}/.git is a file (likely a linked worktree or submodule); adopt the main repo instead\n",
                    .{repo_path},
                );
                return error.NotAGitRepo;
            },
            else => {
                warn(io, "error: {s} has no .git directory\n", .{repo_path});
                return error.NotAGitRepo;
            },
        };
        dir.close(io);
    }
    try rejectMetadataTreeSymlinks(gpa, io, git_src);

    const jj_src = try std.fmt.allocPrint(gpa, "{s}/.jj", .{repo_path});
    defer gpa.free(jj_src);
    const jj_preexisting = blk: {
        var link_buf: [Dir.max_path_bytes]u8 = undefined;
        if (Dir.readLinkAbsolute(io, jj_src, &link_buf)) |_| {
            warn(io, "error: refusing source .jj symlink outside z3store containment: {s}\n", .{jj_src});
            return error.SourceMetadataSymlink;
        } else |err| switch (err) {
            error.NotLink => {},
            error.FileNotFound => break :blk false,
            else => return err,
        }
        _ = Dir.cwd().statFile(io, jj_src, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        break :blk true;
    };
    if (jj_preexisting) try rejectMetadataTreeSymlinks(gpa, io, jj_src);

    if (options.jj_colocate) {
        if (!jj_preexisting) {
            var git_status = try ex.exec(
                gpa,
                io,
                &.{
                    "git",
                    "-c",
                    "status.showUntrackedFiles=all",
                    "status",
                    "--porcelain=v1",
                    "-z",
                    "--untracked-files=all",
                },
                repo_path,
            );
            defer git_status.deinit(gpa);
            if (!git_status.succeeded()) {
                warn(io, "error: could not verify clean git state before jj colocation at {s}\n", .{repo_path});
                return error.ProcessFailed;
            }
            if (git_status.stdout.len != 0) {
                warn(
                    io,
                    "error: refusing jj colocation for dirty repository {s}; " ++
                        "set z3store.jjColocate=false to preserve git-only state\n",
                    .{repo_path},
                );
                return error.RepositoryDirty;
            }
        }
    }

    const git_dest = try std.fmt.allocPrint(gpa, "{s}/{s}/git", .{ gitstore_root, rel_path });
    defer gpa.free(git_dest);
    const jj_dest = try std.fmt.allocPrint(gpa, "{s}/{s}/jj", .{ gitstore_root, rel_path });
    defer gpa.free(jj_dest);
    const log_path = try std.fmt.allocPrint(gpa, "{s}/operations.log", .{gitstore_root});
    defer gpa.free(log_path);
    const repo_store_dir = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ gitstore_root, rel_path });
    defer gpa.free(repo_store_dir);
    const git_backup = try std.fmt.allocPrint(gpa, "{s}.zt-adopt-backup", .{git_src});
    defer gpa.free(git_backup);
    if (try pathExistsNoFollow(io, git_backup)) {
        warn(io, "error: refusing adopt with pre-existing recovery backup: {s}\n", .{git_backup});
        return error.PathAlreadyExists;
    }

    if (dry_run) {
        info(io, "dry-run: would adopt {s}\n", .{repo_path});
        info(io, "  copy {s} -> {s}\n", .{ git_src, git_dest });
        info(io, "  write pointer {s}/.git -> gitdir: {s}\n", .{ repo_path, git_dest });

        if (jj_preexisting) {
            info(io, "  copy {s} -> {s}\n", .{ jj_src, jj_dest });
            info(io, "  symlink {s}/.jj -> {s}\n", .{ repo_path, jj_dest });
        } else if (options.jj_colocate) {
            info(io, "  init jj colocated in {s}\n", .{repo_path});
        } else {
            info(io, "  leave git-only (jj colocation disabled)\n", .{});
        }
        return;
    }

    // --- Step 0: Enumerate linked worktrees BEFORE moving .git/ ---
    const worktrees: [][]u8 = enumerateLinkedWorktrees(gpa, io, repo_path) catch |err| {
        warn(
            io,
            "error: refusing adoption because linked worktrees could not be enumerated ({s})\n",
            .{@errorName(err)},
        );
        return err;
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
            var link_buf: [Dir.max_path_bytes]u8 = undefined;
            if (Dir.readLinkAbsolute(io, next, &link_buf)) |_| {
                warn(io, "error: refusing symlinked gitstore path component: {s}\n", .{next});
                gpa.free(next);
                return error.GitDirMalformed;
            } else |link_err| switch (link_err) {
                error.NotLink => {},
                error.FileNotFound => {
                    gpa.free(next);
                    break;
                },
                else => {
                    gpa.free(next);
                    return link_err;
                },
            }
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
                warn(
                    io,
                    "error: canonicalized gitstore path {s} escapes canonicalized gitstore root {s}\n",
                    .{ canon_path, canon_root },
                );
                gpa.free(next);
                return error.GitDirMalformed;
            }
            gpa.free(current);
            current = next;
        }
    }
    const repo_store_preexisting = blk: {
        _ = Dir.cwd().statFile(io, repo_store_dir, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        break :blk true;
    };
    try Dir.cwd().createDirPath(io, repo_store_dir);

    const adopt_lock = try std.fmt.allocPrint(gpa, "{s}/.zt-adopt.lock", .{repo_store_dir});
    defer gpa.free(adopt_lock);
    Dir.cwd().createDir(io, adopt_lock, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {
            warn(io, "error: another adoption owns the repository lock: {s}\n", .{adopt_lock});
            return error.AdoptionInProgress;
        },
        else => return err,
    };
    defer deleteTreeBestEffort(io, adopt_lock);

    // Refuse pre-existing store targets before cleanup is armed: neither path
    // belongs to this invocation until both no-follow probes confirm absence.
    requireStoreLeafAbsent(io, git_dest) catch |err| {
        if (err == error.AlreadyAdopted) {
            try oplog.logOperation(io, log_path, .copy, git_src, git_dest, "error: target exists");
        }
        return err;
    };
    requireStoreLeafAbsent(io, jj_dest) catch |err| {
        if (err == error.AlreadyAdopted) {
            try oplog.logOperation(io, log_path, .copy, jj_src, jj_dest, "error: target exists");
        }
        return err;
    };

    var store_committed = false;
    var retain_store_on_error = false;
    errdefer if (!store_committed and !retain_store_on_error) {
        deleteTreeBestEffort(io, git_dest);
        deleteTreeBestEffort(io, jj_dest);
        if (!repo_store_preexisting) deleteTreeBestEffort(io, repo_store_dir);
    };

    // --- Step 2: Copy .git to gitstore ---
    try requireSourceMetadataDirectory(io, git_src);
    info(io, "copy: {s} -> {s}\n", .{ git_src, git_dest });
    const cp_result = try ex.exec(gpa, io, &.{ "cp", "-a", git_src, git_dest }, null);
    defer {
        gpa.free(cp_result.stdout);
        gpa.free(cp_result.stderr);
    }
    if (!cp_result.succeeded()) {
        warn(io, "error: cp failed: {s}\n", .{cp_result.stderr});
        deleteTreeBestEffort(io, git_dest);
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
            deleteTreeBestEffort(io, git_dest);
            try oplog.logOperation(io, log_path, .copy, git_src, git_dest, "error: verify failed, rolled back");
            return error.VerifyFailed;
        }
    }

    // --- Step 4: Stage the pristine .git directory and write pointer file ---
    // Keep the original bytes intact until jj initialization and metadata
    // relocation have committed. A post-swap failure can then restore the
    // exact index, refs, config, and worktree metadata even if jj mutated the
    // store copy before failing.
    const pointer_content = try std.fmt.allocPrint(gpa, "gitdir: {s}\n", .{git_dest});
    defer gpa.free(pointer_content);
    try Dir.rename(Dir.cwd(), git_src, Dir.cwd(), git_backup, io);
    var transaction_active = true;
    errdefer if (transaction_active) rollbackAdoptAfterGitSwap(
        gpa,
        io,
        git_src,
        git_dest,
        jj_src,
        jj_dest,
        repo_store_dir,
        repo_store_preexisting,
        worktrees,
        options.jj_colocate and !jj_preexisting,
        &retain_store_on_error,
        log_path,
    );
    logOperationBestEffort(io, log_path, .remove, git_src, "", "ok: staged pristine backup");

    Dir.cwd().writeFile(io, .{ .sub_path = git_src, .data = pointer_content }) catch |err| {
        warn(io, "error: pointer write failed, restoring pristine .git backup\n", .{});
        return err;
    };
    logOperationBestEffort(io, log_path, .write_pointer, git_src, git_dest, "ok");
    info(io, "pointer: {s} -> {s}\n", .{ git_src, git_dest });

    // --- Step 4b: Rewrite linked worktree .git pointers ---
    for (worktrees) |wt| {
        rewriteLinkedWorktreePointer(gpa, io, wt, git_dest) catch |err| {
            warn(io, "warn: could not rewrite worktree pointer at {s}: {s}\n", .{ wt, @errorName(err) });
            logOperationBestEffort(io, log_path, .write_pointer, wt, git_dest, "error: worktree rewrite failed");
            rollbackAdoptAfterGitSwap(
                gpa,
                io,
                git_src,
                git_dest,
                jj_src,
                jj_dest,
                repo_store_dir,
                repo_store_preexisting,
                worktrees,
                false,
                &retain_store_on_error,
                log_path,
            );
            return err;
        };
        logOperationBestEffort(io, log_path, .write_pointer, wt, git_dest, "ok: worktree");
        info(io, "worktree: {s}/.git -> {s}/worktrees/...\n", .{ wt, git_dest });
    }

    // --- Step 5: Handle .jj ---
    if (jj_preexisting) {
        try requireSourceMetadataDirectory(io, jj_src);
        info(io, "copy: {s} -> {s}\n", .{ jj_src, jj_dest });
        const jj_cp = try ex.exec(gpa, io, &.{ "cp", "-a", jj_src, jj_dest }, null);
        defer {
            gpa.free(jj_cp.stdout);
            gpa.free(jj_cp.stderr);
        }
        if (!jj_cp.succeeded()) {
            warn(io, "error: cp .jj failed: {s}\n", .{jj_cp.stderr});
            logOperationBestEffort(io, log_path, .copy, jj_src, jj_dest, "error: cp failed");
            rollbackAdoptAfterGitSwap(
                gpa,
                io,
                git_src,
                git_dest,
                jj_src,
                jj_dest,
                repo_store_dir,
                repo_store_preexisting,
                worktrees,
                false,
                &retain_store_on_error,
                log_path,
            );
            return error.ProcessFailed;
        }
        logOperationBestEffort(io, log_path, .copy, jj_src, jj_dest, "ok");

        rewriteJjGitTarget(gpa, io, jj_dest, git_dest) catch |err| {
            rollbackAdoptAfterGitSwap(
                gpa,
                io,
                git_src,
                git_dest,
                jj_src,
                jj_dest,
                repo_store_dir,
                repo_store_preexisting,
                worktrees,
                false,
                &retain_store_on_error,
                log_path,
            );
            return err;
        };

        // Move the original .jj aside instead of deleting it before the
        // symlink exists — restore it on failure so there is no window
        // where the worktree has no .jj at all.
        const jj_aside = try uniqueSidePath(gpa, io, jj_src, "gs-old");
        defer gpa.free(jj_aside);
        Dir.rename(Dir.cwd(), jj_src, Dir.cwd(), jj_aside, io) catch |err| {
            rollbackAdoptAfterGitSwap(
                gpa,
                io,
                git_src,
                git_dest,
                jj_src,
                jj_dest,
                repo_store_dir,
                repo_store_preexisting,
                worktrees,
                false,
                &retain_store_on_error,
                log_path,
            );
            return err;
        };
        Dir.symLinkAbsolute(io, jj_dest, jj_src, .{ .is_directory = true }) catch |err| {
            warn(io, "error: .jj symlink failed ({s}); restoring original .jj\n", .{@errorName(err)});
            renameBestEffort(io, jj_aside, jj_src);
            rollbackAdoptAfterGitSwap(
                gpa,
                io,
                git_src,
                git_dest,
                jj_src,
                jj_dest,
                repo_store_dir,
                repo_store_preexisting,
                worktrees,
                false,
                &retain_store_on_error,
                log_path,
            );
            return err;
        };
        Dir.cwd().deleteTree(io, jj_aside) catch |err| {
            warn(
                io,
                "error: could not remove staged original .jj ({s}); restoring original layout\n",
                .{@errorName(err)},
            );
            deleteFileBestEffort(io, jj_src);
            renameBestEffort(io, jj_aside, jj_src);
            rollbackAdoptAfterGitSwap(
                gpa,
                io,
                git_src,
                git_dest,
                jj_src,
                jj_dest,
                repo_store_dir,
                repo_store_preexisting,
                worktrees,
                false,
                &retain_store_on_error,
                log_path,
            );
            return err;
        };
        logOperationBestEffort(io, log_path, .remove, jj_src, "", "ok");
        logOperationBestEffort(io, log_path, .create_symlink, jj_src, jj_dest, "ok");
        info(io, "symlink: {s} -> {s}\n", .{ jj_src, jj_dest });
    } else if (options.jj_colocate) {
        try ensureAdoptLocalExcludes(gpa, io, repo_path, git_dest);
        info(io, "init: jj colocated in {s}\n", .{repo_path});
        const jj_init = ex.exec(
            gpa,
            io,
            &.{ jj_binary, "git", "init", "--colocate" },
            repo_path,
        ) catch |err| {
            logOperationBestEffort(io, log_path, .init_jj, repo_path, "", "error: jj spawn failed");
            warn(
                io,
                "error: required jj initialization could not start ({s}); restoring git-only layout\n",
                .{@errorName(err)},
            );
            rollbackAdoptAfterGitSwap(
                gpa,
                io,
                git_src,
                git_dest,
                jj_src,
                jj_dest,
                repo_store_dir,
                repo_store_preexisting,
                worktrees,
                true,
                &retain_store_on_error,
                log_path,
            );
            return err;
        };
        defer {
            gpa.free(jj_init.stdout);
            gpa.free(jj_init.stderr);
        }
        if (jj_init.succeeded()) {
            requireSourceMetadataDirectory(io, jj_src) catch |err| {
                logOperationBestEffort(
                    io,
                    log_path,
                    .init_jj,
                    repo_path,
                    "",
                    "error: jj metadata missing or unreadable",
                );
                warn(
                    io,
                    "error: required jj initialization did not produce readable metadata ({s}); " ++
                        "restoring git-only layout\n",
                    .{@errorName(err)},
                );
                rollbackAdoptAfterGitSwap(
                    gpa,
                    io,
                    git_src,
                    git_dest,
                    jj_src,
                    jj_dest,
                    repo_store_dir,
                    repo_store_preexisting,
                    worktrees,
                    true,
                    &retain_store_on_error,
                    log_path,
                );
                return if (err == error.FileNotFound) error.ProcessFailed else err;
            };
            logOperationBestEffort(io, log_path, .init_jj, repo_path, "", "ok");

            const jj_cp2 = try ex.exec(gpa, io, &.{ "cp", "-a", jj_src, jj_dest }, null);
            defer {
                gpa.free(jj_cp2.stdout);
                gpa.free(jj_cp2.stderr);
            }
            if (!jj_cp2.succeeded()) {
                warn(io, "error: cp auto-created .jj failed: {s}\n", .{jj_cp2.stderr});
                deleteTreeBestEffort(io, jj_dest);
                logOperationBestEffort(io, log_path, .copy, jj_src, jj_dest, "error: cp .jj failed");
                rollbackAdoptAfterGitSwap(
                    gpa,
                    io,
                    git_src,
                    git_dest,
                    jj_src,
                    jj_dest,
                    repo_store_dir,
                    repo_store_preexisting,
                    worktrees,
                    true,
                    &retain_store_on_error,
                    log_path,
                );
                return error.ProcessFailed;
            }

            rewriteJjGitTarget(gpa, io, jj_dest, git_dest) catch |err| {
                warn(
                    io,
                    "error: could not rewrite optional jj git_target at {s}: {s}\n",
                    .{ jj_dest, @errorName(err) },
                );
                deleteTreeBestEffort(io, jj_dest);
                rollbackAdoptAfterGitSwap(
                    gpa,
                    io,
                    git_src,
                    git_dest,
                    jj_src,
                    jj_dest,
                    repo_store_dir,
                    repo_store_preexisting,
                    worktrees,
                    true,
                    &retain_store_on_error,
                    log_path,
                );
                return err;
            };

            const jj_aside = try uniqueSidePath(gpa, io, jj_src, "gs-old");
            defer gpa.free(jj_aside);
            Dir.rename(Dir.cwd(), jj_src, Dir.cwd(), jj_aside, io) catch |err| {
                deleteTreeBestEffort(io, jj_dest);
                rollbackAdoptAfterGitSwap(
                    gpa,
                    io,
                    git_src,
                    git_dest,
                    jj_src,
                    jj_dest,
                    repo_store_dir,
                    repo_store_preexisting,
                    worktrees,
                    true,
                    &retain_store_on_error,
                    log_path,
                );
                return err;
            };
            Dir.symLinkAbsolute(io, jj_dest, jj_src, .{ .is_directory = true }) catch |err| {
                warn(
                    io,
                    "error: auto-created .jj symlink failed ({s}); restoring original layout\n",
                    .{@errorName(err)},
                );
                deleteTreeBestEffort(io, jj_aside);
                deleteTreeBestEffort(io, jj_dest);
                rollbackAdoptAfterGitSwap(
                    gpa,
                    io,
                    git_src,
                    git_dest,
                    jj_src,
                    jj_dest,
                    repo_store_dir,
                    repo_store_preexisting,
                    worktrees,
                    true,
                    &retain_store_on_error,
                    log_path,
                );
                return err;
            };
            Dir.cwd().deleteTree(io, jj_aside) catch |err| {
                warn(
                    io,
                    "error: could not remove auto-created .jj aside ({s}); restoring original layout\n",
                    .{@errorName(err)},
                );
                deleteFileBestEffort(io, jj_src);
                deleteTreeBestEffort(io, jj_aside);
                rollbackAdoptAfterGitSwap(
                    gpa,
                    io,
                    git_src,
                    git_dest,
                    jj_src,
                    jj_dest,
                    repo_store_dir,
                    repo_store_preexisting,
                    worktrees,
                    false,
                    &retain_store_on_error,
                    log_path,
                );
                return err;
            };
            logOperationBestEffort(io, log_path, .create_symlink, jj_src, jj_dest, "ok");
            info(io, "symlink: {s} -> {s}\n", .{ jj_src, jj_dest });
        } else {
            logOperationBestEffort(io, log_path, .init_jj, repo_path, "", "error: jj init failed");
            warn(io, "error: required jj initialization failed; restoring git-only layout: {s}\n", .{jj_init.stderr});
            rollbackAdoptAfterGitSwap(
                gpa,
                io,
                git_src,
                git_dest,
                jj_src,
                jj_dest,
                repo_store_dir,
                repo_store_preexisting,
                worktrees,
                true,
                &retain_store_on_error,
                log_path,
            );
            return error.ProcessFailed;
        }
    } else {
        info(io, "skip: jj colocation disabled for {s}\n", .{repo_path});
    }

    transaction_active = false;
    store_committed = true;
    Dir.cwd().deleteTree(io, git_backup) catch |err| {
        warn(
            io,
            "error: adoption committed but pristine recovery backup remains at {s}: {s}\n",
            .{ git_backup, @errorName(err) },
        );
        logOperationBestEffort(io, log_path, .remove, git_backup, "", "error: committed recovery backup retained");
        return error.RecoveryBackupRetained;
    };
    logOperationBestEffort(io, log_path, .remove, git_backup, "", "ok: adoption committed");
}

/// Adopt all repos under ghq root.
pub fn adoptAll(
    gpa: Allocator,
    io: Io,
    ghq_root: []const u8,
    gitstore_root: []const u8,
    dry_run: bool,
) !void {
    return adoptAllWithOptions(gpa, io, ghq_root, gitstore_root, .{ .dry_run = dry_run });
}

pub fn adoptAllWithOptions(
    gpa: Allocator,
    io: Io,
    ghq_root: []const u8,
    gitstore_root: []const u8,
    options: AdoptOptions,
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

        adoptWithOptions(gpa, io, e.abs_path, ghq_root, gitstore_root, options) catch |err| {
            warn(io, "error: failed to adopt {s}: {s}\n", .{ e.abs_path, @errorName(err) });
            failed += 1;
            continue;
        };
        adopted += 1;
    }

    if (options.dry_run) {
        info(
            io,
            "\ndry-run summary: {d} would adopt, {d} already adopted, {d} failed\n",
            .{ adopted, skipped, failed },
        );
    } else {
        info(io, "\nsummary: {d} adopted, {d} skipped, {d} failed\n", .{ adopted, skipped, failed });
    }
    if (failed > 0) return error.BatchFailures;
}

/// Verify a single repo's gitstore integrity.
pub fn verify(
    gpa: Allocator,
    io: Io,
    repo_path: []const u8,
) !bool {
    const repo_abs = try absoluteRepoPath(gpa, io, repo_path);
    defer gpa.free(repo_abs);

    var ok = true;

    const git_path = try std.fmt.allocPrint(gpa, "{s}/.git", .{repo_abs});
    defer gpa.free(git_path);
    const recovery_path = try std.fmt.allocPrint(gpa, "{s}/.git.zt-adopt-backup", .{repo_abs});
    defer gpa.free(recovery_path);
    if (pathExistsNoFollow(io, recovery_path) catch |err| {
        warn(
            io,
            "FAIL: could not inspect retained recovery backup {s}: {s}\n",
            .{ recovery_path, @errorName(err) },
        );
        ok = false;
        return false;
    }) {
        warn(io, "FAIL: retained recovery backup requires operator cleanup: {s}\n", .{recovery_path});
        ok = false;
    }

    const content = Dir.cwd().readFileAlloc(
        io,
        git_path,
        gpa,
        .limited(max_git_pointer_file_bytes),
    ) catch |err| switch (err) {
        error.IsDir => {
            warn(io, "FAIL: {s}/.git is a directory (not adopted)\n", .{repo_abs});
            return false;
        },
        error.StreamTooLong => {
            warn(io, "FAIL: {s}/.git is too large to be a gitdir pointer\n", .{repo_abs});
            return false;
        },
        else => {
            warn(io, "FAIL: {s}/.git not found\n", .{repo_abs});
            return false;
        },
    };
    defer gpa.free(content);

    const trimmed = ex.trimTrailingNewline(content);
    if (!std.mem.startsWith(u8, trimmed, "gitdir: ")) {
        warn(io, "FAIL: {s}/.git is not a valid gitdir pointer\n", .{repo_abs});
        return false;
    }
    const git_dir = trimmed["gitdir: ".len..];

    _ = Dir.cwd().statFile(io, git_dir, .{}) catch {
        warn(io, "FAIL: gitdir target does not exist: {s}\n", .{git_dir});
        ok = false;
    };

    {
        const git_result = try ex.exec(gpa, io, &.{ "git", "-C", repo_abs, "rev-parse", "--git-dir" }, null);
        defer {
            gpa.free(git_result.stdout);
            gpa.free(git_result.stderr);
        }
        if (!git_result.succeeded()) {
            warn(io, "FAIL: git rev-parse --git-dir failed in {s}\n", .{repo_abs});
            ok = false;
        }
    }

    const jj_path = try std.fmt.allocPrint(gpa, "{s}/.jj", .{repo_abs});
    defer gpa.free(jj_path);

    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const link_len = Dir.cwd().readLink(io, jj_path, &link_buf) catch |err| switch (err) {
        error.FileNotFound => {
            if (ok) info(io, "OK: {s} (no .jj)\n", .{repo_abs});
            return ok;
        },
        else => {
            warn(io, "FAIL: {s}/.jj is not a symlink\n", .{repo_abs});
            return false;
        },
    };
    const link_target = link_buf[0..link_len];

    _ = Dir.cwd().statFile(io, link_target, .{}) catch {
        warn(io, "FAIL: .jj symlink target does not exist: {s}\n", .{link_target});
        ok = false;
    };

    jj_check: {
        const jj_result = ex.exec(gpa, io, &.{ "jj", "status", "-R", repo_abs }, null) catch |err| switch (err) {
            error.FileNotFound => {
                warn(io, "SKIP: jj status skipped in {s} (jj not found on PATH)\n", .{repo_abs});
                break :jj_check;
            },
            else => return err,
        };
        defer {
            gpa.free(jj_result.stdout);
            gpa.free(jj_result.stderr);
        }
        if (!jj_result.succeeded()) {
            warn(io, "FAIL: jj status failed in {s}\n", .{repo_abs});
            ok = false;
        }
    }

    if (ok) info(io, "OK: {s}\n", .{repo_abs});

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

    const entries = list_mod.walk(gpa, io, ghq_root, gitstore_root, .{}) catch |err| {
        warn(io, "error: ghq enumeration failed: {s}\n", .{@errorName(err)});
        return error.ProcessFailed;
    };
    defer list_mod.freeEntries(gpa, entries);

    for (entries) |e| {
        // `e.is_adopted` is precomputed by walk(); skip non-adopted repos.
        if (!e.is_adopted) continue;

        const is_ok = try verify(gpa, io, e.abs_path);
        if (is_ok) ok_count += 1 else fail_count += 1;
    }

    info(io, "\nverify: {d} ok, {d} failed\n", .{ ok_count, fail_count });
    if (fail_count > 0) return error.BatchFailures;
}

/// Show gitstore disk usage, repo count, and broken pointers.
fn adoptedGitPointerBroken(gpa: Allocator, io: Io, repo_path: []const u8) bool {
    const recovery_path = std.fmt.allocPrint(gpa, "{s}/.git.zt-adopt-backup", .{repo_path}) catch return true;
    defer gpa.free(recovery_path);
    if (pathExistsNoFollow(io, recovery_path) catch return true) return true;

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

    const entries = list_mod.walk(gpa, io, ghq_root, gitstore_root, .{}) catch |err| {
        warn(io, "error: ghq enumeration failed: {s}\n", .{@errorName(err)});
        return error.ProcessFailed;
    };
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
        try s.objectField("working_tree_root");
        try s.write(ghq_root);
        try s.objectField("backing_store_root");
        try s.write(gitstore_root);
        // Compatibility alias retained for existing status consumers.
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
        info(io, "working trees: {s}\n", .{ghq_root});
        info(io, "backing store: {s}\n", .{gitstore_root});
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
            deleteFileBestEffort(io, path);
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

fn redactRemoteUserinfo(gpa: Allocator, remote: []const u8) ![]u8 {
    const scheme_idx = std.mem.indexOf(u8, remote, "://") orelse return try gpa.dupe(u8, remote);
    const authority_start = scheme_idx + "://".len;
    var authority_end = remote.len;
    var i = authority_start;
    while (i < remote.len) : (i += 1) {
        switch (remote[i]) {
            '/', '?', '#' => {
                authority_end = i;
                break;
            },
            else => {},
        }
    }
    const authority = remote[authority_start..authority_end];
    const at_rel = std.mem.lastIndexOfScalar(u8, authority, '@') orelse return try gpa.dupe(u8, remote);
    const userinfo_end = authority_start + at_rel + 1;
    const out = try gpa.alloc(u8, remote.len - (userinfo_end - authority_start));
    @memcpy(out[0..authority_start], remote[0..authority_start]);
    @memcpy(out[authority_start..], remote[userinfo_end..]);
    return out;
}

fn infoRedactingRemote(io: Io, text: []const u8, remote: []const u8, safe_remote: []const u8) void {
    if (text.len == 0) return;
    if (std.mem.eql(u8, remote, safe_remote)) {
        info(io, "{s}", .{text});
        return;
    }
    var start: usize = 0;
    while (std.mem.find(u8, text[start..], remote)) |rel| {
        const hit = start + rel;
        info(io, "{s}", .{text[start..hit]});
        info(io, "{s}", .{safe_remote});
        start = hit + remote.len;
    }
    info(io, "{s}", .{text[start..]});
}

fn warnRedactingRemote(io: Io, text: []const u8, remote: []const u8, safe_remote: []const u8) void {
    if (text.len == 0) return;
    if (std.mem.eql(u8, remote, safe_remote)) {
        warn(io, "{s}", .{text});
        return;
    }
    var start: usize = 0;
    while (std.mem.find(u8, text[start..], remote)) |rel| {
        const hit = start + rel;
        warn(io, "{s}", .{text[start..hit]});
        warn(io, "{s}", .{safe_remote});
        start = hit + remote.len;
    }
    warn(io, "{s}", .{text[start..]});
}

test "redactRemoteUserinfo removes URL credentials" {
    const gpa = std.testing.allocator;
    const redacted = try redactRemoteUserinfo(gpa, "sftp://user:secret@example.com/repos");
    defer gpa.free(redacted);
    try std.testing.expectEqualStrings("sftp://example.com/repos", redacted);

    const named = try redactRemoteUserinfo(gpa, "gdrive:ghq");
    defer gpa.free(named);
    try std.testing.expectEqualStrings("gdrive:ghq", named);
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
        deleteFileBestEffort(io, filter_path);
    };
    const safe_remote = try redactRemoteUserinfo(gpa, remote);
    defer gpa.free(safe_remote);

    // Build rclone command
    if (dry_run) {
        info(io, "dry-run: rclone sync {s} {s} --filter-from {s} --dry-run\n", .{ ghq_root, safe_remote, filter_path });
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
            warn(io, "error: rclone dry-run failed\n", .{});
            warnRedactingRemote(io, result.stderr, remote, safe_remote);
            warn(io, "\n", .{});
            return error.ProcessFailed;
        }
        infoRedactingRemote(io, result.stdout, remote, safe_remote);
        if (result.stderr.len > 0) infoRedactingRemote(io, result.stderr, remote, safe_remote);
    } else {
        info(io, "sync: {s} -> {s}\n", .{ ghq_root, safe_remote });
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
            warn(io, "error: rclone sync failed\n", .{});
            warnRedactingRemote(io, result.stderr, remote, safe_remote);
            warn(io, "\n", .{});
            return error.ProcessFailed;
        }
        infoRedactingRemote(io, result.stderr, remote, safe_remote); // rclone stats go to stderr
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

    if (!isAdoptedInternal(gpa, io, repo_path, gitstore_root)) {
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
    const pointer_content = Dir.cwd().readFileAlloc(
        io,
        git_pointer_path,
        gpa,
        .limited(max_git_pointer_file_bytes),
    ) catch |err| switch (err) {
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
        warn(
            io,
            "error: gitdir pointer in {s}/.git lost its 'gitdir: ' prefix between reads: {s}\n",
            .{ repo_path, trimmed },
        );
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
        warn(
            io,
            "error: gitdir pointer in {s}/.git is not a gitstore git_src (missing /git suffix): {s}\n",
            .{ repo_path, git_src },
        );
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
                warn(
                    io,
                    "error: gitdir pointer in {s}/.git has invalid path components: {s}\n",
                    .{ repo_path, git_src },
                );
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
            warn(
                io,
                "error: could not canonicalize gitstore root {s}: {s}\n",
                .{ root_norm, @errorName(err) },
            );
            return error.GitDirMalformed;
        };
        const canon_root = canon_root_buf[0..canon_root_len];
        const canon_repo_len = Dir.cwd().realPathFile(io, repo_store_dir, &canon_repo_buf) catch |err| {
            warn(
                io,
                "error: could not canonicalize gitstore repo dir {s}: {s}\n",
                .{ repo_store_dir, @errorName(err) },
            );
            return error.GitDirMalformed;
        };
        const canon_repo = canon_repo_buf[0..canon_repo_len];
        if (!std.mem.startsWith(u8, canon_repo, canon_root) or
            canon_repo.len <= canon_root.len or
            canon_repo[canon_root.len] != '/')
        {
            warn(
                io,
                "error: canonicalized gitdir target {s} escapes canonicalized gitstore root {s}\n",
                .{ canon_repo, canon_root },
            );
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
        for (worktrees) |wt| {
            info(
                io,
                "  rewrite worktree pointer {s}/.git -> {s}/.git/worktrees/...\n",
                .{ wt, repo_path },
            );
        }
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
    deleteTreeBestEffort(io, git_new);
    info(io, "copy: {s} -> {s}\n", .{ git_src, git_new });
    const cp = try ex.exec(gpa, io, &.{ "cp", "-a", git_src, git_new }, null);
    defer {
        gpa.free(cp.stdout);
        gpa.free(cp.stderr);
    }
    if (!cp.succeeded()) {
        warn(io, "error: cp failed: {s}\n", .{cp.stderr});
        try oplog.logOperation(io, log_path, .copy, git_src, git_new, "error: cp failed (detach)");
        deleteTreeBestEffort(io, git_new);
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
        deleteTreeBestEffort(io, git_new);
        try oplog.logOperation(io, log_path, .copy, git_src, git_new, "error: verify failed");
        return error.VerifyFailed;
    }

    // --- Step 3: Swap — rename pointer aside, rename staged dir, then delete aside ---
    const git_pointer_aside = try uniqueSidePath(gpa, io, git_pointer_path, "gs-old");
    defer gpa.free(git_pointer_aside);
    try Dir.rename(Dir.cwd(), git_pointer_path, Dir.cwd(), git_pointer_aside, io);
    logOperationBestEffort(io, log_path, .remove, git_pointer_path, git_pointer_aside, "ok: detach pointer aside");
    Dir.rename(Dir.cwd(), git_new, Dir.cwd(), git_pointer_path, io) catch |err| {
        warn(io, "error: restoring .git pointer after staged rename failed ({s})\n", .{@errorName(err)});
        renameBestEffort(io, git_pointer_aside, git_pointer_path);
        deleteTreeBestEffort(io, git_new);
        return err;
    };
    try Dir.cwd().deleteFile(io, git_pointer_aside);
    logOperationBestEffort(io, log_path, .write_pointer, git_src, git_pointer_path, "ok: detach restore .git");
    info(io, "restored: {s}/.git\n", .{repo_path});

    var post_restore_err: ?anyerror = null;

    // --- Step 4: Handle .jj ---
    if (has_jj_link) jj_restore: {
        const jj_new = try std.fmt.allocPrint(gpa, "{s}/.jj.gs-new", .{repo_path});
        defer gpa.free(jj_new);
        deleteTreeBestEffort(io, jj_new);
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
                deleteTreeBestEffort(io, jj_new);
                post_restore_err = err;
                break :jj_restore;
            };
            // Now rename staged copy into place. On failure restore the symlink.
            Dir.rename(Dir.cwd(), jj_new, Dir.cwd(), jj_pointer_path, io) catch |err| {
                warn(io, "error: rename staged .jj failed ({s}); restoring symlink\n", .{@errorName(err)});
                renameBestEffort(io, jj_backup, jj_pointer_path);
                deleteTreeBestEffort(io, jj_new);
                post_restore_err = err;
                break :jj_restore;
            };
            rewriteJjGitTargetRelative(gpa, io, jj_pointer_path) catch |err| {
                warn(
                    io,
                    "error: rewrite restored .jj git_target failed ({s}); restoring symlink\n",
                    .{@errorName(err)},
                );
                deleteTreeBestEffort(io, jj_pointer_path);
                renameBestEffort(io, jj_backup, jj_pointer_path);
                post_restore_err = err;
                break :jj_restore;
            };
            // Success — delete the old symlink backup.
            deleteFileBestEffort(io, jj_backup);
            logOperationBestEffort(io, log_path, .create_symlink, jj_src, jj_pointer_path, "ok: detach restore .jj");
            info(io, "restored: {s}/.jj\n", .{repo_path});
        } else {
            warn(io, "error: cp .jj failed: {s}\n", .{jcp.stderr});
            deleteTreeBestEffort(io, jj_new);
            logOperationBestEffort(io, log_path, .copy, jj_src, jj_new, "error: cp .jj failed (detach)");
            post_restore_err = error.ProcessFailed;
            break :jj_restore;
        }
    }

    // --- Step 5: Rewrite linked worktree pointers back ---
    const restored_git = try std.fmt.allocPrint(gpa, "{s}/.git", .{repo_path});
    defer gpa.free(restored_git);
    for (worktrees) |wt| {
        rewriteLinkedWorktreePointer(gpa, io, wt, restored_git) catch |err| {
            warn(io, "warn: could not rewrite worktree pointer {s}: {s}\n", .{ wt, @errorName(err) });
            logOperationBestEffort(
                io,
                log_path,
                .write_pointer,
                wt,
                restored_git,
                "error: detach worktree rewrite failed",
            );
            if (post_restore_err == null) post_restore_err = err;
            continue;
        };
        logOperationBestEffort(io, log_path, .write_pointer, wt, restored_git, "ok: detach worktree");
        info(io, "worktree: {s}/.git -> {s}/worktrees/...\n", .{ wt, restored_git });
    }

    if (post_restore_err) |err| {
        warn(io, "CRITICAL: partial detach after .git restore; leaving z3store entry intact: {s}\n", .{repo_store_dir});
        return err;
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
            logOperationBestEffort(
                io,
                log_path,
                .remove,
                repo_store_dir,
                archived,
                "error: archive failed (left in place)",
            );
            return err;
        };
        logOperationBestEffort(io, log_path, .remove, repo_store_dir, archived, "ok: detach archived");
        info(io, "archived: {s} -> {s}\n", .{ repo_store_dir, archived });
    } else {
        Dir.cwd().deleteTree(io, repo_store_dir) catch |err| {
            warn(io, "error: could not remove z3store entry ({s})\n", .{@errorName(err)});
            logOperationBestEffort(io, log_path, .remove, repo_store_dir, "", "error: remove failed (left in place)");
            return err;
        };
        logOperationBestEffort(io, log_path, .remove, repo_store_dir, "", "ok: detach removed");
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

    const entries = list_mod.walk(gpa, io, ghq_root, gitstore_root, .{}) catch |err| {
        warn(io, "error: ghq enumeration failed: {s}\n", .{@errorName(err)});
        return error.ProcessFailed;
    };
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
        info(
            io,
            "\ndry-run detach summary: {d} would detach, {d} not adopted, {d} failed\n",
            .{ detached, skipped, failed },
        );
    } else {
        info(io, "\ndetach summary: {d} detached, {d} not adopted, {d} failed\n", .{ detached, skipped, failed });
    }
    if (failed > 0) return error.BatchFailures;
}
