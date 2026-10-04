//! Complex arithmetic, the complex elementary functions, the branch cuts
//! they carry, and the sheet/root families that describe their multivalued
//! inverses.
//!
//! # What an assertion is made of
//!
//! A complex number has no finite decimal expansion in general, so most of
//! this file cannot compare an answer to a written-down value the way a test
//! over integers would. What it does instead falls into four kinds, and
//! each kind names its oracle in the comment that introduces it:
//!
//!  * **Exact witnesses.** A chosen argument has an answer that is exact in
//!    binary floating point, and the assertion is that the enclosure
//!    CONTAINS that exact value. `i*i = -1 + 0i`, `(3+4i)(1-2i) = 9-10i`,
//!    `(3+4i)/(1-2i) = -1+2i`, `|3+4i| = 5`, `(1-i)(1+i) = 2`, the fourth
//!    roots of one being `1, i, -1, -i`, `i^2 = -1`, `(-1)^2 = 1` under the
//!    principal logarithm, `0^0 = 1`. These are small integers, zeros and
//!    exact halves. Nothing here is a rounded transcendental, and nothing
//!    here is a width.
//!
//!  * **Independent decimal brackets — agreement only, NOT containment.**
//!    A transcendental answer is bracketed by hand from the definition,
//!    never measured from the library. `e` between 2.7182818284 and
//!    2.7182818285; `sqrt(3)/2` between 0.8660250 and 0.8660255;
//!    `acosh(2) = ln(2+sqrt(3))` between 1.31695 and 1.31697; `ln(3)/2`
//!    between 0.549306 and 0.5493062; `pi/6` between 0.5235987 and
//!    0.5235989. Each row says where its bracket comes from; a bracket
//!    computed by calling the library and padding it would be the
//!    implementation marking its own homework.
//!
//!    These brackets are a dozen digits wide, so a correctly rounded
//!    answer is NARROWER than the gap between the two ends, and demanding
//!    that it contain both ends would reject a correct answer for being
//!    accurate. What a coarse bracket can support, and all it is used
//!    for here, is `intersectsBracket`: the answer is not entirely above
//!    the bracket and not entirely below it. Every such row carries a
//!    stronger claim beside it — an exact binary witness through
//!    `containsPoint`, or a `pi`-multiple through one of the `has...Pi`
//!    helpers, both of which are real strict containment. Where a row has
//!    no such companion, it says so.
//!
//!  * **Mathematical identities.** `sin^2 + cos^2 = 1`, `cosh^2 - sinh^2 =
//!    1`, `sec*cos = 1`, `exp(log z) = z`, `root(z,n,k)^n = z`,
//!    `sin(asin z) = z`, `asin(-z) = -asin(z)`, `asinh(sinh x) = x`. These
//!    hold as mathematics for every argument used here, so they are exact
//!    oracles, and they are checked through DIFFERENT functions of the
//!    library, which is what makes them worth anything.
//!
//!  * **Structure.** Domain (`defined`), continuity, branch-cut metadata,
//!    sheet and cut-side labels, and caller-buffer resource atomicity. These
//!    have no numeric oracle because they are not numeric claims. The
//!    scalar relations `eq`/`ne` are three-valued here, and they are not
//!    each other's complement over an absent operand: an undefined
//!    argument makes both of them false rather than leaving the pair
//!    split.
//!
//! # What is deliberately absent
//!
//! No assertion here is a width, a ULP count, a phase threshold or a
//! zero-slack constant. Widths are checked only as non-degeneracy: a
//! round trip through two different functions has to be an enclosure of
//! SOMETHING, and an answer that reached for the whole plane would pass
//! every containment check while telling the caller nothing. Those bounds
//! are coarse by many orders of magnitude and the comment at each one says
//! what it is for.
//!
//! There is no text parser, no renderer and no graph of anything here. The
//! subject is the complex layer of a library.

const std = @import("std");
const interval = @import("interval");

const Complex = interval.Complex;
const Bounds = interval.complex.Bounds;
const Interval = interval.Interval;
const Rational = interval.Rational;
const Tracked = interval.Tracked;
const branches = interval.branches;
const cx = interval.complex;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// The bounds of an answer, or a failure when the answer refused to give
/// any. Reaching this helper with a null range means the caller asked
/// something that should have been refused earlier.
fn bounds(c: Complex) !Bounds {
    return c.range orelse return error.WholelyUndefined;
}

/// The range of a real-valued answer, under the same rule.
fn trackedRange(t: Tracked) !Interval {
    return t.range orelse return error.WholelyUndefined;
}

/// `b` contains the exact complex point `(re, im)`. Both coordinates must
/// be exact in binary floating point; every witness in this file is.
fn containsPoint(b: Bounds, re: f64, im: f64) !void {
    try std.testing.expect(b.re.contains(re));
    try std.testing.expect(b.im.contains(im));
}

/// `b` contains the box `(lo, hi)` on the real axis and nothing off it.
/// Used for the round trips whose answer is known to be real.
fn coversReal(b: Bounds, lo: f64, hi: f64) !void {
    try std.testing.expect(b.re.lo <= lo);
    try std.testing.expect(b.re.hi >= hi);
    try std.testing.expect(b.im.contains(0.0));
}

// Multiples of pi. The library publishes directed bounds on the SYMBOL pi
// as FUNCTIONS, `piDown()` and `piUp()`, and multiplying those bounds by a
// power of two is exact in binary floating point, so `k * piDown()` is a
// valid lower bound on `k*pi` for the powers of two used below and
// `k * piUp()` a valid upper one. Only those k are used with these
// helpers; a decimal bracket is written out at every other multiple.
//
// Every helper here is an ASSERTION and not a predicate: each one ends in
// `!void` and does its own `expect`, so a call site reads `try hasPi(x)`
// and cannot accidentally apply `try` to a plain boolean.
//
// These are strict containment and soundness forces every one of them. An
// enclosure of a real that no f64 represents has to reach down to the
// largest f64 at or below it and up to the smallest f64 at or above it,
// because those ARE piDown() and piUp(). A tighter-than-correct answer
// fails here; a correctly rounded one passes.

fn hasPi(i: Interval) !void {
    try std.testing.expect(i.lo <= interval.piDown() and i.hi >= interval.piUp());
}

fn hasNegPi(i: Interval) !void {
    try std.testing.expect(i.lo <= -interval.piUp() and i.hi >= -interval.piDown());
}

fn hasHalfPi(i: Interval) !void {
    try std.testing.expect(i.lo <= interval.piDown() / 2 and i.hi >= interval.piUp() / 2);
}

fn hasNegHalfPi(i: Interval) !void {
    try std.testing.expect(i.lo <= -interval.piUp() / 2 and i.hi >= -interval.piDown() / 2);
}

fn hasQuarterPi(i: Interval) !void {
    try std.testing.expect(i.lo <= interval.piDown() / 4 and i.hi >= interval.piUp() / 4);
}

/// `i` contains `k*pi`, for `k` a power of two and `|k| <= 8`. See the note
/// above on why the multiplication is safe here and nowhere else.
fn hasScaledPi(i: Interval, k: f64) !void {
    try std.testing.expect(i.lo <= k * interval.piDown() and i.hi >= k * interval.piUp());
}

/// `i` and the hand-written bracket `[lo, hi]` agree, which is the ONLY
/// claim a decimal bracket can support.
///
/// The two are written down to a dozen digits, so the true value sits
/// somewhere inside them and no answer of any quality need reach BOTH
/// ends: a correctly rounded enclosure of sqrt(3)/2 is narrower than the
/// gap between 0.8660250 and 0.8660255, and demanding that it contain
/// both would reject a correct answer for being accurate. What soundness
/// does force is that the answer is not ENTIRELY above the bracket and
/// not entirely below it, and that is all this checks. Rows that can be
/// made stronger say so: where the value is exact in binary floating
/// point the assertion is `containsPoint`, and where the value is `pi`
/// times a power of two the assertion is one of the `has...Pi` helpers
/// above, both of which are strict containment.
fn intersectsBracket(i: Interval, lo: f64, hi: f64) !void {
    try std.testing.expect(i.lo <= hi and i.hi >= lo);
}

