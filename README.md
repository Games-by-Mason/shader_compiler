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

# `GL_ARB_shading_language_include`

glslang supports the [`GL_ARB_shading_language_include`](https://registry.khronos.org/OpenGL/extensions/ARB/ARB_shading_language_include.txt) extension. You can enable it in your shaders like this:

```glsl
#extension GL_ARB_shading_language_include : require
```

Once enabled, the shader compiler supports preprocessor include:

```glsl
#include "foo.glsl" // Searches the user include path, then the system include path
#include <bar/baz.glsl> // Just searches the system include path
```

To use this feature, you must set the user and system include paths with "--user-include-path" and "--system-include-path". These arguments accumulate, if you set them multiple times earlier paths are searched first.

Command line:
```
zig build run -- --target Vulkan-1.3 --user-include-path user --system-include-path system shader.vert shader.spv
```

Zig build system, note the deps file argument for proper cache invalidation:
```zig
compile_shader.addArg("--user-include-path");
compile_shader.addDirectoryArg(b.path("user"));
compile_shader.addArg("--system-include-path");
compile_shader.addDirectoryArg(b.path("system"));
compile_shader.addArg("--write-deps");
_ = compile_shader.addDepFileOutputArg("deps.d");
```

WIP:
* Test in engine
    * Need to add deps file
        * [x] Get first pass working
        * [ ] escape spaces in paths with backslash
        * [ ] Consider standard syntax (-MMD or -MF or something?)
            * Update instructions if we change this
    * [ ] Try to get rid of branch eval quote change
* Consider updating dependencies
