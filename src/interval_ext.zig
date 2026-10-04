//! Elementary functions of an interval, each returning an enclosure of
//! the true result rather than a rounded copy of it.
//!
//! `interval.zig` holds the operations that min and max arithmetic
//! already carries out. Everything here needs monotonicity or domain
//! analysis to say where the result can lie, which is why it is a
//! set of free functions rather than methods on the interval.
//!
//! HOW AN ANSWER IS MADE. Every transcendental below is evaluated in
//! `certified.zig`, in outward f128 interval arithmetic with an explicit
//! remainder bound for the truncation each series leaves behind, and the
//! f64 answer is the directed projection of that f128 bound: for a finite
//! f128 end, the nearest f64 when it already lies on the right side of it
//! and its neighbour otherwise. Roundoff is therefore covered at EVERY
//! primitive rather than by a step count chosen after the fact, and
//! nothing in this file widens a computed endpoint by a number of ULPs or
//! pads it past a value the format cannot hold. What is left in this file
//! is the mathematics the kernels deliberately do not know: which
//! arguments are in a domain at all, where an image is unbounded, where an
//! endpoint image is an exact integer, where the critical points and poles
//! of the circular functions stand, and how the sign of a power of a
//! negative base follows the parity of an exponent.
//!
//! TWO KINDS OF "NO ANSWER" ARE KEPT APART. `null` means the image is
//! empty in the reals, and every function that can return it clips a
//! partly off-domain argument and refuses only a wholly invalid one, so
//! `sqrt([-4, 1])` is `[0, 1]` and `asin([-4, 0.5])` is `[-pi/2, asin(0.5)]`
//! rather than either refused; a clipped end is a bound the image really
//! has. The refusal that is not about a domain is `powf`'s, and it is a
//! fact about dyadics: a finite non-integer f64 is `p/2^k` in lowest terms
//! with `k >= 1`, so its reduced denominator is even, no odd root of it
//! exists, and a wholly negative base under such an exponent has no real
//! value at any magnitude. An `Interval` with an infinite endpoint is a
//! different answer: unbounded but real, as tangent is across a pole, or
//! a power of a base reaching zero under a negative exponent. Collapsing
//! the two would either throw away a real answer or invent an empty one.
//!
//! The overflow rays arrive as the rays they are: an endpoint at
//! `floatMax` or at `-inf` is read as the half-line it stands for, and
//! nothing here re-derives, widens or re-asserts the conditions. What each
//! function does with a ray is its own business, decided by its own domain
//! and monotonicity, and the answer is not uniform. A function whose domain
//! sits above zero — `sqrt`, `log`, `log2`, `log10`, `log1p`, `acosh` — is
//! outside its domain over the whole negative ray and answers `null` there.
//! `cbrt` and `asinh` are defined on all of the reals and are rising, so
//! the kernel carries them to an unbounded endpoint of the matching sign.
//! An unbounded argument is not in itself a reason for an infinite
//! endpoint, and the functions that saturate are the counterexamples:
//! `tanh` answers either ray with a bounded range near 1, `atan` with a
//! bounded range below pi/2, and `sin` and `cos` with the whole `[-1, 1]`.
//!
//! THE CIRCULAR FUNCTIONS read their range off the endpoints and the
//! critical points rather than reducing the argument, because the critical
//! values are exactly +/-1 and need no arithmetic of their own, while a
//! range reduction would have to be rigorous to the last bit of a multiple
//! of pi. The critical points are found by `criticalIndices` below, which
//! returns `null` once the index is past what this file will count — which
//! is at the boundary the argument reduction behind the endpoints gives up
//! as well, so a counted index and a usable endpoint value stop together.
//! That is the only give-up in the file, it is proved rather than budgeted,
//! and it costs nothing: the answer there is the whole of the range the
//! function spans — `[-1, 1]` for sine and cosine, `[-inf, +inf]` for
//! tangent — which holds every value the function can take, extrema and
//! poles included.

const std = @import("std");
const Interval = @import("interval.zig").Interval;
const rounding = @import("rounding.zig");
const certified = @import("certified.zig");

/// The outward f128 bound type the kernels speak.
const Bounds = certified.Bounds;

/// The positive infinity, for the answers that are unbounded but real.
/// The value is the layout's, not this file's: `rounding` owns the ends of
/// the format, so the answer here is bound to the same bits as every other.
const inf = rounding.pos_inf;

/// The same answer in the arithmetic the kernels are written in. It is
/// used once, at the one place this file builds an unbounded bound itself
/// rather than asking a kernel for one.
const inf128 = std.math.inf(f128);

/// pi/2 as outward f128 bounds: half the certified pi. Halving is exact in
/// binary floating point, so this is pi/2 to the same relative accuracy pi
/// itself is carried at, and dividing is what keeps the dependency on one
/// certified constant rather than on a second copy of it. A function
/// rather than a file-scope constant so that no kernel arithmetic is asked
/// to run at comptime.
fn halfPi() Bounds {
    return Bounds.div(certified.pi, Bounds.point(2.0));
}

