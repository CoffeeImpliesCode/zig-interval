//! The README's own examples, compiled and run.
//!
//! The repository's tests are handed the `interval` module object directly,
//! so nothing in them can tell whether the code a reader copies out of
//! `README.md` still compiles. Two examples did not, and no gate in the tree
//! could see it: the headline Fourier-Motzkin block passed
//! `Interval.init(1, -1)`, an inverted interval, which trips the `lo <= hi`
//! assertion in `init`; and the build-wiring snippet left `target` and
//! `optimize` off the module it created, which panics in the build script
//! with "the root Module of a Compile step must be created with a known
//! 'target' field". Both are fixed in the README. This file is what stops the
//! next one from being invisible.
//!
//! Every example below is the README's block, transcribed line for line
//! between a `--- README` and an `--- end README` marker, with the assertions
//! for it appended. Where a block cannot be transcribed literally, the file
//! says what it did instead, at the point where it happened:
//!
//!   * the `build.zig.zon` stanza is manifest data rather than Zig, so there
//!     is no expression in it to evaluate. What it exists to produce is the
//!     pair of names — the dependency key and the module name — and those are
//!     the pair this binary was compiled with, which is the reason it runs
//!     at all; so it carries no check of its own;
//!   * the `build.zig` snippet is a build script and cannot be a `main`, so
//!     it is checked by naming every declaration and every field it writes
//!     down, at comptime. A rename upstream fails this file's build rather
//!     than the reader's;
//!   * the `mapResult` signature block is a declaration rather than a
//!     statement, so it is checked the same way;
//!   * two blocks name locals the README leaves to the reader — the two
//!     bounds in "Widening your own arithmetic", and `gpa`, `n`, `fill` and
//!     `others` in "`iadd` versus `add" — and they are bound above each
//!     block, with a note on why those values;
//!   * five blocks take an added line, and each one says what it added and
//!     why: the Fourier-Motzkin and `isUnsat` blocks cannot have their
//!     printed values asserted without one (the first frees its box with a
//!     `defer`, the second prints the same getter twice with a mutation in
//!     between); the `isEmpty` block's three lines discard a `bool`, which
//!     Zig rejects, so each is an assertion in place of the discarded call;
//!     the `intersect` block is given the loop header the README leaves
//!     to the prose above it; and the `add` block captures each box the
//!     assignment below it drops, which is what lets that demonstration be
//!     undone. Nothing else in those blocks differs.
//! No check here leaves the heap dirty. The one that demonstrates a leak
//! does so with an allocator that COUNTS blocks, and hands every block it
//! took back before it returns, so the run is clean and a leak in the
//! library is still a red line rather than expected noise.
//!
//! The closing line is `readme examples ok: N checks`, in the shape of the
//! consumer's own, and it is the whole of what the parent `consumer` step
//! watches here. Every check asserts a claim the README itself makes. The
//! ones about arithmetic assert CONTAINMENT plus a width bound and never
//! equality: an enclosure is allowed to be a hair outside the corner it
//! bounds, and pinning the exact bits would pin the implementation rather
//! than the contract.

const std = @import("std");
const interval = @import("interval");

const Interval = interval.Interval;
const DynVec = interval.DynVec;

/// Raised when the library answers one of these examples differently from the
/// way the README says it answers. Returning it from main exits non-zero,
/// which fails the parent `consumer` step.
pub const CheckError = error{UnexpectedReadmeAnswer};

/// Number of checks below; the closing line reports this.
const total_checks = 31;

/// How far outside the exact corner a bound may sit, as a fraction of that
/// corner's magnitude. Widening composes about one step per operation and the
/// Fourier-Motzkin example composes a handful, so the honest figure is a few
/// ULP; this is six orders of magnitude above that, which fails a bound that
/// has lost a row or a pair, and leaves a step or two of tightening or
/// widening free.
const corner_slack: f64 = 1e-9;

// ---------------------------------------------------------------------------
// Assertions.
// ---------------------------------------------------------------------------

/// Compare a produced interval against the exact one, loudly on mismatch.
/// This is the right assertion for a set operation, which does no arithmetic
/// and so needs no widening.
fn expectInterval(what: []const u8, got: Interval, want: Interval) CheckError!void {
    if (got.lo != want.lo or got.hi != want.hi) {
        std.debug.print(
            "FAIL {s}: got [{d}, {d}], want [{d}, {d}]\n",
            .{ what, got.lo, got.hi, want.lo, want.hi },
        );
        return CheckError.UnexpectedReadmeAnswer;
    }
    std.debug.print("ok {s}: [{d}, {d}]\n", .{ what, got.lo, got.hi });
}

