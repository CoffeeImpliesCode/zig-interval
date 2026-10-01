# Provenance of the quality harness in this directory

Everything the gate runs is here, pinned and hashed, and nothing is fetched from
a developer's home directory or from a URL that can change under us. This file
says what each piece is, where it came from, what was changed to make it
distributable, and — the part that matters most — what is **not** established.

Read `manifest.tsv` for the machine-readable pins and `SHA256SUMS` for the
content hashes. This file is the reasoning.

## The shape of the problem

`zig-gate` and `cross-test` had no home. They lived in one person's
`~/.local/bin` and `~/.local/lib/cross-test`, nothing in any repository tracked
them, and `.github/workflows/ci.yml` said so in a block headed *REVISIT THIS
BLOCK WHEN THE HARNESS HAS A HOME*, listing exactly two ways to give it one: a
tagged upstream release, or a vendored copy reviewed into the tree.

There is no tagged upstream release. `cross-test --help` is its entire
documentation and its only home was a filesystem. So this is the second option,
done properly: reviewed sources in the tree, pinned analyzers built from
immutable upstream commits plus checked-in patches, every file hashed.

What was explicitly not done: publishing to a developer's home, pointing at a
mutable branch, committing a binary, and committing a build cache.

## Pinned analyzers

| tool | upstream | pinned commit | declared version | compiler | patches |
| --- | --- | --- | --- | --- | --- |
| zbc | ericsssan/zbc | `419d153ca411d1698899992d86c51eb9a7e14919` | 0.1.3 | Zig 0.16.0 | 5 |
| ziglint | rockorager/ziglint | `66709a408f2ea9ac1de91a438a83b13f4691a941` | 0.5.3 | Zig 0.16.0 | 1 |
| zlint | DonIsaac/zlint | `3ef67af7dfed776cb03012563942cdf3a97f1b59` (tag v0.10.0) | 0.10.0 | Zig 0.16.0 | 0 |
| zwanzig | forketyfork/zwanzig | `1a0768ccd889d3586ec9482f02ffffe872a99749` | 0.15.1 | Zig 0.16.0 | 7 |

All four commits were `HEAD` of their upstream `main` on 2026-10-02 (`git
ls-remote`, recorded at capture time). The installer re-verifies each one after a
`--depth 1` fetch with `git rev-parse FETCH_HEAD`, so the pin is the content
hash rather than a name that could move.

`tool_version` and `compiler` are separate manifest columns because they answer
different questions. zbc declares version 0.1.3 and is compiled with Zig 0.16.0;
zwanzig declares 0.15.1 while its own `build.zig.zon` still names a 0.15.2
minimum, because it is a dual-frontend analyzer. Writing "0.16.0" in a version
column would have been a claim that no upstream made.

### The patches, and why each exists

**ziglint** — one patch, two files, and **not** one rule. Upstream `66709a4`'s
own commit subject is *Z030: allow deinit to destroy self*, and the local tree
carries that fix together with three more changes in the same two files:

* **Z006/Z015 type-expression inputs.** `isTypeExpression` gains a
  `.merge_error_sets` arm: `pub const E = error{A} || Allocator.Error` is a
  public type, and without the arm Z015 fired on every `pub fn` returning one.
  Both `isTypeExpression` and `isTypeAlias` then stop testing builtin calls
  against their own short literal lists and share one 14-name
  `isBuiltinTypeConstructor` predicate (`@This`, `@import`, `@Type`,
  `@TypeOf`, `@EnumLiteral`, `@Int`, `@Tuple`, `@Pointer`, `@Fn`, `@Struct`,
  `@Union`, `@Enum`, `@Vector`, `@FieldType`), so Z006 stops firing on
  `@Int`/`@Enum`/… aliases.
* **Z030 receiver lifetime.** The analysis in `checkDeinitUndefined`,
  `analyzeReceiverLifetime`, `hasUnsafeReturn`, `isPointerType` and
  `isSelfUndefinedAssign` is reworked, and about 400 lines of regression tests
  are added.
* **Z030 wording.** `Rule.Z030.writeMessage` changes from *deinit … should set
  `self.*` = undefined* to *deinit … should leave `self` invalid, empty, or
  destroyed*, and the diagnostic context string changes with it.
* **Deleted coverage, stated plainly.** The patch also deletes eight
  literal-message-rendering tests — Z002, Z003, Z004, Z017, Z020 (two), Z021 and
  Z030 — with no replacement. Only Z030's wording change *requires* those
  deletions; the other seven pin exact message prose and are collateral. What
  they assert is rendered text, not consumer-visible detection. They are not
  restored here, and they are recorded here because a reviewer approving this
  patch from a one-line "one rule" description would otherwise be approving
  four rule-behaviour changes and 87 deleted lines without knowing it.

**zbc** — five patches, and the first is not optional. Upstream's
`build.zig.zon` declares `.minimum_zig_version = "0.17.0-dev.607+456b2ec07"`; the
checked-in patch set changes it to `0.16.0` and carries the 0.16 port with it
(65 files, largely the `std.zig.Ast` → ZIR API move and the `f` → `field`
`@typeInfo` rename, plus flow, type-engine and rule work). `0002` adds four
files that do not exist upstream at all: `src/budget.zig`,
`src/flow/numeric_eval.zig`, `src/flow/numeric_range.zig` and
`src/type_engine/source_policy.zig`. A plain `git diff` misses untracked files
entirely, and these four are imported by the patched sources, so omitting them
would produce a build that cannot resolve its own imports.

