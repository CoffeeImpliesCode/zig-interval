//! The four-geometry trigonometric surface: four geometries, six functions,
//! and the three questions one can ask of each of them -- the value, the
//! principal inverse, and the whole inverse family.
//!
//! ## Where the truth in this file comes from
//!
//! Every assertion is one of five kinds, and the file never mixes them
//! silently.
//!
//!  1. **Exact rational witnesses.** The angle is written as an exact
//!     multiple of pi over a small integer, and the value is a rational
//!     number exact in binary: 0, 1, -1, 1/2, -1/2, 2, -2. The circle at
//!     pi/3 and pi/6, the diamond at pi/4 and 3pi/4, and the square at
//!     pi/4, 3pi/4 and 5pi/4 all hand out complete tables of these. The
//!     diamond at pi/4 and the square at pi/4 pin all six functions at
//!     once. For those rows the only honest assertion is containment: the
//!     enclosure must hold the number, and nothing here says how wide it
//!     is.
//!  2. **Proved windows.** A few transcendental values are pinned by an
//!     inequality rather than by a decimal. `acosh(3/2)` is inside
//!     [0.9, 1.1] because `cosh(0.9) < 3/2 < cosh(1.1)`; each such row
//!     carries the inequality that proves it. These come out of the
//!     power series at 0 with enough terms that the inequality is not
//!     close, never out of a printed approximation.
//!  3. **Round trips and range facts.** `asin(sin(theta))` has to contain
//!     `theta`. `coth(1) > 1.25`, so `coth` over `[1,2]` has to reach
//!     `1.25`. `sech(1) <= 2/3`, so `sech` over `[0,1]` has to come back
//!     under `0.7`. The square normalizes by `max(|c|,|s|)`, so at least
//!     one of its two coordinates is exactly one at every angle. These
//!     need no oracle at all.
//!  4. **Lattice facts.** The full inverse family of `sin` at the value
//!     zero has branch k at k*pi; the family of `csc` at the value two
//!     has branch k at `(-1)^k * pi/6 + k*pi`; the family of `cot` at the
//!     value one has branch k at `pi/4 + k*pi`. Each of those is an exact
//!     consequence of the definition and each is checked for negative k as
//!     well as positive.
//!  5. **Periodicity**, stated once with exact values: an angle one period
//!     away has the same exact value, for all six functions of all four
//!     geometries.
//!
//! Two things about the arguments are worth saying out loud, because both
//! are ways a witness can quietly stop being one.
//!
//! No f64 is exactly `pi/2`, `pi` or `3pi/4`; only zero is an exactly
//! representable multiple of pi. A witness for such an angle is therefore
//! an interval a couple of steps wide, built outward from
//! `interval.piDown()` and `interval.piUp()` rather than from a rounded
//! value of pi, and the pole of the tangent at `pi/2` is INSIDE that
//! interval rather than being it. So the tangent over a `pi/2` witness has
//! an enormous image and not an empty one, and a pole is given an empty
//! image only by asking about the exact point zero, which is the one pole
//! that is exactly representable. The pole behaviour itself is checked by
//! straddling the pole by a width of a millionth, where the size of the
//! answer can be proved rather than guessed. The flat tops of the square
//! are witnessed the same way, from the certified bounds on pi, so the
//! interior angle of a plateau is an interval the test can name rather
//! than a point it has to trust.
//!
//! One thing about the ASSERTIONS is worth stating separately, because it
//! decides how they would react to the library getting better. Where the
//! truth is a number exact in binary -- zero, one, minus one, a half, two
//! -- the answer is required to CONTAIN it, exactly, and those are the
//! sharpest assertions in this file. Where the truth is an angle, the only
//! handle on it is a witness interval built outward from the certified
//! bounds on pi, which is necessarily a couple of steps wider than the
//! angle itself. An answer that is the TIGHT bracket of the true angle is
//! therefore NARROWER than that witness, so requiring it to enclose the
//! witness would be requiring the library to be sloppier than the evidence
//! allows. Those assertions ask for a non-empty intersection with the
//! witness instead. The witnesses are around 1e-16 wide, so an intersection
//! still pins the answer's position to within about an ulp of the true
//! angle -- a wrong sign, period, lattice index or branch is many orders of
//! magnitude away and cannot touch the window -- while surviving any
//! honest improvement in width. Asserting containment against a padded copy
//! of the angle would have been testing the oracle, not the mathematics.
//!
//! There is no decimal of pi and no `std.math` value of any transcendental
//! function anywhere in this file. The nearest double
//! to pi is an empirical measurement of a number that is not exact in
//! binary; pinning it would pin the rounding rather than the mathematics.
//! A rounded f64 point value is likewise not the truth of a
//! transcendental function, and asserting equality against one pins the
//! width of the enclosure rather than its correctness. The witnesses
//! themselves are checked by exact rational arithmetic instead -- that two
//! pi/4 make a pi, that six pi/6 make a pi, that a negative multiplier
//! mirrors the interval exactly -- none of which needs a value of pi. See
//! `tests/interval_ext_test.zig` for that argument at length; this file
//! takes the same side of it.
//!
//! The convention for the two polygons is the one the contract fixes: the
//! radial angle is in radians, and with `s = sin(theta)`, `c = cos(theta)`
//! the diamond point is `(c, s) / (|c| + |s|)` and the square point is
//! `(c, s) / max(|c|, |s|)`. Every polygon witness below is a consequence
//! of that formula and of nothing else. No claim is made about what any
//! other program does with a polygon.

const std = @import("std");
const interval = @import("interval");
const Interval = interval.Interval;
const trig = interval.trig;

const Geometry = trig.Geometry;
const Function = trig.Function;
const Family = trig.Family;
const testing = std.testing;

const prevDown = interval.prevDown;
const nextUp = interval.nextUp;

// ---------------------------------------------------------------------------
// Assertions
// ---------------------------------------------------------------------------

/// Rounding slack for a claim of the form "this answer must not leave this
/// range". It is seven orders of magnitude above any rounding the library
/// performs and seven below any mistake worth catching, so it can be
/// tripped by an answer that is wrong and not by one that is merely loose.
const slack: f64 = 1e-9;

/// The answer of a function which may have no image, with the two checks
/// every answer owes: that it answered at all, and that the interval it
/// handed back respects lo <= hi.
fn answer(x: ?Interval) !Interval {
    const i = x orelse return error.OutOfDomain;
    if (!(i.lo <= i.hi)) {
        std.debug.print("FAIL: answer [{e},{e}] is not an ordered interval\n", .{ i.lo, i.hi });
        return error.NotAnInterval;
    }
    return i;
}

/// Containment of one real number, named in the failure. The number must be
/// in the image of the argument, so an answer which leaves it out has
/// dropped part of the truth.
fn expectContains(what: []const u8, got: Interval, v: f64) !void {
    if (got.contains(v)) return;
    std.debug.print("FAIL {s}: [{e},{e}] does not contain {e}\n", .{ what, got.lo, got.hi, v });
    return error.NotAnEnclosure;
}

/// The answer reaches INTO a window built around an angle the test cannot
/// name exactly, which is what "the answer contains this angle" means when
/// the only handle on the angle is a witness interval.
///
/// The check is a non-empty intersection, not containment, and the reason
/// matters. The witnesses here are built outward from the certified bounds
/// on pi, so each is a couple of steps wider than the true angle on each
/// side. An answer that is the TIGHT bracket of the true angle -- which is
/// the best possible answer, and the one a certified outward projection
/// produces -- is then narrower than the witness, and demanding that it
/// cover the witness would be demanding that the library be sloppier than
/// the evidence requires. Asserting containment would test the oracle
/// rather than the mathematics.
///
/// An intersection is the strongest claim that survives an honest
/// improvement in width, and it loses almost nothing: the windows here are
/// a few steps wide, around 1e-16, so each of these assertions pins the
/// answer's POSITION to within about one ulp of the true angle. Anything
/// that got the sign, the period, the lattice index or the branch wrong is
/// many orders of magnitude away and cannot touch the window.
fn expectReaches(what: []const u8, got: Interval, w: Interval) !void {
    if (got.intersect(w) != null) return;
    std.debug.print("FAIL {s}: [{e},{e}] does not reach [{e},{e}]\n", .{ what, got.lo, got.hi, w.lo, w.hi });
    return error.NotReached;
}

/// The answer CONTAINS the whole of `want`. Use this only where both sides
/// are answers from the library or both are witnesses built by this file,
/// so that neither side is padded relative to a truth the other side is
/// being measured against. Where one side is an angle witness and the other
/// is an answer, `expectReaches` is the correct call.
fn expectEncloses(what: []const u8, got: Interval, want: Interval) !void {
    if (got.lo <= want.lo and want.hi <= got.hi) return;
    std.debug.print("FAIL {s}: [{e},{e}] does not enclose [{e},{e}]\n", .{ what, got.lo, got.hi, want.lo, want.hi });
    return error.NotAnEnclosure;
}

/// No real preimage exists, so there is nothing to enclose.
fn expectAbsent(what: []const u8, got: ?Interval) !void {
    if (got == null) return;
    const i = got.?;
    std.debug.print("FAIL {s}: [{e},{e}] answered where the image is empty\n", .{ what, i.lo, i.hi });
    return error.ShouldBeAbsent;
}

/// The answer stays inside a mathematical range, to within rounding. A lower
/// bound is not allowed above the range and an upper bound is not allowed
/// below it, which is the claim a sign error or a lost constraint makes.
fn expectWithin(what: []const u8, got: Interval, lo: f64, hi: f64) !void {
    if (got.lo >= lo - slack and got.hi <= hi + slack) return;
    std.debug.print("FAIL {s}: [{e},{e}] leaves [{e},{e}]\n", .{ what, got.lo, got.hi, lo, hi });
    return error.OutOfRange;
}

/// The answer lands inside a proved window. The window is an inequality
/// rather than an exact value -- `cosh(0.9) < 3/2 < cosh(1.1)` puts
/// `acosh(3/2)` inside `[0.9, 1.1]` -- and the true answer is ONE number
/// inside it, not the whole interval. So what is required is that the
/// enclosure reaches below the top of the window and above its bottom,
/// which is the only thing a sound answer can be asked for. Demanding that
/// it contain both ends of the window would be demanding that it contain
/// two numbers that are not solutions at all.
fn expectBetween(what: []const u8, got: Interval, lo: f64, hi: f64) !void {
    if (got.lo <= hi and got.hi >= lo) return;
    std.debug.print("FAIL {s}: [{e},{e}] does not reach into [{e},{e}]\n", .{ what, got.lo, got.hi, lo, hi });
    return error.OutsideWindow;
}

/// The answer reaches DOWN to the left end of the window and UP to the right
/// end, each to within the rounding slack. This is the assertion that says
/// "holds the whole window" in a form that a tight answer can satisfy.
///
/// It is here because the weaker checks do not imply it, and the gap is
/// worth naming since it is easy to assume away. Pairing "meets the window"
/// with "is at least as wide as the window" looks sufficient and is not: an
/// answer shifted towards one end, `[P.lo - d, P.hi - d]`, still meets the
/// window and is still exactly as wide as it, so both of those pass, and it
/// yet misses the right end of the level set by `d`. Meeting the window
/// bounds one end of the answer against the opposite end of the window, and
/// the width bounds the two ends against each other, but nothing bounds the
/// pair against the window as a whole. These two one-sided bounds do.
///
/// The side that could bite is the first one. `got.lo <= w.lo` asks the
/// answer's lower bound to reach DOWN to the window's, and that is the side
/// which only works because every witness here spends its extra padding
/// OUTWARD on both operands and on the sum: the window's lower end is then
/// below the true end, and a tight answer is above it, so the inequality is
/// satisfied with room to spare. The other side has the same shape. If a
/// witness were ever built with its ends taken INWARD, this is the side to
/// re-check first -- and it would fail loudly rather than pass quietly,
/// which is the behaviour wanted from a bound that has just been shown to
/// be carrying real weight.
fn expectSpans(what: []const u8, got: Interval, w: Interval) !void {
    if (got.lo <= w.lo + slack and got.hi >= w.hi - slack) return;
    std.debug.print("FAIL {s}: [{e},{e}] does not span [{e},{e}]\n", .{ what, got.lo, got.hi, w.lo, w.hi });
    return error.NotSpanned;
}

/// Some branch in `lo..=hi` whose answer reaches the window `w`. Pointwise:
/// one branch, not the hull of several, because a hull would let the test
/// pass on coverage that no single branch provides.
///
/// The window rather than a bare point is deliberate. The angle witnesses
/// here are a couple of outward steps wider than the true angle, so a bare
/// point taken off one of their ends is NOT the true angle and a tight
/// answer need not contain it. Intersecting with the witness window instead
/// asks the question that actually matters -- is there a branch whose
/// answer reaches this place -- and it keeps asking it when the library
/// tightens.
fn branchReaching(fam: Family, lo: i64, hi: i64, w: Interval, what: []const u8) !Interval {
    var k = lo;
    while (k <= hi) : (k += 1) {
        const b = fam.at(k) orelse continue;
        if (b.intersect(w) != null) return b;
    }
    std.debug.print("FAIL {s}: no branch in [{d},{d}] reaches [{e},{e}]\n", .{ what, lo, hi, w.lo, w.hi });
    return error.BranchMissing;
}

