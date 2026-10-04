//! Complex arithmetic over enclosures, the complex elementary functions, the
//! branch cuts they carry, and the sheet and root families that describe
//! their multivalued inverses.
//!
//! # What a `Complex` is
//!
//! A `Complex` is a BOX in the plane together with two pieces of metadata
//! about it as a function rather than as a number:
//!
//!   * `range: ?Bounds` — the enclosure `[re.lo, re.hi] x [im.lo, im.hi]` of
//!     the values, or `null` when the value is wholly absent. `null` and
//!     `defined == .never` are the same statement, and every constructor here
//!     keeps them in step.
//!   * `defined: Truth` — whether the function is defined at every argument
//!     of the box (`always`), at some (`maybe`), or at none (`never`).
//!   * `continuous: Truth` — whether the function is continuous on the box.
//!
//! `continuous == .always` is only ever claimed when `defined == .always`,
//! and a wholly undefined answer is `continuous == .never`. Both rules are
//! the invariants the constructors assert.
//!
//! A continuity answer has a LOWER proof and an UPPER proof, and this file
//! never mixes them. The lower proof keeps the argument's: an answer is
//! certainly continuous only when everything it was built from certainly was,
//! plus its own domain, plus (for a function with a cut) the absence of a
//! crossing. The upper proof is left OPEN, because a cut crossing, a pole, a
//! cancellation, or a collapse onto one dimension can each make a composition
//! continuous where its parts are not — `|z|` is 1-Lipschitz and both
//! coordinates are linear — and refusing to allow for that would be a claim
//! rather than a proof. So an answer over a box whose map is only partly
//! understood is `.maybe` about its own continuity, never `.always`, and a
//! branch piece inherits the SOURCE's proof rather than being promoted
//! because it was convenient to split it.
//!
//! # The arithmetic is outward f128 arithmetic, and the f64 answer is its projection
//!
//! Every elementary function here is built out of the certified kernels in
//! `certified.zig`, which evaluate in outward `f128`. A `Bounds` in this file
//! therefore never has a rounded endpoint chosen for tidiness: it carries the
//! `f128` roundoff of every operation that produced it, and the `f64` answer
//! is `Bounds.project`, the largest `f64` at or below the lower bound and the
//! smallest `f64` at or above the upper one.
//!
//! That projection is what makes a tight `f128` answer a correct `f64`
//! enclosure of an irrational: the true value sits strictly between two
//! consecutive `f64`s, so the projection spans the gap and the enclosure
//! contains it. Nothing here pads a result by a ULP budget to make that
//! happen; the outward rounding at each operation is what does it, and a
//! value that IS exactly representable comes back as a single point.
//!
//! # The convention: `Arg` in `(-pi, pi]`
//!
//! The principal logarithm is `ln|z| + i*Arg(z)` with `Arg` in the half-open
//! interval `(-pi, pi]`. A point exactly on the negative real axis therefore
//! has `Arg = +pi` and not `-pi`, and this is a convention about the sign of
//! an exact zero, not a measurement. Every other convention in this file
//! follows from it, and none of them is a special case bolted on afterwards:
//!
//!   * `sqrt` and every `nthRoot` are `exp(Log(z)/n)`, so the square root of
//!     the negative axis is `+i*sqrt(|z|)` and the principal cube root of `-8`
//!     is `1 + i*sqrt(3)` and not `-2`. `-2` is the value at root index 1.
//!   * `pow(z, w) = exp(w*Log z)` is the PRINCIPAL power: `(-8)^(3/1)` is `-8`
//!     and NOT the real cube root, because `Arg(-8) = pi` is inside the
//!     strip. `powRational` runs the principal logarithm through the rational
//!     exponent with no axis case anywhere.
//!   * `logSheet(z, k)` is `ln|z| + i*(Arg(z) + 2*pi*k)` for every integer
//!     `k`, computed with `k` exact: the sheet index is an `i64` and becomes
//!     an `f128` without loss, so `k` and `2k` are represented exactly before
//!     any rounding happens to them.
//!
//! # Cuts are not holes
//!
//! The complex `sqrt`, `asin`, `acos`, `asinh`, `acosh` and `atanh` are
//! TOTAL: they answer at every argument, and what they carry is a CUT, not a
//! missing domain. The exceptions are the actual holes, which are algebra,
//! not convention: `log` is undefined at `0`, `tan`, `csc`, `sec`, `cot`,
//! `tanh`, `csch`, `sech`, `coth` and every `1/z`-composed inverse are
//! undefined where their divisor vanishes, and `atan` is undefined at `+-i`
//! and `atanh` at `+-1` — those are exactly the points where the formula in
//! `certified.zig` has a `log` of zero in it.
//!
//! A box that straddles a cut is answered on BOTH sides at once, because the
//! image of the box is the union of the two images, and that union is not an
//! interval-analytic function of the argument. Those answers are marked
//! `continuous == .maybe`: the value is sound, the continuity claim is
//! refused, and the answer does not pretend the cut is not there. A box that
//! meets no cut is marked `.always`.
//!
//! # The composed boxes are answered as boxes
//!
//! Nothing here fakes a total domain to keep a composition clean. When the
//! intermediate box of a composition runs through a point the inner function
//! is not defined at — `atan` of a box that contains `i`, `asin` of a box that
//! contains `1` — the answer is still produced, as the image of the DEFINED
//! part of that box, and the metadata reports `.maybe`. Refusing the whole
//! answer would be a hole that the mathematics does not have; answering as
//! though nothing happened would be a claim about a point the caller never
//! gave. `.maybe` is the honest middle, and the numeric answer is the
//! enclosure of the defined part, which is the only part with a value.
//!
//! # Branch producers
//!
//! `principalLog`, `logSheets` and `roots` write `Writer(Complex)` views.
//! Every one of them SPLITS AN INPUT PIECE BY CUT SIDE FIRST and then
//! enumerates sheets or roots inside each side, because a sheet value is only
//! continuous on one side: the jump of `Arg` across the negative real axis is
//! `2*pi`, and `2*pi*k/n` is not a multiple of `2*pi` for any `k` in the
//! range. The side split is what makes each published piece continuous and
//! the answer tight.
//!
//! The side and the sheet are encoded in ONE `Choice` per piece, in `i128`,
//! with encodings that cannot collide:
//!
//!   * `principalLog`: `+1` above the axis, `0` on the exact axis, `-1`
//!     below. There is no sheet to carry here, so the side IS the label.
//!   * `logSheets`: `3*k + (side + 1)` with `side` in `{-1, 0, +1}`. The
//!     factor three is what keeps the three sides of one sheet away from the
//!     neighbouring sheets: `3k..3k+2` and `3(k+1)..3k+5` cannot meet.
//!   * `roots`: `degree*k + side_index` with `side_index` 0 below, 1 on the
//!     axis, 2 above. `degree >= 1` whenever there is a root at all.
//!
//! Incoming assignments are preserved by `appendBound`, which merges the
//! producer's own label into the caller's map in the writer's own pool and
//! publishes the piece in the same atomic step. Capacity exhaustion rolls the
//! writer back to its entry checkpoint, so a failure leaves no partial set.

const std = @import("std");
const Interval = @import("interval.zig").Interval;
const cert = @import("certified.zig");
const truth_mod = @import("truth.zig");
const tracked_mod = @import("tracked.zig");
const branches = @import("branches.zig");
const real_mod = @import("real.zig");

/// The outward f128 bound the certified kernels speak. Every real
/// computation in this file is done in these and projected once at the end.
const B = cert.Bounds;

/// Three-valued truth, over the possible Boolean outcomes of a claim.
const Truth = truth_mod.Truth;

/// The real-valued tracked scalar, which is what a complex answer collapses
/// to when only one of the two coordinates is asked for.
const Tracked = tracked_mod.Tracked;

/// The exact rational tag, `{ numerator: i64, denominator: u64 }`. It is
/// owned by `real.zig` and used here only as an EXACT exponent tag: a
/// `powRational` argument is never converted to a float before the branch
/// convention has been applied to it.
const Rational = real_mod.Rational;

/// The resource error of every branch producer. It is `branches.Error`,
/// named here so a caller can write the return type without importing the
/// container module.
pub const Error = branches.Error;

/// Positive infinity in the kernel arithmetic. An overflowing result is a
/// legitimate endpoint rather than a failure, and `project` carries it to the
/// matching `f64` infinity.
const inf128 = std.math.inf(f128);

/// The whole line, in the kernel arithmetic. Used where the exact image of a
/// box genuinely is unbounded — a box that straddles a tangent pole really
/// does take every value in both directions — and where a lower bound cannot
/// be proved, so no bound on the quotient is available.
const whole_line: B = B.init(-inf128, inf128);

// ---------------------------------------------------------------------------
// Bounds: the plane enclosure
// ---------------------------------------------------------------------------

/// A box in the plane: an enclosure of the real part and an enclosure of the
/// imaginary part, each `f64`.
pub const Bounds = struct {
    re: Interval,
    im: Interval,

    /// The box `[re.lo, re.hi] x [im.lo, im.hi]`.
    pub fn init(re: Interval, im: Interval) Bounds {
        return .{ .re = re, .im = im };
    }
};

// ---------------------------------------------------------------------------
// The internal working box
// ---------------------------------------------------------------------------

/// The same box in the kernel arithmetic, which is where it is computed.
///
/// A `Complex` carries `f64` endpoints because that is what the rest of the
/// package speaks; the mathematics is done here in `f128` and projected once.
/// Converting a `Bounds` into a `Box` is exact and always sound: widening an
/// `f64` endpoint to `f128` can only make the box larger, and a larger box
/// still contains every value it contained before.
const Box = struct {
    re: B,
    im: B,
};

/// Widen an `f64` interval into the kernel arithmetic. Exact: every `f64` is
/// an `f128`, infinities included.
fn widen(x: Interval) B {
    return B.fromInterval(x);
}

/// The `f64` enclosure of a kernel result, directed outward at both ends.
fn narrow(x: B) Interval {
    return B.project(x);
}


