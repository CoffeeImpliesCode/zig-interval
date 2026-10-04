//! The four-geometry trigonometric surface: four geometries, six functions,
//! and the three questions one can ask of each of them -- the value, the
//! principal inverse, and the whole inverse family.
//!
//! ## The geometries
//!
//! The circle is the usual one: `sin`, `cos`, `tan` with `csc = 1/sin`,
//! `sec = 1/cos`, `cot = cos/sin`. The hyperbola is the same six names over
//! `sinh`, `cosh`, `tanh`.
//!
//! The two polygons are fixed by a CONVENTION CHOSEN HERE, not by any claim
//! about another program. The angle is a radial angle in radians. Writing
//! `s = sin(theta)` and `c = cos(theta)`, the diamond point is
//! `(c, s) / (|c| + |s|)` and the square point is `(c, s) / max(|c|, |s|)`.
//! In both of them the RATIO functions stay circular, because a common factor
//! cancels in `s/c` and in `c/s`; only the two coordinates and their
//! reciprocals change.
//!
//! Three facts about those normalizations carry the implementation:
//!
//!  * `|c| + |s| >= 1` everywhere, since `(a+b)^2 >= a^2 + b^2 = 1` for
//!    `a = |c|`, `b = |s|`. That proved bound is used twice: it says the
//!    diamond's denominator is bounded away from zero, so it has no pole
//!    case, and it is the clip that keeps a cell straddling an axis point --
//!    where `|c|` really does reach zero -- from dividing by an interval
//!    that reaches zero with it. The same bound says both coordinates are at
//!    most one in magnitude, in either polygon.
//!  * On a cell of width at most `pi/16` one of `|c|` and `|s|` is at least
//!    `cos(pi/32) > 0.99`, so the diamond's two coordinates vary little
//!    relative to each other on one cell. That is why its grid is the finer
//!    one: a wider cell couples them through the normalizer and the division
//!    loses the corner.
//!  * On the square's octants one coordinate is exactly `sign(s)` or
//!    `sign(c)`, so the square has flat tops and flat sides: whole intervals
//!    of angles carry one value, and those are level sets which are
//!    INTERVALS rather than points.
//!
//! ## How a range is computed
//!
//! For the circle and the hyperbola the answer is one certified evaluation
//! over the whole argument, guarded by the location of the zeros and poles.
//! The guard matters: `1/sin` over an argument containing a zero of `sin`
//! has no finite bound at all, and an evaluation that only looked at the two
//! ends of such an argument would report a finite pair of numbers that the
//! true image does not have. So the zeros and poles are located first, with
//! the shared helpers of `interval_ext.zig`, and a hit answers unbounded.
//!
//! For the two polygons the argument is WALKED over a grid of certified
//! cells, because both coordinates enter each answer through one
//! normalisation and the two of them are only independent one cell at a
//! time. Each grid point is an interval, not a number -- no multiple of pi
//! is a float -- and the walk therefore uses two kinds of cell:
//!
//!  * a PIECE, from the upper bound of grid point `j-1` to the lower bound of
//!    grid point `j`, which lies entirely inside the true stretch between the
//!    two grid points. For the square this is where the octant formula is
//!    exactly right, with no spill.
//!  * a JUNCTION, from the lower to the upper bound of one grid point, which
//!    straddles the true grid point itself. Every true grid point is inside
//!    the junction around it, which is what stops an extremum or a pole from
//!    falling between two cells.
//!
//! The two kinds together cover the argument with no gap, and nothing is
//! missed at the joins. A junction of the square is evaluated as the hull of
//! the formulas of the octants on either side of it, so the answer there is
//! right on both sides of the boundary instead of right on only one.
//!
//! Two documented fallbacks return a PROVEN WHOLE RANGE rather than
//! enumerating: an argument whose magnitude exceeds `phase_limit = 1e17`,
//! where the index of a grid point has outgrown exact f64 integers, and an
//! argument spanning more than `max_cells` cells. Both are safe rather than
//! lazy, because every function here attains its whole range inside a single
//! period -- the circle's tangent has a pole in every period and the diamond
//! reaches `+-1` at the axis points -- so a wider argument can only add
//! values the whole range already contains.
//!
//! ## Numbers
//!
//! Every transcendental evaluation goes through the certified `f128` kernels
//! in `certified.zig`, and the answer is the DIRECTED PROJECTION of the
//! outward `f128` interval it returns -- no more. Nothing here asks
//! `std.math` for a point value and pads it, and nothing pads it a second
//! time afterwards either: those kernels already carry the roundoff of every
//! primitive they use and an analytic remainder bound on the truncation, so
//! `project` is a sound enclosure on its own and any extra width added on
//! top of it would be widening for its own sake rather than for the maths.
//! An answer here is as narrow as the evidence allows, and a containment
//! check that fails against it is saying something about the check.
//!
//! Lattice angles (`k*pi`, `k*pi/d`) go through the certified arithmetic as
//! well: the index is bracketed by `Bounds.fromInt`, which is exact for EVERY
//! `i128` rather than merely for the indices an f64 holds, and the product
//! and the division are outward `f128` operations. So a branch index of any
//! magnitude, negative or beyond `2^53`, lands on the right angle without a
//! double conversion of the index or a slack term guessed to cover one.
//!
//! That reduction and the one `interval_ext.zig` makes for a critical-point
//! INDEX are deliberately two different things and neither is derived from
//! the other. Both come from `cert.pi`, so there is one constant and no way
//! for the two to drift.

