//! Canonical z3store multi-store configuration.
//!
//! This module implements the first executable slice of the multi-store plan:
//! resolve codestore/gitstore/toolstore/cachestore roots, create a safe
//! codestore-local `z3store.toml`, and expose strict package/workflow defaults.
//!
//! Naming: `z3store` is the product. `gitstore` survives only as the name of
//! the git-backed store tier (detached Git/JJ databases), mirroring
//! `config.zig`'s `backing_store_root`. Environment and config keys follow the
//! repo-wide convention established in `config.zig`: `Z3STORE_*` / `z3store.*`
//! are primary and the `GITSTORE_*` / `gitstore.*` forms remain legacy
//! fallbacks.

const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;

pub const StoreConfig = struct {
    codestore_root: []const u8,
    gitstore_root: []const u8,
    toolstore_root: []const u8,
    cachestore_root: []const u8,
    config_path: []const u8,
    used_bootstrap_config: bool,
    used_legacy_root: bool,
    owned_strings: std.ArrayList([]const u8),

    pub fn deinit(self: *StoreConfig, gpa: Allocator) void {
        for (self.owned_strings.items) |s| gpa.free(s);
        self.owned_strings.deinit(gpa);
        self.* = undefined;
    }
};

/// The four store tiers. `gitstore` names the git-backed tier holding detached
/// Git/JJ databases — it describes git itself, not the product, and stays
/// aligned with `config.zig`'s `backing_store_root`.
pub const StoreName = enum {
    codestore,
    gitstore,
    toolstore,
    cachestore,
};

pub const LoadError = error{
    OutOfMemory,
    InvalidUserId,
    InvalidTomlString,
} || Dir.OpenError || Dir.ReadFileAllocError || Dir.StatFileError;

/// parseStoreName maps canonical store names to StoreName. `--code` and
/// `--store` are legacy CLI flag aliases from the earlier root command surface:
/// they intentionally map to `.codestore` and `.gitstore` for compatibility and
/// should only be removed in a major version. `toolstore` and `cachestore` are
/// canonical names only.
pub fn parseStoreName(s: []const u8) ?StoreName {
    if (std.mem.eql(u8, s, "codestore") or std.mem.eql(u8, s, "--code")) return .codestore;
    if (std.mem.eql(u8, s, "gitstore") or std.mem.eql(u8, s, "--store")) return .gitstore;
    if (std.mem.eql(u8, s, "toolstore")) return .toolstore;
    if (std.mem.eql(u8, s, "cachestore")) return .cachestore;
    return null;
}

pub fn rootFor(cfg: StoreConfig, name: StoreName) []const u8 {
    return switch (name) {
        .codestore => cfg.codestore_root,
        .gitstore => cfg.gitstore_root,
        .toolstore => cfg.toolstore_root,
        .cachestore => cfg.cachestore_root,
    };
}

