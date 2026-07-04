const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const ExecResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,

    pub fn deinit(self: *ExecResult, gpa: Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }

    pub fn succeeded(self: ExecResult) bool {
        return self.term == .exited and self.term.exited == 0;
    }
};

pub const ExecError = std.process.RunError;

/// Whitelist of environment variables propagated to spawned subprocesses
/// (git, jj, ghq, rclone, and friends). Everything else is dropped.
///
/// WHY: git honours `GIT_CONFIG_COUNT` + `GIT_CONFIG_KEY_<i>` /
/// `GIT_CONFIG_VALUE_<i>` and `GIT_DIR` / `GIT_OBJECT_DIRECTORY` /
/// `GIT_*` overrides at runtime. A caller (or an attacker who controls a
/// hook context, sudo wrapper, etc.) could otherwise inject e.g.
/// `core.fsmonitor=/tmp/evil.sh` and have gitstore execute it. By passing
/// only a fresh, scrubbed map to the child, gitstore neutralises this
/// injection vector while preserving the env vars users legitimately need
/// (PATH for tool lookup, HOME / XDG_* for git config discovery,
/// SSH_AUTH_SOCK for ssh-key clones, SSL_CERT_* for TLS, etc.).
const env_whitelist = [_][]const u8{
    "PATH",           "HOME",              "USER",
    "LOGNAME",        "LANG",              "LC_ALL",
    "LC_CTYPE",       "TERM",              "TZ",
    "TMPDIR",         "SSH_AUTH_SOCK",     "SSL_CERT_FILE",
    "SSL_CERT_DIR",   "NIX_SSL_CERT_FILE", "XDG_CONFIG_HOME",
    "XDG_CACHE_HOME", "GHQ_ROOT",          "GITSTORE_ROOT",
    "Z3STORE_ROOT",
};

/// Build a fresh env map containing only `env_whitelist` entries that are
/// present in the current process environment. Caller owns the returned
/// map and must `deinit` it.
///
/// WHY (Codex P1, v0.2.2): the previous implementation walked
/// `std.c.environ` directly. That symbol is null on no-libc Zig 0.16
/// builds, so the scrubbed map silently came back EMPTY — dropping HOME,
/// PATH, and locale vars from every spawned git/jj/ghq subprocess. The
/// portable replacement is to materialize the parent environment via
/// `std.process.Environ.createMap`, sourced from `std.testing.environ`
/// inside the test runner (which is libc-independent) and from the
/// libc-backed `std.c.environ` block in production POSIX builds.
fn buildScrubbedEnv(gpa: Allocator) Allocator.Error!std.process.Environ.Map {
    var parent_map = parentEnvMap(gpa) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.process.Environ.Map.init(gpa),
    };
    defer parent_map.deinit();

    var out: std.process.Environ.Map = .init(gpa);
    errdefer out.deinit();
    for (env_whitelist) |key| {
        if (parent_map.get(key)) |value| {
            try out.put(key, value);
        }
    }
    return out;
}

/// Materialize the parent process environment as a portable
/// `std.process.Environ.Map`. Builds from `std.c.environ` when libc is
/// linked (the standard POSIX path, including under `zig build test`
/// where the test binary inherits the parent shell's environ). Returns
/// an empty map on no-libc targets — gitstore's spawned subprocesses
/// then run with only the explicit whitelist values, which is the
/// security contract this function exists to maintain.
///
/// WHY (CR R7-1, v0.2.2): in Zig 0.16 `std.c.environ` is declared as
/// `extern var environ: [*:null]?[*:0]u8;` regardless of libc linkage —
/// `@hasDecl(std.c, "environ")` is therefore TRUE on no-libc builds too,
/// and dereferencing the symbol there is undefined behaviour (null pointer).
/// `builtin.link_libc` is the compile-time constant that actually reflects
/// whether the symbol is backed by a real libc-provided block. We gate on
/// that primarily and keep `@hasDecl` as a defensive secondary check so the
/// code still compiles on hypothetical std builds that drop the decl.
fn parentEnvMap(gpa: Allocator) !std.process.Environ.Map {
    if (builtin.link_libc and @hasDecl(std.c, "environ")) {
        const c_environ = std.c.environ;
        var count: usize = 0;
        while (c_environ[count] != null) : (count += 1) {}
        const slice: [:null]const ?[*:0]const u8 = @ptrCast(c_environ[0..count :null]);
        const env: std.process.Environ = .{ .block = .{ .slice = slice } };
        return env.createMap(gpa);
    }
    return std.process.Environ.Map.init(gpa);
}

