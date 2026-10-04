//! The elementary functions, checked as enclosures.
//!
//! A transcendental value is not a number the test can write down, so
//! these assert that the result reaches past it rather than that it
//! equals it. Asserting equality against a rounded literal would pin
//! the width of the enclosure instead of its correctness. Only the
//! values that are exact in binary floating point, the integers and the
//! infinities, are compared for equality.
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
    // Two and three are the roots and both are exact in binary floating
    // point, so these two comparisons are the whole of what soundness asks
    // here: there is no rounding in the truth for a bound to be out of step
    // with.
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

test "asin: the argument is clipped to [-1, 1], and null only when it misses it whole" {
    // Misses the domain whole: the true image is empty, so `null`.
    try std.testing.expect(ext.asin(Interval.init(2.0, 4.0)) == null);
    try std.testing.expect(ext.asin(Interval.init(1.5, 4.0)) == null);

    // Straddling the low end. The clip replaces the FAR end with -1 and
    // leaves the near one where it was, so the answer is exactly the span
    // between the two point answers. Comparing those point enclosures is
    // this file's rule and not a convenience: a rounded literal here would
    // pin the width of the widening rather than the clipping, and a literal
    // argument to `std.math.asin` is folded at comptime, where it does not
    // exist.
    const far = try answer(ext.asin(Interval.init(-1.0, -1.0)));
    const near = try answer(ext.asin(Interval.init(0.5, 0.5)));
    const clipped = try answer(ext.asin(Interval.init(-4.0, 0.5)));
    try std.testing.expectEqual(far.lo, clipped.lo);
    try std.testing.expectEqual(near.hi, clipped.hi);
    // -pi/2 is exact in binary, so the far end is pinned against the literal
    // as well: the clip really did reach the domain boundary.
    try std.testing.expect(clipped.lo <= -1.5707963267948966);
}

test "acos: the angles of the ends sit inside the result, falling" {
    const a = try answer(ext.acos(Interval.init(0.0, 1.0)));
    // acos falls where asin rises: the far end of the interval is the
    // low one here, which is the case envelope has to get right.
    try std.testing.expect(a.lo <= 0.0);
    try std.testing.expect(a.hi >= 1.5707963267948966);
}

test "acos: the argument is clipped to [-1, 1], and null only when it misses it whole" {
    try std.testing.expect(ext.acos(Interval.init(2.0, 4.0)) == null);

    // Straddling the upper end, and acos FALLS, so the far end of the clip
    // is the LOW one. That crossing is what a clip can get wrong that a
    // refusal could not: there was no answer to cross before.
    const far = try answer(ext.acos(Interval.init(1.0, 1.0)));
    const near = try answer(ext.acos(Interval.init(0.5, 0.5)));
    const clipped = try answer(ext.acos(Interval.init(0.5, 4.0)));
    try std.testing.expectEqual(far.lo, clipped.lo);
    try std.testing.expectEqual(near.hi, clipped.hi);
    // acos(1) is exactly zero.
    try std.testing.expect(clipped.lo <= 0.0);
}

test "atanh: the angles of the ends sit inside the result" {
    const a = try answer(ext.atanh(Interval.init(0.0, 0.5)));
    try std.testing.expect(a.lo <= 0.0);
    try std.testing.expect(a.hi >= 0.5493061443340548);
}

