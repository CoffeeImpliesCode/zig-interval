//! Certified enclosures of the elementary functions, in `f128`.
//!
//! Nothing here calls a `std.math` transcendental. Every answer is produced
//! by outward-rounded `f128` interval arithmetic plus an ANALYTIC remainder
//! bound for the series that was truncated, so the width of a result is
//! whatever that derivation costs and never a margin measured against a
//! second implementation of the same function. That is the whole difference
//! from `interval_ext.zig`, which widens `std.math`'s point answers by a
//! measured ULP count and therefore cannot say what it is buying.
//!
//! # The outward primitives
//!
//! `Bounds` carries the enclosure; `nextUp`/`prevDown`/`roundUp`/`roundDown`
//! below are this file's own f128 analogues of `rounding.zig`'s f64 pair, with
//! the same two rules they state. Stepping goes to the STRICT IEEE
//! neighbour, so `+0` and `-0` are two lattice points one step apart and the
//! pair needs the explicit guard. And a COMPUTED infinity is widened outward
//! to `-floatMax`/`+floatMax`, because an f128 operation only reaches an
//! infinity by overflowing and what it stands for is a finite real past the
//! end of the range — a lower bound of `+inf` would sit above that real.
//!
//! # Why division is not one step
//!
//! IEEE 754 requires `+`, `-`, `*` and `/` on binary formats to be correctly
//! rounded, so one outward step absorbs their half ULP for the first three.
//! Division in Zig 0.16 on x86-64 is not the hardware instruction:
//! `compiler_rt/divtf3.zig` normalises the quotient and then rounds it into
//! place by a shift whose count is computed as
//! `@as(u7, @intCast(1 - writtenExponent))` BEFORE the underflow test. For a
//! quotient far below the subnormal range that conversion wraps, and the
//! routine returns a subnormal for a value that must round to zero. No step
//! count covers that: the answer is not a little out, it is in the wrong
//! decade.
//!
//! So `qdiv` classifies the quotient BY EXPONENT before dividing. A quotient
//! at or above the smallest normal is handed to the runtime, whose normal
//! path is the exercised one. Anything smaller is rebuilt from normalised
//! significands: `ma / mb` with `|ma|, |mb|` in `[1, 2)` lies in `(0.5, 2]`
//! and is therefore always normal, and the exponent difference is applied
//! afterwards as a chain of exact power-of-two multiplications whose LAST
//! step is a correctly rounded IEEE multiply. The deep underflow the runtime
//! gets wrong is a case this path never enters, and the near-subnormal case
//! it gets right only by accident is one this path computes directly.
//!
//! Division corners are widened by TWO steps rather than one. `divtf3`'s own
//! comment bounds the error of the quotient it forms at "bounded away from
//! 2^-113" without claiming correct rounding, and the recovery path carries
//! one ulp from `ma / mb` plus the rounding of its final scaling. One and a
//! half ULP is under two.
//!
//! # The constants
//!
//! `pi` and `ln2` are computed at compile time by `fpAtanInv`/`fpAtanhInv`,
//! which are exact rational series evaluated in 208-bit fixed point with
//! directed rounding at EVERY step — an integer `floor` and `ceil` of each
//! term — so the integer pair they return brackets the true value by
//! construction rather than by an estimate of it. Machin's formula supplies
//! pi, `ln 2 = 2 atanh(1/3)`, and `ln 10 = 3 ln 2 + 2 atanh(1/9)`. Each
//! series stops when the next term drops below one unit of the fixed point,
//! which is what bounds the omitted tail by the first omitted term for an
//! alternating series and by `first / (1 - q^-2)` for a positive one; two
//! units of slack absorb either.
//!
//! # Phase reduction, in exact integers
//!
//! A single f128 word of pi cannot carry a phase. `pi/2` is only known to
//! about `2^-113`, so a reduction against it inherits a relative error of
//! `2^-113`, and multiplying that by a quarter-turn index of `2^125` puts the
//! error at `2^12` — the reduced argument would be nonsense.
//!
//! The reduction here does not work in floats at all. The fixed point also
//! yields a 200-bit INTEGER `veven` with `pi/2 = veven * 2^-200 + resid`
//! and `|resid|` below `2^-200`. So `x * 2^200` is exact for any f128 (it is
//! the significand shifted by an exponent), `n * veven` is exact because
//! both are integers, and their DIFFERENCE is exact too — no rounding
//! happens anywhere in forming the reduced argument, at any magnitude. The
//! one rounding is the conversion of that integer difference to f128, and it
//! lands on a number of order one, so it costs a half ulp of `2^-113` and
//! nothing grows with `|x|`.
//!
//! That is why `reduce` reaches `1.5 * 2^127` = `2.5521178e38`, past every
//! argument an `f64` can name — rather than stopping at the `2^62` that a scheme
//! requiring exact index-times-word products would allow, and why the argument
//! above which `sin`/`cos` return `[-1, 1]` is a representability limit (the
//! index outgrows what an `i128` holds) rather than a precision one.
//! The fallback is the PROVED range of both functions: an interval too long
//! to reduce contains a whole period, and a whole period of sine attains both
//! `-1` and `1`.
//!
//! # What the kernels promise
//!
//! Every monotone kernel evaluates its two endpoints and hulls them, which is
//! the exact range enclosure of a monotone function whose endpoint values are
//! enclosed. A singleton is evaluated once. The exact identities (`exp(0) =
//! 1`, `sin(0) = 0`, `log(1) = 0`, ...) are produced by explicit fast paths
//! rather than left to fall out of a series, and the `|x| <= 1/2` branches of
//! `expm1`, `log1p`, `sinh`, `tanh` and `asinh` keep RELATIVE accuracy at
//! small arguments — the property a subtraction of two nearly equal `exp`
//! values would destroy, and the reason those branches exist.

const std = @import("std");
const Interval = @import("interval.zig").Interval;
const rounding = @import("rounding.zig");


// ===========================================================================
// The f128 layout, written down once.
// ===========================================================================

/// Sign bit, the top of the 128-bit pattern.
const sign_bit: u128 = @as(u128, 1) << 127;

/// Explicit significand mask. `f128` is binary128: 112 stored significand bits
/// and so 113 of precision, 15 exponent bits, bias 16383.
const frac_mask: u128 = (@as(u128, 1) << 112) - 1;

/// Exponent field mask.
const exp_mask: u128 = @as(u128, 0x7FFF) << 112;

/// The hidden bit, at the top of the significand field.
const hidden_bit: u128 = @as(u128, 1) << 112;

const exp_bias: i32 = 16383;

/// Smallest positive subnormal, `2^-16494`. It is the width every lost
/// product, quotient, or rounding-to-zero stands for.
const min_sub: f128 = @bitCast(@as(u128, 1));

/// Largest finite value.
const float_max: f128 = @bitCast((@as(u128, 0x7FFE) << 112) | frac_mask);

const pos_inf: f128 = @bitCast(@as(u128, 0x7FFF) << 112);
const neg_inf: f128 = -pos_inf;

comptime {
    // These are properties of the layout, and every other constant in the
    // file is defined relative to one of them, so a mistyped digit here would
    // move a whole family's answers rather than one of them.
    @setEvalBranchQuota(4_000);
    std.debug.assert(min_sub == @as(f128, std.math.floatTrueMin(f128)));
    std.debug.assert(float_max == std.math.floatMax(f128));
    std.debug.assert(pos_inf == std.math.inf(f128));
    std.debug.assert(neg_inf == -std.math.inf(f128));
}

/// `2^n` as an exact `f128`, for `n` in the normal range. Built from the
/// exponent field rather than by repeated multiplication, so the result is
/// exact by construction and available at comptime.
fn pow2(n: i32) f128 {
    const e = n + exp_bias;
    std.debug.assert(e > 0 and e < 0x7FFF);
    return @bitCast(@as(u128, @intCast(e)) << 112);
}

// ===========================================================================
// Outward rounding in f128.
// ===========================================================================

/// Smallest `f128` strictly greater than `x`.
///
/// NaN propagates and the infinities saturate: `+inf` has no successor,
/// because the next pattern is a NaN rather than a larger number, and `-inf`
/// lands on the largest finite negative. The pair of signed zeros needs the
/// explicit guard — from the pattern of `-0` this direction SUBTRACTS, and
/// `0x7FFF...F` is an infinity, not a number.
fn nextUp(x: f128) f128 {
    if (std.math.isNan(x)) return x;
    if (x == pos_inf) return x;
    if (x == neg_inf) return -float_max;

    const bits: u128 = @bitCast(x);
    if (bits == sign_bit) return 0.0;

    const stepped: u128 = if (bits & sign_bit != 0) bits - 1 else bits + 1;
    return @bitCast(stepped);
}

/// Largest `f128` strictly less than `x`, the mirror of `nextUp`.
fn prevDown(x: f128) f128 {
    if (std.math.isNan(x)) return x;
    if (x == pos_inf) return float_max;
    if (x == neg_inf) return x;

    const bits: u128 = @bitCast(x);
    // +0 -> -0. The pattern does not get there: this direction subtracts one
    // from zero, which wraps at the bottom of the u128.
    if (bits == 0) return -0.0;

    const stepped: u128 = if (bits & sign_bit != 0) bits + 1 else bits - 1;
    return @bitCast(stepped);
}

/// Upper bound on a value that computed to `x`: `nextUp` at every finite
/// nonzero, and `x` at either zero, since a zero is already its own smallest
/// bound. A computed `-inf` widens to `-floatMax`.
fn roundUp(x: f128) f128 {
    if (x == neg_inf) return -float_max;
    if (x == pos_inf) return x;
    if (x == 0.0) return x;
    return nextUp(x);
}

/// Lower bound on a value that computed to `x`, the mirror of `roundUp`.
fn roundDown(x: f128) f128 {
    if (x == pos_inf) return float_max;
    if (x == neg_inf) return x;
    if (x == 0.0) return x;
    return prevDown(x);
}

// ===========================================================================
// Decomposition and rescaling.
// ===========================================================================

/// `x = mant * 2^exp` with `|mant|` in `[1, 2)` and `exp` an integer. Exact,
/// subnormals included, which the range reduction needs: a subnormal argument
/// is an ordinary argument and its exponent sits two orders of magnitude
/// below the format's.
const Split = struct {
    mant: f128,
    exp: i32,
};

