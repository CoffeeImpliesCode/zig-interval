//! The one oracle in the tree that is finer than `f64`, and the band it is
//! swept on. `tanh` is the only elementary function the package has a real
//! containment reference for, and the band below is swept on a grid rather
//! than drawn for the reason that same two-ULP defect gives: it is a sliver
//! of arguments a random draw reaches about once in twenty-five thousand
//! runs, so sampling it is a check that passes.
//!
//! The reference itself — the exponential identity with the cancellation
//! near zero already paid for, good to 3.1e-34 relative, which is eighteen
//! orders of magnitude below the grid the defect lives on — lives in
//! `soundness_shared.zig`. That is not a demotion: the per-operation fuzz
//! sweep judges `tanh` against the very same reference on every one of its
//! 8,000 draws, and two copies of an oracle would be two oracles. What is
//! left for this file is the part no other concern reads — the band, its
//! grid, the diagnosis a miss prints, and the two tests that pin them.
const shared = @import("soundness_shared.zig");

const std = shared.std;
const interval = shared.interval;
const Interval = shared.Interval;

const Range = shared.Range;
const expectEnclosure = shared.expectEnclosure;
const ex = shared.ex;
const lowerOk = shared.lowerOk;
const max_detail = shared.max_detail;
const reportErr = shared.reportErr;
const tanhRef = shared.tanhRef;
const upperOk = shared.upperOk;

// ---------------------------------------------------------------------------
// The tanh band the magnitude table cannot reach
// ---------------------------------------------------------------------------

// Why this section exists, in numbers. `std.math.tanh` is 2.14 ULP from
// the truth near 0.23, and the two-ULP widening `interval_ext.zig` used to
// apply does not reach that. The arguments where it misses are a sliver
// rather than a region: measured against seventy-digit arithmetic over
// [-0.5, 0.5], three points in 100,001 on a 1e-5 grid exceed two ULP,
// each of them a single grid point and not a run of neighbours, and 29
// points in 524,288 on a 1.9e-6 grid do. A draw from the magnitude table
// reaches |x| <= 0.5 with probability 5e-4 per case, `.ordinary` alone
// spanning [-1000, 1000], so an 8,000-case sweep expects about four
// arguments inside the band and, at the measured rate within it, about
// one miss in twenty-five thousand runs. Random sampling is not a weak
// form of this check; it is a check that passes.
//
// So the band is swept directly, and on a grid rather than a draw, so that
// what it covers is a property of the test and not of a seed. The counts
// on nested grids of this same construction are 0 misses at 2^13, 1 at
// 2^15, 5 at 2^17 and 11 at 2^18; 2^18 is the coarsest that lands inside
// the sliver several times over, and every argument on it is exactly
// representable because the step is a power of two.

/// The width of the directed band. `tanh` is least steep and its relative
/// error largest below half an unit, the defect is there, and nothing
/// above it has been measured to miss, so this is the band swept.
const tanh_band: f64 = 0.5;

/// Steps across the band, as a power of two. Power of two so that every
/// argument is exactly representable and the grid is fixed rather than
/// the rounding of a computed step size.
const tanh_band_log2: u6 = 18;

