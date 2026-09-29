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

**Every operation in this library returns an interval that is guaranteed to
contain the true mathematical answer.** Not "the answer rounded to the nearest
float" — a guaranteed enclosure of it.

Write `X` for a set of reals and `X op Y` for the exact mathematical result of
an operation on sets. For every real `v` belonging to `X op Y`:

```text
result.lo <= v <= result.hi
```

holds exactly, not approximately. A result is a fact about the reals, not a
guess about a machine. The same guarantee holds for the n-dimensional boxes and
for the linear-inequality solver, which propagates intervals for the same
reason.

### How the guarantee is obtained

Zig 0.16 has no directed rounding mode. `@round` is round-to-nearest, and
`@floor`, `@ceil` and `@trunc` snap to a representable value rather than to the
neighbour in the direction of rounding — none of them can produce "the smallest
double at or above `x`". Without directed rounding, an operation computed in
ordinary floating point can land one ULP on the wrong side of the true answer.

So each operation widens instead. It computes its endpoints with ordinary IEEE
round-to-nearest arithmetic and then moves each endpoint outward by exactly
one ULP: `prevDown` on a computed lower bound, `nextUp` on a computed upper
bound. Round-to-nearest errs by at most half a ULP, so a full ULP of outward
slack strictly exceeds the worst-case error and the widened interval cannot
exclude the true value.

`sin` and `cos` widen twice, because their range reduction uses a certified
interval for π, so the reduced argument carries its own error as well as the
one from `sin` or `cos` itself.

### The cost

At most one extra ULP of width per endpoint, per operation. The results are
therefore **very slightly wider than mathematically necessary**. That is the
price of soundness and it is deliberate: a result one ULP too wide is safe and
costs a little accuracy, while a result one ULP too narrow is silently wrong and
nothing downstream can detect it. If you have a choice between a result that is
marginally too wide and a result that is marginally too narrow, take the wide
one.

Because enclosures compose soundly — each operation accounts for its inputs'
error instead of trusting them — accumulated width grows roughly linearly with
the number of operations composed, not exponentially.

`nextUp` and `prevDown` are exported, so you can apply the same widening to your
own arithmetic when a value of yours feeds an `Interval`:

```zig
const interval = @import("interval");

// Your own arithmetic, widened exactly the way the library widens its own.
const iv = interval.Interval.init(
    interval.prevDown(my_lower_bound),
    interval.nextUp(my_upper_bound),
);
```

## Usage

The package exports a single public module named `interval`. Everything —
`Interval`, the vector forms, the elementary functions, the solver namespace —
is reachable from it:

```zig
const std = @import("std");
const interval = @import("interval");
const Interval = interval.Interval;

pub fn main() void {
    const a = Interval.init(1.0, 3.0);
    const b = Interval.init(2.0, 5.0);

    const shared = a.intersect(b).?;          // [2, 3]
    const span = a.hull(b);                   // [1, 5]
    const total = a.add(b);                   // an enclosure of [3, 8]

    // Elementary functions are free functions, and may be null.
    const rooted = interval.sqrt(Interval.init(4.0, 9.0)).?; // brackets [2, 3]

    std.debug.print("{d} {d} {d} {d}\n", .{
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
const dep = b.dependency("zig_interval", .{ .target = target, .optimize = optimize });
const exe = b.addExecutable(.{
    .name = "app",
    .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig") }),
});
exe.root_module.addImport("interval", dep.module("interval"));
b.installArtifact(exe);
```

The dependency key `zig_interval` is the package name; the module name
`interval` is what `@import` resolves against. It is the only public module the
package registers, and it re-exports every type, so one entry point reaches the
whole library.

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
whenever the result set can be empty.

### Algebraic operations — methods on `Interval`

