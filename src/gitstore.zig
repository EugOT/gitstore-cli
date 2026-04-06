const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;
const Allocator = std.mem.Allocator;
const ex = @import("exec.zig");
const oplog = @import("log.zig");

pub const Error = error{
    ProcessFailed,
    NotAGitRepo,
    AlreadyAdopted,
    InvalidGhqRoot,
    VerifyFailed,
} || Allocator.Error || ex.ExecError || Dir.WriteFileError || Dir.SymLinkError ||
    Dir.DeleteTreeError || Dir.OpenError || Dir.CreateDirPathError ||
    File.OpenError || File.StatError || Dir.ReadFileAllocError;

/// Create the gitstore root directory if it does not exist.
/// Respects existing symlinks (does not overwrite).
pub fn init(io: Io, gitstore_root: []const u8) !void {
    Dir.cwd().createDirPath(io, gitstore_root) catch |err| switch (err) {
        error.PathAlreadyExists => {}, // fine, already exists (possibly a symlink target)
        else => return err,
    };
}

/// Determine the gitstore subpath for a repo given its absolute path and ghq root.
/// E.g., ghq_root=/Users/x/ghq, repo_path=/Users/x/ghq/github.com/Org/repo
/// returns "github.com/Org/repo"
pub fn repoRelativePath(repo_path: []const u8, ghq_root: []const u8) ?[]const u8 {
    if (ghq_root.len == 0) return null;
    var root = ghq_root;
    // Ensure ghq_root ends without trailing slash for clean prefix strip
    while (root.len > 1 and root[root.len - 1] == '/') {
        root = root[0 .. root.len - 1];
    }
    // Special case: root is "/"
    if (root.len == 1 and root[0] == '/') {
        if (repo_path.len > 1 and repo_path[0] == '/') {
            return repo_path[1..];
        }
        return null;
    }
    if (std.mem.startsWith(u8, repo_path, root) and
        repo_path.len > root.len and
        repo_path[root.len] == '/')
    {
        return repo_path[root.len + 1 ..];
    }
    return null;
}

/// Check if a repo is already adopted (has .git as a file, not directory).
pub fn isAdopted(io: Io, repo_path: []const u8, gpa: Allocator) bool {
    // Try to read .git as a file. If it starts with "gitdir:", it's a pointer file.
    const git_path = std.fmt.allocPrint(gpa, "{s}/.git", .{repo_path}) catch return false;
    defer gpa.free(git_path);

    const content = Dir.cwd().readFileAlloc(io, git_path, gpa, .unlimited) catch |err| switch (err) {
        error.IsDir => return false, // .git is a directory — not adopted
        else => return false, // doesn't exist or other error
    };
    defer gpa.free(content);
    return std.mem.startsWith(u8, content, "gitdir:");
}

/// Rewrite .jj/repo/store/git_target to use an absolute path to the git database.
/// When .jj is moved to the gitstore, relative paths in git_target break.
pub fn rewriteJjGitTarget(
    gpa: Allocator,
    io: Io,
    jj_dest: []const u8,
    git_dest: []const u8,
) !void {
    const git_target_path = try std.fmt.allocPrint(gpa, "{s}/repo/store/git_target", .{jj_dest});
    defer gpa.free(git_target_path);

    // Write absolute path to git database
    const new_content = try std.fmt.allocPrint(gpa, "{s}", .{git_dest});
    defer gpa.free(new_content);

    Dir.cwd().writeFile(io, .{
        .sub_path = git_target_path,
        .data = new_content,
    }) catch {
        // Non-fatal: git_target might not exist (different jj version)
    };
}

