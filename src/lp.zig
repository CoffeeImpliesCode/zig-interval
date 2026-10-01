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
//! already widened on the way in. `combinedColumn` decides that case on the
//! operands rather than on the widened products, in `f128` where the
//! question has an exact answer, and writes the structural zero when the
//! exact coefficient is zero.

const std = @import("std");

const Interval = @import("interval.zig").Interval;

/// The degenerate interval written into a combined row for the eliminated
/// index. The two `x_k` terms cancel analytically, so the exact zero is the
/// truthful value; anything else would leave a rounding-thin straddle behind
/// that later reads as a bound on a variable that no longer appears.
const zero = Interval.init(0.0, 0.0);

/// Comparison requested by the caller. See the module comment for how each
/// variant is stored.
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
    gpa: std.mem.Allocator,
    carried: []Lin,
    lower: []Part,
    upper: []Part,

    /// Release the three lists. The borrowed rows are untouched.
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
/// `exact` says the multiplier is the exact [0, 0]. Neither is a property of
/// the row alone: `exact` is about the piece, which for a straddling
/// coefficient is a different interval in each of the two buckets.
const Cand = struct {
    coeff: Interval,
    row: Lin,
    flat: bool,
    exact: bool,
};

/// A `Cand` for one bucket. `exact` is derived rather than passed, so a
/// candidate cannot claim a multiplier is the exact zero when it is not.
fn candidate(coeff: Interval, row: Lin, flat: bool) Cand {
    return .{ .coeff = coeff, .row = row, .flat = flat, .exact = isExactZero(coeff) };
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
const Buckets = struct {
    gpa: std.mem.Allocator,
    /// Rows that do not mention the variable. Stays empty when the
    /// passthrough is set, because those rows are already in the caller's
    /// output tables and are not to be kept anywhere else.
    carried: std.ArrayList(Lin) = .empty,
    lower: std.ArrayList(Part) = .empty,
    upper: std.ArrayList(Part) = .empty,
    /// Where a carried row goes instead of into `carried`. Null collects.
    coeffs: ?*std.ArrayList(Interval) = null,
    rhs: ?*std.ArrayList(Interval) = null,
    /// How many rows were carried, whether they were stored or written
    /// through. `carried.items.len` cannot answer it once the passthrough
    /// is set, and the reservation a round makes needs it either way.
    carried_count: usize = 0,

    /// Reserve the worst case: each list takes at most `n` entries, and
    /// reserving is what keeps a round from paying O(log rows)
    /// reallocations that each copy everything built so far.
    fn init(gpa: std.mem.Allocator, n: usize) !Buckets {
        var self = Buckets{ .gpa = gpa };
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
        var self = Buckets{ .gpa = gpa, .coeffs = coeffs, .rhs = rhs };
        errdefer self.deinit();
        try self.lower.ensureTotalCapacity(gpa, n);
        try self.upper.ensureTotalCapacity(gpa, n);
        return self;
    }

    fn deinit(self: *Buckets) void {
        self.carried.deinit(self.gpa);
        self.lower.deinit(self.gpa);
        self.upper.deinit(self.gpa);
    }

    fn addCarried(self: *Buckets, row: Lin) !void {
        if (self.coeffs) |out| {
            try out.appendSlice(self.gpa, row.coeffs);
            try self.rhs.?.append(self.gpa, row.rhs);
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
/// What a piece is DIVIDED by is `boundDivisor`'s question, and the reason
/// it cannot be the piece itself is that piece's doc gives.
const BoundReader = struct {
    lower: ?f64 = null,
    upper: ?f64 = null,

    fn addCarried(_: *BoundReader, _: Lin) !void {}

    fn addLower(self: *BoundReader, part: Part) !void {
        if (!(part.coeff.lo < 0)) return;
        const q = part.row.rhs.div(boundDivisor(part));
        self.lower = if (self.lower) |v| @max(v, q.lo) else q.lo;
    }

    fn addUpper(self: *BoundReader, part: Part) !void {
        if (!(part.coeff.hi > 0)) return;
        const q = part.row.rhs.div(boundDivisor(part));
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
        self.cands[self.lower_len] = candidate(part.coeff, part.row, isFlatApartFrom(part.row.coeffs, self.k));
        self.lower_len += 1;
    }

    fn addUpper(self: *CandWriter, part: Part) !void {
        self.cands[self.n + self.upper_len] = candidate(part.coeff, part.row, isFlatApartFrom(part.row.coeffs, self.k));
        self.upper_len += 1;
    }
};

/// A linear constraint system over interval-valued coefficients.
///
/// Storage comes from the caller's allocator and the caller owns the
/// lifetime. Coefficients live in one row-major array, `var_count` entries
/// per row.
pub const System = struct {
    gpa: std.mem.Allocator,
    var_count: usize,
    coeffs: std.ArrayList(Interval),
    rhs: std.ArrayList(Interval),
    alive: []bool,
    unsat: bool,

    /// Empty system over `var_count` variables.
    ///
    /// Allocating the liveness flags is the one fallible step in building a
    /// system, and it is reported like every other allocation in this file
    /// rather than panicked. It used to be the only allocator call here that
    /// could not fail visibly, which meant a program that wanted to handle
    /// exhaustion instead of dying had no way to ask for that.
    pub fn init(gpa: std.mem.Allocator, var_count: usize) !System {
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
    /// ReleaseFast elides the slicing assertion that would otherwise stop it.
    ///
    /// The view is `const`. Writing to `row.coeffs` does not compile, and
    /// there is no `.op` to write to at all.
    pub fn at(self: System, i: usize) !Lin {
        if (i >= self.rhs.items.len) return error.BadRow;
        const start = i * self.var_count;
        return .{
            .coeffs = self.coeffs.items[start..][0..self.var_count],
            .rhs = self.rhs.items[i],
        };
    }

    /// True once a row with an all-zero coefficient vector has been derived
    /// whose right-hand side cannot be met.
    pub fn isUnsat(self: System) bool {
        return self.unsat;
    }

    /// Add a constraint. `coeffs` is copied, so the caller keeps its slice.
    /// `coeffs.len` must equal `varCount()`.
    pub fn add(self: *System, coeffs: []const Interval, op: Cmp, rhs: Interval) !void {
        if (coeffs.len != self.var_count) return error.BadVariableCount;
        switch (op) {
            .le, .lt => try self.pushRow(coeffs, rhs),
            .ge, .gt => {
                const flipped = try self.flip(coeffs);
                defer self.gpa.free(flipped);
                try self.pushRow(flipped, rhs.neg());
            },
            .eq => {
                try self.pushRow(coeffs, rhs);
                const flipped = try self.flip(coeffs);
                defer self.gpa.free(flipped);
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
    pub fn partition(self: System, k: usize) !Partition {
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
    pub fn rowsAfterEliminating(self: System, k: usize) !usize {
        var tally = Tally{};
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
    pub fn eliminate(self: *System, k: usize) !void {
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
        try self.noteContradiction();
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
    pub fn eliminationOrder(self: System) ![]usize {
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
    pub fn eliminateInOrderOfChoice(self: *System) !bool {
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
    pub fn bounds(self: System, k: usize) !?Interval {
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
        var reader = BoundReader{};
        try scratch.partitionInto(k, &reader);

        const lo = reader.lower orelse return null;
        const hi = reader.upper orelse return null;
        if (lo > hi) return null;

        // The sweep above keeps `k` alive on purpose, because that is what
        // leaves a row to read a bound from, and it is also why the rows
        // cannot contradict one another on their own: a contradiction is a
        // row with every coefficient exactly zero, and while `k` is alive no
        // derived row is that. Dropping `k` as well is the only way a
        // contradiction among the rows becomes visible here, so the question
        // is asked before the answer is handed back.
        //
        // It is asked as `derivesContradiction` and not as `eliminate(k)`
        // because `lo` and `hi` are already read off by this point and no
        // elimination can change them. Everything the round would have had an
        // observable say on is the one fact it sets, `unsat`, and that fact
        // is a question about the rows rather than a request for the rows.
        // On the straddling generator that is 14,641 derived rows and a scan
        // over every one of them against no rows at all.
        if (scratch.alive[k]) {
            if (try scratch.derivesContradiction(k)) return null;
        }
        return Interval.init(lo, hi);
    }

    /// Would eliminating `k` derive a row that `noteContradiction` accepts?
    ///
    /// This is the last round of `bounds` as a question rather than as an
    /// elimination, and it is exact: the same pairs, the same two
    /// expressions `appendCombined` evaluates on them, and no row stored.
    /// Two facts are what make the question answerable without building the
    /// rows the old round built.
    ///
    /// The first is that nothing can be hiding in the rows the round would
    /// carry through untouched. `noteContradiction` runs at the end of every
    /// `eliminate` and every `pushRow`, and `bounds` returns null the moment
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

        var writer = CandWriter{ .cands = cands, .n = n, .k = k };
        try self.partitionInto(k, &writer);
        const lower_len = writer.lower_len;
        const upper_len = writer.upper_len;

        for (cands[0..lower_len]) |l| {
            for (cands[n..][0..upper_len]) |u| {
                const widest_a = u.coeff.hi * @max(l.row.rhs.lo, l.row.rhs.hi);
                const lowest_b = l.coeff.lo * @min(u.row.rhs.lo, u.row.rhs.hi);
                if (widest_a >= lowest_b) continue;

                const lower: Part = .{ .coeff = l.coeff, .row = l.row };
                const upper: Part = .{ .coeff = u.coeff, .row = u.row };
                const proved_all_zero = (l.exact and u.exact) or
                    (l.exact and l.flat) or
                    (u.exact and u.flat) or
                    (l.flat and u.flat);
                if (!proved_all_zero) {
                    var all_zero = true;
                    for (0..vc) |j| {
                        if (j == k) continue;
                        if (!isExactZero(combinedColumn(lower, upper, j))) {
                            all_zero = false;
                            break;
                        }
                    }
                    if (!all_zero) continue;
                }
                if (combinedBound(lower, upper).hi < 0) return true;
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
    pub fn box(self: System) !?[]Interval {
        if (self.unsat) return null;
        const out = try self.gpa.alloc(Interval, self.var_count);
        errdefer self.gpa.free(out);
        for (0..self.var_count) |k| {
            out[k] = (try self.bounds(k)) orelse {
                self.gpa.free(out);
                return null;
            };
        }
        return out;
    }

    /// Deep copy, including the allocator. `bounds` and `eliminationOrder`
    /// simulate eliminations and must not touch the caller's system.
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
        try self.noteContradiction();
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
        var tally = Tally{};
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
    fn noteContradiction(self: *System) !void {
        for (0..self.rowCount()) |i| {
            const row = try self.at(i);
            if (!isAllZero(row.coeffs)) continue;
            if (row.rhs.hi < 0) {
                self.unsat = true;
                return;
            }
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
    for (0..vc) |j| {
        if (j == k) {
            try coeffs.append(gpa, zero);
            continue;
        }
        try coeffs.append(gpa, combinedColumn(lower, upper, j));
    }
    try rhs.append(gpa, combinedBound(lower, upper));
}

/// The coefficient in column `j` of the row that pairs `lower` with `upper`.
///
/// This is the branch logic of `appendCombined`, lifted out so that
/// `System.derivesContradiction` can ask the same question about the same
/// pair. It has to be the same question: a predicate that decided
/// all-zero-ness by a different rule would be answering about a row the
/// elimination never builds, and the difference would show up as a projection
/// that claims solutions exist where none do.
///
/// A zero coefficient is structural, not numerical: the variable is simply
/// absent from that row. A product with an exact zero factor is exactly zero,
/// `x - 0` is `x`, and `-x` is `Interval.neg`, which is exact. So a variable
/// that no row mentions stays exactly [0, 0] through the whole elimination
/// instead of drifting.
///
/// Letting the general form run on a structural zero would hand it to the
/// outward widening, which turns [0, 0] into a subnormal straddle. Every
/// later elimination reads that straddle as a constraint from both sides and
/// pairs rows that share no variable at all, and the row count compounds for
/// nothing. It is a soundness question too: a coefficient that is exactly
/// zero must be free of the variable, and a straddle does not say that.
///
/// The general branch reaches the same straddle by a different route, which
/// is the one the three branches above cannot catch: cancellation. A derived
/// row from `r0: x + y <= 1` paired with `r1: x + y >= 0` has an `x`
/// coefficient of `1 * -1 - -1 * 1`, which is exactly zero, and both products
/// have been widened by the time the subtraction sees them, so the widened
/// difference straddles zero and a row that does not mention `x` at all is
/// stored as one that bounds it from both sides by 3.0e15. The exactness test
/// runs on the four operands, which are the only version of the question that
/// has an exact answer; on the widened products it can only ever compare two
/// approximations of a zero.
inline fn combinedColumn(lower: Part, upper: Part, j: usize) Interval {
    const lj = lower.row.coeffs[j];
    const uj = upper.row.coeffs[j];
    if (isExactZero(lj) and isExactZero(uj)) return zero;
    if (isExactZero(lj)) return lower.coeff.mul(uj).neg();
    if (isExactZero(uj)) return upper.coeff.mul(lj);
    if (cancelsExactly(upper.coeff, lj, lower.coeff, uj)) return zero;
    return upper.coeff.mul(lj).sub(lower.coeff.mul(uj));
}

/// One interval in `f128`: the pair of endpoints `Interval` would carry if
/// its arithmetic were exact and it applied no outward step. It never is,
/// which is why nothing here is stored in one - this is a decision's
/// intermediate, not an answer.
const Exact = struct {
    lo: f128,
    hi: f128,
};

/// Do `u * a` and `l * b` cancel, so that the coefficient they form is zero
/// for EVERY realisation of the four operands?
///
/// THE PROPERTY, AND WHAT IS NOT BEING ASKED. This asks whether the two exact
/// product intervals are the same interval. When they are, every realisation
/// of `u`, `a`, `l` and `b` yields the same coefficient, zero, so the derived
/// row genuinely does not mention the variable - the invariant
/// `combinedColumn`'s doc claims and the one `isExactZero` reads back. What it
/// does NOT ask is whether the difference is small. A coefficient of 1e-300
/// is a coefficient: writing it as [0, 0] discards a real constraint on the
/// variable, and no tolerance appears anywhere in this function, so two
/// products that differ by one ULP fail the test and fall through to the
/// widened path, which is where every nonzero coefficient belongs.
///
/// WHY IT CANNOT NARROW A NONZERO RESULT. Nothing on this path is rounded,
/// and that is a property of the arithmetic rather than a hope about the
/// operands. Widening an `f64` endpoint to `f128` is exact; a product of two
/// doubles is exact at 106 significand bits against the 113 the type carries
/// (`tests/soundness_test.zig:11-18`); and the verdict is an EQUALITY between
/// two such products rather than a subtraction of them, so no sum is ever
/// evaluated that would want the extra bits a sum wants. The products cannot
/// overflow either: the largest product of two doubles is about 3.3e616
/// against an `f128` range that reaches 1.2e4932. Nor can one underflow
/// towards a zero: every double is an integer multiple of 2^-1074, so every
/// product is an integer multiple of 2^-2148, which is an ordinary normal
/// `f128`. So `p.lo == q.hi` is a claim about the mathematics and not about a
/// rounding of it, and two products that differ cannot be reported as equal.
/// Where the two intervals differ this function declines and the widened
/// path answers, exactly as it answered before; the only answer it ever
/// replaces is one it can prove to be the exact zero.
///
/// THE ONE CASE IT DECLINES. An infinite endpoint makes a corner `0 * inf`,
/// which IEEE makes a NaN, and a single NaN poisons the reduction that picks
/// the endpoints. The exact image of a zero interval against an unbounded one
/// is the zero interval, but recovering that from the corners is a special
/// case worth nothing on this path, so those operands go to the widened path
/// unchanged. Nothing is unproven there: it is the answer this function has
/// always given.
///
/// WHERE THE COST USED TO GO, AND WHY IT IS NOT HERE ANY MORE. This is the
/// innermost predicate of the pairing loop: `combinedColumn` asks it once
/// per column of every pair of rows, and on both generators the answer to
/// almost every one of those questions is no. The form this replaces reached
/// for `f128` to find that out, and an `f128` multiply on x86-64 is a
/// soft-float call, so a predicate that declines nearly always was paying
/// eight of them to do it. Two filters now sit in front of the exact
/// arithmetic, and both are consequences of the mathematics rather than
/// approximations of it.
///
/// THE FIRST IS STRUCTURAL. `exactProduct` returns a minimum of the four
/// corners as `lo` and a maximum of the same corners as `hi`, so `p.lo` is
/// never above `p.hi` whatever the operands are. That makes the old verdict
/// `p.lo == q.hi and p.hi == q.lo` a chain that closes on itself:
///
///     p.lo = q.hi <= q.lo = p.hi <= p.lo
///
/// and every link is an identity. Both products are therefore points, and a
/// product of two intervals is a point only if one of them is. Suppose
/// neither `u` nor `a` is a point: then `a.lo != a.hi`, so `u.lo * a.lo` and
/// `u.lo * a.hi` differ unless `u.lo == 0`; and if `u.lo == 0` then
/// `u.lo != u.hi` forces `u.hi != 0`, and `u.hi * a.lo`, `u.hi * a.hi` differ
/// instead. Either way one pair of corners straddles and the hull is wide,
/// so the old test could not have been true. Hence the guard below, and its
/// mirror for `l` and `b`.
///
/// Nothing the old form accepted is refused here: an unsound "no" would
/// have to be a pair of corner hulls that collapsed and did not, and the
/// paragraph above is the proof that none exists. It is the shape of the
/// question, not a tolerance on the operands, and no real coefficient
/// anywhere near zero is turned away by it.
///
/// THE SECOND IS ROUNDING. Among the survivors the corners are still built
/// in `f128`, but first they are built in `f64` and compared there. That is
/// sound because rounding to nearest is monotone: `x <= y` implies
/// `r(x) <= r(y)`, so the minimum of the rounded corners is the rounding of
/// the minimum, and two hulls that coincide exactly cannot differ after
/// rounding. Inequality of the rounded hulls therefore proves inequality of
/// the exact ones, and only hulls that already agree in `f64` are worth the
/// soft-float call. `doubleProduct` is never stored and is not an enclosure;
/// its only use is this comparison, and it is the only claim made about it.
inline fn cancelsExactly(u: Interval, a: Interval, l: Interval, b: Interval) bool {
    if (!isPoint(u) and !isPoint(a)) return false;
    if (!isPoint(l) and !isPoint(b)) return false;
    if (!allFinite(u) or !allFinite(a) or !allFinite(l) or !allFinite(b)) return false;
    const fp = doubleProduct(u, a);
    const fq = doubleProduct(l, b);
    if (fp.lo != fq.hi or fp.hi != fq.lo) return false;
    const p = exactProduct(u, a);
    const q = exactProduct(l, b);
    return p.lo == q.hi and p.hi == q.lo;
}

/// The same four corners as `exactProduct`, rounded to the nearest double.
///
/// NOT AN ENCLOSURE. Rounding each corner independently pulls the hull
/// inwards at both ends, so this is NARROWER than the exact image it is built
/// from, and nothing may be stored in it or read a bound off it. It is a
/// decision's intermediate, like `Exact`, and it exists only to be compared
/// against the same construction on the other pair of operands; see
/// `cancelsExactly` for the monotonicity argument that makes that comparison
/// a sound filter rather than a guess.
inline fn doubleProduct(a: Interval, b: Interval) Interval {
    const p: f64 = a.lo * b.lo;
    const q: f64 = a.lo * b.hi;
    const r: f64 = a.hi * b.lo;
    const s: f64 = a.hi * b.hi;
    return .{
        .lo = @min(@min(p, q), @min(r, s)),
        .hi = @max(@max(p, q), @max(r, s)),
    };
}

/// The exact image of `[a.lo, a.hi] * [b.lo, b.hi]`, as an `f128` interval.
///
/// The product of two intervals is the hull of the four corners, and every
/// corner of a rectangle over the reals is attained, so the two endpoints are
/// a min and a max of the four products. None of that is widened, because each
/// corner is exact (`cancelsExactly` carries the bit count). The caller must
/// have rejected an infinite endpoint: `0 * inf` is a NaN corner and a NaN
/// loses the reduction.
fn exactProduct(a: Interval, b: Interval) Exact {
    const p: f128 = @as(f128, a.lo) * @as(f128, b.lo);
    const q: f128 = @as(f128, a.lo) * @as(f128, b.hi);
    const r: f128 = @as(f128, a.hi) * @as(f128, b.lo);
    const s: f128 = @as(f128, a.hi) * @as(f128, b.hi);
    return .{
        .lo = @min(@min(p, q), @min(r, s)),
        .hi = @max(@max(p, q), @max(r, s)),
    };
}

/// True when neither endpoint is an infinity or a NaN, which is the
/// precondition `exactProduct` needs to keep a corner from being a NaN.
fn allFinite(v: Interval) bool {
    return std.math.isFinite(v.lo) and std.math.isFinite(v.hi);
}

/// The right-hand side of the row that pairs `lower` with `upper`: the same
/// expression `appendCombined` stores, lifted out for the same reason.
inline fn combinedBound(lower: Part, upper: Part) Interval {
    return upper.coeff.mul(lower.row.rhs)
        .sub(lower.coeff.mul(upper.row.rhs));
}

/// The divisor one side of a bound is read off with: the multiplier piece
/// itself where that piece does not reach zero, and its endpoint farthest
/// from zero as a point where it does.
///
/// `Interval.div` answers a divisor that reaches zero with the whole line,
/// which is not a bound in either direction, so a piece that touches zero
/// has to go in as a single endpoint. FAR is the right endpoint because the
/// row must hold for EVERY realisation of the coefficient: `x_k` has one
/// sign, and the coefficient sitting on the other side of it is the one
/// that makes `a * x_k` largest.
///
/// This is the same one-sided reading `eliminate` performs, asked of the
/// same object. `eliminate` needs only the SIGN of a multiplier, and a
/// piece that touches zero still has one, so it multiplies by the piece
/// whole. The guards an earlier form of this arm used - `neg_part.hi < 0`
/// and `pos_part.lo > 0` - were not merely narrow, they were
/// unsatisfiable: a piece that reaches zero has `lo <= 0 <= hi`, so
/// `min(hi, 0) < 0` and `max(lo, 0) > 0` can both never hold, and that arm
/// contributed nothing whatsoever. One round of elimination with an
/// uncertain coefficient is enough to put a zero-touching endpoint in
/// almost every derived coefficient, so almost every bounded variable read
/// as unbounded.
fn boundDivisor(part: Part) Interval {
    if (part.coeff.lo != 0 and part.coeff.hi != 0) return part.coeff;
    const far = if (@abs(part.coeff.lo) >= @abs(part.coeff.hi))
        part.coeff.lo
    else
        part.coeff.hi;
    return Interval.init(far, far);
}

/// True only for the exact zero interval, not for a widening artefact that
/// happens to be small.
fn isExactZero(a: Interval) bool {
    return a.lo == 0 and a.hi == 0;
}

/// True when `row` is the exact [0, 0] in every column except `k`: the
/// shape a final round of elimination leaves behind, a row that mentions
/// `x_k` and nothing else. Asked once per side list, so a coefficient that
/// reaches zero has it computed twice. That is one extra pass over the
/// columns and it buys the shared buckets.
fn isFlatApartFrom(coeffs: []const Interval, k: usize) bool {
    for (coeffs, 0..) |a, j| {
        if (j == k) continue;
        if (!isExactZero(a)) return false;
    }
    return true;
}

/// True when the interval names a single real, `lo == hi`.
///
/// Not the same question as `isExactZero`, which asks whether that one real
/// is zero. `cancelsExactly` needs this one because a product hull is a point
/// only when a factor collapses, and a factor collapses at any value, not at
/// zero. It is two comparisons, and it is the first thing the pairing loop
/// asks, so it sits where the cheapest answer can end the question.
inline fn isPoint(a: Interval) bool {
    return a.lo == a.hi;
}

fn isAllZero(coeffs: []const Interval) bool {
    for (coeffs) |a| {
        if (!isExactZero(a)) return false;
    }
    return true;
}
