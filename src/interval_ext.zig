//! Elementary functions of an interval, each returning an enclosure of
//! the true result rather than a rounded copy of it.
//!
//! `interval.zig` holds the operations that min and max arithmetic
//! already carries out. Everything here needs monotonicity or domain
//! analysis to say where the result can lie, which is why it is a set
//! of free functions rather than methods on the interval.
//!
//! The rigour rule is that every endpoint which came out of an f64
//! computation is widened two ULP outward, with `rounding.roundDown` on
//! the lower side and `rounding.roundUp` on the upper side. Two rather
//! than one, and `lower` below carries the measurement that forced it.
//! The steps are the non-strict ones, which is what makes them bounds:
//! the strict pair steps inward where a bound has to step outward, and
//! it answers a zero with a wider one, which a primitive that underflowed
//! to that zero does not deserve. So a computed zero steps past the pair
//! of zeros here as well, since a primitive whose true value is too
//! small to hold answers with a signed zero. Values that were never
//! rounded are used as they stand: the exact numbers -1, 0 and 1, the
//! infinities a pole produces, and the certified bounds on pi. Widening
//! those would buy no guarantee, since there is no rounding error in
//! them to absorb, and would cost tightness on every call.
//!
//! Two kinds of "no answer" are kept apart. `null` means the result is
//! empty in the reals, which happens only when the whole interval lies
//! outside the domain, as a square root of negative numbers or the
//! hyperbolics past their endpoints do. An `Interval` with an infinite
//! endpoint means the result is unbounded but real, as tangent is
//! across a pole, or a power with a negative exponent of a base
//! reaching zero. Collapsing the two would either throw away a real
//! answer or invent an empty one.
//!
//! The trigonometric functions read their range off the endpoints and
//! the critical points instead of reducing the argument, because the
//! critical values are exactly +/-1 and need no arithmetic of their
//! own, while a range reduction would have to be rigorous to the last
//! ULP of a multiple of pi.

const std = @import("std");
const Interval = @import("interval.zig").Interval;
const rounding = @import("rounding.zig");

/// The positive infinity, for the answers that are unbounded but real.
const inf = std.math.inf(f64);

/// True pi in f80, to more digits than the extra significand bits of
/// the type can hold, so that the quotient the critical-point search
/// divides out is accurate to about 1e-19 relative. At that accuracy
/// the search can tell a critical point from its neighbour out to the
/// magnitudes in `phase_limit` and no further.
const pi80: f80 = 3.14159265358979323846264338327950288;

/// Half of that, the offset of the sine and tangent critical points
/// from the origin. Halving is exact in binary floating point.
const half_pi80: f80 = pi80 / 2.0;

/// Beyond this magnitude the index of a critical point no longer fits
/// the i64 the search counts in, and the number of candidate points
/// would be beyond counting. The three trigonometric functions answer
/// there with the whole range each one spans, which is sound because
/// that range contains every value the function can take.
const phase_limit: f64 = 1e17;

/// The integers k with `offset + k * pi` inside [lo, hi], as an
/// inclusive range which is empty when `last` is below `first`.
const CriticalRange = struct {
    first: i64,
    last: i64,
};

/// The smallest positive subnormal f64, bit pattern 1. A computed zero
/// is not always an exact zero: a primitive whose true value is a number
/// too small to hold answers with a signed zero, and a bound stopping on
/// that zero leaves the value out. Two subnormals is the width the
/// strict pair gave at the zeros, so nothing that was an answer before
/// this repair changes.
const min_subnormal: f64 = @bitCast(@as(u64, 1));

/// Two subnormals, the width the zero case takes, kept as one value so
/// the two sides of the pair cannot drift apart.
const zero_slack: f64 = 2 * min_subnormal;