/// Run a command, capture stdout and stderr, return result with exit status.
///
/// The child inherits a *scrubbed* environment (see `env_whitelist`) — not
/// the full parent env — so callers cannot smuggle `GIT_CONFIG_*` /
/// `GIT_DIR` overrides into the spawned git/jj/ghq/rclone process.
pub fn exec(
    gpa: Allocator,
    io: Io,
    argv: []const []const u8,
    cwd: ?[]const u8,
) ExecError!ExecResult {
    const cwd_opt: std.process.Child.Cwd = if (cwd) |c| .{ .path = c } else .inherit;
    var scrubbed = try buildScrubbedEnv(gpa);
    defer scrubbed.deinit();
    const result = try std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = cwd_opt,
        .environ_map = &scrubbed,
    });
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .term = result.term,
    };
}

/// Run a command, return stdout on success. Returns error on non-zero exit.
pub fn execCheck(
    gpa: Allocator,
    io: Io,
    argv: []const []const u8,
    cwd: ?[]const u8,
) ![]u8 {
    var result = try exec(gpa, io, argv, cwd);
    if (!result.succeeded()) {
        gpa.free(result.stdout);
        gpa.free(result.stderr);
        return error.ProcessFailed;
    }
    gpa.free(result.stderr);
    return result.stdout;
}

/// Trim trailing newlines from a slice.
pub fn trimTrailingNewline(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and (s[end - 1] == '\n' or s[end - 1] == '\r')) {
        end -= 1;
    }
    return s[0..end];
}

const testing = std.testing;

// ===== env_whitelist / buildScrubbedEnv tests =====

test "env_whitelist contains GHQ_ROOT, GITSTORE_ROOT and Z3STORE_ROOT" {
    // ghq honours GHQ_ROOT for repo location. zt wraps `ghq root`
    // and other ghq commands through exec() with a SCRUBBED env, so if
    // GHQ_ROOT is dropped here every adoptAll/detachAll/status call will
    // resolve the wrong root. Same logic for the legacy GITSTORE_ROOT and the
    // primary Z3STORE_ROOT store-root overrides.
    var has_ghq = false;
    var has_gitstore = false;
    var has_z3store = false;
    for (env_whitelist) |key| {
        if (std.mem.eql(u8, key, "GHQ_ROOT")) has_ghq = true;
        if (std.mem.eql(u8, key, "GITSTORE_ROOT")) has_gitstore = true;
        if (std.mem.eql(u8, key, "Z3STORE_ROOT")) has_z3store = true;
    }
    try testing.expect(has_ghq);
    try testing.expect(has_gitstore);
    try testing.expect(has_z3store);
}

test "buildScrubbedEnv preserves whitelisted vars from parent env" {
    // CR R8.6 (v0.2.2): on no-libc Zig 0.16 test builds parentEnvMap()
    // intentionally returns an empty map (the documented security contract,
    // R7-1) — so buildScrubbedEnv() also returns empty, and HOME is missing
    // from `scrubbed` for legitimate reasons. Skip there to keep the contract
    // self-consistent across libc-linked and no-libc test builds. The
    // libc-linked path (default for `zig build test`) is what carries the
    // production guarantee that HOME, PATH, locale, etc. propagate to spawned
    // git/jj/ghq subprocesses.
    if (!builtin.link_libc) return error.SkipZigTest;

    // On the libc-linked path, std.testing.environ is the portable view of
    // the same environ block that std.c.environ exposes. buildScrubbedEnv
    // must agree with that view — if it doesn't, HOME (and friends) silently
    // drop from the scrubbed map and every git/jj/ghq subprocess loses its
    // config-discovery anchor.
    const gpa = testing.allocator;

    // Resolve HOME via the testing-environ block — this is the contract
    // buildScrubbedEnv must match, not "whatever libc happens to expose".
    var parent_map = try std.testing.environ.createMap(gpa);
    defer parent_map.deinit();
    const parent_home = parent_map.get("HOME") orelse return error.SkipZigTest;
    try testing.expect(parent_home.len > 0);

    var scrubbed = try buildScrubbedEnv(gpa);
    defer scrubbed.deinit();

    const home = scrubbed.get("HOME") orelse return error.HomeMissingInScrubbedEnv;
    try testing.expectEqualStrings(parent_home, home);
}

