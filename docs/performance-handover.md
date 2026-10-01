# Performance work — handover

**Written for a future session that has none of the prior context.** Everything
needed to resume is below. If a statement here conflicts with the code, the code
wins — but check the code before trusting this file, because it describes a
moving target.

The companion document is `docs/next-work-plan.md`. It carries the defect table
and the ranked plan for what is still open; this file carries what was measured,
what landed, and what was withdrawn. Nothing is duplicated between them. Two
claims in it have since gone stale and are superseded here: D16's oracle skip
counts of 2,040 for `div` and 2,163 for `recip` were true when it was written
and are both **0** now, and the "8 of 56" coverage figure is **35 of 56**.

Two more claims in it have moved since. **D18 is settled**: an infinite endpoint
is a ray, `Interval.init` canonicalises the two overflow rays, and the frontier
sweep now **judges** all thirteen operations it walks instead of withholding six
of them. The reading is stated once, in
[two kinds of infinity](../README.md#two-kinds-of-infinity); nothing in this
file's measurements changes with it, because the repair is two comparisons in
the constructor and one branch on `scale`'s unbounded path. And the twenty-one
uncovered operations are no longer waiting on hand-written reference series:
the direction is an independently generated MPFR directed-rounding containment
corpus, which changes no `ns/op` figure here either.

Everything in sections 2 and 3 was measured on 2026-09-30, with one dated
exception: the cross-target verification carries its own heading and its own
date, **2026-10-01**, and it re-ran the test step rather than a benchmark, so
no `ns/op` figure anywhere in this file is restated by it. The growth figures
come from throwaway programs that read the sign buckets directly, and section 3
step 1 gives the routine to rebuild them. Nothing here is a guess.

---

## 1. What this project is

`~/zig-interval` — a Zig 0.16.0 library package
(`zig_interval`) doing **rigorous interval arithmetic** over `f64`.

The central claim, which everything else serves: **every operation returns a
result guaranteed to contain the true mathematical answer.** Not approximately —
*guaranteed*. If a result can be too narrow, the library is actively dangerous to
a caller doing verification, so this constraint outranks performance at every
decision point in this document.

The guarantee is obtained by computing with IEEE round-to-nearest and then
widening each endpoint outward. Zig 0.16 has no directed rounding, so the
widening helpers in `src/rounding.zig` do it with `u64` bit-pattern stepping.

Source layout, 4,179 lines under `src/`:

| File | Lines | Contents |
| --- | --- | --- |
| `src/interval.zig` | 1,008 | `Interval{lo,hi}`: 28 public operations, 8 of them arithmetic |
| `src/interval_ext.zig` | 628 | 28 elementary functions, free functions |
| `src/vector.zig` | 807 | `Vec(n)` (compile-time dim) and `DynVec` (runtime dim) boxes |
| `src/lp.zig` | 1,294 | Fourier–Motzkin solver with Tupper's variable ordering |
| `src/rounding.zig` | 218 | outward-rounding primitives, certified pi enclosure |
| `src/root.zig` | 224 | public module root; enumerates the whole surface name by name |

28 plus 28 is the **56 public operations** every coverage number in this
document is a fraction of, and it is the denominator the oracle in section 2
counts against. The `Op` enum in `tests/soundness_shared.zig` names **35** of
them and the remaining **21** are the uncovered list in section 2, so
`35 + 21 = 56`. Count it from the enum and the two source files, not from this
document. Line counts drift; re-run `wc -l src/*.zig` rather than trusting the
table, and read the code when the two disagree.

Consumers import the package as `@import("interval")`.

## 2. Where the work stands right now

Steps 1 to 5 ran to completion, a second optimisation round ran on top of them,
and the soundness oracle was extended from 8 covered operations to 35. Nothing
in this section is a plan. The plan for what is still open is
`docs/next-work-plan.md`; this file records what was done, what it bought, what
was measured away, and what was tried and thrown out.

### Verified tree state — 2026-09-30, re-verified since

| Fact | How it was checked |
| --- | --- |
| `zig build test` exits 0 in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall, each ending `readme examples ok: 31 checks`. The fixture's first consumer prints `consumer ok: 29 checks` immediately before it, and the README's examples are wired second so the log stays in the order the README states them | run, all four modes |
| The soundness oracle reports `0 FAILED` on every operation it covers — 35 of them — and 348 tests pass across the eleven test artifacts | run |
| The MPFR corpus tier reports **1886 rows checked, 0 FAILED**, in each of the four modes. It is the only reference in the tree that was not written in the tree: `scripts/gen_corpus.c` calls MPFR at 256 bits twice per row, once `RNDD` and once `RNDU`, and the output is committed as `tests/corpus/elementary.txt`. 1813 of the rows carry the 21 operations the in-tree oracle does not judge, and 73 more carry `sqrt`, `cbrt` and `tanh`, which it does — external corroboration, not new coverage | run; the row count and that split read out of `tests/corpus/elementary.txt` |
| `8 of 8` operations named by the NaN contract trap on a NaN scalar, and every well-formed control comes back clean | run, each in a child process |
| The oracle is four sibling test binaries over one shared module, `tests/soundness_shared.zig`, and the LP exact block is its own module, `src/lp_exact.zig`, tested by `tests/lp_exact_test.zig`. The four are siblings over one vocabulary rather than a chain because `zig test` collects the tests of every file a binary reaches, imported or not, so a chain would run the shared file's tests a second time | counted from `build.zig` and the `tests/` tree; the extraction is proved by `probe/lp_exact.zig` failing to compile |
| `zig build bench` completes; `bench-lp` is bounded by the 20,000-row budget and its run reports 18.5 s. Both numbers are the 2026-09-30 capture and **neither has been re-measured since**; what has been re-run is the step, one benchmark at a time, and each exits 0 | run |
| `zig fmt --check` clean | run |
| `zig build docs` green | run |
| `aarch64-linux`, `riscv64-linux` and `s390x-linux` build **and run** the whole test step — corpus tier included, 0 FAILED — under QEMU user-mode, **348/348 on each**, the same 348 the native run reports and not a subset. `s390x-linux` is big-endian and is the **only byte-order coverage this project has**: the oracle's `u64` bit-pattern stepping in `src/rounding.zig` and the NaN contract trap's pattern reads are exactly the code a little-endian host cannot get wrong, so a green run on the other targets is not evidence about s390x | run, `cross-test`, 2026-10-01 — `aarch64-linux` and `s390x-linux` at `--timeout 900`, the rest at the default; per-target counts, the byte-order point and the timeout trap are in the cross-target section below |
| `x86_64-windows` builds and is **not run**: there is no wine on this host, so the test step's binaries cannot execute there, and `cross-test` records the target `build_only`, `runtime_unavailable`. "Builds" is the whole of the claim. The suite is **not** evidenced on Windows and this row must not be read as "the tests pass there" | run, `cross-test` |
| `bench-lp`'s geometry report is byte-identical to the capture from before the optimisations, and predicted == achieved on every branch | run |
| Everything this document records is committed, not uncommitted: `main` and `main@origin` are both `083d7471`, HEAD is detached on it, and `85f8592` was the tip when the `ns/op` figures below were taken. **Do not quote that id from this document** — it goes stale at the next commit, this document included — and read a `jj status` that shows a working-copy commit above `083d7471` as work in flight, not as lost work | `jj log -r 'ancestors(@, 25)'` |

Two of those lines want a reader's attention. The geometry report being
byte-identical is what makes every LP number in this document trustworthy: it
says the optimisations changed what the solver **pays**, not what it computes.
And the windows row is the one most easily over-read, because compilation is
not execution and on this host it is the whole of what that target can be.

The cross-target rows have a section of their own below, carrying the
per-target 348/348 counts, the byte-order point, and the one entry in this
table a later session is most likely to mistake for a defect.

**What has moved cost since, in words because the numbers must not move.** O2
in `docs/next-work-plan.md` gave `box` one shared elimination walk in place of
`m` private sweeps. It altered the elimination COUNT — roughly half as many
eliminations — and it raised peak memory, because the walk holds a chain and
one copy alive together where the old form held one. The geometry report row
above is unaffected, and the reason is what that report prints: bounded or
unbounded, and nothing else. **No `ns/op` figure anywhere in this document has
been re-measured since 2026-09-30, and none is claimed to have been.** O2 is
the one landed change that could move them, so `zig build bench` has to be
re-run before any figure here is quoted as current.

**The four-mode run is no longer outstanding.** It was re-run after every
commit since the measurement, one mode at a time, at the tip named in the last
row: `zig build test` exit 0 in all four, the oracle at `0 FAILED` on all 35
operations, the corpus tier at 1886 rows and 0 FAILED, and `zig build docs` and
`zig fmt --check` both green. The benchmark is the one gate that has not been
re-run, and that is deliberate — a figure that moves because nobody re-measured
it is worse than a figure carrying its date.

**And the other cost question since, the priority 1 infinity contract.** The
constructor now compares and selects on two endpoints, `scale` has one extra
branch on the unbounded path only, and `expand` and `translate` read an infinite
scalar as a ray rather than as a number. None of it changes what any finite
answer is, so no `ns/op` figure here is invalidated by it — but the constructor
comparison is on every construction, and whether that is free is a measurement
rather than an assertion. Re-run `zig build bench` with it before quoting a
figure as unchanged.

**Why the width changed, in one line.** `tanh` at
`x = 0.23139395412799124` returned an enclosure that EXCLUDED the true value,
because the `std.math` primitive reaches 2.14 ULP and a two-step widening
brings the bound back to the correctly rounded `f64` and stops. It is D17 in
`docs/next-work-plan.md`; the defect, its witness, and the trap every test for it
has to avoid — the nearest `f64` to the true value IS the bound the old code
returned, so a reference rounded to `f64` reports the defect as sound — are in
§2 of `docs/tests-and-architecture-plan.md`.

### Cross-target verification — 2026-10-01, and the 300-second timeout that reads like a defect

**The mode first, because it decides what the figures below mean.** `cross-test`
runs this build's own `test` step and adds only `-Dtarget=`, so every count
here is the tree's **default optimize mode, Debug** — `build.zig` takes
`optimize` from `b.standardOptimizeOption(.{})` and names no default of its
own, and the build logs say `compile test Debug <target>`. A project profile
that passed `-Doptimize` would change the mode for the targets it covers, so
read one if there is one.

**Measured on 2026-10-01 at one tree state**, in two runs: the whole matrix at
the harness's default execution timeout, and then the two targets that need
more at 900 seconds.

| Target | Build | Run | Tests | Note |
| --- | --- | --- | --- | --- |
| `x86_64-linux` | pass | pass | 348/348 | the host itself, executed natively |
| `aarch64-linux` | pass | pass | 348/348 | QEMU user-mode; **fails the default timeout**, see below |
| `riscv64-linux` | pass | pass | 348/348 | QEMU user-mode; passes the default 300 s |
| `s390x-linux` | pass | pass | 348/348 | QEMU user-mode, **big-endian**; **fails the default timeout**, see below |
| `x86_64-windows` | pass | `build_only`, `runtime_unavailable` | — | no wine on this host, so "builds" is the whole of the claim |

Three foreign targets therefore execute the entire test step, corpus tier
included, at 0 FAILED — the same 348 the native run reports, not a subset.

**`s390x-linux` is the only byte-order coverage in this project, and that is
why it is in the table rather than left out.** Every other target here is
little-endian, including the host. The code most sensitive to byte order is
the oracle's own: `src/rounding.zig` steps endpoints by `u64` bit pattern, and
the NaN contract trap reads bit patterns out of a value. A little-endian host
cannot get that class of code wrong, so **a green run on every other target is
not evidence about s390x at all**, and this target is not redundant with the
rest of the row.

**The trap: the default execution timeout is 300 seconds and this project's
heaviest test takes 108 seconds NATIVELY.** The test
`test.Vec: distance is never below the true Euclidean distance` sweeps
**4,000,000** cases — `norm_cases` at `tests/vector_test.zig:1673` — and
measured **108 s** on its own on this host, on 2026-10-01. The whole 55-test
vector binary also reports 108 s, so essentially all of that is the one loop.
Natively that fits inside the default budget with room to spare. Under
`qemu_user` it does not, and the run then prints exactly this:

```
cross-test: target=aarch64-linux build=pass run=fail tests=348 reason=tests_failed
cross-test: target=s390x-linux   build=pass run=fail tests=348 reason=tests_failed
cross-test: status=fail pass=2 fail=2 build_only=0 partial=0
```

The per-target build log underneath it says
`error: 'vector_test.test.Vec: distance is never below the true Euclidean distance' timed out after 5m98.663ms`
and then `Build Summary: 25/27 steps succeeded (1 failed); 347/348 tests passed (1 timed out)`.

**That is a timeout, not a defect, and the one-line summary is what makes it
look like a defect.** `cross-test: status=fail` cannot tell a timeout from a
wrong answer — both carry `reason=tests_failed` — and the `tests=348` on that
line is how many tests RAN, not how many passed, so it stays at 348 on a run
that lost one. Read the per-target build log before believing a cross-target
failure here, and look for `timed out` in it. Re-run at `--timeout 900` and the
same two targets report `run=pass tests=348 reason=tests_complete` and the run
reports `status=pass pass=2 fail=0`. The two runs differ only in `--timeout`
and `--output`, and the failing log names the timeout and nothing else.

**The harness, so the next session does not have to rediscover any of this.**
It is `~/.local/bin/cross-test`: **outside the repository** — not vendored,
not a submodule, not on this project's `PATH`, and nothing `jj status` will
show you. It behaves in four ways that matter here:

- **It manages its own cache**, and refuses the obvious override: `--cache-dir`
  is rejected with `cross-test manages this option: --cache-dir`, and so are
  `--prefix`, `-Dtarget`, `-j` and `--test-timeout`. Do not pass them.
- **It discovers a project profile** at `./cross-test.profile.sh`, then
  `./test/cross-test.profile.sh`, and a profile may set `CROSS_*` variables
  including `CROSS_MATRIX`, which is what decides the target set. A profile in
  the tree therefore decides what a green run *covers* — read it before
  quoting the table above as the project's coverage.
- **It needs `ZIG` pointed at a real compiler.** The `zig` on `PATH` is the
  anyzig shim described in section 5.
- **Its output has to be on local disk.** `/nfs` rejects `renameat2`
  with `EINVAL`, so a Zig build on the network mount cannot use a cache there;
  cross-test solves that for its own cache, and `--output` solves it for the
  run.

The invocation behind the table, on this host:

```sh
export PATH=/tmp/zigbin:$PATH              # the real 0.16.0; PATH `zig` is a shim
ZIG=/tmp/zigbin/zig ~/.local/bin/cross-test \
  --targets x86_64-linux aarch64-linux riscv64-linux s390x-linux \
  --output /tmp/cross-out --jobs 2 --build-jobs 2            # default 300 s
ZIG=/tmp/zigbin/zig ~/.local/bin/cross-test \
  --targets aarch64-linux s390x-linux \
  --output /tmp/cross-out3 --jobs 2 --build-jobs 2 --timeout 900
```

Each run prints a `cross-test: target=…` line per target, a `status=` line, and
leaves `cross-test-summary.json` plus per-target logs under `--output`. A run
here writes nothing into the working tree and leaves no core dumps.

### The oracle: 35 of the 56 public operations now have a containment oracle

This is the fact that changes what a later session is allowed to trust, so it
belongs near the top of this file and not at the bottom.

The oracle grew from 1,037 lines to several thousand and from 8 covered
operations to 35, and it is now `tests/soundness_shared.zig` under four sibling
test files, one per concern. It computes true extrema from the ORIGINAL `f64`
inputs and checks containment, and it is the only thing between a faster library
and a wrong one. The 35, by the strength of the reference each is held to:

| Layer | Count | Operations | What the reference is |
| --- | --- | --- | --- |
| exact image, no sum needed | 12 | `mul`, `abs`, `sqr`, `neg`, `hull`, `hullOf`, `intersect`, `intersectionOf`, `floor`, `ceil`, `trunc`, `round` | the true mathematical image, built from the original `f64` endpoints. None of these forms a sum: a magnitude, a square, a negation, a min and a max of two `f64` are all exact where they are computed |
| exact image, by an exact residual | 5 | `add`, `sub`, `translate`, `expand`, `scale` | the true sum of the original `f64` endpoints, judged through a `TwoSum` residual — `s` plus `err`, an exact expansion of the sum — never through a rounded `f128` sum. **A rounded `f128` sum is not exact and is never used as truth**: a product of two `f64` needs 106 significand bits and `f128` carries 113, so products are exact, but `floatMax - 3` has its lowest set bit at 2^0 and its highest at 2^1023, so it needs about 1024 bits and **rounds back to `floatMax` even in `f128`**. `1e300 + (-1e-300)` is the same fact at the other end. `scale` needs the five-term form, because its extrema are `(A + B + G*A - G*B) / 2` and the division by two is a sixth. The residual is held against the unsafe `[floatMax, floatMax]` answer for `floatMax - 3` |
| exact, by cross-multiplication | 2 | `div`, `recip` | `f128` holds a **product** of two `f64` exactly — 106 significand bits against the 113 the type carries — so the bound times the divisor is exact and the sign of the divisor fixes the direction. No quotient is ever evaluated. This is a product, and the row above is not, which is the entire difference between the two |
| exact, by a stated bracket | 3 | `sqrt`, `cbrt`, `tanh` | `sqrt` on IEEE 754's own guarantee that a square root is correctly rounded, widened half an ULP; `cbrt` on the sign of `y^3 - x`, which assumes no accuracy of any primitive; `tanh` on the true value in `f128` to 3.1e-34 relative, from the exponential identity with the cancellation near zero paid for, bracketed to `[tanh 20, 1]` past 20 where the value is indistinguishable from 1 at thirty-four digits |
| values | 4 | `midpoint`, `clamp`, `width`, `distanceTo` | each has a reference built from the original `f64` endpoints — the centre, the nearer endpoint, the difference of the two endpoints. **The difference is formed in `f128` and is not always exact there**, for the same reason the sums above are not, which is why these are judged from BOTH sides by `scalarOk` at one ULP rather than by an exactness assertion |
| laws | 9 | `contains`, `overlaps`, `subsetOf`, `eql`, `ne`, `lt`, `le`, `gt`, `ge` | no image exists for a bool, so these are checked against each other and against the set operations, which do have one |

`div` and `recip` report **0 skipped precondition**, where they reported 2,040 and
2,163. Those skips were half genuine non-applicability and half a coverage hole
wearing a precondition's clothes: the library returns a documented contract value
`[-inf, inf]` for a divisor that reaches zero, and a documented answer is a
contract value to be checked, not a case the oracle may decline to judge. A
divisor that merely REACHES zero is now checked from the sign of its two
one-sided limits, and the checks went from 5,070 to 7,110 for `div` and from
5,073 to 7,236 for `recip`.

**Three things the oracle grew beyond adding operations**, each of which changed
what the sweep can say rather than how much of it there is:

- **`width` and `distanceTo` are judged as values.** They sat under a magnitude
  rule that accepted `+inf` unconditionally and imposed no upper bound, so a
  width four times too large passed every one of its 8,000 cases. They are now
  judged two-sidedly, and the overflow the old rule existed for is decided by
  the REFERENCE instead — the exact width of the whole format is a real no `f64`
  holds, so `+inf` is the value there rather than a bound the reference has to
  be widened to.
- **An infinity frontier sweep.** The random layer screens every non-finite
  operand out, so 35 sweeps judged the library on finite inputs and not one of
  them reached an infinity. The new sweep is directed: sixteen named shapes,
  fourteen canonical and two pairs the constructor refuses, carried against each
  other, plus seven scalars for the operations that take one. Its reference is
  built from what an infinite endpoint stands for and is derived from the shape
  rather than read back from the answer, and it uses the `lo_beyond` /
  `hi_beyond` flags the `Range` struct already carried and nothing had ever set.
  **It found six operations whose answer at an infinity is not an enclosure, and
  two of the six findings were themselves wrong** — `sub`'s witness had two rays
  that cannot cancel, and `neg`'s read a non-canonical point where the contract
  has a ray. Both were withdrawn. The contract they were argued under is now
  stated in [two kinds of infinity](../README.md#two-kinds-of-infinity), and the
  sweep **judges all thirteen operations it walks and withholds none**, so a fix
  in `src/` no longer hides behind a withheld row. It is **not green yet**: the
  failures are in the oracle's own references, not in `src/`, and they are
  exactly the kind a withheld row could never surface. D18 in
  `docs/next-work-plan.md` owns the defect and the repair.

  **Why the fix cost no hot-path work.** The repair is in the constructor, and
  its soundness rests on which arm of `roundDown` the corner reaches: at a finite
  nonzero argument `roundDown` is `prevDown`, a full ULP outward, while at a
  computed `+inf` it is `+floatMax` with no step left. Canonicalising the
  operand moves the corner onto the arm that has room, so the existing one-line
  `add` becomes an enclosure with no branch in it. `scale`'s single new branch is
  on the unbounded path only. The finite path is untouched.
- **The per-operation seed is keyed by label, not by position.** It used to be
  `seed ^ @intFromEnum(op)`, which meant inserting one member silently
  re-randomised every later stream and invalidated every count and every
  mutation-bite figure in this file, with no test failure to notice. It is now
  an FNV-1a hash of the operation's label. This is a precondition for the next
  twenty-one operations being added to that enum.

**What is still uncovered, and it is 21 operations.** Every one of them is in
`src/interval_ext.zig`: `pow`, `powf`, `exp`, `exp2`, `expm1`, `log`, `log2`,
`log10`, `log1p`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `sinh`,
`cosh`, `asinh`, `acosh`, `atanh`. The blocker is measured rather than assumed,
and it is in the file's own header: Zig 0.16's `f128` transcendentals are **not**
wider than `f64`, so there is no wider primitive to check them against. Over
20,000 draws `@exp(f128)`, `@log(f128)` and `@sqrt(f128)` rounded to `f64`
equalled the `f64` evaluation 20,000 times out of 20,000, and `@sin`, `@cos` and
`@tan` on all but a few dozen. **The escape is not a wider primitive, and it is
no longer a hand-written one either.** `tanh` has a reference of its own — the
exponential identity with the cancellation paid for, accurate to 3.1e-34 relative
— and that is the one hand-written reference in the tree. The direction for the
other twenty is an **independently generated MPFR directed-rounding containment
corpus**, so the oracle would be checked against an external
arbitrary-precision implementation at a declared rounding direction rather than
against a second implementation written in this tree; a hand-written `f128`
series is a second implementation, and the audit needed to convince anyone it is
correct costs more than the coverage it buys. Their three-ULP widening is
therefore still a measured figure that no test re-measures and no test bounds.
That is the open coverage hole; **T4, T6 and T7 in
`docs/tests-and-architecture-plan.md` are open** until that spec and its evidence
land, and all twenty-one remain unimplemented.

### The blocker that started all of this, and why the row budget is still there

This is history now, and it is kept whole because the row budget is the one
guard in the tree that exists to stop a repeat, and a later session must not
read it as decoration.

**It was not a leak.** A `std.heap.DebugAllocator` over 2,800 solver operations
— `add`, `eliminate`, `eliminationOrder`, `bounds` and `box`, on both the mixed
and the straddling generators — reported `.ok`. Every `deinit`, `errdefer` and
caller-owned `free` in `src/lp.zig` and `bench/bench_lp.zig` was correct, and is.

**It was row explosion.** `System.eliminate` emits exactly
`num_lower(k) * num_upper(k)` rows, and a coefficient that straddles zero is
deliberately pushed into **both** buckets (`src/lp.zig:258-280`) because
dropping it would cut the feasible set. With the generators `bench/bench_lp.zig`
feeds it, the row count therefore grows by roughly a factor of the row count at
every round. Measured growth, exact, by reading the sign buckets `eliminate`
would build without materialising a single derived row:

| System | Growth |
| --- | --- |
| `mixed`, 6 vars, 24 rows | 24 → 215 → 20,076 → **351,661,485 predicted** |
| `straddling`, 5 vars, 10 rows | 10 → 100 → 7,756 → **56,340,286 predicted** |
| `mixed`, 4 vars, 6 rows | 6 → 11 → 26 → 486 → **223,269 predicted** |

At 16 bytes per `Interval` and six columns per row, the 351,661,485-row step is
about 33 GB written by a single `eliminate` call. The observed behaviour
matched: two `bench-lp` processes reached **169 GB** and **160 GB** RSS, and a
throwaway probe that reproduced the growth reached **215 GB** RSS. On a 1 TB host
that is survivable. It is not acceptable, and it must not happen again.

A size search over 78 configurations — `mixed` at 4 to 8 variables and 6 to 64
rows, `straddling` at 3 to 6 variables and 4 to 20 rows — under a 20,000-row
budget found **not one that completes**. There is no comfortable size in the
current parameter space, which is why step 1 bounds the work rather than
tuning it.

### Which of the thirteen measurements were affected, before step 1

Unrunnable as written, because they never terminated in bounded memory:

- `reportGeometry` on `mixed 24x6` and on `straddling 10x5`
- `eliminateAll chosen, mixed 24x6`
- `bounds k=2, straddling 10x5`
- `box, straddling 10x5`

Bounded in memory (peak about 14 MB, freed each iteration) but slow enough that
iteration counts needed review: `bounds k=0, 6x4`, `box 6x4`,
`eliminationOrder 6x4`, `eliminateInOrderOfChoice 6x4`. Each paid a 223,269-row
final round.

Sound and unaffected then and now: `add 8 rows x 4 vars`, `add 64 rows x 8 vars`,
`build 6 rows x 4 vars (control)`, `eliminate k=0, 6 rows x 4 vars`, and both
`eliminateAll` rows on the heuristic system, which uses point `±1` coefficients
and therefore no straddling.

All thirteen measurements run today. None was deleted; the nine that breached
the budget were resized, and the table in step 1 records what each one became.

## 3. The steps, in order, and what each one bought

Steps 1 to 5 are done and their results are below. Step 6 onward are standing
instructions for whoever picks this up, and they are unchanged.

### Step 1 — Bound the LP benchmarks — DONE, and still load-bearing

**Result.** `zig build bench` completes; the whole `bench-lp` run reports
18.5 s against 21.8 s before round 2, and every predicted count still equals its
achieved count on every branch. All thirteen measurements run, and the
20,000-row budget is the only thing between a size mistake and a 329 GB
incident on a host shared with other users' training jobs.

`bench/bench_lp.zig` now carries `predictedRows`, a `row_budget` of 20,000, and
a `requireRowBudget` gate on every elimination the file drives. The prediction
was checked against reality: `reportGeometry` prints predicted beside achieved
and they are equal on every branch, 11/11, 2/2, 4/4, 48/48 and 121/121.

The guard works by predicting, before each elimination, what the row count would
become, and refusing to cross the budget:

```
next_rows(k) = (#rows with an exact zero in column k) + num_lower(k) * num_upper(k)
```

where a straddling coefficient counts once in `num_lower` and once in `num_upper`,
because that is exactly what `eliminate` does with it. Everything the check
needs is already public: `System.at(i)` yields the row, and the sign test is
three float comparisons. No derived row is ever built to make the decision, and
nothing is allocated.

Three things were built on top of it: every elimination the file drives is
gated, a trip exits non-zero through the existing `trap` helper with the
measurement name, the variable, the system shape, the prediction and the budget
in the message, and `reportGeometry` prints the predicted count beside the
achieved one so a future change that makes the solver cheaper shows up as a
smaller number rather than as a hang.

The second, independent guard is now the row budget itself, and that is
sufficient. The `ulimit -v` recipe that an earlier draft of this file
recommended is **wrong and was removed**: the compiler inherits the limit, so
`( ulimit -v 4194304; zig build bench-lp )` dies with `error: OutOfMemory` while
compiling, before a single benchmark row runs. Do not reintroduce it. If a limit
is ever wanted it must wrap the emitted binary, not `zig build`.

`System` propagates `error.OutOfMemory` out of `eliminate`, so a size that
escapes the budget surfaces as an exit status rather than as an OOM kill.

The five measurements that never terminated were resized to what the budget
allows, with the achieved row counts recorded in the file's own header so the
next reader does not "restore" the values that used to hang:

| Measurement | Was | Now | Peak rows |
| --- | --- | --- | --- |
| `reportGeometry` mixed | 6 vars, 24 rows | 2 vars, 14 rows | 17,034 |
| `reportGeometry` straddling | 5 vars, 10 rows | 2 vars, 11 rows | 14,641 |
| `eliminateAll chosen, mixed` | 6 vars, 24 rows | 2 vars, 14 rows | 7,994 |
| `bounds k=2, straddling` | 5 vars, 10 rows | 2 vars, 11 rows | 14,641 |
| `box, straddling` | 5 vars, 10 rows | 2 vars, 11 rows | 14,641 |

Four more had to be resized than the five named, because they breached the
budget too: `bounds 6x4`, `box 6x4`, `eliminationOrder 6x4` and
`eliminateInOrderOfChoice 6x4`. `bounds 6x4` peaked at 223,269 rows and crossed
on 55 seeds in 64 with a 196,927,221 prediction. All thirteen measurements
survive; none was deleted, and all four of those now run at 14x2.

### Step 2 — Capture the baseline — DONE, and the capture has been redone

**Result.** All three baselines exist and two full optimisation rounds have
been measured against them. The figures are below and they supersede the
original capture, which was taken while the host was busy and therefore reads
high on every cheap row.

`build.zig` exposes `bench-scalar`, `bench-vec` and `bench-lp` as per-file steps
alongside the combined `bench` step, which is unchanged. Nothing about what is
built differs; they are aliases, so one benchmark can be run alone.

```sh
cd ~/zig-interval
zig build bench-scalar --cache-dir /tmp/bl/cache --global-cache-dir /tmp/bl/gcache
zig build bench-vec    --cache-dir /tmp/bl/cache --global-cache-dir /tmp/bl/gcache
zig build bench-lp     --cache-dir /tmp/bl/cache --global-cache-dir /tmp/bl/gcache
```

The benchmarks pin their own mode to `ReleaseFast` in `build.zig`, so
`-Doptimize` is neither needed nor wanted. A private cache directory is worth
using anyway: the shared one is contended when anything else is building.

Scalar, `bench-scalar`, ReleaseFast, **idle machine**, three runs, minima. Read
this next to the noise floor at the end of step 4: five of these seven rows sit
under 10 ns/op, where this host moves by up to 44 % with nothing changed, so
only the ordering is trustworthy here and not any single delta.

| Operation | ns/op |
| --- | --- |
| `interval.scale` | 47.795 |
| `interval.div` | 15.465 |
| `interval.mul` | 9.639 |
| `interval.add` | 5.027 |
| `interval.sub` | 5.108 |
| `interval.sqr` | 4.807 |
| `interval.abs` | 4.138 |

`ext.powf` at 272.5 ns/op and `ext.pow` at 107.2 ns/op are the only figures for
those two. They are the original capture and they are the two most expensive
operations in the library, so nothing supersedes them. Neither optimisation
round changed the elementary functions' COST, and the later change to their
WIDTH (two ULP to three) added no measurable time either, because the rounding
helpers inline to nothing at ReleaseFast — so these two rows still stand as
costs. Read them as an order of magnitude on a busy host, not as a current
number.

LP, `bench-lp`, ReleaseFast, **idle machine**, three runs, minima:

| Row | ns/op |
| --- | --- |
| `box, straddling 11x2` | 152,932 |
| `eliminationOrder, mixed 14x2` | 140,342 |
| `box, mixed 14x2` | 124,597 |
| `bounds k=1, straddling 11x2` | 88,369 |
| `bounds k=0, mixed 14x2` | 75,219 |

`eliminate k=0, 6 rows x 4 vars` stands at 62,634 ns/op, and that is the step-2
capture. It was not re-measured in round 2, which is why it carries no
before/after row there; do not read it as current, and do not read it as proof
that round 2 left the small-system path alone.

The handover's earliest figure of "about 16.3 ns/op" for a plain `Interval.add`
was wrong, and the correction to it was also taken on a busy host: 6.3 ns/op
there, 5.027 ns/op on an idle one. Both are inside the band of what this host
does to a cheap row; neither is a claim.

### Step 3 — Check the harness before trusting any number — DONE, two defects found

No row reported `ns/op` of exactly 0, so nothing was being elided. The
checksums are byte-identical across two independent runs, so the harness is
deterministic in what it computes. Two real defects turned up, and a third
problem showed up only in the figures themselves.

**Defect 1, fixed: a use-after-free in the allocator benchmark.**
`bench/bench_vec.zig` read `p[0]` into the sink AFTER freeing the allocation.
The `smp_allocator` happened to leave the byte intact, so the rows looked
plausible and printed `checksum 0` for work that had plainly happened; the
`DebugAllocator` poisons freed memory, so that row died with `SIGSEGV` and took
the whole `bench-vec` run with it. This is why `bench-vec` had never been seen
to finish. The read now happens before the free.

**Defect 2, fixed: the run total was a hard-coded zero.**
`bench/timing.zig` printed `checksum 0` from `@as(f64, 0)`. It now accumulates
every body's sink — as a sum of BIT PATTERNS, not of values, because these
operations legitimately return unbounded intervals and a floating-point total
collapses to `inf` on the first of them and then reads `inf` forever after. A
constant cannot distinguish "the work ran" from "the work was elided".

**Problem 3, fixed in the benchmark: the DynVec figures measured the allocator,
not the library.** The `DynVec` environments were built on a `DebugAllocator`,
so every value-returning row was dominated by an 11,146 ns round trip against
`smp_allocator`'s 30.5 ns. The reported "DynVec is 757x slower than
`Vec(2).add`" was that ratio, not a property of the code.

`bench_vec.zig` now builds both allocators, measures all nine value-returning
bodies under each, suffixes every row with `.smp` or `.dbg`, and prints a table
of how much of a value-returning call is the allocator. Measured, and verified
by re-running `bench-vec`:

| box | round trip smp | round trip Debug | `add` value smp | `add` value Debug | % allocator smp | % allocator Debug |
| --- | --- | --- | --- | --- | --- | --- |
| 2 comp (32 B) | 17.68 | 5,784.86 | 26.27 | 6,793.16 | 67.3 % | 85.2 % |
| 4 comp (64 B) | 30.54 | 11,146.47 | — | — | — | — |

Under the allocator the hot path actually uses, a value-returning `DynVec` add
at dimension 2 costs 26.3 ns against `Vec(2).add` at 10.8 ns — a gap of about
2.4x, not 757x. The DebugAllocator figures are kept alongside, because they are
the honest answer to what checking every allocation costs; they were simply
being quoted as the cost of the library.

That investigation also found a labelling bug of the same kind: the `ops` table
hand-classified `contains` and `distance` as value-returning when both return a
scalar and never allocate, which printed them beside neighbours at 11,000 ns.
They now sit in their own `no-alloc` column.

**Problem 4, measured and NOT fixable in code: the noise floor.** See the table
at the end of step 4. Cheap operations move by up to 44 % between two runs with
nothing changed. That is a property of this shared host, not of the harness,
and it bounds what any future "faster by X %" claim can mean.

### Step 4 — Profile, then rank by measurement — DONE, with verdicts

Every hypothesis was settled against source plus emitted assembly, and the
measured baseline confirms or corrects each one. Ranked by what is actually
worth attacking, largest first. **The verdicts have not changed. The evidence
has:** each measured figure is now the idle-machine figure, or is explicitly
marked as an older capture that nothing has superseded, and a row that clears
the noise band says **CLAIMED** while one that does not says **NO CLAIM**.

The instruction counts come from a throwaway probe, and the probe is written
down because a reader who cannot reproduce it cannot check them. Four `export
fn` wrappers calling one operation each, `f64` in and an out-pointer for the
`[2]f64` result, compiled ReleaseFast against `src/root.zig` with `-femit-asm`,
then each wrapper's assembler body counted line by line:

```sh
zig 0.16.0 build-obj -OReleaseFast --dep interval \
  -Mroot=/tmp/icount/probe.zig -Minterval=src/root.zig \
  -femit-asm=/tmp/icount/probe.s \
  --cache-dir /tmp/icount/cache --global-cache-dir /tmp/icount/gcache
```

`Interval` cannot cross the C ABI, so the wrapper takes and returns `f64`s.
The counts include cold paths, so they rank cost badly and are not a cycle
model; what they are good for is saying whether an operation got simpler. Run
against the pre-round-2 tree at `85f85922` with the identical probe they
reproduce the older figures in this table almost exactly — `mul` 209, `div`
167, `add` 60 — which is the check that this is the recipe that produced them.
One caveat, so the numbers are not over-read: LLVM inlined `div` into its
wrapper this time and outlined it last time, so `div`'s 167 -> 206 is two
different bodies and not a like-for-like delta. `mul` and `add` were emitted
the same way in both.

| Rank | Hypothesis | Verdict | Evidence | Action |
| --- | --- | --- | --- | --- |
| 1 | the final round inside `bounds` | **CONFIRMED, largest win** | creates ~99.8 % of every row `bounds` allocates, for a contradiction test only; `mixed 6x4` sweep is 6 -> 11 -> 26 -> 486 -> 223,269. **CLAIMED**: `box, straddling 11x2` is **152,932 ns/op**, from 2,088,773 at the step-2 capture and 301,609 at the start of round 2; `bounds k=1, straddling 11x2` **88,369**, from 1,005,474 and 161,917 | done in step 5; round 2 took two more passes at the solver, in "Round 2" below |
| 2 | `scale` composes through other ops | **CONFIRMED** | 6 outward-widening steps per endpoint on the finite path, 8 on overflow, and **the step count has not changed** — round 2 kept every step and cut the price of one. Body 345 instructions with 8 out-of-line calls before round 2, 6 of them to `div`; 576 with 2 calls after, because those six calls are gone. `mul` 209 -> 220, `div` 167 -> 206. **CLAIMED**: **47.795 ns/op** against **80.551** at the start of round 2, **-41 %**, and 5.0x `mul` and 3.1x `div` | the widening is deliberate and documented, so this is a design cost, not a bug. Round 2 added `Interval.halve`, which divides by two directly and repairs only the one endpoint whose half is a lost magnitude. The algebraic reformulation that drops two operations was tried, measured unsound, and withdrawn; see section 9 |
| 3 | `DynVec` allocates per value-returning op | **CONFIRMED, and the benchmark was lying about it** | 1000 calls of `add` = 1000 allocations / 64 KB; `iadd` = 0. The measured "DynVec is 757x slower than `Vec(2).add`" was an artefact: those rows run on a `DebugAllocator`, whose round trip is 11,146 ns against `smp_allocator`'s 30.5 ns | the real user-facing cost is one allocator round trip per call, ~30 ns under `smp_allocator`. A caller writing `dv = dv.add(other)` in a loop also LEAKS the previous box unless it is freed first. Step 3 fixed the benchmark to measure both allocators. The library side is unchanged and nothing here has superseded these figures |
| 4 | `Corner` struct cost in `mul`/`div` | **CONFIRMED but misdiagnosed** | the four `f64` corners scalarise into XMM registers with no stack traffic. The real cost is the `undersized: bool` side channel: 4 byte stores plus 3 UNCONDITIONAL reloads in `mul`, and 4 dead stores in `div` | the reloads sat **above** the `v == 0.0` guard, so they carried data that is dead unless the extremum is exactly zero. **Fixed in round 2**: the flag is lazy, `Corners.undersizedAt` asks the question only after the reduction has come back a zero, and the operands are read then rather than spilled beside the values. **CLAIMED**: `mul` **9.639 ns/op** against **11.062**, **-13 %**, which clears the band |
| 5 | `powf` composes `exp(log(base)*y)` | **CONFIRMED, do not change** | depth 7 interval operations, 6 stack frames, 4 envelope calls, zero allocations. Measured **272.5 ns/op** on the step-2 capture, the most expensive operation in the library, 2.5x `ext.pow` | deliberately traded for soundness. Quantified, as asked; not a defect, and not re-measured because neither round touched the elementary functions |
| 6 | `roundUp`/`roundDown` cost a call | **REFUTED** | at ReleaseFast LLVM inlines all four rounding primitives: zero `call` instructions, zero standalone bodies. A `noinline` control differing only by the attribute produced 4 real calls in the same probe, so the probe could detect one | no action |
| 7 | `eliminationOrder` clones per step | **REFUTED as stated** | it clones exactly ONCE, before the loop. The real per-step cost is that `eliminate` rebuilds the whole coefficient table each step, O(R_t * m) bytes, and `chooseNext` costs O(m^2 * R) over the whole loop | the clone is not the problem; the rebuild and the pair-count scan are. Round 2 removed the regrowth half of the rebuild by reserving the exact final capacity, and left the pair-count scan alone |

Three things this table says that the hypotheses did not. First, the ranking by
measured cost and the ranking by "obvious waste" are different: the obvious one,
missing `inline`, is the cheapest item on the list and is already free. Second,
`box` is `m` clones and `m * m` eliminations, so the biggest single lever in
the solver is not any one operation but that `box` re-derives every projection
from scratch. Third, and this is the one a later session should carry forward:
every CONFIRMED row now has an answer. Two were fixed in round 2, rows 2 and 4.
One was fixed in step 5, row 1. One turned out to be a benchmark defect rather
than a library defect and was fixed in step 3, row 3. One is a deliberate
soundness trade and is not being changed at all, row 5. **What is left on this
list is nothing**, which is why the ranked work now lives in
`docs/next-work-plan.md` and not here.

### Noise floor, measured — read this before believing any delta

Two runs of `bench-scalar` on the pre-round-2 tree, same binary, same machine,
nothing changed:

| Operation | Run 1 | Run 2 | Delta |
| --- | --- | --- | --- |
| `interval.scale` | 88.259 | 89.925 | +1.9 % |
| `interval.recip` | 8.316 | 8.387 | +0.9 % |
| `interval.abs` | 5.899 | 5.917 | +0.3 % |
| `interval.add` | 6.335 | 8.468 | +33.6 % |
| `interval.expand` | 6.298 | 8.594 | +36.5 % |
| `interval.mul` | 13.739 | 19.775 | +43.9 % |

The second run was taken with other benchmarks compiling and running on the
same host. Every per-measurement checksum was byte-identical across the two
runs, so the harness is deterministic in what it computes and noisy only in what
it costs. `bench/timing.zig` reports the minimum over 7 repetitions, which is
stable for the expensive rows and not for the cheap ones.

**The band was confirmed a second time, and it is the reason five of the seven
interval rows in the round-2 table are marked NO CLAIM.** A cheap operation is
not a small number on this host; it is a number with an error bar wider than
most optimisations. Both rounds of results below were therefore taken on an
**idle** machine, three runs each, comparing minima, and a row is only called a
result when the delta clears the band. `scale` at -41 % and `mul` at -13 % clear
it. The other five do not, and they are recorded as **NO CLAIM** rather than as
small wins: `div` -1.8 %, `add` -1.0 %, `sub` +0.6 %, `sqr` -0.2 % and `abs`
-0.3 %. A reader who takes `div`'s 0.289 ns as an achievement is wrong, and the
honest statement is that round 2 did not move it and did not prove that it did
not.

**Consequence: a change to any operation under about 10 ns/op cannot be claimed
from a single pair of runs on this host.** Take the measurement on an otherwise
idle machine, or take three runs and compare the minima. The cheap rows are
where an optimisation is most tempting and where the evidence is weakest.

### Step 5 — The last round of `bounds` — DONE, 3.2x to 8.2x

`bounds(k)` eliminated every variable except `k`, read the bounds, and then
eliminated `k` as well, because that was the only way a contradiction among the
surviving rows became visible. That last round created about 99.8 % of every
row the call allocated, and all it produced was a contradiction test.

It is now `System.derivesContradiction(k)`, which answers the same question
without building a row. `appendCombined` was split into `combinedColumn` and
`combinedBound`, which both the elimination and the predicate now call, so the
two ask the identical question of the identical values rather than two
lookalike copies of it.

How it avoids the materialisation:

1. One `O(rows * var_count)` pass fills a fixed scratch with, per row, the
   multiplier part it would carry into each bucket — derived exactly as
   `eliminate` derives it — plus whether the row is the exact `[0,0]` in every
   column except `k`, and whether that multiplier part is itself exactly `[0,0]`.
2. Per pair, a cheap necessary condition on the bound goes first. Because the
   buckets guarantee `upper.coeff >= 0` and `lower.coeff <= 0`,
   `bound.hi` is at least `upper.coeff.hi * max(lower.rhs) - lower.coeff.lo *
   min(upper.rhs)`, so a pair whose plain-`f64` comparison is already `>=` cannot
   fire and is skipped with two scalar multiplications. The comparison is `>=`
   rather than a subtraction on purpose: a difference that overflows to an
   infinity falls through to the exact path instead of being silently dropped.
3. The four-case filter then settles most of the rest: both multipliers exact,
   lower exact and lower flat, upper exact and upper flat, or both flat. Each
   forces every combined column to the exact zero.
4. Any pair the filter does not settle is measured column by column through
   `combinedColumn`, and survivors get the exact `combinedBound(..).hi < 0`
   test. This step is not optional: the filter admits the case where a product
   underflows, and dropping it would change an answer silently.

Measured, ReleaseFast, on the host as it stood when the change landed, the LP
rows that call `bounds`. **These are the numbers for this change and not the
current ones**; the current figures are in step 2 and the round-2 deltas are
below.

| Row | Before | After this change | Speedup |
| --- | --- | --- | --- |
| `box, straddling 11x2` | 2,088,773 | **255,232** | **8.2x** |
| `bounds k=1, straddling 11x2` | 1,005,474 | **139,464** | **7.2x** |
| `box, mixed 14x2` | 540,427 | **154,597** | **3.5x** |
| `bounds k=0, mixed 14x2` | 294,283 | **92,762** | **3.2x** |

Rows that do not call `bounds` moved too, in the direction the noise floor
allows and no further: `eliminateAll ascending` 586,391 -> 270,589,
`eliminationOrder` 238,314 -> 215,415, `eliminate k=0` 62,634 -> 50,938. None of
those is claimed as an improvement; they are inside the band the machine
produces with nothing changed.

Verification, all run after the change:

- `zig build test` green in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall,
  each ending `consumer ok: 29 checks`, with the soundness oracle reporting
  `0 FAILED` on all eight operations it covered at the time. **It now covers
  35**; see section 2.
- `bench-lp`'s geometry report byte-identical to before, including every
  predicted-against-achieved pair (11/11, 2/2, 4/4, 48/48, 121/121). The first
  round is untouched by construction; the change removes work that happens
  after the projection has been read.
- `bounds` returns a bit-identical interval on 7,700 generated systems across
  two build modes, covering mixed point coefficients, straddling coefficients,
  coefficients that merely reach zero, satisfiable systems, contradictory
  systems, and systems where the old final round fired.
- Four characterisation tests in `tests/lp_test.zig` pin the behaviour in both
  directions, and each was proven to fail under the corresponding mutation
  before the change was made: deleting the final round fails "a contradiction
  only the last round can see is still reported" and "one unit of slack
  separates the empty system from the feasible one"; loosening the contradiction
  predicate to `rhs.hi <= 0` fails "the same system one unit away is not a
  contradiction" and "one unit of slack separates the empty system from the
  feasible one". Those tests are the reason this change was admissible rather
  than merely measured. Cite them **by name**: the file has grown since, and
  the line numbers in the previous revision of this document had already gone
  stale.

**One adjacent idea remains ruled out and should not be attempted.** Stopping
after `n - 1` variables, as a textbook Fourier–Motzkin loop does, is still not
available. `eliminationOrder` is contractually a full permutation
("eliminationOrder is a permutation with no repeats"), the final row count is
pinned ("Tupper's order does measurably less work than the mirror order", which
asserts 5 rows in, 1 out, and the shipped path's final count equal to the
planned one), and the all-zero rows the last round produces are the shape the
contradiction tests read. Removing the round changes observable behaviour, so it
is a different function. Section 9 records it again, with the rest of the
withdrawn list.

### Round 2 — what changed after step 5, and what it bought

Four changes, each measured on its own, all landed. ReleaseFast, **idle
machine**, three runs each, comparing minima. The Claim column is the point of
the table: five of the seven interval rows do not clear the noise band and are
recorded as not being results, even though every one of them did go down.

Interval, ns/op:

| Operation | Before | After | Delta | Claim |
| --- | --- | --- | --- | --- |
| `interval.scale` | 80.551 | **47.795** | **-41 %** | **CLAIMED**, far outside the band |
| `interval.mul` | 11.062 | **9.639** | **-13 %** | **CLAIMED**, clears the band |
| `interval.div` | 15.754 | 15.465 | -1.8 % | **NO CLAIM**, inside the band |
| `interval.add` | 5.078 | 5.027 | -1.0 % | **NO CLAIM**, inside the band |
| `interval.sub` | 5.076 | 5.108 | +0.6 % | **NO CLAIM**, inside the band |
| `interval.sqr` | 4.818 | 4.807 | -0.2 % | **NO CLAIM**, inside the band |
| `interval.abs` | 4.149 | 4.138 | -0.3 % | **NO CLAIM**, inside the band |

**`scale`: the two `div(two)` halvings became `Interval.halve`.** `scale` needs
the midpoint and the half-width of the box, and it was getting each by dividing
an interval by the point 2 — the whole four-corner quotient machinery, both
bounds, and the underflow repair, as `scale`'s own doc comment puts it, "three
times over, to divide by the one constant the format can answer exactly". The
emitted body agreed: eight out-of-line calls, six of them to `div`. `halve`
divides by two directly and repairs only the one endpoint whose half is a lost
magnitude: a lower bound steps down, an upper one steps up, and an endpoint
that is itself an exact zero halves to an exact zero, which is already its own
bound. **The widening-step count is unchanged at 6 per endpoint.** What changed
is the price of a step, and that is the whole result: the same guarantee, a
shorter path, 41 % less time.

**`mul`: the `undersized` flag became lazy.** `Corners` used to carry an
`undersized: bool` beside the four values. Four `f64` scalarise into registers;
four bytes do not, so the flag became four byte stores and three UNCONDITIONAL
reloads sitting *above* the `v == 0.0` guard, carrying an answer that is dead
unless the reduced extremum happens to be exactly zero. The flag is gone. The
operands are read, by `Corners.undersizedAt`, at the one moment they are
needed: after the reduction has come back a zero. The dead stores in `div` went
with it.

LP, ns/op, same conditions:

| Row | Before | After | Delta | Claim |
| --- | --- | --- | --- | --- |
| `box, straddling 11x2` | 301,609 | **152,932** | **-49 %** | **CLAIMED** |
| `bounds k=1, straddling 11x2` | 161,917 | **88,369** | **-45 %** | **CLAIMED** |
| `eliminationOrder, mixed 14x2` | 227,450 | **140,342** | **-38 %** | **CLAIMED** |
| `box, mixed 14x2` | 171,663 | **124,597** | **-27 %** | **CLAIMED** |
| `bounds k=0, mixed 14x2` | 100,410 | **75,219** | **-25 %** | **CLAIMED** |
| `bench-lp` total wall time | 21.8 s | 18.5 s | -15 % | **CLAIMED** |

These rows are all far outside the band, and for a structural reason rather
than a lucky one: a row that eliminates tens of thousands of rows is not a
cheap row, and the 44 % the noise floor produces is a property of rows that
finish in nanoseconds.

**The `cancelsExactly` pre-filter.** `cancelsExactly` decides whether a pair of
products cancels to the structural exact zero, and the D4 repair made it decide
on the operands in `f128` — a sound place to decide it, and an expensive one.
The old equality could only ever close when **both** products were point
intervals, so on every column of every pair the eight `f128` soft-float
multiplies were being paid to compute the answer "no". Round 2 puts a cheap
`f64` filter in front: build the same four corners as `doubleProduct`, rounded
to nearest, and if the two rounded hulls do not coincide the exact ones cannot.
Rounding to nearest is monotone, so the minimum of the rounded corners is the
rounding of the minimum, and two hulls that coincide exactly cannot differ
after rounding. Only the pairs that already agree pay for `f128`.

**The `eliminate` capacity reservation.** `eliminate` knows the exact final
row count before it starts and was growing its two output lists geometrically
to reach it. It now reserves the exact capacity once, up front, with the
multiplication guarded against overflow. On the `mixed 6x4` sweep a single
`eliminate` call emits 223,269 rows, and every regrowth-and-copy pass on the way
there is gone.

Verification for round 2, all run after both solver changes:

- An 80,000,000-quadruple differential fuzz of the new predicate against the
  old one: **0 mismatches**.
- Every `bench-lp` checksum line identical to the run before, and the geometry
  report byte-identical, predicted == achieved on every branch.
- `zig build test` green in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall,
  each ending `consumer ok: 29 checks`, oracle `0 FAILED` on every operation it
  covers.

**What round 2 did not buy, and the one reformulation that looked like a win and
was not, are both in section 9.**

### Step 6 — Optimise, one change at a time, with a measurement for each

For every change: re-run the benchmarks, and report the before/after for the
operations the change touched. A change that makes one operation faster and
another slower is a decision to make deliberately, not a win.

### Step 7 — The soundness gate. This is not optional and not negotiable.

The oracle computes true extrema from the ORIGINAL `f64` inputs — exact products
in `f128`, exact sums through a `TwoSum` residual rather than through a rounded
`f128` sum, quotients by cross-multiplication — and checks containment. It
exists because a previous audit found four soundness defects that 200 tests
and 29 consumer checks all passed, and
because D1 survived all of them: a defect that a suite never looks for is not a
suite that passed.

**The gate grew with the work and is now much wider than it was.** It covers 35
of the 56 public operations rather than 8, it reports `0 skipped precondition`
for `div` and `recip` where it used to report 2,040 and 2,163, and it grew a
directed infinity frontier sweep that judges **thirteen** operations at a shape
the random layer screens out, six of them newly judged rather than withheld.
Twenty-one operations — all but one of the
elementary functions in `src/interval_ext.zig` — still have no containment
oracle. Section 2 has the full picture, and
`docs/tests-and-architecture-plan.md` ranks what is left of that work.

**Every optimisation must leave it green.** It is the only thing standing
between a faster library and a wrong one.

```sh
zig build test
```

If an optimisation makes it fail, the optimisation is wrong. Do not relax the
oracle to accommodate a speedup. If you believe the oracle is wrong, prove it
against `tests/soundness_shared.zig` plus a throwaway `f128` check of your own
before changing anything.

### Step 8 — Full verification, then commit

```sh
zig build test                                          # all suites + consumer
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build test -Doptimize=ReleaseSmall
zig build docs
zig fmt --check build.zig build.zig.zon src tests fixture
```

Also run the local cross-target soundness gate:

```sh
cross-test --jobs 8 --build-jobs 2
```

Inspect its summary and target logs. A build-only target or
`no_test_results` is not runtime soundness evidence. MIPS32 execution
found subnormal `div` and `recip` failures that native tests missed:
Zig 0.16's `__divdf3` flushes subnormal quotients. `cornerQuotient` now
recovers them with exact power-of-two scaling before the usual outward
step. Runtime-input regressions cover the witnesses, the normal/subnormal
transition, half-way rounding, deep underflow, and both operand signs.

The build also passes the `cross-test` QEMU runner to the NaN and ownership
child probes. The x86-linux test parent ran under QEMU on this host, but
direct child execution failed without a kernel binfmt handler. Both probes
now use the explicit runner and keep their existing control and trap checks.

There is no Windows or WASI runtime wired up for this project yet. A temporary
Wine 11 and wasmtime 48 are present on this host and are useful for a one-off
probe, but no target of this project's own suite has been executed under either,
so a row claiming Windows or WASI **runtime** evidence would be claiming
something nobody has measured. Build-only evidence is build-only.

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
   of soundness and is deliberate. It looks like waste and is not. For the
   elementary functions it is now THREE ULP, and the count is the auditable
   artefact: it is one number, one place, one table of measured margins per
   primitive. It was two, and a real defect got through — `tanh` reaches 2.14
   ULP on the primitive, so a two-step bound can exclude the true value. If you
   are tempted to narrow it, read the table first.
6. **Do not remove the straddling duplication in `eliminate`.** It is the reason
   the result is a guaranteed superset. It is also the reason the row count
   explodes. Both facts are true; only one of them may be optimised away.
7. **Never run an LP benchmark without a row budget.** The host has 1 TB of RAM
   and is shared with other users' training jobs. 329 GB was observed in one
   `zig build bench`; a larger system would take the machine with it.

## 5. Toolchain gotchas — these cost real time to rediscover

All verified empirically on this machine.

- `std.time.Timer` **does not exist** in Zig 0.16. Timing is
  `std.Io.Clock.real.now(io)`, which returns a plain `Timestamp` (no error
  union — do not `try` it). Get an `Io` with
  `std.Io.Threaded.init(gpa, .{})` then `threaded.io()`. Passing `std.Io` as a
  `main` parameter is **not** supported (`start.zig` wants an `Io.minimal` field
  that does not exist).
- `std.ArrayList` is **unmanaged**: `std.ArrayList(T){}` / `.empty`,
  `append(gpa, x)`, `deinit(gpa)`. There is no `.init(gpa)`.
- On a `*System`, `sys.varCount()` does not resolve; use `sys.*.varCount()`. A
  field read such as `sys.*.var_count` takes no parentheses.
- A labelled block is `blk: { ... break :blk value; }` — the break label is the
  block label, not the name of the value.
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
  directory with a `build.zig.zon` fails with "no build.zig to pull a zig
  version from". Use `zig 0.16.0 build-exe ...`, and give every
  `build.zig.zon` a `.minimum_zig_version` or it exits 1 silently.
- To build a throwaway program against the library without touching
  `build.zig`, register the module on the command line. `-M` takes one module
  per compilation, so this never collides with the build graph:

  ```sh
  zig 0.16.0 build-exe -OReleaseFast --dep interval \
    -Mroot=/tmp/probe.zig -Minterval=src/root.zig \
    -femit-bin=/tmp/probe \
    --cache-dir /tmp/probe/cache --global-cache-dir /tmp/probe/gcache
  ```

  Give a throwaway its own cache directories, and not to keep it off the shared
  one out of fear: a second writer contends on the same manifests and the build
  gets slower, which is a different problem from the one that produced this rule.
- A file may belong to only **one** module per compilation. Registering a
  second module for a file another module already reaches by relative import is
  a hard "file exists in modules" error. This is why `bench/timing.zig` is
  reached by relative import rather than registered, and why the benchmarks do
  NOT take a second registration of the public module — that used to be the
  stated reason, and it was **false on both counts**: the rule does not require
  it, and the measured evidence is that it did nothing. A compilation is
  compiled in the mode of its **root** module; a module's own `.optimize` only
  decides what `builtin.mode` reads inside that module. Measured on 0.16.0 by
  building both ways and hashing: **byte-identical benchmark binaries**. Pin the
  root module, which each of the three benchmark executables already does.
- The `consumer` build step shells out to a nested `zig build` with private
  `--cache-dir` / `--global-cache-dir` and `setCwd`. **Those private caches are
  not a deadlock workaround — there is no deadlock to work around.**
  `Cache.Manifest.hit` locks ONE manifest at a time, with `lock_nonblocking =
  want_shared_lock` defaulting to a shared lock, so a parent and a nested build
  can share one global cache; dropping both flags was measured and the step
  finishes in the same ~43 s with the same `consumer ok: 29 checks`. They are
  kept for containment: both paths are relative to the working directory the
  step sets, so the nested build's cache output lands in `fixture/.zig-cache`
  (163 MB when this was measured) and goes away with the fixture instead of
  joining the machine-wide cache this build shares with every other project.
  One consequence: `fixture` is one of the six entries in `build.zig.zon`'s
  `.paths` and that entry is recursive, so hashing or fetching the package
  walks that cache; `.gitignore` excludes it, and it should be cleaned first.
  The first `zig build test` is slow (~3m20s) because that cache is cold; later
  runs are fast. That is not a problem to fix.
- A struct with automatic layout cannot cross the C ABI, so a throwaway that
  wants to export an `Interval` has to take and return `f64`s instead, and an
  array is not an allowed return type either — use an out-pointer. This bites
  an `export fn` in a `-femit-asm` probe; a `pub fn` called from the same file
  never notices.

## 6. How to check the tree is healthy

```sh
cd ~/zig-interval
zig build test        # exits 0, ends with "readme examples ok: 31 checks"
zig build bench-lp    # safe: the row budget bounds it. The run reports 18.5 s,
                      # on top of compile time. The scalar and vector halves
                      # dominate the combined `zig build bench`, not this one.
jj status
jj log -r main --no-graph -T 'commit_id.short() ++ "  " ++ description.first_line() ++ "\n"'
```

The working copy is not expected to be dirty. What the table at the top of
section 2 records is committed and pushed; a working-copy commit sitting above
`083d7471` is work in flight, and `jj diff --stat` says what is in it.

## 7. Orientation for a first look

Read in this order if you have time for only one thing:

1. `src/rounding.zig` — small, and it explains the whole rigor model.
2. `tests/soundness_shared.zig` — the oracle's vocabulary, and the `Op` enum in
   it names which of the 56 operations the oracle reaches and which it does not.
   The four files beside it are the four concerns. It is why the rest is
   trustworthy, and it is the first place to look before optimising anything.
3. `bench/timing.zig` — why the numbers mean anything.
4. `src/interval.zig` — where the hot operations live, and `Interval.halve` is
   the one private helper round 2 added.
5. `src/lp.zig` — `System.eliminate` and `System.bounds`, the two places the
   row explosion comes from, and `System.derivesContradiction`, the predicate
   that replaced `bounds`' final round.

Cite these by name, not by line number. The line citations in the previous
revision of this document had already drifted by the time it was superseded.

## 8. What not to do

- Do not optimise before the baseline exists. It does now: see step 2.
- Do not reintroduce a row budget below 20,000 rows, or raise any benchmark
  size past what the budget allows without re-checking `predictedRows`. The
  budget is what stops this benchmark from taking 329 GB of a shared host again.
- Do not wrap `zig build` in `ulimit -v`. The compiler inherits the limit and
  dies with OutOfMemory before any benchmark row runs.
- Do not touch the soundness oracle to make an optimisation pass.
- Do not "fix" the straddling duplication in `eliminate`. It is the guarantee.
- Do not report a cheap operation's delta as a result. Five of the seven
  interval rows in the round-2 table did not clear the noise band and are
  recorded as NO CLAIM for exactly that reason.
- Do not re-export or re-register modules; the "one file, one module" rule
  will fail the build and the reason is not obvious from the error.
- Do not remove the consumer step's private cache directories — not because
  removing them deadlocks anything, which it does not, but because they keep
  163 MB of nested build output inside `fixture/.zig-cache` instead of in the
  machine-wide cache every other project on this host shares.
- Do not trust a number you did not re-run yourself. Benchmark agents reported
  results that were never independently confirmed.

## 9. Withdrawn, and not being done

Everything here was tried, measured, or argued, and then dropped. A later
session that re-derives one of these has saved itself the work, and the reason
is recorded so it does not have to be re-derived too.

| Item | Why it is not being done |
| --- | --- |
| `scale`'s algebraic reformulation | **Tried, and measured unsound.** Over the reals, `M - W = lo + (hi - lo)(1 - g) / 2` and `M + W = hi - (hi - lo)(1 - g) / 2`, so the sum that forms the midpoint and the midpoint itself can both be dropped and the composition loses two operations. Each arm is protective in ONE direction only, because the term's sign follows the sign of `1 - g`, which is a property of the caller's factor. A half-width enclosed too WIDE is subtracted on one arm and added on the other, and on the arm where it is subtracted it drags the bound inside the image. Two counterexamples, both measured: `[0, 2^-1074]` at factor zero has the exact image `{2^-1075}` and the short form answers `[0, -2^-1074]`, inverted; `[-floatMax, floatMax]` at factor zero has the exact image `{0}` and the short form answers `[-8.988e307, -floatMax]`, which excludes 0 outright. The reasoning and both counterexamples are in `src/interval.zig` beside `scale`. **Do not re-attempt it** |
| `div` at 15.465 ns/op against 15.754 | **Inside the noise band, so it is not a result.** 0.289 ns on a row this host moves by up to 44 % with nothing changed. Round 2 did not move `div` and did not prove that it did not. The same applies to `add`, `sub`, `sqr` and `abs`; all five are NO CLAIM in the round-2 table |
| the straddling duplication in `eliminate` | **It is the guarantee.** A coefficient that straddles zero bounds its variable from below for its negative realisations and from above for its positive ones, and no single pairing is right for both. Dropping one of the two duplicates would discard a real constraint and cut the feasible set. Both facts are true: it is also the reason the row count explodes. Only one of them may ever be optimised away, and it is not this one. See hard constraint 6 |
| stopping after `n - 1` variables | **Pinned by tests.** `eliminationOrder` is contractually a full permutation, the final row count is asserted, and the all-zero rows the last round produces are the shape the contradiction tests read. Removing the round changes observable behaviour, so it is a different function, not a faster one |
| replacing `powf`'s composition | **A deliberate soundness trade, quantified rather than a defect.** `powf` composes `exp(log(base) * y)`, which is depth 7 interval operations, 6 stack frames, 4 envelope calls and zero allocations, at 272.5 ns/op. It was the most expensive operation in the library when step 4 measured it, and it is still more expensive than anything in the current tables. A hand-rolled version would be faster and would have to be argued sound endpoint by endpoint; the composition is the argument |
| the `log2` / `log10` subnormal claim | **An audit filed it and the claim was withdrawn.** It was checked and did not reproduce: the library contains the truth on the smallest subnormal and at the range boundary in every case tried. The apparent misses were an `f64`-computed reference compared against the library's elementary widening, which is the same reference mistake that would recreate D2 inside the oracle — and the same one that made the `tanh` defect of D17 look sound. Do not re-add it to an audit's list without a reference **finer than `f64`**, and note that `log2` and `log10` are among the 21 operations with no containment oracle at all, which is the real reason the question is open rather than settled |
| the benchmarks' second private ReleaseFast module registration | **Dropped, and it was inert as well as unjustified.** It existed to pin the benchmark mode against a rule that does not require it, and building both ways gives the same binary. The rule that replaces it, and the measurement behind it, are in section 5; the short form is "pin the root module" |
| `ulimit -v` around `zig build` | **Wrong, and removed from an earlier draft of this file.** The compiler inherits the limit and dies with `error:OutOfMemory` while compiling, before a single benchmark row runs. If a memory limit is ever wanted it must wrap the emitted binary, not `zig build` |

The rule underneath all of these is constraint 2: a faster path that computes
something slightly different is a different function, and the guarantee is
about the function as specified.
