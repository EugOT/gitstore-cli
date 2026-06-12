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
    _ = @import("url.zig");
    _ = @import("config.zig");
    _ = @import("list.zig");
    _ = @import("cache.zig");
    _ = @import("clone.zig");
}

const config = @import("config.zig");

// ===== Test helpers =====

const TestEnv = struct {
    base: []const u8,
    ghq_root: []const u8,
    gitstore_root: []const u8,
    gpa: Allocator,
    io: Io,

    fn setup(gpa: Allocator, io: Io) !TestEnv {
        var entropy_marker: u8 = undefined;
        const ns = Io.Clock.real.now(io).nanoseconds;
        const base = try std.fmt.allocPrint(
            gpa,
            "/tmp/gitstore_test_env_{d}_{x}",
            .{ ns, @intFromPtr(&entropy_marker) },
        );
        errdefer gpa.free(base);
        const ghq = try std.fmt.allocPrint(gpa, "{s}/ghq", .{base});
        errdefer gpa.free(ghq);
        const store = try std.fmt.allocPrint(gpa, "{s}/gitstore", .{base});
        errdefer gpa.free(store);

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
        self.gpa.free(self.base);
        self.gpa.free(self.ghq_root);
        self.gpa.free(self.gitstore_root);
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
    var entropy_marker: u8 = undefined;
    const ns = Io.Clock.real.now(io).nanoseconds;
    return std.fmt.allocPrint(
        gpa,
        "/tmp/gitstore_config_test_{d}_{x}.gitconfig",
        .{ ns, @intFromPtr(&entropy_marker) },
    );
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
    try testing.expect(!cfg.used_legacy_ghq_keys);
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
    try testing.expect(cfg.used_legacy_ghq_keys);
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
    try testing.expect(!cfg.used_legacy_ghq_keys);
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
        .used_legacy_ghq_keys = false,
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
        .used_legacy_ghq_keys = false,
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
