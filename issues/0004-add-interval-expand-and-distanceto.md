---
id: 0004
status: merged
severity: medium
labels: []
depends-on: []
parent: 
assigned: 
branch: fix-0004
change-id: nknwkwwsnovy
scope: [src/interval.zig, tests/interval_test.zig]
created: 2026-08-15
updated: 2026-08-15T00:36:15
verdict: approve
confidence: 
revisions: 
test-cmd: zig 0.16.0 build test
testable: 
spec: 
sessions: research:2026-08-14T22-24-25-695Z_01a00260-605f-7000-9586-abb016e6e354.jsonl,reviewer:2026-08-14T22-34-29-005Z_01a00269-950d-7000-af6e-1d1e4005a5bb.jsonl
---

# add Interval expand and distanceTo
## Description

Add Interval.expand(margin: f64): widen both ends by margin (lo -= margin, hi += margin); empty stays empty. Add Interval.distanceTo(x: f64): 0 if x inside [lo,hi], else distance to nearest endpoint (lo if x<lo else hi-x if x>hi).
## Acceptance criteria
- [ ]

## Reproduction

## Test-first acceptance
TEST: zig 0.16.0 build test

## Research

- **Root cause / location**: New feature; no fix. Two new public methods on `Interval` in `src/interval.zig`.
- **Key symbols/locations**:
  - `src/interval.zig` → `Interval` struct with fields `lo`, `hi` (f64, closed-interval invariant `lo <= hi` per merged 0001). Current tree is a bare scaffold: only `init` + `contains` stub (merged issues' methods absent from this checkout — no dependency on them). Add `pub fn expand(self: Interval, margin: f64) Interval` and `pub fn distanceTo(self: Interval, x: f64) f64`.
  - Semantics (intent): `expand` → `.{ .lo = lo - margin, .hi = hi + margin }` (widen both ends). `distanceTo` → `0` if `x` inside `[lo,hi]` (endpoints inclusive, matching `contains`); else `lo - x` when `x < lo`, else `x - hi` when `x > hi` (non-negative distance to nearest endpoint).
  - `tests/interval_test.zig` → imports `Interval` via `@import("interval")` (wired in `build.zig`); pattern `test "…" { try std.testing.expect… }`, run by `zig build test`. Currently a passing scaffold test; coder writes red tests first (0001/0002/0003 discipline).
- **Spec notes**:
  1. `distanceTo` parenthetical reads "(lo if x<lo else hi-x if x>hi)" — literal typos. The returned value must be a *distance*: `lo - x` (x<lo) and `x - hi` (x>hi), both non-negative. Following the literal text verbatim yields a broken/signed result. Function name + "distance to nearest endpoint" make the intended math unambiguous.
  2. "empty stays empty" is unrepresentable here: every `Interval` satisfies `lo <= hi` (closed intervals, no empty marker) — same dead clause 0003 merged with. `expand` has no empty branch to take; leave it as naturally widening code.
  3. Negative `margin` is unconstrained (would shrink/narrow); not worth over-engineering — coder may implement plainly and note it.
- **Related open issues**: none (0001-0003 merged). `expand`/`distanceTo` are not Zig keywords; no name clash (0001 `union→hull` precedent).
- **Effort**: S (two short methods + a few small tests).
- **Suspect/failing tests**: none currently fail (scaffold passes). New tests must cover: `distanceTo` below / inside / above, at exact endpoints (returns 0); `expand` positive margin widens both ends, margin 0 is identity.

`Spec: adequate` — core semantics (distance-to-nearest-endpoint, widen-both-ends) are standard and unambiguous; caveats above (two formula typos, dead empty clause) are resolvable from the function name alone, not blocking.

## Review log
- 2026-08-15T00:36:12 approve:
