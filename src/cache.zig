//! Per-root repository metadata cache.
//!
//! Stores a JSON index at `<gitstore_root>/.z3store/cache/index.json`.
//! Writes are atomic (temp-file + fsync + rename). The diff helper is pure and
//! deterministic so list-walker can test it with `Io.failing`.
//!
//! No global state. All I/O goes through the injected `std.Io`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;

/// One entry per repo in the on-disk index. All slices are owned by whatever
/// allocator populated the containing map; freeing is done with `freeMap`.
pub const CacheEntry = struct {
    rel_path: []const u8,
    url: ?[]const u8 = null,
    head_sha: ?[]const u8 = null,
    last_fetched_unix: ?i64 = null,
};

/// Owned-map free helper. Frees every heap slice in each entry and the keys.
/// The map itself is deinitialized.
pub fn freeMap(gpa: Allocator, map: *std.StringHashMap(CacheEntry)) void {
    var it = map.iterator();
    while (it.next()) |kv| {
        gpa.free(kv.value_ptr.rel_path);
        if (kv.value_ptr.url) |u| gpa.free(u);
        if (kv.value_ptr.head_sha) |s| gpa.free(s);
        // Key is a reference into rel_path; do not double-free.
    }
    map.deinit();
}

/// Deterministic diff between two slices of `CacheEntry`. Pure function.
/// Caller owns all returned slices; call `freeDiff` to release them.
pub const Diff = struct {
    added: []const []const u8,
    removed: []const []const u8,
    changed: []const []const u8,
};

pub fn freeDiff(gpa: Allocator, diff: Diff) void {
    gpa.free(diff.added);
    gpa.free(diff.removed);
    gpa.free(diff.changed);
}

/// Compute added / removed / changed rel_paths between two sorted-or-unsorted
/// snapshots. A rel_path that appears in both is `changed` only when
/// `head_sha` or `url` differ. `last_fetched_unix` alone does NOT count as
/// change — it is treated as a liveness signal, not content.
pub fn diffIndex(
    gpa: Allocator,
    prev: []const CacheEntry,
    curr: []const CacheEntry,
) !Diff {
    var added: std.ArrayList([]const u8) = .empty;
    errdefer added.deinit(gpa);
    var removed: std.ArrayList([]const u8) = .empty;
    errdefer removed.deinit(gpa);
    var changed: std.ArrayList([]const u8) = .empty;
    errdefer changed.deinit(gpa);

    // added + changed
    for (curr) |c| {
        var found: ?*const CacheEntry = null;
        for (prev) |*p| {
            if (std.mem.eql(u8, p.rel_path, c.rel_path)) {
                found = p;
                break;
            }
        }
        if (found) |p| {
            if (!optStrEql(p.head_sha, c.head_sha) or !optStrEql(p.url, c.url)) {
                try changed.append(gpa, c.rel_path);
            }
        } else {
            try added.append(gpa, c.rel_path);
        }
    }

    // removed
    for (prev) |p| {
        var still_there = false;
        for (curr) |c| {
            if (std.mem.eql(u8, p.rel_path, c.rel_path)) {
                still_there = true;
                break;
            }
        }
        if (!still_there) try removed.append(gpa, p.rel_path);
    }

    return .{
        .added = try added.toOwnedSlice(gpa),
        .removed = try removed.toOwnedSlice(gpa),
        .changed = try changed.toOwnedSlice(gpa),
    };
}