pub fn load(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) LoadError!StoreConfig {
    var owned: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (owned.items) |s| gpa.free(s);
        owned.deinit(gpa);
    }

    const home = env.get("HOME") orelse return error.InvalidUserId;
    const xdg_config = env.get("XDG_CONFIG_HOME") orelse try appendOwned(&owned, gpa, try std.fmt.allocPrint(gpa, "{s}/.config", .{home}));
    const bootstrap_path = try appendOwned(&owned, gpa, try std.fmt.allocPrint(gpa, "{s}/z3store/z3store.toml", .{xdg_config}));

    var bootstrap = try ParsedConfig.read(gpa, io, bootstrap_path);
    defer bootstrap.deinit(gpa);

    const legacy_root = firstNonEmpty(&.{
        env.get("CODESTORE_ROOT"),
        env.get("Z3STORE_CODESTORE_ROOT"),
        env.get("GITSTORE_CODESTORE_ROOT"),
        env.get("Z3STORE_ROOT"),
        env.get("GITSTORE_ROOT"),
        env.get("GHQ_ROOT"),
    });
    const default_codestore = try appendOwned(&owned, gpa, try std.fmt.allocPrint(gpa, "{s}/ghq", .{home}));
    const codestore_root = try appendOwned(&owned, gpa, try gpa.dupe(u8, firstNonEmpty(&.{
        bootstrap.get("codestore.root"),
        legacy_root,
        default_codestore,
    }).?));

    const codestore_config_path = try appendOwned(&owned, gpa, try std.fmt.allocPrint(gpa, "{s}/z3store.toml", .{codestore_root}));
    var codestore_config = try ParsedConfig.read(gpa, io, codestore_config_path);
    defer codestore_config.deinit(gpa);

    const active = if (codestore_config.exists) &codestore_config else &bootstrap;
    const default_gitstore = try appendOwned(&owned, gpa, try std.fmt.allocPrint(gpa, "{s}/.local/share/z3store", .{home}));
    const default_toolstore = try appendOwned(&owned, gpa, try std.fmt.allocPrint(gpa, "{s}/.local/share/toolstore", .{home}));
    const default_cachestore = try appendOwned(&owned, gpa, try std.fmt.allocPrint(gpa, "{s}/.cache/z3store", .{home}));

    const gitstore_root = try appendOwned(&owned, gpa, try gpa.dupe(u8, firstNonEmpty(&.{
        active.get("gitstore.root"),
        env.get("Z3STORE_BACKING_STORE_ROOT"),
        env.get("GITSTORE_BACKING_STORE_ROOT"),
        default_gitstore,
    }).?));
    const toolstore_root = try appendOwned(&owned, gpa, try gpa.dupe(u8, firstNonEmpty(&.{
        active.get("toolstore.root"),
        env.get("TOOLSTORE_ROOT"),
        default_toolstore,
    }).?));
    const cachestore_root = try appendOwned(&owned, gpa, try gpa.dupe(u8, firstNonEmpty(&.{
        active.get("cachestore.root"),
        env.get("CACHESTORE_ROOT"),
        default_cachestore,
    }).?));

    const resolved_config_path = if (codestore_config.exists)
        codestore_config_path
    else if (bootstrap.exists)
        bootstrap_path
    else
        codestore_config_path;

    return .{
        .codestore_root = codestore_root,
        .gitstore_root = gitstore_root,
        .toolstore_root = toolstore_root,
        .cachestore_root = cachestore_root,
        .config_path = resolved_config_path,
        .used_bootstrap_config = !codestore_config.exists and bootstrap.exists,
        .used_legacy_root = legacy_root != null,
        .owned_strings = owned,
    };
}

pub fn ensureInitialized(gpa: Allocator, io: Io, cfg: StoreConfig) !bool {
    try Dir.cwd().createDirPath(io, cfg.codestore_root);
    try Dir.cwd().createDirPath(io, cfg.gitstore_root);
    try Dir.cwd().createDirPath(io, cfg.toolstore_root);
    try Dir.cwd().createDirPath(io, cfg.cachestore_root);

    _ = Dir.cwd().statFile(io, cfg.config_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            const parent = parentOf(cfg.config_path) orelse ".";
            try Dir.cwd().createDirPath(io, parent);
            const content = try defaultToml(gpa, cfg);
            defer gpa.free(content);
            try Dir.cwd().writeFile(io, .{ .sub_path = cfg.config_path, .data = content });
            return true;
        },
        else => return err,
    };
    return false;
}

pub fn defaultToml(gpa: Allocator, cfg: StoreConfig) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\version = 1
        \\
        \\[codestore]
        \\root = "{s}"
        \\
        \\[gitstore]
        \\root = "{s}"
        \\
        \\[toolstore]
        \\root = "{s}"
        \\
        \\[cachestore]
        \\root = "{s}"
        \\
        \\[policy.package_managers]
        \\node = "vite-plus-bun"
        \\node_exceptions = ["pnpm"]
        \\python = "pixi"
        \\r = "pixi"
        \\default = "mise"
        \\
        \\[policy.workflows]
        \\supported = ["snakemake", "make", "cmake", "helm", "kubernetes"]
        \\gitops = true
        \\
    , .{ cfg.codestore_root, cfg.gitstore_root, cfg.toolstore_root, cfg.cachestore_root });
}

pub const schema_json = @embedFile("z3store.schema.json");

fn firstNonEmpty(values: []const ?[]const u8) ?[]const u8 {
    for (values) |maybe| {
        if (maybe) |value| {
            if (value.len != 0) return value;
        }
    }
    return null;
}

