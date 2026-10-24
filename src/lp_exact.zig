//! The exact arithmetic of the Fourier-Motzkin pairing, with no allocator
//! anywhere in it.
//!
//! Everything in this file is a function of its arguments. Nothing here owns
//! memory, borrows a `System`, or reaches one: what comes in is a multiplier
//! piece, a row's coefficients and a row's right-hand side, and what comes
//! out is a value. That is not true of `lp.zig`, whose other half is the
//! solver's storage, and it is the whole reason this half was lifted out. A
//! block that can be reached without building a system can be TESTED without
//! building one, and `tests/lp_exact_test.zig` does exactly that: it
//! constructs no `System`, allocates nothing, and still exercises the
//! decision the whole solver's correctness rests on. Before the move the only
//! way to ask a question about that decision was to build a system, add
//! rows, and drive an elimination until the four operands happened to appear.
//!
//! THE HARD PROOF IN THE TREE IS HERE. `combinedColumn` decides a cancelling
//! pair of products on the OPERANDS rather than on the widened products, in
//! `f128` where the question has an exact answer, and writes the structural
//! zero when the exact coefficient is zero. Deciding it on the widened
//! products would compare two approximations of a zero, which can only ever
//! report a straddle where the mathematics says there is nothing to report.
//! `cancelsExactly` below gives the bit count required for exact products.
//!
//! WHAT IS HERE AND WHAT IS NOT. `Lin` and `Part` stayed in `lp.zig`. They
//! are the solver's vocabulary - `System.partition` hands a `Part` out
//! inside a `Partition` that owns three slices - and this is not the solver.
//! The block takes `Side`, below, which carries the three values of a `Part`
//! that these functions actually read and nothing else; `lp.zig` builds one
//! in `sideOf`. `zero` is published because `lp.zig` writes it into the
//! eliminated column too, and a second definition of "the structural zero"
//! would be a second answer to the question.
//!
//! NOTHING HERE MAY BE GIVEN AN ALLOCATOR. Not for convenience, not later.
//! The moment one of these functions can fail, the test that exercises it
//! with no system is no longer possible, and that test is the entire reason
//! this block is a module of its own.

const std = @import("std");

/// Re-exported because it is this module's whole input and output type, and
/// because a test that cannot import anything else still has to be able to
/// build an operand. `lp.zig` imports `interval.zig` directly and does not
/// come through here.
pub const Interval = @import("interval.zig").Interval;

/// The degenerate interval written into a combined row for the eliminated
/// index. The two `x_k` terms cancel analytically, so the exact zero is the
/// truthful value; anything else would leave a rounding-thin straddle behind
/// that later reads as a bound on a variable that no longer appears.
pub const zero = Interval.init(0.0, 0.0);

/// One side of the pairing, reduced to what the exact arithmetic reads.
///
/// This is `lp.Part` with `lp.Lin` flattened and every name the solver owns
/// left out: the multiplier piece, the row's coefficients, and the row's
/// right-hand side. Nothing else in a `Part` is read by anything below, and
/// `Lin` carries a slice the system owns, so a struct that named one would
/// have dragged that ownership in with it and made this file testable only
/// by building the thing it is supposed to be separable from.
///
/// The field names are `lp.Part`'s and `lp.Lin`'s with the nesting taken
/// off, so `lp.zig`'s `sideOf` reads as what it is.
pub const Side = struct {
    /// The piece of the `x_k` coefficient that plays this side's role: a
    /// non-positive piece for the lower side, a non-negative one for the
    /// upper, and the exact [0, 0] for a row that does not mention `x_k`.
    coeff: Interval,
    /// The row's coefficients, one per variable. Read at the column being
    /// combined and never written; the slice belongs to the caller.
    coeffs: []const Interval,
    /// The row's right-hand side, which is EXISTENTIAL: the row holds for
    /// every realisation of the coefficients and against one unknown value
    /// drawn from here.
    rhs: Interval,
};

