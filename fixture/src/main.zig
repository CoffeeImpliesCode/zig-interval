const std = @import("std");
const interval = @import("interval");

const Interval = interval.Interval;
const Vec = interval.Vec;
const DynVec = interval.DynVec;

/// Raised when the library produces a value it does not promise. Returning it
/// from main makes the process exit non-zero, failing the parent `consumer`
/// step.
pub const CheckError = error{UnexpectedIntervalValue};

/// Number of behavioural checks; the summary line reports this.
const total_checks = 29;

/// Compare a produced interval against the expected one, loudly on mismatch.
/// Exact endpoints are the right assertion for the set and geometry
/// operations, which do no arithmetic and therefore need no widening.
fn expectInterval(what: []const u8, got: Interval, want: Interval) CheckError!void {
    if (got.lo != want.lo or got.hi != want.hi) {
        std.debug.print(
            "FAIL {s}: got [{d}, {d}], want [{d}, {d}]\n",
            .{ what, got.lo, got.hi, want.lo, want.hi },
        );
        return CheckError.UnexpectedIntervalValue;
    }
    std.debug.print("ok {s}: [{d}, {d}]\n", .{ what, got.lo, got.hi });
}

/// Compare a produced scalar against the expected one, loudly on mismatch.
fn expectFloat(what: []const u8, got: f64, want: f64) CheckError!void {
    if (got != want) {
        std.debug.print("FAIL {s}: got {d}, want {d}\n", .{ what, got, want });
        return CheckError.UnexpectedIntervalValue;
    }
    std.debug.print("ok {s}: {d}\n", .{ what, got });
}

fn expectBool(what: []const u8, got: bool, want: bool) CheckError!void {
    if (got != want) {
        std.debug.print("FAIL {s}: got {}, want {}\n", .{ what, got, want });
        return CheckError.UnexpectedIntervalValue;
    }
    std.debug.print("ok {s}: {}\n", .{ what, got });
}

/// Assert a `null` result, the library's signal for an answer that is empty
/// in the reals.
fn expectNullInterval(what: []const u8, got: ?Interval) CheckError!void {
    if (got) |g| {
        std.debug.print(
            "FAIL {s}: got [{d}, {d}], want null\n",
            .{ what, g.lo, g.hi },
        );
        return CheckError.UnexpectedIntervalValue;
    }
    std.debug.print("ok {s}: null\n", .{what});
}

/// Assert the library's central promise: `got` CONTAINS the exact real
/// interval [exact_lo, exact_hi]. Equality is neither expected nor wanted
/// here, because every arithmetic endpoint is widened by one ULP outward.
fn expectEncloses(
    what: []const u8,
    got: Interval,
    exact_lo: f64,
    exact_hi: f64,
) CheckError!void {
    if (got.lo > exact_lo or got.hi < exact_hi) {
        std.debug.print(
            "FAIL {s}: [{d}, {d}] does not enclose [{d}, {d}]\n",
            .{ what, got.lo, got.hi, exact_lo, exact_hi },
        );
        return CheckError.UnexpectedIntervalValue;
    }
    std.debug.print(
        "ok {s}: [{d}, {d}] encloses [{d}, {d}]\n",
        .{ what, got.lo, got.hi, exact_lo, exact_hi },
    );
}

/// Assert both halves of the enclosure claim for an addition whose operands
/// are exactly representable, so the exact sum is known and the machine's own
/// round-to-nearest answer `rn` is computable by hand.
///
/// The result must lie STRICTLY outside `rn` on both sides and must still
/// contain the true value. If it merely equalled `rn`, a one-ULP error in the
/// operands would be passed through as if it were exact, and the caller would
/// have no way to tell.
fn expectWidenedEnclosure(
    what: []const u8,
    got: Interval,
    rn: Interval,
    true_lo: f64,
    true_hi: f64,
) CheckError!void {
    if (got.lo >= rn.lo or got.hi <= rn.hi) {
        std.debug.print(
            "FAIL {s}: [{d}, {d}] is not wider than [{d}, {d}]\n",
            .{ what, got.lo, got.hi, rn.lo, rn.hi },
        );
        return CheckError.UnexpectedIntervalValue;
    }
    if (got.lo > true_lo or got.hi < true_hi) {
        std.debug.print(
            "FAIL {s}: [{d}, {d}] does not enclose [{d}, {d}]\n",
            .{ what, got.lo, got.hi, true_lo, true_hi },
        );
        return CheckError.UnexpectedIntervalValue;
    }
    std.debug.print(
        "ok {s}: [{d}, {d}] encloses [{d}, {d}], wider than [{d}, {d}]\n",
        .{ what, got.lo, got.hi, true_lo, true_hi, rn.lo, rn.hi },
    );
}