/// The offset of the tangent cells: -pi/2, the reflection of `halfPi`.
/// The cell holding an angle `theta` is labelled
/// `floor((theta + pi/2)/pi)`, which is the integer lattice generated by
/// `theta = -pi/2 + k*pi`.
fn cellOffset() Bounds {
    return Bounds.neg(halfPi());
}

/// The f128 bounds of an f64 box in the kernel arithmetic. The widening is
/// exact: every f64 is an f128, infinities included, and the canonical
/// overflow rays carry their own end in each direction.
fn widen(x: Interval) Bounds {
    return Bounds.fromInterval(x);
}

/// The f64 enclosure of a kernel result, directed outward at both ends.
fn narrow(x: Bounds) Interval {
    return Bounds.project(x);
}

/// The f128 bounds of one f64 value, for an argument known to be a point.
/// Distinct from `widen`, which is given a box.
fn pointOf(x: f64) Bounds {
    return Bounds.point(@floatCast(x));
}

/// Hull of two kernel results, taken before the projection. The projection
/// is monotone in each end, so a minimum commutes with a directed round
/// and the two orders produce the same `Interval`; doing it here keeps
/// four kernel results to one projection rather than four.
fn join(a: Bounds, b: Bounds) Bounds {
    return Bounds.init(@min(a.lo, b.lo), @max(a.hi, b.hi));
}

/// The inclusive range of integer indices `k`, empty when `last` is below
/// `first`.
pub const IndexRange = struct {
    first: i128,
    last: i128,
};

/// The integers `k` whose `offset + k * period` may meet the box `x`.
///
/// This is a SUPERSET of the indices that really do. A point admitted that
/// is not there costs a caller one extra cell, while a point that is there
/// and was not admitted is the one failure nothing downstream can recover
/// from, so the quotient is widened outward and never inward. `first`
/// above `last` means there are none. `null` means the index is past what
/// this file will count, which is NEVER "there are none": a caller that
/// cannot count the candidates has to say so rather than enumerate a wrong
/// range and report it as complete. `max_index` below sets that line, and
/// it is deliberately a fraction of what an i128 holds.
///
/// The quotient is `(x - offset) / period`, formed as one interval division
/// of outward bounds, and each of its ends is then rounded outward to the
/// integer that encloses it. `period` is expected to be positive and clear
/// of zero, which is what every caller here passes; a period that reaches
/// zero divides to the whole line and leaves through `null`, which is the
/// sound answer for an unusable period.
pub fn criticalIndices(x: Interval, offset: Bounds, period: Bounds) ?IndexRange {
    return indexRange(certified.div(widen(x).sub(offset), period));
}

/// The largest index this file will count, as a bound on the quotient
/// `indexRange` receives rather than on the angle. The two are the same
/// statement in different units: an index leaves i128 at `2^127`, and the
/// index of a critical point at angle `x` is `x / period`, so the ceiling
/// on the angle is `(pi/2) * 2^127` for the circular functions.
///
/// `certified.zig` bounds its argument reduction at `1.5 * 2^127` on the
/// ANGLE, which is 0.955 of that ceiling, and this takes the same angle
/// bound over the same period so the two agree on ONE boundary. That is
/// the whole reason this is not a round power of two: a mismatch leaves a
/// sliver of arguments in which the index is counted here and then
/// discarded by the kernel asked to evaluate the points, which is sound
/// and wastes a division to learn nothing.
///
/// The agreement is specific to `period` being pi, which is what every
/// caller in this file passes — the critical points, the poles and the
/// cells all use `certified.pi`. A caller with some other period refuses
/// at `max_index * period` instead, which lines up with nothing and is
/// sound all the same: what this constant really guarantees is the
/// conversion margin below, and the alignment is a refinement of it that
/// happens to be available for one period.
///
/// Matching also decides what a producer sees at the far end. A box whose
/// cells are countable is enumerated; one past this gets `null`, which is
/// the documented refusal. Enumerating cells whose values would each come
/// back as the whole line is strictly worse than saying so.
const max_index: f128 = 1.5 * 0x1p127 / @floatCast(std.math.pi);

/// The enclosing integers of a quotient, with the representability test
/// that decides between a range and `null`.
fn indexRange(quotient: Bounds) ?IndexRange {
    // `@ceil` and `@floor` move by at most one, so a quotient below this
    // bound converts to at most `max_index + 1`, and that is 2.09 times
    // smaller than `2^127 - 1`. The conversion below is therefore in range
    // for every value that passes, which is the reason this bound is a
    // fraction of the ceiling rather than the ceiling itself.
    //
    // A NaN endpoint fails both comparisons, so a box that arrived with a
    // poisoned end leaves through here rather than through a conversion
    // that would trap on it.
    if (!(quotient.lo > -max_index and quotient.hi < max_index)) return null;
    return .{
        .first = @intFromFloat(@ceil(quotient.lo)),
        .last = @intFromFloat(@floor(quotient.hi)),
    };
}

