//! Walk a ghq root directory tree and enumerate adopted/unadopted repos.
//!
//! Mirrors ghq's `saracen/walker` host/owner/name layout and extends it with
//! adoption + jj detection, optional worktree flattening, and HEAD lookup via
//! the per-root JSON cache in `cache.zig`.
//!
//! Pure traversal: every filesystem op takes the injected `std.Io`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;

const gitstore = @import("z3store.zig");
const ex = @import("exec.zig");
const cache = @import("cache.zig");
const lore = @import("lore.zig");

/// One enumerated repository. All slices are heap-owned by the allocator
/// passed to `walk()`. Call `deinit` to release them.
pub const RepoEntry = struct {
    rel_path: []const u8,
    abs_path: []const u8,
    host: []const u8,
    owner: []const u8,
    name: []const u8,
    is_adopted: bool,
    has_jj: bool,
    /// True when the directory is an EpicGames Lore workspace (`.lore/instance`
    /// present). A repo may be both git AND lore; the flag is independent of
    /// `is_adopted`/`has_jj`. Lore workspaces are marked ` [lore]` in plain
    /// output and are never relocated (see `lore.zig`).
    is_lore: bool = false,
    worktrees: [][]const u8,
    head_sha: ?[]const u8,
    last_fetched_unix: ?i64,

    pub fn deinit(self: *RepoEntry, gpa: Allocator) void {
        gpa.free(self.rel_path);
        gpa.free(self.abs_path);
        gpa.free(self.host);
        gpa.free(self.owner);
        gpa.free(self.name);
        for (self.worktrees) |w| gpa.free(w);
        gpa.free(self.worktrees);
        if (self.head_sha) |s| gpa.free(s);
        self.* = undefined;
    }
};

/// Free a slice of entries and the outer array.
pub fn freeEntries(gpa: Allocator, entries: []RepoEntry) void {
    for (entries) |*e| e.deinit(gpa);
    gpa.free(entries);
}

pub const ListOptions = struct {
    /// Substring match on `rel_path`. Null = no filter.
    pattern: ?[]const u8 = null,
    /// When true, linked worktree paths are flattened into their own entries
    /// (the main repo entry still has its `worktrees` field populated).
    include_worktrees: bool = false,
    /// When true, shell out to `git rev-parse HEAD` for each entry and update
    /// the cache; otherwise consult the cache only.
    include_head: bool = false,
};

pub const WalkError = error{
    OutOfMemory,
    ProcessFailed,
} || Dir.OpenError || Dir.Iterator.Error || Dir.StatFileError ||
    Dir.ReadFileAllocError || Allocator.Error || ex.ExecError;

/// Walk `ghq_root` and return repo entries. The caller owns the slice and
/// must free it with `freeEntries`.
pub fn walk(
    gpa: Allocator,
    io: Io,
    ghq_root: []const u8,
    gitstore_root: []const u8,
    opts: ListOptions,
) WalkError![]RepoEntry {
    var out: std.ArrayList(RepoEntry) = .empty;
    errdefer {
        for (out.items) |*e| e.deinit(gpa);
        out.deinit(gpa);
    }

    // Load cache upfront (cheap if empty). Must be closed at end.
    var cache_map = cache.load(gpa, io, gitstore_root) catch return error.OutOfMemory;
    defer cache.freeMap(gpa, &cache_map);

    // Top-level: iterate host directories.
    var root_dir = Dir.openDirAbsolute(io, ghq_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return try out.toOwnedSlice(gpa),
        else => return err,
    };
    defer root_dir.close(io);

    var host_iter = root_dir.iterate();
    while (try host_iter.next(io)) |host_entry| {
        if (host_entry.kind != .directory) continue;
        if (!looksLikeHost(host_entry.name)) continue;
        try walkHost(gpa, io, &out, ghq_root, gitstore_root, host_entry.name, opts, &cache_map);
    }

    return try out.toOwnedSlice(gpa);
}

