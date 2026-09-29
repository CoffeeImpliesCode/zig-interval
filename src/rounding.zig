//! Outward-directed rounding for rigorous interval arithmetic.
//!
//! Zig 0.16 has no directed rounding: `@round` is round-to-nearest, and
//! `@floor`, `@ceil`, `@trunc` snap to a representable value rather than to
//! its neighbour. Stepping to an adjacent representable value is therefore
//! the only way an operation can round outward, and every operation in the
//! library widens its result with a step and nothing else.
//!
//! Two pairs of steps exist, and they answer different questions.
//! `roundUp` and `roundDown` bound a value outward: the smallest f64 at or
//! above the argument, the largest f64 at or below it. Those are what a
//! computed interval endpoint needs. `nextUp` and `prevDown` are the strict
//! neighbours, and they answer the question a caller who wants the adjacent
//! value is asking.
//!
//! The two pairs differ only at the pair of signed zeros, where the
//! non-strict form keeps the sign it was handed because the argument is
//! already its own bound: a step upward from -0.0 crosses zero and comes
//! back as +0.0, which is a different number than the one that was
//! bounded.
//!
//! At the infinities the two agree, and the agreement is load-bearing
//! rather than incidental. A computed infinity is usually not a value at
//! all: an f64 operation reaches one only by overflowing, and what it
//! stands for is a finite real past the end of the range. An upper bound
//! of -inf is then below the very value it is meant to enclose, and a
//! lower bound of +inf is above it, so the step at those two ends goes
//! outward to -floatMax and +floatMax, which are outside both the real
//! past the range and the infinity itself. Reading an infinity as a value
//! to be stepped inward from is the mistake, and it is a silent one: the
//! result still looks like a bound.
//!
//! How far it widens is not the same everywhere, because what computed the
//! endpoint is not the same everywhere, and the two cases are not equally
//! established.
//!
//! For the operations IEEE 754 defines as correctly rounded — addition,
//! subtraction, multiplication, division and square root — the computed
//! result is the nearest representable one to the exact result, so it lies
//! within half a ULP of it. A single outward step strictly overshoots that
//! error and the widened bound is a guarantee. That is the case the
//! arithmetic in `interval.zig` is in.
//!
//! For the elementary functions the premise fails: the `std.math`
//! primitives behind them carry no documented error bound. Measured
//! against exact arithmetic, a sample of the point primitives landed
//! within roughly 1.1 ULP, with `tanh` the worst at 1.07, which is past
//! what one step absorbs. Those results are widened by two steps
//! instead, so a primitive would have to be more than a full ULP out to
//! escape the bound.
//!
//! That sample is not a bound on the family, and one primitive is a
//! standing counterexample: `std.math.pow` reaches the integer part of
//! its exponent by repeated squaring, whose relative error doubles per
//! bit, so it is 1.52 ULP at an ordinary exponent and grows without
//! bound in the exponent. `powf` therefore does not call it at all, and
//! evaluates its corners through this file's own rigor instead. See
//! `interval_ext.zig`.
//!
//! That second figure is a margin chosen from measurement, not a proof of
//! it. A rigorous guarantee for the elementary functions would need a
//! correctly rounded or formally verified implementation of each one,
//! which this library does not provide. `interval_ext.zig` records the
//! measurement.

const std = @import("std");

/// Top bit of the f64 layout, set on every negative value.
const sign_bit: u64 = 1 << 63;

/// Pattern of +0.0.
const pos_zero: u64 = 0;

/// Pattern of -0.0. It compares equal to +0.0, so only the pattern
/// identifies it, and the pattern neighbour lies on the wrong side of it.
const neg_zero: u64 = sign_bit;

/// Smallest f64 strictly greater than x, for an outward-rounded upper
/// bound. NaN propagates unchanged and the infinities saturate: +inf has
/// no successor, since the pattern after it is a NaN rather than a larger
/// number, and -inf lands on the largest finite negative.
pub fn nextUp(x: f64) f64 {
    if (std.math.isNan(x)) return x;
    if (x == std.math.inf(f64)) return x;
    if (x == -std.math.inf(f64)) return -std.math.floatMax(f64);

    const bits: u64 = @bitCast(x);
    // Stepping the pattern of -0.0 would give the smallest negative
    // subnormal, which is below -0.0, so the pair of zeros needs a guard.
    if (bits == neg_zero) return 0.0;

    // Patterns ascend with the value for positives and descend for
    // negatives. Subnormals follow the same order, contiguously.
    const stepped: u64 = if (bits & sign_bit != 0) bits - 1 else bits + 1;
    return @bitCast(stepped);
}