/// The internal box of a published `Bounds`.
fn boxOf(b: Bounds) Box {
    return .{ .re = widen(b.re), .im = widen(b.im) };
}

/// The published `Bounds` of an internal box.
fn boundsOf(b: Box) Bounds {
    return Bounds.init(narrow(b.re), narrow(b.im));
}

/// True when both ends are the same, which makes a kernel's point path exact
/// and makes the quantity a single mathematical value.
fn isPoint(x: B) bool {
    return x.lo == x.hi;
}

/// True when the quantity is exactly zero, which is a mathematical fact about
/// the argument rather than an estimate of it.
fn isZero(x: B) bool {
    return x.lo == 0.0 and x.hi == 0.0;
}

/// Clamp a lower end up to zero. Only ever applied where the EXACT quantity is
/// known to be non-negative (`|z| +- Re z` and the squared modulus), so the
/// clamp can only ever be sound; the upper end is already non-negative there
/// and is not touched.
fn clampNonNegative(x: B) B {
    std.debug.assert(!(x.lo < 0.0 and x.hi < 0.0));
    return B.init(if (x.lo > 0.0) x.lo else 0.0, x.hi);
}

/// Half of the certified pi, taken by dividing rather than by writing a
/// second constant down: halving is exact in binary floating point, so this
/// carries pi to the same relative accuracy pi itself is carried at.
const halfPi: B = B.div(cert.pi, B.point(2.0));

/// The kernel bounds of an integer, exactly. Every integer a `f128` can hold
/// with room to spare is one `f128` significand is exactly one `f128`, and
/// `i64` needs 64 of the 113 available, so this conversion loses nothing and
/// the multiplication by two below is exact too.
fn intB(k: i64) B {
    return B.point(@as(f128, @floatFromInt(k)));
}

// ---------------------------------------------------------------------------
// Metadata
// ---------------------------------------------------------------------------

/// The continuity of a unary answer, from the continuity of its argument.
///
/// Three things enter the LOWER proof: the argument is certainly continuous,
/// the answer is certainly defined, and the argument box meets no cut. Each
/// of the three is a separate way for the answer not to be provably
/// continuous, and dropping any one of them would let a composition claim a
/// proof its parts do not have — most visibly, a function that is entire on
/// the plane is still not continuous ACROSS its own branch cut.
///
/// The UPPER proof is `true` and is never inherited from the argument. A cut
/// crossing, a pole, a cancellation and a collapse onto a smaller dimension
/// can each make a composition continuous where its parts are not, so an
/// argument's uncertainty is never promoted into a certain discontinuity of
/// the answer.
fn unaryCt(in: Complex, defined: Truth, cuts: bool) Truth {
    return Truth.fromBounds(in.continuous.lower() and defined.lower() and !cuts, true);
}

/// The continuity of a REAL-VALUED COLLAPSE of a complex quantity: the
/// modulus, or one of the two coordinates.
///
/// The LOWER proof is the argument's own, because the collapse is a function
/// of that quantity and cannot be better behaved than whatever it is a
/// function of. The UPPER proof stays open, and that openness is the whole
/// point of treating these three differently from an ordinary composition:
/// `|z|` is 1-Lipschitz and both coordinates are linear, so a collapse can
/// well be continuous where the quantity it collapses is not, and refusing
/// to say so would be a claim rather than a proof.
fn collapseCt(self: Complex) Truth {
    return Truth.fromBounds(self.continuous.lower() and self.defined.lower(), true);
}

/// The continuity of a binary answer. Both arguments' lower proofs enter,
/// because both are functions of something and either one of them being
/// discontinuous leaves the answer no better proven than its worse input.
fn binaryCt(a: Complex, b: Complex, defined: Truth, cuts: bool) Truth {
    return Truth.fromBounds(
        a.continuous.lower() and b.continuous.lower() and defined.lower() and !cuts,
        true,
    );
}

/// The continuity of a BRANCH PIECE of an argument, which is the continuity
/// of the argument over the whole of its box and never of the piece alone.
///
/// A split does not make an answer better behaved: the piece is the image of
/// a SUBSET of the same box, and the function being split is the same
/// function. So the piece inherits the source's lower proof and adds only its
/// own domain, and the caller sees the cut by having received two pieces
/// rather than by being told each one is continuous.
fn pieceCt(source: Complex, defined: Truth) Truth {
    return Truth.fromBounds(source.continuous.lower() and defined.lower(), true);
}

/// The domain question `w` asks of itself: is `0` in the box?
///
///   * `.never` — the box IS the origin, so nothing in it has a value.
///   * `.maybe` — the origin is in the box but is not all of it.
///   * `.always` — the origin is not in the box.
fn originDomain(b: Box) Truth {
    if (isZero(b.re) and isZero(b.im)) return .never;
    if (b.re.lo <= 0.0 and b.re.hi >= 0.0 and b.im.lo <= 0.0 and b.im.hi >= 0.0) return .maybe;
    return .always;
}

/// Whether a box MEETS the negative real axis across it, which is what breaks
/// continuity of every principal branch in this file.
///
/// A box lying exactly ON the axis is not a crossing: the function restricted
/// to that segment is continuous there, and claiming otherwise would be
/// refusing a claim that is true. So the test is for a box with a negative
/// real part AND imaginary parts strictly on both sides of zero.
fn crossesNegAxis(x: B, y: B) bool {
    return x.lo < 0.0 and y.lo < 0.0 and y.hi > 0.0;
}

/// Whether a box crosses the real axis outside `[-1, 1]`, the cut of `asin`,
/// `acos` and `atanh`.
fn crossesRealOutsideUnit(x: B, y: B) bool {
    return y.lo < 0.0 and y.hi > 0.0 and (x.hi >= 1.0 or x.lo <= -1.0);
}

/// Whether a box crosses the imaginary axis outside `[-1, 1]`, the cut of
/// `atan` and `asinh`.
fn crossesImagOutsideUnit(x: B, y: B) bool {
    return x.lo < 0.0 and x.hi > 0.0 and (y.hi >= 1.0 or y.lo <= -1.0);
}

/// Whether a box crosses the ray `Re z <= 1`, the cut of `acosh`.
fn crossesAcLeftOfOne(x: B, y: B) bool {
    return y.lo < 0.0 and y.hi > 0.0 and x.lo <= 1.0;
}

// ---------------------------------------------------------------------------
// Complex
// ---------------------------------------------------------------------------

/// This file's own namespace, so a method can reach the free function of the
/// same name without repeating the whole definition. `@This()` at file scope
/// is the struct the file is, and a name inside it is reachable from it.
const complex = @This();

