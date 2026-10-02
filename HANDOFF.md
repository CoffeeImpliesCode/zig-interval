# HANDOFF — zig-interval pack-up

**Local scratch notes. This file is untracked and must stay that way.** It cites
local paths and host facts on purpose, because the whole point of the current
uncommitted pass is that those do *not* appear in the shipped tree. Do not
"fix" the paths below, and do not `git add` this file — `git ls-files
HANDOFF.md` is empty by design. The shipped record lives in `docs/`.

Date of this snapshot: 2026-10-03. Repo root:
`~/zig-interval`.

---

## 1. Current checkout state

```
git rev-parse --abbrev-ref HEAD   -> main
git rev-parse HEAD                -> 5fc1dac36060b30dd6fdb448fdaee719cb27cdec
git rev-list --left-right --count origin/main...HEAD -> 0  0
```

`main` and `origin/main` are the same commit, so **nothing has been pushed for
this work**. Last eight commits on `main`:

```
5fc1dac build(cross): add 53-target compilation-only sweep
b9054b3 docs(perf): reject noisy contradiction-scan trial
f1c9e7c docs(perf): record current baseline and measured LP trial
7b472ae feat(bench): compare LP allocators under reproducible quality gates
12848a1 build(gates): enforce expanded checks and resolve lint findings
76104b3 test: adopt cross-test, and record the timeout that reads like a defect
ada1aec docs,ci: audit every README claim, correct the plan's own state, and add the gate that was missing
083d747 perf(rounding): move the format endpoints into the layer that owns the format, and take the tree off the std accessors
```

Working tree: **38 staged deletions, 22 unstaged modifications, 0 untracked**
(counted before this file existed; this file is the only untracked path now).

Jujutsu sees the same tree one commit ahead of `main`:

```
uznotpqn c2315376  (no description set)      <- working copy, uncommitted
wsowlvmw 5fc1dac  build(cross): add 53-target compilation-only sweep   <- main
spnsvtlz fee3fd41 (no description set)
qzmwumps b9054b3  docs(perf): reject noisy contradiction-scan trial
```

`fee3fd41` is a **shape artifact, not real history**: its tree is
`937806fa…`, identical to `5fc1dac`'s, and its parent is `b9054b3`.
`git merge-base --is-ancestor fee3fd41 HEAD` answers NOT-ANCESTOR and
`git log` walks `5fc1dac → b9054b3` straight. `jj` infers the extra parent
from git's `refs/heads/main` reflog. Do not try to commit on top of it and do
not "fix" it with `jj op log` — git is the shippable record, and it is clean.

---

## 2. What the uncommitted cleanup contains

### 2.1 The 38 staged deletions — dead process trees, removed

Both directories are already gone from disk; only the index still remembers
them.

| Path | Files | What it was |
| --- | --- | --- |
| `issues/` | 36 | five `.events-000N.jsonl`, twenty `.gates/000N-*` artifacts, `.gitkeep`, and the five `000N-*.md` issue files |
| `.omp/agents/` | 6 | `vibe-coder`, `vibe-finder`, `vibe-research`, `vibe-reviewer`, `vibe-senior-review`, `vibe-triage` |
| `.omp/rules/` | 1 | `vf-guardrails.md` |

`git grep -n -e '\.omp/' -e 'issues/' -e '\bvibe-'` over the whole tree
returns **0 lines** — nothing references them (`.vf/gates.yml` is the live
gate wiring and is untouched), so this is a clean cutover: no shim, no
redirect, no replacement directory.

### 2.2 The 22 unstaged modifications — the host/origin scrub plus a doc refresh

`+1119 / -1449` over 22 files. **No file under `src/` or `tests/` is touched** —
the change set is build wiring, CI, the quality harness, and documentation.

**(a) Host-specific facts removed, host-agnostic contracts substituted.** The
recurring edits are: the machine name `buildhost`, the `/vol` NFS mount, the
`/home/tmp{,2}/$USER` per-user volume list, and hard byte figures such as
"1014 MB", each replaced by the rule the code already enforces.

