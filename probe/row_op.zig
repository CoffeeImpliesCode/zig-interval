const std = @import("std");
const interval = @import("interval");
const Interval = interval.Interval;
const lp = interval.lp;

// A COMPILE-FAILURE PROBE. This file must NOT compile. See
// `probe/row_coeffs.zig` for how to run one and what the house gate's
// `test-paths` glob would otherwise do with it.
//
// The expected result is `error: no field named 'op' in struct 'lp.Lin'` at
// the write below.
//
// `Lin.op` was a field that always read back `.le`, because every stored row
// is `<=` by construction and `at` hard-coded it. Writing it was a silent
// no-op on the solver's answers that read back as a lie, which is worse in
// kind than the `coeffs` door next door: that one changed an answer, and this
// one pretended to.
//
// The permanent regression check for this is `lp_test.zig`'s assertion that
// `lp.Lin` publishes no field named `op`. See docs/next-work-plan.md.
test "a1 probe: writing the comparison on a borrowed row must not compile" {
    var sys = lp.System.init(std.testing.allocator, 1);
    defer sys.deinit();
    try sys.add(&[_]Interval{Interval.init(1.0, 1.0)}, .le, Interval.init(1.0, 1.0));

    var row = try sys.at(0);
    row.op = .eq; // MUST NOT COMPILE
}