/// A complex enclosure with the domain and continuity metadata of the
/// function that produced it.
///
/// `range == null` if and only if `defined == .never`: an absent value
/// carries no interval, because a box around nothing is a claim about a
/// number that does not exist. Every constructor and every function in this
/// file keeps the two in step.
pub const Complex = struct {
    range: ?Bounds,
    defined: Truth,
    continuous: Truth,

    /// The box `[re] x [im]`, fully defined and continuous: a leaf value, not
    /// yet a function of anything.
    pub fn init(re: Interval, im: Interval) Complex {
        return .{
            .range = Bounds.init(re, im),
            .defined = .always,
            .continuous = .always,
        };
    }

    /// The point `re + im*i`.
    pub fn point(re: f64, im: f64) Complex {
        return .init(Interval.init(re, re), Interval.init(im, im));
    }

    /// No value at all. This is not a zero box and not an empty interval; it
    /// is the statement that there is nothing to enclose.
    pub fn undefined() Complex {
        return .{ .range = null, .defined = .never, .continuous = .never };
    }

    /// An answer with its metadata written down. The two invariants are
    /// preconditions and are asserted: a caller may not hand in a box for an
    /// absent value, and may not hand in `null` for a value that exists.
    ///
    /// A wholly undefined answer is forced to `continuous == .never` whatever
    /// the caller wrote, because there is no function there to be continuous.
    pub fn withMetadata(range: ?Bounds, defined: Truth, continuous: Truth) Complex {
        switch (defined) {
            .never => {
                std.debug.assert(range == null);
                return .undefined();
            },
            .maybe, .always => {
                std.debug.assert(range != null);
                return .{ .range = range, .defined = defined, .continuous = continuous };
            },
        }
    }

    /// The internal box, or the absent answer.
    fn box(self: Complex) ?Box {
        const r = self.range orelse return null;
        return boxOf(r);
    }

    // -- algebra ------------------------------------------------------------

    /// `self + other`. Addition is total and smooth, so there is no domain
    /// and no cut to report.
    pub fn add(self: Complex, other: Complex) Complex {
        const a = self.box() orelse return .undefined();
        const b = other.box() orelse return .undefined();
        return make(.{
            .re = a.re.add(b.re),
            .im = a.im.add(b.im),
        }, self.defined.both(other.defined), binaryCt(self, other, self.defined.both(other.defined), false));
    }

    /// `self - other`.
    pub fn sub(self: Complex, other: Complex) Complex {
        const a = self.box() orelse return .undefined();
        const b = other.box() orelse return .undefined();
        return make(.{
            .re = a.re.sub(b.re),
            .im = a.im.sub(b.im),
        }, self.defined.both(other.defined), binaryCt(self, other, self.defined.both(other.defined), false));
    }

    /// `self * other`, as TRUE complex multiplication:
    /// `(a + bi)(c + di) = (ac - bd) + (ad + bc)i`. The imaginary unit squares
    /// to `-1 + 0i` because that is what this formula computes; `Vec(2)`
    /// componentwise multiplication stays a different operation with a
    /// different answer.
    pub fn mul(self: Complex, other: Complex) Complex {
        const a = self.box() orelse return .undefined();
        const b = other.box() orelse return .undefined();
        return make(.{
            .re = a.re.mul(b.re).sub(a.im.mul(b.im)),
            .im = a.re.mul(b.im).add(a.im.mul(b.re)),
        }, self.defined.both(other.defined), binaryCt(self, other, self.defined.both(other.defined), false));
    }

    /// `self / other`, as `(a + bi)(c - di) / (c^2 + d^2)`.
    ///
    /// The divisor is the only thing here with a domain, and it is the only
    /// thing that can have one: the quotient is undefined exactly where the
    /// divisor is zero, which is what `divide` decides.
    pub fn div(self: Complex, other: Complex) Complex {
        const a = self.box() orelse return .undefined();
        const b = other.box() orelse return .undefined();
        const q = divide(a, b);
        const defined = self.defined.both(other.defined).both(q.defined);
        return make(q.value, defined, binaryCt(self, other, defined, false));
    }

    /// `-self`, exactly: negation reverses both coordinates and is exact in
    /// binary floating point.
    pub fn neg(self: Complex) Complex {
        const a = self.box() orelse return .undefined();
        return make(.{
            .re = a.re.neg(),
            .im = a.im.neg(),
        }, self.defined, unaryCt(self, self.defined, false));
    }

    /// `conj(self)`, exactly.
    pub fn conjugate(self: Complex) Complex {
        const a = self.box() orelse return .undefined();
        return make(.{ .re = a.re, .im = a.im.neg() }, self.defined, unaryCt(self, self.defined, false));
    }

    // -- the real-valued collapses -----------------------------------------

    /// `|self|`, the modulus.
    ///
    /// The modulus is 1-Lipschitz, which is why its continuity is decided by
    /// `collapseCt` rather than by the ordinary composition rule: the lower
    /// proof is the argument's, because the modulus is a function of that
    /// argument, and the upper proof stays open, because a non-injective
    /// collapse CAN be continuous where the quantity it collapses is not. The
    /// two facts are both real and the metadata is where they meet.
    pub fn abs(self: Complex) Tracked {
        const a = self.box() orelse return Tracked.undefined();
        return trackedOf(narrow(modulusOf(a)), self.defined, collapseCt(self));
    }

    /// The real part: a coordinate projection, continuous wherever it exists.
    pub fn real(self: Complex) Tracked {
        const a = self.box() orelse return Tracked.undefined();
        return trackedOf(narrow(a.re), self.defined, collapseCt(self));
    }

    /// The imaginary part.
    pub fn imaginary(self: Complex) Tracked {
        const a = self.box() orelse return Tracked.undefined();
        return trackedOf(narrow(a.im), self.defined, collapseCt(self));
    }

    // -- relations ----------------------------------------------------------

    /// Whether `self` and `other` are the same complex VALUE.
    ///
    /// This is the scalar relation on complex numbers and not the structural
    /// one on boxes: two structurally equal boxes are NOT two equal numbers,
    /// so the numeric part answers `.maybe` for them and only a pair of
    /// identical single values answers `.always`.
    ///
    /// The numeric relation is then INTERSECTED with the domain. That
    /// intersection is what stops a partly defined argument from proving
    /// anything: a box that is `.maybe` about its own value cannot prove it
    /// equal to anything, and the intersection says so rather than letting
    /// the coordinates speak for a value the metadata has not established.
    ///
    /// An absent operand answers `.never`, and so does `ne`: there is no value
    /// there for either claim to be about, so both are false rather than one
    /// of them being unknown.
    pub fn eq(self: Complex, other: Complex) Truth {
        return self.defined.both(other.defined).both(numericEq(self, other));
    }

    /// Whether `self` and `other` are different complex values.
    ///
    /// Over two defined operands this is the NEGATION of `eq`, which is the
    /// one relation the two share. Over an operand that is not defined it is
    /// `.never` rather than the negation of that, because `.never` means
    /// "certainly false" and its logical complement is "certainly true":
    /// negating a comparison about a value that is not there would turn "they
    /// are not the same" into a claim that they ARE different, which is a
    /// claim about nothing.
    pub fn ne(self: Complex, other: Complex) Truth {
        return self.defined.both(other.defined).both(numericEq(self, other).negate());
    }

    // -- the elementary functions ------------------------------------------

    /// `exp(self) = exp(Re z)*(cos(Im z) + i*sin(Im z))`. Entire, so it is
    /// defined and continuous wherever its argument is.
    pub fn exp(self: Complex) Complex {
        const a = self.box() orelse return .undefined();
        return make(expBox(a), self.defined, unaryCt(self, self.defined, false));
    }

    /// The principal logarithm, `Log(self) = ln|self| + i*Arg(self)` with
    /// `Arg` in `(-pi, pi]`.
    pub fn log(self: Complex) Complex {
        return complex.log(self);
    }

    /// Sheet `k` of the logarithm, `ln|self| + i*(Arg(self) + 2*pi*k)`.
    pub fn logSheet(self: Complex, k: i64) Complex {
        return complex.logSheet(self, k);
    }

    /// The FULL logarithm family of `self`: infinitely many sheets.
    pub fn logFamily(self: Complex) LogFamily {
        return .{ .z = self };
    }

    /// The principal square root.
    pub fn sqrt(self: Complex) Complex {
        return complex.sqrt(self);
    }

    /// The principal `degree`-th root, which is root index 0.
    pub fn nthRoot(self: Complex, degree: u32) Complex {
        return complex.root(self, degree, 0);
    }

    /// Root `k` of `degree` roots of `self`, for every integer `k`. Root
    /// index 0 is the principal one; index 1 is the next one around.
    pub fn root(self: Complex, degree: u32, k: i64) Complex {
        return complex.root(self, degree, k);
    }

    /// The FULL root family of `self`: exactly `degree` roots.
    pub fn rootFamily(self: Complex, degree: u32) RootFamily {
        return .{ .z = self, .degree = degree };
    }

    /// The principal power, `exp(w*Log(self))`.
    pub fn pow(self: Complex, w: Complex) Complex {
        return complex.pow(self, w);
    }

    /// The principal rational power, `exp(p*Log(self))` for an EXACT `p`.
    pub fn powRational(self: Complex, p: Rational) Complex {
        return complex.powRational(self, p);
    }

    /// `sin(self) = sin(Re z)*cosh(Im z) + i*cos(Re z)*sinh(Im z)`.
    pub fn sin(self: Complex) Complex {
        return complex.sin(self);
    }

    /// `cos(self) = cos(Re z)*cosh(Im z) - i*sin(Re z)*sinh(Im z)`.
    pub fn cos(self: Complex) Complex {
        return complex.cos(self);
    }

    /// `tan(self) = sin(self)/cos(self)`, absent at the zeros of `cos`.
    pub fn tan(self: Complex) Complex {
        return complex.tan(self);
    }

    /// `csc(self) = 1/sin(self)`.
    pub fn csc(self: Complex) Complex {
        return complex.csc(self);
    }

    /// `sec(self) = 1/cos(self)`.
    pub fn sec(self: Complex) Complex {
        return complex.sec(self);
    }

    /// `cot(self) = cos(self)/sin(self)`.
    pub fn cot(self: Complex) Complex {
        return complex.cot(self);
    }

    /// `asin(self) = -i*Log(i*self + sqrt(1 - self^2))`, with its cut along
    /// `(-inf, -1] + [1, inf)`. Total: the cut is a cut and not a hole.
    pub fn asin(self: Complex) Complex {
        return complex.asin(self);
    }

    /// `acos(self) = pi/2 - asin(self)`, with the same cut.
    pub fn acos(self: Complex) Complex {
        return complex.acos(self);
    }

    /// `atan(self) = (i/2)*(Log(1 - i*self) - Log(1 + i*self))`, with its cut
    /// along the imaginary axis outside `[-i, i]` and a real hole at `+-i`.
    pub fn atan(self: Complex) Complex {
        return complex.atan(self);
    }

    /// `acsc(self) = asin(1/self)`, with a hole at `0`.
    pub fn acsc(self: Complex) Complex {
        return complex.acsc(self);
    }

    /// `asec(self) = acos(1/self)`, with a hole at `0`.
    pub fn asec(self: Complex) Complex {
        return complex.asec(self);
    }

    /// `acot(self) = atan(1/self)`, with `acot(0) = pi/2` on the principal
    /// circular branch.
    pub fn acot(self: Complex) Complex {
        return complex.acot(self);
    }

    /// `sinh(self) = sinh(Re z)*cos(Im z) + i*cosh(Re z)*sin(Im z)`.
    pub fn sinh(self: Complex) Complex {
        return complex.sinh(self);
    }

    /// `cosh(self) = cosh(Re z)*cos(Im z) + i*sinh(Re z)*sin(Im z)`.
    pub fn cosh(self: Complex) Complex {
        return complex.cosh(self);
    }

    /// `tanh(self) = sinh(self)/cosh(self)`, absent at the zeros of `cosh`,
    /// which are the purely imaginary points `pi*i/2 + k*pi*i`.
    pub fn tanh(self: Complex) Complex {
        return complex.tanh(self);
    }

    /// `csch(self) = 1/sinh(self)`, with a hole at `0`.
    pub fn csch(self: Complex) Complex {
        return complex.csch(self);
    }

    /// `sech(self) = 1/cosh(self)`, with holes at the zeros of `cosh`.
    pub fn sech(self: Complex) Complex {
        return complex.sech(self);
    }

    /// `coth(self) = cosh(self)/sinh(self)`, with a hole at `0`.
    pub fn coth(self: Complex) Complex {
        return complex.coth(self);
    }

    /// `asinh(self) = Log(self + sqrt(self^2 + 1))`, with its cut along the
    /// imaginary axis outside `[-i, i]`. Total.
    pub fn asinh(self: Complex) Complex {
        return complex.asinh(self);
    }

    /// `acosh(self) = Log(self + sqrt(self - 1)*sqrt(self + 1))`, with its
    /// cut along `(-inf, 1]`. Total: it answers at every argument, the ones
    /// on the cut included.
    pub fn acosh(self: Complex) Complex {
        return complex.acosh(self);
    }

    /// `atanh(self) = (Log(1 + self) - Log(1 - self))/2`, with real holes at
    /// `+-1` and its cut along `(-inf, -1] + [1, inf)`.
    pub fn atanh(self: Complex) Complex {
        return complex.atanh(self);
    }

    /// `acsch(self) = asinh(1/self)`, with a hole at `0`.
    pub fn acsch(self: Complex) Complex {
        return complex.acsch(self);
    }

    /// `asech(self) = acosh(1/self)`, with a hole at `0`.
    pub fn asech(self: Complex) Complex {
        return complex.asech(self);
    }

    /// `acoth(self) = atanh(1/self)`, with a hole at `0` and the holes of
    /// `atanh` at `+-1`.
    pub fn acoth(self: Complex) Complex {
        return complex.acoth(self);
    }
};

