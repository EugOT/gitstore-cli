//! z3store configuration resolution.
//!
//! `z3store.*` git-config keys (and `$Z3STORE_ROOT`) are the primary source.
//! `gitstore.*` / `ghq.*` keys and `$GITSTORE_ROOT` / `$GHQ_ROOT` remain as
//! legacy fallbacks so existing setups keep working.
//!
//! Precedence:
//!   root: z3store.root -> gitstore.root -> ghq.root
//!         -> $Z3STORE_ROOT -> $GITSTORE_ROOT -> $GHQ_ROOT -> ~/ghq
//!   user: z3store.user -> gitstore.user -> ghq.user -> $USER -> gh-user
//!   defaultHost:  z3store.defaultHost  -> gitstore.defaultHost  -> ghq.defaultHost  -> "github.com"
//!   completeUser: z3store.completeUser -> gitstore.completeUser -> ghq.completeUser -> "true"
//!   adoptOnClone: z3store.adoptOnClone -> gitstore.adoptOnClone -> "true" (no ghq fallback)
//!   jjColocate:   z3store.jjColocate   -> gitstore.jjColocate   -> "true" (no ghq fallback)
//!
//! `used_legacy` is set to true whenever a value was sourced from a legacy
//! `gitstore.*` / `ghq.*` key or the `$GITSTORE_ROOT` / `$GHQ_ROOT` env vars —
//! a signal for callers to emit a one-line deprecation hint on stderr.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const exec = @import("exec.zig");

pub const Source = enum { gitstore, ghq, env, default };

pub const Config = struct {
    root: []const u8,
    user: ?[]const u8,
    default_host: []const u8,
    complete_user: bool,
    adopt_on_clone: bool,
    jj_colocate: bool,
    used_legacy: bool,
    /// All heap allocations produced while resolving configuration. `deinit`
    /// frees each slice here.
    owned_strings: std.ArrayList([]const u8),

    pub fn deinit(self: *Config, gpa: Allocator) void {
        for (self.owned_strings.items) |s| gpa.free(s);
        self.owned_strings.deinit(gpa);
        self.* = undefined;
    }
};

pub const LoadError = error{
    OutOfMemory,
    ProcessFailed,
} || exec.ExecError;

pub const Resolution = struct {
    value: []const u8,
    source: Source,
};

/// Pure precedence resolver. Empty strings are treated as "unset" — matches
/// how `git config --get` returns nothing versus an empty value.
///
/// This is one of the five Io.failing-testable pure functions in the plan.
pub fn resolvePrecedence(
    gitstore_val: ?[]const u8,
    ghq_val: ?[]const u8,
    env_val: ?[]const u8,
    default_val: []const u8,
) Resolution {
    if (gitstore_val) |v| if (v.len != 0) return .{ .value = v, .source = .gitstore };
    if (ghq_val) |v| if (v.len != 0) return .{ .value = v, .source = .ghq };
    if (env_val) |v| if (v.len != 0) return .{ .value = v, .source = .env };
    return .{ .value = default_val, .source = .default };
}

/// `true` if a "true"-ish string. Accepts "true", "1", "yes", "on"
/// (case-insensitive). Any other non-empty string is treated as false.
fn parseBool(s: []const u8) bool {
    if (s.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(s, "true")) return true;
    if (std.ascii.eqlIgnoreCase(s, "1")) return true;
    if (std.ascii.eqlIgnoreCase(s, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(s, "on")) return true;
    return false;
}

/// Capture git config once and resolve individual keys from the snapshot.
/// Missing/unreadable config behaves like repeated `git config --get` misses:
/// it is not fatal, and every key falls through to later precedence tiers.
fn gitConfigSnapshot(
    gpa: Allocator,
    io: Io,
    config_file: ?[]const u8,
) LoadError!?[]u8 {
    const file_argv = if (config_file) |path| [_][]const u8{ "git", "config", "--file", path, "--list" } else undefined;
    const global_argv = [_][]const u8{ "git", "config", "--global", "--list" };
    const argv: []const []const u8 = if (config_file != null) file_argv[0..] else global_argv[0..];
    var result = try exec.exec(gpa, io, argv, null);
    defer gpa.free(result.stderr);
    if (!result.succeeded()) {
        gpa.free(result.stdout);
        return null;
    }
    return result.stdout;
}

fn snapshotValue(snapshot: ?[]const u8, key: []const u8) ?[]const u8 {
    const content = snapshot orelse return null;
    var found: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..eq], key)) found = line[eq + 1 ..];
    }
    return found;
}

