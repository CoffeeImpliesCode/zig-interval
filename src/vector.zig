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
const rounding = @import("rounding.zig");

/// Elementwise binary scalar operation: add, sub, mul, div, hull.
const Binary = *const fn (Interval, Interval) Interval;

/// Binary scalar operation undefined off its domain, so it can report
/// the empty case: intersect.
const BinaryOpt = *const fn (Interval, Interval) ?Interval;

/// Elementwise unary scalar operation: neg, recip, abs, sqr.
const Unary = *const fn (Interval) Interval;

/// Unary scalar operation undefined off its domain, which is the shape
/// the transcendental functions have. The public `mapResult` signature
/// spells out this function pointer rather than publishing the alias.
const UnaryOpt = *const fn (Interval) ?Interval;

// ---------------------------------------------------------------------------
// Core: every operation, written once against a component slice.
// ---------------------------------------------------------------------------

// The length assertions in map2, map2Opt, map1, zipInPlace, all2 and
// mapOpt are contract checks on a call site that has already fixed the
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
//
// There is no `errdefer` after an `allocLike` for the same statement
// read from the other side. `add`, `sub`, `mul`, `div` and `hull`
// allocate, and the only statement between that allocation and
// `return out` is a `map2` returning void, so no path exists on
// which a box has been allocated and the operation then fails. An
// `errdefer` there is dead code that reads as if it were carrying
// weight, and a reader who believed it would be hunting a second
// failure that the code cannot have.

/// out[i] = a[i] op b[i].
fn map2(out: []Interval, a: []const Interval, b: []const Interval, op: Binary) void {
    std.debug.assert(out.len == a.len);
    std.debug.assert(a.len == b.len);
    for (out, a, b) |*d, x, y| d.* = op(x, y);
}