/// Some branch in `lo..=hi` whose answer holds all of `a` and all of `b`
/// at once, the widest such answer. This is the check that a whole level
/// set which is an interval lands inside ONE branch: an answer carrying
/// only one end of it leaves the interior unreachable.
fn branchHolding(fam: Family, lo: i64, hi: i64, a: Interval, b: Interval, what: []const u8) !Interval {
    var k = lo;
    var best: ?Interval = null;
    while (k <= hi) : (k += 1) {
        const c = fam.at(k) orelse continue;
        if (c.intersect(a) == null) continue;
        if (c.intersect(b) == null) continue;
        if (best == null or c.hi - c.lo > best.?.hi - best.?.lo) best = c;
    }
    const r = best orelse {
        std.debug.print("FAIL {s}: no branch in [{d},{d}] holds both [{e},{e}] and [{e},{e}]\n", .{ what, lo, hi, a.lo, a.hi, b.lo, b.hi });
        return error.IntervalNotHeld;
    };
    return r;
}

// ---------------------------------------------------------------------------
// Witness angles, built outward from the certified bounds on pi
// ---------------------------------------------------------------------------

/// A witness interval for `k * pi`, rounded outward in the direction that
/// survives a negative multiplier: for `k < 0` the LOWER bound of k*pi
/// comes from the upper bound of pi, because multiplying an inequality by a
/// negative number turns it around.
fn mulPi(k: i64) Interval {
    if (k == 0) return Interval.init(0.0, 0.0);
    const kf: f64 = @floatFromInt(k);
    if (k > 0) return Interval.init(prevDown(kf * interval.piDown()), nextUp(kf * interval.piUp()));
    return Interval.init(prevDown(kf * interval.piUp()), nextUp(kf * interval.piDown()));
}

/// A witness interval for `k * pi / d`. Dividing by anything but a power of
/// two rounds, so a step outward is taken on each side afterwards.
fn mulPiOver(k: i64, d: i64) Interval {
    if (k == 0 and d == 1) return Interval.init(0.0, 0.0);
    const b = mulPi(k);
    const df: f64 = @floatFromInt(d);
    return Interval.init(prevDown(b.lo / df), nextUp(b.hi / df));
}

/// A witness interval for `k * pi / d - e`, for the inverse witnesses where
/// a principal value is a difference rather than a multiple of pi. `e` must
/// itself be exact in binary; every use below is 0, 1/2 or 0.1.
fn angle(k: i64, d: i64, e: f64) Interval {
    const w = mulPiOver(k, d);
    if (e == 0.0) return w;
    return Interval.init(prevDown(w.lo - e), nextUp(w.hi - e));
}

/// The witness for a sum of two witness intervals, outward so the real sum
/// stays inside.
fn addWitness(a: Interval, b: Interval) Interval {
    return Interval.init(prevDown(a.lo + b.lo), nextUp(a.hi + b.hi));
}

/// A witness interval widened by `m` on both sides, for the arguments that
/// have to straddle a pole.
fn widen(x: Interval, m: f64) Interval {
    return Interval.init(prevDown(x.lo - m), nextUp(x.hi + m));
}
fn ptZero() Interval {
    return Interval.init(0.0, 0.0);
}

fn ptQuarterPi() Interval {
    return mulPiOver(1, 4);
}

fn ptHalfPi() Interval {
    return mulPiOver(1, 2);
}

fn ptThreeQuarterPi() Interval {
    return mulPiOver(3, 4);
}

fn ptPi() Interval {
    return mulPiOver(1, 1);
}

fn ptThirdPi() Interval {
    return mulPiOver(1, 3);
}

fn ptSixthPi() Interval {
    return mulPiOver(1, 6);
}

/// A degenerate argument: the library is asked about one real number.
fn pt(v: f64) Interval {
    return Interval.init(v, v);
}

// ---------------------------------------------------------------------------
// The exact forward table
// ---------------------------------------------------------------------------

/// An angle the test can write down. `.unit` is an f64 exact in binary,
/// used for the hyperbolic geometry where 1 is the witness of choice.
const Arg = union(enum) {
    zero,
    pi_over: struct { k: i64, d: i64 },
    unit: f64,

    fn piOver(k: i64, d: i64) Arg {
        return .{ .pi_over = .{ .k = k, .d = d } };
    }

    fn at(v: f64) Arg {
        return .{ .unit = v };
    }
};

/// What the truth is at one witness angle.
const Want = union(enum) {
    /// A rational number exact in binary, and the only image there.
    value: f64,
    /// No image at all: the argument is a pole of a reciprocal function, or
    /// a zero that is being turned upside down.
    absent,
    /// A transcendental number. The test asks only that the answer be an
    /// ordered enclosure and that the inverse give the angle back; the
    /// value itself is never compared to anything.
    transcendental,
};

fn witnessArg(a: Arg) Interval {
    return switch (a) {
        .zero => ptZero(),
        .pi_over => |p| mulPiOver(p.k, p.d),
        .unit => |u| Interval.init(u, u),
    };
}

fn argLabel(comptime a: Arg) []const u8 {
    return switch (a) {
        .zero => "0",
        .pi_over => |p| std.fmt.comptimePrint("{d}pi/{d}", .{ p.k, p.d }),
        .unit => |u| std.fmt.comptimePrint("{d}", .{u}),
    };
}

const Row = struct {
    g: Geometry,
    f: Function,
    arg: Arg,
    want: Want,
    name: []const u8,
};

fn row(comptime g: Geometry, comptime f: Function, comptime a: Arg, w: Want) Row {
    return .{
        .g = g,
        .f = f,
        .arg = a,
        .want = w,
        .name = std.fmt.comptimePrint("{s} {s} at {s}", .{ @tagName(g), @tagName(f), argLabel(a) }),
    };
}

// The witness angles. `.zero` is kept separate from `.pi_over = {0,1}` so
// that the angle is asked about as the exact point zero rather than as a
// hair either side of it.
//
// Every row below is arithmetic on the convention of the row's geometry:
//   circle   sin cos tan are sin cos tan; csc sec cot are 1/sin, 1/cos,
//            cos/sin.
//   hyperbola  the same six with sinh cosh tanh, so csc is 1/sinh, sec is
//            1/cosh and cot is cosh/sinh.
//   diamond  coordinates (c, s) / (|c| + |s|), ratios still circular.
//   square   coordinates (c, s) / max(|c|, |s|), ratios still circular.
//
// The circle's own table is complete at pi/3 only where the truth is
// rational; sqrt(3)/2 is not rational and its row says so rather than
// quoting a decimal. The hyperbolic geometry is transcendental everywhere
// except at zero, which is exactly what the table shows.
const forward_table = [_]Row{
    // circle, at zero: sin 0, cos 1, tan 0, csc and cot undefined, sec 1.
    row(.circle, .sin, .zero, .{ .value = 0.0 }),
    row(.circle, .cos, .zero, .{ .value = 1.0 }),
    row(.circle, .tan, .zero, .{ .value = 0.0 }),
    row(.circle, .csc, .zero, .absent),
    row(.circle, .sec, .zero, .{ .value = 1.0 }),
    row(.circle, .cot, .zero, .absent),

    // circle, at pi/3: cos is 1/2 and sec is 2, both exact. The rest of
    // the row is sqrt(3) and its reciprocal.
    row(.circle, .sin, Arg.piOver(1, 3), .transcendental),
    row(.circle, .cos, Arg.piOver(1, 3), .{ .value = 0.5 }),
    row(.circle, .tan, Arg.piOver(1, 3), .transcendental),
    row(.circle, .csc, Arg.piOver(1, 3), .transcendental),
    row(.circle, .sec, Arg.piOver(1, 3), .{ .value = 2.0 }),
    row(.circle, .cot, Arg.piOver(1, 3), .transcendental),

    // circle, at pi/2: sin 1, cos 0, tan and sec undefined, csc 1, cot 0.
    row(.circle, .sin, Arg.piOver(1, 2), .{ .value = 1.0 }),
    row(.circle, .cos, Arg.piOver(1, 2), .{ .value = 0.0 }),
    // The witness around pi/2 is a hair wide rather than the point pi/2,
    // because no f64 is exactly pi/2. The tangent and the secant therefore
    // do not have an empty image there: they have a pole inside the
    // interval and the image runs to both infinities. Asserting absence
    // here would be asserting that a pole is a hole in the reals, which is
    // the opposite of what it is. The pole behaviour itself is in the
    // tests below that straddle pi/2 by a width of a millionth.
    row(.circle, .tan, Arg.piOver(1, 2), .transcendental),
    row(.circle, .csc, Arg.piOver(1, 2), .{ .value = 1.0 }),
    row(.circle, .sec, Arg.piOver(1, 2), .transcendental),
    row(.circle, .cot, Arg.piOver(1, 2), .{ .value = 0.0 }),

    // circle, at pi: sin 0, cos -1, tan 0, sec -1.
    row(.circle, .sin, Arg.piOver(1, 1), .{ .value = 0.0 }),
    row(.circle, .cos, Arg.piOver(1, 1), .{ .value = -1.0 }),
    row(.circle, .tan, Arg.piOver(1, 1), .{ .value = 0.0 }),
    row(.circle, .sec, Arg.piOver(1, 1), .{ .value = -1.0 }),

    // circle, at pi/4 the tangent and the cotangent are both exactly one,
    // and at 2pi the whole set repeats.
    row(.circle, .tan, Arg.piOver(1, 4), .{ .value = 1.0 }),
    row(.circle, .cot, Arg.piOver(1, 4), .{ .value = 1.0 }),
    row(.circle, .sin, Arg.piOver(2, 1), .{ .value = 0.0 }),
    row(.circle, .cos, Arg.piOver(2, 1), .{ .value = 1.0 }),
    row(.circle, .tan, Arg.piOver(2, 1), .{ .value = 0.0 }),
    row(.circle, .sec, Arg.piOver(2, 1), .{ .value = 1.0 }),
    row(.circle, .tan, Arg.piOver(5, 4), .{ .value = 1.0 }),
    row(.circle, .cot, Arg.piOver(5, 4), .{ .value = 1.0 }),

    // circle, at pi/6 sin is 1/2 and csc is 2; at 3pi/2 sin is -1 and csc
    // is -1.
    row(.circle, .sin, Arg.piOver(1, 6), .{ .value = 0.5 }),
    row(.circle, .csc, Arg.piOver(1, 6), .{ .value = 2.0 }),
    row(.circle, .sin, Arg.piOver(3, 2), .{ .value = -1.0 }),
    row(.circle, .cos, Arg.piOver(3, 2), .{ .value = 0.0 }),
    row(.circle, .csc, Arg.piOver(3, 2), .{ .value = -1.0 }),
    row(.circle, .cot, Arg.piOver(3, 2), .{ .value = 0.0 }),

    // circle, at -pi/6 sin is -1/2 and csc is -2, which is the one exact
    // witness that needs a negative multiplier of pi.
    row(.circle, .sin, Arg.piOver(-1, 6), .{ .value = -0.5 }),
    row(.circle, .csc, Arg.piOver(-1, 6), .{ .value = -2.0 }),

    // hyperbola, at zero: sinh 0, cosh 1, tanh 0, sech 1, csch and coth
    // undefined. At one every value is transcendental and the table says
    // so rather than quoting decimals.
    row(.hyperbola, .sin, .zero, .{ .value = 0.0 }),
    row(.hyperbola, .cos, .zero, .{ .value = 1.0 }),
    row(.hyperbola, .tan, .zero, .{ .value = 0.0 }),
    row(.hyperbola, .csc, .zero, .absent),
    row(.hyperbola, .sec, .zero, .{ .value = 1.0 }),
    row(.hyperbola, .cot, .zero, .absent),
    row(.hyperbola, .sin, Arg.at(1.0), .transcendental),
    row(.hyperbola, .cos, Arg.at(1.0), .transcendental),
    row(.hyperbola, .tan, Arg.at(1.0), .transcendental),
    row(.hyperbola, .csc, Arg.at(1.0), .transcendental),
    row(.hyperbola, .sec, Arg.at(1.0), .transcendental),
    row(.hyperbola, .cot, Arg.at(1.0), .transcendental),

    // diamond, at zero.
    row(.diamond, .sin, .zero, .{ .value = 0.0 }),
    row(.diamond, .cos, .zero, .{ .value = 1.0 }),
    row(.diamond, .tan, .zero, .{ .value = 0.0 }),
    row(.diamond, .csc, .zero, .absent),
    row(.diamond, .sec, .zero, .{ .value = 1.0 }),
    row(.diamond, .cot, .zero, .absent),

    // diamond, at pi/4: |c| = |s| = sqrt(2)/2, so both coordinates are
    // exactly 1/2, both reciprocals exactly 2, and the ratios exactly 1.
    // All six are rational here.
    row(.diamond, .sin, Arg.piOver(1, 4), .{ .value = 0.5 }),
    row(.diamond, .cos, Arg.piOver(1, 4), .{ .value = 0.5 }),
    row(.diamond, .tan, Arg.piOver(1, 4), .{ .value = 1.0 }),
    row(.diamond, .csc, Arg.piOver(1, 4), .{ .value = 2.0 }),
    row(.diamond, .sec, Arg.piOver(1, 4), .{ .value = 2.0 }),
    row(.diamond, .cot, Arg.piOver(1, 4), .{ .value = 1.0 }),

    // diamond, at 3pi/4 the two coordinates are +1/2 and -1/2, so the
    // reciprocals are 2 and -2 and the ratios are -1.
    row(.diamond, .sin, Arg.piOver(3, 4), .{ .value = 0.5 }),
    row(.diamond, .cos, Arg.piOver(3, 4), .{ .value = -0.5 }),
    row(.diamond, .tan, Arg.piOver(3, 4), .{ .value = -1.0 }),
    row(.diamond, .csc, Arg.piOver(3, 4), .{ .value = 2.0 }),
    row(.diamond, .sec, Arg.piOver(3, 4), .{ .value = -2.0 }),
    row(.diamond, .cot, Arg.piOver(3, 4), .{ .value = -1.0 }),

    // diamond, at -pi/4 the same magnitudes with the signs of the second
    // coordinate flipped.
    row(.diamond, .sin, Arg.piOver(-1, 4), .{ .value = -0.5 }),
    row(.diamond, .cos, Arg.piOver(-1, 4), .{ .value = 0.5 }),
    row(.diamond, .tan, Arg.piOver(-1, 4), .{ .value = -1.0 }),
    row(.diamond, .csc, Arg.piOver(-1, 4), .{ .value = -2.0 }),
    row(.diamond, .sec, Arg.piOver(-1, 4), .{ .value = 2.0 }),
    row(.diamond, .cot, Arg.piOver(-1, 4), .{ .value = -1.0 }),

    // diamond, at pi/2 one coordinate is 1 and the other 0, so the
    // reciprocals of the 0 are undefined and the reciprocal of the 1 is 1.
    row(.diamond, .sin, Arg.piOver(1, 2), .{ .value = 1.0 }),
    row(.diamond, .cos, Arg.piOver(1, 2), .{ .value = 0.0 }),
    row(.diamond, .tan, Arg.piOver(1, 2), .transcendental),
    row(.diamond, .csc, Arg.piOver(1, 2), .{ .value = 1.0 }),
    row(.diamond, .sec, Arg.piOver(1, 2), .transcendental),
    row(.diamond, .cot, Arg.piOver(1, 2), .{ .value = 0.0 }),
    row(.diamond, .sin, Arg.piOver(-1, 2), .{ .value = -1.0 }),
    row(.diamond, .cos, Arg.piOver(-1, 2), .{ .value = 0.0 }),
    row(.diamond, .csc, Arg.piOver(-1, 2), .{ .value = -1.0 }),
    row(.diamond, .cot, Arg.piOver(-1, 2), .{ .value = 0.0 }),

    // diamond, at pi: sin 0, cos -1, tan 0, sec -1.
    row(.diamond, .sin, Arg.piOver(1, 1), .{ .value = 0.0 }),
    row(.diamond, .cos, Arg.piOver(1, 1), .{ .value = -1.0 }),
    row(.diamond, .tan, Arg.piOver(1, 1), .{ .value = 0.0 }),
    row(.diamond, .sec, Arg.piOver(1, 1), .{ .value = -1.0 }),

    // diamond, at pi/3 nothing is rational.
    row(.diamond, .sin, Arg.piOver(1, 3), .transcendental),
    row(.diamond, .cos, Arg.piOver(1, 3), .transcendental),
    row(.diamond, .tan, Arg.piOver(1, 3), .transcendental),
    row(.diamond, .csc, Arg.piOver(1, 3), .transcendental),
    row(.diamond, .sec, Arg.piOver(1, 3), .transcendental),
    row(.diamond, .cot, Arg.piOver(1, 3), .transcendental),

    // square, at zero.
    row(.square, .sin, .zero, .{ .value = 0.0 }),
    row(.square, .cos, .zero, .{ .value = 1.0 }),
    row(.square, .tan, .zero, .{ .value = 0.0 }),
    row(.square, .csc, .zero, .absent),
    row(.square, .sec, .zero, .{ .value = 1.0 }),
    row(.square, .cot, .zero, .absent),

    // square, at pi/6 the horizontal coordinate is the larger in
    // magnitude, so it is the one being divided out and it is exactly 1.
    row(.square, .cos, Arg.piOver(1, 6), .{ .value = 1.0 }),
    row(.square, .sec, Arg.piOver(1, 6), .{ .value = 1.0 }),
    row(.square, .sin, Arg.piOver(1, 6), .transcendental),
    row(.square, .tan, Arg.piOver(1, 6), .transcendental),
    row(.square, .csc, Arg.piOver(1, 6), .transcendental),
    row(.square, .cot, Arg.piOver(1, 6), .transcendental),

    // square, at pi/4 the two coordinates are equal in magnitude, so both
    // are exactly 1 and every reciprocal and ratio is exactly 1.
    row(.square, .sin, Arg.piOver(1, 4), .{ .value = 1.0 }),
    row(.square, .cos, Arg.piOver(1, 4), .{ .value = 1.0 }),
    row(.square, .tan, Arg.piOver(1, 4), .{ .value = 1.0 }),
    row(.square, .csc, Arg.piOver(1, 4), .{ .value = 1.0 }),
    row(.square, .sec, Arg.piOver(1, 4), .{ .value = 1.0 }),
    row(.square, .cot, Arg.piOver(1, 4), .{ .value = 1.0 }),

    // square, at 3pi/4 the second coordinate is the larger in magnitude
    // and positive, so it divides itself out to 1 and the first is -1.
    row(.square, .sin, Arg.piOver(3, 4), .{ .value = 1.0 }),
    row(.square, .cos, Arg.piOver(3, 4), .{ .value = -1.0 }),
    row(.square, .tan, Arg.piOver(3, 4), .{ .value = -1.0 }),
    row(.square, .csc, Arg.piOver(3, 4), .{ .value = 1.0 }),
    row(.square, .sec, Arg.piOver(3, 4), .{ .value = -1.0 }),
    row(.square, .cot, Arg.piOver(3, 4), .{ .value = -1.0 }),

    // square, at 5pi/4 both coordinates are negative and equal in
    // magnitude, so both divide themselves out to -1.
    row(.square, .sin, Arg.piOver(5, 4), .{ .value = -1.0 }),
    row(.square, .cos, Arg.piOver(5, 4), .{ .value = -1.0 }),
    row(.square, .tan, Arg.piOver(5, 4), .{ .value = 1.0 }),
    row(.square, .csc, Arg.piOver(5, 4), .{ .value = -1.0 }),
    row(.square, .sec, Arg.piOver(5, 4), .{ .value = -1.0 }),
    row(.square, .cot, Arg.piOver(5, 4), .{ .value = 1.0 }),

    // square, at -pi/4 the same with the second coordinate flipped.
    row(.square, .sin, Arg.piOver(-1, 4), .{ .value = -1.0 }),
    row(.square, .cos, Arg.piOver(-1, 4), .{ .value = 1.0 }),
    row(.square, .tan, Arg.piOver(-1, 4), .{ .value = -1.0 }),
    row(.square, .csc, Arg.piOver(-1, 4), .{ .value = -1.0 }),
    row(.square, .sec, Arg.piOver(-1, 4), .{ .value = 1.0 }),
    row(.square, .cot, Arg.piOver(-1, 4), .{ .value = -1.0 }),

    // square, at pi/2 and 3pi/2 the second coordinate divides itself out.
    row(.square, .sin, Arg.piOver(1, 2), .{ .value = 1.0 }),
    row(.square, .cos, Arg.piOver(1, 2), .{ .value = 0.0 }),
    row(.square, .tan, Arg.piOver(1, 2), .transcendental),
    row(.square, .csc, Arg.piOver(1, 2), .{ .value = 1.0 }),
    row(.square, .sec, Arg.piOver(1, 2), .transcendental),
    row(.square, .cot, Arg.piOver(1, 2), .{ .value = 0.0 }),
    row(.square, .sin, Arg.piOver(3, 2), .{ .value = -1.0 }),
    row(.square, .cos, Arg.piOver(3, 2), .{ .value = 0.0 }),
    row(.square, .csc, Arg.piOver(3, 2), .{ .value = -1.0 }),
    row(.square, .cot, Arg.piOver(3, 2), .{ .value = 0.0 }),
};