/// The cell labels an angle in the box can carry: every `k` whose cell
/// `[k*pi - pi/2, (k+1)*pi - pi/2]` meets the box, in the same
/// superset-and-`null` sense as `criticalIndices`.
///
/// A cell and a pole are different things and the label is what tells them
/// apart: the pole between cells `k` and `k+1` is `tangentPole(k)`. A
/// producer that split a tangent box by SIGN could not separate the two
/// rays of one cell from two cells either side of a pole, which is the
/// whole reason the label is a cell and not a sign bit.
pub fn tangentCells(x: Interval) ?IndexRange {
    return criticalIndices(x, cellOffset(), certified.pi);
}

/// The pole between cells `k` and `k+1`: `pi/2 + k*pi`.
///
/// An enclosure and not a point, because `k` is an i128 whose conversion
/// into f128 is itself rounded and because the product with pi rounds once
/// more. It is OUTWARD at both ends and monotone in `k` — the poles stand
/// pi apart and the widest this enclosure gets is a few f64 steps — so a
/// caller reading a cell boundary off it gets a cell that is widened
/// rather than narrowed, which is the only direction a split may err in.
pub fn tangentPole(k: i128) Interval {
    return narrow(Bounds.add(halfPi(), certified.mul(certified.pi, Bounds.fromInt(k))));
}

/// Whether the box is longer than `2*pi`, which is what makes it hold two
/// consecutive critical points.
///
/// The critical points stand `pi` apart, so a closed box longer than
/// `2*pi` holds at least two of them, and two consecutive ones are a
/// maximum and a minimum for sine and cosine and two poles for tangent: the
/// image is then the whole of the range each one spans. The threshold is
/// the certified UPPER bound on `pi`, doubled, and doubling is exact in
/// binary floating point, so it is strictly above `2*pi` and a box that
/// passes has provably more than `2*pi` of length.
///
/// This is also what bounds the enumeration below. A box shorter than
/// `2*pi` holds at most two critical points, so the loop cannot run long
/// however wide the argument is.
fn spansFullPeriod(x: Interval) bool {
    const length: f128 = @floatCast(x.hi) - @floatCast(x.lo);
    return length > 2.0 * certified.pi.hi;
}

/// Which of the three circular kernels an endpoint sweep asks for. A
/// private tag rather than a function pointer: the three are called on the
/// same two points and through the same hull, and a pointer here would buy
/// an indirect call and a signature that says nothing about which of the
/// three it is.
const Circular = enum { sin, cos, tan };

/// The certified kernel named by a tag. One place, so the two endpoint
/// evaluations of a box cannot be asked of different functions.
fn circularKernel(which: Circular) *const fn (Bounds) Bounds {
    return switch (which) {
        .sin => certified.sin,
        .cos => certified.cos,
        .tan => certified.tan,
    };
}

/// The enclosure of a circular kernel at the two ENDS of the box.
///
/// Both ends are taken, because an endpoint of the argument is not
/// necessarily an endpoint of the image of a function that turns inside the
/// box, and they are hulled rather than crossed.
fn endpoints(x: Interval, which: Circular) Interval {
    const kernel = circularKernel(which);
    return narrow(kernel(pointOf(x.lo))).hull(narrow(kernel(pointOf(x.hi))));
}

/// The whole of the range sine and cosine span, which is also the answer
/// wherever the critical points cannot be counted.
fn unitRange() Interval {
    return Interval.init(-1.0, 1.0);
}

/// The enclosure of the critical candidates, cut to the range both circular
/// functions span. A superset of the true range cut to `[-1, 1]` is still a
/// superset, and this one is no longer than it was. The fallback cannot be
/// reached, since the candidates hold real values of the function and
/// those lie inside `[-1, 1]`; it is there so that a release build without
/// the assertion in `init` still answers with a range that contains the
/// result.
fn insideUnitRange(lo: f64, hi: f64) Interval {
    return Interval.init(lo, hi).intersect(Interval.init(-1.0, 1.0)) orelse unitRange();
}

/// Sine over the interval. A box longer than `2*pi` reaches both ends of
/// the range, and a narrower one is read off its endpoints and the critical
/// points it covers, which stand at `pi/2 + k*pi` and are worth `+1` for
/// even `k` and `-1` for odd `k`.
///
/// A phase whose index has left what an i128 counts in is answered with
/// the whole `[-1, 1]` before any endpoint is read. That is the proved
/// range of the function rather than a fallback: every value sine can take
/// lies in it, extrema included, and it is reached when the critical points
/// can no longer be counted rather than at any magnitude fixed in advance.
pub fn sin(x: Interval) Interval {
    if (spansFullPeriod(x)) return unitRange();
    const range = criticalIndices(x, halfPi(), certified.pi) orelse return unitRange();
    const ends = endpoints(x, .sin);
    var lo = ends.lo;
    var hi = ends.hi;
    var k = range.first;
    while (k <= range.last) : (k += 1) {
        const extreme: f64 = if (@rem(k, 2) == 0) 1.0 else -1.0;
        lo = @min(lo, extreme);
        hi = @max(hi, extreme);
    }
    return insideUnitRange(lo, hi);
}

