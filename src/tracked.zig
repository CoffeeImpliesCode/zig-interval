//! Tracked scalar values: the enclosure, whether there is a value at all,
//! and whether the expression behaves.
//!
//! An `Interval` answers one question — WHERE can the true value lie — and
//! answers it well. It cannot answer the two questions a caller has about an
//! expression whose argument may have no value at all, or may have several:
//!
//!  * Is there a value? A square root of a box crossing zero, a tangent
//!    across a pole, a division by a box containing zero: each has an image
//!    of the part that exists, and the interval version reports that image
//!    as if the whole box had produced it. Nothing in the answer says that
//!    part of the argument produced nothing.
//!  * Is the expression continuous? A floor that spans a jump and a square
//!    root of a box that crosses the axis both return perfectly ordinary
//!    intervals, and a caller reasoning about the difference between the two
//!    has no way to see it.
//!
//! `Tracked` carries both answers beside the enclosure. `range` is the
//! enclosure, `defined` is the truth of whether a value exists at all, and
//! `continuous` is the truth of how the expression behaves as its argument
//! moves. All three are enclosures in their own right: `defined` and
//! `continuous` are `Truth`, which is the enclosure of a Boolean, and a
//! tracked value is wrong in exactly the ways a Boolean interval is wrong
//! when it is used as a Boolean.
//!
//! Two invariants hold every value this file produces, and `withMetadata`
//! asserts them so a caller who breaks one is told rather than obeyed:
//!
//!  * `range == null` if and only if `defined == .never`. A value that does
//!    not exist has no interval standing in for it, and handing back a
//!    degenerate one would put a number into the world where the mathematics
//!    has none. Every other state has an enclosure, because a partly defined
//!    value still has the image of the part that exists.
//!  * `continuous == .always` only when `defined == .always`, and a wholly
//!    undefined value is `continuous == .never`. Continuity of nothing is
//!    not a claim, and continuity of something that may have no value is not
//!    available either.
//!
//! The rules below are written so that the failure modes are the ones a
//! consumer can see. The two that matter most:
//!
//!  * AN UNDEFINED OPERAND NEVER DISAPPEARS. Clipping, multiplying by zero
//!    and raising to the zeroth power all answer a real number for an
//!    expression that has none, and the answer is computed first in every
//!    one of them. `0^0 = 1` says what the answer is WHERE AN ANSWER EXISTS;
//!    it is not a rule that manufactures an argument. The definedness of
//!    every operation below is decided before its enclosure is read.
//!  * A DISCONTINUITY IS NEVER INHERITED UNLESS IT IS EARNED. The lower
//!    bound of the continuity of a composition may use what its operands
//!    prove, and the UPPER bound is always `true`, because a function of a
//!    discontinuous argument can be continuous: the floor of a box that
//!    spans a jump, subtracted from itself, is the constant zero. So the
//!    operations combine the operand LOWER bounds and leave the upper bound
//!    open, and the one operation that may carry an operand's continuity
//!    across exactly is negation, which is injective and therefore cannot
//!    smooth anything away.
//!
//! Every operation of the scalar catalog has a tracked form here, under the
//! same name and in the same order as its `Interval` counterpart, with `Tracked`
//! in place of `Interval` and no optional return: a tracked value carries
//! `never` where the interval version returns `null`, so a caller never has
//! to unwrap and never has to invent a stand-in. The unary and basic
//! operations are methods as well, so a chain reads as a chain; the
//! variable-arity, scratch-taking and extra-parameter operations are module
//! functions. Nothing here allocates: a scratch buffer is the caller's, and
//! no operation converts a list of tracked values into a list of intervals in
//! order to hand it to the interval layer.

const std = @import("std");

const interval_mod = @import("interval.zig");
const certified_mod = @import("certified.zig");
const ext_mod = @import("interval_ext.zig");
const rounding_mod = @import("rounding.zig");
const real_mod = @import("real.zig");
const special_mod = @import("special.zig");
const trig_mod = @import("trig.zig");
const truth_mod = @import("truth.zig");

const Interval = interval_mod.Interval;
const Rational = real_mod.Rational;
const Truth = truth_mod.Truth;

const inf = std.math.inf(f64);

/// The six scalar relations between two real values, in the order they are
/// named in the catalog. A tracked comparison takes one of these rather
/// than a separate function per relation, so a relation can be passed
/// around, stored in a branch label, and switched on.
pub const Cmp = enum { eq, ne, lt, le, gt, ge };

