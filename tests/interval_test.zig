const std = @import("std");
const Interval = @import("interval").Interval;

/// Assert that an interval returned by the public API respects the
/// lo <= hi invariant.
fn expectOrdered(i: Interval) !void {
    try std.testing.expect(i.lo <= i.hi);
}

test "contains: endpoint-inclusive membership" {
    const i = Interval.init(1.0, 3.0);
    try std.testing.expect(i.contains(1.0));
    try std.testing.expect(i.contains(2.0));
    try std.testing.expect(i.contains(3.0));
    try std.testing.expect(!i.contains(0.0));
    try std.testing.expect(!i.contains(3.5));
}

test "union: smallest interval covering both" {
    const a = Interval.init(1.0, 3.0);
    const b = Interval.init(2.0, 5.0);
    const u = a.hull(b);
    try std.testing.expectEqual(@as(f64, 1.0), u.lo);
    try std.testing.expectEqual(@as(f64, 5.0), u.hi);

    const c = Interval.init(4.0, 6.0);
    const res = Interval.init(1.0, 2.0).hull(c);
    try std.testing.expectEqual(@as(f64, 1.0), res.lo);
    try std.testing.expectEqual(@as(f64, 6.0), res.hi);
}

test "intersect: overlapping core" {
    const a = Interval.init(1.0, 3.0);
    const b = Interval.init(2.0, 5.0);
    const x = a.intersect(b).?;
    try std.testing.expectEqual(@as(f64, 2.0), x.lo);
    try std.testing.expectEqual(@as(f64, 3.0), x.hi);
}

test "intersect: touching endpoints overlap at a point" {
    const a = Interval.init(0.0, 2.0);
    const b = Interval.init(2.0, 4.0);
    const x = a.intersect(b).?;
    try std.testing.expectEqual(@as(f64, 2.0), x.lo);
    try std.testing.expectEqual(@as(f64, 2.0), x.hi);
}

test "intersect: disjoint returns null" {
    const a = Interval.init(0.0, 1.0);
    const b = Interval.init(2.0, 3.0);
    try std.testing.expect(a.intersect(b) == null);
}

test "width: hi minus lo" {
    try std.testing.expectEqual(@as(f64, 2.0), Interval.init(1.0, 3.0).width());
    try std.testing.expectEqual(@as(f64, 0.0), Interval.init(2.0, 2.0).width());
}

test "overlaps: shared region" {
    try std.testing.expect(Interval.init(1.0, 3.0).overlaps(Interval.init(2.0, 5.0)));
    try std.testing.expect(Interval.init(0.0, 2.0).overlaps(Interval.init(2.0, 4.0)));
    try std.testing.expect(!Interval.init(0.0, 1.0).overlaps(Interval.init(2.0, 3.0)));
    try std.testing.expect(Interval.init(1.0, 3.0).overlaps(Interval.init(1.0, 1.0)));
}

test "subset: containment of intervals" {
    const outer = Interval.init(0.0, 5.0);
    try std.testing.expect(Interval.init(1.0, 2.0).subsetOf(outer));
    try std.testing.expect(outer.subsetOf(outer));
    try std.testing.expect(!outer.subsetOf(Interval.init(1.0, 2.0)));
    try std.testing.expect(!Interval.init(-1.0, 2.0).subsetOf(outer));
    try std.testing.expect(!Interval.init(1.0, 6.0).subsetOf(outer));
}

test "midpoint: center of interval" {
    try std.testing.expectEqual(@as(f64, 2.0), Interval.init(1.0, 3.0).midpoint());
    try std.testing.expectEqual(@as(f64, -0.5), Interval.init(-2.0, 1.0).midpoint());
}

test "midpoint: degenerate interval is that value" {
    try std.testing.expectEqual(@as(f64, 2.0), Interval.init(2.0, 2.0).midpoint());
}

test "clamp: values below, inside, and above" {
    const i = Interval.init(1.0, 3.0);
    try std.testing.expectEqual(@as(f64, 1.0), i.clamp(0.0));
    try std.testing.expectEqual(@as(f64, 2.0), i.clamp(2.0));
    try std.testing.expectEqual(@as(f64, 3.0), i.clamp(5.0));
}

test "clamp: endpoints inclusive" {
    const i = Interval.init(1.0, 3.0);
    try std.testing.expectEqual(@as(f64, 1.0), i.clamp(1.0));
    try std.testing.expectEqual(@as(f64, 3.0), i.clamp(3.0));
}

test "translate: shifts lo and hi by delta" {
    // 1 + 5 = 6 and 3 + 5 = 8. Both are f64, so a bound sitting on them
    // is already correct and only containment is required.
    try expectEnclosure(Interval.init(1.0, 3.0).translate(5.0), 6.0, 8.0, .representable);
}

test "translate: negative and zero delta" {
    // -4 and -2 are f64 too, and a zero shift leaves [1, 3] exactly.
    try expectEnclosure(Interval.init(1.0, 3.0).translate(-5.0), -4.0, -2.0, .representable);
    try expectEnclosure(Interval.init(1.0, 3.0).translate(0.0), 1.0, 3.0, .representable);
}