fn split128(x: f128) Split {
    const bits: u128 = @bitCast(x);
    const sign = bits & sign_bit;
    const frac = bits & frac_mask;
    const ef: u32 = @intCast((bits & exp_mask) >> 112);

    if (ef != 0) {
        return .{
            .mant = @bitCast(sign | hidden_bit | frac),
            .exp = @as(i32, @intCast(ef)) - exp_bias,
        };
    }
    if (frac == 0) return .{ .mant = x, .exp = 0 };

    var m = frac;
    var e: i32 = 1 - exp_bias;
    while (m < hidden_bit) {
        m <<= 1;
        e -= 1;
    }
    return .{ .mant = @bitCast(sign | m), .exp = e };
}

/// `x * 2^k` as a chain of exact power-of-two multiplications.
///
/// Each chunk is exact while the running value stays normal, so the only
/// rounding in the chain is the one step that leaves the normal range: that
/// step rounds correctly into the subnormals, and overflows to an infinity
/// exactly where the real product does. A value that underflows to zero on a
/// chunk stays zero, and it should — the remaining chunks only make it
/// smaller.
fn scaleValue(x: f128, k: i32) f128 {
    const chunk: i32 = 4096;
    const up = pow2(chunk);
    const down = pow2(-chunk);
    var v = x;
    var rest = k;
    while (rest > chunk) {
        v *= up;
        rest -= chunk;
    }
    while (rest < -chunk) {
        v *= down;
        rest += chunk;
    }
    if (rest != 0) return v * pow2(rest);
    return v;
}

/// The exact integer `x * 2^scale`, or null when that would not fit in the
/// return type.
///
/// This is the heart of the phase reduction: it is exact because the value is
/// the significand shifted by an exponent, and both operations are on
/// integers. Nothing here rounds, at any magnitude, which is what lets the
/// reduction's answer be independent of `|x|`.
fn scaledInteger(x: f128, scale: i32) ?i512 {
    if (!std.math.isFinite(x)) return null;
    const negative = std.math.signbit(x);
    const b: u128 = @bitCast(@abs(x));
    const frac = b & frac_mask;
    const ef: u32 = @intCast((b & exp_mask) >> 112);

    var mant: u128 = undefined;
    var xe: i32 = undefined;
    if (ef != 0) {
        mant = frac | hidden_bit;
        xe = @as(i32, @intCast(ef)) - exp_bias;
    } else {
        if (frac == 0) return null;
        mant = frac;
        xe = 1 - exp_bias;
        while (mant < hidden_bit) {
            mant <<= 1;
            xe -= 1;
        }
    }

    const shift = scale + 112 - xe;
    var mag: u512 = @as(u512, mant);
    if (shift >= 0) {
        if (shift > 511) return null;
        if (mant != 0 and 112 + @as(u32, @intCast(shift)) >= 512) return null;
        mag <<= @as(u9, @intCast(shift));
    } else {
        // A negative shift means `x * 2^scale` is not an integer at all, so
        // there is nothing exact to return. Truncating instead would invent a
        // value, and the caller needs exactness.
        return null;
    }
    const v: i512 = @intCast(mag);
    return if (negative) -v else v;
}


// ===========================================================================
// Bounds.
// ===========================================================================

/// A closed interval over `f128`, canonical when `lo <= hi`, `lo` is not
/// `+inf`, `hi` is not `-inf`, and neither endpoint is a NaN — the four
/// conditions `Interval` states, for the same reasons. `init` normalises the
/// two degenerate shapes to the overflow rays, so `(+inf, +inf)` is
/// `[floatMax, +inf]`, matching what an f64 caller of `fromInterval` and
/// `project` already sees.
///
/// An infinite endpoint denotes an unbounded real set. That is why an
/// overflowed exponential is an endpoint here rather than a poison: the value
/// is real, it is past the format, and `project` maps it to the f64 ray.
pub const Bounds = struct {
    lo: f128,
    hi: f128,

    /// Build `[lo, hi]`. `lo <= hi` is a precondition, checked in the safe
    /// build modes and elided in the fast ones, exactly as `Interval.init`
    /// checks it: a NaN endpoint fails the ordering, since NaN compares false
    /// against everything, and catching that is what the check is for.
    pub fn init(lo: f128, hi: f128) Bounds {
        std.debug.assert(lo <= hi);
        return .{
            .lo = if (lo == pos_inf) float_max else lo,
            .hi = if (hi == neg_inf) -float_max else hi,
        };
    }

    /// The singleton `[x, x]`.
    pub fn point(x: f128) Bounds {
        return .{ .lo = x, .hi = x };
    }

    /// Widen an `f64` interval. Exact in both directions: every `f64` is an
    /// `f128`, and the canonical rays arrive as the rays they are.
    pub fn fromInterval(x: Interval) Bounds {
        return .{ .lo = x.lo, .hi = x.hi };
    }

    /// Bracket an `i128`, for every `i128` and not merely the ones that
    /// convert exactly.
    ///
    /// `|x| <= 2^113` is exact, because an `f128` holds every integer that
    /// small. Beyond that the conversion rounds to nearest and the rounding
    /// direction decides which side needs a step; it is read back by
    /// comparing the INTEGER `x` against the integer value of the rounded
    /// result, so no float rounding can decide it. Near the ends of `i128` the
    /// rounded result can leave the `i128` range altogether, and there the
    /// direction is already determined — a rounded value past `2^127` is
    /// certainly above every `x` — so the comparison is skipped.
    pub fn fromInt(x: i128) Bounds {
        const exact_limit: i128 = @as(i128, 1) << 113;
        const n: f128 = @floatFromInt(x);
        if (x >= -exact_limit and x <= exact_limit) return point(n);

        const int_limit: f128 = pow2(127);
        if (n >= int_limit) return Bounds.init(prevDown(n), n);
        if (n <= -int_limit) return Bounds.init(n, nextUp(n));

        const back: i128 = @intFromFloat(n);
        if (back == x) return point(n);
        if (back < x) return Bounds.init(n, nextUp(n));
        return Bounds.init(prevDown(n), n);
    }

    /// Project onto an `Interval`, outward at both ends.
    ///
    /// The directed rule the spec pins: `n = @floatCast(x)`, and a step is
    /// taken only on the side where the correctly rounded value sits on the
    /// wrong side of `x`. That is tighter than widening unconditionally and
    /// still sound, and it is why a computed zero projects to a zero rather
    /// than to a subnormal — `f128(0.0) <= x` already holds there.
    ///
    /// A bound outside the `f64` range becomes the matching `f64` infinity,
    /// which `Interval.init` turns into its overflow ray. That is right in
    /// both directions: the value is real and past the end, and a ray
    /// contains it.
    pub fn project(x: Bounds) Interval {
        return Interval.init(projectDown(x.lo), projectUp(x.hi));
    }

    /// Negation, exact in IEEE, so it needs no step.
    pub fn neg(x: Bounds) Bounds {
        return Bounds.init(-x.hi, -x.lo);
    }

    /// Magnitude. The image starts at exactly zero when `x` reaches zero,
    /// because a point of `x` maps to zero and no outward step can improve on
    /// a bound that is already there.
    pub fn abs(x: Bounds) Bounds {
        if (x.lo >= 0) return x;
        if (x.hi <= 0) return Bounds.init(-x.hi, -x.lo);
        return Bounds.init(0.0, roundUp(@max(-x.lo, x.hi)));
    }

    /// Sum, one correctly rounded addition per side plus one outward step
    /// each. Overflow to an infinity is recovered by the rounding pair, which
    /// widens a computed `-inf` to `-floatMax` and so keeps the bound outside
    /// the finite real that overflowed into it.
    pub fn add(a: Bounds, b: Bounds) Bounds {
        return Bounds.init(roundDown(a.lo + b.lo), roundUp(a.hi + b.hi));
    }

    /// Difference, a sum against a negated operand: negation is exact, so
    /// this is the same two roundings as `add`.
    pub fn sub(a: Bounds, b: Bounds) Bounds {
        return add(a, neg(b));
    }

    /// Product, as the hull of the four corners.
    ///
    /// Two repairs, both about values the format cannot hold rather than
    /// about rounding. A corner with an exactly zero factor is zero however
    /// large the other factor is, which IEEE declines to say (`0 * inf` is a
    /// NaN, and a NaN corner loses the reduction entirely), so
    /// `cornerProduct` answers it as the exact signed zero. A corner of two
    /// nonzero factors that UNDERFLOWED is a nonzero real standing in a
    /// signed zero, and no comparison can tell that zero from an attained
    /// one; so an extremum that is zero while some corner lost a magnitude
    /// is stepped out to the smallest subnormal, down for the minimum and up
    /// for the maximum — the only two places where the sign of the lost value
    /// is not needed.
    pub fn mul(a: Bounds, b: Bounds) Bounds {
        const av = [2]f128{ a.lo, a.hi };
        const bv = [2]f128{ b.lo, b.hi };
        var p: [4]f128 = undefined;
        var lost = false;
        for (0..2) |i| {
            for (0..2) |j| {
                p[2 * i + j] = cornerProduct(av[i], bv[j]);
                if (p[2 * i + j] == 0.0 and av[i] != 0.0 and bv[j] != 0.0) lost = true;
            }
        }
        var lo = @min(@min(p[0], p[1]), @min(p[2], p[3]));
        var hi = @max(@max(p[0], p[1]), @max(p[2], p[3]));
        if (lost) {
            if (lo == 0.0) lo = -min_sub;
            if (hi == 0.0) hi = min_sub;
        }
        return Bounds.init(roundDown(lo), roundUp(hi));
    }

    /// Quotient, as the hull of the four corners.
    ///
    /// A divisor that reaches zero answers the whole line, which is the same
    /// answer the f64 layer gives and the only one an enclosure can offer:
    /// the reciprocal of a vanishing magnitude has no bound in either
    /// direction. The corners go through `qdiv`, which is where the runtime's
    /// subnormal division problem is answered.
    pub fn div(a: Bounds, b: Bounds) Bounds {
        if (b.lo <= 0.0 and b.hi >= 0.0) return Bounds.init(neg_inf, pos_inf);

        const av = [2]f128{ a.lo, a.hi };
        const bv = [2]f128{ b.lo, b.hi };
        var q: [4]f128 = undefined;
        var wide = false;
        for (0..2) |i| {
            for (0..2) |j| {
                const corner = cornerQuotient(av[i], bv[j]);
                q[2 * i + j] = corner.lo;
                if (corner.hi > corner.lo) wide = true;
            }
        }
        if (wide) return Bounds.init(neg_inf, pos_inf);

        var lo = @min(@min(q[0], q[1]), @min(q[2], q[3]));
        var hi = @max(@max(q[0], q[1]), @max(q[2], q[3]));
        lo = roundDown(roundDown(lo));
        hi = roundUp(roundUp(hi));

        var lost = false;
        for (0..2) |i| {
            for (0..2) |j| {
                if (q[2 * i + j] == 0.0 and av[i] != 0.0 and bv[j] != 0.0) lost = true;
            }
        }
        if (lost) {
            if (lo == 0.0) lo = -min_sub;
            if (hi == 0.0) hi = min_sub;
        }
        return Bounds.init(lo, hi);
    }

    /// Square. Not monotone across zero, so a box spanning zero takes its
    /// minimum at zero rather than at an endpoint.
    pub fn sqr(x: Bounds) Bounds {
        if (x.lo == 0.0 and x.hi == 0.0) return x;
        const lo_sq = x.lo * x.lo;
        const hi_sq = x.hi * x.hi;
        var hi = @max(lo_sq, hi_sq);
        const lost = (lo_sq == 0.0 and x.lo != 0.0) or (hi_sq == 0.0 and x.hi != 0.0);
        if (lost and hi == 0.0) hi = min_sub;
        hi = roundUp(hi);
        if (x.lo <= 0.0 and x.hi >= 0.0) return Bounds.init(0.0, hi);
        return Bounds.init(roundDown(@min(lo_sq, hi_sq)), hi);
    }
};

