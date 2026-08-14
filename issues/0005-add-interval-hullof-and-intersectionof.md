---
id: 0005
status: merged
severity: medium
labels: []
depends-on: []
parent: 
assigned: 
branch: fix-0005
change-id: woqqynzlxomr
scope: [src/interval.zig, tests/interval_test.zig]
created: 2026-08-15
updated: 2026-08-15T00:52:14
verdict: approve
confidence: 
revisions: 
test-cmd: zig 0.16.0 build test
testable: 
spec: 
sessions: research:2026-08-14T22-36-50-757Z_01a0026b-bec5-7000-bc50-469963ea32aa.jsonl,coder:2026-08-14T22-43-04-475Z_01a00271-729b-7000-afe2-299a10ef5e8c.jsonl,reviewer:2026-08-14T22-50-13-221Z_01a00277-fd65-7000-9a66-d0ba0c3d66bc.jsonl
---

# add Interval hullOf and intersectionOf
## Description

Add Interval.hullOf(items: []const Interval): the minimal single interval spanning all inputs (min lo, max hi; empty if the slice is empty or any input is empty). Add Interval.intersectionOf(items: []const Interval): the common intersection (max lo, min hi); empty if any input is empty or the slice is disjoint. Empty slice returns empty for both.
## Acceptance criteria
- [ ]

## Reproduction

## Test-first acceptance
TEST: zig 0.16.0 build test

## Research

- **Root cause / location**: New feature; no fix. Two new slice-fold public functions on `Interval` in `src/interval.zig`.
- **Key symbols/locations**:
  - `src/interval.zig` → `Interval` struct, closed-interval invariant `lo <= hi` (merged 0001). Proof: pairwise `hull(self, other)` (min lo / max hi) and `intersect(self, other) ?Interval` (max lo / min hi, `null` when disjoint) already exist; `hullOf` / `intersectionOf` are their slice folds.
  - `hullOf(items: []const Interval) ?Interval` — fold min of all `lo`, max of all `hi`; `null` when `items.len == 0`.
  - `intersectionOf(items: []const Interval) ?Interval` — fold max of all `lo`, min of all `hi`; `null` when `items.len == 0` or when the folded `lo > hi` (disjoint), mirroring pairwise `intersect`.
  - `tests/interval_test.zig` → imports `Interval` via `@import("interval")` (wired in `build.zig`); TDD pattern `test "…" { try std.testing.expect… }`, run by `zig build test`. Coder writes red tests first (0001-0004 discipline).
- **Spec notes**:
  1. Return type is unspecified. The empty-slice requirement forces `?Interval` (return `null`): this library has *no empty-interval representation* — every `Interval` satisfies `lo <= hi` — and a fold over an empty slice has no lo/hi to return. This matches the existing `intersect … ?Interval` (null for disjoint) convention. Same dead clause 0003/0004 merged with: "any input empty" is impossible here, since all inputs satisfy `lo <= hi` and none are empty.
  2. `intersectionOf` disjoint slice → must also return `null` (empty), consistent with pairwise `intersect` returning `null` on disjoint. "The slice is disjoint" = folded `lo > hi`. Note touching endpoints are NOT disjoint (`lo == hi` is valid, matches merge `intersect: touching endpoints overlap at a point`).
  3. No empty-input guard beyond `items.len == 0`; `[]const Interval` signals no external allocator concerns.
- **Related open issues**: none (0001-0004 merged). `hullOf` / `intersectionOf` are not Zig keywords.
- **Effort**: S (two short fold methods + a handful of small tests).
- **Suspect/failing tests**: none currently fail (scaffold passes). New tests must cover: `hullOf` empty slice → `null`; spanning multiple inputs (min lo / max hi); `intersectionOf` empty slice → `null`; common core of overlapping inputs; disjoint slice → `null`; touching endpoints → non-null point.

`Spec: adequate` — slice semantics (min-max hull, max-min intersection) are standard and unambiguous; the only gap, the empty-slice representation, is resolved by the library's no-empty-marker invariant forcing `?Interval`/`null`, consistent with the existing pairwise `intersect`, not blocking.

## Notes
- 2026-08-15T00:39:54 Per research: return ?Interval (null on empty slice / disjoint intersection), matching the existing intersect() -> ?Interval convention. There is no empty-interval representation (lo <= hi always).

## Review log
- 2026-08-15T00:52:08 approve:
