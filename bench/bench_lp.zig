//! Fourier-Motzkin benchmark for the interval solver.
//!
//! Where the scalar benchmarks ask how expensive one enclosure is, this file
//! asks how expensive a whole linear system is. Those are not the same
//! question: a `System` allocates, it grows its row store geometrically, and
//! elimination pairs every lower row against every upper row, so the cost is
//! quadratic in the row count and a single number per operation says very
//! little on its own. Every elimination benchmark here therefore reports the
//! row count before and after alongside the time, because the row count is
//! what decides whether the time matters.
//!
//! Two properties of the solver drive the whole design of this file.
//!
//! A coefficient interval is universal and a right-hand side is existential.
//! A coefficient that merely reaches zero still bounds its variable, read off
//! the endpoint farthest from zero, and a coefficient that straddles zero
//! joins BOTH buckets in `eliminate` and is read from both sides in `bounds`.
//! Point coefficients alone would measure a cheaper and much rarer solver
//! than the one that exists, so the generated systems mix point, straddling,
//! zero-touching and structurally absent coefficients throughout.
//!
//! The second is that the row count is a design choice, not a constant.
//! Eliminating a variable emits exactly `num_lower * num_upper` rows, so
//! which variable goes first decides whether a system stays at four rows or
//! reaches tens of thousands. `eliminateAll` is only cheap because Tupper's
//! heuristic picks the cheapest variable each round, and the number worth
//! having is the one where the same system is also solved the other way
//! round, to see what that heuristic is actually worth.

const std = @import("std");
const interval = @import("interval");
const timing = @import("timing.zig");

const Interval = interval.Interval;
const System = interval.lp.System;

/// Structural zero: the row does not mention this variable. Kept exactly
/// `[0, 0]` on purpose, because a widening artefact around zero is a
/// different statement and the solver treats it as one.
const zero = Interval.init(0.0, 0.0);

/// The allocator the benchmark bodies use. A body is a plain function of
/// `(ctx, i)` with nowhere to put an allocator, so the runner's is published
/// here for the duration of `run`. The file is single threaded.
var gpa: std.mem.Allocator = undefined;

// -- input generation ----------------------------------------------------

/// Deterministic bit mixer. Inputs have to differ from iteration to iteration
/// or the measurement is of one cached case, but they must cost nothing to
/// produce: float arithmetic in here would land inside the timed region and
/// be charged to the solver.
fn mix(x0: u32) u32 {
    var x = x0;
    x ^= x >> 16;
    x *%= 0x7feb352d;
    x ^= x >> 15;
    x *%= 0x846ca68b;
    x ^= x >> 16;
    return x;
}

fn rowHash(seed: u32, r: usize) u32 {
    return mix(seed ^ (@as(u32, @intCast(r)) *% 0x9e3779b9));
}

fn colHash(h: u32, j: usize) u32 {
    return mix(h ^ (@as(u32, @intCast(j)) *% 0x85ebca6b));
}

/// One coefficient of the general-purpose system.
///
/// The mixture is deliberate. Point-positive and point-negative coefficients
/// are the cheap case that drops out of the pairing; a straddle is paired
/// from both sides, so it costs twice and duplicates the constraint; a
/// zero-touching coefficient is the case `bounds` has a whole arm for; and a
/// structural zero is a variable the row simply does not mention. A system
/// built from any one of those alone measures a different solver.
fn mixed(seed: u32, r: usize, j: usize) Interval {
    const h = colHash(rowHash(seed, r), j);
    // About a quarter absent, as in a real constraint matrix.
    if (h % 4 == 0) return zero;
    const mag = 0.5 + @as(f64, @floatFromInt((h >> 5) % 32)) / 32.0;
    return switch ((h >> 2) % 8) {
        0, 1, 2 => Interval.init(mag, mag),
        3, 4 => Interval.init(-mag, -mag),
        5 => Interval.init(-mag, mag),
        6 => Interval.init(-mag, 0.0),
        else => Interval.init(0.0, mag),
    };
}

