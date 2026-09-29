const std = @import("std");
const interval = @import("interval");
const Interval = interval.Interval;
const lp = interval.lp;

const gpa = std.testing.allocator;

/// The degenerate interval around a single value.
fn pt(v: f64) Interval {
    return Interval.init(v, v);
}

/// Assert that `got` is a rigorous projection of the true range [lo, hi]:
/// it contains the truth, and it is no looser than `tol`.
///
/// The containment half is an exact comparison and is the soundness
/// property. The tightness half carries a tolerance because every derived
/// endpoint comes out of `Interval`, which widens outward by an ULP per
/// operation; a few operations on values of order ten stay far inside 1e-9.
fn expectRange(got: Interval, lo: f64, hi: f64, tol: f64) !void {
    try std.testing.expect(got.lo <= lo);
    try std.testing.expect(got.hi >= hi);
    try std.testing.expect(got.lo >= lo - tol);
    try std.testing.expect(got.hi <= hi + tol);
    try std.testing.expect(got.lo <= got.hi);
}

/// Copy a coefficient vector of point values and add it as `<=`.
fn addPoints(sys: *lp.System, coeffs: []const f64, rhs: f64) !void {
    const buf = try gpa.alloc(Interval, coeffs.len);
    defer gpa.free(buf);
    for (coeffs, buf) |v, *slot| slot.* = pt(v);
    try sys.add(buf, .le, pt(rhs));
}

test "normalisation: eq splits in two, ge flips, at() always reports le" {
    var sys = lp.System.init(gpa, 2);
    defer sys.deinit();

    const c = [_]Interval{ pt(1), pt(2) };
    try sys.add(&c, .le, pt(5));
    try sys.add(&c, .ge, pt(1));
    try sys.add(&c, .eq, pt(3));

    // One row for `le`, one for `ge`, two for the `eq` pair.
    try std.testing.expectEqual(@as(usize, 4), sys.count());
    for (0..sys.count()) |i| {
        try std.testing.expectEqual(lp.Cmp.le, sys.at(i).op);
    }

    // `x + 2y >= 1` is stored as `-x - 2y <= -1`.
    const flipped = sys.at(1);
    try std.testing.expectEqual(@as(f64, -1.0), flipped.coeffs[0].lo);
    try std.testing.expectEqual(@as(f64, -2.0), flipped.coeffs[1].lo);
    try std.testing.expectEqual(@as(f64, -1.0), flipped.rhs.lo);

    // `eq` becomes the pair (a, <=, r) and (-a, <=, -r).
    const eq_lo = sys.at(2);
    try std.testing.expectEqual(@as(f64, 1.0), eq_lo.coeffs[0].lo);
    try std.testing.expectEqual(@as(f64, 3.0), eq_lo.rhs.lo);
    const eq_hi = sys.at(3);
    try std.testing.expectEqual(@as(f64, -1.0), eq_hi.coeffs[0].lo);
    try std.testing.expectEqual(@as(f64, -3.0), eq_hi.rhs.lo);
}

test "add rejects a coefficient vector of the wrong length" {
    var sys = lp.System.init(gpa, 2);
    defer sys.deinit();

    const too_short = [_]Interval{pt(1)};
    try std.testing.expectError(error.BadVariableCount, sys.add(&too_short, .le, pt(1)));
    try std.testing.expectEqual(@as(usize, 0), sys.count());
}

test "a bounded two-variable system projects its exact box" {
    var sys = lp.System.init(gpa, 2);
    defer sys.deinit();

    // 2 <= x + y <= 10 and -1 <= x - y <= 3. With u = x + y and v = x - y
    // both pinned, x = (u + v) / 2 and y = (u - v) / 2, so
    // x is in [0.5, 6.5] and y is in [-0.5, 5.5].
    const xy = [_]Interval{ pt(1), pt(1) };
    const xmy = [_]Interval{ pt(1), pt(-1) };
    try sys.add(&xy, .le, pt(10));
    try sys.add(&xy, .ge, pt(2));
    try sys.add(&xmy, .le, pt(3));
    try sys.add(&xmy, .ge, pt(-1));

    try std.testing.expectEqual(@as(usize, 2), sys.varCount());
    try std.testing.expectEqual(@as(usize, 4), sys.count());
    try std.testing.expect(!sys.isUnsat());

    try expectRange((try sys.bounds(0)).?, 0.5, 6.5, 1e-9);
    try expectRange((try sys.bounds(1)).?, -0.5, 5.5, 1e-9);

    const boxed = (try sys.box()).?;
    defer gpa.free(boxed);
    try std.testing.expectEqual(@as(usize, 2), boxed.len);
    try expectRange(boxed[0], 0.5, 6.5, 1e-9);
    try expectRange(boxed[1], -0.5, 5.5, 1e-9);
}

