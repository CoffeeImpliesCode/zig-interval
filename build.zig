const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Child probes need the same user-mode emulator as their test parent.
    // A host can run a test through QEMU without a binfmt handler for its
    // children. cross-test supplies this runner explicitly.
    const probe_runner_options = b.addOptions();
    const runner_kind = b.graph.environ_map.get("CROSS_TEST_RUNNER_KIND") orelse "";
    const runner_reason = b.graph.environ_map.get("CROSS_TEST_RUNNER_REASON") orelse "";
    const probe_runner = if (std.mem.eql(u8, runner_kind, "exec") and
        std.mem.startsWith(u8, runner_reason, "qemu_user"))
        b.graph.environ_map.get("CROSS_TEST_RUNNER")
    else
        null;
    probe_runner_options.addOption(?[]const u8, "runner", probe_runner);

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
    vector_tests.root_module.addOptions("probe_runner_options", probe_runner_options);
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

    // The corpus tier is a separate binary from the in-tree oracle, for the
    // reason the corpus file's own header gives: its reference is not written
    // in this tree. It is MPFR, at 256 bits, via scripts/gen_corpus.c, and the
    // corpus is committed rather than generated at test time — a test that
    // shells out to a C library is not a gate.
    const corpus_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/corpus_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    corpus_tests.root_module.addImport("interval", interval);
    const run_corpus_tests = b.addRunArtifact(corpus_tests);
    test_step.dependOn(&run_corpus_tests.step);

    // The extracted exact-arithmetic block's own tests take `lp_exact` as
    // their ONLY project module and construct no `System` at all. That is the
    // observable proof the block is pure: no allocator is named anywhere in
    // the compilation, and every question is put to a function of its
    // arguments rather than reached by driving the solver.
    //
    // It is a separate module rather than another import on `interval`,
    // because `interval` already reaches `lp_exact.zig` by relative path and
    // registering the same file twice is a hard "file exists in modules"
    // error.
    const lp_exact_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/lp_exact_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    lp_exact_tests.root_module.addImport("lp_exact", b.createModule(.{
        .root_source_file = b.path("src/lp_exact.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const run_lp_exact_tests = b.addRunArtifact(lp_exact_tests);
    test_step.dependOn(&run_lp_exact_tests.step);

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

    // The probe's built path, as a compile-time constant the soundness
    // reproducers test hands to `std.process.Child`. An options module rather
    // than a run-step environment variable, so the path is right however the
    // test binary is launched, and `addOptionPath` records the dependency:
    // the probe cannot be missing or stale when the test that runs it
    // executes.
    const nan_probe_options = b.addOptions();
    nan_probe_options.addOptionPath("probe_path", nan_probe.getEmittedBin());

    // The soundness oracle is FOUR test binaries rather than one, one per
    // concern: the tanh band and the reference it pins, the random sweeps,
    // the directed frontier sweep, and the named reproducers and guards.
    //
    // They are SIBLINGS over one shared module, `tests/soundness_shared.zig`,
    // and not a chain, and the reason is a property of `zig test` rather than
    // a preference: it collects the tests of EVERY file the root reaches,
    // imported or not, so a concern file that `@import`ed another concern
    // file would run that file's tests a second time and print its report
    // twice. Four roots over one vocabulary runs each of the sixty-eight
    // tests exactly once, in exactly one binary, which is what the single
    // binary did before the split.
    //
    // Each takes the same public `interval` module the other tests do, for
    // the reason given at the top of this file: a second registration of
    // any file under `src/` is a hard "file exists in modules" error.
    const soundness_reference_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/soundness_reference_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    soundness_reference_tests.root_module.addImport("interval", interval);
    const run_soundness_reference_tests = b.addRunArtifact(soundness_reference_tests);
    test_step.dependOn(&run_soundness_reference_tests.step);

    const soundness_fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/soundness_fuzz_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    soundness_fuzz_tests.root_module.addImport("interval", interval);
    const run_soundness_fuzz_tests = b.addRunArtifact(soundness_fuzz_tests);
    test_step.dependOn(&run_soundness_fuzz_tests.step);

    const soundness_frontier_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/soundness_frontier_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    soundness_frontier_tests.root_module.addImport("interval", interval);
    const run_soundness_frontier_tests = b.addRunArtifact(soundness_frontier_tests);
    test_step.dependOn(&run_soundness_frontier_tests.step);

    // The NaN-scalar trap is the one thing in the four that reaches for a
    // build option, and it is the whole reason this step is declared here
    // rather than beside its three siblings: `runProbe` spawns
    // `tests/nan_probe.zig` and reads the probe's built path out of
    // `nan_probe_options`, and on a cross target the child needs the same
    // user-mode emulator as this test binary. The other three reach for
    // nothing but `interval`.
    const soundness_reproducers_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/soundness_reproducers_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    soundness_reproducers_tests.root_module.addImport("interval", interval);
    soundness_reproducers_tests.root_module.addOptions("probe_runner_options", probe_runner_options);
    soundness_reproducers_tests.root_module.addOptions("nan_probe_options", nan_probe_options);
    const run_soundness_reproducers_tests = b.addRunArtifact(soundness_reproducers_tests);
    test_step.dependOn(&run_soundness_reproducers_tests.step);

    // Compile the same test artifacts without run steps or the host consumer.
    // The installed library is the cross-test artifact; the test dependencies
    // force analysis and code generation of the exercised public operations.
    const compile_step = b.step("test-compile", "Compile the library and complete test suite without running");
    compile_step.dependOn(b.getInstallStep());
    for ([_]*std.Build.Step.Compile{
        tests,
        rounding_tests,
        ext_tests,
        vector_tests,
        lp_tests,
        corpus_tests,
        lp_exact_tests,
        soundness_reference_tests,
        soundness_fuzz_tests,
        soundness_frontier_tests,
        soundness_reproducers_tests,
        nan_probe,
    }) |artifact| compile_step.dependOn(&artifact.step);

    // The fixture is a real external package: it declares this one as a
    // dependency and resolves `interval` through the module graph, which the
    // internal test above cannot exercise because it is handed the module
    // object directly.
    //
    // The nested build gets private cache directories, and NOT because a
    // shared global cache would deadlock: `Cache.Manifest.hit` locks ONE
    // manifest file at a time, with `lock_nonblocking = want_shared_lock`,
    // which defaults to true and downgrades to a shared lock for the rest
    // of the build, so a parent and a nested build can share one global
    // cache. Dropping both flags and leaving the nested build on the
    // parent's default global cache finishes in about the same time and
    // reports the same result. The flags are kept for containment, which
    // is the real reason: the nested build's artifacts must not join the
    // machine-wide cache this build shares with every other project, and
    // must not disappear when this build's output is removed.
    //
    // Containment used to be achieved by RELATIVE paths - `.zig-cache` and
    // `.zig-cache/global` - resolved against the working directory set on
    // the child, so the fixture's output landed in `fixture/.zig-cache` and
    // "went away with it". That put build artifacts inside the repository,
    // and the containment estimate above was wrong by more than an order
    // of magnitude. A large generated `builtin.zig` inside the working
    // tree is also what the fmt and lint steps used to walk, which is why
    // they reported unformatted files and lint findings that were all
    // copies of the compiler's own output rather than problems in this
    // repository's sources.
    //
    // So: absolute paths, outside the repository wherever the machine has
    // local storage to put them, chosen by `consumerCacheRoot`. The
    // containment property is unchanged and now actually holds, because
    // nothing the nested build writes to a CACHE lands in `fixture/` or in
    // any other directory `build.zig.zon`'s `.paths` walks.
    //
    // Caches are what moved. The install output has always been relative:
    // no `--prefix` is passed and this step's cwd is `fixture/`, so it is
    // `fixture/zig-out` - two small binaries, ignored by git, and covered by
    // the recursive `fixture` entry in `.paths` exactly as it was before.
    // The bulk of the output that made that entry a problem, described
    // above, was cache output, and cache output is what this moved.
    //
    // Set ZIG_INTERVAL_CONSUMER_CACHE to choose the location. Where that
    // is not set, the helper reuses the cache directory THIS build was
    // given, which on a plain CI runner with no --cache-dir is inside the
    // tree. That is the point of it: the nested caches then land beside
    // the parent's own output in a directory that is already ignored,
    // instead of in a storage location this build invented for itself at
    // the last moment.
    const consumer_root = consumerCacheRoot(b);
    const run_consumer = b.addSystemCommand(&.{ "zig", "build", "run", "--cache-dir" });
    run_consumer.addDirectoryArg2(consumer_root.path(b, "zig-interval-consumer"), .{ .make_absolute = true });
    run_consumer.addArg("-Doptimize=safe");
    // Required, and easy to lose: it is what makes the nested build find
    // fixture/build.zig rather than this one. Without it the child runs in the
    // repository root, picks up the root build script, and fails with
    // `no step named 'run'` - which reads like a missing step rather than a
    // missing working directory.
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
    // The benchmarks take the public `interval` module, the one every
    // other artifact takes, and no second registration is needed to pin
    // the mode. The rule is that a compilation is compiled in the mode of
    // its ROOT module: a module's own `.optimize` does not choose the
    // machine code its files are compiled into, it only decides what
    // `builtin.mode` reads inside that module. With a root in one mode
    // importing a module declared in another, a root at ReleaseFast emits
    // no safety check for an imported module that
    // declared Debug or ReleaseSafe, and a root at Debug or ReleaseSafe
    // emits one, and panics, for an imported module that declared
    // ReleaseFast. Each of the three executables below is its own
    // compilation and its root module is already ReleaseFast, so the
    // library compiles in ReleaseFast with or without a private
    // registration: the three emitted binaries hash the same either way.
    // To pin a mode, pin the root module, which is what these three
    // already do; a second registration of `src/root.zig` would be
    // redundant, and it is also the "file exists in modules" error the
    // comment at the top of this file warns about the moment any two of
    // these compilations are merged into one.

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
    bench_scalar.root_module.addImport("interval", interval);

    const bench_vec = b.addExecutable(.{
        .name = "bench-vec",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench_vec.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    bench_vec.root_module.addImport("interval", interval);

    const bench_lp = b.addExecutable(.{
        .name = "bench-lp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench_lp.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    bench_lp.root_module.addImport("interval", interval);

    const accounting_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench_lp.zig"),
            .target = target,
            .optimize = .debug,
        }),
    });
    accounting_tests.root_module.addImport("interval", interval);
    b.step("bench-accounting-test", "Check allocator-state-independent accounting").dependOn(
        &b.addRunArtifact(accounting_tests).step,
    );

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

    // The combined step above takes no argument and runs all three in
    // parallel, so it cannot name one benchmark on its own. These three
    // steps exist so a single benchmark can be run, and timed, on its own:
    // the LP benchmark's measurements sit next to a row budget that can be
    // tightened independently, and the other two stay runnable while the LP
    // budget is still being worked on.
    //
    // An earlier version of this comment claimed there was a SECOND guard
    // here, "an address-space limit around the step that runs it". There is
    // no such limit, and there never was in this file: the `ulimit -v` recipe
    // was removed as actively wrong, because the compiler inherits the limit
    // and dies with OutOfMemory while COMPILING, before a benchmark row runs.
    // The row budget inside bench/bench_lp.zig limits the benchmark work, and
    // it is already a step of the combined `bench` step. These three steps
    // add isolation, not protection.
    //
    // Pure aliases. Each one names a run step that already exists, so
    // nothing is built, compiled or installed differently, and the combined
    // `bench` step still depends on all three and still runs them in
    // parallel.
    const bench_scalar_step = b.step("bench-scalar", "Run the scalar benchmarks");
    bench_scalar_step.dependOn(&run_bench_scalar.step);

    const bench_vec_step = b.step("bench-vec", "Run the vector benchmarks");
    bench_vec_step.dependOn(&run_bench_vec.step);

    const bench_lp_step = b.step("bench-lp", "Run the Fourier-Motzkin benchmarks");
    bench_lp_step.dependOn(&run_bench_lp.step);
}

/// Root for the nested consumer's caches, resolved at make time.
fn consumerCacheRoot(b: *std.Build) std.Build.LazyPath {
    if (b.graph.environ_map.get("ZIG_INTERVAL_CONSUMER_CACHE")) |path| {
        if (path.len != 0) return b.graph.cwdRelativePath(path);
    }
    return .cache_root;
}