/// Compare a produced scalar against the exact one. Only right where no
/// rounding happened, which is what the two uses here are: the width of a set
/// operation, and the midpoint of one.
fn expectFloat(what: []const u8, got: f64, want: f64) CheckError!void {
    if (got != want) {
        std.debug.print("FAIL {s}: got {d}, want {d}\n", .{ what, got, want });
        return CheckError.UnexpectedReadmeAnswer;
    }
    std.debug.print("ok {s}: {d}\n", .{ what, got });
}

/// Compare a count against the one the claim names. For the claims that
/// are about how many blocks an allocator handed out, which is not a thing
/// an interval comparison can decide.
fn expectCount(what: []const u8, got: usize, want: usize) CheckError!void {
    if (got != want) {
        std.debug.print("FAIL {s}: got {d}, want {d}\n", .{ what, got, want });
        return CheckError.UnexpectedReadmeAnswer;
    }
    std.debug.print("ok {s}: {d} == {d}\n", .{ what, got, want });
}

fn expectBool(what: []const u8, got: bool, want: bool) CheckError!void {
    if (got != want) {
        std.debug.print("FAIL {s}: got {}, want {}\n", .{ what, got, want });
        return CheckError.UnexpectedReadmeAnswer;
    }
    std.debug.print("ok {s}: {}\n", .{ what, got });
}

/// Assert a `null` result, the library's signal for an answer that is empty
/// in the reals rather than unbounded.
fn expectNullInterval(what: []const u8, got: ?Interval) CheckError!void {
    if (got) |g| {
        std.debug.print(
            "FAIL {s}: got [{d}, {d}], want null\n",
            .{ what, g.lo, g.hi },
        );
        return CheckError.UnexpectedReadmeAnswer;
    }
    std.debug.print("ok {s}: null\n", .{what});
}

/// Assert the library's promise on an interval the README names exact
/// corners for: `got` CONTAINS the real interval [exact_lo, exact_hi], and is
/// not much wider than it.
///
/// Containment is the contract and is the half that can fail silently, so it
/// is checked on both ends. The width bound is here so that a result which
/// has overshot — a lost row, a pair that never fired, a sign read backwards
/// — does not pass merely by being bigger. Equality is neither expected nor
/// wanted: every arithmetic endpoint is widened outward by a step, and
/// demanding the exact bits would demand an implementation this fixture is
/// meant to be independent of.
fn expectEncloses(
    what: []const u8,
    got: Interval,
    exact_lo: f64,
    exact_hi: f64,
) CheckError!void {
    if (got.lo > exact_lo or got.hi < exact_hi) {
        std.debug.print(
            "FAIL {s}: [{d}, {d}] does not enclose [{d}, {d}]\n",
            .{ what, got.lo, got.hi, exact_lo, exact_hi },
        );
        return CheckError.UnexpectedReadmeAnswer;
    }
    const over_lo = exact_lo - got.lo;
    const over_hi = got.hi - exact_hi;
    if (over_lo > corner_slack * (@abs(exact_lo) + 1.0) or
        over_hi > corner_slack * (@abs(exact_hi) + 1.0))
    {
        std.debug.print(
            "FAIL {s}: [{d}, {d}] is far wider than [{d}, {d}]\n",
            .{ what, got.lo, got.hi, exact_lo, exact_hi },
        );
        return CheckError.UnexpectedReadmeAnswer;
    }
    std.debug.print(
        "ok {s}: [{d}, {d}] encloses [{d}, {d}]\n",
        .{ what, got.lo, got.hi, exact_lo, exact_hi },
    );
}

/// Assert one printed endpoint against the corner the README names for it.
/// The same claim `expectEncloses` makes, on one end: the printed bound
/// contains the exact value and sits close to it.
fn expectEndpoint(what: []const u8, got: f64, exact: f64) CheckError!void {
    if (got < exact) {
        std.debug.print(
            "FAIL {s}: {d} does not enclose {d}\n",
            .{ what, got, exact },
        );
        return CheckError.UnexpectedReadmeAnswer;
    }
    if (got - exact > corner_slack * (@abs(exact) + 1.0)) {
        std.debug.print(
            "FAIL {s}: {d} is far wider than {d}\n",
            .{ what, got, exact },
        );
        return CheckError.UnexpectedReadmeAnswer;
    }
    std.debug.print("ok {s}: {d} encloses {d}\n", .{ what, got, exact });
}

/// Check a whole box in one shot: the dimension, then every component. One
/// box is one claim, so it reports on one line.
fn expectVecExact(what: []const u8, got: anytype, want: []const Interval) CheckError!void {
    if (got.dim() != want.len) {
        std.debug.print(
            "FAIL {s}: dim {d}, want {d}\n",
            .{ what, got.dim(), want.len },
        );
        return CheckError.UnexpectedReadmeAnswer;
    }
    for (want, 0..) |w, i| {
        const g = got.get(i);
        if (g.lo != w.lo or g.hi != w.hi) {
            std.debug.print(
                "FAIL {s}: component {d} is [{d}, {d}], want [{d}, {d}]\n",
                .{ what, i, g.lo, g.hi, w.lo, w.hi },
            );
            return CheckError.UnexpectedReadmeAnswer;
        }
    }
    std.debug.print("ok {s}: {d} components exact\n", .{ what, want.len });
}