test "scale: factor 1 is the identity on the image" {
    // A unit factor maps the box onto itself. 1 and 3 are f64, so the
    // result has to contain [1, 3] and owes nothing beyond that.
    try expectEnclosure(Interval.init(1.0, 3.0).scale(1.0), 1.0, 3.0, .representable);
}

test "scale: factor 2 doubles width about midpoint" {
    // The half-width 1 becomes 2 about the midpoint 2, so the image is
    // [0, 4]. The lower bound is a zero, which is its own bound already,
    // so no step is asked for on that side.
    try expectEnclosure(Interval.init(1.0, 3.0).scale(2.0), 0.0, 4.0, .representable);
}

test "scale: midpoint preserved and width scaled" {
    const s = Interval.init(1.0, 3.0).scale(0.5);
    // The half-width 1 becomes 0.5 about the midpoint 2, giving [1.5, 2.5].
    // Both bounds are f64, so containment is the whole requirement.
    try expectEnclosure(s, 1.5, 2.5, .representable);
    // The preserved midpoint is an interior point of the image, so an
    // enclosure that had dropped it would have cut the image in half
    // rather than merely widened it.
    try std.testing.expect(s.contains(2.0));
}

test "scale: factor 0 collects the image at the midpoint" {
    // A zero half-width about the midpoint 2 leaves the single point [2, 2].
    // A result that still spans a range is a widened point: containment
    // accepts it, and no step can be demanded of an exactly attained value.
    try expectEnclosure(Interval.init(1.0, 3.0).scale(0.0), 2.0, 2.0, .representable);
}

test "scale: negative factor keeps lo <= hi invariant" {
    // The sign of the factor is irrelevant to a scale about the midpoint,
    // so the image is [1, 3] again; the invariant is the point of the test.
    try expectEnclosure(Interval.init(1.0, 3.0).scale(-1.0), 1.0, 3.0, .representable);
}

test "expand: positive margin widens both ends" {
    // [0, 4], and 0 is its own lower bound.
    try expectEnclosure(Interval.init(1.0, 3.0).expand(1.0), 0.0, 4.0, .representable);
}

test "expand: zero margin is the identity" {
    // A zero margin leaves [1, 3], whose bounds are f64, so a result
    // sitting on them is correct and only containment is required.
    try expectEnclosure(Interval.init(1.0, 3.0).expand(0.0), 1.0, 3.0, .representable);
}

test "expand: negative margin shrinks both ends" {
    // 1.5 and 2.5 are f64, so only containment is required.
    try expectEnclosure(Interval.init(1.0, 3.0).expand(-0.5), 1.5, 2.5, .representable);
}

test "expand: a margin of half the width leaves only the midpoint" {
    // The image is the single point 2. The result must contain it; a
    // non-degenerate result is a widened point, which containment accepts
    // and which no step can be demanded of.
    try expectEnclosure(Interval.init(1.0, 3.0).expand(-1.0), 2.0, 2.0, .representable);
    try expectEnclosure(Interval.init(1.0, 3.0).expand(-0.25), 1.25, 2.75, .representable);
}

test "expand: negative margin on an asymmetric interval" {
    // The midpoint of [0, 10] is 5, so a margin of -5 collects the image
    // there and a margin of -2.5 leaves [2.5, 7.5]. Both are f64.
    try expectEnclosure(Interval.init(0.0, 10.0).expand(-5.0), 5.0, 5.0, .representable);
    try expectEnclosure(Interval.init(0.0, 10.0).expand(-2.5), 2.5, 7.5, .representable);
}

test "distanceTo: zero inside the interval" {
    const i = Interval.init(1.0, 3.0);
    try std.testing.expectEqual(@as(f64, 0.0), i.distanceTo(2.0));
}

test "distanceTo: zero at the endpoints" {
    const i = Interval.init(1.0, 3.0);
    try std.testing.expectEqual(@as(f64, 0.0), i.distanceTo(1.0));
    try std.testing.expectEqual(@as(f64, 0.0), i.distanceTo(3.0));
}

test "distanceTo: below lo returns distance to lo" {
    const i = Interval.init(1.0, 3.0);
    try std.testing.expectEqual(@as(f64, 1.0), i.distanceTo(0.0));
    try std.testing.expectEqual(@as(f64, 2.0), i.distanceTo(-1.0));
}

test "distanceTo: above hi returns distance to hi" {
    const i = Interval.init(1.0, 3.0);
    try std.testing.expectEqual(@as(f64, 2.0), i.distanceTo(5.0));
    try std.testing.expectEqual(@as(f64, 0.5), i.distanceTo(3.5));
}

test "distanceTo: negative interval" {
    try std.testing.expectEqual(@as(f64, 2.0), Interval.init(-3.0, -1.0).distanceTo(-5.0));
    try std.testing.expectEqual(@as(f64, 0.0), Interval.init(-3.0, -1.0).distanceTo(-2.0));
    try std.testing.expectEqual(@as(f64, 1.0), Interval.init(-3.0, -1.0).distanceTo(0.0));
}

test "hullOf: empty slice returns null" {
    const items: []const Interval = &.{};
    try std.testing.expect(Interval.hullOf(items) == null);
}

