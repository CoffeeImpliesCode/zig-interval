//! An EXTERNAL consumer of this package: a separate Zig program in its own
//! package, built against `interval` through the real dependency graph and
//! never handed a source file. The repository's own tests are compiled with
//! the module object in hand, so nothing in them can tell whether a name
//! here reaches a real dependent package at all; this file can, because
//! that is the only way it is built.
//!
//! It exercises four layers as MATH. The interval surface comes first, the
//! way it always did, and then exact rationals, three-valued truth,
//! tracked scalars, branch identity and the complex plane are each asked a
//! question whose answer is decided by mathematics rather than by the
//! library having written a name down: a cube root of a negative number
//! that a float exponent cannot express, a rank that is not a rank, a
//! square root that is partly defined, two rays with a gap between them
//! where an interval answer says there is no gap, and `i * i` whose
//! imaginary part is exactly zero.
//!
//! Nothing here asserts that a name EXISTS or that two spellings reach the
//! same place. Such a check passes for a library that forwards every call
//! to somewhere real and fails for one that computes, which is precisely
//! backwards; the semantics below would all hold either way.
const std = @import("std");
const interval = @import("interval");

const Interval = interval.Interval;
const Vec = interval.Vec;
const DynVec = interval.DynVec;

/// Raised when the library produces a value it does not promise, and when a
/// line reporting one cannot be written. Returning either from main makes
/// the process exit non-zero, failing the parent `consumer` step.
pub const CheckError = error{ UnexpectedIntervalValue, WriteFailed };

/// Number of behavioural checks; the summary line reports this. It counts
/// claims, not declarations: nothing here asserts that a name exists or
/// that two spellings reach the same place, because a check like that
/// passes for a library that forwards and fails for one that computes.
const total_checks = 48;

/// The program's own output: one line per claim, on stderr, with nothing in
/// front of the bytes.
///
/// `std.debug.print` is the debugging logger rather than a program's report,
/// and it is also the wrong tool here for a second reason beyond that: it
/// flushes every line before returning. These fixtures exist to be READ when
/// the library misbehaves, and a library that PANICS rather than returns
/// takes the process with it, so a line still sitting in a buffer is a line
/// nobody reads. Every line is therefore flushed as it is written, which is
/// what the debugging logger was doing anyway and costs one syscall per
/// claim.
///
/// A write that fails is reported as `CheckError.WriteFailed` rather than
/// swallowed: a report that could not be written is a report that cannot be
/// trusted, and every run in which that matters is already failing.
const Report = struct {
    stderr: std.Io.File.Writer,

    /// Write one line and flush it, so the line is readable even if whatever
    /// comes next does not return.
    fn line(self: *Report, comptime fmt: []const u8, args: anytype) CheckError!void {
        try self.stderr.interface.print(fmt, args);
        try self.stderr.interface.flush();
    }
};

/// Compare a produced interval against the expected one, loudly on mismatch.
/// Exact endpoints are the right assertion for the set and geometry
/// operations, which do no arithmetic and therefore need no widening.
fn expectInterval(
    report: *Report,
    what: []const u8,
    got: Interval,
    want: Interval,
) CheckError!void {
    if (got.lo != want.lo or got.hi != want.hi) {
        try report.line(
            "FAIL {s}: got [{d}, {d}], want [{d}, {d}]\n",
            .{ what, got.lo, got.hi, want.lo, want.hi },
        );
        return CheckError.UnexpectedIntervalValue;
    }
    try report.line("ok {s}: [{d}, {d}]\n", .{ what, got.lo, got.hi });
}

/// Compare a produced scalar against the expected one, loudly on mismatch.
fn expectFloat(
    report: *Report,
    what: []const u8,
    got: f64,
    want: f64,
) CheckError!void {
    if (got != want) {
        try report.line("FAIL {s}: got {d}, want {d}\n", .{ what, got, want });
        return CheckError.UnexpectedIntervalValue;
    }
    try report.line("ok {s}: {d}\n", .{ what, got });
}

fn expectBool(
    report: *Report,
    what: []const u8,
    got: bool,
    want: bool,
) CheckError!void {
    if (got != want) {
        try report.line("FAIL {s}: got {}, want {}\n", .{ what, got, want });
        return CheckError.UnexpectedIntervalValue;
    }
    try report.line("ok {s}: {}\n", .{ what, got });
}

/// Assert a `null` result, the library's signal for an answer that is empty
/// in the reals.
fn expectNullInterval(
    report: *Report,
    what: []const u8,
    got: ?Interval,
) CheckError!void {
    if (got) |g| {
        try report.line(
            "FAIL {s}: got [{d}, {d}], want null\n",
            .{ what, g.lo, g.hi },
        );
        return CheckError.UnexpectedIntervalValue;
    }
    try report.line("ok {s}: null\n", .{what});
}

/// The other half of `expectNullInterval`: assert that an answer IS there.
///
/// `null` is a real answer the library can give, so forcing it open with `?`
/// would turn "the library disagreed with this check" into a panic that
/// names neither. A check that wants an interval says so here instead, and
/// the check fails with a line that says which check failed.
fn expectPresent(
    report: *Report,
    what: []const u8,
    got: ?Interval,
) CheckError!Interval {
    return got orelse {
        try report.line("FAIL {s}: got null, want an interval\n", .{what});
        return CheckError.UnexpectedIntervalValue;
    };
}

