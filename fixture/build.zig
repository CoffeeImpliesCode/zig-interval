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

    // The second consumer, and the reason this fixture exists twice over: the
    // README's own examples, as an executable that is compiled and run here.
    // The repository's tests are handed the `interval` module object
    // directly, so nothing in them can tell whether the code a reader copies
    // out of the README still compiles, and two of them did not.
    //
    // It is wired the way the README's `build.zig` snippet wires an
    // executable — the module created with `target` and `optimize` on it,
    // the import added afterwards with `addImport` rather than through
    // `createModule`'s `imports` field — so the snippet is compiled by this
    // file instead of only being quoted by it. Two of the lines it writes
    // down are the ones whose absence used to panic at build-script time.
    const readme = b.addExecutable(.{
        .name = "readme",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/readme.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    readme.root_module.addImport("interval", dep.module("interval"));
    b.installArtifact(readme);

    const run_readme = b.addRunArtifact(readme);
    // After the consumer rather than beside it. Two run steps with no
    // dependency on each other are independent, so the build runner may
    // start them in parallel and interleave their output; making the second
    // one depend on the first keeps the log in the order the README states
    // its examples in.
    run_readme.step.dependOn(&run.step);

    const readme_step = b.step("readme", "Run the README examples against this package");
    readme_step.dependOn(&run_readme.step);
    // `run` is what the parent build invokes, and it runs both consumers.
    run_step.dependOn(&run_readme.step);

    // The second published name, resolved for the same reason `dep.module`
    // above is called at all: this is what proves `build.zig`'s
    // `b.installArtifact` still registers a library a dependent can reach as
    // `dep.artifact("interval")`. The lookup turns a missing artifact into a
    // configure-time panic ("unable to find artifact 'interval'"), so binding
    // the result to `_` is the whole check. Nothing links it and no step
    // depends on it: a Compile nothing depends on is never built, so the
    // fixture's build graph is exactly what it was.
    _ = dep.artifact("interval");
}
