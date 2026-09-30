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
//! How much outward rounding it takes to get there is not the same
//! everywhere, and the two are not equally established. The algebraic
//! operations rest on the operations IEEE 754 defines as correctly
//! rounded, so the computed endpoint is within half a ULP of the true
//! one and a single outward step is a guarantee. The elementary
//! functions rest on primitives with no documented error bound; all of
//! them measured within about 1.1 ULP, so those results are widened by
//! two steps. That second figure is a margin taken from measurement, not
//! a proof of it — a rigorous guarantee there would need a correctly
//! rounded or verified implementation of each function, which this
//! library does not provide. `rounding.zig` and `interval_ext.zig` spell
//! both cases out.
//!
//! An elementary function whose domain is a proper part of the reals —
//! `sqrt`, `log`, `log2`, `log10`, `log1p`, `asin`, `acos`, `atanh`,
//! `acosh`, `powf` — returns `?Interval`, and null is its answer when the
//! argument reaches outside that domain. What null MEANS is not the same
//! for all of them, and the difference is deliberate. `sqrt`, `log`,
//! `log2`, `log10`, `log1p` and `acosh` clip a partly off-domain argument
//! and refuse only a wholly invalid one, so null there is the strong
//! claim: the true image is empty in the reals. `asin`, `acos`, `atanh`
//! and `powf` refuse as soon as ANY part of the argument leaves the
//! domain, so their null is a refusal to bound a partly valid image
//! rather than a statement that the image is empty.
//!
//! The functions defined over every real keep a plain `Interval` return,
//! so a caller that has established its argument is in the domain never
//! has to unwrap. Total is not the same as unbounded: `sin`, `cos`,
//! `atan` and `tanh` are real everywhere and bounded in range, and they
//! answer an enclosing box rather than a ray.
//!
//! The surface splits four ways:
//!
//!  * Algebraic operations are methods on `Interval`, because they read as
//!    a relation between two intervals: `a.hull(b)`, not `hull(a, b)`.
//!  * Elementary functions are free functions, because they lift a real
//!    argument into an interval and have no interval operand to be a
//!    method of. They appear both at the top level and under `ext`, so
//!    `sin(x)` and `ext.sin(x)` are the same call.
//!  * `Vec(n)` and `DynVec` are the n-dimensional forms of the same
//!    enclosure, for a box of intervals rather than a single one. They
//!    are two distinct types over one shared core, not an alias pair:
//!    `Vec(n)` fixes the dimension at comptime and stores the components
//!    inline, while `DynVec` takes the dimension at run time and owns a
//!    heap slice.
//!  * `lp` is the Fourier-Motzkin solver, which eliminates linear
//!    constraints over intervals and bounds the free variables.
//!
//! The imports are suffixed `_mod` so they cannot collide with the public
//! re-exports below: a file-scope `const ext` and a `pub const ext` are
//! the same declaration to Zig, and the second one is a hard error.

// Relative imports, valid because this file's module root directory is
// `src/`, so every sibling source file is in the tree.
const interval_mod = @import("interval.zig");
const ext_mod = @import("interval_ext.zig");
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

/// The elementary functions, as a namespace. Every member is also
/// re-exported at the top level of this module.
///
/// The members are listed one name at a time rather than the whole of
/// `interval_ext.zig` being aliased in under a single `pub const`, because
/// a module alias republishes every `pub` in the file it names. The twenty
/// private declarations over there — eleven free functions and nine
/// constants — are held back by the `fn` keyword and by nothing else, so
/// one over-broad `pub`, or one automated `pub` sweep over the file, would
/// hand all twenty to a dependent package with no compile error and no
/// failing test: a name that was never meant to be public has no test that
/// could fail. Here a name has to be written down to be reachable, and
/// `tests/interval_test.zig` checks this list against its own.
///
/// That is why the list is written twice rather than derived once. The two
/// spellings are a promise of this file — `sin(x)` and `ext.sin(x)` are
/// the same call — so a new function costs a line in each list, and a
/// forgotten one is a failing test instead of a quiet hole in one of them.
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
