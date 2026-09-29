const std = @import("std");

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
};
