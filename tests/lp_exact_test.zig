//! Tests for the extracted exact-arithmetic block, `src/lp_exact.zig`.
//!
//! NOTHING HERE CONSTRUCTS A `System`, AND THAT IS THE POINT OF THE FILE.
//! This compilation takes `lp_exact` as its only project module and imports
//! no `lp` at all, so every question below is put to a pure function of its
//! arguments: no allocator is named, nothing is stored, and the four
//! operands of the cancellation decision are written down directly instead of
//! being reached by adding rows to a system and driving an elimination until
//! they happen to appear. Before the block was extracted that was the only
//! way to ask any of these questions.
//!
//! What is being pinned is the block's arithmetic, not the solver's memory:
//! the structural zero, the `f128` cancellation, the two filters in front of
//! it, and the three predicates the pairing rests on. The solver-level
//! consequences live in `tests/lp_test.zig`, which still drives real
//! systems; these are the units those sit on.

const std = @import("std");
const exact = @import("lp_exact");

const Interval = exact.Interval;

/// The degenerate interval around a single value.
fn pt(v: f64) Interval {
    return Interval.init(v, v);
}

/// One side of a pairing, built from the three values the block reads. This
/// is `lp.zig`'s `sideOf` inlined, and nothing here needs a `System` to
/// exist before it can be called.
fn side(coeff: Interval, coeffs: []const Interval, rhs: Interval) exact.Side {
    return .{ .coeff = coeff, .coeffs = coeffs, .rhs = rhs };
}

/// The double one ULP above `1.0`, as a pattern rather than as a decimal
/// spelling: no decimal literal in the file is the neighbour of one, and a
/// literal that was not the neighbour would make every test below vacuous.
const one_ulp_above_one: f64 = @bitCast(@as(u64, 0x3FF0000000000001));

/// The double one ULP below `1.0`, 0x3FEFFFFFFFFFFFFF.
const one_ulp_below_one: f64 = @bitCast(@as(u64, 0x3FEFFFFFFFFFFFFF));

/// Assert that `got` contains the real `truth`.
///
/// The comparison runs in `f128` because that is where the reference lives:
/// an `f64` endpoint widens exactly, and the exact combination it is checked
/// against generally does not fit in `f64` at all. Widening rather than
/// narrowing is what keeps the containment half sound - a bound read at a
/// rounded reference could exclude a value the bound was holding.
fn expectContains(got: Interval, truth: f128) !void {
    try std.testing.expect(@as(f128, got.lo) <= truth);
    try std.testing.expect(@as(f128, got.hi) >= truth);
}

test "the structural zero is [0, 0] and nothing that is merely small" {
    try std.testing.expect(exact.isExactZero(exact.zero));

    // Both spellings of the point zero. `Interval` takes them, `lo <= hi`
    // holds across the pair of signed zeros, and the partition reads both as
    // the structural zero.
    try std.testing.expect(exact.isExactZero(Interval.init(-0.0, -0.0)));
    try std.testing.expect(exact.isExactZero(Interval.init(0.0, -0.0)));

    // A widening artefact around zero is not a zero, and this is the shape D4
    // was about: a hair either side of the truth, stored where a coefficient
    // belongs, and read by every later round as a constraint from both sides.
    const straddle = Interval.init(-1.1102230246251565e-16, 1.1102230246251565e-16);
    try std.testing.expect(!exact.isExactZero(straddle));
    try std.testing.expect(straddle.lo < 0.0 and straddle.hi > 0.0);

    // A coefficient that REACHES zero is a coefficient. [0, 1] bounds its
    // variable from above and [−1, 0] from below, which is why the partition
    // files such a row in two buckets rather than dropping it.
    try std.testing.expect(!exact.isExactZero(Interval.init(0.0, 1.0)));
    try std.testing.expect(!exact.isExactZero(Interval.init(-1.0, 0.0)));

    // And a plain nonzero is not one either.
    try std.testing.expect(!exact.isExactZero(pt(1.0)));
    try std.testing.expect(!exact.isExactZero(Interval.init(-1e-300, 1e-300)));
}

