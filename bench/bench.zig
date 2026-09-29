//! Scalar benchmarks: every algebraic operation on `Interval`, the six
//! certain comparisons, and the elementary functions over it.
//!
//! Two decisions here decide whether the numbers mean anything.
//!
//! Operands come from tables built at COMPTIME, not from a generator run
//! inside the timed loop. A generator would be inside the measurement,
//! and a splitmix64 is a couple of nanoseconds of integer work against an
//! operation that is a fraction of a nanosecond — the figure would be
//! describing the generator. A table of 256 cases is 8 KB of intervals,
//! stays in L1, and a body reads two of them by the iteration index:
//! varied, but not paid for out of the budget being measured.
//!
//! The spread is spread. An interval benchmark over `Interval.init(1,1)`
//! measures the degenerate case, and the degenerate case is the cheapest
//! path through the code — `add` on a point is two f64 adds, while
//! `mul` on a straddling operand takes its sign-crossing corners. So the
//! operand families below cover ordinary magnitudes, both signs, operands
//! spanning zero, and operands at 2^280 and above where a product leaves
//! the range of the format entirely. Each elementary function has the
//! tables its own domain calls for, because a table of positive intervals
//! is meaningless to a function that only accepts [-1, 1].
//!
//! `build-exe -OReleaseFast`, always. A Debug measurement of a library
//! whose every operation is wrapped in assertions is mostly a measurement
//! of the assertions, and the register spills around them.

const std = @import("std");
const timing = @import("timing.zig");
const interval = @import("interval");

const Interval = interval.Interval;

// =========================================================================
// Operand spread
// =========================================================================

/// Distinct cases in a table. 256 is the compromise: 8 KB of intervals
/// stays in L1 so that reading an operand does not become the cache miss
/// the operation is then measured against, and 256 is far too many to be
/// a single cached case repeated.
const cases = 256;
const case_mask = cases - 1;

/// splitmix64's finaliser. A hash rather than a PRNG, so a table is a
/// fixed function of its index: the same 256 cases come out of every
/// build on every machine, which is what makes a number measured today
/// comparable with the same number measured after a change to the
/// library.
fn hash(v: u64) u64 {
    var z = v +% 0x9e37_79b9_7f4a_7c15;
    z = (z ^ (z >> 30)) *% 0xbf58_476d_1ce4_e5b9;
    z = (z ^ (z >> 27)) *% 0x94d0_49bb_1331_11eb;
    return z ^ (z >> 31);
}

/// A POSITIVE float of magnitude 2^k for a k the hash draws from
/// lo_k ..= hi_k, with a random mantissa so two cases are rarely the
/// same number. Assembled from its bit pattern rather than from a float
/// routine, which is exact, needs no libm, and works at comptime — the
/// table is built by the compiler, not by the measured program.
fn mag(seed: u64, lo_k: i32, hi_k: i32) f64 {
    const span: u64 = @intCast(hi_k - lo_k + 1);
    const k: i64 = @as(i64, lo_k) + @as(i64, @intCast((hash(seed) >> 32) % span));
    const mantissa: u64 = hash(seed +% 0x51ed_270b) & 0x000f_ffff_ffff_ffff;
    const bits: u64 = (@as(u64, k + 1023) << 52) | mantissa;
    return @bitCast(bits);
}

/// `mag` with a sign drawn from the same hash, for the arguments a
/// function defined over all of the reals is handed.
fn signed(seed: u64, lo_k: i32, hi_k: i32) f64 {
    return if (hash(seed) & 1 != 0) -mag(seed, lo_k, hi_k) else mag(seed, lo_k, hi_k);
}

/// An interval from two endpoints in whatever order they come out, so a
/// table of independently drawn ends is ordered by construction.
fn ordered(a: f64, b: f64) Interval {
    return Interval.init(@min(a, b), @max(a, b));
}

/// An ordered positive band, the two ends drawn independently, so the
/// spread holds intervals of every width and not only degenerate ones.
fn positiveBand(seed: u64, lo_k: i32, hi_k: i32) Interval {
    return ordered(mag(seed * 2 + 1, lo_k, hi_k), mag(seed * 2 + 2, lo_k, hi_k));
}

