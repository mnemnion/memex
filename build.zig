// Build script for memex
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const memex_mod = b.addModule("memex", .{
        .root_source_file = b.path("src/memex.zig"),
        .target = target,
        .optimize = optimize,
    });

    const fysti_mod = b.addModule("fysti", .{
        .root_source_file = b.path("src/fysti.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &[0][]const u8{};

    const memex_unit_tests = b.addTest(.{
        .root_module = memex_mod,
        .filters = test_filters,
    });

    const fysti_unit_tests = b.addTest(.{
        .root_module = fysti_mod,
        .filters = test_filters,
    });

    const run_memex_unit_tests = b.addRunArtifact(memex_unit_tests);
    const run_fysti_unit_tests = b.addRunArtifact(fysti_unit_tests);

    const test_step = b.step("test", "Run unit tests");

    test_step.dependOn(&run_memex_unit_tests.step);
    test_step.dependOn(&run_fysti_unit_tests.step);

    const run_kcov = b.addSystemCommand(&.{
        "kcov",
        "--clean",
        "--exclude-line=unreachable,expect(false),@panic,kcov-defer-error,kcov-test-cleanup",
    });
    run_kcov.addPrefixedDirectoryArg("--include-pattern=", b.path("src"));
    const coverage_output = run_kcov.addOutputDirectoryArg(".");
    run_kcov.addArtifactArg(memex_unit_tests);

    run_kcov.enableTestRunnerMode();

    const install_coverage = b.addInstallDirectory(.{
        .source_dir = coverage_output,
        .install_dir = .{ .custom = "coverage" },
        .install_subdir = "",
    });

    const coverage_step = b.step("coverage", "Generate coverage (kcov must be installed)");
    coverage_step.dependOn(&install_coverage.step);
}