test "a point is a different question from the zero" {
    // `cancelsExactly` needs both. A product hull collapses only when a
    // factor collapses, and a factor collapses at any value and not only at
    // zero, so the guard that keeps the `f128` out of the common path cannot
    // be the exact-zero test.
    try std.testing.expect(exact.isPoint(pt(-7.5)));
    try std.testing.expect(exact.isPoint(Interval.init(1.0e-300, 1.0e-300)));
    try std.testing.expect(!exact.isPoint(Interval.init(1.0, 2.0)));
    try std.testing.expect(!exact.isPoint(Interval.init(-1.0, 1.0)));

    try std.testing.expect(exact.isExactZero(exact.zero));
    try std.testing.expect(!exact.isExactZero(pt(-7.5)));
}

test "a cancelling pair of products is the structural zero" {
    // The D4 shape from the reproducer in `tests/lp_test.zig`, taken apart
    // into the values `combinedColumn` reads, with no system anywhere:
    //
    //     upper side:  multiplier +1,  row [ 1,  5], right-hand side 1
    //     lower side:  multiplier -1,  row [-1, -3], right-hand side 0
    //
    // Column 0 is the cancellation D4 was about. `upper * lj` and
    // `lower * uj` are both -1 there, so their difference is exactly zero for
    // every realisation of the four operands and the derived row does not
    // mention that variable at all. Column 1 is perturbed off the cancelling
    // pattern so both behaviours are visible in one pair of rows.
    const r0 = [_]Interval{ pt(1.0), pt(5.0) };
    const r1 = [_]Interval{ pt(-1.0), pt(-3.0) };
    const lower = side(pt(-1.0), &r1, pt(0.0));
    const upper = side(pt(1.0), &r0, pt(1.0));

    try std.testing.expectEqual(exact.zero, exact.combinedColumn(lower, upper, 0));

    // THE SAME COLUMN THROUGH THE GENERAL BRANCH. `Interval.mul` widens
    // outward even when the product is exact, so both products come back as
    // [-1.0000000000000002, -0.9999999999999999] and their difference is a
    // straddle either side of zero. `isExactZero` calls that a coefficient,
    // which is the whole of D4: the next round then pairs rows that share no
    // variable, and `bounds` divides a right-hand side by an endpoint of it.
    const lj = lower.coeffs[0];
    const uj = upper.coeffs[0];
    const widened = upper.coeff.mul(lj).sub(lower.coeff.mul(uj));
    try std.testing.expect(!exact.isExactZero(widened));
    try std.testing.expect(widened.lo < 0.0 and widened.hi > 0.0);

    // The y column of the same pair does NOT cancel - it is -1 * -3 minus
    // -1 * 5, which is 2 - so it keeps the ordinary widened answer, and that
    // answer contains the truth. `combinedColumn` is not "always zero": it
    // answers per column, on the operands of that column.
    try expectContains(exact.combinedColumn(lower, upper, 1), 2);
    try std.testing.expect(!exact.isExactZero(exact.combinedColumn(lower, upper, 1)));
}

test "a column one row does not mention takes that row's branch" {
    // Lower multiplier -3 against upper multiplier +1, so the two structural
    // branches answer with different numbers, -6 and -2, and neither can be
    // mistaken for the other.
    const mentions_x_only = [_]Interval{ pt(-2.0), exact.zero };
    const mentions_nothing = [_]Interval{ exact.zero, exact.zero };

    // `lj` is the structural zero and `uj` is not, so the coefficient is the
    // LOWER multiplier against the upper row's coefficient, negated:
    // -(-3) * -2 = -6.
    const lower_absent = side(pt(-3.0), &mentions_nothing, pt(0.0));
    try expectContains(exact.combinedColumn(lower_absent, side(pt(1.0), &mentions_x_only, pt(1.0)), 0), -6);

    // The mirror: `uj` is the structural zero, so the coefficient is the
    // UPPER multiplier against the lower row's coefficient: 1 * -2 = -2.
    const upper_absent = side(pt(1.0), &mentions_nothing, pt(1.0));
    try expectContains(exact.combinedColumn(side(pt(-3.0), &mentions_x_only, pt(0.0)), upper_absent, 0), -2);

    // Neither row mentions the second variable, so the system has a variable
    // nothing constrains and that column must stay exactly [0, 0]. This is
    // the invariant `isExactZero` reads back, and a straddle there is how it
    // stops holding: the next round would read it as a bound from both sides
    // and pair rows that share no variable.
    try std.testing.expectEqual(exact.zero, exact.combinedColumn(lower_absent, upper_absent, 1));
    try std.testing.expectEqual(exact.zero, exact.combinedColumn(side(pt(-3.0), &mentions_x_only, pt(0.0)), upper_absent, 1));
}

test "cancellation is an equality, not a closeness" {
    // 2 * 3 = 6 and (-6) * (-1) = 6, and both pairs are points, so both
    // products are the same interval for every realisation.
    try std.testing.expect(exact.cancelsExactly(pt(2.0), pt(3.0), pt(-6.0), pt(-1.0)));

    // THE SHAPE `combinedColumn` ACTUALLY ASKS ABOUT: `u * a` and `l * b`
    // with `u = 1`, `a = -1`, `l = -1`, `b = 1`, so both products are -1.
    // Reading it as `u * a` against `l * b` with any other sign on `b` gives
    // -1 against +1, which is a difference and not a cancellation.
    try std.testing.expect(exact.cancelsExactly(pt(1.0), pt(-1.0), pt(-1.0), pt(1.0)));

    // NEIGHBOURING FACTORS. The two products differ by one ULP of one, and
    // one ULP is a coefficient like any other: writing it as the structural
    // zero would discard a real constraint on the variable. There is no
    // tolerance in this function and there must not be one.
    try std.testing.expect(!exact.cancelsExactly(pt(1.0), pt(1.0), pt(1.0), pt(one_ulp_above_one)));
    try std.testing.expect(!exact.cancelsExactly(pt(one_ulp_above_one), pt(1.0), pt(1.0), pt(1.0)));

    // THE SAME QUESTION AT A MAGNITUDE WHERE "CLOSE" IS TEMPTING.
    try std.testing.expect(!exact.cancelsExactly(pt(1.0), pt(1.0), pt(1.0e-300), pt(1.0e-300)));

    // A product that underflows is not a zero. The `f64` corner is 0 and the
    // `f128` one is 1e-600, and the difference is a decline rather than a
    // cancellation.
    try std.testing.expect(!exact.cancelsExactly(pt(1.0e-300), pt(1.0e-300), pt(1.0), pt(1.0)));

    // THE STRUCTURAL FILTER, ISOLATED. Neither factor of either product is a
    // point, so neither hull can be one, and the verdict is no before any
    // `f128` is touched. The two products here are exactly equal, so without
    // that guard this pair would answer YES and write the structural zero
    // over a coefficient of 1.
    const band = Interval.init(1.0, 2.0);
    try std.testing.expect(!exact.cancelsExactly(band, band, band, band));

    // A band against a point is still a band, because the point is the other
    // factor and the hull is over both.
    try std.testing.expect(!exact.cancelsExactly(pt(2.0), Interval.init(3.0, 4.0), pt(-6.0), pt(-1.0)));
}

test "the rounded hull is a filter and not the decision" {
    // `cancelsExactly` builds four rounded corners before it pays for
    // `f128`. That filter is sound because rounding to nearest is monotone,
    // and it is a FILTER: it can admit a pair that does not cancel, which is
    // why the exact comparison follows it. This is such a pair.
    //
    //     (1 + 2^-52) * (1 - 2^-53)  =  1 + 2^-53 - 2^-105
    //
    // which is not 1, and which rounds to 1 anyway: it sits nearer to 1.0
    // than to the next double above it. Both operands are points and both
    // products are finite, so nothing in the guards declines it.
    try std.testing.expectEqual(pt(1.0), exact.doubleProduct(pt(one_ulp_above_one), pt(one_ulp_below_one)));
    try std.testing.expect(!exact.cancelsExactly(pt(one_ulp_above_one), pt(one_ulp_below_one), pt(1.0), pt(1.0)));

    // The exact products do differ, and it is the exact pair that decides.
    const rounded_pair = exact.exactProduct(pt(one_ulp_above_one), pt(one_ulp_below_one));
    const plain_pair = exact.exactProduct(pt(1.0), pt(1.0));
    try std.testing.expect(rounded_pair.lo != plain_pair.lo);
    try std.testing.expect(rounded_pair.hi > plain_pair.hi);

    // The same two products with the sides exchanged are still not a
    // cancellation: the question is an equality, and it does not care which
    // side an operand came from.
    try std.testing.expect(!exact.cancelsExactly(pt(1.0), pt(1.0), pt(one_ulp_above_one), pt(one_ulp_below_one)));
}