| Method | Semantics |
| --- | --- |
| `init(lo: f64, hi: f64) Interval` | Construct an interval; requires `lo <= hi`. |
| `add(self: Interval, other: Interval) Interval` | Endpointwise sum. |
| `sub(self: Interval, other: Interval) Interval` | `self - other`, computed as `self + (-other)`, so `lo` subtracts the higher operand. |
| `neg(self: Interval) Interval` | `[-hi, -lo]`. **Exact**: IEEE negation is exact and only the endpoints swap, so this is the one algebraic operation that pays no ULP. |
| `mul(self: Interval, other: Interval) Interval` | Product of the four endpoint products, minimum and maximum. |
| `div(self: Interval, other: Interval) Interval` | `self * other.recip()`. **`[-inf, inf]` when `other` contains zero.** |
| `recip(self: Interval) Interval` | `1 / self`. **`[-inf, inf]` when `self` contains zero.** |
| `abs(self: Interval) Interval` | `[0, max(abs lo, abs hi)]` when the interval straddles zero, otherwise the interval itself. |
| `sqr(self: Interval) Interval` | Square; nonnegative, and starting at `0` when the interval straddles zero. |
| `contains(self: Interval, x: f64) bool` | Membership test, endpoints inclusive. |
| `hull(self: Interval, other: Interval) Interval` | Smallest interval covering both. |
| `hullOf(items: []const Interval) ?Interval` | Fold of `hull` over `items`; `null` for an empty slice. |
| `intersect(self: Interval, other: Interval) ?Interval` | Shared region; `null` when disjoint. |
| `intersectionOf(items: []const Interval) ?Interval` | Fold of `intersect` over `items`; `null` for an empty slice or a disjoint fold. |
| `width(self: Interval) f64` | `hi - lo`. |
| `overlaps(self: Interval, other: Interval) bool` | True when the two share at least one point. |
| `subsetOf(self: Interval, other: Interval) bool` | True when `self` is contained in `other`. |
| `midpoint(self: Interval) f64` | `(lo + hi) / 2`. |
| `clamp(self: Interval, x: f64) f64` | Clamp `x` into `[lo, hi]`. |
| `translate(self: Interval, delta: f64) Interval` | Shift both ends by `delta`. |
| `scale(self: Interval, factor: f64) Interval` | Scale the width about the midpoint by `\|factor\|`. |
| `expand(self: Interval, margin: f64) Interval` | Widen both ends by `margin`, or shrink both when it is negative; requires `margin >= -(hi - lo) / 2`, a more negative margin traps in Debug and ReleaseSafe. |
| `distanceTo(self: Interval, x: f64) f64` | `0` inside the interval, else the distance to the nearest endpoint. |

`scale` uses `|factor|` for the width, so a negative factor mirrors the width
without inverting the endpoints and the `lo <= hi` invariant still holds.

The set and geometry operations do no arithmetic, so their endpoints are exact
and the results need no widening. The algebraic operations pay one ULP per
endpoint, with two exceptions worth knowing: `neg` is exact, and `abs` and
`sqr` of an interval straddling zero return a lower bound of exactly `0.0`,
which is already exact.

### Elementary functions — free functions

All are reachable as `interval.<name>` and again as `interval.ext.<name>`.

