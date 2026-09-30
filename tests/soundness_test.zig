//! Soundness oracle. The package's central claim is that every operation
//! returns a guaranteed enclosure of the true result of the expression it
//! was asked about, and this file is the only place in the tree that holds
//! that claim to account. Containment is the property under test, and the
//! quantity it is checked against is derived in `f128` from the original
//! `f64` inputs — never by evaluating the corners in `f64` and then
//! treating those results as truth. Evaluating the corners in `f64` and
//! believing them is the mistake that let a result that cuts inside the
//! true image pass 200 tests, so the oracle never makes it.
//!
//! Why `f128` is wide enough for the job, and exactly where it stops
//! being wide enough:
//!
//!   * A PRODUCT of two `f64` values needs 53 + 53 = 106 significand bits
//!     and `f128` carries 113, so every product corner this file forms is
//!     the true product and not a rounding of it. `mul`, `sqr`, the
//!     product corners of the frontier sweep and the cross-products the
//!     quotient checks run on all rest on that one fact.
//!   * A SUM of two `f64` values is a different claim, and an earlier
//!     version of this sentence was wrong about it. The two operands can
//!     sit two thousand binades apart — `floatMax - 3`, `1e300 - 1e-300`
//!     — and the exact sum then needs every one of those bits.
//!     `floatMax - 3` is more than a thousand significand bits wide,
//!     `f128` carries 113, and it rounds to `floatMax`: a reference that
//!     took the `f128` sum for the truth would clear a lower bound AT
//!     `floatMax` for an image reaching three below it. `add`, `sub`,
//!     `translate` and `expand` are therefore judged by a TwoSum RESIDUAL
//!     instead. `s` is the `f128` nearest the true sum and `err` is what
//!     makes `s + err` the true sum as reals, so a returned `f64` is
//!     compared against `s` and, where the two are equal, against the sign
//!     of `err`. That comparison is exact, and it never asks a production
//!     rounding what the answer ought to be.
//!   * The `f128` exponent range vastly exceeds `f64`'s, so a product that
//!     overflows or a product that underflows to a signed zero in `f64` —
//!     1e600, 1e-400 — is an ordinary normal number here. The oracle never
//!     loses the magnitude or the sign exactly where the library does, and
//!     neither the sum nor the residual of a sum of finite `f64`s can
//!     overflow or underflow `f128`, so the residual path has no regime to
//!     exclude and no fallback to reach for.
//!   * A quotient is NOT exact even in `f128`, so `div` and `recip` are
//!     never checked by evaluating a quotient. They are checked by exact
//!     cross-multiplication: the bound times the divisor is an `f64` times
//!     an `f64`, which `f128` holds exactly, and the sign of the divisor
//!     fixes the direction of the comparison.
//!
//! The finite layer was RED against the tree this file was written for —
//! the pre-fix one, where 9 of the 15 tests fail — and GREEN against the
//! tree as it stood when it was written. It is kept rather than deleted at
//! that point, because it goes red again the moment an operation stops
//! enclosing.
//!
//! The frontier layer is the other half of the file, and it is an ACTIVE
//! GATE against the approved canonical-ray contract rather than a row of
//! known failures. `src/` now carries that contract, and every row it names
//! has been observed at runtime, so a frontier failure is a report about the
//! tree and never an allowance made in advance.
//!
//! THIRTEEN operations are judged there — `add`, `sub`, `translate`,
//! `expand`, `neg`, `recip`, `mul`, `div`, `abs`, `sqr`, `scale`, `hull`
//! and `intersect` — every one of them against a reading the contract
//! fixes rather than one this file picks, and a finding there is a real
//! gap in `src/` rather than a defect in the oracle. Each is reported
//! with the shape that triggers it, the reference it misses and the
//! requirement the answer breaks.
//!
//! The coverage is in three layers, in descending order of strength, and
//! which layer an operation falls in is a property of the operation
//! rather than a choice:
//!
//!   * EXACT. `add`, `sub`, `mul`, `translate`, `scale`, `expand`, `abs`,
//!     `sqr`, `neg`, `hull`, `hullOf`, `intersect`, `intersectionOf`,
//!     `sqrt`, `cbrt`, `floor`, `ceil`, `trunc` and `round` are checked
//!     against the true mathematical image, built from the original `f64`
//!     endpoints. Most of those need no `f128` at all: a magnitude, a
//!     square, a negation, a min and a max of two `f64` are all exact
//!     rounding of it. The four whose extremum is a SUM are the exception
//!     the paragraph above names: `add`, `sub`, `translate` and `expand`
//!     are judged by the TwoSum residual rather than by an `f128` sum,
//!     which is exact and is not a rounding of anything. `scale` is the
//!     fifth kind again: its extrema are `(A + B + G*A - G*B) / 2` and
//!     `(A + B - G*A + G*B) / 2`, and the division by two is a sixth term
//!     no `f128` supplies, so it is judged by the sign of the exact sum of
//!     FIVE `f128` terms — the two original endpoints, two products of
//!     original `f64`s and twice the returned bound — held as an
//!     error-free expansion. No midpoint and no half-width is formed on the
//!     way there, which is the whole point: the rounded midpoint of
//!     `[min_subnormal, floatMax]` sits a half-subnormal inside the true
//!     centre and a reference that formed it first would clear it.
//!     `div` and `recip` are checked by exact cross-multiplication, and a
//!     divisor that REACHES zero is checked too, from the sign of the two
//!     one-sided limits rather than from any quotient — the library has a
//!     documented answer there and it is a contract value, not a case the
//!     oracle declines to judge.
//!   * EXACT-UP-TO-A-STATED-MARGIN. `sqrt` rests on the one guarantee the
//!     package already names for it — IEEE 754 requires `sqrt` to be
//!     correctly rounded — and then demands a bound that clears half an
//!     ULP, which is a fact about the standard rather than about the
//!     primitive. `cbrt` gets no such guarantee: IEEE 754 does not
//!     require it and `std.math.cbrt` is a musl port whose accuracy is
//!     claimed and not stated, so its reference brackets the true root
//!     with the sign of `y^3 - x`, which is a fact about reals and holds
//!     whatever the primitive computed. That is the only reference for
//!     `cbrt` that does not assume the answer.
//!   * VALUES. `midpoint`, `clamp`, `width` and `distanceTo` return a number
//!     and there is an exact reference for each: the centre, the nearer
//!     endpoint, and the difference of the two `f64` endpoints formed in
//!     `f128`. They are judged by closeness from BOTH sides (`scalarOk`,
//!     one ULP), because a value is not a bound and a rule that only asks
//!     "is it big enough" accepts +inf for a true 0.5. `width` and
//!     `distanceTo` sat under the LAWS below until the sweep showed why that
//!     was the wrong layer: a magnitude rule passed every one of their 8,000
//!     cases while `Interval.init(-floatMax, floatMax).width()` came back
//!     as anything at all.
//!   * LAWS. `contains`, `overlaps`, `subsetOf` and the six certain
//!     comparisons return a bool, so there is no image to compare against.
//!     They are checked against each other and against the set operations,
//!     which do have an oracle. A one-line restatement of a definition would
//!     be a tautology, so the one line is stated for the record and the LAWS
//!     are what the sweep is for: a `lt` that answered for a straddling
//!     operand passes against itself and fails here.
//!
//! Every oracle added since was checked to BITE before it was trusted,
//! by mutating it to be stricter than the truth and watching the sweep go
//! red. Those numbers are what make the layers above checkable rather
//! than merely present: tightening `sqrt` by 3 ULP fails 1,739 of 7,314;
//! tightening `cbrt` by 2 ULP fails 3,698 of 7,251 and by 3 ULP fails
//! 6,895; forbidding the whole line where a zero-touching divisor gives
//! it fails exactly the 2,040 `div` cases and the 2,163 `recip` cases
//! this file used to skip; letting `lt` claim strict order for an operand
//! within 1.0 of the other fails 1,524; and dropping the third element
//! of `hullOf` fails 4,231.
//!
//! The frontier references are held to that standard from the other side,
//! because a directed sweep has no stream to mutate: each one is pinned
//! against the answer a WRONG reference would clear. `the exact-sum
//! comparator rejects the two inward roundings an f128 sum hides` is that
//! test for the four sum references, and it names the two regressions
//! this file's own header used to get wrong — `[floatMax,floatMax]` for
//! `floatMax - 3`, and the unstepped `1e300` for `1e300 - 1e-300`. Both are
//! cleared by an `f128` reference and refused by a residual one, which is
//! the whole difference between them.
//!
//! The bounded-scale reference is pinned from the same side, by `the exact
//! bounded-scale comparator rejects the inward bounds an f128 midpoint
//! clears`. That one is not a mutation but a named set of inward bounds: the
//! centre of `[min_subnormal, floatMax]` at a factor of zero is
//! `floatMax/2 + min_subnormal/2`, and the rounded `f128` midpoint is
//! `floatMax/2`, which is a real INSIDE that image and would be cleared by
//! any reference that formed the midpoint first. The same guard pins the
//! exact-zero expansion at `[-1,1]`, a computed overflow at
//! `[-floatMax, floatMax]` scaled by two, and the infinite factor, where
//! only the whole line encloses a box that has width.
//!
//! What is NOT in the file matters as much as what is. `exp`, `log`,
//! `sin`, `cos` and `tan` have no containment oracle here, and the reason
//! is measured rather than assumed: Zig 0.16's `f128` transcendentals are
//! NOT wider than `f64`. Over 20,000 draws, `@exp(f128)`, `@log(f128)`
//! and `@sqrt(f128)` rounded to `f64` equalled the `f64` evaluation on
//! 20,000 of 20,000, and `@sin`, `@cos` and `@tan` on all but a few dozen.
//! The `f128` results are the `f64` results widened: `@exp(f128(1))` is
//! 2.718281828459045534884808148490265 where e is
//! 2.718281828459045235360287471352662, an error of 1.1e-16 relative — a
//! sixth of the 6.7e-16 that a three-ULP step on each side absorbs, and the
//! same order as the error the widening exists to cover. An oracle built
//! on them would be the `f64` primitive restated and would agree with
//! whatever the primitive did, which is the exact mistake the paragraph
//! above this one names. A real oracle for those five needs a certified
//! primitive: a Taylor series with a stated remainder, over a multi-limb
//! argument reduction, accurate to better than 1e-20 relative so that the
//! margin is four orders of magnitude rather than one. That is a separate
//! piece of work and not a paragraph of this one, so it is left for a
//! later pass rather than faked here. `tanh` is the one that HAS got an
//! oracle, and it took a different road to the same place: a `tanh` series
//! is not needed anywhere, because the exponential identity carries the
//! whole real line once the cancellation near zero is paid for, which is
//! what the reference below does and what none of the five above can.
//! While the other five are missing, the package's three-ULP margin for
//! the elementary functions rests on the measured table in
//! `interval_ext.zig` and on nothing else, which is worth saying out loud
//! rather than leaving implied.
//!
//! One rule earned here, recorded so it survives: a case whose
//! precondition is a SPECIFIC overflow or a SPECIFIC underflow has to be
//! seeded through the magnitude table, because a random draw over any
//! table will miss it. `scale([-floatMax, floatMax], 0.0)` returns a NaN
//! interval — the width is `+inf` and `inf * 0` is NaN — and this file
//! reported it as sound for as long as the table drew `.float_max`
//! unsigned, because then no box could span both signs at the frontier
//! and `hi - lo` could never overflow. The `full_range` class is the
//! fix; more samples would not have been.
//!
//! A second rule, and it is the reason the frontier sweep below exists. The
//! random layer screens every non-finite operand out before the oracle sees
//! it, so 35 sweeps of 8,000 cases each judged the library on finite inputs
//! and not one of them reached an infinity — and the only infinity coverage
//! the tree had was `lo <= hi`, which asks nothing of the answer. The sweep
//! is therefore directed rather than drawn: sixteen named shapes — six rays
//! and half-lines, the whole line, SEVEN finite boxes beside them, and two
//! pairs the constructor refuses — against each other, seven scalars for the
//! operations that take one, and a reference for each built from what an
//! infinite endpoint stands for rather than from the corner the library
//! computed.
//!
//! What an infinite endpoint STANDS FOR is not a question this file decides
//! any more. The approved contract fixes it: a canonical `lo` is never
//! `+inf` and a canonical `hi` is never `-inf`, so `init(+inf,+inf)` is the
//! closed overflow ray `[floatMax,+inf]` and its mirror `[-inf,-floatMax]`,
//! a finite bound is an attained real, and an infinite one is a direction
//! the set runs off in. Every frontier reference below is the image of that
//! set, formed from the closed end of each ray together with the directions
//! the image itself runs off in. THIRTEEN operations are judged this way —
//! `add`, `sub`, `translate`, `expand`, `neg`, `recip`, `mul`, `div`,
//! `abs`, `sqr`, `scale`, `hull` and `intersect` — and none of them is
//! withheld. A withheld row is a row whose expected answer this file had
//! to choose for itself, and a reference chosen by the judge is not a
//! reference: that is what the six removed ones were, and the two readings
//! of an infinite endpoint disagreed about exactly those six operations.
//!
//! Two consequences of the fixed reading are worth stating before the code,
//! because both were got wrong the first time. A POSITIVE ray minus a
//! NEGATIVE one cannot cancel: `[floatMax,+inf] - [-inf,-floatMax]` runs
//! from `2*floatMax` upward on the low side and to `-inf` on the high one,
//! and the old witness called the whole line with a lower bound of zero.
//! The SAME ray is the one that cancels, and that is the row that used to
//! abort. `src/` now answers it with the whole line, which is its exact
//! image, so the row is judged like every other one instead of being
//! excused.
//! And `neg` of a canonical ray is the ordinary reflected ray —
//! `neg([floatMax,+inf])` is `[-inf,-floatMax]` — so it is judged by the
//! same reflected containment as every other shape and not by a special
//! case written for the degenerate point the constructor used to hand
//! back.
//!
//! One thing about the streams changed with it, and it is worth recording
//! because it invalidates numbers rather than adding any. A stream used to
//! be seeded by the operation's POSITION in `Op`, so inserting one operation
//! re-randomised every stream after it and every count a previous run had
//! printed stopped being about the same cases. Each seed now comes from a
//! hash of the operation's LABEL, and the counts in this file's own header
//! (`cbrt` 7,251 and `sqrt` 7,314) are the pre-change ones: they were taken
//! with the position-seeded streams and are kept as the record of what those
//! runs measured, not as a claim about what the next run will print.

const std = @import("std");
const interval = @import("interval");
const Interval = interval.Interval;

/// Seed for every fuzz stream. Fixed, so a failure reproduces exactly and a
/// pass means something; `std.Random.DefaultPrng` rather than the system
/// source, which would make the suite meaningless.
const seed: u64 = 0xDEAD_BEEF_CAFE_F00D;

/// The stream of one operation, keyed on its LABEL rather than on its
/// position in `Op`.
///
/// FNV-1a over the name, written out here rather than taken from
/// `std.hash` because this file pins its numbers: a hash whose internals the
/// standard library is free to change would move every stream again, which
/// is the same fragility one layer down. 64 bits of FNV-1a keeps these
/// labels apart with nothing to spare and the arithmetic is four lines.
fn labelSeed(label: []const u8) u64 {
    var h: u64 = 0xcbf2_9ce4_8422_2325;
    for (label) |c| {
        h ^= c;
        h *%= 0x0000_0100_0000_01b3;
    }
    return h;
}

/// The seed of one operation's fuzz stream.
///
/// This is the whole of the fix for a suite that used to derive its streams
/// from `@intFromEnum(op)`. Nothing about a stream changes from having
/// another operation inserted at the front of `Op`, which is the property
/// that a count printed by one run keeps meaning against the next: adding a
/// case must change the case, and adding an operation must not.
fn streamSeed(op: Op) u64 {
    return seed ^ labelSeed(op.label());
}

/// Cases per fuzzed operation.
const fuzz_cases: usize = 8000;

/// How many individual failures one fuzz prints in full. The count is
/// always reported exactly; this only bounds the detail so a sweep with a
/// large blast radius stays readable.
const max_detail: usize = 12;

// ---------------------------------------------------------------------------
// Exact layer
// ---------------------------------------------------------------------------

const inf128 = std.math.inf(f128);
const neg_inf128 = -inf128;
const inf64 = std.math.inf(f64);
const neg_inf64 = -inf64;

/// Exact widening of an `f64` to `f128`. Every `f64` is a `f128`, so this
/// loses nothing.
inline fn ex(x: f64) f128 {
    return @as(f128, x);
}

/// The exact image of an operation over a box of `f64` endpoints, held in
/// `f128`. Both bounds are the true mathematical extrema, not roundings of
/// them.
///
/// The two flags say that the extremum is a real PAST the end of the `f64`
/// range rather than an infinity, which is a different statement and is
/// stated differently. Every operand drawn here is finite and every map
/// under test that is not a pole is continuous, so its image is bounded —
/// but a bound like `exp(1e300)` is finite and is further out than any
/// `f64`, and reading it as +inf would demand a returned bound of -inf,
/// which excludes it. The flag moves the comparison to the frontier
/// instead, where the real answer and a saturated one agree.
const Range = struct {
    lo: f128,
    hi: f128,
    lo_beyond: bool = false,
    hi_beyond: bool = false,
};

/// True when `glo` is an acceptable lower bound for the exact minimum
/// `elo`.
///
/// The infinities are handled on their own terms rather than left to the
/// ordering, because the ordering alone is not the rule. An infinite
/// returned bound is a legitimate enclosure of any finite exact extremum
/// and must not be reported as a failure. An exact extremum of -inf is a
/// different matter: no `f64` below it exists, so only -inf itself can
/// bound it, and a finite bound there is a miss.
fn lowerOk(elo: f128, glo: f64) bool {
    if (std.math.isNan(elo) or std.math.isNan(glo)) return false;
    if (elo == neg_inf128) return glo == neg_inf64;
    if (glo == neg_inf64) return true;
    return ex(glo) <= elo;
}

/// The mirror of `lowerOk` for the upper bound.
fn upperOk(ehi: f128, ghi: f64) bool {
    if (std.math.isNan(ehi) or std.math.isNan(ghi)) return false;
    if (ehi == inf128) return ghi == inf64;
    if (ghi == inf64) return true;
    return ex(ghi) >= ehi;
}

/// The exact sum of two finite `f64` values, held as an `f128` head and
/// the residual that makes the PAIR the true sum.
///
/// The true sum is not an `f128` and no amount of widening makes it one:
/// `floatMax - 3` is more than a thousand significand bits wide and
/// `f128` carries 113, so it rounds to `floatMax`. `s` is that rounding
/// and `err` is what the rounding dropped, so `s + err` is the true sum as
/// REALS even where the pair cannot be collapsed into one number again.
/// The error-free transformation below is the standard one, and the
/// residual is exact rather than nearly so: `s - a` is exact whenever
/// `s = fl(a + b)`, the two roundoff terms are therefore exact, and
/// neither can be lost again because a nonzero residual of a sum of two
/// `f64`s is a multiple of 2^-1074, which `f128` holds down to 2^-16494.
const TwoSum = struct {
    s: f128,
    err: f128,
};

/// The same error-free transformation on two `f128` values, which is what
/// the expansion below grows with.
///
/// `TwoSum` rather than `FastTwoSum`, on purpose. The fast one is exact only
/// where the caller has already established that its two operands are ordered
/// by magnitude, and nothing here orders the five terms of a `scale`
/// extremum on anybody's behalf: `A`, `B`, `G*A` and `-G*B` arrive in an
/// order this reference does not choose. The generic transformation costs
/// three more subtractions and asks nothing of its operands.
///
/// The error-free property is a claim about a FLOATING-POINT MODE and not
/// about this code alone, so the mode is SET here rather than assumed:
/// `@setFloatMode(.strict)` below, IEEE 754 round-to-nearest-even, no
/// contraction and no excess intermediate precision. Under any other mode
/// the residual is not the residual the sum lost, and every comparison in
/// this file that leans on one inherits the doubt. Flush-to-zero and
/// denormals-are-zero are host flags rather than language modes and cannot
/// be set from here; the lattice argument in `ScaleBound` is what keeps these
/// operands clear of an `f128` subnormal in the first place, so the
/// requirement bites at the extremes rather than in the middle.
fn twoSumExact(a: f128, b: f128) TwoSum {
    @setFloatMode(.strict);
    const s = a + b;
    const b_virtual = s - a;
    const a_virtual = s - b_virtual;
    return .{ .s = s, .err = (a - a_virtual) + (b - b_virtual) };
}

fn twoSum(a: f64, b: f64) TwoSum {
    return twoSumExact(ex(a), ex(b));
}

/// Where the `f64` `g` stands against the exact real sum of the finite
/// `f64`s `a` and `b`.
///
/// The comparison never forms the sum, because there is no `f128` form of
/// it. It compares `g` with `s` instead, and uses the residual only where
/// the two are EQUAL, which is the one place the rounding of `s` can change
/// the answer. The shortcut is sound because `s` and any `f64` below it sit
/// on grids at least as fine as `s`'s own: `g < s` makes `s - g` a nonzero
/// multiple of `ulp128(s)`, which is at least twice the magnitude of the
/// residual, so `g` is strictly below the true sum. Symmetrically for
/// `g > s`. Only `g == s` has to consult `err`, and there the question is
/// exactly its sign.
///
/// `g` at an infinity is handled on its own terms rather than through the
/// ordering, for the reason `lowerOk` gives: the true sum of two finite
/// `f64`s is a finite real, so `-inf` is below it and `+inf` is above it.
/// A NaN bound is neither below nor above anything and gets its own arm, so
/// no comparison against an integer can let it through — which is the bug
/// a sentinel value invites and an enum cannot express.
const SumOrder = enum { below, equal, above, unordered };

fn compareToSum(g: f64, a: f64, b: f64) SumOrder {
    if (std.math.isNan(g)) return .unordered;
    if (g == inf64) return .above;
    if (g == neg_inf64) return .below;
    const t = twoSum(a, b);
    const G = ex(g);
    if (G < t.s) return .below;
    if (G > t.s) return .above;
    if (t.err > 0.0) return .below;
    if (t.err < 0.0) return .above;
    return .equal;
}

/// True when the `f64` `g` is at or below the exact sum of `a` and `b`.
fn sumLeq(g: f64, a: f64, b: f64) bool {
    return switch (compareToSum(g, a, b)) {
        .below, .equal => true,
        .above, .unordered => false,
    };
}

/// True when the `f64` `g` is at or above the exact sum of `a` and `b`.
fn sumGeq(g: f64, a: f64, b: f64) bool {
    return switch (compareToSum(g, a, b)) {
        .above, .equal => true,
        .below, .unordered => false,
    };
}

// ---------------------------------------------------------------------------
// The exact sum of five terms, held as an expansion
// ---------------------------------------------------------------------------

/// An EXACT `f128` expansion of a sum, held as one fixed array of five slots
/// with no allocation, no sentinel and no sort.
///
/// The five terms a `scale` extremum needs are the original `f64` endpoints,
/// two products of original `f64` values, and one power-of-two scaling of a
/// returned bound. Each is a single exact `f128`, and their SUM is a real no
/// `f128` can name. This holds that sum as an expansion instead: components
/// that do not overlap one another, in order of increasing magnitude, whose
/// value together is the exact total.
///
/// The construction is Shewchuk's `grow_expansion_zeroelim`, and what the
/// theorem behind it says is written out here because the sign rule below
/// stands on it and not on anything observed in this file. Fold an ARBITRARY
/// new value into an expansion that is non-overlapping and ascending; use
/// the generic error-free `TwoSum`, which places no condition on the new
/// value; drop every zero residual; and the result is again non-overlapping
/// and ascending with the exact sum as its value. The magnitude condition
/// `|b| <= |e[last]|` that one reaches for here belongs to `FastTwoSum` and
/// the fast expansion routines and not to this one, and an earlier version
/// of this comment attributed it to this one.
///
/// Two consequences are all that is used. The exactness holds in any order,
/// so the five terms go in as the formula writes them and nothing reorders
/// them. And because the components do not overlap and ascend, each is at
/// most half an ulp of the one above it, so the tail sums to strictly LESS
/// than the last component and the sign of the total is the sign of that one;
/// an empty expansion is a total of exactly zero rather than an absent one.
///
/// Capacity is exactly five and exactly tight: the loop leaves at most one
/// residual per existing component and the head appends one more, so the
/// length after the k-th insertion is at most k, five terms cannot reach a
/// sixth slot, and the largest index ever written is four. Zero elimination
/// is what keeps it there, and a zero residual is dropped by `!= 0.0` and
/// never by `> 0.0` — the latter would let a `-0.0` through and put a zero
/// in the leading position. Every read is of `e[0..n]`: the array is
/// `undefined` past the length, and a slot that was never written is not
/// merely pointless to read but undefined.
const Expansion = struct {
    /// Five terms, five slots. A sixth would only ever be a slot nothing in
    /// this file fills.
    const cap: usize = 5;

    /// The components, smallest first. Only the first `n` are meaningful,
    /// and `n` is the authority on which those are: an unwritten slot is
    /// `undefined` and never zero, so no stale value can be read as a term.
    e: [cap]f128 = undefined,
    n: usize = 0,

    /// The exact sum of this expansion and one more exact term, folded in
    /// place. `term` may be any value this fold can hold: the construction
    /// asks nothing of its magnitude or its position, which is the property
    /// the comment above leans on.
    ///
    /// The incoming term is the running head, folded in from the smallest
    /// stored component upwards. Each nonzero residual is written back into
    /// the slot it was read from, so the write index never runs ahead of the
    /// read index and the array being walked is never extended: a residual
    /// can only land on a component the walk has already copied, and one
    /// buffer is therefore enough — no second array is needed for safety.
    /// The head is appended once, after the walk and under an assert, and only
    /// when it is nonzero.
    ///
    /// A pointer rather than a by-value receiver because the payload is
    /// eighty bytes and this fold is the hot path of every five-term verdict
    /// below; a receiver by value would copy the whole array once per term.
    fn add(x: *Expansion, term: f128) void {
        var q = term;
        var m: usize = 0;
        for (x.e[0..x.n], 0..) |c, i| {
            const folded = twoSumExact(q, c);
            q = folded.s;
            // `!= 0.0` and never `> 0.0`: the second form would store a
            // `-0.0` and put a zero in a component that carries the sign.
            if (folded.err == 0.0) continue;
            std.debug.assert(m <= i);
            x.e[m] = folded.err;
            m += 1;
        }
        if (q != 0.0) {
            std.debug.assert(m < cap);
            x.e[m] = q;
            m += 1;
        }
        x.n = m;
    }

    /// The sign of the exact total: the sign of the LAST component, and zero
    /// for an empty expansion, which is a total of exactly zero rather than an
    /// absent one. The theorem that licenses reading the leading component is
    /// the one the comment above states, so it is not restated here; the three
    /// arms cover the leading component either way, and by construction it is
    /// never a zero. `const` because a verdict reads the total and does not
    /// have the business changing it.
    fn sign(x: *const Expansion) i32 {
        if (x.n == 0) return 0;
        const head = x.e[x.n - 1];
        if (head > 0.0) return 1;
        if (head < 0.0) return -1;
        return 0;
    }
};