test "hullOf: single input returns that interval" {
    const items = [_]Interval{Interval.init(2.0, 5.0)};
    const h = Interval.hullOf(&items).?;
    try std.testing.expectEqual(@as(f64, 2.0), h.lo);
    try std.testing.expectEqual(@as(f64, 5.0), h.hi);
}

test "hullOf: spans min lo and max hi across inputs" {
    const items = [_]Interval{
        Interval.init(4.0, 7.0),
        Interval.init(1.0, 3.0),
        Interval.init(2.0, 9.0),
    };
    const h = Interval.hullOf(&items).?;
    try std.testing.expectEqual(@as(f64, 1.0), h.lo);
    try std.testing.expectEqual(@as(f64, 9.0), h.hi);
}

test "intersectionOf: empty slice returns null" {
    const items: []const Interval = &.{};
    try std.testing.expect(Interval.intersectionOf(items) == null);
}

test "intersectionOf: single input returns that interval" {
    const items = [_]Interval{Interval.init(2.0, 5.0)};
    const x = Interval.intersectionOf(&items).?;
    try std.testing.expectEqual(@as(f64, 2.0), x.lo);
    try std.testing.expectEqual(@as(f64, 5.0), x.hi);
}

test "intersectionOf: common core of overlapping inputs" {
    const items = [_]Interval{
        Interval.init(1.0, 5.0),
        Interval.init(2.0, 6.0),
        Interval.init(3.0, 4.0),
    };
    const x = Interval.intersectionOf(&items).?;
    try std.testing.expectEqual(@as(f64, 3.0), x.lo);
    try std.testing.expectEqual(@as(f64, 4.0), x.hi);
}

test "intersectionOf: disjoint slice returns null" {
    const items = [_]Interval{
        Interval.init(0.0, 1.0),
        Interval.init(2.0, 3.0),
    };
    try std.testing.expect(Interval.intersectionOf(&items) == null);
}

test "intersectionOf: touching endpoints overlap at a point" {
    const items = [_]Interval{
        Interval.init(0.0, 2.0),
        Interval.init(2.0, 4.0),
    };
    const x = Interval.intersectionOf(&items).?;
    try std.testing.expectEqual(@as(f64, 2.0), x.lo);
    try std.testing.expectEqual(@as(f64, 2.0), x.hi);
}

test "init: degenerate lo == hi is accepted" {
    const d = Interval.init(2.0, 2.0);
    try std.testing.expectEqual(@as(f64, 2.0), d.lo);
    try std.testing.expectEqual(@as(f64, 2.0), d.hi);
    try std.testing.expectEqual(@as(f64, 0.0), d.width());
    try std.testing.expectEqual(@as(f64, 2.0), d.midpoint());
}

test "scale: a negative factor maps the interval onto itself" {
    // The image is [1, 3] and [-3, -1]: the sign of the factor reorders the
    // endpoints without changing the extent, which is what lo <= hi has to
    // survive. Every bound is f64, so only containment is required.
    try expectEnclosure(Interval.init(1.0, 3.0).scale(-1.0), 1.0, 3.0, .representable);
    try expectEnclosure(Interval.init(-3.0, -1.0).scale(-1.0), -3.0, -1.0, .representable);
}

test "invariant: every interval-returning operation yields lo <= hi" {
    const base = Interval.init(1.0, 3.0);
    const other = Interval.init(2.0, 5.0);
    const items = [_]Interval{ base, other, Interval.init(0.0, 4.0) };

    try expectOrdered(base);
    try expectOrdered(base.hull(other));
    try expectOrdered(Interval.hullOf(&items).?);
    try expectOrdered(base.intersect(other).?);
    try expectOrdered(Interval.intersectionOf(&items).?);
    try expectOrdered(base.translate(-5.0));
    try expectOrdered(base.scale(2.0));
    try expectOrdered(base.scale(-1.0));
    try expectOrdered(base.scale(0.0));
    try expectOrdered(base.expand(1.0));
    try expectOrdered(base.expand(-0.5));
}

/// Exact widening of an f64 to f128. Every f64 is an f128, so this loses
/// nothing, and two f64 values need 53 + 53 = 106 significand bits where
/// f128 carries 113, so their sum and their product are exact here. The
/// exact image of an operation is therefore available as the real number
/// it is rather than as a rounding of it, which is what lets a test state
/// an extremum that no f64 holds.
inline fn ex(x: f64) f128 {
    return @as(f128, x);
}

/// Whether the exact real extremum of the expression under test is itself
/// an f64. It selects how strictly a returned bound is checked, and the
/// choice is made per case rather than once for the file.
const Exactness = enum {
    /// The exact extremum is not an f64. A sound bound cannot land on it,
    /// so a result that reaches no further than the machine's own
    /// round-to-nearest answer has performed no outward step at all.
    /// Demanding the step is sound to demand, and it is what catches a
    /// missing one.
    unrepresentable,
    /// The exact extremum IS an f64, so a bound that lands on it is
    /// already correct and no step is required. Demanding one there would
    /// be demanding a wider result than correctness requires, and would
    /// fail an implementation that tightened legitimately: scaling by
    /// 1.0 maps a box onto itself, and a zero is already its own bound.
    representable,
};

