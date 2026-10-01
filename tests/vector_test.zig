const std = @import("std");
const interval = @import("interval");
const Interval = interval.Interval;

/// The build's choice of how to re-run this binary, named here rather
/// than inside the probe that spawns it, so the import sits with the
/// others. See `runOwnershipProbe`.
const probe_runner_options = @import("probe_runner_options");

/// The result must contain the exact value and must not reach more than
/// one ULP past it on either side. Together the two bounds pin the
/// outward-rounding contract, without hardcoding which of the two
/// neighbouring representable values a given operation lands on.
fn expectTight(i: Interval, exact_lo: f64, exact_hi: f64) !void {
    try std.testing.expect(i.lo <= exact_lo);
    try std.testing.expect(i.hi >= exact_hi);
    try std.testing.expect(i.lo >= interval.prevDown(exact_lo));
    try std.testing.expect(i.hi <= interval.nextUp(exact_hi));
}

/// Every component of a box obeys lo <= hi.
fn expectOrdered(comps: []const Interval) !void {
    for (comps) |i| {
        try std.testing.expect(i.lo <= i.hi);
    }
}

/// The endpoints of a range, its midpoint, and zero when it covers zero.
/// Every extreme of a sum, difference, product, quotient, or square over
/// a range is reached at one of those, so probing them tests an
/// enclosure where it is tightest rather than somewhere it has slack.
fn probes(i: Interval, out: *[4]f64) usize {
    var n: usize = 0;
    out[n] = i.lo;
    n += 1;
    out[n] = i.hi;
    n += 1;
    out[n] = i.midpoint();
    n += 1;
    if (i.contains(0.0)) {
        out[n] = 0.0;
        n += 1;
    }
    return n;
}

/// The scalar constructor, named once: these tests are about the box
/// operations, and the ranges under them are the same handful of
/// literals written out again and again.
const iv = Interval.init;

/// The true square of the distance from a point to a box, over the EXACT
/// values of the per-component `distanceTo` results, taken in `f128`.
///
/// Two `f64` squares and their sum are exact in `f128`, so this is the
/// true square and not an approximation of it, and no `f128` square root
/// is needed to compare against it: squaring is monotone on the
/// non-negative reals, so `got >= sqrt(t)` exactly when `got * got >= t`.
/// The same sum evaluated in `f64` is the very thing under test, which is
/// why the reference is never taken in the type being tested.
fn normSquareOf(ds: []const f64) f128 {
    var t: f128 = 0.0;
    for (ds) |d| {
        const a: f128 = @floatCast(d);
        t += a * a;
    }
    return t;
}

/// The distance `distance` returned is at or above the true one, which
/// is the whole of the contract it makes: it is a bound, not a value.
/// A predicate rather than a test, so the sweep below can ask it four
/// million times without an error union in the loop.
fn normContains(got: f64, ds: []const f64) bool {
    if (!(got >= 0.0)) return false;
    const g: f128 = @floatCast(got);
    return g * g >= normSquareOf(ds);
}

fn expectNormContains(got: f64, ds: []const f64) !void {
    try std.testing.expect(normContains(got, ds));
}

/// The same, with a ceiling, for the cases whose box and point are
/// written out by hand and can therefore afford a real statement about
/// how large the answer is and not only about which side of the truth it
/// falls on: a containment check alone passes a `distance` that returned
/// the infinity metric, or a hundred. The slack is loose on purpose.
/// `distance` widens each square, the running sum and the root, so a
/// correct answer sits a handful of representable steps above the exact
/// one, and a ceiling tight enough to exclude that slack would exclude
/// the repair along with the defect.
fn expectNormBounded(got: f64, ds: []const f64) !void {
    try expectNormContains(got, ds);
    const g: f128 = @floatCast(got);
    try std.testing.expect(g * g <= normSquareOf(ds) * (1.0 + 1e-14));
}

/// A fixed box used by the arithmetic tests: three components with
/// different signs, widths, and magnitudes, so a fold that mixes the
/// axes up cannot pass.
fn sample() interval.Vec(3) {
    return interval.Vec(3).fromArray(.{
        iv(1.0, 3.0),
        iv(-2.0, 4.0),
        iv(10.0, 20.0),
    });
}

fn other() interval.Vec(3) {
    return interval.Vec(3).fromArray(.{
        iv(10.0, 20.0),
        iv(5.0, 7.0),
        iv(2.0, 2.0),
    });
}

/// Three ranges that all clear of zero, so `recip` and division by them
/// are defined rather than a coin toss over the convention chosen for a
/// range that spans zero.
fn invertible() interval.Vec(3) {
    return interval.Vec(3).fromArray(.{
        iv(1.0, 3.0),
        iv(-2.0, -1.0),
        iv(10.0, 20.0),
    });
}

// ---------------------------------------------------------------------------
// The ownership trap in deinit, watched from a child process
// ---------------------------------------------------------------------------
//
// `DynVec.deinit` traps when `comps` names a slice the box never allocated,
// and a trap is an abort. Zig has no in-process panic expectation, so a test
// that made the mistake in this binary would take every other test down with
// it the moment the contract holds, and a test asserting the opposite
// aborts today, for the same reason. `tests/nan_probe.zig` is a separate
// executable for that reason alone; this file may not touch it and may not
// touch the build that wires it, so the child here is THIS BINARY, run
// again with one environment variable set.
//
// The runner takes no argument that selects a single test, so the child runs
// this file from the top, which is why the test below is the FIRST test
// declared in it: the child spends one test before it aborts rather than
// forty. A child that runs further is a child whose expectation failed, and
// it says so by exiting instead of aborting.

/// Set in the child, and only in the child: its value is the part to play.
/// Every child has it, so the spawn cannot recurse.
const probe_var = "ZIG_INTERVAL_DYNVEC_OWNERSHIP_PROBE";

/// The part that replaces the slice, and the part that does not. The second
/// is the control run, and it is what gives the first its meaning: it is the
/// same child, the same import and the same `deinit`, with the mistake left
/// out, so a child that cannot be spawned or dies before it reaches `deinit`
/// fails the control instead of reading as a trap.
const probe_replace = "replace";
const probe_control = "control";

/// The status a child exits with when `deinit` returned instead of aborting.
/// Deliberately not zero, and matched by value: a child that never reached
/// the mistake must not be readable as one that survived it.
const untrapped_status: u8 = 3;

/// The status for a part this probe does not know, which is the same rule
/// `tests/nan_probe.zig` follows with its own usage status: a run that
/// cannot act on its orders has reported nothing, and must not be readable
/// as a run that did.
const usage_status: u8 = 4;

/// What one child run reported, reduced to the facts the contract turns on.
/// An abort and a nonzero status are two different facts and not one: a
/// trap arrives as a signal under POSIX and as an exit code under Windows,
/// and the release-mode child here EXITS with a status on purpose, so a
/// verdict that folded the two together would read that deliberate report
/// as a trap and the trap as a clean run.
const ProbeVerdict = struct {
    /// True when the child was killed rather than exiting with a status of
    /// its own: a signal, a stop, or an end this process cannot read.
    aborted: bool,
    /// The status the child exited with, or null when it never exited.
    code: ?u8,
    /// What the child wrote to its standard error, owned by the caller. The
    /// panic message is in here, and a child process is the only place the
    /// text of the check can be read from.
    output: []u8,
};

/// The probe itself: build a box, hand it a slice it never allocated, free
/// it. With `replace` false it is the same run with the mistake left out.
///
/// The decoy comes from the SAME allocator, on purpose. The defect being
/// pinned is that the box is made to free memory the allocator never handed
/// out, and a decoy from another allocator would replace that with a death
/// inside the allocator: the child would die for a second and different
/// reason, and the parent could no longer tell the check from the free. From
/// one allocator, the release-mode path frees a block that is real, so the
/// exit status there reports the elided check and nothing else.
fn probeDeinit(replace: bool) void {
    const gpa = std.testing.allocator;
    var v = interval.DynVec.init(gpa, 3, iv(1.0, 2.0)) catch @panic("probe: the box was not built");
    const owned = v.comps;
    if (!replace) {
        v.deinit();
        return;
    }
    const decoy = gpa.alloc(Interval, 3) catch @panic("probe: the decoy was not allocated");
    v.comps = decoy;
    v.deinit();
    // Reached only where the check is compiled out, where the box freed the
    // decoy instead and this is the one allocation the run has not returned.
    gpa.free(owned);
}