`0001` and `0002` are the two **captures** and are preserved byte-for-byte;
their sha256 values are still the ones this directory shipped. `0003` is **not**
a capture from anyone's working copy. It is authored against the tree `0001` and
`0002` produce, and it exists because that tree did not build under Zig 0.16.0,
did not report what it claimed to report, and — once it did build — corrupted
the heap on every file it looked at. It does six things.

1. **Three compile repairs.** `src/lib.zig` opened a `.{ … }` anonymous struct
   literal for `writeFile`'s options and closed it with `);`, so the parser
   reached the end of that test still expecting `}`. In
   `src/type_engine/document_store.zig`, `openLspSyncedDocument` called the
   private `requireAddressableSource` unqualified from `DocumentStore` — Zig
   does not put one type's private members in another type's scope. In
   `src/flow/cfg_builder.zig`, `LoweringError` omitted `error.SourceTooWide`,
   which `FileCache.init` already returns for a source too long to address with
   the `u32` token offsets `std.zig.Ast` uses, so the `LoweringError!void`
   entry points could not `try` the inferred `!void` helpers they delegate to.

2. **The `double_optional_ptr` rule, registered again.** `0001` removed the
   enum member from `config.Invariant`, shortened `all_invariants` from 113 to
   112, and dropped the rule's catalog entry, module import, dispatch row and
   `refAllDecls` pin — while leaving `rules/misc/double_optional_ptr.zig` and
   its `.md` in the tree as unreferenced dead files. After `0001` + `0002` zbc
   never invoked the rule, no build failed, no CLI line mentioned it, and the
   `?*?T` out-param class it exists to catch (upstream cites oven-sh/bun#13955,
   NAPI out-param corrupted caller stack) went unreported. All of it is
   restored from upstream `419d153` verbatim; the dispatch row uses `0001`'s
   single-space table formatting like every neighbouring row.

3. **Six severities back to error.** `0001` downgraded seven rules from
   `.@"error"` to `.warning`. Six go back to upstream's value:
   `memset_undef_after_len_truncation`, `f32_narrowing_int_to_float`,
   `index_minus_one_without_zero_guard`, `index_type_narrowing_wraparound`,
   `intcast_of_negated_signed` and `midpoint_addition_overflow`. No rule is
   disabled and no interval arithmetic is changed to quiet anything.

   **The one exception, named.** `intfromfloat_without_clamp` **stays**
   `.warning`. That is pre-existing, explicitly accepted gate policy — not a
   property of the port, and not an upstream default. The three findings this
   rule produces on the pinned tree were each reviewed with a numeric-range
   proof in hand (`criticalRange`, `expRef`) and accepted before this patch
   existed. It is the only rule in the distribution whose severity differs from
   upstream, it is disclosed at the call site in
   `src/rules/misc/intfromfloat_without_clamp.zig` so a reader of the source
   alone sees it, and `ZBC_STRICT` is deliberately not set. Every other finding
   these seven rules produce is an error and fails the gate.

4. **Explicitly named inputs can no longer vanish.** `SourceSelection.collect`
   had exactly one rejection path that recorded nothing: an input the operator
   named on the command line that `SourcePolicy` refuses was dropped with a
   bare `continue`. So `zbc vendor/thing.zig` analysed nothing, printed nothing,
   exited 0, and the gate printed `zbc: OK`. All three explicit-input rejections
   now record `error.SourceExcluded`, which prints
   `zbc: cannot select <path>: SourceExcluded` and drives zbc's exit 2. The
   discovery-driven exclusions inside `walk()` are deliberately unchanged and
   stay silent: there the operator named the parent directory and not the
   skipped entry, so that is the policy working rather than an omission.

5. **Heap ownership in the liveness solver.** With items 1–4 in place the tree
   compiled and linked, and then the analyzer corrupted the heap on every file
   in its own `src/`: SIGSEGV or SIGABRT on all 152, with stderr naming
   `double free or corruption (out)`, `realloc(): invalid pointer` and
   `mremap_chunk(): invalid pointer`. One gdb backtrace pinned it, with a null
   source and a non-zero length —
   `array_list.ensureTotalCapacityPrecise` ← `addOne` ← `append` ←
   `flow.worklist.computeLiveness` (`src/flow/worklist.zig:143`) ←
   `Solver.init` ← `worklist.check` ← `lib.analyzeEscape`. `computeLiveness`
   did

   ```zig
   var predecessors: std.ArrayListUnmanaged(std.ArrayListUnmanaged(BlockId)) = .empty;
   try predecessors.resize(gpa, block_count);
   … predecessors.items[@intFromEnum(successor)].append(gpa, block.id);
   ```

   and Zig 0.16's `ArrayListUnmanaged.resize` is only `ensureTotalCapacity`
   followed by `items.len = new_len` (`std/array_list.zig:1111-1114`): it grows
   the buffer, sets the length, and writes none of the new slots. So every
   element was whatever the allocator handed back, the first `append` grew that
   garbage list, and the deferred `deinit` freed it. This is a 0.17→0.16
   semantics difference — and `predecessors` does not exist upstream at all, so
   upstream has no version of this line. The fix is the 0.16 idiom: `resize`,
   then initialise every element to `.empty` before the first `append`.

   *Verified*: with that item in, the same `zig build -Doptimize=ReleaseFast`
   gets past compile and the analyzer runs to completion —
   `zbc: selected=153 analyzed=153 failed=0 findings=75` — with no SIGSEGV, no
   SIGABRT and no allocator diagnostic on any file. The path is also covered by
   the 154 tests in `src/flow/worklist.zig`, every one of which builds a CFG and
   reaches `computeLiveness` through its `analyze` helper; no new test was
   added for it.

