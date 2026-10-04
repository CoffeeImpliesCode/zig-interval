//! The real Gamma function, and the DISCRETE factorial.
//!
//! Two operators with two different domains, which is why they are two
//! functions and not one function with two names: `gamma` answers for every
//! real argument except the poles 0, -1, -2, ..., and `factorial` answers only
//! for the nonnegative integers. `2.5` is a perfectly good argument for the
//! first and not an argument for the second, so an operator that answered for
//! both would have to lie about one of them.
//!
//! `gamma` answers `null` exactly when the true image of its argument is
//! empty, which happens exactly when the whole interval IS a single pole: an
//! interval that merely CONTAINS a pole is partly inside the domain, so it is
//! answered with an enclosure of the defined part rather than with a refusal.
//! That distinction is the whole content of the domain handling, and it is
//! carried here rather than left to a caller.
//!
//! **How the enclosures are certified.** Every number below is computed in
//! outward-rounded `f128` interval arithmetic through `certified.Bounds`, whose
//! primitive operations already cover their own rounding, so nothing here
//! needs an empirical ULP budget. On top of that rounding, each analytic step
//! carries an explicit remainder bound, and the three mathematical facts the
//! program depends on are proved at the point of use rather than assumed:
//!
//!   * LOG-CONVEXITY, used for the maximum over a positive interval:
//!     `log Gamma` is convex on `(0, inf)` by Hölder's inequality applied to
//!     Euler's integral `Gamma(x) = int_0^inf t^(x-1) e^(-t) dt`. A convex
//!     function takes its maximum over an interval at an end, so
//!     `max Gamma over [a, b] = max(Gamma(a), Gamma(b))`. That is the whole
//!     reason a positive interval's top is pinned by its endpoints and needs
//!     no search for a critical point.
//!   * WHERE THE MINIMUM IS and WHICH SIDE IS MONOTONE, both from that same
//!     convexity. `Gamma(1) = Gamma(2) = 1` and `Gamma(3) = 2` give
//!     `Gamma <= 1` on `[1, 2]` and `< 1` strictly inside it, a convex
//!     function being below the chord between its ends; and `Gamma(x) > 1`
//!     off that interval, since for `x` in `(0, 1)` convexity at the
//!     midpoint `1` of `x` and `2 - x` gives `Gamma(x) Gamma(2-x) >= 1`
//!     while `Gamma(2-x) < 1`. A convex `f = log Gamma` has nondecreasing
//!     `f'`, so `f' <= 0` on `(0, 1]` and `f' >= 0` on `[2, inf)`: `Gamma`
//!     is strictly decreasing on the first and strictly increasing on the
//!     second, with its unique minimiser strictly inside `(1, 2)`. Where
//!     the minimiser cannot be excluded from an interval, the answer falls
//!     back on a proved coarse bound rather than on an endpoint's value.
//!   * THE COARSE BOUND `Gamma(x) > 1/4` for every `x > 0`, proved in
//!     `positiveCoarseLower` below from Euler's integral and `2 < e < 4`. It
//!     is used only where an interval may contain the minimum, never for a
//!     singleton argument, where the answer is the value itself.
//!
//! **The three routes a value takes.** A positive `x` is lifted to `z >= 32`
//! by the recurrence `Gamma(x) = Gamma(x+m) / prod(x+i)`, taken in logarithms,
//! and evaluated by Stirling's series with the remainder bound of DLMF
//! 5.11(ii) written out at the kernel; a negative `x` inside a pole-free gap
//! is reflected with `cert.sin(cert.pi * (x - floor x))`, where subtracting
//! the cell is what puts the sine's argument inside `[0, 1]` instead of at
//! `-300`, and where the sign of the answer is read off the cell rather than
//! off a transcendental that may have widened past its own sign; and a
//! factorial index is a product of integers multiplied outward in `f128`.
//! Nothing in the file calls a point-evaluated transcendental and pads it.

