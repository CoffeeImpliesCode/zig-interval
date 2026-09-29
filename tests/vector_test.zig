const std = @import("std");
const interval = @import("interval");
const Interval = interval.Interval;

/// The result must contain the exact value and must not reach more than
/// one ULP past it on either side. Together the two bounds pin the
/// outward-rounding contract, without hardcoding which of the two
/// neighbouring representable values a given operation lands on.
fn expectTight(i: Interval, exact_lo: f64, exact_hi: f64) !void {
    try std.testing.expect(i.lo <= exact_lo);
    try std.testing.expect(i.hi >= exact_hi);
    try std.testing.expect(i.lo >= interval.prevDown(exact_lo));
    try std.testing.expect(i.hi <= interval.nextUp(exact_hi));
}

/// Every component of a box obeys lo <= hi.
fn expectOrdered(comps: []const Interval) !void {
    for (comps) |i| {
        try std.testing.expect(i.lo <= i.hi);
    }
}

/// The endpoints of a range, its midpoint, and zero when it covers zero.
/// Every extreme of a sum, difference, product, quotient, or square over
/// a range is reached at one of those, so probing them tests an
/// enclosure where it is tightest rather than somewhere it has slack.
fn probes(i: Interval, out: *[4]f64) usize {
    var n: usize = 0;
    out[n] = i.lo;
    n += 1;
    out[n] = i.hi;
    n += 1;
    out[n] = i.midpoint();
    n += 1;
    if (i.contains(0.0)) {
        out[n] = 0.0;
        n += 1;
    }
    return n;
}

const I = Interval.init;

/// A fixed box used by the arithmetic tests: three components with
/// different signs, widths, and magnitudes, so a fold that mixes the
/// axes up cannot pass.
fn sample() interval.Vec(3) {
    return interval.Vec(3).fromArray(.{
        I(1.0, 3.0),
        I(-2.0, 4.0),
        I(10.0, 20.0),
    });
}

fn other() interval.Vec(3) {
    return interval.Vec(3).fromArray(.{
        I(10.0, 20.0),
        I(5.0, 7.0),
        I(2.0, 2.0),
    });
}

/// Three ranges that all clear of zero, so `recip` and division by them
/// are defined rather than a coin toss over the convention chosen for a
/// range that spans zero.
fn invertible() interval.Vec(3) {
    return interval.Vec(3).fromArray(.{
        I(1.0, 3.0),
        I(-2.0, -1.0),
        I(10.0, 20.0),
    });
}

test "Vec: init fills every component" {
    const v = interval.Vec(3).init(I(1.0, 2.0));
    try std.testing.expectEqual(@as(usize, 3), v.dim());
    for (v.slice()) |c| {
        try std.testing.expectEqual(@as(f64, 1.0), c.lo);
        try std.testing.expectEqual(@as(f64, 2.0), c.hi);
    }
}

test "Vec: fromArray keeps the components, dim is the comptime count" {
    const v = sample();
    try std.testing.expect(v.get(0).eql(I(1.0, 3.0)));
    try std.testing.expect(v.get(1).eql(I(-2.0, 4.0)));
    try std.testing.expect(v.get(2).eql(I(10.0, 20.0)));
    try std.testing.expectEqual(@as(usize, 3), v.dim());
    try std.testing.expectEqual(@as(usize, 1), interval.Vec(1).init(I(0.0, 1.0)).dim());
    try std.testing.expectEqual(@as(usize, 7), interval.Vec(7).init(I(0.0, 1.0)).dim());
}

test "Vec: get and set address one component" {
    var v = interval.Vec(3).init(I(0.0, 1.0));
    try std.testing.expect(v.get(0).eql(I(0.0, 1.0)));
    try std.testing.expect(v.get(2).eql(I(0.0, 1.0)));

    v.set(1, I(-4.0, 9.0));
    try std.testing.expect(v.get(1).eql(I(-4.0, 9.0)));
    // The neighbours are untouched by set.
    try std.testing.expect(v.get(0).eql(I(0.0, 1.0)));
    try std.testing.expect(v.get(2).eql(I(0.0, 1.0)));
}

test "Vec: eql compares componentwise" {
    try std.testing.expect(sample().eql(sample()));

    // A box differing in exactly one component is not equal.
    var v = sample();
    v.set(2, I(10.0, 21.0));
    try std.testing.expect(!v.eql(sample()));
    try std.testing.expect(!sample().eql(v));

    // Endpoints are compared, not just containment.
    try std.testing.expect(!interval.Vec(1).init(I(0.0, 1.0)).eql(interval.Vec(1).init(I(0.0, 2.0))));
    try std.testing.expect(interval.Vec(1).init(I(0.0, 1.0)).eql(interval.Vec(1).init(I(0.0, 1.0))));
}

test "Vec: elementwise add" {
    const r = sample().add(other());
    try expectOrdered(r.slice());
    try expectTight(r.get(0), 11.0, 23.0);
    try expectTight(r.get(1), 3.0, 11.0);
    try expectTight(r.get(2), 12.0, 22.0);
}

