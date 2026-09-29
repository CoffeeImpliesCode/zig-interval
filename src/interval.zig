const std = @import("std");
const rounding = @import("rounding.zig");

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
    pub fn midpoint(self: Interval) f64 {
        return (self.lo + self.hi) / 2.0;
    }

    /// Clamp x into [lo, hi]. Values below lo map to lo, above hi to hi.
    pub fn clamp(self: Interval, x: f64) f64 {
        return @min(@max(x, self.lo), self.hi);
    }

    /// Shift lo and hi by delta, preserving the width.
    pub fn translate(self: Interval, delta: f64) Interval {
        return .{ .lo = self.lo + delta, .hi = self.hi + delta };
    }

    /// Scale about the midpoint, preserving lo <= hi by using |factor|
    /// for the width.
    pub fn scale(self: Interval, factor: f64) Interval {
        const m = self.midpoint();
        const half = self.width() * @abs(factor) / 2.0;
        return .{ .lo = m - half, .hi = m + half };
    }

    /// Widen both ends by margin when positive, shrink both when negative.
    /// Requires margin >= -(hi - lo) / 2; a more negative margin inverts the
    /// interval and traps in Debug and ReleaseSafe.
    pub fn expand(self: Interval, margin: f64) Interval {
        return Interval.init(self.lo - margin, self.hi + margin);
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
    pub fn add(self: Interval, other: Interval) Interval {
        return Interval.init(
            rounding.prevDown(self.lo + other.lo),
            rounding.nextUp(self.hi + other.hi),
        );
    }

    /// Difference self - other, widened outward. The pairing crosses: the
    /// lower bound of the result takes self.lo against other.hi, because
    /// subtracting the larger element of other is what can push the sum
    /// furthest down. Pairing lo with lo instead would be the bug this
    /// form exists to avoid.
    pub fn sub(self: Interval, other: Interval) Interval {
        return Interval.init(
            rounding.prevDown(self.lo - other.hi),
            rounding.nextUp(self.hi - other.lo),
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
    pub fn mul(self: Interval, other: Interval) Interval {
        const p1 = self.lo * other.lo;
        const p2 = self.lo * other.hi;
        const p3 = self.hi * other.lo;
        const p4 = self.hi * other.hi;
        return Interval.init(
            rounding.prevDown(@min(@min(p1, p2), @min(p3, p4))),
            rounding.nextUp(@max(@max(p1, p2), @max(p3, p4))),
        );
    }

    /// Quotient, widened outward, over the same four-endpoint argument as
    /// mul. A divisor that contains zero gives the unbounded interval
    /// [-inf, inf] rather than null: null would assert the image is empty,
    /// which is a different and much stronger claim, while 0/0 is
    /// reachable and the divisor can approach zero from either side. The
    /// unbounded answer is therefore both sound and the only one the
    /// caller can act on. It over-approximates in the sub-cases where the
    /// true quotient range is one-sided or a single point, which is the
    /// price of not inspecting the dividend.
    pub fn div(self: Interval, other: Interval) Interval {
        if (other.lo <= 0.0 and 0.0 <= other.hi) {
            return Interval.init(-std.math.inf(f64), std.math.inf(f64));
        }
        const q1 = self.lo / other.lo;
        const q2 = self.lo / other.hi;
        const q3 = self.hi / other.lo;
        const q4 = self.hi / other.hi;
        return Interval.init(
            rounding.prevDown(@min(@min(q1, q2), @min(q3, q4))),
            rounding.nextUp(@max(@max(q1, q2), @max(q3, q4))),
        );
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
    pub fn abs(self: Interval) Interval {
        const max_abs = @max(@abs(self.lo), @abs(self.hi));
        if (self.lo <= 0.0 and 0.0 <= self.hi) {
            return Interval.init(0.0, rounding.nextUp(max_abs));
        }
        const min_abs = @min(@abs(self.lo), @abs(self.hi));
        return Interval.init(rounding.prevDown(min_abs), rounding.nextUp(max_abs));
    }

    /// Square, widened outward. Squaring is not monotone across zero, so
    /// the branch is load-bearing rather than defensive: on an interval
    /// spanning zero the image is [0, max(lo*lo, hi*hi)], and computing
    /// min(lo*lo, hi*hi) unconditionally would put a lower bound below
    /// the smallest real square, which is zero.
    pub fn sqr(self: Interval) Interval {
        const lo_sq = self.lo * self.lo;
        const hi_sq = self.hi * self.hi;
        const max_sq = @max(lo_sq, hi_sq);
        if (self.lo <= 0.0 and 0.0 <= self.hi) {
            return Interval.init(0.0, rounding.nextUp(max_sq));
        }
        return Interval.init(rounding.prevDown(@min(lo_sq, hi_sq)), rounding.nextUp(max_sq));
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
