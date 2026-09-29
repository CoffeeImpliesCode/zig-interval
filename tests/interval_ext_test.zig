//! The elementary functions, checked as enclosures.
//!
//! A transcendental value is not a number the test can write down, so
//! these assert that the result reaches past it rather than that it
//! equals it. Asserting equality against a rounded literal would pin
//! the width of the enclosure instead of its correctness. Only the
//! values that are exact in binary floating point, the integers and the
//! infinities, are compared for equality.
//!
//! Two of the tests below do reach into the width, and deliberately. The
//! enclosure is the whole point of the library, and the elementary
//! functions are widened by two ULP rather than one because a measured
//! worst case of 1.07 ULP no longer fits in one. A test that quietly
//! stopped caring about that would let the margin be narrowed away by
//! someone tidying up, so the width is pinned as well as the containment.

const std = @import("std");
const interval = @import("interval");
const Interval = interval.Interval;
const ext = interval.ext;

const inf = std.math.inf(f64);

/// The answer of a function which may be outside its domain, with the
/// two checks every answer owes: that it answered at all, and that the
/// interval it handed back respects lo <= hi.
fn answer(x: ?Interval) !Interval {
    const i = x orelse return error.OutOfDomain;
    try std.testing.expect(i.lo <= i.hi);
    return i;
}

/// The same check without keeping the answer, for the sweep over every
/// function at once.
fn check(x: ?Interval) !void {
    _ = try answer(x);
}

test "sqrt: the roots of a positive interval sit inside the result" {
    const s = try answer(ext.sqrt(Interval.init(4.0, 9.0)));
    try std.testing.expect(s.lo <= 2.0);
    try std.testing.expect(s.hi >= 3.0);
    // Two ULP out at each end, which is what the widening rule costs an
    // elementary function.
    try std.testing.expect(s.lo >= interval.prevDown(interval.prevDown(2.0)));
    try std.testing.expect(s.hi <= interval.nextUp(interval.nextUp(3.0)));
}

test "sqrt: a lower end below zero contributes only the bound at zero" {
    const s = try answer(ext.sqrt(Interval.init(0.0, 4.0)));
    try std.testing.expect(s.lo <= 0.0);
    try std.testing.expect(s.hi >= 2.0);
    // The image starts at zero and not below it, however far the
    // interval reaches under the axis.
    const below = try answer(ext.sqrt(Interval.init(-4.0, 4.0)));
    try std.testing.expect(below.lo <= 0.0);
    try std.testing.expectEqual(s.hi, below.hi);
}

test "sqrt: a degenerate interval still encloses its one root" {
    const s = try answer(ext.sqrt(Interval.init(9.0, 9.0)));
    try std.testing.expect(s.lo <= 3.0);
    try std.testing.expect(s.hi >= 3.0);
}

test "sqrt: an interval with no positive part has no image" {
    try std.testing.expect(ext.sqrt(Interval.init(-4.0, -1.0)) == null);
}

test "exp: the exponentials of the ends sit inside the result" {
    const e = try answer(ext.exp(Interval.init(0.0, 1.0)));
    try std.testing.expect(e.lo <= 1.0);
    try std.testing.expect(e.hi >= 2.718281828459045);
}

test "exp: a degenerate interval encloses the one value" {
    const e = try answer(ext.exp(Interval.init(1.0, 1.0)));
    try std.testing.expect(e.lo <= 2.718281828459045);
    try std.testing.expect(e.hi >= 2.718281828459045);
}

test "log: the logarithms of the ends sit inside the result" {
    const l = try answer(ext.log(Interval.init(1.0, 10.0)));
    try std.testing.expect(l.lo <= 0.0);
    try std.testing.expect(l.hi >= 2.302585092994046);
}

test "log: an interval reaching zero runs to minus infinity" {
    // The argument comes arbitrarily close to zero, and the logarithm
    // of that is arbitrarily far down, so no finite lower bound holds.
    const l = try answer(ext.log(Interval.init(0.0, 1.0)));
    try std.testing.expectEqual(-inf, l.lo);
    try std.testing.expect(l.hi >= 0.0);
}

test "log: an interval without a positive part has no image" {
    try std.testing.expect(ext.log(Interval.init(-2.0, 0.0)) == null);
}

test "asin: the angles of the ends sit inside the result" {
    const a = try answer(ext.asin(Interval.init(0.0, 1.0)));
    try std.testing.expect(a.lo <= 0.0);
    try std.testing.expect(a.hi >= 1.5707963267948966);
}

test "asin: outside [-1, 1] there is no real angle" {
    try std.testing.expect(ext.asin(Interval.init(-2.0, 0.0)) == null);
    try std.testing.expect(ext.asin(Interval.init(0.0, 1.5)) == null);
}

test "acos: the angles of the ends sit inside the result, falling" {
    const a = try answer(ext.acos(Interval.init(0.0, 1.0)));
    // acos falls where asin rises: the far end of the interval is the
    // low one here, which is the case envelope has to get right.
    try std.testing.expect(a.lo <= 0.0);
    try std.testing.expect(a.hi >= 1.5707963267948966);
}

test "acos: outside [-1, 1] there is no real angle" {
    try std.testing.expect(ext.acos(Interval.init(1.5, 2.0)) == null);
    try std.testing.expect(ext.acos(Interval.init(-2.0, -1.5)) == null);
}

test "atanh: the angles of the ends sit inside the result" {
    const a = try answer(ext.atanh(Interval.init(0.0, 0.5)));
    try std.testing.expect(a.lo <= 0.0);
    try std.testing.expect(a.hi >= 0.5493061443340548);
}

test "atanh: the domain is open, and its ends are not on it" {
    try std.testing.expect(ext.atanh(Interval.init(0.0, 1.0)) == null);
    try std.testing.expect(ext.atanh(Interval.init(-1.0, 0.0)) == null);
}

test "acosh: the values of the ends sit inside the result" {
    const a = try answer(ext.acosh(Interval.init(1.0, 4.0)));
    // One is the end of the domain and acosh is exactly zero there.
    try std.testing.expect(a.lo <= 0.0);
    try std.testing.expect(a.hi >= 2.0634370688955608);
}

test "acosh: an interval short of one has no image" {
    try std.testing.expect(ext.acosh(Interval.init(0.0, 0.5)) == null);
}

test "pow: exponent zero is one everywhere, and exactly so" {
    const p = try answer(ext.pow(Interval.init(-3.0, 4.0), 0));
    try std.testing.expectEqual(@as(f64, 1.0), p.lo);
    try std.testing.expectEqual(@as(f64, 1.0), p.hi);
}

test "pow: a positive exponent raises the interval" {
    const p = try answer(ext.pow(Interval.init(2.0, 3.0), 2));
    try std.testing.expect(p.lo <= 4.0);
    try std.testing.expect(p.hi >= 9.0);

    const cube = try answer(ext.pow(Interval.init(2.0, 3.0), 3));
    try std.testing.expect(cube.lo <= 8.0);
    try std.testing.expect(cube.hi >= 27.0);
}

test "pow: a negative exponent inverts the interval" {
    const p = try answer(ext.pow(Interval.init(2.0, 3.0), -1));
    try std.testing.expect(p.lo <= 0.3333333333333333);
    try std.testing.expect(p.hi >= 0.5);

    const square = try answer(ext.pow(Interval.init(2.0, 4.0), -2));
    try std.testing.expect(square.lo <= 0.0625);
    try std.testing.expect(square.hi >= 0.25);
}

test "pow: a negative power of a base reaching zero is unbounded" {
    // Unbounded, which is not the same as having no image: the values
    // are real, there are just no finite bounds on them.
    const p = try answer(ext.pow(Interval.init(0.0, 0.0), -1));
    try std.testing.expectEqual(-inf, p.lo);
    try std.testing.expectEqual(inf, p.hi);
}

test "powf: the corners of the box hold the extremes" {
    const p = try answer(ext.powf(Interval.init(2.0, 3.0), Interval.init(2.0, 3.0)));
    try std.testing.expect(p.lo <= 4.0);
    try std.testing.expect(p.hi >= 27.0);
}

test "powf: a negative base has no real general power" {
    try std.testing.expect(ext.powf(Interval.init(-2.0, -1.0), Interval.init(0.5, 2.0)) == null);
}

test "powf: a base reaching zero under a non-positive exponent runs up" {
    const p = try answer(ext.powf(Interval.init(0.0, 2.0), Interval.init(-1.0, 2.0)));
    try std.testing.expectEqual(@as(f64, 0.0), p.lo);
    try std.testing.expectEqual(inf, p.hi);
}

test "powf: a base of exactly zero answers from the exponent alone" {
    const up = try answer(ext.powf(Interval.init(0.0, 0.0), Interval.init(1.0, 3.0)));
    try std.testing.expectEqual(@as(f64, 0.0), up.lo);
    try std.testing.expectEqual(@as(f64, 0.0), up.hi);

    const across = try answer(ext.powf(Interval.init(0.0, 0.0), Interval.init(0.0, 2.0)));
    try std.testing.expectEqual(@as(f64, 0.0), across.lo);
    try std.testing.expectEqual(@as(f64, 1.0), across.hi);
}

test "sin: inside one monotone piece the endpoints hold the range" {
    const s = try answer(ext.sin(Interval.init(0.0, 1.0)));
    try std.testing.expect(s.lo <= 0.0);
    try std.testing.expect(s.hi >= 0.8414709848078965);
    // No critical point lies in [0, 1], so neither end of the range of
    // sine is reached and the result is not the whole of [-1, 1].
    try std.testing.expect(s.lo > -1.0);
    try std.testing.expect(s.hi < 1.0);
}

test "sin: an interval holding a maximum reaches exactly one" {
    // 30.5*pi is 95.82, inside this interval, and the neighbouring
    // critical points at 92.68 and 98.96 are both outside it.
    const s = try answer(ext.sin(Interval.init(94.0, 97.0)));
    try std.testing.expectEqual(@as(f64, 1.0), s.hi);
    try std.testing.expect(s.lo <= -0.24525198546765434);
    try std.testing.expect(s.lo > -1.0);
}

test "sin: an interval holding a minimum reaches exactly minus one" {
    // 31.5*pi is 98.96, inside this interval, and it is the minimum.
    const s = try answer(ext.sin(Interval.init(98.0, 100.0)));
    try std.testing.expectEqual(@as(f64, -1.0), s.lo);
    try std.testing.expect(s.hi >= -0.5063656411097588);
    try std.testing.expect(s.hi < 1.0);
}

test "sin: a large argument still finds its critical points" {
    // No critical point here, and the search has to say so by walking
    // the index near 32 rather than answering with the whole range.
    const s = try answer(ext.sin(Interval.init(100.0, 100.5)));
    try std.testing.expect(s.lo <= -0.5063656411097588);
    try std.testing.expect(s.hi >= -0.030959966783271346);
    try std.testing.expect(s.lo > -1.0);
    try std.testing.expect(s.hi < 1.0);
}

test "sin: a full period reaches both ends of the range exactly" {
    const s = try answer(ext.sin(Interval.init(0.0, 8.0)));
    try std.testing.expectEqual(@as(f64, -1.0), s.lo);
    try std.testing.expectEqual(@as(f64, 1.0), s.hi);
}

test "cos: an interval holding a maximum reaches exactly one" {
    const c = try answer(ext.cos(Interval.init(-1.0, 1.0)));
    // The critical point at zero is a maximum of cosine and is worth
    // exactly 1, so the upper bound lands on it rather than near it.
    try std.testing.expectEqual(@as(f64, 1.0), c.hi);
    try std.testing.expect(c.lo <= 0.5403023058681398);
    try std.testing.expect(c.lo > 0.5);
}

test "cos: an interval holding a minimum reaches exactly minus one" {
    // The critical point at pi is a minimum of cosine, and it is the
    // only one inside [2, 4].
    const c = try answer(ext.cos(Interval.init(2.0, 4.0)));
    try std.testing.expectEqual(@as(f64, -1.0), c.lo);
    try std.testing.expect(c.hi >= -0.6536436208636119);
    try std.testing.expect(c.hi < 0.0);
}

test "cos: a full period reaches both ends of the range exactly" {
    const c = try answer(ext.cos(Interval.init(-8.0, 0.0)));
    try std.testing.expectEqual(@as(f64, -1.0), c.lo);
    try std.testing.expectEqual(@as(f64, 1.0), c.hi);
}

test "tan: an interval holding a pole is unbounded" {
    // pi/2 is inside [1, 2], and tangent there has no finite bounds.
    const t = try answer(ext.tan(Interval.init(1.0, 2.0)));
    try std.testing.expectEqual(-inf, t.lo);
    try std.testing.expectEqual(inf, t.hi);
}

test "tan: an interval clear of a pole is finite and rising" {
    const t = try answer(ext.tan(Interval.init(0.0, 1.0)));
    try std.testing.expect(t.lo <= 0.0);
    try std.testing.expect(t.hi >= 1.5574077246549023);
    // The nearest pole above is at 1.57, so nothing here runs away.
    try std.testing.expect(t.hi < 100.0);
}

test "cosh: the even function answers to the magnitude alone" {
    const c = try answer(ext.cosh(Interval.init(-2.0, 2.0)));
    const same = try answer(ext.cosh(Interval.init(0.0, 2.0)));
    try std.testing.expectEqual(c.lo, same.lo);
    try std.testing.expectEqual(c.hi, same.hi);
    try std.testing.expect(c.lo > 0.0);
    try std.testing.expect(c.hi >= 3.7621956910836314);
}

test "tanh: rising across the origin, from one sign to the other" {
    const t = try answer(ext.tanh(Interval.init(-1.0, 1.0)));
    try std.testing.expect(t.lo <= -0.7615941559557649);
    try std.testing.expect(t.hi >= 0.7615941559557649);
    try std.testing.expect(t.lo < 0.0);
    try std.testing.expect(t.hi > 0.0);
}

test "tanh: the result encloses the true value across a spread of arguments" {
    // The true value of tanh at each argument, written out to twenty
    // significant decimal digits. The literal in a test is itself an f64,
    // so it is not the true value: parsed, it is the f64 nearest to the
    // decimal written, and that sits within half a ULP of the true value.
    // A sound enclosure must therefore cover the whole band
    // [ref - tol, ref + tol], and that band is what the two assertions
    // below check. `tol` is measured in ULPs through the library's own
    // `nextUp`, so it tracks the magnitude of the value rather than a
    // fixed decimal scale.
    //
    // tanh is the function the two-ULP widening was chosen for: it is
    // the worst of the measured primitives at 1.07 ULP, which a single
    // step does not absorb.
    const cases = [_]struct { x: f64, ref: f64 }{
        .{ .x = 0.1, .ref = 0.09966799462495582261 },
        .{ .x = 0.5, .ref = 0.46211715726000975850 },
        .{ .x = 1.0, .ref = 0.76159415595576488812 },
        .{ .x = 2.0, .ref = 0.96402758007581688395 },
        .{ .x = 10.0, .ref = 0.99999999587769276362 },
    };
    for (cases) |c| {
        const t = try answer(ext.tanh(Interval.init(c.x, c.x)));
        const tol = 0.5 * (interval.nextUp(c.ref) - c.ref);
        try std.testing.expect(t.lo <= c.ref - tol);
        try std.testing.expect(t.hi >= c.ref + tol);
    }
}

test "tanh: the result reaches past a one-ULP step, so a narrower one fails" {
    // The argument is read out of a table rather than written as a
    // literal because the `std.math` primitives have no comptime path:
    // a compile-time float would be folded and rejected. What the table
    // buys is a run-time value the primitive can be asked about, which
    // is the only way to name the single-step bound to compare against.
    const cases = [_]f64{ 0.1, 0.5, 1.0, 2.0, 10.0 };
    for (cases) |x| {
        const computed = std.math.tanh(x);
        const t = try answer(ext.tanh(Interval.init(x, x)));
        try std.testing.expect(t.lo < interval.prevDown(computed));
        try std.testing.expect(t.hi > interval.nextUp(computed));
    }
}

test "sin and cos: the endpoint evaluation widens two ULP, not one" {
    // These two do not go through the shared envelope, so the margin
    // they carry is pinned on its own here.
    const cases = [_]f64{ 0.1, 0.5, 1.0, 2.0, 10.0 };
    for (cases) |x| {
        const s = try answer(ext.sin(Interval.init(x, x)));
        const sine = @sin(x);
        try std.testing.expect(s.lo < interval.prevDown(sine));
        try std.testing.expect(s.hi > interval.nextUp(sine));

        const c = try answer(ext.cos(Interval.init(x, x)));
        const cosine = @cos(x);
        try std.testing.expect(c.lo < interval.prevDown(cosine));
        try std.testing.expect(c.hi > interval.nextUp(cosine));
    }
}

test "log: the one-sided bound widens two ULP, not one" {
    // The unbounded side of a logarithm is exact, and only the far end
    // is computed, so it takes the same two steps as everything else.
    // The logarithm of one is zero, and two steps up from zero are two
    // representable subnormals, so this pins the exact count.
    const l = try answer(ext.log(Interval.init(-1.0, 1.0)));
    try std.testing.expectEqual(-inf, l.lo);
    try std.testing.expectEqual(interval.nextUp(interval.nextUp(0.0)), l.hi);
}

test "floor: the ends go down, then outward" {
    // 1.5 and 2.5 both floor to their own integer.
    const f = try answer(ext.floor(Interval.init(1.5, 2.5)));
    try std.testing.expect(f.lo <= 1.0);
    try std.testing.expect(f.hi >= 2.0);
    // Widened rather than snapped onto the integers.
    try std.testing.expect(f.lo < 1.0);
    try std.testing.expect(f.hi > 2.0);
}

test "ceil: the ends go up, then outward" {
    const c = try answer(ext.ceil(Interval.init(1.5, 2.5)));
    try std.testing.expect(c.lo <= 2.0);
    try std.testing.expect(c.hi >= 3.0);
    try std.testing.expect(c.lo < 2.0);
    try std.testing.expect(c.hi > 3.0);
}

test "trunc: the ends go towards zero from either sign" {
    const t = try answer(ext.trunc(Interval.init(-1.5, 1.5)));
    try std.testing.expect(t.lo <= -1.0);
    try std.testing.expect(t.hi >= 1.0);
    try std.testing.expect(t.lo < -1.0);
    try std.testing.expect(t.hi > 1.0);
}

test "round: the halves of an interval reach both integers" {
    const r = try answer(ext.round(Interval.init(-0.5, 0.5)));
    // Half away from zero, not half to even, which would leave the
    // image at zero and put both bounds inside [-1, 1].
    try std.testing.expect(r.lo <= -1.0);
    try std.testing.expect(r.hi >= 1.0);
    try std.testing.expect(r.lo > -2.0);
    try std.testing.expect(r.hi < 2.0);
}

test "round: a lone positive half goes up, not to even" {
    const r = try answer(ext.round(Interval.init(0.5, 0.5)));
    try std.testing.expect(r.lo <= 1.0);
    try std.testing.expect(r.hi >= 1.0);
}

test "round: a lone negative half goes down, not to even" {
    const r = try answer(ext.round(Interval.init(-0.5, -0.5)));
    try std.testing.expect(r.lo <= -1.0);
    try std.testing.expect(r.hi >= -1.0);
}

test "cbrt: the ends sit inside the result, negative ones included" {
    const c = try answer(ext.cbrt(Interval.init(-8.0, 27.0)));
    try std.testing.expect(c.lo <= -2.0);
    try std.testing.expect(c.hi >= 3.0);
}

test "exp2: a degenerate interval encloses the one value" {
    const e = try answer(ext.exp2(Interval.init(1.0, 1.0)));
    try std.testing.expect(e.lo <= 2.0);
    try std.testing.expect(e.hi >= 2.0);
}

test "expm1: the ends sit inside the result near zero" {
    const e = try answer(ext.expm1(Interval.init(0.0, 1.0)));
    try std.testing.expect(e.lo <= 0.0);
    try std.testing.expect(e.hi >= 1.718281828459045);
}

test "log2: the ends sit inside the result" {
    const l = try answer(ext.log2(Interval.init(1.0, 8.0)));
    try std.testing.expect(l.lo <= 0.0);
    try std.testing.expect(l.hi >= 3.0);
}

test "log2: an interval without a positive part has no image" {
    try std.testing.expect(ext.log2(Interval.init(-2.0, 0.0)) == null);
}

test "log10: the ends sit inside the result" {
    const l = try answer(ext.log10(Interval.init(1.0, 100.0)));
    try std.testing.expect(l.lo <= 0.0);
    try std.testing.expect(l.hi >= 2.0);
}

test "log10: an interval without a positive part has no image" {
    try std.testing.expect(ext.log10(Interval.init(-2.0, 0.0)) == null);
}

test "log1p: the ends sit inside the result" {
    const l = try answer(ext.log1p(Interval.init(0.0, 1.0)));
    try std.testing.expect(l.lo <= 0.0);
    try std.testing.expect(l.hi >= 0.6931471805599453);
}

test "log1p: an argument reaching zero runs to minus infinity" {
    // 1 + x reaches zero at x = -1, where the value is not finite.
    const l = try answer(ext.log1p(Interval.init(-1.0, 0.0)));
    try std.testing.expectEqual(-inf, l.lo);
    try std.testing.expect(l.hi >= 0.0);
}

test "log1p: an argument below zero has no image" {
    try std.testing.expect(ext.log1p(Interval.init(-2.0, -1.5)) == null);
}

test "atan: the ends sit inside the result" {
    const a = try answer(ext.atan(Interval.init(0.0, 1.0)));
    try std.testing.expect(a.lo <= 0.0);
    try std.testing.expect(a.hi >= 0.7853981633974483);
}

test "asinh: the ends sit inside the result" {
    const a = try answer(ext.asinh(Interval.init(0.0, 1.0)));
    try std.testing.expect(a.lo <= 0.0);
    try std.testing.expect(a.hi >= 0.881373587019543);
}

test "sinh: rising over the whole line" {
    const s = try answer(ext.sinh(Interval.init(-1.0, 1.0)));
    try std.testing.expect(s.lo <= -1.1752011936438014);
    try std.testing.expect(s.hi >= 1.1752011936438014);
}

test "atan2: the first quadrant is the arc tangent of the quotient" {
    const a = try answer(ext.atan2(Interval.init(0.0, 1.0), Interval.init(1.0, 1.0)));
    try std.testing.expect(a.lo <= 0.0);
    try std.testing.expect(a.hi >= 0.7853981633974483);
}

test "atan2: the second quadrant is counted back from pi" {
    const a = try answer(ext.atan2(Interval.init(1.0, 1.0), Interval.init(-1.0, -1.0)));
    try std.testing.expect(a.lo <= 2.356194490192345);
    try std.testing.expect(a.hi >= 2.356194490192345);
    try std.testing.expect(a.hi <= 3.141592653589793);
}