test "forward: the exact rational witnesses, all twenty-four surfaces" {
    inline for (forward_table) |r| {
        const got = trig.forward(r.g, r.f, witnessArg(r.arg));
        switch (r.want) {
            .value => |v| try expectContains(r.name, try answer(got), v),
            .absent => try expectAbsent(r.name, got),
            .transcendental => _ = try answer(got),
        }
    }
}

test "forward: every row of the table is also reached by the full inverse family" {
    // The exact table is the coverage claim for the forward surface, and a
    // row that only checked a containment could still pass with a value
    // that nothing inverts to. So every row is also run through the FULL
    // inverse family, which is complete for every angle rather than only
    // for the ones inside a principal branch.
    //
    // The principal inverse would have been the wrong thing to use here, and
    // not merely a weaker one. The arcsine returns a quarter turn, the
    // arccosine a half turn, and the arccotangent the half turn from zero to
    // pi, so a row at pi, at two pi or at three halves of pi has no way of
    // coming back through them at all: the answer would have to leave the
    // range the function is defined on. Asking for it would be asking for
    // something no correct implementation can produce. The principal-inverse
    // round trip is checked on all twenty-four surfaces separately, at an
    // angle chosen for each, where it is true.
    inline for (forward_table) |r| {
        if (r.want == .absent) continue;
        const arg = witnessArg(r.arg);
        const y = try answer(trig.forward(r.g, r.f, arg));
        const fam = trig.inverseFamily(r.g, r.f, y);
        // The window is wide enough for every angle the table names, the
        // largest of which is two turns, so which branch carries it is not
        // being assumed here either.
        _ = try branchReaching(fam, -14, 14, arg, r.name);
    }
}

// ---------------------------------------------------------------------------
// The universal sweep: every geometry, every function, all three surfaces
// ---------------------------------------------------------------------------

const all_functions = [_]Function{ .sin, .cos, .tan, .csc, .sec, .cot };

/// One witness angle per geometry AND function, clear of every pole and
/// inside the range where that function's principal inverse is the
/// identity. The circle, the diamond and the hyperbolic geometry need one
/// angle each. The square needs three, and the reason is the flat top: its
/// vertical coordinate only rises over `[-pi/4, pi/4]` and its horizontal
/// one only falls over `[pi/2, 3pi/4]`, so no single angle inverts back
/// through both of them. Taking the octant of the vertical coordinate for
/// the sine and the cosecant, the quadrant of the horizontal one for the
/// cosine and the secant, and pi/3 for the two ratios puts every angle
/// where its own principal inverse is the branch that returns it.
fn sweepAngle(g: Geometry, f: Function) Interval {
    return switch (g) {
        .circle, .diamond => mulPiOver(1, 3),
        .hyperbola => Interval.init(1.0, 1.0),
        .square => switch (f) {
            .sin, .csc => mulPiOver(1, 6),
            .cos, .sec => mulPiOver(2, 3),
            .tan, .cot => mulPiOver(1, 3),
        },
    };
}

test "every surface: forward answers, principal inverse gives the angle back" {
    // The round trip. `arg` is a witness a couple of steps wider than the
    // true angle, so the claim is that the answer reaches into it and not
    // that it encloses it: the tight bracket of an angle is narrower than
    // the outward steps the witness took, and requiring the wider of the
    // two would be requiring the library to be sloppier than it can be.
    // Since the witness is around 1e-16 wide, this still pins the answer's
    // position to within about an ulp of the true angle on all twenty-four
    // surfaces at once.
    inline for (.{ Geometry.circle, .hyperbola, .diamond, .square }) |g| {
        inline for (all_functions) |f| {
            const name = std.fmt.comptimePrint("{s} {s}", .{ @tagName(g), @tagName(f) });
            const arg = sweepAngle(g, f);
            const y = try answer(trig.forward(g, f, arg));
            const back = try answer(trig.principalInverse(g, f, y));
            try expectReaches(name, back, arg);
        }
    }
}

test "every surface: the family reaches the angle it was built from" {
    inline for (.{ Geometry.circle, .hyperbola, .diamond, .square }) |g| {
        inline for (all_functions) |f| {
            const name = std.fmt.comptimePrint("{s} {s}", .{ @tagName(g), @tagName(f) });
            const arg = sweepAngle(g, f);
            const y = try answer(trig.forward(g, f, arg));
            const fam = trig.inverseFamily(g, f, y);
            if (fam.branchCount() == 0) {
                std.debug.print("FAIL {s}: the family of a value that was just produced has no branch\n", .{name});
                return error.EmptyFamily;
            }
            // Some branch has to contain the angle the value came from,
            // and evaluating the forward function over that branch has to
            // give the value back. Two answers, one of which is a wrong
            // branch, cannot both pass.
            const k = try branchReaching(fam, -2, 2, arg, name);
            const again = try answer(trig.forward(g, f, k));
            try expectEncloses(name, again, y);
        }
    }
}

test "every surface: a wider argument hulls the branches of a narrower one" {
    // The level set of a wider argument contains the level set of a
    // narrower one branch by branch, because the wider argument contains
    // the narrower one. This is monotonicity of the whole family, not of
    // one function. The halves are used rather than something invented,
    // so that the narrower arguments are inside the domain of the wider
    // ones by construction and no part of the test can fail for being off
    // the end of a range instead of for being wrong.
    inline for (.{ Geometry.circle, .hyperbola, .diamond, .square }) |g| {
        inline for (all_functions) |f| {
            const name = std.fmt.comptimePrint("{s} {s}", .{ @tagName(g), @tagName(f) });
            const arg = sweepAngle(g, f);
            const y = try answer(trig.forward(g, f, arg));
            const mid = y.midpoint();
            const wide = trig.inverseFamily(g, f, y);
            for ([_]Interval{ Interval.init(y.lo, mid), Interval.init(mid, y.hi) }) |half| {
                const narrow = trig.inverseFamily(g, f, half);
                var k: i64 = -2;
                while (k <= 2) : (k += 1) {
                    const a = narrow.at(k) orelse continue;
                    const b = try answer(wide.at(k));
                    try expectEncloses(name, b, a);
                }
            }
        }
    }
}


// ---------------------------------------------------------------------------
// Quadrants and critical extrema, forward
// ---------------------------------------------------------------------------

test "circle sin: the third quadrant stays under zero and still finds its minimum" {
    // On [pi, 2pi] the sine runs 0, -1, 0. Both zeros are attained and the
    // minimum is in the middle, so an answer that only looked at the ends
    // would miss the -1.
    const arg = Interval.init(ptPi().lo, mulPi(2).hi);
    const r = try answer(trig.forward(.circle, .sin, arg));
    try expectWithin("sin on [pi,2pi]", r, -1.0, 0.0);
    try expectContains("minimum at 3pi/2", r, -1.0);
    try expectContains("zero at pi", r, 0.0);
    try expectContains("zero at 2pi", r, 0.0);
}

test "circle cos: the second quadrant stays under zero and finds its minimum" {
    // On [pi/2, 3pi/2] the cosine runs 0, -1, 0 with the minimum inside.
    const arg = Interval.init(ptHalfPi().lo, mulPiOver(3, 2).hi);
    const r = try answer(trig.forward(.circle, .cos, arg));
    try expectWithin("cos on [pi/2,3pi/2]", r, -1.0, 0.0);
    try expectContains("minimum at pi", r, -1.0);
    try expectContains("zero at pi/2", r, 0.0);
}

test "circle sin: the first quadrant reaches exactly one" {
    const arg = Interval.init(0.0, ptHalfPi().hi);
    const r = try answer(trig.forward(.circle, .sin, arg));
    try expectWithin("sin on [0,pi/2]", r, 0.0, 1.0);
    try expectContains("maximum at pi/2", r, 1.0);
    try expectContains("zero at 0", r, 0.0);
}

test "circle cos: over a whole period both ends of the range are reached" {
    const arg = Interval.init(ptZero().lo, mulPi(2).hi);
    const r = try answer(trig.forward(.circle, .cos, arg));
    try expectWithin("cos on [0,2pi]", r, -1.0, 1.0);
    try expectContains("maximum at 0", r, 1.0);
    try expectContains("minimum at pi", r, -1.0);
}

test "diamond sin and cos: the quadrants keep their signs" {
    // Dividing by |c| + |s| is positive everywhere, so the sign of each
    // coordinate is the sign of the circular one it came from.
    const third = try answer(trig.forward(.diamond, .sin, Interval.init(ptPi().lo, mulPi(2).hi)));
    try expectWithin("diamond sin on [pi,2pi]", third, -1.0, 0.0);
    try expectContains("diamond sin minimum at 3pi/2", third, -1.0);

    const second = try answer(trig.forward(.diamond, .cos, Interval.init(ptHalfPi().lo, mulPiOver(3, 2).hi)));
    try expectWithin("diamond cos on [pi/2,3pi/2]", second, -1.0, 0.0);
    try expectContains("diamond cos minimum at pi", second, -1.0);

    const first = try answer(trig.forward(.diamond, .sin, Interval.init(0.0, ptHalfPi().hi)));
    try expectWithin("diamond sin on [0,pi/2]", first, 0.0, 1.0);
    try expectContains("diamond sin maximum at pi/2", first, 1.0);
}

test "square sin and cos: the quadrants keep their signs" {
    const third = try answer(trig.forward(.square, .sin, Interval.init(ptPi().lo, mulPi(2).hi)));
    try expectWithin("square sin on [pi,2pi]", third, -1.0, 0.0);
    try expectContains("square sin minimum at 3pi/2", third, -1.0);

    const second = try answer(trig.forward(.square, .cos, Interval.init(ptHalfPi().lo, mulPiOver(3, 2).hi)));
    try expectWithin("square cos on [pi/2,3pi/2]", second, -1.0, 0.0);
    try expectContains("square cos minimum at pi", second, -1.0);
}

test "diamond and square: the endpoints of a monotone segment are both reached" {
    // On each octant both polygon coordinates are monotone, so the ends of
    // the segment are attained and both have to come back. This is what a
    // forward answer built from the segment ends alone would satisfy, and
    // what one that also has to find the corner in the middle must still
    // satisfy.
    const d0 = Interval.init(0.0, ptQuarterPi().hi);
    const ds = try answer(trig.forward(.diamond, .sin, d0));
    try expectContains("diamond sin at 0", ds, 0.0);
    try expectContains("diamond sin at pi/4", ds, 0.5);
    const dc = try answer(trig.forward(.diamond, .cos, d0));
    try expectContains("diamond cos at 0", dc, 1.0);
    try expectContains("diamond cos at pi/4", dc, 0.5);

    const s0 = Interval.init(0.0, ptQuarterPi().hi);
    const ss = try answer(trig.forward(.square, .sin, s0));
    try expectContains("square sin at 0", ss, 0.0);
    try expectContains("square sin at pi/4", ss, 1.0);
    const sc = try answer(trig.forward(.square, .cos, s0));
    try expectContains("square cos at 0", sc, 1.0);
    try expectContains("square cos at pi/4", sc, 1.0);
}

test "square sin: the segment across the flat top is all of it" {
    // Between pi/4 and 3pi/4 the vertical coordinate of the square is the
    // larger in magnitude and positive, so it divides itself out and the
    // whole segment is the single value one.
    const flat = Interval.init(ptQuarterPi().lo, ptThreeQuarterPi().hi);
    const r = try answer(trig.forward(.square, .sin, flat));
    try expectWithin("square sin on [pi/4,3pi/4]", r, 1.0, 1.0);
    try expectContains("the flat top", r, 1.0);
}

// ---------------------------------------------------------------------------
// Normalization: what the two polygons divide by
// ---------------------------------------------------------------------------

test "diamond: the two coordinates add up to one in magnitude" {
    // (|c| + |s|) / (|c| + |s|) is one. In the first quadrant both
    // coordinates are positive, so their sum is exactly one, and an answer
    // pair whose sum missed one would have lost the normalization.
    inline for (.{ Arg.piOver(1, 6), Arg.piOver(1, 4), Arg.piOver(1, 3), Arg.piOver(1, 2) }) |a| {
        const arg = witnessArg(a);
        const s = try answer(trig.forward(.diamond, .sin, arg));
        const c = try answer(trig.forward(.diamond, .cos, arg));
        try expectWithin("diamond sin", s, 0.0, 1.0);
        try expectWithin("diamond cos", c, 0.0, 1.0);
        if (!(s.lo + c.lo <= 1.0 and 1.0 <= s.hi + c.hi)) {
            std.debug.print("FAIL diamond at {s}: sin [{e},{e}] plus cos [{e},{e}] does not add up to 1\n", .{ argLabel(a), s.lo, s.hi, c.lo, c.hi });
            return error.NotNormalized;
        }
    }
}

test "square: one of the two coordinates is exactly one at every angle" {
    // max(|c|, |s|) / max(|c|, |s|) is one, and it is always one of the two
    // coordinates that divides itself out. So at every angle at least one
    // of them is the value one exactly, which is a statement about the
    // normalization that no rounding of the division can lose.
    inline for (.{ Arg.piOver(1, 6), Arg.piOver(1, 4), Arg.piOver(1, 3), Arg.piOver(1, 2), Arg.piOver(2, 1) }) |a| {
        const arg = witnessArg(a);
        const s = try answer(trig.forward(.square, .sin, arg));
        const c = try answer(trig.forward(.square, .cos, arg));
        try expectWithin("square sin", s, -1.0, 1.0);
        try expectWithin("square cos", c, -1.0, 1.0);
        if (!s.contains(1.0) and !c.contains(1.0)) {
            std.debug.print("FAIL square at {s}: neither coordinate is one; sin [{e},{e}], cos [{e},{e}]\n", .{ argLabel(a), s.lo, s.hi, c.lo, c.hi });
            return error.NotNormalized;
        }
    }
}

test "diamond and square: the ratios are the circular ones" {
    // The division is out of both coordinates or out of one of them, so it
    // cancels in the ratio and the tangent and the cotangent stay circular
    // in all four geometries. The witness is the angle pi/4, where both are
    // exactly one.
    inline for (.{ Geometry.circle, .hyperbola, .diamond, .square }) |g| {
        inline for (all_functions) |f| {
            // Only the ratio functions have a circular witness here.
            if (f != .tan and f != .cot) continue;
            if (g == .hyperbola) continue;
            const arg = mulPiOver(1, 4);
            const name = std.fmt.comptimePrint("{s} {s} at pi/4", .{ @tagName(g), @tagName(f) });
            const r = try answer(trig.forward(g, f, arg));
            try expectContains(name, r, 1.0);
        }
    }
}

// ---------------------------------------------------------------------------
// Poles and empty images, forward
// ---------------------------------------------------------------------------

test "tan: a box straddling the pole is unbounded both ways" {
    // 1e-6 from pi/2 the tangent is cot(1e-6), and cot(1e-6) > 0.99/1e-6
    // because cos(1e-6) > 0.99 and sin(1e-6) < 1e-6. So the image of the
    // box holds numbers above a hundred thousand and below a hundred
    // thousand in magnitude, and any answer that does not is not an
    // enclosure.
    const arg = widen(ptHalfPi(), 1e-6);
    const r = try answer(trig.forward(.circle, .tan, arg));
    if (!(r.lo <= -1e5 and r.hi >= 1e5)) {
        std.debug.print("FAIL tan across the pole: [{e},{e}] does not reach both ways\n", .{ r.lo, r.hi });
        return error.PoleMissed;
    }
}

test "sec and cot: a box straddling a pole is unbounded both ways" {
    const at_half = widen(ptHalfPi(), 1e-6);
    const sec = try answer(trig.forward(.circle, .sec, at_half));
    if (!(sec.lo <= -1e5 and sec.hi >= 1e5)) {
        std.debug.print("FAIL sec across the pole: [{e},{e}]\n", .{ sec.lo, sec.hi });
        return error.PoleMissed;
    }
    const at_pi = widen(ptPi(), 1e-6);
    const cot = try answer(trig.forward(.circle, .cot, at_pi));
    if (!(cot.lo <= -1e5 and cot.hi >= 1e5)) {
        std.debug.print("FAIL cot across the pole: [{e},{e}]\n", .{ cot.lo, cot.hi });
        return error.PoleMissed;
    }
    const csc = try answer(trig.forward(.circle, .csc, at_pi));
    if (!(csc.lo <= -1e5 and csc.hi >= 1e5)) {
        std.debug.print("FAIL csc across the pole: [{e},{e}]\n", .{ csc.lo, csc.hi });
        return error.PoleMissed;
    }
}

test "circle cot and csc: the pole at zero is unbounded both ways" {
    const at_zero = widen(ptZero(), 1e-6);
    for ([_]Function{ .cot, .csc }) |f| {
        const r = try answer(trig.forward(.circle, f, at_zero));
        if (!(r.lo <= -1e5 and r.hi >= 1e5)) {
            std.debug.print("FAIL circle {s} at zero: [{e},{e}]\n", .{ @tagName(f), r.lo, r.hi });
            return error.PoleMissed;
        }
    }
}

test "circle tan: a box clear of every pole is small" {
    // The counterweight to the pole tests. Across +/-1e-6 the tangent is
    // under 1e-5, so an answer that came back with an infinity in it would
    // be answering the pole instead of the box.
    const arg = widen(ptZero(), 1e-6);
    const r = try answer(trig.forward(.circle, .tan, arg));
    try expectWithin("tan across zero", r, -1e-5, 1e-5);
    try expectContains("tan at zero", r, 0.0);
}

test "hyperbola: the pole at zero of csch and coth is unbounded both ways" {
    const at_zero = widen(ptZero(), 1e-6);
    for ([_]Function{ .csc, .cot }) |f| {
        const r = try answer(trig.forward(.hyperbola, f, at_zero));
        if (!(r.lo <= -1e6 and r.hi >= 1e6)) {
            std.debug.print("FAIL hyperbola {s} at zero: [{e},{e}]\n", .{ @tagName(f), r.lo, r.hi });
            return error.PoleMissed;
        }
    }
}

test "hyperbola coth: the magnitude is above one, and it FALLS as the argument grows" {
    // cosh(x) > sinh(x) for x > 0 and cosh(x) > -sinh(x) for x < 0, because
    // the difference is exp(-|x|), which is never zero. So coth is above one
    // on the positive side and below minus one on the negative side, and it
    // is strictly DEcreasing on the positive side: the derivative is
    // -csch^2, which is negative everywhere it is defined.
    //
    // That direction is what makes the end values fall where they do. Over
    // [1,2] the image runs from coth(2), about 1.04, up to coth(1), about
    // 1.31. So one is not in the image at all, and a quarter past one is:
    // coth(1) > 5/4 because cosh(1) > 3/2 and sinh(1) < 6/5, and by oddness
    // coth(-1) < -5/4. Both of those are real values of the function over
    // the arguments given, so both belong in the answers.
    // The two `expectWithin` lines only ask that the answer not dip below
    // one, or rise above minus one, and they are deliberately loose about
    // HOW that end was arrived at, because there are two sound ways to get
    // there and this test must not pick one. An answer that evaluates the two
    // ends of the argument puts its lower bound at coth(2), about 1.037. An
    // answer that uses the proved limit coth(x) -> 1 as x grows puts it at
    // exactly one, deliberately including the [1, 1.037) that the true image
    // of [1,2] does not reach. Both are enclosures and both pass here, so the
    // slack in these two lines is not load bearing.
    //
    // The identity under them is cosh(x) - sinh(x) = exp(-x) > 0, which says
    // |coth| > 1 everywhere it is defined, with that as the limit. It is
    // NOT the claim that the image of any particular segment touches one.
    // That distinction cuts both ways and both directions are worth saying.
    // Tightening an answer to coth(2) would be a legitimate improvement, and
    // the test would still pass -- but it would make `expectWithin` here
    // check far less than the line reads as checking, because a correct
    // answer that used the limit would then be reported as a failure for
    // being wider than it had to be. So if that bound is ever tightened, this
    // line has to be loosened to match, not left to fail.
    //
    // The `expectContains` lines are the ones that depend on the far end,
    // and 1.25 and -1.25 are in those images because coth(1) > 5/4 out of
    // cosh(1) > 3/2 and sinh(1) < 6/5, and coth is odd.
    const pos = try answer(trig.forward(.hyperbola, .cot, Interval.init(1.0, 2.0)));
    try expectWithin("coth on [1,2]", pos, 1.0, inf);
    try expectContains("coth above one and a quarter", pos, 1.25);
    const neg = try answer(trig.forward(.hyperbola, .cot, Interval.init(-2.0, -1.0)));
    try expectWithin("coth on [-2,-1]", neg, -inf, -1.0);
    try expectContains("coth below minus one and a quarter", neg, -1.25);
}

