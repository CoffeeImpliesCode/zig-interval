//! Public entry point of the package. A dependent package names this file
//! as the `interval` module and reaches everything below through
//! `@import("interval")`; nothing outside `src/` has to know how the files
//! behind it are laid out.
//!
//! Every operation here returns an enclosure: the interval contains the
//! true mathematical value of the expression it was asked about. Rounding
//! is directed outward, never inward, so a result is an enclosure rather
//! than an estimate. Width is a quality measure, not a correctness one. A
//! wider result is still correct; a narrower one that misses the true value
//! is not.
//!
//! The elementary functions no longer rest on measured error margins. Each
//! one is evaluated in outward `f128` interval arithmetic and carries an
//! explicit analytic remainder bound beside it, so the guarantee is a proof
//! at every primitive rather than a three-ULP cushion chosen from the worst
//! number a survey turned up. `src/certified.zig` holds those kernels and
//! the constants; it is deliberately NOT reachable from here, because an
//! internal helper is not part of the surface a reader may depend on.
//!
//! An elementary function whose domain is a proper part of the reals —
//! `sqrt`, `log`, `log2`, `log10`, `log1p`, `asin`, `acos`, `atanh`,
//! `acosh`, `powf` — returns `?Interval`, and can answer `null` when the
//! argument reaches outside that domain. Most of them clip a partly
//! off-domain argument and refuse only a wholly invalid one, so for those
//! null is the strong and exact claim: the true image is empty in the
//! reals. `sqrt([-4, 1])` is `[0, 1]` rather than refused. The distinction
//! is not convenience: empty is a mathematical statement and unbounded is
//! another, and `null` means the first.
//!
//! `powf` over a NEGATIVE base is the case that used to be refused
//! outright and is now answered, because it is a question about the
//! mathematics and the mathematics has cases. A finite non-integer `f64`
//! exponent is a dyadic rational, so a negative base raised to one whose
//! reduced denominator is even has no real value at all and is still
//! refused — but an exact INTEGER exponent is a real power of a negative
//! base, and an exponent interval of positive width contains dyadic
//! rationals of both numerator parities, whose images together enclose
//! `-|base|`^y through `+|base|`^y. `powf(-1, [1, 2])` therefore encloses
//! both `-1` and `+1`. An exact rational exponent is the unambiguous way
//! to ask, and `ext.powRational` takes one.
//!
//! The functions defined over every real keep a plain `Interval` return,
//! so a caller that has established its argument is in the domain never
//! has to unwrap. Total is not the same as unbounded: `sin`, `cos`,
//! `atan` and `tanh` are real everywhere and bounded in range, and they
//! answer an enclosing box rather than a ray.
//!
//! The surface splits into these layers, each enumerated by name below:
//!
//!  * `Interval` carries algebraic operations as METHODS, because they read
//!    as a relation between two intervals: `a.hull(b)`, not `hull(a, b)`.
//!  * `ext` is the scalar catalogue of elementary, real, special and
//!    exact-rational functions. Every member is also a flat alias here, so
//!    `sin(x)` and `ext.sin(x)` are the same call. `gamma` and `factorial`
//!    are `ext.gamma` and `ext.factorial`: they are ordinary scalar
//!    functions of a real argument, and there is no `special` namespace
//!    holding them separately.
//!  * `trig` is the four-geometry trigonometric surface: four geometries,
//!    six functions, and three questions per pair — the forward value, the
//!    principal inverse, and the whole inverse FAMILY, which for an
//!    infinite family carries a formula for every branch rather than a
//!    list of samples.
//!  * `Truth` and `Tracked` are the three-valued layer. A `Truth` is an
//!    ENCLOSURE of the Boolean outcomes an expression may have: `always`,
//!    `never`, and `maybe`, which means mixed or merely not yet pinned down
//!    and never claims to have proved which. A `Tracked` pairs a range with
//!    a `defined` truth and a `continuous` one, so an answer can say which
//!    values it may take, whether it exists at all, and whether it is
//!    continuous — questions an `Interval` alone cannot answer, because an
//!    `Interval` has no way to say that it is a hull of a partly
//!    off-domain argument.
//!  * `branches` carries BRANCH IDENTITY: caller-owned maps of site to
//!    choice, and producers that split one box into the alternatives a
//!    single cell of it can reach. It exists so that a caller can keep
//!    `floor([0.9, 1.1])` as `{0, 1}` instead of the `[0, 1]` hull, and can
//!    then combine only the pieces that agree on the branch they came from.
//!  * `Complex` and `complex` are the complex layer: arithmetic over
//!    enclosures in the plane, the elementary functions with the branch
//!    cuts they actually carry, and the selected-sheet and full-family
//!    forms of the multivalued inverses.
//!  * `Vec(n)` and `DynVec` are the n-dimensional forms of the same
//!    enclosure, for a box of intervals rather than a single one. They are
//!    two distinct types over one shared core, not an alias pair:
//!    `Vec(n)` fixes the dimension at comptime and stores the components
//!    inline, while `DynVec` takes the dimension at run time and owns a
//!    heap slice.
//!  * `lp` is the Fourier-Motzkin solver, which eliminates linear
//!    constraints over intervals and bounds the free variables. Its
//!    comparisons are closed outer relaxations, so an unsatisfiable verdict
//!    is proof and a satisfiable one is not proof of feasibility; the
//!    scalar `Tracked` comparisons are where exact strictness lives.
//!
//! Every namespace here is enumerated one name at a time rather than
//! aliased in under a single `pub const`. A module alias republishes every
//! `pub` in the file it names, so one over-broad `pub` upstream — or one
//! automated sweep adding it — would hand a dependent package a name that
//! was never meant to be public, with no compile error and no failing test:
//! a name nobody intended has no test that could fail. Written down, a name
//! has to be reachable to be public at all.
//!
//! The imports are suffixed `_mod` so they cannot collide with the public
//! re-exports below: a file-scope `const ext` and a `pub const ext` are
//! the same declaration to Zig, and the second one is a hard error.

// Relative imports, valid because this file's module root directory is
// `src/`, so every sibling source file is in the tree. `certified.zig` is
// imported by the files that use it and by nothing here, on purpose.
const interval_mod = @import("interval.zig");
const ext_mod = @import("interval_ext.zig");
const real_mod = @import("real.zig");
const special_mod = @import("special.zig");
const trig_mod = @import("trig.zig");
const truth_mod = @import("truth.zig");
const tracked_mod = @import("tracked.zig");
const branches_mod = @import("branches.zig");
const complex_mod = @import("complex.zig");
const vector_mod = @import("vector.zig");
const lp_mod = @import("lp.zig");
const rounding_mod = @import("rounding.zig");

/// The closed interval [lo, hi] over `f64`, the package's core type.
pub const Interval = interval_mod.Interval;

/// A box in the dimension `n` fixed at compile time, components inline.
/// It is a generic function rather than a type, so it is written
/// `Vec(3)`.
pub const Vec = vector_mod.Vec;

/// A box whose dimension is known only at run time, owning its component
/// slice. Distinct from `Vec(n)`, which it shares an implementation with
/// rather than a definition.
pub const DynVec = vector_mod.DynVec;

/// Apply a scalar `fn (Interval) ?Interval` to every component of a box,
/// returning the mapped box, or null as soon as one component leaves the
/// domain of `f`. This is the bridge to the elementary functions, whose
/// scalar shape is the one that reports the empty case.
pub const mapResult = vector_mod.mapResult;

/// Smallest `f64` strictly greater than the argument, the outward-rounding
/// step of the library.
pub const nextUp = rounding_mod.nextUp;

/// Largest `f64` strictly less than the argument.
pub const prevDown = rounding_mod.prevDown;

/// Lower bound on pi, for certified range reduction.
pub const piDown = rounding_mod.piDown;

/// Upper bound on pi, for certified range reduction.
pub const piUp = rounding_mod.piUp;

