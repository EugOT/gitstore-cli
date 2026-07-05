/// Comprehensive integration and end-to-end tests for gitstore.
/// Tests use a temporary directory tree to avoid touching real repos.
const std = @import("std");
const testing = std.testing;
const Dir = std.Io.Dir;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const gitstore = @import("z3store.zig");
const ex = @import("exec.zig");
const oplog = @import("log.zig");
const hooks = @import("hooks.zig");

// Pull in tests from all modules
comptime {
    _ = @import("exec.zig");
    _ = @import("log.zig");
    _ = @import("hooks.zig");
    _ = @import("url.zig");
    _ = @import("config.zig");
    _ = @import("list.zig");
    _ = @import("cache.zig");
    _ = @import("clone.zig");
    _ = @import("lore.zig");
    // main.zig hosts inline unit tests for its private dispatcher helpers
    // (getGitstoreRoot / getGhqRoot / resolveGhqRootOrHome) and e2e tests
    // that spawn the built gitstore binary. Force-importing it here makes the
    // integration test runner collect those `test` blocks. main.zig is
    // path-relative and transitively imports the co-located src/ modules, so
    // no extra build.zig wiring is needed beyond the `build_options` seam.
    _ = @import("main.zig");
}

const config = @import("config.zig");

// ===== Test helpers =====

fn tempPathCandidate(gpa: Allocator, io: Io, prefix: []const u8, suffix: []const u8, attempt: u32) ![]u8 {
    var entropy_marker: u8 = undefined;
    const tid = std.Thread.getCurrentId();
    const ns = Io.Clock.real.now(io).nanoseconds;
    return std.fmt.allocPrint(
        gpa,
        "{s}_{d}_{d}_{x}{s}",
        .{ prefix, attempt, tid ^ @as(u64, @intCast(ns)), @intFromPtr(&entropy_marker), suffix },
    );
}

/// Reserve a collision-resistant `/tmp` directory. Exclusive creation is the
/// load-bearing safety property: if another test process chooses the same path,
/// it gets `PathAlreadyExists` and retries instead of deleting shared state.
fn uniqueTempDir(gpa: Allocator, io: Io, prefix: []const u8) ![]u8 {
    var attempt: u32 = 0;
    while (attempt < 64) : (attempt += 1) {
        const path = try tempPathCandidate(gpa, io, prefix, "", attempt);
        Dir.cwd().createDir(io, path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                gpa.free(path);
                continue;
            },
            else => |e| {
                gpa.free(path);
                return e;
            },
        };
        return path;
    }
    return error.PathAlreadyExists;
}

/// Reserve a collision-resistant empty file and return its path. The caller may
/// write through normal APIs and is responsible for deleting the file.
fn uniqueTempFile(gpa: Allocator, io: Io, prefix: []const u8, suffix: []const u8) ![]u8 {
    var attempt: u32 = 0;
    while (attempt < 64) : (attempt += 1) {
        const path = try tempPathCandidate(gpa, io, prefix, suffix, attempt);
        var file = Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                gpa.free(path);
                continue;
            },
            else => |e| {
                gpa.free(path);
                return e;
            },
        };
        file.close(io);
        return path;
    }
    return error.PathAlreadyExists;
}

const TestEnv = struct {
    base: []const u8,
    ghq_root: []const u8,
    gitstore_root: []const u8,
    gpa: Allocator,
    io: Io,

    fn setup(gpa: Allocator, io: Io) !TestEnv {
        const base = try uniqueTempDir(gpa, io, "/tmp/gitstore_test_env");
        errdefer gpa.free(base);
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

    fn teardown(self: *const TestEnv) void {
        Dir.cwd().deleteTree(self.io, self.base) catch {};
        self.gpa.free(self.base);
        self.gpa.free(self.ghq_root);
        self.gpa.free(self.gitstore_root);
    }

    /// Create a git repo at ghq_root/org/name with an initial commit.
    fn createRepo(self: *const TestEnv, org: []const u8, name: []const u8) ![]u8 {
        const repo_path = try std.fmt.allocPrint(self.gpa, "{s}/{s}/{s}", .{ self.ghq_root, org, name });
        errdefer self.gpa.free(repo_path);
        try Dir.cwd().createDirPath(self.io, repo_path);
        try self.gitInitAt(repo_path);
        return repo_path;
    }

    /// Create a git+jj colocated repo.
    fn createJjRepo(self: *const TestEnv, org: []const u8, name: []const u8) ![]u8 {
        const repo_path = try self.createRepo(org, name);
        errdefer self.gpa.free(repo_path);

        const r = try ex.exec(self.gpa, self.io, &.{ "jj", "git", "init", "--colocate" }, repo_path);
        defer self.gpa.free(r.stdout);
        defer self.gpa.free(r.stderr);
        if (!r.succeeded()) return error.ProcessFailed;

        return repo_path;
    }

    /// Run `git init` + user config + an initial empty commit inside an
    /// already-created directory. Shared by `createRepo` and the
    /// host/owner/name helpers used by the *All orchestrator tests.
    fn gitInitAt(self: *const TestEnv, repo_path: []const u8) !void {
        const r1 = try ex.exec(self.gpa, self.io, &.{ "git", "init" }, repo_path);
        defer self.gpa.free(r1.stdout);
        defer self.gpa.free(r1.stderr);
        if (!r1.succeeded()) return error.ProcessFailed;

        const r1b = try ex.exec(self.gpa, self.io, &.{ "git", "config", "user.email", "test@test.com" }, repo_path);
        defer self.gpa.free(r1b.stdout);
        defer self.gpa.free(r1b.stderr);
        if (!r1b.succeeded()) return error.ProcessFailed;

        const r1c = try ex.exec(self.gpa, self.io, &.{ "git", "config", "user.name", "Test" }, repo_path);
        defer self.gpa.free(r1c.stdout);
        defer self.gpa.free(r1c.stderr);
        if (!r1c.succeeded()) return error.ProcessFailed;

        const r2 = try ex.exec(self.gpa, self.io, &.{ "git", "commit", "--no-verify", "--allow-empty", "-m", "init" }, repo_path);
        defer self.gpa.free(r2.stdout);
        defer self.gpa.free(r2.stderr);
        if (!r2.succeeded()) return error.ProcessFailed;
    }

    /// Create a real git repo at `ghq_root/host/owner/name` (the ghq
    /// host/owner/name layout that `list.walk` enumerates). `host` must
    /// contain a dot so it passes `looksLikeHost`. Caller frees the path.
    fn createHostRepo(self: *const TestEnv, host: []const u8, owner: []const u8, name: []const u8) ![]u8 {
        const repo_path = try std.fmt.allocPrint(self.gpa, "{s}/{s}/{s}/{s}", .{ self.ghq_root, host, owner, name });
        errdefer self.gpa.free(repo_path);
        try Dir.cwd().createDirPath(self.io, repo_path);
        try self.gitInitAt(repo_path);
        return repo_path;
    }

    /// Create a bare owner directory `ghq_root/host/owner` with no repos.
    /// Used to exercise the "root exists but enumerates nothing" path.
    fn createOwnerDir(self: *const TestEnv, host: []const u8, owner: []const u8) !void {
        const p = try std.fmt.allocPrint(self.gpa, "{s}/{s}/{s}", .{ self.ghq_root, host, owner });
        defer self.gpa.free(p);
        try Dir.cwd().createDirPath(self.io, p);
    }
};

// =========================================================
// repoRelativePath unit tests
// =========================================================

test "repoRelativePath basic case" {
    const result = gitstore.repoRelativePath("/home/user/ghq/github.com/Org/repo", "/home/user/ghq");
    try testing.expect(result != null);
    try testing.expectEqualStrings("github.com/Org/repo", result.?);
}

test "repoRelativePath with trailing slash on root" {
    const result = gitstore.repoRelativePath("/home/user/ghq/github.com/Org/repo", "/home/user/ghq/");
    try testing.expect(result != null);
    try testing.expectEqualStrings("github.com/Org/repo", result.?);
}

test "repoRelativePath with multiple trailing slashes" {
    const result = gitstore.repoRelativePath("/home/user/ghq/github.com/Org/repo", "/home/user/ghq///");
    try testing.expect(result != null);
    try testing.expectEqualStrings("github.com/Org/repo", result.?);
}

test "repoRelativePath returns null for unrelated path" {
    const result = gitstore.repoRelativePath("/other/path/repo", "/home/user/ghq");
    try testing.expect(result == null);
}

test "repoRelativePath returns null when repo equals root" {
    const result = gitstore.repoRelativePath("/home/user/ghq", "/home/user/ghq");
    try testing.expect(result == null);
}

test "repoRelativePath returns null for partial prefix match" {
    // "/home/user/ghq2" starts with "/home/user/ghq" but is not a child
    const result = gitstore.repoRelativePath("/home/user/ghq2/repo", "/home/user/ghq");
    try testing.expect(result == null);
}

test "repoRelativePath with single-level path" {
    const result = gitstore.repoRelativePath("/ghq/repo", "/ghq");
    try testing.expect(result != null);
    try testing.expectEqualStrings("repo", result.?);
}

test "repoRelativePath with deep nesting" {
    const result = gitstore.repoRelativePath("/a/b/c/d/e/f", "/a/b");
    try testing.expect(result != null);
    try testing.expectEqualStrings("c/d/e/f", result.?);
}

test "repoRelativePath root is /" {
    const result = gitstore.repoRelativePath("/ghq/repo", "/");
    try testing.expect(result != null);
    try testing.expectEqualStrings("ghq/repo", result.?);
}

test "repoRelativePath empty root returns null" {
    const result = gitstore.repoRelativePath("/ghq/repo", "");
    try testing.expect(result == null);
}

// =========================================================
// isAdopted unit tests
// =========================================================

test "isAdopted returns false for nonexistent path" {
    const io = testing.io;
    const gpa = testing.allocator;
    try testing.expect(!gitstore.isAdopted(io, "/tmp/gitstore_test_no_such_path_12345", "/any", gpa));
}

test "isAdopted returns true when pointer targets gitstore_root" {
    const io = testing.io;
    const gpa = testing.allocator;
    const dir = "/tmp/gitstore_test_adopted";
    Dir.cwd().createDirPath(io, dir) catch {};
    defer Dir.cwd().deleteTree(io, dir) catch {};

    try Dir.cwd().writeFile(io, .{
        .sub_path = "/tmp/gitstore_test_adopted/.git",
        .data = "gitdir: /tmp/mygitstore/github.com/a/b/git\n",
    });

    try testing.expect(gitstore.isAdopted(io, dir, "/tmp/mygitstore", gpa));
}

test "isAdopted returns false when pointer targets non-gitstore path (linked worktree)" {
    const io = testing.io;
    const gpa = testing.allocator;
    const dir = "/tmp/gitstore_test_linked_wt";
    Dir.cwd().createDirPath(io, dir) catch {};
    defer Dir.cwd().deleteTree(io, dir) catch {};

    // A normal linked worktree points into the main repo's .git/worktrees/
    try Dir.cwd().writeFile(io, .{
        .sub_path = "/tmp/gitstore_test_linked_wt/.git",
        .data = "gitdir: /tmp/some_repo/.git/worktrees/mybranch\n",
    });

    try testing.expect(!gitstore.isAdopted(io, dir, "/tmp/mygitstore", gpa));
}

test "isAdopted returns false for .git directory" {
    const io = testing.io;
    const gpa = testing.allocator;
    const dir = "/tmp/gitstore_test_not_adopted";
    Dir.cwd().deleteTree(io, dir) catch {};
    try Dir.cwd().createDirPath(io, dir);
    try Dir.cwd().createDirPath(io, "/tmp/gitstore_test_not_adopted/.git");
    defer Dir.cwd().deleteTree(io, dir) catch {};

    try testing.expect(!gitstore.isAdopted(io, dir, "/tmp/mygitstore", gpa));
}

test "isAdopted returns false for non-gitdir file content" {
    const io = testing.io;
    const gpa = testing.allocator;
    const dir = "/tmp/gitstore_test_bad_pointer";
    Dir.cwd().createDirPath(io, dir) catch {};
    defer Dir.cwd().deleteTree(io, dir) catch {};

    try Dir.cwd().writeFile(io, .{
        .sub_path = "/tmp/gitstore_test_bad_pointer/.git",
        .data = "not a gitdir pointer\n",
    });

    try testing.expect(!gitstore.isAdopted(io, dir, "/tmp/mygitstore", gpa));
}

test "repoStoragePath falls back to absolute minus slash when not under ghq" {
    const out = gitstore.repoStoragePath("/Users/x/outside", "/Users/x/ghq").?;
    try testing.expectEqualStrings("Users/x/outside", out);
}

test "repoStoragePath uses ghq-relative when under ghq root" {
    const out = gitstore.repoStoragePath("/Users/x/ghq/github.com/o/r", "/Users/x/ghq").?;
    try testing.expectEqualStrings("github.com/o/r", out);
}

test "repoStoragePath returns null for non-absolute path" {
    try testing.expect(gitstore.repoStoragePath("relative/path", "/any") == null);
}

// =========================================================
// rewriteJjGitTarget unit tests
// =========================================================

test "rewriteJjGitTarget writes absolute path" {
    const io = testing.io;
    const gpa = testing.allocator;
    const jj_dir = "/tmp/gitstore_test_jj_target";
    Dir.cwd().deleteTree(io, jj_dir) catch {};
    try Dir.cwd().createDirPath(io, "/tmp/gitstore_test_jj_target/repo/store");
    defer Dir.cwd().deleteTree(io, jj_dir) catch {};

    // Write initial relative content
    try Dir.cwd().writeFile(io, .{
        .sub_path = "/tmp/gitstore_test_jj_target/repo/store/git_target",
        .data = "../../../.git",
    });

    try gitstore.rewriteJjGitTarget(gpa, io, jj_dir, "/store/path/git");

    const content = try Dir.cwd().readFileAlloc(
        io,
        "/tmp/gitstore_test_jj_target/repo/store/git_target",
        gpa,
        .unlimited,
    );
    defer gpa.free(content);
    try testing.expectEqualStrings("/store/path/git", content);
}

test "rewriteJjGitTarget does not error when file missing" {
    const io = testing.io;
    const gpa = testing.allocator;
    // Should not fail even if the path doesn't exist
    try gitstore.rewriteJjGitTarget(gpa, io, "/tmp/no_such_jj_dir_12345", "/some/git");
}

// =========================================================
// init tests
// =========================================================

test "init creates gitstore directory" {
    const io = testing.io;
    const dir = "/tmp/gitstore_test_init_dir";
    Dir.cwd().deleteTree(io, dir) catch {};
    defer Dir.cwd().deleteTree(io, dir) catch {};

    try gitstore.init(io, dir);

    // Verify directory exists by opening it
    var d = try Dir.openDirAbsolute(io, dir, .{});
    d.close(io);
}

test "init is idempotent" {
    const io = testing.io;
    const dir = "/tmp/gitstore_test_init_idem";
    Dir.cwd().deleteTree(io, dir) catch {};
    defer Dir.cwd().deleteTree(io, dir) catch {};

    try gitstore.init(io, dir);
    try gitstore.init(io, dir); // second call should not error

    var d = try Dir.openDirAbsolute(io, dir, .{});
    d.close(io);
}

// =========================================================
// E2E: adopt git-only repo
// =========================================================

test "e2e adopt git-only repo" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const repo = try env.createRepo("testorg", "gitonly");
    defer gpa.free(repo);

    try gitstore.adopt(gpa, io, repo, env.ghq_root, env.gitstore_root, false);

    // .git should be a pointer file
    const git_path = try std.fmt.allocPrint(gpa, "{s}/.git", .{repo});
    defer gpa.free(git_path);
    const content = try Dir.cwd().readFileAlloc(io, git_path, gpa, .unlimited);
    defer gpa.free(content);
    try testing.expect(std.mem.startsWith(u8, content, "gitdir: "));

    // git should still work
    const git_r = try ex.exec(gpa, io, &.{ "git", "-C", repo, "rev-parse", "HEAD" }, null);
    defer {
        gpa.free(git_r.stdout);
        gpa.free(git_r.stderr);
    }
    try testing.expect(git_r.succeeded());
}