| File | +/- | Substance |
| --- | --- | --- |
| `build.zig` | 47/71 | `consumerCacheRoot` goes from **three** candidates to **two** (drop the per-user `/home/tmp{,2}` scan); comment prose de-hostified |
| `.github/workflows/ci.yml` | 29/23 | the two-candidate cache-root rule, stated as an interface |
| `tools/quality/harness/lib/cross-test/scratch-contract.sh` | 106/80 | the scratch-mount rule carried by the distributed harness itself |
| `tools/quality/harness/bin/zig-gate` | 73/52 | same rule at the gate |
| `tools/quality/harness/bin/cross-test` | 61/49 | same rule at the cross driver |
| `tools/quality/harness/lib/cross-test/test.sh` | 23/11 | same |
| `tools/quality/harness/lib/cross-test/test-zig.sh` | 13/5 | same |
| `tools/quality/PROVENANCE.md` | 117/79 | receipts de-hostified; absolute `/home/tmp2/...` log paths dropped |
| `tools/quality/manifest.tsv` | 6/7 | manifest bookkeeping |
| `tools/quality/SHA256SUMS` | 7/7 | re-hash of the above |
| `scripts/scratch.sh` | 36/47 | scratch-root selection de-hostified |
| `cross-test.profile.sh` | 30/32 | de-hostified |
| `scripts/build_mpfr.sh` | 3/4 | de-hostified |
| `scripts/install-quality-tools.sh` | 5/5 | de-hostified |

**(b) README restructured — the performance narrative moved out, the scratch
contract moved in.** `README.md` is `+47 / -327`. The 2026-10-02 capture
narrative (single-run table, capture recipe, per-run checksums) is deleted from
the README, because `docs/performance-handover.md` §"Wave 2" and
`docs/performance-baseline-2026-10-02.tsv` already own it. What replaces it is
a host-agnostic statement of the install/scratch contract — the two modes
(managed host vs. every other host), the explicit rule that the NFS refusal is
load-bearing because `renameat2()` fails there, and `<scratch>` placeholders in
the commands.

**(c) Documentation brought back in line with the tree.**

| File | +/- | Substance |
| --- | --- | --- |
| `docs/performance-handover.md` | 426/564 | new **§0 "Scratch space, cache placement and cleanup"** carrying the rule that moved out of `README.md`; "the handover's final receipt" → "Final Wave 3 verification section"; absolute log paths and the machine name dropped |
| `docs/tests-and-architecture-plan.md` | 36/34 | de-hostified citations |
| `docs/scale-enclosure.md` | 33/32 | de-hostified |
| `docs/next-work-plan.md` | 15/14 | "on host `buildhost`" → "on a shared host"; the 2026-09-30-vs-current-baseline relationship restated; pointer to the final Wave 3 section |
| `docs/performance-baseline-2026-10-02.tsv` | 1/1 | header: host name out |
| `docs/performance-trial-2026-10-02.tsv` | 1/1 | header: host name out |
| `bench/bench_lp.zig` | 4/4 | comments only |

**The claim this section makes:** the cleanup is behaviour-neutral — no `src/`
line, no `tests/` line, no benchmark arithmetic moved. Step 2 below is what
proves it, and it is the reason the commit must not be pushed before that
build.

---

## 3. Outside work: `/tmp/zig-interval/`

**Inventory only. Nothing here has been deleted, moved or consolidated yet.**
Sizes measured 2026-10-03 with `du -sh`.

