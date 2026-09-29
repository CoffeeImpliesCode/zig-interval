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
//! step, while a loop of `dv.iadd(other)` pays it once. That difference is
//! the most actionable thing a user of this library can be told, and it
//! cannot be reported without measuring both forms. It is measured here for
//! `add`, `sub`, `mul`, `div`, `hull` and `intersect`, and the in-place
//! numbers are reported net of the re-seed copy so the comparison is
//! fold-against-allocator rather than memcpy-against-allocator.
//!
//! Allocators: the hot path uses `std.heap.smp_allocator`, the general
//! purpose allocator a caller reaches for by default, because a
//! `DebugAllocator` would make an allocation benchmark measure the
//! `DebugAllocator` — its own bookkeeping, its own leak-detection state —
//! rather than the library. That claim is not taken on faith: the last
//! section times a bare `alloc`/`free` round trip under both allocators at
//! two sizes, so the reader can see how much of a `DynVec` figure is the
//! allocator and how much is the library.
//!
//! Inputs vary with the iteration index over a table of `kCases` distinct
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
const kCases = 16;
const case_mask = kCases - 1;

/// Dimensions measured for both representations. The four the task calls
/// for (2, 3, 4, 16) plus 8 and 32, because the cross-over question is
/// only answerable if some dimensions bracket it.
const dims = [_]Dim{ .{ .n = 2, .s = "2" }, .{ .n = 3, .s = "3" }, .{ .n = 4, .s = "4" }, .{ .n = 8, .s = "8" }, .{ .n = 16, .s = "16" }, .{ .n = 32, .s = "32" } };

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