/// The exact product of two corner operands, or the exact signed zero when
/// either factor is zero. See `Bounds.mul` for why the NaN IEEE would give is
/// not an answer.
fn cornerProduct(a: f128, b: f128) f128 {
    if (a == 0.0 or b == 0.0) {
        const ab: u128 = @bitCast(a);
        const bb: u128 = @bitCast(b);
        return @bitCast((ab ^ bb) & sign_bit);
    }
    return a * b;
}

/// One quotient corner, a point everywhere except at the indeterminate form.
const CornerQ = struct {
    lo: f128,
    hi: f128,
};

/// The quotient of two corner operands. `b` is nonzero. A corner where BOTH
/// operands are unbounded magnitudes is `inf / inf`, which is neither a value
/// nor a number: read as the reals the two infinities stand for, either can
/// outrun the other by any factor, so the answer is a half line. A zero over
/// an unbounded divisor is an IEEE signed zero and is kept.
fn cornerQuotient(a: f128, b: f128) CornerQ {
    if (std.math.isInf(b)) {
        if (std.math.isInf(a)) {
            const negative = std.math.signbit(a) != std.math.signbit(b);
            return if (negative)
                CornerQ{ .lo = neg_inf, .hi = 0.0 }
            else
                CornerQ{ .lo = 0.0, .hi = pos_inf };
        }
        const v = a / b;
        return .{ .lo = v, .hi = v };
    }
    const v = qdiv(a, b);
    return .{ .lo = v, .hi = v };
}

/// The quotient of two nonzero corner operands, classified before it is
/// computed. See the module doc.
fn qdiv(a: f128, b: f128) f128 {
    if (std.math.isInf(a)) return a;
    const sa = split128(a);
    const sb = split128(b);
    const d = sa.exp - sb.exp;
    // `d - 1` is the smallest exponent the quotient can carry, so this is a
    // statement about the EXACT quotient rather than about the runtime's
    // answer to it.
    if (d - 1 >= 1 - exp_bias) return a / b;
    const w = sa.mant / sb.mant; // always in (0.5, 2]: always normal
    return scaleValue(w, d);
}

/// Largest `f64` at or below `x`. The out-of-range test is strict, so an
/// `f128` that happens to equal the `f64` frontier takes the general path and
/// comes back as itself rather than as an infinity.
fn projectDown(x: f128) f64 {
    if (x > @as(f128, rounding.float_max)) return rounding.pos_inf;
    if (x < @as(f128, -rounding.float_max)) return rounding.neg_inf;
    const n: f64 = @floatCast(x);
    if (@as(f128, n) <= x) return n;
    return rounding.prevDown(n);
}

/// Smallest `f64` at or above `x`, the mirror of `projectDown`.
fn projectUp(x: f128) f64 {
    if (x > @as(f128, rounding.float_max)) return rounding.pos_inf;
    if (x < @as(f128, -rounding.float_max)) return rounding.neg_inf;
    const n: f64 = @floatCast(x);
    if (@as(f128, n) >= x) return n;
    return rounding.nextUp(n);
}

/// Hull of two enclosures.
fn hull(a: Bounds, b: Bounds) Bounds {
    return Bounds.init(@min(a.lo, b.lo), @max(a.hi, b.hi));
}

/// The whole line: a domain empty inside a function's own domain, or a
/// quotient whose divisor reaches zero.
fn wholeLine() Bounds {
    return Bounds.init(neg_inf, pos_inf);
}

const zero = Bounds.point(0.0);
const one = Bounds.point(1.0);

// ===========================================================================
// Certified constants, by exact fixed-point series at compile time.
// ===========================================================================

/// Fractional bits of the fixed point. The phase reduction needs a 200-bit
/// integer for `pi/2` and eight more bits of headroom for the residual's
/// fixed-point scale.
const fp_bits: u8 = 208;

/// True real `v` satisfies `lo / 2^fp_bits <= v <= hi / 2^fp_bits`.
///
/// Built by directed rounding at every step — an integer `floor` and `ceil` of
/// each rational term — so the bracket is a property of the arithmetic rather
/// than an estimate of it. A single unit of slack here is `2^-208`.
const Fixed = struct {
    lo: i256,
    hi: i256,
};

fn fpAdd(a: Fixed, b: Fixed) Fixed {
    return .{ .lo = a.lo + b.lo, .hi = a.hi + b.hi };
}

fn fpSub(a: Fixed, b: Fixed) Fixed {
    return .{ .lo = a.lo - b.hi, .hi = a.hi - b.lo };
}

/// Multiply by a power of two: exact, and the only scaling these formulas
/// need.
fn fpScale(a: Fixed, k: u32) Fixed {
    const s: i256 = @as(i256, 1) << @intCast(k);
    return .{ .lo = a.lo * s, .hi = a.hi * s };
}

/// `atan(1/q)` for `q >= 2`, by the alternating series
/// `sum (-1)^k / ((2k+1) q^(2k+1))`.
///
/// The loop stops when the next term falls below one unit of the fixed point,
/// which bounds the omitted alternating tail by the first omitted term
/// because the terms decrease. That is under one unit, so the two units of
/// slack added at the end absorb it with room to spare.
fn fpAtanInv(q: u32) Fixed {
    // This series is walked at compile time, and the default quota of 1000
    // branch evaluations does not cover it: dozens of terms of 256-bit
    // arithmetic with two divisions each. The quota belongs HERE rather than
    // around the container's initialisers, because the loop runs in this
    // function's scope and a caller's quota does not govern a callee's.
    @setEvalBranchQuota(2_000_000);

    const unit: u256 = @as(u256, 1) << fp_bits;
    const q2: u256 = @as(u256, q) * q;
    var qpow: u256 = q; // q^(2k+1)
    var acc: Fixed = .{ .lo = 0, .hi = 0 };
    var k: u32 = 0;
    while (k < 512) : (k += 1) {
        const odd: u256 = 2 * @as(u256, k) + 1;
        if (odd > std.math.maxInt(u256) / qpow) break;
        const d = odd * qpow;
        if (d >= unit) break;
        const flo: i256 = @intCast(unit / d);
        const cei: i256 = @intCast((unit + d - 1) / d);
        acc = fpAdd(acc, if (k % 2 == 0)
            Fixed{ .lo = flo, .hi = cei }
        else
            Fixed{ .lo = -cei, .hi = -flo });
        if (qpow > std.math.maxInt(u256) / q2) break;
        qpow *= q2;
    }
    return .{ .lo = acc.lo - 2, .hi = acc.hi + 2 };
}

/// `atanh(1/q)` for `q >= 2`, by the positive series
/// `sum 1 / ((2k+1) q^(2k+1))`.
///
/// The same stopping rule. A positive series has no alternating cancellation
/// to bound its tail, so the bound is geometric: the terms shrink by `q^-2`
/// and the tail after the last included one is at most the first omitted term
/// divided by `1 - q^-2`. At the smallest `q` used here that factor is `9/8`,
/// so the same two units of slack still cover it.
fn fpAtanhInv(q: u32) Fixed {
    // See `fpAtanInv`: the quota has to be raised in the scope that walks the
    // loop, which is this one.
    @setEvalBranchQuota(2_000_000);

    const unit: u256 = @as(u256, 1) << fp_bits;
    const q2: u256 = @as(u256, q) * q;
    var qpow: u256 = q;
    var acc: Fixed = .{ .lo = 0, .hi = 0 };
    var k: u32 = 0;
    while (k < 512) : (k += 1) {
        const odd: u256 = 2 * @as(u256, k) + 1;
        if (odd > std.math.maxInt(u256) / qpow) break;
        const d = odd * qpow;
        if (d >= unit) break;
        const flo: i256 = @intCast(unit / d);
        const cei: i256 = @intCast((unit + d - 1) / d);
        acc = fpAdd(acc, .{ .lo = flo, .hi = cei });
        if (qpow > std.math.maxInt(u256) / q2) break;
        qpow *= q2;
    }
    return .{ .lo = acc.lo - 2, .hi = acc.hi + 2 };
}

/// `pi / 2`, by Machin's formula `8 atan(1/5) - 2 atan(1/239)`.
const half_pi_fixed: Fixed = fpSub(
    fpScale(fpAtanInv(5), 3),
    fpScale(fpAtanInv(239), 1),
);

/// `ln 2`, as `2 atanh(1/3)`.
const ln2_fixed: Fixed = fpScale(fpAtanhInv(3), 1);

/// `ln 10`, as `3 ln 2 + 2 atanh(1/9)`: `10 = 8 * (5/4)` and
/// `ln(5/4) = 2 atanh(1/9)`.
const ln10_fixed: Fixed = fpAdd(
    fpAdd(fpScale(ln2_fixed, 1), ln2_fixed),
    fpScale(fpAtanhInv(9), 1),
);

/// Convert a fixed-point bracket to `f128` bounds.
///
/// `@floatFromInt` rounds the integer and the power-of-two scale that follows
/// is exact, so the conversion carries at most a half ulp of relative error.
/// Two outward steps each way turn that into a bound: the composed relative
/// error is below `2^-111` and two steps move by `2^-112`, so the result sits
/// outside the true value on both sides.
fn fixedToBounds(f: Fixed) Bounds {
    const scale = pow2(-@as(i32, fp_bits));
    const lo = @as(f128, @floatFromInt(f.lo)) * scale;
    const hi = @as(f128, @floatFromInt(f.hi)) * scale;
    return Bounds.init(roundDown(roundDown(lo)), roundUp(roundUp(hi)));
}