6. **What the same build then showed — recorded, not worked around.** The build's
   remaining failure is `run exe zbc failure / process exited with error code 1`,
   and it is *not* a consequence of the severity policy in item 3. `build.zig`
   is upstream's dogfood: `self_check.addDirectoryArg(b.path("src/"))` plus
   `b.default_step.dependOn(&self_check.step)`, so every `zig build` runs
   `zbc src/` on zbc itself — and `main.zig:306` is
   `return if (all_problems.items.len != 0) 1 else 0;`, exit 1 on **any**
   finding, warning or error. That tree reported 75 findings on its own source —
   a dated measurement of the `0001`–`0003` tree, not a standing count — so that
   self-check cannot pass for it at any severity, including upstream's and
   including the single accepted advisory. Nothing in this patch
   suppresses, re-severitises, excludes or reinterprets a finding to change
   that; the gap between this captured source and upstream's clean-dogfood
   expectation is left visible for whoever owns the next decision.

   One more site of the same class is deliberately **not** touched:
   `src/type_engine/analysis.zig:4166` resizes an `ArrayMap`'s entry list and
   then writes only the key half of each entry. That is upstream code at
   `419d153`, it did not fail in the build above, and changing upstream-authored
   code on a suspicion is not this patch's business.

**`0004` — a named `cli` step, and what it does not claim.** Like `0003` this
is authored, not captured, against the tree `0001`+`0002`+`0003` produce, and
it touches **`build.zig` only**. It replaces the one-line
`b.installArtifact(exe)` with the three lines `std/Build.zig:1660-1662`
already expands it to —
`const install_exe = b.addInstallArtifact(exe, .{});`,
`b.getInstallStep().dependOn(&install_exe.step);` — plus a named step
`cli` that depends on `install_exe.step`. `zig build cli` therefore builds
and installs the same `zig-out/bin/zbc` and runs nothing else.

**The default build is unchanged and still fails.** `b.default_step` *is*
`&b.install_tls.step` (`std/Build.zig:324`), so the install dependency above
is the same graph `b.installArtifact(exe)` produced; the dogfood self-check
(`b.addRunArtifact(exe)` + `addDirectoryArg(b.path("src/"))` +
`b.default_step.dependOn(&self_check.step)`) is not touched, and neither are
the `run`, `test` and `fuzz` steps. A `cli` step that depended on
`default_step` would drag the self-check along with it, which is why it hangs
off the install *artifact* step instead. The self-findings of item 6 are still
there, and `cli` is a way to obtain the binary, not a self-lint pass: no rule,
severity, exclusion or finding is touched to make anything green. The project's
own gate — all four analyzers, ERROR findings fatal — is a separate mechanism
and is unchanged by this.

**Verified how far, stated exactly.** `0004` was applied with `git apply -p1`
onto a pristine `419d153` + `0001`+`0002`+`0003` checkout, cleanly, and the
only file that differs from that base is `build.zig`; the `src/**/*.zig`
digest recomputes to `b794e308…e5e3d2`, unchanged, which is why the
`source_digest` column does not move. The first 2026-10-02 empty-`HOME` cold
attempt compiled and staged zbc with `zig build cli`, then compiled ziglint and
zlint, and failed on zwanzig's captured source and removed the partial prefix;
that attempt proved those three artifact builds and nothing beyond them. The
later installs recorded under **Receipts** completed all four from a fresh
prefix and an empty `HOME`, so this recipe is witnessed by a completed
installation as well as by that failed attempt.

**`0005` — a full-index-coverage certificate for `for` loops.** Authored, not
captured, against the tree `0001`+`0002`+`0003`+`0004` produce. It touches
**`src/flow/cfg_builder.zig` and `src/flow/worklist.zig`**, so the zbc row's
`source_digest` moves — `b794e308…e5e3d2` → `ddcb7de4…c868` — naming `0001`–`0005`.
**The defect.** `lowerFor` gives every loop an unconditional edge from its header to
its natural exit, so a local read after the loop is reachable along a path where the
body never ran. For `var arr: [dims.len]T = undefined;` filled by `inline for
(table, 0..) |v, i| arr[i] = v;` and returned, it does not exist:
`bench/bench_vec.zig` `buildPlan`/`buildSeedNames` were four such errors.
**What it adds.** A proof used only from `lowerFor`. Each level needs exactly one
zero-based index-range input — a `.for_range` node, which `Ast.fullSlice` does not
cover — whose capture is a plain `|x, i|` name, and every input's compile-time length
greater than zero, through the **existing** `FileCache.fixedArrayLenOf` and
`.comptimeIntValueOf`. The body must be exactly **one** statement: the filling
assignment, or a single nested `for`, recursed into; the LHS index chain must be the
enclosing counters, each dimension exactly as long as its counter. Only then does one
`.pointer_write` — the statement `emitWritesInLhs` already emits — go onto the exit
block, **before** any `else` body is lowered onto it. Its effect is `transfer`'s
`.pointer_write` arm in `cfg_transfer` (lines 61–69), which drops the local's `.undef`
and leaves every resource origin alone — **not** `transferAssign`, which rebinds the
local and has no `.undef`-clearing arm. That `emitWritesInLhs` comment named the
wrong function and is corrected here; `cfg_transfer` behaviour does not move.
**What it refuses** its header enumerates, each with a test that must still report: a
body that is not one assignment-or-`for` statement, a value carrying
`undefined`/`break`/`continue`/`return`, a nested `else`, a constant index, a range
not from 0 or of the wrong length, a runtime-length or zero-length input, a partial
fill, and a payload token that is not one.
**The payload bound.** `Ast.full.For.payload_token` is **computed** by
`fullForComponents` as `lastToken(last_input) + 3`, one more after a comma. With a
payload that lands exactly on the token after `|`, a payloadless `for (0..n)` has no
`|`, so the same sum points past the statement, and past `tags.len` at end of file.
The scan now bounds that index and anchors it on a `|` and an identifier-or-`*`
token before reading any token. Untested on purpose: such a loop binds nothing, so
no valid LHS index can equal a name the old unbounded scan reached, and a
discriminating source would have to be invalid Zig.
**The same refusals, for less work.** `forCounterLevel` — the only cache-backed
query this walk makes — now runs after the cheap body-shape gates, so a body that is
neither the filling assignment nor a single nested `for` costs no `FileCache` query.
An open `0..` reuses the neighbour length `forTripCount` already read, so `for (xs,
0..)` does one lookup where it did two; that carried value clears across a range
input, so an open range still refuses a range neighbour.
**What it deliberately does not do.** No CFG edge is touched, no `merge` clear added,
`emitWritesInLhs` untouched; no element-granular state, rule, severity, catalog
entry, exclusion, name, input, benchmark or exported API moves.
**Coverage and evidence.** 20 tests in `src/flow/worklist.zig` cover it. A post-review run over the bytes this patch now carries passes, and the tree it produces has been built, installed and gated; the runs and their limits are below.