/// Build an answer from an internal box, its domain and its continuity.
///
/// The continuity is always computed by `unaryCt`, `binaryCt` or `pieceCt`,
/// never decided here: a call site that has not worked out what it can prove
/// is a call site that would have claimed `.always` for free.
fn make(b: Box, defined: Truth, continuous: Truth) Complex {
    if (defined == .never) return .undefined();
    return Complex.withMetadata(boundsOf(b), defined, continuous);
}

/// Build a `Tracked` from a real interval, keeping the range/defined
/// invariant.
fn trackedOf(range: Interval, defined: Truth, continuous: Truth) Tracked {
    if (defined == .never) return Tracked.undefined();
    return Tracked.withMetadata(range, defined, continuous);
}

/// The NUMERIC half of the complex equality relation, with the domain left
/// out: `.always` only when both coordinates are the same single value,
/// `.never` when the two cannot be equal, `.maybe` in between — which is the
/// case for two structurally equal intervals, because an interval is a set of
/// values rather than one of them.
fn numericEq(self: Complex, other: Complex) Truth {
    if (self.range == null or other.range == null) return .never;
    const a = self.range.?;
    const b = other.range.?;
    return sameInterval(a.re, b.re).both(sameInterval(a.im, b.im));
}

/// The scalar relation between two real intervals: `.always` only when both
/// are the same single value, `.never` when they cannot be equal, and
/// `.maybe` in between — which is the case for two structurally equal
/// intervals, because an interval is a set of values rather than one of them.
fn sameInterval(x: Interval, y: Interval) Truth {
    const xs = x.lo == x.hi;
    const ys = y.lo == y.hi;
    if (xs and ys and x.lo == y.lo) return .always;
    if (!x.overlaps(y)) return .never;
    return .maybe;
}

/// `|z|` in the kernel arithmetic: `sqrt(re^2 + im^2)`. The squared modulus
/// is clamped at zero because the exact quantity is non-negative and the
/// interval product of a box straddling the origin would otherwise have a
/// negative lower end.
fn modulusOf(z: Box) B {
    const sq = z.re.sqr().add(z.im.sqr());
    return kSqrt(clampNonNegative(sq));
}

/// The quotient `a / b` with its domain.
const Quotient = struct { value: Box, defined: Truth };

/// `a / b` by the conjugate rule.
///
/// The domain question is the whole of it: the quotient is undefined exactly
/// where `b` is zero, and the enclosure of `|b|^2` answers that. When the
/// lower end of `|b|^2` is positive the division is done properly and
/// tightly. Otherwise the true image is unbounded — a box that reaches the
/// origin contains arguments of arbitrarily small modulus, so the quotient
/// has no finite bound at all — and the honest answer is the whole plane,
/// marked `.maybe` when the box merely reaches zero and `.never` when the box
/// IS zero.
fn divide(a: Box, b: Box) Quotient {
    const d = b.re.sqr().add(b.im.sqr());
    if (d.lo > 0.0) {
        const re = a.re.mul(b.re).add(a.im.mul(b.im)).div(d);
        const im = a.im.mul(b.re).sub(a.re.mul(b.im)).div(d);
        return .{ .value = .{ .re = re, .im = im }, .defined = .always };
    }
    if (d.hi == 0.0) return .{ .value = .{ .re = whole_line, .im = whole_line }, .defined = .never };
    return .{ .value = .{ .re = whole_line, .im = whole_line }, .defined = .maybe };
}

// ---------------------------------------------------------------------------
// Real kernels
// ---------------------------------------------------------------------------
//
// Every one of these is a certified `f128` kernel, possibly with an exact
// case for an argument that is exactly a point at which the answer is known
// in closed form. Those cases are not padding and not a ULP budget: `sin(0)`,
// `cos(0)`, `exp(0)`, `log(1)`, `sqrt(0)` are exact identities, and writing
// them down is what lets a witness like `asin(1) = pi/2` come back as a
// difference of two identical enclosures rather than as a widening of two.

fn kExp(x: B) B {
    return if (isZero(x)) B.point(1.0) else cert.exp(x);
}

fn kLog(x: B) B {
    return if (isPoint(x) and x.lo == 1.0) B.point(0.0) else cert.log(x);
}

fn kSqrt(x: B) B {
    return if (isZero(x)) B.point(0.0) else cert.sqrt(x);
}

fn kSin(x: B) B {
    return if (isZero(x)) B.point(0.0) else cert.sin(x);
}

fn kCos(x: B) B {
    return if (isZero(x)) B.point(1.0) else cert.cos(x);
}

fn kSinh(x: B) B {
    return if (isZero(x)) B.point(0.0) else cert.sinh(x);
}

fn kCosh(x: B) B {
    return if (isZero(x)) B.point(1.0) else cert.cosh(x);
}

fn kAtan(x: B) B {
    return if (isZero(x)) B.point(0.0) else cert.atan(x);
}

/// The box `1 + 0i`.
fn oneBox() Box {
    return .{ .re = B.point(1.0), .im = B.point(0.0) };
}

/// The box `0 + 0i`.
fn zeroBox() Box {
    return .{ .re = B.point(0.0), .im = B.point(0.0) };
}

/// Complex multiplication of two boxes, the same formula `Complex.mul` uses.
fn mulBox(a: Box, b: Box) Box {
    return .{
        .re = a.re.mul(b.re).sub(a.im.mul(b.im)),
        .im = a.re.mul(b.im).add(a.im.mul(b.re)),
    };
}

/// `exp(z)` for a box, with no domain question: `exp` is entire.
fn expBox(z: Box) Box {
    const e = kExp(z.re);
    return .{ .re = e.mul(kCos(z.im)), .im = e.mul(kSin(z.im)) };
}

// ---------------------------------------------------------------------------
// The argument
// ---------------------------------------------------------------------------

/// An accumulator for a hull built out of up to eight pieces.
const Hull = struct {
    lo: f128 = inf128,
    hi: f128 = -inf128,

    fn add(self: *Hull, x: B) void {
        self.lo = @min(self.lo, x.lo);
        self.hi = @max(self.hi, x.hi);
    }
};

/// `Arg(z)` over a whole box, in `(-pi, pi]`.
///
/// The image is built as the hull of the eight regions the plane splits into
/// relative to the box: four open quadrants and the four half axes. Within
/// each quadrant the argument is `+-atan(|Im|/|Re|)` plus a fixed quarter
/// turn, and `atan` is monotone, so the enclosure of the ratio gives the
/// enclosure of the angle. A region the box only touches at the origin is
/// skipped, and a box that reaches the origin is answered with the widest
/// answer available for that case rather than with a guess.
///
/// Every ratio here divides by a bound whose lower end is strictly positive
/// OR is replaced by the whole quadrant, so no division by an interval
/// containing zero is ever attempted.
fn argOf(z: Box) B {
    const x = z.re;
    const y = z.im;
    var h = Hull{};

    // Quadrant I: Re > 0, Im > 0. Arg = atan(Im/Re), both positive.
    if (x.hi > 0.0 and y.hi > 0.0) {
        const xp = B.init(if (x.lo > 0.0) x.lo else 0.0, x.hi);
        const yp = B.init(if (y.lo > 0.0) y.lo else 0.0, y.hi);
        h.add(if (xp.lo > 0.0) kAtan(yp.div(xp)) else B.init(0.0, halfPi.hi));
    }
    // Quadrant II: Re < 0, Im > 0. Arg = pi - atan(Im/|Re|).
    if (x.lo < 0.0 and y.hi > 0.0) {
        const ax = negLeftPart(x);
        const yp = B.init(if (y.lo > 0.0) y.lo else 0.0, y.hi);
        h.add(cert.pi.sub(atanOfRatio(yp, ax)));
    }
    // Quadrant III: Re < 0, Im < 0. Arg = -pi + atan(|Im|/|Re|).
    if (x.lo < 0.0 and y.lo < 0.0) {
        const ax = negLeftPart(x);
        const yn = B.init(y.lo, if (y.hi < 0.0) y.hi else 0.0).neg();
        h.add(cert.pi.neg().add(atanOfRatio(yn, ax)));
    }
    // Quadrant IV: Re > 0, Im < 0. Arg = atan(Im/Re) with a negative ratio.
    if (x.hi > 0.0 and y.lo < 0.0) {
        const xp = B.init(if (x.lo > 0.0) x.lo else 0.0, x.hi);
        const yn = B.init(y.lo, if (y.hi < 0.0) y.hi else 0.0);
        h.add(if (xp.lo > 0.0) kAtan(yn.div(xp)) else B.init(-halfPi.hi, 0.0));
    }

    // The four half axes. `Re` contains zero and `Im` is positive, and so on.
    const xHasZero = x.lo <= 0.0 and x.hi >= 0.0;
    const yHasZero = y.lo <= 0.0 and y.hi >= 0.0;
    if (yHasZero and x.hi > 0.0) h.add(B.point(0.0));
    if (yHasZero and x.lo < 0.0) h.add(cert.pi);
    if (xHasZero and y.hi > 0.0) h.add(halfPi);
    if (xHasZero and y.lo < 0.0) h.add(cert.pi.neg());

    if (h.lo > h.hi) {
        // Nothing but the origin: no argument has a value. The caller is
        // required to have refused that already, so this is the widest sound
        // answer available rather than a claim about one.
        return cert.pi.mul(B.point(2.0));
    }
    return B.init(h.lo, h.hi);
}

/// `|Re z|` over the part of a box with a non-positive real part, which is
/// `[max(Re), -min(Re)]` for `Re <= 0` and is strictly positive at its upper
/// end.
fn negLeftPart(x: B) B {
    const hi = if (x.hi < 0.0) x.hi else 0.0;
    return B.init(-hi, -x.lo);
}