/// The coefficient in column `j` of the row that pairs `lower` with `upper`.
///
/// This is the branch logic of `lp.appendCombined`, lifted out so that
/// `lp.System.derivesContradiction` can ask the same question about the same
/// pair. It has to be the same question: a predicate that decided
/// all-zero-ness by a different rule would be answering about a row the
/// elimination never builds, and the difference would show up as a projection
/// that claims solutions exist where none do.
///
/// A zero coefficient is structural, not numerical: the variable is simply
/// absent from that row. A product with an exact zero factor is exactly zero,
/// `x - 0` is `x`, and `-x` is `Interval.neg`, which is exact. So a variable
/// that no row mentions stays exactly [0, 0] through the whole elimination
/// instead of drifting.
///
/// Letting the general form run on a structural zero would hand it to the
/// outward widening, which turns [0, 0] into a subnormal straddle. Every
/// later elimination reads that straddle as a constraint from both sides and
/// pairs rows that share no variable at all, and the row count compounds for
/// nothing. It is a soundness question too: a coefficient that is exactly
/// zero must be free of the variable, and a straddle does not say that.
///
/// The general branch reaches the same straddle by a different route, which
/// is the one the three branches above cannot catch: cancellation. A derived
/// row from `r0: x + y <= 1` paired with `r1: x + y >= 0` has an `x`
/// coefficient of `1 * -1 - -1 * 1`, which is exactly zero, and both products
/// have been widened by the time the subtraction sees them, so the widened
/// difference straddles zero and a row that does not mention `x` at all is
/// stored as one that bounds it from both sides by 3.0e15. The exactness test
/// runs on the four operands, which are the only version of the question that
/// has an exact answer; on the widened products it can only ever compare two
/// approximations of a zero.
pub inline fn combinedColumn(lower: Side, upper: Side, j: usize) Interval {
    const lj = lower.coeffs[j];
    const uj = upper.coeffs[j];
    if (isExactZero(lj) and isExactZero(uj)) return zero;
    if (isExactZero(lj)) return lower.coeff.mul(uj).neg();
    if (isExactZero(uj)) return upper.coeff.mul(lj);
    if (cancelsExactly(upper.coeff, lj, lower.coeff, uj)) return zero;
    return upper.coeff.mul(lj).sub(lower.coeff.mul(uj));
}

/// One interval in `f128`: the pair of endpoints `Interval` would carry if
/// its arithmetic were exact and it applied no outward step. It never is,
/// which is why nothing here is stored in one - this is a decision's
/// intermediate, not an answer.
pub const Exact = struct {
    lo: f128,
    hi: f128,
};

