# Next work — defects, plan, features, optimisations, and what is not being done

**Written for the session that picks this up cold.** Everything needed to act is
below, and nothing below needs a conversation with anyone who wrote it.

The one contract this library sells: over `f64`, **every operation returns a
result guaranteed to contain the true mathematical answer.** Obtained by
computing with IEEE round-to-nearest and widening each endpoint outward with
`rounding.roundDown` on the lower side and `rounding.roundUp` on the upper side
(`src/rounding.zig:156-185`). Soundness outranks every other consideration in
this document, including every optimisation in section 4 and every feature in
section 3.

Seven read-only audits ran over the tree, and three of the four top findings
were then reproduced by execution rather than argued from source. What follows
consolidates them. Two more defects were found after them, by the soundness
oracle rather than by an audit: **D17**, a hole in the one guarantee this
library sells, and **D18**, the reading of an infinite endpoint, which is
settled now and is item P8 in section 2. Line numbers were read on 2026-09-30;
if one has drifted, read the file rather than trusting the citation, and
correct this document in the same commit that touches the code.

Severity here means:

| Level | Meaning |
| --- | --- |
| **S1** | The contract is broken, or a caller is handed a recipe that breaks it. |
| **S2** | Memory unsafety, or a public entry point that cannot be used safely. |
| **S3** | A statement in the tree is false and misleads a reader about the guarantee. |
| **S4** | Coverage or dead weight. Not a wrong answer today; the reason a wrong answer survived. |

---

## 1. Defects, ranked by severity

Every row carries a state. **FIXED** means the repair is in the tree and the
paragraph under the row says what it bought; **OPEN** means the next session owns
it. **Every row is FIXED at this revision** — D10 and D11 were the last two, and
P6 and P7 own them. The proof column records whether the behaviour was
**executed** — the reproducer was run and produced the stated output — or
established from: **code**, which is decisive without running anything.

### 1.1 S1 — the contract

| id | sev | site | one-line statement | proof | state |
| --- | --- | --- | --- | --- | --- |
| **D1** | S1 | `src/interval.zig:91` | `div` had no counterpart to `cornerProduct` for `inf / inf`, so a quotient of infinite operands returned `[-nan, -nan]`, an interval that contains nothing. | execution | **FIXED** (P1) |
| **D2** | S1 | `src/vector.zig:179-186` | `normDistance` accumulated `d * d` in `f64` and returned a bare `@sqrt` with no outward step, undershooting the true distance in 3 % of random 2-D cases. | execution | **FIXED** (P2) |
| **D3** | S1 | `README.md:156-197` | The documented widening recipe for third-party arithmetic told callers to use `interval.prevDown` / `interval.nextUp`, which cut inward at the infinities. | code | **FIXED** (P3) |
| **D4** | S1 | `src/lp.zig:916` | The general branch of `combinedColumn` let a cancelling pair of products fall through to the outward widening, so a coefficient whose exact value is zero was stored as a subnormal straddle instead of the structural zero. | execution | **FIXED** (P4) |
| **D17** | S1 | `src/interval_ext.zig:167` | `tanh` reached 2.14 ULP out on the `std.math` primitive and `envelope` widened by two, so the returned enclosure **excluded** the true value. | execution, against an `f128` reference finer than `f64` | **FIXED** — the elementary step is three ULP |
| **D18** | S1 | four sites in `src/interval.zig`, two more reported and withdrawn | An operation forms one endpoint from an infinite operand, the result saturates to `floatMax` or to `-inf`, and the saturated value is then used as if it were the endpoint the operand really stands for. | execution, and the oracle's own frontier report | **FIXED** (P8) — the reading is settled and the constructor canonicalises the two overflow rays |

D1 through D4 came out of the audits. D17 and D18 were found afterwards by the
soundness oracle itself — D17 by a reference finer than `f64`, D18 by a sweep of
named infinite-endpoint shapes — which is the argument for reading the oracle
before changing anything. The paragraphs below are the record of why the code
looks the way it does, which is the only thing a later reader needs from a fixed
defect.

**D1 — `div` at infinite endpoints. FIXED (P1).** `mul` guards the `0 * inf` case
with `cornerProduct` (`src/interval.zig:31-38`), which answers an IEEE-invalid
corner with the sign-xor of the two operands and hands the reduction a real zero.
`div` applied the same four-corner argument with no such guard: the only NaN
source it excluded was the one the divisor check removed, and that check only
excludes a divisor *containing* zero. Two infinities divided to a NaN with no
zero anywhere, and the reduction reduced four NaNs to a NaN.

```zig
const inf = std.math.inf(f64);
const q = Interval.init(inf, inf).div(Interval.init(inf, inf));
// q.lo == -nan, q.hi == -nan
// q.contains(1.0) == false, although 1.0 IS in the true image
```

The repair is `cornerQuotient` (`:91`), called from all four corners (`:707-710`),
with a corner wider than a point settling the reduction on its own (`:713`). It
buys the whole line for an indeterminate corner, which is the answer `div`
already gave a zero divisor and the one its doc already promised. Three tests in
`tests/interval_test.zig` hold it, among them `div: infinite operands on both
sides give the whole line, not a NaN`. The test whose comment used to assert the
opposite of the truth still passes, and now says the right thing: `0 / inf` is a
defined zero, not an indeterminate, and is still exactly `[0, 0]`. The oracle
reports `0 skipped precondition` for `div` and `recip` where it used to report
2,040 and 2,163.

**D2 — `normDistance` undershoots. FIXED (P2).** The body computed
`squares += d * d` in `f64` and returned a bare `@sqrt`, round-to-nearest at the
accumulation and at the root, so each step could land half a ULP the wrong way
and the two errors added. Measured: 119,520 of 4,000,000 random 2-D cases came
back an `f64` strictly below the true distance, each by exactly 1 ULP. It now
widens every step with `roundUp` and nothing with `roundDown`, because a distance
is nonnegative and has no lower end to round (`src/vector.zig:179-186`), with
`squareBound` (`:133-150`) handling the underflow that the zero-if-and-only-if
promise depends on. The exact-equality assertions in the existing `distance`
tests became containment assertions against the `f128` reference, which is the
point: a test that pins the round-to-nearest value of a function whose contract
is a bound is pinning the wrong thing.

**D3 — the README widening recipe. FIXED (P3).** The README told callers
widening their own arithmetic to use `interval.prevDown` / `interval.nextUp`. The
strict pair is the wrong tool for building a bound: `nextUp(-0.0)` returns
`+0.0` and `prevDown(+0.0)` returns `-0.0`, so at the two signed zeros it hands
back a *different number* from the one it was given rather than a value at or
beyond it. Every endpoint inside `src/` uses the non-strict pair and never the
strict one. The README now publishes `roundDown` / `roundUp` as the pair,
demotes `nextUp` / `prevDown` to the strict neighbours they are, and says why in
one paragraph: the non-strict pair is a bound by definition, the strict pair is
a neighbour, and the two are bit-identical at the infinities and at every
finite non-zero value.

**A correction to the reasoning, kept because this kind of thing comes back.**
An earlier draft justified the recipe by claiming the strict pair "answers
`-inf` with `-floatMax`". That is false, and it is false of BOTH pairs:
`nextUp(-inf)` and `roundUp(-inf)` are both `-floatMax`, and `prevDown(+inf)`
and `roundDown(+inf)` are both `floatMax`. They differ only at the two signed
zeros, which is D8's fact. The recipe was still wrong to publish and is still
replaced; the reason was wrong, not the conclusion. `src/interval_ext.zig`
carried the same false claim in its own comment and no longer does.

**D4 — LP coefficient cancellation. FIXED (P4).** `combinedColumn`
special-cased an operand that is the *structural* exact zero precisely because
"letting the general form run on a structural zero would hand it to the outward
widening, which turns [0, 0] into a subnormal straddle". The general branch had
the same failure by another route: a cancelling pair of products arrived as two
widened intervals, their difference was widened again, and a coefficient whose
exact value is zero was stored as a straddling interval. The reproducer was a
2-variable system whose derived x coefficient cancels, giving
`bounds(0) == [-3002399751580332, 10.000000000000002]` where the true range is
`[0, 10]`: a spurious lower bound of −3.0 × 10¹⁵, a stored coefficient
contradicting the invariant the function's own doc comment asserts, and a
cascade — `isExactZero` reads a straddle as a two-sided constraint, so later
eliminations pair rows that share no variable at all.

The fix decides the cancellation **on the operands in `f128`**, the only sound
place to decide it: a product of two `f64` needs 106 significand bits, their
difference at most 107, and `f128` carries 113. `cancelsExactly`
(`src/lp.zig:916`) is the decision, and round 2 put a cheap `f64` pre-filter in
front of it so that only pairs which already agree pay for `f128`. Two
characterisation tests in `tests/lp_test.zig` hold it: a cancelling pair is
stored as the structural zero, and a cancelled row that constrains nothing
bounds nothing. The alternative — an operand-level pre-pass that recognises a
cancelling pattern without `f128` — was never specified and is still not ready
to implement; the measurement says the filtered version is affordable, so leave
it there.

**D17 — `tanh` returned an enclosure that excluded the true value. FIXED: the
elementary step is three ULP.** `std.math.tanh` reaches 2.1385 ULP out, and a
widening of two brings a bound back to the correctly rounded `f64` of the
answer and no further. At `x = 0.23139395412799124` the true value is
`0.227350673456281817160566003736656553566288365188421593478113`; the old `lo`,
`0x3fcd19d3ad9bf171`, sits **above** it, and the new `lo`, `0x3fcd19d3ad9bf170`,
below.

