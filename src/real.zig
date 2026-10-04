//! The real scalar catalog: exact rational exponents, rational powers and
//! roots, logarithms to an arbitrary base, order statistics, the mathematical
//! sign, the positive remainder, n-ary gcd and lcm over the reals, and the two
//! directed tie roundings.
//!
//! Nothing here allocates. Every list operation takes the caller's slice and,
//! where it has to reorder, a caller-owned `[]f64` scratch buffer of at least
//! `xs.len` elements; a shorter buffer is `error.InsufficientScratch` rather
//! than an answer computed from storage that could not hold the question.
//!
//! Every answer is an ENCLOSURE of the true image of the whole argument. A
//! `null` is the strong claim that the image is empty in the reals, and it is
//! only ever returned for an argument that leaves the domain entirely; an
//! argument that leaves it in part is clipped and answered, so the null-ness and
//! the endpoints of a partial-domain answer stay separate claims. The `*Domain`
//! functions below say which of the three cases a caller's argument is, which
//! is what a caller that must also report DEFINEDNESS rather than an interval or
//! nothing needs and cannot get from a single `null`.
//!
//! # The arithmetic underneath
//!
//! The transcendental steps — the logarithms, the exponentials, the square and
//! cube roots — come from `certified.zig`, which evaluates them in OUTWARD f128
//! interval arithmetic with analytic remainder bounds on the series, so every
//! bound in this file is a proof about the real value rather than a point answer
//! widened by a guessed number of ULPs. The f128 results reach the caller
//! through `Bounds.project`, which is the one place that turns a certified f128
//! enclosure into an f64 one: it steps each end to its neighbouring f64,
//! including the signed zeros where a computed zero must not be believed, and it
//! saturates where a real is not there to be bounded. This file has no second
//! projection and no f64 rounding of its own, because a second copy is a second
//! place for the underflow arms to be wrong.
//!
//! The cases where a real answer is EXACT rather than enclosed are listed at
//! each site: a rational exponent of zero, the roots `certified` computes
//! exactly, the IEEE remainder, the order-statistic corners, the tie roundings
//! (whose images are integers, so they carry no rounding at all), the scaling of
//! an exact integer by a power of two, and the dyadic arithmetic of gcd and lcm.

const std = @import("std");
const interval_mod = @import("interval.zig");
const rounding = @import("rounding.zig");
const certified = @import("certified.zig");

const Interval = interval_mod.Interval;

/// The certified f128 enclosure type. Every transcendental step in this file
/// produces one of these, and every interval this file returns is one of them
/// through `Bounds.project`.
const Bounds = certified.Bounds;

const f128_inf = std.math.inf(f128);

/// The smallest NORMAL f128, `2^-16382`. It is the bound this file uses for a
/// value too small for the format to hold precisely: `2^-16494` and below are
/// the subnormals, and anything under half the smallest subnormal rounds to a
/// zero that this library would take as exact.
const f128_min_normal: f128 = std.math.floatMin(f128);

// ---------------------------------------------------------------------------
// Exact rational numbers
// ---------------------------------------------------------------------------

/// An exact rational number as a pair of integers, which is how an exponent is
/// written when the float nearest a third is not a third. The two fields are
/// TAGS, not a rounded approximation: `numerator` and `denominator` read back
/// exactly what `init` normalized, so `1/3` is not `1/2.9999999999999996`.
pub const Rational = struct {
    /// The signed numerator, so that the value is `numerator / denominator`.
    /// `minInt(i64)` is a reachable numerator and is never negated on the way
    /// to one.
    numerator: i64,
    /// The positive denominator, always coprime with `numerator`, and exactly 1
    /// for a zero value whatever denominator it was written with.
    denominator: u64,

    /// The normalized form of `numerator / denominator`, or
    /// `error.ZeroDenominator` when the denominator is zero.
    ///
    /// The three cases the shape of the answer has to survive are written out
    /// rather than reached by accident:
    ///
    ///  * A zero numerator reduces to `0/1` whatever denominator it was given,
    ///    including the largest `u64`. A `0/17` would be a second spelling of
    ///    the same number and every consumer of the pair would have to divide
    ///    before it could compare.
    ///  * The sign lives on the numerator and the denominator stays positive, so
    ///    `(-4, 6)` is `(-2, 3)` and never `(-2, -3)`: two equal rationals have
    ///    one representation and can be compared field by field.
    ///  * `minInt(i64)` has no positive counterpart in `i64`, so the magnitude is
    ///    taken and divided in `u64` and only the RESULT comes back to `i64`.
    ///    Negating it would trap, and so would dividing the other way round:
    ///    `(-2^63, 2^62)` is `(-2, 1)`, which is reachable, and `(minInt, 2^63)`
    ///    is `(-1, 1)`.
    pub fn init(numerator: i64, denominator: u64) error{ZeroDenominator}!Rational {
        if (denominator == 0) return error.ZeroDenominator;
        if (numerator == 0) return Rational{ .numerator = 0, .denominator = 1 };
        // |numerator| without a negation of minInt: its two's complement read as
        // u64 is 2^63, which is exactly the magnitude.
        const mag: u64 = if (numerator == std.math.minInt(i64))
            @as(u64, 1) << 63
        else
            @intCast(if (numerator < 0) -numerator else numerator);
        const common = gcdU64(mag, denominator);
        const reduced = mag / common;
        const num: i64 = if (numerator < 0)
            (if (reduced == (@as(u64, 1) << 63))
                std.math.minInt(i64)
            else
                -@as(i64, @intCast(reduced)))
        else
            @intCast(reduced);
        // The value is BUILT here rather than re-normalized by a recursive call:
        // an already reduced pair — `1/1`, `7/3`, `5/7` — has a gcd of one and
        // would hand itself back unchanged, forever.
        return Rational{ .numerator = num, .denominator = denominator / common };
    }
};

/// gcd of two `u64` by Stein's binary algorithm: it divides out the common twos
/// first, so the odd loop that remains halves a difference every step and
/// terminates in a logarithm of the inputs rather than in their difference. Both
/// arguments are magnitudes here and cannot both be zero, which is what the
/// loop's last step assumes.
fn gcdU64(a0: u64, b0: u64) u64 {
    var a = a0;
    var b = b0;
    if (a == 0) return b;
    if (b == 0) return a;
    const shift_a: u6 = @intCast(@ctz(a));
    const shift_b: u6 = @intCast(@ctz(b));
    const common_shift = @min(shift_a, shift_b);
    a >>= shift_a;
    b >>= shift_b;
    while (a != b) {
        // The larger is replaced by its difference with the smaller. On odd
        // positive values the difference is even, so every pass removes at least
        // one factor of two and the loop cannot run away.
        if (a > b) a -= b else b -= a;
        b >>= @intCast(@ctz(b));
    }
    return a << common_shift;
}

// ---------------------------------------------------------------------------
// Partial domains
// ---------------------------------------------------------------------------

/// How much of an argument has a value, spelled with the same three answers
/// `truth.Truth` uses and in the same order, so a tracked layer can map one onto
/// the other without a table.
///
/// `always` means every point of the argument is in the domain; `maybe` means the
/// argument is clipped or split by the domain and the answer encloses only the
/// part that survives; `never` means the argument is entirely outside it and the
/// function returns `null`.
pub const Domain = enum {
    never,
    maybe,
    always,
};

// ---------------------------------------------------------------------------
// The f128 helpers the catalog shares
// ---------------------------------------------------------------------------

/// The union of two certified enclosures: a number is in the union iff it is in
/// one of the parts, so the smaller lower bound and the larger upper bound bound
/// it.
fn hull(a: Bounds, b: Bounds) Bounds {
    return Bounds.init(@min(a.lo, b.lo), @max(a.hi, b.hi));
}

/// The reflection of an enclosure through zero, `[-hi, -lo]`: the image of a
/// negated range, which is not that range with its ends swapped.
fn negate(b: Bounds) Bounds {
    return Bounds.init(-b.hi, -b.lo);
}

/// An accumulator over the parts a domain split produces. The frozen `certified`
/// surface has no hull method, so the accumulator carries the two comparisons and
/// the null it starts as.
const Union = struct {
    value: ?Bounds = null,

    fn add(self: *Union, b: Bounds) void {
        self.value = if (self.value) |a| hull(a, b) else b;
    }
};

// ---------------------------------------------------------------------------
// Rational powers
// ---------------------------------------------------------------------------