test "Vec: elementwise sub" {
    const r = sample().sub(other());
    try expectOrdered(r.slice());
    // The lower bound pairs the smaller lo against the larger hi.
    try expectTight(r.get(0), -19.0, -7.0);
    try expectTight(r.get(1), -9.0, -1.0);
    try expectTight(r.get(2), 8.0, 18.0);
}

test "Vec: elementwise mul" {
    const r = sample().mul(other());
    try expectOrdered(r.slice());
    try expectTight(r.get(0), 10.0, 60.0);
    // -2 * 7 = -14 is the most negative of the four corner products.
    try expectTight(r.get(1), -14.0, 28.0);
    try expectTight(r.get(2), 20.0, 40.0);
}

test "Vec: elementwise div" {
    const r = sample().div(other());
    try expectOrdered(r.slice());
    try expectTight(r.get(0), 0.05, 0.3);
    try expectTight(r.get(1), -0.4, 0.8);
    try expectTight(r.get(2), 5.0, 10.0);
}

test "Vec: neg, abs, sqr are elementwise" {
    const v = interval.Vec(3).fromArray(.{
        I(1.0, 3.0),
        I(-2.0, 0.5),
        I(10.0, 20.0),
    });

    const n = v.neg();
    try expectOrdered(n.slice());
    try expectTight(n.get(0), -3.0, -1.0);
    // Negating [-2, 0.5] gives [-0.5, 2]: the endpoints swap sides.
    try expectTight(n.get(1), -0.5, 2.0);
    try expectTight(n.get(2), -20.0, -10.0);

    const m = v.abs();
    try expectOrdered(m.slice());
    try expectTight(m.get(0), 1.0, 3.0);
    // A range covering zero has its magnitude reach down to exactly 0.
    try expectTight(m.get(1), 0.0, 2.0);
    try expectTight(m.get(2), 10.0, 20.0);

    // Squaring a range that straddles zero must reach down to zero, so
    // it stays an enclosure instead of folding to the two endpoints.
    const s = v.sqr();
    try expectOrdered(s.slice());
    try expectTight(s.get(0), 1.0, 9.0);
    try expectTight(s.get(1), 0.0, 4.0);
    try expectTight(s.get(2), 100.0, 400.0);
}

test "Vec: recip inverts each component" {
    const v = invertible();
    const r = v.recip();
    try expectOrdered(r.slice());
    try expectTight(r.get(0), 1.0 / 3.0, 1.0);
    // A negative range stays negative and its endpoints swap.
    try expectTight(r.get(1), -1.0, -0.5);
    try expectTight(r.get(2), 0.05, 0.1);
}

test "Vec: hull takes the smallest covering box" {
    const a = interval.Vec(3).fromArray(.{
        I(1.0, 3.0),
        I(-2.0, 4.0),
        I(10.0, 20.0),
    });
    const b = interval.Vec(3).fromArray(.{
        I(2.0, 5.0),
        I(0.0, 1.0),
        I(0.0, 12.0),
    });
    const h = a.hull(b);
    try expectOrdered(h.slice());
    try std.testing.expectEqual(@as(f64, 1.0), h.get(0).lo);
    try std.testing.expectEqual(@as(f64, 5.0), h.get(0).hi);
    try std.testing.expectEqual(@as(f64, -2.0), h.get(1).lo);
    try std.testing.expectEqual(@as(f64, 4.0), h.get(1).hi);
    try std.testing.expectEqual(@as(f64, 0.0), h.get(2).lo);
    try std.testing.expectEqual(@as(f64, 20.0), h.get(2).hi);

    // Hull is commutative, and idempotent on the box it was handed.
    try std.testing.expect(h.eql(b.hull(a)));
    try std.testing.expect(a.eql(a.hull(a)));
    try std.testing.expect(a.eql(a.hull(a).hull(a)));
}

test "Vec: a slice stays valid while its box is alive" {
    // A slice into a by-value copy of the box would point at a stack
    // frame that later calls reuse, so the interleaved calls below would
    // read clobbered memory. The receiver is a pointer precisely so this
    // cannot happen.
    const v = sample();
    const seen = v.slice();

    var scratch: [4]f64 = undefined;
    for (0..4) |k| scratch[k] = @sqrt(@as(f64, @floatFromInt(k)) + 1.0);
    try std.testing.expectEqual(@as(f64, 1.0), scratch[0]);
    _ = v.neg().add(v);
    _ = v.distance(.{ 1.0, 1.0, 1.0 });

    for (0..3) |i| {
        try std.testing.expectEqual(v.get(i).lo, seen[i].lo);
        try std.testing.expectEqual(v.get(i).hi, seen[i].hi);
        try std.testing.expect(seen[i].eql(v.get(i)));
    }
}

