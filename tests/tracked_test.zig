//! Truth and tracked scalar arithmetic, checked as mathematics.
//!
//! Two claims are under test here and they are the ones a tracked value can get
//! wrong without anything looking broken: WHICH VALUES the answer may take, and
//! WHICH BOOLEAN OUTCOMES and HOW CONTINUOUS the expression is.
//!
//! A tracked value carries an enclosure, a `defined` truth and a `continuous`
//! truth. The enclosure is what a caller draws; the other two are what a caller
//! REASONS with, and they are the ones that quietly go wrong. An implementation
//! that clips an off-domain argument and forgets it has clipped; one that
//! multiplies by zero and forgets there was an operand; one that cancels a box
//! against itself; one that reads a `maybe` as a value rather than as an
//! enclosure of outcomes. Every test below is one of those mistakes, pinned at
//! a value a consumer can reach.
//!
//! Three things are deliberately NOT here.
//!
//!  * No width. The enclosure is judged by CONTAINMENT of witnesses that are
//!    exact in binary floating point — the integers, the zeroes, the infinities
//!    — and by UNBOUNDEDNESS where an unbounded answer is the mathematical fact,
//!    as it is at a pole. No test measures how many ULP of widening an answer
//!    carries, because a wider answer is still a correct one. The step functions
//!    are the one family where an endpoint is asserted EXACTLY, and that is not
//!    a width pin: it is the claim that a whole-number image is reported with
//!    whole-number endpoints, which is a statement about the answer rather than
//!    about the format.
//!  * No export names, no declaration counts, no source text. Nothing here reads
//!    what a file declares; every claim is about what a call returns.
//!  * No policy. There is no pixel, viewport or existence classifier here, and
//!    no question about where anything should be drawn. Every assertion below is
//!    a statement about real functions of real arguments, which is the whole of
//!    what this library claims.
//!
//! The witnesses are exact or rigorously bounded, never rounded and hoped for.
//! `19!`, `20!` and `22!` are written as the values their exact binary
//! neighbours hold; Gamma is signed at -5/2 and at -3/2 by the sign of the
//! recurrence; a pole runs to infinity because the function does.

const std = @import("std");
const interval = @import("interval");

const Interval = interval.Interval;
const Rational = interval.Rational;
const Tracked = interval.Tracked;
const Truth = interval.Truth;
const tracked = interval.tracked;
const Cmp = tracked.Cmp;

const inf = std.math.inf(f64);

/// Every state, in the order the tables below read: rows are the left argument,
/// columns the right one.
const states = [_]Truth{ .never, .maybe, .always };

/// The six scalar relations, written out rather than discovered, so that a
/// missing relation fails the test that names it.
const relations = [_]Cmp{ .eq, .ne, .lt, .le, .gt, .ge };

/// The enclosure a tracked value carries, or a failure when it carries none.
///
/// A wholly undefined value has NO interval: there is no number to enclose, and
/// handing back a degenerate one would put a value into the world where the
/// mathematics has none.
fn rangeOf(t: Tracked) !Interval {
    const r = t.range orelse return error.NoRange;
    try std.testing.expect(r.lo <= r.hi);
    return r;
}

/// Whether `outer` allows every outcome `inner` allows: set inclusion on outcome
/// sets, which is the order the three states form. `never` is the smallest,
/// `always` the largest.
fn encloses(outer: Truth, inner: Truth) bool {
    return (!inner.lower() or outer.lower()) and (!inner.upper() or outer.upper());
}

/// A leaf: a box, fully defined and fully continuous, because there is nothing
/// in it that could fail or jump.
fn box(lo: f64, hi: f64) Tracked {
    return Tracked.init(Interval.init(lo, hi));
}

/// One real value, which is the case where the tracker knows most.
fn pt(x: f64) Tracked {
    return Tracked.point(x);
}

/// A value whose metadata is stated outright. The only way to say that a value
/// is discontinuous somewhere, which is what the composition rules below need.
fn meta(lo: f64, hi: f64, defined: Truth, continuous: Truth) Tracked {
    return Tracked.withMetadata(Interval.init(lo, hi), defined, continuous);
}

/// Every state a binary connective answers, against the table this file holds
/// for it. A table is a decision, and it is written down so that changing it
/// reads as a decision somebody made rather than as a mystery failure.
fn checkTable(comptime f: fn (Truth, Truth) Truth, comptime expected: [states.len][states.len]Truth) !void {
    for (states, 0..) |a, i| {
        for (states, 0..) |b, j| {
            try std.testing.expectEqual(expected[i][j], f(a, b));
        }
    }
}

/// The law every binary connective owes, and the one that keeps a connective
/// honest without saying what it computes: the answer for two enclosures must
/// allow every outcome that the tightest and the loosest enclosure inside them
/// could produce between them.
///
/// This is what "an ENCLOSURE of possible outcomes" means, written as a
/// predicate. An implementation that computes the conjunction from the lowers
/// and forgets the uppers fails here. So does one that treats `maybe` as a known
/// value rather than as two possible ones, on the pair of `maybe`s.
fn checkSoundness(comptime f: fn (Truth, Truth) Truth) !void {
    for (states) |a| {
        for (states) |b| {
            const tightest = Truth.fromBounds(a.lower() and b.lower(), a.upper() and b.upper());
            const loosest = Truth.fromBounds(a.lower() or b.lower(), a.upper() or b.upper());
            try std.testing.expect(encloses(f(a, b), tightest.both(loosest)));
        }
    }
}

// ---------------------------------------------------------------- the states

test "Truth: the three states are the three possible outcome bounds" {
    // A state is a pair of bounds on the answer to "can this be true": the
    // strongest outcome it still allows and the weakest one. Two outcomes and
    // two ordered bounds give three states, not four, because the bounds cannot
    // cross.
    try std.testing.expectEqual(Truth.never, Truth.fromBounds(false, false));
    try std.testing.expectEqual(Truth.maybe, Truth.fromBounds(false, true));
    try std.testing.expectEqual(Truth.always, Truth.fromBounds(true, true));

    try std.testing.expect(!Truth.never.lower());
    try std.testing.expect(!Truth.never.upper());
    try std.testing.expect(!Truth.maybe.lower());
    try std.testing.expect(Truth.maybe.upper());
    try std.testing.expect(Truth.always.lower());
    try std.testing.expect(Truth.always.upper());

    // Every state reads back as itself, which is what makes the pair the whole of
    // the value rather than a summary of something larger.
    for (states) |t| {
        try std.testing.expectEqual(t, Truth.fromBounds(t.lower(), t.upper()));
    }
}

test "Truth: negation swaps the two bounds and leaves the middle alone" {
    try std.testing.expectEqual(Truth.always, Truth.never.negate());
    try std.testing.expectEqual(Truth.maybe, Truth.maybe.negate());
    try std.testing.expectEqual(Truth.never, Truth.always.negate());
    for (states) |t| {
        try std.testing.expectEqual(t, t.negate().negate());
    }
}

test "Truth: both intersects the outcome sets" {
    try checkTable(Truth.both, .{
        .{ .never, .never, .never },
        .{ .never, .maybe, .maybe },
        .{ .never, .maybe, .always },
    });
    try checkSoundness(Truth.both);
}

test "Truth: either resolves to one outcome rather than unioning both" {
    // `either` is a disjunction: it sees the outcome each argument allows and
    // settles on one. It is therefore NOT the union of outcome sets — `join`
    // below is, and the test there pins the difference on the same pair of
    // arguments, where `either` answers `always` and `join` answers `maybe`.
    //
    // The cells pinned here are the ones where a disjunction, a conjunction and
    // a union all agree, so they do not depend on which of those `either` turns
    // out to be. The cell where a disjunction and a union part company — a
    // `maybe` against an `always` — is left to the law below, which holds under
    // either reading.
    try std.testing.expectEqual(Truth.never, Truth.never.either(Truth.never));
    try std.testing.expectEqual(Truth.always, Truth.always.either(Truth.always));
    // Two enclosures that each allow both outcomes still allow both between
    // them, whatever the disjunction is called.
    try std.testing.expectEqual(Truth.maybe, Truth.maybe.either(Truth.maybe));
    try checkSoundness(Truth.either);
}

test "Truth: implies is the material implication over the outcome sets" {
    // Rows are the antecedent. A false antecedent makes the implication true,
    // which is why the first row is all `always`.
    try checkTable(Truth.implies, .{
        .{ .always, .always, .always },
        .{ .maybe, .maybe, .always },
        .{ .never, .maybe, .always },
    });
    try checkSoundness(Truth.implies);
}

test "Truth: equivalence of two enclosures does not claim they are mixed" {
    // Two `maybe`s may be the same value, so their equivalence may hold; they
    // may also be different, so it may fail. Both outcomes are possible and the
    // answer is `maybe`. Neither extreme is available here: `always` on that
    // pair would claim the two are KNOWN to be equal, and `never` would claim
    // they are known to be different. Both are assertions `maybe` must not make,
    // because `maybe` says the outcome is not known rather than that it is
    // mixed.
    try checkTable(Truth.equivalent, .{
        .{ .always, .maybe, .never },
        .{ .maybe, .maybe, .maybe },
        .{ .never, .maybe, .always },
    });
    for (states) |a| {
        for (states) |b| {
            try std.testing.expectEqual(a.equivalent(b), b.equivalent(a));
        }
    }
    try checkSoundness(Truth.equivalent);
}

