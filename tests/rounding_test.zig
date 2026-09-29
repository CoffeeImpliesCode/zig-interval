const std = @import("std");
const rounding = @import("rounding");

const nextUp = rounding.nextUp;
const prevDown = rounding.prevDown;
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
    return @as(u64, @bitCast(x));
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
