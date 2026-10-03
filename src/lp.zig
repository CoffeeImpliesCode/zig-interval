//! Fourier-Motzkin elimination for linear constraints whose coefficients,
//! and whose right-hand sides, are intervals rather than points.
//!
//! Every derived bound goes through the rigorous `Interval` methods, so a
//! result is always a guaranteed superset of the true feasible set: widening
//! outward can only enlarge the answer, never clip a real solution.
//!
//! Constraints are stored normalised. `a . x  <=  r` is the only internal
//! shape, so `Lin` carries no comparison field at all: there is nothing on a
//! stored row for one to say. It used to carry one that always read back
//! `.le`, which was a write door into the solver's own storage on which
//! every value but one was a lie.
//!
//!   * `eq` is exactly the conjunction of `le` and `ge`, so it is stored as
//!     two rows, `(a, .le, r)` and `(-a, .le, -r)`.
//!   * `ge` and `gt` are stored flipped, `a . x >= r`  <=>  `-a . x <= -r`.
//!   * `lt` and `gt` are relaxed to `le` and `ge`. A closed interval cannot
//!     represent a strict inequality, and relaxing is the only direction that
//!     keeps the promise of a superset: keeping `a . x > r` would need an open
//!     interval, which this library does not have.
//!
//! Sign normalisation routes through `Interval.neg`, which is exact: IEEE
//! negation flips one sign bit, so the image of [lo, hi] is precisely
//! [-hi, -lo] and no ULP is added. That exactness is load-bearing. A widened
//! negation would turn every exact `0.0` coefficient into a thin straddle
//! around zero, and a straddle is read as a two-sided bound, so it would
//! corrupt every projection of a constraint that merely fails to mention a
//! variable.
//!
//! The rule that splits a row by the sign of its `x_k` coefficient is
//! written down once, in `System.partition`, and every consumer reads it
//! there: `eliminate` builds the rows, `bounds` reads the bounds off them,
//! `derivesContradiction` asks the same question without building them,
//! `pairCount` costs a variable by them, and the benchmark harness's
//! row-budget gate predicts a round with them. Five copies of a soundness
//! rule is five chances to write four of them, and the copy whose job is
//! to catch the fifth agreeing with itself catches nothing.
//!
//! A coefficient of exactly [0, 0] is structural: it means the row does not
//! mention that variable. It stays exactly [0, 0] all the way through
//! elimination, which `appendCombined` arranges by taking the exact branches
//! of the combination when either factor is a structural zero. The general
//! form would hand the zero to the outward widening, and a subnormal
//! straddle is not the same statement as an absent variable: later rounds
//! would read it as a bound from both sides and pair rows that share no
//! variable at all.
//!
//! The general form reaches that same straddle by a second route,
//! cancellation: two equal products subtracted from one another, each of them
//! already widened on the way in. `lp_exact.combinedColumn` decides that
//! case on the operands rather than on the widened products, in `f128` where
//! the question has an exact answer, and writes the structural zero when the
//! exact coefficient is zero.
//!
//! THAT DECISION IS NOT IN THIS FILE. The whole exact block moved to
//! `lp_exact.zig`, which names no allocator and takes a `Side` rather than a
//! `Part`, and the reason is that it could not be tested on its own here:
//! while it sat in this file the only way to reach it was through a
//! `System`, so every question about it had to be paid for with an
//! allocated system, a set of added rows, and an elimination driven until
//! the operands happened to appear. What is left in this file is the
//! memory, the rule, and the arithmetic over that rule.

const std = @import("std");

const Interval = @import("interval.zig").Interval;

/// The exact arithmetic: `combinedColumn`, `combinedBound`,
/// `cancelsExactly`, and the predicates they rest on. Aliased rather than
/// copied, so every caller here reaches the one decision rather than a
/// second reading of it.
const exact = @import("lp_exact.zig");

/// The degenerate interval written into a combined row for the eliminated
/// index. The two `x_k` terms cancel analytically, so the exact zero is the
/// truthful value; anything else would leave a rounding-thin straddle behind
/// that later reads as a bound on a variable that no longer appears.
///
/// Published by `lp_exact`, the block that also writes it, and aliased
/// rather than repeated here so that "the structural zero" has one answer in
/// the tree: `appendCombined` writes it into the eliminated column and
/// `combinedColumn` writes it into a column no row mentions.
const zero = exact.zero;

/// Comparison requested by the caller. The shape a tag is STORED in is not
/// the shape it was asked for, and a caller that counts rows has to know
/// which, so the mapping is written out per tag here rather than left to the
/// module comment:
///
///   * `le` is stored as asked: ONE row, `(a, .le, r)`.
///   * `lt` is RELAXED to `le` on insert and stored as asked, so it is also
///     one row, `(a, .le, r)`. A closed interval cannot represent a strict
///     inequality, and relaxing is the only direction that keeps the
///     promise of a superset.
///   * `ge` is stored FLIPPED, one row, `(-a, .le, -r)`.
///   * `gt` takes both normalisations and is stored exactly as `ge` is:
///     relaxed, then flipped, one row, `(-a, .le, -r)`.
///   * `eq` is stored as TWO rows, `(a, .le, r)` and `(-a, .le, -r)`, so
///     `add` moves `rowCount` by two for it. It is the only tag that
///     duplicates, and the only one whose `add` is not atomic.
pub const Cmp = enum { le, lt, ge, gt, eq };

/// One linear constraint row, borrowed from a `System`.
///
/// `coeffs` has one entry per variable and points into the system's own
/// storage: it is invalidated by the next `add` or `eliminate`, and freed by
/// `deinit`.
///
/// It is a `[]const` because the row is a VIEW. A caller who writes through
/// it edits the solver's own coefficients in place, and that changes what
/// `bounds`, `box` and `isUnsat` answer — silently, with nothing thrown and
/// nothing logged. One assignment to a coefficient of a row from `at` was
/// measured turning `bounds(0)` from a real interval into `null` while
/// `isUnsat()` still said no: a solver that had proved a projection unbounded
/// reported it as proven. There is no runtime guard for that here, because the
/// type is the guard and the compiler is the one that raises it.
///
/// A coefficient is UNIVERSAL and a right-hand side is EXISTENTIAL, and
/// the difference decides what a projection may legitimately conclude. A
/// row reads: for EVERY realisation of the coefficient intervals, the
/// linear form is at most SOME ONE unknown value drawn from `rhs`. So a
/// derived bound is widened outward rather than taken at the convenient
/// end of a coefficient, which is why a coefficient that merely REACHES
/// zero still bounds its variable -- read off the endpoint farthest from
/// zero. `rhs` is the envelope of a single bound value, not a family, so
/// only its `hi` can prove a contradiction.
///
/// Reading the right-hand side as universal instead is the mistake that
/// makes a projection come back too small, and a system reported
/// unsatisfiable that is not.
pub const Lin = struct {
    coeffs: []const Interval,
    rhs: Interval,
};

/// A constraint row together with the piece of its `x_k` coefficient that
/// plays one role in the pairing. `lower` entries carry a non-positive
/// coefficient, `upper` entries a non-negative one, and a coefficient
/// that reaches zero appears in both lists carrying a different piece each
/// time.
///
/// `pub` because `System.partition` hands these out in a `Partition` and a
/// caller has to be able to say what it is holding.
pub const Part = struct {
    coeff: Interval,
    row: Lin,
};

/// The exact block's view of one side of a pairing, built from a `Part`.
///
/// `lp_exact` names no solver type, and this is the one place the solver's
/// `Part` is flattened into the block's `Side`: the multiplier piece, the
/// row's coefficients and the row's right-hand side, which is everything the
/// block reads and nothing that it does not. `Lin` carries a slice the system
/// owns, so a struct that named one would have dragged that ownership across
/// with it, and the block would be reachable only by building the thing it
/// is separable from.
fn sideOf(part: Part) exact.Side {
    return .{
        .coeff = part.coeff,
        .coeffs = part.row.coeffs,
        .rhs = part.row.rhs,
    };
}

