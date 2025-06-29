const std = @import("std");
const structopt = @import("structopt");
const log = std.log.scoped(.shader_compiler);
const c = @import("c.zig").c;
const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Command = structopt.Command;
const PositionalArg = structopt.PositionalArg;
const NamedArg = structopt.NamedArg;
const Dir = std.fs.Dir;
const File = std.fs.File;

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = .info,
};

const Target = enum(c_uint) {
    @"Vulkan-1.0" = c.SPV_ENV_VULKAN_1_0,
    @"Vulkan-1.1" = c.SPV_ENV_VULKAN_1_1,
    @"Vulkan-1.2" = c.SPV_ENV_VULKAN_1_2,
    @"Vulkan-1.3" = c.SPV_ENV_VULKAN_1_3,
    @"OpenGL-4.5" = c.SPV_ENV_OPENGL_4_5,
};

const SpirvVersion = enum {
    default,
    @"1.0",
    @"1.1",
    @"1.2",
    @"1.3",
    @"1.4",
    @"1.5",
    @"1.6",
};

const command: Command = .{
    .name = "shader_compiler",
    .named_args = &.{
        NamedArg.init(Target, .{
            .long = "target",
            .short = 'c',
        }),
        NamedArg.init(SpirvVersion, .{
            .long = "spirv-version",
            .default = .{ .value = .default },
        }),
        NamedArg.init(bool, .{
            .long = "remap",
            .default = .{ .value = false },
        }),
        NamedArg.init(bool, .{
            .long = "debug",
            .default = .{ .value = false },
        }),
        NamedArg.init(bool, .{
            .long = "optimize-perf",
            .default = .{ .value = false },
        }),
        NamedArg.init(bool, .{
            .long = "optimize-size",
            .default = .{ .value = false },
        }),
        NamedArg.init(bool, .{
            .long = "robust-access",
            .default = .{ .value = false },
        }),
        NamedArg.init(bool, .{
            .long = "preserve-bindings",
            .default = .{ .value = false },
        }),
        NamedArg.init(bool, .{
            .long = "preserve-spec-constants",
            .default = .{ .value = false },
        }),
        NamedArg.init(bool, .{
            .long = "relax-logical-pointer",
            .default = .{ .value = false },
        }),
        NamedArg.init(bool, .{
            .long = "relax-block-layout",
            .default = .{ .value = false },
        }),
        NamedArg.init(bool, .{
            .long = "uniform-buffer-standard-layout",
            .default = .{ .value = false },
        }),
        NamedArg.init(bool, .{
            .long = "scalar-block-layout",
            .default = .{ .value = false },
        }),
        NamedArg.init(bool, .{
            .long = "workgroup-scalar-block-layout",
            .default = .{ .value = false },
        }),
        NamedArg.init(bool, .{
            .long = "skip-block-layout",
            .default = .{ .value = false },
        }),
        NamedArg.init(bool, .{
            .long = "relax-struct-store",
            .default = .{ .value = false },
        }),
        NamedArg.init(bool, .{
            .long = "allow-local-size-id",
            .default = .{ .value = false },
        }),
        NamedArg.init(bool, .{
            .long = "allow-offset-texture-operand",
            .default = .{ .value = false },
        }),
        NamedArg.init(bool, .{
            .long = "allow-vulkan32-bit-bitwise",
            .default = .{ .value = false },
        }),
        NamedArg.init(bool, .{
            .long = "before-hlsl-legalization",
            .default = .{ .value = false },
        }),
        NamedArg.init(bool, .{
            .long = "friendly-names",
            .default = .{ .value = true },
        }),
        NamedArg.init(u32, .{
            .long = "max-struct-members",
            .default = .{ .value = 16383 },
        }),
        NamedArg.init(u32, .{
            .long = "max-struct-depth",
            .default = .{ .value = 255 },
        }),
        NamedArg.init(u32, .{
            .long = "max-local-variables",
            .default = .{ .value = 524287 },
        }),
        NamedArg.init(u32, .{
            .long = "max-global-variables",
            .default = .{ .value = 65535 },
        }),
        NamedArg.init(u32, .{
            .long = "max-switch-branches",
            .default = .{ .value = 16383 },
        }),
        NamedArg.init(u32, .{
            .long = "max-function-args",
            .default = .{ .value = 255 },
        }),
        NamedArg.init(u32, .{
            .long = "max-control-flow-nesting-depth",
            .default = .{ .value = 1023 },
        }),
        NamedArg.init(u32, .{
            .long = "max-access-chain-indexes",
            .default = .{ .value = 255 },
        }),
        NamedArg.init(u32, .{
            .long = "max-id-bound",
            .default = .{ .value = 0x3FFFFF },
        }),
        NamedArg.initAccum([]const u8, .{
            .long = "include-path",
        }),
        NamedArg.init(?[]const u8, .{
            .long = "write-deps",
            .default = .{ .value = null },
        }),
        NamedArg.init(?[]const u8, .{
            .long = "preamble",
            .default = .{ .value = null },
        }),
        // Required for preamble to be useful
        NamedArg.init(i32, .{
            .long = "default-version",
            .default = .{ .value = 100 },
        }),
    },
    .positional_args = &.{
        PositionalArg.init([:0]const u8, .{
            .meta = "INPUT",
        }),
        PositionalArg.init([:0]const u8, .{
            .meta = "OUTPUT",
        }),
    },
};