fn walkHost(
    gpa: Allocator,
    io: Io,
    out: *std.ArrayList(RepoEntry),
    ghq_root: []const u8,
    gitstore_root: []const u8,
    host_name: []const u8,
    opts: ListOptions,
    cache_map: *std.StringHashMap(cache.CacheEntry),
) !void {
    const host_abs = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ ghq_root, host_name });
    defer gpa.free(host_abs);

    var host_dir = Dir.openDirAbsolute(io, host_abs, .{ .iterate = true }) catch return;
    defer host_dir.close(io);

    var owner_iter = host_dir.iterate();
    while (try owner_iter.next(io)) |owner_entry| {
        if (owner_entry.kind != .directory) continue;
        try walkOwner(gpa, io, out, ghq_root, gitstore_root, host_name, owner_entry.name, opts, cache_map);
    }
}

fn walkOwner(
    gpa: Allocator,
    io: Io,
    out: *std.ArrayList(RepoEntry),
    ghq_root: []const u8,
    gitstore_root: []const u8,
    host_name: []const u8,
    owner_name: []const u8,
    opts: ListOptions,
    cache_map: *std.StringHashMap(cache.CacheEntry),
) !void {
    const owner_abs = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ ghq_root, host_name, owner_name });
    defer gpa.free(owner_abs);

    var owner_dir = Dir.openDirAbsolute(io, owner_abs, .{ .iterate = true }) catch return;
    defer owner_dir.close(io);

    var name_iter = owner_dir.iterate();
    while (try name_iter.next(io)) |name_entry| {
        if (name_entry.kind != .directory) continue;
        try tryAppendRepo(gpa, io, out, ghq_root, gitstore_root, host_name, owner_name, name_entry.name, opts, cache_map);
    }
}

fn tryAppendRepo(
    gpa: Allocator,
    io: Io,
    out: *std.ArrayList(RepoEntry),
    ghq_root: []const u8,
    gitstore_root: []const u8,
    host_name: []const u8,
    owner_name: []const u8,
    repo_name: []const u8,
    opts: ListOptions,
    cache_map: *std.StringHashMap(cache.CacheEntry),
) !void {
    const abs_path = try std.fmt.allocPrint(
        gpa,
        "{s}/{s}/{s}/{s}",
        .{ ghq_root, host_name, owner_name, repo_name },
    );
    errdefer gpa.free(abs_path);
    const rel_path = try std.fmt.allocPrint(
        gpa,
        "{s}/{s}/{s}",
        .{ host_name, owner_name, repo_name },
    );
    errdefer gpa.free(rel_path);

    if (!isRepoDir(io, abs_path, gpa)) {
        gpa.free(abs_path);
        gpa.free(rel_path);
        return;
    }

    if (opts.pattern) |p| {
        if (p.len != 0 and std.mem.indexOf(u8, rel_path, p) == null) {
            gpa.free(abs_path);
            gpa.free(rel_path);
            return;
        }
    }

    const is_adopted = gitstore.isAdopted(io, abs_path, gitstore_root, gpa);
    const has_jj = hasJj(io, abs_path, gpa);
    const is_lore = lore.detectLoreWorkspace(io, abs_path);

    var worktrees: [][]const u8 = &.{};
    // Always enumerate when a worktree-related thing is needed, or include_worktrees.
    if (opts.include_worktrees or is_adopted) {
        if (gitstore.enumerateLinkedWorktrees(gpa, io, abs_path)) |wt_bufs| {
            // Convert [][]u8 → [][]const u8 (same memory, reinterpreted ownership).
            var buf: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (buf.items) |w| gpa.free(w);
                buf.deinit(gpa);
            }
            try buf.ensureTotalCapacity(gpa, wt_bufs.len);
            for (wt_bufs) |w| buf.appendAssumeCapacity(w);
            gpa.free(wt_bufs); // outer only — inner items now owned by buf
            worktrees = try buf.toOwnedSlice(gpa);
        } else |_| {
            worktrees = &.{};
        }
    }

    // Resolve HEAD sha + last_fetched_unix.
    var head_sha: ?[]const u8 = null;
    var last_fetched_unix: ?i64 = null;
    if (cache_map.get(rel_path)) |cached| {
        if (cached.head_sha) |s| head_sha = try gpa.dupe(u8, s);
        last_fetched_unix = cached.last_fetched_unix;
    }
    if (opts.include_head) {
        if (try resolveHead(gpa, io, abs_path)) |sha| {
            if (head_sha) |old| gpa.free(old);
            head_sha = sha;
        }
    }

    try out.append(gpa, .{
        .rel_path = rel_path,
        .abs_path = abs_path,
        .host = try gpa.dupe(u8, host_name),
        .owner = try gpa.dupe(u8, owner_name),
        .name = try gpa.dupe(u8, repo_name),
        .is_adopted = is_adopted,
        .has_jj = has_jj,
        .is_lore = is_lore,
        .worktrees = worktrees,
        .head_sha = head_sha,
        .last_fetched_unix = last_fetched_unix,
    });

    // If requested, flatten worktree paths as their own entries.
    if (opts.include_worktrees) {
        for (worktrees) |wt| {
            const wt_abs = try gpa.dupe(u8, wt);
            errdefer gpa.free(wt_abs);
            const wt_rel = try gpa.dupe(u8, wt); // rel == abs for out-of-tree worktrees
            errdefer gpa.free(wt_rel);
            try out.append(gpa, .{
                .rel_path = wt_rel,
                .abs_path = wt_abs,
                .host = try gpa.dupe(u8, host_name),
                .owner = try gpa.dupe(u8, owner_name),
                .name = try gpa.dupe(u8, repo_name),
                .is_adopted = false,
                .has_jj = false,
                .worktrees = &.{},
                .head_sha = null,
                .last_fetched_unix = null,
            });
        }
    }
}

