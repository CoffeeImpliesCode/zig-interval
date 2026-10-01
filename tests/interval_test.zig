const std = @import("std");
const interval = @import("interval");
const Interval = interval.Interval;
const builtin = @import("builtin");

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

test "halve: a subset of div by two, and tighter where div is cautious" {
    // The property `halve`'s own doc claims, over a sweep chosen for the
    // shapes where the two answers can differ at all: subnormal endpoints,
    // where halving a lost magnitude rounds to a signed zero; the signed
    // zeros themselves; both infinities; and the ends of the range.
    //
    // They differ because `div` pays its underflow repair on every endpoint
    // and `halve` pays it only where its own endpoint actually lost the half.
    // So on a box whose OTHER end is a lost magnitude, `div` steps further out
    // than the truth needs and `halve` does not. The subset relation is what
    // makes the public version the better one to reach for, and it is the
    // whole of what making it public claims.
    // The smallest positive subnormal, spelled out rather than imported.
    // `rounding.min_subnormal` is not re-exported at the package root, and a
    // test is not a reason to widen the public surface for it.
    const tiny: f64 = @bitCast(@as(u64, 1));
    const fmax = std.math.floatMax(f64);
    const cases = [_]Interval{
        Interval.init(1.0, 2.0),
        Interval.init(-2.0, -1.0),
        Interval.init(1.0, 1.0),
        Interval.init(-1.0, -1.0),
        Interval.init(0.0, 1.0),
        Interval.init(-1.0, 1.0),
        Interval.init(-0.0, 1.0),
        Interval.init(0.0, -0.0),
        Interval.init(tiny, tiny),
        Interval.init(-tiny, tiny),
        Interval.init(-tiny, -tiny),
        Interval.init(tiny, 4.0 * tiny),
        Interval.init(-4.0 * tiny, tiny),
        Interval.init(fmax, fmax),
        Interval.init(-fmax, fmax),
        Interval.init(0.0, fmax),
        Interval.init(-std.math.inf(f64), fmax),
        Interval.init(-fmax, std.math.inf(f64)),
    };
    const two = Interval.init(2.0, 2.0);
    for (cases) |c| {
        const h = c.halve();
        const d = c.div(two);
        // Never wider: each end of the halving is inside the division's.
        try std.testing.expect(h.lo >= d.lo);
        try std.testing.expect(h.hi <= d.hi);
        try std.testing.expect(h.lo <= h.hi);
    }
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
    // invalid operation. Only two divisions are invalid, 0 / 0 and
    // inf / inf, and of those only the first needs a zero in the divisor,
    // so the divisor check that returns the whole line has removed it and
    // nothing else. The second needs an infinity in the divisor, survives
    // that check, and is what cornerQuotient answers. So the zero quotient
    // here is exact and a bound at zero is the truth.
    const zero = Interval.init(0.0, 0.0);
    for ([_]f64{ std.math.inf(f64), -std.math.inf(f64) }) |d| {
        const q = zero.div(Interval.init(d, d));
        try expectOrdered(q);
        try std.testing.expect(q.eql(zero));
        try expectEnclosure(q, 0.0, 0.0, .representable);
    }
}

test "div: infinite operands on both sides give the whole line, not a NaN" {
    // The one IEEE-invalid division the divisor check does not remove.
    // 0 / 0 needs a zero in the divisor and is answered above; inf / inf
    // needs an infinity in it, so it reaches all four corners as a NaN.
    // A NaN corner cannot be reduced — @min and @max have no order to
    // apply to it, and four of them reduce to a NaN — so the bounds came
    // out as [-nan, -nan]. That interval contains nothing, which is the
    // worst answer available: every membership query a verification caller
    // makes against it reads "no".
    const inf = std.math.inf(f64);
    const neg_inf = -std.math.inf(f64);
    const pairs = [_][2]Interval{
        .{ Interval.init(inf, inf), Interval.init(inf, inf) },
        .{ Interval.init(neg_inf, neg_inf), Interval.init(neg_inf, neg_inf) },
        .{ Interval.init(inf, inf), Interval.init(neg_inf, neg_inf) },
    };
    for (pairs) |pair| {
        const a = pair[0];
        const b = pair[1];
        const q = a.div(b);
        try expectOrdered(q);
        // A NaN compares false against everything, so lo <= hi passes on
        // one and the ordering check alone cannot see the failure.
        try std.testing.expect(!std.math.isNan(q.lo));
        try std.testing.expect(!std.math.isNan(q.hi));
        // A real divided by itself is 1. The first two pairs hold a common
        // value outright, and the third reaches 1 as the quotient of two
        // magnitudes that grow together, so 1 is in all three true images.
        try std.testing.expect(q.contains(1.0));
    }

    // The other way a corner comes back a NaN is a NaN OPERAND, and it is not
    // the same thing. inf / inf is the indeterminate form: neither operand is
    // a real number, each stands for an unbounded set of finite reals, and the
    // quotient of two unbounded magnitudes is unbounded in both directions.
    // 1 / nan is not indeterminate — one operand is a value that compares
    // false against everything — and the contract for it is the `lo <= hi`
    // check in Interval.init, which a NaN endpoint fails. Answering it with
    // the whole line as well would hand a caller the one answer an enclosure
    // can always use and report no trap at all, so the NaN would be swallowed
    // rather than caught.
    //
    // The endpoint pair below is observable only where that check is elided.
    // In Debug the call aborts, as it is meant to, and a test that made it in
    // this process would take every other test in the file down with it. The
    // abort itself is watched from a child process in every mode, by
    // tests/soundness_test.zig; what is pinned here is the pair of endpoints
    // the elided build hands back, which is the same NaN either way.
    const checked = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;
    if (!checked) {
        const nan = std.math.nan(f64);
        // inf / nan and nan / inf are here beside the other two on purpose:
        // one infinite operand is not the indeterminate form, and a check
        // that asked only about one side would swallow both.
        const poisoned = [_][2]Interval{
            .{ Interval.init(1.0, 2.0), .{ .lo = nan, .hi = nan } },
            .{ .{ .lo = nan, .hi = nan }, Interval.init(1.0, 2.0) },
            .{ Interval.init(inf, inf), .{ .lo = nan, .hi = nan } },
            .{ .{ .lo = nan, .hi = nan }, Interval.init(inf, inf) },
        };
        for (poisoned) |pair| {
            const q = pair[0].div(pair[1]);
            // A NaN compares false against everything, so nothing else can be
            // asked of these endpoints. What they must not be is the whole
            // line, which is what the loop above gets and this must not.
            try std.testing.expect(std.math.isNan(q.lo));
            try std.testing.expect(std.math.isNan(q.hi));
        }
    }
}