/// The largest argument of `exp` this file evaluates directly, and the floor
/// below it. `exp(11350) ≈ 2.7e4929`, which is inside the f128 range and far
/// outside the f64 one — `ln(float_max) ≈ 709.8` — so an argument at or above the
/// ceiling has an f64 answer of `+inf` however it is computed, and one at or
/// below the floor has an f64 answer of `[0, min_subnormal]`. Saturating there
/// costs nothing in f64 and keeps the exponentials away from their own overflow
/// and underflow, where the answer is decided rather than computed.
const exp_ceiling: f128 = 11350.0;
const exp_floor: f128 = -11350.0;

/// The smallest logarithm an f64 strictly above one can have: such a base is at
/// least `1 + 2^-52`, and `ln(1 + t) > t/(1 + t)` for `t > 0`, so `2^-53` is a
/// valid lower bound. It keeps a denominator positive where a computed bound
/// could reach zero through its own widening.
const log_above_one: f128 = 1.0 / @as(f128, @as(u64, 1) << 53);

/// `exp(e)` over a certified `e`, saturated in f64 at the two ends. The kernel is
/// `certified`'s; the two arms are arithmetic about the f64 range.
fn expBounded(e: Bounds) Bounds {
    if (e.lo >= exp_ceiling) return Bounds.point(f128_inf);
    if (e.hi <= exp_floor) return Bounds.init(0.0, @as(f128, rounding.min_subnormal));
    return certified.exp(e);
}

/// `t^(n/d)` for `t > 0`, where `n != 0` and `d >= 1` is the REDUCED
/// denominator, so `n` and `d` are coprime.
///
/// Three cases, in this order:
///
///  * `d == 1` is an integer power and is computed by repeated squaring in f128
///    rather than through `exp`: squaring an exact dyadic stays exact while it
///    fits, so `2^600` is `2^600` here and not a point estimate of it. A negative
///    exponent inverts, and the inverse of a saturated power is zero, which is
///    the right bound.
///  * Otherwise `t^(n/d) = exp((n/d) ln t)`. The exponent is formed in f128
///    where `n` (up to 2^63) and `d` (up to 2^64) are both exact, so the division
///    is the only rounding in it.
///  * The bounds of `t` propagate through `ln` and `exp` monotonically, so
///    `certified.log` and `expBounded` enclose the image of the whole input bound
///    and not of one sample of it.
///
/// `t` must have a strictly positive lower bound: the zero end is answered by
/// `powSpan`, which knows what `0^(n/d)` is.
fn magnitudePow(t: Bounds, n: i64, d: u64) Bounds {
    std.debug.assert(t.lo > 0.0);
    if (d == 1) {
        // |n| without a negation of minInt, whose two's complement read as u64 is
        // its magnitude: 2^63 is a legal exponent count and the largest
        // `Rational` can name.
        const magnitude: u64 = if (n == std.math.minInt(i64))
            @as(u64, 1) << 63
        else
            @intCast(if (n < 0) -n else n);
        const positive = certified.powUnsigned(t, magnitude);
        if (n > 0) return positive;
        return Bounds.point(1.0).div(positive);
    }
    const exponent = certified.log(t)
        .mul(Bounds.point(@as(f128, @floatFromInt(n))))
        .div(Bounds.point(@as(f128, @floatFromInt(d))));
    return expBounded(exponent);
}

/// The image of `[tlo, thi]` with `0 <= tlo <= thi` and `thi > 0` under
/// `t -> t^(n/d)`.
///
/// The map is monotone in `t`, rising for `n > 0` and falling for `n < 0`, so the
/// two ends of the input give the two ends of the image and the pairing follows
/// that direction. The zero end is the case the pairing cannot cover: `0^(n/d)`
/// is `0` for `n > 0`, is not a real at all for `n < 0` (and a box that is
/// nothing but zero has been refused by the caller), and over a span whose low
/// end IS zero with `n < 0` the image runs to `+inf`.
fn powSpan(tlo: f64, thi: f64, n: i64, d: u64) Bounds {
    if (n > 0) {
        const high = magnitudePow(Bounds.point(thi), n, d);
        if (tlo == 0.0) return Bounds.init(0.0, high.hi);
        const low = magnitudePow(Bounds.point(tlo), n, d);
        return Bounds.init(low.lo, high.hi);
    }
    const low = magnitudePow(Bounds.point(thi), n, d);
    if (tlo == 0.0) return Bounds.init(low.lo, f128_inf);
    const high = magnitudePow(Bounds.point(tlo), n, d);
    return Bounds.init(low.lo, high.hi);
}

/// One positive endpoint through the d-th root; `t.lo > 0` as there.
fn magnitudeRoot(t: Bounds, d: u32) Bounds {
    std.debug.assert(t.lo > 0.0);
    switch (d) {
        1 => return t,
        2 => return certified.sqrt(t),
        3 => return certified.cbrt(t),
        else => {
            const e = certified.log(t).div(Bounds.point(@as(f128, @floatFromInt(d))));
            return expBounded(e);
        },
    }
}

/// The image of `[tlo, thi]` with `0 <= tlo <= thi` and `thi > 0` under the d-th
/// root, for `d >= 1` a magnitude of a root. Rising in `t`, so the two ends pair
/// straight through, and the zero end is the point zero.
fn rootSpan(tlo: f64, thi: f64, d: u32) Bounds {
    const high = magnitudeRoot(Bounds.point(thi), d);
    if (tlo == 0.0) return Bounds.init(0.0, high.hi);
    const low = magnitudeRoot(Bounds.point(tlo), d);
    return Bounds.init(low.lo, high.hi);
}

/// `x` raised to the exact rational `p`, or `null` when the real image of the
/// WHOLE of `x` is empty.
///
/// The exponent is read rather than evaluated. `p.denominator` says whether the
/// root it asks for is defined on negative bases, `p.numerator` says whether the
/// answer keeps the base's sign, and `p.numerator == 0` is `1` for every base at
/// all — zero included — which is the `0^0 = 1` convention the catalog states
/// rather than a limit.
///
///  * An EVEN denominator asks for an even root, which no negative base has. The
///    negative part of `x` contributes nothing and is dropped, and the box is
///    refused only when that part was all of it.
///  * An ODD denominator asks for the unique real root, defined on the whole
///    line and RISING, so `(-27, -8)^(1/3)` is `[-3, -2]` with the base's sign
///    kept, and `(-8)^(2/3)` is `4`, because the sign belongs to the numerator's
///    parity and not to the base's.
///  * A box that is exactly zero under a NEGATIVE exponent has no image —
///    `0^(-1/1)` and `0^(-2/3)` are both `null` — while a box reaching zero from
///    the positive side is partly defined: the positive part answers and the
///    image runs to `+inf`.
///
/// A box that reaches zero and stops there under a POSITIVE exponent is
/// ordinary: zero is in the image, and it is added exactly.
pub fn powRational(x: Interval, p: Rational) ?Interval {
    if (p.numerator == 0) return Interval.init(1.0, 1.0);
    const n = p.numerator;
    const d = p.denominator;
    const odd_denominator = (d & 1) == 1;

    if (!odd_denominator and x.hi < 0.0) return null;
    // The point zero under a negative exponent is the one box with no image at
    // all that an odd denominator does not already refuse.
    if (n < 0 and x.lo == 0.0 and x.hi == 0.0) return null;

    var acc = Union{};
    // The part of x at or above zero, through the monotone t -> t^(n/d).
    if (x.hi > 0.0) acc.add(powSpan(@max(x.lo, 0.0), x.hi, n, d));
    // The part below zero, kept whole only for an odd denominator: its magnitudes
    // run from the modulus of the point closest to zero to the modulus of the
    // lowest one, the map is applied to those, and the sign the numerator's
    // parity asks for is applied last.
    if (odd_denominator and x.lo < 0.0) {
        const part = powSpan(-@min(x.hi, 0.0), -x.lo, n, d);
        acc.add(if (isOdd(n)) negate(part) else part);
    }
    // Zero is in the image exactly when the exponent is positive.
    if (n > 0 and x.lo <= 0.0 and x.hi >= 0.0) acc.add(Bounds.point(0.0));
    std.debug.assert(acc.value != null);
    return Bounds.project(acc.value.?);
}

fn isOdd(v: i64) bool {
    return (v & 1) != 0;
}