const interval_mod = @import("interval.zig");
const Interval = interval_mod.Interval;
const rounding = @import("rounding.zig");
const ext = @import("interval_ext.zig");
const cert = @import("certified.zig");
const Bounds = cert.Bounds;

const pos_inf: f64 = rounding.pos_inf;
const neg_inf: f64 = rounding.neg_inf;

/// Which curve the angle moves on.
pub const Geometry = enum {
    /// `(cos, sin)`, with the ratios `sin/cos` and `cos/sin`.
    circle,
    /// `(cosh, sinh)`, with the ratios `tanh` and `coth`.
    hyperbola,
    /// `(c, s) / (|c| + |s|)`.
    diamond,
    /// `(c, s) / max(|c|, |s|)`.
    square,
};

/// Which of the six functions of a geometry. `csc`, `sec` and `cot` are the
/// reciprocals `1/sin`, `1/cos` and `cos/sin` of the same geometry: the
/// circular ratios for the circle, the diamond and the square, and the
/// hyperbolic ones for the hyperbola.
pub const Function = enum { sin, cos, tan, csc, sec, cot };

// ---------------------------------------------------------------------------
// Certified arithmetic: the whole of the outward rounding
// ---------------------------------------------------------------------------

/// The image of a certified kernel: the directed projection of the outward
/// `f128` interval, and nothing else.
///
/// That projection is a sound enclosure on its own. Each kernel already
/// covers the roundoff of every primitive it uses, and the analytic
/// remainder bound it carries covers the truncation, so the `f128` interval
/// it returns contains the true value; `project` then rounds each bound away
/// from it in binary. Widening past that would be widening for its own sake:
/// it makes no answer truer, and it makes every answer worse at detecting a
/// consumer that relies on a width.
fn bound(b: Bounds) Interval {
    return Bounds.project(b);
}

fn boundsOf(x: Interval) Bounds {
    return Bounds.fromInterval(x);
}

fn pointOf(v: f64) Interval {
    return Interval.init(v, v);
}

/// The whole line, for the functions whose image really is unbounded.
fn wholeLine() Interval {
    return Interval.init(neg_inf, pos_inf);
}

/// Negation of an interval is exact, so applying a known sign factor costs
/// nothing and cannot widen.
fn scaleSign(v: Interval, sign: f64) Interval {
    return if (sign > 0.0) v else v.neg();
}

// ---------------------------------------------------------------------------
// Lattice angles: certified rational multiples of pi
// ---------------------------------------------------------------------------

/// An interval containing `k*pi/d` for an integer `k` and a positive
/// integer `d`.
///
/// The index goes in as an integer and comes back out through the certified
/// arithmetic, which is what makes this exact for EVERY index and not only
/// for the ones an f64 happens to hold. Converting `k` to a float first and
/// multiplying would lose the index twice over -- once at the conversion and
/// again in the rounding of the product -- and a slack term wide enough to
/// cover that would be a guess dressed as a bound.
fn piMultiple(k: i128, d: i64) Interval {
    const kpi = Bounds.mul(Bounds.fromInt(k), cert.pi);
    // Dividing by the point one changes nothing and still costs a division,
    // and every lattice angle with `d` of one skips it.
    if (d == 1) return kpi.project();
    return Bounds.div(kpi, Bounds.point(@as(f64, @floatFromInt(d)))).project();
}

fn halfPi() Interval {
    return piMultiple(1, 2);
}

fn quarterPi() Interval {
    return piMultiple(1, 4);
}

/// The interval of angles on which the square's SECOND coordinate is one:
/// `[pi/4 + k*pi, 3pi/4 + k*pi]`.
///
/// On such a stretch `|s| >= |c|` and `s > 0`, so `s/max(|c|,|s|)` is
/// `s/|s|`, which is one EXACTLY. Every angle of the interval carries the
/// value one, and no single point of it is special.
fn squareSinPlateau(k: i64) Interval {
    const m = piMultiple(k, 1);
    return Interval.init(quarterPi().add(m).lo, piMultiple(3, 4).add(m).hi);
}

/// The interval of angles on which the square's FIRST coordinate is one:
/// `[-pi/4 + k*pi, pi/4 + k*pi]`, the same argument with `c` in place of `s`.
fn squareCosPlateau(k: i64) Interval {
    const m = piMultiple(k, 1);
    return Interval.init(piMultiple(-1, 4).add(m).lo, quarterPi().add(m).hi);
}

// ---------------------------------------------------------------------------
// Reciprocals at or near a pole
// ---------------------------------------------------------------------------