/// How much wider than the exact image a returned bound may be, as a
/// fraction of the image's magnitude. Every widening these operations
/// apply is a rounding-order effect of order 1e-16, so this is not a
/// measure of the step: it is a sanity bound, and it fails a result that
/// is merely huge — the whole line, a mis-paired corner, a percent of
/// slack — while leaving a few steps of tightening or widening free.
const width_slack: f128 = 1e-9;

/// Assert that `got` is a sound enclosure of the exact interval
/// [exact_lo, exact_hi], that it respects the lo <= hi invariant, and that
/// it is not wildly wider than the truth.
///
/// The exact bounds are f128 so that a case whose extremum is not an f64
/// can state it. Written as an f64 it would be rounded onto a neighbour,
/// and the test would then pass or fail for a reason that has nothing to
/// do with the library. The library's own rounding helpers are
/// deliberately not reused here either: compared against themselves they
/// would cancel a bug in the widening direction out.
///
/// WHICH FORM TO ASK FOR, decided per case:
///
///   * `.unrepresentable` when the exact extremum is provably not an f64.
///     Containment alone would then be satisfied by a bound sitting on the
///     round-to-nearest answer, since that answer is within half an ULP of
///     the truth, so this form also requires each bound to reach at least
///     one representable step outside it. The step is required for
///     soundness, so demanding it is sound, and this is the form that
///     catches a missing one.
///
///   * `.representable` when the exact extremum is itself an f64. A bound
///     that lands on it is already correct, so only containment is
///     asserted. This is also the form whenever an exact bound is a zero,
///     which is its own bound already.
fn expectEnclosure(got: Interval, exact_lo: f128, exact_hi: f128, exactness: Exactness) !void {
    try expectOrdered(got);
    try std.testing.expect(ex(got.lo) <= exact_lo);
    try std.testing.expect(ex(got.hi) >= exact_hi);
    if (exactness == .unrepresentable) {
        try std.testing.expect(got.lo < @as(f64, @floatCast(exact_lo)));
        try std.testing.expect(got.hi > @as(f64, @floatCast(exact_hi)));
    }
    const excess = ex(got.hi) - ex(got.lo) - (exact_hi - exact_lo);
    try std.testing.expect(excess <= width_slack * (@abs(exact_lo) + @abs(exact_hi) + 1.0));
}

test "add: the corners are the two same-signed sums" {
    // 1 + 2 = 3 and 3 + 5 = 8. Both bounds are f64, so a bound that
    // landed on them would be correct and only containment is required.
    try expectEnclosure(Interval.init(1.0, 3.0).add(Interval.init(2.0, 5.0)), 3.0, 8.0, .representable);
    try expectEnclosure(Interval.init(-2.0, 1.0).add(Interval.init(3.0, 4.0)), 1.0, 5.0, .representable);
    try expectEnclosure(Interval.init(0.0, 2.0).add(Interval.init(2.0, 4.0)), 2.0, 6.0, .representable);
}

test "sub: the lower bound pairs lo with the far endpoint of other" {
    // 1 - 5 = -4, 3 - 2 = 1. Pairing lo with lo would give 1 - 2 = -1,
    // which does not contain -4, so the enclosure discriminates the
    // pairing on its own. All the bounds here are f64.
    try expectEnclosure(Interval.init(1.0, 3.0).sub(Interval.init(2.0, 5.0)), -4.0, 1.0, .representable);
    try expectEnclosure(Interval.init(5.0, 7.0).sub(Interval.init(2.0, 3.0)), 2.0, 5.0, .representable);
    // 2 - 2 = 0, and an upper bound of zero is attained exactly: a zero is
    // its own bound, so a step past it would replace an exact answer with a
    // weaker one. Containment is the only claim available here.
    try expectEnclosure(Interval.init(0.0, 2.0).sub(Interval.init(2.0, 4.0)), -4.0, 0.0, .representable);
}

test "neg: endpoints swap" {
    // Negation is the one algebraic operation with no rounding in it, so
    // here exact equality IS the guarantee rather than a pinned artefact:
    // the image of [lo, hi] is exactly [-hi, -lo] and widening it would
    // make the answer worse.
    const n = Interval.init(1.0, 3.0).neg();
    try std.testing.expectEqual(@as(f64, -3.0), n.lo);
    try std.testing.expectEqual(@as(f64, -1.0), n.hi);
    try std.testing.expect(n.neg().eql(Interval.init(1.0, 3.0)));
}

test "neg: an interval spanning zero" {
    const n = Interval.init(-2.0, 3.0).neg();
    try std.testing.expectEqual(@as(f64, -3.0), n.lo);
    try std.testing.expectEqual(@as(f64, 2.0), n.hi);
}

test "neg: a degenerate interval stays degenerate" {
    const n = Interval.init(2.0, 2.0).neg();
    try std.testing.expectEqual(@as(f64, -2.0), n.lo);
    try std.testing.expectEqual(@as(f64, -2.0), n.hi);
}

