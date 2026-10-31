//! The directed sweep at the ends of the range. The random layer screens
//! every non-finite operand out before its oracle sees one, so it judged the
//! library on finite inputs and reached an infinity in none of its thirty-five
//! sweeps; this file is the half that does. Its shapes are NAMED rather than
//! drawn — six rays and half-lines, the whole line, seven finite boxes beside
//! them, and the two pairs the constructor refuses — and every reference is
//! built from what an infinite endpoint STANDS FOR rather than from the
//! corner the library computed.
//!
//! THIRTEEN operations are judged this way and none is withheld. A withheld
//! row is a row whose expected answer this file had to choose for itself,
//! and a reference chosen by the judge is not a reference; that is what the
//! six removed ones were, and the two readings of an infinite endpoint
//! disagreed about exactly those six.
//!
//! `Range`, `Span` and `End` live in `soundness_shared.zig` for the reason
//! its header gives: the finite sweep reads the same two, and so do the
//! guard tests at the end of this file. What is here is the shapes, the
//! canonical reading of an infinite endpoint, the thirteen references built
//! from it, the row classifier that decides which rows the callers DECLARE
//! they refuse, and the sweeps that drive them.
const shared = @import("soundness_shared.zig");

const std = shared.std;
const interval = shared.interval;
const Interval = shared.Interval;

const Case = shared.Case;
const End = shared.End;
const Op = shared.Op;
const Range = shared.Range;
const Ray = shared.Ray;
const ScaleBound = shared.ScaleBound;
const Span = shared.Span;
const Tally = shared.Tally;
const Value = shared.Value;

const apply = shared.apply;
const boundedScaleHolds = shared.boundedScaleHolds;
const exactDistanceTo = shared.exactDistanceTo;
const exactWidth = shared.exactWidth;
const ex = shared.ex;
const hiEncloses = shared.hiEncloses;
const holds = shared.holds;
const inf128 = shared.inf128;
const inf64 = shared.inf64;
const loEncloses = shared.loEncloses;
const lowerOk = shared.lowerOk;
const marginAdmissible = shared.marginAdmissible;
const max_detail = shared.max_detail;
const maybeMatches = shared.maybeMatches;
const min_subnormal = shared.min_subnormal;
const neg_inf128 = shared.neg_inf128;
const neg_inf64 = shared.neg_inf64;
const quotientHolds = shared.quotientHolds;
const reportErr = shared.reportErr;
const showCase = shared.showCase;
const sumGeq = shared.sumGeq;
const sumLeq = shared.sumLeq;
const summary = shared.summary;
const twoSum = shared.twoSum;
const upperOk = shared.upperOk;

// ---------------------------------------------------------------------------
// The frontier sweep
// ---------------------------------------------------------------------------

// The random layer, in `soundness_fuzz_test.zig`, draws its operands from a
// table of MAGNITUDES and screens a non-finite one out before the oracle
// sees it, so 35 sweeps of 8,000 cases each judged the library on finite
// inputs and not one of them reached an infinity. The only infinity coverage
// the tree had before this section was `lo <= hi`, which asks nothing of
// the answer, so the shapes here are directed rather than drawn and the
// count is a couple of thousand rows rather than another eight thousand
// per operation.
//
// What an infinite endpoint STANDS FOR is fixed by the approved contract
// rather than chosen here, which is the whole reason this section can judge
// thirteen operations instead of seven. A canonical `lo` is never `+inf` and
// a canonical `hi` is never `-inf`, so `init(+inf,+inf)` is the closed
// overflow ray `[floatMax,+inf]` and its mirror `[-inf,-floatMax]`, a finite
// bound is an attained real, and an infinite one is a direction the set runs
// off in. That is the same UNBOUNDED MAGNITUDE reading `rounding.zig` and
// `src/interval.zig` already stated, and the only thing that changed is that
// it is no longer a question this file has an opinion about.
//
// Every reference below is the true image of that set. An attained end is
// formed in `f128` from the CLOSED end of each ray — floatMax for `+inf`,
// -floatMax for `-inf` — and the directions the image runs off in are
// carried beside it. Two exactness rules follow from the rest of this file
// rather than from anything new:
//
//   * An end that is a SUM of two `f64`s is held as its two operands and
//     compared through the TwoSum residual. `floatMax - 3` is the case that
//     needs every one of the 971 binades between the two operands, and
//     `f128` carries 113 significand bits, so it rounds to its larger
//     operand. (`2 * floatMax` is the other sum that shows up here and it is
//     NOT in the same position: doubling moves the exponent and not the
//     significand, so `2 * floatMax` is exactly an `f128`.)
//   * An attained end that has left the `f64` range sets the matching
//     `_beyond` flag on the `Range`, which is the only thing in this file
//     that sets either. The extremum there is a real rather than an
//     infinity, so the saturated `f64` at the frontier bounds it and an
//     infinity pointing the other way does not.

/// The directed operand shapes, named as endpoint pairs rather than as
/// intervals, because two of them are not intervals. `Interval.init`
/// requires lo <= hi and traps on a pair that breaks it, which is the
/// library's refusal and is recorded rather than worked around.
///
/// SEVEN of the sixteen are wholly finite, and they are here for a reason
/// that has nothing to do with infinity: a sweep made only of rays pairs
/// every operand with an unbounded one, so the finite corner of `div`,
/// `mul`, `hull` and `intersect` is never the operand that decides the
/// answer, and `scale`'s centre and identity cases are unreachable because
/// every operand there has no centre at all. A frontier sweep that cannot
/// reach a finite quotient has not reached the frontier of anything.
///
/// The ORDER is deliberate and the report counts it. The finite shapes come
/// first, then the half-lines, then the degenerate rays, and the whole line
/// last. An operation that aborts on one of the shapes at the end takes the
/// whole test binary with it, so the shapes most likely to abort are the
/// ones whose rows are gathered after everything else has been judged.
const Shape = enum {
    /// [3, 3]: a finite point, so a quotient corner and a scale centre
    /// both have somewhere finite to be.
    point_finite,
    /// [1, 2]: the narrowest non-degenerate finite box there is.
    narrow,
    /// [-3, -1]: wholly below zero, which the sign reasoning has to
    /// separate from a box that reaches it.
    all_neg,
    /// [-1, 1]: finite and straddling zero, so the zero floor of `abs` and
    /// `sqr` and the whole-line answer of a zero-reaching divisor are both
    /// reached by a FINITE box rather than only by a ray.
    straddle,
    /// [0, 0]: the point zero itself.
    origin,
    /// [-floatMax, floatMax]: the widest BOUNDED interval there is. It is
    /// the shape `expand(-inf)` is refused for, and the only one where a
    /// finite margin of -floatMax is admissible.
    wide,
    /// [min_subnormal, 4*min_subnormal]: a wholly finite subnormal box,
    /// where a quotient corner is a value `f64` cannot hold and the repair
    /// has to answer for it.
    subnormal,
    /// [3, inf]: a ray running out past floatMax from a finite end.
    up_finite,
    /// [-inf, 3]: the same from below.
    low_finite,
    /// [-inf, -3]: a ray with no zero anywhere in it, which is the shape a
    /// quotient's sign reasoning has to separate from `low_finite`.
    down_finite,
    /// [-3, inf]: the ray that spans zero as it runs out.
    spanning_up,
    /// [inf, inf]: the canonical constructor's positive overflow ray.
    pos_point,
    /// [-inf, -inf]: its negative mirror.
    neg_point,
    /// [-inf, inf]: the whole line, against itself and against every shape.
    line,
    /// {inf, -inf}: lo > hi, so not an interval.
    inverted_ends,
    /// {3, -inf}: the same refusal with a finite end in it.
    inverted_finite,

    fn label(s: Shape) []const u8 {
        return switch (s) {
            .point_finite => "[3,3]",
            .narrow => "[1,2]",
            .all_neg => "[-3,-1]",
            .straddle => "[-1,1]",
            .origin => "[0,0]",
            .wide => "[-floatMax,floatMax]",
            .subnormal => "[min_subnormal,4*min_subnormal]",
            .up_finite => "[3,inf]",
            .low_finite => "[-inf,3]",
            .down_finite => "[-inf,-3]",
            .spanning_up => "[-3,inf]",
            .pos_point => "[inf,inf]",
            .neg_point => "[-inf,-inf]",
            .line => "[-inf,inf]",
            .inverted_ends => "{inf,-inf}",
            .inverted_finite => "{3,-inf}",
        };
    }

    fn ends(s: Shape) [2]f64 {
        return switch (s) {
            .point_finite => .{ 3.0, 3.0 },
            .narrow => .{ 1.0, 2.0 },
            .all_neg => .{ -3.0, -1.0 },
            .straddle => .{ -1.0, 1.0 },
            .origin => .{ 0.0, 0.0 },
            .wide => .{ -std.math.floatMax(f64), std.math.floatMax(f64) },
            .subnormal => .{ min_subnormal, 4.0 * min_subnormal },
            .up_finite => .{ 3.0, inf64 },
            .low_finite => .{ neg_inf64, 3.0 },
            .down_finite => .{ neg_inf64, -3.0 },
            .spanning_up => .{ -3.0, inf64 },
            .pos_point => .{ inf64, inf64 },
            .neg_point => .{ neg_inf64, neg_inf64 },
            .line => .{ neg_inf64, inf64 },
            .inverted_ends => .{ inf64, neg_inf64 },
            .inverted_finite => .{ 3.0, neg_inf64 },
        };
    }

    /// The two endpoints as an interval, which is only meaningful for a shape
    /// that `ordered` accepts.
    ///
    /// This is what a CALLER WRITES — `Interval.init(inf, inf)` and no
    /// normalisation on this side — and it has to stay that way. The
    /// contract says `init(+inf,+inf)` supplies the closed overflow ray, and
    /// a test that supplied the ray itself would be testing the sweep rather
    /// than the constructor: `abs`, `neg`, `mul` and the rest would be green
    /// against a tree whose `init` still hands back a degenerate point at
    /// `+inf`, and the six operations the old table withheld would stay
    /// unjudged in a quieter way than before. The operand is therefore built
    /// here and the canonical reading is derived in `canonical`, which never
    /// looks at what `init` returned.
    fn interval(s: Shape) Interval {
        return Interval.init(s.ends()[0], s.ends()[1]);
    }

    /// What the contract says this shape IS, as the closed ends it attains
    /// and the two directions it runs off in.
    ///
    /// Derived from the shape's DECLARED ends and never from the interval
    /// `init` handed back. That independence is the whole of the design: an
    /// oracle built from the operand reads the implementation's answer back
    /// to itself, and a sweep whose references move with the code under test
    /// cannot go red.
    fn canonical(s: Shape) Canonical {
        const e = s.ends();
        return .{
            .lo = closedEnd(e[0]),
            .hi = closedEnd(e[1]),
            .lo_unbounded = e[0] == neg_inf64,
            .hi_unbounded = e[1] == inf64,
        };
    }

    /// False for the two shapes `Interval.init` refuses.
    fn ordered(s: Shape) bool {
        return switch (s) {
            .inverted_ends, .inverted_finite => false,
            else => true,
        };
    }

    /// True when either end runs off to an infinity, so the box has no
    /// finite midpoint and `scale`'s documented affine formula has nothing
    /// to evaluate. This replaces the old `both_open`, which asked the same
    /// question for the wrong subset and was the reason three shapes were
    /// skipped: a box with ONE unbounded end has no finite midpoint
    /// either, so skipping only the two-ended ones decided nothing.
    fn unbounded(s: Shape) bool {
        const e = s.ends();
        return e[0] == neg_inf64 or e[1] == inf64;
    }

    /// Whether `expand` would accept `margin` on this bounded shape, decided
    /// on the exact real rather than on a rounded width.
    ///
    /// The old shape of this question compared against `(hi - lo) / 2` as one
    /// `f128`, and that is not the width: `floatMax - min_subnormal` rounds
    /// to `floatMax` in `f128` just as it does in `f64`, so a margin decided
    /// that way can be one that the operation does not accept. The width is
    /// never formed here either — `marginAdmissible` decides the inequality.
    fn admitsMargin(s: Shape, margin: f64) bool {
        const e = s.ends();
        return marginAdmissible(closedEnd(e[0]), closedEnd(e[1]), margin);
    }
};

/// Every shape, in the order `Shape` documents: the finite ones first, the
/// half-lines, then the degenerate rays, and the whole line last.
const frontier_shapes = [_]Shape{
    .point_finite,
    .narrow,
    .all_neg,
    .straddle,
    .origin,
    .wide,
    .subnormal,
    .up_finite,
    .low_finite,
    .down_finite,
    .spanning_up,
    .pos_point,
    .neg_point,
    .line,
    .inverted_ends,
    .inverted_finite,
};

/// The scalars the frontier carries through the same shapes.
///
/// Zero and the two units are here because `scale`'s contract turns on
/// them: a factor of zero is the centre case and |factor| = 1 is the
/// identity case, and neither is reachable if the only finite scalars are
/// 3 and -3. The two of opposite large sign are the shift-by-the-wrong-sign
/// case, and the two infinite ones are where a shift or a widening stops
/// being an arithmetic operation at all.
const frontier_scalars = [_]f64{ 0.0, 1.0, -1.0, 3.0, -3.0, inf64, neg_inf64 };

/// The closed end of the ray an endpoint stands for, as an `f64`: floatMax
/// for `+inf`, -floatMax for `-inf`, and the value itself otherwise.
fn closedEnd(x: f64) f64 {
    if (x == inf64) return std.math.floatMax(f64);
    if (x == neg_inf64) return -std.math.floatMax(f64);
    return x;
}

/// What a frontier shape IS under the approved contract, as the two ends it
/// attains and the two directions it runs off in.
///
/// The attained ends are the CLOSED ends of the rays — floatMax for a `+inf`
/// end, -floatMax for a `-inf` one — because a canonical `lo` is never `+inf`
/// and a canonical `hi` is never `-inf`, so `init(+inf,+inf)` is the closed
/// overflow ray `[floatMax,+inf]` and its mirror is `[-inf,-floatMax]`. The
/// two flags say which of the two ends is a direction rather than a value.
///
/// This type is what keeps the oracle independent: it is built from a
/// shape's DECLARED ends, and no reference below ever reads an interval
/// `Interval.init` returned.
const Canonical = struct {
    /// The real the low end attains, or the closed end of the ray it runs
    /// off below from. Meaningful only when `lo_unbounded` is false.
    lo: f64,
    /// The mirror for the high end.
    hi: f64,
    lo_unbounded: bool,
    hi_unbounded: bool,

    /// Whether the SET these canonical ends denote contains zero. BOTH ends
    /// decide it, not the low one alone: `[-3,-1]` has a low end below zero
    /// and does not reach it, and reading only the low end makes the whole
    /// negative quadrant look like a divisor that straddles zero.
    ///
    /// An unbounded end carries the infinity it runs off to, so comparing
    /// the stored `lo` and `hi` against zero already answers the ray cases:
    /// `[-inf, -3]` compares as `-inf <= 0` and `-3 >= 0`, which is false,
    /// and `[-inf, 3]` is true, which is right.
    fn reachesZero(c: Canonical) bool {
        return c.lo <= 0.0 and c.hi >= 0.0;
    }
};

/// The reflection of a canonical set, with the two directions swapping as
/// well as the two ends: a ray running off below reflects to one running
/// off above. Reflecting the ends alone would turn the whole line into the
/// point `floatMax`, which is the bug the contract's `neg` line exists to
/// prevent and the one the removed bit-pattern test used to pin.
fn negated(c: Canonical) Canonical {
    return .{
        .lo = -c.hi,
        .hi = -c.lo,
        .lo_unbounded = c.hi_unbounded,
        .hi_unbounded = c.lo_unbounded,
    };
}

/// The canonical set as the `Range` the enclosure rules read: an unbounded
/// end becomes the infinity, and an attained end that has left the `f64`
/// range sets the flag saying so.
fn range(c: Canonical) Range {
    const fmax = ex(std.math.floatMax(f64));
    return .{
        .lo = if (c.lo_unbounded) neg_inf128 else ex(c.lo),
        .hi = if (c.hi_unbounded) inf128 else ex(c.hi),
        .lo_beyond = !c.lo_unbounded and ex(c.lo) > fmax,
        .hi_beyond = !c.hi_unbounded and ex(c.hi) < -fmax,
    };
}

/// The low end of a set as an `f128`, with an unbounded one as -inf. The
/// single place the two are combined, so `hull` and `intersect` cannot
/// disagree about what an open end is worth.
fn lowOf(c: Canonical) f128 {
    return if (c.lo_unbounded) neg_inf128 else ex(c.lo);
}

/// The mirror of `lowOf` for the high end.
fn highOf(c: Canonical) f128 {
    return if (c.hi_unbounded) inf128 else ex(c.hi);
}

/// The two endpoints of a canonical operand as the SETS they stand for: the
/// attained end as a point, and an open end as a ray running out from the
/// closed end. This is the only place a frontier operand is read as a set,
/// and it is the whole of what the `+inf` reading costs: `[inf,inf]` is a
/// ray out of floatMax and not a point at `+inf`.
fn canonicalEnds(c: Canonical) [2]End {
    return .{
        if (c.lo_unbounded) .{ .ray = .{ .c = neg_inf128, .up = false } } else .{ .value = ex(c.lo) },
        if (c.hi_unbounded) .{ .ray = .{ .c = inf128, .up = true } } else .{ .value = ex(c.hi) },
    };
}

/// The true image of `a * b`: the hull of the four corner SETS. Taking the
/// hull of the sets and not of four numbers is the whole of the difference
/// at an infinity — a corner pair of rays has no value to take the min of,
/// it has a ray, and the positive overflow ray times `[3,inf)` is
/// `[floatMax^2, inf)` rather than a single point at either end of it.
fn frontierMul(a: Canonical, b: Canonical) Range {
    const ae = canonicalEnds(a);
    const be = canonicalEnds(b);
    // The first corner rather than the whole line. `Span`'s default is the
    // whole line, which is the right answer for an image nothing bounds and
    // the wrong IDENTITY for a hull, because it swallows the first corner
    // and turns every product back into the line.
    var out = productSet(ae[0], be[0]);
    for (ae) |x| {
        for (be) |y| {
            out = Span.hull(out, productSet(x, y));
        }
    }
    return out.range();
}

/// One corner of a product as a set. Two endpoints are each a point or a ray,
/// and the product of any two of them is a point or a ray: a nonzero value
/// stretches a ray in its own direction and a second ray reverses it exactly
/// when the two disagree.
///
/// The one collapse is a zero factor, and it is the same exception
/// `src/interval.zig` makes in cornerProduct for the same reason: zero times
/// an unbounded magnitude is zero, and no unboundedness in the other factor
/// reaches past that. It is a fact about reals, which is why it survives
/// being a value IEEE declines to compute.
fn productSet(p: End, q: End) Span {
    if ((p == .value and p.value == 0.0) or (q == .value and q.value == 0.0)) return Span.point(0.0);
    return switch (p) {
        .value => |px| switch (q) {
            .value => |qy| Span.point(px * qy),
            .ray => |r| stretched(px, r),
        },
        .ray => |r| switch (q) {
            .value => |qy| stretched(qy, r),
            .ray => |s| Span.ray(r.c * s.c, r.up == s.up),
        },
    };
}

/// A nonzero value times a ray: the ray scaled, running the way the sign of
/// the value sends it. A zero value is the collapse and is ruled out by the
/// caller, because a bound here has no direction to point.
fn stretched(v: f128, r: Ray) Span {
    return Span.ray(v * r.c, if (v > 0.0) r.up else !r.up);
}