/// The tracked counterpart of `Interval`: an enclosure, the truth of whether
/// a value exists, and the truth of how the expression behaves.
///
/// See the file header for the invariants every value here satisfies and for
/// the rules the operations follow. Two boxes are two boxes, not two
/// samples of one value: nothing in this type cancels a box against itself,
/// which is why `a.sub(a)` over a box is not zero and `a.div(a)` is not one.
pub const Tracked = struct {
    /// The enclosure of every value the expression can take, or `null` when
    /// it has none. See the invariant: `null` and `defined == .never` are
    /// the same statement.
    range: ?Interval,

    /// Whether the expression has a value for every argument in it.
    ///
    /// `always` for an expression that is defined at every point of its
    /// argument box, `never` for one defined at none of it, and `maybe` for
    /// the rest — including a box that is partly out of a domain and a box
    /// whose uncertainty about its own arguments the tracker has not
    /// resolved.
    defined: Truth,

    /// Whether the expression is continuous over the argument, wherever it
    /// has a value.
    ///
    /// This is an enclosure of a Boolean like any other, and `maybe` is the
    /// honest answer for an expression that MAY jump without claiming that it
    /// does. A value that spans a jump is `maybe`; only a proof that the
    /// whole image is one value gives `always`.
    continuous: Truth,

    /// A leaf: a box that is defined and continuous over all of itself,
    /// because there is nothing in a bare box that could fail or jump.
    pub fn init(range: Interval) Tracked {
        return .{ .range = range, .defined = .always, .continuous = .always };
    }

    /// One real value, which is the argument the tracker knows most about.
    pub fn point(x: f64) Tracked {
        return init(Interval.init(x, x));
    }

    /// No value at all, and therefore no interval. The three fields are the
    /// only consistent choice, and every operation that produces one of
    /// these produces it in this shape.
    pub fn undefined() Tracked {
        return .{ .range = null, .defined = .never, .continuous = .never };
    }

    /// A value with its metadata stated outright.
    ///
    /// This is the only way to say that a value is discontinuous somewhere,
    /// which is what a caller with its own analysis needs, and what the
    /// composition rules in this file are stated against. The three
    /// invariants are asserted rather than assumed: `range == null` exactly
    /// when `defined == .never`, a wholly undefined value is never
    /// continuous, and `continuous == .always` only where `defined` is
    /// `always`. A caller who breaks one is told in Debug and ReleaseSafe
    /// instead of being handed a value whose own answers contradict each
    /// other.
    pub fn withMetadata(range: ?Interval, defined: Truth, continuous: Truth) Tracked {
        std.debug.assert((range == null) == (defined == .never));
        std.debug.assert(!(continuous == .always and defined != .always));
        std.debug.assert(!(defined == .never and continuous != .never));
        return .{ .range = range, .defined = defined, .continuous = continuous };
    }

    // ---------------------------------------------------------------- algebra
    //
    // Definedness is the intersection of the operands' and is decided
    // before the enclosure is read, so an operand with no value cannot be
    // lost to the arithmetic. Continuity combines the operand LOWER bounds
    // with an open upper bound, because cancellation between two boxes can
    // be exact and a jump in an operand does not have to survive it.

    pub fn add(self: Tracked, other: Tracked) Tracked {
        const a = self.range orelse return .undefined();
        const b = other.range orelse return .undefined();
        const defined = self.defined.both(other.defined);
        return Tracked.withMetadata(a.add(b), defined, combineCont(self, other, defined));
    }

    pub fn sub(self: Tracked, other: Tracked) Tracked {
        const a = self.range orelse return .undefined();
        const b = other.range orelse return .undefined();
        const defined = self.defined.both(other.defined);
        return Tracked.withMetadata(a.sub(b), defined, combineCont(self, other, defined));
    }

    pub fn mul(self: Tracked, other: Tracked) Tracked {
        const a = self.range orelse return .undefined();
        const b = other.range orelse return .undefined();
        const defined = self.defined.both(other.defined);
        return Tracked.withMetadata(a.mul(b), defined, combineCont(self, other, defined));
    }

    pub fn div(self: Tracked, other: Tracked) Tracked {
        return divide(self, other);
    }

    pub fn recip(self: Tracked) Tracked {
        return reciprocal(self);
    }

    /// The negation.
    ///
    /// The one operation that carries its operand's continuity across
    /// EXACTLY, in both directions. A negation is injective: it sends two
    /// different values to two different values, so whatever the argument
    /// does, the answer does the same thing. Every other operation here has
    /// to leave its upper bound open because it may fold a jump away, and
    /// this one does not.
    pub fn neg(self: Tracked) Tracked {
        const x = self.range orelse return .undefined();
        return Tracked.withMetadata(x.neg(), self.defined, self.continuous);
    }

    pub fn abs(self: Tracked) Tracked {
        const x = self.range orelse return .undefined();
        return Tracked.withMetadata(x.abs(), self.defined, composeCont(self, self.defined));
    }

    pub fn sqr(self: Tracked) Tracked {
        const x = self.range orelse return .undefined();
        return Tracked.withMetadata(x.sqr(), self.defined, composeCont(self, self.defined));
    }

    // ------------------------------------------------------------- relations

    /// Whether the two values can be equal, as an enclosure of the Boolean.
    pub fn eq(self: Tracked, other: Tracked) Truth {
        return self.compare(other, .eq);
    }

    /// Whether the two values can differ, as an enclosure of the Boolean.
    ///
    /// False where either operand has no value: there is no pair of values
    /// there, so they are certainly not different either. That is the price
    /// of `ne` being false, and the two statements together are what a
    /// consumer needs — "not equal" as a RELATION and "not equal" as a
    /// NEGATION are different questions, and `compareNegated` is the second.
    pub fn ne(self: Tracked, other: Tracked) Truth {
        return self.compare(other, .ne);
    }

    /// Whether the left value is certainly below the right one.
    pub fn lt(self: Tracked, other: Tracked) Truth {
        return self.compare(other, .lt);
    }

    /// Whether the left value is certainly at or below the right one.
    pub fn le(self: Tracked, other: Tracked) Truth {
        return self.compare(other, .le);
    }

    /// Whether the left value is certainly above the right one.
    pub fn gt(self: Tracked, other: Tracked) Truth {
        return self.compare(other, .gt);
    }

    /// Whether the left value is certainly at or above the right one.
    pub fn ge(self: Tracked, other: Tracked) Truth {
        return self.compare(other, .ge);
    }

    /// One of the six scalar relations between two tracked values.
    ///
    /// A relation between SCALARS, not between two sets of values: two
    /// identical boxes may hold the same number or different numbers, so
    /// equality between them is `maybe` and not the `always` that the
    /// interval-set question answers. Two disjoint boxes, on the other hand,
    /// settle all six at once.
    ///
    /// `never` when either operand has no value, for every relation
    /// INCLUDING `ne`. There is no value, so there is no relation between
    /// two values — and a caller who wants the other half of that statement
    /// asks for `compareNegated`, whose answer on the same pair is `always`.
    ///
    /// Two enclosures are compared, not two values: the boxes are treated as
    /// independent samples, so `a.sub(a)` is not zero and nothing here
    /// recovers an identity the caller did not state.
    pub fn compare(self: Tracked, other: Tracked, op: Cmp) Truth {
        const a = self.range orelse return .never;
        const b = other.range orelse return .never;
        const same_point = a.lo == a.hi and a.lo == b.lo and b.lo == b.hi;
        const apart = a.hi < b.lo or b.hi < a.lo;
        // Each arm is a pair of bounds: certainly true when the boxes leave
        // the relation no doubt, and possibly true unless they settle it
        // the other way. The comparison is exact on f64 endpoints, so no
        // rounding has to be absorbed here.
        return switch (op) {
            .eq => .fromBounds(same_point, !apart),
            .ne => .fromBounds(apart, !same_point),
            .lt => .fromBounds(a.hi < b.lo, !(a.lo >= b.hi)),
            .le => .fromBounds(a.hi <= b.lo, !(a.lo > b.hi)),
            .gt => .fromBounds(a.lo > b.hi, !(a.hi <= b.lo)),
            .ge => .fromBounds(a.lo >= b.hi, !(a.hi < b.lo)),
        };
    }

    /// The NEGATION of `compare`, which is not an inverse relation.
    ///
    /// Negating a relation that is certainly false gives one that is
    /// certainly true, so a comparison against a value that does not exist
    /// answers `always` here and `never` there. Swapping the order instead
    /// would answer a different question: the negation of a false `ge` is
    /// certainly true, while no order relation against a hole is anything
    /// but certainly false. The two differ on the same pair of arguments,
    /// and `negate` is the one this function is defined to be.
    pub fn compareNegated(self: Tracked, other: Tracked, op: Cmp) Truth {
        return self.compare(other, op).negate();
    }

    // ------------------------------------------------------------ elementary

    /// The square root: real at and above zero, so a box crossing the axis
    /// is partly in the domain and a box wholly below it is out of it.
    pub fn sqrt(self: Tracked) Tracked {
        return partial(self, ext_mod.sqrt, atOrAboveZero);
    }

    /// The cube root, defined and rising over all of the reals.
    pub fn cbrt(self: Tracked) Tracked {
        return total(self, ext_mod.cbrt);
    }

    /// An integer power, by repeated multiplication.
    ///
    /// A zero exponent is the constant one at every real argument, zero base
    /// included, so over a box that has a value the answer is defined and
    /// continuous whatever the argument does. A NEGATIVE exponent is a
    /// division, and a base reaching zero is then partly out of the domain
    /// while a base that IS zero is out of it whole.
    ///
    /// The base still has to be there. `0^0 = 1` says what the answer is
    /// where an answer exists; it does not manufacture an argument.
    pub fn pow(self: Tracked, n: i32) Tracked {
        const x = self.range orelse return .undefined();
        if (n == 0) {
            return Tracked.withMetadata(ext_mod.pow(x, 0), self.defined, .fromBounds(self.defined.lower(), true));
        }
        const verdict = if (n < 0) excluding(x, 0.0) else .always;
        if (verdict == .never) return .undefined();
        const defined = self.defined.both(verdict);
        return Tracked.withMetadata(ext_mod.pow(x, n), defined, composeCont(self, defined));
    }

    /// A general power with a floating-point exponent.
    ///
    /// The domain is read from the mathematics of the two boxes rather than
    /// from what any single kernel can compute, because it is a question
    /// about both arguments at once. Every real exponent of a positive base
    /// is real. A NEGATIVE base needs an exponent of odd denominator in
    /// lowest terms, and every finite f64 is a dyadic rational: it is an
    /// integer, or a fraction whose reduced denominator is a power of two
    /// and therefore even unless the value is an integer. So a wholly
    /// negative base has no real image under a singleton non-integer
    /// exponent — including one that was MEANT as a third, which is exactly
    /// the reading this refuses — and a positive-width exponent box reaches
    /// both parities of numerator, so the answer is partly defined and the
    /// enclosure is symmetric about zero rather than one of its halves.
    ///
    /// Zero needs a non-negative exponent, with `0^0 = 1` by the convention
    /// the family is built on.
    pub fn powf(self: Tracked, y: Tracked) Tracked {
        const base = self.range orelse return .undefined();
        const exponent = y.range orelse return .undefined();
        const verdict = powfVerdict(base, exponent);
        if (verdict == .never) return .undefined();
        const image = powfImage(base, exponent) orelse return .undefined();
        const defined = self.defined.both(y.defined).both(verdict);
        return Tracked.withMetadata(image, defined, combineCont(self, y, defined));
    }

    pub fn exp(self: Tracked) Tracked {
        return total(self, ext_mod.exp);
    }

    pub fn exp2(self: Tracked) Tracked {
        return total(self, ext_mod.exp2);
    }

    pub fn expm1(self: Tracked) Tracked {
        return total(self, ext_mod.expm1);
    }

    pub fn log(self: Tracked) Tracked {
        return partial(self, ext_mod.log, aboveZero);
    }

    pub fn log2(self: Tracked) Tracked {
        return partial(self, ext_mod.log2, aboveZero);
    }

    pub fn log10(self: Tracked) Tracked {
        return partial(self, ext_mod.log10, aboveZero);
    }

    pub fn log1p(self: Tracked) Tracked {
        return partial(self, ext_mod.log1p, aboveOpen);
    }

    pub fn sin(self: Tracked) Tracked {
        return total(self, ext_mod.sin);
    }

    pub fn cos(self: Tracked) Tracked {
        return total(self, ext_mod.cos);
    }

    /// The tangent, whose poles are the one place in this file where the
    /// hole is in the ARGUMENT rather than in an image.
    ///
    /// `tan` is defined everywhere except at `pi/2 + k*pi`, and a box that
    /// contains a pole is partly in the domain with an image that runs to
    /// infinity on both sides of it. A singleton is never at a pole: every
    /// pole is transcendental and every finite f64 is a dyadic rational, so
    /// no float argument can be one however close it may look.
    pub fn tan(self: Tracked) Tracked {
        const x = self.range orelse return .undefined();
        const defined = self.defined.both(tangentVerdict(x));
        if (defined == .never) return .undefined();
        return Tracked.withMetadata(ext_mod.tan(x), defined, composeCont(self, defined));
    }

    pub fn asin(self: Tracked) Tracked {
        return partial(self, ext_mod.asin, inUnit);
    }

    pub fn acos(self: Tracked) Tracked {
        return partial(self, ext_mod.acos, inUnit);
    }

    pub fn atan(self: Tracked) Tracked {
        return total(self, ext_mod.atan);
    }

    /// The arc tangent of a quotient, defined wherever the two arguments
    /// are, with the whole of the real line as its answer.
    pub fn atan2(self: Tracked, y: Tracked) Tracked {
        const a = self.range orelse return .undefined();
        const b = y.range orelse return .undefined();
        const defined = self.defined.both(y.defined);
        return Tracked.withMetadata(ext_mod.atan2(a, b), defined, combineCont(self, y, defined));
    }

    pub fn sinh(self: Tracked) Tracked {
        return total(self, ext_mod.sinh);
    }

    pub fn cosh(self: Tracked) Tracked {
        return total(self, ext_mod.cosh);
    }

    pub fn tanh(self: Tracked) Tracked {
        return total(self, ext_mod.tanh);
    }

    pub fn asinh(self: Tracked) Tracked {
        return total(self, ext_mod.asinh);
    }

    /// The arc cosine hyperbolicus, real on the CLOSED half-line from one,
    /// so a box sitting on the one is wholly in the domain.
    pub fn acosh(self: Tracked) Tracked {
        return partial(self, ext_mod.acosh, fromOne);
    }

    /// The arc tangent hyperbolicus, real on the OPEN interval between the
    /// two poles. A box whose endpoints ARE the poles contains two points
    /// with no value, and clipping them away is not the same as being
    /// defined.
    pub fn atanh(self: Tracked) Tracked {
        return partial(self, ext_mod.atanh, inOpenUnit);
    }

    // ----------------------------------------------------------------- steps

    pub fn floor(self: Tracked) Tracked {
        const x = self.range orelse return .undefined();
        return step(self, ext_mod.floor(x));
    }

    pub fn ceil(self: Tracked) Tracked {
        const x = self.range orelse return .undefined();
        return step(self, ext_mod.ceil(x));
    }

    pub fn trunc(self: Tracked) Tracked {
        const x = self.range orelse return .undefined();
        return step(self, ext_mod.trunc(x));
    }

    /// The nearest integer, halves away from zero.
    pub fn round(self: Tracked) Tracked {
        const x = self.range orelse return .undefined();
        return step(self, ext_mod.round(x));
    }

    /// The nearest integer, halves toward positive infinity.
    pub fn roundTiesUp(self: Tracked) Tracked {
        const x = self.range orelse return .undefined();
        return step(self, real_mod.roundTiesUp(x));
    }

    /// The nearest integer, halves toward negative infinity.
    pub fn roundTiesDown(self: Tracked) Tracked {
        const x = self.range orelse return .undefined();
        return step(self, real_mod.roundTiesDown(x));
    }

    // ------------------------------------------------------------------ real

    /// A power by a TAGGED rational, so the exponent is exact rather than a
    /// float standing in for one.
    ///
    /// The domain is the one `real.zig` computes for its own interval, which
    /// is where those rules are written down: an even denominator is an even
    /// root, real at and above zero only; an odd denominator is an odd root,
    /// real at every base; a negative numerator is a division, so a base
    /// reaching zero leaves the domain; and a zero numerator is the constant
    /// one, which is a continuous function of the argument rather than a
    /// merely smooth one.
    pub fn powRational(self: Tracked, p: Rational) Tracked {
        const x = self.range orelse return .undefined();
        const verdict = truthOf(real_mod.powRationalDomain(x, p));
        if (verdict == .never) return .undefined();
        const image = real_mod.powRational(x, p) orelse return .undefined();
        const defined = self.defined.both(verdict);
        if (p.numerator == 0) {
            // The zeroth power is the constant one at every real argument,
            // zero base included, so wherever the argument has a value the
            // answer is a constant function of it.
            return Tracked.withMetadata(image, defined, .fromBounds(defined.lower(), true));
        }
        return Tracked.withMetadata(image, defined, composeCont(self, defined));
    }

    /// The `degree`-th root, index first as in the catalog.
    ///
    /// A degree of zero is not a root of anything, so it has no value at
    /// any argument.
    pub fn nthRoot(self: Tracked, degree: u32) Tracked {
        const x = self.range orelse return .undefined();
        const verdict = truthOf(real_mod.nthRootDomain(degree, x));
        if (verdict == .never) return .undefined();
        const image = real_mod.nthRoot(degree, x) orelse return .undefined();
        const defined = self.defined.both(verdict);
        return Tracked.withMetadata(image, defined, composeCont(self, defined));
    }

    /// A logarithm to a base, base first as in the catalog.
    ///
    /// The base must be positive and must not be one. Both are holes, and
    /// the second is the one that is checked last in an implementation that
    /// checks only the first: a base box that REACHES one is partly out of
    /// the domain however good the argument is, while a base that IS one is
    /// out of it whole. The argument carries the ordinary logarithm's own
    /// domain, so an argument reaching zero runs the answer to minus
    /// infinity and the exact values at the valid bases are still in it.
    pub fn logBase(self: Tracked, x: Tracked) Tracked {
        const base = self.range orelse return .undefined();
        const argument = x.range orelse return .undefined();
        const verdict = truthOf(real_mod.logBaseDomain(base, argument));
        if (verdict == .never) return .undefined();
        // The part of the base below zero has no logarithm in it, so it is
        // clipped away before the interval layer is asked; the part of the
        // argument is left alone, because an argument reaching zero has an
        // unbounded answer and clipping it would answer a different
        // question.
        const usable = Interval.init(@max(base.lo, rounding_mod.min_subnormal), base.hi);
        const image = real_mod.logBase(usable, argument) orelse return .undefined();
        const defined = self.defined.both(x.defined).both(verdict);
        return Tracked.withMetadata(image, defined, combineCont(self, x, defined));
    }

    /// The positive remainder of a division, with the modulus read by its
    /// MAGNITUDE.
    ///
    /// The remainder of a number is between zero and the magnitude of the
    /// modulus, so a negative dividend answers there rather than below
    /// zero, and a negative modulus is not a hole. A modulus reaching zero
    /// is partly a modulus and a zero one is not a modulus at all.
    ///
    /// The remainder is `x - k*|m|` on the cell `k <= x/|m| < k+1`, which
    /// is affine in the dividend and so continuous, and it jumps between
    /// cells. Continuity is therefore proved only for a box that lies inside
    /// a single cell of a point modulus.
    pub fn mod(self: Tracked, modulus: Tracked) Tracked {
        const dividend = self.range orelse return .undefined();
        const m = modulus.range orelse return .undefined();
        const verdict = truthOf(real_mod.modDomain(dividend, m));
        if (verdict == .never) return .undefined();
        const image = real_mod.mod(dividend, m) orelse return .undefined();
        const defined = self.defined.both(modulus.defined).both(verdict);
        return Tracked.withMetadata(image, defined, modularCont(dividend, m, defined));
    }

    /// The mathematical sign: -1, zero or one, with no hole at zero.
    pub fn sgn(self: Tracked) Tracked {
        const x = self.range orelse return .undefined();
        // The sign takes one of three constant values, and a box lying
        // wholly on one side of zero takes one of them everywhere: the
        // answer is then a constant function of the argument however the
        // argument itself behaves. A box reaching zero may take all three,
        // and the sign jumps at zero.
        const constant = x.lo > 0.0 or x.hi < 0.0;
        const cont = if (constant) .fromBounds(self.defined.lower(), true) else .fromBounds(false, true);
        return Tracked.withMetadata(real_mod.sgn(x), self.defined, cont);
    }

    // --------------------------------------------------------------- special

    /// The gamma function, whose poles are the non-positive integers.
    ///
    /// A box containing one of them is partly in the domain with an image
    /// running to infinity on both sides of it; a box that IS one of them
    /// has no value at all. Between the poles the function is real
    /// everywhere, and it is smooth wherever it is defined.
    pub fn gamma(self: Tracked) Tracked {
        const x = self.range orelse return .undefined();
        const verdict = gammaPoleVerdict(x);
        if (verdict == .never) return .undefined();
        const image = special_mod.gamma(x) orelse return .undefined();
        const defined = self.defined.both(verdict);
        return Tracked.withMetadata(image, defined, composeCont(self, defined));
    }

    /// The discrete factorial, whose arguments are the non-negative
    /// integers.
    ///
    /// Those are not an interval. A box between two of them holds values
    /// that are not arguments of this function at all — the fractional
    /// points in between — so it is partly in the domain however exact its
    /// endpoints are, while a box with no non-negative integer in it is out
    /// of the domain whole. The negative integers are arguments of gamma's
    /// continuation and not of this one.
    pub fn factorial(self: Tracked) Tracked {
        const x = self.range orelse return .undefined();
        const has_argument = x.hi >= 0.0 and x.lo <= @floor(x.hi);
        if (!has_argument) return .undefined();
        const single = x.lo == x.hi;
        if (single and (@floor(x.lo) != x.lo or x.lo < 0.0)) return .undefined();
        const image = special_mod.factorial(x) orelse return .undefined();
        const defined = self.defined.both(if (single) .always else .maybe);
        return Tracked.withMetadata(image, defined, .fromBounds(defined.lower(), true));
    }

    // ------------------------------------------------------------------ trig

    /// A forward function of a geometry: the value, with the domain the
    /// geometry and the function together carry.
    ///
    /// The reciprocal functions are read through the function they
    /// reciprocate, in this geometry: `csc` is one over this geometry's
    /// sine, `sec` one over its cosine, `cot` their quotient. Their holes
    /// are therefore the ZEROS of those images, which is the mathematics
    /// rather than a property of any kernel, and it is why a box whose
    /// cosine image stays away from zero is wholly in the domain of the
    /// secant.
    pub fn forward(self: Tracked, g: trig_mod.Geometry, f: trig_mod.Function) Tracked {
        return forwardValue(self, g, f);
    }

    /// The principal inverse of a function of a geometry, so the domain
    /// travels with the function rather than with the wrapper.
    pub fn principalInverse(self: Tracked, g: trig_mod.Geometry, f: trig_mod.Function) Tracked {
        return principalValue(self, g, f);
    }

    /// The full inverse relation, as a family of branches over this
    /// argument.
    pub fn inverseFamily(self: Tracked, g: trig_mod.Geometry, f: trig_mod.Function) Family {
        return family(self, g, f);
    }
};

