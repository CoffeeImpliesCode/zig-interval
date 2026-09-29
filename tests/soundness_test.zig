//! Soundness oracle. The package's central claim is that every operation
//! returns a guaranteed enclosure of the true result of the expression it
//! was asked about, and this file is the only place in the tree that holds
//! that claim to account. Containment is the property under test, and the
//! quantity it is checked against is derived in `f128` from the original
//! `f64` inputs — never by evaluating the corners in `f64` and then
//! treating those results as truth. Evaluating the corners in `f64` and
//! believing them is the mistake that let a result that cuts inside the
//! true image pass 200 tests, so the oracle never makes it.
//!
//! Why `f128` is exact enough for the job:
//!
//!   * An `f64` combined with an `f64` needs 53 + 53 = 106 significand
//!     bits and `f128` carries 113, so addition, subtraction and
//!     multiplication of two `f64` values are EXACT in `f128`. Every
//!     endpoint of every operation under test is a sum or a product of two
//!     `f64`s, so the true extremum of the image is available with no
//!     error term at all — not an approximation of it, the value itself.
//!   * The `f128` exponent range vastly exceeds `f64`'s, so a product that
//!     overflows or a product that underflows to a signed zero in `f64` —
//!     1e600, 1e-400 — is an ordinary normal number here. The oracle never
//!     loses the magnitude or the sign exactly where the library does.
//!   * A quotient is NOT exact even in `f128`, so `div` and `recip` are
//!     never checked by evaluating a quotient. They are checked by exact
//!     cross-multiplication: the bound times the divisor is an `f64` times
//!     an `f64`, which `f128` holds exactly, and the sign of the divisor
//!     fixes the direction of the comparison.
//!
//! The suite was RED against the tree this file was written for — the
//! pre-fix one, where 9 of the 15 tests fail — and is GREEN against the
//! tree as it now stands. It is kept rather than deleted at that point,
//! because it goes red again the moment an operation stops enclosing.
//!
//! One rule earned here, recorded so it survives: a case whose
//! precondition is a SPECIFIC overflow or a SPECIFIC underflow has to be
//! seeded through the magnitude table, because a random draw over any
//! table will miss it. `scale([-floatMax, floatMax], 0.0)` returns a NaN
//! interval — the width is `+inf` and `inf * 0` is NaN — and this file
//! reported it as sound for as long as the table drew `.float_max`
//! unsigned, because then no box could span both signs at the frontier
//! and `hi - lo` could never overflow. The `full_range` class is the
//! fix; more samples would not have been.

const std = @import("std");
const interval = @import("interval");
const Interval = interval.Interval;

/// Seed for every fuzz stream. Fixed, so a failure reproduces exactly and a
/// pass means something; `std.Random.DefaultPrng` rather than the system
/// source, which would make the suite meaningless.
const seed: u64 = 0xDEAD_BEEF_CAFE_F00D;

/// Cases per fuzzed operation.
const fuzz_cases: usize = 8000;

/// How many individual failures one fuzz prints in full. The count is
/// always reported exactly; this only bounds the detail so a sweep with a
/// large blast radius stays readable.
const max_detail: usize = 12;

// ---------------------------------------------------------------------------
// Exact layer
// ---------------------------------------------------------------------------

const inf128 = std.math.inf(f128);
const neg_inf128 = -inf128;
const inf64 = std.math.inf(f64);
const neg_inf64 = -inf64;

/// Exact widening of an `f64` to `f128`. Every `f64` is a `f128`, so this
/// loses nothing.
inline fn ex(x: f64) f128 {
    return @as(f128, x);
}

/// The exact image of an operation over a box of `f64` endpoints, held in
/// `f128`. Both bounds are the true mathematical extrema, not roundings of
/// them.
const Range = struct {
    lo: f128,
    hi: f128,
};

/// True when `glo` is an acceptable lower bound for the exact minimum
/// `elo`.
///
/// The infinities are handled on their own terms rather than left to the
/// ordering, because the ordering alone is not the rule. An infinite
/// returned bound is a legitimate enclosure of any finite exact extremum
/// and must not be reported as a failure. An exact extremum of -inf is a
/// different matter: no `f64` below it exists, so only -inf itself can
/// bound it, and a finite bound there is a miss.
fn lowerOk(elo: f128, glo: f64) bool {
    if (std.math.isNan(elo) or std.math.isNan(glo)) return false;
    if (elo == neg_inf128) return glo == neg_inf64;
    if (glo == neg_inf64) return true;
    return ex(glo) <= elo;
}

/// The mirror of `lowerOk` for the upper bound.
fn upperOk(ehi: f128, ghi: f64) bool {
    if (std.math.isNan(ehi) or std.math.isNan(ghi)) return false;
    if (ehi == inf128) return ghi == inf64;
    if (ghi == inf64) return true;
    return ex(ghi) >= ehi;
}

/// Exact image of `a + b`. Addition rises in both operands, so the range
/// is the two same-signed corner sums, each exact in `f128`.
fn exactAdd(a: Interval, b: Interval) Range {
    return .{ .lo = ex(a.lo) + ex(b.lo), .hi = ex(a.hi) + ex(b.hi) };
}

/// Exact image of `a - b`. Subtraction rises in the first operand and
/// falls in the second, so the pairing crosses: the minimum takes `a.lo`
/// against `b.hi` and the maximum takes `a.hi` against `b.lo`. Pairing
/// low with low here would understate the image, so the crossing is the
/// whole point of the routine.
fn exactSub(a: Interval, b: Interval) Range {
    return .{ .lo = ex(a.lo) - ex(b.hi), .hi = ex(a.hi) - ex(b.lo) };
}

/// Exact image of `a * b`. The extreme products of two intervals are
/// always at a pair of endpoints, so the range is the min and the max over
/// the four corner products — each computed in `f128`, and each therefore
/// the true product rather than a rounding of it. This is the step the
/// existing suite does not take: it reads the `f64` corners back out of
/// the implementation and compares them with themselves.
fn exactMul(a: Interval, b: Interval) Range {
    const p1 = ex(a.lo) * ex(b.lo);
    const p2 = ex(a.lo) * ex(b.hi);
    const p3 = ex(a.hi) * ex(b.lo);
    const p4 = ex(a.hi) * ex(b.hi);
    return .{
        .lo = @min(@min(p1, p2), @min(p3, p4)),
        .hi = @max(@max(p1, p2), @max(p3, p4)),
    };
}

/// Exact image of a shift by `delta`, the same monotonicity argument as
/// `add` with the second operand pinned to a point.
fn exactTranslate(a: Interval, delta: f64) Range {
    return .{ .lo = ex(a.lo) + ex(delta), .hi = ex(a.hi) + ex(delta) };
}

/// Exact image of `scale`, under the semantics the package documents for
/// it: the WIDTH is scaled about the midpoint, not the interval multiplied
/// by the factor. `src/interval.zig` and the README both state it that way,
/// and the map is the affine one x -> m + |factor| * (x - m), whose image
/// of [lo, hi] is [m - half, half + m] with m = (lo + hi)/2 and
/// half = (hi - lo) * |factor| / 2. All three quantities are formed here in
/// `f128` from the `f64` endpoints, so the midpoint's own rounding and the
/// half-width's own rounding are both counted against the implementation
/// rather than assumed away.
fn exactScale(a: Interval, factor: f64) Range {
    const m = (ex(a.lo) + ex(a.hi)) / 2.0;
    const half = (ex(a.hi) - ex(a.lo)) * @abs(ex(factor)) / 2.0;
    return .{ .lo = m - half, .hi = m + half };
}

/// Exact image of a widening by `margin`, valid under the documented
/// precondition `margin >= -(hi - lo) / 2`.
fn exactExpand(a: Interval, margin: f64) Range {
    return .{ .lo = ex(a.lo) - ex(margin), .hi = ex(a.hi) + ex(margin) };
}

/// Containment of one corner quotient `a / b` in `got`, decided by exact
/// cross-multiplication.
///
/// The quotient is never evaluated. Both questions — is `got.lo` at most
/// the quotient, is the quotient at most `got.hi` — are answered by
/// multiplying through by the divisor, and each such product is an `f64`
/// times an `f64`, exact in `f128`. A positive divisor leaves the
/// inequality alone and a negative one reverses it, which is the only sign
/// case the argument needs. An infinite bound on the enclosing side is
/// always enough; an infinite bound on the far side is a miss, because the
/// quotient of two finite operands is finite.
fn quotientHolds(a: f64, b: f64, got: Interval) bool {
    const A = ex(a);
    const B = ex(b);
    if (B == 0.0) return true; // a divisor of zero is screened out earlier
    const lower = blk: {
        if (std.math.isNan(got.lo)) break :blk false;
        if (got.lo == neg_inf64) break :blk true;
        const L = ex(got.lo) * B;
        break :blk if (B > 0.0) L <= A else L >= A;
    };
    const upper = blk: {
        if (std.math.isNan(got.hi)) break :blk false;
        if (got.hi == inf64) break :blk true;
        const H = ex(got.hi) * B;
        break :blk if (B > 0.0) H >= A else H <= A;
    };
    return lower and upper;
}

// ---------------------------------------------------------------------------
// Reproducer verdicts
// ---------------------------------------------------------------------------

/// How much wider than the true image a returned interval may be before a
/// reproducer also fails for over-widening. The point is only to reject an
/// answer that gives up — the universal interval, a saturated `floatMax`,
/// anything — and not to pin how tight a legitimate answer is. A test that
/// pinned an exact widened literal would be wrong the moment the
/// implementation changed for a good reason; this one is not.
const width_rel: f64 = 4.0;
const width_ulp_floor: f64 = 1048576.0; // 2^20

/// The smallest positive `f64`. Drawn as an operand in its own right and
/// used as the resolution floor of the width bound.
const min_subnormal: f64 = 4.9406564584124654e-324;