fn appendOwned(list: *std.ArrayList([]const u8), gpa: Allocator, value: []const u8) ![]const u8 {
    try list.append(gpa, value);
    return value;
}

fn parentOf(path: []const u8) ?[]const u8 {
    var i = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '/') {
            if (i == 1) return path[0..1];
            return path[0 .. i - 1];
        }
    }
    return null;
}

const ParsedConfig = struct {
    exists: bool,
    entries: std.StringHashMap([]const u8),

    fn read(gpa: Allocator, io: Io, path: []const u8) !ParsedConfig {
        var entries: std.StringHashMap([]const u8) = .init(gpa);
        errdefer {
            var it = entries.iterator();
            while (it.next()) |kv| {
                gpa.free(kv.key_ptr.*);
                gpa.free(kv.value_ptr.*);
            }
            entries.deinit();
        }

        const bytes = Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return .{ .exists = false, .entries = entries },
            else => return err,
        };
        defer gpa.free(bytes);

        try parseTomlSubset(gpa, bytes, &entries);
        return .{ .exists = true, .entries = entries };
    }

    fn get(self: *const ParsedConfig, key: []const u8) ?[]const u8 {
        return self.entries.get(key);
    }

    fn deinit(self: *ParsedConfig, gpa: Allocator) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            gpa.free(kv.key_ptr.*);
            gpa.free(kv.value_ptr.*);
        }
        self.entries.deinit();
    }
};

/// Parse the deliberately small `z3store.toml` bootstrap subset used before a
/// full schema validator is available. Supported input is simple `[section]`
/// headers plus `root = "value"` assignments. Dotted section names are
/// preserved verbatim when composing `section.root` map entries. This parser
/// intentionally ignores non-root metadata and policy fields, rejects unquoted
/// root values, does not process escapes, and does not support single-quoted
/// strings, multi-line strings, arrays, or inline tables. Switch to a full TOML
/// parser if broader TOML support becomes required.
fn parseTomlSubset(gpa: Allocator, bytes: []const u8, entries: *std.StringHashMap([]const u8)) !void {
    var section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key_part = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.mem.eql(u8, key_part, "root")) continue;
        var value_part = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (value_part.len < 2 or value_part[0] != '"' or value_part[value_part.len - 1] != '"') {
            return error.InvalidTomlString;
        }
        value_part = value_part[1 .. value_part.len - 1];
        const full_key = if (section.len == 0)
            try gpa.dupe(u8, key_part)
        else
            try std.fmt.allocPrint(gpa, "{s}.{s}", .{ section, key_part });
        errdefer gpa.free(full_key);
        const value = try gpa.dupe(u8, value_part);
        errdefer gpa.free(value);
        try entries.put(full_key, value);
    }
}

test "stores: parse store names" {
    try std.testing.expectEqual(StoreName.codestore, parseStoreName("codestore").?);
    try std.testing.expectEqual(StoreName.gitstore, parseStoreName("gitstore").?);
    try std.testing.expectEqual(StoreName.toolstore, parseStoreName("toolstore").?);
    try std.testing.expectEqual(StoreName.cachestore, parseStoreName("cachestore").?);
    try std.testing.expect(parseStoreName("unknown") == null);
}

test "stores: parse toml subset with sections" {
    const gpa = std.testing.allocator;
    var entries: std.StringHashMap([]const u8) = .init(gpa);
    defer {
        var it = entries.iterator();
        while (it.next()) |kv| {
            gpa.free(kv.key_ptr.*);
            gpa.free(kv.value_ptr.*);
        }
        entries.deinit();
    }
    try parseTomlSubset(gpa,
        \\[codestore]
        \\root = "/tmp/code"
        \\
        \\[gitstore]
        \\root = "/tmp/git"
        \\
    , &entries);
    try std.testing.expectEqualStrings("/tmp/code", entries.get("codestore.root").?);
    try std.testing.expectEqualStrings("/tmp/git", entries.get("gitstore.root").?);
}

test "stores: reject unquoted root values" {
    const gpa = std.testing.allocator;
    var entries: std.StringHashMap([]const u8) = .init(gpa);
    defer entries.deinit();
    try std.testing.expectError(error.InvalidTomlString, parseTomlSubset(gpa,
        \\[codestore]
        \\root = /tmp/code
        \\
    , &entries));
}
