//! The real scalar catalog: exact Rational normalization, rational powers and
//! roots, base logarithms, order statistics, sign, positive modulo, dyadic gcd/lcm,
//! and directed tie roundings.
//!
//! Grounded in exact algebraic witnesses, discrete parity rules, and rigorous
//! interval containment. No approximations against f64 transcendental estimates,
//! no declarations-count or source-text testing, and no arbitrary ULP width pins.

const std = @import("std");
const interval = @import("interval");
const Interval = interval.Interval;
const ext = interval.ext;
const Rational = interval.Rational;

const inf = std.math.inf(f64);
const float_max = std.math.floatMax(f64);

fn iv(lo: f64, hi: f64) Interval {
    return Interval.init(lo, hi);
}

fn point(x: f64) Interval {
    return Interval.init(x, x);
}

/// Verify that an answer is present (non-null) and valid (lo <= hi).
fn answer(x: ?Interval) !Interval {
    const res = x orelse return error.OutOfDomain;
    try std.testing.expect(res.lo <= res.hi);
    return res;
}

// ---------------------------------------------------------------------------
// Rational normalization
// ---------------------------------------------------------------------------

test "Rational: exact gcd normalization and canonical sign" {
    // Both ends divided by their exact gcd; denominator stays positive
    const r1 = try Rational.init(4, 6);
    try std.testing.expectEqual(@as(i64, 2), r1.numerator);
    try std.testing.expectEqual(@as(u64, 3), r1.denominator);

    const r2 = try Rational.init(6, 4);
    try std.testing.expectEqual(@as(i64, 3), r2.numerator);
    try std.testing.expectEqual(@as(u64, 2), r2.denominator);

    const r3 = try Rational.init(-9, 6);
    try std.testing.expectEqual(@as(i64, -3), r3.numerator);
    try std.testing.expectEqual(@as(u64, 2), r3.denominator);

    const r4 = try Rational.init(-4, 6);
    try std.testing.expectEqual(@as(i64, -2), r4.numerator);
    try std.testing.expectEqual(@as(u64, 3), r4.denominator);

    const r5 = try Rational.init(7, 21);
    try std.testing.expectEqual(@as(i64, 1), r5.numerator);
    try std.testing.expectEqual(@as(u64, 3), r5.denominator);

    const r6 = try Rational.init(100, 10);
    try std.testing.expectEqual(@as(i64, 10), r6.numerator);
    try std.testing.expectEqual(@as(u64, 1), r6.denominator);

    const r7 = try Rational.init(1, 1);
    try std.testing.expectEqual(@as(i64, 1), r7.numerator);
    try std.testing.expectEqual(@as(u64, 1), r7.denominator);

    const r8 = try Rational.init(-1, 1);
    try std.testing.expectEqual(@as(i64, -1), r8.numerator);
    try std.testing.expectEqual(@as(u64, 1), r8.denominator);
}

test "Rational: zero numerator normalizes to denominator 1" {
    const z1 = try Rational.init(0, 1);
    try std.testing.expectEqual(@as(i64, 0), z1.numerator);
    try std.testing.expectEqual(@as(u64, 1), z1.denominator);

    const z2 = try Rational.init(0, 17);
    try std.testing.expectEqual(@as(i64, 0), z2.numerator);
    try std.testing.expectEqual(@as(u64, 1), z2.denominator);

    const z3 = try Rational.init(0, std.math.maxInt(u64));
    try std.testing.expectEqual(@as(i64, 0), z3.numerator);
    try std.testing.expectEqual(@as(u64, 1), z3.denominator);
}

test "Rational: minInt(i64) normalized safely without negation overflow" {
    const min_i64 = std.math.minInt(i64); // -9223372036854775808 = -2^63

    // gcd(-2^63, 1) = 1
    const r1 = try Rational.init(min_i64, 1);
    try std.testing.expectEqual(min_i64, r1.numerator);
    try std.testing.expectEqual(@as(u64, 1), r1.denominator);

    // gcd(-2^63, 3) = 1 (coprime)
    const r2 = try Rational.init(min_i64, 3);
    try std.testing.expectEqual(min_i64, r2.numerator);
    try std.testing.expectEqual(@as(u64, 3), r2.denominator);

    // gcd(-2^63, 4) = 4
    const r3 = try Rational.init(min_i64, 4);
    try std.testing.expectEqual(min_i64 / 4, r3.numerator);
    try std.testing.expectEqual(@as(u64, 1), r3.denominator);

    // gcd(-2^63, 2^62) = 2^62 => numerator -2, denominator 1
    const r4 = try Rational.init(min_i64, @as(u64, 1) << 62);
    try std.testing.expectEqual(@as(i64, -2), r4.numerator);
    try std.testing.expectEqual(@as(u64, 1), r4.denominator);

    // gcd(-2^63, 2^63) = 2^63 => numerator -1, denominator 1
    const r5 = try Rational.init(min_i64, @as(u64, 1) << 63);
    try std.testing.expectEqual(@as(i64, -1), r5.numerator);
    try std.testing.expectEqual(@as(u64, 1), r5.denominator);
}

test "Rational: denominator 0 returns ZeroDenominator error" {
    try std.testing.expectError(error.ZeroDenominator, Rational.init(0, 0));
    try std.testing.expectError(error.ZeroDenominator, Rational.init(1, 0));
    try std.testing.expectError(error.ZeroDenominator, Rational.init(-1, 0));
    try std.testing.expectError(error.ZeroDenominator, Rational.init(std.math.minInt(i64), 0));
    try std.testing.expectError(error.ZeroDenominator, Rational.init(std.math.maxInt(i64), 0));
}

// ---------------------------------------------------------------------------
// Rational powers: powRational
// ---------------------------------------------------------------------------

