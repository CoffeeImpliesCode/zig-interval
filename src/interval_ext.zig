//! Elementary functions of an interval, each returning an enclosure of
//! the true result rather than a rounded copy of it.
//!
//! `interval.zig` holds the operations that min and max arithmetic
//! already carries out. Everything here needs monotonicity or domain
//! analysis to say where the result can lie, which is why it is a set
//! of free functions rather than methods on the interval.
//!
//! The rigour rule is that every endpoint which came out of an f64
//! computation is widened THREE ULP outward, with `rounding.roundDown` on
//! the lower side and `rounding.roundUp` on the upper side. Three rather
//! than one, and `lower` below carries the measurement that forced it.
//! The steps are the non-strict ones, which is what makes them bounds:
//! the strict pair asks for the neighbour of the argument where a bound
//! asks for the bound itself, and at a zero it steps past a bound the
//! argument already is. A computed zero is stepped past the pair of zeros
//! here, since a primitive whose true value is too small to hold answers
//! with a signed zero, and that zero is no bound of the real value
//! behind it. Values that were never rounded are used as they stand:
//! the exact numbers -1, 0 and 1, the infinities a pole produces, and
//! the certified bounds on pi. Widening those would buy no guarantee,
//! since there is no rounding error in them to absorb, and would cost
//! tightness on every call.
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
//! Every function here reads the canonical bounds of `Interval`, so the two
//! overflow rays arrive as the rays they are: an endpoint at `floatMax` or
//! at `-inf` is read as the half-line it stands for, and nothing in this
//! file re-derives, widens or re-asserts the conditions. What each one
//! does with a ray is its own business, decided by its own domain and its
//! own monotonicity, and the answer is not uniform across the file. A
//! function whose domain sits entirely above zero — `sqrt`, `log`, `log2`,
//! `log10`, `log1p`, `acosh` — is outside its domain over the whole of the
//! negative ray and answers `null` there, which is also what it does for
//! any argument below its domain. `cbrt` and `asinh` are defined on all of
//! the reals and are rising, so `envelope` carries them to an unbounded
//! endpoint of the matching sign: `[-inf, ...]` over the negative ray,
//! where the image runs down without a lower bound, and `[..., +inf]` over
//! the positive ray. An unbounded argument is not in itself a reason for
//! an infinite endpoint, and the functions that saturate are the
//! counterexamples: `tanh` answers either ray with a bounded range near 1,
//! `atan` with a bounded range below pi/2, and `sin` and `cos` with the
//! whole `[-1, 1]`, their `phaseResolvable` guard rejecting an argument
//! that large before any endpoint is read.
//!
//! `asin`, `acos` and `atanh` reject an argument that leaves their domain
//! rather than only one that leaves it entirely, so a `null` from those
//! three is not a claim that the image is empty in the reals. Nothing here
//! is clipped or widened to suit the rays, and no domain changes with them.
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
/// The value is the layout's, not this file's: `rounding` owns the ends of
/// the format, so the answer here is bound to the same bits as every other.
const inf = rounding.pos_inf;

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

/// Two subnormals, the width the zero case takes: one
/// `rounding.min_subnormal` to each side of the pair, kept as a single
/// value so the two sides cannot drift apart.
///
/// A computed zero is not always an exact zero. A primitive whose true
/// value is a number too small to hold answers with a signed zero, and a
/// bound stopping on that zero leaves the value out. A rounded zero
/// stands for a real of magnitude at most half the smallest positive
/// subnormal, so one subnormal on each side already covers it, and the
/// width is symmetric about zero because it is one value rather than
/// two steps that happen to agree.
const zero_slack: f64 = 2 * rounding.min_subnormal;

/// A lower bound on a computed value, widened three ULP outward, and the
/// place the step count of the whole file is written down and defended.
///
/// The steps are the non-strict ones, which is what makes this a bound
/// and not a neighbour. `rounding.prevDown` answers a different question,
/// the largest f64 strictly below its argument, and the two pairs agree
/// at both infinities and at every finite nonzero value, so the only
/// place the choice shows is the pair of signed zeros. There the
/// non-strict form hands the zero back unchanged: right for a zero that
/// is exact, wrong for one that is an underflow, which is what the
/// `zero_slack` case above settles.
///
/// The agreement at the ends of the range is what keeps the bound
/// holding. A computed +inf stands for a finite real above +floatMax, and
/// both forms answer +floatMax, which is below that real and below +inf
/// itself, so a lower bound of +floatMax keeps it where a lower bound of
/// +inf would drop it. -inf is below every real, so it is left as it
/// stands, by both forms alike.
///
/// Three steps, and the number is a measurement rather than a rule anyone
/// could have guessed. The `std.math` primitives every elementary
/// function here is built on are not among the operations IEEE 754
/// defines as correctly rounded and carry no documented error bound, so
/// the count has to clear the worst of what they actually do. Measured
/// against exact arithmetic in seventy decimal digits, the worst signed
/// error of each primitive this file calls, in ULPs of the true value,
/// with what is left of the margin under the three steps here:
///
///     tanh 2.14 -> 0.86    sinh 1.75 -> 1.25    log  1.50 -> 1.50
///     log10 1.37 -> 1.63   log2 1.22 -> 1.78    cosh 1.10 -> 1.90
///     exp  0.87 -> 2.13    tan  0.83 -> 2.17    log1p 0.78 -> 2.22
///     sin  0.77 -> 2.23    atan 0.76 -> 2.24    cos  0.74 -> 2.26
///     exp2 0.50 -> 2.50
///
/// `tanh` is the one that was wrong, and it is why the count is three and
/// not two. The file previously widened by two on the strength of a
/// sample of 300 arguments per function that put every primitive within
/// about 1.1 ULP, `tanh` the worst at 1.07. That figure was a guess
/// about the family, and a dense sweep over |x| <= 0.5 put `tanh` at
/// 2.14: not inside two steps. At x = 0.23139395412799124 the true value
/// is 0.227350673456281817160566003737 and `std.math.tanh` answers
/// 0.22735067345628188, two ULP and a seventh above it, so the widened
/// lower bound sat a seventh of a ULP above the real answer and cut it
/// out. That is a hole in the one guarantee this package makes, and no
/// oracle built out of `f64` can see it, because the nearest `f64` to
/// that true value IS the bound that was returned.
///
/// Provenance, because a table of samples that does not say which pass
/// produced each row is worth very little. The `tanh` and `cosh` rows were
/// re-measured for this change, over a dyadic grid and a linear sweep on
/// |x| <= 0.5 and |x| <= 3, and came back at 2.14 — the witness above is
/// the worst argument found — and 1.10. The `sinh` row was re-measured on
/// the same bands and came back at 1.45, below the 1.75 the earlier pass
/// reported; the table keeps 1.75, the higher of the two, because a margin
/// is only as good as the worst figure anyone holds for a primitive, and a
/// re-measurement that finds less is evidence that the earlier pass
/// sampled a worse case rather than that the primitive improved. Every
/// other row is the earlier pass unchallenged, and the argument bands that
/// pass used are not recorded in this file, which is itself a reason to
/// read the whole table as a sample and not as a bound.
///
/// A per-function step was the alternative and it is the wrong one. The
/// count is what makes the margin auditable — one number, one place, one
/// table to check a new primitive against — and a margin taken from a
/// sample has now been shown wrong about one member of the family, which
/// is exactly the state in which a second, narrower rule for `tanh`
/// alone would be least trustworthy. The extra step costs two ULPs of
/// width, 4.4e-16 relative on a value near one, and is paid on purpose:
/// a result one ULP too wide is merely loose, while one ULP too narrow is
/// silently wrong and nothing downstream can detect it.
///
/// None of that makes three a bound. These are samples of these
/// primitives over the argument bands named above, not worst cases over
/// the reals, and they do not cover every primitive here: `asin`, `acos`,
/// `acosh`, `atanh`, `cbrt`, `expm1` and `sqrt` are not in the table,
/// and `std.math.pow`, which `powf` no longer calls, measured 1.52 ULP
/// with an error proportional to the integer part of the exponent and so
/// growing without limit there. Establishing the bound would take a
/// correctly rounded or formally verified implementation of every
/// elementary function, which this library neither provides nor claims
/// to. `rounding.zig` still quotes the superseded 1.1 ULP figure of its
/// own and should be brought into line with this table.
fn lower(v: f64) f64 {
    if (v == 0.0) return -zero_slack;
    return rounding.roundDown(rounding.roundDown(rounding.roundDown(v)));
}

