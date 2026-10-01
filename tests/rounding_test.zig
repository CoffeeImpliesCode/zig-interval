const std = @import("std");
const rounding = @import("rounding");

const nextUp = rounding.nextUp;
const prevDown = rounding.prevDown;
const roundUp = rounding.roundUp;
const roundDown = rounding.roundDown;
const piDown = rounding.piDown;
const piUp = rounding.piUp;

/// The smallest positive subnormal, 0x0000000000000001.
const min_subnormal: f64 = @bitCast(@as(u64, 1));

/// The largest finite value, 0x7FEFFFFFFFFFFFFF.
const max_finite: f64 = std.math.floatMax(f64);

/// The largest finite negative, 0xFFEFFFFFFFFFFFFF.
const min_finite: f64 = -std.math.floatMax(f64);

/// Bit pattern of x, for asserting an exact neighbour rather than a value
/// that merely compares equal to it.
fn bits(x: f64) u64 {
    return @bitCast(x);
}

/// The top bit of the f64 layout, set on every negative value including
/// -0.0 and the negative NaNs.
const sign_bit: u64 = 1 << 63;

/// The largest subnormal, 0x000FFFFFFFFFFFFF. The last value below the
/// frontier.
const max_subnormal_pattern: u64 = 0x000FFFFFFFFFFFFF;

/// The smallest normal, 0x0010000000000000. The frontier itself, where a
/// step stops adding to the significand and starts adding to the exponent.
const min_normal_pattern: u64 = 0x0010000000000000;

/// The inverse of `bits`, for a pattern that reads better as a literal
/// than as an offset.
fn fromBits(pattern: u64) f64 {
    return @bitCast(pattern);
}

/// Position of x in the total order IEEE 754 gives the format, where
/// -0.0 sits BELOW +0.0 and the NaNs sit outside the infinities. Every
/// comparison here that has to tell the two zeros apart goes through
/// this, because `<` and `==` on f64 cannot: they call them equal. The
/// key is unsigned, because flipping the pattern of a negative value
/// clears its top bit and the positives have to clear theirs.
fn order(x: f64) u64 {
    const pattern: u64 = @bitCast(x);
    return if (pattern & sign_bit == 0) pattern | sign_bit else ~pattern;
}

/// Comparator for the sweep. The total order and not `<`, which cannot
/// tell the two zeros apart and so cannot put them in an order at all.
fn byOrder(_: void, x: f64, y: f64) bool {
    return order(x) < order(y);
}

test "nextUp: exact neighbour patterns" {
    try std.testing.expectEqual(@as(u64, 0x0000000000000001), bits(nextUp(0.0)));
    try std.testing.expectEqual(@as(u64, 0x0000000000000000), bits(nextUp(-0.0)));
    try std.testing.expectEqual(@as(u64, 0x3FF0000000000001), bits(nextUp(1.0)));
    try std.testing.expectEqual(@as(u64, 0xBFEFFFFFFFFFFFFF), bits(nextUp(-1.0)));
    try std.testing.expectEqual(@as(u64, 0x0000000000000002), bits(nextUp(min_subnormal)));
    try std.testing.expectEqual(@as(u64, 0x7FF0000000000000), bits(nextUp(max_finite)));
    try std.testing.expectEqual(@as(u64, 0x7FF0000000000000), bits(nextUp(std.math.inf(f64))));
    try std.testing.expectEqual(@as(u64, 0xFFEFFFFFFFFFFFFF), bits(nextUp(-std.math.inf(f64))));
    try std.testing.expectEqual(@as(u64, 0xFFEFFFFFFFFFFFFE), bits(nextUp(min_finite)));
}

test "prevDown: exact predecessor patterns" {
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), bits(prevDown(0.0)));
    try std.testing.expectEqual(@as(u64, 0x8000000000000001), bits(prevDown(-0.0)));
    try std.testing.expectEqual(@as(u64, 0x3FEFFFFFFFFFFFFF), bits(prevDown(1.0)));
    try std.testing.expectEqual(@as(u64, 0xBFF0000000000001), bits(prevDown(-1.0)));
    try std.testing.expectEqual(@as(u64, 0x0000000000000000), bits(prevDown(min_subnormal)));
    try std.testing.expectEqual(@as(u64, 0x7FEFFFFFFFFFFFFE), bits(prevDown(max_finite)));
    try std.testing.expectEqual(@as(u64, 0xFFF0000000000000), bits(prevDown(-std.math.inf(f64))));
    try std.testing.expectEqual(@as(u64, 0x7FEFFFFFFFFFFFFF), bits(prevDown(std.math.inf(f64))));
    // Nothing sits between the largest finite negative and -inf, so that
    // is its predecessor.
    try std.testing.expectEqual(@as(u64, 0xFFF0000000000000), bits(prevDown(min_finite)));
}