/// A directory is considered a repo if it contains `.git` (dir or pointer
/// file) or `.jj`. Non-git VCS (hg, svn, bzr) are intentionally skipped per
/// libz3store v2 scope.
fn isRepoDir(io: Io, abs_path: []const u8, gpa: Allocator) bool {
    const git_path = std.fmt.allocPrint(gpa, "{s}/.git", .{abs_path}) catch return false;
    defer gpa.free(git_path);
    if (Dir.cwd().statFile(io, git_path, .{})) |_| return true else |_| {}

    const jj_path = std.fmt.allocPrint(gpa, "{s}/.jj", .{abs_path}) catch return false;
    defer gpa.free(jj_path);
    if (Dir.cwd().statFile(io, jj_path, .{})) |_| return true else |_| {}

    // EpicGames Lore workspaces have neither `.git` nor `.jj` but should still
    // surface in `zt list` (marked ` [lore]`), so recognize `.lore/instance`.
    if (lore.detectLoreWorkspace(io, abs_path)) return true;

    return false;
}

fn hasJj(io: Io, abs_path: []const u8, gpa: Allocator) bool {
    const jj_path = std.fmt.allocPrint(gpa, "{s}/.jj", .{abs_path}) catch return false;
    defer gpa.free(jj_path);
    const st = Dir.cwd().statFile(io, jj_path, .{}) catch return false;
    return st.kind == .directory;
}

fn resolveHead(gpa: Allocator, io: Io, abs_path: []const u8) !?[]const u8 {
    var result = ex.exec(gpa, io, &.{ "git", "-C", abs_path, "rev-parse", "HEAD" }, null) catch return null;
    defer {
        gpa.free(result.stdout);
        gpa.free(result.stderr);
    }
    if (!result.succeeded()) return null;
    const trimmed = ex.trimTrailingNewline(result.stdout);
    if (trimmed.len == 0) return null;
    return try gpa.dupe(u8, trimmed);
}

/// Accept `[A-Za-z0-9.-]+` that also contains at least one '.'. Rejects
/// `_file_` / random top-level dirs that would otherwise be mistaken for
/// hosts.
fn looksLikeHost(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s[0] == '.') return false;
    var has_dot = false;
    for (s) |c| {
        if (c == '.') {
            has_dot = true;
            continue;
        }
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '-';
        if (!ok) return false;
    }
    return has_dot;
}

// =========================================================
// Rendering
// =========================================================

/// Render one line per entry, newline-terminated. Caller owns the buffer.
pub fn renderPlain(gpa: Allocator, entries: []const RepoEntry, full_path: bool) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    for (entries) |e| {
        const line = if (full_path) e.abs_path else e.rel_path;
        try aw.writer.writeAll(line);
        // Mark EpicGames Lore workspaces so operators know the tree carries
        // non-relocatable `.lore/` metadata (see lore.zig).
        if (e.is_lore) try aw.writer.writeAll(" [lore]");
        try aw.writer.writeByte('\n');
    }
    return aw.toOwnedSlice();
}