/// The infinities, named once, for the range claims that are one-sided.
const inf: f64 = std.math.inf(f64);

test "diamond and square: the reciprocals are unbounded across their poles" {
    // The diamond's coordinates reach zero at pi/2 and at 0; the square's
    // reach zero at pi/2 and at 0 as well, the square's first coordinate
    // at pi/2 and its second at zero. Same arithmetic as the circle: the
    // denominator passes through zero and the quotient does not come back
    // with a finite pair of bounds.
    const diamond_sec = try answer(trig.forward(.diamond, .sec, widen(ptHalfPi(), 1e-6)));
    if (!(diamond_sec.lo <= -1e5 and diamond_sec.hi >= 1e5)) {
        std.debug.print("FAIL diamond sec across pi/2: [{e},{e}]\n", .{ diamond_sec.lo, diamond_sec.hi });
        return error.PoleMissed;
    }
    const diamond_csc = try answer(trig.forward(.diamond, .csc, widen(ptZero(), 1e-6)));
    if (!(diamond_csc.lo <= -1e6 and diamond_csc.hi >= 1e6)) {
        std.debug.print("FAIL diamond csc across zero: [{e},{e}]\n", .{ diamond_csc.lo, diamond_csc.hi });
        return error.PoleMissed;
    }
    const square_sec = try answer(trig.forward(.square, .sec, widen(ptHalfPi(), 1e-6)));
    if (!(square_sec.lo <= -1e5 and square_sec.hi >= 1e5)) {
        std.debug.print("FAIL square sec across pi/2: [{e},{e}]\n", .{ square_sec.lo, square_sec.hi });
        return error.PoleMissed;
    }
    const square_csc = try answer(trig.forward(.square, .csc, widen(ptZero(), 1e-6)));
    if (!(square_csc.lo <= -1e6 and square_csc.hi >= 1e6)) {
        std.debug.print("FAIL square csc across zero: [{e},{e}]\n", .{ square_csc.lo, square_csc.hi });
        return error.PoleMissed;
    }
}

test "hyperbolic ranges: the four bounds that are not free" {
    // sinh is odd and unbounded, so no range is claimed for it beyond the
    // sign it keeps on the argument it was given. cosh is at least one
    // everywhere, and cosh(1) > 1 + 1/2 out of its own series, so over
    // [0,1] it has to reach 1.5.
    const cosh01 = try answer(trig.forward(.hyperbola, .cos, Interval.init(0.0, 1.0)));
    try expectContains("cosh reaches one at zero", cosh01, 1.0);
    if (!(cosh01.hi >= 1.5)) {
        std.debug.print("FAIL cosh on [0,1]: upper bound {e} is below cosh(1) > 1.5\n", .{cosh01.hi});
        return error.ExtremumMissed;
    }
    // tanh is under one and over minus one, and tanh(1) > 3/4 because
    // tanh(1) = 1 - 2/(exp(2)+1) and exp(2) > 8.
    const tanh01 = try answer(trig.forward(.hyperbola, .tan, Interval.init(0.0, 1.0)));
    try expectWithin("tanh on [0,1]", tanh01, 0.0, 1.0);
    try expectContains("tanh at zero", tanh01, 0.0);
    if (!(tanh01.hi >= 0.75)) {
        std.debug.print("FAIL tanh on [0,1]: upper bound {e} is below tanh(1) > 0.75\n", .{tanh01.hi});
        return error.ExtremumMissed;
    }
    // sech is cosh turned upside down: under one and positive, and
    // sech(1) <= 2/3 because cosh(1) >= 3/2.
    const sech01 = try answer(trig.forward(.hyperbola, .sec, Interval.init(0.0, 1.0)));
    try expectWithin("sech on [0,1]", sech01, 0.0, 1.0);
    try expectContains("sech at zero", sech01, 1.0);
    if (!(sech01.lo < 0.7)) {
        std.debug.print("FAIL sech on [0,1]: lower bound {e} is above sech(1) < 0.7\n", .{sech01.lo});
        return error.ExtremumMissed;
    }
    // csch is positive on a positive argument and above 0.8 at one, because
    // sinh(1) < 1.2 out of its series.
    const csch12 = try answer(trig.forward(.hyperbola, .csc, Interval.init(1.0, 2.0)));
    try expectWithin("csch on [1,2]", csch12, 0.0, inf);
    if (!(csch12.hi > 0.8)) {
        std.debug.print("FAIL csch on [1,2]: upper bound {e} is below csch(1) > 0.8\n", .{csch12.hi});
        return error.ExtremumMissed;
    }
    // coth falls on the positive side, so over [1,2] the value coth(1) is at
    // the TOP of the image and coth(2) is at the bottom. The proved bound on
    // coth(1) therefore belongs on the upper side of the answer, and putting
    // it on the lower side would be demanding that the image of [1,2] reach
    // a number it does not contain.
    const coth12 = try answer(trig.forward(.hyperbola, .cot, Interval.init(1.0, 2.0)));
    if (!(coth12.hi >= 1.25)) {
        std.debug.print("FAIL coth on [1,2]: upper bound {e} is below coth(1) > 1.25\n", .{coth12.hi});
        return error.ExtremumMissed;
    }
}

// ---------------------------------------------------------------------------
// Principal inverse: the exact witnesses
// ---------------------------------------------------------------------------

test "circle principal inverse: the exact witnesses" {
    // Each of these is the inverse of an exact forward row, so the angle it
    // has to return is an exact multiple of pi and not a decimal.
    try expectContains("asin(0)", try answer(trig.principalInverse(.circle, .sin, pt(0.0))), 0.0);
    try expectReaches("asin(1/2)", try answer(trig.principalInverse(.circle, .sin, pt(0.5))), ptSixthPi());
    try expectReaches("asin(1)", try answer(trig.principalInverse(.circle, .sin, pt(1.0))), ptHalfPi());
    try expectReaches("asin(-1)", try answer(trig.principalInverse(.circle, .sin, pt(-1.0))), mulPiOver(-1, 2));

    try expectContains("acos(1)", try answer(trig.principalInverse(.circle, .cos, pt(1.0))), 0.0);
    try expectReaches("acos(1/2)", try answer(trig.principalInverse(.circle, .cos, pt(0.5))), ptThirdPi());
    try expectReaches("acos(0)", try answer(trig.principalInverse(.circle, .cos, pt(0.0))), ptHalfPi());
    try expectReaches("acos(-1)", try answer(trig.principalInverse(.circle, .cos, pt(-1.0))), ptPi());

    try expectContains("atan(0)", try answer(trig.principalInverse(.circle, .tan, pt(0.0))), 0.0);
    try expectReaches("atan(1)", try answer(trig.principalInverse(.circle, .tan, pt(1.0))), ptQuarterPi());
    try expectReaches("atan(-1)", try answer(trig.principalInverse(.circle, .tan, pt(-1.0))), mulPiOver(-1, 4));

    // arcsc is asin(1/x) and arcsec is acos(1/x), so at the reciprocal of
    // an exact forward witness they return the same exact angle.
    try expectReaches("arcsc(1)", try answer(trig.principalInverse(.circle, .csc, pt(1.0))), ptHalfPi());
    try expectReaches("arcsc(2)", try answer(trig.principalInverse(.circle, .csc, pt(2.0))), ptSixthPi());
    try expectReaches("arcsec(1)", try answer(trig.principalInverse(.circle, .sec, pt(1.0))), ptZero());
    try expectReaches("arcsec(2)", try answer(trig.principalInverse(.circle, .sec, pt(2.0))), ptThirdPi());

    // The cotangent is the only one of the six whose principal inverse is
    // not a quarter turn: it is the branch in (0, pi), so the sign of the
    // value picks the half and the value one is at pi/4, not at -3pi/4.
    try expectReaches("arccot(0)", try answer(trig.principalInverse(.circle, .cot, pt(0.0))), ptHalfPi());
    try expectReaches("arccot(1)", try answer(trig.principalInverse(.circle, .cot, pt(1.0))), ptQuarterPi());
    try expectReaches("arccot(-1)", try answer(trig.principalInverse(.circle, .cot, pt(-1.0))), ptThreeQuarterPi());
}

test "circle principal inverse: the branch in (0, pi) for cotangent" {
    // The whole range of the principal cotangent inverse, on every
    // geometry where the cotangent is the circular one.
    inline for (.{ Geometry.circle, .diamond, .square }) |g| {
        const name = std.fmt.comptimePrint("{s} arccot", .{@tagName(g)});
        for ([_]f64{ -4.0, -1.0, -0.25, 0.0, 0.25, 1.0, 4.0 }) |v| {
            const r = try answer(trig.principalInverse(g, .cot, pt(v)));
            // The branch is the half turn (0, pi), so no answer may leave
            // it, and the upper end is the certified witness for pi rather
            // than a decimal of it.
            try expectWithin(name, r, -slack, ptPi().hi);
        }
    }
}

test "hyperbola principal inverse: the proved windows" {
    // cosh(0.9) < 3/2 < cosh(1.1), so acosh(3/2) is inside [0.9, 1.1].
    try expectBetween("acosh(3/2)", try answer(trig.principalInverse(.hyperbola, .cos, pt(1.5))), 0.9, 1.1);
    // cosh is one at zero and never below it.
    try expectContains("acosh(1)", try answer(trig.principalInverse(.hyperbola, .cos, pt(1.0))), 0.0);
    // tanh(0.5) < 1/2 < tanh(0.6), so atanh(1/2) is inside [0.5, 0.6].
    try expectBetween("atanh(1/2)", try answer(trig.principalInverse(.hyperbola, .tan, pt(0.5))), 0.5, 0.6);
    try expectContains("atanh(0)", try answer(trig.principalInverse(.hyperbola, .tan, pt(0.0))), 0.0);
    // sinh(0.8) < 1 < sinh(1), so asinh(1) is inside [0.8, 1].
    try expectBetween("asinh(1)", try answer(trig.principalInverse(.hyperbola, .sin, pt(1.0))), 0.8, 1.0);
    try expectContains("asinh(0)", try answer(trig.principalInverse(.hyperbola, .sin, pt(0.0))), 0.0);
    // arcsch is asinh(1/x), the same window.
    try expectBetween("arcsch(1)", try answer(trig.principalInverse(.hyperbola, .csc, pt(1.0))), 0.8, 1.0);
    // arsech is acosh(1/x), and cosh(1.3) < 2 < cosh(1.4), so acosh(2) is
    // inside [1.3, 1.4].
    try expectBetween("arsech(1/2)", try answer(trig.principalInverse(.hyperbola, .sec, pt(0.5))), 1.3, 1.4);
    // arcoth is atanh(1/x); tanh(0.75) < 2/3 < tanh(0.85), so atanh(2/3)
    // is inside [0.75, 0.85].
    try expectBetween("arcoth(3/2)", try answer(trig.principalInverse(.hyperbola, .cot, pt(1.5))), 0.75, 0.85);
}

test "hyperbola principal inverse: even functions return the positive root" {
    // cosh and sech are even, so the principal root is the positive one.
    // A negative answer would be the other branch of the family, which is
    // where that answer belongs.
    const acosh = try answer(trig.principalInverse(.hyperbola, .cos, pt(1.5)));
    try expectWithin("acosh(3/2) is positive", acosh, 0.0, inf);
    const asech = try answer(trig.principalInverse(.hyperbola, .sec, pt(0.5)));
    try expectWithin("asech(1/2) is positive", asech, 0.0, inf);
}