/// Same, but each component only has to CONTAIN the exact real interval,
/// which is the right assertion for a widened arithmetic result.
fn expectVecEncloses(what: []const u8, got: anytype, want: []const Interval) CheckError!void {
    if (got.dim() != want.len) {
        std.debug.print(
            "FAIL {s}: dim {d}, want {d}\n",
            .{ what, got.dim(), want.len },
        );
        return CheckError.UnexpectedReadmeAnswer;
    }
    for (want, 0..) |w, i| {
        const g = got.get(i);
        if (g.lo > w.lo or g.hi < w.hi) {
            std.debug.print(
                "FAIL {s}: component {d} is [{d}, {d}], does not enclose [{d}, {d}]\n",
                .{ what, i, g.lo, g.hi, w.lo, w.hi },
            );
            return CheckError.UnexpectedReadmeAnswer;
        }
    }
    std.debug.print("ok {s}: {d} components enclose\n", .{ what, want.len });
}

// ---------------------------------------------------------------------------
// The examples.
// ---------------------------------------------------------------------------

/// The README's "Widening your own arithmetic". The block leaves
/// `my_lower_bound` and `my_upper_bound` to the reader — they are the
/// reader's own arithmetic — so they are bound here, one division each, so
/// that neither is exactly representable and both have to be rounded
/// outward.
fn readmeWidenYourOwnArithmetic() CheckError!void {
    // The README names these two without defining them. `1/3` and `2/3` are
    // chosen because neither is a double: at these magnitudes the nearest
    // double to each lies BELOW it, so a round-to-nearest value passed
    // straight through as a bound would be a bound that excludes the true
    // value. That is precisely the mistake `roundDown` and `roundUp` are
    // exported to prevent.
    const my_lower_bound: f64 = 1.0 / 3.0;
    const my_upper_bound: f64 = 2.0 / 3.0;

    // --- README, "Widening your own arithmetic" ---
    const iv = interval.Interval.init(
        interval.roundDown(my_lower_bound),
        interval.roundUp(my_upper_bound),
    );
    // --- end README ---

    // The lower corner is claimed as `my_lower_bound` and the upper as the
    // next double above `my_upper_bound`. Neither is the exact real 1/3 or
    // 2/3, and both are on the safe side of it: the claimed lower bound is
    // below the real 1/3, so containment of it implies containment of the
    // real one, and the claimed upper bound is above the real 2/3, so a
    // result that reaches it has passed the real one.
    try expectEncloses(
        "readme-widen-own-arithmetic",
        iv,
        my_lower_bound,
        interval.nextUp(my_upper_bound),
    );

    // And the claim the pair of helpers exists to make: the upper bound is
    // strictly outside the round-to-nearest answer. Had the block passed
    // `my_upper_bound` itself, the result would have been a number, it would
    // have looked like a bound, and it would have been wrong.
    try expectBool("readme-widen-own-stepped", iv.hi > my_upper_bound, true);
}

/// The four values the README's "Usage" example prints, named as the line
/// prints them so the assertions below read as the claims they check.
const Usage = struct {
    width: f64,
    midpoint: f64,
    total_hi: f64,
    rooted_hi: f64,
};

/// The README's "Usage". The body is the README's own `main`, with the
/// `pub fn main` line replaced by this function's own and the closing brace
/// followed by the return.
fn readmeUsage() CheckError!void {
    // --- README, "Usage" ---
    const a = Interval.init(1.0, 3.0);
    const b = Interval.init(2.0, 5.0);

    const shared = a.intersect(b).?; // [2, 3]
    const span = a.hull(b); // [1, 5]
    const total = a.add(b); // an enclosure of [3, 8]

    // Elementary functions are free functions, and may be null.
    const rooted = interval.sqrt(Interval.init(4.0, 9.0)).?; // brackets [2, 3]

    std.debug.print("{d} {d} {d} {d}\n", .{
        shared.width(), span.midpoint(), total.hi, rooted.hi,
    });
    // --- end README ---

    // The four numbers that line printed, handed back so the OUTPUT can be
    // asserted rather than watched go by. They are the ones the README makes
    // its two kinds of claim about: `shared` and `span` come out of set
    // operations, which take endpoints as they find them, so the width and
    // the midpoint below are exact; `total` and `rooted` are arithmetic, so
    // the two upper bounds below are enclosures of the named corners.
    const printed = Usage{
        .width = shared.width(),
        .midpoint = span.midpoint(),
        .total_hi = total.hi,
        .rooted_hi = rooted.hi,
    };

    try expectFloat("readme-usage-width", printed.width, 1.0);
    try expectFloat("readme-usage-midpoint", printed.midpoint, 3.0);
    try expectEndpoint("readme-usage-total-hi", printed.total_hi, 8.0);
    try expectEndpoint("readme-usage-rooted-hi", printed.rooted_hi, 3.0);
}

