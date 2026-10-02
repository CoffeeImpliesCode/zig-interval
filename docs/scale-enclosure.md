# O1 — an enclosure argument for a one-step fused `scale`

**Verdict: the proof does not close. `scale` is unchanged.**

Item **O1** in `docs/next-work-plan.md` §4 asks for the prerequisite rather than
for the optimisation. A direct formulation of `scale` would need one outward
step per endpoint instead of the six it spends today, and the plan's verdict on
that is *NO, not without a proof*, for the reason `scale`'s own doc comment
gives at `src/interval.zig:466-467`:

> a bound has to bound the whole chain, and the error of a chain is not the
> error of its last step

This document is the proof that was asked for. It is a proof that the fused
form **cannot** be made sound by any fixed number of outward steps, and it
carries a two-parameter family of exact `f64` inputs on which the one-step
form returns a bound that excludes the true image. That converts *nobody has
checked* into *checked, and here is where it fails*, which is what §4 asks for
when it says the item is blocked on an argument rather than on work.

The prize is real and is not being given up: a sound fusion of the six
roundings into one would be cheaper than the six outward steps the composition
spends, and the size of the prize is measured — `interval.scale` is **47.795
ns/op** against **80.551** at the start of round 2, a **−41 %** move, still
3.1× `div`, 5.0× `mul` and 9.5× `add` (see the benchmark captures this
repository keeps). §8 below says what a *sound* fusion would have to cost, and
why it is not the same thing as the one-step form.

---

## 1. What is being fused

The contract is already written down in `src/interval.zig:463-467` and, in the
five-term form the soundness oracle judges by, in the doc comment above
`ScaleBound` (`tests/soundness_shared.zig:822-823`). For a bounded box
`[A, B]` and `G = |factor|` the true image is

```
L = (A + B + G*A - G*B) / 2 = M - W
H = (A + B - G*A + G*B) / 2 = M + W
    with   M = (A + B) / 2      and      W = (B - A) * G / 2
```

taken as reals. Neither `M` nor `W` is an `f64` in general and neither is `L`
or `H`, which is why §2.2 of `docs/tests-and-architecture-plan.md:286-295` exists:
the division by two makes each extremum a sixth term that no rounded `f128`
supplies, so the oracle holds the five terms as an expansion and compares
signs. Everything below is judged against exactly that reference.

**The fused form** is the most generous direct reading of the contract: form
the two intermediates once, combine them once, and widen the answer once.

```
g = |factor|
m = fl(fl(lo + hi) / 2)                // roundings 1 and 2
d = fl(hi - lo)                        // rounding 3
w = fl(d * g / 2)                      // roundings 4 and 5
lo' = roundDown(fl(m - w))              // rounding 6
hi' = roundUp(fl(m + w))               // the same six, on the other arm
```

Six roundings and **one** outward step per endpoint, against the six outward
steps per endpoint the present composition spends. That is the whole of the
proposal, and it is stated this way on purpose: it keeps the midpoint /
half-width structure `scale`'s doc comment insists on (§`src/interval.zig:491-498`),
puts both terms of each arm on the protective side, and gives the fused form
the best rounding any `f64` implementation can have. Anything that fails below
fails for a reason the structure does not repair.

Three of those six roundings are *exactly* exact and cost nothing: the two
divisions by two, because halving a normal is exact
(`src/interval.zig:432-433`), and `fl(m - w)`, which is exact by **Sterbenz**
whenever `w/2 <= m <= 2w` — which is precisely the regime the failure lives
in. That leaves **three** roundings carrying error in the worst case: the
sum, the difference and the product.

The shorter algebra `lo + (hi - lo)(1 - g)/2` is not considered again here. Its
doc comment at `src/interval.zig:500-519` already rejects it, with two
measurements attached, for the independent reason that each of its arms is
protective in one direction only.

---

## 2. What one outward step actually buys

This is the part that decides everything else, so it is stated as a lemma and
proved.

