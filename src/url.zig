//! URL parsing for gitstore — matches ghq v1.8.0 shape handling.
//!
//! Pure module: no I/O, no env, no threads. All slices in the returned
//! `RepoSpec` are owned by the allocator passed to `parse()` and must be
//! released via `RepoSpec.deinit()`.
//!
//! See `/Users/etretiakov/.claude/plans/libgitstore-v2.md` for the URL
//! shapes this module handles and their canonical storage layout.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Transport scheme that produced the `RepoSpec`.
pub const Scheme = enum { https, http, ssh, file, git };

/// A parsed repository reference.
///
/// `host`, `owner`, `name`, and `orig_url` are heap-allocated by the
/// allocator passed to `parse()`. Call `deinit()` to free them.
pub const RepoSpec = struct {
    host: []const u8,
    owner: []const u8,
    name: []const u8,
    scheme: Scheme,
    orig_url: []const u8,

    pub fn deinit(self: *RepoSpec, gpa: Allocator) void {
        gpa.free(self.host);
        gpa.free(self.owner);
        gpa.free(self.name);
        gpa.free(self.orig_url);
        self.* = undefined;
    }

    /// Produce `<root>/<host>/<owner>/<name>`; for `file://` specs where
    /// `host == ""`, `<host>` is replaced by the sentinel `_file_`.
    /// Caller owns returned slice.
    pub fn toStoragePath(self: RepoSpec, gpa: Allocator, root: []const u8) ![]u8 {
        const host_part: []const u8 = if (self.host.len == 0) "_file_" else self.host;
        // Trim trailing '/' from root (but not a lone "/").
        var trimmed_root = root;
        while (trimmed_root.len > 1 and trimmed_root[trimmed_root.len - 1] == '/') {
            trimmed_root = trimmed_root[0 .. trimmed_root.len - 1];
        }
        return std.fmt.allocPrint(gpa, "{s}/{s}/{s}/{s}", .{
            trimmed_root,
            host_part,
            self.owner,
            self.name,
        });
    }

    /// Reconstruct the URL `git clone` should target.
    ///
    /// Some forges serve git from a host that differs from their web UI
    /// host (e.g. SourceCraft: web `sourcecraft.dev`, git
    /// `git.sourcecraft.dev`). The storage path stays on the *web* host
    /// (`self.host`, via `toStoragePath`); only the clone URL is
    /// rewritten to the git host returned by `cloneHost`.
    ///
    /// The transport scheme is preserved:
    ///   * `https`/`http` → `"<scheme>://<git-host>/<owner>/<name>.git"`
    ///   * `git`          → `"git://<git-host>/<owner>/<name>.git"`
    ///   * `ssh`          → scp form `"git@<git-host>:<owner>/<name>.git"`
    ///   * `file`         → a dupe of `orig_url` (no host to rewrite)
    ///
    /// Caller owns the returned slice.
    pub fn cloneUrl(self: RepoSpec, gpa: Allocator) CloneUrlError![]u8 {
        if (self.scheme == .file) {
            return gpa.dupe(u8, self.orig_url);
        }

        const git_host = cloneHost(self.host);
        return switch (self.scheme) {
            .https => std.fmt.allocPrint(gpa, "https://{s}/{s}/{s}.git", .{
                git_host, self.owner, self.name,
            }),
            .http => std.fmt.allocPrint(gpa, "http://{s}/{s}/{s}.git", .{
                git_host, self.owner, self.name,
            }),
            .git => std.fmt.allocPrint(gpa, "git://{s}/{s}/{s}.git", .{
                git_host, self.owner, self.name,
            }),
            .ssh => std.fmt.allocPrint(gpa, "git@{s}:{s}/{s}.git", .{
                git_host, self.owner, self.name,
            }),
            .file => unreachable, // handled above
        };
    }
};

/// Defaults used when parsing short inputs (`repo` or `owner/repo`).
pub const Defaults = struct {
    user: ?[]const u8 = null,
    host: []const u8 = "github.com",
};

pub const ParseError = error{
    EmptyInput,
    InvalidFormat,
    MissingUser,
    DoubleSlash,
    InvalidHost,
    OutOfMemory,
};

/// Errors `RepoSpec.cloneUrl` may return. Allocation is the only failure
/// mode — host rewriting and scheme handling are total over a valid
/// `RepoSpec`.
pub const CloneUrlError = error{OutOfMemory};

/// Maps a forge's web-UI host to the host that actually serves git.
///
/// Most forges serve git from the same host as their web UI (identity).
/// SourceCraft is the known exception: its web UI lives at
/// `sourcecraft.dev` but git/jj clones must target `git.sourcecraft.dev`
/// (empirically verified — clones against the web host fail).
const CloneHostOverride = struct { web: []const u8, git: []const u8 };

const clone_host_overrides = [_]CloneHostOverride{
    .{ .web = "sourcecraft.dev", .git = "git.sourcecraft.dev" },
};

/// Return the git-serving host for a given web host.
///
/// Identity for any host without a registered override; otherwise the
/// override's git host. The returned slice points either into the input
/// (`web_host`) or into the static `clone_host_overrides` table, so it
/// never needs freeing.
pub fn cloneHost(web_host: []const u8) []const u8 {
    for (clone_host_overrides) |o| {
        if (std.mem.eql(u8, web_host, o.web)) return o.git;
    }
    return web_host;
}

/// Parse any of the shapes documented in libgitstore-v2.md into a
/// `RepoSpec`. The returned struct owns its strings via `gpa`.
///
/// Case is preserved (no lowercasing). A trailing `/` on the input is
/// trimmed before parsing, and a trailing `.git` is stripped from `name`
/// only — `orig_url` always holds the raw (pre-trim) input.
pub fn parse(gpa: Allocator, input: []const u8, defaults: Defaults) ParseError!RepoSpec {
    if (input.len == 0) return error.EmptyInput;

    // Preserve the original input verbatim for orig_url.
    const orig = try gpa.dupe(u8, input);

    // Working copy: trim trailing '/' characters.
    var work = input;
    while (work.len > 0 and work[work.len - 1] == '/') {
        work = work[0 .. work.len - 1];
    }
    if (work.len == 0) {
        gpa.free(orig);
        return error.EmptyInput;
    }

    // Dispatch by shape.
    if (std.mem.startsWith(u8, work, "file://")) {
        return parseFile(gpa, work, orig);
    }
    if (std.mem.startsWith(u8, work, "https://")) {
        return parseUrl(gpa, work["https://".len..], .https, orig);
    }
    if (std.mem.startsWith(u8, work, "http://")) {
        return parseUrl(gpa, work["http://".len..], .http, orig);
    }
    if (std.mem.startsWith(u8, work, "ssh://")) {
        return parseUrl(gpa, work["ssh://".len..], .ssh, orig);
    }
    if (std.mem.startsWith(u8, work, "git://")) {
        return parseUrl(gpa, work["git://".len..], .git, orig);
    }

    // scp-like: `user@host:path`. Rewrite to ssh form.
    if (std.mem.indexOfScalar(u8, work, '@')) |at_idx| {
        if (std.mem.indexOfScalar(u8, work, ':')) |colon_idx| {
            if (colon_idx > at_idx and !std.mem.startsWith(u8, work, "://")) {
                return parseScpLike(gpa, work, at_idx, colon_idx, orig);
            }
        }
    }

    // Short forms: `repo`, `owner/repo`, or `host/owner/repo`.
    return parseShort(gpa, work, defaults, orig);
}