The step is three for every elementary function, not three for `tanh` alone,
because **the count is the auditable artefact**: one number, one place, one
table to check a new primitive against. A per-function rule would be a second,
narrower rule resting on the same samples, and one of those samples has just
been shown wrong about a member of its own family. The measured margins are
printed in `src/interval_ext.zig` with the argument bands they came from: `tanh`
2.14, `sinh` 1.75, `log` 1.50, `log10` 1.37, `log2` 1.22, `cosh` 1.10, `exp` 0.87,
`tan` 0.83, `log1p` 0.78, `sin` 0.77, `atan` 0.76, `cos` 0.74, `exp2` 0.50. Seven
primitives the file calls are not in that table at all, and saying so is part of
the claim.

**The trap, stated here because it decides how any future test of an elementary
function must be written: the nearest `f64` to that true value IS the bound the
old code returned.** A reference rounded to `f64` compares the defect with
itself and reports it sound, and will do so forever. A test needs a truth more
precise than the type the bound is expressed in. An `f128` reference does
suffice — `f128` resolution at 0.227 is 2⁻¹¹⁵ against a 3.8e-18 defect — but only
if it does not cancel: `std.math.exp(f128)` inside the naive identity
`(E-1)/(E+1)` cancels near zero and does not suffice. The full statement of the
trap, the reference that works, and the three tests now holding this line are in
`docs/tests-and-architecture-plan.md` §2, which owns them.

**D18 — four operations are not enclosures at an infinity, and two more were
reported wrongly. FIXED (P8).** `src/rounding.zig` states that a computed `+inf`
stands for a real `R` above `floatMax`, and a computed `-inf` for a real below
`-floatMax`. Under that reading an operation that forms one endpoint from an
infinite operand must treat the saturated value as the endpoint the operand
really stands for. Four of the six first reported here did not. The calls below
are written as the constructor stood when the finding was made — `Interval.init(inf,
inf)` is the overflow ray today, not the point it used to be — and they are kept
as reported so the finding stays checkable against the tree it was made in.

| op | call | answer | the real it leaves out |
| --- | --- | --- | --- |
| `add` | `Interval.init(inf, inf).add(Interval.init(-3, inf))` | `lo` AT `floatMax` | `R - 3`, and every real between it and `floatMax`. No `f64` lies in that gap — the ULP there is 2⁹⁷¹ — so nothing working in `f64` ever sees it, and the enclosure claim is about the reals |
| `translate` | `Interval.init(inf, inf).translate(-3.0)` | `lo` at `floatMax` | a shift is an add, so the same `R - 3` |
| `expand` | `Interval.init(inf, inf).expand(3.0)` | `lo` at `floatMax` | the margin comes off the low end, so `R - 3` is in the image. The precondition passes because the width of an unbounded interval is unbounded, so every finite margin does |
| `recip` | `Interval.init(inf, inf).recip()` | a subnormal pair around 0 | `1/1e310` is an ordinary `f64` inside the operand's own ray. The corner `1/inf` is zero in IEEE and the underflow repair then widens that zero to a subnormal, when the true corner is the ray `(0, 1/floatMax]` |

**Two of the six were wrong, and are withdrawn.** `sub`'s witness was
`Interval.init(inf, inf).sub(Interval.init(-inf, -inf))`, on the ground that
`R - S` can be zero. It cannot be: `R >= floatMax` and `S <= -floatMax` give
`R - S >= 2*floatMax`, and the answer that witness recorded already enclosed
that image. The real witness is the **same** ray against itself, whose image is
the whole line — either end can outrun the other by any amount — and which
aborted on the `inf - inf` corner instead of answering anything. `neg`'s witness
said `Interval.init(inf, inf).neg()` answers `[-inf, -inf]` and leaves out
everything below `-floatMax`. Under the canonical constructor `[+inf, +inf]` is
not a point, so the input is the overflow ray and its reflection is the ordinary
negative ray `[-inf, -floatMax]`, which is right; the finding only ever
described a shape `init` no longer hands back. Withdrawing them is what the
settled reading bought, not a retuning of the sweep.

**The decision, taken.** An infinite endpoint is a **ray**, and an infinity the
caller supplied is a **constructed** one rather than a computed one. `init`
asserts the caller's ordering **first** and then maps two endpoint pairs:
`(+inf, +inf)` to `[floatMax, +inf]` and `(-inf, -inf)` to `[-inf, -floatMax]`.
Nothing else in the constructor moved, and a finite call is stored field for
field. A **computed** infinity is untouched by this: `roundDown(+inf) = floatMax`
and `roundUp(-inf) = -floatMax` remain the outward bounds of a finite real the
format cannot hold.

**Why the constructor change was enough, and it is not "widen at the
frontier".** It is which arm of the widening helper the corner reaches. On a
finite nonzero argument `roundDown` is `prevDown`, a full ULP outward, which is
more than the half-ULP rounding error it has to absorb; on a computed `+inf` it
is `+floatMax`, and that arm has no step left, because `+floatMax` is already the
largest finite `f64`. A raw `+inf` reaching the arithmetic therefore spends the
one arm that cannot help. Canonicalising the operand first puts the corner on
the finite arm: `roundDown(floatMax + (-3.0))` computes `floatMax` and steps to
`prevDown(floatMax) = floatMax - 2⁹⁷¹`, well below the true `floatMax - 3`. The
same one-line `add` is then an enclosure with no branch in it, and `translate`
inherits it for free because it is the same addition. The zero corner is exact
and needs no step — `roundDown(0.0)` and `roundUp(0.0)` return `0.0` — which is
why `translate` by `+inf` over `[-floatMax, floatMax]` answers `[0, +inf]`.

The cost is observable and was accepted with it: `init(+inf, +inf)` no longer
returns a point-shaped pair, so `neg`, `width`, `contains`, `eql`, `subsetOf`
and any direct field read see the normalised values. Nothing else changed
shape — two struct fields, no second normalising API, no extra allocation, no
global whole-line widening, and no change to the finite path.

**How they stand in the tree today.** The six `withheld` entries are gone. The
frontier sweep **judges** all thirteen operations it walks — `add`, `sub`,
`translate`, `expand`, `neg`, `recip`, `mul`, `div`, `abs`, `sqr`, `scale`,
`hull`, `intersect` — by consumer-visible containment against a reference built
from what an infinite endpoint stands for, and withholds none. The bit-pattern
test that asserted a degenerate infinite box is a point rather than a ray was
**deleted** rather than re-pinned: under this contract that shape is unreachable
through `init`, and pinning it would pin the representation instead of the
behaviour. What replaced it is containment plus canonical-input regression, and
T2 in `docs/tests-and-architecture-plan.md` describes the sweep; the repair is
P8 below. Per-operation tallies belong to a run rather than to this document and
are not recorded here.

### 1.2 S2 through S4

| id | sev | site | statement | how it was established | state |
| --- | --- | --- | --- | --- | --- |
| **D5** | S2 | `src/vector.zig:774` | `mapResult` took a bare `anytype`; with `V = *Vec(n)` the `comptime V == DynVec` test was false, so it declared an uninitialised pointer and wrote through it. | execution: SIGSEGV in Debug and ReleaseFast | **FIXED** (P5) |
| **D6** | S2 | `src/vector.zig:482-504` | `DynVec.deinit` was neither idempotent nor move-only: a second call freed an undefined slice, and a copy double-freed. | execution: SIGSEGV | **FIXED** (P5) |
| **D7** | S2 | `src/vector.zig:774` | The `!@TypeOf(v)` return type carried `error.OutOfMemory` from a comptime-dead branch, so `mapResult` on a `Vec(2)` value failed to compile. | code; the caller-visible symptom is a compile error, not a crash | **FIXED** (P5) |
| **D8** | S3 | `src/root.zig:95-115` | The `roundUp` / `roundDown` doc comments claimed they differ from `nextUp` / `prevDown` **at the infinities**. They are bit-identical there; the pairs differ only at the two signed zeros. | code | **FIXED** (P6) |
| **D9** | S3 | `src/vector.zig:188-191`, `:362-369`, `:713-715` | `fromArray` documented that it is "the one way to place an inverted interval in a box", and both `isEmpty` comments claimed every component of every box obeys `lo <= hi`. Two comments on one type contradicted. | code | **FIXED** (P6) |
| **D10** | S3 | `src/rounding.zig` (`nextUp`, `prevDown`) | The `-0.0` guard in `nextUp` was justified as preventing a step "to the smallest negative subnormal, which is below -0.0". The general pattern step from `0x8000000000000000` does not produce that subnormal at all — it produces `+floatMax` — so the stated reason was not the reason the guard is there. The direction of the step is what changes at the zeros, and the comment one line up already said so. `prevDown`'s mirror comment was wrong the same way. | code | **FIXED** (P6): both comments now state the change of direction at the zeros; the guards were always right, only the stated reason was wrong |
| **D11** | S3 | `README.md` | Drift, closed in two passes. **First:** the `prevDown`/`nextUp` recipe is gone everywhere, all four rounding helpers are documented, the benchmark build steps and the `iadd` ownership trap are in. **Second:** the two-ULP elementary claims, `abs` off zero, `sub`'s pairing and `DynVec.own` were corrected or verified against `src/`, and the original audit's line list — "the remaining row numbers from the original audit have not been walked" — has been walked: all 16 tables and 149 data rows were checked, and every sentence naming a symbol, a build step, a line number or a file was resolved against the tree. | code, and a sweep of the whole document | **FIXED** (P7): four further defects were found by the sweep and corrected, two of them by the document contradicting itself |
| **D12** | S3 | `build.zig:146-158` | The private cache directories for the nested fixture build were justified by a global-cache-lock deadlock that does not exist. `Cache.Manifest.hit` locks ONE manifest at a time and defaults to a shared lock. | code, and the flags dropped with the step measured unchanged | **FIXED** (P6): the flags are kept for containment, with the measured reason in their place |
| **D13** | S4 | `tests/rounding_test.zig` | The file imported `nextUp`, `prevDown`, `piDown`, `piUp` and never bound `roundUp` or `roundDown` anywhere. The two functions the entire library widens with had no test at all. | code | **FIXED** (P6): ten tests, green in all four optimise modes, and mutation-checked — mutating the `-inf` arm of `roundUp` fails three of them, where it used to fail nothing in the tree |
| **D14** | S4 | `src/vector.zig:53-60` | `errdefer out.deinit();` in `add`, `sub`, `mul`, `div` and `hull` was unreachable: the only statement between it and the return is a `map2` that returns `void`. | code | **FIXED** (P5): deleted, and the absence argued in the file header |
| **D15** | S4 | `docs/performance-handover.md` | The source-layout table and the step-4 table described a tree that no longer existed. | code | **FIXED** |
| **D16** | S4 | `tests/soundness_test.zig` (now `tests/soundness_shared.zig` and its four siblings) | The oracle covered **8 of the 56** public operations with a containment check, and skipped 2,040 `div` cases and 2,163 `recip` cases as preconditions. | code, counted from the `Op` enum and the `apply` / `exact` switches | **FIXED** (F1): 35 covered, `0 skipped precondition` for both; the other 21 of the 56 are covered by the MPFR corpus tier (T4) rather than by the in-tree oracle |