// ---------------------------------------------------------------- the family

/// The tracked form of a full inverse relation: the same branches as the
/// interval family, each carrying the tracked value.
///
/// The fields are internal state, built by `inverseFamily` and written by
/// nothing else; the members below are the surface. A branch index runs
/// over the WHOLE relation — `null` from `branchCount` means the family is
/// infinite and the lattice formula is in the interval family underneath —
/// and a branch index that names no branch of an empty relation gives
/// `null` here, which is what "no such preimage" means.
pub const Family = struct {
    /// The interval-level family underneath, which carries the branch
    /// formula, and `null` when the argument has no value at all: there is
    /// then no relation to describe, and an interval invented to describe it
    /// would be a value the caller never supplied.
    inner: ?trig_mod.Family,
    g: trig_mod.Geometry,
    f: trig_mod.Function,
    arg: Tracked,

    /// The argument values the inverse takes on branch `branch`, or `null`
    /// when the branch holds nothing for this argument.
    ///
    /// A non-null branch answers the WHOLE argument box only when every
    /// value in it has a preimage there, and the forward image over the
    /// branch settles that: an enclosure failing to cover the box admits
    /// that some value in it has no preimage, so the branch is then only
    /// partly defined. That is a statement about the range of a branch and
    /// not a decision about whether a graph exists anywhere.
    pub fn at(self: Family, branch: i64) ?Tracked {
        const family = self.inner orelse return null;
        const angles = family.at(branch) orelse return null;
        const argument = self.arg.range orelse return null;
        var defined = self.arg.defined;
        const back = trig_mod.forward(self.g, self.f, angles);
        if (back == null or !back.?.contains(argument.lo) or !back.?.contains(argument.hi)) {
            defined = defined.both(.maybe);
        }
        return Tracked.withMetadata(angles, defined, composeCont(self.arg, defined));
    }

    /// How many branches the family has: `null` for an infinite one, whose
    /// integer-lattice formula is in the interval family underneath, and
    /// zero when the argument has no value at all — an argument with no
    /// values has no preimages either, which is the empty relation rather
    /// than an infinite one.
    pub fn branchCount(self: Family) ?usize {
        const family = self.inner orelse return 0;
        return family.branchCount();
    }
};

