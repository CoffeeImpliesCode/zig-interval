//! The branch carrier: caller-buffer choice maps, the generic set/writer
//! pair, the typed lifting seams, and the real split producers.
//!
//! A branch map here is not bookkeeping. It is the only thing standing
//! between a set of alternatives and a hull that quietly destroys the
//! mathematics: `floor([0.9, 1.1])` is `{0, 1}` and not `[0, 1]`, `1/x`
//! over `[-1, 1]` is two rays and not the whole line, and once two
//! alternatives share a site, only the pairings that agree at that site
//! are the ones a caller may combine. So this module splits wherever the
//! mathematics splits, keeps the gap in the image, and never merges or
//! hulls alternatives on the caller's behalf.
//!
//! Three distinctions carry most of the weight, and each of them is a
//! different answer rather than a different flavour of the same one:
//!
//!   * An empty result and a resource failure are different statements. A
//!     set with no pieces is mathematics -- `1/0` has no image, so the
//!     alternative set of the box `{0}` under `recip` is empty -- while
//!     `error.CapacityExceeded` is a statement about the caller's buffers.
//!     Every producer here restores the writer to the counts it had on
//!     entry before it returns that error, so a failed split publishes
//!     nothing of itself and leaves earlier views untouched.
//!   * Sites are the caller's own integers and choices are `i128`, not a
//!     bit. `18446744073709551615` and the extremes of `i128` are ordinary
//!     values that survive a merge unchanged, and a map of forty bindings
//!     is walked whole: there is no budget over a branch map anywhere in
//!     this file, so forty bindings agreeing and one disagreeing are very
//!     different answers.
//!   * A site denotes the same operator on the same arguments in the same
//!     evaluation. Two calls of `floor` on the SAME input at the SAME site
//!     describe the SAME cell and are correlated, so their compatible
//!     pairings give `{0, 2}` and never the mixed sum `1`. Give the second
//!     call a different site and every combination is live again. The
//!     library does not police which of those two cases a caller is in --
//!     different arguments at one site is a documented precondition
//!     violation -- but the pairing rule behaves this way in both
//!     directions, and `mod` reuses the `floor` cell label at a shared
//!     site precisely so that a quotient cell and a remainder cell can be
//!     paired with each other.
//!
//! Lifetimes. A `Set(T)` borrows the writer's buffers; `view()` hands back
//! a slice of a caller-owned fixed array, so it stays valid while later
//! appends land within those arrays and stops being meaningful at
//! `reset()`, at reuse of the buffers, or when the writer goes out of
//! scope. Nothing in this module allocates, keeps a handle, keeps a
//! generation counter, or reads a global context: the caller's buffers are
//! the whole of the state.
//!
//! Extension. `mapUnary`, `mapBinary` and `mapSplit` are the seams a
//! caller extends with, and each has one soundness rule attached. A unary
//! or binary callback is a pure function of its value arguments and is
//! handed the incoming maps untouched; it cannot widen, narrow or drop a
//! branch, because it never sees one. `mapSplit` hands the callback the
//! writer itself, so the callback owes two things: it must build each
//! outgoing map by MERGING the incoming one (never replacing it, and never
//! reusing one alternative's map for another), and it must supply metadata
//! it can justify -- `defined` never `always` over a box whose membership
//! or domain is uncertain, and `continuous` never promoted merely because
//! each of the callback's own preimage pieces is smooth. The library
//! enforces the second half only where it owns the mathematics: it checks
//! sortedness and uniqueness of everything published, restores the entry
//! checkpoint on any error, and never publishes a piece whose map
//! contradicts the cut it is being given.
//!
//! Where a producer cannot answer, it says why. A rounding rule whose cell
//! count is not representable as `Choice`, a tangent phase whose cells are
//! not resolvable as `i128`, and a modulus magnitude that reaches zero all
//! end in `error.CapacityExceeded` rather than in a hull, because a hull
//! is the one answer a caller cannot undo.

const std = @import("std");

const interval_mod = @import("interval.zig");
const ext_mod = @import("interval_ext.zig");
const rounding_mod = @import("rounding.zig");
const truth_mod = @import("truth.zig");
const tracked_mod = @import("tracked.zig");
const real_mod = @import("real.zig");
const trig_mod = @import("trig.zig");

const Interval = interval_mod.Interval;
const Truth = truth_mod.Truth;
const Tracked = tracked_mod.Tracked;
const Rational = real_mod.Rational;

const pos_inf = std.math.inf(f64);
const neg_inf = -std.math.inf(f64);

// ---------------------------------------------------------------------------
// The carrier itself.
// ---------------------------------------------------------------------------

/// The only failure this module can report, and it is about the CALLER'S
/// BUFFERS, never about the mathematics. A split that produces no
/// alternatives is a `Set` with zero pieces and not this error; a split
/// that produces more alternatives than there is room for is this error and
/// not a shorter set. No producer in this file returns it in place of a
/// partial answer, and none drops a potentially live alternative to avoid
/// it.
pub const Error = error{CapacityExceeded};

/// A caller-supplied name for one operation on one set of arguments in one
/// evaluation. The library allocates no identifiers and keeps no registry:
/// two operations share a site exactly when the caller passes the same
/// number twice, and the caller is responsible for that number meaning the
/// same mathematical operation both times.
pub const Site = u64;

/// Which alternative of that operation a piece is. Not a bit and not a
/// bounded enum: an inverse-trigonometric branch index, a floor cell label
/// and an encoding of two facts at once all have to be nameable, and all
/// of them have to survive a merge unchanged.
pub const Choice = i128;

/// One binding of a site to a choice. A branch map is a `[]const Assignment`
/// sorted strictly increasing in `site`, which is a precondition the caller
/// states and this module's producers honour.
pub const Assignment = struct {
    site: Site,
    choice: Choice,
};

/// Whether two maps can describe the same alternative: they agree at EVERY
/// site they share. Disjoint maps are compatible by having nothing to
/// disagree about.
///
/// Both arguments are walked whole. There is no budget and no sampling here
/// or anywhere else in this file, because a budget would make "forty
/// bindings agree and one disagrees" the same answer as "two bindings
/// disagree", which is the whole question.
pub fn compatible(a: []const Assignment, b: []const Assignment) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (a[i].site < b[j].site) {
            i += 1;
        } else if (a[i].site > b[j].site) {
            j += 1;
        } else {
            if (a[i].choice != b[j].choice) return false;
            i += 1;
            j += 1;
        }
    }
    return true;
}