/// The true image of `abs` and of `sqr`: both are magnitude maps, so an
/// infinite endpoint is an unbounded MAGNITUDE rather than a value, and the
/// image runs off to +inf exactly when an end does.
///
/// The ray is added only in that case, and that condition is the whole of a
/// bug the finite frontier shapes caught. Unconditionally unioning a
/// `+inf` ray is right for every shape that HAS an infinite end and wrong
/// for every shape that does not: it asks `abs([3,3])` to enclose
/// `[3, +inf)`, and the true image of a bounded box under a magnitude map
/// is bounded. The old version was never wrong only because every shape it
/// met had an infinite end, which is the same reason a sweep of nothing but
/// rays finds nothing else either.
///
/// The attained end is the smaller of the two attained magnitudes, or
/// exactly zero where the operand spans it — the zero floor, since a point
/// of the operand maps to zero itself and no bound above it can be tighter.
fn frontierMagnitude(a: Canonical, p: f128, q: f128) Range {
    // Both ends, and an unbounded end carries the infinity it runs off to,
    // so `[-inf, -3]` compares as `-inf <= 0` against `-3 >= 0` and answers
    // false. Oring in `a.lo_unbounded` instead called that box zero-spanning:
    // it has an unbounded MAGNITUDE, not a zero, and the false floor put 0
    // under `abs([-inf,-3])`, whose true image is `[3, +inf)`.
    const spans_zero = a.lo <= 0.0 and a.hi >= 0.0;
    const attained = Span.point(if (spans_zero) 0.0 else @min(p, q));
    if (!a.lo_unbounded and !a.hi_unbounded) return attained.range();
    return Span.hull(attained, Span.ray(@max(p, q), true)).range();
}

fn frontierAbs(a: Canonical) Range {
    return frontierMagnitude(a, @abs(ex(a.lo)), @abs(ex(a.hi)));
}

/// The true image of `sqr`: the same two attained magnitudes, squared
/// rather than taken, and the same zero floor on an operand that spans
/// zero. The two squares of `f64` endpoints need 106 significand bits and
/// `f128` carries 113, so they are the true squares.
fn frontierSqr(a: Canonical) Range {
    return frontierMagnitude(a, ex(a.lo) * ex(a.lo), ex(a.hi) * ex(a.hi));
}

/// Containment of the quotient set at the frontier, by the same
/// cross-multiplication the finite sweep uses and for the same reason: a
/// quotient is not exact even in `f128`, so no quotient is ever evaluated
/// here either.
///
/// Every requirement below is either an infinity or a cross-product of two
/// `f64`s, and both are exact. What the old version of this function did
/// NOT do is account for the direction a ray runs in: it read an infinite
/// divisor end at its closed value and stopped, which accepts a bound that
/// stops short of the zero the true quotient set accumulates at. The rules
/// are these, and each one is a statement about reals.
///
///   * A divisor that REACHES zero has a quotient set unbounded on both
///     sides, so the answer has to be the whole line. That is also the
///     answer `div` documents, which makes it a contract value rather than
///     a precondition. A divisor of exactly zero has NO quotient at all —
///     the image is empty and every interval encloses it.
///   * A divisor end that RUNS OFF sends the quotient to zero, from
///     whichever side the dividend is on, so the set has zero as an
///     accumulation point and the answer has to reach it: `got.lo <= 0`
///     and `got.hi >= 0`. `1 / inf` is zero in IEEE while the true
///     quotient of a finite number by an unbounded one is a ray with that
///     zero as its infimum, which is the distinction this rule exists for.
///   * A dividend end that RUNS OFF takes the quotient off with it, in the
///     direction the divisor's sign sends it, so that side of the answer
///     has to be the matching infinity.
///   * Every corner where BOTH ends are ATTAINED is checked by
///     `quotientHolds`, unchanged. A corner where either end is a ray is
///     already covered by the two rules above, and feeding a ray into
///     `quotientHolds` would ask for the wrong thing: it demands an
///     infinite bound where a ray only demands zero.
fn frontierQuotientHolds(num: Canonical, den: Canonical, got: Interval) bool {
    if (std.math.isNan(got.lo) or std.math.isNan(got.hi)) return false;
    if (got.lo > got.hi) return false;
    // The empty set: the divisor has no non-zero member, so there is no
    // quotient to enclose and nothing is required.
    if (!den.lo_unbounded and !den.hi_unbounded and den.lo == 0.0 and den.hi == 0.0) return true;
    if (den.reachesZero()) return got.lo == neg_inf64 and got.hi == inf64;
    // A divisor wholly above zero, or wholly below it. The sign is what
    // sends a dividend's ray to one infinity rather than the other.
    const up = den.lo > 0.0;
    if (num.hi_unbounded) {
        if (up) {
            if (got.hi != inf64) return false;
        } else if (got.lo != neg_inf64) return false;
    }
    if (num.lo_unbounded) {
        if (up) {
            if (got.lo != neg_inf64) return false;
        } else if (got.hi != inf64) return false;
    }
    if (den.hi_unbounded and got.lo > 0.0) return false;
    if (den.lo_unbounded and got.hi < 0.0) return false;
    // The corners where BOTH ends are attained, and only those. `Canonical`
    // leaves an unbounded end's value in place but flagged, so the loop
    // skips a flagged end: a ray corner has no real to cross-multiply, and
    // the two rules above already say exactly what it requires.
    for ([_]f64{ num.lo, num.hi }, [_]bool{ num.lo_unbounded, num.hi_unbounded }) |x, x_ray| {
        if (x_ray) continue;
        for ([_]f64{ den.lo, den.hi }, [_]bool{ den.lo_unbounded, den.hi_unbounded }) |y, y_ray| {
            if (y_ray or y == 0.0) continue;
            if (!quotientHolds(x, y, got)) return false;
        }
    }
    return true;
}

/// The `scale` reference for an UNBOUNDED input, which is where the
/// documented formula `M = (lo + hi) / 2` stops deciding anything: with one
/// end running off there is no finite midpoint, and with both there never
/// was one. The approved contract settles it by the factor alone.
///
///   * `|factor| == 1` is the identity for every centre, so the image is
///     the operand and the answer has to BE the operand. Containment would
///     be the weaker check and it is refused on purpose: the whole line
///     encloses the operand, so a containment rule here would pass an
///     answer that gives up on the one case the factor fully decides.
///   * every other factor returns the whole line, the contract's own
///     conservative answer. `m + g (x - m)` runs off with `x` and comes
///     back the other way if it comes back at all, so the line encloses
///     the image for every centre a caller might have meant, and a factor
///     of zero is included in that rather than special-cased: the centre it
///     would return does not exist.
fn unboundedScaleHolds(a: Canonical, factor: f64, got: Interval) bool {
    if (@abs(ex(factor)) != 1.0) return got.lo == neg_inf64 and got.hi == inf64;
    // The identity, so the answer has to BE the operand — read as the set
    // the contract defines rather than as the pair of `f64` the caller
    // happened to write, so that a constructor which normalises
    // `[floatMax,+inf]` and one which leaves `{inf,inf}` are told apart.
    if (std.math.isNan(got.lo) or std.math.isNan(got.hi)) return false;
    if (got.lo > got.hi) return false;
    if (a.lo_unbounded) {
        if (got.lo != neg_inf64) return false;
    } else if (got.lo != a.lo) return false;
    if (a.hi_unbounded) {
        if (got.hi != inf64) return false;
    } else if (got.hi != a.hi) return false;
    return true;
}

/// The exact image of an operation whose two ends are each the SUM of two
/// frontier operand ends.
///
/// The two `f64` operands of each end are kept apart from the two flags
/// saying whether that end runs off, because an end that runs off has no
/// attained extremum to compare against at all: it is the whole ray, and
/// only the matching infinity encloses it. An attained end is a sum of two
/// `f64`s and goes through the residual comparator, for the reason the header
/// gives: `floatMax - 3` is a real no `f128` can name and it rounds to
/// `floatMax`, which is a real `f128` can name and which is therefore a
/// perfectly wrong answer to compare against.
const FrontierSum = struct {
    alo: f64,
    blo: f64,
    ahi: f64,
    bhi: f64,
    /// True when the image runs off to -inf, so `lo` must be -inf.
    lo_unbounded: bool,
    /// True when the image runs off to +inf, so `hi` must be +inf.
    hi_unbounded: bool,

    fn lowerOk(f: FrontierSum, glo: f64) bool {
        if (std.math.isNan(glo)) return false;
        if (f.lo_unbounded) return glo == neg_inf64;
        return sumLeq(glo, f.alo, f.blo);
    }

    fn upperOk(f: FrontierSum, ghi: f64) bool {
        if (std.math.isNan(ghi)) return false;
        if (f.hi_unbounded) return ghi == inf64;
        return sumGeq(ghi, f.ahi, f.bhi);
    }

    fn holds(f: FrontierSum, got: Interval) bool {
        if (got.lo > got.hi) return false;
        return f.lowerOk(got.lo) and f.upperOk(got.hi);
    }
};

/// The frontier image of `a + b`.
///
/// Addition never cancels, so the image runs off below exactly when one of
/// the two lower ends does and off above exactly when one of the two upper
/// ends does. The two rays of opposite sign meet and the sum is the whole
/// line, which is a fact about addition and not an accident of the
/// operands: the positive overflow ray plus the negative one reaches every
/// real, because one side has no lower bound and the other has no upper one.
fn frontierAdd(a: Canonical, b: Canonical) FrontierSum {
    return .{
        .alo = a.lo,
        .blo = b.lo,
        .ahi = a.hi,
        .bhi = b.hi,
        .lo_unbounded = a.lo_unbounded or b.lo_unbounded,
        .hi_unbounded = a.hi_unbounded or b.hi_unbounded,
    };
}

/// The frontier image of `a - b`, which is the reflected sum: the low end
/// takes `a.lo` against `b.hi` and the high one `a.hi` against `b.lo`.
///
/// The reflection is the whole of it, and it is what the old witness got
/// backwards. A `-inf` and a `+inf` are on OPPOSITE sides of a subtraction,
/// so they cannot cancel: an attained low end against a ray running off
/// below is `-inf`, not a number, and an attained low end CANNOT be
/// `+inf` — which is exactly what a canonical `[floatMax,+inf]` fixes. The
/// same-ray row is therefore the whole line, and it is the row that used to
/// abort.
fn frontierSub(a: Canonical, b: Canonical) FrontierSum {
    return .{
        .alo = a.lo,
        .blo = -b.hi,
        .ahi = a.hi,
        .bhi = -b.lo,
        .lo_unbounded = a.lo_unbounded or b.hi_unbounded,
        .hi_unbounded = a.hi_unbounded or b.lo_unbounded,
    };
}