test "DynVec: a slice stays valid while its box is alive" {
    const gpa = std.testing.allocator;
    var v = try interval.DynVec.fromArray(gpa, sample().slice());
    defer v.deinit();
    const seen = v.slice();

    var pad = try interval.DynVec.init(gpa, 3, I(100.0, 200.0));
    defer pad.deinit();
    try pad.iadd(v);
    v.set(0, I(-7.0, -6.0));

    // The slice is the box's own memory, so it follows the write.
    try std.testing.expectEqual(@as(f64, -7.0), seen[0].lo);
    for (1..3) |i| {
        try std.testing.expect(seen[i].eql(sample().get(i)));
    }
}

test "Vec: intersect shares a box when every component overlaps" {
    const a = interval.Vec(3).init(I(0.0, 2.0));
    const b = interval.Vec(3).fromArray(.{
        I(1.0, 3.0),
        I(2.0, 4.0),
        I(0.5, 1.5),
    });
    const x = a.intersect(b).?;
    try expectOrdered(x.slice());
    try std.testing.expectEqual(@as(f64, 1.0), x.get(0).lo);
    try std.testing.expectEqual(@as(f64, 2.0), x.get(0).hi);
    // Components that only touch at an endpoint still share that point.
    try std.testing.expectEqual(@as(f64, 2.0), x.get(1).lo);
    try std.testing.expectEqual(@as(f64, 2.0), x.get(1).hi);
    try std.testing.expectEqual(@as(f64, 0.5), x.get(2).lo);
    try std.testing.expectEqual(@as(f64, 1.5), x.get(2).hi);
}

test "Vec: intersect is null when exactly one component is disjoint" {
    const a = interval.Vec(3).init(I(0.0, 1.0));
    // Only the last component misses, so the boxes share a point along
    // axes 0 and 1 and still have no point in common along axis 2.
    const b = interval.Vec(3).fromArray(.{
        I(0.5, 2.0),
        I(0.5, 2.0),
        I(5.0, 6.0),
    });
    try std.testing.expect(a.intersect(b) == null);
    try std.testing.expect(b.intersect(a) == null);
    // The two matching components really do overlap, so the null comes
    // from the third alone and not from a wholesale mismatch.
    try std.testing.expect(a.get(0).overlaps(b.get(0)));
    try std.testing.expect(a.get(1).overlaps(b.get(1)));
    try std.testing.expect(!a.get(2).overlaps(b.get(2)));
    try std.testing.expect(!a.overlaps(b));

    // Moving the gap to the first component gives the same answer.
    const c = interval.Vec(3).fromArray(.{
        I(5.0, 6.0),
        I(0.5, 2.0),
        I(0.5, 2.0),
    });
    try std.testing.expect(a.intersect(c) == null);
}

test "Vec: overlaps needs every component" {
    const a = interval.Vec(3).init(I(0.0, 1.0));
    try std.testing.expect(a.overlaps(interval.Vec(3).init(I(0.5, 2.0))));
    // Touching at a single point is an overlap.
    try std.testing.expect(a.overlaps(interval.Vec(3).init(I(1.0, 2.0))));
    try std.testing.expect(a.overlaps(a));

    var b = a;
    b.set(1, I(9.0, 10.0));
    try std.testing.expect(!a.overlaps(b));
    try std.testing.expect(!b.overlaps(a));
}

test "Vec: subsetOf needs every component inside" {
    const outer = interval.Vec(3).init(I(0.0, 10.0));
    const inner = interval.Vec(3).fromArray(.{
        I(1.0, 2.0),
        I(3.0, 4.0),
        I(5.0, 6.0),
    });
    try std.testing.expect(inner.subsetOf(outer));
    try std.testing.expect(outer.subsetOf(outer));
    try std.testing.expect(!outer.subsetOf(inner));

    // One component sticking out is enough to fail.
    var poking = inner;
    poking.set(2, I(5.0, 11.0));
    try std.testing.expect(!poking.subsetOf(outer));
    try std.testing.expect(!poking.subsetOf(inner));

    // So is one component reaching below the box.
    var low = inner;
    low.set(0, I(-0.5, 2.0));
    try std.testing.expect(!low.subsetOf(outer));
}

test "Vec: contains is endpoint-inclusive and rejects a point outside" {
    const v = interval.Vec(3).init(I(0.0, 1.0));
    try std.testing.expect(v.contains(.{ 0.5, 0.5, 0.5 }));
    // On a face, and on a corner: the faces are part of the box.
    try std.testing.expect(v.contains(.{ 0.0, 0.5, 0.5 }));
    try std.testing.expect(v.contains(.{ 1.0, 0.5, 0.5 }));
    try std.testing.expect(v.contains(.{ 0.5, 0.0, 0.5 }));
    try std.testing.expect(v.contains(.{ 0.5, 0.5, 1.0 }));
    try std.testing.expect(v.contains(.{ 0.0, 0.0, 0.0 }));
    try std.testing.expect(v.contains(.{ 1.0, 1.0, 1.0 }));

    // Outside on one axis alone is enough to miss the box.
    try std.testing.expect(!v.contains(.{ 1.5, 0.5, 0.5 }));
    try std.testing.expect(!v.contains(.{ 0.5, -0.5, 0.5 }));
    try std.testing.expect(!v.contains(.{ 0.5, 0.5, 2.0 }));
    try std.testing.expect(!v.contains(.{ -1.0, -1.0, -1.0 }));
}