/// Right-hand sides, kept positive throughout. `x = 0` then satisfies every
/// row, so the system is satisfiable by construction and the solver never
/// short-circuits on a contradiction, which would make an end-to-end
/// benchmark measure only the contradiction check.
fn mixedRhs(seed: u32, r: usize) Interval {
    const h = rowHash(seed, r);
    const base = 1.0 + @as(f64, @floatFromInt(h % 8)) / 4.0;
    return if (h % 2 == 0) Interval.init(base, base) else Interval.init(base, base + 0.25);
}

/// `rows` rows over `var_count` variables with the mixed distribution above.
fn buildMixed(seed: u32, var_count: usize, rows: usize) !System {
    var sys = System.init(gpa, var_count);
    errdefer sys.deinit();
    const scratch = try gpa.alloc(Interval, var_count);
    defer gpa.free(scratch);
    for (0..rows) |r| {
        for (0..var_count) |j| scratch[j] = mixed(seed, r, j);
        try sys.add(scratch, .le, mixedRhs(seed, r));
    }
    return sys;
}

/// Coefficient for the straddle sweep. Every one of these crosses or reaches
/// zero, so `eliminate` pairs each of these rows from BOTH sides and the
/// final read in `bounds` takes both arms of the straddle branch. This is
/// the most expensive per-row shape available and the regression baseline
/// for that path.
fn straddling(seed: u32, r: usize, j: usize) Interval {
    const h = colHash(rowHash(seed, r), j);
    const mag = 0.5 + @as(f64, @floatFromInt((h >> 5) % 32)) / 32.0;
    return switch ((h >> 2) % 4) {
        0 => Interval.init(-mag, mag),
        1 => Interval.init(-mag, 0.0),
        2 => Interval.init(0.0, mag),
        else => Interval.init(-mag / 2.0, mag),
    };
}

fn buildStraddling(seed: u32, var_count: usize, rows: usize) !System {
    var sys = System.init(gpa, var_count);
    errdefer sys.deinit();
    const scratch = try gpa.alloc(Interval, var_count);
    defer gpa.free(scratch);
    for (0..rows) |r| {
        for (0..var_count) |j| scratch[j] = straddling(seed, r, j);
        // Positive, so `x = 0` satisfies the system.
        try sys.add(scratch, .le, Interval.init(2.0, 2.5));
    }
    return sys;
}

/// The system that puts Tupper's ordering under test.
///
/// The last variable appears only in the first `pairs` rows, and always with a
/// negative coefficient, so its cost `num_lower * num_upper` is zero and the
/// heuristic takes it first. That elimination is free and drops `pairs` rows,
/// which removes a large share of every other variable's pairing cost before
/// the heuristic commits to anything expensive. A naive ascending index walk
/// does the exact opposite: it takes the most expensive variable while all of
/// those rows are still in play.
///
/// Coefficient signs come from the mixer rather than from a pattern. A
/// symmetric pattern makes every derived coefficient cancel to a structural
/// zero, which silently caps the row count and hides the very blowup this
/// benchmark exists to show.
fn buildHeuristic(var_count: usize, pairs: usize) !System {
    var sys = System.init(gpa, var_count);
    errdefer sys.deinit();
    const cheap = var_count - 1;
    const scratch = try gpa.alloc(Interval, var_count);
    defer gpa.free(scratch);
    for (0..2 * pairs) |r| {
        const h = rowHash(0, r);
        for (0..var_count) |j| {
            scratch[j] = if (j == cheap)
                (if (r < pairs) Interval.init(-1.0, -1.0) else zero)
            else if (colHash(h, j) % 2 == 0)
                Interval.init(1.0, 1.0)
            else
                Interval.init(-1.0, -1.0);
        }
        // Positive, so `x = 0` satisfies the system and the run measures
        // elimination rather than contradiction detection.
        try sys.add(scratch, .le, Interval.init(1.0, 1.5));
    }
    return sys;
}