/// True when the returned interval is not absurdly wider than the true
/// image.
///
/// Used by the reproducer helper and by NOTHING ELSE. The sweep checks
/// containment only, deliberately: the package's contract is enclosure
/// and not tightness, and [-inf, +inf] is the tightest sound `f64` answer
/// wherever the image genuinely leaves the range. Wiring this into the
/// sweep would report thousands of sound enclosures as failures and punish
/// correct behaviour. Its only job is to stop a fix that answers the
/// universal interval where a finite one exists.
///
/// The floor is measured from the smallest positive `f64` rather than
/// from the true extremum alone, because in the underflow regime the true
/// image sits around 1e-400 while no `f64` can be anywhere near it: the
/// narrowest answer a bound can give is two subnormals wide, and a floor
/// measured from 1e-400 would reject that as wasteful. Measuring from the
/// format's own resolution is the only floor that means the same thing in
/// every regime.
fn widthOk(got: Interval, r: Range) bool {
    const w = ex(got.hi) - ex(got.lo);
    if (std.math.isNan(w) or w == inf128) return false;
    const scale = @max(@abs(r.lo), @abs(r.hi));
    const floor = width_ulp_floor * @max(if (scale == 0.0) 1.0 else scale, min_subnormal);
    return w <= @max((r.hi - r.lo) * width_rel, floor);
}

/// Relative slack applied to a `powf` oracle value. The value comes from
/// an `f128` evaluation of `exp(y * log x)`, which is accurate to roughly
/// 1e-30 relative here, so the exact value is bracketed by that much
/// before the comparison. A pass is then a genuine pass rather than a
/// comparison against a number that is merely close.
const powf_slack: f128 = 1e-28;

/// Oracle for `x^y` at a positive base: the exact value to within
/// `powf_slack`. `f128` carries 34 significant decimal digits, and the
/// argument `y * log(x)` is formed there, so the error is some 1e-30
/// relative — many orders below the margin the library applies and far
/// below any difference the reproducers turn on.
fn exactPowf(x: f64, y: f64) Range {
    const v = @exp(ex(y) * @log(ex(x)));
    return .{ .lo = v * (1.0 - powf_slack), .hi = v * (1.0 + powf_slack) };
}

// ---------------------------------------------------------------------------
// Fuzz machinery
// ---------------------------------------------------------------------------

const Op = enum {
    add,
    sub,
    mul,
    div,
    recip,
    translate,
    scale,
    expand,

    fn label(op: Op) []const u8 {
        return @tagName(op);
    }

    /// True for the operations that take a second interval operand.
    fn usesSecond(op: Op) bool {
        return switch (op) {
            .add, .sub, .mul, .div => true,
            .recip, .translate, .scale, .expand => false,
        };
    }

    /// True for the operations that take a bare `f64` scalar.
    fn usesScalar(op: Op) bool {
        return switch (op) {
            .translate, .scale, .expand => true,
            .add, .sub, .mul, .div, .recip => false,
        };
    }
};

/// Magnitude classes an operand is drawn from. They are enumerated rather
/// than sampled from a uniform distribution because a uniform draw over
/// the `f64` range lands in the ordinary binade essentially always: it
/// never reaches a subnormal, never reaches the overflow frontier, and
/// never produces an exact signed zero. Those are the regimes the defects
/// live in, so they are drawn by name.
const Magnitude = enum {
    /// Ordinary values, kept so the sweep is not exclusively exotic.
    ordinary,
    /// Subnormals and the smallest powers of ten, where a product
    /// underflows to a zero that carries no magnitude.
    tiny,
    /// Up to the overflow frontier, where a product overflows to an
    /// infinity.
    huge,
    /// A tiny magnitude on BOTH sides of zero, so the interval spans it.
    /// The single-scale classes can only ever produce an interval that is
    /// all positive or all negative, and an interval that straddles zero
    /// at subnormal magnitude is the one shape where a corner underflows
    /// to a zero whose sign the reduction cannot see. Without this class
    /// the sweep reports `mul` as sound when it is not.
    tiny_spanning,
    /// A huge magnitude on both sides of zero, which is the same idea at
    /// the overflow frontier: the corners of a product or a quotient then
    /// overflow to infinities of both signs.
    huge_spanning,
    /// Exactly one of the two zeros, with its sign.
    exact_zero,
    /// The smallest positive subnormal.
    min_subnormal,
    /// The largest finite value, with a sign, so that a box drawn from
    /// this class can span the whole representable range. `float_max`
    /// below is the unsigned form, and the two are separate because only
    /// the spanning box has a width — 2*floatMax as a real, +inf as an
    /// f64 — and an infinite intermediate is the only place a
    /// width-based operation can meet one. Without this class
    /// `Interval.init(-floatMax, floatMax).scale(0.0)` returns a NaN
    /// interval and the sweep never sees it, because no other entry in
    /// the table can put both endpoints at the frontier.
    full_range,
    /// The largest finite value.
    float_max,
    /// Deliberately non-finite, to exercise the skip path.
    nonfinite,

    fn draw(m: Magnitude, r: std.Random) f64 {
        return switch (m) {
            .ordinary => r.float(f64) * 2000.0 - 1000.0,
            .tiny => pow10(r.intRangeAtMost(i32, -323, -290)) * (1.0 + r.float(f64) * 9.0),
            .huge => pow10(r.intRangeAtMost(i32, 285, 307)) * (1.0 + r.float(f64) * 0.7),
            .tiny_spanning => signed(pow10(r.intRangeAtMost(i32, -323, -290)) * (1.0 + r.float(f64) * 9.0), r),
            .huge_spanning => signed(pow10(r.intRangeAtMost(i32, 285, 307)) * (1.0 + r.float(f64) * 0.7), r),
            .exact_zero => if (r.boolean()) 0.0 else -0.0,
            .min_subnormal => min_subnormal,
            .float_max => std.math.floatMax(f64),
            .full_range => signed(std.math.floatMax(f64), r),
            .nonfinite => switch (r.intRangeAtMost(u8, 0, 2)) {
                0 => inf64,
                1 => neg_inf64,
                else => std.math.nan(f64),
            },
        };
    }
};