/// Check a whole vector in one shot: the dimension, then every component.
/// One vector is one behavioural check, so it reports on one line.
fn expectVecExact(what: []const u8, got: anytype, want: []const Interval) CheckError!void {
    if (got.dim() != want.len) {
        std.debug.print(
            "FAIL {s}: dim {d}, want {d}\n",
            .{ what, got.dim(), want.len },
        );
        return CheckError.UnexpectedIntervalValue;
    }
    for (want, 0..) |w, i| {
        const g = got.get(i);
        if (g.lo != w.lo or g.hi != w.hi) {
            std.debug.print(
                "FAIL {s}: component {d} is [{d}, {d}], want [{d}, {d}]\n",
                .{ what, i, g.lo, g.hi, w.lo, w.hi },
            );
            return CheckError.UnexpectedIntervalValue;
        }
    }
    std.debug.print("ok {s}: {d} components exact\n", .{ what, want.len });
}

/// Same, but each component only has to CONTAIN the exact real interval,
/// which is the right assertion for a widened arithmetic result.
fn expectVecEncloses(what: []const u8, got: anytype, want: []const Interval) CheckError!void {
    if (got.dim() != want.len) {
        std.debug.print(
            "FAIL {s}: dim {d}, want {d}\n",
            .{ what, got.dim(), want.len },
        );
        return CheckError.UnexpectedIntervalValue;
    }
    for (want, 0..) |w, i| {
        const g = got.get(i);
        if (g.lo > w.lo or g.hi < w.hi) {
            std.debug.print(
                "FAIL {s}: component {d} is [{d}, {d}], does not enclose [{d}, {d}]\n",
                .{ what, i, g.lo, g.hi, w.lo, w.hi },
            );
            return CheckError.UnexpectedIntervalValue;
        }
    }
    std.debug.print("ok {s}: {d} components enclose\n", .{ what, want.len });
}