/// The union of two branch maps, into a caller-owned buffer.
///
/// Returns null for a PROVEN CONTRADICTION -- the two maps bind some shared
/// site to two different choices -- and that is a different answer from
/// every other one here: it is not an empty map, not a one-sided union and
/// not `error.CapacityExceeded`. Returns `error.CapacityExceeded` when the
/// union does not fit `out`, having written nothing: a shorter map would
/// then read as a complete one.
///
/// The size is computed before anything is written, so neither failure
/// answer depends on how much of `out` happened to be left.
pub fn merge(out: []Assignment, a: []const Assignment, b: []const Assignment) Error!?[]const Assignment {
    var size: usize = 0;
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (a[i].site < b[j].site) {
            size += 1;
            i += 1;
        } else if (a[i].site > b[j].site) {
            size += 1;
            j += 1;
        } else {
            if (a[i].choice != b[j].choice) return null;
            size += 1;
            i += 1;
            j += 1;
        }
    }
    size += (a.len - i) + (b.len - j);
    if (size > out.len) return error.CapacityExceeded;

    var n: usize = 0;
    i = 0;
    j = 0;
    while (i < a.len and j < b.len) {
        if (a[i].site < b[j].site) {
            out[n] = a[i];
            i += 1;
        } else if (a[i].site > b[j].site) {
            out[n] = b[j];
            j += 1;
        } else {
            out[n] = a[i];
            i += 1;
            j += 1;
        }
        n += 1;
    }
    while (i < a.len) : (i += 1) {
        out[n] = a[i];
        n += 1;
    }
    while (j < b.len) : (j += 1) {
        out[n] = b[j];
        n += 1;
    }
    std.debug.assert(n == size);
    return out[0..n];
}

// ---------------------------------------------------------------------------
// Sets, pieces and the writer.
// ---------------------------------------------------------------------------

/// One alternative of a value: the value, and the branch map that says which
/// cell of the search this one is.
pub fn Piece(comptime T: type) type {
    return struct {
        value: T,
        assignments: []const Assignment,
    };
}

/// A set of alternatives over `T`, borrowing whichever buffers hold them.
/// `pieces` may legitimately be empty: that is the mathematical answer, and
/// it is not the same as a call that failed.
pub fn Set(comptime T: type) type {
    return struct {
        pieces: []const Piece(T),
    };
}

/// A published map is sorted strictly increasing in `site`, which is the
/// precondition a caller may merge against. Asserted on everything this
/// module publishes, because an unsorted map is not one a caller may merge
/// and nothing downstream would notice.
fn assertSortedUnique(map: []const Assignment) void {
    var i: usize = 1;
    while (i < map.len) : (i += 1) {
        std.debug.assert(map[i - 1].site < map[i].site);
    }
}

/// A set built into two caller-owned fixed buffers: one array of pieces and
/// one array of assignments every published map is copied into.
///
/// The writer owns its copy of every map: a caller may hand `append` a
/// slice into a scratch array, scribble over that array, and the published
/// piece does not follow it. Views already handed out stay valid while
/// later appends land, because appending only writes past the counts that
/// those views end at; `reset` and reuse of the buffers is where that
/// guarantee ends, by design rather than by accident.
pub fn Writer(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The two counts an operation restores on failure. A checkpoint is
        /// two integers, not a handle and not a generation: restoring it is
        /// what makes an operation atomic, and there is nothing else to
        /// keep.
        pub const Checkpoint = struct {
            pieces: usize,
            assignments: usize,
        };

        pieces: []Piece(T),
        pool: []Assignment,
        piece_count: usize = 0,
        pool_count: usize = 0,

        pub fn init(pieces: []Piece(T), assignments: []Assignment) Self {
            return .{ .pieces = pieces, .pool = assignments };
        }

        /// How many more pieces the writer can still publish. Producers read
        /// this BEFORE enumerating a cell set, so an impossible count is
        /// refused instead of attempted.
        pub fn remaining(self: *const Self) usize {
            return self.pieces.len - self.piece_count;
        }

        /// The counts this writer is at, to be handed to `rollback` by an
        /// `errdefer` so a failed operation publishes nothing of itself.
        pub fn checkpoint(self: *const Self) Checkpoint {
            return .{ .pieces = self.piece_count, .assignments = self.pool_count };
        }

        /// Return to a checkpoint. Never moves a count forward, so a stale
        /// checkpoint is a caller bug and not a way to invent capacity.
        pub fn rollback(self: *Self, cp: Checkpoint) void {
            std.debug.assert(cp.pieces <= self.piece_count);
            std.debug.assert(cp.assignments <= self.pool_count);
            self.piece_count = cp.pieces;
            self.pool_count = cp.assignments;
        }

        /// Publish one alternative carrying a COPY of `assignments`.
        ///
        /// Both buffers are checked before either is touched, so a failed
        /// append leaves the writer exactly as it was: no half-published
        /// piece, and no piece short of a binding.
        pub fn append(self: *Self, value: T, assignments: []const Assignment) Error!void {
            if (self.piece_count >= self.pieces.len) return error.CapacityExceeded;
            if (assignments.len > self.pool.len - self.pool_count) return error.CapacityExceeded;
            const start = self.pool_count;
            var n: usize = 0;
            for (assignments) |x| {
                self.pool[start + n] = x;
                n += 1;
            }
            assertSortedUnique(self.pool[start..][0..n]);
            self.pieces[self.piece_count] = .{
                .value = value,
                .assignments = self.pool[start..][0..n],
            };
            self.pool_count = start + n;
            self.piece_count += 1;
        }

        /// The published alternatives so far. This borrows the piece buffer,
        /// and an earlier view keeps naming the pieces it named when later
        /// appends land.
        pub fn view(self: *const Self) Set(T) {
            return .{ .pieces = self.pieces[0..self.piece_count] };
        }

        /// Forget everything published, keeping both buffers. Views handed
        /// out before this are not to be read again.
        pub fn reset(self: *Self) void {
            self.piece_count = 0;
            self.pool_count = 0;
        }

        /// Publish one alternative whose map is `a` united with `b` and with
        /// the single binding in `extra`, sorted by site and stored in the
        /// writer's own pool.
        ///
        /// Returns false, having published nothing, when the union is a
        /// PROVEN CONTRADICTION: two of the sources bind one site to two
        /// different choices. That is mathematics, so it is a bool and not
        /// an error, and it is the same rule `merge` reports as null. A
        /// caller that asked for a cell its own input map had already ruled
        /// out skips that cell and keeps going: the other cells of the same
        /// split are still live.
        ///
        /// `extra` is empty or a single binding, which is all any producer
        /// here needs: one new cut, optionally merged with the maps of a
        /// pair of input sets.
        fn appendUnion(
            self: *Self,
            value: T,
            a: []const Assignment,
            b: []const Assignment,
            extra: []const Assignment,
        ) Error!bool {
            std.debug.assert(extra.len <= 1);
            var size: usize = 0;
            var i: usize = 0;
            var j: usize = 0;
            while (i < a.len and j < b.len) {
                if (a[i].site < b[j].site) {
                    size += 1;
                    i += 1;
                } else if (a[i].site > b[j].site) {
                    size += 1;
                    j += 1;
                } else {
                    if (a[i].choice != b[j].choice) return false;
                    size += 1;
                    i += 1;
                    j += 1;
                }
            }
            size += (a.len - i) + (b.len - j);

            var total = size;
            if (extra.len == 1) {
                const at = findSite(a, extra[0].site);
                const in_a = at < a.len and a[at].site == extra[0].site;
                if (in_a and a[at].choice != extra[0].choice) return false;
                const bt = findSite(b, extra[0].site);
                const in_b = bt < b.len and b[bt].site == extra[0].site;
                if (in_b and b[bt].choice != extra[0].choice) return false;
                if (!in_a and !in_b) total += 1;
            }

            if (self.piece_count >= self.pieces.len) return error.CapacityExceeded;
            if (total > self.pool.len - self.pool_count) return error.CapacityExceeded;

            const start = self.pool_count;
            const dst = self.pool[start..][0..total];
            var n: usize = 0;
            i = 0;
            j = 0;
            while (i < a.len and j < b.len) {
                if (a[i].site < b[j].site) {
                    dst[n] = a[i];
                    i += 1;
                } else if (a[i].site > b[j].site) {
                    dst[n] = b[j];
                    j += 1;
                } else {
                    dst[n] = a[i];
                    i += 1;
                    j += 1;
                }
                n += 1;
            }
            while (i < a.len) : (i += 1) {
                dst[n] = a[i];
                n += 1;
            }
            while (j < b.len) : (j += 1) {
                dst[n] = b[j];
                n += 1;
            }
            std.debug.assert(n == size);
            if (total > size) {
                // The one new binding, inserted where `site` belongs. The
                // shift runs backwards over the pool copy this call just
                // wrote, never over the sources it read from.
                var w = size;
                while (w > 0 and dst[w - 1].site > extra[0].site) : (w -= 1) {
                    dst[w] = dst[w - 1];
                }
                dst[w] = extra[0];
            }
            assertSortedUnique(dst);

            self.pieces[self.piece_count] = .{ .value = value, .assignments = dst };
            self.pool_count = start + total;
            self.piece_count += 1;
            return true;
        }

        /// Publish one alternative whose map is `incoming` with `site` bound
        /// to `choice` inserted in sorted position. When `incoming` already
        /// binds `site` to that same choice the map is unchanged; when it
        /// binds a different one the alternative is not published at all,
        /// because the incoming map has already ruled this cell out.
        pub fn appendBound(
            self: *Self,
            value: T,
            incoming: []const Assignment,
            site: Site,
            choice: Choice,
        ) Error!bool {
            var extra = [_]Assignment{.{ .site = site, .choice = choice }};
            return self.appendUnion(value, incoming, &.{}, extra[0..]);
        }

        /// Publish one alternative carrying the union of two maps, as
        /// `mapBinary` needs for one compatible pair. False on a proven
        /// contradiction, as in `appendBound`.
        pub fn appendMerged(
            self: *Self,
            value: T,
            a: []const Assignment,
            b: []const Assignment,
        ) Error!bool {
            return self.appendUnion(value, a, b, &.{});
        }
    };
}