test "two rounded hulls that differ are two exact hulls that differ" {
    // The soundness of the `f64` filter, as the property it rests on.
    // Rounding to nearest is monotone, so the minimum of the rounded corners
    // is the rounding of the minimum: `doubleProduct`'s endpoint IS the
    // rounding of `exactProduct`'s. So two rounded hulls that differ prove
    // the exact hulls differ, and declining there is a decision rather than
    // a guess.
    //
    // The operands stay below 1e150 so that no product leaves the range of
    // the format: a saturated `+inf` rounds back to `floatMax`, and the
    // endpoint-to-endpoint correspondence the argument needs would not hold.
    // Every pair below is a pair `cancelsExactly` accepts past its guards,
    // which is why `allFinite` can decline an overflow but this sweep must
    // not contain one.
    const operands = [_]Interval{
        Interval.init(1.0, 1.0),
        Interval.init(-1.0, -1.0),
        Interval.init(0.0, 0.0),
        Interval.init(1.0, 2.0),
        Interval.init(-2.0, -1.0),
        Interval.init(-1.0, 1.0),
        Interval.init(0.5, 1.5),
        Interval.init(-1.5, -0.5),
        Interval.init(3.0, 7.0),
        Interval.init(-7.0, -3.0),
        Interval.init(1.0e-150, 1.0e-150),
        Interval.init(-1.0e-150, 1.0e-150),
        Interval.init(1.0e150, 1.0e150),
        Interval.init(-1.0e150, -1.0e150),
        Interval.init(1.0, 1.0e150),
        Interval.init(-1.0e150, -1.0),
    };

    var compared: usize = 0;
    for (operands, 0..) |a, i| {
        for (operands, 0..) |b, j| {
            const rounded = exact.doubleProduct(a, b);
            const precise = exact.exactProduct(a, b);
            for (operands, 0..) |c, k| {
                const d = operands[(k + i + j + 1) % operands.len];
                const other_rounded = exact.doubleProduct(c, d);
                if (rounded.lo == other_rounded.lo and rounded.hi == other_rounded.hi) continue;
                const other_precise = exact.exactProduct(c, d);
                try std.testing.expect(precise.lo != other_precise.lo or precise.hi != other_precise.hi);
                compared += 1;
            }
        }
    }
    // A sweep that never compared anything would pass every assertion in it.
    try std.testing.expect(compared > 0);
}

test "an infinite endpoint declines" {
    // `0 * inf` is a NaN corner, a NaN loses the reduction, and recovering
    // the exact image of a zero interval against an unbounded one from the
    // corners is a special case worth nothing here. Those operands go to the
    // widened path unchanged, which is the answer this function has always
    // given and is never an unproven one.
    const inf = std.math.inf(f64);
    try std.testing.expect(!exact.allFinite(Interval.init(0.0, inf)));
    try std.testing.expect(!exact.allFinite(Interval.init(-inf, inf)));
    try std.testing.expect(!exact.allFinite(Interval.init(-inf, 0.0)));
    try std.testing.expect(exact.allFinite(pt(1.0e300)));
    try std.testing.expect(exact.allFinite(exact.zero));

    // The guard is reachable with everything else in the pair perfect, which
    // is the only way to see it is the guard and not one of the other two.
    try std.testing.expect(!exact.cancelsExactly(Interval.init(0.0, inf), pt(1.0), pt(-1.0), pt(1.0)));
    try std.testing.expect(!exact.cancelsExactly(pt(1.0), pt(1.0), pt(1.0), Interval.init(-inf, 1.0)));
}

