//! The named cases, and the traps. Everything here is a shape the generator
//! draws rarely or not at all, or a guard that says what must NOT be
//! accepted: the minimal reproducers, the two overflow guards and what a
//! non-saturating "fix" to them would cost, the div and recip forms at the
//! underflow regimes, the list folds at the lengths no draw can reach, and
//! the NaN-scalar contract observed from OUTSIDE this process.
//!
//! That last one is here rather than anywhere else for a mechanical reason
//! `tests/nan_probe.zig` spells out in full: the contract is that a NaN
//! scalar operand ABORTS, an abort inside a test binary takes every other
//! test down with it, and the exit status of a child is the only signal that
//! survives. It is also the only thing in the four concern files that reaches
//! for a build option, which is why `build.zig` hands `nan_probe_options` and
//! `probe_runner_options` to this file alone.
//!
//! The assertions read the same references the sweeps read, out of
//! `soundness_shared.zig`, and that is what makes them checks rather than
//! restatements: a returned bound is asked to enclose an image built from
//! the ORIGINAL `f64` endpoints — or, where the extremum is a sum no `f128`
//! can name, to satisfy the TwoSum residual — and never a corner the
//! implementation produced.
const shared = @import("soundness_shared.zig");

const std = shared.std;
const Interval = shared.Interval;

const exactAdd = shared.exactAdd;
const exactMul = shared.exactMul;
const exactSub = shared.exactSub;
const exactTranslate = shared.exactTranslate;
const ex = shared.ex;
const expectEnclosure = shared.expectEnclosure;
const expectSumEnclosure = shared.expectSumEnclosure;
const inf64 = shared.inf64;
const lowerOk = shared.lowerOk;
const neg_inf64 = shared.neg_inf64;
const quotientHolds = shared.quotientHolds;
const showInterval = shared.showInterval;
const sumGeq = shared.sumGeq;
const sumLeq = shared.sumLeq;
const twoSum = shared.twoSum;
const upperOk = shared.upperOk;

// ---------------------------------------------------------------------------
// Minimal reproducers, and the guards around them
// ---------------------------------------------------------------------------

