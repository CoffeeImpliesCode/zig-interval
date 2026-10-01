//! Benchmarks for the two box representations: `Vec(n)`, whose dimension
//! is fixed at compile time, and `DynVec`, whose dimension is only known at
//! run time and whose components live on the heap.
//!
//! The claim under test is the one `src/vector.zig` makes: `Vec(n)` is
//! monomorphised, stores its components inline, and allocates nothing, so
//! its cost is the cost of the componentwise fold and nothing else. Two
//! things can falsify that, and this file measures both.
//!
//! First, the per-component cost could stop being flat as N grows. A fold
//! over a slice with a comptime-known length should unroll or vectorise;
//! one that LLVM turns into a loop with a runtime trip count would not. So
//! the same operation is measured at N = 2, 3, 4, 8, 16 and 32, and both
//! the per-call and the per-component figure are printed, because a
//! regression that is invisible at N = 3 and obvious at N = 16 disappears
//! into a per-call average.
//!
//! Second, `DynVec` should lose by roughly the cost of the fold plus the
//! cost of an allocator round trip. The value-returning operations
//! allocate on every call, so a loop of `dv = dv.add(other)` pays that per
//! step, while a loop of `dv.iadd(other)` pays it once. The value form is
//! measured for every operation that has one — `add`, `sub`, `mul`, `div`,
//! `hull`, `intersect` and both `mapResult sqrt` cases — and the in-place
//! numbers are reported net of the re-seed copy so the comparison is
//! fold-against-allocator rather than memcpy-against-allocator.
//!
//! That penalty is an allocator round trip and nothing else, so its size
//! is the allocator the caller supplies rather than a property of this
//! library, and quoting one allocator's figure as "the" cost of a
//! `DynVec` is simply wrong. Every value-returning body is therefore
//! measured TWICE, on two environments built side by side for each
//! dimension: one on `smp_allocator`, the general purpose allocator a
//! caller reaches for by default, and one on a `DebugAllocator`. The rows
//! are named `...value.smp` and `...value.dbg` and every table below
//! prints both, because a cross-over quoted against only one of them is a
//! measurement of the allocator.
//!
//! Allocators: the hot path uses `std.heap.smp_allocator`, because a
//! `DebugAllocator` turns an allocation benchmark into a measurement of
//! the `DebugAllocator` — its own bookkeeping, its own leak-detection
//! state — rather than of the library. That claim is checked rather than
//! asserted: the last section times a bare `alloc`/`free` round trip under
//! both allocators at every box size measured here, and prints what share
//! of a value-returning call that round trip accounts for.
//!
//! What the two come to, measured on this machine in ReleaseFast over
//! several runs: the round trip runs at 17 to 29 ns under `smp_allocator`
//! and 5,400 to 10,100 ns under the `DebugAllocator`, a factor of roughly
//! 240 to 500. The figures move by half between runs on a loaded host, so
//! read the last two tables of the output rather than this paragraph for
//! anything load-bearing.
//!
//! The consequence is the whole point of measuring twice, and it is large.
//! Against `Vec(4).add`, `add` measures 0.5 to 1.1x in place, 1.2 to 2.1x
//! value-returning on `smp_allocator`, and 230 to 460x value-returning on
//! the `DebugAllocator`. Every one of those is a true measurement of
//! something, they are not the same claim, and the earlier version of this
//! file printed only the last while calling it the cost of the library.
//!
//! Inputs vary with the iteration index over a table of `case_count` distinct
//! boxes, so no single cached case is measured a hundred thousand times.
//! Every body folds its result into `ctx.keep`; a body whose result
//! nothing reads is dead code the optimiser is entitled to delete, and its
//! timing would be fiction.
//!
//! Build: ReleaseFast. A debug build of an assert-heavy numeric library
//! measures its assertions, not its arithmetic.

const std = @import("std");
const timing = @import("timing.zig");
const interval = @import("interval");

const Interval = interval.Interval;
const Vec = interval.Vec;
const DynVec = interval.DynVec;

/// Distinct input cases cycled through by the iteration index. A power of
/// two, so selecting a case is a mask.
const case_count = 16;
const case_mask = case_count - 1;

/// Dimensions measured for both representations. The four the task calls
/// for (2, 3, 4, 16) plus 8 and 32, because the cross-over question is
/// only answerable if some dimensions bracket it.
const dims = [_]Dim{
    .{ .n = 2, .s = "2" },
    .{ .n = 3, .s = "3" },
    .{ .n = 4, .s = "4" },
    .{ .n = 8, .s = "8" },
    .{ .n = 16, .s = "16" },
    .{ .n = 32, .s = "32" },
};

const Dim = struct { n: usize, s: []const u8 };

/// Iterations for a dimension. Scaled so every measurement does roughly
/// the same total work: a 32-component fold costs about sixteen times a
/// 2-component one, so it gets a sixteenth of the iterations. The floor
/// keeps the largest dimension long enough to out-resolve the clock.
fn itersFor(comptime n: usize) usize {
    return @max(20_000, 400_000 / n);
}

// ---------------------------------------------------------------------------
// Input tables.
//
// Generated at comptime from a small LCG so the numbers are reproducible
// and the compiler can see the whole table as a constant. Four shapes:
//
//   gen  straddles zero, and is the operand for the operations whose
//         result is finite whatever the sign.
//   pos  is strictly positive and never touches zero, so it is safe as a
//         divisor, as the argument of `recip`, and as the argument of
//         `sqrt`.
//   ovl  overlaps `gen`, so `hull` and `intersect` run their full fold
//         rather than taking an early exit on the first component.
//   dis  is disjoint from `gen`, so `intersect` returns null as soon as it
//         looks at component zero.
//
// `div` and `recip` would otherwise measure their zero-straddling fast
// path — `Interval.div` answers [-inf, inf] for a divisor containing zero
// without touching the corner reduction at all — rather than the code a
// caller with a legal divisor actually runs.
// ---------------------------------------------------------------------------

const lcg_state: u64 = 0x2545_F491_4F6C_DD1D;

fn lcgNext(s: *u64) u64 {
    s.* = s.* *% 6364136223846793005 +% 1442695040888963407;
    return s.* >> 33;
}

/// A unit-scale f64 from the LCG, in [0, 1).
fn lcgUnit(s: *u64) f64 {
    return @as(f64, @floatFromInt(lcgNext(s) & 0xFFFF_FFFF)) / 4294967296.0;
}

const Shape = enum { gen, pos, ovl, dis };