/// The same band mirrored into the negative reals.
fn negativeBand(seed: u64, lo_k: i32, hi_k: i32) Interval {
    const p = positiveBand(seed, lo_k, hi_k);
    return Interval.init(-p.hi, -p.lo);
}

/// An interval spanning zero. This is the case that separates the
/// branches: `abs` takes its other arm, `sqr` is not monotone across
/// here, and the four corner products of `mul` change sign.
fn straddling(seed: u64, lo_k: i32, hi_k: i32) Interval {
    return Interval.init(-mag(seed * 2 + 1, lo_k, hi_k), mag(seed * 2 + 2, lo_k, hi_k));
}

/// One operand pair, the unit the binary benchmarks measure.
const Pair = struct { a: Interval, b: Interval };

/// The operand spread: 256 pairs over eight families, 32 cases each.
///
/// The families are what stop any one of them dominating. Ordinary
/// positive magnitudes are the easy case and are a quarter of the table.
/// Negative bands and sign-crossing pairs are the ordinary arithmetic.
/// Operands spanning zero are where `abs` and `sqr` diverge and where a
/// divisor makes `div` answer [-inf, inf] without touching a corner.
/// Magnitudes from 2^280 up put a product past floatMax and a sum within
/// a few of it, which is a different path through the outward rounding
/// because there is no room left to step out into.
const pairs: [cases]Pair = blk: {
    var out: [cases]Pair = undefined;
    @setEvalBranchQuota(100_000);
    for (0..cases) |i| {
        const s: u64 = @intCast(i * 2 + 1);
        out[i] = switch (i & 7) {
            // Ordinary positive magnitudes.
            0 => .{
                .a = positiveBand(s, -10, 10),
                .b = positiveBand(s + 1, -10, 10),
            },
            // Both operands negative.
            1 => .{
                .a = negativeBand(s, -10, 10),
                .b = negativeBand(s + 1, -10, 10),
            },
            // The first operand spans zero.
            2 => .{
                .a = straddling(s, -10, 10),
                .b = positiveBand(s + 1, -10, 10),
            },
            // The second operand spans zero, so a division or a
            // reciprocal by it is answered as unbounded without
            // evaluating a corner at all.
            3 => .{
                .a = positiveBand(s, -10, 10),
                .b = straddling(s + 1, -10, 10),
            },
            // The two operands IDENTICAL, both negative. `eql` is a
            // conjunction of two endpoint tests and short-circuits on
            // the first, so without a family where the two agree every
            // comparison benchmark would measure half of the operation
            // and report a cost the function does not have.
            4 => same: {
                const a = negativeBand(s, -10, 10);
                break :same .{ .a = a, .b = a };
            },
            // Ordinary magnitudes at the top of the range: a sum is
            // within a few of floatMax and a product is past it.
            5 => .{
                .a = positiveBand(s, 280, 1020),
                .b = positiveBand(s + 1, 280, 1020),
            },
            // A sign crossing at the top of the range, where the corner
            // products are signed infinities.
            6 => .{
                .a = straddling(s, 280, 1020),
                .b = positiveBand(s + 1, 280, 1020),
            },
            // Both operands span zero: the widest sign handling there
            // is, and a divisor that is unbounded.
            else => .{
                .a = straddling(s, -10, 10),
                .b = straddling(s + 1, -10, 10),
            },
        };
    }
    break :blk out;
};

/// Scalars for the operations taking one: `translate`'s shift and
/// `scale`'s factor. Both signs, and three orders of magnitude short of
/// the operands as well as level with them — a shift far below the
/// smallest difference the interval can represent is a different case
/// from one that carries the whole interval with it.
const scalars: [cases]f64 = blk: {
    var out: [cases]f64 = undefined;
    @setEvalBranchQuota(100_000);
    for (0..cases) |i| {
        const s: u64 = @intCast(i);
        out[i] = switch (i & 3) {
            0 => mag(s, -10, 10),
            1 => -mag(s + 1, -10, 10),
            2 => mag(s + 2, -40, -20),
            else => signed(s + 3, 280, 1020),
        };
    }
    break :blk out;
};