// --------------------------------------------------------- module operations
//
// Every operation is available as a method above. These are the same calls
// with the first tracked argument written out, so `x.sqrt()` and `sqrt(x)`
// are one operation and not two that can drift.

/// The sum, `a + b`.
pub fn add(a: Tracked, b: Tracked) Tracked {
    return a.add(b);
}

/// The difference, `a - b`.
pub fn sub(a: Tracked, b: Tracked) Tracked {
    return a.sub(b);
}

/// The product, `a * b`.
pub fn mul(a: Tracked, b: Tracked) Tracked {
    return a.mul(b);
}

/// The quotient, `a / b`, with the pole at a divisor reaching zero kept as
/// a domain rather than handed back as a wide number.
pub fn div(a: Tracked, b: Tracked) Tracked {
    return a.div(b);
}

/// The reciprocal, `1 / x`, with the same domain rule as a division.
pub fn recip(x: Tracked) Tracked {
    return x.recip();
}

/// The negation, `-x`.
pub fn neg(x: Tracked) Tracked {
    return x.neg();
}

/// The magnitude, `|x|`.
pub fn abs(x: Tracked) Tracked {
    return x.abs();
}

/// The square, `x * x`.
pub fn sqr(x: Tracked) Tracked {
    return x.sqr();
}

/// The square root.
pub fn sqrt(x: Tracked) Tracked {
    return x.sqrt();
}

/// The cube root.
pub fn cbrt(x: Tracked) Tracked {
    return x.cbrt();
}

/// An integer power.
pub fn pow(x: Tracked, n: i32) Tracked {
    return x.pow(n);
}

/// A general power with a floating-point exponent.
pub fn powf(x: Tracked, y: Tracked) Tracked {
    return x.powf(y);
}

/// The exponential.
pub fn exp(x: Tracked) Tracked {
    return x.exp();
}

/// The exponential to base two.
pub fn exp2(x: Tracked) Tracked {
    return x.exp2();
}

/// The exponential minus one.
pub fn expm1(x: Tracked) Tracked {
    return x.expm1();
}

/// The natural logarithm.
pub fn log(x: Tracked) Tracked {
    return x.log();
}

/// The logarithm to base two.
pub fn log2(x: Tracked) Tracked {
    return x.log2();
}

/// The logarithm to base ten.
pub fn log10(x: Tracked) Tracked {
    return x.log10();
}

/// The logarithm of one more than the argument.
pub fn log1p(x: Tracked) Tracked {
    return x.log1p();
}

/// The sine.
pub fn sin(x: Tracked) Tracked {
    return x.sin();
}

/// The cosine.
pub fn cos(x: Tracked) Tracked {
    return x.cos();
}

/// The tangent, whose poles are in the argument rather than in an image.
pub fn tan(x: Tracked) Tracked {
    return x.tan();
}

/// The arc sine.
pub fn asin(x: Tracked) Tracked {
    return x.asin();
}

/// The arc cosine.
pub fn acos(x: Tracked) Tracked {
    return x.acos();
}

/// The arc tangent.
pub fn atan(x: Tracked) Tracked {
    return x.atan();
}

/// The arc tangent of a quotient, `atan2(y, x)`.
pub fn atan2(y: Tracked, x: Tracked) Tracked {
    return y.atan2(x);
}

/// The hyperbolic sine.
pub fn sinh(x: Tracked) Tracked {
    return x.sinh();
}

/// The hyperbolic cosine.
pub fn cosh(x: Tracked) Tracked {
    return x.cosh();
}