const std = @import("std");
const interval_mod = @import("interval.zig");
const cert = @import("certified.zig");

const Interval = interval_mod.Interval;
const Bounds = cert.Bounds;

/// Positive infinity in the working type. The kernels below produce it as a
/// bound and never as a value, so it is read here and not computed.
const inf: f128 = std.math.inf(f128);

/// Positive infinity in `f64`, the format the answer is in. It is used as a
/// signed pair because `Interval.init` reads a computed `+inf` low end as "a
/// real that overflowed ABOVE the format" and lowers it to `floatMax`, which
/// is not what the whole line is: `init(-inf, +inf)` is left alone at both
/// ends and is the one form that means all of R.
const f64_inf: f64 = std.math.inf(f64);

/// `floatMax(f64)` and `floatTrueMin(f64)` are powers of two, so these
/// conversions are exact and the two constants are the values themselves.
const f64_float_max: f128 = @as(f128, std.math.floatMax(f64));
const f64_float_true_min: f128 = @as(f128, std.math.floatTrueMin(f64));

const one: Bounds = Bounds.point(1.0);
const two: Bounds = Bounds.point(2.0);

// ---------------------------------------------------------------------------
// gamma
// ---------------------------------------------------------------------------

/// The real Gamma function on `[lo, hi]`, or `null` when the image is empty.
///
/// The image is empty exactly when `[lo, hi]` is a single pole, because the
/// poles are isolated: any interval of positive width holds a non-integer, and
/// `Gamma` is finite there. An interval that contains a pole strictly inside
/// it is answered with the whole line, which is forced rather than lazy: on
/// each side of a pole `Gamma` runs off in both directions and the two sides
/// have opposite signs, so the image of such an interval is all of R and no
/// pair of finite endpoints holds it.
pub fn gamma(x: Interval) ?Interval {
    if (x.lo == x.hi and isPole(x.lo)) return null;
    if (hasInteriorPole(x)) return Interval.init(-f64_inf, f64_inf);

    const open_lo = isPole(x.lo);
    const image = if (x.lo >= 0.0)
        gammaPositive(x.lo, x.hi, open_lo)
    else
        gammaNegative(x.lo, x.hi, open_lo, isPole(x.hi));

    return Bounds.project(image);
}

/// True when `x` is a pole of `Gamma`, that is a nonpositive integer.
///
/// The signed zero is zero, so `gamma(Interval.init(-0.0, -0.0))` is refused
/// exactly as `gamma(Interval.init(0.0, 0.0))` is: an implementation that
/// compared bit patterns instead of values would answer a real number at
/// zero, and that number would be about `1/0`.
fn isPole(x: f64) bool {
    if (!std.math.isFinite(x)) return false;
    if (x > 0.0) return false;
    return @floor(x) == x;
}

/// The greatest pole strictly below `x_hi`.
///
/// Poles are the nonpositive integers, so for `x_hi > 0` the answer is 0 and
/// otherwise it is the integer just below `x_hi`. `x_hi` is never `-inf`: an
/// `Interval` built through `init` has already replaced a `-inf` end with
/// `-floatMax`, and an interval whose two ends are both `-inf` cannot be
/// built. `+inf` is allowed and gives 0, which is a pole of nothing in
/// particular but is the greatest nonpositive integer all the same.
fn poleBelow(x_hi: f64) ?f64 {
    std.debug.assert(x_hi != -f64_inf);
    if (x_hi > 0.0) return 0.0;
    const fl = @floor(x_hi);
    return if (fl == x_hi) fl - 1.0 else fl;
}

/// True when a pole lies strictly inside the interval.
///
/// Only then does the image run to both infinities. An interval that touches
/// a pole at one of its ENDS has a pole in its closure and not in its
/// interior, and its image is a single ray or a single half-line, which is a
/// different answer and the reason this is a strict comparison.
fn hasInteriorPole(x: Interval) bool {
    const p = poleBelow(x.hi) orelse return false;
    return p > x.lo;
}