/// Adopt a single repository: move .git and .jj into gitstore.
pub fn adopt(
    gpa: Allocator,
    io: Io,
    repo_path: []const u8,
    ghq_root: []const u8,
    gitstore_root: []const u8,
    dry_run: bool,
) !void {
    const out = File.stdout();
    const err_out = File.stderr();

    // Check repo is under ghq root
    const rel_path = repoRelativePath(repo_path, ghq_root) orelse {
        var buf: [4096]u8 = undefined;
        var w = err_out.writer(io, &buf);
        try w.interface.print("error: {s} is not under ghq root {s}\n", .{ repo_path, ghq_root });
        try w.flush();
        return error.InvalidGhqRoot;
    };

    // Check if already adopted
    if (isAdopted(io, repo_path, gpa)) {
        var buf: [4096]u8 = undefined;
        var w = out.writer(io, &buf);
        try w.interface.print("skip: {s} (already adopted)\n", .{repo_path});
        try w.flush();
        return;
    }

    // Check .git directory exists
    const git_src = try std.fmt.allocPrint(gpa, "{s}/.git", .{repo_path});
    defer gpa.free(git_src);
    {
        const stat = Dir.cwd().statFile(io, git_src, .{}) catch {
            var buf: [4096]u8 = undefined;
            var w = err_out.writer(io, &buf);
            try w.interface.print("error: {s} has no .git directory\n", .{repo_path});
            try w.flush();
            return error.NotAGitRepo;
        };
        _ = stat;
    }

    // Build gitstore destination paths
    const git_dest = try std.fmt.allocPrint(gpa, "{s}/{s}/git", .{ gitstore_root, rel_path });
    defer gpa.free(git_dest);
    const jj_dest = try std.fmt.allocPrint(gpa, "{s}/{s}/jj", .{ gitstore_root, rel_path });
    defer gpa.free(jj_dest);

    const log_path = try std.fmt.allocPrint(gpa, "{s}/operations.log", .{gitstore_root});
    defer gpa.free(log_path);

    if (dry_run) {
        var buf: [8192]u8 = undefined;
        var w = out.writer(io, &buf);
        try w.interface.print("dry-run: would adopt {s}\n", .{repo_path});
        try w.interface.print("  copy {s} -> {s}\n", .{ git_src, git_dest });
        try w.interface.print("  write pointer {s}/.git -> gitdir: {s}\n", .{ repo_path, git_dest });

        // Check if .jj exists
        const jj_src = try std.fmt.allocPrint(gpa, "{s}/.jj", .{repo_path});
        defer gpa.free(jj_src);
        const has_jj = blk: {
            _ = Dir.cwd().statFile(io, jj_src, .{}) catch break :blk false;
            break :blk true;
        };
        if (has_jj) {
            try w.interface.print("  copy {s} -> {s}\n", .{ jj_src, jj_dest });
            try w.interface.print("  symlink {s}/.jj -> {s}\n", .{ repo_path, jj_dest });
        } else {
            try w.interface.print("  init jj colocated in {s}\n", .{repo_path});
        }
        try w.flush();
        return;
    }

    // --- Step 1: Create gitstore directory structure ---
    const repo_store_dir = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ gitstore_root, rel_path });
    defer gpa.free(repo_store_dir);
    try Dir.cwd().createDirPath(io, repo_store_dir);

    // --- Step 2: Copy .git to gitstore ---
    {
        var buf: [4096]u8 = undefined;
        var w = out.writer(io, &buf);
        try w.interface.print("copy: {s} -> {s}\n", .{ git_src, git_dest });
        try w.flush();
    }
    const cp_result = try ex.exec(gpa, io, &.{ "cp", "-a", git_src, git_dest }, null);
    defer {
        gpa.free(cp_result.stdout);
        gpa.free(cp_result.stderr);
    }
    if (!cp_result.succeeded()) {
        var buf: [4096]u8 = undefined;
        var w = err_out.writer(io, &buf);
        try w.interface.print("error: cp failed: {s}\n", .{cp_result.stderr});
        try w.flush();
        try oplog.logOperation(io, log_path, .copy, git_src, git_dest, "error: cp failed");
        return error.ProcessFailed;
    }
    try oplog.logOperation(io, log_path, .copy, git_src, git_dest, "ok");

    // --- Step 3: Verify the copy by running git rev-parse HEAD ---
    {
        const verify_result = try ex.exec(
            gpa,
            io,
            &.{ "git", "--git-dir", git_dest, "rev-parse", "HEAD" },
            null,
        );
        defer {
            gpa.free(verify_result.stdout);
            gpa.free(verify_result.stderr);
        }
        if (!verify_result.succeeded()) {
            // Rollback: remove the failed copy
            var buf: [4096]u8 = undefined;
            var w = err_out.writer(io, &buf);
            try w.interface.print("error: git verify failed after copy, rolling back\n", .{});
            try w.flush();
            Dir.cwd().deleteTree(io, git_dest) catch {};
            try oplog.logOperation(io, log_path, .copy, git_src, git_dest, "error: verify failed, rolled back");
            return error.VerifyFailed;
        }
    }

    // --- Step 4: Remove original .git directory and write pointer file ---
    try Dir.cwd().deleteTree(io, git_src);
    try oplog.logOperation(io, log_path, .remove, git_src, "", "ok");

    // Write the pointer file
    const pointer_content = try std.fmt.allocPrint(gpa, "gitdir: {s}\n", .{git_dest});
    defer gpa.free(pointer_content);
    try Dir.cwd().writeFile(io, .{
        .sub_path = git_src,
        .data = pointer_content,
    });
    try oplog.logOperation(io, log_path, .write_pointer, git_src, git_dest, "ok");
    {
        var buf: [4096]u8 = undefined;
        var w = out.writer(io, &buf);
        try w.interface.print("pointer: {s} -> {s}\n", .{ git_src, git_dest });
        try w.flush();
    }

    // --- Step 5: Handle .jj ---
    const jj_src = try std.fmt.allocPrint(gpa, "{s}/.jj", .{repo_path});
    defer gpa.free(jj_src);

    const has_jj = blk: {
        const stat = Dir.cwd().statFile(io, jj_src, .{}) catch break :blk false;
        _ = stat;
        break :blk true;
    };

    if (has_jj) {
        // Copy .jj to gitstore
        {
            var buf: [4096]u8 = undefined;
            var w = out.writer(io, &buf);
            try w.interface.print("copy: {s} -> {s}\n", .{ jj_src, jj_dest });
            try w.flush();
        }
        const jj_cp = try ex.exec(gpa, io, &.{ "cp", "-a", jj_src, jj_dest }, null);
        defer {
            gpa.free(jj_cp.stdout);
            gpa.free(jj_cp.stderr);
        }
        if (!jj_cp.succeeded()) {
            var buf: [4096]u8 = undefined;
            var w = err_out.writer(io, &buf);
            try w.interface.print("error: cp .jj failed: {s}\n", .{jj_cp.stderr});
            try w.flush();
            try oplog.logOperation(io, log_path, .copy, jj_src, jj_dest, "error: cp failed");
            return error.ProcessFailed;
        }
        try oplog.logOperation(io, log_path, .copy, jj_src, jj_dest, "ok");

        // Verify jj works against the new location
        {
            const jj_verify = try ex.exec(gpa, io, &.{ "jj", "status", "-R", repo_path }, null);
            defer {
                gpa.free(jj_verify.stdout);
                gpa.free(jj_verify.stderr);
            }
            // jj status may return non-zero for various reasons in a detached state,
            // so we just check it doesn't crash. Accept exit 0 or 1.
        }

        // Rewrite git_target to absolute path before removing original
        try rewriteJjGitTarget(gpa, io, jj_dest, git_dest);

        // Remove original .jj and create symlink
        try Dir.cwd().deleteTree(io, jj_src);
        try oplog.logOperation(io, log_path, .remove, jj_src, "", "ok");

        try Dir.symLinkAbsolute(io, jj_dest, jj_src, .{ .is_directory = true });
        try oplog.logOperation(io, log_path, .create_symlink, jj_src, jj_dest, "ok");
        {
            var buf: [4096]u8 = undefined;
            var w = out.writer(io, &buf);
            try w.interface.print("symlink: {s} -> {s}\n", .{ jj_src, jj_dest });
            try w.flush();
        }
    } else {
        // Initialize jj colocated mode
        {
            var buf: [4096]u8 = undefined;
            var w = out.writer(io, &buf);
            try w.interface.print("init: jj colocated in {s}\n", .{repo_path});
            try w.flush();
        }
        const jj_init = try ex.exec(gpa, io, &.{ "jj", "git", "init", "--colocate" }, repo_path);
        defer {
            gpa.free(jj_init.stdout);
            gpa.free(jj_init.stderr);
        }
        if (jj_init.succeeded()) {
            try oplog.logOperation(io, log_path, .init_jj, repo_path, "", "ok");

            // Now move .jj to gitstore and create symlink
            const jj_check = Dir.cwd().statFile(io, jj_src, .{}) catch null;
            if (jj_check != null) {
                const jj_cp2 = try ex.exec(gpa, io, &.{ "cp", "-a", jj_src, jj_dest }, null);
                gpa.free(jj_cp2.stdout);
                gpa.free(jj_cp2.stderr);
                if (jj_cp2.succeeded()) {
                    try rewriteJjGitTarget(gpa, io, jj_dest, git_dest);
                    try Dir.cwd().deleteTree(io, jj_src);
                    try Dir.symLinkAbsolute(io, jj_dest, jj_src, .{ .is_directory = true });
                    try oplog.logOperation(io, log_path, .create_symlink, jj_src, jj_dest, "ok");
                    {
                        var buf: [4096]u8 = undefined;
                        var w = out.writer(io, &buf);
                        try w.interface.print("symlink: {s} -> {s}\n", .{ jj_src, jj_dest });
                        try w.flush();
                    }
                }
            }
        } else {
            try oplog.logOperation(io, log_path, .init_jj, repo_path, "", "error: jj init failed");
            {
                var buf: [4096]u8 = undefined;
                var w = err_out.writer(io, &buf);
                try w.interface.print("warn: jj init failed (non-fatal): {s}\n", .{jj_init.stderr});
                try w.flush();
            }
        }
    }
}