// =========================================================
// E2E: adopt when jj binary is missing (regression #22)
// =========================================================

test "e2e adopt git-only repo completes when jj binary is missing" {
    const io = testing.io;
    const gpa = testing.allocator;

    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const repo = try env.createRepo("testorg", "nojj");
    defer gpa.free(repo);

    // Simulate an uninstalled jj deterministically: an absolute path that
    // cannot exist makes the spawn itself fail with error.FileNotFound.
    // Injected as a parameter (not shared global state), so the override is
    // local to this test and safe under concurrent adopts.
    // Regression EugOT/gitstore-cli#22: a missing jj binary (spawn
    // error.FileNotFound) must be as non-fatal as jj exiting non-zero —
    // git-level adoption is already complete when the jj step runs.
    try gitstore.adoptWithJjBinary(gpa, io, repo, env.ghq_root, env.gitstore_root, false, "/nonexistent/gitstore-test-missing-jj");

    // Git-level adoption completed: .git is a pointer file.
    const git_path = try std.fmt.allocPrint(gpa, "{s}/.git", .{repo});
    defer gpa.free(git_path);
    const content = try Dir.cwd().readFileAlloc(io, git_path, gpa, .unlimited);
    defer gpa.free(content);
    try testing.expect(std.mem.startsWith(u8, content, "gitdir: "));

    // The jj spawn failure is recorded in the operations log.
    const log_file = try std.fmt.allocPrint(gpa, "{s}/operations.log", .{env.gitstore_root});
    defer gpa.free(log_file);
    const log_content = try Dir.cwd().readFileAlloc(io, log_file, gpa, .unlimited);
    defer gpa.free(log_content);
    try testing.expect(std.mem.indexOf(u8, log_content, "\"action\":\"init_jj\"") != null);
    try testing.expect(std.mem.indexOf(u8, log_content, "error: jj spawn failed") != null);
}

// =========================================================
// E2E: adopt git+jj colocated repo
// =========================================================

test "e2e adopt git+jj colocated repo" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const repo = try env.createJjRepo("testorg", "jjrepo");
    defer gpa.free(repo);

    try gitstore.adopt(gpa, io, repo, env.ghq_root, env.gitstore_root, false);

    // .git should be a pointer file
    const git_path = try std.fmt.allocPrint(gpa, "{s}/.git", .{repo});
    defer gpa.free(git_path);
    const content = try Dir.cwd().readFileAlloc(io, git_path, gpa, .unlimited);
    defer gpa.free(content);
    try testing.expect(std.mem.startsWith(u8, content, "gitdir: "));

    // .jj should be a symlink
    const jj_path = try std.fmt.allocPrint(gpa, "{s}/.jj", .{repo});
    defer gpa.free(jj_path);
    var link_buf: [Dir.max_path_bytes]u8 = undefined;
    const link_len = try Dir.readLinkAbsolute(io, jj_path, &link_buf);
    const link_target = link_buf[0..link_len];
    try testing.expect(std.mem.startsWith(u8, link_target, env.gitstore_root));

    // git should work
    const git_r = try ex.exec(gpa, io, &.{ "git", "-C", repo, "rev-parse", "HEAD" }, null);
    defer {
        gpa.free(git_r.stdout);
        gpa.free(git_r.stderr);
    }
    try testing.expect(git_r.succeeded());

    // jj should work
    const jj_r = try ex.exec(gpa, io, &.{ "jj", "status", "-R", repo }, null);
    defer {
        gpa.free(jj_r.stdout);
        gpa.free(jj_r.stderr);
    }
    try testing.expect(jj_r.succeeded());

    // git_target should be absolute
    const git_target_path = try std.fmt.allocPrint(gpa, "{s}/.jj/repo/store/git_target", .{repo});
    defer gpa.free(git_target_path);
    const gt_content = try Dir.cwd().readFileAlloc(io, git_target_path, gpa, .unlimited);
    defer gpa.free(gt_content);
    try testing.expect(gt_content[0] == '/'); // absolute path
}

// =========================================================
// E2E: adopt dry-run does not modify
// =========================================================

test "e2e adopt dry-run does not modify repo" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const repo = try env.createRepo("testorg", "dryrun");
    defer gpa.free(repo);

    try gitstore.adopt(gpa, io, repo, env.ghq_root, env.gitstore_root, true);

    // .git should still be a directory (statFile on it would not give IsDir if it were a file)
    const git_path = try std.fmt.allocPrint(gpa, "{s}/.git", .{repo});
    defer gpa.free(git_path);
    _ = Dir.cwd().readFileAlloc(io, git_path, gpa, .unlimited) catch |err| switch (err) {
        error.IsDir => return, // Expected: .git is still a directory
        else => return err,
    };
    // If readFileAlloc succeeded, .git is a file — that means dry-run modified it (failure)
    return error.TestUnexpectedResult;
}

// =========================================================
// E2E: adopt idempotent re-adopt
// =========================================================

test "e2e adopt is idempotent" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const repo = try env.createRepo("testorg", "idempotent");
    defer gpa.free(repo);

    // First adopt
    try gitstore.adopt(gpa, io, repo, env.ghq_root, env.gitstore_root, false);

    // Read pointer content
    const git_path = try std.fmt.allocPrint(gpa, "{s}/.git", .{repo});
    defer gpa.free(git_path);
    const content1 = try Dir.cwd().readFileAlloc(io, git_path, gpa, .unlimited);
    defer gpa.free(content1);

    // Second adopt should skip
    try gitstore.adopt(gpa, io, repo, env.ghq_root, env.gitstore_root, false);

    // Pointer should be unchanged
    const content2 = try Dir.cwd().readFileAlloc(io, git_path, gpa, .unlimited);
    defer gpa.free(content2);
    try testing.expectEqualStrings(content1, content2);
}

// =========================================================
// E2E: adopt rejects repo not under ghq root
// =========================================================

test "e2e adopt accepts repo outside ghq root (fallback absolute-path storage)" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    // Create a repo OUTSIDE env.ghq_root
    const repo = try std.fmt.allocPrint(gpa, "{s}/outside/myproject", .{env.base});
    defer gpa.free(repo);
    try Dir.cwd().createDirPath(io, repo);

    const r0 = try ex.exec(gpa, io, &.{ "git", "init" }, repo);
    gpa.free(r0.stdout);
    gpa.free(r0.stderr);
    const rc1 = try ex.exec(gpa, io, &.{ "git", "config", "user.email", "t@t.com" }, repo);
    gpa.free(rc1.stdout);
    gpa.free(rc1.stderr);
    const rc2 = try ex.exec(gpa, io, &.{ "git", "config", "user.name", "T" }, repo);
    gpa.free(rc2.stdout);
    gpa.free(rc2.stderr);
    const rc3 = try ex.exec(gpa, io, &.{ "git", "commit", "--no-verify", "--allow-empty", "-m", "init" }, repo);
    gpa.free(rc3.stdout);
    gpa.free(rc3.stderr);

    try gitstore.adopt(gpa, io, repo, env.ghq_root, env.gitstore_root, false);

    // Gitstore subdir must mirror absolute path minus leading slash
    const rel = gitstore.repoStoragePath(repo, env.ghq_root).?;
    const expected = try std.fmt.allocPrint(gpa, "{s}/{s}/git", .{ env.gitstore_root, rel });
    defer gpa.free(expected);
    var d = try Dir.openDirAbsolute(io, expected, .{});
    d.close(io);

    const git_r = try ex.exec(gpa, io, &.{ "git", "-C", repo, "rev-parse", "--git-dir" }, null);
    defer {
        gpa.free(git_r.stdout);
        gpa.free(git_r.stderr);
    }
    try testing.expect(git_r.succeeded());
}

// =========================================================
// E2E: adopt rejects non-git directory
// =========================================================