**zwanzig** — six captured patches and one authored completion patch.
The captured series exists because the local checkout is at `956bc69`, five
commits ahead of `origin/main`. `git ls-remote` shows `956bc69` in **no** ref of
`forketyfork/zwanzig`, and the GitHub API returns HTTP 422 for it. Pinning it
would pin something `git fetch` cannot retrieve, so the pin is `origin/main`
`1a0768c` and the local work is carried as patches: one per commit
(`0001-674c36b`, `0002-19d6a7b`, `0003-4f3fbce`, `0004-351ae9b`,
`0005-956bc69`), each header naming its commit and subject and stating that it
is not published upstream, then `0006-uncommitted` for the working tree on top.
A per-commit split keeps each patch reviewable on its own and makes the order
explicit; `0006` is the part that is a working tree rather than history.

`0007` completes that captured source for Zig 0.16: two switch terminators,
three AST index conversions, and removal of nonexistent enum/union tags.
The existing `container_decl` tags cover those declarations in Zig 0.16.
The six captures remain unchanged. A ReleaseFast artifact build passed after
these corrections. This build does not prove that the analyzer accepts this project.

### What was deliberately not archived

Only source paths (`src/`, `build.zig`, `build.zig.zon`) are in the patch sets.
Excluded from the captured checkouts: zbc's `README.md` and `.github/`, zwanzig's
`docs/`, `CHANGELOG.md`, `justfile`, `AGENTS.md`, `CLAUDE.md`, `GEMINI.md` and
`test/`, and every `.zig-cache` and `zig-out`. Those are documentation and build
state, they are unrelated to what the gate executes, and zwanzig's `test/` in
particular is fixtures for the tool's own suite rather than inputs to the binary
the gate runs. No cache and no binary is committed anywhere in this directory.

## What the patches were verified against

Not assumed, and the zbc row is now a statement about what was actually re-run.

Each series was applied with `git apply -p1` into a **fresh checkout** of its
pinned upstream commit. For zbc that was re-done from scratch once `0003` was
written: a pristine `git checkout 419d153`, then `0001`, `0002` and `0003` in
order, and the resulting tree compared file-by-file against the corrected tree
the patch was generated from. Every stage matched byte-for-byte, including the
stage before `0003`, which reproduces the old `source_digest` exactly. `0004`
was then applied to that same base: it applies cleanly, and `build.zig` is the
only file that differs afterwards, so the `src/**/*.zig` digest is the same
value before and after it.
`0005` was then applied to that same `0001`–`0004` base: `git apply
--whitespace=nowarn --check -p1` accepts it, and the two files it names are the
only ones it changes. Its `src/**/*.zig` digest therefore **moves**, which is
the difference from `0004` and is recorded as such in `manifest.tsv`.

**Two test runs exist for this series, and the second covers the bytes as
shipped.** The first was over the tree one revision back: `zig test
--test-filter "use_undefined:"`, **exit 0, 29 tests selected, all passed,
7.4878056910820305 s** —
`/tmp/zig-interval/waves/wave1-zbc-array-green-final.log`. Those
29 are this patch's **20** tests plus the 9 pre-existing ones the same filter
selects, so the run covers the whole set rather than the 19 an earlier run did.
It **predated the review correction folded into the current patch** — the
payload-token bound, the counter query moved after the cheap body-shape gates,
and the carried neighbour length — so on its own it witnessed none of those
three.

The second run is over the bytes this patch now carries: the same filter, the
same 29 selected, **all passed, 13.740223854314536 s**,
`/tmp/zig-interval/waves/wave1-zbc-array-reviewed-green.log`.
The review correction is therefore witnessed, by those same 29 tests.

Beyond that, `0005` has been built, installed and gated: `zig build cli` ran as
the installer's recipe against this tree, the analyzer landed in a fresh prefix
under an empty `HOME`, and the full gate run from that prefix is **exit 0**,
with the four historical `bench/bench_vec.zig` `use-undefined` errors absent
from it. **Receipts** below records that run and states what it does not cover
— a three-run benchmark baseline, remote GitHub Actions and the `vf` engine
have not been run, and the default self-dogfood is not part of it.

