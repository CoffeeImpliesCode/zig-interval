const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Resolve the parent package through the real dependency module graph.
    // dep.module("interval") panics with `unable to find module 'interval'`
    // unless the parent registers a public module, which is exactly what
    // this fixture exists to prove.
    const dep = b.dependency("zig_interval", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "interval", .module = dep.module("interval") }},
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the consumer smoke checks");
    run_step.dependOn(&run.step);
}
