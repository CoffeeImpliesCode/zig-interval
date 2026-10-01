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
//! That is the role of an infinity a computation PRODUCED, and it answers a
//! different question from the one an infinity answers as a stored
//! endpoint. `Interval`'s constructor gives `init(+inf, +inf)` the closed
//! overflow ray `[floatMax, +inf]` and `init(-inf, -inf)` its mirror
//! `[-inf, -floatMax]`, so a canonical interval has no lower bound at
//! `+inf` and no upper bound at `-inf`: the two infinities arrive as
//! stored bounds only in those opposite directions. Neither pair of steps
//! moves for it. A computed `+inf` is still answered by a lower bound of
//! `+floatMax` and a computed `-inf` by an upper bound of `-floatMax`,
//! exactly as above, while a stored ray endpoint is a bound in its own
//! right that wants no step at all — which is why the constructor
//! normalizes the two degenerate shapes rather than widening the steps
//! here.
//!
//! How far it widens is not the same everywhere, because what computed the
//! endpoint is not the same everywhere, and the two cases are not equally
//! established.
//!
//! For IEEE 754 addition, subtraction, multiplication, division and square
//! root, a correctly rounded result lies within half a ULP of the exact
//! value. One outward step covers that error. `interval.zig` also repairs
//! the subnormal quotients that Zig 0.16's software division flushes to
//! zero; its scaled recovery has less than one subnormal ULP of error,
//! so the same step covers it.
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

/// The smallest positive subnormal f64, bit pattern 1, and so the least
/// value above zero that the format can hold. A product or a quotient too
/// small to represent comes back as a signed zero, and under
/// round-to-nearest its true magnitude is at most half of this, so one
/// step of this size is the smallest step that puts a bound back outside a
/// value the machine has lost.
///
/// It lives here because it is a property of the layout rather than of
/// any operation, and this file is where the layout is written down: the
/// sign bit and the two zero patterns above are the same kind of fact.
/// Three files need it, each for its own reason — `interval.zig` steps a
/// bound out past a lost product, quotient or half, `interval_ext.zig`
/// takes it as a two-sided slack around a rounded zero, `vector.zig`
/// repairs a square that underflowed. Those are three policies and each
/// file keeps its own; only the pattern is shared, and three copies of
/// one bit pattern are three places for the format to be described
/// wrongly. The dependency runs this way already, since all three import
/// this file for the step beside it, so naming the constant here reaches
/// no further than a local copy did.
pub const min_subnormal: f64 = @bitCast(@as(u64, 1));

/// The two ends of the format and the last finite value below them, as bit
/// patterns rather than as `std.math.inf(f64)` and `std.math.floatMax(f64)`.
///
/// Those two accessors assemble their value one place at a time inside
/// `reconstructFloat`, and that loop is the whole of the comptime cost of
/// every comparison against them — charged once per endpoint per call, so a
/// caller that builds a table of intervals at comptime pays it per row, and
/// the benchmark tables in `bench/bench_vec.zig` are enough of them to
/// exhaust the evaluator's branch budget on their own. The four functions
/// below are where the cost is worth removing most: they are the
/// outward-rounding primitives the whole library widens its answers with, so
/// every hot path runs them, and the module doc above is what makes their
/// answer at an infinity the one that has to be right.
///
/// These are the same three numbers: `pos_inf` is `inf(f64)`, `float_max` is
/// `floatMax(f64)`, and IEEE negation is exact, so `neg_inf` and `-float_max`
/// are the other two. Only what the comparisons cost moved.
///
/// They live here for the reason `min_subnormal` above does: each is a
/// property of the layout rather than of the operation that needs it first,
/// and this file is where the layout is written down. `interval.zig` needs
/// `pos_inf` and `neg_inf` for the two canonical rays its constructor
/// normalises to, and it already imports this file for the step beside them,
/// so naming the constants here reaches no further than a local copy did —
/// while the format is described once instead of twice, and a later edit to
/// this description cannot leave a second copy disagreeing by a ULP.
pub const pos_inf: f64 = @bitCast(@as(u64, 0x7FF0_0000_0000_0000));
pub const neg_inf: f64 = -pos_inf;
pub const float_max: f64 = @bitCast(@as(u64, 0x7FEF_FFFF_FFFF_FFFF));

comptime {
    // A mistyped digit above would move the finite end of a ray by a ULP at
    // the top of the format, and every answer built on that ray moves with
    // it, so the identity is checked rather than asserted in a comment. It
    // costs three `reconstructFloat` evaluations once per translation unit,
    // against the per-call cost the patterns above exist to remove.
    @setEvalBranchQuota(2_000);
    std.debug.assert(pos_inf == std.math.inf(f64));
    std.debug.assert(neg_inf == -std.math.inf(f64));
    std.debug.assert(float_max == std.math.floatMax(f64));
}

/// Smallest f64 strictly greater than x, for an outward-rounded upper
/// bound. NaN propagates unchanged and the infinities saturate: +inf has
/// no successor, since the pattern after it is a NaN rather than a larger
/// number, and -inf lands on the largest finite negative.
pub fn nextUp(x: f64) f64 {
    if (std.math.isNan(x)) return x;
    if (x == pos_inf) return x;
    if (x == neg_inf) return -float_max;

    const bits: u64 = @bitCast(x);
    // The pair of zeros needs a guard because it is 2^63 apart in pattern
    // and adjacent in value, so a step of the pattern does not land on
    // the other zero: from 0x8000...0 this direction SUBTRACTS one and
    // reaches 0x7fff...f, whose exponent field is all ones and whose
    // significand is not zero, so it is a quiet NaN and not a number.
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
    if (x == neg_inf) return x;
    if (x == pos_inf) return float_max;

    const bits: u64 = @bitCast(x);
    // The predecessor of +0.0 is -0.0, and the pattern does not get there:
    // this direction subtracts one from 0x0000...0, which is an integer
    // overflow at the bottom of the u64 rather than a step, and it panics
    // in a checked build. The guard keeps the arithmetic inside the type
    // as well as returning the neighbour. -0.0 needs no guard of its own:
    // this direction ADDS one there and reaches 0x8000...1, the smallest
    // negative subnormal, which is the value below it.
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
    if (x == neg_inf) return -float_max;
    if (x == pos_inf) return x;
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
    if (x == neg_inf) return x;
    if (x == pos_inf) return float_max;
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
