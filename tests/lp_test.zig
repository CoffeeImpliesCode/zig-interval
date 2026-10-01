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

/// True when every coefficient is the exact zero interval. A widening
/// artefact that happens to be small is not one: a rounding-thin straddle is
/// a variable the row still mentions, and reading it as an absent one is how
/// a derived row comes to look like a contradiction when it is not.
fn allZero(coeffs: []const Interval) bool {
    for (coeffs) |iv| {
        if (iv.lo != 0.0 or iv.hi != 0.0) return false;
    }
    return true;
}

/// One constraint in exact arithmetic, for the `f128` scan below: for EVERY
/// `a` in `ax` and EVERY `b` in `ay`, the row states `a * x + b * y <= rhs`.
const Exact = struct { ax: [2]f128, ay: [2]f128, rhs: f128 };

/// Whether some `y` satisfies every row at this `x`, decided in `f128`.
///
/// A row quantifies universally over its coefficient intervals and the
/// linear form is monotone in each coefficient on its own, so the worst
/// realisation of `a * x` is one of the two endpoints and the row reduces to
///
///     max(ax[0] * x, ax[1] * x) + max(ay[0] * y, ay[1] * y) <= rhs
///
/// which bounds `y` from below, from above, or from both. Working in `f128`
/// keeps this verdict clear of the `f64` outward widening the projection
/// applies, so a disagreement points at the projection and not at the scan.
fn yExists(rows: []const Exact, x: f128) bool {
    var lo: f128 = -std.math.inf(f128);
    var hi: f128 = std.math.inf(f128);
    for (rows) |r| {
        const room = r.rhs - @max(r.ax[0] * x, r.ax[1] * x);
        for (r.ay) |c| {
            if (c == 0) {
                // A coefficient of exactly zero leaves `y` out of the row,
                // so the whole of the row's demand on this `x` has to be met
                // by the room that is left or nothing satisfies it.
                if (room < 0) return false;
                continue;
            }
            if (c > 0) hi = @min(hi, room / c);
            if (c < 0) lo = @max(lo, room / c);
        }
    }
    return lo <= hi;
}