test "mul: both operands positive" {
    // The smallest product is 1*3 = 3 and the largest 2*4 = 8, both f64.
    try expectEnclosure(Interval.init(1.0, 2.0).mul(Interval.init(3.0, 4.0)), 3.0, 8.0, .representable);
}

test "mul: both operands negative" {
    // 1*3 = 3 and 2*4 = 8: the smallest product pairs the two endpoints of
    // smallest magnitude, so the image is positive and its bounds are f64.
    try expectEnclosure(Interval.init(-2.0, -1.0).mul(Interval.init(-4.0, -3.0)), 3.0, 8.0, .representable);
}

test "mul: positive times negative" {
    // The four products are -4, -3, -8 and -6, so the image is [-8, -3]:
    // the minimum is 2*(-4), the pairing of the two largest magnitudes.
    try expectEnclosure(Interval.init(1.0, 2.0).mul(Interval.init(-4.0, -3.0)), -8.0, -3.0, .representable);
}

test "mul: negative times positive" {
    // The mirror of the case above, from (-2)*4 = -8 to (-1)*3 = -3.
    try expectEnclosure(Interval.init(-2.0, -1.0).mul(Interval.init(3.0, 4.0)), -8.0, -3.0, .representable);
}

test "mul: an operand spanning zero" {
    // The image straddles zero: -2*2 = -4 is the minimum and 3*2 = 6 the
    // maximum. A reduction that missed the negative corner would return a
    // lower bound of 0, which does not contain -4.
    try expectEnclosure(Interval.init(-2.0, 3.0).mul(Interval.init(1.0, 2.0)), -4.0, 6.0, .representable);
}

test "mul: a degenerate operand" {
    // -3*2 = -6, an f64, so the enclosure has to contain it and nothing
    // more is required of the step on either side.
    try expectEnclosure(Interval.init(-3.0, -3.0).mul(Interval.init(2.0, 2.0)), -6.0, -6.0, .representable);
}

test "div: positive divisor" {
    // The quotient runs from 4/4 = 1 to 12/2 = 6, both f64, so containment
    // is the whole requirement. The exact image of a quotient is not exact
    // even in f128, so the non-representable case of this operation is the
    // cross-multiplied oracle in soundness_test.zig, not this file.
    try expectEnclosure(Interval.init(4.0, 12.0).div(Interval.init(2.0, 4.0)), 1.0, 6.0, .representable);
}

test "div: negative divisor" {
    // The four quotients are -1, -2, -3 and -6, so the image is [-6, -1]:
    // the minimum pairs the largest dividend with the divisor nearest zero.
    // Every bound is f64, so only containment is required.
    try expectEnclosure(Interval.init(4.0, 12.0).div(Interval.init(-4.0, -2.0)), -6.0, -1.0, .representable);
}

test "div: divisor containing zero gives the whole line, not an empty range" {
    // The two infinities are a documented contract value here, not the
    // output of a rounding step, so they are asserted exactly.
    const q = Interval.init(1.0, 2.0).div(Interval.init(-1.0, 1.0));
    try std.testing.expect(q.lo == -std.math.inf(f64));
    try std.testing.expect(q.hi == std.math.inf(f64));

    // Touching zero from one side still counts as containing zero.
    const touch = Interval.init(1.0, 2.0).div(Interval.init(0.0, 1.0));
    try std.testing.expect(touch.lo == -std.math.inf(f64));
    try std.testing.expect(touch.hi == std.math.inf(f64));
}

test "div: degenerate dividend" {
    // 4/4 = 1 and 4/2 = 2, both f64, so only containment is required.
    try expectEnclosure(Interval.init(4.0, 4.0).div(Interval.init(2.0, 4.0)), 1.0, 2.0, .representable);
}

test "recip: reciprocal range" {
    // 1/4 = 0.25 and 1/2 = 0.5, and their reflections likewise: all four
    // bounds are f64, so no step is required of them.
    try expectEnclosure(Interval.init(2.0, 4.0).recip(), 0.25, 0.5, .representable);
    try expectEnclosure(Interval.init(-4.0, -2.0).recip(), -0.5, -0.25, .representable);
}

test "recip: an interval containing zero is unbounded" {
    // As in div, the whole line is the contract rather than a rounding.
    const r = Interval.init(-1.0, 1.0).recip();
    try std.testing.expect(r.lo == -std.math.inf(f64));
    try std.testing.expect(r.hi == std.math.inf(f64));
}

test "abs: positive and negative intervals" {
    // The image of an abs is a pair of the endpoints with their signs
    // dropped, so every exact bound is an f64 whichever side the interval
    // sits on, and containment is the whole requirement.
    try expectEnclosure(Interval.init(1.0, 3.0).abs(), 1.0, 3.0, .representable);
    try expectEnclosure(Interval.init(-3.0, -1.0).abs(), 1.0, 3.0, .representable);
}

test "abs: an interval spanning zero starts at exactly zero" {
    const a = Interval.init(-2.0, 3.0).abs();
    // 0.0 is the tightest lower bound there is, since a point of the
    // interval maps to zero itself, so it is a contract value and is
    // asserted exactly. The upper bound 3 is an f64 endpoint, so only
    // containment is required of it.
    try std.testing.expectEqual(@as(f64, 0.0), a.lo);
    try expectEnclosure(a, 0.0, 3.0, .representable);
}

