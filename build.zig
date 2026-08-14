const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lib = b.addLibrary(.{ .name = "interval", .root_module = b.createModule(.{ .root_source_file = b.path("src/interval.zig"), .target = target, .optimize = optimize }) });
    b.installArtifact(lib);
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/interval_test.zig"), .target = target, .optimize = optimize }) });
    tests.root_module.addImport("interval", lib.root_module);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run interval tests");
    test_step.dependOn(&run_tests.step);
    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);
}