// The two sums an `f128` sum cannot represent, and the answers a reference
// built on one would clear. Both are refusals of the SAME bound pattern: a
// returned endpoint sitting exactly on the larger of the two operands,
// which is the point the sum rounds to and not the sum. This is the guard
// for the four sum references, and it asks the comparator directly rather
// than through a sweep, so a failure says which of the two is wrong rather
// than that some operation somewhere missed.
//
// Nothing here calls production rounding. The expected answer is a fact
// about reals — `floatMax - 3` is three below `floatMax`, and
// `1e300 - 1e-300` is a `1e-300` below `1e300` — and the `f128` head is
// printed only to show that it is the larger operand, which is what makes
// the residual necessary.
test "the exact-sum comparator rejects the two inward roundings an f128 sum hides" {
    const fmax = std.math.floatMax(f64);

    // floatMax - 3. The exact sum is three below floatMax, and the unsafe
    // answer is the box [floatMax, floatMax] with that same floatMax at its
    // lower end.
    const t1 = twoSum(fmax, -3.0);
    try std.testing.expect(t1.s == ex(fmax)); // the f128 head IS floatMax
    try std.testing.expect(t1.err == -3.0); // and the residual is the whole difference
    try std.testing.expect(!sumLeq(fmax, fmax, -3.0)); // [M,M] as a lower bound
    try std.testing.expect(sumLeq(-fmax, fmax, -3.0)); // the next step down is fine
    try std.testing.expect(sumLeq(std.math.nextAfter(f64, fmax, -inf64), fmax, -3.0));
    try std.testing.expect(sumGeq(fmax, fmax, -3.0)); // floatMax is ABOVE the sum

    // The same comparison from the other side: the answer [M, M] is a
    // valid UPPER bound for M - 3 and an invalid LOWER bound, and an oracle
    // that read the two ends off one f128 could not tell them apart.
    const bound = Interval.init(fmax, fmax);
    try std.testing.expect(!exactSub(Interval.init(fmax, fmax), Interval.init(3.0, 3.0)).lowerOk(bound.lo));
    try std.testing.expect(exactAdd(Interval.init(fmax, fmax), Interval.init(-3.0, -3.0)).upperOk(bound.hi));

    // 1e300 + (-1e-300). The exact sum is a 1e-300 below 1e300, and the
    // unstepped point 1e300 is above it. This is the case the finite sweep
    // reaches on its own: the operands are ordinary, the operation is add,
    // and the only thing wrong with the answer is that it is the corner the
    // machine computed rather than the corner the arithmetic reached.
    // Typed as `f64` rather than left as `comptime_float`, and the reason is
    // the point of the whole case: a bare `1e-300` is the exact decimal when
    // it is widened, and this test is about the `f64` the machine holds. The
    // two differ by more than `f128` can name, so an untyped literal here
    // would be comparing the residual against a number the operand never
    // was.
    const big: f64 = 1e300;
    const small: f64 = 1e-300;
    const t2 = twoSum(big, -small);
    try std.testing.expect(t2.s == ex(big));
    try std.testing.expect(t2.err == -small);
    try std.testing.expect(!sumLeq(big, big, -small));
    try std.testing.expect(sumGeq(big, big, -small));
    try std.testing.expect(!exactAdd(Interval.init(big, big), Interval.init(-small, -small)).lowerOk(big));
    try std.testing.expect(exactAdd(Interval.init(big, big), Interval.init(small, small)).lowerOk(big));

    // The residual is zero wherever the f128 sum IS the true sum, which is
    // every case where the two operands are close enough for 113 bits to
    // hold the result. A nonzero residual here would mean the
    // transformation is not an error-free one.
    for ([_][2]f64{
        .{ 1.0, 2.0 },
        .{ 0.1, 0.2 },
        .{ fmax, 0.0 },
        .{ -fmax, fmax },
        .{ 1e-320, 1e-320 },
        .{ std.math.floatMin(f64), std.math.floatMin(f64) },
        .{ 1.0, -1.0 },
        .{ 3.0, -3.0 },
    }) |pair| {
        const t = twoSum(pair[0], pair[1]);
        try std.testing.expect(t.err == 0.0);
        try std.testing.expect(t.s == ex(pair[0]) + ex(pair[1]));
    }

    // And a NaN bound is refused from both sides, because a bound that is
    // not a number encloses nothing.
    try std.testing.expect(!sumLeq(std.math.nan(f64), 1.0, 1.0));
    try std.testing.expect(!sumGeq(std.math.nan(f64), 1.0, 1.0));
    // The infinities are ordered against a finite real sum, not against an
    // `f128` of it.
    try std.testing.expect(sumLeq(neg_inf64, fmax, fmax));
    try std.testing.expect(!sumLeq(inf64, fmax, fmax));
    try std.testing.expect(sumGeq(inf64, fmax, -fmax));
    try std.testing.expect(!sumGeq(neg_inf64, fmax, -fmax));
}

