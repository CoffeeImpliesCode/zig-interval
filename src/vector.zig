//! Interval boxes in one dimension and in many.
//!
//! Two representations share one implementation. `Vec(n)` fixes the
//! dimension at comptime and stores the components inline, so it needs
//! no allocation and its size is known to the compiler. `DynVec` takes
//! the dimension at runtime and owns a heap slice, which is what a
//! dimension discovered while parsing or solving needs.
//!
//! Every box operation is a fold over the components, so each one is
//! written once, against a slice of intervals, and both representations
//! delegate to it. No bound is computed here: each element hands the
//! work to the corresponding scalar `Interval` method, so the outward
//! rounding that makes a result sound is applied in one place instead
//! of being reimplemented per dimension.

const std = @import("std");
const Interval = @import("interval.zig").Interval;

/// Elementwise binary scalar operation: add, sub, mul, div, hull.
const Binary = *const fn (Interval, Interval) Interval;

/// Binary scalar operation undefined off its domain, so it can report
/// the empty case: intersect.
const BinaryOpt = *const fn (Interval, Interval) ?Interval;

/// Elementwise unary scalar operation: neg, recip, abs, sqr.
const Unary = *const fn (Interval) Interval;

/// Unary scalar operation undefined off its domain, which is the shape
/// the transcendental functions have. Also the type of the `f` in
/// `mapResult`.
const UnaryOpt = *const fn (Interval) ?Interval;

// ---------------------------------------------------------------------------
// Core: every operation, written once against a component slice.
// ---------------------------------------------------------------------------

// The length assertion in map2, map2Opt, map1, zipInPlace, all2 and
// mapOpt is a contract check on a call site that has already fixed the
// lengths, not a check on caller input. All six are private, and every
// call site passes lengths that cannot differ: a `Vec(n)` hands them
// arrays of the comptime length n, and a `DynVec` hands them output
// allocated to `self.comps.len` beside operands `sameWidth` has
// already compared, or behind a length comparison of its own that
// short-circuits before the fold. Dropping the assertion in a release
// build therefore drops a redundant compare, not a check.
//
// The two helpers that take a point are the exception: the point comes
// from the caller and the receiver does not fix its length, so they
// compare lengths for real, in every build mode.

/// out[i] = a[i] op b[i].
fn map2(out: []Interval, a: []const Interval, b: []const Interval, op: Binary) void {
    std.debug.assert(out.len == a.len and a.len == b.len);
    for (out, a, b) |*d, x, y| d.* = op(x, y);
}

/// out[i] = a[i] op b[i], reporting false as soon as a component leaves
/// the domain of op. On false, out holds a partial result that the
/// caller discards; nothing reads it.
fn map2Opt(out: []Interval, a: []const Interval, b: []const Interval, op: BinaryOpt) bool {
    std.debug.assert(out.len == a.len and a.len == b.len);
    for (out, a, b) |*d, x, y| {
        d.* = op(x, y) orelse return false;
    }
    return true;
}

/// out[i] = a[i] op, the unary form of map2.
fn map1(out: []Interval, a: []const Interval, op: Unary) void {
    std.debug.assert(out.len == a.len);
    for (out, a) |*d, x| d.* = op(x);
}

/// dst[i] = dst[i] op src[i], in place, for the owned representation.
fn zipInPlace(dst: []Interval, src: []const Interval, op: Binary) void {
    std.debug.assert(dst.len == src.len);
    for (dst, src) |*d, x| d.* = op(d.*, x);
}

/// dst[i] = op(dst[i]), in place, for the owned representation.
fn applyInPlace(dst: []Interval, op: Unary) void {
    for (dst) |*d| d.* = op(d.*);
}

/// True when pred holds for every component: overlaps, subsetOf.
fn all2(a: []const Interval, b: []const Interval, pred: *const fn (Interval, Interval) bool) bool {
    std.debug.assert(a.len == b.len);
    for (a, b) |x, y| {
        if (!pred(x, y)) return false;
    }
    return true;
}

/// out[i] = f(a[i]), reporting false as soon as a component leaves the
/// domain of f. On false, out holds a partial result that the caller
/// discards; nothing reads it.
fn mapOpt(out: []Interval, a: []const Interval, f: UnaryOpt) bool {
    std.debug.assert(out.len == a.len);
    for (out, a) |*d, x| {
        d.* = f(x) orelse return false;
    }
    return true;
}