test "e2e adopt rejects non-git directory" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const dir = try std.fmt.allocPrint(gpa, "{s}/testorg/notgit", .{env.ghq_root});
    defer gpa.free(dir);
    try Dir.cwd().createDirPath(io, dir);

    const result = gitstore.adopt(gpa, io, dir, env.ghq_root, env.gitstore_root, false);
    try testing.expectError(error.NotAGitRepo, result);
}

// =========================================================
// E2E: verify passes on adopted repo
// =========================================================

test "e2e verify passes on correctly adopted repo" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const repo = try env.createRepo("testorg", "verify_ok");
    defer gpa.free(repo);

    try gitstore.adopt(gpa, io, repo, env.ghq_root, env.gitstore_root, false);

    const ok = try gitstore.verify(gpa, io, repo);
    try testing.expect(ok);
}
// =========================================================
// E2E: verify accepts relative repo path
// =========================================================

test "e2e verify accepts relative adopted repo path" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const repo = try env.createRepo("testorg", "verify_relative");
    defer gpa.free(repo);

    try gitstore.adopt(gpa, io, repo, env.ghq_root, env.gitstore_root, false);

    const relative_repo = try uniqueTempFile(gpa, io, "gitstore_verify_relative_link", "");
    defer gpa.free(relative_repo);
    try Dir.cwd().deleteFile(io, relative_repo);
    defer Dir.cwd().deleteFile(io, relative_repo) catch unreachable;
    try Dir.cwd().symLink(io, repo, relative_repo, .{ .is_directory = true });

    const ok = try gitstore.verify(gpa, io, relative_repo);
    try testing.expect(ok);
}

// =========================================================
// E2E: verify fails on non-adopted repo
// =========================================================

test "e2e verify fails on non-adopted repo" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const repo = try env.createRepo("testorg", "verify_nonadopted");
    defer gpa.free(repo);

    // Not adopted — .git is still a directory
    const ok = try gitstore.verify(gpa, io, repo);
    try testing.expect(!ok);
}

// =========================================================
// E2E: verify detects broken pointer
// =========================================================

test "e2e verify detects broken gitdir pointer" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const repo = try env.createRepo("testorg", "verify_broken");
    defer gpa.free(repo);

    try gitstore.adopt(gpa, io, repo, env.ghq_root, env.gitstore_root, false);

    // Break the gitdir target by deleting the gitstore copy
    const rel = gitstore.repoRelativePath(repo, env.ghq_root).?;
    const git_dest = try std.fmt.allocPrint(gpa, "{s}/{s}/git", .{ env.gitstore_root, rel });
    defer gpa.free(git_dest);
    try Dir.cwd().deleteTree(io, git_dest);

    const ok = try gitstore.verify(gpa, io, repo);
    try testing.expect(!ok);
}

// =========================================================
// E2E: verify detects broken jj symlink
// =========================================================

test "e2e verify detects broken jj symlink" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const repo = try env.createJjRepo("testorg", "verify_broken_jj");
    defer gpa.free(repo);

    try gitstore.adopt(gpa, io, repo, env.ghq_root, env.gitstore_root, false);

    // Break the jj symlink target by deleting the gitstore jj copy
    const rel = gitstore.repoRelativePath(repo, env.ghq_root).?;
    const jj_dest = try std.fmt.allocPrint(gpa, "{s}/{s}/jj", .{ env.gitstore_root, rel });
    defer gpa.free(jj_dest);
    try Dir.cwd().deleteTree(io, jj_dest);

    const ok = try gitstore.verify(gpa, io, repo);
    try testing.expect(!ok);
}

// =========================================================
// E2E: operations.log is written during adopt
// =========================================================

test "e2e adopt writes operations log" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const repo = try env.createRepo("testorg", "logtest");
    defer gpa.free(repo);

    try gitstore.adopt(gpa, io, repo, env.ghq_root, env.gitstore_root, false);

    const log_path = try std.fmt.allocPrint(gpa, "{s}/operations.log", .{env.gitstore_root});
    defer gpa.free(log_path);

    const content = try Dir.cwd().readFileAlloc(io, log_path, gpa, .unlimited);
    defer gpa.free(content);

    // Should have at least copy, remove, write_pointer entries
    try testing.expect(std.mem.indexOf(u8, content, "\"action\":\"copy\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"action\":\"remove\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"action\":\"write_pointer\"") != null);

    // Each line should be valid JSONL
    var lines = std.mem.splitScalar(u8, ex.trimTrailingNewline(content), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try testing.expect(line[0] == '{');
        try testing.expect(line[line.len - 1] == '}');
    }
}

// =========================================================
// E2E: status reports correct counts
// =========================================================

// =========================================================
// E2E: initRepo on empty directory
// =========================================================

test "e2e initRepo creates git+jj and adopts" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const repo = try std.fmt.allocPrint(gpa, "{s}/testorg/fresh", .{env.ghq_root});
    defer gpa.free(repo);

    try gitstore.initRepo(gpa, io, repo, env.ghq_root, env.gitstore_root);

    // .git should be a pointer file
    const git_path = try std.fmt.allocPrint(gpa, "{s}/.git", .{repo});
    defer gpa.free(git_path);
    const content = try Dir.cwd().readFileAlloc(io, git_path, gpa, .unlimited);
    defer gpa.free(content);
    try testing.expect(std.mem.startsWith(u8, content, "gitdir: "));

    // .jj should be a symlink
    const jj_path = try std.fmt.allocPrint(gpa, "{s}/.jj", .{repo});
    defer gpa.free(jj_path);
    var link_buf: [Dir.max_path_bytes]u8 = undefined;
    const link_len = try Dir.readLinkAbsolute(io, jj_path, &link_buf);
    try testing.expect(link_len > 0);

    // jj should work
    const jj_r = try ex.exec(gpa, io, &.{ "jj", "status", "-R", repo }, null);
    defer {
        gpa.free(jj_r.stdout);
        gpa.free(jj_r.stderr);
    }
    try testing.expect(jj_r.succeeded());
}

// =========================================================
// E2E: initRepo on existing repo just adopts
// =========================================================

test "e2e initRepo on existing repo adopts without re-init" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    // Create a repo with an actual commit
    const repo = try env.createRepo("testorg", "existing");
    defer gpa.free(repo);

    try gitstore.initRepo(gpa, io, repo, env.ghq_root, env.gitstore_root);

    // Verify commit is preserved
    const git_r = try ex.exec(gpa, io, &.{ "git", "-C", repo, "log", "--oneline" }, null);
    defer {
        gpa.free(git_r.stdout);
        gpa.free(git_r.stderr);
    }
    try testing.expect(git_r.succeeded());
    try testing.expect(std.mem.indexOf(u8, git_r.stdout, "init") != null);
}

// =========================================================
// E2E: initRepo is idempotent
// =========================================================

test "e2e initRepo idempotent on already adopted" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const repo = try std.fmt.allocPrint(gpa, "{s}/testorg/idem", .{env.ghq_root});
    defer gpa.free(repo);

    try gitstore.initRepo(gpa, io, repo, env.ghq_root, env.gitstore_root);

    // Second call should skip
    try gitstore.initRepo(gpa, io, repo, env.ghq_root, env.gitstore_root);

    // Still works
    const jj_r = try ex.exec(gpa, io, &.{ "jj", "status", "-R", repo }, null);
    defer {
        gpa.free(jj_r.stdout);
        gpa.free(jj_r.stderr);
    }
    try testing.expect(jj_r.succeeded());
}

// =========================================================
// E2E: status
// =========================================================

test "e2e status with empty gitstore" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    // status should not crash on empty gitstore
    // (It calls ghq list which returns real repos, but gitstore is empty)
    // Just verify it doesn't error
    try gitstore.status(gpa, io, env.ghq_root, env.gitstore_root, false);
    try gitstore.status(gpa, io, env.ghq_root, env.gitstore_root, true);
}

// =========================================================
// E2E: worktree-aware adopt
// =========================================================

test "e2e adopt repo with linked worktree rewrites pointer" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const repo = try env.createRepo("testorg", "wtrepo");
    defer gpa.free(repo);

    // Create a linked worktree on a new branch
    const wt_dir = try std.fmt.allocPrint(gpa, "{s}/wt-feature", .{env.base});
    defer gpa.free(wt_dir);
    Dir.cwd().deleteTree(io, wt_dir) catch {};
    defer Dir.cwd().deleteTree(io, wt_dir) catch {};
    const wt_add = try ex.exec(gpa, io, &.{ "git", "worktree", "add", "-b", "feature", wt_dir }, repo);
    gpa.free(wt_add.stdout);
    gpa.free(wt_add.stderr);
    try testing.expect(wt_add.term == .exited and wt_add.term.exited == 0);

    try gitstore.adopt(gpa, io, repo, env.ghq_root, env.gitstore_root, false);

    // Main is adopted: .git is a pointer
    const git_pointer = try std.fmt.allocPrint(gpa, "{s}/.git", .{repo});
    defer gpa.free(git_pointer);
    const main_content = try Dir.cwd().readFileAlloc(io, git_pointer, gpa, .unlimited);
    defer gpa.free(main_content);
    try testing.expect(std.mem.startsWith(u8, main_content, "gitdir: "));

    // Linked worktree's .git now points into gitstore
    const wt_git = try std.fmt.allocPrint(gpa, "{s}/.git", .{wt_dir});
    defer gpa.free(wt_git);
    const wt_content = try Dir.cwd().readFileAlloc(io, wt_git, gpa, .unlimited);
    defer gpa.free(wt_content);
    try testing.expect(std.mem.indexOf(u8, wt_content, env.gitstore_root) != null);
    try testing.expect(std.mem.indexOf(u8, wt_content, "/worktrees/") != null);

    // Both main and linked worktree still work
    const g_main = try ex.exec(gpa, io, &.{ "git", "-C", repo, "rev-parse", "--git-dir" }, null);
    defer {
        gpa.free(g_main.stdout);
        gpa.free(g_main.stderr);
    }
    try testing.expect(g_main.succeeded());

    const g_wt = try ex.exec(gpa, io, &.{ "git", "-C", wt_dir, "rev-parse", "--git-dir" }, null);
    defer {
        gpa.free(g_wt.stdout);
        gpa.free(g_wt.stderr);
    }
    try testing.expect(g_wt.succeeded());
}

// =========================================================
// E2E: detach round-trip
// =========================================================

test "e2e detach round-trip git-only" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const repo = try env.createRepo("testorg", "detachgit");
    defer gpa.free(repo);

    try gitstore.adopt(gpa, io, repo, env.ghq_root, env.gitstore_root, false);
    try gitstore.detach(gpa, io, repo, env.ghq_root, env.gitstore_root, false, false);

    // .git is a directory again
    const gp = try std.fmt.allocPrint(gpa, "{s}/.git", .{repo});
    defer gpa.free(gp);
    var d = try Dir.openDirAbsolute(io, gp, .{});
    d.close(io);

    // git log still works
    const gl = try ex.exec(gpa, io, &.{ "git", "-C", repo, "log", "--oneline" }, null);
    defer {
        gpa.free(gl.stdout);
        gpa.free(gl.stderr);
    }
    try testing.expect(gl.succeeded());
    try testing.expect(std.mem.indexOf(u8, gl.stdout, "init") != null);

    // z3store entry removed
    const rel = gitstore.repoStoragePath(repo, env.ghq_root).?;
    const entry = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ env.gitstore_root, rel });
    defer gpa.free(entry);
    const opened = Dir.openDirAbsolute(io, entry, .{});
    try testing.expectError(error.FileNotFound, opened);
}

