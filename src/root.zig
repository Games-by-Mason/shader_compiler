const std = @import("std");
const log_scope = .shader_compiler;
const log = std.log.scoped(log_scope);
const assert = std.debug.assert;

const Io = std.Io;

pub const c = @cImport({
    @cInclude("glslang/Include/glslang_c_interface.h");
    @cInclude("glslang/Public/resource_limits_c.h");
    @cInclude("glslang/SPIRV/spv_remapper_c_interface.h");
    @cInclude("spirv-tools/libspirv.h");
});

const Allocator = std.mem.Allocator;
const Dir = std.fs.Dir;
const File = std.fs.File;

pub const Target = enum(c_uint) {
    @"Vulkan-1.0" = c.SPV_ENV_VULKAN_1_0,
    @"Vulkan-1.1" = c.SPV_ENV_VULKAN_1_1,
    @"Vulkan-1.2" = c.SPV_ENV_VULKAN_1_2,
    @"Vulkan-1.3" = c.SPV_ENV_VULKAN_1_3,
    @"OpenGL-4.5" = c.SPV_ENV_OPENGL_4_5,
};

pub const SpirvVersion = enum {
    default,
    @"1.0",
    @"1.1",
    @"1.2",
    @"1.3",
    @"1.4",
    @"1.5",
    @"1.6",
};

pub const Stage = enum(c_uint) {
    vert = c.GLSLANG_STAGE_VERTEX,
    tesc = c.GLSLANG_STAGE_TESSCONTROL,
    tese = c.GLSLANG_STAGE_TESSEVALUATION,
    geom = c.GLSLANG_STAGE_GEOMETRY,
    frag = c.GLSLANG_STAGE_FRAGMENT,
    comp = c.GLSLANG_STAGE_COMPUTE,
    rgen = c.GLSLANG_STAGE_RAYGEN,
    rint = c.GLSLANG_STAGE_INTERSECT,
    rahit = c.GLSLANG_STAGE_ANYHIT,
    rchit = c.GLSLANG_STAGE_CLOSESTHIT,
    rmiss = c.GLSLANG_STAGE_MISS,
    rcall = c.GLSLANG_STAGE_CALLABLE,
    task = c.GLSLANG_STAGE_TASK,
    mesh = c.GLSLANG_STAGE_MESH,
};

pub const Optimize = struct {
    perf: bool = false,
    size: bool = false,
    preserve_bindings: bool = false,
    preserve_spec_constants: bool = false,
    robust_access: bool = false,
};

pub const Validate = struct {
    allow_local_size_id: bool = false,
    allow_offset_texture_operand: bool = false,
    allow_vulkan32_bit_bitwise: bool = false,

    before_hlsl_legalization: bool = false,

    friendly_names: bool = true,

    max_struct_members: u32 = 16383,
    max_struct_depth: u32 = 255,
    max_local_variables: u32 = 524287,
    max_global_variables: u32 = 65535,
    max_switch_branches: u32 = 16383,
    max_function_args: u32 = 255,
    max_control_flow_nesting_depth: u32 = 1023,
    max_access_chain_indexes: u32 = 255,
    max_id_bound: u32 = 0x3FFFFF,

    relax_logical_pointer: bool = false,
    relax_block_layout: bool = false,
    relax_struct_store: bool = false,

    uniform_buffer_standard_layout: bool = false,
    scalar_block_layout: bool = false,
    workgroup_scalar_block_layout: bool = false,
    skip_block_layout: bool = false,
};

pub const Compile = struct {
    input_path: [:0]const u8,
    output_path: []const u8,
    include_path: []const []const u8 = &.{},
    preamble: []const []const u8 = &.{},
    defines: []const []const u8 = &.{},
    default_version: i32 = 100,
    warnings_as_errors: bool = true,
    stage: ?Stage = null,
    debug: bool = false,
    target: Target,
    spirv_version: SpirvVersion = .default,
    allow_uppercase_paths: bool = false,
};

pub const Options = struct {
    compile: Compile,
    remap: bool = false,
    optimize: Optimize = .{},
    validate: Validate = .{},
};

const max_file_len = 400000;
const max_include_depth = 255;