test "Vec: distance is zero at the centre of a 1-dimensional box" {
    const v = interval.Vec(1).init(I(0.0, 1.0));
    try std.testing.expectEqual(@as(f64, 0.0), v.distance(.{0.5}));
    // Anywhere in the box is zero distance, faces included.
    try std.testing.expectEqual(@as(f64, 0.0), v.distance(.{0.0}));
    try std.testing.expectEqual(@as(f64, 0.0), v.distance(.{1.0}));
    // Outside it is the distance to the nearest face.
    try std.testing.expectEqual(@as(f64, 2.5), v.distance(.{3.5}));
    // The point sits 1.5 below the lower face at 0.0.
    try std.testing.expectEqual(@as(f64, 1.5), v.distance(.{-1.5}));
}

test "Vec: distance is the Euclidean norm, not the max metric" {
    const v = interval.Vec(2).init(I(0.0, 1.0));
    // Each component is 3.0 away, so the max metric would say 3.0 and
    // the Euclidean one says the hypotenuse.
    const d = v.distance(.{ 4.0, 4.0 });
    try std.testing.expect(d > 3.0);
    try std.testing.expectEqual(3.0 * @sqrt(2.0), d);

    // A single axis off by 4 leaves the distance at 4 under both
    // metrics, which is the degenerate case the norm agrees on.
    try std.testing.expectEqual(@as(f64, 4.0), v.distance(.{ 5.0, 0.5 }));
    // Two axes off by 6 and 8 give the 3-4-5 hypotenuse.
    try std.testing.expectEqual(@as(f64, 10.0), v.distance(.{ 7.0, 9.0 }));
    try std.testing.expectEqual(@as(f64, 0.0), v.distance(.{ 0.5, 0.5 }));
}

test "Vec: isEmpty is false for a well-formed box" {
    try std.testing.expect(!sample().isEmpty());
    try std.testing.expect(!interval.Vec(0).init(I(0.0, 1.0)).isEmpty());
    // A degenerate box is one point, not no points.
    try std.testing.expect(!interval.Vec(1).init(I(2.0, 2.0)).isEmpty());
}

test "Vec: a dimension-zero box holds the one point of the empty space" {
    const v = interval.Vec(0).init(I(0.0, 1.0));
    try std.testing.expectEqual(@as(usize, 0), v.dim());
    try std.testing.expect(v.contains(.{}));
    try std.testing.expectEqual(@as(f64, 0.0), v.distance(.{}));
    try std.testing.expect(v.overlaps(interval.Vec(0).init(I(5.0, 6.0))));
    try std.testing.expect(v.intersect(interval.Vec(0).init(I(5.0, 6.0))) != null);
}

test "Vec: a value-returning operation leaves the operands alone" {
    const a = sample();
    const b = other();
    const a_copy = sample();
    const b_copy = other();
    _ = a.add(b);
    _ = a.sub(b);
    _ = a.mul(b);
    _ = a.div(b);
    _ = a.hull(b);
    _ = a.neg();
    _ = a.abs();
    _ = a.sqr();
    _ = invertible().recip();
    try std.testing.expect(a.eql(a_copy));
    try std.testing.expect(b.eql(b_copy));
}

test "Vec: every probed point pair lands inside the arithmetic result" {
    const lx = interval.Vec(3).fromArray(.{
        I(1.0, 3.0),
        I(-2.0, 4.0),
        I(10.0, 20.0),
    });
    const ly = interval.Vec(3).fromArray(.{
        I(30.0, 50.0),
        I(-40.0, -10.0),
        I(2.0, 4.0),
    });

    const sum = lx.add(ly);
    const dif = lx.sub(ly);
    const pro = lx.mul(ly);
    const quo = lx.div(ly);
    const squ = lx.sqr();
    try expectOrdered(sum.slice());
    try expectOrdered(dif.slice());
    try expectOrdered(pro.slice());
    try expectOrdered(quo.slice());
    try expectOrdered(squ.slice());

    var px: [4]f64 = undefined;
    var py: [4]f64 = undefined;
    for (0..3) |i| {
        // Every divisor avoids zero, so the quotient probes are real.
        try std.testing.expect(ly.get(i).lo > 0.0 or ly.get(i).hi < 0.0);
        const nx = probes(lx.get(i), &px);
        const ny = probes(ly.get(i), &py);
        for (px[0..nx]) |p| {
            for (py[0..ny]) |q| {
                try std.testing.expect(sum.get(i).contains(p + q));
                try std.testing.expect(dif.get(i).contains(p - q));
                try std.testing.expect(pro.get(i).contains(p * q));
                try std.testing.expect(quo.get(i).contains(p / q));
                try std.testing.expect(squ.get(i).contains(p * p));
            }
        }
    }
}

