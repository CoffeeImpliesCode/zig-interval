const std = @import("std");
const rounding = @import("rounding.zig");

/// The smallest positive subnormal f64, bit pattern 1. A product or a
/// quotient whose true magnitude falls below it underflows to a signed zero,
/// and one step of this size is the smallest step that puts a bound back
/// outside a value the machine has lost.
const min_subnormal: f64 = @bitCast(@as(u64, 1));

/// Top bit of the f64 layout, set on every negative value.
const sign_mask: u64 = 1 << 63;

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

/// One corner of a product or a quotient: the f64 one pair of endpoints
/// produced, and whether that computation is already exact.
///
/// The flag carries what a pair of f64 cannot. Multiplying or dividing two
/// non-zero operands can produce a true value too small to represent, and
/// f64 answers that with a zero of the sign the operands give. The zero has
/// lost both the magnitude and the sign the reduction discarded, and a min
/// or a max over the corners cannot recover either, because it compares
/// numbers and +0.0 equals -0.0. So the operands' verdict travels beside
/// the value, where the reduction can still reach it.
const Corner = struct {
    value: f64,
    /// True when neither operand is exactly zero, so the value is a small
    /// nonzero number that f64 may have rounded down to a signed zero.
    undersized: bool,

    /// One corner, from its two operands and the value computed for them.
    fn of(a: f64, b: f64, value: f64) Corner {
        return .{ .value = value, .undersized = a != 0.0 and b != 0.0 };
    }
};

/// True when some corner attaining `v` is undersized, so `v` is a signed
/// zero standing in for a value f64 could not hold rather than for a zero.
/// The test is `==`, which holds across the pair of signed zeros, so the
/// answer does not depend on which of the two patterns the reduction
/// happened to keep.
fn undersizedAt(corners: *const [4]Corner, v: f64) bool {
    for (corners.*) |c| {
        if (c.undersized and c.value == v) return true;
    }
    return false;
}

/// Lower bound of a corner reduction, widened outward.
///
/// When the extremum is a zero and no exactly-zero operand explains it, the
/// true value is a small number on the far side of zero, and a bound that
/// stops at the zero excludes it. So the bound steps out to the smallest
/// subnormal. Sign multiplication is exact however far the magnitude
/// underflows, which is why the operands can answer for a value no f64
/// holds, and why no direction of the step has to be guessed from the
/// reduced zero: the lower bound always steps down.
///
/// An extremum that really is zero keeps its bound at zero. Nothing is
/// undersized then, the value is attained, and widening it would replace an
/// exact answer with a weaker one.
fn loBound(corners: *const [4]Corner) f64 {
    const v = @min(@min(corners[0].value, corners[1].value), @min(corners[2].value, corners[3].value));
    if (v == 0.0 and undersizedAt(corners, v)) return -min_subnormal;
    return rounding.roundDown(v);
}

/// Upper bound of a corner reduction, widened outward, the mirror of
/// loBound: the step for an undersized zero goes up.
fn hiBound(corners: *const [4]Corner) f64 {
    const v = @max(@max(corners[0].value, corners[1].value), @max(corners[2].value, corners[3].value));
    if (v == 0.0 and undersizedAt(corners, v)) return min_subnormal;
    return rounding.roundUp(v);
}