test "round trip: the two steps invert each other" {
    // The infinities are absent on purpose: each step saturates there, so
    // the round trip lands on the adjacent finite value instead of back.
    const values = [_]f64{
        0.0,                     -0.0,
        1.0,                     -1.0,
        0.5,                     -0.5,
        min_subnormal,           -min_subnormal,
        max_finite,              min_finite,
        1e300,                   -1e300,
        0.1,                     -0.1,
        @floatCast(std.math.pi),
    };
    for (values) |x| {
        try std.testing.expectEqual(bits(x), bits(prevDown(nextUp(x))));
        try std.testing.expectEqual(bits(x), bits(nextUp(prevDown(x))));
    }
}

test "sign: both steps move toward positive infinity" {
    try std.testing.expect(nextUp(-1.0) > -1.0);
    try std.testing.expect(nextUp(-1.0) < 0.0);
    try std.testing.expect(prevDown(1.0) < 1.0);
    try std.testing.expect(prevDown(1.0) > 0.0);
    try std.testing.expect(nextUp(-min_finite) > min_finite);
    try std.testing.expect(prevDown(max_finite) < max_finite);
}

test "monotonicity: both steps rise with x" {
    var last_up = nextUp(-16.0);
    var last_down = prevDown(-16.0);
    try std.testing.expect(last_up > -16.0);
    try std.testing.expect(last_down < -16.0);

    // -0.0 is the predecessor of +0.0 yet compares equal to it, so the
    // downward step is only numerically below x away from zero. The
    // zeros themselves are pinned bit for bit by the tests above.
    var step: usize = 1;
    while (step < 2048) : (step += 1) {
        const x = @as(f64, @floatFromInt(@as(i32, @intCast(step)) - 1024)) / 64.0;
        const up = nextUp(x);
        const down = prevDown(x);
        try std.testing.expect(up > x);
        if (x != 0.0) try std.testing.expect(down < x);
        try std.testing.expect(up > last_up);
        try std.testing.expect(down > last_down);
        last_up = up;
        last_down = down;
    }
}

test "monotonicity: contiguous through the subnormal range" {
    var pattern: u64 = 1;
    while (pattern <= 64) : (pattern += 1) {
        const x: f64 = @bitCast(pattern);
        const up = nextUp(x);
        const down = prevDown(x);
        try std.testing.expect(up > x);
        try std.testing.expect(down < x);
        try std.testing.expectEqual(pattern + 1, bits(up));
        // The predecessor of the smallest subnormal is +0.0, the only
        // pattern here that steps down out of the exponent range.
        try std.testing.expectEqual(@max(pattern - 1, 0), bits(down));
    }
}

test "infinities: stepping saturates instead of wrapping" {
    const inf = std.math.inf(f64);
    try std.testing.expectEqual(inf, nextUp(inf));
    try std.testing.expectEqual(-inf, prevDown(-inf));
    try std.testing.expectEqual(min_finite, nextUp(-inf));
    try std.testing.expectEqual(max_finite, prevDown(inf));
    // The pattern after +inf is a NaN, so the guard has to come first.
    try std.testing.expect(!std.math.isNan(nextUp(inf)));
    try std.testing.expect(!std.math.isNan(nextUp(-inf)));
    try std.testing.expect(!std.math.isNan(prevDown(inf)));
    try std.testing.expect(!std.math.isNan(prevDown(-inf)));
}

test "NaN: propagates unchanged through both steps" {
    const nan = std.math.nan(f64);
    try std.testing.expect(std.math.isNan(nextUp(nan)));
    try std.testing.expect(std.math.isNan(prevDown(nan)));
    try std.testing.expectEqual(bits(nan), bits(nextUp(nan)));
    try std.testing.expectEqual(bits(nan), bits(prevDown(nan)));
    try std.testing.expect(std.math.isNan(nextUp(-nan)));
    try std.testing.expect(std.math.isNan(prevDown(-nan)));
}