/// True pi. Used by every kernel that has to know where a quarter turn is.
/// The range reduction below does NOT use it, because one f128 word of pi
/// cannot carry a phase — see the module doc.
pub const pi: Bounds = fixedToBounds(fpScale(half_pi_fixed, 1));

/// True natural logarithm of two.
pub const ln2: Bounds = fixedToBounds(ln2_fixed);

/// True natural logarithm of ten. Private, because it is only ever a divisor.
const ln10: Bounds = fixedToBounds(ln10_fixed);

/// `pi / 2`, by an exact halving.
const half_pi: Bounds = Bounds.init(pi.lo / 2.0, pi.hi / 2.0);

/// `pi / 4`, by an exact halving.
const quarter_pi: Bounds = Bounds.init(pi.lo / 4.0, pi.hi / 4.0);

// --- The 200-bit integer and residual the phase reduction works with. ---

/// Fractional bits of the integer `pi / 2` below.
const veven_bits: u8 = 200;

/// How far the fixed point sits below the integer scale, as a shift amount.
const residual_shift: u9 = @intCast(fp_bits - veven_bits);

/// `floor(pi/2 * 2^veven_bits)`, or a lower bound on it. Taken from the fixed
/// point's own lower end and truncated, so it never exceeds the true value;
/// `phase_residual` absorbs whatever that costs.
const veven: u256 = @intCast(half_pi_fixed.lo >> residual_shift);

/// `pi/2 - veven * 2^-veven_bits`, as a bracket.
///
/// Subtracting the exact integer sum from the fixed-point bracket makes this
/// correct even when `veven` is a strict lower bound on the true floor: the
/// difference simply shows up at the lower end. Its width is one unit of
/// `2^-200` plus the fixed point's own few units of `2^-208`, so it is below
/// `2^-199`.
const phase_residual: Bounds = blk: {
    const scale = pow2(-@as(i32, fp_bits));
    const sum: i256 = @intCast(veven << residual_shift);
    const lo: i256 = half_pi_fixed.lo - sum;
    const hi: i256 = half_pi_fixed.hi - sum;
    break :blk Bounds.init(
        @as(f128, @floatFromInt(lo)) * scale,
        @as(f128, @floatFromInt(hi)) * scale,
    );
};

/// `1 / ln 2`, for the exponential's range reduction.
///
/// A `comptime_float` literal, so it carries about 64 significand bits rather
/// than 113 — and that is enough here, because the only consequence of a
/// coarse index is that the reduced argument `x - k ln 2` comes out near
/// `2 ln 2` instead of near `ln 2/2`. That is a worse-conditioned Taylor
/// argument, not a wrong one: the tail bound is evaluated from the actual
/// `|r|`, and at `2 ln 2` with 36 terms it is still below `2^-125`. The
/// trigonometric index has no such luxury and is divided exactly instead; see
/// `reduce`.
const inv_ln2: f128 = 1.44269504088896340735992468100189214;

// ===========================================================================
// Series with analytic remainder bounds.
// ===========================================================================

/// Tail of `sum_{k>=N+1} x^k/k!` for `|x| <= r`: since
/// `k! >= (N+1)! (N+2)^(k-N-1)` for `k >= N+1`, the tail is at most
/// `r^(N+1)/(N+1)! * 1/(1 - r/(N+2))`.
fn expTail(r: f128, n: u32) f128 {
    var p: f128 = 1.0;
    for (0..n + 1) |_| p *= r;
    var fact: f128 = 1.0;
    for (2..(n + 2)) |k| fact *= @floatFromInt(k);
    return p / fact / (1.0 - r / @as(f128, @floatFromInt(n + 2)));
}

/// `exp(x)` by Taylor, with `expTail` added to both ends.
///
/// The reduced argument is at most `ln 2` when the index is the nearest one,
/// and at most `2 ln 2 = 1.3863` when a coarse `1/ln 2` has put it one step
/// out, which is the worst case `expPoint` can hand over — see `inv_ln2`. The
/// count is set from the WORST of those, not the typical one: 40 terms put the
/// tail at `1.3863^41 / 41! / (1 - 1.3863/42)`, which is `3.1e-44`, against
/// the `9.6e-35` that the rounding of the accumulation already costs. At 36
/// terms it would be `1.9e-38` against `2.4e-38` — under, but not by enough
/// to want to rely on. Both radii are far inside the `N+2` that makes the
/// factorial bound finite at all.
fn expSeries(x: Bounds) Bounds {
    const terms: u32 = 40;
    var sum = Bounds.point(1.0);
    var term = Bounds.point(1.0);
    var k: u32 = 1;
    while (k <= terms) : (k += 1) {
        term = Bounds.div(Bounds.mul(term, x), Bounds.fromInt(k));
        sum = Bounds.add(sum, term);
    }
    const t = expTail(@max(@abs(x.lo), @abs(x.hi)), terms);
    return Bounds.init(roundDown(sum.lo - t), roundUp(sum.hi + t));
}

/// `expm1(x)` by its own Taylor series, for the arguments where
/// `exp(x) - 1` would lose the argument to cancellation.
///
/// The sum is dominated by its first term `x`, and every rounding in the
/// accumulation is RELATIVE to that sum, so a small argument comes back with
/// a small relative width. Forming `exp(x) - 1` at `x = 2^-100` would instead
/// return a bound `2^-100` wide around a value of size `2^-100`.
fn expm1Series(x: Bounds) Bounds {
    const terms: u32 = 36;
    var sum = x;
    var term = x;
    var k: u32 = 2;
    while (k <= terms) : (k += 1) {
        term = Bounds.div(Bounds.mul(term, x), Bounds.fromInt(k));
        sum = Bounds.add(sum, term);
    }
    // The `expm1` tail after `terms` terms is the `exp` tail after the same
    // terms, which bounds it: the two differ only by the tail of the constant
    // and linear terms, both of which are zero here.
    const t = expTail(@max(@abs(x.lo), @abs(x.hi)), terms);
    return Bounds.init(roundDown(sum.lo - t), roundUp(sum.hi + t));
}

/// `2 atanh(f) = 2 sum f^(2k+1)/(2k+1)` for `|f| <= 1/3`, plus the geometric
/// tail `2 f^(2K+3) / ((2K+3)(1 - f^2))`.
///
/// Successive terms have ratio `f^2`, so the tail is bounded by the first
/// omitted term divided by `1 - f^2`; at `|f| = 1/3` that is `9/8` times it.
/// 40 terms put that below `2^-137`, far under what the accumulation costs.
fn atanhSeries(f: Bounds) Bounds {
    const terms: u32 = 40;
    const f2 = Bounds.sqr(f);
    var fpow = f;
    var sum = f; // k = 0, divided by one
    var k: u32 = 1;
    while (k <= terms) : (k += 1) {
        fpow = Bounds.mul(fpow, f2);
        sum = Bounds.add(sum, Bounds.div(fpow, Bounds.fromInt(2 * @as(i128, k) + 1)));
    }
    const r = @max(@abs(f.lo), @abs(f.hi));
    var p: f128 = 1.0;
    for (0..(2 * terms + 4)) |_| p *= r;
    const t = 2.0 * p / @as(f128, @floatFromInt(2 * terms + 3)) / (1.0 - r * r);
    const s = Bounds.mul(sum, Bounds.point(2.0));
    return Bounds.init(roundDown(s.lo - t), roundUp(s.hi + t));
}

/// `atan(x)` by its alternating series, for `|x| <= 1/2`, plus the
/// alternating tail `|x|^(2N+3)/(2N+3)`. 62 terms put that below `2^-131` at
/// `|x| = 1/2`.
fn atanSeries(x: Bounds) Bounds {
    const terms: u32 = 62;
    const x2 = Bounds.sqr(x);
    var xpow = x;
    var sum = x;
    var k: u32 = 1;
    while (k <= terms) : (k += 1) {
        xpow = Bounds.mul(xpow, x2);
        const t = Bounds.div(xpow, Bounds.fromInt(2 * @as(i128, k) + 1));
        sum = if (k % 2 == 1) Bounds.sub(sum, t) else Bounds.add(sum, t);
    }
    const r = @max(@abs(x.lo), @abs(x.hi));
    var p: f128 = 1.0;
    for (0..(2 * terms + 4)) |_| p *= r;
    const t = p / @as(f128, @floatFromInt(2 * terms + 3));
    return Bounds.init(roundDown(sum.lo - t), roundUp(sum.hi + t));
}

/// `sinh(x) = x * sum x^(2k)/(2k+1)!` for `|x| <= 1/2`.
///
/// Factored by `x` on purpose. The result is `x` times a number near one, so
/// every rounding inside is relative to `x` and the answer keeps a small
/// RELATIVE width at a small argument.
fn sinhSeries(x: Bounds) Bounds {
    const terms: u32 = 16;
    const x2 = Bounds.sqr(x);
    var term = Bounds.point(1.0);
    var sum = Bounds.point(1.0);
    var k: u32 = 0;
    while (k < terms) : (k += 1) {
        const d = @as(i128, 2 * k + 3) * @as(i128, 2 * k + 2);
        term = Bounds.div(Bounds.mul(term, x2), Bounds.fromInt(d));
        sum = Bounds.add(sum, term);
    }
    // Tail: sum_{k>=terms} x^(2k)/(2k+1)! <= r^(2 terms)/(2 terms+1)! /
    // (1 - r^2 / ((2 terms+2)(2 terms+3))), then multiplied by r for the
    // factor x outside.
    const r = @max(@abs(x.lo), @abs(x.hi));
    var p: f128 = 1.0;
    for (0..(2 * terms)) |_| p *= r;
    var fact: f128 = 1.0;
    for (2..(2 * terms + 2)) |j| fact *= @floatFromInt(j);
    const d0 = @as(f128, @floatFromInt((2 * terms + 2) * (2 * terms + 3)));
    const t = p / fact / (1.0 - r * r / d0) * r;
    const s = Bounds.mul(x, sum);
    return Bounds.init(roundDown(s.lo - t), roundUp(s.hi + t));
}

/// `sin(r)` for `|r| <= pi/4`, by Taylor, with the alternating tail
/// `|r|^(2N+1)/(2N+1)!`.
fn sinSeries(r: Bounds) Bounds {
    const terms: u32 = 18;
    const r2 = Bounds.sqr(r);
    var rpow = r;
    var sum = r;
    var k: u32 = 1;
    while (k <= terms) : (k += 1) {
        var fact: f128 = 1.0;
        for (2..(2 * k + 2)) |j| fact *= @floatFromInt(j);
        rpow = Bounds.mul(rpow, r2);
        const t = Bounds.div(rpow, Bounds.point(fact));
        sum = if (k % 2 == 1) Bounds.sub(sum, t) else Bounds.add(sum, t);
    }
    const a = @max(@abs(r.lo), @abs(r.hi));
    var p: f128 = 1.0;
    for (0..(2 * terms + 1)) |_| p *= a;
    var fact: f128 = 1.0;
    for (2..(2 * terms + 2)) |j| fact *= @floatFromInt(j);
    const t = p / fact;
    return Bounds.init(roundDown(sum.lo - t), roundUp(sum.hi + t));
}