/// Run `gh api user -q .login` to derive the GitHub username. Returns null on
/// any failure (gh not installed, not logged in, network down, etc.).
fn ghUser(gpa: Allocator, io: Io) LoadError!?[]u8 {
    var result = exec.exec(gpa, io, &.{ "gh", "api", "user", "-q", ".login" }, null) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer gpa.free(result.stderr);
    if (!result.succeeded()) {
        gpa.free(result.stdout);
        return null;
    }
    const trimmed = exec.trimTrailingNewline(result.stdout);
    if (trimmed.len == 0) {
        gpa.free(result.stdout);
        return null;
    }
    if (trimmed.len == result.stdout.len) return result.stdout;
    errdefer gpa.free(result.stdout);
    const owned = try gpa.dupe(u8, trimmed);
    gpa.free(result.stdout);
    return owned;
}

/// Duplicate `s` into `gpa`, register it in `list`, and return it.
fn ownStatic(gpa: Allocator, list: *std.ArrayList([]const u8), s: []const u8) LoadError![]const u8 {
    const dup = try gpa.dupe(u8, s);
    try list.append(gpa, dup);
    return dup;
}

/// Load configuration by reading `git config` values, environment variables,
/// and baked-in defaults in precedence order.
// ziglint-ignore: Z015 - LoadError is a public composed error set; ziglint
// 0.5.2 false-positives on same-file public error-set references.
pub fn load(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
) LoadError!Config {
    var owned_strings: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (owned_strings.items) |s| gpa.free(s);
        owned_strings.deinit(gpa);
    }

    var used_legacy = false;

    const config_file = env.get("GIT_CONFIG_GLOBAL");
    const config_snapshot = try gitConfigSnapshot(gpa, io, config_file);
    defer if (config_snapshot) |s| gpa.free(s);

    // --- root ---
    // Primary z3store.* / $Z3STORE_ROOT, then legacy gitstore.* / ghq.* and
    // $GITSTORE_ROOT / $GHQ_ROOT.
    const z3_root_raw = snapshotValue(config_snapshot, "z3store.root");
    const gitstore_root_raw = snapshotValue(config_snapshot, "gitstore.root");
    const ghq_root_raw = snapshotValue(config_snapshot, "ghq.root");
    const env_z3_root = env.get("Z3STORE_ROOT");
    const env_gitstore_root = env.get("GITSTORE_ROOT");
    const env_ghq_root = env.get("GHQ_ROOT");
    const home_opt = env.get("HOME");

    const default_root = if (home_opt) |h|
        try std.fmt.allocPrint(gpa, "{s}/ghq", .{h})
    else
        try gpa.dupe(u8, "ghq");
    try owned_strings.append(gpa, default_root);

    const root_res = resolveStoreRootChain(
        z3_root_raw,
        gitstore_root_raw,
        ghq_root_raw,
        env_z3_root,
        env_gitstore_root,
        env_ghq_root,
        default_root,
    );
    const root: []const u8 = if (root_res.is_default)
        default_root
    else
        try ownStatic(gpa, &owned_strings, root_res.value);
    if (root_res.legacy) used_legacy = true;

    // --- user ---
    const z3_user_raw = snapshotValue(config_snapshot, "z3store.user");
    const gitstore_user_raw = snapshotValue(config_snapshot, "gitstore.user");
    const ghq_user_raw = snapshotValue(config_snapshot, "ghq.user");
    const env_user = env.get("USER");

    var user: ?[]const u8 = null;
    if (nonEmpty(z3_user_raw)) |v| {
        user = try ownStatic(gpa, &owned_strings, v);
    } else if (nonEmpty(gitstore_user_raw)) |v| {
        user = try ownStatic(gpa, &owned_strings, v);
        used_legacy = true;
    } else if (nonEmpty(ghq_user_raw)) |v| {
        user = try ownStatic(gpa, &owned_strings, v);
        used_legacy = true;
    } else if (nonEmpty(env_user)) |v| {
        user = try ownStatic(gpa, &owned_strings, v);
    } else {
        const gh_user_raw = try ghUser(gpa, io);
        defer if (gh_user_raw) |v| gpa.free(v);
        if (nonEmpty(gh_user_raw)) |v| {
            user = try ownStatic(gpa, &owned_strings, v);
        }
    }

    // --- defaultHost ---
    const default_host = try resolveCfgTriple(
        gpa,
        &owned_strings,
        config_snapshot,
        "z3store.defaultHost",
        "gitstore.defaultHost",
        "ghq.defaultHost",
        "github.com",
        &used_legacy,
    );

    // --- completeUser ---
    const cu_val = try resolveCfgTriple(
        gpa,
        &owned_strings,
        config_snapshot,
        "z3store.completeUser",
        "gitstore.completeUser",
        "ghq.completeUser",
        "true",
        &used_legacy,
    );
    const complete_user = parseBool(cu_val);

    // --- adoptOnClone (no ghq fallback) ---
    const aoc_val = try resolveCfgPair(
        gpa,
        &owned_strings,
        config_snapshot,
        "z3store.adoptOnClone",
        "gitstore.adoptOnClone",
        "true",
        &used_legacy,
    );
    const adopt_on_clone = parseBool(aoc_val);

    // --- jjColocate (no ghq fallback) ---
    const jj_val = try resolveCfgPair(
        gpa,
        &owned_strings,
        config_snapshot,
        "z3store.jjColocate",
        "gitstore.jjColocate",
        "true",
        &used_legacy,
    );
    const jj_colocate = parseBool(jj_val);

    return .{
        .root = root,
        .user = user,
        .default_host = default_host,
        .complete_user = complete_user,
        .adopt_on_clone = adopt_on_clone,
        .jj_colocate = jj_colocate,
        .used_legacy = used_legacy,
        .owned_strings = owned_strings,
    };
}