/// The image of `1/d` for `d` in the given interval.
///
/// `d` crossing zero means the reciprocal is unbounded in both directions,
/// and `d` TOUCHING zero means it is unbounded in exactly one: `d = [0, b]`
/// has `1/d` rising to `+inf` as `d` falls to zero, and `d = [a, 0]` falls to
/// `-inf`. Both are read off the sign of the endpoint that is zero, and the
/// endpoints themselves are the only infinities this file needs, so they get
/// no widening.
fn recipRange(d: Interval) Interval {
    // Away from zero the whole reciprocal image is the interval division of
    // the point one by `d`, which rounds each end outward on its own.
    if (d.lo > 0.0 or d.hi < 0.0) return d.recip();
    // `d = [0, b]` rises to `+inf` as `d` falls to zero, and its lowest
    // value is `1/b`, taken at `d = b`.
    if (d.lo == 0.0 and d.hi > 0.0) {
        return Interval.init(pointOf(1.0).div(pointOf(d.hi)).lo, pos_inf);
    }
    // `d = [a, 0]` is the same thing with the sign reversed.
    if (d.hi == 0.0 and d.lo < 0.0) {
        return Interval.init(neg_inf, pointOf(1.0).div(pointOf(d.lo)).hi);
    }
    return wholeLine();
}

/// `1/x` for an argument of an inverse, or null when `x` is exactly the
/// point zero and there is no image at all.
///
/// An argument that straddles zero has a reciprocal image in two pieces, one
/// on each side; the answer of this file is a single interval, so those two
/// pieces are hulled. That hull contains zero, which no real reciprocal of
/// the two pieces equals, and it is still a sound enclosure of both.
fn recipForInverse(x: Interval) ?Interval {
    if (x.lo == 0.0 and x.hi == 0.0) return null;
    if (x.lo >= 0.0) return recipRange(x);
    if (x.hi <= 0.0) return recipRange(x);
    const negative = recipRange(Interval.init(x.lo, 0.0));
    const positive = recipRange(Interval.init(0.0, x.hi));
    return negative.hull(positive);
}

// ---------------------------------------------------------------------------
// Level sets: which values have an angle at all
// ---------------------------------------------------------------------------

/// True when no real angle of geometry `g` maps into `x`, so that the
/// principal inverse and every branch of the family have no answer.
///
/// The ranges used here are the definitions, not approximations: the circle,
/// the diamond and the square have both coordinates in `[-1, 1]`, so their
/// sine and cosine live there and their reciprocals live in `|y| >= 1`; the
/// tangent is onto the reals and the cotangent misses exactly zero, being a
/// coordinate over a nonzero one. On the hyperbola `cosh` is at least one,
/// `tanh` is strictly between minus one and one, `sech` is in `(0, 1]`, and
/// `csch` and `coth` miss exactly zero.
fn levelSetEmpty(g: Geometry, f: Function, x: Interval) bool {
    return switch (g) {
        .circle, .diamond, .square => switch (f) {
            .sin, .cos => x.lo > 1.0 or x.hi < -1.0,
            .tan => false,
            .csc, .sec => x.hi < 1.0 or x.lo > -1.0,
            .cot => x.lo == 0.0 and x.hi == 0.0,
        },
        .hyperbola => switch (f) {
            .sin => false,
            .cos => x.hi < 1.0,
            .tan => x.hi >= 1.0 or x.lo <= -1.0,
            .csc => x.lo == 0.0 and x.hi == 0.0,
            .sec => x.hi > 1.0 or x.lo <= 0.0,
            .cot => x.hi <= 1.0 and x.lo >= -1.0,
        },
    };
}

/// True when the forward image of `x` is empty, which is the only case
/// `forward` answers null.
///
/// Every one of these twenty-four functions is defined except at a DISCRETE
/// set of angles -- the zeros of `sin`, `cos` and `sinh` -- so any argument
/// of positive width contains an angle where the function is defined and its
/// image cannot be empty. An argument that IS a pole has an empty image, and
/// the only exactly representable member of any pole set is the point zero,
/// since no f64 is exactly `pi/2`, `pi` or `3pi/4`. So the empty cases are
/// exactly the point zero asked about the two functions that divide by a
/// coordinate vanishing there.
fn forwardEmpty(f: Function, x: Interval) bool {
    if (x.lo != 0.0 or x.hi != 0.0) return false;
    return switch (f) {
        .csc, .cot => true,
        .sin, .cos, .tan, .sec => false,
    };
}

// ---------------------------------------------------------------------------
// Zeros and poles inside an argument
// ---------------------------------------------------------------------------

/// True when some multiple of pi may lie in `x`: a zero of the sine.
///
/// `criticalIndices` is a SUPERSET of the indices whose true `k*pi` meets `x`,
/// so a positive answer may be a false alarm. A false alarm here costs a
/// whole-line answer where a finite one was available, which is wider but
/// still sound; a missing zero, which is the failure that matters, cannot
/// happen. `null` is a refusal, not an absence, and is reported as a hit.
fn sineZeroIn(x: Interval) bool {
    const r = ext.criticalIndices(x, Bounds.point(0.0), cert.pi) orelse return true;
    return r.first <= r.last;
}

/// True when some pole of the tangent may lie in `x`: a zero of the cosine,
/// which is the same point as the pole of the secant and of the cotangent.
///
/// `tangentCells` gives the labels of the cells a tangent branch occupies,
/// and a label says only that the argument reaches into that cell -- not
/// that the pole inside it is reached. So the labels are narrowed with the
/// pole positions themselves, which are outward enclosures and therefore
/// never report a pole the argument misses by more than a rounding step.
fn cosineZeroIn(x: Interval) bool {
    const r = ext.tangentCells(x) orelse return true;
    if (r.first > r.last) return false;
    var k: i128 = r.first;
    while (true) {
        if (ext.tangentPole(k).overlaps(x)) return true;
        if (k >= r.last) return false;
        k += 1;
    }
}