test "the combined bound contains the combination" {
    // `upper * lower_rhs - lower * upper_rhs`, over point multipliers, so
    // the true combination is a single real and the check is exact. This is
    // the enclosure `checkRowForContradiction` and `derivesContradiction`
    // both rely on: `hi < 0` is read as a PROOF that no row can hold, so a
    // bound that missed the truth here would declare a satisfiable system
    // unsatisfiable and cut the feasible set.
    const cases = [_][4]f64{
        // upper multiplier, lower right-hand side, lower multiplier, upper right-hand side.
        .{ 3.0, 5.0, -1.0, 7.0 },
        .{ 1.0, 1.0, -1.0, 1.0 },
        .{ 0.25, -8.0, -4.0, 0.125 },
        .{ 1.0, 0.0, -1.0, 0.0 },
        .{ 7.0, -3.0, -2.0, 5.0 },
        .{ 1.0e150, 1.0e150, -1.0, 1.0e150 },
    };

    for (cases) |c| {
        const lower = side(pt(c[2]), &[_]Interval{}, pt(c[1]));
        const upper = side(pt(c[0]), &[_]Interval{}, pt(c[3]));
        const truth: f128 = @as(f128, c[0]) * @as(f128, c[1]) -
            @as(f128, c[2]) * @as(f128, c[3]);
        try expectContains(exact.combinedBound(lower, upper), truth);
    }

    // The exact-zero combination, which the reproducer derives, is readable
    // as an enclosure around zero rather than as the structural zero. That
    // is the difference between a bound and a coefficient: this one is
    // existential and only its `hi` can prove anything.
    const cancelling = exact.combinedBound(
        side(pt(-1.0), &[_]Interval{}, pt(0.0)),
        side(pt(1.0), &[_]Interval{}, pt(1.0)),
    );
    try expectContains(cancelling, 1);
    try std.testing.expect(cancelling.hi >= 1.0);
}

