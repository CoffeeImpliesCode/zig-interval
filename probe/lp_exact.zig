const exact = @import("lp_exact");

// A COMPILE-FAILURE PROBE. This file must NOT compile, and that is the whole
// of what it is for. See `probe/row_coeffs.zig` for how to run one and what
// the house gate's `test-paths` glob would otherwise do with it.
//
//   zig test --dep lp_exact -Mroot=probe/lp_exact.zig \
//            -Mlp_exact=src/lp_exact.zig --name test
//
// The expected result is
//
//     error: root struct of file 'lp_exact' has no member named 'Part'
//
// at the line below, and nothing else.
//
// `Part` is the pairing the SOLVER speaks: a multiplier piece and a row
// borrowed from a `System`, handed out by `System.partition` inside a
// `Partition` that owns three slices and has to be released with an
// allocator. It stayed in `lp.zig` when the exact block moved, and the block
// takes `lp_exact.Side` instead, which carries the three values it reads and
// names nothing the solver owns.
//
// Before the move `combinedColumn` took a `Part`, so the only way to reach
// the cancellation decision was through a `System`: a test of it had to
// allocate one, add rows, and drive an elimination until the four operands
// happened to appear. It is now reachable without any of that, and this
// probe is what keeps the old door shut. A `Part` reaching the block again
// would drag the allocator back into a file whose entire argument is that it
// has none, and this file would stop compiling exactly when that happened.
//
// The other half of the boundary is checked by `tests/lp_exact_test.zig`,
// which exercises the block with no `System` and no allocator anywhere in
// the file. See docs/next-work-plan.md.
test "a10 probe: the exact block must not answer to the solver's pairing type" {
    const part: exact.Part = undefined; // MUST NOT COMPILE
    _ = part;
}
