const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;

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

    // Build the JSONL line in a stack buffer
    var line_buf: [4096]u8 = undefined;
    const line = std.fmt.bufPrint(
        &line_buf,
        \\{{"timestamp":"{s}","action":"{s}","source":"{s}","destination":"{s}","status":"{s}"}}
    ++ "\n",
        .{
            ts_str,
            action.toString(),
            source,
            destination,
            status,
        },
    ) catch return;

    // Open or create the log file (non-truncating)
    var file = Dir.cwd().createFile(io, log_path, .{
        .truncate = false,
    }) catch |err| switch (err) {
        else => return err,
    };
    defer file.close(io);

    // Append at end using positional write
    const offset = file.length(io) catch 0;
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

fn removeFileBestEffort(io: Io, path: []const u8) void {
    Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.log.warn("failed to remove test log {s}: {s}", .{ path, @errorName(err) }),
    };
}

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
    const io = testing.io;
    const path = "/tmp/gitstore_test_log_create.jsonl";

    // Clean up from prior runs
    removeFileBestEffort(io, path);

    try logOperation(io, path, .copy, "/src/a", "/dst/b", "ok");

    const gpa = testing.allocator;
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

    // Clean up
    removeFileBestEffort(io, path);
}

test "logOperation appends multiple lines" {
    const io = testing.io;
    const path = "/tmp/gitstore_test_log_append.jsonl";
    removeFileBestEffort(io, path);

    try logOperation(io, path, .copy, "/a", "/b", "ok");
    try logOperation(io, path, .remove, "/c", "", "ok");
    try logOperation(io, path, .write_pointer, "/d", "/e", "error");

    const gpa = testing.allocator;
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

    removeFileBestEffort(io, path);
}

test "logOperation with empty source and destination" {
    const io = testing.io;
    const path = "/tmp/gitstore_test_log_empty.jsonl";
    removeFileBestEffort(io, path);

    try logOperation(io, path, .init_jj, "", "", "ok");

    const gpa = testing.allocator;
    const content = try Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "\"source\":\"\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"destination\":\"\"") != null);

    removeFileBestEffort(io, path);
}

test "logOperation with special characters in paths" {
    const io = testing.io;
    const path = "/tmp/gitstore_test_log_special.jsonl";
    removeFileBestEffort(io, path);

    try logOperation(io, path, .copy, "/path/with spaces/repo", "/dst/path", "ok");

    const gpa = testing.allocator;
    const content = try Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "with spaces") != null);

    removeFileBestEffort(io, path);
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
