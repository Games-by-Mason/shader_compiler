const std = @import("std");
const structopt = @import("structopt");
const assert = std.debug.assert;
const log_scope = .shader_compiler;
const log = std.log.scoped(log_scope);

const shader_compiler = @import("shader_compiler");

const Allocator = std.mem.Allocator;
const Command = structopt.Command;

const Target = shader_compiler.Target;
const SpirvVersion = shader_compiler.SpirvVersion;
const Stage = shader_compiler.Stage;

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = .info,
};

const command: Command = .{
    .name = "shader_compiler",
    .named_args = &.{
        .init(Target, .{
            .long = "target",
            .short = 'c',
        }),
        .init(SpirvVersion, .{
            .long = "spirv-version",
            .default = .{ .value = .default },
        }),
        .init(bool, .{
            .long = "remap",
            .default = .{ .value = false },
        }),
        .init(bool, .{
            .long = "debug",
            .default = .{ .value = false },
        }),
        .init(bool, .{
            .long = "optimize-perf",
            .default = .{ .value = false },
        }),
        .init(bool, .{
            .long = "optimize-size",
            .default = .{ .value = false },
        }),
        .init(bool, .{
            .long = "robust-access",
            .default = .{ .value = false },
        }),
        .init(bool, .{
            .long = "preserve-bindings",
            .default = .{ .value = false },
        }),
        .init(bool, .{
            .long = "preserve-spec-constants",
            .default = .{ .value = false },
        }),
        .init(bool, .{
            .long = "relax-logical-pointer",
            .default = .{ .value = false },
        }),
        .init(bool, .{
            .long = "relax-block-layout",
            .default = .{ .value = false },
        }),
        .init(bool, .{
            .long = "uniform-buffer-standard-layout",
            .default = .{ .value = false },
        }),
        .init(bool, .{
            .long = "scalar-block-layout",
            .default = .{ .value = false },
        }),
        .init(bool, .{
            .long = "workgroup-scalar-block-layout",
            .default = .{ .value = false },
        }),
        .init(bool, .{
            .long = "skip-block-layout",
            .default = .{ .value = false },
        }),
        .init(bool, .{
            .long = "relax-struct-store",
            .default = .{ .value = false },
        }),
        .init(bool, .{
            .long = "allow-local-size-id",
            .default = .{ .value = false },
        }),
        .init(bool, .{
            .long = "allow-offset-texture-operand",
            .default = .{ .value = false },
        }),
        .init(bool, .{
            .long = "allow-vulkan32-bit-bitwise",
            .default = .{ .value = false },
        }),
        .init(bool, .{
            .long = "before-hlsl-legalization",
            .default = .{ .value = false },
        }),
        .init(bool, .{
            .long = "friendly-names",
            .default = .{ .value = true },
        }),
        .init(u32, .{
            .long = "max-struct-members",
            .default = .{ .value = 16383 },
        }),
        .init(u32, .{
            .long = "max-struct-depth",
            .default = .{ .value = 255 },
        }),
        .init(u32, .{
            .long = "max-local-variables",
            .default = .{ .value = 524287 },
        }),
        .init(u32, .{
            .long = "max-global-variables",
            .default = .{ .value = 65535 },
        }),
        .init(u32, .{
            .long = "max-switch-branches",
            .default = .{ .value = 16383 },
        }),
        .init(u32, .{
            .long = "max-function-args",
            .default = .{ .value = 255 },
        }),
        .init(u32, .{
            .long = "max-control-flow-nesting-depth",
            .default = .{ .value = 1023 },
        }),
        .init(u32, .{
            .long = "max-access-chain-indexes",
            .default = .{ .value = 255 },
        }),
        .init(u32, .{
            .long = "max-id-bound",
            .default = .{ .value = 0x3FFFFF },
        }),
        .initAccum([]const u8, .{
            .long = "include-path",
        }),
        .init(?[]const u8, .{
            .long = "write-deps",
            .default = .{ .value = null },
        }),
        .init(?Stage, .{
            .long = "stage",
            .default = .{ .value = null },
        }),
        .initAccum([]const u8, .{
            .long = "preamble",
        }),
        // Defines come after the preamble, and there's no undefine or option for the value. If you
        // need more complex define and undefine logic, you can work around this by baking it into
        // the preamble file. This limitation, in particular the ordering limitation, is due to the
        // way we handle argument parsing and may be resolved in the future:
        //
        // https://github.com/Games-by-Mason/structopt/issues/12
        .initAccum([]const u8, .{
            .long = "define",
        }),
        // Required for preamble to be useful
        .init(i32, .{
            .long = "default-version",
            .default = .{ .value = 100 },
        }),
        .init(bool, .{
            .long = "warnings-as-errors",
            .default = .{ .value = true },
        }),
    },
    .positional_args = &.{
        .init([:0]const u8, .{
            .meta = "INPUT",
        }),
        .init([:0]const u8, .{
            .meta = "OUTPUT",
        }),
    },
};

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
    shader_compiler.compile(allocator, cwd, .{
        .compile = .{
            .input_path = args.positional.INPUT,
            .output_path = args.positional.OUTPUT,
            .include_path = args.named.@"include-path".items,
            .write_deps = args.named.@"write-deps",
            .preamble = args.named.preamble.items,
            .defines = args.named.define.items,
            .default_version = args.named.@"default-version",
            .warnings_as_errors = args.named.@"warnings-as-errors",
            .target = args.named.target,
            .spirv_version = args.named.@"spirv-version",
            .stage = args.named.stage,
            .debug = args.named.debug,
        },
        .remap = args.named.remap,
        .optimize = .{
            .perf = args.named.@"optimize-perf",
            .size = args.named.@"optimize-size",
            .robust_access = args.named.@"robust-access",
            .preserve_bindings = args.named.@"preserve-bindings",
            .preserve_spec_constants = args.named.@"preserve-spec-constants",
        },
        .validate = .{
            .relax_logical_pointer = args.named.@"relax-logical-pointer",
            .relax_block_layout = args.named.@"relax-block-layout",
            .uniform_buffer_standard_layout = args.named.@"uniform-buffer-standard-layout",
            .scalar_block_layout = args.named.@"scalar-block-layout",
            .workgroup_scalar_block_layout = args.named.@"workgroup-scalar-block-layout",
            .skip_block_layout = args.named.@"skip-block-layout",
            .relax_struct_store = args.named.@"relax-struct-store",
            .allow_local_size_id = args.named.@"allow-local-size-id",
            .allow_offset_texture_operand = args.named.@"allow-offset-texture-operand",
            .allow_vulkan32_bit_bitwise = args.named.@"allow-vulkan32-bit-bitwise",
            .before_hlsl_legalization = args.named.@"before-hlsl-legalization",
            .friendly_names = args.named.@"friendly-names",
            .max_struct_members = args.named.@"max-struct-members",
            .max_struct_depth = args.named.@"max-struct-depth",
            .max_local_variables = args.named.@"max-local-variables",
            .max_global_variables = args.named.@"max-global-variables",
            .max_switch_branches = args.named.@"max-switch-branches",
            .max_function_args = args.named.@"max-function-args",
            .max_control_flow_nesting_depth = args.named.@"max-control-flow-nesting-depth",
            .max_access_chain_indexes = args.named.@"max-access-chain-indexes",
            .max_id_bound = args.named.@"max-id-bound",
        },
    }) catch std.process.exit(1);
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

    var buffer: [64]u8 = undefined;
    var stderr = std.debug.lockStderrWriter(&buffer);
    defer std.debug.unlockStderrWriter();
    nosuspend {
        var wrote_prefix = false;
        if (message_level != .info) {
            stderr.writeAll(bold ++ color ++ level_txt ++ reset) catch return;
            wrote_prefix = true;
        }
        if (message_level == .err) stderr.writeAll(bold) catch return;
        if (wrote_prefix) {
            stderr.writeAll(": ") catch return;
        }
        stderr.print(format ++ "\n", args) catch return;
        stderr.writeAll(reset) catch return;
    }
}