fn parseFile(gpa: Allocator, work: []const u8, orig: []u8) ParseError!RepoSpec {
    errdefer gpa.free(orig);
    const prefix = "file://";
    std.debug.assert(std.mem.startsWith(u8, work, prefix));
    const path = work[prefix.len..];
    if (path.len == 0) return error.InvalidFormat;

    // Split on '/'. Require at least owner + name segments.
    // Reject empty interior segments (double-slash) except the leading
    // ones that result from `file:///abs/path` — path may start with '/'.
    var trimmed = path;
    while (trimmed.len > 0 and trimmed[0] == '/') trimmed = trimmed[1..];
    if (trimmed.len == 0) return error.InvalidFormat;

    // Split remaining segments; each must be non-empty.
    var segs: std.ArrayList([]const u8) = .empty;
    defer segs.deinit(gpa);
    var it = std.mem.splitScalar(u8, trimmed, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) return error.DoubleSlash;
        try segs.append(gpa, seg);
    }
    if (segs.items.len < 2) return error.InvalidFormat;

    const name_raw = segs.items[segs.items.len - 1];
    const owner = segs.items[segs.items.len - 2];
    const name = stripDotGit(name_raw);

    const host_dup = try gpa.dupe(u8, "");
    errdefer gpa.free(host_dup);
    const owner_dup = try gpa.dupe(u8, owner);
    errdefer gpa.free(owner_dup);
    const name_dup = try gpa.dupe(u8, name);
    errdefer gpa.free(name_dup);

    return .{
        .host = host_dup,
        .owner = owner_dup,
        .name = name_dup,
        .scheme = .file,
        .orig_url = orig,
    };
}

/// Parse `host[:port]/owner/repo[.git]` (after the scheme prefix has been
/// stripped). Optional `user@` prefix is permitted for ssh.
fn parseUrl(gpa: Allocator, rest: []const u8, scheme: Scheme, orig: []u8) ParseError!RepoSpec {
    errdefer gpa.free(orig);
    if (rest.len == 0) return error.InvalidFormat;

    // Strip optional `user@` (informational only — we drop the user).
    var tail = rest;
    if (std.mem.indexOfScalar(u8, tail, '@')) |at| {
        // Only treat as userinfo if '@' appears before the first '/'.
        const slash = std.mem.indexOfScalar(u8, tail, '/') orelse tail.len;
        if (at < slash) tail = tail[at + 1 ..];
    }

    // Split host from path.
    const slash = std.mem.indexOfScalar(u8, tail, '/') orelse return error.InvalidFormat;
    var host_with_port = tail[0..slash];
    const path = tail[slash + 1 ..];
    if (host_with_port.len == 0) return error.InvalidHost;
    if (path.len == 0) return error.InvalidFormat;

    // Strip optional `:port` from host.
    if (std.mem.indexOfScalar(u8, host_with_port, ':')) |colon| {
        host_with_port = host_with_port[0..colon];
    }
    if (host_with_port.len == 0) return error.InvalidHost;

    // Split remaining path segments; reject empty ones.
    var segs: std.ArrayList([]const u8) = .empty;
    defer segs.deinit(gpa);
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) return error.DoubleSlash;
        try segs.append(gpa, seg);
    }
    if (segs.items.len < 2) return error.InvalidFormat;

    const owner = segs.items[0];
    const name_raw = segs.items[segs.items.len - 1];
    // Note: intermediate path segments (e.g. gitlab subgroups) are
    // collapsed into the owner slot for gitstore v1. For now we
    // conservatively require exactly 2 segments to keep parity with ghq.
    if (segs.items.len != 2) return error.InvalidFormat;
    const name = stripDotGit(name_raw);

    const host_dup = try gpa.dupe(u8, host_with_port);
    errdefer gpa.free(host_dup);
    const owner_dup = try gpa.dupe(u8, owner);
    errdefer gpa.free(owner_dup);
    const name_dup = try gpa.dupe(u8, name);
    errdefer gpa.free(name_dup);

    return .{
        .host = host_dup,
        .owner = owner_dup,
        .name = name_dup,
        .scheme = scheme,
        .orig_url = orig,
    };
}