/// 10^e, evaluated in `f64` because the operand is an `f64` and the exact
/// power is not what a test operand has to be.
fn pow10(e: i32) f64 {
    return std.math.pow(f64, 10.0, @as(f64, @floatFromInt(e)));
}

/// A magnitude with a random sign, so that drawing both endpoints of an
/// interval from the same class lands on both sides of zero about half
/// the time. Negating zero is deliberately not reachable here: the sign
/// of a zero is a bit, not a choice, and `exact_zero` already covers it.
fn signed(magnitude: f64, r: std.Random) f64 {
    return if (r.boolean()) magnitude else -magnitude;
}

/// The magnitude table, weighted towards the regimes that matter. Ordinary
/// values keep the largest single share so the sweep stays a general test
/// rather than an exotic-only one.
const magnitudes = [_]Magnitude{
    .ordinary,
    .ordinary,
    .ordinary,
    .ordinary,
    .ordinary,
    .tiny,
    .tiny,
    .tiny,
    .tiny_spanning,
    .tiny_spanning,
    .tiny_spanning,
    .huge,
    .huge,
    .huge,
    .huge_spanning,
    .huge_spanning,
    .exact_zero,
    .min_subnormal,
    .full_range,
    .full_range,
    .float_max,
    .nonfinite,
};

fn drawMagnitude(r: std.Random) Magnitude {
    return magnitudes[r.uintLessThan(usize, magnitudes.len)];
}

/// A drawn case before any `Interval` exists. The values are screened
/// here rather than after construction because `Interval.init` asserts
/// `lo <= hi`, and a NaN endpoint fails that assertion by comparison rather
/// than by evaluation, which would abort the whole test binary instead of
/// setting the case aside.
const Raw = struct {
    op: Op,
    a: [2]f64,
    b: [2]f64,
    s: f64,
};

/// One screened case: the operation, both operand intervals, and the
/// scalar the unary-in-scalar operations use. `b` and `s` are unused by
/// the operations that do not take them.
const Case = struct {
    op: Op,
    a: Interval,
    b: Interval,
    s: f64,
};

/// Draw one interval's endpoints, sorted so `lo <= hi`. A degenerate
/// interval — one with `lo == hi` — is drawn on a fraction of the cases,
/// because a point interval exercises only two of the four corners of a
/// product and is the shape the existing tests use exclusively.
fn drawEndpoints(m: Magnitude, degenerate: bool, r: std.Random) [2]f64 {
    const x = m.draw(r);
    if (degenerate) return .{ x, x };
    const y = m.draw(r);
    return .{ @min(x, y), @max(x, y) };
}

fn drawRaw(op: Op, r: std.Random) Raw {
    const ma = drawMagnitude(r);
    // Half the cases pair the drawn magnitude against an independently
    // drawn one, which is the mixed-magnitude regime the defects need and
    // a single shared magnitude would reach only by luck.
    const mb = if (op.usesSecond() and r.boolean()) drawMagnitude(r) else ma;
    const degenerate = r.intRangeAtMost(u8, 0, 7) == 0;
    return .{
        .op = op,
        .a = drawEndpoints(ma, degenerate, r),
        .b = if (op.usesSecond()) drawEndpoints(mb, degenerate, r) else .{ 0.0, 0.0 },
        .s = drawMagnitude(r).draw(r),
    };
}

/// Build the intervals of a screened case. Every endpoint is finite here,
/// so the constructor's ordering assertion holds.
fn buildCase(raw: Raw) Case {
    return .{
        .op = raw.op,
        .a = Interval.init(raw.a[0], raw.a[1]),
        .b = Interval.init(raw.b[0], raw.b[1]),
        .s = raw.s,
    };
}

fn apply(c: Case) Interval {
    return switch (c.op) {
        .add => c.a.add(c.b),
        .sub => c.a.sub(c.b),
        .mul => c.a.mul(c.b),
        .div => c.a.div(c.b),
        .recip => c.a.recip(),
        .translate => c.a.translate(c.s),
        .scale => c.a.scale(c.s),
        .expand => c.a.expand(c.s),
    };
}

/// The exact image, for every operation whose image is a closed range this
/// layer can state exactly. `div` and `recip` return null because a
/// quotient is not exact in `f128`; they are checked by `quotientHolds`.
fn exact(c: Case) ?Range {
    return switch (c.op) {
        .add => exactAdd(c.a, c.b),
        .sub => exactSub(c.a, c.b),
        .mul => exactMul(c.a, c.b),
        .translate => exactTranslate(c.a, c.s),
        .scale => exactScale(c.a, c.s),
        .expand => exactExpand(c.a, c.s),
        .div, .recip => null,
    };
}

/// True when `got` is a guaranteed enclosure of the true image of the
/// case, and of the ordering invariant alongside it.
fn holds(c: Case, got: Interval) bool {
    if (got.lo > got.hi) return false;
    switch (c.op) {
        .div => {
            var ok = true;
            const dividends = [2]f64{ c.a.lo, c.a.hi };
            const divisors = [2]f64{ c.b.lo, c.b.hi };
            for (dividends) |x| {
                for (divisors) |y| {
                    if (!quotientHolds(x, y, got)) ok = false;
                }
            }
            return ok;
        },
        .recip => {
            var ok = true;
            for ([2]f64{ c.a.lo, c.a.hi }) |x| {
                if (!quotientHolds(1.0, x, got)) ok = false;
            }
            return ok;
        },
        else => {
            const r = exact(c).?;
            return lowerOk(r.lo, got.lo) and upperOk(r.hi, got.hi);
        },
    }
}

/// Why a drawn case cannot be judged, when it cannot.
const Screen = enum {
    ok,
    /// A NaN or a non-finite operand or scalar. The oracle states true
    /// extrema only for finite `f64` endpoints, so these are set aside and
    /// counted rather than silently dropped or misreported as a defect.
    nonfinite,
    /// The case violates a documented precondition. `div` and `recip` need
    /// a divisor excluding zero, because the corner argument divides by it
    /// and the true image is then unbounded; `expand` needs
    /// `margin >= -(hi - lo) / 2`, which is a precondition of the
    /// operation rather than a property the oracle may assume away.
    precondition,
};

fn screen(raw: Raw) Screen {
    const values = [5]f64{ raw.a[0], raw.a[1], raw.b[0], raw.b[1], raw.s };
    for (values) |v| {
        if (std.math.isNan(v) or !std.math.isFinite(v)) return .nonfinite;
    }
    switch (raw.op) {
        .div, .recip => {
            const d = if (raw.op == .div) raw.b else raw.a;
            if (d[0] <= 0.0 and 0.0 <= d[1]) return .precondition;
        },
        .expand => {
            // The precondition is a real inequality about the exact
            // width, so it is decided in f128. Deciding it on the rounded
            // f64 width would let through margins the operation does not
            // actually accept, and the interval it returns would be
            // inverted — an abort, not a failure report.
            const width = ex(raw.a[1]) - ex(raw.a[0]);
            if (ex(raw.s) < -width / 2.0) return .precondition;
        },
        else => {},
    }
    return .ok;
}

const Tally = struct {
    op: Op,
    checked: usize = 0,
    failures: usize = 0,
    shown: usize = 0,
    skipped_nonfinite: usize = 0,
    skipped_precondition: usize = 0,
};

fn showInterval(i: Interval) void {
    std.debug.print("      [{e: <26} , {e: <26} ]  bits 0x{X:0>16} 0x{X:0>16}\n", .{
        i.lo, i.hi, @as(u64, @bitCast(i.lo)), @as(u64, @bitCast(i.hi)),
    });
}

fn showCase(c: Case, got: Interval) void {
    std.debug.print("    case: {s}\n", .{c.op.label()});
    if (c.op.usesSecond()) {
        std.debug.print("      a =\n", .{});
        showInterval(c.a);
        std.debug.print("      b =\n", .{});
        showInterval(c.b);
    } else {
        std.debug.print("      a =\n", .{});
        showInterval(c.a);
        if (c.op.usesScalar()) {
            std.debug.print("      s = {e}  (bits 0x{X:0>16})\n", .{ c.s, @as(u64, @bitCast(c.s)) });
        }
    }
    std.debug.print("      returned =\n", .{});
    showInterval(got);
}

/// Signed distance from a returned bound to the exact extremum it is
/// meant to bound, in ULPs of the bound. Positive is slack, negative is a
/// bound that has cut inside the true image. It is printed with every
/// failure so a claim of "one ULP too tight" can be checked from the log
/// instead of re-derived, which matters because a sub-ULP miss is exactly
/// the kind of finding an oracle gets accused of inventing.
fn gapUlp(got: f64, want: f128) f128 {
    const g = ex(got);
    const scale = @max(@abs(g), @abs(want));
    if (std.math.isNan(g) or scale == 0.0) return 0.0;
    return (g - want) * 0x1p52 / scale;
}

