const std = @import("std");

/// Re-exported so a consuming project can write:
///     const zbridge = @import("zbridge");
///     zbridge.addPortStep(b, .{ ... });
pub const addPortStep = @import("src/build_api.zig").addPortStep;
pub const PortOptions = @import("src/build_api.zig").PortOptions;
pub const PortStep = @import("src/build_api.zig").PortStep;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The pipeline as a library module, so the CLI, the build integration and
    // the tests all run exactly the same code.
    const mod = b.addModule("zbridge", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zbridge",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zbridge", .module = mod }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the zbridge CLI").dependOn(&run_cmd.step);

    // Tests -------------------------------------------------------------
    const filter = b.option([]const u8, "test-filter", "Only run tests whose name contains this");
    const filters: []const []const u8 = if (filter) |f| &.{f} else &.{};

    const mod_tests = b.addTest(.{ .root_module = mod, .filters = filters });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module, .filters = filters });

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