/// Smallest `f64` greater than or equal to the argument. This is the
/// outward-rounding upper bound: use it for every computed upper bound of
/// an interval result. It agrees with `nextUp` at both infinities and at
/// every finite nonzero value, and differs from it only at the pair of
/// signed zeros, where a zero is already its own smallest bound:
/// `roundUp(-0.0)` is `-0.0` and `nextUp(-0.0)` is `+0.0`, the zero of
/// the other sign. At -inf both answer -floatMax, which is above the
/// finite real a computed -inf stands for, so a bound of -inf would drop
/// that real.
pub const roundUp = rounding_mod.roundUp;

/// Largest `f64` less than or equal to the argument. This is the
/// outward-rounding lower bound: use it for every computed lower bound of
/// an interval result. It agrees with `prevDown` at both infinities and
/// at every finite nonzero value, and differs from it only at the pair of
/// signed zeros, where `roundDown(+0.0)` is `+0.0` and `prevDown(+0.0)`
/// is `-0.0`. At +inf both answer +floatMax, below the finite real a
/// computed +inf stands for, so a bound of +inf would drop that real. At
/// -inf both answer -inf, which is below every real and so is already
/// the bound.
pub const roundDown = rounding_mod.roundDown;

/// The scalar catalogue of elementary, exact-rational and special
/// functions, as a namespace. Every member is also re-exported at the top
/// level of this module, so `sin(x)` and `ext.sin(x)` are the same call.
///
/// The members are listed one name at a time rather than the whole of
/// `interval_ext.zig` being aliased in under a single `pub const`, because
/// a module alias republishes every `pub` in the file it names. The
/// declarations a file keeps to itself are held back by the `fn` keyword
/// and by nothing else, so one over-broad `pub`, or one automated `pub`
/// sweep over the file, would hand them to a dependent package with no
/// compile error and no failing test. Here a name has to be written down to
/// be reachable at all.
///
/// `gamma` and `factorial` are members here rather than a `special`
/// namespace of their own. Both are functions of a real argument in
/// exactly the way `sin` is, so a second catalogue holding them would
/// give a dependent package two spellings to choose between and no
/// mathematical reason to prefer either.
pub const ext = struct {
    pub const sqrt = ext_mod.sqrt;
    pub const cbrt = ext_mod.cbrt;
    pub const pow = ext_mod.pow;
    pub const powf = ext_mod.powf;
    pub const exp = ext_mod.exp;
    pub const exp2 = ext_mod.exp2;
    pub const expm1 = ext_mod.expm1;
    pub const log = ext_mod.log;
    pub const log2 = ext_mod.log2;
    pub const log10 = ext_mod.log10;
    pub const log1p = ext_mod.log1p;
    pub const sin = ext_mod.sin;
    pub const cos = ext_mod.cos;
    pub const tan = ext_mod.tan;
    pub const asin = ext_mod.asin;
    pub const acos = ext_mod.acos;
    pub const atan = ext_mod.atan;
    pub const atan2 = ext_mod.atan2;
    pub const sinh = ext_mod.sinh;
    pub const cosh = ext_mod.cosh;
    pub const tanh = ext_mod.tanh;
    pub const asinh = ext_mod.asinh;
    pub const acosh = ext_mod.acosh;
    pub const atanh = ext_mod.atanh;
    pub const floor = ext_mod.floor;
    pub const ceil = ext_mod.ceil;
    pub const trunc = ext_mod.trunc;
    pub const round = ext_mod.round;

    // The two directed tie roundings. `round` above is half AWAY FROM
    // ZERO, which is what a decimal half is expected to take and is
    // neither of these: at -2.5 the three disagree, so a caller whose
    // ties run one way says so rather than discovering it.
    pub const roundTiesUp = real_mod.roundTiesUp;
    pub const roundTiesDown = real_mod.roundTiesDown;

    // Exact rational powers and roots. A base raised to an exact RATIONAL
    // exponent has one answer, where `powf` takes a real exponent and has
    // to enclose every rational inside it: (-8)^(1/3) is -2, and the f64
    // nearest to 1/3 is not 1/3, so `powf` cannot be told apart from a
    // root of something slightly else. `Rational` carries the exponent as
    // a pair of integers.
    pub const powRational = real_mod.powRational;
    pub const nthRoot = real_mod.nthRoot;

    // The logarithm to an arbitrary base, BASE FIRST, so that a logarithm
    // reads the way the identity does: `log_b x`. A base in (0,1) and a
    // base above 1 are both real logarithms and neither is dropped.
    pub const logBase = real_mod.logBase;

    // Order statistics over a caller-owned slice with a caller-owned
    // scratch buffer: this layer allocates nothing, so a caller who does
    // not want a heap block behind a statistic supplies the space for it.
    // A rank is ONE-BASED and integer-valued, and a rank outside 1..xs.len
    // is not a rank at all rather than a number the library rounds to one.
    pub const min = real_mod.min;
    pub const max = real_mod.max;
    pub const median = real_mod.median;
    pub const nthSmallest = real_mod.nthSmallest;
    pub const nthLargest = real_mod.nthLargest;

    // The mathematical sign, a three-valued answer where an interval test
    // is a two-valued one: `sgn([-1, 1])` is `[-1, 1]`, and the sign is
    // exactly zero throughout a neighborhood of zero.
    pub const sgn = real_mod.sgn;

    // The positive remainder, modulus by magnitude, so a negative
    // argument leaves on the same side as its divisor. A zero modulus has
    // no remainder.
    pub const mod = real_mod.mod;

    // N-ary greatest common divisor and least common multiple over REAL
    // arguments. Over intervals these are the dyadic facts — odd
    // mantissas, binary exponents — widened to enclose every commensurable
    // real answer, because a box of reals has no single greatest common
    // divisor and the alternative to enclosing them all is refusing.
    pub const gcd = real_mod.gcd;
    pub const lcm = real_mod.lcm;

    // The real Gamma function and the DISCRETE factorial. The domain of
    // `n!` is the non-negative integers and not a subset of the reals, so
    // `factorial` is the one answer here whose argument is a question
    // about membership rather than about a range.
    pub const gamma = special_mod.gamma;
    pub const factorial = special_mod.factorial;
};

/// The Fourier-Motzkin solver, as a namespace over the five names it
/// publishes, enumerated for the reason given on `ext` above: aliased to
/// the whole file it would also republish lp's private free functions and
/// private types, held back by their `fn` and nothing else. The private
/// methods on `System` are named by neither, since the `fn` on the method
/// is what keeps those back, and enumerating a namespace neither adds nor
/// removes them.
///
/// `Part` and `Partition` are here because a type a `pub` method returns
/// has to be nameable by whoever calls that method: `System.partition`
/// hands back a `Partition`, and `bench_lp.zig` reads its `carried`,
/// `lower` and `upper`. A name that is not listed is unreachable from
/// outside, which is the point of the list and also its cost.
pub const lp = struct {
    pub const System = lp_mod.System;
    pub const Lin = lp_mod.Lin;
    pub const Cmp = lp_mod.Cmp;
    pub const Part = lp_mod.Part;
    pub const Partition = lp_mod.Partition;
};

// ---------------------------------------------------------------------------
// The four-geometry trigonometric surface.
// ---------------------------------------------------------------------------

/// Four geometries x six functions, and the three questions one can ask of
/// each pair.
///
/// The two polygons are the point of this namespace, so they are stated
/// rather than left to a reader's guess. The radial angle is in RADIANS,
/// and with `s = sin(theta)` and `c = cos(theta)` the diamond point is
/// `(c, s) / (|c| + |s|)` while the square point is
/// `(c, s) / max(|c|, |s|)`. Tangent and cotangent are the circular ratios
/// in every geometry; the reciprocals are reciprocals. Nothing here is a
/// claim about what any other program draws, and the principal inverses
/// are the continuous ones on the branch each name names:
/// `arcsin` of the diamond is `sign(y) * atan(|y| / (1 - |y|))` with
/// endpoints at +/- pi/2, and of the square is `atan(y)` over [-1, 1].
///
/// `inverseFamily` is the whole relation, not a list that stops. Where the
/// relation is infinite the family carries a formula valid for every
/// integer branch, and `at` samples it; where it is finite —
/// the hyperbolic `cosh` and `sech` inverses, which have a plus and a minus
/// branch — `branchCount` is a number. A square plateau at `y = +/-1` is
/// an entire interval of angles, and `at` returns that interval rather
/// than one end of it and a claim of completeness.
pub const trig = struct {
    pub const Geometry = trig_mod.Geometry;
    pub const Function = trig_mod.Function;
    pub const Family = trig_mod.Family;
    pub const forward = trig_mod.forward;
    pub const principalInverse = trig_mod.principalInverse;
    pub const inverseFamily = trig_mod.inverseFamily;
};