/// Render the entries as a pretty-printed JSON array. Caller owns the buffer.
pub fn renderJson(gpa: Allocator, entries: []const RepoEntry) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var s: std.json.Stringify = .{
        .writer = &aw.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try s.beginArray();
    for (entries) |e| {
        try s.beginObject();
        try s.objectField("rel_path");
        try s.write(e.rel_path);
        try s.objectField("abs_path");
        try s.write(e.abs_path);
        try s.objectField("host");
        try s.write(e.host);
        try s.objectField("owner");
        try s.write(e.owner);
        try s.objectField("name");
        try s.write(e.name);
        try s.objectField("is_adopted");
        try s.write(e.is_adopted);
        try s.objectField("has_jj");
        try s.write(e.has_jj);
        try s.objectField("is_lore");
        try s.write(e.is_lore);
        try s.objectField("worktrees");
        try s.beginArray();
        for (e.worktrees) |w| try s.write(w);
        try s.endArray();
        try s.objectField("head_sha");
        if (e.head_sha) |sha| try s.write(sha) else try s.write(null);
        try s.objectField("last_fetched_unix");
        if (e.last_fetched_unix) |t| try s.write(t) else try s.write(null);
        try s.endObject();
    }
    try s.endArray();

    return aw.toOwnedSlice();
}

// =========================================================
// Tests — prefixed "list:" for filtering.
// =========================================================

const testing = std.testing;

const WalkTestEnv = struct {
    base: []const u8,
    ghq_root: []const u8,
    gitstore_root: []const u8,
    gpa: Allocator,
    io: Io,

    fn setup(gpa: Allocator, io: Io, tag: []const u8) !WalkTestEnv {
        const base = try std.fmt.allocPrint(gpa, "/tmp/gitstore_list_{s}", .{tag});
        const ghq = try std.fmt.allocPrint(gpa, "{s}/ghq", .{base});
        const store = try std.fmt.allocPrint(gpa, "{s}/gitstore", .{base});
        Dir.cwd().deleteTree(io, base) catch {};
        try Dir.cwd().createDirPath(io, ghq);
        try Dir.cwd().createDirPath(io, store);
        return .{
            .base = base,
            .ghq_root = ghq,
            .gitstore_root = store,
            .gpa = gpa,
            .io = io,
        };
    }

    fn teardown(self: *const WalkTestEnv) void {
        Dir.cwd().deleteTree(self.io, self.base) catch {};
        self.gpa.free(self.base);
        self.gpa.free(self.ghq_root);
        self.gpa.free(self.gitstore_root);
    }

    /// Create a dir at `<ghq>/host/owner/name` and put a `.git` directory
    /// inside so it's recognized as a repo.
    fn createGitRepo(self: *const WalkTestEnv, host: []const u8, owner: []const u8, name: []const u8) !void {
        const repo = try std.fmt.allocPrint(self.gpa, "{s}/{s}/{s}/{s}", .{ self.ghq_root, host, owner, name });
        defer self.gpa.free(repo);
        const git_dir = try std.fmt.allocPrint(self.gpa, "{s}/.git", .{repo});
        defer self.gpa.free(git_dir);
        try Dir.cwd().createDirPath(self.io, git_dir);
    }

    fn createJjRepo(self: *const WalkTestEnv, host: []const u8, owner: []const u8, name: []const u8) !void {
        try self.createGitRepo(host, owner, name);
        const repo = try std.fmt.allocPrint(self.gpa, "{s}/{s}/{s}/{s}/.jj", .{ self.ghq_root, host, owner, name });
        defer self.gpa.free(repo);
        try Dir.cwd().createDirPath(self.io, repo);
    }

    fn createPlainDir(self: *const WalkTestEnv, rel: []const u8) !void {
        const p = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ self.ghq_root, rel });
        defer self.gpa.free(p);
        try Dir.cwd().createDirPath(self.io, p);
    }

    /// Create a Lore-only workspace (`.lore/instance`) at `<ghq>/host/owner/name`.
    fn createLoreWorkspace(self: *const WalkTestEnv, host: []const u8, owner: []const u8, name: []const u8) !void {
        const lore_dir = try std.fmt.allocPrint(self.gpa, "{s}/{s}/{s}/{s}/.lore", .{ self.ghq_root, host, owner, name });
        defer self.gpa.free(lore_dir);
        try Dir.cwd().createDirPath(self.io, lore_dir);
        const instance = try std.fmt.allocPrint(self.gpa, "{s}/instance", .{lore_dir});
        defer self.gpa.free(instance);
        try Dir.cwd().writeFile(self.io, .{ .sub_path = instance, .data = "0192f000-0000-7000-8000-000000000000\n" });
    }

    /// Write a pointer file that marks the repo as adopted into gitstore.
    fn markAdopted(self: *const WalkTestEnv, host: []const u8, owner: []const u8, name: []const u8) !void {
        const git_path = try std.fmt.allocPrint(
            self.gpa,
            "{s}/{s}/{s}/{s}/.git",
            .{ self.ghq_root, host, owner, name },
        );
        defer self.gpa.free(git_path);
        // Remove the .git dir placeholder if present, replace with a pointer file.
        Dir.cwd().deleteTree(self.io, git_path) catch {};
        const pointer = try std.fmt.allocPrint(
            self.gpa,
            "gitdir: {s}/{s}/{s}/{s}/git\n",
            .{ self.gitstore_root, host, owner, name },
        );
        defer self.gpa.free(pointer);
        try Dir.cwd().writeFile(self.io, .{ .sub_path = git_path, .data = pointer });
    }
};