test "e2e detach round-trip jj+git" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const repo = try env.createJjRepo("testorg", "detachjj");
    defer gpa.free(repo);

    try gitstore.adopt(gpa, io, repo, env.ghq_root, env.gitstore_root, false);
    try gitstore.detach(gpa, io, repo, env.ghq_root, env.gitstore_root, false, false);

    // .git is a directory again
    const gp = try std.fmt.allocPrint(gpa, "{s}/.git", .{repo});
    defer gpa.free(gp);
    var d = try Dir.openDirAbsolute(io, gp, .{});
    d.close(io);

    // .jj is a directory (not symlink)
    const jp = try std.fmt.allocPrint(gpa, "{s}/.jj", .{repo});
    defer gpa.free(jp);
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const link = Dir.readLinkAbsolute(io, jp, &buf);
    try testing.expectError(error.NotLink, link);

    // git_target is relative again
    const gt = try std.fmt.allocPrint(gpa, "{s}/.jj/repo/store/git_target", .{repo});
    defer gpa.free(gt);
    const gt_content = try Dir.cwd().readFileAlloc(io, gt, gpa, .unlimited);
    defer gpa.free(gt_content);
    try testing.expect(std.mem.indexOf(u8, gt_content, "..") != null);

    // jj still works
    const js = try ex.exec(gpa, io, &.{ "jj", "status", "-R", repo }, null);
    defer {
        gpa.free(js.stdout);
        gpa.free(js.stderr);
    }
    try testing.expect(js.succeeded());
}

test "e2e detach propagates .jj backup rename failure" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const repo = try env.createJjRepo("testorg", "detachjjbackupfail");
    defer gpa.free(repo);

    try gitstore.adopt(gpa, io, repo, env.ghq_root, env.gitstore_root, false);

    const jj_backup = try std.fmt.allocPrint(gpa, "{s}/.jj.gs-old", .{repo});
    defer gpa.free(jj_backup);
    try Dir.cwd().createDirPath(io, jj_backup);
    const blocker = try std.fmt.allocPrint(gpa, "{s}/blocker", .{jj_backup});
    defer gpa.free(blocker);
    try Dir.cwd().writeFile(io, .{
        .sub_path = blocker,
        .data = "occupied\n",
    });

    if (gitstore.detach(gpa, io, repo, env.ghq_root, env.gitstore_root, false, false)) {
        return error.TestExpectedError;
    } else |err| switch (err) {
        error.PathAlreadyExists, error.IsDir, error.NotDir => {},
        else => return err,
    }
}

test "e2e detach rejects non-adopted repo" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const repo = try env.createRepo("testorg", "notadopted");
    defer gpa.free(repo);

    const result = gitstore.detach(gpa, io, repo, env.ghq_root, env.gitstore_root, false, false);
    try testing.expectError(error.NotAdopted, result);
}

test "e2e detach --keep-backup preserves archive" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const repo = try env.createRepo("testorg", "keepbackup");
    defer gpa.free(repo);

    try gitstore.adopt(gpa, io, repo, env.ghq_root, env.gitstore_root, false);
    try gitstore.detach(gpa, io, repo, env.ghq_root, env.gitstore_root, false, true);

    // Original entry removed
    const rel = gitstore.repoStoragePath(repo, env.ghq_root).?;
    const entry = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ env.gitstore_root, rel });
    defer gpa.free(entry);
    const opened = Dir.openDirAbsolute(io, entry, .{});
    try testing.expectError(error.FileNotFound, opened);

    // Some archive with .detached- prefix exists under the parent
    var parent_end = rel.len;
    while (parent_end > 0 and rel[parent_end - 1] != '/') parent_end -= 1;
    const parent_slice = rel[0..if (parent_end > 0) parent_end - 1 else 0];
    const parent = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ env.gitstore_root, parent_slice });
    defer gpa.free(parent);

    const ls_r = try ex.exec(gpa, io, &.{ "ls", "-a", parent }, null);
    defer {
        gpa.free(ls_r.stdout);
        gpa.free(ls_r.stderr);
    }
    try testing.expect(ls_r.succeeded());
    try testing.expect(std.mem.indexOf(u8, ls_r.stdout, ".detached-") != null);
}

test "e2e detach round-trip preserves linked worktree" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const repo = try env.createRepo("testorg", "detachwt");
    defer gpa.free(repo);

    const wt_dir = try std.fmt.allocPrint(gpa, "{s}/wt-detach", .{env.base});
    defer gpa.free(wt_dir);
    Dir.cwd().deleteTree(io, wt_dir) catch {};
    defer Dir.cwd().deleteTree(io, wt_dir) catch {};
    const wt_add = try ex.exec(gpa, io, &.{ "git", "worktree", "add", "-b", "feature", wt_dir }, repo);
    gpa.free(wt_add.stdout);
    gpa.free(wt_add.stderr);

    try gitstore.adopt(gpa, io, repo, env.ghq_root, env.gitstore_root, false);
    try gitstore.detach(gpa, io, repo, env.ghq_root, env.gitstore_root, false, false);

    // Linked worktree pointer now points back into repo's .git/worktrees
    const wt_git = try std.fmt.allocPrint(gpa, "{s}/.git", .{wt_dir});
    defer gpa.free(wt_git);
    const wt_content = try Dir.cwd().readFileAlloc(io, wt_git, gpa, .unlimited);
    defer gpa.free(wt_content);
    const expected_prefix = try std.fmt.allocPrint(gpa, "gitdir: {s}/.git/worktrees/", .{repo});
    defer gpa.free(expected_prefix);
    try testing.expect(std.mem.startsWith(u8, wt_content, expected_prefix));

    // Both main and linked work
    const g_main = try ex.exec(gpa, io, &.{ "git", "-C", repo, "rev-parse", "--git-dir" }, null);
    defer {
        gpa.free(g_main.stdout);
        gpa.free(g_main.stderr);
    }
    try testing.expect(g_main.succeeded());
    const g_wt = try ex.exec(gpa, io, &.{ "git", "-C", wt_dir, "rev-parse", "--git-dir" }, null);
    defer {
        gpa.free(g_wt.stdout);
        gpa.free(g_wt.stderr);
    }
    try testing.expect(g_wt.succeeded());
}

// =========================================================
// G6 — multi-repo orchestrators (adoptAll / verifyAll / detachAll).
//
// These exercise the native `list.walk`-backed enumeration that replaced
// the `ghq list --full-path` shell-out. Repos live under the ghq
// host/owner/name layout (host == "github.com" so `looksLikeHost` passes);
// no real `ghq` binary is involved. Adopted fixtures are produced by the
// real z3store adopt flow so the on-disk pointer AND the z3store git
// database both exist (verify/detach need the database to be real).
//
// NOTE on output assertions: z3store's `info()` helper early-returns under
// `builtin.is_test`, so the human-facing summary lines ("would detach: 1",
// "summary: N adopted ...") are intentionally suppressed during tests. G6
// therefore asserts on the *observable state* — return counts surfaced via
// out-params plus on-disk `.git` shape — which is the behavior the summary
// merely reports. `warn()` is NOT suppressed, so the absence of a `FAIL:`/
// `error:` line for a skipped repo is still a meaningful negative signal.
//
// `adoptAll`/`verifyAll`/`detachAll` print their counts rather than
// returning them, so each test re-derives the expected end state from disk.
// =========================================================

/// Read a repo's `.git` and report whether it is a `gitdir:` pointer file.
fn gitIsPointer(gpa: Allocator, io: Io, repo: []const u8) !bool {
    const gp = try std.fmt.allocPrint(gpa, "{s}/.git", .{repo});
    defer gpa.free(gp);
    const content = Dir.cwd().readFileAlloc(io, gp, gpa, .unlimited) catch |err| switch (err) {
        error.IsDir => return false,
        else => return err,
    };
    defer gpa.free(content);
    return std.mem.startsWith(u8, content, "gitdir: ");
}

/// True if `<repo>/.git` is a real directory (i.e. NOT adopted / detached).
fn gitIsDir(gpa: Allocator, io: Io, repo: []const u8) !bool {
    const gp = try std.fmt.allocPrint(gpa, "{s}/.git", .{repo});
    defer gpa.free(gp);
    var d = Dir.openDirAbsolute(io, gp, .{}) catch |err| switch (err) {
        error.NotDir => return false, // pointer file
        error.FileNotFound => return false,
        else => return err,
    };
    d.close(io);
    return true;
}

test "G6-1 adoptAll adopts fresh repos and skips pre-adopted" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const r1 = try env.createHostRepo("github.com", "o", "r1");
    defer gpa.free(r1);
    const r2 = try env.createHostRepo("github.com", "o", "r2");
    defer gpa.free(r2);
    const r3 = try env.createHostRepo("github.com", "o", "r3");
    defer gpa.free(r3);
    // r3 is already adopted before the batch runs.
    try gitstore.adopt(gpa, io, r3, env.ghq_root, env.gitstore_root, false);

    try gitstore.adoptAll(gpa, io, env.ghq_root, env.gitstore_root, false);

    // r1 and r2 are now pointer files; r3 stays a (valid) pointer.
    try testing.expect(try gitIsPointer(gpa, io, r1));
    try testing.expect(try gitIsPointer(gpa, io, r2));
    try testing.expect(try gitIsPointer(gpa, io, r3));
    // All three resolve as adopted; none is a bare .git dir.
    try testing.expect(gitstore.isAdopted(io, r1, env.gitstore_root, gpa));
    try testing.expect(gitstore.isAdopted(io, r2, env.gitstore_root, gpa));
    try testing.expect(gitstore.isAdopted(io, r3, env.gitstore_root, gpa));
}

test "G6-2 adoptAll re-run is all-skip with no pointer corruption" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const r1 = try env.createHostRepo("github.com", "o", "r1");
    defer gpa.free(r1);
    const r2 = try env.createHostRepo("github.com", "o", "r2");
    defer gpa.free(r2);
    const r3 = try env.createHostRepo("github.com", "o", "r3");
    defer gpa.free(r3);

    try gitstore.adoptAll(gpa, io, env.ghq_root, env.gitstore_root, false);
    // Second pass: everything already adopted -> no-op, no corruption.
    try gitstore.adoptAll(gpa, io, env.ghq_root, env.gitstore_root, false);

    try testing.expect(try gitIsPointer(gpa, io, r1));
    try testing.expect(try gitIsPointer(gpa, io, r2));
    try testing.expect(try gitIsPointer(gpa, io, r3));
    try testing.expect(gitstore.isAdopted(io, r1, env.gitstore_root, gpa));
    try testing.expect(gitstore.isAdopted(io, r2, env.gitstore_root, gpa));
    try testing.expect(gitstore.isAdopted(io, r3, env.gitstore_root, gpa));
}

test "G6-3 adoptAll on empty owner dir returns without error" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    // Owner directory exists but contains no repos; walk() yields nothing.
    try env.createOwnerDir("github.com", "o");

    // Old contract: `ghq list` success + empty output -> no error, 0 counts.
    // walk() preserves this exactly (empty slice, loop body never runs).
    try gitstore.adoptAll(gpa, io, env.ghq_root, env.gitstore_root, false);
}

test "G6-4 verifyAll counts ok and skips non-adopted repos" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const r1 = try env.createHostRepo("github.com", "o", "r1");
    defer gpa.free(r1);
    const r2 = try env.createHostRepo("github.com", "o", "r2");
    defer gpa.free(r2);
    // r1 adopted (real pointer + gitstore git dir); r2 left as a plain .git dir.
    try gitstore.adopt(gpa, io, r1, env.ghq_root, env.gitstore_root, false);

    // verifyAll prints its tally; assert the per-repo verify outcomes that
    // drive that tally. r1 must verify OK; r2 must never be examined (it is
    // not adopted, so the loop `continue`s past it).
    try testing.expect(try gitstore.verify(gpa, io, r1));
    try testing.expect(!gitstore.isAdopted(io, r2, env.gitstore_root, gpa));

    // The orchestrator itself must complete without error.
    try gitstore.verifyAll(gpa, io, env.ghq_root, env.gitstore_root);
}

test "G6-5 verifyAll surfaces a broken pointer as a failure" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const r1 = try env.createHostRepo("github.com", "o", "r1");
    defer gpa.free(r1);
    try gitstore.adopt(gpa, io, r1, env.ghq_root, env.gitstore_root, false);

    // Break the pointer by deleting the gitstore git database it targets.
    const store_git = try std.fmt.allocPrint(gpa, "{s}/github.com/o/r1/git", .{env.gitstore_root});
    defer gpa.free(store_git);
    try Dir.cwd().deleteTree(io, store_git);

    // r1 is still flagged adopted (pointer intact) so verifyAll WILL examine
    // it, and verify() must now report failure (target gone).
    try testing.expect(gitstore.isAdopted(io, r1, env.gitstore_root, gpa));
    try testing.expect(!try gitstore.verify(gpa, io, r1));

    // verifyAll completes (failures are tallied, not propagated as errors).
    try gitstore.verifyAll(gpa, io, env.ghq_root, env.gitstore_root);
}