**Lemma.** Let `E` be the exact real value of the fused chain's final
expression and let `e = fl(E)` be what the machine produced, finite and
normal. Then `roundDown(e)` is at or below `L = M - W` **if and only if**

```
delta := E - L   <=   u / 2 ,        u = ulp(e)
```

*Proof.* `roundDown(e) = prevDown(e) = e - u`. The requirement is
`e - u <= L`, i.e. `e <= L + u`. Since `e` is the nearest `f64` to `E`,
`e >= E - u/2`, so the requirement can fail only if `E - u/2 > L + u`, i.e.
`delta > 3u/2`; and it can fail for real only when `e` lands on the `+u/2`
side, which happens whenever `E` sits just above a midpoint. In that case
`e = E + u/2` and `e - u = E - u/2`, so the requirement is exactly
`delta <= u/2`. For `delta <= u/2` the worst case gives `e - u = E + u/2 - u
<= E - u/2 <= L`. ∎

Two things follow, and they are the whole of this document.

1. **The budget for a one-step fused form is half a ULP of the value the form
   produced** — that is, of `L`, the endpoint, *not* of the intermediates.
2. With **N** steps instead of one, the budget becomes `(N - 1/2) ulp(L)`
   rather than half a ULP. No fixed `N` repairs what follows.

---

## 3. The chain error, rounding by rounding

Take the lower arm; the upper arm is the mirror image and §5 exhibits it.
Substituting the six roundings of §1:

```
delta = (m - M) - (w - W) + (fl(m - w) - (m - w))
        \_epsilon_m_/   \_epsilon_w_/   \_ epsilon_f _/
```

`epsilon_f` is the final rounding, and `|epsilon_f| <= u/2` by construction,
so it spends the whole of §2's budget on its own and leaves nothing for the
other two. Each remaining rounding is bounded by half an ULP **of the value it
computes**, and every one of those values sits on the scale of the operands
rather than of the answer:

| # | rounding | own bound | exact? |
| - | -------- | --------- | ------ |
| 1 | `fl(lo + hi)` | `<= ulp(M) / 2`, once the exact halving has moved it onto `M` | no |
| 2 | `fl(s / 2)` | `0` | **yes**, normal range (`src/interval.zig:432-433`) |
| 3 | `fl(hi - lo)` | its error is scaled by `G` on the way into `w`, so `<= ulp(W)` for `G` within a factor of two of 1 | no |
| 4 | `fl(d * g)` | `<= ulp(W) / 2` | no |
| 5 | `fl(p / 2)` | `0` | **yes**, normal range |
| 6 | `fl(m - w)` | `0` under Sterbenz, which is exactly what the cancellation regime produces; `<= ulp(L) / 2` otherwise | see below |

The constants are not the point and are deliberately loose; the **scales** are.
The chain therefore delivers, in the worst case, an error on the scale of

```
    ulp(M) / 2  +  ulp(W)          against a budget of      ulp(L) / 2
```

**The fused form is sound only when `L` sits in the same binade as `M` and
`W`.** The moment `|L| << |M|` — which is not an exotic corner, it is what the
map *is* — the two terms on the left are separated from the budget on the
right by the factor `ulp(M) / ulp(L)`, and the returned value is not a bound
at all.

### 3.1 The cancellation is forced, not accidental

The lower extremum is

```
L = (A(1 + G) + B(1 - G)) / 2
```

For `G` anywhere near 1, `(1 - G)` is near zero, so `L` is essentially
`A` — **unless `A` and `B` have opposite signs**, in which case the two terms
face each other and can cancel to nearly nothing:

```
A = -1,  B = 2^k,  G = 1 - 2^-53

L = ( -1 * (2 - 2^-53) + 2^k * 2^-53 ) / 2
  = -1 + 2^(k-54) + 2^-54                      <-  magnitude about 1
M = (2^k - 1)/2          ~ 2^(k-1)             <-  ulp(M) = 2^(k-54)
W = (2^k + 1)(1 - 2^-53)/2 ~ 2^(k-1)            <-  ulp(W) = 2^(k-53)
```