/// `atan(num/den)` for a non-negative `num` and a non-negative `den`, where
/// a `den` that reaches zero means the ratio is unbounded and the answer is
/// the whole quarter.
fn atanOfRatio(num: B, den: B) B {
    if (den.lo <= 0.0) return B.init(0.0, halfPi.hi);
    return kAtan(num.div(den));
}

/// The principal logarithm VALUE, with no domain question attached.
///
/// This is what every composed inverse in this file uses. The interior
/// argument of a composition can enclose zero as an artifact of interval
/// arithmetic even where the exact argument never is zero, and the exact
/// value is then finite everywhere; clamping the modulus at zero and taking
/// the hull of the eight regions keeps that case sound instead of inventing a
/// hole in a function that has none.
fn logValue(z: Box) Box {
    const sq = clampNonNegative(z.re.sqr().add(z.im.sqr()));
    const ln = if (sq.lo > 0.0) kLog(sq).mul(B.point(0.5)) else B.init(-inf128, kLog(B.point(sq.hi)).hi);
    return .{ .re = ln, .im = argOf(z) };
}

/// `x^(1/degree)` over a non-negative box.
fn nthRootReal(x: B, degree: u32) B {
    if (degree == 1) return x;
    if (isZero(x)) return B.point(0.0);
    const n = B.point(@as(f128, @floatFromInt(degree)));
    // A box that reaches zero has a root that reaches zero, and the logarithm
    // of zero is `-inf`, which `exp` sends back to zero.
    const lo = if (x.lo > 0.0) x.lo else 0.0;
    return clampNonNegative(kExp(kLog(B.init(lo, x.hi)).div(n)));
}

/// Reduce a root index into `[0, degree)` by flooring, so that indices a
/// caller does not reduce by hand still give one of the `degree` roots.
///
/// The division is exact in `i64` and the product is bounded by `|k|`, so
/// neither can overflow.
fn reduceIndex(k: i64, degree: u32) i64 {
    const d: i64 = @intCast(degree);
    if (k >= 0 and k < d) return k;
    return k - @divFloor(k, d) * d;
}

/// An outward `f128` enclosure of the exact rational `num/den`.
///
/// Both integers convert to `f128` exactly (`i64` needs 64 of the 113
/// significand bits and `u64` the same), so the only rounding is the one in
/// the division. A correctly rounded `f128` division carries a relative
/// error below `2^-113`, and `2^-113` of `|q|` is four times that margin
/// below `4*|q|*2^-113`, which is the enclosure used here. `|num/den|` for an
/// `i64` over a `u64` lies in `[2^-64, 2^63]`, well inside the normal range,
/// so the relative bound is the operative one and no subnormal case can
/// reach it.
fn rationalBounds(num: i64, den: u64) B {
    std.debug.assert(den != 0);
    const n = @as(f128, @floatFromInt(num));
    const d = @as(f128, @floatFromInt(den));
    const q = n / d;
    if (q == 0.0) return B.point(0.0);
    const eps = @abs(q) * 0x1p-111; // 4 * 2^-113
    return B.init(q - eps, q + eps);
}

// ---------------------------------------------------------------------------
// exp, log, roots and powers
// ---------------------------------------------------------------------------

/// `exp(z)`. Entire: defined and continuous wherever its argument is.
pub fn exp(z: Complex) Complex {
    const a = z.box() orelse return .undefined();
    return make(expBox(a), z.defined, unaryCt(z, z.defined, false));
}

/// The principal logarithm. `log(0)` is absent, a box reaching zero is
/// `.maybe`, and the argument uses `Arg` in `(-pi, pi]`, so the exact
/// negative real axis is `+pi`.
pub fn log(z: Complex) Complex {
    return logSheet(z, 0);
}

/// Sheet `k` of the logarithm, for every integer `k`.
///
/// The sheet index is converted to `f128` exactly and doubled exactly before
/// it meets `pi`, so no part of `k` is lost to a float rounding and no part
/// of the answer is invented. The jump of `Arg` across the cut is the same
/// `2*pi` on every sheet, so every sheet carries the same cut and the same
/// continuity answer as the principal one.
pub fn logSheet(z: Complex, k: i64) Complex {
    const a = z.box() orelse return .undefined();
    const defined = z.defined.both(originDomain(a));
    if (defined == .never) return .undefined();
    const l = logValue(a);
    const two_pi_k = cert.pi.mul(twoTimesInt(k));
    const value = Box{ .re = l.re, .im = l.im.add(two_pi_k) };
    return make(value, defined, unaryCt(z, defined, crossesNegAxis(a.re, a.im)));
}

/// `2k` as an exact `f128`, for the sheet index. Doubling is exact in binary
/// floating point and `i64` is well inside the `f128` significand, so this
/// is the integer itself.
fn twoTimesInt(k: i64) B {
    return intB(k).mul(B.point(2.0));
}

/// The principal square root of a box, as a VALUE with no domain and no
/// continuity of its own.
///
/// The algebraic form rather than `exp(Log(z)/2)` because it is exact where
/// the exponential form is not: at `z = -1` it gives `0 + 1i` as two exact
/// points, while `exp(i*pi/2)` would hand back a real part of a few rounding
/// errors around zero. Both halves are clamped at zero because `|z| +- Re z`
/// is non-negative exactly, for every `z`.
fn sqrtValue(a: Box) Box {
    const m = modulusOf(a);
    const u = kSqrt(clampNonNegative(m.add(a.re)).mul(B.point(0.5)));
    const s = kSqrt(clampNonNegative(m.sub(a.re)).mul(B.point(0.5)));
    // The imaginary half takes the sign of `Im z`. An imaginary part strictly
    // on both sides of zero means the image covers both signs; an imaginary
    // part of exactly zero means `Im z = +0` pointwise, and the principal
    // branch puts the square root of the negative axis on the UPPER side.
    const v = if (a.im.lo < 0.0 and a.im.hi > 0.0)
        B.init(-s.hi, s.hi)
    else if (a.im.hi < 0.0)
        s.neg()
    else
        s;
    return Box{ .re = u, .im = v };
}

/// The principal square root, on the principal branch with its cut along the
/// negative real axis. TOTAL: it answers at every argument, the cut included.
pub fn sqrt(z: Complex) Complex {
    const a = z.box() orelse return .undefined();
    return make(sqrtValue(a), z.defined, unaryCt(z, z.defined, crossesNegAxis(a.re, a.im)));
}

/// The principal `degree`-th root: root index 0. The degree comes FIRST,
/// after `nthRoot`, because the degree is the parameter and the value is the
/// argument.
pub fn nthRoot(degree: u32, z: Complex) Complex {
    return root(z, degree, 0);
}

/// Root `k` of the `degree` roots of `z`.
///
/// `0` has exactly one `degree`-th root for every positive degree, and it is
/// `0`; there is no argument to take a logarithm of and none is needed.
/// `degree = 0` has no answer at all and is absent.
pub fn root(z: Complex, degree: u32, k: i64) Complex {
    const a = z.box() orelse return .undefined();
    if (degree == 0) return .undefined();
    if (isZero(a.re) and isZero(a.im)) {
        return make(zeroBox(), z.defined, unaryCt(z, z.defined, false));
    }
    const defined = z.defined.both(originDomain(a));
    return make(rootBox(a, degree, k), defined, unaryCt(z, defined, crossesNegAxis(a.re, a.im)));
}

/// Root `k` of the `degree` roots of a box, as a VALUE.
///
/// Every root is `|z|^(1/degree) * exp(i*(Arg(z) + 2*pi*k)/degree)`, which is
/// the principal logarithm run through the root: there is no case here for a
/// negative real argument, and that is the point. `(-8)^(1/3)` is
/// `1 + i*sqrt(3)` because `Arg(-8) = pi` and `pi/3` is the principal angle;
/// the real root `-2` is root index 1, and this function produces it when
/// asked for index 1 rather than quietly swapping the two.
fn rootBox(a: Box, degree: u32, k: i64) Box {
    const index = reduceIndex(k, degree);
    const radius = nthRootReal(modulusOf(a), degree);
    const angle = argOf(a)
        .add(cert.pi.mul(twoTimesInt(index)))
        .div(B.point(@as(f128, @floatFromInt(degree))));
    return Box{ .re = radius.mul(kCos(angle)), .im = radius.mul(kSin(angle)) };
}

/// The principal power `z^w = exp(w*Log z)`.
///
/// Three boundary cases are mathematics rather than convention, and all
/// three are stated here rather than left to a formula:
///
///   * `w` exactly `0` is `1`, for every `z` that exists. `0^0 = 1` is a
///     VALUE, and not the place where a product of two absent factors would
///     have gone: an absent operand still poisons the answer, so a `z` with
///     no value raises `0^0` with it.
///   * `z` exactly `0` with `Re w > 0` is `0`, imaginary exponents included.
///     `|w*Log z|` runs off to infinity faster than its real part does as
///     `z` runs to `0`, so the extension is `0` across the whole open half
///     plane and `1 + i` is in it.
///   * `z` exactly `0` with `Re w <= 0` has no value. `0^i` is the boundary
///     case: `Re i = 0`, so `|i*Log z|` stays out at infinity while the real
///     part does not run off, and there is no limit to report.
pub fn pow(z: Complex, w: Complex) Complex {
    const a = z.box() orelse return .undefined();
    const b = w.box() orelse return .undefined();
    const defined = z.defined.both(w.defined);

    if (isZero(b.re) and isZero(b.im)) return make(oneBox(), defined, binaryCt(z, w, defined, false));

    if (isZero(a.re) and isZero(a.im)) {
        if (b.re.lo > 0.0) return make(zeroBox(), defined, binaryCt(z, w, defined, false));
        if (b.re.hi <= 0.0) return make(zeroBox(), defined.both(.never), binaryCt(z, w, defined.both(.never), false));
        return make(zeroBox(), defined.both(.maybe), binaryCt(z, w, defined.both(.maybe), false));
    }

    const domain = defined.both(originDomain(a));
    if (domain == .never) return .undefined();
    return make(expBox(mulBox(b, logValue(a))), domain, binaryCt(z, w, domain, crossesNegAxis(a.re, a.im)));
}