// ---------------------------------------------------------------------------
// The polygon cell grid
// ---------------------------------------------------------------------------

/// Past this magnitude the index of a grid point has outgrown the integers
/// an f64 holds exactly. The last of those is `2^53`, and `1e17` is well
/// past it, so a grid point there cannot be located by counting.
const phase_limit: f64 = 1e17;

/// How many cells one call is willing to walk. Every function of a polygon
/// attains its whole range inside one period, so a wider argument can only
/// add values the whole range already contains.
const max_cells: i128 = 255;

/// The grid spacing of a polygon, as a number of cells per pi. The square
/// needs the octant grid, because its answer changes FORM at an octant
/// boundary; the diamond needs only enough resolution for its normalizer to
/// stay positive, and `pi/16` is what buys that.
const square_grid: i64 = 4;
const diamond_grid: i64 = 16;

/// `pi/m` as certified bounds.
fn gridPeriod(m: i64) Bounds {
    return Bounds.div(cert.pi, Bounds.point(@as(f64, @floatFromInt(m))));
}

/// The grid indices around `x`, or null when the argument is past the phase
/// limit or spans too many cells to enumerate honestly.
fn cellRange(x: Interval, m: i64) ?ext.IndexRange {
    if (@abs(x.lo) > phase_limit or @abs(x.hi) > phase_limit) return null;
    const r = ext.criticalIndices(x, Bounds.point(0.0), gridPeriod(m)) orelse return null;
    if (r.last - r.first > max_cells) return null;
    return r;
}

/// The piece of `x` between grid points `j-1` and `j`: from the upper bound
/// of the first to the lower bound of the second. That lies entirely INSIDE
/// the true stretch between the two grid points, which is what the octant
/// formulas of the square need.
fn pieceInterval(x: Interval, j: i128, m: i64) ?Interval {
    const lo = @max(x.lo, piMultiple(j - 1, m).hi);
    const hi = @min(x.hi, piMultiple(j, m).lo);
    if (lo > hi) return null;
    return Interval.init(lo, hi);
}

/// The junction of `x` around grid point `j`: from the lower to the upper
/// bound of that one grid point. It straddles the true grid point, which is
/// the only way a critical point or a pole can be sure of being inside some
/// cell rather than between two of them.
fn junctionInterval(x: Interval, j: i128, m: i64) ?Interval {
    const g = piMultiple(j, m);
    const lo = @max(x.lo, g.lo);
    const hi = @min(x.hi, g.hi);
    if (lo > hi) return null;
    return Interval.init(lo, hi);
}

fn joinCell(hull: ?Interval, v: ?Interval) ?Interval {
    const cell = v orelse return hull;
    return hull orelse cell else hull.?.hull(cell);
}

fn clampUnit(v: Interval) Interval {
    const unit = Interval.init(-1.0, 1.0);
    if (!v.overlaps(unit)) return v;
    return v.intersect(unit).?;
}

// ---------------------------------------------------------------------------
// Whole proven ranges
// ---------------------------------------------------------------------------

fn sinhOf(x: Interval) Interval {
    return bound(cert.sinh(boundsOf(x)));
}

fn coshOf(x: Interval) Interval {
    return bound(cert.cosh(boundsOf(x)));
}

fn tanhOf(x: Interval) Interval {
    return bound(cert.tanh(boundsOf(x)));
}

/// One side of zero for `coth`.
///
/// `cosh(x) - sinh(x) = exp(-x) > 0` for every real `x`, so `coth` is
/// strictly greater than one on the positive side and strictly less than
/// minus one on the negative side, and it tends to `+-1` at infinity. The
/// image therefore reaches `1` as a limit without ever equalling it, and
/// taking that limit as a bound is what makes the answer contain one on the
/// positive side and minus one on the negative side -- which an answer taken
/// only at the ends of the argument would miss.
///
/// An argument large enough to overflow a corner of the quotient `cosh/sinh`
/// is answered with the whole range instead: such a corner is `inf/inf`, and
/// a NaN is not an endpoint an interval can hold.
fn cothSide(x: Interval, side: f64) Interval {
    const s = sinhOf(x);
    const c = coshOf(x.abs());
    if (!(@isFinite(s.lo) and @isFinite(s.hi) and
        @isFinite(c.lo) and @isFinite(c.hi)))
    {
        return wholeLine();
    }
    const ratio = c.div(s);
    return if (side > 0.0)
        Interval.init(1.0, ratio.hi)
    else
        Interval.init(ratio.lo, -1.0);
}

/// The range of `coth`, which has a pole at zero on both sides.
fn cothOf(x: Interval) Interval {
    if (x.hi < 0.0) return cothSide(x, -1.0);
    if (x.lo > 0.0) return cothSide(x, 1.0);
    return wholeLine();
}

/// The range of `csch`, which is `1/sinh`.
fn cschOf(x: Interval) Interval {
    return recipRange(sinhOf(x));
}

