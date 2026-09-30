//! Shared timing harness for the interval library's benchmarks.
//!
//! Two things here are deliberate and the benchmark files rely on them, so
//! read this before changing either.
//!
//! First, every measured value is accumulated into `Ctx.sink`. Without that,
//! an optimiser is free to delete the whole loop, because a benchmark that
//! computes a value nobody reads is dead code. Accumulating into a field the
//! harness reports at the end makes the work observable.
//!
//! Second, the reported figure is the MINIMUM over several repetitions, not
//! the mean. On a machine that is doing anything else at all, a timing run is
//! a maximum over a distribution: preemptions, interrupts and cache misses
//! only ever make a run slower, never faster. The minimum is therefore the
//! closest thing available to the cost of the operation itself, and it is
//! stable run to run in a way the mean is not.
//!
//! Timings come from `std.Io.Clock.real`, which is monotonic and is the only
//! clock worth trusting for this. `std.time.Timer` does not exist in Zig 0.16.

const std = @import("std");

/// Accumulator and ambient state handed to every benchmark body.
pub const Ctx = struct {
    io: std.Io,
    /// Every measured result is summed in here so the work cannot be elided.
    /// Reported once at exit as a checksum, purely to keep it live.
    sink: f64 = 0,

    /// Adds a value to the sink. Call this with something derived from the
    /// result of the operation being measured.
    pub fn keep(self: *Ctx, v: f64) void {
        self.sink += v;
    }
};

pub const Row = struct {
    name: []const u8,
    ns_per_op: f64,
    ops_per_sec: f64,
    iterations: usize,
};

pub const Report = struct {
    rows: std.ArrayList(Row),
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Running total over every measured body, accumulated as the SUM OF BIT
    /// PATTERNS rather than as a sum of the values.
    ///
    /// The value form was tried first and is useless here. A correct
    /// benchmark in this library legitimately produces sinks of `inf` and of
    /// `-1400001`, because the operations really do return unbounded
    /// intervals, so a floating-point total collapses to `inf` on the first
    /// such body and then reads `inf` for every run regardless of what the
    /// bodies did. A constant cannot tell "the work was not elided" from
    /// "the work was elided and the result still overflowed".
    ///
    /// Summing the bit patterns keeps the figure finite, exact, and sensitive
    /// to every body that runs. It is NOT the same number as the per-row
    /// `checksum` line `measure` prints: each `measure` call builds its own
    /// `Ctx`, so its printed checksum covers that one body's warmup call plus
    /// all of its repetitions, whereas this field folds every body's sink
    /// together. It is a liveness witness across the run, not a quantity to
    /// interpret arithmetically.
    sink_total: u64,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Report {
        return .{ .gpa = gpa, .rows = .empty, .io = io, .sink_total = 0 };
    }

    pub fn deinit(self: *Report) void {
        self.rows.deinit(self.gpa);
    }

    /// Prints the collected rows as a table, slowest first, so the things
    /// worth optimising are the first thing read.
    pub fn print(self: *Report) void {
        std.sort.heap(Row, self.rows.items, {}, byCostDesc);
        std.debug.print("\n{s:>34}  {s:>12}  {s:>16}  {s:>10}\n", .{
            "operation", "ns/op", "ops/sec", "iters",
        });
        std.debug.print("{s}\n", .{"-" ** 78});
        for (self.rows.items) |r| {
            std.debug.print("{s:>34}  {d:>12.3}  {d:>16.1}  {d:>10}\n", .{
                r.name,
                r.ns_per_op,
                r.ops_per_sec,
                r.iterations,
            });
        }
        // The real accumulated total, not a placeholder. A reader checking
        // whether the work was elided needs a figure that actually moved,
        // and this one moves whenever any body computed anything different.
        std.debug.print("\nchecksum {x}\n", .{self.sink_total});
    }

    fn byCostDesc(_: void, a: Row, b: Row) bool {
        return a.ns_per_op > b.ns_per_op;
    }
};

/// Owns the Io the benchmarks need, and the report they fill in.
pub const Runner = struct {
    gpa: std.mem.Allocator,
    threaded: std.Io.Threaded,
    io: std.Io,
    report: Report,

    pub fn init(gpa: std.mem.Allocator) !Runner {
        var threaded: std.Io.Threaded = .init(gpa, .{});
        errdefer threaded.deinit();
        const io = threaded.io();
        return .{
            .gpa = gpa,
            .threaded = threaded,
            .io = io,
            .report = Report.init(gpa, io),
        };
    }

    pub fn deinit(self: *Runner) void {
        self.report.deinit();
        self.threaded.deinit();
    }
};

/// Repetitions per measurement. The minimum over these is reported.
pub const reps = 7;

/// Calls to run before measurement starts, so page faults and first-touch
/// costs do not land inside the timed region.
pub const warmup = 1;

/// Measures `body` and records one row.
///
/// `body` is a comptime-known function of `(ctx: *Ctx, i: usize) void`. It
/// MUST report something it computed through `ctx.keep`, or the optimiser is
/// entitled to delete it. It is passed an index so that a benchmark can vary
/// its inputs across iterations and avoid measuring a single cached case.
pub fn measure(
    runner: *Runner,
    comptime name: []const u8,
    iterations: usize,
    comptime body: fn (ctx: *Ctx, i: usize) void,
) !void {
    var ctx: Ctx = .{ .io = runner.io };

    for (0..warmup) |i| body(&ctx, i);

    var best: i64 = std.math.maxInt(i64);
    for (0..reps) |_| {
        const start = std.Io.Clock.real.now(runner.io);
        for (0..iterations) |i| body(&ctx, i);
        const end = std.Io.Clock.real.now(runner.io);
        const ns: i96 = end.nanoseconds - start.nanoseconds;
        const as_i64: i64 = @intCast(@max(ns, 0));
        best = @min(best, as_i64);
    }

    // Keep the sink observable after the last measurement, so nothing above
    // can be eliminated on the grounds that its result is unused.
    std.mem.doNotOptimizeAway(ctx.sink);
    std.debug.print("checksum {d}\n", .{ctx.sink});

    const ns_per_op: f64 = @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(iterations));
    // Fold this body's sink into the run total before the row is recorded,
    // by bit pattern rather than by value. See `sink_total` for why the value
    // form collapses to a constant here. `+%` rather than `+` because a
    // wrapping sum is still a perfect witness and an overflow trap in a
    // benchmark's bookkeeping would be a pointless way to end a run.
    runner.report.sink_total +%= @as(u64, @bitCast(ctx.sink));
    try runner.report.rows.append(runner.gpa, .{
        .name = name,
        .ns_per_op = ns_per_op,
        .ops_per_sec = if (ns_per_op > 0) 1e9 / ns_per_op else std.math.inf(f64),
        .iterations = iterations,
    });
}
