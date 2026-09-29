# Performance work — handover

**Written for a future session that has none of the prior context.** Everything
needed to resume is below. If a statement here conflicts with the code, the code
wins — but check the code before trusting this file, because it describes a
moving target.

---

## 1. What this project is

`~/projects/zig-interval` — a Zig 0.16.0 library package
(`zig_interval`) doing **rigorous interval arithmetic** over `f64`.

The central claim, which everything else serves: **every operation returns a
result guaranteed to contain the true mathematical answer.** Not approximately —
*guaranteed*. If a result can be too narrow, the library is actively dangerous to
a caller doing verification, so this constraint outranks performance at every
decision point in this document.

The guarantee is obtained by computing with IEEE round-to-nearest and then
widening each endpoint outward. Zig 0.16 has no directed rounding, so the
widening helpers in `src/rounding.zig` do it with `u64` bit-pattern stepping.

Source layout, ~2600 lines total:

| File | Lines | Contents |
| --- | --- | --- |
| `src/interval.zig` | ~514 | `Interval{lo,hi}`: 15 set/geometry ops, 8 arithmetic ops, 6 certain-comparisons |
| `src/interval_ext.zig` | ~558 | 28 elementary functions, free functions |
| `src/vector.zig` | ~613 | `Vec(n)` (compile-time dim) and `DynVec` (runtime dim) boxes |
| `src/lp.zig` | ~609 | Fourier–Motzkin solver with Tupper's variable ordering |
| `src/rounding.zig` | ~176 | outward-rounding primitives, certified pi enclosure |
| `src/root.zig` | ~141 | public module root; re-exports the whole surface |

Consumers import the package as `@import("interval")`.

## 2. Where the work stands right now

The active goal is: **profile and benchmark single and vectorized usage, then
improve performance.** It is NOT finished. A previous session completed a large
soundness effort first (it is what makes the performance work safe to do) and
stopped partway through the performance phase.

### Committed and green at `8c3b2c40`

The soundness work. 228 tests across six binaries, plus 29 checks in an external
consumer fixture. `main` points here.

### Uncommitted in the working copy

Benchmark infrastructure that exists on disk but is **not yet committed**:

```
A bench/timing.zig     shared harness (written and verified by hand)
A bench/bench.zig      scalar + transcendental benchmarks
A bench/bench_vec.zig  Vec(n) and DynVec benchmarks
A bench/bench_lp.zig   Fourier-Motzkin solver benchmarks
M build.zig            registers a `bench` step
```

`zig build --list-steps` shows `bench` as a step. It is deliberately **not** a
dependency of the default `install` step nor of `test`, so it does not slow the
normal gates and does not affect cross-compilation checks.

**The baseline has not been captured.** A run was started and interrupted. Until
`zig build bench` has been run to completion and its output saved, there are no
before-numbers, and therefore no way to tell whether any optimisation helped.
That is the single most important thing the next session must do first.

## 3. The next steps, in order

### Step 1 — Capture the baseline. Do this before touching any source file.

```sh
cd ~/projects/zig-interval
mkdir -p /tmp/bl
zig build bench --cache-dir /tmp/bl/cache --global-cache-dir /tmp/bl/gcache \
  | tee /tmp/bl/baseline.txt
```

Save the output. Without it, no later claim of "faster" is evidence.

The first calibration point already observed by hand: a plain `Interval.add`
measures about **16.3 ns/op**. A raw `f64` add is a small fraction of a
nanosecond. That gap is the investigation.

### Step 2 — Confirm the harnesses actually run and produce sane numbers

Each agent that wrote a benchmark file reported results, but **the final
numbers have not been read back and checked by the orchestrator**. Do that
before optimising. Specifically check for: rows with `ns/op` of exactly 0
(dead-code elimination, the harness cannot see it), rows that are identical
across obviously different operations, and rows whose value moves when you
change nothing.

### Step 3 — Profile, then rank by measurement

Do not optimise on suspicion. These are hypotheses to confirm or discard with
the baseline in hand — several may be wrong:

| Hypothesis | Where | Why it might cost |
| --- | --- | --- |
| `roundUp`/`roundDown` not inlined | `src/rounding.zig` | called 2× per interval op; each is 3 compares plus a call into `nextUp`/`prevDown` |
| `Corner` struct cost in `mul`/`div` | `src/interval.zig` | builds a 4-element array of `{value, undersized}` then scans it twice |
| `scale` composes through other ops | `src/interval.zig` | each composed op re-widens, so `scale` may pay for redundant steps |
| `DynVec` allocates per value-returning op | `src/vector.zig` | `dv = dv.add(other)` allocates every call; `dv.iadd(other)` should not |
| `powf` now composes `exp(log(base)*y)` | `src/interval_ext.zig` | deliberately traded speed for soundness; quantify it, do not "fix" it |
| `eliminationOrder` clones the system per step | `src/lp.zig` | may cost several times a single elimination |

### Step 4 — Optimise, one change at a time, with a measurement for each

For every change: re-run `zig build bench`, and report the before/after for the
operations the change touched. A change that makes one operation faster and
another slower is a decision to make deliberately, not a win.

### Step 5 — The soundness gate. This is not optional and not negotiable.

`tests/soundness_test.zig` computes true extrema in `f128` from the ORIGINAL
`f64` inputs and checks containment. It exists because a previous audit found
four soundness defects that 200 tests and 29 consumer checks all passed.