/// Resolve a `z3store.<key>` (primary) / `gitstore.<key>` / `ghq.<key>`
/// (legacy) git-config triple, falling back to `default_val`. Any legacy hit
/// flips `used_legacy`. The returned slice is registered in `owned_strings`.
fn resolveCfgTriple(
    gpa: Allocator,
    owned_strings: *std.ArrayList([]const u8),
    config_snapshot: ?[]const u8,
    z3_key: []const u8,
    gitstore_key: []const u8,
    ghq_key: []const u8,
    default_val: []const u8,
    used_legacy: *bool,
) LoadError![]const u8 {
    const z3_raw = snapshotValue(config_snapshot, z3_key);
    const gitstore_raw = snapshotValue(config_snapshot, gitstore_key);
    const ghq_raw = snapshotValue(config_snapshot, ghq_key);

    if (nonEmpty(z3_raw)) |v| return ownStatic(gpa, owned_strings, v);
    if (nonEmpty(gitstore_raw)) |v| {
        used_legacy.* = true;
        return ownStatic(gpa, owned_strings, v);
    }
    if (nonEmpty(ghq_raw)) |v| {
        used_legacy.* = true;
        return ownStatic(gpa, owned_strings, v);
    }
    return ownStatic(gpa, owned_strings, default_val);
}

/// Like `resolveCfgTriple` but with no `ghq.*` fallback tier.
fn resolveCfgPair(
    gpa: Allocator,
    owned_strings: *std.ArrayList([]const u8),
    config_snapshot: ?[]const u8,
    z3_key: []const u8,
    gitstore_key: []const u8,
    default_val: []const u8,
    used_legacy: *bool,
) LoadError![]const u8 {
    const z3_raw = snapshotValue(config_snapshot, z3_key);
    const gitstore_raw = snapshotValue(config_snapshot, gitstore_key);

    if (nonEmpty(z3_raw)) |v| return ownStatic(gpa, owned_strings, v);
    if (nonEmpty(gitstore_raw)) |v| {
        used_legacy.* = true;
        return ownStatic(gpa, owned_strings, v);
    }
    return ownStatic(gpa, owned_strings, default_val);
}

/// Treat null and empty-string as "unset"; return the value otherwise.
fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    if (v) |s| if (s.len != 0) return s;
    return null;
}

pub const RootResolution = struct {
    value: []const u8,
    /// A legacy source (gitstore.*/ghq.* config or $GITSTORE_ROOT/$GHQ_ROOT)
    /// produced the value.
    legacy: bool,
    /// No source matched; `value` is the baked-in default.
    is_default: bool,
};