fn report(c: Case, got: Interval, t: *Tally) void {
    t.failures += 1;
    if (t.shown >= max_detail) return;
    t.shown += 1;
    std.debug.print("    FAIL {s}: the returned interval is not an enclosure\n", .{c.op.label()});
    showCase(c, got);
    if (std.math.isNan(got.lo) or std.math.isNan(got.hi)) {
        // A NaN compares false against everything, so it would sail past
        // both order tests and then be quoted with a gap of zero, which
        // reads as "the bound sits exactly on the extremum". It is named
        // out instead, because a NaN bound is not a bound at all.
        std.debug.print("      a returned bound is NaN, which encloses nothing\n", .{});
    }
    if (exact(c)) |r| {
        std.debug.print("      exact lo = {e}\n", .{r.lo});
        std.debug.print("      exact hi = {e}\n", .{r.hi});
        if (!lowerOk(r.lo, got.lo)) {
            var buf: [64]u8 = undefined;
            const gap = if (std.math.isNan(got.lo))
                ""
            else
                std.fmt.bufPrint(&buf, " : {e} ULP", .{gapUlp(got.lo, r.lo)}) catch " : ?";
            std.debug.print("      lower bound is ABOVE the true minimum and excludes it{s}\n", .{gap});
        }
        if (!upperOk(r.hi, got.hi)) {
            var buf: [64]u8 = undefined;
            const gap = if (std.math.isNan(got.hi))
                ""
            else
                std.fmt.bufPrint(&buf, " : {e} ULP", .{gapUlp(got.hi, r.hi)}) catch " : ?";
            std.debug.print("      upper bound is BELOW the true maximum and excludes it{s}\n", .{gap});
        }
    } else {
        std.debug.print("      checked by exact cross-multiplication of each corner quotient\n", .{});
    }
    if (got.lo > got.hi) {
        std.debug.print("      the returned interval is inverted: lo > hi\n", .{});
    }
}

fn summary(t: Tally) void {
    std.debug.print("  {s}: {d} checked, {d} FAILED, {d} skipped non-finite, {d} skipped precondition\n", .{
        t.op.label(), t.checked, t.failures, t.skipped_nonfinite, t.skipped_precondition,
    });
    if (t.failures > t.shown) {
        std.debug.print("  {s}: {d} further failures not printed individually\n", .{ t.op.label(), t.failures - t.shown });
    }
}

fn fuzz(op: Op) Tally {
    var prng = std.Random.DefaultPrng.init(seed ^ @as(u64, @intFromEnum(op)));
    const r = prng.random();
    var t: Tally = .{ .op = op };
    for (0..fuzz_cases) |_| {
        const raw = drawRaw(op, r);
        switch (screen(raw)) {
            .nonfinite => {
                t.skipped_nonfinite += 1;
                continue;
            },
            .precondition => {
                t.skipped_precondition += 1;
                continue;
            },
            .ok => {},
        }
        t.checked += 1;
        const c = buildCase(raw);
        const got = apply(c);
        if (!holds(c, got)) report(c, got, &t);
    }
    summary(t);
    return t;
}

// ---------------------------------------------------------------------------
// Minimal reproducers, and the guards around them
// ---------------------------------------------------------------------------

/// Assert that `got` encloses `r`, and print the diagnosis if it does not.
/// The width bound is only applied when the true image is representable in
/// `f64`; where it is not, every correct answer is the universal interval
/// and a width bound would say nothing.
fn expectEnclosure(name: []const u8, got: Interval, r: Range, check_width: bool) !void {
    const lo_ok = lowerOk(r.lo, got.lo);
    const hi_ok = upperOk(r.hi, got.hi);
    const wide_ok = !check_width or widthOk(got, r);
    if (lo_ok and hi_ok and wide_ok) return;
    std.debug.print("\n  UNSOUND: {s}\n", .{name});
    std.debug.print("    returned =\n", .{});
    showInterval(got);
    std.debug.print("    exact lo = {e}\n", .{r.lo});
    std.debug.print("    exact hi = {e}\n", .{r.hi});
    if (!lo_ok) std.debug.print("    returned lo is ABOVE the true minimum and excludes it\n", .{});
    if (!hi_ok) std.debug.print("    returned hi is BELOW the true maximum and excludes it\n", .{});
    if (!wide_ok) std.debug.print("    returned interval is far wider than the true image\n", .{});
    std.debug.print("\n", .{});
    return error.NotAnEnclosure;
}

