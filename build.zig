const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const optimize_external = switch (optimize) {
        .Debug => .ReleaseSafe,
        else => optimize,
    };

    const mod = b.addModule("shader_compiler", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "shader_compiler",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "shader_compiler",
                    .module = mod,
                },
            },
        }),
    });

    const structopt = b.dependency("structopt", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("structopt", structopt.module("structopt"));

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
}