/// How much of `x` `powRational` has an image for; see `Domain`.
pub fn powRationalDomain(x: Interval, p: Rational) Domain {
    if (p.numerator == 0) return .always;
    const n = p.numerator;
    if ((p.denominator & 1) == 0) {
        // An even root needs a nonnegative base: the negative part of the box has
        // no image, and the box is wholly outside the domain when that part is
        // all of it.
        if (x.hi < 0.0) return .never;
        if (x.lo < 0.0) return .maybe;
        if (n < 0 and x.lo == 0.0) return .maybe;
        return .always;
    }
    // An odd root is defined on the whole line, so the only hole is zero under a
    // negative exponent.
    if (n < 0) {
        if (x.lo == 0.0 and x.hi == 0.0) return .never;
        if (x.lo <= 0.0) return .maybe;
    }
    return .always;
}

/// The `degree`-th root of `x`, INDEX FIRST so that it reads like the exponent
/// it inverts, or `null` when the image is empty.
///
///  * `degree == 0` is not a root of anything — `x^(1/0)` is not a power — so it
///    is refused rather than answered with the whole line.
///  * `degree == 1` is the identity, and returning `x` is exact rather than a
///    bound around it.
///  * An EVEN degree clips the negative part away, so a box reaching zero from
///    below is partly defined and one wholly below zero has no real image.
///  * An ODD degree is defined and rising on the whole line, so the negative part
///    is kept with its sign: `nthRoot(3, [-8, 27])` is `[-2, 3]`, not `[0, 3]`.
///
/// Every other degree goes through the same machinery as `powRational`, which is
/// what makes `nthRoot(d, x)` and `powRational(x, 1/d)` the same answer by
/// construction rather than by agreement.
pub fn nthRoot(degree: u32, x: Interval) ?Interval {
    if (degree == 0) return null;
    if (degree == 1) return x;

    var acc = Union{};
    if (x.hi > 0.0) acc.add(rootSpan(@max(x.lo, 0.0), x.hi, degree));
    if ((degree & 1) == 1 and x.lo < 0.0) {
        acc.add(negate(rootSpan(-@min(x.hi, 0.0), -x.lo, degree)));
    }
    // Zero is a root of zero at every positive degree, and its image is the point
    // zero. The spans above already start there when x reaches zero; this arm
    // covers the box that IS zero.
    if (x.lo <= 0.0 and x.hi >= 0.0) acc.add(Bounds.point(0.0));
    std.debug.assert(acc.value != null);
    return Bounds.project(acc.value.?);
}

/// How much of `x` `nthRoot` has an image for; see `Domain`.
pub fn nthRootDomain(degree: u32, x: Interval) Domain {
    if (degree == 0) return .never;
    if ((degree & 1) == 1) return .always;
    if (x.hi < 0.0) return .never;
    if (x.lo < 0.0) return .maybe;
    return .always;
}

// ---------------------------------------------------------------------------
// Logarithms to an arbitrary base
// ---------------------------------------------------------------------------

/// `log_base(x)`, BASE FIRST so it reads the way the identity does, or `null`
/// when the image is empty.
///
/// The domain is `base > 0`, `base != 1`, `x > 0`, and each of the three is
/// checked on the WHOLE box: a base at or below zero, a base that IS one, or an
/// argument at or below zero is a `null`, not a clip.
///
/// The two sides of one are kept apart rather than hulled together, because they
/// are two different functions and hulling their denominators through zero
/// invents quotients no base produces. A base in `(0, 1)` has a NEGATIVE
/// logarithm, and the quotient falls without bound as the base approaches one
/// from below; a base above one has a POSITIVE logarithm, and the quotient rises
/// without bound as the base leaves one. Each is answered from its own
/// denominator box `(0, ln hi]`, and the answer is the union of the two, so a
/// base box crossing one carries both rays and a base box that does not carries
/// only the ray it has.
///
/// With `n` over `[nlo, nhi]` and `d` over `(dlo, dhi]` with `dhi > 0` — the
/// limit `dlo == 0` standing for a base approaching one from its own side — the
/// quotient is monotone in each argument on each side of zero, so:
///  * `dlo > 0`: `[nlo/dhi, nhi/dlo]`;
///  * `dlo == 0`: the bound reaching zero is unbounded on the side its numerator
///    has — `nlo < 0` gives `-inf`, `nhi > 0` gives `+inf` — and the other end is
///    the far one, `nlo/dhi` or `nhi/dhi`.
pub fn logBase(base: Interval, x: Interval) ?Interval {
    if (x.hi <= 0.0 or base.hi <= 0.0) return null;

    const upper_exists = base.hi > 1.0;
    const lower_anchor = @min(base.hi, 1.0);
    // The bases below one are `(max(base.lo, 0), lower_anchor]`, or the open
    // `(0, 1)` when the box reaches past one. Either way the branch exists when
    // there is a base strictly below one and strictly above zero in the box.
    const lower_exists = if (lower_anchor < 1.0) lower_anchor > 0.0 else base.lo < 1.0;
    if (!upper_exists and !lower_exists) return null;

    // The numerator: ln over the part of x that survives the domain, running down
    // to -inf as x reaches zero from above.
    const nlo: f128 = if (x.lo <= 0.0) -f128_inf else logPoint(x.lo).lo;
    const nhi: f128 = logPoint(x.hi).hi;

    var acc = Union{};
    if (upper_exists) {
        // den in (0, ln(base.hi)]: a base at or above one, and the one end is
        // never attained, which the limit zero carries. The far end is clamped UP
        // to the smallest logarithm an f64 above one can have, which keeps the
        // denominator positive without lifting it above the true value.
        acc.add(ratio(nlo, nhi, 0.0, @max(logPoint(base.hi).lo, log_above_one)));
    }
    if (lower_exists) {
        // den in [ln(max(base.lo, 0)), ln(lower_anchor)] is nonpositive, so it is
        // divided through by the negation of both, which is the SAME quotient and
        // not a reflection of it. The near end is clamped DOWN to zero: the
        // anchor is at most one, so its true logarithm is at most zero, and a
        // computed lower bound above that would be no bound.
        const den_lo: f128 = if (base.lo <= 0.0) -f128_inf else logPoint(base.lo).lo;
        const den_hi: f128 = @min(logPoint(lower_anchor).hi, 0.0);
        acc.add(ratio(-nlo, -nhi, -den_hi, -den_lo));
    }
    std.debug.assert(acc.value != null);
    return Bounds.project(acc.value.?);
}

/// How much of `(base, x)` `logBase` has an image for; see `Domain`.
pub fn logBaseDomain(base: Interval, x: Interval) Domain {
    if (x.hi <= 0.0 or base.hi <= 0.0) return .never;
    if (base.lo == 1.0 and base.hi == 1.0) return .never;
    if (x.lo <= 0.0) return .maybe;
    if (base.lo <= 0.0) return .maybe;
    if (base.lo <= 1.0 and base.hi >= 1.0) return .maybe;
    return .always;
}

/// `ln` of a single positive endpoint, as an enclosure. A point is still widened:
/// the kernel's series truncation is a bound, not a sample.
fn logPoint(x: f64) Bounds {
    return certified.log(Bounds.point(x));
}

/// `n / d` over `n` in `[nlo, nhi]` and `d` in `(dlo, dhi]`, as `logBase` needs
/// it. See that function for the two cases.
fn ratio(nlo: f128, nhi: f128, dlo: f128, dhi: f128) Bounds {
    // The denominator range has to reach a positive value; a range that does not
    // is one the caller's clamps could not keep, and the whole line is the only
    // bound that answers it.
    if (!(dhi > 0.0)) return Bounds.init(-f128_inf, f128_inf);
    if (dlo > 0.0) return Bounds.init(div128(nlo, dhi), div128(nhi, dlo));
    const lo = if (nlo < 0.0) -f128_inf else div128(nlo, dhi);
    const hi = if (nhi > 0.0) f128_inf else div128(nhi, dhi);
    return Bounds.init(lo, hi);
}

/// The quotient of two f128 bounds, with the one pair IEEE leaves open answered
/// rather than propagated: a magnitude divided by an unbounded magnitude is a
/// NaN, and here the answer is the two-ended limit, zero. That is sound because
/// the extreme of the quotient in that direction is carried by the OTHER corner —
/// the numerator's own infinity against the smallest denominator, or the largest
/// numerator against the denominator's far end — and the hull over both is what
/// the caller keeps.
fn div128(a: f128, b: f128) f128 {
    if (std.math.isInf(b)) return 0.0;
    return a / b;
}

// ---------------------------------------------------------------------------
// Order statistics
// ---------------------------------------------------------------------------

/// The smallest of the arguments, or `null` for an empty list.
///
/// Independent arguments make this a hull and not a point: `min([0, 10], [3, 5])`
/// is `[0, 5]`, because the smallest pair can be `0` (both take their low end)
/// and `5` (the first takes its high end and the second its low end). `min` is
/// monotone in each argument, so its extremes are the low ends and the high ends
/// paired the same way, and nothing is assumed about the arguments being related.
pub fn min(xs: []const Interval) ?Interval {
    if (xs.len == 0) return null;
    var lo = xs[0].lo;
    var hi = xs[0].hi;
    for (xs[1..]) |v| {
        lo = @min(lo, v.lo);
        hi = @min(hi, v.hi);
    }
    return Interval.init(lo, hi);
}

/// The largest of the arguments, or `null` for an empty list. The mirror of `min`
/// on every point of it.
pub fn max(xs: []const Interval) ?Interval {
    if (xs.len == 0) return null;
    var lo = xs[0].lo;
    var hi = xs[0].hi;
    for (xs[1..]) |v| {
        lo = @max(lo, v.lo);
        hi = @max(hi, v.hi);
    }
    return Interval.init(lo, hi);
}

/// The median: the middle value of an odd count, the mean of the two central
/// values of an even one. `null` for an empty list.
///
/// The image of an order statistic over independent arguments is not a hull of
/// the arguments but a hull of TWO CORNERS of the box: the k-th smallest is
/// monotone in every coordinate, so its smallest value over the box is the k-th
/// smallest of the LOW ends and its largest is the k-th smallest of the HIGH ends.
/// Nothing in between has to be enumerated and nothing outside those two corners
/// can be attained. The median of an even count is a sum of two such statistics
/// divided by two, which is monotone in the same way, so the same two corners give
/// it.
///
/// The scratch holds `xs.len` `f64`; the two sorts are done one after the other in
/// it and only the one or two values each sort is read for is kept. A buffer
/// shorter than the list is `error.InsufficientScratch` rather than a truncated
/// question.
pub fn median(xs: []const Interval, scratch: []f64) error{InsufficientScratch}!?Interval {
    if (scratch.len < xs.len) return error.InsufficientScratch;
    if (xs.len == 0) return null;
    const n = xs.len;
    const middle = n / 2;
    const pair = n % 2 == 0;
    // For an even count the two central values are at middle-1 and middle; for an
    // odd count the middle value is the only one, and the second slot is filled
    // with zero and never read.
    const first = middle - @as(usize, if (pair) 1 else 0);

    for (xs, 0..) |v, i| scratch[i] = v.lo;
    sortAscending(scratch[0..n]);
    const lo_a = scratch[first];
    const lo_b = if (pair) scratch[middle] else 0.0;

    for (xs, 0..) |v, i| scratch[i] = v.hi;
    sortAscending(scratch[0..n]);
    const hi_a = scratch[first];
    const hi_b = if (pair) scratch[middle] else 0.0;

    if (!pair) return Interval.init(lo_a, hi_a);
    return Bounds.project(meanBounds(lo_a, lo_b, hi_a, hi_b));
}

/// The `rank`-th smallest argument, `rank` ONE-BASED, or `null` when no integer
/// in `1..xs.len` lies in `rank`.
///
/// A rank is a position, not a real number: `0` and `xs.len + 1` are not ranks,
/// and a box like `[0.2, 0.8]` contains no integer at all, so the answer is empty
/// rather than the nearest rank. A box that does contain integers is CLIPPED to
/// those in range and then hulls every one of them, so `[1, 3]` over three
/// arguments is `[min, max]` while `[1.5, 2.5]` is the single rank 2, exactly.
///
/// The bounds come from the same two corners as `median`: the smallest value of
/// the rank-th order statistic over the box is that statistic at the low-end
/// corner, and over several ranks it is the LOWEST such rank there; the largest is
/// the HIGHEST.
pub fn nthSmallest(xs: []const Interval, rank: Interval, scratch: []f64) error{InsufficientScratch}!?Interval {
    if (scratch.len < xs.len) return error.InsufficientScratch;
    const ranks = validRanks(xs.len, rank) orelse return null;
    return orderStatistic(xs, ranks.first, ranks.last, scratch);
}

/// The `rank`-th largest argument, `rank` one-based from the top, or `null` when
/// no integer in `1..xs.len` lies in `rank`. The same question as `nthSmallest`
/// with the ranks counted the other way: rank `r` from the top is rank `n + 1 - r`
/// from the bottom, and the valid ranks map to an interval of the same kind, with
/// the ends swapped.
pub fn nthLargest(xs: []const Interval, rank: Interval, scratch: []f64) error{InsufficientScratch}!?Interval {
    if (scratch.len < xs.len) return error.InsufficientScratch;
    if (xs.len == 0) return null;
    const n: f64 = @floatFromInt(xs.len);
    const mirrored = Interval.init(n + 1.0 - rank.hi, n + 1.0 - rank.lo);
    const ranks = validRanks(xs.len, mirrored) orelse return null;
    return orderStatistic(xs, ranks.first, ranks.last, scratch);
}

/// A closed range of valid one-based ranks.
const RankRange = struct { first: usize, last: usize };

/// The valid one-based ranks a rank box reaches, or `null` when it reaches none.
///
/// Clipped rather than rounded: the least integer at or above `rank.lo` is the
/// first candidate and the greatest at or below `rank.hi` the last, and the pair
/// is clipped into `1..n` BEFORE either is turned into an index, so no conversion
/// is ever asked for a value outside the list. An infinite endpoint clips to an
/// end of the list.
fn validRanks(n: usize, rank: Interval) ?RankRange {
    if (n == 0) return null;
    const top: f64 = @floatFromInt(n);
    const k_first = @ceil(@max(rank.lo, 1.0));
    const k_last = @floor(@min(rank.hi, top));
    if (k_first > k_last) return null;
    return RankRange{
        .first = @intFromFloat(k_first),
        .last = @intFromFloat(k_last),
    };
}

/// The image of the order statistics `first..last` (one-based, both valid) over
/// the box of independent choices, by the two corners `median` names.
fn orderStatistic(xs: []const Interval, first: usize, last: usize, scratch: []f64) ?Interval {
    const n = xs.len;
    for (xs, 0..) |v, i| scratch[i] = v.lo;
    sortAscending(scratch[0..n]);
    const lower = scratch[first - 1];
    for (xs, 0..) |v, i| scratch[i] = v.hi;
    sortAscending(scratch[0..n]);
    const upper = scratch[last - 1];
    return Interval.init(lower, upper);
}

/// Sorts in place, ascending, with no allocation and no hidden buffer.
///
/// A heap sort rather than an insertion sort: both fit a caller-owned scratch
/// exactly, and the catalog's lists are caller-sized with no promise they are
/// short, so a quadratic order statistic is not a slow answer but a different one
/// on a long list.
fn sortAscending(values: []f64) void {
    std.sort.heap(f64, values, {}, std.sort.asc(f64));
}

/// The mean of two lower-end central values and two upper-end central values, as
/// a certified enclosure: the image of `(lower_a + lower_b) / 2` to
/// `(upper_a + upper_b) / 2`.
///
/// The mean is taken in f128 rather than in f64, where `(a + b) / 2` overflows on
/// two large same-sign endpoints and loses the smaller one's bit on a subnormal.
/// f128 holds the sum of two f64 exactly — 54 significand bits against 113 — so
/// the only rounding left is the projection's, and no avoidable overflow is
/// introduced to keep a result finite that the true mean is not. It is also what
/// keeps a mean of two subnormals from being computed as their sum's half in f64,
/// where `(min_subnormal + 0) / 2` is not representable at all.
///
/// `a` and `b` of OPPOSITE infinities have no mean to enclose, and the whole line
/// is the only sound answer rather than a trap.
fn meanBounds(lower_a: f64, lower_b: f64, upper_a: f64, upper_b: f64) Bounds {
    const lower = meanExact(lower_a, lower_b);
    const upper = meanExact(upper_a, upper_b);
    if (std.math.isNan(lower) or std.math.isNan(upper)) {
        return Bounds.init(-f128_inf, f128_inf);
    }
    return Bounds.init(lower, upper);
}

fn meanExact(a: f64, b: f64) f128 {
    return (@as(f128, a) + @as(f128, b)) / 2.0;
}

// ---------------------------------------------------------------------------
// The mathematical sign
// ---------------------------------------------------------------------------

