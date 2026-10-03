# zig_interval

Closed-interval arithmetic over `f64` for Zig 0.16. Every operation returns a
**guaranteed enclosure** of the true mathematical answer, plus n-dimensional
boxes and a Fourier-Motzkin solver for systems of linear inequalities with
interval coefficients.

## Installation

Add the dependency to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_interval = .{ .url = "<REPOSITORY_URL>", .hash = "<HASH>" },
},
```

`<REPOSITORY_URL>` and `<HASH>` are placeholders. Both values are assigned when
the package is published; run `zig fetch --save <url>` to have the toolchain
write a concrete stanza for you.

## The guarantee

**Every operation in this library returns an interval that contains the true
mathematical answer.** Not "the answer rounded to the nearest float" — an
enclosure of it.

Write `X` for a set of reals and `X op Y` for the exact mathematical result of
an operation on sets. For every real `v` belonging to `X op Y`:

```text
result.lo <= v <= result.hi
```

holds for every real `v` in the set, not approximately for a rounded copy of it.
A result is a claim about the reals, not a guess about a machine. The same
holds for the n-dimensional boxes and for the linear-inequality solver, which
propagates intervals for the same reason.

What backs that claim is not the same everywhere. For arithmetic and square root
it is a proof; for the elementary functions it is a measured error bound with
headroom. [What is proved and what is measured](#what-is-proved-and-what-is-measured)
below says which is which, and this page does not claim the stronger of the two
for the whole library.

### How the guarantee is obtained

Zig 0.16 has no directed rounding mode. `@round` is round-to-nearest, and
`@floor`, `@ceil` and `@trunc` snap to a representable value rather than to the
neighbour in the direction of rounding — none of them can produce "the smallest
double at or above `x`". Without directed rounding, an operation computed in
ordinary floating point can land one ULP on the wrong side of the true answer.

So each operation widens instead. It computes its endpoints with ordinary IEEE
round-to-nearest arithmetic and then moves each endpoint outward: `roundDown` on
a computed lower bound, `roundUp` on a computed upper bound. **How many steps it
moves depends on what computed the endpoint, and the two cases are not equally
well established.**

**Arithmetic widens by one ULP, and that is a proof.** IEEE 754 defines
addition, subtraction, multiplication, division and square root as correctly
rounded, so an IEEE result lies within half a ULP of the exact one. A full
ULP of outward slack exceeds that error. The algebraic operations on
`Interval` — `add`, `sub`, `mul`, `div`, `recip`, `sqr` — widen by one step.

Zig 0.16's software `__divdf3`, used by the default MIPS32 targets, does not
meet that premise for subnormal quotients: it flushes them to zero. `div`
and `recip` recover a zero quotient of nonzero finite operands by scaling
the numerator by 2^54, dividing, and multiplying the result by 2^-54.
The numerator scaling is exact and cannot overflow on this path. A
representable nonzero quotient becomes normal before division; scaling
back contributes at most three quarters of the smallest subnormal in total
rounding error. If the scaled division still flushes, the exact quotient
is smaller than one quarter of that subnormal. The same one-step outward
bounds cover both cases. The exact oracle is not relaxed for these targets.

`sqrt` stands in the same position: correctly rounded, so one step would be
enough. The free function is widened by three anyway — the same three as every
other answer reached through `interval.ext` — so the whole namespace answers
under one rule. That extra width is the price of uniformity, not a risk.

**The elementary functions widen by three ULP, and that is a measured margin,
not a proof.** The `std.math` primitives behind `exp`, `log`, the trigonometric
functions, the hyperbolic functions and the rest are not correctly rounded and
carry no documented error bound, so the count has to clear the worst of what
those primitives actually do rather than the worst of a guess about them. The
worst of them measured is `tanh`, at 2.14 ULP, and [what is proved and what is
measured](#what-is-proved-and-what-is-measured) below gives every figure with
the margin it leaves.

**Three, and not two, because two was not enough.** The count used to be two,
on the strength of a sample of 300 arguments per function at magnitudes from
1e-8 to 1e8, which put every point primitive the library calls within about
1.1 ULP, `tanh` the worst at 1.07 — past what a single step absorbs, so the
sample said two steps would do. A denser sweep over `|x| <= 0.5` then put
`tanh` at 2.14, and at the worst argument it found, `x = 0.23139395412799124`,
the two-step widening put the lower bound *above* the true value, so
`interval.ext.tanh` was returning an enclosure that excluded the value it was
asked to enclose. That is a hole in the one guarantee this package makes, and
no oracle built out of `f64` can see it, because the nearest double to that
true value *is* the bound that was returned.

**One count for the whole family, not one per function, and the uniformity is
the point.** A single number is what makes the margin auditable: one number, in
one place, checked against one table whenever a primitive is added or
re-measured. A per-function margin would be narrower, which reads as an
improvement and is not — it is exactly the kind of number drawn from a sample,
and a sample has now been shown wrong about one member of this family, so a
narrower rule for `tanh` alone is the last one anybody should trust. The third
step costs two ULP of width, 4.4e-16 relative on a value near one, and it is
paid on purpose: a result one ULP too wide is merely loose, while one ULP too
narrow is silently wrong and nothing downstream can detect it.

`powf` is the one operation whose underlying primitive has no usable error bound
at all, and it is now handled by composition rather than by a constant.
`std.math.pow` reaches the integer part of the exponent by repeated squaring,
whose relative error doubles at every squaring, so its error grows with that
integer part and no fixed margin can cover it — under a margin of 2⁻³⁸ the value
`1.0000000001^1e8` came back excluding the true answer. `powf` does not call it.
It evaluates each base endpoint as `exp(log(base) * y)` using this library's own
`log`, `mul` and `exp`, each of which carries its own enclosure, and hulls the
two endpoints. The result is a hull of enclosures rather than four points read
off a primitive that cannot bound its own error.

**The geometry operations widen too, and `scale` widens by a different route.**
`translate` and `expand` are one correctly rounded addition or subtraction per
side, so like `add` they take exactly one step per endpoint. `scale` is not a
single operation: its exact image is `[M - W, M + W]`, and neither `M` nor `W` is
an `f64` — each is a chain of rounded steps, and the error of a chain is not the
error of its last step. So `scale` encloses its two intermediates first
and composes the answer out of `add`, `sub`, `mul` and `halve`, each of
which widens in its own right, rather than taking a fixed number of steps
from the outside.

`sin` and `cos` are the two functions that cannot simply take the value at each
end, because the range may turn inside the argument. They read it off the
endpoints and the critical points it covers, and the endpoints take the same
three steps as everything else; the critical values are exactly ±1 and carry no
error of their own.

### What is proved and what is measured

Read this before trusting `tanh` in a verification pipeline.

| | Basis | Status |
| --- | --- | --- |
| `add`, `sub`, `mul`, `div`, `recip`, `sqr` | IEEE 754 correct rounding, half a ULP | **Proven.** One ULP of outward widening is sufficient. |
| `sqrt` | IEEE 754 correct rounding, half a ULP | **Proven.** Widened by three ULP anyway, for uniformity. |
| `exp`, `log`, the trigonometric and hyperbolic functions, and the rest | Worst measured 2.14 ULP over the point primitives, `tanh` the worst; `std.math.pow` measured 1.52 ULP | **Empirically bounded.** Three ULP of outward widening. |

This library does not implement correctly rounded or formally verified
elementary functions. The three is the worst of what these primitives were
measured to do, not a bound on what they can do, and the table below is that
measurement in full — each primitive this library calls, in ULPs of the true
value, with what is left of the margin under three:

| Primitive | Worst measured | Margin left under three |
| --- | --- | --- |
| `tanh` | 2.14 ULP | 0.86 |
| `sinh` | 1.75 ULP | 1.25 |
| `log` | 1.50 ULP | 1.50 |
| `log10` | 1.37 ULP | 1.63 |
| `log2` | 1.22 ULP | 1.78 |
| `cosh` | 1.10 ULP | 1.90 |
| `exp` | 0.87 ULP | 2.13 |
| `tan` | 0.83 ULP | 2.17 |
| `log1p` | 0.78 ULP | 2.22 |
| `sin` | 0.77 ULP | 2.23 |
| `atan` | 0.76 ULP | 2.24 |
| `cos` | 0.74 ULP | 2.26 |
| `exp2` | 0.50 ULP | 2.50 |

Every row is the highest figure any measurement pass produced rather than an
average or a worst case over the reals: `sinh` came back at 1.45 on a later
sweep, and the table keeps 1.75, because a margin is only as good as the worst
figure anyone holds for the primitive. The pass each row came from is recorded
in the source, and the argument bands are not all the same, which is itself a
reason to read the table as a sample rather than as a bound. Seven primitives
this library calls are not in it at all — `asin`, `acos`, `acosh`, `atanh`,
`cbrt`, `expm1` and `sqrt` — and `std.math.pow`, which `powf` no longer calls,
measured 1.52 ULP with an error that grows without limit in the exponent.

So the three-ULP figure is a margin chosen from measurement, not a proof of it.
It is stated here rather than left for a reader to infer. If you need a
*proof* that an `exp`, `log`, trigonometric or hyperbolic bound holds, use a
verified implementation of those functions rather than this one.

### The cost

One extra ULP of width per endpoint for arithmetic and the single-step geometry
operations, three for `sqrt` and every other elementary function, and a few
more for `scale`, which composes several of them. The results are therefore
**slightly wider than mathematically necessary**. That is the price of soundness
and it is deliberate: a result one ULP too wide is safe and costs a little
accuracy, while a result one ULP too narrow is silently wrong and nothing
downstream can detect it. If you have a choice between a result that is
marginally too wide and a result that is marginally too narrow, take the wide one.

Because enclosures compose soundly — each operation accounts for its inputs'
error instead of trusting them — accumulated width grows roughly linearly with
the number of operations composed, not exponentially. The one operation that
breaks that pattern is integer `pow`, which reaches its exponent by repeated
squaring: each squaring **doubles** the interval's relative width, so the width
after exponent `n` grows with the binary length of `n` rather than staying at
one step per squaring. `powf` is not that operation — going through
`exp(y * log x)`, it composes linearly like everything else.

### Widening your own arithmetic

Six rounding helpers are exported, each reachable from the public module as
`interval.<name>`. Four of them are the two pairs a caller needs to tell apart,
and the other two are the certified bounds on π.

| Export | Meaning |
| --- | --- |
| `roundUp(x: f64) f64` | **The upper bound of `x`**: the smallest `f64` at or above it. At `-inf` it answers `-floatMax`, because `-inf` is below every real and so bounds nothing; `+inf` is left alone, since it is already an upper bound of everything. At every finite nonzero value it is one `nextUp` step. Use it on every computed upper bound, including one of your own. |
| `roundDown(x: f64) f64` | **The lower bound of `x`**: the largest `f64` at or below it. At `+inf` it answers `+floatMax`, for the mirror reason; `-inf` is left alone, since it is already below every real. At every finite nonzero value it is one `prevDown` step. Use it on every computed lower bound, including one of your own. |
| `nextUp(x: f64) f64` | The **strict neighbour**: the smallest `f64` strictly greater than `x`. Not a bound. |
| `prevDown(x: f64) f64` | The **strict neighbour**: the largest `f64` strictly less than `x`. Not a bound. |
| `piDown() f64` | Lower bound on π, for certified range reduction. |
| `piUp() f64` | Upper bound on π, for certified range reduction. |

`roundUp` and `roundDown` are the pair to use when a value of yours feeds an
`Interval`, because a bound *is* the non-strict question — the smallest `f64` at
or above a value, the largest at or below it — and that is exactly what the
library does to its own computed endpoints. The one place "non-strict" needs a
word of its own is an infinity, and it is covered below.

```zig
const interval = @import("interval");