test "guard: an overflowed corner is not the true extremum, so its bound is pulled back inside" {
    // NOT a defect reproducer. The audit filed "nextUp(-inf) returns
    // -floatMax" as a soundness hole; it is not one, and the audit has
    // withdrawn it. The true image of [-1e300, -1e300] * [1e300, 1e300]
    // is the single real -1e600, and -1e600 lies between -inf and
    // -floatMax, so [-inf, -floatMax] encloses it and the original
    // saturation was correct.
    //
    // This stays as a guard because the natural "fix" is unsound. Making
    // the outward step non-strict, so that the smallest f64 at or above
    // -inf is -inf itself, looks like the same rule the step applies
    // everywhere else. It is not: -inf is below every real, so [-inf, -inf]
    // excludes -1e600. That version of the rule was specified, tried, and
    // caught here, and the test is what caught it. The rule that is right
    // is the saturating one, and the test below says so.
    const a = Interval.init(-1e300, -1e300);
    const b = Interval.init(1e300, 1e300);
    const want = exactMul(a, b);

    const saturating = Interval.init(-inf64, -std.math.floatMax(f64));
    const saturating_ok = lowerOk(want.lo, saturating.lo) and upperOk(want.hi, saturating.hi);
    std.debug.print("\n  guard (saturating step, [-inf, -floatMax]): -> {s}\n", .{
        if (saturating_ok) "ENCLOSES the true -1e600" else "does NOT enclose it",
    });
    try std.testing.expect(saturating_ok);

    // Built as a raw struct literal, NOT through `init`. The constructor
    // canonicalises `[-inf, -inf]` to the overflow ray, so going through it
    // hands back the saturating case above and the row would prove nothing
    // at all. What this row states is a fact about REALS: `[-inf, -inf]`
    // excludes -1e600 because -1e600 is strictly inside it. That is true of
    // the pair whatever the constructor chooses to do with it, and a struct
    // literal is the documented way to hold a non-canonical one.
    const collapsed: Interval = .{ .lo = neg_inf64, .hi = neg_inf64 };
    const collapsed_ok = lowerOk(want.lo, collapsed.lo) and upperOk(want.hi, collapsed.hi);
    std.debug.print("  guard (non-strict step, [-inf, -inf]): -> {s}\n", .{
        if (collapsed_ok) "ENCLOSES the true -1e600" else "does NOT enclose it",
    });
    try std.testing.expect(!collapsed_ok);

    // No width bound: the correct answer has infinite width, because no
    // finite pair of f64 brackets -1e600.
    try expectEnclosure("mul does not enclose the true -1e600", a.mul(b), want, false);
}

test "reproducer 1: mul underflow to a signed zero - the lost corner is outside the returned bound" {
    // A product of two non-zero operands that is too small for f64 comes
    // back as a zero carrying only an operand's sign. The min and the max
    // over the four corners then compare zeros, cannot tell the two signs
    // apart, and a bound that stops at the zero leaves out the value the
    // zero stands for. The true maximum here is 1e-400, which is a
    // strictly positive real no larger than the zero the corner became.
    //
    // Two cases, both in the underflow regime, reported separately:
    //
    //  (a) the case as the audit states it, [-1e-200,-1e200] taken
    //      literally is [-1e-200,-1e-200] * [1e-200,1e-200]. Its true
    //      image is the single NEGATIVE point -1e-400 (the audit records
    //      it as +1e-400), and all four corners underflow to the same
    //      -0.0, so the sign never has to be told apart and the returned
    //      interval does enclose it. Verdict reported either way.
    //  (b) the same regime with the corner signs mixed, which is the shape
    //      the defect actually needs: the positive corner is dragged down
    //      to a negative zero by the reduction and the true +1e-400 falls
    //      outside the bound.
    const positive = Interval.init(1e-200, 1e-200);
    const mixed = Interval.init(-1e-200, 1e-200);
    const audit_case = Interval.init(-1e-200, -1e-200).mul(Interval.init(1e-200, 1e-200));
    const audit_exact = exactMul(Interval.init(-1e-200, -1e-200), Interval.init(1e-200, 1e-200));
    const audit_ok = lowerOk(audit_exact.lo, audit_case.lo) and upperOk(audit_exact.hi, audit_case.hi);
    std.debug.print("\n  reproducer 1a (literal audit case): exact image [{e}, {e}] -> {s}\n", .{
        audit_exact.lo, audit_exact.hi, if (audit_ok) "ENCLOSED" else "NOT ENCLOSED",
    });
    std.debug.print("    returned =\n", .{});
    showInterval(audit_case);

    const got = positive.mul(mixed);
    try expectEnclosure("mul underflow excludes the true +1e-400", got, exactMul(positive, mixed), true);
}

