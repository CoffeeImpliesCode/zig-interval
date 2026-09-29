const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // A public module, so a dependent package can reach it through the
    // dependency module graph with `dep.module("interval")`. `createModule`
    // would only produce a private one that no external build can name.
    //
    // The root is `src/root.zig` because a module has exactly one root
    // file, and that file's directory is the only tree reachable by
    // relative import. Rooting the package at `src/interval.zig` would
    // leave every sibling source file invisible to consumers; the root
    // re-exports the whole surface instead.
    const interval = b.addModule("interval", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib = b.addLibrary(.{ .name = "interval", .root_module = interval });
    b.installArtifact(lib);

    // A file may belong to only one module per compilation, and the public
    // `interval` module already contains every file that `src/root.zig`
    // reaches by relative import. Registering `interval_ext.zig`, `vector.zig`
    // or `lp.zig` a second time would be a hard "file exists in modules"
    // error, so their tests import `interval` alone and use the re-exports.
    //
    // `rounding` is the one exception: its test never imports `interval`, so
    // that compilation has no overlap and the module is safe to declare.
    const rounding = b.createModule(.{
        .root_source_file = b.path("src/rounding.zig"),
        .target = target,
        .optimize = optimize,
    });

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

    const rounding_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/rounding_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    rounding_tests.root_module.addImport("rounding", rounding);
    const run_rounding_tests = b.addRunArtifact(rounding_tests);
    test_step.dependOn(&run_rounding_tests.step);

    const ext_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/interval_ext_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    ext_tests.root_module.addImport("interval", interval);
    const run_ext_tests = b.addRunArtifact(ext_tests);
    test_step.dependOn(&run_ext_tests.step);

    const vector_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/vector_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    vector_tests.root_module.addImport("interval", interval);
    const run_vector_tests = b.addRunArtifact(vector_tests);
    test_step.dependOn(&run_vector_tests.step);

    const lp_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/lp_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    lp_tests.root_module.addImport("interval", interval);
    const run_lp_tests = b.addRunArtifact(lp_tests);
    test_step.dependOn(&run_lp_tests.step);

    // The soundness oracle imports the same public `interval` module the
    // other tests do, for the reason given above: a second registration of
    // any file under `src/` is a hard "file exists in modules" error.
    const soundness_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/soundness_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    soundness_tests.root_module.addImport("interval", interval);
    const run_soundness_tests = b.addRunArtifact(soundness_tests);
    test_step.dependOn(&run_soundness_tests.step);

    // The NaN-trap probe is a separate executable rather than a test,
    // because the contract it pins is that a NaN scalar operand ABORTS, and
    // an abort inside a test binary takes every other test down with it. As
    // a child process the exit status is the signal and the abort stays
    // contained; `tests/nan_probe.zig` spells out why in full.
    //
    // Its mode is pinned to Debug whatever `-Doptimize` says, because the
    // contract is about a CHECKED build. ReleaseFast elides the `lo <= hi`
    // assert in `Interval.init` and hands back a NaN interval, so a probe
    // built in whatever mode the suite was asked for would report "no trap"
    // under ReleaseFast and fail the parent test for a reason that has
    // nothing to do with the library.
    const nan_probe = b.addExecutable(.{
        .name = "nan_probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/nan_probe.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    // The same public `interval` module the other artifacts take. The probe
    // adds no file of its own under `src/`, so no registration overlaps.
    nan_probe.root_module.addImport("interval", interval);

    // The probe's built path, as a compile-time constant the soundness test
    // hands to `std.process.Child`. An options module rather than a run-step
    // environment variable, so the path is right however the test binary is
    // launched, and `addOptionPath` records the dependency: the probe cannot
    // be missing or stale when the test that runs it executes.
    const nan_probe_options = b.addOptions();
    nan_probe_options.addOptionPath("probe_path", nan_probe.getEmittedBin());
    soundness_tests.root_module.addOptions("nan_probe_options", nan_probe_options);

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

    // Benchmarks: one executable per benchmark file, all three run by a
    // single `bench` step.
    //
    // The mode is pinned to ReleaseFast rather than taken from
    // `-Doptimize`. A figure from a Debug build of a numeric library
    // whose every operation is wrapped in assertions is mostly a figure
    // for the assertions and the register spills around them, and a
    // benchmark whose numbers move when the flag moves cannot be
    // compared with itself across a change to the library.
    //
    // The benchmarks therefore take a SECOND registration of
    // `src/root.zig`, this one private and this one at ReleaseFast,
    // because `addModule` fixes the mode at the moment the module is
    // created and the public `interval` module belongs to a library
    // built in whatever mode was asked for. Registering a file twice is
    // the error the comment at the top of this file warns about, and it
    // is not what is happening here: the constraint is one module per
    // COMPILATION, and no step in this build compiles both. Each
    // benchmark executable is its own compilation, containing its own
    // root file, `bench/timing.zig`, and this one module.
    const bench_interval = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    // `bench/timing.zig` is reached by a relative import from each
    // benchmark file and is NOT registered as a module of its own. A
    // module's root directory is the directory of its root source file,
    // and all three benchmark files live in `bench/`, so the same
    // `@import("timing.zig")` resolves from each of them exactly as
    // `@import("interval.zig")` resolves from `src/root.zig` to a
    // sibling. Registering it separately would put one file in two
    // modules of the same compilation, which is the hard error the
    // comment above is about.
    const bench_scalar = b.addExecutable(.{
        .name = "bench-scalar",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    bench_scalar.root_module.addImport("interval", bench_interval);

    const bench_vec = b.addExecutable(.{
        .name = "bench-vec",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench_vec.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    bench_vec.root_module.addImport("interval", bench_interval);

    const bench_lp = b.addExecutable(.{
        .name = "bench-lp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench_lp.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    bench_lp.root_module.addImport("interval", bench_interval);

    // The step depends on RUNNING all three, not merely on building
    // them: a benchmark nobody runs has measured nothing. Three
    // `addRunArtifact` calls and three dependencies, rather than a
    // system command per file, because a run step carries the
    // dependency on the artifact it launches and a system command would
    // have to be a second `zig run` that rebuilds the library to get
    // there. The run steps are independent, so `zig build bench` runs
    // the three in parallel.
    //
    // Nothing above depends on this step and nothing below does either:
    // `install` does not build the benchmarks, and `test` does not run
    // them. A number is not a gate, and a benchmark that took four
    // seconds would make the test suite take four seconds longer for
    // every consumer who runs it.
    const run_bench_scalar = b.addRunArtifact(bench_scalar);
    const run_bench_vec = b.addRunArtifact(bench_vec);
    const run_bench_lp = b.addRunArtifact(bench_lp);
    const bench_step = b.step("bench", "Run the scalar, vector and Fourier-Motzkin benchmarks");
    bench_step.dependOn(&run_bench_scalar.step);
    bench_step.dependOn(&run_bench_vec.step);
    bench_step.dependOn(&run_bench_lp.step);
}