Two things about D16 are worth keeping, because they are the reason D1 survived
a 200-test suite and a `f128` oracle. First, the `div` and `recip` skips were
half genuine non-applicability and half a coverage hole wearing a precondition's
clothes: the library returns a documented contract value `[-inf, inf]` for a
divisor that reaches zero, and a documented answer is a contract value to be
checked, not a case the oracle may decline to judge. Both are now checked, from
the sign of the two one-sided limits, and both report zero skips. Second, there
was no containment oracle for any elementary function at all, which is how D17
survived a tree that had already grown to 34 covered operations. **All 21 are
covered now, and not by the oracle.** They were closed by an independently
generated MPFR directed-rounding corpus rather than by anything written in this
tree: `tests/corpus/elementary.txt` carries **1886** rows over **24** labels, of
which **21** are operations nothing else judges, and 427 rows are exactly
representable. Hand-written wider-precision reference series stay refused — an
`f128` series is a second implementation of the same function, and §2.2 of the
test plan is the record of what that costs. T4 in
`docs/tests-and-architecture-plan.md` owns the corpus and its mutation
evidence; this document does not repeat it. What "covered" means here is that a
containment oracle exists and is checked on drawn and named cases — not that
every input of every operation has been proved.

---

## 2. Implementation plan

**Every item in this section is done — P1 through P8, with no exception.** The
ordering was not ceremonial: D1 and D2 were each a single missing outward step,
and either one can be reintroduced by a later change that touches the same line
and does not know why the step is there. What each bought is recorded, because a
plan that lists finished work as pending is worse than no plan: the next
session redoes it, or distrusts the rest of the document.

Ordering inside the S1 block was severity, then blast radius, then risk. D1 and
D2 were code defects on a shipped public path; D3 was a document that shipped
the wrong recipe to every third-party caller; D4 was confined to the solver.

**P8 was the last soundness item, and nothing in this document is open.** It came
before anything in section 3, and it was not a wider version of D17: D17 was one
function widening by one step too few, and P8 was a question about what an
infinity *means*. The documentation items that followed it are closed too: D10
and the remainder of D11 are under P6 and P7 below, and both rows in section 1's
table read FIXED. **Section 3's features are all done and section 4's
optimisations are all resolved** — one answered in the negative, two landed, two
refused — so no entry in this document is a task. Final verification passed:
all four native modes, the MPFR corpus, external consumers, all benchmarks,
docs, LSP diagnostics and the installed expanded gate; see the handover's final
Wave 3 verification section.

### P1 — DONE: `div` at infinite endpoints (D1)

`cornerQuotient` sits beside `cornerProduct` (`src/interval.zig:91`) and is
called from all four corners of `div` (`:707-710`); a corner wider than a point
settles the reduction on its own (`:713`). **What it bought:** an indeterminate
corner now answers the whole line, which is sound, matches the answer `div`
already gave a zero divisor, and is the only enclosure a caller can act on. The
narrow alternative — `[0, inf]` for the same-sign case, by sign-analysing the
operands — was not needed; the frontier sweep judges `div` at thirteen shapes
with the wide answer in place, and `0 / inf` is still exactly `[0, 0]` because
IEEE defines it and the guard must not catch it.

### P2 — DONE: `normDistance` (D2)

`src/vector.zig:179-186` widens each step with `roundUp` and none with
`roundDown`; `squareBound` (`:133-150`) carries the underflow, and the
length-mismatch path still returns `+inf`, which is the value the
zero-if-and-only-if promise rests on. **What it bought:** a distance is a bound
rather than a rounding of one, on the same rule `add`, `abs` and `sqr` already
state. No wider type entered the file, so its arithmetic stays uniform. The
4,000,000-case containment check against the `f128` reference is in
`tests/vector_test.zig`, and the exact-equality assertions it replaced were
wrong to exist — a test that pins the round-to-nearest value of a function whose
contract is a bound pins the wrong thing.

### P3 — DONE: the README widening recipe (D3)

`README.md:156-197` publishes `roundDown` / `roundUp` as the pair for callers
widening their own arithmetic and demotes `nextUp` / `prevDown` to the strict
neighbours they are, with one paragraph saying why. **What it bought:** the
README stopped contradicting `src/`, and the acceptance is one grep —
`interval.prevDown` / `interval.nextUp` appear in it nowhere.

### P4 — DONE: `combinedColumn` cancellation (D4)

`cancelsExactly` (`src/lp.zig:916`) decides the cancellation on the operands in
`f128`, the only sound place to decide it: a **product** of two `f64` needs 106
significand bits and `f128` carries 113, so each product is exact, and the
verdict is an **equality between two such products** rather than a subtraction of
them — so no sum is ever formed. That distinction is the whole repair, because an
arbitrary sum of two `f64` is *not* exact in `f128` however wide `f128` is, and
round 2 put a cheap `f64` pre-filter in front so that only pairs which already
agree pay for the `f128`.
**What it bought:** a coefficient whose exact value is zero is stored as the
structural zero, so `isExactZero` stops reading a straddle as a two-sided
constraint and later eliminations stop pairing rows that share no variable. Two
characterisation tests in `tests/lp_test.zig` hold it, and the `bench-lp`
geometry report stayed byte-identical through both changes. The operand-level
pre-pass that would avoid `f128` entirely was never specified and is still not
ready to implement; the measurement says the filtered version is affordable, so
leave it there.

### P5 — DONE: `mapResult` and `DynVec` ownership (D5, D6, D7, D14)

`mapResult` (`src/vector.zig:774`) rejects a pointer argument at comptime with a
message naming the fault, and its error union no longer carries
`error.OutOfMemory` for a `Vec(n)`. `DynVec` records the address its constructor
allocated (`own`, `:446`) and `deinit` (`:482-504`) compares `comps.ptr` against
it under `std.debug.runtime_safety` — so ReleaseFast and ReleaseSmall elide it —
with a message that names the mistake rather than the symptom. The slice is
swapped for an empty one before the free, and that empty slice keeps the
address, which is why a second `deinit` passes the check and frees nothing.
The five unreachable `errdefer`s are gone, and the file header now argues why
there is no `errdefer` after an `allocLike`.

**What it bought:** a caller can no longer make the library free memory it never
allocated, and `deinit` is idempotent. **What it did not buy:** the check
constrains REPLACEMENT, not duplication. A copy holds the same `comps.ptr` and
the same `own`, so both copies pass and the double free stands. The type's
comment says so rather than pretending otherwise.

### P6 — DONE: the documentation and dead-code sweep (D8 through D14)

**Landed.** D8: the `root.zig` comments now say the pairs differ at the two
signed zeros and agree at the infinities, matching `src/rounding.zig` and
`src/interval_ext.zig`. D9: `fromArray` is named as the one door an inverted
interval comes through, in all three places that talk about it, and `isEmpty`
agrees with it. D12: the private fixture caches are kept with the measured
reason in place of a deadlock that does not exist. D13: `roundUp` and `roundDown`
have **ten** direct tests in `tests/rounding_test.zig`, and the acceptance held
— mutating the `-inf` arm of `roundUp` now fails three of them, where before it
failed nothing anywhere in the tree.

**D10 is closed, and was already closed when this entry last said otherwise.**
The complaint was that the `-0.0` guard in `nextUp` was justified as
preventing a step "to the smallest negative subnormal" — and that the general
pattern step from `0x8000000000000000` does not produce that subnormal at all.
Both comments now say what the acceptance asked for, which is the change of
direction at the zeros:

  * `src/rounding.zig:165-170` — "from 0x8000...0 this direction SUBTRACTS one
    and reaches 0x7fff...f, whose exponent field is all ones and whose
    significand is not zero, so it is a quiet NaN and not a number."
  * `src/rounding.zig:188-195` — the mirror for `prevDown`, naming the integer
    underflow at the bottom of the `u64` and the fact that `-0.0` needs no
    guard of its own.

The line numbers this entry carried for those comments (`:109-110` and
`:129-131`) had drifted, which is itself the argument for the rule the plan
already states: a citation that has moved is a citation nobody checked. Read
the file, not the pointer. No test is affected, and none was — the guards were
always right; only the stated reason was wrong, and only the reason.

### P7 — DONE: README drift and the handover (D11, D15)

**Landed.** The strict-pair recipe is gone from every part of the README
including `:55-56` and `:424-426`; all four rounding helpers are documented; the
benchmark build steps are listed; the `iadd` ownership trap has its own section;
and the two worked examples that could not run both run now — the
Fourier–Motzkin example, which passed an inverted interval to `Interval.init`
and panicked before printing a line, and the build-wiring snippet, which omitted
`target` and panicked inside the dependent's own build script. The handover's
source-layout table and step-4 verdicts have been refreshed against the tree.

**Closed.** The "still open" list this entry carried is now worked and audited.
The elementary-ULP claims, `abs` off zero, `sub`'s pairing and `DynVec.own` had
already been corrected or verified; the last clause — the original audit's line
list, "which has not been walked" — is now walked.