pub fn compile(
    gpa: Allocator,
    io: Io,
    dir: Dir,
    deps: *std.Io.Writer,
    options: Options,
) error{Compile}![]u32 {
    if (c.glslang_initialize_process() == c.false) @panic("glslang_initialize_process failed");
    defer c.glslang_finalize_process();

    const source = try readSource(gpa, dir, options.compile.input_path);
    defer gpa.free(source);

    const preamble = b: {
        var buf: [128]u8 = undefined;
        var preamble: std.ArrayList(u8) = .empty;
        defer preamble.deinit(gpa);
        for (options.compile.preamble) |path| {
            const contents = try openSource(dir, path);
            defer contents.close();
            var contents_reader = contents.readerStreaming(io, &buf);
            contents_reader.interface.appendRemaining(gpa, &preamble, .unlimited) catch |err| {
                if (err == error.OutOfMemory) @panic("OOM");
                log.err("{s}: {s}", .{ path, @errorName(err) });
                return error.Compile;
            };
        }

        for (options.compile.defines) |define| {
            if (std.mem.indexOfScalar(u8, define, '=')) |i| {
                preamble.print(gpa, "#define {s} {s}\n", .{
                    define[0..i],
                    define[i + 1 ..],
                }) catch @panic("OOM");
            } else {
                preamble.print(gpa, "#define {s}\n", .{define}) catch @panic("OOM");
            }
        }

        break :b preamble.toOwnedSliceSentinel(gpa, 0) catch @panic("OOM");
    };
    defer gpa.free(preamble);

    defer {
        deps.writeByte('\n') catch |err| @panic(@errorName(err));
        deps.flush() catch |err| @panic(@errorName(err));
    }
    {
        // We're being overly conservative, but this prevent us from having to more elaborately
        // escape the dep file. We don't use check path here as unlike in GLSL, we want to allow
        // whatever the native path separator is. If you're hitting this error feel free to file an
        // issue, we can always revisit and add full dep file path escpaing if needed.
        for (options.compile.output_path) |char| {
            switch (char) {
                std.fs.path.sep, 'a'...'z', 'A'...'Z', '-', '_', '0'...'9', '.', ' ' => {},
                else => {
                    log.err("{s}: output path contains illegal character: '{c}'", .{
                        options.compile.output_path,
                        char,
                    });
                    return error.Compile;
                },
            }
        }
        writeDepPath(deps, options.compile.output_path) catch |err| @panic(@errorName(err));
        deps.writeAll(": ") catch |err| @panic(@errorName(err));
    }

    const compiled = try compileImpl(gpa, dir, source, preamble, &options, deps);
    defer gpa.free(compiled);

    const optimized = try optimize(compiled, options.compile.target, options.optimize);
    errdefer freeSpirv(optimized);

    const remapped = if (options.remap) remap(optimized) else optimized;

    try validate(options.compile.input_path, remapped, options.compile.target, options.validate);

    return remapped;
}

pub fn freeSpirv(code: []u32) void {
    c.free(code.ptr);
}

fn openSource(dir: Dir, path: []const u8) !File {
    return dir.openFile(path, .{}) catch |err| {
        log.err("{s}: {s}", .{ path, @errorName(err) });
        return error.Compile;
    };
}

fn readSource(
    gpa: Allocator,
    dir: std.fs.Dir,
    path: []const u8,
) ![:0]const u8 {
    return dir.readFileAllocOptions(path, gpa, .unlimited, .@"1", 0) catch |err| {
        log.err("{s}: {s}", .{ path, @errorName(err) });
        return error.Compile;
    };
}