test "DynVec: init sets the runtime length and deinit releases it" {
    const gpa = std.testing.allocator;
    var v = try interval.DynVec.init(gpa, 3, I(1.0, 2.0));
    defer v.deinit();
    try std.testing.expectEqual(@as(usize, 3), v.dim());
    for (v.slice()) |c| {
        try std.testing.expect(c.eql(I(1.0, 2.0)));
    }

    var w = try interval.DynVec.init(gpa, 1, I(0.0, 1.0));
    defer w.deinit();
    try std.testing.expectEqual(@as(usize, 1), w.dim());
    try std.testing.expect(w.dim() != v.dim());

    var e = try interval.DynVec.init(gpa, 0, I(0.0, 1.0));
    defer e.deinit();
    try std.testing.expectEqual(@as(usize, 0), e.dim());
}

test "DynVec: fromArray copies, so the caller keeps its own array" {
    const gpa = std.testing.allocator;
    var src = [_]Interval{ I(1.0, 2.0), I(3.0, 4.0) };
    var v = try interval.DynVec.fromArray(gpa, &src);
    defer v.deinit();
    try std.testing.expectEqual(@as(usize, 2), v.dim());
    try std.testing.expect(v.get(1).eql(I(3.0, 4.0)));
    src[0] = I(9.0, 9.0);
    try std.testing.expect(v.get(0).eql(I(1.0, 2.0)));
}

test "DynVec: get, set, and eql behave as on the fixed box" {
    const gpa = std.testing.allocator;
    var v = try interval.DynVec.init(gpa, 3, I(0.0, 1.0));
    defer v.deinit();
    v.set(1, I(-1.0, 7.0));
    try std.testing.expect(v.get(1).eql(I(-1.0, 7.0)));
    try std.testing.expect(v.get(0).eql(I(0.0, 1.0)));
    try std.testing.expect(v.get(2).eql(I(0.0, 1.0)));

    var w = try interval.DynVec.fromArray(gpa, v.slice());
    defer w.deinit();
    try std.testing.expect(v.eql(w));
    w.set(2, I(0.0, 2.0));
    try std.testing.expect(!v.eql(w));
    try std.testing.expect(!w.eql(v));
}

test "DynVec: value-returning arithmetic matches the fixed box" {
    const gpa = std.testing.allocator;
    const sa = sample();
    const sb = other();
    var a = try interval.DynVec.fromArray(gpa, sa.slice());
    defer a.deinit();
    var b = try interval.DynVec.fromArray(gpa, sb.slice());
    defer b.deinit();

    var adds = try a.add(b);
    defer adds.deinit();
    try expectOrdered(adds.slice());
    for (0..3) |i| {
        try std.testing.expect(adds.get(i).eql(sa.get(i).add(sb.get(i))));
    }

    var subs = try a.sub(b);
    defer subs.deinit();
    for (0..3) |i| {
        try std.testing.expect(subs.get(i).eql(sa.get(i).sub(sb.get(i))));
    }

    var muls = try a.mul(b);
    defer muls.deinit();
    for (0..3) |i| {
        try std.testing.expect(muls.get(i).eql(sa.get(i).mul(sb.get(i))));
    }

    var divs = try a.div(b);
    defer divs.deinit();
    for (0..3) |i| {
        try std.testing.expect(divs.get(i).eql(sa.get(i).div(sb.get(i))));
    }

    var h = try a.hull(b);
    defer h.deinit();
    const want = sa.hull(sb);
    for (0..3) |i| {
        try std.testing.expect(h.get(i).eql(want.get(i)));
    }
    try std.testing.expectEqual(@as(usize, 3), h.dim());
}

test "DynVec: a value-returning operation leaves the operands alone" {
    const gpa = std.testing.allocator;
    var a = try interval.DynVec.fromArray(gpa, sample().slice());
    defer a.deinit();
    var b = try interval.DynVec.fromArray(gpa, other().slice());
    defer b.deinit();
    var a_copy = try interval.DynVec.fromArray(gpa, a.slice());
    defer a_copy.deinit();

    var r = try a.add(b);
    defer r.deinit();
    try std.testing.expect(a.eql(a_copy));
    try std.testing.expect(!r.eql(a));
}