**The sweep.** All 16 tables and 149 data rows were checked against `src/`. The
row count is counted, not inherited: `grep -c '^|' README.md` is 181, and each
of the sixteen tables spends two of those lines on a header row and its
separator, so `181 - 32 = 149`. The sixteen blocks hold 5, 15, 8, 26, 16, 30, 8,
5, 7, 8, 10, 10, 4, 5, 14 and 10 `|` lines, and no `|` line sits inside a code
fence. Beside the tables, every sentence naming a symbol, a build step, a line
number or a file was resolved against the tree. The prose that argues WHY a
design has the shape it does has no mechanical form, so it is deliberately
outside what this entry claims to have counted: what is claimed here is a
procedure, not a total. Four defects were found, and two of them were wrong in
a way only a sweep finds, because the document contradicted ITSELF:

  * The `lp.Lin` field table still documented an `op` field and a mutable
    `coeffs`, both of which A1 deleted. The row was a live write door described
    as if it were still open, and the `const` that now makes a row read-only was
    missing from the very type that carries it. Some 600 lines later the same
    document correctly said `Lin` has no comparison field at all.
  * Two places described `scale` as composing through `div`. It composes through
    `halve`, which A9 made a public operation in its own right; `div` is the
    general division, and `halve` is the one that divides by the single constant
    the format can answer exactly. The two had drifted apart when `halve` was
    split out of it.

Everything checked and found correct was left alone. A wrong claim and a
gratuitous rewrite are both damage, and an audit that cannot tell them apart is
not an audit.

**Acceptance: MET.** `zig build docs` is green, and every one of the four
changes is traceable to a line in `src/` — the citations are in the commit
message. The plan's own standing rule, that a document restating a number
without counting it is a defect, is what caught two of these: the table row
counts and the `scale` composition were both recounted from the tree rather than
carried forward from prose.

### P8 — DONE: the reading of an infinite endpoint, and the rays that honour it (D18)

**Done.** The reading is settled and the repair is in the tree. Section 1.1
states the decision and why one constructor change was enough; this section
records what changed, so a later session does not re-derive it.

**What changed.** `Interval.init` asserts the caller's ordering and then
normalises two endpoint pairs, `(+inf, +inf)` to `[floatMax, +inf]` and
`(-inf, -inf)` to `[-inf, -floatMax]`. Nothing else in the constructor moved,
and `hull`, `hullOf`, `intersect` and `intersectionOf` take canonicality from
their inputs rather than from a normaliser on the hot path. Non-canonical
literals in the tree were migrated, except the ones that are deliberately poison
or invalid-input probes.

**`translate`** is `self.add(Interval.init(delta, delta))`, so an infinite delta
is the canonical scalar overflow ray and contributes its two endpoints rather
than being read as a number. Finite delta numerics are unchanged.

**`expand`** gained the `-inf` arm. `+inf` needs none: it walks the low end to
`-inf` and leaves the high one at `+inf`, so the general body already answers
the whole line. `-inf` is a ray of margins rather than one margin, and it means
every margin at or below `-floatMax`, so it asserts that the input is **actually
unbounded**. Every bounded input stays invalid, `[-floatMax, floatMax]`
included: the widest bounded box is no more valid there than `[0, 1]` is, and
the ray is not quietly clipped to the single admissible `-floatMax`. The
unbounded case is the union over the valid margins,
`[roundDown(lo + floatMax), roundUp(hi - floatMax)]`, which never forms
`inf - inf`.

**`scale`** gained one branch, and it is the only production branch outside
constructor and scalar handling. An unbounded input has no finite midpoint, so
`|factor| == 1` is the identity and every other factor — including `0` and every
`|factor| < 1` — answers the whole line, covering the finite-centre completions
rather than fabricating a centre. Factor validation stays first, because
`Interval.init` still catches a NaN factor. The bounded path and every finite
numerical repair are unchanged; `[1, 3].scale(2)` is still the loose box it was.

**The arithmetic operators** needed no new branch; the reason is which arm of
`roundDown` the corner reaches, and it is in section 1.1. Same-ray subtraction
and opposite-ray addition now answer the whole real line, which is their exact
image. `mul`, `div`, `abs`, `sqr`, `hull` and `intersect` are untouched and stay
as tight as they were.

**Preserved on purpose.** The `cornerQuotient` subnormal repair, the directed
rounding, the exact quotient checks and the QEMU child runners are all as they
were. The two overflow guards in the oracle are the same argument at a
different magnitude and were not undone.

**The shortcut that was not taken.** Widening every saturated result to the
whole line is sound and was rejected: it costs tightness on every call, and
`mul`, `sqr`, `abs`, `hull` and `intersect` are sound at the frontier today and
would stop being as tight for nothing. The rays are canonicalised once, at the
constructor.

**And the reading that was not adopted.** The point reading — `[inf, inf]` is
the point `+inf` — is self-consistent, and under it all six original findings
evaporate. It is not the contract, because `div` already answers `inf / inf`
with the whole line and would be wrong by the whole line if the point reading
were right. Recorded so a later session does not re-derive the choice.

**Files.** `src/interval.zig` for the constructor, `translate`, `expand` and
`scale`; `src/interval_ext.zig` for the ray readers; `src/vector.zig` for the
`fromArray` input contract; `tests/interval_test.zig` for the regressions; and
`tests/soundness_frontier_test.zig` over `tests/soundness_shared.zig` for the
frontier judging — `tests/soundness_test.zig` was the single flat file when this
was written and T10 split it, so cite the two files it became.

**Acceptance. MET — four modes green, and nothing withheld.** The two changed
constructor shapes are documented in the README, `scale`'s conservative whole
line is documented rather than skipped, and no frontier row is withheld: the six
that were are swept like the rest, for the reason `soundness_frontier_test.zig`
states in its own header. `zig build test` exits 0 in Debug, ReleaseSafe,
ReleaseFast and ReleaseSmall, and the oracle reports `0 FAILED` on all 35 of its
operations in each.

**What the red frontier sweep turned out to be, which is the part worth
keeping.** The paragraph this replaces traced every failing row to a defect in
the ORACLE's own reference rather than in `src/`, and it was right about every
one of them. It named four classes; there were five defects, because one class
had two members.

- **`reachesZero` was one-sided** — `c.lo_unbounded or c.lo <= 0.0`. A divisor
  of `[-3, -1]` therefore "reached zero", and the reference demanded the whole
  line from a `div` that had correctly answered `[-1, -1/3]`. Both ends decide
  it: `c.lo <= 0 and c.hi >= 0`. This was `div` and `recip`.
- **`productSet` collapsed a zero factor only when both ends were `.value`.**
  A zero times a RAY fell through to `stretched(0.0, r)` and became an open
  ray, so `[0,0] * [3, inf]` was judged against `[-inf, 0]` when its true
  image is the single point `0`. The collapse is now `or`'d across the two
  cases, which is what the comment two lines above the code already said. This
  was `mul`.
- **`frontierMagnitude` read an unbounded magnitude as spanning zero** — it
  or'd in `a.lo_unbounded`, putting `0` under `abs([-inf, -3])`, whose true
  image is `[3, +inf)`. The two-ends test alone is correct, because an
  unbounded end carries the infinity it runs off to. This was `abs` and `sqr`.
- **`frontierExpand` had the sign of the `-inf` ray inverted.** It built
  `[lo - far, hi + far]`, which is what `expand` does for a POSITIVE margin. A
  negative margin contracts, and the union over the ray `m <= -floatMax` is the
  two ends pulled together by its last member. It judged
  `expand([3, +inf), -inf)` against `[-floatMax, +inf]` when the answer is
  `[3 + floatMax, +inf)`. This was `expand`.
- **The `guard` row had been made vacuous by P8 itself.** It built its
  deliberately non-canonical `[-inf, -inf]` through `Interval.init`, which now
  canonicalises that pair to the overflow ray — so it was comparing the
  saturating case with itself and expecting the two to differ. It is now a raw
  struct literal, which the type's own doc calls the way to hold a
  non-canonical interval.

**And one blocker sat in front of all five, in no list at all: the test file
did not compile.** `tests/soundness_test.zig` carried a `std.debug.print` with
six format placeholders and five arguments — the missing one being the `tiny`
of `floatMax/2 - tiny/2` — so the two `{s}` verdicts shifted into the `{e}`
slots. Nothing in the tree had compiled since, and a `zig build test` here stops
at that compile error before a single test runs, which is worth remembering:
on a tree this size a red gate is not evidence about behaviour until it has
been read past the compile.

---

## 3. Feature proposals, ranked by value against cost

Separate from the defects above. Nothing here is a bug. **All three features are
done.** F1's coverage goal is met by two tiers rather than one: 35 of the 56
audit-set operations are judged by the in-tree oracle and the other 21 by the
MPFR corpus. What was refused rather than deferred is hand-written wider-precision
reference series, and the refusal is recorded below rather than queued.

### F1 — DONE: the 56-operation audit set is covered, by the oracle and by the corpus

**What it was.** Take `tests/soundness_test.zig` from 8 operations to as close to
56 as the machinery honestly allows, in three tiers by how the reference is
obtained. Tier one, the cheap exact answers: `abs` and `sqr` are exact `f128`
images of the `f64` endpoints with no new machinery, because a product of two
`f64` is exact in `f128`. Tier two, exact without `f128` at all: `hull` and
`hullOf` are exact and need only the two distributive laws plus an equality
against the min/max of the four endpoints; `intersect` and `intersectionOf` are
exact and need the complement; `neg`, `midpoint`, `clamp`, `contains` and the
six certain-comparisons are definitional or one line each. Tier three, the
elementary functions, where the honest alternative was declared to be a
*characterisation* oracle rather than containment, because Zig offers no
correctly rounded `f128` `exp`, `log` or `sin` to compare against.