// Your own arithmetic, widened exactly the way the library widens its own.
const iv = interval.Interval.init(
    interval.roundDown(my_lower_bound),
    interval.roundUp(my_upper_bound),
);
```

`nextUp` and `prevDown` answer a different question, and swapping them in for the
pair above is a mistake worth naming precisely, because it is silent.

**The two pairs are bit-identical at the infinities and at every finite non-zero
value.** `nextUp(-inf)` and `roundUp(-inf)` both answer `-floatMax`, and
`prevDown(+inf)` and `roundDown(+inf)` both answer `+floatMax`. That agreement is
load-bearing rather than incidental: an `f64` computation only reaches `-inf` by
overflowing, and the exact real it stands for is then a finite number below
`-floatMax`, so a bound of `-inf` sits *below* the value it was meant to enclose;
`+floatMax` is the mirror. Reading an infinity as a value to step inward from is
the mistake, and it is a silent one — the result still looks like a bound.

Those two arms are not the same width, and the difference is load-bearing: at a
finite value there is a full ULP of outward step available, and at `+floatMax`
there is none. It is why the overflow ray is written `[floatMax, +inf]` and why
a result built from one comes back a whole ULP below the corner it rounded. A
computed infinity is one thing; an infinity you supply as an operand is another,
and this section is about the first. See
[two kinds of infinity](#two-kinds-of-infinity) for the second.

They differ **only at the pair of signed zeros**, and that is where the strict
pair stops being a bound: `nextUp(-0.0)` is `+0.0` and `prevDown(+0.0)` is `-0.0`,
so it hands back a different number from the one it was given, where
`roundUp(-0.0)` is `-0.0` and `roundDown(+0.0)` is `+0.0`. A zero is already its
own bound, and stepping across it substitutes a different value for the one you
were bounding.

Reach for the strict pair only when you genuinely want to stand on the
adjacent representable value: the next sample above a value, the one below it,
or a step off an endpoint whose neighbour you are enumerating. Both pairs are
free functions of one `f64`, both are re-exported at the top level of the
module, and all four of those names are the four a caller has.

## Usage

The package exports a single public module named `interval`. Everything —
`Interval`, the vector forms, the elementary functions, the solver namespace —
is reachable from it:

```zig
const std = @import("std");
const interval = @import("interval");
const Interval = interval.Interval;