/// The README's `build.zig` snippet, which cannot be a `main` because it is
/// a build script. What can be checked from a Zig source file is every name
/// it writes down: each declaration it calls and each field it passes, with
/// the types, so a rename upstream or a field that changes shape fails this
/// build rather than the reader's.
///
/// The one thing that cannot be checked here is the panic the README's prose
/// warns about, which fires inside `Step.Compile.create` while a build script
/// RUNS and has no comptime expression to fail. What this does catch is the
/// cause: `target` and `optimize` are fields of `Module.CreateOptions` and
/// the arguments of `standardTargetOptions` and `standardOptimizeOption`
/// have the types the snippet assumes, so the two lines that were dropped
/// when the snippet was written are named here.
fn readmeBuildWiring() void {
    comptime {
        const CompileOptions = std.Build.Step.Compile.Options;
        const CreateOptions = std.Build.Module.CreateOptions;

        // b.standardTargetOptions(.{}) / b.standardOptimizeOption(.{}): the
        // pair the snippet takes once and passes to both the module and the
        // dependency.
        std.debug.assert(
            @TypeOf(std.Build.standardTargetOptions) ==
                fn (*std.Build, std.Build.StandardTargetOptionsArgs) std.Build.ResolvedTarget,
        );
        std.debug.assert(
            @TypeOf(std.Build.standardOptimizeOption) ==
                fn (*std.Build, std.Build.StandardOptimizeOptionOptions) std.builtin.OptimizeMode,
        );

        // b.addExecutable(.{ .name, .root_module }): the two fields the
        // snippet passes, and the type it reaches through the second.
        std.debug.assert(@hasField(CompileOptions, "name"));
        std.debug.assert(@hasField(CompileOptions, "root_module"));
        std.debug.assert(
            @FieldType(CompileOptions, "root_module") == *std.Build.Module,
        );

        // b.createModule(.{ .root_source_file, .target, .optimize }): the
        // three fields, with the types the snippet's three arguments have.
        // `target` and `optimize` are the pair whose absence panics.
        std.debug.assert(@hasField(CreateOptions, "root_source_file"));
        std.debug.assert(@hasField(CreateOptions, "target"));
        std.debug.assert(@hasField(CreateOptions, "optimize"));
        std.debug.assert(
            @FieldType(CreateOptions, "root_source_file") == ?std.Build.LazyPath,
        );
        std.debug.assert(
            @FieldType(CreateOptions, "target") == ?std.Build.ResolvedTarget,
        );
        std.debug.assert(
            @FieldType(CreateOptions, "optimize") == ?std.builtin.OptimizeMode,
        );
        std.debug.assert(
            @TypeOf(std.Build.path) == fn (*std.Build, []const u8) std.Build.LazyPath,
        );

        // exe.root_module.addImport("interval", dep.module("interval")):
        // the field, and the two functions either side of it. The module
        // `addImport` is handed is the pointer `Dependency.module` returns.
        std.debug.assert(
            @TypeOf(std.Build.Dependency.module) ==
                fn (*std.Build.Dependency, []const u8) *std.Build.Module,
        );
        std.debug.assert(
            @TypeOf(std.Build.Module.addImport) ==
                fn (*std.Build.Module, []const u8, *std.Build.Module) void,
        );

        // b.installArtifact(exe).
        std.debug.assert(@hasDecl(std.Build, "installArtifact"));
    }
    std.debug.print("ok readme-build-wiring: every name the snippet writes down resolves\n", .{});
}

/// The README's "Empty, `null`, and unbounded": the two answers that are
/// easy to conflate, and must not be.
fn readmeEmptyAndUnbounded() CheckError!void {
    // --- README, "Empty, `null`, and unbounded" ---
    // Unbounded: a real answer, just not a finite one.
    const q = Interval.init(1.0, 2.0).div(Interval.init(-1.0, 1.0)); // [-inf, inf]

    // Empty: no real answer at all.
    const r = interval.sqrt(Interval.init(-4.0, -1.0)); // null
    // --- end README ---

    try expectInterval(
        "readme-unbounded",
        q,
        Interval.init(-std.math.inf(f64), std.math.inf(f64)),
    );
    try expectNullInterval("readme-empty", r);
}

/// The README's `Vec(n)` versus `DynVec` example. The whole block is
/// transcribed, including its `defer`: the README writes it as a fragment
/// whose two locals are picked up by the `mapResult` example further down, so
/// the `mapResult` example below builds its own two and says why.
fn readmeVectorForms() !void {
    // --- README, "Use `Vec(n)` when the dimension is a constant" ---
    // Compile-time dimension.
    const box = interval.Vec(3).fromArray(.{
        Interval.init(0.0, 1.0),
        Interval.init(0.0, 10.0),
        Interval.init(0.0, 10.0),
    });

    // Runtime dimension, with an allocator.
    var dyn = try interval.DynVec.init(std.heap.page_allocator, 3, Interval.init(0.0, 1.0));
    defer dyn.deinit();
    // --- end README ---

    // `fromArray` takes the components as they are given, so the fixed box is
    // those three intervals, exactly. `init` sets every component of the
    // runtime box to the fill, so that one is three copies of the same
    // interval.
    try expectVecExact("readme-vec3-fromArray", box, &.{
        Interval.init(0.0, 1.0),
        Interval.init(0.0, 10.0),
        Interval.init(0.0, 10.0),
    });
    try expectVecExact("readme-dynvec-init", dyn, &.{
        Interval.init(0.0, 1.0),
        Interval.init(0.0, 1.0),
        Interval.init(0.0, 1.0),
    });
}

/// Counts the blocks a child allocator hands out and takes back, and keeps
/// the high-water mark, so an ownership claim can be DECIDED here rather
/// than merely witnessed.
///
/// `std.heap` has no `CountingAllocator` in Zig 0.16 — the name did not
/// survive the allocator rewrite — so this is the whole of it: four vtable
/// entries, of which two count.
///
/// Only `alloc` and `free` move the count, because only those two create or
/// destroy a block. `resize` and `remap` change the size of a block that
/// already exists and are passed straight down to the child. And
/// `Allocator.free` returns before reaching the vtable on an empty slice,
/// so the `DynVec.deinit` idempotence the README documents cannot move the
/// count either.
const Counting = struct {
    child: std.mem.Allocator,
    vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    },

    /// Blocks handed out and not yet handed back.
    outstanding: usize = 0,
    /// The most `outstanding` has ever been, and the number a claim about
    /// how many boxes a caller owns is decided on.
    peak: usize = 0,

    /// The allocator to hand the library in place of the child's.
    fn count(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &self.vtable };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const mem = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.outstanding += 1;
        if (self.outstanding > self.peak) self.peak = self.outstanding;
        return mem;
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.outstanding -= 1;
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