/// Run one child, playing `part`. A failure to run at all is an error and
/// never a verdict: a process that cannot be spawned has reported nothing
/// about the library, and turning that into "it trapped" would be the
/// vacuous pass.
fn runOwnershipProbe(part: []const u8) !ProbeVerdict {
    const gpa = std.testing.allocator;
    const exe = try std.process.executablePathAlloc(std.testing.io, gpa);
    defer gpa.free(exe);

    // The child gets an environment of its own holding the part and
    // nothing else, rather than a copy of this one. Inheriting would hand
    // it the progress pipe the build runner gave this binary, and a child
    // that wrote to a pipe it does not own would be a child whose verdict
    // said more about the build than about the library.
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put(probe_var, part);

    const runner = probe_runner_options.runner;
    const argv = [_][]const u8{ runner orelse "", exe };
    var child = try std.process.spawn(std.testing.io, .{
        .argv = if (runner == null) argv[1..] else &argv,
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .ignore,
        // stderr is a pipe rather than /dev/null because the panic message
        // is half of what is being pinned: an abort says that something
        // stopped the child, and the message says what, and "reached
        // unreachable code" is a message that names nothing.
        .stderr = .pipe,
    });
    defer child.kill(std.testing.io);

    // The spawn above asked for a pipe on the child's standard error, so
    // there is one to read. A child without it never reached the code
    // under test and cannot report on it, which is a failure of this
    // probe rather than a verdict about the library.
    const stderr = child.stderr orelse return error.StderrPipeMissing;

    // The pipe is read BEFORE the wait, because the wait closes it, and to
    // the end, because the end of the stream is the child's exit. The buffer
    // is far below the capacity of a pipe, so a panic with a long stack
    // trace under it still fits and the child never blocks writing to a
    // reader that has stopped reading.
    var buf: [16384]u8 = undefined;
    var n: usize = 0;
    while (n < buf.len) {
        const got = stderr.readStreaming(std.testing.io, &.{buf[n..]}) catch |err| switch (err) {
            // The end of the stream is the child's exit, and it arrives as
            // an error rather than as a count of zero.
            error.EndOfStream => break,
            else => |e| return e,
        };
        n += got;
    }
    const output = try gpa.dupe(u8, buf[0..n]);

    const term = try child.wait(std.testing.io);
    return switch (term) {
        .exited => |code| .{ .aborted = false, .code = code, .output = output },
        .signal, .stopped, .unknown => .{ .aborted = true, .code = null, .output = output },
    };
}

/// The part this process was started as, or "" when it was not started as
/// one. Empty rather than an error, because the common case is the ordinary
/// run of the suite and a missing variable is not a failure of anything.
fn probePart(gpa: std.mem.Allocator) ![]u8 {
    return std.process.Environ.getAlloc(std.testing.environ, gpa, probe_var) catch |err| switch (err) {
        error.EnvironmentVariableMissing => "",
        else => |e| e,
    };
}

/// The check's own words, as the child wrote them: the line carrying the
/// marker, or nothing at all when the child died without one. A report that
/// printed the first line of the stream instead would be printing the test
/// runner's progress line, since the runner writes to standard error too.
fn probeMessage(v: ProbeVerdict) []const u8 {
    const start = std.mem.indexOf(u8, v.output, "DynVec.deinit:") orelse return "";
    const rest = v.output[start..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len];
}

/// The verdict, one line each.
fn reportProbe(part: []const u8, v: ProbeVerdict) void {
    if (v.code) |code| {
        std.debug.print("    {s: <9} -> exit code {d}\n", .{ part, code });
        return;
    }
    if (probeMessage(v).len == 0) {
        std.debug.print("    {s: <9} -> killed, with no message of its own\n", .{part});
        return;
    }
    std.debug.print("    {s: <9} -> killed: {s}\n", .{ part, probeMessage(v) });
}

test "contract: a comps replaced since construction traps deinit" {
    const gpa = std.testing.allocator;
    const part = try probePart(gpa);
    defer gpa.free(part);
    if (part.len != 0) {
        // The child. It plays its part, and the only way out of here is the
        // exit below, which is the report that nothing trapped. The control
        // reports the opposite and comes back clean, so the two children
        // differ in one bit of status and one line of the probe.
        const replace = if (std.mem.eql(u8, part, probe_replace))
            true
        else if (std.mem.eql(u8, part, probe_control))
            false
        else
            std.process.exit(usage_status);
        probeDeinit(replace);
        std.process.exit(if (replace) untrapped_status else @as(u8, 0));
    }

    // The parent. `std.debug.runtime_safety` is the predicate the check in
    // `deinit` is compiled under, and the build gives this test root and the
    // `interval` module one mode, so the two cannot disagree about it.
    const checked = std.debug.runtime_safety;
    std.debug.print("\n  DynVec.deinit over a replaced comps, observed as a child process:\n", .{});
    const control = try runOwnershipProbe(probe_control);
    const replace = try runOwnershipProbe(probe_replace);
    defer gpa.free(control.output);
    defer gpa.free(replace.output);
    reportProbe("control", control);
    reportProbe("replace", replace);

    // The control first, and it is the control that makes the rest mean
    // something: the same child, the same import, the same deinit, and back
    // again with a clean status and no message from the check.
    try std.testing.expect(!control.aborted);
    try std.testing.expectEqual(@as(?u8, 0), control.code);
    try std.testing.expectEqual(@as(usize, 0), probeMessage(control).len);
    if (checked) {
        // The decoy is a real block of the same allocator, so the free the
        // child goes on to perform is well formed and cannot be what killed
        // it: the abort came from a check in this library, and the only
        // check between the replacement and that free is the one in
        // `src/vector.zig`.
        try std.testing.expect(replace.aborted);
        // And the check names the mistake rather than reporting that two
        // pointers differ, which is what a bare `assert` would leave. The
        // message is the contract, so it is read back rather than assumed.
        try std.testing.expect(std.mem.indexOf(u8, replace.output, "comps was replaced since construction") != null);
    } else {
        // ReleaseFast and ReleaseSmall compile the check out, the trade the
        // ownership note on the type names. So the child is EXPECTED to
        // come back, and to say so with the status it was handed, and an
        // abort here would mean the check outlived an optimization it was
        // not meant to survive.
        try std.testing.expect(!replace.aborted);
        try std.testing.expectEqual(@as(?u8, untrapped_status), replace.code);
    }
}

test "Vec: init fills every component" {
    const v = interval.Vec(3).init(iv(1.0, 2.0));
    try std.testing.expectEqual(@as(usize, 3), v.dim());
    for (v.slice()) |c| {
        try std.testing.expectEqual(@as(f64, 1.0), c.lo);
        try std.testing.expectEqual(@as(f64, 2.0), c.hi);
    }
}

test "Vec: fromArray keeps the components, dim is the comptime count" {
    const v = sample();
    try std.testing.expect(v.get(0).eql(iv(1.0, 3.0)));
    try std.testing.expect(v.get(1).eql(iv(-2.0, 4.0)));
    try std.testing.expect(v.get(2).eql(iv(10.0, 20.0)));
    try std.testing.expectEqual(@as(usize, 3), v.dim());
    try std.testing.expectEqual(@as(usize, 1), interval.Vec(1).init(iv(0.0, 1.0)).dim());
    try std.testing.expectEqual(@as(usize, 7), interval.Vec(7).init(iv(0.0, 1.0)).dim());
}

test "Vec: get and set address one component" {
    var v = interval.Vec(3).init(iv(0.0, 1.0));
    try std.testing.expect(v.get(0).eql(iv(0.0, 1.0)));
    try std.testing.expect(v.get(2).eql(iv(0.0, 1.0)));

    v.set(1, iv(-4.0, 9.0));
    try std.testing.expect(v.get(1).eql(iv(-4.0, 9.0)));
    // The neighbours are untouched by set.
    try std.testing.expect(v.get(0).eql(iv(0.0, 1.0)));
    try std.testing.expect(v.get(2).eql(iv(0.0, 1.0)));
}

test "Vec: eql compares componentwise" {
    try std.testing.expect(sample().eql(sample()));

    // A box differing in exactly one component is not equal.
    var v = sample();
    v.set(2, iv(10.0, 21.0));
    try std.testing.expect(!v.eql(sample()));
    try std.testing.expect(!sample().eql(v));

    // Endpoints are compared, not just containment.
    try std.testing.expect(!interval.Vec(1).init(iv(0.0, 1.0)).eql(interval.Vec(1).init(iv(0.0, 2.0))));
    try std.testing.expect(interval.Vec(1).init(iv(0.0, 1.0)).eql(interval.Vec(1).init(iv(0.0, 1.0))));
}

test "Vec: elementwise add" {
    const r = sample().add(other());
    try expectOrdered(r.slice());
    try expectTight(r.get(0), 11.0, 23.0);
    try expectTight(r.get(1), 3.0, 11.0);
    try expectTight(r.get(2), 12.0, 22.0);
}

test "Vec: elementwise sub" {
    const r = sample().sub(other());
    try expectOrdered(r.slice());
    // The lower bound pairs the smaller lo against the larger hi.
    try expectTight(r.get(0), -19.0, -7.0);
    try expectTight(r.get(1), -9.0, -1.0);
    try expectTight(r.get(2), 8.0, 18.0);
}

test "Vec: elementwise mul" {
    const r = sample().mul(other());
    try expectOrdered(r.slice());
    try expectTight(r.get(0), 10.0, 60.0);
    // -2 * 7 = -14 is the most negative of the four corner products.
    try expectTight(r.get(1), -14.0, 28.0);
    try expectTight(r.get(2), 20.0, 40.0);
}

test "Vec: elementwise div" {
    const r = sample().div(other());
    try expectOrdered(r.slice());
    try expectTight(r.get(0), 0.05, 0.3);
    try expectTight(r.get(1), -0.4, 0.8);
    try expectTight(r.get(2), 5.0, 10.0);
}