/// Margins for `expand`, which widens on a positive margin and SHRINKS on
/// a negative one — a different pair of operations, so both are in the
/// spread. A margin more than half the width below zero would invert the
/// interval and trap, so the negative cases are taken as a fraction of
/// the width of the operand they are paired with.
const margins: [cases]f64 = blk: {
    var out: [cases]f64 = undefined;
    @setEvalBranchQuota(100_000);
    for (0..cases) |i| {
        const w = pairs[i].a.hi - pairs[i].a.lo;
        out[i] = switch (i & 3) {
            0 => w,
            1 => -w / 4.0,
            2 => mag(i, -10, 10),
            else => mag(i + 1, 280, 1020),
        };
    }
    break :blk out;
};

/// Arguments for the functions defined over every real. Spread over
/// magnitude, sign and width, and bounded above at 2^8: `exp`, `expm1`,
/// `sinh` and `cosh` all reach an infinity somewhere near 710, and a
/// table reaching past that point measures the overflow rather than the
/// function. 2^8 is the largest power of two whose mantissa cannot
/// carry a `mag` past 512, which is the last value below 710 that a
/// 52-bit mantissa cannot step over.
///
/// Intervals wider than a period are in the spread on purpose: that is
/// the branch where sine and cosine answer their whole range without
/// computing anything. So are the large phases, which are what make the
/// critical-point scan do real work instead of landing on k = 0 every
/// time — and `tan` and its pole row are meant to reach an infinity,
/// because an unbounded tangent is that function's actual answer.
const real_args: [cases]Interval = blk: {
    var out: [cases]Interval = undefined;
    @setEvalBranchQuota(100_000);
    for (0..cases) |i| {
        const s: u64 = @intCast(i);
        out[i] = switch (i & 7) {
            0 => ordered(signed(s, -8, 8), signed(s + 1, -8, 8)),
            1 => straddling(s, -8, 8),
            2 => ordered(signed(s, -1, 1), signed(s + 1, -1, 1)),
            3 => ordered(signed(s, -40, 8), signed(s + 1, -40, 8)),
            // Wider than a period, so the range branch fires.
            4 => Interval.init(-32.0, 32.0),
            // Very narrow about zero, where the whole interval sits
            // inside one binade and every endpoint rounds the same way.
            5 => Interval.init(-1e-8, 1e-8),
            // A large phase, so the critical-point scan has real work
            // to do rather than landing on k = 0 every time.
            6 => positiveBand(s, 6, 8),
            // A sign crossing several binades wide, which is a
            // different width class again.
            else => straddling(s, 2, 2),
        };
    }
    break :blk out;
};

/// A table of intervals strictly inside the positive reals, for the
/// logarithms, the square root and the base of `powf`.
fn makePositiveTable(lo_k: i32, hi_k: i32) [cases]Interval {
    var out: [cases]Interval = undefined;
    @setEvalBranchQuota(100_000);
    for (0..cases) |i| {
        const s: u64 = @intCast(i * 2 + 1);
        const a = mag(s, lo_k, hi_k);
        const b = mag(s + 1, lo_k, hi_k);
        out[i] = switch (i & 3) {
            0 => ordered(a, b),
            // The same band with the ends the other way round, so the
            // argument is sometimes the wide end on the left.
            1 => ordered(b, a),
            // A point, where the outward widening is the only thing
            // between the result and the primitive.
            2 => Interval.init(a, a),
            // A band reaching a couple of binades below its upper end.
            else => ordered(mag(s, lo_k - 2, hi_k), b),
        };
    }
    return out;
}

/// Arguments inside the positive reals, from 2^-300 to 2^300. The
/// square root of that table runs from 2^-150 to 2^150, so no row of it
/// is measuring a cached primitive on a familiar argument.
const positive_args: [cases]Interval = makePositiveTable(-300, 300);

/// Arguments from 1 upwards, which is what `acosh` needs: it refuses
/// anything whose upper end is below 1 and clamps the lower one, so a
/// table reaching below 1 would be measuring that repair instead of the
/// function.
const positive_acosh_args: [cases]Interval = makePositiveTable(0, 60);