/// An upper bound on a computed value, three ULP outward for the reason
/// `lower` gives, and out past the pair of zeros for the same one.
fn upper(v: f64) f64 {
    if (v == 0.0) return zero_slack;
    return rounding.roundUp(rounding.roundUp(rounding.roundUp(v)));
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
/// primitive by three ULP, `mul` widens the correctly rounded product by
/// one, `exp` widens three and rises, and the image of a rising function
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
    // bounds in the function, so they carry the three-ULP widening that
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

/// The arc sine, rising over `[-1, 1]`.
///
/// **The argument is clipped to the domain rather than refused.** `null` is
/// therefore the answer exactly when the true image is empty in the reals,
/// which is when the whole interval lies outside `[-1, 1]` — so `null` here
/// means what the package prose says `null` means everywhere else. A partly
/// valid argument used to be refused as well, which was sound and lossy:
/// `asin([-4, 0.5])` has the true image `[-pi/2, asin(0.5)]` and answered
/// nothing at all. Clipping is what `sqrt`, `log*` and `acosh` already do
/// for a partial violation, and it costs the caller nothing.
///
/// The domain is closed, so a clipped end is the endpoint itself rather than
/// a pole: `asin(-1)` is a finite `-pi/2` and the bound is the usual three
/// ULP outward. Nothing here runs off to an infinity, and that is the whole
/// difference from `atanh`.
pub fn asin(x: Interval) ?Interval {
    const lo = @max(x.lo, -1.0);
    const hi = @min(x.hi, 1.0);
    // The clip is empty exactly when the argument misses the domain whole.
    if (lo > hi) return null;
    return envelope(std.math.asin(lo), std.math.asin(hi));
}

/// The arc cosine, falling where the arc sine rises, so `envelope` swaps
/// the two ends on its own.
///
/// **Clipped to `[-1, 1]` rather than refused**, on the same rule and for
/// the same reason `asin` gives: `acos([0.5, 4])` has the true image
/// `[0, acos(0.5)]` and used to answer nothing. `null` is the answer only
/// when the argument misses the domain whole.
pub fn acos(x: Interval) ?Interval {
    const lo = @max(x.lo, -1.0);
    const hi = @min(x.hi, 1.0);
    if (lo > hi) return null;
    return envelope(std.math.acos(lo), std.math.acos(hi));
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

/// The inverse hyperbolic tangent, rising over the OPEN interval
/// `(-1, 1)`.
///
/// **The argument is clipped to the domain rather than refused, and the pole
/// does what a pole does**: a clipped end sitting exactly on `±1` runs off to
/// the matching infinity. So `atanh([-2, -0.5])` answers `[-inf,
/// atanh(-0.5)]` where it used to answer nothing, and an argument spanning
/// the whole domain answers the whole line.
///
/// One shape stays `null` that a closed-domain clip would have accepted: an
/// argument whose only overlap with the domain is the endpoint `±1` itself,
/// such as `atanh([1, 2])`. Its true image really is empty, because `1` is
/// not in `(-1, 1)`, and answering `[floatMax, +inf]` for it would be a bound
/// of nothing wearing an interval's clothes. So the emptiness test is
/// two-sided — the clip must still reach a point strictly inside — and not
/// `lo <= hi`.
pub fn atanh(x: Interval) ?Interval {
    const lo = @max(x.lo, -1.0);
    const hi = @min(x.hi, 1.0);
    if (lo > hi) return null;
    // The domain is open, so a clip that reaches no further than the endpoint
    // from inside it overlaps nothing at all.
    if (hi <= -1.0 or lo >= 1.0) return null;
    // A clipped end ON the pole is the infinite one. std.math already
    // answers the matching infinity there; naming it keeps the pole out of
    // the arithmetic rather than leaning on that.
    const out_lo = if (lo <= -1.0) -inf else std.math.atanh(lo);
    const out_hi = if (hi >= 1.0) inf else std.math.atanh(hi);
    return envelope(out_lo, out_hi);
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
