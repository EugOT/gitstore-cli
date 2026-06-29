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

const gitstore = @import("gitstore.zig");
const ex = @import("exec.zig");
const cache = @import("cache.zig");
const test_support = @import("test_support.zig");

const HeadLookup = union(enum) {
    sha: []u8,
    clear,
    unavailable,
};

fn ignoreMissingCleanupError(err: anyerror) !void {
    switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
}

fn freeCacheEntry(gpa: Allocator, entry: cache.CacheEntry) void {
    gpa.free(entry.rel_path);
    if (entry.url) |u| gpa.free(u);
    if (entry.head_sha) |s| gpa.free(s);
}

fn updateHeadCache(
    gpa: Allocator,
    cache_map: *std.StringHashMap(cache.CacheEntry),
    rel_path: []const u8,
    head_sha: ?[]const u8,
    last_fetched_unix: ?i64,
) !void {
    var url_copy: ?[]const u8 = null;
    errdefer if (url_copy) |u| gpa.free(u);
    var removed_entry: ?cache.CacheEntry = null;
    errdefer if (removed_entry) |entry| freeCacheEntry(gpa, entry);
    if (cache_map.fetchRemove(rel_path)) |old| {
        removed_entry = old.value;
        if (old.value.url) |u| url_copy = try gpa.dupe(u8, u);
        freeCacheEntry(gpa, old.value);
        removed_entry = null;
    }

    const rel_copy = try gpa.dupe(u8, rel_path);
    errdefer gpa.free(rel_copy);
    var sha_copy: ?[]const u8 = null;
    errdefer if (sha_copy) |s| gpa.free(s);
    if (head_sha) |s| sha_copy = try gpa.dupe(u8, s);

    try cache_map.put(rel_copy, .{
        .rel_path = rel_copy,
        .url = url_copy,
        .head_sha = sha_copy,
        .last_fetched_unix = last_fetched_unix,
    });
    url_copy = null;
    sha_copy = null;
}

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
) anyerror![]RepoEntry {
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

    if (opts.include_head) {
        cache.save(gpa, io, gitstore_root, &cache_map) catch |err| {
            std.log.warn("repository cache save failed for {s}: {s}", .{ gitstore_root, @errorName(err) });
        };
    }

    return out.toOwnedSlice(gpa);
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

    var host_dir = Dir.openDirAbsolute(io, host_abs, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
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

    var owner_dir = Dir.openDirAbsolute(io, owner_abs, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer owner_dir.close(io);

    var name_iter = owner_dir.iterate();
    while (try name_iter.next(io)) |name_entry| {
        if (name_entry.kind != .directory) continue;
        try tryAppendRepo(
            gpa,
            io,
            out,
            ghq_root,
            gitstore_root,
            host_name,
            owner_name,
            name_entry.name,
            opts,
            cache_map,
        );
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
    var abs_path_owned = true;
    defer if (abs_path_owned) gpa.free(abs_path);
    const rel_path = try std.fmt.allocPrint(
        gpa,
        "{s}/{s}/{s}",
        .{ host_name, owner_name, repo_name },
    );
    var rel_path_owned = true;
    defer if (rel_path_owned) gpa.free(rel_path);

    if (opts.pattern) |p| {
        if (p.len != 0 and std.mem.indexOf(u8, rel_path, p) == null) {
            return;
        }
    }

    if (!try isRepoDir(gpa, io, abs_path)) {
        return;
    }

    const is_adopted = gitstore.isAdoptedPaths(gpa, io, .{ .repo_path = abs_path, .gitstore_root = gitstore_root });
    const has_jj = try hasJj(gpa, io, abs_path);

    var worktrees: [][]const u8 = &.{};
    var worktrees_owned = false;
    defer if (worktrees_owned) {
        for (worktrees) |wt| gpa.free(wt);
        gpa.free(worktrees);
    };
    // Always enumerate when a worktree-related thing is needed, or include_worktrees.
    if (opts.include_worktrees or is_adopted) {
        if (gitstore.enumerateLinkedWorktrees(gpa, io, abs_path)) |wt_bufs| {
            var wt_bufs_owned = true;
            errdefer if (wt_bufs_owned) {
                for (wt_bufs) |w| gpa.free(w);
                gpa.free(wt_bufs);
            };
            // Convert [][]u8 → [][]const u8 (same memory, reinterpreted ownership).
            var buf: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (buf.items) |w| gpa.free(w);
                buf.deinit(gpa);
            }
            try buf.ensureTotalCapacity(gpa, wt_bufs.len);
            for (wt_bufs) |w| buf.appendAssumeCapacity(w);
            gpa.free(wt_bufs); // outer only — inner items now owned by buf
            wt_bufs_owned = false;
            worktrees = try buf.toOwnedSlice(gpa);
            worktrees_owned = true;
        } else |err| switch (err) {
            error.ProcessFailed => {
                std.log.warn("linked worktree enumeration failed for {s}: {s}", .{ abs_path, @errorName(err) });
                worktrees = &.{};
            },
            else => return err,
        }
    }

    // Resolve HEAD sha + last_fetched_unix.
    var head_sha: ?[]const u8 = null;
    var head_sha_owned = false;
    defer if (head_sha_owned) {
        if (head_sha) |s| gpa.free(s);
    };
    var last_fetched_unix: ?i64 = null;
    if (cache_map.get(rel_path)) |cached| {
        if (cached.head_sha) |s| {
            head_sha = try gpa.dupe(u8, s);
            head_sha_owned = true;
        }
        last_fetched_unix = cached.last_fetched_unix;
    }
    if (opts.include_head) {
        switch (try resolveHead(gpa, io, abs_path)) {
            .sha => |sha| {
                if (head_sha_owned) {
                    if (head_sha) |old| gpa.free(old);
                }
                head_sha = sha;
                head_sha_owned = true;
                try updateHeadCache(gpa, cache_map, rel_path, head_sha, last_fetched_unix);
            },
            .clear => {
                if (head_sha_owned) {
                    if (head_sha) |old| gpa.free(old);
                }
                head_sha = null;
                head_sha_owned = false;
                try updateHeadCache(gpa, cache_map, rel_path, head_sha, last_fetched_unix);
            },
            .unavailable => {},
        }
    }

    const entry_host = try gpa.dupe(u8, host_name);
    var entry_host_owned = true;
    defer if (entry_host_owned) gpa.free(entry_host);
    const entry_owner = try gpa.dupe(u8, owner_name);
    var entry_owner_owned = true;
    defer if (entry_owner_owned) gpa.free(entry_owner);
    const entry_name = try gpa.dupe(u8, repo_name);
    var entry_name_owned = true;
    defer if (entry_name_owned) gpa.free(entry_name);

    try out.append(gpa, .{
        .rel_path = rel_path,
        .abs_path = abs_path,
        .host = entry_host,
        .owner = entry_owner,
        .name = entry_name,
        .is_adopted = is_adopted,
        .has_jj = has_jj,
        .worktrees = worktrees,
        .head_sha = head_sha,
        .last_fetched_unix = last_fetched_unix,
    });
    rel_path_owned = false;
    abs_path_owned = false;
    entry_host_owned = false;
    entry_owner_owned = false;
    entry_name_owned = false;
    worktrees_owned = false;
    head_sha_owned = false;

    // If requested, flatten worktree paths as their own entries.
    if (opts.include_worktrees) {
        for (worktrees) |wt| {
            const wt_abs = try gpa.dupe(u8, wt);
            var wt_abs_owned = true;
            defer if (wt_abs_owned) gpa.free(wt_abs);
            const wt_rel = try gpa.dupe(u8, wt); // rel == abs for out-of-tree worktrees
            var wt_rel_owned = true;
            defer if (wt_rel_owned) gpa.free(wt_rel);
            const wt_host = try gpa.dupe(u8, host_name);
            var wt_host_owned = true;
            defer if (wt_host_owned) gpa.free(wt_host);
            const wt_owner = try gpa.dupe(u8, owner_name);
            var wt_owner_owned = true;
            defer if (wt_owner_owned) gpa.free(wt_owner);
            const wt_name = try gpa.dupe(u8, repo_name);
            var wt_name_owned = true;
            defer if (wt_name_owned) gpa.free(wt_name);
            var wt_head_sha: ?[]const u8 = null;
            var wt_head_sha_owned = false;
            defer if (wt_head_sha_owned) {
                if (wt_head_sha) |sha| gpa.free(sha);
            };
            var wt_last_fetched_unix: ?i64 = null;
            if (cache_map.get(wt_rel)) |cached| {
                if (cached.head_sha) |s| {
                    wt_head_sha = try gpa.dupe(u8, s);
                    wt_head_sha_owned = true;
                }
                wt_last_fetched_unix = cached.last_fetched_unix;
            }
            if (opts.include_head) {
                switch (try resolveHead(gpa, io, wt_abs)) {
                    .sha => |sha| {
                        if (wt_head_sha_owned) {
                            if (wt_head_sha) |old| gpa.free(old);
                        }
                        wt_head_sha = sha;
                        wt_head_sha_owned = true;
                        try updateHeadCache(gpa, cache_map, wt_rel, wt_head_sha, wt_last_fetched_unix);
                    },
                    .clear => {
                        if (wt_head_sha_owned) {
                            if (wt_head_sha) |old| gpa.free(old);
                        }
                        wt_head_sha = null;
                        wt_head_sha_owned = false;
                        try updateHeadCache(gpa, cache_map, wt_rel, wt_head_sha, wt_last_fetched_unix);
                    },
                    .unavailable => {},
                }
            }
            try out.append(gpa, .{
                .rel_path = wt_rel,
                .abs_path = wt_abs,
                .host = wt_host,
                .owner = wt_owner,
                .name = wt_name,
                .is_adopted = false,
                .has_jj = false,
                .worktrees = &.{},
                .head_sha = wt_head_sha,
                .last_fetched_unix = wt_last_fetched_unix,
            });
            wt_rel_owned = false;
            wt_abs_owned = false;
            wt_host_owned = false;
            wt_owner_owned = false;
            wt_name_owned = false;
            wt_head_sha_owned = false;
        }
    }
}

/// A directory is considered a repo if it contains `.git` (dir or pointer
/// file) or `.jj`. Non-git VCS (hg, svn, bzr) are intentionally skipped per
/// libgitstore v2 scope.
fn isRepoDir(gpa: Allocator, io: Io, abs_path: []const u8) !bool {
    const git_path = try std.fmt.allocPrint(gpa, "{s}/.git", .{abs_path});
    defer gpa.free(git_path);
    if (Dir.cwd().statFile(io, git_path, .{})) |_| return true else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const jj_path = try std.fmt.allocPrint(gpa, "{s}/.jj", .{abs_path});
    defer gpa.free(jj_path);
    if (Dir.cwd().statFile(io, jj_path, .{})) |st| return st.kind == .directory else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    return false;
}

fn hasJj(gpa: Allocator, io: Io, abs_path: []const u8) !bool {
    const jj_path = try std.fmt.allocPrint(gpa, "{s}/.jj", .{abs_path});
    defer gpa.free(jj_path);
    const st = Dir.cwd().statFile(io, jj_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return st.kind == .directory;
}

fn resolveHead(gpa: Allocator, io: Io, abs_path: []const u8) !HeadLookup {
    const result = ex.exec(
        gpa,
        io,
        &.{ "git", "-C", abs_path, "rev-parse", "--verify", "--quiet", "HEAD" },
        null,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            std.log.warn("HEAD lookup failed for {s}: {s}", .{ abs_path, @errorName(err) });
            return .unavailable;
        },
    };
    defer {
        gpa.free(result.stdout);
        gpa.free(result.stderr);
    }
    if (!result.succeeded()) {
        const stderr = ex.trimTrailingNewline(result.stderr);
        if (result.term == .exited and result.term.exited == 1 and stderr.len == 0) {
            return .clear;
        }
        if (stderr.len != 0) {
            std.log.warn("HEAD lookup failed for {s}: {s}", .{ abs_path, stderr });
        } else {
            std.log.warn("HEAD lookup failed for {s}: git rev-parse exited non-zero", .{abs_path});
        }
        return .unavailable;
    }
    const trimmed = ex.trimTrailingNewline(result.stdout);
    if (trimmed.len == 0) return .clear;
    const owned = try gpa.dupe(u8, trimmed);
    return .{ .sha = owned };
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
        const prefix = try std.fmt.allocPrint(gpa, "list_{s}", .{tag});
        defer gpa.free(prefix);
        const base = try test_support.uniqueTempDir(gpa, io, prefix);
        errdefer gpa.free(base);
        errdefer Dir.cwd().deleteTree(io, base) catch |err| test_support.ignoreCleanupError("list setup", err);
        const ghq = try std.fmt.allocPrint(gpa, "{s}/ghq", .{base});
        errdefer gpa.free(ghq);
        const store = try std.fmt.allocPrint(gpa, "{s}/gitstore", .{base});
        errdefer gpa.free(store);
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
        Dir.cwd().deleteTree(self.io, self.base) catch |err| test_support.ignoreCleanupError("list env", err);
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

    /// Write a pointer file that marks the repo as adopted into gitstore.
    fn markAdopted(self: *const WalkTestEnv, host: []const u8, owner: []const u8, name: []const u8) !void {
        const git_path = try std.fmt.allocPrint(
            self.gpa,
            "{s}/{s}/{s}/{s}/.git",
            .{ self.ghq_root, host, owner, name },
        );
        defer self.gpa.free(git_path);
        // Remove the .git dir placeholder if present, replace with a pointer file.
        Dir.cwd().deleteTree(self.io, git_path) catch |err| try ignoreMissingCleanupError(err);
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
    var env = try WalkTestEnv.setup(gpa, io, "missingroot");
    defer env.teardown();
    const missing_ghq = try std.fmt.allocPrint(gpa, "{s}/missing-ghq", .{env.base});
    defer gpa.free(missing_ghq);
    const missing_store = try std.fmt.allocPrint(gpa, "{s}/missing-store", .{env.base});
    defer gpa.free(missing_store);
    const entries = try walk(
        gpa,
        io,
        missing_ghq,
        missing_store,
        .{},
    );
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

test "list: include_head keeps stale cached head when live lookup is unavailable" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try WalkTestEnv.setup(gpa, io, "stalehead");
    defer env.teardown();
    try env.createGitRepo("github.com", "owner", "stale");

    var src: std.StringHashMap(cache.CacheEntry) = .init(gpa);
    defer cache.freeMap(gpa, &src);
    const rel = try gpa.dupe(u8, "github.com/owner/stale");
    var rel_owned = true;
    errdefer if (rel_owned) gpa.free(rel);
    const stale_sha = try gpa.dupe(u8, "deadbeef");
    var stale_sha_owned = true;
    errdefer if (stale_sha_owned) gpa.free(stale_sha);
    try src.put(rel, .{
        .rel_path = rel,
        .head_sha = stale_sha,
        .last_fetched_unix = 1_700_000_000,
    });
    rel_owned = false;
    stale_sha_owned = false;
    try cache.save(gpa, io, env.gitstore_root, &src);

    const entries = try walk(gpa, io, env.ghq_root, env.gitstore_root, .{ .include_head = true });
    defer freeEntries(gpa, entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("deadbeef", entries[0].head_sha.?);
    try testing.expectEqual(@as(?i64, 1_700_000_000), entries[0].last_fetched_unix);

    const cached_entries = try walk(gpa, io, env.ghq_root, env.gitstore_root, .{});
    defer freeEntries(gpa, cached_entries);
    try testing.expectEqual(@as(usize, 1), cached_entries.len);
    try testing.expectEqualStrings("deadbeef", cached_entries[0].head_sha.?);
    try testing.expectEqual(@as(?i64, 1_700_000_000), cached_entries[0].last_fetched_unix);
}

test "list: include_head clears stale cached head for unborn git repo" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try WalkTestEnv.setup(gpa, io, "unbornhead");
    defer env.teardown();
    const repo = try std.fmt.allocPrint(gpa, "{s}/github.com/owner/unborn", .{env.ghq_root});
    defer gpa.free(repo);
    try Dir.cwd().createDirPath(io, repo);
    var init = try ex.exec(gpa, io, &.{ "git", "-C", repo, "init" }, null);
    defer init.deinit(gpa);
    try testing.expect(init.succeeded());

    var src: std.StringHashMap(cache.CacheEntry) = .init(gpa);
    defer cache.freeMap(gpa, &src);
    const rel = try gpa.dupe(u8, "github.com/owner/unborn");
    var rel_owned = true;
    errdefer if (rel_owned) gpa.free(rel);
    const stale_sha = try gpa.dupe(u8, "deadbeef");
    var stale_sha_owned = true;
    errdefer if (stale_sha_owned) gpa.free(stale_sha);
    try src.put(rel, .{
        .rel_path = rel,
        .head_sha = stale_sha,
        .last_fetched_unix = 1_700_000_000,
    });
    rel_owned = false;
    stale_sha_owned = false;
    try cache.save(gpa, io, env.gitstore_root, &src);

    const entries = try walk(gpa, io, env.ghq_root, env.gitstore_root, .{ .include_head = true });
    defer freeEntries(gpa, entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expect(entries[0].head_sha == null);
    try testing.expectEqual(@as(?i64, 1_700_000_000), entries[0].last_fetched_unix);

    const cached_entries = try walk(gpa, io, env.ghq_root, env.gitstore_root, .{});
    defer freeEntries(gpa, cached_entries);
    try testing.expectEqual(@as(usize, 1), cached_entries.len);
    try testing.expect(cached_entries[0].head_sha == null);
    try testing.expectEqual(@as(?i64, 1_700_000_000), cached_entries[0].last_fetched_unix);
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

    const base = try test_support.uniqueTempDir(gpa, io, "list_fuzz_root");
    defer {
        Dir.cwd().deleteTree(io, base) catch |err| test_support.ignoreCleanupError("list fuzz", err);
        gpa.free(base);
    }

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
                    try Dir.cwd().createDirPath(io, gitp);
                }
                if (has_jj_flag) {
                    const jjp = try std.fmt.allocPrint(gpa, "{s}/.jj", .{repo_path});
                    defer gpa.free(jjp);
                    try Dir.cwd().createDirPath(io, jjp);
                }
            }
        }
    }

    const missing_store = try std.fmt.allocPrint(gpa, "{s}/store_does_not_exist", .{base});
    defer gpa.free(missing_store);

    const entries = walk(gpa, io, base, missing_store, .{}) catch |err| switch (err) {
        error.OutOfMemory => return,
        else => return err,
    };
    freeEntries(gpa, entries);
}

test "list: fuzz walker on synthetic trees" {
    try std.testing.fuzz({}, fuzzWalkerSynthetic, .{});
}