const max_file_len = 400000;
const max_include_depth = 255;

pub fn main() void {
    @setEvalBranchQuota(2000); // For structopt

    defer std.process.cleanExit();

    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false }){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var arg_iter = std.process.argsWithAllocator(allocator) catch @panic("OOM");
    defer arg_iter.deinit();
    const args = command.parseOrExit(allocator, &arg_iter);
    defer command.parseFree(args);

    const cwd = std.fs.cwd();

    var estimated_total_items: usize = 0;
    estimated_total_items += 1; // Read source
    estimated_total_items += 1; // Compile
    estimated_total_items += 1; // Optimize (even if 0 passes still starts up)
    if (args.named.remap) estimated_total_items += 1;
    estimated_total_items += 1; // Validate
    estimated_total_items += 1; // Write

    if (c.glslang_initialize_process() == c.false) @panic("glslang_initialize_process failed");
    defer c.glslang_finalize_process();

    const source = readSource(allocator, cwd, args.positional.INPUT);
    defer allocator.free(source);

    const preamble = if (args.named.preamble) |path| b: {
        break :b readSource(allocator, cwd, path);
    } else null;
    defer if (preamble) |p| allocator.free(p);

    const compiled = compile(allocator, source, preamble, args);
    defer allocator.free(compiled);

    const optimized = optimize(compiled, args);
    defer optimizeFree(optimized);

    const remapped = if (args.named.remap) remap(optimized) else optimized;

    validate(args.positional.INPUT, remapped, args);

    writeSpirv(cwd, args.positional.OUTPUT, remapped);
}

fn readSource(
    gpa: Allocator,
    dir: std.fs.Dir,
    path: []const u8,
) [:0]const u8 {
    var file = dir.openFile(path, .{}) catch |err| {
        log.err("{s}: {s}", .{ path, @errorName(err) });
        std.process.exit(1);
    };
    defer file.close();

    return file.readToEndAllocOptions(gpa, max_file_len, null, .@"1", 0) catch |err| {
        log.err("{s}: {s}", .{ path, @errorName(err) });
        std.process.exit(1);
    };
}