/// The sign of `x` as a mathematical value: `-1` below zero, `0` at zero, `1`
/// above it, and the hull of the three when `x` spans them.
///
/// This is not an interval comparison. `sgn([-3, 0])` is `[-1, 0]` and not
/// `[-1, 1]`, because zero is INSIDE that box and `sign(0) = 0` is a value the box
/// attains; a box touching zero from one side is not a box of mixed signs.
/// `zeroSplit` already separates the five cases, so reading the sign off it means
/// this file cannot invent an arm `Interval` has not already justified.
pub fn sgn(x: Interval) Interval {
    return switch (x.zeroSplit()) {
        .negative => Interval.init(-1.0, -1.0),
        .positive => Interval.init(1.0, 1.0),
        .zero => Interval.init(0.0, 0.0),
        .touches_above => Interval.init(0.0, 1.0),
        .touches_below => Interval.init(-1.0, 0.0),
        .straddles => Interval.init(-1.0, 1.0),
    };
}

// ---------------------------------------------------------------------------
// The positive remainder
// ---------------------------------------------------------------------------

/// The positive remainder `x mod modulus`: the unique `r` with
/// `x = q * |modulus| + r` and `0 <= r < |modulus|`. `null` when the modulus is
/// the point zero, which has no remainder.
///
/// The modulus is taken by MAGNITUDE, so `-7 mod -3` is `2` and not the `-1` of a
/// truncated division: this is the remainder of a real number and not a
/// language's remainder operator.
///
/// Four cases, and the first three are exact:
///
///  * Two finite points. IEEE 754 defines `@rem` to be EXACT, so the remainder
///    of `x` by `|m|` is a real f64 already holds and is returned as itself. A
///    negative IEEE remainder is below zero, and adding the modulus back is one
///    rounded addition; the two ends are then stepped outward, which is exact
///    whenever the sum is and one ulp wider when it is not — `roundDown(fl(V))`
///    is at most `V` and `roundUp(fl(V))` at least `V` for every real `V`. The
///    sum cannot overflow: the remainder is below the modulus in magnitude, so
///    the total is below it too.
///  * A point modulus with an interval dividend. When the dividend lies inside
///    ONE cell `[q*m, (q+1)*m)` the remainder is `x - q*m`, rising, and the image
///    is that interval. The cell index `q` is an exact integer quotient of two
///    dyadics rather than a float division, because a float division of
///    `float_max` by three rounds to an integer and the floor of that names the
///    wrong cell. The test for staying in the cell is strict — the cell's far end
///    is excluded, since `x` at `(q+1)*m` has remainder zero — and it is made
///    against the LOWER end of the outward product, so a boundary that rounding
///    put a hair above `x.hi` falls back to the hull instead of claiming a cell
///    the dividend has left.
///  * A modulus box whose smallest magnitude covers the dividend: the remainder
///    is the dividend itself in the positive half, and the dividend plus the
///    modulus in the negative half. A modulus EQUAL to the dividend is its own
///    case, giving remainder zero rather than the dividend, so the low end of that
///    branch is zero and not the dividend.
///  * Anything else. A positive-modulus remainder is never below zero and never
///    reaches the modulus, so `[0, max|modulus|]` bounds it for every modulus in
///    the box — including the ones approaching zero, which is what keeps a box
///    that reaches zero an answered partial domain rather than a `null`.
pub fn mod(x: Interval, modulus: Interval) ?Interval {
    if (modulus.lo == 0.0 and modulus.hi == 0.0) return null;
    // Zero has zero remainder for every modulus, and that is a value, not a cell
    // to be searched: a dividend that IS zero is answered before any of the box
    // reasoning below, which would otherwise read it as a negative dividend and
    // add the modulus to it.
    if (x.lo == 0.0 and x.hi == 0.0) return Interval.init(0.0, 0.0);
    const magnitude = modulus.abs();

    // Two points: the exact IEEE remainder. Infinities are excluded, because IEEE
    // leaves `x rem y` NaN when one of them is infinite and an infinite dividend
    // is not a real number: such a box is unbounded, and the hull at the end is
    // the bound for every finite value in it.
    if (x.lo == x.hi and magnitude.lo == magnitude.hi and
        std.math.isFinite(x.lo) and std.math.isFinite(magnitude.lo))
    {
        const t = @rem(x.lo, magnitude.lo);
        if (t >= 0.0) return Interval.init(t, t);
        return Interval.init(
            rounding.roundDown(t + magnitude.lo),
            rounding.roundUp(t + magnitude.lo),
        );
    }

    // A point modulus, with the dividend inside one cell.
    if (magnitude.lo == magnitude.hi and std.math.isFinite(magnitude.lo)) {
        if (singleCellRemainder(x, magnitude.lo)) |cell| return cell;
    }

    // A modulus box whose smallest magnitude still covers the dividend: the
    // remainder is the dividend itself in the positive half, and the dividend
    // plus the modulus in the negative half, and both are exact images.
    if (x.lo >= 0.0 and magnitude.lo >= x.hi) {
        // Equality is its own case and is why the test is not a strict one: a
        // modulus EQUAL to the dividend has remainder zero, while every modulus
        // above it has the dividend itself, so the image is the zero together
        // with the dividend range and its low end is zero, not the dividend.
        return Interval.init(if (magnitude.lo == x.hi) 0.0 else x.lo, x.hi);
    }
    if (x.hi <= 0.0 and magnitude.lo >= -x.lo) {
        return Bounds.project(Bounds.fromInterval(x).add(Bounds.fromInterval(magnitude)));
    }

    // The general hull: a remainder is in [0, |m|), so [0, max|m|] bounds it for
    // every modulus in the box.
    return Interval.init(0.0, rounding.roundUp(magnitude.hi));
}

/// How much of the arguments `mod` has an image for; see `Domain`. Only the
/// modulus has a domain: the dividend is a real of any sign, and zero is a
/// dividend with an answer.
pub fn modDomain(x: Interval, modulus: Interval) Domain {
    _ = x;
    if (modulus.lo == 0.0 and modulus.hi == 0.0) return .never;
    if (modulus.lo <= 0.0 and modulus.hi >= 0.0) return .maybe;
    return .always;
}

/// The remainder over `[x.lo, x.hi]` when both ends lie in the same cell of
/// `m > 0`, or `null` when they do not.
fn singleCellRemainder(x: Interval, m: f64) ?Interval {
    const q = floorQuotient(x.lo, m) orelse return null;
    const cell_top = Bounds.point(@as(f128, q) + 1.0).mul(Bounds.point(m));
    if (!(@as(f128, x.hi) < cell_top.lo)) return null;
    const base = Bounds.point(@as(f128, q)).mul(Bounds.point(m));
    const from_lo = certified.sub(Bounds.point(x.lo), base);
    const from_hi = certified.sub(Bounds.point(x.hi), base);
    return Bounds.project(Bounds.init(from_lo.lo, from_hi.hi));
}

/// `floor(a / m)` for finite `a` and `m > 0`, exactly, or `null` when the
/// quotient is too large for the `i128` that carries it.
///
/// The float division is not the way in. `a` and `m` are dyadic, so `a / m` is a
/// rational whose distance from an integer is at least `1 / odd_part`, while the
/// f128 rounding error of the division grows with the QUOTIENT rather than with
/// that distance: at `a ≈ 2^1023` the error is about `2^-90` while the distance
/// can be `2^-52`, so the f128 quotient can land on an integer that is not there
/// and the floor of it names the wrong cell. Both operands are therefore taken as
/// exact `mantissa * 2^exponent` pairs and divided as integers, where the floor is
/// the definition.
fn floorQuotient(a: f64, m: f64) ?i128 {
    if (!std.math.isFinite(a) or !std.math.isFinite(m)) return null;
    const num = decompose(@abs(a));
    const den = decompose(m);
    const shift = @as(i64, num.exponent) - @as(i64, den.exponent);
    if (shift >= 0) {
        // (num.mantissa * 2^shift) / den.mantissa. The shift is capped at 70 so the
        // scaled numerator stays inside a u128: 53 bits of mantissa against the 70
        // left to it is 123, inside 127.
        if (shift > 70) return null;
        const scaled: u128 = @as(u128, num.mantissa) << @intCast(shift);
        const divisor: u128 = @as(u128, den.mantissa);
        const quotient = scaled / divisor;
        if (a < 0.0 and scaled % divisor != 0) return -@as(i128, @intCast(quotient + 1));
        return @intCast(quotient);
    }
    const back = -shift;
    if (back > 70) {
        // The quotient is below one in magnitude, so its floor is 0 upwards and
        // -1 downwards.
        return if (a < 0.0) -1 else 0;
    }
    const divisor: u128 = @as(u128, den.mantissa) << @intCast(back);
    const scaled: u128 = @as(u128, num.mantissa);
    const quotient = scaled / divisor;
    if (a < 0.0 and scaled % divisor != 0) return -@as(i128, @intCast(quotient + 1));
    return @intCast(quotient);
}