**What it bought.** 35 operations are judged by containment where 8 were, and
`div` / `recip` report `0 skipped precondition` where they reported 2,040 and
2,163 — a divisor that merely REACHES zero is now checked from the sign of its
two one-sided limits, because the library returns a documented answer there and
a documented answer is a contract value to be checked, not a case to decline.
Every oracle added was checked to bite before it was trusted: tightening `sqrt`
by 3 ULP fails 1,739 of 7,314, tightening `cbrt` by 3 ULP fails 6,895 of 7,251,
dropping the third element of `hullOf` fails 4,231. That is what separates a
live oracle from a decorative one.

**And the tier-three direction changed, twice: once away from the plan this item
was written with, once into the corpus.** `tanh` is in, built from the exponential
with the cancellation paid for, and catching D17 is what it was built for. The
remaining **21** are covered as well, and not by anything written in this tree.
Hand-written reference series were refused on the grounds §2.2 of
`docs/tests-and-architecture-plan.md` gives: an `f128` series is a *second
implementation of the same function*, and the audit needed to convince anyone it
is right costs more than the coverage it buys. What landed instead is an
**independently generated MPFR directed-rounding containment corpus**:
`tests/corpus/elementary.txt` carries **1886** rows over **24** operation labels,
**21** of which are operations nothing else judges and **427** of which are
exactly representable, and `tests/corpus_test.zig` checks every row for
containment. T4, T6 and T7 in `docs/tests-and-architecture-plan.md` own it and
are **done**, including the mutation evidence that the corpus bites. The eight
shape designs that entry used to carry are kept there as the fallback analysis
and are **not** a plan: nothing on that list was written and nothing on it is to
be written.

**What "the 56" is, so that the coverage claim is not over-read.** The 56 is the
audit's own set: 28 public methods on `Interval` and 28 free functions in
`src/interval_ext.zig`. Three helper methods were published afterwards and are
outside that set — `Interval.halve` (A9), and `Interval.signOf` /
`Interval.zeroSplit` (A3), which are the classifier the 35 in-tree operations
read rather than operations they judge. All 28 of the audit-set methods are in
the `Op` enum, and so are seven of the 28 free functions; the remaining 21 are
the corpus labels. `35 + 21 = 56` with no remainder, and nothing here claims
anything about the three added helpers or about every input of any of the 56:
what each tier asserts is containment on drawn and named cases.

### F2 — DONE: `asin`, `acos` and `atanh` clip to their domains instead of refusing

**Done.** The refusal is gone and `null` now means the one thing the package
prose says it means. The clipping is `@max(x.lo, -1)` / `@min(x.hi, 1)` for the
two closed domains and the same pair for the open one, and emptiness is a clip
that reaches no further than the endpoint from inside it.

**What it bought.** `asin(Interval.init(-4, 0.5))` answers `[-pi/2, asin(0.5)]`
and `atanh(Interval.init(-2, -0.5))` answers `[-inf, atanh(-0.5)]`, where both
answered nothing and both had a sound answer. A caller doing global
reachability no longer splits the domain by hand at every call site, and the
library's identity — it bounds rather than refuses — now holds for every
function in `ext` without an exception to remember.

**The one place the answer is NOT the closed-domain rule, and why.** `atanh`'s
domain is OPEN, so an argument whose only overlap with it is the endpoint
itself — `atanh([1, 2])` — has an empty true image and stays `null`. A closed
clip would have accepted it and answered `[floatMax, +inf]`, which is a bound of
nothing wearing an interval's clothes. The emptiness test is therefore
two-sided (`hi <= -1 or lo >= 1`) and not `lo <= hi`. That is the whole of the
distinction between `atanh` and its two closed-domain siblings.

**What it did not change.** `mapResult`'s null still means "some component's
true image is empty" and never "some component reached a boundary"; a test over
a `Vec(3)` with two clipping components and one empty one pins it, because
clipping is exactly the change that could have merged those two answers.
`powf` is untouched and is the one function that still refuses a partly invalid
argument, because a negative base to a general real exponent has no real value
at any part of the argument and there is nothing to clip to. `acosh` already
clipped.

**What follows this line is the specification as it was written BEFORE the
change landed, kept as history.** It is not a work list: the clipping is in the
tree, the tests named below are in `tests/interval_ext_test.zig` under the names
"asin: the argument is clipped to [-1, 1], and null only when it misses it
whole", the same for `acos`, "atanh: the argument is clipped to (-1, 1) and the
pole answers", and "domain: clipping must not have merged null into an answer".
**Acceptance. MET**, on those four tests. Read the rest for the reasoning, not
for the tree.

**What it was.** `asin` returned `null` unless the whole
interval lies inside `[-1, 1]`; `acos` did the same; `atanh` refused
anything reaching `±1`. Clip instead: intersect the argument with the domain,
evaluate the monotone function at the clipped ends, and let the pole produce an
infinite endpoint. `atanh([-2, -0.5])` becomes `[-inf, atanh(-0.5)]` instead of
of `null`. Under the proposal `null` would then mean what the package prose says
of `src/root.zig` — the true image empty in the reals — which happens only when
the whole interval is outside the domain, as `asin([2, 4])` already does. It is
not what those three functions meant then: `null` also
covers a partly valid argument, which is precisely the case this proposal
removes. That asymmetry is the finding, and it is the same asymmetry
`sqrt`, `log*` and `acosh` do not have, because those clip a partial violation
and refuse only a wholly invalid one.

**Why it matters to a user.** Before the change, a caller doing global
reachability got no answer where a sound one exists, and the only workaround was
to split the domain by hand at every call site. The change costs a caller nothing
and saves them that. It is also the difference between a library that refuses and
one that bounds, which is the identity this library is selling.

**What it risks.** The `mapResult` null contract in `src/vector.zig`, which
folds a scalar `?Interval` over a box and reports null as soon as one component
leaves the domain. Clipping does not change that contract, but a reviewer must
check it has not: the `null` from `mapResult` must still mean "some component's
true image is empty", never "some component reached a boundary". `acosh`
(`src/interval_ext.zig:568`) has the same shape and should be considered
together.

**Acceptance, as specified before the change and since met.** New tests in
`tests/interval_ext_test.zig` asserting `atanh(Interval.init(-2.0, -0.5))` is
non-null with `.lo == -inf` and `.hi <= atanh(-0.5)`, that
`asin(Interval.init(-4.0, 0.5))` and
`acos(Interval.init(0.5, 4.0))` are non-null with the unclipped end at
±pi/2 widened, and that `asin(Interval.init(2.0, 4.0))`,
`acos(Interval.init(2.0, 4.0))` and `atanh(Interval.init(1.0, 2.0))` still
return `null`. A `mapResult` test over a `Vec(3)` with one component outside the
domain must still return `null` while the other two would clip, proving the two
answers were not merged. (The last clause named three README rows by line number
as work still to do; the row numbers are gone, the rows were walked by P7, and
the citation is not carried forward.)

### F3 — DONE: `roundUp` / `roundDown` documented as the widening pair

The README half landed as P3 and the source-side half with it: `src/root.zig`
carries correct comments on both, and the README names both pairs in its API
table alongside `piDown` and `piUp`, with a paragraph on why the non-strict pair
is the one a bound needs. Nothing is left here, and it is not to be reopened as a
separate decision — the acceptance is P3's, one grep.

---

## 4. Optimisation backlog for the next round

Drawn from the step-4 ranking in `docs/performance-handover.md`, with the
verdicts that ranking already reached and the figures it ended on. **O1 through O4
are resolved** — O2 and O3 landed, O1 is answered in the negative by a proof that
was written afterwards, and O4 is refused and closed — so none of those four is a
**O5 was the one open entry, and it has been tried and is now REFUSED**: it was
carried as a trial rather than as an accepted optimisation, it failed all three
of the conditions fixed before the run, nothing from it is in the tree, and no
speedup is claimed. **This section has no open entry left.**
**Cheap-row noise is capture-specific.** The contended 2026-09-30 capture moved
by up to 44% between two runs of the same binary. The current three-run capture
is wider: max/min spread is 66.2% on `interval.mul` and 287.6% on `dyn3.contains`.
Nothing under about 10 ns/op is claimable from a single pair of runs on a
shared host. Use repeated measurements and each current row's range; cite every
figure with its date and mode.

**The current baseline is 2026-10-02; the handover's 2026-09-30 capture is the historical one.**
`docs/performance-baseline-2026-10-02.tsv` carries **all 362 timed rows** — 60
scalar, 276 vector, 26 LP, the LP 26 being the 13-body catalog run twice, once
per heap — each row with the three runs' `ns/op` beside their median, minimum and
maximum. It was captured at revision `7b472aee` on a shared host with compiler
0.16.0, root and interval both `ReleaseFast`, warmup 1 and reps 7, the LP row
budget at 20,000, as three sequential rounds in the order scalar, vector, LP,
each program's output to an ordinary file. The host is shared and unpinned, so
this is a baseline to compare a later revision against and **not** a claim that
any row is a stable cost. The earlier capture in `docs/performance-handover.md`
is the 2026-09-30 one and stays historical; its separately dated Wave 2 section
summarises this current baseline. Where the dated captures differ, cite the TSV
and its header for current measurements, without treating that difference as a
speedup.

The same capture is written up in `docs/performance-handover.md` under its own
heading, **Wave 2 — the current three-run baseline, 2026-10-02**, which is
where the recipe and the 13 LP cases in full are.

**The baseline is proved equal, not merely re-taken, and that is what makes it
usable as the reference for the next change.** All nine program runs exited 0, and
a strict parser compared them: row identities, iteration counts, the streamed
per-row checksums and the fold are identical across all three captures of each
program, and every row identity, iteration count, checksum and fold in the
2026-10-02 Wave 1 smoke logs is reproduced. On LP the geometry report is identical on
every run; the untimed accounting of all 13 bodies is identical across all three
captures and on both heaps; `allocs == frees` and `alloc B == freed B` on every
body; and the per-heap totals are **494,632** allocations and **306,958,852**
bytes, the same figure on `allocator=dbg` and on `allocator=smp`. So a candidate
change can be required to reproduce those checksums exactly, and a candidate that
does not is wrong however fast it looks.

