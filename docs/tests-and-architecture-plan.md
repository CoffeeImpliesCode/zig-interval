# Tests and architecture — what is verified, what is left, and what is refused

**Written for the session that picks this up cold.** This file is the test and
structure plan. It is not the defect list and it is not the performance record:
those are `docs/next-work-plan.md` and `docs/performance-handover.md`, and
where they overlap this file points at them rather than restating them.

One line about citations. Every `path:line` below was read in the session that
wrote this file, with one exception: `tests/soundness_test.zig` was being edited
concurrently by another agent throughout, so its line numbers drift and its
anchors here are given **by name** (`magnitudeOk`, `screen`, `fuzz`, the `Op`
enum) rather than by number. Everything else is stable and can be jumped to.

**The library in one line.** Over `f64`, every operation returns a result
guaranteed to CONTAIN the true mathematical answer, obtained by computing with
IEEE round-to-nearest and widening each endpoint outward. Soundness outranks
everything. A NaN scalar operand ABORTS in a checked build, and that is a
pinned contract, not an oversight (`build.zig:113-127` builds the probe in
`.Debug` whatever `-Doptimize` says, and says why).

**State of the tree when this was written.** `zig build test` green in Debug,
ReleaseSafe, ReleaseFast and ReleaseSmall, each ending `consumer ok: 29 checks`
(`fixture/src/main.zig:14`, `:502`; the same string is quoted in the build
comment at `build.zig:153`). The oracle reports `0 FAILED`. Eight of eight
operations trap on a NaN scalar. Steps: `install`, `uninstall`, `test`,
`consumer`, `docs`, `bench`, `bench-scalar`, `bench-vec`, `bench-lp`
(the README's build-steps table). Seven read-only audits have run, and
everything below is their verified output.

**Where the 56 comes from, so it is counted rather than inherited.** 28
operations are methods on `Interval` in `src/interval.zig`, 28 are free
functions in `src/interval_ext.zig`, and `28 + 28 = 56`. The `Op` enum in
`tests/soundness_test.zig` names **35** of them; the other **21** are the T4
list. `35 + 21 = 56`. Both figures are counted from the tree, and a document that
restates them without counting them is how the 34-of-55 figure in an earlier
draft of this file survived.

One change since the last four-mode run, and it is the reason section 2 exists:
the elementary functions widen **three** ULP outward rather than two. The width
pins in `tests/interval_ext_test.zig` moved with them and are gathered into one
table in that file's header, so the count is read off in a single place and a
deliberate tightening reads as a decision rather than as a mystery failure.
Nothing else in the tree pins it.

---

## 1. What was verified and is now fixed

Each item was reproduced before it was changed, and the reproduction is given so
a later reader can tell a measurement from an opinion.

**P0, the headline Fourier-Motzkin example in the README passed an inverted
interval.** `README.md:932` read
`interval.Interval.init(1, -1)`, an interval with `lo > hi`, inside the worked
example at `README.md:920-957`. `Interval.init` asserts `lo <= hi`
(`src/interval.zig:212-215`), so the example panicked in a checked build before
it printed a line. Reproduced independently, then fixed to
`init(-1, -1)`. The example now prints
`x in [-5.0000000000000036, 6.000000000000004], y in [-4.0000000000000036, 7.000000000000005]`,
which is exactly the pair of corners the prose at `README.md:959-963` claims
(`2x <= 12` and `2x >= -10` give `x ∈ [-5, 6]`; the mirror gives
`y ∈ [-4, 7]`), each printed a hair outside because a derived bound is an
enclosure and not a corner.

**P1, the README's build-wiring snippet could not be pasted.** `README.md:246-250`
created the consumer's module with `.name` and `.root_source_file` only.
`b.createModule` panics with *"the root Module of a Compile step must be created
with a known 'target' field"* without a target, whatever the options type says,
so the snippet panicked inside the dependent's own build script rather than
inside this library's. Fixed, with `README.md:257-260` now stating the rule
explicitly: pass the same `target` and `optimize` to the module you create and
to the dependency.

**P1, a comment in `build.zig` justifying the benchmarks' second private
ReleaseFast module registration was false.** The registration is gone and the
comment with it (`build.zig:192-210`). The measured rule that replaced it: a
compilation is compiled in the mode of its **root** module, and a module's own
`.optimize` only decides what `builtin.mode` reads inside it. Measured on
0.16.0 two ways: a root in one mode importing a module declared in another
emits or elides safety checks according to the ROOT and not the import, and old
wiring against new wiring hash to the same benchmark binary. So the rule is
"pin the root module", which each of the three benchmark executables already
does at `build.zig:221-249`.

**P1, the second false comment in `build.zig`.** The consumer step's private
cache directories (`build.zig:159-168`) had been justified by a claimed
"global cache lock deadlock". There is no whole-global-cache lock:
`Cache.Manifest.hit` locks ONE manifest at a time, with
`lock_nonblocking = want_shared_lock`, which defaults to true, so a parent and
a nested build can share one global cache. Dropping both flags was measured: the
step finishes in the same ~43 s and prints the same `consumer ok: 29 checks`.
The flags are **kept**, with the true reason in their place: both paths are
relative to the working directory set at `build.zig:169`, so the cache output
lands in `fixture/.zig-cache` — 163 MB at the time the comment was written —
and goes away with the fixture, instead of joining the machine-wide cache this
build shares with every other project. One consequence worth knowing: `fixture`
is one of the six entries in `build.zig.zon`'s `.paths`, and that entry is
recursive, so `zig fetch` or a package hash walks that cache too. `.gitignore`
excludes it from version control; clean it before hashing a package. A false
comment replaced by a true one is the whole of the fix; the behaviour did not
change.

**P0 test gap, closed: `roundUp` and `roundDown` had zero direct tests.** These
are the pair every computed bound in the library passes through —
`src/rounding.zig:156-163` and `:178-185`, used by `add`
(`src/interval.zig:496-500`), `sub`, `scale`, `Corners.loBound`/`hiBound`
(`:186-204`) and by every endpoint of `src/interval_ext.zig` through `lower`
and `upper` (`:167` and `:174`). Ten tests now cover them at
`tests/rounding_test.zig:181`, `:206`, `:225`, `:246`, `:260`, `:293`, `:330`,
`:364`, `:402` and `:429`. They were checked to BITE: mutating the `-inf` arm
of `roundUp` now fails three of them. Before this change that mutation failed
nothing anywhere in the tree.

**Architecture, `min_subnormal` was declared in three upper layers.** It is now
one `pub const` in `src/rounding.zig:97`, the file where the f64 bit layout is
written down (`:68-76`), and its own comment at `:78-96` names the three
consumers and says why the constant lives there rather than in any of them.
Those consumers keep their own trigger and their own width:
`src/interval.zig:192` and `:200` step out past a corner that underflowed,
`src/interval.zig:348-349` and `:784` repair a halving and a square,
`src/vector.zig:148` repairs a squared distance, and
`src/interval_ext.zig:83` takes it as a two-sided slack around a rounded zero.
The dependency already ran this way, so the cutover changed no import graph.

**Architecture, the sign trichotomy is now stated once.** `Interval.signOf()`
(`src/interval.zig:608-613`), its `Sign` enum (`:566`), `Interval.zeroSplit()`
(`:654`) and its `ZeroSplit` enum (`:625`) exist, and three in-file sites use
them: `intersectionOf` (`:703`), `abs` (`:745`) and `sqr` (`:785`). The trichotomy
used to be formalised only in the top layer (`src/lp.zig:86-91`) and open-coded
in roughly 25 places below it. Note one deliberate difference that the lp
cutover in section 4 has to settle rather than inherit: `Interval.signOf`
treats a NaN endpoint as **not** straddling (it fails the "reaches zero" test
and answers `.negative`, so that `init`'s `lo <= hi` assertion is what rejects
a poison), while lp's private `signOf` answers `.straddle` for it because that
is the bare fallthrough of a chain that has already excluded `hi < 0`, `lo > 0`
and both zeros. The two are answering different questions, and merging them is
not a mechanical change.

---

## 2. The confirmed soundness defect, its fix, and the trap in testing for it

**This is the most important thing in this document. Read it before writing any
test that touches an elementary function, and read 2.2 before deciding that a
reference is fine because it passes.**

### 2.1 The defect, and what closed it

`interval_ext.tanh` returned an enclosure that **excluded the true value**.
Take the degenerate interval at

```
x = 0.23139395412799124
```

The true mathematical value is

```
tanh(x) = 0.227350673456281817160566003736656553566288365188421593478113
```

and the lower bound it returned was `0x3fcd19d3ad9bf171`, which is **above**
that truth. The enclosure's lower edge sat above the number it was supposed to
enclose.

The cause was the WIDENING, not the answer. The chain, verified in exact
arithmetic:

| Step | Value | Position relative to the truth | ULP |
| --- | --- | --- | --- |
| true `tanh(x)` | `0.227350673456281817160566003736656553566288365188421593478113` | — | — |
| `std.math.tanh(x)` | `0x3fcd19d3ad9bf173` | above | **+2.1385** |
| `lower(v)` = `roundDown(roundDown(v))` | `0x3fcd19d3ad9bf171` | above | **+0.1385** |
| returned `lo`, two steps | `0x3fcd19d3ad9bf171` | **above** | **+0.1385** |
| returned `lo`, three steps | `0x3fcd19d3ad9bf170` | **below** | **−0.8615** |

The primitive reached 2.1385 ULP out and `envelope` widened by two. Two steps
bring the bound back to the correctly rounded `f64` of the answer and stop, with
the truth still 0.1385 ULP below it. The computed answer was right; the widening
failed to absorb the primitive's error.

**The fix is one number: the elementary step is THREE ULP, uniformly**
(`lower` and `upper`, `src/interval_ext.zig:167` and `:174`, defended at
`:104-166`). Three and not four, and not a wider step for `tanh` alone. The
measured worst signed error of each primitive the file calls, in ULP of the true
value, with what is left of the margin:

```
tanh 2.14 -> 0.86    sinh 1.75 -> 1.25    log  1.50 -> 1.50
log10 1.37 -> 1.63   log2 1.22 -> 1.78    cosh 1.10 -> 1.90
exp  0.87 -> 2.13    tan  0.83 -> 2.17    log1p 0.78 -> 2.22
sin  0.77 -> 2.23    atan 0.76 -> 2.24    cos  0.74 -> 2.26
exp2 0.50 -> 2.50
```

**Why uniform and not per-function.** The count is the auditable artefact: one
number, one place, one table to check a new primitive against. A per-function
step would be a second, narrower rule resting on the same samples, and a margin
taken from a sample has just been shown wrong about one member of the family —
which is exactly the state in which a rule for `tanh` alone is least
trustworthy. The extra step costs two ULP of width, 4.4e-16 relative on a value
near one, and it is paid on purpose: a result one ULP too wide is merely loose,
one ULP too narrow is silently wrong and nothing downstream can detect it.

**What the table still does not say.** These are samples over stated argument
bands, not worst cases over the reals, and seven primitives are not in it at
all: `asin`, `acos`, `acosh`, `atanh`, `cbrt`, `expm1` and `sqrt`. A bound would
take a correctly rounded or formally verified implementation of each, which
this library neither provides nor claims to. Say so when quoting a margin.

### 2.2 The trap

> **The nearest `f64` to the true value IS the bound the two-step code
> returned.**
> `float(true_tanh) == 0x3fcd19d3ad9bf171 == lo`, exactly, bit for bit.
> **So a test that rounds the reference to `f64` reports this interval as
> CONTAINING the truth. It passes. It will always pass. It is worthless.**

This is the trap every future person writing a test for `tanh` will fall into,
and it is worth stating three ways:

1. **Do not write the reference as `@tanh(x)` in `f64`.** `lo <= @tanh(x)` is
   `0x...171 <= 0x...171`, true by construction, and `hi >= @tanh(x)` likewise.
   The test asserts that a correctly rounded value rounds to itself.
2. **Do not write it as `@floatCast` of an `f128` result that came from
   `@tanh`.** The same collapse happens one level down: the whole defect is
   0.14 of an `f64` ULP wide, so a check at `f64` width cannot see it at any
   `f128` provenance.
3. **The `f128` reference is the fix, not the trap** — but only because the
   defect is 0.14 ULP and `f128` carries 113 significand bits. `lo` compared
   against the `f128` value of the truth is a clean violation of 3.84e-18, four
   orders of magnitude above `f128`'s own resolution at that magnitude. The
   oracle's own doctrine (`tests/soundness_test.zig`, the file header) already
   names this: containment is checked against a reference derived in `f128` from
   the ORIGINAL `f64` inputs, "never by evaluating the corners in `f64` and then
   treating those results as truth".

**And the general form of the same trap, which is the one that catches people.**
The three above are one defect at one magnitude. The general form catches every
oracle that forms a finite extremum by **adding** two original `f64`
endpoints, which is `add`, `sub`, `translate`, `expand` and the affine extrema
`scale` builds. A **product** of two `f64` needs 106 significand bits and `f128`
carries 113, so a product is exact. A **sum** is not: the exact sum reaches the
smaller operand's lowest place, and `floatMax - 3` has its highest set bit at
2^1023 and its lowest at 2^0, so it needs about 1024 bits and **rounds back to
`floatMax` even in `f128`**. `1e300 + (-1e-300)` is the same fact at the other
end of the range. Overflow and underflow of `f128` cannot rescue this — neither
is reachable for a sum of two finite `f64` — so a sum that sits comfortably
inside the type's range is exactly the case that fails. It fails silently, and
it fails in the direction that makes the library look correct.

**The fix is an exact residual, not a wider sum.** `TwoSum` yields `s` and
`err` with `s + err` the true sum as reals, so the returned `f64` is compared
against `s` and, where the two are equal, against the sign of `err`. That is
what the oracle does for `add`, `sub`, `translate` and `expand`; `scale` needs
the five-term version, because its extrema are `(A + B + G*A - G*B) / 2` and
`(A + B - G*A + G*B) / 2` and the division by two is a sixth term. What is
**not** acceptable is a `roundDown` / `roundUp` or a `nextUp` / `prevDown`
expression copied out of `src/` and used as the oracle: that compares the
library to itself. The residual is held against the unsafe `[floatMax,
floatMax]` answer for `floatMax - 3` and against `1e300 + (-1e-300)`.

**And one refinement that costs an afternoon if nobody writes it down.** An
`f128` reference is sufficient, but not any `f128` reference: the obvious one
is not. `tanh(x) = (E - 1) / (E + 1)` with `E = std.math.exp(2x)` evaluated in
`f128` cancels catastrophically near zero — at `x = 1e-8` the difference is
2e-8 wide and `f128` holds it to 2^-113, and the error grows as 1/x from there,
all the way down the subnormals the band sweep walks. Compute `E - 1` in its own
right instead and the cancellation never happens. That is exactly what the
landed reference does (§2.3), and a reviewer who reaches for `std.math.exp(f128)`
is reproducing the defect under a new name.

There is a fourth, quieter version of the same trap, and it is why this defect
survived as long as it did: **`tanh` was one of the 22 operations with no
containment oracle at all** when the defect was found. Nothing in the tree was
checking it. The `lo <= hi` invariant sweep in `tests/interval_ext_test.zig`
calls `tanh` and passes, because `lo <= hi` says nothing about whether the truth
is inside. It is covered now (§2.3); the other 21 uncovered operations are the
same trap waiting for the same argument, and section 3, T4 is the work.

### 2.3 The reference and the tests that now hold this line

**The reference.** `tanhRef` in `tests/soundness_test.zig` returns the true
`tanh` of an `f64` endpoint as an `f128` bracket, measured accurate to
**3.1e-34 relative** — 1.4e-18 of ONE ULP of `f64`, eighteen orders of
finer than the grid the defect lives on. It is built from the exponential
identity with the cancellation paid for: `ln2_ref` as a forty-digit literal,
the Taylor series in Horner form to thirty terms below `|t| <= 1`, an exact
power-of-two scaling above it, and `expm1Ref` returning `E - 1` directly so
nothing anywhere subtracts two numbers near one. Past `|x| = 20` it stops
claiming digits and returns the bracket `[tanh 20, 1]`, which is the truth
about that region rather than a number in it.

Three tests use it, and they are layered deliberately:

- **`reproducer 6`** pins the witness. It asserts containment at
  `x = 0.23139395412799124` against the bracket, and it asserts the trap
  itself: that `@floatCast(tanhRef(x).lo)` is exactly `0.22735067345628182`,
  the number the two-step bound returned, and that this rounded value is
  ABOVE the truth. The defect is now a fact the suite checks about itself, not
  only about the library.
- **`fuzz: tanh`** puts `tanh` in the `Op` enum, so it gets the same 8,000
  drawn cases, the same magnitude table and the same containment arm as the
  other 34 covered operations. It takes the band where `tanh` is least steep,
  because that is where the relative error is worst.
- **the directed band sweep** walks `|x| <= 0.5` in 2^18 equal steps, both
  endpoints included, each a degenerate box. This is a COMPLETE check of
  `tanh` over the band, not a sample of it: `tanh` is rising, so the image of
  `[lo, hi]` is the image of its two ends, and containment at both ends implies
  containment everywhere between, exactly rather than approximately.

**What any replacement must keep.** The truth has to reach the comparison
without an `f64` rounding step anywhere in between, and the literal

```
tanh(0.23139395412799124)
  = 0.227350673456281817160566003736656553566288365188421593478113
```

stays as a **second, independent** assertion beside the series. It costs
nothing, it is the only oracle that cannot be quietly re-derived from the code
it is checking, and a reference that is itself a floating-point computation
can one day be wrong in the same direction.

**The rule the whole file is built on, in one line.** A test for a bound needs a
truth more precise than the type the bound is expressed in, and a reference
finer than the type is only sufficient if it is computed without cancellation.

---

## 3. Ranked remaining test work

Ranked by (defect class caught) × (probability the defect recurs), not by cost.
T1, T2 and T3 are **done** and keep their letters because the other two
documents cite them; each says what it bought and what it left behind.

### T1 — DONE: `width` and `distanceTo` are judged as VALUES

`magnitudeOk` in the oracle accepts `+inf` unconditionally and imposes no upper
bound, so `width` returning `+inf`, or `1e9` where the truth is `0.5`, passed
the entire sweep. A SOUNDNESS-shaped one-sided rule where a VALUE check belongs.
Both operations now go through `scalarOk`, the two-sided check already in the
file, against `exactWidth` and `exactDistanceTo` — the difference of the two
`f64` endpoints formed in `f128`, judged to within one ULP.

**What it bought.** The first oracle arm in the tree that can catch a
deliberately-too-wide answer as well as a too-narrow one, and it found things:
a magnitude rule passed all 8,000 cases of both operations while
`Interval.init(-floatMax, floatMax).width()` could come back as anything at
all. The saturation the old rule existed for is still decided correctly, and it
is now decided by the REFERENCE rather than by the rule: the exact width of the
whole format is a real no `f64` holds (3.59e308), so `exactWidth` saturates to
`+inf` there and `+inf` is the value rather than something the reference has to
be widened to. A mutant answering finite `floatMax` at that point is rejected.

**How the acceptance is kept decidable.** The named guard test `guard: width and
distanceTo are judged as VALUES` walks the mutants rather than trusting the
rule: four times the true width, `+inf` for a finite width, `floatMax` for the
whole format's width, and the same pair for `distanceTo`, each judged and each
expected to be rejected — while the library's own answers are expected to be
accepted, including the saturated one. Mutating `Interval.width` to
`return std.math.inf(f64)` turns the sweep red; the mutants here are the same
thing without editing the library.

### T2 — DONE: the infinity frontier, and what it decided

The oracle's random layer screens every non-finite operand out before the oracle
sees it, so 35 sweeps of 8,000 cases each judged the library on finite inputs and
not one of them reached an infinity. The only infinity coverage the tree had was
`lo <= hi`, which asks nothing of the answer. The sweep is therefore directed
rather than drawn — sixteen named shapes, fourteen of them canonical and two of
them pairs the constructor refuses, carried against each other — plus seven
scalars for the operations that take one, of which zero and the two units are
there because `scale`'s contract turns on them. The reference for each case is
built from what an infinite endpoint **stands for**, not from the corner the
library computed, and the canonical reading is derived from the shape rather than
read back from what `init` returned: a sweep whose references move with the code
under test cannot go red. The mechanism is the one the file's header had already
earned: a case with a specific precondition is seeded by name, never drawn.

**What it bought, in the first half.** Seven operations judged at an infinity
(`mul`, `div`, `abs`, `sqr`, `scale`, `hull`, `intersect`), which is thirteen
operations the sweep walks in all. Where the true extremum is a real past the
end of the `f64` range rather than an infinity, the comparison moves to the
frontier through the `lo_beyond` / `hi_beyond` flags the `Range` struct already
carried and nothing had ever set: a saturated `f64` at the frontier bounds such
a real and an infinity pointing the other way does not. The three cases the
original criterion named are covered: the two value cases by T1's arm, and
`mul([-floatMax, floatMax], 0.0)` — a NaN interval the file once reported as
sound — by the `full_range` magnitude class in the random layer.

**What it bought, in the second half.** Six operations returned an answer at an
infinity that is **not** an enclosure under the reading `src/rounding.zig`
itself states. **Two of those six findings were wrong, and are withdrawn**, which
is the more useful half of the result.

- `sub`'s witness was `+ray` minus `-ray`, on the ground that `R - S` can be
  zero. It cannot be: `R >= floatMax` and `S <= -floatMax`, so `R - S >=
  2*floatMax`, and the answer that witness recorded already enclosed that image.
  The real witness is the **same** ray against itself, whose image is the whole
  line — either end can outrun the other by any amount — and which aborted on
  the `inf - inf` corner instead of answering anything. It now answers
  `[-inf, +inf]`, which is its exact image.
- `neg`'s witness was `neg([inf, inf])` answering `[-inf, -inf]` and containing
  nothing below `-floatMax`. That is an artefact of reading the pair as a point.
  Under the canonical constructor the input is the overflow ray and its
  reflection is the ordinary negative ray `[-inf, -floatMax]`, which is right.

The remaining four — `add`, `translate`, `expand`, `recip` — are the same defect
in different arithmetic: an endpoint formed from an infinite operand saturates,
and the saturated value is then used as if it were the endpoint the operand
really stands for.

**How the decision resolved them.** `Interval.init` asserts the caller's
ordering **first** and then canonicalises two endpoint pairs, `(+inf, +inf)` to
`[floatMax, +inf]` and `(-inf, -inf)` to `[-inf, -floatMax]`. That is one
normalisation in one place, and the arithmetic operators needed no new branch:
canonicalising the operand moves the corner onto the finite arm of `roundDown`,
which is `prevDown` and therefore has a full ULP of outward step available,
where the `+inf` arm is `+floatMax` and has none. The endpoint arithmetic itself
is unchanged. `scale` gained one branch for the unbounded input that has no
finite midpoint, `expand` gained the `-inf` precondition, and `translate` reads
an infinite delta as the scalar ray. The defect itself is **D18 in
`docs/next-work-plan.md`**, which owns the table and the decision.

**They are judged, not withheld.** The six `withheld` entries are gone and the
sweep judges all **thirteen** operations it walks — `add`, `sub`, `translate`,
`expand`, `neg`, `recip`, `mul`, `div`, `abs`, `sqr`, `scale`, `hull` and
`intersect` — with nothing withheld. What replaced the withholding is
consumer-visible containment plus canonical-input regression, not bit patterns:
the test that asserted a degenerate infinite box is a point rather than a ray
was **deleted** rather than re-pinned, because under this contract that shape is
unreachable through `init` and pinning it would pin the representation instead of
the behaviour. **The sweep is not green yet**, and the failures are in the
oracle's own references in `tests/soundness_test.zig` rather than in `src/`: a
one-sided "reaches zero" quotient test used two-sidedly on `div` and `recip`,
the same shape of error on `abs` and `sqr`, a zero-factor collapse skipped on
`mul` when the other end is a ray, and an inverted sign in the `-inf` margin
reference for `expand`. Judging rather than withholding is what exposed them.
Per-operation tallies are read from a run rather than recorded here.

**Fully finite frontier shapes sit beside the unbounded ones**, so `div`, `mul`,
`hull` and `intersect` exercise finite corners next to infinite ones instead of
only whole-line rows. `expand` with `-inf` over a bounded input is an explicit
precondition refusal rather than a skipped row — `[-floatMax, floatMax]`
included — and `scale`'s former no-centre skip is gone rather than renamed,
because a box with ONE unbounded end has no finite midpoint either and skipping
only the two-ended ones decided nothing.

### T3 — DONE: the per-operation seed is keyed by LABEL, not by position

`fuzz` used to derive each stream from `seed ^ @intFromEnum(op)`, so a member's
POSITION decided the cases it drew: adding one operation silently re-randomised
every later stream, and with it every figure and every mutation-bite count in
this document and in `docs/performance-handover.md` — with no test failure and no
diff anyone would notice. `streamSeed` now folds an FNV-1a hash of the
operation's **label** into the seed. Nothing about a stream changes from having
another operation inserted anywhere in the enum, so a count printed by one run
keeps meaning against the next: adding a case must change the case, and adding
an operation must not.

**Why it was sequenced first.** T4 appends to that enum twenty-one times, and a
re-key done afterwards would invalidate every measurement made in between. It
is now the reason the numbers in this file and in the handover stay meaningful
as T4 lands.

### T4 — DONE: 1654 independently certified rows over all twenty-one operations

**Done.** `tests/corpus/elementary.txt` carries 1654 rows across all twenty-one
operations the in-tree oracle did not judge, and `tests/corpus_test.zig` checks
every one of them for containment. The reference is MPFR at 256 bits, called
with a declared rounding direction, by `scripts/gen_corpus.c`; the corpus is
committed rather than generated at test time. Current run: **1654 rows checked,
0 FAILED, 390 of them exactly representable.**

#### The blocker recorded here earlier was wrong, and the correction is the useful part

An earlier draft of this entry said MPFR's `mpfr_get_d` "does not honour its
rounding-mode argument" and recorded a probe showing ROUND-UP for modes 0, 2, 4,
6 and ROUND-DOWN for 1, 3, 5 — an alternation, not a rounding table. **MPFR was
fine. The binding was calling a function that does not exist.**

MPFR 4 removed the `d` default parameter: `mpfr_get_d` takes `(srcptr, rnd)`, not
`(srcptr, d, rnd)`. The three-argument call therefore read the rounding mode out
of the wrong register, and the "alternation" was a mis-called ABI. Nothing about
the library was wrong; the thing that needed checking was the binding, and the
only reliable way to check it was to compile against the real header. This host
carries `libmpfr.so.6` and no `mpfr.h`, so `scripts/build_mpfr.sh` builds MPFR
from source to get one.

Two more of the same kind, all found only because the corpus was verified
against an independent source rather than assumed correct:

- **The rounding modes are an enum whose values did NOT change.** An earlier
  draft of this entry claimed MPFR 4 swapped RNDU and RNDD relative to 3.x. It
  did not: both headers read `RNDN=0 RNDZ=1 RNDU=2 RNDD=3 RNDA=4`, checked
  against `mpfr-3.1.6/src/mpfr.h` and the 4.2.1 header directly. The claim was
  inferred rather than measured, and the code was never affected because it
  uses the named constants — but a wrong explanation in a record is still a
  wrong record. Read the numbers out of the header being compiled against.
- **The ternary is not a NaN flag.** It is `0` exact, `+1` inexact-rounded-up,
  `-1` inexact-rounded-**down**. An earlier version guarded with `t1 >= 0`, which
  reads every inexact result as a failure and silently kept only the exact rows:
  the tier reported green while checking nothing but `exp(0)` and `sin(0)`. NaN
  is now tested on the value.

That last one is the reason the mutation below was run rather than assumed. A
corpus tier that passes is only evidence once it has been seen to fail.

#### The mutation, and the direction that works

Pushing `exp`'s brackets 16 ULP past the library's margin turns it red — the
first two attempts at this mutation were in the wrong direction and passed
cleanly. Containment is `got.lo <= want_lo and got.hi >= want_hi`, so a
bracket is made unmeetable by moving `want_lo` **below** the library's widened
bound or `want_hi` **above** it — the opposite of what "tighten" suggests, and
the opposite of what the first two attempts did. Raising `want_lo` relaxes the
lower condition; setting it to `+inf` relaxes it completely.

#### The generator spec, as implemented

**Source of truth.** MPFR at **256 bits**, called with an explicit rounding
direction on every call. One function per `src/interval_ext.zig` operation,
mapped to its MPFR counterpart; `pow` and `powf` both map to `pow`, `pow` with
its integer exponent read exactly rather than rounded.

**Each corpus row is a quintuple, every field certified rather than
approximated:**

| field | how it is obtained |
| --- | --- |
| `op` | the operation name |
| `lo`, `hi` | the `f64` argument endpoints as exact hex, so no decimal parsing is in the path |
| `want_lo` | `mpfr_get_d(f_down, RNDD)`, where `f_down` is the function evaluated at 256 bits rounding toward `-inf` |
| `want_hi` | `mpfr_get_d(f_up, RNDU)`, where `f_up` is the same function at the same precision rounding toward `+inf` |
| `ternary` | MPFR's return code, kept: `0` exact, `±1` inexact with the sign giving the direction of the rounding error |

**Why evaluating down and up separately is required, and not a belt-and-braces
extra.** Evaluating once at 256 bits and rounding the result to `f64` rounds
TwICE, and the second rounding is not the one that was certified. Evaluating
the two directions separately and converting each with the matching direction
makes the bracket contain the true value by construction rather than by
argument.

**Exactness is kept separate from strictness.** A row with ternary `0` is exact
and its bracket may be a single point; a row with a non-zero ternary is inexact
and its bracket must be a genuine interval. Folding the two together loses the
ability to tell "the answer is exactly this" from "the answer is near this" —
and that distinction is the whole of §2.2's trap.

**Arguments.** Endpoints are drawn from the `f64` bit patterns the finite sweep
already draws, plus the named infinite shapes, so the corpus exercises the
operands the oracle does rather than inventing a second distribution. At least
one row per operation per shape.

**Where it lives.** A committed `tests/corpus/<name>.txt` of hex endpoints and
hex bounds. Committed, not generated at test time: a test that shells out to
Python is not a gate, and a corpus nobody can read is not evidence.

**How it is consumed.** `tests/soundness_test.zig` grows a tier that reads each
row, calls the library, and asserts `want_lo <= got.lo and got.hi <= want_hi`.
Containment of the certified bracket, which is the only sound direction.
Tightness is NOT asserted — a corpus bounds correctness, not width, and a
tightness claim is what §2.2 shows goes wrong.

**The evidence that it bites, required before this item closes.** Tighten
`want_lo` by one `f64` ULP for one named operation; that operation must then
report `FAILED`. A corpus that cannot be made to fail proves nothing, and this
is the standard the frontier sweep and the `f128` bounds in §2.3 were held to.

**What it was.**

This is the largest item and the one with the most leverage left in it. The 21
are `pow`, `powf`, `exp`, `exp2`, `expm1`, `log`, `log2`, `log10`, `log1p`,
`sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `sinh`, `cosh`, `asinh`,
`acosh`, `atanh` — all in `src/interval_ext.zig`. `tanh` was the 22nd and is
done (§2.3); it is the one reference already written, and its shape is the
eighth one below, which the table did not have.

**They are grouped below by the shape of reference that works for them, because
the shape is what decides whether a containment oracle is affordable at all.**
The recorded blocker ("Zig 0.16's `f128` transcendentals are not wider than
`f64`") is TRUE as stated, and the inference drawn from it was WRONG. Calling
`@exp`/`@log`/`@sin` on an `f128` really does give an answer only f64-accurate —
over 20,000 draws they equalled the `f64` evaluation every time, and
`@sin`/`@cos`/`@tan` on all but a few dozen. But **writing the series out by
hand in `f128` arithmetic** reproduces the truth to about 2^-118, which is
thirty-odd orders of magnitude below the three-ULP margin the library applies and
enough to make the reference an independent check rather than a restatement of
the primitive. The oracle is buildable today.

**Direction changed after this section was written, and T4 is still open.** The
eight hand-written shapes below were the design; they are kept here as the
fallback analysis, not as the plan. The direction is an **independently
generated MPFR directed-rounding containment corpus**: the oracle would be
checked against values produced by an external arbitrary-precision library at a
declared rounding direction, using its ternary return code to keep strictness
and exactness apart, and the tightest enclosing `f64` floor and ceiling of each
would be certified rather than approximated. A hand-written `f128` series is a
**second implementation of the same function**, and the audit needed to convince
anyone it is correct costs more than the coverage it buys — which is the same
reason §2.2's trap is fatal to a rounded `f128` result. No shape table is
authorised, and no reference is written, until the generator spec and the
evidence that the corpus actually bites are in hand. Nothing here has been
implemented: all **21** remain uncovered.

The current probe says the direction is reachable rather than hypothetical, and
it is evidence about the **backend**, not a substitute for the corpus: `gmpy2`
2.3.1 on MPFR 4.2.2 returns `rc = (-1, +1)` for directed `RoundDown` / `RoundUp`
on `sin`, `cos`, `sinh`, `cosh`, `log1p` and `atanh` at `minsub`, and certifies
binary64 floor and ceiling for `exp(±floatMax)`, `expm1(-floatMax)` and
`1.0000000001^1e8`. Ten directed ray-endpoint certificates at 256 bits came back
clean for `sqrt`, `cbrt`, `log`, `log2`, `log10`, `log1p`, `asinh` and `acosh` on
both overflow rays. **That is a backend probe and a ten-case spot check, not the
gate.** The gate is thousands of reproducible cases per operation, every one of
them decided.

**Shape 8, and it is the cheapest of the eight: the defining identity, with the
cancellation paid for.** `tanh` was solved without a `tanh` series at all, and
the reason generalises. `tanh(x) = (E - 1) / (E + 1)` with `E = exp(2x)` carries
the whole real line, and `expm1Ref` returns `E - 1` in its own right — the
series itself below `|t| <= 1`, one subtraction against a number of at least
`e` above it — so nothing anywhere cancels. Measured worst relative error of the
construction: 3.1e-34, which is 1.4e-18 of one ULP of `f64`. `expm1` is on the
list above and is the same primitive with one fewer step; `sinh` and `cosh` are
half a sum and half a difference of exponentials that share this reference.
**What does not transfer is the naive form.** Computing `E - 1` as a difference
of two numbers near one inside `(E - 1)/(E + 1)` reintroduces exactly the failure
of §2.2 at a different magnitude, and a reviewer who writes it will not see it in
the answer.

| Shape | Operations | What the reference is | Why the shape is affordable |
| --- | --- | --- | --- |
| **1. Exact rational, no transcendental** | `pow` | `x^n` at the endpoints, plus the interior extremum (0 for even `n` when the interval spans it), compared against the returned `f64` bounds in exact integer arithmetic | `(p/q)^n` needs more than 113 bits for `n >= 3`, so it is done in big integers, not `f128`. The library's own answer accumulates one `mul` widening per exponent bit and is many ULP wide, so the comparison has enormous slack. `pow` needs no series at all |
| **2. Power-of-two reduction, then a series with an exact-rational tail bound** | `exp`, `exp2`, `expm1`, `sinh`, `cosh` | Reduce `x` to a small window by dividing by an exact power of two (exact in binary FP), sum the series in exact rational arithmetic, bound the tail by the first omitted term times a geometric factor | Binary reduction produces a **dyadic** argument, so every term of the series is an exact rational and the reference error is set by the TAIL BOUND, not by any floating-point rounding anywhere. Shape 8 above beats this for `sinh` and `cosh`, since the exponential reference is already written |
| **3. Binary-exponent extraction, then a normalised-mantissa series** | `log`, `log2`, `log10`, `log1p` | `x = m·2^e` is exact for a normalised `f64` (both `m` and `e` exact, the product exact by construction), so `log x = e·log 2 + log m` with `m ∈ [1, 2)`; `log m = 2·atanh((m-1)/(m+1))` converges at 1/3 per term. `log1p` needs the same for `1+x`, **which is exact in `f128` only while `x` is not far below 1 in magnitude**: the exact sum reaches `x`'s lowest place, so `1 + 2^-1074` needs about 1075 bits and does not fit. Treat the `f128` sum as a rounded value and judge `log1p` at a width that rounding can justify, or use the exact residual comparator from §2.2 | The reduction is EXACT, not approximate, so it contributes nothing to the error budget. Only the series does, except where `log1p`'s own sum is formed first — and that is §2.2's trap again |
| **4. Certified-π reduction, then a truncated series** | `sin`, `cos`, `tan` | Reduce to `[-pi/4, pi/4]` using the two certified `f64` bounds at `src/rounding.zig:189-197` widened into `f128`, with the quotient rounded once; the residual is small and the series is exact rational. `tan` is `sin/cos` with the pole settled by the same sign rule the library uses | This is the only shape that needs a rigorous range reduction, and the reduction is the hard part. The library deliberately does NOT reduce (`src/interval_ext.zig:34-38`), so this reference is independent of the implementation rather than a restatement of it |
| **5. Reference by composition through the defining relation** | `asin`, `acos`, `atan`, `asinh`, `acosh`, `atanh` | No new series. For a monotone branch, `x ∈ f⁻¹(X)` if and only if `f(X)` contains `x`, evaluated in interval arithmetic against the **oracle's** `sin`/`cos`/`tan`/`sinh`/`cosh`/`tanh` (shapes 2 and 4), never the library's | Each of these is exactly the inverse of a function the oracle will already have. They are nearly free once shapes 2 and 4 exist, which is why they are not ranked with them |
| **6. Reference by composition through the library's own identity** | `powf` | `powf` IS `exp(log(x)·y)` composed from the library's own operations (`src/interval_ext.zig:308-318`). The reference composes the same identity from the oracle's `log` and `exp` (shapes 2 and 3) through rigorous interval algebra | The library's guarantee already rests on the composition being sound; the oracle checks the composition against two INDEPENDENT references rather than against itself. `powf` needs no transcendental of its own |
| **7. Two-argument, quadrant by quadrant** | `atan2` | Not a composition. The quadrants at `src/interval_ext.zig:469-491` are four separate cases and each needs its own reference, with the sign of `x` and whether `y` reaches zero deciding which | **This one is NOT READY.** What is missing: a decision on whether the reference is a Taylor series in each quadrant, or a bounded search over certified `atan` values that brackets the true angle. The second is cheaper and sound; neither has been written. Do not fake it with `@atan2` — that is the `f64` trap of section 2 wearing a different hat |

**Acceptance, per operation added.** Three things, all decidable:

1. The operation appears in the `Op` enum and the sweep reports `0 FAILED` for
   it, with a non-zero case count.
2. **The reference bites.** Tighten the series tail bound by a factor of
   `2^-40` and the operation must report `FAILED` on at least one case. A
   reference that cannot be made to fail is not a reference.
3. **For an operation whose defect has a known witness, the witness must be in
   the case set**, not merely its result. `tanh` at
   `0.23139395412799124` is pinned by name in `reproducer 6` because a sweep
   that never draws it would not find that defect again even with a perfect
   oracle — the argument sits in a sliver, and random draws land elsewhere.

Ship in shape order, not operation order: shape 1 is a day, shape 8 is written,
shapes 2 and 3 are the bulk of the work and unlock 9 operations, shape 4 is the
hard one and unlocks 3 plus all of shape 5, and shapes 5 and 6 are then
arithmetic on references that already exist.

### T5 — DONE: `phase_limit` fallback coverage, and the spec's own boundary was wrong

**Done, with two corrections to the spec this replaces.** Both were found by
running the acceptance as written and are recorded because the same two errors
would otherwise be made again.

**The spec's arguments did not reach the branch it named.** `phaseResolvable`
compares with `<=`, so an argument of EXACTLY `phase_limit = 1e17` is still
resolvable and goes through the critical-point search. Two of the four named
inputs — `sin([1e17, 1e17])` and `tan([1e17, 1e17])` — therefore answer from
their endpoints and are narrow, not `[-1, 1]` and `[-inf, inf]`. The tests use
`1e18` and `[-2e17, 2e17]`, which are past the line.

**The spec's mutation was backwards.** It said lowering `phase_limit` to `1e3`
would turn `sin([100, 100.5])` into `[-1, 1]`. Lowering a limit makes MORE
arguments resolvable, not fewer: `100 <= 1000`, so that test stays green and
proves nothing. What fires is the other direction, and both directions were
run:

- **Raising `phase_limit` to `1e20`** makes `1e18` resolvable, and both new
  tests go red. That is the mutation that proves they reach the branch.
- **Lowering it to `1e1`** makes `100` unresolvable, and `sin([100, 100.5])`
  answers `[-1, 1]` — so its `s.lo > -1.0` goes red, along with the two other
  existing `sin` tests that find critical points. That is the mutation the
  spec was reaching for.

**The boundary is now pinned from both sides, which the spec did not ask for
and which is the more valuable half.** `sin` of exactly `phase_limit` is
asserted to come back NARROW (width under 2, rather than the fallback's exact
2), and `nextUp(phase_limit)` is asserted to come back exactly `[-1, 1]`. One
ULP of the constant moves a test. The width is asserted rather than the
endpoints because the resolvable answer is `sin` at a fixed argument widened by
three ULP, and where that argument happens to land is not a property this file
should depend on.

**What it was.**

`sin`, `cos` and `tan` answer with the whole range each spans once the argument
passes `phase_limit = 1e17` (`src/interval_ext.zig:63`, reached through
`phaseResolvable` at `:220-222`), and `tan` with the whole line. The largest
argument anywhere in the tree is 100.5, at `tests/interval_ext_test.zig:233`.
So the fallback at `:418`, `:445` and `:480` is **completely unexercised**,
and a defect there is invisible.

**What it adds.** Coverage of three branches that currently cannot be reached by
any test, on the operations whose range is widest.

**Acceptance.** Four named inputs, exact answers:
`sin([1e17, 1e17]) == [-1, 1]`, `cos([1e18, 1e18]) == [-1, 1]`,
`tan([1e17, 1e17]) == [-inf, +inf]`, and
`sin([-2e17, 2e17]) == [-1, 1]`. **And the mutation must fire:** lowering
`phase_limit` to `1e3` must make `tests/interval_ext_test.zig:236` fail, because
`sin([100.0, 100.5])` would then return `[-1, 1]` and the existing
`expect(s.lo > -1.0)` at `:239` would go red. If that mutation is green, the
new tests are not reaching the branch.

### T6 — DONE: `pow` beyond integer endpoints and integer exponents

**Done, and this item was NOT gated on T4 after all.** The paragraph below says
"this item closes with T4's corpus rather than ahead of it". That is true of
`pow`'s CONTAINMENT COVERAGE in general and false of this item's own acceptance
cases, both of which are exact in `f64` and need no reference library at all:
`0.5^5 = 2^-5`, `2^5 = 32`, `3^4 = 81`. A reference would have been the
§2.2 mistake, and none was needed.

**Three rows.** `pow([0.5, 2], 5)` encloses `[0.03125, 32]`; `pow([-2, 3], 4)`
encloses `[0, 81]`; and `pow([1/3, 2/3], 3)` covers a base whose corners are not
exact at all, which is the case the integer-base tests could never reach.

**The mutation fires, but not on the row this item predicted it would.** Taking
`result = result.mul(base)` as the same corner product in raw `f64` with no
outward step turns the FRACTIONAL row red and leaves `[0.5, 2]^5` green —
because the squarings still go through the real `base.mul(base)`, and their
widening survives into the final product. That is worth recording rather than
tidying away: the row whose corners are exact is precisely the row that cannot
detect a missing step in `result`, and an earlier draft of that test's comment
claimed otherwise. The comment now says so.

**A tightness observation the test records rather than asserts.** `pow([-2, 3],
4)` answers far below the true minimum: `intPow` squares with `base.mul(base)`,
and interval multiplication has no symmetry to exploit, so `[-2,3] * [-2,3]`
comes back `[-6, 9]` rather than `[0, 9]` and the looseness compounds. Sound,
and loose — the price of the `O(log n)` shape. No tight lower bound is asserted,
because none is promised.

**What it was.**

Every `pow` test uses an integer exponent and integer base endpoints
(`tests/interval_ext_test.zig:146-177`), so the per-multiply widening that
`intPow` accumulates (`src/interval_ext.zig:253-265`) is never exercised on a
base with endpoints of different signs or a fractional magnitude, and a `pow`
that dropped one widening would pass.

**What it adds.** The accumulation path of exponentiation by squaring, which is
the only reason `pow` is implemented that way rather than as a loop of `n`
multiplies.

**Acceptance.** A named case held to an exact reference: `pow([0.5, 2.0], 5)`
must enclose `[0.03125, 32]`, and `pow([-2.0, 3.0], 4)` must enclose the true
image including the interior minimum at 0. The reference is exact integer
arithmetic, not a rounded `f128` sum, for the reason §2.2 gives. **And the
mutation must fire:** replacing `result = result.mul(base)` at
`src/interval_ext.zig:258` with the same corner product taken in raw `f64` with
no outward step must make the new case fail. Nothing here is written yet: `pow`
is still uncovered, and this item closes with T4's corpus rather than ahead of
it.

### T7 — DONE: `powf`'s reference replaced, not reused

**Done.** `exactPowf` and `powf_slack` are deleted from
`tests/soundness_test.zig`. The `reproducer 3` test has MOVED to
`tests/corpus_test.zig`, keeping its name and its claim, and now reads its
reference from the MPFR corpus instead of from an `f128` evaluation of
`exp(y * log x)` — which was a second implementation of the same function,
computed with primitives Zig 0.16 only reaches `f64` accuracy with, so it
inherited the very error the oracle exists to detect. It passed because
`powf`'s answer is many ULP wide and swallowed the reference's error.

The argument pair `1.0000000001, 1e8` is now in the corpus because the
generator was given it for this reason: a corpus that does not contain the case
cannot certify it. The certified bracket is `[1.010050167919382,
1.0100501679193823]`, and the library answers `[1.0100501679193816,
1.010050167919383]`.

#### The mutation this item specifies does not fire, and the reason matters

The acceptance says "tightening that reference by `1e-18` relative must make
`powf` report `FAILED`". Run against the corpus, it does **not**:

- tightening that row by **1e-18** relative leaves the build **green**
- tightening it by **1e-15** relative turns it **red**

The item's number was written for the OLD reference and does not transfer.
`exactPowf` widened by `powf_slack = 1e-28`, which on a value near 1 is far
below one `f64` ULP — so its bracket was, in practice, a **point** at the
rounded `f128` value, and "tightening by 1e-18" was a large relative change to
that point. The corpus bracket is a genuine interval about 1e-16 wide, so 1e-18
is deep inside it and tightening by that much changes nothing at all.

**What keeps the reproducer honest instead.** The half of the old assertion
that had teeth was its WIDTH check, and the reference is what supplied the
scale for it. So the reproducer now asserts the claim directly, with no
reference: `powf`'s answer is 1.319e-15 relatively wide at an exponent of
1e8, and the test requires that to stay under 1e-14. That is "the fixed margin
does not grow with the exponent" stated as a fact about the answer. Tightening
that bound to 1e-16 turns it red, which is the same evidence the old width
check produced and is recorded here so the number in the acceptance is not
reused as-is.

**What it was.**

`powf` has **exactly one** containment assertion in the whole tree, at the
`reproducer 3` test. Its reference, `exactPowf`, is unsound and must be
**replaced, not reused**:

- it evaluates `@exp(ex(y) * @log(ex(x)))` on `f128`, and Zig 0.16's `f128`
  transcendentals are f64-accurate — the file's own header says so and gives
  the measurement. So the reference inherits the very error the oracle exists to
  avoid;
- it then declares `powf_slack = 1e-28` relative. The reference is accurate to
  about 1e-16. The claim is twelve orders of magnitude tighter than the thing
  measured, which makes the assertion a razor around a point that may itself be
  wrong. It passes today only because the library's answer is many ULP wide and
  swallows the reference's error, which is not evidence of anything.

**Acceptance.** `exactPowf` is deleted; `powf` is a member of the `Op` enum with
a reference from the directed-rounding corpus; and tightening that reference by
`1e-18` relative must make `powf` report `FAILED`. The old single-assertion
test stays, because the `1.0000000001^1e8` case at the reproducer is a
regression worth pinning, but it must be re-pointed at the corpus result, which
the current probe has already certified once. **T7 is OPEN and its spec is not
fixed**; it is closed by the same corpus decision as T4, not ahead of it.

### T8 — MOSTLY DONE: the re-export half is closed, at compile time

**The half that was actually missing is now closed, and the gap was real.**
Nothing in the tree named `src/root.zig`'s forty top-level re-exports. The
namespace test looks INSIDE `ext` and `lp`, and the fixture's README
transcriptions touch only a handful of the top-level names, so deleting any one
of the forty broke nothing at all. `tests/interval_test.zig` now names all
forty with `@hasDecl` under an `inline for`, which makes every question
comptime and therefore answered by the compiler.

Measured, not assumed, and both directions run as the acceptance requires:
removing `pub const acos = ext_mod.acos;` fails the build with "root source
file struct 'root' has no member named 'acos'", and restoring it goes green
again. The check landing as a compile error rather than a failing assertion is
the better outcome — it cannot be skipped, and it costs nothing when it passes.

**What it cannot see, stated so a later session does not over-read it.** An
ADDITION. A module has no decl count to compare an expected list against, so an
extra top-level re-export is caught only by the README's API tables going
stale. The namespace test does carry exact-set checking for `ext` and `lp`,
where `@typeInfo(...).decls.len` does exist.

**The other half of this item was already done and is not redone.** "Each README
example as its own executable" is not what the tree has: the fixture compiles
and RUNS every example in one file, `fixture/src/readme.zig`, with 31
containment checks. That is not identical — a broken example would fail all of
them at once — but the compile coverage is the same, because an example that
does not compile fails the fixture. Splitting them buys isolation of failure
reporting, not additional proof, and it has not been done.

**What it was.**

The fixture proves a consumer can resolve the module graph and run 29
behavioural checks. It does **not** prove that a single README example compiles
— and two of three were broken, which is the only reason section 1's first two
items are P0 rather than P2. It also does not catch a missing re-export or a
signature a consumer cannot call, because nothing in the tree names the public
surface without also using it.

**What it adds.** The only class of defect in this list that a runtime test
cannot see at all.

**Acceptance.** A build step compiles each README example as its own executable
against the fixture package; and **deleting any one `pub const` re-export from
`src/root.zig` must make that step fail to compile.** Two-sided: the probe must
also go green when the re-export is restored. Without the deletion check the
step proves nothing.

### T9 — DONE: the refusals were pinned first, and F2 then changed exactly that test

**Done, in the order this item asked for, which was the whole point of it.** The
refusals were pinned BEFORE anything changed them, by a test naming the three
partly valid arguments and asserting `null` on each. `F2` then landed and
changed that test and only that test — which is the acceptance criterion, met
literally rather than approximately.

**What the pin bought beyond the acceptance.** The three WHOLLY invalid
arguments were pinned in the same test, so a change that clips could not pass
by making everything non-null. That is the failure mode clipping introduces and
the one a refusal could never have had, so it is the half of the pin worth
having.

**What it was.**

`asin` (`src/interval_ext.zig:489`) and `acos` (`:497`) return `null` unless the
WHOLE interval lies inside `[-1, 1]`, and `atanh` (`:576`) returns `null` unless
it lies strictly inside `(-1, 1)`. So `atanh([-2, -0.5])` returns `null` where
the true image is `[-inf, atanh(-0.5)]`. **Sound but lossy.** The feature that
clips to the domain instead of refusing is `F2` in `docs/next-work-plan.md`,
which owns the ranking, and is not this file's business; what is this file's
business is that the loss is currently **pinned by no test**, so a replacement
could change the null into something else and nothing would notice.

**Acceptance.** A test naming `atanh(Interval.init(-2.0, -0.5))` and asserting
`== null`, plus one for `asin(Interval.init(-1.5, 0.5))`. When `F2` lands, that
test changes and only that test changes.

### T10 — Split `tests/soundness_test.zig`

The file is one flat several-thousand lines holding four unrelated concerns: the exact
and bracket reference layers, the fuzz machinery, the frontier sweep, the
per-operation reference switch, and a set of named reproducers and guards. It
is the largest file in the tree and the hardest to read, and it is the file the
next twenty-one operations go into.

**This is the lowest-ranked item on this list and it is ranked there
deliberately.** Splitting it fixes no defect and catches no regression; it costs
a careful move of the `Op` enum, the seed derivation and three shared helpers
across four files, on the file that guards the library's central claim. Do it
**after T4, never before**: moving the seed derivation and the enum while the
enum is being appended to is how a stream gets silently re-keyed. T3 has already
removed the hazard that made this the dangerous half of the job.

**Acceptance.** Each of the four concerns heads its own file, each is a
registered test step in `build.zig`, and `zig build test` still runs all of
them with the same report. Decidable, and no more than that.

---

## 4. Ranked architecture work

Ranked by (correctness risk) × (future defects prevented), the ranking the
audits produced. Every acceptance criterion here is an observable end state,
and most are a probe that must **stop compiling**. A2 and A4 are **done** and
keep their letters because the other two documents cite them; each says what it
bought and, where it applies, what it did not.

### A1 — DONE: `Lin.coeffs` is `[]const Interval`, and `Lin.op` is deleted

**Done.** Both write doors are closed at the type level, which is the only
place they can be: `Lin` is now `struct { coeffs: []const Interval, rhs:
Interval }`, and `at` hands out that view.

**What it bought.** A caller who wrote through a row from `at` was editing the
solver's own coefficient storage, and the measured consequence was `bounds(0)`
going from a real interval to `null` while `isUnsat()` still said no — a
solver that had proved a projection unbounded, reporting it as proven. That is
now a compile error rather than a silent wrong answer. The `op` door was worse
in kind and is gone entirely: it was `.le` in every row by construction, so a
write to it changed nothing and read back as a lie.

**The cutover was source-compatible in-tree, as this item predicted.** Every
site that touched a row was a read, and the single test that asserted
`.op == .le` now asserts the shape a row reads back with instead.

**How the acceptance was checked, and what is permanent.** The two compile
probes are in the tree at `probe/row_coeffs.zig` and `probe/row_op.zig`,
deliberately outside `tests/**` so the house gate's `test-paths` glob cannot
pick up a file that is supposed to fail. Both were compiled: the first fails
with `cannot assign to constant` at the write, the second with
`no field named 'op' in struct 'lp.Lin'`.

A file that must not compile cannot belong to a build step, so the PERMANENT
check is a type-level assertion in `tests/lp_test.zig`: `@hasField(lp.Lin,
"op")` is false, and a `comptime` block fails the build if `Lin.coeffs` stops
being exactly `[]const Interval`. It was mutation-verified — relaxing the field
back to `[]Interval` fails the build with its own message — which is what
stops a probe from quietly starting to compile again.

**What automatic compile-failure wiring would take, and where it belongs.**
Running those probes from the build needs a step that compiles each and
inverts its exit status. That is the machinery `T8` is about, and it belongs
there rather than being built twice.

**What it was.**

`src/lp.zig:76-80`, read by `at` at `:177`. Two live write doors into the
solver's own storage, and both change its answers **silently**.

**The proof that this is not theoretical.** One assignment to a `coeffs` element
of a row obtained from `at` changed `bounds(0)` from a real interval to `null`,
with `isUnsat()` still false. Nothing threw, nothing was logged, and a solver
that had proved a projection unbounded reported it as proven. A caller who
believed `at` handed out a view it must not write through has no way to find
this out except by auditing.

`op` is worse in kind. Every stored row has `op == .le` by construction
(`:9`, `:12`, `:61`, and the only construction site `at` at `:177-184`
hard-codes `.le`). It is `.le` in every row the library builds, and a write to
it is a silent no-op that reads back as a lie.

**What it costs.** Nothing. `add` already takes `[]const Interval` (`:195`),
`pushRow` does (`:679`), `appendSlice` does, and every in-tree site that touches
a row is a read. The change is source-compatible in-tree and makes every
out-of-tree write a compile error.

**Acceptance.** A compile-only probe in the tree that does
`const row = try sys.at(0); row.coeffs[0] = other;` **must stop compiling** with
a `const`-mutation error. Second, probe: `row.op = .eq;` must also stop
compiling, because the field is gone. Third, `zig build test` stays green — which
is the check that the cutover really was source-compatible.

### A2 — DONE: `DynVec` has an ownership trap, and `mapResult` takes a box

`src/vector.zig:434` (the allocator), `:439` (`comps`) and `:446` (`own`).
Both fields were `pub` by virtue of being fields of a `pub const` type, and
`deinit` freed `self.comps` with `self.gpa`: reassign either and it freed memory
the box does not own, a double free or a free of a caller's stack, with no
diagnostic. Zig 0.16 has **no field privacy**, so the fix is a trap rather than
a wall.

**What it bought.** The type now records the address of the slice its
constructor allocated (`own`), and `deinit` (`:482-504`) compares it under
`std.debug.runtime_safety` and panics with a message naming the mistake rather
than the symptom. The check is written out by hand rather than as
`std.debug.assert` because an assert reports "reached unreachable code". The
address rather than the length is what makes it hold: the slice is swapped for
an empty one before the free, so a second `deinit` frees nothing, and a box
reassigned a foreign slice of the SAME width is still caught. `mapResult`
(`:774`) rejects a pointer argument at comptime with a message saying to pass
the box rather than a pointer to it, and its error union no longer carries
`error.OutOfMemory` for a `Vec(n)`.

**The half that remains.** This closes the free path. `deinit` still cannot
make a COPY safe to free — two boxes over one slice are still two owners — and
it says so in its own comment rather than pretending otherwise. That is the
remaining ownership work, and it is a different item from this one.

### A3 — DONE: one public sign-bucketing rule, and the benchmark gate stopped having its own

**Done, and the gate ended up with less than the acceptance asked for.** All
three parts of the acceptance below are met, and the last is stronger than it
was written to be.

- **The gate delegates rather than shares.** `requireRowBudget` in
  `bench/bench_lp.zig` holds no copy of the rule at all: it calls
  `System.rowsAfterEliminating` (`src/lp.zig:562`), which is `pub` and tallies
  through the solver's own `partitionInto`. The acceptance asked that the gate
  call the one public bucketing function and keep no float comparison of its
  own. There is now nothing in the gate left to compare, so the divergence
  cannot be reintroduced by editing the benchmark alone — which is the whole
  point of the item.
- **The private copy is gone.** `grep 'fn signOf' src/lp.zig` returns nothing.
  `eliminate` reads the public `Interval.signOf` through the `Sign` trichotomy
  (`src/lp.zig:524`), and `boundDivisor` (`:1250`) is the one place a divisor is
  read for a bound.
- **The NaN arm is settled by a test rather than by the merge.**
  `Interval.signOf` answers `negative` for a NaN endpoint, computed as a
  comparison rather than as the absence of a better answer, and
  `tests/lp_test.zig` pins what the solver does with such a row: it fails the
  test for reaching zero, answers `negative`, and is filed in ONE list with its
  coefficient carried through unchanged. `tests/interval_test.zig:996` and
  `:1004` pin the same rule on both canonical rays.

**What it bought.** The gate and the solver can no longer disagree about where a
coefficient sits relative to zero — the one failure on either list whose damage
would have been invisible to the thing built to detect damage. It also closed a
real hazard on the way: Zig's `@min`/`@max` are NaN-suppressing, so the old
fallthrough-to-straddle classification laundered a `[-5, NaN]` coefficient into a
well-formed `[-5, 0]` and dropped the poison.

**What it was.**
The rule for where an `x_k` coefficient sits relative to zero WAS open-coded in
**five** places, and one of them was a correctness gate. Cite these by name; the
line numbers drift every time the solver is edited:

| Site | File | Form |
| --- | --- | --- |
| `eliminate` | `src/lp.zig` | shares the private `signOf` |
| `bounds` | `src/lp.zig` | shares the private `signOf` |
| `derivesContradiction` | `src/lp.zig` | shares the private `signOf` |
| `pairCount` | `src/lp.zig` | shares the private `signOf` |
| **`predictedRows`** | **`bench/bench_lp.zig`** | **open-codes it: three float comparisons, its own `if` chain** |

**What has changed under it, and it is what makes the merge decidable.** The
public half now exists: `Interval.signOf` (`src/interval.zig:608-613`) states the
trichotomy once, with `Sign` at `:566`, and `Interval.zeroSplit` (`:654`) is the
second question of the same shape. Three sites in `interval.zig` already use
them. So the item is no longer "factor out a rule that does not exist" — it is
"point five call sites at a rule that already has a name, and decide what the
name means for a NaN".

**Why this is ranked this high.** `requireRowBudget` in `bench/bench_lp.zig` is
the gate every elimination in that benchmark passes through, and it exists to
stop the row explosion recorded in `docs/performance-handover.md`. Its
prediction is built from its own copy of the bucketing rule. If `eliminate`'s
bucketing changes and `derivesContradiction`'s does not, a contradiction goes
undetected and an unsatisfiable system returns as a bounded one. **A
correctness gate that reimplements the rule it gates is itself a defect**, and
it is the only item on either list where a future edit's damage is invisible to
the thing built to detect damage.

**What it prevents.** A silent soundness regression in the solver, enabled by
any future edit to one of five copies.

**Acceptance.** `predictedRows` calls the one public bucketing function and
contains **no float comparison of its own** — decidable by grep: zero
occurrences of `.hi < 0` or `.lo > 0` in `bench/bench_lp.zig`. Second, the
semantics question is settled by a test, not by the merge: a named test pins
what the shared rule answers for a NaN endpoint, because `Interval.signOf`
says `.negative` and lp's private `signOf` says `.straddle`, and the two answer
different questions (section 1 records the difference and why it is
deliberate). Whichever is chosen, it is chosen once and written down. The third
part is that lp stops importing its own copy: `grep -n 'fn signOf' src/lp.zig`
must return nothing after the cutover.

### A4 — DONE: `root.zig` enumerates its two namespaces by name

`ext` was `pub const ext = ext_mod;` and `lp` was `pub const lp = lp_mod;`.
Those two declarations made **23 non-`pub` free functions** (11 in
`src/interval_ext.zig`, 12 in `src/lp.zig`) and **7 private methods on
`System`** reachable from outside the package, each held back by the `fn`
keyword and nothing else. One over-broad `pub` grew the public API with no
error, no test failure, and no diff that looked like a decision.

**What it bought.** Both are now structs of named members (`src/root.zig:135`
and `:173`), so a name has to be written down to be reachable, and the comment
on each says why. The twenty private declarations in `interval_ext.zig` and the
seven private free functions plus five private types in `lp.zig` are no longer
published. `tests/interval_test.zig` carries the guard that makes it stay that
way: `ext and lp publish exactly the enumerated names` walks
`@typeInfo(...).@"struct".decls` and fails on a member that is not in the
written-down list, so a stray `pub` is a failing test rather than a hole.

**The cost, and it was worth paying deliberately.** The list is written twice —
once in the namespace and once at the top level, because `sin(x)` and
`ext.sin(x)` are promised to be the same call — so a new elementary function
costs a line in each. That is a maintenance price chosen over a silent one, and
the test above is what keeps the two lists honest.

### A5 — DONE: `noteContradiction` stops rescanning every row

**Done.** `pushRow` now calls `checkRowForContradiction(rowCount() - 1)` — the
row it just appended and nothing else. The full scan survives as
`rescanForContradiction` and is called from exactly one place, `eliminate`,
where the row set has genuinely changed underneath it.

**Why one row is enough.** `unsat` is latched: once true nothing clears it and
every caller acting on it returns early. So the only row that can be NEWLY
all-zero with a negative right-hand side is the one just appended — every
earlier row was checked when it was appended, and neither `add` nor `pushRow`
modifies a row in place. `eliminate` is the one path that replaces rows
wholesale, and it is the one that still pays the full scan.

**What it removes.** `add` was `O(N^2 * var_count)` in the number of
constraints; it is now linear in the rows appended, each costing one row's
worth of coefficient scan. The LP benchmark's row budget is what made that a
wall rather than a theoretical concern.

**The acceptance's mutation, run.** Making the predicate never fire — flipping
`row.rhs.hi < 0` to a comparison that cannot be true — turns three lp tests
red, among them "unsatisfiable by contradiction, reported through isUnsat" and
"a contradiction only the last round can see is still reported". That is what
shows the check is load-bearing rather than decorative.

**No timing is claimed, and none is needed.** This host's noise floor is +33% to
+44% between two runs of the same binary, and `add` is a cheap operation, so a
delta here would not be evidence. The acceptance is decidable structurally —
the loop body's index expression is a single constant on the `pushRow` path,
and the full scan exists only on the `eliminate` path — and that is what was
verified.

**What it was.**

`src/lp.zig:744-751`, called from `pushRow` at `:683` on every appended row and
from `eliminate` at `:317`. The loop scans ALL rows, so `add` is
`O(N² · var_count)` in the number of constraints. `unsat` is already latched,
so the only row that can be **newly** all-zero is the one just appended. The
other N-1 rows were checked when they were appended and nothing since can have
changed them.

**What it prevents.** Not a defect — a quadratic. It is ranked here because it is
the same file and the same class of "the invariant is already known and is being
re-derived", and because the LP benchmark's row budget means quadratic behaviour
in `add` is a real wall, not a theoretical one.

**Acceptance.** The check inside `pushRow` examines the row just appended and no
other. Decidable structurally: the loop body's index expression is a single
constant, and the full `noteContradiction` scan exists only on the `eliminate`
path where the row set has genuinely changed. Second, mutation: flipping the
single-row predicate must make the lp suite report an unsatisfiable system as
satisfiable — that is the test that proves the check is load-bearing.

### A6 — DONE: `System.count()` is renamed `rowCount()`

**Done.** `System.count` is `System.rowCount`, and no `count` survives on the
lp surface — the rename ran across `src/lp.zig`, `tests/lp_test.zig` (35 call
sites), `bench/bench_lp.zig` (20), the README's API table and both worked
examples, and the fixture.

**The distinction is pinned, not merely renamed away.** The acceptance's named
test is the normalisation test at the top of `lp_test.zig`: three constraints,
one of them an `eq`, answer `rowCount() == 4`. That row now says in its comment
that the gap between three constraints and four rows is the whole reason for
the name, so a reader who later "simplifies" it back to `count` has to read
past the reason to do it.

**One thing this rename did NOT touch, deliberately.** `fixture/src/readme.zig`
has its own `fn count(self: *Counting) std.mem.Allocator` — a counting
allocator in the fixture's leak checks, unrelated to `System.count`. It keeps
its name; the grep in the acceptance is about the lp surface.

**What it was.**

`src/lp.zig:167-169`. It returns `self.rhs.items.len`, which is stored **ROWS**,
not constraints. An `eq` is stored as two rows (`:204-209`), so a caller asking
"how big is this system?" gets 4 for 3 constraints, and the error is a factor of
two per equality. The name is what a caller trusts when they report a system's
size. A `gt` or `lt` is relaxed, not duplicated, so the inflation is specifically
from equalities — a caller cannot even predict the factor from the input count.

**Acceptance.** The method is named `rowCount` and no `count` remains; the
rename compiles across the tree. Second, a named test asserts
`rowCount() == 4` for three constraints of which exactly one is `.eq`, so the
distinction is pinned rather than merely renamed away.

### A7 — DONE: `System.init` returns an error union instead of panicking

**Done.** `init` is `!System`, the allocation is `try`n with an `errdefer` that
frees the flags if anything after it fails, and every caller in the tree uses
`try`: the README's two worked examples, the fixture, `clone`, the three
benchmark builders, and 35 sites in `tests/lp_test.zig`.

**What it bought.** A caller in a program that wanted to *handle* exhaustion
rather than die can now ask for that. Before this, `init` was the one allocator
call in the file that could not fail visibly, and the panic made the decision
for the caller.

**The probe is a permanent test, not a throwaway.** The acceptance named a probe
built against a failing allocator; `tests/lp_test.zig` now carries it, because
`std.testing.FailingAllocator` makes it a two-line test rather than a program.
It sets `fail_index = 0` and asserts `error.OutOfMemory`, and then — the half
that matters — builds the same allocator with nothing failing and checks the
system it returns actually works. A probe that only proved the failure would
pass against an `init` that could never succeed at all.

**Acceptance. MET.**

**What it was.**

`src/lp.zig:139-141` is the only allocator call in the file that cannot report
failure; every other one propagates. It panics with a message, which means a
caller in a program that wanted to handle exhaustion cannot.

**Acceptance.** `lp.System.init` returns `!System`. The README worked example
(`README.md:926`) and the fixture both use `try`. A probe built against a
failing allocator **must return `error.OutOfMemory` rather than panic** — that
is the observable end state, and it is decidable with
`std.testing.FailingAllocator`.

### A8 — DONE: one public elimination driver, not three

**Done.** `eliminateAll` is deleted and `eliminateInOrderOfChoice` is the one
driver. `eliminationOrder` stays, because a full permutation is a different
contract (section 5), not a second driver.

**The wrapper was an artefact of the naming collision A6 removed**, exactly as
this item predicted: `eliminateAll` took an out-parameter called `count_out`
only because a parameter named `count` shadowed the `count` method, which Zig
rejects. With that renamed there was nothing left for it to do but call the
other one.

**The one behaviour worth recording, because it could have been lost in the
cutover.** `eliminateAll` did exactly one thing the survivor did not: it
answered `false` for a system that was ALREADY unsatisfiable before the call,
without touching a row. `chooseNext` does not look at `unsat`, so a naive
deletion would have let the sweep run on past a proof it already had,
eliminate whatever variables were still alive, and then report `true`. That
check is now the first line of `eliminateInOrderOfChoice`, so the behaviour is
preserved and the survivor is correct on its own rather than by delegation.
`tests/lp_test.zig` exercises both shapes — a system that goes unsat during the
sweep, and one that was already unsat before it — and the second is the case
the wrapper existed for.

**The probe.** `probe/eliminate_all.zig` fails to compile with `no field or
member function named 'eliminateAll' in 'lp.System'`, as the acceptance asked.
The call sites converted were ten in `tests/lp_test.zig`, four in
`bench/bench_lp.zig`, one in the fixture, and the README's API table and worked
example.

**What was deliberately NOT renamed.** The benchmark's row LABELS still read
`eliminateAll chosen, mixed` and so on. Those strings identify rows in the
recorded table in `docs/performance-handover.md`, and changing them would
silently break the correspondence between that record and a re-run. Comments in
that file that named the removed API were corrected; the labels were not.

**What it was.**

`src/lp.zig:335` (`eliminationOrder`), `:351` (`eliminateInOrderOfChoice`) and
`:368` (`eliminateAll`). All three run the same greedy loop; the file says at
`:366-367` that the third exists **only** because a parameter named `count`
shadows the `count` method. One of them is an artifact of a naming collision, and
the other two are the same loop with different return conventions.

**Acceptance.** `eliminateAll` is deleted and `eliminateInOrderOfChoice` is the
one driver; a compile probe naming `eliminateAll` **must stop compiling**. (The
rename in A6 removes the shadowing that motivated it, so A8 depends on A6
landing first — sequence them that way.) `eliminationOrder` stays, because a full
permutation is a different contract (section 5).

### A9 — DONE: `Interval.halve` is public, with the property its doc claims pinned

**Done, and the test is the part that matters.** `halve` is `pub`, and
`tests/interval_test.zig` sweeps eighteen shapes — subnormal endpoints, both
signed zeros, both infinities and the ends of the range — asserting that
`x.halve()` is a SUBSET of `x.div(Interval.init(2.0, 2.0))` on every one. The
probe the acceptance asked for is the same test: the call compiles because the
test calls it.

**Why the property holds, and why the sweep is not a tautology.** The two
compute the same real by different routes. `div` pays its underflow repair on
every endpoint, because it cannot know which corner lost its magnitude;
`halve` pays it only where its own endpoint actually did. So on a box whose
OTHER end is a lost magnitude, `div` steps further out than the truth needs and
`halve` does not, and that difference is exactly what the subset relation names.
The sweep fails if either side stops paying its own repair, which is what makes
it a test rather than a restatement of the doc comment above it.

**What it did not cost.** `min_subnormal` is not re-exported at the package
root, and the test spells the constant out rather than widening the public
surface for its own convenience.

**What it was.**

`src/interval.zig:344-351`. A rigorous halving exists, is documented as
*never wider than `div` by two*, and cannot be called by a consumer who would
benefit from exactly that. It is private for want of a caller.

**Acceptance.** A probe `Interval.init(1.0, 2.0).halve()` compiles. Second, a
named test asserts the property its own doc comment claims at `:336-343`: for
every case in a sweep, `halve` is a subset of `div` by `Interval.init(2.0, 2.0)`.
That test is the point; the visibility change alone buys nothing.

### A10 — Extract the exact-arithmetic block of `lp.zig`

`src/lp.zig` is 1002 lines holding a roughly 240-line exact-arithmetic block —
`combinedColumn` (`:817`), `cancelsExactly` (`:916`), `doubleProduct` (`:937`),
`exactProduct` (`:956`), `combinedBound` (`:975`), `isExactZero` (`:982`),
`isPoint` (`:993`) — interleaved with allocator code. This block holds the
hardest proof in the tree: `f128` cancellation decided on the operands rather
than on the widened products, which is **D4** in `docs/next-work-plan.md`, the
document that owns the defect record. The block is **pure**: it takes a `Part`
and returns a value, with no allocator anywhere in it.

Being pure is what makes it extractable and testable in isolation, and neither is
available while it sits inside a file whose other half is memory management.

**Acceptance.** The block lives in a module that names no allocator type, and a
compile probe that reaches for `Part` or `combinedColumn` from outside **must
stop compiling**. Second, the block's own tests run without constructing a
`System` at all — that is the observable proof that it is pure.

**Ranked last deliberately.** It is the largest diff of the ten and the one with
the least defect risk behind it. The renames of section 5 should ride along with
it, not land alone.

### A11 — DONE: the guard in `boundDivisor` is an endpoint test, and its doc now says so

**Resolution 1. The doc was wrong and has been corrected down to "neither
endpoint is zero"; the guard is right and did not move.** No code changed, so
no solver answer changed and `src/lp.zig` is untouched. The two readings of
the guard that came apart on a straddling piece are now separated by an
argument rather than by a preference, and the argument refutes the tighter
one.

**The finding: the far endpoint is chosen by MAGNITUDE, and the two reads of
one row want OPPOSITE ends of the coefficient.** That is what this entry was
missing, and it is stronger than the worry the entry opened with. Reading a
LOWER bound off `a * x_k <= rhs` takes the largest `rhs / a` over the piece,
and where that is finite it is attained at the negative end; reading an UPPER
bound takes the smallest, and where that is finite it is attained at the
positive end. So the lower arm wants `a.lo` and the upper arm wants `a.hi`,
while `boundDivisor` can return only one divisor. On a one-sided piece that
costs nothing, because the endpoint that is not zero is the only end either
arm can want. On a piece with both signs the single divisor does not exist,
and **whichever read the magnitude rule does not favour is bound by an
endpoint that is not its extremum, so it comes out TIGHTER than the truth.**
A bound too tight is not a bound, and this library would rather report none.
Two counterexamples, both pinned in
`tests/lp_exact_test.zig` as arithmetic rather than as prose:

- `a = [-1, 5]`, `rhs = [1, 2]`. Magnitude picks `5`, so the lower arm claims
  `x_k >= rhs.lo / 5 = 0.2`. But `x_k = -0.5` satisfies the row for EVERY
  realisation of `a`, because `a * x_k` is largest at `a = -1`, is `0.5`, and
  the smallest `rhs` is `1`. The bound excludes a value the row permits.
- `a = [-1, 1]`, the shape this entry named. Magnitude is a tie and the
  comparison prefers `lo`, so the collapse yields `-1` and the upper arm
  claims `x_k <= -1`. `x_k = 0.5` is admitted by every realisation, the same
  argument at `a = 1`, and again the bound excludes what the row permits.

So on EVERY straddling piece exactly one of the two reads is too tight. That
is the durable result: the collapse does not fail because the piece reaches
zero, it fails because it reaches **both** signs and one divisor cannot serve
both reads. And it is not a realisation NEAR zero that escapes the collapsed
bound, which is the form this question was originally put in — that term is
real, and it is what makes the whole line the right answer for a piece with
zero in its interior. What escapes the COLLAPSE is the whole other end of the
piece: the endpoint on the far side of zero from the one the magnitude rule
chose, which the collapse never divided by and never bounded by.

**What the whole-line answer costs, stated rather than glossed.** Handing a
straddling piece back whole is sound and it is LOOSE. With `rhs.lo >= 0` the
set of `x_k` satisfying `a * x_k <= rhs` under every realisation is the
interior interval `[rhs.lo / a.lo, rhs.lo / a.hi]`, so a real bound exists on
both sides and the code declines to take either. Earning it takes one divisor
per SIDE rather than one per row — a change of interface, not of guard — and
it would change no answer today: `partitionInto` (`src/lp.zig:583-601`)
splits every straddling piece into `[a.lo, 0]` and `[0, a.hi]` before
`BoundReader` sees one, so the shape is unreachable from `bounds` and `box`.
Recorded here; not taken.

**Why the endpoint test is not a weaker version of the containment test.** On
every piece the solver builds the two are the same question, which is why the
guard was never wrong in use and only under-described. `partitionInto` files a
straddling coefficient as `[a.lo, 0]` in the lower bucket and `[0, a.hi]` in
the upper, and `BoundReader` (`src/lp.zig:360-370`) calls `boundDivisor` only
for a piece whose `lo` is below zero or whose `hi` is above zero, so every
piece that reaches the guard is one-sided outright, or one-sided and touching
zero at one endpoint. The magnitude comparison is a tie on `[0, 0]` alone,
where both candidates are zero and nothing observable turns on it.

**The tree already drew the line the guard does not.** Kept because it is how
the two got confused: `Interval.div` branches on containment,
`other.lo <= 0.0 and 0.0 <= other.hi` (`src/interval.zig:894`), and the
soundness reference calls its two cases by name — a divisor that REACHES zero
from one side, whose true quotient set is one ray with a finite end, and a
divisor with zero in its INTERIOR, whose hull is the whole line
(`tests/soundness_shared.zig:1372-1383`). Those are answers about the QUOTIENT
SET, which is what `div` is for. `BoundReader` asks a different question —
which end of the piece binds `x_k` — and the guard encodes the answer to that
one. The whole line `div` returns for an interior zero is a correct answer to
the question `div` is asked; `BoundReader` reads `-inf` and `+inf` off it and
keeps the bound it already had, and contributing nothing is sound.

**The test.** `tests/lp_exact_test.zig` keeps its name — the contract that name
states is the one the code implements — and its straddling expectation is now
the settled answer rather than a known disagreement. It pins the symmetric and
the asymmetric straddle, both of which come back whole, and it pins the
refutation above with `mul`, `div` and `contains`, so a change to the guard
that reintroduces the collapse fails on the numbers rather than on a
reviewer's reading of a comment. The draft of that test which asserted the
containment reading, and failed with "expected `pt(-1.0)`, got `[-1, 1]`",
was wrong; the failure was the question, and this entry is its answer.

**Acceptance. MET.** The doc comment above `boundDivisor` is corrected down to
"neither endpoint is zero" and the test stands. The guard is deliberately not
`lo > 0 or hi < 0`, because that version is refuted above rather than merely
unproved. Nothing was deleted or weakened: the straddling expectations the old
draft got wrong are the expectations now.

**What it was.**

`boundDivisor` (`src/lp_exact.zig:334-341`) hands the multiplier piece back
whole when `coeff.lo != 0 and coeff.hi != 0`, and otherwise hands back the
endpoint of larger magnitude as a point. The first test is about **endpoints**:
neither of them is zero. It is not a test about the piece **containing** zero,
which is `lo <= 0 <= hi` and is the question `Interval.signOf` branches on
(`src/interval.zig:799-804`). The two come apart on exactly one shape — a piece
that straddles zero and has no zero endpoint, `[-1, 1]`.

The comment above it said the divisor is "the multiplier piece itself where
that piece does not reach zero, and its endpoint farthest from zero as a point
where it does", and the next paragraph argued from the one-sided reading
`eliminate` performs: a piece that touches zero still has a sign, so it
multiplies by the piece whole. Both "reaches zero" and "touches zero" read as
containment in that text, and on that reading the sentence described a guard
the code does not have.

**How it was found.** By `tests/lp_exact_test.zig`, which is A10's test and
pins the extracted block without building a `System`, and not by an audit. The
body is **pre-existing**: `HEAD:src/lp.zig:1278-1285` carries the identical
guard, so the extraction moved it verbatim and did not introduce it.

---

## 5. What is deliberately not being done, and why

Each of these is a refusal with a reason, recorded so a later session does not
re-litigate it. The longer treatment of the first three is section 5 of
`docs/next-work-plan.md`; they are restated here because this file touches the
same lines.

**The straddling duplication in `eliminate` stays.** The `.straddle` arm of the
bucketing switch in `src/lp.zig` pushes a coefficient interval that straddles
zero into **both** sign buckets. It is not waste and not a missed optimisation —
dropping it would discard a real constraint and cut the feasible set, which is
the one thing this library must never do. The module header states the
guarantee, and the duplication IS the guarantee. The cost is row explosion,
documented and measured (`docs/performance-handover.md`), and the mitigation is
the 20,000-row budget in the benchmark harness, not a change to the solver. Note
that A3 must not be confused with this: consolidating the *rule* that buckets a
coefficient is not consolidating the *bucketing*, and the straddle arm must keep
putting a coefficient in two lists. The `f128` cancellation fix is compatible for
the same reason: it removes coefficients that are **exactly** zero, which is a
different thing from a coefficient whose interval **contains** zero.

**Stopping after `n - 1` variables stays out.** A textbook Fourier-Motzkin loop
stops with one variable live, because the last round produces only the
contradiction test. Here `eliminationOrder` (`src/lp.zig:335`) is contractually a
full permutation and the final row count is pinned by tests, so removing the
round changes observable behaviour and makes it a different function. The
finding is recorded in `docs/performance-handover.md` and in section 5 of
`docs/next-work-plan.md`, and the tests are the reason it is closed.

**`powf`'s composition stays.** `powerCorner` (`src/interval_ext.zig:351`)
evaluates `x^y` as `exp(y · log x)` through this library's own rigorous `log`,
`mul` and `exp`, and the argument for it is in the doc comment above it: three
elementary evaluations where there used to be one is the right trade for a
library whose only claim is that a result can be trusted. The measured price was
accepted knowingly. It is also the right dependency for the corpus reference
`powf` is checked against, which has to decide the composition without asking
the library's own `log`, `mul` and `exp` whether they are right.

**The 0.0.0-package renames do not land alone.** `ext` to `elementary` and
`mapResult` to `mapBox` are readability, and readability is not worth a diff
that touches every caller and no test. A4 is done and did not take them: it
rewrote the `ext` surface without renaming it, because renaming a namespace and
changing what it publishes are two changes with two different failure modes, and
only one of them has a test. They ride along with A10, whose module boundary is
what would make `ext` a better name in the first place.

**Also not being done, referenced rather than restated:** the `log2` / `log10`
subnormal claim stays withdrawn (it was checked and not reproduced — the apparent
misses were an `f64`-computed reference, which is the trap of section 2 again);
the `0 * inf` guard in `mul` stays and is not redundant; the two overflow guards
in the oracle are guards, not obsolete reproducers, and must not be deleted;
`bench-lp` sizes must not be restored to the values that used to hang.

---

## 6. The measurement constraint on this host, for whoever measures anything

**This host is shared, and other users run training jobs on it.** The snapshot
taken while this file was written: **72 cores**, **7 logged-in users**, load
average **28.51 / 67.98 / 103.01** over 1 / 5 / 15 minutes, **1007 GB** total
RAM with **354 GB** in use. Those numbers will have moved; the property they
record will not. A measurement taken here measures a contended machine unless
the contention is controlled.

**Delegated measurement must be ONE process and ONE verification mode.** Both
rules are about concurrency, not about accuracy of effort:

- **One process.** `zig build bench` depends on all three benchmark run steps
  (`build.zig:265-271`), so it runs three benchmark executables at once. Add a
  delegated agent compiling or benchmarking and you have six-plus compilers and
  benchmark loops against a host that already averages dozens of runnable tasks.
  The measured cost is not a wash: the noise floor in
  `docs/performance-handover.md` is **+33.6 %** on `add`, **+36.5 %** on
  `expand` and **+43.9 %** on `mul` between two runs of the SAME BINARY with
  other benchmarks running. A benchmark run under that contention is a report
  on the contention.
- **One verification mode.** `zig build test` in four modes is four full
  compilations, each ending in a nested `zig build run` for the fixture
  (`build.zig:159-172`, ~43 s each). Run all four concurrently and the wall
  clock is the slowest plus the noise of the others. They also answer different
  questions: Debug is where the `lo <= hi` assertions and the NaN probe live,
  ReleaseFast elides them. Pick the mode the question is about.

The same rule applies to an agent that only needs to COMPILE something to check
it: one process, one mode, small case counts, and private `--cache-dir` /
`--global-cache-dir` directories so two agents never contend for the same
cache. The gates themselves belong to whoever is orchestrating, once, over the
union of the work.

**Cite existing measurements; do not re-derive them.** Every LP figure,
baseline, optimisation delta and noise band is already in
`docs/performance-handover.md` with the date, the mode and how it was taken.
Re-running a benchmark to "confirm" a number in that file costs a contended
host, produces a number that differs for reasons that have nothing to do with
the code, and then invites a later session to treat the discrepancy as a
regression. **If a change has no measurement attached, it has no claim attached
either** — that file's convention is to record such a row as **NO CLAIM** rather
than as a small win, and it is the right one.

**The consequences, stated once.** A change to any operation under about
10 ns/op **cannot** be claimed from a single pair of runs here: take the
measurement on an otherwise idle machine, or take three runs and compare minima,
as the noise-floor section of `docs/performance-handover.md` says. The cheap
rows are where optimisation is most tempting and where the evidence is weakest.
And **never run an LP benchmark without a row budget** — 329 GB was observed in
one `zig build bench` on this host, which has 1 TB and other users on it. A
larger system does not fail; it takes the machine with it.

**What this means for the work in this file.** Sections 2 through 5 are
correctness and structure work. None of it needs a benchmark, and **none of it
should be justified by one**. A1 through A10 are compiler-enforced changes whose
acceptance criteria are compile errors and assertion outcomes; T1 through T10 are
oracle and coverage work whose criteria are `FAILED` counts and failing
mutations. That is deliberate. The next person to reach for a timing number to
justify one of these items should re-read this section first.