| tool | src digest after the pins in `manifest.tsv` | verdict |
| --- | --- | --- |
| zbc | `ddcb7de4…c868` | upstream + 0001-0005. The apply round-trip through 0004 is byte-for-byte, and `0005` is accepted by `git apply --check` on that base. Two `use_undefined:` runs exist — 29 selected, all passed, the first before the review correction and the second over the bytes as shipped — and the tree has been built with `zig build cli`, installed into a fresh prefix under an empty `HOME`, and gated from that prefix at **exit 0**. **Receipts** below has the numbers. The default dogfood is separate from all of that and still exits 1 on any finding; no `zbc src/` self-run over `0001`–`0005` exists. |

| zwanzig | `50e2cee8…8e23c` | upstream + 0001-0007. The six captures are preserved. The authored completion passed a ReleaseFast artifact build. |
| ziglint | `b70c237d…30211f` | upstream + 0001, identical to the captured working copy |
| zlint | `c6919ca8…59d9` | (upstream, no patches) |

The digest is `sha256` over the sorted `sha256  path` listing of `src/**/*.zig`.
It is recorded per row in `manifest.tsv` as `source_digest` so a reader can
tell, without trusting this file, what a tree contains.

**Three zbc digests, and the differences are the point.** `bf5331d6…c07df` is the
digest of **upstream + `0001` + `0002`** — the two captures, unchanged, which
is exactly what this repository recorded before `0003` existed.
`b794e308…e5e3d2` is the digest of **upstream + `0001` + `0002` + `0003`** —
and of the tree with `0004` on it as well, because `0004` is a `build.zig`-only
patch and this digest is taken over `src/**/*.zig`. `bf5331d6…c07df` and
`b794e308…e5e3d2` are not expected to match: `0003` exists because the
`bf5331d6…c07df` tree does not compile, silently drops explicitly named inputs,
had unregistered a rule, and corrupted the heap on every file it analysed. A tree
matching `bf5331d6…c07df` is the pre-correction capture, not the distribution.

`ddcb7de4…c868` is the digest of **upstream + `0001`–`0005`**, and unlike
`0004`, `0005` does move it: it changes two files under `src/`. It is what
`manifest.tsv` now records and therefore what a re-install must reproduce. A
digest that still reads `b794e308…e5e3d2` for the zbc row means `0005` is missing
from that manifest, not that the two are equivalent. Note what this digest does
**not** say: it says which `src/` bytes the distribution analyses, and nothing
about whether those bytes behave correctly. Behaviour is witnessed separately:
the two `use_undefined:` runs recorded above, and the installed gate under
**Receipts**.

**And the zbc row was also built, not only applied.** A ReleaseFast build
against the pinned tree plus `0001`–`0003` compiled and linked cleanly under
Zig 0.16.0, and the resulting analyzer analysed its own `src/` to completion —
`selected=153 analyzed=153 failed=0` — reporting **75 findings about that
tree's own source**. That count is dated evidence about the `0001`–`0003` tree.
It was not re-measured after `0004` or after `0005` and it is **not** carried
forward as the current self-finding count. **No `zbc src/` self-run over
`0001`–`0005` exists and none is claimed**, so that number is unknown here.

**Default build policy is unchanged.** Upstream's dogfood self-check is not in
the `cli` install path. It runs `zbc src/` and fails on any finding. The
observed self-run covers `0001`–`0003`, not current `0001`–`0005`; its outcome
is recorded in item 6. A green installed project gate does not establish a
green current self-dogfood run.

**What each claim here covers.** The ReleaseFast artifact build and the
self-analysis cover the tree `0001`–`0003` produce. The first completed
empty-`HOME` cold install in the receipts covers `0001`–`0004`. The
fresh-prefix install and the green gate in the receipts cover `0001`–`0005` and
are the current evidence. Nothing in this section is evidence about a
three-run benchmark baseline, about remote GitHub Actions, or about the `vf`
engine; none of those has been run.

`zig build cli` — selected for zbc by the `build_recipe` name `cli` in
`manifest.tsv`, and recorded per install as the resolved argv in
`install-manifest.tsv` — is the way to obtain that same binary without the
dogfood step, and it is a build step and not
a lint gate: it installs `zig-out/bin/zbc` and reports nothing about findings.
The default build still runs that separate self-check. The project's own gate
runs all four analyzers over the project and treats ERROR findings as fatal;
that policy is enforced by the gate, not by this build step.

**Nothing here claims the shipped source still equals anyone's current working
copy.** It did while the pin was only `0001` + `0002`. It does not now and
should not: those working copies were drifting while they were captured and
have been edited since. What is claimed is the other direction — a pristine
checkout of the pinned commits plus the checked-in patches reproduces the
digest above, byte-for-byte.

**Capture instants are per patch, not one clock reading.** Every patch header
carries its own and they disagree, because the work happened at different times
and because not all of these files are captures at all: zbc `0001` is
2026-10-01T23:43:59Z, zbc `0002` and zwanzig `0006` are 2026-10-01T23:43:14Z,
ziglint `0001` carries the date 2026-10-02 and no instant, the five per-commit
zwanzig patches carry none because they are commit diffs, and zbc `0003` and
`0004` carry authoring times rather than captures. The headers record
2026-10-02T01:57Z for `0004` and 2026-10-02T04:12Z for later items in `0003`.
zbc `0005` carries no instant in its header at all, because none was recorded
when it was written.
These author-recorded timestamps do not establish chronology. The numbered
patch series defines apply order. `manifest.tsv` transcribes the header values
instead of declaring a single instant for the directory. The one caveat that
still stands: the zbc working copy was being edited *while* it was captured —
`src/flow/value_range_tests.zig` changed between 23:43:36Z and 23:43:59Z, the
first capture was discarded, and `0001` is the retake.