// ---------------------------------------------------------------------------
// The non-strict pair: the two steps every computed bound in the library
// passes through
// ---------------------------------------------------------------------------

test "roundUp: exact upper bound patterns" {
    // The same inputs as the nextUp rows above, and the same answer at
    // every one of them except the two zeros and -inf, which are the
    // three the two functions are asked about differently. They are
    // repeated here rather than left to the zeros and infinity tests
    // below so that the two tables can be read against each other.
    try std.testing.expectEqual(@as(u64, 0x0000000000000000), bits(roundUp(0.0)));
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), bits(roundUp(-0.0)));
    try std.testing.expectEqual(@as(u64, 0x3FF0000000000001), bits(roundUp(1.0)));
    try std.testing.expectEqual(@as(u64, 0xBFEFFFFFFFFFFFFF), bits(roundUp(-1.0)));
    try std.testing.expectEqual(@as(u64, 0x0000000000000002), bits(roundUp(min_subnormal)));
    // A negative value one step from zero is one step from -0.0, because
    // the outward direction is toward the interior of the range and not
    // toward the end the sign points at.
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), bits(roundUp(-min_subnormal)));
    try std.testing.expectEqual(@as(u64, 0x0010000000000000), bits(roundUp(fromBits(max_subnormal_pattern))));
    try std.testing.expectEqual(@as(u64, 0x0010000000000001), bits(roundUp(fromBits(min_normal_pattern))));
    // The top of the range, where the only f64 above the largest finite is
    // the infinity the step is supposed to be widening PAST, not toward.
    try std.testing.expectEqual(@as(u64, 0x7FF0000000000000), bits(roundUp(max_finite)));
    try std.testing.expectEqual(@as(u64, 0x7FF0000000000000), bits(roundUp(std.math.inf(f64))));
    try std.testing.expectEqual(@as(u64, 0xFFEFFFFFFFFFFFFF), bits(roundUp(-std.math.inf(f64))));
    try std.testing.expectEqual(@as(u64, 0xFFEFFFFFFFFFFFFE), bits(roundUp(min_finite)));
}

test "roundDown: exact lower bound patterns" {
    // The mirror of the rows above against the prevDown rows, and the
    // same three differences the other way round.
    try std.testing.expectEqual(@as(u64, 0x0000000000000000), bits(roundDown(0.0)));
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), bits(roundDown(-0.0)));
    try std.testing.expectEqual(@as(u64, 0x3FEFFFFFFFFFFFFF), bits(roundDown(1.0)));
    try std.testing.expectEqual(@as(u64, 0xBFF0000000000001), bits(roundDown(-1.0)));
    try std.testing.expectEqual(@as(u64, 0x0000000000000000), bits(roundDown(min_subnormal)));
    // The mirror of the row above: away from the zero on the negative
    // side, the step is away from the interior of the range.
    try std.testing.expectEqual(@as(u64, 0x8000000000000002), bits(roundDown(-min_subnormal)));
    try std.testing.expectEqual(@as(u64, 0x000FFFFFFFFFFFFE), bits(roundDown(fromBits(max_subnormal_pattern))));
    try std.testing.expectEqual(@as(u64, 0x000FFFFFFFFFFFFF), bits(roundDown(fromBits(min_normal_pattern))));
    try std.testing.expectEqual(@as(u64, 0x7FEFFFFFFFFFFFFE), bits(roundDown(max_finite)));
    try std.testing.expectEqual(@as(u64, 0x7FEFFFFFFFFFFFFF), bits(roundDown(std.math.inf(f64))));
    try std.testing.expectEqual(@as(u64, 0xFFF0000000000000), bits(roundDown(-std.math.inf(f64))));
    try std.testing.expectEqual(@as(u64, 0xFFF0000000000000), bits(roundDown(min_finite)));
}