/// The range of `sech`, which is `1/cosh`; `cosh` is even and at least one,
/// so the magnitude of the reciprocal is bounded by one.
fn sechOf(x: Interval) Interval {
    return recipRange(coshOf(x.abs()));
}

/// The whole range of one of the twenty-four functions, used where the walk
/// is not attempted at all.
fn wholeRange(g: Geometry, f: Function) Interval {
    return switch (g) {
        .circle, .diamond, .square => switch (f) {
            .sin, .cos => Interval.init(-1.0, 1.0),
            .tan, .csc, .sec, .cot => wholeLine(),
        },
        .hyperbola => switch (f) {
            .sin, .csc, .cot => wholeLine(),
            .cos => Interval.init(1.0, pos_inf),
            .tan => Interval.init(-1.0, 1.0),
            .sec => Interval.init(0.0, 1.0),
        },
    };
}

// ---------------------------------------------------------------------------
// Forward
// ---------------------------------------------------------------------------

/// The value of `f` of geometry `g` over the argument `x`, or null when the
/// image is empty.
///
/// Null here is the strong claim that no real angle in `x` produces a value
/// at all; it is not a statement that the answer would be inconvenient. A
/// proven whole range is returned where the walk is not attempted, and never
/// an invented substitute for a value this argument range does contain.
pub fn forward(g: Geometry, f: Function, x: Interval) ?Interval {
    if (forwardEmpty(f, x)) return null;
    return switch (g) {
        .circle => circleForward(f, x),
        .diamond => diamondForward(f, x),
        .square => squareForward(f, x),
        .hyperbola => switch (f) {
            .sin => sinhOf(x),
            .cos => coshOf(x.abs()),
            .tan => tanhOf(x),
            .csc => cschOf(x),
            .sec => sechOf(x),
            .cot => cothOf(x),
        },
    };
}

/// The circle, where the answer is one certified evaluation over the whole
/// argument guarded by the zeros and poles.
///
/// `tan` has a pole at every multiple of `pi/2`, and `sec` and `cot` divide
/// by the cosine and by the sine there, so one test covers all three.
/// `csc` and `cot` divide by the sine, whose zeros are the multiples of `pi`.
fn circleForward(f: Function, x: Interval) Interval {
    return switch (f) {
        .sin => bound(cert.sin(boundsOf(x))),
        .cos => bound(cert.cos(boundsOf(x))),
        .tan => if (cosineZeroIn(x))
            wholeLine()
        else
            bound(cert.tan(boundsOf(x))),
        .csc => if (sineZeroIn(x))
            wholeLine()
        else
            recipRange(bound(cert.sin(boundsOf(x)))),
        .sec => if (cosineZeroIn(x))
            wholeLine()
        else
            recipRange(bound(cert.cos(boundsOf(x)))),
        .cot => if (sineZeroIn(x))
            wholeLine()
        else
            bound(cert.cos(boundsOf(x))).div(bound(cert.sin(boundsOf(x)))),
    };
}

/// The diamond, walked over its grid of cells.
///
/// The formula `c/(|c|+|s|)` is valid on the whole line, so a junction is
/// evaluated exactly as a piece is. The grid is finer than the square's
/// because the normalizer is the one quantity here that has to stay away
/// from zero: on a cell of width `pi/16` one of the two coordinates is at
/// least `cos(pi/32)`, so the sum formed on that cell never reaches zero.
fn diamondForward(f: Function, x: Interval) Interval {
    return walkPolygon(.diamond, f, x, diamond_grid);
}

/// The square, walked over its octant grid. See `squareOctant`.
fn squareForward(f: Function, x: Interval) Interval {
    return walkPolygon(.square, f, x, square_grid);
}

/// The walk shared by the two polygons: the pieces and the junctions, which
/// between them cover the argument with no gap.
fn walkPolygon(g: Geometry, f: Function, x: Interval, m: i64) Interval {
    const cells = cellRange(x, m) orelse return wholeRange(g, f);
    var hull: ?Interval = null;
    // The junctions, one per grid point the argument reaches or passes.
    var j: i128 = cells.first - 1;
    const jstop: i128 = cells.last + 1;
    while (j <= jstop) : (j += 1) {
        const jc = junctionInterval(x, j, m);
        hull = joinCell(hull, if (jc) |arg| polygonJunction(g, f, j, arg) else null);
    }
    // The pieces between them.
    var p: i128 = cells.first - 1;
    const pstop: i128 = cells.last;
    while (p <= pstop) : (p += 1) {
        const pc = pieceInterval(x, p, m);
        hull = joinCell(hull, if (pc) |arg| polygonPiece(g, f, p, arg) else null);
    }
    const h = hull orelse return wholeRange(g, f);
    // Both polygons are bounded by one in each coordinate, which the
    // division can only lose to its own rounding.
    return switch (f) {
        .sin, .cos => clampUnit(h),
        else => h,
    };
}

fn polygonPiece(g: Geometry, f: Function, j: i128, arg: Interval) Interval {
    return switch (g) {
        .diamond => diamondCell(f, arg),
        .square => squareOctant(f, j, arg),
        .circle, .hyperbola => unreachable,
    };
}