/// Eliminating in ascending index order: what a solver without the heuristic
/// does. Present so the benchmark can measure what the ordering buys instead
/// of asserting that it buys something.
fn eliminateNaive(sys: *System) !void {
    for (0..sys.varCount()) |k| {
        if (!sys.alive[k]) continue;
        try sys.eliminate(k);
    }
}

/// The one place a benchmark body can fail. The systems here are small and
/// well formed, so an error means the benchmark itself is wrong; panicking
/// beats dropping the measurement and reporting a number for work that never
/// ran.
fn trap(comptime what: []const u8, err: anyerror) noreturn {
    std.debug.print("bench_lp: {s} failed: {s}\n", .{ what, @errorName(err) });
    std.process.exit(1);
}

// -- benchmark bodies ----------------------------------------------------

fn add8x4(ctx: *timing.Ctx, i: usize) void {
    var sys = buildMixed(@intCast(i), 4, 8) catch |e| trap("add 8x4", e);
    defer sys.deinit();
    ctx.keep(@floatFromInt(sys.count()));
}

fn add64x8(ctx: *timing.Ctx, i: usize) void {
    var sys = buildMixed(@intCast(i), 8, 64) catch |e| trap("add 64x8", e);
    defer sys.deinit();
    ctx.keep(@floatFromInt(sys.count()));
}

/// Control for the `eliminate` benchmark below: the same system, built but
/// not eliminated. Measured separately so the elimination row can be read as
/// a difference rather than as a sum.
fn build6x4(ctx: *timing.Ctx, i: usize) void {
    var sys = buildMixed(@intCast(i), 4, 6) catch |e| trap("build 6x4", e);
    defer sys.deinit();
    ctx.keep(@floatFromInt(sys.count()));
}

fn eliminateOne(ctx: *timing.Ctx, i: usize) void {
    var sys = buildMixed(@intCast(i), 4, 6) catch |e| trap("eliminate 6x4", e);
    defer sys.deinit();
    const before = sys.count();
    sys.eliminate(0) catch |e| trap("eliminate 6x4", e);
    ctx.keep(@floatFromInt(before + sys.count()));
}

fn orderOnly(ctx: *timing.Ctx, i: usize) void {
    var sys = buildMixed(@intCast(i), 4, 6) catch |e| trap("eliminationOrder 6x4", e);
    defer sys.deinit();
    const order = sys.eliminationOrder() catch |e| trap("eliminationOrder 6x4", e);
    defer gpa.free(order);
    ctx.keep(@as(f64, @floatFromInt(order.len)) + @as(f64, @floatFromInt(order[0])));
}

fn inOrderOfChoice(ctx: *timing.Ctx, i: usize) void {
    var sys = buildMixed(@intCast(i), 4, 6) catch |e| trap("eliminateInOrder 6x4", e);
    defer sys.deinit();
    const sat = sys.eliminateInOrderOfChoice() catch |e| trap("eliminateInOrder 6x4", e);
    ctx.keep(@as(f64, @floatFromInt(sys.count())) + @as(f64, if (sat) 1.0 else 0.0));
}

fn boundsOne(ctx: *timing.Ctx, i: usize) void {
    var sys = buildMixed(@intCast(i), 4, 6) catch |e| trap("bounds 6x4", e);
    defer sys.deinit();
    const b = sys.bounds(0) catch |e| trap("bounds 6x4", e);
    ctx.keep(if (b) |v| v.lo + v.hi else -1.0);
}

fn boxAll(ctx: *timing.Ctx, i: usize) void {
    var sys = buildMixed(@intCast(i), 4, 6) catch |e| trap("box 6x4", e);
    defer sys.deinit();
    const b = (sys.box() catch |e| trap("box 6x4", e)) orelse {
        ctx.keep(-1.0);
        return;
    };
    defer gpa.free(b);
    var acc: f64 = 0;
    for (b) |v| acc += v.lo + v.hi;
    ctx.keep(acc);
}