/// Do `u * a` and `l * b` cancel, so that the coefficient they form is zero
/// for EVERY realisation of the four operands?
///
/// THE PROPERTY, AND WHAT IS NOT BEING ASKED. This asks whether the two exact
/// product intervals are the same interval. When they are, every realisation
/// of `u`, `a`, `l` and `b` yields the same coefficient, zero, so the derived
/// row genuinely does not mention the variable - the invariant
/// `combinedColumn`'s doc claims and the one `isExactZero` reads back. What it
/// does NOT ask is whether the difference is small. A coefficient of 1e-300
/// is a coefficient: writing it as [0, 0] discards a real constraint on the
/// variable, and no tolerance appears anywhere in this function, so two
/// products that differ by one ULP fail the test and fall through to the
/// widened path, which is where every nonzero coefficient belongs.
///
/// WHY IT CANNOT NARROW A NONZERO RESULT. Nothing on this path is rounded,
/// and that is a property of the arithmetic rather than a hope about the
/// operands. Widening an `f64` endpoint to `f128` is exact; a product of two
/// doubles is exact at 106 significand bits against the 113 the type carries
/// (`tests/soundness_test.zig:11-18`); and the verdict is an EQUALITY between
/// two such products rather than a subtraction of them, so no sum is ever
/// evaluated that would want the extra bits a sum wants. The products cannot
/// overflow either: the largest product of two doubles is about 3.3e616
/// against an `f128` range that reaches 1.2e4932. Nor can one underflow
/// towards a zero: every double is an integer multiple of 2^-1074, so every
/// product is an integer multiple of 2^-2148, which is an ordinary normal
/// `f128`. So `p.lo == q.hi` is a claim about the mathematics and not about a
/// rounding of it, and two products that differ cannot be reported as equal.
/// Where the two intervals differ this function declines and the widened
/// path answers, exactly as it answered before; the only answer it ever
/// replaces is one it can prove to be the exact zero.
///
/// THE ONE CASE IT DECLINES. An infinite endpoint makes a corner `0 * inf`,
/// which IEEE makes a NaN, and a single NaN poisons the reduction that picks
/// the endpoints. The exact image of a zero interval against an unbounded one
/// is the zero interval, but recovering that from the corners is a special
/// case worth nothing on this path, so those operands go to the widened path
/// unchanged. Nothing is unproven there: it is the answer this function has
/// always given.
///
/// WHERE THE COST USED TO GO, AND WHY IT IS NOT HERE ANY MORE. This is the
/// innermost predicate of the pairing loop: `combinedColumn` asks it once
/// per column of every pair of rows, and on both generators the answer to
/// almost every one of those questions is no. The form this replaces reached
/// for `f128` to find that out, and an `f128` multiply on x86-64 is a
/// soft-float call, so a predicate that declines nearly always was paying
/// eight of them to do it. Two filters now sit in front of the exact
/// arithmetic, and both are consequences of the mathematics rather than
/// approximations of it.
///
/// THE FIRST IS STRUCTURAL. `exactProduct` returns a minimum of the four
/// corners as `lo` and a maximum of the same corners as `hi`, so `p.lo` is
/// never above `p.hi` whatever the operands are. That makes the old verdict
/// `p.lo == q.hi and p.hi == q.lo` a chain that closes on itself:
///
///     p.lo = q.hi <= q.lo = p.hi <= p.lo
///
/// and every link is an identity. Both products are therefore points, and a
/// product of two intervals is a point only if one of them is. Suppose
/// neither `u` nor `a` is a point: then `a.lo != a.hi`, so `u.lo * a.lo` and
/// `u.lo * a.hi` differ unless `u.lo == 0`; and if `u.lo == 0` then
/// `u.lo != u.hi` forces `u.hi != 0`, and `u.hi * a.lo`, `u.hi * a.hi` differ
/// instead. Either way one pair of corners straddles and the hull is wide,
/// so the old test could not have been true. Hence the guard below, and its
/// mirror for `l` and `b`.
///
/// Nothing the old form accepted is refused here: an unsound "no" would
/// have to be a pair of corner hulls that collapsed and did not, and the
/// paragraph above is the proof that none exists. It is the shape of the
/// question, not a tolerance on the operands, and no real coefficient
/// anywhere near zero is turned away by it.
///
/// THE SECOND IS ROUNDING. Among the survivors the corners are still built
/// in `f128`, but first they are built in `f64` and compared there. That is
/// sound because rounding to nearest is monotone: `x <= y` implies
/// `r(x) <= r(y)`, so the minimum of the rounded corners is the rounding of
/// the minimum, and two hulls that coincide exactly cannot differ after
/// rounding. Inequality of the rounded hulls therefore proves inequality of
/// the exact ones, and only hulls that already agree in `f64` are worth the
/// soft-float call. `doubleProduct` is never stored and is not an enclosure;
/// its only use is this comparison, and it is the only claim made about it.
pub inline fn cancelsExactly(u: Interval, a: Interval, l: Interval, b: Interval) bool {
    if (!isPoint(u) and !isPoint(a)) return false;
    if (!isPoint(l) and !isPoint(b)) return false;
    if (!allFinite(u) or !allFinite(a) or !allFinite(l) or !allFinite(b)) return false;
    const fp = doubleProduct(u, a);
    const fq = doubleProduct(l, b);
    if (fp.lo != fq.hi or fp.hi != fq.lo) return false;
    const p = exactProduct(u, a);
    const q = exactProduct(l, b);
    return p.lo == q.hi and p.hi == q.lo;
}

