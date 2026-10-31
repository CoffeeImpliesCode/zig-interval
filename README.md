# zig-interval

Closed-interval arithmetic over `f64`, n-dimensional boxes, and a
Fourier–Motzkin solver for linear inequalities with interval coefficients.
Experimental. Requires Zig 0.17.0; the library has no external dependencies.

## Build and test

```sh
zig build
zig build test
zig build docs
zig build consumer
zig build test-compile
zig build bench
```

`test` runs the unit tests, soundness checks, committed MPFR corpus, and external
consumer fixture. `test-compile` compiles the suite without executing it.
`docs` writes API documentation to `zig-out/docs`.
`bench` runs all benchmarks; `bench-scalar`, `bench-vec`, and `bench-lp` run them
separately. Benchmark executables use ReleaseFast.

## Add a dependency

From your project's directory:

```sh
zig fetch --save git+https://github.com/CoffeeImpliesCode/zig-interval
```

The command writes the URL and content hash to `build.zig.zon`. In `build.zig`:

```zig
const target = b.standardTargetOptions(.{});
const optimize = b.standardOptimizeOption(.{});
const dep = b.dependency("zig_interval", .{ .target = target, .optimize = optimize });
const exe = b.addExecutable(.{
    .name = "app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
exe.root_module.addImport("interval", dep.module("interval"));
b.installArtifact(exe);
```

The public module and installed library artifact are both named `interval`.
The consumer fixture resolves both through the dependency graph.

## Use

```zig
const interval = @import("interval");
const Interval = interval.Interval;

const a = Interval.init(1.0, 3.0);
const b = Interval.init(2.0, 5.0);
const total = a.add(b); // encloses [3, 8]
const shared = a.intersect(b); // [2, 3]
const rooted = interval.sqrt(Interval.init(4.0, 9.0)); // encloses [2, 3]
```

- `Interval` provides arithmetic, set operations, comparisons, and geometry.
- Elementary functions are free functions under `interval` and `interval.ext`.
- `Vec(n)` stores a fixed-size box. `DynVec` owns a runtime-sized box, stores its
  allocator, and requires `deinit`.
- `mapResult` applies a scalar interval function to a box.
- `interval.lp` exports `System`, `Lin`, `Cmp`, `Part`, and `Partition`.
- `nextUp` and `prevDown` return strict floating-point neighbours.
  `roundUp` and `roundDown` widen computed endpoints. `piDown` and `piUp`
  bracket π.

See the generated API documentation and `fixture/src/` for complete examples.

## Numerical contract

`Interval.init(lo, hi)` requires ordered, non-NaN endpoints. Use `null` for an
empty result; `[-inf, inf]` represents the whole real line. Division by an
interval containing zero returns the whole line. Elementary functions clip
partly valid domains and return `null` for wholly invalid domains; `powf`
rejects negative bases. Set operations select existing endpoints. Comparisons
such as `lt` express a relation that holds for every point in the operands.

Arithmetic widens IEEE 754 results outward. This relies on correctly rounded
basic arithmetic and strict floating-point evaluation. The elementary functions
use `std.math` with a three-ULP outward margin. That margin comes from sampled
error measurements, not a proof over all inputs. Do not treat those functions
as formally verified enclosures. `powf` composes interval `log`, multiplication,
and `exp`, rather than applying a fixed margin to `std.math.pow`.

`scale` encloses its intermediate midpoint and half-width before combining
them. [The enclosure argument](docs/scale-enclosure.md) explains why widening
only the final rounded result is insufficient.

## Layout

- `src/`: intervals, rounding, boxes, elementary functions, and solver.
- `tests/`: unit tests, soundness oracles, and committed reference corpus.
- `fixture/`: external-package usage examples.
- `bench/`: scalar, vector, and solver benchmarks.
- `scripts/gen_corpus.c`: optional MPFR corpus generator; existing tests use the
  committed corpus and do not require MPFR.
- `tools/quality/`: pinned external analyzer sources, patches, and harnesses.
  zbc uses Zig 0.17.0 to match the project parser; the other three analyzers
  retain their Zig 0.16.0 build compiler. Both toolchains are digest-pinned in CI.

## License

MIT, see [LICENSE](LICENSE).
