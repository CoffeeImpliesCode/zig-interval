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
    const t = Interval.init(1.0, 3.0).translate(5.0);
    try std.testing.expectEqual(@as(f64, 6.0), t.lo);
    try std.testing.expectEqual(@as(f64, 8.0), t.hi);
}

test "translate: negative and zero delta" {
    const neg = Interval.init(1.0, 3.0).translate(-5.0);
    try std.testing.expectEqual(@as(f64, -4.0), neg.lo);
    try std.testing.expectEqual(@as(f64, -2.0), neg.hi);

    const zero = Interval.init(1.0, 3.0).translate(0.0);
    try std.testing.expectEqual(@as(f64, 1.0), zero.lo);
    try std.testing.expectEqual(@as(f64, 3.0), zero.hi);
}

test "scale: factor 1 is identity" {
    const s = Interval.init(1.0, 3.0).scale(1.0);
    try std.testing.expectEqual(@as(f64, 1.0), s.lo);
    try std.testing.expectEqual(@as(f64, 3.0), s.hi);
}

test "scale: factor 2 doubles width about midpoint" {
    const s = Interval.init(1.0, 3.0).scale(2.0);
    try std.testing.expectEqual(@as(f64, 0.0), s.lo);
    try std.testing.expectEqual(@as(f64, 4.0), s.hi);
}

test "scale: midpoint preserved and width scaled" {
    const s = Interval.init(1.0, 3.0).scale(0.5);
    try std.testing.expectEqual(@as(f64, 1.5), s.lo);
    try std.testing.expectEqual(@as(f64, 2.5), s.hi);
    try std.testing.expectEqual(@as(f64, 2.0), s.midpoint());
    try std.testing.expectEqual(@as(f64, 1.0), s.width());
}

test "scale: factor 0 collapses to midpoint" {
    const s = Interval.init(1.0, 3.0).scale(0.0);
    try std.testing.expectEqual(@as(f64, 2.0), s.lo);
    try std.testing.expectEqual(@as(f64, 2.0), s.hi);
}

test "scale: negative factor keeps lo <= hi invariant" {
    const s = Interval.init(1.0, 3.0).scale(-1.0);
    try std.testing.expect(s.lo <= s.hi);
    try std.testing.expectEqual(@as(f64, 1.0), s.lo);
    try std.testing.expectEqual(@as(f64, 3.0), s.hi);
}

test "expand: positive margin widens both ends" {
    const e = Interval.init(1.0, 3.0).expand(1.0);
    try std.testing.expectEqual(@as(f64, 0.0), e.lo);
    try std.testing.expectEqual(@as(f64, 4.0), e.hi);
}

test "expand: zero margin is identity" {
    const e = Interval.init(1.0, 3.0).expand(0.0);
    try std.testing.expectEqual(@as(f64, 1.0), e.lo);
    try std.testing.expectEqual(@as(f64, 3.0), e.hi);
}

test "expand: negative margin shrinks both ends" {
    const e = Interval.init(1.0, 3.0).expand(-0.5);
    try std.testing.expectEqual(@as(f64, 1.5), e.lo);
    try std.testing.expectEqual(@as(f64, 2.5), e.hi);
}

test "expand: negative margin at half the width degenerates to a point" {
    const at_bound = Interval.init(1.0, 3.0).expand(-1.0);
    try std.testing.expectEqual(@as(f64, 2.0), at_bound.lo);
    try std.testing.expectEqual(@as(f64, 2.0), at_bound.hi);

    const interior = Interval.init(1.0, 3.0).expand(-0.25);
    try std.testing.expectEqual(@as(f64, 1.25), interior.lo);
    try std.testing.expectEqual(@as(f64, 2.75), interior.hi);
}