/// Pure six-source store-root resolver:
///   z3store.root -> gitstore.root -> ghq.root
///   -> $Z3STORE_ROOT -> $GITSTORE_ROOT -> $GHQ_ROOT -> default.
/// Empty strings are treated as unset. The three legacy tiers set `legacy`.
pub fn resolveStoreRootChain(
    z3_cfg: ?[]const u8,
    gitstore_cfg: ?[]const u8,
    ghq_cfg: ?[]const u8,
    env_z3: ?[]const u8,
    env_gitstore: ?[]const u8,
    env_ghq: ?[]const u8,
    default_val: []const u8,
) RootResolution {
    if (nonEmpty(z3_cfg)) |v| return .{ .value = v, .legacy = false, .is_default = false };
    if (nonEmpty(gitstore_cfg)) |v| return .{ .value = v, .legacy = true, .is_default = false };
    if (nonEmpty(ghq_cfg)) |v| return .{ .value = v, .legacy = true, .is_default = false };
    if (nonEmpty(env_z3)) |v| return .{ .value = v, .legacy = false, .is_default = false };
    if (nonEmpty(env_gitstore)) |v| return .{ .value = v, .legacy = true, .is_default = false };
    if (nonEmpty(env_ghq)) |v| return .{ .value = v, .legacy = true, .is_default = false };
    return .{ .value = default_val, .legacy = false, .is_default = true };
}

/// Four-way resolver used only for `root` (which has two env fallbacks).
/// Pure; exposed here so tests can exercise it directly.
pub fn resolveRootChain(
    gitstore_val: ?[]const u8,
    ghq_val: ?[]const u8,
    env_gitstore_root: ?[]const u8,
    env_ghq_root: ?[]const u8,
    default_val: []const u8,
) Resolution {
    if (gitstore_val) |v| if (v.len != 0) return .{ .value = v, .source = .gitstore };
    if (ghq_val) |v| if (v.len != 0) return .{ .value = v, .source = .ghq };
    if (env_gitstore_root) |v| if (v.len != 0) return .{ .value = v, .source = .env };
    if (env_ghq_root) |v| if (v.len != 0) return .{ .value = v, .source = .env };
    return .{ .value = default_val, .source = .default };
}

/// Resolve the root directory for a specific URL using
/// `git config --get-urlmatch`. Tries `gitstore.root <url>` first, then
/// `ghq.root <url>`, then falls back to `base.root`. The returned slice is
/// always a fresh heap allocation owned by the caller.
// ziglint-ignore: Z015 - LoadError is a public composed error set; ziglint
// 0.5.2 false-positives on same-file public error-set references.
pub fn resolveRootForUrl(
    gpa: Allocator,
    io: Io,
    url: []const u8,
    base: Config,
) LoadError![]u8 {
    return resolveRootForUrlWithConfigFile(gpa, io, url, base, null);
}

/// Testable variant of `resolveRootForUrl` that reads a specific git config
/// file instead of the ambient global config.
// ziglint-ignore: Z015 - LoadError is a public composed error set; ziglint
// 0.5.2 false-positives on same-file public error-set references.
pub fn resolveRootForUrlWithConfigFile(
    gpa: Allocator,
    io: Io,
    url: []const u8,
    base: Config,
    config_file: ?[]const u8,
) LoadError![]u8 {
    // git config --get-urlmatch <key> <url> — z3store.root (primary) first.
    {
        const file_argv = if (config_file) |path|
            [_][]const u8{ "git", "config", "--file", path, "--get-urlmatch", "z3store.root", url }
        else
            undefined;
        const global_argv = [_][]const u8{ "git", "config", "--global", "--get-urlmatch", "z3store.root", url };
        const argv: []const []const u8 = if (config_file != null) file_argv[0..] else global_argv[0..];
        var result = try exec.exec(
            gpa,
            io,
            argv,
            null,
        );
        defer gpa.free(result.stderr);
        if (result.succeeded()) {
            const trimmed = exec.trimTrailingNewline(result.stdout);
            if (trimmed.len != 0) {
                if (trimmed.len == result.stdout.len) return result.stdout;
                errdefer gpa.free(result.stdout);
                const owned = try gpa.dupe(u8, trimmed);
                gpa.free(result.stdout);
                return owned;
            }
        }
        gpa.free(result.stdout);
    }

    // Legacy gitstore.root urlmatch.
    {
        const file_argv = if (config_file) |path|
            [_][]const u8{ "git", "config", "--file", path, "--get-urlmatch", "gitstore.root", url }
        else
            undefined;
        const global_argv = [_][]const u8{ "git", "config", "--global", "--get-urlmatch", "gitstore.root", url };
        const argv: []const []const u8 = if (config_file != null) file_argv[0..] else global_argv[0..];
        var result = try exec.exec(
            gpa,
            io,
            argv,
            null,
        );
        defer gpa.free(result.stderr);
        if (result.succeeded()) {
            const trimmed = exec.trimTrailingNewline(result.stdout);
            if (trimmed.len != 0) {
                if (trimmed.len == result.stdout.len) return result.stdout;
                errdefer gpa.free(result.stdout);
                const owned = try gpa.dupe(u8, trimmed);
                gpa.free(result.stdout);
                return owned;
            }
        }
        gpa.free(result.stdout);
    }

    {
        const file_argv = if (config_file) |path|
            [_][]const u8{ "git", "config", "--file", path, "--get-urlmatch", "ghq.root", url }
        else
            undefined;
        const global_argv = [_][]const u8{ "git", "config", "--global", "--get-urlmatch", "ghq.root", url };
        const argv: []const []const u8 = if (config_file != null) file_argv[0..] else global_argv[0..];
        var result = try exec.exec(
            gpa,
            io,
            argv,
            null,
        );
        defer gpa.free(result.stderr);
        if (result.succeeded()) {
            const trimmed = exec.trimTrailingNewline(result.stdout);
            if (trimmed.len != 0) {
                if (trimmed.len == result.stdout.len) return result.stdout;
                errdefer gpa.free(result.stdout);
                const owned = try gpa.dupe(u8, trimmed);
                gpa.free(result.stdout);
                return owned;
            }
        }
        gpa.free(result.stdout);
    }

    return gpa.dupe(u8, base.root);
}