/// The canonical reading of a scalar: the point it is when it is finite, and
/// the closed overflow ray when it is not. This is what `translate` and
/// `expand` see at an infinite delta or margin — the two endpoints of the
/// ray, not the infinity as a numeric point.
fn scalarRay(x: f64) Canonical {
    return .{
        .lo = closedEnd(x),
        .hi = closedEnd(x),
        .lo_unbounded = x == neg_inf64,
        .hi_unbounded = x == inf64,
    };
}

/// The frontier image of a shift, which is the contract's own definition of
/// it: `add` against the canonical overflow ray an infinite delta stands
/// for.
fn frontierTranslate(a: Canonical, delta: f64) FrontierSum {
    return frontierAdd(a, scalarRay(delta));
}

/// The frontier image of a widening by `margin`.
///
/// A positive ray margin is the whole line, which is both what the contract
/// says and the only thing the set says: widening by every finite positive
/// margin fills the line. A negative ray margin is the union over every
/// real margin at or below -floatMax, and that union is the attained ends
/// pulled together by that last margin. A negative margin CONTRACTS rather
/// than widens: `expand` computes `[lo - margin, hi + margin]`, so its two
/// ends move toward each other, and the row below reads the margin in that
/// form throughout. The single admissible margin is NOT clipped out of the
/// ray, because an answer covering only -floatMax would leave out every
/// margin below it. For a BOUNDED input the row never reaches here: the
/// documented width precondition refuses every margin in the ray, and
/// `classifyRow` says so by name.
fn frontierExpand(a: Canonical, margin: f64) FrontierSum {
    if (margin == inf64) {
        return .{
            .alo = 0.0,
            .blo = 0.0,
            .ahi = 0.0,
            .bhi = 0.0,
            .lo_unbounded = true,
            .hi_unbounded = true,
        };
    }
    // The margin in `[lo - far, hi + far]` form. A finite margin is itself.
    // The `-inf` ray is every margin at or below `-floatMax`, and the union
    // over it runs out at the LAST of them, the one that opens the image
    // furthest — so the ray is represented by `-floatMax` and NOT by its
    // magnitude. Taking the magnitude is the sign this row used to carry,
    // and it widened the box where `expand` contracts it: it judged
    // `expand([3, +inf), -inf)` against `[-floatMax, +inf]` when the union
    // over the ray is `[3 + floatMax, +inf)`.
    const far = if (margin == neg_inf64) -std.math.floatMax(f64) else margin;
    return .{
        .alo = a.lo,
        .blo = -far,
        .ahi = a.hi,
        .bhi = far,
        .lo_unbounded = a.lo_unbounded,
        .hi_unbounded = a.hi_unbounded,
    };
}

/// The frontier sum reference of `op`, for the four operations whose image
/// ends are each a sum of two operand ends. Null for every other operation.
fn frontierSum(op: Op, a: Canonical, b: Canonical, s: f64) ?FrontierSum {
    return switch (op) {
        .add => frontierAdd(a, b),
        .sub => frontierSub(a, b),
        .translate => frontierTranslate(a, s),
        .expand => frontierExpand(a, s),
        else => null,
    };
}

/// The frontier reference of an operation whose image is a `Range`, or null
/// where the reference is a residual comparison, a cross-multiplication or
/// the identity-or-whole-line rule instead.
fn frontierReference(op: Op, a: Canonical, b: Canonical, _: f64) ?Range {
    return switch (op) {
        .mul => frontierMul(a, b),
        .abs => frontierAbs(a),
        .sqr => frontierSqr(a),
        // The reflection, with the two directions swapping as well as the
        // two ends. This is the ordinary reflected ray the contract fixes:
        // the positive overflow ray reflects to the negative one, and the
        // degenerate box a constructor that does not normalise would hand
        // back is not an enclosure of it.
        .neg => range(negated(a)),
        .hull => .{
            .lo = @min(lowOf(a), lowOf(b)),
            .hi = @max(highOf(a), highOf(b)),
        },
        .intersect => blk: {
            const lo = @max(lowOf(a), lowOf(b));
            const hi = @min(highOf(a), highOf(b));
            if (lo > hi) break :blk null;
            break :blk Range{ .lo = lo, .hi = hi };
        },
        .add, .sub, .translate, .expand, .div, .recip, .scale => null,
        else => null,
    };
}

/// The frontier reference of an operation, named in every failure report
/// for the reason `Op.oracle` gives for the finite sweep.
fn frontierOracle(op: Op) []const u8 {
    return switch (op) {
        .add => "the sum of the two attained closed ends, held as its two f64 operands and judged through the" ++
            "TwoSum residual, with the image running off below or above exactly when one of the two ends of an" ++
            "operand does",
        .sub => "the crossed corner sums of the attained closed ends, held as their two f64 operands and judged" ++
            "through the TwoSum residual; rays of opposite sign cannot cancel, and the same ray cancels to the whole" ++
            "line",
        .translate => "the reference add gives, against the canonical overflow ray an infinite delta stands for" ++
            "rather than the infinity as a point",
        .expand => "the whole line at a positive ray margin, and at a negative ray margin the union over every real" ++
            "margin at or below -floatMax, which is the attained closed ends pushed apart by exactly floatMax",
        .neg => "the reflected canonical ray, the ends swapping so that an infinite end becomes the infinity it" ++
            "reflects to and a finite one its own negation",
        .mul => "the hull of the four corner SETS, each a point or a ray, with a zero factor collapsing its corner" ++
            "to the point zero",
        .abs => "the attained closed-end magnitudes, with exactly zero where the interval spans it and +inf" ++
            "wherever either end is unbounded",
        .sqr => "the attained closed-end squares, with exactly zero where the interval spans it and +inf wherever" ++
            "either end is unbounded",
        .scale => "for an unbounded input the operand itself at |factor| = 1 and the whole line at every other" ++
            "factor, and for a bounded input the exact affine extrema compared through the five-term f128 expansion" ++
            "of the original f64 endpoints, with the whole line demanded at an infinite factor on any box that has" ++
            "width and the point itself demanded on one that does not",
        .div, .recip => "the whole line where the divisor reaches zero or is the whole line, zero as an" ++
            "accumulation point at every ray end of the divisor, the matching infinity at every ray end of the" ++
            "dividend, and exact cross-multiplication of every attained corner",
        .hull, .intersect => "the min and the max of the two lower and upper ends, exact, and null where they cross",
        else => unreachable,
    };
}

/// What a frontier row turned out to be.
///
/// Every arm is read off the SHAPES and the scalar and never off an answer or
/// off the arithmetic the operation will go on to perform, so the
/// classification costs nothing and cannot be accused of having classified
/// its way to green. The three refusals are the three the callers DECLARE: an
/// unordered pair, and the two preconditions of `expand`. A row that is none
/// of those is called and judged — including every operation that forms an
/// endpoint out of a ray, because the constructor normalises
/// `[floatMax,+inf]` and `[-inf,-floatMax]`, so a canonical operand no longer
/// produces the indeterminate corner sum an unnormalised one did.
const Row = enum {
    /// Call the operation and judge the answer against its reference.
    asked,
    /// `Interval.init` requires lo <= hi and TRAPS on a pair that breaks it,
    /// measured rather than assumed: every operation on `{inf,-inf}` dies
    /// with SIGABRT before it computes anything. The sweep records the
    /// refusal instead of working around it. A hand-built inverted struct is
    /// a different question and is asked in a fixed test of its own, where
    /// the two operations that never call `init` can be watched.
    unordered,
    /// `expand`'s documented precondition `margin >= -(hi - lo) / 2`, which a
    /// BOUNDED box can refuse — and does refuse a margin more negative than
    /// half its width, which would come back as an inverted interval and
    /// abort. Decided on the exact real through `marginAdmissible` — the
    /// sign of `hi - lo + 2 * margin` — and never on a width rounded to one
    /// `f128` or one `f64`, so a margin the operation does not accept never
    /// reaches a call. An unbounded box has no width to divide, so every
    /// finite margin passes it.
    expand_width,
    /// `expand(-inf)`: the margin is the canonical NEGATIVE overflow ray and
    /// stands for every real margin at or below -floatMax. Every one of
    /// them is at or under -floatMax, and no bounded box accepts any of
    /// them, so the row is a refusal and the ray is NOT quietly narrowed to
    /// the one margin some box would take. `[-floatMax, floatMax]` is the
    /// case that makes the rule visible rather than incidental: it is the
    /// widest bounded box there is, its only admissible margin in the ray is
    /// -floatMax itself, and the answer for that single margin is not an
    /// answer for the ray. An unbounded input has no width, so every margin
    /// in the ray passes there and the row is called.
    expand_negative_ray,
};

/// What this row is, read off the shapes and the scalar alone.
fn classifyRow(op: Op, a: Shape, b: ?Shape, s: f64) Row {
    if (!a.ordered()) return .unordered;
    if (b) |x| {
        if (!x.ordered()) return .unordered;
    }
    if (op == .expand and !a.unbounded()) {
        if (s == neg_inf64) return .expand_negative_ray;
        // The width is a real, so the inequality is decided on the real and
        // not on a rounded difference of two widened endpoints.
        if (!a.admitsMargin(s)) return .expand_width;
    }
    return .asked;
}

/// True when `got` is what the frontier reference requires of the case.
///
/// The reference is built from the two canonical readings and never from
/// the intervals in the case, which is what keeps this from being a
/// comparison of the library against itself: a constructor that normalises
/// `[floatMax,+inf]` and one that leaves `{inf,inf}` are judged against the
/// same reference and answer differently.
fn frontierHolds(op: Op, a: Canonical, b: Canonical, s: f64, c: Case, got: Value) bool {
    if (frontierSum(op, a, b, s)) |f| return f.holds(got.intervalOrNull() orelse return false);
    const one: Canonical = .{ .lo = 1.0, .hi = 1.0, .lo_unbounded = false, .hi_unbounded = false };
    switch (op) {
        .div => return frontierQuotientHolds(a, b, got.intervalOrNull() orelse return false),
        .recip => return frontierQuotientHolds(one, a, got.intervalOrNull() orelse return false),
        .scale => {
            const g = got.intervalOrNull() orelse return false;
            // An unbounded box has no finite midpoint, so the contract
            // replaces the affine image with the identity-or-whole-line
            // pair. A bounded one has no ray to read and nothing to
            // normalise, so it is judged by the same exact five-term
            // comparison the finite sweep uses, over the endpoints the
            // caller wrote.
            if (a.lo_unbounded or a.hi_unbounded) return unboundedScaleHolds(a, s, g);
            return boundedScaleHolds(c.a, s, g);
        },
        .intersect => {
            const m = switch (got) {
                .maybe_interval => |x| x,
                else => return false,
            };
            return maybeMatches(m, frontierReference(op, a, b, s));
        },
        else => {},
    }
    const g = got.intervalOrNull() orelse return false;
    if (std.math.isNan(g.lo) or std.math.isNan(g.hi)) return false;
    if (g.lo > g.hi) return false;
    const r = frontierReference(op, a, b, s) orelse return false;
    return loEncloses(r, g.lo) and hiEncloses(r, g.hi);
}