pub fn main(init: std.process.Init) !void {
    var stderr = std.Io.File.stderr().writer(init.io, &.{});
    const out = &stderr.interface;
    const a = Interval.init(1.0, 3.0);
    const b = Interval.init(2.0, 5.0);

    const shared = a.intersect(b) orelse return error.NoRealAnswer; // [2, 3]
    const span = a.hull(b);                   // [1, 5]
    const total = a.add(b);                   // an enclosure of [3, 8]

    // Elementary functions are free functions, and may be null.
    const rooted = interval.sqrt(Interval.init(4.0, 9.0)) orelse
        return error.NoRealAnswer; // brackets [2, 3]

    try out.print("{d} {d} {d} {d}\n", .{
        shared.width(), span.midpoint(), total.hi, rooted.hi,
    });
}
```

Note what the two kinds of result mean. `shared` and `span` are *exact*: set
operations take endpoints as they find them. `total` and `rooted` are
*enclosures*: they are guaranteed to contain the true answers, which here are
`[3, 8]` and `[2, 3]`, and they come back a hair wider.

In your `build.zig`, wire that module into the module that needs it:

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

The `target` and `optimize` on the module you CREATE are not optional in
practice: `Module.create` panics with "the root Module of a Compile step must
be created with a known 'target' field" without them, whatever the options type
says. Pass the same pair to the dependency.

The dependency key `zig_interval` is the package name; the module name
`interval` is what `@import` resolves against. It is the only public module the
package registers, and it re-exports every type, so one entry point reaches the
whole library.

The package installs a library artifact as well, named `interval`, and that is
the route for a consumer that links the library rather than importing the
module:

```zig
const lib = b.dependency("zig_interval", .{}).artifact("interval");
```

The two names are for two different things — `module("interval")` is the public
module, `artifact("interval")` the installed library — and both are resolved by
name while the build graph is configured, so a rename fails there rather than at
link time. The consumer fixture resolves both.

## API

### Why algebraic operations are methods and elementary functions are not

Two different kinds of work sit behind the same type, and the split is not
arbitrary.

An **algebraic** operation — add, multiply, divide — is expressible in min/max
arithmetic: evaluate the four endpoint combinations, take the minimum for `lo`
and the maximum for `hi`. It is a fixed, tiny amount of work with no analysis
of the function's shape, and it reads naturally as an operation *between two
values*. So it is a method on `Interval`, called as `a.add(b)`.

An **elementary** function needs two analyses that the endpoint trick does not
supply: **monotonicity**, to decide which endpoint maps to which and whether
the function turns, and **domain**, to decide whether the result is real at
all. Every function fails differently — `sin` has extrema, `tan` has poles,
`log` has a boundary, `acos` reverses the endpoints — and none of that work has
a shape worth hiding behind a method call. They are functions from sets to
sets, so they are free functions of an `Interval` and return `?Interval`
whenever the argument can reach outside a domain.

### Algebraic operations — methods on `Interval`

| Method | Semantics |
| --- | --- |
| `init(lo: f64, hi: f64) Interval` | Construct an interval; requires `lo <= hi` and no NaN endpoint, and **normalises the two infinite shapes**: `init(+inf, +inf)` answers the closed overflow ray `[floatMax, +inf]` and `init(-inf, -inf)` its mirror `[-inf, -floatMax]`. The ordering is asserted **first**, so the check still sees the pair you wrote. A finite call, or a pair with one infinite end, is stored field for field. See [two kinds of infinity](#two-kinds-of-infinity). |
| `add(self: Interval, other: Interval) Interval` | Endpointwise sum. |
| `sub(self: Interval, other: Interval) Interval` | `self - other`, computed as `self + (-other)`, so `lo` subtracts the higher operand. |
| `neg(self: Interval) Interval` | `[-hi, -lo]`. **Exact**: IEEE negation is exact and only the endpoints swap, so this is the one algebraic operation that pays no ULP. |
| `mul(self: Interval, other: Interval) Interval` | Product of the four endpoint products, minimum and maximum. |
| `div(self: Interval, other: Interval) Interval` | `self * other.recip()`. **`[-inf, inf]` when `other` contains zero.** |
| `recip(self: Interval) Interval` | `1 / self`. **`[-inf, inf]` when `self` contains zero.** |
| `abs(self: Interval) Interval` | `[0, roundUp(max(abs lo, abs hi))]` when the interval reaches or straddles zero, and `[roundDown(min(abs lo, abs hi)), roundUp(max(abs lo, abs hi))]` otherwise. Widened outward at both ends either way — the magnitude is exact and the two steps are the whole of the widening — but the lower bound **stays at exactly `0.0`** when the interval contains zero, because a point of it maps to zero and no outward step can tighten a bound already at the truth. |
| `sqr(self: Interval) Interval` | Square; nonnegative, and starting at `0` when the interval straddles zero. |
| `contains(self: Interval, x: f64) bool` | Membership test, endpoints inclusive, reading the stored fields. A non-finite `x` is just the comparison, so an upper-unbounded interval answers `contains(+inf)` — that value is on the closed bound, not outside it. Use `eql` to compare two intervals. |
| `hull(self: Interval, other: Interval) Interval` | Smallest interval covering both. |
| `hullOf(items: []const Interval) ?Interval` | Fold of `hull` over `items`; `null` for an empty slice. |
| `intersect(self: Interval, other: Interval) ?Interval` | Shared region; `null` when disjoint. |
| `intersectionOf(items: []const Interval) ?Interval` | Fold of `intersect` over `items`; `null` for an empty slice or a disjoint fold. |
| `width(self: Interval) f64` | `hi - lo`. |
| `overlaps(self: Interval, other: Interval) bool` | True when the two share at least one point. |
| `subsetOf(self: Interval, other: Interval) bool` | True when `self` is contained in `other`. |
| `midpoint(self: Interval) f64` | `(lo + hi) / 2`. |
| `clamp(self: Interval, x: f64) f64` | Clamp `x` into `[lo, hi]`. |
| `translate(self: Interval, delta: f64) Interval` | Shift both ends by `delta`, by adding the point `[delta, delta]`. Finite delta numerics are unchanged. An **infinite** delta is the canonical scalar overflow ray and contributes its two endpoints rather than being read as a number. A NaN delta still violates the constructor precondition. |
| `halve(self: Interval) Interval` | Image of `self` under `x -> x / 2`, widened outward. **Never wider than the bound `div` returns, and tighter in one case** — it is exact outside the subnormal range, so it spends no repair `div` needs, and it steps by `min_subnormal` only at an endpoint that is a lost subnormal. Use it rather than `div` by two wherever a halving is what is wanted. |
| `scale(self: Interval, factor: f64) Interval` | Scale the width about the midpoint by `\|factor\|`. An **unbounded input has no finite midpoint**: `\|factor\| == 1` is the identity, and every other factor — `0` and every `\|factor\| < 1` included — answers `[-inf, +inf]`, which conservatively covers every finite-centre completion instead of fabricating a centre. Bounded-input numerics are unchanged. |
| `expand(self: Interval, margin: f64) Interval` | Widen both ends by `margin`, or shrink both when it is negative; a finite margin requires `margin >= -(hi - lo) / 2`, and a more negative margin traps in Debug and ReleaseSafe. **`+inf` answers the whole line. `-inf` is refused for every bounded input**, `[-floatMax, floatMax]` included: it denotes every margin at or below `-floatMax`, so it is defined only for an interval already unbounded in some direction, where it answers `[roundDown(lo + floatMax), roundUp(hi - floatMax)]`. |
| `distanceTo(self: Interval, x: f64) f64` | `0` inside the interval, else the distance to the nearest endpoint. |

`scale` uses `|factor|` for the width, so a negative factor mirrors the width
without inverting the endpoints and the `lo <= hi` invariant still holds. It is
also the one operation here that is not a single rounded step: for a **bounded**
input it encloses its midpoint and its half-width and composes the answer out of
`add`, `sub`, `mul` and `halve`, so it runs a few ULP wider than the exact image.
The unbounded case is not that composition at all, because the centre it needs
does not exist; it is the identity at `|factor| == 1` and the whole line
otherwise, which is loose by design rather than by rounding.

The **set** operations — `hull`, `hullOf`, `intersect`, `intersectionOf` — do
no arithmetic, so their endpoints are exact and the results need no widening.
The **geometry** operations do arithmetic and do widen: `translate` and `expand`
are one correctly rounded addition or subtraction per side for a finite argument,
so they pay one ULP per endpoint exactly as `add` does, and `scale` pays whatever
its composition pays. The infinite cases are the rows above, not a wider version
of this.
The algebraic operations pay one ULP per endpoint, with two exceptions
worth knowing: `neg` is exact, and `abs` and `sqr` of an interval straddling
zero return a lower bound of exactly `0.0`, which is already exact.

### Public struct fields

Every public struct in the package, and every field it has. The vector types and
the solver types have their own sections below, which say what the fields are
for; this is the one table that lists all of them together.

| Type | Field | Type | Meaning |
| --- | --- | --- | --- |
| `Interval` | `lo` | `f64` | The lower bound, inclusive. |
| `Interval` | `hi` | `f64` | The upper bound, inclusive. `lo <= hi` holds for every interval the library builds; writing the endpoints yourself bypasses that. |
| `Vec(n)` | `comps` | `[n]Interval` | The components, inline in the struct. No allocator, so the type cannot fail to build and cannot leak. |
| `DynVec` | `gpa` | `std.mem.Allocator` | The allocator every result of this box is drawn from, and the one `deinit` frees with. |
| `DynVec` | `comps` | `[]Interval` | The components, owned. Its `len` is the runtime dimension. **Do not replace the slice**: it is the storage `deinit` frees, and a write here names memory this box never allocated. |
| `DynVec` | `own` | `[*]Interval` | The address `comps` had when the constructor returned the box. Read-only to you: `deinit` compares it against `comps.ptr` and panics in a checked build when the two differ. See [`one box, one owner`](#iadd-versus-add-who-owns-the-box). |
| `lp.Lin` | `coeffs` | `[]const Interval` | One coefficient per variable, borrowed from the system rather than owned. A row from `at` is a view, so writing through it does not compile. |
| `lp.Lin` | `rhs` | `Interval` | The right-hand side, enclosing the one unknown value the row constrains. |
| `lp.System` | `gpa` | `std.mem.Allocator` | Where the system allocates, and what `deinit` frees with. |
| `lp.System` | `var_count` | `usize` | The number of variables, fixed for the life of the system at `init`. |
| `lp.System` | `coeffs` | `std.ArrayList(Interval)` | Every coefficient of every row in one row-major list, `var_count` entries per row. |
| `lp.System` | `rhs` | `std.ArrayList(Interval)` | One right-hand side per row, parallel to `coeffs`, so `rhs.items.len` is the row count. |
| `lp.System` | `alive` | `[]bool` | One flag per variable, cleared when that variable has been eliminated. |
| `lp.System` | `unsat` | `bool` | Set once an added or derived row is a contradiction. Both paths set it: `add` checks the row it stores, and `eliminate` checks every row the round derives. This is the field behind `isUnsat`, which returns it unchanged. |

Treat the two `Interval` endpoints as read-only: writing `a.lo` directly
bypasses the `lo <= hi` check that `init` and every operation rely on, and the
inverted interval that produces is the caller's to carry.

The two `DynVec` fields are read-only in the same sense, and for a sharper
reason. `comps` is the storage `deinit` frees and `own` is the record of what
that storage was, so writing either desynchronises the box from the allocator
it came from. Zig 0.16 has no field privacy and the fields are public, so
nothing in the type can stop the write — an assertion inside `deinit` is what
catches it, and that assertion is compiled out in a release build.

### Elementary functions — free functions

All are reachable as `interval.<name>` and again as `interval.ext.<name>`.

| Function | Semantics |
| --- | --- |
| `sqrt(x: Interval) ?Interval` | `[√lo, √hi]`. **`null` when `hi < 0`.** |
| `cbrt(x: Interval) Interval` | `[∛lo, ∛hi]`. Monotone and real on all of ℝ, so it never fails. |
| `pow(x: Interval, n: i32) Interval` | `x^n` for a **plain integer** exponent, by squaring. Never `null`; `pow(x, 0)` is exactly `[1, 1]`. **`[-inf, inf]` when `n < 0` and `x` contains zero.** |
| `powf(x: Interval, y: Interval) ?Interval` | `x^y` with an **interval** exponent, which needs real analysis rather than repeated squaring. Each base endpoint is evaluated as `exp(log(base) * y)` with this library's own `log`, `mul` and `exp`, and the two endpoints are hulled. **`null` when `x.lo < 0`**: a negative base raised to a general exponent has no real value. **`[0, +inf]` when the base reaches zero and the exponent reaches down to zero** — the trigger is reaching down to zero, not passing any particular value, and the lower bound is `0` rather than `-inf` because a positive base has a positive power. A base of exactly zero under an exponent that stays positive is `[0, 0]`, gaining the value `1` when the exponent reaches exactly zero. No path returns a negative bound. |
| `exp(x: Interval) Interval` | `[e^lo, e^hi]`. Increasing, total, unbounded. |
| `exp2(x: Interval) Interval` | `[2^lo, 2^hi]`. |
| `expm1(x: Interval) Interval` | `[e^lo − 1, e^hi − 1]`; keeps precision where `exp(x) - 1` would cancel. |
| `log(x: Interval) ?Interval` | `[ln lo, ln hi]`. **`null` when `hi <= 0`.** |
| `log2(x: Interval) ?Interval` | `[log₂ lo, log₂ hi]`. **`null` when `hi <= 0`.** |
| `log10(x: Interval) ?Interval` | `[log₁₀ lo, log₁₀ hi]`. **`null` when `hi <= 0`.** |
| `log1p(x: Interval) ?Interval` | `[ln(1 + lo), ln(1 + hi)]`. **`null` when `1 + hi <= 0`**, i.e. `hi <= -1`. Keeps precision near zero. |
| `sin(x: Interval) Interval` | Image of the interval under `sin`. Exactly `[-1, 1]` when the interval spans a full period. |
| `cos(x: Interval) Interval` | Image under `cos`. Exactly `[-1, 1]` over a full period. |
| `tan(x: Interval) Interval` | **`[-inf, inf]` when the interval contains a pole** at `π/2 + kπ`. Monotone between poles. |
| `asin(x: Interval) ?Interval` | Increasing on `[-1, 1]`. **The argument is clipped to `[-1, 1]`**, so `asin([-4, 0.5])` answers `[-pi/2, asin(0.5)]` rather than nothing. `null` exactly when the argument misses the domain whole, which is when its true image is empty. |
| `acos(x: Interval) ?Interval` | Decreasing, so the endpoints swap — and a clip can cross them, which is why the shared envelope takes a min and a max rather than the two ends in order. **Clipped to `[-1, 1]`**; `null` exactly when the argument misses the domain whole. |
| `atan(x: Interval) Interval` | Increasing into `(-π/2, π/2)`, real everywhere. |
| `atan2(y: Interval, x: Interval) Interval` | Quadrant-aware arctangent of the point `(x, y)`. Unlike `atan`, it knows the signs of both coordinates and so covers the whole plane. Real everywhere, so it never returns `null`. |
| `sinh(x: Interval) Interval` | Increasing, real everywhere. |
| `cosh(x: Interval) Interval` | Even, so the result is `[min, max]` of the two endpoint values. |
| `tanh(x: Interval) Interval` | Increasing into `(-1, 1)`, real everywhere. |
| `asinh(x: Interval) Interval` | Odd, increasing, real everywhere. |
| `acosh(x: Interval) ?Interval` | **Domain is `[1, ∞)`, so `null` when `hi < 1`.** |
| `atanh(x: Interval) ?Interval` | Rising over the **open** `(-1, 1)`, and **clipped to it**: a clipped end sitting exactly on `±1` is the pole and answers the matching infinity, so `atanh([-2, -0.5])` is `[-inf, atanh(-0.5)]` and `atanh([-2, 2])` is the whole line. `null` when the argument misses the domain whole — **including the one shape a closed-domain clip would have accepted**: an argument whose only overlap with `(-1, 1)` is the endpoint itself, such as `atanh([1, 2])`, whose true image really is empty. |
| `floor(x: Interval) Interval` | Monotone, so it is evaluated at both ends, combined with min/max, and widened. An **enclosure** of the integer values in the image, not a value snapped onto integers. |
| `ceil(x: Interval) Interval` | Same construction with `ceil`. |
| `trunc(x: Interval) Interval` | Same construction, toward zero. |
| `round(x: Interval) Interval` | Same construction with `@round`'s rule, which breaks ties away from zero: `round([-0.5, 0.5])` brackets `[-1, 1]`. |

`powf` publishes no constant to read. How tight a `powf` result can be is
answered by the composition it is built from, not by a number: the width is
whatever this library's own `log`, `mul` and `exp` produce for that argument,
and it grows with the argument rather than sitting at a fixed figure. The
margin that used to be published here, `interval.ext.pow_margin`, was deleted
along with the `std.math.pow` call it belonged to, because it was a guess at a
primitive's error that the primitive could not keep to.

#### Critical points, and why `sin` and `cos` are special

`sin` and `cos` are computed by locating the **critical points** of the function
that fall inside the argument interval, and evaluating there — not by reducing
the argument modulo `2π`. Reduction loses precision: it subtracts large
quantities to obtain a small remainder, and the error in that subtraction
grows with the size of the argument.

Locating the points subtracts nothing at run time. It only decides which
integers `k` fall inside the argument, by dividing the ends of the argument by a
certified interval for π and taking the integers between. A decision that is
wrong in either direction is harmless: a critical point that is not really
there contributes a ±1 that the range already contains, and a pole that is not
really there reports an unbounded tangent that still contains the finite one.
The one failure that is not harmless is missing a point that is there, which is
why the quotients are biased outward rather than inward.

The endpoints of the argument are evaluated directly and widened by the same
three ULP steps as every other computed bound. The payoff is that when an
interval spans a full period the answer is exactly `[-1, 1]`, with no
accumulated reduction error at all.

### Comparisons — certain, not existential

These answer *"is this relationship **certain**?"*, not *"does it hold
somewhere?"*. `lt` is true when every point of `self` is below every point of
`other`; it is false the moment the two intervals touch or overlap, even
though the relationship does hold for some pairs of points.

This is the single most misreadable part of any interval API, so it is worth
being blunt: `Interval.init(1, 3).lt(Interval.init(2, 4))` is `false`, not
`true`.

| Method | True exactly when |
| --- | --- |
| `eql(self: Interval, other: Interval) bool` | The two intervals are the same set. Structural, on the stored fields: `Interval.init(+inf, +inf)` and `Interval.init(floatMax, +inf)` are the same interval, and a struct literal holding the point `+inf` is not the ray. |
| `ne(self: Interval, other: Interval) bool` | `!eql` — the two intervals are not the same set. Note this is *not* the disjointness predicate: for that, use `!a.overlaps(b)`. |
| `lt(self: Interval, other: Interval) bool` | `self.hi < other.lo`. **Not** `self.lo < other.hi`. |
| `le(self: Interval, other: Interval) bool` | `self.hi <= other.lo`. |
| `gt(self: Interval, other: Interval) bool` | `self.lo > other.hi`. |
| `ge(self: Interval, other: Interval) bool` | `self.lo >= other.hi`. |

`eql` and `ne` are the only two of the six that are not order comparisons.
`eql` is structural — the endpoints determine a closed interval, so a strict
superset is not equal — and `ne` is its negation.

If you want the existential question instead, spell it out with `overlaps`,
`intersect` and `contains`, whose answers are already about points rather than
about whole sets.

### Empty, `null`, and unbounded

Three different conditions, three different answers. Conflating them is the
easiest way to get a solver wrong.

| Condition | When | Result |
| --- | --- | --- |
| **Empty in the reals** | No real value satisfies the query. | `null` |
| **Unbounded** | Every real number is a possible answer. | `Interval{ .lo = -inf, .hi = inf }` |
| **Bounded** | The usual case. | A finite interval |

**Empty → `null`, and everything else clips.** `sqrt` of an interval entirely
below zero, `log` / `log2` / `log10` / `log1p` of an interval wholly outside
their domain, and `acosh` with `hi < 1` are `null` because the true image
really is empty. Everything else **clips** the partly off-domain part and
refuses only a wholly invalid one: `asin(Interval.init(-1.5, 0.5))` is
`[-pi/2, asin(0.5)]` rather than `null`, and `atanh(Interval.init(-2, -0.5))`
is `[-inf, atanh(-0.5)]` because the clipped end is the pole and a pole
answers with an infinity. So `null` means exactly one thing in this package —
the true image is empty in the reals — and a caller doing global
reachability does not have to split the domain by hand at every call site to
get a sound answer.

`powf` is the exception, and it is an exception about the mathematics rather
than about convenience: it is `null` when `x.lo < 0`, because a negative base
raised to a general real exponent has no real value at **any** part of the
argument, not only outside some part of it. There is nothing to clip to.

`intersect` of disjoint intervals and the empty folds `hullOf` /
`intersectionOf` of an empty slice are `null` too. The question "what is `√x`
for `x ∈ [-4, -1]`?" has no answer, and `null` says so.

**Unbounded → an infinite interval.** `div` and `recip` when the divisor
contains zero (including a divisor that merely *touches* zero, such as
`[0, 1]`); `tan` across a pole; `pow` with a negative integer exponent applied to
a base that contains zero; and `powf` whose exponent interval reaches down to
zero, applied to a base that reaches zero. The question "what is `1 / x` for
`x ∈ [-1, 1]`?" has a perfectly good answer — all of ℝ — so the result is
`[-inf, inf]`, not `null`. `powf` is the one-sided case among these: a positive
base has a positive power, so it answers `[0, +inf]` rather than all of ℝ.

```zig
// Unbounded: a real answer, just not a finite one.
const q = Interval.init(1.0, 2.0).div(Interval.init(-1.0, 1.0)); // [-inf, inf]

