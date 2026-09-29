//! Outward-directed rounding for rigorous interval arithmetic.
//!
//! Zig 0.16 has no directed rounding: `@round` is round-to-nearest, and
//! `@floor`, `@ceil`, `@trunc` snap to a representable value rather than to
//! its neighbour. `nextUp` and `prevDown` are therefore the only way an
//! operation can round outward, and every operation in the library widens
//! its result with them and nothing else.
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
//! against exact arithmetic, every one of them landed within roughly
//! 1.1 ULP, with `tanh` the worst at 1.07, which is past what one step
//! absorbs. Those results are widened by two steps instead, so a primitive
//! would have to be more than a full ULP out to escape the bound.
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
