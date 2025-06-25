const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    const build_steps = .{
        .unit_test = b.step("test", "Run unit tests"),
    };

    build_unit_test(b, build_steps.unit_test);
}

fn build_unit_test(b: *std.Build, step_unit_test: *std.Build.Step) void {
    const target = b.standardTargetOptions(.{});

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/unit_tests.zig"),
        .target = target,
        .optimize = b.standardOptimizeOption(.{}),
        .filters = b.args orelse &.{},
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    step_unit_test.dependOn(&run_unit_tests.step);
}