test "div: an infinite endpoint beside a finite one keeps the true quotient" {
    // The shapes that reach the guard from one corner rather than all
    // four. [1, inf] over [inf, inf] has two corners of 1 / inf beside two
    // indeterminate ones, and [-inf, -1] over [-inf, -1] has one
    // indeterminate corner beside three finite ones, where -inf / -1 is
    // itself a value the reduction has to carry. The witness on each row
    // is a quotient the true image attains, attained by the pair of values
    // named in the comment beside it.
    const inf = std.math.inf(f64);
    const neg_inf = -std.math.inf(f64);
    const cases = [_]struct { a: Interval, b: Interval, witness: f64 }{
        // x / x for any x past the end of the range, so x = y.
        .{ .a = Interval.init(1.0, inf), .b = Interval.init(inf, inf), .witness = 1.0 },
        // (-1) / (-1) = 1.
        .{ .a = Interval.init(neg_inf, -1.0), .b = Interval.init(neg_inf, -1.0), .witness = 1.0 },
        // 1 / (-1) = -1.
        .{ .a = Interval.init(1.0, inf), .b = Interval.init(neg_inf, -1.0), .witness = -1.0 },
        // (-1) / 1 = -1.
        .{ .a = Interval.init(neg_inf, -1.0), .b = Interval.init(1.0, inf), .witness = -1.0 },
    };
    for (cases) |c| {
        const q = c.a.div(c.b);
        try expectOrdered(q);
        try std.testing.expect(!std.math.isNan(q.lo));
        try std.testing.expect(!std.math.isNan(q.hi));
        try std.testing.expect(q.contains(c.witness));
    }
}

/// Whether the constructor has already normalized the two overflow rays.
/// Every frontier call that would otherwise form an indeterminate sum
/// needs that to have happened first, and needs it to be CHECKED first:
/// read as the points they used to be, those calls hand the constructor a
/// NaN and its ordering check aborts, which in a checked build takes
/// every later test in this process down with it. A failed assertion is
/// the other half of that answer, and the right one — the test fails, the
/// process lives, and the calls below still get their chance to be judged.
fn expectCanonicalRays() !void {
    const inf = std.math.inf(f64);
    const fmax = std.math.floatMax(f64);
    const pos = Interval.init(inf, inf);
    const neg = Interval.init(-inf, -inf);
    try std.testing.expectEqual(fmax, pos.lo);
    try std.testing.expectEqual(inf, pos.hi);
    try std.testing.expectEqual(-inf, neg.lo);
    try std.testing.expectEqual(-fmax, neg.hi);
}

/// The exact real sum of two finite f64 values, as the pair (s, err) of an
/// f128 TwoSum: s + err IS that real sum, with no rounding left in it.
///
/// The pair is not decoration. The sum of two f64 values is exact in f128
/// as long as the span between their exponents fits in f128's 113
/// significand bits, which is the usual case and covers every small
/// integer sum. It stops being exact when that span is wide enough to
/// cross 113, and M - 3 crosses it by a long way: M = (2^53 - 1) * 2^971,
/// so M - 3 needs 971 + 53 = 1024 significand bits and rounds straight
/// back onto M in f128 as well. A comparator built on the rounded sum alone
/// would therefore report the unsafe [M, M] as the right answer for M - 3,
/// and the residual is what says otherwise. Overflow and underflow of f128
/// cannot happen for a sum of finite f64s or for its residual, so the
/// whole argument is arithmetic rather than a range assumption.
fn twoSum(a: f64, b: f64) [2]f128 {
    const fa: f128 = a;
    const fb: f128 = b;
    const s: f128 = fa + fb;
    const bb: f128 = s - fa;
    const err: f128 = (fa - (s - bb)) + (fb - bb);
    return .{ s, err };
}

/// Whether `bound` is at or below the exact real sum of `a` and `b`, judged
/// without rounding the sum.
///
/// A bound off the rounded sum cannot be carried back across it by the
/// residual: the residual is at most half a step of f128 and a step of f64
/// is 2^60 times wider, so an f64 strictly below the rounded sum is
/// strictly below the exact one as well. A bound sitting ON the rounded sum
/// is the case the residual exists for, and its sign is the whole answer: a
/// positive residual is the part of the truth that the rounding dropped
/// BELOW the sum, so a lower bound there is above the sum it was asked to
/// bound.
fn sumBoundLe(bound: f64, a: f64, b: f64) bool {
    const pair = twoSum(a, b);
    const w: f128 = bound;
    if (w != pair[0]) return w < pair[0];
    return pair[1] >= 0;
}