test "sqr: positive and negative intervals" {
    // 1^2 = 1 and 3^2 = 9, both f64, so only containment is required.
    try expectEnclosure(Interval.init(1.0, 3.0).sqr(), 1.0, 9.0, .representable);
    try expectEnclosure(Interval.init(-3.0, -1.0).sqr(), 1.0, 9.0, .representable);
}

test "sqr: an interval spanning zero starts at exactly zero" {
    // 9 is the larger square, so this is the case where treating squaring
    // as monotone would put a lower bound below the smallest real square.
    // Zero is the tightest lower bound a square can have, so it is a
    // contract value and is asserted exactly; 9 and 1 are f64, so the
    // upper bounds only have to enclose them.
    const wide = Interval.init(-2.0, 3.0).sqr();
    try std.testing.expectEqual(@as(f64, 0.0), wide.lo);
    try expectEnclosure(wide, 0.0, 9.0, .representable);

    const narrow = Interval.init(-1.0, 1.0).sqr();
    try std.testing.expectEqual(@as(f64, 0.0), narrow.lo);
    try expectEnclosure(narrow, 0.0, 1.0, .representable);
}

test "widening: an exact value no f64 holds forces a step outward" {
    // Every case above is built from small integers, so every exact bound
    // in it is an f64 and only containment can be demanded. These are the
    // other kind. 0.1, 0.2, 0.3, 0.5, 0.7 and 0.9 are the f64 neighbours
    // of the tenths, and no f64 is their sum, difference or product in the
    // orders used below, so a result that stopped on the machine's own
    // round-to-nearest answer would enclose no real value at all. The
    // exact bounds are formed in f128, where an f64 times an f64 is exact,
    // and the strict form then requires the step that soundness needs.
    //
    // abs is absent because the image of an abs is a pair of the endpoints
    // themselves and is therefore always f64. div and recip are absent
    // because a quotient is not exact even in f128; their guarantee is
    // held by the cross-multiplied oracle in soundness_test.zig.
    try expectEnclosure(
        Interval.init(0.1, 0.1).add(Interval.init(0.7, 0.7)),
        ex(0.1) + ex(0.7),
        ex(0.1) + ex(0.7),
        .unrepresentable,
    );
    // The pairing crosses: 0.1 - 1.1 is the minimum and 0.2 - 0.9 the
    // maximum, and neither is an f64.
    try expectEnclosure(
        Interval.init(0.1, 0.2).sub(Interval.init(0.9, 1.1)),
        ex(0.1) - ex(1.1),
        ex(0.2) - ex(0.9),
        .unrepresentable,
    );
    try expectEnclosure(
        Interval.init(0.1, 0.1).mul(Interval.init(0.7, 0.7)),
        ex(0.1) * ex(0.7),
        ex(0.1) * ex(0.7),
        .unrepresentable,
    );
    // The square of an endpoint is not the endpoint: 0.1 * 0.1 and
    // 0.3 * 0.3 are both inexact in f64.
    try expectEnclosure(
        Interval.init(0.1, 0.3).sqr(),
        ex(0.1) * ex(0.1),
        ex(0.3) * ex(0.3),
        .unrepresentable,
    );
    // The affine operations form sums, and 1 + 0.1 and 1 - 0.1 are two of
    // them. A widening that only shifted the round-to-nearest answer would
    // put a bound on the wrong side of the true value.
    try expectEnclosure(
        Interval.init(1.0, 3.0).translate(0.1),
        ex(1.0) + ex(0.1),
        ex(3.0) + ex(0.1),
        .unrepresentable,
    );
    try expectEnclosure(
        Interval.init(1.0, 3.0).expand(0.1),
        ex(1.0) - ex(0.1),
        ex(3.0) + ex(0.1),
        .unrepresentable,
    );
    // scale forms the midpoint plus or minus the scaled half-width, and
    // 2 + 0.1 is neither an f64.
    try expectEnclosure(
        Interval.init(1.0, 3.0).scale(0.1),
        ex(2.0) - ex(0.1),
        ex(2.0) + ex(0.1),
        .unrepresentable,
    );
}

test "eql: true only when both endpoints match" {
    try std.testing.expect(Interval.init(1.0, 3.0).eql(Interval.init(1.0, 3.0)));
    try std.testing.expect(!Interval.init(1.0, 3.0).eql(Interval.init(1.0, 4.0)));
    try std.testing.expect(!Interval.init(1.0, 3.0).eql(Interval.init(0.0, 3.0)));
    // Containment is not equality.
    try std.testing.expect(!Interval.init(1.0, 3.0).eql(Interval.init(0.0, 4.0)));
}

test "ne: the complement of eql" {
    try std.testing.expect(Interval.init(1.0, 3.0).ne(Interval.init(1.0, 4.0)));
    try std.testing.expect(Interval.init(1.0, 3.0).ne(Interval.init(0.0, 3.0)));
    try std.testing.expect(!Interval.init(1.0, 3.0).ne(Interval.init(1.0, 3.0)));
}