test "Vec: neg, abs, sqr are elementwise" {
    const v = interval.Vec(3).fromArray(.{
        iv(1.0, 3.0),
        iv(-2.0, 0.5),
        iv(10.0, 20.0),
    });

    const n = v.neg();
    try expectOrdered(n.slice());
    try expectTight(n.get(0), -3.0, -1.0);
    // Negating [-2, 0.5] gives [-0.5, 2]: the endpoints swap sides.
    try expectTight(n.get(1), -0.5, 2.0);
    try expectTight(n.get(2), -20.0, -10.0);

    const m = v.abs();
    try expectOrdered(m.slice());
    try expectTight(m.get(0), 1.0, 3.0);
    // A range covering zero has its magnitude reach down to exactly 0.
    try expectTight(m.get(1), 0.0, 2.0);
    try expectTight(m.get(2), 10.0, 20.0);

    // Squaring a range that straddles zero must reach down to zero, so
    // it stays an enclosure instead of folding to the two endpoints.
    const s = v.sqr();
    try expectOrdered(s.slice());
    try expectTight(s.get(0), 1.0, 9.0);
    try expectTight(s.get(1), 0.0, 4.0);
    try expectTight(s.get(2), 100.0, 400.0);
}

test "Vec: recip inverts each component" {
    const v = invertible();
    const r = v.recip();
    try expectOrdered(r.slice());
    try expectTight(r.get(0), 1.0 / 3.0, 1.0);
    // A negative range stays negative and its endpoints swap.
    try expectTight(r.get(1), -1.0, -0.5);
    try expectTight(r.get(2), 0.05, 0.1);
}

test "Vec: hull takes the smallest covering box" {
    const a = interval.Vec(3).fromArray(.{
        iv(1.0, 3.0),
        iv(-2.0, 4.0),
        iv(10.0, 20.0),
    });
    const b = interval.Vec(3).fromArray(.{
        iv(2.0, 5.0),
        iv(0.0, 1.0),
        iv(0.0, 12.0),
    });
    const h = a.hull(b);
    try expectOrdered(h.slice());
    try std.testing.expectEqual(@as(f64, 1.0), h.get(0).lo);
    try std.testing.expectEqual(@as(f64, 5.0), h.get(0).hi);
    try std.testing.expectEqual(@as(f64, -2.0), h.get(1).lo);
    try std.testing.expectEqual(@as(f64, 4.0), h.get(1).hi);
    try std.testing.expectEqual(@as(f64, 0.0), h.get(2).lo);
    try std.testing.expectEqual(@as(f64, 20.0), h.get(2).hi);

    // Hull is commutative, and idempotent on the box it was handed.
    try std.testing.expect(h.eql(b.hull(a)));
    try std.testing.expect(a.eql(a.hull(a)));
    try std.testing.expect(a.eql(a.hull(a).hull(a)));
}

test "Vec: a slice stays valid while its box is alive" {
    // A slice into a by-value copy of the box would point at a stack
    // frame that later calls reuse, so the interleaved calls below would
    // read clobbered memory. The receiver is a pointer precisely so this
    // cannot happen.
    const v = sample();
    const seen = v.slice();

    var scratch: [4]f64 = undefined;
    for (0..4) |k| scratch[k] = @sqrt(@as(f64, @floatFromInt(k)) + 1.0);
    try std.testing.expectEqual(@as(f64, 1.0), scratch[0]);
    _ = v.neg().add(v);
    _ = v.distance(.{ 1.0, 1.0, 1.0 });

    for (0..3) |i| {
        try std.testing.expectEqual(v.get(i).lo, seen[i].lo);
        try std.testing.expectEqual(v.get(i).hi, seen[i].hi);
        try std.testing.expect(seen[i].eql(v.get(i)));
    }
}

test "DynVec: a slice stays valid while its box is alive" {
    const gpa = std.testing.allocator;
    var v = try interval.DynVec.fromArray(gpa, sample().slice());
    defer v.deinit();
    const seen = v.slice();

    var pad = try interval.DynVec.init(gpa, 3, iv(100.0, 200.0));
    defer pad.deinit();
    try pad.iadd(v);
    v.set(0, iv(-7.0, -6.0));

    // The slice is the box's own memory, so it follows the write.
    try std.testing.expectEqual(@as(f64, -7.0), seen[0].lo);
    for (1..3) |i| {
        try std.testing.expect(seen[i].eql(sample().get(i)));
    }
}

test "Vec: intersect shares a box when every component overlaps" {
    const a = interval.Vec(3).init(iv(0.0, 2.0));
    const b = interval.Vec(3).fromArray(.{
        iv(1.0, 3.0),
        iv(2.0, 4.0),
        iv(0.5, 1.5),
    });
    const x = a.intersect(b) orelse return error.ExpectedOverlap;
    try expectOrdered(x.slice());
    try std.testing.expectEqual(@as(f64, 1.0), x.get(0).lo);
    try std.testing.expectEqual(@as(f64, 2.0), x.get(0).hi);
    // Components that only touch at an endpoint still share that point.
    try std.testing.expectEqual(@as(f64, 2.0), x.get(1).lo);
    try std.testing.expectEqual(@as(f64, 2.0), x.get(1).hi);
    try std.testing.expectEqual(@as(f64, 0.5), x.get(2).lo);
    try std.testing.expectEqual(@as(f64, 1.5), x.get(2).hi);
}

test "Vec: intersect is null when exactly one component is disjoint" {
    const a = interval.Vec(3).init(iv(0.0, 1.0));
    // Only the last component misses, so the boxes share a point along
    // axes 0 and 1 and still have no point in common along axis 2.
    const b = interval.Vec(3).fromArray(.{
        iv(0.5, 2.0),
        iv(0.5, 2.0),
        iv(5.0, 6.0),
    });
    try std.testing.expect(a.intersect(b) == null);
    try std.testing.expect(b.intersect(a) == null);
    // The two matching components really do overlap, so the null comes
    // from the third alone and not from a wholesale mismatch.
    try std.testing.expect(a.get(0).overlaps(b.get(0)));
    try std.testing.expect(a.get(1).overlaps(b.get(1)));
    try std.testing.expect(!a.get(2).overlaps(b.get(2)));
    try std.testing.expect(!a.overlaps(b));

    // Moving the gap to the first component gives the same answer.
    const c = interval.Vec(3).fromArray(.{
        iv(5.0, 6.0),
        iv(0.5, 2.0),
        iv(0.5, 2.0),
    });
    try std.testing.expect(a.intersect(c) == null);
}

test "Vec: overlaps needs every component" {
    const a = interval.Vec(3).init(iv(0.0, 1.0));
    try std.testing.expect(a.overlaps(interval.Vec(3).init(iv(0.5, 2.0))));
    // Touching at a single point is an overlap.
    try std.testing.expect(a.overlaps(interval.Vec(3).init(iv(1.0, 2.0))));
    try std.testing.expect(a.overlaps(a));

    var b = a;
    b.set(1, iv(9.0, 10.0));
    try std.testing.expect(!a.overlaps(b));
    try std.testing.expect(!b.overlaps(a));
}

test "Vec: subsetOf needs every component inside" {
    const outer = interval.Vec(3).init(iv(0.0, 10.0));
    const inner = interval.Vec(3).fromArray(.{
        iv(1.0, 2.0),
        iv(3.0, 4.0),
        iv(5.0, 6.0),
    });
    try std.testing.expect(inner.subsetOf(outer));
    try std.testing.expect(outer.subsetOf(outer));
    try std.testing.expect(!outer.subsetOf(inner));

    // One component sticking out is enough to fail.
    var poking = inner;
    poking.set(2, iv(5.0, 11.0));
    try std.testing.expect(!poking.subsetOf(outer));
    try std.testing.expect(!poking.subsetOf(inner));

    // So is one component reaching below the box.
    var low = inner;
    low.set(0, iv(-0.5, 2.0));
    try std.testing.expect(!low.subsetOf(outer));
}

test "Vec: contains is endpoint-inclusive and rejects a point outside" {
    const v = interval.Vec(3).init(iv(0.0, 1.0));
    try std.testing.expect(v.contains(.{ 0.5, 0.5, 0.5 }));
    // On a face, and on a corner: the faces are part of the box.
    try std.testing.expect(v.contains(.{ 0.0, 0.5, 0.5 }));
    try std.testing.expect(v.contains(.{ 1.0, 0.5, 0.5 }));
    try std.testing.expect(v.contains(.{ 0.5, 0.0, 0.5 }));
    try std.testing.expect(v.contains(.{ 0.5, 0.5, 1.0 }));
    try std.testing.expect(v.contains(.{ 0.0, 0.0, 0.0 }));
    try std.testing.expect(v.contains(.{ 1.0, 1.0, 1.0 }));

    // Outside on one axis alone is enough to miss the box.
    try std.testing.expect(!v.contains(.{ 1.5, 0.5, 0.5 }));
    try std.testing.expect(!v.contains(.{ 0.5, -0.5, 0.5 }));
    try std.testing.expect(!v.contains(.{ 0.5, 0.5, 2.0 }));
    try std.testing.expect(!v.contains(.{ -1.0, -1.0, -1.0 }));
}

