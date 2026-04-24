const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fmt = b.addFmt(.{
        .paths = &.{ "build.zig", "build.zig.zon", "src" },
        .check = true,
    });
    const fmt_step = b.step("fmt", "Check formatting");
    fmt_step.dependOn(&fmt.step);

    // Public library module: consumers depend on this and import it as
    // `@import("gitstore")`.
    const gitstore_mod = b.addModule("gitstore", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "gitstore",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run gitstore");
    run_step.dependOn(&run_cmd.step);

    // Unit tests: exec.zig (standalone, fast)
    const unit_mod = b.createModule(.{
        .root_source_file = b.path("src/exec.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .root_module = unit_mod });
    const run_unit = b.addRunArtifact(unit_tests);

    // Integration tests: tests.zig (imports all modules, e2e tests)
    const integration_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const integration_tests = b.addTest(.{ .root_module = integration_mod });
    const run_integration = b.addRunArtifact(integration_tests);

    // Public module smoke: catches regressions in the package surface that
    // external consumers import as `@import("gitstore")`.
    const lib_tests = b.addTest(.{ .root_module = gitstore_mod });
    const run_lib = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit.step);
    test_step.dependOn(&run_lib.step);
    test_step.dependOn(&run_integration.step);

    // Separate steps for targeted testing
    const unit_step = b.step("test-unit", "Run unit tests only");
    unit_step.dependOn(&run_unit.step);

    const lib_step = b.step("test-lib", "Run public library smoke tests");
    lib_step.dependOn(&run_lib.step);

    const integration_step = b.step("test-integration", "Run integration/e2e tests");
    integration_step.dependOn(&run_integration.step);

    // Fuzzing in Zig 0.16 is driven by the build runner's `--fuzz` flag.
    // This step prepares the full test graph so the runner can discover
    // project fuzz targets and rerun the relevant test binaries in fuzz mode.
    const fuzz_step = b.step("fuzz", "Prepare fuzz-capable test runs");
    fuzz_step.dependOn(&run_unit.step);
    fuzz_step.dependOn(&run_lib.step);
    fuzz_step.dependOn(&run_integration.step);

    const docs_install = b.addInstallDirectory(.{
        .source_dir = lib_tests.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Install generated API docs");
    docs_step.dependOn(&docs_install.step);
}