fn compile(
    gpa: Allocator,
    source: [:0]const u8,
    preamble: ?[:0]const u8,
    args: command.Result(),
) []u32 {
    const cwd = std.fs.cwd();

    const stage = b: {
        const stages = std.StaticStringMap(c_uint).initComptime(.{
            .{ ".vert", c.GLSLANG_STAGE_VERTEX },
            .{ ".tesc", c.GLSLANG_STAGE_TESSCONTROL },
            .{ ".tese", c.GLSLANG_STAGE_TESSEVALUATION },
            .{ ".geom", c.GLSLANG_STAGE_GEOMETRY },
            .{ ".frag", c.GLSLANG_STAGE_FRAGMENT },
            .{ ".comp", c.GLSLANG_STAGE_COMPUTE },
            .{ ".rgen", c.GLSLANG_STAGE_RAYGEN },
            .{ ".rint", c.GLSLANG_STAGE_INTERSECT },
            .{ ".rahit", c.GLSLANG_STAGE_ANYHIT },
            .{ ".rchit", c.GLSLANG_STAGE_CLOSESTHIT },
            .{ ".rmiss", c.GLSLANG_STAGE_MISS },
            .{ ".rcall", c.GLSLANG_STAGE_CALLABLE },
            .{ ".task", c.GLSLANG_STAGE_TASK },
            .{ ".mesh", c.GLSLANG_STAGE_MESH },
        });
        const period = std.mem.lastIndexOfScalar(u8, args.positional.INPUT, '.') orelse {
            log.err("{s}: shader missing extension", .{args.positional.INPUT});
            std.process.exit(1);
        };
        const extension = args.positional.INPUT[period..];
        const stage = stages.get(extension) orelse {
            log.err("{s}: unknown extension", .{args.positional.INPUT});
            std.process.exit(1);
        };
        break :b stage;
    };

    for (args.named.@"include-path".items) |path| {
        cwd.access(path, .{}) catch |err| {
            log.err("include-path: {s}: {}", .{ path, err });
            std.process.exit(1);
        };
    }

    const deps_file = if (args.named.@"write-deps") |path| cwd.createFile(path, .{}) catch |err| {
        log.err("{s}: {s}", .{ path, @errorName(err) });
        std.process.exit(1);
    } else null;
    defer if (deps_file) |f| {
        f.sync() catch |err| @panic(@errorName(err));
        f.close();
    };
    const deps_writer = if (deps_file) |f| f.writer() else null;
    if (deps_writer) |f| {
        f.print("{s}: ", .{args.positional.OUTPUT}) catch |err| @panic(@errorName(err));
    }

    var callbacks: Callbacks = .{
        .gpa = gpa,
        .include_paths = args.named.@"include-path".items,
        .deps_writer = deps_writer,
    };
    const input: c.glslang_input_t = .{
        .language = c.GLSLANG_SOURCE_GLSL,
        .stage = stage,
        .client = switch (args.named.target) {
            .@"Vulkan-1.0",
            .@"Vulkan-1.1",
            .@"Vulkan-1.2",
            .@"Vulkan-1.3",
            => c.GLSLANG_CLIENT_VULKAN,
            .@"OpenGL-4.5" => c.GLSLANG_CLIENT_OPENGL,
        },
        .client_version = switch (args.named.target) {
            .@"Vulkan-1.0" => c.GLSLANG_TARGET_VULKAN_1_0,
            .@"Vulkan-1.1" => c.GLSLANG_TARGET_VULKAN_1_1,
            .@"Vulkan-1.2" => c.GLSLANG_TARGET_VULKAN_1_2,
            .@"Vulkan-1.3" => c.GLSLANG_TARGET_VULKAN_1_3,
            .@"OpenGL-4.5" => c.GLSLANG_TARGET_OPENGL_450,
        },
        .target_language = c.GLSLANG_TARGET_SPV,
        .target_language_version = switch (args.named.@"spirv-version") {
            .default => switch (args.named.target) {
                .@"Vulkan-1.0" => c.GLSLANG_TARGET_SPV_1_0,
                .@"Vulkan-1.1" => c.GLSLANG_TARGET_SPV_1_3,
                .@"Vulkan-1.2" => c.GLSLANG_TARGET_SPV_1_5,
                .@"Vulkan-1.3" => c.GLSLANG_TARGET_SPV_1_6,
                .@"OpenGL-4.5" => c.GLSLANG_TARGET_SPV_1_0,
            },
            .@"1.0" => c.GLSLANG_TARGET_SPV_1_0,
            .@"1.1" => c.GLSLANG_TARGET_SPV_1_1,
            .@"1.2" => c.GLSLANG_TARGET_SPV_1_2,
            .@"1.3" => c.GLSLANG_TARGET_SPV_1_3,
            .@"1.4" => c.GLSLANG_TARGET_SPV_1_4,
            .@"1.5" => c.GLSLANG_TARGET_SPV_1_5,
            .@"1.6" => c.GLSLANG_TARGET_SPV_1_6,
        },
        .code = source,
        .default_version = args.named.@"default-version",
        // Poorly documented, reference exe always passes no profile
        .default_profile = c.GLSLANG_NO_PROFILE,
        .force_default_version_and_profile = c.false,
        .forward_compatible = c.false,
        .messages = c.GLSLANG_MSG_DEFAULT_BIT,
        .resource = c.glslang_default_resource(),
        .callbacks = .{
            .include_system = &Callbacks.includeSystem,
            .include_local = &Callbacks.includeLocal,
            .free_include_result = &Callbacks.freeIncludeResult,
        },
        .callbacks_ctx = @ptrCast(&callbacks),
    };

    const shader = c.glslang_shader_create(&input) orelse @panic("OOM");
    defer c.glslang_shader_delete(shader);

    if (preamble) |p| c.glslang_shader_set_preamble(shader, p);

    if (c.glslang_shader_preprocess(shader, &input) == c.false) {
        compilationFailed(shader, "preprocessing", args.positional.INPUT);
    }

    if (c.glslang_shader_parse(shader, &input) == c.false) {
        compilationFailed(shader, "parsing", args.positional.INPUT);
    }

    const program: *c.glslang_program_t = c.glslang_program_create() orelse @panic("OOM");
    defer c.glslang_program_delete(program);

    c.glslang_program_add_shader(program, shader);

    if (c.glslang_program_link(
        program,
        c.GLSLANG_MSG_SPV_RULES_BIT | c.GLSLANG_MSG_VULKAN_RULES_BIT,
    ) == c.false) {
        compilationFailed(shader, "linking", args.positional.INPUT);
    }

    c.glslang_program_set_source_file(program, stage, args.positional.INPUT);
    c.glslang_program_add_source_text(program, stage, source, source.len);

    var options: c.glslang_spv_options_t = .{
        .generate_debug_info = args.named.debug,
        .strip_debug_info = !args.named.debug,
        .disable_optimizer = true,
        .optimize_size = false,
        .disassemble = false,
        .validate = true,
        .emit_nonsemantic_shader_debug_info = false,
        .emit_nonsemantic_shader_debug_source = false,
        .compile_only = false,
        .optimize_allow_expanded_id_bound = false,
    };
    c.glslang_program_SPIRV_generate_with_options(program, stage, &options);

    const size = c.glslang_program_SPIRV_get_size(program);
    const buf = gpa.alloc(u32, size) catch @panic("OOM");
    errdefer gpa.free(buf);
    c.glslang_program_SPIRV_get(program, buf.ptr);

    if (c.glslang_program_SPIRV_get_messages(program)) |msgs| {
        writeGlslMessages(log.info, args.positional.INPUT, msgs);
    }

    return buf[0..size];
}