This is a local benchmark capture. It is not a gate run, and nothing remote was
executed to produce it.

**O1 — `scale` at 47.795 ns/op, six widening steps per endpoint.**
`src/interval.zig`. Verdict: **NO — and now answered rather than merely
deferred.** An earlier version of this entry said "not without a proof", because the
sound argument it asked for was missing: a direct formulation needs one outward
step per endpoint, and nothing established that one step covers the chain of
roundings the present composition encloses. **The proof was written, and it says
no.**
`docs/scale-enclosure.md` works the error budget in exact rational arithmetic over
IEEE binary64 and closes in its §9, *Verdict*: one step buys half an ULP of the
endpoint, the fused chain delivers up to one ULP of the midpoint, and the ratio
`ulp(M) / ulp(L)` is unbounded on the family `[-1, 2^k]` at `G = 1 - 2^-53`. No
fixed step count repairs it, and the only term that breaks the one-step bound is
the rounding of the product `fl((hi - lo) * g)`. **So O1 is closed as answered, in
the negative direction, and it is not to be reopened** — a form that does not
compute `M - W` from two rounded `f64` intermediates is §8 of that document, and
§8 is a different piece of work, not this optimisation. No executable line of
`src/interval.zig` changed; the only edit was the paragraph in `scale`'s doc
comment that cites the document. The arithmetic behind the verdict is in that
document and the reasoning this entry was written on is kept here; the step count
did not change in round 2, and what changed there was the price of a step, which
is why the figure moved at all.

**O2 — DONE: one shared elimination walk in `box`, in place of `m` private
sweeps.** `box` in `src/lp.zig` used to call `bounds(k)` for every `k`, and each
call cloned and eliminated, so the cost was `m` clones and `m * m` eliminations.
The soundness argument that licensed the change is the one this entry gave:
every elimination step is a sound over-approximation, so a projection computed
from a shared prefix is at least as valid as one computed from a private copy;
the only question was tightness, since the Tupper order is a row-count heuristic
and sharing it fixes one order for all `m` projections. **That question is
answered by the tree, not by argument.** `System.box` now keeps one chain and
reads each projection off the state that chain has reached, and the named test
`box: the shared walk answers exactly what a private sweep per variable answers`
in `tests/lp_test.zig` pins the result against a re-implementation of the OLD
two-line form: bit-identity is what the walk achieves, because it runs the same
elimination order, and the containment assertions are kept as well so the test
would still hold — the looser one — if a future change to the order made every
projection merely wider. That was the acceptance, and the `null` cases were
reasoned through rather than discovered: the doc comment on `box` says why the
contradiction check the walk adds cannot move a `null`, and why the walk stops one
variable short.

**What it cost, and it was accepted deliberately.** It altered the elimination
COUNT — roughly half as many eliminations — and it raised peak memory, because
the walk holds a chain and one copy alive together where the old form held one.
The `bench-lp` geometry report is unaffected: it records row counts, first-round
predictions, chosen orders and boundedness, not the internal clone count.
**No speed is claimed here, and the reason has changed.** The
`bounds`-calling rows this entry once proposed to measure — 75,219 ns and
152,932 ns — are the 2026-09-30 capture's numbers, stay labelled with that
date, and are not restated as current. What has changed is that they are no
longer the newest figures: the current measurement of every row, three runs
each, is `docs/performance-baseline-2026-10-02.tsv`, and those two rows are in
it. Neither set attributes a delta to this entry, because one revision
captured once is not a before/after pair — what the shared walk costs in
nanoseconds is still not measured, and only the elimination count and the peak
memory are claimed.

**O3 — DONE: the `undersized` side channel in `mul` and `div`.** The flag was
computed eagerly per corner, four byte stores and three unconditional reloads in
`mul` and four dead stores in `div`, and the reloads sat above the `v == 0.0`
guard, carrying an answer that is dead unless the reduced extremum is exactly
zero. It is gone: the operands are read at the one moment they are needed, by
`Corners.undersizedAt`. The flag's *meaning* did not change, only *when* it is
computed, and the widening step count is unchanged. **Claimed: `mul` 11.062 →
9.639 ns/op, −13 %**, which clears the noise band. The corner tests and the
underflow reproducers in the oracle are unchanged. This was a tidy-up that
turned out to be measurable. O3 and O2 are the two items of this section that
have landed; O1 is answered in the negative, O4 is refused and O5 was tried and
refused, so none of the five is pending.

**O4 — REFUSED and closed: `powf` at 272.5 ns/op, seven interval operations
composed.** `powerCorner` (`src/interval_ext.zig`) and the identity above it.
Verdict: **NO. Clearly no, and this is settled.** The composition *is* the
guarantee:
`log` widens three ULP, `mul` widens one, `exp` widens three, and the image of a
rising function over an enclosure is the enclosure of its two ends. Replacing it
with `std.math.pow` reintroduces the error that grows with the exponent —
measured at 1.52 ULP on an ordinary exponent, and `1.0000000001^1e8` came back
as 1.01005016788679320 against a true 1.0100501679193823. The handover reached
the same verdict at rank 5: "do not change ... deliberately traded for
soundness. Quantified, as asked; not a defect." Do not reopen it.

**O5 — REFUSED and closed: test `row.rhs.hi < 0` before `isAllZero` in
`System.checkRowForContradiction`.** It was the one open entry and it was carried
as a trial, not as an accepted optimisation. It was implemented, measured against
conditions fixed before the run, and **rejected**: all three timing conditions
failed. Nothing from it is in the tree, no comment was added with it, and the
entry records **NO CLAIM**.

**What the profile said, 2026-10-02, same revision, same host.**
The profile covers 20 calls to the public `bench_lp.run` path in a separate SMP
consumer — geometry report, accounting and printing included, not the timed
region alone — with **36,754** samples and **0 lost**, and every original signal reproduced.
`eliminate` carries **56.74 %** of the whole profile's self time. Inside it, the
post-elimination rescan on the `eliminate` path — raw leaf periods mapped
through the disassembly onto two address ranges — is **7.537 %** of `eliminate`
and **4.276 %** of the whole profile, from **1,581** samples.
The heuristic is the thing this entry did NOT propose to touch: `chooseNext` has
exactly two callers, `eliminationOrder` and `eliminateInOrderOfChoice` (LSP, not
inspection), the tally is inlined into it, and their combined **self** time is
**0.595 %** of the whole profile. That figure is an **upper bound** and not its
cost, because caller self time also contains the wrapper's own work and the
inlined callee is not separable there; 0.595 % is not worth changing. The
collecting `Buckets.partitionInto` is **1.85 %**, and it is a different function
from the heuristic's tally — do not add the two.
Three limits travel with these numbers: the DWARF call-chain and inline reports
did not separate the inlined scans (inclusive equalled self), so address ranges
and raw leaf periods were used instead; the host is shared and unpinned; and
sample attribution is **not** a speedup. One labelling trap: the profile ran the
public `bench_lp.run`, which prints the `allocator=dbg` heading while running on
the runner's own heap. The two heaps in the TSV's LP rows are `bench-lp`'s own
`main`, where the labels are literal.

The profile is written up in full, with the two emitted address ranges and the
capture recipe, under **Wave 2 — the LP profile, 2026-10-02** in
`docs/performance-handover.md`; this entry adds only the decision and its terms.

**The candidate, exactly.** `checkRowForContradiction` (`src/lp.zig:1248-1252`)
is two tests: return unless every coefficient of the row is exactly zero, and
latch `unsat` when the right-hand side's upper bound is below zero. Asking the
second question first skips the whole-row coefficient scan on any row that
already cannot contradict. How many rows that is on the elimination path is
**not** measured, and the trial did not measure it either — the 4.276 % is
the scan's cost, not the number of skips the reordering would buy.

**Everything that must not move, stated as conditions rather than as intent.**
The predicate stays `rhs.hi < 0`: not `rhs.lo < 0`, not `<= 0`, and the
doc comment at `src/lp.zig:1235-1247` is why — `rhs.lo` reads a satisfiable
system as unsatisfiable, which cuts the feasible set. `isAllZero` keeps reading
coefficients only, keeps calling `exact.isExactZero` (`a.lo == 0 and a.hi == 0`,
so a rounding-thin straddle is still a variable the row mentions), keeps its
whole-row early exit, and is neither deleted nor duplicated. `pushRow` still
checks only the row it just appended and `rescanForContradiction` still scans
every row on the `eliminate` path — A5's split is untouched and does not reopen.
`unsat` stays latched, and every system that latches and every system that does
not must latch identically. Elimination order, tie-breaking between equal
candidates, the row budget, the workloads, the seeds, the iteration counts and
the arithmetic are all untouched: the change reordered a conjunction of two pure
tests and computed nothing, and every one of those conditions held in the end.

**Accept or reject, decided two ways, both required — declared before the run.**
1. **Differential equality.** The candidate's captures must reproduce the
   2026-10-02 baseline exactly — every row identity, iteration count, streamed
   per-row checksum and fold, on all three programs; the LP geometry report and
   the untimed accounting of all 13 bodies on both heaps; the per-heap totals
   still **494,632** allocations and **306,958,852** bytes. "Close" is a failure.
2. **Repeatable timing.** Run the unchanged baseline and candidate sequentially,
   paired across three rounds, on the same host. Each row remains the minimum of
   seven internal repetitions; compare the three-run medians and ranges.
   Require at least 5% lower median on `eliminateAll chosen, mixed 14x2` under
   `allocator=smp`, improvement in all three pairs, and non-overlapping ranges.
   Otherwise reject. Use that row's fresh paired variance, not historical scalar noise.