/// The image of `Gamma` over the pole-free part of `[lo, hi]` where that part
/// is positive.
///
/// `open_lo` says the part is `(lo, ...]` with `lo` a pole, which can only be
/// the pole at zero: the value runs off to `+inf` there, and the answer is
/// unbounded above whatever the rest of the part says.
fn gammaPositive(lo: f64, hi: f64, open_lo: bool) Bounds {
    if (!open_lo and !std.math.isInf(hi)) {
        const at_lo = gammaPosAt(@as(f128, lo));
        // A singleton argument has no interval to bound: its image is the
        // value, and this is also why the coarse lower bound below never
        // reaches a point the caller asked a question about.
        if (lo == hi) return at_lo;
        const at_hi = gammaPosAt(@as(f128, hi));

        // The maximum is at an end by log-convexity, and the minimum is at an
        // end too unless the interval may contain the unique minimiser, which
        // sits strictly inside (1, 2).
        const upper = @max(at_lo.hi, at_hi.hi);
        const lower = if (lo >= 2.0)
            at_lo.lo // increasing on [2, inf)
        else if (hi <= 1.0)
            at_hi.lo // decreasing on (0, 1]
        else
            positiveCoarseLower();

        return Bounds.init(lower, upper);
    }

    // One end runs off to +inf, so only the bottom is left to pin.
    const lower = if (lo >= 2.0)
        gammaPosAt(@as(f128, lo)).lo
    else if (hi <= 1.0)
        gammaPosAt(@as(f128, hi)).lo
    else
        positiveCoarseLower();

    return Bounds.init(lower, inf);
}

/// `1/4`, a proved lower bound for `Gamma` on `(0, inf)`.
///
/// The proof is Euler's integral, and it is an integral rather than a
/// measurement. For `x >= 1`, `t^(x-1) >= 1` on `[1, inf)`, so
/// `Gamma(x) >= int_1^inf e^(-t) dt = 1/e`. For `0 < x <= 1`,
/// `t^(x-1) >= 1` on `(0, 1]`, so `Gamma(x) >= int_0^1 e^(-t) dt = 1 - 1/e`.
/// Since `2 < e < 4`, both `1/e` and `1 - 1/e` exceed `1/4`, so
/// `Gamma(x) > 1/4` for every `x > 0`.
///
/// The strictness matters only in that `1/4` is itself an exact `f128`, so it
/// is a valid lower bound without any rounding. It is deliberately coarse: it
/// is the price of not locating a minimiser, and it is spent only where the
/// minimiser cannot be excluded.
fn positiveCoarseLower() f128 {
    return 0.25;
}

/// `Gamma(z)` at a positive point, in `f128`.
fn gammaPosAt(z: f128) Bounds {
    std.debug.assert(z > 0.0);
    return expPositive(logGammaPosPoint(z));
}

