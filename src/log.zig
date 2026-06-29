const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;
const test_support = @import("test_support.zig");

const log_lock_attempts: u8 = 64;
const log_lock_backoff = Io.Duration.fromMilliseconds(1);

pub const Action = enum {
    copy,
    remove,
    write_pointer,
    create_symlink,
    init_jj,

    pub fn toString(self: Action) []const u8 {
        return switch (self) {
            .copy => "copy",
            .remove => "remove",
            .write_pointer => "write_pointer",
            .create_symlink => "create_symlink",
            .init_jj => "init_jj",
        };
    }
};

/// Append a JSONL line to the operations log file.
/// Each line is a JSON object with: timestamp, action, source, destination, status.
pub fn logOperation(
    gpa: Allocator,
    io: Io,
    log_path: []const u8,
    action: Action,
    source: []const u8,
    destination: []const u8,
    status: []const u8,
) void {
    writeOperation(gpa, io, log_path, action, source, destination, status) catch |err| {
        std.log.warn("operation log write failed for {s}: {s}", .{ log_path, @errorName(err) });
    };
}

fn writeOperation(
    gpa: Allocator,
    io: Io,
    log_path: []const u8,
    action: Action,
    source: []const u8,
    destination: []const u8,
    status: []const u8,
) !void {
    // Build timestamp in a stack buffer (no static mutable)
    var ts_buf: [30]u8 = undefined;
    const ts_str = timestamp(io, &ts_buf);

    // Build the JSONL line with JSON escaping. It can exceed a fixed stack
    // buffer for long repository paths, but logging must not abort migrations
    // after filesystem state has already changed.
    var line_writer: std.Io.Writer.Allocating = .init(gpa);
    defer line_writer.deinit();
    var json: std.json.Stringify = .{ .writer = &line_writer.writer, .options = .{} };
    try json.beginObject();
    try json.objectField("timestamp");
    try json.write(ts_str);
    try json.objectField("action");
    try json.write(action.toString());
    try json.objectField("source");
    try json.write(source);
    try json.objectField("destination");
    try json.write(destination);
    try json.objectField("status");
    try json.write(status);
    try json.endObject();
    try line_writer.writer.writeByte('\n');
    const line = line_writer.written();

    // Open or create the log file (non-truncating)
    var file = Dir.cwd().createFile(io, log_path, .{
        .truncate = false,
    }) catch |err| switch (err) {
        else => return err,
    };
    defer file.close(io);

    // Serialize append offset selection with the write so concurrent processes
    // cannot interleave JSONL records.
    var locked = false;
    var lock_attempt: u8 = 0;
    while (lock_attempt < log_lock_attempts) : (lock_attempt += 1) {
        locked = try file.tryLock(io, .exclusive);
        if (locked) break;
        try Io.sleep(io, log_lock_backoff, .real);
    }
    if (!locked) {
        std.log.warn("operation log lock unavailable for {s}; dropping record", .{log_path});
        return;
    }
    defer file.unlock(io);
    const offset = try file.length(io);
    try file.writePositionalAll(io, line, offset);
}

/// Write ISO 8601 timestamp into caller-owned buffer. Returns the written slice.
pub fn timestamp(io: Io, buf: *[30]u8) []const u8 {
    const ts = Io.Clock.real.now(io);
    const ns = ts.nanoseconds;
    const secs: u64 = @intCast(@divTrunc(ns, std.time.ns_per_s));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const day_seconds = es.getDaySeconds();
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const written = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch "0000-00-00T00:00:00Z";
    return written;
}

// ===== Tests =====
const testing = std.testing;

// ===== Action.toString() tests =====

test "Action.toString covers all variants" {
    try testing.expectEqualStrings("copy", Action.copy.toString());
    try testing.expectEqualStrings("remove", Action.remove.toString());
    try testing.expectEqualStrings("write_pointer", Action.write_pointer.toString());
    try testing.expectEqualStrings("create_symlink", Action.create_symlink.toString());
    try testing.expectEqualStrings("init_jj", Action.init_jj.toString());
}

// ===== logOperation() tests =====

test "logOperation creates file and writes valid JSONL" {
    const gpa = testing.allocator;
    const io = testing.io;
    const path = try test_support.uniqueTempFile(gpa, io, "test_log_create", ".jsonl");
    defer gpa.free(path);
    try Dir.cwd().deleteFile(io, path);
    defer Dir.cwd().deleteFile(io, path) catch |err| test_support.ignoreCleanupError("log create", err);

    logOperation(gpa, io, path, .copy, "/src/a", "/dst/b", "ok");

    const content = try Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(content);

    // Must end with newline
    try testing.expect(content.len > 0);
    try testing.expect(content[content.len - 1] == '\n');

    // Must contain all expected fields
    try testing.expect(std.mem.indexOf(u8, content, "\"action\":\"copy\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"source\":\"/src/a\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"destination\":\"/dst/b\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"status\":\"ok\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"timestamp\":\"") != null);
}