test "diamond principal inverse: the exact witnesses" {
    // The diamond divides by |c| + |s|, so at pi/4 both coordinates are
    // 1/2, and its arcsine is atan(|y|/(1-|y|)) with the sign of y, which
    // at 1/2 is atan(1) = pi/4 exactly.
    try expectReaches("diamond asin(1/2)", try answer(trig.principalInverse(.diamond, .sin, pt(0.5))), ptQuarterPi());
    try expectReaches("diamond acos(1/2)", try answer(trig.principalInverse(.diamond, .cos, pt(0.5))), ptQuarterPi());
    try expectContains("diamond asin(0)", try answer(trig.principalInverse(.diamond, .sin, pt(0.0))), 0.0);
    try expectReaches("diamond acos(0)", try answer(trig.principalInverse(.diamond, .cos, pt(0.0))), ptHalfPi());
    // The ends of the diamond's range are its own vertices, so the arcsine
    // reaches a quarter turn exactly and the arccos reaches half of one.
    try expectReaches("diamond asin(1)", try answer(trig.principalInverse(.diamond, .sin, pt(1.0))), ptHalfPi());
    try expectReaches("diamond asin(-1)", try answer(trig.principalInverse(.diamond, .sin, pt(-1.0))), mulPiOver(-1, 2));
    try expectContains("diamond acos(1)", try answer(trig.principalInverse(.diamond, .cos, pt(1.0))), 0.0);
    try expectReaches("diamond acos(-1)", try answer(trig.principalInverse(.diamond, .cos, pt(-1.0))), ptPi());
    // The reciprocals run the same formulae at 1/y, so at 2 they land back
    // on the angle whose coordinate was 1/2.
    try expectReaches("diamond arcsc(2)", try answer(trig.principalInverse(.diamond, .csc, pt(2.0))), ptQuarterPi());
    try expectReaches("diamond arcsec(2)", try answer(trig.principalInverse(.diamond, .sec, pt(2.0))), ptQuarterPi());
    try expectReaches("diamond arctan(1)", try answer(trig.principalInverse(.diamond, .tan, pt(1.0))), ptQuarterPi());
}

test "square principal inverse: the exact witnesses" {
    // The square divides by max(|c|, |s|), so its arcsine is atan(y) on
    // [-1,1] and its arccos is a quarter turn less than that.
    try expectReaches("square asin(1)", try answer(trig.principalInverse(.square, .sin, pt(1.0))), ptQuarterPi());
    try expectReaches("square asin(-1)", try answer(trig.principalInverse(.square, .sin, pt(-1.0))), mulPiOver(-1, 4));
    try expectReaches("square acos(1)", try answer(trig.principalInverse(.square, .cos, pt(1.0))), ptQuarterPi());
    try expectReaches("square acos(-1)", try answer(trig.principalInverse(.square, .cos, pt(-1.0))), ptThreeQuarterPi());
    try expectContains("square asin(0)", try answer(trig.principalInverse(.square, .sin, pt(0.0))), 0.0);
    try expectReaches("square acos(0)", try answer(trig.principalInverse(.square, .cos, pt(0.0))), ptHalfPi());
    try expectReaches("square arctan(1)", try answer(trig.principalInverse(.square, .tan, pt(1.0))), ptQuarterPi());
}

test "square principal inverse: at one half the angle is a quarter turn off a half turn" {
    // acos_square(1/2) = pi/2 - atan(1/2), and tan(0.4) < 1/2 < tan(0.5),
    // so atan(1/2) is inside [0.4, 0.5] and the angle is inside
    // [pi/2 - 0.5, pi/2 - 0.4].
    const lo = angle(1, 2, 0.5);
    const hi = angle(1, 2, 0.4);
    const r = try answer(trig.principalInverse(.square, .sec, pt(2.0)));
    // The angle is one number inside that window, so the binding side is
    // the upper one: the answer may not sit above the top of the window.
    try expectBetween("square arcsec(2)", r, lo.lo, hi.hi);
    const c = try answer(trig.principalInverse(.square, .csc, pt(2.0)));
    try expectBetween("square arccsc(2)", c, 0.4, 0.5);
}

// ---------------------------------------------------------------------------
// Empty domains
// ---------------------------------------------------------------------------

test "principal inverse: an argument outside the range has no image" {
    // Each of these six is a whole argument interval outside the range of
    // the function being inverted, so there is no real angle at all and the
    // answer is the empty one.
    try expectAbsent("asin on [1.5,2]", trig.principalInverse(.circle, .sin, Interval.init(1.5, 2.0)));
    try expectAbsent("acos on [-2,-1.5]", trig.principalInverse(.circle, .cos, Interval.init(-2.0, -1.5)));
    try expectAbsent("arcsc on [0,0.5]", trig.principalInverse(.circle, .csc, Interval.init(0.0, 0.5)));
    try expectAbsent("arcsec on [0,0.5]", trig.principalInverse(.circle, .sec, Interval.init(0.0, 0.5)));
    try expectAbsent("acosh on [0,0.5]", trig.principalInverse(.hyperbola, .cos, Interval.init(0.0, 0.5)));
    try expectAbsent("atanh on [1.5,2]", trig.principalInverse(.hyperbola, .tan, Interval.init(1.5, 2.0)));
    try expectAbsent("arcoth on [0,0.5]", trig.principalInverse(.hyperbola, .cot, Interval.init(0.0, 0.5)));
    try expectAbsent("arcoth on [-0.5,0]", trig.principalInverse(.hyperbola, .cot, Interval.init(-0.5, 0.0)));
    try expectAbsent("arcsch at zero", trig.principalInverse(.hyperbola, .csc, pt(0.0)));
    try expectAbsent("asech on [1.5,2]", trig.principalInverse(.hyperbola, .sec, Interval.init(1.5, 2.0)));
    try expectAbsent("diamond asin on [1.5,2]", trig.principalInverse(.diamond, .sin, Interval.init(1.5, 2.0)));
    try expectAbsent("diamond arcsec on [0,0.5]", trig.principalInverse(.diamond, .sec, Interval.init(0.0, 0.5)));
    try expectAbsent("square asin on [1.5,2]", trig.principalInverse(.square, .sin, Interval.init(1.5, 2.0)));
    try expectAbsent("square arcsec on [0,0.5]", trig.principalInverse(.square, .sec, Interval.init(0.0, 0.5)));
    try expectAbsent("square arccsc at zero", trig.principalInverse(.square, .csc, pt(0.0)));
}

test "family: an argument outside the range has no branch at all" {
    // The family reports emptiness through its count rather than through a
    // null, so an argument with no real preimage is countable: zero.
    const cases = [_]struct { g: Geometry, f: Function, x: Interval }{
        .{ .g = .circle, .f = .sin, .x = Interval.init(1.5, 2.0) },
        .{ .g = .circle, .f = .cos, .x = Interval.init(-2.0, -1.5) },
        .{ .g = .circle, .f = .csc, .x = Interval.init(0.0, 0.5) },
        .{ .g = .circle, .f = .sec, .x = Interval.init(0.0, 0.5) },
        .{ .g = .hyperbola, .f = .cos, .x = Interval.init(0.0, 0.5) },
        .{ .g = .hyperbola, .f = .tan, .x = Interval.init(1.5, 2.0) },
        .{ .g = .hyperbola, .f = .sec, .x = Interval.init(1.5, 2.0) },
        .{ .g = .hyperbola, .f = .cot, .x = Interval.init(0.0, 0.5) },
        .{ .g = .diamond, .f = .sin, .x = Interval.init(1.5, 2.0) },
        .{ .g = .diamond, .f = .sec, .x = Interval.init(0.0, 0.5) },
        .{ .g = .square, .f = .sin, .x = Interval.init(1.5, 2.0) },
        .{ .g = .square, .f = .sec, .x = Interval.init(0.0, 0.5) },
        .{ .g = .square, .f = .csc, .x = Interval.init(0.0, 0.5) },
    };
    for (cases) |c| {
        const fam = trig.inverseFamily(c.g, c.f, c.x);
        if (fam.branchCount() != 0) {
            std.debug.print("FAIL {s} {s}: the family of an empty level set reports {any}\n", .{ @tagName(c.g), @tagName(c.f), fam.branchCount() });
            return error.ShouldBeEmpty;
        }
        var k: i64 = -3;
        while (k <= 3) : (k += 1) {
            if (fam.at(k) != null) {
                std.debug.print("FAIL {s} {s}: branch {d} of an empty family answered\n", .{ @tagName(c.g), @tagName(c.f), k });
                return error.ShouldBeEmpty;
            }
        }
    }
}

test "square: a coordinate of the square is at most one, so its reciprocals are at least one" {
    // |cos| and |sin| of the square are at most one in magnitude, so the
    // secant and the cosecant are at least one in magnitude. The empty
    // arguments are therefore the ones UNDER one, not the ones over it, and
    // the point one is not empty because the flat top and the flat side sit
    // there. Getting the direction of this the wrong way round is the
    // mistake the test is here for.
    const under_csc = trig.inverseFamily(.square, .csc, Interval.init(0.1, 0.9));
    if (under_csc.branchCount() != 0) return error.ShouldBeEmpty;
    const under_sec = trig.inverseFamily(.square, .sec, Interval.init(-0.5, 0.5));
    if (under_sec.branchCount() != 0) return error.ShouldBeEmpty;
    const over_csc = trig.inverseFamily(.square, .csc, Interval.init(1.0000001, 2.0));
    if (over_csc.branchCount() == 0) return error.ShouldBePresent;
    const over_sec = trig.inverseFamily(.square, .sec, Interval.init(2.0, 3.0));
    if (over_sec.branchCount() == 0) return error.ShouldBePresent;
    const at_one = trig.inverseFamily(.square, .csc, pt(1.0));
    if (at_one.branchCount() == 0) return error.ShouldBePresent;
    // The same shape on the circle, where the coordinates are at most one
    // and the reciprocal is at least one, and on the hyperbolic geometry,
    // whose cosh is at least one and whose domain starts there.
    const circle_under = trig.inverseFamily(.circle, .csc, Interval.init(0.1, 0.9));
    if (circle_under.branchCount() != 0) return error.ShouldBeEmpty;
    const circle_over = trig.inverseFamily(.circle, .sec, Interval.init(2.0, 3.0));
    if (circle_over.branchCount() == 0) return error.ShouldBePresent;
    const below = trig.inverseFamily(.hyperbola, .cos, Interval.init(0.0, 0.9999999));
    if (below.branchCount() != 0) return error.ShouldBeEmpty;
    const at_ve = trig.inverseFamily(.hyperbola, .cos, pt(1.0));
    if (at_ve.branchCount() != 1) return error.ShouldBePresent;
}

// ---------------------------------------------------------------------------
// The full inverse families
// ---------------------------------------------------------------------------

test "circle sin family: branch k sits at (-1)^k * p + k*pi" {
    // At the value zero the principal inverse is zero and the lattice
    // collapses to k*pi, which is exact for every integer k including the
    // negative ones. Each branch is also checked to be near its own k*pi
    // and not somewhere else in the line.
    const fam = trig.inverseFamily(.circle, .sin, pt(0.0));
    try testing.expect(fam.branchCount() == null);
    var k: i64 = -5;
    while (k <= 5) : (k += 1) {
        const want = mulPi(k);
        const got = try answer(fam.at(k));
        try expectReaches("sin family at zero", got, want);
        try expectWithin("sin family at zero is local", got, want.lo - 3.2, want.hi + 3.2);
    }
}

test "circle sin family: the exact lattice away from the origin" {
    // At 1/2 the principal inverse is pi/6 and every branch is
    // (-1)^k * pi/6 + k*pi, all exact. Two branches never overlap: they
    // are different solutions of the same equation.
    const fam = trig.inverseFamily(.circle, .sin, pt(0.5));
    var k: i64 = -4;
    while (k <= 4) : (k += 1) {
        const s: i64 = if (k % 2 == 0) 1 else -1;
        const want = addWitness(mulPiOver(s, 6), mulPi(k));
        const got = try answer(fam.at(k));
        try expectReaches("sin family at 1/2", got, want);
    }
    try expectPairwiseDisjoint(fam, -4, 4, "circle sin family at 1/2");
}

test "circle cos family: the two halves sit at p + 2n*pi and -p + 2n*pi" {
    // At zero the principal inverse is pi/2. Which of the pair of branch
    // indices carries the plus is not pinned here: the pair is checked as a
    // set, and the two are checked to be disjoint, because a single branch
    // holding both would be a branch with a hole in it.
    const fam = trig.inverseFamily(.circle, .cos, pt(0.0));
    try testing.expect(fam.branchCount() == null);
    var n: i64 = -2;
    while (n <= 2) : (n += 1) {
        const plus = addWitness(ptHalfPi(), mulPi(2 * n));
        const minus = addWitness(mulPiOver(-1, 2), mulPi(2 * n));
        const a0 = try answer(fam.at(2 * n));
        const a1 = try answer(fam.at(2 * n + 1));
        // The PAIR is checked as a set: the two solutions of a period are
        // reached by the two branches together, not by each branch on its
        // own. Demanding that each branch hold both would force the two to
        // intersect, which is what the check just below forbids.
        try expectReaches("cos family pair", a0.hull(a1), plus);
        try expectReaches("cos family pair", a0.hull(a1), minus);
        if (a0.intersect(a1) != null) {
            std.debug.print("FAIL circle cos family: branches {d} and {d} overlap\n", .{ 2 * n, 2 * n + 1 });
            return error.BranchesOverlap;
        }
    }
}

test "circle tan family: branch k sits at p + k*pi" {
    const fam = trig.inverseFamily(.circle, .tan, pt(1.0));
    try testing.expect(fam.branchCount() == null);
    var k: i64 = -4;
    while (k <= 4) : (k += 1) {
        const want = addWitness(ptQuarterPi(), mulPi(k));
        const got = try answer(fam.at(k));
        try expectReaches("tan family at one", got, want);
    }
    try expectPairwiseDisjoint(fam, -4, 4, "circle tan family at one");
}