test "Truth: join unions the outcome sets rather than resolving to one of them" {
    // A state is the SET of outcomes it allows: `never` allows {false}, `maybe`
    // allows {false, true}, `always` allows {true}. Joining two states unions
    // those sets, so joining two states that each allow one outcome gives an
    // answer allowing BOTH — which is `maybe`, not `always`.
    //
    // The row that pins the mistake. `always` and `never` together allow
    // {true} and {false}, so their union allows both and the join is `maybe`.
    // Reading the join as a Boolean `or` over a rank order would answer
    // `always`, which asserts that only the true outcome is possible — a claim
    // that one of the two arguments rules out.
    try checkTable(Truth.join, .{
        .{ .never, .maybe, .maybe },
        .{ .maybe, .maybe, .maybe },
        .{ .maybe, .maybe, .always },
    });
    try std.testing.expectEqual(Truth.maybe, Truth.always.join(Truth.never));
    // And the two operations that are NOT unions, on the same pair. The
    // conjunction of an always with a never is certainly false, and the
    // disjunction is certainly true: each of those sees only the outcome ITSELF
    // allows, where the join sees both.
    try std.testing.expectEqual(Truth.never, Truth.always.both(Truth.never));
    try std.testing.expectEqual(Truth.always, Truth.always.either(Truth.never));
    try checkSoundness(Truth.join);
}

test "Truth: join is idempotent and commutative" {
    for (states) |a| {
        for (states) |b| {
            try std.testing.expectEqual(a, a.join(a));
            try std.testing.expectEqual(a.join(b), b.join(a));
        }
    }
}

// -------------------------------------------------------------- construction

test "Tracked: a leaf is defined and continuous over its whole range" {
    const x = box(1.0, 2.0);
    try std.testing.expectEqual(Truth.always, x.defined);
    try std.testing.expectEqual(Truth.always, x.continuous);
    try std.testing.expect((try rangeOf(x)).eql(Interval.init(1.0, 2.0)));

    const q = pt(0.5);
    try std.testing.expectEqual(Truth.always, q.defined);
    try std.testing.expectEqual(Truth.always, q.continuous);
    try std.testing.expect((try rangeOf(q)).eql(Interval.init(0.5, 0.5)));
}

test "Tracked: an undefined value carries no numeric range at all" {
    const u = Tracked.undefined();
    try std.testing.expect(u.range == null);
    try std.testing.expectEqual(Truth.never, u.defined);
    // There is nothing to half-hold here: a value that does not exist has no
    // interval, and the interval it would have had is the one thing that must
    // not be invented.
    try std.testing.expect(!u.defined.lower());
    try std.testing.expect(!u.defined.upper());
}

// -------------------------------------------------------- the scalar relations

test "compare: a scalar relation is not the equality of two interval sets" {
    const a = box(0.0, 1.0);
    const b = box(0.0, 1.0);
    // As SETS of values the two boxes are the same box, which is what
    // `Interval.eql` answers and what a caller comparing two enclosures wants.
    try std.testing.expect(a.range.?.eql(b.range.?));
    // As SCALARS they are not the same: nothing says the value sampled from a
    // is the value sampled from b, so equality is possible and not necessary.
    // `always` here is the interval-set answer leaking into a scalar question.
    try std.testing.expectEqual(Truth.maybe, a.eq(b));
    try std.testing.expectEqual(Truth.maybe, a.ne(b));
}

test "compare: nothing at all is certain between two equal broad boxes" {
    const a = box(1.0, 2.0);
    // Every one of the six relations has both outcomes available between two
    // independent samples of the same box: 1 against 1 settles some of them and
    // 1 against 2 settles the rest, in both directions.
    inline for (relations) |c| {
        try std.testing.expectEqual(Truth.maybe, a.compare(a, c));
    }
}

test "compare: independent equal boxes do not cancel" {
    const a = box(1.0, 2.0);
    // The same box against itself. Every value in [1,2] can be subtracted from
    // every other value in [1,2], so the difference spans [-1,1] and the
    // quotient spans [1/2, 2]. An implementation that recognised the two
    // operands as one expression would answer [0,0] and [1,1], and both of those
    // are wrong: two boxes are not a promise that they came from one value.
    const d = try rangeOf(a.sub(a));
    try std.testing.expect(d.contains(-1.0));
    try std.testing.expect(d.contains(1.0));
    try std.testing.expect(!d.eql(Interval.init(0.0, 0.0)));

    const q = try rangeOf(a.div(a));
    try std.testing.expect(q.contains(0.5));
    try std.testing.expect(q.contains(2.0));
    try std.testing.expect(!q.eql(Interval.init(1.0, 1.0)));

    // And the value that does cancel, really does: two points of the same value
    // are one value, and the tracker is allowed to say so.
    const one = try rangeOf(pt(1.0).sub(pt(1.0)));
    try std.testing.expect(one.eql(Interval.init(0.0, 0.0)));
    try std.testing.expectEqual(Truth.always, pt(1.0).sub(pt(1.0)).eq(pt(0.0)));
}

test "compare: disjoint boxes settle all six relations" {
    const a = box(0.0, 1.0);
    const b = box(2.0, 3.0);
    try std.testing.expectEqual(Truth.always, a.compare(b, .lt));
    try std.testing.expectEqual(Truth.always, a.compare(b, .le));
    try std.testing.expectEqual(Truth.never, a.compare(b, .eq));
    try std.testing.expectEqual(Truth.always, a.compare(b, .ne));
    try std.testing.expectEqual(Truth.never, a.compare(b, .gt));
    try std.testing.expectEqual(Truth.never, a.compare(b, .ge));

    try std.testing.expectEqual(Truth.never, b.compare(a, .lt));
    try std.testing.expectEqual(Truth.never, b.compare(a, .le));
    try std.testing.expectEqual(Truth.never, b.compare(a, .eq));
    try std.testing.expectEqual(Truth.always, b.compare(a, .ne));
    try std.testing.expectEqual(Truth.always, b.compare(a, .gt));
    try std.testing.expectEqual(Truth.always, b.compare(a, .ge));
}

test "compare: two points settle every relation with no uncertainty left" {
    try std.testing.expectEqual(Truth.always, pt(1.0).eq(pt(1.0)));
    try std.testing.expectEqual(Truth.never, pt(1.0).ne(pt(1.0)));
    try std.testing.expectEqual(Truth.never, pt(1.0).lt(pt(1.0)));
    try std.testing.expectEqual(Truth.always, pt(1.0).le(pt(1.0)));
    try std.testing.expectEqual(Truth.never, pt(1.0).gt(pt(1.0)));
    try std.testing.expectEqual(Truth.always, pt(1.0).ge(pt(1.0)));

    try std.testing.expectEqual(Truth.always, pt(1.0).lt(pt(2.0)));
    try std.testing.expectEqual(Truth.always, pt(1.0).le(pt(2.0)));
    try std.testing.expectEqual(Truth.never, pt(1.0).eq(pt(2.0)));
    try std.testing.expectEqual(Truth.never, pt(2.0).lt(pt(1.0)));
    try std.testing.expectEqual(Truth.never, pt(2.0).gt(pt(1.0)));
}

test "compare: every relation is false when an operand has no value" {
    const u = Tracked.undefined();
    const x = pt(1.0);
    // All six, on the left, on the right, and hole against hole. `ne` is in the
    // list and is the one that is tempting to special-case: there is no value,
    // so the two values are certainly not different either. `always` there is
    // the same error as `always` for `eq`, and it is the one that makes a hole
    // look like a difference.
    inline for (relations) |c| {
        try std.testing.expectEqual(Truth.never, u.compare(x, c));
        try std.testing.expectEqual(Truth.never, x.compare(u, c));
        try std.testing.expectEqual(Truth.never, u.compare(u, c));
    }
    try std.testing.expectEqual(Truth.never, u.ne(x));
    try std.testing.expectEqual(Truth.never, x.ne(u));
}

test "compare: the negation of a false relation is true" {
    const u = Tracked.undefined();
    const x = pt(1.0);
    // Negating a relation that is certainly false gives one that is certainly
    // true. This is the one place an undefined operand produces `always`, and it
    // is the price of `ne` being false: the two statements together are what a
    // consumer needs, since "not equal" as a NEGATION is a different question
    // from "not equal" as a relation.
    inline for (relations) |c| {
        try std.testing.expectEqual(Truth.always, x.compareNegated(u, c));
        try std.testing.expectEqual(x.compare(u, c).negate(), x.compareNegated(u, c));
    }
    try std.testing.expectEqual(Truth.always, u.compareNegated(x, .ne));
}