// Empty: no real answer at all.
const r = interval.sqrt(Interval.init(-4.0, -1.0));               // null
```

`[-inf, inf]` and `null` are not interchangeable, and neither is a third thing
that happens to be spelled like them. For an `Interval` this library *builds*
there is no separate empty-interval representation, because `lo <= hi` always
holds: an empty result is `null`, and a degenerate result is the single point
`[x, x]`. The one way to hold an inverted interval is to write the endpoints
yourself — `Interval{ .lo = 4.0, .hi = -2.0 }` — and `fromArray` will carry it
into a box; see `isEmpty` in the vector section.

### Two kinds of infinity

An infinity reaches this library two ways, and they are not the same thing.

A **computed** infinity is what finite `f64` arithmetic gives you when it
overflows. It stands for a finite real past the end of the range, which is why
`roundDown(+inf)` answers `floatMax` and `roundUp(-inf)` answers `-floatMax`:
those are the outward bounds of a finite result the format cannot hold. That
behaviour is unchanged.

A **constructed** infinity is an operand you supplied, and it is not a number.
It is a direction. This library gives it one shape.

| Call | Fields you get back |
| --- | --- |
| `Interval.init(-inf, hi)` with finite `hi` | the ordinary lower-unbounded interval |
| `Interval.init(lo, +inf)` with finite `lo` | the ordinary upper-unbounded interval |
| `Interval.init(-inf, +inf)` | the whole line, unchanged |
| `Interval.init(+inf, +inf)` | **`[floatMax, +inf]`** |
| `Interval.init(-inf, -inf)` | **`[-inf, -floatMax]`** |

The last two are the **overflow rays**: the closed rays of reals past the end of
the format, in the one canonical closed form `f64` can hold. `init` checks that
you passed `lo <= hi` **first** and normalises those two pairs afterwards, so the
ordering is still your assertion and a NaN endpoint is still a caller error.

**What this costs you, stated plainly.** `Interval.init(+inf, +inf)` used to hand
back the point-shaped pair `[+inf, +inf]`. It now hands back a ray, and every
answer that reads `.lo` or `.hi` — `neg`, `width`, `contains`, `eql`,
`subsetOf`, your own code — observes the normalised fields. That is the
observable price of the contract, and it is why the invariant below names the
rays instead of leaving them implied. Two struct fields stay two struct fields,
the finite path is untouched, and there is no second normalising entry point to
learn.

**Too wide is fine.** A sound answer wider than the truth is not a defect and is
never reported as one. A whole line returned where a ray was asked for is sound.
An answer that is too *narrow* is the defect, and that is what the soundness work
in `docs/next-work-plan.md` is about.

**Why the rays are finite at one end.** `roundDown` widens by a full ULP at a
finite value, and `+floatMax` is the largest finite `f64`, so a lower bound of
exactly `floatMax` has nowhere left to step. That is why the overflow ray is
written `[floatMax, +inf]`, and it is why a result built from it comes back a
whole ULP below the corner it rounded: `roundDown(floatMax + (-3.0))` computes
`floatMax` and steps to `prevDown(floatMax)`, well below the real `floatMax - 3`
the image contains. A ray starting at `+inf` instead would spend the one arm of
the helper that cannot widen. See
[widening your own arithmetic](#widening-your-own-arithmetic) for the other
infinity mistake, which is reading one as a value to step inward from.

### Invariant

Every `Interval` **this library returns or accepts through `init`** satisfies
`lo <= hi`, its `lo` is never `+inf`, its `hi` is never `-inf`, and neither
endpoint is a NaN. The last three clauses are the canonical form the two
overflow rays take; see [two kinds of infinity](#two-kinds-of-infinity). That
holds for every value it returns, not only for ranges handed to `init`.
`expand` builds its result through `init`, so a margin that would invert
the interval traps instead of producing one; `hull` and `hullOf` take `lo` from
a minimum and `hi` from a maximum; `intersect` and `intersectionOf` guard their
result with an explicit `lo > hi` check; `translate` shifts both ends by the
same delta; and `scale` grows the width about the midpoint with `|factor|`. No
public function can return an inverted interval in a checked build.

The four clauses are checked and then established, in that order: `init` asserts
the ordering **before** it normalises, so the requirement is still yours and
`init(+inf, -inf)` traps exactly as it always did. Everything after it holds for
canonical inputs under their stated preconditions, and the arithmetic needs no
branch of its own to keep it: a canonical pair carries no `+inf` at the low end
and no `-inf` at the high end, so no corner can cancel into a NaN.

The exceptions are both the caller's, and both are literal ones. `Interval` is a
struct with public endpoints, so `Interval{ .lo = 4.0, .hi = -2.0 }` compiles and
gives you an inverted interval with nothing to catch it; from there `fromArray`
will carry it into a box. The library never hands you one; it can only let you
make one. The same is true of a non-canonical infinite pair:
`Interval{ .lo = inf, .hi = inf }` compiles and gives you the point `+inf`
rather than the overflow ray, and nothing normalises it afterwards, because
`hull`, `hullOf`, `intersect` and `intersectionOf` take canonicality from their
inputs and repair nothing. If you want the ray, call `init`.

`init` checks the invariant with `std.debug.assert`, which traps in Debug and
ReleaseSafe builds. The check is elided in ReleaseFast and ReleaseSmall, so in
those builds the caller is responsible for passing a valid range.

Widening preserves the invariant: `roundDown` only ever decreases a lower bound
and `roundUp` only ever increases an upper bound, so a valid input interval
produces a valid output interval.

## Vector forms

The same mathematics in ℝⁿ, as an n-dimensional box. Two types, because the
dimension is worth treating in two different ways.

| | `Vec(n)` | `DynVec` |
| --- | --- | --- |
| Dimension | Fixed at compile time by `n` | Chosen at runtime |
| Storage | Inline in the struct, stack-allocated | A slice, heap-allocated |
| Specialisation | Monomorphised per `n` | One compiled body |
| Allocator | None | Required at construction, stored in the value |
| Bounds checks | On `get` and `set`, in Debug and ReleaseSafe | On `get` and `set`, in Debug and ReleaseSafe |
| Best for | Small fixed dimensions in hot code | Data-driven dimensions |

`get` and `set` bounds-check their index, on both types. `Vec(n)` indexes a
`[n]Interval` field and `DynVec` indexes a slice, and Zig checks a runtime index
into either one in Debug and ReleaseSafe. As with every `std.debug` assertion,
the check is compiled out in ReleaseFast and ReleaseSmall, so those two are
the only modes in which an out-of-range index goes unchecked, and the caller
is responsible there.

Use `Vec(n)` when the dimension is a constant in your program — 2 for a
rectangle, 3 for a bounding box, 7 for a state vector. It has no allocator in
its type, so it cannot leak and cannot fail. Use `DynVec` when the dimension
arrives from data: a user-supplied dimension, a parsed file, a config value.

```zig
const interval = @import("interval");
const Interval = interval.Interval;

// Compile-time dimension.
const box = interval.Vec(3).fromArray(.{
    Interval.init(0.0, 1.0),
    Interval.init(0.0, 10.0),
    Interval.init(0.0, 10.0),
});

// Runtime dimension, with an allocator.
var dyn = try interval.DynVec.init(std.heap.page_allocator, 3, Interval.init(0.0, 1.0));
defer dyn.deinit();
```

### Constructors and accessors

| Method | `Vec(n)` | `DynVec` |
| --- | --- | --- |
| `init(fill: Interval) Vec(n)` | Every component set to `fill`. | `init(gpa, n: usize, fill: Interval) !DynVec` |
| `fromArray(comps: [n]Interval) Vec(n)` | Build from a literal. Checks nothing, so this is where an inverted component can enter — see `isEmpty`. It normalises nothing either: the ray contract is `init`'s, so a component written as a struct literal keeps a non-canonical infinite pair. | `fromArray(gpa, comps: []const Interval) !DynVec`, which copies and checks nothing either. |
| `dim(self) usize` | `n`. | The runtime length. |
| `get(self, i: usize) Interval` | Component `i`. | Component `i`. |
| `set(self: *Self, i: usize, v: Interval) void` | Overwrite component `i`, through a pointer. | Overwrite component `i`, through a pointer. |
| `slice(self) []const Interval` | View of the components. | View of the components. |
| `deinit(self: *DynVec) void` | — | Frees the storage. Idempotent: a second call frees nothing. In a checked build it also panics, naming the mistake, if `comps` was replaced since construction. |
| `eql(self, other) bool` | Same dimension and same components. | Same. |

`DynVec` stores the allocator it was built with, so value-returning operations
do not take one again: they allocate from `self.gpa`.

### Operations

Every operation is componentwise, so the guarantees of the scalar API carry
over unchanged. Every result is an enclosure.

| Operation | `Vec(n)` | `DynVec` |
| --- | --- | --- |
| `add`, `sub`, `mul`, `div` | `(self, other) Vec(n)` | `(self, other) !DynVec` |
| `neg`, `recip`, `abs`, `sqr` | `(self) Vec(n)` | `(self: *DynVec) void`, **in place** |
| `hull` | `(self, other) Vec(n)` | `(self, other) !DynVec` |
| `intersect` | `(self, other) ?Vec(n)` | `(self, other) !?DynVec` |
| `overlaps`, `subsetOf`, `eql` | `(self, other) bool` | `(self, other) bool` |
| `contains` | `(self, p: [n]f64) bool` | `(self, p: []const f64) bool` |
| `distance` | `(self, p: [n]f64) f64` | `(self, p: []const f64) f64` |
| `isEmpty` | `(self) bool` | `(self) bool` |

Three shape differences from `Vec(n)`, and the third one is the one that costs
you memory if you miss it:

- **Value-returning operations allocate and return `!DynVec`.** They build a
  new value from `self.gpa`; they do not mutate. They fail with
  `error.DimensionMismatch` when the dimensions differ and `error.OutOfMemory`
  when allocation fails.
- **Unary operations mutate in place and return `void`.** `dyn.neg()` changes
  `dyn` and hands back nothing, because there is nothing to hand back. For the
  binaries, `iadd`, `isub`, `imul` and `idiv` mutate in place and return
  `!void`.
- **The value-returning forms hand you a box you own; the in-place forms hand
  you nothing.** `add`, `sub`, `mul`, `div`, `hull` and `intersect` each
  allocate one new box, which the caller must `deinit`. `iadd`, `isub`, `imul`,
  `idiv`, `neg`, `recip`, `abs` and `sqr` allocate nothing at all.

### `iadd` versus `add`: who owns the box

This is the most actionable thing in the vector API, because the line that
leaks is the line that reads best. `add` returns a **new** `DynVec` that the
caller owns, and it leaves the receiver alone, so assigning the result over the
receiver drops the previous box on the floor — one leak per iteration:

```zig
var acc = try interval.DynVec.init(gpa, n, fill);
defer acc.deinit();