/// A table wholly outside every domain the `?Interval` functions have,
/// all of it negative and below -2. One table serves all ten of them:
/// the square root of it has no real value, its logarithm has none, its
/// logarithm plus one has none, it is outside [-1, 1] for the inverse
/// circular and hyperbolic tangents, below 1 for the inverse hyperbolic
/// cosine, and a negative base for a real power. The cost of that early
/// return does not depend on the magnitude, so there is nothing to vary
/// in it but the sign.
const off_domain: [cases]Interval = blk: {
    var out: [cases]Interval = undefined;
    @setEvalBranchQuota(100_000);
    for (0..cases) |i| {
        const s: u64 = @intCast(i * 2 + 1);
        const a = -mag(s, 1, 60);
        const b = -mag(s + 1, 1, 60);
        out[i] = switch (i & 3) {
            0 => ordered(a, b),
            1 => ordered(b, a),
            2 => Interval.init(a, a),
            else => ordered(-mag(s, 20, 60), a),
        };
    }
    break :blk out;
};

/// A table strictly inside (-1, 1), the domain of `asin`, `acos` and
/// `atanh` at once. Both signs, both halves, points and bands.
const unit_args: [cases]Interval = blk: {
    var out: [cases]Interval = undefined;
    @setEvalBranchQuota(100_000);
    for (0..cases) |i| {
        const s: u64 = @intCast(i * 2 + 1);
        const a = mag(s, -60, -2);
        const b = mag(s + 1, -60, -2);
        out[i] = switch (i & 3) {
            0 => Interval.init(-a, b),
            1 => ordered(-a, a),
            2 => Interval.init(b, b),
            else => Interval.init(-b, a),
        };
    }
    break :blk out;
};

/// A table with one end at or below zero and the other above it. The
/// logarithms give this their own answer rather than a null: the
/// argument then runs arbitrarily close to zero, so the image runs
/// arbitrarily far down and no finite bound holds it. That branch
/// computes one primitive and returns [-inf, hi], which is a different
/// cost from either of the other two.
const straddling_args: [cases]Interval = blk: {
    var out: [cases]Interval = undefined;
    @setEvalBranchQuota(100_000);
    for (0..cases) |i| {
        out[i] = straddling(i, 1, 60);
    }
    break :blk out;
};

/// Bases for `powf`: strictly positive, so none of the exact cases at
/// zero or one short-circuit, and the identity `exp(y * log x)` is
/// actually evaluated. Near one is in the spread because that is the
/// case the `std.math.pow` error the function replaced was worst at.
const powf_bases: [cases]Interval = makePositiveTable(-20, 20);

/// Exponents for `powf`, varied so the cost is not measured on one of
/// them. A small integer, a large one, a fraction, a band, and a base so
/// close to one that the product `y * log x` is near zero.
const powf_exponents: [cases]Interval = blk: {
    var out: [cases]Interval = undefined;
    @setEvalBranchQuota(100_000);
    for (0..cases) |i| {
        out[i] = switch (i & 7) {
            0 => Interval.init(2.0, 2.0),
            1 => Interval.init(-2.0, -2.0),
            2 => Interval.init(0.5, 0.5),
            3 => Interval.init(-0.5, 0.5),
            4 => Interval.init(1.0, 3.0),
            5 => Interval.init(0.25, 4.0),
            6 => Interval.init(1.0000000001, 1.0000000001),
            else => Interval.init(1.0, 1.0),
        };
    }
    break :blk out;
};

/// Integer exponents for `pow`. That one is a squaring loop rather than
/// a single primitive, so its cost is set by how many bits the exponent
/// has, and the spread is over bit counts as much as over values.
const int_exponents: [cases]i32 = blk: {
    var out: [cases]i32 = undefined;
    @setEvalBranchQuota(100_000);
    for (0..cases) |i| {
        out[i] = switch (i & 7) {
            0 => 1,
            1 => 2,
            2 => 3,
            3 => 5,
            4 => 16,
            5 => 1023,
            6 => -3,
            else => 65536,
        };
    }
    break :blk out;
};