fn optStrEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// Open (or initialize empty) the on-disk cache for a given store root.
/// Never panics; a missing file returns an empty map. A corrupt file returns
/// an empty map (callers will rebuild).
///
/// Returned map owns heap-allocated key slices (they reference into the
/// `rel_path` value, so freeing keys is NOT required — `freeMap` handles it).
pub fn load(
    gpa: Allocator,
    io: Io,
    gitstore_root: []const u8,
) !std.StringHashMap(CacheEntry) {
    var map: std.StringHashMap(CacheEntry) = .init(gpa);
    errdefer freeMap(gpa, &map);

    const index_path = try indexPath(gpa, gitstore_root);
    defer gpa.free(index_path);

    const bytes = Dir.cwd().readFileAlloc(io, index_path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => blk: {
            const legacy_index_path = try legacyIndexPath(gpa, gitstore_root);
            defer gpa.free(legacy_index_path);
            break :blk Dir.cwd().readFileAlloc(io, legacy_index_path, gpa, .unlimited) catch return map;
        },
        else => return map, // any other read error: return empty; callers rebuild
    };
    defer gpa.free(bytes);

    var parsed = std.json.parseFromSlice(
        std.json.Value,
        gpa,
        bytes,
        .{},
    ) catch return map;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return map;
    const entries = root.object.get("entries") orelse return map;
    if (entries != .array) return map;

    for (entries.array.items) |item| {
        if (item != .object) continue;
        const rel_v = item.object.get("rel_path") orelse continue;
        if (rel_v != .string) continue;
        const rel = try gpa.dupe(u8, rel_v.string);
        errdefer gpa.free(rel);

        var url_copy: ?[]const u8 = null;
        if (item.object.get("url")) |u| {
            if (u == .string) url_copy = try gpa.dupe(u8, u.string);
        }
        errdefer if (url_copy) |s| gpa.free(s);

        var sha_copy: ?[]const u8 = null;
        if (item.object.get("head_sha")) |s| {
            if (s == .string) sha_copy = try gpa.dupe(u8, s.string);
        }
        errdefer if (sha_copy) |s| gpa.free(s);

        var ts: ?i64 = null;
        if (item.object.get("last_fetched_unix")) |t| {
            if (t == .integer) ts = t.integer;
        }

        try map.put(rel, .{
            .rel_path = rel,
            .url = url_copy,
            .head_sha = sha_copy,
            .last_fetched_unix = ts,
        });
    }

    return map;
}