| Entry | Size | What it is |
| --- | --- | --- |
| `waves/` | 62M | the evidence record: 131 entries, the bulk of them `wave1-*`/`wave2-*`/`wave3-*` run logs |
| `waves/evidence/` | 12 files | `wave2-lp-comparison.json`, `wave2-*.stat`, `wave2-profile-metadata.json`, `wave3-*-contract.json`, `wave3-*-comparison.json` |
| `waves/quality-wave1-9fby02wf/` | — | `cross-out/`, `empty-home/`, `prefix/` — the cold install and its prefix |
| `waves/quality-wave3-fqbcdef1/` | — | `cross-out/`, `empty-home/` — the reviewed install |
| `waves/original-lp-cases.json` | 939 B | the 13 LP case definitions as captured |
| `zigcache/` | 753M | parent build cache |
| `zigglobal/` | 51M | parent global cache |
| `zig-interval-consumer/` | 103M | nested fixture consumer cache (dbg heap) |
| `zig-interval-consumer-global/` | 49M | nested fixture consumer cache (smp heap) |
| `compile53-tdtkix79/` | 2.8M | the 53-target compilation-only sweep output |
| `run20-2enzy5sg/` | 1.7M | the 20-call LP profile capture |
| `cross/` | 1.2M | `cross-test-summary.json` (run `20261001-230423-70143-10830`, 5 targets, mode `zig-build`, Zig 0.16.0) and `runs/` |
| `lint-sweep/` | 340K | `findings.json` plus the ziglint / cross-exit sweep logs |
| `verification/` | 32K | `summary.json`, `publication.json`, `root-boundaries.json`, `documentation-guard-smokes.json`, and the `lp-box`/`lp-unsat`/`usage` build+run stdout/stderr |
| `zig-gate.t0bQzGgO/` | 88K | a gate run directory |
| `gate.log` | 16K | the `zig fmt --check` / `zig build` / … gate log; head reads `== zig fmt --check ==\n  fmt: OK` |
| `.rev_new.txt`, `.rev_old.txt` | 815 B each | two revision row-id lists (identical prefix so far), used for the revision comparison |
| `zl.txt` | 0 B | empty leftover |

Roughly 1.0 GB total, of which about 950 MB is Zig cache that a fresh
`zig build` recreates. The evidence worth keeping is `waves/`, `cross/`,
`lint-sweep/findings.json` and `verification/*.json`; everything else is
regenerable.

---

## 4. Remaining pack-up steps

Steps 0–1 (seven-slice origin cleanup, and the outside-work inventory) are
done. What is left, in order:

### Step 1 — Consolidate the outside work
Decide per entry in §3 above: **cite in the shipped docs, keep, or delete.**
The doc sweep has already removed the absolute `/home/tmp2/...` log paths from
`tools/quality/PROVENANCE.md`, so the receipts now say what ran without saying
where — consolidation must not put those paths back. Keep `waves/evidence/`,
`cross/cross-test-summary.json`, `lint-sweep/findings.json` and
`verification/summary.json` until the final gate has been read back; delete the
`zigcache/`, `zigglobal/`, consumer caches and the `zig-gate.*` scratch only
after step 2 is green, since a build that has just passed is the cheapest thing
to re-create if it has to be.

### Step 2 — Minimal build
The cheapest proof that the scrub did not touch behaviour, and it is the gate
for step 3. From the repo root, per `docs/performance-handover.md` §6:

```sh
zig build test        # exits 0, ends with "readme examples ok: 31 checks"
zig fmt --check       # the gate's first section; must print fmt: OK
```

`zig build bench-lp` is safe (the 20,000-row budget bounds it) but is not part
of the minimal pass — nothing in the diff touches `bench/` arithmetic except
four comment lines. The installed quality gate (`$QUALITY_TOOLS_PREFIX/bin/zig-gate`,
see §6 of the handover and `.vf/gates.yml`) is tens of minutes because it
builds and runs four foreign targets; run it only after the history is shaped,
as the final check before push.

**Read past a compile error before believing a red gate.** That exact lesson is
recorded at `docs/next-work-plan.md:576-583`: a tree once sat red on a
six-placeholder / five-argument `std.debug.print`, and nothing had compiled
since. A red `zig build test` is not evidence about behaviour until it has been
read past the compile.

### Step 3 — Shape the history
The index holds two unrelated things (38 deletions, 22 modifications) and the
working tree holds them uncommitted. Land them as two commits at minimum:

1. `chore: drop the issue-tracker and vibe-agent process trees` — the 38 staged
   deletions. Pure deletion, no content change.
2. `docs,ci,build: de-host the tree and move the scratch contract out of the README`
   — the 22 modified files. One theme: no machine name, no `/vol` NFS path, no
   `/home/tmp{,2}` volume scan, no absolute evidence path in anything that
   ships. `build.zig`'s `consumerCacheRoot` losing a candidate is a behaviour
   change and belongs in its own commit if the reviewer wants it separable.

Both are reversible on their own and neither should absorb the other. Then
confirm the working copy is clean and that git's history is what you intend:

```sh
git status --short --branch     # expect: no staged, no modified
jj status
jj log -r 'main | main@origin' --no-graph \
  -T 'commit_id.short() ++ "  " ++ description.first_line() ++ "\n"'
```

### Step 4 — Cleanup pass 1: sweep the working tree

Both commands below were run on this tree on 2026-10-03. The working tree is
already clean — **0 hit lines, excluding this file** — which is the direct
evidence that the uncommitted cleanup did what it claims. Re-run them after
step 3 to keep it that way:

```sh
# pass 1: the working tree
grep -rn --exclude-dir=.git --exclude-dir=.jj --exclude-dir=.zig-cache \
  --exclude-dir=zig-out --exclude=HANDOFF.md \
  -e buildhost -e '/home/tmp' -e '/vol/' -e fob-vol .

# pass 2: what actually ships, i.e. the committed history
git grep -n -e buildhost -e '/home/tmp' -e '/vol/' -e fob-vol main -- .
```


### Step 5 — Cleanup pass 2: the same sweep against the committed history

**Pass 2 is red today and that is expected: it reads `main`, and the cleanup
is not committed yet.** Measured on `main` at `5fc1dac`: **114 hit lines across
16 files** —

```
docs/performance-handover.md            34    scripts/scratch.sh                 7
README.md                               18    tools/quality/PROVENANCE.md        7
cross-test.profile.sh                   10    tools/quality/harness/bin/zig-gate 7
tools/quality/harness/lib/cross-test/scratch-contract.sh   9
build.zig                                6    tools/quality/harness/bin/cross-test 5
.github/workflows/ci.yml                 2    tools/quality/harness/lib/cross-test/test.sh 2
docs/next-work-plan.md                   2    scripts/build_mpfr.sh              2
docs/performance-baseline-2026-10-02.tsv 1    tools/quality/harness/lib/cross-test/test-zig.sh 1
docs/performance-trial-2026-10-02.tsv    1
```

Every one of those 114 lines is removed by the 22 modified files in §2.2.
That is the number pass 2 has to reach after step 3: **0**, with nothing left
except this file, which is untracked and so is never in `git grep`'s path.
A hit that survives both passes is a host fact that came back through another
door — fix it and re-run step 2 before step 6. Nothing under `src/` or
`tests/` matched in either sweep, which is consistent with §2.2's claim that
the change set is behaviour-neutral.

### Step 6 — Push

```sh
git push origin main
```

`main` is currently equal to `origin/main` (`0  0`), so this is the first push
of the whole pack-up. Push only after step 2 is green and steps 4–5 find
nothing. `git rev-list --left-right --count origin/main...HEAD` should read
`0  0` afterwards.

---

## 5. Future work

### 5.1 No defect, plan, feature or optimisation row is OPEN

Evidence, read 2026-10-03 from `docs/next-work-plan.md`:

* §1.1 — all six S1 rows (`D1`, `D2`, `D3`, `D4`, `D17`, `D18`) read
  **FIXED**, each with its owning plan item (P1–P4, P8, P8). The section says so
  in its own words at `:38`: *"**Every row is FIXED at this revision** — D10 and
  D11 were the last two, and P6 and P7 own them."*
* §1.2 — all eleven S2–S4 rows (`D5`–`D16`) read **FIXED** (P5, P6, P7, F1).
* §2 — *"**Every item in this section is done — P1 through P8, with no
  exception.**"* (`:292`)
* §3 — *"**All three features are done.**"* (`F1`, `F2`, `F3`; `:589`)
* §4 — *"**This section has no open entry left.**"* (`:749`) — `O1` answered in
  the negative by the proof in `docs/scale-enclosure.md`, `O2` and `O3` landed,
  `O4` and `O5` refused and closed.