/// `cos(r)` for `|r| <= pi/4`, by Taylor, with the alternating tail
/// `|r|^(2N+2)/(2N+2)!`.
fn cosSeries(r: Bounds) Bounds {
    const terms: u32 = 18;
    const r2 = Bounds.sqr(r);
    var rpow = Bounds.point(1.0);
    var sum = Bounds.point(1.0);
    var k: u32 = 1;
    while (k <= terms) : (k += 1) {
        var fact: f128 = 1.0;
        for (2..(2 * k + 1)) |j| fact *= @floatFromInt(j);
        rpow = Bounds.mul(rpow, r2);
        const t = Bounds.div(rpow, Bounds.point(fact));
        sum = if (k % 2 == 1) Bounds.sub(sum, t) else Bounds.add(sum, t);
    }
    const a = @max(@abs(r.lo), @abs(r.hi));
    var p: f128 = 1.0;
    for (0..(2 * terms + 2)) |_| p *= a;
    var fact: f128 = 1.0;
    for (2..(2 * terms + 3)) |j| fact *= @floatFromInt(j);
    const t = p / fact;
    return Bounds.init(roundDown(sum.lo - t), roundUp(sum.hi + t));
}

// ===========================================================================
// Exponential family.
// ===========================================================================

/// Above this the exponential is past the format: `2^16385` overflows f128,
/// so any argument at or above `16385 ln 2` has an exponential that does.
/// Derived from the certified `ln 2` rather than quoted, so the threshold and
/// the bound it is used with come from the same number.
const exp_overflow_cut: f128 = @as(f128, 16385.0) * ln2.hi;

/// Below this the exponential underflows: `2^-16495` is half the smallest
/// subnormal, so any argument under `-16495 ln 2` has an exponential below
/// that and the only `f128` the answer can name is zero — while the real
/// value is still strictly positive. That is why the answer is
/// `[0, min_sub]` and not the singleton zero.
const exp_underflow_cut: f128 = @as(f128, -16495.0) * ln2.lo;

/// `exp(x)`. Increasing, so the image is the hull of the two endpoint images,
/// and a singleton is evaluated once.
pub fn exp(x: Bounds) Bounds {
    if (x.lo == x.hi) return expPoint(x.lo);
    return hull(expPoint(x.lo), expPoint(x.hi));
}

fn expPoint(v: f128) Bounds {
    if (v == 0.0) return one;
    if (std.math.isNan(v)) return Bounds.point(v);
    if (v >= exp_overflow_cut) return Bounds.init(pos_inf, pos_inf);
    if (v <= exp_underflow_cut) return Bounds.init(0.0, min_sub);

    // `x = k ln 2 + r`, `k` an integer. The index need NOT be the nearest
    // one: `r` is an enclosure formed against the TRUE ln 2, so whichever `k`
    // came out, the identity `exp(x) = 2^k exp(r)` holds inside it. All the
    // reduction needs is a bound on `|r|`, and `|r| <= ln 2/2 + ln 2/2 = ln 2
    // < 0.7` is one, well inside the series' proven radius.
    const q = v * inv_ln2;
    const kf = roundHalfAway(q);
    const k: i128 = @intFromFloat(kf);
    const r = Bounds.sub(Bounds.point(v), Bounds.mul(Bounds.fromInt(k), ln2));
    return scaleBounds(expSeries(r), @intCast(k));
}

/// The nearest integer to `x` as a float, half away from zero.
///
/// `@round` is not used: there is no `roundf128` in this tree's compiler_rt,
/// whereas `@trunc` is backed by `truncq`. The fractional part is exact by
/// Sterbenz, so the comparison is not deciding on a rounded quantity.
fn roundHalfAway(x: f128) f128 {
    const t = @trunc(x);
    const f = x - t;
    if (f >= 0.5) return t + 1.0;
    if (f <= -0.5) return t - 1.0;
    return t;
}

/// `2^x`. Reduces on the integer part of `x`, which is exact by Sterbenz for
/// every `x`, so the split itself carries no error.
pub fn exp2(x: Bounds) Bounds {
    if (x.lo == x.hi) return exp2Point(x.lo);
    return hull(exp2Point(x.lo), exp2Point(x.hi));
}

fn exp2Point(v: f128) Bounds {
    if (v == 0.0) return one;
    if (std.math.isNan(v)) return Bounds.point(v);
    if (v >= 16385.0) return Bounds.init(pos_inf, pos_inf);
    if (v <= -16495.0) return Bounds.init(0.0, min_sub);

    const kf = roundHalfAway(v);
    const k: i128 = @intFromFloat(kf);
    const r = Bounds.sub(Bounds.point(v), Bounds.point(kf));
    // 2^r = exp(r ln 2), and |r| <= 1/2 keeps that inside the proven radius.
    return scaleBounds(expSeries(Bounds.mul(r, ln2)), @intCast(k));
}

/// `expm1(x)`.
pub fn expm1(x: Bounds) Bounds {
    if (x.lo == x.hi) return expm1Point(x.lo);
    return hull(expm1Point(x.lo), expm1Point(x.hi));
}

fn expm1Point(v: f128) Bounds {
    if (v == 0.0) return zero;
    if (std.math.isNan(v)) return Bounds.point(v);
    if (v >= exp_overflow_cut) return Bounds.init(pos_inf, pos_inf);
    if (v <= exp_underflow_cut) return Bounds.point(-1.0);

    if (@abs(v) <= 0.5) return expm1Series(Bounds.point(v));

    // Away from zero the subtraction cannot cancel: `exp(v)` differs from one
    // by at least `exp(1/2) - 1 = 0.6487`, so the exponential's absolute error
    // is already a small RELATIVE error of the result.
    return Bounds.sub(expPoint(v), one);
}

// ===========================================================================
// Logarithm family.
// ===========================================================================

/// `ln x` at a point, for `x > 0`.
///
/// Binary reduction: `x = m 2^e` with `m` in `[1, 2)` is exact, and
/// `ln m = 2 atanh((m-1)/(m+1))` with the reduced argument in `[0, 1/3]`.
/// Forming the reduction factor from `m` rather than computing `1 - x` is
/// what keeps the answer relative-accurate near one.
fn logPoint(v: f128) Bounds {
    if (v == pos_inf) return Bounds.point(pos_inf);
    if (v == neg_inf) return Bounds.point(neg_inf);
    const s = split128(v);
    const m = Bounds.point(s.mant);
    const f = Bounds.div(Bounds.sub(m, one), Bounds.add(m, one));
    return Bounds.add(Bounds.mul(Bounds.fromInt(s.exp), ln2), atanhSeries(f));
}

fn logKernel(x: Bounds) Bounds {
    if (x.lo == x.hi) return logPoint(x.lo);
    return hull(logPoint(x.lo), logPoint(x.hi));
}

/// `ln x`, clipped to the part of its domain that is present.
///
/// An argument whose upper end reaches zero has no valid part, and the answer
/// is the whole line: the image of `(0, infinity)` is the reals. An argument
/// that reaches zero only at its lower end keeps the unbounded half, which is
/// the honest clip rather than a refusal.
pub fn log(x: Bounds) Bounds {
    var lo = x.lo;
    if (lo <= 0.0) lo = neg_inf;
    if (x.hi <= 0.0) return wholeLine();
    if (lo == x.hi) return logPoint(lo);
    return hull(logPoint(lo), logPoint(x.hi));
}

/// `log2 x`. The division by `ln 2` is a correctly rounded quotient of two
/// known bounds, so it costs its own outward steps and nothing else.
pub fn log2(x: Bounds) Bounds {
    return Bounds.div(log(x), ln2);
}

/// `log10 x`.
pub fn log10(x: Bounds) Bounds {
    return Bounds.div(log(x), ln10);
}

/// `log(1 + x)`, for `x > -1`. Three branches, and the small one is the one
/// that matters.
///
/// Forming `1 + x` and taking a logarithm destroys a small argument outright:
/// below `2^-113` the sum rounds to one and the answer is zero for a function
/// whose value is `x`. So `|x| <= 1/2` goes straight into the atanh series
/// with `f = x/(2 + x)`, which never forms a difference. The other two have
/// no cancellation left to avoid — for `x > 1/2` the argument is above `1.5`,
/// and for `x < -1/2` the substitution `y = -x/(1+x)` sends the problem to a
/// positive `y`.
pub fn log1p(x: Bounds) Bounds {
    var lo = x.lo;
    if (x.hi <= -1.0) return wholeLine();
    if (lo <= -1.0) lo = neg_inf;
    if (lo == x.hi) return log1pPoint(lo);
    return hull(log1pPoint(lo), log1pPoint(x.hi));
}

fn log1pPoint(v: f128) Bounds {
    if (v == 0.0) return zero;
    if (std.math.isNan(v)) return Bounds.point(v);
    if (v == pos_inf) return Bounds.point(pos_inf);
    if (v == neg_inf) return Bounds.point(neg_inf);

    if (@abs(v) <= 0.5) {
        const p = Bounds.point(v);
        return atanhSeries(Bounds.div(p, Bounds.add(Bounds.point(2.0), p)));
    }
    if (v > 0.5) return logPoint(1.0 + v);
    // -1 < v <= -1/2. With `y = -v/(1+v)` we get `1 + y = 1/(1+v)` exactly in
    // the reals, so `log(1+v) = -log(1+y)`. `y` is at least one here, so
    // neither `1+y` nor its logarithm has any cancellation left in it.
    const den = 1.0 + v;
    const y = -v / den;
    return Bounds.neg(logPoint(1.0 + y));
}

// ===========================================================================
// Trigonometric family.
// ===========================================================================

/// Past this the quarter-turn index no longer fits an `i128`, which holds
/// magnitudes below `2^127`. The index is `n = x * 2/pi`, so the limit on `|x|`
/// is `2^127 * pi/2 = 1.5708 * 2^127`; this stops at `1.5 * 2^127`, which puts
/// the index at `0.637 * 1.5 * 2^127 = 0.955 * 2^127` and leaves a factor of
/// two in hand. Nothing here is a precision limit: the reduction is exact in
/// integers and its error does not grow with `|x|` at all.
const reduce_limit: f128 = pow2(127) * 1.5;