/// How many rows each outcome took, so the skip count on a report line can
/// be read rather than taken on trust. Every arm is a DECLARED precondition,
/// so a skip here is a row the callers themselves refuse, and each reason is
/// named on the report line rather than left as a bare number.
const Skips = struct {
    unordered: usize = 0,
    expand_width: usize = 0,
    expand_negative_ray: usize = 0,

    fn note(s: *Skips, r: Row) void {
        switch (r) {
            .unordered => s.unordered += 1,
            .expand_width => s.expand_width += 1,
            .expand_negative_ray => s.expand_negative_ray += 1,
            .asked => {},
        }
    }

    /// The reasons, one line each and only when there is something to say, so
    /// that a skipped count in the log is never a bare number.
    fn report(s: Skips, op: Op) void {
        if (s.unordered > 0) {
            reportErr(
                "      {d} rows not called: the pair is not ordered, and Interval.init traps on it\n",
                .{s.unordered},
            );
        }
        if (s.expand_width > 0) {
            reportErr(
                "      {d} rows not called: {s} needs margin >= -(hi - lo) / 2, and this bounded box refuses the" ++
                    "margin\n",
                .{ s.expand_width, op.label() },
            );
        }
        if (s.expand_negative_ray > 0) {
            reportErr(
                "      {d} rows not called: the margin is the negative overflow ray, every real margin at or below" ++
                    "-floatMax, and no bounded box accepts any of them - [-floatMax,floatMax] included\n",
                .{s.expand_negative_ray},
            );
        }
    }
};

/// Whether the sweep announces each row before calling it.
///
/// It does, and the reason is mechanical rather than cosmetic. A call can
/// abort when the production answer to a row is not an interval, and an
/// abort ends the whole test binary, so with no trace the last line in the
/// log belongs to whichever operation ran before the culprit and the row
/// that killed the run is never named. The sweep is directed and bounded, so
/// a line per row is a record rather than a flood, and the `Shape` ordering
/// is chosen so the shapes most likely to abort are asked last.
const frontier_trace = true;

/// The identity of one frontier row: the shapes, and the scalar where the
/// operation takes one. The shape IS the identity of a frontier case, since
/// the same operation on two of them has two different true images.
fn rowText(buf: []u8, op: Op, a: Shape, b: ?Shape, s: f64) []const u8 {
    if (op.usesScalar()) {
        if (b) |x| {
            const text = std.mem.print(buf, "a = {s}, b = {s}, s = {e}", .{
                a.label(), x.label(), s,
            }) catch "a shape pair";
            return text;
        }
        return std.mem.print(buf, "a = {s}, s = {e}", .{ a.label(), s }) catch "one shape";
    }
    if (b) |x| {
        return std.mem.print(buf, "a = {s}, b = {s}", .{ a.label(), x.label() }) catch "a shape pair";
    }
    return std.mem.print(buf, "a = {s}", .{a.label()}) catch "one shape";
}

/// The canonical reading of the second operand, or of a stand-in point when
/// the operation takes no second shape. The point is `{0,0}` rather than
/// anything else because every operation that ignores `b` ignores it
/// entirely, and a stand-in that is a valid canonical set means the
/// reference cannot be disturbed by a choice made here.
fn bCanonical(b: ?Shape) Canonical {
    if (b) |x| return x.canonical();
    return .{ .lo = 0.0, .hi = 0.0, .lo_unbounded = false, .hi_unbounded = false };
}

/// One frontier row, classified and then either skipped on a declared
/// precondition, or called and judged.
fn frontierRow(op: Op, t: *Tally, skips: *Skips, a: Shape, b: ?Shape, s: f64) void {
    switch (classifyRow(op, a, b, s)) {
        .asked => {},
        else => |r| {
            skips.note(r);
            t.skipped_precondition += 1;
            return;
        },
    }
    const c: Case = .{
        .op = op,
        .a = a.interval(),
        .b = if (b) |x| x.interval() else Interval.init(0.0, 0.0),
        .s = s,
    };
    var buf: [96]u8 = undefined;
    if (frontier_trace) {
        reportErr("    row {s}: {s}\n", .{ op.label(), rowText(&buf, op, a, b, s) });
    }
    const got = apply(c);
    if (frontierHolds(op, a.canonical(), bCanonical(b), s, c, got)) {
        t.checked += 1;
        return;
    }
    t.failures += 1;
    if (t.shown >= max_detail) return;
    t.shown += 1;
    reportErr("    FAIL frontier {s}: the answer is not what the frontier reference requires\n", .{op.label()});
    reportErr("      shapes    {s}\n", .{rowText(&buf, op, a, b, s)});
    showCase(c, got);
    diagnoseFrontier(op, a.canonical(), bCanonical(b), s, got);
    reportErr("      the frontier reference is {s}\n", .{frontierOracle(op)});
}

/// What the answer missed, in the terms of the reference that missed it.
/// A sum reference prints its two `f64` operands and the residual beside
/// them, a `scale` prints the rule it broke — the identity-or-whole-line
/// pair on an unbounded operand and the five exact terms on a bounded one —
/// and a `Range` reference prints the extremum and which side cut inside it.
fn diagnoseFrontier(op: Op, a: Canonical, b: Canonical, s: f64, got: Value) void {
    const g = got.intervalOrNull() orelse return;
    if (frontierSum(op, a, b, s)) |f| {
        const lo = twoSum(f.alo, f.blo);
        const hi = twoSum(f.ahi, f.bhi);
        if (f.lo_unbounded) {
            reportErr("      the true image runs off to -inf, so only a lo of -inf encloses it\n", .{});
        } else {
            reportErr("      true lo = {e} + {e} = {e} + {e} exactly\n", .{ f.alo, f.blo, lo.s, lo.err });
        }
        if (f.hi_unbounded) {
            reportErr("      the true image runs off to +inf, so only a hi of +inf encloses it\n", .{});
        } else {
            reportErr("      true hi = {e} + {e} = {e} + {e} exactly\n", .{ f.ahi, f.bhi, hi.s, hi.err });
        }
        if (!f.lowerOk(g.lo)) reportErr("      the lower bound excludes the true minimum\n", .{});
        if (!f.upperOk(g.hi)) reportErr("      the upper bound excludes the true maximum\n", .{});
        return;
    }
    if (op == .scale and (a.lo_unbounded or a.hi_unbounded)) {
        if (@abs(ex(s)) == 1.0) {
            reportErr(
                "      |factor| = 1 is the identity for every centre, so the answer has to be the operand itself\n",
                .{},
            );
        } else {
            reportErr(
                "      no centre exists for an unbounded input, so the contract's answer is the whole line at every" ++
                    "factor but +/-1\n",
                .{},
            );
        }
        return;
    }
    if (op == .scale) {
        const bound: ScaleBound = .{ .lo = a.lo, .hi = a.hi, .mag = @abs(s) };
        if (@abs(s) == inf64 and a.lo < a.hi) {
            reportErr(
                "      an infinite factor is an unknown finite magnitude, and the union over all of them is" ++
                    "the whole line for a box with width\n",
                .{},
            );
        } else {
            reportErr(
                "      A = {e}, B = {e}, G = {e}, judged through the exact five-term expansion and never through a" ++
                    "midpoint\n",
                .{ bound.lo, bound.hi, bound.mag },
            );
        }
        if (!bound.lowerOk(g.lo)) reportErr("      the lower bound excludes the true minimum\n", .{});
        if (!bound.upperOk(g.hi)) reportErr("      the upper bound excludes the true maximum\n", .{});
        return;
    }
    if (op == .div or op == .recip) {
        reportErr(
            "      quotient containment, by exact cross-multiplication; see the frontier reference for the rule each" ++
                "corner falls under\n",
            .{},
        );
        return;
    }
    const r = frontierReference(op, a, b, s) orelse return;
    reportErr("      frontier lo = {e}\n", .{r.lo});
    reportErr("      frontier hi = {e}\n", .{r.hi});
    if (r.lo_beyond) {
        reportErr(
            "      the true minimum is a real past the end of the f64 range, so a returned lo of +inf excludes it\n",
            .{},
        );
    } else if (!lowerOk(r.lo, g.lo)) {
        reportErr("      lower bound is ABOVE the true minimum and excludes it\n", .{});
    }
    if (r.hi_beyond) {
        reportErr(
            "      the true maximum is a real past the end of the f64 range, so a returned hi of -inf excludes it\n",
            .{},
        );
    } else if (!upperOk(r.hi, g.hi)) {
        reportErr("      upper bound is BELOW the true maximum and excludes it\n", .{});
    }
}

/// The constructor contract every frontier row depends on.
///
/// `Interval.init(+inf,+inf)` supplies the closed overflow ray `[floatMax,
/// +inf]` and its mirror `[-inf,-floatMax]`, and that is the ONE thing this
/// sweep needs before it can call any operation on a shape with an infinite
/// end. Without it, `add`, `sub`, `translate` and `expand` form an endpoint
/// out of `inf + (-inf)`, hand a NaN pair to the very constructor that would
/// have normalised the operand, and trap — which takes the test binary down
/// before a single later row can report anything.
///
/// It is a guard on the constructor and nothing else. It refuses nothing,
/// skips nothing and judges no answer: once the two rays come back
/// canonical every one of the thirteen sweeps runs every row it has, and a
/// production gap afterwards is reported as a failed row rather than
/// hidden.
fn expectCanonicalRays() !void {
    const pos = Interval.init(inf64, inf64);
    const neg = Interval.init(neg_inf64, neg_inf64);
    reportErr(
        "      canonical rays from the constructor: [+inf,+inf] -> [{e}, {e}], [-inf,-inf] -> [{e}, {e}]\n",
        .{ pos.lo, pos.hi, neg.lo, neg.hi },
    );
    try std.testing.expectEqual(std.math.floatMax(f64), pos.lo);
    try std.testing.expectEqual(inf64, pos.hi);
    try std.testing.expectEqual(neg_inf64, neg.lo);
    try std.testing.expectEqual(-std.math.floatMax(f64), neg.hi);
}