/// Cosine over the interval, read off its endpoints and the critical
/// points at `k*pi`, worth `+1` for even `k` and `-1` for odd `k`. The
/// argument is never reduced, and the give-up at an uncountable phase is
/// the same whole range `sin` returns and for the same reason.
pub fn cos(x: Interval) Interval {
    if (spansFullPeriod(x)) return unitRange();
    const range = criticalIndices(x, Bounds.point(0.0), certified.pi) orelse return unitRange();
    const ends = endpoints(x, .cos);
    var lo = ends.lo;
    var hi = ends.hi;
    var k = range.first;
    while (k <= range.last) : (k += 1) {
        const extreme: f64 = if (@rem(k, 2) == 0) 1.0 else -1.0;
        lo = @min(lo, extreme);
        hi = @max(hi, extreme);
    }
    return insideUnitRange(lo, hi);
}

/// Tangent over the interval. A pole inside it makes the result unbounded,
/// which is a real answer rather than an empty one, and the poles stand pi
/// apart at `pi/2 + k*pi`, the same places where sine turns. Without one
/// the function is continuous and rising across the whole box, so the
/// endpoints hold the range.
///
/// A box longer than `2*pi` holds at least one pole whatever the argument
/// is, and a phase whose index has left what an i128 counts in cannot be
/// searched for poles at all. Both answer with the whole line, which holds
/// every value tangent can take.
pub fn tan(x: Interval) Interval {
    if (spansFullPeriod(x)) return Interval.init(-inf, inf);
    const range = criticalIndices(x, halfPi(), certified.pi) orelse return Interval.init(-inf, inf);
    if (range.first <= range.last) return Interval.init(-inf, inf);
    return endpoints(x, .tan);
}

/// The square root, or null when the whole interval is negative and so has
/// no square root at all. A negative part contributes nothing but the bound
/// at zero, which the clip below supplies.
pub fn sqrt(x: Interval) ?Interval {
    if (x.hi < 0.0) return null;
    return narrow(certified.sqrt(widen(Interval.init(@max(x.lo, 0.0), x.hi))));
}

/// The cube root, which is defined and rising on all of the reals, so the
/// negative ray carries it to an unbounded lower end.
pub fn cbrt(x: Interval) Interval {
    return narrow(certified.cbrt(widen(x)));
}

/// The integer power, by exponentiation by squaring inside the kernel so
/// that the error of log n multiplications is what accumulates rather than
/// the error of n of them at once. A negative exponent inverts the
/// positive one, which a base reaching zero makes impossible in finite
/// bounds.
///
/// Two of the answers are settled by the body rather than by the
/// squaring: an exponent of zero is `[1, 1]` for any base at all, and a
/// negative exponent of a base that reaches zero is `[-inf, +inf]`,
/// because the inversion it asks for has no finite bound to give.
///
/// The kernel is asked for the image of the whole box rather than for a
/// product of boxes, and that is not a convenience. An odd power of a box
/// that straddles zero is not the product of that box with itself: `3^3` is
/// 27 while `[-2,3]*[-2,3]*[-2,3]` stops at 18, because the box is not
/// monotone in its base across zero. Only a kernel that splits the box at
/// zero can enclose it, and `certified.powUnsigned` does.
pub fn pow(x: Interval, n: i32) Interval {
    if (n == 0) return Interval.init(1.0, 1.0);
    if (n < 0 and x.contains(0.0)) return Interval.init(-inf, inf);
    // Negation in i64, since the magnitude of the most negative i32 has no
    // positive counterpart to hold it, and u64 takes the magnitude as it
    // stands rather than as a sign that has to be carried further.
    const magnitude: u64 = @intCast(if (n < 0) -@as(i64, n) else @as(i64, n));
    const raised = unsignedPower(x, magnitude);
    if (n > 0) return raised;
    return Interval.init(1.0, 1.0).div(raised);
}

/// `x^n` for a box and an exponent a u64 holds, in one line so that every
/// caller reaches the kernel the same way.
fn unsignedPower(x: Interval, n: u64) Interval {
    return narrow(certified.powUnsigned(widen(x), n));
}