/// The same four corners as `exactProduct`, rounded to the nearest double.
///
/// NOT AN ENCLOSURE. Rounding each corner independently pulls the hull
/// inwards at both ends, so this is NARROWER than the exact image it is built
/// from, and nothing may be stored in it or read a bound off it. It is a
/// decision's intermediate, like `Exact`, and it exists only to be compared
/// against the same construction on the other pair of operands; see
/// `cancelsExactly` for the monotonicity argument that makes that comparison
/// a sound filter rather than a guess.
pub inline fn doubleProduct(a: Interval, b: Interval) Interval {
    const p: f64 = a.lo * b.lo;
    const q: f64 = a.lo * b.hi;
    const r: f64 = a.hi * b.lo;
    const s: f64 = a.hi * b.hi;
    return .{
        .lo = @min(@min(p, q), @min(r, s)),
        .hi = @max(@max(p, q), @max(r, s)),
    };
}

/// The exact image of `[a.lo, a.hi] * [b.lo, b.hi]`, as an `f128` interval.
///
/// The product of two intervals is the hull of the four corners, and every
/// corner of a rectangle over the reals is attained, so the two endpoints are
/// a min and a max of the four products. None of that is widened, because each
/// corner is exact (`cancelsExactly` carries the bit count). The caller must
/// have rejected an infinite endpoint: `0 * inf` is a NaN corner and a NaN
/// loses the reduction.
pub fn exactProduct(a: Interval, b: Interval) Exact {
    const p: f128 = @as(f128, a.lo) * @as(f128, b.lo);
    const q: f128 = @as(f128, a.lo) * @as(f128, b.hi);
    const r: f128 = @as(f128, a.hi) * @as(f128, b.lo);
    const s: f128 = @as(f128, a.hi) * @as(f128, b.hi);
    return .{
        .lo = @min(@min(p, q), @min(r, s)),
        .hi = @max(@max(p, q), @max(r, s)),
    };
}

/// True when neither endpoint is an infinity or a NaN, which is the
/// precondition `exactProduct` needs to keep a corner from being a NaN.
pub fn allFinite(v: Interval) bool {
    return std.math.isFinite(v.lo) and std.math.isFinite(v.hi);
}

/// The right-hand side of the row that pairs `lower` with `upper`: the same
/// expression `lp.appendCombined` stores, lifted out for the same reason.
pub inline fn combinedBound(lower: Side, upper: Side) Interval {
    return upper.coeff.mul(lower.rhs).sub(lower.coeff.mul(upper.rhs));
}