fn polygonJunction(g: Geometry, f: Function, j: i128, arg: Interval) Interval {
    return switch (g) {
        .diamond => diamondCell(f, arg),
        // A junction straddles an octant boundary, where the form of the
        // answer changes, so it is answered as the hull of the two forms.
        // Each is within a rounding step of the true value there, and their
        // hull contains the true image.
        .square => squareOctant(f, j - 1, arg).hull(squareOctant(f, j, arg)),
        .circle, .hyperbola => unreachable,
    };
}

/// One cell of the diamond. The normalizer is `|c| + |s|`, which is at least
/// one everywhere, and that proved bound is used to clip it: a junction that
/// straddles an axis point sees `|c|` reach zero there, and without the clip
/// the sum would too and every coordinate would divide by an interval that
/// reaches zero. The ratio functions still divide by a coordinate that can
/// vanish, which `div` answers with the whole line.
fn diamondCell(f: Function, arg: Interval) Interval {
    const s = bound(cert.sin(boundsOf(arg)));
    const c = bound(cert.cos(boundsOf(arg)));
    const raw = s.abs().add(c.abs());
    const den = Interval.init(1.0, @max(raw.hi, 1.0));
    return switch (f) {
        .sin => s.div(den),
        .cos => c.div(den),
        .tan => s.div(c),
        .cot => c.div(s),
        .csc => den.div(s),
        .sec => den.div(c),
    };
}

/// The whole of octant `j` of the square's grid, by the formula of that
/// octant rather than by evaluating a quotient.
///
/// Octant `j` covers `[j*pi/4, (j+1)*pi/4]`. Inside it `|s| >= |c|` exactly
/// when `j` is one or two into a group of four, which is the stretch within
/// `pi/4` of `pi/2`. On those octants the second coordinate is `sign(s)`
/// EXACTLY and the first is `cot * sign(s)`; on the others it is the other
/// way round. The signs come from the index modulo eight, with floor division
/// by four for the sine, so the whole classification is arithmetic on
/// integers and not an inequality a rounding step could go the wrong side of.
fn squareOctant(f: Function, j: i128, arg: Interval) Interval {
    const into_four: i128 = @mod(j, 4);
    const sin_dominant = into_four == 1 or into_four == 2;
    const sin_sign: f64 = if (@mod(@divFloor(j, 4), 2) == 0) 1.0 else -1.0;
    const into_eight: i128 = @mod(j, 8);
    const cos_sign: f64 = if (into_eight == 0 or into_eight == 1 or
        into_eight == 6 or into_eight == 7) 1.0 else -1.0;
    return switch (f) {
        // Where `|s| >= |c|`: the second coordinate IS `sign(s)` and the
        // cosecant is the same constant, while the first is `cot*sign(s)`
        // and the secant is `tan*sign(s)`.
        .sin => if (sin_dominant)
            pointOf(sin_sign)
        else
            tangentOver(arg, cos_sign),
        .csc => if (sin_dominant)
            pointOf(sin_sign)
        else
            cotangentOver(arg, cos_sign),
        // Where `|c| > |s|`: the first coordinate IS `sign(c)` and the
        // secant is the same constant, while the second is `tan*sign(c)`
        // and the cosecant is `cot*sign(c)`.
        .cos => if (sin_dominant)
            cotangentOver(arg, sin_sign)
        else
            pointOf(cos_sign),
        .sec => if (sin_dominant)
            tangentOver(arg, sin_sign)
        else
            pointOf(cos_sign),
        .tan => tangentOver(arg, 1.0),
        .cot => cotangentOver(arg, 1.0),
    };
}

/// `tan` over an argument, with a normalization sign applied. An argument
/// that reaches a pole of the tangent has an unbounded image.
fn tangentOver(arg: Interval, sign: f64) Interval {
    const c = bound(cert.cos(boundsOf(arg)));
    const v = if (c.lo <= 0.0 and c.hi >= 0.0)
        wholeLine()
    else
        bound(cert.tan(boundsOf(arg)));
    return scaleSign(v, sign);
}

/// `cot = cos/sin` over an argument, with a normalization sign applied. An
/// argument that reaches a zero of the sine divides by an interval that
/// touches zero, which `div` answers with the whole line.
fn cotangentOver(arg: Interval, sign: f64) Interval {
    const c = bound(cert.cos(boundsOf(arg)));
    const s = bound(cert.sin(boundsOf(arg)));
    return scaleSign(c.div(s), sign);
}

// ---------------------------------------------------------------------------
// Principal inverse
// ---------------------------------------------------------------------------

fn clipLow1(x: Interval) Interval {
    return Interval.init(@max(x.lo, 1.0), x.hi);
}

fn atanOf(x: Interval) Interval {
    return bound(cert.atan(boundsOf(x)));
}

fn asinOf(x: Interval) Interval {
    return bound(cert.asin(boundsOf(x)));
}

fn acosOf(x: Interval) Interval {
    return bound(cert.acos(boundsOf(x)));
}

fn asinhOf(x: Interval) Interval {
    return bound(cert.asinh(boundsOf(x)));
}

fn acoshOf(x: Interval) Interval {
    return bound(cert.acosh(boundsOf(x)));
}

