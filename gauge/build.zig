const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_runner_path = b.graph.zig_lib_directory.join(b.allocator, &.{
        "compiler",
        "test_runner.zig",
    }) catch @panic("OOM");
    std.debug.assert(test_runner_path.len > 0);

    const lib = b.addStaticLibrary(.{
        .name = "gauge",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    _ = b.addModule("gauge", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .test_runner = .{
            .path = .{ .cwd_relative = test_runner_path },
            .mode = .simple,
        },
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    run_lib_unit_tests.stdio = .inherit;
    std.debug.assert(run_lib_unit_tests.stdio == .inherit);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