/// True when every component interval contains the point's
/// coordinate. A point of another length is a point of another space,
/// so it lies in no box of this width and the result is false. The
/// lengths are compared for real, so this holds in ReleaseFast and
/// ReleaseSmall too, where an assertion would be elided and the fold
/// would run off the end of the shorter of the two.
fn allContains(comps: []const Interval, p: []const f64) bool {
    if (comps.len != p.len) return false;
    for (comps, p) |c, x| {
        if (!c.contains(x)) return false;
    }
    return true;
}

/// Euclidean norm of the per-component distances from the point to the
/// box. The infinity norm, the max of the component distances, is the
/// other natural box metric; this is not it.
///
/// A point of another length has no distance to this box, and the
/// result is the positive infinity. That is the one value that keeps
/// the promise that the distance is zero exactly for a point in the
/// box, which the length check rules out, and it never reports a
/// distance below the true one.
fn normDistance(comps: []const Interval, p: []const f64) f64 {
    if (comps.len != p.len) return std.math.inf(f64);
    var squares: f64 = 0.0;
    for (comps, p) |c, x| {
        const d = c.distanceTo(x);
        squares += d * d;
    }
    return @sqrt(squares);
}

/// A box in a dimension fixed at compile time. Every component obeys
/// lo <= hi, so the box is never empty; see `isEmpty`.
pub fn Vec(comptime n: usize) type {
    return struct {
        const Self = @This();

        /// The components, one per coordinate axis.
        comps: [n]Interval,

        /// A box with every component set to fill.
        pub fn init(fill: Interval) Self {
            return .{ .comps = @splat(fill) };
        }

        /// A box over components taken as given. They must already obey
        /// lo <= hi; this constructor does not re-check them, so it is
        /// the one way to place an inverted interval in a box.
        pub fn fromArray(comps: [n]Interval) Self {
            return .{ .comps = comps };
        }

        /// n, known at compile time and read off the components.
        pub fn dim(self: Self) usize {
            return self.comps.len;
        }

        /// The components as a slice, for code written against the core.
        /// The receiver is a pointer because the components live inside
        /// it: a slice taken from a by-value copy would point at a
        /// stack frame that is gone the moment the call returns.
        pub fn slice(self: *const Self) []const Interval {
            return &self.comps;
        }

        /// Component i. The index is part of the caller's contract: an
        /// i outside `0..n` trips the bounds check the language
        /// inserts in Debug and ReleaseSafe, and reads past the array
        /// in ReleaseFast and ReleaseSmall, where that check is
        /// elided. The caller keeps the index in range; nothing here
        /// checks it in every build mode.
        pub fn get(self: Self, i: usize) Interval {
            return self.comps[i];
        }

        /// Replace component i. The same index contract as `get`, and
        /// the same reach into the array when it is broken.
        pub fn set(self: *Self, i: usize, v: Interval) void {
            self.comps[i] = v;
        }

        /// Componentwise equality of the endpoints, delegated to
        /// `Interval.eql` so both levels agree on what set equality of
        /// enclosures means. Both operands are the same `Vec(n)`, so
        /// their widths agree by type and no width check is needed.
        pub fn eql(self: Self, other: Self) bool {
            for (self.comps, other.comps) |x, y| {
                if (!x.eql(y)) return false;
            }
            return true;
        }

        /// Componentwise `Interval.add`, leaving the operands unchanged.
        pub fn add(self: Self, other: Self) Self {
            var out: Self = undefined;
            map2(&out.comps, &self.comps, &other.comps, Interval.add);
            return out;
        }

        /// Componentwise `Interval.sub`.
        pub fn sub(self: Self, other: Self) Self {
            var out: Self = undefined;
            map2(&out.comps, &self.comps, &other.comps, Interval.sub);
            return out;
        }

        /// Componentwise `Interval.mul`.
        pub fn mul(self: Self, other: Self) Self {
            var out: Self = undefined;
            map2(&out.comps, &self.comps, &other.comps, Interval.mul);
            return out;
        }

        /// Componentwise `Interval.div`. Every component of other must
        /// avoid zero; the scalar method is what reports that.
        pub fn div(self: Self, other: Self) Self {
            var out: Self = undefined;
            map2(&out.comps, &self.comps, &other.comps, Interval.div);
            return out;
        }

        /// Componentwise `Interval.neg`.
        pub fn neg(self: Self) Self {
            var out: Self = undefined;
            map1(&out.comps, &self.comps, Interval.neg);
            return out;
        }

        /// Componentwise `Interval.recip`. Every component must avoid
        /// zero.
        pub fn recip(self: Self) Self {
            var out: Self = undefined;
            map1(&out.comps, &self.comps, Interval.recip);
            return out;
        }

        /// Componentwise `Interval.abs`.
        pub fn abs(self: Self) Self {
            var out: Self = undefined;
            map1(&out.comps, &self.comps, Interval.abs);
            return out;
        }

        /// Componentwise `Interval.sqr`.
        pub fn sqr(self: Self) Self {
            var out: Self = undefined;
            map1(&out.comps, &self.comps, Interval.sqr);
            return out;
        }

        /// Per-component `Interval.hull`: the smallest box covering
        /// both.
        pub fn hull(self: Self, other: Self) Self {
            var out: Self = undefined;
            map2(&out.comps, &self.comps, &other.comps, Interval.hull);
            return out;
        }

        /// Per-component `Interval.intersect`, so null as soon as a
        /// single component is disjoint: the boxes are then disjoint,
        /// because they share no point along that axis. The empty box
        /// is never returned, only reported, so see `isEmpty`.
        pub fn intersect(self: Self, other: Self) ?Self {
            var out: Self = undefined;
            if (!map2Opt(&out.comps, &self.comps, &other.comps, Interval.intersect)) return null;
            return out;
        }

        /// True when every component overlaps, which is exactly when
        /// the boxes share at least one point.
        pub fn overlaps(self: Self, other: Self) bool {
            return all2(&self.comps, &other.comps, Interval.overlaps);
        }

        /// True when every component of self is a subset of the
        /// matching component of other, which is exactly when the box
        /// is contained in the other box.
        pub fn subsetOf(self: Self, other: Self) bool {
            return all2(&self.comps, &other.comps, Interval.subsetOf);
        }

        /// True when every component contains the matching coordinate.
        /// The point is an array of the box's own dimension, so its
        /// length always matches the width and the fold cannot run off
        /// the end of either.
        pub fn contains(self: Self, p: [n]f64) bool {
            return allContains(&self.comps, &p);
        }

        /// Euclidean distance from the point to the box: the norm of the
        /// per-component `Interval.distanceTo` values, not their
        /// maximum. It is zero exactly when the point is in the box.
        /// The point is an array of the box's own dimension, so its
        /// length always matches the width.
        pub fn distance(self: Self, p: [n]f64) f64 {
            return normDistance(&self.comps, &p);
        }

        /// Always false. A box is the product of its components, and
        /// every component of every box obeys lo <= hi, so a box always
        /// holds at least one point and cannot be empty. There is no
        /// box state for this to detect: emptiness is only observable
        /// as the null that `intersect` returns, and that null is never
        /// stored in a box.
        pub fn isEmpty(self: Self) bool {
            _ = self;
            return false;
        }
    };
}