test "Vec: distance is zero at the centre of a 1-dimensional box" {
    const v = interval.Vec(1).init(iv(0.0, 1.0));
    try std.testing.expectEqual(@as(f64, 0.0), v.distance(.{0.5}));
    // Anywhere in the box is zero distance, faces included. The
    // widening in `distance` must not move a zero: the promise that the
    // distance is zero EXACTLY for a point in the box is stated in
    // terms of this value, and these are the assertions that keep it.
    try std.testing.expectEqual(@as(f64, 0.0), v.distance(.{0.0}));
    try std.testing.expectEqual(@as(f64, 0.0), v.distance(.{1.0}));
    // Outside it is the distance to the nearest face. The distances are
    // exactly 2.5 and exactly 1.5, and `distance` encloses its
    // accumulation rather than rounding it once at the end, so both
    // answers come back a step or two above those. What is asserted is
    // the bound, against the true value; the round-to-nearest f64 is
    // what the defect returned.
    try expectNormBounded(v.distance(.{3.5}), &.{2.5});
    // The point sits 1.5 below the lower face at 0.0.
    try expectNormBounded(v.distance(.{-1.5}), &.{1.5});
}

test "Vec: distance is the Euclidean norm, not the max metric" {
    const v = interval.Vec(2).init(iv(0.0, 1.0));
    // Each component is 3.0 away, so the max metric would say 3.0 and
    // the Euclidean one says the hypotenuse. The components and the
    // ceiling are what is asserted; the exact 3 * sqrt(2) is not,
    // because `distance` returns a bound and a test that pins the
    // round-to-nearest value pins the rounding the library promises not
    // to rely on.
    const d = v.distance(.{ 4.0, 4.0 });
    try std.testing.expect(d > 3.0);
    try expectNormBounded(d, &.{ 3.0, 3.0 });

    // A single axis off by 4 leaves the distance at 4 under both
    // metrics, which is the degenerate case the norm agrees on.
    try expectNormBounded(v.distance(.{ 5.0, 0.5 }), &.{4.0});
    // Two axes off by 6 and 8 give the 3-4-5 hypotenuse.
    try expectNormBounded(v.distance(.{ 7.0, 9.0 }), &.{ 6.0, 8.0 });
    try std.testing.expectEqual(@as(f64, 0.0), v.distance(.{ 0.5, 0.5 }));
}

test "Vec: isEmpty is false for a well-formed box" {
    try std.testing.expect(!sample().isEmpty());
    try std.testing.expect(!interval.Vec(0).init(iv(0.0, 1.0)).isEmpty());
    // A degenerate box is one point, not no points.
    try std.testing.expect(!interval.Vec(1).init(iv(2.0, 2.0)).isEmpty());
}

test "Vec: isEmpty reports the one box fromArray can build" {
    // `fromArray` takes the components as given and checks nothing, so
    // an inverted component enters the box here, and a box with one
    // holds no point at all: it is empty. The component is written as
    // a literal rather than through `I` because `Interval.init` traps
    // on an inverted pair, which is the check this constructor skips.
    const inverted: Interval = .{ .lo = 2.0, .hi = 1.0 };
    const empty = interval.Vec(3).fromArray(.{
        iv(1.0, 2.0),
        inverted,
        iv(-1.0, 1.0),
    });
    try std.testing.expect(empty.isEmpty());
    // An empty box holds no point, so the membership predicates agree
    // with it and not only with `isEmpty`.
    try std.testing.expect(!empty.contains(.{ 1.5, 1.5, 0.0 }));
    try std.testing.expect(!empty.overlaps(empty));

    // Ordering that one component and nothing else takes the box out
    // of the empty state, so this is not a predicate that refuses
    // everything it is handed.
    var whole = interval.Vec(3).fromArray(.{
        iv(1.0, 2.0),
        iv(1.0, 2.0),
        iv(-1.0, 1.0),
    });
    try std.testing.expect(!whole.isEmpty());
    whole.set(1, inverted);
    try std.testing.expect(whole.isEmpty());

    // A degenerate component is one point, not no points, and a box
    // with no components at all holds the one point of the empty
    // space.
    try std.testing.expect(!interval.Vec(1).init(iv(2.0, 2.0)).isEmpty());
    try std.testing.expect(!interval.Vec(0).init(iv(0.0, 1.0)).isEmpty());
}

test "Vec: a dimension-zero box holds the one point of the empty space" {
    const v = interval.Vec(0).init(iv(0.0, 1.0));
    try std.testing.expectEqual(@as(usize, 0), v.dim());
    try std.testing.expect(v.contains(.{}));
    try std.testing.expectEqual(@as(f64, 0.0), v.distance(.{}));
    try std.testing.expect(v.overlaps(interval.Vec(0).init(iv(5.0, 6.0))));
    try std.testing.expect(v.intersect(interval.Vec(0).init(iv(5.0, 6.0))) != null);
}

test "Vec: a value-returning operation leaves the operands alone" {
    const a = sample();
    const b = other();
    const a_copy = sample();
    const b_copy = other();
    _ = a.add(b);
    _ = a.sub(b);
    _ = a.mul(b);
    _ = a.div(b);
    _ = a.hull(b);
    _ = a.neg();
    _ = a.abs();
    _ = a.sqr();
    _ = invertible().recip();
    try std.testing.expect(a.eql(a_copy));
    try std.testing.expect(b.eql(b_copy));
}

test "Vec: every probed point pair lands inside the arithmetic result" {
    const lx = interval.Vec(3).fromArray(.{
        iv(1.0, 3.0),
        iv(-2.0, 4.0),
        iv(10.0, 20.0),
    });
    const ly = interval.Vec(3).fromArray(.{
        iv(30.0, 50.0),
        iv(-40.0, -10.0),
        iv(2.0, 4.0),
    });

    const sum = lx.add(ly);
    const dif = lx.sub(ly);
    const pro = lx.mul(ly);
    const quo = lx.div(ly);
    const squ = lx.sqr();
    try expectOrdered(sum.slice());
    try expectOrdered(dif.slice());
    try expectOrdered(pro.slice());
    try expectOrdered(quo.slice());
    try expectOrdered(squ.slice());

    var px: [4]f64 = undefined;
    var py: [4]f64 = undefined;
    for (0..3) |i| {
        // Every divisor avoids zero, so the quotient probes are real.
        try std.testing.expect(ly.get(i).lo > 0.0 or ly.get(i).hi < 0.0);
        const nx = probes(lx.get(i), &px);
        const ny = probes(ly.get(i), &py);
        for (px[0..nx]) |p| {
            for (py[0..ny]) |q| {
                try std.testing.expect(sum.get(i).contains(p + q));
                try std.testing.expect(dif.get(i).contains(p - q));
                try std.testing.expect(pro.get(i).contains(p * q));
                try std.testing.expect(quo.get(i).contains(p / q));
                try std.testing.expect(squ.get(i).contains(p * p));
            }
        }
    }
}

test "DynVec: init sets the runtime length and deinit releases it" {
    const gpa = std.testing.allocator;
    var v = try interval.DynVec.init(gpa, 3, iv(1.0, 2.0));
    defer v.deinit();
    try std.testing.expectEqual(@as(usize, 3), v.dim());
    for (v.slice()) |c| {
        try std.testing.expect(c.eql(iv(1.0, 2.0)));
    }

    var w = try interval.DynVec.init(gpa, 1, iv(0.0, 1.0));
    defer w.deinit();
    try std.testing.expectEqual(@as(usize, 1), w.dim());
    try std.testing.expect(w.dim() != v.dim());

    var e = try interval.DynVec.init(gpa, 0, iv(0.0, 1.0));
    defer e.deinit();
    try std.testing.expectEqual(@as(usize, 0), e.dim());
}

test "DynVec: deinit is safe to call twice on one box" {
    const gpa = std.testing.allocator;
    var v = try interval.DynVec.init(gpa, 3, iv(1.0, 2.0));
    v.deinit();
    // Before, this second call freed the slice the first one had
    // replaced with `undefined`, and the binary died inside
    // `Allocator.free` on the way in. The allocation is released
    // exactly once either way, which is what the testing allocator
    // checks at the end of the run.
    v.deinit();

    // What a deinited box holds is an empty component slice, and that
    // is the state the second call read and the third call reads.
    try std.testing.expectEqual(@as(usize, 0), v.dim());
    try std.testing.expectEqual(@as(usize, 0), v.slice().len);
    try std.testing.expect(!v.isEmpty());
    // The recorded address is what carries the second and third call past
    // the check in `deinit`: the empty slice still sits where the owned
    // slice was, so the record and the slice agree at every call, and a
    // record compared against nothing would fire here instead.
    try std.testing.expect(v.own == v.comps.ptr);
    v.deinit();
}

