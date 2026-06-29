//! gitstore configuration resolution.
//!
//! Precedence (per libgitstore v2 plan):
//!   gitstore.root          -> ghq.root          -> $GITSTORE_ROOT -> $GHQ_ROOT -> ~/ghq
//!   gitstore.user          -> ghq.user          -> gh-user        -> $USER
//!   gitstore.defaultHost   -> ghq.defaultHost   -> "github.com"
//!   gitstore.completeUser  -> ghq.completeUser  -> "true"
//!   gitstore.adoptOnClone  -> (default "true"; no ghq fallback)
//!   gitstore.jjColocate    -> (default "true"; no ghq fallback)
//!
//! `used_legacy_ghq_keys` is set to true when any `gitstore.*` lookup was
//! unset AND the `ghq.*` fallback produced a real value — a signal for
//! callers to emit a deprecation hint on stderr.

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
    used_legacy_ghq_keys: bool,
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

fn gitConfigReturnedMissing(result: exec.ExecResult) bool {
    return result.term == .exited and result.term.exited == 1;
}

fn gitConfigReturnedMissingGlobal(result: exec.ExecResult) bool {
    if (!(result.term == .exited and result.term.exited == 128)) return false;
    return std.mem.indexOf(u8, result.stderr, "$HOME not set") != null;
}

/// Returns a trimmed, heap-allocated copy of the stdout of
/// `git config --get <key>` if the key is set. Returns `null` if the key is
/// absent (non-zero exit) or if its value is empty after trimming.
///
/// Caller owns returned memory.
fn gitConfigGet(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    key: []const u8,
    config_file: ?[]const u8,
) LoadError!?[]u8 {
    const argv: []const []const u8 = if (config_file) |path|
        &.{ "git", "config", "--file", path, "--get", key }
    else
        &.{ "git", "config", "--global", "--get", key };
    var result = try exec.execWithEnv(gpa, io, argv, null, env);
    defer gpa.free(result.stderr);
    if (!result.succeeded()) {
        gpa.free(result.stdout);
        if (!gitConfigReturnedMissing(result) and
            !(config_file == null and gitConfigReturnedMissingGlobal(result)))
        {
            return error.ProcessFailed;
        }
        return null;
    }
    const trimmed = exec.trimTrailingNewline(result.stdout);
    if (trimmed.len == 0) {
        gpa.free(result.stdout);
        return null;
    }
    if (trimmed.len == result.stdout.len) return result.stdout;
    const owned = gpa.dupe(u8, trimmed) catch |err| {
        gpa.free(result.stdout);
        return err;
    };
    gpa.free(result.stdout);
    return owned;
}

fn gitConfigGetUrlmatch(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    key: []const u8,
    url: []const u8,
    config_file: ?[]const u8,
) LoadError!?[]u8 {
    const argv: []const []const u8 = if (config_file) |path|
        &.{ "git", "config", "--file", path, "--get-urlmatch", key, url }
    else
        &.{ "git", "config", "--global", "--get-urlmatch", key, url };
    var result = try exec.execWithEnv(gpa, io, argv, null, env);
    defer gpa.free(result.stderr);
    if (!result.succeeded()) {
        gpa.free(result.stdout);
        if (!gitConfigReturnedMissing(result) and
            !(config_file == null and gitConfigReturnedMissingGlobal(result)))
        {
            return error.ProcessFailed;
        }
        return null;
    }
    const trimmed = exec.trimTrailingNewline(result.stdout);
    if (trimmed.len == 0) {
        gpa.free(result.stdout);
        return null;
    }
    if (trimmed.len == result.stdout.len) return result.stdout;
    const owned = gpa.dupe(u8, trimmed) catch |err| {
        gpa.free(result.stdout);
        return err;
    };
    gpa.free(result.stdout);
    return owned;
}

fn defaultRoot(gpa: Allocator, env: *std.process.Environ.Map) LoadError![]u8 {
    if (env.get("HOME")) |home| {
        if (home.len != 0) return std.fmt.allocPrint(gpa, "{s}/ghq", .{home});
    }
    return error.ProcessFailed;
}

