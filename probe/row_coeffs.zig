const std = @import("std");
const interval = @import("interval");
const Interval = interval.Interval;
const lp = interval.lp;

// A COMPILE-FAILURE PROBE. This file must NOT compile, and that is the whole
// of what it is for. It lives outside `tests/**` so the house gate's
// `test-paths` glob cannot pick it up, and it is compiled on demand:
//
//   zig test --dep interval -Mroot=probe/row_coeffs.zig \
//            -Minterval=src/root.zig --name test
//
// The expected result is `error: cannot assign to constant` at the write
// below. Before A1 this compiled, and running it changed `bounds(0)` from a
// real interval to `null` while `isUnsat()` still said no: the write had
// edited the solver's own coefficient storage in place, silently, with nothing
// thrown and nothing logged.
//
// The permanent regression check for this is `lp_test.zig`'s assertion that
// `Lin.coeffs` is exactly `[]const Interval`. See docs/next-work-plan.md.
test "a1 probe: writing through a borrowed row must not compile" {
    var sys = lp.System.init(std.testing.allocator, 1);
    defer sys.deinit();
    try sys.add(&[_]Interval{Interval.init(1.0, 1.0)}, .le, Interval.init(1.0, 1.0));

    const row = try sys.at(0);
    row.coeffs[0] = Interval.init(9.0, 9.0); // MUST NOT COMPILE
}