/// The hyperbolic tangent.
pub fn tanh(x: Tracked) Tracked {
    return x.tanh();
}

/// The inverse hyperbolic sine.
pub fn asinh(x: Tracked) Tracked {
    return x.asinh();
}

/// The inverse hyperbolic cosine, real from one upwards.
pub fn acosh(x: Tracked) Tracked {
    return x.acosh();
}

/// The inverse hyperbolic tangent, real between the two open poles.
pub fn atanh(x: Tracked) Tracked {
    return x.atanh();
}

/// The largest integer not above the argument.
pub fn floor(x: Tracked) Tracked {
    return x.floor();
}

/// The smallest integer not below the argument.
pub fn ceil(x: Tracked) Tracked {
    return x.ceil();
}

/// The argument cut towards zero.
pub fn trunc(x: Tracked) Tracked {
    return x.trunc();
}

/// The nearest integer, halves away from zero.
pub fn round(x: Tracked) Tracked {
    return x.round();
}

/// The nearest integer, halves toward positive infinity.
pub fn roundTiesUp(x: Tracked) Tracked {
    return x.roundTiesUp();
}

/// The nearest integer, halves toward negative infinity.
pub fn roundTiesDown(x: Tracked) Tracked {
    return x.roundTiesDown();
}

/// A power by a tagged rational.
pub fn powRational(x: Tracked, p: Rational) Tracked {
    return x.powRational(p);
}

/// The `degree`-th root of the argument, index first.
pub fn nthRoot(degree: u32, x: Tracked) Tracked {
    return x.nthRoot(degree);
}

/// A logarithm to a base, the base first.
pub fn logBase(base: Tracked, x: Tracked) Tracked {
    return base.logBase(x);
}

/// The positive remainder of `x` over the magnitude of `modulus`.
pub fn mod(x: Tracked, modulus: Tracked) Tracked {
    return x.mod(modulus);
}

/// The mathematical sign, -1, zero or one.
pub fn sgn(x: Tracked) Tracked {
    return x.sgn();
}

/// The gamma function.
pub fn gamma(x: Tracked) Tracked {
    return x.gamma();
}

/// The discrete factorial of a non-negative integer.
pub fn factorial(x: Tracked) Tracked {
    return x.factorial();
}

/// A forward function of a geometry.
pub fn forward(g: trig_mod.Geometry, f: trig_mod.Function, x: Tracked) Tracked {
    return forwardValue(x, g, f);
}

/// The principal inverse of a function of a geometry.
pub fn principalInverse(g: trig_mod.Geometry, f: trig_mod.Function, x: Tracked) Tracked {
    return principalValue(x, g, f);
}

/// The full inverse relation of a function of a geometry.
pub fn inverseFamily(g: trig_mod.Geometry, f: trig_mod.Function, x: Tracked) Family {
    return family(x, g, f);
}

/// The least of a list of tracked values.
///
/// The enclosure is the interval between the least lower end and the least
/// upper end, which is the exact image of a function that is monotone in
/// every argument, and the list is read as independent samples: the least
/// of two boxes is not one of them. An empty list has no least value, and a
/// list containing an argument with no value has no least value either.
pub fn min(xs: []const Tracked) Tracked {
    if (xs.len == 0) return .undefined();
    var defined: Truth = .always;
    var cont: Truth = .always;
    var lo = inf;
    var hi = inf;
    for (xs) |x| {
        const r = x.range orelse return .undefined();
        defined = defined.both(x.defined);
        cont = cont.both(x.continuous);
        lo = @min(lo, r.lo);
        hi = @min(hi, r.hi);
    }
    if (defined == .never) return .undefined();
    return Tracked.withMetadata(Interval.init(lo, hi), defined, .fromBounds(cont.lower() and defined.lower(), true));
}

/// The greatest of a list of tracked values, on the same enclosure as `min`
/// with the greatest end of every box.
pub fn max(xs: []const Tracked) Tracked {
    if (xs.len == 0) return .undefined();
    var defined: Truth = .always;
    var cont: Truth = .always;
    var lo = -inf;
    var hi = -inf;
    for (xs) |x| {
        const r = x.range orelse return .undefined();
        defined = defined.both(x.defined);
        cont = cont.both(x.continuous);
        lo = @max(lo, r.lo);
        hi = @max(hi, r.hi);
    }
    if (defined == .never) return .undefined();
    return Tracked.withMetadata(Interval.init(lo, hi), defined, .fromBounds(cont.lower() and defined.lower(), true));
}

/// The middle value of a list: the middle one of an odd count, the mean of
/// the two central values of an even count.
///
/// The scratch is the caller's and holds one `f64` per element. No list of
/// intervals is built on the way: the two bounds are read off the sorted
/// lower ends and the sorted upper ends separately, which is exact because
/// the median is monotone in every argument. A scratch too small for the
/// list is an error rather than an answer computed from a buffer that could
/// not hold the question.
pub fn median(xs: []const Tracked, scratch: []f64) error{InsufficientScratch}!Tracked {
    if (xs.len == 0) return .undefined();
    if (scratch.len < xs.len) return error.InsufficientScratch;
    var defined: Truth = .always;
    var cont: Truth = .always;
    for (xs) |x| {
        if (x.range == null) return .undefined();
        defined = defined.both(x.defined);
        cont = cont.both(x.continuous);
    }
    const lo_bound = middleOfEnds(xs, scratch, true);
    const hi_bound = middleOfEnds(xs, scratch, false);
    return Tracked.withMetadata(
        Interval.init(lo_bound.lo, hi_bound.hi),
        defined,
        .fromBounds(cont.lower() and defined.lower(), true),
    );
}

/// The `rank`-th smallest value of a list, ranks counted from one.
///
/// A rank is an INTEGER from one to the length of the list, and nothing else
/// is one: `0.5` is not the rank half, and neither is anything else between
/// two ranks. So a rank box is read in two separate steps — which integers
/// in `1..len` it contains, and what the rest of the box is — and the first
/// step decides the enclosure while the second decides whether every argument
/// in the box has an answer at all. A box containing no integer of the list is
/// a hole rather than a reason to pick the nearest rank.
pub fn nthSmallest(xs: []const Tracked, rank: Tracked, scratch: []f64) error{InsufficientScratch}!Tracked {
    if (xs.len == 0) return .undefined();
    if (scratch.len < xs.len) return error.InsufficientScratch;
    const r = rank.range orelse return .undefined();
    const window = rankWindow(r, xs.len) orelse return .undefined();
    const defined = rankVerdict(r).both(listDefinedness(xs));
    if (defined == .never) return .undefined();
    return Tracked.withMetadata(
        Interval.init(orderBound(xs, scratch, window.first, true), orderBound(xs, scratch, window.last, false)),
        defined,
        orderStatisticsCont(xs, rank, defined),
    );
}

/// The `rank`-th largest value of a list, which is the `(len + 1 - rank)`-th
/// smallest counting from the other end.
///
/// The mirror is applied to the INTEGER RANKS rather than to the rank box. A
/// rank box is a box of real numbers, and mirroring a box in floating point
/// both rounds and shifts the ends: with three arguments, a rank of
/// `nextDown(1)` is no rank at all, while `4 - nextDown(1)` rounds to the rank
/// three, so mirroring the box would answer for a rank the caller never
/// asked about. Finding the valid integer candidates first and mirroring
/// those moves no information and rounds nothing.
pub fn nthLargest(xs: []const Tracked, rank: Tracked, scratch: []f64) error{InsufficientScratch}!Tracked {
    if (xs.len == 0) return .undefined();
    if (scratch.len < xs.len) return error.InsufficientScratch;
    const r = rank.range orelse return .undefined();
    const window = rankWindow(r, xs.len) orelse return .undefined();
    const defined = rankVerdict(r).both(listDefinedness(xs));
    if (defined == .never) return .undefined();
    // Rank `k` counting from the largest is rank `len + 1 - k` counting from
    // the smallest, so the smallest candidate from this end is the largest
    // candidate from the other one and the bounds swap accordingly.
    const n = xs.len;
    return Tracked.withMetadata(
        Interval.init(
            orderBound(xs, scratch, n + 1 - window.last, true),
            orderBound(xs, scratch, n + 1 - window.first, false),
        ),
        defined,
        orderStatisticsCont(xs, rank, defined),
    );
}

