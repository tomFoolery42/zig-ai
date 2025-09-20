const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("zig-ai", .{
        .root_source_file = b.path("src/llm.zig"),
        .target = target,
        .optimize = optimize,
    });

    const stream_module = b.addModule("stream-cli", .{
        .root_source_file = b.path("examples/stream-cli.zig"),
        .target = target,
        .optimize = optimize,
    });

    const stream_example = b.addExecutable(.{
        .name = "stream-cli",
        .root_module = stream_module,
    });
    stream_example.root_module.addImport("zig-ai", module);
}