/// One round's rows, split by the sign of their `x_k` coefficient.
///
/// `carried` holds the rows that do not mention the variable and pass
/// through the round untouched; `lower` and `upper` are the two halves of
/// the pairing, and each entry carries the piece of its own coefficient
/// that plays that role.
///
/// The three slices are owned and must be released with `deinit`. Every
/// `Lin` inside them is BORROWED from the system the partition came from,
/// so that system has to outlive the partition.
pub const Partition = struct {
    /// The allocator `deinit` frees the three lists through, and it has to
    /// be the allocator they were built with. The `DynVec` pattern, for the
    /// same reason it is one there: a value that stores the allocator it
    /// owns memory with frees through that field, so a `Partition` whose
    /// `gpa` is not the one its slices came from hands another allocator a
    /// pointer it never returned.
    gpa: std.mem.Allocator,
    carried: []Lin,
    lower: []Part,
    upper: []Part,

    /// Release the three lists. The borrowed rows are untouched.
    ///
    /// NOT IDEMPOTENT, AND NOT SAFE ON A COPY (L14). A `Partition` copied by
    /// value is two owners of one set of slices, and the second `deinit` is
    /// a double free. The value moves, it does not copy; nothing here can
    /// detect the mistake, so it is stated instead.
    pub fn deinit(self: Partition) void {
        self.gpa.free(self.carried);
        self.gpa.free(self.lower);
        self.gpa.free(self.upper);
    }

    /// Exactly how many rows eliminating the partitioned variable leaves
    /// behind: one per carried row and one per lower/upper pair. Exact, not
    /// an estimate, because it is the length of the solver's own buckets.
    pub fn rowsProduced(self: Partition) usize {
        return self.carried.len + self.lower.len * self.upper.len;
    }
};

/// A row as the final round of `bounds` would use it: the piece of its `x_k`
/// coefficient that plays one role in the pairing, the row itself, and the
/// two facts about them that cost a single pass to establish.
///
/// `flat` says the row is the exact [0, 0] in every column except `k`, and
/// `Cand.exact` says the multiplier is the exact [0, 0]. Neither is a
/// property of the row alone: `Cand.exact` is about the piece, which for a
/// straddling coefficient is a different interval in each of the two
/// buckets.
const Cand = struct {
    coeff: Interval,
    row: Lin,
    flat: bool,
    exact: bool,
};

/// A `Cand` for one bucket. The `exact` field is derived rather than passed,
/// so a candidate cannot claim a multiplier is the exact zero when it is not;
/// the derivation is `lp_exact`'s, because that module owns the question.
fn candidate(coeff: Interval, row: Lin, flat: bool) Cand {
    return .{ .coeff = coeff, .row = row, .flat = flat, .exact = exact.isExactZero(coeff) };
}

/// Where `partitionInto` puts each row it classifies.
///
/// The rule is written once, in `partitionInto`, and what a caller does
/// with a row afterwards is the caller's own business. `Buckets` STORES
/// the two side lists and has two shapes for the carried rows:
/// `partition` collects them into a third list and hands all three back,
/// while `eliminate` points the sink at the output tables it is building
/// and a carried row is written into them as it goes past. The other sinks
/// only COUNT or READ what they are handed, and that is why they exist
/// rather than a call to `partition` followed by a walk over what it
/// built: `pairCount` runs once per live variable in every round of every
/// sweep, `bounds` answers a projection, and the benchmark's row-budget
/// gate runs inside the timed region of every elimination it measures. A
/// question whose answer is two integers must not cost three allocations
/// to ask, and a projection must not pay to store rows it reads one at a
/// time.
/// The caller's two output tables, when a round appends its carried rows
/// through instead of collecting them. Borrowed for the life of the round;
/// the memory stays the caller's, as `Buckets` never owns it.
const Passthrough = struct {
    coeffs: *std.ArrayList(Interval),
    rhs: *std.ArrayList(Interval),
};

const Buckets = struct {
    gpa: std.mem.Allocator,
    /// Rows that do not mention the variable. Stays empty when the
    /// passthrough is set, because those rows are already in the caller's
    /// output tables and are not to be kept anywhere else.
    carried: std.ArrayList(Lin) = .empty,
    lower: std.ArrayList(Part) = .empty,
    upper: std.ArrayList(Part) = .empty,
    /// Where a carried row goes instead of into `carried`. Null collects.
    /// Both halves or neither: a round that has nowhere to write the right
    /// side of a row has nowhere to write the left side either, so the two
    /// are one field and not two optionals that could disagree.
    passthrough: ?Passthrough = null,
    /// How many rows were carried, whether they were stored or written
    /// through. `carried.items.len` cannot answer it once the passthrough
    /// is set, and the reservation a round makes needs it either way.
    carried_count: usize = 0,

    /// Reserve the worst case: each list takes at most `n` entries, and
    /// reserving is what keeps a round from paying O(log rows)
    /// reallocations that each copy everything built so far.
    fn init(gpa: std.mem.Allocator, n: usize) !Buckets {
        var self: Buckets = .{ .gpa = gpa };
        try self.carried.ensureTotalCapacity(gpa, n);
        errdefer self.deinit();
        try self.lower.ensureTotalCapacity(gpa, n);
        try self.upper.ensureTotalCapacity(gpa, n);
        return self;
    }

    /// The same, except that a carried row is APPENDED to the caller's two
    /// output tables instead of being collected. The side lists are still
    /// stored, because a pairing needs both halves at once.
    fn initRound(
        gpa: std.mem.Allocator,
        coeffs: *std.ArrayList(Interval),
        rhs: *std.ArrayList(Interval),
        n: usize,
    ) !Buckets {
        var self: Buckets = .{ .gpa = gpa, .passthrough = .{ .coeffs = coeffs, .rhs = rhs } };
        errdefer self.deinit();
        try self.lower.ensureTotalCapacity(gpa, n);
        try self.upper.ensureTotalCapacity(gpa, n);
        return self;
    }

    /// Release the three lists and leave the receiver unusable.
    ///
    /// The `undefined` is an invalidation, not a check: a second `deinit`
    /// through it reads memory this call wrote over, which is undefined
    /// behaviour and may or may not trap. What it removes is the state a
    /// `Buckets` whose three `ArrayList`s were `.empty` would read as a live
    /// one, so reaching this twice is a bug rather than a shape the code is
    /// willing to carry. The same idiom `System.deinit` below uses, for the
    /// same reason.
    fn deinit(self: *Buckets) void {
        self.carried.deinit(self.gpa);
        self.lower.deinit(self.gpa);
        self.upper.deinit(self.gpa);
        self.* = undefined;
    }

    fn addCarried(self: *Buckets, row: Lin) !void {
        if (self.passthrough) |out| {
            try out.coeffs.appendSlice(self.gpa, row.coeffs);
            try out.rhs.append(self.gpa, row.rhs);
        } else {
            try self.carried.append(self.gpa, row);
        }
        self.carried_count += 1;
    }

    fn addLower(self: *Buckets, part: Part) !void {
        try self.lower.append(self.gpa, part);
    }

    fn addUpper(self: *Buckets, part: Part) !void {
        try self.upper.append(self.gpa, part);
    }

    /// How many rows the round this bucketing came from leaves behind: one
    /// per carried row and one per side pair.
    fn rows(self: Buckets) usize {
        return self.carried_count + self.lower.items.len * self.upper.items.len;
    }

    /// Hand the three lists over to the caller. Each is emptied on the way,
    /// so the `deinit` an error path still runs has nothing left to free.
    /// Only meaningful on a collecting sink: a round's output tables belong
    /// to the caller already, and there is nothing to hand over.
    fn release(self: *Buckets) !Partition {
        const carried = try self.carried.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(carried);
        const lower = try self.lower.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(lower);
        return .{
            .gpa = self.gpa,
            .carried = carried,
            .lower = lower,
            .upper = try self.upper.toOwnedSlice(self.gpa),
        };
    }
};