`|M| / |L|` is about `2^(k-1)` and is **unbounded**. The budget is
`ulp(L)/2 = 2^-54`. The smallest error any rounding can contribute is half an
ULP of the operand it touches, which here is `ulp(M)/2 = 2^(k-55)` — already
`ulp(M) / ulp(L) = 2^(k-1)` times the budget, `2^39` at `k = 40`, with no
ceiling.

This is not a far corner of the format. `[-1, 2^10]` is an ordinary box.

---

## 4. The counterexample, exactly

`scale([-1, 2^40], 1 - 2^-53)` — one factor, one box, every quantity exact.

```
g = 0x1.fffffffffffffp-1  =  1 - 2^-53  =  nextafter(1, 0)

M = (lo + hi) / 2         = 549755813887.5
W = (hi - lo) * g / 2     = 549755813888.49993896484375

L = M - W = -18013298997854207 / 18014398509481984
          = -0.99993896484375            = -0x1.fff8000000000p-1
H = M + W =  19807040628566083298874359807 / 18014398509481984
          =  1099511627775.9999          =  0x1.fffffffffffffp+39
```

The chain, each rounding charged to the row it enters:

```
fl(hi - lo)          = 1099511627777.0        err =  0                (exact: 2^40 + 1 < 2^53)
fl(d * g)            = 1099511627776.9998     err = -(2^(k-53) - 2^-53)  -0.5 ULP of its own value
fl(p / 2)            = 549755813888.4999      err = -(2^(k-54) - 2^-54)  exact halving, inherits the product's error
fl(fl(lo + hi) / 2)  = 549755813887.5         err =  0                (exact sum, exact halving)
fl(m - w)            = -0.9998779296875       err = +(2^(k-54) - 2^-54)  EXACT by Sterbenz; m and w within a factor 2
```

Exactly **one** rounding is wrong: the product `fl(d*g)`, by half an ULP of a
value near `2^39`, which is `2^(k-53) - 2^-53` in absolute terms. Halved by
the exact division, it reaches the endpoint as `2^(k-54) - 2^-54`, which is
**one whole ULP of the midpoint**. The budget of §2 is half an ULP of `L`,
`5.55e-17`, so the chain is already `2^k - 1` times it at `k = 40` and there
is no ceiling on that as `k` grows.

The single outward step then does this:

```
roundDown(fl(m - w)) = -0.9998779296875001     = -0x1.fff0000000001p-1
true L              = -0.99993896484375        = -0x1.fff8000000000p-1

chain error            = +6.103515625e-05      = 2^(k-54) - 2^-54
one outward step       = -1.1102230246251565e-16 = -ulp(L)
cut                    = +6.103515624994449e-05 = 2^39 - 3/2 ULP of the bound
budget for the step    =  1.1102230246251565e-16 = half an ULP of the bound
```

**The returned lower bound is above the true lower endpoint of the image.**
The true image contains `-0.99993896484375`; the fused form returns an
interval whose lower end is `-0.9998779296875001`, which does not. A caller
asking whether that interval contains a point of the image is told *no*, for a
point that is in it.

The same family, over five decades of `k`. `G` is held at `1 - 2^-53` and only
the box moves:

| `k` | true `L` | fused `lo` | cut (ULP of the bound) | current form |
| -: | -------- | ---------- | ---------------------- | ------------ |
| 10 | `-0.99999999999994316` | `-0.99999999999988642` | `510.5` | sound |
| 20 | `-0.99999999994179234` | `-0.99999999988358479` | `524286.5` | sound |
| 30 | `-0.99999994039535522` | `-0.99999988079071056` | `536870910.5` | sound |
| 40 | `-0.99993896484375` | `-0.99987792968750011` | `549755813886.5` | sound |
| 50 | `-0.9375` | `-0.87500000000000011` | `562949953421310.5` | sound |

The cut is `2^(k-1) - 3/2` ULP on every row, exactly, and it is unbounded.
The present form is sound on every one. Beyond `k = 52` the box's own
difference `2^k + 1` stops being representable and rounding 1 joins the
chain, so the closed form ends there — the failure does not.

---

## 5. The upper arm fails by the same argument

`H = (A(1 - G) + B(1 + G)) / 2`, so the mirror box `[-2^k, 1]` cancels the
other way and the fault lands on the upper endpoint:

| `k` | true `H` | fused `hi` | shortfall (ULP of the bound) | current form |
| -: | -------- | ---------- | -------------------------- | ------------ |
| 10 | `0.99999999999994316` | `0.99999999999988642` | `510.5` | sound |
| 20 | `0.99999999994179234` | `0.99999999988358479` | `524286.5` | sound |
| 30 | `0.99999994039535522` | `0.99999988079071056` | `536870910.5` | sound |
| 40 | `0.99993896484375` | `0.99987792968750011` | `549755813886.5` | sound |
| 50 | `0.9375` | `0.87500000000000011` | `562949953421310.5` | sound |

`roundUp` is the mirror of `roundDown` and the argument is the same one with
every sign flipped, so this is a single defect observed twice rather than two
defects. A form that failed on one arm only would have been a lucky accident
of the sign table; it fails on both, which is what §3 predicts.

---

## 6. The check against reality

The argument above predicts a specific thing: the one-step form should fail
whenever the true endpoint is a binade or more below its own intermediates,
and it should fail *often*, because that regime is where the map puts the
answer. Three independent sweeps, all judged against the five-term
`Fraction`-exact reference of `ScaleBound`
(`tests/soundness_shared.zig:862-920`), all in IEEE binary64:

| corpus | cases | present `scale` | fused, 1 step | fused, **exact** `M` and `W` | algebraic, 1 step |
| ------ | ----- | --------------- | ------------- | --------------------------- | ------------------ |
| structured magnitudes x factors | 2,511,054 | **0** | 669,286 | 588 | 1,970 |
| randomised, seed 20261001 | 200,000 | **0** | 28,458 | 871 | 1,958 |
| randomised, normal-magnitude endpoints only | 200,000 | **0** | 27,882 | — | — |

Four things to read out of that table.

**The present form is sound on all 2.9 million cases.** That is the
self-check on the harness: a model of `scale` that were even slightly wrong
would show unsoundness here, and it shows none. Tracing the rounding steps
on the finite path of `scale([-1, 3], 2)` gives fourteen `roundDown`/`roundUp`
calls, seven of each, of which exactly **six** lie on the path to the
returned lower endpoint:

```
fl(lo+hi) -> fl(/2) -> [ fl(hi-lo) -> fl(*g) -> fl(/2) ] -> fl(m - w)
    1          2                 3         4         5            6
```

which is exactly the six outward-widening steps per endpoint that the finite
path spends.

**The fused form fails at 27 % and 14 % of everything.** §3 predicts a failure
rate that tracks how often the endpoint cancels; it does.

**The fused form with exact `M` and `W` fails too — but only in the
subnormals.** Both sweeps were re-run classifying every one of those cases by
the magnitude of its true endpoint, and every single one is inside the
subnormal range: 588 of 588 and 871 of 871, none normal. The mechanism is the
one the rest of the file already knows: a correctly-rounded final add whose
exact value is below `min_subnormal` lands on a signed zero, and
`roundUp`/`roundDown`
**deliberately do not step at a zero** (`src/rounding.zig:204-205`,
`:231-233`) because a zero is already its own bound. Repairs for exactly this
live in `halve` (`src/interval.zig:437-444`), `Corners.loBound`/`hiBound`
(`:209-226`) and `sqr` (`:964-983`), and a fused form would have to carry one
too. At every normal magnitude the lemma holds and the exact-`M`-and-`W` form
is sound on every case tested — which is the empirical confirmation that §2's
budget is not a guess but the exact threshold.