test "round trip: the non-strict pair inverts each other" {
    // The same round trip the strict pair has above, over the same kind
    // of cases and for the same reason: each of the two is one
    // representable step, so stepping the other way lands back on the
    // argument. It holds at the zeros as well, where the step is no step
    // at all and the round trip is the identity twice over rather than a
    // step out and a step back.
    for (sweep()) |x| {
        try std.testing.expectEqual(bits(x), bits(roundUp(roundDown(x))));
        try std.testing.expectEqual(bits(x), bits(roundDown(roundUp(x))));
    }

    // The infinities are absent from the sweep on purpose: each end
    // widens OUTWARD there rather than stepping to its neighbour, so the
    // round trip comes back with the largest finite of the same sign
    // instead of with the argument. Both are pinned because the failure
    // is silent: the result still looks like a bound.
    try std.testing.expectEqual(@as(u64, 0xFFEFFFFFFFFFFFFF), bits(roundUp(roundDown(-std.math.inf(f64)))));
    try std.testing.expectEqual(@as(u64, 0x7FEFFFFFFFFFFFFF), bits(roundDown(roundUp(std.math.inf(f64)))));
}

test "direction: both bounds leave the value they bound inside" {
    // A bound that excluded the value it bounds would be worse than
    // useless, and this is the row that says which way each of the two
    // is meant to step. Equality is the case the identity at the zeros
    // produces, and the direction row is also the row that says the
    // identity is legal there: a computed zero endpoint is its own bound.
    // The two zeros compare equal to each other, so this loop sees one
    // value where there are two patterns; the bit rows hold them apart.
    for (sweep()) |x| {
        try std.testing.expect(roundUp(x) >= x);
        try std.testing.expect(roundDown(x) <= x);
    }
}

test "step width: the argument itself at a zero, one step everywhere else" {
    // The definition of the two functions is the SMALLEST f64 at or above
    // the argument and the LARGEST at or below it, not merely some such
    // value, and the total order is the only place that is stated: the
    // step is exactly one representable value at every point of the
    // finite range and zero at the pair of signed zeros, where the
    // argument is already its own bound. A pair of steps sold as a pair
    // of one is still sound and still wrong here, which is what makes
    // this the row that catches it, and the sweep is what keeps it from
    // passing on the handful of values named above.
    for (sweep()) |x| {
        const up = order(roundUp(x));
        const down = order(roundDown(x));
        if (x == 0.0) {
            // The identity, and the only place the step is no step at
            // all: the bound is the argument, pattern and all. The two
            // zeros come out as two neighbouring cases here, because the
            // sweep walks the total order, and both land in this branch
            // because they compare equal.
            try std.testing.expectEqual(order(x), up);
            try std.testing.expectEqual(order(x), down);
        } else {
            // One representable value away, on the side the function is
            // for. The arithmetic saturates on purpose: a step taken the
            // wrong way has to be a clean failure HERE and not an integer
            // overflow, which would abort the test binary and take the
            // other nineteen tests with it.
            try std.testing.expectEqual(order(x) +| 1, up);
            try std.testing.expectEqual(order(x) -| 1, down);
        }
    }
}

test "monotonicity: both bounds rise with x" {
    // Over the whole sweep in one pass, so this is the strict form of
    // the claim rather than a sample of it. A lower bound that rose with
    // x somewhere between two cases would put the values in between
    // below their own bound and an upper bound that fell would put them
    // above theirs, and the adjacent pairs are all a sweep of
    // sweep_cases can see.
    //
    // BOTH directions are non-decreasing, and that is the whole of the
    // order claim. Each function is the argument itself or the adjacent
    // value on a fixed side of it, so each one carries the order of its
    // argument along with it; what separates the two is the SIDE they
    // sit on, which is the direction row above and not this one. The
    // reading that roundDown falls as x rises is a slip worth naming
    // rather than a slip worth encoding: roundDown(-2.0) is
    // -2.0000000000000004 and roundDown(-1.0) is -1.0000000000000002,
    // and the second of those is the larger number.
    //
    // The comparisons are the ordinary f64 ones and not the total order,
    // which agrees here and is not needed. At the pair of signed zeros
    // the identity is what makes the lower bound -0.0 for the first and
    // +0.0 for the second, and -0.0 <= +0.0 is exactly the claim this
    // row wants. The strict pair is not a function of the value at the
    // zeros at all, so the row it gets above walks a fixed grid instead.
    const cases = sweep();
    var last_up = roundUp(cases[0]);
    var last_down = roundDown(cases[0]);
    for (cases[1..]) |x| {
        const up = roundUp(x);
        const down = roundDown(x);
        try std.testing.expect(up >= last_up);
        try std.testing.expect(down >= last_down);
        last_up = up;
        last_down = down;
    }
}