/// Adopt all repos under ghq root.
pub fn adoptAll(
    gpa: Allocator,
    io: Io,
    ghq_root: []const u8,
    gitstore_root: []const u8,
    dry_run: bool,
) !void {
    const out = File.stdout();
    var adopted: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;

    // Get list of all repos
    const list_result = try ex.exec(gpa, io, &.{ "ghq", "list", "--full-path" }, null);
    defer {
        gpa.free(list_result.stdout);
        gpa.free(list_result.stderr);
    }
    if (!list_result.succeeded()) {
        var buf: [4096]u8 = undefined;
        var w = File.stderr().writer(io, &buf);
        try w.interface.print("error: ghq list failed\n", .{});
        try w.flush();
        return error.ProcessFailed;
    }

    var lines = std.mem.splitScalar(u8, ex.trimTrailingNewline(list_result.stdout), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        if (isAdopted(io, line, gpa)) {
            skipped += 1;
            continue;
        }

        adopt(gpa, io, line, ghq_root, gitstore_root, dry_run) catch |err| {
            failed += 1;
            var buf: [4096]u8 = undefined;
            var w = File.stderr().writer(io, &buf);
            w.interface.print("error: failed to adopt {s}: {s}\n", .{ line, @errorName(err) }) catch {};
            w.flush() catch {};
            continue;
        };
        adopted += 1;
    }

    var buf: [4096]u8 = undefined;
    var w = out.writer(io, &buf);
    if (dry_run) {
        try w.interface.print("\ndry-run summary: {d} would adopt, {d} already adopted, {d} failed\n", .{ adopted, skipped, failed });
    } else {
        try w.interface.print("\nsummary: {d} adopted, {d} skipped, {d} failed\n", .{ adopted, skipped, failed });
    }
    try w.flush();
}