test "guard: an overflowed corner is not the true extremum, so its bound is pulled back inside" {
    // NOT a defect reproducer. The audit filed "nextUp(-inf) returns
    // -floatMax" as a soundness hole; it is not one, and the audit has
    // withdrawn it. The true image of [-1e300, -1e300] * [1e300, 1e300]
    // is the single real -1e600, and -1e600 lies between -inf and
    // -floatMax, so [-inf, -floatMax] encloses it and the original
    // saturation was correct.
    //
    // This stays as a guard because the natural "fix" is unsound. Making
    // the outward step non-strict, so that the smallest f64 at or above
    // -inf is -inf itself, looks like the same rule the step applies
    // everywhere else. It is not: -inf is below every real, so [-inf, -inf]
    // excludes -1e600. That version of the rule was specified, tried, and
    // caught here, and the test is what caught it. The rule that is right
    // is the saturating one, and the test below says so.
    const a = Interval.init(-1e300, -1e300);
    const b = Interval.init(1e300, 1e300);
    const want = exactMul(a, b);

    const saturating = Interval.init(-inf64, -std.math.floatMax(f64));
    const saturating_ok = lowerOk(want.lo, saturating.lo) and upperOk(want.hi, saturating.hi);
    std.debug.print("\n  guard (saturating step, [-inf, -floatMax]): -> {s}\n", .{
        if (saturating_ok) "ENCLOSES the true -1e600" else "does NOT enclose it",
    });
    try std.testing.expect(saturating_ok);

    const collapsed = Interval.init(-inf64, neg_inf64);
    const collapsed_ok = lowerOk(want.lo, collapsed.lo) and upperOk(want.hi, collapsed.hi);
    std.debug.print("  guard (non-strict step, [-inf, -inf]): -> {s}\n", .{
        if (collapsed_ok) "ENCLOSES the true -1e600" else "does NOT enclose it",
    });
    try std.testing.expect(!collapsed_ok);

    // No width bound: the correct answer has infinite width, because no
    // finite pair of f64 brackets -1e600.
    try expectEnclosure("mul does not enclose the true -1e600", a.mul(b), want, false);
}

test "reproducer 1: mul underflow to a signed zero - the lost corner is outside the returned bound" {
    // A product of two non-zero operands that is too small for f64 comes
    // back as a zero carrying only an operand's sign. The min and the max
    // over the four corners then compare zeros, cannot tell the two signs
    // apart, and a bound that stops at the zero leaves out the value the
    // zero stands for. The true maximum here is 1e-400, which is a
    // strictly positive real no larger than the zero the corner became.
    //
    // Two cases, both in the underflow regime, reported separately:
    //
    //  (a) the case as the audit states it, [-1e-200,-1e200] taken
    //      literally is [-1e-200,-1e-200] * [1e-200,1e-200]. Its true
    //      image is the single NEGATIVE point -1e-400 (the audit records
    //      it as +1e-400), and all four corners underflow to the same
    //      -0.0, so the sign never has to be told apart and the returned
    //      interval does enclose it. Verdict reported either way.
    //  (b) the same regime with the corner signs mixed, which is the shape
    //      the defect actually needs: the positive corner is dragged down
    //      to a negative zero by the reduction and the true +1e-400 falls
    //      outside the bound.
    const positive = Interval.init(1e-200, 1e-200);
    const mixed = Interval.init(-1e-200, 1e-200);
    const audit_case = Interval.init(-1e-200, -1e-200).mul(Interval.init(1e-200, 1e-200));
    const audit_exact = exactMul(Interval.init(-1e-200, -1e-200), Interval.init(1e-200, 1e-200));
    const audit_ok = lowerOk(audit_exact.lo, audit_case.lo) and upperOk(audit_exact.hi, audit_case.hi);
    std.debug.print("\n  reproducer 1a (literal audit case): exact image [{e}, {e}] -> {s}\n", .{
        audit_exact.lo, audit_exact.hi, if (audit_ok) "ENCLOSED" else "NOT ENCLOSED",
    });
    std.debug.print("    returned =\n", .{});
    showInterval(audit_case);

    const got = positive.mul(mixed);
    try expectEnclosure("mul underflow excludes the true +1e-400", got, exactMul(positive, mixed), true);
}

test "reproducer 2: translate has no outward widening - the exact 0.1 + 0.2 is above the returned bound" {
    // 0.1 + 0.2 in exact arithmetic over the two f64 values is
    // 10808639105689191 / 2^55 = 0.3000000000000000166533453693773481,
    // which is strictly BELOW the f64 nearest it, 0.30000000000000004.
    // A shift that adds without widening therefore returns a lower bound
    // above the true minimum and cuts the true value off. The value here
    // is built from the f64 endpoints, not from the decimal literals, so
    // it is the sum of the two f64 numbers rather than the real 0.3.
    const a = Interval.init(0.1, 0.2);
    const got = a.translate(0.2);
    try expectEnclosure("translate excludes the exact 0.1 + 0.2", got, exactTranslate(a, 0.2), true);
}