test "contract: every constructor records the address deinit checks" {
    // The record is the whole of the check, so a constructor that forgot it
    // would make every `deinit` of its own box abort, on a box no caller
    // had touched and no other statement in this file would notice. The
    // record is the address, not the length: two boxes of the same width
    // hold different addresses, and a check on the length would pass for
    // both of them.
    const gpa = std.testing.allocator;

    var filled = try interval.DynVec.init(gpa, 3, iv(1.0, 2.0));
    defer filled.deinit();
    try std.testing.expect(filled.own == filled.comps.ptr);

    var copied = try interval.DynVec.fromArray(gpa, sample().slice());
    defer copied.deinit();
    try std.testing.expect(copied.own == copied.comps.ptr);

    // The value-returning operations allocate their own box, so their
    // constructor is the one behind `add` rather than a public one.
    var sum = try filled.add(copied);
    defer sum.deinit();
    try std.testing.expect(sum.own == sum.comps.ptr);

    var twin = try interval.DynVec.init(gpa, 3, iv(3.0, 4.0));
    defer twin.deinit();
    try std.testing.expectEqual(sum.dim(), twin.dim());
    try std.testing.expect(twin.own != sum.own);
}

test "DynVec: a returned box belongs to whoever holds it last" {
    // The convention the type cannot enforce: freeing a COPY is a
    // double free, because the copy names the same slice, so the old
    // box goes before the assignment that would drop it on the floor.
    // The testing allocator reports an allocation that was never
    // freed, so a step that loses a box fails here rather than
    // passing quietly.
    const gpa = std.testing.allocator;
    var acc = try interval.DynVec.fromArray(gpa, sample().slice());
    var want = sample();
    for (0..3) |_| {
        var o = try interval.DynVec.fromArray(gpa, other().slice());
        defer o.deinit();
        const next = try acc.add(o);
        acc.deinit();
        acc = next;
        want = want.add(other());
    }
    defer acc.deinit();

    try expectOrdered(acc.slice());
    for (0..3) |i| {
        try std.testing.expect(acc.get(i).eql(want.get(i)));
    }
}

test "DynVec: fromArray copies, so the caller keeps its own array" {
    const gpa = std.testing.allocator;
    var src = [_]Interval{ iv(1.0, 2.0), iv(3.0, 4.0) };
    var v = try interval.DynVec.fromArray(gpa, &src);
    defer v.deinit();
    try std.testing.expectEqual(@as(usize, 2), v.dim());
    try std.testing.expect(v.get(1).eql(iv(3.0, 4.0)));
    src[0] = iv(9.0, 9.0);
    try std.testing.expect(v.get(0).eql(iv(1.0, 2.0)));
}

test "DynVec: get, set, and eql behave as on the fixed box" {
    const gpa = std.testing.allocator;
    var v = try interval.DynVec.init(gpa, 3, iv(0.0, 1.0));
    defer v.deinit();
    v.set(1, iv(-1.0, 7.0));
    try std.testing.expect(v.get(1).eql(iv(-1.0, 7.0)));
    try std.testing.expect(v.get(0).eql(iv(0.0, 1.0)));
    try std.testing.expect(v.get(2).eql(iv(0.0, 1.0)));

    var w = try interval.DynVec.fromArray(gpa, v.slice());
    defer w.deinit();
    try std.testing.expect(v.eql(w));
    w.set(2, iv(0.0, 2.0));
    try std.testing.expect(!v.eql(w));
    try std.testing.expect(!w.eql(v));
}

test "DynVec: value-returning arithmetic matches the fixed box" {
    const gpa = std.testing.allocator;
    const sa = sample();
    const sb = other();
    var a = try interval.DynVec.fromArray(gpa, sa.slice());
    defer a.deinit();
    var b = try interval.DynVec.fromArray(gpa, sb.slice());
    defer b.deinit();

    var adds = try a.add(b);
    defer adds.deinit();
    try expectOrdered(adds.slice());
    for (0..3) |i| {
        try std.testing.expect(adds.get(i).eql(sa.get(i).add(sb.get(i))));
    }

    var subs = try a.sub(b);
    defer subs.deinit();
    for (0..3) |i| {
        try std.testing.expect(subs.get(i).eql(sa.get(i).sub(sb.get(i))));
    }

    var muls = try a.mul(b);
    defer muls.deinit();
    for (0..3) |i| {
        try std.testing.expect(muls.get(i).eql(sa.get(i).mul(sb.get(i))));
    }

    var divs = try a.div(b);
    defer divs.deinit();
    for (0..3) |i| {
        try std.testing.expect(divs.get(i).eql(sa.get(i).div(sb.get(i))));
    }

    var h = try a.hull(b);
    defer h.deinit();
    const want = sa.hull(sb);
    for (0..3) |i| {
        try std.testing.expect(h.get(i).eql(want.get(i)));
    }
    try std.testing.expectEqual(@as(usize, 3), h.dim());
}

test "DynVec: a value-returning operation leaves the operands alone" {
    const gpa = std.testing.allocator;
    var a = try interval.DynVec.fromArray(gpa, sample().slice());
    defer a.deinit();
    var b = try interval.DynVec.fromArray(gpa, other().slice());
    defer b.deinit();
    var a_copy = try interval.DynVec.fromArray(gpa, a.slice());
    defer a_copy.deinit();

    var r = try a.add(b);
    defer r.deinit();
    try std.testing.expect(a.eql(a_copy));
    try std.testing.expect(!r.eql(a));
}

test "DynVec: mismatched widths are rejected" {
    const gpa = std.testing.allocator;
    var a = try interval.DynVec.init(gpa, 2, iv(0.0, 1.0));
    defer a.deinit();
    var b = try interval.DynVec.init(gpa, 3, iv(0.0, 1.0));
    defer b.deinit();

    try std.testing.expectError(error.DimensionMismatch, a.add(b));
    try std.testing.expectError(error.DimensionMismatch, a.sub(b));
    try std.testing.expectError(error.DimensionMismatch, a.mul(b));
    try std.testing.expectError(error.DimensionMismatch, a.div(b));
    try std.testing.expectError(error.DimensionMismatch, a.hull(b));
    try std.testing.expectError(error.DimensionMismatch, a.intersect(b));
    try std.testing.expectError(error.DimensionMismatch, a.iadd(b));
    try std.testing.expectError(error.DimensionMismatch, a.isub(b));
    try std.testing.expectError(error.DimensionMismatch, a.imul(b));
    try std.testing.expectError(error.DimensionMismatch, a.idiv(b));

    // Widths that disagree are not comparable at all, so the
    // predicates say false rather than trap. a is exactly the
    // two-component prefix of b, so a walk over the components that
    // ignored the widths would call the two boxes equal, in both
    // directions.
    try std.testing.expect(!a.overlaps(b));
    try std.testing.expect(!a.subsetOf(b));
    try std.testing.expect(a.overlaps(a));
    try std.testing.expect(a.subsetOf(a));
    try std.testing.expect(!a.eql(b));
    try std.testing.expect(!b.eql(a));
    try std.testing.expect(a.eql(a));

    // Equal widths still fall through to the components, so the check
    // is not just refusing every comparison.
    var c = try interval.DynVec.init(gpa, 2, iv(0.0, 2.0));
    defer c.deinit();
    try std.testing.expect(!a.eql(c));
    try std.testing.expect(!c.eql(a));
    try std.testing.expect(c.eql(c));
    // A separate box of the same width and the same components is
    // equal, so the width check is not all the comparison does.
    var twin = try interval.DynVec.fromArray(gpa, a.slice());
    defer twin.deinit();
    try std.testing.expect(a.eql(twin));
    try std.testing.expect(twin.eql(a));
}

test "DynVec: iadd overwrites the receiver, add does not" {
    const gpa = std.testing.allocator;
    var a = try interval.DynVec.fromArray(gpa, sample().slice());
    defer a.deinit();
    var b = try interval.DynVec.fromArray(gpa, other().slice());
    defer b.deinit();

    var before = try a.add(b);
    defer before.deinit();
    try a.iadd(b);
    try std.testing.expect(a.eql(before));
    // iadd is not a no-op: the receiver really moved.
    const moved = sample();
    var differs = false;
    for (0..3) |i| {
        if (!a.get(i).eql(moved.get(i))) differs = true;
    }
    try std.testing.expect(differs);
}

test "DynVec: neg, abs, sqr, recip are in place" {
    const gpa = std.testing.allocator;
    const src = interval.Vec(3).fromArray(.{
        iv(1.0, 3.0),
        iv(-2.0, 0.5),
        iv(10.0, 20.0),
    });
    var v = try interval.DynVec.fromArray(gpa, src.slice());
    defer v.deinit();

    v.neg();
    try expectOrdered(v.slice());
    for (0..3) |i| {
        try std.testing.expect(v.get(i).eql(src.neg().get(i)));
    }

    v.neg();
    v.abs();
    try expectOrdered(v.slice());
    for (0..3) |i| {
        try std.testing.expect(v.get(i).eql(src.abs().get(i)));
    }

    var s = try interval.DynVec.fromArray(gpa, src.slice());
    defer s.deinit();
    s.sqr();
    try expectOrdered(s.slice());
    for (0..3) |i| {
        try std.testing.expect(s.get(i).eql(src.sqr().get(i)));
    }

    const inv = invertible();
    var r = try interval.DynVec.fromArray(gpa, inv.slice());
    defer r.deinit();
    r.recip();
    try expectOrdered(r.slice());
    for (0..3) |i| {
        try std.testing.expect(r.get(i).eql(inv.recip().get(i)));
    }
}