// =========================================================
// Tests — all prefixed "config:" for filtering via test-filter.
// Pure tests don't touch Io; the load/resolveRootForUrl tests
// use real `git config` via std.testing.tmpDir + exec.exec.
// =========================================================

const testing = std.testing;

test "config: resolvePrecedence picks gitstore first" {
    const r = resolvePrecedence("gitstore_val", "ghq_val", "env_val", "default_val");
    try testing.expectEqualStrings("gitstore_val", r.value);
    try testing.expectEqual(Source.gitstore, r.source);
}

test "config: resolvePrecedence falls to ghq when gitstore is null" {
    const r = resolvePrecedence(null, "ghq_val", "env_val", "default_val");
    try testing.expectEqualStrings("ghq_val", r.value);
    try testing.expectEqual(Source.ghq, r.source);
}

test "config: resolvePrecedence falls to ghq when gitstore is empty string" {
    const r = resolvePrecedence("", "ghq_val", "env_val", "default_val");
    try testing.expectEqualStrings("ghq_val", r.value);
    try testing.expectEqual(Source.ghq, r.source);
}

test "config: resolvePrecedence falls to env when gitstore+ghq both null" {
    const r = resolvePrecedence(null, null, "env_val", "default_val");
    try testing.expectEqualStrings("env_val", r.value);
    try testing.expectEqual(Source.env, r.source);
}

test "config: resolvePrecedence falls to env when gitstore+ghq empty" {
    const r = resolvePrecedence("", "", "env_val", "default_val");
    try testing.expectEqualStrings("env_val", r.value);
    try testing.expectEqual(Source.env, r.source);
}

test "config: resolvePrecedence falls to default when all earlier are unset" {
    const r = resolvePrecedence(null, null, null, "default_val");
    try testing.expectEqualStrings("default_val", r.value);
    try testing.expectEqual(Source.default, r.source);
}

test "config: resolvePrecedence treats empty env as unset" {
    const r = resolvePrecedence(null, null, "", "default_val");
    try testing.expectEqualStrings("default_val", r.value);
    try testing.expectEqual(Source.default, r.source);
}

test "config: resolvePrecedence — gitstore-only is kept over empty rest" {
    const r = resolvePrecedence("only_gs", "", "", "default_val");
    try testing.expectEqualStrings("only_gs", r.value);
    try testing.expectEqual(Source.gitstore, r.source);
}

test "config: resolvePrecedence with ghq-only falls back there" {
    const r = resolvePrecedence(null, "only_ghq", null, "default_val");
    try testing.expectEqualStrings("only_ghq", r.value);
    try testing.expectEqual(Source.ghq, r.source);
}

test "config: resolvePrecedence treats all null as default" {
    const r = resolvePrecedence(null, null, null, "fallback");
    try testing.expectEqualStrings("fallback", r.value);
    try testing.expectEqual(Source.default, r.source);
}

test "config: resolveStoreRootChain z3 config beats gitstore beats ghq" {
    const r = resolveStoreRootChain("/z3", "/gs", "/ghq", "/ez3", "/egs", "/eghq", "/def");
    try testing.expectEqualStrings("/z3", r.value);
    try testing.expect(!r.legacy);
    try testing.expect(!r.is_default);
}