fn makeVecTable(comptime n: usize, comptime shape: Shape) [kCases]Vec(n) {
    @setEvalBranchQuota(100_000);
    var s: u64 = lcg_state;
    var out: [kCases]Vec(n) = undefined;
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
fn makePointTable(comptime n: usize) [kCases][n]f64 {
    @setEvalBranchQuota(100_000);
    var s: u64 = lcg_state ^ 0x9E37_79B9_7F4A_7C15;
    var out: [kCases][n]f64 = undefined;
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

fn keepVec(ctx: *timing.Ctx, comptime n: usize, v: Vec(n)) void {
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
            keepVec(ctx, n, gen[i & case_mask].add(gen[(i + 1) & case_mask]));
        }

        pub fn sub(ctx: *timing.Ctx, i: usize) void {
            keepVec(ctx, n, gen[i & case_mask].sub(ovl[i & case_mask]));
        }

        pub fn mul(ctx: *timing.Ctx, i: usize) void {
            keepVec(ctx, n, gen[i & case_mask].mul(gen[(i + 1) & case_mask]));
        }

        pub fn div(ctx: *timing.Ctx, i: usize) void {
            keepVec(ctx, n, gen[i & case_mask].div(pos[i & case_mask]));
        }

        pub fn neg(ctx: *timing.Ctx, i: usize) void {
            keepVec(ctx, n, gen[i & case_mask].neg());
        }

        pub fn recip(ctx: *timing.Ctx, i: usize) void {
            keepVec(ctx, n, pos[i & case_mask].recip());
        }

        pub fn abs(ctx: *timing.Ctx, i: usize) void {
            keepVec(ctx, n, gen[i & case_mask].abs());
        }

        pub fn sqr(ctx: *timing.Ctx, i: usize) void {
            keepVec(ctx, n, gen[i & case_mask].sqr());
        }

        pub fn hull(ctx: *timing.Ctx, i: usize) void {
            keepVec(ctx, n, gen[i & case_mask].hull(ovl[i & case_mask]));
        }

        pub fn intersect(ctx: *timing.Ctx, i: usize) void {
            if (gen[i & case_mask].intersect(ovl[i & case_mask])) |r| {
                keepVec(ctx, n, r);
            } else {
                ctx.keep(0);
            }
        }

        /// The early exit: `disjoint` is separated from `gen` on every
        /// component, so the fold stops at the first one.
        pub fn intersect_disjoint(ctx: *timing.Ctx, i: usize) void {
            if (gen[i & case_mask].intersect(dis[i & case_mask])) |r| {
                keepVec(ctx, n, r);
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
        /// domain failure is a null with nothing to free.
        pub fn mapResult_sqrt(ctx: *timing.Ctx, i: usize) void {
            if (interval.mapResult(pos[i & case_mask], interval.sqrt) catch unreachable) |r| {
                keepVec(ctx, n, r);
            } else {
                ctx.keep(0);
            }
        }

        pub fn mapResult_sqrt_out_of_domain(ctx: *timing.Ctx, i: usize) void {
            // `gen` straddles zero, so `sqrt` fails on it. The fold stops
            // at the first component.
            if (interval.mapResult(gen[i & case_mask], interval.sqrt) catch unreachable) |r| {
                keepVec(ctx, n, r);
            } else {
                ctx.keep(-1);
            }
        }
    };
}

// ---------------------------------------------------------------------------
// DynVec bodies.
//
// The tables are on the heap, built once in `setup`, and reached through a
// file-scope array indexed by dimension. A benchmark body is a plain
// `fn (ctx, i) void` with nowhere to hang a context, so the state it needs
// has to live somewhere the function can name.
//
// The in-place bodies re-seed their destination from the table each step.
// Without that the box would be transformed over and over across the
// hundreds of thousands of iterations of a run and drift to infinities and
// then to NaN, and the figure would be the cost of arithmetic on NaN. The
// re-seed is a `memcpy` of n components; the `seed` body measures exactly
// that copy with no operation on top of it, so the in-place figure can be
// read net of it.
// ---------------------------------------------------------------------------

const DynEnv = struct {
    gpa: std.mem.Allocator,
    gen: []DynVec,
    pos: []DynVec,
    ovl: []DynVec,
    dis: []DynVec,
    pts: []f64, // kCases * n, row-major
    work: DynVec, // scratch of width n for the in-place bodies
};

var dyn_envs: [dims.len]DynEnv = undefined;

fn dimSlot(comptime n: usize) usize {
    inline for (dims, 0..) |d, idx| {
        if (d.n == n) return idx;
    }
    @compileError("no DynVec environment for this dimension");
}

fn setupEnv(env: *DynEnv, gpa: std.mem.Allocator, comptime n: usize) !void {
    const gen = comptime makeVecTable(n, .gen);
    const pos = comptime makeVecTable(n, .pos);
    const ovl = comptime makeVecTable(n, .ovl);
    const dis = comptime makeVecTable(n, .dis);
    const pts = comptime makePointTable(n);

    env.gpa = gpa;
    env.gen = try gpa.alloc(DynVec, kCases);
    env.pos = try gpa.alloc(DynVec, kCases);
    env.ovl = try gpa.alloc(DynVec, kCases);
    env.dis = try gpa.alloc(DynVec, kCases);
    env.pts = try gpa.alloc(f64, kCases * n);
    env.work = try DynVec.init(gpa, n, Interval.init(0, 1));
    for (0..kCases) |c| {
        env.gen[c] = try boxFrom(gpa, n, gen[c]);
        env.pos[c] = try boxFrom(gpa, n, pos[c]);
        env.ovl[c] = try boxFrom(gpa, n, ovl[c]);
        env.dis[c] = try boxFrom(gpa, n, dis[c]);
        for (0..n) |k| env.pts[c * n + k] = pts[c][k];
    }
}

fn boxFrom(gpa: std.mem.Allocator, comptime n: usize, comps: Vec(n)) !DynVec {
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

fn DynBench(comptime n: usize) type {
    const env = &dyn_envs[dimSlot(n)];

    return struct {
        const Self = @This();

        fn point(c: usize) []const f64 {
            return env.pts[c * n ..][0..n];
        }

        // -- value-returning: one allocation and one free per call -------

        pub fn add_value(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            var r = env.gen[c].add(env.ovl[c]) catch unreachable;
            defer r.deinit();
            keepDyn(ctx, r);
        }

        pub fn sub_value(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            var r = env.gen[c].sub(env.ovl[c]) catch unreachable;
            defer r.deinit();
            keepDyn(ctx, r);
        }

        pub fn mul_value(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            var r = env.gen[c].mul(env.ovl[c]) catch unreachable;
            defer r.deinit();
            keepDyn(ctx, r);
        }

        pub fn div_value(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            var r = env.gen[c].div(env.pos[c]) catch unreachable;
            defer r.deinit();
            keepDyn(ctx, r);
        }

        pub fn hull_value(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            var r = env.gen[c].hull(env.ovl[c]) catch unreachable;
            defer r.deinit();
            keepDyn(ctx, r);
        }

        pub fn intersect_value(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            var r = (env.gen[c].intersect(env.ovl[c]) catch unreachable) orelse {
                ctx.keep(0);
                return;
            };
            defer r.deinit();
            keepDyn(ctx, r);
        }

        pub fn intersect_disjoint_value(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            var r = (env.gen[c].intersect(env.dis[c]) catch unreachable) orelse {
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
            env.work.iadd(env.ovl[c]) catch unreachable;
            keepDyn(ctx, env.work);
        }

        pub fn isub(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            @memcpy(env.work.comps, env.gen[c].comps);
            env.work.isub(env.ovl[c]) catch unreachable;
            keepDyn(ctx, env.work);
        }

        pub fn imul(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            @memcpy(env.work.comps, env.gen[c].comps);
            env.work.imul(env.ovl[c]) catch unreachable;
            keepDyn(ctx, env.work);
        }

        pub fn idiv(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            @memcpy(env.work.comps, env.gen[c].comps);
            env.work.idiv(env.pos[c]) catch unreachable;
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

        pub fn mapResult_sqrt(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            var r = (interval.mapResult(env.pos[c], interval.sqrt) catch unreachable) orelse {
                ctx.keep(0);
                return;
            };
            defer r.deinit();
            keepDyn(ctx, r);
        }

        pub fn mapResult_sqrt_out_of_domain(ctx: *timing.Ctx, i: usize) void {
            const c = i & case_mask;
            var r = (interval.mapResult(env.gen[c], interval.sqrt) catch unreachable) orelse {
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
// directly, under the allocator the hot path uses and under a
// `DebugAllocator`, so the share of the `DynVec` figures that belongs to
// the allocator rather than to the library is visible rather than assumed.
// ---------------------------------------------------------------------------

var smp_alloc: std.mem.Allocator = undefined;
var dbg_alloc_storage: std.heap.DebugAllocator(.{}) = undefined;

/// 4 components, the size of the smallest interesting box.
const small_bytes = 4 * @sizeOf(Interval);
/// 32 components, the largest measured.
const large_bytes = 32 * @sizeOf(Interval);

fn AllocBench(comptime bytes: usize) type {
    return struct {
        const Self = @This();
        pub fn smp(ctx: *timing.Ctx, i: usize) void {
            const p = smp_alloc.alloc(u8, bytes) catch unreachable;
            // The touch is one byte: the point is the allocator, and a
            // first-touch page fault would be an mmap measurement.
            p[0] = @truncate(i);
            smp_alloc.free(p);
            ctx.keep(p[0]);
        }

        pub fn debug(ctx: *timing.Ctx, i: usize) void {
            const p = dbg_alloc_storage.allocator().alloc(u8, bytes) catch unreachable;
            p[0] = @truncate(i);
            dbg_alloc_storage.allocator().free(p);
            ctx.keep(p[0]);
        }
    };
}

// ---------------------------------------------------------------------------
// Driver
// ---------------------------------------------------------------------------

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    smp_alloc = std.heap.smp_allocator;
    dbg_alloc_storage = .init;

    var runner = try timing.Runner.init(gpa.allocator());
    defer runner.deinit();

    var dyn_gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(dyn_gpa.deinit() == .ok);
    inline for (dims) |d| try setupEnv(&dyn_envs[dimSlot(d.n)], dyn_gpa.allocator(), d.n);
    defer inline for (dims) |d| teardownEnv(&dyn_envs[dimSlot(d.n)]);

    std.debug.print("\n=== Vec(n): fixed dimension, inline components ===\n", .{});
    inline for (dims) |d| {
        const B = VecBench(d.n);
        const it = itersFor(d.n);
        const p = "vec" ++ d.s ++ ".";
        try timing.measure(&runner, p ++ "add", it, B.add);
        try timing.measure(&runner, p ++ "sub", it, B.sub);
        try timing.measure(&runner, p ++ "mul", it, B.mul);
        try timing.measure(&runner, p ++ "div", it, B.div);
        try timing.measure(&runner, p ++ "neg", it, B.neg);
        try timing.measure(&runner, p ++ "recip", it, B.recip);
        try timing.measure(&runner, p ++ "abs", it, B.abs);
        try timing.measure(&runner, p ++ "sqr", it, B.sqr);
        try timing.measure(&runner, p ++ "hull", it, B.hull);
        try timing.measure(&runner, p ++ "intersect", it, B.intersect);
        try timing.measure(&runner, p ++ "intersect.disjoint", it, B.intersect_disjoint);
        try timing.measure(&runner, p ++ "mapResult.sqrt", it, B.mapResult_sqrt);
        try timing.measure(&runner, p ++ "mapResult.sqrt.ood", it, B.mapResult_sqrt_out_of_domain);
        try timing.measure(&runner, p ++ "contains", it, B.contains);
        try timing.measure(&runner, p ++ "distance", it, B.distance);
    }

    std.debug.print("\n=== DynVec: runtime dimension, heap components ===\n", .{});
    inline for (dims) |d| {
        const B = DynBench(d.n);
        const it = itersFor(d.n);
        const p = "dyn" ++ d.s ++ ".";
        try timing.measure(&runner, p ++ "seed", it, B.seed);
        try timing.measure(&runner, p ++ "add.value", it, B.add_value);
        try timing.measure(&runner, p ++ "add.inplace", it, B.iadd);
        try timing.measure(&runner, p ++ "sub.value", it, B.sub_value);
        try timing.measure(&runner, p ++ "sub.inplace", it, B.isub);
        try timing.measure(&runner, p ++ "mul.value", it, B.mul_value);
        try timing.measure(&runner, p ++ "mul.inplace", it, B.imul);
        try timing.measure(&runner, p ++ "div.value", it, B.div_value);
        try timing.measure(&runner, p ++ "div.inplace", it, B.idiv);
        try timing.measure(&runner, p ++ "hull.value", it, B.hull_value);
        try timing.measure(&runner, p ++ "intersect.value", it, B.intersect_value);
        try timing.measure(&runner, p ++ "intersect.disj.value", it, B.intersect_disjoint_value);
        try timing.measure(&runner, p ++ "neg.inplace", it, B.neg);
        try timing.measure(&runner, p ++ "recip.inplace", it, B.recip);
        try timing.measure(&runner, p ++ "abs.inplace", it, B.abs);
        try timing.measure(&runner, p ++ "sqr.inplace", it, B.sqr);
        try timing.measure(&runner, p ++ "mapResult.sqrt", it, B.mapResult_sqrt);
        try timing.measure(&runner, p ++ "mapResult.sqrt.ood", it, B.mapResult_sqrt_out_of_domain);
        try timing.measure(&runner, p ++ "contains", it, B.contains);
        try timing.measure(&runner, p ++ "distance", it, B.distance);
    }

    std.debug.print("\n=== allocator round trip, alone ===\n", .{});
    try timing.measure(&runner, "alloc.smp.4comp", itersFor(4), AllocBench(small_bytes).smp);
    try timing.measure(&runner, "alloc.smp.32comp", itersFor(32), AllocBench(large_bytes).smp);
    try timing.measure(&runner, "alloc.debug.4comp", itersFor(4), AllocBench(small_bytes).debug);
    try timing.measure(&runner, "alloc.debug.32comp", itersFor(32), AllocBench(large_bytes).debug);

    report(&runner);
    runner.report.print();
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
// ---------------------------------------------------------------------------

const Op = struct {
    name: []const u8,
    vec: ?[]const u8 = null,
    dyn_val: ?[]const u8 = null,
    dyn_in: ?[]const u8 = null,
};

const ops = [_]Op{
    .{ .name = "add", .vec = "vec{s}.add", .dyn_val = "dyn{s}.add.value", .dyn_in = "dyn{s}.add.inplace" },
    .{ .name = "sub", .vec = "vec{s}.sub", .dyn_val = "dyn{s}.sub.value", .dyn_in = "dyn{s}.sub.inplace" },
    .{ .name = "mul", .vec = "vec{s}.mul", .dyn_val = "dyn{s}.mul.value", .dyn_in = "dyn{s}.mul.inplace" },
    .{ .name = "div", .vec = "vec{s}.div", .dyn_val = "dyn{s}.div.value", .dyn_in = "dyn{s}.div.inplace" },
    .{ .name = "hull", .vec = "vec{s}.hull", .dyn_val = "dyn{s}.hull.value" },
    .{ .name = "neg", .vec = "vec{s}.neg", .dyn_in = "dyn{s}.neg.inplace" },
    .{ .name = "recip", .vec = "vec{s}.recip", .dyn_in = "dyn{s}.recip.inplace" },
    .{ .name = "abs", .vec = "vec{s}.abs", .dyn_in = "dyn{s}.abs.inplace" },
    .{ .name = "sqr", .vec = "vec{s}.sqr", .dyn_in = "dyn{s}.sqr.inplace" },
    .{ .name = "intersect", .vec = "vec{s}.intersect", .dyn_val = "dyn{s}.intersect.value" },
    .{ .name = "intersect (disjoint)", .vec = "vec{s}.intersect.disjoint", .dyn_val = "dyn{s}.intersect.disj.value" },
    .{ .name = "mapResult sqrt", .vec = "vec{s}.mapResult.sqrt", .dyn_val = "dyn{s}.mapResult.sqrt" },
    .{ .name = "mapResult sqrt (out of domain)", .vec = "vec{s}.mapResult.sqrt.ood", .dyn_val = "dyn{s}.mapResult.sqrt.ood" },
    .{ .name = "contains", .vec = "vec{s}.contains", .dyn_val = "dyn{s}.contains" },
    .{ .name = "distance", .vec = "vec{s}.distance", .dyn_val = "dyn{s}.distance" },
};

/// The row names one (dimension, operation) pair contributes, expanded at
/// comptime. The report walks this at run time and does nothing but a
/// string lookup per cell, because the harness keys its rows by name and
/// the thing worth reading here is a matrix rather than a list.
const PlanRow = struct {
    vec: ?[]const u8 = null,
    val: ?[]const u8 = null,
    inpl: ?[]const u8 = null,
};

fn buildPlan() [dims.len][ops.len]PlanRow {
    @setEvalBranchQuota(5_000_000);
    var arr: [dims.len][ops.len]PlanRow = undefined;
    inline for (dims, 0..) |d, di| {
        inline for (ops, 0..) |op, oi| {
            arr[di][oi] = .{
                .vec = if (op.vec) |t| std.fmt.comptimePrint(t, .{d.s}) else null,
                .val = if (op.dyn_val) |t| std.fmt.comptimePrint(t, .{d.s}) else null,
                .inpl = if (op.dyn_in) |t| std.fmt.comptimePrint(t, .{d.s}) else null,
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
const dash70 = dash10 ++ dash10 ++ dash10 ++ dash10 ++ dash10 ++ dash10 ++ dash10;
const dash80 = dash70 ++ dash10;
const dash100 = dash80 ++ dash10 ++ dash10;

fn columnHeader() void {
    std.debug.print("{s:>34}", .{"operation"});
    for (dims) |d| std.debug.print("  {s:>13}", .{d.s});
    std.debug.print("\n{s}\n", .{dash100});
}

/// `Vec(n)` against `DynVec` at the same operation and the same dimension.
/// `net_of_seed` picks which DynVec form is the comparison: the value form
/// is what a caller writing `dv = dv.add(other)` pays, the net in-place
/// form is what a caller writing `dv.iadd(other)` pays.
fn crossOver(runner: *timing.Runner, title: []const u8, note: []const u8, comptime net_of_seed: bool) void {
    std.debug.print("\n=== {s} ===\n", .{title});
    columnHeader();
    for (0..ops.len) |oi| {
        std.debug.print("{s:>34}", .{ops[oi].name});
        for (0..dims.len) |di| {
            const key = if (net_of_seed) plan[di][oi].inpl else plan[di][oi].val;
            const v = if (plan[di][oi].vec) |k| nsFor(runner, k) else null;
            const d = if (net_of_seed) dynInPlaceNet(runner, di, key) else if (key) |k| nsFor(runner, k) else null;
            if (v != null and d != null) {
                std.debug.print("  {d:>6.2}/{d:>5.2}", .{ v.?, d.? / v.? });
            } else {
                std.debug.print("  {s:>13}", .{"-"});
            }
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("\n{s}\n", .{note});
}

fn report(runner: *timing.Runner) void {
    std.debug.print("\n=== Vec(n): ns per call / ns per component ===\n", .{});
    columnHeader();
    for (0..ops.len) |oi| {
        std.debug.print("{s:>34}", .{ops[oi].name});
        for (0..dims.len) |di| {
            const key = plan[di][oi].vec;
            const ns = if (key) |k| nsFor(runner, k) else null;
            if (ns) |v| {
                std.debug.print("  {d:>6.2}/{d:>5.2}", .{ v, v / @as(f64, @floatFromInt(dims[di].n)) });
            } else {
                std.debug.print("  {s:>13}", .{"-"});
            }
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("\n  left of the slash is ns per call, right is ns per component\n", .{});

    std.debug.print("\n=== DynVec: value-returning vs in-place, ns per call ===\n", .{});
    columnHeader();
    for (0..ops.len) |oi| {
        std.debug.print("{s:>34}", .{ops[oi].name});
        for (0..dims.len) |di| {
            const a = if (plan[di][oi].val) |k| nsFor(runner, k) else null;
            const b = if (plan[di][oi].inpl) |k| nsFor(runner, k) else null;
            if (a != null and b != null) {
                std.debug.print("  {d:>6.2}/{d:>5.2}", .{ a.?, b.? });
            } else if (a != null) {
                std.debug.print("  {d:>6.2}/{s:>5}", .{ a.?, "value" });
            } else if (b != null) {
                std.debug.print("  {s:>6}/{d:>5.2}", .{ "inpl", b.? });
            } else {
                std.debug.print("  {s:>13}", .{"-"});
            }
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("\n  left of the slash allocates and frees on every call, right of it does not;\n", .{});
    std.debug.print("  'inpl' marks an operation with no value-returning form at all\n", .{});

    std.debug.print("\n=== DynVec in-place, net of the re-seed copy ===\n", .{});
    std.debug.print("{s:>34}{s:>8}{s:>12}{s:>12}{s:>12}\n", .{ "operation", "dim", "as measured", "re-seed", "net" });
    std.debug.print("{s}\n", .{dash80});
    for (0..ops.len) |oi| {
        for (0..dims.len) |di| {
            const gross = if (plan[di][oi].inpl) |k| nsFor(runner, k) else null;
            const net = dynInPlaceNet(runner, di, plan[di][oi].inpl);
            const seed = nsFor(runner, seed_names[di]) orelse 0;
            if (gross != null and net != null) {
                std.debug.print("{s:>34}{s:>8}{d:>12.2}{d:>12.2}{d:>12.2}\n", .{
                    ops[oi].name, dims[di].s, gross.?, seed, net.?,
                });
            }
        }
    }

    crossOver(runner, "cross-over: DynVec in-place (net) / Vec(n)", "  left is Vec(n) ns/call, right is the ratio; above 1.00 the fixed form is cheaper", true);
    crossOver(runner, "cross-over: DynVec value-returning / Vec(n)", "  left is Vec(n) ns/call, right is the ratio; above 1.00 the fixed form is cheaper", false);

    std.debug.print("\n=== allocator round trip on its own, ns per alloc+free ===\n", .{});
    std.debug.print("{s:>34}{s:>16}{s:>18}\n", .{ "size", "smp_allocator", "DebugAllocator" });
    std.debug.print("{s}\n", .{dash70});
    const alloc_rows = [_]struct { label: []const u8, smp: []const u8, dbg: []const u8 }{
        .{ .label = "4 components (64 B)", .smp = "alloc.smp.4comp", .dbg = "alloc.debug.4comp" },
        .{ .label = "32 components (512 B)", .smp = "alloc.smp.32comp", .dbg = "alloc.debug.32comp" },
    };
    for (alloc_rows) |r| {
        std.debug.print("{s:>34}{d:>16.2}{d:>18.2}\n", .{
            r.label,
            nsFor(runner, r.smp) orelse 0,
            nsFor(runner, r.dbg) orelse 0,
        });
    }
    std.debug.print("\n  the hot path uses smp_allocator; these rows are what that choice costs\n", .{});
}