test "reproducer 2: translate has no outward widening - the exact 0.1 + 0.2 is above the returned bound" {
    // 0.1 + 0.2 in exact arithmetic over the two f64 values is
    // 10808639105689191 / 2^55 = 0.3000000000000000166533453693773481,
    // which is strictly BELOW the f64 nearest it, 0.30000000000000004.
    // A shift that adds without widening therefore returns a lower bound
    // above the true minimum and cuts the true value off. The value here
    // is built from the f64 endpoints, not from the decimal literals, so
    // it is the sum of the two f64 numbers rather than the real 0.3.
    const a = Interval.init(0.1, 0.2);
    const got = a.translate(0.2);
    try expectSumEnclosure("translate excludes the exact 0.1 + 0.2", got, exactTranslate(a, 0.2), true);
}

// "reproducer 3: powf's fixed relative margin does not grow with the exponent"
// has MOVED, and the reason it moved is the reason it was ever a defect worth
// keeping.
//
// Its reference was `exactPowf`: an `f128` evaluation of `exp(y * log x)`
// widened by a fixed `1e-28`. That is a SECOND IMPLEMENTATION of the same
// function, evaluated with primitives Zig 0.16 only computes to `f64`
// accuracy, so it inherited the very error the oracle exists to detect. It
// passed only because `powf`'s answer is many ULP wide and swallowed the
// reference's error, which is not evidence of anything.
//
// The reference is now the MPFR corpus, which is not written in this tree and
// carries no such assumption. The test itself is unchanged in substance and
// keeps its name: it lives in `tests/corpus_test.zig`, where the corpus is
// read, and it asserts the same thing — that the fixed margin holds at an
// exponent of 1e8. The argument pair is in the corpus because the generator
// was given it for this reason.

// ---------------------------------------------------------------------------
// The div and recip forms, and the guards
// ---------------------------------------------------------------------------

test "guard: an overflowed quotient is not the true extremum either" {
    // The same property as the product guard above, at the other end of
    // the range and through the division path. 1e300 / 1e-300 is 1e600, a
    // finite real past the end of the f64 range, so a corner quotient of
    // +inf is not that real: +inf is above it, and the lower bound taken
    // from that corner has to come back down to +floatMax. The reciprocal
    // of 1e-320 is 1e320, the same shape from the other direction.
    //
    // Not a defect reproducer. The audit filed the saturating step as the
    // bug; it is the other way round, and these two hold now as they did
    // before. They are kept because a bound that collapses an overflowed
    // quotient to [+inf, +inf] is unsound for the reason the product guard
    // spells out, and nothing else in the tree would notice.
    const a = Interval.init(1e300, 1e300);
    const b = Interval.init(1e-300, 1e-300);
    const got = a.div(b);
    if (!quotientHolds(a.lo, b.lo, got)) {
        std.debug.print("\n  UNSOUND: div overflow does not enclose the true 1e600\n", .{});
        std.debug.print("    returned =\n", .{});
        showInterval(got);
        std.debug.print("    exact quotient {e} / {e} = about {e}\n", .{ a.lo, b.lo, ex(a.lo) / ex(b.lo) });
        return error.NotAnEnclosure;
    }

    const tiny = Interval.init(1e-320, 1e-320);
    const recip_got = tiny.recip();
    if (!quotientHolds(1.0, tiny.lo, recip_got)) {
        std.debug.print("\n  UNSOUND: recip overflow does not enclose the true 1e320\n", .{});
        std.debug.print("    returned =\n", .{});
        showInterval(recip_got);
        std.debug.print("    exact quotient 1 / {e} = about {e}\n", .{ tiny.lo, 1.0 / ex(tiny.lo) });
        return error.NotAnEnclosure;
    }
}