/// Whether `bound` is at or above the exact real sum of `a` and `b`, the
/// mirror of sumBoundLe.
fn sumBoundGe(bound: f64, a: f64, b: f64) bool {
    const pair = twoSum(a, b);
    const w: f128 = bound;
    if (w != pair[0]) return w > pair[0];
    return pair[1] <= 0;
}

test "overflow ray: canonical constructor" {
    // A box whose two ends point the same way holds no real member that an
    // f64 can name, and the only sound thing an f64 can say about it is the
    // ray that reaches the end of the format. `init(+inf, +inf)` supplies
    // the closed overflow ray [floatMax, +inf] and `init(-inf, -inf)` its
    // mirror [-inf, -floatMax]. Both are conservative, and both are
    // CANONICAL, which is the property every consumer reads: no lower bound
    // is +inf and no upper bound is -inf.
    //
    // This is also why the frontier calls below do not abort. Read as the
    // points the ends used to be, +inf meets -inf as inf - inf and
    // inf + (-inf), and in a checked build the constructor's own ordering
    // check refuses the NaN it was handed.
    const inf = std.math.inf(f64);
    const neg_inf = -inf;
    const fmax = std.math.floatMax(f64);

    const pos = Interval.init(inf, inf);
    try expectOrdered(pos);
    try std.testing.expectEqual(fmax, pos.lo);
    try std.testing.expectEqual(inf, pos.hi);
    try std.testing.expect(pos.lo != inf);
    try std.testing.expect(pos.hi != neg_inf);
    try std.testing.expect(pos.signOf() == .positive);

    const neg = Interval.init(neg_inf, neg_inf);
    try expectOrdered(neg);
    try std.testing.expectEqual(neg_inf, neg.lo);
    try std.testing.expectEqual(-fmax, neg.hi);
    try std.testing.expect(neg.lo != inf);
    try std.testing.expect(neg.hi != neg_inf);
    try std.testing.expect(neg.signOf() == .negative);

    // A ray carries the whole half-line it stands for. Each one contains
    // the finite frontier it is named for, reaches no further, and stops
    // short of zero, which is what makes it a ray and not a line.
    try std.testing.expect(pos.contains(fmax));
    try std.testing.expect(!pos.contains(0.0));
    try std.testing.expect(!pos.contains(-fmax));
    try std.testing.expect(neg.contains(-fmax));
    try std.testing.expect(!neg.contains(0.0));
    try std.testing.expect(!neg.contains(fmax));

    // Equality reads the normalized fields, which is the observable half
    // of the change: the ray denotes the same set as the wider pair an
    // unbounded box could be written as, and `eql` says so rather than
    // comparing two bit patterns a caller has to interpret.
    try std.testing.expect(pos.eql(Interval.init(fmax, inf)));
    try std.testing.expect(neg.eql(Interval.init(-inf, -fmax)));

    // Nothing else moved. The whole line has both ends canonical already,
    // a bounded pair is handed back field for field, and a ray with ONE
    // infinite end is a different thing from the ray above: [1, +inf) is
    // an upper-unbounded half-line and is left exactly as it was.
    const line = Interval.init(neg_inf, inf);
    try std.testing.expectEqual(neg_inf, line.lo);
    try std.testing.expectEqual(inf, line.hi);
    const bounded = Interval.init(1.0, 3.0);
    try std.testing.expectEqual(@as(f64, 1.0), bounded.lo);
    try std.testing.expectEqual(@as(f64, 3.0), bounded.hi);
    const wide = Interval.init(-fmax, fmax);
    try std.testing.expectEqual(-fmax, wide.lo);
    try std.testing.expectEqual(fmax, wide.hi);
    const upper_half = Interval.init(1.0, inf);
    try std.testing.expectEqual(@as(f64, 1.0), upper_half.lo);
    try std.testing.expectEqual(inf, upper_half.hi);
    const lower_half = Interval.init(neg_inf, -1.0);
    try std.testing.expectEqual(neg_inf, lower_half.lo);
    try std.testing.expectEqual(@as(f64, -1.0), lower_half.hi);
}

test "overflow ray: the exact sum comparator sees past the f128 rounding" {
    // The comparator is the oracle for the three bounds below, so it is
    // checked against the two answers it exists to disagree with.
    //
    // M - 3 is the frontier one: f128 rounds it back onto M, and M is the
    // nearest f64 at or above it as well, so [M, M] is the answer every
    // rounded comparison in this file would accept and the one the exact
    // sum refuses.
    const m = std.math.floatMax(f64);
    try std.testing.expectEqual(@as(f128, m), twoSum(m, -3.0)[0]);
    try std.testing.expect(!sumBoundLe(m, m, -3.0));
    try std.testing.expect(sumBoundLe(-m, m, -3.0));
    try std.testing.expect(sumBoundGe(m, m, -3.0));
    // The one step below M is where the sound lower bound has to sit.
    try std.testing.expect(sumBoundLe(oneStepBelow(m), m, -3.0));

    // And a residual that is not a frontier artefact at all: the sum of
    // 1e300 and -1e-300 rounds onto 1e300 in f128 and the true sum is
    // below it by 1e-300, so the same signed decision applies. Both
    // operands are named as f64 values on purpose: the literal written
    // here is a decimal with more digits than f64 holds, so widening the
    // literal directly and letting twoSum round it are two different
    // numbers, and the reference has to be the one the operands actually
    // carry.
    const big: f64 = 1e300;
    const small: f64 = -1e-300;
    try std.testing.expectEqual(@as(f128, big), twoSum(big, small)[0]);
    try std.testing.expect(!sumBoundLe(big, big, small));
    try std.testing.expect(sumBoundGe(big, big, small));
}