test "powRational: odd reduced denominator real roots over negative base" {
    // (-8)^(1/3) = -2 exactly
    const cube = try answer(ext.powRational(point(-8.0), try Rational.init(1, 3)));
    try std.testing.expect(cube.contains(-2.0));

    // Even if written unreduced as 2/6, it normalizes to 1/3 and is well-defined
    const unreduced = try answer(ext.powRational(point(-8.0), try Rational.init(2, 6)));
    try std.testing.expect(unreduced.contains(-2.0));

    // Odd-denominator root preserves monotonicity across an interval of negative reals:
    // [-27, -8]^(1/3) = [-3, -2]
    const neg_box = try answer(ext.powRational(iv(-27.0, -8.0), try Rational.init(1, 3)));
    try std.testing.expect(neg_box.contains(-3.0));
    try std.testing.expect(neg_box.contains(-2.0));

    // Straddling interval [-8, 8]^(1/3) = [-2, 2]
    const straddle = try answer(ext.powRational(iv(-8.0, 8.0), try Rational.init(1, 3)));
    try std.testing.expect(straddle.contains(-2.0));
    try std.testing.expect(straddle.contains(2.0));
    try std.testing.expect(straddle.contains(0.0));
}

test "powRational: even reduced numerator with odd denominator maps negative base to positive" {
    // (-8)^(2/3) = ((-8)^(1/3))^2 = (-2)^2 = 4
    const res = try answer(ext.powRational(point(-8.0), try Rational.init(2, 3)));
    try std.testing.expect(res.contains(4.0));

    // An interval [-8, -1] under 2/3 has image [1, 4]
    const neg_iv = try answer(ext.powRational(iv(-8.0, -1.0), try Rational.init(2, 3)));
    try std.testing.expect(neg_iv.contains(1.0));
    try std.testing.expect(neg_iv.contains(4.0));
    try std.testing.expect(neg_iv.lo >= 0.0);

    // Straddling interval [-8, 8] has minimum 0 at x=0 and maximum 4: [0, 4]
    const straddle = try answer(ext.powRational(iv(-8.0, 8.0), try Rational.init(2, 3)));
    try std.testing.expect(straddle.contains(0.0));
    try std.testing.expect(straddle.contains(4.0));
    try std.testing.expect(straddle.lo <= 0.0);
}

test "powRational: even reduced denominator wholly negative base has empty real image" {
    // (-4)^(1/2) has no real value
    try std.testing.expect(ext.powRational(point(-4.0), try Rational.init(1, 2)) == null);
    try std.testing.expect(ext.powRational(iv(-9.0, -1.0), try Rational.init(1, 2)) == null);
    try std.testing.expect(ext.powRational(iv(-8.0, -1.0), try Rational.init(3, 4)) == null);
    try std.testing.expect(ext.powRational(point(-1.0), try Rational.init(-1, 2)) == null);
}

test "powRational: even reduced denominator clips negative part on mixed interval" {
    // [-4, 9]^(1/2) clips negative part [-4, 0), leaving [0, 9]^(1/2) = [0, 3]
    const clipped = try answer(ext.powRational(iv(-4.0, 9.0), try Rational.init(1, 2)));
    try std.testing.expect(clipped.contains(0.0));
    try std.testing.expect(clipped.contains(3.0));
    try std.testing.expect(clipped.lo <= 0.0);
}

test "powRational: negative powers invert with correct parity" {
    // 4^(-1/2) = 1/2 = 0.5
    const pos_neg_pow = try answer(ext.powRational(point(4.0), try Rational.init(-1, 2)));
    try std.testing.expect(pos_neg_pow.contains(0.5));

    // [4, 16]^(-1/2) = [0.25, 0.5]
    const pos_iv_neg = try answer(ext.powRational(iv(4.0, 16.0), try Rational.init(-1, 2)));
    try std.testing.expect(pos_iv_neg.contains(0.25));
    try std.testing.expect(pos_iv_neg.contains(0.5));

    // (-8)^(-1/3) = -0.5
    const neg_neg_odd = try answer(ext.powRational(point(-8.0), try Rational.init(-1, 3)));
    try std.testing.expect(neg_neg_odd.contains(-0.5));

    // (-8)^(-2/3) = 0.25
    const neg_neg_even_num = try answer(ext.powRational(point(-8.0), try Rational.init(-2, 3)));
    try std.testing.expect(neg_neg_even_num.contains(0.25));

    // [2, 3]^(-1/1) = [1/3, 1/2]
    const recip_iv = try answer(ext.powRational(iv(2.0, 3.0), try Rational.init(-1, 1)));
    try std.testing.expect(recip_iv.contains(0.5));
    try std.testing.expect(recip_iv.lo <= 1.0 / 3.0);
    try std.testing.expect(recip_iv.hi >= 0.5);
}

test "powRational: zero base conventions and 0^0" {
    // 0^0 = 1 contract mandate
    const z0 = try answer(ext.powRational(point(0.0), try Rational.init(0, 1)));
    try std.testing.expectEqual(@as(f64, 1.0), z0.lo);
    try std.testing.expectEqual(@as(f64, 1.0), z0.hi);

    // Negative base with exponent 0 is also 1: (-5)^0 = 1
    const neg_z0 = try answer(ext.powRational(iv(-5.0, 7.0), try Rational.init(0, 1)));
    try std.testing.expectEqual(@as(f64, 1.0), neg_z0.lo);
    try std.testing.expectEqual(@as(f64, 1.0), neg_z0.hi);

    // 0^(positive) = 0
    const z_pos = try answer(ext.powRational(point(0.0), try Rational.init(3, 1)));
    try std.testing.expectEqual(@as(f64, 0.0), z_pos.lo);
    try std.testing.expectEqual(@as(f64, 0.0), z_pos.hi);

    const z_pos_rat = try answer(ext.powRational(point(0.0), try Rational.init(1, 3)));
    try std.testing.expectEqual(@as(f64, 0.0), z_pos_rat.lo);
    try std.testing.expectEqual(@as(f64, 0.0), z_pos_rat.hi);

    // 0^(negative Rational) has empty real image: MUST return null
    try std.testing.expect(ext.powRational(point(0.0), try Rational.init(-1, 1)) == null);
    try std.testing.expect(ext.powRational(point(0.0), try Rational.init(-2, 3)) == null);
}