/// True when the two complex enclosures cannot be the same value. Two
/// roots of the same polynomial are different numbers, so two enclosures
/// that overlap on both axes are a duplicate and not a pair of roots.
fn distinguishable(a: Bounds, b: Bounds) bool {
    return !(a.re.overlaps(b.re) and a.im.overlaps(b.im));
}

/// The choice recorded at `site`, or null when the piece carries no
/// assignment there. A branch producer that leaves its own site unlabelled
/// has produced a cell it cannot be told apart from any other.
fn choiceAt(piece: branches.Piece(Complex), site: branches.Site) ?branches.Choice {
    for (piece.assignments) |a| {
        if (a.site == site) return a.choice;
    }
    return null;
}


// ---------------------------------------------------------------------------
// Arithmetic
// ---------------------------------------------------------------------------

test "i*i encloses -1+0i" {
    const imaginary_unit = Complex.point(0.0, 1.0);
    const square = imaginary_unit.mul(imaginary_unit);
    try std.testing.expect(square.defined == .always);
    try containsPoint(try bounds(square), -1.0, 0.0);

    // 2i is exact too, and it is a different number from -1, which is what
    // makes this a product test and not a square-root test.
    try containsPoint(try bounds(imaginary_unit.add(imaginary_unit)), 0.0, 2.0);
    try containsPoint(try bounds(imaginary_unit.mul(Complex.point(2.0, 0.0))), 0.0, 2.0);
}

test "a complex product reaches its exact witness" {
    // (3+4i)(1-2i) = 3 - 6i + 4i - 8i^2 = 9 - 10i.
    const a = Complex.point(3.0, 4.0);
    const b = Complex.point(1.0, -2.0);
    try containsPoint(try bounds(a.mul(b)), 9.0, -10.0);
    // and the identity z * conj(z) = |z|^2, which is 25 for 3+4i.
    try containsPoint(try bounds(a.mul(a.conjugate())), 25.0, 0.0);
}

test "a complex quotient reaches its exact witness" {
    // (3+4i)/(1-2i) = (3+4i)(1+2i)/5 = (3 - 8 + (6+4)i)/5 = -1 + 2i.
    const a = Complex.point(3.0, 4.0);
    const b = Complex.point(1.0, -2.0);
    try containsPoint(try bounds(a.div(b)), -1.0, 2.0);
    // (1+i)/i = (1+i)(-i)/1 = 1 - i.
    const num = Complex.point(1.0, 1.0);
    const den = Complex.point(0.0, 1.0);
    try containsPoint(try bounds(num.div(den)), 1.0, -1.0);
    // (1+i)(1-i) = 2 exactly, so dividing that product by 2 gives back 1.
    // The quotient is not the point of the row; the point is that the
    // division reaches it and not merely something nearby.
    const pair = Complex.point(1.0, -1.0);
    try containsPoint(try bounds(num.mul(pair)), 2.0, 0.0);
    try containsPoint(try bounds(num.mul(pair).div(Complex.point(2.0, 0.0))), 1.0, 0.0);
}

test "division by zero is absent, and a box that reaches zero is only maybe" {
    const zero = Complex.point(0.0, 0.0);
    const by_zero = Complex.point(3.0, 4.0).div(zero);
    try std.testing.expect(by_zero.defined == .never);
    try std.testing.expect(by_zero.range == null);

    // A real interval crossing zero reaches the pole without sitting on
    // it, so some of the box divides and some of it does not.
    const crossing = Complex.init(Interval.init(-1.0, 1.0), Interval.init(0.0, 0.0));
    const over_crossing = Complex.point(3.0, 4.0).div(crossing);
    try std.testing.expect(over_crossing.defined == .maybe);
    try std.testing.expect(over_crossing.range != null);


    // The complex square root is NOT the real one with a hole in it. It
    // answers at every argument; what it has is a CUT. A box crossing the
    // negative real axis is answered on both sides at once, and that is
    // a continuity claim rather than a domain one.
    const straddling = Complex.init(Interval.init(-4.0, 1.0), Interval.init(-1.0, 1.0)).sqrt();
    try std.testing.expect(straddling.defined == .always);
    try std.testing.expect(straddling.range != null);
    const sb = try bounds(straddling);
    // Principal root has a non-negative real part, sqrt(1) = 1, and both
    // sqrt(-4) = 2i and its mirror reach the imaginary part.
    try std.testing.expect(sb.re.lo >= 0.0);
    try std.testing.expect(sb.re.hi >= 1.0);
    try std.testing.expect(sb.im.hi >= 2.0);
    try std.testing.expect(sb.im.lo <= -2.0);
    // NOT a demand that the answer be `maybe`. A box across a branch cut
    // is genuinely not continuous, and `never` is a correct thing for a
    // sound implementation to say about it; all this row forbids is the
    // opposite mistake, an answer that claims `always`.
    try std.testing.expect(straddling.continuous != .always);
}

test "an undefined argument does not vanish into a zero" {
    const missing = Complex.undefined();
    try std.testing.expect(missing.range == null);
    try std.testing.expect(missing.defined == .never);

    const zero = Complex.point(0.0, 0.0);
    const one = Complex.point(1.0, 1.0);

    const by_multiplication = missing.mul(zero);
    try std.testing.expect(by_multiplication.defined == .never);
    try std.testing.expect(by_multiplication.range == null);

    const by_exponent_zero = missing.pow(zero);
    try std.testing.expect(by_exponent_zero.defined == .never);
    try std.testing.expect(by_exponent_zero.range == null);

    const by_rational_zero = missing.powRational(try Rational.init(0, 1));
    try std.testing.expect(by_rational_zero.defined == .never);
    try std.testing.expect(by_rational_zero.range == null);

    const by_division = missing.div(one);
    try std.testing.expect(by_division.defined == .never);
    try std.testing.expect(by_division.range == null);

    // The accessors and the unary transforms carry the absence through too.
    try std.testing.expect(missing.neg().defined == .never);
    try std.testing.expect(missing.conjugate().defined == .never);
    try std.testing.expect(missing.abs().range == null);
    try std.testing.expect(missing.real().range == null);
    try std.testing.expect(missing.imaginary().range == null);
}

test "negation and conjugation are exact on witnesses" {
    const z = Complex.point(3.0, -4.0);
    try containsPoint(try bounds(z.neg()), -3.0, 4.0);
    try containsPoint(try bounds(z.conjugate()), 3.0, 4.0);
    try containsPoint(try bounds(z.conjugate().conjugate()), 3.0, -4.0);

    const imaginary_unit = Complex.point(0.0, 1.0);
    try containsPoint(try bounds(imaginary_unit.conjugate()), 0.0, -1.0);

    // z + conj(z) is the real part doubled and the imaginary part gone.
    try containsPoint(try bounds(z.add(z.conjugate())), 6.0, 0.0);
    // z - conj(z) is the other half of the same statement.
    try containsPoint(try bounds(z.sub(z.conjugate())), 0.0, -8.0);
}