test "div: a quotient past the end of the range keeps the unbounded answer" {
    // The OTHER use of the two outward steps, and a different case from
    // the constructor's rays. Every operand here is finite, so nothing is
    // read as a ray: the corner itself overflows, and what it stands for
    // is the finite real +/-2 * floatMax that no f64 holds. A lower bound
    // of -floatMax would sit ABOVE that real and a lower bound of +floatMax
    // on the positive side would sit above it too, so the step at the end
    // of the range has to go outward to the infinities rather than back
    // to the finite frontier.
    //
    // The exact quotient is exact in f128 and no oracle is reused: the
    // divisor is a power of two, so scaling floatMax by it doubles the
    // value without any rounding at all. Containment against that widened
    // real is the whole requirement, and it fails on a bound pulled back
    // into the range without demanding any particular width.
    const fmax = std.math.floatMax(f64);
    const half: f64 = 0.5;
    const twice_max: f128 = 2.0 * @as(f128, fmax);
    const down = Interval.init(-fmax, -fmax).div(Interval.init(half, half));
    try expectOrdered(down);
    try std.testing.expect(!std.math.isNan(down.lo));
    try std.testing.expect(!std.math.isNan(down.hi));
    try std.testing.expect(@as(f128, down.lo) <= -twice_max);
    try std.testing.expect(-twice_max <= @as(f128, down.hi));
    const up = Interval.init(-fmax, -fmax).div(Interval.init(-half, -half));
    try expectOrdered(up);
    try std.testing.expect(!std.math.isNan(up.lo));
    try std.testing.expect(!std.math.isNan(up.hi));
    try std.testing.expect(@as(f128, up.lo) <= twice_max);
    try std.testing.expect(twice_max <= @as(f128, up.hi));
}

/// The f64 one representable step below x, written out here rather than
/// imported so the comparator's own oracle does not come from the file
/// under test. Patterns ascend with the value for positives and descend
/// for negatives, so the step this direction takes is the other one in
/// each half of the format.
fn oneStepBelow(x: f64) f64 {
    const bits: u64 = @bitCast(x);
    return @bitCast(if (bits & (@as(u64, 1) << 63) != 0) bits + 1 else bits - 1);
}

test "overflow ray: a sum of the positive ray is bounded from below under M-3" {
    const inf = std.math.inf(f64);
    const fmax = std.math.floatMax(f64);
    const pos = Interval.init(inf, inf);

    // No f64 witnesses any of these three, which is exactly why they are
    // worth a regression. The image of [floatMax, +inf) added to
    // [-3, +inf) runs from floatMax - 3 upward, and floatMax - 3 lies in
    // the gap between floatMax and the step below it: the ULP there is
    // 2^971, so every f64 at or above floatMax - 3 is floatMax or more. A
    // lower bound sitting on floatMax therefore EXCLUDES the real value
    // floatMax - 3 and passes every membership query a consumer working in
    // f64 can ask. Only exact arithmetic sees the gap, which is what the
    // comparator above is for.
    const sum = pos.add(Interval.init(-3.0, inf));
    try expectOrdered(sum);
    try std.testing.expect(sumBoundLe(sum.lo, fmax, -3.0));
    try std.testing.expect(std.math.isInf(sum.hi) and sum.hi > 0.0);

    // A shift is an add against the point [delta, delta], so the same real
    // value is at stake and the same bound has to be under it.
    const shift = pos.translate(-3.0);
    try expectOrdered(shift);
    try std.testing.expect(sumBoundLe(shift.lo, fmax, -3.0));
    try std.testing.expect(std.math.isInf(shift.hi) and shift.hi > 0.0);

    // A margin comes off the low end, so the real value is the same one.
    const wide = pos.expand(3.0);
    try expectOrdered(wide);
    try std.testing.expect(sumBoundLe(wide.lo, fmax, -3.0));
    try std.testing.expect(std.math.isInf(wide.hi) and wide.hi > 0.0);

    // What they do owe is the half-line they stand for: each answer starts
    // below the ray it was built from and reaches up without a bound.
    try std.testing.expect(sum.contains(fmax));
    try std.testing.expect(!sum.contains(0.0));
}

test "overflow ray: a sum of the negative ray is bounded from above over -M+3" {
    const inf = std.math.inf(f64);
    const neg_inf = -inf;
    const fmax = std.math.floatMax(f64);
    const neg = Interval.init(neg_inf, neg_inf);

    // The mirror of the case above, and the same gap from the other side.
    // The image of [-inf, -floatMax] added to [-inf, 3] runs up to
    // -floatMax + 3, and that value lies between -floatMax and the step
    // above it: the ULP there is 2^971 as well. A bound sitting on
    // -floatMax therefore excludes a real value the image takes.
    const sum = neg.add(Interval.init(neg_inf, 3.0));
    try expectOrdered(sum);
    try std.testing.expect(sum.lo == neg_inf);
    try std.testing.expect(sumBoundGe(sum.hi, -fmax, 3.0));

    const shift = neg.translate(3.0);
    try expectOrdered(shift);
    try std.testing.expect(sumBoundGe(shift.hi, -fmax, 3.0));
    try std.testing.expect(shift.lo == neg_inf);

    // A negative margin takes -floatMax - 3 off the high end. That value
    // rounds onto -floatMax, so the outward step is what has to put the
    // bound past it rather than on it.
    const narrow = neg.expand(-3.0);
    try expectOrdered(narrow);
    try std.testing.expect(sumBoundGe(narrow.hi, -fmax, -3.0));
    try std.testing.expect(narrow.lo == neg_inf);
}