test "zeros: the non-strict pair is the identity where the strict pair steps" {
    // These two functions build a BOUND, and that is the whole reason
    // they exist beside nextUp and prevDown. A computed lower endpoint
    // that is exactly +0.0 is already a correct lower bound, so
    // prevDown's answer of -0.0 is one step wider than the bound needs.
    // It is also a DIFFERENT number, and one that compares equal, so a
    // caller reading the sign back out of the interval, or printing the
    // endpoint, sees a value that never occurred.
    //
    // At -0.0 the same argument is stronger, because the strict step
    // CROSSES zero: nextUp(-0.0) is +0.0, so the sign of the endpoint is
    // not preserved but flipped. A step past a computed zero is legal and
    // merely wide; a step that changes which zero it is does not, and no
    // amount of width compensates for it.
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), bits(roundUp(-0.0)));
    try std.testing.expectEqual(@as(u64, 0x0000000000000000), bits(roundDown(0.0)));
    // The other direction at the same two zeros, where the strict pair
    // does not cross: it steps out to the subnormal of the same sign,
    // which is wider than the bound needs and harmless that way.
    try std.testing.expectEqual(@as(u64, 0x0000000000000000), bits(roundUp(0.0)));
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), bits(roundDown(-0.0)));
    // The strict pair on the same four inputs, for the contrast.
    try std.testing.expectEqual(@as(u64, 0x0000000000000000), bits(nextUp(-0.0)));
    try std.testing.expectEqual(@as(u64, 0x0000000000000001), bits(nextUp(0.0)));
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), bits(prevDown(0.0)));
    try std.testing.expectEqual(@as(u64, 0x8000000000000001), bits(prevDown(-0.0)));
    // The two pairs differ at no other point of the range. The step is a
    // step in the total order at every other point of it, the infinities
    // agree as well where both step outward past the end of the range,
    // and the NaN rows below agree because both pairs return the
    // argument. The rows above are where the difference is, and they are
    // the whole of it.
}

test "infinities: the step is outward at the end an overflow reaches" {
    // Load-bearing rather than incidental, and the reason is that an f64
    // reaches an infinity only by overflowing: what it stands for is a
    // finite real past the end of the range. -inf is below every real, so
    // it is not an upper bound of the real that overflowed into it, and
    // the bound [-inf, -inf] excludes that value. -floatMax is above both
    // that real and the infinity, so it bounds the two cases at once.
    // +inf is the mirror: above every real, so not a lower bound of the
    // real that overflowed into it, while +floatMax is below both.
    //
    // The other two ends need no step, and none is available: -inf is
    // already below every real and +inf already above it, so a bound
    // there is already correct and there is no f64 outside it to widen to.
    try std.testing.expectEqual(@as(u64, 0xFFEFFFFFFFFFFFFF), bits(roundUp(-std.math.inf(f64))));
    try std.testing.expectEqual(@as(u64, 0x7FEFFFFFFFFFFFFF), bits(roundDown(std.math.inf(f64))));
    try std.testing.expectEqual(@as(u64, 0xFFF0000000000000), bits(roundDown(-std.math.inf(f64))));
    try std.testing.expectEqual(@as(u64, 0x7FF0000000000000), bits(roundUp(std.math.inf(f64))));
    // The two ends that move agree with the strict pair, so the claim that
    // the two pairs differ only at the zeros covers all four.
    try std.testing.expectEqual(bits(nextUp(-std.math.inf(f64))), bits(roundUp(-std.math.inf(f64))));
    try std.testing.expectEqual(bits(prevDown(std.math.inf(f64))), bits(roundDown(std.math.inf(f64))));
    // And the step goes outward at both of them, in the direction each
    // function is for. An inward step here is the soundness hole the
    // saturating form exists to close, and it is invisible to a
    // comparison against the value: [-inf, -inf] still reads as a bound
    // of a number nobody can name.
    try std.testing.expect(roundUp(-std.math.inf(f64)) >= -std.math.inf(f64));
    try std.testing.expect(roundDown(std.math.inf(f64)) <= std.math.inf(f64));
    try std.testing.expectEqual(@as(u64, 1), order(roundUp(-std.math.inf(f64))) -| order(-std.math.inf(f64)));
    try std.testing.expectEqual(@as(u64, 1), order(std.math.inf(f64)) -| order(roundDown(std.math.inf(f64))));
    // The identity at the two ends that need no step is a step of zero
    // there, which the strict pair also is, so the two pairs still agree.
    try std.testing.expectEqual(@as(u64, 0), order(roundUp(std.math.inf(f64))) - order(std.math.inf(f64)));
    try std.testing.expectEqual(@as(u64, 0), order(roundDown(-std.math.inf(f64))) - order(-std.math.inf(f64)));
    try std.testing.expectEqual(bits(nextUp(std.math.inf(f64))), bits(roundUp(std.math.inf(f64))));
    try std.testing.expectEqual(bits(prevDown(-std.math.inf(f64))), bits(roundDown(-std.math.inf(f64))));
}