for (others) |o| acc = try acc.add(o); // one leaked box per iteration
```

Two ways out, and the first is the one to reach for by default: take the
in-place form, which allocates nothing and so has nothing to free.

```zig
for (others) |o| try acc.iadd(o); // in place, no allocation
```

Or free the previous box before overwriting it, which is the only way to keep
the value-returning form when you need the old box to survive the step:

```zig
for (others) |o| {
    const next = try acc.add(o);
    acc.deinit();
    acc = next;
}
```

The same trap applies to `sub`, `mul`, `div` and `hull`. For `intersect` there
is nothing to free on the `null` arm, because no box was built:

```zig
if (try acc.intersect(o)) |shared| {
    acc.deinit();
    acc = shared;
}
// else: no box, and acc is unchanged
```

`iadd` and its three siblings still return `!void` rather than `void` because
they check the widths before they touch anything, so they can report
`error.DimensionMismatch` having changed nothing. `neg`, `recip`, `abs` and
`sqr` take no operand and so return plain `void`.

One rule underpins all of it: **one box, one owner.** A constructor hands the box
to the caller, and so does every method that returns a `DynVec`; the receiver
keeps whatever it held, and the new owner frees that box once, with `deinit`,
using the allocator the box was built from.

`deinit` is **idempotent** — calling it twice on one box is safe and frees
nothing the second time, because the component slice is swapped for an empty one
before the free and freeing an empty slice is a no-op. A deinited box is a
zero-dimensional box: `dim()` is 0 and `slice()` is empty.

What idempotence does **not** buy is safety for a copy. `var b = a;` is a second
reference to the *same* slice, not a second box, so freeing both is a double
free, and nothing in the type can catch it — Zig has no move qualifier to forbid
the copy with, and the copy carries the recorded address along with it, so the
check below does not fire for it either. The assignment that honours the rule
is the free-then-overwrite form above.

There is one more mistake the type *can* catch, and it is caught by an
assertion rather than by the type system: replacing `comps`. Both fields are
public and Zig 0.16 has no field privacy — a private inner struct would hide
nothing either, since the fields are reached through the same path either way —
so a caller can point `comps` at a slice this box never allocated. Freeing that
through `gpa` hands the allocator memory it never handed out: silent heap
corruption under a release allocator, and under a checked one a death inside
`Allocator.free` that names the allocator rather than the mistake. So **the
slice must not be replaced after construction**, every constructor records the
address it had in `own`, and `deinit` compares that record against `comps.ptr`:

```text
panic: DynVec.deinit: comps was replaced since construction: this box does not own the slice it holds, and freeing it hands the allocator memory it never allocated
```

**A release build does not catch it.** The check is an assertion, so
ReleaseFast and ReleaseSmall elide it and free the wrong slice exactly as
before; the rule is the caller's to keep in every build mode. It is the same
trade every other check in this library makes, and the recorded address is also
what makes idempotence hold — `deinit` swaps the slice for an empty one that
keeps the address, so the comparison passes on every call after the first. It
is an address rather than a length because a length check would also pass for a
box reassigned a slice of the same width, which is the mistake the record
exists to catch.

### Semantics worth stating outright

- **`intersect` is null if ANY component is disjoint.** The intersection of
  boxes is a box, and it is empty as soon as one coordinate is empty — no
  amount of overlap in the other coordinates rescues it. Two boxes that agree
  everywhere except across a gap in the first coordinate do not intersect.

- **`distance` is the Euclidean norm**, the square root of the sum of squared
  per-component `distanceTo` values. It is *not* the max metric, which would
  return the largest single-component distance and is the right answer for a
  different question (how far can you move and stay inside the box). If you want
  the max metric, take the max of `distanceTo` yourself.

- **`isEmpty` is true when some component is inverted, `lo > hi`.** A box is the
  product of its components, so one empty coordinate leaves the whole box
  holding no point at all. Every box this library *builds* obeys `lo <= hi` in
  every component, because `Interval.init` asserts it, the widening preserves
  it, and `intersect` reports an empty result as a `null` rather than storing
  one — so on any box you did not assemble yourself the answer is `false`, and
  emptiness is still a `null` from `intersect` or a dimension mismatch from a
  binary operation.

  **`fromArray` is the one door an inverted component comes through.** It takes
  the components as given and re-checks nothing, on both types, and it does not
  normalise them either — the ray contract is `init`'s, and a box is not a second
  place to enforce it — so an inverted interval, or a non-canonical infinite
  pair, placed there produces a box that exists and holds what you put in it:

  ```zig
  // Interval.init asserts lo <= hi and traps, so an inverted component has
  // to be written as a literal.
  const inverted: Interval = .{ .lo = 4.0, .hi = -2.0 };
  const empty = interval.Vec(2).fromArray(.{ Interval.init(0, 1), inverted });

  // true: no point satisfies both components
  empty.isEmpty();
  // false, and not merely because isEmpty said so
  empty.contains(.{ 0.5, 2.0 });
  // false: it holds no point to share
  empty.overlaps(empty);
  ```

  Writing a component through `set` has the same effect as building it that
  way. Two things `isEmpty` is *not*: a NaN endpoint is not emptiness (`lo > hi`
  is false for it — it is the poison the scalar contract names), and a deinited
  `DynVec` is not empty either, since a zero-dimensional box has no component
  to reach this fold.

### `mapResult`

```zig
pub fn mapResult(v: anytype, f: *const fn (Interval) ?Interval) MapResult(@TypeOf(v))
```

Applies an elementary function to every component. The argument is a plain
function pointer, so it must be a top-level function or a comptime-known
declaration — closures are not accepted. The result is `null` if **any**
component maps to `null`, since a single empty coordinate makes the whole image
empty. The receiver is left alone either way.

`MapResult` is the per-shape result type, and it is what follows the receiver:

| Receiver | Result type | Why |
| --- | --- | --- |
| `Vec(n)` | `?Vec(n)` | It fills a stack array. There is no allocator to fail on and no error to return. |
| `DynVec` | `DynVec.Error!?DynVec` — that is `error{DimensionMismatch, OutOfMemory}!?DynVec` | It allocates from `v.gpa`, so the fold can fail. |

The split is per shape rather than one `!?V` because the error set of a single
`!?V` is collected from *every* `try` in the body, reachable or not: one function
with an arm per shape hands the `Vec(n)` arm an `error.OutOfMemory` it can
neither produce nor catch, and makes every caller of that arm write a `try` that
can never fire. `mapResult` on a `Vec(n)` therefore has **no error set at all**,
and `try` on it does not compile:

```
error: expected error union type, found '?vector.Vec(2)'
note: consider omitting 'try'
```

The `DynVec` arm carries the whole `DynVec.Error` even though a unary fold
compares no widths, so only `error.OutOfMemory` is reachable there. Handle both
at the call site, or the compiler will not let you forget one.

The receiver is a box **by value**. A pointer is a compile error, and that is
deliberate: a pointer says nothing about where the result should be built, and
the shape that accepted one declared `var out: V = undefined` with `V` a pointer
and wrote the components through it, which is a segfault in every build mode
rather than a wrong answer.

```
error: mapResult takes a box by value: pass the box, not a pointer to it.
```

So a fixed box takes no `try`, and an owned box takes one **and hands you a box
you now own**:

```zig
// Vec(3): the result is ?Vec(3), so no try.
const roots = interval.mapResult(box, interval.sqrt);

// DynVec: the result is an error union over the same optional, and the
// non-null arm is a box you must deinit — hence `var`, because deinit
// takes the box by pointer.
var dyn_roots = (try interval.mapResult(dyn, interval.sqrt)) orelse
    return error.NoRealAnswer;
defer dyn_roots.deinit();
```

On the `null` arm of the `DynVec` case there is nothing to free: the partial box
is released before the `null` is returned, so a `null` costs nothing beyond the
allocations already made.

This is the reason the elementary functions are plain functions of an
`Interval` rather than methods: with that shape, applying one across a vector
is a single generic, rather than 28 hand-written per-function wrappers whose
only difference is which function pointer they pass along. The cost of that
shape is that **not every function in the table above works here**. The
parameter type is `fn (Interval) ?Interval`, and only the ten functions that
can report an empty result are coercible to it: `sqrt`, `log`, `log2`, `log10`,
`log1p`, `asin`, `acos`, `acosh`, `atanh` and `powf`. The other eighteen return
a plain `Interval`, which is not a `?Interval` and will not compile at this call
site; to apply one of those across a box, call it on each component and build
the box yourself. Any function of your own with the matching signature works.

## Fourier-Motzkin solver — `interval.lp`

A solver for systems of linear inequalities over the reals, where the
coefficients and the right-hand sides are themselves intervals rather than
points.

```zig
const lp = @import("interval").lp;
```

The question it answers is: *given these constraints, where can the variables
be?* The answer comes back as a box — an interval per variable — that is a
**guaranteed superset** of the feasible region. It will not miss a feasible
point, and it will often be loose, because a box is a coarse description of
what may be a polygon or a parallelepiped.

### What it is for

A system like

```text
x + y <= 10
x - y <= 2
-x + y <= 4
-x - y <= 6
```

has a feasible region with four sides. The solver eliminates variables one at a
time and returns `x ∈ [-5, 6]`, `y ∈ [-4, 7]`, the tightest box containing the
region. That box is what you want for range analysis, for bounding a search, or
for feeding an interval-arithmetic computation that must stay sound.

### The types

| Type | Meaning |
| --- | --- |
| `Cmp` | The comparison in a linear inequality: `enum { le, lt, ge, gt, eq }`. |
| `Lin` | One stored inequality, always `<=`: `struct { coeffs: []const Interval, rhs: Interval }` — `sum(coeffs[i] * x_i) <= rhs`. **`coeffs` is `const`**, so a row from `at` is a view and writing through it does not compile. There is no comparison field, because every stored row is `<=` and nothing on one could say otherwise. |
| `System` | A mutable collection of `Lin` plus the variable count. |

A coefficient is **universal** and a right-hand side is **existential**. A row
is a claim that `sum(coeffs[i] * x_i) op rhs` holds for *every* realisation of
the coefficient intervals, so the solver may only derive constraints true in all
of them, and it widens a derived row outward rather than picking the convenient
value. The right-hand side is not a family of bounds to be quantified over:
`rhs` encloses *one* unknown bound value, and an enclosure of it bounds that one
value. Reading the right-hand side as a universal constraint instead is the
mistake that makes a projection come back too small, which is the one failure
this solver must never produce.

`Lin` **borrows**: the slice returned by `try at(i)` and the slices inside it
into the system's own storage. They are invalidated by the next `add` or
`eliminate`, and freed by `deinit`. Hold a copy of the data, not of the `Lin`.

Every row is **normalised to `<=` on insertion**: `eq` splits into a `<=` and a
`>=`, and `ge`/`gt` are multiplied through by `-1` and stored as `<=` too. So
`Lin` carries no comparison field to read: a row is `<=` because that is the
only shape there is, not because a field says so. An `eq` you add shows up as
two rows.

Strict comparisons are additionally **relaxed** on the way in, because
strictness is not representable in a closed interval: `gt` becomes `ge` and
`lt` becomes `le`, each flipped through by `-1` on the way to the stored `-coeffs
<= -rhs`. Relaxing is the only sound direction — a system you believe is
strictly bounded has its bound widen, never tighten.

### Operations

| Method | Semantics |
| --- | --- |
| `init(gpa, var_count: usize) !System` | An empty system over `var_count` variables. Allocating the liveness flags is the one fallible step in building a system, and it is reported as `error.OutOfMemory` like every other allocation rather than panicked. |
| `deinit(self: *System) void` | Free everything. |
| `varCount(self) usize` | The number of variables, fixed at `init`. |
| `rowCount(self) usize` | The number of stored **rows**, not of constraints. A row added as `eq` is stored as two, so three constraints of which one is an `eq` answer `4` here. `gt` and `lt` are relaxed rather than duplicated, so the inflation is specifically from equalities and its factor cannot be predicted from the input count. |
| `add(self, coeffs: []const Interval, op: Cmp, rhs: Interval) !void` | Insert a constraint, copying `coeffs`. `coeffs.len` must equal `varCount()`, else `error.BadVariableCount`. An `eq` inserts two rows. |
| `at(self, i: usize) !Lin` | Row `i`, borrowed and **read-only**: `error.BadRow` for an index at or above `rowCount()`, and `row.coeffs` is a `[]const` so a write through the view is a compile error rather than a silent edit of the solver's own storage. |
| `isUnsat(self) bool` | True once the system holds a row with an all-zero coefficient vector and a strictly negative right-hand side, whether `add` stored that row or `eliminate` derived it. Conflicting rows that both mention a variable are not such a row, so this is `false` until an elimination pairs them. |
| `eliminate(self, k: usize) !void` | Eliminate variable `k` exactly. `error.BadVariable` for an out-of-range index, `error.VariableEliminated` for one already gone. |
| `eliminationOrder(self) ![]usize` | The order the solver would pick. Caller-owned; free it with the system's allocator. |
| `eliminateInOrderOfChoice(self) !bool` | Eliminate in that order. Returns `false` when the system is proven unsatisfiable. |
| `bounds(self, k: usize) !?Interval` | The derived interval for variable `k`. `null` when `k` is unbounded in either direction, when the system is unsat, or when the derived lower and upper bounds come out disjoint. |
| `box(self) !?[]Interval` | The derived box, one interval per variable. `null` when unsat or when any variable is unbounded. Caller-owned; free it with the system's allocator. |

`bounds` and `box` **project the current system**, so they only mean anything
while the variables are still live: after `eliminate` has removed one, there is
nothing left to project and the answer is `null`. Neither mutates the caller's
system — each runs its elimination on a private clone — so you can read the
box first and then eliminate everything on the same system.

```zig
const satisfiable = try sys.eliminateInOrderOfChoice();
if (!satisfiable) return;
```

### Why the elimination order matters

Eliminating a variable from a system of linear inequalities is straightforward
and explosive. Split the rows into those that give an upper bound on the
variable and those that give a lower bound, then form **every pair**, one
upper with one lower: each pair yields a new constraint on the remaining
variables. If `u` rows are upper bounds and `l` are lower bounds, eliminating
one variable multiplies the row count by up to `u * l`.

Tupper's contribution — the result this implementation follows — is that the
growth is controllable by choosing *which* variable to eliminate next, not by
changing the algorithm. Score each remaining variable by the number of pairs its
elimination would generate, eliminate the cheapest, and rescore. Because the
row count drives the next round's scores, an unlucky order can multiply the
system by orders of magnitude while a good one keeps it modest.
`eliminationOrder()` returns the chosen order and `eliminateInOrderOfChoice()`
applies it.

### What interval coefficients cost you

With point coefficients, a row that mentions the variable being eliminated is
unambiguously an upper bound or a lower bound, and the pairing above is exact.
An interval coefficient that **straddles zero** is neither: the same row can act
as an upper bound for one value of the variable and a lower bound for another.

The solver does not guess. Such a row contributes to *both* sides of the
pairing, so it generates pairs it might not need to. The derived region is
therefore a guaranteed **superset** — never too small, sometimes larger than
necessary. Widening a coefficient cannot make the solver unsound; it can only
make the answer wider, which is the correct direction for a tool whose purpose
is to never report a false bound.

### A worked example

```zig
const std = @import("std");
const interval = @import("interval");
const lp = interval.lp;

