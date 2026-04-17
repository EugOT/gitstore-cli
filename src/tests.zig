/// Comprehensive integration and end-to-end tests for gitstore.
/// Tests use a temporary directory tree to avoid touching real repos.
const std = @import("std");
const testing = std.testing;
const Dir = std.Io.Dir;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const gitstore = @import("gitstore.zig");
const ex = @import("exec.zig");
const oplog = @import("log.zig");
const hooks = @import("hooks.zig");

// Pull in tests from all modules
comptime {
    _ = @import("exec.zig");
    _ = @import("log.zig");
    _ = @import("hooks.zig");
}

// ===== Test helpers =====

/// Suppress stdout output from gitstore functions during tests
/// to prevent interleaving with the test runner.
fn suppressOutput() void {
    gitstore.quiet = true;
}

fn restoreOutput() void {
    gitstore.quiet = false;
}

const TestEnv = struct {
    base: []const u8,
    ghq_root: []const u8,
    gitstore_root: []const u8,
    gpa: Allocator,
    io: Io,

    fn setup(gpa: Allocator, io: Io) !TestEnv {
        suppressOutput();

        const base = "/tmp/gitstore_test_env";
        const ghq = "/tmp/gitstore_test_env/ghq";
        const store = "/tmp/gitstore_test_env/gitstore";

        Dir.cwd().deleteTree(io, base) catch {};

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
        restoreOutput();
    }

    /// Create a git repo at ghq_root/org/name with an initial commit.
    fn createRepo(self: *const TestEnv, org: []const u8, name: []const u8) ![]u8 {
        const repo_path = try std.fmt.allocPrint(self.gpa, "{s}/{s}/{s}", .{ self.ghq_root, org, name });
        try Dir.cwd().createDirPath(self.io, repo_path);

        // git init + configure user + initial commit
        const r1 = try ex.exec(self.gpa, self.io, &.{ "git", "init" }, repo_path);
        self.gpa.free(r1.stdout);
        self.gpa.free(r1.stderr);

        const r1b = try ex.exec(self.gpa, self.io, &.{ "git", "config", "user.email", "test@test.com" }, repo_path);
        self.gpa.free(r1b.stdout);
        self.gpa.free(r1b.stderr);

        const r1c = try ex.exec(self.gpa, self.io, &.{ "git", "config", "user.name", "Test" }, repo_path);
        self.gpa.free(r1c.stdout);
        self.gpa.free(r1c.stderr);

        const r2 = try ex.exec(self.gpa, self.io, &.{ "git", "commit", "--no-verify", "--allow-empty", "-m", "init" }, repo_path);
        self.gpa.free(r2.stdout);
        self.gpa.free(r2.stderr);

        return repo_path;
    }

    /// Create a git+jj colocated repo.
    fn createJjRepo(self: *const TestEnv, org: []const u8, name: []const u8) ![]u8 {
        const repo_path = try self.createRepo(org, name);

        const r = try ex.exec(self.gpa, self.io, &.{ "jj", "git", "init", "--colocate" }, repo_path);
        self.gpa.free(r.stdout);
        self.gpa.free(r.stderr);

        return repo_path;
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
    const repo = "/tmp/gitstore_test_outside/myproject";
    Dir.cwd().deleteTree(io, "/tmp/gitstore_test_outside") catch {};
    defer Dir.cwd().deleteTree(io, "/tmp/gitstore_test_outside") catch {};
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
    const expected = try std.fmt.allocPrint(gpa, "{s}/tmp/gitstore_test_outside/myproject/git", .{env.gitstore_root});
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
    const wt_dir = "/tmp/gitstore_test_env/wt-feature";
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

    // gitstore entry removed
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

    const wt_dir = "/tmp/gitstore_test_env/wt-detach";
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
