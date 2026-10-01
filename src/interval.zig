const std = @import("std");
const rounding = @import("rounding.zig");

/// Top bit of the f64 layout, set on every negative value.
const sign_mask: u64 = 1 << 63;

/// The two ends of the format and the last finite value below them, as bit
/// patterns rather than as `std.math.inf(f64)` and `std.math.floatMax(f64)`.
///
/// Those two accessors assemble their value one place at a time inside
/// `reconstructFloat`, and that loop is the entire comptime cost of the two
/// comparisons in `init` — charged once per endpoint per call, so a caller
/// that builds a table of intervals at comptime pays it per row, and the
/// benchmark tables in `bench/bench_vec.zig` are enough of them to exhaust
/// the evaluator's branch budget on their own.
///
/// These are the same three numbers: `pos_inf` is `inf(f64)`, `float_max` is
/// `floatMax(f64)`, and IEEE negation is exact, so `neg_inf` and `-float_max`
/// are the other two. Only what the comparisons cost moved.
const pos_inf: f64 = @bitCast(@as(u64, 0x7FF0_0000_0000_0000));
const neg_inf: f64 = -pos_inf;
const float_max: f64 = @bitCast(@as(u64, 0x7FEF_FFFF_FFFF_FFFF));

comptime {
    // A mistyped digit above would move the finite end of a ray by a ULP at
    // the top of the format, and every answer built on that ray moves with
    // it, so the identity is checked rather than asserted in a comment. It
    // costs three `reconstructFloat` evaluations once per translation unit,
    // against the per-call cost the patterns above exist to remove.
    @setEvalBranchQuota(2_000);
    std.debug.assert(pos_inf == std.math.inf(f64));
    std.debug.assert(neg_inf == -std.math.inf(f64));
    std.debug.assert(float_max == std.math.floatMax(f64));
}

/// The product of two corner operands, taken as an exact zero whenever
/// either factor is zero.
///
/// A product with a zero factor is zero whatever the other factor is,
/// and that is a fact about reals rather than about the format. IEEE
/// 754 does not hold it in the one case that matters here: it answers
/// 0 * inf with a NaN. A NaN corner does not survive the reduction
/// below, and all four can be NaN at once, when one factor is the
/// degenerate {0} and the other carries an infinity at both of its
/// ends. The min and the max are then handed four NaNs and report a
/// NaN, where the exact image is {0}.
///
/// The sign is the exclusive or of the operand signs, which is the sign
/// IEEE itself gives every zero-factor product it does define, so a
/// corner that IEEE already answered exactly keeps the value it had.
/// Such a corner is not undersized, exactly as no corner with an
/// exactly-zero operand ever is, so loBound and hiBound leave the zero
/// where it is instead of stepping past a value that was never lost.
fn cornerProduct(a: f64, b: f64) f64 {
    if (a == 0.0 or b == 0.0) {
        const a_bits: u64 = @bitCast(a);
        const b_bits: u64 = @bitCast(b);
        return @bitCast((a_bits ^ b_bits) & sign_mask);
    }
    return a * b;
}

/// The two endpoints of one quotient corner: a point wherever IEEE 754
/// computed a quotient, the whole line wherever it computed none. Two
/// endpoints rather than one value, because the indeterminate corner is the
/// line itself and no single f64 says so — a NaN does not reduce, and an
/// infinity narrows the line to one of its two halves.
const CornerQuotient = struct {
    lo: f64,
    hi: f64,
};

/// The quotient of two corner operands: the f64 IEEE 754 computed, or the two
/// endpoints of the whole line where it computed the one undefined division
/// that has an answer.
///
/// A division is invalid in exactly two cases, and div has already answered
/// one of them. 0 / 0 needs a zero in the divisor, and the check at the head
/// of div returns the whole line for it. inf / inf needs an infinity in the
/// divisor instead, so that check never sees it and the corner arrives as a
/// NaN. A NaN does not survive the reduction: @min and @max have no order to
/// apply to it, and four of them reduce to a NaN, which is an interval
/// containing nothing at all — the one answer a caller of an enclosure
/// cannot use, since every membership query against it reads "no".
///
/// The corner IEEE declines becomes the whole line rather than something
/// narrower, because read as the finite reals the two infinities stand for,
/// the quotient of two unbounded magnitudes has no bound in either
/// direction: either one can outrun the other by any factor. Two operands
/// of the same sign do bound the quotient below by zero, and [0, inf] would
/// be sound there, but reading a sign off two operands to get it is a
/// per-quadrant case analysis in the one place mul's doc says this kind of
/// code goes wrong. The whole line is also the answer div already gives a
/// divisor containing zero and the one its own doc promises, so the two
/// undefined divisions get one answer.
///
/// That answer is for the indeterminate form ALONE: both operands infinite,
/// and nothing else. A quotient is a NaN for two unrelated reasons, and only
/// one of them is undefined arithmetic. inf / inf, -inf / -inf and inf / -inf
/// are all that form — neither operand is a real number, each stands for an
/// unbounded set of finite reals — and all three get the line. The other is an
/// operand that is itself a NaN: 1 / nan, nan / 1, nan / nan and inf / nan
/// all carry one, and none of them is a quotient with no bound. Such an
/// operand is a poisoned value rather than an indeterminate quotient, and the
/// contract for it is the `lo <= hi` check in Interval.init, which a NaN
/// endpoint fails because NaN compares false against everything. Widening it
/// here would hand the caller the one answer an enclosure can always use and
/// report no trap at all, so the NaN is passed through as the point it is and
/// div's reduction carries it to that check.
///
/// Both operands are asked, not one. inf / nan has an infinite dividend and
/// is still the NaN case, and code that read the dividend alone would put it
/// in the first group and swallow it. isInf is false for a NaN, so the second
/// operand alone settles it.
///
/// A zero dividend over an infinite divisor is not one of the invalid
/// cases. IEEE 754 defines 0 / inf as a signed zero, and it is passed
/// through unchanged: the exact quotient is zero, nothing was lost, and a
/// bound at zero is the truth there rather than a gap.
fn cornerQuotient(a: f64, b: f64) CornerQuotient {
    var v = a / b;
    if (v == 0.0 and a != 0.0 and std.math.isFinite(b)) {
        // Zig 0.16's software __divdf3 flushes subnormal quotients to
        // zero. Lift the quotient by 2^54, then scale it back with a
        // multiplication, whose software implementation preserves them.
        //
        // Here |a/b| < 2^-1022 and |b| <= floatMax, so |a| < 4:
        // a * 2^54 is exact and cannot overflow. Any representable
        // nonzero quotient becomes normal. If the lifted quotient still
        // flushes, the true result is below one quarter of min_subnormal.
        // Otherwise the division error after scaling back is at most one
        // quarter of min_subnormal; the multiplication adds at most half.
        // The existing one-step bounds cover both errors and lost zeros.
        v = ((a * 0x1p54) / b) * 0x1p-54;
    }
    // Both operands infinite is the indeterminate form and the only NaN
    // corner with an answer. Anything else that came back a NaN came back
    // that way because an operand was one, and it stays a NaN.
    if (std.math.isNan(v) and std.math.isInf(a) and std.math.isInf(b)) {
        return .{ .lo = -std.math.inf(f64), .hi = std.math.inf(f64) };
    }
    return .{ .lo = v, .hi = v };
}