/// One containment failure for `tanh` at `x`, with the true value in
/// digits an `f64` cannot hold, and the signed gap in ULPs that says the
/// bound cut inside the true image rather than merely being loose.
fn reportTanhMiss(x: f64, got: Interval, want: Range, shown: *usize) void {
    if (shown.* >= max_detail) return;
    shown.* += 1;
    const gap_lo = @abs((ex(got.lo) - want.lo) * 0x1p52 / @max(@abs(ex(got.lo)), @abs(want.lo)));
    const gap_hi = @abs((ex(got.hi) - want.hi) * 0x1p52 / @max(@abs(ex(got.hi)), @abs(want.hi)));
    reportErr("    FAIL tanh at x = {e}  bits 0x{X:0>16}\n", .{ x, @as(u64, @bitCast(x)) });
    reportErr("      returned lo = {e}  bits 0x{X:0>16}\n", .{ got.lo, @as(u64, @bitCast(got.lo)) });
    reportErr("      returned hi = {e}  bits 0x{X:0>16}\n", .{ got.hi, @as(u64, @bitCast(got.hi)) });
    reportErr("      true        = {e}\n", .{want.lo});
    if (!lowerOk(want.lo, got.lo)) {
        reportErr("      the lower bound is ABOVE the true value and excludes it by {e} ULP\n", .{gap_lo});
    }
    if (!upperOk(want.hi, got.hi)) {
        reportErr("      the upper bound is BELOW the true value and excludes it by {e} ULP\n", .{gap_hi});
    }
    reportErr(
        "      the nearest f64 to that truth is {e}, so an oracle built on f64" ++
            "compares it with itself and reports this sound\n",
        .{@as(f64, @floatCast(want.lo))},
    );
}

test "reproducer 6: tanh at the witness argument, 2.14 ULP out and cut out by the two-ULP bound" {
    // The minimal case, named and pinned rather than left to a sweep. The
    // two-ULP widening returned [0.22735067345628182, 0.22735067345628193]
    // here, and the true value is 0.227350673456281817160566003737, which
    // is BELOW that lower bound by 0.14 ULP: the interval excluded the very
    // answer it was supposed to enclose. Three ULP moves the bound to
    // 0.2273506734562818, which is 0.86 ULP below the truth.
    const x = 0.23139395412799124;
    // The negative argument is the same point by oddness and is here so
    // that a fix which widened only one side would be caught.
    for ([_]f64{ x, -x }) |arg| {
        try expectEnclosure(
            "tanh does not enclose the true value at the two-ULP witness",
            interval.ext.tanh(Interval.init(arg, arg)),
            tanhRef(arg),
            false,
        );
    }
    // The trap, asserted rather than described. The nearest `f64` to the
    // true value IS the lower bound the two-ULP widening returned, and it
    // is strictly ABOVE the truth. An oracle that rounded the truth to
    // `f64` would compare those two numbers, find them equal, and report
    // the defect sound — which is why the reference above is `f128`.
    const truth = tanhRef(x).lo;
    const rounded: f64 = @floatCast(truth);
    try std.testing.expect(rounded == 0.22735067345628182);
    try std.testing.expect(ex(rounded) > truth);
}

test "tanh: every argument of the directed band over |x| <= 0.5 is enclosed" {
    // The sweep. 2^18 equal steps across [-0.5, 0.5], endpoints included,
    // each argument a degenerate box — the shape the defect has.
    //
    // Degenerate boxes are not a sample of the non-degenerate ones; they
    // settle them. `tanh` is rising, so the image of [lo, hi] is the image
    // of its two ends, and `envelope` returns `lower` of the smaller and
    // `upper` of the larger. Containment at both ends therefore implies
    // containment everywhere between, exactly rather than approximately.
    // So this is a complete check of `tanh` over the band, not a sample
    // of it.
    const steps: u64 = @as(u64, 1) << tanh_band_log2;
    const step = 2.0 * tanh_band / @as(f64, @floatFromInt(steps));
    var k: u64 = 0;
    var failures: usize = 0;
    var shown: usize = 0;
    while (k <= steps) : (k += 1) {
        const x = -tanh_band + @as(f64, @floatFromInt(k)) * step;
        const got = interval.ext.tanh(Interval.init(x, x));
        const want = tanhRef(x);
        if (lowerOk(want.lo, got.lo) and upperOk(want.hi, got.hi)) continue;
        failures += 1;
        reportTanhMiss(x, got, want, &shown);
    }
    reportErr("  tanh band |x| <= {d}, 2^{d} steps: {d} checked, {d} FAILED\n", .{
        tanh_band, tanh_band_log2, steps + 1, failures,
    });
    if (failures > shown) {
        reportErr("  tanh band: {d} further failures not printed individually\n", .{failures - shown});
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}