/// The integer ranks a rank box contains, as an inclusive pair of one-based
/// indices into the list, or `null` when it contains none.
///
/// This is the step that makes a rank a rank. The integers of `1..len` are the
/// only ones, so the box is first clipped to that range and then to the
/// integers inside what is left: `[1.5, 2.5]` holds the rank two and nothing
/// else, while `[0.5, 2.2]` holds one and two and `[5, 7]` holds none of them.
/// The clipping is done on the ends rather than by scanning, so a box of any
/// width costs the same as a point.
fn rankWindow(r: Interval, n: usize) ?RankWindow {
    const top: f64 = @floatFromInt(n);
    const first = @ceil(@max(r.lo, 1.0));
    const last = @floor(@min(r.hi, top));
    if (first > last or first < 1.0 or last > top) return null;
    return .{ .first = @intFromFloat(first), .last = @intFromFloat(last) };
}

/// An inclusive range of one-based ranks.
const RankWindow = struct { first: usize, last: usize };

/// Whether the rank box is a value at every argument in it.
///
/// Certain only when the box is ONE number and that number is a rank, because
/// a box of positive width contains real numbers that are not integers at all
/// and so are not ranks: `[1, 2]` contains the ranks one and two and every
/// real between them, and the answers at those two ranks are a hull over them
/// rather than a promise that the box as a whole has one. The `never` case —
/// no rank of the list in the box at all — is decided by the window above and
/// never reaches this.
fn rankVerdict(r: Interval) Truth {
    // A singleton reaching here is a rank: the window was found by clipping
    // to `1..len` and taking the integers inside, so a singleton that has one
    // is an integer of the list. Everything of positive width is uncertain,
    // and the reason is the non-integers in it rather than the ranks.
    return if (r.lo == r.hi) .always else .maybe;
}

/// Whether every element of a list has a value, which a whole-list reduction
/// of any kind inherits: an element with no range leaves nothing behind.
fn listDefinedness(xs: []const Tracked) Truth {
    var defined: Truth = .always;
    for (xs) |x| {
        if (x.range == null) return .never;
        defined = defined.both(x.defined);
    }
    return defined;
}

/// Continuity of an order statistic: the order statistics are Lipschitz in
/// every argument, so the answer is as continuous as its arguments are, with
/// the upper bound left open for the same reason as everywhere else.
fn orderStatisticsCont(xs: []const Tracked, rank: Tracked, defined: Truth) Truth {
    var cont: Truth = rank.continuous;
    for (xs) |x| cont = cont.both(x.continuous);
    return .fromBounds(cont.lower() and defined.lower(), true);
}

/// The greatest common divisor of a list of tracked values, over the reals.
///
/// The arguments are reals rather than integers, so a value of this function
/// exists only where they are COMMENSURABLE — where each is an integer
/// multiple of a common real. Every finite f64 is a dyadic rational and so
/// commensurable with every other, which is why a list of points always has
/// one; a box admits tuples with no common measure at all, which is what
/// leaves such an answer partly defined rather than refused. A zero argument
/// bounds nothing, since `gcd(0, a)` is the magnitude of `a`, and a list of
/// nothing but zeroes has no greatest common divisor, Euclid's algorithm
/// having nothing to divide by.
///
/// The whole list goes to `real.zig` in ONE call rather than being folded
/// here into a binary operation, because three of its decisions are about the
/// list rather than about a pair of its members — the empty-list refusal, the
/// all-zero refusal, and the point-versus-box split between exact arithmetic
/// and a bound — and none of the three survives a fold. The accessor below is
/// what lets the list be handed over whole: the element type is this file's
/// and no array of intervals is built to convert it into the interval layer's.
pub fn gcd(xs: []const Tracked) Tracked {
    const meta = listMetadata(xs, real_mod.gcdDomainOver(Tracked, xs, rangeOf));
    if (meta.defined == .never) return .undefined();
    const image = real_mod.gcdOver(Tracked, xs, rangeOf) orelse return .undefined();
    return Tracked.withMetadata(
        image,
        meta.defined,
        .fromBounds(meta.cont.lower() and meta.defined.lower(), true),
    );
}

/// The least common multiple of a list of tracked values, over the reals.
///
/// Commensurability is the same question it is for the greatest common
/// divisor, and a box leaves the answer just as partly defined. Zero EXTENDS
/// here rather than making a hole: the least common multiple of zero and
/// anything is zero, so one zero argument settles the whole answer, while a
/// list of nothing but zeroes has no least common multiple at all. Those two
/// refusals are the reason this is `real.lcm` over the whole list rather than
/// a fold: the zero extension is checked before any other arm, so a zero
/// argument gives exactly zero whatever else the list holds.
pub fn lcm(xs: []const Tracked) Tracked {
    const meta = listMetadata(xs, real_mod.lcmDomainOver(Tracked, xs, rangeOf));
    if (meta.defined == .never) return .undefined();
    const image = real_mod.lcmOver(Tracked, xs, rangeOf) orelse return .undefined();
    return Tracked.withMetadata(
        image,
        meta.defined,
        .fromBounds(meta.cont.lower() and meta.defined.lower(), true),
    );
}

/// The tracked range of one element, which is what the real layer's
/// parameterised reduction reads a tracked list through. One call per
/// element, no array, no allocator.
fn rangeOf(x: Tracked) ?Interval {
    return x.range;
}

/// The metadata of a whole-list reduction: every element's own definedness
/// and continuity, and then the real layer's verdict about the list.
///
/// An element with no range makes the whole answer never, which is the same
/// answer as an empty list and the same as the value call returning nothing —
/// so all three are read from one place rather than inferred from one another.
/// An element whose range exists but which only sometimes has a value leaves
/// the answer only sometimes defined, which the intersection above carries.
const ListMetadata = struct {
    defined: Truth,
    cont: Truth,
};

fn listMetadata(xs: []const Tracked, domain: real_mod.Domain) ListMetadata {
    var defined: Truth = .always;
    var cont: Truth = .always;
    for (xs) |x| {
        if (x.range == null) return .{ .defined = .never, .cont = .never };
        defined = defined.both(x.defined);
        cont = cont.both(x.continuous);
    }
    return .{ .defined = defined.both(truthOf(domain)), .cont = cont };
}

/// Which arm of a condition is live, and the value that follows from it.
///
/// A KNOWN condition takes only the arm it chooses, and the arm it does not
/// take has no effect on the answer at all: an undefined unused arm has no
/// interval to hull into the result and nothing to widen it with, and the
/// live arm's own domain and continuity come through exactly as they are.
/// An UNKNOWN condition hulls the two arms and joins their definitions as
/// outcome SETS, so the answer has to reach both values and a selection that
/// picked the branch it happened to take first would be a number rather than
/// an answer.
///
/// Its continuity is `maybe` rather than a join of the arms', and the reason
/// is that the JOIN is the wrong operation here rather than a coarse one. The
/// function a conditional computes is piecewise, and a piecewise function is
/// continuous exactly where the pieces agree at the seam — which is a
/// question about the two arms meeting, not about either arm alone. Joining
/// the arms' continuations reports `always` for two smooth arms, and two
/// smooth arms can still jump: `select(maybe, x, x + 1)` is the sawtooth. And
/// an arm that is never continuous carries no proof THROUGH the conditional
/// either, since a jump in the condition can leave the discontinuous arm
/// behind entirely. The one case where `always` is earned is both arms being
/// the same point with the domain to match, where the answer is a constant
/// function of the argument whatever the condition does.
pub fn select(condition: Truth, when_true: Tracked, when_false: Tracked) Tracked {
    if (condition == .always) return when_true;
    if (condition == .never) return when_false;
    const defined = when_true.defined.join(when_false.defined);
    if (defined == .never) return .undefined();
    var range: ?Interval = null;
    if (when_true.range) |a| {
        range = if (when_false.range) |b| a.hull(b) else a;
    } else range = when_false.range;
    return Tracked.withMetadata(range, defined, selectCont(when_true, when_false, defined));
}

/// Continuity of a selection whose condition is not known, under the rule in
/// `select`: constant when the two arms cannot differ, uncertain otherwise.
fn selectCont(when_true: Tracked, when_false: Tracked, defined: Truth) Truth {
    if (defined == .never) return .never;
    const a = when_true.range orelse return .maybe;
    const b = when_false.range orelse return .maybe;
    if (defined.lower() and a.lo == a.hi and b.lo == b.hi and a.lo == b.lo) {
        return .always;
    }
    return .maybe;
}

// ----------------------------------------------------------------- internals