/// True when a corner's value is a signed zero standing in for a magnitude
/// f64 could not hold rather than for an attained zero. A product or a
/// quotient of two nonzero operands is a nonzero real, so a zero out of one
/// has lost a magnitude the reduction cannot recover, because it compares
/// numbers and +0.0 equals -0.0. A corner with an exactly-zero operand is
/// the other case and is not one: that product is exactly zero whatever the
/// other factor is, nothing was lost, and a bound at the zero is the truth.
///
/// The question is asked about the operands rather than about the value
/// because the value is the thing being questioned: its sign is the one
/// part of it the reduction has already thrown away, and both callers need
/// the same rule stated once rather than twice.
fn lostToZero(a: f64, b: f64) bool {
    return a != 0.0 and b != 0.0;
}

/// The four corners of a product or a quotient: the four values the
/// reduction runs on, and the two endpoints behind each of them.
///
/// The operands are kept rather than a verdict. Multiplying or dividing two
/// non-zero operands can produce a true value too small to represent, and
/// f64 answers that with a zero of the sign the operands give. The zero has
/// lost both the magnitude and the sign the reduction discarded, and a min
/// or a max over the corners cannot recover either, because it compares
/// numbers and +0.0 equals -0.0. So the operands stay where the reduction
/// can still reach them and answer for a value no f64 holds.
///
/// Keeping them is enough, and keeping a per-corner BOOL beside them is not
/// merely unnecessary but is what a compiler will spill: four f64 values
/// scalarise into registers, four bytes do not, so the flags became four
/// stores and three unconditional reloads on every call — the reloads sit
/// above the `v == 0.0` guard, so they carry an answer that is dead unless
/// the reduced extremum is exactly zero. The predicate needs both operands
/// and the value beside them, and it is only ever asked after the
/// reduction has come back a zero, so the operands are read then and the
/// flag is never built.
const Corners = struct {
    /// The endpoints of the dividend, as lo then hi.
    a: [2]f64,
    /// The endpoints of the divisor, in the same order.
    b: [2]f64,
    /// The four values, indexed as `a[i] * b[j]` with `2 * i + j`.
    v: [4]f64,

    /// The smallest of the four values.
    fn lowest(self: Corners) f64 {
        return @min(@min(self.v[0], self.v[1]), @min(self.v[2], self.v[3]));
    }

    /// The largest of the four values.
    fn highest(self: Corners) f64 {
        return @max(@max(self.v[0], self.v[1]), @max(self.v[2], self.v[3]));
    }

    /// True when some corner attaining `x` is undersized, so `x` is a
    /// signed zero standing in for a value f64 could not hold rather than
    /// for a zero. Which corners those are is lostToZero's rule, asked
    /// here and only here after the reduction has come back a zero.
    ///
    /// The test on the value is `==`, which holds across the pair of signed
    /// zeros, so the answer does not depend on which of the two patterns
    /// the reduction happened to keep.
    fn undersizedAt(self: Corners, x: f64) bool {
        for (0..2) |i| {
            for (0..2) |j| {
                if (lostToZero(self.a[i], self.b[j]) and self.v[2 * i + j] == x) return true;
            }
        }
        return false;
    }

    /// Lower bound of the reduction, widened outward.
    ///
    /// When the extremum is a zero and no exactly-zero operand explains
    /// it, the true value is a small number on the far side of zero, and a
    /// bound that stops at the zero excludes it. So the bound steps out to
    /// the smallest subnormal. Sign multiplication is exact however far
    /// the magnitude underflows, which is why the operands can answer for
    /// a value no f64 holds, and why no direction of the step has to be
    /// guessed from the reduced zero: the lower bound always steps down.
    ///
    /// An extremum that really is zero keeps its bound at zero. Nothing is
    /// undersized then, the value is attained, and widening it would
    /// replace an exact answer with a weaker one.
    fn loBound(self: Corners) f64 {
        const v = self.lowest();
        // One step of the format's smallest positive subnormal, the value
        // `rounding` owns. A corner that underflowed has a true magnitude
        // under half of it, so one step of that size is the narrowest that
        // still contains every such corner.
        if (v == 0.0 and self.undersizedAt(v)) return -rounding.min_subnormal;
        return rounding.roundDown(v);
    }

    /// Upper bound of the reduction, widened outward, the mirror of
    /// loBound: the step for an undersized zero goes up.
    fn hiBound(self: Corners) f64 {
        const v = self.highest();
        if (v == 0.0 and self.undersizedAt(v)) return rounding.min_subnormal;
        return rounding.roundUp(v);
    }
};

