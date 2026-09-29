//! Fourier-Motzkin elimination for linear constraints whose coefficients,
//! and whose right-hand sides, are intervals rather than points.
//!
//! Every derived bound goes through the rigorous `Interval` methods, so a
//! result is always a guaranteed superset of the true feasible set: widening
//! outward can only enlarge the answer, never clip a real solution.
//!
//! Constraints are stored normalised. `a . x  <=  r` is the only internal
//! shape, and `Lin.op` always reads back as `.le`:
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
//! A coefficient of exactly [0, 0] is structural: it means the row does not
//! mention that variable. It stays exactly [0, 0] all the way through
//! elimination, which `appendCombined` arranges by taking the exact branches
//! of the combination when either factor is a structural zero. The general
//! form would hand the zero to the outward widening, and a subnormal
//! straddle is not the same statement as an absent variable: later rounds
//! would read it as a bound from both sides and pair rows that share no
//! variable at all.

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
/// `deinit`. Every stored row has `op == .le`.
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
    coeffs: []Interval,
    op: Cmp,
    rhs: Interval,
};

/// Where a coefficient sits relative to zero. `straddle` is the case an
/// interval coefficient creates and a point coefficient never does.
const Sign = enum { negative, positive, zero, straddle };

fn signOf(a: Interval) Sign {
    if (a.hi < 0) return .negative;
    if (a.lo > 0) return .positive;
    if (a.lo == 0 and a.hi == 0) return .zero;
    return .straddle;
}