test "powRational: huge exponent scale limits" {
    // 2^600 is exact dyadic power within f64 range
    const p600 = try answer(ext.powRational(point(2.0), try Rational.init(600, 1)));
    try std.testing.expect(p600.contains(0x1p+600));

    // 2^2000 overflows f64: upper bound must saturate to +inf
    const p2000 = try answer(ext.powRational(point(2.0), try Rational.init(2000, 1)));
    try std.testing.expectEqual(inf, p2000.hi);
    try std.testing.expect(!std.math.isNan(p2000.lo));
    try std.testing.expect(p2000.lo > 0.0);

    // (-2)^2001 is a huge negative power: lower bound must saturate to -inf
    const neg_p2001 = try answer(ext.powRational(point(-2.0), try Rational.init(2001, 1)));
    try std.testing.expectEqual(-inf, neg_p2001.lo);
    try std.testing.expect(!std.math.isNan(neg_p2001.hi));
    try std.testing.expect(neg_p2001.hi < 0.0);
}

// ---------------------------------------------------------------------------
// nthRoot: INDEX FIRST
// ---------------------------------------------------------------------------

test "nthRoot: index first, degree 0 is undefined" {
    try std.testing.expect(ext.nthRoot(0, point(4.0)) == null);
    try std.testing.expect(ext.nthRoot(0, point(0.0)) == null);
    try std.testing.expect(ext.nthRoot(0, iv(-2.0, 2.0)) == null);
}

test "nthRoot: degree 1 is exact identity" {
    const id1 = try answer(ext.nthRoot(1, iv(-5.0, 7.0)));
    try std.testing.expect(id1.contains(-5.0));
    try std.testing.expect(id1.contains(7.0));
    try std.testing.expect(id1.lo <= -5.0);
    try std.testing.expect(id1.hi >= 7.0);
}

test "nthRoot: even degrees clip negative part" {
    // 2nd root of [-4, 9] -> clips to [0, 9] -> contains 0 and 3
    const r2 = try answer(ext.nthRoot(2, iv(-4.0, 9.0)));
    try std.testing.expect(r2.contains(0.0));
    try std.testing.expect(r2.contains(3.0));
    try std.testing.expect(r2.lo <= 0.0);

    // 4th root of 16 -> 2
    const r4 = try answer(ext.nthRoot(4, point(16.0)));
    try std.testing.expect(r4.contains(2.0));

    // Wholly negative argument has no real image
    try std.testing.expect(ext.nthRoot(2, iv(-9.0, -1.0)) == null);
    try std.testing.expect(ext.nthRoot(4, point(-16.0)) == null);
}

test "nthRoot: odd degrees accept negative arguments" {
    // 3rd root of -8 -> -2
    const r3_neg = try answer(ext.nthRoot(3, point(-8.0)));
    try std.testing.expect(r3_neg.contains(-2.0));

    // 3rd root of [-8, 27] -> [-2, 3]
    const r3_span = try answer(ext.nthRoot(3, iv(-8.0, 27.0)));
    try std.testing.expect(r3_span.contains(-2.0));
    try std.testing.expect(r3_span.contains(3.0));

    // 5th root of -32 -> -2
    const r5_neg = try answer(ext.nthRoot(5, point(-32.0)));
    try std.testing.expect(r5_neg.contains(-2.0));
}

test "nthRoot: huge degree and scale limits" {
    // 1000th root of 2^1000 is exactly 2
    const r1000_exact = try answer(ext.nthRoot(1000, point(0x1p+1000)));
    try std.testing.expect(r1000_exact.contains(2.0));

    // 1000th root of 2: 1 < 2^(1/1000) < 2
    const r1000 = try answer(ext.nthRoot(1000, point(2.0)));
    try std.testing.expect(r1000.contains(1.0006933874625807));
    try std.testing.expect(r1000.lo >= 1.0);
    try std.testing.expect(r1000.hi <= 2.0);

    // Square root of largest finite floatMax: ~1.34078e154
    const r_fmax = try answer(ext.nthRoot(2, point(float_max)));
    try std.testing.expect(r_fmax.contains(1.3407807929942596e154));
    try std.testing.expect(r_fmax.lo >= 0.0);
    try std.testing.expect(r_fmax.hi <= float_max);
}

// ---------------------------------------------------------------------------
// Base logarithm: logBase (BASE FIRST)
// ---------------------------------------------------------------------------

test "logBase: base first with exact integer powers" {
    // log_2(8) = 3
    const l2_8 = try answer(ext.logBase(point(2.0), point(8.0)));
    try std.testing.expect(l2_8.contains(3.0));

    // log_10([100, 1000]) = [2, 3]
    const l10_span = try answer(ext.logBase(point(10.0), iv(100.0, 1000.0)));
    try std.testing.expect(l10_span.contains(2.0));
    try std.testing.expect(l10_span.contains(3.0));

    // log_b(1) = 0 for any valid base
    const l_one = try answer(ext.logBase(iv(2.0, 8.0), point(1.0)));
    try std.testing.expect(l_one.contains(0.0));
}

test "logBase: base below 1 reverses orientation" {
    // log_{0.5}(8) = -3
    const l_half_8 = try answer(ext.logBase(point(0.5), point(8.0)));
    try std.testing.expect(l_half_8.contains(-3.0));

    // log_{0.5}([1, 8]) = [-3, 0]
    const l_half_span = try answer(ext.logBase(point(0.5), iv(1.0, 8.0)));
    try std.testing.expect(l_half_span.contains(-3.0));
    try std.testing.expect(l_half_span.contains(0.0));

    // base in [0.25, 0.5], x in [1, 16] -> contains log_{0.5}(16) = -4 and log_{0.25}(1) = 0
    const l_bases_sub1 = try answer(ext.logBase(iv(0.25, 0.5), iv(1.0, 16.0)));
    try std.testing.expect(l_bases_sub1.contains(-4.0));
    try std.testing.expect(l_bases_sub1.contains(0.0));
}

test "logBase: base 1, base <= 0, and nonpositive x are wholly undefined" {
    // Base 1 is undefined
    try std.testing.expect(ext.logBase(point(1.0), point(8.0)) == null);
    try std.testing.expect(ext.logBase(point(1.0), point(1.0)) == null);

    // Nonpositive base is undefined
    try std.testing.expect(ext.logBase(point(0.0), point(8.0)) == null);
    try std.testing.expect(ext.logBase(point(-2.0), point(8.0)) == null);
    try std.testing.expect(ext.logBase(iv(-5.0, 0.0), point(8.0)) == null);

    // Nonpositive argument x is undefined
    try std.testing.expect(ext.logBase(point(2.0), point(0.0)) == null);
    try std.testing.expect(ext.logBase(point(2.0), point(-4.0)) == null);
    try std.testing.expect(ext.logBase(point(2.0), iv(-8.0, 0.0)) == null);
}