| Function | Semantics |
| --- | --- |
| `sqrt(x: Interval) ?Interval` | `[√lo, √hi]`. **`null` when `hi < 0`.** |
| `cbrt(x: Interval) Interval` | `[∛lo, ∛hi]`. Monotone and real on all of ℝ, so it never fails. |
| `pow(x: Interval, n: i32) Interval` | `x^n` for a **plain integer** exponent, by squaring. Never `null`; `pow(x, 0)` is exactly `[1, 1]`. **`[-inf, inf]` when `n < 0` and `x` contains zero.** |
| `powf(x: Interval, y: Interval) ?Interval` | `x^y` with an **interval** exponent, which needs real analysis rather than repeated squaring. **`null` when `x.lo < 0`**: a negative base raised to a general exponent has no real value. **`[-inf, inf]` when the base contains zero and the exponent reaches below `-1`.** |
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
| `asin(x: Interval) ?Interval` | Increasing on `[-1, 1]`. **`null` outside `[-1, 1]`.** |
| `acos(x: Interval) ?Interval` | Decreasing, so the endpoints swap. **`null` outside `[-1, 1]`.** |
| `atan(x: Interval) Interval` | Increasing into `(-π/2, π/2)`, real everywhere. |
| `atan2(y: Interval, x: Interval) Interval` | Quadrant-aware arctangent of the point `(x, y)`. Unlike `atan`, it knows the signs of both coordinates and so covers the whole plane. Real everywhere, so it never returns `null`. |
| `sinh(x: Interval) Interval` | Increasing, real everywhere. |
| `cosh(x: Interval) Interval` | Even, so the result is `[min, max]` of the two endpoint values. |
| `tanh(x: Interval) Interval` | Increasing into `(-1, 1)`, real everywhere. |
| `asinh(x: Interval) Interval` | Odd, increasing, real everywhere. |
| `acosh(x: Interval) ?Interval` | **Domain is `[1, ∞)`, so `null` when `hi < 1`.** |
| `atanh(x: Interval) ?Interval` | **`null` on or outside `[-1, 1]`**: at ±1 the limit is infinite, which is not a real value, and beyond ±1 there is no real result at all. |
| `floor(x: Interval) Interval` | Monotone, so it is evaluated at both ends, combined with min/max, and widened. An **enclosure** of the integer values in the image, not a value snapped onto integers. |
| `ceil(x: Interval) Interval` | Same construction with `ceil`. |
| `trunc(x: Interval) Interval` | Same construction, toward zero. |
| `round(x: Interval) Interval` | Same construction with `@round`'s rule, which breaks ties away from zero: `round([-0.5, 0.5])` brackets `[-1, 1]`. |

#### Range reduction, and why `sin` and `cos` are special

`sin` and `cos` are computed by locating the **critical points** of the function
that fall inside the argument interval, and evaluating there — not by reducing
the argument modulo `2π`. Reduction loses precision: it subtracts large
quantities to obtain a small remainder, and the error in that subtraction
grows with the size of the argument. Here the reduction is done against a
certified interval for π, so the error is bounded rather than merely small, and
it is accounted for by the usual one-ULP widening on top.

The payoff is that when an interval spans a full period the answer is exactly
`[-1, 1]`, with no accumulated reduction error at all.

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
| `eql(self: Interval, other: Interval) bool` | The two intervals are the same set. |
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

**Empty → `null`.** `sqrt` of an interval entirely below zero, `log` of an
interval with `hi <= 0`, `asin`/`acos` outside `[-1, 1]`, `acosh` with `hi < 1`,
and `atanh` on or outside `[-1, 1]`. Also `intersect` of disjoint intervals and
the empty folds `hullOf` / `intersectionOf` of an empty slice. The question
"what is `√x` for `x ∈ [-4, -1]`?" has no answer, and `null` says so.

**Unbounded → an infinite interval.** `div` and `recip` when the divisor
contains zero (including a divisor that merely *touches* zero, such as
`[0, 1]`); `tan` across a pole; and `pow` with a negative integer exponent, or
`powf` whose exponent interval reaches below `-1`, applied to a base that
contains zero. The question "what is `1 / x` for `x ∈ [-1, 1]`?" has a
perfectly good answer — all of ℝ — so the result is `[-inf, inf]`, not `null`.

```zig
// Unbounded: a real answer, just not a finite one.
const q = Interval.init(1.0, 2.0).div(Interval.init(-1.0, 1.0)); // [-inf, inf]

// Empty: no real answer at all.
const r = interval.sqrt(Interval.init(-4.0, -1.0));               // null
```

`[-inf, inf]` and `null` are not interchangeable, and neither is a third thing
that happens to be spelled like them. There is no separate empty-interval
representation, because `lo <= hi` always holds: an empty result is `null`, and
a degenerate result is the single point `[x, x]`.

### Invariant

Every `Interval` satisfies `lo <= hi`. That holds for every value the library
returns, not only for ranges handed to `init`. `expand` builds its result
through `init`, so a margin that would invert the interval traps instead of
producing one; `hull` and `hullOf` take `lo` from a minimum and `hi` from a
maximum; `intersect` and `intersectionOf` guard their result with an explicit
`lo > hi` check; `translate` shifts both ends by the same delta; and `scale`
grows the width about the midpoint with `|factor|`. No public function can
return an inverted interval in a checked build.