test "NaN: propagates unchanged through the non-strict pair" {
    const nan = std.math.nan(f64);
    try std.testing.expect(std.math.isNan(roundUp(nan)));
    try std.testing.expect(std.math.isNan(roundDown(nan)));
    // The pattern and all, which is the part an isNan check cannot see:
    // the argument comes back rather than a fresh NaN standing in for it.
    // The two guards ahead of the delegate in each function compare
    // against zero and against the infinities, and neither a NaN nor the
    // pattern of one satisfies either of them.
    try std.testing.expectEqual(bits(nan), bits(roundUp(nan)));
    try std.testing.expectEqual(bits(nan), bits(roundDown(nan)));
    try std.testing.expectEqual(bits(-nan), bits(roundUp(-nan)));
    try std.testing.expectEqual(bits(-nan), bits(roundDown(-nan)));
    // A NaN is a payload rather than a single value, so the rows above
    // pin one of the 2^51 - 1 of them. 0x7FF0000000000001 is signalling,
    // which is the pattern most likely to be quieted by something on the
    // way through, and 0x7FF8000000000007 carries a payload in its low
    // bits, which is the one an implementation is most likely to
    // regenerate.
    const signalling: u64 = 0x7FF0000000000001;
    const payload: u64 = 0x7FF8000000000007;
    try std.testing.expectEqual(signalling, bits(roundUp(fromBits(signalling))));
    try std.testing.expectEqual(signalling, bits(roundDown(fromBits(signalling))));
    try std.testing.expectEqual(payload | sign_bit, bits(roundUp(fromBits(payload | sign_bit))));
    try std.testing.expectEqual(payload | sign_bit, bits(roundDown(fromBits(payload | sign_bit))));
}

test "the two pairs: identical but for the pair of signed zeros" {
    // The claim the module comment makes about the two pairs, stated as
    // a test rather than as prose: same answer at every point of the
    // finite range but the pair of signed zeros, where the argument is
    // already its own bound. The NaN rows above and the infinity rows
    // cover the two ends outside that range, so the difference is exactly
    // the two zeros and nothing else anywhere.
    for (sweep()) |x| {
        // The zeros compare equal, so one branch takes both of them; the
        // rows that hold their signs apart are pinned by pattern above.
        if (x == 0.0) continue;
        try std.testing.expectEqual(bits(nextUp(x)), bits(roundUp(x)));
        try std.testing.expectEqual(bits(prevDown(x)), bits(roundDown(x)));
    }
}

// ---------------------------------------------------------------------------
// The sweep behind the rows that need more than a named value
// ---------------------------------------------------------------------------

/// Seed for the sweep. Fixed, so a failure reproduces exactly and a pass
/// means something; `std.Random.DefaultPrng` rather than the system
/// source, which would make the sweep meaningless.
const sweep_seed: u64 = 0x5EED_016E_0BA5_0000;

/// Cases in the sweep. The bound is one representable step from the value
/// at every point of the range, so the count buys coverage of the RANGE
/// and nothing else. A class of the table below is missed with
/// probability (8/9)^sweep_cases, which is about one in 10^105, and the
/// random pattern draws reach the whole exponent field rather than the
/// ten or so the classes name.
const sweep_cases: usize = 2048;

/// The regimes the sweep draws from. A uniform draw of 64 bits lands in
/// the subnormal field once in 2047 cases and never lands on a frontier
/// pattern at all, so a sweep over raw patterns would report a pass
/// without having touched either of the two places the non-strict pair
/// is not the strict pair stepped.
const Class = enum {
    /// The pair of signed zeros, the one input class on which the two
    /// pairs disagree.
    zero,
    /// Anywhere in the subnormal field, where the spacing is the fixed
    /// 2^-1074 rather than a fraction of the value.
    subnormal,
    /// The frontier between the subnormals and the normals, and the value
    /// above it, where a step changes which field it adds to.
    boundary,
    /// A random pattern, which reaches every exponent of the format.
    ordinary,
    /// The largest finite of either sign, which is the last value in the
    /// range on one side and the one whose outward step is forced out to
    /// an infinity on the other.
    extreme,
};

