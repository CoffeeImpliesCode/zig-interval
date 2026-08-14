const std = @import("std");
pub const Interval = struct {
    lo: f64,
    hi: f64,
    pub fn init(lo: f64, hi: f64) Interval { return .{ .lo = lo, .hi = hi }; }
    pub fn contains(self: Interval, x: f64) bool { _ = self; _ = x; return false; }
};