test "compare: a negated relation is not the inverse order relation" {
    // [0,1] against [1,2]. The two boxes touch, so `lt` is possible (0 < 1) and
    // `gt` is impossible: nothing in the first box is above anything in the
    // second. The negation of `lt` is `maybe` and `gt` is `never`, so the two
    // differ on the same pair of arguments. Swapping one for the other answers a
    // different question, and against a hole the difference is the whole answer:
    // the negation of a false `ge` is `always`, while no order relation against a
    // hole is anything but `never`.
    const a = box(0.0, 1.0);
    const b = box(1.0, 2.0);
    try std.testing.expectEqual(Truth.maybe, a.compare(b, .lt));
    try std.testing.expectEqual(Truth.never, a.compare(b, .gt));
    try std.testing.expectEqual(Truth.maybe, a.compareNegated(b, .lt));
    try std.testing.expect(a.compareNegated(b, .lt) != a.compare(b, .gt));

    const u = Tracked.undefined();
    try std.testing.expectEqual(Truth.always, u.compareNegated(pt(1.0), .ge));
    try std.testing.expectEqual(Truth.never, u.compare(pt(1.0), .lt));

    // Over the whole surface, the negated relation is the negation and nothing
    // else: no inverse order relation, no complement of the enclosure.
    const pairs = [_][2]Tracked{
        .{ box(0.0, 1.0), box(1.0, 2.0) },
        .{ box(-3.0, -2.0), pt(0.5) },
        .{ u, pt(1.0) },
        .{ pt(1.0), u },
    };
    for (pairs) |pair| {
        inline for (relations) |c| {
            try std.testing.expectEqual(pair[0].compare(pair[1], c).negate(), pair[0].compareNegated(pair[1], c));
        }
    }
}

// ------------------------------------------------------------------ the domains

test "sqrt: an argument crossing the axis is only partly in the domain" {
    // The negative half of this box has no square root and the positive half
    // does, so the value is partly defined. The enclosure is the image of the
    // part that exists, and it starts at zero however far the box reaches under
    // the axis.
    const s = box(-1.0, 1.0).sqrt();
    try std.testing.expectEqual(Truth.maybe, s.defined);
    const r = try rangeOf(s);
    try std.testing.expect(r.lo >= 0.0);
    try std.testing.expect(r.contains(0.0));
    try std.testing.expect(r.contains(1.0));
    // Partly defined is not continuous: over a box reaching under the axis the
    // square root has an end to it, and `continuous = always` here is a claim
    // the clipping cannot support.
    try std.testing.expect(s.continuous != Truth.always);
}

test "sqrt: a wholly negative argument has no value and no range" {
    const s = box(-4.0, -1.0).sqrt();
    try std.testing.expectEqual(Truth.never, s.defined);
    try std.testing.expect(s.range == null);
    // The same question asked through the module function, which is the same
    // call.
    try std.testing.expectEqual(Truth.never, tracked.sqrt(box(-4.0, -1.0)).defined);
}

test "sqrt: a partly defined value is not certainly equal to a negative one" {
    // The trap this pins: an argument only half in the domain produces a value
    // only half defined, and a tracker that treats uncertainty about DEFINITION
    // as uncertainty about VALUE answers `always` for a comparison it has never
    // made. The square root of anything that exists is at least zero, so
    // equality with a negative value is not merely unproved.
    const s = box(-1.0, 1.0).sqrt();
    try std.testing.expect(s.eq(pt(-0.5)) != Truth.always);
    try std.testing.expect(s.eq(box(-1.0, -0.5)) != Truth.always);

    // On a wholly valid argument the same comparison is certainly FALSE, and it
    // has to stay that way: a tracker answering `maybe` for every disjoint pair
    // would be right about this one by accident and about nothing else ever.
    const whole = box(0.0, 1.0).sqrt();
    try std.testing.expectEqual(Truth.always, whole.defined);
    try std.testing.expectEqual(Truth.never, whole.eq(pt(-0.5)));
    try std.testing.expectEqual(Truth.always, whole.gt(pt(-0.5)));
}

test "sqrt: a domain survives being composed with another function" {
    // The clipping happens once, at the square root, and the logarithm of that
    // answer has a pole at zero because the square root produced one. Chaining
    // must not tidy it away.
    const partial = box(-4.0, 4.0).sqrt().log();
    try std.testing.expectEqual(Truth.maybe, partial.defined);
    try std.testing.expectEqual(-inf, (try rangeOf(partial)).lo);

    // The same chain with nothing to clip: the root of [1/4,4] lies in [1/2,2]
    // and every value of that is a legal logarithm argument.
    const whole = box(0.25, 4.0).sqrt().log();
    try std.testing.expectEqual(Truth.always, whole.defined);
    const r = try rangeOf(whole);
    try std.testing.expect(r.contains(0.0));
    try std.testing.expect(r.contains(0.6931471805599453));
}

test "arithmetic: an undefined operand stays undefined through every operation" {
    const u = Tracked.undefined();
    const x = box(-2.0, 3.0);
    // Every algebraic operation, with the hole on the left and on the right. An
    // implementation that computes the range first and the definedness second has
    // already lost the hole by the time it gets there.
    const results = [_]Tracked{
        u.add(x),
        x.add(u),
        u.sub(x),
        x.sub(u),
        u.mul(x),
        x.mul(u),
        u.div(x),
        x.div(u),
        u.recip(),
        u.neg(),
        u.abs(),
        u.sqr(),
    };
    for (results) |r| {
        try std.testing.expectEqual(Truth.never, r.defined);
        try std.testing.expect(r.range == null);
    }
}

test "arithmetic: a zero factor does not rescue an undefined operand" {
    // Zero times a value that does not exist is still no value. Multiplying the
    // enclosures first would hand back [0,0], which is a real answer to a
    // different question, and the caller could not tell the two apart.
    const u = Tracked.undefined();
    const zero = pt(0.0);
    try std.testing.expectEqual(Truth.never, zero.mul(u).defined);
    try std.testing.expect(zero.mul(u).range == null);
    try std.testing.expectEqual(Truth.never, u.mul(zero).defined);

    // With a real operand the same multiplication is exact, and this contrast is
    // what makes the row above a test rather than a coincidence.
    const z = zero.mul(box(-2.0, 3.0));
    try std.testing.expectEqual(Truth.always, z.defined);
    try std.testing.expect((try rangeOf(z)).eql(Interval.init(0.0, 0.0)));
    try std.testing.expectEqual(Truth.always, z.continuous);
}

test "div: a divisor without a value in it is a domain, not a wide number" {
    // The bare interval division answers a hull here, and that answer is not a
    // claim that a value exists. The tracked division has to say the value does
    // not.
    const zero = pt(1.0).div(pt(0.0));
    try std.testing.expectEqual(Truth.never, zero.defined);
    try std.testing.expect(zero.range == null);
    try std.testing.expectEqual(Truth.never, pt(0.0).recip().defined);

    // A divisor that CONTAINS zero is only partly a divisor, and the pole at zero
    // is what makes the answer unbounded.
    const partial = pt(1.0).div(box(0.0, 1.0));
    try std.testing.expectEqual(Truth.maybe, partial.defined);
    const r = try rangeOf(partial);
    try std.testing.expect(r.contains(1.0));
    try std.testing.expectEqual(inf, r.hi);

    const recip = box(0.0, 1.0).recip();
    try std.testing.expectEqual(Truth.maybe, recip.defined);
    const rr = try rangeOf(recip);
    try std.testing.expect(rr.contains(1.0));
    try std.testing.expectEqual(inf, rr.hi);
}

test "pow: an exponent of zero does not rescue an undefined base" {
    // x^0 is 1 at every real x, zero included, so over a real base the answer is
    // a constant and the family is defined and continuous there.
    const one = tracked.pow(box(-3.0, 4.0), 0);
    try std.testing.expectEqual(Truth.always, one.defined);
    try std.testing.expectEqual(Truth.always, one.continuous);
    try std.testing.expect((try rangeOf(one)).contains(1.0));

    // The base still has to be there. 0^0 = 1 says what the answer is WHERE AN
    // ANSWER EXISTS; it is not a rule that manufactures an argument.
    const hollow = tracked.pow(Tracked.undefined(), 0);
    try std.testing.expectEqual(Truth.never, hollow.defined);
    try std.testing.expect(hollow.range == null);

    // A negative exponent needs a base that is not zero, which puts a box
    // touching zero partly out of the domain.
    try std.testing.expectEqual(Truth.maybe, tracked.pow(box(0.0, 2.0), -1).defined);
    try std.testing.expectEqual(Truth.never, tracked.pow(box(0.0, 0.0), -1).defined);
    try std.testing.expectEqual(Truth.always, tracked.pow(box(1.0, 2.0), -1).defined);

    // A definite integer image, against which the three rows above are read.
    try std.testing.expect((try rangeOf(tracked.pow(pt(2.0), 10))).contains(1024.0));
    try std.testing.expectEqual(Truth.always, tracked.pow(pt(2.0), 10).defined);
}