/// Where `site` sits in a sorted unique map, or `map.len` when absent.
fn findSite(map: []const Assignment, site: Site) usize {
    var lo: usize = 0;
    var hi: usize = map.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (map[mid].site < site) lo = mid + 1 else hi = mid;
    }
    return lo;
}

// ---------------------------------------------------------------------------
// Generic lifting.
// ---------------------------------------------------------------------------

/// Apply a unary function to every alternative, keeping every map untouched.
///
/// The callback is the typed mathematical extension seam: it is handed a
/// value and returns a value, so it cannot see, widen or drop a branch. It
/// is responsible for its own metadata, which means a partial-domain
/// function has to say `defined = maybe` rather than echoing a fully
/// defined input -- a soundness rule the library cannot enforce on a value
/// it never sees.
///
/// The returned set is the writer's WHOLE content, including whatever the
/// caller had published in it before this call. On error the writer is back
/// at its entry checkpoint and nothing of this operation is published.
pub fn mapUnary(
    comptime T: type,
    out: *Writer(T),
    input: Set(T),
    f: *const fn (T) T,
) Error!Set(T) {
    const cp = out.checkpoint();
    errdefer out.rollback(cp);
    for (input.pieces) |p| {
        try out.append(f(p.value), p.assignments);
    }
    return out.view();
}

/// Apply a binary function to every COMPATIBLE PAIR of alternatives, merging
/// each surviving pair's two maps into the one its result carries.
///
/// This is where the site rule earns its keep: with two calls at one site
/// the mixed pairings are proven contradictions and do not appear, and with
/// two calls at different sites every combination is live. A pair that is
/// potentially compatible is NEVER skipped for a capacity reason: a buffer
/// that fits only some of the pairs is `error.CapacityExceeded` with the
/// writer rolled back, not a shorter answer that would read as complete.
///
/// The callback is pure over values and never sees a branch. The returned
/// set is the writer's whole content.
pub fn mapBinary(
    comptime T: type,
    out: *Writer(T),
    a: Set(T),
    b: Set(T),
    f: *const fn (T, T) T,
) Error!Set(T) {
    const cp = out.checkpoint();
    errdefer out.rollback(cp);
    for (a.pieces) |pa| {
        for (b.pieces) |pb| {
            if (!compatible(pa.assignments, pb.assignments)) continue;
            _ = try out.appendMerged(f(pa.value, pb.value), pa.assignments, pb.assignments);
        }
    }
    return out.view();
}

/// Apply a splitting callback to every alternative, letting it append as
/// many correlated alternatives as that one piece has.
///
/// This is the seam for a caller's own special function, and it is the one
/// seam that hands the writer over. The callback therefore OWNS two
/// obligations, both of which matter for soundness: it must build each
/// outgoing map by merging the incoming one rather than replacing it, and
/// it must supply metadata it can justify for a piece whose membership in
/// the original box is uncertain. What the library enforces is everything
/// outside the callback's arithmetic: sortedness and uniqueness of what gets
/// published, and the entry checkpoint, which is restored on any error --
/// including a `CapacityExceeded` the callback raised after it had already
/// appended part of its split.
pub fn mapSplit(
    comptime T: type,
    out: *Writer(T),
    input: Set(T),
    f: *const fn (*Writer(T), Piece(T)) Error!void,
) Error!Set(T) {
    const cp = out.checkpoint();
    errdefer out.rollback(cp);
    for (input.pieces) |p| {
        try f(out, p);
    }
    return out.view();
}

/// Join the POSSIBLE outcomes of every compatible pair under `op`.
///
/// This is a join of outcome sets and not a conjunction over alternatives:
/// one pair that proves the relation and another that refutes it answers
/// `maybe`, because a true outcome exists and throwing it away would be
/// unsound. No compatible pair at all is `never`, since there is no outcome
/// to join. Per-piece definedness is kept per pair -- a wholly undefined
/// piece contributes a certainly false outcome and does not poison a true
/// one -- which is why the comparison is made pair by pair and joined
/// afterwards rather than made once per set.
///
/// The user still owns the quantifier policy; nothing here decides whether
/// "some alternative satisfies" answers a question.
pub fn compare(a: Set(Tracked), b: Set(Tracked), op: tracked_mod.Cmp) Truth {
    var acc: Truth = .never;
    var any = false;
    for (a.pieces) |pa| {
        for (b.pieces) |pb| {
            if (!compatible(pa.assignments, pb.assignments)) continue;
            any = true;
            acc = truth_mod.join(acc, pa.value.compare(pb.value, op));
        }
    }
    return if (any) acc else .never;
}

// ---------------------------------------------------------------------------
// Metadata the producers share.
// ---------------------------------------------------------------------------

/// The two truths a producer publishes for one piece, decided before any
/// value is computed.
const Meta = struct {
    defined: Truth,
    continuous: Truth,
};