/// The README's "`iadd` versus `add`: who owns the box".
///
/// The section's claim is a claim about ownership, and the only thing in a
/// Zig source file that can decide one is an allocator that knows what it
/// is holding. So `Counting` is wrapped UNDER a `DebugAllocator` and the
/// claim is decided on its high-water mark: the first loop's dropped boxes
/// are captured, the count is asserted while all of them are still
/// outstanding, and every one of them is freed before the run returns. The
/// demonstration is a demonstration, and the leak checker below it has
/// nothing to report.
///
/// `.safety = true` is written down rather than left to the default, which
/// follows `runtime_safety`: the parent builds the fixture in ReleaseSafe,
/// but a reader who runs `zig build run -Doptimize=ReleaseFast` in the
/// fixture on its own would otherwise get a leak check that cannot fail.
///
/// Every phase frees its box explicitly before the allocator's `deinit`,
/// rather than through a `defer`. A `defer` registered in the same scope
/// runs AFTER the explicit call, and would then free through an allocator
/// that has already released its backing memory.
fn readmeBoxOwnership() !void {
    // The operands, from the page allocator rather than from a checked one,
    // so that every block the count below is about is one a loop built, and
    // none of them is data a loop was merely handed.
    const gpa = std.heap.page_allocator;
    const n: usize = 3;
    const fill = Interval.init(0.0, 1.0);
    var others = [_]DynVec{
        try DynVec.init(gpa, n, Interval.init(1.0, 1.0)),
        try DynVec.init(gpa, n, Interval.init(2.0, 2.0)),
        try DynVec.init(gpa, n, Interval.init(4.0, 4.0)),
    };
    defer for (&others) |*o| o.deinit();

    // The README's first form, and the line it says leaks.
    //
    // The claim is a COUNT, not a leak report: after the loop the caller
    // names one box and the allocator is holding `others.len + 1` of them,
    // so `others.len` of them cannot be reached from here at all. That
    // count is asserted BELOW, on the high-water mark and before any of the
    // frees, because an order that asserted afterwards would be asserting
    // the zero every correct program ends on.
    //
    // A leak report is not a witness here. It is noise in the middle of a
    // log a gate reads, and it is indistinguishable from a leak in the
    // library, which is the one thing this fixture must never be.
    {
        var dbg: std.heap.DebugAllocator(.{ .safety = true }) = .init;
        var counting = Counting{ .child = dbg.allocator() };

        // The boxes the loop below drops, kept so the demonstration can be
        // undone. This array comes from the page allocator, so it is not
        // one of the blocks the count is about; and freeing it through a
        // `defer` is safe where freeing a box is not, because the page
        // allocator has no `deinit` of its own to have run already.
        const dropped = try gpa.alloc(DynVec, others.len);
        defer gpa.free(dropped);

        var acc = try DynVec.init(counting.count(), n, fill);

        for (others, 0..) |o, i| {
            dropped[i] = acc; // added: the box `acc = next` overwrites
            acc = try acc.add(o); // one box lost per iteration
        }

        try expectCount(
            "readme-box-add-leaks",
            counting.peak,
            others.len + 1, // the constructor's box, plus one per `add`
        );

        // Hand all `others.len + 1` of them back: the reachable one first,
        // then the ones the capture kept.
        acc.deinit();
        for (dropped) |*d| d.deinit();

        try expectBool("readme-box-add-frees-everything", dbg.deinit() == .ok, true);
    }

    // The first way out, and the one the README says to reach for by
    // default. The claim is the other half of the pair above, and it is
    // stricter than "did not leak": `iadd` must not allocate at all, not
    // even a block it hands straight back. A `.ok` from the leak check
    // cannot see that difference, so the count does.
    {
        var dbg: std.heap.DebugAllocator(.{ .safety = true }) = .init;
        var counting = Counting{ .child = dbg.allocator() };

        var acc = try DynVec.init(counting.count(), n, fill);

        for (others) |o| try acc.iadd(o); // in place, no allocation

        try expectCount(
            "readme-box-iadd-owns-nothing",
            counting.peak,
            1, // the constructor's box, and no other
        );

        acc.deinit();
        try expectBool("readme-box-iadd-frees-everything", dbg.deinit() == .ok, true);
    }

    // The second way out, for when the old box has to survive the step.
    {
        var dbg: std.heap.DebugAllocator(.{ .safety = true }) = .init;
        var acc = try interval.DynVec.init(dbg.allocator(), n, fill);

        for (others) |o| {
            const next = try acc.add(o);
            acc.deinit();
            acc = next;
        }

        acc.deinit();
        try expectBool("readme-box-free-then-overwrite", dbg.deinit() == .ok, true);
    }

    // The same rule for `intersect`, where there is nothing to free on the
    // `null` arm because no box was built. The loop header is added here:
    // the README quotes the four lines of the body and leaves the loop they
    // belong to to the prose above, and `o` has nothing to refer to without
    // it. The operands overlap on no component, so the `null` arm is the one
    // taken and its claim — that it frees nothing — is what is checked.
    {
        var dbg: std.heap.DebugAllocator(.{ .safety = true }) = .init;
        var acc = try interval.DynVec.init(dbg.allocator(), n, fill);

        for (others) |o| {
            if (try acc.intersect(o)) |shared| {
                acc.deinit();
                acc = shared;
            }
            // else: no box, and acc is unchanged
        }

        acc.deinit();
        try expectBool("readme-box-intersect-ownership", dbg.deinit() == .ok, true);
    }
}

/// The README's `fromArray` example: the one door an inverted component comes
/// through, because `init` asserts and traps.
fn readmeEmptyBoxFromArray() CheckError!void {
    // --- README, "`isEmpty` is true when some component is inverted" ---
    // Interval.init asserts lo <= hi and traps, so an inverted component has
    // to be written as a literal.
    const inverted = Interval{ .lo = 4.0, .hi = -2.0 };
    const empty = interval.Vec(2).fromArray(.{ Interval.init(0, 1), inverted });

    // The block's other three lines, each with the trailing comment the
    // README gives it. The substitution is that the discarded result becomes
    // the assertion that reads it: Zig rejects a bare call whose result is
    // dropped, so a block that discards a bool cannot be transcribed AND run
    // without this one change. Nothing else about the three lines differs.
    try expectBool("readme-fromArray-isEmpty", empty.isEmpty(), true); // true: no point satisfies both components
    try expectBool("readme-fromArray-contains", empty.contains(.{ 0.5, 2.0 }), false); // false, and not merely because isEmpty said so
    try expectBool("readme-fromArray-overlaps", empty.overlaps(empty), false); // false: it holds no point to share
}