**The algebraic form fails 1,970 times, and its first failure in the
structured sweep inverts.** `scale([-floatMax, 1e300], 0.0)` comes back
`[floatMax, -floatMax]`: the true image is the single point
`-8.988465624311579e+307`, and the answer excludes it while also breaking the
`lo <= hi` invariant that `src/interval.zig:256-275` warns about and that
`Interval.init` traps on in a checked build. That is the `src/interval.zig:
500-519` rejection reproducing itself under a one-step widening, which is why
the shorter algebra is not the fallback here either.

---

## 7. What the composition is actually paying for

The reason the present form is sound on all 2.9 million cases while the fused
form is sound on almost none is worth stating precisely, because it is the
thing a reader has to take away.

`m` and `w` are not values in the present form. They are **intervals**: `m`
arrives from `add` and `halve` as a pair whose width is the outward steps
already taken, and `w` from `sub`, `mul` and `halve` as a pair. The final
`m.sub(w).lo` is `roundDown(m.lo - w.hi)`, and because `m.lo <= M` and
`w.hi >= W` the enclosure of `L` carries a slack equal to the sum of the two
intermediates' half-widths. On the `k = 40` counterexample:

```
m = [549755813887.49988, 549755813887.50012]      width 4 ULP = 2.44e-4
w = [549755813888.49951, 549755813888.50024]      width 6 ULP = 7.32e-4

composed lo = roundDown(m.lo - w.hi) = -1.0003662109375002
true      L = -0.99993896484375
distance below L = |m.lo - M| + |w.hi - W| = 1.22e-4 + 3.05e-4 = 4.27e-4
```

`4.27e-4` is comfortably larger than the chain error `6.10e-5` that broke the
fused form, and it is larger because it is *not* one number's worth of
rounding: it is two enclosures wide, each of which was built by an operation
whose own outwardness was sized against its own chain.

**That is the theorem `src/interval.zig:466-467` states, and §4 gives it a
number.** In the composition each step's outwardness is the error budget the
next step spends, so the cancellation at the end is paid for by the width that
the composition carried into it. In the fused form there is one step and one
width, and the width has to be a half-ULP of the *result* — while the error it
has to absorb is an ULP of a quantity `2^(k-1)` times larger.

The same argument kills the fixed-count variant. With `N` steps the budget is
`(N - 1/2) ulp(L)` and the chain delivers `ulp(M)` at worst, so it takes
`N >= ulp(M) / ulp(L) + 1` steps, and `ulp(M)/ulp(L)` is unbounded on this
family. No constant repairs it, which is why the existing doc comment's line —
*"A fixed count is a guess at what the chain accumulated, it is only ever a
guess"* (`src/interval.zig:470-471`) — is not a stylistic preference but the
correct statement about this particular computation.

---

## 8. So what would be sound?

Only one thing: **computing each endpoint from an exact expansion**, so that
§2's budget is all that is left over.

`L = (A + B + G*A - G*B) / 2` is a sum of four exactly representable terms —
`A` and `B` are given, `G*A` and `G*B` need 106 significand bits and are exact
under an error-free product, and the division by two is a power of two — plus a
second power-of-two scaling. An error-free transform gets each product with
`@mulAdd` (2 operations), and Knuth's `TwoSum` accumulates the four terms
without ordering them (6 operations each, as `twoSumExact`
(`tests/soundness_shared.zig:415-421`) already does at `f128` width). That is
a rough **30 operations per endpoint**, against the composition's seven
interval operations on the finite path — `add`, `halve`, `sub`, `mul`, `halve`,
`sub`, `add` — and the terms overlap between the two endpoints, so the pair
shares the products. This is an **operation count, not a measurement** —
nothing in this section was timed; measured figures are cited where they
belong, and the full timings live in the benchmark captures this
repository keeps, not in this section. A count of that shape is not a promise
of a win; it is a reason to think the win O1 is after is not in this
direction.

It would also be a different function, not a faster one: it would lose the
`lo <= hi` check by composition that
`src/interval.zig:556-563` calls the one place in the file where an assertion
still has something to catch, and it would have to re-derive the unbounded
branch, the `|factor|` convention and the subnormal repair for itself.

---

## 9. Verdict