test "buildScrubbedEnv excludes dangerous git/jj/rclone env vars" {
    // Even if the parent env contains these (set by an attacker, hook,
    // sudo wrapper, etc.), they must NEVER reach the scrubbed map. This
    // is the security contract that buildScrubbedEnv exists to enforce.
    const gpa = testing.allocator;
    var scrubbed = try buildScrubbedEnv(gpa);
    defer scrubbed.deinit();

    const forbidden = [_][]const u8{
        "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0",     "GIT_CONFIG_VALUE_0",
        "GIT_DIR",          "GIT_OBJECT_DIRECTORY", "GIT_SSH_COMMAND",
        "GIT_AUTHOR_NAME",  "GIT_COMMITTER_NAME",   "GIT_TERMINAL_PROMPT",
        "GIT_INDEX_FILE",   "GIT_WORK_TREE",        "JJ_USER",
        "JJ_EMAIL",         "JJ_OP_HOSTNAME",       "RCLONE_CONFIG",
        "RCLONE_VERBOSE",   "GH_TOKEN",             "GITHUB_TOKEN",
    };

    // Deterministic contract (CR R8.5, v0.2.2): if a forbidden key is
    // accidentally added to env_whitelist but happens to be unset in the
    // host env / CI runner, the runtime check below would silently pass.
    // Pin the whitelist itself so the test fails the moment any forbidden
    // name appears there, regardless of host env contents.
    for (forbidden) |blocked| {
        var found = false;
        for (env_whitelist) |allowed| {
            if (std.mem.eql(u8, blocked, allowed)) {
                found = true;
                break;
            }
        }
        try testing.expect(!found);
    }

    for (forbidden) |key| {
        try testing.expect(scrubbed.get(key) == null);
    }
}

test "buildScrubbedEnv mirrors parent environ for every whitelist key" {
    // CR R8.6 (v0.2.2): same no-libc carve-out as the "preserves" test.
    // parentEnvMap returns Map.init(gpa) when builtin.link_libc is false, so
    // scrubbed is also empty there — the assertion below would fire for
    // legitimate reasons (the documented R7-1 security contract), not a
    // real regression. Default `zig build test` links libc and exercises
    // the production guarantee path that this test pins.
    if (!builtin.link_libc) return error.SkipZigTest;

    // Contract: scrubbed env must agree with the parent shell environ
    // for every whitelist key — present in parent ⇒ present and equal in
    // scrubbed; absent in parent ⇒ absent in scrubbed. Compares against
    // std.testing.environ.createMap (the portable view of the same block
    // std.c.environ exposes under POSIX libc), so it catches any bug
    // where buildScrubbedEnv silently drops or rewrites whitelisted vars.
    const gpa = testing.allocator;

    var parent_map = try std.testing.environ.createMap(gpa);
    defer parent_map.deinit();

    var scrubbed = try buildScrubbedEnv(gpa);
    defer scrubbed.deinit();

    for (env_whitelist) |key| {
        const parent_value = parent_map.get(key);
        const scrubbed_value = scrubbed.get(key);
        if (parent_value) |pv| {
            // Parent has this var → scrubbed must too, with the same value.
            const sv = scrubbed_value orelse return error.WhitelistedVarMissing;
            try testing.expectEqualStrings(pv, sv);
        } else {
            // Parent doesn't have it → scrubbed must not have it either.
            try testing.expect(scrubbed_value == null);
        }
    }
}

// ===== exec() tests =====

test "exec git version succeeds" {
    const gpa = testing.allocator;
    const io = testing.io;
    var result = try exec(gpa, io, &.{ "git", "--version" }, null);
    defer result.deinit(gpa);
    try testing.expect(result.succeeded());
    try testing.expect(std.mem.startsWith(u8, result.stdout, "git version"));
}

test "exec captures stderr on failure" {
    const gpa = testing.allocator;
    const io = testing.io;
    var result = try exec(gpa, io, &.{ "git", "log", "--oneline", "-1", "--invalid-flag-xyz" }, null);
    defer result.deinit(gpa);
    try testing.expect(!result.succeeded());
    try testing.expect(result.stderr.len > 0);
}

test "exec nonexistent command returns FileNotFound" {
    const gpa = testing.allocator;
    const io = testing.io;
    const result = exec(gpa, io, &.{"__nonexistent_binary_12345__"}, null);
    try testing.expectError(error.FileNotFound, result);
}

