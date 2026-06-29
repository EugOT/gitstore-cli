//! `gitstore get` clone orchestrator.
//!
//! Phase-1 module per `/Users/etretiakov/.claude/plans/libgitstore-v2.md`
//! (§ Concurrency model). Depends on `url.zig` (`RepoSpec.toStoragePath`)
//! and calls `gitstore.adopt` after a successful clone to relocate `.git`
//! into the gitstore layout.
//!
//! All I/O is parametric on `std.Io` — no `std.fs.cwd`, no direct
//! `std.posix.*`. Parallel clones use `std.Io.Group` + `std.Io.Semaphore`;
//! failures from individual clones are captured on the per-report struct
//! (no fail-fast) so one bad URL cannot kill sibling clones.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = std.Io.Dir;

const ex = @import("exec.zig");
const gitstore = @import("gitstore.zig");
const test_support = @import("test_support.zig");
const url = @import("url.zig");

/// Options threaded through `cloneOne` / `cloneMany`.
pub const CloneOptions = struct {
    /// `-u` / `--update-if-exists`: when the storage path already exists,
    /// run `git fetch --all --prune` in-place and report `.updated`.
    update_if_exists: bool = false,
    /// `-P N`: maximum concurrent clones. 0 or 1 means serial.
    parallelism: u32 = 1,
    /// `--no-adopt`: clone into storage path but do **not** relocate
    /// `.git` into gitstore layout.
    no_adopt: bool = false,
    /// `--shallow`: pass `--depth 1` to git.
    shallow: bool = false,
    /// `-b <name>`: check out a branch other than HEAD.
    branch: ?[]const u8 = null,
    /// `--recursive` (default) / `--no-recursive`: pass
    /// `--recursive` / `--no-recursive` to `git clone`.
    recursive: bool = true,
};

/// Per-URL outcome — retained across `cloneMany` for ordered reporting.
///
/// `url` and `storage_path` are heap-allocated by the caller's allocator
/// and freed by `freeReports`. `err` is heap-allocated only when non-null.
pub const CloneReport = struct {
    url: []const u8,
    storage_path: []const u8,
    status: Status,
    err: ?[]const u8,

    pub const Status = enum { cloned, updated, skipped_exists, failed };
};

fn freeReportFields(gpa: Allocator, report: CloneReport) void {
    if (report.url.len != 0) gpa.free(report.url);
    if (report.storage_path.len != 0) gpa.free(report.storage_path);
    if (report.err) |e| gpa.free(e);
}

/// Free every string inside each `CloneReport` and the outer slice.
pub fn freeReports(gpa: Allocator, reports: []CloneReport) void {
    for (reports) |r| {
        freeReportFields(gpa, r);
    }
    gpa.free(reports);
}

/// Errors cloneOne may return. `error.Canceled` is single-`l` per 0.16
/// upstream spelling and always propagates through `cloneMany`.
pub const CloneError = error{
    /// Requested op was canceled via `io` — propagate upward.
    Canceled,
} || Allocator.Error || ex.ExecError ||
    Dir.OpenError || Dir.StatFileError || Dir.CreateDirPathError ||
    gitstore.Error;