// ---------------------------------------------------------------------------
// Three-valued truth.
// ---------------------------------------------------------------------------

/// An ENCLOSURE of the Boolean outcomes an expression may have: `always`,
/// `never`, or `maybe`.
///
/// `maybe` is deliberately one state and not two. It means the outcomes are
/// not pinned down — which may be because they really are mixed, or
/// because the enclosure is too wide to tell — and this type never claims
/// to have proved which. The operations on it are set operations over the
/// outcomes: `join` is the UNION of two outcome sets and is not a logical
/// or, so `join(always, never)` is `maybe`, the one value that can be
/// right about two pieces of knowledge that contradict each other.
pub const Truth = truth_mod.Truth;

// ---------------------------------------------------------------------------
// Tracked scalars.
// ---------------------------------------------------------------------------

/// A range paired with what is known about whether it exists and whether it
/// is continuous.
///
/// `range` is null exactly when `defined` is `never`, and an absent answer
/// carries no interval at all: a hull standing in for a value that does
/// not exist would be a number the caller could draw. Continuity is a
/// SEPARATE question from definedness because the two come apart — over
/// `[-1, 1]` the square root is partly defined and not continuous, and
/// over a box that cancels against itself a result can be perfectly
/// continuous even though each operand was not.
pub const Tracked = tracked_mod.Tracked;