test "logOperation appends multiple lines" {
    const gpa = testing.allocator;
    const io = testing.io;
    const path = try test_support.uniqueTempFile(gpa, io, "test_log_append", ".jsonl");
    defer gpa.free(path);
    defer Dir.cwd().deleteFile(io, path) catch |err| test_support.ignoreCleanupError("log append", err);

    logOperation(gpa, io, path, .copy, "/a", "/b", "ok");
    logOperation(gpa, io, path, .remove, "/c", "", "ok");
    logOperation(gpa, io, path, .write_pointer, "/d", "/e", "error");

    const content = try Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(content);

    // Count newlines = number of JSON lines
    var line_count: usize = 0;
    for (content) |c| {
        if (c == '\n') line_count += 1;
    }
    try testing.expectEqual(@as(usize, 3), line_count);

    // Each line should be separate valid JSON object
    var lines = std.mem.splitScalar(u8, content, '\n');
    var idx: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try testing.expect(line[0] == '{');
        try testing.expect(line[line.len - 1] == '}');
        idx += 1;
    }
    try testing.expectEqual(@as(usize, 3), idx);
}

test "logOperation with empty source and destination" {
    const gpa = testing.allocator;
    const io = testing.io;
    const path = try test_support.uniqueTempFile(gpa, io, "test_log_empty", ".jsonl");
    defer gpa.free(path);
    defer Dir.cwd().deleteFile(io, path) catch |err| test_support.ignoreCleanupError("log empty", err);

    logOperation(gpa, io, path, .init_jj, "", "", "ok");

    const content = try Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "\"source\":\"\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"destination\":\"\"") != null);
}

test "logOperation with special characters in paths" {
    const gpa = testing.allocator;
    const io = testing.io;
    const path = try test_support.uniqueTempFile(gpa, io, "test_log_special", ".jsonl");
    defer gpa.free(path);
    defer Dir.cwd().deleteFile(io, path) catch |err| test_support.ignoreCleanupError("log special", err);

    const source = "/path/with \"quotes\" and \\backslash\nrepo";
    const destination = "/dst/path/with\\backslash\"quote";
    const status = "ok\nquoted \"status\" with \\ slash";
    logOperation(gpa, io, path, .copy, source, destination, status);

    const content = try Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(content);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, content, .{});
    defer parsed.deinit();

    const object = parsed.value.object;
    try testing.expectEqualStrings(source, object.get("source").?.string);
    try testing.expectEqualStrings(destination, object.get("destination").?.string);
    try testing.expectEqualStrings(status, object.get("status").?.string);
}

test "logOperation handles long escaped lines" {
    const gpa = testing.allocator;
    const io = testing.io;
    const path = try test_support.uniqueTempFile(gpa, io, "test_log_overflow", ".jsonl");
    defer gpa.free(path);
    try Dir.cwd().deleteFile(io, path);
    defer Dir.cwd().deleteFile(io, path) catch |err| test_support.ignoreCleanupError("log overflow", err);

    const too_large = try gpa.alloc(u8, 5000);
    defer gpa.free(too_large);
    @memset(too_large, 'x');

    logOperation(gpa, io, path, .copy, too_large, "/dst", "ok");

    const content = try Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(content);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, content, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(too_large, parsed.value.object.get("source").?.string);
}

// ===== timestamp() tests =====

test "timestamp returns ISO 8601 format" {
    const io = testing.io;
    var ts_b: [30]u8 = undefined;
    const ts = timestamp(io, &ts_b);
    // Format: YYYY-MM-DDTHH:MM:SSZ
    try testing.expectEqual(@as(usize, 20), ts.len);
    try testing.expect(ts[4] == '-');
    try testing.expect(ts[7] == '-');
    try testing.expect(ts[10] == 'T');
    try testing.expect(ts[13] == ':');
    try testing.expect(ts[16] == ':');
    try testing.expect(ts[19] == 'Z');
}

test "timestamp year is reasonable" {
    const io = testing.io;
    var ts_b: [30]u8 = undefined;
    const ts = timestamp(io, &ts_b);
    // Year should be 2020-2099 range
    const year_str = ts[0..4];
    const year = std.fmt.parseInt(u32, year_str, 10) catch 0;
    try testing.expect(year >= 2020);
    try testing.expect(year <= 2099);
}
