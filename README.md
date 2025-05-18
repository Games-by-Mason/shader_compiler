# Shader Compiler

A command line tool that compiles GLSL shaders to SPIRV, and optimizes them using [glslang-zig](https://github.com/Games-by-Mason/glslang-zig).

Remap is also supported (results in better compression), SPIRV is validated before results are written.

# Zig Version

[`main`](https://github.com/Games-by-Mason/shader_compiler/tree/main) loosely tracks Zig master. For support for Zig 0.14.0, use [v1.0.0](https://github.com/Games-by-Mason/shader_compiler/releases/tag/v0.1.0).

# Usage

Note that the initial compile will take quite while as it's building the shader C++ implementation of the shader compiler. Once this finishes it will be cached.

Example usage:
```sh
zig build run -- --target Vulkan-1.3 --optimize-perf input.glsl output.spv
```

Example usage from Zig's build system:

```zig
const compile_shader = b.addRunArtifact(shader_compiler_exe);
compile_shader.addArg("--scalar-block-layout");
compile_shader.addArgs(&.{
    "--target", "Vulkan-1.3",
});
switch (optimize) {
    .Debug => {},
    .ReleaseSafe, .ReleaseFast => compile_shader.addArgs(&.{
        "--optimize-perf",
    }),
    .ReleaseSmall => compile_shader.addArgs(&.{
        "--optimize-perf",
        "--optimize-size",
    }),
}
compile_shader.addFileArg(b.path(path));
return compile_shader.addOutputFileArg("compiled.spv");
```

# `GL_ARB_shading_language_include`

`glslang` supports `#include` via the [`GL_ARB_shading_language_include`](https://registry.khronos.org/OpenGL/extensions/ARB/ARB_shading_language_include.txt) extension. You can enable it in your shaders like this:

```glsl
#extension GL_ARB_shading_language_include : require
```

You will also need to specify at least one include path via `--include-path`. Multiple can be specified by passing the arg more than once. If calling via Zig's build system, use '--write-deps' for proper caching behavior.

Command line:
```
zig build run -- --target Vulkan-1.3 --include-path include shader.vert shader.spv
```

Zig build system:
```zig
compile_shader.addArg("--include-path");
compile_shader.addDirectoryArg(b.path("include"));
compile_shader.addArg("--write-deps");
_ = compile_shader.addDepFileOutputArg("deps.d");
```

You can now include files in your shaders:
```glsl
#include "foo.glsl"
```

For details on inclusion syntax and path resolution, see the [extension specification](https://registry.khronos.org/OpenGL/extensions/ARB/ARB_shading_language_include.txt).