/// Parse `user@host:owner/repo[.git]` (scp-like git URL).
fn parseScpLike(
    gpa: Allocator,
    work: []const u8,
    at_idx: usize,
    colon_idx: usize,
    orig: []u8,
) ParseError!RepoSpec {
    errdefer gpa.free(orig);
    if (colon_idx <= at_idx + 1) return error.InvalidHost;
    const host = work[at_idx + 1 .. colon_idx];
    if (host.len == 0) return error.InvalidHost;
    if (colon_idx + 1 >= work.len) return error.InvalidFormat;
    const path = work[colon_idx + 1 ..];

    var segs: std.ArrayList([]const u8) = .empty;
    defer segs.deinit(gpa);
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) return error.DoubleSlash;
        try segs.append(gpa, seg);
    }
    if (segs.items.len != 2) return error.InvalidFormat;

    const owner = segs.items[0];
    const name_raw = segs.items[1];
    const name = stripDotGit(name_raw);

    const host_dup = try gpa.dupe(u8, host);
    errdefer gpa.free(host_dup);
    const owner_dup = try gpa.dupe(u8, owner);
    errdefer gpa.free(owner_dup);
    const name_dup = try gpa.dupe(u8, name);
    errdefer gpa.free(name_dup);

    return .{
        .host = host_dup,
        .owner = owner_dup,
        .name = name_dup,
        .scheme = .ssh,
        .orig_url = orig,
    };
}

/// Parse short forms:
///   * `repo`               → defaults.host / defaults.user / repo
///   * `owner/repo`         → defaults.host / owner / repo
///   * `host/owner/repo`    → host / owner / repo (only when first
///                            segment looks like a DNS host)
fn parseShort(
    gpa: Allocator,
    work: []const u8,
    defaults: Defaults,
    orig: []u8,
) ParseError!RepoSpec {
    errdefer gpa.free(orig);

    var segs: std.ArrayList([]const u8) = .empty;
    defer segs.deinit(gpa);
    var it = std.mem.splitScalar(u8, work, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) return error.DoubleSlash;
        try segs.append(gpa, seg);
    }

    const n = segs.items.len;
    if (n == 0) return error.EmptyInput;

    var host: []const u8 = defaults.host;
    var owner: []const u8 = undefined;
    var name_raw: []const u8 = undefined;

    switch (n) {
        1 => {
            const user = defaults.user orelse return error.MissingUser;
            owner = user;
            name_raw = segs.items[0];
        },
        2 => {
            owner = segs.items[0];
            name_raw = segs.items[1];
        },
        3 => {
            // The first segment must look like a DNS host. Accept only
            // `[A-Za-z0-9]+\.[A-Za-z]+(:port)?$`.
            if (!looksLikeHost(segs.items[0])) return error.InvalidFormat;
            host = stripHostPort(segs.items[0]);
            owner = segs.items[1];
            name_raw = segs.items[2];
        },
        else => return error.InvalidFormat,
    }

    if (host.len == 0) return error.InvalidHost;
    if (owner.len == 0 or name_raw.len == 0) return error.InvalidFormat;
    const name = stripDotGit(name_raw);
    if (name.len == 0) return error.InvalidFormat;

    const host_dup = try gpa.dupe(u8, host);
    errdefer gpa.free(host_dup);
    const owner_dup = try gpa.dupe(u8, owner);
    errdefer gpa.free(owner_dup);
    const name_dup = try gpa.dupe(u8, name);
    errdefer gpa.free(name_dup);

    return .{
        .host = host_dup,
        .owner = owner_dup,
        .name = name_dup,
        .scheme = .https,
        .orig_url = orig,
    };
}

fn stripDotGit(s: []const u8) []const u8 {
    if (std.mem.endsWith(u8, s, ".git")) return s[0 .. s.len - ".git".len];
    return s;
}

fn stripHostPort(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, ':')) |c| return s[0..c];
    return s;
}

/// Returns true if `s` matches `[A-Za-z0-9]+\.[A-Za-z]+(:[0-9]+)?$`.
fn looksLikeHost(s: []const u8) bool {
    if (s.len == 0) return false;

    // Split optional `:port`.
    const core = stripHostPort(s);
    if (core.len == 0) return false;

    // Require at least one '.' with alphanumeric on the left and alpha on
    // the right tail. Ensure the final label contains only letters.
    const dot = std.mem.lastIndexOfScalar(u8, core, '.') orelse return false;
    if (dot == 0 or dot == core.len - 1) return false;

    const head = core[0..dot];
    const tail = core[dot + 1 ..];

    // Head: at least one alphanumeric; allow '.', '-' elsewhere.
    var any_alnum = false;
    for (head) |c| {
        if (isAlnum(c)) {
            any_alnum = true;
            continue;
        }
        if (c == '.' or c == '-') continue;
        return false;
    }
    if (!any_alnum) return false;

    // Tail: at least one alpha, all alpha.
    if (tail.len == 0) return false;
    for (tail) |c| {
        if (!isAlpha(c)) return false;
    }

    // If there was a port, ensure it's all digits.
    if (core.len != s.len) {
        const port = s[core.len + 1 ..];
        if (port.len == 0) return false;
        for (port) |c| {
            if (c < '0' or c > '9') return false;
        }
    }
    return true;
}