/// Metadata for a piece whose source piece is `src`, which is known not to be
/// wholly undefined -- an undefined source never reaches here, because a
/// wholly undefined argument has no cells to name at all.
///
/// `whole_in_domain` asks whether the FUNCTION is defined at every point of
/// the SOURCE box, not of this piece's sub-box. That is deliberate: a piece
/// is a cell of the original box rather than a subset of it, so its
/// membership is uncertain, and the source box's own undefined points have
/// to be reported by every one of its cells. It is also what keeps a smooth
/// cell from being promoted to a continuous whole: `tan` over a box holding
/// a pole gives every one of its cells `defined = maybe` and
/// `continuous = maybe`, however smooth each cell is on its own.
fn carried(src: Tracked, whole_in_domain: bool) Meta {
    return .{
        .defined = if (whole_in_domain) src.defined else truth_mod.join(src.defined, .maybe),
        .continuous = if (whole_in_domain) src.continuous else truth_mod.join(src.continuous, .maybe),
    };
}

/// As `carried`, for a producer that combines two arguments: neither
/// argument's definedness may be lost, and neither may disappear because the
/// other one clips or zeroes something.
fn carried2(a: Tracked, b: Tracked, whole_in_domain: bool) Meta {
    const defined = truth_mod.join(a.defined, b.defined);
    const continuous = truth_mod.join(a.continuous, b.continuous);
    return .{
        .defined = if (whole_in_domain) defined else truth_mod.join(defined, .maybe),
        .continuous = if (whole_in_domain) continuous else truth_mod.join(continuous, .maybe),
    };
}

/// Metadata for a producer whose pieces are CONSTANT -- the six rounding
/// rules and `sgn` name one integer cell each -- where the value function on
/// the cell is a constant and so is continuous wherever it is defined. The
/// image SPANNING a jump is what is not continuous, and the split is exactly
/// what keeps that jump out of every published piece.
fn constantImage(src: Tracked) Meta {
    return .{ .defined = src.defined, .continuous = src.defined };
}

// ---------------------------------------------------------------------------
// Integer cells: the six rounding rules.
// ---------------------------------------------------------------------------

/// Which directed integer map a rounding producer implements. Every one of
/// them is non-decreasing, which is what makes the image of a box the
/// unbroken integer range between the images of its two endpoints -- and
/// therefore what makes "name every cell" both necessary and complete.
const Rounding = enum {
    /// Toward -infinity.
    floor,
    /// Toward +infinity.
    ceil,
    /// Toward zero.
    trunc,
    /// Half away from zero: the tie leaves the origin. This is `ext.round`.
    away,
    /// Half toward +infinity.
    ties_up,
    /// Half toward -infinity.
    ties_down,
};

/// The integer a rounding rule assigns to `x`, exactly.
///
/// The tie comparisons are exact. `@floor`, `@ceil` and `@trunc` of an f64
/// are that integer when it is representable, and the distance from a point
/// to a neighbouring integer is a difference of representable numbers below
/// one, which is itself representable; so a tie is seen as a tie here
/// instead of being lost to the rounding of `x + 1/2`.
///
/// An infinite or unrepresentable argument returns an infinity, which
/// `cellRange` refuses before any conversion.
fn stepValue(rule: Rounding, x: f64) f64 {
    return switch (rule) {
        .floor => @floor(x),
        .ceil => @ceil(x),
        .trunc => @trunc(x),
        .away => blk: {
            const t = @trunc(x);
            if (@abs(x - t) >= 0.5) break :blk if (x < 0.0) t - 1.0 else t + 1.0;
            break :blk t;
        },
        .ties_up => blk: {
            const lo = @floor(x);
            if (x - lo >= 0.5) break :blk @ceil(x);
            break :blk lo;
        },
        .ties_down => blk: {
            const hi = @ceil(x);
            if (hi - x >= 0.5) break :blk @floor(x);
            break :blk hi;
        },
    };
}

/// The largest cell label this module will name. `Choice` is an `i128`, and
/// this is 2^126, so the conversion in `cellRange` is inside the type for
/// every value that passes. It is also far past any cell set a caller could
/// enumerate, which is why a box that reaches it is a capacity refusal and
/// not a loop.
const label_limit: f64 = 8.507059173023462e37;

const CellRange = struct { first: Choice, last: Choice };

/// The integer cells a rounding rule cuts `box` into, as `Choice` labels.
///
/// Refuses -- with the one error this module has -- when a cell label is not
/// representable as a `Choice`. That refusal happens BEFORE the conversion
/// that would trap and BEFORE any enumeration, so `[0, 1e18]` is answered
/// in constant time by a caller whose buffers cannot hold a billion
/// alternatives.
fn cellRange(box: Interval, rule: Rounding) Error!CellRange {
    const a = stepValue(rule, box.lo);
    const b = stepValue(rule, box.hi);
    // Written to reject NaN and both infinities as well as the too-large
    // case: a NaN fails every comparison here.
    if (!(a >= -label_limit and a < label_limit)) return error.CapacityExceeded;
    if (!(b >= -label_limit and b < label_limit)) return error.CapacityExceeded;
    return .{ .first = @intFromFloat(a), .last = @intFromFloat(b) };
}

/// Refuse an unenumerable cell set before enumerating it. A count this large
/// is not going to fit any caller buffer, and answering after a partial
/// enumeration would be a truncated set, which is the one answer a caller
/// cannot undo. The count stays in `i128` throughout: casting it to a
/// machine word first is how a large box turns into a small loop.
fn refuseIfTooMany(cells: CellRange, out: *const Writer(Tracked)) Error!void {
    const need = cells.last - cells.first + 1;
    if (need > @as(i128, @intCast(out.remaining()))) return error.CapacityExceeded;
}

/// An enclosure of the integer `k`, which is the VALUE of a rounding cell.
///
/// Below 2^53 the conversion is exact and the answer is the point. Beyond
/// it `@floatFromInt` rounds to nearest, so the true integer is within half
/// an ulp of the computed value and one outward step on each side encloses
/// it. Width here is a quality measure: what matters is that the cell's own
/// integer is inside, and never that a neighbouring one is.
fn intInterval(k: Choice) Interval {
    const f: f64 = if (k == 0) 0.0 else @floatFromInt(k);
    if (@as(Choice, @intFromFloat(f)) == k) return Interval.init(f, f);
    return Interval.init(rounding_mod.prevDown(f), rounding_mod.nextUp(f));
}

/// The value `1/y` at one endpoint, outward-widened exactly as `Interval`
/// division widens an exactly representable quotient, and never through the
/// zero arm -- every caller here has already established `y != 0`.
fn reciprocalPoint(y: f64) Interval {
    return Interval.init(1.0, 1.0).div(Interval.init(y, y));
}

/// The quotient `x/y` of two exact points, the same construction.
fn quotientPoint(x: f64, y: f64) Interval {
    return Interval.init(x, x).div(Interval.init(y, y));
}