test "powf: a negative base over a whole exponent range keeps both signs" {
    // -1 to the rationals in [1,2] is +1 for the odd numerators and -1 for the
    // even ones, so an enclosure reporting one sign has dropped half the answer.
    // This row separates a symmetric enclosure from a clipped one.
    const p = tracked.powf(pt(-1.0), box(1.0, 2.0));
    try std.testing.expect(p.defined != Truth.never);
    const r = try rangeOf(p);
    try std.testing.expect(r.contains(1.0));
    try std.testing.expect(r.contains(-1.0));
}

test "powf: the parity of the exponent decides whether a negative base has a value" {
    // An exponent of half a turn is a square root and has no real answer for a
    // negative base. So has one third of a turn AS A FLOAT, and this is the row
    // that says why: the nearest binary64 to one third is not the rational one
    // third, it is a dyadic rational with an even reduced denominator, and a
    // negative base raised to one of those has no real value at all.
    //
    // The error this pins is reading a float exponent as the exact rational a
    // caller meant. The tagged `Rational` below is how the exact cube root is
    // actually asked for.
    try std.testing.expectEqual(Truth.never, tracked.powf(pt(-1.0), pt(0.5)).defined);
    try std.testing.expectEqual(Truth.never, tracked.powf(pt(-1.0), pt(1.0 / 3.0)).defined);

    // An exact integer exponent is not the problem, negative included: (-1)^-2 is
    // 1 and has to be answered.
    const integral = tracked.powf(pt(-1.0), pt(-2.0));
    try std.testing.expectEqual(Truth.always, integral.defined);
    try std.testing.expect((try rangeOf(integral)).contains(1.0));
    const odd = tracked.powf(pt(-1.0), pt(3.0));
    try std.testing.expectEqual(Truth.always, odd.defined);
    try std.testing.expect((try rangeOf(odd)).contains(-1.0));

    // Zero to zero is one, by the convention the family is built on.
    const zero_zero = tracked.powf(pt(0.0), pt(0.0));
    try std.testing.expectEqual(Truth.always, zero_zero.defined);
    try std.testing.expect((try rangeOf(zero_zero)).contains(1.0));
}

test "roots: the degree decides the sign and a degree of zero decides nothing" {
    // An odd root takes the negative half whole.
    const cube = tracked.nthRoot(3, box(-8.0, -1.0));
    try std.testing.expectEqual(Truth.always, cube.defined);
    try std.testing.expect((try rangeOf(cube)).contains(-2.0));

    // An even root clips it, so a box crossing zero is only partly in the domain
    // and a box wholly below it is out of it entirely.
    try std.testing.expectEqual(Truth.maybe, tracked.nthRoot(2, box(-1.0, 1.0)).defined);
    try std.testing.expectEqual(Truth.never, tracked.nthRoot(2, box(-4.0, -1.0)).defined);
    try std.testing.expectEqual(Truth.always, tracked.nthRoot(2, box(1.0, 4.0)).defined);

    // A degree of zero is not a root of anything.
    try std.testing.expectEqual(Truth.never, tracked.nthRoot(0, box(1.0, 2.0)).defined);

    // A tagged rational carries its own denominator, so a third is not read as
    // half and half is not read as a third.
    const third = try Rational.init(1, 3);
    const half = try Rational.init(1, 2);
    const c = tracked.powRational(box(-8.0, -1.0), third);
    try std.testing.expectEqual(Truth.always, c.defined);
    try std.testing.expect((try rangeOf(c)).contains(-2.0));
    try std.testing.expectEqual(Truth.never, tracked.powRational(box(-8.0, -1.0), half).defined);
    try std.testing.expectEqual(Truth.never, tracked.powRational(Tracked.undefined(), third).defined);
}

test "log: a box reaching zero is partly out of the domain, and the pole is a bound" {
    try std.testing.expectEqual(Truth.maybe, box(-1.0, 1.0).log().defined);
    try std.testing.expectEqual(Truth.never, box(-1.0, 0.0).log().defined);
    try std.testing.expectEqual(Truth.always, box(0.5, 1.0).log().defined);
    try std.testing.expectEqual(Truth.never, Tracked.undefined().log().defined);

    // The argument comes arbitrarily close to zero and the logarithm of that is
    // arbitrarily far down, so the near end is minus infinity while the value at
    // one is exactly zero and stays in the answer.
    const r = try rangeOf(box(0.0, 1.0).log());
    try std.testing.expectEqual(-inf, r.lo);
    try std.testing.expect(r.contains(0.0));

    // The other two bases share the domain. A family that forgets one of them is
    // a hole in the surface.
    try std.testing.expectEqual(Truth.maybe, box(-1.0, 1.0).log2().defined);
    try std.testing.expectEqual(Truth.never, box(-1.0, 0.0).log2().defined);
    try std.testing.expectEqual(Truth.maybe, box(-1.0, 1.0).log10().defined);
    try std.testing.expectEqual(Truth.never, box(-1.0, 0.0).log10().defined);

    // log1p has its pole one unit to the left rather than at zero.
    try std.testing.expectEqual(Truth.maybe, box(-2.0, 1.0).log1p().defined);
    try std.testing.expectEqual(Truth.never, box(-2.0, -1.5).log1p().defined);
    try std.testing.expectEqual(Truth.always, box(-0.5, 0.5).log1p().defined);
}

test "logBase: the base comes first, and base one is not a logarithm" {
    // log base 2 of 8 is 3, which is exact and worth pinning as a value.
    const l = tracked.logBase(pt(2.0), pt(8.0));
    try std.testing.expectEqual(Truth.always, l.defined);
    try std.testing.expect((try rangeOf(l)).contains(3.0));
    try std.testing.expectEqual(Truth.always, tracked.logBase(pt(2.0), pt(1.0)).defined);

    // A base must be positive and must not be one. Both are holes, and the second
    // is the one an implementation checks last.
    try std.testing.expectEqual(Truth.never, tracked.logBase(pt(1.0), pt(8.0)).defined);
    try std.testing.expectEqual(Truth.never, tracked.logBase(pt(-2.0), pt(8.0)).defined);
    try std.testing.expectEqual(Truth.never, tracked.logBase(pt(0.0), pt(8.0)).defined);

    // The argument has the same domain as an ordinary logarithm.
    try std.testing.expectEqual(Truth.never, tracked.logBase(pt(2.0), pt(0.0)).defined);
    try std.testing.expectEqual(Truth.never, tracked.logBase(pt(2.0), pt(-4.0)).defined);

    // A base that varies over a valid range keeps every branch of the answer, and
    // a range that REACHES one of the excluded bases is partly out of the domain
    // however good the argument is.
    try std.testing.expectEqual(Truth.maybe, tracked.logBase(box(1.0, 2.0), pt(8.0)).defined);
    try std.testing.expectEqual(Truth.maybe, tracked.logBase(box(0.5, 2.0), pt(8.0)).defined);
    try std.testing.expectEqual(Truth.always, tracked.logBase(box(2.0, 3.0), pt(8.0)).defined);

    // Both ends out at once: the argument reaching zero runs the answer to minus
    // infinity, and the exact values at base two are still in it.
    const both = tracked.logBase(box(2.0, 3.0), box(0.0, 8.0));
    try std.testing.expectEqual(Truth.maybe, both.defined);
    const r = try rangeOf(both);
    try std.testing.expectEqual(-inf, r.lo);
    try std.testing.expect(r.contains(0.0));
    try std.testing.expect(r.contains(3.0));
}

test "inverse circle functions: the ends of the domain are the whole story" {
    try std.testing.expectEqual(Truth.always, box(-1.0, 1.0).asin().defined);
    try std.testing.expectEqual(Truth.maybe, box(-4.0, 1.0).asin().defined);
    try std.testing.expectEqual(Truth.never, box(2.0, 4.0).asin().defined);

    try std.testing.expectEqual(Truth.always, box(-1.0, 1.0).acos().defined);
    try std.testing.expectEqual(Truth.maybe, box(-4.0, 1.0).acos().defined);
    try std.testing.expectEqual(Truth.never, box(2.0, 4.0).acos().defined);

    // The arc tangent is real everywhere, so nothing about its argument can open
    // a hole in it.
    try std.testing.expectEqual(Truth.always, box(-4.0, 4.0).atan().defined);
    try std.testing.expectEqual(Truth.never, Tracked.undefined().atan().defined);

    // The arcsine rises and the arc cosine mirrors it, so the two enclosures
    // contain the same two endpoints of the range.
    const a = try rangeOf(box(-1.0, 1.0).asin());
    try std.testing.expect(a.contains(0.0));
    try std.testing.expect(a.contains(1.5707963267948966));
    const c = try rangeOf(box(-1.0, 1.0).acos());
    try std.testing.expect(c.contains(0.0));
    try std.testing.expect(c.contains(1.5707963267948966));
}

test "inverse hyperbolic functions: the ends are open and acosh is closed" {
    // acosh is real on [1, infinity), a closed half-line, so a box sitting on the
    // one is wholly in the domain.
    try std.testing.expectEqual(Truth.always, box(1.0, 2.0).acosh().defined);
    try std.testing.expectEqual(Truth.maybe, box(0.5, 2.0).acosh().defined);
    try std.testing.expectEqual(Truth.never, box(-1.0, 0.0).acosh().defined);

    // atanh is real on the OPEN interval (-1, 1), so a box whose endpoints ARE
    // the poles contains two points with no value. Clipping them away and then
    // reporting the box as continuous is the error this pins.
    try std.testing.expectEqual(Truth.maybe, box(-1.0, 1.0).atanh().defined);
    try std.testing.expectEqual(Truth.maybe, box(-2.0, 1.0).atanh().defined);
    try std.testing.expectEqual(Truth.never, box(1.0, 2.0).atanh().defined);
    try std.testing.expectEqual(Truth.always, box(0.0, 0.5).atanh().defined);

    // The poles are at the ends of the interval, so the answer runs to infinity
    // in both directions there.
    const r = try rangeOf(box(-1.0, 1.0).atanh());
    try std.testing.expectEqual(-inf, r.lo);
    try std.testing.expectEqual(inf, r.hi);
    try std.testing.expect(r.contains(0.0));

    // asinh is real everywhere and stays finite.
    try std.testing.expectEqual(Truth.always, box(-4.0, 4.0).asinh().defined);
}

test "the reciprocal circle functions have poles of their own" {
    // sec and csc are undefined where cos and sin are, so the family wrapper has
    // to see that rather than hand back a hull: the hull of a function with a
    // hole in it is not the image of the function.
    //
    // The reciprocal domain is read off the ZEROES of the image just computed,
    // which is sound in both directions — a box whose cosine image stays away
    // from zero is wholly in the domain of the secant, and one whose image
    // reaches zero is not.
    //
    // csc over [0,1]: sin vanishes at the box's own endpoint, so the box is half
    // in the domain and half out of it.
    try std.testing.expectEqual(Truth.maybe, tracked.forward(.circle, .csc, box(0.0, 1.0)).defined);

    // sec over [-1,1] is the row this test used to get wrong, by reading the
    // family as "reciprocals have holes somewhere nearby". They do not: the hole
    // of the secant is at +/- pi/2 = +/-1.5708, which is OUTSIDE [-1,1], and
    // cos over [-1,1] is [0.5403, 1] because the cosine is even and falling on
    // [0,1]. That image never reaches zero, so the secant is defined at EVERY
    // point of this box and the answer is `always`.
    try std.testing.expectEqual(Truth.always, tracked.forward(.circle, .sec, box(-1.0, 1.0)).defined);

    // Widening the box to reach the pole is what makes the secant partly defined.
    // [-2,2] contains +/-pi/2, so the image of the cosine runs through zero and
    // the answer runs out on both sides of it.
    try std.testing.expectEqual(Truth.maybe, tracked.forward(.circle, .sec, box(-2.0, 2.0)).defined);

    // Away from the poles they are ordinary total functions, and sec(0) is 1.
    const sec0 = tracked.forward(.circle, .sec, pt(0.0));
    try std.testing.expectEqual(Truth.always, sec0.defined);
    try std.testing.expect((try rangeOf(sec0)).contains(1.0));

    // cot is cos over sin, so it is undefined at the zeroes of sin, while the
    // sine itself is undefined nowhere.
    try std.testing.expectEqual(Truth.never, tracked.forward(.circle, .cot, pt(0.0)).defined);
    const sin0 = tracked.forward(.circle, .sin, pt(0.0));
    try std.testing.expectEqual(Truth.always, sin0.defined);
    try std.testing.expect((try rangeOf(sin0)).contains(0.0));
}

test "principalInverse through the family wrapper carries the same domain" {
    // The wrapper takes a geometry and a function, so the domain travels with the
    // function rather than with the wrapper.
    try std.testing.expectEqual(Truth.always, tracked.principalInverse(.circle, .asin, box(-1.0, 1.0)).defined);
    try std.testing.expectEqual(Truth.maybe, tracked.principalInverse(.circle, .asin, box(-4.0, 1.0)).defined);
    try std.testing.expectEqual(Truth.never, tracked.principalInverse(.circle, .asin, box(2.0, 4.0)).defined);
    try std.testing.expectEqual(Truth.never, tracked.principalInverse(.circle, .acos, box(2.0, 4.0)).defined);

    // The principal arc cosine runs from pi down to zero, so the end it is
    // certain about is the other one from the arcsine's.
    const c = try rangeOf(tracked.principalInverse(.circle, .acos, pt(1.0)));
    try std.testing.expect(c.contains(0.0));
    const s = try rangeOf(tracked.principalInverse(.circle, .asin, pt(1.0)));
    try std.testing.expect(s.contains(1.5707963267948966));
}

test "gamma: the poles are at the non-positive integers and they are real holes" {
    try std.testing.expectEqual(Truth.never, pt(0.0).gamma().defined);
    try std.testing.expectEqual(Truth.never, pt(-1.0).gamma().defined);
    try std.testing.expectEqual(Truth.never, pt(-2.0).gamma().defined);
    try std.testing.expectEqual(Truth.never, Tracked.undefined().gamma().defined);

    // A box across a pole is partly in the domain, and one across two poles is no
    // more defined than one across a single pole.
    try std.testing.expectEqual(Truth.maybe, box(-0.5, 0.5).gamma().defined);
    try std.testing.expectEqual(Truth.maybe, box(-1.0, 1.0).gamma().defined);

    // Between -3 and 0 the only poles are the integers, so a box sitting strictly
    // inside one of those gaps is wholly in the domain. Gamma(-2.9) and
    // Gamma(-2.1) are both large and negative, which is the sign the recurrence
    // gives for three negative factors over a positive numerator.
    const gap = box(-2.9, -2.1).gamma();
    try std.testing.expectEqual(Truth.always, gap.defined);
    const g = try rangeOf(gap);
    try std.testing.expect(g.contains(-1.9184));
    try std.testing.expect(g.contains(-4.6260));

    // A box across the pole at zero runs to infinity on BOTH sides of it: the
    // function is unbounded above as the argument rises to the pole and unbounded
    // below as it leaves the other side.
    const pole = try rangeOf(box(-0.5, 0.5).gamma());
    try std.testing.expectEqual(inf, pole.hi);
    try std.testing.expectEqual(-inf, pole.lo);
    try std.testing.expect(pole.contains(0.0));
}

test "gamma: a pole-free gap is wholly in the domain and its image is bounded" {
    // The positive reals carry no pole at all, and Gamma is rising there, so the
    // image of [3,4] holds the two exact endpoint values Gamma(3) = 2 and
    // Gamma(4) = 6.
    const pos = box(3.0, 4.0).gamma();
    try std.testing.expectEqual(Truth.always, pos.defined);
    const r = try rangeOf(pos);
    try std.testing.expect(r.lo <= 2.0);
    try std.testing.expect(r.hi >= 6.0);

    // [1/2, 3/2] contains no pole either, and it is the interesting box because
    // the function DIPS across the middle of it: Gamma(1/2) is the square root
    // of pi, it falls to a minimum near 0.8856 before x = 3/2, and Gamma(1) = 1
    // sits between them. An implementation that assumed monotonicity and took
    // only the endpoints would answer [0.8862, 1.7725] and drop the whole dip.
    // The three witnesses below are all attained, so all three must be inside.
    const dip = box(0.5, 1.5).gamma();
    try std.testing.expectEqual(Truth.always, dip.defined);
    const d = try rangeOf(dip);
    try std.testing.expect(d.contains(1.0));
    try std.testing.expect(d.contains(1.7724538509055159));
    try std.testing.expect(d.contains(0.8862269254527580));
}

test "gamma: a singleton argument is answered, not replaced by a global bound" {
    // A coarse lower bound for the positive reals is available to a solver that
    // has to cross an unresolved minimum, and spending it on a single argument
    // would turn a number into a ray. Gamma(4) is 6 exactly.
    const four = pt(4.0).gamma();
    try std.testing.expectEqual(Truth.always, four.defined);
    try std.testing.expect((try rangeOf(four)).contains(6.0));

    // Gamma(1/2) is the square root of pi, which lies strictly between 1 and 2
    // and is a single finite number.
    const half = pt(0.5).gamma();
    const r = try rangeOf(half);
    try std.testing.expect(r.contains(1.5));
    try std.testing.expect(r.lo > 0.0);
    try std.testing.expect(r.hi < inf);
}

test "factorial: the domain is the non-negative integers, which is not an interval" {
    // [3,4] holds two arguments of this function and is still only partly in the
    // domain, because the function is not defined between them. The fractional
    // points in between are not arguments at all.
    const f = box(3.0, 4.0).factorial();
    try std.testing.expectEqual(Truth.maybe, f.defined);
    const r = try rangeOf(f);
    try std.testing.expect(r.contains(6.0));
    try std.testing.expect(r.contains(24.0));

    // A box with no non-negative integer in it has no value.
    try std.testing.expectEqual(Truth.never, box(-1.5, -1.0).factorial().defined);
    try std.testing.expectEqual(Truth.never, box(-2.0, -1.0).factorial().defined);
    try std.testing.expectEqual(Truth.never, Tracked.undefined().factorial().defined);

    // A single argument in the domain is certainly defined, and the negative
    // integers are not arguments: -1! is a value of Gamma's continuation and not
    // of this one.
    const four = pt(4.0).factorial();
    try std.testing.expectEqual(Truth.always, four.defined);
    try std.testing.expect((try rangeOf(four)).contains(24.0));
    try std.testing.expectEqual(Truth.never, pt(-1.0).factorial().defined);
}

test "factorial: large values are not refused for being large" {
    // 19!, 20! and 22! are exact in binary64, so an enclosure can hold them and
    // one that calls them unrepresentable has refused an answer it can give. The
    // criterion is what the format holds, not what fits under 2^53.
    try std.testing.expect((try rangeOf(pt(19.0).factorial())).contains(121645100408832000.0));
    try std.testing.expect((try rangeOf(pt(20.0).factorial())).contains(2432902008176640000.0));
    try std.testing.expect((try rangeOf(pt(22.0).factorial())).contains(1124000727777607680000.0));

    // Zero is an argument and not a hole: 0! is 1.
    try std.testing.expectEqual(Truth.always, pt(0.0).factorial().defined);
    try std.testing.expect((try rangeOf(pt(0.0).factorial())).contains(1.0));
}

test "order statistics: an empty list has no value and a single one has exactly its value" {
    const empty: []const Tracked = &.{};
    const no_min = tracked.min(empty);
    try std.testing.expectEqual(Truth.never, no_min.defined);
    try std.testing.expect(no_min.range == null);
    try std.testing.expectEqual(Truth.never, tracked.max(empty).defined);

    const one = [_]Tracked{pt(2.5)};
    try std.testing.expectEqual(Truth.always, tracked.min(&one).defined);
    try std.testing.expect((try rangeOf(tracked.min(&one))).contains(2.5));
    try std.testing.expectEqual(Truth.always, tracked.max(&one).defined);
    try std.testing.expect((try rangeOf(tracked.max(&one))).contains(2.5));
}

test "order statistics: the middle of three, the middle of four, and the ends" {
    const three = [_]Tracked{ pt(3.0), pt(1.0), pt(2.0) };
    var scratch3: [3]f64 = undefined;
    const middle = try tracked.median(&three, &scratch3);
    try std.testing.expectEqual(Truth.always, middle.defined);
    try std.testing.expect((try rangeOf(middle)).contains(2.0));

    // An even count takes the mean of the two central values, which here are 2
    // and 3. That mean is 5/2, exact in binary floating point.
    const four = [_]Tracked{ pt(4.0), pt(1.0), pt(3.0), pt(2.0) };
    var scratch4: [4]f64 = undefined;
    try std.testing.expect((try rangeOf(try tracked.median(&four, &scratch4))).contains(2.5));

    // The ends are not a separate family: they are the same hull over the same
    // values.
    try std.testing.expect((try rangeOf(tracked.min(&three))).contains(1.0));
    try std.testing.expect((try rangeOf(tracked.max(&three))).contains(3.0));
}

test "order statistics: ties are values, not a distinction the tracker has to make" {
    const tied = [_]Tracked{ pt(2.0), pt(2.0), pt(2.0) };
    var scratch: [3]f64 = undefined;
    const m = try tracked.median(&tied, &scratch);
    try std.testing.expectEqual(Truth.always, m.defined);
    try std.testing.expect((try rangeOf(m)).contains(2.0));
    try std.testing.expectEqual(Truth.always, tracked.min(&tied).defined);
    try std.testing.expect((try rangeOf(tracked.min(&tied))).contains(2.0));
    try std.testing.expectEqual(Truth.always, tracked.max(&tied).defined);
    try std.testing.expect((try rangeOf(tracked.max(&tied))).contains(2.0));

    // Two arguments that tie and one that does not: the hull is still a hull, and
    // the tie costs the caller nothing.
    const mixed = [_]Tracked{ pt(2.0), pt(2.0), pt(7.0) };
    try std.testing.expect((try rangeOf(tracked.min(&mixed))).contains(2.0));
    try std.testing.expect((try rangeOf(tracked.max(&mixed))).contains(7.0));
    try std.testing.expect((try rangeOf(try tracked.nthSmallest(&mixed, pt(2.0), &scratch))).contains(2.0));
    try std.testing.expect((try rangeOf(try tracked.nthLargest(&mixed, pt(1.0), &scratch))).contains(7.0));
}

test "rank: one-based, and only the integers 1..len are ranks" {
    var scratch: [2]f64 = undefined;
    const xs = [_]Tracked{ pt(1.0), pt(5.0) };

    // Rank one is the smallest and rank two the largest here, which is what
    // settles whether the count starts at one.
    try std.testing.expect((try rangeOf(try tracked.nthSmallest(&xs, pt(1.0), &scratch))).contains(1.0));
    try std.testing.expect((try rangeOf(try tracked.nthSmallest(&xs, pt(2.0), &scratch))).contains(5.0));
    try std.testing.expect((try rangeOf(try tracked.nthLargest(&xs, pt(1.0), &scratch))).contains(5.0));
    try std.testing.expect((try rangeOf(try tracked.nthLargest(&xs, pt(2.0), &scratch))).contains(1.0));

    // Rank zero is not a rank, and neither is one past the end.
    try std.testing.expectEqual(Truth.never, (try tracked.nthSmallest(&xs, pt(0.0), &scratch)).defined);
    try std.testing.expectEqual(Truth.never, (try tracked.nthSmallest(&xs, pt(3.0), &scratch)).defined);
    // A rank between the integers is no rank at all.
    try std.testing.expectEqual(Truth.never, (try tracked.nthSmallest(&xs, pt(0.5), &scratch)).defined);
    try std.testing.expectEqual(Truth.never, (try tracked.nthSmallest(&xs, pt(2.5), &scratch)).defined);

    // A rank spanning the valid ones HULLS the answers at those ranks without
    // being wholly in the domain, and those are two separate facts.
    //
    // The enclosure is the hull over ranks 1 and 2, so it reaches both ends of
    // the list: that is what makes a wide rank a hull rather than a refusal.
    //
    // The DEFINEDNESS is a different question, and the answer is `maybe`. This
    // box holds the ranks 1 and 2, and it also holds 0.5, 1.5, 2.1 and every
    // other real between them, and none of those is a rank at all. A function
    // whose domain is the integer ranks 1..len is undefined at those points, so
    // `always` here would claim an answer for arguments that have none. It is not
    // `never` either, because the ranks 1 and 2 in the same box do have answers.
    const span = try tracked.nthSmallest(&xs, box(0.5, 2.5), &scratch);
    try std.testing.expectEqual(Truth.maybe, span.defined);
    const r = try rangeOf(span);
    try std.testing.expect(r.contains(1.0));
    try std.testing.expect(r.contains(5.0));

    // A rank with no value at all leaves no value behind.
    try std.testing.expectEqual(Truth.never, (try tracked.nthSmallest(&xs, Tracked.undefined(), &scratch)).defined);
    // And a rank box containing no integer of the list is a domain failure, not a
    // reason to pick the nearest rank.
    try std.testing.expectEqual(Truth.never, (try tracked.nthSmallest(&xs, box(5.0, 7.0), &scratch)).defined);
}

test "rank: the scratch is sized by the list and too small a one is an error" {
    const xs = [_]Tracked{ pt(3.0), pt(1.0), pt(2.0) };
    var enough: [3]f64 = undefined;
    var short: [2]f64 = undefined;
    try std.testing.expect((try rangeOf(try tracked.nthSmallest(&xs, pt(2.0), &enough))).contains(2.0));
    // The error is explicit rather than an answer computed from a buffer too
    // small to hold the question.
    try std.testing.expectError(error.InsufficientScratch, tracked.nthSmallest(&xs, pt(2.0), &short));
    try std.testing.expectError(error.InsufficientScratch, tracked.median(&xs, &short));
}

test "gcd and lcm: the zeroes are the interesting arguments" {
    const zeros = [_]Tracked{ pt(0.0), pt(0.0) };
    // Euclid's algorithm has nothing to divide by, so there is no greatest common
    // divisor of two zeroes, and the least common multiple of two zeroes is not a
    // value either.
    try std.testing.expectEqual(Truth.never, tracked.gcd(&zeros).defined);
    try std.testing.expectEqual(Truth.never, tracked.lcm(&zeros).defined);

    // One zero among non-zero arguments is a boundary case rather than a hole,
    // and the two families answer it differently on purpose: gcd(0, a) is the
    // magnitude of a, while lcm(0, a) is zero.
    const mixed = [_]Tracked{ pt(0.0), pt(6.0) };
    const g = tracked.gcd(&mixed);
    try std.testing.expectEqual(Truth.always, g.defined);
    try std.testing.expect((try rangeOf(g)).contains(6.0));

    const l = tracked.lcm(&mixed);
    try std.testing.expectEqual(Truth.always, l.defined);
    try std.testing.expect((try rangeOf(l)).contains(0.0));
}