/// The real power of an interval by an interval.
///
/// The base is split into the three parts the real line has, and each part
/// is answered by its own mathematics rather than by one decision taken at
/// the top:
///
///  * a base reaching zero is answered from the exponent alone — zero under
///    a positive one, `1` when `0^0 = 1` is in the image, and no finite
///    upper bound under a negative one, since a vanishing positive base
///    raised to a negative power runs to infinity;
///  * a base above zero is monotone in each argument, so its four corners
///    carry the whole range;
///  * a base below zero is real only under an exponent whose reduced
///    denominator is odd, and the numerator's parity decides the sign.
pub fn powf(x: Interval, y: Interval) ?Interval {
    // `x^0` is 1 for every real `x`, the base 0 included, so an exponent
    // box that IS the single value zero is settled before anything looks
    // at the base. The answer is exactly `[1, 1]`, for a wholly negative
    // base and for one reaching zero alike.
    if (y.lo == 0.0 and y.hi == 0.0) return Interval.init(1.0, 1.0);

    const split = x.zeroSplit();
    var out: ?Interval = null;

    // The part below zero, cut at the axis so the magnitude raised is a box
    // of NON-NEGATIVE numbers even when the base straddles. It contributes
    // nothing when the exponent admits no real power of a negative base, and
    // a box that straddles the axis keeps its other parts either way.
    switch (split) {
        .negative, .touches_below, .straddles => {
            if (negativePower(Interval.init(x.lo, @min(x.hi, 0.0)), y)) |part| {
                out = joinResult(out, part);
            }
        },
        .positive, .touches_above, .zero => {},
    }

    // The degenerate part at zero, which the base holds whenever it reaches
    // zero from either side.
    switch (split) {
        .zero, .touches_above, .touches_below, .straddles => {
            out = joinResult(out, zeroBasePower(y));
        },
        .negative, .positive => {},
    }

    // The part above zero, which exists whenever the box reaches above zero.
    switch (split) {
        .positive, .touches_above, .straddles => {
            out = joinResult(out, positivePower(Interval.init(@max(x.lo, 0.0), x.hi), y));
        },
        .negative, .touches_below, .zero => {},
    }

    return out;
}

/// An existing result hulled with a new one, the new one standing alone
/// where there is nothing yet.
fn joinResult(so_far: ?Interval, next: Interval) Interval {
    const current = so_far orelse return next;
    return current.hull(next);
}

/// The image of the base `{0}` under the exponents in `y`.
///
/// Three exact cases and no arithmetic: `0^e` is zero for every positive
/// `e`, one at `e = 0` because `0^0` is 1, and unbounded above for a
/// negative one. The negative case is unbounded rather than empty because
/// the box around it holds bases approaching zero from above, and their
/// negative powers have no upper bound at all — a real value past the end
/// of the format, which is exactly what an infinite endpoint means here.
fn zeroBasePower(y: Interval) Interval {
    if (y.lo < 0.0) return Interval.init(0.0, inf);
    if (y.lo == 0.0) return Interval.init(0.0, 1.0);
    return Interval.init(0.0, 0.0);
}

/// The image of a base box of non-negative numbers under the exponents in
/// `y`, read off the four corners.
///
/// Both arguments are monotone over a positive base — the base rises with
/// the exponent above one and falls below it, which taking every
/// combination of corner covers — so the four corners hold the extremes of
/// the image and nothing else has to be examined. A base end of zero goes
/// through `cornerPower`'s exact cases rather than through a logarithm of
/// zero.
fn positivePower(x: Interval, y: Interval) Interval {
    return narrow(join(
        join(cornerPower(x.lo, y.lo), cornerPower(x.lo, y.hi)),
        join(cornerPower(x.hi, y.lo), cornerPower(x.hi, y.hi)),
    ));
}

/// `b^e` for one non-negative base end and one exponent end.
///
/// The two cases a logarithm cannot see are settled first: a zero base,
/// which is `zeroBasePower` at a point exponent, and a zero exponent, which
/// is one for every base. Both matter here rather than only at the top of
/// `powf`, because a corner pair is free to be one of them while the other
/// three corners are ordinary — a zero exponent multiplied by an infinite
/// logarithm would otherwise carry an indeterminate product into the hull.
fn cornerPower(b: f64, e: f64) Bounds {
    if (b == 0.0) {
        if (e < 0.0) return Bounds.init(0.0, inf128);
        if (e == 0.0) return Bounds.init(0.0, 1.0);
        return Bounds.init(0.0, 0.0);
    }
    if (e == 0.0) return Bounds.point(1.0);
    // `b^e` is `exp(e * log b)` for `b > 0`, and each of the three is a
    // certified kernel, so the rounding of the whole composition is
    // absorbed by the arithmetic rather than by a margin applied from
    // outside to a value the arithmetic already bounded.
    return certified.exp(certified.mul(pointOf(e), certified.log(pointOf(b))));
}

