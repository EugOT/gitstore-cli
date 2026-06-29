const std = @import("std");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Io = std.Io;

pub fn ignoreCleanupError(context: []const u8, err: anyerror) void {
    switch (err) {
        error.FileNotFound => {},
        else => std.log.warn("{s} cleanup failed: {s}", .{ context, @errorName(err) }),
    }
}

fn tempRoot(gpa: Allocator) ![]u8 {
    var env = try std.testing.environ.createMap(gpa);
    defer env.deinit();

    if (env.get("TMPDIR") orelse env.get("TEMP") orelse env.get("TMP")) |root| {
        const trimmed = std.mem.trimEnd(u8, root, "/");
        if (trimmed.len > 0) return gpa.dupe(u8, trimmed);
    }

    return gpa.dupe(u8, ".zig-cache/tmp");
}

fn tempPathCandidate(
    gpa: Allocator,
    io: Io,
    root: []const u8,
    namespace: []const u8,
    suffix: []const u8,
    attempt: u32,
) ![]u8 {
    const tid: u64 = @intCast(std.Thread.getCurrentId());
    const ns: u64 = @intCast(Io.Clock.real.now(io).nanoseconds);
    return std.fmt.allocPrint(
        gpa,
        "{s}/gitstore_{s}_{d}_{d}{s}",
        .{ root, namespace, attempt, tid ^ ns, suffix },
    );
}

const temp_create_attempts: u32 = 64;

fn createUniqueDir(io: Io, path: []const u8) !void {
    try Dir.cwd().createDir(io, path, .default_dir);
}

fn createUniqueFile(io: Io, path: []const u8) !void {
    var file = try Dir.cwd().createFile(io, path, .{ .exclusive = true });
    file.close(io);
}

fn uniqueTempPath(
    gpa: Allocator,
    io: Io,
    comptime create: fn (Io, []const u8) anyerror!void,
    namespace: []const u8,
    suffix: []const u8,
) ![]u8 {
    const root = try tempRoot(gpa);
    defer gpa.free(root);
    try Dir.cwd().createDirPath(io, root);

    var attempt: u32 = 0;
    while (attempt < temp_create_attempts) : (attempt += 1) {
        const path = try tempPathCandidate(gpa, io, root, namespace, suffix, attempt);
        create(io, path) catch |err| switch (err) {
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

/// Caller owns the returned slice and must free it with `gpa`.
pub fn uniqueTempDir(gpa: Allocator, io: Io, namespace: []const u8) ![]u8 {
    return uniqueTempPath(gpa, io, createUniqueDir, namespace, "");
}

/// Caller owns the returned slice and must free it with `gpa`.
pub fn uniqueTempFile(gpa: Allocator, io: Io, namespace: []const u8, suffix: []const u8) ![]u8 {
    return uniqueTempPath(gpa, io, createUniqueFile, namespace, suffix);
}