/// Counts the buckets without storing one of them.
const Tally = struct {
    carried: usize = 0,
    lower: usize = 0,
    upper: usize = 0,

    fn addCarried(self: *Tally, _: Lin) !void {
        self.carried += 1;
    }

    fn addLower(self: *Tally, _: Part) !void {
        self.lower += 1;
    }

    fn addUpper(self: *Tally, _: Part) !void {
        self.upper += 1;
    }

    /// How many rows eliminating `k` leaves behind: one per carried row and
    /// one per pair.
    fn rows(self: Tally) usize {
        return self.carried + self.lower * self.upper;
    }

    /// How many PAIRS, which is what the heuristic ranks variables by and
    /// what `rows` is not: a row that does not mention the variable costs
    /// one row and no pair at all.
    fn pairs(self: Tally) usize {
        return self.lower * self.upper;
    }
};

/// Reads both sides of a projection as the rows go past.
///
/// This is `bounds`' half of the round. A row that does not mention the
/// variable bounds nothing in either direction and is dropped; a lower
/// piece that does not reach below zero bounds nothing from below, and an
/// upper piece that does not reach above zero bounds nothing from above.
/// What a piece is DIVIDED by is `lp_exact.boundDivisor`'s question, and the
/// reason it cannot be the piece itself is that function's doc gives.
const BoundReader = struct {
    lower: ?f64 = null,
    upper: ?f64 = null,

    fn addCarried(_: *BoundReader, _: Lin) !void {}

    fn addLower(self: *BoundReader, part: Part) !void {
        if (!(part.coeff.lo < 0)) return;
        const q = part.row.rhs.div(exact.boundDivisor(sideOf(part)));
        self.lower = if (self.lower) |v| @max(v, q.lo) else q.lo;
    }

    fn addUpper(self: *BoundReader, part: Part) !void {
        if (!(part.coeff.hi > 0)) return;
        const q = part.row.rhs.div(exact.boundDivisor(sideOf(part)));
        self.upper = if (self.upper) |v| @min(v, q.hi) else q.hi;
    }
};

/// Fills the two candidate runs `derivesContradiction` scans.
///
/// `lower` occupies `0..lower_len` and `upper` `n..n + upper_len`, and
/// neither run can reach the other: a row contributes at most one entry to
/// each bucket, so each length is at most `n` and `2 * n` is enough.
const CandWriter = struct {
    cands: []Cand,
    n: usize,
    k: usize,
    lower_len: usize = 0,
    upper_len: usize = 0,

    fn addCarried(_: *CandWriter, _: Lin) !void {}

    fn addLower(self: *CandWriter, part: Part) !void {
        self.cands[self.lower_len] = candidate(part.coeff, part.row, exact.isFlatApartFrom(part.row.coeffs, self.k));
        self.lower_len += 1;
    }

    fn addUpper(self: *CandWriter, part: Part) !void {
        self.cands[self.n + self.upper_len] = candidate(
            part.coeff,
            part.row,
            exact.isFlatApartFrom(part.row.coeffs, self.k),
        );
        self.upper_len += 1;
    }
};