/// The image of `Gamma` over the pole-free part of `[lo, hi]` where that part
/// is negative.
///
/// `lo < 0 <= hi`, and the only integers in the closure of the part are its
/// own ends. `open_lo` and `open_hi` say which of those ends is a pole the
/// part therefore does not contain; an open end is a limit, and every bound
/// below that touches it is taken at the limit rather than at the end.
///
/// Everything here is reflection, and the sign is not recovered from a sine
/// evaluation but read off the cell, which is the point: on a pole-free gap
/// `sin(pi x)` never changes sign. Subtracting the cell is what puts the
/// sine's argument inside `[0, 1]` instead of at `-300`, and it is done as an
/// outward interval subtraction because it is NOT exact in general: the
/// difference is exact for `|x| >= 1/2` by Sterbenz and for `x >= 0`, but for
/// `-1/2 < x < 0` the residual lands near one and the addition rounds. The
/// enclosure carries that rounding; nothing below reads the residual as an
/// exact value of the difference.
fn gammaNegative(lo: f64, hi: f64, open_lo: bool, open_hi: bool) Bounds {
    std.debug.assert(lo < 0.0);
    const span = Bounds.fromInterval(Interval.init(lo, hi));

    // The cell label. An integer strictly inside the part would be a pole,
    // and `gamma` has already answered with the whole line in that case, so
    // `floor` is constant over the part and one subtraction suffices.
    const cell = @floor(lo);

    var residual = Bounds.sub(span, Bounds.point(cell));
    // The exact residual is in `[0, 1]` because the part runs from the cell to
    // the next pole at most. Clamping rather than asserting is the honest
    // form of that: an outward subtraction can round a residual that is
    // exactly zero down by an ulp, and every statement below is about the
    // closed interval `[0, 1]`, so a stray ulp outside it is absorbed here
    // instead of being a claim this file would rather not make about another
    // module's rounding. `hi <= cell + 1` for the reason above, with equality
    // only when `hi` is the pole at zero and the part is open there; the end
    // the clamp admits is not read as a value of the sine, because `open_hi`
    // says it is a limit rather than a point.
    if (residual.lo < 0.0) residual.lo = 0.0;
    if (residual.hi > 1.0) residual.hi = 1.0;

    // |sin(pi x)| = sin(pi (x - cell)) because the shifted argument is in
    // `[0, 1]` and the sign lives in `(-1)^cell`. On `[0, 1]` the sine rises
    // and falls exactly once, at one half, which says where both of its
    // extremes over the residual are: the MINIMUM is always at an end, and
    // the MAXIMUM is at an end unless the half lies inside the residual, in
    // which case the maximum is the peak itself, which is 1 exactly. Both
    // cases are statements about the sine on `[0, 1]` rather than readings of
    // an evaluation, and both ends are evaluated as points so that a part
    // narrower than a half period keeps the precision that costs it nothing.
    const sine_low = cert.sin(Bounds.mul(cert.pi, Bounds.point(residual.lo)));
    const sine_high = cert.sin(Bounds.mul(cert.pi, Bounds.point(residual.hi)));
    // An end that is an OPEN pole runs the sine down to zero, and zero is in
    // the closed hull of the image even though the part never attains it. The
    // sine of the closed hull's own end is NOT that zero -- sin of pi is not
    // zero -- so an open end has to be recognised here rather than read off
    // the evaluation. That recognition is also what makes the magnitude
    // unbounded at that end.
    const sine_min = if (open_lo or open_hi)
        0.0
    else
        @max(0.0, @min(sine_low.lo, sine_high.lo));
    var sine_max = @max(0.0, @max(sine_low.hi, sine_high.hi));
    if (residual.lo <= 0.5 and 0.5 <= residual.hi) sine_max = 1.0;
    // `|sin| <= 1` always, and is the only bound left if both certified ends
    // have widened past their own values.
    if (sine_max <= 0.0) sine_max = 1.0;
    const log_sine = Bounds.init(
        if (sine_min > 0.0) cert.log(Bounds.point(sine_min)).lo else -inf,
        cert.log(Bounds.point(sine_max)).hi,
    );

    // `Gamma(x) = pi / (sin(pi x) Gamma(1 - x))`, and `Gamma(1 - x)` is
    // positive because `1 - x >= 1`. The extremes of the logarithm are formed
    // by pairing the smallest logarithm of each factor with the largest of the
    // others; the sine's own lower logarithm is `-inf` when the part runs up
    // to a pole, which is what makes the magnitude unbounded there.
    const log_pi = cert.log(cert.pi);
    const log_gamma_u = logGammaPos(Bounds.sub(one, span));
    const log_abs = Bounds.init(
        log_pi.lo - log_sine.hi - log_gamma_u.hi,
        log_pi.hi - log_sine.lo - log_gamma_u.lo,
    );

    const magnitude = expPositive(log_abs);
    // `sin(pi x)` is positive on `(2k, 2k+1)` and negative on `(2k-1, 2k)`,
    // and `Gamma(1-x)` is positive, so `(-1)^cell` IS the sign of `Gamma`.
    return if (@mod(cell, 2.0) == 0.0) magnitude else Bounds.neg(magnitude);
}