/// A lower bound on a computed value, widened two ULP outward, and the
/// place the reason the whole file widens by two rather than by one is
/// written down.
///
/// The steps are the non-strict ones, which is what makes this a bound
/// and not a neighbour. `rounding.prevDown` answers a different question,
/// the largest f64 strictly below its argument, and it answers -inf with
/// -floatMax. -floatMax is above -inf and above every real past the end
/// of the range, so a lower bound built from it stops short of the truth
/// and drops the value that overflowed into -inf along with every real
/// below -floatMax. `rounding.roundDown` is the largest f64 at or below
/// its argument, and steps outward at the ends of the range where that
/// one steps inward, which is the whole difference between the pairs
/// there.
///
/// They differ at the two zeros too, and there the non-strict form hands
/// the zero back unchanged: right for a zero that is exact, wrong for one
/// that is an underflow, which is what the `min_subnormal` case above
/// settles.
///
/// Two steps rather than one, because the `std.math` primitives the
/// elementary functions are built on are not among the operations IEEE
/// 754 defines as correctly rounded and carry no documented error
/// bound. Measured against exact arithmetic over 300 arguments per
/// function at magnitudes from 1e-8 to 1e8, the point primitives this
/// file calls landed within about 1.1 ULP, with `tanh` the worst at
/// 1.07: past what one step absorbs. That is a sample of those
/// primitives, not a bound on them, and it does not hold for all of
/// them: `std.math.pow` measured 1.52 ULP, and its error is proportional
/// to the integer part of the exponent and so grows without limit there,
/// which is why `powf` no longer goes through it. The extra ULP of width
/// is paid on purpose, since a result one ULP too wide is merely loose
/// while one ULP too narrow is silently wrong and nothing downstream can
/// detect it.
///
/// Two steps are still a margin taken from that measurement, not a proof
/// of it. Establishing the bound would take a correctly rounded or
/// formally verified implementation of every elementary function, which
/// this library neither provides nor claims to.
fn lower(v: f64) f64 {
    if (v == 0.0) return -zero_slack;
    return rounding.roundDown(rounding.roundDown(v));
}

/// An upper bound on a computed value, two ULP outward for the reason
/// `lower` gives, and out past the pair of zeros for the same one.
fn upper(v: f64) f64 {
    if (v == 0.0) return zero_slack;
    return rounding.roundUp(rounding.roundUp(v));
}

/// The pattern every monotone function here follows. The two values
/// are the function at the two ends of the interval; the smaller one
/// is the lower bound and the larger the upper one, which is why a
fn envelope(a: f64, b: f64) Interval {
    return Interval.init(lower(@min(a, b)), upper(@max(a, b)));
}

/// The lower quotient (x - offset) / pi, in f80 and biased below the
/// true value by more than the roundings above can move it. A critical
/// point belongs to [lo, hi] when an integer lies between the quotient
/// of the lower end and the quotient of the upper end, and pushing
/// either side outward only ever admits a point that is not there.
/// That is harmless: a critical point that is not there contributes a
/// +/-1 already in the range, and a pole that is not there reports an
/// unbounded tangent that still contains the finite one. Missing a
/// point that is there is the one failure that is not.
fn quotientLo(x: f64, offset: f80) f80 {
    const q = (@as(f80, x) - offset) / pi80;
    return q - @abs(q) * 1e-18 - 1e-30;
}

/// The upper quotient (x - offset) / pi, biased above the true value by
/// the same margin as `quotientLo` biases below it.
fn quotientHi(x: f64, offset: f80) f80 {
    const q = (@as(f80, x) - offset) / pi80;
    return q + @abs(q) * 1e-18 + 1e-30;
}

/// The integers k with `offset + k * pi` inside [lo, hi]. The quotient
/// runs below one past the last integer once the interval reaches a
/// full period, so callers narrow the interval first.
fn criticalRange(lo: f64, hi: f64, offset: f80) CriticalRange {
    return .{
        .first = @intFromFloat(@ceil(quotientLo(lo, offset))),
        .last = @intFromFloat(@floor(quotientHi(hi, offset))),
    };
}

/// Whether the critical point index is computable for this argument at
/// all. It grows as the argument divided by pi, and past
/// `phase_limit` it has left the range the search can count over.
fn phaseResolvable(x: Interval) bool {
    return @abs(x.lo) <= phase_limit and @abs(x.hi) <= phase_limit;
}

/// The square root, or null when the whole interval is negative and so
/// has no square root at all. A negative part contributes nothing but
/// the bound at zero, which the clamp below supplies.
pub fn sqrt(x: Interval) ?Interval {
    if (x.hi < 0.0) return null;
    return envelope(@sqrt(@max(0.0, x.lo)), @sqrt(x.hi));
}

/// The cube root, which is defined and rising on all of the reals.
pub fn cbrt(x: Interval) Interval {
    return envelope(std.math.cbrt(x.lo), std.math.cbrt(x.hi));
}