test "reproducer 3: powf's fixed relative margin does not grow with the exponent" {
    // The exponent is reached by repeated squaring, whose relative error
    // doubles with every bit of it, so a fixed margin cannot cover it once
    // the exponent is large enough. 1.0000000001^1e8 is 1.0100501679193823.
    const base = Interval.init(1.0000000001, 1.0000000001);
    const expo = Interval.init(1e8, 1e8);
    const got = interval.ext.powf(base, expo) orelse return error.PowfRefused;
    try expectEnclosure("powf excludes the true 1.0000000001^1e8", got, exactPowf(1.0000000001, 1e8), true);
}

// ---------------------------------------------------------------------------
// The div and recip forms, and the guards
// ---------------------------------------------------------------------------

test "guard: an overflowed quotient is not the true extremum either" {
    // The same property as the product guard above, at the other end of
    // the range and through the division path. 1e300 / 1e-300 is 1e600, a
    // finite real past the end of the f64 range, so a corner quotient of
    // +inf is not that real: +inf is above it, and the lower bound taken
    // from that corner has to come back down to +floatMax. The reciprocal
    // of 1e-320 is 1e320, the same shape from the other direction.
    //
    // Not a defect reproducer. The audit filed the saturating step as the
    // bug; it is the other way round, and these two hold now as they did
    // before. They are kept because a bound that collapses an overflowed
    // quotient to [+inf, +inf] is unsound for the reason the product guard
    // spells out, and nothing else in the tree would notice.
    const a = Interval.init(1e300, 1e300);
    const b = Interval.init(1e-300, 1e-300);
    const got = a.div(b);
    if (!quotientHolds(a.lo, b.lo, got)) {
        std.debug.print("\n  UNSOUND: div overflow does not enclose the true 1e600\n", .{});
        std.debug.print("    returned =\n", .{});
        showInterval(got);
        std.debug.print("    exact quotient {e} / {e} = about {e}\n", .{ a.lo, b.lo, ex(a.lo) / ex(b.lo) });
        return error.NotAnEnclosure;
    }

    const tiny = Interval.init(1e-320, 1e-320);
    const recip_got = tiny.recip();
    if (!quotientHolds(1.0, tiny.lo, recip_got)) {
        std.debug.print("\n  UNSOUND: recip overflow does not enclose the true 1e320\n", .{});
        std.debug.print("    returned =\n", .{});
        showInterval(recip_got);
        std.debug.print("    exact quotient 1 / {e} = about {e}\n", .{ tiny.lo, 1.0 / ex(tiny.lo) });
        return error.NotAnEnclosure;
    }
}

test "reproducer 4: div underflow to a signed zero" {
    // A quotient of two non-zero operands underflows exactly as a product
    // does. With the dividend spanning zero the two corner quotients have
    // opposite signs, and the reduction cannot tell a +0.0 from a -0.0.
    // The corner that should have supplied the upper bound is the positive
    // one, +1e-400, and it came back as a zero that lost its sign.
    const a = Interval.init(-1e-200, 1e-200);
    const b = Interval.init(1e200, 1e200);
    const got = a.div(b);
    if (quotientHolds(a.hi, b.lo, got)) return;
    std.debug.print("\n  UNSOUND: div underflow excludes the true +1e-400\n", .{});
    std.debug.print("    returned =\n", .{});
    showInterval(got);
    std.debug.print("    exact quotient {e} / {e} = about {e}\n", .{ a.hi, b.lo, ex(a.hi) / ex(b.lo) });
    return error.NotAnEnclosure;
}

test "reproducer 5: recip underflow" {
    // 1 / 1e300 is 1e-300, in range, and the audit's own subnormal case
    // 1 / 1e-320 is the one that leaves it. The recip path is monotone in
    // its argument and an interval excluding zero maps to an interval of
    // one sign, so the two corner quotients never have opposite signs and
    // the sign-losing reduction cannot bite here the way it does in `div`.
    // Reported so the coverage is complete and the reason for the difference
    // is on the record.
    const audit = Interval.init(1e300, 1e300).recip();
    const audit_ok = quotientHolds(1.0, 1e300, audit);
    std.debug.print("\n  reproducer 5a (1/1e300): -> {s}\n", .{if (audit_ok) "ENCLOSED" else "NOT ENCLOSED"});
    try std.testing.expect(audit_ok);

    const huge = Interval.init(1.7e308, 1.7e308);
    const got = huge.recip();
    if (quotientHolds(1.0, huge.lo, got)) return;
    std.debug.print("\n  UNSOUND: recip underflow excludes the true 1/1.7e308\n", .{});
    std.debug.print("    returned =\n", .{});
    showInterval(got);
    return error.NotAnEnclosure;
}

// ---------------------------------------------------------------------------
// The fuzz sweeps
// ---------------------------------------------------------------------------

test "fuzz: add" {
    const t = fuzz(.add);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: sub" {
    const t = fuzz(.sub);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: mul" {
    const t = fuzz(.mul);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: div" {
    const t = fuzz(.div);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: recip" {
    const t = fuzz(.recip);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: translate" {
    const t = fuzz(.translate);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: scale" {
    const t = fuzz(.scale);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: expand" {
    const t = fuzz(.expand);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}
