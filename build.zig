const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // A public module, so a dependent package can reach it through the
    // dependency module graph with `dep.module("interval")`. `createModule`
    // would only produce a private one that no external build can name.
    const interval = b.addModule("interval", .{
        .root_source_file = b.path("src/interval.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib = b.addLibrary(.{ .name = "interval", .root_module = interval });
    b.installArtifact(lib);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/interval_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("interval", interval);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run interval tests");
    test_step.dependOn(&run_tests.step);

    // The fixture is a real external package: it declares this one as a
    // dependency and resolves `interval` through the module graph, which the
    // internal test above cannot exercise because it is handed the module
    // object directly.
    //
    // The nested build gets private cache directories. The parent build is
    // still running and holds the shared global cache lock, so reusing the
    // default global cache would deadlock. The paths are relative to the
    // working directory below, so both caches stay inside `fixture/`.
    const run_consumer = b.addSystemCommand(&.{
        "zig",
        "build",
        "run",
        "--cache-dir",
        ".zig-cache",
        "--global-cache-dir",
        ".zig-cache/global",
        "-Doptimize=ReleaseSafe",
    });
    run_consumer.setCwd(b.path("fixture"));
    const consumer_step = b.step("consumer", "Build and run the external consumer fixture");
    consumer_step.dependOn(&run_consumer.step);
    test_step.dependOn(&run_consumer.step);

    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);
}
