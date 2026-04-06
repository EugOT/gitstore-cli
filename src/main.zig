const std = @import("std");
const Io = std.Io;
const File = std.Io.File;
const Allocator = std.mem.Allocator;
const gitstore = @import("gitstore.zig");
const hooks = @import("hooks.zig");

const usage_text =
    \\Usage: gitstore <command> [options]
    \\
    \\Commands:
    \\  init              Create gitstore directory structure
    \\  init <path>       Init git+jj repo and adopt into gitstore in one shot
    \\  adopt <path>      Migrate an existing repo into gitstore
    \\  adopt --all       Migrate all repos under ghq root
    \\  verify <path>     Check pointer/symlink integrity
    \\  verify --all      Check all repos under ghq root
    \\  status            Show gitstore disk usage and repo count
    \\  hook --zsh        Print the zsh hook function
    \\  hook --nu         Print the nushell hook module
    \\
    \\Options:
    \\  --dry-run         Print planned actions without modifying anything
    \\  --json            Output status in JSON format
    \\  --help            Show this help message
    \\
;

fn getGitstoreRoot(gpa: Allocator, environ_map: *const std.process.Environ.Map) ![]u8 {
    const home = environ_map.get("HOME") orelse return error.InvalidUserId;
    return std.fmt.allocPrint(gpa, "{s}/.local/share/gitstore", .{home});
}

fn getGhqRoot(gpa: Allocator, io: Io) ![]u8 {
    const ex = @import("exec.zig");
    const result = try ex.exec(gpa, io, &.{ "ghq", "root" }, null);
    defer gpa.free(result.stderr);
    if (!result.succeeded()) {
        gpa.free(result.stdout);
        return error.ProcessFailed;
    }
    // Trim trailing newline from the stdout
    const trimmed = ex.trimTrailingNewline(result.stdout);
    // We need to return owned memory of just the trimmed part
    if (trimmed.len < result.stdout.len) {
        const owned = try gpa.dupe(u8, trimmed);
        gpa.free(result.stdout);
        return owned;
    }
    return result.stdout;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip argv[0]

    const command = args_iter.next() orelse {
        try printUsage(io);
        return;
    };

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage(io);
        return;
    }

    if (std.mem.eql(u8, command, "init")) {
        const gitstore_root = try getGitstoreRoot(gpa, init.environ_map);
        defer gpa.free(gitstore_root);

        // init with a path: create git+jj repo and adopt in one shot
        const path_arg = args_iter.next();
        if (path_arg) |p| {
            const ghq_root = try getGhqRoot(gpa, io);
            defer gpa.free(ghq_root);
            try gitstore.initRepo(gpa, io, p, ghq_root, gitstore_root);
        } else {
            // No path: just ensure gitstore root directory exists
            try gitstore.init(io, gitstore_root);
            var buf: [4096]u8 = undefined;
            var w = File.stdout().writerStreaming(io, &buf);
            try w.interface.print("gitstore initialized at {s}\n", .{gitstore_root});
            try w.flush();
        }
        return;
    }

    if (std.mem.eql(u8, command, "hook")) {
        const flag = args_iter.next() orelse {
            try printErr(io, "error: hook requires --zsh or --nu\n");
            return;
        };
        if (std.mem.eql(u8, flag, "--zsh")) {
            try printOut(io, hooks.zsh_hook);
        } else if (std.mem.eql(u8, flag, "--nu")) {
            try printOut(io, hooks.nu_hook);
        } else {
            try printErr(io, "error: hook requires --zsh or --nu\n");
        }
        return;
    }

    if (std.mem.eql(u8, command, "adopt")) {
        const gitstore_root = try getGitstoreRoot(gpa, init.environ_map);
        defer gpa.free(gitstore_root);
        const ghq_root = try getGhqRoot(gpa, io);
        defer gpa.free(ghq_root);

        try gitstore.init(io, gitstore_root);

        var dry_run = false;
        var all = false;
        var path: ?[]const u8 = null;

        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--dry-run")) {
                dry_run = true;
            } else if (std.mem.eql(u8, arg, "--all")) {
                all = true;
            } else if (arg[0] != '-') {
                path = arg;
            }
        }

        if (all) {
            try gitstore.adoptAll(gpa, io, ghq_root, gitstore_root, dry_run);
        } else if (path) |p| {
            try gitstore.adopt(gpa, io, p, ghq_root, gitstore_root, dry_run);
        } else {
            try printErr(io, "error: adopt requires <path> or --all\n");
        }
        return;
    }

    if (std.mem.eql(u8, command, "verify")) {
        const ghq_root = try getGhqRoot(gpa, io);
        defer gpa.free(ghq_root);

        var all = false;
        var path: ?[]const u8 = null;

        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--all")) {
                all = true;
            } else if (arg[0] != '-') {
                path = arg;
            }
        }

        if (all) {
            try gitstore.verifyAll(gpa, io, ghq_root);
        } else if (path) |p| {
            const ok = try gitstore.verify(gpa, io, p);
            if (!ok) {
                return error.VerifyFailed;
            }
        } else {
            try printErr(io, "error: verify requires <path> or --all\n");
        }
        return;
    }

    if (std.mem.eql(u8, command, "status")) {
        const gitstore_root = try getGitstoreRoot(gpa, init.environ_map);
        defer gpa.free(gitstore_root);
        const ghq_root = try getGhqRoot(gpa, io);
        defer gpa.free(ghq_root);

        var json_mode = false;
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--json")) {
                json_mode = true;
            }
        }

        try gitstore.status(gpa, io, ghq_root, gitstore_root, json_mode);
        return;
    }

    try printErr(io, "error: unknown command '");
    try printErr(io, command);
    try printErr(io, "'\n");
    try printUsage(io);
}

fn printUsage(io: Io) !void {
    var buf: [4096]u8 = undefined;
    var w = File.stderr().writerStreaming(io, &buf);
    try w.interface.print("{s}", .{usage_text});
    try w.flush();
}

fn printOut(io: Io, text: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = File.stdout().writerStreaming(io, &buf);
    try w.interface.print("{s}\n", .{text});
    try w.flush();
}

fn printErr(io: Io, text: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = File.stderr().writerStreaming(io, &buf);
    try w.interface.print("{s}", .{text});
    try w.flush();
}
