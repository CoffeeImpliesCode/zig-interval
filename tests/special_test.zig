//! The special functions: the real Gamma function and the discrete factorial.
//!
//! They live at `interval.ext.gamma` and `interval.ext.factorial`, with the
//! matching flat aliases. Their values are not reachable from the elementary
//! primitives by an exact argument - `Gamma` has poles, a range that leaves
//! the format long before its argument does, and no closed form at a general
//! real - which is why every oracle below is written out rather than called
//! from the library, and why none of them is a rounded `f64` constant: an
//! enclosure test whose reference is the answer it is testing proves nothing.
//!
//! **Where each reference comes from.** There are four kinds here and each is
//! a proof rather than a number typed in.
//!
//!   * INTEGERS. `Gamma(n) = (n-1)!` and `n!` is a product of integers, so
//!     the table of exact values is checked against a chain of directed
//!     products rather than believed: each row fails unless the chain, which
//!     rounds every step of the way, lands on the literal from both
//!     directions. A mistyped or rounded literal is caught before it is used
//!     as a witness, and a value past the end of the format saturates to
//!     `floatMax` below and `+inf` above, which is the proof that the product
//!     no longer fits.
//!   * `sqrt(pi)`. The only transcendental-shaped value any assertion here
//!     needs, and it is computed rather than quoted: Machin's identity
//!     `pi/4 = 4 atan(1/5) - atan(1/239)` over the alternating series for
//!     `atan(1/n)`, whose remainder is bounded by its first omitted term
//!     because the terms decrease. It is evaluated in `f128` using only the
//!     IEEE correctly rounded `+`, `-`, `*` and `/`, and the square root is
//!     taken in `f64` where IEEE 754 defines it as correctly rounded. It is
//!     NOT taken in `f128`, because Zig 0.16's `f128` transcendentals are the
//!     `f64` results widened - `tests/soundness_shared.zig` measured that over
//!     20,000 draws - and a widened `f64` root under a wider type would be an
//!     `f64` answer wearing a costume.
//!   * THE HALF-INTEGERS. `Gamma(1/2 - n) = (-1)^n sqrt(pi) prod 2/(2k-1)`
//!     and `Gamma(n + 1/2)` is that product into `sqrt(pi)`: the recurrence
//!     `Gamma(x+1) = x Gamma(x)` applied to `Gamma(1/2) = sqrt(pi)`, with the
//!     coefficient carried in a directed bracket. Nothing here evaluates a
//!     Gamma function.
//!   * POWERS OF TWO. The near-pole and the subnormal arguments are bounded
//!     by exact powers of two and by the two classical facts that
//!     `Gamma(1) = Gamma(2) = 1` with `log Gamma` convex, which put
//!     `Gamma(1 + e)` between `1/4` and `1`, and `Gamma(x) > 1/4` for
//!     `x > 0`. The witnesses are integers, so no rounding of the witness is
//!     what the assertion compares.
//!
//! **What is asserted, and what is not.** Containment only. No width is
//! pinned anywhere in this file, and no answer is compared for equality with
//! anything: a wider answer than the reference needs is a correct answer.
//! The assertions that are not containment are the ones SOUNDNESS forces on
//! any enclosure at all - a `null` at a pole, an infinity where the value has
//! left the format, a bound that has to keep the sign of a value too small to
//! name. Those do not describe an implementation, they describe the reals.
//!
//! **Where the tests are thin.** `Gamma` at an argument that is neither a
//! half-integer nor near a pole - `Gamma(0.25)`, `Gamma(-1.25)` - has no
//! closed form to be a witness for, and inventing a bound for it here would be
//! a second implementation of the same function, which is the mistake this
//! file's oracle exists to avoid. Those arguments are certified instead by
//! `tests/corpus_test.zig`, where MPFR at 256 bits supplies the bracket from
//! outside this tree entirely.

const std = @import("std");
const interval = @import("interval");
const Interval = interval.Interval;

/// The two functions under test, under the names the public catalog gives
/// them. Taken as values rather than called as `interval.ext.gamma(...)` so
/// that the whole file refers to one spelling.
const gamma = interval.ext.gamma;
const factorial = interval.ext.factorial;

const inf = std.math.inf(f64);
const neg_inf: f64 = -inf;
const float_max = std.math.floatMax(f64);