test "atanh: the argument is clipped to (-1, 1) and the pole answers" {
    // Past the pole on one side, the clipped end IS the pole, so the answer
    // runs off to the matching infinity and the near end is untouched.
    const near = try answer(ext.atanh(Interval.init(-0.5, -0.5)));
    const clipped = try answer(ext.atanh(Interval.init(-2.0, -0.5)));
    try std.testing.expectEqual(-inf, clipped.lo);
    try std.testing.expectEqual(near.hi, clipped.hi);

    const near_pos = try answer(ext.atanh(Interval.init(0.5, 0.5)));
    const clipped_pos = try answer(ext.atanh(Interval.init(0.5, 2.0)));
    try std.testing.expectEqual(inf, clipped_pos.hi);
    try std.testing.expectEqual(near_pos.lo, clipped_pos.lo);

    // The whole open domain is the whole line: atanh rises out of both
    // poles, so nothing bounds either end.
    const all = try answer(ext.atanh(Interval.init(-2.0, 2.0)));
    try std.testing.expectEqual(-inf, all.lo);
    try std.testing.expectEqual(inf, all.hi);

    // An argument whose ONLY overlap with the domain is the endpoint itself
    // has an empty true image and stays null: 1 is not in (-1, 1), so
    // answering `[floatMax, +inf]` would be a bound of nothing wearing an
    // interval's clothes. This is the one shape where an OPEN domain answers
    // differently from a closed one, and it is why the emptiness test is
    // two-sided rather than `lo <= hi`.
    try std.testing.expect(ext.atanh(Interval.init(1.0, 2.0)) == null);
    try std.testing.expect(ext.atanh(Interval.init(-2.0, -1.0)) == null);
}