pub fn main(init: std.process.Init) !void {
    var stderr = std.Io.File.stderr().writer(init.io, &.{});
    const out = &stderr.interface;
    var sys = try lp.System.init(std.heap.page_allocator, 2);
    defer sys.deinit();

    // x + y <= 10
    try sys.add(&.{ interval.Interval.init(1, 1), interval.Interval.init(1, 1) }, .le, interval.Interval.init(10, 10));
    // x - y <= 2
    try sys.add(&.{ interval.Interval.init(1, 1), interval.Interval.init(-1, -1) }, .le, interval.Interval.init(2, 2));
    // -x + y <= 4
    try sys.add(&.{ interval.Interval.init(-1, -1), interval.Interval.init(1, 1) }, .le, interval.Interval.init(4, 4));
    // -x - y <= 6
    try sys.add(&.{ interval.Interval.init(-1, -1), interval.Interval.init(-1, -1) }, .le, interval.Interval.init(6, 6));

    // Read the derived box while the variables are still live. box() does not
    // mutate the system, so the same system can still be reduced afterwards.
    if (try sys.box()) |derived| {
        defer std.heap.page_allocator.free(derived);
        try out.print("x in [{d}, {d}], y in [{d}, {d}]\n", .{
            derived[0].lo, derived[0].hi, derived[1].lo, derived[1].hi,
        });
        // x in [-5, 6], y in [-4, 7] — the exact corners, each printed a hair
        // outside, because a derived bound is an enclosure and not the corner.
    } else {
        try out.print("no finite box\n", .{});
    }

    // To keep the reduced system rather than just read a bound, eliminate.
    if (!try sys.eliminateInOrderOfChoice()) {
        try out.print("unsatisfiable\n", .{});
        return;
    }
}
```

Eliminating `y` pairs its two upper bounds (`y <= 10 - x`, `y <= 4 + x`) with
its two lower bounds (`y >= x - 2`, `y >= -6 - x`), giving four rows in `x`
alone. Two of them are trivially true constants; the other two are
`2x <= 12` and `2x >= -10`, so `x ∈ [-5, 6]`. The same reasoning in the other
direction gives `y ∈ [-4, 7]`. The true feasible region is a parallelogram, and
the box is the tightest one containing it. Those two ranges are the exact
corners of that box; what the code prints sits a few ULP outside them, because
every bound it derives is an enclosure rather than a corner.

An unsatisfiable system, and where the unsatisfiability is reported. Note that
**adding the two conflicting rows is not enough** for `isUnsat` to say so:

```zig
const std = @import("std");
const interval = @import("interval");
const lp = interval.lp;

pub fn main(init: std.process.Init) !void {
    var stderr = std.Io.File.stderr().writer(init.io, &.{});
    const out = &stderr.interface;
    var sys = try lp.System.init(std.heap.page_allocator, 1);
    defer sys.deinit();

    // x <= 1
    try sys.add(&.{interval.Interval.init(1, 1)}, .le, interval.Interval.init(1, 1));
    // x >= 2, stored normalised as -x <= -2
    try sys.add(&.{interval.Interval.init(1, 1)}, .ge, interval.Interval.init(2, 2));

    try out.print("before: {}\n", .{sys.isUnsat()}); // false

    try sys.eliminate(0);

    try out.print("after: {}\n", .{sys.isUnsat()});  // true
}
```

`isUnsat` is true only once the system holds a row whose coefficient vector is
**entirely zero** and whose right-hand side is strictly negative: a row stating
`0 <= -1`, which no variable can rescue. Neither row above is that, because both
mention `x`. It is the elimination that derives it, pairing `x <= 1` against
`x >= 2` and cancelling the `x` terms. An `add` sets the flag too, on a
stored row of exactly that shape, so the two paths are not exclusive; what
holds either way is that rows which merely conflict are not one, and a test
of `isUnsat` on a system holding nothing but those is testing nothing.
`bounds` and `box` do not set it either: each runs its elimination on a
private clone, so read their return value, which is `null` when the system is
unsatisfiable.

## Build steps

| Step | Effect |
| --- | --- |
| `install` (default) | Installs the library artifact. |
| `test` | Runs the interval test suite and the external consumer fixture. |
| `test-compile` | Compiles the library, all 11 test binaries and the NaN probe without running tests or the host consumer. |
| `consumer` | Builds and runs the external consumer fixture on its own. |
| `docs` | Emits API documentation. |
| `bench` | Runs all three benchmarks — scalar, vector and Fourier-Motzkin — in parallel. |
| `bench-scalar` | Runs the scalar benchmark alone. |
| `bench-vec` | Runs the vector benchmark alone. |
| `bench-lp` | Runs the Fourier-Motzkin benchmark alone. |

The three single-benchmark steps are pure aliases: each names the same run step
`bench` already depends on, so nothing is built, compiled or installed
differently, and `bench` still runs all three at once. They exist so one
benchmark can be timed on its own — the LP one in particular sits next to a row
budget that is worth tightening on its own.

Two things about the benchmarks are deliberate and worth knowing before reading
a number off them. They are pinned to **ReleaseFast** regardless of
`-Doptimize`, because a figure from a Debug build of a numeric library measures
the assertions and the register spills around them, and a benchmark whose
numbers move when the flag moves cannot be compared with itself across a change
to the library. And nothing depends on the `bench` step: `install` does not
build the benchmarks and `test` does not run them, because a number is not a
gate.

### Reading `bench-lp`

`zig build bench-lp` runs one recipe twice and prints two sections.

| Section | Heap | Timed rows |
| --- | --- | --- |
| `allocator=dbg` | `std.heap.DebugAllocator` | 13 |
| `allocator=smp` | `std.heap.smp_allocator` | 13 |

Twenty-six timed rows in all. The two sections are the same thirteen bodies,
under the same names, with the same iteration counts and the same seeds; the
only thing that differs is the heap they are built on.

That difference is why both exist. These systems allocate, grow geometrically
and free, so which heap they run on is part of what is being timed: a
`DebugAllocator` charges its own guard bytes and bookkeeping to every round trip,
which makes a figure measured under one partly a measurement of the allocator.
`smp_allocator` is the fast general-purpose heap and does **no leak detection at
all**: it keeps no record of what it handed out, so it cannot report a leak and a
leak under it is invisible rather than absent. The `DebugAllocator` is therefore
the only one of the two whose end-of-run state can still be asked about, and
that question is asked about the `allocator=dbg` section only. The untimed
accounting block described below is printed for *both* sections — those counters
are the wrapper's own and do not depend on the heap having leak detection. A time
here is a property of the PAIR, workload and allocator, so quote it under the
heading it was printed beneath.

**A difference between the two tables is not, by itself, a heap measurement.**
The recipe is otherwise identical — which is what the paragraph above proves —
but which section ran first, the state the run leaves in the caches and the
allocator, and everything else on a shared host are all inside the delta too.
Separating the heap's own cost from that noise needs a same-run A/B under the
harness's controls, and no figure in this document is one.

The evidence that the second section really is the first recipe again is in the
output itself. The geometry report and every per-row `checksum` are functions of
the inputs alone, so the `allocator=smp` section must print the `allocator=dbg`
section's geometry and checksums; if it does not, the two sections differ in
something other than the allocator. So the two runs are configured alike down to
the heap and nothing else — which is a statement about the recipe, and not a
claim that the only thing their timings can differ by is the heap.

### The untimed allocation accounting

Each section prints one more block, and no clock runs there. It comes after that
section's geometry report, its timed measurements and its summary line — and
before the timing table itself, which the harness prints when the section has
finished, so the table you read for `ns/op` is the last thing that section
prints rather than the thing this block follows. Every body is swept once per
iteration its timed row runs — the same varying inputs, with `reps = 1` against
the harness's seven — through `std.testing.FailingAllocator` with `fail_index`
and `resize_fail_index` both at `maxInt`, which means the wrapper injects **no
failure of its own**: it is not set to make any particular allocation in the
sweep fail. That does not make the sweep infallible — an allocation the
underlying heap refuses still answers `error.OutOfMemory`, reaches the body's
own `catch`, and ends the run uncounted. What the setting buys is that the
counts are counts of work that really ran, rather than of the allocation at
which an injected failure stopped it.

The counters are totals over that whole range, and their definitions are not the
obvious ones:

| Column | Definition |
| --- | --- |
| `allocs` | successful `alloc` calls. A successful `resize` or `remap` is **neither** an alloc nor a free. |
| `frees` | successful `free` calls. |
| `alloc B` | the bytes of those successful allocations **plus** the positive growth of every successful `resize` or `remap`. Not a sum of requested raw sizes. |
| `freed B` | the bytes handed to `free`, plus the shrinkage of those same resizes. |
| `checksum` | this body's own sink over the sweep — not the timed table's checksum, which covers that body's warmup call and its seven repetitions. |

Every body is swept twice and the two sweeps must be identical, and every body
must come back balanced: as many frees as allocations, as many freed bytes as
allocated bytes. A difference or an imbalance ends the run rather than printing
a figure, because a count that drifts between two identical sweeps is a count of
something other than the work, and a workload allocation that outlived its call
is a defect rather than a number. The totals line counts one sweep of each body;
the second sweep exists only to be compared, and is printed by neither.

No counter runs inside a timed region, and the harness's own buffers — the `Io`
thread pool and each report's row buffer — come from a third allocator, so a
body is never billed for the table it is being printed into. The 20,000-row
budget on every elimination is unchanged by any of this, and each section's
summary line reports the wall time of its own timed measurements and that
budget — before the accounting block and before the timing table.

### Capturing a baseline

Take LP figures from `zig build bench-lp` on its own. The combined
`zig build bench` step runs all three benchmarks in parallel, so its numbers are
contended with two other benchmark processes and are not a baseline; the
per-file steps exist for exactly this. Measure on an otherwise idle machine, and
compare minima across runs rather than single figures.

**Capturing a run to a file is part of that, and it is now trustworthy.** The
benchmark report is written to stderr through a streaming, line-buffered writer.
It used to go through a writer that recorded byte offsets and wrote
positionally: correct on a terminal, wrong on a regular file, where redirecting a
run into a capture file lost rows with no error anywhere. That was found by
doing the capture, not by reading the code, so the rule recorded here is the
honest one — **capture by redirecting, then read the file back**, rather than
assuming a printed table equals a written one. The clock behind the numbers is
unchanged (`std.Io.Clock.real`, wall time), and the recipe above is the only
thing that produces a figure in this repository.

## Development

The required acceptance gate is the installed `zig-gate`, run from the prefix it
was installed into rather than from `PATH`:

```sh
QUALITY_TOOLS_PREFIX=<scratch>/zig-interval/quality-tools
"$QUALITY_TOOLS_PREFIX/bin/zig-gate"
```

There is deliberately no bare `zig-gate` in this project's contract: `.vf/gates.yml`
runs that same absolute path, so the gate that decides acceptance is the one whose
bytes are in the prefix and whose analysers are the pinned ones, not whichever
copy happens to be first on `PATH`.

### Installing the gate

`zig-gate` is not a system binary, and nothing about it has to be fetched from a
developer's home directory. It is installed from this repository, from pinned
sources, into a prefix you choose:

```sh
QUALITY_TOOLS_PREFIX=<scratch>/zig-interval/quality-tools
QUALITY_TOOLS_WORK_ROOT=<scratch>/zig-interval/quality-build
ZIG=<scratch>/zigbin/zig                  # a real 0.16.0; a PATH `zig` shim will not do