pub fn main() !void {
    // --- Set and geometry operations: exact endpoints, no widening. ---

    try expectInterval(
        "hull",
        Interval.init(1.0, 3.0).hull(Interval.init(2.0, 5.0)),
        Interval.init(1.0, 5.0),
    );

    try expectInterval(
        "intersect",
        Interval.init(1.0, 3.0).intersect(Interval.init(2.0, 5.0)).?,
        Interval.init(2.0, 3.0),
    );

    const disjoint = Interval.init(0.0, 1.0).intersect(Interval.init(2.0, 3.0));
    if (disjoint != null) {
        std.debug.print(
            "FAIL intersect-disjoint: got [{d}, {d}], want null\n",
            .{ disjoint.?.lo, disjoint.?.hi },
        );
        return CheckError.UnexpectedIntervalValue;
    }
    std.debug.print("ok intersect-disjoint: null\n", .{});

    const spread = [_]Interval{
        Interval.init(4.0, 7.0),
        Interval.init(1.0, 3.0),
        Interval.init(2.0, 9.0),
    };
    try expectInterval(
        "hullOf",
        Interval.hullOf(&spread).?,
        Interval.init(1.0, 9.0),
    );

    const common = [_]Interval{
        Interval.init(1.0, 5.0),
        Interval.init(2.0, 6.0),
        Interval.init(3.0, 4.0),
    };
    try expectInterval(
        "intersectionOf",
        Interval.intersectionOf(&common).?,
        Interval.init(3.0, 4.0),
    );

    try expectFloat("distanceTo", Interval.init(1.0, 3.0).distanceTo(0.0), 1.0);

    try expectInterval(
        "scale",
        Interval.init(1.0, 3.0).scale(2.0),
        Interval.init(0.0, 4.0),
    );

    try expectInterval(
        "expand",
        Interval.init(1.0, 3.0).expand(1.0),
        Interval.init(0.0, 4.0),
    );

    try expectFloat("clamp", Interval.init(1.0, 3.0).clamp(5.0), 3.0);

    // --- Algebraic operations: every result is an enclosure, so the
    // assertion is containment, never equality. All the operands below are
    // small integers, so the exact real result is a small integer too. ---

    // 1 + 2 = 3, 3 + 5 = 8.
    try expectEncloses(
        "add",
        Interval.init(1.0, 3.0).add(Interval.init(2.0, 5.0)),
        3.0,
        8.0,
    );

    // 5 - 2 = 3, 7 - 1 = 6.
    try expectEncloses(
        "sub",
        Interval.init(5.0, 7.0).sub(Interval.init(1.0, 2.0)),
        3.0,
        6.0,
    );

    // IEEE negation is exact and only the endpoints swap, so neg is the one
    // algebraic operation that returns its endpoints unwidened. [-3, -1] is
    // therefore an exact result, not merely an enclosure.
    try expectInterval("neg", Interval.init(1.0, 3.0).neg(), Interval.init(-3.0, -1.0));

    // Smallest product 2*2 = 4, largest 3*3 = 9.
    try expectEncloses(
        "mul-positive",
        Interval.init(2.0, 3.0).mul(Interval.init(2.0, 3.0)),
        4.0,
        9.0,
    );

    // Sign change: the smallest product is 2*(-2) = -4, the largest 3*3 = 9.
    try expectEncloses(
        "mul-mixed-sign",
        Interval.init(2.0, 3.0).mul(Interval.init(-2.0, 3.0)),
        -4.0,
        9.0,
    );

    // Divisor stays strictly positive, so the quotient stays bounded:
    // smallest 4/4 = 1, largest 8/2 = 4.
    try expectEncloses(
        "div-positive",
        Interval.init(4.0, 8.0).div(Interval.init(2.0, 4.0)),
        1.0,
        4.0,
    );

    // The image of |x| over [-3, 5] is [0, 5], not [3, 5]: the minimum of
    // |x| is 0, reached at x = 0 inside the interval.
    try expectEncloses("abs", Interval.init(-3.0, 5.0).abs(), 0.0, 5.0);

    // --- The enclosure guarantee itself. ---

    // The central claim of the library, checked twice: once where no rounding
    // error is possible, and once where it certainly is.
    //
    // Here every operand is an exactly representable integer, so the machine's
    // own round-to-nearest sum is exactly 5 and exactly 10, and the exact real
    // sum is also exactly 5 and exactly 10. A result equal to [5, 10] would
    // happen to be sound here, but only by luck: the library must not depend
    // on luck, so it must come back strictly wider.
    try expectWidenedEnclosure(
        "enclosure-widening",
        Interval.init(1.0, 2.0).add(Interval.init(4.0, 8.0)),
        Interval.init(5.0, 10.0), // what round-to-nearest would return
        5.0,
        10.0,
    );

    // Now a case where the naive answer is WRONG, not merely narrow.
    //
    // The operands are the f64 values 0.1 and 0.7, which are not the reals
    // 1/10 and 7/10 but are slightly above and slightly below them. Their
    // exact real sum is therefore 0.79999999999999996114..., which lies
    // strictly BETWEEN the two adjacent f64 values 0.7999999999999999
    // (0.79999999999999991118...) and 0.8 (0.80000000000000004440...).
    //
    // Round-to-nearest picks 0.7999999999999999, which is BELOW the true sum:
    // returning it as a lower bound would exclude the real answer and the
    // error would be undetectable downstream. A sound lower bound therefore
    // has to be at most 0.7999999999999999, and since no double lies between
    // that value and the true sum, "at most" here means strictly less. For
    // the same reason a sound upper bound has to be at least 0.8.
    try expectWidenedEnclosure(
        "enclosure-rounding-error",
        Interval.init(0.1, 0.1).add(Interval.init(0.7, 0.7)),
        Interval.init(0.7999999999999999, 0.7999999999999999), // round-to-nearest
        0.7999999999999999, // largest double below the true sum
        0.8, // smallest double above the true sum
    );

    // --- Certain comparisons. ---

    // lt is true only when every point of self is below every point of other.
    try expectBool(
        "lt-separated",
        Interval.init(1.0, 2.0).lt(Interval.init(3.0, 4.0)),
        true,
    );

    // [1, 3] and [3, 5] share the point 3, so it is NOT certain that self is
    // less than other. `lt` is self.hi < other.lo, never self.lo < other.hi.
    try expectBool(
        "lt-touching",
        Interval.init(1.0, 3.0).lt(Interval.init(3.0, 5.0)),
        false,
    );

    // Overlapping: some points of self are above some points of other, so the
    // certain answer is false even though the intervals do overlap.
    try expectBool(
        "lt-overlapping",
        Interval.init(1.0, 3.0).lt(Interval.init(2.0, 5.0)),
        false,
    );

    // --- Elementary functions. ---

    // sqrt is increasing, so the image of [4, 9] is [sqrt 4, sqrt 9] = [2, 3].
    // 2 and 3 are exact, but the result is still widened, so assert that it
    // BRACKETS [2, 3] rather than equalling it.
    try expectEncloses(
        "sqrt-brackets",
        interval.sqrt(Interval.init(4.0, 9.0)).?,
        2.0,
        3.0,
    );

    // The real logarithm is undefined on (-inf, 0], so the image of [-1, 0]
    // is empty in the reals. Empty is signalled by null, which is a
    // different condition from unbounded.
    try expectNullInterval(
        "log-non-positive",
        interval.log(Interval.init(-1.0, 0.0)),
    );

    // Same distinction on the other branch: no real square root below zero.
    try expectNullInterval(
        "sqrt-negative",
        interval.sqrt(Interval.init(-4.0, -1.0)),
    );

    // --- Vector forms. ---

    // Componentwise addition of two boxes. Each component is the same exact
    // integer sum as the scalar case above, widened by one ULP on each end:
    // prevDown(2) = 1.9999999999999998, nextUp(3) = 3.0000000000000004, and
    // so on up to prevDown(6) = 5.999999999999999, nextUp(7) = 7.000000000000001.
    const va = Vec(3).fromArray(.{
        Interval.init(1.0, 2.0),
        Interval.init(3.0, 4.0),
        Interval.init(5.0, 6.0),
    });
    const vb = Vec(3).fromArray(.{
        Interval.init(1.0, 1.0),
        Interval.init(1.0, 1.0),
        Interval.init(1.0, 1.0),
    });
    // One check covers the whole vector: dimension plus all three components.
    try expectVecExact("vec3-add", va.add(vb), &.{
        Interval.init(1.9999999999999998, 3.0000000000000004),
        Interval.init(3.9999999999999996, 5.000000000000001),
        Interval.init(5.999999999999999, 7.000000000000001),
    });

    // Two boxes that share a large overlap in two components are still
    // disjoint, because the first component is disjoint: the intersection of
    // boxes is empty as soon as ONE component is empty.
    const vleft = Vec(3).fromArray(.{
        Interval.init(0.0, 1.0),
        Interval.init(0.0, 10.0),
        Interval.init(0.0, 10.0),
    });
    const vright = Vec(3).fromArray(.{
        Interval.init(2.0, 3.0),
        Interval.init(0.0, 10.0),
        Interval.init(0.0, 10.0),
    });
    if (vleft.intersect(vright) != null) {
        std.debug.print("FAIL vec3-intersect-disjoint: got a box, want null\n", .{});
        return CheckError.UnexpectedIntervalValue;
    }
    std.debug.print("ok vec3-intersect-disjoint: null\n", .{});

    // DynVec carries its dimension at runtime and its own allocator. The
    // constructor only copies, so the components are exact. `neg` mutates in
    // place through a pointer and returns void, so its result is checked as an
    // enclosure: the true image of -x over [1, 2] is [-2, -1].
    var dv = try DynVec.fromArray(std.heap.page_allocator, &.{
        Interval.init(1.0, 2.0),
        Interval.init(3.0, 4.0),
    });
    defer dv.deinit();
    try expectVecExact("dynvec-init", dv, &.{
        Interval.init(1.0, 2.0),
        Interval.init(3.0, 4.0),
    });

    dv.neg();
    try expectVecEncloses("dynvec-neg", dv, &.{
        Interval.init(-2.0, -1.0),
        Interval.init(-4.0, -3.0),
    });

    // --- Empty versus unbounded: the distinction that matters most. ---

    // A divisor that straddles zero makes the quotient set all of R. That is
    // an unbounded interval, not an empty one: it is [-inf, inf], a real
    // answer, and emphatically not null. Null would have meant "no answer
    // exists", as in the log and sqrt checks above.
    const unbounded = Interval.init(1.0, 2.0).div(Interval.init(-1.0, 1.0));
    if (unbounded.lo != -std.math.inf(f64) or unbounded.hi != std.math.inf(f64)) {
        std.debug.print(
            "FAIL div-straddling-zero: got [{d}, {d}], want [-inf, inf]\n",
            .{ unbounded.lo, unbounded.hi },
        );
        return CheckError.UnexpectedIntervalValue;
    }
    std.debug.print("ok div-straddling-zero: [-inf, inf]\n", .{});

    std.debug.print("consumer ok: {d} checks\n", .{total_checks});
}