`init` checks the invariant with `std.debug.assert`, which traps in Debug and
ReleaseSafe builds. The check is elided in ReleaseFast, so in fast builds the
caller is responsible for passing a valid range.

Widening preserves the invariant: `prevDown` only ever decreases a lower bound
and `nextUp` only ever increases an upper bound, so a valid input interval
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
| Bounds checks | None | None |
| Best for | Small fixed dimensions in hot code | Data-driven dimensions |

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
| `fromArray(comps: [n]Interval) Vec(n)` | Build from a literal. | `fromArray(gpa, comps: []const Interval) !DynVec` |
| `dim(self) usize` | `n`. | The runtime length. |
| `get(self, i: usize) Interval` | Component `i`. | Component `i`. |
| `set(self: *Self, i: usize, v: Interval) void` | Overwrite component `i`, through a pointer. | Overwrite component `i`, through a pointer. |
| `slice(self) []const Interval` | View of the components. | View of the components. |
| `deinit(self: *DynVec) void` | — | Frees the storage. |
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

Two shape differences from `DynVec`:

- **Value-returning operations allocate and return `!DynVec`.** They build a
  new value from `self.gpa`; they do not mutate. They fail with
  `error.DimensionMismatch` when the dimensions differ and `error.OutOfMemory`
  when allocation fails.
- **Unary operations mutate in place and return `void`.** `dyn.neg()` changes
  `dyn` and hands back nothing, because there is nothing to hand back. For the
  binaries, `iadd`, `isub`, `imul` and `idiv` mutate in place and return
  `!void`.

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

- **`isEmpty` is always false.** It exists so that vector code can be written
  against the same vocabulary as the scalar API, but there is no empty box: as
  with `Interval`, emptiness is a `null` from `intersect` or a dimension
  mismatch from a binary operation, never a value that exists and is empty.

### `mapResult`

```zig
pub fn mapResult(v: anytype, f: *const fn (Interval) ?Interval) !?@TypeOf(v)
```

Applies an elementary function to every component. The argument is a plain
function pointer, so it must be a top-level function or a comptime-known
declaration — closures are not accepted. The result is `null` if **any**
component maps to `null`, since a single empty coordinate makes the whole
image empty; the error is allocation for `DynVec`, which allocates from
`v.gpa`. `Vec(n)` needs no allocator and cannot fail on allocation.

```zig
const roots = try interval.mapResult(box, interval.sqrt);
```

This is the reason the elementary functions are plain functions of an
`Interval` rather than methods: with that shape, applying one across a vector
is a single generic, rather than 28 hand-written per-function wrappers whose
only difference is which function pointer they pass along. Every function
listed in the table above works here, and so does any function of your own with
the same signature.

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
| `Lin` | One linear inequality: `struct { coeffs: []Interval, op: Cmp, rhs: Interval }` — `sum(coeffs[i] * x_i) op rhs`. |
| `System` | A mutable collection of `Lin` plus the variable count. |

`Lin` **borrows**: the slice returned by `at(i)` and the slices inside it point
into the system's own storage. They are invalidated by the next `add` or
`eliminate`, and freed by `deinit`. Hold a copy of the data, not of the `Lin`.

Every row is **normalised to `<=` on insertion**: `eq` splits into a `<=` and a
`>=`, and `ge`/`gt` are multiplied through by `-1` and stored as `<=` too. So
`at(i).op` is always `.le`, and an `eq` you add shows up as two rows.

Strict comparisons are additionally **relaxed** on the way in, because
strictness is not representable in a closed interval: `gt` becomes `ge` and
`lt` becomes `le`, each flipped through by `-1` on the way to the stored `-coeffs
<= -rhs`. Relaxing is the only sound direction — a system you believe is
strictly bounded has its bound widen, never tighten.

### Operations

