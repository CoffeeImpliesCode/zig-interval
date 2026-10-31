//! The random layer: one generator, THIRTY-FIVE operations, one sweep of
//! 8,000 cases each. Every case is drawn from a table of MAGNITUDES rather
//! than from a uniform distribution — the regimes the defects live in are
//! subnormals, the overflow frontier and exact signed zeros, and a uniform
//! draw over the `f64` range reaches none of them — screened for a
//! non-finite operand, and then judged against the exact image.
//!
//! Two thirds of what this sweep needs is not here, and the split is worth
//! naming. Drawing a case, and printing what went wrong when one fails, are
//! this file's business. Deciding whether a returned interval encloses the
//! true image is not: the frontier sweep builds the very same `Case` values
//! by hand and asks the very same `holds`, and the reproducer tests assert
//! against the very same references, so the verdict and every reference it
//! reads live in `soundness_shared.zig`. What is left here is the generator,
//! the report and the thirty-five sweeps that drive them.
const shared = @import("soundness_shared.zig");

const std = shared.std;
const Interval = shared.Interval;

const Case = shared.Case;
const Op = shared.Op;
const ScaleBound = shared.ScaleBound;
const SumBound = shared.SumBound;
const Tally = shared.Tally;
const Value = shared.Value;

const apply = shared.apply;
const exact = shared.exact;
const ex = shared.ex;
const holds = shared.holds;
const inf64 = shared.inf64;
const lowerOk = shared.lowerOk;
const marginAdmissible = shared.marginAdmissible;
const max_detail = shared.max_detail;
const min_subnormal = shared.min_subnormal;
const neg_inf64 = shared.neg_inf64;
const reportErr = shared.reportErr;
const showCase = shared.showCase;
const streamSeed = shared.streamSeed;
const sumBound = shared.sumBound;
const summary = shared.summary;
const twoSum = shared.twoSum;
const upperOk = shared.upperOk;

// ---------------------------------------------------------------------------
// Fuzz machinery
// ---------------------------------------------------------------------------

/// Cases per fuzzed operation.
const fuzz_cases: usize = 8000;

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

/// Why a drawn case cannot be judged, when it cannot.
const Screen = enum {
    ok,
    /// A NaN or a non-finite operand or scalar. The oracle states true
    /// extrema only for finite `f64` endpoints, so these are set aside and
    /// counted rather than silently dropped or misreported as a defect.
    nonfinite,
    /// The case falls in a documented precondition or a documented
    /// limitation, neither of which is a property the oracle may assume
    /// away. `expand` needs `margin >= -(hi - lo) / 2`, which is a
    /// precondition of the operation. `midpoint` is the one limitation:
    /// the package says its sum of the two endpoints overflows for a box
    /// at the top of the range where the centre does not, and an
    /// operation that documents itself as not a sound place to start from
    /// is not judged as though it were one.
    ///
    /// `div` and `recip` are NOT here, which is the point of this entry.
    /// They used to be, on the ground that a divisor touching zero makes
    /// the true image unbounded. It does, and the library has a
    /// documented answer for it, and an answer that is documented is a
    /// contract value to be checked rather than a case to be set aside.
    precondition,
};