/// Arguments for `tan` placed across a pole. That is the one case where
/// the answer is unbounded rather than merely wide, and the case the
/// critical-point scan exists for: the answer comes from the scan finding
/// an integer in the range, not from evaluating anything.
const tan_pole_args: [cases]Interval = blk: {
    var out: [cases]Interval = undefined;
    @setEvalBranchQuota(100_000);
    for (0..cases) |i| {
        const s: u64 = @intCast(i);
        const k: f64 = @floatFromInt(@as(i32, @intCast(hash(s) & 7)) - 4);
        const centre = 1.5707963267948966 + k * 3.141592653589793;
        const half: f64 = @as(f64, @floatFromInt((hash(s +% 1) & 0xffff_ffff) + 1)) / 1e9;
        out[i] = Interval.init(centre - half, centre + half);
    }
    break :blk out;
};

// =========================================================================
// Folding a result into the sink
// =========================================================================

/// The one value a result is reduced to before it reaches the sink.
///
/// The width rather than an endpoint sum, because an endpoint sum is
/// indeterminate for every result with an infinite end — the unbounded
/// quotient, the tangent across a pole — and a NaN in the sink is still
/// a live sink, but it is an ugly one. The width is never negative, and
/// for a result whose endpoints are both finite it is finite, so the
/// checksum printed at the end of a run is worth reading.
fn fold(r: Interval) f64 {
    return r.hi - r.lo;
}

/// The same for a function that may decline. A null has no width, so the
/// branch is kept in the measurement by a constant on that side of it:
/// the whole point of measuring the out-of-domain path is that it is a
/// compare and a return, and this is what it costs.
fn foldMaybe(r: ?Interval) f64 {
    const v = r orelse return -1.0;
    return fold(v);
}

/// The comparison results, which are booleans, as the 0 and 1 the sink
/// can take. Both outcomes occur in the table, which is the reason the
/// identical-operand family is in it.
fn foldBool(b: bool) f64 {
    return if (b) 1.0 else 0.0;
}

// =========================================================================
// Group: algebraic operations
// =========================================================================

/// Iterations for the algebraic rows. The fastest of them, the
/// comparisons, are a couple of loads and a compare; a million of those
/// is still several milliseconds inside the timed region, which is far
/// above the resolution of the clock and far above the noise of a
/// preempted sample.
const algebra_iters = 1_000_000;

fn benchAdd(ctx: *timing.Ctx, i: usize) void {
    const p = pairs[i & case_mask];
    ctx.keep(fold(p.a.add(p.b)));
}

fn benchSub(ctx: *timing.Ctx, i: usize) void {
    const p = pairs[i & case_mask];
    ctx.keep(fold(p.a.sub(p.b)));
}

fn benchNeg(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(fold(pairs[i & case_mask].a.neg()));
}

fn benchMul(ctx: *timing.Ctx, i: usize) void {
    const p = pairs[i & case_mask];
    ctx.keep(fold(p.a.mul(p.b)));
}

fn benchDiv(ctx: *timing.Ctx, i: usize) void {
    const p = pairs[i & case_mask];
    ctx.keep(fold(p.a.div(p.b)));
}

fn benchRecip(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(fold(pairs[i & case_mask].a.recip()));
}

fn benchAbs(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(fold(pairs[i & case_mask].a.abs()));
}

fn benchSqr(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(fold(pairs[i & case_mask].a.sqr()));
}

fn benchTranslate(ctx: *timing.Ctx, i: usize) void {
    const j = i & case_mask;
    ctx.keep(fold(pairs[j].a.translate(scalars[j])));
}

fn benchScale(ctx: *timing.Ctx, i: usize) void {
    const j = i & case_mask;
    ctx.keep(fold(pairs[j].a.scale(scalars[j])));
}

fn benchExpand(ctx: *timing.Ctx, i: usize) void {
    const j = i & case_mask;
    ctx.keep(fold(pairs[j].a.expand(margins[j])));
}

fn benchEql(ctx: *timing.Ctx, i: usize) void {
    const p = pairs[i & case_mask];
    ctx.keep(foldBool(p.a.eql(p.b)));
}