/// The image of a base box reaching strictly below zero, or null when the
/// exponent admits no real power of a negative base at all.
///
/// A singleton exponent decides the whole sign question. An exact integer
/// `n` keeps the sign of the base exactly as `(-1)^n` does, so `(-2)^3` is
/// `-8` and `(-2)^2` is `4`, and the odd case is the half of the image a
/// magnitude alone loses. A singleton exponent that is not an integer is
/// `p/2^k` in lowest terms with an EVEN denominator, so no odd root of it
/// exists and the honest answer is null rather than an enclosure of
/// nothing.
///
/// A positive-width exponent box is a different case, and refusing it
/// would throw away real values. Every such box contains rationals of BOTH
/// numerator parities over an odd denominator — `1` and `4/3` both lie in
/// `[1, 2]` — so the image reaches both signs and the enclosure is
/// symmetric about zero. That is not a property of `[1, 2]` alone: for any
/// odd `q` large enough, both `p/q` and `(p+1)/q` lie inside ANY
/// positive-width box, and their parities differ. A base of `-1` under
/// `[1, 2]` is therefore `[-1, +1]`, not `[1, 1]`.
fn negativePower(x: Interval, y: Interval) ?Interval {
    const magnitude = Interval.init(-x.hi, -x.lo);
    if (y.lo == y.hi) {
        const n = y.lo;
        if (n != @trunc(n)) return null;
        const raised = signedPower(magnitude, n);
        // fmod is exact on an exact division, and every f64 integer at or
        // above 2^53 is even, so this reads the parity of the integer for
        // every integer an f64 holds.
        if (@rem(n, 2.0) == 0.0) return raised;
        return raised.neg();
    }
    const spread = positivePower(magnitude, y);
    return Interval.init(-spread.hi, spread.hi);
}

/// `|b|^n` for a base box of non-negative numbers and an exact integer
/// exponent of any magnitude an f64 holds.
///
/// The exponent is bounded by no machine word here, which is what makes
/// the second half of this necessary: `2^3000000000` is past the end of
/// every format and `2^-3000000001` is below the smallest value any of
/// them holds, and neither may be answered by refusing. Past the range of
/// a u64 the logarithmic form carries it instead, and the product it forms
/// is a finite f128 for every finite exponent, so the overflow happens
/// where it belongs: in the exponential, as an infinity the projection
/// reads as an unbounded but real image.
fn signedPower(a: Interval, n: f64) Interval {
    if (n == 0.0) return Interval.init(1.0, 1.0);
    // A vanishing magnitude under a negative exponent inverts, and the
    // inversion has no finite bound in either direction.
    if (n < 0.0 and a.lo == 0.0) return Interval.init(-inf, inf);
    // 2^64 is one past the largest magnitude a u64 holds. Every f64 integer
    // at or above it is even, so this branch only ever sees an even
    // exponent; the parity has already been settled by the caller, which
    // is what keeps the two branches from disagreeing about the sign.
    if (@abs(n) < 0x1p64) {
        const raised = unsignedPower(a, @intFromFloat(@abs(n)));
        if (n > 0.0) return raised;
        return Interval.init(1.0, 1.0).div(raised);
    }
    return narrow(certified.exp(certified.mul(pointOf(n), certified.log(widen(a)))));
}

/// The exponential, rising over all of the reals.
pub fn exp(x: Interval) Interval {
    return narrow(certified.exp(widen(x)));
}

/// The exponential to base two, rising over all of the reals.
pub fn exp2(x: Interval) Interval {
    return narrow(certified.exp2(widen(x)));
}

/// The exponential less one, which keeps its precision near zero and is
/// rising over all of the reals.
pub fn expm1(x: Interval) Interval {
    return narrow(certified.expm1(widen(x)));
}

/// The natural logarithm, or null when the interval reaches no positive
/// number.
///
/// A lower end at or below zero is not merely small: the argument then runs
/// arbitrarily close to zero, and the logarithm of that runs arbitrarily
/// far down, which no finite bound holds. That end is `-inf` by that
/// argument and by no computation, so only the far end is evaluated here.
pub fn log(x: Interval) ?Interval {
    if (x.hi <= 0.0) return null;
    if (x.lo <= 0.0) return Interval.init(-inf, unboundedEnd(narrow(certified.log(pointOf(x.hi)))));
    return narrow(certified.log(widen(x)));
}

/// The logarithm to base two, or null when the interval reaches no
/// positive number, with the same unbounded lower end for the same reason.
pub fn log2(x: Interval) ?Interval {
    if (x.hi <= 0.0) return null;
    if (x.lo <= 0.0) return Interval.init(-inf, unboundedEnd(narrow(certified.log2(pointOf(x.hi)))));
    return narrow(certified.log2(widen(x)));
}

/// The logarithm to base ten, or null when the interval reaches no
/// positive number, with the same unbounded lower end for the same reason.
pub fn log10(x: Interval) ?Interval {
    if (x.hi <= 0.0) return null;
    if (x.lo <= 0.0) return Interval.init(-inf, unboundedEnd(narrow(certified.log10(pointOf(x.hi)))));
    return narrow(certified.log10(widen(x)));
}