/// Clone a single repository into its canonical storage path.
///
/// Invariants:
/// * `spec` strings are **not** freed here — caller owns them.
/// * Returned report holds **owned** duplicates of `spec.orig_url` and
///   the computed storage path. Free via `freeReports` for batched
///   reports; for a single report, free `r.url`, `r.storage_path` and
///   `r.err` manually.
pub fn cloneOne(
    gpa: Allocator,
    io: Io,
    spec: url.RepoSpec,
    ghq_root: []const u8,
    gitstore_root: []const u8,
    opts: CloneOptions,
) anyerror!CloneReport {
    const storage_path = try spec.toStoragePath(gpa, ghq_root);
    errdefer gpa.free(storage_path);
    const url_dup = try gpa.dupe(u8, spec.orig_url);
    errdefer gpa.free(url_dup);

    // Probe storage_path.
    const exists = dirExists(io, storage_path);

    if (exists and opts.update_if_exists) {
        // In-place fetch. We pass `git -C <path>` so no chdir is needed.
        var fetch = try ex.exec(
            gpa,
            io,
            &.{ "git", "-C", storage_path, "fetch", "--all", "--prune" },
            null,
        );
        defer fetch.deinit(gpa);
        if (!fetch.succeeded()) {
            const msg = try std.fmt.allocPrint(
                gpa,
                "git fetch failed: {s}",
                .{ex.trimTrailingNewline(fetch.stderr)},
            );
            return .{
                .url = url_dup,
                .storage_path = storage_path,
                .status = .failed,
                .err = msg,
            };
        }
        return .{
            .url = url_dup,
            .storage_path = storage_path,
            .status = .updated,
            .err = null,
        };
    }

    if (exists) {
        return .{
            .url = url_dup,
            .storage_path = storage_path,
            .status = .skipped_exists,
            .err = null,
        };
    }

    // Ensure parent directory exists before `git clone` runs.
    if (parentOf(storage_path)) |parent| {
        Dir.cwd().createDirPath(io, parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                const msg = try std.fmt.allocPrint(
                    gpa,
                    "createDirPath({s}): {s}",
                    .{ parent, @errorName(err) },
                );
                return .{
                    .url = url_dup,
                    .storage_path = storage_path,
                    .status = .failed,
                    .err = msg,
                };
            },
        };
    }

    // Build argv dynamically.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "git");
    try argv.append(gpa, "clone");
    if (opts.shallow) {
        try argv.append(gpa, "--depth");
        try argv.append(gpa, "1");
    }
    if (opts.branch) |b| {
        try argv.append(gpa, "--branch");
        try argv.append(gpa, b);
    }
    if (opts.recursive) {
        try argv.append(gpa, "--recursive");
    } else {
        try argv.append(gpa, "--no-recursive");
    }
    // Preserve explicit clone inputs for identity-host clones. Short forms
    // still need a concrete URL, and forge host overrides still need to
    // rewrite the clone target (e.g. SourceCraft web host differs from its
    // git host).
    const clone_target = try cloneTarget(gpa, spec);
    defer gpa.free(clone_target);
    // Terminate option parsing before the URL so a crafted clone target
    // starting with "--" cannot be misinterpreted by `git clone` as an
    // option (e.g. --upload-pack=/path/to/evil). Round-5 hardening.
    try argv.append(gpa, "--");
    try argv.append(gpa, clone_target);
    try argv.append(gpa, storage_path);

    var clone_res = try ex.exec(gpa, io, argv.items, null);
    defer clone_res.deinit(gpa);
    if (!clone_res.succeeded()) {
        const msg = try std.fmt.allocPrint(
            gpa,
            "git clone failed: {s}",
            .{ex.trimTrailingNewline(clone_res.stderr)},
        );
        return .{
            .url = url_dup,
            .storage_path = storage_path,
            .status = .failed,
            .err = msg,
        };
    }

    // Post-clone: relocate .git into gitstore layout unless caller opted out.
    if (!opts.no_adopt) {
        gitstore.adopt(gpa, io, storage_path, ghq_root, gitstore_root, false) catch |err| {
            if (err == error.Canceled) return err;
            const msg = try std.fmt.allocPrint(
                gpa,
                "adopt failed: {s}",
                .{@errorName(err)},
            );
            // Clone succeeded but adoption failed — still useful to the
            // user on disk, so report as failed but do not purge.
            return .{
                .url = url_dup,
                .storage_path = storage_path,
                .status = .failed,
                .err = msg,
            };
        };
    }

    return .{
        .url = url_dup,
        .storage_path = storage_path,
        .status = .cloned,
        .err = null,
    };
}