fn isAlnum(c: u8) bool {
    return isAlpha(c) or (c >= '0' and c <= '9');
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

// =========================================================
// Tests — all test names are prefixed "url:" so they can be
// filtered via `zig build test --test-filter "url:"`.
// =========================================================

const testing = std.testing;

fn expectSpec(spec: RepoSpec, host: []const u8, owner: []const u8, name: []const u8, scheme: Scheme) !void {
    try testing.expectEqualStrings(host, spec.host);
    try testing.expectEqualStrings(owner, spec.owner);
    try testing.expectEqualStrings(name, spec.name);
    try testing.expectEqual(scheme, spec.scheme);
}

test "url: owner/repo short form with default host" {
    const gpa = testing.allocator;
    var spec = try parse(gpa, "x-motemen/ghq", .{});
    defer spec.deinit(gpa);
    try expectSpec(spec, "github.com", "x-motemen", "ghq", .https);
}

test "url: bare repo with default user" {
    const gpa = testing.allocator;
    var spec = try parse(gpa, "ghq", .{ .user = "eugot" });
    defer spec.deinit(gpa);
    try expectSpec(spec, "github.com", "eugot", "ghq", .https);
}

test "url: bare repo missing default user returns error" {
    const gpa = testing.allocator;
    try testing.expectError(error.MissingUser, parse(gpa, "ghq", .{}));
}

test "url: three-segment host/owner/repo" {
    const gpa = testing.allocator;
    var spec = try parse(gpa, "gitlab.com/foo/bar", .{});
    defer spec.deinit(gpa);
    try expectSpec(spec, "gitlab.com", "foo", "bar", .https);
}

test "url: https URL with trailing .git stripped from name only" {
    const gpa = testing.allocator;
    var spec = try parse(gpa, "https://github.com/a/b.git", .{});
    defer spec.deinit(gpa);
    try expectSpec(spec, "github.com", "a", "b", .https);
    try testing.expectEqualStrings("https://github.com/a/b.git", spec.orig_url);
}

test "url: http URL" {
    const gpa = testing.allocator;
    var spec = try parse(gpa, "http://example.com/a/b", .{});
    defer spec.deinit(gpa);
    try expectSpec(spec, "example.com", "a", "b", .http);
}

test "url: scp-style ssh with user@host:owner/repo" {
    const gpa = testing.allocator;
    var spec = try parse(gpa, "git@github.com:a/b.git", .{});
    defer spec.deinit(gpa);
    try expectSpec(spec, "github.com", "a", "b", .ssh);
}

test "url: ssh URL with port preserved in scheme but stripped from host" {
    const gpa = testing.allocator;
    var spec = try parse(gpa, "ssh://git@git.example.com:2222/a/b.git", .{});
    defer spec.deinit(gpa);
    try testing.expectEqualStrings("git.example.com", spec.host);
    try testing.expectEqualStrings("a", spec.owner);
    try testing.expectEqualStrings("b", spec.name);
    try testing.expectEqual(Scheme.ssh, spec.scheme);
}

test "url: file:// path produces empty host" {
    const gpa = testing.allocator;
    var spec = try parse(gpa, "file:///tmp/repos/myproj", .{});
    defer spec.deinit(gpa);
    try testing.expectEqual(Scheme.file, spec.scheme);
    try testing.expectEqualStrings("", spec.host);
    try testing.expectEqualStrings("myproj", spec.name);
}

test "url: trailing slash is trimmed before parsing" {
    const gpa = testing.allocator;
    var spec = try parse(gpa, "github.com/a/b/", .{});
    defer spec.deinit(gpa);
    try expectSpec(spec, "github.com", "a", "b", .https);
}

test "url: double slash u//r is rejected" {
    const gpa = testing.allocator;
    try testing.expectError(error.DoubleSlash, parse(gpa, "a//b", .{}));
}

test "url: empty input is rejected" {
    const gpa = testing.allocator;
    try testing.expectError(error.EmptyInput, parse(gpa, "", .{}));
}

test "url: toStoragePath composes root/host/owner/name" {
    const gpa = testing.allocator;
    var spec = try parse(gpa, "github.com/a/b", .{});
    defer spec.deinit(gpa);
    const p = try spec.toStoragePath(gpa, "/tmp/ghq");
    defer gpa.free(p);
    try testing.expectEqualStrings("/tmp/ghq/github.com/a/b", p);
}

test "url: toStoragePath with file:// uses _file_ placeholder" {
    const gpa = testing.allocator;
    var spec = try parse(gpa, "file:///tmp/work/proj", .{});
    defer spec.deinit(gpa);
    const p = try spec.toStoragePath(gpa, "/gs");
    defer gpa.free(p);
    try testing.expectEqualStrings("/gs/_file_/work/proj", p);
}

test "url: toStoragePath trims trailing slash from root" {
    const gpa = testing.allocator;
    var spec = try parse(gpa, "github.com/a/b", .{});
    defer spec.deinit(gpa);
    const p = try spec.toStoragePath(gpa, "/tmp/ghq/");
    defer gpa.free(p);
    try testing.expectEqualStrings("/tmp/ghq/github.com/a/b", p);
}

test "url: case is preserved (no folding)" {
    const gpa = testing.allocator;
    var spec = try parse(gpa, "https://GitHub.com/UPPER/lower", .{});
    defer spec.deinit(gpa);
    try testing.expectEqualStrings("GitHub.com", spec.host);
    try testing.expectEqualStrings("UPPER", spec.owner);
    try testing.expectEqualStrings("lower", spec.name);
}

test "url: ssh://user@host/a/b strips .git from name" {
    const gpa = testing.allocator;
    var spec = try parse(gpa, "ssh://git@example.com/a/b.git", .{});
    defer spec.deinit(gpa);
    try testing.expectEqualStrings("b", spec.name);
}

test "url: https with port in host-part path works" {
    const gpa = testing.allocator;
    var spec = try parse(gpa, "https://self-hosted.example:8443/team/repo", .{});
    defer spec.deinit(gpa);
    try testing.expectEqualStrings("team", spec.owner);
    try testing.expectEqualStrings("repo", spec.name);
}

// ---- clone-host rewrite (SourceCraft git host != web host) ----

test "url: cloneHost identity for hosts without override" {
    try testing.expectEqualStrings("github.com", cloneHost("github.com"));
    try testing.expectEqualStrings("gitlab.com", cloneHost("gitlab.com"));
    try testing.expectEqualStrings("codeberg.org", cloneHost("codeberg.org"));
    try testing.expectEqualStrings("dagshub.com", cloneHost("dagshub.com"));
    try testing.expectEqualStrings("example.com", cloneHost("example.com"));
}

test "url: cloneHost rewrites sourcecraft web host to git host" {
    try testing.expectEqualStrings("git.sourcecraft.dev", cloneHost("sourcecraft.dev"));
}

test "url: cloneUrl rewrites https sourcecraft to git host" {
    const gpa = testing.allocator;
    var spec = try parse(gpa, "https://sourcecraft.dev/owner/repo", .{});
    defer spec.deinit(gpa);
    const u = try spec.cloneUrl(gpa);
    defer gpa.free(u);
    try testing.expectEqualStrings("https://git.sourcecraft.dev/owner/repo.git", u);
}

test "url: cloneUrl keeps storage path on the web host after rewrite" {
    const gpa = testing.allocator;
    var spec = try parse(gpa, "https://sourcecraft.dev/owner/repo", .{});
    defer spec.deinit(gpa);
    // The clone URL targets the git host…
    const u = try spec.cloneUrl(gpa);
    defer gpa.free(u);
    try testing.expectEqualStrings("https://git.sourcecraft.dev/owner/repo.git", u);
    // …but the storage path must stay on the web host.
    const p = try spec.toStoragePath(gpa, "/ghq");
    defer gpa.free(p);
    try testing.expectEqualStrings("/ghq/sourcecraft.dev/owner/repo", p);
}

test "url: cloneUrl is identity for https github" {
    const gpa = testing.allocator;
    var spec = try parse(gpa, "https://github.com/a/b", .{});
    defer spec.deinit(gpa);
    const u = try spec.cloneUrl(gpa);
    defer gpa.free(u);
    try testing.expectEqualStrings("https://github.com/a/b.git", u);
}

test "url: cloneUrl preserves http scheme" {
    const gpa = testing.allocator;
    var spec = try parse(gpa, "http://example.com/a/b", .{});
    defer spec.deinit(gpa);
    const u = try spec.cloneUrl(gpa);
    defer gpa.free(u);
    try testing.expectEqualStrings("http://example.com/a/b.git", u);
}

test "url: cloneUrl ssh scp-form rewrites sourcecraft git host" {
    const gpa = testing.allocator;
    var spec = try parse(gpa, "git@sourcecraft.dev:owner/repo.git", .{});
    defer spec.deinit(gpa);
    const u = try spec.cloneUrl(gpa);
    defer gpa.free(u);
    try testing.expectEqualStrings("git@git.sourcecraft.dev:owner/repo.git", u);
}

test "url: cloneUrl ssh scp-form is identity for github" {
    const gpa = testing.allocator;
    var spec = try parse(gpa, "git@github.com:a/b.git", .{});
    defer spec.deinit(gpa);
    const u = try spec.cloneUrl(gpa);
    defer gpa.free(u);
    try testing.expectEqualStrings("git@github.com:a/b.git", u);
}

test "url: cloneUrl file scheme passes orig_url through unchanged" {
    const gpa = testing.allocator;
    var spec = try parse(gpa, "file:///tmp/repos/myproj", .{});
    defer spec.deinit(gpa);
    const u = try spec.cloneUrl(gpa);
    defer gpa.free(u);
    try testing.expectEqualStrings("file:///tmp/repos/myproj", u);
}

test "url: cloneUrl git scheme rewrites sourcecraft git host" {
    const gpa = testing.allocator;
    var spec = try parse(gpa, "git://sourcecraft.dev/owner/repo", .{});
    defer spec.deinit(gpa);
    const u = try spec.cloneUrl(gpa);
    defer gpa.free(u);
    try testing.expectEqualStrings("git://git.sourcecraft.dev/owner/repo.git", u);
}

test "url: cloneUrl git scheme is identity for non-override host" {
    const gpa = testing.allocator;
    var spec = try parse(gpa, "git://example.com/a/b", .{});
    defer spec.deinit(gpa);
    const u = try spec.cloneUrl(gpa);
    defer gpa.free(u);
    try testing.expectEqualStrings("git://example.com/a/b.git", u);
}

test "url: cloneUrl ssh:// URL emits scp-form with override" {
    const gpa = testing.allocator;
    var spec = try parse(gpa, "ssh://git@sourcecraft.dev/owner/repo", .{});
    defer spec.deinit(gpa);
    const u = try spec.cloneUrl(gpa);
    defer gpa.free(u);
    try testing.expectEqualStrings("git@git.sourcecraft.dev:owner/repo.git", u);
}

fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = testing.allocator;
    var buf: [512]u8 = undefined;
    const len: usize = smith.valueRangeAtMost(u16, 0, @intCast(buf.len));
    smith.bytes(buf[0..len]);
    const input = buf[0..len];

    var spec = parse(gpa, input, .{ .user = "eugot" }) catch return;
    defer spec.deinit(gpa);
    // If parse succeeded, basic invariants must hold.
    try testing.expect(spec.name.len > 0);
    try testing.expect(spec.owner.len > 0);
}

test "url: fuzz — parse must not crash on any input" {
    try testing.fuzz({}, fuzzOne, .{});
}