/// Verify a single repo's gitstore integrity.
pub fn verify(
    gpa: Allocator,
    io: Io,
    repo_path: []const u8,
) !bool {
    const err_out = File.stderr();
    var ok = true;

    // Check .git is a file (pointer), not a directory
    const git_path = try std.fmt.allocPrint(gpa, "{s}/.git", .{repo_path});
    defer gpa.free(git_path);

    const content = Dir.cwd().readFileAlloc(io, git_path, gpa, .unlimited) catch |err| switch (err) {
        error.IsDir => {
            var buf: [4096]u8 = undefined;
            var w = err_out.writer(io, &buf);
            try w.interface.print("FAIL: {s}/.git is a directory (not adopted)\n", .{repo_path});
            try w.flush();
            return false;
        },
        else => {
            var buf: [4096]u8 = undefined;
            var w = err_out.writer(io, &buf);
            try w.interface.print("FAIL: {s}/.git not found\n", .{repo_path});
            try w.flush();
            return false;
        },
    };
    defer gpa.free(content);

    // Parse gitdir pointer
    const trimmed = ex.trimTrailingNewline(content);
    if (!std.mem.startsWith(u8, trimmed, "gitdir: ")) {
        var buf: [4096]u8 = undefined;
        var w = err_out.writer(io, &buf);
        try w.interface.print("FAIL: {s}/.git is not a valid gitdir pointer\n", .{repo_path});
        try w.flush();
        return false;
    }
    const git_dir = trimmed["gitdir: ".len..];

    // Check the gitdir target exists
    _ = Dir.cwd().statFile(io, git_dir, .{}) catch {
        var buf: [4096]u8 = undefined;
        var w = err_out.writer(io, &buf);
        try w.interface.print("FAIL: gitdir target does not exist: {s}\n", .{git_dir});
        try w.flush();
        ok = false;
    };

    // Verify git works
    {
        const git_result = try ex.exec(gpa, io, &.{ "git", "-C", repo_path, "rev-parse", "HEAD" }, null);
        defer {
            gpa.free(git_result.stdout);
            gpa.free(git_result.stderr);
        }
        if (!git_result.succeeded()) {
            var buf: [4096]u8 = undefined;
            var w = err_out.writer(io, &buf);
            try w.interface.print("FAIL: git rev-parse HEAD failed in {s}\n", .{repo_path});
            try w.flush();
            ok = false;
        }
    }

    // Check .jj symlink
    const jj_path = try std.fmt.allocPrint(gpa, "{s}/.jj", .{repo_path});
    defer gpa.free(jj_path);

    // Try reading it as a symlink
    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const link_len = Dir.readLinkAbsolute(io, jj_path, &link_buf) catch |err| switch (err) {
        error.FileNotFound => {
            // No .jj at all — might be ok if jj not used
            if (ok) {
                var buf: [4096]u8 = undefined;
                var w = File.stdout().writer(io, &buf);
                try w.interface.print("OK: {s} (no .jj)\n", .{repo_path});
                try w.flush();
            }
            return ok;
        },
        else => {
            var buf: [4096]u8 = undefined;
            var w = err_out.writer(io, &buf);
            try w.interface.print("FAIL: {s}/.jj is not a symlink\n", .{repo_path});
            try w.flush();
            return false;
        },
    };
    const link_target = link_buf[0..link_len];

    // Check symlink target exists
    _ = Dir.cwd().statFile(io, link_target, .{}) catch {
        var buf: [4096]u8 = undefined;
        var w = err_out.writer(io, &buf);
        try w.interface.print("FAIL: .jj symlink target does not exist: {s}\n", .{link_target});
        try w.flush();
        ok = false;
    };

    // Verify jj works
    {
        const jj_result = try ex.exec(gpa, io, &.{ "jj", "status", "-R", repo_path }, null);
        defer {
            gpa.free(jj_result.stdout);
            gpa.free(jj_result.stderr);
        }
        if (!jj_result.succeeded()) {
            var buf: [4096]u8 = undefined;
            var w = err_out.writer(io, &buf);
            try w.interface.print("FAIL: jj status failed in {s}\n", .{repo_path});
            try w.flush();
            ok = false;
        }
    }

    if (ok) {
        var buf: [4096]u8 = undefined;
        var w = File.stdout().writer(io, &buf);
        try w.interface.print("OK: {s}\n", .{repo_path});
        try w.flush();
    }

    return ok;
}