bash scripts/install-quality-tools.sh \
  --prefix "$QUALITY_TOOLS_PREFIX" \
  --work-root "$QUALITY_TOOLS_WORK_ROOT" \
  --zig "$ZIG"
```

Three required arguments, all absolute paths: `--prefix` is where the tools
land, `--work-root` is the installer's own fetch/patch/build/cache root, and
`--zig` is a real Zig 0.16.0 — the installer refuses a compiler that reports
anything else, which is why a version shim on `PATH` will not do. The remaining
flags narrow or re-check the run rather than change the recipe: `--only LIST`
builds a subset (`zbc, ziglint, zlint, zwanzig, cross-test, zig-gate, harness,
analyzers, all`), `--manifest PATH` reads an alternative source manifest,
`--optimize MODE` selects the mode the tools are built in (`ReleaseFast` by
default), `--list` prints the resolved plan and exits, `--force` overwrites an
existing prefix, `--verify-only` verifies the checked-in hashes and creates
nothing, and `--help` prints the same plan.
Exit status is 0 on success, 1 on a build or install failure, and 2 on a usage
error, a missing prerequisite, a manifest that does not parse or a checksum
mismatch; a signal that kills the installer propagates as 130, 143 or 129.

The work root is safe to cache because reuse is checked, not assumed — and the
check starts from the manifest, not from the stamp. **A stamp is a claim about
itself**, so a stamp that merely agrees with its own checkout proves nothing:
the four values it records are first *bound* to the ones this run's manifest row
lists (the pinned revision, the ordered patch hashes, the `src/**/*.zig` source
digest), and only then is the disk re-derived and compared — `git rev-parse
HEAD` against the bound revision, a freshly computed `src/**/*.zig` digest
against the bound digest, and a digest of the build inputs (`build.zig`,
`build.zig.zon`, `@embedFile` targets, top-level build files) against what the
stamp recorded for them. Anything short of all four re-fetches and re-patches.

The binding is the half that is easy to leave out, and it was: a tool with no
patches — `zlint` — whose pin later moves to a new revision keeps a stamp that
matches its own checkout perfectly, and would have been reused as though it were
the new pin. The build-input digest is the other half that is not implied by the
rest: a revision pin says nothing about a build script, so without it a restored
work root could run an edited `build.zig` against the pinned sources.

**Each analyzer is built by a named recipe, and `zbc`'s is not the other three's.**
The manifest's `build_recipe` column names one — `default` for the tool's own
default step, `cli` for its named install-only step — and the installer
dispatches that name from a fixed table. The column is never evaluated, never
expanded and never run as a command: an unrecognised name is exit 2 before
anything is fetched, never a fallback to a build nothing describes.
`ziglint`, `zlint` and `zwanzig` are `default`, a plain `zig build`. `zbc` is
`cli`, so it is built with `zig build cli`.

The reason is upstream's own build script, not a policy this repository
invented. `zbc`'s `build.zig` leaves its dogfood on the **default** step —
`zbc src/` over its own `src/`, with a CLI that returns 1 on *any* finding.
The measured `0001`–`0003` tree analyzed all 153 files and reported 75 findings,
exit 1. No self-run over current `0001`–`0005` exists; its count is unknown.
`zig build cli` builds and installs the same `zig-out/bin/zbc` without running
that self-check.

**The dogfood is not removed, weakened or re-severitised**:
`b.default_step.dependOn(&self_check.step)` is upstream's line and stays as it
is, the default step keeps the same artifact-install dependency it always had,
and no rule, severity or finding is suppressed anywhere to get a binary
installed.

Read that as the narrow claim it is: **the install step proves the pinned tree
compiles, links and installs; it says nothing about whether `zbc` finds
anything in `zbc`.** What the gate asserts about findings is a run over *this*
project's sources. The dated self-analysis is recorded in
[`tools/quality/PROVENANCE.md`](tools/quality/PROVENANCE.md); it does not
establish the current tool's self-findings. Fixing upstream's findings is outside
this project. The argv that actually ran — step and optimize mode together — is
recorded per install in `install-manifest.tsv`'s `build_recipe` column and read
back by the `analyze` job.

What a failed run leaves behind is worth stating precisely, because the useful
guarantee is narrower than "nothing half-written". Every usage, prerequisite,
manifest and checksum check finishes **before anything is created**, so a
malformed manifest or a refused path leaves the filesystem untouched. After
that the installer creates **both** roots early — the work root first, then an
empty prefix — and does the real work in a staging tree at
`$QUALITY_TOOLS_WORK_ROOT/stage/prefix`; the prefix is populated by one copy at
the very end, after every payload file has been hashed. The manifest cannot hash itself.
So a build that fails four hours in leaves the **work root** behind (fetched
sources, stamps, build logs — that is what makes the next run cheap) and
leaves the **prefix** empty; if that prefix was empty when the run started, the
installer removes it and says so. **A cold install therefore ends either with a
complete prefix or with no prefix at all** — but a failed run is not a run that
wrote nothing, and the work root is deliberately kept. `--force` over a prefix
that already existed is not transactional: files already replaced stay
replaced, and the diagnostic names where it stopped.

`--verify-only` is the read-only half, and it is genuinely read-only: it hashes
`tools/quality/` against `SHA256SUMS`, prints the plan, and exits **before**
either root is created. Neither path has to exist, and neither has to be a legal
scratch location for that run. What it proves is about the **checked-in
sources** — nothing about an installed prefix. Proving an install is intact is
the other check, and it is a different one: every row of the prefix's
`install-manifest.tsv` carries the sha256 of the file it names, so a prefix can
be re-verified byte for byte without re-running the installer:

```sh
( cd "$QUALITY_TOOLS_PREFIX" \
    && awk -F'\t' '!/^#/ && NF { print $8 "  " $7 }' install-manifest.tsv \
    | sha256sum --check --strict - )