test "G6-6 detachAll detaches adopted and skips non-adopted" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const r1 = try env.createHostRepo("github.com", "o", "r1");
    defer gpa.free(r1);
    const r2 = try env.createHostRepo("github.com", "o", "r2");
    defer gpa.free(r2);
    try gitstore.adopt(gpa, io, r1, env.ghq_root, env.gitstore_root, false);

    // Sanity: pre-state is r1 adopted (pointer), r2 a plain .git dir.
    try testing.expect(try gitIsPointer(gpa, io, r1));
    try testing.expect(try gitIsDir(gpa, io, r2));

    try gitstore.detachAll(gpa, io, env.ghq_root, env.gitstore_root, false, false);

    // r1 restored to a real .git directory; r2 untouched (still a dir).
    try testing.expect(try gitIsDir(gpa, io, r1));
    try testing.expect(!gitstore.isAdopted(io, r1, env.gitstore_root, gpa));
    try testing.expect(try gitIsDir(gpa, io, r2));
    // r1's git history survives the round-trip.
    const gl = try ex.exec(gpa, io, &.{ "git", "-C", r1, "log", "--oneline" }, null);
    defer {
        gpa.free(gl.stdout);
        gpa.free(gl.stderr);
    }
    try testing.expect(gl.succeeded());
}

test "G6-7 detachAll --dry-run leaves adopted entries in place" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const r1 = try env.createHostRepo("github.com", "o", "r1");
    defer gpa.free(r1);
    const r2 = try env.createHostRepo("github.com", "o", "r2");
    defer gpa.free(r2);
    try gitstore.adopt(gpa, io, r1, env.ghq_root, env.gitstore_root, false);

    // dry_run=true: the summary line "would detach: 1" is emitted via info(),
    // which is suppressed under builtin.is_test, so we assert the *invariant*
    // a dry run guarantees: nothing on disk changes.
    try gitstore.detachAll(gpa, io, env.ghq_root, env.gitstore_root, true, false);

    // r1 is STILL an adopted pointer; the gitstore database is STILL present.
    try testing.expect(try gitIsPointer(gpa, io, r1));
    try testing.expect(gitstore.isAdopted(io, r1, env.gitstore_root, gpa));
    const store_git = try std.fmt.allocPrint(gpa, "{s}/github.com/o/r1/git", .{env.gitstore_root});
    defer gpa.free(store_git);
    var sd = try Dir.openDirAbsolute(io, store_git, .{});
    sd.close(io);
    // r2 remains a plain .git dir.
    try testing.expect(try gitIsDir(gpa, io, r2));
}

test "G6-8 detachAll on empty root returns without error" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    // No repos under ghq_root at all (the root dir itself exists, empty).
    try gitstore.detachAll(gpa, io, env.ghq_root, env.gitstore_root, false, false);
}

// =========================================================
// config: resolvePrecedence — pure, Io.failing-testable
// =========================================================

test "config: resolvePrecedence prefers gitstore over all" {
    const r = config.resolvePrecedence("/g", "/h", "/e", "/d");
    try testing.expectEqualStrings("/g", r.value);
    try testing.expectEqual(config.Source.gitstore, r.source);
}

test "config: resolvePrecedence falls through to ghq when gitstore unset" {
    const r = config.resolvePrecedence(null, "/h", "/e", "/d");
    try testing.expectEqualStrings("/h", r.value);
    try testing.expectEqual(config.Source.ghq, r.source);
}

test "config: resolvePrecedence falls through to env when gitstore and ghq unset" {
    const r = config.resolvePrecedence(null, null, "/e", "/d");
    try testing.expectEqualStrings("/e", r.value);
    try testing.expectEqual(config.Source.env, r.source);
}

test "config: resolvePrecedence returns default when all unset" {
    const r = config.resolvePrecedence(null, null, null, "/d");
    try testing.expectEqualStrings("/d", r.value);
    try testing.expectEqual(config.Source.default, r.source);
}

test "config: resolvePrecedence empty gitstore is treated as unset" {
    const r = config.resolvePrecedence("", "/h", "/e", "/d");
    try testing.expectEqualStrings("/h", r.value);
    try testing.expectEqual(config.Source.ghq, r.source);
}

test "config: resolvePrecedence empty ghq is treated as unset" {
    const r = config.resolvePrecedence(null, "", "/e", "/d");
    try testing.expectEqualStrings("/e", r.value);
    try testing.expectEqual(config.Source.env, r.source);
}

test "config: resolvePrecedence empty env is treated as unset" {
    const r = config.resolvePrecedence(null, null, "", "/d");
    try testing.expectEqualStrings("/d", r.value);
    try testing.expectEqual(config.Source.default, r.source);
}

test "config: resolvePrecedence all empty returns default" {
    const r = config.resolvePrecedence("", "", "", "/d");
    try testing.expectEqualStrings("/d", r.value);
    try testing.expectEqual(config.Source.default, r.source);
}

test "config: resolvePrecedence empty default is returned as-is" {
    const r = config.resolvePrecedence(null, null, null, "");
    try testing.expectEqualStrings("", r.value);
    try testing.expectEqual(config.Source.default, r.source);
}

test "config: resolvePrecedence gitstore empty but ghq set prefers ghq" {
    const r = config.resolvePrecedence("", "github.com", null, "default.host");
    try testing.expectEqualStrings("github.com", r.value);
    try testing.expectEqual(config.Source.ghq, r.source);
}

test "config: resolvePrecedence single-char values" {
    const r = config.resolvePrecedence("a", "b", "c", "d");
    try testing.expectEqualStrings("a", r.value);
    try testing.expectEqual(config.Source.gitstore, r.source);
}

test "config: resolveRootChain prefers gitstore gitconfig over ghq env" {
    const r = config.resolveRootChain("/g", null, null, "/envghq", "/def");
    try testing.expectEqualStrings("/g", r.value);
    try testing.expectEqual(config.Source.gitstore, r.source);
}

test "config: resolveRootChain env gitstore_root beats env ghq_root" {
    const r = config.resolveRootChain(null, null, "/env_gs", "/env_ghq", "/def");
    try testing.expectEqualStrings("/env_gs", r.value);
    try testing.expectEqual(config.Source.env, r.source);
}

test "config: resolveRootChain falls back to default with all unset" {
    const r = config.resolveRootChain(null, null, null, null, "/def");
    try testing.expectEqualStrings("/def", r.value);
    try testing.expectEqual(config.Source.default, r.source);
}

// =========================================================
// config: fuzz resolvePrecedence is total (never panics)
// =========================================================

fn fuzzResolvePrecedence(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [256]u8 = undefined;

    const have_g = smith.value(bool);
    const have_h = smith.value(bool);
    const have_e = smith.value(bool);

    const g_len = if (have_g) smith.valueRangeAtMost(u8, 0, 64) else 0;
    const h_len = if (have_h) smith.valueRangeAtMost(u8, 0, 64) else 0;
    const e_len = if (have_e) smith.valueRangeAtMost(u8, 0, 64) else 0;
    const d_len = smith.valueRangeAtMost(u8, 0, 64);

    // Layout three potentially-present slices + default, end-to-end, in `buf`.
    var offset: usize = 0;
    smith.bytes(buf[offset .. offset + g_len]);
    const g_slice = buf[offset .. offset + g_len];
    offset += g_len;
    smith.bytes(buf[offset .. offset + h_len]);
    const h_slice = buf[offset .. offset + h_len];
    offset += h_len;
    smith.bytes(buf[offset .. offset + e_len]);
    const e_slice = buf[offset .. offset + e_len];
    offset += e_len;
    smith.bytes(buf[offset .. offset + d_len]);
    const d_slice = buf[offset .. offset + d_len];

    const g_opt: ?[]const u8 = if (have_g) g_slice else null;
    const h_opt: ?[]const u8 = if (have_h) h_slice else null;
    const e_opt: ?[]const u8 = if (have_e) e_slice else null;

    const r = config.resolvePrecedence(g_opt, h_opt, e_opt, d_slice);

    // Totality: value must be one of the inputs; source must match provenance.
    switch (r.source) {
        .gitstore => try testing.expect(have_g and g_slice.len != 0),
        .ghq => try testing.expect(have_h and h_slice.len != 0),
        .env => try testing.expect(have_e and e_slice.len != 0),
        .default => {
            // All earlier sources must be either null or empty.
            if (have_g) try testing.expect(g_slice.len == 0);
            if (have_h) try testing.expect(h_slice.len == 0);
            if (have_e) try testing.expect(e_slice.len == 0);
        },
    }
}

test "config: fuzz resolvePrecedence is total" {
    try std.testing.fuzz({}, fuzzResolvePrecedence, .{});
}

// =========================================================
// config: load — shells out to real `git config`, but each test uses a
// temporary config file through the config loader test seam so randomized
// test order cannot mutate or observe the user's real global config.
// =========================================================

fn tempGitConfigPath(gpa: Allocator, io: Io) ![]u8 {
    return uniqueTempFile(gpa, io, "/tmp/gitstore_config_test", ".gitconfig");
}

/// Run `git config --unset <key>` against a test-local config file.
fn gitUnsetFile(gpa: Allocator, io: Io, config_path: []const u8, key: []const u8) void {
    const r = ex.exec(gpa, io, &.{ "git", "config", "--file", config_path, "--unset-all", key }, null) catch return;
    gpa.free(r.stdout);
    gpa.free(r.stderr);
}

fn gitSetFile(gpa: Allocator, io: Io, config_path: []const u8, key: []const u8, value: []const u8) !void {
    const r = try ex.exec(gpa, io, &.{ "git", "config", "--file", config_path, key, value }, null);
    defer {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
    try testing.expect(r.succeeded());
}

test "config: load reads gitstore.root from real global git config" {
    const gpa = testing.allocator;
    const io = testing.io;

    const config_path = try tempGitConfigPath(gpa, io);
    defer gpa.free(config_path);
    defer Dir.cwd().deleteFile(io, config_path) catch {};

    try gitSetFile(gpa, io, config_path, "gitstore.root", "/gitstore_unit_test_sentinel_root");

    var env_map: std.process.Environ.Map = .init(gpa);
    defer env_map.deinit();
    // Intentionally do NOT set HOME so default path formula is distinct.
    try env_map.put("HOME", "/nonexistent_test_home");
    try env_map.put("GIT_CONFIG_GLOBAL", config_path);

    var cfg = try config.load(gpa, io, &env_map);
    defer cfg.deinit(gpa);

    try testing.expectEqualStrings("/gitstore_unit_test_sentinel_root", cfg.root);
    // gitstore.root is now a legacy fallback -> flags the deprecation signal.
    try testing.expect(cfg.used_legacy);
}

test "config: load falls back to ghq.root and flags legacy" {
    const gpa = testing.allocator;
    const io = testing.io;

    const config_path = try tempGitConfigPath(gpa, io);
    defer gpa.free(config_path);
    defer Dir.cwd().deleteFile(io, config_path) catch {};

    try gitSetFile(gpa, io, config_path, "ghq.root", "/ghq_legacy_test_sentinel_root");

    var env_map: std.process.Environ.Map = .init(gpa);
    defer env_map.deinit();
    try env_map.put("HOME", "/nonexistent_test_home");
    try env_map.put("GIT_CONFIG_GLOBAL", config_path);

    var cfg = try config.load(gpa, io, &env_map);
    defer cfg.deinit(gpa);

    try testing.expectEqualStrings("/ghq_legacy_test_sentinel_root", cfg.root);
    try testing.expect(cfg.used_legacy);
}

test "config: load uses env GITSTORE_ROOT when no git config set" {
    const gpa = testing.allocator;
    const io = testing.io;

    const config_path = try tempGitConfigPath(gpa, io);
    defer gpa.free(config_path);
    defer Dir.cwd().deleteFile(io, config_path) catch {};
    try Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = "" });

    var env_map: std.process.Environ.Map = .init(gpa);
    defer env_map.deinit();
    try env_map.put("HOME", "/nonexistent_test_home");
    try env_map.put("GIT_CONFIG_GLOBAL", config_path);
    try env_map.put("GITSTORE_ROOT", "/from/env/gitstore");

    var cfg = try config.load(gpa, io, &env_map);
    defer cfg.deinit(gpa);

    try testing.expectEqualStrings("/from/env/gitstore", cfg.root);
    // Legacy $GITSTORE_ROOT must flag the deprecation signal.
    try testing.expect(cfg.used_legacy);
}