/// The frontier sweep for one operation: every shape against every shape it
/// takes a second shape from, or every scalar it takes.
///
/// No operation is short-circuited here any more. The old sweep returned
/// early for the six whose answer the file had no agreed reading for, and
/// printed a finding instead of a tally; the contract fixes the reading, so
/// every one of the thirteen is swept like the rest and a gap in `src/`
/// shows up as a failed row with a shape and a reference attached to it.
///
/// The constructor guard runs first and is the only thing that can stop a
/// sweep before it starts. It is what turns a pre-fix run into a clean
/// assertion failure naming the constructor instead of an abort that
/// suppresses every finding after it, and it suppresses nothing at all once
/// the two rays are canonical.
fn frontier(op: Op) !Tally {
    try expectCanonicalRays();
    var t: Tally = .{ .op = op };
    var skips: Skips = .{};
    if (op.usesSecond()) {
        for (frontier_shapes) |a| {
            for (frontier_shapes) |b| frontierRow(op, &t, &skips, a, b, 0.0);
        }
    } else if (op.usesScalar()) {
        for (frontier_shapes) |a| {
            for (frontier_scalars) |s| frontierRow(op, &t, &skips, a, null, s);
        }
    } else {
        for (frontier_shapes) |a| frontierRow(op, &t, &skips, a, null, 0.0);
    }
    summary(t, "frontier ");
    skips.report(op);
    return t;
}

// ---------------------------------------------------------------------------
// The frontier sweep
// ---------------------------------------------------------------------------

// One line per judged operation, in the order of `Op`, with the tally the
// random sweeps print. The rows are directed rather than drawn, so the
// counts are small and every one of them is a shape whose true image is
// stated in the section above rather than reached by luck.
//
// THIRTEEN of them, and there is no thirteenth-block comment about what is
// missing: the six that used to be withheld are swept here like the rest,
// because the reading their expected answers depended on is now fixed.
//
// Every one of them asks its rows after the constructor guard, which is the
// only thing that can stop a sweep before it starts. A run against a
// constructor that does not yet normalise the two overflow rays therefore
// fails as one clean assertion naming the constructor, instead of aborting
// inside the first ray row and reporting nothing after it.