fn atanhOf(x: Interval) Interval {
    return bound(cert.atanh(boundsOf(x)));
}

/// The branch of the cotangent's inverse in `(0, pi)`.
///
/// It is `pi/2 - atan(y)`: at `y = 0` that is `pi/2`, at `y = 1` it is
/// `pi/4`, and at `y = -1` it is `3pi/4`, which is the half turn and not
/// `-pi/4`. It is the same expression in every geometry, because the
/// cotangent is the circular one in all of them.
fn cotPrincipal(y: Interval) Interval {
    return halfPi().sub(atanOf(y));
}

/// The principal arcsine of the diamond: `sign(y)*atan(|y|/(1-|y|))`.
///
/// Solving `|s| = |y|(|c| + |s|)` with `|c|^2 + |s|^2 = 1` gives
/// `|tan(theta)| = |y|/(1-|y|)`, which is the inverse of the ratio
/// functions; the sign of the angle is the sign of `y`, because the
/// normalizer `|c| + |s|` is positive. The ends of the range are the
/// vertices, reached as `|y|` tends to one, and the end is the quarter turn.
fn diamondArcsinMagnitude(u: Interval) Interval {
    // u is |y| clipped to [0, 1].
    if (u.lo >= 1.0) return halfPi();
    if (u.hi < 1.0) {
        const den = Interval.init(0.0, 1.0).sub(u);
        return atanOf(u.div(den));
    }
    // The argument reaches a vertex, so the magnitude rises to the quarter
    // turn. Its lower end still comes from the smaller magnitude, which is
    // the ratio at `u.lo`, and the upper end is the vertex itself.
    const den = pointOf(1.0).sub(pointOf(u.lo));
    const at_lo = atanOf(pointOf(u.lo).div(den));
    return Interval.init(@min(at_lo.lo, halfPi().lo), halfPi().hi);
}

fn diamondArcsin(y: Interval) ?Interval {
    const u = y.abs().intersect(Interval.init(0.0, 1.0)) orelse return null;
    const mag = diamondArcsinMagnitude(u);
    if (y.lo >= 0.0) return Interval.init(mag.lo, mag.hi);
    if (y.hi <= 0.0) return Interval.init(-mag.hi, -mag.lo);
    return Interval.init(-mag.hi, mag.hi);
}

fn diamondArccos(y: Interval) ?Interval {
    const a = diamondArcsin(y) orelse return null;
    return halfPi().sub(a);
}

/// The principal arcsine of the square: `atan(y)` on `[-1, 1]`, chosen so
/// that each coordinate inverts on the octants where it is the dominant one,
/// which are exactly the octants where it is the tangent or the cotangent.
fn squareArcsin(y: Interval) Interval {
    return atanOf(clampUnit(y));
}

fn squareArccos(y: Interval) Interval {
    return halfPi().sub(squareArcsin(y));
}

/// The principal inverse of `f` of geometry `g`, or null when the argument
/// misses the range of `f` entirely.
pub fn principalInverse(g: Geometry, f: Function, x: Interval) ?Interval {
    if (levelSetEmpty(g, f, x)) return null;
    return switch (g) {
        .circle => switch (f) {
            .sin => asinOf(clampUnit(x)),
            .cos => acosOf(clampUnit(x)),
            .tan => atanOf(x),
            .csc => asinOf(clampUnit(recipForInverse(x) orelse return null)),
            .sec => acosOf(clampUnit(recipForInverse(x) orelse return null)),
            .cot => cotPrincipal(x),
        },
        .diamond => switch (f) {
            .sin => diamondArcsin(x),
            .cos => diamondArccos(x),
            .tan => atanOf(x),
            .csc => diamondArcsin(recipForInverse(x) orelse return null),
            .sec => diamondArccos(recipForInverse(x) orelse return null),
            .cot => cotPrincipal(x),
        },
        .square => switch (f) {
            .sin => squareArcsin(x),
            .cos => squareArccos(x),
            .tan => atanOf(x),
            .csc => squareArcsin(recipForInverse(x) orelse return null),
            .sec => squareArccos(recipForInverse(x) orelse return null),
            .cot => cotPrincipal(x),
        },
        .hyperbola => switch (f) {
            .sin => asinhOf(x),
            .cos => acoshOf(clipLow1(x)),
            .tan => atanhOf(clampUnit(x)),
            .csc => asinhOf(recipForInverse(x) orelse return null),
            .sec => acoshOf(clipLow1(recipForInverse(x) orelse return null)),
            .cot => atanhOf(clampUnit(recipForInverse(x) orelse return null)),
        },
    };
}

// ---------------------------------------------------------------------------
// The full inverse family
// ---------------------------------------------------------------------------

