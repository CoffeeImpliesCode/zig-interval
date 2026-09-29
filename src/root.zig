//! Public entry point of the package. A dependent package names this file
//! as the `interval` module and reaches everything below through
//! `@import("interval")`; nothing outside `src/` has to know how the files
//! behind it are laid out.
//!
//! The guarantee is one guarantee, and every operation here makes it: the
//! returned interval encloses the true mathematical value of the expression
//! it was asked about. Rounding is directed outward, never inward, so a
//! result is an enclosure rather than an estimate. Width is a quality
//! measure, not a correctness one. A wider result is still correct; a
//! narrower one that misses the true value is not.
//!
//! An elementary function whose domain is a proper part of the reals —
//! `sqrt`, `log`, `asin`, `powf` and the rest — returns `?Interval`, and a
//! null is the answer when the argument reaches outside that domain. Null
//! is not slack in the enclosure: it is a stronger claim, that no interval
//! bounds the result at all. The functions defined over every real keep a
//! plain `Interval` return, so a caller that has established its argument
//! is in the domain never has to unwrap.
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

/// The elementary functions, as a namespace. Every member is also
/// re-exported at the top level of this module.
pub const ext = ext_mod;

/// The Fourier-Motzkin solver.
pub const lp = lp_mod;

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