test "list: empty ghq root yields no entries" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try WalkTestEnv.setup(gpa, io, "empty");
    defer env.teardown();

    const entries = try walk(gpa, io, env.ghq_root, env.gitstore_root, .{});
    defer freeEntries(gpa, entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "list: nonexistent ghq root returns empty slice" {
    const gpa = testing.allocator;
    const io = testing.io;
    const entries = try walk(gpa, io, "/tmp/gitstore_list_absolutely_no_such_root_42", "/tmp/gitstore_list_no_such_store_42", .{});
    defer freeEntries(gpa, entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "list: single git repo is enumerated" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try WalkTestEnv.setup(gpa, io, "singlegit");
    defer env.teardown();
    try env.createGitRepo("github.com", "owner", "repo");

    const entries = try walk(gpa, io, env.ghq_root, env.gitstore_root, .{});
    defer freeEntries(gpa, entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("github.com/owner/repo", entries[0].rel_path);
    try testing.expect(!entries[0].is_adopted);
    try testing.expect(!entries[0].has_jj);
}

test "list: jj-colocated repo flips has_jj" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try WalkTestEnv.setup(gpa, io, "jjcolo");
    defer env.teardown();
    try env.createJjRepo("github.com", "owner", "jjrepo");

    const entries = try walk(gpa, io, env.ghq_root, env.gitstore_root, .{});
    defer freeEntries(gpa, entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expect(entries[0].has_jj);
}

test "list: pattern filter matches substring of rel_path" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try WalkTestEnv.setup(gpa, io, "pattern");
    defer env.teardown();
    try env.createGitRepo("github.com", "a", "one");
    try env.createGitRepo("github.com", "b", "two");
    try env.createGitRepo("gitlab.com", "c", "three");

    const entries = try walk(gpa, io, env.ghq_root, env.gitstore_root, .{ .pattern = "gitlab" });
    defer freeEntries(gpa, entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("gitlab.com/c/three", entries[0].rel_path);
}

test "list: adopted repo is flagged is_adopted=true" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try WalkTestEnv.setup(gpa, io, "adopted");
    defer env.teardown();
    try env.createGitRepo("github.com", "owner", "adopted");
    try env.markAdopted("github.com", "owner", "adopted");

    const entries = try walk(gpa, io, env.ghq_root, env.gitstore_root, .{});
    defer freeEntries(gpa, entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expect(entries[0].is_adopted);
}

test "list: skip directory without .git or .jj" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try WalkTestEnv.setup(gpa, io, "skipnonrepo");
    defer env.teardown();
    try env.createPlainDir("github.com/owner/notarepo");
    try env.createGitRepo("github.com", "owner", "yes");

    const entries = try walk(gpa, io, env.ghq_root, env.gitstore_root, .{});
    defer freeEntries(gpa, entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("github.com/owner/yes", entries[0].rel_path);
}

test "list: non-host top-level dirs are ignored" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try WalkTestEnv.setup(gpa, io, "nonhost");
    defer env.teardown();
    // "_file_" has no dot; "tmp" has no dot; neither should be walked.
    try env.createPlainDir("_file_/owner/stray");
    try env.createPlainDir("tmp/owner/stray");
    try env.createGitRepo("github.com", "owner", "good");

    const entries = try walk(gpa, io, env.ghq_root, env.gitstore_root, .{});
    defer freeEntries(gpa, entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("github.com/owner/good", entries[0].rel_path);
}

test "list: deep nesting below host/owner/name is not descended into" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try WalkTestEnv.setup(gpa, io, "deepnest");
    defer env.teardown();
    try env.createGitRepo("github.com", "owner", "repo");
    // create a nested dir that *inside* the repo — should NOT emerge as a
    // second entry, we only walk two levels.
    try env.createPlainDir("github.com/owner/repo/subdir/with/nesting");

    const entries = try walk(gpa, io, env.ghq_root, env.gitstore_root, .{});
    defer freeEntries(gpa, entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
}

test "list: renderPlain produces one line per entry" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try WalkTestEnv.setup(gpa, io, "renderplain");
    defer env.teardown();
    try env.createGitRepo("github.com", "owner", "a");
    try env.createGitRepo("github.com", "owner", "b");

    const entries = try walk(gpa, io, env.ghq_root, env.gitstore_root, .{});
    defer freeEntries(gpa, entries);

    const text = try renderPlain(gpa, entries, false);
    defer gpa.free(text);
    // Two newline-terminated lines.
    var count: usize = 0;
    for (text) |c| if (c == '\n') {
        count += 1;
    };
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expect(std.mem.indexOf(u8, text, "github.com/owner/a") != null);
    try testing.expect(std.mem.indexOf(u8, text, "github.com/owner/b") != null);
}

test "list: lore-only workspace is enumerated and marked [lore]" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try WalkTestEnv.setup(gpa, io, "loremark");
    defer env.teardown();
    try env.createGitRepo("github.com", "owner", "plaingit");
    try env.createLoreWorkspace("github.com", "owner", "lorews");

    const entries = try walk(gpa, io, env.ghq_root, env.gitstore_root, .{});
    defer freeEntries(gpa, entries);
    try testing.expectEqual(@as(usize, 2), entries.len);

    var saw_lore = false;
    for (entries) |e| {
        if (std.mem.eql(u8, e.rel_path, "github.com/owner/lorews")) {
            saw_lore = true;
            try testing.expect(e.is_lore);
            try testing.expect(!e.is_adopted);
        } else {
            try testing.expect(!e.is_lore);
        }
    }
    try testing.expect(saw_lore);

    const text = try renderPlain(gpa, entries, false);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "github.com/owner/lorews [lore]") != null);
    // The plain git repo carries no marker.
    try testing.expect(std.mem.indexOf(u8, text, "github.com/owner/plaingit [lore]") == null);
}