fn optimize(spirv: []u32, args: command.Result()) []u32 {
    // Set the options
    const options = c.spvOptimizerOptionsCreate() orelse @panic("OOM");
    defer c.spvOptimizerOptionsDestroy(options);
    c.spvOptimizerOptionsSetRunValidator(options, false);
    c.spvOptimizerOptionsSetPreserveBindings(options, args.named.@"preserve-bindings");
    c.spvOptimizerOptionsSetPreserveSpecConstants(options, args.named.@"preserve-spec-constants");

    // Create the optimizer
    const optimizer = c.spvOptimizerCreate(@intFromEnum(args.named.target)) orelse @panic("OOM");
    defer c.spvOptimizerDestroy(optimizer);
    if (args.named.@"optimize-perf") c.spvOptimizerRegisterPerformancePasses(optimizer);
    if (args.named.@"optimize-size") c.spvOptimizerRegisterSizePasses(optimizer);
    if (args.named.@"robust-access") {
        assert(c.spvOptimizerRegisterPassFromFlag(optimizer, "--graphics-robust-access"));
    }

    // Run the optimizer
    var optimized_binary: c.spv_binary = null;
    if (c.spvOptimizerRun(
        optimizer,
        spirv.ptr,
        spirv.len,
        &optimized_binary,
        options,
    ) != c.SPV_SUCCESS) @panic("spvOptimizerRun failed");
    return optimized_binary.?.*.code[0..optimized_binary.?.*.wordCount];
}

fn optimizeFree(code: []u32) void {
    c.free(code.ptr);
}

fn remap(spirv: []u32) []u32 {
    var len = spirv.len;
    if (c.glslang_remap(spirv.ptr, &len) == false) @panic("remap failed");
    return spirv[0..len];
}