/// The integer power, by exponentiation by squaring so that the error
/// of log n multiplications is what accumulates rather than the error
/// of n of them at once. A negative exponent inverts the positive one,
/// which a base reaching zero makes impossible in finite bounds.
pub fn pow(x: Interval, n: i32) Interval {
    if (n == 0) return Interval.init(1.0, 1.0);
    if (n < 0 and x.contains(0.0)) return Interval.init(-inf, inf);
    // Negation in i64, since the magnitude of the most negative i32 has
    // no positive counterpart to hold it.
    const magnitude: u32 = @intCast(if (n < 0) -@as(i64, n) else @as(i64, n));
    const positive = intPow(x, magnitude);
    if (n > 0) return positive;
    return Interval.init(1.0, 1.0).div(positive);
}

/// x raised to a non-negative exponent, one squaring per bit of it.
fn intPow(x: Interval, e: u32) Interval {
    var result = Interval.init(1.0, 1.0);
    var base = x;
    var n = e;
    while (n != 0) {
        if ((n & 1) == 1) result = result.mul(base);
        n >>= 1;
        // No last squaring: it would widen the interval by a rounding
        // error that no bit of the exponent ever reads.
        if (n != 0) base = base.mul(base);
    }
    return result;
}

/// The real power of an interval by an interval. A negative base has
/// no real power under a general exponent, so it is refused rather
/// than guessed at; the split of the real line into a positive and a
/// negative base is exactly the split between a real value and none.
///
/// A base that reaches zero is answered from the exponent alone. An
/// exponent interval that reaches down to zero gives `[0, +inf]`: one
/// part of the image is a base approaching zero raised to an exponent at
/// or below zero, and that part runs to +inf, which is unbounded but
/// real rather than empty. A base of exactly zero under an exponent
/// interval that stays above zero is `[0, 0]`, and gains the value 1
/// when the exponent interval reaches exactly zero, since 0^0 is 1.
/// Every other base goes through `powerCorner`, which evaluates it with
/// this file's own `log`, `mul` and `exp`.
pub fn powf(x: Interval, y: Interval) ?Interval {
    if (x.lo < 0.0) return null;
    // The one rule for a base that reaches zero, in one place, so the
    // paths through it cannot disagree: a base reaching zero under an
    // exponent interval reaching down to zero has an image running to
    // +inf. It says so about a base that is exactly zero, a base that
    // reaches zero and stops there, and a base straddling zero, which is
    // the answer `pow` gives a negative integer exponent of a base
    // containing zero. What triggers it is the exponent reaching down to
    // zero, not any particular value it passes, and the bound at zero
    // rather than -inf that comes back is the one the image really has,
    // since a positive base has a positive power. Answering an exactly
    // zero base under a negative exponent from the exponent alone used
    // to give [0, 1] here while the two neighbouring paths gave
    // [0, +inf], which let a vanishingly small positive base report a
    // larger range than a zero one.
    if (x.lo == 0.0 and y.lo < 0.0) return Interval.init(0.0, inf);
    if (x.lo == 0.0 and x.hi == 0.0) {
        // The base is exactly zero and no exponent is negative, so the
        // image is zero raised to a positive exponent, which is zero,
        // and possibly 0^0, which is one.
        if (y.lo == 0.0) return Interval.init(0.0, 1.0);
        return Interval.init(0.0, 0.0);
    }
    if (x.lo <= 0.0 and y.lo <= 0.0) {
        // The base reaches zero and the exponent reaches down to it, so
        // one part of the image is zero to a negative power.
        return Interval.init(0.0, inf);
    }
    // The power rises with the exponent at every base, and with the
    // base wherever the exponent is positive and falls with the base
    // wherever it is negative, so the two extreme base endpoints carry
    // the range. Each is raised to the whole of y rather than to a
    // corner of it, which is the same hull reached in one enclosure
    // instead of four. A base of negative zero goes in as positive
    // zero, since pow(-0.0, 0.5) is not a real number everywhere.
    return powerCorner(@abs(x.lo), y).hull(powerCorner(x.hi, y));
}