/// Clone many repositories concurrently (bounded by `opts.parallelism`).
///
/// Returns an ordered slice of `CloneReport` aligned to `specs`. Caller
/// frees via `freeReports`. `error.Canceled` is the only error that
/// propagates — every other per-URL failure is captured on that URL's
/// report with `.failed`.
pub fn cloneMany(
    gpa: Allocator,
    io: Io,
    specs: []const url.RepoSpec,
    ghq_root: []const u8,
    gitstore_root: []const u8,
    opts: CloneOptions,
) anyerror![]CloneReport {
    const reports = try gpa.alloc(CloneReport, specs.len);
    // Seed each slot with an empty placeholder so early cancellation
    // never leaves uninitialized memory. `workerOne` replaces each slot
    // atomically before it returns.
    for (reports) |*r| r.* = .{
        .url = "",
        .storage_path = "",
        .status = .failed,
        .err = null,
    };
    errdefer freeReports(gpa, reports);

    const cap: u32 = if (opts.parallelism == 0) 1 else opts.parallelism;
    var limiter: Io.Semaphore = .{ .permits = cap };

    var group: Io.Group = .init;
    // If we return early (e.g. due to a Cancelable producer), cancel the
    // group so spawned tasks have a chance to unwind cleanly.
    errdefer group.cancel(io);

    // Allocate a worker context per spec so each async invocation has
    // stable storage for its arguments.
    const ctxs = try gpa.alloc(WorkerCtx, specs.len);
    defer gpa.free(ctxs);

    for (specs, 0..) |spec, idx| {
        ctxs[idx] = .{
            .gpa = gpa,
            .io = io,
            .spec = spec,
            .ghq_root = ghq_root,
            .gitstore_root = gitstore_root,
            .opts = opts,
            .out = &reports[idx],
            .limiter = &limiter,
        };
        group.async(io, workerOne, .{&ctxs[idx]});
    }

    // Await propagates the first observed cancellation; per-URL
    // non-cancel failures were already captured on the report.
    group.await(io) catch |err| switch (err) {
        error.Canceled => {
            return error.Canceled;
        },
    };

    return reports;
}

const WorkerCtx = struct {
    gpa: Allocator,
    io: Io,
    spec: url.RepoSpec,
    ghq_root: []const u8,
    gitstore_root: []const u8,
    opts: CloneOptions,
    out: *CloneReport,
    limiter: *Io.Semaphore,
};

fn workerOne(ctx: *WorkerCtx) Io.Cancelable!void {
    // Bound concurrency. If the wait is canceled, propagate immediately —
    // the slot already has a `.failed` placeholder.
    try ctx.limiter.wait(ctx.io);
    defer ctx.limiter.post(ctx.io);

    const result = cloneOne(
        ctx.gpa,
        ctx.io,
        ctx.spec,
        ctx.ghq_root,
        ctx.gitstore_root,
        ctx.opts,
    ) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => blk: {
            // Build a failure report that still carries the URL.
            const url_dup = ctx.gpa.dupe(u8, ctx.spec.orig_url) catch "";
            const msg = ctx.gpa.dupe(u8, @errorName(err)) catch null;
            break :blk CloneReport{
                .url = url_dup,
                .storage_path = "",
                .status = .failed,
                .err = msg,
            };
        },
    };

    // Replace the placeholder — freeing any empty strings we seeded.
    const old = ctx.out.*;
    // `old` strings were either produced by cloneOne on a prior attempt
    // (impossible — single-shot worker) or are the empty-string seeds we
    // wrote in cloneMany. Empty slices cannot be freed, so we only free
    // when non-empty.
    freeReportFields(ctx.gpa, old);

    ctx.out.* = result;
}

// =========================================================
// Helpers
// =========================================================

fn cloneTarget(gpa: Allocator, spec: url.RepoSpec) CloneError![]u8 {
    if (shouldPreserveExplicitCloneInput(spec)) {
        return gpa.dupe(u8, spec.orig_url);
    }
    return spec.cloneUrl(gpa);
}