test "config: resolveStoreRootChain gitstore config is legacy" {
    const r = resolveStoreRootChain(null, "/gs", "/ghq", "/ez3", "/egs", "/eghq", "/def");
    try testing.expectEqualStrings("/gs", r.value);
    try testing.expect(r.legacy);
}

test "config: resolveStoreRootChain ghq config is legacy" {
    const r = resolveStoreRootChain(null, null, "/ghq", "/ez3", "/egs", "/eghq", "/def");
    try testing.expectEqualStrings("/ghq", r.value);
    try testing.expect(r.legacy);
}

test "config: resolveStoreRootChain $Z3STORE_ROOT beats $GITSTORE_ROOT beats $GHQ_ROOT" {
    const r = resolveStoreRootChain(null, null, null, "/ez3", "/egs", "/eghq", "/def");
    try testing.expectEqualStrings("/ez3", r.value);
    try testing.expect(!r.legacy);
    const r2 = resolveStoreRootChain(null, null, null, null, "/egs", "/eghq", "/def");
    try testing.expectEqualStrings("/egs", r2.value);
    try testing.expect(r2.legacy);
    const r3 = resolveStoreRootChain(null, null, null, null, null, "/eghq", "/def");
    try testing.expectEqualStrings("/eghq", r3.value);
    try testing.expect(r3.legacy);
}

test "config: resolveStoreRootChain empty strings are unset, default when all empty" {
    const r = resolveStoreRootChain("", "", "", "", "", "", "/def");
    try testing.expectEqualStrings("/def", r.value);
    try testing.expect(!r.legacy);
    try testing.expect(r.is_default);
}

test "config: parseBool accepts true/1/yes/on case-insensitively" {
    try testing.expect(parseBool("true"));
    try testing.expect(parseBool("TRUE"));
    try testing.expect(parseBool("True"));
    try testing.expect(parseBool("1"));
    try testing.expect(parseBool("yes"));
    try testing.expect(parseBool("YES"));
    try testing.expect(parseBool("on"));
    try testing.expect(!parseBool(""));
    try testing.expect(!parseBool("false"));
    try testing.expect(!parseBool("0"));
    try testing.expect(!parseBool("off"));
    try testing.expect(!parseBool("maybe"));
}

fn fuzzOnePrecedence(_: void, smith: *testing.Smith) anyerror!void {
    // Generate random-length slices for each source; function must be total.
    var buf: [256]u8 = undefined;
    const have_g = smith.value(bool);
    const have_h = smith.value(bool);
    const have_e = smith.value(bool);
    const g_len = if (have_g) smith.valueRangeAtMost(u8, 0, 48) else 0;
    const h_len = if (have_h) smith.valueRangeAtMost(u8, 0, 48) else 0;
    const e_len = if (have_e) smith.valueRangeAtMost(u8, 0, 48) else 0;
    const d_len = smith.valueRangeAtMost(u8, 0, 48);

    var off: usize = 0;
    smith.bytes(buf[off .. off + g_len]);
    const g_slice = buf[off .. off + g_len];
    off += g_len;
    smith.bytes(buf[off .. off + h_len]);
    const h_slice = buf[off .. off + h_len];
    off += h_len;
    smith.bytes(buf[off .. off + e_len]);
    const e_slice = buf[off .. off + e_len];
    off += e_len;
    smith.bytes(buf[off .. off + d_len]);
    const d_slice = buf[off .. off + d_len];

    const gs: ?[]const u8 = if (have_g) g_slice else null;
    const gh: ?[]const u8 = if (have_h) h_slice else null;
    const ev: ?[]const u8 = if (have_e) e_slice else null;
    const r = resolvePrecedence(gs, gh, ev, d_slice);
    // Totality: source must match its input's presence.
    switch (r.source) {
        .gitstore => try testing.expect(have_g and g_slice.len != 0),
        .ghq => try testing.expect(have_h and h_slice.len != 0),
        .env => try testing.expect(have_e and e_slice.len != 0),
        .default => {
            if (have_g) try testing.expect(g_slice.len == 0);
            if (have_h) try testing.expect(h_slice.len == 0);
            if (have_e) try testing.expect(e_slice.len == 0);
        },
    }
}

test "config: fuzz — resolvePrecedence is total (never panics)" {
    try testing.fuzz({}, fuzzOnePrecedence, .{});
}