test "frontier: add" {
    const t = try frontier(.add);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "frontier: sub" {
    const t = try frontier(.sub);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "frontier: mul" {
    const t = try frontier(.mul);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "frontier: div" {
    const t = try frontier(.div);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "frontier: recip" {
    const t = try frontier(.recip);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "frontier: translate" {
    const t = try frontier(.translate);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "frontier: expand" {
    const t = try frontier(.expand);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "frontier: abs" {
    const t = try frontier(.abs);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "frontier: sqr" {
    const t = try frontier(.sqr);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "frontier: scale" {
    const t = try frontier(.scale);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "frontier: neg" {
    const t = try frontier(.neg);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "frontier: hull" {
    const t = try frontier(.hull);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "frontier: intersect" {
    const t = try frontier(.intersect);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

// The bounded-scale reference is the one oracle in this file that compares
// FIVE exact terms rather than two, and a five-term oracle has a failure mode
// of its own: an `f128` midpoint and half-width are exact to within 2^-113
// relative, which is millions of orders tighter than the answer they judge,
// so they LOOK adequate and are not. Every case below is a bound that lies
// inside the true image, and each one is named for the arithmetic that puts
// it there rather than for a shape in a table.
//
// The centre row is the genuine miss, and it is the one to read first. At a
// factor of zero the true image of `[min_subnormal, floatMax]` is the single
// real `floatMax/2 + min_subnormal/2`, and the rounded `f128` midpoint of
// the two endpoints is `floatMax/2` — which is INSIDE that image, below its
// top. A reference that formed the midpoint first would therefore clear the
// answer `[floatMax/2, floatMax/2]` for a box whose image it excludes, and
// the mirrored row `[-min_subnormal, floatMax]` puts the same real on the
// other side, where the unsafe answer is the one with `floatMax/2` at its
// BOTTOM. The `f128` midpoint is computed below and printed against its
// verdict, so the gap is visible in the log rather than asserted here.
//
// The identity row and the subnormal lattice row are pins and not misses,
// and saying so is the point of the paragraph. The identity row's bounds are
// the box's own endpoints; the lattice row's two extrema are `1.25` and
// `1.75` times the smallest subnormal, and the rounded midpoint and
// half-width happen to be exact on three subnormals. Neither line argues
// that the old reference was wrong there. Both hold the new predicate to the
// answer the arithmetic gives, which is what makes them guards rather than
// restatements: one step in from either end of either row is a real inside
// the image, and every such point is refused.
//
// Nothing here calls production rounding and nothing pins an incidental bit
// pattern. The inward points are named as facts about reals, and the
// expectations are the reference's verdicts, not the library's.
test "the exact bounded-scale comparator rejects the inward bounds an f128 midpoint clears" {
    const fmax = std.math.floatMax(f64);
    const tiny = min_subnormal;

    // A factor of one is the identity, so the true image of
    // `[min_subnormal, floatMax]` is that box and nothing else. One step in
    // from either end is inside the image and must be refused.
    //
    // The two accepting lines are the other half of the row and they are not
    // filler. An oracle that is too TIGHT is a defect class of its own: it
    // reports the library's correct answers as failures, which is a false RED
    // rather than a missed hole, and this row is where one is caught. A
    // rounded `f128` reference is exactly that here — its range for this
    // identity comes out `[0, floatMax]`, whose lower end is below the true
    // minimum and which therefore refuses the sound bound `[min_subnormal,
    // floatMax]`. The exact predicate accepts it, because the two signed
    // differences are zero to the last bit.
    const identity: ScaleBound = .{ .lo = tiny, .hi = fmax, .mag = 1.0 };
    try std.testing.expect(identity.lowerOk(tiny));
    try std.testing.expect(identity.upperOk(fmax));
    try std.testing.expect(!identity.lowerOk(interval.nextUp(tiny)));
    try std.testing.expect(!identity.upperOk(interval.prevDown(fmax)));

    // A factor of zero is the centre, and the centre of a box spanning two
    // thousand binades is NOT the rounded mean of its endpoints. The `f128`
    // midpoint is printed beside the verdict to show the gap: it is
    // `floatMax/2` exactly, which is a real half a subnormal below the true
    // centre, and the exact comparison refuses it as an UPPER bound while
    // accepting it as a lower one.
    const centre: ScaleBound = .{ .lo = tiny, .hi = fmax, .mag = 0.0 };
    const rounded_centre: f64 = @floatCast((ex(tiny) + ex(fmax)) / 2.0);
    reportErr("\n  scale centre of [{e}, {e}] at a factor of zero\n", .{ tiny, fmax });
    reportErr(
        "    the rounded f128 midpoint is {e}, a real half a subnormal BELOW the true centre {e} + {e} / 2\n",
        .{ rounded_centre, fmax, tiny },
    );
    reportErr("    read as a lower bound {s}, as an upper bound {s}\n", .{
        if (centre.lowerOk(rounded_centre)) "ACCEPTED" else "REJECTED",
        if (centre.upperOk(rounded_centre)) "ACCEPTED" else "REJECTED",
    });
    try std.testing.expect(rounded_centre == fmax / 2.0);
    try std.testing.expect(centre.lowerOk(fmax / 2.0));
    try std.testing.expect(!centre.upperOk(fmax / 2.0));
    // And the same centre from below, where the residual goes the other way:
    // the true centre of `[-min_subnormal, floatMax]` is
    // `floatMax/2 - min_subnormal/2`, so `floatMax/2` is above it and is
    // not a lower bound.
    const below: ScaleBound = .{ .lo = -tiny, .hi = fmax, .mag = 0.0 };
    reportErr(
        "    the mirror box [-{e}, {e}] puts its true centre at {e} / 2 - {e} / 2, a half" ++
            "subnormal below it, so read as a lower bound {s}, as an upper bound {s}\n",
        .{
            tiny,
            fmax,
            fmax,
            tiny,
            if (below.lowerOk(rounded_centre)) "ACCEPTED" else "REJECTED",
            if (below.upperOk(rounded_centre)) "ACCEPTED" else "REJECTED",
        },
    );
    try std.testing.expect(!below.lowerOk(fmax / 2.0));
    try std.testing.expect(below.upperOk(fmax / 2.0));

    // The same predicate on a wholly subnormal lattice, where both extrema
    // are reals no `f64` holds: 1.25 and 1.75 times the smallest subnormal.
    // The box itself encloses them, and each inward point does not.
    const lattice: ScaleBound = .{ .lo = tiny, .hi = 2.0 * tiny, .mag = 0.5 };
    try std.testing.expect(lattice.lowerOk(tiny));
    try std.testing.expect(lattice.upperOk(2.0 * tiny));
    try std.testing.expect(!lattice.lowerOk(2.0 * tiny));
    try std.testing.expect(!lattice.upperOk(tiny));

    // An exactly cancelling comparison is an EXACT ZERO expansion, and it is
    // the case a rounded head cannot represent at all: `[-1,1]` at a factor
    // of one has `L = -1` and `H = 1` to the last bit, and one step in from
    // either end is a step inside.
    const parity: ScaleBound = .{ .lo = -1.0, .hi = 1.0, .mag = 1.0 };
    try std.testing.expect(parity.lowerOk(-1.0));
    try std.testing.expect(parity.upperOk(1.0));
    try std.testing.expect(!parity.lowerOk(interval.nextUp(-1.0)));
    try std.testing.expect(!parity.upperOk(interval.prevDown(1.0)));

    // A computed overflow on the way out. `[-floatMax, floatMax]` at a
    // factor of two has the extrema `-2*floatMax` and `2*floatMax`, which
    // are reals past the end of the `f64` range and not numbers at all in it.
    // The enclosing infinity is the only lower bound there is, and `floatMax`
    // is a real inside the image and is refused.
    const overflowed: ScaleBound = .{ .lo = -fmax, .hi = fmax, .mag = 2.0 };
    try std.testing.expect(overflowed.lowerOk(neg_inf64));
    try std.testing.expect(overflowed.upperOk(inf64));
    try std.testing.expect(!overflowed.lowerOk(fmax));
    try std.testing.expect(!overflowed.upperOk(-fmax));
    // The same bound pointing the other way is not an enclosure of anything
    // finite, and a NaN bound is not a bound.
    try std.testing.expect(!overflowed.lowerOk(inf64));
    try std.testing.expect(!overflowed.upperOk(neg_inf64));
    try std.testing.expect(!overflowed.lowerOk(std.math.nan(f64)));

    // A degenerate box is a point at every factor, and the infinities still
    // enclose it: the map has zero half-width there, so nothing widens it.
    const point = Interval.init(2.0, 2.0);
    try std.testing.expect(boundedScaleHolds(point, 3.0, point));
    try std.testing.expect(boundedScaleHolds(point, 0.0, point));
    try std.testing.expect(!boundedScaleHolds(point, 3.0, Interval.init(interval.nextUp(2.0), 3.0)));

    // An infinite factor is an unknown magnitude and never a number in the
    // expansion. A box with width is the whole line and nothing else; a box
    // without one is its own point, because the half-width is zero at every
    // magnitude. Both signs of the factor are the same magnitude, so both
    // take the same arm.
    const wide = Interval.init(1.0, 2.0);
    try std.testing.expect(boundedScaleHolds(wide, inf64, Interval.init(neg_inf64, inf64)));
    try std.testing.expect(boundedScaleHolds(wide, neg_inf64, Interval.init(neg_inf64, inf64)));
    try std.testing.expect(!boundedScaleHolds(wide, inf64, Interval.init(-3.0, 4.0)));
    try std.testing.expect(!boundedScaleHolds(wide, neg_inf64, Interval.init(neg_inf64, 4.0)));
    try std.testing.expect(boundedScaleHolds(point, inf64, point));
    try std.testing.expect(boundedScaleHolds(point, neg_inf64, point));
    // A NaN factor is the operation's own precondition, not an image.
    try std.testing.expect(!boundedScaleHolds(wide, std.math.nan(f64), Interval.init(neg_inf64, inf64)));

    // The library's own answers, at the shapes the fuzz draw cannot reach: a
    // centre and the two identities on a finite box. These are containment
    // checks against the exact reference and not pins of a bound.
    const unit = Interval.init(1.0, 2.0);
    try std.testing.expect(boundedScaleHolds(unit, 1.0, unit.scale(1.0)));
    try std.testing.expect(boundedScaleHolds(unit, -1.0, unit.scale(-1.0)));
    const two = Interval.init(-3.0, 5.0);
    try std.testing.expect(boundedScaleHolds(two, 2.0, two.scale(2.0)));
    // The centre of `[min_subnormal, floatMax]`, which is the case the
    // whole comparison exists for.
    try std.testing.expect(boundedScaleHolds(Interval.init(tiny, fmax), 0.0, Interval.init(tiny, fmax).scale(0.0)));
}

// The margin precondition has the same failure mode the bounded-scale
// comparator has and no rounded-width reference can be trusted with it,
// because the width is the largest sum in the format: `floatMax -
// min_subnormal` is over a thousand significand bits and `f128` carries
// 113, so it comes back as `floatMax` and the half-width comes back as
// `floatMax / 2` — a number BELOW the true half-width, since the true one
// is `floatMax / 2 + min_subnormal / 2`. A rounded rule therefore refuses
// the one admissible margin just above the boundary and admits the one
// just below it, and the margin it admits is exactly the one that comes
// back as an inverted interval and takes the binary with it.
//
// Every line below is the reference's verdict on a margin, not the
// library's answer, and the disagreement with the rounded rule is shown at
// the one place it exists so that the rule cannot be reinstated by accident.
test "the exact margin predicate separates the two margins a rounded half-width merges" {
    const fmax = std.math.floatMax(f64);
    const tiny = min_subnormal;

    // The extreme-residual boundary. On `[min_subnormal, floatMax]` the
    // admissible margins run from `-(floatMax / 2 + min_subnormal / 2)`
    // upward, and that lower end is not a number `f64` holds. The two
    // representable margins straddling it are `-floatMax / 2`, which is one
    // step too far and inverts the interval, and the next step up, which
    // is admissible by a comfortable margin. The rounded half-width sits
    // at `-floatMax / 2`, so it puts the boundary a whole step too low and
    // takes the first of these two.
    try std.testing.expect(!marginAdmissible(tiny, fmax, -fmax / 2.0));
    try std.testing.expect(marginAdmissible(tiny, fmax, interval.nextUp(-fmax / 2.0)));
    // The rounded rule is the one that has to disagree, and it is shown
    // disagreeing rather than described: `floatMax - min_subnormal` rounds
    // to `floatMax`, so `-width / 2` is exactly the margin the exact
    // predicate refuses, and a strict `<` against it lets that one through.
    const rounded_half = -((ex(fmax) - ex(tiny)) / 2.0);
    try std.testing.expect(rounded_half == -fmax / 2.0);
    try std.testing.expect(!(ex(-fmax / 2.0) < rounded_half));

    // The widest bounded box there is, where the true half-width IS a
    // number: `floatMax`. The margin at the boundary is an EXACT ZERO
    // expansion — the fold leaves nothing behind at all — so it is also the
    // row that says an empty expansion is a total of zero and not an
    // absent one.
    // There is no finite `f64` margin past it — `-floatMax` is the most
    // negative one there is — so the step-past boundary is taken on a box
    // half as wide, where both sides of the boundary are representable.
    try std.testing.expect(marginAdmissible(-fmax, fmax, -fmax));
    try std.testing.expect(marginAdmissible(-fmax / 2.0, fmax / 2.0, -fmax / 2.0));
    try std.testing.expect(!marginAdmissible(-fmax / 2.0, fmax / 2.0, interval.prevDown(-fmax / 2.0)));

    // A box with no width admits no negative margin at all: the total is
    // then exactly `2 * margin`, so zero is the boundary and it is reached.
    try std.testing.expect(marginAdmissible(2.0, 2.0, 0.0));
    try std.testing.expect(marginAdmissible(2.0, 2.0, tiny));
    try std.testing.expect(!marginAdmissible(2.0, 2.0, -tiny));

    // An ordinary box, where the boundary `-0.5` IS representable and the
    // step below it is the one the operation refuses.
    try std.testing.expect(marginAdmissible(0.0, 1.0, -0.5));
    try std.testing.expect(!marginAdmissible(0.0, 1.0, interval.prevDown(-0.5)));

    // A subnormal lattice, where the true half-width is `1.5` times the
    // smallest subnormal and therefore not representable at all: the two
    // representable margins are `-2 * tiny`, one step too far, and
    // `-tiny`, which clears it.
    try std.testing.expect(!marginAdmissible(tiny, 4.0 * tiny, -2.0 * tiny));
    try std.testing.expect(marginAdmissible(tiny, 4.0 * tiny, -tiny));

    // A margin at or above zero is admissible at every width, which is a
    // statement about the three terms rather than a special case: the
    // width is never negative and neither is twice the margin.
    try std.testing.expect(marginAdmissible(tiny, fmax, 0.0));
    try std.testing.expect(marginAdmissible(tiny, fmax, fmax));
    try std.testing.expect(marginAdmissible(-fmax, fmax, fmax));

    // The infinities are decided before the expansion is grown, and the
    // reason they have to be is that folding one in does not widen the
    // answer, it destroys it: `TwoSum(+inf, x)` computes `inf - inf` and
    // the residual comes back NaN. A positive ray margin is a widening by
    // every positive real and no box refuses it; the negative ray is every
    // margin at or below -floatMax and every bounded box refuses all of
    // them, `[-floatMax, floatMax]` — the one box with a finite margin at
    // exactly -floatMax — included, because the contract refuses the ray
    // rather than clipping it to that single admissible value. A NaN is
    // not a margin.
    try std.testing.expect(marginAdmissible(-fmax, fmax, inf64));
    try std.testing.expect(marginAdmissible(2.0, 2.0, inf64));
    try std.testing.expect(!marginAdmissible(-fmax, fmax, neg_inf64));
    try std.testing.expect(!marginAdmissible(2.0, 2.0, neg_inf64));
    try std.testing.expect(!marginAdmissible(2.0, 2.0, std.math.nan(f64)));
}

// The two frontier references the old table got wrong, pinned as
// REFERENCES and not as answers. Both are statements about the image of a
// set, so asking the reference is asking the mathematics; the production
// answer at the same shapes is what `frontier: sub` and `frontier: neg`
// judge, and is not restated here.
test "frontier: the subtraction witness is the same ray, and the reflection is the canonical ray" {
    const fmax = std.math.floatMax(f64);
    // The canonical overflow rays the contract fixes, built directly rather
    // than through the constructor, so this test states the reference and
    // not what the constructor currently does with a pair of infinities.
    const pos = Shape.pos_point.canonical();
    const neg = Shape.neg_point.canonical();

    // The SAME ray cancels. Both ends run off, in opposite directions, and
    // the image is the whole line. This is the row that used to abort.
    const same = frontierSub(pos, pos);
    try std.testing.expect(same.lo_unbounded);
    try std.testing.expect(same.hi_unbounded);
    try std.testing.expect(same.holds(Interval.init(neg_inf64, inf64)));
    try std.testing.expect(!same.holds(Interval.init(-fmax, inf64)));
    // The same is true of the negative ray against itself, for the mirrored
    // reason: the low end is -inf and the high end is +inf.
    const same_neg = frontierSub(neg, neg);
    try std.testing.expect(same_neg.lo_unbounded);
    try std.testing.expect(same_neg.hi_unbounded);

    // The OPPOSITE rays do NOT cancel, and this is the witness the old
    // table had backwards. The low end is the sum of two attained closed
    // ends, 2*floatMax, and the high end runs off to +inf. So the image is
    // a ray above 2*floatMax and NOT the whole line, the lower bound does
    // not have to reach -inf, and floatMax is a sound lower bound because
    // every f64 is at or below 2*floatMax.
    const opposed = frontierSub(pos, neg);
    try std.testing.expect(!opposed.lo_unbounded);
    try std.testing.expect(opposed.hi_unbounded);
    try std.testing.expect(opposed.lowerOk(-fmax));
    try std.testing.expect(opposed.lowerOk(fmax));
    try std.testing.expect(!opposed.lowerOk(inf64));
    try std.testing.expect(!opposed.holds(Interval.init(neg_inf64, fmax)));
    // The mirror: the negative ray minus the positive one runs off to
    // -inf below and is bounded above by -2*floatMax.
    const opposed_mirror = frontierSub(neg, pos);
    try std.testing.expect(opposed_mirror.lo_unbounded);
    try std.testing.expect(!opposed_mirror.hi_unbounded);
    try std.testing.expect(opposed_mirror.upperOk(-fmax));
    try std.testing.expect(!opposed_mirror.upperOk(neg_inf64));

    // Opposite-ray ADDITION is the whole line, and that is a fact about
    // addition rather than an accident: one side has no lower bound and the
    // other has no upper one.
    const sum = frontierAdd(pos, neg);
    try std.testing.expect(sum.lo_unbounded);
    try std.testing.expect(sum.hi_unbounded);
    try std.testing.expect(sum.holds(Interval.init(neg_inf64, inf64)));

    // `neg` of a canonical ray is the ordinary reflected ray, so it is
    // judged by the same containment as every other shape — and the
    // reflection swaps the two DIRECTIONS as well as the two ends, which
    // is the part the removed bit-pattern test used to stand in for. The
    // degenerate box a constructor that does not normalise hands back is
    // not an enclosure of either ray: it is the single point -inf, and the
    // image of the positive ray is everything below -floatMax.
    const reflected = range(negated(pos));
    try std.testing.expect(neg_inf128 == reflected.lo);
    try std.testing.expect(ex(-fmax) == reflected.hi);
    try std.testing.expect(loEncloses(reflected, neg_inf64) and hiEncloses(reflected, -fmax));
    try std.testing.expect(!(hiEncloses(reflected, neg_inf64)));
    const mirrored = range(negated(neg));
    try std.testing.expect(ex(fmax) == mirrored.lo);
    try std.testing.expect(inf128 == mirrored.hi);
    try std.testing.expect(loEncloses(mirrored, fmax) and hiEncloses(mirrored, inf64));
    try std.testing.expect(!(loEncloses(mirrored, inf64)));
    // The whole line reflects to itself, on both flags as well as both ends.
    const line_reflected = negated(Shape.line.canonical());
    try std.testing.expect(line_reflected.lo_unbounded and line_reflected.hi_unbounded);
    try std.testing.expect(loEncloses(range(line_reflected), neg_inf64) and hiEncloses(range(line_reflected), inf64));
    // A bounded box reflects to itself set-wise only when it is symmetric,
    // and a bounded box never picks up a direction it did not have.
    const finite_reflected = negated(Shape.narrow.canonical());
    try std.testing.expect(!finite_reflected.lo_unbounded and !finite_reflected.hi_unbounded);
    try std.testing.expectEqual(@as(f64, -2.0), finite_reflected.lo);
    try std.testing.expectEqual(@as(f64, -1.0), finite_reflected.hi);
}

// The mutants the one-sided magnitude rule let through, and the overflow its
// saturation was really about. Every wrong answer here used to pass
// `fuzz: width` and `fuzz: distance_to`, and none of them does now.
//
// Every verdict is PRINTED before any of them is asserted, so a run against
// the old rule shows the whole list of what it accepted rather than stopping
// at the first one.
test "guard: width and distanceTo are judged as VALUES - too large fails as loudly as too small" {
    const a = Interval.init(1.0, 2.0);
    const width_case: Case = .{ .op = .width, .a = a, .b = Interval.init(0.0, 0.0), .s = 0.0 };
    const true_width = exactWidth(a);
    // Four times the true width, plus one. A rule that asks only "is it big
    // enough" takes this, and it is plenty big.
    const inflated: f64 = @floatCast(true_width * 4.0 + 1.0);
    // +inf for a width that is a finite real, which the old rule took on
    // every case without asking.
    const true_ok = holds(width_case, .{ .scalar = a.width() });
    const inflated_ok = holds(width_case, .{ .scalar = inflated });
    const infinite_ok = holds(width_case, .{ .scalar = inf64 });

    // The overflow that rule existed for is still decided correctly, and it
    // is decided by the REFERENCE rather than by the rule: the exact width of
    // the whole format is a real no `f64` holds, and the format's own
    // subtraction returns +inf for it, which is then the value and not a
    // bound. A rule that let +inf through for EVERY width is what left the
    // finite cases unguarded.
    const full = Interval.init(-std.math.floatMax(f64), std.math.floatMax(f64));
    const full_case: Case = .{ .op = .width, .a = full, .b = Interval.init(0.0, 0.0), .s = 0.0 };
    const saturated = std.math.isInf(exactWidth(full));
    const full_ok = holds(full_case, .{ .scalar = full.width() });
    // A mutant answering the finite floatMax there is wrong: the true width
    // is 3.59e308 and no finite `f64` bounds it from below.
    const full_mutant_ok = holds(full_case, .{ .scalar = std.math.floatMax(f64) });

    // `distanceTo` is a value for the same reasons and is judged the same
    // way, on both sides.
    const far: Case = .{ .op = .distance_to, .a = Interval.init(1.0, 2.0), .b = Interval.init(0.0, 0.0), .s = 10.0 };
    const true_gap = exactDistanceTo(far.a, far.s);
    const gap_inflated: f64 = @floatCast(true_gap * 4.0 + 1.0);
    const gap_ok = holds(far, .{ .scalar = far.a.distanceTo(far.s) });
    const gap_mutant_ok = holds(far, .{ .scalar = gap_inflated });
    const gap_infinite_ok = holds(far, .{ .scalar = inf64 });

    reportErr("\n  guard: width, the exact difference of two f64 endpoints, judged as a VALUE\n", .{});
    reportErr("    the true width of [{e}, {e}] is exactly {e}\n", .{ a.lo, a.hi, @as(f64, @floatCast(true_width)) });
    reportErr(
        "    what the library answers ({e})                        -> {s}\n",
        .{ a.width(), if (true_ok) "ACCEPTED" else "REJECTED" },
    );
    reportErr(
        "    a mutant four times too large ({e})                    -> {s}\n",
        .{ inflated, if (inflated_ok) "ACCEPTED" else "rejected" },
    );
    reportErr(
        "    a mutant answering +inf for that finite width          -> {s}\n",
        .{if (infinite_ok) "ACCEPTED" else "rejected"},
    );
    reportErr(
        "    the exact width of the whole format is {e}, and the answer {e} -> {s}\n",
        .{ exactWidth(full), full.width(), if (full_ok) "ACCEPTED" else "REJECTED" },
    );
    reportErr(
        "    a mutant answering floatMax there                     -> {s}\n",
        .{if (full_mutant_ok) "ACCEPTED" else "rejected"},
    );
    reportErr("  guard: the distance from 10 to [1, 2], the same kind of value\n", .{});
    reportErr("    the true distance is exactly {e}\n", .{@as(f64, @floatCast(true_gap))});
    reportErr(
        "    what the library answers ({e})                        -> {s}\n",
        .{ far.a.distanceTo(far.s), if (gap_ok) "ACCEPTED" else "REJECTED" },
    );
    reportErr(
        "    a mutant four times too large ({e})                    -> {s}\n",
        .{ gap_inflated, if (gap_mutant_ok) "ACCEPTED" else "rejected" },
    );
    reportErr(
        "    a mutant answering +inf for it                        -> {s}\n",
        .{if (gap_infinite_ok) "ACCEPTED" else "rejected"},
    );

    try std.testing.expect(true_ok);
    try std.testing.expect(!inflated_ok);
    try std.testing.expect(!infinite_ok);
    try std.testing.expect(saturated);
    try std.testing.expect(full_ok);
    try std.testing.expect(!full_mutant_ok);
    try std.testing.expect(gap_ok);
    try std.testing.expect(!gap_mutant_ok);
    try std.testing.expect(!gap_infinite_ok);
}

// What the library does with an inverted pair, and why the sweep records a
// refusal rather than watching one. Measured, in a checked build and outside
// this binary: every operation on `Interval.init(inf, -inf)` dies with
// SIGABRT, and `src/interval.zig` says why at line 215 -- `init` asserts
// lo <= hi and `inf <= -inf` is false. A trap is an abort and an abort
// inside a test binary takes every other test down with it, which is the
// whole reason the NaN contract needed `tests/nan_probe.zig`; there is no
// in-process way to watch one. So the sweep counts these rows as skipped
// precondition (`Row.unordered`) and this test asks the part of the
// question that CAN be asked in process.
//
// A struct literal rather than `init`, deliberately, and for the reason
// `tests/nan_probe.zig` gives for building its poisoned operand the same
// way: it is how a poisoned interval arrives from outside the type.
test "guard: an inverted pair is refused by init, and hull and intersect never call it" {
    const inverted: Interval = .{ .lo = inf64, .hi = neg_inf64 };

    // `hull` forms its answer from a struct literal and never calls `init`,
    // so it REPAIRS the inversion into something well ordered, which is the
    // only answer a caller can go on to use.
    const repaired = inverted.hull(Interval.init(-1.0, 1.0));
    try std.testing.expectEqual(@as(f64, -1.0), repaired.lo);
    try std.testing.expectEqual(@as(f64, 1.0), repaired.hi);

    // `intersect` reports the pair as disjoint rather than handing the
    // inversion on: lo is above hi, and the null is the claim that the two
    // share nothing, which is as true of an interval that cannot exist as it
    // is of one that genuinely does not meet the other.
    try std.testing.expect(inverted.intersect(Interval.init(-1.0, 1.0)) == null);
    try std.testing.expect(Interval.intersectionOf(&[_]Interval{ inverted, Interval.init(-1.0, 1.0) }) == null);
}