**Every optimisation must leave it green.** It is the only thing standing
between a faster library and a wrong one.

```sh
zig build test
```

If an optimisation makes it fail, the optimisation is wrong. Do not relax the
oracle to accommodate a speedup. If you believe the oracle is wrong, prove it
against `tests/soundness_test.zig` plus a throwaway `f128` check of your own
before changing anything.

### Step 6 — Full verification, then commit

```sh
zig build test                                          # all suites + consumer
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build test -Doptimize=ReleaseSmall
zig build docs
zig fmt --check build.zig build.zig.zon src tests fixture
```

Cross-targets (`zig build -Dtarget=aarch64-linux` etc.) are worth re-running
before any commit that changes build wiring, not on every change.

Then commit, and move `main`.

## 4. Hard constraints

1. **Soundness outranks speed.** A result that can be too narrow is worse than
   a slow result. When the two conflict, the oracle decides and speed loses.
2. **Do not change numerics to gain speed.** A faster path that computes
   something slightly different is a different function, and the guarantee is
   about the function as specified.
3. **Benchmarks are ReleaseFast only.** Debug numbers for an assert-heavy
   numeric library mostly measure the asserts.
4. **Keep `nextUp`/`prevDown` as the strict neighbours.** They are used where a
   strict neighbour is genuinely wanted. `roundUp`/`roundDown` are the
   outward-rounding forms and differ from them at exactly the signed zeros.
5. **Do not "simplify away" the widening.** The extra ULP of width is the price
   of soundness and is deliberate. It looks like waste and is not.

## 5. Toolchain gotchas — these cost real time to rediscover

All verified empirically on this machine.

- `std.time.Timer` **does not exist** in Zig 0.16. Timing is
  `std.Io.Clock.real.now(io)`, which returns a plain `Timestamp` (no error
  union — do not `try` it). Get an `Io` with
  `std.Io.Threaded.init(gpa, .{})` then `threaded.io()`. Passing `std.Io` as a
  `main` parameter is **not** supported (`start.zig` wants an `Io.minimal` field
  that does not exist).
- `std.posix.clock_gettime` and `std.c.clock_gettime` are both awkward —
  the former is gone, the latter needs libc linked.
- `std.ArrayList` is **unmanaged**: `std.ArrayList(T){}` / `.empty`,
  `append(gpa, x)`, `deinit(gpa)`. There is no `.init(gpa)`.
- `**` is **array repetition**, not exponentiation. Use `std.math.pow`.
- `2.0 ** -38` will not compile; `std.math.pow(f64, 2.0, -38)` will.
- `@field` is lowercase. `@Field` does not exist.
- `std.fs.File` does not exist; use `std.debug.print`.
- `std.math.maxFloat` does not exist; it is `std.math.floatMax`.
- `2.0 ** 3` and the `-38` literal both go through `std.math.pow`; several
  `@builtins` that used to exist (`@cbrt`, `@expm1`, `@log1p`, `@asin`,
  `@acos`, `@atan`, `@sinh`, `@cosh`, `@tanh`, `@asinh`, `@acosh`, `@atanh`)
  are not builtins in 0.16 — use `std.math.*`.
- `f80` is portable (emulated on aarch64 and riscv64), so it is safe in tests
  when `f64` lacks the precision needed.
- The `zig` on PATH is an anyzig shim: a bare `zig build-exe` outside a
  directory with a `build.zig.zig` fails with "no build.zig to pull a zig
  version from". Use `zig 0.16.0 build-exe ...`, and give every
  `build.zig.zon` a `.minimum_zig_version` or it exits 1 silently.
- A file may belong to only **one** module per compilation. Registering a
  second module for a file another module already reaches by relative import is
  a hard "file exists in modules" error. This is why the benchmarks each take a
  second registration of the public module and why `bench/timing.zig` is reached
  by relative import rather than registered.
- The `consumer` build step shells out to a nested `zig build` with private
  `--cache-dir` / `--global-cache-dir` and `setCwd`. **Those private caches are
  mandatory** — the parent build holds the shared global cache lock, and
  reusing it deadlocks. Do not remove them. The first `zig build test` is slow
  (~3m20s) because that cache is cold; later runs are fast. That is not a
  problem to fix.

## 6. How to check the tree is healthy

```sh
cd ~/projects/zig-interval
zig build test        # 228 tests + 29 consumer checks
zig build bench        # the benchmarks
jj status             # what is uncommitted
jj log -r main --no-graph -T 'commit_id.short() ++ "  " ++ description.first_line() ++ "\n"'
```

Expected: `zig build test` exits 0; the oracle reports 0 failures across all
eight operations; the consumer prints `consumer ok: 29 checks`.

## 7. Orientation for a first look

Read in this order if you have time for only one thing:

1. `src/rounding.zig` — small, and it explains the whole rigor model.
2. `tests/soundness_test.zig` — the oracle. It is why the rest is trustworthy.
3. `bench/timing.zig` — why the numbers mean anything.
4. `src/interval.zig` — where the hot operations live.

## 8. What not to do

- Do not optimise before the baseline exists.
- Do not touch the soundness oracle to make an optimisation pass.
- Do not re-export or re-register modules; the "one file, one module" rule
  will fail the build and the reason is not obvious from the error.
- Do not remove the consumer step's private cache directories.
- Do not trust a number you did not re-run yourself. Benchmark agents reported
  results that were never independently confirmed.
