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
        try std.testing.expectEqual(lp.Cmp.le, (try sys.at(i)).op);
    }

    // `x + 2y >= 1` is stored as `-x - 2y <= -1`.
    const flipped = try sys.at(1);
    try std.testing.expectEqual(@as(f64, -1.0), flipped.coeffs[0].lo);
    try std.testing.expectEqual(@as(f64, -2.0), flipped.coeffs[1].lo);
    try std.testing.expectEqual(@as(f64, -1.0), flipped.rhs.lo);

    // `eq` becomes the pair (a, <=, r) and (-a, <=, -r).
    const eq_lo = try sys.at(2);
    try std.testing.expectEqual(@as(f64, 1.0), eq_lo.coeffs[0].lo);
    try std.testing.expectEqual(@as(f64, 3.0), eq_lo.rhs.lo);
    const eq_hi = try sys.at(3);
    try std.testing.expectEqual(@as(f64, -1.0), eq_hi.coeffs[0].lo);
    try std.testing.expectEqual(@as(f64, -3.0), eq_hi.rhs.lo);
}

test "at rejects a row index past the end of the system" {
    var sys = lp.System.init(gpa, 2);
    defer sys.deinit();
    try sys.add(&[_]Interval{ pt(1), pt(0) }, .le, pt(1));
    try std.testing.expectEqual(@as(usize, 1), sys.count());

    // One past the end is the ordinary mistake. The wild index is the
    // dangerous one, because the row slice is built by arithmetic: without a
    // check, an out-of-range `i` reads whatever the allocator left past the
    // rows and reports it as a constraint.
    try std.testing.expectError(error.BadRow, sys.at(1));
    // The variable count is not the row count, and a caller reaching for the
    // wrong one of the two is the likely mistake.
    try std.testing.expectError(error.BadRow, sys.at(sys.varCount()));
    try std.testing.expectError(error.BadRow, sys.at(1 << 20));
    try std.testing.expectError(error.BadRow, sys.at(std.math.maxInt(usize)));

    // An empty system has no row to return either.
    var empty = lp.System.init(gpa, 1);
    defer empty.deinit();
    try std.testing.expectError(error.BadRow, empty.at(0));

    // A rejected read leaves the system alone.
    try std.testing.expectEqual(@as(usize, 1), sys.count());
    try std.testing.expectEqual(@as(f64, 1.0), (try sys.at(0)).rhs.lo);
}