/// Assert the library's central promise: `got` CONTAINS the exact real
/// interval [exact_lo, exact_hi]. Equality is neither expected nor wanted
/// here, because every arithmetic endpoint is widened by one ULP outward.
fn expectEncloses(
    report: *Report,
    what: []const u8,
    got: Interval,
    exact_lo: f64,
    exact_hi: f64,
) CheckError!void {
    if (got.lo > exact_lo or got.hi < exact_hi) {
        try report.line(
            "FAIL {s}: [{d}, {d}] does not enclose [{d}, {d}]\n",
            .{ what, got.lo, got.hi, exact_lo, exact_hi },
        );
        return CheckError.UnexpectedIntervalValue;
    }
    try report.line(
        "ok {s}: [{d}, {d}] encloses [{d}, {d}]\n",
        .{ what, got.lo, got.hi, exact_lo, exact_hi },
    );
}

/// Assert both halves of the enclosure claim for an addition whose operands
/// are exactly representable, so the exact sum is known and the machine's own
/// round-to-nearest answer `rn` is computable by hand.
///
/// The result must lie STRICTLY outside `rn` on both sides and must still
/// contain the true value. If it merely equalled `rn`, a one-ULP error in the
/// operands would be passed through as if it were exact, and the caller would
/// have no way to tell.
fn expectWidenedEnclosure(
    report: *Report,
    what: []const u8,
    got: Interval,
    rn: Interval,
    true_lo: f64,
    true_hi: f64,
) CheckError!void {
    if (got.lo >= rn.lo or got.hi <= rn.hi) {
        try report.line(
            "FAIL {s}: [{d}, {d}] is not wider than [{d}, {d}]\n",
            .{ what, got.lo, got.hi, rn.lo, rn.hi },
        );
        return CheckError.UnexpectedIntervalValue;
    }
    if (got.lo > true_lo or got.hi < true_hi) {
        try report.line(
            "FAIL {s}: [{d}, {d}] does not enclose [{d}, {d}]\n",
            .{ what, got.lo, got.hi, true_lo, true_hi },
        );
        return CheckError.UnexpectedIntervalValue;
    }
    try report.line(
        "ok {s}: [{d}, {d}] encloses [{d}, {d}], wider than [{d}, {d}]\n",
        .{ what, got.lo, got.hi, true_lo, true_hi, rn.lo, rn.hi },
    );
}

/// How much wider than the exact image a returned interval may be, as a
/// fraction of the image's magnitude. Every widening the library applies is
/// a rounding-order effect of order 1e-16, so this is a sanity bound rather
/// than a measure of the step: it fails a runaway result, the whole line or
/// a percent of slack, and leaves a few steps of tightening or widening
/// free.
const width_slack: f64 = 1e-9;

/// Assert the library's promise for an image of the form [0, exact_hi].
///
/// The lower end is a zero, and a zero is attained exactly and is its own
/// bound, so no step is demanded there: a result sitting on it is already
/// correct, and demanding a step would be demanding a wider answer than
/// correctness requires. The upper end is a real value the computation
/// could have missed, so it must come back at least one representable step
/// outside `exact_hi`: that step is the outward rounding, and a caller
/// handed the round-to-nearest answer could not tell a bound from an
/// estimate. Containment is the soundness claim and is checked on both
/// ends; the width bound keeps a result that merely overshoots from
/// passing.
fn expectEnclosesFromZero(
    report: *Report,
    what: []const u8,
    got: Interval,
    exact_hi: f64,
) CheckError!void {
    if (got.lo > 0.0 or got.hi < exact_hi) {
        try report.line(
            "FAIL {s}: [{d}, {d}] does not enclose [0, {d}]\n",
            .{ what, got.lo, got.hi, exact_hi },
        );
        return CheckError.UnexpectedIntervalValue;
    }
    if (got.hi <= exact_hi) {
        try report.line(
            "FAIL {s}: upper bound {d} is not widened past {d}\n",
            .{ what, got.hi, exact_hi },
        );
        return CheckError.UnexpectedIntervalValue;
    }
    if (got.hi - got.lo - exact_hi > width_slack * (exact_hi + 1.0)) {
        try report.line(
            "FAIL {s}: [{d}, {d}] is far wider than [0, {d}]\n",
            .{ what, got.lo, got.hi, exact_hi },
        );
        return CheckError.UnexpectedIntervalValue;
    }
    try report.line(
        "ok {s}: [{d}, {d}] encloses [0, {d}] and is widened at the top\n",
        .{ what, got.lo, got.hi, exact_hi },
    );
}

/// Assert an enclosure against an EXACT witness that is representable in
/// binary floating point, and nothing else.
///
/// The right assertion for a result whose true value is a small integer, a
/// zero or a sign: the answer has to CONTAIN it, and how far outside it
/// sits is a quality measure this fixture deliberately does not judge. A
/// check that pinned the endpoints would pin the width, and the width is
/// the one thing an enclosure library is free to change.
fn expectContains(
    report: *Report,
    what: []const u8,
    got: Interval,
    exact: f64,
) CheckError!void {
    if (!got.contains(exact)) {
        try report.line(
            "FAIL {s}: [{d}, {d}] does not contain {d}\n",
            .{ what, got.lo, got.hi, exact },
        );
        return CheckError.UnexpectedIntervalValue;
    }
    try report.line("ok {s}: [{d}, {d}] contains {d}\n", .{ what, got.lo, got.hi, exact });
}