test "atan2: the third quadrant is counted down from -pi" {
    const a = try answer(ext.atan2(Interval.init(-1.0, -1.0), Interval.init(-1.0, -1.0)));
    try std.testing.expect(a.lo <= -2.356194490192345);
    try std.testing.expect(a.hi >= -2.356194490192345);
    try std.testing.expect(a.lo >= -3.141592653589793);
}

test "atan2: a point on the vertical axis stays off the other side" {
    const up = try answer(ext.atan2(Interval.init(1.0, 1.0), Interval.init(0.0, 0.0)));
    try std.testing.expectEqual(@as(f64, 0.0), up.lo);
    try std.testing.expect(up.hi >= 3.141592653589793);

    const down = try answer(ext.atan2(Interval.init(-1.0, -1.0), Interval.init(0.0, 0.0)));
    try std.testing.expect(down.lo <= -3.141592653589793);
    try std.testing.expectEqual(@as(f64, 0.0), down.hi);
}

test "atan2: a point that can sit anywhere near the origin spans the range" {
    const a = try answer(ext.atan2(Interval.init(-1.0, 1.0), Interval.init(-1.0, 1.0)));
    try std.testing.expect(a.lo <= -3.141592653589793);
    try std.testing.expect(a.hi >= 3.141592653589793);
}

test "invariant: every function answers an interval that respects lo <= hi" {
    const wide = Interval.init(-1.0, 1.0);
    const any = Interval.init(-2.0, 2.0);
    const pos = Interval.init(0.25, 3.0);
    const neg = Interval.init(-3.0, -0.25);
    // The inverse hyperbolic tangent alone needs an input clear of the
    // ends of its open domain.
    const open = Interval.init(-0.5, 0.5);

    try check(ext.sqrt(pos));
    try check(ext.cbrt(any));
    try check(ext.pow(pos, 3));
    try check(ext.pow(pos, -2));
    try check(ext.powf(pos, Interval.init(0.5, 2.0)));
    try check(ext.exp(any));
    try check(ext.exp2(any));
    try check(ext.expm1(any));
    try check(ext.log(pos));
    try check(ext.log2(pos));
    try check(ext.log10(pos));
    try check(ext.log1p(neg));
    try check(ext.sin(any));
    try check(ext.cos(any));
    try check(ext.tan(Interval.init(0.0, 1.0)));
    try check(ext.asin(wide));
    try check(ext.acos(wide));
    try check(ext.atan(any));
    try check(ext.atan2(any, pos));
    try check(ext.sinh(any));
    try check(ext.cosh(any));
    try check(ext.tanh(any));
    try check(ext.asinh(any));
    try check(ext.acosh(pos));
    try check(ext.atanh(open));
    try check(ext.floor(any));
    try check(ext.ceil(any));
    try check(ext.trunc(any));
    try check(ext.round(any));
}

test "invariant: an unbounded answer is still an interval, not a null" {
    // The three ways a result leaves the finite range are all real
    // answers, and each has to come back as an interval.
    const pole = try answer(ext.tan(Interval.init(1.0, 2.0)));
    try std.testing.expectEqual(-inf, pole.lo);
    try std.testing.expectEqual(inf, pole.hi);

    const inverted = try answer(ext.pow(Interval.init(0.0, 1.0), -2));
    try std.testing.expectEqual(-inf, inverted.lo);
    try std.testing.expectEqual(inf, inverted.hi);

    const vanishing = try answer(ext.log(Interval.init(-1.0, 1.0)));
    try std.testing.expectEqual(-inf, vanishing.lo);
    // The far end is the logarithm of 1, which is zero, so only the
    // lower side of this answer runs off.
    try std.testing.expect(vanishing.hi > 0.0);
    try std.testing.expect(vanishing.hi <= interval.nextUp(interval.nextUp(0.0)));
}