test "DynVec: intersect is null when exactly one component is disjoint" {
    const gpa = std.testing.allocator;
    var a = try interval.DynVec.init(gpa, 3, iv(0.0, 1.0));
    defer a.deinit();
    var b = try interval.DynVec.init(gpa, 3, iv(0.5, 2.0));
    defer b.deinit();
    b.set(2, iv(5.0, 6.0));

    try std.testing.expect((try a.intersect(b)) == null);
    try std.testing.expect((try b.intersect(a)) == null);
    // Exactly one component misses, and the other two overlap.
    try std.testing.expect(a.get(0).overlaps(b.get(0)));
    try std.testing.expect(a.get(1).overlaps(b.get(1)));
    try std.testing.expect(!a.get(2).overlaps(b.get(2)));
    try std.testing.expect(!a.overlaps(b));

    b.set(2, iv(0.5, 0.75));
    var x = (try a.intersect(b)) orelse return error.ExpectedOverlap;
    defer x.deinit();
    try expectOrdered(x.slice());
    for (0..3) |i| {
        const axis = a.get(i).intersect(b.get(i)) orelse return error.ExpectedOverlap;
        try std.testing.expect(x.get(i).eql(axis));
    }
}

test "DynVec: hull, overlaps, and subsetOf match the fixed box" {
    const gpa = std.testing.allocator;
    var outer = try interval.DynVec.init(gpa, 3, iv(0.0, 10.0));
    defer outer.deinit();
    var inner = try interval.DynVec.fromArray(gpa, &[_]Interval{ iv(1.0, 2.0), iv(3.0, 4.0), iv(5.0, 6.0) });
    defer inner.deinit();

    var h = try outer.hull(inner);
    defer h.deinit();
    try std.testing.expectEqual(@as(f64, 0.0), h.get(0).lo);
    try std.testing.expectEqual(@as(f64, 10.0), h.get(0).hi);
    try std.testing.expectEqual(@as(usize, 3), h.dim());

    try std.testing.expect(inner.subsetOf(outer));
    try std.testing.expect(!outer.subsetOf(inner));

    inner.set(2, iv(5.0, 11.0));
    try std.testing.expect(!inner.subsetOf(outer));
    inner.set(2, iv(5.0, 6.0));
    try std.testing.expect(inner.overlaps(outer));

    var far = try interval.DynVec.init(gpa, 3, iv(20.0, 21.0));
    defer far.deinit();
    try std.testing.expect(!inner.overlaps(far));
    try std.testing.expect((try inner.intersect(far)) == null);
}

test "DynVec: contains and distance match the fixed box" {
    const gpa = std.testing.allocator;
    var v = try interval.DynVec.fromArray(gpa, &[_]Interval{ iv(0.0, 1.0), iv(0.0, 1.0), iv(0.0, 1.0) });
    defer v.deinit();
    const fv = interval.Vec(3).init(iv(0.0, 1.0));
    const p = [_]f64{ 0.5, 0.5, 0.5 };
    // Both representations measure the same box with the same metric.
    try std.testing.expectEqual(fv.distance(p), v.distance(&p));

    try std.testing.expect(v.contains(&.{ 0.5, 0.5, 0.5 }));
    try std.testing.expect(v.contains(&.{ 0.0, 1.0, 0.5 }));
    try std.testing.expect(!v.contains(&.{ 0.5, 0.5, 1.5 }));
    try std.testing.expectEqual(@as(f64, 0.0), v.distance(&.{ 0.5, 0.5, 0.5 }));
    try expectNormBounded(v.distance(&.{ 4.0, 4.0, 4.0 }), &.{ 3.0, 3.0, 3.0 });
    try std.testing.expect(!v.isEmpty());
}

test "DynVec: isEmpty sees the same components as the fixed box" {
    const gpa = std.testing.allocator;
    const inverted: Interval = .{ .lo = 2.0, .hi = 1.0 };
    var v = try interval.DynVec.fromArray(gpa, &[_]Interval{ iv(0.0, 1.0), inverted });
    defer v.deinit();
    try std.testing.expect(v.isEmpty());
    try std.testing.expect(interval.Vec(2).fromArray(.{ iv(0.0, 1.0), inverted }).isEmpty());

    // The one component ordered, and the box is no longer empty in
    // either representation.
    v.set(1, iv(0.0, 1.0));
    try std.testing.expect(!v.isEmpty());
    try std.testing.expect(!interval.Vec(2).init(iv(0.0, 1.0)).isEmpty());
}

test "DynVec: contains is false for a point of the wrong length" {
    const gpa = std.testing.allocator;
    var v = try interval.DynVec.fromArray(gpa, &[_]Interval{ iv(0.0, 1.0), iv(0.0, 1.0), iv(0.0, 1.0) });
    defer v.deinit();

    // Every coordinate given below lies inside the matching component,
    // so a comparison that stopped at the length of the point would
    // call all of them contained. These pin the length check itself,
    // not the arithmetic behind it.
    try std.testing.expect(!v.contains(&.{ 0.5, 0.5 }));
    try std.testing.expect(!v.contains(&.{ 0.5, 0.5, 0.5, 0.5 }));
    try std.testing.expect(!v.contains(&.{ 1.0, 1.0, 1.0, 9.0 }));
    try std.testing.expect(!v.contains(&.{}));

    // A matching length answers the question it always did, so the
    // check is not simply refusing every point.
    try std.testing.expect(v.contains(&.{ 0.5, 0.5, 0.5 }));
    try std.testing.expect(!v.contains(&.{ 0.5, 0.5, 1.5 }));

    // Dimension zero is the one width the empty point matches.
    var e = try interval.DynVec.init(gpa, 0, iv(0.0, 1.0));
    defer e.deinit();
    try std.testing.expect(e.contains(&.{}));
    try std.testing.expect(!e.contains(&.{0.5}));
}

test "DynVec: distance to a point of the wrong length is +infinity" {
    const gpa = std.testing.allocator;
    const inf: f64 = std.math.inf(f64);
    var v = try interval.DynVec.fromArray(gpa, &[_]Interval{ iv(0.0, 1.0), iv(0.0, 1.0), iv(0.0, 1.0) });
    defer v.deinit();

    // A point of another dimension is in no box of this width, and
    // contains has already said it is not in this one, so the distance
    // is not zero. It is read no further than the point goes, so the
    // result is +infinity rather than a norm over a partial pair.
    try std.testing.expectEqual(inf, v.distance(&.{ 0.5, 0.5 }));
    try std.testing.expectEqual(inf, v.distance(&.{ 0.5, 0.5, 0.5, 0.5 }));
    try std.testing.expectEqual(inf, v.distance(&.{ 1.0, 1.0, 1.0, 9.0 }));
    try std.testing.expectEqual(inf, v.distance(&.{9.0}));
    try std.testing.expectEqual(inf, v.distance(&.{}));

    // A matching length is measured exactly as before.
    try std.testing.expectEqual(@as(f64, 0.0), v.distance(&.{ 0.5, 0.5, 0.5 }));
    try expectNormBounded(v.distance(&.{ 4.0, 4.0, 4.0 }), &.{ 3.0, 3.0, 3.0 });
}

/// Doubles an interval. Doubling is domain-total, so the mapped box
/// always exists.
fn double(i: Interval) ?Interval {
    return i.add(i);
}

/// Undefined on a range that reaches below zero, the shape a square
/// root has. Used to drive the null path of `mapResult` without
/// depending on which elementary functions the library ships.
fn nonNegativeSqrt(i: Interval) ?Interval {
    if (i.hi < 0.0) return null;
    return iv(@sqrt(@max(i.lo, 0.0)), @sqrt(i.hi));
}

test "mapResult: applies a function to every component" {
    const v = sample();
    const d = interval.mapResult(v, double) orelse return error.ExpectedMappedBox;
    try expectOrdered(d.slice());
    for (0..3) |i| {
        try expectTight(d.get(i), 2.0 * v.get(i).lo, 2.0 * v.get(i).hi);
    }
    // The result is a box of the same shape, not a list of intervals.
    try std.testing.expectEqual(@as(usize, 3), d.dim());
    try std.testing.expect(interval.Vec(3) == @TypeOf(d));
}

test "mapResult: a component off the domain makes the whole box null" {
    var v = interval.Vec(3).fromArray(.{
        iv(1.0, 4.0),
        iv(9.0, 16.0),
        iv(-4.0, -1.0),
    });
    // Only the last component leaves the domain, and it is the last one
    // reached, so the fold has already filled two results.
    try std.testing.expect(interval.mapResult(v, nonNegativeSqrt) == null);

    // The same function over a box whose components are all in domain
    // succeeds, and a component touching zero clamps rather than going
    // NaN.
    v.set(2, iv(-0.25, 4.0));
    const s = interval.mapResult(v, nonNegativeSqrt) orelse return error.ExpectedMappedBox;
    try expectOrdered(s.slice());
    for (0..3) |i| {
        try std.testing.expect(s.get(i).contains(@sqrt(@max(v.get(i).lo, 0.0))));
        try std.testing.expect(s.get(i).contains(@sqrt(v.get(i).hi)));
    }
}