fn screen(raw: Raw) Screen {
    const values = [5]f64{ raw.a[0], raw.a[1], raw.b[0], raw.b[1], raw.s };
    for (values) |v| {
        if (std.math.isNan(v) or !std.math.isFinite(v)) return .nonfinite;
    }
    switch (raw.op) {
        .expand => {
            // The precondition is a real inequality, so it is decided on
            // the real through the exact three-term sign and never on a
            // width rounded to one `f128`. A rounded width lets through
            // margins the operation does not actually accept, and the
            // interval it then returns is inverted — an abort, not a
            // failure report, and one that takes the rest of the binary
            // with it.
            if (!marginAdmissible(raw.a[0], raw.a[1], raw.s)) return .precondition;
        },
        .midpoint => {
            // The exact centre of a box spanning the frontier is finite
            // even where the f64 sum of its endpoints is not, and the
            // package documents that gap. The exact sum is never
            // infinite in f128 for two f64 operands, so an infinite f64
            // sum is exactly the documented case and nothing else.
            if (std.math.isInf(raw.a[0] + raw.a[1])) return .precondition;
        },
        else => {},
    }
    return .ok;
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

/// The diagnosis for a sum reference: the two `f64` operands of each end,
/// the `f128` head their sum rounds to, and the residual the rounding
/// dropped.
///
/// Both halves are printed, and that is the point rather than a flourish.
/// The head alone is what a rounded reference would have compared against,
/// so a log carrying only the head would be the argument this file exists
/// to refute rather than evidence for it.
fn reportSum(s: SumBound, got: Value) void {
    const g = got.intervalOrNull();
    const lo = twoSum(s.alo, s.blo);
    const hi = twoSum(s.ahi, s.bhi);
    reportErr("      true lo = {e} + {e} = {e} + {e} exactly\n", .{ s.alo, s.blo, lo.s, lo.err });
    reportErr("      true hi = {e} + {e} = {e} + {e} exactly\n", .{ s.ahi, s.bhi, hi.s, hi.err });
    if (g) |x| {
        if (!s.lowerOk(x.lo)) {
            reportErr("      lower bound is ABOVE the true minimum and excludes it\n", .{});
        }
        if (!s.upperOk(x.hi)) {
            reportErr("      upper bound is BELOW the true maximum and excludes it\n", .{});
        }
    }
}

/// The diagnosis for a bounded `scale`: the five terms of each end, and which
/// side cut inside the truth.
///
/// No midpoint and no half-width is printed, because there is no such number
/// to print and printing a rounded one is the mistake this reference was
/// written to avoid. What a reader gets instead is the formula, the original
/// operands, and the verdict of the exact comparison.
fn reportScale(s: ScaleBound, got: Value) void {
    const g = got.intervalOrNull();
    reportErr("      A = {e}, B = {e}, G = |factor| = {e}\n", .{ s.lo, s.hi, s.mag });
    reportErr(
        "      true lo = (A + B + G*A - G*B) / 2, compared as the sign of that minus 2*lo and never formed\n",
        .{},
    );
    reportErr(
        "      true hi = (A + B - G*A + G*B) / 2, compared as the sign of that minus 2*hi and never formed\n",
        .{},
    );
    if (g) |x| {
        if (!s.lowerOk(x.lo)) {
            reportErr("      lower bound is ABOVE the true minimum and excludes it\n", .{});
        }
        if (!s.upperOk(x.hi)) {
            reportErr("      upper bound is BELOW the true maximum and excludes it\n", .{});
        }
    }
}

fn report(c: Case, got: Value, t: *Tally) void {
    t.failures += 1;
    if (t.shown >= max_detail) return;
    t.shown += 1;
    reportErr("    FAIL {s}: the answer is not what the oracle requires\n", .{c.op.label()});
    showCase(c, got);
    if (got.intervalOrNull()) |g| {
        if (std.math.isNan(g.lo) or std.math.isNan(g.hi)) {
            // A NaN compares false against everything, so it would sail
            // past both order tests and then be quoted with a gap of zero,
            // which reads as "the bound sits exactly on the extremum". It
            // is named out instead, because a NaN bound is not a bound.
            reportErr("      a returned bound is NaN, which encloses nothing\n", .{});
        }
        if (g.lo > g.hi) {
            reportErr("      the returned interval is inverted: lo > hi\n", .{});
        }
    }
    if (c.op == .scale) {
        reportScale(.{ .lo = c.a.lo, .hi = c.a.hi, .mag = @abs(c.s) }, got);
    } else if (sumBound(c)) |s| {
        reportSum(s, got);
    } else if (exact(c)) |r| {
        reportErr("      exact lo = {e}\n", .{r.lo});
        reportErr("      exact hi = {e}\n", .{r.hi});
        const g = got.intervalOrNull();
        if (r.lo_beyond) {
            reportErr(
                "      the true minimum is a real past the end of the f64 range, so a" ++
                    "returned lo of +inf excludes it\n",
                .{},
            );
        } else if (g != null and !lowerOk(r.lo, g.?.lo)) {
            var buf: [64]u8 = undefined;
            const gap = if (std.math.isNan(g.?.lo))
                ""
            else
                std.mem.print(&buf, " : {e} ULP", .{gapUlp(g.?.lo, r.lo)}) catch " : ?";
            reportErr("      lower bound is ABOVE the true minimum and excludes it{s}\n", .{gap});
        }
        if (r.hi_beyond) {
            reportErr(
                "      the true maximum is a real past the end of the f64 range, so a" ++
                    "returned hi of -inf excludes it\n",
                .{},
            );
        } else if (g != null and !upperOk(r.hi, g.?.hi)) {
            var buf: [64]u8 = undefined;
            const gap = if (std.math.isNan(g.?.hi))
                ""
            else
                std.mem.print(&buf, " : {e} ULP", .{gapUlp(g.?.hi, r.hi)}) catch " : ?";
            reportErr("      upper bound is BELOW the true maximum and excludes it{s}\n", .{gap});
        }
    } else {
        reportErr("      the oracle for this operation is {s}\n", .{c.op.oracle()});
    }
}

fn fuzz(op: Op) Tally {
    var prng = std.Random.DefaultPrng.init(streamSeed(op));
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
    summary(t, "");
    return t;
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

// The rest of the surface. One line per operation, the same generator and
// the same report, in the order of `Op` so that reading the log top to
// bottom reads the enum.

test "fuzz: abs" {
    const t = fuzz(.abs);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: sqr" {
    const t = fuzz(.sqr);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: neg" {
    const t = fuzz(.neg);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: hull" {
    const t = fuzz(.hull);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: intersect" {
    const t = fuzz(.intersect);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: hull_of" {
    const t = fuzz(.hull_of);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: intersection_of" {
    const t = fuzz(.intersection_of);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: midpoint" {
    const t = fuzz(.midpoint);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: clamp" {
    const t = fuzz(.clamp);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: width" {
    const t = fuzz(.width);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: distance_to" {
    const t = fuzz(.distance_to);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: contains" {
    const t = fuzz(.contains);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: overlaps" {
    const t = fuzz(.overlaps);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: subset_of" {
    const t = fuzz(.subset_of);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: eql" {
    const t = fuzz(.eql);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: ne" {
    const t = fuzz(.ne);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: lt" {
    const t = fuzz(.lt);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: le" {
    const t = fuzz(.le);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: gt" {
    const t = fuzz(.gt);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: ge" {
    const t = fuzz(.ge);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: floor" {
    const t = fuzz(.floor);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: ceil" {
    const t = fuzz(.ceil);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: trunc" {
    const t = fuzz(.trunc);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: round" {
    const t = fuzz(.round);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: sqrt" {
    const t = fuzz(.sqrt);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: cbrt" {
    const t = fuzz(.cbrt);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: tanh" {
    const t = fuzz(.tanh);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}