// ---------------------------------------------------------------------------
// log Gamma
// ---------------------------------------------------------------------------

/// `ln Gamma` over a positive interval, as an enclosure of the logarithm.
///
/// The maximum is at an end by log-convexity; the minimum is at an end
/// wherever monotonicity settles it, and is the proved coarse bound
/// `ln(1/4) = -2 ln 2` where the unique minimiser inside `(1, 2)` may sit.
/// A singleton argument is the value and nothing else.
fn logGammaPos(x: Bounds) Bounds {
    std.debug.assert(x.lo > 0.0);
    if (x.lo == x.hi) return logGammaPosPoint(x.lo);

    const at_lo = logGammaPosPoint(x.lo);
    const at_hi = logGammaPosPoint(x.hi);

    const upper = @max(at_lo.hi, at_hi.hi);
    const lower = if (x.lo >= 2.0)
        at_lo.lo // increasing on [2, inf)
    else if (x.hi <= 1.0)
        at_hi.lo // decreasing on (0, 1]
    else
        Bounds.neg(Bounds.mul(cert.ln2, two)).lo; // ln(1/4), rounded outward

    return Bounds.init(lower, upper);
}

/// `ln Gamma(z)` at a positive point, by the recurrence up to `z >= 32` and
/// Stirling's series there.
///
/// The recurrence is `Gamma(z) = Gamma(z + m) / prod_{i<m} (z + i)`, taken in
/// logarithms so that nothing has to be divided: `ln Gamma(z) = ln Gamma(z+m)
/// - sum_{i<m} ln(z + i)`. `z` is the `f128` the caller already holds rather
/// than a re-narrowed `f64`, and each `z + i` is an outward `f128` addition,
/// so the rounding of that addition is inside the answer instead of outside
/// it. It is not exact either: `z = 2^-1070` and `i = 1` want 1072 significand
/// bits and `f128` has 113, and the answer carries that rounding rather than
/// assuming it away.
fn logGammaPosPoint(z: f128) Bounds {
    std.debug.assert(z > 0.0);
    const steps = stirlingShift(z);

    const shifted = Bounds.add(Bounds.point(z), Bounds.point(@as(f128, @floatFromInt(steps))));
    var lg = stirling(shifted);
    var i: u64 = 0;
    while (i < steps) : (i += 1) {
        const factor = Bounds.add(Bounds.point(z), Bounds.point(@as(f128, @floatFromInt(i))));
        lg = Bounds.sub(lg, cert.log(factor));
    }
    return lg;
}

/// The number of recurrence steps that lift `z` to `z >= stirling_shift`.
///
/// Never negative and never more than 33, which is what makes the loop above
/// a bounded loop: for `z` in `(0, 1)` the shift is 33 and for `z >= 32` it is
/// nothing.
///
/// The ceiling is taken of the UPPER end of the interval `stirling_shift - z`
/// rather than of a rounded scalar difference, and then one more step is added
/// on top. Either alone would do. A scalar difference rounded down across an
/// integer can take a step too few and leave the shifted argument below 32;
/// the ceiling of the interval cannot, and the extra step then puts the
/// shifted argument at 33 or above however the addition itself rounds. The
/// cost is one logarithm and a slightly tighter series.
fn stirlingShift(z: f128) u64 {
    if (z >= stirling_shift) return 0;
    const gap = Bounds.sub(Bounds.point(stirling_shift), Bounds.point(z));
    const steps = @ceil(gap.hi) + 1.0;
    std.debug.assert(steps >= 2.0);
    std.debug.assert(steps <= 33.0);
    return @intFromFloat(steps);
}