/// The tracked form of the whole scalar catalogue, under the same names
/// and the same parameter orders as `ext`, with `Interval` replaced by
/// `Tracked` and `?Interval` by `Tracked`.
///
/// There is no optional here even where `ext` has one, because absence is
/// not a separate outcome here — it is `defined = never`, which a tracked
/// value states directly and which an unwrapped `null` would throw away.
/// Every elementary function is also a `Tracked` method, so a chain reads
/// as one expression.
///
/// The scratch-buffer failures stay explicit: `median`, `nthSmallest` and
/// `nthLargest` return `error.InsufficientScratch` rather than quietly
/// allocating behind a caller who supplied the space on purpose.
pub const tracked = struct {
    /// The tracked value type itself, so that `tracked.Tracked` and the
    /// flat `Tracked` are one declaration rather than two spellings that
    /// could drift apart.
    pub const Tracked = tracked_mod.Tracked;
    /// The six scalar relations, in the order `compare` takes them. This
    /// is the enumeration a tracked comparison uses; `Interval.eql` and its
    /// neighbours are not, because those are two-valued tests on boxes and
    /// a box comparison is not a scalar one.
    pub const Cmp = tracked_mod.Cmp;
    /// The tracked inverse family: `at(branch)` and `branchCount()`, where
    /// a null count is an infinite family rather than a missing one.
    pub const Family = tracked_mod.Family;

    // The algebraic operations, as functions as well as methods, so a
    // caller holding two tracked values in variables can write the relation
    // without having to repeat which of the two is the receiver.
    pub const add = tracked_mod.add;
    pub const sub = tracked_mod.sub;
    pub const mul = tracked_mod.mul;
    pub const div = tracked_mod.div;
    pub const recip = tracked_mod.recip;
    pub const neg = tracked_mod.neg;
    pub const abs = tracked_mod.abs;
    pub const sqr = tracked_mod.sqr;
    pub const sqrt = tracked_mod.sqrt;
    pub const cbrt = tracked_mod.cbrt;
    pub const pow = tracked_mod.pow;
    pub const powf = tracked_mod.powf;
    pub const exp = tracked_mod.exp;
    pub const exp2 = tracked_mod.exp2;
    pub const expm1 = tracked_mod.expm1;
    pub const log = tracked_mod.log;
    pub const log2 = tracked_mod.log2;
    pub const log10 = tracked_mod.log10;
    pub const log1p = tracked_mod.log1p;
    pub const sin = tracked_mod.sin;
    pub const cos = tracked_mod.cos;
    pub const tan = tracked_mod.tan;
    pub const asin = tracked_mod.asin;
    pub const acos = tracked_mod.acos;
    pub const atan = tracked_mod.atan;
    pub const atan2 = tracked_mod.atan2;
    pub const sinh = tracked_mod.sinh;
    pub const cosh = tracked_mod.cosh;
    pub const tanh = tracked_mod.tanh;
    pub const asinh = tracked_mod.asinh;
    pub const acosh = tracked_mod.acosh;
    pub const atanh = tracked_mod.atanh;
    pub const floor = tracked_mod.floor;
    pub const ceil = tracked_mod.ceil;
    pub const trunc = tracked_mod.trunc;
    pub const round = tracked_mod.round;
    pub const roundTiesUp = tracked_mod.roundTiesUp;
    pub const roundTiesDown = tracked_mod.roundTiesDown;
    pub const powRational = tracked_mod.powRational;
    pub const nthRoot = tracked_mod.nthRoot;
    pub const logBase = tracked_mod.logBase;
    pub const min = tracked_mod.min;
    pub const max = tracked_mod.max;
    pub const median = tracked_mod.median;
    pub const nthSmallest = tracked_mod.nthSmallest;
    pub const nthLargest = tracked_mod.nthLargest;
    pub const sgn = tracked_mod.sgn;
    pub const mod = tracked_mod.mod;
    pub const gcd = tracked_mod.gcd;
    pub const lcm = tracked_mod.lcm;
    pub const gamma = tracked_mod.gamma;
    pub const factorial = tracked_mod.factorial;

    /// Choose between two tracked values on a three-valued condition.
    ///
    /// A condition that is already known selects one arm outright, so an
    /// undefined arm that was not taken does not poison the answer. A
    /// condition that is `maybe` hulls what the two arms could give and
    /// combines what is known about them conservatively, because that is
    /// all a hull of two undecided answers can honestly say.
    pub const select = tracked_mod.select;

    // The tracked trigonometric surface. Its geometry and function
    // arguments come from `trig` rather than from here, so there is one
    // `Geometry` in this library and a tracked call cannot be handed an
    // untagged one by accident.
    pub const forward = tracked_mod.forward;
    pub const principalInverse = tracked_mod.principalInverse;
    pub const inverseFamily = tracked_mod.inverseFamily;
};

// ---------------------------------------------------------------------------
// Branch identity.
// ---------------------------------------------------------------------------

/// An exact rational exponent, as a pair of integers with a positive
/// denominator.
///
/// The fields are the exact value and not a rounding of it: `denominator`
/// is a `u64` because the sign lives entirely in `numerator`, and `init`
/// reduces by the exact gcd rather than by a floating-point division that
/// would report a reduced pair it could not be sure of. A `powf` argument
/// cannot carry this — 1/3 has no exact f64 — which is the whole reason
/// this type exists.
pub const Rational = real_mod.Rational;

/// Branch maps, sets and the producers that split a box into alternatives.
///
/// This namespace exists for one reason: a hull destroys the mathematics
/// it is a hull of. `floor([0.9, 1.1])` is the two values 0 and 1, and
/// `[0, 1]` is a statement about a continuous interval that happens to
/// contain them. `1/x` over `[-1, 1]` is two rays and not all of R. Once
/// two alternatives share a site, only the pairings that AGREE on that
/// site may be combined, which is the correlation a single interval has
/// no way to carry.
///
/// A `Site` is the caller's own integer, naming the same operator on the
/// same arguments in the same evaluation, and a `Choice` is an `i128` and
/// not a bit, because a cell label is often a value: the floor of a box is
/// labelled by the integer it floored to. Nothing here allocates; every
/// buffer is the caller's, a producer that runs out of room fails with
/// `CapacityExceeded` and leaves its writer exactly as it found it, and an
/// empty result is a set with no pieces rather than an error. The library
/// never merges or hulls alternatives on the caller's behalf — losing a
/// correlation is a decision, and a caller who wants one asks for it.
pub const branches = struct {
    pub const Site = branches_mod.Site;
    pub const Choice = branches_mod.Choice;
    pub const Assignment = branches_mod.Assignment;
    pub const Piece = branches_mod.Piece;
    pub const Set = branches_mod.Set;
    pub const Writer = branches_mod.Writer;
    pub const Error = branches_mod.Error;

    pub const compatible = branches_mod.compatible;
    pub const merge = branches_mod.merge;
    pub const compare = branches_mod.compare;

    // The lifting seams. `mapUnary` and `mapBinary` carry a pure callback
    // over a typed value, and `mapSplit` carries one that writes several
    // pieces, which is the extension point for a function the library does
    // not have: the caller supplies the mathematics and the metadata, and
    // the branch machinery still merges the incoming maps.
    pub const mapUnary = branches_mod.mapUnary;
    pub const mapBinary = branches_mod.mapBinary;
    pub const mapSplit = branches_mod.mapSplit;

    // The real producers. Each keeps the assignments its input already
    // carried and adds its own cut, so a cell the caller reached earlier
    // is still the cell it is in after the split.
    pub const leaf = branches_mod.leaf;
    pub const recip = branches_mod.recip;
    pub const div = branches_mod.div;
    pub const tan = branches_mod.tan;
    pub const floor = branches_mod.floor;
    pub const ceil = branches_mod.ceil;
    pub const trunc = branches_mod.trunc;
    pub const round = branches_mod.round;
    pub const roundTiesUp = branches_mod.roundTiesUp;
    pub const roundTiesDown = branches_mod.roundTiesDown;
    pub const sgn = branches_mod.sgn;
    pub const plusMinus = branches_mod.plusMinus;
    pub const powRational = branches_mod.powRational;
    pub const inverseTrig = branches_mod.inverseTrig;
    pub const mod = branches_mod.mod;
};

// ---------------------------------------------------------------------------
// The complex layer.
// ---------------------------------------------------------------------------

/// An enclosure in the plane: a real box and an imaginary box, each
/// possibly absent, with the same definedness and continuity metadata a
/// `Tracked` carries.
///
/// The two coordinates are INDEPENDENT enclosures and stay that way. The
/// image of a complex function is not in general the product of the images
/// of its coordinates — that would be a box a function may never take any
/// point of — and `i * i` answering `[-1, -1] + 0i` rather than a box that
/// reaches into the reals is the difference this layer exists to preserve.
pub const Complex = complex_mod.Complex;

/// The complex elementary functions, the branch cuts they carry, and the
/// producers that keep the alternatives of a cut apart.
///
/// `log` and `pow` are PRINCIPAL: the argument of a principal logarithm
/// lies in `(-pi, pi]`, and an exact negative-real point answers with
/// `+pi` rather than being dropped. That choice is a convention and it is
/// stated here because a caller who needs a different one needs
/// `logSheet(z, k)`, which adds `2*pi*i*k` to the principal answer and
/// takes any integer `k`.
///
/// The cuts are real, not decorative: an inverse is not analytic across
/// the negative real axis, and the answer on one side is not the answer on
/// the other. `principalLog` therefore returns BOTH sides of the cut as
/// separate pieces with separate labels, since a single box spanning them
/// would say the cut was not there.
pub const complex = struct {
    pub const Bounds = complex_mod.Bounds;
    pub const Complex = complex_mod.Complex;
    pub const LogFamily = complex_mod.LogFamily;
    pub const RootFamily = complex_mod.RootFamily;
    pub const Error = complex_mod.Error;

    pub const exp = complex_mod.exp;
    pub const log = complex_mod.log;
    pub const logSheet = complex_mod.logSheet;
    pub const sqrt = complex_mod.sqrt;
    pub const nthRoot = complex_mod.nthRoot;
    pub const root = complex_mod.root;
    pub const pow = complex_mod.pow;
    pub const powRational = complex_mod.powRational;
    pub const logFamily = complex_mod.logFamily;
    pub const rootFamily = complex_mod.rootFamily;
    pub const sin = complex_mod.sin;
    pub const cos = complex_mod.cos;
    pub const tan = complex_mod.tan;
    pub const csc = complex_mod.csc;
    pub const sec = complex_mod.sec;
    pub const cot = complex_mod.cot;
    pub const asin = complex_mod.asin;
    pub const acos = complex_mod.acos;
    pub const atan = complex_mod.atan;
    pub const acsc = complex_mod.acsc;
    pub const asec = complex_mod.asec;
    pub const acot = complex_mod.acot;
    pub const sinh = complex_mod.sinh;
    pub const cosh = complex_mod.cosh;
    pub const tanh = complex_mod.tanh;
    pub const csch = complex_mod.csch;
    pub const sech = complex_mod.sech;
    pub const coth = complex_mod.coth;
    pub const asinh = complex_mod.asinh;
    pub const acosh = complex_mod.acosh;
    pub const atanh = complex_mod.atanh;
    pub const acsch = complex_mod.acsch;
    pub const asech = complex_mod.asech;
    pub const acoth = complex_mod.acoth;

    pub const leaf = complex_mod.leaf;
    pub const principalLog = complex_mod.principalLog;
    pub const logSheets = complex_mod.logSheets;
    pub const roots = complex_mod.roots;
};

pub const sqrt = ext_mod.sqrt;
pub const cbrt = ext_mod.cbrt;
pub const pow = ext_mod.pow;
pub const powf = ext_mod.powf;
pub const exp = ext_mod.exp;
pub const exp2 = ext_mod.exp2;
pub const expm1 = ext_mod.expm1;
pub const log = ext_mod.log;
pub const log2 = ext_mod.log2;
pub const log10 = ext_mod.log10;
pub const log1p = ext_mod.log1p;
pub const sin = ext_mod.sin;
pub const cos = ext_mod.cos;
pub const tan = ext_mod.tan;
pub const asin = ext_mod.asin;
pub const acos = ext_mod.acos;
pub const atan = ext_mod.atan;
pub const atan2 = ext_mod.atan2;
pub const sinh = ext_mod.sinh;
pub const cosh = ext_mod.cosh;
pub const tanh = ext_mod.tanh;
pub const asinh = ext_mod.asinh;
pub const acosh = ext_mod.acosh;
pub const atanh = ext_mod.atanh;
pub const floor = ext_mod.floor;
pub const ceil = ext_mod.ceil;
pub const trunc = ext_mod.trunc;
pub const round = ext_mod.round;

// The flat spellings of the `ext` members above, and the reason the two
// lists exist rather than one derived from the other: `sin(x)` and
// `ext.sin(x)` are the same call, and that promise has to be written down
// twice to be a promise at all.
pub const roundTiesUp = real_mod.roundTiesUp;
pub const roundTiesDown = real_mod.roundTiesDown;
pub const powRational = real_mod.powRational;
pub const nthRoot = real_mod.nthRoot;
pub const logBase = real_mod.logBase;
pub const min = real_mod.min;
pub const max = real_mod.max;
pub const median = real_mod.median;
pub const nthSmallest = real_mod.nthSmallest;
pub const nthLargest = real_mod.nthLargest;
pub const sgn = real_mod.sgn;
pub const mod = real_mod.mod;
pub const gcd = real_mod.gcd;
pub const lcm = real_mod.lcm;
pub const gamma = special_mod.gamma;
pub const factorial = special_mod.factorial;
