const std = @import("std");
const Interval = @import("interval").Interval;

/// Raised when the library produces a value it does not promise. Returning it
/// from main makes the process exit non-zero, failing the parent `consumer`
/// step.
pub const CheckError = error{UnexpectedIntervalValue};

/// Number of behavioural checks; the summary line reports this.
const total_checks = 9;

/// Compare a produced interval against the expected one, loudly on mismatch.
fn expectInterval(what: []const u8, got: Interval, want: Interval) CheckError!void {
    if (got.lo != want.lo or got.hi != want.hi) {
        std.debug.print(
            "FAIL {s}: got [{d}, {d}], want [{d}, {d}]\n",
            .{ what, got.lo, got.hi, want.lo, want.hi },
        );
        return CheckError.UnexpectedIntervalValue;
    }
    std.debug.print("ok {s}: [{d}, {d}]\n", .{ what, got.lo, got.hi });
}

/// Compare a produced scalar against the expected one, loudly on mismatch.
fn expectFloat(what: []const u8, got: f64, want: f64) CheckError!void {
    if (got != want) {
        std.debug.print("FAIL {s}: got {d}, want {d}\n", .{ what, got, want });
        return CheckError.UnexpectedIntervalValue;
    }
    std.debug.print("ok {s}: {d}\n", .{ what, got });
}

pub fn main() !void {
    try expectInterval(
        "hull",
        Interval.init(1.0, 3.0).hull(Interval.init(2.0, 5.0)),
        Interval.init(1.0, 5.0),
    );

    try expectInterval(
        "intersect",
        Interval.init(1.0, 3.0).intersect(Interval.init(2.0, 5.0)).?,
        Interval.init(2.0, 3.0),
    );

    const disjoint = Interval.init(0.0, 1.0).intersect(Interval.init(2.0, 3.0));
    if (disjoint != null) {
        std.debug.print(
            "FAIL intersect-disjoint: got [{d}, {d}], want null\n",
            .{ disjoint.?.lo, disjoint.?.hi },
        );
        return CheckError.UnexpectedIntervalValue;
    }
    std.debug.print("ok intersect-disjoint: null\n", .{});

    const spread = [_]Interval{
        Interval.init(4.0, 7.0),
        Interval.init(1.0, 3.0),
        Interval.init(2.0, 9.0),
    };
    try expectInterval(
        "hullOf",
        Interval.hullOf(&spread).?,
        Interval.init(1.0, 9.0),
    );

    const common = [_]Interval{
        Interval.init(1.0, 5.0),
        Interval.init(2.0, 6.0),
        Interval.init(3.0, 4.0),
    };
    try expectInterval(
        "intersectionOf",
        Interval.intersectionOf(&common).?,
        Interval.init(3.0, 4.0),
    );

    try expectFloat("distanceTo", Interval.init(1.0, 3.0).distanceTo(0.0), 1.0);

    try expectInterval(
        "scale",
        Interval.init(1.0, 3.0).scale(2.0),
        Interval.init(0.0, 4.0),
    );

    try expectInterval(
        "expand",
        Interval.init(1.0, 3.0).expand(1.0),
        Interval.init(0.0, 4.0),
    );

    try expectFloat("clamp", Interval.init(1.0, 3.0).clamp(5.0), 3.0);

    std.debug.print("consumer ok: {d} checks\n", .{total_checks});
}