fn compileImpl(
    gpa: Allocator,
    dir: Dir,
    source: [:0]const u8,
    preamble: ?[:0]const u8,
    options: *const Options,
    deps: *std.Io.Writer,
) ![]u32 {
    const stage = b: {
        if (options.compile.stage) |stage| break :b stage;

        const enum_fields = @typeInfo(Stage).@"enum".fields;
        comptime var kvs_list: [enum_fields.len]struct { []const u8, Stage } = undefined;
        inline for (enum_fields, 0..) |field, i| {
            kvs_list[i] = .{ field.name, @enumFromInt(field.value) };
        }
        const stages = std.StaticStringMap(Stage).initComptime(kvs_list);

        const period = std.mem.lastIndexOfScalar(u8, options.compile.input_path, '.') orelse {
            log.err("{s}: shader missing extension", .{options.compile.input_path});
            return error.Compile;
        };
        const extension = options.compile.input_path[period + 1 ..];
        const stage = stages.get(extension) orelse {
            log.err("{s}: unknown extension", .{options.compile.input_path});
            return error.Compile;
        };
        break :b stage;
    };

    for (options.compile.include_path) |path| {
        dir.access(path, .{}) catch |err| {
            log.err("include-path: {s}: {}", .{ path, err });
            return error.Compile;
        };
    }

    var callbacks: Callbacks = .{
        .gpa = gpa,
        .include_paths = options.compile.include_path,
        .deps = deps,
        .dir = dir,
        .allow_uppercase_paths = options.compile.allow_uppercase_paths,
    };
    const input: c.glslang_input_t = .{
        .language = c.GLSLANG_SOURCE_GLSL,
        .stage = @intFromEnum(stage),
        .client = switch (options.compile.target) {
            .@"Vulkan-1.0",
            .@"Vulkan-1.1",
            .@"Vulkan-1.2",
            .@"Vulkan-1.3",
            => c.GLSLANG_CLIENT_VULKAN,
            .@"OpenGL-4.5" => c.GLSLANG_CLIENT_OPENGL,
        },
        .client_version = switch (options.compile.target) {
            .@"Vulkan-1.0" => c.GLSLANG_TARGET_VULKAN_1_0,
            .@"Vulkan-1.1" => c.GLSLANG_TARGET_VULKAN_1_1,
            .@"Vulkan-1.2" => c.GLSLANG_TARGET_VULKAN_1_2,
            .@"Vulkan-1.3" => c.GLSLANG_TARGET_VULKAN_1_3,
            .@"OpenGL-4.5" => c.GLSLANG_TARGET_OPENGL_450,
        },
        .target_language = c.GLSLANG_TARGET_SPV,
        .target_language_version = switch (options.compile.spirv_version) {
            .default => switch (options.compile.target) {
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
        .default_version = options.compile.default_version,
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

    if (c.glslang_shader_preprocess(shader, &input) != c.true) {
        try writeGlslMessages(shader, null, "preprocessor", options, true);
    }

    if (c.glslang_shader_parse(shader, &input) != c.true) {
        try writeGlslMessages(shader, null, "parser", options, true);
    }

    const program: *c.glslang_program_t = c.glslang_program_create() orelse @panic("OOM");
    defer c.glslang_program_delete(program);

    c.glslang_program_add_shader(program, shader);

    if (c.glslang_program_link(
        program,
        c.GLSLANG_MSG_SPV_RULES_BIT | c.GLSLANG_MSG_VULKAN_RULES_BIT,
    ) != c.true) {
        try writeGlslMessages(shader, program, "linker", options, true);
    }

    c.glslang_program_set_source_file(program, @intFromEnum(stage), options.compile.input_path);
    c.glslang_program_add_source_text(program, @intFromEnum(stage), source, source.len);

    var spv_options: c.glslang_spv_options_t = .{
        .generate_debug_info = options.compile.debug,
        .strip_debug_info = !options.compile.debug,
        .disable_optimizer = true,
        .optimize_size = false,
        .disassemble = false,
        .validate = true,
        .emit_nonsemantic_shader_debug_info = false,
        .emit_nonsemantic_shader_debug_source = false,
        .compile_only = false,
        .optimize_allow_expanded_id_bound = false,
    };
    c.glslang_program_SPIRV_generate_with_options(program, @intFromEnum(stage), &spv_options);

    const size = c.glslang_program_SPIRV_get_size(program);
    const buf = gpa.alloc(u32, size) catch @panic("OOM");
    errdefer gpa.free(buf);
    c.glslang_program_SPIRV_get(program, buf.ptr);

    try writeGlslMessages(shader, program, "codegen", options, false);

    return buf[0..size];
}

fn optimize(spirv: []u32, target: Target, options: Optimize) ![]u32 {
    // Set the options
    const optimizer_options = c.spvOptimizerOptionsCreate() orelse @panic("OOM");
    defer c.spvOptimizerOptionsDestroy(optimizer_options);
    c.spvOptimizerOptionsSetRunValidator(optimizer_options, false);
    c.spvOptimizerOptionsSetPreserveBindings(optimizer_options, options.preserve_bindings);
    c.spvOptimizerOptionsSetPreserveSpecConstants(optimizer_options, options.preserve_spec_constants);

    // Create the optimizer
    const optimizer = c.spvOptimizerCreate(@intFromEnum(target)) orelse @panic("OOM");
    defer c.spvOptimizerDestroy(optimizer);
    if (options.perf) c.spvOptimizerRegisterPerformancePasses(optimizer);
    if (options.size) c.spvOptimizerRegisterSizePasses(optimizer);
    if (options.robust_access) {
        assert(c.spvOptimizerRegisterPassFromFlag(optimizer, "--graphics-robust-access"));
    }

    // Run the optimizer
    var optimized_binary: c.spv_binary = null;
    if (c.spvOptimizerRun(
        optimizer,
        spirv.ptr,
        spirv.len,
        &optimized_binary,
        optimizer_options,
    ) != c.SPV_SUCCESS) @panic("spvOptimizerRun failed");
    return optimized_binary.?.*.code[0..optimized_binary.?.*.wordCount];
}

fn remap(spirv: []u32) []u32 {
    var len = spirv.len;
    if (c.glslang_remap(spirv.ptr, &len) == false) @panic("remap failed");
    return spirv[0..len];
}

fn validate(path: []const u8, spirv: []u32, target: Target, options: Validate) !void {
    const spirv_context = c.spvContextCreate(@intFromEnum(target));
    defer c.spvContextDestroy(spirv_context);
    var spirv_binary: c.spv_const_binary_t = .{
        .code = spirv.ptr,
        .wordCount = spirv.len,
    };

    const validator_options = c.spvValidatorOptionsCreate() orelse @panic("OOM");
    defer c.spvValidatorOptionsDestroy(validator_options);
    c.spvValidatorOptionsSetUniversalLimit(
        validator_options,
        c.spv_validator_limit_max_struct_members,
        options.max_struct_members,
    );
    c.spvValidatorOptionsSetUniversalLimit(
        validator_options,
        c.spv_validator_limit_max_struct_depth,
        options.max_struct_depth,
    );
    c.spvValidatorOptionsSetUniversalLimit(
        validator_options,
        c.spv_validator_limit_max_local_variables,
        options.max_local_variables,
    );
    c.spvValidatorOptionsSetUniversalLimit(
        validator_options,
        c.spv_validator_limit_max_global_variables,
        options.max_global_variables,
    );
    c.spvValidatorOptionsSetUniversalLimit(
        validator_options,
        c.spv_validator_limit_max_switch_branches,
        options.max_switch_branches,
    );
    c.spvValidatorOptionsSetUniversalLimit(
        validator_options,
        c.spv_validator_limit_max_function_args,
        options.max_function_args,
    );
    c.spvValidatorOptionsSetUniversalLimit(
        validator_options,
        c.spv_validator_limit_max_control_flow_nesting_depth,
        options.max_control_flow_nesting_depth,
    );
    c.spvValidatorOptionsSetUniversalLimit(
        validator_options,
        c.spv_validator_limit_max_access_chain_indexes,
        options.max_access_chain_indexes,
    );
    c.spvValidatorOptionsSetUniversalLimit(
        validator_options,
        c.spv_validator_limit_max_id_bound,
        options.max_id_bound,
    );
    c.spvValidatorOptionsSetRelaxStoreStruct(
        validator_options,
        options.relax_struct_store,
    );
    c.spvValidatorOptionsSetRelaxLogicalPointer(
        validator_options,
        options.relax_logical_pointer,
    );
    c.spvValidatorOptionsSetRelaxBlockLayout(
        validator_options,
        options.relax_block_layout,
    );
    c.spvValidatorOptionsSetUniformBufferStandardLayout(
        validator_options,
        options.uniform_buffer_standard_layout,
    );
    c.spvValidatorOptionsSetScalarBlockLayout(
        validator_options,
        options.scalar_block_layout,
    );
    c.spvValidatorOptionsSetWorkgroupScalarBlockLayout(
        validator_options,
        options.workgroup_scalar_block_layout,
    );
    c.spvValidatorOptionsSetSkipBlockLayout(
        validator_options,
        options.skip_block_layout,
    );
    c.spvValidatorOptionsSetAllowLocalSizeId(
        validator_options,
        options.allow_local_size_id,
    );
    c.spvValidatorOptionsSetAllowOffsetTextureOperand(
        validator_options,
        options.allow_offset_texture_operand,
    );
    c.spvValidatorOptionsSetAllowVulkan32BitBitwise(
        validator_options,
        options.allow_vulkan32_bit_bitwise,
    );
    c.spvValidatorOptionsSetBeforeHlslLegalization(
        validator_options,
        options.before_hlsl_legalization,
    );
    c.spvValidatorOptionsSetFriendlyNames(
        validator_options,
        options.friendly_names,
    );

    var spirv_diagnostic: [8]c.spv_diagnostic = .{null} ** 8;
    if (c.spvValidateWithOptions(
        spirv_context,
        validator_options,
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
        return error.Compile;
    }
}

fn writeGlslMessageList(path: []const u8, raw: [*:0]const u8) std.enums.EnumSet(std.log.Level) {
    var levels: std.enums.EnumSet(std.log.Level) = .initEmpty();
    const span = std.mem.span(raw);
    var iter = std.mem.splitScalar(u8, span, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) continue;

        const level: std.log.Level, const level_ex: []const u8, const prefix_removed = b: {
            // See `InfoSink.h`
            {
                const prefix = "WARNING: ";
                if (std.mem.startsWith(u8, line, prefix)) {
                    break :b .{ .warn, "", line[prefix.len..] };
                }
            }

            {
                const prefix = "ERROR: ";
                if (std.mem.startsWith(u8, line, prefix)) {
                    break :b .{ .err, "", line[prefix.len..] };
                }
            }

            {
                const prefix = "INTERNAL ERROR: ";
                if (std.mem.startsWith(u8, line, prefix)) {
                    break :b .{ .err, "internal error: ", line[prefix.len..] };
                }
            }

            {
                const prefix = "UNIMPLEMENTED: ";
                if (std.mem.startsWith(u8, line, prefix)) {
                    break :b .{ .err, "unimplemented: ", line[prefix.len..] };
                }
            }

            {
                const prefix = "NOTE: ";
                if (std.mem.startsWith(u8, line, prefix)) {
                    break :b .{ .info, "note: ", line[prefix.len..] };
                }
            }

            break :b .{ .info, "", line };
        };

        levels.insert(level);

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
        const format = "{s}:{s} {s}{s}";
        const args = .{ path, location, level_ex, message };
        switch (level) {
            inline else => |l| std.options.logFn(l, log_scope, format, args),
        }
    }
    return levels;
}

fn writeGlslMessages(
    shader: ?*c.struct_glslang_shader_s,
    program: ?*c.glslang_program_t,
    step: []const u8,
    options: *const Options,
    fatal: bool,
) !void {
    var levels: std.enums.EnumSet(std.log.Level) = .initEmpty();
    if (shader) |s| {
        levels.setUnion(
            writeGlslMessageList(options.compile.input_path, c.glslang_shader_get_info_log(s)),
        );
    }
    if (program) |p| {
        levels.setUnion(
            writeGlslMessageList(options.compile.input_path, c.glslang_program_get_info_log(p)),
        );
        if (c.glslang_program_SPIRV_get_messages(program)) |msgs| {
            levels.setUnion(writeGlslMessageList(options.compile.input_path, msgs));
        }
    }

    if (levels.contains(.err)) {
        log.err("{s}: {s} failed", .{ options.compile.input_path, step });
        return error.Compile;
    } else if (fatal) {
        @panic("glslang reported a fatal error with no errors");
    }

    if (levels.contains(.warn) and options.compile.warnings_as_errors) {
        log.err("{s}: encountered warnings without disabling warnings as errors", .{
            options.compile.input_path,
        });
        return error.Compile;
    }
}

const Callbacks = struct {
    gpa: std.mem.Allocator,
    include_paths: []const []const u8,
    deps: *std.Io.Writer,
    dir: Dir,
    allow_uppercase_paths: bool,

    pub fn includeSystem(
        ctx: ?*anyopaque,
        header_path_c: [*c]const u8,
        includer_name: [*c]const u8,
        depth: usize,
    ) callconv(.c) ?*c.glsl_include_result_t {
        const self: *Callbacks = @ptrCast(@alignCast(ctx));
        const header_path = std.mem.span(header_path_c);
        _ = includer_name;

        if (!self.checkDepthAndPath(depth, header_path, true)) return null;

        if (self.include_paths.len == 0) {
            log.err("include path not set", .{});
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
    ) callconv(.c) ?*c.glsl_include_result_t {
        const self: *Callbacks = @ptrCast(@alignCast(ctx));
        const header_name = std.mem.span(header_name_c);
        const includer_name = std.mem.span(includer_name_c);

        if (!self.checkDepthAndPath(depth, header_name, false)) return null;

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
    ) callconv(.c) c_int {
        const ctx: *const Callbacks = @ptrCast(@alignCast(ctx_c));
        const result = &results[0];
        ctx.gpa.free(@as([:0]const u8, @ptrCast(result.header_data[0..result.header_length])));
        ctx.gpa.free(std.mem.span(result.header_name));
        ctx.gpa.destroy(result);
        return 0;
    }

    fn checkDepthAndPath(
        self: *const @This(),
        depth: usize,
        path: []const u8,
        diagnostic: bool,
    ) bool {
        if (depth > max_include_depth) {
            log.err("exceeded max include depth ({})", .{max_include_depth});
            return false;
        }

        return checkPath(
            if (diagnostic) "include path" else null,
            path,
            self.allow_uppercase_paths,
        );
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

        // Attempt to read the
        const source = self.dir.readFileAllocOptions(
            path,
            self.gpa,
            .unlimited,
            .@"1",
            0,
        ) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => {
                log.err("{s}: {s}", .{ path, @errorName(err) });
                return null;
            },
        };

        // Write the include path to the deps file
        {
            self.deps.writeAll("\\\n    ") catch |err| cppPanic(@errorName(err));
            writeDepPath(self.deps, path) catch |err| cppPanic(@errorName(err));
            self.deps.writeByte(' ') catch |err| cppPanic(@errorName(err));
        }

        // Return the result
        const result = self.gpa.create(c.glsl_include_result_t) catch cppPanic("OOM");
        result.* = .{
            .header_name = self.gpa.dupeZ(u8, header_path) catch cppPanic("OOM"),
            .header_data = source.ptr,
            .header_length = source.len,
        };
        return result;
    }
};

/// This check is more conservative than the spec calls for, but many of the other allowed
/// characters are not supported by many file systems anyway.
fn checkPath(diagnostic: ?[]const u8, path: []const u8, allow_uppercase: bool) bool {
    var lastWasSlash = false;
    for (path) |char| {
        switch (char) {
            '/' => if (lastWasSlash) {
                if (diagnostic) |source| {
                    log.err("{s}: {s} contains illegal substring: \"//\"", .{ path, source });
                }
                return false;
            } else {
                lastWasSlash = true;
            },
            'a'...'z', '-', '_', '0'...'9', '.', ' ' => lastWasSlash = false,
            'A'...'Z' => if (!allow_uppercase) {
                if (diagnostic) |source| {
                    log.err(
                        "{s}: {s} contains upper case characters without uppercase path support enabled",
                        .{ path, source },
                    );
                }
                return false;
            },
            else => {
                if (diagnostic) |source| {
                    log.err("{s}: {s} contains illegal character: '{c}'", .{ path, source, char });
                }
                return false;
            },
        }
    }

    return true;
}

/// Writes a path to a dep file, escaping spaces. Assumes the path contains no characters that
/// require escaping other than spaces.
fn writeDepPath(deps: *std.Io.Writer, path: []const u8) !void {
    for (path) |char| {
        if (char == ' ') {
            try deps.writeByte('\\');
        }
        try deps.writeByte(char);
    }
}
