# Performance work — handover

**Written for a future session that has none of the prior context.** Everything
needed to resume is below. If a statement here conflicts with the code, the code
wins — but check the code before trusting this file, because it describes a
moving target.

The companion document is `docs/next-work-plan.md`. It carries the defect table
and the ranked plan, which at this revision carries no open item; this file
carries what was measured, what landed, and what was withdrawn. Nothing is
duplicated between them. Two claims in it have since gone stale and are
superseded here: D16's oracle skip counts of 2,040 for `div` and 2,163 for
`recip` were true when it was written and are both **0** now, and the "8 of 56"
coverage figure is **35 of 56**, with the other 21 the corpus tier's.

Two more claims in it have moved since. **D18 is settled**: an infinite endpoint
is a ray, `Interval.init` canonicalises the two overflow rays, and the frontier
sweep now **judges** all thirteen operations it walks instead of withholding six
of them. The reading is stated once, in
[two kinds of infinity](../README.md#two-kinds-of-infinity); nothing in this
file's measurements changes with it, because the repair is two comparisons in
the constructor and one branch on `scale`'s unbounded path. And the twenty-one
operations the in-tree oracle does not judge are no longer waiting on
hand-written reference series **or on anything else**: the independently
generated MPFR directed-rounding containment corpus landed, 1886 rows over 24
labels with 427 of them exactly representable, so the 56-operation audit set is
covered by two tiers and no figure in this file changes for it.

Everything in sections 2 and 3 was measured on 2026-09-30, and that date still
governs every table in them. Later material is **added under its own heading and
its own date rather than folded into those sections**: the cross-target
verification at **2026-10-01**, which re-ran the test step rather than a
benchmark, and on **2026-10-02** the gate receipts, the three benchmark smokes,
the three-run baseline, the LP profile and the Wave 3 solver trial that
**rejected** the one candidate that profile selected. None of them restates a
2026-09-30 figure and none is a delta against one — the later captures did not
run on an otherwise idle machine, and the later baseline is a fresh capture
rather than a re-measurement of the state 2026-09-30 was taken in. The growth
figures come from throwaway programs that read the sign buckets directly, and
section 3 step 1 gives the routine to rebuild them. Nothing here is a guess.

The later **2026-10-02 full compilation sweep** is recorded separately below:
all 53 published targets compiled the existing library, 11 test binaries and
NaN probe in Debug. No numerical implementation or test body needed a change.
It adds compilation coverage, not runtime soundness evidence.

**The gate wiring in section 2 is stated as interface rather than as a run.** How
the tools are installed, where the gate resolves them and what a failed install
leaves behind is written in the present tense because it is the contract in
`.vf/gates.yml`, `scripts/install-quality-tools.sh` and `tools/quality/`. **The
current status of the prefix-only gate is green**: the four required Linux
targets each execute **348** tests and `x86_64-windows` is `build_only`. A cold
install into a fresh prefix with an empty `HOME` followed by the gate run out of
it **failed**, and that red case stays in the record whole — an install that
fails late leaves the work root behind and the prefix empty, and a red gate over
a tree nothing in it changed is not a claim about the source either. Wave 2's
three-run measurements are recorded, under their own date, in the sections below
and in
[`docs/performance-baseline-2026-10-02.tsv`](performance-baseline-2026-10-02.tsv),
and Wave 3 is **closed with the trial REJECTED and NO CLAIM**: the profile's one
candidate was implemented, measured against a frozen baseline in three
counterbalanced pairs, failed all three predeclared acceptance criteria, and was
**removed again**, so `src/lp.zig` is byte-identical to the pre-trial file and
**no solver optimization is accepted, landed or pending**. Its own section
carries the predeclared criteria, the reasons each of them failed, the
correctness work that *did* pass, and the
[trial TSV](performance-trial-2026-10-02.tsv). Remote GitHub Actions and the
`vf` engine have not been executed; neither is evidence for the verified local
gate.

---

## 0. Scratch space, cache placement and cleanup

**The rules live in this repository, not in a machine-wide policy file.** The
distributed harness carries them itself in
`lib/cross-test/scratch-contract.sh`: a candidate has to be a real mountpoint
with a writable path and enough free space, symlinked and foreign-owned
directories are refused, an NFS filesystem is refused, and a machine that
publishes an approved list of scratch volumes is held to that list. On any other
host it accepts an explicitly owned, writable, local path, which is what lets a
CI runner use `/tmp` where a shared machine may not. Where a host-wide policy
file *is* readable it is still sourced first and still wins, so a site that
publishes one is describing an extra layer, not a prerequisite: nothing in this
repository requires such a file to exist, and nothing here required editing one
to get there.

**But prefer a LOCAL volume for a Zig build cache.** A cache on NFS does not
work: the mount rejects `renameat2` with `EINVAL` and Zig reports `programmer
bug caused syscall error: INVAL`. That is why the capture commands below name a
local cache explicitly — the benchmark capture, the instruction-count probe and
the throwaway build each pass `--cache-dir` and `--global-cache-dir` under a
scratch root the contract approved, and `cross-test` rejects `--cache-dir`
because it manages its own. The short commands quoted in passing elsewhere in
this file — `zig build test`, `zig build bench-lp`, `zig build docs`,
`zig-gate` — pass no cache flag: they are the abbreviated form, and they assume
the local cache the surrounding shell or runner already provides. That is a
statement about those commands, not a promise that any snippet here is portable
as pasted. **The resolver that finds a scratch root is one file, not two.**
`scripts/scratch.sh` no longer carries its own list of volumes, its own "is this
a real local directory" test, or a machine-wide policy file as a hard
prerequisite. It sources
`tools/quality/harness/lib/cross-test/scratch-contract.sh` — the same helper the
installed `zig-gate` and `cross-test` use — and the only decision left in it is
which candidates to OFFER: `ZIG_INTERVAL_SCRATCH` if it is set (validated, not
trusted), then whatever a host-wide policy named as `HOST_SCRATCH_ROOT` if there
is one and it named one (an empty root is skipped, not accepted), then the
caller's own directory under each approved volume in managed mode —
`$QUALITY_MANAGED_ROOTS`, the contract's own variable, not a restatement of it
— and on any other host an explicitly set `TMPDIR` and nothing else. Every
candidate is cleared by the contract before it is offered, so a refusal names
its reason, and if none survives it prints what it checked and fails rather
than choosing a volume on your behalf. **The one refusal it keeps that the
contract does not: it never falls back to an unnamed `/tmp`.** That is this
file's job on a shared machine, and an explicitly set `TMPDIR` is somebody
else's decision and is honoured. Its interfaces — `scratch_root`,
`scratch_init`, `SCRATCH_ROOT`, `SCRATCH_DIR` — are unchanged, so
`scripts/build_mpfr.sh` needs no edit.

`build.zig`'s `consumerCacheRoot` names the root for the nested fixture build
and cannot ask that shell policy at all, so it carries two candidates of its
own: `ZIG_INTERVAL_CONSUMER_CACHE`, resolved absolute because the nested
build's working directory is `fixture/`; and otherwise **the cache directory
this build was itself given**, also absolute. Read the function rather than
trusting a copy of it here. There is no `XDG_CACHE_HOME`, no `$HOME` and no
per-user volume scan in that list, and none is wanted back — an environment
variable is not a decision, `$HOME` may be an NFS mount, and a scan for a
per-user directory is a volume naming question this build has no business
answering. **So "`scratch.sh` does the same" was a false sentence about this
project; read the function.** The one difference worth naming, because it looks
like a bug and is not: that second candidate can point inside the repository —
`.zig-cache` on a runner that passes no `--cache-dir` — and nothing here
promises otherwise. That is what keeps CI working, and it is still a directory
this build chose rather than one invented at the last moment.

**Clean up after yourself, periodically.** Remove your own caches, throwaway
probes, scratch files and background jobs once the work that needed them is
done. A shared `/tmp` holds other people's data, so delete only your own
artifacts — never blanket-clear it.

**One trap worth naming, because it was nearly deleted.** `probe/` at the
repository root looks like leftover scratch and is not: all four files are
tracked, and `docs/tests-and-architecture-plan.md` and this file cite three of
them **by name** as the proof for claims they make. Before deleting anything
that looks like clutter, grep the docs for its name.

---

## 1. What this project is

`zig-interval` — a Zig 0.16.0 library package (`zig_interval`) doing **rigorous
interval arithmetic** over `f64`.

The central claim, which everything else serves: **every operation returns a
result guaranteed to contain the true mathematical answer.** Not approximately —
*guaranteed*. If a result can be too narrow, the library is actively dangerous to
a caller doing verification, so this constraint outranks performance at every
decision point in this document.

The guarantee is obtained by computing with IEEE round-to-nearest and then
widening each endpoint outward. Zig 0.16 has no directed rounding, so the
widening helpers in `src/rounding.zig` do it with `u64` bit-pattern stepping.

Source layout, 4,179 lines under `src/`:

| File | Lines | Contents |
| --- | --- | --- |
| `src/interval.zig` | 1,008 | `Interval{lo,hi}`: 28 public operations, 8 of them arithmetic |
| `src/interval_ext.zig` | 628 | 28 elementary functions, free functions |
| `src/vector.zig` | 807 | `Vec(n)` (compile-time dim) and `DynVec` (runtime dim) boxes |
| `src/lp.zig` | 1,294 | Fourier–Motzkin solver with Tupper's variable ordering |
| `src/rounding.zig` | 218 | outward-rounding primitives, certified pi enclosure |
| `src/root.zig` | 224 | public module root; enumerates the whole surface name by name |

28 plus 28 is the **56 public operations** of the audit's own set, and it is the
denominator every coverage number in this document is a fraction of: 28 methods
on `Interval` and 28 free functions in `src/interval_ext.zig`. The `Op` enum in
`tests/soundness_shared.zig` names **35** of them — all 28 of the audit-set
methods plus seven free functions — and the remaining **21** are covered by the
corpus tier instead, so `35 + 21 = 56` with no remainder. Count it from the enum
and the two source files, not from this document. Two things that count is not:
the tree publishes **three more** public methods since the audit (`Interval.halve`,
`Interval.signOf`, `Interval.zeroSplit`), and neither tier proves every input of
every operation — the oracle asserts containment on drawn and directed cases, the
corpus on the rows it carries. Line counts drift; re-run `wc -l src/*.zig` rather
than trusting the table above, and read the code when the two disagree.

Consumers import the package as `@import("interval")`.

## 2. Where the work stands right now

Steps 1 to 5 ran to completion, a second optimisation round ran on top of them,
and the soundness oracle was extended from 8 covered operations to 35. Nothing
in this section is a plan. The other document is `docs/next-work-plan.md`, and at
this revision it carries **no open item** — every defect row reads FIXED and every
optimisation is answered, landed or refused; this file records what was done, what
it bought, what was measured away, and what was tried and thrown out.

### Verified tree state — 2026-09-30, re-verified since

| Fact | How it was checked |
| --- | --- |
| `zig build test` exits 0 in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall, each ending `readme examples ok: 31 checks`. The fixture's first consumer prints `consumer ok: 29 checks` immediately before it, and the README's examples are wired second so the log stays in the order the README states them | run, all four modes |
| The soundness oracle reports `0 FAILED` on every operation it covers — 35 of them — and 348 tests pass across the eleven test artifacts | run |
| The MPFR corpus tier reports **1886 rows checked, 0 FAILED**, in each of the four modes, of which **427 are exactly representable**. It is the only reference in the tree that was not written in the tree: `scripts/gen_corpus.c` calls MPFR at 256 bits twice per row, once `RNDD` and once `RNDU`, and the output is committed as `tests/corpus/elementary.txt`. 1813 of the rows carry the 21 operations the in-tree oracle does not judge, and 73 more carry `sqrt`, `cbrt` and `tanh`, which it does — external corroboration, not new coverage. Together with the oracle's 35 that is the whole 56-operation audit set, twice over on those three | run; the row count and that split read out of `tests/corpus/elementary.txt` |
| `8 of 8` operations named by the NaN contract trap on a NaN scalar, and every well-formed control comes back clean | run, each in a child process |
| The oracle is four sibling test binaries over one shared module, `tests/soundness_shared.zig`, and the LP exact block is its own module, `src/lp_exact.zig`, tested by `tests/lp_exact_test.zig`. The four are siblings over one vocabulary rather than a chain because `zig test` collects the tests of every file a binary reaches, imported or not, so a chain would run the shared file's tests a second time | counted from `build.zig` and the `tests/` tree; the extraction is proved by `probe/lp_exact.zig` failing to compile |
| `zig build bench` completes; `bench-lp` is bounded by the 20,000-row budget and its run reports 18.5 s. Both numbers are the 2026-09-30 capture and **neither has been re-measured since**; what has been re-run is the step, one benchmark at a time, and each exits 0 — and all three ran to completion nine more times on 2026-10-02, which produced the current three-run baseline in its own section below and left both numbers above exactly as they are | run |
| `zig fmt --check` clean | run |
| `zig build docs` green | run |
| All 20 Linux targets with a local runner build **and run** the whole test step — corpus tier included, 0 FAILED — under QEMU user-mode (native for `x86_64-linux`), **348/348 on each, 6,960 tests total**: `x86_64-linux`, `x86_64` 32-bit, `aarch64` and big-endian `aarch64_be`, 32-bit `arm` both endians, `hexagon`, `loongarch64`, `mips` 32/64-bit both endians, `powerpc` 32/64-bit both endians plus little-endian 64-bit, `riscv32`, `riscv64`, big-endian `s390x`, and `thumb` both endians. Byte-order coverage is therefore four targets wide (`s390x-linux`, `aarch64_be-linux`, `armeb-linux`, `thumbeb-linux`), not one: the oracle's `u64` bit-pattern stepping in `src/rounding.zig` and the NaN contract trap's pattern reads run green on all four. Reproduce with `cross-test --targets '<the 20 names>' --jobs 4 --build-jobs 1 --timeout 900 --build-timeout 900 --output <dir>` (see the release-sweep recipe in `cross-test.profile.sh`) | run, `cross-test --targets '<the 20 names>'` at `--timeout 900 --build-timeout 900` (see the release-sweep recipe in `cross-test.profile.sh:200-203`); the per-target table for the sweep is the gate cross-target table below plus the four big-endian rows named in this row |
| `x86_64-windows` builds and is **not run**: there is no wine available, so the test step's binaries cannot execute there, and `cross-test` records the target `build_only`, `runtime_unavailable`. "Builds" is the whole of the claim. The suite is **not** evidenced on Windows and this row must not be read as "the tests pass there" | run, `cross-test` |
| `bench-lp`'s geometry report is byte-identical to the capture from before the optimisations, and predicted == achieved on every branch | run |
| Everything this document records is committed, not left uncommitted — and the tip is a query rather than an id written here, because an id in this file goes stale at the next commit and this file is in the next commit. `jj status` names the working-copy commit and anything uncommitted in front of it, `jj log -r main` and `jj log -r main@origin` say whether the bookmark and its remote agree, and `jj diff --stat` says what is in that commit. A working-copy commit sitting above `main` is work in flight, not lost work. The `ns/op` figures below carry the 2026-09-30 capture date this file dates them with, not a commit id | `jj status`, `jj log -r main` |

Two of those lines want a reader's attention. The geometry report being
byte-identical is what makes every LP number in this document trustworthy: it
says the optimisations changed what the solver **pays**, not what it computes.
And the windows row is the one most easily over-read, because compilation is
not execution and where there is no runner it is the whole of what that target can be.

The cross-target rows have a section of their own below, carrying the
per-target 348/348 counts, the byte-order point, and the one entry in this
table a later session is most likely to mistake for a defect.

**What has moved cost since, in words because the numbers must not move.** O2
in `docs/next-work-plan.md` gave `box` one shared elimination walk in place of
`m` private sweeps. It altered the elimination COUNT — roughly half as many
eliminations — and it raised peak memory, because the walk holds a chain and
one copy alive together where the old form held one. The geometry report row
above is unaffected, and the reason is what that report prints: bounded or
unbounded, and nothing else. **No `ns/op` figure in this section or in section 3
has been re-measured since 2026-09-30, and none is claimed to have been.** All
three benchmarks ran to completion again on 2026-10-02, and the gate receipt
below records that completion while saying plainly that the numbers that run
printed are not adopted: so every table here stays the 2026-09-30 capture.
**The current measured baseline is a separate, separately dated 2026-10-02
capture in its own section below, published as its own file**; it replaces
nothing here, and the two dates are not a before/after pair, because this
document's tables were taken on an idle machine and the current capture was
taken on an unpinned shared one.

**The four-mode run is no longer outstanding.** It was re-run after every
commit since the measurement, one mode at a time, at the tip named in the last
row: `zig build test` exit 0 in all four, the oracle at `0 FAILED` on all 35
operations, the corpus tier at 1886 rows and 0 FAILED, and `zig build docs` and
`zig fmt --check` both green. The whole suite, all four modes and the cross
matrix, then ran once more on the stable tree on 2026-10-02 and is written down
in the gate section below. That is a completion record: the numbers the
benchmark run printed were measured while the rest of the verification was
running alongside them, so they are not a trustworthy refreshed performance
baseline and are not adopted as the baseline here — a figure that moves
because nobody re-measured it is worse than a figure carrying its date.

A second gate run on the same date, this time out of an installed prefix, is
**red** and has its own subsection below. It does not retract the one above,
whose tools were resolved out of a home directory rather than out of a prefix,
and neither of them refreshed a figure.

**And the other cost question since, the priority 1 infinity contract.** The
constructor now compares and selects on two endpoints, `scale` has one extra
branch on the unbounded path only, and `expand` and `translate` read an infinite
scalar as a ray rather than as a number. None of it changes what any finite
answer is, so no `ns/op` figure here is invalidated by it — but the constructor
comparison is on every construction, and whether that is free is a measurement
rather than an assertion. Re-run `zig build bench` with it before quoting a
figure as unchanged.

**Why the width changed, in one line.** `tanh` at
`x = 0.23139395412799124` returned an enclosure that EXCLUDED the true value,
because the `std.math` primitive reaches 2.14 ULP and a two-step widening
brings the bound back to the correctly rounded `f64` and stops. It is D17 in
`docs/next-work-plan.md`; the defect, its witness, and the trap every test for it
has to avoid — the nearest `f64` to the true value IS the bound the old code
returned, so a reference rounded to `f64` reports the defect as sound — are in
§2 of `docs/tests-and-architecture-plan.md`.

### The gate — `.vf/gates.yml`, installed from this repository

**The policy is a file; the command behind it is now in this repository.**
`.vf/gates.yml` installs the gate from `tools/quality/` and runs it out of the
prefix it wrote:

```yaml
suite-install: bash scripts/install-quality-tools.sh --prefix "$QUALITY_TOOLS_PREFIX" --work-root "$QUALITY_TOOLS_WORK_ROOT" --zig "$ZIG"
suite-cmd: ZIG_GATE_PREFIX="$QUALITY_TOOLS_PREFIX" "$QUALITY_TOOLS_PREFIX/bin/zig-gate"
suite-timeout: 3600
enforce: true
```

`suite-cmd` is what a cold session runs, and it is an **absolute path into the
prefix** with `ZIG_GATE_PREFIX` bound to the same prefix, not a bare
`zig-gate`. That is the whole point of the arrangement: a bare name resolves
through `PATH` and, failing that, through `$HOME/.local/bin`, so the gate a cold
session ran would be whatever binaries happened to be on that machine's disk —
and a gate that resolves its analysers from `PATH` reports findings about
whatever analysers that shell had. `suite-install` refuses to run at all unless
all three variables are set, so an unset one stops the suite with a message
rather than falling back to a default path or to `$HOME`. `suite-timeout` is
3600 s because the cross section of that command builds the suite for all five
of `cross-test.profile.sh`'s targets and runs four of them — one natively, three
under QEMU — which takes tens of minutes on its own. `enforce: true` makes a
non-zero exit a red gate rather than a report. The other keys —
`target-cmd: zig 0.16.0 build test`, `test-paths` — are harness plumbing and
state no policy of this project's. README's Development section is the
consumer-facing statement of the same gate; this is the session-facing one.

Three variables carry the environment, and they are the same three the install
needs:

| Variable | What it is |
| --- | --- |
| `QUALITY_TOOLS_PREFIX` | the prefix the installer writes and the gate runs from |
| `QUALITY_TOOLS_WORK_ROOT` | the installer's own fetch/patch/build/cache root |
| `ZIG` | an absolute path to a real Zig 0.16.0 |

All three must be absolute, and the first two must also be local, writable and
owned by the caller — on a machine that publishes an approved scratch list, a
per-user directory on one of its approved volumes, and on a runner any owned
local path including `/tmp`. A session that runs the
suite by hand sets the same three and calls the same two commands. Both keys
guard themselves against an unset variable: `suite-install` exits 2 with a
message naming all three, and `suite-cmd` exits 2 rather than run a gate that
was never installed, so neither falls back to a default path or to `$HOME`.

**`.vf/gates.yml` names no scratch or cache roots at all.** There is no `env:`
key in it, so `GATE_SCRATCH`, `GATE_CACHE_DIR`, `GATE_GLOBAL_CACHE_DIR` and
`GATE_CROSS_OUTPUT` are whatever the operator exports: on a machine that
publishes an approved scratch list the scratch contract selects a sanctioned
local root itself, and anywhere else they must be named explicitly. Only
`.github/workflows/ci.yml` sets those four, per job. `ZIG_GATE_PREFIX` is set
*inside* `suite-cmd` rather than through an `env:` key, deliberately — the
command does not depend on the runner supporting one.

**One assumption, stated rather than hidden: both keys are POSIX shell.** There
is no `vf` binary to confirm that, so whether the runner executes these values
through a shell is unverified. They are written as shell because
that is what a shell-executing runner needs. If a runner splits the value on
whitespace without a shell, neither key can work — and that is a runner-side
finding to report, not something to paper over by shortening the command.

**Installing it is one command, and its interface is the contract.**

```sh
. scripts/scratch.sh || exit 1
scratch_init quality-build || exit 1   # a local root the contract approved
export QUALITY_TOOLS_WORK_ROOT="$SCRATCH_DIR"
export QUALITY_TOOLS_PREFIX="$SCRATCH_ROOT/quality-tools"
export ZIG="$(zig 0.16.0 env | awk -F '"' '/\.zig_exe =/ {print $2; exit}')"

bash scripts/install-quality-tools.sh \
  --prefix "$QUALITY_TOOLS_PREFIX" \
  --work-root "$QUALITY_TOOLS_WORK_ROOT" \
  --zig "$ZIG"
```

`--prefix`, `--work-root` and `--zig` are required and must be absolute; the
compiler must report exactly 0.16.0, which is why a version shim on `PATH` will
not do. `--only LIST` takes `zbc`, `ziglint`, `zlint`, `zwanzig`, `cross-test`,
`zig-gate`, `harness`, `analyzers` or `all`; `--manifest PATH` reads an
alternative source manifest; `--optimize MODE` selects the build mode
(`ReleaseFast` by default); `--list` and `--help` print the resolved plan;
`--verify-only` verifies the checked-in hashes, creates nothing, and stops —
the two subjects it covers and the one it does not are spelled out below;
`--force` overwrites an existing prefix. Exit status is 0, 1 for a build or
install failure, and 2 for a usage error, a missing prerequisite, an unparseable
manifest or a checksum mismatch, with 130/143/129 propagated from a signal.

**What a failed install leaves behind is narrower than "nothing half-written",
and the distinction is load-bearing.** Every usage, prerequisite, manifest and
checksum check completes *before anything is created at all*, so a malformed
manifest or a refused path leaves the filesystem untouched. After that the
installer creates **both** roots early — the work root first, then an empty
prefix — and does the real work in a staging tree under
`$QUALITY_TOOLS_WORK_ROOT/stage/prefix`. The prefix is populated by one copy at
the very end, after every payload file has been hashed. The manifest cannot hash itself.
So a build that fails an hour in leaves the **work root** behind — fetched
sources, stamps, build logs, which is exactly what makes the next run cheap —
and leaves the **prefix** empty; when that prefix was empty when the run
started, the installer removes it and says so. **A cold install ends either
with a complete prefix or with no prefix**, and a failed install is *not* an
install that wrote nothing. A `--force` install over a prefix that already
existed is *not* transactional: files already replaced stay replaced and the
diagnostic names where it stopped. Do not write either claim looser than that.

**`--verify-only` and "is the installed prefix intact" are different questions,
and the flag answers only the first.** It hashes `tools/quality/` against
`SHA256SUMS` — including the check that no file under `tools/quality/` is
missing from that listing — prints the plan, and exits before either root is
created. It never opens `$QUALITY_TOOLS_PREFIX`, neither named path has to
exist, and neither has to be a legal scratch location for that run. So a green
`--verify-only` is a statement about the **checked-in distribution this tree
holds**, and nothing whatsoever about what an install put in a prefix. The
second question has its own answer: every row of the installed
`install-manifest.tsv` records the sha256 of the file it names, so a prefix is
re-verified byte for byte with

```sh
( cd "$QUALITY_TOOLS_PREFIX" \
    && awk -F'\t' '!/^#/ && NF { print $8 "  " $7 }' install-manifest.tsv \
    | sha256sum --check --strict - )
```

`--strict` is what makes a **missing** file a failure rather than a skip, so a
truncated or deleted binary cannot pass by being absent. The `analyze` job runs
both — the dry source verification first, this loop second — because neither
one substitutes for the other.

**The manifest is strict about its own shape, and a malformed row is a usage
error rather than a shifted column.** A row must carry all fourteen
tab-separated columns and none of them may be empty; `-` is how a value says
"does not apply". Tab is an IFS whitespace character, so a parser that splits
on it the obvious way collapses runs of tabs — an interior empty column would
shift every column after it and turn the post-build artifact lookup into a
filename that cannot exist. That is a confusing failure for a plainly malformed
input, so the installer splits exactly and rejects anything else with exit 2.

**What the work root's reuse check actually verifies, in four facts, because
"the work root is cacheable" is otherwise a claim with no content.** A stamp is a
claim about itself, so the first three facts are **bindings** and only the
fourth takes the stamp's own value as an expectation. A restored checkout is
reused only when all four hold: the stamp's recorded revision, its ordered patch
hashes and its `src/**/*.zig` source digest are the ones **this run's manifest
row** lists; and then, re-derived from disk rather than read back, the
checked-out commit is that bound revision, the `src/**/*.zig` digest computed
fresh is that bound digest, and **the digest of the build inputs still matches
what the stamp recorded** for them.

Neither half of that was there at the start, and the binding is the one that is
easy to mistake for a formality. Without it, a tool carrying **no patches** —
`zlint` — whose pin later moves to a new revision keeps a stamp that agrees with
its own checkout perfectly, so the old tree is reused and built as though it were
the new pin. A stamp that is internally consistent is not evidence of which tree
it is about. Without the build-input digest, a cache restore carrying an edited
`build.zig` or `build.zig.zon` passed every check and then ran unpinned build
code with the pinned sources as its input. The hashed set is exactly `build.zig`
and `build.zig.zon` where present, every path `build.zig` pulls in with
`@embedFile` (an embedded file is build input, and its contents reach the build
without touching `src/`), and every regular file at the top level of the
checkout — which is what covers a tool whose build is named `Cargo.toml` or
`package.json` instead. Cost is a handful of sha256sums, not a tree walk.

Two consequences worth knowing. A **stamp written before the fourth field existed has
none**, and that is a non-match rather than a pass: the answer is a fresh fetch,
which costs one network round trip and is the only outcome that cannot be wrong.
A stamp written before the binding existed fails the same way, for the same
reason. And this is a *reuse* check, distinct from the two integrity checks
above: it decides whether to re-fetch, and it says nothing about the prefix,
which is what `install-manifest.tsv` is for.

**Each analyzer is built by a named recipe, and one of the four is not built
like the other three.** `manifest.tsv`'s `build_recipe` column carries a NAME —
`default` (the tool's own default step) or `cli` (its named install-only step) —
and the installer dispatches it from a fixed table. It is never eval'd, never
expanded and never run as a command; a name outside that table is exit 2 before
anything is fetched, never a fallback to `zig build`, because the binary that
reached the prefix would then be one nothing in the distribution describes.
`ziglint`, `zlint` and `zwanzig` are `default`. **`zbc` is `cli`** — built with
`zig build cli`.

The reason is zbc's own build script. Its `build.zig` leaves upstream's dogfood
on the **default** step — `self_check.addDirectoryArg(b.path("src/"))` plus
`b.default_step.dependOn(&self_check.step)`, i.e. `zbc src/` over zbc's own
`src/`, with a CLI that returns 1 on *any* finding. The measured `0001`–`0003`
tree reported **75 findings about itself**
(`selected=153 analyzed=153 failed=0 findings=75`), exit 1. No self-run over
current `0001`–`0005` exists; the shipped tree's count is unknown.
`cli` builds and installs the same `zig-out/bin/zbc` without running the
self-check.

**The dogfood is not removed, weakened or re-severitised**:
`b.default_step.dependOn(&self_check.step)` is upstream's line and is untouched,
and the default step keeps the artifact-install dependency upstream gave it —
the equality after the reviewed patch is in the *step graph*, not in the file
bytes, because the default step now has a named sibling pointing at the same
install-artifact node. No rule, severity or finding is suppressed, lowered or
excluded anywhere to get a binary installed.

**The honest width of that claim, because it is easy to read wider.** The
install proves the pinned tree **compiles, links and installs**. It says nothing
about whether `zbc` finds anything in `zbc`. What the gate asserts about
findings is a run over *this* project's sources. The dated self-analysis is
recorded in `tools/quality/PROVENANCE.md`; it does not establish the current
tool's self-findings. Fixing upstream's findings is outside this project.
The historical red project gate reported four errors and three warnings
(`selected=32 analyzed=32 failed=0 findings=7`). The reviewed green gate below
reported zero errors and the three standing warnings. Neither is a tool
self-dogfood result. The argv that each install actually ran — step and
optimize mode together, e.g. `zig build cli -Doptimize=ReleaseFast` — is
recorded per install in `install-manifest.tsv` and read back by the `analyze`
job, which is where a reader should look rather than at this paragraph.

**A cold install from empty caches HAS now been captured and dated for this
file, on 2026-10-02 — see "The cold install and the first prefix-only gate run"
below.** Everything else this section states about the distribution is still the
interface and the checked-in pins, read out of the installer and
`tools/quality/`; the receipt is a single dated run, so it dates what it
measured and nothing else. Its logs belong beside the prefix's
`install-manifest.tsv`, and a later session's own install is its own receipt to
write down, not a reason to overwrite this one.

**What lands in the prefix:**

| Under `$QUALITY_TOOLS_PREFIX` | Contents |
| --- | --- |
| `bin/` | `zig-gate`, `cross-test`, `ziglint`, `zlint`, `zbc`, `zwanzig` |
| `lib/cross-test/` | `test.sh`, `test-zig.sh`, `run_policy.zig`, `zig-targets.sh`, `scratch-contract.sh` |
| `share/zig-interval-quality/` | the resolved `manifest.tsv`, `SHA256SUMS`, `PROVENANCE.md`, `licenses/`, `patches/` |
| `install-manifest.tsv` | pins, licences and hashes for every payload file, including patches. This manifest does not hash itself. |

`zig-cov` is deliberately **not** in `bin/`: the coverage section is opt-in
behind `--cov` and reports the tool as skipped when it is absent, so an installed
prefix is complete without it.

**Licence is recorded per file, and the harness's own notice ships with it.**
`bin/` and `lib/cross-test/` are first-party code from this repository, so they
travel under this repository's MIT — `tools/quality/licenses/harness.LICENSE`,
a verbatim copy of the root `LICENSE` — installed beside them as
`share/zig-interval-quality/licenses/harness.LICENSE`. The four analysers keep
their own upstream notices as `licenses/{zbc,ziglint,zlint,zwanzig}.LICENSE`,
retained verbatim, and `run_policy.zig` and the other helpers are **not** a
third-party helper with no notice: they are part of the harness, so the
harness's notice is theirs. A harness install with no `harness.LICENSE` to ship
is refused (exit 2) rather than shipped unlabelled, and no third-party code is
attributed to anyone other than its own authors.

**The pins, and why `zwanzig`'s base revision is not the tip.** The upstream
revisions are full 40-hex commits, re-checked after a `--depth 1` fetch with
`git rev-parse FETCH_HEAD`, so a pin is content rather than a movable tag:

| Tool | Upstream | Pinned revision |
| --- | --- | --- |
| `zbc` | `ericsssan/zbc` | `419d153ca411d1698899992d86c51eb9a7e14919` |
| `ziglint` | `rockorager/ziglint` | `66709a408f2ea9ac1de91a438a83b13f4691a941` |
| `zlint` | `DonIsaac/zlint` | `3ef67af7dfed776cb03012563942cdf3a97f1b59` |
| `zwanzig` | `forketyfork/zwanzig` | `1a0768ccd889d3586ec9482f02ffffe872a99749` |

`zwanzig` carries five further local commits and one uncommitted working tree
above `1a0768c…`, and they travel as an ordered, individually hashed patch
series under `tools/quality/patches/zwanzig/` — one file per commit, plus
`0006-uncommitted`. Those local commits are in no origin ref upstream, which is
exactly why the base is the last published revision and not the tip of the local
series. One reading trap: the installed `zlint` prints `v0.0.0` for `--version`,
which is upstream's own default for a source build and not a version marker that
could have drifted.

**What "captured" means for the patch series, stated precisely, because the
upstream base is not always re-fetchable.** For `zwanzig`'s five local commits
the base revision is fetchable, but the five commits are not: they exist in no
origin ref, so the only durable form of them is the checked-in patch file. So
there are two different kinds of evidence here and they are not
interchangeable. The **identity** evidence is hash-based and complete: every
patch carries its sha256 in `tools/quality/manifest.tsv`, the installer verifies
each one *before* applying it and refuses a build on a mismatch, and every file
under `tools/quality/` is listed in `tools/quality/SHA256SUMS` and verified
before an install runs. That is what makes "this is the tree that was reviewed"
a checkable statement. The **instant** evidence is weaker and is stated here so
nobody reads more into it than it carries: a manifest declares one capture
instant for the working-tree patches, and individual patch headers record the
instant **of their own capture where they record one at all** — some carry a
full timestamp, some only a date, and some carry none. `tools/quality/PROVENANCE.md`
is where the instants are reconciled per patch; this file deliberately does not
restate them, because a second list would be one more thing to drift. What this
file claims is only that each patch's bytes are hash-pinned; if you need to know
*when* a given patch was taken, read that patch's header and PROVENANCE.md, not
this paragraph.

**The sections, in order:** `zig fmt --check`, `zig build`, `zig build test`,
`zig ast-check` over the project file list, then `ziglint`, `zlint -S`, `zbc`,
`zwanzig`, then `cross-test`. A coverage section is opt-in and off unless
`--cov` is passed. The order matters less than these four rules.

- **Every analyser is required, and a missing one FAILS.** `ziglint`, `zlint`,
  `zbc`, `zwanzig` and `cross-test` resolve as `$QUALITY_TOOLS_PREFIX/bin/<name>`
  and to nothing else — no `$HOME/.local/bin` lookup and no `PATH` fallback —
  and a missing one is exit 2 before any project check runs, naming every absent
  analyser at once. The cross section additionally fails when the project's
  `./cross-test.profile.sh` (or `./test/cross-test.profile.sh`) is missing. A
  quieter gate is not a gate. An explicit `ZIGLINT` / `ZLINT` / `ZBC` /
  `ZWANZIG` / `CROSS_TEST` override still wins, because that is the operator
  naming a tool deliberately.
- **ziglint, zlint and zwanzig assert every finding, with nothing excluded.**
  This project configures no `ZIGLINT_ARGS`, no `ZLINT_ARGS` and no
  `ZWANZIG_ARGS`, so there is no suppression and no `--ignore` anywhere in the
  policy. In particular the two zwanzig families that would be easiest
  to quiet — optional unwrapping and identifier style — are answered in `src/`,
  not filtered out of the report. **A new finding gets a fix in the source. Do
  not add an exclusion to make it go away.**
- **zbc splits by severity, and the policy is that, not a list.** Any
  `error(...)` fails; a `warning` is advisory; `ZBC_STRICT=1` is the single knob
  that makes warnings fail as well. Every finding is printed by rule and no
  rule is disabled to make this tree quiet. **There is no whitelist of
  permitted findings, no per-rule exception list and no file/line carve-out**
  — so this gate does not promise that some fixed set of warnings is tolerated,
  and a later session should not write it down as if it did.

  What is expected on **this** tree: three reviewed zbc warnings — the
  float-to-integer conversions without a clamp — each read and answered with the
  range proofs README's Development section names, `criticalRange` in
  `src/interval_ext.zig` and `expRef` in `tests/soundness_shared.zig`. Those
  three stay advisory.

  **And the thing a later session most needs not to assume: this is not a
  warning-only run.** An `error` from *any* zbc rule fails acceptance, and that
  now includes the six rules the pinned source carries at upstream severity —
  `memset_undef_after_len_truncation`, `f32_narrowing_int_to_float`,
  `index_minus_one_without_zero_guard`, `index_type_narrowing_wraparound`,
  `intcast_of_negated_signed` and `midpoint_addition_overflow`. Those six were
  downgraded to `.warning` by an unreviewed capture and have been restored to
  upstream's `.@"error"` on purpose, so a run against the restored pinned
  source can legitimately go red on them.

  The seventh rule those captures touched, `intfromfloat_without_clamp`, is the
  single exception: it stays `.warning` by accepted, reviewed policy rather than
  by upstream default, and it is the rule behind the three warnings named above.

  `index-type-narrowing-wraparound` and
  `intcast-of-negated-signed` are exactly the shapes a numerical library of
  this kind hits. As an instance of the *shape*: a ReleaseFast build of the
  patched **analyzer** — a plain `zig build` inside the zbc checkout with the
  pinned patch series applied, running upstream's dogfood over its own source
  with `zbc src/` — reported
  `index-type-narrowing-wraparound` findings in the analyzer's own
  `src/type_engine/segmented_list.zig`. **That path belongs to the pinned zbc
  tree, not to this repository**, which has no `src/type_engine/` at all; it is
  shown as evidence of the shape of finding these rules produce, not as a
  finding here. Whether zig-interval trips them is a separate question this file
  does not answer. **The remedy for any of them is a fix in `src/`, never a
  severity edit in the patch**, and a red analyze job on one of these rules is
  the gate working, not the gate misfiring. Nothing here claims such a fix has
  been made.

  The other limit, stated rather than papered over: with `ZBC_STRICT` unset a
  *fourth warning* would print and would not fail the run. That is why the
  per-rule histograms the gate prints are the artefact to read, and why setting
  `ZBC_STRICT=1` is the right move the moment a new warning appears that nobody
  has read. Changing interval arithmetic to satisfy a caller-insensitive
  analysis is not the alternative.
- **One explicit file list feeds every source section, and it drops cache and
  output trees at ANY depth.** `zig-gate` builds it with `find . -name '*.zig'`
  minus `vk.zig`, `zig-pkg/` and four top-level trees, then removes
  `GATE_EXCLUDE` — default `/[.]zig-cache/ /zig-out/ /zig-cache/
  /zig-global-cache/` — one `grep -v` pattern each. Depth is the whole point:
  the nested consumer build used to write `fixture/.zig-cache` INSIDE this
  repository, top-level-only exclusions never matched it, and the fmt and lint
  sections duly reported Zig's own generated `builtin.zig` and
  `dependencies.zig` as defects. Those counts were a function of build state,
  not source state. zwanzig is handed the same explicit list for the same
  reason: it reads no ignore file and skips only four directory names of its
  own, none of them `.zig-cache`, so a bare `.` would make its findings depend
  on what the last build left behind.

**cross-test fails closed, and `partial` is not `pass`.** A non-zero exit, a
missing `fail=` count on the `status=` line, and any status word the gate does
not recognise each fail the section. `status=partial` or `status=build_only`
with `fail=0` passes, and that is the normal clean result wherever
`x86_64-windows` has no runner. So **`build_only` on Windows means
the library compiles and nothing else**: it is not "the tests pass on Windows",
and no row of this document may be read that way. On `status=fail` the gate
opens that run's own per-target build logs and says which it found — `timed
out` is a budget, anything else is a real failing assertion — instead of
reporting a run that lost one test as a broken suite.

**What a green cross row covers is declared at RUN TIME, in a file, and that is
the shape to keep.** `cross-test.profile.sh` sits in the repository root, and
`cross-test` **sources** it as trusted bash at the start of every run — its own
process and every per-target worker — rather than reading a target list from a
flag, an environment variable or a compiled-in table. So the coverage a green
run claims is whatever that file declares at the moment it runs, and quoting a
"five targets" figure without quoting the file is quoting a number with no
source. Three things follow, and all three are deliberate:

- **The file is the contract, and it is read rather than restated.** `zig-gate`
  section 9 requires it to exist and fails the section when it is missing, so a
  deleted profile is a red gate rather than a silent drop to fewer targets. The
  `cross` job in CI goes one step further and *compares*: its guard step sources
  the same file and requires its `TARGETS`, its `CROSS_TIMEOUT` and the
  concurrency the harness will resolve to be the ones CI names, so adding or
  dropping a target turns the job red until the two lists agree on purpose. That
  is the difference between a coverage claim that is checked and one that is
  remembered.
- **A target can be declared REQUIRED, and that is what turns "it compiled"
  into "it ran".** The profile carries one extra single-line declaration beside
  `TARGETS`:

  ```sh
  CROSS_REQUIRED_RUN_TARGETS='x86_64-linux aarch64-linux riscv64-linux s390x-linux'
  ```

  One assignment, one line, single-quoted, space-separated, no array and no
  continuation — the last assignment wins, exactly as bash does, and a
  commented-out line never matches. `x86_64-windows` is deliberately **not** in
  it: on a host with no wine that row is compile coverage, and listing it would
  be asking for a pass that cannot exist. The installed `zig-gate` never sources
  the profile — it extracts the declaration with `sed`, strips one optional pair
  of quotes, validates every token against cross-test's own target pattern (a
  bad token fails the section *before* the run, naming the file and the token),
  binds its own `CROSS_RUN_ID`, and then reads only
  `$GATE_CROSS_OUTPUT/runs/$CROSS_RUN_ID/summary.json` — never "whichever run is
  newest". For each required target it demands `build.status=pass`,
  `run.status=pass`, `status=pass` and `run.tests > 0`, straight out of
  cross-test's own classification. A missing row, a `build_only`, a zero test
  count, an unfinished run, `bookkeeping_failure`, malformed JSON or a missing
  file all fail the section. A profile that declares nothing keeps exactly the
  previous reporting, and `python3` is required only when something is
  declared.
- **Concurrency is pinned, not inherited.** `cross-test` resolves target and
  build concurrency from CLI flags, then the profile, then `MAX_JOBS` /
  `ZIG_JOBS`, then its own defaults. The profile sets `CROSS_JOBS=2` and
  `CROSS_BUILD_JOBS=1` explicitly, **and** CI's guard step asserts the value the
  harness will actually resolve to, **and** the job environment empties both
  ambient names on purpose. Any one of those alone would have been enough to
  catch an inherited `MAX_JOBS`; all three together mean the failure surfaces in
  the guard step instead of hours later in the summary's `target_jobs` field —
  which is a two-hour failure to learn that an environment variable was set.
- **A row's verdict is the harness's, and the sentence describing it follows the
  row.** CI asserts the per-target verdicts (build, run status, executed-test
  count) and prints what the Windows row actually said: compile-only coverage
  when it says `build_only`, and a runtime pass with its test count when it says
  `pass`. A fixed "Windows is compile-only" sentence would have been a lie the
  day a runner appeared, and would have understated the coverage rather than
  overstated it — which is the direction that hides work.

None of this changes the numbers in this document. The 2026-10-01 run behind the
cross rows below was made against the profile as it stood then, and every
per-target count quoted here came from that run's own `summary.json`.

**One tool correction, and it is in this repository's distribution now.**
`ziglint`'s Z030 rule did not recognise a typed slice range written `[0..0]`, so
the idiomatic empty-slice form in `src/vector.zig` was reported as something it
is not. The correction was made in the tool's own source and is now a
reviewed patch in the tree: `tools/quality/patches/ziglint/0001-Z030-deinit-destroys-self.patch`,
sha256-listed in `tools/quality/manifest.tsv` and applied by the installer on
top of the pinned revision `66709a408f2ea9ac1de91a438a83b13f4691a941`. It
recognises the typed-slice form and leaves `DynVec`'s existing idempotent
`deinit` exactly as it was: no value was poisoned to silence a rule, no public
symbol was renamed, no rule was disabled. What that work observed was the tool's
own suite and not this project's: the focused regression red at 41 of 42 and then
green at 42 of 42, the tool's full test run 314 of 314, and then a clean run of
the corrected `ziglint` over this project.

**Those figures are 2026-10-02 and are HISTORICAL.** They describe the tool's
own suite, not a gate run of this tree, and this file adopts none of them as a
current measurement. What has changed since is where the fix lives, not whether
it was real: it is a pinned, hashed patch in `tools/quality/`, so a clone that
installs the prefix gets the corrected `ziglint` rather than whatever an
installer's build happened to produce. It is still not published upstream, so
the pin is the only reason the corrected rule is available here.

**A green gate reports what it ran, and nothing more.** The last of the
prefix-only receipts is the one that counts, and what it established is durable
rather than dated: the whole gate — `zig fmt --check` through the cross-target
section — green with its analysers resolved inside the prefix, `policy=builtin`,
and no `$HOME` or `PATH` lookup; `zbc` over this tree at `selected=32
analyzed=32 failed=0 errors=0` with the **3** standing
`intfromfloat-without-clamp` advisories and nothing else; and a cross section
read from the immutable run directory of its own run rather than from a rolling
summary, reporting `pass 4, fail 0, build_only 1, partial 0`, `status=partial`,
exit 0, **348** tests on each of the four targets that executed and **1392**
executed tests in all, with `x86_64-windows` compiled and never run.

**How to read a cross row, because `partial` is not a defect.** A clean run
reports `partial` precisely because one row is compile-only, and it still exits
0. Read the counts out of a run's own `summary.json` and never out of the
rolling `cross-test-summary.json`: cross-test rewrites that file as a run
progresses and completes, so it can describe an in-flight run and otherwise
reports whatever ran **latest**. It is not immutable, and it is not the receipt
for an earlier one. The gate binds its own `CROSS_RUN_ID` and reads that run's
directory; it never asks for "whichever run is newest".

**A red gate over an unchanged tree is an analyzer finding, not a verdict on
the source.** The first prefix-only run was red on `ziglint` style findings in
`bench/bench_lp.zig` and on `use-undefined` **errors** in
`bench/bench_vec.zig`, whose arrays are fully initialised at comptime. The
working attribution was the pinned analyzer's `for`-range CFG lowering, which
builds a zero-trip path for a statically nonempty iterable. It was resolved by a
reviewed source patch to the analyzer and by the style corrections themselves —
**never** by a severity edit, a suppression or an `--ignore` — and the receipt
that followed is what re-installing and re-gating with them produced. The
advisories it also reported were the same three this file has always carried,
which is the observable proof that a freshly built analyzer reproduces them
rather than losing them.

**Two fail-closed proofs, and neither one claims runtime coverage.** The
consumer cache selection was exercised in three configurations — the default, an
explicit relative override, and the parent-cache fallback. The scratch resolver
was probed with an empty, a relative and an NFS provider root, each resolving to
the local volume, plus one isolated case that **fails closed**: a throwaway
`HOME` whose policy does nothing together with a `USER` that does not exist, so
no per-user directory is there and the resolver exits 1 rather than reaching for
`/tmp`. Separately, an empty and a whitespace-only `CROSS_REQUIRED_RUN_TARGETS`
declaration were rejected by the source guard **before** cross-test was invoked.
An accepted empty list proves no runtime coverage whatsoever.

**No `ns/op` figure in this document is refreshed by any of that.** A green gate
reports what it ran; it does not turn the Windows `build_only` into a tested
target, and it says nothing about performance. The gate ran with its default
consumer cache selection, while the native release runs and the benchmark runs
passed **explicit** `--cache-dir` and `--global-cache-dir`. The benchmarks did
emit fresh `ns/op` while the rest of the verification ran alongside them, so
those contended outputs are not a baseline and none was adopted as one.

### The cold install and the first prefix-only gate run — 2026-10-02, and it failed

**This is the first of the two prefix-only receipts, and it is red**; the green
one follows it below. The two commands of section 6, run with three differences
that are the point of the exercise: the prefix and the work root were **fresh** —
neither existed beforehand — and `HOME` was an empty throwaway directory, so
nothing could be resolved out of a developer's home even by accident. Section 6
carries both commands verbatim and needs no host-specific path; a session runs
them with its own three variables.

**The install succeeded, and that is the observable receipt for "no `$HOME`
prerequisite" above.** All four analysers were built from their pinned
revisions in `ReleaseFast` — `zbc` by `zig build cli -Doptimize=ReleaseFast`, and
`ziglint`, `zlint` and `zwanzig` each by `zig build -Doptimize=ReleaseFast` — with
the ordered patch series applied and every patch's sha256 checked before it was.
`HOME` was **still empty** when the install returned. `install-manifest.tsv` then
carried a hash per payload file and re-hashing it with section 6's one-liner
printed `OK` once per file, exit 0; `tools/quality/SHA256SUMS` seals the checked-in
distribution, which is what `--verify-only` checks. **One exception, the only
one: `install-manifest.tsv` does not hash itself.** Every patch row names both
notices its file travels under — the tool's upstream `licenses/<tool>.LICENSE`
and `harness.LICENSE`, this repository's own MIT — because a patched tree is
neither purely upstream nor purely local. Read the current counts out of the
install rather than from a receipt; they move with the distribution.

**The gate failed, and the first line of its log is the wiring claim made
observable** — `analyzers resolved inside prefix … (no HOME or PATH lookup)`,
`policy=builtin`, so with that empty `HOME` the built-in scratch contract applied
and no host-wide policy file was consulted. `zig fmt --check`, `zig build`,
`zig build test` and the `zig ast-check` section were green; `zlint` and
`zwanzig` reported nothing. Two sections did not: `ziglint` on four style
findings in `bench/bench_lp.zig` (one over-long line, three parameter-order
findings), and `zbc` on **4** `use-undefined` **errors** in
`bench/bench_vec.zig`, plus the **3** standing
`intfromfloat-without-clamp` **warnings**.

Those four are **errors**, and under the policy in this section an error from any
rule fails acceptance with nothing whitelisted, no rule disabled and no severity
lowered — that alone ended the run. The three warnings were advisory and failed
nothing, and they are the same three this file has always carried, so the freshly
built analyzer reproduced them rather than losing them.

**Why this run is not a claim about this source, and why it stops at red for
good.** The errors sit in `bench/bench_vec.zig`, whose arrays are fully
initialised at comptime and which this run did not change; the working
attribution is to the pinned analyzer's `for`-range CFG lowering, which builds a
zero-trip path for a statically nonempty iterable. The `zbc` fix that attribution
called for and the four `ziglint` style corrections both landed after it, and the
receipt that follows is what re-installing and re-gating with them produced.
Neither is folded back into the figures above.

**What this run does and does not move.** Its cross section reported
`status=partial pass=4 fail=0 build_only=1`: the four REQUIRED targets —
`x86_64-linux` native, `aarch64-linux`, `riscv64-linux` and `s390x-linux` under
QEMU — each built and ran **348** tests, **1392 executed tests** in all, at the
concurrency this project's own `cross-test.profile.sh` pins (`CROSS_JOBS=2`,
`CROSS_BUILD_JOBS=1`, `CROSS_TIMEOUT=900`, build timeout 900).
`x86_64-windows` built as well, so all five targets compiled, and it did **not**
run: `runtime_unavailable`, `build_only`, compile coverage only, not a tested
target. The cross-target section below stays dated **2026-10-01** and is **not**
replaced by this: it is a second, independent run of the same matrix. **No
`ns/op` figure in this document was refreshed by it.** The install, re-hash, gate
and cross logs live under a scratch root that does not survive the session, which
is why the reproducible form is section 6's commands, not those paths.

### The reviewed install and the green prefix-only gate — 2026-10-02, exit 0

**This is the current status of the installed prefix. It supersedes the red
receipt above, which is HISTORICAL and stays in the record whole.** Same two
commands of section 6 and the same three-variable discipline, with two of the
three differences that made the cold receipt what it was preserved — a **fresh**
prefix and an **empty throwaway `HOME`, still empty at exit** — and one not: the
work root was **reused**, so this was a reviewed install rather than a second
cold one.

**The gate: `$QUALITY_TOOLS_PREFIX/bin/zig-gate`, exit 0, GATE PASSED.** The whole
gate, `zig fmt --check` through the cross-target section, with its analysers
resolved inside that prefix, `policy=builtin` and no `$HOME` or `PATH` lookup.
`zbc` over this tree: `selected=32 analyzed=32 failed=0 errors=0`, **3** advisory
warnings and 3 findings — the same three `intfromfloat-without-clamp` this file
has always carried, and nothing else. No rule was disabled, no severity lowered
and nothing whitelisted; the `zbc` source patch is what the reviewed install
carries and gates with, and it is recorded in `tools/quality/PROVENANCE.md`.

**The cross section is read from the immutable run directory of its own run,
not from a rolling summary**, and what it reported: `mode=zig-build`, this
project's own `cross-test.profile.sh`, `CROSS_JOBS=2`, `CROSS_BUILD_JOBS=1`,
900 s build and run budgets, `bookkeeping_failure=false`, `target_count=5`.

| Target | Build | Run | Tests | Note |
| --- | --- | --- | --- | --- |
| `x86_64-linux` | pass | pass | 348 | the host itself |
| `aarch64-linux` | pass | pass | 348 | QEMU user-mode |
| `riscv64-linux` | pass | pass | 348 | QEMU user-mode |
| `s390x-linux` | pass | pass | 348 | QEMU user-mode, big-endian |
| `x86_64-windows` | pass | `build_only`, `runtime_unavailable` | — | no wine available: compile coverage only, never a tested target |

**1392 executed tests** across the four REQUIRED targets, `pass 4, fail 0,
build_only 1, partial 0`, `status=partial`, `exit_code 0`. A clean run reports
`partial` precisely because one row is compile-only, and it still exits 0. The CI
runtime reader, pointed at that same `summary.json` with expected exit 0, exited
0 itself.

**The patched analyzer's own rule was checked before it was trusted.** Its
`use_undefined:` regression suite — 20 of those tests travel in the patch, 9 were
already there — was built and run directly, `zig test --test-filter
"use_undefined:"` over the patched `src/lib.zig` with the type engine: **29
selected, all 29 passed**, exit 0 over the bytes as shipped. Both that and the
earlier run over the same filter before the review correction passed; both are
the tool's own suite rather than this tree's gate, and the witnessing and the
receipts are in `tools/quality/PROVENANCE.md`.

**What this receipt does not claim.** Its own `not_proved` list: the **three-run
current baseline**, the **selected solver optimisation**, a **remote GitHub
Actions run** and **`vf` engine execution**. No `ns/op` figure in this document
was refreshed by it, and the three benchmark smokes below are one run each, not a
baseline. **At the date of this receipt** the remaining work was Wave 2's
measurement and Wave 3's measured optimisation — **both closed since, see the two
supersession notes below**; nothing in the installed gate was waiting on either.
The install, re-hash, gate and cross logs live under a scratch root that does not
survive the session, which is why the reproducible form is section 6's commands,
not those paths.

**Superseded on the same date, after this run, by the two headings below.** Wave
2's three-run measurement is now taken, checked and published in
[`performance-baseline-2026-10-02.tsv`](performance-baseline-2026-10-02.tsv).
That is a later, separately dated capture; it does not rewrite this receipt's
`not_proved` list, and the gate run refreshed no figure.

**And Wave 3 is closed too, by the Wave 3 section below.** The solver
optimisation named
above was trialled on the same date and **rejected**: three counterbalanced
paired measurements of the profile's predeclared primary row, all three
predeclared acceptance criteria failed, and the two-line guard was removed again
so the tree carries the original solver. `src/lp.zig` is back at the same
sha256 the baseline was pinned to, nothing landed from the trial, and **no
solver optimization is accepted, in flight or queued**. The `not_proved` entry
above stays as the receipt wrote it; this is the separate Wave 3 section.

### Benchmark smoke verification — 2026-10-02

Each benchmark was compiled as a standalone `ReleaseFast` executable — root
`bench/bench.zig`, `bench/bench_vec.zig`, `bench/bench_lp.zig`, `-Minterval` on
`src/root.zig` — then run **alone, one at a time**, stderr redirected into its own
regular file and read back from it. One run each, and the counts of what reached
the file are the point: **60** timed rows in the scalar program, **276** in the
vector program and **26** in the LP program (13 `dbg` + 13 `smp`).

**Those are smokes, not a baseline, and no speedup is claimed.** Each program ran
once; its internal timing repetitions are unchanged. What the capture does
establish is that every row survives the redirect, where the old positional
writer reset its offset to 0 and dropped rows with no error, and that the LP
accounting held on both heaps: every body swept **twice** with drift or imbalance
fatal, **494,632** successful allocs and frees and **306,958,852** allocated and
freed bytes **on each of `allocator=dbg` and `allocator=smp`**, with every sink
value and the geometry report byte-identical between them. **The three-run
baseline is its own capture in the section below**; it does not convert these
three runs into a baseline. The Wave 3 trial taken after that one is
**rejected**, in its own section below.

### Wave 2 — the current three-run baseline, 2026-10-02

**This is the current measured baseline, and it supersedes nothing in sections 2
and 3.** Those tables stay the 2026-09-30 capture; this is a second, separately
dated capture, published as its own file,
**[`docs/performance-baseline-2026-10-02.tsv`](performance-baseline-2026-10-02.tsv)**,
holding **all 362 timed rows** with each row's three `ns/op` values and its
median, minimum and maximum. **The figures are in that file and not here.**
Read a row out of it; do not read a row out of this document and call it current.

Compiler 0.16.0, root and `interval` both `ReleaseFast`, captured on a **shared
machine that was neither pinned nor isolated**. Three **complete sequential
program runs** per program — the order `scalar` → `vec` → `lp` repeated for
three rounds, sequential, with no parallel benchmark, profile or build — all nine
exiting 0, with stdout and stderr on ordinary files read back afterwards. Each
program was its own standalone `ReleaseFast` executable, root and `-Minterval` on
`src/root.zig`, built under a private build cache and private global cache
rather than the contended shared one.

**Nothing about the workload moved to produce that capture**: no workload,
iteration count, seed, elimination order, warmup (`1`), internal repetitions
(`7`) or row budget (`20,000`) changed. Each TSV cell is the **minimum over that
program's 7 internal repetitions**, so the three values per row are three program
runs and the min/max columns are the spread **across those three**, not across
the seven.

**What was checked, and how.** A strict throwaway reader took each of the nine
logs with the Wave 1 originals as a `--reference` and compared them keyed by
row, never in report order. It found **60** timed rows in every scalar run,
**276** in every vector run and **26** in every LP run (13 `dbg` + 13 `smp`),
with **row identity, iteration counts, the per-body checksum sequences and the
final folds matching the Wave 1 originals on all nine runs** — so the capture
computes the same things the previous capture computed. For LP it also checked
the accounting: **all 13 accounting rows identical across both heap sections of
all three LP program runs**, the geometry report identical across them too,
and **494,632 allocs and 494,632 frees, 306,958,852 allocated bytes and
306,958,852 freed bytes, on each of `allocator=dbg` and `allocator=smp`** — the
same totals the smoke run above reported, now confirmed over three runs each.

**All 13 LP cases are in the TSV**, one row each on both heaps, with the median of
the three per-run minima and the min–max span across the three runs in brackets.

The `dbg`/`smp` gap on those rows is the `DebugAllocator` round trip step 3
measured, not a property of the solver: the shapes and the accounting are the
same, so **this document does not compare the two allocators as a result.**

**Seven scalar rows are in it too**, under the operation names `interval.scale`,
`div`, `mul`, `sub`, `sqr`, `add` and `abs`. This document does **not** read them
as a delta against the 2026-09-30 step-2 capture — the earlier one was taken on
an idle machine and this one on an unpinned shared one, and the noise floor below
still binds. The ordering is stable; the cheap rows are not precise to the digit.

**The 276 vector rows are named the same way** — under the operation names
`alloc.*`, `dyn<n>.*` and `vec<n>.*` for `n` in 2, 3, 4, 8, 16, 32.
**No speedup is claimed**: this is one revision on an unpinned shared machine, not
a before/after pair. Run 1 was strictly highest on 211/362 rows: 54/60 scalar,
136/276 vector and 21/26 LP. The capture provides dated, checkable figures for the
next comparison, not evidence of a uniformly slower first run.

### Wave 2 — the LP profile, 2026-10-02, and the one candidate carried into Wave 3

**What was profiled.** A profiling-only consumer imported the repository's own
public `bench/bench_lp.zig` and called its public `run(*Runner)` twenty times
over, taking the `Runner` type from that function's own parameter type. No
workload, case, seed, iteration, warmup, repetition or budget change, no solver
copy, no new production API. Built `ReleaseFast` with `-fno-strip` for DWARF,
private cache and private global cache, and sampled with
`perf record -e cycles:u -F 999 --call-graph dwarf,16384`.

**Two things about that profile must be said before any number in it.** The
consumer initialises `Runner` with `std.heap.smp_allocator` so the actual heap
is the real SMP one, while `bench_lp.run`'s own text still prints
`allocator=dbg` — that label is fixed inside the imported `run` and is
**misleading in this profile by construction**; the disclosure is the point.
And the profile is **whole-process**: geometry, the 13 timed bodies, the untimed
allocation accounting and the printing are all inside it. It is **not**
timed-region-only, and no `ns/op` figure was taken under it.

**What the samples say.** **0 samples lost**, and the per-body fingerprints match
the original run, so the profile measured the same work the benchmark runs
measured. `System.eliminate` accounts for more than half of total process period.
Within it, the **post-elimination rescan** — two address regions of the emitted
binary, taken from raw leaf periods because the DWARF reports would not separate
them — is a small share of whole-process period and a much larger share of
`eliminate`. The `Buckets.partitionInto` collecting partition is smaller again,
and that is the elimination's own bookkeeping, **not** the heuristic's tally.

**The heuristic's own cost, stated as an upper bound and no more.** `chooseNext`
has exactly two callers in the source, `System.eliminationOrder` and
`System.eliminateInOrderOfChoice`, and `pairCount`/`Tally` are inlined into it.
The two callers' **combined SELF** share of process period is the figure quoted
below, and it is an **upper bound for the inlined `chooseNext` plus
`pairCountTally`, not a measurement of either**: caller self share also carries
the wrapper's own work, and the DWARF call-chain and `--inline` reports
returned inclusive equal to self for these inlined frames, so **no precise
inclusive cost for the inlined scans is available from this profile and none is
invented here.** On that upper bound the heuristic is not worth changing, which
is the whole reason the candidate below is about the rescan and not about it.

**Raw perf percentages are sample attribution, not speedups**, and this was an
unpinned shared host.

**The one candidate selected, and its exact status.** Test an **RHS-first
short-circuit in the private `System.checkRowForContradiction`, before the
`isAllZero` test**. Among the two scan hypotheses, the measured rescan is larger
than the heuristic upper bound. The trial rejects rows by their upper RHS
endpoint before scanning coefficients. The predicate stays **exactly** `rhs.hi < 0`; every all-zero
row, all-rows, unsat transition, tie, elimination order, row budget and every
piece of arithmetic stay as they are, and no API, validation, retry, allocator,
cache or layout change travels with it.

**At the date of this section it was not implemented and no speedup had been
measured.** The candidate was selected, not proved, and the rule written down
then still stands: Wave 3 had to show it with a **differential proof** that every
solver result, checksum, geometry report and accounting total is unchanged,
plus **repeatable baseline-and-candidate timing** that clears the noise floor,
and a failure of either had to be recorded as a **rejection** rather than
explained away. **Superseded the same day, by the Wave 3 section below: the
trial ran, the correctness half passed, all three predeclared timing criteria
failed, and the candidate was REJECTED with NO CLAIM and the original solver
restored.** Nothing in this section was ever a claim that it would pay, and the
two profile percentages above remain dated sample attribution rather than
speedups. Remote GitHub Actions and the `vf` engine remain unexercised and
are not a Wave 2 or Wave 3 promise.

### Wave 3 — the RHS-first trial, 2026-10-02: REJECTED, NO CLAIM

**What was trialled, and that it is now gone.** The one candidate the profile
selected — the RHS-first short-circuit in the private
`System.checkRowForContradiction`, ahead of the `isAllZero` test — was
implemented as exactly **two guard lines** in `src/lp.zig`, measured against a
frozen baseline, and then **removed again**. `src/lp.zig` is byte-identical to
the pre-trial file: sha256 `40868f63…`, the same pin the baseline side was
built from. **No source change, no comment and no API from this trial remains
in the tree, and no solver optimization is accepted, landed or queued.** The
predicate was exactly `rhs.hi < 0` while it was in, and nothing travelled with
it: the arithmetic, the other guards, the all-zero / all-rows / unsat-transition
rules, the tie handling, the elimination order, the 20,000-row budget and the
validation are the originals.

**The primary row and the three criteria were fixed before the paired trial
captures.** One row, named in advance: **`eliminateAll chosen, mixed 14x2`**, **200
iterations**, heap **`allocator=smp`**, whose earlier three-run max/min spread
was 3.17%. The whole-process profile did not separate costs by benchmark case.
All three predeclared timing criteria had to hold:

| # | Predeclared criterion | Required |
| --- | --- | --- |
| 1 | median improvement | ≥ 5 % |
| 2 | every paired round improves | 3 of 3 |
| 3 | the two three-run ranges | disjoint |

**The three paired rounds.** `ns/op` is the minimum over the unchanged 7 internal
repetitions after 1 warmup, at 200 iterations, on `allocator=smp`. The pairs ran
**serially** and counterbalanced, so ordering bias does not land on one variant,
and the three paired gains were **−250.04 %**, **+27.44 %** and **+6.88 %**. The
absolute `ns/op` values behind them are in
[`docs/performance-trial-2026-10-02.tsv`](performance-trial-2026-10-02.tsv); read a
row out of that file, not out of this section.

**All three criteria fail.**

| Criterion | Observed | Verdict |
| --- | --- | --- |
| median ≥ 5 % better | the candidate median is **2.19634548 % lower** | **FAIL** — below target |
| every paired round improves | **2 of 3**; pair 1 is a **250.04 % regression** | **FAIL** |
| ranges disjoint | the baseline three-run range lies **inside** the candidate's | **FAIL** |

**So: REJECTED, NO CLAIM.** The 2.19634548 % median difference is **not a
speedup** and is not written down as one. It is smaller than this row's own
run-to-run spread on an unpinned shared machine and rests on three samples. In the
first pair, the candidate takes 3.50× its baseline time. Under the rule fixed
before those captures, one failing criterion was enough;
all three failed. **The two guard lines are not to be carried back in.** No
second candidate is queued, and this trial says nothing about whether some other
part of the solver is worth measuring — that would need its own profile and its
own predeclared criteria, and neither exists.

**The method, in the terms a later session has to trust it.** Compiler 0.16.0,
both builds root and `interval` `ReleaseFast`, private build and global caches,
private scratch root. Six **complete LP program runs** in three serial
counterbalanced pairs **AB / BA / AB**, **all six exiting 0**, with no concurrent
project build, profile, test or benchmark on the machine, on a shared and
unpinned host. The workload did not move to make this comparison: the actual
complete LP programs, unchanged, with the same cases, iteration counts, seeds,
7 repetitions, 1 warmup and 20,000-row budget, stdout and stderr on ordinary
files read back afterwards. The baseline was built from a **frozen copy** of the
sources — a 7-file manifest over `lp.zig`, `vector.zig`, `interval.zig`,
`interval_ext.zig`, `rounding.zig`, `lp_exact.zig` and `root.zig` — with the
before `lp.zig` sha256 `40868f63e901c04204234e9f28eb5d832f44a5817ecb2ad484213835cfa5fb23`
verified against the revision rather than against a working copy; the candidate
was the live tree, `lp.zig` sha256 `606fa7f15a55ccf0410beffefc23aeea9757459f7191e87167f498f3a5f0551a`.
The original "before" argv is preserved exactly as it ran; the certified replay
control later pins both nominal modules to the frozen copies. The baseline code
revision is `7b472aee`, unchanged by this trial.

**Both captures still compute the same thing.** The strict readers for the
baseline three-run capture and for the candidate three-run capture each **exit
0**. Against the Wave 1 reference they match **row identity, iteration counts,
the 13 body checksum sequences and the final fold `4b4f94d960b30e8e`**, and the
geometry report and the **13 accounting rows** are identical across both heap
sections of all three program runs of each side: **494,632** allocs against
**494,632** frees and **306,958,852** allocated bytes against **306,958,852**
freed bytes, **on `allocator=dbg` and on `allocator=smp` alike**. The candidate
changed nothing a reader can see. That is the correctness half passing; it is
not the timing half, and passing it does not convert the trial into an
acceptance.

**The behaviour and boundary proofs, and their exact scope.**

- **State machine.** **414** state cases — **400** random cases with 0–2
  variables and at most 6 rows, plus **14** controlled cases — over **1,341
  adds** and **442 eliminations**, with **0 gaps** in the enumerated transitions.
  Compared exactly rather than approximately: state, errors and null answers,
  row order and liveness, and the serialized state **at the bit level**.
- **Boundaries.** **23** precise cases, **81** operations, **104** snapshots and
  **10,566** explicitly serialized words compared word for word, plus **150**
  allocation-failure runs (**10** scripts × **15** indices) in which every
  allocation count and every byte total comes back balanced.
- **Both consumers** passed against the before tree and against the candidate:
  the state-machine and boundary differentials each built and each ran **exit
  0** on both sides.
- **Result: 0 mismatches and 0 unbalanced `COUNT` or `BYTE` teardowns.**

**The proofs were checked against mutants, so they are not vacuous.** The
certified Debug boundary control exits **0** frozen-against-frozen and **0**
frozen-against-candidate, while three deliberately wrong private predicates —
`rhs.hi <= 0`, `rhs.lo < 0`, and an approximate-zero test — each build **exit
0** and each **exit 1** when run. One methodological fix is part of that receipt
and is not a change to the tree: the boundary probe originally *reported*
mismatches without failing the process, so it was corrected to return
`error.DifferentialMismatch` and to compare allocation counts as well as byte
totals. Every exit code quoted above is from after that fix; before it, the
mutants would have run green. The mutants are private throwaway copies under
the wave's scratch root, not tree files; no permanent test, no new API and no
probe was added for them, and the probes were removed at closure.

**Two independent native reviews passed** — one on semantics, one on
standards — after the material findings they raised were corrected and
re-verified: the probe that did not fail on a mismatch, and the source pin that
had to be established from the revision rather than from the working copy. No
comment explaining the accepted row ordering was added to the tree, because the
candidate was rejected: a comment describing a guard that is not there would be
a false description of the current source.

**The historical profile figures stay exactly what they were.** **4.276 %** of
whole-process period (**7.537 %** of `eliminate`) for the post-elimination
rescan, and **0.594916210 %** as the combined caller-`SELF` upper bound for the
inlined `chooseNext` plus `pairCountTally`, are **dated sample attribution on an
unpinned shared host, not speedups** — and the trial above is what a prediction
drawn from them turned out to be worth.

**The full data** is
[`docs/performance-trial-2026-10-02.tsv`](performance-trial-2026-10-02.tsv):
**52 rows**, both variants, every LP case on both heaps, three `ns/op` values
each with median, min and max. Its header line records the date, host, compiler,
the baseline code revision `7b472aee`, both `lp.zig` sha256s and the outcome —
`REJECTED NO_CLAIM`, three counterbalanced sequential pairs `AB/BA/AB`, each row
the minimum of 7 after warmup 1, on a shared unpinned host, with the original
solver restored. Read a row out of that file, not out of this section: the
primary row was predeclared. The other 25 timed rows per variant provide complete
capture data, not alternate acceptance targets or claimed performance results.

### Final Wave 3 verification — 2026-10-02

The rejected trial is closed and all seven production source hashes match the
frozen baseline again; `src/lp.zig` is
`40868f63e901c04204234e9f28eb5d832f44a5817ecb2ad484213835cfa5fb23`.
The final runs below used the restored solver, after all delegated implementation
and documentation writers stopped, with explicit private caches and an empty `HOME`.

| Check | Observed result |
| --- | --- |
| `zig build test -Doptimize=Debug -j1 --summary all` | 348/348 tests passed |
| `zig build test -Doptimize=ReleaseSafe -j1 --summary all` | 348/348 tests passed |
| `zig build test -Doptimize=ReleaseFast -j1 --summary all` | 348/348 tests passed |
| `zig build test -Doptimize=ReleaseSmall -j1 --summary all` | 348/348 tests passed |
| explicit ReleaseSafe MPFR corpus | 1,886 rows, 0 failures, 427 exactly representable |
| external package consumer and README executable | 31 README checks passed; both consumers exited 0 |
| complete scalar benchmark smoke | exited 0 |
| complete vector benchmark smoke | exited 0 |
| complete LP benchmark smoke | exited 0 |
| `zig build docs` | passed |
| installed expanded gate | all required sections passed |

Optional `zig-cov` coverage was not requested or run.

Strict readers verified the final benchmark contracts: all 60 scalar, 276 vector
and 26 LP rows match the original identities, iterations, checksum streams and
folds. These are single final smoke runs, not three new timing captures. LP
geometry and all 13 accounting rows per heap also match, including balanced
494,632 allocations and 306,958,852 bytes per heap.

The exact rejected candidate snapshot also completed scalar and vector
contract-only smokes: all 60 and 276 rows matched. Together with the three
candidate LP captures, every benchmark program met the differential criterion;
these additional smokes did not reopen the rejected timing decision.

LSP reported no issues in seven production files, four benchmark files and the
corpus test. The gate passed formatting, build, tests, AST checks, `ziglint`,
`zlint`, `zbc`, `zwanzig` and cross-target execution. `zbc` analyzed all 32
selected files with 0 failed files, 0 errors and the 3 standing advisory
`intfromfloat-without-clamp` warnings; 12 unresolved-import lookups remain.

The immutable cross run of that final verification, schema 2:

| Target | Build | Runtime | Executed tests |
| --- | --- | --- | --- |
| `x86_64-linux` | pass | pass | 348 |
| `aarch64-linux` | pass | pass | 348 |
| `riscv64-linux` | pass | pass | 348 |
| `s390x-linux` | pass | pass | 348 |
| `x86_64-windows` | pass | unavailable, build-only | none |

Four required runtime passes, 1,392 runtime tests total, overall `partial`,
`fail=0`; Windows is compile coverage only. The CI workflow's actual Python
reader passed locally on that immutable summary. This is not a remote GitHub
Actions run or a `vf` engine run. The empty `HOME` remained empty.


### Full 53-target compilation — 2026-10-02

Both the unchanged-source baseline and the permanent compilation route built
every target in the pinned Zig 0.16.0 Tier 1/2 table. The baseline used a private
copy with only a temporary compile-step adapter; all production sources and
test bodies were unchanged. It exited 0. No portability fix or target exclusion
was required.

The permanent route is `zig build test-compile` and
`cross-test --profile ./cross-compile.profile.sh`. It compiles the same 11 test
binaries as `test`, the Debug NaN probe and the installed library, without any
run step. The library artifact is the harness's output marker; the test
dependencies are what force code generation of the exercised public API.
Benchmarks and foreign consumer fixtures are outside this compilation sweep;
the host consumer remains in the normal runtime `test` step.

```sh
ZIG=/absolute/path/to/zig-0.16.0 \
  "$QUALITY_TOOLS_PREFIX/bin/cross-test" \
  --profile ./cross-compile.profile.sh \
  --jobs 4 --build-jobs 1 --build-timeout 900 \
  --output "$SCRATCH_ROOT/compile-out"
```

The profile derives all targets from the harness's published table, validates
the compiler reports 0.16.0 and uses the supported artifact-mode `skip` policy.
An inherited `TARGETS` subset cannot narrow the default sweep; explicit CLI
`--targets` still works. The recorded run also started with
`CROSS_REQUIRE_RUNNERS=1` in the environment, overridden by this compile-only
profile. No runtime is represented as having passed.

**Final immutable run:** exit **0**. Counts: `pass=0`, `fail=0`, `build_only=53`,
`partial=0`;
overall `build_only`. Every build log reports 11 Debug test compilations,
one Debug NaN-probe compilation and a successfully installed library:
**583 test binaries, 53 probes and 53 libraries**, with no test execution.

| Platform | Compiled targets |
| --- | --- |
| Linux | 20 |
| FreeBSD | 6 |
| NetBSD | 9 |
| OpenBSD | 9 |
| Windows | 4 |
| macOS | 2 |
| Mac Catalyst | 2 |
| WASI | 1 |
| **Total** | **53** |

The matrix includes 32-bit and 64-bit architectures and both byte orders.
Only Debug was swept across all 53; this is not an optimize-mode product or
runtime soundness proof. The profile validates the compiler directly;
artifact-mode summary JSON itself leaves `zig_version` empty.

The actual native `test-compile` command passed with no run steps. Native
Debug and ReleaseSafe each passed **348/348 tests**, including **1,886 corpus
rows, 0 failures, 427 exactly representable** and the real external consumers'
**31 README checks**. All production and test-source hashes still match the
unchanged-source baseline.

The installed expanded gate then passed, exit **0**. Its runtime cross run still
executes **348 tests** on each of the four required Linux targets; Windows is
`build_only/runtime_unavailable`, overall `partial`, `fail=0`. `zbc` analyzed
all 32 files with 0 failed files, 0 errors, 3 standing advisory warnings and
12 unresolved-import lookups. Both shell profiles parsed, `zig build docs`
passed and LSP reported no build-graph issues. The isolated `HOME` remained
empty. Remote Actions, `vf` execution and optional coverage were not run.

### Cross-target verification — 2026-10-01, and the 300-second timeout that reads like a defect

**The mode first, because it decides what the figures below mean.** `cross-test`
runs this build's own `test` step and adds only `-Dtarget=`, so every count
here is the tree's **default optimize mode, Debug** — `build.zig` takes
`optimize` from `b.standardOptimizeOption(.{})` and names no default of its
own, and the build logs say `compile test Debug <target>`. A project profile
that passed `-Doptimize` would change the mode for the targets it covers, so
read one if there is one.

**Measured on 2026-10-01 at one tree state**, in two runs: the whole matrix at
the harness's default execution timeout, and then the two targets that need
more at 900 seconds.

| Target | Build | Run | Tests | Note |
| --- | --- | --- | --- | --- |
| `x86_64-linux` | pass | pass | 348/348 | the host itself, executed natively |
| `aarch64-linux` | pass | pass | 348/348 | QEMU user-mode; **fails the default timeout**, see below |
| `riscv64-linux` | pass | pass | 348/348 | QEMU user-mode; passes the default 300 s |
| `s390x-linux` | pass | pass | 348/348 | QEMU user-mode, **big-endian**; **fails the default timeout**, see below |
| `x86_64-windows` | pass | `build_only`, `runtime_unavailable` | — | no wine available, so "builds" is the whole of the claim |

Three foreign targets therefore execute the entire test step, corpus tier
included, at 0 FAILED — the same 348 the native run reports, not a subset.

**`s390x-linux` is the byte-order coverage in this project's gate table, and that is
why it is in the table rather than left out.** Every other target in the gate table is
little-endian. The code most sensitive to byte order is
the oracle's own: `src/rounding.zig` steps endpoints by `u64` bit pattern, and
the NaN contract trap reads bit patterns out of a value. A little-endian host
cannot get that class of code wrong. (The full 20-target sweep above widens this to four big-endian targets: `s390x-linux`, `aarch64_be-linux`, `armeb-linux` and `thumbeb-linux`.)

**The trap: the harness's default execution timeout is 300 seconds and this
project's heaviest test does not fit it under emulation.** The default is the
harness's, not this project's. The test
`test.Vec: distance is never below the true Euclidean distance` sweeps
**4,000,000** cases — the `norm_cases` constant in `tests/vector_test.zig` — and
the whole 55-test vector binary costs essentially what that one loop costs, so
the sweep is the binary's time. Natively that fits inside the default budget with
room to spare. Under `qemu_user` it does not, and the run then prints exactly
this:

```
cross-test: target=aarch64-linux build=pass run=fail tests=348 reason=tests_failed
cross-test: target=s390x-linux   build=pass run=fail tests=348 reason=tests_failed
cross-test: status=fail pass=2 fail=2 build_only=0 partial=0
```

The per-target build log underneath it names that test and says it **timed out**,
and then reports `Build Summary: 25/27 steps succeeded (1 failed); 347/348 tests
passed (1 timed out)`.

**That is a timeout, not a defect, and the one-line summary is what makes it
look like a defect.** `cross-test: status=fail` cannot tell a timeout from a
wrong answer — both carry `reason=tests_failed` — and the `tests=348` on that
line is how many tests RAN, not how many passed, so it stays at 348 on a run
that lost one. Read the per-target build log before believing a cross-target
failure here, and look for `timed out` in it. Re-run at `--timeout 900` and the
same two targets report `run=pass tests=348 reason=tests_complete` and the run
reports `status=pass pass=2 fail=0`. The two runs differ only in `--timeout`
and `--output`, and the failing log names the timeout and nothing else.

**The harness, so the next session does not have to rediscover any of this.**
`cross-test` is **in this repository's distribution now**: its source is
`tools/quality/harness/bin/cross-test`, and the installer puts it at
`$QUALITY_TOOLS_PREFIX/bin/cross-test` beside its `lib/cross-test/` siblings. It
is not a submodule and it is not a moving upstream, and the pin is the same for
it as for the analysers — `tools/quality/manifest.tsv`, the ordered hashed
patches, and `SHA256SUMS`. It behaves in four ways that matter here:

- **It manages its own cache**, and refuses the obvious override: `--cache-dir`
  is rejected with `cross-test manages this option: --cache-dir`, and so are
  `--prefix`, `-Dtarget`, `-j` and `--test-timeout`. Do not pass them.
- **It discovers a project profile** at `./cross-test.profile.sh`, then
  `./test/cross-test.profile.sh`, and a profile may set `CROSS_*` variables
  including `CROSS_MATRIX`, which is what decides the target set. A profile in
  the tree therefore decides what a green run *covers* — read it before
  quoting the table above as the project's coverage.
- **It needs `ZIG` pointed at a real compiler.** The `zig` on `PATH` may be a
  version-manager shim described in section 5.
- **Its output has to be on local disk.** A network mount rejects `renameat2`
  with `EINVAL`, so a Zig build on one cannot use a cache there; cross-test
  solves that for its own cache, and `--output` solves it for the run.
- **It refuses a run to a volume that cannot host one.** On a managed host an
  `--output` (or `CROSS_PREFIX`) that resolves to `/tmp`, `/var/tmp` or
  `/dev/shm` is rejected with exit 2 before any output, lock or run directory is
  created, symlinks resolved first, so a link that lands in `/tmp` is judged by
  where it lands. The rule comes from the installed
  `lib/cross-test/scratch-contract.sh`, which on a managed host requires a root
  on one of the volumes that host approves and elsewhere requires an explicitly
  owned, writable, local, non-symlink path with room on it — so a CI runner may
  use its own temporary storage and a shared machine may not use `/tmp`. No
  machine-wide policy file is a prerequisite; where one is readable it is still
  sourced first and its exports still win.

The invocation behind the table, with `--output` on a local volume. **The
measurements above came from that invocation and are unchanged**, and the run is
now the installed binary driven by the same variables the gate section names.

**Every snippet in this file that builds a scratch path is subshelled and fails
closed.** The four capture snippets — the cross-test invocation below, the
benchmark capture in step 2, the instruction-count probe in step 4 and the
throwaway build in section 5 — each name the local root they build under, and
each asserts its own variables before the first command that builds a path, all
of it inside `( … )`. So a snippet whose variables are unset ends with a message
instead of letting it create `cross-out`, `bl` or `probe` somewhere no rule
approved — and the `exit` leaves the subshell, not the shell a reader pasted it
into. **A snippet that stops is reporting an unset variable, not a defect in the
command.** No machine-wide policy file is a prerequisite of any of them.

The run, against the installed prefix — nothing here resolves a tool out of a
home directory, and the compiler is a real 0.16.0 rather than the PATH shim:

```sh
(
  : "${QUALITY_TOOLS_PREFIX:?set it to the installed prefix}"
  : "${QUALITY_TOOLS_WORK_ROOT:?the installer's own local root}"
  ZIG="$(zig 0.16.0 env | awk -F '"' '/\.zig_exe =/ {print $2; exit}')"
  : "${ZIG:?resolve a real 0.16.0 first}"
  ZIG="$ZIG" "$QUALITY_TOOLS_PREFIX/bin/cross-test" \
    --targets x86_64-linux aarch64-linux riscv64-linux s390x-linux \
    --output "$QUALITY_TOOLS_WORK_ROOT/cross-out" --jobs 2 --build-jobs 2
  ZIG="$ZIG" "$QUALITY_TOOLS_PREFIX/bin/cross-test" \
    --targets aarch64-linux s390x-linux \
    --output "$QUALITY_TOOLS_WORK_ROOT/cross-out3" --jobs 2 --build-jobs 2 \
    --timeout 900
)
```

Each run prints a `cross-test: target=…` line per target, a `status=` line, and
leaves `cross-test-summary.json` plus per-target logs under `--output`. A run
here writes nothing into the working tree and leaves no core dumps.

### The oracle: 35 of the 56 public operations, and a corpus tier for the other 21

This is the fact that changes what a later session is allowed to trust, so it
belongs near the top of this file and not at the bottom.

The oracle grew from 1,037 lines to several thousand and from 8 covered
operations to 35, and it is now `tests/soundness_shared.zig` under four sibling
test files, one per concern. It computes true extrema from the ORIGINAL `f64`
inputs and checks containment, and it is the only thing between a faster library
and a wrong one. The 35, by the strength of the reference each is held to:

| Layer | Count | Operations | What the reference is |
| --- | --- | --- | --- |
| exact image, no sum needed | 12 | `mul`, `abs`, `sqr`, `neg`, `hull`, `hullOf`, `intersect`, `intersectionOf`, `floor`, `ceil`, `trunc`, `round` | the true mathematical image, built from the original `f64` endpoints. None of these forms a sum: a magnitude, a square, a negation, a min and a max of two `f64` are all exact where they are computed |
| exact image, by an exact residual | 5 | `add`, `sub`, `translate`, `expand`, `scale` | the true sum of the original `f64` endpoints, judged through a `TwoSum` residual — `s` plus `err`, an exact expansion of the sum — never through a rounded `f128` sum. **A rounded `f128` sum is not exact and is never used as truth**: a product of two `f64` needs 106 significand bits and `f128` carries 113, so products are exact, but `floatMax - 3` has its lowest set bit at 2^0 and its highest at 2^1023, so it needs about 1024 bits and **rounds back to `floatMax` even in `f128`**. `1e300 + (-1e-300)` is the same fact at the other end. `scale` needs the five-term form, because its extrema are `(A + B + G*A - G*B) / 2` and the division by two is a sixth. The residual is held against the unsafe `[floatMax, floatMax]` answer for `floatMax - 3` |
| exact, by cross-multiplication | 2 | `div`, `recip` | `f128` holds a **product** of two `f64` exactly — 106 significand bits against the 113 the type carries — so the bound times the divisor is exact and the sign of the divisor fixes the direction. No quotient is ever evaluated. This is a product, and the row above is not, which is the entire difference between the two |
| exact, by a stated bracket | 3 | `sqrt`, `cbrt`, `tanh` | `sqrt` on IEEE 754's own guarantee that a square root is correctly rounded, widened half an ULP; `cbrt` on the sign of `y^3 - x`, which assumes no accuracy of any primitive; `tanh` on the true value in `f128` to 3.1e-34 relative, from the exponential identity with the cancellation near zero paid for, bracketed to `[tanh 20, 1]` past 20 where the value is indistinguishable from 1 at thirty-four digits |
| values | 4 | `midpoint`, `clamp`, `width`, `distanceTo` | each has a reference built from the original `f64` endpoints — the centre, the nearer endpoint, the difference of the two endpoints. **The difference is formed in `f128` and is not always exact there**, for the same reason the sums above are not, which is why these are judged from BOTH sides by `scalarOk` at one ULP rather than by an exactness assertion |
| laws | 9 | `contains`, `overlaps`, `subsetOf`, `eql`, `ne`, `lt`, `le`, `gt`, `ge` | no image exists for a bool, so these are checked against each other and against the set operations, which do have one |

`div` and `recip` report **0 skipped precondition**, where they reported 2,040 and
2,163. Those skips were half genuine non-applicability and half a coverage hole
wearing a precondition's clothes: the library returns a documented contract value
`[-inf, inf]` for a divisor that reaches zero, and a documented answer is a
contract value to be checked, not a case the oracle may decline to judge. A
divisor that merely REACHES zero is now checked from the sign of its two
one-sided limits, and the checks went from 5,070 to 7,110 for `div` and from
5,073 to 7,236 for `recip`.

**Three things the oracle grew beyond adding operations**, each of which changed
what the sweep can say rather than how much of it there is:

- **`width` and `distanceTo` are judged as values.** They sat under a magnitude
  rule that accepted `+inf` unconditionally and imposed no upper bound, so a
  width four times too large passed every one of its 8,000 cases. They are now
  judged two-sidedly, and the overflow the old rule existed for is decided by
  the REFERENCE instead — the exact width of the whole format is a real no `f64`
  holds, so `+inf` is the value there rather than a bound the reference has to
  be widened to.
- **An infinity frontier sweep.** The random layer screens every non-finite
  operand out, so 35 sweeps judged the library on finite inputs and not one of
  them reached an infinity. The new sweep is directed: sixteen named shapes,
  fourteen canonical and two pairs the constructor refuses, carried against each
  other, plus seven scalars for the operations that take one. Its reference is
  built from what an infinite endpoint stands for and is derived from the shape
  rather than read back from the answer, and it uses the `lo_beyond` /
  `hi_beyond` flags the `Range` struct already carried and nothing had ever set.
  **It found six operations whose answer at an infinity is not an enclosure, and
  two of the six findings were themselves wrong** — `sub`'s witness had two rays
  that cannot cancel, and `neg`'s read a non-canonical point where the contract
  has a ray. Both were withdrawn. The contract they were argued under is now
  stated in [two kinds of infinity](../README.md#two-kinds-of-infinity), and the
  sweep **judges all thirteen operations it walks and withholds none**, so a fix
  in `src/` no longer hides behind a withheld row. It was **not green** when
  judging landed: the failures were in the oracle's own references, not in `src/`,
  and they were exactly the kind a withheld row could never surface. All five are
  fixed — P8 of `docs/next-work-plan.md` lists them — and the sweep is green now.
  That document owns the defect and the repair.

  **Why the fix cost no hot-path work.** The repair is in the constructor, and
  its soundness rests on which arm of `roundDown` the corner reaches: at a finite
  nonzero argument `roundDown` is `prevDown`, a full ULP outward, while at a
  computed `+inf` it is `+floatMax` with no step left. Canonicalising the
  operand moves the corner onto the arm that has room, so the existing one-line
  `add` becomes an enclosure with no branch in it. `scale`'s single new branch is
  on the unbounded path only. The finite path is untouched.
- **The per-operation seed is keyed by label, not by position.** It used to be
  `seed ^ @intFromEnum(op)`, which meant inserting one member silently
  re-randomised every later stream and invalidated every count and every
  mutation-bite figure in this file, with no test failure to notice. It is now
  an FNV-1a hash of the operation's label. That was a precondition for adding
  operations to that enum, and it turned out not to be needed for the last
  twenty-one: the corpus tier landed outside the oracle entirely, so every stream
  kept the cases it had and every count below still means the same cases.

**What the in-tree oracle does not judge, and where it is covered instead: 21
operations.** Every one of them is in `src/interval_ext.zig`: `pow`, `powf`,
`exp`, `exp2`, `expm1`, `log`, `log2`, `log10`, `log1p`, `sin`, `cos`, `tan`,
`asin`, `acos`, `atan`, `atan2`, `sinh`, `cosh`, `asinh`, `acosh`, `atanh`.
The blocker was measured rather than assumed, and it is in the file's own header:
Zig 0.16's `f128` transcendentals are **not** wider than `f64`, so there is no
wider primitive to check them against. Over 20,000 draws `@exp(f128)`,
`@log(f128)` and `@sqrt(f128)` rounded to `f64` equalled the `f64` evaluation
20,000 times out of 20,000, and `@sin`, `@cos` and `@tan` on all but a few dozen.
**The escape was not a wider primitive, and it was not a hand-written one
either.** `tanh` has a reference of its own — the exponential identity with the
cancellation paid for, accurate to 3.1e-34 relative — and that is still the one
hand-written reference in the tree. The direction taken for the other twenty was
an **independently generated MPFR directed-rounding containment corpus**, so they
are checked against an external arbitrary-precision implementation at a declared
rounding direction rather than against a second implementation written in this
tree; a hand-written `f128` series is a second implementation, and the audit
needed to convince anyone it is correct costs more than the coverage it buys.

**That corpus exists.** `tests/corpus/elementary.txt` carries 1886 rows over 24
labels, 1813 of them over these 21 operations, checked for containment by
`tests/corpus_test.zig` in every mode, and T4, T6 and T7 in
`docs/tests-and-architecture-plan.md` are DONE with the mutation evidence that
the tier bites. Their three-ULP widening is therefore no longer a measured
figure that nothing bounds: it is bounded by containment against 256-bit MPFR
brackets, on the rows the corpus carries. **What it still is not is a proof over
every input** — 1886 rows are a sample, and the samples are the argument the tier
rests on, not the arithmetic of each operation.

### The blocker that started all of this, and why the row budget is still there

This is history now, and it is kept whole because the row budget is the one
guard in the tree that exists to stop a repeat, and a later session must not
read it as decoration.

**It was not a leak.** A `std.heap.DebugAllocator` over 2,800 solver operations
— `add`, `eliminate`, `eliminationOrder`, `bounds` and `box`, on both the mixed
and the straddling generators — reported `.ok`. Every `deinit`, `errdefer` and
caller-owned `free` in `src/lp.zig` and `bench/bench_lp.zig` was correct, and is.

**It was row explosion.** `System.eliminate` emits exactly
`num_lower(k) * num_upper(k)` rows, and a coefficient that straddles zero is
deliberately pushed into **both** buckets (`src/lp.zig:258-280`) because
dropping it would cut the feasible set. With the generators `bench/bench_lp.zig`
feeds it, the row count therefore grows by roughly a factor of the row count at
every round. Measured growth, exact, by reading the sign buckets `eliminate`
would build without materialising a single derived row:

| System | Growth |
| --- | --- |
| `mixed`, 6 vars, 24 rows | 24 → 215 → 20,076 → **351,661,485 predicted** |
| `straddling`, 5 vars, 10 rows | 10 → 100 → 7,756 → **56,340,286 predicted** |
| `mixed`, 4 vars, 6 rows | 6 → 11 → 26 → 486 → **223,269 predicted** |

At 16 bytes per `Interval` and six columns per row, the 351,661,485-row step is
about 33 GB written by a single `eliminate` call. The observed behaviour
matched: the growth was reproduced outside the benchmark as well. On a machine
with headroom that is survivable. It is not acceptable, and it must not happen
again.

A size search over 78 configurations — `mixed` at 4 to 8 variables and 6 to 64
rows, `straddling` at 3 to 6 variables and 4 to 20 rows — under a 20,000-row
budget found **not one that completes**. There is no comfortable size in the
current parameter space, which is why step 1 bounds the work rather than
tuning it.

### Which of the thirteen measurements were affected, before step 1

Unrunnable as written, because they never terminated in bounded memory:

- `reportGeometry` on `mixed 24x6` and on `straddling 10x5`
- `eliminateAll chosen, mixed 24x6`
- `bounds k=2, straddling 10x5`
- `box, straddling 10x5`

Bounded in memory (peak about 14 MB, freed each iteration) but slow enough that
iteration counts needed review: `bounds k=0, 6x4`, `box 6x4`,
`eliminationOrder 6x4`, `eliminateInOrderOfChoice 6x4`. Each paid a 223,269-row
final round.

Sound and unaffected then and now: `add 8 rows x 4 vars`, `add 64 rows x 8 vars`,
`build 6 rows x 4 vars (control)`, `eliminate k=0, 6 rows x 4 vars`, and both
`eliminateAll` rows on the heuristic system, which uses point `±1` coefficients
and therefore no straddling.

All thirteen measurements run today. None was deleted; the nine that breached
the budget were resized, and the table in step 1 records what each one became.

## 3. The steps, in order, and what each one bought

Steps 1 to 5 are done and their results are below. Step 6 onward are standing
instructions for whoever picks this up, and they are unchanged.

### Step 1 — Bound the LP benchmarks — DONE, and still load-bearing

**Result.** `zig build bench` completes; the whole `bench-lp` run reports
18.5 s against 21.8 s before round 2, and every predicted count still equals its
achieved count on every branch. All thirteen measurements run, and the
20,000-row budget is the only thing between a size mistake and a machine-sized
allocation on a host shared with other work.

`bench/bench_lp.zig` now carries `predictedRows`, a `row_budget` of 20,000, and
a `requireRowBudget` gate on every elimination the file drives. The prediction
was checked against reality: `reportGeometry` prints predicted beside achieved
and they are equal on every branch, 11/11, 2/2, 4/4, 48/48 and 121/121.

The guard works by predicting, before each elimination, what the row count would
become, and refusing to cross the budget:

```
next_rows(k) = (#rows with an exact zero in column k) + num_lower(k) * num_upper(k)
```

where a straddling coefficient counts once in `num_lower` and once in `num_upper`,
because that is exactly what `eliminate` does with it. Everything the check
needs is already public: `System.at(i)` yields the row, and the sign test is
three float comparisons. No derived row is ever built to make the decision, and
nothing is allocated.

Three things were built on top of it: every elimination the file drives is
gated, a trip exits non-zero through the existing `trap` helper with the
measurement name, the variable, the system shape, the prediction and the budget
in the message, and `reportGeometry` prints the predicted count beside the
achieved one so a future change that makes the solver cheaper shows up as a
smaller number rather than as a hang.

The second, independent guard is now the row budget itself, and that is
sufficient. The `ulimit -v` recipe that an earlier draft of this file
recommended is **wrong and was removed**: the compiler inherits the limit, so
`( ulimit -v 4194304; zig build bench-lp )` dies with `error: OutOfMemory` while
compiling, before a single benchmark row runs. Do not reintroduce it. If a limit
is ever wanted it must wrap the emitted binary, not `zig build`.

`System` propagates `error.OutOfMemory` out of `eliminate`, so a size that
escapes the budget surfaces as an exit status rather than as an OOM kill.

The five measurements that never terminated were resized to what the budget
allows, with the achieved row counts recorded in the file's own header so the
next reader does not "restore" the values that used to hang:

| Measurement | Was | Now | Peak rows |
| --- | --- | --- | --- |
| `reportGeometry` mixed | 6 vars, 24 rows | 2 vars, 14 rows | 17,034 |
| `reportGeometry` straddling | 5 vars, 10 rows | 2 vars, 11 rows | 14,641 |
| `eliminateAll chosen, mixed` | 6 vars, 24 rows | 2 vars, 14 rows | 7,994 |
| `bounds k=2, straddling` | 5 vars, 10 rows | 2 vars, 11 rows | 14,641 |
| `box, straddling` | 5 vars, 10 rows | 2 vars, 11 rows | 14,641 |

Four more had to be resized than the five named, because they breached the
budget too: `bounds 6x4`, `box 6x4`, `eliminationOrder 6x4` and
`eliminateInOrderOfChoice 6x4`. `bounds 6x4` peaked at 223,269 rows and crossed
on 55 seeds in 64 with a 196,927,221 prediction. All thirteen measurements
survive; none was deleted, and all four of those now run at 14x2.

### Step 2 — Capture the baseline — DONE, and the capture has been redone

**Result.** All three baselines exist and two full optimisation rounds have
been measured against them. The figures are below and they supersede the
original capture, which was taken under load and therefore reads high on every
cheap row.

`build.zig` exposes `bench-scalar`, `bench-vec` and `bench-lp` as per-file steps
alongside the combined `bench` step, which is unchanged. Nothing about what is
built differs; they are aliases, so one benchmark can be run alone.

```sh
(
  # run from the repository root; SCRATCH_ROOT comes from scripts/scratch.sh
  : "${SCRATCH_ROOT:?resolve a local scratch root first — see section 0}"
  BL="$SCRATCH_ROOT/bl"              # private cache, on local storage
  zig build bench-scalar --cache-dir "$BL/cache" --global-cache-dir "$BL/gcache"
  zig build bench-vec    --cache-dir "$BL/cache" --global-cache-dir "$BL/gcache"
  zig build bench-lp     --cache-dir "$BL/cache" --global-cache-dir "$BL/gcache"
)
```

The benchmarks pin their own mode to `ReleaseFast` in `build.zig`, so
`-Doptimize` is neither needed nor wanted. A private cache directory is worth
using anyway: the shared one is contended when anything else is building.

**Capturing a run to a file is part of that recipe, and it is now trustworthy
where it silently was not.** The benchmark report is written to stderr through
a streaming, line-buffered writer (`Out.print` in `bench/timing.zig`). It used
to go through a writer that recorded a byte offset and wrote **positionally**:
on a terminal that is invisible, and on a regular file — which is exactly what
`zig build bench-scalar > capture.txt 2>&1` produces — it lost output, silently,
with no error anywhere and no non-zero exit. That was found by *doing* the
capture and reading the file back, not by reading the code, which is the whole
argument for doing the capture. So the standing rule is: **capture by
redirecting, then read the file back**, never assume a printed table equals a
written one.

Two things did **not** change and are worth saying because the fix could have
changed them quietly. The clock is unchanged — `std.Io.Clock.real`, wall time —
and the recipe above builds the same three programs under the same private caches.
And no measurement was taken on a quieter machine because of this: the
writer is how the report leaves the process, not how long the timed region took,
and this document makes **no claim about any CPU**, its model or its clock
speed. Every `ns/op` figure below is still the capture named beside it.

Scalar, `bench-scalar`, ReleaseFast, **idle machine**, three runs, minima. Read
this next to the noise floor at the end of step 4: five of these seven rows sit
under 10 ns/op, where a shared machine moves by up to 44 % with nothing changed, so
only the ordering is trustworthy here and not any single delta.

| Operation | ns/op |
| --- | --- |
| `interval.scale` | 47.795 |
| `interval.div` | 15.465 |
| `interval.mul` | 9.639 |
| `interval.add` | 5.027 |
| `interval.sub` | 5.108 |
| `interval.sqr` | 4.807 |
| `interval.abs` | 4.138 |

`ext.powf` at 272.5 ns/op and `ext.pow` at 107.2 ns/op are the only figures for
those two. They are the original capture and they are the two most expensive
operations in the library, so nothing supersedes them. Neither optimisation
round changed the elementary functions' COST, and the later change to their
WIDTH (two ULP to three) added no measurable time either, because the rounding
helpers inline to nothing at ReleaseFast — so these two rows still stand as
costs. Read them as an order of magnitude under load, not as a current
number.

LP, `bench-lp`, ReleaseFast, **idle machine**, three runs, minima:

| Row | ns/op |
| --- | --- |
| `box, straddling 11x2` | 152,932 |
| `eliminationOrder, mixed 14x2` | 140,342 |
| `box, mixed 14x2` | 124,597 |
| `bounds k=1, straddling 11x2` | 88,369 |
| `bounds k=0, mixed 14x2` | 75,219 |

`eliminate k=0, 6 rows x 4 vars` stands at 62,634 ns/op, and that is the step-2
capture. It was not re-measured in round 2, which is why it carries no
before/after row there; do not read it as current, and do not read it as proof
that round 2 left the small-system path alone.

The handover's earliest figure of "about 16.3 ns/op" for a plain `Interval.add`
was wrong, and the correction to it was also taken under load. Both are inside
the band of what a shared machine does to a cheap row; neither is a claim.

### Step 3 — Check the harness before trusting any number — DONE, two defects found

No row reported `ns/op` of exactly 0, so nothing was being elided. The
checksums are byte-identical across two independent runs, so the harness is
deterministic in what it computes. Two real defects turned up, and a third
problem showed up only in the figures themselves.

**Defect 1, fixed: a use-after-free in the allocator benchmark.**
`bench/bench_vec.zig` read `p[0]` into the sink AFTER freeing the allocation.
The `smp_allocator` happened to leave the byte intact, so the rows looked
plausible and printed `checksum 0` for work that had plainly happened; the
`DebugAllocator` poisons freed memory, so that row died with `SIGSEGV` and took
the whole `bench-vec` run with it. This is why `bench-vec` had never been seen
to finish. The read now happens before the free.

**Defect 2, fixed: the run total was a hard-coded zero.**
`bench/timing.zig` printed `checksum 0` from `@as(f64, 0)`. It now accumulates
every body's sink — as a sum of BIT PATTERNS, not of values, because these
operations legitimately return unbounded intervals and a floating-point total
collapses to `inf` on the first of them and then reads `inf` forever after. A
constant cannot distinguish "the work ran" from "the work was elided".

**Problem 3, fixed in the benchmark: the DynVec figures measured the allocator,
not the library.** The `DynVec` environments were built on a `DebugAllocator`,
so every value-returning row was dominated by an 11,146 ns round trip against
`smp_allocator`'s 30.5 ns. The reported "DynVec is 757x slower than
`Vec(2).add`" was that ratio, not a property of the code.

`bench_vec.zig` now builds both allocators, measures all nine value-returning
bodies under each, suffixes every row with `.smp` or `.dbg`, and prints a table
of how much of a value-returning call is the allocator. Measured, and verified
by re-running `bench-vec`:

| box | round trip smp | round trip Debug | `add` value smp | `add` value Debug | % allocator smp | % allocator Debug |
| --- | --- | --- | --- | --- | --- | --- |
| 2 comp (32 B) | 17.68 | 5,784.86 | 26.27 | 6,793.16 | 67.3 % | 85.2 % |
| 4 comp (64 B) | 30.54 | 11,146.47 | — | — | — | — |

Under the allocator the hot path actually uses, a value-returning `DynVec` add
at dimension 2 costs 26.3 ns against `Vec(2).add` at 10.8 ns — a gap of about
2.4x, not 757x. The DebugAllocator figures are kept alongside, because they are
the honest answer to what checking every allocation costs; they were simply
being quoted as the cost of the library.

That investigation also found a labelling bug of the same kind: the `ops` table
hand-classified `contains` and `distance` as value-returning when both return a
scalar and never allocate, which printed them beside neighbours at 11,000 ns.
They now sit in their own `no-alloc` column.

**Problem 4, measured and NOT fixable in code: the noise floor.** See the table
at the end of step 4. Cheap operations move by up to 44 % between two runs with
nothing changed. That is a property of a shared machine, not of the harness,
and it bounds what any future "faster by X %" claim can mean.

### Step 4 — Profile, then rank by measurement — DONE, with verdicts

Every hypothesis was settled against source plus emitted assembly, and the
measured baseline confirms or corrects each one. Ranked by what is actually
worth attacking, largest first. **The verdicts have not changed. The evidence
has:** each measured figure is now the idle-machine figure, or is explicitly
marked as an older capture that nothing has superseded, and a row that clears
the noise band says **CLAIMED** while one that does not says **NO CLAIM**.

The instruction counts come from a throwaway probe, and the probe is written
down because a reader who cannot reproduce it cannot check them. Four `export
fn` wrappers calling one operation each, `f64` in and an out-pointer for the
`[2]f64` result, compiled ReleaseFast against `src/root.zig` with `-femit-asm`,
then each wrapper's assembler body counted line by line:

```sh
(
  : "${SCRATCH_ROOT:?resolve a local scratch root first — see section 0}"
  mkdir -p "$SCRATCH_ROOT/icount"
  zig 0.16.0 build-obj -OReleaseFast --dep interval \
    -Mroot="$SCRATCH_ROOT/icount/probe.zig" -Minterval=src/root.zig \
    -femit-asm="$SCRATCH_ROOT/icount/probe.s" \
    --cache-dir "$SCRATCH_ROOT/icount/cache" \
    --global-cache-dir "$SCRATCH_ROOT/icount/gcache"
)
```

`Interval` cannot cross the C ABI, so the wrapper takes and returns `f64`s.
The counts include cold paths, so they rank cost badly and are not a cycle
model; what they are good for is saying whether an operation got simpler. Run
against the pre-round-2 tree at `85f85922` with the identical probe they
reproduce the older figures in this table almost exactly — `mul` 209, `div`
167, `add` 60 — which is the check that this is the recipe that produced them.
One caveat, so the numbers are not over-read: LLVM inlined `div` into its
wrapper this time and outlined it last time, so `div`'s 167 -> 206 is two
different bodies and not a like-for-like delta. `mul` and `add` were emitted
the same way in both.

| Rank | Hypothesis | Verdict | Evidence | Action |
| --- | --- | --- | --- | --- |
| 1 | the final round inside `bounds` | **CONFIRMED, largest win** | creates ~99.8 % of every row `bounds` allocates, for a contradiction test only; `mixed 6x4` sweep is 6 -> 11 -> 26 -> 486 -> 223,269. **CLAIMED**: `box, straddling 11x2` is **152,932 ns/op**, from 2,088,773 at the step-2 capture and 301,609 at the start of round 2; `bounds k=1, straddling 11x2` **88,369**, from 1,005,474 and 161,917 | done in step 5; round 2 took two more passes at the solver, in "Round 2" below |
| 2 | `scale` composes through other ops | **CONFIRMED** | 6 outward-widening steps per endpoint on the finite path, 8 on overflow, and **the step count has not changed** — round 2 kept every step and cut the price of one. Body 345 instructions with 8 out-of-line calls before round 2, 6 of them to `div`; 576 with 2 calls after, because those six calls are gone. `mul` 209 -> 220, `div` 167 -> 206. **CLAIMED**: **47.795 ns/op** against **80.551** at the start of round 2, **-41 %**, and 5.0x `mul` and 3.1x `div` | the widening is deliberate and documented, so this is a design cost, not a bug. Round 2 added `Interval.halve`, which divides by two directly and repairs only the one endpoint whose half is a lost magnitude. The algebraic reformulation that drops two operations was tried, measured unsound, and withdrawn; see section 9 |
| 3 | `DynVec` allocates per value-returning op | **CONFIRMED, and the benchmark was lying about it** | 1000 calls of `add` = 1000 allocations / 64 KB; `iadd` = 0. The measured "DynVec is 757x slower than `Vec(2).add`" was an artefact: those rows run on a `DebugAllocator`, whose round trip is 11,146 ns against `smp_allocator`'s 30.5 ns | the real user-facing cost is one allocator round trip per call, ~30 ns under `smp_allocator`. A caller writing `dv = dv.add(other)` in a loop also LEAKS the previous box unless it is freed first. Step 3 fixed the benchmark to measure both allocators. The library side is unchanged and nothing here has superseded these figures |
| 4 | `Corner` struct cost in `mul`/`div` | **CONFIRMED but misdiagnosed** | the four `f64` corners scalarise into XMM registers with no stack traffic. The real cost is the `undersized: bool` side channel: 4 byte stores plus 3 UNCONDITIONAL reloads in `mul`, and 4 dead stores in `div` | the reloads sat **above** the `v == 0.0` guard, so they carried data that is dead unless the extremum is exactly zero. **Fixed in round 2**: the flag is lazy, `Corners.undersizedAt` asks the question only after the reduction has come back a zero, and the operands are read then rather than spilled beside the values. **CLAIMED**: `mul` **9.639 ns/op** against **11.062**, **-13 %**, which clears the band |
| 5 | `powf` composes `exp(log(base)*y)` | **CONFIRMED, do not change** | depth 7 interval operations, 6 stack frames, 4 envelope calls, zero allocations. Measured **272.5 ns/op** on the step-2 capture, the most expensive operation in the library, 2.5x `ext.pow` | deliberately traded for soundness. Quantified, as asked; not a defect, and not re-measured because neither round touched the elementary functions |
| 6 | `roundUp`/`roundDown` cost a call | **REFUTED** | at ReleaseFast LLVM inlines all four rounding primitives: zero `call` instructions, zero standalone bodies. A `noinline` control differing only by the attribute produced 4 real calls in the same probe, so the probe could detect one | no action |
| 7 | `eliminationOrder` clones per step | **REFUTED as stated** | it clones exactly ONCE, before the loop. The real per-step cost is that `eliminate` rebuilds the whole coefficient table each step, O(R_t * m) bytes, and `chooseNext` costs O(m^2 * R) over the whole loop | the clone is not the problem; the rebuild and the pair-count scan are. Round 2 removed the regrowth half of the rebuild by reserving the exact final capacity, and left the pair-count scan alone |

Three things this table says that the hypotheses did not. First, the ranking by
measured cost and the ranking by "obvious waste" are different: the obvious one,
missing `inline`, is the cheapest item on the list and is already free. Second,
`box` is `m` clones and `m * m` eliminations, so the biggest single lever in
the solver is not any one operation but that `box` re-derives every projection
from scratch. Third, and this is the one a later session should carry forward:
every CONFIRMED row now has an answer. Two were fixed in round 2, rows 2 and 4.
One was fixed in step 5, row 1. One turned out to be a benchmark defect rather
than a library defect and was fixed in step 3, row 3. One is a deliberate
soundness trade and is not being changed at all, row 5. **What is left on this
list is nothing**, which is why the ranked work lives in
`docs/next-work-plan.md` and not here — and that document has since closed too.

### Noise floor, measured — read this before believing any delta

Two runs of `bench-scalar` on the pre-round-2 tree, same binary, same machine,
nothing changed:

| Operation | Run 1 | Run 2 | Delta |
| --- | --- | --- | --- |
| `interval.scale` | 88.259 | 89.925 | +1.9 % |
| `interval.recip` | 8.316 | 8.387 | +0.9 % |
| `interval.abs` | 5.899 | 5.917 | +0.3 % |
| `interval.add` | 6.335 | 8.468 | +33.6 % |
| `interval.expand` | 6.298 | 8.594 | +36.5 % |
| `interval.mul` | 13.739 | 19.775 | +43.9 % |

The second run was taken with other benchmarks compiling and running on the
same machine. Every per-measurement checksum was byte-identical across the two
runs, so the harness is deterministic in what it computes and noisy only in what
it costs. `bench/timing.zig` reports the minimum over 7 repetitions, which is
stable for the expensive rows and not for the cheap ones.

**The band was confirmed a second time, and it is the reason five of the seven
interval rows in the round-2 table are marked NO CLAIM.** A cheap operation is
not a small number on a shared machine; it is a number with an error bar wider
than most optimisations.
Both rounds of results below were therefore taken on an
**idle** machine, three runs each, comparing minima, and a row is only called a
result when the delta clears the band. `scale` at -41 % and `mul` at -13 % clear
it. The other five do not, and they are recorded as **NO CLAIM** rather than as
small wins: `div` -1.8 %, `add` -1.0 %, `sub` +0.6 %, `sqr` -0.2 % and `abs`
-0.3 %. A reader who takes `div`'s 0.289 ns as an achievement is wrong, and the
honest statement is that round 2 did not move it and did not prove that it did
not.

**Consequence: a change to any operation under about 10 ns/op cannot be claimed
from a single pair of runs on a shared machine.** Take the measurement on an otherwise
idle machine, or take three runs and compare the minima. The cheap rows are
where an optimisation is most tempting and where the evidence is weakest.

### Step 5 — The last round of `bounds` — DONE, 3.2x to 8.2x

`bounds(k)` eliminated every variable except `k`, read the bounds, and then
eliminated `k` as well, because that was the only way a contradiction among the
surviving rows became visible. That last round created about 99.8 % of every
row the call allocated, and all it produced was a contradiction test.

It is now `System.derivesContradiction(k)`, which answers the same question
without building a row. `appendCombined` was split into `combinedColumn` and
`combinedBound`, which both the elimination and the predicate now call, so the
two ask the identical question of the identical values rather than two
lookalike copies of it.

How it avoids the materialisation:

1. One `O(rows * var_count)` pass fills a fixed scratch with, per row, the
   multiplier part it would carry into each bucket — derived exactly as
   `eliminate` derives it — plus whether the row is the exact `[0,0]` in every
   column except `k`, and whether that multiplier part is itself exactly `[0,0]`.
2. Per pair, a cheap necessary condition on the bound goes first. Because the
   buckets guarantee `upper.coeff >= 0` and `lower.coeff <= 0`,
   `bound.hi` is at least `upper.coeff.hi * max(lower.rhs) - lower.coeff.lo *
   min(upper.rhs)`, so a pair whose plain-`f64` comparison is already `>=` cannot
   fire and is skipped with two scalar multiplications. The comparison is `>=`
   rather than a subtraction on purpose: a difference that overflows to an
   infinity falls through to the exact path instead of being silently dropped.
3. The four-case filter then settles most of the rest: both multipliers exact,
   lower exact and lower flat, upper exact and upper flat, or both flat. Each
   forces every combined column to the exact zero.
4. Any pair the filter does not settle is measured column by column through
   `combinedColumn`, and survivors get the exact `combinedBound(..).hi < 0`
   test. This step is not optional: the filter admits the case where a product
   underflows, and dropping it would change an answer silently.

Measured, ReleaseFast, on an otherwise idle machine, the LP
rows that call `bounds`. **These are the numbers for this change and not the
current ones**; the current figures are in step 2 and the round-2 deltas are
below.

| Row | Before | After this change | Speedup |
| --- | --- | --- | --- |
| `box, straddling 11x2` | 2,088,773 | **255,232** | **8.2x** |
| `bounds k=1, straddling 11x2` | 1,005,474 | **139,464** | **7.2x** |
| `box, mixed 14x2` | 540,427 | **154,597** | **3.5x** |
| `bounds k=0, mixed 14x2` | 294,283 | **92,762** | **3.2x** |

Rows that do not call `bounds` moved too, in the direction the noise floor
allows and no further: `eliminateAll ascending` 586,391 -> 270,589,
`eliminationOrder` 238,314 -> 215,415, `eliminate k=0` 62,634 -> 50,938. None of
those is claimed as an improvement; they are inside the band the machine
produces with nothing changed.

Verification, all run after the change:

- `zig build test` green in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall,
  each ending `consumer ok: 29 checks`, with the soundness oracle reporting
  `0 FAILED` on all eight operations it covered at the time. **It now covers
  35**; see section 2.
- `bench-lp`'s geometry report byte-identical to before, including every
  predicted-against-achieved pair (11/11, 2/2, 4/4, 48/48, 121/121). The first
  round is untouched by construction; the change removes work that happens
  after the projection has been read.
- `bounds` returns a bit-identical interval on 7,700 generated systems across
  two build modes, covering mixed point coefficients, straddling coefficients,
  coefficients that merely reach zero, satisfiable systems, contradictory
  systems, and systems where the old final round fired.
- Four characterisation tests in `tests/lp_test.zig` pin the behaviour in both
  directions, and each was proven to fail under the corresponding mutation
  before the change was made: deleting the final round fails "a contradiction
  only the last round can see is still reported" and "one unit of slack
  separates the empty system from the feasible one"; loosening the contradiction
  predicate to `rhs.hi <= 0` fails "the same system one unit away is not a
  contradiction" and "one unit of slack separates the empty system from the
  feasible one". Those tests are the reason this change was admissible rather
  than merely measured. Cite them **by name**: the file has grown since, and
  the line numbers in the previous revision of this document had already gone
  stale.

**One adjacent idea remains ruled out and should not be attempted.** Stopping
after `n - 1` variables, as a textbook Fourier–Motzkin loop does, is still not
available. `eliminationOrder` is contractually a full permutation
("eliminationOrder is a permutation with no repeats"), the final row count is
pinned ("Tupper's order does measurably less work than the mirror order", which
asserts 5 rows in, 1 out, and the shipped path's final count equal to the
planned one), and the all-zero rows the last round produces are the shape the
contradiction tests read. Removing the round changes observable behaviour, so it
is a different function. Section 9 records it again, with the rest of the
withdrawn list.

### Round 2 — what changed after step 5, and what it bought

Four changes, each measured on its own, all landed. ReleaseFast, **idle
machine**, three runs each, comparing minima. The Claim column is the point of
the table: five of the seven interval rows do not clear the noise band and are
recorded as not being results, even though every one of them did go down.

Interval, ns/op:

| Operation | Before | After | Delta | Claim |
| --- | --- | --- | --- | --- |
| `interval.scale` | 80.551 | **47.795** | **-41 %** | **CLAIMED**, far outside the band |
| `interval.mul` | 11.062 | **9.639** | **-13 %** | **CLAIMED**, clears the band |
| `interval.div` | 15.754 | 15.465 | -1.8 % | **NO CLAIM**, inside the band |
| `interval.add` | 5.078 | 5.027 | -1.0 % | **NO CLAIM**, inside the band |
| `interval.sub` | 5.076 | 5.108 | +0.6 % | **NO CLAIM**, inside the band |
| `interval.sqr` | 4.818 | 4.807 | -0.2 % | **NO CLAIM**, inside the band |
| `interval.abs` | 4.149 | 4.138 | -0.3 % | **NO CLAIM**, inside the band |

**`scale`: the two `div(two)` halvings became `Interval.halve`.** `scale` needs
the midpoint and the half-width of the box, and it was getting each by dividing
an interval by the point 2 — the whole four-corner quotient machinery, both
bounds, and the underflow repair, as `scale`'s own doc comment puts it, "three
times over, to divide by the one constant the format can answer exactly". The
emitted body agreed: eight out-of-line calls, six of them to `div`. `halve`
divides by two directly and repairs only the one endpoint whose half is a lost
magnitude: a lower bound steps down, an upper one steps up, and an endpoint
that is itself an exact zero halves to an exact zero, which is already its own
bound. **The widening-step count is unchanged at 6 per endpoint.** What changed
is the price of a step, and that is the whole result: the same guarantee, a
shorter path, 41 % less time.

**`mul`: the `undersized` flag became lazy.** `Corners` used to carry an
`undersized: bool` beside the four values. Four `f64` scalarise into registers;
four bytes do not, so the flag became four byte stores and three UNCONDITIONAL
reloads sitting *above* the `v == 0.0` guard, carrying an answer that is dead
unless the reduced extremum happens to be exactly zero. The flag is gone. The
operands are read, by `Corners.undersizedAt`, at the one moment they are
needed: after the reduction has come back a zero. The dead stores in `div` went
with it.

LP, ns/op, same conditions:

| Row | Before | After | Delta | Claim |
| --- | --- | --- | --- | --- |
| `box, straddling 11x2` | 301,609 | **152,932** | **-49 %** | **CLAIMED** |
| `bounds k=1, straddling 11x2` | 161,917 | **88,369** | **-45 %** | **CLAIMED** |
| `eliminationOrder, mixed 14x2` | 227,450 | **140,342** | **-38 %** | **CLAIMED** |
| `box, mixed 14x2` | 171,663 | **124,597** | **-27 %** | **CLAIMED** |
| `bounds k=0, mixed 14x2` | 100,410 | **75,219** | **-25 %** | **CLAIMED** |
| `bench-lp` total wall time | 21.8 s | 18.5 s | -15 % | **CLAIMED** |

These rows are all far outside the band, and for a structural reason rather
than a lucky one: a row that eliminates tens of thousands of rows is not a
cheap row, and the 44 % the noise floor produces is a property of rows that
finish in nanoseconds.

**The `cancelsExactly` pre-filter.** `cancelsExactly` decides whether a pair of
products cancels to the structural exact zero, and the D4 repair made it decide
on the operands in `f128` — a sound place to decide it, and an expensive one.
The old equality could only ever close when **both** products were point
intervals, so on every column of every pair the eight `f128` soft-float
multiplies were being paid to compute the answer "no". Round 2 puts a cheap
`f64` filter in front: build the same four corners as `doubleProduct`, rounded
to nearest, and if the two rounded hulls do not coincide the exact ones cannot.
Rounding to nearest is monotone, so the minimum of the rounded corners is the
rounding of the minimum, and two hulls that coincide exactly cannot differ
after rounding. Only the pairs that already agree pay for `f128`.

**The `eliminate` capacity reservation.** `eliminate` knows the exact final
row count before it starts and was growing its two output lists geometrically
to reach it. It now reserves the exact capacity once, up front, with the
multiplication guarded against overflow. On the `mixed 6x4` sweep a single
`eliminate` call emits 223,269 rows, and every regrowth-and-copy pass on the way
there is gone.

Verification for round 2, all run after both solver changes:

- An 80,000,000-quadruple differential fuzz of the new predicate against the
  old one: **0 mismatches**.
- Every `bench-lp` checksum line identical to the run before, and the geometry
  report byte-identical, predicted == achieved on every branch.
- `zig build test` green in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall,
  each ending `consumer ok: 29 checks`, oracle `0 FAILED` on every operation it
  covers.

**What round 2 did not buy, and the one reformulation that looked like a win and
was not, are both in section 9.**

### Step 6 — Optimise, one change at a time, with a measurement for each

For every change: re-run the benchmarks, and report the before/after for the
operations the change touched. A change that makes one operation faster and
another slower is a decision to make deliberately, not a win.

### Step 7 — The soundness gate. This is not optional and not negotiable.

The oracle computes true extrema from the ORIGINAL `f64` inputs — exact products
in `f128`, exact sums through a `TwoSum` residual rather than through a rounded
`f128` sum, quotients by cross-multiplication — and checks containment. It
exists because a previous audit found four soundness defects that 200 tests
and 29 consumer checks all passed, and
because D1 survived all of them: a defect that a suite never looks for is not a
suite that passed.

**The gate grew with the work and is now much wider than it was.** It covers 35
of the 56 public operations rather than 8, it reports `0 skipped precondition`
for `div` and `recip` where it used to report 2,040 and 2,163, and it grew a
directed infinity frontier sweep that judges **thirteen** operations at a shape
the random layer screens out, six of them newly judged rather than withheld.
The other twenty-one operations in `src/interval_ext.zig` are not judged by this
oracle at all; they are covered by the MPFR corpus tier, which is a separate
build artifact over a committed reference file. Section 2 has the full picture.

**Every optimisation must leave it green.** It is the only thing standing
between a faster library and a wrong one.

```sh
zig build test
```

If an optimisation makes it fail, the optimisation is wrong. Do not relax the
oracle to accommodate a speedup. If you believe the oracle is wrong, prove it
against `tests/soundness_shared.zig` plus a throwaway `f128` check of your own
before changing anything.

### Step 8 — Full verification, then commit

```sh
zig build test                                          # all suites + consumer
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build test -Doptimize=ReleaseSmall
zig build docs
zig fmt --check build.zig build.zig.zon src tests fixture
```

Also run the local cross-target soundness gate:

```sh
cross-test --jobs 8 --build-jobs 2
```

Inspect its summary and target logs. A build-only target or
`no_test_results` is not runtime soundness evidence. MIPS32 execution
found subnormal `div` and `recip` failures that native tests missed:
Zig 0.16's `__divdf3` flushes subnormal quotients. `cornerQuotient` now
recovers them with exact power-of-two scaling before the usual outward
step. Runtime-input regressions cover the witnesses, the normal/subnormal
transition, half-way rounding, deep underflow, and both operand signs.

The build also passes the `cross-test` QEMU runner to the NaN and ownership
child probes. The x86-linux test parent ran under QEMU there, but
direct child execution failed without a kernel binfmt handler. Both probes
now use the explicit runner and keep their existing control and trap checks.

Windows runtime coverage now exists for the ownership revision. On 2026-10-04,
Wine 11.0 ran all 357 `x86_64-windows` root tests and both Windows consumer
executables. [Section 10](#10-ownership-revision-verification-and-exact-scale-trial--2026-10-04)
records the target, modes and limits. Wine is not a native Windows host.
WASI runtime coverage is still unverified. Build-only evidence is build-only.

Then commit, and move `main`.

## 4. Hard constraints

1. **Soundness outranks speed.** A result that can be too narrow is worse than
   a slow result. When the two conflict, the oracle decides and speed loses.
2. **Do not change numerics to gain speed.** A faster path that computes
   something slightly different is a different function, and the guarantee is
   about the function as specified.
3. **Benchmarks are ReleaseFast only.** Debug numbers for an assert-heavy
   numeric library mostly measure the asserts.
4. **Keep `nextUp`/`prevDown` as the strict neighbours.** They are used where a
   strict neighbour is genuinely wanted. `roundUp`/`roundDown` are the
   outward-rounding forms and differ from them at exactly the signed zeros.
5. **Do not "simplify away" the widening.** The extra ULP of width is the price
   of soundness and is deliberate. It looks like waste and is not. For the
   elementary functions it is now THREE ULP, and the count is the auditable
   artefact: it is one number, one place, one table of measured margins per
   primitive. It was two, and a real defect got through — `tanh` reaches 2.14
   ULP on the primitive, so a two-step bound can exclude the true value. If you
   are tempted to narrow it, read the table first.
6. **Do not remove the straddling duplication in `eliminate`.** It is the reason
   the result is a guaranteed superset. It is also the reason the row count
   explodes. Both facts are true; only one of them may be optimised away.
7. **Never run an LP benchmark without a row budget.** Row explosion is unbounded
   and a benchmark machine is shared with other people's work; a single
   unbounded `zig build bench` can take the machine with it.

## 5. Toolchain gotchas — these cost real time to rediscover

All verified empirically against the pinned 0.16.0 toolchain.

- `std.time.Timer` **does not exist** in Zig 0.16. Timing is
  `std.Io.Clock.real.now(io)`, which returns a plain `Timestamp` (no error
  union — do not `try` it). Get an `Io` with
  `std.Io.Threaded.init(gpa, .{})` then `threaded.io()`. Passing `std.Io` as a
  `main` parameter is **not** supported (`start.zig` wants an `Io.minimal` field
  that does not exist).
- `std.ArrayList` is **unmanaged**: `std.ArrayList(T){}` / `.empty`,
  `append(gpa, x)`, `deinit(gpa)`. There is no `.init(gpa)`.
- On a `*System`, `sys.varCount()` does not resolve; use `sys.*.varCount()`. A
  field read such as `sys.*.var_count` takes no parentheses.
- A labelled block is `blk: { ... break :blk value; }` — the break label is the
  block label, not the name of the value.
- `**` is **array repetition**, not exponentiation. Use `std.math.pow`.
- `2.0 ** -38` will not compile; `std.math.pow(f64, 2.0, -38)` will.
- `@field` is lowercase. `@Field` does not exist.
- `std.fs.File` does not exist; use `std.debug.print`.
- `std.math.maxFloat` does not exist; it is `std.math.floatMax`.
- `2.0 ** 3` and the `-38` literal both go through `std.math.pow`; several
  `@builtins` that used to exist (`@cbrt`, `@expm1`, `@log1p`, `@asin`,
  `@acos`, `@atan`, `@sinh`, `@cosh`, `@tanh`, `@asinh`, `@acosh`, `@atanh`)
  are not builtins in 0.16 — use `std.math.*`.
- `f80` is portable (emulated on aarch64 and riscv64), so it is safe in tests
  when `f64` lacks the precision needed.
- The `zig` on PATH may be a version-manager shim: a bare `zig build-exe`
  outside a directory with a `build.zig.zon` fails with "no build.zig to pull
  a zig version from". Use `zig 0.16.0 build-exe ...`, and give every
  `build.zig.zon` a `.minimum_zig_version` or it exits 1 silently.
- To build a throwaway program against the library without touching
  `build.zig`, register the module on the command line. `-M` takes one module
  per compilation, so this never collides with the build graph:

  ```sh
  (
    : "${SCRATCH_ROOT:?resolve a local scratch root first — see section 0}"
    mkdir -p "$SCRATCH_ROOT"
    zig 0.16.0 build-exe -OReleaseFast --dep interval \
      -Mroot="$SCRATCH_ROOT/probe.zig" -Minterval=src/root.zig \
      -femit-bin="$SCRATCH_ROOT/probe" \
      --cache-dir "$SCRATCH_ROOT/probe-cache" --global-cache-dir "$SCRATCH_ROOT/probe-global-cache"
  )
  ```

  Give a throwaway its own cache directories, and not to keep it off the shared
  one out of fear: a second writer contends on the same manifests and the build
  gets slower, which is a different problem from the one that produced this rule.
- A file may belong to only **one** module per compilation. Registering a
  second module for a file another module already reaches by relative import is
  a hard "file exists in modules" error. This is why `bench/timing.zig` is
  reached by relative import rather than registered, and why the benchmarks do
  NOT take a second registration of the public module — that used to be the
  stated reason, and it was **false on both counts**: the rule does not require
  it, and the measured evidence is that it did nothing. A compilation is
  compiled in the mode of its **root** module; a module's own `.optimize` only
  decides what `builtin.mode` reads inside that module. Measured on 0.16.0 by
  building both ways and hashing: **byte-identical benchmark binaries**. Pin the
  root module, which each of the three benchmark executables already does.
- The `consumer` build step shells out to a nested `zig build` with private
  `--cache-dir` / `--global-cache-dir` and `setCwd`. **Those private caches are
  not a deadlock workaround — there is no deadlock to work around.**
  `Cache.Manifest.hit` locks ONE manifest at a time, with `lock_nonblocking =
  want_shared_lock` defaulting to a shared lock, so a parent and a nested build
  can share one global cache; dropping both flags was measured and the step
  finishes in the same time with the same `consumer ok: 29 checks`. They are
  kept for containment: both paths are ABSOLUTE and are named by
  `consumerCacheRoot`, so the nested build's cache output never joins the
  machine-wide global cache this build shares with every other project.
  Containment used to be RELATIVE paths, resolved against the working directory
  the step sets, which put that output in `fixture/.zig-cache` — over 100 MB as
  it was measured, and inside the working tree.
  The consequences that bit were two: `fixture` is a recursive `.paths`
  entry in `build.zig.zon`, so hashing or fetching the package walked all of
  it; and the fmt and lint sections walked
  it too, reporting the compiler's own generated `builtin.zig` and
  `dependencies.zig` as defects. **Where the root lands is
  `consumerCacheRoot`'s decision, and read it rather than assume it:** an
  explicit `ZIG_INTERVAL_CONSUMER_CACHE` wins, and otherwise the nested build
  follows the parent build's own cache directory, which can be inside the
  repository. The first `zig build test` is still slow
  on a cold cache; later runs are fast. That is
  not a problem to fix.
- A struct with automatic layout cannot cross the C ABI, so a throwaway that
  wants to export an `Interval` has to take and return `f64`s instead, and an
  array is not an allowed return type either — use an out-pointer. This bites
  an `export fn` in a `-femit-asm` probe; a `pub fn` called from the same file
  never notices.

## 6. How to check the tree is healthy

```sh
# from the repository root
zig build test        # exits 0, ends with "readme examples ok: 31 checks"
zig build bench-lp    # safe: the row budget bounds it, and the scalar and vector
                      # halves dominate the combined `zig build bench`, not this one.
jj status
jj log -r main --no-graph -T 'commit_id.short() ++ "  " ++ description.first_line() ++ "\n"'
```

The gate is not on `PATH` and this file will not pretend otherwise. Install it
once, then run it from the prefix, exactly as `.vf/gates.yml` does:

```sh
. scripts/scratch.sh || exit 1
scratch_init quality-build || exit 1
export QUALITY_TOOLS_WORK_ROOT="$SCRATCH_DIR"
export QUALITY_TOOLS_PREFIX="$SCRATCH_ROOT/quality-tools"
export ZIG="$(zig 0.16.0 env | awk -F '"' '/\.zig_exe =/ {print $2; exit}')"

# all three absolute; the first two local, writable and yours. SCRATCH_ROOT comes
# from scripts/scratch.sh and section 0 has the rule behind it.

bash scripts/install-quality-tools.sh \
  --prefix "$QUALITY_TOOLS_PREFIX" \
  --work-root "$QUALITY_TOOLS_WORK_ROOT" \
  --zig "$ZIG"

"$QUALITY_TOOLS_PREFIX/bin/zig-gate"        # the required acceptance gate, and
                                           # the command .vf/gates.yml runs.
                                           # Budget tens of minutes: its last
                                           # section BUILDS AND RUNS the suite
                                           # for four foreign targets.
                                           # `--no-cross` skips that one. See
                                           # the gate section in section 2.
```

After an install, the prefix re-hashes against its own manifest — read-only, and
the check the 2026-10-02 receipt in section 2 reports:

```sh
( cd "$QUALITY_TOOLS_PREFIX" \
    && awk -F'\t' '!/^#/ && NF { print $8 "  " $7 }' install-manifest.tsv \
    | sha256sum --check --strict - )
```

Re-run only the install when the prefix is missing or `--force` is wanted; a
second install over a live prefix is not transactional, and the section 2 gate
prose says exactly what a failed one leaves behind.

The working copy is not expected to be dirty, and what the table at the top of
section 2 records is committed and pushed — but read that from the version
control rather than from this file, which goes stale at the next commit and is
in it. `jj status` names the working-copy commit and anything uncommitted in
front of it, `jj log -r main` and `jj log -r main@origin` say whether the
bookmark and its remote agree, and `jj diff --stat` says what is in that commit.

## 7. Orientation for a first look

Read in this order if you have time for only one thing:

1. `src/rounding.zig` — small, and it explains the whole rigor model.
2. `tests/soundness_shared.zig` — the oracle's vocabulary, and its `Op` enum names
   which of the 56 audit-set operations the oracle reaches; `tests/corpus/elementary.txt`
   is the committed half of that coverage, read by `tests/corpus_test.zig`.
   The four files beside it are the four concerns. It is why the rest is
   trustworthy, and it is the first place to look before optimising anything.
3. `bench/timing.zig` — why the numbers mean anything.
4. `src/interval.zig` — where the hot operations live, and `Interval.halve` is
   the one private helper round 2 added.
5. `src/lp.zig` — `System.eliminate` and `System.bounds`, the two places the
   row explosion comes from, and `System.derivesContradiction`, the predicate
   that replaced `bounds`' final round.

Cite these by name, not by line number. The line citations in the previous
revision of this document had already drifted by the time it was superseded.

The current measured figures are not in this file's tables. They are in
[`docs/performance-baseline-2026-10-02.tsv`](performance-baseline-2026-10-02.tsv)
— all 362 rows, three `ns/op` values each — and the two Wave 2 sections in
section 2 that introduce it say what was measured, what was checked, and what
the file does not establish. The one trial figure set is in
[`docs/performance-trial-2026-10-02.tsv`](performance-trial-2026-10-02.tsv) —
all 52 rows, baseline and candidate — and its outcome is **REJECTED**; read the
Wave 3 section in section 2 for the three paired rows and the three criteria
that failed, not this file's prose for a speedup.

## 8. What not to do

- Do not optimise before the baseline exists. It does now: see step 2, and for
  the current dated capture see the Wave 2 section and its TSV.
- Do not reintroduce a row budget below 20,000 rows, or raise any benchmark
  size past what the budget allows without re-measuring the sweep that
  `requireRowBudget` guards in `bench/bench_lp.zig`. The budget is what stops
  this benchmark from allocating without bound on a shared machine again.
- Do not wrap `zig build` in `ulimit -v`. The compiler inherits the limit and
  dies with OutOfMemory before any benchmark row runs.
- Do not touch the soundness oracle to make an optimisation pass.
- Do not "fix" the straddling duplication in `eliminate`. It is the guarantee.
- Do not report a cheap operation's delta as a result. Five of the seven
  interval rows in the round-2 table did not clear the noise band and are
  recorded as NO CLAIM for exactly that reason.
- Do not quote the 2026-10-02 TSV as a speedup, or as a delta against the
  2026-09-30 tables in section 3. It is one capture on an unpinned shared machine,
  the two dates are not a before/after pair, and a perf percentage is sample
  attribution rather than time.
- Do not carry the RHS-first `checkRowForContradiction` guard into the tree
  because a profile named it, or because this file still describes the
  selection. **It was trialled and REJECTED on 2026-10-02** — it was measured,
  it failed all three predeclared criteria, and it was removed again, so
  `src/lp.zig` is the original file. The rule it was selected under still
  governs any next candidate: a differential proof that every result, checksum,
  geometry report and accounting total is unchanged, plus repeatable
  baseline-and-candidate timing that clears a predeclared bar, and a rejection
  recorded as a rejection rather than explained away. An API, validation,
  retry, allocator, cache or layout change does not travel with one.
- Do not re-export or re-register modules; the "one file, one module" rule
  will fail the build and the reason is not obvious from the error.
- Do not remove the consumer step's private cache directories — not because
  removing them deadlocks anything, which it does not, but because they keep
  the nested build's output out of the machine-wide global cache every other
  project on that machine shares, and off the repository as well,
  which is where the relative form of those paths used to put 163 MB of it.
- Do not trust a number you did not re-run yourself. Benchmark agents reported
  results that were never independently confirmed.
- Do not quote a benchmark table you did not read back out of the file you
  captured. The report writer was positional until recently and lost rows when
  stderr was a regular file, with no error and no non-zero exit — so "it
  finished" was never evidence that the capture was complete. Redirect, then
  read the file. That is the whole finding, and it is why this rule is here
  rather than in the step-2 text alone.
- Do not treat a green `--verify-only` as a statement about an installed prefix.
  It hashes `tools/quality/` and nothing else, and reads no installed file. The
  prefix's own `install-manifest.tsv` is what carries a sha256 per installed
  file, and re-checking that list against the prefix is the check that answers
  the question. The two are not interchangeable and CI runs both.

## 9. Withdrawn, and not being done

Everything here was tried, measured, or argued, and then dropped. A later
session that re-derives one of these has saved itself the work, and the reason
is recorded so it does not have to be re-derived too.

| Item | Why it is not being done |
| --- | --- |
| the RHS-first `checkRowForContradiction` guard | **Tried as Wave 3, measured, and REJECTED with NO CLAIM.** Two guard lines ahead of the `isAllZero` test, the predicate exactly `rhs.hi < 0`, against a frozen baseline in three counterbalanced paired rounds on the predeclared primary row `eliminateAll chosen, mixed 14x2` at 200 iterations on `allocator=smp`. All **three** predeclared criteria failed: the median moved 2.19634548 % — below the 5 % bar, and not a speedup — only 2 of 3 pairs improved and the first was a 250.04 % regression, and the two three-run ranges overlap almost completely. The correctness half passed — bit-level state and boundary equality over 414 state cases and 23 boundary cases, 10,566 serialized words, 150 allocation-failure runs, both real consumers green on both sides, and three wrong-predicate mutants caught — which is why the rejection is about timing and nothing else. The lines were removed again, `src/lp.zig` is the original file at sha256 `40868f63…`, and no second candidate is queued. This says nothing about whether some other part of the solver is worth measuring; it says this one was not, and the profile percentages that suggested it are sample attribution, not time |
| `scale`'s algebraic reformulation | **Tried, and measured unsound.** Over the reals, `M - W = lo + (hi - lo)(1 - g) / 2` and `M + W = hi - (hi - lo)(1 - g) / 2`, so the sum that forms the midpoint and the midpoint itself can both be dropped and the composition loses two operations. Each arm is protective in ONE direction only, because the term's sign follows the sign of `1 - g`, which is a property of the caller's factor. A half-width enclosed too WIDE is subtracted on one arm and added on the other, and on the arm where it is subtracted it drags the bound inside the image. Two counterexamples, both measured: `[0, 2^-1074]` at factor zero has the exact image `{2^-1075}` and the short form answers `[0, -2^-1074]`, inverted; `[-floatMax, floatMax]` at factor zero has the exact image `{0}` and the short form answers `[-8.988e307, -floatMax]`, which excludes 0 outright. The reasoning and both counterexamples are in `src/interval.zig` beside `scale`. **Do not re-attempt it** |
| `div`'s round-2 delta | **Inside the noise band, so it is not a result.** Under a tenth of a nanosecond on a row a shared machine moves by up to 44 % with nothing changed. Round 2 did not move `div` and did not prove that it did not. The same applies to `add`, `sub`, `sqr` and `abs`; all five are NO CLAIM in the round-2 table |
| the straddling duplication in `eliminate` | **It is the guarantee.** A coefficient that straddles zero bounds its variable from below for its negative realisations and from above for its positive ones, and no single pairing is right for both. Dropping one of the two duplicates would discard a real constraint and cut the feasible set. Both facts are true: it is also the reason the row count explodes. Only one of them may ever be optimised away, and it is not this one. See hard constraint 6 |
| stopping after `n - 1` variables | **Pinned by tests.** `eliminationOrder` is contractually a full permutation, the final row count is asserted, and the all-zero rows the last round produces are the shape the contradiction tests read. Removing the round changes observable behaviour, so it is a different function, not a faster one |
| replacing `powf`'s composition | **A deliberate soundness trade, quantified rather than a defect.** `powf` composes `exp(log(base) * y)`, which is depth 7 interval operations, 6 stack frames, 4 envelope calls and zero allocations, at 272.5 ns/op. It was the most expensive operation in the library when step 4 measured it, and it is still more expensive than anything in the current tables. A hand-rolled version would be faster and would have to be argued sound endpoint by endpoint; the composition is the argument |
| the `log2` / `log10` subnormal claim | **An audit filed it and the claim was withdrawn.** It was checked and did not reproduce: the library contains the truth on the smallest subnormal and at the range boundary in every case tried. The apparent misses were an `f64`-computed reference compared against the library's elementary widening, which is the same reference mistake that would recreate D2 inside the oracle — and the same one that made the `tanh` defect of D17 look sound. Do not re-add it to an audit's list without a reference **finer than `f64`**. The clause this row used to carry — that `log2` and `log10` are "among the 21 operations with no containment oracle at all, which is the real reason the question is open rather than settled" — is superseded: the corpus tier now carries 15 rows for each of them against 256-bit MPFR brackets, among them `minsubnormal` and `floatMax`. The withdrawal still stands; the reason for it is no longer a coverage hole, it is the reference the audit used |
| the benchmarks' second private ReleaseFast module registration | **Dropped, and it was inert as well as unjustified.** It existed to pin the benchmark mode against a rule that does not require it, and building both ways gives the same binary. The rule that replaces it, and the measurement behind it, are in section 5; the short form is "pin the root module" |
| `ulimit -v` around `zig build` | **Wrong, and removed from an earlier draft of this file.** The compiler inherits the limit and dies with `error:OutOfMemory` while compiling, before a single benchmark row runs. If a memory limit is ever wanted it must wrap the emitted binary, not `zig build` |

The rule underneath all of these is constraint 2: a faster path that computes
something slightly different is a different function, and the guarantee is
about the function as specified.

## 10. Ownership revision verification and exact-scale trial — 2026-10-04

### Published ownership revision

`b9ed7e13281cfebaa67715e639ff85f5b491c1d3` contains the separate ownership
feature and planning-document commits. A local snapshot matched all 81 tracked
files before verification. The installed quality prefix was retained unchanged.

The complete `cross-compile.profile.sh` run used Zig 0.16.0, two target jobs
and one build job per target, pinned to CPUs 0–1. All **53 targets** built in
Debug. Every target log was checked, not sampled: 11 test binaries, one NaN
probe and one installed library per target. Totals: **583 test binaries,
53 probes and 53 libraries**. Summary: `pass=0`, `fail=0`, `build_only=53`,
`partial=0`. This is compilation coverage, not runtime evidence for 53 targets.

The same revision also ran on **`x86_64-windows` under Wine 11.0**:
**357/357 tests**, 27/27 build steps, no failed or skipped runtime step.
`--require-runners` was set. The root build's nested consumers are host
programs, so they were not counted as Windows consumers.

Both actual package consumers were then built for Windows in ReleaseSafe and
run with Zig's `-fwine` integration: **29 API checks and 31 README checks**,
5/5 build steps. The ownership transfer and optional-intersection examples
reported successful cleanup. These were Windows PE runs under Wine on Linux,
not native-Windows-host runs.

Wine and its harness utilities came through the approved Nix wrapper, with a
dedicated local `WINEPREFIX` and no display. The resolved Nixpkgs revision was
`c9fe7d12cd78d1adcd12dd15e24432dde5b155a0`. Wine's bootstrap reported missing
Fontconfig defaults and an unavailable 32-bit `rundll32`; the required 64-bit
runtime and both consumers completed. No site configuration was changed.

The published ownership revision's [GitHub Actions](https://github.com/CoffeeImpliesCode/zig-interval/actions/runs/37160213307)
completed all nine jobs successfully. That CI result is separate from the
local 53-target and Wine receipts.

Evidence root: `/tmp/scratch/zig-interval-six.vfU6fB0s`.
The immutable compilation run is `compile53/runs/20261003-232459-5499-13273`;
the Windows suite run is `windows-runtime/runs/20261003-233140-48464-16829`.
`task4-source-identity.tsv`, `task4-compile53.json`,
`task4-windows-runtime.json` and `task4-windows-consumers.json` bind the
observations to the published source. No numerical source change was needed.

### Exact-expansion `scale`: sound formulation, measured rejection

The follow-on trial uses exact binary128 products, four-component expansions,
`COMPRESS`, and zero-aware binary64 outward neighbors. It is not the rejected
rounded `M-W` shortcut. The full finite-range, subnormal, factor and ray proof
is in [scale-enclosure.md §10](scale-enclosure.md#10-exact-expansion-trial--2026-10-04).

The compiled research candidate passed 219,172 cases in each optimize mode
and 20,000 independent exact-rational comparisons. Nonfinite-input policy
delegates to the existing implementation; checked NaN refusal was exercised.
No permanent test or numerical API was added for this investigation.

Three counterbalanced ReleaseFast pairs on the existing 256-case scalar
workload gave medians **50.975 ns/op** for the composition and
**961.631 ns/op** for the candidate: **18.86× slower**. The predeclared 5%
improvement, three improving pairs and separated ranges in the improvement
direction all failed. The output-bit witnesses are stable within each path,
but are not equal across paths because the enclosures differ.

**REJECTED. Production `src/interval.zig` is unchanged. No performance
improvement is claimed.** All 42 timing samples, hashes, checks and the
predeclaration are in the scoped run's `task5-*.json` receipts.

### Deferred scratch cleanup

The user explicitly selected **“Defer cleanup; continue 4–6.”**
The earlier `zig-interval-gate.RXA5hj1K` run is retained at **936,886,272
allocated bytes**. Its audit found no foreign owner, submount or visible live
reference, but three owned services deny descriptor inspection and noninteractive
sudo requires a password. No deletion or signal was performed.
The installed quality prefix and verification evidence remain intact.