/// out[i] = a[i] op b[i], reporting false as soon as a component leaves
/// the domain of op. On false, out holds a partial result that the
/// caller discards; nothing reads it.
fn map2Opt(out: []Interval, a: []const Interval, b: []const Interval, op: BinaryOpt) bool {
    std.debug.assert(out.len == a.len);
    std.debug.assert(a.len == b.len);
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

/// One component's distance squared, widened upward into a bound the
/// accumulation below can hold.
///
/// A square whose true magnitude falls below the smallest positive
/// subnormal computes to a signed zero, and `roundUp` answers a zero
/// with the zero it was handed, because a zero is already its own
/// smallest bound. That is right for a bound which WAS computed as
/// zero and wrong here, where the true square is a positive real the
/// format cannot hold: a bound of zero on it is no bound at all, the
/// root of the accumulated sum comes back below the distance, and a
/// point a subnormal away from the box reads as being inside it. Every
/// square that underflowed is below the smallest positive subnormal, so
/// substituting it bounds all of them. That subnormal is
/// `rounding.min_subnormal`, shared with `Interval.sqr` rather than
/// written out again, so the two cannot disagree about the format.
/// `Interval.sqr` takes the same guard for the same reason.
fn squareBound(d: f64) f64 {
    const sq = d * d;
    if (sq == 0.0 and d != 0.0) return rounding.min_subnormal;
    return rounding.roundUp(sq);
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
///
/// The accumulation is enclosed as it grows, not rounded once at the
/// end. Every step here is a single correctly rounded operation, so
/// one outward step is the whole of the widening at that step, and
/// squaring, adding and the root are all monotone in their
/// non-negative arguments, so enclosing each term and the running
/// total encloses the root. Rounding the sum once at the end left all
/// three steps at round-to-nearest, which is half a ULP the wrong way
/// about as often as not at each of them, and the errors added: the
/// answer came back one ULP below the true distance in three per cent
/// of random 2-D cases, and in a third of the cases the sweep in
/// `tests/vector_test.zig` draws, which puts subnormals in on purpose.
///
/// `roundUp` at every step and `roundDown` nowhere, because a distance
/// is nonnegative and there is no lower end here to round. The zero is
/// the one answer the widening must not move, since the promise above
/// is stated in terms of it, and no nonzero square can widen a sum
/// down to it.
fn normDistance(comps: []const Interval, p: []const f64) f64 {
    if (comps.len != p.len) return rounding.pos_inf;
    var squares: f64 = 0.0;
    for (comps, p) |c, x| {
        squares = rounding.roundUp(squares + squareBound(c.distanceTo(x)));
    }
    return rounding.roundUp(@sqrt(squares));
}

/// A box in a dimension fixed at compile time. Every box this library
/// builds has canonical components — `lo <= hi`, no lower bound at `+inf`,
/// no upper bound at `-inf`, neither endpoint a NaN — so no box it returns
/// is empty. A component that breaks those conditions can reach a box
/// through any of the constructors or through the public `comps` field
/// itself, all of which take values as given. See `isEmpty`.
pub fn Vec(comptime n: usize) type {
    return struct {
        const Self = @This();

        /// The components, one per coordinate axis.
        comps: [n]Interval,

        /// A box with every component set to fill.
        pub fn init(fill: Interval) Self {
            return .{ .comps = @splat(fill) };
        }

        /// A box over the components as they stand, copied in with no check
        /// and no normalization. The caller holds the `Interval` contract for
        /// every component it passes, the same contract a caller of
        /// `Interval.init` holds and the same one `init(fill)` and a write to
        /// `comps[i]` assume; an implicit per-element pass here would be a
        /// second place deciding what a canonical interval is, and the two
        /// could drift apart. An invalid component therefore reaches the box
        /// unchanged, and it can equally be written in afterwards. See
        /// `isEmpty`.
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
        /// The slice borrows the receiver's storage, so it ends where
        /// the receiver does: the box going out of scope, or being moved
        /// after the slice was taken, is what invalidates it. `set` is
        /// not one of those — it writes the same array through the same
        /// pointer, so a slice taken before it reads the new component.
        /// Nothing here owns heap storage, so there is nothing to free;
        /// `DynVec.slice` is the one that has to name the call which
        /// ends its borrow.
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
            // SAFETY: `map2` writes all n components of `out.comps`
            // from the two operands before this returns, so no
            // component of `out` is read while it is undefined.
            var out: Self = undefined;
            map2(&out.comps, &self.comps, &other.comps, Interval.add);
            return out;
        }

        /// Componentwise `Interval.sub`.
        pub fn sub(self: Self, other: Self) Self {
            // SAFETY: `map2` writes all n components of `out.comps`
            // from the two operands before this returns, so no
            // component of `out` is read while it is undefined.
            var out: Self = undefined;
            map2(&out.comps, &self.comps, &other.comps, Interval.sub);
            return out;
        }

        /// Componentwise `Interval.mul`.
        pub fn mul(self: Self, other: Self) Self {
            // SAFETY: `map2` writes all n components of `out.comps`
            // from the two operands before this returns, so no
            // component of `out` is read while it is undefined.
            var out: Self = undefined;
            map2(&out.comps, &self.comps, &other.comps, Interval.mul);
            return out;
        }

        /// Componentwise `Interval.div`. Every component of other must
        /// avoid zero; the scalar method is what reports that.
        pub fn div(self: Self, other: Self) Self {
            // SAFETY: `map2` writes all n components of `out.comps`
            // from the two operands before this returns, so no
            // component of `out` is read while it is undefined.
            var out: Self = undefined;
            map2(&out.comps, &self.comps, &other.comps, Interval.div);
            return out;
        }

        /// Componentwise `Interval.neg`.
        pub fn neg(self: Self) Self {
            // SAFETY: `map1` writes all n components of `out.comps`
            // from the operand before this returns, so no component of
            // `out` is read while it is undefined.
            var out: Self = undefined;
            map1(&out.comps, &self.comps, Interval.neg);
            return out;
        }

        /// Componentwise `Interval.recip`. Every component must avoid
        /// zero.
        pub fn recip(self: Self) Self {
            // SAFETY: `map1` writes all n components of `out.comps`
            // from the operand before this returns, so no component of
            // `out` is read while it is undefined.
            var out: Self = undefined;
            map1(&out.comps, &self.comps, Interval.recip);
            return out;
        }

        /// Componentwise `Interval.abs`.
        pub fn abs(self: Self) Self {
            // SAFETY: `map1` writes all n components of `out.comps`
            // from the operand before this returns, so no component of
            // `out` is read while it is undefined.
            var out: Self = undefined;
            map1(&out.comps, &self.comps, Interval.abs);
            return out;
        }

        /// Componentwise `Interval.sqr`.
        pub fn sqr(self: Self) Self {
            // SAFETY: `map1` writes all n components of `out.comps`
            // from the operand before this returns, so no component of
            // `out` is read while it is undefined.
            var out: Self = undefined;
            map1(&out.comps, &self.comps, Interval.sqr);
            return out;
        }

        /// Per-component `Interval.hull`: the smallest box covering
        /// both.
        pub fn hull(self: Self, other: Self) Self {
            // SAFETY: `map2` writes all n components of `out.comps`
            // from the two operands before this returns, so no
            // component of `out` is read while it is undefined.
            var out: Self = undefined;
            map2(&out.comps, &self.comps, &other.comps, Interval.hull);
            return out;
        }

        /// Per-component `Interval.intersect`, so null as soon as a
        /// single component is disjoint: the boxes are then disjoint,
        /// because they share no point along that axis. The empty box
        /// is never returned, only reported, so see `isEmpty`.
        pub fn intersect(self: Self, other: Self) ?Self {
            // SAFETY: `map2Opt` writes the components of `out.comps` in
            // turn and reports false at the first one that leaves the
            // domain of the operation, and this function returns null
            // there and drops `out` unread; on the path that returns
            // `out` every one of the n components has been written.
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

        /// True when some component is inverted, lo > hi. A box is the
        /// product of its components, so one empty component leaves the
        /// whole box holding no point at all, and that is the only empty box
        /// there is: every box this library builds keeps its components
        /// ordered, because `Interval.init` checks the ordering and supplies
        /// the two overflow rays, the widening preserves the ordering, and
        /// `intersect` reports an empty result as a null instead of storing
        /// one.
        ///
        /// It detects THAT condition and nothing else, so it is not a check
        /// that a component is canonical. A NaN endpoint is not emptiness: it
        /// is the poison the scalar contract names, and lo > hi is false for
        /// it, so a poisoned box reads as non-empty. Neither is a lower bound
        /// at `+inf` or an upper bound at `-inf` looked at; a box holding
        /// either reads as non-empty here. The caller who breaks the
        /// precondition owns what the rest of the box then computes.
        pub fn isEmpty(self: Self) bool {
            for (self.comps) |c| {
                if (c.lo > c.hi) return true;
            }
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
///
/// Ownership: one box, one owner. A constructor hands the box to the
/// caller, and so does every method that returns a `DynVec`: the
/// returned box is the new owner's, the receiver keeps whatever it
/// held, and the new owner frees that box once, with `deinit`, using
/// the allocator the box was built from. A copy, `var b = a;`, is a
/// second reference to the SAME slice rather than a second box, so
/// freeing both is a double free, and nothing in the type can catch
/// it: the language has no move qualifier to forbid the copy with.
/// The convention above is the whole of the rule, and the assignment
/// that honours it frees the old box before overwriting it:
///
///     const next = try acc.add(o);
///     acc.deinit();
///     acc = next;
///
/// `deinit` is idempotent, so the one mistake the type CAN catch, a
/// second `deinit` on one box, costs nothing.
///
/// The slice must not be REPLACED, and the type cannot say so. `gpa`
/// and `comps` are public fields and the language has no field
/// privacy, so a caller can point `comps` at a slice this box never
/// allocated; a private inner struct hides nothing either, because the
/// fields are reached through the same path either way. Every
/// constructor records the address its slice had, and `deinit`
/// compares that record with the address the slice has now, so the
/// mistake is caught by an assertion in this file that NAMES it,
/// rather than by `Allocator.free` further down the stack naming the
/// allocator, or, under a release allocator, not at all.
///
/// That is an assertion, so ReleaseFast and ReleaseSmall elide it,
/// which is the trade every other check in this library makes and the
/// same one: the caller keeps the slice it was given, because the
/// rule cannot be carried by the type.
pub const DynVec = struct {
    /// Failures of the box operations: the operand widths disagree, or
    /// the allocation for a new box did not fit.
    pub const Error = error{ DimensionMismatch, OutOfMemory };

    /// The allocator every result of this box is drawn from. `deinit`
    /// frees with it, so it must be the one `init` was handed.
    gpa: std.mem.Allocator,

    /// The components, one per coordinate axis, and the box's own
    /// allocation. Replace it and `deinit` frees a slice this box
    /// never allocated; see the ownership note on this type.
    comps: []Interval,

    /// The address `comps` had when the constructor returned the box,
    /// and the only thing `deinit` trusts. Private by convention
    /// alone, since the language has no field privacy: a caller can
    /// read and write it, and a write to `comps` that leaves this
    /// behind is exactly what `deinit` checks for.
    own: [*]Interval,

    /// A box of n components, all set to fill.
    pub fn init(gpa: std.mem.Allocator, n: usize, fill: Interval) !DynVec {
        const comps = try gpa.alloc(Interval, n);
        @memset(comps, fill);
        return .{ .gpa = gpa, .comps = comps, .own = comps.ptr };
    }

    /// A box over components copied from comps, which the caller still
    /// owns. The copy is neither a check nor a normalization: the caller
    /// holds the `Interval` contract for every component exactly as it does
    /// for `Vec(n).fromArray`, for `init(fill)`, and for a write to
    /// `comps[i]`, and an invalid component is stored here unchanged. See
    /// `isEmpty`.
    pub fn fromArray(gpa: std.mem.Allocator, comps: []const Interval) !DynVec {
        const owned = try gpa.dupe(Interval, comps);
        return .{ .gpa = gpa, .comps = owned, .own = owned.ptr };
    }

    /// Free the components, and safe to call a second time on the same
    /// box: the slice is swapped for an empty one before the free, and
    /// `Allocator.free` returns on an empty slice, so a second call
    /// frees nothing rather than freeing twice. The box is left as a
    /// zero-dimensional box, where `dim()` is 0 and `slice()` is empty,
    /// which is exactly the state that second call reads, and a third
    /// call is as safe as the second.
    ///
    /// The empty slice keeps the address the owned slice had, so `own`
    /// still matches it and the check below passes on every call after
    /// the first. That is the whole of the idempotence, and the
    /// recorded address is what makes it hold: a check on the LENGTH
    /// alone would also pass for a box reassigned a slice of the same
    /// width, which is the mistake the record exists to catch.
    ///
    /// This does not make a COPY safe to free, and cannot: the copy
    /// holds the same slice, so the second free is a double free. One
    /// box, one owner; see the ownership note on this type.
    pub fn deinit(self: *DynVec) void {
        // A box owns one slice, the one its constructor allocated, and
        // `own` is the address of that slice. Both fields are public,
        // so `comps` can name a slice this box never allocated, and
        // freeing that through `gpa` hands the allocator memory it
        // never handed out: a silent heap corruption under a release
        // allocator, and under a checked one a death inside
        // `Allocator.free` that names the allocator rather than the
        // mistake. So the check is here, and it names the mistake.
        //
        // `runtime_safety` is the elision every other check in this
        // library gets from `std.debug.assert`, spelled out because an
        // `assert` reports "reached unreachable code", which names the
        // symptom rather than the mistake.
        if (std.debug.runtime_safety) {
            if (self.comps.ptr != self.own) {
                std.debug.panic(
                    "DynVec.deinit: comps was replaced since construction: " ++
                        "this box does not own the slice it holds, and freeing it " ++
                        "hands the allocator memory it never allocated",
                    .{},
                );
            }
        }
        const comps = self.comps;
        // The box is left holding an empty slice at the address it
        // owned, which is the state the second call reads: `own` still
        // matches the check above and `Allocator.free` returns on an
        // empty slice. An empty slice built somewhere else, `&.{}` say,
        // would move `comps` off `own` and turn the second `deinit`
        // into the very trap that check names.
        self.comps = comps[0..0];
        self.gpa.free(comps);
    }

    /// The runtime component count.
    pub fn dim(self: DynVec) usize {
        return self.comps.len;
    }

    /// The components as a slice, for code written against the core.
    /// The receiver is a pointer, matching `Vec(n).slice`, so the two
    /// representations are spelled the same way at every call site.
    /// The slice borrows the box's own allocation, and `deinit` is the
    /// call that ends the borrow: it frees that memory, so a slice taken
    /// before it must not be read after. `set` does not end the borrow
    /// — it writes one component of the same allocation, so the slice
    /// sees the new value.
    pub fn slice(self: *const DynVec) []const Interval {
        return self.comps;
    }

    /// Component i. The index is part of the caller's contract: an
    /// i outside `0..dim()` trips the bounds check the language
    /// inserts in Debug and ReleaseSafe, and reads past the allocation
    /// in ReleaseFast and ReleaseSmall, where that check is elided.
    /// The caller keeps the index in range.
    pub fn get(self: DynVec, i: usize) Interval {
        return self.comps[i];
    }

    /// Replace component i. The same index contract as `get`.
    pub fn set(self: *DynVec, i: usize, v: Interval) void {
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
    pub fn eql(self: DynVec, other: DynVec) bool {
        if (self.comps.len != other.comps.len) return false;
        for (self.comps, other.comps) |x, y| {
            if (!x.eql(y)) return false;
        }
        return true;
    }

    /// A new box of the same width, with uninitialised components.
    fn allocLike(self: DynVec) !DynVec {
        const comps = try self.gpa.alloc(Interval, self.comps.len);
        return .{ .gpa = self.gpa, .comps = comps, .own = comps.ptr };
    }

    /// The shared width check of every binary box operation. Its error
    /// set is `DimensionMismatch` alone and not the whole `Error`,
    /// because comparing two lengths allocates nothing: a caller that
    /// runs only this check cannot reach `OutOfMemory`, and the four
    /// in-place operations below say so in their own signatures rather
    /// than promise an allocation failure they cannot have.
    fn sameWidth(self: DynVec, other: DynVec) error{DimensionMismatch}!void {
        if (self.comps.len != other.comps.len) return error.DimensionMismatch;
    }

    /// Fill a freshly allocated box from a componentwise fold, freeing
    /// it when the fold leaves the domain of the operation.
    fn foldOpt(
        self: DynVec,
        other: DynVec,
        op: BinaryOpt,
    ) Error!?DynVec {
        try self.sameWidth(other);
        var out = try self.allocLike();
        if (!map2Opt(out.comps, self.comps, other.comps, op)) {
            out.deinit();
            return null;
        }
        return out;
    }

    /// Componentwise `Interval.add`, as a new box.
    pub fn add(self: DynVec, other: DynVec) Error!DynVec {
        try self.sameWidth(other);
        const out = try self.allocLike();
        map2(out.comps, self.comps, other.comps, Interval.add);
        return out;
    }

    /// Componentwise `Interval.sub`, as a new box.
    pub fn sub(self: DynVec, other: DynVec) Error!DynVec {
        try self.sameWidth(other);
        const out = try self.allocLike();
        map2(out.comps, self.comps, other.comps, Interval.sub);
        return out;
    }

    /// Componentwise `Interval.mul`, as a new box.
    pub fn mul(self: DynVec, other: DynVec) Error!DynVec {
        try self.sameWidth(other);
        const out = try self.allocLike();
        map2(out.comps, self.comps, other.comps, Interval.mul);
        return out;
    }

    /// Componentwise `Interval.div`, as a new box. Every component of
    /// other must avoid zero.
    pub fn div(self: DynVec, other: DynVec) Error!DynVec {
        try self.sameWidth(other);
        const out = try self.allocLike();
        map2(out.comps, self.comps, other.comps, Interval.div);
        return out;
    }

    /// `self + other`, overwriting the receiver. The in-place twin of
    /// `add`, and the reason `add` can stay non-destructive.
    ///
    /// `DimensionMismatch` is the whole error set, not the wider `Error`
    /// the allocating operations carry: an in-place form writes the
    /// receiver's own components and draws nothing, so there is no
    /// allocation here for `OutOfMemory` to refuse. The width check
    /// comes first, so that failure has changed nothing.
    pub fn iadd(self: *DynVec, other: DynVec) error{DimensionMismatch}!void {
        try self.sameWidth(other);
        zipInPlace(self.comps, other.comps, Interval.add);
    }

    /// `self - other`, overwriting the receiver.
    pub fn isub(self: *DynVec, other: DynVec) error{DimensionMismatch}!void {
        try self.sameWidth(other);
        zipInPlace(self.comps, other.comps, Interval.sub);
    }

    /// `self * other`, overwriting the receiver.
    pub fn imul(self: *DynVec, other: DynVec) error{DimensionMismatch}!void {
        try self.sameWidth(other);
        zipInPlace(self.comps, other.comps, Interval.mul);
    }

    /// `self / other`, overwriting the receiver.
    pub fn idiv(self: *DynVec, other: DynVec) error{DimensionMismatch}!void {
        try self.sameWidth(other);
        zipInPlace(self.comps, other.comps, Interval.div);
    }

    /// Componentwise `Interval.neg`, in place: the box is the receiver.
    pub fn neg(self: *DynVec) void {
        applyInPlace(self.comps, Interval.neg);
    }

    /// Componentwise `Interval.recip`, in place. Every component must
    /// avoid zero.
    pub fn recip(self: *DynVec) void {
        applyInPlace(self.comps, Interval.recip);
    }

    /// Componentwise `Interval.abs`, in place.
    pub fn abs(self: *DynVec) void {
        applyInPlace(self.comps, Interval.abs);
    }

    /// Componentwise `Interval.sqr`, in place.
    pub fn sqr(self: *DynVec) void {
        applyInPlace(self.comps, Interval.sqr);
    }

    /// Per-component `Interval.hull`, as a new box.
    pub fn hull(self: DynVec, other: DynVec) Error!DynVec {
        try self.sameWidth(other);
        const out = try self.allocLike();
        map2(out.comps, self.comps, other.comps, Interval.hull);
        return out;
    }

    /// Per-component `Interval.intersect`, as a new box, or null as soon
    /// as a single component is disjoint: the boxes are then disjoint,
    /// because they share no point along that axis. The empty box is
    /// never returned, only reported, so see `isEmpty`.
    pub fn intersect(self: DynVec, other: DynVec) Error!?DynVec {
        return self.foldOpt(other, Interval.intersect);
    }

    /// True when every component overlaps, which is exactly when the
    /// boxes share at least one point.
    pub fn overlaps(self: DynVec, other: DynVec) bool {
        return self.comps.len == other.comps.len and
            all2(self.comps, other.comps, Interval.overlaps);
    }

    /// True when every component of self is a subset of the matching
    /// component of other. Widths that disagree are not comparable, so
    /// that is false.
    pub fn subsetOf(self: DynVec, other: DynVec) bool {
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
    pub fn contains(self: DynVec, p: []const f64) bool {
        return allContains(self.comps, p);
    }

    /// Euclidean distance from the point to the box: the norm of the
    /// per-component `Interval.distanceTo` values, not their maximum.
    /// It is zero exactly when the point is in the box. A point whose
    /// length is not the width of the box is in no box of this width,
    /// so it is not in this one, and the distance is the positive
    /// infinity: the one value that keeps the zero-if-and-only-if
    /// promise and never under-reports.
    pub fn distance(self: DynVec, p: []const f64) f64 {
        return normDistance(self.comps, p);
    }

    /// True when some component is inverted, lo > hi: a box is the
    /// product of its components, so one empty component leaves the whole
    /// box holding no point at all. No box this library builds has one,
    /// because `Interval.init` checks the ordering and supplies the two
    /// overflow rays, the widening preserves the ordering, and `intersect`
    /// reports an empty result as a null instead of storing one.
    ///
    /// It detects THAT condition and nothing else, so it is not a check that
    /// a component is canonical. A NaN endpoint is not emptiness, and lo > hi
    /// is false for it, so a poisoned box reads as non-empty; neither is a
    /// lower bound at `+inf` or an upper bound at `-inf` looked at.
    ///
    /// A deinited box is a zero-dimensional box and no component
    /// reaches this fold, so it is not empty. `deinit` frees memory; it
    /// does not build a box that holds nothing.
    pub fn isEmpty(self: DynVec) bool {
        for (self.comps) |c| {
            if (c.lo > c.hi) return true;
        }
        return false;
    }
};

/// The result `mapResult` gives for a receiver of type V: `?V`, a plain
/// optional, for a `Vec(n)`, which fills a stack array and cannot fail,
/// and `DynVec.Error!?DynVec`, an error union over the same optional,
/// for a `DynVec`, which allocates. The name is private to this file,
/// so those two spellings are what a caller writes.
///
/// The split lives here rather than in an inferred return type because
/// the error set of a `!?V` is collected from every `try` in the body,
/// whether or not the branch holding it can run on this instantiation.
/// One function with one arm per shape therefore hands the stack arm an
/// `error.OutOfMemory` it can neither produce nor catch, and makes
/// every caller of that arm write a `try` that can never fire. The arms
/// are separate functions for that same reason: a `try` needs an error
/// union under it, and no one return type is an error union for both
/// shapes.
fn MapResult(comptime V: type) type {
    if (V == DynVec) return DynVec.Error!?DynVec;
    return ?V;
}

/// Applies f to every component of v and collects the results into a
/// box of the same shape, so a transcendental is written once and used
/// on both representations. f is undefined off its domain, and the box
/// is undefined off the box, so the result is null as soon as a single
/// component leaves the domain: there is no component to put in the
/// result and none of the other components can rescue it.
///
/// The receiver is a box BY VALUE, and the result type follows it: a
/// `Vec(n)` fills a stack array and cannot fail, so its result is a
/// plain `?Vec(n)`; a `DynVec` allocates from the allocator it carries
/// and frees the partial box again when the fold leaves the domain, so a
/// null there costs nothing but the allocations already made, and its
/// result is `DynVec.Error!?DynVec`, an error union over the same
/// optional. Those are the two spellings a caller writes; the return
/// type below resolves through a private alias that no call site outside
/// this file can name.
///
/// The owned arm carries the whole `DynVec.Error` even though a unary
/// fold compares no widths, so only `error.OutOfMemory` is reachable
/// there. Handle both at the call site, or the compiler will not let
/// you forget one.
///
/// A POINTER is a compile error, and that is deliberate. A pointer
/// names a box the caller owns and says nothing about where a result
/// should be built: `Vec(n)` has no allocator to draw one from, and
/// the shape that compiled before this check existed declared
/// `var out: V = undefined` with V a pointer and wrote the components
/// through it, which is a segfault in every build mode rather than a
/// wrong answer. A call site that says `mapResult(&box, f)` has made a
/// mistake about ownership, and the cheapest thing to hand it is an
/// error naming the mistake rather than a wild write.
///
/// f is a `fn (Interval) ?Interval`, which is the signature of the
/// elementary functions that can report an EMPTY result: `sqrt`, `log`,
/// `log2`, `log10`, `log1p`, `asin`, `acos`, `acosh`, `atanh` and
/// `powf`. The remaining eighteen return a plain `Interval` and are not
/// coercible here; to fold one of those, wrap it so that its result is
/// lifted into an optional.
pub fn mapResult(v: anytype, f: *const fn (Interval) ?Interval) MapResult(@TypeOf(v)) {
    const V = @TypeOf(v);
    if (comptime @typeInfo(V) == .pointer) {
        @compileError("mapResult takes a box by value: pass the box, not a pointer to it.");
    }
    if (comptime V == DynVec) return mapResultOwned(v, f);
    return mapResultStack(v, f);
}

/// The `DynVec` arm of `mapResult`: it allocates, so it has an error to
/// report, and it is a function of its own so that the one `try` in it
/// stands under a return type that admits an error. Written as an arm
/// of the body above it was a `try` under a return type that is a plain
/// `?Vec(n)` on the stack instantiation, which cannot produce one.
fn mapResultOwned(v: DynVec, f: UnaryOpt) DynVec.Error!?DynVec {
    var out = try v.allocLike();
    if (!mapOpt(out.comps, v.comps, f)) {
        out.deinit();
        return null;
    }
    return out;
}

/// The `Vec(n)` arm: a stack array, so nothing to allocate and no error
/// to report, and nothing to free when the fold leaves the domain.
fn mapResultStack(v: anytype, f: UnaryOpt) ?@TypeOf(v) {
    // SAFETY: `mapOpt` writes the components of `out.comps` in turn and
    // reports false at the first one that leaves the domain of f, and
    // this function then drops `out` unread; on the path that returns
    // it, all n components have been written.
    var out: @TypeOf(v) = undefined;
    if (!mapOpt(&out.comps, &v.comps, f)) return null;
    return out;
}