/// A closed interval [lo, hi] over f64, canonical when:
///
///   * `lo <= hi`;
///   * `lo` is not `+inf`;
///   * `hi` is not `-inf`;
///   * neither endpoint is a NaN.
///
/// Finite bounds denote the ordinary closed real interval, and a `-inf`
/// lower bound or a `+inf` upper bound means unbounded in that direction.
/// `init` supplies canonical intervals and every operation here preserves
/// the four conditions from canonical inputs under their stated
/// preconditions. A raw struct literal is not normalized on the way in, so
/// a caller who writes one holds the same obligation a caller of `init`
/// does.
///
/// Two argument shapes have no canonical pair of their own — both ends at
/// the same infinity — and `init` maps them to the conservative overflow
/// ray `[floatMax, +inf]` and its mirror `[-inf, -floatMax]`. That mapping
/// is a policy rather than the only sound choice: `[-inf, +inf]` is sound
/// for the same inputs and wider. The ray is what this library settles on
/// because it keeps as much of the answer as the two endpoints carry, and
/// it is the pair every downstream operation is written against. No other
/// shape moves, so a finite pair and a pair with one infinite end come back
/// field for field.
pub const Interval = struct {
    lo: f64,
    hi: f64,

    /// Build [lo, hi]. Callers must pass lo <= hi; a violation is diagnosed
    /// by `std.debug.assert` in Debug and ReleaseSafe and the check is
    /// elided in ReleaseFast and ReleaseSmall, so the condition is a
    /// precondition rather than a guarantee that holds in every build.
    ///
    /// The ordering is asserted BEFORE the normalization below rather than
    /// after, so the check still sees the pair the caller wrote: a NaN
    /// endpoint fails `lo <= hi` because a NaN compares false against
    /// everything, and a poison scalar is exactly what that comparison is
    /// there to catch.
    ///
    /// The normalization then supplies the two canonical rays described on
    /// the type. It is two comparisons and two selections on a path every
    /// operation in this file already runs, and it is deliberately not a
    /// second constructor, a helper, or a field: one place knows what a
    /// canonical pair is, and `hull`, `hullOf`, `intersect` and
    /// `intersectionOf` get canonicality from their inputs rather than from
    /// a normalizer on the hot path.
    pub fn init(lo: f64, hi: f64) Interval {
        std.debug.assert(lo <= hi);
        return .{
            .lo = if (lo == pos_inf) float_max else lo,
            .hi = if (hi == neg_inf) -float_max else hi,
        };
    }

    /// True when x lies in [lo, hi], endpoints inclusive, which is the
    /// bounds comparison `self.lo <= x and x <= self.hi` and nothing more.
    ///
    /// For a finite x that is the whole of it, and the normalized fields are
    /// what it reads: an overflow ray contains its own finite frontier and
    /// every real above or below it, and no real on the other side of zero.
    /// For a non-finite x the comparison is still just the comparison, so a
    /// ray whose `hi` is `+inf` also answers `contains(+inf)` — that value
    /// is on the closed bound, not outside it. Callers asking whether a box
    /// admits an extended-real point are asking something this predicate
    /// does not answer; `eql` below sees the normalized fields instead.
    pub fn contains(self: Interval, x: f64) bool {
        return self.lo <= x and x <= self.hi;
    }

    /// Smallest interval covering both self and other.
    ///
    /// Built from a struct literal rather than through `init`, like the
    /// three below it: the min and the max of two canonical pairs are
    /// canonical, so there is nothing for `init` to supply and nothing for
    /// it to catch. That closure is a statement about canonical INPUTS, and
    /// it says nothing about invalid ones: an inverted or poisoned operand
    /// is not validated here and not repaired here, and `@min` and `@max`
    /// have no order to apply to a NaN. Hardening those is not in scope,
    /// and the caller who breaks the precondition owns what comes out.
    pub fn hull(self: Interval, other: Interval) Interval {
        return .{
            .lo = @min(self.lo, other.lo),
            .hi = @max(self.hi, other.hi),
        };
    }

    /// Smallest interval covering all of items, or null when empty.
    pub fn hullOf(items: []const Interval) ?Interval {
        if (items.len == 0) return null;
        var lo = items[0].lo;
        var hi = items[0].hi;
        for (items[1..]) |it| {
            lo = @min(lo, it.lo);
            hi = @max(hi, it.hi);
        }
        return .{ .lo = lo, .hi = hi };
    }

    /// Common intersection of all of items, or null when empty or disjoint.
    pub fn intersectionOf(items: []const Interval) ?Interval {
        if (items.len == 0) return null;
        var lo = items[0].lo;
        var hi = items[0].hi;
        for (items[1..]) |it| {
            lo = @max(lo, it.lo);
            hi = @min(hi, it.hi);
        }
        if (lo > hi) return null;
        return .{ .lo = lo, .hi = hi };
    }

    /// Shared region, or null when the intervals are disjoint.
    pub fn intersect(self: Interval, other: Interval) ?Interval {
        const lo = @max(self.lo, other.lo);
        const hi = @min(self.hi, other.hi);
        if (lo > hi) return null;
        return .{ .lo = lo, .hi = hi };
    }

    /// Length of the interval, hi - lo.
    pub fn width(self: Interval) f64 {
        return self.hi - self.lo;
    }

    /// True when the intervals share at least one point.
    pub fn overlaps(self: Interval, other: Interval) bool {
        return self.lo <= other.hi and other.lo <= self.hi;
    }

    /// True when self is fully contained in other.
    pub fn subsetOf(self: Interval, other: Interval) bool {
        return other.lo <= self.lo and self.hi <= other.hi;
    }

    /// Center of the interval, (lo + hi) / 2.
    ///
    /// Two roundings, and a bare f64, so this is a value and not a bound.
    /// It can sit half an ULP either side of the exact centre, and half an
    /// ULP is wider than the nearest representable pair, so no interval
    /// formed around it is tighter than one formed around the exact centre
    /// and a consumer that needs a midpoint as a BOUND cannot use this to
    /// get one. It is also not a sound place to start from: the sum
    /// overflows for a box at the top of the range where the centre does
    /// not. An operation that needs a midpoint as a bound, scale among
    /// them, encloses the sum itself, which is why the two share no helper.
    pub fn midpoint(self: Interval) f64 {
        return (self.lo + self.hi) / 2.0;
    }

    /// Clamp x into [lo, hi]. Values below lo map to lo, above hi to hi.
    pub fn clamp(self: Interval, x: f64) f64 {
        return @min(@max(x, self.lo), self.hi);
    }

    /// Shift lo and hi by delta, preserving the width. Each endpoint is one
    /// correctly rounded addition, so a single outward step per side covers
    /// its half ULP and turns the shift into a bound.
    ///
    /// A shift IS an add, and it is written as one: `add` against the point
    /// `[delta, delta]`. For a finite delta the two forms are the same two
    /// roundings on the same two sums, so nothing numerical moves here.
    ///
    /// What the form buys is the infinite delta. An infinite delta is the
    /// scalar overflow ray, which carries two endpoints, and `init` is what
    /// supplies them — the shift sums against `[floatMax, +inf]` or
    /// `[-inf, -floatMax]`. Read as the NUMBER `+inf` the low end would come
    /// back at floatMax for a box such as `[-floatMax, floatMax]`, whose
    /// image runs from zero upward, so that bound sits above the image; read
    /// as the ray it comes back a step lower and holds it.
    ///
    /// Built through init, so the lo <= hi invariant is checked rather than
    /// assumed. Rounding cannot break it for an ordered pair: a correctly
    /// rounded addition is monotone, so a shift of an ordered pair stays
    /// ordered however it rounds. What can break it is a NaN delta, which
    /// fails the same ordering comparison init applies to every interval in
    /// this file, and which is a scalar the caller got wrong rather than an
    /// answer this function owes one.
    pub fn translate(self: Interval, delta: f64) Interval {
        return self.add(Interval.init(delta, delta));
    }

    /// Half of the interval, widened outward: the image of `self` under
    /// `x -> x / 2`, guaranteed to contain the true half.
    ///
    /// **It is never wider than the bound `div` returns, and is tighter in one
    /// case.** That is why it is public rather than private. A caller halving
    /// an interval for a midpoint, a step size or a scale factor wants this
    /// and not `div`, because `div` spends a repair on a rounding loss that
    /// this operation can prove cannot happen here. It was private, and
    /// documented, and unreachable by the one caller that had a use for it.
    ///
    /// The one division in this file that does not go through `div`, and the
    /// reason it need not is that halving is an operation with a stated
    /// precondition rather than an error budget: it is exact at every value
    /// outside the subnormal range, so the single outward step left over
    /// covers the whole of what rounding can do, and the subnormal range is
    /// one comparison away.
    ///
    /// The repair is the part of div that earns its keep here, so it is
    /// kept rather than assumed. Halving a normal is exact — the exponent
    /// drops and the significand is untouched — and a subnormal is the one
    /// value where that fails: 2^-1075 halved is 2^-1076, which is half a
    /// step of the subnormal grid and so rounds to a signed zero. The true
    /// half is a nonzero number of the endpoint's sign, so a bound stopping
    /// at that zero excludes it. Which way the step goes is not a guess: the
    /// lower bound steps down and the upper one up, and the only endpoint
    /// that can ask for either is one that is itself a nonzero value f64
    /// could not hold halved — an exact zero halves to an exact zero, which
    /// is already its own bound.
    ///
    /// That is the whole of div's repair, restricted to the one endpoint
    /// being halved, so this is the same bound as div returns or a tighter
    /// one and never a wider one. It is tighter in exactly the case where
    /// div's is needlessly cautious: halving [-0, 2^-1075] puts the real 0
    /// in the image, div steps the lower bound out to -2^-1075 because the
    /// other endpoint's half is a lost magnitude, and the step here is not
    /// asked for at all. The step is `rounding.min_subnormal`, one such
    /// subnormal out, the width every lost half fits inside.
    pub fn halve(self: Interval) Interval {
        const lo = self.lo / 2.0;
        const hi = self.hi / 2.0;
        return Interval.init(
            if (lo == 0.0 and self.lo != 0.0) -rounding.min_subnormal else rounding.roundDown(lo),
            if (hi == 0.0 and self.hi != 0.0) rounding.min_subnormal else rounding.roundUp(hi),
        );
    }

    /// Scale about the midpoint, preserving lo <= hi by using |factor|
    /// for the width.
    ///
    /// The exact image is [M - W, M + W] with M = (lo + hi) / 2 and
    /// W = (hi - lo) * |factor| / 2 taken as reals. Neither is an f64 and
    /// each is a chain of rounded operations, so neither can be a bound in
    /// its own right: a bound has to bound the whole chain, and the error
    /// of a chain is not the error of its last step. So both are enclosed
    /// first, the way everything else here is, and the answer is composed
    /// out of add, sub and mul rather than widened by a fixed number
    /// of ULP from the outside. A fixed count is a guess at what the chain
    /// accumulated, it is only ever a guess, and it is worst exactly where
    /// the two intermediates sit in different binades, where a step taken
    /// on the small one pays for nothing on the large one.
    ///
    /// That paragraph is not an assertion, it is a measured result, and the
    /// measurement is `docs/scale-enclosure.md`. Item O1 of
    /// `docs/next-work-plan.md` asked for the enclosure a direct formulation
    /// would need — one outward step per endpoint, against the six this one
    /// spends — and the argument there is that no fixed number of steps
    /// supplies it. One step buys half an ULP of the ENDPOINT; the chain
    /// delivers an error on the scale of an ULP of the MIDPOINT; and on
    /// `[-1, 2^k]` at `|factor| = 1 - 2^-53` the two differ by `2^(k-1)`,
    /// with no ceiling. On that family the fused form returns a lower bound
    /// `2^39 - 3/2` ULP above the true one at `k = 40`, and a sweep of 2.9
    /// million cases finds it unsound on 14 to 27 % of them while this
    /// form is sound on all of them. So the six steps stay, and this is
    /// what they buy: each one's outwardness is the budget the next one
    /// spends, which is the only reason the cancellation at the end is
    /// paid for at all.
    ///
    /// Each arm then puts both of its terms on the protective side: the
    /// lower bound subtracts an upper half-width from a lower midpoint,
    /// the upper bound adds an upper half-width to an upper midpoint. Each
    /// partial sum is already a bound before the step that sub and add
    /// apply, and that step has only the rounding of the sum itself left to
    /// cover. Stepping the half-width the other way on the lower arm is
    /// the trap: a smaller half-width RAISES the very bound it is there to
    /// lower, and no widening anywhere else recovers it.
    ///
    /// The midpoint is load-bearing rather than convenient, and there is a
    /// shorter algebra available that this form exists to reject. Over the
    /// reals, with g = |factor|,
    ///
    ///     M - W = lo + (hi - lo)(1 - g) / 2
    ///     M + W = hi - (hi - lo)(1 - g) / 2
    ///
    /// so the sum that forms the midpoint and the midpoint itself can
    /// both be dropped and the composition loses two operations. It is
    /// unsound, and the reason is the sentence above turned into a
    /// measurement: each of those two arms is protective in ONE direction
    /// only, because the term's sign follows the sign of (1 - g), which is
    /// a property of the caller's factor and not of the box. A half-width
    /// enclosed too WIDE is therefore subtracted on one arm and added on
    /// the other, and on the arm where it is subtracted it drags the bound
    /// inside the image. The form here has no such arm: the lower bound
    /// subtracts an upper half-width and the upper bound adds that SAME
    /// upper half-width — `m.sub(w)` and `m.add(w)` share one enclosure of
    /// W — so a loose enclosure of W can only widen the answer, which is the
    /// whole point of composing enclosures.
    ///
    /// Two consequences, both measured rather than argued. In the
    /// subnormal range an enclosure of a half-width is several ULP wide,
    /// and [0, 2^-1074] at factor zero has the exact image {2^-1075}, which
    /// the short form answers with [0, -2^-1074]: inverted, and missing the
    /// point it is supposed to be. At the top of the range the same arm
    /// meets an infinity. The half-width of a box spanning the whole format
    /// has no f64 enclosure short of one, because roundUp(floatMax) is
    /// +inf, so [-floatMax, floatMax] at factor zero — the exact image is
    /// {0}, and the form here answers [0, 0] — comes back from the short
    /// form as [-8.988e307, -floatMax], which excludes 0 outright. The
    /// centre is the whole reason a box at the frontier still returns a box.
    ///
    /// Halving by two is exact everywhere but the subnormal range, and the
    /// hand step above is what carries the repair for the range where it is
    /// not: the smallest subnormal 2^-1074 halves to 2^-1075, a tie that
    /// rounds away to a signed zero, and a bound stopping at that zero drops
    /// a value the machine only just failed to hold. No slack added
    /// afterwards reinstates it, because by then the information is gone.
    /// div would carry the same repair, and pay for it with four corner
    /// quotients and both bounds every time, three times over, to divide by
    /// the one constant the format can answer exactly.
    ///
    /// Both intermediates have a second route, and each is taken where the
    /// other leaves the range. A sum or a difference past floatMax is an
    /// infinity standing for a real the format cannot hold: it bounds
    /// correctly and answers nothing, so there the halves come first and
    /// stay inside. The width still multiplies before it halves even there,
    /// because halving a subnormal width first would round away an
    /// absolute error that the factor then turns into a relative one.
    ///
    /// Composing costs width, and that is the price: the answer runs a few
    /// ULP wider than the image and wider still at the two ends of the
    /// range, where a step outward from floatMax has nowhere left to go.
    /// Containment is the claim here, not tightness.
    ///
    /// Composed through init, so the lo <= hi invariant is checked rather
    /// than assumed. It does hold for every ordered input, and each arm
    /// carries its own guarantee, but only as a theorem about the pair:
    /// the lower endpoint bounds M - W and the upper one bounds M + W, and
    /// the two are ordered because W is nonnegative — nothing says the
    /// centre M is itself nonnegative, and for a box below zero it is not.
    /// Nothing local to this return shows that, which makes it the one
    /// place in this file where an assertion still has something to catch.
    ///
    /// The one case the composed form has no centre for is an UNBOUNDED
    /// box, and it is answered before the algebra starts rather than
    /// composed. Both arms of the composition start from the sum of the two
    /// endpoints, and that sum overflows on one side or the other for every
    /// box with an infinite end, so the centre it produces is an infinity
    /// and the endpoints that reach `init` are a NaN pair. It is answered
    /// after the factor has been validated, because a NaN factor is a
    /// scalar the caller got wrong and not an unbounded box.
    ///
    /// What it answers with is a policy, not a derivation. There is no
    /// finite midpoint of an unbounded box to scale about, so this function
    /// picks a safe answer instead of computing one: at |factor| == 1 the
    /// box comes back unchanged, and at any other factor it comes back as
    /// the whole line. Both are sound, and the second is far wider than the
    /// true image needs. A positive ray scaled by a factor below one stays
    /// inside that same ray for every one of its finite completions, so the
    /// union over completions does NOT run out in both directions the way a
    /// factor above one makes it. The line is chosen because it is the one
    /// answer that holds for every completion of an unbounded box at every
    /// factor without a centre having to be invented for any of them, and
    /// it is the answer a caller can act on. Tightness is not claimed here
    /// and is not available here.
    pub fn scale(self: Interval, factor: f64) Interval {
        const f = Interval.init(@abs(factor), @abs(factor));
        if (self.lo == -std.math.inf(f64) or self.hi == std.math.inf(f64)) {
            if (@abs(factor) == 1.0) return self;
            return Interval.init(-std.math.inf(f64), std.math.inf(f64));
        }
        // M from the sum of the endpoints where that sum stays in range,
        // and from their halves where the sum leaves it.
        const sum = Interval.init(self.lo, self.lo).add(Interval.init(self.hi, self.hi));
        const m = if (std.math.isFinite(sum.lo) and std.math.isFinite(sum.hi))
            sum.halve()
        else
            Interval.init(self.lo, self.lo).halve().add(Interval.init(self.hi, self.hi).halve());
        // W from the width itself where the width stays in range, the
        // multiply ahead of the halving so that a subnormal width is
        // lifted back out of the subnormal range by the factor before
        // anything halves it, and from the halved width where the
        // difference itself has left the range.
        const diff = Interval.init(self.hi, self.hi).sub(Interval.init(self.lo, self.lo));
        const w = if (std.math.isFinite(diff.lo) and std.math.isFinite(diff.hi))
            diff.mul(f).halve()
        else
            Interval.init(self.hi, self.hi).halve().sub(Interval.init(self.lo, self.lo).halve()).mul(f);
        return Interval.init(m.sub(w).lo, m.add(w).hi);
    }

    /// Widen both ends by margin when positive, shrink both when negative.
    /// Requires margin >= -(hi - lo) / 2 for a bounded box; a more negative
    /// margin inverts the interval, which `init`'s ordering check diagnoses
    /// in Debug and ReleaseSafe and which is a precondition violation rather
    /// than a guarantee in ReleaseFast and ReleaseSmall.
    ///
    /// Each end is one correctly rounded operation, so as in add the
    /// outward step per side is the whole of the widening. A zero margin
    /// widens too: lo - 0.0 and hi + 0.0 are exact, and the step is what
    /// makes them bounds. An infinite margin needs no branch of its own: a
    /// margin of `+inf` already walks the low end to `-inf` and leaves the
    /// high one at `+inf`, so the whole line is what this body returns for
    /// any canonical input.
    ///
    /// A margin of `-inf` does need one, because it is a ray of margins
    /// rather than a single one. Read as the NUMBER `-inf` it asks for the
    /// pair `(+inf, -inf)`, which inverts. What it denotes is every margin at
    /// or below `-floatMax`, and the answer is the union over that ray: for
    /// an unbounded box that is `[roundDown(lo + floatMax), roundUp(hi -
    /// floatMax)]`, each end reached at the last margin in the ray and each
    /// side still unbounded in its own direction. `[-floatMax, +inf)` gives
    /// `[0, +inf)` and `(-inf, floatMax]` gives `(-inf, 0]`.
    ///
    /// No margin in that ray is legal for a BOUNDED box, which is why the
    /// branch states the requirement instead of clipping the ray to the one
    /// admissible margin: `[-floatMax, floatMax]` is no more valid there than
    /// `[0, 1]` is. The check is the same kind of precondition as the one
    /// above — diagnosed by the checked builds, and a contract the unchecked
    /// builds do not police — and it is written here rather than left to
    /// the ordering check so that the reason is on the same screen as the
    /// requirement.
    pub fn expand(self: Interval, margin: f64) Interval {
        if (margin == -std.math.inf(f64)) {
            std.debug.assert(self.lo == -std.math.inf(f64) or self.hi == std.math.inf(f64));
            return Interval.init(
                rounding.roundDown(self.lo + std.math.floatMax(f64)),
                rounding.roundUp(self.hi - std.math.floatMax(f64)),
            );
        }
        return Interval.init(
            rounding.roundDown(self.lo - margin),
            rounding.roundUp(self.hi + margin),
        );
    }

    /// Distance from x to the interval: 0 inside [lo, hi], otherwise the
    /// distance to the nearest endpoint.
    pub fn distanceTo(self: Interval, x: f64) f64 {
        if (x < self.lo) return self.lo - x;
        if (x > self.hi) return x - self.hi;
        return 0.0;
    }

    /// Sum, widened outward by one ULP on each side. Addition is monotone
    /// in both operands, so the exact range of self + other is
    /// [self.lo + other.lo, self.hi + other.hi].
    ///
    /// The underflow repair mul and div need does not apply, and the reason
    /// is a property of the format rather than of luck. Every f64 is an
    /// integer multiple of 2^-1075, so the exact sum of two of them is too.
    /// A nonzero exact sum at or below the smallest normal is therefore
    /// exactly representable as a subnormal and comes back exactly; one
    /// above it rounds by at most half a ULP, which the single step already
    /// absorbs. A sum that comes out as a zero is thus a sum that is zero,
    /// and the bound at zero is the truth rather than a loss.
    ///
    /// Canonical inputs make this body the whole of the answer at the
    /// overflow rays too, and the reason is the invariant rather than a case
    /// analysis here. A NaN can only come out of `+` where one operand is
    /// `+inf` and the other `-inf`, and no lower bound is `+inf` and no upper
    /// bound is `-inf`, so no corner can be NaN. The two overflow rays added
    /// to each other give the whole line, which is also their exact image:
    /// writing them as floatMax + a and -floatMax - b with a and b at or
    /// above zero, the sum is a - b, and that is every real.
    pub fn add(self: Interval, other: Interval) Interval {
        return Interval.init(
            rounding.roundDown(self.lo + other.lo),
            rounding.roundUp(self.hi + other.hi),
        );
    }

    /// Difference self - other, widened outward. The pairing crosses: the
    /// lower bound of the result takes self.lo against other.hi, because
    /// subtracting the larger element of other is what can push the sum
    /// furthest down. Pairing lo with lo instead would be the bug this
    /// form exists to avoid.
    ///
    /// Both ends are correctly rounded sums, so add's argument about
    /// underflow carries over unchanged: a nonzero exact difference is
    /// never rounded down onto a zero, and a zero endpoint is exact.
    ///
    /// The canonical invariant is what keeps this body NaN-free as well. A
    /// NaN out of `-` needs `+inf` on one side and `-inf` on the other, and
    /// the two ends this pairs cannot be the ones that carries it: `self.lo`
    /// is never `+inf` and `other.hi` is never `-inf` on the lower bound, and
    /// `self.hi` is never `-inf` and `other.lo` is never `+inf` on the upper
    /// one. A same-ray difference is therefore the whole line, which is its
    /// exact image — a ray against itself reaches zero at floatMax and every
    /// real on either side of it.
    pub fn sub(self: Interval, other: Interval) Interval {
        return Interval.init(
            rounding.roundDown(self.lo - other.hi),
            rounding.roundUp(self.hi - other.lo),
        );
    }

    /// Additive inverse. IEEE 754 negation is exact, so no widening
    /// applies, but the endpoints swap: the image of [lo, hi] is
    /// [-hi, -lo], and emitting [-lo, -hi] would invert the interval.
    ///
    /// The reflection of an overflow ray is the other one rather than a
    /// degenerate pair: `[-floatMax, +inf]` maps to `[-inf, -floatMax]`, and
    /// both of those are canonical, so the round trip closes on a ray at
    /// each end instead of on a point.
    pub fn neg(self: Interval) Interval {
        return Interval.init(-self.hi, -self.lo);
    }

    /// Product, widened outward. The extreme products of two intervals
    /// always occur at a pair of endpoints, so evaluating all four and
    /// taking the min and the max encloses the exact product set. That
    /// form needs no sign case analysis: it is the same four products in
    /// every quadrant, and per-quadrant special cases are where this kind
    /// of code goes wrong.
    ///
    /// The corners carry their operands because a product of two non-zero
    /// operands can be too small to hold, and f64 answers that with a zero
    /// of the operands' sign. The min and the max then compare zeros,
    /// cannot tell those signs apart, and a bound stopping at the zero
    /// leaves out the value that was lost. loBound and hiBound step past a
    /// zero that no exactly-zero operand explains, and only that one.
    ///
    /// A corner with a zero factor is the opposite case, and cornerProduct
    /// is what answers it. That product is exactly zero, nothing was lost,
    /// and IEEE 754 still declines to say so for an infinite other factor,
    /// where it produces a NaN the reduction cannot use. The image of a
    /// product containing such a corner contains that zero, so a bound at
    /// zero is the truth there and not a loss, exactly as it already is for
    /// the corner of an exact zero that loBound and hiBound leave alone.
    pub fn mul(self: Interval, other: Interval) Interval {
        const corners = Corners{
            .a = .{ self.lo, self.hi },
            .b = .{ other.lo, other.hi },
            .v = .{
                cornerProduct(self.lo, other.lo),
                cornerProduct(self.lo, other.hi),
                cornerProduct(self.hi, other.lo),
                cornerProduct(self.hi, other.hi),
            },
        };
        return Interval.init(corners.loBound(), corners.hiBound());
    }

    /// Where an interval sits relative to zero, in the four arms every
    /// widening bound asks for before it can move an endpoint. The
    /// question is the same everywhere and has been asked in three
    /// different spellings in three different files, only one of which
    /// the other two could reach.
    pub const Sign = enum {
        /// hi < 0. Wholly below zero.
        negative,
        /// lo > 0. Wholly above zero.
        positive,
        /// The point zero, and nothing else. A structural bound and a
        /// point coefficient are what produce it, and +0.0 equals -0.0
        /// so [0, -0] lands here as well.
        zero,
        /// Reaches zero and is not the point zero: lo <= 0 <= hi.
        straddle,
    };

    /// The trichotomy of self against zero. See Sign for the arms.
    ///
    /// `straddle` INCLUDES an interval that merely TOUCHES zero at one
    /// end, and that is deliberate and load-bearing. A coefficient of
    /// [0, mag] is non-negative: it bounds its variable from above
    /// alone, and reading it as a two-sided bound is how a projection
    /// comes back wrong. So the arm means REACHES ZERO, and [0, mag],
    /// [-mag, 0] and [-mag, mag] all land in it. What has to tell
    /// [0, mag] apart from [-mag, mag] is zeroSplit's question, not
    /// this one — powf is the caller that needs them apart, and mixing
    /// the two questions is what once let a vanishingly small positive
    /// base report a larger range than a zero one.
    ///
    /// The last arm is computed as the two comparisons rather than as
    /// the absence of a better answer, and that is the whole of this
    /// method's subtlety. An endpoint that is not a number compares
    /// false against zero in every direction, so a method ending in a
    /// bare `return .straddle` would report a poisoned interval as
    /// reaching zero. It must not. div, abs and sqr all branch on this
    /// arm, and each of them has to carry a poisoned interval PAST that
    /// branch so that init's `lo <= hi` check is what rejects it; an
    /// enclosure that answered [-inf, inf] instead would report no trap
    /// at all, which is the one answer this library must never give for
    /// a scalar the caller got wrong.
    ///
    /// A poisoned interval therefore answers `negative`, one of the two
    /// arms that do not reach zero. The choice between those two is
    /// made here, once, and is otherwise arbitrary: nothing downstream
    /// asks which of them a poison is, only that it is one of them.
    pub fn signOf(self: Interval) Sign {
        if (self.hi < 0.0) return .negative;
        if (self.lo > 0.0) return .positive;
        if (self.lo == 0.0 and self.hi == 0.0) return .zero;
        return if (self.lo <= 0.0 and 0.0 <= self.hi) .straddle else .negative;
    }

    /// Which parts of an interval lie on each side of zero. signOf folds
    /// [0, mag] in with [-mag, mag] because a bound asks only whether
    /// zero is reached; this is the question that has to separate them.
    ///
    /// powf is why the fold is not safe to lean on everywhere. A base of
    /// [0, mag] never takes a negative power and its image is bounded
    /// below by zero, while a base of [-mag, mag] has a part on each
    /// side and the two parts are raised separately. Both reach zero, so
    /// one rule covering both once let a vanishingly small positive base
    /// report a larger range than a zero one.
    pub const ZeroSplit = enum {
        /// hi < 0. One part, wholly below zero.
        negative,
        /// lo > 0. One part, wholly above zero.
        positive,
        /// The point zero, with nothing of substance either side.
        zero,
        /// [0, hi] with hi > 0. The part at or below zero is the
        /// degenerate point and the interval bounds from above alone.
        touches_above,
        /// [lo, 0] with lo < 0. The mirror: bounded from below alone.
        touches_below,
        /// lo < 0 < hi. A part below zero and a part above it, neither
        /// degenerate — the only arm with two parts of substance.
        straddles,
    };

    /// The parts of self on each side of zero, as a ZeroSplit.
    ///
    /// The parts themselves are read off self rather than returned, so
    /// there is no pair of intervals here for a caller to fill in
    /// wrongly: the part at or below zero is [lo, @min(hi, 0)] and the
    /// part at or above it is [@max(lo, 0), hi], whichever side the arm
    /// puts them on.
    ///
    /// The refinement is read off signOf rather than from a second pass
    /// over the endpoints, so the two cannot drift apart. `straddle`
    /// already states lo <= 0 <= hi, which is exactly what makes `lo == 0`
    /// and `hi == 0` the only two cases left to tell apart here.
    pub fn zeroSplit(self: Interval) ZeroSplit {
        return switch (self.signOf()) {
            .negative => .negative,
            .positive => .positive,
            .zero => .zero,
            .straddle => blk: {
                if (self.lo == 0.0) break :blk .touches_above;
                if (self.hi == 0.0) break :blk .touches_below;
                break :blk .straddles;
            },
        };
    }

    /// Quotient, widened outward, over the same four-endpoint argument as
    /// mul. A divisor that contains zero gives the unbounded interval
    /// [-inf, inf] rather than null: null would assert the image is empty,
    /// which is a different and much stronger claim, while 0/0 is
    /// reachable and the divisor can approach zero from either side. The
    /// unbounded answer is therefore both sound and the only one the
    /// caller can act on. It over-approximates in the sub-cases where the
    /// true quotient range is one-sided or a single point, which is the
    /// price of not inspecting the dividend. Those endpoints are the
    /// infinities themselves, so they need no widening.
    ///
    /// A quotient of two non-zero operands can underflow to a signed zero
    /// exactly as a product does, and the operands are already on hand
    /// here, so the same repair applies. An exactly-zero dividend still
    /// gives an exact zero quotient and keeps its bound at zero.
    ///
    /// A corner of two infinite operands is the other undefined division,
    /// and cornerQuotient is what answers it. It is unbounded in both
    /// directions rather than empty, and a line is both sound and the only
    /// enclosure a caller can act on, so it gets the same answer the
    /// divisor check above gives. No min or max over the other three
    /// corners can pull a bound back inside it, so the reduction is skipped
    /// rather than handed a NaN.
    ///
    /// A corner with a NaN OPERAND is not that case and is not answered
    /// here. cornerQuotient passes such a corner through as the NaN it is,
    /// the reduction below reduces four NaNs to a NaN, and init is then
    /// handed an endpoint that compares false against itself and traps in a
    /// checked build. That trap is the contract for a poisoned interval,
    /// and swallowing it into a bound here would be the one change that
    /// makes a wrong answer look like a working one.
    pub fn div(self: Interval, other: Interval) Interval {
        // Reaches zero. The structural [0, 0] and the zero-touching
        // [0, mag] are in this set for the same reason [-mag, mag] is,
        // so signOf's `zero` arm is part of the branch rather than an
        // early exit of its own.
        switch (other.signOf()) {
            .zero, .straddle => return Interval.init(-std.math.inf(f64), std.math.inf(f64)),
            .negative, .positive => {},
        }
        const q0 = cornerQuotient(self.lo, other.lo);
        const q1 = cornerQuotient(self.lo, other.hi);
        const q2 = cornerQuotient(self.hi, other.lo);
        const q3 = cornerQuotient(self.hi, other.hi);
        // A corner wider than a point is the whole line, and one that wide
        // settles the reduction on its own.
        if (q0.lo < q0.hi or q1.lo < q1.hi or q2.lo < q2.hi or q3.lo < q3.hi) {
            return Interval.init(-std.math.inf(f64), std.math.inf(f64));
        }
        const corners = Corners{
            .a = .{ self.lo, self.hi },
            .b = .{ other.lo, other.hi },
            .v = .{ q0.lo, q1.lo, q2.lo, q3.lo },
        };
        return Interval.init(corners.loBound(), corners.hiBound());
    }

    /// Reciprocal, the quotient of the point interval [1, 1] by self. The
    /// zero rule matches div: an interval containing zero yields the
    /// unbounded [-inf, inf], since the reciprocal of a vanishing
    /// magnitude is not a finite number.
    pub fn recip(self: Interval) Interval {
        return Interval.init(1.0, 1.0).div(self);
    }

    /// Magnitude, widened outward. When self contains zero the image
    /// starts at exactly 0.0, which is the best possible lower bound: a
    /// point of self may map to zero itself, so no outward widening can
    /// tighten it.
    ///
    /// Negation of the sign is exact, so a magnitude is always one of the
    /// two endpoint values and never a value f64 lost, and the two steps
    /// are the whole of the widening. The underflow question mul asks
    /// cannot arise here: the only zero among the magnitudes is an exact
    /// zero of an endpoint, and that endpoint maps to exactly zero, so a
    /// bound at zero is the truth rather than a loss.
    pub fn abs(self: Interval) Interval {
        const max_abs = @max(@abs(self.lo), @abs(self.hi));
        switch (self.signOf()) {
            // Reaches zero, the zero-touching [0, mag] included, so the
            // same `lo <= 0 <= hi` the doc above describes still holds:
            // a point of self maps to zero and no outward step can
            // tighten a bound that is already at it.
            .zero, .straddle => return Interval.init(0.0, rounding.roundUp(max_abs)),
            .negative, .positive => {},
        }
        const min_abs = @min(@abs(self.lo), @abs(self.hi));
        return Interval.init(rounding.roundDown(min_abs), rounding.roundUp(max_abs));
    }

    /// Square, widened outward. Squaring is not monotone across zero, so
    /// the branch is load-bearing rather than defensive: on an interval
    /// spanning zero the image is [0, max(lo*lo, hi*hi)], and computing
    /// min(lo*lo, hi*hi) unconditionally would put a lower bound below
    /// the smallest real square, which is zero.
    ///
    /// The upper bound needs the underflow repair mul needs, and for the
    /// same reason. A square of a nonzero endpoint is a nonzero value, so
    /// a maximum that came back as +0.0 is a magnitude f64 could not
    /// hold, and the true square is a small positive number that a bound
    /// at zero would cut off. The step goes up, because a square is
    /// nonnegative, and it is `rounding.min_subnormal` — one such
    /// subnormal up, which is the width the corner reduction of mul uses
    /// as well. The lower bound needs no repair at all, and unlike in
    /// mul widening it would be wrong: zero is below every value a square
    /// can take, so a bound at zero there is exact and stays put.
    pub fn sqr(self: Interval) Interval {
        const lo_sq = self.lo * self.lo;
        const hi_sq = self.hi * self.hi;
        const max_sq = @max(lo_sq, hi_sq);
        // Which endpoint produced the maximum decides it, as in mul: the
        // square of an exact zero is an exact zero, while the square of a
        // nonzero endpoint is a value f64 may have underflowed. One
        // nonzero endpoint is enough, because a tie between the two
        // squares leaves the maximum undersized if either of them is.
        const lost = lostToZero(self.lo, self.lo) or lostToZero(self.hi, self.hi);
        const undersized = max_sq == 0.0 and lost;
        const hi = if (undersized) rounding.min_subnormal else rounding.roundUp(max_sq);
        switch (self.signOf()) {
            // Reaches zero, and squaring is not monotone across it, so
            // the minimum is not taken here at all.
            .zero, .straddle => return Interval.init(0.0, hi),
            .negative, .positive => {},
        }
        return Interval.init(rounding.roundDown(@min(lo_sq, hi_sq)), hi);
    }

    /// Set equality, a certain comparison: true exactly when both
    /// endpoints match, which is exactly when the two intervals denote
    /// the same set. Certain comparisons never report a relation that is
    /// merely possible, so this needs no overlap case.
    ///
    /// It reads the normalized fields, which is the observable half of the
    /// constructor's treatment of the two overflow rays: `init(+inf, +inf)`
    /// and `Interval.init(floatMax, +inf)` are the same ray, and this says
    /// so. `contains` reads the same fields, so a ray contains its own
    /// finite frontier and nothing on the far side of it.
    pub fn eql(self: Interval, other: Interval) bool {
        return self.lo == other.lo and self.hi == other.hi;
    }

    /// Certain inequality, the complement of eql.
    pub fn ne(self: Interval, other: Interval) bool {
        return !self.eql(other);
    }

    /// Certain strict order: true only when every point of self is below
    /// every point of other. Overlapping intervals return false, because
    /// the relation is then merely possible. A false result means "not
    /// proven", not "disproven": the ranges are enclosures, and a wider
    /// enclosure would settle more of them.
    pub fn lt(self: Interval, other: Interval) bool {
        return self.hi < other.lo;
    }

    /// Certain weak order: true only when every point of self is at or
    /// below every point of other, so touching at a shared endpoint
    /// counts. Overlapping intervals return false, since the relation is
    /// then merely possible.
    pub fn le(self: Interval, other: Interval) bool {
        return self.hi <= other.lo;
    }

    /// Certain strict order the other way: true only when every point of
    /// self is above every point of other. Overlapping intervals return
    /// false, because the relation is then merely possible.
    pub fn gt(self: Interval, other: Interval) bool {
        return self.lo > other.hi;
    }

    /// Certain weak order the other way: true only when every point of
    /// self is at or above every point of other. Overlapping intervals
    /// return false, since the relation is then merely possible.
    pub fn ge(self: Interval, other: Interval) bool {
        return self.lo >= other.hi;
    }
};
