const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const build_steps = .{
        .unit_test = b.step("test", "Run unit tests"),
        .wasm = b.step("wasm", "Build WebAssembly bindings"),
    };

    build_unit_test(b, build_steps.unit_test, target, optimize);

    build_wasm_bindings(b, build_steps.wasm);
}

fn add_brotli_lib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) struct { lib: *std.Build.Step.Compile, mod: *std.Build.Module } {
    const brotli_c_sources = [_][]const u8{
        "deps/brotli/c/common/constants.c",
        "deps/brotli/c/common/context.c",
        "deps/brotli/c/common/dictionary.c",
        "deps/brotli/c/common/platform.c",
        "deps/brotli/c/common/shared_dictionary.c",
        "deps/brotli/c/common/transform.c",
        "deps/brotli/c/dec/bit_reader.c",
        "deps/brotli/c/dec/decode.c",
        "deps/brotli/c/dec/huffman.c",
        "deps/brotli/c/dec/state.c",
        "deps/brotli/c/enc/backward_references.c",
        "deps/brotli/c/enc/backward_references_hq.c",
        "deps/brotli/c/enc/bit_cost.c",
        "deps/brotli/c/enc/block_splitter.c",
        "deps/brotli/c/enc/brotli_bit_stream.c",
        "deps/brotli/c/enc/cluster.c",
        "deps/brotli/c/enc/command.c",
        "deps/brotli/c/enc/compound_dictionary.c",
        "deps/brotli/c/enc/compress_fragment.c",
        "deps/brotli/c/enc/compress_fragment_two_pass.c",
        "deps/brotli/c/enc/dictionary_hash.c",
        "deps/brotli/c/enc/encode.c",
        "deps/brotli/c/enc/encoder_dict.c",
        "deps/brotli/c/enc/entropy_encode.c",
        "deps/brotli/c/enc/fast_log.c",
        "deps/brotli/c/enc/histogram.c",
        "deps/brotli/c/enc/literal_cost.c",
        "deps/brotli/c/enc/memory.c",
        "deps/brotli/c/enc/metablock.c",
        "deps/brotli/c/enc/static_dict.c",
        "deps/brotli/c/enc/utf8_util.c",
    };

    const brotli_lib = b.addStaticLibrary(.{
        .name = "brotli",
        .target = target,
        .optimize = optimize,
    });

    brotli_lib.linkLibC();
    brotli_lib.addIncludePath(b.path("deps/brotli/c/include"));
    brotli_lib.addCSourceFiles(.{ .files = &brotli_c_sources, .flags = &.{} });
    brotli_lib.installHeadersDirectory(b.path("deps/brotli/c/include/brotli"), "brotli", .{});

    switch (target.result.os.tag) {
        .linux => brotli_lib.root_module.addCMacro("OS_LINUX", "1"),
        .freebsd => brotli_lib.root_module.addCMacro("OS_FREEBSD", "1"),
        .macos => brotli_lib.root_module.addCMacro("OS_MACOSX", "1"),
        else => {},
    }

    const brotli_zig_mod = b.addModule("brotli", .{
        .root_source_file = b.path("deps/brotli/zig/mod.zig"),
    });

    brotli_zig_mod.linkLibrary(brotli_lib);

    return .{ .lib = brotli_lib, .mod = brotli_zig_mod };
}

fn build_unit_test(
    b: *std.Build,
    step_unit_test: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/unit_tests.zig"),
        .target = target,
        .optimize = optimize,
        .filters = b.args orelse &.{},
    });

    const brotli = add_brotli_lib(b, target, optimize);
    // unit_tests.linkLibrary(brotli.lib);
    unit_tests.root_module.addImport("brotli", brotli.mod);

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