test "expand: negative margin on an asymmetric interval" {
    const at_bound = Interval.init(0.0, 10.0).expand(-5.0);
    try std.testing.expectEqual(@as(f64, 5.0), at_bound.lo);
    try std.testing.expectEqual(@as(f64, 5.0), at_bound.hi);

    const interior = Interval.init(0.0, 10.0).expand(-2.5);
    try std.testing.expectEqual(@as(f64, 2.5), interior.lo);
    try std.testing.expectEqual(@as(f64, 7.5), interior.hi);
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

test "scale: negative factor maps the interval onto itself" {
    const a = Interval.init(1.0, 3.0).scale(-1.0);
    try std.testing.expectEqual(@as(f64, 1.0), a.lo);
    try std.testing.expectEqual(@as(f64, 3.0), a.hi);

    const b = Interval.init(-3.0, -1.0).scale(-1.0);
    try std.testing.expectEqual(@as(f64, -3.0), b.lo);
    try std.testing.expectEqual(@as(f64, -1.0), b.hi);
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

/// Assert that got is a sound enclosure of the exact interval
/// [exact_lo, exact_hi] and that both bounds were moved strictly outward.
/// The exact bounds are derived by hand in each test, and the library's
/// own rounding helpers are deliberately not reused here: compared against
/// themselves they would cancel a bug in the widening direction out. A
/// bound left sitting exactly on the true value certifies nothing, so the
/// strict checks fail it.
fn expectEnclosure(got: Interval, exact_lo: f64, exact_hi: f64) !void {
    try std.testing.expect(got.lo <= exact_lo);
    try std.testing.expect(got.hi >= exact_hi);
    try std.testing.expect(got.lo < exact_lo);
    try std.testing.expect(got.hi > exact_hi);
}

/// Assert the shape of an image that contains zero: a lower bound of
/// exactly 0.0, the tightest available, and an upper bound that encloses
/// the true maximum with a widening step of its own.
fn expectZeroBased(got: Interval, exact_hi: f64) !void {
    try std.testing.expectEqual(@as(f64, 0.0), got.lo);
    try std.testing.expect(got.hi >= exact_hi);
    try std.testing.expect(got.hi > exact_hi);
}

test "add: exact sums widen outward" {
    try expectEnclosure(Interval.init(1.0, 3.0).add(Interval.init(2.0, 5.0)), 3.0, 8.0);
    try expectEnclosure(Interval.init(-2.0, 1.0).add(Interval.init(3.0, 4.0)), 1.0, 5.0);
    try expectEnclosure(Interval.init(0.0, 2.0).add(Interval.init(2.0, 4.0)), 2.0, 6.0);
}

test "sub: the lower bound pairs lo with the far endpoint of other" {
    // 1 - 5 = -4, 3 - 2 = 1. Pairing lo with lo would give 1 - 2 = -1.
    try expectEnclosure(Interval.init(1.0, 3.0).sub(Interval.init(2.0, 5.0)), -4.0, 1.0);
    try expectEnclosure(Interval.init(5.0, 7.0).sub(Interval.init(2.0, 3.0)), 2.0, 5.0);
    try expectEnclosure(Interval.init(0.0, 2.0).sub(Interval.init(2.0, 4.0)), -4.0, 0.0);
}

test "neg: endpoints swap" {
    const n = Interval.init(1.0, 3.0).neg();
    try std.testing.expectEqual(@as(f64, -3.0), n.lo);
    try std.testing.expectEqual(@as(f64, -1.0), n.hi);

    // Negation is exact, so no widening shows up.
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
    try expectEnclosure(Interval.init(1.0, 2.0).mul(Interval.init(3.0, 4.0)), 3.0, 8.0);
}

test "mul: both operands negative" {
    try expectEnclosure(Interval.init(-2.0, -1.0).mul(Interval.init(-4.0, -3.0)), 3.0, 8.0);
}

test "mul: positive times negative" {
    try expectEnclosure(Interval.init(1.0, 2.0).mul(Interval.init(-4.0, -3.0)), -8.0, -3.0);
}

test "mul: negative times positive" {
    try expectEnclosure(Interval.init(-2.0, -1.0).mul(Interval.init(3.0, 4.0)), -8.0, -3.0);
}

test "mul: an operand spanning zero" {
    try expectEnclosure(Interval.init(-2.0, 3.0).mul(Interval.init(1.0, 2.0)), -4.0, 6.0);
}

test "mul: a degenerate operand" {
    try expectEnclosure(Interval.init(-3.0, -3.0).mul(Interval.init(2.0, 2.0)), -6.0, -6.0);
}

test "div: positive divisor" {
    try expectEnclosure(Interval.init(4.0, 12.0).div(Interval.init(2.0, 4.0)), 1.0, 6.0);
}

test "div: negative divisor" {
    try expectEnclosure(Interval.init(4.0, 12.0).div(Interval.init(-4.0, -2.0)), -6.0, -1.0);
}

test "div: divisor containing zero gives the whole line, not an empty range" {
    const q = Interval.init(1.0, 2.0).div(Interval.init(-1.0, 1.0));
    try std.testing.expect(q.lo == -std.math.inf(f64));
    try std.testing.expect(q.hi == std.math.inf(f64));

    // Touching zero from one side still counts as containing zero.
    const touch = Interval.init(1.0, 2.0).div(Interval.init(0.0, 1.0));
    try std.testing.expect(touch.lo == -std.math.inf(f64));
    try std.testing.expect(touch.hi == std.math.inf(f64));
}

test "div: degenerate dividend" {
    try expectEnclosure(Interval.init(4.0, 4.0).div(Interval.init(2.0, 4.0)), 1.0, 2.0);
}

test "recip: reciprocal range" {
    try expectEnclosure(Interval.init(2.0, 4.0).recip(), 0.25, 0.5);
    try expectEnclosure(Interval.init(-4.0, -2.0).recip(), -0.5, -0.25);
}

test "recip: an interval containing zero is unbounded" {
    const r = Interval.init(-1.0, 1.0).recip();
    try std.testing.expect(r.lo == -std.math.inf(f64));
    try std.testing.expect(r.hi == std.math.inf(f64));
}

test "abs: positive and negative intervals" {
    try expectEnclosure(Interval.init(1.0, 3.0).abs(), 1.0, 3.0);
    try expectEnclosure(Interval.init(-3.0, -1.0).abs(), 1.0, 3.0);
}

test "abs: an interval spanning zero starts at exactly zero" {
    try expectZeroBased(Interval.init(-2.0, 3.0).abs(), 3.0);
}

test "sqr: positive and negative intervals" {
    try expectEnclosure(Interval.init(1.0, 3.0).sqr(), 1.0, 9.0);
    try expectEnclosure(Interval.init(-3.0, -1.0).sqr(), 1.0, 9.0);
}

test "sqr: an interval spanning zero starts at exactly zero" {
    // 9 is the larger square, so this is the case where treating squaring
    // as monotone would put a lower bound below the smallest real square.
    try expectZeroBased(Interval.init(-2.0, 3.0).sqr(), 9.0);
    try expectZeroBased(Interval.init(-1.0, 1.0).sqr(), 1.0);
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