/// The principal rational power `z^p = exp(p*Log z)` for an exact rational
/// `p`.
///
/// The principal convention runs all the way through with no case on the
/// negative axis: `(-8)^(3/1) = exp(3*(ln 8 + i*pi)) = -8`, which is NOT the
/// real cube root of `-8`, and `(-8)^(1/3) = 1 + i*sqrt(3)`, which is not
/// `-2`. Both of those are the convention stated at the top of this file, and
/// a caller who wants the real root asks `root(-8, 3, 1)`.
///
/// `p = 0` is `1` and `z = 0` is `0` for a positive `p`, the same boundary
/// rules as `pow`. A negative `p` at `0` is the unbounded case and has no
/// finite value.
pub fn powRational(z: Complex, p: Rational) Complex {
    const a = z.box() orelse return .undefined();
    if (p.numerator == 0) return make(oneBox(), z.defined, unaryCt(z, z.defined, false));
    if (isZero(a.re) and isZero(a.im)) {
        if (p.numerator > 0) return make(zeroBox(), z.defined, unaryCt(z, z.defined, false));
        return make(zeroBox(), z.defined.both(.never), unaryCt(z, z.defined.both(.never), false));
    }
    const domain = z.defined.both(originDomain(a));
    if (domain == .never) return .undefined();
    const exponent = rationalBounds(p.numerator, p.denominator);
    return make(expBox(mulBox(logValue(a), exponent)), domain, unaryCt(z, domain, crossesNegAxis(a.re, a.im)));
}

// ---------------------------------------------------------------------------
// Circular trigonometry
// ---------------------------------------------------------------------------

/// `sin(x + iy) = sin x*cosh y + i*cos x*sinh y`.
fn sinBox(z: Box) Box {
    return .{ .re = kSin(z.re).mul(kCosh(z.im)), .im = kCos(z.re).mul(kSinh(z.im)) };
}

/// `cos(x + iy) = cos x*cosh y - i*sin x*sinh y`.
fn cosBox(z: Box) Box {
    return .{ .re = kCos(z.re).mul(kCosh(z.im)), .im = kSin(z.re).mul(kSinh(z.im)).neg() };
}

/// `sinh(x + iy) = sinh x*cos y + i*cosh x*sin y`.
fn sinhBox(z: Box) Box {
    return .{ .re = kSinh(z.re).mul(kCos(z.im)), .im = kCosh(z.re).mul(kSin(z.im)) };
}

/// `cosh(x + iy) = cosh x*cos y + i*sinh x*sin y`.
fn coshBox(z: Box) Box {
    return .{ .re = kCosh(z.re).mul(kCos(z.im)), .im = kSinh(z.re).mul(kSin(z.im)) };
}

/// The box `z^2`.
fn squareOf(z: Box) Box {
    return mulBox(z, z);
}

/// `z` multiplied by one, rotated: `i*z`.
fn timesI(z: Box) Box {
    return .{ .re = z.im.neg(), .im = z.re };
}

/// `sin(z)`. Entire, and therefore defined and continuous wherever its
/// argument is. There is no cut: the complex sine is one analytic function on
/// the whole plane, unlike the real one on the interval.
pub fn sin(z: Complex) Complex {
    const a = z.box() orelse return .undefined();
    return make(sinBox(a), z.defined, unaryCt(z, z.defined, false));
}

/// `cos(z)`. Entire.
pub fn cos(z: Complex) Complex {
    const a = z.box() orelse return .undefined();
    return make(cosBox(a), z.defined, unaryCt(z, z.defined, false));
}

/// `tan(z) = sin(z)/cos(z)`, absent at the zeros of `cos`, which are the
/// real points `pi/2 + k*pi`.
///
/// The domain is read off the enclosure of `cos` over the box: a `cos` that
/// provably misses zero proves `tan` defined there, and a `cos` that reaches
/// zero admits a pole and the answer is `.maybe` with no bound on either
/// side. Note that no `f64` is ever exactly `pi/2 + k*pi`, so a POINT box is
/// never exactly a pole and never gets the `.maybe` answer by accident.
pub fn tan(z: Complex) Complex {
    const a = z.box() orelse return .undefined();
    const q = divide(sinBox(a), cosBox(a));
    const defined = z.defined.both(q.defined);
    return make(q.value, defined, unaryCt(z, defined, false));
}

/// `csc(z) = 1/sin(z)`, absent at the zeros of `sin`.
pub fn csc(z: Complex) Complex {
    const a = z.box() orelse return .undefined();
    const q = divide(oneBox(), sinBox(a));
    const defined = z.defined.both(q.defined);
    return make(q.value, defined, unaryCt(z, defined, false));
}

/// `sec(z) = 1/cos(z)`, absent at the zeros of `cos`.
pub fn sec(z: Complex) Complex {
    const a = z.box() orelse return .undefined();
    const q = divide(oneBox(), cosBox(a));
    const defined = z.defined.both(q.defined);
    return make(q.value, defined, unaryCt(z, defined, false));
}

/// `cot(z) = cos(z)/sin(z)`, absent at the zeros of `sin`.
pub fn cot(z: Complex) Complex {
    const a = z.box() orelse return .undefined();
    const q = divide(cosBox(a), sinBox(a));
    const defined = z.defined.both(q.defined);
    return make(q.value, defined, unaryCt(z, defined, false));
}

/// `asin(z) = -i*Log(i*z + sqrt(1 - z^2))`, as a VALUE.
///
/// The interior `Log` never has a hole: `i*z + sqrt(1 - z^2)` is zero only if
/// `1 - z^2 = (i*z)^2 = -z^2`, which says `1 = 0`. So the argument of the
/// logarithm is nonzero for every `z` even when its ENCLOSEMENT contains zero
/// for a wide box, and `logValue` answers that case as the image of the
/// defined part instead of refusing it.
fn asinValue(z: Box) Box {
    const l = logValue(timesI(z).add(sqrtValue(oneBox().sub(squareOf(z)))));
    return Box{ .re = l.im, .im = l.re.neg() };
}

/// `acos(z) = pi/2 - asin(z)`, as a VALUE.
fn acosValue(z: Box) Box {
    const a = asinValue(z);
    return Box{ .re = halfPi.sub(a.re), .im = a.im.neg() };
}

/// `atan(z) = (i/2)*(Log(1 - i*z) - Log(1 + i*z))`, as a VALUE.
fn atanValue(z: Box) Box {
    const iz = timesI(z);
    const d = logValue(oneBox().sub(iz)).sub(logValue(oneBox().add(iz)));
    return Box{ .re = d.im.neg().mul(B.point(0.5)), .im = d.re.mul(B.point(0.5)) };
}

/// `asin(z)`: TOTAL, with its cut along `(-inf, -1] + [1, inf)`.
///
/// Total means total. A box on the cut is answered on both sides at once —
/// the values above the real axis approach `pi/2` and those below approach
/// `-pi/2` — and the answer is marked not continuous, because it is not.
pub fn asin(z: Complex) Complex {
    const a = z.box() orelse return .undefined();
    return make(asinValue(a), z.defined, unaryCt(z, z.defined, crossesRealOutsideUnit(a.re, a.im)));
}

/// `acos(z)`: total, on the same cut as `asin`.
pub fn acos(z: Complex) Complex {
    const a = z.box() orelse return .undefined();
    return make(acosValue(a), z.defined, unaryCt(z, z.defined, crossesRealOutsideUnit(a.re, a.im)));
}

/// `atan(z)`, with its cut along the imaginary axis outside `[-i, i]`.
///
/// `+-i` are HOLES and not cuts: `atan` is the composition of a logarithm
/// with a quantity that is genuinely zero there, and `originDomain` on the two
/// inner logarithms is what reports it. `atan(0) = 0` exactly, because the two
/// logarithms are then the logarithms of the same number and their
/// enclosures are identical.
pub fn atan(z: Complex) Complex {
    const a = z.box() orelse return .undefined();
    const iz = timesI(a);
    const dom = originDomain(oneBox().sub(iz)).both(originDomain(oneBox().add(iz)));
    const defined = z.defined.both(dom);
    return make(atanValue(a), defined, unaryCt(z, defined, crossesImagOutsideUnit(a.re, a.im)));
}

/// `acsc(z) = asin(1/z)`, with a hole at `0` — `csc` never takes the value
/// zero, so there is nothing to invert there.
pub fn acsc(z: Complex) Complex {
    const a = z.box() orelse return .undefined();
    const q = divide(oneBox(), a);
    const defined = z.defined.both(q.defined);
    if (defined == .never) return .undefined();
    return make(asinValue(q.value), defined, unaryCt(z, defined, crossesRealOutsideUnit(q.value.re, q.value.im)));
}

/// `asec(z) = acos(1/z)`, with a hole at `0`.
pub fn asec(z: Complex) Complex {
    const a = z.box() orelse return .undefined();
    const q = divide(oneBox(), a);
    const defined = z.defined.both(q.defined);
    if (defined == .never) return .undefined();
    return make(acosValue(q.value), defined, unaryCt(z, defined, crossesRealOutsideUnit(q.value.re, q.value.im)));
}

/// `acot(z) = atan(1/z)` on the principal circular branch, with a stated
/// value at zero.
///
/// `acot` is the one inverse here that has a VALUE at zero, and the value is
/// the circular branch's: the circular arccot is single valued on `(0, pi)`,
/// so `acot(0) = pi/2`, which is also the limit of `atan(1/z)` along the
/// POSITIVE real axis. The limit along the negative real axis is `-pi/2`, and
/// that difference is the branch: this is the branch continuous on the
/// positive real axis, not a two-variable function that could have both at
/// once. A box that reaches zero from both sides is therefore `.maybe` about
/// the value and gets the hull of the two, which is what an uncertain argument
/// earns.
///
/// Everywhere else it is `atan(1/z)`, holes included, and it inherits
/// `atan`'s cut along the imaginary axis outside `[-i, i]` through the
/// reciprocal.
pub fn acot(z: Complex) Complex {
    const a = z.box() orelse return .undefined();
    if (isZero(a.re) and isZero(a.im)) {
        return make(Box{ .re = B.point(0.0), .im = halfPi }, z.defined, unaryCt(z, z.defined, false));
    }
    const q = divide(oneBox(), a);
    const defined = z.defined.both(q.defined);
    if (defined == .never) return .undefined();
    return make(atanValue(q.value), defined, unaryCt(z, defined, crossesImagOutsideUnit(q.value.re, q.value.im)));
}