test "reproducer 4: div underflow to a signed zero" {
    // A quotient of two non-zero operands underflows exactly as a product
    // does. With the dividend spanning zero the two corner quotients have
    // opposite signs, and the reduction cannot tell a +0.0 from a -0.0.
    // The corner that should have supplied the upper bound is the positive
    // one, +1e-400, and it came back as a zero that lost its sign.
    const a = Interval.init(-1e-200, 1e-200);
    const b = Interval.init(1e200, 1e200);
    const got = a.div(b);
    if (quotientHolds(a.hi, b.lo, got)) return;
    std.debug.print("\n  UNSOUND: div underflow excludes the true +1e-400\n", .{});
    std.debug.print("    returned =\n", .{});
    showInterval(got);
    std.debug.print("    exact quotient {e} / {e} = about {e}\n", .{ a.hi, b.lo, ex(a.hi) / ex(b.lo) });
    return error.NotAnEnclosure;
}

test "reproducer 5: recip underflow" {
    // 1 / 1e300 is 1e-300, in range, and the audit's own subnormal case
    // 1 / 1e-320 is the one that leaves it. The recip path is monotone in
    // its argument and an interval excluding zero maps to an interval of
    // one sign, so the two corner quotients never have opposite signs and
    // the sign-losing reduction cannot bite here the way it does in `div`.
    // Reported so the coverage is complete and the reason for the difference
    // is on the record.
    const audit = Interval.init(1e300, 1e300).recip();
    const audit_ok = quotientHolds(1.0, 1e300, audit);
    std.debug.print("\n  reproducer 5a (1/1e300): -> {s}\n", .{if (audit_ok) "ENCLOSED" else "NOT ENCLOSED"});
    try std.testing.expect(audit_ok);

    const huge = Interval.init(1.7e308, 1.7e308);
    const got = huge.recip();
    if (quotientHolds(1.0, huge.lo, got)) return;
    std.debug.print("\n  UNSOUND: recip underflow excludes the true 1/1.7e308\n", .{});
    std.debug.print("    returned =\n", .{});
    showInterval(got);
    return error.NotAnEnclosure;
}

test "subnormal division: runtime corners remain enclosed" {
    // Volatile inputs prevent constant folding from hiding software-float
    // division failures. These are the first two MIPS32 cross-test witnesses.
    var patterns = [_][4]u64{
        .{ 0x000000000000010B, 0x00000000004184D8, 0xC08975E52D35BD0E, 0xC05C395A4951E5E0 },
        .{ 0x0000000009D60017, 0x00233C5E0AE83AE1, 0x40554E7CA1D40A10, 0x4065115B91524910 },
    };
    const inputs: *volatile [2][4]u64 = &patterns;
    for (0..patterns.len) |i| {
        const a = Interval.init(@bitCast(inputs[i][0]), @bitCast(inputs[i][1]));
        const b = Interval.init(@bitCast(inputs[i][2]), @bitCast(inputs[i][3]));
        const got = a.div(b);
        for ([_]f64{ a.lo, a.hi }) |n| {
            for ([_]f64{ b.lo, b.hi }) |d| {
                try std.testing.expect(quotientHolds(n, d, got));
            }
        }
    }
}

test "subnormal division: runtime rounding boundaries remain enclosed" {
    // Normal/subnormal transition, half-way cases, deep underflow, and
    // exact zero over infinity all constrain the recovery path.
    var patterns = [_][2]u64{
        .{ 0x0010000000000000, 0x4000000000000000 },
        .{ 0x000FFFFFFFFFFFFF, 0x3FF0000000000000 },
        .{ 0x0010000000000000, 0x3FF0000000000001 },
        .{ 0x0000000000000001, 0x4000000000000000 },
        .{ 0x0000000000000003, 0x4000000000000000 },
        .{ 0x0000000000000001, 0x7FEFFFFFFFFFFFFF },
        .{ 0x3FF0000000000000, 0x7FEFFFFFFFFFFFFF },
        .{ 0x3FF0000000000000, 0x7FEE42D130773B76 },
        .{ 0x7FEFFFFFFFFFFFFF, 0x7FF0000000000000 },
        .{ 0x0000000000000000, 0x4000000000000000 },
    };
    const inputs: *volatile [10][2]u64 = &patterns;
    for (0..patterns.len) |i| {
        const n: f64 = @bitCast(inputs[i][0]);
        const d: f64 = @bitCast(inputs[i][1]);
        for ([_]f64{ d, -d }) |signed_d| {
            for ([_]f64{ n, -n }) |signed_n| {
                const got = Interval.init(signed_n, signed_n).div(Interval.init(signed_d, signed_d));
                if (std.math.isInf(signed_d) or signed_n == 0.0) {
                    try std.testing.expect(got.lo <= 0.0 and 0.0 <= got.hi);
                } else {
                    try std.testing.expect(quotientHolds(signed_n, signed_d, got));
                }
            }
            if (n == 1.0) {
                const reciprocal = Interval.init(signed_d, signed_d).recip();
                try std.testing.expect(quotientHolds(1.0, signed_d, reciprocal));
            }
        }
    }
}