| Method | Semantics |
| --- | --- |
| `init(gpa, var_count: usize) System` | An empty system over `var_count` variables. |
| `deinit(self: *System) void` | Free everything. |
| `varCount(self) usize` | The number of variables, fixed at `init`. |
| `count(self) usize` | The number of rows currently stored. |
| `add(self, coeffs: []const Interval, op: Cmp, rhs: Interval) !void` | Insert a constraint, copying `coeffs`. `coeffs.len` must equal `varCount()`, else `error.BadVariableCount`. An `eq` inserts two rows. |
| `at(self, i: usize) Lin` | Row `i`, borrowed. |
| `isUnsat(self) bool` | True when the system provably has no solution. |
| `eliminate(self, k: usize) !void` | Eliminate variable `k` exactly. `error.BadVariable` for an out-of-range index, `error.VariableEliminated` for one already gone. |
| `eliminateAll(self, count_out: *bool) !void` | Eliminate every variable in turn. Writes `false` into `*count_out` and returns early if it proves the system unsatisfiable. |
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
var satisfiable = true;
try sys.eliminateAll(&satisfiable);
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

pub fn main() !void {
    var sys = lp.System.init(std.heap.page_allocator, 2);
    defer sys.deinit();

    // x + y <= 10
    try sys.add(&.{ interval.Interval.init(1, 1) }, .le, interval.Interval.init(10, 10));
    // x - y <= 2
    try sys.add(&.{ interval.Interval.init(1, 1), interval.Interval.init(1, -1) }, .le, interval.Interval.init(2, 2));
    // -x + y <= 4
    try sys.add(&.{ interval.Interval.init(-1, -1), interval.Interval.init(1, 1) }, .le, interval.Interval.init(4, 4));
    // -x - y <= 6
    try sys.add(&.{ interval.Interval.init(-1, -1), interval.Interval.init(-1, -1) }, .le, interval.Interval.init(6, 6));

    // Read the derived box while the variables are still live. box() does not
    // mutate the system, so the same system can still be reduced afterwards.
    if (try sys.box()) |derived| {
        defer std.heap.page_allocator.free(derived);
        std.debug.print("x in [{d}, {d}], y in [{d}, {d}]\n", .{
            derived[0].lo, derived[0].hi, derived[1].lo, derived[1].hi,
        });
        // x in [-5, 6], y in [-4, 7]
    } else {
        std.debug.print("no finite box\n", .{});
    }

    // To keep the reduced system rather than just read a bound, eliminate.
    if (!try sys.eliminateInOrderOfChoice()) {
        std.debug.print("unsatisfiable\n", .{});
        return;
    }
}
```

Eliminating `y` pairs its two upper bounds (`y <= 10 - x`, `y <= 4 + x`) with
its two lower bounds (`y >= x - 2`, `y >= -6 - x`), giving four rows in `x`
alone. Two of them are trivially true constants; the other two are
`2x <= 12` and `2x >= -10`, so `x ∈ [-5, 6]`. The same reasoning in the other
direction gives `y ∈ [-4, 7]`. The true feasible region is a parallelogram, and
the box is the tightest one containing it.

An unsatisfiable system, detected before any elimination:

```zig
var sys = lp.System.init(std.heap.page_allocator, 1);
defer sys.deinit();

// x <= 1
try sys.add(&.{Interval.init(1, 1)}, .le, Interval.init(1, 1));
// x >= 2, stored normalised as -x <= -2
try sys.add(&.{Interval.init(1, 1)}, .ge, Interval.init(2, 2));

sys.isUnsat(); // true
```

## Build steps

| Step | Effect |
| --- | --- |
| `install` (default) | Installs the library artifact. |
| `test` | Runs the interval test suite and the external consumer fixture. |
| `consumer` | Builds and runs the external consumer fixture on its own. |
| `docs` | Emits API documentation. |

## Development

Run the test suite with:

```
zig build test
```

The `test` step also depends on `consumer`, which builds the standalone package
under `fixture/` against this one as a real dependency. That validates the
public module is registered and reachable through the dependency module graph,
not merely importable inside this repository. The fixture asserts the
enclosure property directly: it checks that results are strictly wider than the
machine's own round-to-nearest answer while still containing the exact real
value, which is the only claim the rest of the library rests on.

## License

MIT. See [LICENSE](LICENSE).