test "logBase: argument x approaching zero clips to pole at -inf" {
    // x in (0, 8] with base 2 runs to -inf
    const l_zero = try answer(ext.logBase(point(2.0), iv(0.0, 8.0)));
    try std.testing.expectEqual(-inf, l_zero.lo);
    try std.testing.expect(l_zero.contains(3.0));

    // Partly negative x clips to (0, 4] with base 2 -> lo is -inf, contains 2
    const l_partly_neg = try answer(ext.logBase(point(2.0), iv(-5.0, 4.0)));
    try std.testing.expectEqual(-inf, l_partly_neg.lo);
    try std.testing.expect(l_partly_neg.contains(2.0));
}

test "logBase: mixed valid bases crossing 1 preserves both rays" {
    // base in [0.5, 2.0] crosses 1. As base -> 1-, log_base(8) -> -inf.
    // As base -> 1+, log_base(8) -> +inf.
    // Both branches must be enclosed: result must be unbounded in both directions.
    const l_cross = try answer(ext.logBase(iv(0.5, 2.0), iv(1.0, 8.0)));
    try std.testing.expectEqual(-inf, l_cross.lo);
    try std.testing.expectEqual(inf, l_cross.hi);
    try std.testing.expect(l_cross.contains(-3.0)); // log_{0.5}(8) = -3
    try std.testing.expect(l_cross.contains(3.0));  // log_2(8) = 3
    try std.testing.expect(l_cross.contains(0.0));  // log_b(1) = 0
}

// ---------------------------------------------------------------------------
// Order statistics: min, max, median, nthSmallest, nthLargest
// ---------------------------------------------------------------------------

test "min and max: empty input is undefined" {
    const empty = [_]Interval{};
    try std.testing.expect(ext.min(&empty) == null);
    try std.testing.expect(ext.max(&empty) == null);
}

test "min and max: single element and distinct lists" {
    const single = [_]Interval{point(42.0)};
    const m_single = try answer(ext.min(&single));
    try std.testing.expectEqual(@as(f64, 42.0), m_single.lo);
    try std.testing.expectEqual(@as(f64, 42.0), m_single.hi);

    const xs = [_]Interval{ point(5.0), point(1.0), point(3.0) };
    const lo = try answer(ext.min(&xs));
    try std.testing.expectEqual(@as(f64, 1.0), lo.lo);
    try std.testing.expectEqual(@as(f64, 1.0), lo.hi);

    const hi = try answer(ext.max(&xs));
    try std.testing.expectEqual(@as(f64, 5.0), hi.lo);
    try std.testing.expectEqual(@as(f64, 5.0), hi.hi);
}

test "min and max: overlapping independent intervals" {
    // Two independent intervals A=[0, 10], B=[3, 5]:
    // min(a, b) ranges from min(0, 5)=0 to min(10, 5)=5 => [0, 5]
    // max(a, b) ranges from max(0, 3)=3 to max(10, 5)=10 => [3, 10]
    const pair = [_]Interval{ iv(0.0, 10.0), iv(3.0, 5.0) };
    const min_pair = try answer(ext.min(&pair));
    try std.testing.expect(min_pair.contains(0.0));
    try std.testing.expect(min_pair.contains(5.0));

    const max_pair = try answer(ext.max(&pair));
    try std.testing.expect(max_pair.contains(3.0));
    try std.testing.expect(max_pair.contains(10.0));
}

test "median: empty input is undefined" {
    const empty = [_]Interval{};
    var scratch: [1]f64 = undefined;
    try std.testing.expect(try ext.median(&empty, scratch[0..]) == null);
}

test "median: odd count middle value and even count central mean" {
    var scratch: [4]f64 = undefined;

    // Odd count: median([5, 1, 3]) = 3
    const odd = [_]Interval{ point(5.0), point(1.0), point(3.0) };
    const med_odd = try answer(try ext.median(&odd, scratch[0..3]));
    try std.testing.expectEqual(@as(f64, 3.0), med_odd.lo);
    try std.testing.expectEqual(@as(f64, 3.0), med_odd.hi);

    // Even count: median([1, 2, 3, 4]) = mean(2, 3) = 2.5
    const even = [_]Interval{ point(1.0), point(2.0), point(3.0), point(4.0) };
    const med_even = try answer(try ext.median(&even, scratch[0..4]));
    try std.testing.expectEqual(@as(f64, 2.5), med_even.lo);
    try std.testing.expectEqual(@as(f64, 2.5), med_even.hi);

    // Two elements: mean([1, 3]) = 2
    const two = [_]Interval{ point(1.0), point(3.0) };
    const med_two = try answer(try ext.median(&two, scratch[0..2]));
    try std.testing.expectEqual(@as(f64, 2.0), med_two.lo);
    try std.testing.expectEqual(@as(f64, 2.0), med_two.hi);
}

test "median: overlapping independent intervals" {
    // Four intervals: 0, 1, [0, 10], 1
    // Sorted multiset {0, 1, 1, y} with y in [0, 10].
    // If y=0: {0, 0, 1, 1} -> 2nd=0, 3rd=1 -> mean 0.5.
    // If y=10: {0, 1, 1, 10} -> 2nd=1, 3rd=1 -> mean 1.0.
    // Sound enclosure must contain 0.5 and 1.0.
    const xs = [_]Interval{ point(0.0), point(1.0), iv(0.0, 10.0), point(1.0) };
    var scratch: [4]f64 = undefined;
    const med = try answer(try ext.median(&xs, scratch[0..]));
    try std.testing.expect(med.contains(0.5));
    try std.testing.expect(med.contains(1.0));
}

test "median: scratch buffer exhaustion" {
    const xs = [_]Interval{ point(1.0), point(2.0), point(3.0) };
    var short_scratch: [2]f64 = undefined;
    try std.testing.expectError(error.InsufficientScratch, ext.median(&xs, short_scratch[0..]));

    var exact_scratch: [3]f64 = undefined;
    _ = try answer(try ext.median(&xs, exact_scratch[0..]));
}