/// One alternative: `range` under `meta`, carrying `a` united with `b` and
/// the one new cut.
fn emit(
    out: *Writer(Tracked),
    meta: Meta,
    range: Interval,
    a: []const Assignment,
    b: []const Assignment,
    site: Site,
    choice: Choice,
) Error!void {
    var extra = [_]Assignment{.{ .site = site, .choice = choice }};
    const v = Tracked.withMetadata(range, meta.defined, meta.continuous);
    _ = try out.appendUnion(v, a, b, extra[0..]);
}

/// One UNDEFINED alternative: no range at all, `defined = never`,
/// `continuous = never`, carrying the same maps as `emit`. An undefined
/// result carries no fake interval, which is why this is its own shape and
/// not an empty range.
fn emitUndefined(
    out: *Writer(Tracked),
    a: []const Assignment,
    b: []const Assignment,
    site: Site,
    choice: Choice,
) Error!void {
    var extra = [_]Assignment{.{ .site = site, .choice = choice }};
    _ = try out.appendUnion(Tracked.undefined(), a, b, extra[0..]);
}

// ---------------------------------------------------------------------------
// Producers over Tracked values.
// ---------------------------------------------------------------------------

/// The value as it stands, with no cut invented and no site bound: the one
/// producer for a leaf input to a later operation.
pub fn leaf(out: *Writer(Tracked), value: Tracked) Error!Set(Tracked) {
    const cp = out.checkpoint();
    errdefer out.rollback(cp);
    try out.append(value, &.{});
    return out.view();
}

/// Every integer a rounding rule takes over the box, one piece each, with
/// the integer ITSELF as the choice at `site`.
fn rounding(
    out: *Writer(Tracked),
    x: Set(Tracked),
    site: Site,
    rule: Rounding,
) Error!Set(Tracked) {
    const cp = out.checkpoint();
    errdefer out.rollback(cp);
    for (x.pieces) |p| {
        const src = p.value;
        const box = src.range orelse {
            // A wholly undefined argument has no cell to name, so it yields
            // the one undefined alternative rather than a cell per integer.
            try emitUndefined(out, p.assignments, &.{}, site, 0);
            continue;
        };
        const cells = try cellRange(box, rule);
        try refuseIfTooMany(cells, out);
        const meta = constantImage(src);
        var k = cells.first;
        while (k <= cells.last) : (k += 1) {
            const value = Tracked.withMetadata(intInterval(k), meta.defined, meta.continuous);
            // An incoming map that already binds this site to another cell
            // has ruled this cell out. That is a proven contradiction and
            // not a reason to stop enumerating the rest.
            _ = try out.appendBound(value, p.assignments, site, k);
        }
    }
    return out.view();
}

/// Every integer `floor(x)` takes over the box, named as `rounding` does.
///
/// `floor([0.9, 1.1])` is `{0, 1}` and `floor([0.9, 2.1])` is `{0, 1, 2}`:
/// there is no two-piece cap anywhere in this file, and a box whose cell
/// count exceeds the caller's buffer is an error rather than a truncated
/// image. The incoming map is preserved and the cut is sorted into it, so a
/// piece of a forty-binding input carries forty-one bindings.
pub fn floor(out: *Writer(Tracked), x: Set(Tracked), site: Site) Error!Set(Tracked) {
    return rounding(out, x, site, .floor);
}

/// Every integer `ceil(x)` takes over the box, named as `floor` does.
pub fn ceil(out: *Writer(Tracked), x: Set(Tracked), site: Site) Error!Set(Tracked) {
    return rounding(out, x, site, .ceil);
}

/// Every integer `trunc(x)` takes over the box, named as `floor` does.
/// Toward zero on both sides, so `[-1.5, 1.5]` has three cells where `ceil`
/// has four.
pub fn trunc(out: *Writer(Tracked), x: Set(Tracked), site: Site) Error!Set(Tracked) {
    return rounding(out, x, site, .trunc);
}

/// Every integer `round(x)` takes over the box, half AWAY FROM ZERO, named
/// as `floor` does.
pub fn round(out: *Writer(Tracked), x: Set(Tracked), site: Site) Error!Set(Tracked) {
    return rounding(out, x, site, .away);
}

/// Every integer `roundTiesUp(x)` takes over the box, half toward
/// +infinity, named as `floor` does.
pub fn roundTiesUp(out: *Writer(Tracked), x: Set(Tracked), site: Site) Error!Set(Tracked) {
    return rounding(out, x, site, .ties_up);
}

/// Every integer `roundTiesDown(x)` takes over the box, half toward
/// -infinity, named as `floor` does. The three rules are the same function
/// away from a tie and three different functions at one.
pub fn roundTiesDown(out: *Writer(Tracked), x: Set(Tracked), site: Site) Error!Set(Tracked) {
    return rounding(out, x, site, .ties_down);
}

/// The mathematical sign of every point of the box: exactly the signs the box
/// reaches and no others. `sgn([-2, 3])` is `{-1, 0, 1}` and `sgn([2, 3])` is
/// `{1}`, because a box that does not reach zero has no zero alternative to
/// invent. The label IS the sign, so the three cells tell each other apart
/// without this module having allocated an identifier for them.
pub fn sgn(out: *Writer(Tracked), x: Set(Tracked), site: Site) Error!Set(Tracked) {
    const cp = out.checkpoint();
    errdefer out.rollback(cp);
    const one = Interval.init(1.0, 1.0);
    const minus_one = Interval.init(-1.0, -1.0);
    const zero = Interval.init(0.0, 0.0);
    for (x.pieces) |p| {
        const src = p.value;
        const box = src.range orelse {
            try emitUndefined(out, p.assignments, &.{}, site, 0);
            continue;
        };
        // The sign is total, so the source's definedness is all there is to
        // carry, and each cell's image is a constant.
        const meta = constantImage(src);
        switch (box.zeroSplit()) {
            .negative => try emit(out, meta, minus_one, p.assignments, &.{}, site, -1),
            .positive => try emit(out, meta, one, p.assignments, &.{}, site, 1),
            .zero => try emit(out, meta, zero, p.assignments, &.{}, site, 0),
            .touches_above => {
                try emit(out, meta, zero, p.assignments, &.{}, site, 0);
                try emit(out, meta, one, p.assignments, &.{}, site, 1);
            },
            .touches_below => {
                try emit(out, meta, minus_one, p.assignments, &.{}, site, -1);
                try emit(out, meta, zero, p.assignments, &.{}, site, 0);
            },
            .straddles => {
                try emit(out, meta, minus_one, p.assignments, &.{}, site, -1);
                try emit(out, meta, zero, p.assignments, &.{}, site, 0);
                try emit(out, meta, one, p.assignments, &.{}, site, 1);
            },
        }
    }
    return out.view();
}

/// Both signs of the value ITSELF: `x` and `-x`, at choices `+1` and `-1`,
/// so that the label IS the sign. This is the plus/minus of the value and
/// not a plus/minus square root, because that is what was asked for.
///
/// Two calls at the SAME site are the same operation on the same argument
/// and so correlate: pairing them leaves `2x` and `-2x` and no `0`. Two
/// calls at different sites are independent and every combination is live.
pub fn plusMinus(out: *Writer(Tracked), x: Set(Tracked), site: Site) Error!Set(Tracked) {
    const cp = out.checkpoint();
    errdefer out.rollback(cp);
    for (x.pieces) |p| {
        const v = p.value;
        if (v.range == null) {
            try emitUndefined(out, p.assignments, &.{}, site, 0);
            continue;
        }
        // Negation cannot change a definedness or a continuity, so the two
        // pieces carry the source's own truths unchanged.
        _ = try out.appendBound(v, p.assignments, site, 1);
        _ = try out.appendBound(v.neg(), p.assignments, site, -1);
    }
    return out.view();
}