fn benchNe(ctx: *timing.Ctx, i: usize) void {
    const p = pairs[i & case_mask];
    ctx.keep(foldBool(p.a.ne(p.b)));
}

fn benchLt(ctx: *timing.Ctx, i: usize) void {
    const p = pairs[i & case_mask];
    ctx.keep(foldBool(p.a.lt(p.b)));
}

fn benchLe(ctx: *timing.Ctx, i: usize) void {
    const p = pairs[i & case_mask];
    ctx.keep(foldBool(p.a.le(p.b)));
}

fn benchGt(ctx: *timing.Ctx, i: usize) void {
    const p = pairs[i & case_mask];
    ctx.keep(foldBool(p.a.gt(p.b)));
}

fn benchGe(ctx: *timing.Ctx, i: usize) void {
    const p = pairs[i & case_mask];
    ctx.keep(foldBool(p.a.ge(p.b)));
}

fn runAlgebra(runner: *timing.Runner) !void {
    try timing.measure(runner, "interval.add", algebra_iters, benchAdd);
    try timing.measure(runner, "interval.sub", algebra_iters, benchSub);
    try timing.measure(runner, "interval.neg", algebra_iters, benchNeg);
    try timing.measure(runner, "interval.mul", algebra_iters, benchMul);
    try timing.measure(runner, "interval.div", algebra_iters, benchDiv);
    try timing.measure(runner, "interval.recip", algebra_iters, benchRecip);
    try timing.measure(runner, "interval.abs", algebra_iters, benchAbs);
    try timing.measure(runner, "interval.sqr", algebra_iters, benchSqr);
    try timing.measure(runner, "interval.translate", algebra_iters, benchTranslate);
    try timing.measure(runner, "interval.scale", algebra_iters, benchScale);
    try timing.measure(runner, "interval.expand", algebra_iters, benchExpand);
    try timing.measure(runner, "interval.eql", algebra_iters, benchEql);
    try timing.measure(runner, "interval.ne", algebra_iters, benchNe);
    try timing.measure(runner, "interval.lt", algebra_iters, benchLt);
    try timing.measure(runner, "interval.le", algebra_iters, benchLe);
    try timing.measure(runner, "interval.gt", algebra_iters, benchGt);
    try timing.measure(runner, "interval.ge", algebra_iters, benchGe);
}

// =========================================================================
// Group: elementary functions
// =========================================================================

/// Iterations for the elementary rows. These are one to three libm
/// calls plus the outward widening, so they are an order of magnitude
/// slower than the comparisons above and a fifth of the iterations buys
/// the same resolution.
const ext_iters = 200_000;

/// `powf` gets its own, smaller, count: it evaluates two corners
/// through `log`, `mul` and `exp`, which makes it the most expensive
/// call in the surface by some distance and would otherwise dominate the
/// wall time of the whole group.
const powf_iters = 50_000;

fn benchSqrt(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(foldMaybe(interval.sqrt(real_args[i & case_mask])));
}

fn benchSqrtOut(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(foldMaybe(interval.sqrt(off_domain[i & case_mask])));
}

fn benchCbrt(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(fold(interval.cbrt(real_args[i & case_mask])));
}

fn benchPow(ctx: *timing.Ctx, i: usize) void {
    const j = i & case_mask;
    ctx.keep(fold(interval.pow(pairs[j].a, int_exponents[j])));
}

fn benchPowf(ctx: *timing.Ctx, i: usize) void {
    const j = i & case_mask;
    ctx.keep(foldMaybe(interval.powf(powf_bases[j], powf_exponents[j])));
}

fn benchPowfOut(ctx: *timing.Ctx, i: usize) void {
    const j = i & case_mask;
    ctx.keep(foldMaybe(interval.powf(off_domain[j], powf_exponents[j])));
}

fn benchExp(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(fold(interval.exp(real_args[i & case_mask])));
}

fn benchExp2(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(fold(interval.exp2(real_args[i & case_mask])));
}

fn benchExpm1(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(fold(interval.expm1(real_args[i & case_mask])));
}

fn benchLog(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(foldMaybe(interval.log(positive_args[i & case_mask])));
}

fn benchLogOut(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(foldMaybe(interval.log(off_domain[i & case_mask])));
}

fn benchLogStraddle(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(foldMaybe(interval.log(straddling_args[i & case_mask])));
}

fn benchLog2(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(foldMaybe(interval.log2(positive_args[i & case_mask])));
}

fn benchLog2Out(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(foldMaybe(interval.log2(off_domain[i & case_mask])));
}

fn benchLog2Straddle(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(foldMaybe(interval.log2(straddling_args[i & case_mask])));
}

fn benchLog10(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(foldMaybe(interval.log10(positive_args[i & case_mask])));
}

fn benchLog10Out(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(foldMaybe(interval.log10(off_domain[i & case_mask])));
}

fn benchLog10Straddle(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(foldMaybe(interval.log10(straddling_args[i & case_mask])));
}

fn benchLog1p(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(foldMaybe(interval.log1p(real_args[i & case_mask])));
}

fn benchLog1pOut(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(foldMaybe(interval.log1p(off_domain[i & case_mask])));
}

fn benchLog1pStraddle(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(foldMaybe(interval.log1p(straddling_args[i & case_mask])));
}

fn benchSin(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(fold(interval.sin(real_args[i & case_mask])));
}

fn benchCos(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(fold(interval.cos(real_args[i & case_mask])));
}

fn benchTan(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(fold(interval.tan(real_args[i & case_mask])));
}

fn benchTanPole(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(fold(interval.tan(tan_pole_args[i & case_mask])));
}

fn benchAsin(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(foldMaybe(interval.asin(unit_args[i & case_mask])));
}

fn benchAsinOut(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(foldMaybe(interval.asin(off_domain[i & case_mask])));
}

fn benchAcos(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(foldMaybe(interval.acos(unit_args[i & case_mask])));
}

fn benchAcosOut(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(foldMaybe(interval.acos(off_domain[i & case_mask])));
}

fn benchAtan(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(fold(interval.atan(real_args[i & case_mask])));
}

fn benchAtan2(ctx: *timing.Ctx, i: usize) void {
    const p = pairs[i & case_mask];
    ctx.keep(fold(interval.atan2(p.a, p.b)));
}

fn benchSinh(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(fold(interval.sinh(real_args[i & case_mask])));
}

fn benchCosh(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(fold(interval.cosh(real_args[i & case_mask])));
}

fn benchTanh(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(fold(interval.tanh(real_args[i & case_mask])));
}

fn benchAsinh(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(fold(interval.asinh(real_args[i & case_mask])));
}

fn benchAcosh(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(foldMaybe(interval.acosh(positive_acosh_args[i & case_mask])));
}

fn benchAcoshOut(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(foldMaybe(interval.acosh(off_domain[i & case_mask])));
}

fn benchAtanh(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(foldMaybe(interval.atanh(unit_args[i & case_mask])));
}

fn benchAtanhOut(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(foldMaybe(interval.atanh(off_domain[i & case_mask])));
}

fn benchFloor(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(fold(interval.floor(real_args[i & case_mask])));
}

fn benchCeil(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(fold(interval.ceil(real_args[i & case_mask])));
}

fn benchTrunc(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(fold(interval.trunc(real_args[i & case_mask])));
}

fn benchRound(ctx: *timing.Ctx, i: usize) void {
    ctx.keep(fold(interval.round(real_args[i & case_mask])));
}