// ---------------------------------------------------------------------------
// Dyadic decomposition
// ---------------------------------------------------------------------------

/// A finite f64 as `mantissa * 2^exponent` with the mantissa ODD, or
/// `mantissa == 0` for zero.
///
/// Oddness is what makes gcd and lcm exact arithmetic rather than an
/// approximation. The power of two in a dyadic number and its odd part are
/// coprime, so the gcd of two of them is the gcd of the ODD parts times the
/// SMALLER power of two, and the lcm is the lcm of the odd parts times the
/// LARGER. Neither statement has to argue about an odd factor against a power of
/// two, and a `u64` holds every f64 mantissa.
const Dyadic = struct {
    mantissa: u64,
    exponent: i32,
};

/// The exact decomposition of a finite f64.
fn decompose(x: f64) Dyadic {
    std.debug.assert(std.math.isFinite(x));
    if (x == 0.0) return Dyadic{ .mantissa = 0, .exponent = 0 };
    const bits: u64 = @bitCast(@abs(x));
    const fraction_mask = (@as(u64, 1) << 52) - 1;
    const fraction = bits & fraction_mask;
    const biased: i32 = @intCast((bits >> 52) & 0x7ff);
    // A normal number is (2^52 + fraction) * 2^(biased - 1075), and a subnormal is
    // fraction * 2^-1074. Both then lose their trailing twos, which is what makes
    // the odd part odd.
    var mantissa: u64 = undefined;
    var exponent: i32 = undefined;
    if (biased == 0) {
        mantissa = fraction;
        exponent = -1074;
    } else {
        mantissa = fraction | (@as(u64, 1) << 52);
        exponent = biased - 1075;
    }
    const twos: u6 = @intCast(@ctz(mantissa));
    return Dyadic{
        .mantissa = mantissa >> twos,
        .exponent = exponent + @as(i32, twos),
    };
}

/// `lower * 2^exponent` through `upper * 2^exponent`, where the two coefficients
/// are exact integers the caller has already bounded the value with, as a
/// certified f128 enclosure.
///
/// The power of two is exact wherever f128 holds a result at full precision, so
/// the two products are the exact images of the two coefficients there. Three
/// ends are not, and none of them is answered with a rounded value:
///
///  * An OVERFLOW is an infinity, which is the right bound for a value past the
///    f128 range and becomes the overflow ray in f64.
///  * A SUBNORMAL result is rounded by the scaling, and a bound here is a proof,
///    so it is not used: that side is widened to zero on the low end and to the
///    smallest NORMAL f128 on the high end, which enclose every value the format
///    cannot hold precisely. Widening a negative side to zero is sound — zero is
///    above it — and so is lifting a negative high end to a positive one.
///  * A complete UNDERFLOW to zero is the same case, and the smallest normal is
///    still above the true value, which is positive and tiny: zero is the only
///    bound below it the format has.
fn scaleExact(lower: f128, upper: f128, exponent: i32) Bounds {
    var lo = std.math.ldexp(lower, exponent);
    var hi = std.math.ldexp(upper, exponent);
    if (lo != 0.0 and @abs(lo) < f128_min_normal) lo = 0.0;
    if (hi != 0.0 and @abs(hi) < f128_min_normal) hi = f128_min_normal;
    return Bounds.init(lo, hi);
}

/// `mantissa * 2^exponent` for a mantissa f128 holds exactly, as an f128
/// enclosure.
fn dyadicBounds(mantissa: u64, exponent: i32) Bounds {
    const exact: f128 = @floatFromInt(mantissa);
    return scaleExact(exact, exact, exponent);
}

// ---------------------------------------------------------------------------
// A fixed-capacity integer for the n-ary lcm
// ---------------------------------------------------------------------------

/// The limbs of the odd-part accumulator.
///
/// Capacity is PROVEN against the f64 range rather than chosen by taste. Every
/// normalized f64 is `odd * 2^e` with `e >= -1074`, so an lcm whose magnitude is
/// within the f64 range — below `2^1024` — has an odd part below
/// `2^1024 * 2^1074 = 2^2098`. 34 limbs is 2176 bits, which is above that, so
/// the fold is EXACT for every lcm the f64 format can hold a magnitude of, and an
/// overflow of the accumulator is not a loss of exactness to paper over: it PROVES
/// the odd part is at least `2^2176`, so the lcm is at least `2^2176 * 2^-1074`,
/// far past `float_max`, and the answer is the overflow ray.
///
/// The limbs are used in place, only `limbs[0..len]` is ever written or read, and
/// the array is left undefined outside that window rather than zeroed.
const big_limbs = 34;

/// An unsigned integer in fixed limbs: no allocation, no heap, no growth, and a
/// fold that REPORTS overflow rather than wrapping.
///
/// The odd part of an n-ary lcm is the LCM of the ODD parts. Unlike a
/// two-argument product — where 53 + 53 bits is 106 and f128 holds it exactly — it
/// grows by up to 53 bits per argument, and by nothing at all when an argument
/// already divides what is there. That last property is why this is a fold over
/// exact integers and not over f128: a repeated argument has to divide the
/// accumulator EXACTLY for the answer to stay right, and a rounded accumulator
/// cannot be asked whether it divides anything.
const Big = struct {
    limbs: [big_limbs]u64,
    len: usize,

    /// The multiplicative identity, which is what an lcm fold starts from. Only
    /// the first limb is initialized: nothing outside `limbs[0..len]` is ever
    /// read, and zeroing 34 words to hold the value 1 is a cost this file has no
    /// reason to pay.
    fn init() Big {
        var limbs: [big_limbs]u64 = undefined;
        limbs[0] = 1;
        return .{ .limbs = limbs, .len = 1 };
    }

    /// `self * m`, or false when the result needs a limb this capacity does not
    /// have — which the caller turns into the overflow ray, since `big_limbs`
    /// exceeds the 2098 bits an in-range lcm can need.
    fn mulSmall(self: *Big, m: u64) bool {
        var carry: u128 = 0;
        for (self.limbs[0..self.len]) |*limb| {
            const product = @as(u128, limb.*) * @as(u128, m) + carry;
            limb.* = @truncate(product);
            carry = product >> 64;
        }
        if (carry != 0) {
            if (self.len == big_limbs) return false;
            self.limbs[self.len] = @truncate(carry);
            self.len += 1;
        }
        return true;
    }

    /// `self / d`, returning the remainder. `d` is never zero, and every call
    /// divides by a known divisor of `self`.
    fn divSmall(self: *Big, d: u64) u64 {
        var remainder: u128 = 0;
        var i = self.len;
        while (i > 0) {
            i -= 1;
            const current = (remainder << 64) | @as(u128, self.limbs[i]);
            self.limbs[i] = @truncate(current / d);
            remainder = current % d;
        }
        while (self.len > 1 and self.limbs[self.len - 1] == 0) self.len -= 1;
        return @truncate(remainder);
    }

    /// `self mod m`. The limbs are little-endian, so the division has to start at
    /// the MOST significant limb and work down: running it the other way rounds a
    /// partial value at 64 bits and then treats those bits as the leading ones,
    /// which is a different modulus and a wrong divisor for the next argument.
    fn modSmall(self: *const Big, m: u64) u128 {
        var remainder: u128 = 0;
        var i = self.len;
        while (i > 0) {
            i -= 1;
            remainder = ((remainder << 64) | @as(u128, self.limbs[i])) % m;
        }
        return remainder;
    }

    /// Fold one odd mantissa into an lcm: divide out what it shares with the
    /// accumulator, then multiply by it whole. Both halves are exact integer
    /// arithmetic, so an argument that already divides what is there multiplies
    /// nothing — which is the property an f128 accumulator cannot have.
    fn foldLcm(self: *Big, m: u64) bool {
        const shared = gcdU64(@intCast(self.modSmall(m)), m);
        if (shared != 1) _ = self.divSmall(shared);
        return self.mulSmall(m);
    }

    /// The number of significant bits, counting from the top of the highest
    /// non-zero limb.
    fn bitLength(self: *const Big) u32 {
        var i = self.len;
        while (i > 0) {
            i -= 1;
            const limb = self.limbs[i];
            if (limb != 0) {
                return @as(u32, @intCast(i)) * 64 + (@as(u32, 64) - @as(u32, @clz(limb)));
            }
        }
        return 0;
    }

    /// The bits of self from position `from` upwards, at most 128 of them and
    /// zero-padded above. A limb boundary is the only awkward case, so the first
    /// limb contributes its top bits and every later one contributes all 64 at the
    /// place the first left off.
    fn bitsFrom(self: *const Big, from: u32) u128 {
        var value: u128 = 0;
        var position: u32 = 0;
        const offset: u6 = @intCast(from % 64);
        var limb_index: usize = from / 64;
        var leading = true;
        while (position < 128 and limb_index < self.len) : ({
            limb_index += 1;
            leading = false;
        }) {
            if (leading and offset != 0) {
                value |= @as(u128, self.limbs[limb_index] >> offset) << @intCast(position);
                position += 64 - @as(u32, offset);
            } else {
                value |= @as(u128, self.limbs[limb_index]) << @intCast(position);
                position += 64;
            }
        }
        return value;
    }

    /// Whether any bit below position `from` is set: the discarded tail that
    /// decides whether the value above `from` is the whole of it or a little more.
    fn anyBitBelow(self: *const Big, from: u32) bool {
        const whole: usize = from / 64;
        const offset: u6 = @intCast(from % 64);
        var i: usize = 0;
        while (i < whole and i < self.len) : (i += 1) {
            if (self.limbs[i] != 0) return true;
        }
        if (offset != 0 and whole < self.len) {
            const mask = (@as(u64, 1) << offset) - 1;
            if ((self.limbs[whole] & mask) != 0) return true;
        }
        return false;
    }
};