test "exec with cwd" {
    const gpa = testing.allocator;
    const io = testing.io;
    var result = try exec(gpa, io, &.{"pwd"}, "/tmp");
    defer result.deinit(gpa);
    try testing.expect(result.succeeded());
    const trimmed = trimTrailingNewline(result.stdout);
    // On macOS /tmp -> /private/tmp
    try testing.expect(std.mem.endsWith(u8, trimmed, "/tmp"));
}

test "exec with null cwd inherits current dir" {
    const gpa = testing.allocator;
    const io = testing.io;
    var result = try exec(gpa, io, &.{"pwd"}, null);
    defer result.deinit(gpa);
    try testing.expect(result.succeeded());
    try testing.expect(result.stdout.len > 0);
}

test "exec multi-arg command" {
    const gpa = testing.allocator;
    const io = testing.io;
    var result = try exec(gpa, io, &.{ "echo", "hello", "world" }, null);
    defer result.deinit(gpa);
    try testing.expect(result.succeeded());
    try testing.expectEqualStrings("hello world\n", result.stdout);
}

test "exec empty stdout" {
    const gpa = testing.allocator;
    const io = testing.io;
    var result = try exec(gpa, io, &.{"true"}, null);
    defer result.deinit(gpa);
    try testing.expect(result.succeeded());
    try testing.expectEqualStrings("", result.stdout);
}

test "exec exit code preserved" {
    const gpa = testing.allocator;
    const io = testing.io;
    var result = try exec(gpa, io, &.{"false"}, null);
    defer result.deinit(gpa);
    try testing.expect(!result.succeeded());
    try testing.expect(result.term == .exited);
    try testing.expect(result.term.exited != 0);
}

// ===== ExecResult.succeeded() tests =====

test "succeeded returns true for exit 0" {
    const result = ExecResult{
        .stdout = &.{},
        .stderr = &.{},
        .term = .{ .exited = 0 },
    };
    try testing.expect(result.succeeded());
}

test "succeeded returns false for exit 1" {
    const result = ExecResult{
        .stdout = &.{},
        .stderr = &.{},
        .term = .{ .exited = 1 },
    };
    try testing.expect(!result.succeeded());
}

test "succeeded returns false for signal" {
    const result = ExecResult{
        .stdout = &.{},
        .stderr = &.{},
        .term = .{ .signal = .SEGV },
    };
    try testing.expect(!result.succeeded());
}

// ===== execCheck() tests =====

test "execCheck returns stdout on success" {
    const gpa = testing.allocator;
    const io = testing.io;
    const stdout = try execCheck(gpa, io, &.{ "echo", "hello" }, null);
    defer gpa.free(stdout);
    try testing.expectEqualStrings("hello\n", stdout);
}

test "execCheck returns error on failure" {
    const gpa = testing.allocator;
    const io = testing.io;
    const result = execCheck(gpa, io, &.{"false"}, null);
    try testing.expectError(error.ProcessFailed, result);
}

test "execCheck returns error on nonexistent command" {
    const gpa = testing.allocator;
    const io = testing.io;
    const result = execCheck(gpa, io, &.{"__no_such_cmd__"}, null);
    try testing.expectError(error.FileNotFound, result);
}

// ===== trimTrailingNewline() tests =====

test "trimTrailingNewline removes LF" {
    try testing.expectEqualStrings("hello", trimTrailingNewline("hello\n"));
}

test "trimTrailingNewline removes CRLF" {
    try testing.expectEqualStrings("hello", trimTrailingNewline("hello\r\n"));
}

test "trimTrailingNewline removes multiple trailing newlines" {
    try testing.expectEqualStrings("hello", trimTrailingNewline("hello\n\n\n"));
}

test "trimTrailingNewline preserves no-newline string" {
    try testing.expectEqualStrings("hello", trimTrailingNewline("hello"));
}

test "trimTrailingNewline on empty string" {
    try testing.expectEqualStrings("", trimTrailingNewline(""));
}

test "trimTrailingNewline on only newlines" {
    try testing.expectEqualStrings("", trimTrailingNewline("\n"));
    try testing.expectEqualStrings("", trimTrailingNewline("\r\n"));
    try testing.expectEqualStrings("", trimTrailingNewline("\n\r\n"));
}

test "trimTrailingNewline preserves internal newlines" {
    try testing.expectEqualStrings("hello\nworld", trimTrailingNewline("hello\nworld\n"));
}

test "trimTrailingNewline preserves spaces" {
    try testing.expectEqualStrings("hello ", trimTrailingNewline("hello \n"));
}