fn shouldPreserveExplicitCloneInput(spec: url.RepoSpec) bool {
    if (!std.ascii.eqlIgnoreCase(url.cloneHost(spec.host), spec.host)) return false;
    return isExplicitCloneInput(spec.orig_url);
}

fn isExplicitCloneInput(input: []const u8) bool {
    const schemes = [_][]const u8{
        "https://",
        "http://",
        "ssh://",
        "git://",
        "file://",
    };
    for (schemes) |scheme| {
        if (std.mem.startsWith(u8, input, scheme)) return true;
    }
    return isScpLikeCloneInput(input);
}

fn isScpLikeCloneInput(input: []const u8) bool {
    const at_idx = std.mem.indexOfScalar(u8, input, '@') orelse return false;
    const colon_idx = std.mem.indexOfScalar(u8, input, ':') orelse return false;
    return colon_idx > at_idx and std.mem.indexOf(u8, input[0..colon_idx], "://") == null;
}

/// Return a slice of `path` ending at (but not including) the final `/`.
/// Returns null if there is no slash.
fn parentOf(path: []const u8) ?[]const u8 {
    var i = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '/') {
            if (i == 1) return path[0..1]; // root '/'
            return path[0 .. i - 1];
        }
    }
    return null;
}

/// True iff `path` refers to an existing directory or file.
fn dirExists(io: Io, path: []const u8) bool {
    _ = Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

// =========================================================
// Tests — every test prefixed "clone:" for filtering.
// =========================================================

const testing = std.testing;

test "clone: cloneTarget preserves explicit https identity URL" {
    const gpa = testing.allocator;
    var spec = try url.parse(gpa, "https://git.example.com/team/repo", .{});
    defer spec.deinit(gpa);

    const target = try cloneTarget(gpa, spec);
    defer gpa.free(target);

    try testing.expectEqualStrings("https://git.example.com/team/repo", target);
}

test "clone: cloneTarget preserves explicit scp-like identity URL" {
    const gpa = testing.allocator;
    var spec = try url.parse(gpa, "git@example.com:team/repo", .{});
    defer spec.deinit(gpa);

    const target = try cloneTarget(gpa, spec);
    defer gpa.free(target);

    try testing.expectEqualStrings("git@example.com:team/repo", target);
}

test "clone: cloneTarget preserves explicit userless ssh identity URL" {
    const gpa = testing.allocator;
    var spec = try url.parse(gpa, "ssh://example.internal/owner/repo", .{});
    defer spec.deinit(gpa);

    const target = try cloneTarget(gpa, spec);
    defer gpa.free(target);

    try testing.expectEqualStrings("ssh://example.internal/owner/repo", target);
}

test "clone: cloneTarget builds concrete URL for short input" {
    const gpa = testing.allocator;
    var spec = try url.parse(gpa, "github.com/owner/repo", .{});
    defer spec.deinit(gpa);

    const target = try cloneTarget(gpa, spec);
    defer gpa.free(target);

    try testing.expectEqualStrings("https://github.com/owner/repo.git", target);
}

test "clone: cloneTarget rewrites explicit sourcecraft URL" {
    const gpa = testing.allocator;
    var spec = try url.parse(gpa, "https://sourcecraft.dev/owner/repo", .{});
    defer spec.deinit(gpa);

    const target = try cloneTarget(gpa, spec);
    defer gpa.free(target);

    try testing.expectEqualStrings("https://git.sourcecraft.dev/owner/repo.git", target);
}

/// Initialize a bare git repo at `bare_path` with at least one commit.
/// Mirrors the seeded-repo helper in tests.zig but writes to any path.
fn makeLocalBareFixture(
    gpa: Allocator,
    io: Io,
    work_dir: []const u8,
    bare_path: []const u8,
) !void {
    try Dir.cwd().createDirPath(io, work_dir);

    // `git init` in working dir.
    var init_res = try ex.exec(gpa, io, &.{ "git", "init", "-q" }, work_dir);
    defer init_res.deinit(gpa);
    try testing.expect(init_res.succeeded());

    // Minimal identity for `git commit`.
    var e1 = try ex.exec(gpa, io, &.{ "git", "config", "user.email", "t@t.test" }, work_dir);
    e1.deinit(gpa);
    var e2 = try ex.exec(gpa, io, &.{ "git", "config", "user.name", "tester" }, work_dir);
    e2.deinit(gpa);
    var e3 = try ex.exec(gpa, io, &.{ "git", "config", "commit.gpgsign", "false" }, work_dir);
    e3.deinit(gpa);

    // Seed commit. `--no-verify` matches tests.zig — some developers have
    // a global `commit-msg` hook that rejects bare messages.
    var c = try ex.exec(
        gpa,
        io,
        &.{ "git", "commit", "--no-verify", "--allow-empty", "-m", "feat: seed", "-q" },
        work_dir,
    );
    defer c.deinit(gpa);
    try testing.expect(c.succeeded());

    // `git clone --bare <work_dir> <bare_path>` so `file://<bare_path>`
    // is a valid remote.
    var clone_bare = try ex.exec(
        gpa,
        io,
        &.{ "git", "clone", "--bare", "-q", work_dir, bare_path },
        null,
    );
    defer clone_bare.deinit(gpa);
    try testing.expect(clone_bare.succeeded());
}

test "clone: cloneOne clones from a file:// bare fixture" {
    const gpa = testing.allocator;
    const io = testing.io;

    const base = try test_support.uniqueTempDir(gpa, io, "clone_test_basic");
    defer gpa.free(base);
    defer Dir.cwd().deleteTree(io, base) catch |err| test_support.ignoreCleanupError("clone basic", err);
    const work = try std.fmt.allocPrint(gpa, "{s}/wk", .{base});
    defer gpa.free(work);
    const bare = try std.fmt.allocPrint(gpa, "{s}/bare.git", .{base});
    defer gpa.free(bare);
    const ghq_root = try std.fmt.allocPrint(gpa, "{s}/ghq", .{base});
    defer gpa.free(ghq_root);
    const store = try std.fmt.allocPrint(gpa, "{s}/store", .{base});
    defer gpa.free(store);
    try Dir.cwd().createDirPath(io, ghq_root);
    try Dir.cwd().createDirPath(io, store);

    try makeLocalBareFixture(gpa, io, work, bare);

    const input = try std.fmt.allocPrint(gpa, "file://{s}", .{bare});
    defer gpa.free(input);

    var spec = try url.parse(gpa, input, .{});
    defer spec.deinit(gpa);

    const report = try cloneOne(gpa, io, spec, ghq_root, store, .{
        .no_adopt = true, // keep .git in-tree for easy assertion
        .recursive = false,
    });
    // Release the `CloneReport` fields — they are heap-owned.
    defer {
        gpa.free(report.url);
        gpa.free(report.storage_path);
        if (report.err) |e| gpa.free(e);
    }

    try testing.expectEqual(CloneReport.Status.cloned, report.status);
    // `.git` should now live inside the storage path.
    const git_path = try std.fmt.allocPrint(gpa, "{s}/.git", .{report.storage_path});
    defer gpa.free(git_path);
    _ = try Dir.cwd().statFile(io, git_path, .{});
}

test "clone: cloneOne with update_if_exists refreshes an existing clone" {
    const gpa = testing.allocator;
    const io = testing.io;

    const base = try test_support.uniqueTempDir(gpa, io, "clone_test_update");
    defer gpa.free(base);
    defer Dir.cwd().deleteTree(io, base) catch |err| test_support.ignoreCleanupError("clone update", err);
    const work = try std.fmt.allocPrint(gpa, "{s}/wk", .{base});
    defer gpa.free(work);
    const bare = try std.fmt.allocPrint(gpa, "{s}/bare.git", .{base});
    defer gpa.free(bare);
    const ghq_root = try std.fmt.allocPrint(gpa, "{s}/ghq", .{base});
    defer gpa.free(ghq_root);
    const store = try std.fmt.allocPrint(gpa, "{s}/store", .{base});
    defer gpa.free(store);
    try Dir.cwd().createDirPath(io, ghq_root);
    try Dir.cwd().createDirPath(io, store);

    try makeLocalBareFixture(gpa, io, work, bare);

    const input = try std.fmt.allocPrint(gpa, "file://{s}", .{bare});
    defer gpa.free(input);

    var spec = try url.parse(gpa, input, .{});
    defer spec.deinit(gpa);

    // First pass: initial clone (no adopt so a plain .git remains).
    const r1 = try cloneOne(gpa, io, spec, ghq_root, store, .{
        .no_adopt = true,
        .recursive = false,
    });
    defer {
        gpa.free(r1.url);
        gpa.free(r1.storage_path);
        if (r1.err) |e| gpa.free(e);
    }
    try testing.expectEqual(CloneReport.Status.cloned, r1.status);

    // Second pass with update_if_exists — must hit the fetch path.
    const r2 = try cloneOne(gpa, io, spec, ghq_root, store, .{
        .update_if_exists = true,
        .no_adopt = true,
        .recursive = false,
    });
    defer {
        gpa.free(r2.url);
        gpa.free(r2.storage_path);
        if (r2.err) |e| gpa.free(e);
    }
    try testing.expectEqual(CloneReport.Status.updated, r2.status);

    // Sanity: the working tree still has a usable .git after fetch.
    var log = try ex.exec(gpa, io, &.{ "git", "-C", r2.storage_path, "log", "--oneline", "-1" }, null);
    defer log.deinit(gpa);
    try testing.expect(log.succeeded());
}

test "clone: cloneOne without update on existing path returns skipped" {
    const gpa = testing.allocator;
    const io = testing.io;

    const base = try test_support.uniqueTempDir(gpa, io, "clone_test_skip");
    defer gpa.free(base);
    defer Dir.cwd().deleteTree(io, base) catch |err| test_support.ignoreCleanupError("clone skip", err);
    const work = try std.fmt.allocPrint(gpa, "{s}/wk", .{base});
    defer gpa.free(work);
    const bare = try std.fmt.allocPrint(gpa, "{s}/bare.git", .{base});
    defer gpa.free(bare);
    const ghq_root = try std.fmt.allocPrint(gpa, "{s}/ghq", .{base});
    defer gpa.free(ghq_root);
    const store = try std.fmt.allocPrint(gpa, "{s}/store", .{base});
    defer gpa.free(store);
    try Dir.cwd().createDirPath(io, ghq_root);
    try Dir.cwd().createDirPath(io, store);

    try makeLocalBareFixture(gpa, io, work, bare);

    const input = try std.fmt.allocPrint(gpa, "file://{s}", .{bare});
    defer gpa.free(input);

    var spec = try url.parse(gpa, input, .{});
    defer spec.deinit(gpa);

    const r1 = try cloneOne(gpa, io, spec, ghq_root, store, .{
        .no_adopt = true,
        .recursive = false,
    });
    defer {
        gpa.free(r1.url);
        gpa.free(r1.storage_path);
        if (r1.err) |e| gpa.free(e);
    }
    try testing.expectEqual(CloneReport.Status.cloned, r1.status);

    const r2 = try cloneOne(gpa, io, spec, ghq_root, store, .{
        .no_adopt = true,
        .recursive = false,
    });
    defer {
        gpa.free(r2.url);
        gpa.free(r2.storage_path);
        if (r2.err) |e| gpa.free(e);
    }
    try testing.expectEqual(CloneReport.Status.skipped_exists, r2.status);
}

test "clone: cloneOne against a non-existent remote reports failure" {
    const gpa = testing.allocator;
    const io = testing.io;

    const base = try test_support.uniqueTempDir(gpa, io, "clone_test_fail");
    defer gpa.free(base);
    defer Dir.cwd().deleteTree(io, base) catch |err| test_support.ignoreCleanupError("clone fail", err);
    const ghq_root = try std.fmt.allocPrint(gpa, "{s}/ghq", .{base});
    defer gpa.free(ghq_root);
    const store = try std.fmt.allocPrint(gpa, "{s}/store", .{base});
    defer gpa.free(store);
    try Dir.cwd().createDirPath(io, ghq_root);
    try Dir.cwd().createDirPath(io, store);

    const missing = try std.fmt.allocPrint(gpa, "{s}/__no_such_repo__.git", .{base});
    defer gpa.free(missing);
    const input = try std.fmt.allocPrint(gpa, "file://{s}", .{missing});
    defer gpa.free(input);

    var spec = try url.parse(gpa, input, .{});
    defer spec.deinit(gpa);

    const report = try cloneOne(gpa, io, spec, ghq_root, store, .{
        .no_adopt = true,
        .recursive = false,
    });
    defer {
        gpa.free(report.url);
        gpa.free(report.storage_path);
        if (report.err) |e| gpa.free(e);
    }

    try testing.expectEqual(CloneReport.Status.failed, report.status);
    try testing.expect(report.err != null);
    try testing.expect(report.err.?.len > 0);
}

test "clone: cloneMany runs three file:// clones with parallelism=2" {
    const gpa = testing.allocator;
    const io = testing.io;

    const base = try test_support.uniqueTempDir(gpa, io, "clone_test_many");
    defer gpa.free(base);
    defer Dir.cwd().deleteTree(io, base) catch |err| test_support.ignoreCleanupError("clone many", err);
    const ghq_root = try std.fmt.allocPrint(gpa, "{s}/ghq", .{base});
    defer gpa.free(ghq_root);
    const store = try std.fmt.allocPrint(gpa, "{s}/store", .{base});
    defer gpa.free(store);
    try Dir.cwd().createDirPath(io, ghq_root);
    try Dir.cwd().createDirPath(io, store);

    // Three independent bare fixtures.
    var bare_paths: [3][]u8 = undefined;
    var specs: [3]url.RepoSpec = undefined;
    var made: usize = 0;
    defer {
        for (0..made) |i| {
            gpa.free(bare_paths[i]);
            specs[i].deinit(gpa);
        }
    }

    for (0..3) |i| {
        const work = try std.fmt.allocPrint(gpa, "{s}/wk{d}", .{ base, i });
        defer gpa.free(work);
        const bare = try std.fmt.allocPrint(gpa, "{s}/bare{d}.git", .{ base, i });
        try makeLocalBareFixture(gpa, io, work, bare);
        const input = try std.fmt.allocPrint(gpa, "file://{s}", .{bare});
        defer gpa.free(input);
        const spec = try url.parse(gpa, input, .{});
        specs[i] = spec;
        bare_paths[i] = bare;
        made = i + 1;
    }

    const reports = try cloneMany(gpa, io, &specs, ghq_root, store, .{
        .parallelism = 2,
        .no_adopt = true,
        .recursive = false,
    });
    defer freeReports(gpa, reports);

    try testing.expectEqual(@as(usize, 3), reports.len);
    for (reports) |r| {
        try testing.expectEqual(CloneReport.Status.cloned, r.status);
        try testing.expect(r.storage_path.len > 0);
    }
}

test "clone: CloneError error set includes Canceled" {
    // Runtime check that the error tag coerces into the published set —
    // any drift that drops `Canceled` from `CloneError` fails to compile.
    const e: CloneError = error.Canceled;
    try testing.expectEqual(CloneError.Canceled, e);
}