test "overflow ray: neg reflects one ray onto the other" {
    const inf = std.math.inf(f64);
    const neg_inf = -inf;
    const fmax = std.math.floatMax(f64);
    const pos = Interval.init(inf, inf);
    const neg = Interval.init(neg_inf, neg_inf);

    // IEEE negation is exact at an infinity, so nothing is widened here.
    // What the constructor adds is that the reflected box is ITSELF
    // canonical, which is the whole difference between a negative ray and
    // the degenerate pair the reflection would otherwise produce: -floatMax
    // has to be the new upper bound, and -inf cannot be an upper bound of
    // anything at all.
    const to_neg = pos.neg();
    try expectOrdered(to_neg);
    try std.testing.expectEqual(neg_inf, to_neg.lo);
    try std.testing.expectEqual(-fmax, to_neg.hi);
    try std.testing.expect(to_neg.hi != neg_inf);
    try std.testing.expect(to_neg.eql(neg));

    // The round trip closes, from either end, and each reflection starts
    // from a ray rather than from a point.
    try std.testing.expect(neg.neg().eql(pos));
    try std.testing.expect(pos.neg().neg().eql(pos));
    try std.testing.expect(neg.neg().neg().eql(neg));
}

test "overflow ray: recip of a ray reaches the reciprocal of its near end" {
    const inf = std.math.inf(f64);
    const neg_inf = -inf;
    const pos = Interval.init(inf, inf);
    const neg = Interval.init(neg_inf, neg_inf);

    // 1 / [floatMax, +inf) is [0, 1/floatMax], and 1/floatMax is an
    // ordinary subnormal f64 of about 5.6e-309. The reciprocal of the ray
    // read as a POINT is a signed zero that the underflow repair widens to
    // one subnormal either side, which is a pair around zero and excludes
    // 1e-310 outright. The reciprocal of the ray as a ray reaches its near
    // end, and the witness is an ordinary membership query.
    const r_pos = pos.recip();
    try expectOrdered(r_pos);
    try std.testing.expect(r_pos.contains(0.0));
    try std.testing.expect(r_pos.contains(1e-310));
    try std.testing.expect(r_pos.hi > 1e-310);
    try std.testing.expect(r_pos.lo < 0.0);

    // The mirror: 1 / (-inf, -floatMax] is [-1/floatMax, 0].
    const r_neg = neg.recip();
    try expectOrdered(r_neg);
    try std.testing.expect(r_neg.contains(0.0));
    try std.testing.expect(r_neg.contains(-1e-310));
    try std.testing.expect(r_neg.lo < -1e-310);
    try std.testing.expect(r_neg.hi > 0.0);
}

test "overflow ray: same-ray subtraction and opposite-ray addition enclose the line" {
    try expectCanonicalRays();
    const inf = std.math.inf(f64);
    const neg_inf = -inf;
    const pos = Interval.init(inf, inf);
    const neg = Interval.init(neg_inf, neg_inf);
    const witnesses = [_]f64{ 0.0, 1.0, -1.0, 1e308, -1e308, 1e-310, -1e-310 };

    // R - R is every real for R = [floatMax, +inf): take the divisor to be
    // floatMax and the dividend to be t * floatMax, which is in the ray for
    // every t there is. Read as the two points the ends used to be, the
    // same call is inf - inf, which a checked build refuses at init.
    const same = pos.sub(pos);
    try expectOrdered(same);
    try std.testing.expect(same.lo == neg_inf and same.hi == inf);
    for (witnesses) |w| try std.testing.expect(same.contains(w));

    // The mirror, and the same line from the other end of the format.
    const same_neg = neg.sub(neg);
    try expectOrdered(same_neg);
    try std.testing.expect(same_neg.lo == neg_inf and same_neg.hi == inf);
    for (witnesses) |w| try std.testing.expect(same_neg.contains(w));

    // The two rays added together: either operand can outrun the other by
    // any amount, so the image is every real and the line is the only
    // answer a bound can be. A negative ray added to a positive one is the
    // order in which inf + (-inf) is formed under the point reading.
    const across = neg.add(pos);
    try expectOrdered(across);
    try std.testing.expect(across.lo == neg_inf and across.hi == inf);
    for (witnesses) |w| try std.testing.expect(across.contains(w));

    // Both orders, then, because they are the same image and not two
    // different ones: write the operands as floatMax + a and -floatMax - b
    // with a and b at or above zero and the sum is a - b, which is every
    // real there is. Neither order can return a narrower answer than that,
    // so both have to come back as the line.
    const across_up = pos.add(neg);
    try expectOrdered(across_up);
    try std.testing.expect(across_up.lo == neg_inf and across_up.hi == inf);
    for (witnesses) |w| try std.testing.expect(across_up.contains(w));
}