// ---------------------------------------------------------------------------
// Hyperbolic trigonometry
// ---------------------------------------------------------------------------

/// `sinh(z)`. Entire.
pub fn sinh(z: Complex) Complex {
    const a = z.box() orelse return .undefined();
    return make(sinhBox(a), z.defined, unaryCt(z, z.defined, false));
}

/// `cosh(z)`. Entire.
pub fn cosh(z: Complex) Complex {
    const a = z.box() orelse return .undefined();
    return make(coshBox(a), z.defined, unaryCt(z, z.defined, false));
}

/// `tanh(z) = sinh(z)/cosh(z)`, absent at the zeros of `cosh`, which are the
/// purely imaginary points `pi*i/2 + k*pi*i`.
pub fn tanh(z: Complex) Complex {
    const a = z.box() orelse return .undefined();
    const q = divide(sinhBox(a), coshBox(a));
    const defined = z.defined.both(q.defined);
    return make(q.value, defined, unaryCt(z, defined, false));
}

/// `csch(z) = 1/sinh(z)`, with a hole at `0`.
pub fn csch(z: Complex) Complex {
    const a = z.box() orelse return .undefined();
    const q = divide(oneBox(), sinhBox(a));
    const defined = z.defined.both(q.defined);
    return make(q.value, defined, unaryCt(z, defined, false));
}

/// `sech(z) = 1/cosh(z)`, with holes at the zeros of `cosh`.
pub fn sech(z: Complex) Complex {
    const a = z.box() orelse return .undefined();
    const q = divide(oneBox(), coshBox(a));
    const defined = z.defined.both(q.defined);
    return make(q.value, defined, unaryCt(z, defined, false));
}

/// `coth(z) = cosh(z)/sinh(z)`, with a hole at `0`.
pub fn coth(z: Complex) Complex {
    const a = z.box() orelse return .undefined();
    const q = divide(coshBox(a), sinhBox(a));
    const defined = z.defined.both(q.defined);
    return make(q.value, defined, unaryCt(z, defined, false));
}

/// `asinh(z) = Log(z + sqrt(z^2 + 1))`, as a VALUE. Total: the argument of
/// the logarithm is zero only if `z^2 + 1 = z^2`.
fn asinhValue(z: Box) Box {
    return logValue(z.add(sqrtValue(squareOf(z).add(oneBox()))));
}

/// `acosh(z) = Log(z + sqrt(z - 1)*sqrt(z + 1))`, as a VALUE.
///
/// The two square roots are taken SEPARATELY and multiplied, and that is the
/// whole branch question: `sqrt(z - 1)*sqrt(z + 1)` is not
/// `sqrt(z^2 - 1)`, and using the latter picks the wrong side of the cut for
/// arguments in the left half plane. Written this way the function is total,
/// which is why `acosh(0)` is the answer `i*pi/2` rather than an absence.
fn acoshValue(z: Box) Box {
    const a = sqrtValue(z.sub(oneBox()));
    const b = sqrtValue(z.add(oneBox()));
    return logValue(z.add(mulBox(a, b)));
}

/// `atanh(z) = (Log(1 + z) - Log(1 - z))/2`.
///
/// `+-1` are HOLES, read off the two inner logarithms: at `z = 1` the second
/// argument is exactly zero, and the composition has no value there. They are
/// not cuts of a total function, and pretending otherwise would be inventing
/// a domain that the mathematics does not have.
pub fn atanh(z: Complex) Complex {
    const a = z.box() orelse return .undefined();
    const plus = a.add(oneBox());
    const minus = a.sub(oneBox());
    const defined = z.defined.both(originDomain(plus)).both(originDomain(minus));
    if (defined == .never) return .undefined();
    const value = logValue(plus).sub(logValue(minus)).mul(B.point(0.5));
    return make(value, defined, unaryCt(z, defined, crossesRealOutsideUnit(a.re, a.im)));
}

/// `asinh(z)`: total, with its cut along the imaginary axis outside
/// `[-i, i]`.
pub fn asinh(z: Complex) Complex {
    const a = z.box() orelse return .undefined();
    return make(asinhValue(a), z.defined, unaryCt(z, z.defined, crossesImagOutsideUnit(a.re, a.im)));
}

/// `acosh(z)`: total, with its cut along `(-inf, 1]`.
pub fn acosh(z: Complex) Complex {
    const a = z.box() orelse return .undefined();
    return make(acoshValue(a), z.defined, unaryCt(z, z.defined, crossesAcLeftOfOne(a.re, a.im)));
}

/// `acsch(z) = asinh(1/z)`, with a hole at `0`.
pub fn acsch(z: Complex) Complex {
    const a = z.box() orelse return .undefined();
    const q = divide(oneBox(), a);
    const defined = z.defined.both(q.defined);
    if (defined == .never) return .undefined();
    return make(asinhValue(q.value), defined, unaryCt(z, defined, crossesImagOutsideUnit(q.value.re, q.value.im)));
}

/// `asech(z) = acosh(1/z)`, with a hole at `0`.
pub fn asech(z: Complex) Complex {
    const a = z.box() orelse return .undefined();
    const q = divide(oneBox(), a);
    const defined = z.defined.both(q.defined);
    if (defined == .never) return .undefined();
    return make(acoshValue(q.value), defined, unaryCt(z, defined, crossesAcLeftOfOne(q.value.re, q.value.im)));
}

/// `acoth(z) = atanh(1/z)`, with a hole at `0` and the holes of `atanh` at
/// `+-1`, which the reciprocal brings along.
pub fn acoth(z: Complex) Complex {
    const a = z.box() orelse return .undefined();
    const q = divide(oneBox(), a);
    const defined = z.defined.both(q.defined);
    if (defined == .never) return .undefined();
    const w = q.value;
    const inner = defined.both(originDomain(w.add(oneBox()))).both(originDomain(w.sub(oneBox())));
    if (inner == .never) return .undefined();
    const value = logValue(w.add(oneBox())).sub(logValue(w.sub(oneBox()))).mul(B.point(0.5));
    return make(value, inner, unaryCt(z, inner, crossesRealOutsideUnit(w.re, w.im)));
}

// ---------------------------------------------------------------------------
// The full sheet and root families
// ---------------------------------------------------------------------------

/// The FULL logarithm family of one argument: `Log(z) + 2*pi*i*k` for every
/// integer `k`.
///
/// This is not a list that happens to be long. `at` computes the sheet it is
/// asked for from the integer-lattice formula, so `branchCount() == null`
/// means "infinitely many" and not "however many were enumerated", and sheet
/// `k` at the far end of the `i64` range is the same number it is at the near
/// end. `null` from `at` means the family is EMPTY, and the emptiness is a
/// fact about the DOMAIN rather than about the argument's own metadata: there
/// is no logarithm of zero on any sheet, so the family of the logarithm of
/// zero is empty and every index of it is `null`.
pub const LogFamily = struct {
    z: Complex,

    /// Whether there is a logarithm on ANY sheet. This is the DOMAIN
    /// question and not the source's own metadata: there is no logarithm of
    /// zero on any sheet at all, so sheet 0 of the logarithm of zero is
    /// `null` and the count is `0`, where a check that only looked at whether
    /// the source had a value would have answered "infinitely many sheets"
    /// and handed back a real part of `-inf`.
    fn hasSheets(self: LogFamily) bool {
        const a = self.z.box() orelse return false;
        return originDomain(a) != .never;
    }

    /// Sheet `k`, or `null` when the family is empty.
    pub fn at(self: LogFamily, k: i64) ?Complex {
        if (!self.hasSheets()) return null;
        return logSheet(self.z, k);
    }

    /// `null` for infinitely many branches, `0` for none.
    pub fn branchCount(self: LogFamily) ?usize {
        if (!self.hasSheets()) return 0;
        return null;
    }

    /// Whether the argument has a logarithm at all, and on which sheets.
    pub fn defined(self: LogFamily) Truth {
        const a = self.z.box() orelse return .never;
        return self.z.defined.both(originDomain(a));
    }
};

/// The FULL root family of one argument: exactly `degree` roots.
///
/// The count is exact and it is `degree`, not however many the caller looked
/// at: every root of a nonzero argument exists, is distinct, and is at one of
/// the indices `0..degree-1`. `at` accepts those indices and returns `null`
/// outside them, so a caller who asks for a root that is not one of the
/// `degree` gets told so rather than handed a duplicate.
pub const RootFamily = struct {
    z: Complex,
    degree: u32,

    /// Root `k`, or `null` for an empty family or an index outside
    /// `0..degree-1`.
    pub fn at(self: RootFamily, k: i64) ?Complex {
        if (self.z.defined == .never or self.degree == 0) return null;
        const d: i64 = @intCast(self.degree);
        if (k < 0 or k >= d) return null;
        return root(self.z, self.degree, k);
    }

    /// `degree` roots, or `0` when there are none: an absent argument, or a
    /// degree of zero, which has no root at all to count.
    pub fn branchCount(self: RootFamily) ?usize {
        if (self.z.defined == .never or self.degree == 0) return 0;
        return @intCast(self.degree);
    }

    /// Whether the argument has a root at all.
    pub fn defined(self: RootFamily) Truth {
        if (self.degree == 0) return .never;
        return self.z.defined;
    }
};

/// The full logarithm family of `z`.
pub fn logFamily(z: Complex) LogFamily {
    return .{ .z = z };
}