/// The argument from which the Stirling series is used.
///
/// 32 is a margin, not a necessity. The first omitted term of the nine summed
/// below is `B_20 / (20 * 19 z^19)`, whose magnitude at `z = 32` is
/// `(174611 / 125400) * 2^-95 < 3.6e-29`, while the largest term that IS
/// summed is `B_18 / (18 * 17 * 32^17)`, about `4.7e-27`. The sum itself is of
/// order 78, where one `f128` unit in the last place is `2^-107 < 6.2e-33`, so
/// the truncation is some millions of units in the last place of the value
/// summed. Halving the shift to 16 would raise it to `1.9e-23`, still seven
/// orders below the `10^-16` relative an `f64` answer is read at, which is why
/// this is margin: the answer's `f64` accuracy is set by the final directed
/// projection and not by the series.
const stirling_shift: f128 = 32.0;

/// How many terms of Stirling's series for `ln Gamma` are summed.
///
/// The sum runs over `k = 1 .. stirling_terms`, and DLMF 5.11(ii) is the
/// theorem that licenses stopping there: "if the sums in the expansions are
/// terminated at `k = n-1` (`k >= 0`) and `z` is real and positive, then the
/// remainder terms are bounded in magnitude by the first neglected terms and
/// have the same sign." With `n = stirling_terms + 1` the first neglected term
/// is `k = stirling_terms + 1`, and that is the term whose sign the remainder
/// inherits and whose magnitude bounds it. This is the clause for a POSITIVE
/// REAL `z` specifically; the complex-`z` version multiplies it by a
/// `sec`ant factor and is not what is used here.
const stirling_terms: usize = 9;

/// `ln Gamma(z)` for an interval `z` with `z.lo >= stirling_shift`.
///
/// The expansion is DLMF 5.11.1:
///
///     ln Gamma(z) ~ (z - 1/2) ln z - z + 1/2 ln(2 pi)
///                  + sum_{k>=1} B_2k / (2k (2k-1) z^(2k-1))
///
/// The Bernoulli numbers are held as EXACT rationals and divided outward, so
/// no coefficient is ever a rounded `f64` or `f128` constant whose error would
/// have to be guessed at.
fn stirling(z: Bounds) Bounds {
    std.debug.assert(z.lo >= stirling_shift);

    var sum = Bounds.sub(
        Bounds.mul(Bounds.sub(z, Bounds.point(0.5)), cert.log(z)),
        z,
    );
    sum = Bounds.add(sum, Bounds.div(cert.log(Bounds.mul(two, cert.pi)), two));

    // `p` walks z^-1, z^-3, z^-5, ...: two multiplications per term, and the
    // powers stay positive throughout, which keeps the reciprocals tight where
    // an interval power of a whole interval would not be.
    const z_inverse = Bounds.div(one, z);
    const z_inverse_squared = Bounds.mul(z_inverse, z_inverse);
    var p = z_inverse;
    var k: usize = 1;
    while (k <= stirling_terms) : (k += 1) {
        sum = Bounds.add(sum, Bounds.div(bernoulliTerm(k), p));
        p = Bounds.mul(p, z_inverse_squared);
    }

    // The remainder, by DLMF 5.11(ii) for positive real z: it has the sign of
    // the first omitted term and no larger magnitude. The first omitted term
    // is `B_2n / (2n(2n-1) z^(2n-1))` at `n = stirling_terms + 1`, and `p`
    // is now exactly its `z^-(2n-1)` factor.
    const omitted = Bounds.div(bernoulliTerm(stirling_terms + 1), p);
    return Bounds.add(sum, Bounds.init(@min(0.0, omitted.lo), @max(0.0, omitted.hi)));
}