/// Continuity of an operation on two operands.
///
/// The lower bound may use what the operands prove about themselves, and the
/// UPPER bound is left open: two boxes can cancel, and an operation that may
/// cancel cannot report a discontinuity its operands do not establish. A
/// result with no value is not continuous, because there is nothing to be.
fn combineCont(a: Tracked, b: Tracked, defined: Truth) Truth {
    if (defined == .never) return .never;
    return .fromBounds(a.continuous.lower() and b.continuous.lower() and defined.lower(), true);
}

/// Continuity of a smooth function of one operand, under the same rule: the
/// operand's lower bound is a proof and its upper bound is not.
fn composeCont(x: Tracked, defined: Truth) Truth {
    if (defined == .never) return .never;
    return .fromBounds(x.continuous.lower() and defined.lower(), true);
}

/// A function defined at every real argument: only the argument itself can
/// remove a value.
fn total(self: Tracked, image: fn (Interval) Interval) Tracked {
    const x = self.range orelse return .undefined();
    return Tracked.withMetadata(image(x), self.defined, composeCont(self, self.defined));
}

/// A function with a partial domain, lifted with the truth of how much of
/// the box is inside it.
///
/// The domain verdict is decided from the box ALONE and combined with the
/// argument's own definedness, never from whatever the interval layer
/// returned: an enclosure that happens to be wide is not evidence of a hole
/// and an enclosure that happens to be narrow is not evidence against one.
fn partial(self: Tracked, image: fn (Interval) ?Interval, verdict: fn (Interval) Truth) Tracked {
    const x = self.range orelse return .undefined();
    const defined = self.defined.both(verdict(x));
    if (defined == .never) return .undefined();
    const range = image(x) orelse return .undefined();
    return Tracked.withMetadata(range, defined, composeCont(self, defined));
}

/// The real layer's domain verdict in the tracked vocabulary.
///
/// `real.zig` answers "which part of this argument is in the domain" as an
/// enum of its own, and it is the one place the rules for a rational power,
/// a root, a base and a modulus are written down. A tracked value does not
/// re-derive them: an answer that disagreed with the enclosure beside it
/// would be a tracker reporting a domain its own range does not have.
fn truthOf(domain: real_mod.Domain) Truth {
    return switch (domain) {
        .never => .never,
        .maybe => .maybe,
        .always => .always,
    };
}

/// A step function: floor, ceil, trunc, round or either tie rule.
///
/// The endpoints are whole numbers already, so the image is the image and
/// not a widened copy of it. Continuity is proved only for a constant
/// image: a floor that lands on one whole number is a constant function of
/// the argument, and one that reaches a second number jumps somewhere
/// inside the box. That leaves the answer `maybe` about continuity, which
/// says the jump may be there and claims nothing about where.
fn step(self: Tracked, image: Interval) Tracked {
    const constant = image.lo == image.hi;
    const cont = if (constant) .fromBounds(self.defined.lower(), true) else .fromBounds(false, true);
    return Tracked.withMetadata(image, self.defined, cont);
}

/// Division, kept apart so `recip` and the cotangent of a geometry can reach
/// it without a detour through the constant one.
fn divide(a: Tracked, b: Tracked) Tracked {
    const x = a.range orelse return .undefined();
    const y = b.range orelse return .undefined();
    const defined = divVerdict(a.defined, b.defined, y);
    if (defined == .never) return .undefined();
    return Tracked.withMetadata(x.div(y), defined, combineCont(a, b, defined));
}

/// The reciprocal, as a division by the constant one.
fn reciprocal(x: Tracked) Tracked {
    const y = x.range orelse return .undefined();
    const defined = divVerdict(.always, x.defined, y);
    if (defined == .never) return .undefined();
    return Tracked.withMetadata(y.recip(), defined, composeCont(x, defined));
}

/// Whether a quotient exists, from the divisor's own box.
///
/// A divisor that IS zero has no legal value, so nothing is defined at all.
/// A divisor that REACHES zero has one value with no quotient, so the answer
/// is partly defined — and the pole at zero is what makes its enclosure run
/// to infinity rather than merely widen. A divisor away from zero leaves the
/// operands' own definedness as the whole question.
fn divVerdict(a: Truth, b: Truth, divisor: Interval) Truth {
    if (a == .never or b == .never) return .never;
    if (divisor.lo == 0.0 and divisor.hi == 0.0) return .never;
    if (divisor.lo <= 0.0 and 0.0 <= divisor.hi) return .maybe;
    return a.both(b);
}

/// The domain `[0, infinity)`: never below zero, maybe across the axis.
fn atOrAboveZero(y: Interval) Truth {
    if (y.hi < 0.0) return .never;
    if (y.lo < 0.0) return .maybe;
    return .always;
}

/// The domain `(0, infinity)`: the open end is a pole.
fn aboveZero(y: Interval) Truth {
    if (y.hi <= 0.0) return .never;
    if (y.lo <= 0.0) return .maybe;
    return .always;
}

/// The domain `(-1, infinity)`, the one `log1p` has.
fn aboveOpen(y: Interval) Truth {
    if (y.hi <= -1.0) return .never;
    if (y.lo <= -1.0) return .maybe;
    return .always;
}

/// The domain `[-1, 1]`, closed at both ends: the arcsine and the arccosine.
fn inUnit(y: Interval) Truth {
    if (y.hi < -1.0 or y.lo > 1.0) return .never;
    if (y.lo < -1.0 or y.hi > 1.0) return .maybe;
    return .always;
}

/// The domain `(-1, 1)`, open at both ends: the hyperbolic arctangent, whose
/// poles are the ends of the interval rather than a point inside it.
fn inOpenUnit(y: Interval) Truth {
    if (y.hi <= -1.0 or y.lo >= 1.0) return .never;
    if (y.lo <= -1.0 or y.hi >= 1.0) return .maybe;
    return .always;
}

/// The domain `[1, infinity)`: the arc cosine hyperbolicus.
fn fromOne(y: Interval) Truth {
    if (y.hi < 1.0) return .never;
    if (y.lo < 1.0) return .maybe;
    return .always;
}

/// A domain excluding one value: the value itself is out whole, and a box
/// reaching it is partly out.
fn excluding(y: Interval, v: f64) Truth {
    if (y.lo == v and y.hi == v) return .never;
    if (y.lo <= v and v <= y.hi) return .maybe;
    return .always;
}

/// The domain `|y| >= 1`, two closed rays: what a reciprocal argument has to
/// satisfy to lie inside the unit interval of a principal arcsine or
/// arccosine.
fn outsideClosedUnit(y: Interval) Truth {
    if (y.lo > -1.0 and y.hi < 1.0) return .never;
    if (y.hi <= -1.0 or y.lo >= 1.0) return .always;
    return .maybe;
}

/// The domain `|y| > 1`, two open rays: the hyperbolic arc cotangent.
fn outsideOpenUnit(y: Interval) Truth {
    if (y.lo > -1.0 and y.hi < 1.0) return .never;
    if (y.hi < -1.0 or y.lo > 1.0) return .always;
    return .maybe;
}

/// The domain `(a, b]`: the hyperbolic arc secant, which takes its argument
/// at zero only in the limit.
fn inHalfOpen(y: Interval, a: f64, b: f64) Truth {
    if (y.hi <= a or y.lo > b) return .never;
    if (y.lo > a and y.hi <= b) return .always;
    return .maybe;
}

/// Whether the box can contain a pole of the tangent.
///
/// The poles are `pi/2 + k*pi` and every one of them is transcendental, so
/// no finite `f64` can be one: a singleton argument is defined however near
/// a pole it happens to sit. For a box of positive width the question is
/// whether a pole lies inside it, and the certified index range answers it
/// exactly where the count is available — an empty range means no pole can
/// meet the box — while an index that has left what an integer can count is
/// `null`, and `null` means the count failed rather than that there are no
/// poles, so the answer is left open.
fn tangentVerdict(x: Interval) Truth {
    if (x.lo == x.hi) return .always;
    const half_pi = certified_mod.Bounds.div(certified_mod.pi, certified_mod.Bounds.point(2.0));
    const poles = ext_mod.criticalIndices(x, half_pi, certified_mod.pi) orelse return .maybe;
    return if (poles.first > poles.last) .always else .maybe;
}

/// Whether the box can contain a pole of the gamma function.
///
/// The poles are the non-positive integers, which ARE representable, so
/// unlike the tangent this is a question about a box of positive width too.
/// A box containing an integer at or below zero is partly in the domain, and
/// a box that IS one of them is out of it whole.
fn gammaPoleVerdict(x: Interval) Truth {
    // The question is whether ANY integer at or below zero is in the box,
    // so the search stops at zero: the largest pole the box can reach is the
    // integer below the lower of its two ends and the point zero itself.
    const has_pole = x.lo <= @floor(@min(x.hi, 0.0));
    if (!has_pole) return .always;
    if (x.lo == x.hi and x.lo <= 0.0) return .never;
    return .maybe;
}

