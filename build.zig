const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const optimize_external = switch (optimize) {
        .Debug => .ReleaseSafe,
        else => optimize,
    };

    const mod = b.addModule("mr_glsl", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "mr_glsl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "mr_glsl",
                    .module = mod,
                },
            },
        }),
    });

    const structopt = b.dependency("mr_structopt", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("mr_structopt", structopt.module("mr_structopt"));

    const glslang = b.dependency("glslang", .{
        .target = target,
        .optimize = optimize_external,
        .@"enable-opt" = true,
    });
    mod.linkLibrary(glslang.artifact("glslang"));
    mod.linkLibrary(glslang.artifact("SPIRV-Tools"));

    const remap = b.addLibrary(.{
        .name = "remap",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize_external,
        }),
    });
    remap.addCSourceFile(.{
        .file = b.path("src/remap.cpp"),
        .flags = &.{
            "-std=c++17",
            "-fno-exceptions",
            "-fno-rtti",
        },
    });
    remap.linkLibrary(glslang.artifact("SPVRemapper"));
    remap.installHeader(b.path("src/remap.h"), "glslang/SPIRV/spv_remapper_c_interface.h");
    mod.linkLibrary(remap);

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const docs = tests.getEmittedDocs();
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs,
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Build the docs");
    docs_step.dependOn(&install_docs.step);
}