fn componentAt(shape: Shape, s: *u64) Interval {
    return switch (shape) {
        .gen => blk: {
            const centre = (lcgUnit(s) - 0.5) * 2000.0;
            const w = 0.25 + lcgUnit(s) * 12.0;
            break :blk Interval.init(centre - w * 0.5, centre + w * 0.5);
        },
        .pos => blk: {
            const lo = 0.5 + lcgUnit(s) * 100.0;
            const w = 0.25 + lcgUnit(s) * 8.0;
            break :blk Interval.init(lo, lo + w);
        },
        // Shifted by less than the width of gen, so the two always share
        // points and the fold never short-circuits.
        .ovl => blk: {
            const centre = (lcgUnit(s) - 0.5) * 2000.0;
            const w = 0.25 + lcgUnit(s) * 12.0;
            const shift = (lcgUnit(s) - 0.5) * 4.0;
            break :blk Interval.init(centre - w * 0.5 + shift, centre + w * 0.5 + shift);
        },
        // Pushed well above the top of gen's range for the same index,
        // which the generator below preserves by construction.
        .dis => blk: {
            const centre = 5000.0 + lcgUnit(s) * 1000.0;
            const w = 1.0 + lcgUnit(s) * 10.0;
            break :blk Interval.init(centre - w * 0.5, centre + w * 0.5);
        },
    };
}

fn makeVecTable(comptime n: usize, comptime shape: Shape) [case_count]Vec(n) {
    // Paying for the LCG loop itself, not for `Interval.init`: the two
    // comparisons in the constructor used to cost enough per row to push
    // this past six figures, and the whole table at the widest dimension
    // now lands between ten and twenty thousand. The default is a
    // thousand, so the line stays.
    @setEvalBranchQuota(100_000);
    var s: u64 = lcg_state;
    var out: [case_count]Vec(n) = undefined;
    for (&out) |*v| {
        var comps: [n]Interval = undefined;
        for (&comps) |*c| c.* = componentAt(shape, &s);
        v.* = Vec(n).fromArray(comps);
    }
    return out;
}