/// `1/x`, split at zero so the gap survives.
///
/// `1/x` over `[-4, 2]` is the negative ray `[-inf, -1/4]` and the positive
/// ray `[1/2, inf]` as two alternatives, and neither contains zero. The box
/// `{0}` has no image at all, which is an EMPTY set and not an error, and a
/// box that cannot reach zero is one alternative with `defined = always`.
///
/// Neither ray may claim `defined = always` when the source box reaches
/// zero: the point `0` of that box has no image, so membership is uncertain
/// for both of them and both say so. The cell labels are `-1` and `+1`, so
/// the two rays of a sign split and the two signs of `plusMinus` are the
/// same naming convention.
pub fn recip(out: *Writer(Tracked), x: Set(Tracked), site: Site) Error!Set(Tracked) {
    const cp = out.checkpoint();
    errdefer out.rollback(cp);
    for (x.pieces) |p| {
        const src = p.value;
        const box = src.range orelse {
            try emitUndefined(out, p.assignments, &.{}, site, 0);
            continue;
        };
        switch (box.zeroSplit()) {
            .negative => {
                // The whole box avoids zero: one cell, bounded image.
                try emit(out, carried(src, true), Interval.init(1.0, 1.0).div(box), p.assignments, &.{}, site, -1);
            },
            .positive => {
                try emit(out, carried(src, true), Interval.init(1.0, 1.0).div(box), p.assignments, &.{}, site, 1);
            },
            .zero => {
                // The single point zero has no reciprocal. The alternative
                // set is empty, and that is a mathematical answer.
            },
            .touches_above => {
                // (0, hi]: the image runs away upwards at the zero end and
                // stops at 1/hi.
                try emit(out, carried(src, false), Interval.init(reciprocalPoint(box.hi).lo, pos_inf), p.assignments, &.{}, site, 1);
            },
            .touches_below => {
                try emit(out, carried(src, false), Interval.init(neg_inf, reciprocalPoint(box.lo).hi), p.assignments, &.{}, site, -1);
            },
            .straddles => {
                try emit(out, carried(src, false), Interval.init(neg_inf, reciprocalPoint(box.lo).hi), p.assignments, &.{}, site, -1);
                try emit(out, carried(src, false), Interval.init(reciprocalPoint(box.hi).lo, pos_inf), p.assignments, &.{}, site, 1);
            },
        }
    }
    return out.view();
}

/// The quotient of a positive box by a box containing zero, and of anything
/// by a denominator that vanishes in general.
///
/// The denominator cell that reaches zero makes the quotient unbounded
/// there, and the SIGN of that runaway decides which ray the cell's image
/// is; the other side is then missing from the answer, which is the gap.
/// `[-2, -1] / [-1, 0)` is `[1, inf)` and not `[-inf, inf]`, because the
/// quotient of two negatives is positive and has no sign to change as the
/// denominator approaches zero from below. A numerator that reaches zero
/// leaves the sign undecided and the cell's image is the whole line; the
/// numerator `{0}` divides to exactly zero.
///
/// Only COMPATIBLE pairs of pieces are combined, and each pair's two maps
/// are merged into the one its result carries, so a quotient cell stays
/// correlated with the operands that produced it.
pub fn div(
    out: *Writer(Tracked),
    a: Set(Tracked),
    b: Set(Tracked),
    site: Site,
) Error!Set(Tracked) {
    const cp = out.checkpoint();
    errdefer out.rollback(cp);
    for (a.pieces) |pa| {
        for (b.pieces) |pb| {
            if (!compatible(pa.assignments, pb.assignments)) continue;
            const na = pa.value;
            const db = pb.value;
            const n = na.range orelse {
                try emitUndefined(out, pa.assignments, pb.assignments, site, 0);
                continue;
            };
            const d = db.range orelse {
                try emitUndefined(out, pa.assignments, pb.assignments, site, 0);
                continue;
            };
            switch (d.zeroSplit()) {
                .negative => try emit(out, carried2(na, db, true), n.div(d), pa.assignments, pb.assignments, site, -1),
                .positive => try emit(out, carried2(na, db, true), n.div(d), pa.assignments, pb.assignments, site, 1),
                .zero => {
                    // A denominator that is exactly zero has no quotient for
                    // any numerator: an empty alternative set.
                },
                .touches_above => try emit(out, carried2(na, db, false), quotientFromAbove(n, d.hi), pa.assignments, pb.assignments, site, 1),
                .touches_below => try emit(out, carried2(na, db, false), quotientFromBelow(n, d.lo), pa.assignments, pb.assignments, site, -1),
                .straddles => {
                    try emit(out, carried2(na, db, false), quotientFromBelow(n, d.lo), pa.assignments, pb.assignments, site, -1);
                    try emit(out, carried2(na, db, false), quotientFromAbove(n, d.hi), pa.assignments, pb.assignments, site, 1);
                },
            }
        }
    }
    return out.view();
}

/// The quotient of `n` by a denominator cell `[blo, 0)` that reaches zero
/// from below, where the zero itself has no image and the quotient runs away
/// downwards there. `blo < 0`.
fn quotientFromBelow(n: Interval, blo: f64) Interval {
    if (n.lo == 0.0 and n.hi == 0.0) return Interval.init(0.0, 0.0);
    if (n.lo > 0.0) return Interval.init(neg_inf, quotientPoint(n.lo, blo).hi);
    if (n.hi < 0.0) return Interval.init(quotientPoint(n.hi, blo).lo, pos_inf);
    return Interval.init(neg_inf, pos_inf);
}

/// The mirror of `quotientFromBelow`: a denominator cell `(0, bhi]` with
/// `bhi > 0`, where the quotient runs away upwards.
fn quotientFromAbove(n: Interval, bhi: f64) Interval {
    if (n.lo == 0.0 and n.hi == 0.0) return Interval.init(0.0, 0.0);
    if (n.lo > 0.0) return Interval.init(quotientPoint(n.lo, bhi).lo, pos_inf);
    if (n.hi < 0.0) return Interval.init(neg_inf, quotientPoint(n.hi, bhi).hi);
    return Interval.init(neg_inf, pos_inf);
}

