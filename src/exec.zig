const std = @import("std");
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
    "XDG_CACHE_HOME",
};

/// Build a fresh env map containing only `env_whitelist` entries that are
/// present in the current process environment. Caller owns the returned
/// map and must `deinit` it.
fn buildScrubbedEnv(gpa: Allocator) Allocator.Error!std.process.Environ.Map {
    var out: std.process.Environ.Map = .init(gpa);
    errdefer out.deinit();
    for (env_whitelist) |key| {
        if (lookupParentEnv(key)) |value| {
            try out.put(key, value);
        }
    }
    return out;
}

/// Look up a single variable in the parent process environment via the
/// POSIX `environ` global. Returns null when the variable is unset or when
/// running on a target without a libc `environ` symbol (e.g. WASI).
fn lookupParentEnv(key: []const u8) ?[]const u8 {
    if (!@hasDecl(std.c, "environ")) return null;
    const environ = std.c.environ;
    var i: usize = 0;
    while (environ[i]) |entry| : (i += 1) {
        const slice = std.mem.sliceTo(entry, 0);
        if (slice.len <= key.len) continue;
        if (slice[key.len] != '=') continue;
        if (!std.mem.eql(u8, slice[0..key.len], key)) continue;
        return slice[key.len + 1 ..];
    }
    return null;
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