/// Assert a `Truth` against the one the mathematics gives, by name.
///
/// The three states are printed rather than as a bool because the third
/// one is the whole point of the type: `maybe` is what a caller sees when
/// the outcomes are not pinned down, and a boolean would have thrown away
/// the difference between "we know it is mixed" and "we do not know",
/// which are different facts about different problems.
fn expectTruth(
    report: *Report,
    what: []const u8,
    got: interval.Truth,
    want: interval.Truth,
) CheckError!void {
    if (got != want) {
        try report.line(
            "FAIL {s}: got {s}, want {s}\n",
            .{ what, @tagName(got), @tagName(want) },
        );
        return CheckError.UnexpectedIntervalValue;
    }
    try report.line("ok {s}: {s}\n", .{ what, @tagName(got) });
}

/// Report the range a tracked value carries, insisting that it carries
/// one. Reaching this with an absent range means something asked for a
/// value the mathematics does not have, and the line says which.
fn trackedRange(
    report: *Report,
    what: []const u8,
    t: interval.Tracked,
) CheckError!Interval {
    return t.range orelse {
        try report.line("FAIL {s}: the value is wholly undefined\n", .{what});
        return CheckError.UnexpectedIntervalValue;
    };
}

/// The complex box a tracked-free complex answer carries, under the same
/// insistence as `trackedRange`: an absent box is a fact to report, not a
/// box to work around.
fn complexRange(
    report: *Report,
    what: []const u8,
    c: interval.Complex,
) CheckError!interval.complex.Bounds {
    return c.range orelse {
        try report.line("FAIL {s}: the complex value is wholly undefined\n", .{what});
        return CheckError.UnexpectedIntervalValue;
    };
}

/// Assert that a complex box contains an exact point, and that it does so
/// in both coordinates at once.
///
/// A witness has to be exact in binary floating point for this to decide
/// anything, which every witness below is: the integers, the zeroes, and
/// the exact halves. A rounded transcendental is not a witness, and
/// padding one to be a witness would be the implementation marking its
/// own homework.
fn expectComplexPoint(
    report: *Report,
    what: []const u8,
    b: interval.complex.Bounds,
    re: f64,
    im: f64,
) CheckError!void {
    if (!b.re.contains(re) or !b.im.contains(im)) {
        try report.line(
            "FAIL {s}: re [{d}, {d}], im [{d}, {d}] does not contain ({d}, {d})\n",
            .{ what, b.re.lo, b.re.hi, b.im.lo, b.im.hi, re, im },
        );
        return CheckError.UnexpectedIntervalValue;
    }
    try report.line("ok {s}: contains ({d}, {d})\n", .{ what, re, im });
}

/// Check a whole vector in one shot: the dimension, then every component.
/// One vector is one behavioural check, so it reports on one line.
fn expectVecExact(
    report: *Report,
    what: []const u8,
    got: anytype,
    want: []const Interval,
) CheckError!void {
    if (got.dim() != want.len) {
        try report.line(
            "FAIL {s}: dim {d}, want {d}\n",
            .{ what, got.dim(), want.len },
        );
        return CheckError.UnexpectedIntervalValue;
    }
    for (want, 0..) |w, i| {
        const g = got.get(i);
        if (g.lo != w.lo or g.hi != w.hi) {
            try report.line(
                "FAIL {s}: component {d} is [{d}, {d}], want [{d}, {d}]\n",
                .{ what, i, g.lo, g.hi, w.lo, w.hi },
            );
            return CheckError.UnexpectedIntervalValue;
        }
    }
    try report.line("ok {s}: {d} components exact\n", .{ what, want.len });
}

/// Same, but each component only has to CONTAIN the exact real interval,
/// which is the right assertion for a widened arithmetic result.
fn expectVecEncloses(
    report: *Report,
    what: []const u8,
    got: anytype,
    want: []const Interval,
) CheckError!void {
    if (got.dim() != want.len) {
        try report.line(
            "FAIL {s}: dim {d}, want {d}\n",
            .{ what, got.dim(), want.len },
        );
        return CheckError.UnexpectedIntervalValue;
    }
    for (want, 0..) |w, i| {
        const g = got.get(i);
        if (g.lo > w.lo or g.hi < w.hi) {
            try report.line(
                "FAIL {s}: component {d} is [{d}, {d}], does not enclose [{d}, {d}]\n",
                .{ what, i, g.lo, g.hi, w.lo, w.hi },
            );
            return CheckError.UnexpectedIntervalValue;
        }
    }
    try report.line("ok {s}: {d} components enclose\n", .{ what, want.len });
}