**What the trial ran.** Same shared host, compiler and mode as the baseline:
compiler 0.16.0, root and `interval` both `ReleaseFast`, the complete unchanged
LP program with its iterations and seeds untouched, minimum of seven internal
repetitions, warmup 1, LP row budget 20,000, ordinary-file stdout and stderr,
the shared unpinned host with no concurrent project build, profile, test or
benchmark. Three counterbalanced sequential pairs, AB / BA / AB, giving six
program runs, all exit 0. The predeclared primary row is the only row the
decision rests on: `eliminateAll chosen, mixed 14x2`, 200 iterations,
`allocator=smp`. Paired gain is `(baseline - candidate) / baseline`, so a
negative figure is a regression.

| run | baseline ns/op | candidate ns/op | paired gain |
| --- | --- | --- | --- |
| 1 | 141681.945 | 495945.510 | **-250.04 %**, a regression |
| 2 | 190976.300 | 138570.120 | +27.44 % |
| 3 | 123919.585 | 115391.035 | +6.88 % |
| **median** | **141681.945** | **138570.120** | **+2.196 %** |

**Every predeclared condition, and what happened to it.**

| condition | result |
| --- | --- |
| median at least 5 % lower | **FAILED** — 2.196 %, well under the bar |
| improvement in all three pairs | **FAILED** — the first pair is a 250.04 % regression, the candidate running 3.5x its own baseline |
| non-overlapping ranges | **FAILED** — baseline 123919.585-190976.300 against candidate 115391.035-495945.510 |
| differential equality | **MET**, and it does not rescue the other three |

**The 2.196 % is not a speedup and must never be quoted as one.** It is the
difference of two medians on a shared, unpinned host, and it is smaller than the
spread inside either capture's own three runs. The other two conditions exist
precisely so that a figure like it cannot be accepted on its own. The entry
closes as refused here, and no arithmetic is done with that median.

**Differential equality held, and it is not in dispute.** Strict LP readers on
both three-run captures exited 0: row identities, iteration counts, the streamed
per-row checksums and the fold, the geometry report and the untimed accounting
of all 13 bodies are identical to the 2026-10-02 Wave 1 reference on both heaps,
with per-heap totals still **494,632** allocations and **306,958,852** bytes,
`allocs == frees` and `alloc B == freed B` on every body. Beyond the benchmark's
own signals, a behaviour probe compared before and candidate on **414** state
cases — 400 random systems of 0 to 2 variables and at most 6 rows, plus 14
controlled shapes — which produced 1,341 additions and 442 eliminations with
**0** gaps, comparing exact bit patterns, the latched `unsat` state, errors,
`null` answers, elimination order and liveness; on **23** precise cases over 81
operations and 104 snapshots, compared as 10,566 explicitly serialized words; and
over **150** allocation-failure runs, 10 scripts by 15 failing indices, with no
mismatches and no unbalanced COUNT or BYTE teardown. Zero mismatches in all
three. Both RF consumers pass on the before tree and on the candidate, and the
certified Debug boundary control is green frozen-against-frozen and
frozen-against-candidate.

**The mutation evidence, and why the predicates were not why this failed.** The
boundary probe needed a fix of its own before its exit codes mean anything: it
originally reported a mismatch without failing the process, and now returns
`error.DifferentialMismatch` and checks both the allocation counts and the byte
totals. With that in place, three private wrong-predicate mutants — `rhs.hi <= 0`,
`rhs.lo < 0`, and an approximate-zero test — each built and each **exited 1**,
while the certified control and candidate exited 0. The differential harness
detects exactly the class of change this entry proposed to make.

**The pins.** The unmodified baseline tree is revision `f1c9e7c5`, code-equivalent
to the `7b472aee` the current baseline TSV was taken at, with `src/lp.zig` at
sha256 `40868f63…` read back from that revision and from the frozen seven-file
manifest; the candidate's `src/lp.zig` hashed `606fa7f1…`. The original
before-build argv was left exactly as it ran, against the live pre-trial source,
and a certified replay control pins two distinct nominal modules to frozen
copies. The probes were throwaway and are gone: **no permanent test, no new API
and no second candidate** came out of this entry.

**What was restored, and what never moved.** `src/lp.zig` is the original file
again — sha256 `40868f63…`, byte for byte the revision the baseline came from,
with only the two guard lines the trial added removed and nothing else touched.
No API, no allocation, no validation, no elimination order, no tie-break between
equal candidates, no row budget and no arithmetic changed, and neither the strict
`rhs.hi < 0` predicate nor the exact `isAllZero` predicate was weakened. A5's
`pushRow`-checks-one-row / full-rescan-on-`eliminate` split stands and does not
reopen. No comment was added for the rejected order, because the entry was
refused.

**The full record.** All **52** rows of the paired capture — the 26 LP rows of
the benchmark catalog, run as baseline and as candidate, each with its three
`ns/op` values beside median, minimum and maximum — are in
`docs/performance-trial-2026-10-02.tsv`. Its header carries the date, the host,
the compiler, `baseline_code=7b472aee`, both `src/lp.zig` hashes and
`outcome=REJECTED NO_CLAIM`, so the file is readable without this entry. The
362-row `docs/performance-baseline-2026-10-02.tsv` is untouched by the trial and
remains the current baseline.

**What is left here.** Nothing. These measurements bound the two scan
hypotheses; they do not establish that no other bottleneck exists. No second
candidate is queued behind this one and none is promised. Final verification is
complete; the handover records the native suites and immutable cross run.

---

## 5. Not doing

Listed so a later session does not relitigate any of it.

**The straddling duplication in `eliminate` stays.** The `.straddle` arm of the
bucketing switch in `src/lp.zig` pushes a coefficient interval that straddles
zero into **both** sign buckets, because dropping it would discard a real
constraint and cut the feasible set, "which is the one thing this library must
never do". The duplication is the guarantee, not waste. The cost is row
explosion, documented and measured in `docs/performance-handover.md`, and the
mitigation is the 20,000-row budget in the benchmark harness, not a change to the
solver. The `f128` cancellation fix in P4 is compatible with this: it removes
coefficients that are *exactly* zero, which is a different thing from a
coefficient whose interval contains zero.

**Stopping after `n - 1` variables stays out.** A textbook Fourier–Motzkin loop
stops with one variable live, because the last round produces the contradiction
test. Here `eliminationOrder` is contractually a full permutation and the final
row count is pinned by tests, so removing the round changes observable behaviour
and makes it a different function — the finding is recorded in section 9 of
`docs/performance-handover.md` under "stopping after `n - 1` variables", and the
tests are the reason it is closed.

**`powf`'s composition stays.** See O4. The composition is the proof; the
measured 272.5 ns/op is the price and was accepted knowingly.

**The `log2` / `log10` subnormal claim stays withdrawn.** An audit filed it, and
it was checked and not reproduced: the library contains the truth on the
smallest subnormal and at the range boundary in every case tried. The apparent
misses were an `f64`-computed reference compared against the library's widening
— the same reference mistake that would recreate D2 inside the oracle, and the
same one that made D17 look sound. It is not in section 1 and must not be added
to a later audit's list without a reference finer than `f64`.

**The `0 * inf` guard in `mul` stays, and is not "redundant".**
`src/interval.zig:31-38` answers a corner IEEE declares invalid with the sign
xor of the two operands, which is the only way the four-corner reduction can
survive it. `div` has its counterpart now (`cornerQuotient`, P1); neither guard
is a reason to touch the other.

**The two overflow guards in the oracle are guards, not reproducers.** They are
not defect reproducers and must not be deleted as obsolete. They exist because
the natural "fix" to each is unsound, and each says so in its own comment. They
are the standing record of why an overflowed corner's bound is pulled back
inside rather than read as an infinity. P8 settled that same argument at a
different magnitude by canonicalising the rays in the constructor; the guards
stay exactly as they are.

**`bench-lp` sizes must not be restored to their old values.** The measurements
that never terminated were resized to fit the row budget, with the achieved
counts recorded in the file's own header so the next reader does not "restore"
the values that used to hang. The `ulimit -v` recipe from an even earlier draft
is wrong and was removed; do not reintroduce it.

## 6. DynVec ownership specification (implemented)

**Status:** implemented in `0ffccc03` and verified on 2026-10-04 with Zig 0.16.0.
The design specified at `2edb6094` now provides `DynVec.takeFrom`.
Arithmetic methods, storage layout, constructors and benchmark workloads stay unchanged.

### Requirement and decision

Keep `DynVec` as the sole owner of its component allocation. Add one explicit
transfer operation that replaces a destination and drains the source. This
reduces mistakes in the existing free-then-overwrite pattern without changing
the arithmetic API, storage layout or allocation policy.

**This is not an arbitrary-copy-safe representation.** `var b = a` makes an
alias, not an independent owner. Releasing both remains invalid in every
optimize mode. Borrowed by-value method arguments do not acquire cleanup duties.
Explicit transfer closes the handoff gap, not that language-level limitation.

| Operation | Contract |
| --- | --- |
| Construct | Existing `init` and `fromArray`; returned box has one owner. |
| Deep copy | Existing `DynVec.fromArray(gpa, source.slice())`; caller chooses the copy's allocator. No `clone` alias. |
| Borrow | Existing `slice()` and read-only by-value arguments; no ownership transfer. |
| Transfer | `takeFrom(self: *DynVec, source: *DynVec) void`; source is mutable because the method drains it. |
| Release | Existing `deinit()`; repeat cleanup of the same emptied object is safe, cleanup of an owning copy is not. |

### Transfer contract

1. Both objects must be valid owners or valid zero-dimensional objects.
   Their allocator, component slice and ownership record must not have been
   replaced by the caller. No stale owning alias is a valid input.
2. `self == source` is an unconditional no-op, including for a nonempty box.
   No allocation is freed, no field changes and no borrow ends.
3. Otherwise, capture the source's allocator, components and `own` record.
   Release the destination's previous allocation with its previous allocator.
   Adopt the captured fields without changing any component.
4. Leave the source with `source.comps = adopted_comps[0..0]`. Retain its
   allocator and `own` record. This is the existing post-`deinit` state:
   dimension 0, empty slice, `isEmpty() == false`, and repeat cleanup is safe.