test "nthSmallest and nthLargest: one-based integer rank semantics" {
    const xs = [_]Interval{ point(50.0), point(10.0), point(30.0) };
    var scratch: [3]f64 = undefined;

    // Rank 1 = smallest (10), Rank 2 = middle (30), Rank 3 = largest (50)
    const r1 = try answer(try ext.nthSmallest(&xs, point(1.0), scratch[0..]));
    try std.testing.expectEqual(@as(f64, 10.0), r1.lo);
    try std.testing.expectEqual(@as(f64, 10.0), r1.hi);

    const r2 = try answer(try ext.nthSmallest(&xs, point(2.0), scratch[0..]));
    try std.testing.expectEqual(@as(f64, 30.0), r2.lo);
    try std.testing.expectEqual(@as(f64, 30.0), r2.hi);

    const r3 = try answer(try ext.nthSmallest(&xs, point(3.0), scratch[0..]));
    try std.testing.expectEqual(@as(f64, 50.0), r3.lo);
    try std.testing.expectEqual(@as(f64, 50.0), r3.hi);

    // nthLargest mirrors: rank 1 is largest (50), rank 3 is smallest (10)
    const l1 = try answer(try ext.nthLargest(&xs, point(1.0), scratch[0..]));
    try std.testing.expectEqual(@as(f64, 50.0), l1.lo);
    try std.testing.expectEqual(@as(f64, 50.0), l1.hi);

    const l3 = try answer(try ext.nthLargest(&xs, point(3.0), scratch[0..]));
    try std.testing.expectEqual(@as(f64, 10.0), l3.lo);
    try std.testing.expectEqual(@as(f64, 10.0), l3.hi);
}

test "nthSmallest: rank index out of range or fractional without integers" {
    const xs = [_]Interval{ point(10.0), point(20.0), point(30.0) };
    var scratch: [3]f64 = undefined;

    // Rank 0 is strictly invalid (1-based)
    try std.testing.expect(try ext.nthSmallest(&xs, point(0.0), scratch[0..]) == null);

    // Rank > xs.len is invalid
    try std.testing.expect(try ext.nthSmallest(&xs, point(4.0), scratch[0..]) == null);
    try std.testing.expect(try ext.nthSmallest(&xs, point(-1.0), scratch[0..]) == null);

    // Fractional interval containing NO integer: [0.2, 0.8] -> null
    try std.testing.expect(try ext.nthSmallest(&xs, iv(0.2, 0.8), scratch[0..]) == null);

    // Fractional interval containing NO integer in 1..3: [3.2, 3.8] -> null
    try std.testing.expect(try ext.nthSmallest(&xs, iv(3.2, 3.8), scratch[0..]) == null);
}

test "nthSmallest: rank interval hulls all allowed integer ranks" {
    const xs = [_]Interval{ point(10.0), point(20.0), point(30.0) };
    var scratch: [3]f64 = undefined;

    // Rank [1.5, 2.5] contains single integer 2 -> 20.0
    const r_single_int = try answer(try ext.nthSmallest(&xs, iv(1.5, 2.5), scratch[0..]));
    try std.testing.expectEqual(@as(f64, 20.0), r_single_int.lo);
    try std.testing.expectEqual(@as(f64, 20.0), r_single_int.hi);

    // Rank [1.0, 3.0] hulls ranks 1, 2, 3 -> [10, 30]
    const r_all = try answer(try ext.nthSmallest(&xs, iv(1.0, 3.0), scratch[0..]));
    try std.testing.expectEqual(@as(f64, 10.0), r_all.lo);
    try std.testing.expectEqual(@as(f64, 30.0), r_all.hi);

    // Rank [0.5, 2.2] clips to valid integer ranks {1, 2} -> [10, 20]
    const r_partial = try answer(try ext.nthSmallest(&xs, iv(0.5, 2.2), scratch[0..]));
    try std.testing.expectEqual(@as(f64, 10.0), r_partial.lo);
    try std.testing.expectEqual(@as(f64, 20.0), r_partial.hi);
}

test "nthSmallest: overlapping independent intervals" {
    // xs = [[1, 5], [2, 9], [4, 6]]
    // Selecting one value from each:
    // Rank 2 (median): minimum is 2 (at 1, 2, 4), maximum is 6 (at 5, 9, 6).
    // Image of rank 2 is [2, 6].
    const xs = [_]Interval{ iv(1.0, 5.0), iv(2.0, 9.0), iv(4.0, 6.0) };
    var scratch: [3]f64 = undefined;

    const r2 = try answer(try ext.nthSmallest(&xs, point(2.0), scratch[0..]));
    try std.testing.expect(r2.contains(2.0));
    try std.testing.expect(r2.contains(6.0));

    // Rank 1 (minimum): min possible is 1, max possible is 2 (at 5, 2, 4).
    const r1 = try answer(try ext.nthSmallest(&xs, point(1.0), scratch[0..]));
    try std.testing.expect(r1.contains(1.0));
    try std.testing.expect(r1.contains(2.0));

    // Rank 3 (maximum): min possible is 4 (at 1, 2, 4), max possible is 9 (at 5, 9, 6).
    const r3 = try answer(try ext.nthSmallest(&xs, point(3.0), scratch[0..]));
    try std.testing.expect(r3.contains(4.0));
    try std.testing.expect(r3.contains(9.0));
}

test "nthSmallest and nthLargest: scratch buffer exhaustion" {
    const xs = [_]Interval{ point(1.0), point(2.0), point(3.0) };
    var short_scratch: [2]f64 = undefined;
    try std.testing.expectError(error.InsufficientScratch, ext.nthSmallest(&xs, point(1.0), short_scratch[0..]));
    try std.testing.expectError(error.InsufficientScratch, ext.nthLargest(&xs, point(1.0), short_scratch[0..]));

    var exact_scratch: [3]f64 = undefined;
    _ = try answer(try ext.nthSmallest(&xs, point(1.0), exact_scratch[0..]));
    _ = try answer(try ext.nthLargest(&xs, point(1.0), exact_scratch[0..]));
}

// ---------------------------------------------------------------------------
// Scalar sign: sgn
// ---------------------------------------------------------------------------

