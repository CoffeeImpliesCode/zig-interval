---
id: 0003
status: merged
severity: medium
labels: []
depends-on: []
parent: 
assigned: 
branch: fix-0003
change-id: ttzlupsyyspu
scope: [src/interval.zig, tests/interval_test.zig]
created: 2026-08-15
updated: 2026-08-15T00:22:54
verdict: approve
confidence: 0.95
revisions: 1
test-cmd: zig 0.16.0 build test
testable: 
spec: adequate
sessions: research:2026-08-14T22-01-43-724Z_01a0024b-982c-7000-add1-8f229b963523.jsonl,research:2026-08-14T22-02-14-548Z_01a0024c-1094-7000-a856-b9cb6fd6213e.jsonl,coder:2026-08-14T22-05-42-766Z_01a0024f-3dee-7000-b877-babf550102ca.jsonl,reviewer:2026-08-14T22-20-17-455Z_01a0025c-96af-7000-ac06-49c8886aa0d3.jsonl,coder:2026-08-14T22-09-31-821Z_01a00252-bcad-7000-af0e-b441d45f3acc.jsonl
---

# add Interval scale and translate
## Description

Add Interval.scale(factor: f64) (scale about the midpoint, preserving width*factor) and Interval.translate(delta: f64) (shift lo and hi by delta). Empty interval: scale returns self, translate returns self.
## Acceptance criteria
- [ ]

## Reproduction

## Test-first acceptance
TEST: zig 0.16.0 build test

## Research

- **Root cause / location**: New feature; no fix needed. Both are new public methods on `Interval` in `src/interval.zig`. Struct has fields `lo`, `hi` (f64, invariant `lo <= hi`) plus `contains` from scaffold and `midpoint`/`clamp`/`hull`/`intersect`/`width`/`overlaps`/`subsetOf` from merged issues 0001/0002.
- **Key symbols/locations**:
  - `src/interval.zig` → add `pub fn scale(self: Interval, factor: f64) Interval` and `pub fn translate(self: Interval, delta: f64) Interval`. Expected math: `translate` = `.{ .lo = lo+delta, .hi = hi+delta }`; `scale` about midpoint `m=(lo+hi)/2` preserving width×factor → `.{ .lo = m - (hi-lo)*factor/2, .hi = m + (hi-lo)*factor/2 }`.
  - `tests/interval_test.zig` → imports `Interval` via `@import("interval")` (wired in `build.zig`); pattern `test "…" { try std.testing.expect… }`, run by `zig build test`. Existing file is a passing scaffold test; no failing signal yet — coder writes red tests first (0001/0002 discipline).
- **Spec gaps** (block on re-triage):
  1. "Empty interval" is unrepresentable in this type: all `Interval`s satisfy `lo <= hi` (closed intervals); there is no empty/pathological value, so the `scale`/`translate` empty-clause is dead, untestable code. Either drop the clause or define how an empty interval is represented.
  2. `scale` with negative `factor` yields `lo' > hi'`, breaking the `lo <= hi` invariant. Spec says `factor: f64` with no constraint; expected result for `factor < 0` (re-sort bounds vs. abs vs. reject) is undefined.
- **Related open issues**: none. 0001, 0002 merged; 0001 note `union→hull rename forced by Zig keyword` — scale/translate names are not Zig keywords, no clash.
- **Effort**: S (two short methods + a few small tests).
- **Suspect/failing tests**: none currently fail (scaffold passes). New tests must cover: translate positive/negative/zero delta; scale factor 1 (identity), 0 (degenerate at midpoint), 2 (doubling width); endpoints and midpoint preserved under scale.

`Spec: underspecified` — empty-interval clause is untestable (no empty Interval exists) and scale's negative-factor behavior is undefined; re-triage should confirm/remove both.

## Review log
- 2026-08-15T00:08:33 request-changes: red/green re-run failed:
- target command FAILED at the fix tip (expected PASS): zig 0.16.0 build test (exit 1)
- 2026-08-15T00:22:02 approve (confidence 0.95): TDD red→green confirmed; scale/translate correct about midpoint, reuse width()/midpoint(); negative factor resolved via |factor| to hold lo<=hi (spec's undefined gap), tested; scope+size clean.