/// Continuity of a remainder: a box inside one cell of a point modulus
/// gives an affine remainder, and anything else leaves the answer open.
///
/// The cell index is read off the quotient, widened by one step at each end
/// before it is taken, so a box whose ends land within a rounding of a cell
/// boundary reports a jump rather than claiming an affine stretch across it.
fn modularCont(dividend: Interval, modulus: Interval, defined: Truth) Truth {
    if (defined == .never) return .never;
    if (modulus.lo != modulus.hi or modulus.lo == 0.0) return .fromBounds(false, true);
    const magnitude = @abs(modulus.lo);
    const quotient = Interval.init(
        rounding_mod.prevDown(dividend.lo / magnitude),
        rounding_mod.nextUp(dividend.hi / magnitude),
    );
    const cell = ext_mod.floor(quotient);
    if (cell.lo == cell.hi) return .fromBounds(defined.lower(), true);
    return .fromBounds(false, true);
}

/// The truth of "the general power has a real value", read from both boxes.
///
/// Every real exponent of a positive base is real. A negative base needs an
/// exponent of odd reduced denominator, and every finite f64 is a dyadic
/// rational: an integer, or a fraction whose reduced denominator is a power
/// of two, which is even unless the value is an integer. Zero needs a
/// non-negative exponent, with `0^0` read as one.
fn powfVerdict(base: Interval, exponent: Interval) Truth {
    const negative_base = base.lo < 0.0;
    const zero_base = base.lo <= 0.0 and 0.0 <= base.hi;
    const positive_base = base.hi > 0.0;
    const all_integer = exponent.lo == exponent.hi and exponent.lo == @floor(exponent.lo);
    const some_integer = exponent.lo <= @floor(exponent.hi);
    const covered = (!negative_base or all_integer) and (!zero_base or exponent.lo >= 0.0);
    if (covered) return .always;
    const empty = !positive_base and
        !(zero_base and exponent.hi >= 0.0) and
        !(negative_base and some_integer);
    return if (empty) .never else .maybe;
}

/// The enclosure of a general power.
///
/// An integer exponent over a negative base is an integer power, and the
/// integer kernel is the one that carries a negative base correctly, so it
/// is asked directly there. Everything else goes through the general power,
/// which encloses both numerator parities over a positive-width exponent and
/// so reports a symmetric interval rather than one of its halves.
fn powfImage(base: Interval, exponent: Interval) ?Interval {
    const integral = exponent.lo == exponent.hi and exponent.lo == @floor(exponent.lo);
    if (base.lo < 0.0 and integral and exponent.lo >= -2147483648.0 and exponent.lo <= 2147483647.0) {
        return ext_mod.pow(base, @intFromFloat(exponent.lo));
    }
    return ext_mod.powf(base, exponent);
}

/// A forward function of a geometry, with the reciprocal three read through
/// the function each of them reciprocates.
fn forwardValue(x: Tracked, g: trig_mod.Geometry, f: trig_mod.Function) Tracked {
    return switch (f) {
        .sin => direct(x, g, .sin, false),
        .cos => direct(x, g, .cos, false),
        .tan => direct(x, g, .tan, true),
        .csc => reciprocal(direct(x, g, .sin, false)),
        .sec => reciprocal(direct(x, g, .cos, false)),
        .cot => divide(direct(x, g, .cos, false), direct(x, g, .sin, false)),
    };
}

/// One forward function, with the argument's poles taken into account where
/// the geometry has them.
fn direct(x: Tracked, g: trig_mod.Geometry, f: trig_mod.Function, poles: bool) Tracked {
    const r = x.range orelse return .undefined();
    const defined = if (poles) x.defined.both(tangentVerdict(r)) else x.defined;
    if (defined == .never) return .undefined();
    const image = trig_mod.forward(g, f, r) orelse return .undefined();
    return Tracked.withMetadata(image, defined, composeCont(x, defined));
}

/// The principal inverse of a function of a geometry.
///
/// The domain travels with the function: it is the argument's own for a
/// function that is real everywhere, the unit interval for a principal
/// arcsine or arccosine, and the composition's for a reciprocal one, whose
/// argument has to survive the reciprocal first.
fn principalValue(x: Tracked, g: trig_mod.Geometry, f: trig_mod.Function) Tracked {
    const r = x.range orelse return .undefined();
    const defined = x.defined.both(inverseVerdict(g, f, r));
    if (defined == .never) return .undefined();
    const image = trig_mod.principalInverse(g, f, r) orelse return .undefined();
    return Tracked.withMetadata(image, defined, composeCont(x, defined));
}

/// The domain of a principal inverse, from the definitions of the catalog.
///
/// The reciprocal inverses are read through their compositions: an arc
/// secant is an arc cosine of `1/x`, which is legal exactly where `x` has a
/// value and `|1/x|` is at most one, that is where `|x|` is at least one.
/// The hyperbolic arc secant is the one with the open end, since it takes
/// its argument at zero only in the limit.
fn inverseVerdict(g: trig_mod.Geometry, f: trig_mod.Function, y: Interval) Truth {
    return switch (g) {
        .circle => switch (f) {
            .sin, .cos => inUnit(y),
            .tan => .always,
            .csc, .sec => outsideClosedUnit(y),
            .cot => .always,
        },
        .hyperbola => switch (f) {
            .sin => .always,
            .cos => fromOne(y),
            .tan => inOpenUnit(y),
            .csc => excluding(y, 0.0),
            .sec => inHalfOpen(y, 0.0, 1.0),
            .cot => outsideOpenUnit(y),
        },
        .diamond, .square => switch (f) {
            .sin, .cos => inUnit(y),
            .tan => .always,
            .csc, .sec => outsideClosedUnit(y),
            .cot => .always,
        },
    };
}

/// The tracked full inverse family of a geometry and function, over an
/// argument that may have no value at all.
fn family(x: Tracked, g: trig_mod.Geometry, f: trig_mod.Function) Family {
    return .{
        .inner = if (x.range) |r| trig_mod.inverseFamily(g, f, r) else null,
        .g = g,
        .f = f,
        .arg = x,
    };
}

/// Insertion sort over f64, in place, with no allocation.
///
/// The order statistics below are read off this, and a list of tracked
/// values is converted into no list of intervals on the way: the scratch the
/// caller supplied holds one number per element and holds it twice over, for
/// the lower ends and then for the upper ends.
fn sortAscending(values: []f64) void {
    var i: usize = 1;
    while (i < values.len) : (i += 1) {
        const v = values[i];
        var j = i;
        while (j > 0 and values[j - 1] > v) : (j -= 1) values[j] = values[j - 1];
        values[j] = v;
    }
}

/// Fill the scratch with one end of every box, sort it, and read the
/// middle: the median's value at that end of the argument.
fn middleOfEnds(xs: []const Tracked, scratch: []f64, low_end: bool) Interval {
    for (xs, 0..) |x, i| {
        const r = x.range.?;
        scratch[i] = if (low_end) r.lo else r.hi;
    }
    sortAscending(scratch[0..xs.len]);
    const n = xs.len;
    if (n % 2 == 1) {
        const v = scratch[n / 2];
        return Interval.init(v, v);
    }
    // The mean of the two central values. The halves are taken before the
    // sum so a pair of large arguments cannot overflow into an infinity
    // that is not there, and the rounding of the one addition is absorbed
    // outward on both sides.
    const a = scratch[n / 2 - 1] / 2.0;
    const b = scratch[n / 2] / 2.0;
    return Interval.init(rounding_mod.roundDown(a + b), rounding_mod.roundUp(a + b));
}

/// Fill the scratch with one end of every box, sort it, and read the value
/// at one one-based rank: the extreme of that order statistic over the
/// argument. The rank is an integer by the time it arrives here, so nothing
/// in this function rounds and nothing in it decides which ranks are valid.
fn orderBound(xs: []const Tracked, scratch: []f64, rank: usize, low_end: bool) f64 {
    std.debug.assert(rank >= 1 and rank <= xs.len);
    for (xs, 0..) |x, i| {
        const r = x.range.?;
        scratch[i] = if (low_end) r.lo else r.hi;
    }
    sortAscending(scratch[0..xs.len]);
    return scratch[rank - 1];
}