fn runExt(runner: *timing.Runner) !void {
    // The arguments in the positive reals: the logarithms, the square
    // root, and the base of a real power. Their magnitudes run from
    // 2^-300 to 2^300, so the square root of the table spans 2^-150 to
    // 2^150 and none of it is the same argument twice.
    try timing.measure(runner, "ext.sqrt", ext_iters, benchSqrt);
    try timing.measure(runner, "ext.sqrt [out of domain]", ext_iters, benchSqrtOut);
    try timing.measure(runner, "ext.cbrt", ext_iters, benchCbrt);
    try timing.measure(runner, "ext.pow", ext_iters, benchPow);
    try timing.measure(runner, "ext.powf", powf_iters, benchPowf);
    try timing.measure(runner, "ext.powf [out of domain]", powf_iters, benchPowfOut);
    try timing.measure(runner, "ext.exp", ext_iters, benchExp);
    try timing.measure(runner, "ext.exp2", ext_iters, benchExp2);
    try timing.measure(runner, "ext.expm1", ext_iters, benchExpm1);
    try timing.measure(runner, "ext.log", ext_iters, benchLog);
    try timing.measure(runner, "ext.log [out of domain]", ext_iters, benchLogOut);
    try timing.measure(runner, "ext.log [straddling zero]", ext_iters, benchLogStraddle);
    try timing.measure(runner, "ext.log2", ext_iters, benchLog2);
    try timing.measure(runner, "ext.log2 [out of domain]", ext_iters, benchLog2Out);
    try timing.measure(runner, "ext.log2 [straddling zero]", ext_iters, benchLog2Straddle);
    try timing.measure(runner, "ext.log10", ext_iters, benchLog10);
    try timing.measure(runner, "ext.log10 [out of domain]", ext_iters, benchLog10Out);
    try timing.measure(runner, "ext.log10 [straddling zero]", ext_iters, benchLog10Straddle);
    try timing.measure(runner, "ext.log1p", ext_iters, benchLog1p);
    try timing.measure(runner, "ext.log1p [out of domain]", ext_iters, benchLog1pOut);
    try timing.measure(runner, "ext.log1p [straddling zero]", ext_iters, benchLog1pStraddle);
    try timing.measure(runner, "ext.sin", ext_iters, benchSin);
    try timing.measure(runner, "ext.cos", ext_iters, benchCos);
    try timing.measure(runner, "ext.tan", ext_iters, benchTan);
    try timing.measure(runner, "ext.tan [across a pole]", ext_iters, benchTanPole);
    try timing.measure(runner, "ext.asin", ext_iters, benchAsin);
    try timing.measure(runner, "ext.asin [out of domain]", ext_iters, benchAsinOut);
    try timing.measure(runner, "ext.acos", ext_iters, benchAcos);
    try timing.measure(runner, "ext.acos [out of domain]", ext_iters, benchAcosOut);
    try timing.measure(runner, "ext.atan", ext_iters, benchAtan);
    try timing.measure(runner, "ext.atan2", ext_iters, benchAtan2);
    try timing.measure(runner, "ext.sinh", ext_iters, benchSinh);
    try timing.measure(runner, "ext.cosh", ext_iters, benchCosh);
    try timing.measure(runner, "ext.tanh", ext_iters, benchTanh);
    try timing.measure(runner, "ext.asinh", ext_iters, benchAsinh);
    try timing.measure(runner, "ext.acosh", ext_iters, benchAcosh);
    try timing.measure(runner, "ext.acosh [out of domain]", ext_iters, benchAcoshOut);
    try timing.measure(runner, "ext.atanh", ext_iters, benchAtanh);
    try timing.measure(runner, "ext.atanh [out of domain]", ext_iters, benchAtanhOut);
    try timing.measure(runner, "ext.floor", ext_iters, benchFloor);
    try timing.measure(runner, "ext.ceil", ext_iters, benchCeil);
    try timing.measure(runner, "ext.trunc", ext_iters, benchTrunc);
    try timing.measure(runner, "ext.round", ext_iters, benchRound);
}

// =========================================================================
// Entry point
// =========================================================================

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    // One runner per group, so each prints its own table and the two
    // never interleave into one unreadable list. A second
    // `std.Io.Threaded` costs a thread pool, which is nothing against a
    // run of several million iterations, and it leaves the shared
    // harness untouched — which matters, because the other two benchmark
    // files measure against exactly the same one.
    var algebra_runner = try timing.Runner.init(gpa.allocator());
    defer algebra_runner.deinit();
    std.debug.print("\n== group: Interval algebraic operations ==\n", .{});
    try runAlgebra(&algebra_runner);
    algebra_runner.report.print();

    var ext_runner = try timing.Runner.init(gpa.allocator());
    defer ext_runner.deinit();
    std.debug.print("\n== group: elementary functions ==\n", .{});
    try runExt(&ext_runner);
    ext_runner.report.print();
}