/// `odd * 2^exponent` for an odd part too wide for one f128, as a certified f128
/// enclosure.
///
/// Two cases, and neither of them is a rounded integer offered as exact:
///
///  * At most 113 significant bits: f128 holds the coefficient exactly, so both
///    bounds are that value.
///  * More: the value is `2^shift * (head + tail)` where `head` is the top 113
///    bits, `0 <= tail < 1`, and the top bits are held exactly. The lower bound is
///    `head * 2^(exponent + shift)` — truncation toward zero, which is below the
///    value — and the upper bound is that plus one unit of the last place, or the
///    same number when the discarded tail is zero. The scale is then an exact power
///    of two, so the two coefficients become the two certified ends.
///
/// Nothing is discarded silently and no error is left for a wider f64 step to
/// absorb: what survives is the interval the two exact coefficients describe.
fn bigBounds(odd: *const Big, exponent: i32) Bounds {
    const bits = odd.bitLength();
    std.debug.assert(bits > 0);
    if (bits <= 113) {
        const exact: f128 = @floatFromInt(odd.bitsFrom(0));
        return scaleExact(exact, exact, exponent);
    }
    const shift: u32 = bits - 113;
    const head = odd.bitsFrom(shift);
    const ceiling = head + @as(u128, if (odd.anyBitBelow(shift)) 1 else 0);
    return scaleExact(
        @floatFromInt(head),
        @floatFromInt(ceiling),
        exponent + @as(i32, @intCast(shift)),
    );
}

// ---------------------------------------------------------------------------
// N-ary gcd and lcm over the reals
// ---------------------------------------------------------------------------

/// The greatest common divisor of commensurable real arguments, or `null` when
/// the image is empty.
///
/// The conventions are the ones Euclid's algorithm gives, and they are boundary
/// cases rather than special functions:
///
///  * An empty list has no gcd.
///  * `gcd(0, 0, ..., 0)` is undefined, as it is in Euclid: every number divides
///    zero, so there is no greatest one.
///  * `gcd(0, a) = |a|` for `a != 0`: zero is the identity, so a zero argument is
///    dropped and one non-zero argument left gives its magnitude.
///  * A common divisor of REAL arguments is only defined when the arguments are
///    commensurable, which two points always are: they are dyadic, hence rational,
///    hence commensurable. A box is not, so a box argument gives
///    `[0, min over arguments of the largest magnitude in it]` — a bound and not an
///    answer. Zero is its infimum, being attained by no gcd of commensurable
///    reals, and the upper bound is `|a_i|` for EVERY argument because a common
///    divisor divides each of them. A caller who needs the exact value over a box
///    is asking about commensurability, which no bound can answer.
///
/// Points are exact: the gcd of dyadics is the gcd of their ODD parts times the
/// SMALLEST power of two, both integers, so the answer is a real this file states
/// exactly rather than encloses.
pub fn gcd(xs: []const Interval) ?Interval {
    return gcdOver(Interval, xs, intervalOf);
}

/// `gcd` over any list whose elements read as an interval through `range`.
///
/// The parameterization exists so that a caller whose element type is not
/// `Interval` — a tracked value, a quantity — reaches THIS algorithm instead of
/// reimplementing it, and reaches it without materializing an array of
/// intervals: the accessor is called once per element and nothing is
/// allocated. Reimplementing it is not a neutral choice, because the exact
/// arithmetic below is what makes a wide point list exact, and a second copy of
/// it would be a second answer to the same question.
///
/// An element whose `range` is null has no value and so has no gcd with anything,
/// which is `null` for the whole list — the same answer an empty list gets, and
/// the reason a caller that tracks definedness should read `gcdDomainOver`
/// rather than infer domain from this function's `null`.
pub fn gcdOver(comptime T: type, xs: []const T, comptime range: fn (T) ?Interval) ?Interval {
    if (xs.len == 0) return null;
    const s = surveyOver(T, xs, range) orelse return null;
    if (s.all_zero) return null;
    if (s.loose) return Interval.init(0.0, looseGcdBoundOver(T, xs, range));
    return Bounds.project(dyadicBounds(s.divisor.mantissa, s.divisor.exponent));
}

/// The least common multiple of commensurable real arguments, or `null` when the
/// image is empty.
///
/// The conventions are the mirror of `gcd`'s and are deliberately NOT each other's:
/// a common multiple of zero and `a` exists for every real, so `lcm(0, a) = 0` as
/// soon as some argument is a non-zero number, while `lcm(0, ..., 0)` is `0` for
/// every number and has no LEAST one, so it is `null` as `gcd(0, 0)` is. An empty
/// list has no lcm.
///
/// Points are exact, and the odd part is folded argument by argument in exact
/// integer arithmetic: the lcm of dyadics is the lcm of their ODD parts times the
/// LARGEST power of two, and each argument's share is divided out before it is
/// multiplied in whole, so an argument that already divides the accumulator
/// contributes nothing. It is not `|prod a_i| / gcd`, which is a two-argument
/// identity that is wrong for three or more — `lcm(4, 6, 10)` is `60` while
/// `|4 * 6 * 10| / 2` is `120` — and it is not a float accumulator, which cannot
/// decide the divisibility the fold depends on.
///
/// Exactness is bounded, and the bound is arithmetic rather than a policy: see
/// `big_limbs`. An accumulator that runs out of limbs is an lcm whose magnitude
/// provably passes `float_max`, which is the overflow ray, so no approximation of
/// an inexact lcm is ever returned.
pub fn lcm(xs: []const Interval) ?Interval {
    return lcmOver(Interval, xs, intervalOf);
}

/// `lcm` over any list whose elements read as an interval through `range`; see
/// `gcdOver` for why the list is parameterized rather than handed over as
/// `[]const Interval`.
///
/// Every decision is taken over the WHOLE list, which is what the parameterization
/// must not break: the empty-list refusal, the all-zero refusal, the zero
/// extension that decides the answer outright, the point-versus-box split
/// between exact arithmetic and a bound, and the proved overflow ray.
pub fn lcmOver(comptime T: type, xs: []const T, comptime range: fn (T) ?Interval) ?Interval {
    if (xs.len == 0) return null;
    const s = surveyOver(T, xs, range) orelse return null;
    if (s.all_zero) return null;
    // The zero extension comes BEFORE any saturation: one argument that IS zero
    // makes every defined lcm exactly zero, whatever the rest of the list is.
    if (s.zero_present) return Interval.init(0.0, 0.0);
    if (s.loose) return Interval.init(looseLcmFloorOver(T, xs, range), rounding.pos_inf);
    if (s.odd_exact) return Bounds.project(bigBounds(&s.odd, s.power));
    // The fold outran its capacity, which `big_limbs` shows can only happen when
    // the magnitude is past `float_max`: every f64's dyadic exponent is at least
    // -1074 and the odd part is then at least 2^2176, so the lcm is at least
    // 2^1102 and the overflow ray is the truth rather than a guess.
    return Interval.init(rounding.float_max, rounding.pos_inf);
}

