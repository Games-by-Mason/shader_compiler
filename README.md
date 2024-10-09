# Shader Compiler

A command line tool that compiles GLSL shaders to SPIRV, and optimizes them using [glslang-zig](https://github.com/Games-by-Mason/glslang-zig).

Remap is also supported (results in better compression), SPIRV is validated before results are written.

# Usage

Note that the initial compile will take quite while as it's building the shader C++ implementation of the shader compiler. Once this finishes it will be cached.

Example usage:
```sh
zig build run -- --target Vulkan-1.3 --optimize-perf input.glsl output.spv
```

Example usage from Zig's build system:

```zig
const compile_shader = b.addRunArtifact(shader_compiler_exe);
compile_shader.addArgs(&.{
    "--target", "Vulkan-1.3",
});
switch (optimize) {
    .Debug => compile_shader.addArgs(&.{
        "--robust-access",
    }),
    .ReleaseSafe => compile_shader.addArgs(&.{
        "--optimize-perf",
        "--robust-access",
    }),
    .ReleaseFast => compile_shader.addArgs(&.{
        "--optimize-perf",
    }),
    .ReleaseSmall => compile_shader.addArgs(&.{
        "--optimize-perf",
        "--optimize-small",
    }),
}
compile_shader.addFileArg(b.path(path));
return compile_shader.addOutputFileArg("compiled.spv");
```

# GL_ARB_shading_language_include

WIP:
* Don't allow using ../../ etc to go outside of the listed include directories, since this can break caching
    * Look at the resolve/abs functions
* Reuse readSource or such, maybe clean up/remove progress nodes
* Does panicking from the C callbacks work? I think no because it goes through C++, may need to use process exit in those cases
* We heap alloc the included files, may as well do the same with the normal ones
* Write up instructions here