test "gcd and lcm: the sign is not carried, and a box is not a value" {
    const signed = [_]Tracked{ pt(-4.0), pt(6.0) };
    const negatives = [_]Tracked{ pt(-4.0), pt(-6.0) };
    try std.testing.expect((try rangeOf(tracked.gcd(&signed))).contains(2.0));
    try std.testing.expect((try rangeOf(tracked.gcd(&negatives))).contains(2.0));

    const coprime = [_]Tracked{ pt(3.0), pt(4.0) };
    try std.testing.expect((try rangeOf(tracked.lcm(&coprime))).contains(12.0));

    // A box holds many commensurable-real answers rather than one of them, so
    // the family stays partly defined. Reporting `always` would claim that every
    // pair inside the box has a greatest common divisor, and a pair of arguments
    // with no common measure shows that it does not.
    const broad = [_]Tracked{box(2.0, 4.0)};
    try std.testing.expectEqual(Truth.maybe, tracked.gcd(&broad).defined);
    try std.testing.expectEqual(Truth.maybe, tracked.lcm(&broad).defined);

    // An argument with no value has no gcd or lcm with anything.
    const holed = [_]Tracked{ pt(6.0), Tracked.undefined() };
    try std.testing.expectEqual(Truth.never, tracked.gcd(&holed).defined);
    try std.testing.expectEqual(Truth.never, tracked.lcm(&holed).defined);
}

test "mod: the remainder is the positive one and the modulus is a magnitude" {
    const m = pt(2.0);
    const single = tracked.mod(pt(5.0), m);
    try std.testing.expectEqual(Truth.always, single.defined);
    try std.testing.expect((try rangeOf(single)).contains(1.0));

    // A negative dividend leaves a remainder between zero and the magnitude of the
    // modulus. An answer that can go negative has taken the remainder of a
    // programming language rather than the remainder of a number.
    const neg = try rangeOf(tracked.mod(box(-7.0, -5.0), m));
    try std.testing.expect(neg.lo >= 0.0);
    try std.testing.expect(neg.hi <= 2.0);
    try std.testing.expect(neg.contains(1.0));

    // A negative modulus is read by its magnitude, so it is not a hole.
    try std.testing.expectEqual(Truth.always, tracked.mod(pt(5.0), pt(-2.0)).defined);

    // A modulus reaching zero is partly a modulus, and a zero one is not.
    try std.testing.expectEqual(Truth.maybe, tracked.mod(pt(5.0), box(-1.0, 1.0)).defined);
    try std.testing.expectEqual(Truth.never, tracked.mod(pt(5.0), pt(0.0)).defined);
    try std.testing.expectEqual(Truth.never, Tracked.undefined().mod(m).defined);

    // A dividend running over several multiples of the modulus is defined at
    // every point: the remainder exists everywhere, and the enclosure covers both
    // values it takes.
    const over = tracked.mod(box(5.0, 7.0), m);
    try std.testing.expectEqual(Truth.always, over.defined);
    const r = try rangeOf(over);
    try std.testing.expect(r.contains(0.0));
    try std.testing.expect(r.contains(1.0));
}

test "sgn: three values and no hole" {
    const s = box(-5.0, 5.0).sgn();
    try std.testing.expectEqual(Truth.always, s.defined);
    const r = try rangeOf(s);
    try std.testing.expect(r.contains(-1.0));
    try std.testing.expect(r.contains(0.0));
    try std.testing.expect(r.contains(1.0));

    try std.testing.expect((try rangeOf(pt(-2.0).sgn())).contains(-1.0));
    try std.testing.expect((try rangeOf(pt(0.0).sgn())).contains(0.0));
    try std.testing.expect((try rangeOf(pt(2.0).sgn())).contains(1.0));

    // The sign of a value that is not there is not zero.
    const u = Tracked.undefined().sgn();
    try std.testing.expectEqual(Truth.never, u.defined);
    try std.testing.expect(u.range == null);
}

test "steps: the image of a step function is whole numbers with exact endpoints" {
    // 1 and 2 are integers already, so every bit of these answers is the image and
    // none of it is widening. A step function whose endpoints had been moved
    // outward would be answering a question about the format rather than about the
    // function.
    const f = tracked.floor(box(1.0, 2.0));
    try std.testing.expectEqual(Truth.always, f.defined);
    try std.testing.expect((try rangeOf(f)).eql(Interval.init(1.0, 2.0)));
    try std.testing.expect((try rangeOf(pt(1.5).floor())).eql(Interval.init(1.0, 1.0)));
    try std.testing.expect((try rangeOf(box(-1.5, 1.5).ceil())).eql(Interval.init(-1.0, 2.0)));
    try std.testing.expect((try rangeOf(box(-1.5, 1.5).trunc())).eql(Interval.init(-1.0, 1.0)));
    try std.testing.expect((try rangeOf(box(0.5, 0.9).floor())).eql(Interval.init(0.0, 0.0)));

    // Every argument has a floor, so there is no domain to lose here beyond the
    // argument itself.
    try std.testing.expectEqual(Truth.never, Tracked.undefined().floor().defined);
}

test "steps: a tie goes the way each rule says" {
    // `round` keeps its rule of half away from zero. The two tie directions are
    // separate operations with separate rules, and the difference between them is
    // exactly the tie.
    try std.testing.expect((try rangeOf(pt(0.5).round())).eql(Interval.init(1.0, 1.0)));
    try std.testing.expect((try rangeOf(pt(-0.5).round())).eql(Interval.init(-1.0, -1.0)));
    try std.testing.expect((try rangeOf(pt(0.5).roundTiesUp())).eql(Interval.init(1.0, 1.0)));
    try std.testing.expect((try rangeOf(pt(-0.5).roundTiesUp())).eql(Interval.init(0.0, 0.0)));
    try std.testing.expect((try rangeOf(pt(0.5).roundTiesDown())).eql(Interval.init(0.0, 0.0)));
    try std.testing.expect((try rangeOf(pt(-0.5).roundTiesDown())).eql(Interval.init(-1.0, -1.0)));

    // Neither tie rule may lose the value on the other side of the tie: the box
    // [-1/2, 1/2] contains both ties, and each rule has to give both answers.
    const up = try rangeOf(box(-0.5, 0.5).roundTiesUp());
    try std.testing.expect(up.contains(0.0));
    try std.testing.expect(up.contains(1.0));
    const down = try rangeOf(box(-0.5, 0.5).roundTiesDown());
    try std.testing.expect(down.contains(0.0));
    try std.testing.expect(down.contains(-1.0));

    // Away from a tie both rules give the nearer integer, which is what shows the
    // two share everything except the tie itself.
    try std.testing.expect((try rangeOf(pt(0.4).roundTiesUp())).eql(Interval.init(0.0, 0.0)));
    try std.testing.expect((try rangeOf(pt(0.4).roundTiesDown())).eql(Interval.init(0.0, 0.0)));
    try std.testing.expect((try rangeOf(pt(-0.4).roundTiesUp())).eql(Interval.init(0.0, 0.0)));
    try std.testing.expect((try rangeOf(pt(-0.4).roundTiesDown())).eql(Interval.init(0.0, 0.0)));
}

test "steps: an image spanning a jump is uncertain about continuity, not certain about a discontinuity" {
    const across = box(0.9, 1.1).floor();
    try std.testing.expectEqual(Truth.always, across.defined);
    const r = try rangeOf(across);
    try std.testing.expect(r.contains(0.0));
    try std.testing.expect(r.contains(1.0));

    // The two endpoints differ and the function really does jump between them,
    // but "the answer spans two integers" is a statement about the ANSWER and not
    // about the argument. Reading it as a statement about the argument is how a
    // floor spanning a jump becomes `continuous = never`, which claims a
    // discontinuity the tracker has not earned.
    try std.testing.expectEqual(Truth.maybe, across.continuous);

    // A floor that lands on one whole image is a constant function of the
    // argument, and a constant is continuous.
    const within = box(0.5, 0.9).floor();
    try std.testing.expect((try rangeOf(within)).eql(Interval.init(0.0, 0.0)));
    try std.testing.expectEqual(Truth.always, within.continuous);
}

test "steps: a pole inside the argument is a hole and an unbounded answer" {
    // Tangent has a pole at pi/2, and pi/2 lies between 1.5 and 1.6, so the box is
    // partly in the domain and the answer runs to infinity on both sides of the
    // hole. An answer that is bounded here has dropped one of the two ends.
    const t = box(1.5, 1.6).tan();
    try std.testing.expectEqual(Truth.maybe, t.defined);
    const r = try rangeOf(t);
    try std.testing.expectEqual(-inf, r.lo);
    try std.testing.expectEqual(inf, r.hi);

    // The functions that are real everywhere cannot have a hole in them, at any
    // width of argument.
    try std.testing.expectEqual(Truth.always, box(-10.0, 10.0).sin().defined);
    try std.testing.expectEqual(Truth.always, box(-10.0, 10.0).cos().defined);
    try std.testing.expectEqual(Truth.always, box(-10.0, 10.0).tanh().defined);
    try std.testing.expectEqual(Truth.always, box(-10.0, 10.0).exp().defined);
    try std.testing.expectEqual(Truth.always, box(-10.0, 10.0).expm1().defined);
    try std.testing.expectEqual(Truth.always, box(-10.0, 10.0).cbrt().defined);

    // The hole travels with the argument, and zero is not a pole of the tangent.
    try std.testing.expectEqual(Truth.never, Tracked.undefined().tan().defined);
    const at0 = pt(0.0).tan();
    try std.testing.expectEqual(Truth.always, at0.defined);
    try std.testing.expect((try rangeOf(at0)).contains(0.0));
}

