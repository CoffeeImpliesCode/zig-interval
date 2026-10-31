const std = @import("std");
const Step = std.Build.Step;
const Run = Step.Run;

// The build graph keeps its compile dependencies when a foreign run is skipped.
pub fn configure(b: *std.Build) !void {
    // Runner selection is environment-driven, outside the configure cache key.
    if (@hasDecl(std.Build.Graph, "poisonCache")) b.graph.poisonCache();
    const environment = &b.graph.environ_map;
    const kind_text = environment.get("CROSS_TEST_RUNNER_KIND") orelse return error.MissingRunnerKind;
    const kind = std.meta.stringToEnum(RunnerKind, kind_text) orelse return error.InvalidRunnerPolicy;
    if (kind == .native) return;
    const query = try std.Target.Query.parse(.{
        .arch_os_abi = environment.get("CROSS_TEST_TARGET") orelse return error.MissingCrossTarget,
    });
    const policy: Policy = .{
        .arch = query.cpu_arch orelse return error.MissingCrossArch,
        .os = query.os_tag orelse return error.MissingCrossOs,
        .kind = kind,
        .runner = environment.get("CROSS_TEST_RUNNER") orelse "",
        .reason = environment.get("CROSS_TEST_RUNNER_REASON") orelse "",
    };
    const arena = b.allocator;
    var visited: std.AutoHashMapUnmanaged(*Step, void) = .empty;
    defer visited.deinit(arena);
    var pending: std.ArrayList(*Step) = .empty;
    defer pending.deinit(arena);
    for (b.top_level_steps.values()) |top_level| {
        try pending.append(arena, &top_level.step);
    }
    while (pending.pop()) |step| {
        const entry = try visited.getOrPut(arena, step);
        if (entry.found_existing) continue;
        try pending.appendSlice(arena, step.dependencies.items);
        if (step.cast(Run)) |run| try configureRun(run, &policy);
    }
}

const RunnerKind = enum { native, unavailable, exec };

const Policy = struct {
    arch: std.Target.Cpu.Arch,
    os: std.Target.Os.Tag,
    kind: RunnerKind,
    runner: []const u8,
    reason: []const u8,
};

fn configureRun(run: *Run, policy: *const Policy) !void {
    if (run.argv.items.len == 0) return;
    const executable = switch (run.argv.items[0]) {
        .artifact => |argument| argument.artifact,
        else => return, // Keep explicit project command prefixes and system commands.
    };
    const target = executable.root_module.resolved_target.?.result;
    if (target.cpu.arch != policy.arch or target.os.tag != policy.os) return;
    if (policy.kind == .unavailable) {
        skipForeignRunPolicy(run);
        return;
    }
    if (policy.runner.len == 0) {
        return error.InvalidRunnerPolicy;
    }

    const b = run.step.owner;
    var prefix: [3]Run.Arg = undefined;
    // Byte arguments are read-only during execution. These strings outlive the graph.
    prefix[0] = .{ .bytes = @constCast(policy.runner) };
    var prefix_count: usize = 1;
    if (std.mem.startsWith(u8, policy.reason, "qemu_user")) {
        const links_libc = if (@hasField(@TypeOf(executable.*), "is_linking_libc"))
            executable.is_linking_libc
        else
            executable.dependsOnSystemLibrary("c");
        const needs_loader = links_libc and
            (target.isGnuLibC() or
                (target.isMuslLibC() and executable.linkage == .dynamic));
        if (needs_loader) {
            const runtimes = (if (@hasField(std.Build, "libc_runtimes_dir"))
                b.libc_runtimes_dir
            else
                b.graph.environ_map.get("CROSS_TEST_LIBC_RUNTIMES")) orelse {
                skipForeignRunPolicy(run);
                return;
            };
            const triple = if (target.isGnuLibC())
                try std.zig.target.glibcRuntimeTriple(
                    b.allocator,
                    target.cpu.arch,
                    target.os.tag,
                    target.abi,
                )
            else
                try std.zig.target.muslRuntimeTriple(b.allocator, target.cpu.arch, target.abi);
            prefix[1] = .{ .bytes = @constCast("-L") };
            prefix[2] = .{ .bytes = b.pathJoin(&.{ runtimes, triple }) };
            prefix_count = 3;
        }
    } else if (std.mem.eql(u8, policy.reason, "wasmtime")) {
        prefix[1] = .{ .bytes = @constCast("--dir=.") };
        prefix[2] = .{ .bytes = @constCast("-Sinherit-env") };
        prefix_count = 3;
    } else if (std.mem.startsWith(u8, policy.reason, "wine")) {
        if (b.graph.environ_map.get("WINEDEBUG") == null) {
            run.setEnvironmentVariable("WINEDEBUG", "-all");
        }
    }
    // Force the detected executor instead of relying on kernel binfmt or x86 compatibility.
    try run.argv.insertSlice(b.allocator, 0, prefix[0..prefix_count]);
}

fn skipForeignRunPolicy(run: *Run) void {
    if (@hasField(Step, "makeFn")) {
        run.step.makeFn = skipForeignRun;
    } else {
        // Preserve MakeSkipped across the configurer/maker boundary, even
        // when binfmt_misc would try the wrong operating system's executable.
        run.setEnvironmentVariable("CROSS_TEST_SKIP_FOREIGN", "1");
    }
}

fn skipForeignRun(_: *Step, _: Step.MakeOptions) error{MakeSkipped}!void {
    return error.MakeSkipped;
}