/// The smallest positive double: the least value the format holds above zero,
/// and therefore the least upper bound a POSITIVE real smaller than every
/// normal number can be given.
const min_subnormal = std.math.floatTrueMin(f64);

// ---------------------------------------------------------------------------
// The oracle
// ---------------------------------------------------------------------------

/// A certified bracket for one real: `lo <= value <= hi`.
///
/// The shape is what makes it usable. An assertion against it is
/// `got.lo <= hi and got.hi >= lo`, because the bracket's LOW end is a witness
/// the answer's HIGH end has to reach past and its HIGH end is a witness the
/// answer's LOW end has to reach under. Reading the pair the other way round
/// asserts a width, and a width is not a property of an enclosure.
const Brace = struct {
    lo: f64,
    hi: f64,
};

/// Containment of an interval in a bracket.
fn expectHolds(got: Interval, truth: Brace) !void {
    try expectBrace(.{ .lo = got.lo, .hi = got.hi }, truth);
}

/// Containment of one bracket in another: the same question asked of a product
/// of two answers rather than of one of them.
fn expectBrace(got: Brace, truth: Brace) !void {
    try std.testing.expect(got.lo <= truth.hi);
    try std.testing.expect(got.hi >= truth.lo);
}

/// The four corner products of two enclosures, as a bracket.
///
/// The exact image of `a * b` is the hull of the four corners and every corner
/// is attained, so this is the whole of what a pair of answers certifies about
/// their product - and it is what lets an identity between two library
/// functions be checked without either of them being evaluated here.
fn corners(a: Interval, b: Interval) Brace {
    const c = [4]f64{
        a.lo * b.lo, a.lo * b.hi,
        a.hi * b.lo, a.hi * b.hi,
    };
    var lo = c[0];
    var hi = c[0];
    for (c) |v| {
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    return .{ .lo = lo, .hi = hi };
}

/// The answer of a function with a partial domain, with the two checks every
/// answer in this package owes: that it answered, and that what it answered
/// respects `lo <= hi`.
fn answered(x: ?Interval) !Interval {
    const i = x orelse return error.OutOfDomain;
    try std.testing.expect(i.lo <= i.hi);
    return i;
}

/// A `null` where the mathematics says there is no image.
fn refused(x: ?Interval) !void {
    try std.testing.expect(x == null);
}

fn point(v: f64) Interval {
    return Interval.init(v, v);
}

/// The largest double below `v`, and the smallest above it.
///
/// The conversion is to nearest, which is not a bound in either direction, and
/// the library's `roundDown`/`roundUp` step the result by one. One step is
/// enough: the conversion is off by at most half a ULP, so the double it
/// produced is at most one ULP away from `v`, and stepping crosses it. Those
/// two helpers are used rather than `prevDown`/`nextUp` because they are the
/// outward bounds this library rounds every bound with, including the two
/// places where they move instead of stepping: a computed `-inf` stands for a
/// real that overflowed BELOW the format and so is not an upper bound of
/// anything, and a computed zero is already its own smallest bound.
fn f64Down(v: f128) f64 {
    return interval.roundDown(@as(f64, @floatCast(v)));
}

fn f64Up(v: f128) f64 {
    return interval.roundUp(@as(f64, @floatCast(v)));
}

/// `atan(1/n)` for `n >= 2`, by
///
///     atan(1/n) = sum over k >= 0 of (-1)^k / ((2k+1) * n^(2k+1))
///
/// The terms decrease strictly for `n >= 2`, so this is an alternating series
/// and the remainder after `terms` terms is no larger than the first omitted
/// one. That is what makes this an oracle and not an estimate. `f128` is used
/// because its `+`, `-`, `*` and `/` are the IEEE correctly rounded operations
/// at 113 significand bits, so every rounding in the loop is accounted for in
/// the bound `piBracket` states.
fn atanInverse(n: u32, terms: usize) f128 {
    const nf: f128 = @floatFromInt(n);
    var sum: f128 = 0.0;
    // n^(2k+1) starts at n itself, so the k = 0 term is 1/n and not 1.
    var power: f128 = nf;
    var k: usize = 0;
    while (k < terms) : (k += 1) {
        const odd: f128 = @floatFromInt(2 * k + 1);
        const term: f128 = 1.0 / (odd * power);
        if (k % 2 == 0) sum += term else sum -= term;
        power *= nf * nf;
    }
    return sum;
}

/// pi, bracketed, from Machin: `pi/4 = 4 atan(1/5) - atan(1/239)`.
///
/// The error of that evaluation is bounded rather than measured. Writing `u`
/// for one unit in the last place of `f128`, so `u = 2^-113`:
///
///   * `power` is a chain of `terms` correctly rounded multiplications by the
///     EXACT `n*n`, so it carries a relative error of at most `terms * u`, and
///     the term that uses it carries at most `(terms + 2) * u` including the
///     division by the exact odd integer.
///   * Every partial sum of an alternating series with decreasing terms is
///     bounded by the first term `1/n`, so the `terms` additions cost at most
///     `terms/n * u` between them.
///   * The truncation after `terms` terms is at most
///     `1/((2*terms+1) * n^(2*terms+1))`, which is below 1e-42 for both
///     arguments here and so is not what limits the bracket.
///
/// For the 40 and 10 terms below those three come to less than 3e-31 for pi.
/// The guard this function subtracts and adds is `2^-96`, roughly forty times
/// that, and it is thirteen orders of magnitude below one ULP of a double, so
/// it cannot move the answer: it is there so that the conversion to `f64` is
/// provably outward rather than possibly inward.
fn piBracket() Brace {
    const computed: f128 = 16.0 * atanInverse(5, 40) - 4.0 * atanInverse(239, 10);
    const guard: f128 = 0x1p-96;
    return .{
        .lo = f64Down(computed - guard),
        .hi = f64Up(computed + guard),
    };
}

/// `sqrt(pi)`, from `piBracket` and the IEEE square root.
///
/// `@sqrt` on `f64` is correctly rounded by IEEE 754, so for a positive `p` the
/// true `sqrt(p)` is within half a ULP of the double `@sqrt(p)` produced, and
/// one outward step in each direction is outside it. The square root is
/// increasing, so `roundDown(@sqrt(pi.lo)) <= sqrt(pi)` and
/// `roundUp(@sqrt(pi.hi)) >= sqrt(pi)`: the two ends of the answer are outside
/// the true value by a step rather than by an assumption.
fn sqrtPiBracket() Brace {
    const p = piBracket();
    return .{
        .lo = interval.roundDown(@sqrt(p.lo)),
        .hi = interval.roundUp(@sqrt(p.hi)),
    };
}

/// `coeff_n = 4^n n! / (2n)!`, the rational that carries `sqrt(pi)` to the
/// negative half-integers and back.
///
/// The recurrence is `Gamma(x+1) = x Gamma(x)` applied `n` times down from
/// `Gamma(1/2) = sqrt(pi)`, and it reads
///
///     coeff_0 = 1,  coeff_k = coeff_{k-1} * 2/(2k-1)
///
/// because `Gamma(1/2 - k) = Gamma(1/2 - (k-1)) / (-(2k-1))`. The only
/// rounding in a step is the division by the EXACT odd integer - the doubling
/// is exact - so taking the two directions of it keeps a bracket by induction,
/// and that bracket stays valid down into the subnormals because `roundDown`
/// and `roundUp` step on the real grid of the format at every magnitude.
fn halfCoeff(n: usize) Brace {
    var lo: f64 = 1.0;
    var hi: f64 = 1.0;
    var k: usize = 1;
    while (k <= n) : (k += 1) {
        const odd: f64 = @floatFromInt(2 * k - 1);
        lo = interval.roundDown((lo * 2.0) / odd);
        hi = interval.roundUp((hi * 2.0) / odd);
    }
    return .{ .lo = lo, .hi = hi };
}

/// `Gamma(n + 1/2)` for `n >= 0`, which is `sqrt(pi)` divided by the
/// coefficient.
fn gammaPosHalf(n: usize) Brace {
    const s = sqrtPiBracket();
    const c = halfCoeff(n);
    // A quotient of two positive brackets: the low end of the quotient is the
    // low end of the numerator over the HIGH end of the denominator, and the
    // other way round at the top. Getting that the wrong way round would state
    // a bracket the true value can fall out of.
    return .{
        .lo = interval.roundDown(s.lo / c.hi),
        .hi = interval.roundUp(s.hi / c.lo),
    };
}

/// `Gamma(1/2 - n)` for `n >= 0`, which is the coefficient times `sqrt(pi)`
/// with the sign of `(-1)^n`.
///
/// The sign alternation is the recurrence's: `Gamma(1/2) > 0`, and every step
/// down divides by a negative number. It is the part a reflection formula has
/// to reproduce, and the part a value that has crossed a pole usually does
/// not.
fn gammaNegHalf(n: usize) Brace {
    const s = sqrtPiBracket();
    const c = halfCoeff(n);
    const m = Brace{
        .lo = interval.roundDown(c.lo * s.lo),
        .hi = interval.roundUp(c.hi * s.hi),
    };
    return if (n % 2 == 0) m else Brace{ .lo = -m.hi, .hi = -m.lo };
}

/// `(-1)^negative * pi`, bracketed, for the reflection identity.
fn reflectedPi(negative: bool) Brace {
    const p = piBracket();
    return if (negative) Brace{ .lo = -p.hi, .hi = -p.lo } else p;
}

/// A bracket for `n!` from a chain of directed-rounded products.
///
/// Each step multiplies by an EXACT integer and `roundDown`/`roundUp` of a
/// correctly rounded product bound the true product on either side, so the
/// bracket holds by induction. `n!` is never evaluated as a single rounding
/// anywhere in this file, which is what keeps the rows past 22! meaningful:
/// those integers have more than 53 bits in them and a literal could not hold
/// one. At the top of the format the chain does not fail either - `roundDown`
/// of an overflow is `floatMax`, below every real past the end of the range,
/// and `roundUp` of one is `+inf`, above all of them - so a saturated chain IS
/// the proof that the product no longer fits, and the test below reads it as
/// such.
fn factorialBracket(n: u64) Brace {
    var lo: f64 = 1.0;
    var hi: f64 = 1.0;
    var k: u64 = 2;
    while (k <= n) : (k += 1) {
        const f: f64 = @floatFromInt(k);
        lo = interval.roundDown(lo * f);
        hi = interval.roundUp(hi * f);
    }
    return .{ .lo = lo, .hi = hi };
}

// ---------------------------------------------------------------------------
// gamma
// ---------------------------------------------------------------------------

/// `Gamma(n) = (n-1)!` for the positive integers this format holds exactly.
///
/// Every literal below is checked against `factorialBracket` before it is
/// used as a witness, so a literal is a result of that comparison rather than
/// an assumption in a comment. The check is that the literal sits INSIDE the
/// chain, not that either end of the chain equals it: the chain steps every
/// product outward, so `2!` is already a step wider than `2` at both ends and
/// a chain could not be asked to be as narrow as the integer it proves.
const integer_gamma = [_]struct { n: u64, value: f64 }{
    .{ .n = 1, .value = 1.0 },
    .{ .n = 2, .value = 1.0 },
    .{ .n = 3, .value = 2.0 },
    .{ .n = 4, .value = 6.0 },
    .{ .n = 5, .value = 24.0 },
    .{ .n = 6, .value = 120.0 },
    .{ .n = 7, .value = 720.0 },
    .{ .n = 8, .value = 5040.0 },
    .{ .n = 9, .value = 40320.0 },
    .{ .n = 10, .value = 362880.0 },
    .{ .n = 11, .value = 3628800.0 },
    .{ .n = 12, .value = 39916800.0 },
    .{ .n = 13, .value = 479001600.0 },
    .{ .n = 14, .value = 6227020800.0 },
    .{ .n = 15, .value = 87178291200.0 },
    .{ .n = 16, .value = 1307674368000.0 },
    .{ .n = 17, .value = 20922789888000.0 },
    .{ .n = 18, .value = 355687428096000.0 },
    .{ .n = 19, .value = 6402373705728000.0 },
    .{ .n = 20, .value = 121645100408832000.0 },
    .{ .n = 21, .value = 2432902008176640000.0 },
    .{ .n = 22, .value = 51090942171709440000.0 },
    .{ .n = 23, .value = 1124000727777607680000.0 },
};

test "gamma: at a positive integer the value is the factorial of one less" {
    for (integer_gamma) |row| {
        // The literal is a witness because it IS the integer, exactly. It is
        // not compared for equality with either end of the chain: the chain is
        // a bracket that steps outward on every one of its products, so even
        // `2!` is a step wider than `2` at both ends, and asking an oracle to
        // be tighter than it can be is asking for a coincidence. What is
        // checked is that the independently computed chain CONTAINS the
        // literal, which is what catches a mistyped or rounded one.
        const chain = factorialBracket(row.n - 1);
        try expectBrace(chain, .{ .lo = row.value, .hi = row.value });

        const x: f64 = @floatFromInt(row.n);
        try expectHolds(try answered(gamma(point(x))), chain);
    }
}

test "gamma: a high positive integer is held by a chain of directed products" {
    // Past 22! the value is an integer this format cannot hold, which is why
    // the witness is a bracket around it rather than a literal, and why a
    // rounded `f64` would be the wrong thing to compare against.
    for ([_]u64{ 23, 25, 30, 50, 100, 170, 171 }) |n| {
        const x: f64 = @floatFromInt(n);
        try expectHolds(try answered(gamma(point(x))), factorialBracket(n - 1));
    }
}

test "gamma: the positive half-integers are sqrt(pi) over a rational" {
    // The tightest rows in this file on purpose. The oracle bracket is a step
    // or two wide around `sqrt(pi)` and a rational multiple of it, so an
    // answer that fell back on the coarse global bound this library is allowed
    // to use where it cannot resolve a minimum would be caught here rather
    // than at an argument that has one.
    for (0..8) |n| {
        const x: f64 = 0.5 + @as(f64, @floatFromInt(n));
        try expectHolds(try answered(gamma(point(x))), gammaPosHalf(n));
    }
}

test "gamma: below the first pole the value is the same rational, signed" {
    for (0..8) |n| {
        const x: f64 = 0.5 - @as(f64, @floatFromInt(n));
        try expectHolds(try answered(gamma(point(x))), gammaNegHalf(n));
    }
}

test "gamma: the reflection identity holds across a pole" {
    // `Gamma(x) Gamma(1-x) = pi / sin(pi x)`, and at `x = 1/2 - n` the sine
    // is `(-1)^n` exactly, so the product of the two answers is `(-1)^n pi`.
    // The witnesses here are the two LIBRARY answers, hulled by their four
    // corners, checked against a bracket for pi: neither function is
    // evaluated on this side of the assertion.
    for (0..5) |n| {
        const below = try answered(gamma(point(0.5 - @as(f64, @floatFromInt(n)))));
        const above = try answered(gamma(point(0.5 + @as(f64, @floatFromInt(n)))));
        try expectBrace(corners(below, above), reflectedPi(n % 2 == 1));
    }
}

test "gamma: a pole is an argument with no image at all" {
    // Zero and the negative integers are the poles. There is no real value
    // there, so the answer is `null` - which in this library is the strong
    // claim that the image is empty, not a shrug.
    for ([_]f64{ 0.0, -1.0, -2.0, -3.0, -4.0, -10.0, -170.0 }) |pole| {
        try refused(gamma(point(pole)));
    }
    // The signed zero is zero. An implementation that compared bit patterns
    // instead of values would answer a real number here, and the real number
    // would be about 1/|0|.
    try refused(gamma(Interval.init(-0.0, -0.0)));
}

test "gamma: an argument between two poles is the whole real line" {
    // Every one of these has a pole inside it, and on each side of a pole the
    // value runs off in both directions, so the image is all of R and NO pair
    // of finite endpoints contains it. The two infinities are therefore not a
    // quality of this implementation but the only sound answer, and an answer
    // that stopped at the first pole would be finite and wrong.
    for ([_][2]f64{
        .{ -1.0, 1.0 },
        .{ -3.0, -1.0 },
        .{ -2.0, 2.0 },
        .{ -0.5, 0.5 },
        .{ -4.0, 2.0 },
    }) |span| {
        const got = try answered(gamma(Interval.init(span[0], span[1])));
        try std.testing.expect(got.lo == neg_inf);
        try std.testing.expect(got.hi == inf);
    }
}

test "gamma: an interval that only touches a pole is unbounded on that side" {
    // `(0, 1]` has no pole inside it: the value runs from `+inf` at the right
    // of zero down to `Gamma(1) = 1`, so the image is `[1, +inf)`. The answer
    // has to reach 1 from below and run off to `+inf`, and it must NOT be
    // `null`: the domain is only partly reached here, which is a different
    // answer from having no image at all.
    const got = try answered(gamma(Interval.init(0.0, 1.0)));
    try std.testing.expect(got.lo <= 1.0);
    try std.testing.expect(got.hi == inf);
}

test "gamma: just off a pole the value is large and signed by the recurrence" {
    // `Gamma(-1 + e) = -Gamma(1 + e) / (e(1-e))` and `Gamma(1 + e)` is
    // between `1/4` and `1` on `(0, 1)`: the lower end from `Gamma > 1/4`,
    // the upper from `log Gamma` being convex between `Gamma(1) = Gamma(2) = 1`
    // and so being under zero there. Every witness below is a power of two, so
    // nothing rounded is what the assertion compares.
    const eps: f64 = 0x1p-20;

    // -2^21 < Gamma(-1 + e) < -2^18: large, and NEGATIVE.
    const at_pole_one = try answered(gamma(point(-1.0 + eps)));
    try std.testing.expect(at_pole_one.lo <= -262144.0);
    try std.testing.expect(at_pole_one.hi >= -2097152.0);

    // The same argument one pole further down, where the value is POSITIVE:
    // 2^17 < Gamma(-2 + e) < 2^20. The pair is what a reflection formula that
    // lost its sign cannot both satisfy.
    const at_pole_two = try answered(gamma(point(-2.0 + eps)));
    try std.testing.expect(at_pole_two.lo <= 1048576.0);
    try std.testing.expect(at_pole_two.hi >= 131072.0);

    // And on the far side of the first pole the sign is positive again, which
    // is the third leg of the same statement.
    const past_pole_one = try answered(gamma(point(-1.0 - eps)));
    try std.testing.expect(past_pole_one.lo <= 1048576.0);
    try std.testing.expect(past_pole_one.hi >= 131072.0);
}

test "gamma: an interval holding the minimum is bounded by its ends" {
    // `[0.5, 1.5]` holds the minimum of Gamma (it is near 1.4616) and both
    // witnesses below are exact:
    //
    //   * `Gamma(0.5) = sqrt(pi)` is IN the image, so the answer's high bound
    //     has to reach it;
    //   * `Gamma(1.5) = sqrt(pi)/2` is in the image too and is ABOVE the
    //     minimum, which is attained inside this interval, so the answer's low
    //     bound has to reach under it;
    //   * `log Gamma` is convex, so the maximum over an interval is at one of
    //     its ends - here the end that gives the bound above, from the other
    //     side - and it is FINITE. An answer of `+inf` at the top would be
    //     sound but is not what an image that stops at `sqrt(pi)` can justify
    //     on the low side, and this row is where the two ends are read
    //     together.
    const s = sqrtPiBracket();
    const got = try answered(gamma(Interval.init(0.5, 1.5)));
    try std.testing.expect(got.lo <= interval.roundUp(s.hi / 2.0));
    try std.testing.expect(got.hi >= s.lo);
    try std.testing.expect(got.hi != inf);

    // `[1, 2]` is the other half: the minimum is inside it and BOTH ends are
    // exactly 1, so convexity pins the top of the answer at a number two
    // witnesses agree on, while the bottom is only pinned as far as the proved
    // coarse bound allows.
    const two = try answered(gamma(Interval.init(1.0, 2.0)));
    try std.testing.expect(two.hi >= 1.0);
    try std.testing.expect(two.hi != inf);
}

test "gamma: over an interval with no extremum inside, both ends are the endpoints" {
    // Convexity of `log Gamma` says the maximum over `[a, b]` is the larger of
    // the two endpoint values, and on these intervals the value is increasing,
    // so the minimum is the smaller of them. All four numbers are integers, so
    // this is an exact witness at both ends of the answer and the test cannot
    // pass on an answer that looked at one end.
    for ([_]struct { lo: f64, hi: f64, first: f64, last: f64 }{
        .{ .lo = 2.0, .hi = 5.0, .first = 1.0, .last = 24.0 },
        .{ .lo = 3.0, .hi = 4.0, .first = 2.0, .last = 6.0 },
        .{ .lo = 4.0, .hi = 4.0, .first = 6.0, .last = 6.0 },
    }) |span| {
        const got = try answered(gamma(Interval.init(span.lo, span.hi)));
        try std.testing.expect(got.lo <= span.first);
        try std.testing.expect(got.hi >= span.last);
        try std.testing.expect(got.hi != inf);
    }
}

test "gamma: a value past the end of the format is an infinity, not a refusal" {
    // The chain is the proof, in the same arithmetic the witness uses. 170!
    // is still a double; the step that multiplies it by 171 overflows in `f64`,
    // and IEEE rounds an overflow to `+inf` only when the exact result is past
    // `floatMax`, so a chain that lands there has PROVED 171! > floatMax
    // without ever computing 171!.
    const fits = factorialBracket(170);
    const does_not = factorialBracket(171);
    try std.testing.expect(fits.hi <= float_max);
    try std.testing.expect(does_not.hi == inf);

    // `Gamma(172) = 171!` is a real number like any other that is simply
    // bigger than the largest double. No finite bound can hold it, so the high
    // end is `+inf`; and it is not `null`, because a null would claim the
    // image is empty and it is not.
    for ([_]f64{ 172.0, 200.0, 1000.0 }) |x| {
        const got = try answered(gamma(point(x)));
        try std.testing.expect(got.hi == inf);
    }

    // The one below the edge is still held exactly enough to be checked.
    try expectHolds(try answered(gamma(point(171.0))), fits);

    // An argument whose image runs off the top of the format is a ray, and
    // `Gamma(1) = 1` is in its image, so the low end is still pinned.
    const span = try answered(gamma(Interval.init(1.0, 200.0)));
    try std.testing.expect(span.hi == inf);
    try std.testing.expect(span.lo <= 1.0);
}

test "gamma: a value below the smallest double keeps its side of zero" {
    // `Gamma(1/2 - 400) = Gamma(-399.5)` is positive: the recurrence divides
    // by a negative number on every step down, so the sign alternates with the
    // number of poles crossed and 400 of them is an even number. `Gamma` has no
    // zeros on the reals, so this value is a positive real and NOT a zero,
    // however far below the format it has gone - which is all the following
    // needs, and no claim is made about its magnitude.
    //
    // What that forces: the low bound of an enclosure of a positive real is at
    // most zero, and the high bound is at least the smallest positive double.
    // `[0, 0]` would hold no positive value at all. `[-3, 3]` is sound and is
    // allowed; what is not allowed is losing the side of zero.
    const tiny_positive = try answered(gamma(point(-399.5)));
    try std.testing.expect(tiny_positive.lo <= 0.0);
    try std.testing.expect(tiny_positive.hi >= min_subnormal);

    // One pole further down the value is negative and equally far below the
    // format, and the pair of forced bounds is the mirror: the low bound has
    // to be a NEGATIVE double, because `-0.0` is zero and would exclude it,
    // and the high bound cannot be below the smallest negative double.
    const tiny_negative = try answered(gamma(point(-400.5)));
    try std.testing.expect(tiny_negative.lo <= -min_subnormal);
    try std.testing.expect(tiny_negative.hi >= -min_subnormal);
}

// ---------------------------------------------------------------------------
// factorial
// ---------------------------------------------------------------------------

test "factorial: an argument with no nonnegative integer in it has no image" {
    // This operator is DISCRETE. Its domain is the nonnegative integers and
    // nothing else, so an interval whose integer points are all negative, or
    // which contains no integer at all, has an empty image - which is `null`
    // here, the same strong claim a pole is for gamma.
    // `[3.2, 3.8]` is the row that makes the discrete reading concrete: it
    // straddles 3 without containing it, and an implementation that answered a
    // fractional argument as its nearest integer would answer 6 here. It is
    // the neighbour of `[2.8, 3.2]` in the next test, which does contain 3.
    for ([_][2]f64{
        .{ 0.5, 0.9 },
        .{ 2.5, 2.9 },
        .{ 3.2, 3.8 },
        .{ -1.0, -0.25 },
        .{ -4.0, -2.0 },
        .{ -0.75, -0.51 },
    }) |span| {
        try refused(factorial(Interval.init(span[0], span[1])));
    }

    // The contrast with gamma is the point of the whole pair. 2.5 is a
    // perfectly good argument for the real Gamma function and is not an
    // argument for this one, so the two cannot be one function with two names.
    try std.testing.expect(gamma(point(2.5)) != null);
    try refused(factorial(point(2.5)));
}

test "factorial: an interval holding exactly one integer is that integer's product" {
    // These are the arguments that make the operator discrete: a fractional
    // range with a single integer in it has a single-element image, and an
    // answer that treated the endpoints as products would be wrong on both
    // sides. `[0.9, 1.1]` holds 1 and nothing else, and `[2.8, 3.2]` holds 3
    // and nothing else, so those two answers are 1 and 6. A range holding NO
    // integer at all - `[3.2, 3.8]` - is in the other test, where `null` is
    // the answer; 0! is the row that catches a product which starts at the
    // argument instead of at 1, since it is the one place where the argument
    // is not the answer.
    for ([_]struct { lo: f64, hi: f64, value: f64 }{
        .{ .lo = -0.5, .hi = 0.5, .value = 1.0 },
        .{ .lo = 0.0, .hi = 0.0, .value = 1.0 },
        .{ .lo = 0.9, .hi = 1.1, .value = 1.0 },
        .{ .lo = 2.8, .hi = 3.2, .value = 6.0 },
        .{ .lo = 5.0, .hi = 5.0, .value = 120.0 },
        .{ .lo = 20.0, .hi = 20.0, .value = 2432902008176640000.0 },
    }) |c| {
        const got = try answered(factorial(Interval.init(c.lo, c.hi)));
        try std.testing.expect(got.lo <= c.value);
        try std.testing.expect(got.hi >= c.value);
    }
}

test "factorial: a range of integers holds the products at both ends" {
    // The image of a discrete operator over a range is a SET of integers, so
    // the answer is the hull of the products from the smallest one in the range
    // to the largest, and the two ends are what it has to reach. `[19.5, 21.5]`
    // holds 20 and 21 and nothing else, which are the first two arguments
    // here whose products are not single-step small numbers.
    for ([_]struct { lo: f64, hi: f64, first: f64, last: f64 }{
        .{ .lo = 0.0, .hi = 1.0, .first = 1.0, .last = 1.0 },
        .{ .lo = 0.0, .hi = 3.0, .first = 1.0, .last = 6.0 },
        .{ .lo = 2.5, .hi = 4.5, .first = 6.0, .last = 24.0 },
        .{ .lo = -2.0, .hi = 2.0, .first = 1.0, .last = 2.0 },
        .{ .lo = 19.5, .hi = 21.5, .first = 121645100408832000.0, .last = 51090942171709440000.0 },
    }) |c| {
        const got = try answered(factorial(Interval.init(c.lo, c.hi)));
        try std.testing.expect(got.lo <= c.first);
        try std.testing.expect(got.hi >= c.last);
    }
}

test "factorial: the top of the format is an infinity and not a refusal" {
    // 171! is past the largest double, by the same chain that proves it for
    // gamma above, and 1e18! is past it by an enormous margin and with an
    // argument that is itself an exact integer: 1e18 is 2^18 * 5^18 and
    // 5^18 < 2^53, so the format holds it exactly and there is no rounding in
    // the argument that could make this row about something else.
    // Nothing is claimed about the low end here beyond what the chain already
    // says for the arguments that fit: a sound enclosure of a product that has
    // run off the top of the format may start anywhere below it, and `+inf` at
    // the top is the only thing the mathematics forces.
    for ([_]f64{ 171.0, 200.0, 1e18 }) |n| {
        const got = try answered(factorial(point(n)));
        try std.testing.expect(got.hi == inf);
    }

    // A range that reaches past the end of the format is a ray at the top, and
    // its low end is still the smallest product in the range.
    const span = try answered(factorial(Interval.init(170.0, 171.0)));
    try std.testing.expect(span.hi == inf);
    try std.testing.expect(span.lo <= factorialBracket(170).hi);

    // And the last argument that does fit is still held by the chain.
    try expectHolds(try answered(factorial(point(170.0))), factorialBracket(170));
}

test "factorial and gamma: the discrete operator is gamma one argument to the right" {
    // `n! = Gamma(n+1)` on the nonnegative integers, and the two operators
    // have different domains: this one refuses a fractional argument where
    // that one answers. Checking both against the same certified chain is what
    // makes the pair a statement about the offset rather than about either
    // function's width - an off-by-one in either shows up as a containment
    // failure against a number computed here from integers.
    for ([_]u64{ 0, 1, 2, 3, 5, 10, 17, 20 }) |n| {
        const chain = factorialBracket(n);
        const f: f64 = @floatFromInt(n);
        try expectHolds(try answered(factorial(point(f))), chain);
        try expectHolds(try answered(gamma(point(f + 1.0))), chain);
    }
}