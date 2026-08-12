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

const RootResolution = struct {
    value: []const u8,
    legacy: bool,
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

// ziglint-ignore: Z015 - LoadError is a public composed error set; ziglint
// 0.5.2 false-positives on same-file public error-set references.
pub fn load(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) LoadError!StoreConfig {
    var owned: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (owned.items) |s| gpa.free(s);
        owned.deinit(gpa);
    }

    const home = env.get("HOME") orelse return error.InvalidUserId;
    const xdg_config = env.get("XDG_CONFIG_HOME") orelse try appendOwned(
        gpa,
        &owned,
        try std.fmt.allocPrint(gpa, "{s}/.config", .{home}),
    );
    const bootstrap_path = try appendOwned(
        gpa,
        &owned,
        try std.fmt.allocPrint(gpa, "{s}/z3store/z3store.toml", .{xdg_config}),
    );

    var bootstrap = try ParsedConfig.read(gpa, io, bootstrap_path);
    defer bootstrap.deinit(gpa);

    const default_codestore = try appendOwned(gpa, &owned, try std.fmt.allocPrint(gpa, "{s}/ghq", .{home}));
    const codestore_resolution = resolveCodestoreRootChain(
        bootstrap.get("codestore.root"),
        env.get("CODESTORE_ROOT"),
        env.get("Z3STORE_CODESTORE_ROOT"),
        env.get("Z3STORE_ROOT"),
        env.get("GITSTORE_CODESTORE_ROOT"),
        env.get("GITSTORE_ROOT"),
        env.get("GHQ_ROOT"),
        default_codestore,
    );
    const codestore_root = try appendOwned(gpa, &owned, try gpa.dupe(u8, codestore_resolution.value));

    const codestore_config_path = try appendOwned(
        gpa,
        &owned,
        try std.fmt.allocPrint(gpa, "{s}/z3store.toml", .{codestore_root}),
    );
    var codestore_config = try ParsedConfig.read(gpa, io, codestore_config_path);
    defer codestore_config.deinit(gpa);

    const active = if (codestore_config.exists) &codestore_config else &bootstrap;
    const default_gitstore = try appendOwned(
        gpa,
        &owned,
        try std.fmt.allocPrint(gpa, "{s}/.local/share/z3store", .{home}),
    );
    const default_toolstore = try appendOwned(
        gpa,
        &owned,
        try std.fmt.allocPrint(gpa, "{s}/.local/share/toolstore", .{home}),
    );
    const default_cachestore = try appendOwned(gpa, &owned, try std.fmt.allocPrint(gpa, "{s}/.cache/z3store", .{home}));

    const gitstore_root = try appendOwned(gpa, &owned, try gpa.dupe(u8, firstNonEmpty(&.{
        active.get("gitstore.root"),
        env.get("Z3STORE_BACKING_STORE_ROOT"),
        env.get("GITSTORE_BACKING_STORE_ROOT"),
        default_gitstore,
    }).?));
    const toolstore_root = try appendOwned(gpa, &owned, try gpa.dupe(u8, firstNonEmpty(&.{
        active.get("toolstore.root"),
        env.get("TOOLSTORE_ROOT"),
        default_toolstore,
    }).?));
    const cachestore_root = try appendOwned(gpa, &owned, try gpa.dupe(u8, firstNonEmpty(&.{
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
        .used_legacy_root = codestore_resolution.legacy,
        .owned_strings = owned,
    };
}

pub fn ensureInitialized(gpa: Allocator, io: Io, cfg: StoreConfig) !bool {
    try Dir.cwd().createDirPath(io, cfg.codestore_root);
    try Dir.cwd().createDirPath(io, cfg.gitstore_root);
    try Dir.cwd().createDirPath(io, cfg.toolstore_root);
    try Dir.cwd().createDirPath(io, cfg.cachestore_root);

    const parent = parentOf(cfg.config_path) orelse ".";
    try Dir.cwd().createDirPath(io, parent);
    const content = try defaultToml(gpa, cfg);
    defer gpa.free(content);
    Dir.cwd().writeFile(io, .{
        .sub_path = cfg.config_path,
        .data = content,
        .flags = .{ .exclusive = true },
    }) catch |err| switch (err) {
        error.PathAlreadyExists => return false,
        else => return err,
    };
    return true;
}

pub fn defaultToml(gpa: Allocator, cfg: StoreConfig) ![]u8 {
    const codestore_root = try encodeTomlBasicString(gpa, cfg.codestore_root);
    defer gpa.free(codestore_root);
    const gitstore_root = try encodeTomlBasicString(gpa, cfg.gitstore_root);
    defer gpa.free(gitstore_root);
    const toolstore_root = try encodeTomlBasicString(gpa, cfg.toolstore_root);
    defer gpa.free(toolstore_root);
    const cachestore_root = try encodeTomlBasicString(gpa, cfg.cachestore_root);
    defer gpa.free(cachestore_root);

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
    , .{ codestore_root, gitstore_root, toolstore_root, cachestore_root });
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

fn resolveCodestoreRootChain(
    bootstrap: ?[]const u8,
    env_codestore: ?[]const u8,
    env_z3_codestore: ?[]const u8,
    env_z3_root: ?[]const u8,
    env_gitstore_codestore: ?[]const u8,
    env_gitstore_root: ?[]const u8,
    env_ghq_root: ?[]const u8,
    default_value: []const u8,
) RootResolution {
    if (firstNonEmpty(&.{bootstrap})) |value| return .{ .value = value, .legacy = false };
    if (firstNonEmpty(&.{ env_codestore, env_z3_codestore, env_z3_root })) |value| {
        return .{ .value = value, .legacy = false };
    }
    if (firstNonEmpty(&.{ env_gitstore_codestore, env_gitstore_root, env_ghq_root })) |value| {
        return .{ .value = value, .legacy = true };
    }
    return .{ .value = default_value, .legacy = false };
}

fn appendOwned(gpa: Allocator, list: *std.ArrayList([]const u8), value: []const u8) ![]const u8 {
    errdefer gpa.free(value);
    try list.append(gpa, value);
    return value;
}

fn encodeTomlBasicString(gpa: Allocator, value: []const u8) ![]u8 {
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidTomlString;

    var encoded: std.ArrayList(u8) = .empty;
    errdefer encoded.deinit(gpa);
    const hex = "0123456789ABCDEF";
    for (value) |byte| switch (byte) {
        '"' => try encoded.appendSlice(gpa, "\\\""),
        '\\' => try encoded.appendSlice(gpa, "\\\\"),
        0x08 => try encoded.appendSlice(gpa, "\\b"),
        '\t' => try encoded.appendSlice(gpa, "\\t"),
        '\n' => try encoded.appendSlice(gpa, "\\n"),
        0x0c => try encoded.appendSlice(gpa, "\\f"),
        '\r' => try encoded.appendSlice(gpa, "\\r"),
        0x00...0x07, 0x0b, 0x0e...0x1f, 0x7f => try encoded.appendSlice(gpa, &.{
            '\\',
            'u',
            '0',
            '0',
            hex[byte >> 4],
            hex[byte & 0x0f],
        }),
        else => try encoded.append(gpa, byte),
    };
    return encoded.toOwnedSlice(gpa);
}

fn decodeTomlBasicString(gpa: Allocator, value: []const u8) ![]u8 {
    var decoded: std.ArrayList(u8) = .empty;
    errdefer decoded.deinit(gpa);

    var i: usize = 0;
    while (i < value.len) {
        if (value[i] != '\\') {
            try decoded.append(gpa, value[i]);
            i += 1;
            continue;
        }

        i += 1;
        if (i == value.len) return error.InvalidTomlString;
        switch (value[i]) {
            '"' => try decoded.append(gpa, '"'),
            '\\' => try decoded.append(gpa, '\\'),
            'b' => try decoded.append(gpa, 0x08),
            't' => try decoded.append(gpa, '\t'),
            'n' => try decoded.append(gpa, '\n'),
            'f' => try decoded.append(gpa, 0x0c),
            'r' => try decoded.append(gpa, '\r'),
            'u', 'U' => |kind| {
                const digit_count: usize = if (kind == 'u') 4 else 8;
                if (i + digit_count >= value.len) return error.InvalidTomlString;
                const digits = value[i + 1 .. i + 1 + digit_count];
                const codepoint = std.fmt.parseInt(u21, digits, 16) catch return error.InvalidTomlString;
                var bytes: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(codepoint, &bytes) catch return error.InvalidTomlString;
                try decoded.appendSlice(gpa, bytes[0..len]);
                i += digit_count;
            },
            else => return error.InvalidTomlString,
        }
        i += 1;
    }

    const result = try decoded.toOwnedSlice(gpa);
    if (!std.unicode.utf8ValidateSlice(result)) {
        gpa.free(result);
        return error.InvalidTomlString;
    }
    return result;
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
        self.* = undefined;
    }
};

/// Parse the deliberately small `z3store.toml` bootstrap subset used before a
/// full schema validator is available. Supported input is simple `[section]`
/// headers plus `root = "value"` assignments. Dotted section names are
/// preserved verbatim when composing `section.root` map entries. This parser
/// intentionally ignores non-root metadata and policy fields, rejects unquoted
/// root values, decodes standard TOML basic-string escapes, and does not
/// support single-quoted strings, multi-line strings, arrays, or inline tables.
/// Switch to a full TOML parser if broader TOML support becomes required.
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
        const value = try decodeTomlBasicString(gpa, value_part);
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

test "stores: primary root variables precede legacy aliases" {
    const primary = resolveCodestoreRootChain(null, null, null, "/z3", "/legacy-specific", null, null, "/default");
    try std.testing.expectEqualStrings("/z3", primary.value);
    try std.testing.expect(!primary.legacy);

    const legacy = resolveCodestoreRootChain(null, null, null, null, "/legacy-specific", null, null, "/default");
    try std.testing.expectEqualStrings("/legacy-specific", legacy.value);
    try std.testing.expect(legacy.legacy);
}

test "stores: bootstrap root suppresses unused legacy warning" {
    const resolved = resolveCodestoreRootChain(
        "/bootstrap",
        null,
        null,
        null,
        "/ignored-legacy",
        null,
        null,
        "/default",
    );
    try std.testing.expectEqualStrings("/bootstrap", resolved.value);
    try std.testing.expect(!resolved.legacy);
}

test "stores: appendOwned frees value when registration fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const gpa = failing.allocator();
    const value = try gpa.dupe(u8, "owned");
    var owned: std.ArrayList([]const u8) = .empty;
    defer owned.deinit(gpa);

    try std.testing.expectError(error.OutOfMemory, appendOwned(gpa, &owned, value));
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "stores: generated TOML roots round-trip special characters" {
    const gpa = std.testing.allocator;
    const cfg: StoreConfig = .{
        .codestore_root = "/tmp/quote\"slash\\line\ncontrol\x01",
        .gitstore_root = "/tmp/git",
        .toolstore_root = "/tmp/tool",
        .cachestore_root = "/tmp/cache",
        .config_path = "/tmp/z3store.toml",
        .used_bootstrap_config = false,
        .used_legacy_root = false,
        .owned_strings = .empty,
    };
    const toml = try defaultToml(gpa, cfg);
    defer gpa.free(toml);
    try std.testing.expect(std.mem.indexOf(u8, toml, "quote\\\"slash\\\\line\\ncontrol\\u0001") != null);

    var entries: std.StringHashMap([]const u8) = .init(gpa);
    defer {
        var it = entries.iterator();
        while (it.next()) |kv| {
            gpa.free(kv.key_ptr.*);
            gpa.free(kv.value_ptr.*);
        }
        entries.deinit();
    }
    try parseTomlSubset(gpa, toml, &entries);
    try std.testing.expectEqualStrings(cfg.codestore_root, entries.get("codestore.root").?);
}

test "stores: reject invalid UTF-8 root when generating TOML" {
    const cfg: StoreConfig = .{
        .codestore_root = &.{0xff},
        .gitstore_root = "/tmp/git",
        .toolstore_root = "/tmp/tool",
        .cachestore_root = "/tmp/cache",
        .config_path = "/tmp/z3store.toml",
        .used_bootstrap_config = false,
        .used_legacy_root = false,
        .owned_strings = .empty,
    };
    try std.testing.expectError(error.InvalidTomlString, defaultToml(std.testing.allocator, cfg));
}

test "stores: initialization never overwrites an existing config" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/code", .{tmp.sub_path});
    defer gpa.free(root);
    const config_path = try std.fmt.allocPrint(gpa, "{s}/z3store.toml", .{root});
    defer gpa.free(config_path);
    const cfg: StoreConfig = .{
        .codestore_root = root,
        .gitstore_root = root,
        .toolstore_root = root,
        .cachestore_root = root,
        .config_path = config_path,
        .used_bootstrap_config = false,
        .used_legacy_root = false,
        .owned_strings = .empty,
    };

    try std.testing.expect(try ensureInitialized(gpa, std.testing.io, cfg));
    try std.testing.expect(!try ensureInitialized(gpa, std.testing.io, cfg));
    const contents = try tmp.dir.readFileAlloc(std.testing.io, "code/z3store.toml", gpa, .unlimited);
    defer gpa.free(contents);
    try std.testing.expect(std.mem.startsWith(u8, contents, "version = 1"));
}