test "domain: clipping must not have merged null into an answer" {
    // `mapResult` folds a scalar `?Interval` over a box. Its null has always
    // meant "some component's TRUE IMAGE IS EMPTY", never "some component
    // reached a boundary", and clipping to the domain is exactly the change
    // that could have merged the two. Two components below would clip and
    // answer on their own; the third has no real image at all, so the fold
    // must still be null.
    const partly_outside = interval.Vec(3).fromArray(.{
        Interval.init(-4.0, 0.5),
        Interval.init(0.0, 0.5),
        Interval.init(2.0, 4.0),
    });
    try std.testing.expect(interval.mapResult(partly_outside, ext.asin) == null);

    // The same box with the third component in the domain answers, which is
    // what makes the null above about that third component and not about the
    // fold refusing to answer at all.
    const all_in_domain = interval.Vec(3).fromArray(.{
        Interval.init(-4.0, 0.5),
        Interval.init(0.0, 0.5),
        Interval.init(-1.0, 1.0),
    });
    try std.testing.expect(interval.mapResult(all_in_domain, ext.asin) != null);
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

test "pow: a box whose corners are exact powers of two" {
    // 0.5^5 = 2^-5 and 2^5 = 32, and both are EXACT in f64, so the true
    // image is [0.03125, 32] to the bit.
    //
    // Containment against an exact image is the whole of what soundness
    // asks here, and it is the direction that matters. A squaring that
    // narrowed the answer past the truth fails these two lines; a squaring
    // that widened it passes both, because widening is never a soundness
    // defect and pinning how far it widened would pin an implementation
    // rather than the mathematics.
    const p = try answer(ext.pow(Interval.init(0.5, 2.0), 5));
    try std.testing.expect(p.lo <= 0.03125);
    try std.testing.expect(p.hi >= 32.0);
}

test "pow: a straddling base under an even exponent still reaches the true image" {
    // `pow([-2, 3], 4)` is the other case this item names. The true image is
    // [0, 81]: an even power is never negative, x = 0 lies inside the base,
    // and max(2^4, 3^4) = 81.
    //
    // The answer is far LOOSER at the bottom than that, and the reason is
    // worth recording rather than papering over. `intPow` squares with
    // `base.mul(base)`, and interval multiplication has no symmetry to
    // exploit: [-2, 3] * [-2, 3] comes back [-6, 9] rather than [0, 9], and
    // that looseness compounds through the squarings. Sound, and loose - the
    // price of the O(log n) shape. Nothing here asserts a tight lower bound,
    // because a tight one is not what this function promises.
    const p = try answer(ext.pow(Interval.init(-2.0, 3.0), 4));
    try std.testing.expect(p.lo <= 0.0);
    try std.testing.expect(p.hi >= 81.0);
}

test "pow: a fractional base whose corners are not exact" {
    // One third is not representable, so the squarings genuinely round and
    // the accumulated rounding is all that stands between the answer and a
    // bound narrowed past the truth.
    //
    // The reference here is the rounded `f64` power, which is NOT a sound
    // reference in general, so this row claims only what that reference can
    // carry: the answer contains both rounded corner values. It says nothing
    // about how much wider the answer is than that, because the width is not
    // a property a consumer may rely on.
    const p = try answer(ext.pow(Interval.init(1.0 / 3.0, 2.0 / 3.0), 3));
    const lo = std.math.pow(f64, 1.0 / 3.0, 3.0);
    const hi = std.math.pow(f64, 2.0 / 3.0, 3.0);
    try std.testing.expect(p.lo <= lo);
    try std.testing.expect(p.hi >= hi);
}

test "powf: the corners of the box hold the extremes" {
    const p = try answer(ext.powf(Interval.init(2.0, 3.0), Interval.init(2.0, 3.0)));
    try std.testing.expect(p.lo <= 4.0);
    try std.testing.expect(p.hi >= 27.0);
}

test "powf: an exact integer exponent answers a wholly negative base" {
    // A real power of a negative number needs an exponent whose reduced
    // denominator is odd, and 2 = 2/1 is one of them: (-2)^2 = 4 and
    // (-1)^2 = 1, so the image of [-2, -1] under the exact exponent 2 is
    // [1, 4]. Refusing this is refusing a power that is a number.
    const even = try answer(ext.powf(Interval.init(-2.0, -1.0), Interval.init(2.0, 2.0)));
    try std.testing.expect(even.lo <= 1.0);
    try std.testing.expect(even.hi >= 4.0);

    // An ODD integer exponent keeps the sign, and that is the half of a
    // negative base an answer computed from the magnitude alone loses:
    // (-2)^3 = -8 and (-1)^3 = -1.
    const odd = try answer(ext.powf(Interval.init(-2.0, -1.0), Interval.init(3.0, 3.0)));
    try std.testing.expect(odd.lo <= -8.0);
    try std.testing.expect(odd.hi >= -1.0);

    // A negative integer exponent inverts that same signed image:
    // (-2)^-3 = -1/8 and (-1)^-3 = -1, so the image is [-1, -1/8] and
    // every value in it is negative.
    const down = try answer(ext.powf(Interval.init(-2.0, -1.0), Interval.init(-3.0, -3.0)));
    try std.testing.expect(down.lo <= -1.0);
    try std.testing.expect(down.hi >= -0.125);

    // The base -1 alone, which is the element whose power flips sign with
    // the numerator parity, and is therefore the sharpest witness that a
    // negative base was carried rather than replaced by its magnitude.
    const minus_one = try answer(ext.powf(Interval.init(-1.0, -1.0), Interval.init(3.0, 3.0)));
    try std.testing.expect(minus_one.lo <= -1.0);
    try std.testing.expect(minus_one.hi >= -1.0);
}

test "powf: an exact integer exponent past the i32 range still answers" {
    // The exponent is an interval rather than an integer type, so its
    // magnitude is bounded by no machine word. An even exponent past 1023
    // raises 2 past the largest f64, and an infinite upper bound is what
    // that forces: the value is unbounded, not absent.
    const even = try answer(ext.powf(Interval.init(-2.0, -2.0), Interval.init(3_000_000_000.0, 3_000_000_000.0)));
    try std.testing.expectEqual(inf, even.hi);

    // The odd partner carries the sign down to a magnitude below the
    // smallest subnormal, so zero is the only f64 that can sit where the
    // answer's bounds have to reach. What this row proves is that the pair
    // answers at all, with a negative base and an exponent no integer type
    // holds, rather than being refused.
    const odd = try answer(ext.powf(Interval.init(-2.0, -2.0), Interval.init(-3_000_000_001.0, -3_000_000_001.0)));
    try std.testing.expect(odd.lo <= 0.0);
    try std.testing.expect(odd.hi >= 0.0);
}

test "powf: an exact non-integer exponent has no real image of a negative base" {
    // 0.5 = 1/2, and one third is not a number an f64 holds: it is p/2^54 in
    // lowest terms, whose denominator is even. Neither admits an odd root,
    // so (-2)^(1/2) and (-2)^(1/3) are not real numbers and the honest
    // answer is `null` rather than an enclosure of nothing.
    //
    // That is the SINGLETON case, and it is decided by the exponent alone.
    // The whole exponent beside it answers, so a null here is about the
    // exponent rather than about negative bases being refused wholesale.
    try std.testing.expect(ext.powf(Interval.init(-2.0, -1.0), Interval.init(0.5, 0.5)) == null);
    try std.testing.expect(ext.powf(Interval.init(-2.0, -1.0), Interval.init(1.0 / 3.0, 1.0 / 3.0)) == null);
    try std.testing.expect(ext.powf(Interval.init(-2.0, -1.0), Interval.init(2.0, 2.0)) != null);

    // A box that only PARTLY reaches below the axis has an image anyway,
    // because its positive part is real under every exponent. The negative
    // corner contributes nothing and is dropped; what is left is the square
    // root of [0, 2], so the answer reaches zero at the base 0 and reaches
    // the square root of two at the base 2.
    const straddling = try answer(ext.powf(Interval.init(-2.0, 2.0), Interval.init(0.5, 0.5)));
    try std.testing.expect(straddling.lo <= 0.0);
    try std.testing.expect(straddling.hi >= 1.4142135623730951);
}

test "powf: a positive-width exponent answers a negative base with both signs" {
    // [0.5, 2] is full of exponents whose reduced denominator is odd - 1
    // and 5/3 carry odd numerators, 4/3 an even one - and the parity of the
    // numerator is what decides the sign of a power of a negative base. The
    // true image therefore has a positive part and a negative part, and an
    // answer on one side of zero only is missing half of it.
    const p = try answer(ext.powf(Interval.init(-2.0, -1.0), Interval.init(0.5, 2.0)));
    try std.testing.expect(p.lo < 0.0);
    try std.testing.expect(p.hi > 0.0);

    // The magnitudes run to 2^2 and no further: the odd-denominator
    // exponents approach 2 from below without reaching it, and the base
    // reaches 2, so the image approaches -4 and +4 from inside. A bound
    // strictly between zero and either of those cuts off values the image
    // really takes.
    try std.testing.expect(p.lo <= -4.0);
    try std.testing.expect(p.hi >= 4.0);

    // -1 and +1 are both attained exactly. The base -1 lies in the box, and
    // so do the exponents 1 and 5/3, which give -1, and 4/3, which gives +1.
    try std.testing.expect(p.contains(-1.0));
    try std.testing.expect(p.contains(1.0));
}

test "powf: base -1 under the exponents [1, 2] encloses both -1 and +1" {
    // The named case, on its own. 1 = 1/1 is an exponent in this interval
    // and gives (-1)^1 = -1; 4/3 is an exponent in it too and gives
    // (-1)^(4/3) = +1. An answer computed from the magnitude alone reports
    // [1, 1] and loses the -1.
    const p = try answer(ext.powf(Interval.init(-1.0, -1.0), Interval.init(1.0, 2.0)));
    try std.testing.expect(p.contains(-1.0));
    try std.testing.expect(p.contains(1.0));
}

test "powf: a base reaching zero under a non-positive exponent runs up" {
    // A base that reaches zero with an exponent that reaches down through
    // zero: the part of the image where a vanishing positive base carries a
    // negative exponent runs to +inf. Unbounded, and real.
    const p = try answer(ext.powf(Interval.init(0.0, 2.0), Interval.init(-1.0, 2.0)));
    try std.testing.expectEqual(@as(f64, 0.0), p.lo);
    try std.testing.expectEqual(inf, p.hi);

    // The same box with negative bases in it is unbounded BOTH ways, and
    // one-sidedness here is the defect. (-2)^-1 = -1/2 is in the image, and
    // as a negative base approaches zero the exponents -1/3 and -2/3 - odd
    // denominator, opposite numerator parity - send the image to -inf and to
    // +inf. Nothing finite bounds either end.
    const straddle = try answer(ext.powf(Interval.init(-2.0, 0.0), Interval.init(-1.0, 2.0)));
    try std.testing.expectEqual(-inf, straddle.lo);
    try std.testing.expectEqual(inf, straddle.hi);

    // The same argument with a whole exponent needs no limiting values at
    // all: 1/x over [-2, 2] takes -1/2 at x = -2 and 2 at x = 1/2, and the
    // two rays leaving zero run off at both ends.
    const recip = try answer(ext.powf(Interval.init(-2.0, 2.0), Interval.init(-1.0, -1.0)));
    try std.testing.expectEqual(-inf, recip.lo);
    try std.testing.expectEqual(inf, recip.hi);
}

test "powf: a base of exactly zero answers from the exponent alone" {
    const up = try answer(ext.powf(Interval.init(0.0, 0.0), Interval.init(1.0, 3.0)));
    try std.testing.expectEqual(@as(f64, 0.0), up.lo);
    try std.testing.expectEqual(@as(f64, 0.0), up.hi);

    // 0^0 is one and every exponent strictly above zero gives zero, so the
    // image of the base {0} under the exponents [0, 2] is the two values
    // {0, 1} and no more.
    const across = try answer(ext.powf(Interval.init(0.0, 0.0), Interval.init(0.0, 2.0)));
    try std.testing.expectEqual(@as(f64, 0.0), across.lo);
    try std.testing.expectEqual(@as(f64, 1.0), across.hi);
}

test "powf: the exact exponent zero is one for every base, negative ones included" {
    // x^0 is 1 for every real x and 0^0 is itself 1, so the image of ANY
    // base interval under the exact exponent 0 is the single value 1. The
    // negative bases are the ones a sign-carrying power has to keep here,
    // and the base that reaches zero is the one a power answering "zero or
    // one" from its exponent has to keep here.
    for ([_]Interval{
        Interval.init(2.0, 3.0),
        Interval.init(-2.0, -1.0),
        Interval.init(-2.0, 3.0),
        Interval.init(0.0, 0.0),
    }) |x| {
        const p = try answer(ext.powf(x, Interval.init(0.0, 0.0)));
        try std.testing.expectEqual(@as(f64, 1.0), p.lo);
        try std.testing.expectEqual(@as(f64, 1.0), p.hi);
    }
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

test "sin and cos: a box longer than a period reaches both ends of the range" {
    // Any real interval at least 2*pi long holds a whole period of sine and
    // of cosine, so the image of a box far wider than that contains every
    // critical value there is, and the answer has to reach -1 and +1.
    //
    // This is a fact about the LENGTH of the box rather than about how far
    // an argument reduces, so it holds at every magnitude and decides
    // nothing about where a critical-point search gives up.
    const sine = try answer(ext.sin(Interval.init(0.0, 1e300)));
    try std.testing.expect(sine.lo <= -1.0);
    try std.testing.expect(sine.hi >= 1.0);

    const cosine = try answer(ext.cos(Interval.init(-1e300, 1e300)));
    try std.testing.expect(cosine.lo <= -1.0);
    try std.testing.expect(cosine.hi >= 1.0);
}

test "tan: a box longer than pi holds a pole at every magnitude" {
    // The poles of tangent sit pi apart, so any box wider than that holds
    // one and the image is unbounded both ways, whatever the argument and
    // however far it reduces. Infinite bounds are forced here: no finite
    // pair of f64 holds an image that has no finite bounds.
    const wide = try answer(ext.tan(Interval.init(0.0, 1e300)));
    try std.testing.expectEqual(-inf, wide.lo);
    try std.testing.expectEqual(inf, wide.hi);

    const centred = try answer(ext.tan(Interval.init(-1e300, 1e300)));
    try std.testing.expectEqual(-inf, centred.lo);
    try std.testing.expectEqual(inf, centred.hi);
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
    // The band is the smallest statement that can be made without an oracle
    // finer than f64, and it is not a width pin: nothing here says how far
    // outside it the answer reaches, because that distance is a property of
    // an implementation's rounding rather than of the mathematics a
    // consumer may rely on. `tests/soundness_reference_test.zig` judges this
    // function against an f128 reference over a directed band, and that is
    // where a narrowing of the enclosure is actually caught.
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

test "log: the unbounded side is exact and the far end is an exact value" {
    // An interval whose near end reaches zero has no finite lower bound: the
    // logarithm of something approaching zero runs down without limit. That
    // end is exact rather than widened, because there is nothing to widen.
    //
    // The far ends named here are exact values, all of them integers an f64
    // holds: log(1) = 0, log2(8) = 3 and log10(100) = 2. Each is a bound
    // the answer has to reach, with no room between it and the truth.
    const one = try answer(ext.log(Interval.init(-1.0, 1.0)));
    try std.testing.expectEqual(-inf, one.lo);
    try std.testing.expect(one.hi >= 0.0);

    const two = try answer(ext.log2(Interval.init(0.0, 8.0)));
    try std.testing.expectEqual(-inf, two.lo);
    try std.testing.expect(two.hi >= 3.0);

    const ten = try answer(ext.log10(Interval.init(0.0, 100.0)));
    try std.testing.expectEqual(-inf, ten.lo);
    try std.testing.expect(ten.hi >= 2.0);

    // A degenerate 1 is exactly zero, and a zero result is its own bound:
    // the answer has to reach zero from below as well as from above.
    const zero = try answer(ext.log2(Interval.init(1.0, 1.0)));
    try std.testing.expect(zero.lo <= 0.0);
    try std.testing.expect(zero.hi >= 0.0);
}

test "floor: the image is the exact integers the interval reaches" {
    // The image of [1.5, 2.5] under floor is {1, 2}, and both are exact in
    // f64, so an answer that rounds away from those integers is reporting
    // bounds that are not the image. Two integers in, two out.
    const up = try answer(ext.floor(Interval.init(1.5, 2.5)));
    try std.testing.expectEqual(@as(f64, 1.0), up.lo);
    try std.testing.expectEqual(@as(f64, 2.0), up.hi);

    // Towards minus infinity, so the sign moves the integers and not merely
    // their magnitude: floor([-1.5, -0.5]) is {-2, -1}.
    const down = try answer(ext.floor(Interval.init(-1.5, -0.5)));
    try std.testing.expectEqual(@as(f64, -2.0), down.lo);
    try std.testing.expectEqual(@as(f64, -1.0), down.hi);

    // A box that already reaches an integer takes it, so the image can be a
    // single value: floor([1, 1.5]) is {1}.
    const reach = try answer(ext.floor(Interval.init(1.0, 1.5)));
    try std.testing.expectEqual(@as(f64, 1.0), reach.lo);
    try std.testing.expectEqual(@as(f64, 1.0), reach.hi);
}

test "ceil: the image is the exact integers the interval reaches" {
    const up = try answer(ext.ceil(Interval.init(1.5, 2.5)));
    try std.testing.expectEqual(@as(f64, 2.0), up.lo);
    try std.testing.expectEqual(@as(f64, 3.0), up.hi);

    const down = try answer(ext.ceil(Interval.init(-1.5, -0.5)));
    try std.testing.expectEqual(@as(f64, -1.0), down.lo);
    try std.testing.expectEqual(@as(f64, 0.0), down.hi);

    // The upper end reaching its own integer: ceil([-1.5, -1]) is {-1}.
    const reach = try answer(ext.ceil(Interval.init(-1.5, -1.0)));
    try std.testing.expectEqual(@as(f64, -1.0), reach.lo);
    try std.testing.expectEqual(@as(f64, -1.0), reach.hi);
}

test "trunc: the image is the exact integers, towards zero from either sign" {
    const both = try answer(ext.trunc(Interval.init(-1.5, 1.5)));
    try std.testing.expectEqual(@as(f64, -1.0), both.lo);
    try std.testing.expectEqual(@as(f64, 1.0), both.hi);

    // Towards zero on the negative side, which is where floor and ceil both
    // disagree with trunc in opposite directions: trunc([-1.5, -1]) is
    // {-1}, where floor would report {-2, -1}.
    const neg = try answer(ext.trunc(Interval.init(-1.5, -1.0)));
    try std.testing.expectEqual(@as(f64, -1.0), neg.lo);
    try std.testing.expectEqual(@as(f64, -1.0), neg.hi);

    // The positive side, where trunc and floor agree and the far end is the
    // one integer trunc drops.
    const pos = try answer(ext.trunc(Interval.init(0.5, 1.5)));
    try std.testing.expectEqual(@as(f64, 0.0), pos.lo);
    try std.testing.expectEqual(@as(f64, 1.0), pos.hi);
}

test "round: the halves of an interval reach both integers" {
    const r = try answer(ext.round(Interval.init(-0.5, 0.5)));
    // Half away from zero, not half to even: -0.5 rounds to -1 and 0.5 to
    // 1, so the image is {-1, 1} and those are the two bounds. Ties to even
    // would leave the image at {0} and this answer at [0, 0].
    try std.testing.expectEqual(@as(f64, -1.0), r.lo);
    try std.testing.expectEqual(@as(f64, 1.0), r.hi);
}

test "round: a lone half goes away from zero, on either sign" {
    const up = try answer(ext.round(Interval.init(0.5, 0.5)));
    try std.testing.expectEqual(@as(f64, 1.0), up.lo);
    try std.testing.expectEqual(@as(f64, 1.0), up.hi);

    const down = try answer(ext.round(Interval.init(-0.5, -0.5)));
    try std.testing.expectEqual(@as(f64, -1.0), down.lo);
    try std.testing.expectEqual(@as(f64, -1.0), down.hi);

    // The ties that rule out every other answer. Ties to even sends 2.5 to
    // 2 and -2.5 to -2; ties towards minus infinity sends 2.5 down as well.
    // Only away-from-zero reaches 3 and -3.
    const even = try answer(ext.round(Interval.init(2.5, 2.5)));
    try std.testing.expectEqual(@as(f64, 3.0), even.lo);
    try std.testing.expectEqual(@as(f64, 3.0), even.hi);

    const odd = try answer(ext.round(Interval.init(-2.5, -2.5)));
    try std.testing.expectEqual(@as(f64, -3.0), odd.lo);
    try std.testing.expectEqual(@as(f64, -3.0), odd.hi);
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

    // An argument whose phase index no machine word can hold is still an
    // argument a consumer may pass, and it has to come back as an ordered
    // interval rather than as a null or a pair of NaN bounds. `answer`
    // catches two of those three. Where a search gives up, and what it
    // answers with instead, is deliberately not asserted here.
    try check(ext.sin(Interval.init(1e300, 1e300)));
    try check(ext.cos(Interval.init(1e300, 1e300)));
    try check(ext.tan(Interval.init(1e300, 1e300)));
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

    // The far end is the logarithm of one, which is exactly zero, so only
    // the lower side of this answer runs off. Zero is in the image and is
    // its own bound, so the upper bound has to reach it.
    const vanishing = try answer(ext.log(Interval.init(-1.0, 1.0)));
    try std.testing.expectEqual(-inf, vanishing.lo);
    try std.testing.expect(vanishing.hi >= 0.0);
}