* §5 "Not doing" is a closed list of things a later session must not
  relitigate (the `eliminate` sign-bucket duplication, stopping after `n - 1`
  variables, `powf`'s composition, the withdrawn `log2`/`log10` claim, the
  `0 * inf` guard, the oracle's two overflow guards, the `bench-lp` sizes).

So there is **no OPEN row to pick up**. The TODOs below are the only items the
plan itself describes as deferred, un-specified, or explicitly not bought.
Three of them, in the order a future session should take them.

### 5.2 TODO list

**TODO-1 — `DynVec` copy still double-frees; the ownership check constrains
replacement, not duplication.**
`deinit` compares `comps.ptr` against the recorded `own` address under
`std.debug.runtime_safety`, which makes a second `deinit` safe, but a *copy*
carries both the same `comps.ptr` and the same `own`, so both copies pass the
check and the double free stands. The type's own comment says so rather than
pretending otherwise, so this is a documented limitation, not a silent one — it
still needs a spec before it can be fixed (a move-only type is the obvious
route and has never been written down).
Pointers, verified against the tree on 2026-10-03 (the plan's `:446` and
`:482-504` have drifted): `src/vector.zig:489` (the `own: [*]Interval`
field), `src/vector.zig:527-559` (`DynVec.deinit`; the check itself is
`:541-548`); rationale at `docs/next-work-plan.md:380-384` (plan item P5,
"What it did not buy").

**TODO-2 — an operand-level cancellation pre-pass for `combinedColumn` that
avoids `f128` entirely.**
`cancelsExactly` decides exact cancellation in `f128` (a product of two `f64`
needs 106 significand bits, `f128` carries 113) behind a cheap `f64` pre-filter.
An operand-level pass that recognises the cancelling pattern without `f128` was
*"never specified and is still not ready to implement"*; the plan's standing
instruction is to **leave the filtered version as it is** because the
measurement says it is affordable. Taking this on means writing the
specification first, and it is a performance item, not a soundness one.
Pointers, verified against the tree: `src/lp_exact.zig:210`
(`cancelsExactly` — it has moved out of `lp.zig`, which reaches it through the
`exact` alias at `src/lp.zig:69-72`, so the plan's `src/lp.zig:916` is stale);
`docs/next-work-plan.md:142-145` and `:362-365` (plan item P4).

**TODO-3 — a `scale` formulation that does not compute `M - W` from two rounded
`f64` intermediates.**
The one-step `scale` formulation was proved insufficient
(`docs/scale-enclosure.md` §9: `ulp(M) / ulp(L)` is unbounded on the family
`[-1, 2^k]` at `G = 1 - 2^-53`, so no fixed step count repairs it). A form that
avoids the two rounded intermediates is §8 of that document and is explicitly
*"a different piece of work, not this optimisation"* — it is **not** a
reopening of O1, which is answered and closed.
Pointers, verified against the tree: `docs/scale-enclosure.md` §8 and §9;
`src/interval.zig:587` (`scale`), whose doc paragraph at `:475-479` cites the
measurement and O1's verdict; `docs/next-work-plan.md:792-812`.

Nothing else is queued: §4 of the plan records no second LP candidate behind the
refused O5 trial, and the corpus tier (`tests/corpus/elementary.txt`, 1886 rows
over 24 labels) is done under T4 in `docs/tests-and-architecture-plan.md`.

---

## 6. Resume pointers

Read in this order after picking this up cold:

1. **`docs/next-work-plan.md`** — the defect tables (every row FIXED), plan items
   P1–P8, features F1–F3, optimisations O1–O5, and §5 "Not doing".
2. **`docs/performance-handover.md`** — the tree state and the gate wiring in
   §2; **§0 "Scratch space, cache placement and cleanup"** for the rule the
   current uncommitted pass moved out of `README.md`; §6 "How to check the tree
   is healthy" for the exact commands step 2 uses; §8 "What not to do" and §9
   "Withdrawn, and not being done".
3. **`docs/tests-and-architecture-plan.md`** — owns the MPFR corpus tier (T4, T6,
   T7) and the oracle split across `tests/soundness_shared.zig` plus its four
   siblings.
4. **`docs/scale-enclosure.md`** — the exact-rational error budget behind O1's
   negative verdict, and TODO-3's §8.
5. **`.vf/gates.yml`** and **`tools/quality/`** — how the gate is installed and
   what the manifest pins.
6. **`src/rounding.zig`** — small, and it explains the whole rigor model: every
   endpoint is widened outward with `roundUp` on the upper side and `roundDown`
   on the lower side, at `src/rounding.zig:219` and `:241`. (The plan's
   `src/rounding.zig:156-185` for that range has drifted; read the file.)

Measurements are quoted from files, never from prose:
`docs/performance-baseline-2026-10-02.tsv` (362 rows, the current baseline) and
`docs/performance-trial-2026-10-02.tsv` (52 rows, the refused O5 trial,
`outcome=REJECTED NO_CLAIM`). A single capture is not a speedup, and the 2.196 %
median gain from that trial must never be quoted as one.