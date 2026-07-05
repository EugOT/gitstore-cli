//! EpicGames Lore workspace recognition (read-only, conservative).
//!
//! Lore is a workspace/VCS system whose per-worktree metadata lives in a
//! `.lore/` directory at the worktree root. Ground truth (cited from the live
//! Lore docs, verified 2026-07-04):
//!
//!   - `.lore/` contains at least:
//!       * `config.toml` — client configuration, including the
//!         `[shared_store_to_use]` table with `use_shared_store` (bool) and
//!         `shared_store_path` (string).
//!       * `instance`    — a UUIDv7 identifying the workspace instance.
//!       * `view`        — the materialized view state.
//!     Reference: https://epicgames.github.io/lore/reference/lore-cli-config/
//!
//!   - `.lore/` is NOT relocatable. Unlike z3store's git/jj adoption (which
//!     replaces `.git` with a `gitdir:` pointer into the store), Lore exposes
//!     NO pointer/symlink indirection for its workspace metadata, and its
//!     on-disk formats are explicitly pre-1.0 and subject to change. Moving or
//!     symlinking `.lore/` is unsupported and unsafe.
//!     Reference: https://epicgames.github.io/lore/explanation/system-design/ §24.1
//!
//!   - The sanctioned way to keep bulk data out of the worktree is Lore's OWN
//!     shared-store feature (`lore shared-store`, configured via the
//!     `[shared_store_to_use]` table), NOT external relocation.
//!
//! Consequently z3store treats Lore workspaces as first-class-but-immovable:
//! it recognizes and reports them, refuses to adopt a Lore-only workspace, and
//! NEVER writes into `.lore/`. This module is pure recognition + a minimal
//! read-only config scanner (no TOML dependency). Every filesystem op takes the
//! injected `std.Io`.

const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;

/// Lore configs are small client metadata; cap reads so a corrupt file cannot
/// make `zt lore` allocate unbounded memory.
const max_lore_config_bytes = 1 * 1024 * 1024;

/// Result of inspecting a candidate Lore workspace. `shared_store_path` (when
/// present) is heap-owned by the allocator passed to `loreStatus`; call
/// `deinit` to release it.
pub const LoreStatus = struct {
    /// `.lore/config.toml` exists and was readable.
    has_config: bool,
    /// `.lore/config.toml` exists but could not be parsed/read within limits.
    config_parse_failed: bool,
    /// `.lore/instance` exists (the load-bearing marker of a Lore workspace).
    has_instance: bool,
    /// `[shared_store_to_use].use_shared_store` parsed as `true`.
    shared_store_configured: bool,
    /// `[shared_store_to_use].shared_store_path` value, if set. Owned.
    shared_store_path: ?[]u8,

    pub fn deinit(self: *LoreStatus, gpa: Allocator) void {
        if (self.shared_store_path) |p| gpa.free(p);
        self.* = undefined;
    }
};

/// True when `path` is an EpicGames Lore workspace: a `.lore/` directory that
/// contains an `instance` file. The `instance` file (not merely the directory)
/// is the marker, matching Lore's own on-disk contract and avoiding false
/// positives on an empty/partial `.lore/`.
///
/// Signature is intentionally allocation-free: a stack buffer builds the probe
/// path. An over-long path yields `false` (it cannot be a valid workspace we
/// could act on anyway).
pub fn detectLoreWorkspace(io: Io, path: []const u8) bool {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const probe = std.fmt.bufPrint(&buf, "{s}/.lore/instance", .{path}) catch return false;
    _ = Dir.cwd().statFile(io, probe, .{}) catch return false;
    return true;
}

/// Inspect the `.lore/` metadata under `path` and report presence of the
/// `instance`/`config.toml` files plus the parsed `[shared_store_to_use]`
/// settings. Read-only: nothing under `.lore/` is ever written.
///
/// Only the `OutOfMemory` failure propagates; a missing/unreadable config is
/// reported as `has_config = false` rather than an error, so callers can report
/// a partial Lore workspace instead of aborting.
pub fn loreStatus(gpa: Allocator, io: Io, path: []const u8) !LoreStatus {
    var st: LoreStatus = .{
        .has_config = false,
        .config_parse_failed = false,
        .has_instance = false,
        .shared_store_configured = false,
        .shared_store_path = null,
    };

    const instance_path = try std.fmt.allocPrint(gpa, "{s}/.lore/instance", .{path});
    defer gpa.free(instance_path);
    if (Dir.cwd().statFile(io, instance_path, .{})) |_| {
        st.has_instance = true;
    } else |_| {}

    const config_path = try std.fmt.allocPrint(gpa, "{s}/.lore/config.toml", .{path});
    defer gpa.free(config_path);
    const content = Dir.cwd().readFileAlloc(io, config_path, gpa, .limited(max_lore_config_bytes)) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (err == error.StreamTooLong) {
            st.has_config = true;
            st.config_parse_failed = true;
            return st;
        }
        // Absent / not-a-file / permission: report as no config, keep going.
        return st;
    };
    defer gpa.free(content);
    st.has_config = true;

    try parseSharedStore(gpa, content, &st);
    return st;
}