/// The README's `mapResult` signature, which is a declaration rather than a
/// statement and so cannot be run.
///
/// The return type the block prints, `MapResult(@TypeOf(v))`, is a private
/// helper in the source, so it is deliberately not checkable from out here;
/// what IS checkable is the pair of parameters, because those are what a
/// caller writes at the call site, and the first of them is what the
/// surrounding prose is about.
fn readmeMapResultSignature() void {
    comptime {
        const params = @typeInfo(@TypeOf(interval.mapResult)).@"fn".params;
        std.debug.assert(params.len == 2);
        std.debug.assert(params[0].is_generic);
        std.debug.assert(params[1].type.? == *const fn (Interval) ?Interval);
    }
    std.debug.print("ok readme-mapResult-signature: anytype, *const fn (Interval) ?Interval\n", .{});
}

/// The README's `mapResult` call sites. Its block quotes the two locals the
/// `Vec(n)` example built, so this one builds them again from that same
/// block rather than borrowing them: the README states the two as fragments
/// of one program, and a program cannot hand a `deinit`-owned box across two
/// examples without inventing a lifetime the README does not have.
fn readmeMapResultCalls() !void {
    // --- README, "Use `Vec(n)` when the dimension is a constant" ---
    // Compile-time dimension.
    const box = interval.Vec(3).fromArray(.{
        Interval.init(0.0, 1.0),
        Interval.init(0.0, 10.0),
        Interval.init(0.0, 10.0),
    });

    // Runtime dimension, with an allocator.
    var dyn = try interval.DynVec.init(std.heap.page_allocator, 3, Interval.init(0.0, 1.0));
    defer dyn.deinit();
    // --- end README ---

    // --- README, "`mapResult`" ---
    // Vec(3): the result is ?Vec(3), so no try.
    const roots = interval.mapResult(box, interval.sqrt);

    // DynVec: the result is an error union over the same optional, and the
    // non-null arm is a box you must deinit — hence `var`, because deinit
    // takes the box by pointer.
    var dyn_roots = (try interval.mapResult(dyn, interval.sqrt)).?;
    defer dyn_roots.deinit();
    // --- end README ---

    // What each route must have produced, worked out from the box it was
    // given and not from the function. The two are NOT the same box: `box`
    // is the one the vector example builds component by component, and `dyn`
    // is the one it fills from a single interval, so its other two
    // components are [0, 1] as well and its image is [0, 1] three times.
    //
    // The upper end of sqrt(10) is the one corner here that is not a double
    // boundary: IEEE 754 defines square root as correctly rounded, so
    // `@sqrt` is that exact value and the library's two-step widening is free
    // to sit outside it.
    const exact_box = [_]Interval{
        Interval.init(0.0, 1.0),
        Interval.init(0.0, @sqrt(10.0)),
        Interval.init(0.0, @sqrt(10.0)),
    };
    const exact_dyn = [_]Interval{
        Interval.init(0.0, 1.0),
        Interval.init(0.0, 1.0),
        Interval.init(0.0, 1.0),
    };

    // The fixed box takes no `try` and answers null only if a component
    // leaves the domain, which none of these does.
    try expectVecEncloses("readme-mapResult-vec", roots.?, &exact_box);
    // The owned box takes one, and the non-null arm is a box this function
    // frees above.
    try expectVecEncloses("readme-mapResult-dyn", dyn_roots, &exact_dyn);

    // And the claim the prose makes of the shared shape: one component out of
    // the domain empties the whole box, because a single empty coordinate
    // makes the image empty. `contains` is not one of the ten functions that
    // can report it, so `sqrt` on a wholly negative component is the case.
    const outside = interval.Vec(2).fromArray(.{
        Interval.init(1.0, 4.0),
        Interval.init(-4.0, -1.0),
    });
    if (interval.mapResult(outside, interval.sqrt) != null) {
        std.debug.print(
            "FAIL readme-mapResult-null: got a box, want null\n",
            .{},
        );
        return CheckError.UnexpectedReadmeAnswer;
    }
    std.debug.print("ok readme-mapResult-null: null\n", .{});
}

/// The README's `eliminateAll` block. The system is built here because the
/// README's block is three statements that assume one.
fn readmeEliminateAll() !void {
    const lp = interval.lp;

    // Two rows over two variables: x + y <= 10 and -x - y <= -4, so x + y is
    // pinned to a range rather than to a point and the system is satisfiable.
    var sys = lp.System.init(std.heap.page_allocator, 2);
    defer sys.deinit();
    try sys.add(
        &.{ Interval.init(1, 1), Interval.init(1, 1) },
        .le,
        Interval.init(10, 10),
    );
    try sys.add(
        &.{ Interval.init(-1, -1), Interval.init(-1, -1) },
        .le,
        Interval.init(-4, -4),
    );

    // --- README, "Operations" ---
    var satisfiable = true;
    try sys.eliminateAll(&satisfiable);
    if (!satisfiable) return;
    // --- end README ---

    // The flag the block reads: a satisfiable system survives the sweep.
    try expectBool("readme-eliminateAll-satisfiable", satisfiable, true);

    // And the consequence the section states two paragraphs below: `bounds`
    // and `box` project the CURRENT system, so once every variable has been
    // eliminated there is nothing left to project and both answer null.
    try expectNullInterval("readme-eliminateAll-bounds", try sys.bounds(0));
    if (try sys.box()) |derived| {
        std.heap.page_allocator.free(derived);
        std.debug.print(
            "FAIL readme-eliminateAll-box: got a box, want null\n",
            .{},
        );
        return CheckError.UnexpectedReadmeAnswer;
    }
    std.debug.print("ok readme-eliminateAll-box: null\n", .{});
}

