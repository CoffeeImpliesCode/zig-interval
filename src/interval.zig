const std = @import("std");

/// A closed interval [lo, hi] over f64, with invariant lo <= hi.
pub const Interval = struct {
    lo: f64,
    hi: f64,

    pub fn init(lo: f64, hi: f64) Interval {
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
};