/// The exact image of an operation whose two endpoints are each the sum of
/// two `f64` values, held as the OPERANDS rather than as a value.
///
/// The operands are the reference and not a convenience: they are `f64`, so
/// they are exact, and the comparison against them goes through
/// `sumLeq`/`sumGeq`. Nothing here is a number that could be rounded, which
/// is the whole difference between this and a `Range` built from an `f128`
/// sum.
const SumBound = struct {
    /// The two `f64` whose sum is the true MINIMUM of the image.
    alo: f64,
    blo: f64,
    /// The two `f64` whose sum is the true MAXIMUM of the image.
    ahi: f64,
    bhi: f64,

    fn lowerOk(s: SumBound, glo: f64) bool {
        return sumLeq(glo, s.alo, s.blo);
    }

    fn upperOk(s: SumBound, ghi: f64) bool {
        return sumGeq(ghi, s.ahi, s.bhi);
    }

    fn holds(s: SumBound, got: Interval) bool {
        return s.lowerOk(got.lo) and s.upperOk(got.hi);
    }
};

/// Containment of an exact extremum that lies past the end of the `f64`
/// range. The extremum is a real, so an `f64` at or inside the frontier in
/// that direction is at or below it and bounds it; an infinity pointing
/// the other way is the one answer that does not.
fn lowerOkBeyond(glo: f64) bool {
    if (std.math.isNan(glo)) return false;
    return glo < inf64;
}

/// The mirror of `lowerOkBeyond` for an extremum below the range.
fn upperOkBeyond(ghi: f64) bool {
    if (std.math.isNan(ghi)) return false;
    return ghi > neg_inf64;
}

/// The lower-bound test for a `Range`, honouring the `lo_beyond` flag.
fn loEncloses(r: Range, glo: f64) bool {
    return if (r.lo_beyond) lowerOkBeyond(glo) else lowerOk(r.lo, glo);
}

/// The upper-bound test for a `Range`, honouring the `hi_beyond` flag.
fn hiEncloses(r: Range, ghi: f64) bool {
    return if (r.hi_beyond) upperOkBeyond(ghi) else upperOk(r.hi, ghi);
}

/// The margin `scalarOk` allows, and why it is one ULP and not a
/// tolerance chosen to let something through: the reference is not always
/// exact even in `f128`, because the difference of two `f64` can need more
/// than 113 significand bits. A reference subtraction rounds, and
/// rounding a rounded value to `f64` can land one ULP off the `f64`
/// rounding of the same exact quantity. One ULP is the whole of that
/// double rounding.
const scalar_slack: f128 = 0x1p-52;

/// Containment of a returned `f64` VALUE against a reference formed in
/// `f128`, to within that one ULP.
fn scalarOk(got: f64, want: f128) bool {
    if (std.math.isNan(got) or std.math.isNan(want)) return false;
    if (want == 0.0) return got == 0.0;
    if (std.math.isInf(want)) return ex(got) == want;
    const g = ex(got);
    if (std.math.isInf(g)) return false;
    return @abs(g - want) <= @abs(want) * scalar_slack + ex(min_subnormal);
}

/// The point at which a correctly rounded `f64` operation gives up and
/// returns an infinity: 2^1024 - 2^970, the midpoint between floatMax and
/// the binade above it. Below it the answer is a finite `f64`; at or above it
/// round-to-nearest gives +inf.
const overflow_threshold: f128 = 0x1p1024 - 0x1p970;

/// The exact width of `a`, as a VALUE and not as a bound, with the
/// saturation that a value needs at the top of the range.
///
/// `width` returns `hi - lo` and nothing else: there is no outward step to
/// take, and `+inf` is not a lost width but the value the format's own
/// subtraction produces there, so it IS the reference rather than something
/// the reference has to be widened to. `Interval.init(-floatMax, floatMax)`
/// has the real width 3.59e308, which no `f64` holds, and the correctly
/// rounded difference of the two endpoints is +inf; asking for a bound of
/// the real instead would ask for a value the format cannot produce, and
/// `scalarOk` would then report the only answer it has as unsound.
fn exactWidth(a: Interval) f128 {
    const d = ex(a.hi) - ex(a.lo);
    return if (d >= overflow_threshold) inf128 else d;
}

/// The exact distance from `x` to `a`: zero inside, and the difference to
/// the nearer endpoint outside it. The same saturation as `exactWidth`, for
/// the same reason: a distance is a value.
fn exactDistanceTo(a: Interval, x: f64) f128 {
    const d = if (ex(x) < ex(a.lo))
        ex(a.lo) - ex(x)
    else if (ex(x) > ex(a.hi))
        ex(x) - ex(a.hi)
    else
        0.0;
    return if (d >= overflow_threshold) inf128 else d;
}

/// Half an ULP of `v`: the margin IEEE 754 permits between a correctly
/// rounded square root and the real one. Taken from the exponent field
/// rather than from a logarithm, because a logarithm cannot tell which
/// side of a power of two it is on and the two sides carry different
/// grids. A subnormal answer has the subnormal grid, whose half-step is
/// half the smallest positive `f64`, and both are clamped there.
fn halfUlp(v: f64) f64 {
    if (v == 0.0) return 0.0;
    const bits: u64 = @bitCast(@abs(v));
    const e: u32 = @intCast((bits >> 52) & 0x7ff);
    // Below the smallest normal binade the grid is the subnormal one and
    // its half-step is half a subnormal, which rounds to nothing; the
    // clamp is there so the answer is a positive step at every magnitude.
    if (e <= 1075) return 0x1p-1075;
    // e - 1076 is in [0, 970] here, so 2^(e - 1076) is a normal power of
    // two and its pattern is the biased exponent on its own.
    const k: u64 = @as(u64, e) - 1076 + 1023;
    return @bitCast(k << 52);
}

/// Exact image of `a + b`. Addition rises in both operands, so the minimum
/// is the sum of the two lower ends and the maximum the sum of the two
/// upper ones. Both are held as their two `f64` operands rather than as an
/// `f128` value, because that value is not the sum: see `SumBound`.
fn exactAdd(a: Interval, b: Interval) SumBound {
    return .{ .alo = a.lo, .blo = b.lo, .ahi = a.hi, .bhi = b.hi };
}

/// Exact image of `a - b`. Subtraction rises in the first operand and
/// falls in the second, so the pairing crosses: the minimum takes `a.lo`
/// against `b.hi` and the maximum takes `a.hi` against `b.lo`. Pairing
/// low with low here would understate the image, so the crossing is the
/// whole point of the routine. The second operand is negated rather than
/// subtracted, because an `f64` negation is exact and a subtraction is
/// the sum the residual comparator is there to judge.
fn exactSub(a: Interval, b: Interval) SumBound {
    return .{ .alo = a.lo, .blo = -b.hi, .ahi = a.hi, .bhi = -b.lo };
}

/// Exact image of a shift by `delta`, the same monotonicity argument as
/// `add` with the second operand pinned to the point `delta`.
fn exactTranslate(a: Interval, delta: f64) SumBound {
    return .{ .alo = a.lo, .blo = delta, .ahi = a.hi, .bhi = delta };
}

/// Exact image of a widening by `margin`, valid under the documented
/// precondition `margin >= -(hi - lo) / 2`. The low end is `a.lo - margin`
/// and the high one `a.hi + margin`, so the margin enters the low corner
/// negated for the same reason it does in `exactSub`.
fn exactExpand(a: Interval, margin: f64) SumBound {
    return .{ .alo = a.lo, .blo = -margin, .ahi = a.hi, .bhi = margin };
}

/// Whether `expand` would ACCEPT `margin` on the finite box `[lo, hi]`.
///
/// The documented precondition is `margin >= -(hi - lo) / 2`, and that is
/// the same statement as
///
///     hi - lo + 2 * margin >= 0
///
/// which is the direction the predicate reads. All three terms are single
/// exact `f128` values — the two endpoints widened, and a power-of-two
/// scaling of a `f64`, which shifts an exponent and not a significand — so
/// the sign is read off a three-term expansion and the width is never
/// formed at all.
///
/// Not forming it is the whole point, and a rounded width is not merely
/// imprecise here: on `[min_subnormal, floatMax]` the true width is
/// `floatMax - min_subnormal`, more than a thousand significand bits wide,
/// and `f128` carries 113, so the difference rounds to `floatMax` and the
/// half-width rounds to `floatMax / 2`. That number sits BELOW the true
/// half-width `floatMax / 2 + min_subnormal / 2`, so a rounded reference
/// refuses the one admissible margin just above the boundary and admits the
/// one just below it. The boundary falls between two CONSECUTIVE `f64`
/// values, and no rounded number holds them apart.
///
/// Two cases fall out of the same three terms rather than being
/// special-cased: a margin at or above zero is admissible at every width,
/// and a box with no width at all admits no negative margin whatsoever,
/// because the total is then exactly `2 * margin`.
///
/// An infinite margin is decided on its own terms before the expansion is
/// grown, for the reason `lowerOk` gives: it is not a term the fold may
/// hold, and folding one in yields a NaN rather than a total — `TwoSum(+inf,
/// x)` has `s - a = inf - inf`, so the residual comes back NaN, the sign is
/// read off a garbage component, and the verdict is whatever that component
/// happens to compare as. `+inf` is a widening by every positive real, so no
/// box refuses it; `-inf` is the ray of margins at or below -floatMax, which
/// the contract refuses for EVERY bounded box, `[-floatMax, floatMax]`
/// included, and `Row.expand_negative_ray` is where that one is named on the
/// report rather than folded in here. A NaN is not a margin at all.
///
/// `lo` and `hi` are finite at both callers: the fuzz screen has already
/// returned on a non-finite endpoint, and `Shape.admitsMargin` is only
/// reached for a bounded shape, so `closedEnd` has nothing to close.
fn marginAdmissible(lo: f64, hi: f64, margin: f64) bool {
    if (std.math.isNan(margin)) return false;
    if (margin == inf64) return true;
    if (margin == neg_inf64) return false;
    var total = Expansion{};
    total.add(ex(hi));
    total.add(-ex(lo));
    total.add(2.0 * ex(margin));
    return total.sign() >= 0;
}

/// Exact image of `a * b`. The extreme products of two intervals are
/// always at a pair of endpoints, so the range is the min and the max over
/// the four corner products — each computed in `f128`, and each therefore
/// the true product rather than a rounding of it. This is the step the
/// existing suite does not take: it reads the `f64` corners back out of
/// the implementation and compares them with themselves.
fn exactMul(a: Interval, b: Interval) Range {
    const p1 = ex(a.lo) * ex(b.lo);
    const p2 = ex(a.lo) * ex(b.hi);
    const p3 = ex(a.hi) * ex(b.lo);
    const p4 = ex(a.hi) * ex(b.hi);
    return .{
        .lo = @min(@min(p1, p2), @min(p3, p4)),
        .hi = @max(@max(p1, p2), @max(p3, p4)),
    };
}

/// The exact image of `scale` on a BOUNDED box, held as the TERMS of the
/// comparison rather than as a value.
///
/// `scale` is the affine map `x -> m + |factor| * (x - m)`, so for the
/// ORIGINAL `f64` endpoints `A = lo`, `B = hi` and the original magnitude
/// `G = |factor|` the true image of `[A, B]` is
///
///     L = (A + B + G*A - G*B) / 2
///     H = (A + B - G*A + G*B) / 2
///
/// and neither of those is formed, because the division by two is what makes
/// them inaccessible: `L` is a sixth term and not a fifth, and there is no
/// rounding of `f128` that hands it over. What is formed instead are the two
/// SIGNED DIFFERENCES that carry the same question without it:
///
///     glo <= L   exactly when   A + B + G*A - G*B - 2*glo  >= 0
///     ghi >= H   exactly when   A + B - G*A + G*B - 2*ghi  <= 0
///
/// and every one of those five terms is a single exact `f128`:
///
///   * `A` and `B` are the ORIGINAL endpoints, widened. Nothing is rounded
///     on the way in, and no midpoint and no half-width is formed first:
///     those are the two quantities whose rounding is the whole defect this
///     reference exists to catch.
///   * `G*A` and `G*B` are products of two `f64` values, needing 53 + 53 =
///     106 significand bits against the 113 `f128` carries, so they are the
///     true products and not roundings of them.
///   * `2*g` is a power-of-two scaling of an `f64` and is EXACT: fifty-three
///     significand bits are still fifty-three after the exponent moves.
///     `2 * floatMax` is the case that looks like an overflow and is not —
///     an earlier sentence in this file said that both it and
///     `floatMax - 3` were reals `f128` cannot name, and the first of those
///     two claims was wrong. `floatMax - 3` is the one that needs more than
///     113 bits, and it is the reason this type holds operands rather than
///     values.
///
/// No `f128` over- or underflow is reachable, so the round-to-nearest
/// assumption the expansion's `TwoSum` rests on holds with no excluded regime
/// and no fallback to reach for, and the chain is worth spelling out rather
/// than asserting. Every term is a multiple of 2^-2148 — the smallest product
/// of two `f64`s, and a coarser multiple of it for the endpoints and for
/// `2*g`. The rounded head of a `TwoSum` is a lattice multiple again, because
/// `f128` has no subnormals in play at these magnitudes, and the residual is
/// exact, so it is a lattice multiple too. A NONZERO residual is therefore at
/// least 2^-2148 in magnitude, and the total of five terms stays below
/// 2^2051, while `f128` normals run from 2^-16382 to 2^16383. That floor and
/// that ceiling are the whole of the exclusion.
const ScaleBound = struct {
    /// The low end of the box, as the caller wrote it.
    lo: f64,
    /// The high end, likewise.
    hi: f64,
    /// `|factor|`, as the caller wrote it.
    mag: f64,

    /// True when `glo` is at or below the true minimum.
    fn lowerOk(s: ScaleBound, glo: f64) bool {
        // The infinities are decided before the expansion is grown, for the
        // reason the file-level `lowerOk` gives: the true minimum here is a
        // finite real, so -inf is below it, +inf is above it, and a NaN bound
        // is no bound at all.
        if (std.math.isNan(glo)) return false;
        if (glo == neg_inf64) return true;
        if (glo == inf64) return false;
        return expandLower(s, glo);
    }

    /// The mirror of `lowerOk` for the high end.
    fn upperOk(s: ScaleBound, ghi: f64) bool {
        if (std.math.isNan(ghi)) return false;
        if (ghi == inf64) return true;
        if (ghi == neg_inf64) return false;
        return expandUpper(s, ghi);
    }

    /// The sign of `A + B + G*A - G*B - 2*glo`, which is non-negative exactly
    /// when `glo` is at or below the true minimum. The five terms are the ones
    /// `ScaleBound`'s comment names, folded in as the formula writes them —
    /// the expansion asks nothing of their order.
    fn expandLower(s: ScaleBound, glo: f64) bool {
        var total = Expansion{};
        total.add(ex(s.lo));
        total.add(ex(s.hi));
        total.add(ex(s.mag) * ex(s.lo));
        total.add(-(ex(s.mag) * ex(s.hi)));
        total.add(-2.0 * ex(glo));
        return total.sign() >= 0;
    }

    /// The mirror of `expandLower` for the high end, where the sign has to be
    /// non-positive.
    fn expandUpper(s: ScaleBound, ghi: f64) bool {
        var total = Expansion{};
        total.add(ex(s.lo));
        total.add(ex(s.hi));
        total.add(-(ex(s.mag) * ex(s.lo)));
        total.add(ex(s.mag) * ex(s.hi));
        total.add(-2.0 * ex(ghi));
        return total.sign() <= 0;
    }

    fn holds(s: ScaleBound, got: Interval) bool {
        if (got.lo > got.hi) return false;
        return s.lowerOk(got.lo) and s.upperOk(got.hi);
    }
};

/// `scale` judged against that image for a BOUNDED operand, with the
/// infinite factor taken apart rather than multiplied in.
///
/// A finite factor is the five-term comparison above. An INFINITE factor is
/// not a number the expansion may hold: it stands for every finite magnitude
/// at or above floatMax, and the union of the images over all of them is the
/// whole line for any box with width, because the half-width is
/// proportional to the magnitude and leaves in both directions at once. A
/// box of NO width is the exception, and it is a fact about the map rather
/// than a convenience: the half-width is zero at every magnitude, so the
/// image is the single point the box already was and no union widens it. The
/// factor is never multiplied into the finite expansion in either arm.
///
/// A NaN factor is refused, and it is the operation's own precondition doing
/// it: `scale` validates the factor through the constructor before it
/// computes anything, and there is no image of a scalar that is not a number.
fn boundedScaleHolds(a: Interval, factor: f64, got: Interval) bool {
    if (std.math.isNan(factor)) return false;
    if (std.math.isNan(got.lo) or std.math.isNan(got.hi)) return false;
    if (got.lo > got.hi) return false;
    if (@abs(factor) == inf64) {
        if (a.lo == a.hi) return (ScaleBound{ .lo = a.lo, .hi = a.hi, .mag = 0.0 }).holds(got);
        return got.lo == neg_inf64 and got.hi == inf64;
    }
    return (ScaleBound{ .lo = a.lo, .hi = a.hi, .mag = @abs(factor) }).holds(got);
}

/// Exact image of `abs`. The magnitude map is piecewise linear with the
/// break at zero, so the extrema are at the endpoints unless the interval
/// straddles zero, where a point of it maps to zero and the image starts
/// there. A magnitude is a negation of an endpoint or the endpoint itself,
/// never a value `f64` lost, which is why no `f128` is needed for it.
fn exactAbs(a: Interval) Range {
    const p = @abs(ex(a.lo));
    const q = @abs(ex(a.hi));
    return .{
        .lo = if (a.lo <= 0.0 and 0.0 <= a.hi) 0.0 else @min(p, q),
        .hi = @max(p, q),
    };
}

/// Exact image of `sqr`. The two squares of `f64` endpoints need 106
/// significand bits, which `f128` carries, so these are the true squares
/// and not roundings of them. The branch is the whole reference: squaring
/// is not monotone across zero, and on an interval that straddles it the
/// minimum of the two squares is below every value a square can take.
fn exactSqr(a: Interval) Range {
    const p = ex(a.lo) * ex(a.lo);
    const q = ex(a.hi) * ex(a.hi);
    if (a.lo <= 0.0 and 0.0 <= a.hi) return .{ .lo = 0.0, .hi = @max(p, q) };
    return .{ .lo = @min(p, q), .hi = @max(p, q) };
}

/// Exact image of `neg`: the endpoints swap, and IEEE 754 negation is
/// exact, so this reference is the answer bit for bit.
fn exactNeg(a: Interval) Range {
    return .{ .lo = -ex(a.hi), .hi = -ex(a.lo) };
}

/// Exact image of the hull of two intervals. A min and a max of two `f64`
/// are selections, not computations, so this reference is an `f64` pair
/// with no rounding anywhere in it and the only thing to check is that
/// the returned pair is it.
fn exactHull(a: Interval, b: Interval) Range {
    return .{ .lo = @min(ex(a.lo), ex(b.lo)), .hi = @max(ex(a.hi), ex(b.hi)) };
}

/// Exact image of the common part of two intervals, or null when the two
/// are disjoint. The null is the reference as much as the pair is: it is
/// the claim that no interval bounds the shared part at all, and a sweep
/// that let a null through where a pair was due would be checking
/// nothing.
fn exactIntersect(a: Interval, b: Interval) ?Range {
    const lo = @max(ex(a.lo), ex(b.lo));
    const hi = @min(ex(a.hi), ex(b.hi));
    if (lo > hi) return null;
    return .{ .lo = lo, .hi = hi };
}

/// Exact image of `hullOf`, as a fold of min and max over the list, with
/// the empty list as the null it is.
fn exactHullOf(items: []const Interval) ?Range {
    if (items.len == 0) return null;
    var lo = ex(items[0].lo);
    var hi = ex(items[0].hi);
    for (items[1..]) |it| {
        lo = @min(lo, ex(it.lo));
        hi = @max(hi, ex(it.hi));
    }
    return .{ .lo = lo, .hi = hi };
}

/// Exact image of `intersectionOf`, as a fold of max and min over the
/// whole list, with the empty list as the null it is.
///
/// Said plainly, because it is worth knowing where this oracle is thin:
/// the fold over three is NOT what gives it its power. Intersection is
/// associative, so a pairwise reduction and a flat fold return the same
/// null, and a third element changes nothing. What the third element
/// rules out is a fold that stops early, and the empty and one-element
/// shapes — the two a draw cannot reach — are pinned in a fixed test
/// instead. `hullOf` is the one where the third element decides the
/// answer, and dropping it fails 4,231 of that sweep.
fn exactIntersectionOf(items: []const Interval) ?Range {
    if (items.len == 0) return null;
    var lo = ex(items[0].lo);
    var hi = ex(items[0].hi);
    for (items[1..]) |it| {
        lo = @max(lo, ex(it.lo));
        hi = @min(hi, ex(it.hi));
    }
    if (lo > hi) return null;
    return .{ .lo = lo, .hi = hi };
}

/// True when `got` IS `want`, endpoint for endpoint.
///
/// An equality rather than a containment, and the difference is the
/// point: the set operations are asked for a value, not for a bound, and
/// a min or a max rounds nothing. A returned endpoint that is not the
/// right one is wrong rather than loose, and a comparison that allowed
/// slack would let a bound one endpoint too far in through.
fn rangeMatches(got: Interval, want: Range) bool {
    return ex(got.lo) == want.lo and ex(got.hi) == want.hi;
}

/// A `?Interval` answer against a `?Range` reference. The null cases have
/// to agree as exactly as the values do, because a null is the claim that
/// nothing bounds the result.
fn maybeMatches(got: ?Interval, want: ?Range) bool {
    if (want) |w| {
        const g = got orelse return false;
        return rangeMatches(g, w);
    }
    return got == null;
}

/// The sign of `y^3 - x`, decided in `f128`, or 0 when the difference is
/// inside the roundings and the sign is therefore not decided.
///
/// `y * y` is exact — 106 significand bits, which `f128` carries — and the
/// cube is one rounding of that, and the difference from `x` is at most
/// one more. The margin is four `f128` half-steps, which is more than
/// both of those together; the cases where it matters are the ones where
/// the cube is within an ULP of `x` anyway, so being generous costs one
/// extra step and never a wrong answer.
fn cubeSign(y: f64, x: f64) i8 {
    const square = ex(y) * ex(y);
    const cube = square * ex(y);
    const d = cube - ex(x);
    const margin = @max(@abs(cube), @abs(ex(x))) * 0x1p-111;
    if (d > margin) return 1;
    if (d < -margin) return -1;
    return 0;
}

/// Largest `f64` whose cube is not above `x`, and so a lower bound for
/// the true cube root of `x`.
///
/// The stepping starts at the library's own `std.math.cbrt` only as a
/// place to start, and nothing in the answer depends on it being right:
/// the loop runs until the sign says the cube is below `x`, and the cube
/// is strictly increasing, so that condition alone puts the answer under
/// the root. An undecided sign steps down as well, because a bound that
/// might be one ULP high is not a bound. The loop terminates because
/// stepping down takes the cube to -infinity.
fn cbrtLo(x: f64) f64 {
    if (x == 0.0) return 0.0;
    var y = std.math.cbrt(x);
    while (cubeSign(y, x) != -1) y = interval.prevDown(y);
    return y;
}

/// Smallest `f64` whose cube is not below `x`, and so an upper bound for
/// the true cube root of `x`. The mirror of `cbrtLo`, stepping up.
fn cbrtHi(x: f64) f64 {
    if (x == 0.0) return 0.0;
    var y = std.math.cbrt(x);
    while (cubeSign(y, x) != 1) y = interval.nextUp(y);
    return y;
}

/// Exact image of `cbrt`, as the bracket the two cube tests give.
///
/// No accuracy of any primitive is assumed, which is the reason this is
/// written the long way round. IEEE 754 requires `sqrt` to be correctly
/// rounded and says nothing whatever about `cbrt`, `std.math.cbrt` is a
/// musl port, and the package's own margin for the elementary functions
/// rests on a measured sample. A reference built from an `f128` cube root
/// would be that sample widened, and would agree with whatever the
/// primitive did — the `tanh` block below is the same trap caught in the
/// act, and the reason this one is written the long way round. It assumes
/// nothing: it is a statement about the cube function being increasing, so
/// it catches a primitive that is wrong by more than the three-ULP
/// widening claims to cover.
fn exactCbrt(a: Interval) Range {
    return .{ .lo = ex(cbrtLo(a.lo)), .hi = ex(cbrtHi(a.hi)) };
}

/// Exact image of `sqrt`, or null when the interval reaches no positive
/// number and so has no square root at all.
///
/// The endpoints are bracketed by half an ULP of the correctly rounded
/// `f64` answer, which is the entire margin IEEE 754 allows and the only
/// premise needed: `rounding.zig` rests on that same guarantee in the
/// same place, and this file is not going to quietly assume more or less
/// than the package already does. The negative part of `a` contributes
/// nothing to the image, so where the interval reaches below zero the
/// minimum is the exact zero that a point of the interval maps to.
fn exactSqrt(a: Interval) ?Range {
    if (a.hi < 0.0) return null;
    const lo = @sqrt(@max(0.0, a.lo));
    const hi = @sqrt(a.hi);
    return .{
        .lo = if (a.lo < 0.0) 0.0 else ex(lo) - ex(halfUlp(lo)),
        .hi = ex(hi) + ex(halfUlp(hi)),
    };
}

// ---------------------------------------------------------------------------
// The tanh reference: an oracle finer than f64
// ---------------------------------------------------------------------------

/// The natural logarithm of two, to forty decimal digits. `f128` carries
/// about thirty-four, so the literal IS the nearest `f128` to the true
/// constant, and the 2^-114 that costs is the whole of the error the
/// argument reduction below goes on to make.
const ln2_ref: f128 = 0.6931471805599453094172321214581765680755;

/// Terms of the exponential series that are kept, counted from the point
/// the argument has been reduced to |r| <= ln2/2. The first omitted term
/// there is 0.347^31/31! = 1e-43 against a sum of order one, ten orders
/// below the `f128` rounding floor of 1e-34, so the truncation is not what
/// limits this reference — the `f128` arithmetic is. Checked against
/// seventy-digit arithmetic at the widest argument, the zero and the
/// domain edges, the measured worst relative error of the whole
/// construction is 3.1e-34, which is 1.4e-18 of ONE ULP of `f64`.
///
/// That figure is the reason this exists at all, and the reason it has to
/// be stated rather than assumed. `std.math.tanh(0.23139395412799124)`
/// answers 0.22735067345628188 and the true value is
/// 0.227350673456281817160566003737, so the primitive is 2.14 ULP high
/// and the nearest `f64` to the truth is the very number it produced. An
/// oracle that rounded the truth to `f64` would therefore compare the
/// truth with itself and report the defect sound. Only a truth finer than
/// `f64` can see it, and at 1.4e-18 of a ULP this one is eighteen orders
/// finer than the grid the defect lives on.
const series_terms: usize = 30;

/// 1/n for n in [1, series_terms], formed at compile time. Multiplied by
/// rather than divided by at run time, because the band below runs the
/// series once per point and a software `f128` division costs two orders
/// of magnitude more than a multiply does.
const reciprocals: [series_terms]f128 = blk: {
    var table: [series_terms]f128 = undefined;
    for (&table, 1..) |*slot, i| {
        slot.* = 1.0 / @as(f128, @floatFromInt(i));
    }
    break :blk table;
};

/// exp(t) for |t| <= 1, by the Taylor series in Horner form. The terms
/// alternate and decrease across the whole band — |t|/n is under one for
/// every n from one on — so the first omitted term bounds the truncation,
/// and the sum is of order one against a leading term of order one, so
/// nothing here cancels.
fn expRefSmall(t: f128) f128 {
    var h: f128 = 1.0;
    var n: usize = series_terms;
    while (n >= 1) : (n -= 1) h = 1.0 + h * t * reciprocals[n - 1];
    return h;
}

/// exp(t) for t in [1, 40], which is the whole of what the reference
/// asks of it. The argument is reduced to t = k*ln2 + r, and both halves
/// of that are cheap: 2^k is a power of two built by doubling, so it is
/// exact, and r is under a third of a unit, where `expRefSmall`'s series
/// converges in thirty terms.
fn expRef(t: f128) f128 {
    const k: i32 = @intFromFloat(@round(t / ln2_ref));
    var scale: f128 = 1.0;
    var i: i32 = 0;
    while (i < k) : (i += 1) scale *= 2.0;
    return scale * expRefSmall(t - @as(f128, @floatFromInt(k)) * ln2_ref);
}

/// exp(t) - 1 for |t| <= 1, which is the branch that keeps this reference
/// honest near zero. The identity below forms m = exp(2x) - 1 and would
/// cancel catastrophically if m came out of a difference of two numbers
/// near one: at x = 1e-8 the difference is 2e-8 wide and an `f128` holds
/// it to 2^-113, so the value would carry a 1e-27 relative error — still
/// tolerable, but the error would grow as 1/x all the way down and the
/// band sweeps to a subnormal. Here m is never a difference at all: below
/// |t| = 1 it is the series evaluated in its own right, and above it the
/// subtraction is of a number at least e against a one, which costs less
/// than a bit.
fn expm1Ref(t: f128) f128 {
    if (@abs(t) <= 1.0) {
        // exp(t) - 1 = t * (1 + t/2 * (1 + t/3 * (1 + ...))), which is the
        // same series with its first term taken out and factored.
        var h: f128 = 1.0;
        var n: usize = series_terms;
        while (n >= 2) : (n -= 1) h = 1.0 + h * t * reciprocals[n - 1];
        return t * h;
    }
    return expRef(@abs(t)) - 1.0;
}

/// The true `tanh` at a magnitude in [0, 20], as a single `f128`.
///
/// It is the exponential identity with the cancellation already paid for:
/// tanh(x) = (E - 1) / (E + 1) with E = exp(2x), and `expm1Ref` hands back
/// m = E - 1 directly, so the quotient is m / (2 + m). Nothing in that
/// subtracts two nearly equal numbers at any magnitude — which matters
/// most near zero, where the naive identity evaluates 1 - 1 and loses
/// every digit it has.
fn tanhRefMag(a: f64) f128 {
    const t: f128 = 2.0 * @as(f128, a); // exact: doubling an f64
    const m = expm1Ref(t);
    return m / (2.0 + m);
}

/// Where the reference stops being a value and becomes a bracket.
///
/// Past 20 the true value is one to within 8e-18 — a thirty-fourth of a
/// ULP of `f64` — so no `f128` distinguishes it from 1, and an oracle
/// that answered 1 there would be answering a number ABOVE the truth and
/// would report a sound answer as a miss. The bracket is the statement
/// that survives: the value is in `[tanh 20, 1]` and that is the truth
/// about it.
const tanh_saturation: f64 = 20.0;

/// The true `tanh` at `x`, bracketed: the returned pair contains the real
/// value for every `f64` `x`, and is a degenerate pair everywhere the
/// value is representable to thirty-four digits.
fn tanhRef(x: f64) Range {
    const a = @abs(x);
    if (a > tanh_saturation) {
        const edge: f128 = tanhRefMag(tanh_saturation);
        return if (x > 0.0)
            .{ .lo = edge, .hi = 1.0 }
        else
            .{ .lo = -1.0, .hi = -edge };
    }
    const v = tanhRefMag(a);
    return .{ .lo = if (x < 0.0) -v else v, .hi = if (x < 0.0) -v else v };
}

/// Exact image of `tanh` over `a`, as the pair of brackets `tanhRef`
/// gives at its two ends. `tanh` rises, so the image of a closed interval
/// is the image of its ends, and widening each end to a bracket and
/// taking the outer pair keeps every value between them inside.
fn exactTanh(a: Interval) Range {
    const l = tanhRef(a.lo);
    const h = tanhRef(a.hi);
    return .{ .lo = @min(l.lo, h.lo), .hi = @max(l.hi, h.hi) };
}

/// Exact image of `floor`. The map snaps to a value OF the interval, so
/// its image is the pair of snapped ends; the reference is exact rather
/// than a rounding of an exact value, which is what a snapping map
/// buys over every other one under test.
fn exactFloor(a: Interval) Range {
    return .{ .lo = ex(@floor(a.lo)), .hi = ex(@floor(a.hi)) };
}

/// Exact image of `ceil`, the other snapping map.
fn exactCeil(a: Interval) Range {
    return .{ .lo = ex(@ceil(a.lo)), .hi = ex(@ceil(a.hi)) };
}

/// Exact image of `trunc`.
fn exactTrunc(a: Interval) Range {
    return .{ .lo = ex(@trunc(a.lo)), .hi = ex(@trunc(a.hi)) };
}

/// Exact image of `round`, ties away from zero as `@round` goes.
fn exactRound(a: Interval) Range {
    return .{ .lo = ex(@round(a.lo)), .hi = ex(@round(a.hi)) };
}

/// The exact centre of `a`, and the margin a returned midpoint is allowed
/// to sit outside it by.
///
/// `midpoint` returns a value and not a bound, and the package says so,
/// so the requirement is closeness rather than containment. The centre
/// here is exact — the sum of two `f64` is exact in `f128` — and the
/// returned value is `fl(fl(lo + hi) / 2)`, so it sits within a quarter
/// ULP of that centre from the sum's own rounding and within half an ULP
/// from the division's. The margin below is one ULP measured relatively
/// with a factor of two over the worst case, because the two values can
/// straddle a binade boundary and the grid is not the same on both sides
/// of one. A midpoint formed from the wrong pair of endpoints, or from a
/// negated one, lands outside the interval it came from and does not
/// survive that; one that is merely a ULP out does, which is what the
/// package promises and all this file asks of it.
const midpoint_rel: f128 = 0x1p-51;

fn exactMidpoint(a: Interval) f128 {
    return (ex(a.lo) + ex(a.hi)) / 2.0;
}

/// The exact value `clamp` must return: the nearer of the two endpoints,
/// or `x` when `x` is already inside. A min and a max are selections, so
/// the `f128` reference picks the same operand the `f64` one does and
/// `scalarOk` is only covering the arithmetic, not a disagreement.
fn exactClamp(a: Interval, x: f64) f128 {
    return @min(@max(ex(x), ex(a.lo)), ex(a.hi));
}

/// Containment of one corner quotient `a / b` in `got`, decided by exact
/// cross-multiplication.
///
/// The quotient is never evaluated. Both questions — is `got.lo` at most
/// the quotient, is the quotient at most `got.hi` — are answered by
/// multiplying through by the divisor, and each such product is an `f64`
/// times an `f64`, exact in `f128`. A positive divisor leaves the
/// inequality alone and a negative one reverses it, which is the only sign
/// case the argument needs. An infinite bound on the enclosing side is
/// always enough; an infinite bound on the far side is a miss, because the
/// quotient of two finite operands is finite.
fn quotientHolds(a: f64, b: f64, got: Interval) bool {
    const A = ex(a);
    const B = ex(b);
    if (B == 0.0) return true; // a divisor of zero is screened out earlier
    const lower = blk: {
        if (std.math.isNan(got.lo)) break :blk false;
        if (got.lo == neg_inf64) break :blk true;
        const L = ex(got.lo) * B;
        break :blk if (B > 0.0) L <= A else L >= A;
    };
    const upper = blk: {
        if (std.math.isNan(got.hi)) break :blk false;
        if (got.hi == inf64) break :blk true;
        const H = ex(got.hi) * B;
        break :blk if (B > 0.0) H >= A else H <= A;
    };
    return lower and upper;
}