test "list: renderJson emits a top-level array" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try WalkTestEnv.setup(gpa, io, "renderjson");
    defer env.teardown();
    try env.createJjRepo("github.com", "owner", "repo");

    const entries = try walk(gpa, io, env.ghq_root, env.gitstore_root, .{});
    defer freeEntries(gpa, entries);

    const json = try renderJson(gpa, entries);
    defer gpa.free(json);

    // Parseable JSON
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .array);
    try testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    const obj = parsed.value.array.items[0].object;
    try testing.expectEqualStrings("github.com/owner/repo", obj.get("rel_path").?.string);
    try testing.expect(obj.get("has_jj").?.bool);
}

test "list: include_worktrees flattens linked worktree paths" {
    // Build a real git repo with a linked worktree so we can exercise the
    // flatten path without stubbing exec.
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try WalkTestEnv.setup(gpa, io, "wtflatten");
    defer env.teardown();

    const repo = try std.fmt.allocPrint(gpa, "{s}/github.com/owner/wt", .{env.ghq_root});
    defer gpa.free(repo);
    try Dir.cwd().createDirPath(io, repo);
    const r0 = try ex.exec(gpa, io, &.{ "git", "init" }, repo);
    gpa.free(r0.stdout);
    gpa.free(r0.stderr);
    const r1 = try ex.exec(gpa, io, &.{ "git", "config", "user.email", "t@t" }, repo);
    gpa.free(r1.stdout);
    gpa.free(r1.stderr);
    const r2 = try ex.exec(gpa, io, &.{ "git", "config", "user.name", "T" }, repo);
    gpa.free(r2.stdout);
    gpa.free(r2.stderr);
    const r3 = try ex.exec(gpa, io, &.{ "git", "commit", "--no-verify", "--allow-empty", "-m", "m" }, repo);
    gpa.free(r3.stdout);
    gpa.free(r3.stderr);

    const wt_dir = try std.fmt.allocPrint(gpa, "{s}/wt-branch", .{env.base});
    defer gpa.free(wt_dir);
    const rw = try ex.exec(gpa, io, &.{ "git", "worktree", "add", "-b", "feat", wt_dir }, repo);
    gpa.free(rw.stdout);
    gpa.free(rw.stderr);

    const entries = try walk(gpa, io, env.ghq_root, env.gitstore_root, .{ .include_worktrees = true });
    defer freeEntries(gpa, entries);
    // Expect at least 2: the main repo + its linked worktree.
    try testing.expect(entries.len >= 2);
    var found_main = false;
    var found_wt = false;
    for (entries) |e| {
        if (std.mem.eql(u8, e.rel_path, "github.com/owner/wt")) found_main = true;
        if (std.mem.indexOf(u8, e.rel_path, "wt-branch") != null) found_wt = true;
    }
    try testing.expect(found_main);
    try testing.expect(found_wt);
}