fn boundsStraddle(ctx: *timing.Ctx, i: usize) void {
    var sys = buildStraddling(@intCast(i), 5, 10) catch |e| trap("bounds straddle 10x5", e);
    defer sys.deinit();
    const b = sys.bounds(2) catch |e| trap("bounds straddle 10x5", e);
    ctx.keep(if (b) |v| v.lo + v.hi else -1.0);
}

fn boxStraddle(ctx: *timing.Ctx, i: usize) void {
    var sys = buildStraddling(@intCast(i), 5, 10) catch |e| trap("box straddle 10x5", e);
    defer sys.deinit();
    const b = (sys.box() catch |e| trap("box straddle 10x5", e)) orelse {
        ctx.keep(-1.0);
        return;
    };
    defer gpa.free(b);
    var acc: f64 = 0;
    for (b) |v| acc += v.lo + v.hi;
    ctx.keep(acc);
}

/// End-to-end, chosen order, on the system built to make the choice matter.
fn eliminateAllHeuristic(ctx: *timing.Ctx, i: usize) void {
    _ = i;
    var sys = buildHeuristic(heuristic.vars, heuristic.pairs) catch |e| trap("eliminateAll chosen", e);
    defer sys.deinit();
    const before = sys.count();
    var sat = true;
    sys.eliminateAll(&sat) catch |e| trap("eliminateAll chosen", e);
    ctx.keep(@as(f64, @floatFromInt(before + sys.count())) + @as(f64, if (sat) 1.0 else 0.0));
}

/// The same system and the same seed with the other elimination order. The
/// two rows are directly comparable: the order is the only difference.
fn eliminateAllNaive(ctx: *timing.Ctx, i: usize) void {
    _ = i;
    var sys = buildHeuristic(heuristic.vars, heuristic.pairs) catch |e| trap("eliminateAll ascending", e);
    defer sys.deinit();
    const before = sys.count();
    eliminateNaive(&sys) catch |e| trap("eliminateAll ascending", e);
    ctx.keep(@floatFromInt(before + sys.count()));
}

/// End-to-end on a general mixed system, to see what the ordering costs on
/// input that is not built to flatter it.
fn eliminateAllMixed(ctx: *timing.Ctx, i: usize) void {
    var sys = buildMixed(@intCast(i), 6, 24) catch |e| trap("eliminateAll mixed 24x6", e);
    defer sys.deinit();
    const before = sys.count();
    var sat = true;
    sys.eliminateAll(&sat) catch |e| trap("eliminateAll mixed 24x6", e);
    ctx.keep(@as(f64, @floatFromInt(before + sys.count())) + @as(f64, if (sat) 1.0 else 0.0));
}

// -- geometry ------------------------------------------------------------

/// Shape of the system the ordering benchmarks run on. Sized so the naive
/// order terminates in a measurable time and a row count rather than in an
/// allocation failure.
const heuristic = .{ .vars = 4, .pairs = 4 };

fn printOrder(label: []const u8, order: []const usize, before: usize, after: usize) void {
    std.debug.print("    {s: <22} {d:>7} -> {d:>8} rows   order:", .{ label, before, after });
    for (order, 0..) |k, n| {
        std.debug.print(" {s}{d}", .{ if (n == 0) "" else " ", k });
    }
    std.debug.print("\n", .{});
}