/// The divisor one side of a bound is read off with: the multiplier piece
/// itself where NEITHER OF ITS ENDPOINTS is zero, and its endpoint farthest
/// from zero as a point where one of them is.
///
/// The test is about ENDPOINTS, not about the piece CONTAINING zero, and on a
/// piece whose zero is in its INTERIOR the difference decides soundness
/// rather than tidiness. This sentence used to say "where that piece does not
/// reach zero", which reads as containment, and `Interval.div` does branch on
/// containment, so the doc and the guard really were answering different
/// questions about the same piece. They come apart on exactly one shape, a
/// piece that straddles with no zero endpoint such as `[-1, 1]`, and on that
/// shape this guard hands the piece back WHOLE. Handing it back whole is the
/// sound answer, and the reason is not the one the old comment reached for.
///
/// Reading a LOWER bound off `a * x_k <= rhs` takes the largest `rhs / a`
/// over the piece, and where that is finite it is attained at the NEGATIVE
/// end; reading an UPPER bound takes the smallest, and where that is finite
/// it is attained at the POSITIVE end. Whether either is finite at all is
/// `rhs`'s business and `Interval.div`'s to decide - a divisor with zero in
/// its interior has neither - and nothing below depends on the answer. So
/// the two reads of one row want OPPOSITE ends of the same piece, while this
/// function hands back ONE divisor for both, chosen by magnitude.
///
/// On a piece with only one sign the difficulty cannot arise. A piece that is
/// strictly one-sided is returned whole, and a piece that is one-sided and
/// closed at zero has exactly one endpoint that is not zero, so that endpoint
/// is both the extreme of the piece and the only end either read can want.
/// The magnitude comparison below finds it without being told which side the
/// caller is on, and it is a tie on `[0, 0]` alone, where both candidates are
/// zero and nothing observable turns on it.
///
/// On a piece with both signs the single divisor does not exist, and the end
/// magnitude picks is wrong for one of the two reads on EVERY such piece.
/// `[-1, 5]` picks `5`, so a lower read claims `x_k >= rhs.lo / 5 = 0.2`
/// against `rhs = [1, 2]`, while `x_k = -0.5` satisfies the row under EVERY
/// realisation of `a` in that piece: the largest `a * x_k` is at `a = -1` and
/// is `0.5`, at or below the smallest `rhs`. `[-1, 1]` is a tie and picks
/// `-1`, so an upper read claims `x_k <= -1`, while `x_k = 0.5` is admitted
/// the same way, at `a = 1`. One of the two reads is too tight either way,
/// and a bound too tight is not a bound.
///
/// `Interval.div` is not what fails here. The whole line it answers for a
/// divisor with zero in its interior is a correct answer to the question it
/// is asked, and `BoundReader` reads `-inf` and `+inf` off it and keeps the
/// bound it already had, so a row with nothing better to say contributes
/// nothing, which is sound. Earning a real bound on a straddling piece would
/// take one divisor per SIDE rather than one per row - a different interface,
/// not a different guard - and `partitionInto` splits every straddling piece
/// into two one-sided ones before `BoundReader` sees one, so it would change
/// no answer today.
///
/// This is the same one-sided reading `lp.System.eliminate` performs, asked of
/// the same object. `eliminate` needs only the SIGN of a multiplier, and a
/// piece that touches zero still has one, so it multiplies by the piece
/// whole. The guards an earlier form of this arm used - `neg_part.hi < 0`
/// and `pos_part.lo > 0` - were not merely narrow, they were
/// unsatisfiable: a piece that reaches zero has `lo <= 0 <= hi`, so
/// `min(hi, 0) < 0` and `max(lo, 0) > 0` can both never hold, and that arm
/// contributed nothing whatsoever. One round of elimination with an
/// uncertain coefficient is enough to put a zero-touching endpoint in
/// almost every derived coefficient, so almost every bounded variable read
/// as unbounded.
pub fn boundDivisor(side: Side) Interval {
    if (side.coeff.lo != 0 and side.coeff.hi != 0) return side.coeff;
    const far = if (@abs(side.coeff.lo) >= @abs(side.coeff.hi))
        side.coeff.lo
    else
        side.coeff.hi;
    return Interval.init(far, far);
}

/// True only for the exact zero interval, not for a widening artefact that
/// happens to be small.
pub fn isExactZero(a: Interval) bool {
    return a.lo == 0 and a.hi == 0;
}

/// True when `coeffs` is the exact [0, 0] in every column except `k`: the
/// shape a final round of elimination leaves behind, a row that mentions
/// `x_k` and nothing else. Asked once per side list, so a coefficient that
/// reaches zero has it computed twice. That is one extra pass over the
/// columns and it buys the shared buckets.
pub fn isFlatApartFrom(coeffs: []const Interval, k: usize) bool {
    for (coeffs, 0..) |a, j| {
        if (j == k) continue;
        if (!isExactZero(a)) return false;
    }
    return true;
}

/// True when the interval names a single real, `lo == hi`.
///
/// Not the same question as `isExactZero`, which asks whether that one real
/// is zero. `cancelsExactly` needs this one because a product hull is a point
/// only when a factor collapses, and a factor collapses at any value, not at
/// zero. It is two comparisons, and it is the first thing the pairing loop
/// asks, so it sits where the cheapest answer can end the question.
pub inline fn isPoint(a: Interval) bool {
    return a.lo == a.hi;
}