- **The proof does not close, and it closes in the negative direction.** The
  error budget for one outward step per endpoint is half a ULP of the endpoint
  (§2, exact, both directions). The fused form's chain delivers up to one ULP
  of the midpoint (§3). The gap between the two is `ulp(M) / ulp(L)`, which is
  **unbounded** on the family `[-1, 2^k]` at `G = 1 - 2^-53` and is `2^39` at
  `k = 40`.
- **The term that breaks the one-step bound is the rounding of the product
  `fl((hi - lo) * g)`** (§4, row 2 of the chain table). It contributes
  essentially `ulp(M)` to `delta`, against a budget of `ulp(L)/2 = 2^-54`.
  Everything else in the chain is exact on that case.
- **No fixed number of steps repairs it** (§7): `N` steps buy `(N - 1/2) ulp(L)`
  and the chain needs `N >= ulp(M)/ulp(L) + 1`.
- **A subnormal defect survives even the exact version**, and would need the
  `min_subnormal` repair the rest of the file already carries (§6).
- **`scale` is unchanged.** No executable line of `src/interval.zig` was
  touched; the only edit is the paragraph in its doc comment that cites this
  document. The `|factor|` convention, the unbounded-input branch, the
  `lo <= hi` invariant and the six steps per endpoint all stand as they were,
  and there is no public API change.
- **O1 should be closed as answered, not reopened.** The prerequisite the plan
  asked for exists, and it says no. Reopening it would need a form that does
  not compute `M - W` from two rounded `f64` intermediates, which is §8, and
  §8 is not this optimisation.

## Appendix — reproducing this

The analysis is exact rational arithmetic over IEEE binary64; no `f64`
quantity in the reference is rounded, and the oracle's five-term comparison,
`ScaleBound` at `tests/soundness_shared.zig:862-920`, is the one being
enforced. The harness models `add`, `sub`, `mul` through `Corners`, `halve`,
`Interval.init` and `rounding.roundUp`/`roundDown` operation for operation,
and the self-check is the zero in the *present form* column of §6: 2.9 million
cases in which the model finds no unsoundness, where a mis-modelled operation
would find one quickly.

The corpora and seeds are named in §6. The structured sweep is 146 magnitudes
— `0`, both signed subnormals, `+-1`, `+-2`, `+-0.5`, `+-floatMax`, `1e+-300`,
`1e300`, `1e16`, `7/3`, and three significands at each of eleven decades —
crossed into 10,731 ordered boxes, against 117 factors (zero, the units, the
binade neighbours of 1 taken 53 steps each way, and the two range ends), each
tried with both signs. The randomised sweep draws its box endpoints from five
shapes: uniform significands at a random binade, integer significands at a
random binade, `[-1, 1]`, `[-floatMax, floatMax]` and a mixed set of specials;
and its factor from `|U[0, 4]|`, a random walk of up to 63 `nextafter` steps
away from 1, a specials list, or a random magnitude.

To re-derive the single counterexample without the harness:

```python
from fractions import Fraction as F
g = (2**53 - 1) / 2**53          # 1 - 2^-53, exactly an f64
lo, hi = -1.0, 2.0**40
M = (F(lo) + F(hi)) / 2
W = (F(hi) - F(lo)) * F(g) / 2
L = M - W                       # -0.99993896484375, a perfectly normal f64

m = (lo + hi) / 2.0             # 549755813887.5, exact
w = ((hi - lo) * g) / 2.0       # 549755813888.4999, one rounding short
e = m - w                       # exact by Sterbenz
import math
b = math.nextafter(e, -math.inf)    # what roundDown returns for e < 0
assert b > float(L)                  # the bound excludes a point of the image
print(b, float(L), "cut =", (b - float(L)) / 2.0**-53, "ULP")
# -0.9998779296875001 -0.99993896484375 cut = 549755813887.0 ULP
# (the exact cut is 2^39 - 3/2 = 549755813886.5; the last term of the print
#  divides in binary64, and 2^39 - 3/2 is not representable)
```