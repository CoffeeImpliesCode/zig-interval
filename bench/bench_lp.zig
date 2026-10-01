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
//! joins BOTH buckets in `System.partition` and is read from both sides in
//! `bounds`. Point coefficients alone would measure a cheaper and much rarer
//! solver than the one that exists, so the generated systems mix point,
//! straddling, zero-touching and structurally absent coefficients
//! throughout.
//!
//! The second is that the row count is a design choice, not a constant.
//! Eliminating a variable emits exactly `num_lower * num_upper` rows, so
//! which variable goes first decides whether a system stays at four rows or
//! reaches tens of thousands. The greedy sweep is only cheap because Tupper's
//! heuristic picks the cheapest variable each round, and the number worth
//! having is the one where the same system is also solved the other way
//! round, to see what that heuristic is actually worth.
//!
//! ## The row budget, and why it exists
//!
//! `row_budget` is 20,000 rows, and every elimination this file drives is
//! checked against it BEFORE it runs, by asking the solver's own bucketing
//! rule what that round would produce - `System.rowsAfterEliminating`, which
//! reads the same `System.partition` `eliminate` reads. That prediction is
//! exact for one call, because it is the solver's bucket lengths and not a
//! second reading of its rule, and a trip is an exit status rather than a
//! machine-level incident. It allocates nothing and builds no derived row.
//! It has to be one: with these generators the row count grows by roughly the
//! row count every round, two `bench-lp` processes on this host reached
//! 169 GB and 160 GB of resident memory, and a search of 78 configurations
//! at three or more variables found not one that completed under this
//! budget.
//!
//! Where this file drives the elimination itself - `eliminateOne`, and every
//! round of `eliminateNaive` - the check is on the round about to happen. The
//! sweeps that live inside `System` (`eliminationOrder`,
//! `eliminateInOrderOfChoice`, `bounds`, `box`) have no
//! per-step hook from out here, so they are checked once on their FIRST
//! round. A first-round refusal is definitive, because no later round can
//! have fewer rows than the one before it; a first-round PASS is not, and
//! the sizes below are what actually keep those measurements inside the
//! budget. That is why every size here was chosen by measurement over
//! thousands of seeds rather than by asking what the guard says. See
//! `requireGreedyFirst` for a measured case where the first round fits and
//! the sweep does not.
//!
//! WHICH variable that first round is comes second, and it is a different
//! problem from which ROUND. Three of those sweeps pick their own variable
//! by a cost model that lives inside `System` and cannot be read from out
//! here, so naming one candidate and checking it is a gate that assumes an
//! answer it does not have. This file checks every live variable instead
//! and refuses on the worst of them, which is a claim about no particular
//! choice at all: whatever the solver picks is one of the ones that
//! passed. `costliest` records both the measurement that forced the
//! change - the solver's ranking and this file's disagree about which
//! variable is cheapest on 242 seeds in 4,096 at `mixed` 2 vars x 14 rows -
//! and what the over-checking costs, which at the sizes below is under one
//! percent of the budget.
//!
//! 20,000 rows is a machine-safety limit and NOT a modelling choice. It is
//! not a claim that twenty thousand rows is an interesting amount of work,
//! and no measurement below sits near it for its own sake: the sizes are set
//! by what the sweep needs, and the budget is only the ceiling that keeps a
//! mistake cheap.
//!
//! ## The sizes, and the peaks they reach
//!
//! Every peak below is measured, not asserted: the largest row count reached
//! anywhere in a full sweep, maximised over 4,096 seeds of the generator.
//!
//! | System | Sweep | Peak rows |
//! | --- | --- | --- |
//! | `mixed`, 4 vars, 6 rows | one elimination, k=0 | 36 |
//! | `mixed`, 2 vars, 14 rows | greedy, `eliminateAll` | 7,994 |
//! | `mixed`, 2 vars, 14 rows | `bounds(k)`, k=0 | 17,034 |
//! | `mixed`, 2 vars, 14 rows | `bounds(k)`, k=1 | 11,997 |
//! | `straddling`, 2 vars, 11 rows | `bounds(k)`, either k | 14,641 |
//! | heuristic, 4 vars, 2 pairs | chosen order | 4 |
//! | heuristic, 4 vars, 2 pairs | ascending order | 1,448 |
//!
//! ## Why these sizes and not larger ones
//!
//! Because every larger size was measured and did not fit. The old values are
//! recorded here so the next reader can see they were tried; restoring them
//! restores a hang.
//!
//! `mixed` 24 rows x 6 vars predicted 20,076 rows on its second round and
//! 351,661,485 on its third. `straddling` 10 rows x 5 vars predicted 7,756
//! and then 56,340,286. Neither terminates in bounded memory.
//!
//! `mixed` needs two variables rather than four because the SWEEP is what
//! grows, not the variable count. At 4 vars and 6 rows the greedy order
//! already peaks at 9,802 rows and crosses the budget on 28 seeds in 64,
//! while `bounds(0)` crosses on 55 seeds in 64 with a 196,927,221
//! prediction. At 2 vars and 16 rows the greedy sweep peaks at 11,767, but
//! `bounds(0)` peaks at 19,601, which is 98 % of the budget and leaves
//! nothing for the seed after the last one checked. Fourteen rows is the
//! largest size at which every `mixed` sweep in this file - greedy or
//! bounding, either `k` - stays clear of the ceiling with room to spare.
//!
//! `straddling` at 11 rows is exact rather than sampled. Every coefficient
//! straddles, so every row joins both buckets, the first round emits
//! `11 * 11 = 121` rows and the second `121 * 121 = 14,641`, which is
//! `rows^4`. Twelve rows predicts 20,736 and does not fit: it measured
//! 19,884 at best and crossed the budget on 25 seeds in 256. Eleven rows at
//! two variables is 14,641 rows and still about a millisecond a call, which
//! is what makes the two straddling rows the slowest in the table below.
//!
//! Two variables is the largest straddling system that fits: at 3 vars and 4
//! rows the second round already crosses on 63 seeds in 64. The straddle
//! path is what these rows exist to exercise, and two variables exercise it
//! in full, because every row is paired from both sides and every bound is
//! read from both arms of the straddle branch.
//!
//! The heuristic system drops from 4 pairs to 2 because the ASCENDING order
//! is what that row exists to show and it is the one that grows. Two pairs
//! peak at 1,448 rows; three pairs cross the budget on every seed with a
//! 3,991,524 prediction, and four pairs cross it on the fourth round. The
//! chosen order still costs four rows on the same system, which is the whole
//! point of the comparison.