/// One base endpoint raised to a whole exponent interval, as the hull of
/// a rigorous `exp(y * log x)`.
///
/// The identity is the point. For a strictly positive base `x^y` is
/// `exp(y * log x)`, and each of the three operations is one of this
/// file's, so the rounding of all three is absorbed by the arithmetic
/// rather than by a margin. `std.math.pow` is no longer on this path at
/// all: it reached the integer part of the exponent by repeated
/// squaring, and each squaring doubles the relative error, so its error
/// grows with that integer part and no fixed relative margin can cover
/// it. 1.0000000001^1e8 came back as 1.01005016788679320 against a true
/// 1.0100501679193823, and the fixed 2^-38 this function used to apply
/// sat inside that gap rather than over it.
///
/// What the answer rests on instead is the premise the rest of the file
/// rests on, applied in series: `log` widens the rounding of its own
/// primitive by two ULP, `mul` widens the correctly rounded product by
/// one, `exp` widens two and rises, and the image of a rising function
/// over an enclosure is the enclosure of its two ends. So an enclosure
/// of `y * log x` encloses `x^y` for every y in the interval, and the
/// result is a hull of enclosures rather than four points read off a
/// primitive that has no bound of its own. Three elementary evaluations
/// where there used to be one is the right trade for a library whose
/// only claim is that a result can be trusted.
///
/// The cases the identity does not reach are exact. A base of zero is
/// zero under every exponent already settled as non-negative, and one
/// to any power is one, which also settles the one place the product
/// below is undefined, since the logarithm of one is exactly zero and
/// zero times an infinite exponent is the indeterminate form that would
/// carry a NaN into the hull.
fn powerCorner(base: f64, y: Interval) Interval {
    if (base == 1.0) return Interval.init(1.0, 1.0);
    if (base == 0.0) return Interval.init(0.0, 0.0);
    // A strictly positive base is never outside the domain of the
    // logarithm, so that null cannot be reached. The whole line stands
    // in for a trap, and it bounds anything the corner could hold, which
    // is what a release build without the assertion in `init` needs in
    // order to go on answering.
    const lg = log(Interval.init(base, base)) orelse return Interval.init(-inf, inf);
    return exp(lg.mul(y));
}

/// The exponential, rising over all of the reals.
pub fn exp(x: Interval) Interval {
    return envelope(@exp(x.lo), @exp(x.hi));
}

/// The exponential to base two, rising over all of the reals.
pub fn exp2(x: Interval) Interval {
    return envelope(@exp2(x.lo), @exp2(x.hi));
}

/// The exponential less one, which keeps its precision near zero and
/// is rising over all of the reals.
pub fn expm1(x: Interval) Interval {
    return envelope(std.math.expm1(x.lo), std.math.expm1(x.hi));
}

/// The natural logarithm, or null when the interval reaches no
/// positive number. A lower end at or below zero is not merely small:
/// the argument then runs arbitrarily close to zero, and the logarithm
/// of that is arbitrarily far down, which no finite bound would hold.
pub fn log(x: Interval) ?Interval {
    if (x.hi <= 0.0) return null;
    if (x.lo <= 0.0) return Interval.init(-inf, upper(@log(x.hi)));
    return envelope(@log(x.lo), @log(x.hi));
}

/// The logarithm to base two, or null outside the positive reals.
pub fn log2(x: Interval) ?Interval {
    if (x.hi <= 0.0) return null;
    if (x.lo <= 0.0) return Interval.init(-inf, upper(@log2(x.hi)));
    return envelope(@log2(x.lo), @log2(x.hi));
}

/// The logarithm to base ten, or null outside the positive reals.
pub fn log10(x: Interval) ?Interval {
    if (x.hi <= 0.0) return null;
    if (x.lo <= 0.0) return Interval.init(-inf, upper(@log10(x.hi)));
    return envelope(@log10(x.lo), @log10(x.hi));
}

/// One plus the interval, then its logarithm, which is why the domain
/// stops one below zero rather than at it. A lower end at or under -1
/// puts the argument at zero, where the value runs off to minus
/// infinity, and everything below is off the domain entirely.
pub fn log1p(x: Interval) ?Interval {
    if (x.hi <= -1.0) return null;
    if (x.lo <= -1.0) return Interval.init(-inf, upper(std.math.log1p(x.hi)));
    return envelope(std.math.log1p(x.lo), std.math.log1p(x.hi));
}