test "normalisation: eq splits in two, ge flips, and every stored row is <= by construction" {
    var sys = try lp.System.init(gpa, 2);
    defer sys.deinit();

    const c = [_]Interval{ pt(1), pt(2) };
    try sys.add(&c, .le, pt(5));
    try sys.add(&c, .ge, pt(1));
    try sys.add(&c, .eq, pt(3));

    // One row for `le`, one for `ge`, two for the `eq` pair: THREE constraints
    // answered as FOUR rows. That gap is the whole reason the accessor is
    // named `rowCount` — a caller asking how big the system is needs the
    // normalisation rules to use this number at all.
    try std.testing.expectEqual(@as(usize, 4), sys.rowCount());

    // There is no `.op` to read back. Every stored row is `<=` by
    // construction, and the type now says so by not carrying the field at
    // all; the old assertion here read `.le` off a field a caller could have
    // written to anything else. What replaces it is that every row still
    // reads back with the shape it was stored with, one coefficient per
    // variable.
    for (0..sys.rowCount()) |i| {
        try std.testing.expectEqual(sys.varCount(), (try sys.at(i)).coeffs.len);
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

test "Lin is a read-only view: coeffs is const, and there is no op field" {
    // The permanent regression check for the two write doors A1 closed.
    //
    // `probe/row_coeffs.zig` and `probe/row_op.zig` are the compile-failure
    // probes and belong to no build step, because a file that must not
    // compile cannot be in one. These two assertions are what keep them true:
    // relax either and a probe starts compiling again, which is exactly the
    // regression worth catching.
    //
    // They are read from the type rather than by writing to a row, because a
    // successful write cannot be written down inside a test that has to
    // build.
    try std.testing.expect(!@hasField(lp.Lin, "op"));

    comptime {
        const Coeffs = @TypeOf(@as(lp.Lin, undefined).coeffs);
        if (Coeffs != []const Interval) {
            @compileError("Lin.coeffs must be []const Interval. A mutable slice " ++
                "re-opens the door A1 closed: writing through a row from at() " ++
                "edits the solver's own storage and changes what bounds, box " ++
                "and isUnsat answer, silently.");
        }
    }
}

test "init reports exhaustion instead of panicking" {
    // The one allocator call in this file that used to be unable to fail
    // visibly. Every other one propagates, and this one aborted, so a caller
    // in a program that wanted to handle exhaustion had no way to ask for
    // that; the panic decided it instead.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    failing.fail_index = 0;
    try std.testing.expectError(error.OutOfMemory, lp.System.init(failing.allocator(), 1));

    // And the same allocator with nothing failing still builds a working
    // system, so the error above is the allocator refusing and not the shape
    // of the call. A test that only proved the failure would pass against an
    // `init` that could never succeed at all.
    var ok = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var sys = try lp.System.init(ok.allocator(), 2);
    defer sys.deinit();
    try std.testing.expectEqual(@as(usize, 2), sys.varCount());
    try std.testing.expectEqual(@as(usize, 0), sys.rowCount());
}

test "at rejects a row index past the end of the system" {
    var sys = try lp.System.init(gpa, 2);
    defer sys.deinit();
    try sys.add(&[_]Interval{ pt(1), pt(0) }, .le, pt(1));
    try std.testing.expectEqual(@as(usize, 1), sys.rowCount());

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
    var empty = try lp.System.init(gpa, 1);
    defer empty.deinit();
    try std.testing.expectError(error.BadRow, empty.at(0));

    // A rejected read leaves the system alone.
    try std.testing.expectEqual(@as(usize, 1), sys.rowCount());
    try std.testing.expectEqual(@as(f64, 1.0), (try sys.at(0)).rhs.lo);
}

test "lt and gt relax outward, never inward" {
    // `x < 3` and `x > 1` describe the open range (1, 3) over the reals. A
    // closed interval cannot represent an open range, so both comparisons
    // are relaxed to their non-strict form, and the relaxation has to go
    // outward: the answer must admit the two endpoints the strict system
    // excludes, because a tighter answer would cut the feasible set.
    const one = [_]Interval{pt(1)};
    var strict = try lp.System.init(gpa, 1);
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
    var closed = try lp.System.init(gpa, 1);
    defer closed.deinit();
    try closed.add(&one, .le, pt(3));
    try closed.add(&one, .ge, pt(1));
    const exact = (try closed.bounds(0)).?;
    try std.testing.expect(relaxed.lo <= exact.lo + 1e-9);
    try std.testing.expect(relaxed.hi + 1e-9 >= exact.hi);
}

test "add rejects a coefficient vector of the wrong length" {
    var sys = try lp.System.init(gpa, 2);
    defer sys.deinit();

    const too_short = [_]Interval{pt(1)};
    try std.testing.expectError(error.BadVariableCount, sys.add(&too_short, .le, pt(1)));
    try std.testing.expectEqual(@as(usize, 0), sys.rowCount());
}

test "a bounded two-variable system projects its exact box" {
    var sys = try lp.System.init(gpa, 2);
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
    try std.testing.expectEqual(@as(usize, 4), sys.rowCount());
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
    var sys = try lp.System.init(gpa, 1);
    defer sys.deinit();

    // x <= 0 and x >= 1.
    const c = [_]Interval{pt(1)};
    try sys.add(&c, .le, pt(0));
    try sys.add(&c, .ge, pt(1));
    try std.testing.expectEqual(@as(usize, 2), sys.rowCount());
    try std.testing.expect(!sys.isUnsat());

    // Before elimination the projected bounds are already disjoint: the
    // lower side reads 1 and the upper side reads 0.
    try std.testing.expect((try sys.bounds(0)) == null);

    const satisfiable = try sys.eliminateInOrderOfChoice();
    try std.testing.expect(!satisfiable);
    try std.testing.expect(sys.isUnsat());

    // Eliminating the only variable leaves `0 <= -1` with every coefficient
    // exactly zero.
    try std.testing.expectEqual(@as(usize, 1), sys.rowCount());
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
    var sys = try lp.System.init(gpa, 2);
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
    var fine = try lp.System.init(gpa, 2);
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
    var sys = try lp.System.init(gpa, 1);
    defer sys.deinit();

    // x <= 3 and x >= 3.
    const c = [_]Interval{pt(1)};
    try sys.add(&c, .le, pt(3));
    try sys.add(&c, .ge, pt(3));

    const b = (try sys.bounds(0)).?;
    try std.testing.expect(b.contains(3.0));
    try expectRange(b, 3.0, 3.0, 1e-9);

    const satisfiable = try sys.eliminateInOrderOfChoice();
    try std.testing.expect(satisfiable);
    try std.testing.expect(!sys.isUnsat());
}

test "an unconstrained variable makes the whole box null" {
    var sys = try lp.System.init(gpa, 2);
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
    var sys = try lp.System.init(gpa, 2);
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
    var tight = try lp.System.init(gpa, 2);
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

    const satisfiable = try sys.eliminateInOrderOfChoice();
    try std.testing.expect(satisfiable);
    try std.testing.expect(!sys.isUnsat());
}

test "a coefficient that only reaches zero still bounds the variable" {
    var sys = try lp.System.init(gpa, 2);
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

test "a contradiction only the last round can see is still reported" {
    // One variable, three rows:
    //   [0, 1] * x <= -1
    //    [1, 1] * x <= -1
    //   [-1, -1] * x <= 1
    // The first row decides this system. A coefficient that TOUCHES zero is
    // not absent from the row: the row has to hold for the realisation c = 0
    // as well, and that realisation states 0 <= -1, which no x satisfies. The
    // row is false on its own, so the system is empty.
    //
    // The bounds reading cannot see that, and the reason is structural. A
    // [0, 1] coefficient is not negative, so the row contributes an UPPER
    // bound of -1 and no lower one, and the only lower bound in the system
    // comes from the third row. Read that way the answer is [-1, -1], it
    // does not cross, and the disjointness test has nothing to say either.
    // The reading is outward-widened by `Interval.div` before it is compared,
    // so what the projection would hand back with no contradiction test at
    // all is [-1.0000000000000002, -0.9999999999999999]: a non-empty
    // interval around a point that satisfies nothing. Reporting that is the
    // failure this library must never produce, because a caller reads it as
    // "solutions exist, and here is where x is" and is then wrong at every
    // point of the answer.
    //
    // What catches the row is the LAST round of `bounds`, the one that drops
    // k after the bounds have been read. The [0, 1] coefficient splits there,
    // and its lower part [0, 0] lands in the lower bucket. Paired against the
    // strictly positive second row, that zero multiplier derives a row whose
    // every coefficient is exactly zero and whose right-hand side is
    // negative: `0 <= -1` with nothing left to satisfy it. That is the
    // contradiction test, and the answer is null. Remove the round and this
    // system comes back as the interval above.
    var sys = try lp.System.init(gpa, 1);
    defer sys.deinit();
    try sys.add(&[_]Interval{Interval.init(0.0, 1.0)}, .le, pt(-1));
    try sys.add(&[_]Interval{pt(1)}, .le, pt(-1));
    try sys.add(&[_]Interval{pt(-1)}, .le, pt(1));
    try std.testing.expectEqual(@as(usize, 3), sys.rowCount());

    // Nothing is wrong with the storage, so `isUnsat` still says no and the
    // caller's system is untouched: the emptiness is the projection's to find.
    try std.testing.expect(!sys.isUnsat());
    try std.testing.expect((try sys.bounds(0)) == null);
    try std.testing.expect((try sys.box()) == null);

    // Driven to zero variables the same system says why. Every surviving row
    // is a constant constraint, and at least one of them is the contradiction
    // the reading could not see.
    const satisfiable = try sys.eliminateInOrderOfChoice();
    try std.testing.expect(!satisfiable);
    try std.testing.expect(sys.isUnsat());
    var contradiction = false;
    for (0..sys.rowCount()) |i| {
        const row = try sys.at(i);
        if (allZero(row.coeffs) and row.rhs.hi < 0) contradiction = true;
    }
    try std.testing.expect(contradiction);
}

test "the same system one unit away is not a contradiction" {
    // The system above with ONE number changed: the first row's right-hand
    // side moves from -1 to 0. Everything else is the same system - the same
    // three rows, the same [0, 1] coefficient, and the same [0, 0] multiplier
    // reaching the final round.
    //
    // That single step is what the boundary is made of, and it is the whole
    // reason the last round is a predicate over pairs of rows rather than a
    // scan for zero-touching coefficients. At rhs 0 the c = 0 realisation
    // states 0 <= 0, which is true, so the system IS satisfiable: x = -1
    // satisfies [0, 1] * x <= 0 (c = 0 gives 0 <= 0, c = 1 gives -1 <= 0),
    // x <= -1 and x >= -1 all at once. The true range of x is the singleton
    // {-1}, and a null here reports a satisfiable system as unsatisfiable.
    //
    // On this side and the one above the two errors are the same size and
    // neither is the safe one. A missed contradiction hands an unsatisfiable
    // system back as a non-empty interval, so a caller reasons about
    // solutions that do not exist. An invented one reports a satisfiable
    // system as empty, so a caller discards solutions that do. Both cut the
    // feasible set, cutting it is the one failure this library has no answer
    // for, and the two tests are the pair that says the predicate has to be
    // right on both sides of the same boundary.
    var sys = try lp.System.init(gpa, 1);
    defer sys.deinit();
    try sys.add(&[_]Interval{Interval.init(0.0, 1.0)}, .le, pt(0));
    try sys.add(&[_]Interval{pt(1)}, .le, pt(-1));
    try sys.add(&[_]Interval{pt(-1)}, .le, pt(1));

    // The answer is NOT the exact singleton. Every endpoint of a reading
    // comes out of `Interval.div`, which steps its result one ULP outward
    // even when the quotient is exact, so the singleton comes back as
    // [-1.0000000000000002, -0.9999999999999999]: the one feasible point
    // with a part in 10^16 of slack on each side. The pin is that widened
    // interval and not [-1, -1]; the containment below is the part of it
    // that carries the contract.
    const maybe = try sys.bounds(0);
    try std.testing.expect(maybe != null);
    try std.testing.expectEqual(@as(?Interval, Interval.init(-1.0000000000000002, -0.9999999999999999)), maybe);
    const got = maybe.?;
    try std.testing.expect(got.contains(-1.0));
    try std.testing.expect(got.lo <= got.hi);
    try expectRange(got, -1.0, -1.0, 1e-9);

    // And the system really is satisfiable, checked the long way round: with
    // every variable driven out, no constant row contradicts.
    const maybe_box = try sys.box();
    try std.testing.expect(maybe_box != null);
    const boxed = maybe_box.?;
    defer gpa.free(boxed);
    try expectRange(boxed[0], -1.0, -1.0, 1e-9);
    const satisfiable = try sys.eliminateInOrderOfChoice();
    try std.testing.expect(satisfiable);
    try std.testing.expect(!sys.isUnsat());
    for (0..sys.rowCount()) |i| {
        const row = try sys.at(i);
        try std.testing.expect(!allZero(row.coeffs) or row.rhs.hi >= 0);
    }
}

test "a straddling system with a finite answer still hands that answer back" {
    // Four rows over two variables, and every coefficient is an interval
    // that straddles zero:
    //   [-1, 1] * x + [-1, 1] * y <= 1
    //   [-1, 0] * x + [-1, 0] * y <= 0
    //   [-1, 0] * x               <= 0
    //            [0, 1] * x       <= 1
    // Read as universal quantifiers the first row is |x| + |y| <= 1 and the
    // second is max(-x, 0) + max(-y, 0) <= 0, which can only hold with
    // x >= 0 and y >= 0. The feasible set is then the triangle
    // x >= 0, y >= 0, x + y <= 1, and the true range of each variable is
    // [0, 1].
    var sys = try lp.System.init(gpa, 2);
    defer sys.deinit();
    try sys.add(&[_]Interval{ Interval.init(-1.0, 1.0), Interval.init(-1.0, 1.0) }, .le, pt(1));
    try sys.add(&[_]Interval{ Interval.init(-1.0, 0.0), Interval.init(-1.0, 0.0) }, .le, pt(0));
    try sys.add(&[_]Interval{ Interval.init(-1.0, 0.0), pt(0) }, .le, pt(0));
    try sys.add(&[_]Interval{ Interval.init(0.0, 1.0), pt(0) }, .le, pt(1));
    try std.testing.expectEqual(@as(usize, 4), sys.rowCount());

    // The true range, computed here in f128 from the rows above instead of
    // from the projection, so the two are independent of each other. x = 0
    // and x = 1 are both feasible, at y = 0, and the first row denies every
    // x outside: a quarter of a unit past either end has no y at all, not
    // even one a later widening could call satisfiable.
    const rows = [_]Exact{
        .{ .ax = .{ -1, 1 }, .ay = .{ -1, 1 }, .rhs = 1 },
        .{ .ax = .{ -1, 0 }, .ay = .{ -1, 0 }, .rhs = 0 },
        .{ .ax = .{ -1, 0 }, .ay = .{ 0, 0 }, .rhs = 0 },
        .{ .ax = .{ 0, 1 }, .ay = .{ 0, 0 }, .rhs = 1 },
    };
    try std.testing.expect(yExists(&rows, 0));
    try std.testing.expect(yExists(&rows, 0.5));
    try std.testing.expect(yExists(&rows, 1));
    try std.testing.expect(!yExists(&rows, -0.25));
    try std.testing.expect(!yExists(&rows, 1.25));

    // A straddling coefficient is what the last round is most likely to
    // mishandle, because a row derived from one can come back with a
    // coefficient that touches zero. The answer here is finite, so a
    // contradiction that is not there has to leave it alone.
    const maybe_x = try sys.bounds(0);
    try std.testing.expect(maybe_x != null);
    const bx = maybe_x.?;
    const maybe_y = try sys.bounds(1);
    try std.testing.expect(maybe_y != null);
    const by = maybe_y.?;
    try std.testing.expect(bx.lo <= bx.hi);
    try std.testing.expect(by.lo <= by.hi);
    try expectRange(bx, 0.0, 1.0, 1e-9);
    try expectRange(by, 0.0, 1.0, 1e-9);
    // Both ends of the true range are in the answer, and they are feasible
    // points rather than merely numbers inside a range.
    try std.testing.expect(bx.contains(0.0));
    try std.testing.expect(bx.contains(1.0));
    try std.testing.expect(by.contains(0.0));
    try std.testing.expect(by.contains(1.0));

    const maybe_box = try sys.box();
    try std.testing.expect(maybe_box != null);
    const boxed = maybe_box.?;
    defer gpa.free(boxed);
    try std.testing.expectEqual(@as(usize, 2), boxed.len);
    try expectRange(boxed[0], 0.0, 1.0, 1e-9);
    try expectRange(boxed[1], 0.0, 1.0, 1e-9);

    // The triangle is not empty, so no round of elimination may claim it is.
    const satisfiable = try sys.eliminateInOrderOfChoice();
    try std.testing.expect(satisfiable);
    try std.testing.expect(!sys.isUnsat());
}

test "one unit of slack separates the empty system from the feasible one" {
    // Both directions of the last round, on one two-variable system and on
    // its twin:
    //   [0, 1] * x <= r,  x <= -1,  x >= -1,  y >= -4,  y <= 4
    // with r = -1 in one and r = 0 in the other and nothing else changed.
    //
    // r = -1 is empty: the c = 0 realisation of the first row states
    // 0 <= -1, whatever x and y are. r = 0 is satisfiable at x = -1 with y
    // anywhere in [-4, 4]. The f128 scan says so without the library, and
    // that is what makes the two answers below statements about the systems
    // rather than about the projection.
    //
    // Both failure modes of a predicate over pairs of rows show up here as a
    // wrong answer on one side or the other: a predicate that never fires
    // hands the empty twin a non-empty interval, and a predicate that fires
    // on a hair's breadth empties the feasible twin. The two systems are one
    // unit apart in one right-hand side, so no slack in the threshold passes
    // both - the boundary has to sit exactly where the enclosure puts it.
    const dead_rows = [_]Exact{
        .{ .ax = .{ 0, 1 }, .ay = .{ 0, 0 }, .rhs = -1 },
        .{ .ax = .{ 1, 1 }, .ay = .{ 0, 0 }, .rhs = -1 },
        .{ .ax = .{ -1, -1 }, .ay = .{ 0, 0 }, .rhs = 1 },
        .{ .ax = .{ 0, 0 }, .ay = .{ -1, -1 }, .rhs = 4 },
        .{ .ax = .{ 0, 0 }, .ay = .{ 1, 1 }, .rhs = 4 },
    };
    try std.testing.expect(!yExists(&dead_rows, -1));
    try std.testing.expect(!yExists(&dead_rows, 0));
    try std.testing.expect(!yExists(&dead_rows, 4));

    var dead = try lp.System.init(gpa, 2);
    defer dead.deinit();
    try dead.add(&[_]Interval{ Interval.init(0.0, 1.0), pt(0) }, .le, pt(-1));
    try dead.add(&[_]Interval{ pt(1), pt(0) }, .le, pt(-1));
    try dead.add(&[_]Interval{ pt(-1), pt(0) }, .le, pt(1));
    try dead.add(&[_]Interval{ pt(0), pt(-1) }, .le, pt(4));
    try dead.add(&[_]Interval{ pt(0), pt(1) }, .le, pt(4));

    // Emptiness is a property of the system and not of the variable asked
    // about, so every projection of it is null and so is the box.
    try std.testing.expect(!dead.isUnsat());
    try std.testing.expect((try dead.bounds(0)) == null);
    try std.testing.expect((try dead.bounds(1)) == null);
    try std.testing.expect((try dead.box()) == null);
    const still_dead = try dead.eliminateInOrderOfChoice();
    try std.testing.expect(!still_dead);
    try std.testing.expect(dead.isUnsat());

    const live_rows = [_]Exact{
        .{ .ax = .{ 0, 1 }, .ay = .{ 0, 0 }, .rhs = 0 },
        .{ .ax = .{ 1, 1 }, .ay = .{ 0, 0 }, .rhs = -1 },
        .{ .ax = .{ -1, -1 }, .ay = .{ 0, 0 }, .rhs = 1 },
        .{ .ax = .{ 0, 0 }, .ay = .{ -1, -1 }, .rhs = 4 },
        .{ .ax = .{ 0, 0 }, .ay = .{ 1, 1 }, .rhs = 4 },
    };
    // The feasible twin has exactly one feasible x, and it is -1.
    try std.testing.expect(yExists(&live_rows, -1));
    try std.testing.expect(!yExists(&live_rows, -2));
    try std.testing.expect(!yExists(&live_rows, 0));

    var live = try lp.System.init(gpa, 2);
    defer live.deinit();
    try live.add(&[_]Interval{ Interval.init(0.0, 1.0), pt(0) }, .le, pt(0));
    try live.add(&[_]Interval{ pt(1), pt(0) }, .le, pt(-1));
    try live.add(&[_]Interval{ pt(-1), pt(0) }, .le, pt(1));
    try live.add(&[_]Interval{ pt(0), pt(-1) }, .le, pt(4));
    try live.add(&[_]Interval{ pt(0), pt(1) }, .le, pt(4));

    const maybe_lx = try live.bounds(0);
    try std.testing.expect(maybe_lx != null);
    const lx = maybe_lx.?;
    const maybe_ly = try live.bounds(1);
    try std.testing.expect(maybe_ly != null);
    const ly = maybe_ly.?;
    try std.testing.expect(lx.contains(-1.0));
    try std.testing.expect(lx.lo <= lx.hi);
    try std.testing.expect(ly.lo <= ly.hi);
    try expectRange(lx, -1.0, -1.0, 1e-9);
    try expectRange(ly, -4.0, 4.0, 1e-9);

    const maybe_box = try live.box();
    try std.testing.expect(maybe_box != null);
    const boxed = maybe_box.?;
    defer gpa.free(boxed);
    try std.testing.expectEqual(@as(usize, 2), boxed.len);
    try expectRange(boxed[0], -1.0, -1.0, 1e-9);
    try expectRange(boxed[1], -4.0, 4.0, 1e-9);
    const alive = try live.eliminateInOrderOfChoice();
    try std.testing.expect(alive);
    try std.testing.expect(!live.isUnsat());
}

test "an uncertain coefficient does not make a satisfiable system look empty" {
    var sys = try lp.System.init(gpa, 2);
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
    var sys = try lp.System.init(gpa, 3);
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
    const satisfiable = try sys.eliminateInOrderOfChoice();
    try std.testing.expect(satisfiable);
    try std.testing.expect(sys.rowCount() > 0);
    for (0..sys.rowCount()) |i| {
        const row = try sys.at(i);
        for (row.coeffs) |iv| {
            try std.testing.expectEqual(@as(f64, 0.0), iv.lo);
            try std.testing.expectEqual(@as(f64, 0.0), iv.hi);
        }
        try std.testing.expect(row.rhs.hi >= 0);
    }
}

test "eliminate rejects a bad or already eliminated variable" {
    var sys = try lp.System.init(gpa, 2);
    defer sys.deinit();

    try addPoints(&sys, &.{ 1, 0 }, 2);
    try addPoints(&sys, &.{ -1, 0 }, -2);

    try std.testing.expectError(error.BadVariable, sys.eliminate(2));
    try sys.eliminate(0);
    try std.testing.expectError(error.VariableEliminated, sys.eliminate(0));
}

test "a well-posed three-variable system projects [0, 6] in every slot" {
    var sys = try lp.System.init(gpa, 3);
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
    for (0..sys.rowCount()) |i| {
        const row = try sys.at(i);
        for (row.coeffs) |iv| try std.testing.expect(iv.lo <= iv.hi);
        try std.testing.expect(row.rhs.lo <= row.rhs.hi);
    }

    const satisfiable = try sys.eliminateInOrderOfChoice();
    try std.testing.expect(satisfiable);
    for (0..sys.rowCount()) |i| {
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

    var sys = try lp.System.init(gpa, 4);
    defer sys.deinit();
    for (rows, rhs) |r, b| try addPoints(&sys, r, b);
    try std.testing.expectEqual(@as(usize, 5), sys.rowCount());

    const order = try sys.eliminationOrder();
    defer gpa.free(order);
    try std.testing.expectEqual(@as(usize, 4), order.len);
    try std.testing.expectEqual(@as(usize, 1), order[0]);
    try std.testing.expect(!std.mem.eql(usize, order, &worst));

    // Drive both orders by hand and record how many rows each step produced.
    var good = try lp.System.init(gpa, 4);
    defer good.deinit();
    for (rows, rhs) |r, b| try addPoints(&good, r, b);
    var good_peak = good.rowCount();
    for (order) |k| {
        try good.eliminate(k);
        good_peak = @max(good_peak, good.rowCount());
    }

    var bad = try lp.System.init(gpa, 4);
    defer bad.deinit();
    for (rows, rhs) |r, b| try addPoints(&bad, r, b);
    var bad_peak = bad.rowCount();
    for (worst) |k| {
        try bad.eliminate(k);
        bad_peak = @max(bad_peak, bad.rowCount());
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
    try std.testing.expect(good.rowCount() <= bad.rowCount());
    try std.testing.expect(good.rowCount() < bad.rowCount());
    try std.testing.expect(good_peak <= 8);
    try std.testing.expect(bad_peak >= 20);

    // And the shipped path agrees with the plan it advertises.
    var chosen = try lp.System.init(gpa, 4);
    defer chosen.deinit();
    for (rows, rhs) |r, b| try addPoints(&chosen, r, b);
    try std.testing.expect(try chosen.eliminateInOrderOfChoice());
    try std.testing.expect(chosen.rowCount() <= bad.rowCount());
    try std.testing.expectEqual(@as(usize, good.rowCount()), chosen.rowCount());
}

test "a cancelling pair of products is stored as the structural zero" {
    // Four rows over two variables, of which the third is what makes the
    // projection bounded:
    //
    //     x + y <= 1        r0
    //     x + y >= 0        r1, stored as -x - y <= 0
    //     y     <= 0        r2
    //     x     <= 10       r3
    //
    // Eliminating y pairs r1 against r0 and against r2. The first pair is the
    // one that cancels: its x coefficient is `1 * -1 - (-1 * 1)`, zero for
    // every realisation of the four operands, and its y coefficient is zero by
    // construction, so the row it derives is `0 <= 1` and mentions neither
    // variable. The second pair is ordinary.
    //
    // Nothing about that is fragile except how it is STORED. Each product
    // goes through `Interval.mul`, which widens outward even when the product
    // is exact, so the two products are equal WIDENED intervals and their
    // difference is widened again: [-1.0000000000000002, -0.9999999999999999]
    // minus itself came back as [-3.33e-16, 3.33e-16], one ULP of 1 either side
    // of zero. `isExactZero` calls that a coefficient, the next round pairs
    // rows that share no variable, and `bounds` divides a right-hand side by
    // an endpoint of it.
    var sys = try lp.System.init(gpa, 2);
    defer sys.deinit();
    try sys.add(&[_]Interval{ pt(1), pt(1) }, .le, pt(1));
    try sys.add(&[_]Interval{ pt(1), pt(1) }, .ge, pt(0));
    try sys.add(&[_]Interval{ pt(0), pt(1) }, .le, pt(0));
    try sys.add(&[_]Interval{ pt(1), pt(0) }, .le, pt(10));

    // The round is driven by hand because `bounds` runs it on a scratch copy,
    // and the row it reads there is not observable from outside it.
    var drive = try lp.System.init(gpa, 2);
    defer drive.deinit();
    try drive.add(&[_]Interval{ pt(1), pt(1) }, .le, pt(1));
    try drive.add(&[_]Interval{ pt(1), pt(1) }, .ge, pt(0));
    try drive.add(&[_]Interval{ pt(0), pt(1) }, .le, pt(0));
    try drive.add(&[_]Interval{ pt(1), pt(0) }, .le, pt(10));
    try drive.eliminate(1);
    try std.testing.expectEqual(@as(usize, 3), drive.rowCount());

    // The cancelled row is found by its right-hand side, `1 * 0 - (-1 * 1)` =
    // 1, which belongs to no other row in this system, rather than by where
    // it landed in the list.
    var cancelling: ?lp.Lin = null;
    for (0..drive.rowCount()) |i| {
        const row = try drive.at(i);
        if (row.rhs.lo <= 1.5 and 0.5 <= row.rhs.hi) cancelling = row;
    }
    try std.testing.expect(cancelling != null);

    // The invariant as an equality and not as a magnitude. A coefficient whose
    // exact value is zero says the variable is absent from the row, and
    // [0, 0] is the only interval that says it; a straddle says the opposite,
    // that the variable reaches both sides of zero. Nothing here asks whether
    // the stored value is SMALL, because a coefficient of 1e-300 is a
    // coefficient and is stored as such.
    try std.testing.expectEqual(Interval.init(0.0, 0.0), cancelling.?.coeffs[0]);
    try std.testing.expectEqual(Interval.init(0.0, 0.0), cancelling.?.coeffs[1]);

    // Writing that zero costs the projection nothing. The true range of x is
    // [0, 10] - x >= -y >= 0 from r1 with r2, and x <= 10 from r3, and both
    // ends are attained at y = 0 and at y = -10 - while the true range of y is
    // [-10, 0]. Both answers were [-0, 10.000000000000002] and
    // [-10.000000000000007, 0] before the change and are still that: the
    // cancelled row was contributing 3.0e15 on each side of each variable and
    // neither figure was anywhere near the binding one.
    try expectRange((try sys.bounds(0)).?, 0.0, 10.0, 1e-9);
    try expectRange((try sys.bounds(1)).?, -10.0, 0.0, 1e-9);
}

test "a cancelled row that constrains nothing bounds nothing" {
    // The same cancellation with one row fewer:
    //
    //     x + y <= 1        r0
    //     x + y >= 0        r1, stored as -x - y <= 0
    //     x     <= 10       r2
    //
    // Pairing r0 with r1 derives `0 <= 1` again, a row that mentions neither
    // variable and so constrains neither.
    //
    // Neither variable is bounded here, and that is the mathematics rather
    // than an artefact of this change. For any x <= 10 put y = -x: then
    // x + y = 0 satisfies both of the first two rows, so the projection of x
    // is (-inf, 10]. For any y >= -10 put x = -y, which satisfies x <= 10 the
    // same way, so the projection of y is [-10, inf).
    //
    // Before the change this system answered [-3002399751580332,
    // 10.000000000000002] for x and [-10.000000000000007, 3002399751580332]
    // for y. The two figures of 3.0e15 are read off one endpoint of a
    // coefficient that is exactly zero, and reported for a row that does not
    // contain the variable. Each one was the only candidate on the side it
    // landed on - `bounds` keeps the tightest lower bound and the tightest
    // upper bound - and 3.0e15 is not out of range, it is merely absurd, which
    // an enclosure has no test for.
    var sys = try lp.System.init(gpa, 2);
    defer sys.deinit();
    try sys.add(&[_]Interval{ pt(1), pt(1) }, .le, pt(1));
    try sys.add(&[_]Interval{ pt(1), pt(1) }, .ge, pt(0));
    try sys.add(&[_]Interval{ pt(1), pt(0) }, .le, pt(10));

    // The cancelled pair is the only row that mentions nothing, so it is the
    // only all-zero row after the round, and the reader may take no bound from
    // it. One ULP either side of zero is not a structural zero and this count
    // was zero before the change.
    var drive = try lp.System.init(gpa, 2);
    defer drive.deinit();
    try drive.add(&[_]Interval{ pt(1), pt(1) }, .le, pt(1));
    try drive.add(&[_]Interval{ pt(1), pt(1) }, .ge, pt(0));
    try drive.add(&[_]Interval{ pt(1), pt(0) }, .le, pt(10));
    try drive.eliminate(1);
    var all_zero_rows: usize = 0;
    for (0..drive.rowCount()) |i| {
        const row = try drive.at(i);
        if (allZero(row.coeffs)) all_zero_rows += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), all_zero_rows);

    // Unbounded is how `bounds` reports a variable with no bound on one side,
    // and here it is the truth on both sides of both variables.
    try std.testing.expect((try sys.bounds(0)) == null);
    try std.testing.expect((try sys.bounds(1)) == null);
    try std.testing.expect((try sys.box()) == null);
}

test "a poisoned coefficient enters one bucket whole and is never split" {
    // Both endpoints, because a NaN in either one is the same poison and the
    // two are not symmetric in what the old rule did to them.
    //
    // A poison cannot be built with `Interval.init`: `init` IS the trap site,
    // so `Interval.init(-5.0, nan)` would abort inside the setup of this test
    // and say nothing at all about the partition. A struct literal is how a
    // poisoned interval actually arrives from outside the type - a scalar
    // read off some earlier computation rather than an interval anybody
    // produced through the checked constructor - and `tests/nan_probe.zig`
    // stages its operands the same way for the same reason.
    const nan = std.math.nan(f64);
    const cases = [_]struct { coeff: Interval, lo_nan: bool, hi_nan: bool, kept: f64 }{
        .{ .coeff = .{ .lo = -5.0, .hi = nan }, .lo_nan = false, .hi_nan = true, .kept = -5.0 },
        .{ .coeff = .{ .lo = nan, .hi = 5.0 }, .lo_nan = true, .hi_nan = false, .kept = 5.0 },
    };

    for (cases) |case| {
        var sys = try lp.System.init(gpa, 1);
        defer sys.deinit();
        try sys.add(&[_]Interval{case.coeff}, .le, pt(1));

        const part = try sys.partition(0);
        defer part.deinit();

        // WHAT THE OLD RULE DID, AND WHY IT WAS NOT COSMETIC. The partition
        // used to read the sign through a private classifier of its own whose
        // last arm was a bare `return .straddle`. A NaN endpoint compares
        // false in every direction, so it fell out of the two ordered arms and
        // landed on that one: a poison was reported as REACHING ZERO. The two
        // pieces of a straddle are then derived through `@min` and `@max`,
        // which are specified to answer with the non-NaN operand, and that is
        // where the poison stops being a poison. From `[-5, NaN]` the lower
        // piece comes out as `(-5, 0)` - `@min(NaN, 0.0)` is `0.0` - which
        // passes `lo <= hi` and is a well-formed constraint on x_0: bounded
        // from below by -5 and carrying no trace of the operand that was never
        // a number. From `[NaN, 5]` the lower piece is `(NaN, 0)`, not even a
        // legal interval, and `Interval.init` aborts on it immediately. The
        // two rows are the same defect seen from two ends, and the first is
        // the dangerous one precisely because it does not look like anything.
        //
        // The rule is now `Interval.signOf`, which computes its last arm as a
        // comparison rather than as the absence of a better answer, so a NaN
        // fails the test for reaching zero and answers `negative`. The row is
        // filed in ONE list carrying its coefficient through UNCHANGED, and
        // the poison survives to the first `Interval.init` that meets it. That
        // is the pinned NaN contract arriving through this door rather than a
        // fourth case computed here, and it is why a classifier whose own
        // answer runs arithmetic on the operand cannot be trusted to have
        // classified correctly.
        //
        // ONE bucket, and the one a wholly negative coefficient goes to. Not
        // both, which is what a straddle means and would pair the row against
        // itself; not `carried`, which means the row does not mention the
        // variable at all and is reserved for an exact [0, 0].
        try std.testing.expectEqual(@as(usize, 0), part.carried.len);
        try std.testing.expectEqual(@as(usize, 1), part.lower.len);
        try std.testing.expectEqual(@as(usize, 0), part.upper.len);

        // The regression itself, named. `[NaN, 5]` and `[-5, NaN]` each came
        // back as ONE piece, and the piece came back clean.
        try std.testing.expectEqual(@as(usize, 0), part.rowsProduced());

        // THE REGRESSION, AS THE THING THAT MUST NOT HAPPEN. `@min` and
        // `@max` cannot return a NaN - that is the whole reason the split
        // laundered the poison - so a piece that still carries one was not
        // split. Checked with `isNan` and not with an equality, because a NaN
        // equals nothing including itself, and a plain comparison against the
        // laundered `[-5, 0]` would pass on any endpoint that merely happened
        // to be finite.
        const got = part.lower[0].coeff;
        try std.testing.expect(std.math.isNan(got.lo) or std.math.isNan(got.hi));
        try std.testing.expectEqual(case.lo_nan, std.math.isNan(got.lo));
        try std.testing.expectEqual(case.hi_nan, std.math.isNan(got.hi));

        // Whole, not merely poisoned: the one endpoint that was a real number
        // is still that number. A rule that kept the NaN and moved the other
        // end would be a different defect, and this is the line that catches
        // it.
        try std.testing.expectEqual(case.kept, if (case.hi_nan) got.lo else got.hi);
    }
}

test "the row-budget count reads a poisoned coefficient the same way" {
    // `rowsAfterEliminating` is the question `bench/bench_lp.zig` asks on
    // every elimination it drives, inside the timed region of each one, and it
    // is answered by the rule above read through a sink that COUNTS instead
    // of one that STORES. A counting sink that disagreed with a storing one
    // would be a gate agreeing with itself while the solver disagreed with
    // both, so the two are pinned against each other here and against one
    // concrete system, not against a table of counts.
    //
    // Three rows over one variable, of which only the first is poisoned:
    //
    //     [-5, NaN] * x <= 1   the poison
    //     [-1,    1] * x <= 1   a genuine straddle, so it fills both lists
    //     [ 1,    1] * x <= 1   a genuine upper bound
    //
    // The straddle is what keeps the counts from being trivial: the side
    // lists are {poison, straddle} and {straddle, upper}, and the round emits
    // their cross product. Nothing is carried, so no row here is structural.
    var sys = try lp.System.init(gpa, 1);
    defer sys.deinit();
    try sys.add(&[_]Interval{.{ .lo = -5.0, .hi = std.math.nan(f64) }}, .le, pt(1));
    try sys.add(&[_]Interval{Interval.init(-1.0, 1.0)}, .le, pt(1));
    try sys.add(&[_]Interval{pt(1)}, .le, pt(1));

    const part = try sys.partition(0);
    defer part.deinit();
    try std.testing.expectEqual(@as(usize, 0), part.carried.len);
    try std.testing.expectEqual(@as(usize, 2), part.lower.len);
    try std.testing.expectEqual(@as(usize, 2), part.upper.len);
    try std.testing.expectEqual(@as(usize, 4), part.rowsProduced());
    try std.testing.expectEqual(part.rowsProduced(), try sys.rowsAfterEliminating(0));

    // Exactly one piece in the whole partition is poisoned, and it is the row
    // that went in whole. Counted rather than indexed, so the pin does not
    // depend on where the row landed in the list. A split would have left two
    // clean pieces and put the row into `upper` as well, and this is the
    // assertion that says so.
    var poisoned: usize = 0;
    for (part.lower) |p| {
        if (std.math.isNan(p.coeff.lo) or std.math.isNan(p.coeff.hi)) poisoned += 1;
    }
    for (part.upper) |p| {
        if (std.math.isNan(p.coeff.lo) or std.math.isNan(p.coeff.hi)) poisoned += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), poisoned);

    // The poison changes nothing about the SHAPE of the round. Swapping the
    // NaN for the real endpoint it was hiding gives the same two lists and the
    // same four rows, which is what a poison that reaches zero would not: it
    // would add an entry to `upper` and the count would be six. Read together
    // with the assertion above, the two systems differ in exactly one way - the
    // NaN is still in the multiplier - and the round cannot see the difference,
    // which is the point of routing a poison through ONE bucket rather than
    // two.
    var clean = try lp.System.init(gpa, 1);
    defer clean.deinit();
    try clean.add(&[_]Interval{Interval.init(-5.0, -5.0)}, .le, pt(1));
    try clean.add(&[_]Interval{Interval.init(-1.0, 1.0)}, .le, pt(1));
    try clean.add(&[_]Interval{pt(1)}, .le, pt(1));
    const clean_part = try clean.partition(0);
    defer clean_part.deinit();
    try std.testing.expectEqual(clean_part.lower.len, part.lower.len);
    try std.testing.expectEqual(clean_part.upper.len, part.upper.len);
    try std.testing.expectEqual(clean_part.rowsProduced(), part.rowsProduced());
    try std.testing.expectEqual(try clean.rowsAfterEliminating(0), try sys.rowsAfterEliminating(0));
}