test "overflow ray: an infinite shift moves a box by the ray, not by a point" {
    const inf = std.math.inf(f64);
    const neg_inf = -inf;
    const fmax = std.math.floatMax(f64);
    const pos = Interval.init(inf, inf);
    const neg = Interval.init(neg_inf, neg_inf);

    // An infinite delta is the scalar overflow ray, so it carries two
    // endpoints and the shift is the sum against both of them. The witness
    // is a plain membership query: [-floatMax, floatMax] shifted by
    // [floatMax, +inf) has an image running from -floatMax + floatMax = 0
    // upward, so the answer has to contain 0. Shifted by the NUMBER +inf
    // instead, the low end comes back at floatMax, which is above every
    // value the image takes below it.
    const up = Interval.init(-fmax, fmax).translate(inf);
    try expectOrdered(up);
    try std.testing.expect(up.contains(0.0));
    try std.testing.expect(!up.contains(-1.0));
    try std.testing.expect(up.hi == inf);

    // The mirror: shifted by (-inf, -floatMax] the image runs from -inf up
    // to floatMax + (-floatMax) = 0, so the answer has to contain 0 and
    // must not reach past it.
    const down = Interval.init(-fmax, fmax).translate(neg_inf);
    try expectOrdered(down);
    try std.testing.expect(down.contains(0.0));
    try std.testing.expect(!down.contains(1.0));
    try std.testing.expect(down.lo == neg_inf);
    try std.testing.expect(down.hi <= 0.0);

    // The rays shifted by themselves. [floatMax, +inf) added to itself runs
    // from 2 * floatMax upward, which is past every finite f64, so no finite
    // witness of the image exists and the claim is about the bounds: no
    // lower bound may sit above floatMax, which is the tightest sound one,
    // and no upper bound may stand at all. The mirror is the same two
    // claims from the other end of the format.
    const ray_up = pos.translate(inf);
    try expectOrdered(ray_up);
    try std.testing.expect(ray_up.lo == fmax);
    try std.testing.expect(ray_up.hi == inf);

    const ray_down = neg.translate(neg_inf);
    try expectOrdered(ray_down);
    try std.testing.expect(ray_down.lo == neg_inf);
    try std.testing.expect(ray_down.hi == -fmax);
}

test "overflow ray: expand by the positive margin ray is the whole line" {
    try expectCanonicalRays();
    const inf = std.math.inf(f64);
    const neg_inf = -inf;
    const fmax = std.math.floatMax(f64);
    const pos = Interval.init(inf, inf);
    const neg = Interval.init(neg_inf, neg_inf);
    const witnesses = [_]f64{ 0.0, 1.0, -1.0, 1e308, -1e308 };

    // A margin of +inf is the ray [floatMax, +inf), and widening any box by
    // it reaches without a bound in both directions: the canonical body
    // already walks the low end to -inf and leaves the high one at +inf,
    // so no branch is needed for it. Read as the NUMBER +inf instead, the
    // two ends of the positive ray meet as inf - inf at the low end, and
    // a checked build refuses that NaN.
    const from_pos = pos.expand(inf);
    try expectOrdered(from_pos);
    try std.testing.expect(from_pos.lo == neg_inf and from_pos.hi == inf);
    for (witnesses) |w| try std.testing.expect(from_pos.contains(w));

    const from_neg = neg.expand(inf);
    try expectOrdered(from_neg);
    try std.testing.expect(from_neg.lo == neg_inf and from_neg.hi == inf);
    for (witnesses) |w| try std.testing.expect(from_neg.contains(w));

    // A bounded box widens to the same line, and it is the margin that
    // takes it there rather than the box: -floatMax - +inf is -inf and
    // floatMax + +inf is +inf whatever pair the box has.
    const from_bounded = Interval.init(-fmax, fmax).expand(inf);
    try expectOrdered(from_bounded);
    try std.testing.expect(from_bounded.lo == neg_inf and from_bounded.hi == inf);
    for (witnesses) |w| try std.testing.expect(from_bounded.contains(w));
}

test "overflow ray: expand by the negative margin ray needs an unbounded input" {
    try expectCanonicalRays();
    const inf = std.math.inf(f64);
    const neg_inf = -inf;
    const fmax = std.math.floatMax(f64);

    // A margin of -inf is the ray of margins (-inf, -floatMax], every one
    // of which is a legal narrowing of a box wide enough to take it. Its
    // image is the union over that whole ray rather than the answer for the
    // NUMBER -inf, which is the pair (+inf, -inf) and inverts. A bounded
    // box takes no margin that large, which is why the branch there demands
    // an unbounded one. That is a PRECONDITION rather than an unconditional
    // trap: the checked builds diagnose the violation and the unchecked
    // ones answer outside the contract, as for every other invalid interval
    // in this library.
    //
    // [-floatMax, +inf) narrowed by every margin in that ray reaches down
    // to -floatMax - (-floatMax) = 0 and up to +inf, so the union is
    // [0, +inf) and 0 is a bound it attains at the last margin in the ray.
    const up = Interval.init(-fmax, inf).expand(neg_inf);
    try expectOrdered(up);
    try std.testing.expect(up.contains(0.0));
    try std.testing.expect(!up.contains(-1.0));
    try std.testing.expect(up.lo <= 0.0);
    try std.testing.expect(up.hi == inf);

    // The mirror: (-inf, floatMax] narrowed by every such margin reaches
    // down to -inf and up to floatMax - (-floatMax) = 0.
    const down = Interval.init(neg_inf, fmax).expand(neg_inf);
    try expectOrdered(down);
    try std.testing.expect(down.contains(0.0));
    try std.testing.expect(!down.contains(1.0));
    try std.testing.expect(down.lo == neg_inf);
    try std.testing.expect(down.hi >= 0.0);

    // The whole line narrowed by the ray is still the whole line: at least
    // one of the two ends is unbounded in each direction at every margin.
    const line = Interval.init(neg_inf, inf).expand(neg_inf);
    try expectOrdered(line);
    try std.testing.expect(line.lo == neg_inf and line.hi == inf);
}