test "sgn: exact mathematical signs -1, 0, +1" {
    // Strictly negative interval
    const s_neg = ext.sgn(iv(-10.0, -0.5));
    try std.testing.expectEqual(@as(f64, -1.0), s_neg.lo);
    try std.testing.expectEqual(@as(f64, -1.0), s_neg.hi);

    // Exact zero
    const s_zero = ext.sgn(point(0.0));
    try std.testing.expectEqual(@as(f64, 0.0), s_zero.lo);
    try std.testing.expectEqual(@as(f64, 0.0), s_zero.hi);

    // Strictly positive interval
    const s_pos = ext.sgn(iv(0.1, 100.0));
    try std.testing.expectEqual(@as(f64, 1.0), s_pos.lo);
    try std.testing.expectEqual(@as(f64, 1.0), s_pos.hi);

    // Interval spanning zero: image contains both signs and zero: [-1, 1]
    const s_span = ext.sgn(iv(-2.0, 3.0));
    try std.testing.expectEqual(@as(f64, -1.0), s_span.lo);
    try std.testing.expectEqual(@as(f64, 1.0), s_span.hi);

    // Touching zero from below: [-1, 0]
    const s_touch_neg = ext.sgn(iv(-3.0, 0.0));
    try std.testing.expectEqual(@as(f64, -1.0), s_touch_neg.lo);
    try std.testing.expectEqual(@as(f64, 0.0), s_touch_neg.hi);

    // Touching zero from above: [0, 1]
    const s_touch_pos = ext.sgn(iv(0.0, 3.0));
    try std.testing.expectEqual(@as(f64, 0.0), s_touch_pos.lo);
    try std.testing.expectEqual(@as(f64, 1.0), s_touch_pos.hi);
}

// ---------------------------------------------------------------------------
// Positive modulo: mod
// ---------------------------------------------------------------------------

test "mod: positive remainder with positive modulus" {
    // 7 mod 3 = 1 (7 = 2*3 + 1)
    const m1 = try answer(ext.mod(point(7.0), point(3.0)));
    try std.testing.expectEqual(@as(f64, 1.0), m1.lo);
    try std.testing.expectEqual(@as(f64, 1.0), m1.hi);

    // 0 mod 3 = 0
    const m0 = try answer(ext.mod(point(0.0), point(3.0)));
    try std.testing.expectEqual(@as(f64, 0.0), m0.lo);
    try std.testing.expectEqual(@as(f64, 0.0), m0.hi);
}

test "mod: negative dividend yields positive remainder" {
    // -7 mod 3 = 2 (-7 = -3*3 + 2, positive remainder in [0, 3))
    const m_neg = try answer(ext.mod(point(-7.0), point(3.0)));
    try std.testing.expectEqual(@as(f64, 2.0), m_neg.lo);
    try std.testing.expectEqual(@as(f64, 2.0), m_neg.hi);
}

test "mod: negative modulus uses modulus magnitude" {
    // 7 mod -3 = 1 (magnitude 3, remainder 1)
    const m_neg_mod = try answer(ext.mod(point(7.0), point(-3.0)));
    try std.testing.expectEqual(@as(f64, 1.0), m_neg_mod.lo);
    try std.testing.expectEqual(@as(f64, 1.0), m_neg_mod.hi);

    // -7 mod -3 = 2
    const m_both_neg = try answer(ext.mod(point(-7.0), point(-3.0)));
    try std.testing.expectEqual(@as(f64, 2.0), m_both_neg.lo);
    try std.testing.expectEqual(@as(f64, 2.0), m_both_neg.hi);
}

test "mod: zero modulus point is undefined" {
    try std.testing.expect(ext.mod(point(7.0), point(0.0)) == null);
    try std.testing.expect(ext.mod(point(-7.0), point(0.0)) == null);
    try std.testing.expect(ext.mod(point(0.0), point(0.0)) == null);
}

test "mod: modulus interval crossing zero hulls defined remainders" {
    // dividend x=7, modulus m in [-3, 3].
    // m=0 is undefined, but for every |m| in (0, 3], remainders are valid:
    // |m|=3 gives 7 mod 3 = 1
    // |m|=2.5 gives 7 - 2*2.5 = 2.0
    // |m|=1.0 gives 7 mod 1 = 0.0
    // Supremum over |m| in (0, 3] is 7/3 ~ 2.3333333333333335 (approached as |m| -> 7/3 from above).
    // Result is non-null partial-domain hull containing 0, 1, 2 and reaching sup 7/3.
    const m_cross = try answer(ext.mod(point(7.0), iv(-3.0, 3.0)));
    try std.testing.expect(m_cross.contains(0.0));
    try std.testing.expect(m_cross.contains(1.0));
    try std.testing.expect(m_cross.contains(2.0));
    try std.testing.expect(m_cross.lo <= 0.0);
    try std.testing.expect(m_cross.hi >= 7.0 / 3.0);
    try std.testing.expect(m_cross.hi <= 3.0);
}

// ---------------------------------------------------------------------------
// Directed tie roundings: roundTiesUp and roundTiesDown
// ---------------------------------------------------------------------------

test "roundTiesUp and roundTiesDown: opposite tie conventions on halves" {
    const cases = [_]struct {
        x: f64,
        ties_up: f64,
        ties_down: f64,
        away: f64,
    }{
        .{ .x = 0.5, .ties_up = 1.0, .ties_down = 0.0, .away = 1.0 },
        .{ .x = -0.5, .ties_up = 0.0, .ties_down = -1.0, .away = -1.0 },
        .{ .x = 1.5, .ties_up = 2.0, .ties_down = 1.0, .away = 2.0 },
        .{ .x = -1.5, .ties_up = -1.0, .ties_down = -2.0, .away = -2.0 },
        .{ .x = 2.5, .ties_up = 3.0, .ties_down = 2.0, .away = 3.0 },
        .{ .x = -2.5, .ties_up = -2.0, .ties_down = -3.0, .away = -3.0 },
    };

    for (cases) |c| {
        const up = ext.roundTiesUp(point(c.x));
        try std.testing.expectEqual(c.ties_up, up.lo);
        try std.testing.expectEqual(c.ties_up, up.hi);

        const down = ext.roundTiesDown(point(c.x));
        try std.testing.expectEqual(c.ties_down, down.lo);
        try std.testing.expectEqual(c.ties_down, down.hi);

        // ext.round retains half away from zero
        const away = ext.round(point(c.x));
        try std.testing.expectEqual(c.away, away.lo);
        try std.testing.expectEqual(c.away, away.hi);
    }
}

test "tie roundings: non-tie values agree across all conventions" {
    const non_ties = [_]f64{ 0.0, 1.2, -1.2, 1.8, -1.8, 3.0, -3.0 };
    for (non_ties) |x| {
        const up = ext.roundTiesUp(point(x));
        const down = ext.roundTiesDown(point(x));
        const away = ext.round(point(x));
        try std.testing.expectEqual(up.lo, down.lo);
        try std.testing.expectEqual(up.hi, down.hi);
        try std.testing.expectEqual(up.lo, away.lo);
        try std.testing.expectEqual(up.hi, away.hi);
    }
}

test "tie roundings: intervals straddling halves" {
    // [-0.5, 0.5] under tiesUp maps -0.5 -> 0, 0.5 -> 1 => [0, 1]
    const span_up = ext.roundTiesUp(iv(-0.5, 0.5));
    try std.testing.expectEqual(@as(f64, 0.0), span_up.lo);
    try std.testing.expectEqual(@as(f64, 1.0), span_up.hi);

    // [-0.5, 0.5] under tiesDown maps -0.5 -> -1, 0.5 -> 0 => [-1, 0]
    const span_down = ext.roundTiesDown(iv(-0.5, 0.5));
    try std.testing.expectEqual(@as(f64, -1.0), span_down.lo);
    try std.testing.expectEqual(@as(f64, 0.0), span_down.hi);

    // [-0.5, 0.5] under ext.round maps -0.5 -> -1, 0.5 -> 1 => [-1, 1]
    const span_away = ext.round(iv(-0.5, 0.5));
    try std.testing.expectEqual(@as(f64, -1.0), span_away.lo);
    try std.testing.expectEqual(@as(f64, 1.0), span_away.hi);
}

test "tie roundings: huge integer representations without overflow" {
    // 1e300 and float_max are already exact integers in f64
    const large_vals = [_]f64{ 1e300, -1e300, 0x1p+62, -0x1p+62, float_max, -float_max };
    for (large_vals) |v| {
        const up = ext.roundTiesUp(point(v));
        try std.testing.expectEqual(v, up.lo);
        try std.testing.expectEqual(v, up.hi);

        const down = ext.roundTiesDown(point(v));
        try std.testing.expectEqual(v, down.lo);
        try std.testing.expectEqual(v, down.hi);
    }
}

// ---------------------------------------------------------------------------
// N-ary real gcd and lcm
// ---------------------------------------------------------------------------

test "gcd and lcm: empty list is undefined" {
    const empty = [_]Interval{};
    try std.testing.expect(ext.gcd(&empty) == null);
    try std.testing.expect(ext.lcm(&empty) == null);
}

test "gcd and lcm: single-argument conventions" {
    // Single nonzero argument gcd([a]) = abs(a), lcm([a]) = abs(a)
    const single_pos = [_]Interval{point(5.0)};
    const g_pos = try answer(ext.gcd(&single_pos));
    try std.testing.expect(g_pos.contains(5.0));
    const l_pos = try answer(ext.lcm(&single_pos));
    try std.testing.expect(l_pos.contains(5.0));

    const single_neg = [_]Interval{point(-7.5)};
    const g_neg = try answer(ext.gcd(&single_neg));
    try std.testing.expect(g_neg.contains(7.5));
    const l_neg = try answer(ext.lcm(&single_neg));
    try std.testing.expect(l_neg.contains(7.5));

    // Single zero argument is undefined under chosen all-zero convention
    const single_zero = [_]Interval{point(0.0)};
    try std.testing.expect(ext.gcd(&single_zero) == null);
    try std.testing.expect(ext.lcm(&single_zero) == null);
}

test "gcd and lcm: all-zero list is undefined" {
    const all_zero = [_]Interval{ point(0.0), point(0.0) };
    try std.testing.expect(ext.gcd(&all_zero) == null);
    try std.testing.expect(ext.lcm(&all_zero) == null);

    const all_zero3 = [_]Interval{ point(0.0), point(0.0), point(0.0) };
    try std.testing.expect(ext.gcd(&all_zero3) == null);
    try std.testing.expect(ext.lcm(&all_zero3) == null);
}

test "gcd: zero extension gcd(0, a) = |a| for nonzero a" {
    const g1 = try answer(ext.gcd(&[_]Interval{ point(0.0), point(5.0) }));
    try std.testing.expect(g1.contains(5.0));

    const g2 = try answer(ext.gcd(&[_]Interval{ point(0.0), point(-5.0) }));
    try std.testing.expect(g2.contains(5.0));

    const g3 = try answer(ext.gcd(&[_]Interval{ point(0.0), point(0.0), point(12.0) }));
    try std.testing.expect(g3.contains(12.0));
}

test "lcm: zero extension lcm(0, a) = 0 if some a is nonzero" {
    const l1 = try answer(ext.lcm(&[_]Interval{ point(0.0), point(5.0) }));
    try std.testing.expect(l1.contains(0.0));

    const l2 = try answer(ext.lcm(&[_]Interval{ point(0.0), point(-7.0) }));
    try std.testing.expect(l2.contains(0.0));

    const l3 = try answer(ext.lcm(&[_]Interval{ point(0.0), point(4.0), point(6.0) }));
    try std.testing.expect(l3.contains(0.0));
}