test "lt and gt relax outward, never inward" {
    // `x < 3` and `x > 1` describe the open range (1, 3) over the reals. A
    // closed interval cannot represent an open range, so both comparisons
    // are relaxed to their non-strict form, and the relaxation has to go
    // outward: the answer must admit the two endpoints the strict system
    // excludes, because a tighter answer would cut the feasible set.
    const one = [_]Interval{pt(1)};
    var strict = lp.System.init(gpa, 1);
    defer strict.deinit();
    try strict.add(&one, .lt, pt(3));
    try strict.add(&one, .gt, pt(1));

    const relaxed = (try strict.bounds(0)).?;
    try std.testing.expect(relaxed.contains(1.0));
    try std.testing.expect(relaxed.contains(3.0));
    try std.testing.expect(relaxed.lo <= 1.0);
    try std.testing.expect(relaxed.hi >= 3.0);
    try expectRange(relaxed, 1.0, 3.0, 1e-9);

    // The same system written non-strict. Its true range is the closed
    // [1, 3], so the relaxed reading may not come back tighter than that.
    var closed = lp.System.init(gpa, 1);
    defer closed.deinit();
    try closed.add(&one, .le, pt(3));
    try closed.add(&one, .ge, pt(1));
    const exact = (try closed.bounds(0)).?;
    try std.testing.expect(relaxed.lo <= exact.lo + 1e-9);
    try std.testing.expect(relaxed.hi + 1e-9 >= exact.hi);
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
    const row = try sys.at(0);
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

test "a system whose straddling row contradicts another one projects to nothing" {
    var sys = lp.System.init(gpa, 2);
    defer sys.deinit();

    // Five rows, two of which say something about x and three about y:
    //   [-1, 1] * x <= 1        x is in [-1, 1]
    //        1 * x <= -3        x is at most -3
    //       -x <= 5            x is at least -5
    //   [-1, -1] * y <= 2       y is at least -2
    //        1 * y <= 2        y is at most 2
    // Every row but the first is satisfiable on its own, and the y rows are
    // satisfiable together, so the emptiness comes from the first row
    // meeting the second: a coefficient of -1 is a realisation of [-1, 1],
    // and it reads -x <= 1, so x is at least -1, which the second row denies.
    try sys.add(&[_]Interval{ Interval.init(-1.0, 1.0), pt(0) }, .le, pt(1));
    try sys.add(&[_]Interval{ pt(1), pt(0) }, .le, pt(-3));
    try sys.add(&[_]Interval{ pt(-1), pt(0) }, .le, pt(5));
    try sys.add(&[_]Interval{ pt(0), pt(-1) }, .le, pt(2));
    try sys.add(&[_]Interval{ pt(0), pt(1) }, .le, pt(2));

    // Nothing about the storage is wrong here, so `isUnsat` still says no
    // and the caller's system is untouched: the emptiness is the projection's
    // to find, and a non-null answer is the only signal a caller has that
    // solutions exist.
    try std.testing.expect(!sys.isUnsat());
    try std.testing.expect((try sys.bounds(0)) == null);
    try std.testing.expect((try sys.box()) == null);

    // y is still bounded on its own. Emptiness is a property of the system,
    // not of the variable asked about, and the y rows never touch x, so this
    // is the honest answer for the projection onto y alone.
    try expectRange((try sys.bounds(1)).?, -2.0, 2.0, 1e-9);

    // Reading only the second row back, with the first one dropped, leaves an
    // ordinary satisfiable system with the same shape, so the null above
    // comes from the straddling row and not from the layout.
    var fine = lp.System.init(gpa, 2);
    defer fine.deinit();
    try fine.add(&[_]Interval{ pt(1), pt(0) }, .le, pt(-3));
    try fine.add(&[_]Interval{ pt(-1), pt(0) }, .le, pt(5));
    try fine.add(&[_]Interval{ pt(0), pt(-1) }, .le, pt(2));
    try fine.add(&[_]Interval{ pt(0), pt(1) }, .le, pt(2));
    try expectRange((try fine.bounds(0)).?, -5.0, -3.0, 1e-9);
    const fine_box = (try fine.box()).?;
    defer gpa.free(fine_box);
    try std.testing.expectEqual(@as(usize, 2), fine_box.len);
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
    // The true range of x is [-1, 4]: the straddling row reads |x| + y <= 4
    // and y reaches 0, so x stops at 4 and the x <= 5 row never binds. The
    // looser [-1, 5] this test used to pin was the answer from a coefficient
    // that reached zero and was therefore read as no bound at all, not the
    // shape of the feasible set.
    try expectRange(wide, -1.0, 4.0, 1e-9);
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
    // The two true ranges are the same interval, [-1, 4], so this compares
    // two roundings of the same two numbers rather than two nested sets, and
    // the outward widening leaves them a couple of ULPs apart in whichever
    // direction the arithmetic happened to accumulate them. Comparing them
    // exactly would be a test of which path rounds wider.
    try std.testing.expect(wide.lo <= narrow.lo + 1e-9);
    try std.testing.expect(wide.hi + 1e-9 >= narrow.hi);
    try expectRange(narrow, -1.0, 4.0, 1e-9);

    var satisfiable = true;
    try sys.eliminateAll(&satisfiable);
    try std.testing.expect(satisfiable);
    try std.testing.expect(!sys.isUnsat());
}

test "a coefficient that only reaches zero still bounds the variable" {
    var sys = lp.System.init(gpa, 2);
    defer sys.deinit();

    // [-2, 2] * x + y <= 3 and [-2, 2] * x - y <= -1. Each row has to hold
    // for every coefficient in [-2, 2], so the worst realisation of each is
    // the one on the far side of zero from x, and the pair reads
    // y <= 3 - 2 * |x| and y >= 1 + 2 * |x|. Adding them gives 4 * |x| <= 2,
    // so x is in [-0.5, 0.5] and, from the same two rows, y is in [1, 3].
    try sys.add(&[_]Interval{ Interval.init(-2.0, 2.0), pt(1) }, .le, pt(3));
    try sys.add(&[_]Interval{ Interval.init(-2.0, 2.0), pt(-1) }, .le, pt(-1));

    // One elimination round leaves a coefficient on x that straddles zero,
    // which is the case that used to read as no bound at all. Both sides are
    // now read, each off the endpoint of the coefficient farthest from zero,
    // and the answer for x is the true range.
    const bx = (try sys.bounds(0)).?;
    try expectRange(bx, -0.5, 0.5, 1e-9);
    try std.testing.expect(bx.contains(0.0));

    // The projection onto y comes back looser on the low side, which is
    // allowed and expected: a box must contain the true range, not equal it.
    // What it may not do is clip either end of it.
    const by = (try sys.bounds(1)).?;
    try std.testing.expect(by.lo <= 1.0);
    try std.testing.expect(by.hi >= 3.0);
    try std.testing.expect(by.lo >= -1.0);
    try std.testing.expect(by.hi <= 3.0 + 1e-9);

    const boxed = (try sys.box()).?;
    defer gpa.free(boxed);
    try std.testing.expectEqual(@as(usize, 2), boxed.len);
    try expectRange(boxed[0], -0.5, 0.5, 1e-9);
    try std.testing.expect(boxed[1].lo <= 1.0);
    try std.testing.expect(boxed[1].hi >= 3.0);
}

test "an uncertain coefficient does not make a satisfiable system look empty" {
    var sys = lp.System.init(gpa, 2);
    defer sys.deinit();

    // The four rows of the infeasibility report, unchanged:
    //   [-2, 2] * x                <= [0, 3]
    //   [-2, 1] * x + [-2, -1] * y <= [0, 1]
    //            [1, 2] * y         <= [3, 3]
    //    [1, 2] * x + [-1,  0] * y <= [-3, 3]
    // A coefficient interval is a universal quantifier: the row has to hold
    // for every realisation of it. The right-hand side is not. It encloses
    // one unknown bound, and the row has to hold for that single value, so
    // the test is whether some value in the right-hand side interval is at
    // least the worst case the coefficients can force on the left.
    //
    // At (0, 1) that worst case is 0, -1, 2 and 0, one per row, and every
    // one of them is inside its right-hand side. So this system has a
    // solution, a box is the right answer, and calling it infeasible would
    // be the false positive a solver like this must never produce: reading
    // the right-hand side as universal as well is what makes the reported
    // contradiction come out, and it is not the contract.
    try sys.add(&[_]Interval{ Interval.init(-2.0, 2.0), pt(0) }, .le, Interval.init(0.0, 3.0));
    try sys.add(&[_]Interval{ Interval.init(-2.0, 1.0), Interval.init(-2.0, -1.0) }, .le, Interval.init(0.0, 1.0));
    try sys.add(&[_]Interval{ pt(0), Interval.init(1.0, 2.0) }, .le, pt(3));
    try sys.add(&[_]Interval{ Interval.init(1.0, 2.0), Interval.init(-1.0, 0.0) }, .le, Interval.init(-3.0, 3.0));

    // The projection contains the witness, so it is not the empty answer
    // dressed up as a narrow one, and it stays a rigorous superset of the
    // true ranges: x really does span [-1.5, 1.5] and y spans [-0.5, 1.5].
    const bx = (try sys.bounds(0)).?;
    const by = (try sys.bounds(1)).?;
    try std.testing.expect(bx.contains(0.0));
    try std.testing.expect(by.contains(1.0));
    try expectRange(bx, -1.5, 1.5, 1e-9);
    try std.testing.expect(by.lo <= -0.5);
    try std.testing.expect(by.hi >= 1.5);
    const reported = (try sys.box()).?;
    defer gpa.free(reported);
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
        const row = try sys.at(i);
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
        const row = try sys.at(i);
        for (row.coeffs) |iv| try std.testing.expect(iv.lo <= iv.hi);
        try std.testing.expect(row.rhs.lo <= row.rhs.hi);
    }

    var satisfiable = true;
    try sys.eliminateAll(&satisfiable);
    try std.testing.expect(satisfiable);
    for (0..sys.count()) |i| {
        const row = try sys.at(i);
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
