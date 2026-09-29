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