test "DynVec: mismatched widths are rejected" {
    const gpa = std.testing.allocator;
    var a = try interval.DynVec.init(gpa, 2, I(0.0, 1.0));
    defer a.deinit();
    var b = try interval.DynVec.init(gpa, 3, I(0.0, 1.0));
    defer b.deinit();

    try std.testing.expectError(error.DimensionMismatch, a.add(b));
    try std.testing.expectError(error.DimensionMismatch, a.sub(b));
    try std.testing.expectError(error.DimensionMismatch, a.mul(b));
    try std.testing.expectError(error.DimensionMismatch, a.div(b));
    try std.testing.expectError(error.DimensionMismatch, a.hull(b));
    try std.testing.expectError(error.DimensionMismatch, a.intersect(b));
    try std.testing.expectError(error.DimensionMismatch, a.iadd(b));
    try std.testing.expectError(error.DimensionMismatch, a.isub(b));
    try std.testing.expectError(error.DimensionMismatch, a.imul(b));
    try std.testing.expectError(error.DimensionMismatch, a.idiv(b));

    // Widths that disagree are not comparable at all, so the
    // predicates say false rather than trap.
    try std.testing.expect(!a.overlaps(b));
    try std.testing.expect(!a.subsetOf(b));
    try std.testing.expect(a.overlaps(a));
    try std.testing.expect(a.subsetOf(a));
}

test "DynVec: iadd overwrites the receiver, add does not" {
    const gpa = std.testing.allocator;
    var a = try interval.DynVec.fromArray(gpa, sample().slice());
    defer a.deinit();
    var b = try interval.DynVec.fromArray(gpa, other().slice());
    defer b.deinit();

    var before = try a.add(b);
    defer before.deinit();
    try a.iadd(b);
    try std.testing.expect(a.eql(before));
    // iadd is not a no-op: the receiver really moved.
    const moved = sample();
    var differs = false;
    for (0..3) |i| {
        if (!a.get(i).eql(moved.get(i))) differs = true;
    }
    try std.testing.expect(differs);
}

test "DynVec: neg, abs, sqr, recip are in place" {
    const gpa = std.testing.allocator;
    const src = interval.Vec(3).fromArray(.{
        I(1.0, 3.0),
        I(-2.0, 0.5),
        I(10.0, 20.0),
    });
    var v = try interval.DynVec.fromArray(gpa, src.slice());
    defer v.deinit();

    v.neg();
    try expectOrdered(v.slice());
    for (0..3) |i| {
        try std.testing.expect(v.get(i).eql(src.neg().get(i)));
    }

    v.neg();
    v.abs();
    try expectOrdered(v.slice());
    for (0..3) |i| {
        try std.testing.expect(v.get(i).eql(src.abs().get(i)));
    }

    var s = try interval.DynVec.fromArray(gpa, src.slice());
    defer s.deinit();
    s.sqr();
    try expectOrdered(s.slice());
    for (0..3) |i| {
        try std.testing.expect(s.get(i).eql(src.sqr().get(i)));
    }

    const inv = invertible();
    var r = try interval.DynVec.fromArray(gpa, inv.slice());
    defer r.deinit();
    r.recip();
    try expectOrdered(r.slice());
    for (0..3) |i| {
        try std.testing.expect(r.get(i).eql(inv.recip().get(i)));
    }
}

test "DynVec: intersect is null when exactly one component is disjoint" {
    const gpa = std.testing.allocator;
    var a = try interval.DynVec.init(gpa, 3, I(0.0, 1.0));
    defer a.deinit();
    var b = try interval.DynVec.init(gpa, 3, I(0.5, 2.0));
    defer b.deinit();
    b.set(2, I(5.0, 6.0));

    try std.testing.expect((try a.intersect(b)) == null);
    try std.testing.expect((try b.intersect(a)) == null);
    // Exactly one component misses, and the other two overlap.
    try std.testing.expect(a.get(0).overlaps(b.get(0)));
    try std.testing.expect(a.get(1).overlaps(b.get(1)));
    try std.testing.expect(!a.get(2).overlaps(b.get(2)));
    try std.testing.expect(!a.overlaps(b));

    b.set(2, I(0.5, 0.75));
    var x = (try a.intersect(b)).?;
    defer x.deinit();
    try expectOrdered(x.slice());
    for (0..3) |i| {
        try std.testing.expect(x.get(i).eql(a.get(i).intersect(b.get(i)).?));
    }
}

test "DynVec: hull, overlaps, and subsetOf match the fixed box" {
    const gpa = std.testing.allocator;
    var outer = try interval.DynVec.init(gpa, 3, I(0.0, 10.0));
    defer outer.deinit();
    var inner = try interval.DynVec.fromArray(gpa, &[_]Interval{ I(1.0, 2.0), I(3.0, 4.0), I(5.0, 6.0) });
    defer inner.deinit();

    var h = try outer.hull(inner);
    defer h.deinit();
    try std.testing.expectEqual(@as(f64, 0.0), h.get(0).lo);
    try std.testing.expectEqual(@as(f64, 10.0), h.get(0).hi);
    try std.testing.expectEqual(@as(usize, 3), h.dim());

    try std.testing.expect(inner.subsetOf(outer));
    try std.testing.expect(!outer.subsetOf(inner));

    inner.set(2, I(5.0, 11.0));
    try std.testing.expect(!inner.subsetOf(outer));
    inner.set(2, I(5.0, 6.0));
    try std.testing.expect(inner.overlaps(outer));

    var far = try interval.DynVec.init(gpa, 3, I(20.0, 21.0));
    defer far.deinit();
    try std.testing.expect(!inner.overlaps(far));
    try std.testing.expect((try inner.intersect(far)) == null);
}