test "config: load uses env Z3STORE_ROOT and does not flag legacy" {
    const gpa = testing.allocator;
    const io = testing.io;

    const config_path = try tempGitConfigPath(gpa, io);
    defer gpa.free(config_path);
    defer Dir.cwd().deleteFile(io, config_path) catch {};
    try Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = "" });

    var env_map: std.process.Environ.Map = .init(gpa);
    defer env_map.deinit();
    try env_map.put("HOME", "/nonexistent_test_home");
    try env_map.put("GIT_CONFIG_GLOBAL", config_path);
    // Both set: primary Z3STORE_ROOT must win over legacy GITSTORE_ROOT.
    try env_map.put("Z3STORE_ROOT", "/from/env/z3store");
    try env_map.put("GITSTORE_ROOT", "/from/env/gitstore");

    var cfg = try config.load(gpa, io, &env_map);
    defer cfg.deinit(gpa);

    try testing.expectEqualStrings("/from/env/z3store", cfg.root);
    try testing.expect(!cfg.used_legacy);
}

test "config: load prefers z3store.root over gitstore.root git config" {
    const gpa = testing.allocator;
    const io = testing.io;

    const config_path = try tempGitConfigPath(gpa, io);
    defer gpa.free(config_path);
    defer Dir.cwd().deleteFile(io, config_path) catch {};

    try gitSetFile(gpa, io, config_path, "z3store.root", "/z3store_primary_root");
    try gitSetFile(gpa, io, config_path, "gitstore.root", "/gitstore_legacy_root");

    var env_map: std.process.Environ.Map = .init(gpa);
    defer env_map.deinit();
    try env_map.put("HOME", "/nonexistent_test_home");
    try env_map.put("GIT_CONFIG_GLOBAL", config_path);

    var cfg = try config.load(gpa, io, &env_map);
    defer cfg.deinit(gpa);

    try testing.expectEqualStrings("/z3store_primary_root", cfg.root);
    try testing.expect(!cfg.used_legacy);
}

// =========================================================
// config: resolveRootForUrl honors a git urlmatch pattern
// =========================================================

test "config: resolveRootForUrl falls back to base.root when no pattern matches" {
    const gpa = testing.allocator;
    const io = testing.io;

    const sentinel_url = "https://gitstore-test.invalid/unused/sentinel";
    const config_path = try tempGitConfigPath(gpa, io);
    defer gpa.free(config_path);
    defer Dir.cwd().deleteFile(io, config_path) catch {};
    try Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = "" });

    var owned: std.ArrayList([]const u8) = .empty;
    defer owned.deinit(gpa);
    const base: config.Config = .{
        .root = "/fallback/root",
        .user = null,
        .default_host = "github.com",
        .complete_user = true,
        .adopt_on_clone = true,
        .jj_colocate = true,
        .used_legacy = false,
        .owned_strings = owned,
    };

    const unmatched = try config.resolveRootForUrlWithConfigFile(gpa, io, sentinel_url, base, config_path);
    defer gpa.free(unmatched);
    try testing.expectEqualStrings("/fallback/root", unmatched);
}

test "config: resolveRootForUrl prefers matching gitstore.<url>.root urlmatch" {
    const gpa = testing.allocator;
    const io = testing.io;

    const test_url = "https://gitstore-urlmatch-test.invalid/acme/widget";
    const pattern_key = "gitstore.https://gitstore-urlmatch-test.invalid/acme/.root";

    const config_path = try tempGitConfigPath(gpa, io);
    defer gpa.free(config_path);
    defer Dir.cwd().deleteFile(io, config_path) catch {};

    try gitSetFile(gpa, io, config_path, pattern_key, "/per-org/acme");

    var owned: std.ArrayList([]const u8) = .empty;
    defer owned.deinit(gpa);
    const base: config.Config = .{
        .root = "/fallback/root",
        .user = null,
        .default_host = "github.com",
        .complete_user = true,
        .adopt_on_clone = true,
        .jj_colocate = true,
        .used_legacy = false,
        .owned_strings = owned,
    };

    const matched = try config.resolveRootForUrlWithConfigFile(gpa, io, test_url, base, config_path);
    defer gpa.free(matched);
    try testing.expectEqualStrings("/per-org/acme", matched);
}

// =========================================================
// list-walker / cache modules — pull in their module-local
// tests so `zig build test-integration` also covers them.
// =========================================================

comptime {
    _ = @import("list.zig");
    _ = @import("cache.zig");
}

// =========================================================
// detach/adopt path-validation hardening (rounds 3-6)
// =========================================================
//
// These tests cover every `error.GitDirMalformed` branch in
// gitstore.detach() and gitstore.adopt(). They craft a fake
// adopted-repo on disk (a real `.git` pointer file with a
// chosen target) then invoke detach/adopt and assert the
// exact error. Without these tests the 6 rounds of CR
// hardening can be silently regressed by a future cleanup PR.
//
// Each test scopes its tmp dir under TestEnv.base so they
// run in parallel without cross-talk.

/// Helper: write a `gitdir: <target>\n` pointer file at <repo>/.git.
/// Creates the parent directory if needed.
fn writeGitPointer(env: *const TestEnv, repo: []const u8, gitdir_target: []const u8) !void {
    try Dir.cwd().createDirPath(env.io, repo);
    const git_path = try std.fmt.allocPrint(env.gpa, "{s}/.git", .{repo});
    defer env.gpa.free(git_path);
    const content = try std.fmt.allocPrint(env.gpa, "gitdir: {s}\n", .{gitdir_target});
    defer env.gpa.free(content);
    try Dir.cwd().writeFile(env.io, .{ .sub_path = git_path, .data = content });
}

test "detach rejects gitdir without /git suffix" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const repo = try std.fmt.allocPrint(gpa, "{s}/r", .{env.base});
    defer gpa.free(repo);

    // Target starts with gitstore_root (so isAdopted passes) but lacks /git suffix.
    const target = try std.fmt.allocPrint(gpa, "{s}/foo/notgit", .{env.gitstore_root});
    defer gpa.free(target);
    try writeGitPointer(&env, repo, target);

    const r = gitstore.detach(gpa, io, repo, env.ghq_root, env.gitstore_root, false, false);
    try testing.expectError(error.GitDirMalformed, r);
}

test "detach rejects gitdir with empty repo segment" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const repo = try std.fmt.allocPrint(gpa, "{s}/r", .{env.base});
    defer gpa.free(repo);

    // "<store>/git" → ends in /git but no <repo> segment between root and /git.
    const target = try std.fmt.allocPrint(gpa, "{s}/git", .{env.gitstore_root});
    defer gpa.free(target);
    try writeGitPointer(&env, repo, target);

    const r = gitstore.detach(gpa, io, repo, env.ghq_root, env.gitstore_root, false, false);
    try testing.expectError(error.GitDirMalformed, r);
}

test "detach refuses insecure gitstore_root '/'" {
    // The insecure-root rejection in detach is defense-in-depth that fires
    // AFTER isAdopted() has confirmed the repo is adopted. Constructing an
    // adopted repo whose canonical gitdir resolves under root="/" is not
    // possible from a unit test (would require writing under '/'). The
    // validation is still exercised end-to-end by the prefix-escape and
    // realpath canonicalization tests below; this case is gated by the
    // earlier NotAdopted return path. The adopt-side equivalent test below
    // covers the same insecure-root branch via a path that isAdopted does
    // not gate.
    return error.SkipZigTest;
}

test "detach rejects gitdir whose canonical form escapes gitstore_root" {
    // CR-minor follow-up (PR #6): the test name was previously "rejects
    // gitdir that escapes gitstore_root prefix", suggesting it exercised
    // the textual prefix-with-slash branch in detach(). It does not — and
    // cannot, in a unit test. The textual branch in detach() (root_norm
    // startsWith + boundary char check) is identical to the gate already
    // applied by isAdopted(); if isAdopted passes, the textual branch
    // also passes. The textual branch is defense-in-depth against a
    // TOCTOU where the .git pointer is swapped between the isAdopted
    // read and detach()'s second read. Exercising it requires fault
    // injection at file-read level, which is out of scope for unit tests.
    //
    // What this test DOES exercise (and is genuinely useful coverage):
    // the round-5 canonicalization branch. The constructed target lives
    // inside fake_root (so isAdopted passes via the textual path) but
    // the target directory is never created on disk, so detach()'s
    // realPathFile call returns FileNotFound → the canonicalization
    // branch returns GitDirMalformed. That is the user-visible contract
    // and is what we pin here.
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const fake_root = try std.fmt.allocPrint(gpa, "{s}/elsewhere", .{env.base});
    defer gpa.free(fake_root);
    try Dir.cwd().createDirPath(io, fake_root);

    const repo = try std.fmt.allocPrint(gpa, "{s}/r", .{env.base});
    defer gpa.free(repo);

    // Target inside fake_root → isAdopted(repo, fake_root) returns true.
    // Target dir does NOT exist → realPathFile fails → GitDirMalformed.
    const target = try std.fmt.allocPrint(gpa, "{s}/host/owner/repo/git", .{fake_root});
    defer gpa.free(target);
    try writeGitPointer(&env, repo, target);

    const r = gitstore.detach(gpa, io, repo, env.ghq_root, fake_root, false, false);
    try testing.expectError(error.GitDirMalformed, r);
}

test "detach rejects gitdir with '..' segment" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const repo = try std.fmt.allocPrint(gpa, "{s}/r", .{env.base});
    defer gpa.free(repo);

    const target = try std.fmt.allocPrint(gpa, "{s}/foo/../etc/git", .{env.gitstore_root});
    defer gpa.free(target);
    try writeGitPointer(&env, repo, target);

    const r = gitstore.detach(gpa, io, repo, env.ghq_root, env.gitstore_root, false, false);
    try testing.expectError(error.GitDirMalformed, r);
}

test "detach rejects gitdir with '.' segment" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const repo = try std.fmt.allocPrint(gpa, "{s}/r", .{env.base});
    defer gpa.free(repo);

    const target = try std.fmt.allocPrint(gpa, "{s}/foo/./bar/git", .{env.gitstore_root});
    defer gpa.free(target);
    try writeGitPointer(&env, repo, target);

    const r = gitstore.detach(gpa, io, repo, env.ghq_root, env.gitstore_root, false, false);
    try testing.expectError(error.GitDirMalformed, r);
}

test "detach rejects gitdir with empty segment (double slash)" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const repo = try std.fmt.allocPrint(gpa, "{s}/r", .{env.base});
    defer gpa.free(repo);

    const target = try std.fmt.allocPrint(gpa, "{s}//repo/git", .{env.gitstore_root});
    defer gpa.free(target);
    try writeGitPointer(&env, repo, target);

    const r = gitstore.detach(gpa, io, repo, env.ghq_root, env.gitstore_root, false, false);
    try testing.expectError(error.GitDirMalformed, r);
}