fn gitConfigGlobalPath(env: *std.process.Environ.Map) ?[]const u8 {
    if (env.get("GIT_CONFIG_GLOBAL")) |path| {
        const trimmed = std.mem.trim(u8, path, " \t\r\n");
        if (trimmed.len != 0) return trimmed;
    }
    return null;
}

fn envHasValue(env: *std.process.Environ.Map, key: []const u8) bool {
    const value = env.get(key) orelse return false;
    return std.mem.trim(u8, value, " \t\r\n").len != 0;
}

fn hasGlobalGitConfigSource(env: *std.process.Environ.Map) bool {
    return gitConfigGlobalPath(env) != null or
        envHasValue(env, "HOME") or
        envHasValue(env, "XDG_CONFIG_HOME");
}

fn gitConfigGetEnv(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    key: []const u8,
) LoadError!?[]u8 {
    const config_file = gitConfigGlobalPath(env);
    if (config_file == null and !hasGlobalGitConfigSource(env)) return null;
    return gitConfigGet(gpa, io, env, key, config_file);
}

const OwnedResolution = struct {
    value: []u8,
    source: Source,
};

fn loadResolvedRoot(gpa: Allocator, io: Io, env: *std.process.Environ.Map) LoadError!OwnedResolution {
    const gitstore_root_raw = try gitConfigGetEnv(gpa, io, env, "gitstore.root");
    defer if (gitstore_root_raw) |v| gpa.free(v);
    const ghq_root_raw = try gitConfigGetEnv(gpa, io, env, "ghq.root");
    defer if (ghq_root_raw) |v| gpa.free(v);
    const env_gitstore_root = env.get("GITSTORE_ROOT");
    const env_ghq_root = env.get("GHQ_ROOT");

    const root_res = resolveRootChain(
        gitstore_root_raw,
        ghq_root_raw,
        env_gitstore_root,
        env_ghq_root,
        "",
    );
    if (root_res.source == .default) {
        const fallback_root = try defaultRoot(gpa, env);
        return .{ .value = fallback_root, .source = root_res.source };
    }

    const root = try gpa.dupe(u8, root_res.value);
    return .{ .value = root, .source = root_res.source };
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
    const owned = try gpa.dupe(u8, trimmed);
    gpa.free(result.stdout);
    return owned;
}

/// Duplicate `s` into `gpa`, register it in `list`, and return it.
fn ownStatic(gpa: Allocator, list: *std.ArrayList([]const u8), s: []const u8) LoadError![]const u8 {
    const dup = try gpa.dupe(u8, s);
    list.append(gpa, dup) catch |err| {
        gpa.free(dup);
        return err;
    };
    return dup;
}