/// Strip a single pair of matching ASCII quotes (`"` or `'`) from `v`.
fn stripQuotes(v: []const u8) []const u8 {
    if (v.len >= 2 and (v[0] == '"' or v[0] == '\'') and v[v.len - 1] == v[0]) {
        return v[1 .. v.len - 1];
    }
    return v;
}

/// Strip TOML inline comments while preserving `#` bytes inside quoted values.
fn stripUnquotedInlineComment(line: []const u8) []const u8 {
    var in_single = false;
    var in_double = false;
    var escaped = false;

    for (line, 0..) |c, i| {
        if (in_double) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_double = false;
            }
            continue;
        }
        if (in_single) {
            if (c == '\'') in_single = false;
            continue;
        }

        switch (c) {
            '#' => return line[0..i],
            '"' => in_double = true,
            '\'' => in_single = true,
            else => {},
        }
    }
    return line;
}

/// Minimal line scanner for the ONLY keys z3store cares about:
/// `[shared_store_to_use].use_shared_store` and `.shared_store_path`. This is
/// deliberately not a general TOML parser — it tracks the current `[table]`
/// header, ignores comments/blank lines, and reads `key = value` pairs inside
/// the `shared_store_to_use` table only.
fn parseSharedStore(gpa: Allocator, content: []const u8, st: *LoreStatus) !void {
    var in_section = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, stripUnquotedInlineComment(raw), " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            const name = std.mem.trim(u8, line[1..close], " \t");
            in_section = std.mem.eql(u8, name, "shared_store_to_use");
            continue;
        }
        if (!in_section) continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (std.mem.eql(u8, key, "use_shared_store")) {
            const v = stripQuotes(val);
            if (std.mem.eql(u8, v, "true")) {
                st.shared_store_configured = true;
            } else if (std.mem.eql(u8, v, "false")) {
                st.shared_store_configured = false;
            }
        } else if (std.mem.eql(u8, key, "shared_store_path")) {
            const v = stripQuotes(val);
            if (v.len > 0) {
                if (st.shared_store_path) |old| gpa.free(old);
                st.shared_store_path = try gpa.dupe(u8, v);
            }
        }
    }
}

// =========================================================
// Tests
// =========================================================

const testing = std.testing;

/// Create a unique throwaway workspace dir under /tmp. Caller frees the path
/// and is responsible for deleting the tree.
fn uniqueWs(gpa: Allocator, io: Io, tag: []const u8) ![]u8 {
    var marker: u8 = undefined;
    const ns = Io.Clock.real.now(io).nanoseconds;
    const path = try std.fmt.allocPrint(
        gpa,
        "/tmp/z3s_lore_{s}_{x}_{x}",
        .{ tag, @as(u64, @intCast(ns)), @intFromPtr(&marker) },
    );
    Dir.cwd().deleteTree(io, path) catch {};
    try Dir.cwd().createDirPath(io, path);
    return path;
}

fn writeLoreFile(gpa: Allocator, io: Io, ws: []const u8, name: []const u8, body: []const u8) !void {
    const dir = try std.fmt.allocPrint(gpa, "{s}/.lore", .{ws});
    defer gpa.free(dir);
    try Dir.cwd().createDirPath(io, dir);
    const file = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name });
    defer gpa.free(file);
    try Dir.cwd().writeFile(io, .{ .sub_path = file, .data = body });
}

test "lore: detectLoreWorkspace true only with .lore/instance" {
    const gpa = testing.allocator;
    const io = testing.io;
    const ws = try uniqueWs(gpa, io, "detect");
    defer {
        Dir.cwd().deleteTree(io, ws) catch {};
        gpa.free(ws);
    }

    // Bare dir: not a workspace.
    try testing.expect(!detectLoreWorkspace(io, ws));

    // .lore/ without instance: still not a workspace.
    try writeLoreFile(gpa, io, ws, "config.toml", "x = 1\n");
    try testing.expect(!detectLoreWorkspace(io, ws));

    // .lore/instance present: recognized.
    try writeLoreFile(gpa, io, ws, "instance", "0192f000-0000-7000-8000-000000000000\n");
    try testing.expect(detectLoreWorkspace(io, ws));
}