test "unsatisfiable by contradiction, reported through isUnsat" {
    var sys = lp.System.init(gpa, 1);
    defer sys.deinit();

    // x <= 0 and x >= 1.
    const c = [_]Interval{pt(1)};
    try sys.add(&c, .le, pt(0));
    try sys.add(&c, .ge, pt(1));
    try std.testing.expectEqual(@as(usize, 2), sys.count());
    try std.testing.expect(!sys.isUnsat());

    // Before elimination the projected bounds are already disjoint: the
    // lower side reads 1 and the upper side reads 0.
    try std.testing.expect((try sys.bounds(0)) == null);

    var satisfiable = true;
    try sys.eliminateAll(&satisfiable);
    try std.testing.expect(!satisfiable);
    try std.testing.expect(sys.isUnsat());

    // Eliminating the only variable leaves `0 <= -1` with every coefficient
    // exactly zero.
    try std.testing.expectEqual(@as(usize, 1), sys.count());
    const row = sys.at(0);
    try std.testing.expectEqual(@as(usize, 1), row.coeffs.len);
    for (row.coeffs) |iv| {
        try std.testing.expectEqual(@as(f64, 0.0), iv.lo);
        try std.testing.expectEqual(@as(f64, 0.0), iv.hi);
    }
    try std.testing.expect(row.rhs.hi < 0);

    // A proven-unsatisfiable system projects to nothing.
    try std.testing.expect((try sys.bounds(0)) == null);
    try std.testing.expect((try sys.box()) == null);
}

test "a variable pinned from both sides collapses to a point" {
    var sys = lp.System.init(gpa, 1);
    defer sys.deinit();

    // x <= 3 and x >= 3.
    const c = [_]Interval{pt(1)};
    try sys.add(&c, .le, pt(3));
    try sys.add(&c, .ge, pt(3));

    const b = (try sys.bounds(0)).?;
    try std.testing.expect(b.contains(3.0));
    try expectRange(b, 3.0, 3.0, 1e-9);

    var satisfiable = true;
    try sys.eliminateAll(&satisfiable);
    try std.testing.expect(satisfiable);
    try std.testing.expect(!sys.isUnsat());
}

test "an unconstrained variable makes the whole box null" {
    var sys = lp.System.init(gpa, 2);
    defer sys.deinit();

    // Only x is mentioned; y is free in both directions.
    const c = [_]Interval{ pt(1), pt(0) };
    try sys.add(&c, .le, pt(2));
    try sys.add(&c, .ge, pt(-2));

    try expectRange((try sys.bounds(0)).?, -2.0, 2.0, 1e-9);
    try std.testing.expect((try sys.bounds(1)) == null);

    // Documented contract: box() is null when any variable is unbounded,
    // which is exactly what y does here.
    try std.testing.expect((try sys.box()) == null);
}

test "a coefficient interval straddling zero stays a sound superset" {
    var sys = lp.System.init(gpa, 2);
    defer sys.deinit();

    // [-1, 1] * x + y <= 4, with x <= 5, 0 <= y <= 3 and x >= -1.
    const straddling = [_]Interval{ Interval.init(-1.0, 1.0), pt(1) };
    try sys.add(&straddling, .le, pt(4));
    try sys.add(&[_]Interval{ pt(1), pt(0) }, .le, pt(5));
    try sys.add(&[_]Interval{ pt(0), pt(-1) }, .le, pt(0));
    try sys.add(&[_]Interval{ pt(0), pt(1) }, .le, pt(3));
    try sys.add(&[_]Interval{ pt(-1), pt(0) }, .le, pt(1));

    // The straddling coefficient may be 1, 0 or -1, so the row bounds
    // neither side of x on its own. What it does contribute is a valid lower
    // bound of -inf and a valid upper bound of +inf, through its parts. The
    // row is kept and never dropped.
    const wide = (try sys.bounds(0)).?;
    const wide_y = (try sys.bounds(1)).?;
    try expectRange(wide, -1.0, 5.0, 1e-9);
    try expectRange(wide_y, 0.0, 3.0, 1e-9);

    // The same system with the straddling coefficient pinned to its largest
    // realisation, 1 * x + y <= 4. That is the tightest reading of the
    // interval, so its projection must sit inside the straddling one.
    var tight = lp.System.init(gpa, 2);
    defer tight.deinit();
    try tight.add(&[_]Interval{ pt(1), pt(1) }, .le, pt(4));
    try tight.add(&[_]Interval{ pt(1), pt(0) }, .le, pt(5));
    try tight.add(&[_]Interval{ pt(0), pt(-1) }, .le, pt(0));
    try tight.add(&[_]Interval{ pt(0), pt(1) }, .le, pt(3));
    try tight.add(&[_]Interval{ pt(-1), pt(0) }, .le, pt(1));

    const narrow = (try tight.bounds(0)).?;
    try std.testing.expect(wide.lo <= narrow.lo);
    try std.testing.expect(wide.hi >= narrow.hi);
    try expectRange(narrow, -1.0, 4.0, 1e-9);

    var satisfiable = true;
    try sys.eliminateAll(&satisfiable);
    try std.testing.expect(satisfiable);
    try std.testing.expect(!sys.isUnsat());
}