// ---------------------------------------------------------------------------
// The folds at the sizes the generator does not reach
// ---------------------------------------------------------------------------

// The list folds are swept over three elements, which is the length a
// pairwise law could not settle. The empty list and the one-element list
// are the other two shapes, and neither is reachable by drawing: a zero
// length and a length of one are constants, not draws. Each is checked
// against the same fold the sweep uses, and the one-element list against
// the interval itself, which is the only fold of one there is.
test "hullOf and intersectionOf at the list lengths a draw cannot reach" {
    const empty: []const Interval = &.{};
    try std.testing.expect(Interval.hullOf(empty) == null);
    try std.testing.expect(Interval.intersectionOf(empty) == null);

    const one = [_]Interval{Interval.init(-3.5, 7.25)};
    const one_hull = Interval.hullOf(&one);
    const one_inter = Interval.intersectionOf(&one);
    try std.testing.expect(one_hull != null and one_hull.?.eql(one[0]));
    try std.testing.expect(one_inter != null and one_inter.?.eql(one[0]));

    // A disjoint pair makes the intersection null while the hull is still
    // the pair's span, which is the one case where the two folds differ
    // in SHAPE and not only in value.
    const apart = [_]Interval{ Interval.init(1.0, 2.0), Interval.init(5.0, 6.0) };
    try std.testing.expect(Interval.hullOf(&apart).?.eql(Interval.init(1.0, 6.0)));
    try std.testing.expect(Interval.intersectionOf(&apart) == null);

    // Three elements where the first pair is already disjoint and the
    // third is not: a fold that stopped at the first disjoint pair would
    // return the third element, and one that short-circuited to null
    // would get the answer here by accident.
    const mixed = [_]Interval{
        Interval.init(0.0, 1.0),
        Interval.init(4.0, 5.0),
        Interval.init(-2.0, 9.0),
    };
    try std.testing.expect(Interval.hullOf(&mixed).?.eql(Interval.init(-2.0, 9.0)));
    try std.testing.expect(Interval.intersectionOf(&mixed) == null);
}

// The two folds against the pairwise operations they are the folds of.
// `hullOf([a, b])` has to be `a.hull(b)` and `intersectionOf([a, b])` has
// to be `a.intersect(b)`, including in the disjoint case where the
// second is a null and the first is not. This is the distributive law
// between two public entry points that reach the same answer by
// different code, so it is a check and not a restatement.
test "hullOf and intersectionOf agree with the pairwise operations" {
    const pairs = [_][2]Interval{
        .{ Interval.init(1.0, 4.0), Interval.init(2.0, 6.0) },
        .{ Interval.init(-5.0, -1.0), Interval.init(-3.0, 2.0) },
        .{ Interval.init(0.0, 0.0), Interval.init(-0.0, -0.0) },
        .{ Interval.init(1.0, 2.0), Interval.init(3.0, 4.0) },
        .{ Interval.init(-std.math.floatMax(f64), std.math.floatMax(f64)), Interval.init(0.0, 0.0) },
    };
    for (pairs) |p| {
        const two = [_]Interval{ p[0], p[1] };
        const hull = Interval.hullOf(&two);
        const want_hull = p[0].hull(p[1]);
        try std.testing.expect(hull != null);
        try std.testing.expect(hull.?.eql(want_hull));

        const inter = Interval.intersectionOf(&two);
        const want_inter = p[0].intersect(p[1]);
        if (want_inter) |w| {
            try std.testing.expect(inter != null);
            try std.testing.expect(inter.?.eql(w));
        } else {
            try std.testing.expect(inter == null);
        }
    }
}