test "gcd: dyadic exactness and n-ary reduction" {
    // gcd(4, 6) = 2
    const g4_6 = try answer(ext.gcd(&[_]Interval{ point(4.0), point(6.0) }));
    try std.testing.expect(g4_6.contains(2.0));

    // gcd(-4, 6) = 2
    const g_neg4_6 = try answer(ext.gcd(&[_]Interval{ point(-4.0), point(6.0) }));
    try std.testing.expect(g_neg4_6.contains(2.0));

    // gcd(12, 18, 30, 42) = 6
    const g_nary = try answer(ext.gcd(&[_]Interval{ point(12.0), point(18.0), point(30.0), point(42.0) }));
    try std.testing.expect(g_nary.contains(6.0));

    // Dyadic mantissas: 1.5 = 3/2, 2.5 = 5/2 -> gcd is 0.5 (1/2)
    const g_dyadic = try answer(ext.gcd(&[_]Interval{ point(1.5), point(2.5) }));
    try std.testing.expect(g_dyadic.contains(0.5));

    // 0.5 and 0.25 -> 0.25
    const g_powers = try answer(ext.gcd(&[_]Interval{ point(0.5), point(0.25) }));
    try std.testing.expect(g_powers.contains(0.25));

    // Huge powers: gcd(2^1000, 2^1001) = 2^1000
    const g_huge = try answer(ext.gcd(&[_]Interval{ point(0x1p+1000), point(0x1p+1001) }));
    try std.testing.expect(g_huge.contains(0x1p+1000));
}

test "lcm: dyadic exactness and 106-bit product overflow protection" {
    // lcm(4, 6) = 12
    const l4_6 = try answer(ext.lcm(&[_]Interval{ point(4.0), point(6.0) }));
    try std.testing.expect(l4_6.contains(12.0));

    // lcm(3, 4, 5) = 60
    const l345 = try answer(ext.lcm(&[_]Interval{ point(3.0), point(4.0), point(5.0) }));
    try std.testing.expect(l345.contains(60.0));

    // lcm(1.5, 2.5) = (3/2 * 5/2) / (1/2) = 15/2 = 7.5
    const l_dyadic = try answer(ext.lcm(&[_]Interval{ point(1.5), point(2.5) }));
    try std.testing.expect(l_dyadic.contains(7.5));

    // lcm(0.5, 0.25) = 0.5
    const l_powers = try answer(ext.lcm(&[_]Interval{ point(0.5), point(0.25) }));
    try std.testing.expect(l_powers.contains(0.5));

    // 106-bit exact product protection:
    // lcm(2^1000, 2^1001) = 2^1001. Naive product (2^2001) overflows f64,
    // but contract specifies odd mantissa and max binary exponent.
    // Result must enclose 2^1001 without overflowing to +inf or returning NaN.
    const l_huge = try answer(ext.lcm(&[_]Interval{ point(0x1p+1000), point(0x1p+1001) }));
    try std.testing.expect(l_huge.contains(0x1p+1001));
    try std.testing.expect(!std.math.isNan(l_huge.lo));
    try std.testing.expect(!std.math.isNan(l_huge.hi));
}

test "gcd: nonpoint intervals enclose all commensurable results" {
    // Over a in [2, 4] and b in [3, 6], commensurable pairs achieve gcd:
    // gcd(2, 3) = 1
    // gcd(4, 6) = 2
    // gcd(3, 3) = 3
    // gcd(4, 4) = 4
    // As common factor shrinks, positive gcd approaches 0.
    // Result must contain all attained witnesses 1, 2, 3, 4 with lo <= 0 and hi >= 4.
    const g_box = try answer(ext.gcd(&[_]Interval{ iv(2.0, 4.0), iv(3.0, 6.0) }));
    try std.testing.expect(g_box.contains(1.0));
    try std.testing.expect(g_box.contains(2.0));
    try std.testing.expect(g_box.contains(3.0));
    try std.testing.expect(g_box.contains(4.0));
    try std.testing.expect(g_box.lo <= 0.0);
    try std.testing.expect(g_box.hi >= 4.0);
}

test "lcm: nonpoint intervals are unbounded above" {
    // Over a in [2, 4] and b in [3, 6], commensurable pairs achieve lcm:
    // lcm(3, 3) = 3 (minimum)
    // lcm(2, 4) = 4
    // lcm(2, 3) = 6
    // lcm(3, 4) = 12
    // lcm(4, 5) = 20
    // Arbitrarily large lcm can be formed with small common factor, so hi is +inf.
    const l_box = try answer(ext.lcm(&[_]Interval{ iv(2.0, 4.0), iv(3.0, 6.0) }));
    try std.testing.expect(l_box.contains(3.0));
    try std.testing.expect(l_box.contains(4.0));
    try std.testing.expect(l_box.contains(6.0));
    try std.testing.expect(l_box.contains(12.0));
    try std.testing.expect(l_box.contains(20.0));
    try std.testing.expect(l_box.lo <= 3.0);
    try std.testing.expectEqual(inf, l_box.hi);
}

test "lcm: repeated subnormal factors retain exact n-ary divisibility" {
    // M-1, M-3 and M-5 are pairwise coprime: their pairwise differences
    // are 2 or 4, and all three are odd. The repeated first factor must
    // not multiply the lcm again after its 156-bit coefficient is formed.
    const m: u64 = @as(u64, 1) << 52;
    const a: f64 = @bitCast(m - 1);
    const b: f64 = @bitCast(m - 3);
    const c: f64 = @bitCast(m - 5);
    const xs = [_]Interval{ point(a), point(b), point(c), point(a) };
    const got = try answer(ext.lcm(&xs));

    // The exact lcm is
    // 2^-918 - 9*2^-970 + 23*2^-1022 - 15*2^-1074.
    // The first two terms give an exact f64 q. The remaining positive
    // amount is strictly less than the next spacing, 2^-971. Any f64
    // enclosure of the real value must therefore contain q and nextUp(q).
    const q: f64 = 0x1p-918 - 9.0 * 0x1p-970;
    try std.testing.expect(got.lo <= q);
    try std.testing.expect(got.hi >= interval.nextUp(q));
    try std.testing.expect(got.lo > 0.0);
    try std.testing.expect(got.hi < 0x1p-917);
}

test "gcd: coprime subnormal mantissas retain the smallest dyadic unit" {
    const m: u64 = @as(u64, 1) << 52;
    const a: f64 = @bitCast(m - 1);
    const b: f64 = @bitCast(m - 3);
    const xs = [_]Interval{ point(a), point(b) };
    const got = try answer(ext.gcd(&xs));
    const unit: f64 = @bitCast(@as(u64, 1));
    try std.testing.expectEqual(unit, got.lo);
    try std.testing.expectEqual(unit, got.hi);
}