test "eliminationOrder is a permutation with no repeats" {
    var sys = lp.System.init(gpa, 3);
    defer sys.deinit();

    try addPoints(&sys, &.{ 1, 1, 1 }, 12);
    try addPoints(&sys, &.{ -1, -1, -1 }, 0);
    try addPoints(&sys, &.{ -1, -1, 1 }, 0);
    try addPoints(&sys, &.{ -1, 1, -1 }, 0);
    try addPoints(&sys, &.{ 1, -1, -1 }, 0);
    try addPoints(&sys, &.{ 1, 0, 0 }, 6);
    try addPoints(&sys, &.{ 0, 1, 0 }, 6);
    try addPoints(&sys, &.{ 0, 0, 1 }, 6);

    const order = try sys.eliminationOrder();
    defer gpa.free(order);

    try std.testing.expectEqual(sys.varCount(), order.len);
    var seen = [_]bool{false} ** 3;
    for (order) |k| {
        try std.testing.expect(k < sys.varCount());
        try std.testing.expect(!seen[k]);
        seen[k] = true;
    }

    // Following the plan drives every variable out, and what is left are
    // zero-dimensional rows: the constant constraints that decide
    // satisfiability. They are heavily redundant, which is the usual outcome
    // of Fourier-Motzkin and is not a defect; every one of them must still be
    // readable and satisfiable.
    for (order) |k| try sys.eliminate(k);
    var satisfiable = true;
    try sys.eliminateAll(&satisfiable);
    try std.testing.expect(satisfiable);
    try std.testing.expect(sys.count() > 0);
    for (0..sys.count()) |i| {
        const row = sys.at(i);
        for (row.coeffs) |iv| {
            try std.testing.expectEqual(@as(f64, 0.0), iv.lo);
            try std.testing.expectEqual(@as(f64, 0.0), iv.hi);
        }
        try std.testing.expect(row.rhs.hi >= 0);
    }
}

test "eliminate rejects a bad or already eliminated variable" {
    var sys = lp.System.init(gpa, 2);
    defer sys.deinit();

    try addPoints(&sys, &.{ 1, 0 }, 2);
    try addPoints(&sys, &.{ -1, 0 }, -2);

    try std.testing.expectError(error.BadVariable, sys.eliminate(2));
    try sys.eliminate(0);
    try std.testing.expectError(error.VariableEliminated, sys.eliminate(0));
}

test "a well-posed three-variable system projects [0, 6] in every slot" {
    var sys = lp.System.init(gpa, 3);
    defer sys.deinit();

    // x + y + z in [0, 12], each variable at most the sum of the other two,
    // and each at most 6.
    try addPoints(&sys, &.{ -1, -1, -1 }, 0);
    try addPoints(&sys, &.{ 1, 1, 1 }, 12);
    try addPoints(&sys, &.{ -1, -1, 1 }, 0);
    try addPoints(&sys, &.{ -1, 1, -1 }, 0);
    try addPoints(&sys, &.{ 1, -1, -1 }, 0);
    try addPoints(&sys, &.{ 1, 0, 0 }, 6);
    try addPoints(&sys, &.{ 0, 1, 0 }, 6);
    try addPoints(&sys, &.{ 0, 0, 1 }, 6);

    const boxed = (try sys.box()).?;
    defer gpa.free(boxed);
    try std.testing.expectEqual(@as(usize, 3), boxed.len);
    for (boxed) |iv| try expectRange(iv, 0.0, 6.0, 1e-9);

    // Every interval the solver produces keeps lo <= hi, both the surviving
    // rows and the projections.
    for (0..sys.count()) |i| {
        const row = sys.at(i);
        for (row.coeffs) |iv| try std.testing.expect(iv.lo <= iv.hi);
        try std.testing.expect(row.rhs.lo <= row.rhs.hi);
    }

    var satisfiable = true;
    try sys.eliminateAll(&satisfiable);
    try std.testing.expect(satisfiable);
    for (0..sys.count()) |i| {
        const row = sys.at(i);
        for (row.coeffs) |iv| try std.testing.expect(iv.lo <= iv.hi);
        try std.testing.expect(row.rhs.lo <= row.rhs.hi);
    }
}