const std = @import("std");
const interval = @import("interval");
const timing = @import("timing.zig");

const Interval = interval.Interval;
const System = interval.lp.System;

/// Structural zero: the row does not mention this variable. Kept exactly
/// `[0, 0]` on purpose, because a widening artefact around zero is a
/// different statement and the solver treats it as one.
const zero = Interval.init(0.0, 0.0);

/// The machine-safety limit on a single elimination, in rows.
///
/// This bounds what a mistake in this file can cost, and nothing else. It is
/// NOT a modelling choice and it is not a claim that twenty thousand rows is
/// an interesting amount of work: no measurement below comes near it, and
/// the sizes are set by what the sweep needs. Its whole job is that a row
/// count nobody predicted should end the run as an exit status, on the first
/// elimination that would cross it, rather than as hundreds of gigabytes of
/// resident memory an hour later.
const row_budget: usize = 20_000;

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
fn buildMixed(gpa: std.mem.Allocator, seed: u32, var_count: usize, rows: usize) !System {
    var sys = try System.init(gpa, var_count);
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

fn buildStraddling(gpa: std.mem.Allocator, seed: u32, var_count: usize, rows: usize) !System {
    var sys = try System.init(gpa, var_count);
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
fn buildHeuristic(gpa: std.mem.Allocator, var_count: usize, pairs: usize) !System {
    var sys = try System.init(gpa, var_count);
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
///
/// This is the one full sweep this file drives itself, so every round goes
/// through the gate individually. The ascending order is the dangerous one -
/// it takes the most expensive variable while all of its rows are still in
/// play - which is exactly why it is checked per round and not once up front.
fn eliminateNaive(comptime what: []const u8, io: std.Io, sys: *System) !void {
    for (0..sys.varCount()) |k| {
        if (!sys.alive[k]) continue;
        requireRowBudget(what, io, sys.*, k);
        try sys.eliminate(k);
    }
}

/// The one place a benchmark body can fail. The systems here are small and
/// well formed, so an error means the benchmark itself is wrong; naming it
/// and leaving through a non-zero exit beats dropping the measurement and
/// reporting a number for work that never ran.
///
/// The wording and the exit status are `timing.fail`'s, so a benchmark in
/// this project fails one way: a plain line on stderr, then out.
fn trap(comptime what: []const u8, io: std.Io, err: anyerror) noreturn {
    timing.fail("bench_lp: " ++ what, io, err);
}

/// The single gate every elimination in this file passes through.
///
/// On a trip it names the measurement, the variable, the system shape, the
/// prediction and the budget, then leaves through `trap` so the failure is an
/// exit status. It does not return a flag and let a body carry on, because a
/// body that silently skipped the elimination would report a time for work
/// that never ran, which is the one outcome a benchmark must not have.
///
/// THE PREDICTION IS THE SOLVER'S, NOT A COPY OF IT. `System.partition`
/// splits the rows exactly as `eliminate` splits them, and what a round
/// writes is the length of those three lists plus one row per lower/upper
/// pair. This gate used to count the buckets itself, from its own three
/// float comparisons per row, and that was a defect in its own right: a
/// gate that reimplements the rule it gates can agree with itself while
/// disagreeing with the solver, and the disagreement it would hide is a row
/// count nobody predicted.
///
/// It asks `System.rowsAfterEliminating`, which reads that same rule and
/// counts rather than storing, because this runs inside the timed region of
/// every measured elimination and a gate that allocated three lists a call
/// would be measuring its own allocator. `reportGeometry` below calls
/// `System.partition` itself, so the entry point that returns the lists is
/// exercised end to end as well.
///
/// WHICH VARIABLE it is asked about is the caller's decision, and that is a
/// separate question from which count it reads. A trip therefore names the
/// variable the gate chose to check, which for `requireGreedyFirst` is the
/// most expensive live variable rather than the one the sweep will pick -
/// the most informative of the candidates, and never a name this file
/// invented from a rule of its own.
fn requireRowBudget(comptime what: []const u8, io: std.Io, sys: System, k: usize) void {
    const predicted = sys.rowsAfterEliminating(k) catch |e| trap(what, io, e);
    if (predicted <= row_budget) return;
    tripReport(what, io, sys, k, predicted);
}

/// The line a trip prints, and the end of the run.
///
/// It is a function of its own so that the gate above, which runs inside the
/// timed region of every measured elimination, carries no report buffer on
/// its stack for a line it will almost certainly never print.
fn tripReport(
    comptime what: []const u8,
    io: std.Io,
    sys: System,
    k: usize,
    predicted: usize,
) noreturn {
    var out = timing.Out.init(io);
    out.print(
        "bench_lp: {s}: eliminating x_{d} of a {d}-variable, {d}-row system " ++
            "predicts {d} rows, over the {d}-row budget\n",
        .{ what, k, sys.varCount(), sys.rowCount(), predicted, row_budget },
    ) catch |e| trap(what, io, e);
    trap(what, io, error.RowBudgetExceeded);
}

/// The live variable whose elimination would cost the MOST rows, or null
/// when nothing is alive.
///
/// THE MAXIMUM, NOT THE MINIMUM, and that choice is the whole gate. The
/// sweep picks its own variable and does not pick it the way this file used
/// to guess. `System.chooseNext` ranks live variables by PAIRS,
/// `lower * upper`; the `firstChosen` this replaces ranked them by ROWS,
/// `carried + lower * upper`. Those two answer the same question only when
/// every candidate carries the same number of rows through untouched, and
/// they do not: on `mixed` 2 vars x 14 rows, the size this file gates, they
/// name DIFFERENT variables on 242 seeds in 4,096. A gate that predicted a
/// choice made by a different cost model was checking a round the sweep
/// would not run, and on those seeds it was checking a round nobody had
/// predicted.
///
/// That never blew up, and it is recorded here rather than hidden. Over
/// 1,024 seeds at every shape swept - `mixed` from 2 to 4 variables and 30
/// to 800 rows, `straddling` from 2 to 4 variables and 15 to 400 rows - the
/// variable `chooseNext` actually picks was never over budget on a seed
/// where the variable this function used to return was not. The exposure
/// was LATENT, on these two generators, at these sizes. A gate that is
/// sound only for the sizes and the generators somebody remembered to
/// sweep is not a gate, and the next generator is under no obligation to
/// be as well behaved as the last one.
///
/// Taking the maximum removes the dependence instead of narrowing it.
/// Whatever the sweep chooses is a live variable, every live variable is
/// measured here, and no disagreement between two cost models - or between
/// this one and a `chooseNext` rewritten to rank by something else - can
/// turn into a pass. The price is refusing a run whose ACTUAL first round
/// would have fitted, which is the right way round: the asymmetry is why
/// the gate exists, a resize costs one constant, and a false pass costs
/// hundreds of gigabytes of a shared host.
///
/// At the sizes in this file the price is nothing. The same maximum peaks
/// at 145 rows against the 20,000-row budget on `mixed` 2 vars x 14 rows,
/// 121 on `straddling` 2 vars x 11 and 4 on the heuristic system, over
/// 4,096 seeds - under one percent of the budget in every case, and two
/// orders of magnitude below the peaks in the table at the top of this
/// file.
///
/// One tally per live variable, the same passes the function it replaces
/// made, and `requireRowBudget` reads the winner once more to report a
/// trip. Nothing is allocated and no derived row is built.
fn costliest(sys: System) !?usize {
    var worst: ?usize = null;
    var worst_rows: usize = 0;
    for (0..sys.varCount()) |k| {
        if (!sys.alive[k]) continue;
        const rows = try sys.rowsAfterEliminating(k);
        // Strictly greater, so a tie goes to the lowest index and the
        // variable a trip names is a function of the system alone.
        if (worst == null or rows > worst_rows) {
            worst = k;
            worst_rows = rows;
        }
    }
    return worst;
}

/// Guards a sweep whose per-step elimination lives inside `System`, so there
/// is no per-step hook to put a guard in.
///
/// `System.eliminationOrder` and `System.eliminateInOrderOfChoice` both
/// choose their own variable and loop internally, so the sweep can only be
/// checked up front. What is checked is the FIRST
/// elimination, and a refusal there is definitive: if the very first round
/// already predicts more than the budget, no later round can be cheaper,
/// because each round's input contains every row the previous round
/// produced.
///
/// WHICH first round is checked is the part that used to be wrong. This
/// used to check the cheapest round and trust `firstChosen` to name the one
/// the solver would run, and the two are chosen by different cost models;
/// `costliest` measures all of them and this hands over the worst, so the
/// variable the sweep actually eliminates is one of the ones that passed.
/// A PASS is therefore no longer a prediction about a variable nobody out
/// here can see. It is still not a claim about the SECOND round: measured
/// on `mixed` 2 vars x 200 rows, the first round predicts 11,626 rows,
/// fits with room to spare, and the sweep then reaches 62,374,015. So for
/// these three measurements the guard is a cheap necessary condition on the
/// first round, and the SIZE is what actually keeps the run inside the
/// budget - which is why the sizes in this file were chosen by measurement
/// over thousands of seeds rather than by asking what this function says.
/// The one sweep this file drives itself, `eliminateNaive`, is guarded on
/// every round and does not have this gap.
fn requireGreedyFirst(comptime what: []const u8, io: std.Io, sys: System) void {
    const worst = costliest(sys) catch |e| trap(what, io, e) orelse return;
    requireRowBudget(what, io, sys, worst);
}

/// The first variable `System.bounds(k)` eliminates: the lowest live index
/// other than `k`. `System.bounds` clones and sweeps internally, so this is
/// the only elimination of the call a caller can predict.
fn firstSweptVar(sys: System, k: usize) ?usize {
    for (0..sys.varCount()) |j| {
        if (j == k) continue;
        if (!sys.alive[j]) continue;
        return j;
    }
    return null;
}

/// Only the first round of the first projection can be predicted from out
/// here, and that is what this checks; the guard cannot see the rounds after
/// it, because the rows that decide them do not exist yet. A refusal is
/// definitive and a pass is not, so the measurements below are sized so the
/// WHOLE sweep stays under the budget on every seed they run - a stronger
/// condition than this first round alone, stated at each body. A first-round
/// check still earns its place: it is what fires if the generator or the
/// size is ever changed back to something that explodes immediately.
///
/// Unlike `requireGreedyFirst` this gate does not have to guess WHICH round
/// runs, so it does not over-check to cover the guess. `System.bounds` does
/// not choose a variable at all: it walks the live indices in ascending
/// order and skips `k`, so the first elimination of the call is exactly
/// `firstSweptVar` and the count checked below IS that round. Measuring
/// the worst live variable instead would be pure conservatism here, buying
/// no soundness against a cost model that does not exist.
fn requireProjectionFirst(comptime what: []const u8, io: std.Io, sys: System, k: usize) void {
    requireRowBudget(what, io, sys, firstSweptVar(sys, k) orelse k);
}

// -- benchmark bodies ----------------------------------------------------

fn add8x4(ctx: *timing.Ctx, i: usize) void {
    var sys = buildMixed(ctx.gpa, @intCast(i), 4, 8) catch |e| trap("add 8x4", ctx.io, e);
    defer sys.deinit();
    ctx.keep(@floatFromInt(sys.rowCount()));
}

fn add64x8(ctx: *timing.Ctx, i: usize) void {
    var sys = buildMixed(ctx.gpa, @intCast(i), 8, 64) catch |e| trap("add 64x8", ctx.io, e);
    defer sys.deinit();
    ctx.keep(@floatFromInt(sys.rowCount()));
}

/// Control for the `eliminate` benchmark below: the same system, built but
/// not eliminated. Measured separately so the elimination row can be read as
/// a difference rather than as a sum.
fn build6x4(ctx: *timing.Ctx, i: usize) void {
    var sys = buildMixed(ctx.gpa, @intCast(i), 4, 6) catch |e| trap("build 6x4", ctx.io, e);
    defer sys.deinit();
    ctx.keep(@floatFromInt(sys.rowCount()));
}

/// The one elimination this file drives directly, so the guard is exact:
/// the prediction below IS the row count the call produces, and the geometry
/// report shows the two side by side to prove it. 4 vars x 6 rows peaks at
/// 36 rows across 4,096 seeds, far under the budget, and the size is
/// unchanged from before the guard existed.
fn eliminateOne(ctx: *timing.Ctx, i: usize) void {
    const what = "eliminate k=0, 6x4";
    var sys = buildMixed(ctx.gpa, @intCast(i), 4, 6) catch |e| trap(what, ctx.io, e);
    defer sys.deinit();
    requireRowBudget(what, ctx.io, sys, 0);
    const before = sys.rowCount();
    sys.eliminate(0) catch |e| trap(what, ctx.io, e);
    ctx.keep(@floatFromInt(before + sys.rowCount()));
}

/// The ordering decision on its own, with no answer read back.
///
/// `System.eliminationOrder` picks the variable and runs the whole sweep
/// internally, so there is no per-step hook and the guard runs on the FIRST
/// elimination only; the size is what keeps the rest of the sweep in budget.
/// `mixed` 2 vars x 14 rows peaks at 7,994 rows greedy. The old 4 vars x 6
/// rows is not usable: at that shape the sweep crosses the budget on 28
/// seeds in 64.
fn orderOnly(ctx: *timing.Ctx, i: usize) void {
    const what = "eliminationOrder";
    var sys = buildMixed(ctx.gpa, @intCast(i), mixed_sweep.vars, mixed_sweep.rows) catch |e|
        trap(what, ctx.io, e);
    defer sys.deinit();
    requireGreedyFirst(what, ctx.io, sys);
    const order = sys.eliminationOrder() catch |e| trap(what, ctx.io, e);
    defer ctx.gpa.free(order);
    ctx.keep(@as(f64, @floatFromInt(order.len)) + @as(f64, @floatFromInt(order[0])));
}

/// The same ordering decision, taken for its side effects rather than
/// reported. Guarded and sized exactly as `orderOnly` is, because it runs the
/// same sweep on the same system.
fn inOrderOfChoice(ctx: *timing.Ctx, i: usize) void {
    const what = "eliminateInOrderOfChoice";
    var sys = buildMixed(ctx.gpa, @intCast(i), mixed_sweep.vars, mixed_sweep.rows) catch |e|
        trap(what, ctx.io, e);
    defer sys.deinit();
    requireGreedyFirst(what, ctx.io, sys);
    const sat = sys.eliminateInOrderOfChoice() catch |e| trap(what, ctx.io, e);
    ctx.keep(@as(f64, @floatFromInt(sys.rowCount())) + @as(f64, if (sat) 1.0 else 0.0));
}

/// One projection, on the mixed generator.
///
/// `System.bounds` clones the system and eliminates every other variable
/// inside the library, so no per-step guard is possible and only the first
/// round is predicted here. The SIZE is what keeps the whole sweep under the
/// budget: `mixed` 2 vars x 14 rows peaks at 17,034 rows on `k=0` and 11,997
/// on `k=1` over 4,096 seeds. The old 4 vars x 6 rows reached 223,269 rows
/// and crossed the budget on 55 seeds in 64 with a 196,927,221 prediction.
fn boundsOne(ctx: *timing.Ctx, i: usize) void {
    const what = "bounds k=0";
    var sys = buildMixed(ctx.gpa, @intCast(i), mixed_sweep.vars, mixed_sweep.rows) catch |e|
        trap(what, ctx.io, e);
    defer sys.deinit();
    requireProjectionFirst(what, ctx.io, sys, 0);
    const b = sys.bounds(0) catch |e| trap(what, ctx.io, e);
    ctx.keep(if (b) |v| v.lo + v.hi else -1.0);
}

/// Every variable projected, on the mixed generator.
///
/// `System.box` is `bounds` once per variable, so its peak is the worst of
/// them and its guard is the first round of the first projection. The size is
/// the one `boundsOne` uses, and the peak it reaches is the same 17,034 rows
/// because `k=0` is the more expensive of the two.
fn boxAll(ctx: *timing.Ctx, i: usize) void {
    const what = "box, mixed";
    var sys = buildMixed(ctx.gpa, @intCast(i), mixed_sweep.vars, mixed_sweep.rows) catch |e|
        trap(what, ctx.io, e);
    defer sys.deinit();
    requireProjectionFirst(what, ctx.io, sys, 0);
    const b = (sys.box() catch |e| trap(what, ctx.io, e)) orelse {
        ctx.keep(-1.0);
        return;
    };
    defer ctx.gpa.free(b);
    var acc: f64 = 0;
    for (b) |v| acc += v.lo + v.hi;
    ctx.keep(acc);
}

/// One projection on the straddling generator, which is the expensive path:
/// every coefficient is paired from both sides, and the final read takes both
/// arms of the straddle branch in `bounds`.
///
/// The old 10 rows x 5 vars predicted 56,340,286 rows on its second round and
/// never terminated. `straddling` 2 vars x 11 rows is exact: every row joins
/// both buckets, so the rounds are 121 and then 14,641 rows, the same for
/// every seed and for either `k`. Two variables is not a smaller version of
/// the same measurement: every row still straddles, so the straddle path is
/// exercised in full. The elimination is inside `System`, so only the first
/// round is predicted and the size carries the rest of the guarantee.
fn boundsStraddle(ctx: *timing.Ctx, i: usize) void {
    const what = "bounds k=1, straddling";
    var sys = buildStraddling(ctx.gpa, @intCast(i), straddle_sweep.vars, straddle_sweep.rows) catch |e|
        trap(what, ctx.io, e);
    defer sys.deinit();
    requireProjectionFirst(what, ctx.io, sys, 1);
    const b = sys.bounds(1) catch |e| trap(what, ctx.io, e);
    ctx.keep(if (b) |v| v.lo + v.hi else -1.0);
}

/// Every variable projected on the straddling generator. Same size and same
/// reasoning as `boundsStraddle`; `System.box` projects each variable in
/// turn and both projections peak at the same 14,641 rows here.
fn boxStraddle(ctx: *timing.Ctx, i: usize) void {
    const what = "box, straddling";
    var sys = buildStraddling(ctx.gpa, @intCast(i), straddle_sweep.vars, straddle_sweep.rows) catch |e|
        trap(what, ctx.io, e);
    defer sys.deinit();
    requireProjectionFirst(what, ctx.io, sys, 0);
    const b = (sys.box() catch |e| trap(what, ctx.io, e)) orelse {
        ctx.keep(-1.0);
        return;
    };
    defer ctx.gpa.free(b);
    var acc: f64 = 0;
    for (b) |v| acc += v.lo + v.hi;
    ctx.keep(acc);
}

/// End-to-end, chosen order, on the system built to make the choice matter.
///
/// `System.eliminateInOrderOfChoice` runs the whole sweep internally, so the
/// guard covers the first elimination. At 4 vars x 2 pairs the chosen order predicts one
/// row for its first round and peaks at 4 rows over the whole sweep.
fn eliminateAllHeuristic(ctx: *timing.Ctx, i: usize) void {
    _ = i;
    const what = "eliminateAll chosen, heuristic";
    var sys = buildHeuristic(ctx.gpa, heuristic.vars, heuristic.pairs) catch |e|
        trap(what, ctx.io, e);
    defer sys.deinit();
    requireGreedyFirst(what, ctx.io, sys);
    const before = sys.rowCount();
    const sat = sys.eliminateInOrderOfChoice() catch |e| trap(what, ctx.io, e);
    ctx.keep(@as(f64, @floatFromInt(before + sys.rowCount())) + @as(f64, if (sat) 1.0 else 0.0));
}

/// The same system and the same seed with the other elimination order. The
/// two rows are directly comparable: the order is the only difference.
///
/// This is the row that constrains the heuristic system's size, because
/// ascending is the order that grows. `eliminateNaive` guards every round of
/// this sweep individually, so a size change here is caught on the round that
/// would cross the budget and not merely on the first one.
fn eliminateAllNaive(ctx: *timing.Ctx, i: usize) void {
    _ = i;
    const what = "eliminateAll ascending, heuristic";
    var sys = buildHeuristic(ctx.gpa, heuristic.vars, heuristic.pairs) catch |e|
        trap(what, ctx.io, e);
    defer sys.deinit();
    const before = sys.rowCount();
    eliminateNaive(what, ctx.io, &sys) catch |e| trap(what, ctx.io, e);
    ctx.keep(@floatFromInt(before + sys.rowCount()));
}

/// End-to-end on a general mixed system, to see what the ordering costs on
/// input that is not built to flatter it.
///
/// The old 24 rows x 6 vars predicted 20,076 rows on its second round and
/// 351,661,485 on its third, so it never finished. At 14 rows x 2 vars the
/// greedy sweep peaks at 7,994 rows; it runs inside `System`, so
/// the guard covers the first elimination and the size covers the rest.
fn eliminateAllMixed(ctx: *timing.Ctx, i: usize) void {
    const what = "eliminateAll chosen, mixed";
    var sys = buildMixed(ctx.gpa, @intCast(i), mixed_sweep.vars, mixed_sweep.rows) catch |e|
        trap(what, ctx.io, e);
    defer sys.deinit();
    requireGreedyFirst(what, ctx.io, sys);
    const before = sys.rowCount();
    const sat = sys.eliminateInOrderOfChoice() catch |e| trap(what, ctx.io, e);
    ctx.keep(@as(f64, @floatFromInt(before + sys.rowCount())) + @as(f64, if (sat) 1.0 else 0.0));
}

// -- geometry ------------------------------------------------------------

/// Shape of the system the ordering benchmarks run on. Sized so the naive
/// order terminates in a measurable time and a row count rather than in an
/// allocation failure - and, now, rather than over the row budget. It was 4
/// pairs; that reaches 223,269 rows on the fourth ascending round and
/// crosses the budget on the way, so it is 2 pairs, which peaks at 1,448.
const heuristic = .{ .vars = 4, .pairs = 2 };

/// Size of every `mixed` system a sweep runs on: 2 variables, 14 rows. The
/// labels in this file write that as "14 rows x 2 vars", rows first, and the
/// peaks are 7,994 rows greedy, 17,034 through `bounds(0)` and 11,997
/// through `bounds(1)`. 14 is the largest row count at which all three stay
/// clear of the budget; see the file header for the measurements that
/// stopped it.
const mixed_sweep = .{ .vars = 2, .rows = 14 };

/// Size of every `straddling` system a projection runs on. 2 variables, 11
/// rows, which is exact rather than sampled: the two rounds are 121 and
/// 14,641 rows for every seed and for either `k`.
const straddle_sweep = .{ .vars = 2, .rows = 11 };

/// One line of the geometry report: what the sweep started from, what it
/// ended at, and what its first round was predicted to cost beside what that
/// round actually produced.
///
/// The prediction is printed next to the achieved count because that is how
/// a cheaper solver shows up. A change to the solver that made elimination
/// cheaper would make both numbers smaller and would be visible here as a
/// smaller figure; without the prediction, the only symptom would be a run
/// that takes longer to blow up.
fn printOrder(
    out: *timing.Out,
    label: []const u8,
    order: []const usize,
    before: usize,
    predicted: usize,
    achieved: usize,
    after: usize,
) !void {
    try out.print(
        "    {s: <22} {d:>7} -> {d:>8} rows   round 1 predicted {d:>6}, achieved {d:>6}   order:",
        .{ label, before, after, predicted, achieved },
    );
    for (order, 0..) |k, n| {
        try out.print(" {s}{d}", .{ if (n == 0) "" else " ", k });
    }
    try out.print("\n", .{});
}

/// Row counts, which no timing figure can be read without. Two systems
/// solved in the same nanoseconds are only equivalent if they also produced
/// the same number of rows, so every elimination figure is reported here
/// first, next to what `System.partition` said it would produce.
///
/// A `System` owns heap buffers and its clone is private, so each variant
/// here builds its own copy from the same deterministic recipe rather than
/// copying the struct. Copying it would alias the buffers and free them
/// twice. That is also why the first round of a sweep is run on a system of
/// its own: the prediction needs a system before the round and the achieved
/// count needs one after it, and they cannot be the same object.
///
/// Every branch here goes through the gate before it eliminates, for the same
/// reason every benchmark body does: `reportGeometry` runs before any
/// measurement, so a size mistake here would take the process down before
/// the table exists.
fn reportGeometry(gpa: std.mem.Allocator, io: std.Io) !void {
    var out = timing.Out.init(io);
    {
        var sys = try buildMixed(gpa, 1, 4, 6);
        defer sys.deinit();
        requireRowBudget("mixed 6x4, eliminate k=0", io, sys, 0);
        const before = sys.rowCount();
        // The partition borrows the rows and `eliminate` invalidates them, so
        // only the count is read back; the three lists are its own.
        const parts = try sys.partition(0);
        defer parts.deinit();
        const predicted = parts.rowsProduced();
        try sys.eliminate(0);
        try printOrder(
            &out,
            "mixed 6x4, eliminate k=0",
            &.{0},
            before,
            predicted,
            sys.rowCount(),
            sys.rowCount(),
        );
    }
    {
        const before = 2 * heuristic.pairs;
        const n = heuristic.vars;

        var probe = try buildHeuristic(gpa, n, heuristic.pairs);
        defer probe.deinit();
        requireGreedyFirst("heuristic, chosen order", io, probe);
        const order = try probe.eliminationOrder();
        defer gpa.free(order);
        const first = order[0];

        var round1 = try buildHeuristic(gpa, n, heuristic.pairs);
        defer round1.deinit();
        requireRowBudget("heuristic, chosen order", io, round1, first);
        const chosen_parts = try round1.partition(first);
        defer chosen_parts.deinit();
        const chosen_predicted = chosen_parts.rowsProduced();
        try round1.eliminate(first);

        var chosen = try buildHeuristic(gpa, n, heuristic.pairs);
        defer chosen.deinit();
        requireGreedyFirst("heuristic, chosen order", io, chosen);
        const sat = try chosen.eliminateInOrderOfChoice();
        try printOrder(
            &out,
            "heuristic, chosen order",
            order,
            before,
            chosen_predicted,
            round1.rowCount(),
            chosen.rowCount(),
        );

        var ascending: [16]usize = undefined;
        for (0..n) |k| ascending[k] = k;
        var ascending_round1 = try buildHeuristic(gpa, n, heuristic.pairs);
        defer ascending_round1.deinit();
        requireRowBudget("heuristic, ascending order", io, ascending_round1, 0);
        const ascending_parts = try ascending_round1.partition(0);
        defer ascending_parts.deinit();
        const ascending_predicted = ascending_parts.rowsProduced();
        try ascending_round1.eliminate(0);

        var naive = try buildHeuristic(gpa, n, heuristic.pairs);
        defer naive.deinit();
        try eliminateNaive("heuristic, ascending order", io, &naive);
        try printOrder(
            &out,
            "heuristic, ascending order",
            ascending[0..n],
            before,
            ascending_predicted,
            ascending_round1.rowCount(),
            naive.rowCount(),
        );
        try out.print("    (reported solvable: {s})\n", .{if (sat) "yes" else "no"});
    }
    {
        const before = mixed_sweep.rows;

        var probe = try buildMixed(gpa, 1, mixed_sweep.vars, mixed_sweep.rows);
        defer probe.deinit();
        requireGreedyFirst("mixed, chosen order", io, probe);
        const order = try probe.eliminationOrder();
        defer gpa.free(order);
        const first = order[0];

        var round1 = try buildMixed(gpa, 1, mixed_sweep.vars, mixed_sweep.rows);
        defer round1.deinit();
        requireRowBudget("mixed, chosen order", io, round1, first);
        const parts = try round1.partition(first);
        defer parts.deinit();
        const predicted = parts.rowsProduced();
        try round1.eliminate(first);

        var chosen = try buildMixed(gpa, 1, mixed_sweep.vars, mixed_sweep.rows);
        defer chosen.deinit();
        requireGreedyFirst("mixed, chosen order", io, chosen);
        const sat = try chosen.eliminateInOrderOfChoice();
        try printOrder(
            &out,
            "mixed 14x2, chosen order",
            order,
            before,
            predicted,
            round1.rowCount(),
            chosen.rowCount(),
        );
        try out.print("    (reported solvable: {s})\n", .{if (sat) "yes" else "no"});
    }
    {
        var sys = try buildStraddling(gpa, 1, straddle_sweep.vars, straddle_sweep.rows);
        defer sys.deinit();
        requireProjectionFirst("straddling 11x2, bounds(1)", io, sys, 1);
        // A system with no live variable besides `k` eliminates nothing, so
        // there is no first round to predict and none to report. The
        // straddling generator always builds two live variables, so a null
        // here is a change of shape and not a run that may carry on.
        const first = firstSweptVar(sys, 1) orelse return error.NoVariableToSweep;
        const parts = try sys.partition(first);
        defer parts.deinit();
        const predicted = parts.rowsProduced();

        var round1 = try buildStraddling(gpa, 1, straddle_sweep.vars, straddle_sweep.rows);
        defer round1.deinit();
        requireRowBudget("straddling 11x2, bounds(1)", io, round1, first);
        try round1.eliminate(first);

        const b = try sys.bounds(1);
        const boxed = try sys.box();
        defer if (boxed) |slice| gpa.free(slice);
        // A straddling system is the case where the answer is a wide
        // enclosure rather than nothing at all, so the geometry report says
        // what the projection actually came back with. A null here would mean
        // the straddle arms read as unbounded, which is the regression this
        // sweep exists to catch.
        try out.print(
            "    straddling 11x2: {d} rows, first round of bounds(1) predicted {d}, achieved {d}; bounds(1) = ",
            .{ sys.rowCount(), predicted, round1.rowCount() },
        );
        if (b) |v| {
            try out.print("[{d:.4}, {d:.4}]", .{ v.lo, v.hi });
        } else {
            try out.print("unbounded", .{});
        }
        try out.print(", box = {s}\n", .{
            if (boxed) |_| "all variables bounded" else "unbounded",
        });
    }
}

/// Measures everything and appends to a shared report. The runner owns the
/// report and prints it, so several benchmark files can feed one table, and
/// its allocator is the heap every body below builds from.
///
/// The wall time is printed here because the practical question about this
/// file is not whether a row is fast but whether the whole run finishes: a
/// benchmark that takes an hour is a benchmark nobody runs a second time.
pub fn run(runner: *timing.Runner) !void {
    const started = std.Io.Clock.real.now(runner.io);
    try reportGeometry(runner.gpa, runner.io);

    try timing.measure("add 8 rows x 4 vars", add8x4, runner, 20_000);
    try timing.measure("add 64 rows x 8 vars", add64x8, runner, 2_000);

    // Build time is reported on its own so the elimination row below can be
    // read as a difference.
    try timing.measure("build 6 rows x 4 vars (control)", build6x4, runner, 20_000);
    try timing.measure("eliminate k=0, 6 rows x 4 vars", eliminateOne, runner, 20_000);

    // Iteration counts. The four slow rows used to run 5,000 to 10,000 times
    // each, because each one paid a final round of 223,269 rows on top of
    // every sweep. At the sizes above a whole sweep costs a few hundred
    // microseconds instead, so their counts come down and the run finishes in
    // tens of seconds rather than the minutes it cost before. They are not a
    // tuning knob: the harness reports the MINIMUM over 7 repetitions, so what
    // matters is only that there are enough calls to reach a steady state,
    // and 500 calls at ~300 us is well past that.
    //
    // `eliminateAll ascending` moves the other way, 20 to 100: the heuristic
    // system is half the size it was, the ascending sweep costs ~500 us rather
    // than a millisecond, and 20 calls was too few for a stable minimum.
    try timing.measure("eliminationOrder, mixed 14x2", orderOnly, runner, 500);
    try timing.measure("eliminateInOrderOfChoice, mixed 14x2", inOrderOfChoice, runner, 500);

    try timing.measure("bounds k=0, mixed 14x2", boundsOne, runner, 500);
    try timing.measure("box, mixed 14x2", boxAll, runner, 200);
    try timing.measure("bounds k=1, straddling 11x2", boundsStraddle, runner, 100);
    try timing.measure("box, straddling 11x2", boxStraddle, runner, 50);

    try timing.measure("eliminateAll chosen, mixed 14x2", eliminateAllMixed, runner, 200);
    try timing.measure("eliminateAll chosen, heuristic 4v", eliminateAllHeuristic, runner, 2_000);
    try timing.measure("eliminateAll ascending, heuristic 4v", eliminateAllNaive, runner, 100);

    const elapsed: i96 = std.Io.Clock.real.now(runner.io).nanoseconds - started.nanoseconds;
    var out = timing.Out.init(runner.io);
    try out.print("\nbench_lp: {d:.3} s total, row budget {d} rows\n", .{
        @as(f64, @floatFromInt(elapsed)) / 1e9,
        row_budget,
    });
}

/// Standalone entry point, so this file can be built and run on its own
/// without waiting for the shared driver to pick it up.
pub fn main() !void {
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg.deinit();
    var runner = try timing.Runner.init(dbg.allocator());
    defer runner.deinit();
    try run(&runner);
    try runner.report.print();
}