/// A linear constraint system over interval-valued coefficients.
///
/// Storage comes from the caller's allocator and the caller owns the
/// lifetime. Coefficients live in one row-major array, `var_count` entries
/// per row.
pub const System = struct {
    /// Everything a fallible method on this type can report, published as
    /// one named set rather than an inferred union per method, so a caller
    /// writes the name once and has one place to look.
    ///
    /// THE TRADEOFF IS THAT THE SET IS SHARED. `add` cannot report
    /// `error.BadRow` and `at` cannot report `error.OutOfMemory`, so every
    /// signature below is wider than the arms its own body can reach, and an
    /// exhaustive `switch` on the error of a call carries one arm that
    /// cannot fire. That is the price of the one name; what it buys is a
    /// caller that never has to spell an inferred union, and a tree in which
    /// the set of failures is written down once.
    pub const Error = error{ OutOfMemory, BadRow, BadVariableCount, BadVariable, VariableEliminated };

    /// The allocator every buffer is taken from and freed through, and it
    /// has to be the allocator `init` was given. The `DynVec` pattern, for
    /// the reason it is one there: a value that stores the allocator it owns
    /// memory with frees through that field, so a system whose `gpa` is not
    /// the one its buffers came from hands another allocator pointers it
    /// never returned.
    gpa: std.mem.Allocator,
    var_count: usize,
    coeffs: std.ArrayList(Interval),
    rhs: std.ArrayList(Interval),
    /// One liveness flag per variable, allocated by `init` and cleared by
    /// `eliminate` as it takes each variable away. It is the only gate on
    /// `error.VariableEliminated`: a second elimination of the same variable
    /// finds its flag false and is refused, rather than running a round that
    /// pairs every remaining row against a variable that is not there. The
    /// rest of the file reads the same slice rather than asking `eliminate`,
    /// so a variable that is not live is invisible to the arithmetic and not
    /// merely unusable: `chooseNext` skips it, `bounds` does not sweep it,
    /// and `box` answers null for a system that has lost one.
    alive: []bool,
    unsat: bool,

    /// Empty system over `var_count` variables.
    ///
    /// Allocating the liveness flags is the one fallible step in building a
    /// system, and it is reported like every other allocation in this file
    /// rather than panicked. It used to be the only allocator call here that
    /// could not fail visibly, which meant a program that wanted to handle
    /// exhaustion instead of dying had no way to ask for that.
    pub fn init(gpa: std.mem.Allocator, var_count: usize) Error!System {
        const flags = try gpa.alloc(bool, var_count);
        errdefer gpa.free(flags);
        @memset(flags, true);
        return .{
            .gpa = gpa,
            .var_count = var_count,
            .coeffs = .empty,
            .rhs = .empty,
            .alive = flags,
            .unsat = false,
        };
    }

    /// Release every buffer. The system is unusable afterwards.
    ///
    /// NOT IDEMPOTENT, AND NOT SAFE ON A COPY (L14). A system copied out by
    /// value shares every buffer with the original, so a `deinit` on each of
    /// them frees the same memory twice. The system moves, it does not copy;
    /// passing it by value to a method that only reads it is fine, and
    /// storing a second owner of it is not.
    pub fn deinit(self: *System) void {
        self.coeffs.deinit(self.gpa);
        self.rhs.deinit(self.gpa);
        self.gpa.free(self.alive);
        self.* = undefined;
    }

    /// Number of variables. Fixed for the life of the system.
    pub fn varCount(self: System) usize {
        return self.var_count;
    }

    /// Number of stored ROWS, after normalisation — not the number of
    /// constraints. A row added as `eq` is stored as two, so three
    /// constraints of which one is an `eq` answer 4 here.
    ///
    /// The name says rows because that is what is counted. A caller asking
    /// "how big is this system?" and being told the row count has to know the
    /// normalisation to use the number, and `gt` and `lt` are relaxed rather
    /// than duplicated, so the inflation is specifically from equalities and
    /// its factor cannot be predicted from the input count.
    pub fn rowCount(self: System) usize {
        return self.rhs.items.len;
    }

    /// Borrowed view of row `i`. Invalidated by the next mutation.
    ///
    /// `i` must be below `rowCount()`, and anything else is `error.BadRow`. The
    /// check is not decoration: the slice below is built by arithmetic, so an
    /// unchecked `i` reads whatever the allocator left past the rows, and
    /// ReleaseFast and ReleaseSmall both elide the slicing assertion that
    /// would otherwise stop it.
    ///
    /// The view is `const`. Writing to `row.coeffs` does not compile, and
    /// there is no `.op` to write to at all.
    pub fn at(self: System, i: usize) Error!Lin {
        if (i >= self.rhs.items.len) return error.BadRow;
        const start = i * self.var_count;
        return .{
            .coeffs = self.coeffs.items[start..][0..self.var_count],
            .rhs = self.rhs.items[i],
        };
    }

    /// True once a row with an all-zero coefficient vector has been ADDED OR
    /// DERIVED whose right-hand side cannot be met. Both count, and they are
    /// the same check on the same row: `checkRowForContradiction` reads
    /// `rhs.hi < 0` on an all-zero row, and what differs is only the scan.
    /// `pushRow` runs it on the one row `add` has just inserted, so a
    /// constraint a caller wrote as all zeros with a negative right-hand
    /// side latches the flag before a single variable has been eliminated,
    /// and `eliminate` rescans the whole finished round through the same
    /// function. A system whose rows only conflict in COMBINATION still
    /// answers false here until the elimination that combines them.
    ///
    /// The flag is LATCHED. Nothing clears it, so once it is set `bounds`
    /// answers null for every variable and `eliminateInOrderOfChoice`
    /// answers false, and the answer does not depend on what the caller does
    /// to the rows afterwards.
    pub fn isUnsat(self: System) bool {
        return self.unsat;
    }

    /// Add a constraint. `coeffs` is copied, so the caller keeps its slice.
    /// `coeffs.len` must equal `varCount()`.
    ///
    /// THE FLIP IS ALLOCATED BEFORE EITHER ROW IS STORED, WHICH IS WHAT
    /// MAKES A REFUSED `eq` LEAVE NOTHING BEHIND. The `ge` arm has always
    /// allocated its flipped copy first; the `eq` arm stored `(a, .le, r)`
    /// and flipped afterwards, so the one allocation that could fail failed
    /// with half a constraint already in the system. Both arms allocate
    /// first now, and a heap that refuses the flip refuses the whole `add`:
    /// the caller sees `error.OutOfMemory` and a system whose `rowCount` and
    /// `isUnsat` are exactly what they were.
    ///
    /// WHAT IS LEFT IS THE SECOND `pushRow`, AND A CALLER HAS TO KNOW IT. Its
    /// own allocations can fail with the first row of the equality already
    /// stored, so an `eq` that answers `error.OutOfMemory` may have committed
    /// one row: `rowCount` has risen by one rather than by two, the system
    /// holds one half of a constraint, and because `pushRow` latches `unsat`
    /// on insert that half can have latched it too — a system reporting
    /// unsatisfiable on the strength of a row the caller was just told had
    /// not been added. There is no all-or-nothing `add` here and the residue
    /// is named rather than smoothed over: a caller that cannot tolerate
    /// either rebuilds the system and replays what it had, and one that can
    /// reads `rowCount` after a failed `add` instead of assuming the row set
    /// is untouched.
    pub fn add(self: *System, coeffs: []const Interval, op: Cmp, rhs: Interval) Error!void {
        if (coeffs.len != self.var_count) return error.BadVariableCount;
        switch (op) {
            .le, .lt => try self.pushRow(coeffs, rhs),
            .ge, .gt => {
                const flipped = try self.flip(coeffs);
                defer self.gpa.free(flipped);
                try self.pushRow(flipped, rhs.neg());
            },
            .eq => {
                const flipped = try self.flip(coeffs);
                defer self.gpa.free(flipped);
                try self.pushRow(coeffs, rhs);
                try self.pushRow(flipped, rhs.neg());
            },
        }
    }

    /// Every row of this system split by the sign of its `x_k` coefficient,
    /// with each side row carrying the piece of its own coefficient that
    /// plays that role. THIS IS THE ONE PLACE THAT RULE IS WRITTEN.
    ///
    /// `eliminate` builds the rows from these lists, `bounds` reads the
    /// bounds off them, `derivesContradiction` asks the same question
    /// without building them, `pairCount` costs a variable by them, and
    /// `bench/bench_lp.zig` predicts a round with them, because that
    /// prediction is a machine-safety limit and a gate which restated the
    /// rule could agree with itself while disagreeing with the solver. One
    /// rule, five readers, and none of them can drift because none of them
    /// re-derives anything.
    ///
    /// THE RULE. A coefficient entirely below zero joins `lower`, one
    /// entirely above joins `upper`, and an exact [0, 0] is STRUCTURAL -
    /// the row does not mention the variable at all - so it is carried
    /// through untouched in `carried`. A coefficient that REACHES ZERO
    /// joins BOTH side lists, carrying its negative piece into `lower` and
    /// its positive piece into `upper`.
    ///
    /// THE REACHING-ZERO ROW GOES IN TWICE, AND THAT IS THE SOUNDNESS
    /// GUARANTEE. A coefficient interval is universal: the same row bounds
    /// `x_k` from below for its negative realisations and from above for
    /// its positive ones, and no single pairing is right for both. Leaving
    /// such a row out of one list would discard a real constraint and CUT
    /// THE FEASIBLE SET, which is the one thing this library must never do.
    /// Each piece multiplies the opposite list by a non-negative factor,
    /// so the `<=` direction survives and every derived row holds for every
    /// realisation of the coefficients. The cost is duplicate constraints
    /// and a looser answer; the benefit is that the answer is always a
    /// superset of the truth. Do not deduplicate this, do not cap it, do
    /// not "optimise" it away: every row it removes is a solution the
    /// library would stop being able to certify.
    ///
    /// THE EXACT ZERO IS READ FIRST AND IS NOT A STRADDLE. `[0, 0]` and
    /// `[0.0, -0.0]` both reach zero, and so does `[0, mag]`, so an arm
    /// ordered on reaching zero ALONE would file a row that says nothing
    /// about `x_k` as a constraint from both sides and pair it against rows
    /// that share no variable with it. Only this arm may drop a row from
    /// the pairing, and that is the whole of what its position buys.
    ///
    /// WHAT A NaN ENDPOINT ANSWERS, AND WHY THIS IS `Interval.signOf` AND
    /// NOT A PRIVATE COPY OF IT. The two spellings agree on every
    /// well-formed interval and disagree on exactly one input, an endpoint
    /// that is not a number, and the disagreement is the entire content of
    /// this paragraph. The partition needs to know whether a coefficient
    /// REACHES ZERO, because reaching zero is the only reason the second
    /// list exists, and `Interval.signOf` is the function that states that
    /// property and explains it: a poison compares false in every
    /// direction, so an arm ending in a bare `return .straddle` reports a
    /// poisoned interval as reaching zero when it reaches nothing at all.
    ///
    /// Filing it as reaching zero here would not be a mislabel either, it
    /// would be a corrupt part. The arm below derives its two pieces
    /// through `@min` and `@max`, which are specified to answer with the
    /// non-NaN operand, so from `[-5, NaN]` the lower piece comes out as
    /// the perfectly well-formed `[-5, 0]` with the poison silently gone,
    /// and a caller reading that list sees a constraint where none exists.
    /// A classifier whose own answer runs arithmetic on the operand cannot
    /// be trusted to have classified correctly. Under `Interval.signOf` a
    /// poison enters ONE list, carried through unchanged, and the first
    /// `Interval.init` that meets it rejects it and names the operand. That
    /// is the pinned NaN contract arriving through the back door, not a
    /// fourth case to compute.
    ///
    /// `k` must be below `varCount()`, and anything else is
    /// `error.BadVariable`. An eliminated `k` is not rejected: its column
    /// is an exact [0, 0] in every row by then, so the answer is every row
    /// in `carried` and no pairs, which is what eliminating it again would
    /// have produced.
    ///
    /// The sink is the caller's business and this function is the whole
    /// rule. One of the sinks below STORES the three lists, and that is
    /// what `partition` hands back and what `eliminate` builds rows from.
    /// The other three only COUNT or READ what they are handed, and that is
    /// why they are here rather than three calls to `partition` followed by
    /// a walk over what it built: `pairCount` runs once per live variable
    /// in every round of every sweep, `bounds` answers a projection, and
    /// the benchmark's row-budget gate runs inside the timed region of
    /// every elimination it measures. A question whose answer is two
    /// integers must not cost three allocations to ask.
    fn partitionInto(self: System, k: usize, sink: anytype) !void {
        if (k >= self.var_count) return error.BadVariable;
        for (0..self.rowCount()) |i| {
            const row = try self.at(i);
            const a = row.coeffs[k];
            switch (a.signOf()) {
                .zero => try sink.addCarried(row),
                .negative => try sink.addLower(.{ .coeff = a, .row = row }),
                .positive => try sink.addUpper(.{ .coeff = a, .row = row }),
                // `signOf` has already established `lo <= 0 <= hi` and that
                // the pair is not the point zero, so both pieces reach
                // exactly zero and neither needs a comparison of its own.
                .straddle => {
                    try sink.addLower(.{ .coeff = Interval.init(a.lo, @min(a.hi, 0.0)), .row = row });
                    try sink.addUpper(.{ .coeff = Interval.init(@max(a.lo, 0.0), a.hi), .row = row });
                },
            }
        }
    }

    /// The three lists this rule produces, owned by the caller, for a
    /// caller that needs the rows themselves rather than their count. Every
    /// `Lin` inside is borrowed from `self`, which has to outlive the
    /// `Partition`; `deinit` frees the three lists and nothing else.
    pub fn partition(self: System, k: usize) Error!Partition {
        if (k >= self.var_count) return error.BadVariable;
        var buckets = try Buckets.init(self.gpa, self.rowCount());
        errdefer buckets.deinit();
        try self.partitionInto(k, &buckets);
        return buckets.release();
    }

    /// Exactly how many rows eliminating `k` would leave behind: one per
    /// row that does not mention `k`, plus one per lower/upper pair.
    /// Exact, not an estimate, because it is the solver's own buckets
    /// counted.
    ///
    /// This is the question a caller asks BEFORE it commits to a round, and
    /// `bench/bench_lp.zig` asks it on every elimination it drives, inside
    /// the timed region of each one. It counts rather than building the
    /// lists `partition` returns, so the check costs no allocation and no
    /// copy of the rows; the rule it reads is that same rule either way,
    /// which is the only part the gate was ever for.
    pub fn rowsAfterEliminating(self: System, k: usize) Error!usize {
        var tally: Tally = .{};
        try self.partitionInto(k, &tally);
        return tally.rows();
    }

    /// Fourier-Motzkin elimination of variable `k`.
    ///
    /// The rows are bucketed by the rule `partition` publishes, and every
    /// `lower` entry combines with every `upper` entry. The result is the
    /// carried rows followed by the combined ones. When one of the two side
    /// lists is empty the other has no partner, and pushing `x_k` towards
    /// the opposite infinity makes those rows vacuous, so they drop out;
    /// that is exactly what the same formula yields.
    ///
    /// A carried row is APPENDED to the two output tables as it goes past,
    /// not collected into a list and copied out of it afterwards. That is
    /// the one place this method does not go through `partition` as
    /// published, and the reason is that a carried row is not something to
    /// be kept: it is the next row of the round. Collecting it first costs
    /// an allocation the size of the whole row set and a second pass over
    /// every row that says nothing about the variable, and the row sets
    /// here reach tens of thousands. The rule read is the same one, out of
    /// the same function.
    pub fn eliminate(self: *System, k: usize) Error!void {
        if (k >= self.var_count) return error.BadVariable;
        if (!self.alive[k]) return error.VariableEliminated;

        const gpa = self.gpa;
        const vc = self.var_count;

        var coeffs: std.ArrayList(Interval) = .empty;
        errdefer coeffs.deinit(gpa);
        var rhs: std.ArrayList(Interval) = .empty;
        errdefer rhs.deinit(gpa);

        var buckets = try Buckets.initRound(gpa, &coeffs, &rhs, self.rowCount());
        defer buckets.deinit();
        try self.partitionInto(k, &buckets);

        // The final length of both output tables is decided by the buckets:
        // one row per carried-through row, one per pair, and `var_count`
        // coefficients per row. Reserving that here replaces the geometric
        // regrowth, which is O(log rows) reallocations each copying
        // everything built so far, with a single allocation. The row counts
        // these systems reach are tens of thousands, where that copying is
        // not a detail: a straddling system grows 11 -> 121 -> 14,641, and
        // the last of those steps recopies everything before it four times
        // over on the way.
        //
        // `buckets.rows()` counts the pairs exactly the way the loop below
        // appends, so the reservation can never be short of what that loop
        // writes. A count so large that `rows * var_count` wraps falls back
        // to the geometric growth instead of reserving a wrapped number:
        // unreachable on any allocatable system, but a reservation must
        // never be the thing that turns "impossible" into "truncated".
        const out_rows = buckets.rows();
        if (std.math.mul(usize, out_rows, vc)) |out_coeffs| {
            try coeffs.ensureTotalCapacity(gpa, out_coeffs);
            try rhs.ensureTotalCapacity(gpa, out_rows);
        } else |_| {}

        for (buckets.lower.items) |l| {
            for (buckets.upper.items) |u| {
                try appendCombined(gpa, &coeffs, &rhs, l, u, k, vc);
            }
        }

        self.coeffs.deinit(gpa);
        self.rhs.deinit(gpa);
        self.coeffs = coeffs;
        self.rhs = rhs;
        self.alive[k] = false;
        try self.rescanForContradiction();
    }

    /// The elimination order Tupper's heuristic chooses, as a caller-owned
    /// slice that must be freed with the system's allocator.
    ///
    /// This is Tupper's variable-selection heuristic, and it is the reason
    /// the solver finishes at all on inputs where naive Fourier-Motzkin
    /// explodes. Eliminating variable `k` costs exactly
    /// `num_lower(k) * num_upper(k)` rows: one per pair of a lower and an
    /// upper row, and nothing else. The raw number of rows mentioning `k`,
    /// `num_lower(k) + num_upper(k)`, is the wrong cost model because it
    /// cannot see the cross product. A variable appearing in 20 rows as one
    /// lower and nineteen upper emits 19 new rows, while one appearing in 4
    /// rows as two and two emits only 4, despite touching twice as many
    /// rows. So the greedy minimum discards the dangerous variables first,
    /// and the score is recomputed after every elimination because the row
    /// set, and with it every count, changes.
    pub fn eliminationOrder(self: System) Error![]usize {
        var scratch = try self.clone();
        defer scratch.deinit();

        var order: std.ArrayList(usize) = .empty;
        errdefer order.deinit(self.gpa);
        while (try scratch.chooseNext()) |k| {
            try order.append(self.gpa, k);
            try scratch.eliminate(k);
        }
        return order.toOwnedSlice(self.gpa);
    }

    /// Eliminate every variable following the same heuristic that
    /// `eliminationOrder` reports, leaving only zero-dimensional rows behind.
    /// Returns false as soon as a contradiction proves the system
    /// unsatisfiable, and stops early there:
    ///
    ///     const satisfiable = try sys.eliminateInOrderOfChoice();
    ///
    /// An ALREADY unsatisfiable system answers false without touching a row.
    /// That check is here rather than left to the loop because `chooseNext`
    /// does not look at `unsat`: without it the sweep would run on past a
    /// proof it already had, eliminate whatever variables were still alive,
    /// and then report `true`. The wrapper this replaced carried the same
    /// check, so this preserves its behaviour exactly.
    pub fn eliminateInOrderOfChoice(self: *System) Error!bool {
        if (self.unsat) return false;
        while (try self.chooseNext()) |k| {
            try self.eliminate(k);
            if (self.unsat) return false;
        }
        return true;
    }

    /// The projected range of variable `k`: every other variable is
    /// eliminated away on a scratch copy, leaving only lower and upper
    /// bounds on `k`.
    ///
    /// Returns null when `k` is unbounded in either direction, when the
    /// system is unsatisfiable, or when the derived bounds come out disjoint.
    /// `self` is taken by value and left untouched.
    ///
    /// The two emptiness tests are what make the answer trustworthy. A
    /// lower bound above an upper bound is a proof that no `x_k` satisfies
    /// the rows, because each side is a necessary condition; and a
    /// contradiction among the rows themselves is a proof that no point
    /// satisfies the system at all. Neither fires unless it can be shown
    /// from an enclosure, so a satisfiable system is never reported
    /// infeasible. Both are needed, and neither subsumes the other: the
    /// disjoint test needs a readable bound on each side, and the
    /// contradiction test sees rows the reader ignores.
    pub fn bounds(self: System, k: usize) Error!?Interval {
        if (k >= self.var_count) return error.BadVariable;
        if (self.unsat) return null;

        var scratch = try self.clone();
        defer scratch.deinit();

        for (0..self.var_count) |j| {
            if (j == k) continue;
            if (!scratch.alive[j]) continue;
            try scratch.eliminate(j);
            if (scratch.unsat) return null;
        }
        return scratch.projectBounds(k);
    }

    /// Read the projection of `k` off a system that has already lost every
    /// variable but `k`, and decide both of the emptiness questions on the
    /// rows that are left. `bounds` reaches that state by sweeping the other
    /// variables away one at a time on a private copy; `box` reaches it by
    /// way of a walk that shares its eliminations between projections. The
    /// reading is one function because it has to be ONE reading: two copies
    /// of it could agree on the arithmetic and still disagree on which rows
    /// bound `k` from which side, and then `bounds(k)` and `box` would give
    /// two answers for one system. The two emptiness tests are here and
    /// nowhere else for the same reason; `bounds` states what they mean.
    ///
    /// `self.alive[k]` may be false, which is a request for the same rows
    /// with one fewer question asked: a variable already eliminated has an
    /// exact [0, 0] in every column, so there is nothing to read and the
    /// answer is null through the reader rather than through a test. The
    /// contradiction check below is skipped in that case for the reason its
    /// own comment gives.
    fn projectBounds(self: System, k: usize) !?Interval {
        // After the sweep every row holds an exact [0, 0] in every slot but
        // k, so each surviving row reads `a * x_k <= rhs`. A negative `a`
        // bounds x_k from below and says nothing about how large it can be; a
        // positive one bounds it from above and says nothing about how small.
        // Each side is therefore read only from the rows that actually bound
        // it, and the tightest of those wins. `partitionInto` is what says
        // which rows those are, and `BoundReader` reads each one as it goes
        // past rather than storing a list to walk a second time: `lower`
        // holds every row that can be read from below, `upper` every row
        // that can be read from above, and a coefficient that reaches zero
        // sits in both, carrying the piece that belongs to each side.
        var reader: BoundReader = .{};
        try self.partitionInto(k, &reader);

        const lo = reader.lower orelse return null;
        const hi = reader.upper orelse return null;
        if (lo > hi) return null;

        // The sweep keeps `k` alive on purpose, because that is what leaves a
        // row to read a bound from, and it is also why the rows cannot
        // contradict one another on their own: a contradiction is a row with
        // every coefficient exactly zero, and while `k` is alive no derived
        // row is that. Dropping `k` as well is the only way a contradiction
        // among the rows becomes visible here, so the question is asked
        // before the answer is handed back.
        //
        // It is asked as `derivesContradiction` and not as `eliminate(k)`
        // because `lo` and `hi` are already read off by this point and no
        // elimination can change them. Everything the round would have had an
        // observable say on is the one fact it sets, `unsat`, and that fact
        // is a question about the rows rather than a request for the rows.
        // On the straddling generator that is 14,641 derived rows and a scan
        // over every one of them against no rows at all.
        if (self.alive[k]) {
            if (try self.derivesContradiction(k)) return null;
        }
        return Interval.init(lo, hi);
    }

    /// Would eliminating `k` derive a row the contradiction check accepts?
    ///
    /// This is the last round of `bounds` as a question rather than as an
    /// elimination, and it is exact: the same pairs, the same two
    /// expressions `appendCombined` evaluates on them, and no row stored.
    /// Two facts are what make the question answerable without building the
    /// rows the old round built.
    ///
    /// The first is that nothing can be hiding in the rows the round would
    /// carry through untouched. The contradiction check runs at the end of
    /// every `eliminate` and every `pushRow`, and `bounds` returns null the moment
    /// `unsat` is set, so the row set arriving here holds no all-zero row
    /// whose right-hand side has `hi < 0` already. Everything the round can
    /// find, it derives itself.
    ///
    /// The second is that a derived row is written by `appendCombined` and by
    /// nothing else. Slot `k` is the exact `zero`, because those two terms
    /// cancel analytically, and every other column is `combinedColumn`. So
    /// "all zero, and its bound below zero" is decided by evaluating those
    /// same two expressions over the same pairs of rows.
    ///
    /// The four-case filter settles the first half of that for nothing.
    /// Each of
    ///
    ///     both multipliers are the exact [0, 0]
    ///     the lower multiplier is exact and the lower row is flat
    ///     the upper multiplier is exact and the upper row is flat
    ///     both rows are flat
    ///
    /// forces every combined column to the exact zero, so a pair in one of
    /// them is all zero without touching an interval. Each of them does so
    /// through an exact zero and nothing else, which is the only way an exact
    /// zero is reachable here: a product with an exact zero factor is exactly
    /// zero, `Interval.neg` is exact, an exact zero minus an exact zero is
    /// exactly zero because `roundUp` and `roundDown` leave the two zeros
    /// where they are, and a product of two non-zero factors is never the
    /// exact zero, because `loBound` and `hiBound` step a magnitude f64 lost
    /// out to the smallest subnormal instead of leaving a signed zero.
    ///
    /// That reasoning is a theorem about the widening rather than a statement
    /// the four cases make about themselves, and a pair outside all four is
    /// not decided by them in either direction. So the filter is a fast path
    /// and every pair it does not settle is measured column by column with
    /// the branch logic of `appendCombined` itself, through the same
    /// `combinedColumn` the derived row would have been written with, and the
    /// survivors of that are evaluated exactly. Reading the filter as a
    /// decision is what would be unsound: it can only be wrong in the
    /// direction that misses a row, a missed contradiction hands an
    /// unsatisfiable system back as a bounded one, and a caller reasons about
    /// solutions that do not exist. On the row sets this is called with it
    /// never reaches that measurement, because eliminating a variable writes
    /// the exact [0, 0] in that variable's column and the exact zero
    /// propagates through every round after it, so each row the sweep leaves
    /// is flat in every column but `k` and the fourth case covers every pair.
    /// The measurement costs nothing on those and is what keeps the predicate
    /// an answer about the pairs rather than an assumption about them.
    ///
    /// Before either half, one pair is discarded by two multiplications in
    /// plain `f64`. With `A` the product of the upper multiplier and the
    /// lower right-hand side and `B` the product of the lower multiplier and
    /// the upper one, the derived bound has `hi` at least
    /// `A.hi - B.lo`, and the extreme corner of each product is fixed by the
    /// signs the buckets guarantee: the upper multiplier is non-negative, so
    /// `A.hi` is at least `upper.coeff.hi * max(lower.rhs)`, and the lower
    /// multiplier is non-positive, so `B.lo` is at most
    /// `lower.coeff.lo * min(upper.rhs)`. A pair that fails that comparison
    /// derives a bound at zero or above and cannot be a contradiction. The
    /// comparison is `>=` and not a subtraction, so an infinity that makes
    /// the difference undefined falls through to the exact arithmetic rather
    /// than being dropped with it.
    ///
    /// The scratch is the partition plus `2 * rowCount()` candidates, so the
    /// cost is two passes over the rows - one to bucket them, one to settle
    /// the flags - and one comparison per PAIR, against the old round's
    /// `num_lower * num_upper` stored rows, each of `var_count` coefficients,
    /// followed by a scan over all of them.
    fn derivesContradiction(self: System, k: usize) !bool {
        const gpa = self.gpa;
        const vc = self.var_count;
        const n = self.rowCount();

        // The buckets are the solver's own, not a second reading of the
        // rule, which is the whole point of this predicate: a pair it fails
        // to ask about is a contradiction that goes undetected, and an
        // undetected contradiction hands an unsatisfiable system back as a
        // bounded one. A row that does not mention `k` has no partner on
        // either side and contributes nothing to the pairing, exactly as
        // `eliminate` finds when it carries the row through untouched, and
        // `CandWriter` drops it, which is how that says so here.
        //
        // Two entries per row at most, because a coefficient that reaches
        // zero is the only one that joins both buckets and it enters each
        // once.
        const cands = try gpa.alloc(Cand, 2 * n);
        defer gpa.free(cands);

        var writer: CandWriter = .{ .cands = cands, .n = n, .k = k };
        try self.partitionInto(k, &writer);
        const lower_len = writer.lower_len;
        const upper_len = writer.upper_len;

        for (cands[0..lower_len]) |l| {
            for (cands[n..][0..upper_len]) |u| {
                const widest_a = u.coeff.hi * @max(l.row.rhs.lo, l.row.rhs.hi);
                const lowest_b = l.coeff.lo * @min(u.row.rhs.lo, u.row.rhs.hi);
                if (widest_a >= lowest_b) continue;

                // A `Side` rather than a `Part`: the exact block is handed
                // the three values it reads and names nothing else, so it
                // takes no ownership and cannot be reached only through a
                // system.
                const lower: exact.Side = .{ .coeff = l.coeff, .coeffs = l.row.coeffs, .rhs = l.row.rhs };
                const upper: exact.Side = .{ .coeff = u.coeff, .coeffs = u.row.coeffs, .rhs = u.row.rhs };
                const proved_all_zero = (l.exact and u.exact) or
                    (l.exact and l.flat) or
                    (u.exact and u.flat) or
                    (l.flat and u.flat);
                if (!proved_all_zero) {
                    var all_zero = true;
                    for (0..vc) |j| {
                        if (j == k) continue;
                        if (!exact.isExactZero(exact.combinedColumn(lower, upper, j))) {
                            all_zero = false;
                            break;
                        }
                    }
                    if (!all_zero) continue;
                }
                if (exact.combinedBound(lower, upper).hi < 0) return true;
            }
        }
        return false;
    }

    /// The projected box, one interval per variable.
    ///
    /// Returns null when the system is unsatisfiable or when any variable is
    /// unbounded. On success the caller owns the slice and must free it with
    /// the same allocator the system was built with:
    ///
    ///     if (try sys.box()) |b| {
    ///         defer gpa.free(b);
    ///         ...
    ///     }
    ///
    /// Same precondition as `bounds`: call it while the variables are live.
    ///
    /// ONE WALK, NOT `m` SWEEPS. Write the variables in increasing index
    /// order as `v_1 .. v_m`. The form this replaces called `bounds(k)` for
    /// each `k`, and each of those began at its own deep copy of this system
    /// and swept away `m - 1` variables to leave one, so a box cost `m`
    /// clones and `m * (m - 1)` eliminations - while throwing away every
    /// answer but the one in front of it. The sweep for the second variable
    /// rebuilt the row set the sweep for the first had already built and
    /// already discarded, and so on down the line: close to half of those
    /// eliminations were spent reconstructing a state that had existed a
    /// moment earlier.
    ///
    /// What this does instead is keep ONE scratch system, `chain`, and take
    /// every projection off it. The chain eliminates `v_1`, then `v_2`, and
    /// so on, so when projection `k` comes up the chain holds exactly the
    /// state the old sweep had reached after `v_1 .. v_{k-1}`: every
    /// variable before `k` gone, every one from `k` on still alive. A
    /// projection needs every OTHER variable gone, and the ones still
    /// missing are precisely the ones after `k`, so the projection is a COPY
    /// of the chain state with `v_{k+1} .. v_m` eliminated on the copy:
    /// `m - k` eliminations. The last variable is the exception the walk is
    /// built around: nothing follows it, so its projection reads the chain
    /// itself, and the chain is never eliminated past `v_{m-1}`.
    ///
    /// The cost is `m - 1` eliminations on the chain plus `m - 1` more for
    /// the projection of `v_1`, `m - 2` for `v_2`, and so on down to none:
    /// `(m - 1) * (m + 2) / 2` against the `m * (m - 1)` it replaces. Just
    /// over half, and the gap widens with `m` - fourteen eliminations against
    /// twenty at five variables, fifty-four against ninety at ten. That count
    /// depends only on how many variables follow each one and not on which
    /// they are, so taking them in ascending index order costs nothing in
    /// rounds and is worth having for the reason two paragraphs down.
    ///
    /// The copies are still `m` of them - one of the caller's own system, and
    /// `m - 1` more - and that is not an oversight left for later. A
    /// projection wants a system with exactly `v_k` alive, and a walk of
    /// eliminations reaches such a state exactly once, because every round
    /// removes one variable and the chain's live set only ever shrinks
    /// towards empty. Two projections therefore cannot share one system, and
    /// sharing an elimination would have to mean undoing one, and no
    /// elimination here can be undone. What the walk does change is what
    /// those copies are copies OF. The old form cloned the caller's system
    /// every time; this clones it once and clones the states the walk has
    /// already reached after that. On a generator whose rows compound that
    /// is MORE memory copied than before, traded against rather less
    /// arithmetic: an elimination is a cross product of interval operations
    /// over every column, some of them soft-float, where a copy is a
    /// `memcpy`. The trade is stated here rather than left to be found on a
    /// profile. The peak row count any one system reaches is unchanged, for
    /// the reason the next paragraph gives; what does change is that two
    /// systems are alive at once - the chain and one copy - where the old
    /// form held one, and that is the other half of the same price.
    ///
    /// WHY THE ANSWER IS THE SAME ANSWER, NOT A MERELY WIDER ONE.
    /// Soundness would have settled the question either way: every
    /// elimination is a sound over-approximation, so a projection taken from
    /// a shared prefix is at least as valid as one taken from a private copy,
    /// and the only thing sharing could cost is TIGHTNESS. It costs none,
    /// and the reason is that the walk runs the OLD ORDER. For projection
    /// `k` the eliminations are `v_1 .. v_{k-1}` and then `v_{k+1} .. v_m`,
    /// in that order, because that is the order `bounds(k)` used: it walked
    /// the live indices in increasing order and skipped `k`. The chain
    /// performed that prefix and the copy performs that suffix, `eliminate`
    /// is deterministic, and the chain state after `v_1 .. v_{k-1}` is
    /// therefore bit for bit the state the old sweep held at that point.
    /// Every row after it is written by the same code from the same operands,
    /// the bound read off those rows is the same `f64`, and the peak row
    /// count of any one system is the peak the old sweep reached for the same
    /// projection. So the box this returns is not wider: it is the same
    /// numbers, and a caller pinning them - or the benchmark's geometry line,
    /// which says whether every variable came back bounded - sees no change
    /// at all.
    ///
    /// WHY THE `null` CANNOT MOVE. Two of the three ways to answer null are
    /// decided in `projectBounds`, which this walk shares with `bounds` and
    /// runs over the same rows, so they cannot differ. The third is the
    /// contradiction check after every elimination, and the walk does run
    /// eliminations `bounds` never did: the chain's own. A chain round that
    /// proves a contradiction is not new information, and the shape of the
    /// walk is why. After eliminating `v_1 .. v_k` the chain holds a state
    /// the old sweep reached as the first `k` rounds of its projection for
    /// `v_{k+1}`, because that sweep walked the indices in increasing order
    /// as well and skipped only `v_{k+1}`. Every state the chain can prove
    /// unsatisfiable is one the old `box` proved unsatisfiable on the very
    /// next projection, and answered null there. The walk also stops one
    /// variable short of eliminating everything, because the state with no
    /// variable alive is a state no projection ever reads - and dropping
    /// `v_m` as well would buy nothing even if it were read, since its round
    /// pairs exactly the rows `derivesContradiction` already asks about and
    /// the last projection is about to ask that question anyway.
    pub fn box(self: System) Error!?[]Interval {
        if (self.unsat) return null;
        const out = try self.gpa.alloc(Interval, self.var_count);
        errdefer self.gpa.free(out);

        // A variable that is not live answers null, and takes the whole box
        // with it: its column is the structural zero in every row, so no row
        // bounds it and `projectBounds` returns null for it. The precondition
        // above already excludes such a system, but the old form answered
        // null for it rather than something, and an unwritten slot in `out`
        // is what "something" would look like.
        var live_left: usize = 0;
        for (self.alive) |a| {
            if (a) live_left += 1;
        }
        if (live_left != self.var_count) {
            self.gpa.free(out);
            return null;
        }

        var chain = try self.clone();
        defer chain.deinit();

        for (0..self.var_count) |k| {
            live_left -= 1;

            // The last variable is the one projection that needs no copy:
            // nothing follows it, so the chain already holds the system with
            // every other variable eliminated.
            if (live_left == 0) {
                out[k] = (try chain.projectBounds(k)) orelse {
                    self.gpa.free(out);
                    return null;
                };
                continue;
            }

            // The variables after `k` are what this projection is still
            // missing, and the chain state is what it is missing them from,
            // so the copy continues from the row set the old sweep would have
            // reached after the `k` eliminations it had already done.
            var tail = try chain.clone();
            defer tail.deinit();
            for (k + 1..self.var_count) |j| {
                try tail.eliminate(j);
                if (tail.unsat) {
                    self.gpa.free(out);
                    return null;
                }
            }

            out[k] = (try tail.projectBounds(k)) orelse {
                self.gpa.free(out);
                return null;
            };

            // Only now does the chain take `k` away, which is the round the
            // next projection starts from and the one place this walk does
            // something the old form never did.
            try chain.eliminate(k);
            if (chain.unsat) {
                self.gpa.free(out);
                return null;
            }
        }
        return out;
    }

    /// Deep copy, including the allocator. `bounds`, `box` and
    /// `eliminationOrder` simulate eliminations and must not touch the
    /// caller's system.
    fn clone(self: System) !System {
        var out = try System.init(self.gpa, self.var_count);
        errdefer out.deinit();
        try out.coeffs.appendSlice(self.gpa, self.coeffs.items);
        try out.rhs.appendSlice(self.gpa, self.rhs.items);
        @memcpy(out.alive, self.alive);
        out.unsat = self.unsat;
        return out;
    }

    fn pushRow(self: *System, coeffs: []const Interval, rhs: Interval) !void {
        try self.rhs.append(self.gpa, rhs);
        errdefer _ = self.rhs.pop();
        try self.coeffs.appendSlice(self.gpa, coeffs);
        // `unsat` is latched, so the row just appended is the only one that
        // can be NEWLY all-zero: every row before it was checked when it was
        // appended, and nothing since has changed it. Scanning them all here
        // made `add` quadratic in the number of constraints.
        try self.checkRowForContradiction(self.rowCount() - 1);
    }

    /// Caller-freed copy of `coeffs` with every coefficient negated, used by
    /// `add` to store `a . x >= r` as `-a . x <= -r`.
    fn flip(self: *const System, coeffs: []const Interval) ![]Interval {
        const out = try self.gpa.alloc(Interval, coeffs.len);
        for (coeffs, out) |a, *b| b.* = a.neg();
        return out;
    }

    /// The live variable with the smallest Tupper cost, or null when none is
    /// left. Ties go to the lowest index, which keeps the order a function of
    /// the system alone.
    fn chooseNext(self: System) !?usize {
        var best: ?usize = null;
        var best_cost: usize = std.math.maxInt(usize);
        for (0..self.var_count) |k| {
            if (!self.alive[k]) continue;
            const cost = try self.pairCount(k);
            if (cost < best_cost) {
                best_cost = cost;
                best = k;
            }
        }
        return best;
    }

    /// `num_lower(k) * num_upper(k)`: how many rows eliminating `k` would
    /// generate. Counted off the shared rule rather than recounted here, so
    /// the cost the heuristic ranks variables by cannot drift from the
    /// buckets the solver actually builds. A coefficient that reaches zero
    /// counts in both buckets, because it is paired from both sides.
    ///
    /// One pass and no allocation, exactly as before the rule moved, and
    /// that is what `Tally` is for: this runs once per live variable in
    /// every round of every sweep, so it is the last place in the file that
    /// could afford to materialise a list to measure its length.
    fn pairCount(self: System, k: usize) !usize {
        var tally: Tally = .{};
        try self.partitionInto(k, &tally);
        return tally.pairs();
    }

    /// A row with an all-zero coefficient vector states `0 <= rhs`, where
    /// `rhs` encloses one unknown bound value. The row is a genuine
    /// contradiction only when the whole enclosure is strictly negative, so
    /// the test is `rhs.hi < 0`.
    ///
    /// The looser-looking `rhs.lo < 0` would be wrong here, and the reason is
    /// the outward rounding. `x <= 3` paired with `x >= 3` is exactly
    /// satisfiable - the combined row is `0 <= 0` - but `Interval` encloses
    /// that zero as a hair either side of it, so `rhs.lo` lands a few ULPs
    /// below zero. Reading that as infeasible would report a satisfiable
    /// system as unsatisfiable, which cuts the feasible set and is the one
    /// failure this library must never produce. Claiming infeasibility is the
    /// expensive direction, so it waits for an enclosure that rules it out.
    fn checkRowForContradiction(self: *System, i: usize) !void {
        const row = try self.at(i);
        if (!isAllZero(row.coeffs)) return;
        if (row.rhs.hi < 0) self.unsat = true;
    }

    /// Every row, and only on the `eliminate` path, where the row set has
    /// genuinely changed underneath. One scan per elimination round is the
    /// price of that; `pushRow` does not pay it, which is the whole of A5.
    fn rescanForContradiction(self: *System) !void {
        for (0..self.rowCount()) |i| {
            try self.checkRowForContradiction(i);
            if (self.unsat) return;
        }
    }
};