/// Largest f64 strictly less than x, for an outward-rounded lower bound.
/// NaN propagates unchanged and the infinities saturate: -inf has no
/// predecessor, since the pattern after it is the largest finite negative
/// rather than a smaller number, and +inf lands on that value.
pub fn prevDown(x: f64) f64 {
    if (std.math.isNan(x)) return x;
    if (x == -std.math.inf(f64)) return x;
    if (x == std.math.inf(f64)) return std.math.floatMax(f64);

    const bits: u64 = @bitCast(x);
    // The predecessor of +0.0 is -0.0, not the smallest positive
    // subnormal, which is above zero. -0.0 needs no guard of its own:
    // stepping its pattern gives the smallest negative subnormal.
    if (bits == pos_zero) return -0.0;

    const stepped: u64 = if (bits & sign_bit != 0) bits + 1 else bits - 1;
    return @bitCast(stepped);
}

/// The outward-rounding UPPER bound on a value that computed to x: the
/// smallest f64 that is >= x, widened at the two infinities.
///
/// At every finite nonzero value this is nextUp. At the two zeros it is x
/// instead, because a zero is already its own smallest bound and the step
/// would cross it: roundUp(-0.0) is -0.0, not +0.0.
///
/// At -inf the step is outward, not inward, and that is the whole reason
/// this function exists beside nextUp. An f64 computation only reaches
/// -inf by overflowing, and the exact result it stands for is then a
/// finite real below -floatMax, not a real infinity at all. -inf is below
/// every real, so it is not an upper bound of any of them, and a bound of
/// [-inf, -inf] excludes the value that overflowed into it. -floatMax is
/// above every real past the end of the range, and it is also above -inf
/// itself, so it bounds both cases and is the tightest f64 that does.
/// +inf needs no such care: it is an upper bound of everything.
///
/// NaN propagates unchanged, the pattern and all.
pub fn roundUp(x: f64) f64 {
    if (x == -std.math.inf(f64)) return -std.math.floatMax(f64);
    if (x == std.math.inf(f64)) return x;
    // Either zero: -0.0 is >= itself, and +0.0 is the pattern nextUp
    // returns, whose successor is a step wider than the bound needs.
    if (x == 0.0) return x;
    return nextUp(x);
}

/// The outward-rounding LOWER bound on a value that computed to x: the
/// largest f64 that is <= x, widened at the two infinities.
///
/// At every finite nonzero value this is prevDown. At the two zeros it is
/// x instead: roundDown(+0.0) is +0.0, not -0.0, for the same reason
/// roundUp(-0.0) is -0.0.
///
/// At +inf the step is outward, for the mirror of roundUp's reason: a
/// computed +inf stands for a finite real above +floatMax, and +inf is
/// above every real and so is not a lower bound of any of them, while
/// +floatMax is below both that real and +inf itself. -inf needs no care.
///
/// NaN propagates unchanged, the pattern and all.
pub fn roundDown(x: f64) f64 {
    if (x == -std.math.inf(f64)) return x;
    if (x == std.math.inf(f64)) return std.math.floatMax(f64);
    // Either zero: +0.0 is <= itself, and -0.0 is the pattern prevDown
    // returns, whose predecessor is a step wider than the bound needs.
    if (x == 0.0) return x;
    return prevDown(x);
}

/// Lower bound on pi, certified for interval range reduction: the f64
/// nearest pi, which is below the true 3.14159265358979323846...
pub fn piDown() f64 {
    return @floatCast(std.math.pi);
}

/// Upper bound on pi, certified for interval range reduction: the smallest
/// f64 above the nearest one, which is above the true value.
pub fn piUp() f64 {
    return nextUp(piDown());
}