test "lt: certain strict order, false on overlap" {
    try std.testing.expect(Interval.init(1.0, 2.0).lt(Interval.init(3.0, 4.0)));
    // Touching is not strict.
    try std.testing.expect(!Interval.init(1.0, 2.0).lt(Interval.init(2.0, 4.0)));
    // Overlap makes the relation merely possible, so it is not reported.
    try std.testing.expect(!Interval.init(1.0, 3.0).lt(Interval.init(2.0, 5.0)));
    try std.testing.expect(!Interval.init(1.0, 3.0).lt(Interval.init(1.0, 3.0)));
}

test "le: certain weak order, false on overlap" {
    try std.testing.expect(Interval.init(0.0, 2.0).le(Interval.init(2.0, 4.0)));
    try std.testing.expect(Interval.init(1.0, 2.0).le(Interval.init(3.0, 4.0)));
    try std.testing.expect(!Interval.init(1.0, 3.0).le(Interval.init(2.0, 5.0)));
    try std.testing.expect(!Interval.init(1.0, 3.0).le(Interval.init(0.0, 5.0)));
}

test "gt: certain strict order, false on overlap" {
    try std.testing.expect(Interval.init(3.0, 4.0).gt(Interval.init(1.0, 2.0)));
    try std.testing.expect(!Interval.init(2.0, 4.0).gt(Interval.init(1.0, 2.0)));
    try std.testing.expect(!Interval.init(2.0, 5.0).gt(Interval.init(1.0, 3.0)));
    try std.testing.expect(!Interval.init(1.0, 3.0).gt(Interval.init(1.0, 3.0)));
}

test "ge: certain weak order, false on overlap" {
    try std.testing.expect(Interval.init(2.0, 4.0).ge(Interval.init(1.0, 2.0)));
    try std.testing.expect(Interval.init(3.0, 4.0).ge(Interval.init(1.0, 2.0)));
    try std.testing.expect(!Interval.init(2.0, 5.0).ge(Interval.init(1.0, 3.0)));
    try std.testing.expect(!Interval.init(1.0, 3.0).ge(Interval.init(0.0, 5.0)));
}

test "invariant: arithmetic results keep lo <= hi, infinities included" {
    const pairs = [_][2]Interval{
        .{ Interval.init(1.0, 3.0), Interval.init(-2.0, 2.0) },
        .{ Interval.init(-1.0, 1.0), Interval.init(1.0, 3.0) },
        .{ Interval.init(0.0, 0.0), Interval.init(-4.0, 4.0) },
        .{ Interval.init(1.0, 3.0), Interval.init(std.math.inf(f64), std.math.inf(f64)) },
        .{ Interval.init(-std.math.inf(f64), -std.math.inf(f64)), Interval.init(1.0, 3.0) },
        .{ Interval.init(-std.math.inf(f64), 3.0), Interval.init(1.0, 2.0) },
        .{ Interval.init(1.0, 2.0), Interval.init(-std.math.inf(f64), std.math.inf(f64)) },
        .{ Interval.init(-std.math.inf(f64), std.math.inf(f64)), Interval.init(-1.0, 1.0) },
        .{ Interval.init(-std.math.inf(f64), std.math.inf(f64)), Interval.init(2.0, 4.0) },
        .{ Interval.init(1.0, 2.0), Interval.init(-std.math.inf(f64), -1.0) },
    };
    for (pairs) |pair| {
        const a = pair[0];
        const b = pair[1];
        try expectOrdered(a.add(b));
        try expectOrdered(a.sub(b));
        try expectOrdered(a.mul(b));
        try expectOrdered(a.div(b));
        try expectOrdered(a.abs());
        try expectOrdered(a.sqr());
        // A zero-free operand keeps its reciprocal ordered, however
        // extreme the operand is.
        if (!a.contains(0.0)) try expectOrdered(a.recip());
    }

    try expectOrdered(Interval.init(1.0, 2.0).recip());
    try expectOrdered(Interval.init(-std.math.inf(f64), 3.0).abs());
    try expectOrdered(Interval.init(-std.math.inf(f64), 3.0).sqr());
    try expectOrdered(Interval.init(-std.math.inf(f64), -1.0).abs());
    try expectOrdered(Interval.init(-std.math.inf(f64), -1.0).sqr());
    const far_divisor = Interval.init(std.math.inf(f64), std.math.inf(f64));
    try expectOrdered(Interval.init(2.0, 4.0).div(far_divisor));
}