5. Transfer can change the destination's dimension. It compares no widths,
   allocates no storage, copies no component data and returns no error union.
   There is no partially committed OOM state.
6. Carry `source.own` verbatim; do not reconstruct it from `comps.ptr`.
   Transfer must not erase the existing replaced-address diagnostic.
7. In Debug and ReleaseSafe, diagnose distinct inputs that both have nonzero
   length and the same component address before freeing either allocation.
   Check **both lengths**: independently created empty boxes can share a
   sentinel, and a released empty object can retain an address that a new
   allocation reuses. Neither case is an ownership conflict.
8. The direct-alias diagnostic is omitted in ReleaseFast and ReleaseSmall,
   like the existing `deinit` guard. It is not a liveness registry and cannot
   detect all raw copies, stale slices, allocator replacement or field forgery.
   Violating the ownership precondition can still cause a leak, use-after-free
   or double free in unchecked builds.

The source allocator travels with the allocation. After transfer, later
allocating operations on the destination use that allocator. Its backing state
must outlive the destination's allocation. Transfer from a short-lived arena
does not extend the arena's lifetime. No stable address for the `DynVec` object
itself is required; the method stores no pointer to either object.

### Borrow lifetime

- A view of the destination's old allocation ends at replacement.
- A view of the source's allocation survives a successful transfer. It follows
  the allocation to the destination and ends when that allocation is released
  or replaced. Cleanup of the drained source does not release it.
- Writes through the current owner remain visible through a live borrowed
  slice. Borrowing does not permit racing mutation, transfer or teardown.
- Self-transfer changes neither allocation nor view lifetime.

The `slice` documentation states these rules.
Do not read a released destination view in a test to prove that it is invalid.

### Caller patterns and failure state

Replacement pattern:

```zig
var next = try acc.add(other);
defer next.deinit();
acc.takeFrom(&next);
```

If `add` fails, `acc` still owns its old allocation and `next` was not built.
Once `next` exists, transfer cannot fail. Its deferred cleanup sees an empty
object; the destination's cleanup releases the adopted allocation.

For an optional owned result, keep the payload mutable rather than taking the
address of an immutable value capture:

```zig
var shared = try acc.intersect(other);
defer if (shared) |*box| box.deinit();
if (shared) |*box| acc.takeFrom(box);
```

The null arm leaves the destination unchanged. Generic `mapResult` continues to
borrow its input by value and return an independently owned nonnull `DynVec`;
its signatures, error set and partial-allocation cleanup do not change.

For an owning container, reserve capacity before committing a transfer into a
valid empty destination element. If reservation fails, the source must still
own its allocation. Do not introduce a by-value consuming wrapper: it cannot
drain a named source and makes a registered source cleanup unsafe.

The deep-copy route remains failure-atomic: an allocation failure changes
neither source nor its live views. It copies component data without checking
or normalizing it, as `fromArray` already specifies. Copying zero components
produces a valid zero-dimensional object without a heap allocation.

### Alternatives and their costs

| Model | When it wins | Reason not selected here |
| --- | --- | --- |
| Explicit owner, existing copy route, one `takeFrom` method | Existing allocated-result callers and generic `mapResult` retain their contracts. | Selected. Raw owning copies remain a caller error; no runtime copy-safety claim. |
| Add `clone` and a value-returning `take` | Frequent copies or direct transfer expressions justify more names. | `fromArray` plus `slice` already copies. A value-returning take can drain before a fallible sink accepts ownership; replacement needs fewer steps with `takeFrom`. |
| Caller-owned storage and output buffers | A kernel already owns a bounded buffer or arena and must not allocate. | Moves lifetime management to every caller, changes allocated-result and generic-map contracts, and changes the subject of allocator benchmark rows. |
| Caller-owned store with slot/generation handles | The requirement is to reject duplicate release and stale handle access in all modes. | Requires a stable-lived store, slot-table storage, checked access and broad error/caller changes. Raw borrowed views still need a lifetime contract. |

If copy-safe release becomes the requirement, use the checked-store design
instead of claiming that this protocol meets it. Such a design must retire
slots before generation wrap, prevent identity reuse after store teardown,
define store synchronization and reject stale access before touching freed
components. A copied handle is not an implicit retain. No global registry,
refcount shim or unchecked public escape is part of that alternative.

These are design costs, not measurements. No timing gain or new performance
baseline is claimed.

### Implementation boundary and migration — complete

- `takeFrom` is the only new method in `src/vector.zig`. Symbol references and
  all existing owning handoffs were checked before migration.
- The type, `fromArray`, `deinit` and `slice` comments state the transfer and
  borrow contracts. The raw-copy warning remains. Fields, constructors,
  arithmetic methods and error sets are unchanged.
- Published replacement examples in `README.md`, executable ownership blocks
  in `fixture/src/readme.zig`, and the ownership test loop now drain mutable
  sources. Deferred source cleanup remains valid. The leak counterexample
  remains explicitly incorrect code.
- `fixture/src/main.zig`, `bench/bench_vec.zig`, `Vec(n)`, `mapResult`, and the
  root export are unchanged. No module, compatibility alias or deprecated path
  was added. A2 links this implemented contract without claiming copy safety.

### Acceptance and verified results

Valid cases run in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall:

1. Replace a nonempty destination with a differently sized source. Destination
   reads the source components, source is zero-dimensional, and all cleanup is
   balanced with source cleanup registered both before and after transfer.
2. Self-transfer of nonempty and empty objects preserves data and live views.
3. Transfer nonempty-to-empty, empty-to-nonempty, empty-to-empty, and from an
   already released source. A retained empty address reused by a new allocation
   must not cause a false ownership-conflict diagnostic.
4. Observe release of the old destination at transfer and release of the
   adopted allocation at destination cleanup, through their respective
   allocators. Transfer performs no allocation or component copy.
5. A source view still reads the adopted components after source cleanup;
   destination mutation is visible through it. Never read a freed old view.
6. Independent `fromArray(gpa, source.slice())` copies survive source mutation
   and cleanup. Nonzero-copy OOM preserves the source; zero-width copy needs no
   allocation. Preserve the existing component representation.
7. Repeated accumulator replacement and nullable intersection have balanced
   cleanup. Forced failure before transfer retains the previous accumulator.
8. Diagnose a direct nonempty copied-owner transfer in Debug and ReleaseSafe.
   Test the refusal, not its exact wording. Do not execute this invalid
   precondition in unchecked modes or claim general copied-owner detection.
9. Run both real package consumers after migration. Keep behavior tests;
   remove constructor-field wiring assertions rather than re-pin them.

Native verification used `zig build test -Doptimize=<mode> -j1`, CPU affinity
`0,1`, local build storage, and the real Zig 0.16.0 compiler:

| Mode | Build steps | Tests |
| --- | --- | --- |
| Debug | 27/27 succeeded | 357/357 passed |
| ReleaseSafe | 27/27 succeeded | 357/357 passed |
| ReleaseFast | 27/27 succeeded | 356 passed, 1 checked-only refusal test skipped |
| ReleaseSmall | 27/27 succeeded | 356 passed, 1 checked-only refusal test skipped |

Both real external consumers pass after migration: 29 API checks and 31 README
checks. The valid transfer cases cover every empty/nonempty combination,
self-transfer, reused empty addresses, cross-allocator release, live source
views, independent copies, signed-zero preservation, nullable replacement and
failure before transfer. Checked children reject a copied-owner transfer and
retain the replaced-address diagnostic. Constructor-field and panic-wording
assertions were removed, not re-pinned. The initial test failed because the
method was absent.

The separate earlier DebugAllocator probe reported a double free when two raw
owning copies were released. That remains a limitation, not a passing safety
test. No new benchmark or speed claim accompanies this method.

## 7. Cancellation pre-pass backlog correction (2026-10-03)

**Status: already implemented at `2edb6094`.** The local handoff's proposed
operand-level cancellation pre-pass was stale. It is not a new optimization
candidate and does not need a second predicate.

`src/lp_exact.zig` has the required order:

1. `combinedColumn` handles structural zero columns first.
2. It calls `cancelsExactly` on the operands **before** the general widened
   `Interval.mul` / `Interval.sub` path.
3. `cancelsExactly` first requires a point factor in each product, then declines
   nonfinite endpoints. A rounded-f64 product-hull mismatch rejects the pair
   before exact arithmetic.
4. A rounded match is not a zero verdict. Exact f128 corner products must
   collapse to the same point, checked by the cross-endpoint equalities.
   Two equal nondegenerate hulls or two merely close products do not qualify.
5. A declined pair keeps the existing widened result. No approximate-zero
   tolerance is used to discard a coefficient.

The pure arithmetic regressions are in `tests/lp_exact_test.zig`; solver
consequences remain in `tests/lp_test.zig`. A native smoke also exercised
`combinedColumn`: an exact cancelling column returned `[0, 0]`, a one-ULP
perturbation retained a nonzero enclosing coefficient, and the predicate
declined nonpoint hulls, unequal products that both underflow in f64, and
nonfinite operands. The full installed gate passed on the pinned code;
each of the four required Linux targets executed 351 tests. Windows was
compile-only coverage.

**Performance decision: no trial and no new speed claim.** The existing
362-row baseline and the rejected 52-row RHS-first trial remain unchanged.
Closing a duplicate backlog item is not a measurement, and it does not show
that no other bottleneck exists.

Reopen this area only for a distinct, profiled cost with a predeclared candidate
and acceptance rule. Keep exact-zero behavior, nonfinite fallback, subnormal
and near-cancellation soundness, row identities and counts, checksums, and
balanced allocation accounting. Use the existing sequential paired-measurement
protocol and benchmark row budget. Do not duplicate this pre-pass, replace
exact equality with a tolerance, or rename the rejected RHS-first trial.

The alternative scale-enclosure formulation in `scale-enclosure.md` is separate
research. This correction neither implements it nor reopens the rejected
rounded `M - W` shortcut.