fn validate(path: []const u8, spirv: []u32, args: command.Result()) void {
    const spirv_context = c.spvContextCreate(@intFromEnum(args.named.target));
    defer c.spvContextDestroy(spirv_context);
    var spirv_binary: c.spv_const_binary_t = .{
        .code = spirv.ptr,
        .wordCount = spirv.len,
    };

    const options = c.spvValidatorOptionsCreate() orelse @panic("OOM");
    defer c.spvValidatorOptionsDestroy(options);
    c.spvValidatorOptionsSetUniversalLimit(
        options,
        c.spv_validator_limit_max_struct_members,
        args.named.@"max-struct-members",
    );
    c.spvValidatorOptionsSetUniversalLimit(
        options,
        c.spv_validator_limit_max_struct_depth,
        args.named.@"max-struct-depth",
    );
    c.spvValidatorOptionsSetUniversalLimit(
        options,
        c.spv_validator_limit_max_local_variables,
        args.named.@"max-local-variables",
    );
    c.spvValidatorOptionsSetUniversalLimit(
        options,
        c.spv_validator_limit_max_global_variables,
        args.named.@"max-global-variables",
    );
    c.spvValidatorOptionsSetUniversalLimit(
        options,
        c.spv_validator_limit_max_switch_branches,
        args.named.@"max-switch-branches",
    );
    c.spvValidatorOptionsSetUniversalLimit(
        options,
        c.spv_validator_limit_max_function_args,
        args.named.@"max-function-args",
    );
    c.spvValidatorOptionsSetUniversalLimit(
        options,
        c.spv_validator_limit_max_control_flow_nesting_depth,
        args.named.@"max-control-flow-nesting-depth",
    );
    c.spvValidatorOptionsSetUniversalLimit(
        options,
        c.spv_validator_limit_max_access_chain_indexes,
        args.named.@"max-access-chain-indexes",
    );
    c.spvValidatorOptionsSetUniversalLimit(
        options,
        c.spv_validator_limit_max_id_bound,
        args.named.@"max-id-bound",
    );
    c.spvValidatorOptionsSetRelaxStoreStruct(
        options,
        args.named.@"relax-struct-store",
    );
    c.spvValidatorOptionsSetRelaxLogicalPointer(
        options,
        args.named.@"relax-logical-pointer",
    );
    c.spvValidatorOptionsSetRelaxBlockLayout(
        options,
        args.named.@"relax-block-layout",
    );
    c.spvValidatorOptionsSetUniformBufferStandardLayout(
        options,
        args.named.@"uniform-buffer-standard-layout",
    );
    c.spvValidatorOptionsSetScalarBlockLayout(
        options,
        args.named.@"scalar-block-layout",
    );
    c.spvValidatorOptionsSetWorkgroupScalarBlockLayout(
        options,
        args.named.@"workgroup-scalar-block-layout",
    );
    c.spvValidatorOptionsSetSkipBlockLayout(
        options,
        args.named.@"skip-block-layout",
    );
    c.spvValidatorOptionsSetRelaxStoreStruct(
        options,
        args.named.@"relax-struct-store",
    );
    c.spvValidatorOptionsSetAllowLocalSizeId(
        options,
        args.named.@"allow-local-size-id",
    );
    c.spvValidatorOptionsSetAllowOffsetTextureOperand(
        options,
        args.named.@"allow-offset-texture-operand",
    );
    c.spvValidatorOptionsSetAllowVulkan32BitBitwise(
        options,
        args.named.@"allow-vulkan32-bit-bitwise",
    );
    c.spvValidatorOptionsSetBeforeHlslLegalization(
        options,
        args.named.@"before-hlsl-legalization",
    );
    c.spvValidatorOptionsSetFriendlyNames(
        options,
        args.named.@"friendly-names",
    );

    var spirv_diagnostic: [8]c.spv_diagnostic = .{null} ** 8;
    if (c.spvValidateWithOptions(
        spirv_context,
        options,
        &spirv_binary,
        &spirv_diagnostic,
    ) != c.SPV_SUCCESS) {
        log.err("{s}: SPIRV validation failed", .{path});
        for (spirv_diagnostic) |diagnostic| {
            const d = diagnostic orelse break;
            if (d.*.isTextSource) {
                log.err("{s}:{}:{}: {s}", .{
                    path,
                    d.*.position.line + 1, // Offset to match text editors
                    d.*.position.column,
                    d.*.@"error",
                });
            } else if (d.*.position.index > 0) {
                log.err("{s}[{}] {s}", .{
                    path,
                    d.*.position.index,
                    d.*.@"error",
                });
            } else {
                log.err("{s}: {s}", .{
                    path,
                    d.*.@"error",
                });
            }
        }
        std.process.exit(1);
    }
}