/// A box whose dimension is known only at runtime. It owns its
/// component slice and the allocator that slice came from, so every
/// operation either reuses the receiver or draws its result from that
/// same allocator, and a result stays valid for as long as the box
/// that produced it.
///
/// The value semantics differ from `Vec(n)`, so read this before use:
/// an operation that produces a new box returns `!DynVec` and can fail
/// on a dimension mismatch or on allocation, while an operation that
/// can reuse the receiver is in place, takes a `*DynVec`, and returns
/// `void`. So `add` leaves the receiver alone, `iadd` overwrites it,
/// and `neg` is in place because there is no second box worth keeping.
pub const DynVec = struct {
    const Self = @This();

    /// Failures of the box operations: the operand widths disagree, or
    /// the allocation for a new box did not fit.
    pub const Error = error{ DimensionMismatch, OutOfMemory };

    /// The allocator every result of this box is drawn from. `deinit`
    /// frees with it, so it must be the one `init` was handed.
    gpa: std.mem.Allocator,

    /// The components, one per coordinate axis.
    comps: []Interval,

    /// A box of n components, all set to fill.
    pub fn init(gpa: std.mem.Allocator, n: usize, fill: Interval) !Self {
        const comps = try gpa.alloc(Interval, n);
        @memset(comps, fill);
        return .{ .gpa = gpa, .comps = comps };
    }

    /// A box over components copied from comps, which the caller still
    /// owns.
    pub fn fromArray(gpa: std.mem.Allocator, comps: []const Interval) !Self {
        return .{ .gpa = gpa, .comps = try gpa.dupe(Interval, comps) };
    }

    /// Free the components. The box is unusable afterwards.
    pub fn deinit(self: *Self) void {
        self.gpa.free(self.comps);
        self.* = undefined;
    }

    /// The runtime component count.
    pub fn dim(self: Self) usize {
        return self.comps.len;
    }

    /// The components as a slice, for code written against the core.
    /// The receiver is a pointer, matching `Vec(n).slice`, so the two
    /// representations are spelled the same way at every call site.
    pub fn slice(self: *const Self) []const Interval {
        return self.comps;
    }

    /// Component i. The index is part of the caller's contract: an
    /// i outside `0..dim()` trips the bounds check the language
    /// inserts in Debug and ReleaseSafe, and reads past the allocation
    /// in ReleaseFast and ReleaseSmall, where that check is elided.
    /// The caller keeps the index in range.
    pub fn get(self: Self, i: usize) Interval {
        return self.comps[i];
    }

    /// Replace component i. The same index contract as `get`.
    pub fn set(self: *Self, i: usize, v: Interval) void {
        self.comps[i] = v;
    }

    /// Componentwise equality of the endpoints, delegated to
    /// `Interval.eql` so both levels agree on what set equality of
    /// enclosures means. Widths that disagree are not comparable, so
    /// that is false, as it is for `overlaps` and `subsetOf`. The
    /// widths are compared for real, because a componentwise walk
    /// alone would decide equality over the prefix the two boxes
    /// share, and in a release build that check is not there to stop
    /// it.
    pub fn eql(self: Self, other: Self) bool {
        if (self.comps.len != other.comps.len) return false;
        for (self.comps, other.comps) |x, y| {
            if (!x.eql(y)) return false;
        }
        return true;
    }

    /// A new box of the same width, with uninitialised components.
    fn allocLike(self: Self) !Self {
        return .{ .gpa = self.gpa, .comps = try self.gpa.alloc(Interval, self.comps.len) };
    }

    /// The shared width check of every binary box operation.
    fn sameWidth(self: Self, other: Self) Error!void {
        if (self.comps.len != other.comps.len) return error.DimensionMismatch;
    }

    /// Fill a freshly allocated box from a componentwise fold, freeing
    /// it when the fold leaves the domain of the operation.
    fn foldOpt(
        self: Self,
        other: Self,
        op: BinaryOpt,
    ) Error!?Self {
        try self.sameWidth(other);
        var out = try self.allocLike();
        if (!map2Opt(out.comps, self.comps, other.comps, op)) {
            out.deinit();
            return null;
        }
        return out;
    }

    /// Componentwise `Interval.add`, as a new box.
    pub fn add(self: Self, other: Self) Error!Self {
        try self.sameWidth(other);
        var out = try self.allocLike();
        errdefer out.deinit();
        map2(out.comps, self.comps, other.comps, Interval.add);
        return out;
    }

    /// Componentwise `Interval.sub`, as a new box.
    pub fn sub(self: Self, other: Self) Error!Self {
        try self.sameWidth(other);
        var out = try self.allocLike();
        errdefer out.deinit();
        map2(out.comps, self.comps, other.comps, Interval.sub);
        return out;
    }

    /// Componentwise `Interval.mul`, as a new box.
    pub fn mul(self: Self, other: Self) Error!Self {
        try self.sameWidth(other);
        var out = try self.allocLike();
        errdefer out.deinit();
        map2(out.comps, self.comps, other.comps, Interval.mul);
        return out;
    }

    /// Componentwise `Interval.div`, as a new box. Every component of
    /// other must avoid zero.
    pub fn div(self: Self, other: Self) Error!Self {
        try self.sameWidth(other);
        var out = try self.allocLike();
        errdefer out.deinit();
        map2(out.comps, self.comps, other.comps, Interval.div);
        return out;
    }

    /// `self + other`, overwriting the receiver. The in-place twin of
    /// `add`, and the reason `add` can stay non-destructive.
    pub fn iadd(self: *Self, other: Self) Error!void {
        try self.sameWidth(other);
        zipInPlace(self.comps, other.comps, Interval.add);
    }

    /// `self - other`, overwriting the receiver.
    pub fn isub(self: *Self, other: Self) Error!void {
        try self.sameWidth(other);
        zipInPlace(self.comps, other.comps, Interval.sub);
    }

    /// `self * other`, overwriting the receiver.
    pub fn imul(self: *Self, other: Self) Error!void {
        try self.sameWidth(other);
        zipInPlace(self.comps, other.comps, Interval.mul);
    }

    /// `self / other`, overwriting the receiver.
    pub fn idiv(self: *Self, other: Self) Error!void {
        try self.sameWidth(other);
        zipInPlace(self.comps, other.comps, Interval.div);
    }

    /// Componentwise `Interval.neg`, in place: the box is the receiver.
    pub fn neg(self: *Self) void {
        applyInPlace(self.comps, Interval.neg);
    }

    /// Componentwise `Interval.recip`, in place. Every component must
    /// avoid zero.
    pub fn recip(self: *Self) void {
        applyInPlace(self.comps, Interval.recip);
    }

    /// Componentwise `Interval.abs`, in place.
    pub fn abs(self: *Self) void {
        applyInPlace(self.comps, Interval.abs);
    }

    /// Componentwise `Interval.sqr`, in place.
    pub fn sqr(self: *Self) void {
        applyInPlace(self.comps, Interval.sqr);
    }

    /// Per-component `Interval.hull`, as a new box.
    pub fn hull(self: Self, other: Self) Error!Self {
        try self.sameWidth(other);
        var out = try self.allocLike();
        errdefer out.deinit();
        map2(out.comps, self.comps, other.comps, Interval.hull);
        return out;
    }

    /// Per-component `Interval.intersect`, as a new box, or null as soon
    /// as a single component is disjoint: the boxes are then disjoint,
    /// because they share no point along that axis. The empty box is
    /// never returned, only reported, so see `isEmpty`.
    pub fn intersect(self: Self, other: Self) Error!?Self {
        return self.foldOpt(other, Interval.intersect);
    }

    /// True when every component overlaps, which is exactly when the
    /// boxes share at least one point.
    pub fn overlaps(self: Self, other: Self) bool {
        return self.comps.len == other.comps.len and
            all2(self.comps, other.comps, Interval.overlaps);
    }

    /// True when every component of self is a subset of the matching
    /// component of other. Widths that disagree are not comparable, so
    /// that is false.
    pub fn subsetOf(self: Self, other: Self) bool {
        return self.comps.len == other.comps.len and
            all2(self.comps, other.comps, Interval.subsetOf);
    }

    /// True when every component contains the matching coordinate. A
    /// point whose length is not the width of the box is a point of
    /// another space, so it lies in no box of this width and the
    /// result is false, the answer the sibling predicates give for
    /// widths that disagree. The length is compared for real, so this
    /// holds in ReleaseFast and ReleaseSmall too, where an assertion
    /// would be elided and the fold would read past the shorter of the
    /// two.
    pub fn contains(self: Self, p: []const f64) bool {
        return allContains(self.comps, p);
    }

    /// Euclidean distance from the point to the box: the norm of the
    /// per-component `Interval.distanceTo` values, not their maximum.
    /// It is zero exactly when the point is in the box. A point whose
    /// length is not the width of the box is in no box of this width,
    /// so it is not in this one, and the distance is the positive
    /// infinity: the one value that keeps the zero-if-and-only-if
    /// promise and never under-reports.
    pub fn distance(self: Self, p: []const f64) f64 {
        return normDistance(self.comps, p);
    }

    /// Always false. A box is the product of its components, and every
    /// component of every box obeys lo <= hi, so a box always holds at
    /// least one point and cannot be empty. There is no box state for
    /// this to detect: emptiness is only observable as the null that
    /// `intersect` returns, and that null is never stored in a box.
    pub fn isEmpty(self: Self) bool {
        _ = self;
        return false;
    }
};

/// Applies f to every component of v and collects the results into a
/// box of the same shape, so a transcendental is written once and used
/// on both representations. f is undefined off its domain, and the box
/// is undefined off the box, so the result is null as soon as a single
/// component leaves the domain: there is no component to put in the
/// result and none of the other components can rescue it.
///
/// A `Vec(n)` fills a stack array and cannot fail. A `DynVec` allocates
/// from the allocator it carries, and frees the partial box again when
/// the fold leaves the domain, so a null costs nothing but the
/// allocations already made.
///
/// f is a `fn (Interval) ?Interval`, which is the signature the
/// transcendental functions in `interval_ext` have.
pub fn mapResult(v: anytype, f: UnaryOpt) !?@TypeOf(v) {
    const V = @TypeOf(v);
    if (comptime V == DynVec) {
        var out = try v.allocLike();
        if (!mapOpt(out.comps, v.comps, f)) {
            out.deinit();
            return null;
        }
        return out;
    } else {
        var out: V = undefined;
        if (!mapOpt(&out.comps, &v.comps, f)) return null;
        return out;
    }
}