test "mapResult: the DynVec case allocates and deinits cleanly" {
    const gpa = std.testing.allocator;
    var v = try interval.DynVec.fromArray(gpa, sample().slice());
    defer v.deinit();

    var d = (try interval.mapResult(v, double)) orelse return error.ExpectedMappedBox;
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 3), d.dim());
    try expectOrdered(d.slice());
    for (0..3) |i| {
        try expectTight(d.get(i), 2.0 * v.get(i).lo, 2.0 * v.get(i).hi);
    }
    // The result owns a separate allocation, so freeing it leaves the
    // source box intact.
    try std.testing.expect(v.get(0).eql(sample().get(0)));

    var s = (try interval.mapResult(v, nonNegativeSqrt)) orelse return error.ExpectedMappedBox;
    defer s.deinit();
    try expectOrdered(s.slice());
    for (0..3) |i| {
        try std.testing.expect(s.get(i).contains(@sqrt(@max(v.get(i).lo, 0.0))));
    }
}

test "mapResult: the DynVec case returns null and frees the partial box" {
    const gpa = std.testing.allocator;
    var v = try interval.DynVec.fromArray(gpa, sample().slice());
    defer v.deinit();
    // The last component is the one that leaves the domain, so the fold
    // has already written two results before it gives up. The testing
    // allocator would report the leftover as a leak.
    v.set(2, iv(-4.0, -1.0));
    try std.testing.expect((try interval.mapResult(v, nonNegativeSqrt)) == null);
    try std.testing.expect(v.get(1).eql(iv(-2.0, 4.0)));
}

test "mapResult: a zero-component box maps to itself" {
    const v = interval.Vec(0).init(iv(0.0, 1.0));
    const d = interval.mapResult(v, double) orelse return error.ExpectedMappedBox;
    try std.testing.expectEqual(@as(usize, 0), d.dim());
    // No component can leave the domain, so the result cannot be null.
    try std.testing.expect(interval.Vec(0) == @TypeOf(d));
}

test "mapResult: the receivers are left alone" {
    const gpa = std.testing.allocator;
    var v = try interval.DynVec.fromArray(gpa, sample().slice());
    defer v.deinit();
    var before = try interval.DynVec.fromArray(gpa, v.slice());
    defer before.deinit();

    var d = (try interval.mapResult(v, double)) orelse return error.ExpectedMappedBox;
    defer d.deinit();
    try std.testing.expect(v.eql(before));

    const fv = sample();
    const fd = interval.mapResult(fv, double) orelse return error.ExpectedMappedBox;
    try std.testing.expect(fv.eql(sample()));
    try expectOrdered(fd.slice());
}

test "mapResult: a fixed box returns a plain optional, not an error union" {
    const v = interval.Vec(2).fromArray(.{
        iv(1.0, 3.0),
        iv(-2.0, 4.0),
    });
    // The annotation is the assertion. Before the split this arm was
    // `error{OutOfMemory}!?Vec(2)`, because the error set of a `!?V`
    // return is collected from every `try` in the body, including the
    // one in the `DynVec` branch that cannot run on this
    // instantiation, so this line did not compile:
    //     expected optional type, found `error{OutOfMemory}!?Vec(2)`
    // and every caller had to wrap the call in a `try` for an error
    // the operation cannot produce.
    const d: ?interval.Vec(2) = interval.mapResult(v, double);
    const got = d orelse return error.ExpectedMappedBox;
    try std.testing.expectEqual(@as(usize, 2), got.dim());
    try expectTight(got.get(0), 2.0, 6.0);
    try expectTight(got.get(1), -4.0, 8.0);

    // The optional is the DOMAIN report, not the failure report, so it
    // is still reachable, and one component below zero is enough.
    const straddling = interval.Vec(2).fromArray(.{
        iv(-4.0, -1.0),
        iv(1.0, 4.0),
    });
    try std.testing.expect(interval.mapResult(straddling, nonNegativeSqrt) == null);
    try std.testing.expect(interval.mapResult(v, nonNegativeSqrt) != null);
}

test "mapResult: the owned box still reports the failure it can have" {
    const gpa = std.testing.allocator;
    var v = try interval.DynVec.fromArray(gpa, sample().slice());
    defer v.deinit();

    var d = (try interval.mapResult(v, double)) orelse return error.ExpectedMappedBox;
    defer d.deinit();
    for (0..3) |i| {
        try std.testing.expect(d.get(i).eql(v.get(i).add(v.get(i))));
    }

    // Splitting the error set away from the stack arm took nothing out
    // of this one: a `DynVec` allocates before it folds, so the
    // allocation failing is still an `error.OutOfMemory` out of the
    // call, and the box it would have allocated is not left behind.
    // The first allocation succeeds and is the box above; the second
    // is the one `mapResult` makes.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 1 });
    var tight = try interval.DynVec.init(failing.allocator(), 3, iv(1.0, 2.0));
    defer tight.deinit();
    try std.testing.expectError(error.OutOfMemory, interval.mapResult(tight, double));
    try std.testing.expect(tight.get(1).eql(iv(1.0, 2.0)));
}

test "mapResult: the receiver is a box by value, and a pointer is a compile error" {
    // There is no runtime assertion for the pointer case here because
    // there is no runtime case: the call below does not compile.
    //
    //     interval.mapResult(&v, double)
    //     error: mapResult takes a box by value: pass the box, not a
    //            pointer to it.
    //
    // It compiled, and then segfaulted, before the check existed. A
    // pointer is not `DynVec`, so the fold took the stack arm, which
    // declared `var out: V = undefined` with V a POINTER and handed
    // that uninitialised pointer to `mapOpt` as the output slice: the
    // fault was in `mapOpt` at src/vector.zig:102, in Debug and in
    // ReleaseFast alike, before any assertion could have said
    // anything about it.
    var v = interval.Vec(2).fromArray(.{
        iv(1.0, 3.0),
        iv(-2.0, 4.0),
    });
    const doubled: ?interval.Vec(2) = interval.mapResult(v, double);
    for (0..2) |i| {
        try std.testing.expect(doubled.?.get(i).eql(v.get(i).add(v.get(i))));
    }

    // The fold reads the receiver and writes only its own box, so
    // what a caller reaching for a pointer wanted is already what the
    // by-value call gives.
    try std.testing.expect(v.get(0).eql(iv(1.0, 3.0)));
    try std.testing.expect(v.get(1).eql(iv(-2.0, 4.0)));
}

test "invariant: every component of every arithmetic result obeys lo <= hi" {
    const boxes = [_]interval.Vec(3){
        sample(),
        interval.Vec(3).init(iv(-1.0, 1.0)),
        interval.Vec(3).fromArray(.{
            iv(-std.math.floatMax(f64), std.math.floatMax(f64)),
            iv(0.0, 0.0),
            iv(1e300, 1e300),
        }),
        interval.Vec(3).init(iv(-std.math.inf(f64), std.math.inf(f64))),
    };
    // Every component of every divisor stays clear of zero.
    const divisors = [_]interval.Vec(3){
        other(),
        interval.Vec(3).init(iv(-4.0, -1.0)),
    };

    for (boxes) |a| {
        for (divisors) |b| {
            try expectOrdered(a.add(b).slice());
            try expectOrdered(a.sub(b).slice());
            try expectOrdered(a.mul(b).slice());
            try expectOrdered(a.div(b).slice());
            try expectOrdered(a.hull(b).slice());
        }
        try expectOrdered(a.neg().slice());
        try expectOrdered(a.abs().slice());
        try expectOrdered(a.sqr().slice());
        try expectOrdered(a.slice());
    }

    // Inverting a range that spans zero is undefined, so recip runs
    // over ranges that stay on one side of it.
    const inv = invertible();
    try expectOrdered(inv.recip().slice());
    const extremes = [_]interval.Vec(3){
        interval.Vec(3).init(iv(-std.math.floatMax(f64), -1.0)),
        interval.Vec(3).init(iv(1.0, std.math.floatMax(f64))),
        interval.Vec(3).init(iv(1e-300, 1e300)),
    };
    for (boxes) |a| {
        try expectOrdered(inv.recip().add(a).slice());
    }
    for (extremes) |e| {
        try expectOrdered(e.recip().slice());
    }
}