test "circle cot family: branch k sits at p + k*pi, in the half turn" {
    // cot(pi/4) = 1 exactly, so the principal inverse of one is pi/4 and
    // every branch is pi/4 + k*pi. At the value zero the principal inverse
    // is pi/2 and the lattice is k*pi + pi/2, which is exact too.
    const one = trig.inverseFamily(.circle, .cot, pt(1.0));
    var k: i64 = -4;
    while (k <= 4) : (k += 1) {
        const want = addWitness(ptQuarterPi(), mulPi(k));
        try expectReaches("cot family at one", try answer(one.at(k)), want);
    }
    try expectPairwiseDisjoint(one, -4, 4, "circle cot family at one");

    const zero = trig.inverseFamily(.circle, .cot, pt(0.0));
    k = -4;
    while (k <= 4) : (k += 1) {
        const want = addWitness(ptHalfPi(), mulPi(k));
        try expectReaches("cot family at zero", try answer(zero.at(k)), want);
    }
    try expectPairwiseDisjoint(zero, -4, 4, "circle cot family at zero");
}

test "circle csc and sec families: the reciprocals inherit the lattice" {
    // csc(pi/6) = 2 exactly, so the family of the value two is the sine
    // family at 1/2: (-1)^k * pi/6 + k*pi. sec(pi/3) = 2 exactly, so the
    // family of the value two is the cosine family at 1/2, whose
    // principal inverse is pi/3.
    const csc = trig.inverseFamily(.circle, .csc, pt(2.0));
    var k: i64 = -4;
    while (k <= 4) : (k += 1) {
        const s: i64 = if (k % 2 == 0) 1 else -1;
        const want = addWitness(mulPiOver(s, 6), mulPi(k));
        try expectReaches("csc family at two", try answer(csc.at(k)), want);
    }
    try expectPairwiseDisjoint(csc, -4, 4, "circle csc family at two");

    const sec = trig.inverseFamily(.circle, .sec, pt(2.0));
    var n: i64 = -2;
    while (n <= 2) : (n += 1) {
        const plus = addWitness(ptThirdPi(), mulPi(2 * n));
        const minus = addWitness(mulPiOver(-1, 3), mulPi(2 * n));
        const a0 = try answer(sec.at(2 * n));
        const a1 = try answer(sec.at(2 * n + 1));
        // The pair as a set, for the reason given in the circle cos test.
        try expectReaches("sec family pair", a0.hull(a1), plus);
        try expectReaches("sec family pair", a0.hull(a1), minus);
        if (a0.intersect(a1) != null) return error.BranchesOverlap;
    }
}

test "diamond families: the same lattices at the exact witnesses" {
    // The diamond's arcsine at 1/2 is pi/4 exactly and its arccosine at 1/2
    // is pi/4 exactly, so both families have a complete exact table at the
    // value one half, and at the reciprocal value two.
    const sin_half = trig.inverseFamily(.diamond, .sin, pt(0.5));
    var k: i64 = -4;
    while (k <= 4) : (k += 1) {
        const s: i64 = if (k % 2 == 0) 1 else -1;
        const want = addWitness(mulPiOver(s, 4), mulPi(k));
        try expectReaches("diamond sin family at 1/2", try answer(sin_half.at(k)), want);
    }
    try expectPairwiseDisjoint(sin_half, -4, 4, "diamond sin family at 1/2");

    const cos_half = trig.inverseFamily(.diamond, .cos, pt(0.5));
    var n: i64 = -2;
    while (n <= 2) : (n += 1) {
        const plus = addWitness(ptQuarterPi(), mulPi(2 * n));
        const minus = addWitness(mulPiOver(-1, 4), mulPi(2 * n));
        const a0 = try answer(cos_half.at(2 * n));
        const a1 = try answer(cos_half.at(2 * n + 1));
        // The pair as a set, for the reason given in the circle cos test.
        try expectReaches("diamond cos family pair", a0.hull(a1), plus);
        try expectReaches("diamond cos family pair", a0.hull(a1), minus);
        if (a0.intersect(a1) != null) return error.BranchesOverlap;
    }

    const csc_two = trig.inverseFamily(.diamond, .csc, pt(2.0));
    k = -4;
    while (k <= 4) : (k += 1) {
        const s: i64 = if (k % 2 == 0) 1 else -1;
        const want = addWitness(mulPiOver(s, 4), mulPi(k));
        try expectReaches("diamond csc family at two", try answer(csc_two.at(k)), want);
    }

    const cot_one = trig.inverseFamily(.diamond, .cot, pt(1.0));
    k = -4;
    while (k <= 4) : (k += 1) {
        const want = addWitness(ptQuarterPi(), mulPi(k));
        try expectReaches("diamond cot family at one", try answer(cot_one.at(k)), want);
    }
    try expectPairwiseDisjoint(cot_one, -4, 4, "diamond cot family at one");
}

test "hyperbola families: the unique branches and the pair of roots" {
    // sinh, tanh and csch have one root where they have one at all, so
    // their families have exactly one branch and no second one.
    const sinh = trig.inverseFamily(.hyperbola, .sin, pt(1.0));
    try testing.expect(sinh.branchCount() == 1);
    try expectBetween("asinh(1)", try answer(sinh.at(0)), 0.8, 1.0);
    try expectAbsent("asinh has no second branch", sinh.at(1));

    const tanh = trig.inverseFamily(.hyperbola, .tan, pt(0.5));
    try testing.expect(tanh.branchCount() == 1);
    try expectBetween("atanh(1/2)", try answer(tanh.at(0)), 0.5, 0.6);
    try expectAbsent("atanh has no second branch", tanh.at(1));

    const csch = trig.inverseFamily(.hyperbola, .csc, pt(1.0));
    try testing.expect(csch.branchCount() == 1);
    try expectBetween("arcsch(1)", try answer(csch.at(0)), 0.8, 1.0);
    try expectAbsent("arcsch has no second branch", csch.at(1));

    const coth = trig.inverseFamily(.hyperbola, .cot, pt(1.5));
    try testing.expect(coth.branchCount() == 1);
    try expectBetween("arcoth(3/2)", try answer(coth.at(0)), 0.75, 0.85);
    try expectAbsent("arcoth has no second branch", coth.at(1));

    // cosh and sech are even, so they have two roots and the family has to
    // have two branches, one on each side of zero, with nothing between
    // them: a root of cosh(t) = 3/2 is never at a negative t and a branch
    // straddling zero would be a branch with a hole in it.
    const cosh = trig.inverseFamily(.hyperbola, .cos, pt(1.5));
    try testing.expect(cosh.branchCount() == 2);
    try expectAbsent("acosh has no third branch", cosh.at(2));
    const roots = [_]Interval{ try answer(cosh.at(0)), try answer(cosh.at(1)) };
    var first = roots[0];
    var second = roots[1];
    if (second.lo < first.lo) {
        first = roots[1];
        second = roots[0];
    }
    if (!(first.lo >= 0.0)) {
        std.debug.print("FAIL acosh family: the smaller root starts at {e}\n", .{first.lo});
        return error.RootOnWrongSide;
    }
    if (second.hi > 0.0) {
        std.debug.print("FAIL acosh family: the larger root ends at {e}\n", .{second.hi});
        return error.RootOnWrongSide;
    }
    try expectBetween("acosh positive root", first, 0.9, 1.1);
    try expectBetween("acosh negative root", second, -1.1, -0.9);
    if (first.intersect(second) != null) {
        std.debug.print("FAIL acosh family: the two roots overlap\n", .{});
        return error.BranchesOverlap;
    }

    const sech = trig.inverseFamily(.hyperbola, .sec, pt(0.5));
    try testing.expect(sech.branchCount() == 2);
    try expectAbsent("asech has no third branch", sech.at(2));
    const s0 = try answer(sech.at(0));
    const s1 = try answer(sech.at(1));
    var pos = s0;
    var neg = s1;
    if (neg.lo < pos.lo) {
        pos = s1;
        neg = s0;
    }
    try expectBetween("asech positive root", pos, 1.3, 1.4);
    try expectBetween("asech negative root", neg, -1.4, -1.3);
    if (pos.intersect(neg) != null) return error.BranchesOverlap;
}

test "hyperbolic family: at the vertex cosh has one root, not two" {
    // cosh(0) = 1 and cosh is at its smallest there, so the level set of
    // one is the single angle zero. A family reporting two branches at that
    // value would be reporting a second copy of the same angle.
    const fam = trig.inverseFamily(.hyperbola, .cos, pt(1.0));
    try testing.expect(fam.branchCount() == 1);
    try expectContains("acosh(1)", try answer(fam.at(0)), 0.0);
    const sech = trig.inverseFamily(.hyperbola, .sec, pt(1.0));
    try testing.expect(sech.branchCount() == 1);
    try expectContains("asech(1)", try answer(sech.at(0)), 0.0);
}

test "square families: the lattice inside a flat top" {
    // Away from the flat tops the square keeps the sine lattice. At the
    // value zero the principal inverse is zero and every branch is at k*pi,
    // which is exact, and the three branches inside one period are
    // disjoint.
    const fam = trig.inverseFamily(.square, .sin, pt(0.0));
    try testing.expect(fam.branchCount() == null);
    var k: i64 = -5;
    while (k <= 5) : (k += 1) {
        const want = mulPi(k);
        const got = try answer(fam.at(k));
        try expectReaches("square sin family at zero", got, want);
        try expectWithin("square sin family at zero is local", got, want.lo - 3.2, want.hi + 3.2);
    }
    try expectPairwiseDisjoint(fam, -5, 5, "square sin family at zero");

    const cos_fam = trig.inverseFamily(.square, .cos, pt(0.0));
    var n: i64 = -2;
    while (n <= 2) : (n += 1) {
        const plus = addWitness(ptHalfPi(), mulPi(2 * n));
        const minus = addWitness(mulPiOver(-1, 2), mulPi(2 * n));
        const a0 = try answer(cos_fam.at(2 * n));
        const a1 = try answer(cos_fam.at(2 * n + 1));
        // The pair as a set, for the reason given in the circle cos test.
        try expectReaches("square cos family pair", a0.hull(a1), plus);
        try expectReaches("square cos family pair", a0.hull(a1), minus);
    }

    // The square's ratios are the circular ones, so their families are the
    // circular families and the exact witness at one applies unchanged.
    const tan_fam = trig.inverseFamily(.square, .tan, pt(1.0));
    k = -4;
    while (k <= 4) : (k += 1) {
        const want = addWitness(ptQuarterPi(), mulPi(k));
        try expectReaches("square tan family at one", try answer(tan_fam.at(k)), want);
    }
    try expectPairwiseDisjoint(tan_fam, -4, 4, "square tan family at one");
}

fn expectPairwiseDisjoint(fam: Family, lo: i64, hi: i64, what: []const u8) !void {
    var a = lo;
    while (a <= hi) : (a += 1) {
        const x = fam.at(a) orelse continue;
        var b = a + 1;
        while (b <= hi) : (b += 1) {
            const y = fam.at(b) orelse continue;
            if (x.intersect(y) != null) {
                std.debug.print("FAIL {s}: branches {d} and {d} overlap\n", .{ what, a, b });
                return error.BranchesOverlap;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// The square's plateaus: a level set that is an interval of angles
// ---------------------------------------------------------------------------

/// The flat top of the square in its vertical coordinate, at the value one:
/// the whole of `[pi/4 + 2n*pi, 3pi/4 + 2n*pi]`, where the vertical
/// coordinate is the larger in magnitude and positive and so divides itself
/// out. The ends are both attained, and so is every angle between them.
fn squareSinPlateau(n: i64) Interval {
    return Interval.init(
        prevDown(ptQuarterPi().lo + mulPi(2 * n).lo),
        nextUp(ptThreeQuarterPi().hi + mulPi(2 * n).hi),
    );
}

/// The same for the value minus one: `[5pi/4 + 2n*pi, 7pi/4 + 2n*pi]`.
fn squareSinPlateauBelow(n: i64) Interval {
    return Interval.init(
        prevDown(mulPiOver(5, 4).lo + mulPi(2 * n).lo),
        nextUp(mulPiOver(7, 4).hi + mulPi(2 * n).hi),
    );
}

/// The flat side of the square in its horizontal coordinate, at the value
/// one: `[-pi/4 + 2n*pi, pi/4 + 2n*pi]`.
fn squareCosPlateau(n: i64) Interval {
    return Interval.init(
        prevDown(mulPiOver(-1, 4).lo + mulPi(2 * n).lo),
        nextUp(ptQuarterPi().hi + mulPi(2 * n).hi),
    );
}

/// The same at the value minus one: `[3pi/4 + 2n*pi, 5pi/4 + 2n*pi]`.
fn squareCosPlateauBelow(n: i64) Interval {
    return Interval.init(
        prevDown(ptThreeQuarterPi().lo + mulPi(2 * n).lo),
        nextUp(mulPiOver(5, 4).hi + mulPi(2 * n).hi),
    );
}

test "square sin family: the level set of one is an interval of angles" {
    // The square's vertical coordinate is one over the whole of its top
    // edge, so the angles answering to the value one are an interval and
    // not a point. Four things have to hold.
    //
    //  * The MIDDLE of the edge is reached. This is the check that catches
    //    the regression the whole file exists for: an answer that carries
    //    only one end of the level set and claims completeness misses the
    //    middle entirely, and the middle is not a branch point of anything.
    //  * Some ONE branch holds the whole interval. If the two ends were
    //    answered by two branches, the interior would have no home.
    //  * That branch spans the interval, which is the one-sided pair of
    //    checks below. This is NOT implied by the branch merely meeting the
    //    window, and the comment there says why.
    //  * That branch is as wide as the level set, so a degenerate answer
    //    cannot pass by being long enough in one direction only.
    //
    // The two ends of the edge are deliberately not checked as points. The
    // witness for an end is padded outward, so it sits OUTSIDE the true
    // level set, and no correct answer can contain it. They are covered by
    // the span check instead, which asks whether the answer reaches down to
    // the left end and up to the right end -- the question that is actually
    // meaningful about an end.
    const fam = trig.inverseFamily(.square, .sin, pt(1.0));
    try testing.expect(fam.branchCount() == null);

    var n: i64 = -2;
    while (n <= 2) : (n += 1) {
        const plateau = squareSinPlateau(n);
        // The MIDDLE of the plateau is the angle that decides this. It is
        // interior, so an answer carrying only one end of the level set
        // misses it entirely, and it is far from either end, so a window a
        // couple of steps wide around it is comfortably inside any answer
        // that holds the plateau. The two ends are deliberately not checked
        // here: their witnesses are padded outward and so sit BELOW and
        // ABOVE the true ends, and asking a tight answer to reach them
        // would be asking it to be wider than the truth. What the ends get
        // checked by is the branch just below, which overlaps the whole
        // level-set window.
        try expectReachable(fam, n, plateau.midpoint(), "square sin plateau middle");
        // And one branch holds the lot.
        const held = try branchHolding(fam, 2 * n - 3, 2 * n + 3, plateau, plateau, "square sin plateau");
        try expectReaches("square sin plateau", held, plateau);
        try expectSpans("square sin plateau spans its level set", held, plateau);
        const width = plateau.hi - plateau.lo;
        if (!(held.hi - held.lo >= width - slack)) {
            std.debug.print("FAIL square sin plateau at n = {d}: the branch is {e} wide, the level set is {e}\n", .{ n, held.hi - held.lo, width });
            return error.PlateauTooNarrow;
        }
    }
}

test "square sin family: the level set of minus one is an interval of angles" {
    const fam = trig.inverseFamily(.square, .sin, pt(-1.0));
    var n: i64 = -2;
    while (n <= 2) : (n += 1) {
        const plateau = squareSinPlateauBelow(n);
        // The middle of the edge, for the reason given in the test above.
        try expectReachable(fam, n, plateau.midpoint(), "square sin lower plateau middle");
        const held = try branchHolding(fam, 2 * n - 3, 2 * n + 3, plateau, plateau, "square sin lower plateau");
        try expectSpans("square sin lower plateau spans its level set", held, plateau);
        const width = plateau.hi - plateau.lo;
        if (!(held.hi - held.lo >= width - slack)) return error.PlateauTooNarrow;
    }
}

test "square cos family: the flat side is an interval of angles" {
    const fam = trig.inverseFamily(.square, .cos, pt(1.0));
    var n: i64 = -2;
    while (n <= 2) : (n += 1) {
        const plateau = squareCosPlateau(n);
        try expectReachable(fam, n, plateau.midpoint(), "square cos plateau middle");
        const held = try branchHolding(fam, 2 * n - 3, 2 * n + 3, plateau, plateau, "square cos plateau");
        try expectSpans("square cos plateau spans its level set", held, plateau);
        const width = plateau.hi - plateau.lo;
        if (!(held.hi - held.lo >= width - slack)) return error.PlateauTooNarrow;
    }
    const below = trig.inverseFamily(.square, .cos, pt(-1.0));
    n = -2;
    while (n <= 2) : (n += 1) {
        const plateau = squareCosPlateauBelow(n);
        try expectReachable(below, n, plateau.midpoint(), "square cos lower plateau middle");
        const held = try branchHolding(below, 2 * n - 3, 2 * n + 3, plateau, plateau, "square cos lower plateau");
        try expectSpans("square cos lower plateau spans its level set", held, plateau);
        const width = plateau.hi - plateau.lo;
        if (!(held.hi - held.lo >= width - slack)) return error.PlateauTooNarrow;
    }
}

test "square sec and csc families: the plateaus are the same as the coordinates" {
    // sec is 1 over cos and csc is 1 over sin, so their level sets at one
    // and at minus one are the level sets of cos and sin at the same value.
    // The plateaus have to come back whole through the reciprocals too, and
    // not as a point.
    const sec = trig.inverseFamily(.square, .sec, pt(1.0));
    var n: i64 = -2;
    while (n <= 2) : (n += 1) {
        const plateau = squareCosPlateau(n);
        try expectReachable(sec, n, plateau.midpoint(), "square sec plateau middle");
        const held = try branchHolding(sec, 2 * n - 3, 2 * n + 3, plateau, plateau, "square sec plateau");
        try expectSpans("square sec plateau spans its level set", held, plateau);
        if (!(held.hi - held.lo >= (plateau.hi - plateau.lo) - slack)) return error.PlateauTooNarrow;
    }
    const csc = trig.inverseFamily(.square, .csc, pt(1.0));
    n = -2;
    while (n <= 2) : (n += 1) {
        const plateau = squareSinPlateau(n);
        try expectReachable(csc, n, plateau.midpoint(), "square csc plateau middle");
        const held = try branchHolding(csc, 2 * n - 3, 2 * n + 3, plateau, plateau, "square csc plateau");
        try expectSpans("square csc plateau spans its level set", held, plateau);
        if (!(held.hi - held.lo >= (plateau.hi - plateau.lo) - slack)) return error.PlateauTooNarrow;
    }
    const csc_below = trig.inverseFamily(.square, .csc, pt(-1.0));
    n = -2;
    while (n <= 2) : (n += 1) {
        const plateau = squareSinPlateauBelow(n);
        try expectReachable(csc_below, n, plateau.midpoint(), "square csc lower plateau middle");
        const held = try branchHolding(csc_below, 2 * n - 3, 2 * n + 3, plateau, plateau, "square csc lower plateau");
        try expectSpans("square csc lower plateau spans its level set", held, plateau);
        if (!(held.hi - held.lo >= (plateau.hi - plateau.lo) - slack)) return error.PlateauTooNarrow;
    }
}

test "square: the diamond has no plateau and the square has one" {
    // The counterweight to the plateau tests. The diamond divides by
    // |c| + |s|, which reaches one only at the vertices, so its arcsine is
    // strictly rising all the way to a quarter turn and the family of the
    // value one is a point per period. A square-shaped answer here would be
    // wrong, not merely loose.
    const dia = trig.inverseFamily(.diamond, .sin, pt(1.0));
    var n: i64 = -1;
    while (n <= 1) : (n += 1) {
        const want = addWitness(ptHalfPi(), mulPi(2 * n));
        const held = try branchHolding(dia, 2 * n - 3, 2 * n + 3, want, want, "diamond sin at one");
        // The diamond's arcsine is strictly rising to a quarter turn, so
        // this branch has to be at that one angle. Spanning is what says so
        // here: a branch sitting anywhere else, even one of the right tiny
        // width, fails it.
        try expectSpans("diamond sin at one sits at its angle", held, want);
        if (!(held.hi - held.lo <= 1e-3)) {
            std.debug.print("FAIL diamond sin at one, n = {d}: the branch is {e} wide, a point was expected\n", .{ n, held.hi - held.lo });
            return error.PlateauUnexpected;
        }
    }
}

/// Some branch reaches `p`, searched in the window `2n - 3 .. 2n + 3`
/// around the period `n` the level set belongs to.
///
/// `branchHolding` searches the same window for the same reason.
///
/// The window is LOAD BEARING and it is not a courtesy. Which branch index
/// carries a whole flat edge is an encoding choice the contract does not
/// fix: an implementation is free to put the edge on the even branch of its
/// period or on the odd one, and to let the neighbouring branch carry only
/// the degenerate lattice point at one end of it, and those two choices put
/// the edge on different single indices. Both are self consistent and both
/// satisfy the same mathematics, so the window is what lets this file test
/// the mathematics rather than one particular encoding of it.
///
/// The consequence runs the other way too, and is the reason this comment
/// is here at all: narrowing the window from `2n +/- 3` to a single assumed
/// index would silently promote an encoding choice into a pinned behaviour,
/// and the test would then fail against a correct implementation that chose
/// the other parity. Do not do that.
fn expectReachable(fam: Family, n: i64, p: f64, what: []const u8) !void {
    _ = try branchReaching(fam, 2 * n - 3, 2 * n + 3, Interval.init(prevDown(p), nextUp(p)), what);
}

// ---------------------------------------------------------------------------
// Periodic continuation of the forward functions
// ---------------------------------------------------------------------------

test "every geometry: the forward functions come back after a full turn" {
    // The same angle one period away has the same exact value. That is a
    // statement about the period that does not depend on how either of the
    // two enclosures happened to be rounded, which is all that comparing
    // the two enclosures against each other would have been: both are
    // roundings of the same image and either could be the wider.
    const cases = [_]struct { g: Geometry, f: Function, plus: Interval, minus: Interval, v: f64 }{
        .{ .g = .circle, .f = .sin, .plus = addWitness(mulPi(2), ptSixthPi()), .minus = addWitness(mulPi(-2), ptSixthPi()), .v = 0.5 },
        .{ .g = .circle, .f = .csc, .plus = addWitness(mulPi(2), ptSixthPi()), .minus = addWitness(mulPi(-2), ptSixthPi()), .v = 2.0 },
        .{ .g = .circle, .f = .cos, .plus = mulPi(2), .minus = mulPi(-2), .v = 1.0 },
        .{ .g = .circle, .f = .sec, .plus = mulPi(2), .minus = mulPi(-2), .v = 1.0 },
        .{ .g = .circle, .f = .cos, .plus = addWitness(mulPi(2), ptPi()), .minus = addWitness(mulPi(-2), ptPi()), .v = -1.0 },
        .{ .g = .circle, .f = .tan, .plus = addWitness(mulPi(2), ptQuarterPi()), .minus = addWitness(mulPi(-2), ptQuarterPi()), .v = 1.0 },
        .{ .g = .circle, .f = .cot, .plus = addWitness(mulPi(2), ptQuarterPi()), .minus = addWitness(mulPi(-2), ptQuarterPi()), .v = 1.0 },
        .{ .g = .diamond, .f = .sin, .plus = addWitness(mulPi(2), ptQuarterPi()), .minus = addWitness(mulPi(-2), ptQuarterPi()), .v = 0.5 },
        .{ .g = .diamond, .f = .cos, .plus = addWitness(mulPi(2), ptQuarterPi()), .minus = addWitness(mulPi(-2), ptQuarterPi()), .v = 0.5 },
        .{ .g = .diamond, .f = .tan, .plus = addWitness(mulPi(2), ptQuarterPi()), .minus = addWitness(mulPi(-2), ptQuarterPi()), .v = 1.0 },
        .{ .g = .diamond, .f = .csc, .plus = addWitness(mulPi(2), ptQuarterPi()), .minus = addWitness(mulPi(-2), ptQuarterPi()), .v = 2.0 },
        .{ .g = .diamond, .f = .sec, .plus = addWitness(mulPi(2), ptQuarterPi()), .minus = addWitness(mulPi(-2), ptQuarterPi()), .v = 2.0 },
        .{ .g = .diamond, .f = .cot, .plus = addWitness(mulPi(2), ptQuarterPi()), .minus = addWitness(mulPi(-2), ptQuarterPi()), .v = 1.0 },
        .{ .g = .square, .f = .sin, .plus = addWitness(mulPi(2), ptQuarterPi()), .minus = addWitness(mulPi(-2), ptQuarterPi()), .v = 1.0 },
        .{ .g = .square, .f = .cos, .plus = addWitness(mulPi(2), ptQuarterPi()), .minus = addWitness(mulPi(-2), ptQuarterPi()), .v = 1.0 },
        .{ .g = .square, .f = .tan, .plus = addWitness(mulPi(2), ptQuarterPi()), .minus = addWitness(mulPi(-2), ptQuarterPi()), .v = 1.0 },
        .{ .g = .square, .f = .csc, .plus = addWitness(mulPi(2), ptQuarterPi()), .minus = addWitness(mulPi(-2), ptQuarterPi()), .v = 1.0 },
        .{ .g = .square, .f = .sec, .plus = addWitness(mulPi(2), ptQuarterPi()), .minus = addWitness(mulPi(-2), ptQuarterPi()), .v = 1.0 },
        .{ .g = .square, .f = .cot, .plus = addWitness(mulPi(2), ptQuarterPi()), .minus = addWitness(mulPi(-2), ptQuarterPi()), .v = 1.0 },
    };
    for (cases) |c| {
        const name = std.fmt.comptimePrint("{s} {s} one period away", .{ @tagName(c.g), @tagName(c.f) });
        try expectContains(name, try answer(trig.forward(c.g, c.f, c.plus)), c.v);
        try expectContains(name, try answer(trig.forward(c.g, c.f, c.minus)), c.v);
    }
}

test "polygon forward: the quadrant answers of the two polygons are signed alike" {
    // Dividing by a sum or a maximum of absolute values never changes a
    // sign, so the sign of a polygon coordinate in each quadrant is the
    // sign of the circular one. This is the cheap statement that a polygon
    // forward function is using the polygon of its geometry and not the
    // plain circle under another name.
    inline for (.{ Geometry.diamond, .square }) |g| {
        const name = @tagName(g);
        const first = try answer(trig.forward(g, .sin, Interval.init(0.0, ptHalfPi().hi)));
        try expectWithin(name, first, 0.0, 1.0);
        const second = try answer(trig.forward(g, .sin, Interval.init(ptHalfPi().lo, ptPi().hi)));
        try expectWithin(name, second, 0.0, 1.0);
        const third = try answer(trig.forward(g, .sin, Interval.init(ptPi().lo, mulPi(2).hi)));
        try expectWithin(name, third, -1.0, 0.0);
        const fourth = try answer(trig.forward(g, .sin, Interval.init(mulPiOver(3, 2).lo, mulPi(2).hi)));
        try expectWithin(name, fourth, -1.0, 0.0);
    }
}