test "magnitude reaches its exact witness and the accessors read through" {
    const a = Complex.point(3.0, 4.0);
    try std.testing.expect((try trackedRange(a.abs())).contains(5.0));
    try std.testing.expect((try trackedRange(Complex.point(0.0, 0.0).abs())).contains(0.0));
    try std.testing.expect((try trackedRange(Complex.point(0.0, 1.0).abs())).contains(1.0));

    // A box: the modulus of the box contains the moduli of its corners,
    // 0 at the origin and sqrt(34) = 5.8309518948... at (3,5).
    const box = Complex.init(Interval.init(-2.0, 3.0), Interval.init(-4.0, 5.0));
    const m = try trackedRange(box.abs());
    try std.testing.expect(m.contains(0.0));
    try std.testing.expect(intersectsBracket(m, 5.8309518, 5.8309520));

    // |z| and |conj(z)| are the same number, so the two enclosures have to
    // overlap. Two functions that each gave a plausible-looking but
    // disjoint range would pass every check above.
    const modulus = try trackedRange(a.abs());
    const conjugate_modulus = try trackedRange(a.conjugate().abs());
    try std.testing.expect(modulus.overlaps(conjugate_modulus));
    try std.testing.expect(conjugate_modulus.contains(5.0));

    try std.testing.expect((try trackedRange(a.real())).contains(3.0));
    try std.testing.expect((try trackedRange(a.imaginary())).contains(-4.0));
    const accessors = Complex.init(Interval.init(-2.0, 3.0), Interval.init(-4.0, 5.0));
    try std.testing.expect((try trackedRange(accessors.real())).lo <= -2.0);
    try std.testing.expect((try trackedRange(accessors.real())).hi >= 3.0);
    try std.testing.expect((try trackedRange(accessors.imaginary())).lo <= -4.0);
    try std.testing.expect((try trackedRange(accessors.imaginary())).hi >= 5.0);
}

test "eq and ne are scalar relations, and a broad range settles nothing" {
    const a = Complex.point(1.0, 2.0);
    const b = Complex.point(3.0, 4.0);

    try std.testing.expect(a.eq(a) == .always);
    try std.testing.expect(a.ne(a) == .never);
    try std.testing.expect(a.eq(b) == .never);
    try std.testing.expect(a.ne(b) == .always);

    // An undefined operand is not an unknown relation, it is a false one,
    // and both relations say false about it. Neither answers maybe: there
    // is nothing here left to be uncertain about.
    try std.testing.expect(Complex.undefined().eq(a) == .never);
    try std.testing.expect(a.ne(Complex.undefined()) == .never);
    try std.testing.expect(Complex.undefined().eq(Complex.undefined()) == .never);

    // [1,2]x[3,4] could be the same value or not. Two structurally equal
    // ranges are not two equal numbers, and the answer has to say so.
    const box = Complex.init(Interval.init(1.0, 2.0), Interval.init(3.0, 4.0));
    try std.testing.expect(box.eq(box) == .maybe);
    try std.testing.expect(box.ne(box) == .maybe);

    // Disjoint ranges are as certain as equal points are.
    const far = Complex.init(Interval.init(10.0, 11.0), Interval.init(12.0, 13.0));
    try std.testing.expect(far.eq(box) == .never);
    try std.testing.expect(far.ne(box) == .always);
}

// ---------------------------------------------------------------------------
// Log, its sheets, and the cut
// ---------------------------------------------------------------------------

test "log of zero is absent, a box reaching zero is maybe, the right half plane is not" {
    const at_zero = Complex.point(0.0, 0.0).log();
    try std.testing.expect(at_zero.defined == .never);
    try std.testing.expect(at_zero.range == null);

    const touching = Complex.init(Interval.init(-1.0, 1.0), Interval.init(-1.0, 1.0)).log();
    try std.testing.expect(touching.defined == .maybe);
    try std.testing.expect(touching.range != null);

    const safe = Complex.init(Interval.init(0.5, 1.5), Interval.init(0.5, 1.5)).log();
    try std.testing.expect(safe.defined == .always);

    // log(1) = 0 exactly, in both parts.
    try containsPoint(try bounds(Complex.point(1.0, 0.0).log()), 0.0, 0.0);
}

test "the principal log of the exact negative axis uses +pi" {
    // Arg(-1) = pi, not -pi: the convention is Arg in (-pi, pi], and a
    // point exactly ON the axis is on the upper side of that convention.
    try hasPi(try bounds(Complex.point(-1.0, 0.0).log()).im);
    try hasPi(try bounds(Complex.point(-4.0, 0.0).log()).im);
    try containsPoint(try bounds(Complex.point(-1.0, 0.0).log()), 0.0, 0.0);

    // log(2) = ln 2 = 0.693147180559945... on the real axis, no argument.
    const two = try bounds(Complex.point(2.0, 0.0).log());
    try intersectsBracket(two.re, 0.6931471, 0.6931472);
    try std.testing.expect(two.im.contains(0.0));
}

test "a box across the negative axis is uncertain about its side, and the answer spans both" {
    const across = Complex.init(Interval.init(-2.0, -0.5), Interval.init(-0.4, 0.4));
    const b = try bounds(across.log());
    try std.testing.expect(across.log().defined == .always);

    // The box contains points with an argument just under zero and points
    // with an argument of exactly pi, so the principal image reaches both
    // -pi and +pi. A hull that stopped at one of them would be unsound.
    try std.testing.expect(b.im.lo <= -interval.piUp());
    try std.testing.expect(b.im.hi >= interval.piDown());

    // And the principal convention Arg in (-pi, pi] still holds: the
    // answer never leaves that strip, however uncertain it is about where
    // inside it any particular point fell.
    try std.testing.expect(b.im.lo >= -interval.piUp());
    try std.testing.expect(b.im.hi <= interval.piUp());

    // A box that stays clear of the axis still knows which quadrant it is
    // in, and the corners pin that down exactly. Above the axis,
    // arg = pi - atan(im/|re|), and im/|re| runs over [0.25, 1] here, so the
    // smallest argument is 3*pi/4 and the largest is just short of pi.
    // The 3*pi/4 bracket is an agreement check with NO strict companion
    // on this row: 3*pi/4 is not pi times a power of two, so no directed
    // pi bound is available for it. The sign checks around it carry the
    // weight instead.
    const above = try bounds(Complex.init(Interval.init(-2.0, -1.0), Interval.init(0.5, 1.0)).log());
    try std.testing.expect(above.im.lo > 0.0);
    try intersectsBracket(above.im, 2.3561944, 2.3561945);
    try std.testing.expect(above.im.hi < 3.0);

    // Below the axis the arguments are the same numbers negated.
    const below = try bounds(Complex.init(Interval.init(-2.0, -1.0), Interval.init(-1.0, -0.5)).log());
    try std.testing.expect(below.im.hi < 0.0);
    try intersectsBracket(below.im, -2.8966140, -2.8966139);
    try std.testing.expect(below.im.lo > -3.0);
    try std.testing.expect(below.im.lo >= -interval.piUp());
    // Likewise an agreement check without a strict companion. These two
    // rows exist to show which quadrant the answer came out in; the
    // strict containment for pi itself is `hasPi` on the straddling box
    // three rows above.


    // The real part is the logarithm of the MODULUS and knows nothing at
    // all about which side of the axis a point fell on. Being on the
    // negative axis does not force it positive: the smallest modulus in
    // this box is 1/2 at (-1/2, 0), whose logarithm is -ln(2), and the
    // largest is sqrt(2^2 + 0.4^2) = 2.0396078..., whose logarithm is
    // 0.7127575....
    try std.testing.expect(b.re.lo <= -0.6931471);
    try std.testing.expect(b.re.hi >= 0.7127);
}

test "log of a complex point reaches an independent bracket" {
    // log(1+i) = ln(sqrt 2) + i*pi/4 = 0.3465735902799726... + i*pi/4.
    const b = try bounds(Complex.point(1.0, 1.0).log());
    try intersectsBracket(b.re, 0.3465735, 0.3465737);
    try hasQuarterPi(b.im);
    try std.testing.expect(b.im.lo > 0.0);
}

test "exp of log and log of exp return the argument on a valid box" {
    // Identity: exp(log z) = z for z in the right half plane.
    const box = Complex.init(Interval.init(0.5, 1.5), Interval.init(0.2, 0.9));
    const back = try bounds(box.log().exp());
    try std.testing.expect(back.re.lo <= 0.5);
    try std.testing.expect(back.re.hi >= 1.5);
    try std.testing.expect(back.im.lo <= 0.2);
    try std.testing.expect(back.im.hi >= 0.9);

    // Identity: log(exp z) = z whenever Im z is inside the principal strip,
    // and [-1,1] is inside it.
    const strip = Complex.init(Interval.init(0.5, 1.5), Interval.init(-1.0, 1.0));
    const again = try bounds(strip.exp().log());
    try std.testing.expect(again.re.lo <= 0.5);
    try std.testing.expect(again.re.hi >= 1.5);
    try std.testing.expect(again.im.lo <= -1.0);
    try std.testing.expect(again.im.hi >= 1.0);

    // Non-degeneracy only. A round trip through two different functions
    // has to enclose SOMETHING; an answer that had reached for the whole
    // plane would pass every containment check above while telling the
    // caller nothing at all. The bound is orders of magnitude wider than
    // any honest answer to a point argument needs, so this is a floor on
    // usefulness and not a width pin.
    const at_one = try bounds(Complex.point(1.0, 1.0).log().exp());
    try containsPoint(at_one, 1.0, 1.0);
    try std.testing.expect(at_one.re.width() < 0.05);
    try std.testing.expect(at_one.im.width() < 0.05);
}

test "exp of zero and of one" {
    try containsPoint(try bounds(Complex.point(0.0, 0.0).exp()), 1.0, 0.0);
    // e = 2.718281828459045..., bracketed by hand rather than measured.
    const e = try bounds(Complex.point(1.0, 0.0).exp());
    try intersectsBracket(e.re, 2.7182818284, 2.7182818285);
    try std.testing.expect(e.im.contains(0.0));
}

test "logSheet shifts by 2*pi*k, on both sides of k = 0" {
    const z = Complex.point(1.0, 0.0);
    // log(1) = 0, so every sheet is 2*pi*i*k and nothing else.
    try hasScaledPi(try bounds(z.logSheet(0)).im, 0.0);
    try hasScaledPi(try bounds(z.logSheet(1)).im, 2.0);
    try hasScaledPi(try bounds(z.logSheet(-1)).im, -2.0);
    try hasScaledPi(try bounds(z.logSheet(2)).im, 4.0);
    try hasScaledPi(try bounds(z.logSheet(-2)).im, -4.0);

    // The real part is the modulus and does not move with the sheet.
    try containsPoint(try bounds(z.logSheet(0)), 0.0, 0.0);
    try containsPoint(try bounds(z.logSheet(1)), 0.0, 0.0);
    try containsPoint(try bounds(z.logSheet(-3)), 0.0, 0.0);

    // Off the axis the sheet adds to the principal argument: sheet 1 of
    // 1+i is pi/4 + 2*pi = 9*pi/4 = 7.0685834705770345...
    const off_axis = Complex.point(1.0, 1.0);
    const principal = try bounds(off_axis.logSheet(0));
    const shifted = try bounds(off_axis.logSheet(1));
    try intersectsBracket(shifted.re, 0.3465735, 0.3465737);
    try intersectsBracket(shifted.im, 7.0685834, 7.0685835);

    // The decimal bracket above cannot be more than an agreement check,
    // so the shift is also stated exactly and RELATIVELY: sheet 1 is
    // sheet 0 plus one whole turn and nothing else. Both halves are
    // forced by soundness, and roundUp/roundDown keep the f64 sum from
    // rounding in the wrong direction under the test.
    try std.testing.expect(shifted.im.lo <= interval.roundUp(principal.im.hi + 2.0 * interval.piUp()));
    try std.testing.expect(shifted.im.hi >= interval.roundDown(principal.im.lo + 2.0 * interval.piDown()));
}

// ---------------------------------------------------------------------------
// Roots
// ---------------------------------------------------------------------------

test "the four roots of one are 1, i, -1 and -i" {
    const one = Complex.point(1.0, 0.0);
    try containsPoint(try bounds(one.nthRoot(4)), 1.0, 0.0);
    try containsPoint(try bounds(one.root(4, 0)), 1.0, 0.0);
    try containsPoint(try bounds(one.root(4, 1)), 0.0, 1.0);
    try containsPoint(try bounds(one.root(4, 2)), -1.0, 0.0);
    try containsPoint(try bounds(one.root(4, 3)), 0.0, -1.0);
}

test "the principal square root of the negative axis is i" {
    const negative = Complex.point(-1.0, 0.0);
    try containsPoint(try bounds(negative.sqrt()), 0.0, 1.0);
    try containsPoint(try bounds(negative.nthRoot(2)), 0.0, 1.0);
    try containsPoint(try bounds(negative.root(2, 0)), 0.0, 1.0);
    try containsPoint(try bounds(negative.root(2, 1)), 0.0, -1.0);
}

test "nonreal roots: the cubes of one and the cubes of minus eight" {
    const one = Complex.point(1.0, 0.0);
    const k1 = try bounds(one.root(3, 1));
    try std.testing.expect(k1.re.contains(-0.5));
    // sqrt(3)/2 = 0.8660254037844386..., bracketed from sqrt(3).
    try intersectsBracket(k1.im, 0.8660250, 0.8660255);
    try std.testing.expect((try trackedRange(one.root(3, 1).abs())).contains(1.0));

    const k2 = try bounds(one.root(3, 2));
    try std.testing.expect(k2.re.contains(-0.5));
    try intersectsBracket(k2.im, -0.8660255, -0.8660250);

    // The three cube roots of -8 are 1+i*sqrt(3), -2 and 1-i*sqrt(3),
    // because Arg(-8) = pi is INSIDE the principal strip: the principal
    // cube root is at angle pi/3 and the real root sits on sheet 1.
    const minus_eight = Complex.point(-8.0, 0.0);
    const m0 = try bounds(minus_eight.root(3, 0));
    try std.testing.expect(m0.re.contains(1.0));
    try intersectsBracket(m0.im, 0.8660250, 0.8660255);
    try containsPoint(try bounds(minus_eight.root(3, 1)), -2.0, 0.0);
    const m2 = try bounds(minus_eight.root(3, 2));
    try std.testing.expect(m2.re.contains(1.0));
    try intersectsBracket(m2.im, -0.8660255, -0.8660250);

    // Zero is a root of every degree and has no argument to divide.
    try containsPoint(try bounds(Complex.point(0.0, 0.0).nthRoot(5)), 0.0, 0.0);
    try containsPoint(try bounds(Complex.point(0.0, 0.0).root(5, 3)), 0.0, 0.0);
}

test "a zero-th root has no degree to take" {
    const one = Complex.point(1.0, 0.0);
    try std.testing.expect(one.nthRoot(0).defined == .never);
    try std.testing.expect(one.nthRoot(0).range == null);
    try std.testing.expect(one.root(0, 0).defined == .never);
    try std.testing.expect(one.root(0, 0).range == null);
}

test "every root raises back to the radicand" {
    // w^n = z is the definition of the nth root, checked through repeated
    // interval multiplication rather than by comparing to a value the
    // library produced.
    const z = Complex.point(2.0, 0.0);
    var k: i64 = 0;
    while (k < 3) : (k += 1) {
        const w = z.root(3, k);
        const cube = w.mul(w).mul(w);
        try containsPoint(try bounds(cube), 2.0, 0.0);
    }
    const odd = Complex.point(-2.0, 3.0);
    k = 0;
    while (k < 5) : (k += 1) {
        const w = odd.root(5, k);
        const fifth = w.mul(w).mul(w).mul(w).mul(w);
        try containsPoint(try bounds(fifth), -2.0, 3.0);
    }
}

test "the root family has exactly degree branches and they do not coincide" {
    const one = Complex.point(1.0, 0.0);
    const family = one.rootFamily(3);
    try std.testing.expect(family.branchCount().? == 3);

    const a = try bounds(family.at(0) orelse return error.NoSuchSheet);
    const b = try bounds(family.at(1) orelse return error.NoSuchSheet);
    const c = try bounds(family.at(2) orelse return error.NoSuchSheet);

    // All three are on the unit circle and one of them is exactly 1.
    try std.testing.expect(a.re.contains(1.0));
    try std.testing.expect(a.im.contains(0.0));
    try std.testing.expect(distinguishable(a, b));
    try std.testing.expect(distinguishable(a, c));
    try std.testing.expect(distinguishable(b, c));
}

test "the log family is infinite and reaches every sheet" {
    const family = Complex.point(1.0, 0.0).logFamily();
    // null is the documented spelling of "infinitely many branches".
    try std.testing.expect(family.branchCount() == null);

    try hasScaledPi(try bounds(family.at(0) orelse return error.NoSuchSheet).im, 0.0);
    try hasScaledPi(try bounds(family.at(1) orelse return error.NoSuchSheet).im, 2.0);
    try hasScaledPi(try bounds(family.at(-1) orelse return error.NoSuchSheet).im, -2.0);
    try hasScaledPi(try bounds(family.at(4) orelse return error.NoSuchSheet).im, 8.0);
    try hasScaledPi(try bounds(family.at(-4) orelse return error.NoSuchSheet).im, -8.0);
}

// ---------------------------------------------------------------------------
// Powers
// ---------------------------------------------------------------------------

test "pow reaches its exact witnesses, including the branch at minus one" {
    try containsPoint(try bounds(Complex.point(2.0, 0.0).pow(Complex.point(3.0, 0.0))), 8.0, 0.0);
    try containsPoint(try bounds(Complex.point(2.0, 0.0).pow(Complex.point(-1.0, 0.0))), 0.5, 0.0);
    try containsPoint(try bounds(Complex.point(4.0, 0.0).pow(Complex.point(-1.0, 0.0))), 0.25, 0.0);
    try containsPoint(try bounds(Complex.point(1.0, 0.0).pow(Complex.point(0.0, 0.0))), 1.0, 0.0);

    // (-1)^2 = exp(2*i*pi) = 1, the branch convention made visible: the
    // principal log of -1 is +i*pi and twice that is a whole turn.
    try containsPoint(try bounds(Complex.point(-1.0, 0.0).pow(Complex.point(2.0, 0.0))), 1.0, 0.0);

    // 2^(1/2) = sqrt(2) = 1.4142135623730951..., bracketed by hand.
    const half = try bounds(Complex.point(2.0, 0.0).pow(Complex.point(0.5, 0.0)));
    try intersectsBracket(half.re, 1.4142135, 1.4142136);
    try std.testing.expect(half.im.contains(0.0));

    // Zero to a positive power is zero, and not an absence.
    const zero_power = Complex.point(0.0, 0.0).pow(Complex.point(2.0, 0.0));
    try std.testing.expect(zero_power.defined == .always);
    try containsPoint(try bounds(zero_power), 0.0, 0.0);

    // 0^0 is 1 when both operands are defined. That is a value, and not a
    // hole where the product of two absent factors would have gone.
    const zero_to_zero = Complex.point(0.0, 0.0).pow(Complex.point(0.0, 0.0));
    try std.testing.expect(zero_to_zero.defined == .always);
    try containsPoint(try bounds(zero_to_zero), 1.0, 0.0);

    // 0^w extends continuously to zero across the whole HALF PLANE
    // Re(w) > 0, imaginary exponent included, because
    // |w*log z| -> infinity faster than its real part does when z -> 0.
    // 1+i has a positive real part, so the answer is 0 and not a hole.
    const zero_complex_exponent = Complex.point(0.0, 0.0).pow(Complex.point(1.0, 1.0));
    try std.testing.expect(zero_complex_exponent.defined == .always);
    try containsPoint(try bounds(zero_complex_exponent), 0.0, 0.0);

    // 0^i is the other half of that boundary. Re(i) = 0, so the zero
    // extension does not reach it: the magnitude |i*log z| stays put at
    // infinity while the real part does not run off, and there is no
    // value to report. Undefined here means absent, not unknown.
    const zero_to_i = Complex.point(0.0, 0.0).pow(Complex.point(0.0, 1.0));
    try std.testing.expect(zero_to_i.defined == .never);
    try std.testing.expect(zero_to_i.range == null);
}

test "rational powers reach their exact witnesses" {
    // 3 is the NUMERATOR: 8^3 = 512, not 8^(1/3) = 2. The one-third power
    // is spelled with the 3 in the denominator and is a different row.
    try containsPoint(try bounds(Complex.point(8.0, 0.0).powRational(try Rational.init(3, 1))), 512.0, 0.0);
    // 8^-3 = 1/512, which is exact in binary floating point.
    try containsPoint(try bounds(Complex.point(8.0, 0.0).powRational(try Rational.init(-3, 1))), 0.001953125, 0.0);
    try containsPoint(try bounds(Complex.point(9.0, 0.0).powRational(try Rational.init(1, 2))), 3.0, 0.0);
    try containsPoint(try bounds(Complex.point(16.0, 0.0).powRational(try Rational.init(-1, 4))), 0.5, 0.0);
    try containsPoint(try bounds(Complex.point(2.0, 0.0).powRational(try Rational.init(1, 1))), 2.0, 0.0);
    try containsPoint(try bounds(Complex.point(4.0, 0.0).powRational(try Rational.init(0, 1))), 1.0, 0.0);
    try containsPoint(try bounds(Complex.point(1.0, 0.0).powRational(try Rational.init(-1, 1))), 1.0, 0.0);
    try containsPoint(try bounds(Complex.point(0.0, 0.0).powRational(try Rational.init(1, 2))), 0.0, 0.0);

    // The principal convention runs THROUGH the rational power, with no
    // special case anywhere on the negative axis. log(-8) = ln(8) + i*pi,
    // so (-8)^(3/1) = exp(3*ln(8) + 3i*pi) = 8*(-1) = -8. That is not
    // the real cube root of -8 and must not be quietly turned into it.
    try containsPoint(try bounds(Complex.point(-8.0, 0.0).powRational(try Rational.init(3, 1))), -8.0, 0.0);

    // The one-third power IS the principal cube root: Arg(-8) = pi is
    // inside the strip, so the principal root is at angle pi/3, which is
    // 1 + i*sqrt(3) and NOT -2. The real root -2 is selected sheet 1, and
    // it is asserted on its own above, where the sheet index says so.
    const minus_eight = Complex.point(-8.0, 0.0);
    const principal_third = try bounds(minus_eight.powRational(try Rational.init(1, 3)));
    try std.testing.expect(principal_third.re.contains(1.0));
    try std.testing.expect((try trackedRange(minus_eight.powRational(try Rational.init(1, 3)).abs())).contains(2.0));
    try intersectsBracket(principal_third.im, 1.7320507, 1.7320509);

    // On the positive real axis the principal root is the ordinary one.
    try containsPoint(try bounds(Complex.point(8.0, 0.0).powRational(try Rational.init(1, 3))), 2.0, 0.0);
    try containsPoint(try bounds(Complex.point(8.0, 0.0).powRational(try Rational.init(-1, 3))), 0.5, 0.0);

    // Powers of i, where the argument is exact and every sheet lands on an
    // exact point: log(i) = i*pi/2, so i^n = exp(i*n*pi/2).
    const imaginary_unit = Complex.point(0.0, 1.0);
    try containsPoint(try bounds(imaginary_unit.powRational(try Rational.init(2, 1))), -1.0, 0.0);
    try containsPoint(try bounds(imaginary_unit.powRational(try Rational.init(4, 1))), 1.0, 0.0);
    try containsPoint(try bounds(imaginary_unit.powRational(try Rational.init(-2, 1))), -1.0, 0.0);
    try containsPoint(try bounds(imaginary_unit.powRational(try Rational.init(1, 1))), 0.0, 1.0);
}

// ---------------------------------------------------------------------------
// Circular trigonometry
// ---------------------------------------------------------------------------

test "sin squared plus cos squared is one" {
    // Euler's identity, checked by composing two different functions of
    // the library. It is a theorem, not a measurement.
    for ([_]Complex{
        Complex.point(0.5, 0.5),
        Complex.point(-1.25, 0.75),
        Complex.point(2.0, -0.5),
        Complex.init(Interval.init(0.25, 0.75), Interval.init(0.25, 0.75)),
        Complex.init(Interval.init(-0.6, 0.3), Interval.init(0.1, 0.9)),
    }) |z| {
        const identity = z.sin().mul(z.sin()).add(z.cos().mul(z.cos()));
        try containsPoint(try bounds(identity), 1.0, 0.0);
    }

    // Non-degeneracy at a point, coarse on purpose: a sin or a cos that
    // had been widened to the whole plane would make the identity above
    // pass for the wrong reason.
    const at_half = Complex.point(0.5, 0.5);
    try std.testing.expect((try bounds(at_half.sin())).re.width() < 0.01);
    try std.testing.expect((try bounds(at_half.cos())).im.width() < 0.01);
}

test "tan is sin over cos" {
    const z = Complex.point(0.5, 0.5);
    try containsPoint(try bounds(z.tan().mul(z.cos()).sub(z.sin())), 0.0, 0.0);

    const box = Complex.init(Interval.init(0.25, 0.75), Interval.init(0.25, 0.75));
    try containsPoint(try bounds(box.tan().mul(box.cos()).sub(box.sin())), 0.0, 0.0);

    try containsPoint(try bounds(Complex.point(0.0, 0.0).tan()), 0.0, 0.0);
}

test "the reciprocal circular functions invert their partners" {
    const box = Complex.init(Interval.init(0.25, 0.75), Interval.init(0.25, 0.75));
    try containsPoint(try bounds(box.sec().mul(box.cos())), 1.0, 0.0);
    try containsPoint(try bounds(box.csc().mul(box.sin())), 1.0, 0.0);
    try containsPoint(try bounds(box.cot().mul(box.tan())), 1.0, 0.0);

    // And off the real axis, where none of the four partners has a zero.
    const off = Complex.init(Interval.init(0.25, 0.75), Interval.init(1.25, 1.75));
    try containsPoint(try bounds(off.sec().mul(off.cos())), 1.0, 0.0);
    try containsPoint(try bounds(off.csc().mul(off.sin())), 1.0, 0.0);
    try containsPoint(try bounds(off.cot().mul(off.tan())), 1.0, 0.0);
}

test "the tangent pole inside a box is not dropped" {
    // pi/2 = 1.5707963267948966..., so this box straddles it by about
    // 1e-4. Soundness alone forces the image to contain values of size
    // about 1/1e-4 in both directions; asking for hundreds rather than
    // thousands is deliberately weaker than what any sound answer must
    // give, so this catches a hull that swallowed the pole and nothing
    // else that could go wrong.
    const across = Complex.init(Interval.init(1.5707, 1.5709), Interval.init(0.0, 0.0));
    const t = across.tan();
    try std.testing.expect(t.defined == .maybe);
    const b = try bounds(t);
    try std.testing.expect(b.re.hi > 900.0);
    try std.testing.expect(b.re.lo < -900.0);

    // A box that stays away from the pole is simply defined.
    const clear = Complex.init(Interval.init(0.5, 1.0), Interval.init(0.0, 0.0));
    try std.testing.expect(clear.tan().defined == .always);
}

test "circular inverse principal ranges" {
    const asin_half = Complex.point(0.5, 0.0).asin();
    try std.testing.expect(asin_half.defined == .always);
    const ar = try trackedRange(asin_half.real());
    try std.testing.expect(ar.lo >= -interval.piDown() / 2);
    try std.testing.expect(ar.hi <= interval.piUp() / 2);

    const acos_half = Complex.point(0.5, 0.0).acos();
    const cr = try trackedRange(acos_half.real());
    try std.testing.expect(cr.lo >= 0.0);
    try std.testing.expect(cr.hi <= 3.14);

    // The three values that are exact.
    try containsPoint(try bounds(Complex.point(0.0, 0.0).asin()), 0.0, 0.0);
    try containsPoint(try bounds(Complex.point(1.0, 0.0).acos()), 0.0, 0.0);
    try containsPoint(try bounds(Complex.point(0.0, 0.0).atan()), 0.0, 0.0);

    const far = Complex.point(100.0, 0.0).atan();
    const fr = try trackedRange(far.real());
    try std.testing.expect(fr.lo >= -interval.piDown() / 2);
    try std.testing.expect(fr.hi <= interval.piUp() / 2);
    const fi = try trackedRange(far.imaginary());
    try std.testing.expect(fi.contains(0.0));
}

test "sin of asin and atan of tan return the argument" {
    const box = Complex.init(Interval.init(0.25, 0.75), Interval.init(0.0, 0.0));
    try coversReal(try bounds(box.asin().sin()), 0.25, 0.75);
    try coversReal(try bounds(box.tan().atan()), 0.25, 0.75);
    try coversReal(try bounds(box.acos().cos()), 0.25, 0.75);

    // Off the axis as well, inside the unit disc where the principal
    // inverse of sin really is an inverse.
    const inside = Complex.init(Interval.init(0.25, 0.5), Interval.init(0.25, 0.5));
    const back = try bounds(inside.asin().sin());
    try std.testing.expect(back.re.lo <= 0.25);
    try std.testing.expect(back.re.hi >= 0.5);
    try std.testing.expect(back.im.lo <= 0.25);
    try std.testing.expect(back.im.hi >= 0.5);
}

test "asin past the end of the real interval keeps the standard branch" {
    // asin(2) = pi/2 - i*acosh(2), acosh(2) = ln(2+sqrt(3)) =
    // 1.3169578969248166...; asin(-z) = -asin(z) is the same fact again.
    const two = try bounds(Complex.point(2.0, 0.0).asin());
    try hasHalfPi(two.re);
    try intersectsBracket(two.im, -1.31697, -1.31695);

    const minus = try bounds(Complex.point(-2.0, 0.0).asin());
    try hasNegHalfPi(minus.re);
    try intersectsBracket(minus.im, 1.31695, 1.31697);
}

test "reciprocal circular inverses" {
    // acsc(2) = asin(1/2) = pi/6 = 0.5235987755982989...
    const a = try bounds(Complex.point(2.0, 0.0).acsc());
    try intersectsBracket(a.re, 0.5235987, 0.5235989);
    try std.testing.expect(a.im.contains(0.0));

    // asec(2) = acos(1/2) = pi/3 = 1.0471975511965976...
    const s = try bounds(Complex.point(2.0, 0.0).asec());
    try intersectsBracket(s.re, 1.0471975, 1.0471977);
    try std.testing.expect(s.im.contains(0.0));

    // acot(1) = atan(1) = pi/4.
    const c = try bounds(Complex.point(1.0, 0.0).acot());
    try hasQuarterPi(c.im);
    try std.testing.expect(c.re.contains(0.0));

    // cot(z) = 0 has the solution z = pi/2 and the circular arccot is
    // single valued on (0, pi), so its principal value at zero is pi/2.
    const c0 = try bounds(Complex.point(0.0, 0.0).acot());
    try hasHalfPi(c0.im);
    try std.testing.expect(c0.re.contains(0.0));

    // sec and csc never take the value zero, so their inverses have no
    // answer there at all rather than a guess.
    try std.testing.expect(Complex.point(0.0, 0.0).acsc().defined == .never);
    try std.testing.expect(Complex.point(0.0, 0.0).acsc().range == null);
    try std.testing.expect(Complex.point(0.0, 0.0).asec().defined == .never);
    try std.testing.expect(Complex.point(0.0, 0.0).asec().range == null);
}

// ---------------------------------------------------------------------------
// Hyperbolic trigonometry
// ---------------------------------------------------------------------------

test "cosh squared minus sinh squared is one" {
    for ([_]Complex{
        Complex.point(0.5, 0.5),
        Complex.point(-1.25, 0.75),
        Complex.point(2.0, -0.5),
        Complex.init(Interval.init(0.25, 0.75), Interval.init(0.25, 0.75)),
    }) |z| {
        const identity = z.cosh().mul(z.cosh()).sub(z.sinh().mul(z.sinh()));
        try containsPoint(try bounds(identity), 1.0, 0.0);
    }
}

test "the hyperbolic reciprocals invert their partners" {
    const box = Complex.init(Interval.init(0.25, 0.75), Interval.init(0.25, 0.75));
    try containsPoint(try bounds(box.sech().mul(box.cosh())), 1.0, 0.0);
    try containsPoint(try bounds(box.csch().mul(box.sinh())), 1.0, 0.0);
    try containsPoint(try bounds(box.coth().mul(box.tanh())), 1.0, 0.0);
}

test "hyperbolic values at zero and the domains around it" {
    const zero = Complex.point(0.0, 0.0);
    try containsPoint(try bounds(zero.sinh()), 0.0, 0.0);
    try containsPoint(try bounds(zero.cosh()), 1.0, 0.0);
    try containsPoint(try bounds(zero.tanh()), 0.0, 0.0);
    try containsPoint(try bounds(zero.asinh()), 0.0, 0.0);
    try containsPoint(try bounds(Complex.point(1.0, 0.0).acosh()), 0.0, 0.0);
    try containsPoint(try bounds(zero.atanh()), 0.0, 0.0);

    // cosh(z) = 0 at z = pi/2 + k*pi, so the inverse hyperbolic cosine of
    // zero is that solution and not an absence.
    try hasHalfPi(try bounds(zero.acosh()).im);
    try std.testing.expect(zero.acosh().defined == .always);

    // csch and coth divide by sinh, which vanishes at zero.
    try std.testing.expect(zero.csch().defined == .never);
    try std.testing.expect(zero.csch().range == null);
    try std.testing.expect(zero.coth().defined == .never);
    try std.testing.expect(zero.coth().range == null);

    // A box straddling the pole is only partly defined.
    const across = Complex.init(Interval.init(-0.5, 0.5), Interval.init(0.0, 0.0));
    try std.testing.expect(across.csch().defined == .maybe);
    try std.testing.expect(across.coth().defined == .maybe);
}

test "hyperbolic inverses return their argument on the real axis" {
    const box = Complex.init(Interval.init(0.25, 0.75), Interval.init(0.0, 0.0));
    try coversReal(try bounds(box.sinh().asinh()), 0.25, 0.75);
    try coversReal(try bounds(box.cosh().acosh()), 0.25, 0.75);
    try coversReal(try bounds(box.tanh().atanh()), 0.25, 0.75);

    // The same real-axis identities hold in the other order: sinh carries
    // [0.25,0.75] to [0.2526, 0.8223] and atanh carries that back, through
    // a third and fourth pair of functions.
    try coversReal(try bounds(box.atanh(box.sinh())), 0.2526, 0.8223);
}

test "asinh and atanh away from the real axis" {
    // asinh(2i) = log(2i + sqrt((2i)^2 + 1)) = log(2i + sqrt(-3))
    //           = log(i*(2 + sqrt(3))) = acosh(2) + i*pi/2, and
    // acosh(2) = ln(2 + sqrt(3)) = 1.3169578969...
    const s = try bounds(Complex.point(0.0, 2.0).asinh());
    try intersectsBracket(s.re, 1.31695, 1.31697);
    try hasHalfPi(s.im);

    // atanh(i) = (1/2)*log((1+i)/(1-i)) = (1/2)*log(i) = i*pi/4.
    const t = try bounds(Complex.point(0.0, 1.0).atanh());
    try std.testing.expect(t.re.contains(0.0));
    try hasQuarterPi(t.im);
}

test "atanh past the end of the real interval leaves the axis" {
    // atanh(2) = (1/2)*log((1+2)/(1-2)) = (1/2)*log(-3) = ln(3)/2 +/-
    // i*pi/2. Which side of the axis is the convention; leaving the axis
    // is not, so the test asks for the real part exactly and for the
    // imaginary part only up to its size.
    const b = try bounds(Complex.point(2.0, 0.0).atanh());
    try intersectsBracket(b.re, 0.549306, 0.5493062);
    // The imaginary part is exactly pi/2 in magnitude, so this is a strict
    // containment check rather than a decimal one, and it is forced by
    // soundness. Only the SIGN is a convention, so either direction
    // passes and neither of them passing does not.
    try std.testing.expect(b.im.hi >= interval.piDown() / 2 or b.im.lo <= -interval.piUp() / 2);

    // Inside the interval the answer is real. atanh(0.5) is the same
    // number reached from the other side of the argument: (1/2)*ln(3),
    // computed here with a positive logarithm where the row above had to
    // go through a negative one.
    const inside = try bounds(Complex.point(0.5, 0.0).atanh());
    try intersectsBracket(inside.re, 0.549306, 0.5493062);
    try std.testing.expect(inside.im.contains(0.0));
}

// ---------------------------------------------------------------------------
// Domain and continuity metadata
// ---------------------------------------------------------------------------

test "continuity is claimed where the branch is whole and refused where it is cut" {
    // A box across the negative real axis: the principal logarithm is
    // defined everywhere there and continuous nowhere across the axis, so
    // the answer may not claim continuity.
    const across = Complex.init(Interval.init(-2.0, -1.0), Interval.init(-0.5, 0.5));
    const cut = across.log();
    try std.testing.expect(cut.defined == .always);
    // See the note on the same question in the sqrt row: `never` and
    // `maybe` both pass here, and only a claim of `always` fails.
    try std.testing.expect(cut.continuous != .always);

    // A box wholly inside one analytic piece keeps it.
    const inside = Complex.init(Interval.init(0.5, 1.5), Interval.init(0.2, 0.9));
    try std.testing.expect(inside.log().continuous == .always);

    // A point off every cut is continuous wherever it is defined.
    try std.testing.expect(Complex.point(1.0, 1.0).log().continuous == .always);
    try std.testing.expect(Complex.point(0.5, 0.5).exp().continuous == .always);
    try std.testing.expect(Complex.point(0.5, 0.5).sin().continuous == .always);

    // A box crossing the square root's branch cut. The complex root is
    // defined at every argument, so this is a cut and not a hole, and
    // the answer may not claim to be continuous across it.
    const straddling = Complex.init(Interval.init(-4.0, 1.0), Interval.init(-1.0, 1.0)).sqrt();
    try std.testing.expect(straddling.defined == .always);
    try std.testing.expect(straddling.continuous != .always);

    // An undefined answer carries no continuity claim worth making, and
    // no fake range to go with it.
    const absent = Complex.point(0.0, 0.0).log();
    try std.testing.expect(absent.range == null);
    try std.testing.expect(absent.continuous != .always);
}

// ---------------------------------------------------------------------------
// Branch producers
// ---------------------------------------------------------------------------

test "principalLog keeps both sides of the cut and labels them apart" {
    var assignments: [64]branches.Assignment = undefined;
    var slots: [8]branches.Piece(Complex) = undefined;
    var writer = branches.Writer(Complex).init(slots[0..], assignments[0..]);

    // An incoming assignment, standing for a cell the caller reached
    // earlier. A split that dropped it would silently claim the two sides
    // of the cut came from the same place in the caller's program.
    var incoming: [1]branches.Assignment = .{.{ .site = 7, .choice = 11 }};
    var inputs: [1]branches.Piece(Complex) = undefined;
    inputs[0] = .{
        .value = Complex.init(Interval.init(-2.0, -0.5), Interval.init(-0.4, 0.4)),
        .assignments = incoming[0..],
    };
    const input = branches.Set(Complex){ .pieces = inputs[0..] };

    const site: branches.Site = 900;
    const set = try cx.principalLog(&writer, input, site);

    try std.testing.expect(set.pieces.len >= 2);
    try std.testing.expect(set.pieces.len <= slots.len);

    var above = false;
    var below = false;
    var reaches_pi = false;
    var labels: [8]branches.Choice = undefined;
    var n: usize = 0;

    for (set.pieces) |piece| {
        var kept_incoming = false;
        for (piece.assignments) |a| {
            if (a.site == 7 and a.choice == 11) kept_incoming = true;
        }
        try std.testing.expect(kept_incoming);

        const label = choiceAt(piece, site) orelse return error.MissingCutLabel;
        labels[n] = label;
        n += 1;

        const b = try bounds(piece.value);
        // The principal strip is respected on each side separately.
        try std.testing.expect(b.im.lo >= -interval.piUp());
        try std.testing.expect(b.im.hi <= interval.piUp());
        if (b.im.lo >= 0.0) above = true;
        if (b.im.hi <= 0.0) below = true;
        if (b.im.hi >= interval.piDown()) reaches_pi = true;
    }

    try std.testing.expect(above);
    try std.testing.expect(below);
    try std.testing.expect(reaches_pi);

    // Distinct labels are what makes the two sides different cells rather
    // than the same answer written down twice.
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var j: usize = i + 1;
        while (j < n) : (j += 1) {
            try std.testing.expect(labels[i] != labels[j]);
        }
    }
}

test "principalLog of a point off the cut is one piece, not two" {
    var assignments: [16]branches.Assignment = undefined;
    var slots: [8]branches.Piece(Complex) = undefined;
    var writer = branches.Writer(Complex).init(slots[0..], assignments[0..]);

    const no_assignments: [0]branches.Assignment = .{};
    var inputs: [1]branches.Piece(Complex) = undefined;
    inputs[0] = .{ .value = Complex.point(1.0, 0.0), .assignments = no_assignments[0..] };
    const input = branches.Set(Complex){ .pieces = inputs[0..] };

    const set = try cx.principalLog(&writer, input, 901);
    try std.testing.expectEqual(@as(usize, 1), set.pieces.len);
    const b = try bounds(set.pieces[0].value);
    try containsPoint(b, 0.0, 0.0);
    try std.testing.expect(choiceAt(set.pieces[0], 901) != null);
}

test "logSheets writes one piece per selected sheet, each with its own label" {
    var assignments: [64]branches.Assignment = undefined;
    var slots: [8]branches.Piece(Complex) = undefined;
    var writer = branches.Writer(Complex).init(slots[0..], assignments[0..]);

    var incoming: [1]branches.Assignment = .{.{ .site = 3, .choice = 1 }};
    var inputs: [1]branches.Piece(Complex) = undefined;
    inputs[0] = .{ .value = Complex.point(1.0, 0.0), .assignments = incoming[0..] };
    const input = branches.Set(Complex){ .pieces = inputs[0..] };

    const selected = [_]i64{ -1, 0, 1 };
    const site: branches.Site = 902;
    const set = try cx.logSheets(&writer, input, site, selected[0..]);

    try std.testing.expectEqual(@as(usize, 3), set.pieces.len);

    var saw_minus_one = false;
    var saw_zero = false;
    var saw_plus_one = false;
    var labels: [3]branches.Choice = undefined;
    for (set.pieces, 0..) |piece, idx| {
        var kept_incoming = false;
        for (piece.assignments) |a| {
            if (a.site == 3 and a.choice == 1) kept_incoming = true;
        }
        try std.testing.expect(kept_incoming);

        labels[idx] = choiceAt(piece, site) orelse return error.MissingSheetLabel;
        const b = try bounds(piece.value);
        // log(1) = 0, so the three sheets are 0, +2*pi*i and -2*pi*i.
        if (b.im.contains(0.0)) saw_zero = true;
        if (hasScaledPi(b.im, 2.0)) saw_plus_one = true;
        if (hasScaledPi(b.im, -2.0)) saw_minus_one = true;
    }

    try std.testing.expect(saw_zero);
    try std.testing.expect(saw_plus_one);
    try std.testing.expect(saw_minus_one);
    try std.testing.expect(labels[0] != labels[1]);
    try std.testing.expect(labels[0] != labels[2]);
    try std.testing.expect(labels[1] != labels[2]);
}

test "roots writes every degree root, and they are different numbers" {
    var assignments: [64]branches.Assignment = undefined;
    var slots: [8]branches.Piece(Complex) = undefined;
    var writer = branches.Writer(Complex).init(slots[0..], assignments[0..]);

    const no_assignments: [0]branches.Assignment = .{};
    var inputs: [1]branches.Piece(Complex) = undefined;
    inputs[0] = .{ .value = Complex.point(1.0, 0.0), .assignments = no_assignments[0..] };
    const input = branches.Set(Complex){ .pieces = inputs[0..] };

    const site: branches.Site = 903;
    const set = try cx.roots(&writer, input, 3, site);
    try std.testing.expectEqual(@as(usize, 3), set.pieces.len);

    var seen: [3]Bounds = undefined;
    var labels: [3]branches.Choice = undefined;
    var saw_one = false;
    for (set.pieces, 0..) |piece, idx| {
        labels[idx] = choiceAt(piece, site) orelse return error.MissingRootLabel;
        const b = try bounds(piece.value);
        seen[idx] = b;
        if (b.re.contains(1.0) and b.im.contains(0.0)) saw_one = true;

        // w^3 = 1, which is what a root is.
        try containsPoint(try bounds(piece.value.mul(piece.value).mul(piece.value)), 1.0, 0.0);
        // Every cube root of one lies on the unit circle.
        try std.testing.expect((try trackedRange(piece.value.abs())).contains(1.0));
    }

    try std.testing.expect(saw_one);
    try std.testing.expect(distinguishable(seen[0], seen[1]));
    try std.testing.expect(distinguishable(seen[0], seen[2]));
    try std.testing.expect(distinguishable(seen[1], seen[2]));
    try std.testing.expect(labels[0] != labels[1]);
    try std.testing.expect(labels[0] != labels[2]);
    try std.testing.expect(labels[1] != labels[2]);
}

test "a writer with no room reports CapacityExceeded and keeps its count" {
    // Two slots cannot hold four roots. The contract is that the call fails
    // and the writer is left exactly as it was found: a partial set of
    // roots, or a count that has run ahead of the pieces behind it, would
    // both be worse than the failure.
    var assignments: [64]branches.Assignment = undefined;
    var slots: [2]branches.Piece(Complex) = undefined;
    var writer = branches.Writer(Complex).init(slots[0..], assignments[0..]);

    const no_assignments: [0]branches.Assignment = .{};
    var inputs: [1]branches.Piece(Complex) = undefined;
    inputs[0] = .{ .value = Complex.point(1.0, 0.0), .assignments = no_assignments[0..] };
    const input = branches.Set(Complex){ .pieces = inputs[0..] };

    var reported = false;
    cx.roots(&writer, input, 4, 904) catch |err| {
        reported = err == error.CapacityExceeded;
    };
    try std.testing.expect(reported);
    try std.testing.expectEqual(@as(usize, 0), writer.view().pieces.len);
}