// The certain comparisons across the four geometric classes, spelled out
// rather than drawn. The generator reaches these classes by luck and
// unevenly — `touching` in particular needs two endpoints to land on the
// same value, which a continuous draw essentially never does — and a law
// that only fires in a class the sweep does not reach is a law that has
// not been tested. So the four classes are built here, from integers, and
// the sound direction of all six comparisons is checked on each.
test "the certain comparisons on the four geometric classes" {
    const classes = [_][2]Interval{
        // overlapping: both intervals reach into the same place
        .{ Interval.init(1.0, 5.0), Interval.init(3.0, 7.0) },
        // touching at a shared endpoint
        .{ Interval.init(1.0, 3.0), Interval.init(3.0, 5.0) },
        // separated with a gap
        .{ Interval.init(1.0, 3.0), Interval.init(4.0, 5.0) },
        // degenerate: a point inside the other
        .{ Interval.init(1.0, 5.0), Interval.init(3.0, 3.0) },
    };
    for (classes) |p| {
        const a = p[0];
        const b = p[1];
        // lt is the one whose failure is a soundness failure: it may
        // fail to prove, it may never claim. An interval that shares a
        // point with the other is not certainly below it.
        if (a.overlaps(b)) {
            try std.testing.expect(!a.lt(b));
            try std.testing.expect(!a.gt(b));
        }
        if (a.hi < b.lo) try std.testing.expect(a.lt(b));
        if (a.lo > b.hi) try std.testing.expect(a.gt(b));
        // le and ge admit exactly the touching case that lt and gt do not.
        if (a.hi <= b.lo) try std.testing.expect(a.le(b));
        if (a.lo >= b.hi) try std.testing.expect(a.ge(b));
        if (a.hi <= b.lo and !(a.hi < b.lo)) try std.testing.expect(!a.lt(b));
        if (a.lo >= b.hi and !(a.lo > b.hi)) try std.testing.expect(!a.gt(b));
        // Equality is mutual containment, and an overlapping pair that is
        // not contained either way is not equal.
        const same = a.subsetOf(b) and b.subsetOf(a);
        try std.testing.expect(a.eql(b) == same);
        try std.testing.expect(a.ne(b) == !same);
        // The negation of a certain order is the certain order the other
        // way round, and the two must never both be true.
        try std.testing.expect(!(a.lt(b) and a.ge(b)));
        try std.testing.expect(!(a.lt(b) and a.gt(b)));
        try std.testing.expect(!(a.le(b) and a.ge(b)));
        try std.testing.expect(!(b.lt(a) and b.ge(a)));
    }
}

// ---------------------------------------------------------------------------
// The NaN-scalar trap, seen from outside the process
// ---------------------------------------------------------------------------

/// Where `build.zig` put the built `nan_probe`. `tests/nan_probe.zig` and
/// that file's build wiring both say why the observation has to happen in a
/// child: a trap is an abort, an abort inside a test binary takes the other
/// tests with it, and the exit status is the only signal that survives.
const nan_probe = @import("nan_probe_options");

/// The operations the NaN contract names. The test walks this list and not
/// the probe's own, so that an operation the probe fails to dispatch shows
/// up as a failed control below rather than as a pass that quietly has an
/// unrunnable row in it.
const nan_ops = [_][]const u8{
    "add",
    "sub",
    "mul",
    "div",
    "scale",
    "expand",
    "translate",
    "neg",
};