test "invariant: the owned representation holds the same order" {
    const gpa = std.testing.allocator;
    const boxes = [_]interval.Vec(3){
        sample(),
        interval.Vec(3).init(iv(-1.0, 1.0)),
        interval.Vec(3).fromArray(.{
            iv(-std.math.floatMax(f64), std.math.floatMax(f64)),
            iv(0.0, 0.0),
            iv(1e300, 1e300),
        }),
        interval.Vec(3).init(iv(-std.math.inf(f64), std.math.inf(f64))),
    };
    const divisors = [_]interval.Vec(3){
        other(),
        interval.Vec(3).init(iv(-4.0, -1.0)),
    };

    for (boxes) |a| {
        for (divisors) |b| {
            var x = try interval.DynVec.fromArray(gpa, a.slice());
            defer x.deinit();
            var y = try interval.DynVec.fromArray(gpa, b.slice());
            defer y.deinit();

            var sum = try x.add(y);
            defer sum.deinit();
            try expectOrdered(sum.slice());
            var dif = try x.sub(y);
            defer dif.deinit();
            try expectOrdered(dif.slice());
            var pro = try x.mul(y);
            defer pro.deinit();
            try expectOrdered(pro.slice());
            var quo = try x.div(y);
            defer quo.deinit();
            try expectOrdered(quo.slice());
            var hul = try x.hull(y);
            defer hul.deinit();
            try expectOrdered(hul.slice());

            try x.iadd(y);
            try expectOrdered(x.slice());
            try x.isub(y);
            try expectOrdered(x.slice());
            try x.imul(y);
            try expectOrdered(x.slice());
            try x.idiv(y);
            try expectOrdered(x.slice());
            x.neg();
            try expectOrdered(x.slice());
            x.abs();
            try expectOrdered(x.slice());
            x.sqr();
            try expectOrdered(x.slice());
        }

        var solo = try interval.DynVec.fromArray(gpa, a.slice());
        defer solo.deinit();
        solo.neg();
        try expectOrdered(solo.slice());
        solo.abs();
        try expectOrdered(solo.slice());
        solo.sqr();
        try expectOrdered(solo.slice());
    }

    var r = try interval.DynVec.fromArray(gpa, invertible().slice());
    defer r.deinit();
    r.recip();
    try expectOrdered(r.slice());
}

// ---------------------------------------------------------------------------
// The distance oracle
// ---------------------------------------------------------------------------

/// The positive infinity, for the answers that are unbounded but real.
const inf64: f64 = std.math.inf(f64);
const neg_inf64: f64 = -std.math.inf(f64);

/// The smallest positive subnormal f64, bit pattern 1. The square of a
/// distance this small is a positive real the format cannot hold, which
/// is the one regime where an outward step on the square is not enough
/// on its own.
const min_subnormal: f64 = @bitCast(@as(u64, 1));

/// 10^e, evaluated in `f64` because the operand is an `f64` and the
/// exact power is not what a test operand has to be.
fn pow10(e: i32) f64 {
    return std.math.pow(f64, 10.0, @as(f64, @floatFromInt(e)));
}

/// A magnitude with a random sign, so that a box and a point drawn
/// from the same class land on opposite sides of each other about half
/// the time. Negating a zero is deliberately not reachable here: the
/// sign of a zero is a bit, not a choice, and `exact_zero` covers it.
fn signed(magnitude: f64, r: std.Random) f64 {
    return if (r.boolean()) magnitude else -magnitude;
}

/// A magnitude class for one drawn box endpoint or point coordinate.
///
/// The spread is the point of the sweep. A defect worth half a ULP at
/// each of the squares, the running sum and the root only shows itself
/// where the numbers have no spare bits, and the subnormal classes are
/// exactly that: the difference of two subnormals is a subnormal, and
/// the square of a subnormal is a positive real the `f64` format cannot
/// hold at all.
const NormClass = enum {
    /// Ordinary magnitudes: the regime a rounding defect hides in, and
    /// where it hides best.
    ordinary,
    /// 1e-323 to 1e-290, subnormal and barely normal together.
    tiny,
    /// A raw subnormal bit pattern, so two draws of this class are a
    /// fixed distance apart in ULPs rather than in orders of magnitude.
    subnormal,
    /// 1e285 to 1e307, where the square of a distance is close to
    /// overflowing the format and the root comes back from an infinity.
    huge,
    /// Both signed zeros, the one answer the widening must not move.
    exact_zero,
    /// The one representable value below every subnormal.
    min_subnormal,
    /// The largest finite value, whose square overflows.
    float_max,

    fn draw(self: NormClass, r: std.Random) f64 {
        return switch (self) {
            .ordinary => r.float(f64) * 2000.0 - 1000.0,
            .tiny => pow10(r.intRangeAtMost(i32, -323, -290)) * (1.0 + r.float(f64) * 9.0),
            .subnormal => signed(@as(f64, @bitCast(r.intRangeAtMost(u64, 1, 0x000f_ffff_ffff_ffff))), r),
            .huge => pow10(r.intRangeAtMost(i32, 285, 307)) * (1.0 + r.float(f64) * 0.7),
            .exact_zero => if (r.boolean()) 0.0 else -0.0,
            .min_subnormal => min_subnormal,
            .float_max => signed(std.math.floatMax(f64), r),
        };
    }
};

/// The class table, weighted towards the ordinary so the sweep stays a
/// general test rather than an exotic-only one, and towards the tiny
/// and the subnormal because that is where a missing outward step has
/// nowhere left to hide.
const norm_classes = [_]NormClass{
    .ordinary,
    .ordinary,
    .ordinary,
    .ordinary,
    .ordinary,
    .ordinary,
    .tiny,
    .tiny,
    .tiny,
    .subnormal,
    .subnormal,
    .subnormal,
    .subnormal,
    .huge,
    .huge,
    .huge,
    .exact_zero,
    .min_subnormal,
    .float_max,
};

/// One box component. Sorted, degenerate on a fraction of the cases, and
/// unbounded on one side on a fraction of the rest: a box with an
/// infinite face is a box the norm still has to answer, and it is not a
/// special case there either.
fn drawNormComponent(m: NormClass, r: std.Random) Interval {
    const x = m.draw(r);
    const y = if (r.intRangeAtMost(u8, 0, 7) == 0) x else m.draw(r);
    const lo = @min(x, y);
    const hi = @max(x, y);
    if (r.intRangeAtMost(u8, 0, 15) != 0) return iv(lo, hi);
    // Substituting the infinities and sorting after, so one cannot land
    // on the wrong end of the range and trip the constructor's ordering
    // assertion, which aborts the binary rather than failing this case.
    const a = if (r.boolean()) neg_inf64 else lo;
    const b = if (r.boolean()) inf64 else hi;
    return iv(@min(a, b), @max(a, b));
}

/// One point coordinate. A fraction of them sit outside the end of the
/// range, where the true distance is an infinity; the answer there has
/// to be an infinity and not the NaN that a zero times an infinity
/// would hand the accumulation.
fn drawNormCoordinate(m: NormClass, r: std.Random) f64 {
    if (r.intRangeAtMost(u8, 0, 63) == 0) return if (r.boolean()) inf64 else neg_inf64;
    return m.draw(r);
}

/// One drawn case: a 2-dimensional box and a point of matching width.
fn drawNormCase(r: std.Random) struct { box: interval.Vec(2), p: [2]f64 } {
    const mb = norm_classes[r.uintLessThan(usize, norm_classes.len)];
    // Half the cases pair the box against an independently drawn class.
    // The mixed-magnitude regime is where a difference lands between
    // two exponents that were never near each other, and a sweep that
    // drew both from one class would reach it only by luck.
    const mp = if (r.boolean()) norm_classes[r.uintLessThan(usize, norm_classes.len)] else mb;
    return .{
        .box = interval.Vec(2).fromArray(.{ drawNormComponent(mb, r), drawNormComponent(mb, r) }),
        .p = .{ drawNormCoordinate(mp, r), drawNormCoordinate(mp, r) },
    };
}

/// Seed for the sweep. Fixed, so a failure reproduces exactly and a
/// pass means something; `std.Random.DefaultPrng` rather than the
/// system source, which would make the sweep meaningless.
const norm_seed: u64 = 0x0BAD_C0DE_FACE_BEEF;

/// Cases in the sweep. The step this file is about is worth half a ULP
/// at each of the squares, the running sum and the root, so a sweep of
/// a few thousand finds nothing at all and reports a clean bill of
/// health on a function that is wrong. Four million is what it took to
/// turn the failure from an argument into a count.
const norm_cases: usize = 4_000_000;

/// How many individual failures the sweep prints in full. The count is
/// always reported exactly; this bounds the detail only.
const norm_max_detail: usize = 8;

test "Vec: distance is never below the true Euclidean distance" {
    var prng = std.Random.DefaultPrng.init(norm_seed);
    const r = prng.random();

    var failures: usize = 0;
    for (0..norm_cases) |n| {
        const c = drawNormCase(r);
        const ds = [2]f64{
            c.box.get(0).distanceTo(c.p[0]),
            c.box.get(1).distanceTo(c.p[1]),
        };
        const got = c.box.distance(c.p);
        // normContains is the claim in one line: the true distance is
        // sqrt(d0*d0 + d1*d1) over the EXACT values of the two
        // distanceTo results, and the answer has to be at or above it.
        if (normContains(got, &ds)) continue;
        failures += 1;
        if (failures <= norm_max_detail) {
            std.debug.print(
                "  case {d}: box [{e}, {e}] x [{e}, {e}], point ({e}, {e})," ++
                    " distances {e} and {e}, returned {e}\n",
                .{
                    n,
                    c.box.get(0).lo,
                    c.box.get(0).hi,
                    c.box.get(1).lo,
                    c.box.get(1).hi,
                    c.p[0],
                    c.p[1],
                    ds[0],
                    ds[1],
                    got,
                },
            );
        }
    }
    std.debug.print(
        "normDistance containment: {d} of {d} 2-D cases below the true distance\n",
        .{ failures, norm_cases },
    );
    try std.testing.expectEqual(@as(usize, 0), failures);
}