/// Every check, once each, in the order the sections below appear.
///
/// The report is passed in rather than reached for, so that every line these
/// checks write goes through one buffer and one stream: the parent's log is
/// then exactly what this program decided, in the order it decided it.
fn run(report: *Report) !void {
    // --- Set and geometry operations: exact endpoints, no widening. ---

    try expectInterval(
        report,
        "hull",
        Interval.init(1.0, 3.0).hull(Interval.init(2.0, 5.0)),
        Interval.init(1.0, 5.0),
    );

    try expectInterval(
        report,
        "intersect",
        try expectPresent(
            report,
            "intersect",
            Interval.init(1.0, 3.0).intersect(Interval.init(2.0, 5.0)),
        ),
        Interval.init(2.0, 3.0),
    );

    const disjoint = Interval.init(0.0, 1.0).intersect(Interval.init(2.0, 3.0));
    if (disjoint) |d| {
        try report.line(
            "FAIL intersect-disjoint: got [{d}, {d}], want null\n",
            .{ d.lo, d.hi },
        );
        return CheckError.UnexpectedIntervalValue;
    }
    try report.line("ok intersect-disjoint: null\n", .{});

    const spread = [_]Interval{
        Interval.init(4.0, 7.0),
        Interval.init(1.0, 3.0),
        Interval.init(2.0, 9.0),
    };
    try expectInterval(
        report,
        "hullOf",
        try expectPresent(report, "hullOf", Interval.hullOf(&spread)),
        Interval.init(1.0, 9.0),
    );

    const common = [_]Interval{
        Interval.init(1.0, 5.0),
        Interval.init(2.0, 6.0),
        Interval.init(3.0, 4.0),
    };
    try expectInterval(
        report,
        "intersectionOf",
        try expectPresent(report, "intersectionOf", Interval.intersectionOf(&common)),
        Interval.init(3.0, 4.0),
    );

    try expectFloat(report, "distanceTo", Interval.init(1.0, 3.0).distanceTo(0.0), 1.0);

    try expectFloat(report, "clamp", Interval.init(1.0, 3.0).clamp(5.0), 3.0);

    // --- Algebraic operations: every result is an enclosure, so the
    // assertion is containment, never equality. All the operands below are
    // small integers, so the exact real result is a small integer too. ---

    // 1 + 2 = 3, 3 + 5 = 8.
    try expectEncloses(
        report,
        "add",
        Interval.init(1.0, 3.0).add(Interval.init(2.0, 5.0)),
        3.0,
        8.0,
    );

    // 5 - 2 = 3, 7 - 1 = 6.
    try expectEncloses(
        report,
        "sub",
        Interval.init(5.0, 7.0).sub(Interval.init(1.0, 2.0)),
        3.0,
        6.0,
    );

    // IEEE negation is exact and only the endpoints swap, so neg is the one
    // algebraic operation that returns its endpoints unwidened. [-3, -1] is
    // therefore an exact result, not merely an enclosure.
    try expectInterval(report, "neg", Interval.init(1.0, 3.0).neg(), Interval.init(-3.0, -1.0));

    // Smallest product 2*2 = 4, largest 3*3 = 9.
    try expectEncloses(
        report,
        "mul-positive",
        Interval.init(2.0, 3.0).mul(Interval.init(2.0, 3.0)),
        4.0,
        9.0,
    );

    // Sign change: the four products are -4, 6, -6 and 9, so the image is
    // [-6, 9]. The minimum is 3*(-2), NOT 2*(-2): pairing the two lo ends
    // gives -4, and a check written against -4 would accept exactly that
    // mistake, so the lower corner is stated where a wrong one fails.
    try expectEncloses(
        report,
        "mul-mixed-sign",
        Interval.init(2.0, 3.0).mul(Interval.init(-2.0, 3.0)),
        -6.0,
        9.0,
    );

    // Divisor stays strictly positive, so the quotient stays bounded:
    // smallest 4/4 = 1, largest 8/2 = 4.
    try expectEncloses(
        report,
        "div-positive",
        Interval.init(4.0, 8.0).div(Interval.init(2.0, 4.0)),
        1.0,
        4.0,
    );

    // The two affine operations. Neither returns the interval it was handed
    // any more: `scale` and `expand` widen their result outward, so an
    // equality check against the pre-widening interval was checking the old
    // output rather than the guarantee. The image of each is [0, 4] here.
    // Zero is attained exactly and is its own bound, so no step is asked
    // for at the bottom; 4 is a real value the arithmetic could have
    // missed, so a step at the top is required and is checked.
    try expectEnclosesFromZero(report, "scale", Interval.init(1.0, 3.0).scale(2.0), 4.0);
    try expectEnclosesFromZero(report, "expand", Interval.init(1.0, 3.0).expand(1.0), 4.0);

    // The image of |x| over [-3, 5] is [0, 5], not [3, 5]: the minimum of
    // |x| is 0, reached at x = 0 inside the interval.
    try expectEncloses(report, "abs", Interval.init(-3.0, 5.0).abs(), 0.0, 5.0);

    // --- The enclosure guarantee itself. ---

    // The central claim of the library, checked twice: once where no rounding
    // error is possible, and once where it certainly is.
    //
    // Here every operand is an exactly representable integer, so the machine's
    // own round-to-nearest sum is exactly 5 and exactly 10, and the exact real
    // sum is also exactly 5 and exactly 10. A result equal to [5, 10] would
    // happen to be sound here, but only by luck: the library must not depend
    // on luck, so it must come back strictly wider.
    try expectWidenedEnclosure(
        report,
        "enclosure-widening",
        Interval.init(1.0, 2.0).add(Interval.init(4.0, 8.0)),
        Interval.init(5.0, 10.0), // what round-to-nearest would return
        5.0,
        10.0,
    );

    // Now a case where the naive answer is WRONG, not merely narrow.
    //
    // The operands are the f64 values 0.1 and 0.7, which are not the reals
    // 1/10 and 7/10 but are slightly above and slightly below them. Their
    // exact real sum is therefore 0.79999999999999996114..., which lies
    // strictly BETWEEN the two adjacent f64 values 0.7999999999999999
    // (0.79999999999999991118...) and 0.8 (0.80000000000000004440...).
    //
    // Round-to-nearest picks 0.7999999999999999, which is BELOW the true sum:
    // returning it as a lower bound would exclude the real answer and the
    // error would be undetectable downstream. A sound lower bound therefore
    // has to be at most 0.7999999999999999, and since no double lies between
    // that value and the true sum, "at most" here means strictly less. For
    // the same reason a sound upper bound has to be at least 0.8.
    try expectWidenedEnclosure(
        report,
        "enclosure-rounding-error",
        Interval.init(0.1, 0.1).add(Interval.init(0.7, 0.7)),
        Interval.init(0.7999999999999999, 0.7999999999999999), // round-to-nearest
        0.7999999999999999, // largest double below the true sum
        0.8, // smallest double above the true sum
    );

    // --- Certain comparisons. ---

    // lt is true only when every point of self is below every point of other.
    try expectBool(
        report,
        "lt-separated",
        Interval.init(1.0, 2.0).lt(Interval.init(3.0, 4.0)),
        true,
    );

    // [1, 3] and [3, 5] share the point 3, so it is NOT certain that self is
    // less than other. `lt` is self.hi < other.lo, never self.lo < other.hi.
    try expectBool(
        report,
        "lt-touching",
        Interval.init(1.0, 3.0).lt(Interval.init(3.0, 5.0)),
        false,
    );

    // Overlapping: some points of self are above some points of other, so the
    // certain answer is false even though the intervals do overlap.
    try expectBool(
        report,
        "lt-overlapping",
        Interval.init(1.0, 3.0).lt(Interval.init(2.0, 5.0)),
        false,
    );

    // --- Elementary functions. ---

    // sqrt is increasing, so the image of [4, 9] is [sqrt 4, sqrt 9] = [2, 3].
    // 2 and 3 are exact, but the result is still widened, so assert that it
    // BRACKETS [2, 3] rather than equalling it.
    try expectEncloses(
        report,
        "sqrt-brackets",
        try expectPresent(report, "sqrt-brackets", interval.sqrt(Interval.init(4.0, 9.0))),
        2.0,
        3.0,
    );

    // The real logarithm is undefined on (-inf, 0], so the image of [-1, 0]
    // is empty in the reals. Empty is signalled by null, which is a
    // different condition from unbounded.
    try expectNullInterval(
        report,
        "log-non-positive",
        interval.log(Interval.init(-1.0, 0.0)),
    );

    // Same distinction on the other branch: no real square root below zero.
    try expectNullInterval(
        report,
        "sqrt-negative",
        interval.sqrt(Interval.init(-4.0, -1.0)),
    );

    // --- Vector forms. ---

    // Componentwise addition of two boxes. Each component is the same exact
    // integer sum as the scalar case above, widened by one ULP on each end:
    // prevDown(2) = 1.9999999999999998, nextUp(3) = 3.0000000000000004, and
    // so on up to prevDown(6) = 5.999999999999999, nextUp(7) = 7.000000000000001.
    const va = Vec(3).fromArray(.{
        Interval.init(1.0, 2.0),
        Interval.init(3.0, 4.0),
        Interval.init(5.0, 6.0),
    });
    const vb = Vec(3).fromArray(.{
        Interval.init(1.0, 1.0),
        Interval.init(1.0, 1.0),
        Interval.init(1.0, 1.0),
    });
    // One check covers the whole vector: dimension plus all three components.
    try expectVecExact(report, "vec3-add", va.add(vb), &.{
        Interval.init(1.9999999999999998, 3.0000000000000004),
        Interval.init(3.9999999999999996, 5.000000000000001),
        Interval.init(5.999999999999999, 7.000000000000001),
    });

    // Two boxes that share a large overlap in two components are still
    // disjoint, because the first component is disjoint: the intersection of
    // boxes is empty as soon as ONE component is empty.
    const vleft = Vec(3).fromArray(.{
        Interval.init(0.0, 1.0),
        Interval.init(0.0, 10.0),
        Interval.init(0.0, 10.0),
    });
    const vright = Vec(3).fromArray(.{
        Interval.init(2.0, 3.0),
        Interval.init(0.0, 10.0),
        Interval.init(0.0, 10.0),
    });
    if (vleft.intersect(vright) != null) {
        try report.line("FAIL vec3-intersect-disjoint: got a box, want null\n", .{});
        return CheckError.UnexpectedIntervalValue;
    }
    try report.line("ok vec3-intersect-disjoint: null\n", .{});

    // DynVec carries its dimension at runtime and its own allocator. The
    // constructor only copies, so the components are exact. `neg` mutates in
    // place through a pointer and returns void, so its result is checked as an
    // enclosure: the true image of -x over [1, 2] is [-2, -1].
    var dv = try DynVec.fromArray(std.heap.page_allocator, &.{
        Interval.init(1.0, 2.0),
        Interval.init(3.0, 4.0),
    });
    defer dv.deinit();
    try expectVecExact(report, "dynvec-init", dv, &.{
        Interval.init(1.0, 2.0),
        Interval.init(3.0, 4.0),
    });

    dv.neg();
    try expectVecEncloses(report, "dynvec-neg", dv, &.{
        Interval.init(-2.0, -1.0),
        Interval.init(-4.0, -3.0),
    });

    // --- Empty versus unbounded: the distinction that matters most. ---

    // A divisor that straddles zero makes the quotient set all of R. That is
    // an unbounded interval, not an empty one: it is [-inf, inf], a real
    // answer, and emphatically not null. Null would have meant "no answer
    // exists", as in the log and sqrt checks above.
    const unbounded = Interval.init(1.0, 2.0).div(Interval.init(-1.0, 1.0));
    if (unbounded.lo != -std.math.inf(f64) or unbounded.hi != std.math.inf(f64)) {
        try report.line(
            "FAIL div-straddling-zero: got [{d}, {d}], want [-inf, inf]\n",
            .{ unbounded.lo, unbounded.hi },
        );
        return CheckError.UnexpectedIntervalValue;
    }
    try report.line("ok div-straddling-zero: [-inf, inf]\n", .{});

    // =======================================================================
    // The layers above, exercised as MATH rather than as names.
    // =======================================================================
    //
    // Everything to this point is the original surface: intervals, vectors,
    // and the elementary functions. What follows is the four layers this
    // package grew, and each one is asked a question whose answer is
    // decided by mathematics rather than by the library having written a
    // name down. A check that could pass on forwarding would pass for a
    // forwarding bug, which is the one class of bug this file exists to be
    // able to see.

    // --- Layer one: exact rationals, and the root a float cannot ask for.

    // (-8)^(1/3) is -2, and the interesting part is that the question is
    // ANSWERABLE AT ALL. The f64 nearest to 1/3 is not 1/3, so `powf` with
    // a base of -8 under an exponent of that value has to enclose the image
    // of a slightly different exponent, and a negative base under a
    // non-integer exponent is a question with no real answer. Passing the
    // exponent as the exact pair (1, 3) is what makes it one.
    const third = interval.Rational{ .numerator = 1, .denominator = 3 };
    try expectContains(
        report,
        "powRational-cube-root-of-minus-eight",
        interval.ext.powRational(Interval.init(-8.0, -8.0), third) orelse {
            try report.line("FAIL powRational-cube-root-of-minus-eight: got null\n", .{});
            return CheckError.UnexpectedIntervalValue;
        },
        -2.0,
    );

    // The exact pair normalizes: (4, 6) and (6, 4) are the same rational,
    // and an unreduced one would be a different exponent to anyone reading
    // the struct rather than dividing it.
    const reduced = interval.Rational.init(4, 6) catch {
        try report.line("FAIL rational-init: got an error\n", .{});
        return CheckError.UnexpectedIntervalValue;
    };
    try expectFloat(
        report,
        "rational-reduced-numerator",
        @floatFromInt(reduced.numerator),
        2.0,
    );
    try expectFloat(
        report,
        "rational-reduced-denominator",
        @floatFromInt(reduced.denominator),
        3.0,
    );

    // A rank is ONE-BASED and integer-valued. Rank 2 of three ordered
    // intervals is the middle one, and rank 3.5 is not a rank at all: it
    // is a real number between two ranks, and the honest answer is that
    // there is no such element. Both halves are checked, because an
    // implementation that rounded 3.5 down to 3 would satisfy the first
    // and fail the second.
    const ordered = [_]Interval{
        Interval.init(1.0, 1.0),
        Interval.init(5.0, 5.0),
        Interval.init(9.0, 9.0),
    };
    var scratch: [3]f64 = undefined;
    try expectContains(
        report,
        "nthSmallest-rank-2",
        try interval.ext.nthSmallest(&ordered, Interval.init(2.0, 2.0), scratch[0..]) orelse {
            try report.line("FAIL nthSmallest-rank-2: got null\n", .{});
            return CheckError.UnexpectedIntervalValue;
        },
        5.0,
    );
    try expectNullInterval(
        report,
        "nthSmallest-rank-3.5",
        try interval.ext.nthSmallest(&ordered, Interval.init(3.5, 3.5), scratch[0..]),
    );

    // --- Layer two: three-valued truth about a partly off-domain root.

    // The square root of [-1, 1] EXISTS for some points of the box and not
    // for others. An `Interval` answer of [0, 1] is correct as an enclosure
    // and says nothing about which; a `Tracked` answer says
    // `defined = maybe`, and that is the reason the type exists. Neither
    // `always` nor `never` would be true here, so the check that fails if
    // the value is over-claimed is the one that matters.
    const straddling = interval.Tracked.init(Interval.init(-1.0, 1.0)).sqrt();
    try expectTruth(report, "sqrt-straddling-defined", straddling.defined, .maybe);
    try expectContains(
        report,
        "sqrt-straddling-range",
        try trackedRange(report, "sqrt-straddling-range", straddling),
        0.0,
    );

    // The square root of [-4, -1] has NO real value at any point of the
    // box. This is where a `Tracked` and an `?Interval` part company: the
    // range is ABSENT rather than an interval standing in for nothing. An
    // implementation that answered [-inf, inf] would pass every
    // containment check above and would draw a picture of a value that is
    // not there, so the absence is what this row asserts.
    const off_domain = interval.Tracked.init(Interval.init(-4.0, -1.0)).sqrt();
    try expectTruth(report, "sqrt-off-domain-defined", off_domain.defined, .never);
    if (off_domain.range != null) {
        try report.line("FAIL sqrt-off-domain-range: got a range, want none\n", .{});
        return CheckError.UnexpectedIntervalValue;
    }
    try report.line("ok sqrt-off-domain-range: absent\n", .{});

    // Strictness, which the interval layer cannot express at all. Two
    // points are compared, and the answer is `always` or `never` because a
    // point is either below another point or it is not. The two rows are
    // opposites on purpose: an equality that were reported as `maybe` would
    // be the classic bug, since the whole domain of x < x is empty and
    // there is nothing to be unsure about.
    try expectTruth(
        report,
        "tracked-lt-separated",
        interval.Tracked.point(2.0).lt(interval.Tracked.point(4.0)),
        .always,
    );
    try expectTruth(
        report,
        "tracked-lt-equal-points",
        interval.Tracked.point(3.0).lt(interval.Tracked.point(3.0)),
        .never,
    );

    // --- Layer three: branch identity, and the gap a hull would erase.

    // floor([0.9, 1.1]) is the two values 0 and 1. The hull is [0, 1], and
    // the hull is not a rounding of the answer: it contains 0.5, which is
    // not the floor of anything in that box. Two pieces and two labels, and
    // the label IS the integer the box floored to.
    //
    // The pieces are looked up BY LABEL rather than by position, because
    // the order a producer emits them in is not a promise — only the
    // pairing of value and label is, and a check that read `pieces[0]`
    // would be asserting an implementation detail that could change for no
    // reason a caller could see.
    var floor_pieces: [4]interval.branches.Piece(interval.Tracked) = undefined;
    var floor_pool: [8]interval.branches.Assignment = undefined;
    var floor_in: [1]interval.branches.Piece(interval.Tracked) = undefined;
    floor_in[0] = .{
        .value = interval.Tracked.init(Interval.init(0.9, 1.1)),
        .assignments = &.{},
    };
    var floor_writer = interval.branches.Writer(interval.Tracked).init(
        floor_pieces[0..],
        floor_pool[0..],
    );
    const floored = try interval.branches.floor(
        &floor_writer,
        .{ .pieces = floor_in[0..] },
        7,
    );
    if (floored.pieces.len != 2) {
        try report.line("FAIL floor-cells: got {d} pieces, want 2\n", .{floored.pieces.len});
        return CheckError.UnexpectedIntervalValue;
    }
    for ([_]interval.branches.Choice{ 0, 1 }) |cell| {
        var piece_with_cell: ?interval.branches.Piece(interval.Tracked) = null;
        for (floored.pieces) |piece| {
            for (piece.assignments) |a| {
                if (a.site == 7 and a.choice == cell) piece_with_cell = piece;
            }
        }
        const piece = piece_with_cell orelse {
            try report.line(
                "FAIL floor-cell-{d}: no piece is labelled with it\n",
                .{cell},
            );
            return CheckError.UnexpectedIntervalValue;
        };
        // The image of a cell is the integer itself, exactly: a whole
        // number, and a whole-number answer with a fractional endpoint
        // would be a widening the mathematics does not call for.
        try expectInterval(
            report,
            "floor-cell-value",
            try trackedRange(report, "floor-cell-value", piece.value),
            Interval.init(@floatFromInt(cell), @floatFromInt(cell)),
        );
        try report.line("ok floor-cell-{d}: labelled at site 7\n", .{cell});
    }

    // 1/x over [-1, 1] is two RAYS, and the gap between them is the point
    // of the exercise: the images are (-inf, -1] and [1, inf), so zero is
    // in neither, and nothing of magnitude below 1 is in either. The
    // interval layer answers [-inf, inf] here, which is a real answer and
    // is also a statement that 0 is reachable. It is not.
    var recip_in: [1]interval.branches.Piece(interval.Tracked) = undefined;
    var recip_pieces: [4]interval.branches.Piece(interval.Tracked) = undefined;
    var recip_pool: [8]interval.branches.Assignment = undefined;
    recip_in[0] = .{
        .value = interval.Tracked.init(Interval.init(-1.0, 1.0)),
        .assignments = &.{},
    };
    var recip_writer = interval.branches.Writer(interval.Tracked).init(
        recip_pieces[0..],
        recip_pool[0..],
    );
    const reciprocated = try interval.branches.recip(
        &recip_writer,
        .{ .pieces = recip_in[0..] },
        8,
    );
    var gap_holds = reciprocated.pieces.len == 2;
    for (reciprocated.pieces) |piece| {
        const range = try trackedRange(report, "recip-gap", piece.value);
        // Neither ray may reach zero, and neither may reach 0.5, which is
        // in the gap between them.
        if (range.contains(0.0)) gap_holds = false;
        if (range.contains(0.5)) gap_holds = false;
    }
    if (!gap_holds) {
        try report.line("FAIL recip-gap: a piece reaches into the gap\n", .{});
        return CheckError.UnexpectedIntervalValue;
    }
    try report.line("ok recip-gap: 2 rays, neither reaches 0\n", .{});

    // --- Layer four: the complex plane, where i*i is -1 and not a box.

    // i*i = -1 exactly. This is the check a forwarding implementation
    // cannot pass by accident: the imaginary coordinate is EXACTLY zero,
    // and it is checked exactly because a complex multiply that widened
    // the two coordinates independently would put that box somewhere
    // around zero and might still contain 0.0 while being far too wide to
    // be an answer. Containment alone would let it through.
    const imaginary_unit = interval.Complex.point(0.0, 1.0);
    const squared_box = try complexRange(report, "i*i", imaginary_unit.mul(imaginary_unit));
    try expectComplexPoint(report, "i*i-contains-minus-one", squared_box, -1.0, 0.0);
    if (squared_box.im.lo != 0.0 or squared_box.im.hi != 0.0) {
        try report.line(
            "FAIL i*i-imaginary-part: [{d}, {d}], want exactly [0, 0]\n",
            .{ squared_box.im.lo, squared_box.im.hi },
        );
        return CheckError.UnexpectedIntervalValue;
    }
    try report.line("ok i*i-imaginary-part: exactly [0, 0]\n", .{});

    // The logarithm of one is zero on the principal sheet, and every other
    // sheet is that zero plus 2*pi*i*k. Sheets -1, 0 and 1 are selected
    // EXPLICITLY, and the answer carries one piece per selected sheet with
    // its own label, so a caller that asked for three can tell which is
    // which. The exact value 2*pi is not an f64, so the off-zero sheets are
    // checked by SIGN rather than by a pinned width: the negative sheet's
    // imaginary box lies below zero and the positive one's above it, and
    // that is the whole of what distinguishes k = -1 from k = +1.
    var log_pieces: [4]interval.branches.Piece(interval.Complex) = undefined;
    var log_pool: [16]interval.branches.Assignment = undefined;
    var log_in: [1]interval.branches.Piece(interval.Complex) = undefined;
    log_in[0] = .{
        .value = interval.Complex.point(1.0, 0.0),
        .assignments = &.{},
    };
    var log_writer = interval.branches.Writer(interval.Complex).init(
        log_pieces[0..],
        log_pool[0..],
    );
    const sheets = [_]i64{ -1, 0, 1 };
    const logarithms = try interval.complex.logSheets(
        &log_writer,
        .{ .pieces = log_in[0..] },
        11,
        sheets[0..],
    );
    if (logarithms.pieces.len != sheets.len) {
        try report.line(
            "FAIL log-sheets: got {d} pieces, want {d}\n",
            .{ logarithms.pieces.len, sheets.len },
        );
        return CheckError.UnexpectedIntervalValue;
    }
    // Each sheet's real part is 0: log(1) is 0 and adding 2*pi*i*k does
    // not move the real part. That is checked on every sheet rather than
    // on one, because a sheet-index bug that also moved the real part
    // would otherwise be caught by nothing.
    for (logarithms.pieces, 0..) |piece, idx| {
        const sheet_box = try complexRange(report, "log-sheets", piece.value);
        if (!sheet_box.re.contains(0.0)) {
            try report.line(
                "FAIL log-sheet-real-part: [{d}, {d}] does not contain 0\n",
                .{ sheet_box.re.lo, sheet_box.re.hi },
            );
            return CheckError.UnexpectedIntervalValue;
        }
        switch (idx) {
            0 => {
                // k = -1: the imaginary part is -2*pi, so the box lies
                // strictly below zero.
                if (sheet_box.im.hi > 0.0) {
                    try report.line(
                        "FAIL log-sheet-minus-one: imaginary part reaches {d}, want negative\n",
                        .{sheet_box.im.hi},
                    );
                    return CheckError.UnexpectedIntervalValue;
                }
                try report.line("ok log-sheet-minus-one: imaginary part below 0\n", .{});
            },
            1 => {
                // k = 0: the principal sheet, and log(1) is EXACTLY zero.
                if (sheet_box.im.lo != 0.0 or sheet_box.im.hi != 0.0) {
                    try report.line(
                        "FAIL log-sheet-zero: imaginary part [{d}, {d}], want [0, 0]\n",
                        .{ sheet_box.im.lo, sheet_box.im.hi },
                    );
                    return CheckError.UnexpectedIntervalValue;
                }
                try report.line("ok log-sheet-zero: imaginary part exactly [0, 0]\n", .{});
            },
            else => {
                // k = +1: the imaginary part is +2*pi, strictly above zero.
                if (sheet_box.im.lo < 0.0) {
                    try report.line(
                        "FAIL log-sheet-plus-one: imaginary part reaches {d}, want positive\n",
                        .{sheet_box.im.lo},
                    );
                    return CheckError.UnexpectedIntervalValue;
                }
                try report.line("ok log-sheet-plus-one: imaginary part above 0\n", .{});
            },
        }
    }

    try report.line("consumer ok: {d} checks\n", .{total_checks});
}

pub fn main(init: std.process.Init) !void {
    // SAFETY: the writer fills the buffer before reading any of it back, and
    // nothing outside this scope can observe it: `Report.line` flushes on
    // every call, so no byte is left buffered when this function returns.
    var buffer: [4096]u8 = undefined;
    const stderr = std.Io.File.stderr().writerStreaming(init.io, &buffer);
    var report: Report = .{ .stderr = stderr };

    // No `defer` and no flush here: every line was flushed as it was written,
    // so a run that stops at a check has already published the line that
    // says which one, and a run that panics has published the lines before
    // it. Propagating the error is all that is left to do.
    try run(&report);
}