## Receipts

Two installs and two gates, both on 2026-10-02 on `buildhost` with Zig 0.16.0.
They are different runs about different trees and must not be read as one
result or relabelled as each other. Logs are under
`/tmp/zig-interval/waves/`.

**Historical — a genuine cold install, and the red gate that followed.**
Fresh prefix *and* fresh work root, empty `HOME`: **exit 0,
285.8154720328748 s**, `wave1-complete-cold-install.log`. That install hashed
**31** payload files and **12** patches and sealed **26** source files, rehash
exit 0. The first full gate run from that prefix was **exit 1,
322.3062626081519 s**, `wave1-installed-full-gate.log`: four ziglint findings
(one Z024 at `bench/bench_lp.zig:1284` and three Z023 parameter-order findings)
and four zbc `use-undefined` errors in the compile-time-initialised `bench_vec`
arrays, alongside the three reviewed `intfromfloat-without-clamp` warnings.
This is the `0001`–`0004` tree's historical result; `0005` addresses the array
initialization errors.

**Current — fresh prefix and empty `HOME`, reused work cache.** The install in
force now wrote a **fresh prefix**
(`waves/quality-wave1-9fby02wf/prefix`) and ran under an **empty `HOME`**
(`waves/quality-wave1-9fby02wf/empty-home`, which was still empty when it
finished), but it **reused an existing work cache**
(`waves/quality-cold-final-9mngc9u6/work`): exit 0, **276.16231817100197 s**,
`wave1-reviewed-prefix-install.log`. It is therefore **not a second cold
install** and is not counted as one; what it proves is that the `cli` recipe
builds the tree `0001`–`0005` produces and that the prefix installs and
verifies. Rehash of every installed payload row: exit 0, **32** files,
`wave1-reviewed-prefix-rehash.log`. The bundle those numbers describe is **32**
payload files, **13** patches and **27** sealed source files — the growth from
31 / 12 / 26 is `0005` itself, as a patch file and as an installed row.

The post-review regression run is recorded under **What the patches were
verified against**. The gate from that fresh prefix: **exit 0,
1061.0421875622123 s**, `wave1-reviewed-full-gate.log`, `GATE PASSED`. zbc
reported `selected=32 analyzed=32 failed=0` with **0 errors and 3 warnings**, all
three the standing `intfromfloat-without-clamp` advisory, so the four historical
`bench_vec` `use-undefined` errors no longer appear in the project's own gate.
The cross run `gate-20261002-045938-6457-7192` is immutable and bound to that
gate: four Linux targets at `build=pass run=pass tests=348` each — 1392
executed tests — and `x86_64-windows` at `build=pass run=unavailable`,
`fail=0`, `status=partial`.

**Still proved by none of it.** Each of the three benchmark programs was run
once, to a regular file. That is a smoke, not a three-run baseline and not a
speedup. No solver optimization has been selected or measured. The remote
GitHub Actions workflow and the `vf` engine have not been executed.

## What is NOT claimed

**No binary equivalence.** The installed analyzers are source-equivalent to the
pinned upstream commit plus the checked-in patches. They are not claimed to be
byte-identical, or even behaviorally identical, to whatever happens to be in a
developer's `~/.local/bin`. The build optimizer is an installer flag
(`--optimize`, default `ReleaseFast`) and is recorded per tool in
`install-manifest.tsv`, because it is a build choice and not a fact about the
source.

The development binaries were also newer than some of the trees they came from:
`zbc`'s sources were last touched 2026-10-02 01:38 and its binary was built
2026-09-29 22:30; zwanzig's sources 2026-10-02 01:13 against a binary from
2026-10-01 22:48. Those two had drifted past the binaries before this capture
started. `ziglint`'s tree (2026-10-01 22:59) predates its binary (23:22) and is
consistent with it. Nothing in this directory depends on those binaries; they are
recorded here only so nobody reads these pins as a reconstruction of them.

**No published upstream patch.** These patches are not on any upstream branch and
are not offered as contributions. They are a local diff against a published
commit, carried so the gate can be rebuilt. Where a patch touches a file an
upstream maintainer would want, that is a question for upstream and not for this
repository.

**No self-dogfood result for zbc `0005`.** The tree `0001`–`0005` produces has
been built with `zig build cli`, installed into a fresh prefix under an empty
`HOME`, and gated from that prefix at **exit 0**; **Receipts** above is the
record. What is still *not* established about that tree is the self-analysis:
no `zbc src/` run over `0001`–`0005` exists, so how many findings it reports
about itself is unknown here, and upstream's dogfood default build would still
exit 1 on any finding. Also unproved by all of the above, and claimed nowhere
in this directory: a three-run benchmark baseline, the remote GitHub Actions
workflow, and the `vf` engine. An exit 0 from the project's own gate means all
four analyzers ran and no ERROR finding fired; it is not a claim that the
source is clean, and the three standing `intfromfloat_with_clamp` advisories
are still findings.

## The zlint `v0.0.0`

The installed `zlint` prints `v0.0.0`. That string identifies nothing, and
reading a version out of it would have produced a wrong pin. It is
`build.zig:329` of DonIsaac/zlint:

```zig
opts.addOption([]const u8, "version", b.option([]const u8, "version", "ZLint version") orelse "v0.0.0");
```

so **every** build from source prints it unless a release build injects a
version. The pin rests instead on fingerprints the binary does expose:

* dependency hashes `chameleon-2.0.1-ZOxajZ17AADmYCpHFqqoGfaXQiRkXM8B5lYJfir9tqsz`
  and `smart_pointers-0.0.4-NPos2JOtAACuxKEoBGQgkmncI0APAPl-QwaI6klLObuP`,
  byte-identical to the upstream `build.zig.zon` at `3ef67af`;
* `src/Semantic/Cfg` present in the binary's source paths, a directory added
  2026-08-16 (`400e93dc`), which rules out everything before it;
* the `-c, --config <path>` help string, added 2026-08-23 (`25b9fa2a`);
* the literal `zlint.json` in the binary, introduced 2026-09-15 (`5628391c`).

The newest revision consistent with all four is `3ef67af` (2026-09-17), which is
also `origin/main` HEAD and the commit tagged `v0.10.0`. The binary was built
2026-09-29. The binary's own source paths say `~/tools/zlint`, so it
was not built here, and the version it prints carries no information about which
revision it was. `3ef67af` is the strongest pin the available evidence supports.

## The distributed harness

`harness/bin/zig-gate`, `harness/bin/cross-test` and the five files under
`harness/lib/cross-test/` are reviewed source copies. The gate logic, the ten
sections, the fail-closed verdict rules, every lint rule, the cross matrix, the
summary schema, the artifact safety rules and every exit code are unchanged.
What did change is the portability and fail-closed behaviour around them, and
it is listed here in full rather than summarised as "a few things".

**What made the harness distributable in the first place:**

1. **No developer's home as a tool source.** When `ZIG_GATE_PREFIX` is set, or
   when the gate runs as `<prefix>/bin/zig-gate`, `ziglint`, `zlint`, `zbc`,
   `zwanzig` and `cross-test` resolve to `<prefix>/bin/<name>` and to nothing
   else. No `$HOME/.local/bin`, no `PATH`. A missing analyzer is exit 2 naming
   every absent file at once, before any project check runs, because a gate that
   silently runs a *different* analyzer than the one it was installed with
   reports findings about a tool nobody pinned.

2. **No required machine-wide policy.** `cross-test` used to exit 2 unless
   `~/.local/lib/host-scratch.sh` existed. That is a developer-home dependency
   and a cold install with an isolated HOME has no such file. The rules now come
   from `harness/lib/cross-test/scratch-contract.sh`, which is self-contained:
   on a managed cluster host it enforces the sanctioned local-volume list
   itself, and elsewhere it accepts an explicitly chosen local directory. The
   machine policy is still sourced first and still wins where it is readable, so
   this host's behaviour is unchanged. Nothing in the host's global
   configuration was modified to achieve that.

3. **One file-list exclusion.** `tools/quality/harness/` joins the default
   `GATE_EXCLUDE` so the vendored `run_policy.zig` is not linted and formatted as
   if it were this project's source. It is a narrow path, not a blanket
   suppression: nothing else under `tools/` is excluded, and a project that sets
   `GATE_EXCLUDE` itself keeps full control.

**What the first real distribution run found wrong, and what was corrected:**

4. **An unset `HOME` no longer aborts the harness.** The machine-policy path was
   expanded from `$HOME` in a default word, so under `set -u` an unset `HOME`
   raised an unbound-variable error in `cross-test`, `zig-gate`, `test.sh` and
   `test-zig.sh` before argument parsing — including on `--list` and `--help`.
   The policy path is now consulted only from an explicit
   `QUALITY_HOST_SCRATCH_POLICY` or a non-empty `HOME`, so a cold install with an
   isolated environment works and no bare `/.local/lib/host-scratch.sh` lookup
   happens.

5. **The `--output` prefix is re-checked once it exists.** Only the
   pre-creation location check ran, so `--output /home/tmp2/<other-user>/…`
   passed and the run directory was then created inside another user's tree. The
   prefix is now re-checked with the full predicate — real directory, writable,
   and owned on a managed host — before the lock file or the run directory is
   touched, exactly as the `TMPDIR` path already was.

6. **An inherited `ZIG_GLOBAL_CACHE_DIR` is held to the same contract.** It was
   used as the cache base with no validation, so an ambient NFS value created a
   directory and then died inside `zig build` on `renameat2` as a build error
   instead of a storage refusal, leaving the directory behind. It now goes
   through the contract before `mkdir`/`mktemp`, like `TMPDIR`.

7. **Section 9 exports its own validated cache and its own run id.** The gate
   hands the cross-test child the `GATE_GLOBAL_CACHE_DIR` it already validated,
   so an ambient NFS cache cannot override it, and it binds a unique
   `CROSS_RUN_ID` and reads only `runs/$CROSS_RUN_ID/summary.json` — the
   "newest directory under `runs/`" fallback is gone, so no evidence can come
   from another run.

8. **Section 9 requires executed-test evidence for the Linux targets.** It used
   to accept `build_only`/`partial` and print `cross-test: OK` with zero tests
   executed, which on a host with no emulator turned the whole cross matrix
   green without running anything. When the project profile declares
   `CROSS_REQUIRED_RUN_TARGETS`, every required target must now show
   `build.status=pass`, `run.status=pass`, `status=pass` and `run.tests>0` in
   that run's summary, or the section fails — a missing row, `build_only`, zero
   tests, a summary belonging to another run id, an unfinished run,
   `bookkeeping_failure`, malformed JSON, a missing file and a declaration that
   does not parse as target names all fail closed. `python3` (stdlib `json`) is
   needed only when a set is declared; `cross-test` itself stays Python-free and
   gains no new flag. A profile that declares nothing keeps the previous
   build-only reporting verbatim — and in that case the `cross-test: OK` line
   now says that the profile declares no rows that must execute, instead of
   claiming a check that never ran.