test "detach rejects symlink at repo_store_dir leaf (round-4/5 canonicalization)" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    // Build a real on-disk attack: <store>/host/owner/repo is a symlink
    // pointing to a directory OUTSIDE the canonical gitstore_root.
    const outside = try std.fmt.allocPrint(gpa, "{s}/outside_store", .{env.base});
    defer gpa.free(outside);
    try Dir.cwd().createDirPath(io, outside);

    const owner_dir = try std.fmt.allocPrint(gpa, "{s}/host/owner", .{env.gitstore_root});
    defer gpa.free(owner_dir);
    try Dir.cwd().createDirPath(io, owner_dir);

    const repo_store_link = try std.fmt.allocPrint(gpa, "{s}/repo", .{owner_dir});
    defer gpa.free(repo_store_link);
    try Dir.symLinkAbsolute(io, outside, repo_store_link, .{ .is_directory = true });

    // Now write a .git pointer that targets <store>/host/owner/repo/git.
    // The textual prefix check passes (starts with store, no .. or .),
    // but the realpath canonicalization resolves to outside_store/git
    // which escapes the canonical store root.
    const repo = try std.fmt.allocPrint(gpa, "{s}/work_repo", .{env.base});
    defer gpa.free(repo);
    const target = try std.fmt.allocPrint(gpa, "{s}/git", .{repo_store_link});
    defer gpa.free(target);
    try writeGitPointer(&env, repo, target);

    const r = gitstore.detach(gpa, io, repo, env.ghq_root, env.gitstore_root, false, false);
    try testing.expectError(error.GitDirMalformed, r);
}

test "detach rejects ancestor symlink (round-5 canonicalization)" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    // Ancestor attack: <store>/host is a symlink pointing OUTSIDE store.
    const outside = try std.fmt.allocPrint(gpa, "{s}/ancestor_outside", .{env.base});
    defer gpa.free(outside);
    try Dir.cwd().createDirPath(io, outside);
    // Pre-populate the would-be path so realPathFile resolves cleanly.
    const outside_owner_repo = try std.fmt.allocPrint(gpa, "{s}/owner/repo/git", .{outside});
    defer gpa.free(outside_owner_repo);
    try Dir.cwd().createDirPath(io, outside_owner_repo);

    const host_link = try std.fmt.allocPrint(gpa, "{s}/host", .{env.gitstore_root});
    defer gpa.free(host_link);
    try Dir.symLinkAbsolute(io, outside, host_link, .{ .is_directory = true });

    const repo = try std.fmt.allocPrint(gpa, "{s}/work_ancestor", .{env.base});
    defer gpa.free(repo);
    const target = try std.fmt.allocPrint(gpa, "{s}/host/owner/repo/git", .{env.gitstore_root});
    defer gpa.free(target);
    try writeGitPointer(&env, repo, target);

    const r = gitstore.detach(gpa, io, repo, env.ghq_root, env.gitstore_root, false, false);
    try testing.expectError(error.GitDirMalformed, r);
}

test "adopt refuses insecure gitstore_root '/'" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const repo = try env.createRepo("testorg", "adopt_insecure_root");
    defer gpa.free(repo);

    const r = gitstore.adopt(gpa, io, repo, env.ghq_root, "/", false);
    try testing.expectError(error.GitDirMalformed, r);
}

test "adopt rejects repo_path with '..' segment under storage path" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    // Construct a repo_path outside ghq_root so repoStoragePath uses the
    // absolute fallback (path[1..]). With "/foo/../etc" the relative
    // storage path is "foo/../etc" which contains "..".
    const r = gitstore.adopt(gpa, io, "/foo/../etc", env.ghq_root, env.gitstore_root, false);
    try testing.expectError(error.GitDirMalformed, r);
}

test "adopt rejects repo_path with empty segment under storage path" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    // "/foo//bar" → storage path "foo//bar" → empty middle segment.
    const r = gitstore.adopt(gpa, io, "/foo//bar", env.ghq_root, env.gitstore_root, false);
    try testing.expectError(error.GitDirMalformed, r);
}

test "adopt rejects repo_path with '.' segment under storage path" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const r = gitstore.adopt(gpa, io, "/foo/./bar", env.ghq_root, env.gitstore_root, false);
    try testing.expectError(error.GitDirMalformed, r);
}

test "adopt rejects symlinked root component before creating store path" {
    const io = testing.io;
    const gpa = testing.allocator;
    var env = try TestEnv.setup(gpa, io);
    defer env.teardown();

    const repo = try env.createRepo("testorg", "adopt_symlink_root");
    defer gpa.free(repo);

    const outside = try std.fmt.allocPrint(gpa, "{s}/outside_adopt_store", .{env.base});
    defer gpa.free(outside);
    try Dir.cwd().createDirPath(io, outside);

    const root_component = try std.fmt.allocPrint(gpa, "{s}/testorg", .{env.gitstore_root});
    defer gpa.free(root_component);
    try Dir.symLinkAbsolute(io, outside, root_component, .{ .is_directory = true });

    const r = gitstore.adopt(gpa, io, repo, env.ghq_root, env.gitstore_root, false);
    try testing.expectError(error.GitDirMalformed, r);

    const escaped_repo_dir = try std.fmt.allocPrint(gpa, "{s}/adopt_symlink_root", .{outside});
    defer gpa.free(escaped_repo_dir);
    try testing.expectError(error.FileNotFound, Dir.cwd().statFile(io, escaped_repo_dir, .{}));
}

// =========================================================
// G3 — CLI end-to-end tests: spawn the BUILT `gitstore` binary
// =========================================================
//
// These tests exercise the real argument dispatcher in src/main.zig by
// spawning the compiled executable in a child process and asserting its
// exit code and a substring of the chosen output stream. The binary path is
// baked in hermetically at build time:
//
//   build.zig:
//     integration_tests.step.dependOn(&exe.step);   // build gitstore first
//     e2e_opts.addOptionPath("zt_bin", exe.getEmittedBin());
//     integration_mod.addOptions("build_options", e2e_opts);
//
// `addOptionPath` takes the emitted-bin LazyPath and resolves it lazily inside
// the Options step's own make() (an eager getPath2() during graph construction
// panics with "misconfigured build script"), writing the absolute path into
// the generated `build_options` module where it surfaces as a `[]const u8`.
// `zt_bin` is therefore an absolute path to the just-built binary —
// no cwd-relative guessing, no reliance on the install prefix.
//
// stdout vs stderr routing (load-bearing, verified against main.zig):
//   * printUsage / printErr → File.stderr() — usage text + all error lines
//   * printOut              → File.stdout() — every `<cmd> --help` body
// So `--help` substrings are asserted in STDOUT; usage/error substrings in
// STDERR.
//
// Exit-code matrix (verified against every `return N` in main.zig):
//   * exit 0  — success, usage on no-args, all `--help`
//   * exit 1  — `filter <unexpected>` ONLY among bad-arg paths (main.zig:682)
//   * exit 2  — every other argument-rejection path
//   * != 0    — `migrate <path>` real-mode returns error.MigrationNotImplemented
//               (main.zig:1218), which the Zig runtime reports as a non-zero
//               process exit.
//
// Each test runs with a controlled environment (HOME + GIT_CONFIG_GLOBAL
// pointed at throwaway temp paths, plus the real PATH) so no test can touch
// the operator's real HOME, ghq config, or gitstore root.

const build_options = @import("build_options");

/// Which captured stream a substring assertion targets.
const Stream = enum { stdout, stderr };

/// Expected process termination for an e2e case.
const ExpectExit = union(enum) {
    /// Exact `Exited` code.
    code: u8,
    /// Any non-zero `Exited` code (used for the migrate real-mode error
    /// return, whose precise code is runtime-defined).
    nonzero,
};

const E2eCase = struct {
    argv_tail: []const []const u8,
    expect: ExpectExit,
    stream: Stream,
    needle: []const u8,
};

/// Build a controlled child environment. HOME and GIT_CONFIG_GLOBAL point at
/// the supplied throwaway paths; PATH is copied from the test environ so the
/// child can still resolve git/jj if a code path reaches an exec (the
/// argument-rejection cases return before any exec, but happy-path help does
/// not, and keeping PATH makes the harness reusable).
fn controlledEnv(
    gpa: Allocator,
    home: []const u8,
    git_config_global: []const u8,
) !std.process.Environ.Map {
    var map: std.process.Environ.Map = .init(gpa);
    errdefer map.deinit();
    try map.put("HOME", home);
    try map.put("GIT_CONFIG_GLOBAL", git_config_global);
    // Copy PATH from the portable testing environ view if present.
    var parent = try std.testing.environ.createMap(gpa);
    defer parent.deinit();
    if (parent.get("PATH")) |path| {
        try map.put("PATH", path);
    }
    return map;
}

