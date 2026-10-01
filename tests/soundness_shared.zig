//! The soundness oracle's shared vocabulary, and the argument for why the
//! oracle is built the way it is. The oracle proper is four sibling test
//! files, one per concern:
//!
//!   * `soundness_reference_test.zig` — the tanh oracle's band, the one
//!     piece of the reference layer that is a test of its own rather than a
//!     reading of somebody else's sweep.
//!   * `soundness_fuzz_test.zig` — the generator, the per-operation random
//!     sweeps, and the failure report they print.
//!   * `soundness_frontier_test.zig` — the directed sweep over the shapes at
//!     and beyond the ends of the `f64` range, and the guards that pin its
//!     references.
//!   * `soundness_reproducers_test.zig` — the minimal reproducers, the
//!     overflow guards, the div and recip forms, the folds at the list
//!     lengths a draw cannot reach, and the NaN-scalar trap observed from
//!     outside this process.
//!
//! Everything more than one of those four reads lives here: the imports, the
//! stream seeds, `Op`, the enclosure rules, the exact images, the verdict a
//! drawn case is judged by, and the reproducer assertions. The reference
//! layer is here rather than in a concern file of its own for a reason that
//! is a property of Zig and not a preference: `zig test` collects the tests
//! of EVERY file a test binary reaches, root or not, so a concern file that
//! `@import`ed another concern file would run that file's tests a second
//! time and print its report twice — the tanh band sweep, at 2^18 points,
//! three times over. Four siblings over one shared module is the shape that
//! keeps every test running exactly once, in exactly one binary, which is
//! what `zig build test` did when all of this lived in one file.
//!
//! Every declaration here is `pub` for the same reason: a concern file pulls
//! what it needs out through a one-line alias rather than through a
//! namespace, because `usingnamespace` is gone and a cross-file declaration
//! has to be visible before it can be named at all.
//! Soundness oracle. The package's central claim is that every operation
//! returns a guaranteed enclosure of the true result of the expression it
//! was asked about, and these five files are the only place in the tree that
//! holds that claim to account. Containment is the property under test, and
//! the quantity it is checked against is derived in `f128` from the
//! original `f64` inputs — never by evaluating the corners in `f64` and
//! then treating those results as truth. Evaluating the corners in `f64`
//! and believing them is the mistake that let a result that cuts inside the
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

pub const std = @import("std");
pub const interval = @import("interval");
pub const Interval = interval.Interval;

/// Seed for every fuzz stream. Fixed, so a failure reproduces exactly and a
/// pass means something; `std.Random.DefaultPrng` rather than the system
/// source, which would make the suite meaningless.
pub const seed: u64 = 0xDEAD_BEEF_CAFE_F00D;

/// The stream of one operation, keyed on its LABEL rather than on its
/// position in `Op`.
///
/// FNV-1a over the name, written out here rather than taken from
/// `std.hash` because this file pins its numbers: a hash whose internals the
/// standard library is free to change would move every stream again, which
/// is the same fragility one layer down. 64 bits of FNV-1a keeps these
/// labels apart with nothing to spare and the arithmetic is four lines.
pub fn labelSeed(label: []const u8) u64 {
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
pub fn streamSeed(op: Op) u64 {
    return seed ^ labelSeed(op.label());
}

/// How many individual failures one fuzz prints in full. The count is
/// always reported exactly; this only bounds the detail so a sweep with a
/// large blast radius stays readable.
pub const max_detail: usize = 12;

// ---------------------------------------------------------------------------
// Exact layer
// ---------------------------------------------------------------------------

pub const inf128 = std.math.inf(f128);
pub const neg_inf128 = -inf128;
pub const inf64 = std.math.inf(f64);
pub const neg_inf64 = -inf64;

/// Exact widening of an `f64` to `f128`. Every `f64` is a `f128`, so this
/// loses nothing.
pub inline fn ex(x: f64) f128 {
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
pub const Range = struct {
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
pub fn lowerOk(elo: f128, glo: f64) bool {
    if (std.math.isNan(elo) or std.math.isNan(glo)) return false;
    if (elo == neg_inf128) return glo == neg_inf64;
    if (glo == neg_inf64) return true;
    return ex(glo) <= elo;
}

/// The mirror of `lowerOk` for the upper bound.
pub fn upperOk(ehi: f128, ghi: f64) bool {
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
pub const TwoSum = struct {
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
pub fn twoSumExact(a: f128, b: f128) TwoSum {
    @setFloatMode(.strict);
    const s = a + b;
    const b_virtual = s - a;
    const a_virtual = s - b_virtual;
    return .{ .s = s, .err = (a - a_virtual) + (b - b_virtual) };
}

pub fn twoSum(a: f64, b: f64) TwoSum {
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
pub const SumOrder = enum { below, equal, above, unordered };

pub fn compareToSum(g: f64, a: f64, b: f64) SumOrder {
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
pub fn sumLeq(g: f64, a: f64, b: f64) bool {
    return switch (compareToSum(g, a, b)) {
        .below, .equal => true,
        .above, .unordered => false,
    };
}

/// True when the `f64` `g` is at or above the exact sum of `a` and `b`.
pub fn sumGeq(g: f64, a: f64, b: f64) bool {
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
pub const Expansion = struct {
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
    pub fn add(x: *Expansion, term: f128) void {
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
    pub fn sign(x: *const Expansion) i32 {
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
pub const SumBound = struct {
    /// The two `f64` whose sum is the true MINIMUM of the image.
    alo: f64,
    blo: f64,
    /// The two `f64` whose sum is the true MAXIMUM of the image.
    ahi: f64,
    bhi: f64,

    pub fn lowerOk(s: SumBound, glo: f64) bool {
        return sumLeq(glo, s.alo, s.blo);
    }

    pub fn upperOk(s: SumBound, ghi: f64) bool {
        return sumGeq(ghi, s.ahi, s.bhi);
    }

    pub fn holds(s: SumBound, got: Interval) bool {
        return s.lowerOk(got.lo) and s.upperOk(got.hi);
    }
};

/// Containment of an exact extremum that lies past the end of the `f64`
/// range. The extremum is a real, so an `f64` at or inside the frontier in
/// that direction is at or below it and bounds it; an infinity pointing
/// the other way is the one answer that does not.
pub fn lowerOkBeyond(glo: f64) bool {
    if (std.math.isNan(glo)) return false;
    return glo < inf64;
}

/// The mirror of `lowerOkBeyond` for an extremum below the range.
pub fn upperOkBeyond(ghi: f64) bool {
    if (std.math.isNan(ghi)) return false;
    return ghi > neg_inf64;
}

/// The lower-bound test for a `Range`, honouring the `lo_beyond` flag.
pub fn loEncloses(r: Range, glo: f64) bool {
    return if (r.lo_beyond) lowerOkBeyond(glo) else lowerOk(r.lo, glo);
}

/// The upper-bound test for a `Range`, honouring the `hi_beyond` flag.
pub fn hiEncloses(r: Range, ghi: f64) bool {
    return if (r.hi_beyond) upperOkBeyond(ghi) else upperOk(r.hi, ghi);
}

/// The margin `scalarOk` allows, and why it is one ULP and not a
/// tolerance chosen to let something through: the reference is not always
/// exact even in `f128`, because the difference of two `f64` can need more
/// than 113 significand bits. A reference subtraction rounds, and
/// rounding a rounded value to `f64` can land one ULP off the `f64`
/// rounding of the same exact quantity. One ULP is the whole of that
/// double rounding.
pub const scalar_slack: f128 = 0x1p-52;

/// Containment of a returned `f64` VALUE against a reference formed in
/// `f128`, to within that one ULP.
pub fn scalarOk(got: f64, want: f128) bool {
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
pub const overflow_threshold: f128 = 0x1p1024 - 0x1p970;

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
pub fn exactWidth(a: Interval) f128 {
    const d = ex(a.hi) - ex(a.lo);
    return if (d >= overflow_threshold) inf128 else d;
}

/// The exact distance from `x` to `a`: zero inside, and the difference to
/// the nearer endpoint outside it. The same saturation as `exactWidth`, for
/// the same reason: a distance is a value.
pub fn exactDistanceTo(a: Interval, x: f64) f128 {
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
pub fn halfUlp(v: f64) f64 {
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
pub fn exactAdd(a: Interval, b: Interval) SumBound {
    return .{ .alo = a.lo, .blo = b.lo, .ahi = a.hi, .bhi = b.hi };
}

/// Exact image of `a - b`. Subtraction rises in the first operand and
/// falls in the second, so the pairing crosses: the minimum takes `a.lo`
/// against `b.hi` and the maximum takes `a.hi` against `b.lo`. Pairing
/// low with low here would understate the image, so the crossing is the
/// whole point of the routine. The second operand is negated rather than
/// subtracted, because an `f64` negation is exact and a subtraction is
/// the sum the residual comparator is there to judge.
pub fn exactSub(a: Interval, b: Interval) SumBound {
    return .{ .alo = a.lo, .blo = -b.hi, .ahi = a.hi, .bhi = -b.lo };
}

/// Exact image of a shift by `delta`, the same monotonicity argument as
/// `add` with the second operand pinned to the point `delta`.
pub fn exactTranslate(a: Interval, delta: f64) SumBound {
    return .{ .alo = a.lo, .blo = delta, .ahi = a.hi, .bhi = delta };
}

/// Exact image of a widening by `margin`, valid under the documented
/// precondition `margin >= -(hi - lo) / 2`. The low end is `a.lo - margin`
/// and the high one `a.hi + margin`, so the margin enters the low corner
/// negated for the same reason it does in `exactSub`.
pub fn exactExpand(a: Interval, margin: f64) SumBound {
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
pub fn marginAdmissible(lo: f64, hi: f64, margin: f64) bool {
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
pub fn exactMul(a: Interval, b: Interval) Range {
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
pub const ScaleBound = struct {
    /// The low end of the box, as the caller wrote it.
    lo: f64,
    /// The high end, likewise.
    hi: f64,
    /// `|factor|`, as the caller wrote it.
    mag: f64,

    /// True when `glo` is at or below the true minimum.
    pub fn lowerOk(s: ScaleBound, glo: f64) bool {
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
    pub fn upperOk(s: ScaleBound, ghi: f64) bool {
        if (std.math.isNan(ghi)) return false;
        if (ghi == inf64) return true;
        if (ghi == neg_inf64) return false;
        return expandUpper(s, ghi);
    }

    /// The sign of `A + B + G*A - G*B - 2*glo`, which is non-negative exactly
    /// when `glo` is at or below the true minimum. The five terms are the ones
    /// `ScaleBound`'s comment names, folded in as the formula writes them —
    /// the expansion asks nothing of their order.
    pub fn expandLower(s: ScaleBound, glo: f64) bool {
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
    pub fn expandUpper(s: ScaleBound, ghi: f64) bool {
        var total = Expansion{};
        total.add(ex(s.lo));
        total.add(ex(s.hi));
        total.add(-(ex(s.mag) * ex(s.lo)));
        total.add(ex(s.mag) * ex(s.hi));
        total.add(-2.0 * ex(ghi));
        return total.sign() <= 0;
    }

    pub fn holds(s: ScaleBound, got: Interval) bool {
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
pub fn boundedScaleHolds(a: Interval, factor: f64, got: Interval) bool {
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
pub fn exactAbs(a: Interval) Range {
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
pub fn exactSqr(a: Interval) Range {
    const p = ex(a.lo) * ex(a.lo);
    const q = ex(a.hi) * ex(a.hi);
    if (a.lo <= 0.0 and 0.0 <= a.hi) return .{ .lo = 0.0, .hi = @max(p, q) };
    return .{ .lo = @min(p, q), .hi = @max(p, q) };
}

/// Exact image of `neg`: the endpoints swap, and IEEE 754 negation is
/// exact, so this reference is the answer bit for bit.
pub fn exactNeg(a: Interval) Range {
    return .{ .lo = -ex(a.hi), .hi = -ex(a.lo) };
}

/// Exact image of the hull of two intervals. A min and a max of two `f64`
/// are selections, not computations, so this reference is an `f64` pair
/// with no rounding anywhere in it and the only thing to check is that
/// the returned pair is it.
pub fn exactHull(a: Interval, b: Interval) Range {
    return .{ .lo = @min(ex(a.lo), ex(b.lo)), .hi = @max(ex(a.hi), ex(b.hi)) };
}

/// Exact image of the common part of two intervals, or null when the two
/// are disjoint. The null is the reference as much as the pair is: it is
/// the claim that no interval bounds the shared part at all, and a sweep
/// that let a null through where a pair was due would be checking
/// nothing.
pub fn exactIntersect(a: Interval, b: Interval) ?Range {
    const lo = @max(ex(a.lo), ex(b.lo));
    const hi = @min(ex(a.hi), ex(b.hi));
    if (lo > hi) return null;
    return .{ .lo = lo, .hi = hi };
}

/// Exact image of `hullOf`, as a fold of min and max over the list, with
/// the empty list as the null it is.
pub fn exactHullOf(items: []const Interval) ?Range {
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
pub fn exactIntersectionOf(items: []const Interval) ?Range {
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
pub fn rangeMatches(got: Interval, want: Range) bool {
    return ex(got.lo) == want.lo and ex(got.hi) == want.hi;
}

/// A `?Interval` answer against a `?Range` reference. The null cases have
/// to agree as exactly as the values do, because a null is the claim that
/// nothing bounds the result.
pub fn maybeMatches(got: ?Interval, want: ?Range) bool {
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
pub fn cubeSign(y: f64, x: f64) i8 {
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
pub fn cbrtLo(x: f64) f64 {
    if (x == 0.0) return 0.0;
    var y = std.math.cbrt(x);
    while (cubeSign(y, x) != -1) y = interval.prevDown(y);
    return y;
}

/// Smallest `f64` whose cube is not below `x`, and so an upper bound for
/// the true cube root of `x`. The mirror of `cbrtLo`, stepping up.
pub fn cbrtHi(x: f64) f64 {
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
pub fn exactCbrt(a: Interval) Range {
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
pub fn exactSqrt(a: Interval) ?Range {
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
pub const ln2_ref: f128 = 0.6931471805599453094172321214581765680755;

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
pub const series_terms: usize = 30;

/// 1/n for n in [1, series_terms], formed at compile time. Multiplied by
/// rather than divided by at run time, because the band below runs the
/// series once per point and a software `f128` division costs two orders
/// of magnitude more than a multiply does.
pub const reciprocals: [series_terms]f128 = blk: {
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
pub fn expRefSmall(t: f128) f128 {
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
pub fn expRef(t: f128) f128 {
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
pub fn expm1Ref(t: f128) f128 {
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
pub fn tanhRefMag(a: f64) f128 {
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
pub const tanh_saturation: f64 = 20.0;

/// The true `tanh` at `x`, bracketed: the returned pair contains the real
/// value for every `f64` `x`, and is a degenerate pair everywhere the
/// value is representable to thirty-four digits.
pub fn tanhRef(x: f64) Range {
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
pub fn exactTanh(a: Interval) Range {
    const l = tanhRef(a.lo);
    const h = tanhRef(a.hi);
    return .{ .lo = @min(l.lo, h.lo), .hi = @max(l.hi, h.hi) };
}

/// Exact image of `floor`. The map snaps to a value OF the interval, so
/// its image is the pair of snapped ends; the reference is exact rather
/// than a rounding of an exact value, which is what a snapping map
/// buys over every other one under test.
pub fn exactFloor(a: Interval) Range {
    return .{ .lo = ex(@floor(a.lo)), .hi = ex(@floor(a.hi)) };
}

/// Exact image of `ceil`, the other snapping map.
pub fn exactCeil(a: Interval) Range {
    return .{ .lo = ex(@ceil(a.lo)), .hi = ex(@ceil(a.hi)) };
}

/// Exact image of `trunc`.
pub fn exactTrunc(a: Interval) Range {
    return .{ .lo = ex(@trunc(a.lo)), .hi = ex(@trunc(a.hi)) };
}

/// Exact image of `round`, ties away from zero as `@round` goes.
pub fn exactRound(a: Interval) Range {
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
pub const midpoint_rel: f128 = 0x1p-51;

pub fn exactMidpoint(a: Interval) f128 {
    return (ex(a.lo) + ex(a.hi)) / 2.0;
}

/// The exact value `clamp` must return: the nearer of the two endpoints,
/// or `x` when `x` is already inside. A min and a max are selections, so
/// the `f128` reference picks the same operand the `f64` one does and
/// `scalarOk` is only covering the arithmetic, not a disagreement.
pub fn exactClamp(a: Interval, x: f64) f128 {
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
pub fn quotientHolds(a: f64, b: f64, got: Interval) bool {
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
pub fn unboundedQuotientHolds(num: Interval, den: Interval, got: Interval) bool {
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
pub const width_rel: f64 = 4.0;
pub const width_ulp_floor: f64 = 1048576.0; // 2^20

/// The smallest positive `f64`. Drawn as an operand in its own right and
/// used as the resolution floor of the width bound.
pub const min_subnormal: f64 = 4.9406564584124654e-324;

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
pub fn widthOk(got: Interval, r: Range) bool {
    const w = ex(got.hi) - ex(got.lo);
    if (std.math.isNan(w) or w == inf128) return false;
    const scale = @max(@abs(r.lo), @abs(r.hi));
    const floor = width_ulp_floor * @max(if (scale == 0.0) 1.0 else scale, min_subnormal);
    return w <= @max((r.hi - r.lo) * width_rel, floor);
}

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
pub const Op = enum {
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

    pub fn label(op: Op) []const u8 {
        return @tagName(op);
    }

    /// True for the operations that take a second interval operand.
    pub fn usesSecond(op: Op) bool {
        return switch (op) {
            .add, .sub, .mul, .div, .hull, .intersect, .hull_of, .intersection_of, .overlaps, .subset_of, .eql, .ne, .lt, .le, .gt, .ge => true,
            else => false,
        };
    }

    /// True for the operations that take a bare `f64` scalar. The two
    /// list folds are in it because their third element is the scalar
    /// drawn for the case, which is what takes the fold past the
    /// two-element case a pairwise law would settle.
    pub fn usesScalar(op: Op) bool {
        return switch (op) {
            .translate, .scale, .expand, .clamp, .distance_to, .contains, .hull_of, .intersection_of => true,
            else => false,
        };
    }

    /// The reference the sweep judges this operation against, named in
    /// every failure report so that a failure says what was expected
    /// without the reader having to go and look it up.
    pub fn oracle(op: Op) []const u8 {
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

/// One screened case: the operation, both operand intervals, and the
/// scalar the operations taking a bare `f64` use. `b` and `s` are unused
/// by the operations that do not take them.
pub const Case = struct {
    op: Op,
    a: Interval,
    b: Interval,
    s: f64,

    /// The third element the list folds read, built from the scalar the
    /// case already drew. Reusing that draw is what keeps one generator
    /// serving every operation: a second draw would either be a second
    /// generator or a change to the stream the eight original operations
    /// already have.
    pub fn third(c: Case) Interval {
        return Interval.init(c.s, c.s);
    }

    /// The list the two folds read, in the order they read it.
    pub fn list(c: Case) [3]Interval {
        return .{ c.a, c.b, c.third() };
    }
};

/// What one operation returned. Four shapes because the package has four
/// shapes: an enclosure, an enclosure or the claim that there is none, a
/// scalar, and a bool. The sweep reports one line per operation whichever
/// shape came back, and a union is what lets a single `apply` and a
/// single `holds` serve all four without a second generator.
pub const Value = union(enum) {
    interval: Interval,
    maybe_interval: ?Interval,
    scalar: f64,
    flag: bool,

    pub fn intervalOrNull(v: Value) ?Interval {
        return switch (v) {
            .interval => |i| i,
            else => null,
        };
    }

    pub fn flagOrNull(v: Value) ?bool {
        return switch (v) {
            .flag => |b| b,
            else => null,
        };
    }

    pub fn scalarOrNull(v: Value) ?f64 {
        return switch (v) {
            .scalar => |x| x,
            else => null,
        };
    }
};

/// Call the operation the case names, whatever shape it answers in.
pub fn apply(c: Case) Value {
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
pub fn exact(c: Case) ?Range {
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
pub fn sumBound(c: Case) ?SumBound {
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
pub const Relations = struct {
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

    pub fn of(a: Interval, b: Interval) Relations {
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
pub fn predicateHolds(op: Op, c: Case, got: bool) bool {
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
pub fn holds(c: Case, got: Value) bool {
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

pub const Tally = struct {
    op: Op,
    checked: usize = 0,
    failures: usize = 0,
    shown: usize = 0,
    skipped_nonfinite: usize = 0,
    skipped_precondition: usize = 0,
};

pub fn showInterval(i: Interval) void {
    std.debug.print("      [{e: <26} , {e: <26} ]  bits 0x{X:0>16} 0x{X:0>16}\n", .{
        i.lo, i.hi, @as(u64, @bitCast(i.lo)), @as(u64, @bitCast(i.hi)),
    });
}

pub fn showValue(v: Value) void {
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

pub fn showCase(c: Case, got: Value) void {
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

pub fn summary(t: Tally, tag: []const u8) void {
    std.debug.print("  {s}{s}: {d} checked, {d} FAILED, {d} skipped non-finite, {d} skipped precondition\n", .{
        tag, t.op.label(), t.checked, t.failures, t.skipped_nonfinite, t.skipped_precondition,
    });
    if (t.failures > t.shown) {
        std.debug.print("  {s}: {d} further failures not printed individually\n", .{ t.op.label(), t.failures - t.shown });
    }
}

/// One ray: the real it runs from and the direction it runs in.
pub const Ray = struct {
    c: f128,
    up: bool,
};

/// One endpoint of a frontier operand as the SET it stands for: either the
/// single value, or a ray running outward from it.
pub const End = union(enum) {
    value: f128,
    ray: Ray,
};

/// The extent of a set of reals at the frontier: the two ends it ATTAINS and
/// the directions it runs off in. The default is the whole line, which is
/// both the identity for `hull` and the answer for an image nothing bounds.
pub const Span = struct {
    lo: f128 = neg_inf128,
    hi: f128 = inf128,
    lo_open: bool = true,
    hi_open: bool = true,

    pub fn point(v: f128) Span {
        return .{ .lo = v, .hi = v, .lo_open = false, .hi_open = false };
    }

    /// A ray running from `c` out to one infinity. Every field named, because
    /// the defaults on the type are the two open flags and a partial literal
    /// here would leave the other one set, which is the whole line rather
    /// than the ray.
    pub fn ray(c: f128, up: bool) Span {
        return if (up)
            .{ .lo = c, .hi = inf128, .lo_open = false, .hi_open = true }
        else
            .{ .lo = neg_inf128, .hi = c, .lo_open = true, .hi_open = false };
    }

    pub fn hull(a: Span, b: Span) Span {
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
    pub fn range(s: Span) Range {
        const fmax = ex(std.math.floatMax(f64));
        return .{
            .lo = if (s.lo_open) neg_inf128 else s.lo,
            .hi = if (s.hi_open) inf128 else s.hi,
            .lo_beyond = !s.lo_open and s.lo > fmax,
            .hi_beyond = !s.hi_open and s.hi < -fmax,
        };
    }
};

/// Assert that `got` encloses `r`, and print the diagnosis if it does not.
/// The width bound is only applied when the true image is representable in
/// `f64`; where it is not, every correct answer is the universal interval
/// and a width bound would say nothing.
pub fn expectEnclosure(name: []const u8, got: Interval, r: Range, check_width: bool) !void {
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
pub fn expectSumEnclosure(name: []const u8, got: Interval, s: SumBound, check_width: bool) !void {
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