/// The offending scalar, as text. `parseFloat` accepts "nan", so the probe
/// is handed the same NaN a caller would produce.
const nan_value = "nan";

/// An ordinary scalar, and what the control run passes where the NaN was.
/// Every operation above is defined on it, so a control that dies is a
/// broken probe and not a surprise about the arithmetic.
const control_value = "2.0";

/// What one probe run reported, reduced to the fact the contract turns on.
const ProbeVerdict = struct {
    /// True when the child did not exit cleanly with status zero. A trap
    /// counts however it arrives, because it arrives as a signal under POSIX
    /// and as an exit code under Windows, and a contract that noticed only
    /// one of those would be reporting the platform.
    died: bool,
    /// The exit code, or null when the child was signalled or stopped and
    /// had no code to report.
    code: ?u8,
};

/// Run the probe once. A failure to run at all is an error and never a
/// verdict: a probe that cannot be spawned has reported nothing about the
/// library, and turning that into "it died" would be the vacuous pass.
fn runProbe(op: []const u8, value: []const u8) !ProbeVerdict {
    const runner = @import("probe_runner_options").runner;
    const argv = [_][]const u8{ runner orelse "", nan_probe.probe_path, op, value };
    var child = try std.process.spawn(std.testing.io, .{
        .argv = if (runner == null) argv[1..] else &argv,
        .stdin = .ignore,
        // Every trapping row makes the child print a panic message, and a
        // passing sweep should be quiet. The exit status is the signal.
        .stdout = .ignore,
        .stderr = .ignore,
    });
    // Idempotent, and a no-op once wait has returned.
    defer child.kill(std.testing.io);
    const term = try child.wait(std.testing.io);
    return switch (term) {
        .exited => |code| .{ .died = code != 0, .code = code },
        .signal, .stopped, .unknown => .{ .died = true, .code = null },
    };
}

/// One row of the report: which operation, which scalar, and what the child
/// did about it.
fn reportVerdict(row: []const u8, op: []const u8, value: []const u8, v: ProbeVerdict) void {
    if (v.code) |code| {
        std.debug.print("    {s} {s} with {s} -> exit code {d}\n", .{ row, op, value, code });
    } else {
        std.debug.print("    {s} {s} with {s} -> died with no exit code\n", .{ row, op, value });
    }
}

test "contract: a NaN scalar traps in every operation named, and in no other" {
    // Two runs per operation, and the control is what gives the trapping run
    // its meaning. It is the same probe, the same code path and the same
    // operation with an ordinary scalar where the NaN was, so a probe that
    // cannot find its operation, cannot be spawned, or is broken in any other
    // way fails the control and takes the test down with it.
    var verdicts: [nan_ops.len]ProbeVerdict = undefined;
    var controls: [nan_ops.len]ProbeVerdict = undefined;

    std.debug.print("\n  NaN scalar, observed as a child process:\n", .{});
    for (nan_ops, 0..) |op, i| {
        controls[i] = try runProbe(op, control_value);
        verdicts[i] = try runProbe(op, nan_value);
        reportVerdict("control", op, control_value, controls[i]);
        reportVerdict("nan    ", op, nan_value, verdicts[i]);
    }

    // The claim is agreement, so the set is judged as a whole rather than one
    // row at a time: every named operation must trap, and every control must
    // come back clean. One survivor means an operation disagrees with the
    // rest, and the report above already names which one.
    var trapped: usize = 0;
    var survived: usize = 0;
    var control_failed: usize = 0;
    for (verdicts, controls) |v, c| {
        if (v.died) trapped += 1 else survived += 1;
        if (c.died) control_failed += 1;
    }
    std.debug.print("    -> {d} of {d} operations trapped on the NaN, {d} well-formed controls failed\n", .{
        trapped,
        nan_ops.len,
        control_failed,
    });

    try std.testing.expectEqual(@as(usize, 0), survived);
    try std.testing.expectEqual(@as(usize, 0), control_failed);
}