/// Every tangent cell the box reaches, one piece each, labelled by the cell
/// index `floor((theta + pi/2)/pi)` -- so a box holding two poles and the
/// zero between them has THREE cells, and not a sign bit and not two.
///
/// `tan` over `[1.5, 1.6]`, which straddles the pole at `pi/2`, gives two
/// separated rays and keeps the gap: zero is in neither of them. Every piece
/// reports `defined` and `continuous` uncertain, because the SOURCE box holds
/// a point where `tan` does not exist -- being smooth on one's own preimage
/// is not what continuity of the whole operation means. `tan` over
/// `[0.4, 0.6]`, which holds no pole, is one piece and is proved continuous,
/// so the uncertainty above is the mathematics of the pole and not a
/// standing hedge about every producer.
///
/// Cell `k` is `[max(lo, pole(k-1)), min(hi, pole(k))]`, and reaching a pole
/// is read off the certified pole ENCLOSURE. A pole that comes back wider
/// than a point therefore widens this answer and never narrows it: an
/// endpoint reported as at-or-beyond a pole gives `+/-inf` where the true
/// tangent runs away, which is a wider bound and never a wrong one. A cell
/// the box reaches only at a pole is EMPTY, and it is published as the
/// undefined alternative it is rather than dropped, since dropping it would
/// hide a cell the caller may go on to ask about.
///
/// `tangentCells` is a superset of the true labels, so an admitted cell that
/// is not really there costs one extra alternative and never a missing one.
/// Its null means the label range is not resolvable as `i128`, which is not
/// "there are none", and a cell count larger than the caller's buffer is
/// refused BEFORE the enumeration rather than after it.
pub fn tan(out: *Writer(Tracked), x: Set(Tracked), site: Site) Error!Set(Tracked) {
    const cp = out.checkpoint();
    errdefer out.rollback(cp);
    for (x.pieces) |p| {
        const src = p.value;
        const box = src.range orelse {
            try emitUndefined(out, p.assignments, &.{}, site, 0);
            continue;
        };
        // TWO REFUSALS LAND ON `error.CapacityExceeded` here, for different
        // reasons, and a caller debugging an unexpected one at a huge
        // argument would otherwise go looking for a buffer that is perfectly
        // large enough. Which fired is recorded at the line it fires on.
        //
        //   * null below is a refusal to COUNT. `tangentCells` returns null
        //     when the phase is past what the library will count --
        //     `criticalIndices` refuses above |x| < 2.552e38 -- which is
        //     never "there are no cells". The kernel's argument reduction
        //     gives up above 1.5*2^127 on the angle in the same region, so a
        //     label range there would only have produced cells that each
        //     collapse to the same proved whole range. Enumerating them
        //     would be worse than refusing.
        //   * `refuseIfTooMany` below is a refusal to FIT, and is the only
        //     one of the two that is about the caller's buffers.
        //
        // They share one error because that is the only error this module
        // has; the distinction is here rather than in the error name.
        const labels = ext_mod.tangentCells(box) orelse return error.CapacityExceeded;
        try refuseIfTooMany(.{ .first = labels.first, .last = labels.last }, out);
        // The refusal to FIT, distinguishable at this line from the refusal
        // to COUNT above: `labels` is a real, enumerable range, and what ran
        // out is the writer.

        // `labels.first - 1` and the `k += 1` below both step an i128 label,
        // and that is safe only because `criticalIndices` guards the
        // QUOTIENT at |x/pi| < 1.5*2^127/pi (8.1236e37) rather than at the
        // bare 2^127 ceiling: i128 holds 1.7014e38, so there is a factor of
        // 2.094 of room either side. At the bare ceiling the `+1` would be
        // the overflow rather than the guard. If that constant is ever
        // relaxed, this is the first thing that breaks.

        // One cell is a pole-free whole only when neither of its two
        // boundaries is a pole the box reaches.
        const only_left = ext_mod.tangentPole(labels.first - 1);
        const only_right = ext_mod.tangentPole(labels.first);
        const meta = carried(src, labels.first == labels.last and
            box.lo > only_left.hi and box.hi < only_right.lo);

        var k = labels.first;
        while (k <= labels.last) : (k += 1) {
            const left = ext_mod.tangentPole(k - 1);
            const right = ext_mod.tangentPole(k);
            const cell_lo = @max(box.lo, left.lo);
            const cell_hi = @min(box.hi, right.hi);
            if (cell_lo > cell_hi) {
                try emitUndefined(out, p.assignments, &.{}, site, k);
                continue;
            }
            const lo_bound = if (cell_lo <= left.hi)
                neg_inf
            else
                ext_mod.tan(Interval.init(cell_lo, cell_lo)).lo;
            const hi_bound = if (cell_hi >= right.lo)
                pos_inf
            else
                ext_mod.tan(Interval.init(cell_hi, cell_hi)).hi;
            try emit(out, meta, Interval.init(lo_bound, hi_bound), p.assignments, &.{}, site, k);
        }
    }
    return out.view();
}

/// A rational power of the box, as ONE alternative per input piece, with the
/// power of zero used as its cell label.
///
/// The domain question is decided here rather than left to the value,
/// because it is the branch that matters:
///
///   * A box wholly inside the domain is one alternative with `defined`
///     carried from the source: an even root of a wholly positive box, an
///     odd root of anything, an integer power of anything.
///   * An even-degree root of a box that reaches below zero has a part with
///     NO image at all. That part is clipped away and the image of the rest
///     survives with a non-negative range and `defined = maybe`, because the
///     box does contain points the operation has no value for and every
///     cell of it has to say so. A box wholly below zero has no image at
///     all and yields the undefined alternative.
///   * A NEGATIVE power of a box that reaches zero is split at zero, because
///     that is where the image has a gap and one interval cannot keep it.
///     The positive cell runs away upwards as the base approaches zero and
///     stays positive, so it is `[far end, +inf)`. On the negative half line
///     a rational power has a constant sign or no real value at all, so the
///     negative cell is one ray whose direction the far endpoint's sign
///     reports, and the two rays together leave the middle out. The point
///     zero has no image under a negative power, so the box `{0}` yields an
///     empty set.
///
/// `p.denominator` decides odd from even; a rational in lowest terms with
/// denominator one is an integer power and is defined over every real, and
/// `0/1` is `0^0 = 1` everywhere as the catalog has it.
pub fn powRational(
    out: *Writer(Tracked),
    x: Set(Tracked),
    p: Rational,
    site: Site,
) Error!Set(Tracked) {
    const cp = out.checkpoint();
    errdefer out.rollback(cp);
    std.debug.assert(p.denominator != 0);
    const even_root = p.denominator % 2 == 0;
    for (x.pieces) |piece| {
        const src = piece.value;
        const box = src.range orelse {
            try emitUndefined(out, piece.assignments, &.{}, site, 0);
            continue;
        };
        const split = box.zeroSplit();
        const reaches_zero = split != .negative and split != .positive;
        if (p.numerator < 0 and reaches_zero) {
            if (split == .zero) {
                // The single point zero under a negative power: no image.
                continue;
            }
            if (box.lo < 0.0) {
                const far = real_mod.powRational(Interval.init(box.lo, box.lo), p);
                if (negativePowerRay(far)) |ray| {
                    try emit(out, carried(src, false), ray, piece.assignments, &.{}, site, -1);
                } else {
                    // No real image on the negative half line at all.
                    try emitUndefined(out, piece.assignments, &.{}, site, -1);
                }
            }
            if (box.hi > 0.0) {
                const far = real_mod.powRational(Interval.init(box.hi, box.hi), p);
                if (far) |v| {
                    // A positive base to a real power is positive, and runs
                    // away upwards as the base approaches zero.
                    try emit(out, carried(src, false), Interval.init(v.lo, pos_inf), piece.assignments, &.{}, site, 1);
                } else {
                    try emitUndefined(out, piece.assignments, &.{}, site, 1);
                }
            }
            continue;
        }
        // A box wholly below zero under an even root has no image, and a box
        // that reaches below one keeps only its nonnegative part.
        const image = if (even_root and box.hi < 0.0)
            null
        else
            real_mod.powRational(
                if (even_root) Interval.init(@max(0.0, box.lo), box.hi) else box,
                p,
            );
        const value = image orelse {
            try emitUndefined(out, piece.assignments, &.{}, site, 0);
            continue;
        };
        try emit(out, carried(src, !even_root or box.lo >= 0.0), value, piece.assignments, &.{}, site, 0);
    }
    return out.view();
}