fn writeSpirv(dir: std.fs.Dir, path: []const u8, spirv: []const u32) void {
    var file = dir.createFile(path, .{}) catch |err| {
        log.err("{s}: {s}", .{ path, @errorName(err) });
        std.process.exit(1);
    };
    defer {
        file.sync() catch |err| @panic(@errorName(err));
        file.close();
    }

    file.writeAll(std.mem.sliceAsBytes(spirv)) catch |err| {
        log.err("{s}: {s}", .{ path, @errorName(err) });
        std.process.exit(1);
    };
}

fn writeGlslMessages(
    write: fn (comptime []const u8, anytype) void,
    path: []const u8,
    raw: [*:0]const u8,
) void {
    const span = std.mem.span(raw);
    var iter = std.mem.splitScalar(u8, span, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) continue;

        const error_prefix = "ERROR: ";
        const start = if (std.mem.startsWith(u8, line, error_prefix)) error_prefix.len else 0;
        const prefix_removed = line[start..];

        const location = if (std.mem.indexOfScalar(u8, prefix_removed, ' ')) |i| b: {
            const location = prefix_removed[0..i];
            var pieces = std.mem.splitScalar(u8, location, ':');
            const linen = pieces.next() orelse break :b "";
            const coln = pieces.next() orelse break :b "";
            _ = linen;
            _ = coln;
            const empty = pieces.next() orelse break :b "";
            if (empty.len > 0) break :b "";
            if (pieces.next() != null) break :b "";
            break :b location;
        } else "";
        const message = std.mem.trim(u8, prefix_removed[location.len..], " ");
        write("{s}:{s} {s}", .{ path, location, message });
    }
}

fn compilationFailed(
    shader: *c.struct_glslang_shader_s,
    step: []const u8,
    path: []const u8,
) noreturn {
    log.err("{s}: {s} failed", .{ path, step });
    writeGlslMessages(log.err, path, c.glslang_shader_get_info_log(shader));
    writeGlslMessages(log.err, path, c.glslang_shader_get_info_debug_log(shader));
    std.process.exit(1);
}

fn logFn(
    comptime message_level: std.log.Level,
    comptime _: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const bold = "\x1b[1m";
    const color = switch (message_level) {
        .err => "\x1b[31m",
        .info => "\x1b[32m",
        .debug => "\x1b[34m",
        .warn => "\x1b[33m",
    };
    const reset = "\x1b[0m";
    const level_txt = comptime message_level.asText();
    const stderr = std.io.getStdErr().writer();
    var bw = std.io.bufferedWriter(stderr);
    const writer = bw.writer();

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    nosuspend {
        var wrote_prefix = false;
        if (message_level != .info) {
            writer.writeAll(bold ++ color ++ level_txt ++ reset) catch return;
            wrote_prefix = true;
        }
        if (message_level == .err) writer.writeAll(bold) catch return;
        if (wrote_prefix) {
            writer.writeAll(": ") catch return;
        }
        writer.print(format ++ "\n", args) catch return;
        writer.writeAll(reset) catch return;
        bw.flush() catch return;
    }
}