test "lore: loreStatus parses shared_store_to_use table" {
    const gpa = testing.allocator;
    const io = testing.io;
    const ws = try uniqueWs(gpa, io, "status");
    defer {
        Dir.cwd().deleteTree(io, ws) catch {};
        gpa.free(ws);
    }

    try writeLoreFile(gpa, io, ws, "instance", "0192f000-0000-7000-8000-000000000000\n");
    try writeLoreFile(gpa, io, ws, "config.toml",
        \\# lore client config
        \\[other]
        \\use_shared_store = false
        \\
        \\[shared_store_to_use]
        \\use_shared_store = true
        \\shared_store_path = "/srv/lore/shared"
        \\
    );

    var st = try loreStatus(gpa, io, ws);
    defer st.deinit(gpa);

    try testing.expect(st.has_instance);
    try testing.expect(st.has_config);
    try testing.expect(st.shared_store_configured);
    try testing.expect(st.shared_store_path != null);
    try testing.expectEqualStrings("/srv/lore/shared", st.shared_store_path.?);
}

test "lore: loreStatus parses bool with unquoted inline comment" {
    const gpa = testing.allocator;
    const io = testing.io;
    const ws = try uniqueWs(gpa, io, "inline_bool_comment");
    defer {
        Dir.cwd().deleteTree(io, ws) catch {};
        gpa.free(ws);
    }

    try writeLoreFile(gpa, io, ws, "instance", "id\n");
    try writeLoreFile(gpa, io, ws, "config.toml",
        \\[shared_store_to_use]
        \\use_shared_store = true # enabled for this workspace
        \\
    );

    var st = try loreStatus(gpa, io, ws);
    defer st.deinit(gpa);

    try testing.expect(st.shared_store_configured);
}

test "lore: loreStatus preserves hash inside quoted shared_store_path" {
    const gpa = testing.allocator;
    const io = testing.io;
    const ws = try uniqueWs(gpa, io, "quoted_hash");
    defer {
        Dir.cwd().deleteTree(io, ws) catch {};
        gpa.free(ws);
    }

    try writeLoreFile(gpa, io, ws, "instance", "id\n");
    try writeLoreFile(gpa, io, ws, "config.toml",
        \\[shared_store_to_use] # selected store
        \\use_shared_store = true
        \\shared_store_path = "/srv/lore#shared" # literal # is inside quotes
        \\
    );

    var st = try loreStatus(gpa, io, ws);
    defer st.deinit(gpa);

    try testing.expect(st.shared_store_path != null);
    try testing.expectEqualStrings("/srv/lore#shared", st.shared_store_path.?);
}

test "lore: loreStatus without config reports partial workspace" {
    const gpa = testing.allocator;
    const io = testing.io;
    const ws = try uniqueWs(gpa, io, "partial");
    defer {
        Dir.cwd().deleteTree(io, ws) catch {};
        gpa.free(ws);
    }

    try writeLoreFile(gpa, io, ws, "instance", "0192f000-0000-7000-8000-000000000000\n");

    var st = try loreStatus(gpa, io, ws);
    defer st.deinit(gpa);

    try testing.expect(st.has_instance);
    try testing.expect(!st.has_config);
    try testing.expect(!st.shared_store_configured);
    try testing.expect(st.shared_store_path == null);
}

test "lore: loreStatus treats oversized config as parse failure" {
    const gpa = testing.allocator;
    const io = testing.io;
    const ws = try uniqueWs(gpa, io, "oversize");
    defer {
        Dir.cwd().deleteTree(io, ws) catch {};
        gpa.free(ws);
    }

    try writeLoreFile(gpa, io, ws, "instance", "0192f000-0000-7000-8000-000000000000\n");
    const big = try gpa.alloc(u8, max_lore_config_bytes + 1);
    defer gpa.free(big);
    @memset(big, 'x');
    try writeLoreFile(gpa, io, ws, "config.toml", big);

    var st = try loreStatus(gpa, io, ws);
    defer st.deinit(gpa);

    try testing.expect(st.has_instance);
    try testing.expect(st.has_config);
    try testing.expect(st.config_parse_failed);
    try testing.expect(!st.shared_store_configured);
    try testing.expect(st.shared_store_path == null);
}

test "lore: loreStatus ignores keys outside the shared_store_to_use table" {
    const gpa = testing.allocator;
    const io = testing.io;
    const ws = try uniqueWs(gpa, io, "scoped");
    defer {
        Dir.cwd().deleteTree(io, ws) catch {};
        gpa.free(ws);
    }

    try writeLoreFile(gpa, io, ws, "instance", "id\n");
    try writeLoreFile(gpa, io, ws, "config.toml",
        \\shared_store_path = "/not/in/table"
        \\use_shared_store = true
        \\[shared_store_to_use]
        \\use_shared_store = false
        \\
    );

    var st = try loreStatus(gpa, io, ws);
    defer st.deinit(gpa);

    try testing.expect(st.has_config);
    // Only the in-table `use_shared_store = false` counts; the pre-table
    // `shared_store_path` MUST NOT be captured.
    try testing.expect(!st.shared_store_configured);
    try testing.expect(st.shared_store_path == null);
}