/// `B_2k / (2k(2k-1))`, the `k`-th coefficient of the Stirling series.
///
/// Exact integers in, an outward division out: `B_2k`'s numerator and
/// denominator and `2k(2k-1)` are all far below `2^113`, so the conversion to
/// `f128` introduces no error and the only rounding is the division's.
fn bernoulliTerm(k: usize) Bounds {
    std.debug.assert(k >= 1);
    std.debug.assert(k <= bernoulli.len);
    const pair = bernoulli[k - 1];
    const scale = @as(f128, @floatFromInt(2 * k)) * @as(f128, @floatFromInt(2 * k - 1));
    return Bounds.div(
        Bounds.div(
            Bounds.point(@as(f128, @floatFromInt(pair.numerator))),
            Bounds.point(@as(f128, @floatFromInt(pair.denominator))),
        ),
        Bounds.point(scale),
    );
}

/// The even Bernoulli numbers `B_2, B_4, ..., B_20`, exactly.
///
/// `stirling_terms + 1` of them are needed, because the remainder bound names
/// the first OMITTED term rather than the last summed one. The odd Bernoulli
/// numbers vanish, which is why the series has only even indices.
const bernoulli = [_]struct { numerator: i64, denominator: u64 }{
    .{ .numerator = 1, .denominator = 6 }, // B_2  = 1/6
    .{ .numerator = -1, .denominator = 30 }, // B_4  = -1/30
    .{ .numerator = 1, .denominator = 42 }, // B_6  = 1/42
    .{ .numerator = -1, .denominator = 30 }, // B_8  = -1/30
    .{ .numerator = 5, .denominator = 66 }, // B_10 = 5/66
    .{ .numerator = -691, .denominator = 2730 }, // B_12 = -691/2730
    .{ .numerator = 7, .denominator = 6 }, // B_14 = 7/6
    .{ .numerator = -3617, .denominator = 510 }, // B_16 = -3617/510
    .{ .numerator = 43867, .denominator = 798 }, // B_18 = 43867/798
    .{ .numerator = -174611, .denominator = 330 }, // B_20 = -174611/330
};

comptime {
    // The table is indexed by `k - 1` and must reach the first omitted term.
    std.debug.assert(bernoulli.len == stirling_terms + 1);
    // `B_2k` alternates in sign, which is what lets the remainder inherit a
    // sign from the omitted term instead of only a magnitude.
    for (bernoulli, 0..) |pair, index| {
        const expected_positive = index % 2 == 0;
        std.debug.assert((pair.numerator > 0) == expected_positive);
    }
}

// ---------------------------------------------------------------------------
// exponentiation of a logarithm
// ---------------------------------------------------------------------------

/// `exp(l)` for a logarithm `l` of a POSITIVE quantity, as an `f128` bracket.
///
/// The two branches are not padding and not a fallback: they are the only way
/// a value that has left the `f64` range can be enclosed in `f64` at all.
/// `exp` of a logarithm past the top of the range is above every `f64`, and
/// `floatMax(f64)` is a genuine lower bound for it; `exp` of a logarithm below
/// the bottom is below the smallest positive `f64`, and for a positive value
/// the smallest `f64` above zero is a genuine upper bound while zero is a
/// genuine lower bound. `[0, 0]` would hold no positive value at all, which is
/// the failure this pair of branches exists to prevent.
///
/// `+/-750` are chosen so that the proof is one inequality. `floatMax(f64)` is
/// below `2^1024` and the smallest positive `f64` is `2^-1074`, so it is
/// enough that `e^750 > 2^1024` and `e^-750 < 2^-1074`, i.e. that
/// `1024 ln 2 < 750` and `1074 ln 2 < 750`; and `ln 2 < 0.694` from
/// `ln 2 = 2(1/3 + 1/(3*3^3) + 1/(5*3^5) + ...)` with the alternating
/// remainder bounded by the first omitted term, since
/// `1024 * 0.694 = 710.7 < 750` and `1074 * 0.694 = 745.4 < 750`.
fn expPositive(l: Bounds) Bounds {
    if (l.lo > exp_log_top_bound) return Bounds.init(f64_float_max, inf);
    if (l.hi < exp_log_bottom_bound) return Bounds.init(0.0, f64_float_true_min);
    return cert.exp(l);
}