/// Containment of the quotient set `{x / y : x in num, y in den, y != 0}`
/// in `got`, for a `den` that REACHES zero.
///
/// This is the case the sweep used to decline, and it is not a case the
/// oracle has to decline: the library has a documented answer for it —
/// `src/interval.zig` returns the whole line from the guard
/// `other.lo <= 0.0 and 0.0 <= other.hi` — and a documented answer is a
/// contract value that can be checked, not a precondition. What the TRUE
/// image is does take deriving, and it is not always the whole line:
///
///   * A divisor that merely REACHES zero from one side leaves the
///     quotient set unbounded on exactly one side, and its finite end is
///     the single corner quotient at the far endpoint. A dividend of one
///     sign gives one ray; a dividend straddling zero gives the line.
///   * A divisor with zero in its INTERIOR leaves both rays free, so its
///     hull is the whole line whatever the dividend is, and the two
///     situations are worth telling apart: `[-1, 1] / [0, 3]` is the whole
///     line, because a dividend straddling zero reaches both infinities
///     even from one side of the divisor, while `[1, 2] / [0, 3]` is the
///     single ray `[1/3, +inf)`. An oracle that assumed the second shape
///     for both would pass the library's over-answer on the first and
///     hide a narrowing of the second.
///   * A dividend of exactly zero gives the single point zero for every
///     non-zero divisor, so the requirement is that `got` contains it.
///   * A divisor of exactly zero has NO quotient at all: the only divisor
///     is the one that is undefined, so the image is empty and every
///     interval encloses it. Nothing is required, and nothing is checked.
///
/// The finite ends are decided by `quotientHolds` on the one relevant
/// corner, which never evaluates a quotient. The infinite ends are
/// decided by the sign of the limit, and that is the only premise here:
/// `x / y` runs off to a signed infinity as `y` runs off to zero, and it
/// runs off to opposite infinities from the two sides.
fn unboundedQuotientHolds(num: Interval, den: Interval, got: Interval) bool {
    // y over the positive part of the divisor, (0, den.hi].
    if (den.hi > 0.0) {
        if (num.lo < 0.0 and got.lo != neg_inf64) return false;
        if (num.hi > 0.0 and got.hi != inf64) return false;
        if (!quotientHolds(num.lo, den.hi, got)) return false;
        if (!quotientHolds(num.hi, den.hi, got)) return false;
    }
    // y over the negative part, [den.lo, 0). The quotient reverses, so the
    // two ends of the dividend swap which infinity they reach.
    if (den.lo < 0.0) {
        if (num.hi > 0.0 and got.lo != neg_inf64) return false;
        if (num.lo < 0.0 and got.hi != inf64) return false;
        if (!quotientHolds(num.hi, den.lo, got)) return false;
        if (!quotientHolds(num.lo, den.lo, got)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Reproducer verdicts
// ---------------------------------------------------------------------------

/// How much wider than the true image a returned interval may be before a
/// reproducer also fails for over-widening. The point is only to reject an
/// answer that gives up — the universal interval, a saturated `floatMax`,
/// anything — and not to pin how tight a legitimate answer is. A test that
/// pinned an exact widened literal would be wrong the moment the
/// implementation changed for a good reason; this one is not.
const width_rel: f64 = 4.0;
const width_ulp_floor: f64 = 1048576.0; // 2^20

/// The smallest positive `f64`. Drawn as an operand in its own right and
/// used as the resolution floor of the width bound.
const min_subnormal: f64 = 4.9406564584124654e-324;

/// True when the returned interval is not absurdly wider than the true
/// image.
///
/// Used by the reproducer helper and by NOTHING ELSE. The sweep checks
/// containment only, deliberately: the package's contract is enclosure
/// and not tightness, and [-inf, +inf] is the tightest sound `f64` answer
/// wherever the image genuinely leaves the range. Wiring this into the
/// sweep would report thousands of sound enclosures as failures and punish
/// correct behaviour. Its only job is to stop a fix that answers the
/// universal interval where a finite one exists.
///
/// The floor is measured from the smallest positive `f64` rather than
/// from the true extremum alone, because in the underflow regime the true
/// image sits around 1e-400 while no `f64` can be anywhere near it: the
/// narrowest answer a bound can give is two subnormals wide, and a floor
/// measured from 1e-400 would reject that as wasteful. Measuring from the
/// format's own resolution is the only floor that means the same thing in
/// every regime.
fn widthOk(got: Interval, r: Range) bool {
    const w = ex(got.hi) - ex(got.lo);
    if (std.math.isNan(w) or w == inf128) return false;
    const scale = @max(@abs(r.lo), @abs(r.hi));
    const floor = width_ulp_floor * @max(if (scale == 0.0) 1.0 else scale, min_subnormal);
    return w <= @max((r.hi - r.lo) * width_rel, floor);
}

/// Relative slack applied to a `powf` oracle value. The value comes from
/// an `f128` evaluation of `exp(y * log x)`, which is accurate to roughly
/// 1e-30 relative here, so the exact value is bracketed by that much
/// before the comparison. A pass is then a genuine pass rather than a
/// comparison against a number that is merely close.
const powf_slack: f128 = 1e-28;

/// Oracle for `x^y` at a positive base: the exact value to within
/// `powf_slack`. `f128` carries 34 significant decimal digits, and the
/// argument `y * log(x)` is formed there, so the error is some 1e-30
/// relative — many orders below the margin the library applies and far
/// below any difference the reproducers turn on.
fn exactPowf(x: f64, y: f64) Range {
    const v = @exp(ex(y) * @log(ex(x)));
    return .{ .lo = v * (1.0 - powf_slack), .hi = v * (1.0 + powf_slack) };
}

// ---------------------------------------------------------------------------
// Fuzz machinery
// ---------------------------------------------------------------------------

/// The operations the sweep covers, one report line each.
///
/// The ORDER of the members is documentation and nothing else. The seed of
/// a stream comes from the operation's LABEL (`streamSeed` below), so
/// inserting a member anywhere in this list leaves every other stream
/// drawing exactly the cases it drew before. It used to be the enum value
/// XORed into `seed`, which made a member's POSITION its identity: adding
/// one operation in the middle re-randomised every stream after it, so the
/// counts a previous run printed stopped being about the same cases with no
/// change anywhere in the code under test to explain it.
const Op = enum {
    add,
    sub,
    mul,
    div,
    recip,
    translate,
    scale,
    expand,
    abs,
    sqr,
    neg,
    hull,
    intersect,
    hull_of,
    intersection_of,
    midpoint,
    clamp,
    width,
    distance_to,
    contains,
    overlaps,
    subset_of,
    eql,
    ne,
    lt,
    le,
    gt,
    ge,
    floor,
    ceil,
    trunc,
    round,
    sqrt,
    cbrt,
    tanh,

    fn label(op: Op) []const u8 {
        return @tagName(op);
    }

    /// True for the operations that take a second interval operand.
    fn usesSecond(op: Op) bool {
        return switch (op) {
            .add, .sub, .mul, .div, .hull, .intersect, .hull_of, .intersection_of, .overlaps, .subset_of, .eql, .ne, .lt, .le, .gt, .ge => true,
            else => false,
        };
    }

    /// True for the operations that take a bare `f64` scalar. The two
    /// list folds are in it because their third element is the scalar
    /// drawn for the case, which is what takes the fold past the
    /// two-element case a pairwise law would settle.
    fn usesScalar(op: Op) bool {
        return switch (op) {
            .translate, .scale, .expand, .clamp, .distance_to, .contains, .hull_of, .intersection_of => true,
            else => false,
        };
    }

    /// The reference the sweep judges this operation against, named in
    /// every failure report so that a failure says what was expected
    /// without the reader having to go and look it up.
    fn oracle(op: Op) []const u8 {
        return switch (op) {
            .add => "the two same-signed corner sums, judged against the two f64 operands of each through the TwoSum residual and never against an f128 of the sum",
            .sub => "the two crossed corner differences, judged against the two f64 operands of each through the TwoSum residual and never against an f128 of the sum",
            .mul => "the min and max over the four corner products, exact in f128",
            .div, .recip => "exact cross-multiplication of each corner, and for a divisor reaching zero the sign of the two one-sided limits",
            .translate => "the two endpoint sums, judged against the two f64 operands of each through the TwoSum residual and never against an f128 of the sum",
            .scale => "the exact affine extrema (A + B + G*A - G*B) / 2 and (A + B - G*A + G*B) / 2 for the original f64 endpoints A, B and the magnitude G, compared term by term through the five-term f128 expansion of A, B, G*A, -G*B and -2*g - no midpoint, no half-width, no f128 rounding anywhere in the reference, and the whole line at an infinite factor on a box with width",
            .expand => "the two endpoint differences, judged against the two f64 operands of each through the TwoSum residual and never against an f128 of the sum",
            .abs => "the min and max of the two endpoint magnitudes, exact",
            .sqr => "the two endpoint squares, exact in f128, with a zero floor on an interval straddling zero",
            .neg => "the endpoints swapped, exact",
            .hull, .hull_of => "the min of the lower ends and the max of the upper ends, exact",
            .intersect, .intersection_of => "the max of the lower ends and the min of the upper ends, exact, and null when they cross",
            .midpoint => "the exact centre (lo + hi) / 2 in f128, to within one ULP",
            .clamp => "the nearer endpoint, or x itself, selected in f128",
            .width, .distance_to => "the exact difference of the f64 endpoints in f128, as a value to within one ULP",
            .contains, .overlaps, .subset_of => "agreement with intersect and hull, which have exact references",
            .eql, .ne, .lt, .le, .gt, .ge => "the endpoint relation stated in f128, together with the certain-comparison laws",
            .floor, .ceil, .trunc, .round => "the primitive at each endpoint, exact because the map snaps to a value of the interval",
            .sqrt => "each endpoint bracketed by half an ULP, the whole margin IEEE 754 allows a correctly rounded square root",
            .cbrt => "the bracket the sign of y^3 - x gives, which assumes no accuracy of any primitive",
            .tanh => "the true tanh of each endpoint in f128 to 3.1e-34 relative, from the exponential identity with the cancellation near zero controlled, bracketed to [tanh 20, 1] past 20 where the value is indistinguishable from 1 at thirty-four digits",
        };
    }
};

/// Magnitude classes an operand is drawn from. They are enumerated rather
/// than sampled from a uniform distribution because a uniform draw over
/// the `f64` range lands in the ordinary binade essentially always: it
/// never reaches a subnormal, never reaches the overflow frontier, and
/// never produces an exact signed zero. Those are the regimes the defects
/// live in, so they are drawn by name.
const Magnitude = enum {
    /// Ordinary values, kept so the sweep is not exclusively exotic.
    ordinary,
    /// Subnormals and the smallest powers of ten, where a product
    /// underflows to a zero that carries no magnitude.
    tiny,
    /// Up to the overflow frontier, where a product overflows to an
    /// infinity.
    huge,
    /// A tiny magnitude on BOTH sides of zero, so the interval spans it.
    /// The single-scale classes can only ever produce an interval that is
    /// all positive or all negative, and an interval that straddles zero
    /// at subnormal magnitude is the one shape where a corner underflows
    /// to a zero whose sign the reduction cannot see. Without this class
    /// the sweep reports `mul` as sound when it is not.
    tiny_spanning,
    /// A huge magnitude on both sides of zero, which is the same idea at
    /// the overflow frontier: the corners of a product or a quotient then
    /// overflow to infinities of both signs.
    huge_spanning,
    /// Exactly one of the two zeros, with its sign.
    exact_zero,
    /// The smallest positive subnormal.
    min_subnormal,
    /// The largest finite value, with a sign, so that a box drawn from
    /// this class can span the whole representable range. `float_max`
    /// below is the unsigned form, and the two are separate because only
    /// the spanning box has a width — 2*floatMax as a real, +inf as an
    /// f64 — and an infinite intermediate is the only place a
    /// width-based operation can meet one. Without this class
    /// `Interval.init(-floatMax, floatMax).scale(0.0)` returns a NaN
    /// interval and the sweep never sees it, because no other entry in
    /// the table can put both endpoints at the frontier.
    full_range,
    /// The largest finite value.
    float_max,
    /// Deliberately non-finite, to exercise the skip path.
    nonfinite,

    fn draw(m: Magnitude, r: std.Random) f64 {
        return switch (m) {
            .ordinary => r.float(f64) * 2000.0 - 1000.0,
            .tiny => pow10(r.intRangeAtMost(i32, -323, -290)) * (1.0 + r.float(f64) * 9.0),
            .huge => pow10(r.intRangeAtMost(i32, 285, 307)) * (1.0 + r.float(f64) * 0.7),
            .tiny_spanning => signed(pow10(r.intRangeAtMost(i32, -323, -290)) * (1.0 + r.float(f64) * 9.0), r),
            .huge_spanning => signed(pow10(r.intRangeAtMost(i32, 285, 307)) * (1.0 + r.float(f64) * 0.7), r),
            .exact_zero => if (r.boolean()) 0.0 else -0.0,
            .min_subnormal => min_subnormal,
            .float_max => std.math.floatMax(f64),
            .full_range => signed(std.math.floatMax(f64), r),
            .nonfinite => switch (r.intRangeAtMost(u8, 0, 2)) {
                0 => inf64,
                1 => neg_inf64,
                else => std.math.nan(f64),
            },
        };
    }
};

/// 10^e, evaluated in `f64` because the operand is an `f64` and the exact
/// power is not what a test operand has to be.
fn pow10(e: i32) f64 {
    return std.math.pow(f64, 10.0, @as(f64, @floatFromInt(e)));
}

/// A magnitude with a random sign, so that drawing both endpoints of an
/// interval from the same class lands on both sides of zero about half
/// the time. Negating zero is deliberately not reachable here: the sign
/// of a zero is a bit, not a choice, and `exact_zero` already covers it.
fn signed(magnitude: f64, r: std.Random) f64 {
    return if (r.boolean()) magnitude else -magnitude;
}

/// The magnitude table, weighted towards the regimes that matter. Ordinary
/// values keep the largest single share so the sweep stays a general test
/// rather than an exotic-only one.
const magnitudes = [_]Magnitude{
    .ordinary,
    .ordinary,
    .ordinary,
    .ordinary,
    .ordinary,
    .tiny,
    .tiny,
    .tiny,
    .tiny_spanning,
    .tiny_spanning,
    .tiny_spanning,
    .huge,
    .huge,
    .huge,
    .huge_spanning,
    .huge_spanning,
    .exact_zero,
    .min_subnormal,
    .full_range,
    .full_range,
    .float_max,
    .nonfinite,
};

fn drawMagnitude(r: std.Random) Magnitude {
    return magnitudes[r.uintLessThan(usize, magnitudes.len)];
}

/// A drawn case before any `Interval` exists. The values are screened
/// here rather than after construction because `Interval.init` asserts
/// `lo <= hi`, and a NaN endpoint fails that assertion by comparison rather
/// than by evaluation, which would abort the whole test binary instead of
/// setting the case aside.
const Raw = struct {
    op: Op,
    a: [2]f64,
    b: [2]f64,
    s: f64,
};

/// One screened case: the operation, both operand intervals, and the
/// scalar the operations taking a bare `f64` use. `b` and `s` are unused
/// by the operations that do not take them.
const Case = struct {
    op: Op,
    a: Interval,
    b: Interval,
    s: f64,

    /// The third element the list folds read, built from the scalar the
    /// case already drew. Reusing that draw is what keeps one generator
    /// serving every operation: a second draw would either be a second
    /// generator or a change to the stream the eight original operations
    /// already have.
    fn third(c: Case) Interval {
        return Interval.init(c.s, c.s);
    }

    /// The list the two folds read, in the order they read it.
    fn list(c: Case) [3]Interval {
        return .{ c.a, c.b, c.third() };
    }
};

/// What one operation returned. Four shapes because the package has four
/// shapes: an enclosure, an enclosure or the claim that there is none, a
/// scalar, and a bool. The sweep reports one line per operation whichever
/// shape came back, and a union is what lets a single `apply` and a
/// single `holds` serve all four without a second generator.
const Value = union(enum) {
    interval: Interval,
    maybe_interval: ?Interval,
    scalar: f64,
    flag: bool,

    fn intervalOrNull(v: Value) ?Interval {
        return switch (v) {
            .interval => |i| i,
            else => null,
        };
    }

    fn flagOrNull(v: Value) ?bool {
        return switch (v) {
            .flag => |b| b,
            else => null,
        };
    }

    fn scalarOrNull(v: Value) ?f64 {
        return switch (v) {
            .scalar => |x| x,
            else => null,
        };
    }
};

/// Draw one interval's endpoints, sorted so `lo <= hi`. A degenerate
/// interval — one with `lo == hi` — is drawn on a fraction of the cases,
/// because a point interval exercises only two of the four corners of a
/// product and is the shape the existing tests use exclusively.
fn drawEndpoints(m: Magnitude, degenerate: bool, r: std.Random) [2]f64 {
    const x = m.draw(r);
    if (degenerate) return .{ x, x };
    const y = m.draw(r);
    return .{ @min(x, y), @max(x, y) };
}

fn drawRaw(op: Op, r: std.Random) Raw {
    const ma = drawMagnitude(r);
    // Half the cases pair the drawn magnitude against an independently
    // drawn one, which is the mixed-magnitude regime the defects need and
    // a single shared magnitude would reach only by luck.
    const mb = if (op.usesSecond() and r.boolean()) drawMagnitude(r) else ma;
    const degenerate = r.intRangeAtMost(u8, 0, 7) == 0;
    return .{
        .op = op,
        .a = drawEndpoints(ma, degenerate, r),
        .b = if (op.usesSecond()) drawEndpoints(mb, degenerate, r) else .{ 0.0, 0.0 },
        .s = drawMagnitude(r).draw(r),
    };
}

/// Build the intervals of a screened case. Every endpoint is finite here,
/// so the constructor's ordering assertion holds.
fn buildCase(raw: Raw) Case {
    return .{
        .op = raw.op,
        .a = Interval.init(raw.a[0], raw.a[1]),
        .b = Interval.init(raw.b[0], raw.b[1]),
        .s = raw.s,
    };
}

/// Call the operation the case names, whatever shape it answers in.
fn apply(c: Case) Value {
    return switch (c.op) {
        .add => .{ .interval = c.a.add(c.b) },
        .sub => .{ .interval = c.a.sub(c.b) },
        .mul => .{ .interval = c.a.mul(c.b) },
        .div => .{ .interval = c.a.div(c.b) },
        .recip => .{ .interval = c.a.recip() },
        .translate => .{ .interval = c.a.translate(c.s) },
        .scale => .{ .interval = c.a.scale(c.s) },
        .expand => .{ .interval = c.a.expand(c.s) },
        .abs => .{ .interval = c.a.abs() },
        .sqr => .{ .interval = c.a.sqr() },
        .neg => .{ .interval = c.a.neg() },
        .hull => .{ .interval = c.a.hull(c.b) },
        .intersect => .{ .maybe_interval = c.a.intersect(c.b) },
        .hull_of => .{ .maybe_interval = Interval.hullOf(&c.list()) },
        .intersection_of => .{ .maybe_interval = Interval.intersectionOf(&c.list()) },
        .midpoint => .{ .scalar = c.a.midpoint() },
        .clamp => .{ .scalar = c.a.clamp(c.s) },
        .width => .{ .scalar = c.a.width() },
        .distance_to => .{ .scalar = c.a.distanceTo(c.s) },
        .contains => .{ .flag = c.a.contains(c.s) },
        .overlaps => .{ .flag = c.a.overlaps(c.b) },
        .subset_of => .{ .flag = c.a.subsetOf(c.b) },
        .eql => .{ .flag = c.a.eql(c.b) },
        .ne => .{ .flag = c.a.ne(c.b) },
        .lt => .{ .flag = c.a.lt(c.b) },
        .le => .{ .flag = c.a.le(c.b) },
        .gt => .{ .flag = c.a.gt(c.b) },
        .ge => .{ .flag = c.a.ge(c.b) },
        .floor => .{ .interval = interval.ext.floor(c.a) },
        .ceil => .{ .interval = interval.ext.ceil(c.a) },
        .trunc => .{ .interval = interval.ext.trunc(c.a) },
        .round => .{ .interval = interval.ext.round(c.a) },
        .sqrt => .{ .maybe_interval = interval.ext.sqrt(c.a) },
        .cbrt => .{ .interval = interval.ext.cbrt(c.a) },
        .tanh => .{ .interval = interval.ext.tanh(c.a) },
    };
}

/// The exact image, for every operation whose image is a closed range this
/// layer can state as a `Range`. `div` and `recip` return null because a
/// quotient is not exact in `f128`; they are checked by `quotientHolds` and
/// by `unboundedQuotientHolds`. The predicates and the comparisons return
/// null for the same reason in the other direction: they have no image.
/// The four whose extremum is a sum of two `f64`s return null here as well
/// and are read through `sumBound`, because a `Range` for them would have
/// to hold an `f128` that is not their extremum. `scale` joins them for a
/// related reason and is read through `boundedScaleHolds`: its extrema are
/// five-term sums of the original endpoints, and the only `Range` it could
/// return would have to carry the rounding of a midpoint it must not form.
fn exact(c: Case) ?Range {
    return switch (c.op) {
        .mul => exactMul(c.a, c.b),
        .abs => exactAbs(c.a),
        .sqr => exactSqr(c.a),
        .neg => exactNeg(c.a),
        .hull => exactHull(c.a, c.b),
        .hull_of => exactHullOf(&c.list()),
        .intersect => exactIntersect(c.a, c.b),
        .intersection_of => exactIntersectionOf(&c.list()),
        .floor => exactFloor(c.a),
        .ceil => exactCeil(c.a),
        .trunc => exactTrunc(c.a),
        .round => exactRound(c.a),
        .sqrt => exactSqrt(c.a),
        .cbrt => exactCbrt(c.a),
        .tanh => exactTanh(c.a),
        .add, .sub, .translate, .expand, .scale, .div, .recip, .midpoint, .clamp, .width, .distance_to, .contains, .overlaps, .subset_of, .eql, .ne, .lt, .le, .gt, .ge => null,
    };
}

/// The sum reference of `op`, for the four operations whose image ends are
/// each the sum of two `f64` values. Null for every other operation.
fn sumBound(c: Case) ?SumBound {
    return switch (c.op) {
        .add => exactAdd(c.a, c.b),
        .sub => exactSub(c.a, c.b),
        .translate => exactTranslate(c.a, c.s),
        .expand => exactExpand(c.a, c.s),
        else => null,
    };
}

/// Every relation the package offers about one pair of operands, read off
/// in one place. The predicates and the certain comparisons have no image
/// to check against, so what they are checked against is each other, and
/// this is the single place that reads them all off the same pair.
const Relations = struct {
    overlaps: bool,
    subset: bool,
    reverse_subset: bool,
    intersect: ?Interval,
    hull: Interval,
    eql: bool,
    lt: bool,
    le: bool,
    gt: bool,
    ge: bool,

    fn of(a: Interval, b: Interval) Relations {
        return .{
            .overlaps = a.overlaps(b),
            .subset = a.subsetOf(b),
            .reverse_subset = b.subsetOf(a),
            .intersect = a.intersect(b),
            .hull = a.hull(b),
            .eql = a.eql(b),
            .lt = a.lt(b),
            .le = a.le(b),
            .gt = a.gt(b),
            .ge = a.ge(b),
        };
    }
};

/// The one-line reference for each predicate, stated in `f128` from the
/// exact endpoints. On its own this is the definition compared with
/// itself, which is a tautology, and it is here for the record and
/// because it costs nothing. What the sweep is FOR is the law beside it:
/// every rule below is a relation between two DIFFERENT operations, so an
/// answer that is wrong in a way its own definition cannot see still
/// fails somewhere in here. The certain-comparison rules are written to
/// the sound direction — a certain comparison may fail to prove a
/// relation, because a wider enclosure settles more of them, but it may
/// never REPORT one the operands leave open — which is the failure mode
/// that a self-comparison cannot see at all.
fn predicateHolds(op: Op, c: Case, got: bool) bool {
    const a = c.a;
    const b = c.b;
    const r = Relations.of(a, b);
    // The point `contains` asks about, built once so the three ways of
    // asking it below all read the same value.
    const point = Interval.init(c.s, c.s);
    switch (op) {
        .overlaps => {
            // The one line: two orderings, read in f128.
            if (got != (ex(a.lo) <= ex(b.hi) and ex(b.lo) <= ex(a.hi))) return false;
            // Sharing a point and having a common part are the same claim
            // reached two ways: four orderings against a max and a min.
            if (got != (r.intersect != null)) return false;
            // Either interval lying inside the other is a sharing, so a
            // "no" here rules out both containments at once.
            if (!got and (r.subset or r.reverse_subset)) return false;
        },
        .subset_of => {
            if (got != (ex(b.lo) <= ex(a.lo) and ex(a.hi) <= ex(b.hi))) return false;
            // Containment is exactly the hull collapsing onto the
            // container, which is an exact min and max rather than two
            // orderings.
            if (got != r.hull.eql(b)) return false;
            // The other collapse: a hull that comes back as `a` says `a`
            // holds `b`, so a one-sided containment that also collapses
            // the other way is mutual, which is equality.
            if (got and r.hull.eql(a) and !r.reverse_subset) return false;
        },
        .contains => {
            if (got != (ex(a.lo) <= ex(c.s) and ex(c.s) <= ex(a.hi))) return false;
            // A point is inside exactly when the two share it, read
            // through `intersect` and through `overlaps`, the two claims
            // about pairs this file has an exact oracle for.
            if (got != (a.intersect(point) != null)) return false;
            if (got != a.overlaps(point)) return false;
            // And exactly when the hull leaves the interval alone, which
            // is the min and max of the pair rather than two orderings.
            if (got != a.hull(point).eql(a)) return false;
        },
        .eql => {
            if (got != (ex(a.lo) == ex(b.lo) and ex(a.hi) == ex(b.hi))) return false;
            // Equality is mutual containment, and it is nothing else.
            if (got != (r.subset and r.reverse_subset)) return false;
            if (got) {
                if (!r.hull.eql(a)) return false;
                if (!r.overlaps) return false;
                const m = r.intersect orelse return false;
                if (!m.eql(a)) return false;
                // An equal pair that is not a point can be certainly
                // ordered in no direction at all, which is the one case a
                // one-sided order test would have to reach and would
                // miss. A pair of equal POINTS is the exception and the
                // sweep draws those constantly: every ordering holds of
                // {x} against {x}.
                if (a.lo != a.hi and (r.lt or r.gt or r.le or r.ge)) return false;
            }
        },
        .ne => {
            if (got != (ex(a.lo) != ex(b.lo) or ex(a.hi) != ex(b.hi))) return false;
            // Inequality is exactly the failure of mutual containment,
            // through two orderings per direction rather than the one
            // comparison `ne` itself is written as.
            if (got == (r.subset and r.reverse_subset)) return false;
        },
        .lt => {
            // The one line, and the sound direction it is checked in: a
            // certain comparison may fail to prove a relation, because a
            // wider enclosure would settle more of them, and it may never
            // report one the operands leave open. A `lt` that answered
            // for a straddling operand is that failure, and a one-line
            // comparison against its own definition cannot see it.
            if (got != (ex(a.hi) < ex(b.lo))) return false;
            // The symmetry law: the strict order the other way round is
            // the same claim read through the other operand, from a
            // different endpoint of it and in the other direction. A
            // comparison that reached for the wrong endpoint disagrees
            // with its own mirror here and nowhere else.
            if (got != b.gt(a)) return false;
            if (got) {
                if (r.overlaps) return false;
                if (!r.le) return false;
                if (r.ge) return false;
                if (b.le(a)) return false;
                if (r.eql) return false;
            }
            // Strictness is what separates `lt` from `le`, and the two
            // differ on exactly the touching pairs and nowhere else.
            if (r.le and !r.lt and !(ex(a.hi) == ex(b.lo))) return false;
            if (!r.le and r.lt) return false;
        },
        .le => {
            if (got != (ex(a.hi) <= ex(b.lo))) return false;
            if (got != b.ge(a)) return false;
            // The strict order implies the weak one, and the two weak
            // orders are disjoint for anything but a point. Both facts
            // reach different endpoints of the two operands, which is
            // what makes them checks rather than restatements: the
            // exemption below is where they stop being true, and a
            // comparison reading the wrong endpoint would move it.
            if (r.lt and !r.le) return false;
            if (got and r.gt) return false;
            if (got and a.lo != a.hi and a.ge(b)) return false;
        },
        .gt => {
            if (got != (ex(a.lo) > ex(b.hi))) return false;
            if (got != b.lt(a)) return false;
            if (got) {
                if (r.overlaps) return false;
                if (!r.ge) return false;
                if (r.le) return false;
                if (a.le(b)) return false;
                if (r.eql) return false;
            }
            if (r.ge and !r.gt and !(ex(a.lo) == ex(b.hi))) return false;
            if (!r.ge and r.gt) return false;
        },
        .ge => {
            if (got != (ex(a.lo) >= ex(b.hi))) return false;
            if (got != b.le(a)) return false;
            if (r.gt and !r.ge) return false;
            if (got and r.lt) return false;
            // The same exemption, reached from this side: the two weak
            // orders in opposite directions both hold only when both
            // operands are the one same point.
            if (got and a.lo != a.hi and a.le(b)) return false;
        },
        else => return false,
    }
    return true;
}

/// True when `got` is what the oracle requires of the case, whatever shape
/// it came back in.
fn holds(c: Case, got: Value) bool {
    switch (c.op) {
        .div => {
            const g = got.intervalOrNull() orelse return false;
            if (g.lo > g.hi) return false;
            // A divisor that reaches zero is a documented answer and not
            // a precondition, so it is judged by the true image of the
            // quotient set rather than set aside.
            if (c.b.lo <= 0.0 and 0.0 <= c.b.hi) {
                return unboundedQuotientHolds(c.a, c.b, g);
            }
            var ok = true;
            const dividends = [2]f64{ c.a.lo, c.a.hi };
            const divisors = [2]f64{ c.b.lo, c.b.hi };
            for (dividends) |x| {
                for (divisors) |y| {
                    if (!quotientHolds(x, y, g)) ok = false;
                }
            }
            return ok;
        },
        .recip => {
            const g = got.intervalOrNull() orelse return false;
            if (g.lo > g.hi) return false;
            const one = Interval.init(1.0, 1.0);
            if (c.a.lo <= 0.0 and 0.0 <= c.a.hi) {
                return unboundedQuotientHolds(one, c.a, g);
            }
            var ok = true;
            for ([2]f64{ c.a.lo, c.a.hi }) |x| {
                if (!quotientHolds(1.0, x, g)) ok = false;
            }
            return ok;
        },
        .intersect, .intersection_of, .hull_of => {
            const m = switch (got) {
                .maybe_interval => |x| x,
                else => return false,
            };
            return maybeMatches(m, exact(c));
        },
        .sqrt => {
            const m = switch (got) {
                .maybe_interval => |x| x,
                else => return false,
            };
            const want = exactSqrt(c.a);
            const g = m orelse return want == null;
            const w = want orelse return false;
            if (g.lo > g.hi) return false;
            return loEncloses(w, g.lo) and hiEncloses(w, g.hi);
        },
        .tanh => {
            // Containment, with no margin of any kind. The two-ULP
            // defect this arm exists to catch is 0.14 ULP, so a tolerance
            // wide enough to matter would be a tolerance wide enough to
            // hide it — and the reference is good to 1.4e-18 ULP anyway,
            // eighteen orders of magnitude below the decision. The
            // package's contract is that the answer CONTAINS the truth,
            // and nothing here asks how much wider than the truth it is.
            const g = got.intervalOrNull() orelse return false;
            if (g.lo > g.hi) return false;
            const r = exactTanh(c.a);
            return loEncloses(r, g.lo) and hiEncloses(r, g.hi);
        },
        .midpoint => {
            const x = got.scalarOrNull() orelse return false;
            if (std.math.isNan(x) or std.math.isInf(x)) return false;
            const centre = exactMidpoint(c.a);
            return @abs(ex(x) - centre) <= @abs(centre) * midpoint_rel + ex(min_subnormal);
        },
        .clamp => {
            const x = got.scalarOrNull() orelse return false;
            return scalarOk(x, exactClamp(c.a, c.s));
        },
        .width, .distance_to => {
            // `width` returns `hi - lo` and `distanceTo` returns a
            // difference, so both are VALUES and not bounds, and both are
            // judged by the two-sided check: an answer too large is as wrong
            // as one too small, and a magnitude rule that only asks "is it
            // big enough" lets +inf through for a true 0.5 and lets 1e9
            // through for the same. What the one-sided rule was there for
            // is the overflow at the top of the range, and `exactWidth`
            // now puts that on the right footing by making the reference
            // the infinity the format itself returns there.
            const x = got.scalarOrNull() orelse return false;
            const want = if (c.op == .width) exactWidth(c.a) else exactDistanceTo(c.a, c.s);
            return scalarOk(x, want);
        },
        .contains, .overlaps, .subset_of, .eql, .ne, .lt, .le, .gt, .ge => {
            const f = got.flagOrNull() orelse return false;
            return predicateHolds(c.op, c, f);
        },
        .add, .sub, .translate, .expand => {
            // The four whose extremum is a sum, judged against the two
            // `f64` operands of that sum and NOT against an `f128` of it.
            // The difference is a whole answer: `floatMax - 3` and
            // `1e300 - 1e-300` both round to their larger operand in `f128`,
            // and a reference that took the rounded value would clear a
            // bound sitting exactly on the operand.
            const g = got.intervalOrNull() orelse return false;
            if (g.lo > g.hi) return false;
            return sumBound(c).?.holds(g);
        },
        .scale => {
            // The affine extrema are five-term sums of the ORIGINAL f64
            // endpoints and of products of them, so the comparison is the
            // sign of their exact expansion and never a rounded midpoint.
            // The difference is a whole answer here rather than a margin:
            // `(A + B) / 2` in `f128` drops a residual as small as half an
            // ulp of the centre, and a reference that formed the midpoint
            // first would clear a bound sitting on the wrong side of the
            // truth by exactly that much.
            const g = got.intervalOrNull() orelse return false;
            return boundedScaleHolds(c.a, c.s, g);
        },
        .hull, .neg, .abs, .sqr, .mul, .floor, .ceil, .trunc, .round, .cbrt => {
            const g = got.intervalOrNull() orelse return false;
            if (g.lo > g.hi) return false;
            const r = exact(c) orelse return false;
            return loEncloses(r, g.lo) and hiEncloses(r, g.hi);
        },
    }
}

/// Why a drawn case cannot be judged, when it cannot.
const Screen = enum {
    ok,
    /// A NaN or a non-finite operand or scalar. The oracle states true
    /// extrema only for finite `f64` endpoints, so these are set aside and
    /// counted rather than silently dropped or misreported as a defect.
    nonfinite,
    /// The case falls in a documented precondition or a documented
    /// limitation, neither of which is a property the oracle may assume
    /// away. `expand` needs `margin >= -(hi - lo) / 2`, which is a
    /// precondition of the operation. `midpoint` is the one limitation:
    /// the package says its sum of the two endpoints overflows for a box
    /// at the top of the range where the centre does not, and an
    /// operation that documents itself as not a sound place to start from
    /// is not judged as though it were one.
    ///
    /// `div` and `recip` are NOT here, which is the point of this entry.
    /// They used to be, on the ground that a divisor touching zero makes
    /// the true image unbounded. It does, and the library has a
    /// documented answer for it, and an answer that is documented is a
    /// contract value to be checked rather than a case to be set aside.
    precondition,
};

fn screen(raw: Raw) Screen {
    const values = [5]f64{ raw.a[0], raw.a[1], raw.b[0], raw.b[1], raw.s };
    for (values) |v| {
        if (std.math.isNan(v) or !std.math.isFinite(v)) return .nonfinite;
    }
    switch (raw.op) {
        .expand => {
            // The precondition is a real inequality, so it is decided on
            // the real through the exact three-term sign and never on a
            // width rounded to one `f128`. A rounded width lets through
            // margins the operation does not actually accept, and the
            // interval it then returns is inverted — an abort, not a
            // failure report, and one that takes the rest of the binary
            // with it.
            if (!marginAdmissible(raw.a[0], raw.a[1], raw.s)) return .precondition;
        },
        .midpoint => {
            // The exact centre of a box spanning the frontier is finite
            // even where the f64 sum of its endpoints is not, and the
            // package documents that gap. The exact sum is never
            // infinite in f128 for two f64 operands, so an infinite f64
            // sum is exactly the documented case and nothing else.
            if (std.math.isInf(raw.a[0] + raw.a[1])) return .precondition;
        },
        else => {},
    }
    return .ok;
}

const Tally = struct {
    op: Op,
    checked: usize = 0,
    failures: usize = 0,
    shown: usize = 0,
    skipped_nonfinite: usize = 0,
    skipped_precondition: usize = 0,
};

fn showInterval(i: Interval) void {
    std.debug.print("      [{e: <26} , {e: <26} ]  bits 0x{X:0>16} 0x{X:0>16}\n", .{
        i.lo, i.hi, @as(u64, @bitCast(i.lo)), @as(u64, @bitCast(i.hi)),
    });
}

fn showValue(v: Value) void {
    switch (v) {
        .interval => |i| showInterval(i),
        .maybe_interval => |m| {
            if (m) |i| {
                showInterval(i);
            } else {
                std.debug.print("      null, which claims the result is empty in the reals\n", .{});
            }
        },
        .scalar => |x| std.debug.print("      {e}  (bits 0x{X:0>16})\n", .{ x, @as(u64, @bitCast(x)) }),
        .flag => |b| std.debug.print("      {s}\n", .{if (b) "true" else "false"}),
    }
}

fn showCase(c: Case, got: Value) void {
    std.debug.print("    case: {s}\n", .{c.op.label()});
    std.debug.print("      a =\n", .{});
    showInterval(c.a);
    if (c.op.usesSecond()) {
        std.debug.print("      b =\n", .{});
        showInterval(c.b);
    }
    if (c.op.usesScalar()) {
        std.debug.print("      s = {e}  (bits 0x{X:0>16})\n", .{ c.s, @as(u64, @bitCast(c.s)) });
    }
    std.debug.print("      returned =\n", .{});
    showValue(got);
}

/// Signed distance from a returned bound to the exact extremum it is
/// meant to bound, in ULPs of the bound. Positive is slack, negative is a
/// bound that has cut inside the true image. It is printed with every
/// failure so a claim of "one ULP too tight" can be checked from the log
/// instead of re-derived, which matters because a sub-ULP miss is exactly
/// the kind of finding an oracle gets accused of inventing.
fn gapUlp(got: f64, want: f128) f128 {
    const g = ex(got);
    const scale = @max(@abs(g), @abs(want));
    if (std.math.isNan(g) or scale == 0.0) return 0.0;
    return (g - want) * 0x1p52 / scale;
}

/// The diagnosis for a sum reference: the two `f64` operands of each end,
/// the `f128` head their sum rounds to, and the residual the rounding
/// dropped.
///
/// Both halves are printed, and that is the point rather than a flourish.
/// The head alone is what a rounded reference would have compared against,
/// so a log carrying only the head would be the argument this file exists
/// to refute rather than evidence for it.
fn reportSum(s: SumBound, got: Value) void {
    const g = got.intervalOrNull();
    const lo = twoSum(s.alo, s.blo);
    const hi = twoSum(s.ahi, s.bhi);
    std.debug.print("      true lo = {e} + {e} = {e} + {e} exactly\n", .{ s.alo, s.blo, lo.s, lo.err });
    std.debug.print("      true hi = {e} + {e} = {e} + {e} exactly\n", .{ s.ahi, s.bhi, hi.s, hi.err });
    if (g) |x| {
        if (!s.lowerOk(x.lo)) {
            std.debug.print("      lower bound is ABOVE the true minimum and excludes it\n", .{});
        }
        if (!s.upperOk(x.hi)) {
            std.debug.print("      upper bound is BELOW the true maximum and excludes it\n", .{});
        }
    }
}

/// The diagnosis for a bounded `scale`: the five terms of each end, and which
/// side cut inside the truth.
///
/// No midpoint and no half-width is printed, because there is no such number
/// to print and printing a rounded one is the mistake this reference was
/// written to avoid. What a reader gets instead is the formula, the original
/// operands, and the verdict of the exact comparison.
fn reportScale(s: ScaleBound, got: Value) void {
    const g = got.intervalOrNull();
    std.debug.print("      A = {e}, B = {e}, G = |factor| = {e}\n", .{ s.lo, s.hi, s.mag });
    std.debug.print("      true lo = (A + B + G*A - G*B) / 2, compared as the sign of that minus 2*lo and never formed\n", .{});
    std.debug.print("      true hi = (A + B - G*A + G*B) / 2, compared as the sign of that minus 2*hi and never formed\n", .{});
    if (g) |x| {
        if (!s.lowerOk(x.lo)) {
            std.debug.print("      lower bound is ABOVE the true minimum and excludes it\n", .{});
        }
        if (!s.upperOk(x.hi)) {
            std.debug.print("      upper bound is BELOW the true maximum and excludes it\n", .{});
        }
    }
}

fn report(c: Case, got: Value, t: *Tally) void {
    t.failures += 1;
    if (t.shown >= max_detail) return;
    t.shown += 1;
    std.debug.print("    FAIL {s}: the answer is not what the oracle requires\n", .{c.op.label()});
    showCase(c, got);
    if (got.intervalOrNull()) |g| {
        if (std.math.isNan(g.lo) or std.math.isNan(g.hi)) {
            // A NaN compares false against everything, so it would sail
            // past both order tests and then be quoted with a gap of zero,
            // which reads as "the bound sits exactly on the extremum". It
            // is named out instead, because a NaN bound is not a bound.
            std.debug.print("      a returned bound is NaN, which encloses nothing\n", .{});
        }
        if (g.lo > g.hi) {
            std.debug.print("      the returned interval is inverted: lo > hi\n", .{});
        }
    }
    if (c.op == .scale) {
        reportScale(.{ .lo = c.a.lo, .hi = c.a.hi, .mag = @abs(c.s) }, got);
    } else if (sumBound(c)) |s| {
        reportSum(s, got);
    } else if (exact(c)) |r| {
        std.debug.print("      exact lo = {e}\n", .{r.lo});
        std.debug.print("      exact hi = {e}\n", .{r.hi});
        const g = got.intervalOrNull();
        if (r.lo_beyond) {
            std.debug.print("      the true minimum is a real past the end of the f64 range, so a returned lo of +inf excludes it\n", .{});
        } else if (g != null and !lowerOk(r.lo, g.?.lo)) {
            var buf: [64]u8 = undefined;
            const gap = if (std.math.isNan(g.?.lo))
                ""
            else
                std.fmt.bufPrint(&buf, " : {e} ULP", .{gapUlp(g.?.lo, r.lo)}) catch " : ?";
            std.debug.print("      lower bound is ABOVE the true minimum and excludes it{s}\n", .{gap});
        }
        if (r.hi_beyond) {
            std.debug.print("      the true maximum is a real past the end of the f64 range, so a returned hi of -inf excludes it\n", .{});
        } else if (g != null and !upperOk(r.hi, g.?.hi)) {
            var buf: [64]u8 = undefined;
            const gap = if (std.math.isNan(g.?.hi))
                ""
            else
                std.fmt.bufPrint(&buf, " : {e} ULP", .{gapUlp(g.?.hi, r.hi)}) catch " : ?";
            std.debug.print("      upper bound is BELOW the true maximum and excludes it{s}\n", .{gap});
        }
    } else {
        std.debug.print("      the oracle for this operation is {s}\n", .{c.op.oracle()});
    }
}

fn summary(t: Tally, tag: []const u8) void {
    std.debug.print("  {s}{s}: {d} checked, {d} FAILED, {d} skipped non-finite, {d} skipped precondition\n", .{
        tag, t.op.label(), t.checked, t.failures, t.skipped_nonfinite, t.skipped_precondition,
    });
    if (t.failures > t.shown) {
        std.debug.print("  {s}: {d} further failures not printed individually\n", .{ t.op.label(), t.failures - t.shown });
    }
}

fn fuzz(op: Op) Tally {
    var prng = std.Random.DefaultPrng.init(streamSeed(op));
    const r = prng.random();
    var t: Tally = .{ .op = op };
    for (0..fuzz_cases) |_| {
        const raw = drawRaw(op, r);
        switch (screen(raw)) {
            .nonfinite => {
                t.skipped_nonfinite += 1;
                continue;
            },
            .precondition => {
                t.skipped_precondition += 1;
                continue;
            },
            .ok => {},
        }
        t.checked += 1;
        const c = buildCase(raw);
        const got = apply(c);
        if (!holds(c, got)) report(c, got, &t);
    }
    summary(t, "");
    return t;
}

// ---------------------------------------------------------------------------
// The frontier sweep
// ---------------------------------------------------------------------------

// Everything above draws its operands from a table of MAGNITUDES and screens
// a non-finite one out before the oracle sees it, so 35 sweeps of 8,000
// cases each judged the library on finite inputs and not one of them reached
// an infinity. The only infinity coverage the tree had before this section
// was `lo <= hi`, which asks nothing of the answer, so the shapes here are
// directed rather than drawn and the count is a couple of thousand rows
// rather than another eight thousand per operation.
//
// What an infinite endpoint STANDS FOR is fixed by the approved contract
// rather than chosen here, which is the whole reason this section can judge
// thirteen operations instead of seven. A canonical `lo` is never `+inf` and
// a canonical `hi` is never `-inf`, so `init(+inf,+inf)` is the closed
// overflow ray `[floatMax,+inf]` and its mirror `[-inf,-floatMax]`, a finite
// bound is an attained real, and an infinite one is a direction the set runs
// off in. That is the same UNBOUNDED MAGNITUDE reading `rounding.zig` and
// `src/interval.zig` already stated, and the only thing that changed is that
// it is no longer a question this file has an opinion about.
//
// Every reference below is the true image of that set. An attained end is
// formed in `f128` from the CLOSED end of each ray — floatMax for `+inf`,
// -floatMax for `-inf` — and the directions the image runs off in are
// carried beside it. Two exactness rules follow from the rest of this file
// rather than from anything new:
//
//   * An end that is a SUM of two `f64`s is held as its two operands and
//     compared through the TwoSum residual. `floatMax - 3` is the case that
//     needs every one of the 971 binades between the two operands, and
//     `f128` carries 113 significand bits, so it rounds to its larger
//     operand. (`2 * floatMax` is the other sum that shows up here and it is
//     NOT in the same position: doubling moves the exponent and not the
//     significand, so `2 * floatMax` is exactly an `f128`.)
//   * An attained end that has left the `f64` range sets the matching
//     `_beyond` flag on the `Range`, which is the only thing in this file
//     that sets either. The extremum there is a real rather than an
//     infinity, so the saturated `f64` at the frontier bounds it and an
//     infinity pointing the other way does not.

/// The directed operand shapes, named as endpoint pairs rather than as
/// intervals, because two of them are not intervals. `Interval.init`
/// requires lo <= hi and traps on a pair that breaks it, which is the
/// library's refusal and is recorded rather than worked around.
///
/// SEVEN of the sixteen are wholly finite, and they are here for a reason
/// that has nothing to do with infinity: a sweep made only of rays pairs
/// every operand with an unbounded one, so the finite corner of `div`,
/// `mul`, `hull` and `intersect` is never the operand that decides the
/// answer, and `scale`'s centre and identity cases are unreachable because
/// every operand there has no centre at all. A frontier sweep that cannot
/// reach a finite quotient has not reached the frontier of anything.
///
/// The ORDER is deliberate and the report counts it. The finite shapes come
/// first, then the half-lines, then the degenerate rays, and the whole line
/// last. An operation that aborts on one of the shapes at the end takes the
/// whole test binary with it, so the shapes most likely to abort are the
/// ones whose rows are gathered after everything else has been judged.
const Shape = enum {
    /// [3, 3]: a finite point, so a quotient corner and a scale centre
    /// both have somewhere finite to be.
    point_finite,
    /// [1, 2]: the narrowest non-degenerate finite box there is.
    narrow,
    /// [-3, -1]: wholly below zero, which the sign reasoning has to
    /// separate from a box that reaches it.
    all_neg,
    /// [-1, 1]: finite and straddling zero, so the zero floor of `abs` and
    /// `sqr` and the whole-line answer of a zero-reaching divisor are both
    /// reached by a FINITE box rather than only by a ray.
    straddle,
    /// [0, 0]: the point zero itself.
    origin,
    /// [-floatMax, floatMax]: the widest BOUNDED interval there is. It is
    /// the shape `expand(-inf)` is refused for, and the only one where a
    /// finite margin of -floatMax is admissible.
    wide,
    /// [min_subnormal, 4*min_subnormal]: a wholly finite subnormal box,
    /// where a quotient corner is a value `f64` cannot hold and the repair
    /// has to answer for it.
    subnormal,
    /// [3, inf]: a ray running out past floatMax from a finite end.
    up_finite,
    /// [-inf, 3]: the same from below.
    low_finite,
    /// [-inf, -3]: a ray with no zero anywhere in it, which is the shape a
    /// quotient's sign reasoning has to separate from `low_finite`.
    down_finite,
    /// [-3, inf]: the ray that spans zero as it runs out.
    spanning_up,
    /// [inf, inf]: the canonical constructor's positive overflow ray.
    pos_point,
    /// [-inf, -inf]: its negative mirror.
    neg_point,
    /// [-inf, inf]: the whole line, against itself and against every shape.
    line,
    /// {inf, -inf}: lo > hi, so not an interval.
    inverted_ends,
    /// {3, -inf}: the same refusal with a finite end in it.
    inverted_finite,

    fn label(s: Shape) []const u8 {
        return switch (s) {
            .point_finite => "[3,3]",
            .narrow => "[1,2]",
            .all_neg => "[-3,-1]",
            .straddle => "[-1,1]",
            .origin => "[0,0]",
            .wide => "[-floatMax,floatMax]",
            .subnormal => "[min_subnormal,4*min_subnormal]",
            .up_finite => "[3,inf]",
            .low_finite => "[-inf,3]",
            .down_finite => "[-inf,-3]",
            .spanning_up => "[-3,inf]",
            .pos_point => "[inf,inf]",
            .neg_point => "[-inf,-inf]",
            .line => "[-inf,inf]",
            .inverted_ends => "{inf,-inf}",
            .inverted_finite => "{3,-inf}",
        };
    }

    fn ends(s: Shape) [2]f64 {
        return switch (s) {
            .point_finite => .{ 3.0, 3.0 },
            .narrow => .{ 1.0, 2.0 },
            .all_neg => .{ -3.0, -1.0 },
            .straddle => .{ -1.0, 1.0 },
            .origin => .{ 0.0, 0.0 },
            .wide => .{ -std.math.floatMax(f64), std.math.floatMax(f64) },
            .subnormal => .{ min_subnormal, 4.0 * min_subnormal },
            .up_finite => .{ 3.0, inf64 },
            .low_finite => .{ neg_inf64, 3.0 },
            .down_finite => .{ neg_inf64, -3.0 },
            .spanning_up => .{ -3.0, inf64 },
            .pos_point => .{ inf64, inf64 },
            .neg_point => .{ neg_inf64, neg_inf64 },
            .line => .{ neg_inf64, inf64 },
            .inverted_ends => .{ inf64, neg_inf64 },
            .inverted_finite => .{ 3.0, neg_inf64 },
        };
    }

    /// The two endpoints as an interval, which is only meaningful for a shape
    /// that `ordered` accepts.
    ///
    /// This is what a CALLER WRITES — `Interval.init(inf, inf)` and no
    /// normalisation on this side — and it has to stay that way. The
    /// contract says `init(+inf,+inf)` supplies the closed overflow ray, and
    /// a test that supplied the ray itself would be testing the sweep rather
    /// than the constructor: `abs`, `neg`, `mul` and the rest would be green
    /// against a tree whose `init` still hands back a degenerate point at
    /// `+inf`, and the six operations the old table withheld would stay
    /// unjudged in a quieter way than before. The operand is therefore built
    /// here and the canonical reading is derived in `canonical`, which never
    /// looks at what `init` returned.
    fn interval(s: Shape) Interval {
        return Interval.init(s.ends()[0], s.ends()[1]);
    }

    /// What the contract says this shape IS, as the closed ends it attains
    /// and the two directions it runs off in.
    ///
    /// Derived from the shape's DECLARED ends and never from the interval
    /// `init` handed back. That independence is the whole of the design: an
    /// oracle built from the operand reads the implementation's answer back
    /// to itself, and a sweep whose references move with the code under test
    /// cannot go red.
    fn canonical(s: Shape) Canonical {
        const e = s.ends();
        return .{
            .lo = closedEnd(e[0]),
            .hi = closedEnd(e[1]),
            .lo_unbounded = e[0] == neg_inf64,
            .hi_unbounded = e[1] == inf64,
        };
    }

    /// False for the two shapes `Interval.init` refuses.
    fn ordered(s: Shape) bool {
        return switch (s) {
            .inverted_ends, .inverted_finite => false,
            else => true,
        };
    }

    /// True when either end runs off to an infinity, so the box has no
    /// finite midpoint and `scale`'s documented affine formula has nothing
    /// to evaluate. This replaces the old `both_open`, which asked the same
    /// question for the wrong subset and was the reason three shapes were
    /// skipped: a box with ONE unbounded end has no finite midpoint
    /// either, so skipping only the two-ended ones decided nothing.
    fn unbounded(s: Shape) bool {
        const e = s.ends();
        return e[0] == neg_inf64 or e[1] == inf64;
    }

    /// Whether `expand` would accept `margin` on this bounded shape, decided
    /// on the exact real rather than on a rounded width.
    ///
    /// The old shape of this question compared against `(hi - lo) / 2` as one
    /// `f128`, and that is not the width: `floatMax - min_subnormal` rounds
    /// to `floatMax` in `f128` just as it does in `f64`, so a margin decided
    /// that way can be one that the operation does not accept. The width is
    /// never formed here either — `marginAdmissible` decides the inequality.
    fn admitsMargin(s: Shape, margin: f64) bool {
        const e = s.ends();
        return marginAdmissible(closedEnd(e[0]), closedEnd(e[1]), margin);
    }
};

/// Every shape, in the order `Shape` documents: the finite ones first, the
/// half-lines, then the degenerate rays, and the whole line last.
const frontier_shapes = [_]Shape{
    .point_finite,
    .narrow,
    .all_neg,
    .straddle,
    .origin,
    .wide,
    .subnormal,
    .up_finite,
    .low_finite,
    .down_finite,
    .spanning_up,
    .pos_point,
    .neg_point,
    .line,
    .inverted_ends,
    .inverted_finite,
};

/// The scalars the frontier carries through the same shapes.
///
/// Zero and the two units are here because `scale`'s contract turns on
/// them: a factor of zero is the centre case and |factor| = 1 is the
/// identity case, and neither is reachable if the only finite scalars are
/// 3 and -3. The two of opposite large sign are the shift-by-the-wrong-sign
/// case, and the two infinite ones are where a shift or a widening stops
/// being an arithmetic operation at all.
const frontier_scalars = [_]f64{ 0.0, 1.0, -1.0, 3.0, -3.0, inf64, neg_inf64 };

/// The closed end of the ray an endpoint stands for, as an `f64`: floatMax
/// for `+inf`, -floatMax for `-inf`, and the value itself otherwise.
fn closedEnd(x: f64) f64 {
    if (x == inf64) return std.math.floatMax(f64);
    if (x == neg_inf64) return -std.math.floatMax(f64);
    return x;
}

/// What a frontier shape IS under the approved contract, as the two ends it
/// attains and the two directions it runs off in.
///
/// The attained ends are the CLOSED ends of the rays — floatMax for a `+inf`
/// end, -floatMax for a `-inf` one — because a canonical `lo` is never `+inf`
/// and a canonical `hi` is never `-inf`, so `init(+inf,+inf)` is the closed
/// overflow ray `[floatMax,+inf]` and its mirror is `[-inf,-floatMax]`. The
/// two flags say which of the two ends is a direction rather than a value.
///
/// This type is what keeps the oracle independent: it is built from a
/// shape's DECLARED ends, and no reference below ever reads an interval
/// `Interval.init` returned.
const Canonical = struct {
    /// The real the low end attains, or the closed end of the ray it runs
    /// off below from. Meaningful only when `lo_unbounded` is false.
    lo: f64,
    /// The mirror for the high end.
    hi: f64,
    lo_unbounded: bool,
    hi_unbounded: bool,

    /// The set as a `Span`, for the references that are built out of spans.
    fn span(c: Canonical) Span {
        return .{
            .lo = ex(c.lo),
            .hi = ex(c.hi),
            .lo_open = c.lo_unbounded,
            .hi_open = c.hi_unbounded,
        };
    }

    /// Whether the SET these canonical ends denote contains zero. BOTH ends
    /// decide it, not the low one alone: `[-3,-1]` has a low end below zero
    /// and does not reach it, and reading only the low end makes the whole
    /// negative quadrant look like a divisor that straddles zero.
    ///
    /// An unbounded end carries the infinity it runs off to, so comparing
    /// the stored `lo` and `hi` against zero already answers the ray cases:
    /// `[-inf, -3]` compares as `-inf <= 0` and `-3 >= 0`, which is false,
    /// and `[-inf, 3]` is true, which is right.
    fn reachesZero(c: Canonical) bool {
        return c.lo <= 0.0 and c.hi >= 0.0;
    }

    fn isLine(c: Canonical) bool {
        return c.lo_unbounded and c.hi_unbounded;
    }
};

/// The reflection of a canonical set, with the two directions swapping as
/// well as the two ends: a ray running off below reflects to one running
/// off above. Reflecting the ends alone would turn the whole line into the
/// point `floatMax`, which is the bug the contract's `neg` line exists to
/// prevent and the one the removed bit-pattern test used to pin.
fn negated(c: Canonical) Canonical {
    return .{
        .lo = -c.hi,
        .hi = -c.lo,
        .lo_unbounded = c.hi_unbounded,
        .hi_unbounded = c.lo_unbounded,
    };
}

/// The canonical set as the `Range` the enclosure rules read: an unbounded
/// end becomes the infinity, and an attained end that has left the `f64`
/// range sets the flag saying so.
fn range(c: Canonical) Range {
    const fmax = ex(std.math.floatMax(f64));
    return .{
        .lo = if (c.lo_unbounded) neg_inf128 else ex(c.lo),
        .hi = if (c.hi_unbounded) inf128 else ex(c.hi),
        .lo_beyond = !c.lo_unbounded and ex(c.lo) > fmax,
        .hi_beyond = !c.hi_unbounded and ex(c.hi) < -fmax,
    };
}

/// The low end of a set as an `f128`, with an unbounded one as -inf. The
/// single place the two are combined, so `hull` and `intersect` cannot
/// disagree about what an open end is worth.
fn lowOf(c: Canonical) f128 {
    return if (c.lo_unbounded) neg_inf128 else ex(c.lo);
}

/// The mirror of `lowOf` for the high end.
fn highOf(c: Canonical) f128 {
    return if (c.hi_unbounded) inf128 else ex(c.hi);
}

/// One ray: the real it runs from and the direction it runs in.
const Ray = struct {
    c: f128,
    up: bool,
};

/// One endpoint of a frontier operand as the SET it stands for: either the
/// single value, or a ray running outward from it.
const End = union(enum) {
    value: f128,
    ray: Ray,
};

fn endpointOf(x: f64) End {
    if (x == inf64) return .{ .ray = .{ .c = ex(std.math.floatMax(f64)), .up = true } };
    if (x == neg_inf64) return .{ .ray = .{ .c = -ex(std.math.floatMax(f64)), .up = false } };
    return .{ .value = ex(x) };
}

/// The extent of a set of reals at the frontier: the two ends it ATTAINS and
/// the directions it runs off in. The default is the whole line, which is
/// both the identity for `hull` and the answer for an image nothing bounds.
const Span = struct {
    lo: f128 = neg_inf128,
    hi: f128 = inf128,
    lo_open: bool = true,
    hi_open: bool = true,

    fn point(v: f128) Span {
        return .{ .lo = v, .hi = v, .lo_open = false, .hi_open = false };
    }

    /// A ray running from `c` out to one infinity. Every field named, because
    /// the defaults on the type are the two open flags and a partial literal
    /// here would leave the other one set, which is the whole line rather
    /// than the ray.
    fn ray(c: f128, up: bool) Span {
        return if (up)
            .{ .lo = c, .hi = inf128, .lo_open = false, .hi_open = true }
        else
            .{ .lo = neg_inf128, .hi = c, .lo_open = true, .hi_open = false };
    }

    fn hull(a: Span, b: Span) Span {
        return .{
            .lo = @min(a.lo, b.lo),
            .hi = @max(a.hi, b.hi),
            .lo_open = a.lo_open or b.lo_open,
            .hi_open = a.hi_open or b.hi_open,
        };
    }

    /// The `Range` the sweep checks against. An unbounded end becomes the
    /// infinity the enclosure rules already read (an image that runs off to
    /// -inf has no bound below it but -inf itself), and an attained end that
    /// has left the `f64` range sets the flag that says so.
    fn range(s: Span) Range {
        const fmax = ex(std.math.floatMax(f64));
        return .{
            .lo = if (s.lo_open) neg_inf128 else s.lo,
            .hi = if (s.hi_open) inf128 else s.hi,
            .lo_beyond = !s.lo_open and s.lo > fmax,
            .hi_beyond = !s.hi_open and s.hi < -fmax,
        };
    }
};

/// The two endpoints of a canonical operand as the SETS they stand for: the
/// attained end as a point, and an open end as a ray running out from the
/// closed end. This is the only place a frontier operand is read as a set,
/// and it is the whole of what the `+inf` reading costs: `[inf,inf]` is a
/// ray out of floatMax and not a point at `+inf`.
fn canonicalEnds(c: Canonical) [2]End {
    return .{
        if (c.lo_unbounded) .{ .ray = .{ .c = neg_inf128, .up = false } } else .{ .value = ex(c.lo) },
        if (c.hi_unbounded) .{ .ray = .{ .c = inf128, .up = true } } else .{ .value = ex(c.hi) },
    };
}

/// The true image of `a * b`: the hull of the four corner SETS. Taking the
/// hull of the sets and not of four numbers is the whole of the difference
/// at an infinity — a corner pair of rays has no value to take the min of,
/// it has a ray, and the positive overflow ray times `[3,inf)` is
/// `[floatMax^2, inf)` rather than a single point at either end of it.
fn frontierMul(a: Canonical, b: Canonical) Range {
    const ae = canonicalEnds(a);
    const be = canonicalEnds(b);
    // The first corner rather than the whole line. `Span`'s default is the
    // whole line, which is the right answer for an image nothing bounds and
    // the wrong IDENTITY for a hull, because it swallows the first corner
    // and turns every product back into the line.
    var out = productSet(ae[0], be[0]);
    for (ae) |x| {
        for (be) |y| {
            out = Span.hull(out, productSet(x, y));
        }
    }
    return out.range();
}

/// One corner of a product as a set. Two endpoints are each a point or a ray,
/// and the product of any two of them is a point or a ray: a nonzero value
/// stretches a ray in its own direction and a second ray reverses it exactly
/// when the two disagree.
///
/// The one collapse is a zero factor, and it is the same exception
/// `src/interval.zig` makes in cornerProduct for the same reason: zero times
/// an unbounded magnitude is zero, and no unboundedness in the other factor
/// reaches past that. It is a fact about reals, which is why it survives
/// being a value IEEE declines to compute.
fn productSet(p: End, q: End) Span {
    if ((p == .value and p.value == 0.0) or (q == .value and q.value == 0.0)) return Span.point(0.0);
    return switch (p) {
        .value => |px| switch (q) {
            .value => |qy| Span.point(px * qy),
            .ray => |r| stretched(px, r),
        },
        .ray => |r| switch (q) {
            .value => |qy| stretched(qy, r),
            .ray => |s| Span.ray(r.c * s.c, r.up == s.up),
        },
    };
}

/// A nonzero value times a ray: the ray scaled, running the way the sign of
/// the value sends it. A zero value is the collapse and is ruled out by the
/// caller, because a bound here has no direction to point.
fn stretched(v: f128, r: Ray) Span {
    return Span.ray(v * r.c, if (v > 0.0) r.up else !r.up);
}

/// The true image of `abs` and of `sqr`: both are magnitude maps, so an
/// infinite endpoint is an unbounded MAGNITUDE rather than a value, and the
/// image runs off to +inf exactly when an end does.
///
/// The ray is added only in that case, and that condition is the whole of a
/// bug the finite frontier shapes caught. Unconditionally unioning a
/// `+inf` ray is right for every shape that HAS an infinite end and wrong
/// for every shape that does not: it asks `abs([3,3])` to enclose
/// `[3, +inf)`, and the true image of a bounded box under a magnitude map
/// is bounded. The old version was never wrong only because every shape it
/// met had an infinite end, which is the same reason a sweep of nothing but
/// rays finds nothing else either.
///
/// The attained end is the smaller of the two attained magnitudes, or
/// exactly zero where the operand spans it — the zero floor, since a point
/// of the operand maps to zero itself and no bound above it can be tighter.
fn frontierMagnitude(a: Canonical, p: f128, q: f128) Range {
    // Both ends, and an unbounded end carries the infinity it runs off to,
    // so `[-inf, -3]` compares as `-inf <= 0` against `-3 >= 0` and answers
    // false. Oring in `a.lo_unbounded` instead called that box zero-spanning:
    // it has an unbounded MAGNITUDE, not a zero, and the false floor put 0
    // under `abs([-inf,-3])`, whose true image is `[3, +inf)`.
    const spans_zero = a.lo <= 0.0 and a.hi >= 0.0;
    const attained = Span.point(if (spans_zero) 0.0 else @min(p, q));
    if (!a.lo_unbounded and !a.hi_unbounded) return attained.range();
    return Span.hull(attained, Span.ray(@max(p, q), true)).range();
}

fn frontierAbs(a: Canonical) Range {
    return frontierMagnitude(a, @abs(ex(a.lo)), @abs(ex(a.hi)));
}

/// The true image of `sqr`: the same two attained magnitudes, squared
/// rather than taken, and the same zero floor on an operand that spans
/// zero. The two squares of `f64` endpoints need 106 significand bits and
/// `f128` carries 113, so they are the true squares.
fn frontierSqr(a: Canonical) Range {
    return frontierMagnitude(a, ex(a.lo) * ex(a.lo), ex(a.hi) * ex(a.hi));
}

/// Containment of the quotient set at the frontier, by the same
/// cross-multiplication the finite sweep uses and for the same reason: a
/// quotient is not exact even in `f128`, so no quotient is ever evaluated
/// here either.
///
/// Every requirement below is either an infinity or a cross-product of two
/// `f64`s, and both are exact. What the old version of this function did
/// NOT do is account for the direction a ray runs in: it read an infinite
/// divisor end at its closed value and stopped, which accepts a bound that
/// stops short of the zero the true quotient set accumulates at. The rules
/// are these, and each one is a statement about reals.
///
///   * A divisor that REACHES zero has a quotient set unbounded on both
///     sides, so the answer has to be the whole line. That is also the
///     answer `div` documents, which makes it a contract value rather than
///     a precondition. A divisor of exactly zero has NO quotient at all —
///     the image is empty and every interval encloses it.
///   * A divisor end that RUNS OFF sends the quotient to zero, from
///     whichever side the dividend is on, so the set has zero as an
///     accumulation point and the answer has to reach it: `got.lo <= 0`
///     and `got.hi >= 0`. `1 / inf` is zero in IEEE while the true
///     quotient of a finite number by an unbounded one is a ray with that
///     zero as its infimum, which is the distinction this rule exists for.
///   * A dividend end that RUNS OFF takes the quotient off with it, in the
///     direction the divisor's sign sends it, so that side of the answer
///     has to be the matching infinity.
///   * Every corner where BOTH ends are ATTAINED is checked by
///     `quotientHolds`, unchanged. A corner where either end is a ray is
///     already covered by the two rules above, and feeding a ray into
///     `quotientHolds` would ask for the wrong thing: it demands an
///     infinite bound where a ray only demands zero.
fn frontierQuotientHolds(num: Canonical, den: Canonical, got: Interval) bool {
    if (std.math.isNan(got.lo) or std.math.isNan(got.hi)) return false;
    if (got.lo > got.hi) return false;
    // The empty set: the divisor has no non-zero member, so there is no
    // quotient to enclose and nothing is required.
    if (!den.lo_unbounded and !den.hi_unbounded and den.lo == 0.0 and den.hi == 0.0) return true;
    if (den.reachesZero()) return got.lo == neg_inf64 and got.hi == inf64;
    // A divisor wholly above zero, or wholly below it. The sign is what
    // sends a dividend's ray to one infinity rather than the other.
    const up = den.lo > 0.0;
    if (num.hi_unbounded) {
        if (up) {
            if (got.hi != inf64) return false;
        } else if (got.lo != neg_inf64) return false;
    }
    if (num.lo_unbounded) {
        if (up) {
            if (got.lo != neg_inf64) return false;
        } else if (got.hi != inf64) return false;
    }
    if (den.hi_unbounded and got.lo > 0.0) return false;
    if (den.lo_unbounded and got.hi < 0.0) return false;
    // The corners where BOTH ends are attained, and only those. `Canonical`
    // leaves an unbounded end's value in place but flagged, so the loop
    // skips a flagged end: a ray corner has no real to cross-multiply, and
    // the two rules above already say exactly what it requires.
    for ([_]f64{ num.lo, num.hi }, [_]bool{ num.lo_unbounded, num.hi_unbounded }) |x, x_ray| {
        if (x_ray) continue;
        for ([_]f64{ den.lo, den.hi }, [_]bool{ den.lo_unbounded, den.hi_unbounded }) |y, y_ray| {
            if (y_ray or y == 0.0) continue;
            if (!quotientHolds(x, y, got)) return false;
        }
    }
    return true;
}

/// The `scale` reference for an UNBOUNDED input, which is where the
/// documented formula `M = (lo + hi) / 2` stops deciding anything: with one
/// end running off there is no finite midpoint, and with both there never
/// was one. The approved contract settles it by the factor alone.
///
///   * `|factor| == 1` is the identity for every centre, so the image is
///     the operand and the answer has to BE the operand. Containment would
///     be the weaker check and it is refused on purpose: the whole line
///     encloses the operand, so a containment rule here would pass an
///     answer that gives up on the one case the factor fully decides.
///   * every other factor returns the whole line, the contract's own
///     conservative answer. `m + g (x - m)` runs off with `x` and comes
///     back the other way if it comes back at all, so the line encloses
///     the image for every centre a caller might have meant, and a factor
///     of zero is included in that rather than special-cased: the centre it
///     would return does not exist.
fn unboundedScaleHolds(a: Canonical, factor: f64, got: Interval) bool {
    if (@abs(ex(factor)) != 1.0) return got.lo == neg_inf64 and got.hi == inf64;
    // The identity, so the answer has to BE the operand — read as the set
    // the contract defines rather than as the pair of `f64` the caller
    // happened to write, so that a constructor which normalises
    // `[floatMax,+inf]` and one which leaves `{inf,inf}` are told apart.
    if (std.math.isNan(got.lo) or std.math.isNan(got.hi)) return false;
    if (got.lo > got.hi) return false;
    if (a.lo_unbounded) {
        if (got.lo != neg_inf64) return false;
    } else if (got.lo != a.lo) return false;
    if (a.hi_unbounded) {
        if (got.hi != inf64) return false;
    } else if (got.hi != a.hi) return false;
    return true;
}

/// The exact image of an operation whose two ends are each the SUM of two
/// frontier operand ends.
///
/// The two `f64` operands of each end are kept apart from the two flags
/// saying whether that end runs off, because an end that runs off has no
/// attained extremum to compare against at all: it is the whole ray, and
/// only the matching infinity encloses it. An attained end is a sum of two
/// `f64`s and goes through the residual comparator, for the reason the header
/// gives: `floatMax - 3` is a real no `f128` can name and it rounds to
/// `floatMax`, which is a real `f128` can name and which is therefore a
/// perfectly wrong answer to compare against.
const FrontierSum = struct {
    alo: f64,
    blo: f64,
    ahi: f64,
    bhi: f64,
    /// True when the image runs off to -inf, so `lo` must be -inf.
    lo_unbounded: bool,
    /// True when the image runs off to +inf, so `hi` must be +inf.
    hi_unbounded: bool,

    fn lowerOk(f: FrontierSum, glo: f64) bool {
        if (std.math.isNan(glo)) return false;
        if (f.lo_unbounded) return glo == neg_inf64;
        return sumLeq(glo, f.alo, f.blo);
    }

    fn upperOk(f: FrontierSum, ghi: f64) bool {
        if (std.math.isNan(ghi)) return false;
        if (f.hi_unbounded) return ghi == inf64;
        return sumGeq(ghi, f.ahi, f.bhi);
    }

    fn holds(f: FrontierSum, got: Interval) bool {
        if (got.lo > got.hi) return false;
        return f.lowerOk(got.lo) and f.upperOk(got.hi);
    }
};

/// The frontier image of `a + b`.
///
/// Addition never cancels, so the image runs off below exactly when one of
/// the two lower ends does and off above exactly when one of the two upper
/// ends does. The two rays of opposite sign meet and the sum is the whole
/// line, which is a fact about addition and not an accident of the
/// operands: the positive overflow ray plus the negative one reaches every
/// real, because one side has no lower bound and the other has no upper one.
fn frontierAdd(a: Canonical, b: Canonical) FrontierSum {
    return .{
        .alo = a.lo,
        .blo = b.lo,
        .ahi = a.hi,
        .bhi = b.hi,
        .lo_unbounded = a.lo_unbounded or b.lo_unbounded,
        .hi_unbounded = a.hi_unbounded or b.hi_unbounded,
    };
}

/// The frontier image of `a - b`, which is the reflected sum: the low end
/// takes `a.lo` against `b.hi` and the high one `a.hi` against `b.lo`.
///
/// The reflection is the whole of it, and it is what the old witness got
/// backwards. A `-inf` and a `+inf` are on OPPOSITE sides of a subtraction,
/// so they cannot cancel: an attained low end against a ray running off
/// below is `-inf`, not a number, and an attained low end CANNOT be
/// `+inf` — which is exactly what a canonical `[floatMax,+inf]` fixes. The
/// same-ray row is therefore the whole line, and it is the row that used to
/// abort.
fn frontierSub(a: Canonical, b: Canonical) FrontierSum {
    return .{
        .alo = a.lo,
        .blo = -b.hi,
        .ahi = a.hi,
        .bhi = -b.lo,
        .lo_unbounded = a.lo_unbounded or b.hi_unbounded,
        .hi_unbounded = a.hi_unbounded or b.lo_unbounded,
    };
}

/// The canonical reading of a scalar: the point it is when it is finite, and
/// the closed overflow ray when it is not. This is what `translate` and
/// `expand` see at an infinite delta or margin — the two endpoints of the
/// ray, not the infinity as a numeric point.
fn scalarRay(x: f64) Canonical {
    return .{
        .lo = closedEnd(x),
        .hi = closedEnd(x),
        .lo_unbounded = x == neg_inf64,
        .hi_unbounded = x == inf64,
    };
}

/// The frontier image of a shift, which is the contract's own definition of
/// it: `add` against the canonical overflow ray an infinite delta stands
/// for.
fn frontierTranslate(a: Canonical, delta: f64) FrontierSum {
    return frontierAdd(a, scalarRay(delta));
}

/// The frontier image of a widening by `margin`.
///
/// A positive ray margin is the whole line, which is both what the contract
/// says and the only thing the set says: widening by every finite positive
/// margin fills the line. A negative ray margin is the union over every
/// real margin at or below -floatMax, and that union is the attained ends
/// pulled together by that last margin. A negative margin CONTRACTS rather
/// than widens: `expand` computes `[lo - margin, hi + margin]`, so its two
/// ends move toward each other, and the row below reads the margin in that
/// form throughout. The single admissible margin is NOT clipped out of the
/// ray, because an answer covering only -floatMax would leave out every
/// margin below it. For a BOUNDED input the row never reaches here: the
/// documented width precondition refuses every margin in the ray, and
/// `classifyRow` says so by name.
fn frontierExpand(a: Canonical, margin: f64) FrontierSum {
    if (margin == inf64) {
        return .{
            .alo = 0.0,
            .blo = 0.0,
            .ahi = 0.0,
            .bhi = 0.0,
            .lo_unbounded = true,
            .hi_unbounded = true,
        };
    }
    // The margin in `[lo - far, hi + far]` form. A finite margin is itself.
    // The `-inf` ray is every margin at or below `-floatMax`, and the union
    // over it runs out at the LAST of them, the one that opens the image
    // furthest — so the ray is represented by `-floatMax` and NOT by its
    // magnitude. Taking the magnitude is the sign this row used to carry,
    // and it widened the box where `expand` contracts it: it judged
    // `expand([3, +inf), -inf)` against `[-floatMax, +inf]` when the union
    // over the ray is `[3 + floatMax, +inf)`.
    const far = if (margin == neg_inf64) -std.math.floatMax(f64) else margin;
    return .{
        .alo = a.lo,
        .blo = -far,
        .ahi = a.hi,
        .bhi = far,
        .lo_unbounded = a.lo_unbounded,
        .hi_unbounded = a.hi_unbounded,
    };
}

/// The frontier sum reference of `op`, for the four operations whose image
/// ends are each a sum of two operand ends. Null for every other operation.
fn frontierSum(op: Op, a: Canonical, b: Canonical, s: f64) ?FrontierSum {
    return switch (op) {
        .add => frontierAdd(a, b),
        .sub => frontierSub(a, b),
        .translate => frontierTranslate(a, s),
        .expand => frontierExpand(a, s),
        else => null,
    };
}

/// The frontier reference of an operation whose image is a `Range`, or null
/// where the reference is a residual comparison, a cross-multiplication or
/// the identity-or-whole-line rule instead.
fn frontierReference(op: Op, a: Canonical, b: Canonical, _: f64) ?Range {
    return switch (op) {
        .mul => frontierMul(a, b),
        .abs => frontierAbs(a),
        .sqr => frontierSqr(a),
        // The reflection, with the two directions swapping as well as the
        // two ends. This is the ordinary reflected ray the contract fixes:
        // the positive overflow ray reflects to the negative one, and the
        // degenerate box a constructor that does not normalise would hand
        // back is not an enclosure of it.
        .neg => range(negated(a)),
        .hull => .{
            .lo = @min(lowOf(a), lowOf(b)),
            .hi = @max(highOf(a), highOf(b)),
        },
        .intersect => blk: {
            const lo = @max(lowOf(a), lowOf(b));
            const hi = @min(highOf(a), highOf(b));
            if (lo > hi) break :blk null;
            break :blk Range{ .lo = lo, .hi = hi };
        },
        .add, .sub, .translate, .expand, .div, .recip, .scale => null,
        else => null,
    };
}

/// The frontier reference of an operation, named in every failure report
/// for the reason `Op.oracle` gives for the finite sweep.
fn frontierOracle(op: Op) []const u8 {
    return switch (op) {
        .add => "the sum of the two attained closed ends, held as its two f64 operands and judged through the TwoSum residual, with the image running off below or above exactly when one of the two ends of an operand does",
        .sub => "the crossed corner sums of the attained closed ends, held as their two f64 operands and judged through the TwoSum residual; rays of opposite sign cannot cancel, and the same ray cancels to the whole line",
        .translate => "the reference add gives, against the canonical overflow ray an infinite delta stands for rather than the infinity as a point",
        .expand => "the whole line at a positive ray margin, and at a negative ray margin the union over every real margin at or below -floatMax, which is the attained closed ends pushed apart by exactly floatMax",
        .neg => "the reflected canonical ray, the ends swapping so that an infinite end becomes the infinity it reflects to and a finite one its own negation",
        .mul => "the hull of the four corner SETS, each a point or a ray, with a zero factor collapsing its corner to the point zero",
        .abs => "the attained closed-end magnitudes, with exactly zero where the interval spans it and +inf wherever either end is unbounded",
        .sqr => "the attained closed-end squares, with exactly zero where the interval spans it and +inf wherever either end is unbounded",
        .scale => "for an unbounded input the operand itself at |factor| = 1 and the whole line at every other factor, and for a bounded input the exact affine extrema compared through the five-term f128 expansion of the original f64 endpoints, with the whole line demanded at an infinite factor on any box that has width and the point itself demanded on one that does not",
        .div, .recip => "the whole line where the divisor reaches zero or is the whole line, zero as an accumulation point at every ray end of the divisor, the matching infinity at every ray end of the dividend, and exact cross-multiplication of every attained corner",
        .hull, .intersect => "the min and the max of the two lower and upper ends, exact, and null where they cross",
        else => unreachable,
    };
}

/// What a frontier row turned out to be.
///
/// Every arm is read off the SHAPES and the scalar and never off an answer or
/// off the arithmetic the operation will go on to perform, so the
/// classification costs nothing and cannot be accused of having classified
/// its way to green. The three refusals are the three the callers DECLARE: an
/// unordered pair, and the two preconditions of `expand`. A row that is none
/// of those is called and judged — including every operation that forms an
/// endpoint out of a ray, because the constructor normalises
/// `[floatMax,+inf]` and `[-inf,-floatMax]`, so a canonical operand no longer
/// produces the indeterminate corner sum an unnormalised one did.
const Row = enum {
    /// Call the operation and judge the answer against its reference.
    asked,
    /// `Interval.init` requires lo <= hi and TRAPS on a pair that breaks it,
    /// measured rather than assumed: every operation on `{inf,-inf}` dies
    /// with SIGABRT before it computes anything. The sweep records the
    /// refusal instead of working around it. A hand-built inverted struct is
    /// a different question and is asked in a fixed test of its own, where
    /// the two operations that never call `init` can be watched.
    unordered,
    /// `expand`'s documented precondition `margin >= -(hi - lo) / 2`, which a
    /// BOUNDED box can refuse — and does refuse a margin more negative than
    /// half its width, which would come back as an inverted interval and
    /// abort. Decided on the exact real through `marginAdmissible` — the
    /// sign of `hi - lo + 2 * margin` — and never on a width rounded to one
    /// `f128` or one `f64`, so a margin the operation does not accept never
    /// reaches a call. An unbounded box has no width to divide, so every
    /// finite margin passes it.
    expand_width,
    /// `expand(-inf)`: the margin is the canonical NEGATIVE overflow ray and
    /// stands for every real margin at or below -floatMax. Every one of
    /// them is at or under -floatMax, and no bounded box accepts any of
    /// them, so the row is a refusal and the ray is NOT quietly narrowed to
    /// the one margin some box would take. `[-floatMax, floatMax]` is the
    /// case that makes the rule visible rather than incidental: it is the
    /// widest bounded box there is, its only admissible margin in the ray is
    /// -floatMax itself, and the answer for that single margin is not an
    /// answer for the ray. An unbounded input has no width, so every margin
    /// in the ray passes there and the row is called.
    expand_negative_ray,
};

/// What this row is, read off the shapes and the scalar alone.
fn classifyRow(op: Op, a: Shape, b: ?Shape, s: f64) Row {
    if (!a.ordered()) return .unordered;
    if (b) |x| {
        if (!x.ordered()) return .unordered;
    }
    if (op == .expand and !a.unbounded()) {
        if (s == neg_inf64) return .expand_negative_ray;
        // The width is a real, so the inequality is decided on the real and
        // not on a rounded difference of two widened endpoints.
        if (!a.admitsMargin(s)) return .expand_width;
    }
    return .asked;
}

/// True when `got` is what the frontier reference requires of the case.
///
/// The reference is built from the two canonical readings and never from
/// the intervals in the case, which is what keeps this from being a
/// comparison of the library against itself: a constructor that normalises
/// `[floatMax,+inf]` and one that leaves `{inf,inf}` are judged against the
/// same reference and answer differently.
fn frontierHolds(op: Op, a: Canonical, b: Canonical, s: f64, c: Case, got: Value) bool {
    if (frontierSum(op, a, b, s)) |f| return f.holds(got.intervalOrNull() orelse return false);
    const one = Canonical{ .lo = 1.0, .hi = 1.0, .lo_unbounded = false, .hi_unbounded = false };
    switch (op) {
        .div => return frontierQuotientHolds(a, b, got.intervalOrNull() orelse return false),
        .recip => return frontierQuotientHolds(one, a, got.intervalOrNull() orelse return false),
        .scale => {
            const g = got.intervalOrNull() orelse return false;
            // An unbounded box has no finite midpoint, so the contract
            // replaces the affine image with the identity-or-whole-line
            // pair. A bounded one has no ray to read and nothing to
            // normalise, so it is judged by the same exact five-term
            // comparison the finite sweep uses, over the endpoints the
            // caller wrote.
            if (a.lo_unbounded or a.hi_unbounded) return unboundedScaleHolds(a, s, g);
            return boundedScaleHolds(c.a, s, g);
        },
        .intersect => {
            const m = switch (got) {
                .maybe_interval => |x| x,
                else => return false,
            };
            return maybeMatches(m, frontierReference(op, a, b, s));
        },
        else => {},
    }
    const g = got.intervalOrNull() orelse return false;
    if (std.math.isNan(g.lo) or std.math.isNan(g.hi)) return false;
    if (g.lo > g.hi) return false;
    const r = frontierReference(op, a, b, s) orelse return false;
    return loEncloses(r, g.lo) and hiEncloses(r, g.hi);
}

/// How many rows each outcome took, so the skip count on a report line can
/// be read rather than taken on trust. Every arm is a DECLARED precondition,
/// so a skip here is a row the callers themselves refuse, and each reason is
/// named on the report line rather than left as a bare number.
const Skips = struct {
    unordered: usize = 0,
    expand_width: usize = 0,
    expand_negative_ray: usize = 0,

    fn note(s: *Skips, r: Row) void {
        switch (r) {
            .unordered => s.unordered += 1,
            .expand_width => s.expand_width += 1,
            .expand_negative_ray => s.expand_negative_ray += 1,
            .asked => {},
        }
    }

    /// The reasons, one line each and only when there is something to say, so
    /// that a skipped count in the log is never a bare number.
    fn report(s: Skips, op: Op) void {
        if (s.unordered > 0) {
            std.debug.print("      {d} rows not called: the pair is not ordered, and Interval.init traps on it\n", .{s.unordered});
        }
        if (s.expand_width > 0) {
            std.debug.print("      {d} rows not called: {s} needs margin >= -(hi - lo) / 2, and this bounded box refuses the margin\n", .{ s.expand_width, op.label() });
        }
        if (s.expand_negative_ray > 0) {
            std.debug.print("      {d} rows not called: the margin is the negative overflow ray, every real margin at or below -floatMax, and no bounded box accepts any of them - [-floatMax,floatMax] included\n", .{s.expand_negative_ray});
        }
    }
};

/// Whether the sweep announces each row before calling it.
///
/// It does, and the reason is mechanical rather than cosmetic. A call can
/// abort when the production answer to a row is not an interval, and an
/// abort ends the whole test binary, so with no trace the last line in the
/// log belongs to whichever operation ran before the culprit and the row
/// that killed the run is never named. The sweep is directed and bounded, so
/// a line per row is a record rather than a flood, and the `Shape` ordering
/// is chosen so the shapes most likely to abort are asked last.
const frontier_trace = true;

/// The identity of one frontier row: the shapes, and the scalar where the
/// operation takes one. The shape IS the identity of a frontier case, since
/// the same operation on two of them has two different true images.
fn rowText(buf: []u8, op: Op, a: Shape, b: ?Shape, s: f64) []const u8 {
    if (op.usesScalar()) {
        if (b) |x| {
            return std.fmt.bufPrint(buf, "a = {s}, b = {s}, s = {e}", .{ a.label(), x.label(), s }) catch "a shape pair";
        }
        return std.fmt.bufPrint(buf, "a = {s}, s = {e}", .{ a.label(), s }) catch "one shape";
    }
    if (b) |x| {
        return std.fmt.bufPrint(buf, "a = {s}, b = {s}", .{ a.label(), x.label() }) catch "a shape pair";
    }
    return std.fmt.bufPrint(buf, "a = {s}", .{a.label()}) catch "one shape";
}

/// The canonical reading of the second operand, or of a stand-in point when
/// the operation takes no second shape. The point is `{0,0}` rather than
/// anything else because every operation that ignores `b` ignores it
/// entirely, and a stand-in that is a valid canonical set means the
/// reference cannot be disturbed by a choice made here.
fn b_canonical(b: ?Shape) Canonical {
    if (b) |x| return x.canonical();
    return .{ .lo = 0.0, .hi = 0.0, .lo_unbounded = false, .hi_unbounded = false };
}

/// One frontier row, classified and then either skipped on a declared
/// precondition, or called and judged.
fn frontierRow(op: Op, t: *Tally, skips: *Skips, a: Shape, b: ?Shape, s: f64) void {
    switch (classifyRow(op, a, b, s)) {
        .asked => {},
        else => |r| {
            skips.note(r);
            t.skipped_precondition += 1;
            return;
        },
    }
    const c = Case{
        .op = op,
        .a = a.interval(),
        .b = if (b) |x| x.interval() else Interval.init(0.0, 0.0),
        .s = s,
    };
    var buf: [96]u8 = undefined;
    if (frontier_trace) {
        std.debug.print("    row {s}: {s}\n", .{ op.label(), rowText(&buf, op, a, b, s) });
    }
    const got = apply(c);
    if (frontierHolds(op, a.canonical(), b_canonical(b), s, c, got)) {
        t.checked += 1;
        return;
    }
    t.failures += 1;
    if (t.shown >= max_detail) return;
    t.shown += 1;
    std.debug.print("    FAIL frontier {s}: the answer is not what the frontier reference requires\n", .{op.label()});
    std.debug.print("      shapes    {s}\n", .{rowText(&buf, op, a, b, s)});
    showCase(c, got);
    diagnoseFrontier(op, a.canonical(), b_canonical(b), s, got);
    std.debug.print("      the frontier reference is {s}\n", .{frontierOracle(op)});
}

/// What the answer missed, in the terms of the reference that missed it.
/// A sum reference prints its two `f64` operands and the residual beside
/// them, a `scale` prints the rule it broke — the identity-or-whole-line
/// pair on an unbounded operand and the five exact terms on a bounded one —
/// and a `Range` reference prints the extremum and which side cut inside it.
fn diagnoseFrontier(op: Op, a: Canonical, b: Canonical, s: f64, got: Value) void {
    const g = got.intervalOrNull() orelse return;
    if (frontierSum(op, a, b, s)) |f| {
        const lo = twoSum(f.alo, f.blo);
        const hi = twoSum(f.ahi, f.bhi);
        if (f.lo_unbounded) {
            std.debug.print("      the true image runs off to -inf, so only a lo of -inf encloses it\n", .{});
        } else {
            std.debug.print("      true lo = {e} + {e} = {e} + {e} exactly\n", .{ f.alo, f.blo, lo.s, lo.err });
        }
        if (f.hi_unbounded) {
            std.debug.print("      the true image runs off to +inf, so only a hi of +inf encloses it\n", .{});
        } else {
            std.debug.print("      true hi = {e} + {e} = {e} + {e} exactly\n", .{ f.ahi, f.bhi, hi.s, hi.err });
        }
        if (!f.lowerOk(g.lo)) std.debug.print("      the lower bound excludes the true minimum\n", .{});
        if (!f.upperOk(g.hi)) std.debug.print("      the upper bound excludes the true maximum\n", .{});
        return;
    }
    if (op == .scale and (a.lo_unbounded or a.hi_unbounded)) {
        if (@abs(ex(s)) == 1.0) {
            std.debug.print("      |factor| = 1 is the identity for every centre, so the answer has to be the operand itself\n", .{});
        } else {
            std.debug.print("      no centre exists for an unbounded input, so the contract's answer is the whole line at every factor but +/-1\n", .{});
        }
        return;
    }
    if (op == .scale) {
        const bound = ScaleBound{ .lo = a.lo, .hi = a.hi, .mag = @abs(s) };
        if (@abs(s) == inf64 and a.lo < a.hi) {
            std.debug.print("      an infinite factor is an unknown finite magnitude, and the union over all of them is the whole line for a box with width\n", .{});
        } else {
            std.debug.print("      A = {e}, B = {e}, G = {e}, judged through the exact five-term expansion and never through a midpoint\n", .{ bound.lo, bound.hi, bound.mag });
        }
        if (!bound.lowerOk(g.lo)) std.debug.print("      the lower bound excludes the true minimum\n", .{});
        if (!bound.upperOk(g.hi)) std.debug.print("      the upper bound excludes the true maximum\n", .{});
        return;
    }
    if (op == .div or op == .recip) {
        std.debug.print("      quotient containment, by exact cross-multiplication; see the frontier reference for the rule each corner falls under\n", .{});
        return;
    }
    const r = frontierReference(op, a, b, s) orelse return;
    std.debug.print("      frontier lo = {e}\n", .{r.lo});
    std.debug.print("      frontier hi = {e}\n", .{r.hi});
    if (r.lo_beyond) {
        std.debug.print("      the true minimum is a real past the end of the f64 range, so a returned lo of +inf excludes it\n", .{});
    } else if (!lowerOk(r.lo, g.lo)) {
        std.debug.print("      lower bound is ABOVE the true minimum and excludes it\n", .{});
    }
    if (r.hi_beyond) {
        std.debug.print("      the true maximum is a real past the end of the f64 range, so a returned hi of -inf excludes it\n", .{});
    } else if (!upperOk(r.hi, g.hi)) {
        std.debug.print("      upper bound is BELOW the true maximum and excludes it\n", .{});
    }
}

/// The constructor contract every frontier row depends on.
///
/// `Interval.init(+inf,+inf)` supplies the closed overflow ray `[floatMax,
/// +inf]` and its mirror `[-inf,-floatMax]`, and that is the ONE thing this
/// sweep needs before it can call any operation on a shape with an infinite
/// end. Without it, `add`, `sub`, `translate` and `expand` form an endpoint
/// out of `inf + (-inf)`, hand a NaN pair to the very constructor that would
/// have normalised the operand, and trap — which takes the test binary down
/// before a single later row can report anything.
///
/// It is a guard on the constructor and nothing else. It refuses nothing,
/// skips nothing and judges no answer: once the two rays come back
/// canonical every one of the thirteen sweeps runs every row it has, and a
/// production gap afterwards is reported as a failed row rather than
/// hidden.
fn expectCanonicalRays() !void {
    const pos = Interval.init(inf64, inf64);
    const neg = Interval.init(neg_inf64, neg_inf64);
    std.debug.print(
        "      canonical rays from the constructor: [+inf,+inf] -> [{e}, {e}], [-inf,-inf] -> [{e}, {e}]\n",
        .{ pos.lo, pos.hi, neg.lo, neg.hi },
    );
    try std.testing.expectEqual(std.math.floatMax(f64), pos.lo);
    try std.testing.expectEqual(inf64, pos.hi);
    try std.testing.expectEqual(neg_inf64, neg.lo);
    try std.testing.expectEqual(-std.math.floatMax(f64), neg.hi);
}

/// The frontier sweep for one operation: every shape against every shape it
/// takes a second shape from, or every scalar it takes.
///
/// No operation is short-circuited here any more. The old sweep returned
/// early for the six whose answer the file had no agreed reading for, and
/// printed a finding instead of a tally; the contract fixes the reading, so
/// every one of the thirteen is swept like the rest and a gap in `src/`
/// shows up as a failed row with a shape and a reference attached to it.
///
/// The constructor guard runs first and is the only thing that can stop a
/// sweep before it starts. It is what turns a pre-fix run into a clean
/// assertion failure naming the constructor instead of an abort that
/// suppresses every finding after it, and it suppresses nothing at all once
/// the two rays are canonical.
fn frontier(op: Op) !Tally {
    try expectCanonicalRays();
    var t: Tally = .{ .op = op };
    var skips: Skips = .{};
    if (op.usesSecond()) {
        for (frontier_shapes) |a| {
            for (frontier_shapes) |b| frontierRow(op, &t, &skips, a, b, 0.0);
        }
    } else if (op.usesScalar()) {
        for (frontier_shapes) |a| {
            for (frontier_scalars) |s| frontierRow(op, &t, &skips, a, null, s);
        }
    } else {
        for (frontier_shapes) |a| frontierRow(op, &t, &skips, a, null, 0.0);
    }
    summary(t, "frontier ");
    skips.report(op);
    return t;
}

// ---------------------------------------------------------------------------
// Minimal reproducers, and the guards around them
// ---------------------------------------------------------------------------

/// Assert that `got` encloses `r`, and print the diagnosis if it does not.
/// The width bound is only applied when the true image is representable in
/// `f64`; where it is not, every correct answer is the universal interval
/// and a width bound would say nothing.
fn expectEnclosure(name: []const u8, got: Interval, r: Range, check_width: bool) !void {
    const lo_ok = lowerOk(r.lo, got.lo);
    const hi_ok = upperOk(r.hi, got.hi);
    const wide_ok = !check_width or widthOk(got, r);
    if (lo_ok and hi_ok and wide_ok) return;
    std.debug.print("\n  UNSOUND: {s}\n", .{name});
    std.debug.print("    returned =\n", .{});
    showInterval(got);
    std.debug.print("    exact lo = {e}\n", .{r.lo});
    std.debug.print("    exact hi = {e}\n", .{r.hi});
    if (!lo_ok) std.debug.print("    returned lo is ABOVE the true minimum and excludes it\n", .{});
    if (!hi_ok) std.debug.print("    returned hi is BELOW the true maximum and excludes it\n", .{});
    if (!wide_ok) std.debug.print("    returned interval is far wider than the true image\n", .{});
    std.debug.print("\n", .{});
    return error.NotAnEnclosure;
}

/// The mirror of `expectEnclosure` for a SUM reference, where the true
/// extremum is not a number `f128` can hold and the width is therefore
/// formed from the two residuals rather than from a difference of two
/// widened values.
///
/// The width bound is only applied when the reference's own ends are
/// representable, which is decided rather than assumed: the check is
/// skipped for a case whose width is not a finite `f128`, because a width
/// bound there would say nothing and a wrong one would fail a sound
/// answer.
fn expectSumEnclosure(name: []const u8, got: Interval, s: SumBound, check_width: bool) !void {
    const lo_ok = s.lowerOk(got.lo);
    const hi_ok = s.upperOk(got.hi);
    const tlo = twoSum(s.alo, s.blo);
    const thi = twoSum(s.ahi, s.bhi);
    const lo_val = tlo.s + tlo.err;
    const hi_val = thi.s + thi.err;
    const width_ok = if (check_width and std.math.isFinite(lo_val) and std.math.isFinite(hi_val))
        widthOk(got, .{ .lo = lo_val, .hi = hi_val })
    else
        true;
    if (lo_ok and hi_ok and width_ok) return;
    std.debug.print("\n  UNSOUND: {s}\n", .{name});
    std.debug.print("    returned =\n", .{});
    showInterval(got);
    std.debug.print("    true lo = {e} + {e} = {e} + {e} exactly\n", .{ s.alo, s.blo, tlo.s, tlo.err });
    std.debug.print("    true hi = {e} + {e} = {e} + {e} exactly\n", .{ s.ahi, s.bhi, thi.s, thi.err });
    if (!lo_ok) std.debug.print("    returned lo is ABOVE the true minimum and excludes it\n", .{});
    if (!hi_ok) std.debug.print("    returned hi is BELOW the true maximum and excludes it\n", .{});
    if (!width_ok) std.debug.print("    returned interval is far wider than the true image\n", .{});
    std.debug.print("\n", .{});
    return error.NotAnEnclosure;
}

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

test "reproducer 3: powf's fixed relative margin does not grow with the exponent" {
    // The exponent is reached by repeated squaring, whose relative error
    // doubles with every bit of it, so a fixed margin cannot cover it once
    // the exponent is large enough. 1.0000000001^1e8 is 1.0100501679193823.
    const base = Interval.init(1.0000000001, 1.0000000001);
    const expo = Interval.init(1e8, 1e8);
    const got = interval.ext.powf(base, expo) orelse return error.PowfRefused;
    try expectEnclosure("powf excludes the true 1.0000000001^1e8", got, exactPowf(1.0000000001, 1e8), true);
}

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
// The fuzz sweeps
// ---------------------------------------------------------------------------

test "fuzz: add" {
    const t = fuzz(.add);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: sub" {
    const t = fuzz(.sub);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: mul" {
    const t = fuzz(.mul);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: div" {
    const t = fuzz(.div);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: recip" {
    const t = fuzz(.recip);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: translate" {
    const t = fuzz(.translate);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: scale" {
    const t = fuzz(.scale);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: expand" {
    const t = fuzz(.expand);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

// The rest of the surface. One line per operation, the same generator and
// the same report, in the order of `Op` so that reading the log top to
// bottom reads the enum.

test "fuzz: abs" {
    const t = fuzz(.abs);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: sqr" {
    const t = fuzz(.sqr);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: neg" {
    const t = fuzz(.neg);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: hull" {
    const t = fuzz(.hull);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: intersect" {
    const t = fuzz(.intersect);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: hull_of" {
    const t = fuzz(.hull_of);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: intersection_of" {
    const t = fuzz(.intersection_of);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: midpoint" {
    const t = fuzz(.midpoint);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: clamp" {
    const t = fuzz(.clamp);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: width" {
    const t = fuzz(.width);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: distance_to" {
    const t = fuzz(.distance_to);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: contains" {
    const t = fuzz(.contains);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: overlaps" {
    const t = fuzz(.overlaps);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: subset_of" {
    const t = fuzz(.subset_of);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: eql" {
    const t = fuzz(.eql);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: ne" {
    const t = fuzz(.ne);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: lt" {
    const t = fuzz(.lt);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: le" {
    const t = fuzz(.le);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: gt" {
    const t = fuzz(.gt);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: ge" {
    const t = fuzz(.ge);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: floor" {
    const t = fuzz(.floor);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: ceil" {
    const t = fuzz(.ceil);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: trunc" {
    const t = fuzz(.trunc);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: round" {
    const t = fuzz(.round);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: sqrt" {
    const t = fuzz(.sqrt);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: cbrt" {
    const t = fuzz(.cbrt);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "fuzz: tanh" {
    const t = fuzz(.tanh);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

// ---------------------------------------------------------------------------
// The tanh band the magnitude table cannot reach
// ---------------------------------------------------------------------------

// Why this section exists, in numbers. `std.math.tanh` is 2.14 ULP from
// the truth near 0.23, and the two-ULP widening `interval_ext.zig` used to
// apply does not reach that. The arguments where it misses are a sliver
// rather than a region: measured against seventy-digit arithmetic over
// [-0.5, 0.5], three points in 100,001 on a 1e-5 grid exceed two ULP,
// each of them a single grid point and not a run of neighbours, and 29
// points in 524,288 on a 1.9e-6 grid do. A draw from the magnitude table
// reaches |x| <= 0.5 with probability 5e-4 per case, `.ordinary` alone
// spanning [-1000, 1000], so an 8,000-case sweep expects about four
// arguments inside the band and, at the measured rate within it, about
// one miss in twenty-five thousand runs. Random sampling is not a weak
// form of this check; it is a check that passes.
//
// So the band is swept directly, and on a grid rather than a draw, so that
// what it covers is a property of the test and not of a seed. The counts
// on nested grids of this same construction are 0 misses at 2^13, 1 at
// 2^15, 5 at 2^17 and 11 at 2^18; 2^18 is the coarsest that lands inside
// the sliver several times over, and every argument on it is exactly
// representable because the step is a power of two.

/// The width of the directed band. `tanh` is least steep and its relative
/// error largest below half an unit, the defect is there, and nothing
/// above it has been measured to miss, so this is the band swept.
const tanh_band: f64 = 0.5;

/// Steps across the band, as a power of two. Power of two so that every
/// argument is exactly representable and the grid is fixed rather than
/// the rounding of a computed step size.
const tanh_band_log2: u6 = 18;

/// One containment failure for `tanh` at `x`, with the true value in
/// digits an `f64` cannot hold, and the signed gap in ULPs that says the
/// bound cut inside the true image rather than merely being loose.
fn reportTanhMiss(x: f64, got: Interval, want: Range, shown: *usize) void {
    if (shown.* >= max_detail) return;
    shown.* += 1;
    const gap_lo = @abs((ex(got.lo) - want.lo) * 0x1p52 / @max(@abs(ex(got.lo)), @abs(want.lo)));
    const gap_hi = @abs((ex(got.hi) - want.hi) * 0x1p52 / @max(@abs(ex(got.hi)), @abs(want.hi)));
    std.debug.print("    FAIL tanh at x = {e}  bits 0x{X:0>16}\n", .{ x, @as(u64, @bitCast(x)) });
    std.debug.print("      returned lo = {e}  bits 0x{X:0>16}\n", .{ got.lo, @as(u64, @bitCast(got.lo)) });
    std.debug.print("      returned hi = {e}  bits 0x{X:0>16}\n", .{ got.hi, @as(u64, @bitCast(got.hi)) });
    std.debug.print("      true        = {e}\n", .{want.lo});
    if (!lowerOk(want.lo, got.lo)) {
        std.debug.print("      the lower bound is ABOVE the true value and excludes it by {e} ULP\n", .{gap_lo});
    }
    if (!upperOk(want.hi, got.hi)) {
        std.debug.print("      the upper bound is BELOW the true value and excludes it by {e} ULP\n", .{gap_hi});
    }
    std.debug.print("      the nearest f64 to that truth is {e}, so an oracle built on f64 compares it with itself and reports this sound\n", .{@as(f64, @floatCast(want.lo))});
}

test "reproducer 6: tanh at the argument where the primitive is 2.14 ULP out - the two-ULP bound cut the true value out" {
    // The minimal case, named and pinned rather than left to a sweep. The
    // two-ULP widening returned [0.22735067345628182, 0.22735067345628193]
    // here, and the true value is 0.227350673456281817160566003737, which
    // is BELOW that lower bound by 0.14 ULP: the interval excluded the very
    // answer it was supposed to enclose. Three ULP moves the bound to
    // 0.2273506734562818, which is 0.86 ULP below the truth.
    const x = 0.23139395412799124;
    // The negative argument is the same point by oddness and is here so
    // that a fix which widened only one side would be caught.
    for ([_]f64{ x, -x }) |arg| {
        try expectEnclosure(
            "tanh does not enclose the true value at the two-ULP witness",
            interval.ext.tanh(Interval.init(arg, arg)),
            tanhRef(arg),
            false,
        );
    }
    // The trap, asserted rather than described. The nearest `f64` to the
    // true value IS the lower bound the two-ULP widening returned, and it
    // is strictly ABOVE the truth. An oracle that rounded the truth to
    // `f64` would compare those two numbers, find them equal, and report
    // the defect sound — which is why the reference above is `f128`.
    const truth = tanhRef(x).lo;
    const rounded = @as(f64, @floatCast(truth));
    try std.testing.expect(rounded == 0.22735067345628182);
    try std.testing.expect(ex(rounded) > truth);
}

test "tanh: every argument of the directed band over |x| <= 0.5 is enclosed" {
    // The sweep. 2^18 equal steps across [-0.5, 0.5], endpoints included,
    // each argument a degenerate box — the shape the defect has.
    //
    // Degenerate boxes are not a sample of the non-degenerate ones; they
    // settle them. `tanh` is rising, so the image of [lo, hi] is the image
    // of its two ends, and `envelope` returns `lower` of the smaller and
    // `upper` of the larger. Containment at both ends therefore implies
    // containment everywhere between, exactly rather than approximately.
    // So this is a complete check of `tanh` over the band, not a sample
    // of it.
    const steps: u64 = @as(u64, 1) << tanh_band_log2;
    const step = 2.0 * tanh_band / @as(f64, @floatFromInt(steps));
    var k: u64 = 0;
    var failures: usize = 0;
    var shown: usize = 0;
    while (k <= steps) : (k += 1) {
        const x = -tanh_band + @as(f64, @floatFromInt(k)) * step;
        const got = interval.ext.tanh(Interval.init(x, x));
        const want = tanhRef(x);
        if (lowerOk(want.lo, got.lo) and upperOk(want.hi, got.hi)) continue;
        failures += 1;
        reportTanhMiss(x, got, want, &shown);
    }
    std.debug.print("  tanh band |x| <= {d}, 2^{d} steps: {d} checked, {d} FAILED\n", .{
        tanh_band, tanh_band_log2, steps + 1, failures,
    });
    if (failures > shown) {
        std.debug.print("  tanh band: {d} further failures not printed individually\n", .{failures - shown});
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

// ---------------------------------------------------------------------------
// The frontier sweep
// ---------------------------------------------------------------------------

// One line per judged operation, in the order of `Op`, with the tally the
// random sweeps print. The rows are directed rather than drawn, so the
// counts are small and every one of them is a shape whose true image is
// stated in the section above rather than reached by luck.
//
// THIRTEEN of them, and there is no thirteenth-block comment about what is
// missing: the six that used to be withheld are swept here like the rest,
// because the reading their expected answers depended on is now fixed.
//
// Every one of them asks its rows after the constructor guard, which is the
// only thing that can stop a sweep before it starts. A run against a
// constructor that does not yet normalise the two overflow rays therefore
// fails as one clean assertion naming the constructor, instead of aborting
// inside the first ray row and reporting nothing after it.

test "frontier: add" {
    const t = try frontier(.add);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "frontier: sub" {
    const t = try frontier(.sub);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "frontier: mul" {
    const t = try frontier(.mul);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "frontier: div" {
    const t = try frontier(.div);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "frontier: recip" {
    const t = try frontier(.recip);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "frontier: translate" {
    const t = try frontier(.translate);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "frontier: expand" {
    const t = try frontier(.expand);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "frontier: abs" {
    const t = try frontier(.abs);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "frontier: sqr" {
    const t = try frontier(.sqr);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "frontier: scale" {
    const t = try frontier(.scale);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "frontier: neg" {
    const t = try frontier(.neg);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "frontier: hull" {
    const t = try frontier(.hull);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

test "frontier: intersect" {
    const t = try frontier(.intersect);
    try std.testing.expectEqual(@as(usize, 0), t.failures);
}

// The bounded-scale reference is the one oracle in this file that compares
// FIVE exact terms rather than two, and a five-term oracle has a failure mode
// of its own: an `f128` midpoint and half-width are exact to within 2^-113
// relative, which is millions of orders tighter than the answer they judge,
// so they LOOK adequate and are not. Every case below is a bound that lies
// inside the true image, and each one is named for the arithmetic that puts
// it there rather than for a shape in a table.
//
// The centre row is the genuine miss, and it is the one to read first. At a
// factor of zero the true image of `[min_subnormal, floatMax]` is the single
// real `floatMax/2 + min_subnormal/2`, and the rounded `f128` midpoint of
// the two endpoints is `floatMax/2` — which is INSIDE that image, below its
// top. A reference that formed the midpoint first would therefore clear the
// answer `[floatMax/2, floatMax/2]` for a box whose image it excludes, and
// the mirrored row `[-min_subnormal, floatMax]` puts the same real on the
// other side, where the unsafe answer is the one with `floatMax/2` at its
// BOTTOM. The `f128` midpoint is computed below and printed against its
// verdict, so the gap is visible in the log rather than asserted here.
//
// The identity row and the subnormal lattice row are pins and not misses,
// and saying so is the point of the paragraph. The identity row's bounds are
// the box's own endpoints; the lattice row's two extrema are `1.25` and
// `1.75` times the smallest subnormal, and the rounded midpoint and
// half-width happen to be exact on three subnormals. Neither line argues
// that the old reference was wrong there. Both hold the new predicate to the
// answer the arithmetic gives, which is what makes them guards rather than
// restatements: one step in from either end of either row is a real inside
// the image, and every such point is refused.
//
// Nothing here calls production rounding and nothing pins an incidental bit
// pattern. The inward points are named as facts about reals, and the
// expectations are the reference's verdicts, not the library's.
test "the exact bounded-scale comparator rejects the inward bounds an f128 midpoint clears" {
    const fmax = std.math.floatMax(f64);
    const tiny = min_subnormal;

    // A factor of one is the identity, so the true image of
    // `[min_subnormal, floatMax]` is that box and nothing else. One step in
    // from either end is inside the image and must be refused.
    //
    // The two accepting lines are the other half of the row and they are not
    // filler. An oracle that is too TIGHT is a defect class of its own: it
    // reports the library's correct answers as failures, which is a false RED
    // rather than a missed hole, and this row is where one is caught. A
    // rounded `f128` reference is exactly that here — its range for this
    // identity comes out `[0, floatMax]`, whose lower end is below the true
    // minimum and which therefore refuses the sound bound `[min_subnormal,
    // floatMax]`. The exact predicate accepts it, because the two signed
    // differences are zero to the last bit.
    const identity = ScaleBound{ .lo = tiny, .hi = fmax, .mag = 1.0 };
    try std.testing.expect(identity.lowerOk(tiny));
    try std.testing.expect(identity.upperOk(fmax));
    try std.testing.expect(!identity.lowerOk(interval.nextUp(tiny)));
    try std.testing.expect(!identity.upperOk(interval.prevDown(fmax)));

    // A factor of zero is the centre, and the centre of a box spanning two
    // thousand binades is NOT the rounded mean of its endpoints. The `f128`
    // midpoint is printed beside the verdict to show the gap: it is
    // `floatMax/2` exactly, which is a real half a subnormal below the true
    // centre, and the exact comparison refuses it as an UPPER bound while
    // accepting it as a lower one.
    const centre = ScaleBound{ .lo = tiny, .hi = fmax, .mag = 0.0 };
    const rounded_centre: f64 = @floatCast((ex(tiny) + ex(fmax)) / 2.0);
    std.debug.print("\n  scale centre of [{e}, {e}] at a factor of zero\n", .{ tiny, fmax });
    std.debug.print("    the rounded f128 midpoint is {e}, a real half a subnormal BELOW the true centre {e} + {e} / 2\n", .{ rounded_centre, fmax, tiny });
    std.debug.print("    read as a lower bound {s}, as an upper bound {s}\n", .{
        if (centre.lowerOk(rounded_centre)) "ACCEPTED" else "REJECTED",
        if (centre.upperOk(rounded_centre)) "ACCEPTED" else "REJECTED",
    });
    try std.testing.expect(rounded_centre == fmax / 2.0);
    try std.testing.expect(centre.lowerOk(fmax / 2.0));
    try std.testing.expect(!centre.upperOk(fmax / 2.0));
    // And the same centre from below, where the residual goes the other way:
    // the true centre of `[-min_subnormal, floatMax]` is
    // `floatMax/2 - min_subnormal/2`, so `floatMax/2` is above it and is
    // not a lower bound.
    const below = ScaleBound{ .lo = -tiny, .hi = fmax, .mag = 0.0 };
    std.debug.print("    the mirror box [-{e}, {e}] puts its true centre at {e} / 2 - {e} / 2, a half subnormal below it, so read as a lower bound {s}, as an upper bound {s}\n", .{
        tiny,
        fmax,
        fmax,
        tiny,
        if (below.lowerOk(rounded_centre)) "ACCEPTED" else "REJECTED",
        if (below.upperOk(rounded_centre)) "ACCEPTED" else "REJECTED",
    });
    try std.testing.expect(!below.lowerOk(fmax / 2.0));
    try std.testing.expect(below.upperOk(fmax / 2.0));

    // The same predicate on a wholly subnormal lattice, where both extrema
    // are reals no `f64` holds: 1.25 and 1.75 times the smallest subnormal.
    // The box itself encloses them, and each inward point does not.
    const lattice = ScaleBound{ .lo = tiny, .hi = 2.0 * tiny, .mag = 0.5 };
    try std.testing.expect(lattice.lowerOk(tiny));
    try std.testing.expect(lattice.upperOk(2.0 * tiny));
    try std.testing.expect(!lattice.lowerOk(2.0 * tiny));
    try std.testing.expect(!lattice.upperOk(tiny));

    // An exactly cancelling comparison is an EXACT ZERO expansion, and it is
    // the case a rounded head cannot represent at all: `[-1,1]` at a factor
    // of one has `L = -1` and `H = 1` to the last bit, and one step in from
    // either end is a step inside.
    const parity = ScaleBound{ .lo = -1.0, .hi = 1.0, .mag = 1.0 };
    try std.testing.expect(parity.lowerOk(-1.0));
    try std.testing.expect(parity.upperOk(1.0));
    try std.testing.expect(!parity.lowerOk(interval.nextUp(-1.0)));
    try std.testing.expect(!parity.upperOk(interval.prevDown(1.0)));

    // A computed overflow on the way out. `[-floatMax, floatMax]` at a
    // factor of two has the extrema `-2*floatMax` and `2*floatMax`, which
    // are reals past the end of the `f64` range and not numbers at all in it.
    // The enclosing infinity is the only lower bound there is, and `floatMax`
    // is a real inside the image and is refused.
    const overflowed = ScaleBound{ .lo = -fmax, .hi = fmax, .mag = 2.0 };
    try std.testing.expect(overflowed.lowerOk(neg_inf64));
    try std.testing.expect(overflowed.upperOk(inf64));
    try std.testing.expect(!overflowed.lowerOk(fmax));
    try std.testing.expect(!overflowed.upperOk(-fmax));
    // The same bound pointing the other way is not an enclosure of anything
    // finite, and a NaN bound is not a bound.
    try std.testing.expect(!overflowed.lowerOk(inf64));
    try std.testing.expect(!overflowed.upperOk(neg_inf64));
    try std.testing.expect(!overflowed.lowerOk(std.math.nan(f64)));

    // A degenerate box is a point at every factor, and the infinities still
    // enclose it: the map has zero half-width there, so nothing widens it.
    const point = Interval.init(2.0, 2.0);
    try std.testing.expect(boundedScaleHolds(point, 3.0, point));
    try std.testing.expect(boundedScaleHolds(point, 0.0, point));
    try std.testing.expect(!boundedScaleHolds(point, 3.0, Interval.init(interval.nextUp(2.0), 3.0)));

    // An infinite factor is an unknown magnitude and never a number in the
    // expansion. A box with width is the whole line and nothing else; a box
    // without one is its own point, because the half-width is zero at every
    // magnitude. Both signs of the factor are the same magnitude, so both
    // take the same arm.
    const wide = Interval.init(1.0, 2.0);
    try std.testing.expect(boundedScaleHolds(wide, inf64, Interval.init(neg_inf64, inf64)));
    try std.testing.expect(boundedScaleHolds(wide, neg_inf64, Interval.init(neg_inf64, inf64)));
    try std.testing.expect(!boundedScaleHolds(wide, inf64, Interval.init(-3.0, 4.0)));
    try std.testing.expect(!boundedScaleHolds(wide, neg_inf64, Interval.init(neg_inf64, 4.0)));
    try std.testing.expect(boundedScaleHolds(point, inf64, point));
    try std.testing.expect(boundedScaleHolds(point, neg_inf64, point));
    // A NaN factor is the operation's own precondition, not an image.
    try std.testing.expect(!boundedScaleHolds(wide, std.math.nan(f64), Interval.init(neg_inf64, inf64)));

    // The library's own answers, at the shapes the fuzz draw cannot reach: a
    // centre and the two identities on a finite box. These are containment
    // checks against the exact reference and not pins of a bound.
    const unit = Interval.init(1.0, 2.0);
    try std.testing.expect(boundedScaleHolds(unit, 1.0, unit.scale(1.0)));
    try std.testing.expect(boundedScaleHolds(unit, -1.0, unit.scale(-1.0)));
    const two = Interval.init(-3.0, 5.0);
    try std.testing.expect(boundedScaleHolds(two, 2.0, two.scale(2.0)));
    // The centre of `[min_subnormal, floatMax]`, which is the case the
    // whole comparison exists for.
    try std.testing.expect(boundedScaleHolds(Interval.init(tiny, fmax), 0.0, Interval.init(tiny, fmax).scale(0.0)));
}

// The margin precondition has the same failure mode the bounded-scale
// comparator has and no rounded-width reference can be trusted with it,
// because the width is the largest sum in the format: `floatMax -
// min_subnormal` is over a thousand significand bits and `f128` carries
// 113, so it comes back as `floatMax` and the half-width comes back as
// `floatMax / 2` — a number BELOW the true half-width, since the true one
// is `floatMax / 2 + min_subnormal / 2`. A rounded rule therefore refuses
// the one admissible margin just above the boundary and admits the one
// just below it, and the margin it admits is exactly the one that comes
// back as an inverted interval and takes the binary with it.
//
// Every line below is the reference's verdict on a margin, not the
// library's answer, and the disagreement with the rounded rule is shown at
// the one place it exists so that the rule cannot be reinstated by accident.
test "the exact margin predicate separates the two margins a rounded half-width merges" {
    const fmax = std.math.floatMax(f64);
    const tiny = min_subnormal;

    // The extreme-residual boundary. On `[min_subnormal, floatMax]` the
    // admissible margins run from `-(floatMax / 2 + min_subnormal / 2)`
    // upward, and that lower end is not a number `f64` holds. The two
    // representable margins straddling it are `-floatMax / 2`, which is one
    // step too far and inverts the interval, and the next step up, which
    // is admissible by a comfortable margin. The rounded half-width sits
    // at `-floatMax / 2`, so it puts the boundary a whole step too low and
    // takes the first of these two.
    try std.testing.expect(!marginAdmissible(tiny, fmax, -fmax / 2.0));
    try std.testing.expect(marginAdmissible(tiny, fmax, interval.nextUp(-fmax / 2.0)));
    // The rounded rule is the one that has to disagree, and it is shown
    // disagreeing rather than described: `floatMax - min_subnormal` rounds
    // to `floatMax`, so `-width / 2` is exactly the margin the exact
    // predicate refuses, and a strict `<` against it lets that one through.
    const rounded_half = -((ex(fmax) - ex(tiny)) / 2.0);
    try std.testing.expect(rounded_half == -fmax / 2.0);
    try std.testing.expect(!(ex(-fmax / 2.0) < rounded_half));

    // The widest bounded box there is, where the true half-width IS a
    // number: `floatMax`. The margin at the boundary is an EXACT ZERO
    // expansion — the fold leaves nothing behind at all — so it is also the
    // row that says an empty expansion is a total of zero and not an
    // absent one.
    // There is no finite `f64` margin past it — `-floatMax` is the most
    // negative one there is — so the step-past boundary is taken on a box
    // half as wide, where both sides of the boundary are representable.
    try std.testing.expect(marginAdmissible(-fmax, fmax, -fmax));
    try std.testing.expect(marginAdmissible(-fmax / 2.0, fmax / 2.0, -fmax / 2.0));
    try std.testing.expect(!marginAdmissible(-fmax / 2.0, fmax / 2.0, interval.prevDown(-fmax / 2.0)));

    // A box with no width admits no negative margin at all: the total is
    // then exactly `2 * margin`, so zero is the boundary and it is reached.
    try std.testing.expect(marginAdmissible(2.0, 2.0, 0.0));
    try std.testing.expect(marginAdmissible(2.0, 2.0, tiny));
    try std.testing.expect(!marginAdmissible(2.0, 2.0, -tiny));

    // An ordinary box, where the boundary `-0.5` IS representable and the
    // step below it is the one the operation refuses.
    try std.testing.expect(marginAdmissible(0.0, 1.0, -0.5));
    try std.testing.expect(!marginAdmissible(0.0, 1.0, interval.prevDown(-0.5)));

    // A subnormal lattice, where the true half-width is `1.5` times the
    // smallest subnormal and therefore not representable at all: the two
    // representable margins are `-2 * tiny`, one step too far, and
    // `-tiny`, which clears it.
    try std.testing.expect(!marginAdmissible(tiny, 4.0 * tiny, -2.0 * tiny));
    try std.testing.expect(marginAdmissible(tiny, 4.0 * tiny, -tiny));

    // A margin at or above zero is admissible at every width, which is a
    // statement about the three terms rather than a special case: the
    // width is never negative and neither is twice the margin.
    try std.testing.expect(marginAdmissible(tiny, fmax, 0.0));
    try std.testing.expect(marginAdmissible(tiny, fmax, fmax));
    try std.testing.expect(marginAdmissible(-fmax, fmax, fmax));

    // The infinities are decided before the expansion is grown, and the
    // reason they have to be is that folding one in does not widen the
    // answer, it destroys it: `TwoSum(+inf, x)` computes `inf - inf` and
    // the residual comes back NaN. A positive ray margin is a widening by
    // every positive real and no box refuses it; the negative ray is every
    // margin at or below -floatMax and every bounded box refuses all of
    // them, `[-floatMax, floatMax]` — the one box with a finite margin at
    // exactly -floatMax — included, because the contract refuses the ray
    // rather than clipping it to that single admissible value. A NaN is
    // not a margin.
    try std.testing.expect(marginAdmissible(-fmax, fmax, inf64));
    try std.testing.expect(marginAdmissible(2.0, 2.0, inf64));
    try std.testing.expect(!marginAdmissible(-fmax, fmax, neg_inf64));
    try std.testing.expect(!marginAdmissible(2.0, 2.0, neg_inf64));
    try std.testing.expect(!marginAdmissible(2.0, 2.0, std.math.nan(f64)));
}

// The two frontier references the old table got wrong, pinned as
// REFERENCES and not as answers. Both are statements about the image of a
// set, so asking the reference is asking the mathematics; the production
// answer at the same shapes is what `frontier: sub` and `frontier: neg`
// judge, and is not restated here.
test "frontier: the subtraction witness is the same ray, and the reflection is the canonical ray" {
    const fmax = std.math.floatMax(f64);
    // The canonical overflow rays the contract fixes, built directly rather
    // than through the constructor, so this test states the reference and
    // not what the constructor currently does with a pair of infinities.
    const pos = Shape.pos_point.canonical();
    const neg = Shape.neg_point.canonical();

    // The SAME ray cancels. Both ends run off, in opposite directions, and
    // the image is the whole line. This is the row that used to abort.
    const same = frontierSub(pos, pos);
    try std.testing.expect(same.lo_unbounded);
    try std.testing.expect(same.hi_unbounded);
    try std.testing.expect(same.holds(Interval.init(neg_inf64, inf64)));
    try std.testing.expect(!same.holds(Interval.init(-fmax, inf64)));
    // The same is true of the negative ray against itself, for the mirrored
    // reason: the low end is -inf and the high end is +inf.
    const same_neg = frontierSub(neg, neg);
    try std.testing.expect(same_neg.lo_unbounded);
    try std.testing.expect(same_neg.hi_unbounded);

    // The OPPOSITE rays do NOT cancel, and this is the witness the old
    // table had backwards. The low end is the sum of two attained closed
    // ends, 2*floatMax, and the high end runs off to +inf. So the image is
    // a ray above 2*floatMax and NOT the whole line, the lower bound does
    // not have to reach -inf, and floatMax is a sound lower bound because
    // every f64 is at or below 2*floatMax.
    const opposed = frontierSub(pos, neg);
    try std.testing.expect(!opposed.lo_unbounded);
    try std.testing.expect(opposed.hi_unbounded);
    try std.testing.expect(opposed.lowerOk(-fmax));
    try std.testing.expect(opposed.lowerOk(fmax));
    try std.testing.expect(!opposed.lowerOk(inf64));
    try std.testing.expect(!opposed.holds(Interval.init(neg_inf64, fmax)));
    // The mirror: the negative ray minus the positive one runs off to
    // -inf below and is bounded above by -2*floatMax.
    const opposed_mirror = frontierSub(neg, pos);
    try std.testing.expect(opposed_mirror.lo_unbounded);
    try std.testing.expect(!opposed_mirror.hi_unbounded);
    try std.testing.expect(opposed_mirror.upperOk(-fmax));
    try std.testing.expect(!opposed_mirror.upperOk(neg_inf64));

    // Opposite-ray ADDITION is the whole line, and that is a fact about
    // addition rather than an accident: one side has no lower bound and the
    // other has no upper one.
    const sum = frontierAdd(pos, neg);
    try std.testing.expect(sum.lo_unbounded);
    try std.testing.expect(sum.hi_unbounded);
    try std.testing.expect(sum.holds(Interval.init(neg_inf64, inf64)));

    // `neg` of a canonical ray is the ordinary reflected ray, so it is
    // judged by the same containment as every other shape — and the
    // reflection swaps the two DIRECTIONS as well as the two ends, which
    // is the part the removed bit-pattern test used to stand in for. The
    // degenerate box a constructor that does not normalise hands back is
    // not an enclosure of either ray: it is the single point -inf, and the
    // image of the positive ray is everything below -floatMax.
    const reflected = range(negated(pos));
    try std.testing.expect(neg_inf128 == reflected.lo);
    try std.testing.expect(ex(-fmax) == reflected.hi);
    try std.testing.expect(loEncloses(reflected, neg_inf64) and hiEncloses(reflected, -fmax));
    try std.testing.expect(!(hiEncloses(reflected, neg_inf64)));
    const mirrored = range(negated(neg));
    try std.testing.expect(ex(fmax) == mirrored.lo);
    try std.testing.expect(inf128 == mirrored.hi);
    try std.testing.expect(loEncloses(mirrored, fmax) and hiEncloses(mirrored, inf64));
    try std.testing.expect(!(loEncloses(mirrored, inf64)));
    // The whole line reflects to itself, on both flags as well as both ends.
    const line_reflected = negated(Shape.line.canonical());
    try std.testing.expect(line_reflected.lo_unbounded and line_reflected.hi_unbounded);
    try std.testing.expect(loEncloses(range(line_reflected), neg_inf64) and hiEncloses(range(line_reflected), inf64));
    // A bounded box reflects to itself set-wise only when it is symmetric,
    // and a bounded box never picks up a direction it did not have.
    const finite_reflected = negated(Shape.narrow.canonical());
    try std.testing.expect(!finite_reflected.lo_unbounded and !finite_reflected.hi_unbounded);
    try std.testing.expectEqual(@as(f64, -2.0), finite_reflected.lo);
    try std.testing.expectEqual(@as(f64, -1.0), finite_reflected.hi);
}

// The mutants the one-sided magnitude rule let through, and the overflow its
// saturation was really about. Every wrong answer here used to pass
// `fuzz: width` and `fuzz: distance_to`, and none of them does now.
//
// Every verdict is PRINTED before any of them is asserted, so a run against
// the old rule shows the whole list of what it accepted rather than stopping
// at the first one.
test "guard: width and distanceTo are judged as VALUES - too large fails as loudly as too small" {
    const a = Interval.init(1.0, 2.0);
    const width_case = Case{ .op = .width, .a = a, .b = Interval.init(0.0, 0.0), .s = 0.0 };
    const true_width = exactWidth(a);
    // Four times the true width, plus one. A rule that asks only "is it big
    // enough" takes this, and it is plenty big.
    const inflated: f64 = @floatCast(true_width * 4.0 + 1.0);
    // +inf for a width that is a finite real, which the old rule took on
    // every case without asking.
    const true_ok = holds(width_case, .{ .scalar = a.width() });
    const inflated_ok = holds(width_case, .{ .scalar = inflated });
    const infinite_ok = holds(width_case, .{ .scalar = inf64 });

    // The overflow that rule existed for is still decided correctly, and it
    // is decided by the REFERENCE rather than by the rule: the exact width of
    // the whole format is a real no `f64` holds, and the format's own
    // subtraction returns +inf for it, which is then the value and not a
    // bound. A rule that let +inf through for EVERY width is what left the
    // finite cases unguarded.
    const full = Interval.init(-std.math.floatMax(f64), std.math.floatMax(f64));
    const full_case = Case{ .op = .width, .a = full, .b = Interval.init(0.0, 0.0), .s = 0.0 };
    const saturated = std.math.isInf(exactWidth(full));
    const full_ok = holds(full_case, .{ .scalar = full.width() });
    // A mutant answering the finite floatMax there is wrong: the true width
    // is 3.59e308 and no finite `f64` bounds it from below.
    const full_mutant_ok = holds(full_case, .{ .scalar = std.math.floatMax(f64) });

    // `distanceTo` is a value for the same reasons and is judged the same
    // way, on both sides.
    const far = Case{ .op = .distance_to, .a = Interval.init(1.0, 2.0), .b = Interval.init(0.0, 0.0), .s = 10.0 };
    const true_gap = exactDistanceTo(far.a, far.s);
    const gap_inflated: f64 = @floatCast(true_gap * 4.0 + 1.0);
    const gap_ok = holds(far, .{ .scalar = far.a.distanceTo(far.s) });
    const gap_mutant_ok = holds(far, .{ .scalar = gap_inflated });
    const gap_infinite_ok = holds(far, .{ .scalar = inf64 });

    std.debug.print("\n  guard: width, the exact difference of two f64 endpoints, judged as a VALUE\n", .{});
    std.debug.print("    the true width of [{e}, {e}] is exactly {e}\n", .{ a.lo, a.hi, @as(f64, @floatCast(true_width)) });
    std.debug.print("    what the library answers ({e})                        -> {s}\n", .{ a.width(), if (true_ok) "ACCEPTED" else "REJECTED" });
    std.debug.print("    a mutant four times too large ({e})                    -> {s}\n", .{ inflated, if (inflated_ok) "ACCEPTED" else "rejected" });
    std.debug.print("    a mutant answering +inf for that finite width          -> {s}\n", .{if (infinite_ok) "ACCEPTED" else "rejected"});
    std.debug.print("    the exact width of the whole format is {e}, and the answer {e} -> {s}\n", .{ exactWidth(full), full.width(), if (full_ok) "ACCEPTED" else "REJECTED" });
    std.debug.print("    a mutant answering floatMax there                     -> {s}\n", .{if (full_mutant_ok) "ACCEPTED" else "rejected"});
    std.debug.print("  guard: the distance from 10 to [1, 2], the same kind of value\n", .{});
    std.debug.print("    the true distance is exactly {e}\n", .{@as(f64, @floatCast(true_gap))});
    std.debug.print("    what the library answers ({e})                        -> {s}\n", .{ far.a.distanceTo(far.s), if (gap_ok) "ACCEPTED" else "REJECTED" });
    std.debug.print("    a mutant four times too large ({e})                    -> {s}\n", .{ gap_inflated, if (gap_mutant_ok) "ACCEPTED" else "rejected" });
    std.debug.print("    a mutant answering +inf for it                        -> {s}\n", .{if (gap_infinite_ok) "ACCEPTED" else "rejected"});

    try std.testing.expect(true_ok);
    try std.testing.expect(!inflated_ok);
    try std.testing.expect(!infinite_ok);
    try std.testing.expect(saturated);
    try std.testing.expect(full_ok);
    try std.testing.expect(!full_mutant_ok);
    try std.testing.expect(gap_ok);
    try std.testing.expect(!gap_mutant_ok);
    try std.testing.expect(!gap_infinite_ok);
}

// What the library does with an inverted pair, and why the sweep records a
// refusal rather than watching one. Measured, in a checked build and outside
// this binary: every operation on `Interval.init(inf, -inf)` dies with
// SIGABRT, and `src/interval.zig` says why at line 215 -- `init` asserts
// lo <= hi and `inf <= -inf` is false. A trap is an abort and an abort
// inside a test binary takes every other test down with it, which is the
// whole reason the NaN contract needed `tests/nan_probe.zig`; there is no
// in-process way to watch one. So the sweep counts these rows as skipped
// precondition (`Row.unordered`) and this test asks the part of the
// question that CAN be asked in process.
//
// A struct literal rather than `init`, deliberately, and for the reason
// `tests/nan_probe.zig` gives for building its poisoned operand the same
// way: it is how a poisoned interval arrives from outside the type.
test "guard: an inverted pair is refused by the constructor, and the two operations that never call it say so themselves" {
    const inverted: Interval = .{ .lo = inf64, .hi = neg_inf64 };

    // `hull` forms its answer from a struct literal and never calls `init`,
    // so it REPAIRS the inversion into something well ordered, which is the
    // only answer a caller can go on to use.
    const repaired = inverted.hull(Interval.init(-1.0, 1.0));
    try std.testing.expectEqual(@as(f64, -1.0), repaired.lo);
    try std.testing.expectEqual(@as(f64, 1.0), repaired.hi);

    // `intersect` reports the pair as disjoint rather than handing the
    // inversion on: lo is above hi, and the null is the claim that the two
    // share nothing, which is as true of an interval that cannot exist as it
    // is of one that genuinely does not meet the other.
    try std.testing.expect(inverted.intersect(Interval.init(-1.0, 1.0)) == null);
    try std.testing.expect(Interval.intersectionOf(&[_]Interval{ inverted, Interval.init(-1.0, 1.0) }) == null);
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
