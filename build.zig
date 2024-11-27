const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .Debug });

    const di_module = b.addModule("di", .{
        .root_source_file = b.path("src/di.zig"),
    });

    {
        const exe = b.addExecutable(.{
            .name = "zig",
            .root_source_file = b.path("examples/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = false,
        });

        exe.root_module.addImport("di", di_module);

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);

        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }

    {
        const exe_unit_tests = b.addTest(.{
            .root_source_file = b.path("tests/tests.zig"),
            .target = target,
            .optimize = optimize,
        });

        exe_unit_tests.root_module.addImport("di", di_module);

        const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_exe_unit_tests.step);
    }
}
