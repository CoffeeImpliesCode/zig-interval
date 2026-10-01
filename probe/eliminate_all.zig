const std = @import("std");
const interval = @import("interval");
const Interval = interval.Interval;
const lp = interval.lp;

// A COMPILE-FAILURE PROBE. This file must NOT compile. See
// `probe/row_coeffs.zig` for how to run one and why it lives outside
// `tests/**`.
//
// The expected result is `error: no field or member function named
// 'eliminateAll' in 'lp.System'` at the call below.
//
// There were three elimination drivers and this one was an artefact: it took
// an out-parameter because a parameter named `count` shadowed the `count`
// method, which Zig rejects. A6 renamed that method `rowCount`, so nothing
// stood in the way of the driver that returns its answer, and `eliminateAll`
// was a wrapper around it with one extra guard - an ALREADY unsatisfiable
// system answers false without touching a row - which is now the first line
// of `eliminateInOrderOfChoice` itself.
//
// The permanent check is that `tests/lp_test.zig` exercises both shapes: the
// sweep returning false on a system that goes unsat DURING it, and on one
// that was ALREADY unsat before it was called. The second is the one this
// wrapper existed for.
test "a8 probe: the removed elimination driver must not compile" {
    var sys = try lp.System.init(std.testing.allocator, 1);
    defer sys.deinit();
    try sys.add(&[_]Interval{Interval.init(1.0, 1.0)}, .le, Interval.init(1.0, 1.0));

    var satisfiable = true;
    try sys.eliminateAll(&satisfiable); // MUST NOT COMPILE
}