test "Tupper's order does measurably less work than the mirror order" {
    // Four variables, five rows:
    //   x0 + x1 + x2 + x3 <= -1
    //      - x1 - x2 + x3 <=  2
    //   -x0      - x2 - x3 <=  2
    //   -x0      + x2 - x3 <=  1
    //   x0           - x3 <=  0
    //
    // The very first Tupper scores, num_lower * num_upper, are
    //   x0: 2 * 2 = 4,  x1: 1 * 1 = 1,  x2: 2 * 2 = 4,  x3: 3 * 2 = 6,
    // so x1 is the unique minimum and must open the order.
    const rows = [_][]const f64{
        &.{ 1, 1, 1, 1 },
        &.{ 0, -1, -1, 1 },
        &.{ -1, 0, -1, -1 },
        &.{ -1, 0, 1, -1 },
        &.{ 1, 0, 0, -1 },
    };
    const rhs = [_]f64{ -1, 2, 2, 1, 0 };

    // The mirror of Tupper's rule: eliminate the variable with the LARGEST
    // num_lower * num_upper first. This is the blow-up the heuristic exists
    // to avoid, and it is what an arbitrary or reversed order amounts to.
    const worst = [_]usize{ 3, 1, 0, 2 };

    var sys = lp.System.init(gpa, 4);
    defer sys.deinit();
    for (rows, rhs) |r, b| try addPoints(&sys, r, b);
    try std.testing.expectEqual(@as(usize, 5), sys.count());

    const order = try sys.eliminationOrder();
    defer gpa.free(order);
    try std.testing.expectEqual(@as(usize, 4), order.len);
    try std.testing.expectEqual(@as(usize, 1), order[0]);
    try std.testing.expect(!std.mem.eql(usize, order, &worst));

    // Drive both orders by hand and record how many rows each step produced.
    var good = lp.System.init(gpa, 4);
    defer good.deinit();
    for (rows, rhs) |r, b| try addPoints(&good, r, b);
    var good_peak = good.count();
    for (order) |k| {
        try good.eliminate(k);
        good_peak = @max(good_peak, good.count());
    }

    var bad = lp.System.init(gpa, 4);
    defer bad.deinit();
    for (rows, rhs) |r, b| try addPoints(&bad, r, b);
    var bad_peak = bad.count();
    for (worst) |k| {
        try bad.eliminate(k);
        bad_peak = @max(bad_peak, bad.count());
    }

    // Measured on this system: the chosen order never exceeds 5 rows and
    // finishes with 1, while the mirror reaches 121 rows and finishes with
    // 121 - the same satisfiability answer, reached by 120 redundant
    // intermediate constraints. Outward rounding moves these counts by a
    // little; it cannot move them by two orders of magnitude, so the bands
    // below state the gap and not an accident of a particular rounding.
    try std.testing.expect(good_peak < bad_peak);
    // The comparison the heuristic is claimed to win, and the strict form of
    // it: measurably fewer constraints, not merely no more.
    try std.testing.expect(good.count() <= bad.count());
    try std.testing.expect(good.count() < bad.count());
    try std.testing.expect(good_peak <= 8);
    try std.testing.expect(bad_peak >= 20);

    // And the shipped path agrees with the plan it advertises.
    var chosen = lp.System.init(gpa, 4);
    defer chosen.deinit();
    for (rows, rhs) |r, b| try addPoints(&chosen, r, b);
    try std.testing.expect(try chosen.eliminateInOrderOfChoice());
    try std.testing.expect(chosen.count() <= bad.count());
    try std.testing.expectEqual(@as(usize, good.count()), chosen.count());
}