test "DynVec: contains and distance match the fixed box" {
    const gpa = std.testing.allocator;
    var v = try interval.DynVec.fromArray(gpa, &[_]Interval{ I(0.0, 1.0), I(0.0, 1.0), I(0.0, 1.0) });
    defer v.deinit();
    const fv = interval.Vec(3).init(I(0.0, 1.0));
    const p = [_]f64{ 0.5, 0.5, 0.5 };
    // Both representations measure the same box with the same metric.
    try std.testing.expectEqual(fv.distance(p), v.distance(&p));

    try std.testing.expect(v.contains(&.{ 0.5, 0.5, 0.5 }));
    try std.testing.expect(v.contains(&.{ 0.0, 1.0, 0.5 }));
    try std.testing.expect(!v.contains(&.{ 0.5, 0.5, 1.5 }));
    try std.testing.expectEqual(@as(f64, 0.0), v.distance(&.{ 0.5, 0.5, 0.5 }));
    try std.testing.expectEqual(3.0 * @sqrt(3.0), v.distance(&.{ 4.0, 4.0, 4.0 }));
    try std.testing.expect(!v.isEmpty());
}

/// Doubles an interval. Doubling is domain-total, so the mapped box
/// always exists.
fn double(i: Interval) ?Interval {
    return i.add(i);
}

/// Undefined on a range that reaches below zero, the shape a square
/// root has. Used to drive the null path of `mapResult` without
/// depending on which elementary functions the library ships.
fn nonNegativeSqrt(i: Interval) ?Interval {
    if (i.hi < 0.0) return null;
    return I(@sqrt(@max(i.lo, 0.0)), @sqrt(i.hi));
}

test "mapResult: applies a function to every component" {
    const v = sample();
    const d = (try interval.mapResult(v, double)).?;
    try expectOrdered(d.slice());
    for (0..3) |i| {
        try expectTight(d.get(i), 2.0 * v.get(i).lo, 2.0 * v.get(i).hi);
    }
    // The result is a box of the same shape, not a list of intervals.
    try std.testing.expectEqual(@as(usize, 3), d.dim());
    try std.testing.expect(interval.Vec(3) == @TypeOf(d));
}

test "mapResult: a component off the domain makes the whole box null" {
    var v = interval.Vec(3).fromArray(.{
        I(1.0, 4.0),
        I(9.0, 16.0),
        I(-4.0, -1.0),
    });
    // Only the last component leaves the domain, and it is the last one
    // reached, so the fold has already filled two results.
    try std.testing.expect((try interval.mapResult(v, nonNegativeSqrt)) == null);

    // The same function over a box whose components are all in domain
    // succeeds, and a component touching zero clamps rather than going
    // NaN.
    v.set(2, I(-0.25, 4.0));
    const s = (try interval.mapResult(v, nonNegativeSqrt)).?;
    try expectOrdered(s.slice());
    for (0..3) |i| {
        try std.testing.expect(s.get(i).contains(@sqrt(@max(v.get(i).lo, 0.0))));
        try std.testing.expect(s.get(i).contains(@sqrt(v.get(i).hi)));
    }
}

test "mapResult: the DynVec case allocates and deinits cleanly" {
    const gpa = std.testing.allocator;
    var v = try interval.DynVec.fromArray(gpa, sample().slice());
    defer v.deinit();

    var d = (try interval.mapResult(v, double)).?;
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 3), d.dim());
    try expectOrdered(d.slice());
    for (0..3) |i| {
        try expectTight(d.get(i), 2.0 * v.get(i).lo, 2.0 * v.get(i).hi);
    }
    // The result owns a separate allocation, so freeing it leaves the
    // source box intact.
    try std.testing.expect(v.get(0).eql(sample().get(0)));

    var s = (try interval.mapResult(v, nonNegativeSqrt)).?;
    defer s.deinit();
    try expectOrdered(s.slice());
    for (0..3) |i| {
        try std.testing.expect(s.get(i).contains(@sqrt(@max(v.get(i).lo, 0.0))));
    }
}

test "mapResult: the DynVec case returns null and frees the partial box" {
    const gpa = std.testing.allocator;
    var v = try interval.DynVec.fromArray(gpa, sample().slice());
    defer v.deinit();
    // The last component is the one that leaves the domain, so the fold
    // has already written two results before it gives up. The testing
    // allocator would report the leftover as a leak.
    v.set(2, I(-4.0, -1.0));
    try std.testing.expect((try interval.mapResult(v, nonNegativeSqrt)) == null);
    try std.testing.expect(v.get(1).eql(I(-2.0, 4.0)));
}