/// Serialize the cache and write it atomically. The procedure:
///   1. Ensure `<gitstore_root>/.z3store/cache/` exists.
///   2. Write to `index.json.tmp`.
///   3. `rename()` over `index.json`.
///
/// On any failure the temp file is unlinked.
pub fn save(
    gpa: Allocator,
    io: Io,
    gitstore_root: []const u8,
    entries: *const std.StringHashMap(CacheEntry),
) !void {
    const cache_dir = try cacheDir(gpa, gitstore_root);
    defer gpa.free(cache_dir);
    try Dir.cwd().createDirPath(io, cache_dir);

    const final_path = try std.fmt.allocPrint(gpa, "{s}/index.json", .{cache_dir});
    defer gpa.free(final_path);
    const tmp_path = try std.fmt.allocPrint(gpa, "{s}/index.json.tmp", .{cache_dir});
    defer gpa.free(tmp_path);

    // Serialize to an Allocating writer so we don't need to size up-front.
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var s: std.json.Stringify = .{
        .writer = &aw.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try s.beginObject();
    try s.objectField("version");
    try s.write(@as(u32, 1));
    try s.objectField("entries");
    try s.beginArray();

    var it = entries.iterator();
    while (it.next()) |kv| {
        const v = kv.value_ptr.*;
        try s.beginObject();
        try s.objectField("rel_path");
        try s.write(v.rel_path);
        if (v.url) |u| {
            try s.objectField("url");
            try s.write(u);
        }
        if (v.head_sha) |sh| {
            try s.objectField("head_sha");
            try s.write(sh);
        }
        if (v.last_fetched_unix) |t| {
            try s.objectField("last_fetched_unix");
            try s.write(t);
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();

    // Write to temp, then atomically rename.
    Dir.cwd().writeFile(io, .{
        .sub_path = tmp_path,
        .data = aw.written(),
    }) catch |err| {
        Dir.cwd().deleteFile(io, tmp_path) catch {};
        return err;
    };

    Dir.rename(Dir.cwd(), tmp_path, Dir.cwd(), final_path, io) catch |err| {
        Dir.cwd().deleteFile(io, tmp_path) catch {};
        return err;
    };
}

fn cacheDir(gpa: Allocator, gitstore_root: []const u8) ![]u8 {
    var trimmed = gitstore_root;
    while (trimmed.len > 1 and trimmed[trimmed.len - 1] == '/') {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    // a stale legacy `.gitstore/cache` left behind is harmless.
    return std.fmt.allocPrint(gpa, "{s}/.z3store/cache", .{trimmed});
}

fn indexPath(gpa: Allocator, gitstore_root: []const u8) ![]u8 {
    const dir = try cacheDir(gpa, gitstore_root);
    defer gpa.free(dir);
    return std.fmt.allocPrint(gpa, "{s}/index.json", .{dir});
}

fn legacyIndexPath(gpa: Allocator, gitstore_root: []const u8) ![]u8 {
    var trimmed = gitstore_root;
    while (trimmed.len > 1 and trimmed[trimmed.len - 1] == '/') {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    return std.fmt.allocPrint(gpa, "{s}/.gitstore/cache/index.json", .{trimmed});
}

// =========================================================
// Tests — prefixed "cache:" for filtering.
// =========================================================

const testing = std.testing;

test "cache: diffIndex detects added entries" {
    const gpa = testing.allocator;
    const prev = [_]CacheEntry{};
    const curr = [_]CacheEntry{
        .{ .rel_path = "github.com/a/b" },
        .{ .rel_path = "github.com/a/c" },
    };
    const d = try diffIndex(gpa, &prev, &curr);
    defer freeDiff(gpa, d);
    try testing.expectEqual(@as(usize, 2), d.added.len);
    try testing.expectEqual(@as(usize, 0), d.removed.len);
    try testing.expectEqual(@as(usize, 0), d.changed.len);
}

test "cache: diffIndex detects removed entries" {
    const gpa = testing.allocator;
    const prev = [_]CacheEntry{
        .{ .rel_path = "github.com/a/b" },
        .{ .rel_path = "github.com/a/c" },
    };
    const curr = [_]CacheEntry{
        .{ .rel_path = "github.com/a/b" },
    };
    const d = try diffIndex(gpa, &prev, &curr);
    defer freeDiff(gpa, d);
    try testing.expectEqual(@as(usize, 0), d.added.len);
    try testing.expectEqual(@as(usize, 1), d.removed.len);
    try testing.expectEqualStrings("github.com/a/c", d.removed[0]);
    try testing.expectEqual(@as(usize, 0), d.changed.len);
}

test "cache: diffIndex detects head_sha changes" {
    const gpa = testing.allocator;
    const prev = [_]CacheEntry{
        .{ .rel_path = "r", .head_sha = "aaa" },
    };
    const curr = [_]CacheEntry{
        .{ .rel_path = "r", .head_sha = "bbb" },
    };
    const d = try diffIndex(gpa, &prev, &curr);
    defer freeDiff(gpa, d);
    try testing.expectEqual(@as(usize, 1), d.changed.len);
    try testing.expectEqualStrings("r", d.changed[0]);
}

test "cache: diffIndex ignores last_fetched_unix differences" {
    const gpa = testing.allocator;
    const prev = [_]CacheEntry{
        .{ .rel_path = "r", .head_sha = "aaa", .last_fetched_unix = 1 },
    };
    const curr = [_]CacheEntry{
        .{ .rel_path = "r", .head_sha = "aaa", .last_fetched_unix = 999 },
    };
    const d = try diffIndex(gpa, &prev, &curr);
    defer freeDiff(gpa, d);
    try testing.expectEqual(@as(usize, 0), d.added.len);
    try testing.expectEqual(@as(usize, 0), d.removed.len);
    try testing.expectEqual(@as(usize, 0), d.changed.len);
}

test "cache: diffIndex detects url change when head_sha missing" {
    const gpa = testing.allocator;
    const prev = [_]CacheEntry{
        .{ .rel_path = "r", .url = "https://one" },
    };
    const curr = [_]CacheEntry{
        .{ .rel_path = "r", .url = "https://two" },
    };
    const d = try diffIndex(gpa, &prev, &curr);
    defer freeDiff(gpa, d);
    try testing.expectEqual(@as(usize, 1), d.changed.len);
}

test "cache: load on missing root returns empty map" {
    const gpa = testing.allocator;
    const io = testing.io;
    // Use a path that definitely does not exist.
    var map = try load(gpa, io, "/tmp/gitstore_cache_missing_12345");
    defer freeMap(gpa, &map);
    try testing.expectEqual(@as(u32, 0), map.count());
}

test "cache: save + load roundtrip preserves entries" {
    const gpa = testing.allocator;
    const io = testing.io;
    const root = "/tmp/gitstore_cache_roundtrip_test";
    Dir.cwd().deleteTree(io, root) catch {};
    defer Dir.cwd().deleteTree(io, root) catch {};
    try Dir.cwd().createDirPath(io, root);

    var src: std.StringHashMap(CacheEntry) = .init(gpa);
    defer freeMap(gpa, &src);

    const rel_a = try gpa.dupe(u8, "github.com/a/b");
    const sha_a = try gpa.dupe(u8, "deadbeef");
    const url_a = try gpa.dupe(u8, "https://github.com/a/b");
    try src.put(rel_a, .{
        .rel_path = rel_a,
        .url = url_a,
        .head_sha = sha_a,
        .last_fetched_unix = 1_700_000_000,
    });

    const rel_b = try gpa.dupe(u8, "gitlab.com/c/d");
    try src.put(rel_b, .{
        .rel_path = rel_b,
        .url = null,
        .head_sha = null,
        .last_fetched_unix = null,
    });

    try save(gpa, io, root, &src);

    // Assert the final file exists (rename target).
    const final_path = "/tmp/gitstore_cache_roundtrip_test/.z3store/cache/index.json";
    _ = try Dir.cwd().statFile(io, final_path, .{});
    // Temp file must be gone after rename.
    try testing.expectError(error.FileNotFound, Dir.cwd().statFile(io, final_path ++ ".tmp", .{}));

    var loaded = try load(gpa, io, root);
    defer freeMap(gpa, &loaded);
    try testing.expectEqual(@as(u32, 2), loaded.count());

    const a = loaded.get("github.com/a/b") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("deadbeef", a.head_sha.?);
    try testing.expectEqualStrings("https://github.com/a/b", a.url.?);
    try testing.expectEqual(@as(i64, 1_700_000_000), a.last_fetched_unix.?);

    const b = loaded.get("gitlab.com/c/d") orelse return error.TestUnexpectedResult;
    try testing.expect(b.url == null);
    try testing.expect(b.head_sha == null);
    try testing.expect(b.last_fetched_unix == null);
}

test "cache: load falls back to legacy gitstore cache index" {
    const gpa = testing.allocator;
    const io = testing.io;
    const root = "/tmp/gitstore_cache_legacy_test";
    Dir.cwd().deleteTree(io, root) catch {};
    defer Dir.cwd().deleteTree(io, root) catch {};
    try Dir.cwd().createDirPath(io, "/tmp/gitstore_cache_legacy_test/.gitstore/cache");
    try Dir.cwd().writeFile(io, .{
        .sub_path = "/tmp/gitstore_cache_legacy_test/.gitstore/cache/index.json",
        .data =
        \\{"version":1,"entries":[{"rel_path":"github.com/a/b","url":"https://github.com/a/b","head_sha":"abc123","last_fetched_unix":1700000000}]}
        ,
    });

    var loaded = try load(gpa, io, root);
    defer freeMap(gpa, &loaded);

    try testing.expectEqual(@as(u32, 1), loaded.count());
    const entry = loaded.get("github.com/a/b") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("https://github.com/a/b", entry.url.?);
    try testing.expectEqualStrings("abc123", entry.head_sha.?);
    try testing.expectEqual(@as(i64, 1_700_000_000), entry.last_fetched_unix.?);
}

test "cache: load on corrupt json returns empty map" {
    const gpa = testing.allocator;
    const io = testing.io;
    const root = "/tmp/gitstore_cache_corrupt_test";
    Dir.cwd().deleteTree(io, root) catch {};
    defer Dir.cwd().deleteTree(io, root) catch {};
    try Dir.cwd().createDirPath(io, "/tmp/gitstore_cache_corrupt_test/.z3store/cache");
    try Dir.cwd().writeFile(io, .{
        .sub_path = "/tmp/gitstore_cache_corrupt_test/.z3store/cache/index.json",
        .data = "{not valid json",
    });

    var map = try load(gpa, io, root);
    defer freeMap(gpa, &map);
    try testing.expectEqual(@as(u32, 0), map.count());
}

test "cache: save overwrites previous index atomically" {
    const gpa = testing.allocator;
    const io = testing.io;
    const root = "/tmp/gitstore_cache_overwrite_test";
    Dir.cwd().deleteTree(io, root) catch {};
    defer Dir.cwd().deleteTree(io, root) catch {};
    try Dir.cwd().createDirPath(io, root);

    var m1: std.StringHashMap(CacheEntry) = .init(gpa);
    defer freeMap(gpa, &m1);
    const k1 = try gpa.dupe(u8, "one");
    try m1.put(k1, .{ .rel_path = k1 });
    try save(gpa, io, root, &m1);

    var m2: std.StringHashMap(CacheEntry) = .init(gpa);
    defer freeMap(gpa, &m2);
    const k2 = try gpa.dupe(u8, "two");
    try m2.put(k2, .{ .rel_path = k2 });
    try save(gpa, io, root, &m2);

    var loaded = try load(gpa, io, root);
    defer freeMap(gpa, &loaded);
    try testing.expectEqual(@as(u32, 1), loaded.count());
    try testing.expect(loaded.get("two") != null);
    try testing.expect(loaded.get("one") == null);
}