/// An argument reduced against a quarter turn, and which quarter turn it was.
const Reduced = struct {
    r: Bounds,
    n: i128,
};

/// `x` reduced to `r = x - n pi/2` with `|r| <= pi/4`, as tightly as the
/// certified `pi` allows.
///
/// The quarter-turn index is an INTEGER DIVISION, not a floating quotient,
/// and that is not an optimisation. `x * 2^200` is exact for every f128, and
/// so is the ratio of that integer against `veven` to within `2^-72` at the
/// largest argument the limit admits — so the index is right, or off by one
/// where the true quotient sits within `2^-72` of a half-integer. Dividing in
/// floating point instead would need `2/pi` to a precision that grows with
/// the index, and no f128 word has it: a `comptime_float` literal holds about
/// 64 significand bits, which is an index error of `2^62` at `|x| = 2^126`.
///
/// The off-by-one is then CHECKED rather than trusted. Measuring `r` catches
/// it — a wrong index lands the reduced argument near `pi/2` instead of near
/// zero — and a correction step fixes it. Two steps are allowed because the
/// correction is itself a measurement and that measurement is bounded, not
/// because two are expected.
///
/// An argument already inside a quarter turn skips all of it: `n = 0` and
/// `r = x`, which is also what keeps the integer scaling in range, since
/// `scaledInteger` is only exact once the argument is large enough to need a
/// reduction at all.
fn reduce(x: f128) Reduced {
    const a = @abs(x);
    if (a <= quarter_pi.hi) return .{ .r = Bounds.point(x), .n = 0 };

    // Unreachable for an argument this size: `scaledInteger` is exact from a
    // quarter turn up, and the limit caps the shift at 312. The fallback is
    // the unreduced argument, which the series still encloses correctly.
    const xs = scaledInteger(x, @as(i32, veven_bits)) orelse
        return .{ .r = Bounds.point(x), .n = 0 };

    var n = nearestQuarterTurns(xs);
    var out = reduceOnce(xs, n);
    var fixups: u8 = 0;
    while (fixups < 2) {
        if (out.r.lo > quarter_pi.lo) {
            n += 1;
            out = reduceOnce(xs, n);
            fixups += 1;
        } else if (out.r.hi < -quarter_pi.lo) {
            n -= 1;
            out = reduceOnce(xs, n);
            fixups += 1;
        } else break;
    }
    return out;
}

/// `veven` as a signed integer, for the index division.
const veven_signed: i512 = @intCast(veven);

/// The integer nearest `xs / veven`, which is the quarter-turn index.
///
/// Truncating division and a remainder comparison, so the result is exact. The
/// divisor is positive and the remainder takes the sign of the dividend, so a
/// single pair of comparisons rounds a truncation toward zero in either
/// direction.
fn nearestQuarterTurns(xs: i512) i128 {
    const q: i512 = @divTrunc(xs, veven_signed);
    const twice = 2 * (xs - q * veven_signed);
    if (twice >= veven_signed) return @intCast(q + 1);
    if (twice <= -veven_signed) return @intCast(q - 1);
    return @intCast(q);
}

/// The reduction itself, on the already-exact integer `x * 2^200`. See the
/// module doc: `n * veven` is exact because both are integers, their
/// difference is exact, and the single rounding is the conversion of that
/// difference to f128 — which lands on a number of order one, so nothing here
/// grows with `|x|`.
fn reduceOnce(xs: i512, n: i128) Reduced {
    const scale: i32 = @as(i32, veven_bits);
    const scaled: i512 = xs - @as(i512, n) * veven_signed;

    const v = @as(f128, @floatFromInt(scaled)) * pow2(-scale);
    // `@floatFromInt` rounded; two steps turn a half-ulp conversion error into
    // a bound, and the residual term below is applied inside that.
    var r = Bounds.init(roundDown(roundDown(v)), roundUp(roundUp(v)));

    // `pi/2 = veven * 2^-scale + residual`, so the residual's contribution is
    // `n * residual`. `n` here is the exact integer converted to f128, whose
    // relative error is below `2^-113`; times a residual below `2^-199` that
    // is under `2^-186` in absolute terms, an order of magnitude below the
    // rounding of the term itself, and the extra step already taken covers it.
    const nf = Bounds.point(@as(f128, @floatFromInt(n)));
    r = Bounds.sub(r, Bounds.mul(nf, phase_residual));
    r = Bounds.init(roundDown(r.lo), roundUp(r.hi));
    return .{ .r = r, .n = n };
}

/// `sin` of a reduced argument, quadrant applied.
fn sinReduced(rd: Reduced) Bounds {
    return switch (@mod(rd.n, 4)) {
        0 => sinSeries(rd.r),
        1 => cosSeries(rd.r),
        2 => Bounds.neg(sinSeries(rd.r)),
        else => Bounds.neg(cosSeries(rd.r)),
    };
}

/// `cos` of a reduced argument, quadrant applied.
fn cosReduced(rd: Reduced) Bounds {
    return switch (@mod(rd.n, 4)) {
        0 => cosSeries(rd.r),
        1 => Bounds.neg(sinSeries(rd.r)),
        2 => Bounds.neg(cosSeries(rd.r)),
        else => sinSeries(rd.r),
    };
}

/// `[-1, 1]`, the proved range of both `sin` and `cos`.
fn unitRange() Bounds {
    return Bounds.init(-1.0, 1.0);
}

/// True when the reduction cannot be attempted: a non-finite endpoint, or one
/// past the limit at which the quarter-turn index stops being representable.
fn unresolvable(lo: f128, hi: f128) bool {
    if (!std.math.isFinite(lo) or !std.math.isFinite(hi)) return true;
    return @abs(lo) > reduce_limit or @abs(hi) > reduce_limit;
}

/// True when the boundaries strictly between two quarter-turn indices include
/// an ODD one — the points where sine turns round.
fn crossesOddBoundary(a: i128, b: i128) bool {
    if (a == b) return false;
    const first = @min(a, b) + 1;
    const last = @max(a, b);
    if (last - first >= 1) return true; // two or more consecutive integers
    return @mod(first, 2) == 1;
}

/// The mirror for `cos`, whose turning points are the EVEN quarter turns.
fn crossesEvenBoundary(a: i128, b: i128) bool {
    if (a == b) return false;
    const first = @min(a, b) + 1;
    const last = @max(a, b);
    if (last - first >= 1) return true;
    return @mod(first, 2) == 0;
}

/// `sin`, which is not monotone and so is not in general the hull of its
/// endpoint values.
///
/// Three shapes. A singleton is one reduction. An argument at least a whole
/// period long contains a complete period, whose image is exactly `[-1, 1]`.
/// Otherwise the two endpoints are reduced; in the same quarter turn the
/// function is monotone across what is left of it, so the hull of the two
/// endpoint values IS the range. If the quarter turns differ, at least one
/// boundary is crossed, and whether that boundary is a zero or a turning point
/// is DETECTED rather than assumed: a single crossed boundary is a turning
/// point exactly when its index is odd, and two or more crossed boundaries
/// contain an odd one.
pub fn sin(x: Bounds) Bounds {
    if (x.lo == x.hi) return sinPoint(x.lo);
    if (unresolvable(x.lo, x.hi)) return unitRange();
    if (roundDown(x.hi - x.lo) >= Bounds.add(pi, pi).lo) return unitRange();

    const a = reduce(x.lo);
    const b = reduce(x.hi);
    if (a.n == b.n) return hull(sinReduced(a), sinReduced(b));
    if (crossesOddBoundary(a.n, b.n)) return unitRange();
    return hull(sinReduced(a), sinReduced(b));
}

fn sinPoint(v: f128) Bounds {
    if (unresolvable(v, v)) return unitRange();
    return sinReduced(reduce(v));
}

/// `cos`, by the same three shapes with the turning-point parity swapped.
pub fn cos(x: Bounds) Bounds {
    if (x.lo == x.hi) return cosPoint(x.lo);
    if (unresolvable(x.lo, x.hi)) return unitRange();
    if (roundDown(x.hi - x.lo) >= Bounds.add(pi, pi).lo) return unitRange();

    const a = reduce(x.lo);
    const b = reduce(x.hi);
    if (a.n == b.n) return hull(cosReduced(a), cosReduced(b));
    if (crossesEvenBoundary(a.n, b.n)) return unitRange();
    return hull(cosReduced(a), cosReduced(b));
}

fn cosPoint(v: f128) Bounds {
    if (unresolvable(v, v)) return unitRange();
    return cosReduced(reduce(v));
}

/// `tan`.
///
/// A pole is a zero of the cosine, and it is found rather than hoped about. An
/// interval longer than `pi` contains a pole whatever the arithmetic says,
/// because consecutive poles are `pi` apart. Inside that length the reduced
/// cosine is consulted: it vanishes only where the reduced argument is zero
/// with an odd quarter-turn index, which is precisely a pole, and `cos`'s own
/// enclosure reports it as a bound containing zero.
pub fn tan(x: Bounds) Bounds {
    if (x.lo == x.hi) return tanPoint(x.lo);
    if (!std.math.isFinite(x.lo) or !std.math.isFinite(x.hi)) return wholeLine();
    if (@abs(x.lo) > reduce_limit or @abs(x.hi) > reduce_limit) return wholeLine();
    if (roundDown(x.hi - x.lo) >= pi.lo) return wholeLine();

    const a = reduce(x.lo);
    const b = reduce(x.hi);
    if (a.n != b.n and crossesOddBoundary(a.n, b.n)) return wholeLine();

    const s = hull(sinReduced(a), sinReduced(b));
    const c = hull(cosReduced(a), cosReduced(b));
    if (c.lo <= 0.0 and c.hi >= 0.0) return wholeLine();
    return Bounds.div(s, c);
}

fn tanPoint(v: f128) Bounds {
    if (!std.math.isFinite(v)) return wholeLine();
    if (@abs(v) > reduce_limit) return wholeLine();
    const rd = reduce(v);
    const c = cosReduced(rd);
    if (c.lo <= 0.0 and c.hi >= 0.0) return wholeLine();
    return Bounds.div(sinReduced(rd), c);
}

/// `asin`, clipped to `[-1, 1]`.
///
/// The composition is `atan(x / sqrt(1 - x^2))`, and `|x| = 1` needs no branch
/// of its own: there the square root is zero, the argument is a whole line,
/// and the arctangent of a whole line is the whole of `[-pi/2, pi/2]`, which
/// is the answer.
pub fn asin(x: Bounds) Bounds {
    const lo = @max(x.lo, -1.0);
    const hi = @min(x.hi, 1.0);
    if (lo > hi) return Bounds.init(-half_pi.hi, half_pi.hi);
    if (lo == hi) return asinPoint(lo);
    return hull(asinPoint(lo), asinPoint(hi));
}

