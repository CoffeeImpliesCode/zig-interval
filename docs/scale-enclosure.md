# Enclosing centred interval scaling

`Interval.scale` maps a finite interval `[A, B]` about its midpoint by
`G = |factor|`. Over the reals, its endpoints are

```text
M = (A + B) / 2
W = (B - A) * G / 2
L = M - W = (A + B + G*A - G*B) / 2
H = M + W = (A + B - G*A + G*B) / 2
```

The implementation in `src/interval.zig` encloses the intermediate values with
interval arithmetic. The exact reference in `tests/soundness_shared.zig`
compares expansions of the endpoint terms.

## Why a final outward step is insufficient

Consider a direct floating-point implementation:

```text
m = fl(fl(A + B) / 2)
d = fl(B - A)
w = fl(fl(d * G) / 2)
lower = prevDown(fl(m - w))
upper = nextUp(fl(m + w))
```

Here `fl` denotes IEEE binary64 round-to-nearest. An outward step covers the
last rounding error. Earlier errors are measured at the scale of `M` and `W`,
which can be much larger than the final endpoint after cancellation.

For a lower endpoint, let `E` be the exact value of the final expression over
its already rounded intermediates, `e = fl(E)`, and `d = e - prevDown(e)`.
With `delta = E - L` and `epsilon = e - E`, the bound is sound if and only if

```text
delta + epsilon <= d
```

A one-step margin on `e` alone does not bound `delta`.

## Counterexample

Use the exactly representable inputs

```text
A = -1
B = 2^40
G = 1 - 2^-53
```

The real lower endpoint is

```text
L = -1 + 2^-14 + 2^-54
  = -18013298997854207 / 18014398509481984
```

The direct binary64 chain produces

```text
m = 549755813887.5
w = 549755813888.4998779296875
m - w = -0.9998779296875
prevDown(m - w) = -0.99987792968750011102230246251565404236316680908203125
```

The proposed lower bound exceeds `L` and excludes part of the real image.
The sum and difference of the input endpoints are exact here. The product
rounding loses information before cancellation; exact final subtraction
cannot recover it. Reflecting the interval to `[-2^40, 1]` gives the matching
failure on the upper endpoint.

The endpoint error must account for the complete chain. Keep enclosure
arithmetic for the intermediates unless a replacement derives a bound for
all of their rounding errors, including subnormal and unbounded cases.