/// One plus the interval, then its logarithm, which is why the domain
/// stops one below zero rather than at it. A lower end at or under -1 puts
/// the argument at zero, where the value runs off to minus infinity, and
/// everything below is off the domain entirely.
pub fn log1p(x: Interval) ?Interval {
    if (x.hi <= -1.0) return null;
    if (x.lo <= -1.0) return Interval.init(-inf, unboundedEnd(narrow(certified.log1p(pointOf(x.hi)))));
    return narrow(certified.log1p(widen(x)));
}

/// The end that survives when the other end has run off to minus infinity.
/// Written once so that the four logarithmic answers cannot disagree about
/// which end of the enclosure carries the pole.
fn unboundedEnd(reached: Interval) f64 {
    return reached.hi;
}

/// The arc sine, rising over `[-1, 1]`.
///
/// **The argument is clipped to the domain rather than refused.** `null` is
/// therefore the answer exactly when the true image is empty in the reals,
/// which is when the whole box lies outside `[-1, 1]`. `asin([-4, 0.5])`
/// has the true image `[-pi/2, asin(0.5)]`, and a refusal there would
/// throw away a real answer to buy a tidier rule. Clipping is what `sqrt`,
/// `log*` and `acosh` already do, and it costs the caller nothing.
///
/// The domain is closed, so a clipped end is the endpoint itself rather
/// than a pole: `asin(-1)` is a finite `-pi/2` and nothing here runs off
/// to an infinity.
pub fn asin(x: Interval) ?Interval {
    const lo = @max(x.lo, -1.0);
    const hi = @min(x.hi, 1.0);
    // The clip is empty exactly when the argument misses the domain whole.
    if (lo > hi) return null;
    return narrow(certified.asin(widen(Interval.init(lo, hi))));
}

/// The arc cosine, falling where the arc sine rises, over the same closed
/// domain and on the same clipping rule. It falls, so the lower end of the
/// image is the kernel's evaluation at the upper end of the argument, which
/// is the kernel's own business and not a swap here.
pub fn acos(x: Interval) ?Interval {
    const lo = @max(x.lo, -1.0);
    const hi = @min(x.hi, 1.0);
    if (lo > hi) return null;
    return narrow(certified.acos(widen(Interval.init(lo, hi))));
}

/// The arc tangent, rising over all of the reals.
pub fn atan(x: Interval) Interval {
    return narrow(certified.atan(widen(x)));
}

/// The angle from the positive x axis to the point (x, y).
///
/// The quadrants are settled before any division, so that a zero in `x`
/// lands in a case of its own instead of turning the quotient into
/// something undefined. What is left divides by a box away from zero and
/// rises with the quotient, which the certified arc tangent then carries
/// out, and is reflected against the certified bounds on pi.
///
/// A box of arguments describes a sweep and not a point, and the sweep is
/// what is answered: a box whose `x` reaches zero from above and whose `y`
/// is positive covers the first and second quadrants, so the answer runs
/// from zero to pi rather than sitting on `pi/2`. That is the enclosure of
/// the image of the box, and it is wider than a point argument deserves
/// precisely because the box is not a point.
pub fn atan2(y: Interval, x: Interval) Interval {
    if (x.hi < 0.0) {
        if (y.contains(0.0)) {
            // The point swings across the negative x axis, where the angle
            // jumps from -pi to pi, so the range is the whole.
            return Interval.init(-rounding.piUp(), rounding.piUp());
        }
        // Reflection into the first quadrant, where the angle runs from
        // pi/2 to pi or from -pi down to -pi/2. Negating both ends exactly,
        // rather than going through `abs`, keeps the reflected interval
        // clear of zero even at the smallest magnitudes.
        const r = atan(certifiedQuotient(y, Interval.init(-x.hi, -x.lo)));
        if (y.lo > 0.0) return piInterval().sub(r);
        return Interval.init(-rounding.piUp(), -rounding.piDown()).sub(r);
    }
    if (x.lo > 0.0) return atan(certifiedQuotient(y, x));
    // The point swings across the positive x axis on one side of the
    // origin, and the angles it passes reach the axes without crossing
    // them, so the answer is a half-turn rather than a quadrant.
    if (y.contains(0.0)) return Interval.init(-rounding.piUp(), rounding.piUp());
    if (y.lo > 0.0) return Interval.init(0.0, rounding.piUp());
    return Interval.init(-rounding.piUp(), 0.0);
}

/// The quotient of two boxes, in the kernel arithmetic. Both boxes reach
/// clear of zero here: the quadrant split above has already answered the
/// cases where either of them does not.
fn certifiedQuotient(y: Interval, x: Interval) Interval {
    return narrow(certified.div(widen(y), widen(x)));
}

/// pi as an interval, between the two certified bounds. The nearest double
/// is below the true pi and its successor is above it, so a reflection
/// against this pair keeps the last bit on both sides; `rounding` owns the
/// claim and the step.
fn piInterval() Interval {
    return Interval.init(rounding.piDown(), rounding.piUp());
}