```

That is what the `analyze` job in CI runs, after `--verify-only`; neither one
stands in for the other.

What an install puts in the prefix:

| Under `$QUALITY_TOOLS_PREFIX` | Contents |
| --- | --- |
| `bin/` | `zig-gate`, `cross-test`, `ziglint`, `zlint`, `zbc`, `zwanzig` |
| `lib/cross-test/` | `test.sh`, `test-zig.sh`, `run_policy.zig`, `zig-targets.sh`, `scratch-contract.sh` |
| `share/zig-interval-quality/` | the resolved `manifest.tsv`, `SHA256SUMS`, `PROVENANCE.md`, `licenses/`, `patches/` |
| `install-manifest.tsv` | pins, licences and hashes for every payload file, including patches. This manifest does not hash itself. |

**Licensing is stated per file, not implied by a directory name.** `bin/` and
`lib/cross-test/` are first-party code from this repository and ship under this
repository's own MIT, whose text is installed beside them as
`share/zig-interval-quality/licenses/harness.LICENSE`; the four analysers keep
their own upstream notices as `licenses/{zbc,ziglint,zlint,zwanzig}.LICENSE`.
The installer refuses a harness install that has no `harness.LICENSE` to ship,
and every row of `install-manifest.tsv` names the licence it travels under. No
third-party code is attributed to anyone other than its own authors.

The pins live in the repository, not in the install:

| In the tree | Contents |
| --- | --- |
| `tools/quality/manifest.tsv` | one row per tool: repository, pinned revision and its date, the tool's own version, the compiler it was built with, the ordered patch list and their sha256s, license, the **name** of the build recipe (`default` or `cli` — a selector, never a command; the concrete argv is recorded per install in `install-manifest.tsv`), installed path, and a source digest |
| `tools/quality/patches/` | the reviewed local patches applied on top of those revisions, in the order the manifest lists them |
| `tools/quality/SHA256SUMS` | a `sha256sum` listing covering every file under `tools/quality/` except itself |
| `tools/quality/harness/` | `zig-gate` and `cross-test` themselves |

A revision is a full 40-hex commit, and the installer re-checks it after the
fetch with `git rev-parse FETCH_HEAD`, so a pin is the content that was
reviewed rather than a tag that can move.

| Tool | Upstream | Pinned revision |
| --- | --- | --- |
| `zbc` | `ericsssan/zbc` | `419d153ca411d1698899992d86c51eb9a7e14919` |
| `ziglint` | `rockorager/ziglint` | `66709a408f2ea9ac1de91a438a83b13f4691a941` |
| `zlint` | `DonIsaac/zlint` | `3ef67af7dfed776cb03012563942cdf3a97f1b59` |
| `zwanzig` | `forketyfork/zwanzig` | `1a0768ccd889d3586ec9482f02ffffe872a99749` |

One tool carries more than its upstream, and the base revision is why it reads
that way: `zwanzig`'s pin is the last revision **published upstream**, and five
further local commits plus one uncommitted working tree sit above it as an
ordered, individually hashed patch series under
`tools/quality/patches/zwanzig/` — one file per commit, plus
`0006-uncommitted`. That is exactly why the pin is `1a0768c…` and not the tip of
the local series.

One reading trap, because it looks like a pin that drifted: the installed `zlint`
prints `v0.0.0` for `--version`. That is upstream's own default for a build made
from source, not a version marker this install could have got wrong, and the pin
in the manifest is what the revision rests on.

There is no system toolchain to install first and no host policy file to
fetch: `$QUALITY_TOOLS_PREFIX/bin` and `$QUALITY_TOOLS_PREFIX/lib` are the
whole runtime dependency. What lands in the prefix is source-equivalent to the
pinned revisions plus the checked-in patches, and nothing else.

### Running it

```sh
QUALITY_TOOLS_PREFIX=<scratch>/zig-interval/quality-tools
"$QUALITY_TOOLS_PREFIX/bin/zig-gate"
```

The installed gate resolves its required tools — `ziglint`, `zlint`, `zbc`,
`zwanzig` and `cross-test` — as `$QUALITY_TOOLS_PREFIX/bin/<name>` and nothing
else: no lookup outside the prefix and no `PATH` fallback.
`ZIG_GATE_PREFIX` names the prefix explicitly, and an installed
`$QUALITY_TOOLS_PREFIX/bin/zig-gate` infers it from its own location without
one. A missing analyser is exit 2, before any project check runs, naming every
absent file at once rather than substituting something else; an explicit
`ZIGLINT` / `ZLINT` / `ZBC` / `ZWANZIG` / `CROSS_TEST` override still wins,
because that is the operator naming a tool on purpose. `zig-cov` is **not**
installed and is not required: the opt-in `--cov` section reports it as skipped
and carries on, so an installed prefix is complete without it.
`zig-gate --help` lists the sections in the order they run and the
flags; `--no-cross` drops the one section that leaves the host.

### Scratch and cache roots

The installed harness carries its own scratch contract,
`$QUALITY_TOOLS_PREFIX/lib/cross-test/scratch-contract.sh`, and **no
machine-wide policy file is a prerequisite**: `zig-gate` and `cross-test`
enforce the rules themselves, so a cold install with an isolated `HOME` is
governed exactly like any other. Where such a policy file happens to be
readable it is still sourced first and its exports still win, and nothing in
any host's global configuration has to be modified to make this work.

`scripts/scratch.sh` — the resolver `scripts/build_mpfr.sh` uses — asks that
**same file**, at `tools/quality/harness/lib/cross-test/scratch-contract.sh`,
rather than carrying its own copy of the volume list. There is one
implementation of the rule and three callers of it: `zig-gate`, `cross-test`,
and this repository's own scripts.

The contract has two modes, chosen by the host and not by the caller. On a
**managed** host it accepts only the volumes that host's own policy sanctions
for scratch: a real mountpoint with that policy's own free-space floor,
symlinks resolved, **NFS refused outright**, and the small system temp volumes
(`/tmp`, `/var/tmp`, `/dev/shm`) refused for anything the harness writes.
**The NFS refusal is the load-bearing part of the rule, and the reason is
`renameat2()`:** an NFS mount rejects it, so a Zig cache placed there dies
inside `zig build` with an error naming the syscall rather than the volume. A
network-backed volume that is sanctioned for scratch elsewhere is therefore
refused here rather than accepted and left to fail later.

On **every other** host — a CI runner, a laptop — there is no cluster volume
list to honour, so the test is explicit ownership: an absolute path that is a
real, non-symlink directory the caller owns and can write, with at least 1 GiB
free and not on NFS. `/tmp` is ordinary in that mode, because on a runner it is
the only sane scratch. Name the roots:

| Variable | What it is |
| --- | --- |
| `GATE_SCRATCH` | scratch root for this run |
| `GATE_CACHE_DIR` | Zig local cache |
| `GATE_GLOBAL_CACHE_DIR` | Zig global cache |
| `GATE_CROSS_OUTPUT` | the `cross-test --output` directory |

A root named explicitly on a refused volume stops the run; an ambient `TMPDIR`
on one is corrected with a notice instead. An inherited temporary directory, an
inherited cache variable and an explicit flag are all validated the same way,
and nothing is created until a candidate has passed. Existing CI may use
runner-local temporary storage. The installer's own `--prefix` and
`--work-root` are checked by the same helper, so the rule is one implementation
rather than two, and neither is ever defaulted.

### What the gate enforces

The gate runs formatting, build, tests, AST checks, both linters, `zbc`,
`zwanzig` and the cross-target profile. Missing required tools fail the gate.
Its focused target command remains `zig 0.16.0 build test`.

`ziglint`, `zlint` and `zwanzig` findings fail acceptance without rule
suppression. `zbc` splits by severity: an `error` finding fails, a warning is
advisory, and `ZBC_STRICT=1` is the one knob that makes warnings fail too.
There is no whitelist of permitted findings and no file/line carve-out.

What is expected on **this** tree is three reviewed zbc warnings — the
float-to-integer conversions without a clamp — each of which requires the range
proofs documented at `criticalRange` and the soundness oracle's `expRef`. Those
three stay advisory — `intfromfloat_without_clamp` is the **one** rule that
remains a `.warning` by accepted, reviewed policy rather than by upstream
default, and every other rule in the pinned source runs at upstream's severity.
**Do not read that as "a clean run is three warnings and
nothing else":** an `error` from *any* zbc rule fails acceptance, and that
includes the six rules the pinned source now carries at upstream severity —
`memset_undef_after_len_truncation`, `f32_narrowing_int_to_float`,
`index_minus_one_without_zero_guard`, `index_type_narrowing_wraparound`,
`intcast_of_negated_signed` and `midpoint_addition_overflow` — which an
unreviewed capture had downgraded to warnings and which were restored on
purpose. A numerical library of this shape can legitimately trip
`index_type_narrowing_wraparound` or `intcast_of_negated_signed`; when it does,
the fix belongs in `src/` and not in a severity edit. The other limit worth
naming: with `ZBC_STRICT` unset a *fourth warning* would print without failing,
so read the per-rule histograms — and in neither case is changing interval
arithmetic to satisfy a caller-insensitive analysis the remedy.

### How `.vf` runs it

`.vf/gates.yml` does not run a bare `zig-gate`. It installs the prefix this
page describes and then runs the gate out of it, with `ZIG_GATE_PREFIX` bound to
the same prefix, so a gate run cannot inherit somebody else's tools and a missing
analyser exits 2 naming the file instead of quietly skipping a section. Its two
load-bearing keys read:

```yaml
suite-install: bash scripts/install-quality-tools.sh --prefix "$QUALITY_TOOLS_PREFIX" --work-root "$QUALITY_TOOLS_WORK_ROOT" --zig "$ZIG"
suite-cmd: ZIG_GATE_PREFIX="$QUALITY_TOOLS_PREFIX" "$QUALITY_TOOLS_PREFIX/bin/zig-gate"
suite-timeout: 3600
enforce: true
```

Both keys guard themselves: `suite-install` exits 2 with a message unless all
three variables are set, and `suite-cmd` exits 2 rather than run a gate that is
not installed. Neither falls back to a default path or to `$HOME`, so "which
tools ran" is never answered silently.

`.vf/gates.yml` names **no** scratch or cache roots of its own. `GATE_SCRATCH`,
`GATE_CACHE_DIR`, `GATE_GLOBAL_CACHE_DIR` and `GATE_CROSS_OUTPUT` are whatever
the operator exports: on a managed cluster host the scratch contract picks a
sanctioned local root itself, and anywhere else they must be named explicitly.

Three variables carry the rest:

| Variable | What it is |
| --- | --- |
| `QUALITY_TOOLS_PREFIX` | prefix the installer writes and the gate is run from |
| `QUALITY_TOOLS_WORK_ROOT` | the installer's fetch/patch/build/cache root |
| `ZIG` | absolute path to a real Zig 0.16.0 — a version shim on `PATH` is not it |

All three must be absolute paths, and the prefix and work root must also be
local, writable and owned by the caller, for the reasons the scratch section
gives: on a managed host that means one of the volumes its own policy sanctions
for scratch, and in every other mode it means any owned, writable, local
path, the system temp volumes included.
`suite-timeout` is 3600 s because the cross section builds and runs the whole
test step for the four required Linux targets, and `enforce: true` turns a
non-zero exit into a red gate rather than a report.

For a focused native test run, without the gate and without its analysers:

```sh
zig build test
```

### Cross-target verification

`cross-test.profile.sh` is the runtime coverage contract, and it is worth reading
before quoting runtime results. Five targets:
`x86_64-linux` natively, `aarch64-linux`, `riscv64-linux` and `s390x-linux` under
QEMU user-mode, and `x86_64-windows` **build only**. The profile raises the
execution budget to 900 seconds; two targets run at a time with one job per
build.

**What the profile also declares is what must actually RUN, and it is declared
at run time rather than asserted here.** One line in
`cross-test.profile.sh`,
`CROSS_REQUIRED_RUN_TARGETS='x86_64-linux aarch64-linux riscv64-linux s390x-linux'`,
names the four targets for which "it compiled" is not enough. The installed
`zig-gate` reads that declaration without sourcing the file, validates every
token against cross-test's own target pattern, binds its own run id, and then
reads only that run's `summary.json` — requiring `build=pass`, `run=pass`,
`status=pass` and a test count above zero for each of the four. A `build_only`
row, a missing row, a zero-test run or an unfinished run fails the section.
`x86_64-windows` is deliberately not in the list: with no wine it is compile
coverage, and demanding a runtime pass there would be demanding the impossible.
A profile that declares nothing keeps the previous, looser reporting.

```sh
ZIG=<scratch>/zigbin/zig \
  "$QUALITY_TOOLS_PREFIX/bin/cross-test" --output <scratch>/cross-out
```

`cross-test` manages its own cache and rejects `--cache-dir`, `--prefix`,
`-Dtarget`, `-j` and `--test-timeout`; `--output` is how you move its run off a
network mount.

`--output` is not optional on an NFS checkout: it is what moves the prefix, the
per-target logs and `cross-test-summary.json` off the network mount. Read
`<output>/cross-test-summary.json` and `<output>/runs/RUN_ID/build-TARGET.log`.

`x86_64-windows` has no runner, so `cross-test` records it as
`build_only` / `runtime_unavailable` and never counts it as a pass. A clean run
therefore reports `status=partial`, not `pass`, with `fail=0` and five target
rows, and still exits 0. "Builds" is the whole of that row's claim: it is
compile coverage of the Windows ABI and `std` paths, and it is never evidence
that the tests pass there. `--require-runners` would turn that row into a
failure and is not usable against this profile, so judge the run by `fail=0`
plus five target rows.

Compilation is not execution evidence anywhere in that run: build-only targets
remain untested at runtime, `no_test_results` requires investigation of the
runner log, and an incomplete runtime check is not a passing soundness check.

The child-process trap probes use the QEMU runner supplied by `cross-test`.
This does not require a kernel binfmt handler for the child executable.
Both probes retain their well-formed controls, so a failed launch cannot
count as a successful trap check.

The `test` step also depends on `consumer`, which builds the standalone package
under `fixture/` against this one as a real dependency. That validates the
public module is registered and reachable through the dependency module graph,
not merely importable inside this repository. The fixture asserts the
enclosure property directly: it checks that results are strictly wider than the
machine's own round-to-nearest answer while still containing the exact real
value, which is the only claim the rest of the library rests on.

#### Compilation across all 53 targets

The separate [`cross-compile.profile.sh`](cross-compile.profile.sh) selects the
pinned harness's entire Zig 0.16.0 support table and marks every runner `skip`.
It validates the selected compiler version and does not copy or narrow the
published target list. The default sweep ignores an inherited `TARGETS` subset;
an explicit `--targets` option still permits a diagnostic subset.

```sh
ZIG=<scratch>/zigbin/zig \
  "$QUALITY_TOOLS_PREFIX/bin/cross-test" \
  --profile ./cross-compile.profile.sh \
  --jobs 4 --build-jobs 1 --build-timeout 900 \
  --output <scratch>/compile-out
```

Each target runs `zig build test-compile`: the same **11 test binaries** that
contain the 348-test suite, the Debug NaN probe and the installed library.
The test dependencies force analysis and code generation of the exercised
public operations; a library archive alone would not establish that because
Zig analyzes declarations lazily. No tests, benchmarks or host consumer execute.
Benchmark executables and foreign consumer fixtures are not part of this sweep.

Because every runner is `skip`, a clean sweep reports no pass and no fail, with
every target counted in the `build_only` column:

```text
status=build_only pass=0 fail=0 build_only=53 partial=0
```

The sweep covers 32-bit and 64-bit targets, both byte orders, Linux, FreeBSD,
NetBSD, OpenBSD, Windows, macOS, Mac Catalyst and WASI. It is compilation
coverage, not 53 runtime passes or a target-by-optimize-mode matrix.
The normal gate retains its four required Linux runtime passes and Windows
compile-only row.

## License

MIT. See [LICENSE](LICENSE).