/// A closed interval [lo, hi] over f64, with invariant lo <= hi.
pub const Interval = struct {
    lo: f64,
    hi: f64,

    /// Build [lo, hi]. Callers must pass lo <= hi; a violation traps in
    /// Debug and ReleaseSafe, and the check is elided in ReleaseFast.
    pub fn init(lo: f64, hi: f64) Interval {
        std.debug.assert(lo <= hi);
        return .{ .lo = lo, .hi = hi };
    }

    /// True when x lies in [lo, hi], endpoints inclusive.
    pub fn contains(self: Interval, x: f64) bool {
        return self.lo <= x and x <= self.hi;
    }

    /// Smallest interval covering both self and other.
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
    /// Built through init, so the lo <= hi invariant is checked rather than
    /// assumed. Rounding cannot break it: a correctly rounded addition is
    /// monotone, so a shift of an ordered pair stays ordered however it
    /// rounds. What it can do is produce a NaN, from a NaN delta or from
    /// an infinite endpoint shifted by an infinite delta, and a NaN pair
    /// fails the comparison without being caught by it. That is a scalar
    /// the caller got wrong, and expand and scale already trap on it
    /// rather than hand back an interval that breaks its own invariant.
    pub fn translate(self: Interval, delta: f64) Interval {
        return Interval.init(
            rounding.roundDown(self.lo + delta),
            rounding.roundUp(self.hi + delta),
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
    /// out of add, sub, mul and div rather than widened by a fixed number
    /// of ULP from the outside. A fixed count is a guess at what the chain
    /// accumulated, it is only ever a guess, and it is worst exactly where
    /// the two intermediates sit in different binades, where a step taken
    /// on the small one pays for nothing on the large one.
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
    /// Halving by two is exact everywhere but the subnormal range, so it
    /// goes through div rather than through a hand step, and div is what
    /// carries the repair for the range where it is not: the smallest
    /// subnormal halves to 2^-1075, a tie that rounds away to zero, and a
    /// bound stopping at that zero drops a value the machine only just
    /// failed to hold. No slack added afterwards reinstates it, because by
    /// then the information is gone.
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
    /// the two are ordered only because W is nonnegative and M is.
    /// Nothing local to this return shows that, which makes it the one
    /// place in this file where an assertion still has something to catch.
    pub fn scale(self: Interval, factor: f64) Interval {
        const two = Interval.init(2.0, 2.0);
        const f = Interval.init(@abs(factor), @abs(factor));
        // M from the sum of the endpoints where that sum stays in range,
        // and from their halves where the sum leaves it.
        const sum = Interval.init(self.lo, self.lo).add(Interval.init(self.hi, self.hi));
        const m = if (std.math.isFinite(sum.lo) and std.math.isFinite(sum.hi))
            sum.div(two)
        else
            Interval.init(self.lo, self.lo).div(two).add(Interval.init(self.hi, self.hi).div(two));
        // W from the width itself where the width stays in range, the
        // multiply ahead of the halving so that a subnormal width is
        // lifted back out of the subnormal range by the factor before
        // anything halves it, and from the halved width where the
        // difference itself has left the range.
        const diff = Interval.init(self.hi, self.hi).sub(Interval.init(self.lo, self.lo));
        const w = if (std.math.isFinite(diff.lo) and std.math.isFinite(diff.hi))
            diff.mul(f).div(two)
        else
            Interval.init(self.hi, self.hi).div(two).sub(Interval.init(self.lo, self.lo).div(two)).mul(f);
        return Interval.init(m.sub(w).lo, m.add(w).hi);
    }

    /// Widen both ends by margin when positive, shrink both when negative.
    /// Requires margin >= -(hi - lo) / 2; a more negative margin inverts the
    /// interval and traps in Debug and ReleaseSafe.
    ///
    /// Each end is one correctly rounded operation, so as in add the
    /// outward step per side is the whole of the widening. A zero margin
    /// widens too: lo - 0.0 and hi + 0.0 are exact, and the step is what
    /// makes them bounds.
    pub fn expand(self: Interval, margin: f64) Interval {
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
    pub fn sub(self: Interval, other: Interval) Interval {
        return Interval.init(
            rounding.roundDown(self.lo - other.hi),
            rounding.roundUp(self.hi - other.lo),
        );
    }

    /// Additive inverse. IEEE 754 negation is exact, so no widening
    /// applies, but the endpoints swap: the image of [lo, hi] is
    /// [-hi, -lo], and emitting [-lo, -hi] would invert the interval.
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
        const corners = [4]Corner{
            Corner.of(self.lo, other.lo, cornerProduct(self.lo, other.lo)),
            Corner.of(self.lo, other.hi, cornerProduct(self.lo, other.hi)),
            Corner.of(self.hi, other.lo, cornerProduct(self.hi, other.lo)),
            Corner.of(self.hi, other.hi, cornerProduct(self.hi, other.hi)),
        };
        return Interval.init(loBound(&corners), hiBound(&corners));
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
    pub fn div(self: Interval, other: Interval) Interval {
        if (other.lo <= 0.0 and 0.0 <= other.hi) {
            return Interval.init(-std.math.inf(f64), std.math.inf(f64));
        }
        const corners = [4]Corner{
            Corner.of(self.lo, other.lo, self.lo / other.lo),
            Corner.of(self.lo, other.hi, self.lo / other.hi),
            Corner.of(self.hi, other.lo, self.hi / other.lo),
            Corner.of(self.hi, other.hi, self.hi / other.hi),
        };
        return Interval.init(loBound(&corners), hiBound(&corners));
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
        if (self.lo <= 0.0 and 0.0 <= self.hi) {
            return Interval.init(0.0, rounding.roundUp(max_abs));
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
    /// nonnegative. The lower bound needs no repair at all, and unlike in
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
        const undersized = max_sq == 0.0 and (self.lo != 0.0 or self.hi != 0.0);
        const hi = if (undersized) min_subnormal else rounding.roundUp(max_sq);
        if (self.lo <= 0.0 and 0.0 <= self.hi) {
            return Interval.init(0.0, hi);
        }
        return Interval.init(rounding.roundDown(@min(lo_sq, hi_sq)), hi);
    }

    /// Set equality, a certain comparison: true exactly when both
    /// endpoints match, which is exactly when the two intervals denote
    /// the same set. Certain comparisons never report a relation that is
    /// merely possible, so this needs no overlap case.
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