/// The full root family of `z` at `degree` roots. The degree comes FIRST,
/// after `nthRoot`, for the same reason it does there.
pub fn rootFamily(z: Complex, degree: u32) RootFamily {
    return .{ .z = z, .degree = degree };
}

// ---------------------------------------------------------------------------
// The branch producers
// ---------------------------------------------------------------------------

/// One side of the real axis within a box, with the label that side carries.
const Side = struct {
    /// `principalLog`'s label for this side: `+1` above, `0` on the exact
    /// axis, `-1` below.
    choice: branches.Choice,
    /// The sub-box of the argument on this side.
    box: Box,
    /// `roots`' side index: 0 below, 1 on the axis, 2 above.
    index: i128,
};

/// At most two sides of the real axis, which is all a box can have once the
/// two strict sides have been separated.
const Sides = struct {
    items: [2]Side,
    len: usize,
};

/// Split a box by cut side.
///
/// A box with imaginary parts strictly on both sides of zero becomes two
/// pieces, each clamped to touch the real axis: the upper one and the lower
/// one. A box on one side only, or exactly ON the axis, is a single piece and
/// keeps its own label. There is no third "on the axis" piece for a straddling
/// box: the axis there is a zero-width face of the same set, already inside
/// both of the pieces that straddle it, and publishing it again would give a
/// caller a cell it cannot pair with anything the other two do not already
/// cover.
fn sidesOf(z: Box) Sides {
    const y = z.im;
    if (y.lo < 0.0 and y.hi > 0.0) {
        return Sides{
            .items = .{
                .{ .choice = 1, .box = Box{ .re = z.re, .im = B.init(0.0, y.hi) }, .index = 2 },
                .{ .choice = -1, .box = Box{ .re = z.re, .im = B.init(y.lo, 0.0) }, .index = 0 },
            },
            .len = 2,
        };
    }
    if (y.lo > 0.0) {
        return Sides{ .items = .{.{ .choice = 1, .box = z, .index = 2 }}, .len = 1 };
    }
    if (y.hi < 0.0) {
        return Sides{ .items = .{.{ .choice = -1, .box = z, .index = 0 }}, .len = 1 };
    }
    return Sides{ .items = .{.{ .choice = 0, .box = z, .index = 1 }}, .len = 1 };
}

/// `Log(b) + 2*pi*i*k` as a VALUE, for a box already known to lie on one
/// side of the real axis.
fn logSheetBox(b: Box, k: i64) Box {
    const l = logValue(b);
    return Box{ .re = l.re, .im = l.im.add(cert.pi.mul(twoTimesInt(k))) };
}

/// The label of sheet `k` on a side: `3*k + (side + 1)`.
///
/// The arithmetic is in `i128` and the integer in `i64`, so `3*k` cannot
/// overflow whatever `k` is, and the factor three keeps the three sides of
/// one sheet in `3k..3k+2`, which no neighbouring sheet reaches.
fn sheetLabel(k: i64, side_choice: branches.Choice) branches.Choice {
    return 3 * @as(i128, k) + side_choice + 1;
}

/// The label of root `k` on a side: `3*k + side_index`.
///
/// The factor is the number of sides and NOT the degree, which is what makes
/// the encoding collision-free for EVERY degree at once: with `degree*k` a
/// two-rooted enumeration put root 0 above the axis at the same label as root
/// 1 below it, so two different roots of two different calls could be told
/// apart by nothing. `3k..3k+2` and `3(k+1)..3k+5` cannot meet whatever `k`
/// is, and the arithmetic is in `i128` so it cannot overflow on the way.
fn rootLabel(k: i64, side_index: i128) branches.Choice {
    return 3 * @as(i128, k) + side_index;
}

/// Publish one value with no branch decision attached, for a caller building
/// a set that has no branch to label.
pub fn leaf(out: *branches.Writer(Complex), value: Complex) Error!branches.Set(Complex) {
    const cp = out.checkpoint();
    errdefer out.rollback(cp);
    _ = try out.append(value, &.{});
    return out.view();
}

/// The principal logarithm of every piece, split across the negative real
/// axis cut.
///
/// Both sides of the cut are published, and they are published SEPARATELY,
/// because they are different cells: the principal argument is `pi` on the
/// axis, approaches `pi` from above and `-pi` from below, and a piece that
/// covered both would be reporting the hull of two functions while claiming
/// to be one. The label is the side: `+1` above, `0` on the exact axis, `-1`
/// below.
///
/// Each published piece is continuous on its own box, so its continuity is
/// `.always` whenever it is defined; it is the ORIGINAL box that is not
/// continuous across the cut, and that is what the caller can see by having
/// received two pieces with different labels instead of one.
///
/// An absent input piece is published as ONE absent piece, with its incoming
/// map intact. Dropping it would be a resource decision dressed as a
/// mathematical one: a set that contains a false alternative and a set that
/// omits it answer a caller's comparison DIFFERENTLY, and the difference is
/// the difference between "these are not equal" being possible and it not
/// being. The absent piece carries no number — there is no value to invent one
/// for — and it carries the axis label `0`, which is the one side that is
/// neither above nor below and so the honest placeholder for "no side at
/// all".
///
/// A piece whose incoming map already binds `site` to a DIFFERENT label is a
/// proven contradiction — the caller's cell and this side cannot both be true
/// of the same evaluation — and `appendBound` publishes nothing for it. The
/// loop moves on to the next side, which is the whole of the rest of the
/// split.
///
/// Every published piece inherits the SOURCE piece's continuity proof and
/// adds only its own domain. A split does not make the function any more
/// continuous than it was: what makes the answer discontinuous across the cut
/// is the cut, and the caller sees that as two labelled pieces rather than
/// being told that each one on its own is continuous.
pub fn principalLog(
    out: *branches.Writer(Complex),
    input: branches.Set(Complex),
    site: branches.Site,
) Error!branches.Set(Complex) {
    const cp = out.checkpoint();
    errdefer out.rollback(cp);

    for (input.pieces) |piece| {
        const a = piece.value.box() orelse {
            _ = try out.appendBound(.undefined(), piece.assignments, site, 0);
            continue;
        };
        const defined = piece.value.defined.both(originDomain(a));
        const sides = sidesOf(a);
        for (sides.items[0..sides.len]) |side| {
            const value = pieceValue(logSheetBox(side.box, 0), piece.value, defined);
            _ = try out.appendBound(value, piece.assignments, site, side.choice);
        }
    }
    return out.view();
}

/// One piece per selected sheet of one side of the cut.
///
/// `selected` is an EXPLICIT selection of sheets and is not a claim that the
/// set is the whole family: the family is `LogFamily`, which is infinite.
/// Duplicate indices in `selected` produce duplicate labels on purpose —
/// they are the same cell written down twice, and merging them would be a
/// silent hull of two things the caller asked for separately.
///
/// The label is `3*k + (side + 1)`, so a caller can read the sheet and the
/// cut side back off a single `i128` without consulting this file.
///
/// An absent input piece is published as ONE absent piece carrying its
/// incoming map and the sheet-0 axis label, exactly as `principalLog` does it
/// and for exactly the same reason: an omitted alternative is a silent
/// change to what the set means.
pub fn logSheets(
    out: *branches.Writer(Complex),
    input: branches.Set(Complex),
    site: branches.Site,
    selected: []const i64,
) Error!branches.Set(Complex) {
    const cp = out.checkpoint();
    errdefer out.rollback(cp);

    for (input.pieces) |piece| {
        const a = piece.value.box() orelse {
            _ = try out.appendBound(.undefined(), piece.assignments, site, sheetLabel(0, 0));
            continue;
        };
        const defined = piece.value.defined.both(originDomain(a));
        const sides = sidesOf(a);
        for (sides.items[0..sides.len]) |side| {
            for (selected) |k| {
                const value = pieceValue(logSheetBox(side.box, k), piece.value, defined);
                _ = try out.appendBound(value, piece.assignments, site, sheetLabel(k, side.choice));
            }
        }
    }
    return out.view();
}

/// Every root of every piece, at every side of the cut.
///
/// This one IS complete: `degree` roots exist for `degree > 0`, and this
/// writes all of them. It fails with `CapacityExceeded` rather than writing
/// the ones that fit, and the writer is rolled back to its entry checkpoint
/// so that a caller who runs out of room is left with exactly what it had
/// before and no partial set to mistake for an answer.
///
/// `degree == 0` is not a failure and not a full set either: it is the empty
/// set, because a zero-th root is not a thing and the count of roots at
/// degree zero is zero.
///
/// An absent input piece is published as ONE absent piece carrying its
/// incoming map and the root-0 axis label, as in the other two producers.
/// There is no enumeration to run for it: an absent argument has no roots,
/// and the piece that says so is published once rather than `degree` times.
///
/// Every published piece inherits the SOURCE piece's continuity proof and
/// adds only its own domain, for the same reason `principalLog` does: the
/// split is what reveals the cut, not a change in the function.
pub fn roots(
    out: *branches.Writer(Complex),
    input: branches.Set(Complex),
    degree: u32,
    site: branches.Site,
) Error!branches.Set(Complex) {
    const cp = out.checkpoint();
    errdefer out.rollback(cp);

    if (degree == 0) return out.view();
    const d: i64 = @intCast(degree);

    for (input.pieces) |piece| {
        const a = piece.value.box() orelse {
            _ = try out.appendBound(.undefined(), piece.assignments, site, rootLabel(0, 1));
            continue;
        };
        const sides = sidesOf(a);
        for (sides.items[0..sides.len]) |side| {
            var k: i64 = 0;
            while (k < d) : (k += 1) {
                const value = pieceValue(rootBox(side.box, degree, k), piece.value, piece.value.defined);
                _ = try out.appendBound(value, piece.assignments, site, rootLabel(k, side.index));
            }
        }
    }
    return out.view();
}

/// The answer for one side-piece: the value the producer computed, carrying
/// the SOURCE piece's continuity proof rather than a fresh claim of its own.
fn pieceValue(b: Box, source: Complex, defined: Truth) Complex {
    return make(b, defined, pieceCt(source, defined));
}