test "overflow ray: scale of an unbounded box is the identity or the whole line" {
    try expectCanonicalRays();
    const inf = std.math.inf(f64);
    const neg_inf = -inf;
    const line = Interval.init(neg_inf, inf);

    // An unbounded box has no finite midpoint: the sum of its two ends
    // overflows on one side or the other, and the half of it that survives
    // is not the centre of anything. The bounded algorithm would carry
    // that infinity into the sum it forms the centre from and hand the
    // constructor a NaN pair, so the case is answered before the algebra
    // starts — after the factor itself has been checked, because a NaN
    // factor is a scalar the caller got wrong and not an unbounded box.
    //
    // Both answers are forced rather than chosen. At |factor| == 1 a scale
    // maps every box onto itself, and this scale discards the sign of the
    // factor the way it always has, so the identity is the whole image for
    // every finite completion of an unbounded box as well. At any other
    // factor a completion [1, c] grows a half-width proportional to c
    // about a centre that moves with it, and the union over every
    // completion runs out in both directions at once — which is what the
    // line covers, without a centre having been invented for the box.
    for ([_]f64{ 0.0, 1.0, -1.0, 2.0, 0.5, -2.0, 1e308, 1e-308 }) |factor| {
        const scaled = line.scale(factor);
        try expectOrdered(scaled);
        try std.testing.expect(scaled.lo == neg_inf and scaled.hi == inf);
    }

    // The identity, from both ends and under both signs.
    for ([_]f64{ 1.0, -1.0 }) |factor| {
        const upper = Interval.init(1.0, inf);
        const lower = Interval.init(neg_inf, -1.0);
        try std.testing.expect(upper.scale(factor).eql(upper));
        try std.testing.expect(lower.scale(factor).eql(lower));
        try std.testing.expect(line.scale(factor).eql(line));
    }

    // A half-unbounded box at any other factor takes the line, and the two
    // signs of it are the same line. [1, +inf) at 2 has the exact image
    // [2, +inf) and (-inf, -1] at 2 has (-inf, -2], both inside it.
    for ([_]f64{ 0.0, 2.0, -2.0, 0.5 }) |factor| {
        const upper = Interval.init(1.0, inf).scale(factor);
        try expectOrdered(upper);
        try std.testing.expect(upper.lo == neg_inf and upper.hi == inf);
        const lower = Interval.init(neg_inf, -1.0).scale(factor);
        try expectOrdered(lower);
        try std.testing.expect(lower.lo == neg_inf and lower.hi == inf);
    }
}

test "overflow ray: the algebraic operations agree with the rays" {
    const inf = std.math.inf(f64);
    const neg_inf = -inf;
    const fmax = std.math.floatMax(f64);
    const pos = Interval.init(inf, inf);
    const neg = Interval.init(neg_inf, neg_inf);
    const witnesses = [_]f64{ 0.0, 1.0, -1.0, 1e308, -1e308, fmax, -fmax };

    // Canonical in, canonical out: every one of these is fed two rays and
    // has to hand back a pair with no lower bound at +inf and no upper
    // bound at -inf. That is the invariant every consumer now reads, so it
    // is asserted rather than assumed.
    const derived = [_]Interval{
        pos.mul(pos),
        pos.mul(neg),
        neg.mul(pos),
        neg.mul(neg),
        pos.div(pos),
        pos.div(neg),
        pos.abs(),
        neg.abs(),
        pos.sqr(),
        neg.sqr(),
    };
    for (derived) |d| {
        try expectOrdered(d);
        try std.testing.expect(d.lo != inf);
        try std.testing.expect(d.hi != neg_inf);
        try std.testing.expect(!std.math.isNan(d.lo));
        try std.testing.expect(!std.math.isNan(d.hi));
    }

    // Squaring either ray squares to the positive ray and the magnitude of
    // either is the positive ray. Both images start past the end of the
    // format — floatMax squared is well beyond it — so no finite f64 is a
    // member of either and the claim is about the bounds instead: no lower
    // bound may sit above floatMax, the tightest sound one, and no upper
    // bound may stand at all.
    const sq = pos.sqr();
    try std.testing.expect(sq.lo <= fmax);
    try std.testing.expect(sq.hi == inf);
    try std.testing.expect(neg.sqr().eql(sq));
    const magnitude = pos.abs();
    try std.testing.expect(magnitude.lo <= fmax);
    try std.testing.expect(magnitude.hi == inf);
    try std.testing.expect(neg.abs().eql(magnitude));

    // A same-ray quotient is the indeterminate form, and its image is every
    // real: x / x = 1 for x in the ray, and x / floatMax is every real x
    // above floatMax. The line is the only sound answer, so it is the only
    // one there is.
    const quotient = pos.div(pos);
    try std.testing.expect(quotient.lo == neg_inf and quotient.hi == inf);
    for (witnesses) |w| try std.testing.expect(quotient.contains(w));

    // The hull of the two rays is the line, which no narrower answer holds
    // together, and they are disjoint, so the intersection is empty: their
    // common part would have to be at once above floatMax and below
    // -floatMax. Both answers are forced.
    const hulled = pos.hull(neg);
    try std.testing.expect(hulled.lo == neg_inf and hulled.hi == inf);
    try std.testing.expect(pos.intersect(neg) == null);
    const items = [_]Interval{ pos, neg };
    const hulled_of = Interval.hullOf(&items).?;
    try std.testing.expect(hulled_of.lo == neg_inf and hulled_of.hi == inf);
    try std.testing.expect(Interval.intersectionOf(&items) == null);
}

/// The 28 names `interval.ext` publishes, in the order `src/root.zig`
/// writes them, so the two lists can be read against each other. The
/// comparison is a set comparison, so the order carries no meaning.
const ext_names = [_][]const u8{
    "sqrt",  "cbrt",  "pow",   "powf",  "exp",  "exp2",  "expm1",
    "log",   "log2",  "log10", "log1p", "sin",  "cos",   "tan",
    "asin",  "acos",  "atan",  "atan2", "sinh", "cosh",  "tanh",
    "asinh", "acosh", "atanh", "floor", "ceil", "trunc", "round",
};