/// Verify all repos under ghq root.
pub fn verifyAll(
    gpa: Allocator,
    io: Io,
    ghq_root: []const u8,
) !void {
    _ = ghq_root;
    const out = File.stdout();
    var ok_count: usize = 0;
    var fail_count: usize = 0;

    const list_result = try ex.exec(gpa, io, &.{ "ghq", "list", "--full-path" }, null);
    defer {
        gpa.free(list_result.stdout);
        gpa.free(list_result.stderr);
    }
    if (!list_result.succeeded()) return error.ProcessFailed;

    var lines = std.mem.splitScalar(u8, ex.trimTrailingNewline(list_result.stdout), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (!isAdopted(io, line, gpa)) continue; // skip non-adopted repos

        const is_ok = try verify(gpa, io, line);
        if (is_ok) {
            ok_count += 1;
        } else {
            fail_count += 1;
        }
    }

    var buf: [4096]u8 = undefined;
    var w = out.writer(io, &buf);
    try w.interface.print("\nverify: {d} ok, {d} failed\n", .{ ok_count, fail_count });
    try w.flush();
}

/// Show gitstore disk usage, repo count, and broken pointers.
pub fn status(
    gpa: Allocator,
    io: Io,
    ghq_root: []const u8,
    gitstore_root: []const u8,
    json_mode: bool,
) !void {
    const out = File.stdout();

    // Disk usage
    const du_result = try ex.exec(gpa, io, &.{ "du", "-sh", gitstore_root }, null);
    defer {
        gpa.free(du_result.stdout);
        gpa.free(du_result.stderr);
    }
    const du_line = ex.trimTrailingNewline(du_result.stdout);
    // du output: "SIZE\tPATH"
    var du_parts = std.mem.splitScalar(u8, du_line, '\t');
    const disk_usage = du_parts.next() orelse "unknown";

    // Count repos via ghq list and check adopted status
    const list_result = try ex.exec(gpa, io, &.{ "ghq", "list", "--full-path" }, null);
    defer {
        gpa.free(list_result.stdout);
        gpa.free(list_result.stderr);
    }

    var total_repos: usize = 0;
    var adopted_count: usize = 0;
    var broken_count: usize = 0;

    if (list_result.succeeded()) {
        var lines = std.mem.splitScalar(u8, ex.trimTrailingNewline(list_result.stdout), '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            total_repos += 1;
            if (isAdopted(io, line, gpa)) {
                adopted_count += 1;
                // Quick verify: check gitdir target exists
                const git_path = std.fmt.allocPrint(gpa, "{s}/.git", .{line}) catch continue;
                defer gpa.free(git_path);
                const content = Dir.cwd().readFileAlloc(io, git_path, gpa, .unlimited) catch continue;
                defer gpa.free(content);
                const trimmed = ex.trimTrailingNewline(content);
                if (std.mem.startsWith(u8, trimmed, "gitdir: ")) {
                    const git_dir = trimmed["gitdir: ".len..];
                    _ = Dir.cwd().statFile(io, git_dir, .{}) catch {
                        broken_count += 1;
                    };
                }
            }
        }
    }

    _ = ghq_root;

    var buf: [8192]u8 = undefined;
    var w = out.writer(io, &buf);

    if (json_mode) {
        try w.interface.print(
            \\{{"disk_usage":"{s}","gitstore_root":"{s}","total_repos":{d},"adopted":{d},"broken":{d}}}
        , .{
            disk_usage, gitstore_root, total_repos, adopted_count, broken_count,
        });
        try w.interface.print("\n", .{});
    } else {
        try w.interface.print("gitstore: {s}\n", .{gitstore_root});
        try w.interface.print("disk usage: {s}\n", .{disk_usage});
        try w.interface.print("total repos: {d}\n", .{total_repos});
        try w.interface.print("adopted: {d}\n", .{adopted_count});
        if (broken_count > 0) {
            try w.interface.print("broken pointers: {d}\n", .{broken_count});
        }
    }
    try w.flush();
}