/// Build the single constraint that combines a lower and an upper row.
///
/// With `a_l <= 0 <= a_u`, multiplying the lower row by `a_u` and the upper
/// row by `-a_l` cancels the `x_k` terms:
///     a_u * S_l  -  a_l * S_u   <=   a_u * r_l  -  a_l * r_u
/// Both multipliers are non-negative, so the `<=` direction survives for every
/// realisation of the coefficient intervals. Each endpoint comes from
/// `Interval.mul` and `Interval.sub`, which widen outward, so the result is a
/// guaranteed superset of the true combined row. Slot `k` is written as the
/// exact [0, 0] because those terms do cancel analytically.
fn appendCombined(
    gpa: std.mem.Allocator,
    coeffs: *std.ArrayList(Interval),
    rhs: *std.ArrayList(Interval),
    lower: Part,
    upper: Part,
    k: usize,
    vc: usize,
) !void {
    const l = sideOf(lower);
    const u = sideOf(upper);
    for (0..vc) |j| {
        if (j == k) {
            try coeffs.append(gpa, zero);
            continue;
        }
        try coeffs.append(gpa, exact.combinedColumn(l, u, j));
    }
    try rhs.append(gpa, exact.combinedBound(l, u));
}

/// True when every coefficient of a row is the exact zero interval.
///
/// The one predicate left in this file that reads nothing but coefficients:
/// it is a whole-row scan rather than part of the pairing arithmetic, and it
/// has no multiplier, so `lp_exact` has nothing to take from it. The test it
/// rests on is that module's `isExactZero`, not a second copy of it - a
/// rounding-thin straddle is a variable the row still mentions, and reading
/// it as an absent one is how a derived row comes to look like a
/// contradiction when it is not.
fn isAllZero(coeffs: []const Interval) bool {
    for (coeffs) |a| {
        if (!exact.isExactZero(a)) return false;
    }
    return true;
}