/// The hyperbolic sine, rising over all of the reals.
pub fn sinh(x: Interval) Interval {
    return narrow(certified.sinh(widen(x)));
}

/// The hyperbolic cosine, which is even and rising in the magnitude, so
/// the magnitude of the box is what it is applied to. That turns the rise
/// of the function into a plain monotone pattern, and it is why
/// `cosh([-2, 2])` and `cosh([0, 2])` answer the same pair of bounds
/// rather than two enclosures that merely overlap.
pub fn cosh(x: Interval) Interval {
    return narrow(certified.cosh(widen(x.abs())));
}

/// The hyperbolic tangent, rising over all of the reals.
pub fn tanh(x: Interval) Interval {
    return narrow(certified.tanh(widen(x)));
}

/// The inverse hyperbolic sine, rising over all of the reals.
pub fn asinh(x: Interval) Interval {
    return narrow(certified.asinh(widen(x)));
}

/// The inverse hyperbolic cosine, or null unless the box reaches one. What
/// lies below is not on the domain at all, and the function takes the value
/// zero exactly at the end of it, which is what clipping the near end to one
/// supplies.
pub fn acosh(x: Interval) ?Interval {
    if (x.hi < 1.0) return null;
    return narrow(certified.acosh(widen(Interval.init(@max(x.lo, 1.0), x.hi))));
}

/// The inverse hyperbolic tangent, rising over the OPEN interval
/// `(-1, 1)`.
///
/// **The argument is clipped to the domain rather than refused, and the pole
/// does what a pole does**: a clipped end sitting exactly on `±1` runs off
/// to the matching infinity. So `atanh([-2, -0.5])` answers `[-inf,
/// atanh(-0.5)]`, and an argument spanning the whole domain answers the
/// whole line.
///
/// One shape stays `null` that a closed-domain clip would have accepted: an
/// argument whose only overlap with the domain is the endpoint `±1` itself,
/// such as `atanh([1, 2])`. Its true image really is empty, because `1` is
/// not in `(-1, 1)`, and answering `[floatMax, +inf]` for it would be a
/// bound of nothing wearing an interval's clothes. So the emptiness test is
/// two-sided — the clip must still reach a point strictly inside — and not
/// `lo <= hi`.
///
/// A clipped end ON the pole is moved one representable step inside before
/// the kernel sees it and the infinite end is attached here, so the kernel
/// is never asked to divide by zero and the answer at the pole is this
/// file's own argument rather than whatever a kernel returns there.
pub fn atanh(x: Interval) ?Interval {
    const lo = @max(x.lo, -1.0);
    const hi = @min(x.hi, 1.0);
    if (lo > hi) return null;
    // The domain is open, so a clip that reaches no further than the
    // endpoint from inside it overlaps nothing at all.
    if (hi <= -1.0 or lo >= 1.0) return null;
    const touches_low = lo <= -1.0;
    const touches_high = hi >= 1.0;
    const inside = narrow(certified.atanh(widen(Interval.init(
        if (touches_low) rounding.nextUp(-1.0) else lo,
        if (touches_high) rounding.prevDown(1.0) else hi,
    ))));
    if (touches_low) return Interval.init(-inf, inside.hi);
    if (touches_high) return Interval.init(inside.lo, inf);
    return inside;
}

/// The largest integer not above each end.
///
/// The image of a box under `floor` is exactly `[floor(lo), floor(hi)]`:
/// floor is monotone, so its smallest value over the box is at the lower
/// end and its largest at the upper one. Both ends are integers an f64
/// holds exactly, since IEEE 754 rounds them exactly, so nothing is
/// widened here — an enclosure of `{1, 2}` reporting `[0.99, 2.01]` would
/// be reporting bounds that are not the image.
pub fn floor(x: Interval) Interval {
    return Interval.init(@floor(x.lo), @floor(x.hi));
}

/// The smallest integer not below each end, on the same argument: ceil is
/// monotone too, and its image of a box is `[ceil(lo), ceil(hi)]` with both
/// ends exact.
pub fn ceil(x: Interval) Interval {
    return Interval.init(@ceil(x.lo), @ceil(x.hi));
}

/// Each end cut towards zero, which is monotone on the whole line, so the
/// image of a box is `[trunc(lo), trunc(hi)]` and both ends are exact.
pub fn trunc(x: Interval) Interval {
    return Interval.init(@trunc(x.lo), @trunc(x.hi));
}

/// Each end rounded to the nearest integer, with a tie going away from zero
/// as `@round` does.
///
/// Half away from zero is monotone ACROSS zero, which is what lets the two
/// ends be read separately: rounding half to even is not, since `2.5` goes
/// down and `-2.5` goes up in one case and the other way round in the
/// other. The image of a box is the interval between the two rounded ends,
/// and both of those are exact integers an f64 holds.
pub fn round(x: Interval) Interval {
    return Interval.init(@round(x.lo), @round(x.hi));
}