// =========================================================
// Fuzz: a synthetic ghq tree generated via Smith must never
// cause `walk` to crash or leak.
// =========================================================

fn fuzzWalkerSynthetic(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = testing.allocator;
    const io = testing.io;

    const base = "/tmp/gitstore_list_fuzz_root";
    Dir.cwd().deleteTree(io, base) catch {};
    defer Dir.cwd().deleteTree(io, base) catch {};
    try Dir.cwd().createDirPath(io, base);

    const host_count = smith.valueRangeAtMost(u8, 0, 3);
    var h: u8 = 0;
    while (h < host_count) : (h += 1) {
        const host_kind = smith.valueRangeAtMost(u8, 0, 2);
        const host_name: []const u8 = switch (host_kind) {
            0 => "github.com",
            1 => "gitlab.com",
            else => "example.net",
        };
        const owners = smith.valueRangeAtMost(u8, 0, 2);
        var o: u8 = 0;
        while (o < owners) : (o += 1) {
            const repos = smith.valueRangeAtMost(u8, 0, 3);
            var r: u8 = 0;
            while (r < repos) : (r += 1) {
                const name_kind = smith.valueRangeAtMost(u8, 0, 2);
                const name: []const u8 = switch (name_kind) {
                    0 => "alpha",
                    1 => "beta",
                    else => "gamma",
                };
                const owner: []const u8 = if (o == 0) "o1" else "o2";
                const repo_path = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}/{s}", .{ base, host_name, owner, name });
                defer gpa.free(repo_path);

                // Randomly add .git, .jj, both, or neither.
                const has_git = smith.value(bool);
                const has_jj_flag = smith.value(bool);
                try Dir.cwd().createDirPath(io, repo_path);
                if (has_git) {
                    const gitp = try std.fmt.allocPrint(gpa, "{s}/.git", .{repo_path});
                    defer gpa.free(gitp);
                    Dir.cwd().createDirPath(io, gitp) catch {};
                }
                if (has_jj_flag) {
                    const jjp = try std.fmt.allocPrint(gpa, "{s}/.jj", .{repo_path});
                    defer gpa.free(jjp);
                    Dir.cwd().createDirPath(io, jjp) catch {};
                }
            }
        }
    }

    const entries = walk(gpa, io, base, "/tmp/gitstore_list_fuzz_store_does_not_exist", .{}) catch |err| switch (err) {
        error.OutOfMemory => return,
        else => return err,
    };
    freeEntries(gpa, entries);
}

test "list: fuzz walker on synthetic trees" {
    try std.testing.fuzz({}, fuzzWalkerSynthetic, .{});
}