/// Spawn the built gitstore binary with `argv_tail` and a controlled env,
/// then assert the expected exit code and that `needle` appears in the
/// selected stream. Uses std.process.run (the same high-level spawn API
/// exec.zig builds on) so pipe wiring and full-output capture are handled.
fn runE2eCase(gpa: Allocator, io: Io, case: E2eCase) !void {
    // Throwaway HOME dir + empty global gitconfig, unique per invocation so
    // parallel test execution cannot collide.
    const home = try uniqueTempDir(gpa, io, "/tmp/gitstore_e2e_home");
    defer {
        Dir.cwd().deleteTree(io, home) catch {};
        gpa.free(home);
    }
    const git_config = try uniqueTempFile(gpa, io, "/tmp/gitstore_e2e", ".gitconfig");
    defer {
        Dir.cwd().deleteFile(io, git_config) catch {};
        gpa.free(git_config);
    }

    // argv = [binary, tail...]
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, build_options.zt_bin);
    for (case.argv_tail) |a| try argv.append(gpa, a);

    // Space-joined tail for diagnostics. In Zig 0.16 `{s}` only formats a
    // single `[]const u8`, so a `[]const []const u8` must be joined first.
    const argv_desc = try std.mem.join(gpa, " ", case.argv_tail);
    defer gpa.free(argv_desc);

    var env_map = try controlledEnv(gpa, home, git_config);
    defer env_map.deinit();

    const result = try std.process.run(gpa, io, .{
        .argv = argv.items,
        .environ_map = &env_map,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    // Exit-code assertion.
    try testing.expect(result.term == .exited);
    switch (case.expect) {
        .code => |c| testing.expectEqual(c, result.term.exited) catch |err| {
            std.debug.print(
                "e2e argv={s} expected exit {d}, got {d}\nstdout=<<{s}>>\nstderr=<<{s}>>\n",
                .{ argv_desc, c, result.term.exited, result.stdout, result.stderr },
            );
            return err;
        },
        .nonzero => testing.expect(result.term.exited != 0) catch |err| {
            std.debug.print(
                "e2e argv={s} expected non-zero exit, got 0\nstdout=<<{s}>>\nstderr=<<{s}>>\n",
                .{ argv_desc, result.stdout, result.stderr },
            );
            return err;
        },
    }

    // Substring assertion on the selected stream (skip when needle is empty —
    // e.g. `--help` cases whose body content is not pinned, only exit code).
    if (case.needle.len > 0) {
        const haystack = switch (case.stream) {
            .stdout => result.stdout,
            .stderr => result.stderr,
        };
        testing.expect(std.mem.indexOf(u8, haystack, case.needle) != null) catch |err| {
            std.debug.print(
                "e2e argv={s} missing needle <<{s}>> in {s}\nstdout=<<{s}>>\nstderr=<<{s}>>\n",
                .{ argv_desc, case.needle, @tagName(case.stream), result.stdout, result.stderr },
            );
            return err;
        };
    }
}

// --- usage / global help (printUsage → stderr) ---

test "e2e (no args) prints usage to stderr, exit 0" {
    try runE2eCase(testing.allocator, testing.io, .{
        .argv_tail = &.{},
        .expect = .{ .code = 0 },
        .stream = .stderr,
        .needle = "Usage: zt",
    });
}

test "e2e --help prints usage to stderr, exit 0" {
    try runE2eCase(testing.allocator, testing.io, .{
        .argv_tail = &.{"--help"},
        .expect = .{ .code = 0 },
        .stream = .stderr,
        .needle = "Usage: zt",
    });
}

test "e2e -h prints usage to stderr, exit 0" {
    try runE2eCase(testing.allocator, testing.io, .{
        .argv_tail = &.{"-h"},
        .expect = .{ .code = 0 },
        .stream = .stderr,
        .needle = "Usage: zt",
    });
}

test "e2e unknown command exits 2 with error on stderr" {
    try runE2eCase(testing.allocator, testing.io, .{
        .argv_tail = &.{"frobnicator"},
        .expect = .{ .code = 2 },
        .stream = .stderr,
        .needle = "error: unknown command 'frobnicator'",
    });
}

// --- init ---

test "e2e init --unknown rejects unknown flag, exit 2" {
    try runE2eCase(testing.allocator, testing.io, .{
        .argv_tail = &.{ "init", "--unknown" },
        .expect = .{ .code = 2 },
        .stream = .stderr,
        .needle = "error: unknown flag for init: --unknown",
    });
}

test "e2e init with two paths rejects extra path, exit 2" {
    try runE2eCase(testing.allocator, testing.io, .{
        .argv_tail = &.{ "init", "/a", "/b" },
        .expect = .{ .code = 2 },
        .stream = .stderr,
        .needle = "error: init takes at most one path: /b",
    });
}

test "e2e init --help prints sub-help to stdout, exit 0" {
    try runE2eCase(testing.allocator, testing.io, .{
        .argv_tail = &.{ "init", "--help" },
        .expect = .{ .code = 0 },
        .stream = .stdout,
        .needle = "zt init",
    });
}

// --- hook (scan-all flag handling) ---

test "e2e hook with no shell flag errors, exit 2" {
    try runE2eCase(testing.allocator, testing.io, .{
        .argv_tail = &.{"hook"},
        .expect = .{ .code = 2 },
        .stream = .stderr,
        .needle = "error: hook requires --zsh, --bash, or --nu",
    });
}

test "e2e hook with conflicting shells errors, exit 2" {
    try runE2eCase(testing.allocator, testing.io, .{
        .argv_tail = &.{ "hook", "--zsh", "--bash" },
        .expect = .{ .code = 2 },
        .stream = .stderr,
        .needle = "error: hook accepts only one of --zsh/--bash/--nu",
    });
}

test "e2e hook --zsh --help surfaces help to stdout, exit 0" {
    // Scan-all: --help wins even after a valid shell flag (main.zig round-6).
    try runE2eCase(testing.allocator, testing.io, .{
        .argv_tail = &.{ "hook", "--zsh", "--help" },
        .expect = .{ .code = 0 },
        .stream = .stdout,
        .needle = "zt hook",
    });
}

// --- filter (exit-1 anomaly) ---

test "e2e filter unexpected arg exits 1 (NOT 2), error on stderr" {
    // Load-bearing: this is the ONLY bad-arg path that returns 1 (main.zig:682).
    try runE2eCase(testing.allocator, testing.io, .{
        .argv_tail = &.{ "filter", "unexpected" },
        .expect = .{ .code = 1 },
        .stream = .stderr,
        .needle = "error: unexpected argument: unexpected",
    });
}

test "e2e filter foo -h surfaces help to stdout, exit 0" {
    // Scan-all: -h anywhere wins over the otherwise-unexpected `foo`.
    try runE2eCase(testing.allocator, testing.io, .{
        .argv_tail = &.{ "filter", "foo", "-h" },
        .expect = .{ .code = 0 },
        .stream = .stdout,
        .needle = "",
    });
}

// --- get ---

test "e2e get with no url errors, exit 2" {
    try runE2eCase(testing.allocator, testing.io, .{
        .argv_tail = &.{"get"},
        .expect = .{ .code = 2 },
        .stream = .stderr,
        .needle = "error: get requires at least one <url>",
    });
}

test "e2e get -P with non-integer value errors, exit 2" {
    try runE2eCase(testing.allocator, testing.io, .{
        .argv_tail = &.{ "get", "-P", "foo", "https://example.com/o/r" },
        .expect = .{ .code = 2 },
        .stream = .stderr,
        .needle = "error: -P argument must be a positive integer",
    });
}

// --- create ---

test "e2e create --vcs with bad value errors, exit 2" {
    try runE2eCase(testing.allocator, testing.io, .{
        .argv_tail = &.{ "create", "--vcs", "hg", "owner/repo" },
        .expect = .{ .code = 2 },
        .stream = .stderr,
        .needle = "error: --vcs must be 'git' or 'jj'",
    });
}

// --- migrate (exit 2 on missing arg; non-zero error on real-mode) ---

test "e2e migrate with no new-root errors, exit 2" {
    try runE2eCase(testing.allocator, testing.io, .{
        .argv_tail = &.{"migrate"},
        .expect = .{ .code = 2 },
        .stream = .stderr,
        .needle = "error: migrate requires <new-root>",
    });
}

test "e2e migrate real-mode is unimplemented, non-zero exit with stderr" {
    // `migrate <path>` without --dry-run prints the not-implemented error and
    // returns error.MigrationNotImplemented (main.zig:1218); the Zig runtime
    // turns that into a non-zero process exit.
    try runE2eCase(testing.allocator, testing.io, .{
        .argv_tail = &.{ "migrate", "/tmp/gitstore_e2e_new_root" },
        .expect = .nonzero,
        .stream = .stderr,
        .needle = "real-mode not implemented",
    });
}

// =========================================================
// EpicGames Lore workspace recognition (e2e)
// =========================================================

const lore = @import("lore.zig");

const ZtOut = struct {
    exit: u8,
    stdout: []u8,
    stderr: []u8,
    fn deinit(self: *ZtOut, gpa: Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

/// Spawn the built `zt` with an absolute-path argument and a throwaway HOME.
/// Unlike `runE2eCase`, this returns the captured output so a test can assert
/// on both streams AND inspect on-disk state afterwards (the no-mutation
/// property for adopt-refusal).
fn spawnZt(gpa: Allocator, io: Io, argv_tail: []const []const u8) !ZtOut {
    const home = try uniqueTempDir(gpa, io, "/tmp/gitstore_lore_home");
    defer {
        Dir.cwd().deleteTree(io, home) catch {};
        gpa.free(home);
    }
    const git_config = try uniqueTempFile(gpa, io, "/tmp/gitstore_lore", ".gitconfig");
    defer {
        Dir.cwd().deleteFile(io, git_config) catch {};
        gpa.free(git_config);
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, build_options.zt_bin);
    for (argv_tail) |a| try argv.append(gpa, a);

    var env_map = try controlledEnv(gpa, home, git_config);
    defer env_map.deinit();

    const result = try std.process.run(gpa, io, .{
        .argv = argv.items,
        .environ_map = &env_map,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    errdefer gpa.free(result.stdout);
    errdefer gpa.free(result.stderr);
    try testing.expect(result.term == .exited);
    return .{ .exit = result.term.exited, .stdout = result.stdout, .stderr = result.stderr };
}

/// Create a Lore workspace fixture at a unique /tmp dir. When `config_body` is
/// non-null it is written to `.lore/config.toml`. Caller owns/deletes the dir.
fn makeLoreFixture(gpa: Allocator, io: Io, config_body: ?[]const u8) ![]u8 {
    const ws = try uniqueTempDir(gpa, io, "/tmp/gitstore_lore_ws");
    const lore_dir = try std.fmt.allocPrint(gpa, "{s}/.lore", .{ws});
    defer gpa.free(lore_dir);
    try Dir.cwd().createDirPath(io, lore_dir);
    const instance = try std.fmt.allocPrint(gpa, "{s}/instance", .{lore_dir});
    defer gpa.free(instance);
    try Dir.cwd().writeFile(io, .{ .sub_path = instance, .data = "0192f000-0000-7000-8000-000000000000\n" });
    if (config_body) |body| {
        const cfg = try std.fmt.allocPrint(gpa, "{s}/config.toml", .{lore_dir});
        defer gpa.free(cfg);
        try Dir.cwd().writeFile(io, .{ .sub_path = cfg, .data = body });
    }
    return ws;
}

test "e2e adopt refuses a lore-only workspace and mutates nothing" {
    const gpa = testing.allocator;
    const io = testing.io;
    const ws = try makeLoreFixture(gpa, io, null);
    defer {
        Dir.cwd().deleteTree(io, ws) catch {};
        gpa.free(ws);
    }

    var out = try spawnZt(gpa, io, &.{ "adopt", ws });
    defer out.deinit(gpa);

    try testing.expect(out.exit != 0);
    try testing.expect(std.mem.indexOf(u8, out.stderr, "Lore workspace") != null);
    try testing.expect(std.mem.indexOf(u8, out.stderr, "lore shared-store") != null);

    // No mutation: `.lore/instance` still present, no `.git` pointer created.
    try testing.expect(lore.detectLoreWorkspace(io, ws));
    const git_path = try std.fmt.allocPrint(gpa, "{s}/.git", .{ws});
    defer gpa.free(git_path);
    try testing.expectError(error.FileNotFound, Dir.cwd().statFile(io, git_path, .{}));
}

test "e2e lore subcommand reports missing shared-store config as unhealthy" {
    const gpa = testing.allocator;
    const io = testing.io;
    const ws = try makeLoreFixture(gpa, io,
        \\[shared_store_to_use]
        \\use_shared_store = true
        \\shared_store_path = "/nonexistent/shared/store"
        \\
    );
    defer {
        Dir.cwd().deleteTree(io, ws) catch {};
        gpa.free(ws);
    }

    var out = try spawnZt(gpa, io, &.{ "lore", ws });
    defer out.deinit(gpa);

    try testing.expectEqual(@as(u8, 1), out.exit);
    try testing.expect(std.mem.indexOf(u8, out.stdout, "instance:") != null);
    try testing.expect(std.mem.indexOf(u8, out.stdout, "shared_store: enabled") != null);
    try testing.expect(std.mem.indexOf(u8, out.stdout, "MISSING") != null);
}

test "e2e lore subcommand rejects a non-lore path" {
    const gpa = testing.allocator;
    const io = testing.io;
    const dir = try uniqueTempDir(gpa, io, "/tmp/gitstore_lore_notlore");
    defer {
        Dir.cwd().deleteTree(io, dir) catch {};
        gpa.free(dir);
    }

    var out = try spawnZt(gpa, io, &.{ "lore", dir });
    defer out.deinit(gpa);

    try testing.expectEqual(@as(u8, 1), out.exit);
    try testing.expect(std.mem.indexOf(u8, out.stderr, "not a Lore workspace") != null);
}

test "e2e verify on a lore-only workspace reports metadata, exit 0" {
    const gpa = testing.allocator;
    const io = testing.io;
    const ws = try makeLoreFixture(gpa, io,
        \\[shared_store_to_use]
        \\use_shared_store = false
        \\
    );
    defer {
        Dir.cwd().deleteTree(io, ws) catch {};
        gpa.free(ws);
    }

    var out = try spawnZt(gpa, io, &.{ "verify", ws });
    defer out.deinit(gpa);

    try testing.expectEqual(@as(u8, 0), out.exit);
    try testing.expect(std.mem.indexOf(u8, out.stdout, "instance:") != null);
    try testing.expect(std.mem.indexOf(u8, out.stdout, "shared_store: not configured") != null);
}

test "e2e verify fails when lore shared store is enabled without a path" {
    const gpa = testing.allocator;
    const io = testing.io;
    const ws = try makeLoreFixture(gpa, io,
        \\[shared_store_to_use]
        \\use_shared_store = true
        \\
    );
    defer {
        Dir.cwd().deleteTree(io, ws) catch {};
        gpa.free(ws);
    }

    var out = try spawnZt(gpa, io, &.{ "verify", ws });
    defer out.deinit(gpa);

    try testing.expectEqual(@as(u8, 1), out.exit);
    try testing.expect(std.mem.indexOf(u8, out.stdout, "shared_store: enabled but no shared_store_path set") != null);
}

test "e2e lore subcommand help prints to stdout, exit 0" {
    try runE2eCase(testing.allocator, testing.io, .{
        .argv_tail = &.{ "lore", "--help" },
        .expect = .{ .code = 0 },
        .stream = .stdout,
        .needle = "zt lore",
    });
}