const classes = [_]Class{
    .zero,
    .subnormal,
    .subnormal,
    .boundary,
    .boundary,
    .ordinary,
    .ordinary,
    .ordinary,
    .extreme,
    .extreme,
};

/// The sign bit, drawn. Every class below is reachable on both signs, and
/// the sign of an endpoint is what the two pairs of steps are easiest to
/// get wrong on, so it is drawn rather than assumed.
fn drawSign(r: std.Random) u64 {
    return if (r.boolean()) sign_bit else 0;
}

/// A magnitude with a drawn sign, the way the fuzzers in the other test
/// files draw theirs.
fn signed(magnitude: f64, r: std.Random) f64 {
    return if (r.boolean()) magnitude else -magnitude;
}

/// A uniformly random finite pattern. The pattern order IS the value
/// order, so this reaches every exponent of the format rather than the
/// ten or so the named classes cover. Two fields have to be kept apart
/// for that: the significand is masked to its own 52 bits, and the
/// exponent is drawn from below the all-ones field the infinities and
/// the NaNs share. Mask the sign alone and the significand runs up into
/// the exponent field, the OR sets it to all ones, and the draw lands
/// on a NaN, which is a class this sweep does not claim to cover.
fn drawPattern(r: std.Random) f64 {
    const significand = r.int(u64) & max_subnormal_pattern;
    const exponent = @as(u64, r.intRangeAtMost(u16, 0, 0x7FE)) << 52;
    return fromBits(significand | exponent);
}

/// One sweep case. The class is drawn from the table rather than
/// generated, because a case the sweep is about has to be a case the
/// sweep draws.
fn draw(r: std.Random) f64 {
    return switch (classes[r.uintLessThan(usize, classes.len)]) {
        // The sign of a zero is a bit, not a choice, and both of the two
        // are the interesting ones.
        .zero => if (r.boolean()) 0.0 else -0.0,
        // The whole subnormal field rather than a value in it, so the
        // smallest subnormal and the largest are both in the draw.
        .subnormal => fromBits(r.intRangeAtMost(u64, 1, max_subnormal_pattern) | drawSign(r)),
        .boundary => fromBits(min_normal_pattern | @as(u64, r.intRangeAtMost(u8, 0, 1)) | drawSign(r)),
        .ordinary => drawPattern(r),
        .extreme => signed(std.math.floatMax(f64), r),
    };
}

/// The sweep, in ascending total order. Sorted by `order` rather than by
/// `<`, which cannot separate the two zeros at all, so a sort on it
/// would leave their relative position to the algorithm rather than to
/// the order. Built afresh per test from the fixed seed, so every row
/// that uses it sees the same cases and a failure names a case.
fn sweep() [sweep_cases]f64 {
    var prng = std.Random.DefaultPrng.init(sweep_seed);
    const r = prng.random();
    var cases: [sweep_cases]f64 = undefined;
    for (&cases) |*c| c.* = draw(r);
    std.mem.sort(f64, &cases, {}, byOrder);
    return cases;
}

test "pi: the enclosure brackets the true value" {
    // The true pi is 3.14159265358979323846..., inside the decimal bounds
    // 3.1415926535897932 and 3.1415926535897933. Both of those round to the
    // same f64 as piDown, so f64 alone cannot separate them from the bound
    // and the comparison needs a wider significand to mean anything.
    try std.testing.expect(@as(f80, piDown()) < 3.1415926535897932);
    try std.testing.expect(3.1415926535897933 < @as(f80, piUp()));
}

test "pi: the bounds are the nearest f64 and its successor" {
    try std.testing.expectEqual(@as(f64, @floatCast(std.math.pi)), piDown());
    try std.testing.expect(piDown() < piUp());
    try std.testing.expectEqual(bits(piDown()) + 1, bits(piUp()));
    // Both decimal bounds in the test above round onto the f64 of piDown
    // itself, so the upper one is the only pair of them f64 can separate:
    // pi is above the lower bound because that bound IS piDown.
    try std.testing.expect(3.1415926535897932 < piUp());
}
