# zig-ai

A simple OpenAI API client for Zig with streaming support.

Find examples in the [`examples`](./examples) directory.

## Installation

```bash
$ zig fetch --save git+https://github.com/FOLLGAD/zig-ai
```

and add `zig-ai` to your `build.zig` file:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "stream-cli",
        .root_source_file = b.path("examples/stream-cli.zig"),
        .target = target,
        .optimize = optimize,
    });

    const module = b.dependency("zig-ai", .{
        .root_source_file = b.path("src/llm.zig"),
    });
    exe.root_module.addImport("zig-ai", module.module("zig-ai"));
}
```

## Usage

See the `examples` directory for usage examples.