/// A constraint row together with the piece of its `x_k` coefficient that
/// plays one role in the pairing. `lower` entries carry a non-positive
/// coefficient, `upper` entries a non-negative one, and a straddling row
/// appears in both lists carrying a different piece each time.
const Part = struct {
    coeff: Interval,
    row: Lin,
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

    /// Empty system over `var_count` variables. Allocating the liveness flags
    /// can fail and this signature has no error to report it in, so it panics
    /// on out of memory.
    pub fn init(gpa: std.mem.Allocator, var_count: usize) System {
        const flags = gpa.alloc(bool, var_count) catch @panic("lp.System.init: out of memory");
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

    /// Number of stored rows, after normalisation. A row added as `eq`
    /// counts twice.
    pub fn count(self: System) usize {
        return self.rhs.items.len;
    }

    /// Borrowed view of row `i`. Invalidated by the next mutation.
    ///
    /// `i` must be below `count()`, and anything else is `error.BadRow`. The
    /// check is not decoration: the slice below is built by arithmetic, so an
    /// unchecked `i` reads whatever the allocator left past the rows, and
    /// ReleaseFast elides the slicing assertion that would otherwise stop it.
    pub fn at(self: System, i: usize) !Lin {
        if (i >= self.rhs.items.len) return error.BadRow;
        const start = i * self.var_count;
        return .{
            .coeffs = self.coeffs.items[start..][0..self.var_count],
            .op = .le,
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

    /// Fourier-Motzkin elimination of variable `k`.
    ///
    /// Rows split by the sign of their `x_k` coefficient: `lower` (entirely
    /// negative), `upper` (entirely positive), and `free` (exactly zero,
    /// carried through untouched). Every `lower` row combines with every
    /// `upper` row, and the result is `free ++ combined`. When one of the two
    /// groups is empty the other has no partner, and pushing `x_k` towards
    /// the opposite infinity makes those rows vacuous, so they drop out; that
    /// is exactly what the same formula yields.
    pub fn eliminate(self: *System, k: usize) !void {
        if (k >= self.var_count) return error.BadVariable;
        if (!self.alive[k]) return error.VariableEliminated;

        const gpa = self.gpa;
        const vc = self.var_count;
        const n = self.count();

        var lower: std.ArrayList(Part) = .empty;
        defer lower.deinit(gpa);
        var upper: std.ArrayList(Part) = .empty;
        defer upper.deinit(gpa);
        try lower.ensureTotalCapacity(gpa, n);
        try upper.ensureTotalCapacity(gpa, n);

        var coeffs: std.ArrayList(Interval) = .empty;
        errdefer coeffs.deinit(gpa);
        var rhs: std.ArrayList(Interval) = .empty;
        errdefer rhs.deinit(gpa);

        for (0..n) |i| {
            const row = try self.at(i);
            const a = row.coeffs[k];
            switch (signOf(a)) {
                .zero => {
                    try coeffs.appendSlice(gpa, row.coeffs);
                    try rhs.append(gpa, row.rhs);
                },
                .negative => try lower.append(gpa, .{ .coeff = a, .row = row }),
                .positive => try upper.append(gpa, .{ .coeff = a, .row = row }),
                // A coefficient interval that straddles zero cannot be sorted
                // into one bucket: the same row bounds x_k from below for its
                // negative realisations and from above for its positive ones,
                // and no single pairing is right for both. Dropping it would
                // discard a real constraint and cut the feasible set, which is
                // the one thing this library must never do. So the row joins
                // BOTH groups, carrying its negative part into `lower` and its
                // positive part into `upper`. Each part then multiplies the
                // opposite group by a non-negative factor, so the `<=`
                // direction survives and every derived row stays valid for
                // every realisation of the coefficient. The cost is duplicate
                // constraints and a looser answer; the benefit is that the
                // result is always a superset of the truth.
                .straddle => {
                    try lower.append(gpa, .{
                        .coeff = Interval.init(a.lo, @min(a.hi, 0.0)),
                        .row = row,
                    });
                    try upper.append(gpa, .{
                        .coeff = Interval.init(@max(a.lo, 0.0), a.hi),
                        .row = row,
                    });
                },
            }
        }

        for (lower.items) |l| {
            for (upper.items) |u| {
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
    /// `eliminationOrder` reports. Returns false as soon as a contradiction
    /// proves the system unsatisfiable, and stops early there.
    pub fn eliminateInOrderOfChoice(self: *System) !bool {
        while (try self.chooseNext()) |k| {
            try self.eliminate(k);
            if (self.unsat) return false;
        }
        return true;
    }

    /// Eliminate every variable in Tupper's order, leaving only
    /// zero-dimensional rows behind. `count_out` receives false as soon as a
    /// contradiction proves the system unsatisfiable; the caller seeds it:
    ///
    ///     var satisfiable = true;
    ///     try sys.eliminateAll(&satisfiable);
    ///
    /// The parameter is `count_out` and not `count` because a parameter named
    /// `count` shadows the `count` method, which Zig rejects.
    pub fn eliminateAll(self: *System, count_out: *bool) !void {
        if (self.unsat) {
            count_out.* = false;
            return;
        }
        count_out.* = try self.eliminateInOrderOfChoice();
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
        // it, and the tightest of those wins.
        var lower: ?f64 = null;
        var upper: ?f64 = null;
        for (0..scratch.count()) |i| {
            const row = try scratch.at(i);
            const a = row.coeffs[k];
            switch (signOf(a)) {
                .zero => {},
                .negative => {
                    const q = row.rhs.div(a);
                    lower = if (lower) |v| @max(v, q.lo) else q.lo;
                },
                .positive => {
                    const q = row.rhs.div(a);
                    upper = if (upper) |v| @min(v, q.hi) else q.hi;
                },
                .straddle => {
                    // A coefficient that reaches zero still bounds the
                    // variable, and it bounds it from both sides. The row
                    // must hold for every realisation, so the binding one is
                    // the endpoint farthest from zero: `x_k` has one sign,
                    // and the coefficient sitting on the other side of it is
                    // the one that makes `a * x_k` largest. Dividing by that
                    // endpoint as a point is what makes the reading
                    // possible at all. The part itself cannot be the divisor,
                    // because the part reaches zero and `Interval.div`
                    // answers a zero-touching divisor with the unbounded
                    // interval, which is not a bound in either direction.
                    //
                    // The guards this replaces - `neg_part.hi < 0` and
                    // `pos_part.lo > 0` - were not merely narrow, they were
                    // unsatisfiable. A straddle has `lo <= 0 <= hi`, so
                    // `min(hi, 0) < 0` and `max(lo, 0) > 0` can both never
                    // hold, and this arm contributed nothing whatsoever. One
                    // round of elimination with an uncertain coefficient is
                    // enough to put a zero-touching endpoint in almost every
                    // derived coefficient, so almost every bounded variable
                    // read as unbounded. `eliminate` is happy with the same
                    // part, because there only the sign of the multiplier
                    // matters and a part that touches zero is still
                    // non-negative; this arm is the same one-sided reading,
                    // asked of the same object.
                    if (a.lo < 0) {
                        const q = row.rhs.div(Interval.init(a.lo, a.lo));
                        lower = if (lower) |v| @max(v, q.lo) else q.lo;
                    }
                    if (a.hi > 0) {
                        const q = row.rhs.div(Interval.init(a.hi, a.hi));
                        upper = if (upper) |v| @min(v, q.hi) else q.hi;
                    }
                },
            }
        }

        const lo = lower orelse return null;
        const hi = upper orelse return null;
        if (lo > hi) return null;

        // The sweep above keeps `k` alive on purpose, because that is what
        // leaves a row to read a bound from, and it is also why
        // `noteContradiction` has nothing to fire on: a contradiction is a
        // row with every coefficient exactly zero, and while `k` is alive no
        // derived row is that. Dropping `k` as well costs one more round and
        // is the only way a contradiction among the rows becomes visible
        // here, so it runs before the answer is handed back. The bounds are
        // already read off by this point, and eliminating `k` discards the
        // rows they came from.
        if (scratch.alive[k]) {
            try scratch.eliminate(k);
            if (scratch.unsat) return null;
        }
        return Interval.init(lo, hi);
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
        var out = System.init(self.gpa, self.var_count);
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
    /// generate. A straddling coefficient counts in both, because it is
    /// paired from both sides.
    fn pairCount(self: System, k: usize) !usize {
        var lower: usize = 0;
        var upper: usize = 0;
        for (0..self.count()) |i| {
            switch (signOf((try self.at(i)).coeffs[k])) {
                .negative => lower += 1,
                .positive => upper += 1,
                .straddle => {
                    lower += 1;
                    upper += 1;
                },
                .zero => {},
            }
        }
        return lower * upper;
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
        for (0..self.count()) |i| {
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
        // A zero coefficient is structural, not numerical: the variable is
        // simply absent from that row. A product with an exact zero factor
        // is exactly zero, `x - 0` is `x`, and `-x` is `Interval.neg`, which
        // is exact. So a variable that no row mentions stays exactly [0, 0]
        // through the whole elimination instead of drifting.
        //
        // Letting the general form run on a structural zero would hand it to
        // the outward widening, which turns [0, 0] into a subnormal
        // straddle. Every later elimination reads that straddle as a
        // constraint from both sides and pairs rows that share no variable
        // at all, and the row count compounds for nothing. It is a soundness
        // question too: a coefficient that is exactly zero must be free of
        // the variable, and a straddle does not say that.
        const lj = lower.row.coeffs[j];
        const uj = upper.row.coeffs[j];
        const combined = if (isExactZero(lj) and isExactZero(uj))
            zero
        else if (isExactZero(lj))
            lower.coeff.mul(uj).neg()
        else if (isExactZero(uj))
            upper.coeff.mul(lj)
        else
            upper.coeff.mul(lj).sub(lower.coeff.mul(uj));
        try coeffs.append(gpa, combined);
    }
    const bound = upper.coeff.mul(lower.row.rhs)
        .sub(lower.coeff.mul(upper.row.rhs));
    try rhs.append(gpa, bound);
}

/// True only for the exact zero interval, not for a widening artefact that
/// happens to be small.
fn isExactZero(a: Interval) bool {
    return a.lo == 0 and a.hi == 0;
}

fn isAllZero(coeffs: []const Interval) bool {
    for (coeffs) |a| {
        if (!isExactZero(a)) return false;
    }
    return true;
}