/// `e^l > floatMax(f64)` is proved for `l > 750`, and `e^l < floatTrueMin(f64)`
/// for `l < -750`. See `expPositive` for the proof of both.
const exp_log_top_bound: f128 = 750.0;
const exp_log_bottom_bound: f128 = -750.0;

// ---------------------------------------------------------------------------
// factorial
// ---------------------------------------------------------------------------

/// `n!` for the nonnegative integers `n` in `[lo, hi]`, or `null` when there
/// are none.
///
/// This operator is DISCRETE. Its domain is the nonnegative integers and
/// nothing else, so `[3.2, 3.8]` has an empty image even though it straddles
/// three: an implementation that answered a fractional argument as its
/// nearest integer would answer 6 there, and `Gamma` answers it happily. The
/// candidates are therefore `ceil(lo)` clipped at zero and `floor(hi)`, and an
/// interval holding no integer at all is `null` -- the same strong claim a
/// pole is for `gamma`.
pub fn factorial(x: Interval) ?Interval {
    const first = @max(0.0, @ceil(x.lo));
    const last = @floor(x.hi);
    if (!(first <= last)) return null;

    // `n!` increases in `n` for `n >= 0`, so the image is the hull of the two
    // ends of the index range and nothing in between.
    return Bounds.project(Bounds.init(
        factorialProduct(first).lo,
        factorialProduct(last).hi,
    ));
}

/// `n!` for a nonnegative integer index `n` given as a `f64`, as an `f128`
/// bracket. `+inf` is accepted and means an index no `f64` can hold.
///
/// The product is accumulated in `f128` with every factor multiplying
/// outward, so the running interval bounds the true partial product by
/// induction; the `f64` projection happens once, at the end, rather than at
/// every step, which is why a product far past the top of the range is still a
/// statement about a product rather than a statement about where `f64` stopped.
fn factorialProduct(n: f64) Bounds {
    if (std.math.isInf(n)) return Bounds.init(f64_float_max, inf);
    if (n >= factorial_proved_overflow_index) return Bounds.init(f64_float_max, inf);

    // The index is a nonnegative integer below 2048, so the conversion to an
    // The index is a nonnegative integer below 2048, so the conversion to an
    // integer is exact and cannot trap. The loop below is bounded by it, which
    // is the constant-time property: an index too large for any `f64` never
    // reaches a loop at all.
    const count: u64 = @intFromFloat(n);
    var product: Bounds = Bounds.point(1.0);
    var k: u64 = 2;
    while (k <= count) : (k += 1) {
        product = Bounds.mul(product, Bounds.point(@as(f128, @floatFromInt(k))));
        // Only the LOWER end of the bracket proves anything about the exact
        // product. A bracket whose upper end is past `floatMax(f64)` while its
        // lower end is below it says that the product MAY be past the top, and
        // `floatMax` would then be a bound on nothing; the answer has to be
        // the whole bracket in that case, which the fall-through does. A lower
        // end past `floatMax` is a proof, and the factors are at least one
        // from here on, so it is also a proof for every larger product. In
        // `f128` the bracket is far narrower than the factor of 171 between
        // 170! and 171!, so the proof arrives at 171 steps.
        if (product.lo > f64_float_max) return Bounds.init(f64_float_max, inf);
    }
    return product;
}

/// The index from which `n!` is proved to exceed `floatMax(f64)` without any
/// multiplication at all.
///
/// For `n >= 2048`, the factors from `ceil(n/2)` to `n` are at least 1024 of
/// them and each is at least `ceil(n/2) >= 1024 = 2^10`, so
/// `n! >= 2^(10*1024) = 2^10240`. And `floatMax(f64)` is
/// `(2 - 2^-52) * 2^1023`, which is below `2^1024`. So every `n!` from this
/// index on is above every `f64`, and the answer is `[floatMax, +inf]` -- a
/// sound enclosure of a real that exists, rather than `null`, which would claim
/// the image is empty.
const factorial_proved_overflow_index: f64 = 2048.0;