/// The README's worked Fourier-Motzkin example: the headline, and the block
/// that was passing an inverted interval before it was fixed.
///
/// Two lines are added to the block and are marked where they sit. The two
/// assertions go in because the block frees `derived` with a `defer` as it
/// leaves the `if`, so the corners have to be read while the box is still
/// alive. The `else` arm returns an error rather than falling through,
/// because "no finite box" is this example failing, not this example
/// passing.
fn readmeFourierMotzkinWorkedExample() !void {
    const lp = interval.lp;

    var sys = lp.System.init(std.heap.page_allocator, 2);
    defer sys.deinit();

    // x + y <= 10
    try sys.add(&.{ Interval.init(1, 1), Interval.init(1, 1) }, .le, Interval.init(10, 10));
    // x - y <= 2
    try sys.add(&.{ Interval.init(1, 1), Interval.init(-1, -1) }, .le, Interval.init(2, 2));
    // -x + y <= 4
    try sys.add(&.{ Interval.init(-1, -1), Interval.init(1, 1) }, .le, Interval.init(4, 4));
    // -x - y <= 6
    try sys.add(&.{ Interval.init(-1, -1), Interval.init(-1, -1) }, .le, Interval.init(6, 6));

    // --- README, "A worked example" ---
    // Read the derived box while the variables are still live. box() does not
    // mutate the system, so the same system can still be reduced afterwards.
    if (try sys.box()) |derived| {
        defer std.heap.page_allocator.free(derived);
        std.debug.print("x in [{d}, {d}], y in [{d}, {d}]\n", .{
            derived[0].lo, derived[0].hi, derived[1].lo, derived[1].hi,
        });
        // x in [-5, 6], y in [-4, 7] — the exact corners, each printed a hair
        // outside, because a derived bound is an enclosure and not the corner.
        try expectEncloses("readme-fourier-motzkin-x", derived[0], -5.0, 6.0);
        try expectEncloses("readme-fourier-motzkin-y", derived[1], -4.0, 7.0);
    } else {
        std.debug.print("no finite box\n", .{});
        return CheckError.UnexpectedReadmeAnswer;
    }

    // To keep the reduced system rather than just read a bound, eliminate.
    if (!try sys.eliminateInOrderOfChoice()) {
        std.debug.print("unsatisfiable\n", .{});
        return;
    }
    // --- end README ---
}

/// The README's unsatisfiable example, and the note that a test of
/// `isUnsat` on a freshly built system is testing nothing.
fn readmeUnsatisfiable() !void {
    const lp = interval.lp;

    // --- README, "An unsatisfiable system" ---
    var sys = lp.System.init(std.heap.page_allocator, 1);
    defer sys.deinit();

    // x <= 1
    try sys.add(&.{Interval.init(1, 1)}, .le, Interval.init(1, 1));
    // x >= 2, stored normalised as -x <= -2
    try sys.add(&.{Interval.init(1, 1)}, .ge, Interval.init(2, 2));

    std.debug.print("before: {}\n", .{sys.isUnsat()}); // false

    // The claim the comment on that line makes, asked where the value is
    // still the one that was just printed: two conflicting rows are not
    // enough for the flag to say so, because both rows still mention x.
    try expectBool("readme-isUnsat-before", sys.isUnsat(), false);

    try sys.eliminate(0);

    std.debug.print("after: {}\n", .{sys.isUnsat()}); // true
    // --- end README ---

    // And the claim on the other line: it is the elimination that derives
    // the contradiction.
    try expectBool("readme-isUnsat-after", sys.isUnsat(), true);
}

// ---------------------------------------------------------------------------

pub fn main() !void {
    // In the order the README states them.
    try readmeWidenYourOwnArithmetic();
    try readmeUsage();
    readmeBuildWiring();
    try readmeEmptyAndUnbounded();

    try readmeVectorForms();

    try readmeBoxOwnership();
    try readmeEmptyBoxFromArray();
    readmeMapResultSignature();
    try readmeMapResultCalls();
    try readmeEliminateAll();
    try readmeFourierMotzkinWorkedExample();
    try readmeUnsatisfiable();

    std.debug.print("readme examples ok: {d} checks\n", .{total_checks});
}