/// Load configuration by reading `git config` values, environment variables,
/// and baked-in defaults in precedence order.
pub fn load(gpa: Allocator, io: Io, env: *std.process.Environ.Map) anyerror!Config {
    var owned_strings: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (owned_strings.items) |s| gpa.free(s);
        owned_strings.deinit(gpa);
    }

    var used_legacy = false;

    // --- root ---
    const root_res = try loadResolvedRoot(gpa, io, env);
    owned_strings.append(gpa, root_res.value) catch |err| {
        gpa.free(root_res.value);
        return err;
    };
    const root: []const u8 = root_res.value;
    if (root_res.source == .ghq) used_legacy = true;

    // --- user ---
    const gitstore_user_raw = try gitConfigGetEnv(gpa, io, env, "gitstore.user");
    defer if (gitstore_user_raw) |v| gpa.free(v);
    const ghq_user_raw = try gitConfigGetEnv(gpa, io, env, "ghq.user");
    defer if (ghq_user_raw) |v| gpa.free(v);
    const gh_user_raw = try ghUser(gpa, io);
    defer if (gh_user_raw) |v| gpa.free(v);
    const env_user = env.get("USER");

    var user: ?[]const u8 = null;
    if (gitstore_user_raw) |v| {
        user = try ownStatic(gpa, &owned_strings, v);
    } else if (ghq_user_raw) |v| {
        user = try ownStatic(gpa, &owned_strings, v);
        used_legacy = true;
    } else if (gh_user_raw) |v| {
        user = try ownStatic(gpa, &owned_strings, v);
    } else if (env_user) |v| {
        if (v.len != 0) user = try ownStatic(gpa, &owned_strings, v);
    }

    // --- defaultHost ---
    const gitstore_host_raw = try gitConfigGetEnv(gpa, io, env, "gitstore.defaultHost");
    defer if (gitstore_host_raw) |v| gpa.free(v);
    const ghq_host_raw = try gitConfigGetEnv(gpa, io, env, "ghq.defaultHost");
    defer if (ghq_host_raw) |v| gpa.free(v);
    const host_res = resolvePrecedence(
        gitstore_host_raw,
        ghq_host_raw,
        null,
        "github.com",
    );
    const default_host: []const u8 = try ownStatic(gpa, &owned_strings, host_res.value);
    if (host_res.source == .ghq) used_legacy = true;

    // --- completeUser ---
    const gitstore_cu_raw = try gitConfigGetEnv(gpa, io, env, "gitstore.completeUser");
    defer if (gitstore_cu_raw) |v| gpa.free(v);
    const ghq_cu_raw = try gitConfigGetEnv(gpa, io, env, "ghq.completeUser");
    defer if (ghq_cu_raw) |v| gpa.free(v);
    const cu_res = resolvePrecedence(gitstore_cu_raw, ghq_cu_raw, null, "true");
    const complete_user = parseBool(cu_res.value);
    if (cu_res.source == .ghq) used_legacy = true;

    // --- adoptOnClone (no ghq fallback) ---
    const gitstore_aoc_raw = try gitConfigGetEnv(gpa, io, env, "gitstore.adoptOnClone");
    defer if (gitstore_aoc_raw) |v| gpa.free(v);
    const aoc_res = resolvePrecedence(gitstore_aoc_raw, null, null, "true");
    const adopt_on_clone = parseBool(aoc_res.value);

    // --- jjColocate (no ghq fallback) ---
    const gitstore_jj_raw = try gitConfigGetEnv(gpa, io, env, "gitstore.jjColocate");
    defer if (gitstore_jj_raw) |v| gpa.free(v);
    const jj_res = resolvePrecedence(gitstore_jj_raw, null, null, "true");
    const jj_colocate = parseBool(jj_res.value);

    return .{
        .root = root,
        .user = user,
        .default_host = default_host,
        .complete_user = complete_user,
        .adopt_on_clone = adopt_on_clone,
        .jj_colocate = jj_colocate,
        .used_legacy_ghq_keys = used_legacy,
        .owned_strings = owned_strings,
    };
}

/// Resolve only the ghq/gitstore root. This intentionally skips user/default
/// host resolution because those paths can shell out to `gh api user`.
/// Caller owns the returned memory.
pub fn loadRoot(gpa: Allocator, io: Io, env: *std.process.Environ.Map) anyerror![]u8 {
    const root_res = try loadResolvedRoot(gpa, io, env);
    return root_res.value;
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
pub fn resolveRootForUrl(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    url: []const u8,
    base: Config,
) anyerror![]u8 {
    return resolveRootForUrlWithConfigFile(gpa, io, env, url, base, null);
}

/// Testable variant of `resolveRootForUrl` that reads a specific git config
/// file instead of the ambient global config.
pub fn resolveRootForUrlWithConfigFile(
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    url: []const u8,
    base: Config,
    config_file: ?[]const u8,
) anyerror![]u8 {
    // git config --get-urlmatch <key> <url>
    if (try gitConfigGetUrlmatch(gpa, io, env, "gitstore.root", url, config_file)) |root| return root;
    if (try gitConfigGetUrlmatch(gpa, io, env, "ghq.root", url, config_file)) |root| return root;

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

test "config: loadRoot uses env root without global git config source" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env_map = std.process.Environ.Map.init(gpa);
    defer env_map.deinit();
    try env_map.put("GITSTORE_ROOT", "/from/env/gitstore");

    const root = try loadRoot(gpa, io, &env_map);
    defer gpa.free(root);
    try testing.expectEqualStrings("/from/env/gitstore", root);
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