9. **`quality_scratch_pick` was returning the volume, not the candidate.**
   `quality_scratch_path_ok` and `quality_scratch_why` left `candidate` and
   `root` undeclared. Under bash's dynamic scoping an undeclared assignment
   writes a global, so `quality_scratch_pick` returned the matched volume
   (`/home/tmp2`) instead of the caller's candidate — and exited 0, which is the
   worst possible shape for that bug. Both functions now declare every variable
   they write, loop variables included.

10. **Scratch refusals say what the predicate said.** Refusals print the
    `QUALITY_SCRATCH_WHY` sentence from the failing predicate set instead of
    re-deriving one from the path, and `quality_scratch_why` separates "on an
    approved volume but not permitted" from "outside the approved volumes" —
    the old wording sent the reader after the wrong volume for a path that was
    under `/home/tmp{,2}` all along.

11. **Concurrency is pinned in the profile, and the profile's comments match
    reality.** `cross-test.profile.sh` sets `CROSS_JOBS=2` and
    `CROSS_BUILD_JOBS=1`, so an ambient `MAX_JOBS`/`ZIG_JOBS` can no longer
    change the concurrency CI asserts. It declares
    `CROSS_REQUIRED_RUN_TARGETS='x86_64-linux aarch64-linux riscv64-linux
    s390x-linux'` — the four Linux rows; `x86_64-windows` is deliberately not
    among them because it is compile coverage on a host with no wine. The
    header comments now describe `cross-test` as the pinned, checksummed
    distribution installed by `scripts/install-quality-tools.sh` into the
    prefix — not a developer's `~/.local/bin` — describe the current CI job as
    one that installs qemu-user and asserts the runtime rows rather than the
    compile-only job the old comment claimed, and cite the current line numbers.
    The measured 108 s and 5m98.663ms timeout story and the lost-test reading
    rule are kept, still dated as the measurements they are.

12. **Four new consumer-visible cases in `test.sh`**, the harness's own suite,
    so items 4, 5, 6 and 9 cannot silently come back: `quality_scratch_pick`
    must return the candidate it was given rather than the volume above it; an
    unset `HOME` must not abort `cross-test` before argument parsing; an
    inherited `ZIG_GLOBAL_CACHE_DIR` that fails the contract must be refused
    with nothing created and no summary published; and a non-writable output
    prefix must be refused before any lock file or run directory (skipped when
    the suite runs as root, where `-w` cannot fail). No existing assertion was
    changed or removed.


No new option, environment variable or per-tool argument passthrough was added to
the gate: section 7 invokes the analyzers with the plain file list, `ZBC_STRICT`
is still unset, and no analyzer rule is disabled. The accepted advisory-warning
policy is untouched.

`run_policy.zig` and `zig-targets.sh` are byte-for-byte the reviewed originals.
`test.sh` and `test-zig.sh` keep every assertion they had; they now find their
own command and their own scratch beside themselves, their system-temp
expectations key off the contract's mode instead of a second hostname test that
could disagree with the code it is testing, and `test.sh` carries the four added
cases named above.

## Licenses

All four analyzers are MIT, and the license files are carried verbatim:

| file | upstream | copyright |
| --- | --- | --- |
| `licenses/zbc.LICENSE` | ericsssan/zbc | Copyright (c) 2026 Eric San |
| `licenses/ziglint.LICENSE` | rockorager/ziglint | Copyright (c) 2026 Tim Culverhouse |
| `licenses/zlint.LICENSE` | DonIsaac/zlint | Copyright (c) 2024 Don Isaac |
| `licenses/zwanzig.LICENSE` | forketyfork/zwanzig | Copyright (c) 2026 forketyfork |

`zlint`'s license was fetched from the pinned revision, because there is no local
zlint checkout to copy it from. `scripts/install-quality-tools.sh` installs these
files into `<prefix>/share/zig-interval-quality/licenses/` and records each one
in `install-manifest.tsv`.

`licenses/harness.LICENSE` is a byte-for-byte copy of this repository's root
`LICENSE` — MIT, Copyright (c) 2026 Janis, sha256
`3ffc12bc6edab9ffc6783f5443f47c444b2276ccc2ee6f620f42d6b3a070baec`. The installer
copies it to `<prefix>/share/zig-interval-quality/licenses/harness.LICENSE` and
requires it whenever the harness is selected, so nothing this installer
redistributes into a prefix lacks an applicable licence notice.

The patch files contain MIT-licensed upstream source and local changes.
Each installed patch row identifies the corresponding upstream notice in
`licenses/<tool>.LICENSE` and this repository's notice in `harness.LICENSE`
for local changes. Upstream copyright notices remain intact.
The harness, the
`cross-test` helpers and `run_policy.zig` are **quality-tools source** — a
separately versioned, separately licensed distribution that this repository
carries under the same MIT terms as its own `LICENSE`. That classification is
deliberate and it is the complete licensing story for those files: they are not
upstream, no third-party copyright is invented for them, and the notice that
applies to them is `harness.LICENSE`. The installer records that licence against
every harness and helper row of `install-manifest.tsv`, so a reader of an
installed prefix can tell which terms cover which file without reading this
document.