/// The image of a NEGATIVE base cell that reaches zero under a negative
/// rational power, given the point image at its far endpoint.
///
/// `x -> x^p` on the negative half line is continuous there or is not real
/// there at all, so where it is real its sign does not change and the
/// runaway at the zero end carries that one sign. `q` is the enclosure of
/// the value at the far endpoint: a null answer means the negative half line
/// has no real image here, and an answer that straddles zero leaves the sign
/// undecided, which is reported as the whole line rather than as a guess.
fn negativePowerRay(q: ?Interval) ?Interval {
    const v = q orelse return null;
    if (v.hi < 0.0) return Interval.init(neg_inf, v.hi);
    if (v.lo > 0.0) return Interval.init(v.lo, pos_inf);
    return Interval.init(neg_inf, pos_inf);
}

/// The INVERSE TRIGONOMETRIC branch `k` of each alternative, as chosen by the
/// caller.
///
/// `selectedBranches` is explicitly a SELECTION from the full family and
/// never a claim to be all of it: this function walks the caller's list and
/// nothing else, so an infinite family is sampled by the caller rather than
/// pretended complete here. A branch index with no solution for the given
/// argument contributes no alternative, because there is no value to name --
/// which is a different statement from dropping a live alternative, and the
/// difference is why the branch is absent rather than undefined.
///
/// The label is the branch index ITSELF, so branch `k` means branch `k`
/// however many branches were selected with it: a choice is a stable name
/// for a branch and not a position in a list. Negative indices work and are
/// not offset.
///
/// `defined` is proved only for a degenerate argument box. For a box of
/// positive width this function does not re-prove the branch's own partial
/// domain and says `maybe`, which is sound and weaker than the family can
/// do; it never claims `always` merely because a value came back.
pub fn inverseTrig(
    out: *Writer(Tracked),
    x: Set(Tracked),
    g: trig_mod.Geometry,
    f: trig_mod.Function,
    site: Site,
    selectedBranches: []const i64,
) Error!Set(Tracked) {
    const cp = out.checkpoint();
    errdefer out.rollback(cp);
    for (x.pieces) |piece| {
        const src = piece.value;
        const y = src.range orelse {
            try emitUndefined(out, piece.assignments, &.{}, site, 0);
            continue;
        };
        const family = trig_mod.inverseFamily(g, f, y);
        const meta = carried(src, y.lo == y.hi);
        for (selectedBranches) |k| {
            const branch = family.at(k) orelse continue;
            try emit(out, meta, branch, piece.assignments, &.{}, site, @as(Choice, k));
        }
    }
    return out.view();
}

/// The POSITIVE REMAINDER of `a` by `modulus`, split into the cells of the
/// shared quotient label `k = floor(a / |modulus|)`.
///
/// The label is the actual floor of the quotient, at the caller's `site`,
/// which is exactly the label `floor` writes at that same site for the same
/// quantity. A caller that computes both therefore gets them CORRELATED for
/// free: `mapBinary` pairs cell `k` of the quotient with cell `k` of the
/// remainder and refuses every other pairing, and `m*floor(q) + rem` then
/// lands back inside the box. Two different sites correlate nothing, which is
/// how a caller sees that the correlation was doing something.
///
/// The modulus is taken in MAGNITUDE, so `-17` and `17` are one operator
/// here and give the same positive remainders cell for cell. The magnitude
/// is computed before anything else, so the two runs cannot differ in the
/// last bit. Each cell's value is that cell's preimage shifted down by
/// `k*|m|` and clipped to `[0, |m|]`: the remainder of a number in cell `k`
/// IS that number minus `k*|m|`, so no preimage value is ever reported as a
/// remainder and no remainder is invented for a number of another cell.
///
/// A modulus magnitude that REACHES ZERO has no finite cell set at all --
/// the quotient is unbounded and the cells cannot be enumerated -- and a
/// modulus that is exactly zero leaves every number without a remainder. The
/// first is `error.CapacityExceeded` and the second is an empty set, because
/// one of them is a fact about the mathematics and the other about the
/// caller's buffers. A modulus of non-zero width is handled by taking the
/// union of its possible cells over the whole magnitude box, which preserves
/// every alternative rather than inventing one for a modulus the caller
/// never chose.
///
/// The remainder is continuous in the dividend for a fixed magnitude, being
/// linear on each cell, so the piece carries the source's continuity and
/// reports no jump.
pub fn mod(
    out: *Writer(Tracked),
    a: Set(Tracked),
    modulus: Set(Tracked),
    site: Site,
) Error!Set(Tracked) {
    const cp = out.checkpoint();
    errdefer out.rollback(cp);
    for (a.pieces) |pa) {
        for (modulus.pieces) |mp| {
            if (!compatible(pa.assignments, mp.assignments)) continue;
            const na = pa.value;
            const nm = mp.value;
            const n = na.range orelse {
                try emitUndefined(out, pa.assignments, mp.assignments, site, 0);
                continue;
            };
            const m = nm.range orelse {
                try emitUndefined(out, pa.assignments, mp.assignments, site, 0);
                continue;
            };
            const mag = m.abs();
            switch (mag.signOf()) {
                .negative, .positive => {},
                // Every number is without a remainder under a modulus of
                // zero, so there is nothing to name.
                .zero => continue,
                // The quotient is unbounded and its cells are not
                // enumerable, which is a fact about the caller's buffers.
                .straddle, .touches_above => return error.CapacityExceeded,
            }
            // The cells are the floor of the quotient, which is the label
            // `floor` writes at this same site for this same quantity.
            const cells = try cellRange(n.div(mag), .floor);
            try refuseIfTooMany(cells, out);
            const meta = carried2(na, nm, true);
            var k = cells.first;
            while (k <= cells.last) : (k += 1) {
                const shift = intInterval(k).mul(mag);
                const upper = intInterval(k + 1).mul(mag);
                const cell_lo = @max(n.lo, shift.lo);
                const cell_hi = @min(n.hi, upper.hi);
                const remainder = if (cell_lo > cell_hi)
                    null
                else
                    Interval.init(cell_lo, cell_hi).sub(shift).intersect(Interval.init(0.0, mag.hi));
                if (remainder) |value| {
                    try emit(out, meta, value, pa.assignments, mp.assignments, site, k);
                } else {
                    // The box reaches this cell only at its lower boundary,
                    // or the remainder left the magnitude range. The cell is
                    // kept as the undefined alternative it is.
                    try emitUndefined(out, pa.assignments, mp.assignments, site, k);
                }
            }
        }
    }
    return out.view();
}