const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    const build_steps = .{
        .unit_test = b.step("test", "Run unit tests"),
        .wasm = b.step("wasm", "Build WebAssembly bindings"),
    };

    build_unit_test(b, build_steps.unit_test);

    build_wasm_bindings(b, build_steps.wasm);
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

fn build_wasm_bindings(b: *std.Build, step_wasm: *std.Build.Step) void {
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_generate = b.addExecutable(.{
        .name = "ttf",
        .root_source_file = b.path("bindings/wasm/mod.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });

    const ttf_mod = b.addModule("ttf", .{
        .root_source_file = b.path("src/lib.zig"),
    });
    wasm_generate.root_module.addImport("ttf", ttf_mod);

    wasm_generate.rdynamic = true;
    wasm_generate.entry = .disabled;

    step_wasm.dependOn(&b.addInstallFile(wasm_generate.getEmittedBin(), b.pathJoin(
        &.{
            "ttf.wasm",
        },
    )).step);
}