/// Points for `contains` and `distance`. Half inside the corresponding
/// `gen` box and half outside, so the fold does not always exit on the
/// first component.
fn makePointTable(comptime n: usize) [case_count][n]f64 {
    @setEvalBranchQuota(100_000);
    var s: u64 = lcg_state ^ 0x9E37_79B9_7F4A_7C15;
    var out: [case_count][n]f64 = undefined;
    for (&out) |*p| {
        for (p) |*x| {
            const centre = (lcgUnit(&s) - 0.5) * 2000.0;
            // Every third coordinate is pushed outside the box's scale, so
            // roughly a third of the cases fail on an early component and
            // the rest walk the whole width.
            x.* = if (lcgNext(&s) % 3 == 0) centre + 3000.0 else centre;
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// Reporting a vector through the sink.
//
// Both endpoints of every component are summed. Summing only `lo` would let
// a dead-code pass drop the `hi` half of every operation — `Interval.add`
// computes the two bounds independently — and the measurement would be of
// half the work. The fold itself costs 2n f64 additions against an
// operation that costs about 16.3 ns per component, so it is a few percent
// at every dimension measured here, and it does not grow faster than the
// operation it is reporting.
// ---------------------------------------------------------------------------

fn keepVec(comptime n: usize, ctx: *timing.Ctx, v: Vec(n)) void {
    var acc: f64 = 0;
    for (v.comps) |c| acc += c.lo + c.hi;
    ctx.keep(acc);
}

fn keepDyn(ctx: *timing.Ctx, v: DynVec) void {
    var acc: f64 = 0;
    for (v.comps) |c| acc += c.lo + c.hi;
    ctx.keep(acc);
}

// ---------------------------------------------------------------------------
// Vec(n) bodies.
// ---------------------------------------------------------------------------

fn VecBench(comptime n: usize) type {
    const gen = comptime makeVecTable(n, .gen);
    const pos = comptime makeVecTable(n, .pos);
    const ovl = comptime makeVecTable(n, .ovl);
    const dis = comptime makeVecTable(n, .dis);
    const pts = comptime makePointTable(n);

    return struct {
        pub fn add(ctx: *timing.Ctx, i: usize) void {
            keepVec(n, ctx, gen[i & case_mask].add(gen[(i + 1) & case_mask]));
        }

        pub fn sub(ctx: *timing.Ctx, i: usize) void {
            keepVec(n, ctx, gen[i & case_mask].sub(ovl[i & case_mask]));
        }

        pub fn mul(ctx: *timing.Ctx, i: usize) void {
            keepVec(n, ctx, gen[i & case_mask].mul(gen[(i + 1) & case_mask]));
        }

        pub fn div(ctx: *timing.Ctx, i: usize) void {
            keepVec(n, ctx, gen[i & case_mask].div(pos[i & case_mask]));
        }

        pub fn neg(ctx: *timing.Ctx, i: usize) void {
            keepVec(n, ctx, gen[i & case_mask].neg());
        }

        pub fn recip(ctx: *timing.Ctx, i: usize) void {
            keepVec(n, ctx, pos[i & case_mask].recip());
        }

        pub fn abs(ctx: *timing.Ctx, i: usize) void {
            keepVec(n, ctx, gen[i & case_mask].abs());
        }

        pub fn sqr(ctx: *timing.Ctx, i: usize) void {
            keepVec(n, ctx, gen[i & case_mask].sqr());
        }

        pub fn hull(ctx: *timing.Ctx, i: usize) void {
            keepVec(n, ctx, gen[i & case_mask].hull(ovl[i & case_mask]));
        }

        pub fn intersect(ctx: *timing.Ctx, i: usize) void {
            if (gen[i & case_mask].intersect(ovl[i & case_mask])) |r| {
                keepVec(n, ctx, r);
            } else {
                ctx.keep(0);
            }
        }

        /// The early exit: `disjoint` is separated from `gen` on every
        /// component, so the fold stops at the first one.
        pub fn intersectDisjoint(ctx: *timing.Ctx, i: usize) void {
            if (gen[i & case_mask].intersect(dis[i & case_mask])) |r| {
                keepVec(n, ctx, r);
            } else {
                ctx.keep(-1);
            }
        }

        pub fn contains(ctx: *timing.Ctx, i: usize) void {
            ctx.keep(if (gen[i & case_mask].contains(pts[i & case_mask])) 1 else 0);
        }

        pub fn distance(ctx: *timing.Ctx, i: usize) void {
            ctx.keep(gen[i & case_mask].distance(pts[i & case_mask]));
        }

        /// `mapResult` over `Vec(n)`: a stack array, no allocation, and a
        /// domain failure is a null with nothing to free. The `Vec(n)`
        /// instantiation cannot fail, so it returns a plain optional and
        /// there is no error union to report here. Only the `DynVec` arms
        /// below reach an allocator, so those are the bodies that can fail.
        pub fn mapResultSqrt(ctx: *timing.Ctx, i: usize) void {
            if (interval.mapResult(pos[i & case_mask], interval.sqrt)) |r| {
                keepVec(n, ctx, r);
            } else {
                ctx.keep(0);
            }
        }

        pub fn mapResultSqrtOutOfDomain(ctx: *timing.Ctx, i: usize) void {
            // `gen` straddles zero, so `sqrt` fails on it. The fold stops
            // at the first component.
            if (interval.mapResult(gen[i & case_mask], interval.sqrt)) |r| {
                keepVec(n, ctx, r);
            } else {
                ctx.keep(-1);
            }
        }
    };
}

// ---------------------------------------------------------------------------
// DynVec bodies.
//
// The tables are on the heap, built once in `setupEnv`, and reached through
// a file-scope array indexed by allocator and then by dimension. A
// benchmark body is a plain `fn (ctx, i) void` with nowhere to hang a
// context, so the state it needs has to live somewhere the function can
// name.
//
// The in-place bodies re-seed their destination from the table each step.
// Without that the box would be transformed over and over across the
// hundreds of thousands of iterations of a run and drift to infinities and
// then to NaN, and the figure would be the cost of arithmetic on NaN. The
// re-seed is a `memcpy` of n components; the `seed` body measures exactly
// that copy with no operation on top of it, so the in-place figure can be
// read net of it.
// ---------------------------------------------------------------------------

/// Which allocator a `DynVec` environment is built on. The value-returning
/// bodies allocate through `env.gpa` and nothing else in them touches the
/// heap, so the same source line measured under the two allocators differs
/// by exactly the round trip. That difference is the whole measurement, so
/// it is never left to one allocator.
const Alloc = enum { smp, dbg };

const DynEnv = struct {
    gpa: std.mem.Allocator,
    gen: []DynVec,
    pos: []DynVec,
    ovl: []DynVec,
    dis: []DynVec,
    pts: []f64, // case_count * n, row-major
    work: DynVec, // scratch of width n for the in-place bodies
};

/// Indexed by allocator first, then by dimension, so the two runs of every
/// dimension sit side by side and share no state.
var dyn_envs: [2][dims.len]DynEnv = undefined;

fn dimSlot(comptime n: usize) usize {
    inline for (dims, 0..) |d, idx| {
        if (d.n == n) return idx;
    }
    @compileError("no DynVec environment for this dimension");
}

fn envOf(comptime a: Alloc, comptime n: usize) *DynEnv {
    return &dyn_envs[@intFromEnum(a)][dimSlot(n)];
}

fn setupEnv(comptime n: usize, gpa: std.mem.Allocator, env: *DynEnv) !void {
    const gen = comptime makeVecTable(n, .gen);
    const pos = comptime makeVecTable(n, .pos);
    const ovl = comptime makeVecTable(n, .ovl);
    const dis = comptime makeVecTable(n, .dis);
    const pts = comptime makePointTable(n);

    env.gpa = gpa;
    env.gen = try gpa.alloc(DynVec, case_count);
    env.pos = try gpa.alloc(DynVec, case_count);
    env.ovl = try gpa.alloc(DynVec, case_count);
    env.dis = try gpa.alloc(DynVec, case_count);
    env.pts = try gpa.alloc(f64, case_count * n);
    env.work = try DynVec.init(gpa, n, Interval.init(0, 1));
    for (0..case_count) |c| {
        env.gen[c] = try boxFrom(n, gpa, gen[c]);
        env.pos[c] = try boxFrom(n, gpa, pos[c]);
        env.ovl[c] = try boxFrom(n, gpa, ovl[c]);
        env.dis[c] = try boxFrom(n, gpa, dis[c]);
        for (0..n) |k| env.pts[c * n + k] = pts[c][k];
    }
}

fn boxFrom(comptime n: usize, gpa: std.mem.Allocator, comps: Vec(n)) !DynVec {
    const v = try DynVec.init(gpa, n, Interval.init(0, 1));
    @memcpy(v.comps, comps.comps[0..]);
    return v;
}

fn teardownEnv(env: *DynEnv) void {
    for (env.gen) |*v| v.deinit();
    for (env.pos) |*v| v.deinit();
    for (env.ovl) |*v| v.deinit();
    for (env.dis) |*v| v.deinit();
    env.work.deinit();
    env.gpa.free(env.gen);
    env.gpa.free(env.pos);
    env.gpa.free(env.ovl);
    env.gpa.free(env.dis);
    env.gpa.free(env.pts);
}

/// Bodies for one dimension under one allocator. The value-returning
/// bodies allocate through `env.gpa`, so the identical source measured
/// under `.smp` and under `.dbg` differs by precisely the round trip and
/// by nothing else. The in-place and no-allocation bodies never reach the
/// allocator, so they are measured once, from the `.smp` environment, and
/// a second run of them would be the same number twice.
fn DynBench(comptime n: usize, comptime a: Alloc) type {
    const env = envOf(a, n);

    return struct {
        fn point(c: usize) []const f64 {
            return env.pts[c * n ..][0..n];
        }

        /// The name a body here reports when it cannot do its work: the
        /// operation, the width and the allocator, which is the whole of
        /// what a failure in this file is about.
        fn label(comptime op: []const u8) []const u8 {
            return std.fmt.comptimePrint(
                "bench_vec: dyn {s} (n={d}, {s})",
                .{ op, n, @tagName(a) },
            );
        }

        /// The one place a body below can fail. Every environment is built
        /// once in `setupEnv` and lives for the whole run, so an error out
        /// of one of these calls is the machine running out of memory and
        /// not anything the measurement did. It ends the run with a name,
        /// because a time for work that never happened is the one figure a
        /// benchmark must not print.
        fn fatal(comptime op: []const u8, io: std.Io, err: anyerror) noreturn {
            timing.fail(label(op), io, err);
        }

        // -- value-returning: one allocation and one free per call -------
        //
        // Every body below this line is measured twice, once per
        // allocator, because every one of them calls `allocLike` (or
        // `mapResult`, which calls it) before the fold and frees after.

        pub fn addValue(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            var r = env.gen[c].add(env.ovl[c]) catch |e| fatal("add.value", ctx.io, e);
            defer r.deinit();
            keepDyn(ctx, r);
        }

        pub fn subValue(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            var r = env.gen[c].sub(env.ovl[c]) catch |e| fatal("sub.value", ctx.io, e);
            defer r.deinit();
            keepDyn(ctx, r);
        }

        pub fn mulValue(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            var r = env.gen[c].mul(env.ovl[c]) catch |e| fatal("mul.value", ctx.io, e);
            defer r.deinit();
            keepDyn(ctx, r);
        }

        pub fn divValue(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            var r = env.gen[c].div(env.pos[c]) catch |e| fatal("div.value", ctx.io, e);
            defer r.deinit();
            keepDyn(ctx, r);
        }

        pub fn hullValue(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            var r = env.gen[c].hull(env.ovl[c]) catch |e| fatal("hull.value", ctx.io, e);
            defer r.deinit();
            keepDyn(ctx, r);
        }

        pub fn intersectValue(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            const mapped = env.gen[c].intersect(env.ovl[c]) catch |e|
                fatal("intersect.value", ctx.io, e);
            var r = mapped orelse {
                ctx.keep(0);
                return;
            };
            defer r.deinit();
            keepDyn(ctx, r);
        }

        pub fn intersectDisjointValue(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            const mapped = env.gen[c].intersect(env.dis[c]) catch |e|
                fatal("intersect.disj.value", ctx.io, e);
            var r = mapped orelse {
                ctx.keep(-1);
                return;
            };
            defer r.deinit();
            keepDyn(ctx, r);
        }

        // -- in-place: no allocation at all ----------------------------

        pub fn seed(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            @memcpy(env.work.comps, env.gen[c].comps);
            keepDyn(ctx, env.work);
        }

        pub fn iadd(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            @memcpy(env.work.comps, env.gen[c].comps);
            env.work.iadd(env.ovl[c]) catch |e| fatal("iadd", ctx.io, e);
            keepDyn(ctx, env.work);
        }

        pub fn isub(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            @memcpy(env.work.comps, env.gen[c].comps);
            env.work.isub(env.ovl[c]) catch |e| fatal("isub", ctx.io, e);
            keepDyn(ctx, env.work);
        }

        pub fn imul(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            @memcpy(env.work.comps, env.gen[c].comps);
            env.work.imul(env.ovl[c]) catch |e| fatal("imul", ctx.io, e);
            keepDyn(ctx, env.work);
        }

        pub fn idiv(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            @memcpy(env.work.comps, env.gen[c].comps);
            env.work.idiv(env.pos[c]) catch |e| fatal("idiv", ctx.io, e);
            keepDyn(ctx, env.work);
        }

        pub fn neg(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            @memcpy(env.work.comps, env.gen[c].comps);
            env.work.neg();
            keepDyn(ctx, env.work);
        }

        pub fn recip(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            @memcpy(env.work.comps, env.pos[c].comps);
            env.work.recip();
            keepDyn(ctx, env.work);
        }

        pub fn abs(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            @memcpy(env.work.comps, env.gen[c].comps);
            env.work.abs();
            keepDyn(ctx, env.work);
        }

        pub fn sqr(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            @memcpy(env.work.comps, env.gen[c].comps);
            env.work.sqr();
            keepDyn(ctx, env.work);
        }

        // -- the ones with no allocation and no in-place twin -----------

        pub fn contains(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            ctx.keep(if (env.gen[c].contains(point(c))) 1 else 0);
        }

        pub fn distance(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            ctx.keep(env.gen[c].distance(point(c)));
        }

        // -- mapResult: allocates from the box's own allocator ----------

        pub fn mapResultSqrt(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            const mapped = interval.mapResult(env.pos[c], interval.sqrt) catch |e|
                fatal("mapResult.sqrt.value", ctx.io, e);
            var r = mapped orelse {
                ctx.keep(0);
                return;
            };
            defer r.deinit();
            keepDyn(ctx, r);
        }

        pub fn mapResultSqrtOutOfDomain(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            const mapped = interval.mapResult(env.gen[c], interval.sqrt) catch |e|
                fatal("mapResult.sqrt.ood.value", ctx.io, e);
            var r = mapped orelse {
                // Allocated, walked one component, freed. Nothing else.
                ctx.keep(-1);
                return;
            };
            defer r.deinit();
            keepDyn(ctx, r);
        }
    };
}

// ---------------------------------------------------------------------------
// Allocator cost on its own.
//
// The gap between a value-returning `DynVec` call and an in-place one is an
// allocator round trip plus a little. This measures the round trip
// directly, at every box size the `DynVec` sections use, under the
// allocator the hot path uses and under a `DebugAllocator`, so the share of
// the `DynVec` figures that belongs to the allocator rather than to the
// library is visible rather than assumed.
//
// Every size, not just two of them. A round trip's cost depends on the
// request size, and a share computed against the wrong size would be a
// fabrication, so each dimension's own byte count is measured rather than
// interpolated from a neighbour.
// ---------------------------------------------------------------------------

/// The bytes a `DynVec` of width n asks its allocator for, which is the
/// same request `DynVec.allocLike` makes on every value-returning call.
fn boxBytes(comptime n: usize) usize {
    return n * @sizeOf(Interval);
}

/// Row name for a round trip at one dimension under one allocator.
fn allocName(comptime s: []const u8, comptime suffix: []const u8) []const u8 {
    return std.fmt.comptimePrint("alloc.{s}comp.{s}", .{ s, suffix });
}

/// Human label for the same row: the width and the request size. The size
/// is written out as an expression rather than as a call to `boxBytes`,
/// because Zig 0.16 cannot resolve the length of a `comptimePrint` whose
/// argument tuple holds a function call.
fn allocLabel(comptime n: usize) []const u8 {
    return std.fmt.comptimePrint("{d} components ({d} B)", .{ n, n * @sizeOf(Interval) });
}

/// A `DebugAllocator` of this file's own, for the allocation-only rows.
///
/// It is deliberately not one of the `DynVec` environments' allocators: a
/// round trip is the cost of one `alloc`/`free` pair and nothing else, and
/// these rows are the reference the `DynVec` figures are divided by, so they
/// are measured on allocators that serve no other purpose.
///
/// `.init` is a comptime constant, so this is a definite value rather than a
/// lazy one: the instance exists before the first body runs, which is when
/// the equivalent assignment in `main` used to create it, and it is the
/// only file-scope state these two rows need.
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

/// One allocator round trip at one size, under the allocator named by the
/// body: `smp` is `std.heap.smp_allocator` itself, the allocator the hot
/// path uses, and `debug` is `debug_allocator` above.
///
/// Both bodies are three operations and a read: one allocation of the box
/// size, one byte touched, the byte read into the sink while the
/// allocation is alive, and the free.
fn AllocBench(comptime bytes: usize) type {
    return struct {
        pub fn smp(ctx: *timing.Ctx, i: usize) void {
            const p = std.heap.smp_allocator.alloc(u8, bytes) catch |e|
                timing.fail("bench_vec: alloc round trip (smp)", ctx.io, e);
            // The touch is one byte: the point is the allocator, and a
            // first-touch page fault would be an mmap measurement.
            p[0] = @truncate(i);
            // Read the byte back BEFORE the free. This used to free first
            // and then read `p[0]` into the sink, which is a use-after-free:
            // the smp allocator happened to leave the byte intact so the
            // figures looked plausible, while the DebugAllocator poisons
            // freed memory and the row died with SIGSEGV. The sink was also
            // reading whatever the allocator left behind, so both rows
            // reported `checksum 0` for work that had plainly happened.
            // The value is what keeps the work observable; it has to be
            // taken while the allocation is still alive.
            ctx.keep(p[0]);
            std.heap.smp_allocator.free(p);
        }

        pub fn debug(ctx: *timing.Ctx, i: usize) void {
            // `.allocator()` is called per iteration here, as it always was:
            // building the view is part of what this row measures.
            const p = debug_allocator.allocator().alloc(u8, bytes) catch |e|
                timing.fail("bench_vec: alloc round trip (debug)", ctx.io, e);
            p[0] = @truncate(i);
            ctx.keep(p[0]);
            debug_allocator.allocator().free(p);
        }
    };
}

// ---------------------------------------------------------------------------
// Driver
// ---------------------------------------------------------------------------

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);

    var runner = try timing.Runner.init(gpa.allocator());
    defer runner.deinit();
    var out = timing.Out.init(runner.io);

    // Two environments per dimension, one per allocator, on the same
    // inputs, so a value-returning figure under one can be set against the
    // same figure under the other. The `defer` for the teardown is
    // registered after the `dyn_gpa` teardown and so runs before it, which
    // is what keeps the DebugAllocator's leak report empty.
    var dyn_gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(dyn_gpa.deinit() == .ok);
    inline for (dims) |d| {
        try setupEnv(d.n, std.heap.smp_allocator, envOf(.smp, d.n));
        try setupEnv(d.n, dyn_gpa.allocator(), envOf(.dbg, d.n));
    }
    defer inline for (dims) |d| {
        teardownEnv(envOf(.smp, d.n));
        teardownEnv(envOf(.dbg, d.n));
    };

    try out.print("\n=== Vec(n): fixed dimension, inline components ===\n", .{});
    inline for (dims) |d| {
        const vec = VecBench(d.n);
        const it = itersFor(d.n);
        const p = "vec" ++ d.s ++ ".";
        try timing.measure(p ++ "add", vec.add, &runner, it);
        try timing.measure(p ++ "sub", vec.sub, &runner, it);
        try timing.measure(p ++ "mul", vec.mul, &runner, it);
        try timing.measure(p ++ "div", vec.div, &runner, it);
        try timing.measure(p ++ "neg", vec.neg, &runner, it);
        try timing.measure(p ++ "recip", vec.recip, &runner, it);
        try timing.measure(p ++ "abs", vec.abs, &runner, it);
        try timing.measure(p ++ "sqr", vec.sqr, &runner, it);
        try timing.measure(p ++ "hull", vec.hull, &runner, it);
        try timing.measure(p ++ "intersect", vec.intersect, &runner, it);
        try timing.measure(p ++ "intersect.disjoint", vec.intersectDisjoint, &runner, it);
        try timing.measure(p ++ "mapResult.sqrt", vec.mapResultSqrt, &runner, it);
        try timing.measure(
            p ++ "mapResult.sqrt.ood",
            vec.mapResultSqrtOutOfDomain,
            &runner,
            it,
        );
        try timing.measure(p ++ "contains", vec.contains, &runner, it);
        try timing.measure(p ++ "distance", vec.distance, &runner, it);
    }

    try out.print("\n=== DynVec: runtime dimension, heap components ===\n", .{});
    inline for (dims) |d| {
        // `smp` and `dbg` are the same bodies over the same inputs on the
        // two allocators. Only the value-returning ones differ: they are the
        // ones that reach `env.gpa`. The in-place and no-allocation bodies
        // are measured once, from `smp`, because a second run of them under
        // `dbg` would be the same number printed twice.
        const smp = DynBench(d.n, .smp);
        const dbg = DynBench(d.n, .dbg);
        const it = itersFor(d.n);
        const p = "dyn" ++ d.s ++ ".";
        try timing.measure(p ++ "seed", smp.seed, &runner, it);
        try timing.measure(p ++ "add.value.smp", smp.addValue, &runner, it);
        try timing.measure(p ++ "add.value.dbg", dbg.addValue, &runner, it);
        try timing.measure(p ++ "add.inplace", smp.iadd, &runner, it);
        try timing.measure(p ++ "sub.value.smp", smp.subValue, &runner, it);
        try timing.measure(p ++ "sub.value.dbg", dbg.subValue, &runner, it);
        try timing.measure(p ++ "sub.inplace", smp.isub, &runner, it);
        try timing.measure(p ++ "mul.value.smp", smp.mulValue, &runner, it);
        try timing.measure(p ++ "mul.value.dbg", dbg.mulValue, &runner, it);
        try timing.measure(p ++ "mul.inplace", smp.imul, &runner, it);
        try timing.measure(p ++ "div.value.smp", smp.divValue, &runner, it);
        try timing.measure(p ++ "div.value.dbg", dbg.divValue, &runner, it);
        try timing.measure(p ++ "div.inplace", smp.idiv, &runner, it);
        try timing.measure(p ++ "hull.value.smp", smp.hullValue, &runner, it);
        try timing.measure(p ++ "hull.value.dbg", dbg.hullValue, &runner, it);
        try timing.measure(p ++ "intersect.value.smp", smp.intersectValue, &runner, it);
        try timing.measure(p ++ "intersect.value.dbg", dbg.intersectValue, &runner, it);
        try timing.measure(
            p ++ "intersect.disj.value.smp",
            smp.intersectDisjointValue,
            &runner,
            it,
        );
        try timing.measure(
            p ++ "intersect.disj.value.dbg",
            dbg.intersectDisjointValue,
            &runner,
            it,
        );
        try timing.measure(p ++ "neg.inplace", smp.neg, &runner, it);
        try timing.measure(p ++ "recip.inplace", smp.recip, &runner, it);
        try timing.measure(p ++ "abs.inplace", smp.abs, &runner, it);
        try timing.measure(p ++ "sqr.inplace", smp.sqr, &runner, it);
        try timing.measure(p ++ "mapResult.sqrt.value.smp", smp.mapResultSqrt, &runner, it);
        try timing.measure(p ++ "mapResult.sqrt.value.dbg", dbg.mapResultSqrt, &runner, it);
        try timing.measure(
            p ++ "mapResult.sqrt.ood.value.smp",
            smp.mapResultSqrtOutOfDomain,
            &runner,
            it,
        );
        try timing.measure(
            p ++ "mapResult.sqrt.ood.value.dbg",
            dbg.mapResultSqrtOutOfDomain,
            &runner,
            it,
        );
        try timing.measure(p ++ "contains", smp.contains, &runner, it);
        try timing.measure(p ++ "distance", smp.distance, &runner, it);
    }

    // One round trip per dimension, at that dimension's own box size, so
    // the share printed in the report divides a value-returning figure by
    // the round trip that figure actually pays.
    try out.print("\n=== allocator round trip, alone ===\n", .{});
    inline for (dims) |d| {
        const it = itersFor(d.n);
        try timing.measure(allocName(d.s, "smp"), AllocBench(boxBytes(d.n)).smp, &runner, it);
        try timing.measure(allocName(d.s, "debug"), AllocBench(boxBytes(d.n)).debug, &runner, it);
    }

    try report(&runner);
    try runner.report.print();
}

// ---------------------------------------------------------------------------
// Reporting.
//
// The harness prints one flat table sorted by cost, which is the right
// shape for "what is slow" and the wrong shape for "how does cost scale
// with N". The tables below are the actual deliverable: the per-component
// column is what makes an N=16 regression visible, and the value/in-place
// column is the actionable finding. They are printed before the harness
// table because the harness sorts its rows in place.
//
// A form is a claim about what the body does, not a bucket to sort
// figures into, and the three `dyn_*` fields below are mutually exclusive
// for exactly that reason. `contains` and `distance` used to be listed
// under the value-returning field even though they return a scalar and
// never allocate, which printed `contains 2.95/value` beside neighbours
// at 11,000 ns and told the reader a round trip the body does not make.
// They now have a field of their own, and every cell that is not measured
// prints a dash rather than a number.
// ---------------------------------------------------------------------------

const Op = struct {
    name: []const u8,
    vec: ?[]const u8 = null,
    /// Value-returning: allocates and frees once per call. The template
    /// takes the dimension and then the allocator suffix, so it expands
    /// to two row names.
    dyn_val: ?[]const u8 = null,
    /// In-place: allocates nothing.
    dyn_in: ?[]const u8 = null,
    /// Returns a scalar, not a box. Allocates nothing and has no
    /// in-place twin.
    dyn_none: ?[]const u8 = null,
};

const ops = [_]Op{
    .{ .name = "add", .vec = "vec{s}.add", .dyn_val = "dyn{s}.add.value.{s}", .dyn_in = "dyn{s}.add.inplace" },
    .{ .name = "sub", .vec = "vec{s}.sub", .dyn_val = "dyn{s}.sub.value.{s}", .dyn_in = "dyn{s}.sub.inplace" },
    .{ .name = "mul", .vec = "vec{s}.mul", .dyn_val = "dyn{s}.mul.value.{s}", .dyn_in = "dyn{s}.mul.inplace" },
    .{ .name = "div", .vec = "vec{s}.div", .dyn_val = "dyn{s}.div.value.{s}", .dyn_in = "dyn{s}.div.inplace" },
    .{ .name = "hull", .vec = "vec{s}.hull", .dyn_val = "dyn{s}.hull.value.{s}" },
    .{ .name = "neg", .vec = "vec{s}.neg", .dyn_in = "dyn{s}.neg.inplace" },
    .{ .name = "recip", .vec = "vec{s}.recip", .dyn_in = "dyn{s}.recip.inplace" },
    .{ .name = "abs", .vec = "vec{s}.abs", .dyn_in = "dyn{s}.abs.inplace" },
    .{ .name = "sqr", .vec = "vec{s}.sqr", .dyn_in = "dyn{s}.sqr.inplace" },
    .{ .name = "intersect", .vec = "vec{s}.intersect", .dyn_val = "dyn{s}.intersect.value.{s}" },
    .{
        .name = "intersect (disjoint)",
        .vec = "vec{s}.intersect.disjoint",
        .dyn_val = "dyn{s}.intersect.disj.value.{s}",
    },
    .{ .name = "mapResult sqrt", .vec = "vec{s}.mapResult.sqrt", .dyn_val = "dyn{s}.mapResult.sqrt.value.{s}" },
    .{
        .name = "mapResult sqrt (out of domain)",
        .vec = "vec{s}.mapResult.sqrt.ood",
        .dyn_val = "dyn{s}.mapResult.sqrt.ood.value.{s}",
    },
    .{ .name = "contains", .vec = "vec{s}.contains", .dyn_none = "dyn{s}.contains" },
    .{ .name = "distance", .vec = "vec{s}.distance", .dyn_none = "dyn{s}.distance" },
};

/// The row name of a value-returning body under one allocator: the
/// allocator is always on the end, so a bare `dyn4.add.value` cannot appear
/// in a report. Both arguments go straight into the format for the same
/// reason `allocLabel` spells its size out: Zig 0.16 leaves the length of a
/// `comptimePrint` unresolvable when its argument tuple holds a call, and a
/// plain `++` of two comptime slices yields a correctly sized array of
/// zeroes instead of the text.
fn valName(comptime tpl: []const u8, comptime dim: []const u8, comptime a: Alloc) []const u8 {
    return switch (a) {
        .smp => std.fmt.comptimePrint(tpl, .{ dim, "smp" }),
        .dbg => std.fmt.comptimePrint(tpl, .{ dim, "dbg" }),
    };
}

/// The row names one (dimension, operation) pair contributes, expanded at
/// comptime. The report walks this at run time and does nothing but a
/// string lookup per cell, because the harness keys its rows by name and
/// the thing worth reading here is a matrix rather than a list.
const PlanRow = struct {
    vec: ?[]const u8 = null,
    /// The value-returning row under each allocator, indexed by
    /// `@intFromEnum(Alloc)`. Both are always set or both are null, so no
    /// table can print one and silently drop the other.
    val: [2]?[]const u8 = .{ null, null },
    inpl: ?[]const u8 = null,
    noalloc: ?[]const u8 = null,
};

fn buildPlan() [dims.len][ops.len]PlanRow {
    @setEvalBranchQuota(5_000_000);
    var arr: [dims.len][ops.len]PlanRow = undefined;
    inline for (dims, 0..) |d, di| {
        inline for (ops, 0..) |op, oi| {
            arr[di][oi] = .{
                .vec = if (op.vec) |t| std.fmt.comptimePrint(t, .{d.s}) else null,
                .val = if (op.dyn_val) |t| .{
                    valName(t, d.s, .smp),
                    valName(t, d.s, .dbg),
                } else .{ null, null },
                .inpl = if (op.dyn_in) |t| std.fmt.comptimePrint(t, .{d.s}) else null,
                .noalloc = if (op.dyn_none) |t| std.fmt.comptimePrint(t, .{d.s}) else null,
            };
        }
    }
    return arr;
}

fn buildSeedNames() [dims.len][]const u8 {
    @setEvalBranchQuota(5_000_000);
    var arr: [dims.len][]const u8 = undefined;
    inline for (dims, 0..) |d, di| arr[di] = std.fmt.comptimePrint("dyn{s}.seed", .{d.s});
    return arr;
}

const plan = buildPlan();
const seed_names = buildSeedNames();

fn nsFor(runner: *timing.Runner, name: []const u8) ?f64 {
    for (runner.report.rows.items) |r| {
        if (std.mem.eql(u8, r.name, name)) return r.ns_per_op;
    }
    return null;
}

/// The in-place DynVec figure, net of the re-seed copy, so it can be set
/// against the `Vec(n)` figure, which has no equivalent setup cost.
fn dynInPlaceNet(runner: *timing.Runner, di: usize, key: ?[]const u8) ?f64 {
    const k = key orelse return null;
    const gross = nsFor(runner, k) orelse return null;
    const seed = nsFor(runner, seed_names[di]) orelse 0;
    return @max(gross - seed, 0);
}

/// Horizontal rules. `**` is array repetition now, so a repeated string is
/// spliced out of a literal with `++` rather than written as `"-" ** n`.
const dash10 = "----------";
const dash60 = dash10 ++ dash10 ++ dash10 ++ dash10 ++ dash10 ++ dash10;
const dash70 = dash10 ++ dash10 ++ dash10 ++ dash10 ++ dash10 ++ dash10 ++ dash10;
const dash80 = dash70 ++ dash10;
const dash100 = dash80 ++ dash10 ++ dash10;
const dash110 = dash100 ++ dash10;

fn columnHeader(out: *timing.Out) !void {
    try out.print("{s:>34}", .{"operation"});
    for (dims) |d| try out.print("  {s:>13}", .{d.s});
    try out.print("\n{s}\n", .{dash100});
}

/// Which `DynVec` form a cross-over column is built from. The two
/// value-returning entries differ only in the allocator, which is the whole
/// point: the ratio is not a property of the library until the allocator
/// behind it is named.
const DynForm = enum { inpl_net, value_smp, value_dbg };

/// `Vec(n)` against `DynVec` at the same operation and the same dimension.
/// `form` picks which `DynVec` form is the comparison: the in-place form is
/// what a caller writing `dv.iadd(other)` pays, the two value-returning
/// forms are what a caller writing `dv = dv.add(other)` pays, once per
/// allocator. A dash means the operation has no such form, not that it was
/// fast.
fn crossOver(
    comptime form: DynForm,
    out: *timing.Out,
    runner: *timing.Runner,
    title: []const u8,
    note: []const u8,
) !void {
    try out.print("\n=== {s} ===\n", .{title});
    try columnHeader(out);
    for (0..ops.len) |oi| {
        try out.print("{s:>34}", .{ops[oi].name});
        for (0..dims.len) |di| {
            const pr = plan[di][oi];
            const v = if (pr.vec) |k| nsFor(runner, k) else null;
            const d: ?f64 = switch (form) {
                .inpl_net => dynInPlaceNet(runner, di, pr.inpl),
                .value_smp => if (pr.val[@intFromEnum(Alloc.smp)]) |k| nsFor(runner, k) else null,
                .value_dbg => if (pr.val[@intFromEnum(Alloc.dbg)]) |k| nsFor(runner, k) else null,
            };
            if (v != null and d != null) {
                try out.print("  {d:>6.2}/{d:>5.2}", .{ v.?, d.? / v.? });
            } else {
                try out.print("  {s:>13}", .{"-"});
            }
        }
        try out.print("\n", .{});
    }
    try out.print("\n{s}\n", .{note});
}

/// A figure, or a dash when the operation has no such form. Never 0.00 for
/// a missing cell: 0 ns would be a claim about a measurement, whereas a
/// dash is only a claim about the table.
fn cell(out: *timing.Out, ns: ?f64) !void {
    if (ns) |v| {
        try out.print("{d:>13.2}", .{v});
    } else {
        try out.print("{s:>13}", .{"-"});
    }
}

/// The round trip as a percentage of a whole call, or a dash when either
/// side of the ratio is missing.
fn shareCell(out: *timing.Out, rt: ?f64, call: ?f64) !void {
    const r = rt orelse {
        try out.print("{s:>11}", .{"-"});
        return;
    };
    const c = call orelse {
        try out.print("{s:>11}", .{"-"});
        return;
    };
    if (c <= 0) {
        try out.print("{s:>11}", .{"-"});
        return;
    }
    try out.print("{d:>11.1}", .{100.0 * r / c});
}

/// The `add` row of `ops`, used as the reference for the allocator share:
/// `add` is the operation the cross-over claim is quoted for, so it is the
/// one the share is stated against. Every other value-returning row is in
/// the table above and divides by the same round trip.
const add_op: usize = blk: {
    for (ops, 0..) |op, idx| {
        if (std.mem.eql(u8, op.name, "add")) break :blk idx;
    }
    @compileError("no `add` row in `ops`");
};

fn report(runner: *timing.Runner) !void {
    var out = timing.Out.init(runner.io);
    try out.print("\n=== Vec(n): ns per call / ns per component ===\n", .{});
    try columnHeader(&out);
    for (0..ops.len) |oi| {
        try out.print("{s:>34}", .{ops[oi].name});
        for (0..dims.len) |di| {
            const key = plan[di][oi].vec;
            const ns = if (key) |k| nsFor(runner, k) else null;
            if (ns) |v| {
                try out.print("  {d:>6.2}/{d:>5.2}", .{ v, v / @as(f64, @floatFromInt(dims[di].n)) });
            } else {
                try out.print("  {s:>13}", .{"-"});
            }
        }
        try out.print("\n", .{});
    }
    try out.print("\n  left of the slash is ns per call, right is ns per component\n", .{});

    // One row per (operation, dimension) rather than a matrix: a dimension
    // column now carries four figures instead of two, and a matrix of
    // those runs off the side of a screen.
    try out.print("\n=== DynVec: what each form costs, ns per call ===\n", .{});
    try out.print("{s:>34}{s:>5}{s:>13}{s:>13}{s:>13}{s:>13}\n", .{
        "operation", "dim", "inpl(net)", "no-alloc", "value/smp", "value/dbg",
    });
    try out.print("{s}\n", .{dash100});
    for (0..ops.len) |oi| {
        for (0..dims.len) |di| {
            const pr = plan[di][oi];
            if (pr.inpl == null and pr.noalloc == null and pr.val[0] == null) continue;
            try out.print("{s:>34}{s:>5}", .{ ops[oi].name, dims[di].s });
            try cell(&out, dynInPlaceNet(runner, di, pr.inpl));
            try cell(&out, if (pr.noalloc) |k| nsFor(runner, k) else null);
            try cell(&out, if (pr.val[@intFromEnum(Alloc.smp)]) |k| nsFor(runner, k) else null);
            try cell(&out, if (pr.val[@intFromEnum(Alloc.dbg)]) |k| nsFor(runner, k) else null);
            try out.print("\n", .{});
        }
    }
    try out.print("\n  inpl(net) allocates nothing; it is the in-place body minus its re-seed copy\n", .{});
    try out.print("  no-alloc returns a scalar rather than a box, so it has nothing to allocate\n", .{});
    try out.print("  value/smp and value/dbg are the same body allocating and freeing on every\n", .{});
    try out.print("  call, once under smp_allocator and once under a DebugAllocator. The gap\n", .{});
    try out.print("  between those two columns is the allocator, not the library.\n", .{});
    try out.print("  A dash is an operation that has no such form, never a dropped measurement.\n", .{});

    try out.print("\n=== DynVec in-place, net of the re-seed copy ===\n", .{});
    try out.print("{s:>34}{s:>8}{s:>12}{s:>12}{s:>12}\n", .{
        "operation", "dim", "as measured", "re-seed", "net",
    });
    try out.print("{s}\n", .{dash80});
    for (0..ops.len) |oi| {
        for (0..dims.len) |di| {
            const gross = if (plan[di][oi].inpl) |k| nsFor(runner, k) else null;
            const net = dynInPlaceNet(runner, di, plan[di][oi].inpl);
            const seed = nsFor(runner, seed_names[di]) orelse 0;
            if (gross != null and net != null) {
                try out.print("{s:>34}{s:>8}{d:>12.2}{d:>12.2}{d:>12.2}\n", .{
                    ops[oi].name, dims[di].s, gross.?, seed, net.?,
                });
            }
        }
    }

    const ratio_note = "  left is Vec(n) ns/call, right is the ratio; above 1.00 the fixed form is cheaper";
    try crossOver(
        .inpl_net,
        &out,
        runner,
        "cross-over: DynVec in-place (net) / Vec(n)",
        ratio_note,
    );
    try crossOver(
        .value_smp,
        &out,
        runner,
        "cross-over: DynVec value-returning under smp_allocator / Vec(n)",
        ratio_note,
    );
    try crossOver(
        .value_dbg,
        &out,
        runner,
        "cross-over: DynVec value-returning under DebugAllocator / Vec(n)",
        ratio_note,
    );

    try out.print("\n=== allocator round trip on its own, ns per alloc+free ===\n", .{});
    try out.print("{s:>34}{s:>13}{s:>13}\n", .{ "box", "smp", "Debug" });
    try out.print("{s}\n", .{dash60});
    inline for (dims) |d| {
        try out.print("{s:>34}", .{allocLabel(d.n)});
        try cell(&out, nsFor(runner, allocName(d.s, "smp")));
        try cell(&out, nsFor(runner, allocName(d.s, "debug")));
        try out.print("\n", .{});
    }
    try out.print("\n  'smp' is std.heap.smp_allocator, which the hot path uses, and 'Debug' is a\n", .{});
    try out.print("  DebugAllocator. One row per box size, so a share can be divided by the round\n", .{});
    try out.print("  trip that box actually pays rather than by one measured at another size.\n", .{});

    try out.print("\n=== how much of a value-returning add is the allocator ===\n", .{});
    try out.print("{s:>34}{s:>13}{s:>13}{s:>13}{s:>13} {s:>11}{s:>11}\n", .{
        "box", "rt smp", "rt Debug", "add smp", "add Debug", "% rt smp", "% rt Debug",
    });
    try out.print("{s}\n", .{dash110});
    inline for (dims) |d| {
        const pr = plan[dimSlot(d.n)][add_op];
        const rt_smp = nsFor(runner, allocName(d.s, "smp"));
        const rt_dbg = nsFor(runner, allocName(d.s, "debug"));
        const val_smp = if (pr.val[@intFromEnum(Alloc.smp)]) |k| nsFor(runner, k) else null;
        const val_dbg = if (pr.val[@intFromEnum(Alloc.dbg)]) |k| nsFor(runner, k) else null;
        try out.print("{s:>34}", .{allocLabel(d.n)});
        try cell(&out, rt_smp);
        try cell(&out, rt_dbg);
        try cell(&out, val_smp);
        try cell(&out, val_dbg);
        try shareCell(&out, rt_smp, val_smp);
        try shareCell(&out, rt_dbg, val_dbg);
        try out.print("\n", .{});
    }
    try out.print("\n  'rt' is the round trip at that exact box size, 'add' the value-returning add\n", .{});
    try out.print("  on the same allocator. The percentage is the round trip's share of that one\n", .{});
    try out.print("  call; the remainder is the componentwise fold and the sink, and is the\n", .{});
    try out.print("  library's. The same division holds for every value-returning row above.\n", .{});
    try out.print("  Every figure is the minimum of seven repetitions, so a share above 100 just\n", .{});
    try out.print("  means the round trip's best repetition beat the call's.\n", .{});
}