// ------------------------------------------------------------- the continuity

test "continuity: a leaf and a smooth total function are continuous" {
    try std.testing.expectEqual(Truth.always, box(-2.0, 3.0).add(box(0.0, 1.0)).continuous);
    try std.testing.expectEqual(Truth.always, box(-2.0, 3.0).mul(box(0.0, 1.0)).continuous);
    try std.testing.expectEqual(Truth.always, pt(1.0).exp().continuous);
    try std.testing.expectEqual(Truth.always, box(-2.0, 3.0).cbrt().continuous);
    try std.testing.expectEqual(Truth.always, box(0.0, 3.0).sqrt().continuous);

    // A negation is the one operation that may carry the operand's continuity
    // across exactly, so it is the one that has to be asked rather than derived.
    const j = meta(0.0, 1.0, .always, .never);
    try std.testing.expectEqual(Truth.never, j.neg().continuous);
}

test "continuity: combining operands never proves a discontinuity" {
    // The rule the lower bound of a smooth composition may use its operands'
    // lower proofs, while the upper bound must leave room for the two boxes to
    // cancel. Copying a `never` down into the answer is the error: it reports a
    // discontinuity the operands do not establish, and for an addition of two
    // boxes it is a statement about the answer rather than about anything the
    // caller can see.
    const j = meta(0.0, 1.0, .always, .never);
    const x = box(1.0, 2.0);
    const results = [_]Tracked{
        j.add(j),
        j.sub(j),
        j.mul(j),
        j.add(x),
        x.sub(j),
        j.mul(x),
        j.div(x),
        x.div(j),
        j.recip(),
        j.abs(),
        j.sqr(),
        j.exp(),
        j.cbrt(),
        j.sin(),
        j.log(),
    };
    for (results) |r| {
        // Each of these can still be defined, which is the premise: a result with
        // no value says nothing about continuity, and a result that can be defined
        // cannot be proved discontinuous from the operands' metadata.
        try std.testing.expect(r.defined.upper());
        try std.testing.expect(r.continuous != Truth.never);
    }
}

test "continuity: the jumps of an operand do not travel into a constant answer" {
    // A floor over a box spanning a jump is uncertain about continuity. Taking two
    // of those and subtracting gives the zero function on the box, and multiplying
    // one by zero gives the same answer from half the operands. A rule that passes
    // `never` down through the combination reports a discontinuity in a constant.
    const f = box(0.9, 1.1).floor();
    try std.testing.expectEqual(Truth.maybe, f.continuous);

    const d = f.sub(f);
    try std.testing.expectEqual(Truth.always, d.defined);
    try std.testing.expect(d.continuous != Truth.never);

    const z = f.mul(pt(0.0));
    try std.testing.expectEqual(Truth.always, z.defined);
    try std.testing.expect((try rangeOf(z)).eql(Interval.init(0.0, 0.0)));
    try std.testing.expect(z.continuous != Truth.never);
}

test "continuity: an operand that is itself uncertain leaves the answer uncertain" {
    // The same floor added to itself. The lower bound may use what the operands
    // prove, and here they prove only that they MAY jump, so the answer may jump
    // too. Reporting `always` here would be a claim about the argument that the
    // operands do not support.
    const f = box(0.9, 1.1).floor();
    const s = f.add(f);
    try std.testing.expectEqual(Truth.always, s.defined);
    try std.testing.expectEqual(Truth.maybe, s.continuous);

    // A partly defined argument is a hole rather than a jump, and the answer keeps
    // the hole rather than reporting a jump or a smooth curve.
    const partial = box(-1.0, 1.0).sqrt();
    try std.testing.expectEqual(Truth.maybe, partial.defined);
    try std.testing.expect(partial.continuous != Truth.always);
}

// -------------------------------------------------------------- the selection

test "select: a known condition takes only the arm it chooses" {
    const live = box(1.0, 2.0);
    const dead = Tracked.undefined();

    const when_true = tracked.select(.always, live, dead);
    try std.testing.expectEqual(Truth.always, when_true.defined);
    try std.testing.expectEqual(Truth.always, when_true.continuous);
    try std.testing.expect((try rangeOf(when_true)).eql(Interval.init(1.0, 2.0)));

    // And the other way round, so the two arms cannot be swapped by accident.
    const when_false = tracked.select(.never, dead, live);
    try std.testing.expectEqual(Truth.always, when_false.defined);
    try std.testing.expectEqual(Truth.always, when_false.continuous);
    try std.testing.expect((try rangeOf(when_false)).eql(Interval.init(1.0, 2.0)));

    // The unused arm has no range at all, so there is nothing of it to hull into
    // the answer and nothing of it to widen the answer with.
    try std.testing.expect(!(try rangeOf(when_true)).contains(0.0));
    try std.testing.expect(!(try rangeOf(when_false)).contains(0.0));

    // A live arm that is itself partly defined comes through with its own domain
    // rather than with the condition's.
    const partial = tracked.select(.always, box(-1.0, 1.0).sqrt(), dead);
    try std.testing.expectEqual(Truth.maybe, partial.defined);
}

test "select: an unknown condition covers both arms" {
    const a = pt(1.0);
    const b = pt(2.0);

    const both = tracked.select(.maybe, a, b);
    try std.testing.expect(both.defined != Truth.never);
    const r = try rangeOf(both);
    try std.testing.expect(r.contains(1.0));
    try std.testing.expect(r.contains(2.0));

    // An arm with no value at all leaves the answer partly defined, whichever side
    // of the condition it is on: the condition is not known, so the dead arm
    // cannot be ruled out and the answer cannot be promised. Nor can it be
    // refused, because the other arm is there.
    const dead = Tracked.undefined();
    const mixed = tracked.select(.maybe, a, dead);
    try std.testing.expectEqual(Truth.maybe, mixed.defined);
    try std.testing.expect((try rangeOf(mixed)).contains(1.0));

    const other = tracked.select(.maybe, dead, b);
    try std.testing.expectEqual(Truth.maybe, other.defined);
    try std.testing.expect((try rangeOf(other)).contains(2.0));

    // Two dead arms leave nothing, and the result is the honest one rather than an
    // empty interval standing in for a value. A known condition over two dead arms
    // has no value either, since both arms it could choose are dead.
    const none = tracked.select(.maybe, dead, dead);
    try std.testing.expectEqual(Truth.never, none.defined);
    try std.testing.expect(none.range == null);
    try std.testing.expectEqual(Truth.never, tracked.select(.always, dead, dead).defined);
    try std.testing.expectEqual(Truth.never, tracked.select(.never, dead, dead).defined);
}

test "select: an unknown condition does not narrow the answer to either arm" {
    // Two distinct values and a condition that may go either way. The answer has
    // to reach both, and a selection that picked the branch it happened to take
    // first would be a number rather than an answer.
    const both = tracked.select(.maybe, pt(1.0), pt(2.0));
    const r = try rangeOf(both);
    try std.testing.expect(r.contains(1.0));
    try std.testing.expect(r.contains(2.0));
    try std.testing.expect(!r.eql(Interval.init(1.0, 1.0)));
    try std.testing.expect(!r.eql(Interval.init(2.0, 2.0)));

    // The same with the arms the other way round, so the hull cannot be an
    // artefact of the order the arguments arrive in.
    const swapped = tracked.select(.maybe, pt(2.0), pt(1.0));
    try std.testing.expect((try rangeOf(swapped)).eql(r));
}

test "select: an unknown condition joins two smooth arms into something that may jump" {
    // Continuity of a selection is not continuity of its arms. Both arms here
    // are leaves, so each is continuous on its own, but a condition that may go
    // either way makes the answer a sawtooth: it takes one value, then the
    // other, then the first again. The seam between the two is a jump, and
    // joining the arms' continuities would report `always` for a function that
    // is discontinuous wherever the condition switches.
    const saw = tracked.select(.maybe, pt(1.0), pt(2.0));
    try std.testing.expectEqual(Truth.maybe, saw.continuous);

    // Two arms that are the SAME single point are the exception: whichever way
    // the condition goes, the answer is that one value, and a constant is
    // continuous however it is selected.
    const same = tracked.select(.maybe, pt(1.0), pt(1.0));
    try std.testing.expectEqual(Truth.always, same.continuous);
    try std.testing.expectEqual(Truth.always, same.defined);
    try std.testing.expect((try rangeOf(same)).eql(Interval.init(1.0, 1.0)));

    // Two arms that are the same BOX are not the same value: the selection is
    // still free to take either end, so the answer is not a point and the
    // continuity of the answer is not promoted either.
    const boxy = tracked.select(.maybe, box(0.0, 1.0), box(0.0, 1.0));
    try std.testing.expectEqual(Truth.maybe, boxy.continuous);
}