/// Row counts, which no timing figure can be read without. Two systems
/// solved in the same nanoseconds are only equivalent if they also produced
/// the same number of rows, so every elimination figure is reported here
/// first.
///
/// A `System` owns heap buffers and its clone is private, so each variant
/// here builds its own copy from the same deterministic recipe rather than
/// copying the struct. Copying it would alias the buffers and free them
/// twice.
fn reportGeometry() !void {
    {
        var sys = try buildMixed(1, 4, 6);
        defer sys.deinit();
        const before = sys.count();
        try sys.eliminate(0);
        printOrder("mixed 6x4, eliminate k=0", &.{0}, before, sys.count());
    }
    {
        const before = 2 * heuristic.pairs;
        const n = heuristic.vars;

        var probe = try buildHeuristic(n, heuristic.pairs);
        defer probe.deinit();
        const order = try probe.eliminationOrder();
        defer gpa.free(order);

        var chosen = try buildHeuristic(n, heuristic.pairs);
        defer chosen.deinit();
        var sat = true;
        try chosen.eliminateAll(&sat);
        printOrder("heuristic, chosen order", order, before, chosen.count());

        var ascending: [16]usize = undefined;
        for (0..n) |k| ascending[k] = k;
        var naive = try buildHeuristic(n, heuristic.pairs);
        defer naive.deinit();
        try eliminateNaive(&naive);
        printOrder("heuristic, ascending order", ascending[0..n], before, naive.count());
        std.debug.print("    (reported solvable: {s})\n", .{if (sat) "yes" else "no"});
    }
    {
        var sys = try buildMixed(1, 6, 24);
        defer sys.deinit();
        const before = sys.count();
        const order = try sys.eliminationOrder();
        defer gpa.free(order);
        var sat = true;
        try sys.eliminateAll(&sat);
        printOrder("mixed 24x6, chosen order", order, before, sys.count());
    }
    {
        var sys = try buildStraddling(1, 5, 10);
        defer sys.deinit();
        const b = try sys.bounds(2);
        const boxed = try sys.box();
        defer if (boxed) |slice| gpa.free(slice);
        // A straddling system is the case where the answer is a wide
        // enclosure rather than nothing at all, so the geometry report says
        // what the projection actually came back with. A null here would mean
        // the straddle arms read as unbounded, which is the regression this
        // sweep exists to catch.
        std.debug.print("    straddling 10x5: {d} rows, bounds(2) = ", .{sys.count()});
        if (b) |v| {
            std.debug.print("[{d:.4}, {d:.4}]", .{ v.lo, v.hi });
        } else {
            std.debug.print("unbounded", .{});
        }
        std.debug.print(", box = {s}\n", .{
            if (boxed) |_| "all variables bounded" else "unbounded",
        });
    }
}

/// Measures everything and appends to a shared report. The runner owns the
/// report and prints it, so several benchmark files can feed one table.
pub fn run(allocator: std.mem.Allocator, runner: *timing.Runner) !void {
    gpa = allocator;
    try reportGeometry();

    try timing.measure(runner, "add 8 rows x 4 vars", 20_000, add8x4);
    try timing.measure(runner, "add 64 rows x 8 vars", 2_000, add64x8);

    // Build time is reported on its own so the elimination row below can be
    // read as a difference.
    try timing.measure(runner, "build 6 rows x 4 vars (control)", 20_000, build6x4);
    try timing.measure(runner, "eliminate k=0, 6 rows x 4 vars", 20_000, eliminateOne);

    try timing.measure(runner, "eliminationOrder 6x4", 10_000, orderOnly);
    try timing.measure(runner, "eliminateInOrderOfChoice 6x4", 10_000, inOrderOfChoice);

    try timing.measure(runner, "bounds k=0, 6x4", 5_000, boundsOne);
    try timing.measure(runner, "box 6x4", 2_000, boxAll);
    try timing.measure(runner, "bounds k=2, straddling 10x5", 1_000, boundsStraddle);
    try timing.measure(runner, "box, straddling 10x5", 200, boxStraddle);

    try timing.measure(runner, "eliminateAll chosen, mixed 24x6", 200, eliminateAllMixed);
    try timing.measure(runner, "eliminateAll chosen, heuristic 4v", 2_000, eliminateAllHeuristic);
    try timing.measure(runner, "eliminateAll ascending, heuristic 4v", 20, eliminateAllNaive);
}

/// Standalone entry point, so this file can be built and run on its own
/// without waiting for the shared driver to pick it up.
pub fn main() !void {
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg.deinit();
    var runner = try timing.Runner.init(dbg.allocator());
    defer runner.deinit();
    try run(dbg.allocator(), &runner);
    runner.report.print();
}