/// Sine over the interval. A full period reaches both ends of the
/// range, and a narrower one is read off its endpoints and the
/// critical points it covers, which stand at pi/2 + k*pi and are worth
/// +1 for even k and -1 for odd k.
pub fn sin(x: Interval) Interval {
    if (!phaseResolvable(x)) return Interval.init(-1.0, 1.0);
    if (x.width() >= 2.0 * rounding.piUp()) return Interval.init(-1.0, 1.0);
    // The endpoint of a narrower interval may be the low one or the
    // high one, so both are taken as both, and the two widened values
    // are hulled rather than crossed. These two are the only computed
    // bounds in the function, so they carry the two-ULP widening that
    // `lower` sets out, and the critical points below are exact.
    const a = @sin(x.lo);
    const b = @sin(x.hi);
    var lo = @min(lower(a), lower(b));
    var hi = @max(upper(a), upper(b));
    // At most two critical points lie in an interval this narrow, so
    // the range spans three integers at most.
    const k = criticalRange(x.lo, x.hi, half_pi80);
    var i = k.first;
    while (i <= k.last) : (i += 1) {
        const extreme: f64 = if (@rem(i, 2) == 0) 1.0 else -1.0;
        lo = @min(lo, extreme);
        hi = @max(hi, extreme);
    }
    return insideUnitRange(lo, hi);
}

/// Cosine over the interval, read off the endpoints and the critical
/// points at k*pi, worth +1 for even k and -1 for odd k. The argument
/// is never reduced.
pub fn cos(x: Interval) Interval {
    if (!phaseResolvable(x)) return Interval.init(-1.0, 1.0);
    if (x.width() >= 2.0 * rounding.piUp()) return Interval.init(-1.0, 1.0);
    // Widened as in `sin`: the endpoints are the only computed bounds
    // here, and the critical points are the exact numbers +/-1.
    const a = @cos(x.lo);
    const b = @cos(x.hi);
    var lo = @min(lower(a), lower(b));
    var hi = @max(upper(a), upper(b));
    const k = criticalRange(x.lo, x.hi, 0.0);
    var i = k.first;
    while (i <= k.last) : (i += 1) {
        const extreme: f64 = if (@rem(i, 2) == 0) 1.0 else -1.0;
        lo = @min(lo, extreme);
        hi = @max(hi, extreme);
    }
    return insideUnitRange(lo, hi);
}

/// The enclosure of the critical candidates of sine or cosine, cut to
/// the range both of them span. A superset of the true range cut to
/// [-1, 1] is still a superset, and this one is no longer than it was.
/// The fallback cannot be reached, since the candidates hold a real
/// value of the function and that value lies inside [-1, 1]; it is
/// there so that a release build without the assertion in `init` still
/// answers with a range that contains the result.
fn insideUnitRange(lo: f64, hi: f64) Interval {
    return Interval.init(lo, hi).intersect(Interval.init(-1.0, 1.0)) orelse Interval.init(-1.0, 1.0);
}

/// Tangent over the interval. A pole inside it makes the result
/// unbounded, which is a real answer rather than an empty one, and the
/// poles stand pi apart at pi/2 + k*pi, the same places where sine
/// turns. Without one the function is continuous and rising across
/// the whole interval, so the endpoints hold the range.
pub fn tan(x: Interval) Interval {
    if (!phaseResolvable(x)) return Interval.init(-inf, inf);
    if (x.width() >= 2.0 * rounding.piUp()) return Interval.init(-inf, inf);
    const k = criticalRange(x.lo, x.hi, half_pi80);
    if (k.first <= k.last) return Interval.init(-inf, inf);
    return envelope(@tan(x.lo), @tan(x.hi));
}

/// The arc sine, or null unless the interval lies inside [-1, 1],
/// where it is rising.
pub fn asin(x: Interval) ?Interval {
    if (x.lo < -1.0 or x.hi > 1.0) return null;
    return envelope(std.math.asin(x.lo), std.math.asin(x.hi));
}

/// The arc cosine, or null unless the interval lies inside [-1, 1].
/// It falls where the arc sine rises, and `envelope` swaps the two ends
/// on its own.
pub fn acos(x: Interval) ?Interval {
    if (x.lo < -1.0 or x.hi > 1.0) return null;
    return envelope(std.math.acos(x.lo), std.math.acos(x.hi));
}