fn asinPoint(v: f128) Bounds {
    if (v == 0.0) return zero;
    if (v >= 1.0) return half_pi;
    if (v <= -1.0) return Bounds.neg(half_pi);
    const p = Bounds.point(v);
    const s = sqrt(Bounds.sub(one, Bounds.sqr(p)));
    return atan(Bounds.div(p, s));
}

/// `acos`, as `pi/2 - asin`. The identity is exact and it is the stable
/// direction: `asin` is the one with the series in it.
pub fn acos(x: Bounds) Bounds {
    const lo = @max(x.lo, -1.0);
    const hi = @min(x.hi, 1.0);
    if (lo > hi) return Bounds.init(0.0, pi.hi);
    return Bounds.sub(half_pi, asin(Bounds.init(lo, hi)));
}

/// `atan`, monotone and increasing, so the hull of the endpoint images.
pub fn atan(x: Bounds) Bounds {
    if (x.lo == x.hi) return atanPoint(x.lo);
    return hull(atanPoint(x.lo), atanPoint(x.hi));
}

fn atanPoint(v: f128) Bounds {
    if (std.math.isNan(v)) return Bounds.point(v);
    if (v == pos_inf) return half_pi;
    if (v == neg_inf) return Bounds.neg(half_pi);
    if (v == 0.0) return zero;

    const ax = Bounds.point(@abs(v));
    const a = @abs(v);
    var r: Bounds = undefined;
    if (a <= 0.5) {
        r = atanSeries(ax);
    } else if (a <= 1.0) {
        // atan(a) = pi/4 - atan((1-a)/(1+a)); the reduced argument is in
        // [0, 1/3].
        r = Bounds.sub(quarter_pi, atanSeries(Bounds.div(Bounds.sub(one, ax), Bounds.add(one, ax))));
    } else if (a <= 3.0) {
        // atan(a) = pi/4 + atan((a-1)/(a+1)); the reduced argument is in
        // [0, 1/2], which the series' proven radius covers.
        r = Bounds.add(quarter_pi, atanSeries(Bounds.div(Bounds.sub(ax, one), Bounds.add(ax, one))));
    } else {
        r = Bounds.sub(half_pi, atanSeries(Bounds.div(one, ax)));
    }
    return if (v < 0.0) Bounds.neg(r) else r;
}

/// `atan2`, in the `[-pi, pi]` convention.
///
/// The plane is cut into the three regions the formula actually distinguishes
/// — `x > 0`, `x < 0`, and `x = 0` — and each is answered by its own
/// identity. `x = 0` is a separate region because `atan(y/0)` is a whole line
/// whose arctangent is the whole of `[-pi/2, pi/2]`, which contains the
/// answer `+/-pi/2` but is not it, and an exact pole deserves the exact value.
/// The `x < 0` region splits again on the sign of `y`, since the formula adds
/// `pi` on one side and subtracts it on the other.
pub fn atan2(y: Bounds, x: Bounds) Bounds {
    var parts: [4]Bounds = undefined;
    var n: usize = 0;

    if (x.hi > 0.0) {
        const xa = @max(x.lo, min_sub);
        if (xa <= x.hi) {
            parts[n] = atan(Bounds.div(y, Bounds.init(xa, x.hi)));
            n += 1;
        }
    }
    if (x.lo < 0.0) {
        const xb = @min(x.hi, -min_sub);
        if (x.lo <= xb) {
            const nx = Bounds.init(x.lo, xb);
            if (y.lo >= 0.0) {
                parts[n] = Bounds.add(atan(Bounds.div(y, nx)), pi);
                n += 1;
            } else if (y.hi < 0.0) {
                parts[n] = Bounds.sub(atan(Bounds.div(y, nx)), pi);
                n += 1;
            } else {
                parts[n] = Bounds.add(atan(Bounds.div(Bounds.init(0.0, y.hi), nx)), pi);
                n += 1;
                parts[n] = Bounds.sub(atan(Bounds.div(Bounds.init(y.lo, 0.0), nx)), pi);
                n += 1;
            }
        }
    }
    if (x.lo <= 0.0 and x.hi >= 0.0) {
        if (y.lo > 0.0) {
            parts[n] = half_pi;
            n += 1;
        } else if (y.hi < 0.0) {
            parts[n] = Bounds.neg(half_pi);
            n += 1;
        } else {
            parts[n] = Bounds.init(-half_pi.hi, half_pi.hi);
            n += 1;
        }
    }

    if (n == 0) return wholeLine();
    var acc = parts[0];
    for (parts[1..n]) |p| acc = hull(acc, p);
    return acc;
}

// ===========================================================================
// Hyperbolic family.
// ===========================================================================

/// `sinh`.
pub fn sinh(x: Bounds) Bounds {
    if (x.lo == x.hi) return sinhPoint(x.lo);
    return hull(sinhPoint(x.lo), sinhPoint(x.hi));
}

fn sinhPoint(v: f128) Bounds {
    if (v == 0.0) return zero;
    if (std.math.isNan(v)) return Bounds.point(v);
    if (std.math.isInf(v)) return Bounds.point(if (v > 0.0) pos_inf else neg_inf);
    if (@abs(v) <= 0.5) return sinhSeries(Bounds.point(v));
    // (e^a - e^-a)/2. Away from zero there is no cancellation to avoid, and
    // an overflow to an infinity on the large side is a real answer.
    const a = expPoint(@abs(v));
    const half = Bounds.div(Bounds.sub(a, Bounds.div(one, a)), Bounds.point(2.0));
    return if (v < 0.0) Bounds.neg(half) else half;
}

/// `cosh`. `(e^x + e^-x)/2` has no cancellation to avoid at any argument, and
/// overflow to an infinity is a real answer rather than a failure.
pub fn cosh(x: Bounds) Bounds {
    if (x.lo == x.hi) return coshPoint(x.lo);
    return hull(coshPoint(x.lo), coshPoint(x.hi));
}

fn coshPoint(v: f128) Bounds {
    if (v == 0.0) return one;
    if (std.math.isNan(v)) return Bounds.point(v);
    if (std.math.isInf(v)) return Bounds.point(pos_inf);
    return Bounds.div(Bounds.add(expPoint(v), expPoint(-v)), Bounds.point(2.0));
}

/// `tanh`, monotone and bounded, so the hull of the two endpoint images.
pub fn tanh(x: Bounds) Bounds {
    if (x.lo == x.hi) return tanhPoint(x.lo);
    return hull(tanhPoint(x.lo), tanhPoint(x.hi));
}

fn tanhPoint(v: f128) Bounds {
    if (v == 0.0) return zero;
    if (std.math.isNan(v)) return Bounds.point(v);
    if (v == pos_inf) return Bounds.point(1.0);
    if (v == neg_inf) return Bounds.point(-1.0);

    const a = @abs(v);
    const ax = Bounds.point(a);
    var m: Bounds = undefined;
    if (a <= 0.5) {
        // sinh/cosh, with sinh in its factored series so the quotient inherits
        // a relative width from `v`.
        const num = sinhSeries(ax);
        const e = exp(ax);
        const den = Bounds.div(Bounds.add(e, Bounds.div(one, e)), Bounds.point(2.0));
        m = Bounds.div(num, den);
    } else if (a <= 100.0) {
        const e = exp(ax);
        const inv = Bounds.div(one, e);
        const num = Bounds.div(Bounds.sub(e, inv), Bounds.point(2.0));
        const den = Bounds.div(Bounds.add(e, inv), Bounds.point(2.0));
        m = Bounds.div(num, den);
    } else {
        // Beyond here both exponentials overflow, so `sinh/cosh` would be
        // `inf/inf` — a NaN where the answer is `1 - 10^-200`. The
        // `1 - 2/(e^(2a) + 1)` form has only one large quantity, and the
        // subtraction recovery in `floorBelowOne` is what makes its lower
        // bound a bound.
        const e = exp(Bounds.mul(ax, Bounds.point(2.0)));
        const two_over = Bounds.div(Bounds.point(2.0), Bounds.add(e, one));
        m = Bounds.init(floorBelowOne(1.0 - two_over.hi), roundUp(1.0 - two_over.lo));
    }
    m = if (v < 0.0) Bounds.neg(m) else m;
    return clipUnit(m);
}

/// The largest `f128` at or below `1 - d`, for a `d >= 0`.
///
/// `u = 1 - d` computed in f128 rounds, and the rounded value can sit ABOVE
/// the real `1 - d` — the one situation where a plain `roundDown` is not a
/// bound, because `roundDown(1.0)` is `1.0` and `1.0` bounds nothing below
/// one. The lattice settles it: when the rounded value IS one, the largest
/// f128 below `1 - d` is the predecessor of one, whatever `d` is.
fn floorBelowOne(u: f128) f128 {
    if (u >= 1.0) return prevDown(1.0);
    return roundDown(u);
}

/// `tanh` never attains `+/-1`, so its image is clipped inside the open
/// interval, with the clipped end at the strict predecessor of one.
fn clipUnit(t: Bounds) Bounds {
    var lo = t.lo;
    var hi = t.hi;
    if (hi > 1.0) hi = 1.0;
    if (lo >= 1.0) lo = prevDown(1.0);
    if (lo <= -1.0) lo = -1.0;
    if (hi < -1.0) hi = -1.0;
    if (lo > hi) return zero;
    return Bounds.init(lo, hi);
}

/// `atanh`, for `|x| < 1`.
///
/// Two forms, split on where the subtraction would start costing accuracy.
/// `0.5 ln((1+x)/(1-x))` is good for `|x| >= 1/4`, because the ratio is then at
/// least `5/3` and the logarithm is of a number well away from one. Below
/// that the ratio is `1 + 2x + O(x^2)` and forming it throws `x` away, so the
/// series is used, where every rounding is relative to `x`.
pub fn atanh(x: Bounds) Bounds {
    const lo = @max(x.lo, -1.0);
    const hi = @min(x.hi, 1.0);
    if (lo > hi) return wholeLine();
    if (lo == hi) return atanhPoint(lo);
    return hull(atanhPoint(lo), atanhPoint(hi));
}

fn atanhPoint(v: f128) Bounds {
    if (v == 0.0) return zero;
    if (std.math.isNan(v)) return Bounds.point(v);
    if (v >= 1.0) return Bounds.point(pos_inf);
    if (v <= -1.0) return Bounds.point(neg_inf);
    const p = Bounds.point(v);
    if (@abs(v) < 0.25) return atanhSeries(p);
    const ratio = Bounds.div(Bounds.add(one, p), Bounds.sub(one, p));
    return Bounds.mul(logKernel(ratio), Bounds.point(0.5));
}

fn atanhKernel(x: Bounds) Bounds {
    if (x.lo == x.hi) return atanhPoint(x.lo);
    return hull(atanhPoint(x.lo), atanhPoint(x.hi));
}

/// `asinh`.
///
/// For `|x| <= 1` it is `atanh(x / sqrt(1 + x^2))`, which never overflows and
/// keeps a small argument small. Beyond that the inner ratio would approach
/// one, and `atanh` of one is an infinity where `asinh` is a logarithm of
/// `2|x|`; so there the identity `asinh(x) = ln|x| + ln(1 + sqrt(1 +
/// 1/x^2))` is used, whose only large quantity is the logarithm itself.
pub fn asinh(x: Bounds) Bounds {
    if (x.lo == x.hi) return asinhPoint(x.lo);
    return hull(asinhPoint(x.lo), asinhPoint(x.hi));
}

fn asinhPoint(v: f128) Bounds {
    if (v == 0.0) return zero;
    if (std.math.isNan(v)) return Bounds.point(v);
    if (std.math.isInf(v)) return Bounds.point(if (v > 0.0) pos_inf else neg_inf);
    const p = Bounds.point(v);
    if (@abs(v) <= 1.0) {
        const s = sqrt(Bounds.add(one, Bounds.sqr(p)));
        return atanhKernel(Bounds.div(p, s));
    }
    const inv2 = Bounds.div(one, Bounds.sqr(p));
    const s = sqrt(Bounds.add(one, inv2));
    return Bounds.add(logKernel(p), logKernel(Bounds.add(one, s)));
}

/// `acosh`, for `x >= 1`. `ln(x + sqrt(x^2 - 1))` overflows on the square for
/// every large argument, so the factored form `ln x + ln(1 + sqrt(1 -
/// 1/x^2))` is used throughout; it is exact at `x = 1`, where the second term
/// is `ln 1`.
pub fn acosh(x: Bounds) Bounds {
    if (x.hi < 1.0) return Bounds.init(0.0, pos_inf);
    const lo = @max(x.lo, 1.0);
    if (lo == x.hi) return acoshPoint(lo);
    return hull(acoshPoint(lo), acoshPoint(x.hi));
}

fn acoshPoint(v: f128) Bounds {
    if (v <= 1.0) return zero;
    if (std.math.isNan(v)) return Bounds.point(v);
    if (std.math.isInf(v)) return Bounds.point(pos_inf);
    const p = Bounds.point(v);
    const inv2 = Bounds.div(one, Bounds.sqr(p));
    const s = sqrt(Bounds.sub(one, inv2));
    return Bounds.add(logKernel(p), logKernel(Bounds.add(one, s)));
}

// ===========================================================================
// Roots and integer powers.
// ===========================================================================

/// `sqrt(x)`, by a plain Newton iteration followed by a certified error
/// bound.
///
/// The hardware square root is not available for `f128` here: `@sqrt` lowers
/// to `llvm.sqrt.f128`, which has no `compiler_rt` implementation in this tree
/// and would need libquadmath at link time. So the root is computed, and then
/// CERTIFIED — the two halves are different kinds of work and only the second
/// one is what makes the answer an enclosure.
///
/// The iteration is the usual `y <- (y + m/y)/2` on a normalised `m` in
/// `[1, 4)`, in plain `f128` and with no interval bookkeeping at all. That is
/// deliberate. Iterated INTERVAL Newton was the obvious choice and it does not
/// work from a wide bracket: the mean-value operator `x - f(x)/f'([a,b])`
/// contracts only once `f'([a,b])` is a narrow band, so from `[1, 2)` its
/// image is wider than its input and intersecting with the old bracket
/// returns the old bracket unchanged — the iteration makes no progress at
/// all while every intermediate number stays plausible. Interval BISECTION
/// would work and costs one bit of width per step, so a full 113. The plain
/// iteration is quadratic and costs a dozen.
///
/// The certificate is Newton's own error estimate, which is a theorem rather
/// than a measurement. For `f(x) = x^2 - m` on an interval where `f'` does
/// not change sign, the mean value theorem gives `f(y) - f(r) = f'(xi)(y - r)`
/// for a `xi` between `y` and `r`, so `|y - r| = |f(y)| / f'(xi)`. The root
/// lies in `[1, 2)` because `m` is in `[1, 4)`, and every iterate lies there
/// too — `(y + m/y)/2 >= sqrt(m)` by the arithmetic-geometric mean inequality,
/// and the sequence decreases — so `f'(xi) = 2 xi >= 2` and
/// `|y - r| <= |y^2 - m| / 2`. That bound is evaluated in INTERVAL
/// arithmetic, so it accounts for the rounding of the iterations themselves,
/// for their stagnation, and for the rounding of the subtraction: whatever
/// the plain arithmetic did, what is divided by two is an enclosure of the
/// true residual. Twelve iterations from a relative error of a third put that
/// below `2^-113`, and the loop is bounded rather than conditional.
pub fn sqrt(x: Bounds) Bounds {
    var lo = x.lo;
    if (lo < 0.0) lo = 0.0;
    if (x.hi < 0.0) return Bounds.init(0.0, pos_inf);
    if (lo == x.hi) return sqrtPoint(lo);
    return hull(sqrtPoint(lo), sqrtPoint(x.hi));
}

fn sqrtPoint(v: f128) Bounds {
    if (v == 0.0) return zero;
    if (v == pos_inf) return Bounds.point(pos_inf);

    const s = split128(v);
    var m = s.mant;
    var e = s.exp;
    if (@mod(e, 2) != 0) {
        // Exact: doubling needs no more than the 113 bits already there, and
        // it takes `m` from `[1, 2)` to `[2, 4)`.
        m *= 2.0;
        e -= 1;
    }
    // Now `v = m 2^e` with `e` even and `m` in `[1, 4)`, so
    // `sqrt(v) = 2^(e/2) sqrt(m)` and `sqrt(m)` lies in `[1, 2)`.
    // Iterate plainly, then certify. See the `sqrt` doc for why the plain
    // form is the one that converges here, and for the mean-value theorem
    // behind the error bound.
    var y: f128 = 1.5;
    var k: u8 = 0;
    while (k < 12) : (k += 1) y = 0.5 * (y + m / y);

    const residual = Bounds.init(roundDown(y * y - m), roundUp(y * y - m));
    const err = Bounds.div(Bounds.abs(residual), Bounds.point(2.0));
    const root = Bounds.add(Bounds.point(y), Bounds.neg(err));
    return scaleBounds(root, @divTrunc(e, 2));
}

/// `cbrt(x)` through the certified logarithm and exponential.
///
/// `exp(log(x)/3)` is the composition the contract allows, chosen over Newton
/// for a reason about proof rather than speed: the logarithm is already a
/// proved enclosure, the division by three is a correctly rounded quotient of
/// two known bounds, and the exponential is a proved enclosure of a number
/// within `O(ln x 2^-113)` of the true cube root. Nothing in that chain is a
/// claim about a runtime's rounding, and the sign of a negative argument is
/// handled by `cbrtPoint`'s oddness branch, so the parity needs no branch on a
/// degree at all.
///
/// The interval case is then the simplest thing in this file: the cube root is
/// strictly increasing on ALL of the reals, so the image of a box is the hull
/// of its two endpoint images and there is nothing to clip and nothing to
/// case on. Clipping the lower end to zero — which is what `sqrt` above has to
/// do, because ITS domain starts there — would silently drop half the image of
/// every box that reaches below zero, since `cbrtPoint` would never see the
/// negative endpoint and its oddness branch would never fire. A ray is not a
/// special case either: `cbrtPoint(-inf)` routes through the oddness branch to
/// `cbrtPoint(+inf)`, and `Bounds.init` turns the mirrored pair of infinities
/// back into the canonical ray.
pub fn cbrt(x: Bounds) Bounds {
    if (x.lo == x.hi) return cbrtPoint(x.lo);
    return hull(cbrtPoint(x.lo), cbrtPoint(x.hi));
}

fn cbrtPoint(v: f128) Bounds {
    if (v == 0.0) return zero;
    if (v == pos_inf) return Bounds.point(pos_inf);
    if (v < 0.0) return Bounds.neg(cbrtPoint(-v));
    return exp(Bounds.div(logPoint(v), Bounds.point(3.0)));
}

/// `x^n` for a non-negative integer `n`.
///
/// The box is split at zero FIRST, and that is the whole correctness
/// argument. Raising an interval to a power by repeated squaring is an
/// enclosure only when the interval does not straddle zero, because the map
/// is not monotone across it: squaring `[-2, 3]` gives `[0, 9]` and then
/// multiplying that back gives a hull whose corners no longer attain its
/// extrema, since one factor changes sign. Splitting leaves `[-2, 0]` and
/// `[0, 3]`, each monotone under `x -> x^n` for EVERY `n`, and each handled
/// correctly by repeated squaring. The parity then needs no case at all:
/// squaring a non-positive box gives a non-negative one, and multiplying it
/// back carries the sign of an odd power on its own. `n = 0` is the constant
/// one, at a zero base included.
pub fn powUnsigned(x: Bounds, n: u64) Bounds {
    if (n == 0) return one;
    var acc: ?Bounds = null;
    if (x.lo < 0.0) {
        acc = powOnMonotone(Bounds.init(x.lo, @min(x.hi, 0.0)), n);
    }
    if (x.hi > 0.0) {
        const p = powOnMonotone(Bounds.init(@max(x.lo, 0.0), x.hi), n);
        acc = if (acc) |old| hull(old, p) else p;
    }
    return acc orelse zero;
}

/// Repeated squaring on a box that does not straddle zero.
fn powOnMonotone(x: Bounds, n: u64) Bounds {
    var result = one;
    var base = x;
    var e = n;
    while (e != 0) {
        if (e & 1 == 1) result = Bounds.mul(result, base);
        e >>= 1;
        if (e != 0) base = Bounds.sqr(base);
    }
    return result;
}

// ===========================================================================
// Rescaling a bound.
// ===========================================================================

/// Multiply an enclosure by `2^k`, as a chain of exact power-of-two
/// multiplications on each endpoint. Only the final chunk of each chain can
/// round, and it rounds correctly into the subnormals.
fn scaleBounds(x: Bounds, k: i32) Bounds {
    return Bounds.init(
        roundDown(scaleValue(x.lo, k)),
        roundUp(scaleValue(x.hi, k)),
    );
}
