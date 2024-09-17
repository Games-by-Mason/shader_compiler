pub const c = @cImport({
    @cInclude("glslang/Include/glslang_c_interface.h");
    @cInclude("glslang/Public/resource_limits_c.h");
    @cInclude("glslang/SPIRV/spv_remapper_c_interface.h");
    @cInclude("spirv-tools/libspirv.h");
});