/// The five names `interval.lp` publishes, in the order `src/root.zig`
/// writes them. A name that reaches the namespace without a line written
/// for it there fails this test, and a name that does not is unreachable
/// from outside the package at all.
const lp_names = [_][]const u8{ "System", "Lin", "Cmp", "Part", "Partition" };

/// Assert that the namespace `namespace` publishes exactly `expected`,
/// naming the namespace `what` in the message when it does not.
///
/// Both halves are needed and neither is enough alone. The names cannot
/// see a declaration added beside the set, because every expected name
/// would still be there; the count cannot see one swapped for another.
/// Equal counts together with every expected name present is equality of
/// the two sets.
///
/// The count is read off `@typeInfo(...).decls` and the names off
/// `@hasDecl`, because only the length of that slice folds: it is a slice
/// of compiler-generated data, so indexing it at compile time does not
/// resolve. The two spellings answer about the same declarations, the
/// public ones, which is the whole of what a namespace publishes.
///
/// `expected` is taken as an array rather than as a slice of names: a
/// comptime-known name is what `@hasDecl` asks for, and a name reached
/// through a slice is not comptime-known however comptime the slice is.
fn expectExactDecls(
    comptime what: []const u8,
    comptime namespace: type,
    comptime expected: anytype,
) !void {
    const published = @typeInfo(namespace).@"struct".decls.len;
    if (published != expected.len) {
        std.debug.print("{s} publishes {d} names, expected {d}:\n", .{
            what,
            published,
            expected.len,
        });
        for (@typeInfo(namespace).@"struct".decls) |d| {
            std.debug.print("  {s}\n", .{d.name});
        }
        return error.UnexpectedPublicNames;
    }
    inline for (expected) |want| {
        if (!@hasDecl(namespace, want)) {
            std.debug.print("{s} does not publish {s}\n", .{ what, want });
            return error.MissingPublicName;
        }
    }
}

/// Every name `src/root.zig` publishes at the TOP level, in the order it
/// writes them. The `ext` and `lp` namespaces have their own exact-set check
/// below; this is the one for the module itself, and it exists because
/// nothing else in the tree names these forty.
///
/// **That gap was real and it was measured.** Deleting any one of these
/// re-exports — `pub const acos = ext_mod.acos;` and the rest — broke nothing
/// at all: the namespace check looks INSIDE `ext`, not at the top level, and
/// the fixture's README transcriptions happen to touch only a handful of
/// these names. A re-export is a promise to consumers and nothing was holding
/// it. Deleting `acos` is a silent breaking change to every caller that used
/// `interval.acos`.
const root_names = [_][]const u8{
    "Interval",
    "Vec",
    "DynVec",
    "mapResult",
    "nextUp",
    "prevDown",
    "piDown",
    "piUp",
    "roundUp",
    "roundDown",
    "ext",
    "lp",
    "sqrt",
    "cbrt",
    "pow",
    "powf",
    "exp",
    "exp2",
    "expm1",
    "log",
    "log2",
    "log10",
    "log1p",
    "sin",
    "cos",
    "tan",
    "asin",
    "acos",
    "atan",
    "atan2",
    "sinh",
    "cosh",
    "tanh",
    "asinh",
    "acosh",
    "atanh",
    "floor",
    "ceil",
    "trunc",
    "round",
};

test "the package root publishes every re-export it promises" {
    // `inline for` makes every name comptime-known, so each `@hasDecl` below
    // is answered by the COMPILER rather than at run time. Deleting a
    // re-export therefore fails the build as a compile error naming the
    // missing member — stronger than a failing assertion, because it cannot
    // be skipped and it costs nothing when it passes.
    //
    // That was measured, not assumed: removing `pub const acos =
    // ext_mod.acos;` from `src/root.zig` fails here with "root source file
    // struct 'root' has no member named 'acos'". Before this test existed,
    // removing it broke nothing at all.
    //
    // What this cannot see is an ADDITION: a module has no decl count to
    // compare an expected list against. The namespace test below carries that
    // side for `ext` and `lp`, where `@typeInfo(...).decls.len` does exist. An
    // extra top-level re-export is caught by the README's API tables going
    // stale, not by this.
    inline for (root_names) |name| {
        if (!@hasDecl(interval, name)) {
            @compileError("src/root.zig no longer publishes " ++ name);
        }
    }
}

test "ext and lp publish exactly the enumerated names" {
    // The public shape of `ext` and `lp`: exactly the names listed above,
    // and nothing else.
    //
    // This is what guards against a stray `pub`. Both namespaces are
    // written out one name at a time in `src/root.zig` rather than aliased
    // to the whole of `interval_ext.zig` and `lp.zig`, because a module
    // alias republishes every `pub` in the file it names and leaves the
    // question of which of them are meant to be public to nothing at all.
    // The declarations are read here off the namespaces as they are
    // published, so a name reaching either of them without a line written
    // for it in `src/root.zig` fails this test. A `pub` added to either
    // source file is not what this catches, and does not need catching: a
    // name absent from the two lists is unreachable from outside the
    // package, which is what enumerating them bought.
    // `interval.ext` and `interval.lp` are struct types, and a type is
    // passed as itself: `@TypeOf` of either one answers `type`, which is
    // the type of the namespace rather than the namespace.
    try expectExactDecls("ext", interval.ext, ext_names);
    try expectExactDecls("lp", interval.lp, lp_names);

    // The other side of the same check, and why this is a test rather than
    // a comment: every name in both lists has to keep resolving, and
    // `@field` is the probe that says so. A name gone missing is a compile
    // error here, which is the right severity for a public name that no
    // longer exists rather than one that answers wrongly.
    comptime {
        for (ext_names) |name| _ = @field(interval, name);
        for (lp_names) |name| _ = @field(interval.lp, name);
    }
}