test "mapResult: a zero-component box maps to itself" {
    const v = interval.Vec(0).init(I(0.0, 1.0));
    const d = (try interval.mapResult(v, double)).?;
    try std.testing.expectEqual(@as(usize, 0), d.dim());
    // No component can leave the domain, so the result cannot be null.
    try std.testing.expect(interval.Vec(0) == @TypeOf(d));
}

test "mapResult: the receivers are left alone" {
    const gpa = std.testing.allocator;
    var v = try interval.DynVec.fromArray(gpa, sample().slice());
    defer v.deinit();
    var before = try interval.DynVec.fromArray(gpa, v.slice());
    defer before.deinit();

    var d = (try interval.mapResult(v, double)).?;
    defer d.deinit();
    try std.testing.expect(v.eql(before));

    const fv = sample();
    const fd = (try interval.mapResult(fv, double)).?;
    try std.testing.expect(fv.eql(sample()));
    try expectOrdered(fd.slice());
}

test "invariant: every component of every arithmetic result obeys lo <= hi" {
    const boxes = [_]interval.Vec(3){
        sample(),
        interval.Vec(3).init(I(-1.0, 1.0)),
        interval.Vec(3).fromArray(.{
            I(-std.math.floatMax(f64), std.math.floatMax(f64)),
            I(0.0, 0.0),
            I(1e300, 1e300),
        }),
        interval.Vec(3).init(I(-std.math.inf(f64), std.math.inf(f64))),
    };
    // Every component of every divisor stays clear of zero.
    const divisors = [_]interval.Vec(3){
        other(),
        interval.Vec(3).init(I(-4.0, -1.0)),
    };

    for (boxes) |a| {
        for (divisors) |b| {
            try expectOrdered(a.add(b).slice());
            try expectOrdered(a.sub(b).slice());
            try expectOrdered(a.mul(b).slice());
            try expectOrdered(a.div(b).slice());
            try expectOrdered(a.hull(b).slice());
        }
        try expectOrdered(a.neg().slice());
        try expectOrdered(a.abs().slice());
        try expectOrdered(a.sqr().slice());
        try expectOrdered(a.slice());
    }

    // Inverting a range that spans zero is undefined, so recip runs
    // over ranges that stay on one side of it.
    const inv = invertible();
    try expectOrdered(inv.recip().slice());
    const extremes = [_]interval.Vec(3){
        interval.Vec(3).init(I(-std.math.floatMax(f64), -1.0)),
        interval.Vec(3).init(I(1.0, std.math.floatMax(f64))),
        interval.Vec(3).init(I(1e-300, 1e300)),
    };
    for (boxes) |a| {
        try expectOrdered(inv.recip().add(a).slice());
    }
    for (extremes) |e| {
        try expectOrdered(e.recip().slice());
    }
}

test "invariant: the owned representation holds the same order" {
    const gpa = std.testing.allocator;
    const boxes = [_]interval.Vec(3){
        sample(),
        interval.Vec(3).init(I(-1.0, 1.0)),
        interval.Vec(3).fromArray(.{
            I(-std.math.floatMax(f64), std.math.floatMax(f64)),
            I(0.0, 0.0),
            I(1e300, 1e300),
        }),
        interval.Vec(3).init(I(-std.math.inf(f64), std.math.inf(f64))),
    };
    const divisors = [_]interval.Vec(3){
        other(),
        interval.Vec(3).init(I(-4.0, -1.0)),
    };

    for (boxes) |a| {
        for (divisors) |b| {
            var x = try interval.DynVec.fromArray(gpa, a.slice());
            defer x.deinit();
            var y = try interval.DynVec.fromArray(gpa, b.slice());
            defer y.deinit();

            var sum = try x.add(y);
            defer sum.deinit();
            try expectOrdered(sum.slice());
            var dif = try x.sub(y);
            defer dif.deinit();
            try expectOrdered(dif.slice());
            var pro = try x.mul(y);
            defer pro.deinit();
            try expectOrdered(pro.slice());
            var quo = try x.div(y);
            defer quo.deinit();
            try expectOrdered(quo.slice());
            var hul = try x.hull(y);
            defer hul.deinit();
            try expectOrdered(hul.slice());

            try x.iadd(y);
            try expectOrdered(x.slice());
            try x.isub(y);
            try expectOrdered(x.slice());
            try x.imul(y);
            try expectOrdered(x.slice());
            try x.idiv(y);
            try expectOrdered(x.slice());
            x.neg();
            try expectOrdered(x.slice());
            x.abs();
            try expectOrdered(x.slice());
            x.sqr();
            try expectOrdered(x.slice());
        }

        var solo = try interval.DynVec.fromArray(gpa, a.slice());
        defer solo.deinit();
        solo.neg();
        try expectOrdered(solo.slice());
        solo.abs();
        try expectOrdered(solo.slice());
        solo.sqr();
        try expectOrdered(solo.slice());
    }

    var r = try interval.DynVec.fromArray(gpa, invertible().slice());
    defer r.deinit();
    r.recip();
    try expectOrdered(r.slice());
}