/// The whole mathematical inverse relation of one function at one value, as
/// a descriptor with no storage of its own: the lattice is carried by the
/// integer formula documented on `at`, not by a list built in advance.
/// Copying a `Family` copies three plain values; there is no allocator, no
/// handle and nothing to release.
pub const Family = struct {
    geometry: Geometry,
    function: Function,
    value: Interval,

    /// The angles of branch `k` for the value this family was built at, or
    /// null when there is no such branch.
    ///
    /// For the sine-like lattices the branch is `(-1)^k * P + k*pi`, with `P`
    /// the principal answer. For the cosine-like ones the even index `2n`
    /// carries `+P` and the odd index `2n+1` carries `-P`, a whole period
    /// apart. For the tangent and the cotangent the branch is `P + k*pi`. The
    /// integer `k` is a CONVENIENCE for looking at one branch of an infinite
    /// family and not a truncation of it: `branchCount` is null for all of
    /// these, and the formula holds for every integer `k`, negative ones
    /// included.
    pub fn at(self: Family, branch: i64) ?Interval {
        if (levelSetEmpty(self.geometry, self.function, self.value)) return null;
        return switch (self.geometry) {
            .circle, .diamond => latticeBranch(self.geometry, self.function, self.value, branch),
            .square => squareFamilyBranch(self.function, self.value, branch),
            .hyperbola => hyperFamilyBranch(self.function, self.value, branch),
        };
    }

    /// How many branches there are: null for an infinite family, and the
    /// count when it is finite. Zero means the level set is empty, which is
    /// a mathematical fact and not a resource failure.
    pub fn branchCount(self: Family) ?usize {
        if (levelSetEmpty(self.geometry, self.function, self.value)) return 0;
        return switch (self.geometry) {
            .circle, .diamond, .square => null,
            .hyperbola => switch (self.function) {
                // sinh, tanh, csch and coth each have one root where they
                // have one at all.
                .sin, .tan, .csc, .cot => 1,
                // cosh and sech are even, so they have two roots -- except at
                // their vertex, where the two roots are the same angle zero
                // and reporting them twice would report one angle twice.
                .cos, .sec => if (self.value.lo == 1.0 and self.value.hi == 1.0) 1 else 2,
            },
        };
    }
};

/// The inverse relation of `f` of geometry `g` at the value `x`.
pub fn inverseFamily(g: Geometry, f: Function, x: Interval) Family {
    return .{ .geometry = g, .function = f, .value = x };
}

fn latticeBranch(g: Geometry, f: Function, x: Interval, k: i64) ?Interval {
    const even = @mod(k, 2) == 0;
    return switch (f) {
        .sin, .csc => {
            const p = principalInverse(g, .sin, x) orelse return null;
            const v = if (even) p else p.neg();
            return v.add(piMultiple(k, 1));
        },
        .cos, .sec => {
            const p = principalInverse(g, .cos, x) orelse return null;
            const v = if (even) p else p.neg();
            const idx: i128 = if (even) @intCast(k) else @as(i128, k) - 1;
            return v.add(piMultiple(idx, 1));
        },
        .tan, .cot => {
            const p = principalInverse(g, f, x) orelse return null;
            return p.add(piMultiple(k, 1));
        },
    };
}

/// The square's family, which is the one place where a branch is an
/// INTERVAL of angles rather than a point of a lattice.
///
/// Where one coordinate of the square is exactly one, every angle of that
/// edge carries the value one, so the level set of one is a whole edge and
/// the branch that carries it has to carry the edge. The edge of branch `k`
/// is the flat stretch `[pi/4 + k*pi, 3pi/4 + k*pi]` for the second
/// coordinate and `[-pi/4 + k*pi, pi/4 + k*pi]` for the first, and its value
/// is one on an even `k` and minus one on an odd one. So the edge belongs to
/// the level set exactly when the value asked about contains that one, and
/// otherwise the branch is the plain lattice point.
fn squareFamilyBranch(f: Function, x: Interval, k: i64) ?Interval {
    const parity_value: f64 = if (@mod(k, 2) == 0) 1.0 else -1.0;
    switch (f) {
        .sin => {
            const u = clampUnit(x);
            var v = atanOf(u).add(piMultiple(k, 1));
            if (u.contains(parity_value)) v = v.hull(squareSinPlateau(k));
            return v;
        },
        .csc => {
            const q = recipForInverse(x) orelse return null;
            const u = clampUnit(q);
            var v = atanOf(u).add(piMultiple(k, 1));
            if (q.contains(parity_value)) v = v.hull(squareSinPlateau(k));
            return v;
        },
        .cos => {
            const u = clampUnit(x);
            var v = squareArccos(x).add(piMultiple(k, 1));
            if (u.contains(parity_value)) v = v.hull(squareCosPlateau(k));
            return v;
        },
        .sec => {
            const q = recipForInverse(x) orelse return null;
            const u = clampUnit(q);
            var v = squareArccos(q).add(piMultiple(k, 1));
            if (q.contains(parity_value)) v = v.hull(squareCosPlateau(k));
            return v;
        },
        .tan => return atanOf(x).add(piMultiple(k, 1)),
        .cot => return cotPrincipal(x).add(piMultiple(k, 1)),
    }
}

/// The hyperbolic family, which is finite and is enumerated by the branch
/// index itself. The even functions contribute the two roots of the same
/// even equation, one on each side of zero, and the odd ones a single root.
fn hyperFamilyBranch(f: Function, x: Interval, k: i64) ?Interval {
    const p = principalInverse(.hyperbola, f, x) orelse return null;
    return switch (f) {
        .sin, .tan, .csc, .cot => if (k == 0) p else null,
        .cos, .sec => switch (k) {
            0 => p,
            1 => p.neg(),
            else => null,
        },
    };
}