const Callbacks = struct {
    gpa: std.mem.Allocator,
    include_paths: []const []const u8,
    deps_writer: ?File.Writer,

    pub fn includeSystem(
        ctx: ?*anyopaque,
        header_path_c: [*c]const u8,
        includer_name: [*c]const u8,
        depth: usize,
    ) callconv(.C) ?*c.glsl_include_result_t {
        const self: *Callbacks = @ptrCast(@alignCast(ctx));
        const header_path = std.mem.span(header_path_c);
        _ = includer_name;

        if (!checkDepthAndPath(depth, header_path, true)) return null;

        if (self.include_paths.len == 0) {
            log.err("include-path not set", .{});
            return null;
        }

        for (self.include_paths) |include_path| {
            if (self.include(include_path, header_path)) |result| {
                return result;
            }
        }

        return null;
    }

    pub fn includeLocal(
        ctx: ?*anyopaque,
        header_name_c: [*c]const u8,
        includer_name_c: [*c]const u8,
        depth: usize,
    ) callconv(.C) ?*c.glsl_include_result_t {
        const self: *Callbacks = @ptrCast(@alignCast(ctx));
        const header_name = std.mem.span(header_name_c);
        const includer_name = std.mem.span(includer_name_c);

        if (!checkDepthAndPath(depth, header_name, false)) return null;

        // Get the current directory path, or skip local includes if there is none. This conforms
        // with the `ARB_shading_language_include` specification. We need to use `dirname` not
        // `dirnamePosix` here, because on Windows the includer name may include backslashes even if
        // we never use them in the shaders.
        const dir_path = std.fs.path.dirname(includer_name) orelse return null;

        // If we're an absolute path, skip local includes.
        if (header_name.len > 0 and header_name[0] == '/') return null;

        const header_path = std.fs.path.join(self.gpa, &.{
            dir_path,
            header_name,
        }) catch cppPanic("OOM");
        defer self.gpa.free(header_path);

        for (self.include_paths) |include_path| {
            if (self.include(include_path, header_path)) |result| {
                return result;
            }
        }

        return null;
    }

    fn freeIncludeResult(
        ctx_c: ?*anyopaque,
        results: [*c]c.glsl_include_result_t,
    ) callconv(.C) c_int {
        const ctx: *const Callbacks = @ptrCast(@alignCast(ctx_c));
        const result = &results[0];
        ctx.gpa.free(@as([:0]const u8, @ptrCast(result.header_data[0..result.header_length])));
        ctx.gpa.free(std.mem.span(result.header_name));
        ctx.gpa.destroy(result);
        return 0;
    }

    fn checkDepthAndPath(depth: usize, path: []const u8, diagnostic: bool) bool {
        if (depth > max_include_depth) {
            log.err("exceeded max include depth ({})", .{max_include_depth});
            std.process.exit(1);
        }

        var lastWasSlash = false;
        for (path) |char| {
            switch (char) {
                '/' => if (lastWasSlash) {
                    if (diagnostic) {
                        log.err("include path contains illegal substring: \"//\"", .{});
                    }
                    return false;
                } else {
                    lastWasSlash = true;
                },
                'a'...'z', 'A'...'Z', '_', '0'...'9', '.', ' ' => lastWasSlash = false,
                else => {
                    if (diagnostic) {
                        log.err("include path contains illegal character: '{c}'", .{char});
                    }
                    return false;
                },
            }
        }

        return true;
    }

    fn cppPanic(message: []const u8) noreturn {
        // We can't use normal panics in the callbacks, because they'd cause us to unwind through
        // C++ code.
        log.err("panic in callback: {s}", .{message});
        std.process.exit(2);
    }

    fn include(
        self: *@This(),
        include_path: []const u8,
        header_path: []const u8,
    ) ?*c.glsl_include_result_t {
        // Get the full path
        const path = std.fs.path.join(self.gpa, &.{ include_path, header_path }) catch cppPanic("OOM");
        defer self.gpa.free(path);

        // Attempt to open the file
        const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                return null;
            },
            else => {
                log.err("{s}: {s}", .{ path, @errorName(err) });
                std.process.exit(1);
            },
        };
        defer file.close();

        // Write the include path to the deps file
        if (self.deps_writer) |deps_writer| {
            for (path) |char| {
                if (char == ' ') {
                    deps_writer.writeByte('\\') catch |err| cppPanic(@errorName(err));
                }
                deps_writer.writeByte(char) catch |err| cppPanic(@errorName(err));
            }
            deps_writer.writeByte(' ') catch |err| cppPanic(@errorName(err));
        }

        // Return the result
        const result = self.gpa.create(c.glsl_include_result_t) catch cppPanic("OOM");
        const source = file.readToEndAllocOptions(
            self.gpa,
            max_file_len,
            null,
            .@"1",
            0,
        ) catch |err| cppPanic(@errorName(err));
        result.* = .{
            .header_name = self.gpa.dupeZ(u8, header_path) catch cppPanic("OOM"),
            .header_data = source.ptr,
            .header_length = source.len,
        };
        return result;
    }
};