test "the divisor is the piece whole, or the far endpoint where an ENDPOINT is zero" {
    const no_columns = [_]Interval{};
    const inf = std.math.inf(f64);

    // THE GUARD, SPELLED OUT. `boundDivisor` asks whether NEITHER ENDPOINT is
    // zero - `coeff.lo != 0 and coeff.hi != 0` - and a piece that passes
    // comes back WHOLE. It does not ask whether the piece CONTAINS zero.
    // Those are two questions, and they come apart on exactly one shape: a
    // piece that straddles zero and has no zero endpoint, [-1, 1] below.
    //
    // So a piece with neither endpoint at zero divides by itself.
    try std.testing.expectEqual(
        Interval.init(-3.0, -2.0),
        exact.boundDivisor(side(Interval.init(-3.0, -2.0), &no_columns, pt(0.0))),
    );
    try std.testing.expectEqual(
        Interval.init(2.0, 3.0),
        exact.boundDivisor(side(Interval.init(2.0, 3.0), &no_columns, pt(0.0))),
    );

    // A piece with an endpoint exactly AT zero is a single endpoint instead,
    // because `Interval.div` answers a divisor that contains zero with the
    // whole line, which is not a bound in either direction. The survivor is
    // the endpoint farthest from zero, and on this path that is necessarily
    // the endpoint that is not zero: the guard has already turned away the
    // only shape on which the two readings could differ. Every case here has
    // one zero endpoint and one nonzero one, so preferring the zero, or
    // exchanging the two sides, fails; the magnitudes are not all 1, so a
    // rule which pinned the magnitude instead of reading it fails too.
    try std.testing.expectEqual(
        pt(-1.0),
        exact.boundDivisor(side(Interval.init(-1.0, 0.0), &no_columns, pt(0.0))),
    );
    try std.testing.expectEqual(
        pt(-0.25),
        exact.boundDivisor(side(Interval.init(-0.25, 0.0), &no_columns, pt(0.0))),
    );
    try std.testing.expectEqual(
        pt(1.0),
        exact.boundDivisor(side(Interval.init(0.0, 1.0), &no_columns, pt(0.0))),
    );
    try std.testing.expectEqual(
        pt(4.0),
        exact.boundDivisor(side(Interval.init(0.0, 4.0), &no_columns, pt(0.0))),
    );

    // WHY THE COLLAPSE IS WORTH ANYTHING. Handed the point the collapse
    // produces, the right-hand side divides to a finite bound that contains
    // the true quotient. That is the whole reason the branch above exists,
    // and `bounds` and `box` read exactly this quotient off `BoundReader`.
    const collapsed = exact.boundDivisor(side(Interval.init(0.0, 2.0), &no_columns, pt(0.0)));
    const quotient = Interval.init(1.0, 2.0).div(collapsed);
    try std.testing.expect(std.math.isFinite(quotient.lo) and std.math.isFinite(quotient.hi));
    try expectContains(quotient, 1);

    // AND THE PIECE THE GUARD DOES NOT CATCH. The name and the comment this
    // test used to carry claimed a divisor that REACHES ZERO is the far
    // endpoint as a point, which is the doc's own "does not reach zero"
    // phrasing read as containment. Neither is what the code does for a
    // piece that straddles: neither endpoint of [-1, 1] is zero, so the
    // guard fires, the piece comes back WHOLE, and `Interval.div` then takes
    // its `.straddle` arm and answers the whole line. No bound at all, where
    // the name and the doc both promised one.
    //
    // No piece like this reaches the function from the solver, and that is
    // what keeps the disagreement from being a defect today.
    // `partitionInto` (`src/lp.zig:595-598`) files a straddling coefficient
    // as `[a.lo, 0]` in the lower bucket and `[0, a.hi]` in the upper, and
    // `BoundReader` (`src/lp.zig:360-370`) calls `boundDivisor` only for a
    // piece whose lo is below zero or whose hi is above zero. So every piece
    // that reaches the guard is one-sided outright, or one-sided and
    // touching zero at one end, and on those two shapes "neither endpoint is
    // zero" and "does not contain zero" are the same question. What is
    // pinned here is therefore the CONTRACT, so that a caller which does not
    // come through that switch is owed an answer it can predict. A11 in
    // `docs/tests-and-architecture-plan.md` records the open question.
    const straddling = side(Interval.init(-1.0, 1.0), &no_columns, pt(0.0));
    try std.testing.expectEqual(Interval.init(-1.0, 1.0), exact.boundDivisor(straddling));
    const by_straddling = Interval.init(1.0, 2.0).div(exact.boundDivisor(straddling));
    try std.testing.expectEqual(Interval.init(-inf, inf), by_straddling);

    // The structural zero is a piece with an endpoint at zero like any other
    // and hands back [0, 0] unchanged. It is the only shape on which the
    // magnitude comparison is a TIE, both candidates being zero, so the tie
    // decides nothing observable; what matters is that the whole zero
    // reaches `div` and is answered with the whole line.
    const zero_piece = side(exact.zero, &no_columns, pt(0.0));
    try std.testing.expectEqual(exact.zero, exact.boundDivisor(zero_piece));
    const by_zero = Interval.init(1.0, 2.0).div(exact.boundDivisor(zero_piece));
    try std.testing.expectEqual(Interval.init(-inf, inf), by_zero);
}

test "a row flat apart from the eliminated column is the shape the last round leaves" {
    const coeffs = [_]Interval{ exact.zero, pt(3.0), exact.zero };

    // Flat apart from column 1, which is the only one it mentions.
    try std.testing.expect(exact.isFlatApartFrom(&coeffs, 1));

    // Not flat apart from column 0, because column 1 is then part of the
    // question and is a coefficient.
    try std.testing.expect(!exact.isFlatApartFrom(&coeffs, 0));
    try std.testing.expect(!exact.isFlatApartFrom(&coeffs, 2));

    // The eliminated column is SKIPPED, not compared, so anything may sit
    // there. A coefficient that reaches zero is the common case and is what
    // makes `derivesContradiction` compute this twice for one row.
    try std.testing.expect(exact.isFlatApartFrom(&[_]Interval{ exact.zero, Interval.init(-1.0, 1.0) }, 1));

    // A row that mentions nothing at all is flat apart from every column.
    try std.testing.expect(exact.isFlatApartFrom(&[_]Interval{exact.zero}, 0));
    try std.testing.expect(exact.isFlatApartFrom(&[_]Interval{}, 0));

    // And a widening artefact is not a structural zero, in either position.
    const artefact = Interval.init(-1e-300, 1e-300);
    try std.testing.expect(!exact.isFlatApartFrom(&[_]Interval{artefact}, 1));
    try std.testing.expect(!exact.isFlatApartFrom(&[_]Interval{ exact.zero, artefact }, 0));
}