/// The arc tangent, rising over all of the reals.
pub fn atan(x: Interval) Interval {
    return envelope(std.math.atan(x.lo), std.math.atan(x.hi));
}

/// The angle from the positive x axis to the point (x, y). The
/// quadrants are settled before any division, so that a zero in x
/// lands in a case of its own instead of turning the quotient into
/// something undefined. What is left divides by an interval away from
/// zero and rises with the quotient, which `atan` then carries out.
pub fn atan2(y: Interval, x: Interval) Interval {
    if (x.hi < 0.0) {
        if (y.contains(0.0)) {
            // The point swings across the negative x axis, where the
            // angle jumps from -pi to pi, so the range is the whole.
            return Interval.init(-rounding.piUp(), rounding.piUp());
        }
        // Reflection into the first quadrant, where the angle runs from
        // pi/2 to pi or from -pi down to -pi/2. Negating both ends
        // exactly, rather than going through `abs`, keeps the reflected
        // interval clear of zero even at the smallest magnitudes.
        const r = atan(y.div(Interval.init(-x.hi, -x.lo)));
        if (y.lo > 0.0) return piInterval().sub(r);
        return Interval.init(-rounding.piUp(), -rounding.piDown()).sub(r);
    }
    if (x.lo > 0.0) return atan(y.div(x));
    // The point swings across the positive x axis on one side of the
    // origin, and the angles it passes reach the axes without crossing
    // them.
    if (y.contains(0.0)) return Interval.init(-rounding.piUp(), rounding.piUp());
    if (y.lo > 0.0) return Interval.init(0.0, rounding.piUp());
    return Interval.init(-rounding.piUp(), 0.0);
}

/// pi as an interval, between the two certified bounds. The nearest
/// double is below the true pi, so a bare f64 pi would cut the last
/// ULP off every angle reflected against it.
fn piInterval() Interval {
    return Interval.init(rounding.piDown(), rounding.piUp());
}

/// The hyperbolic sine, rising over all of the reals.
pub fn sinh(x: Interval) Interval {
    return envelope(std.math.sinh(x.lo), std.math.sinh(x.hi));
}

/// The hyperbolic cosine, which is even and rising in the magnitude, so
/// the magnitude of the interval is what it is applied to. That turns
/// the rise of the function into a plain monotone pattern.
pub fn cosh(x: Interval) Interval {
    return envelope(std.math.cosh(x.abs().lo), std.math.cosh(x.abs().hi));
}

/// The hyperbolic tangent, rising over all of the reals.
pub fn tanh(x: Interval) Interval {
    return envelope(std.math.tanh(x.lo), std.math.tanh(x.hi));
}

/// The inverse hyperbolic sine, rising over all of the reals.
pub fn asinh(x: Interval) Interval {
    return envelope(std.math.asinh(x.lo), std.math.asinh(x.hi));
}

/// The inverse hyperbolic cosine, or null unless the interval reaches
/// one. What lies below is not on the domain at all, and the function
/// takes the value zero exactly at the end of it.
pub fn acosh(x: Interval) ?Interval {
    if (x.hi < 1.0) return null;
    return envelope(std.math.acosh(@max(1.0, x.lo)), std.math.acosh(x.hi));
}

/// The inverse hyperbolic tangent, or null unless the interval lies
/// strictly inside (-1, 1). The domain is open there, and the ends
/// are not a limit the function reaches.
pub fn atanh(x: Interval) ?Interval {
    if (x.lo <= -1.0 or x.hi >= 1.0) return null;
    return envelope(std.math.atanh(x.lo), std.math.atanh(x.hi));
}

/// The largest integer not above each end. These four land on exact
/// values, but the result is widened anyway, so that every function in
/// this file answers under the one rule rather than four exceptions to
/// it.
pub fn floor(x: Interval) Interval {
    return envelope(@floor(x.lo), @floor(x.hi));
}

/// The smallest integer not below each end.
pub fn ceil(x: Interval) Interval {
    return envelope(@ceil(x.lo), @ceil(x.hi));
}

/// Each end cut towards zero.
pub fn trunc(x: Interval) Interval {
    return envelope(@trunc(x.lo), @trunc(x.hi));
}

/// Each end rounded to the nearest integer, with a tie going away
/// from zero as `@round` does.
pub fn round(x: Interval) Interval {
    return envelope(@round(x.lo), @round(x.hi));
}