test "mul: a degenerate zero factor collapses the image to zero" {
    // The product of the degenerate set {0} with anything is {0}, because
    // zero times a real is zero and the other factor is irrelevant. Each
    // partner below has an infinite endpoint somewhere, which is where
    // IEEE 754 answers 0 * inf with a NaN and a NaN corner cannot be
    // reduced into a bound. eql is the library's own statement that two
    // intervals denote the same set, and -0.0 and +0.0 are the same set,
    // so it asks for [0, 0] exactly as the image asks for it.
    const zero = Interval.init(0.0, 0.0);
    const partners = [_]Interval{
        Interval.init(-std.math.inf(f64), std.math.inf(f64)),
        Interval.init(std.math.inf(f64), std.math.inf(f64)),
        Interval.init(-std.math.inf(f64), -std.math.inf(f64)),
        Interval.init(-std.math.inf(f64), 0.0),
        Interval.init(0.0, std.math.inf(f64)),
        Interval.init(-std.math.floatMax(f64), std.math.floatMax(f64)),
        Interval.init(std.math.floatMax(f64), std.math.floatMax(f64)),
        Interval.init(-std.math.floatMax(f64), -std.math.floatMax(f64)),
        Interval.init(-std.math.floatMax(f64), 0.0),
        Interval.init(0.0, std.math.floatMax(f64)),
        Interval.init(-1.0, 1.0),
        Interval.init(1.0, 1.0),
    };
    for (partners) |p| {
        const forward = p.mul(zero);
        const backward = zero.mul(p);
        try expectOrdered(forward);
        try expectOrdered(backward);
        try std.testing.expect(forward.eql(zero));
        try std.testing.expect(backward.eql(zero));
        // The image is a point, and a widened point is still an
        // enclosure, but eql above already demands there be no width.
        try expectEnclosure(forward, 0.0, 0.0, .representable);
        try expectEnclosure(backward, 0.0, 0.0, .representable);
    }
    // A signed zero operand is the same set and has to answer the same way,
    // with the sign rule rather than the set deciding which pattern comes
    // out.
    const signed = Interval.init(-0.0, 0.0);
    try std.testing.expect(Interval.init(-std.math.inf(f64), std.math.inf(f64)).mul(signed).eql(zero));
    try std.testing.expect(signed.mul(Interval.init(-std.math.inf(f64), std.math.inf(f64))).eql(zero));
}

test "mul: a zero factor keeps an attained zero at zero" {
    // Two cases that look alike and must not be answered alike. Here a
    // factor is exactly zero, so the product is exactly zero, nothing was
    // lost, and a bound at zero is the truth rather than a gap. Stepping
    // out to the smallest subnormal would be the underflow repair, and
    // applying it here would replace an exact answer with a weaker one.
    const zero = Interval.init(0.0, 0.0);
    const tiny = Interval.init(1e-200, 1e-200);
    const product = zero.mul(tiny);
    try std.testing.expect(product.eql(zero));
    try expectEnclosure(product, 0.0, 0.0, .representable);
}

test "mul: an underflowed corner is still repaired" {
    // The mirror of the case above, and the reason the zero-factor rule
    // cannot be stated as "a zero extremum always steps out". Neither
    // factor is zero here, so the exact product 1e-400 is a real positive
    // number that f64 could not hold, and the bound has to reach outside
    // it. The step goes out on both sides: the extremum came back as a
    // zero of no usable sign, and roundDown of an underflowed positive
    // zero stays at that zero, which would exclude the very value that
    // was lost.
    const tiny = Interval.init(1e-200, 1e-200);
    const product = tiny.mul(tiny);
    try expectOrdered(product);
    try std.testing.expect(product.contains(0.0));
    try std.testing.expect(product.hi > 0.0);
}

test "mul: a zero the image attains stays inside the bound" {
    // The product set holds 0 whenever either factor can be 0, because the
    // other factor is never empty. A bound that stopped short of 0 here
    // would exclude a member of the very set it is enclosing, and the
    // reduction is where that happens: a zero corner has to survive the
    // min and the max as a zero rather than arrive as a NaN and be
    // dropped by them.
    const cases = [_][2]Interval{
        .{ Interval.init(-std.math.inf(f64), -std.math.inf(f64)), Interval.init(-std.math.inf(f64), 0.0) },
        .{ Interval.init(-std.math.inf(f64), -std.math.inf(f64)), Interval.init(0.0, 0.0) },
        .{ Interval.init(0.0, 1.0), Interval.init(1.0, std.math.inf(f64)) },
        .{ Interval.init(-std.math.inf(f64), -std.math.inf(f64)), Interval.init(0.0, 1.0) },
    };
    for (cases) |pair| {
        const a = pair[0];
        const b = pair[1];
        try std.testing.expect(a.contains(0.0) or b.contains(0.0));
        try expectOrdered(a.mul(b));
        try std.testing.expect(a.mul(b).contains(0.0));
        try std.testing.expect(b.mul(a).contains(0.0));
    }
}

test "div: a zero dividend over an infinite divisor is an exact zero" {
    // The product side of this file has a rule about a zero factor, and the
    // question is whether the quotient needs the same one. It does not, and
    // the reason is that IEEE 754 defines 0 / inf: it is a zero, not an
    // invalid operation. Both sources of a NaN quotient, 0 / 0 and
    // inf / inf, need a zero in the divisor, and the divisor check that
    // returns the whole line has already removed every one of them. So the
    // zero quotient here is exact and a bound at zero is the truth.
    const zero = Interval.init(0.0, 0.0);
    for ([_]f64{ std.math.inf(f64), -std.math.inf(f64) }) |d| {
        const q = zero.div(Interval.init(d, d));
        try expectOrdered(q);
        try std.testing.expect(q.eql(zero));
        try expectEnclosure(q, 0.0, 0.0, .representable);
    }
}