/// How much of the arguments `gcd` has an image for; see `Domain`. A box argument
/// is `maybe`: the commensurable choices inside it do have gcds, and the answer is
/// a hull of them.
pub fn gcdDomain(xs: []const Interval) Domain {
    return gcdDomainOver(Interval, xs, intervalOf);
}

/// `gcdDomain` over any list read through `range`; see `gcdOver`.
pub fn gcdDomainOver(comptime T: type, xs: []const T, comptime range: fn (T) ?Interval) Domain {
    return reduceDomainOver(T, xs, range);
}

/// How much of the arguments `lcm` has an image for; see `Domain`.
pub fn lcmDomain(xs: []const Interval) Domain {
    return lcmDomainOver(Interval, xs, intervalOf);
}

/// `lcmDomain` over any list read through `range`; see `gcdOver`.
pub fn lcmDomainOver(comptime T: type, xs: []const T, comptime range: fn (T) ?Interval) Domain {
    return reduceDomainOver(T, xs, range);
}

/// The domain of a list whose elements read as intervals through `range`.
///
/// An element with no range is `never` for the whole list, because a gcd or an lcm
/// with an argument that has no value is not a value. A box argument is `maybe`:
/// the commensurable choices inside it do have answers, and the answer is a hull of
/// them. Everything else is `always`, and an empty or all-zero list is `never`.
fn reduceDomainOver(comptime T: type, xs: []const T, comptime range: fn (T) ?Interval) Domain {
    if (xs.len == 0) return .never;
    var all_zero = true;
    var all_points = true;
    for (xs) |v| {
        const r = range(v) orelse return .never;
        if (!(r.lo == 0.0 and r.hi == 0.0)) all_zero = false;
        if (r.lo != r.hi or !std.math.isFinite(r.lo)) all_points = false;
    }
    if (all_zero) return .never;
    if (!all_points) return .maybe;
    return .always;
}

/// The accessor `gcd`, `lcm` and their domain forms use for their own element
/// type. An `Interval` is its own range, and it is never null: a boxed
/// `Interval` is a value with width, not an absent value.
fn intervalOf(v: Interval) ?Interval {
    return v;
}

/// What one pass over the arguments of a gcd or an lcm establishes.
const Survey = struct {
    /// Every argument is the point zero: the case both families refuse.
    all_zero: bool,
    /// Some argument is not a finite point, so there is no exact answer.
    loose: bool,
    /// Some argument is the point zero while another is not.
    zero_present: bool,
    /// The exact gcd fold over the non-zero point arguments.
    divisor: Dyadic,
    /// The exact odd-part lcm fold, valid while `odd_exact` holds.
    odd: Big,
    odd_exact: bool,
    /// The largest power of two among the non-zero point arguments, which is the
    /// power of two in their lcm.
    power: i32,
};

/// Read a list once for both families.
///
/// Zeros are separated from the rest rather than folded: they are the identity for
/// a gcd, and for an lcm a single zero argument decides the whole answer.
fn surveyOver(comptime T: type, xs: []const T, comptime range: fn (T) ?Interval) ?Survey {
    var s = Survey{
        .all_zero = true,
        .loose = false,
        .zero_present = false,
        .divisor = Dyadic{ .mantissa = 1, .exponent = 0 },
        .odd = Big.init(),
        .odd_exact = true,
        .power = std.math.minInt(i32),
    };
    var have_divisor = false;
    for (xs) |v| {
        const r = range(v) orelse return null;
        if (!(r.lo == 0.0 and r.hi == 0.0)) s.all_zero = false;
        if (r.lo != r.hi or !std.math.isFinite(r.lo)) {
            s.loose = true;
            continue;
        }
        const d = decompose(@abs(r.lo));
        if (d.mantissa == 0) {
            s.zero_present = true;
            continue;
        }
        s.power = @max(s.power, d.exponent);
        s.divisor = if (have_divisor)
            Dyadic{
                .mantissa = gcdU64(s.divisor.mantissa, d.mantissa),
                .exponent = @min(s.divisor.exponent, d.exponent),
            }
        else
            d;
        have_divisor = true;
        if (s.odd_exact) s.odd_exact = s.odd.foldLcm(d.mantissa);
    }
    return s;
}

/// The upper bound for a gcd over arguments that are not all points: the largest
/// magnitude each argument can take, and the smallest of those, since a common
/// divisor cannot exceed any one of the numbers it divides. A zero argument is
/// skipped, being the identity rather than a divisor.
fn looseGcdBoundOver(comptime T: type, xs: []const T, comptime range: fn (T) ?Interval) f64 {
    var bound = rounding.float_max;
    for (xs) |v| {
        const r = range(v) orelse continue;
        if (r.lo == 0.0 and r.hi == 0.0) continue;
        const largest = @max(@abs(r.lo), @abs(r.hi));
        if (largest < bound) bound = largest;
    }
    return rounding.roundUp(bound);
}

/// The lower bound for an lcm over arguments that are not all points: the largest
/// smallest-magnitude in the list. A common multiple of the arguments is at least
/// every one of them, so it is at least the smallest magnitude each argument can
/// take, and at least the largest of those. A zero argument is skipped: it decides
/// the answer outright, elsewhere.
fn looseLcmFloorOver(comptime T: type, xs: []const T, comptime range: fn (T) ?Interval) f64 {
    var lowest: f64 = 0.0;
    for (xs) |v| {
        const r = range(v) orelse continue;
        if (r.lo == 0.0 and r.hi == 0.0) continue;
        const smallest = @min(@abs(r.lo), @abs(r.hi));
        if (smallest > lowest) lowest = smallest;
    }
    return rounding.roundDown(lowest);
}

// ---------------------------------------------------------------------------
// Directed tie roundings
// ---------------------------------------------------------------------------

/// Round to the nearest integer, a tie going toward `+infinity`.
///
/// The image of an interval is the pair of its ends rounded, because the map is
/// monotone, and every value it takes is an INTEGER: `@floor` and `@ceil` return
/// exact f64, the test for a tie is an exact subtraction (`x - floor(x)` is exact
/// by Sterbenz for `x >= 1` and trivially for smaller), and the step to the
/// neighbouring integer is exact too. So there is no rounding here to widen, and
/// the answer for an integral box is that box.
///
/// The rule is NOT `floor(x + 1/2)`, and the difference is not academic: that sum
/// rounds, so at `x = 2^53 + 1` the `+ 0.5` is lost to the nearest even and the
/// answer comes out one integer too high. Reading the fraction part instead keeps a
/// large integral point on itself, which is the right answer for every f64 above
/// `2^52` because no half exists there to be a tie.
pub fn roundTiesUp(x: Interval) Interval {
    return Interval.init(tiesUpPoint(x.lo), tiesUpPoint(x.hi));
}

/// Round to the nearest integer, a tie going toward `-infinity`. The mirror of
/// `roundTiesUp` in the same way, and equally free of the `x ± 0.5` sum.
pub fn roundTiesDown(x: Interval) Interval {
    return Interval.init(tiesDownPoint(x.lo), tiesDownPoint(x.hi));
}

fn tiesUpPoint(x: f64) f64 {
    if (x >= 0.0) {
        const h = @floor(x);
        // A tie goes UP, which on this side of zero is the larger candidate.
        return unsignedZero(if (x - h >= 0.5) h + 1.0 else h);
    }
    const h = @ceil(x);
    // A tie goes UP, which on this side is the candidate h itself.
    return unsignedZero(if (h - x > 0.5) h - 1.0 else h);
}

fn tiesDownPoint(x: f64) f64 {
    if (x >= 0.0) {
        const h = @floor(x);
        return unsignedZero(if (x - h > 0.5) h + 1.0 else h);
    }
    const h = @ceil(x);
    return unsignedZero(if (h - x >= 0.5) h - 1.0 else h);
}

/// The canonical zero. `@ceil` of a negative fraction smaller than one is `-0.0`,
/// which equals `0.0` in every comparison and reads as a negative zero in a bit
/// pattern; this file publishes a positive one.
fn unsignedZero(v: f64) f64 {
    return if (v == 0.0) 0.0 else v;
}