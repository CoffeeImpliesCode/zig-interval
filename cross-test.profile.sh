#!/usr/bin/env bash
# cross-test profile for zig-interval.
#
# cross-test is the pinned, checksummed harness in tools/quality/harness/,
# installed by scripts/install-quality-tools.sh into $QUALITY_TOOLS_PREFIX/bin.
# CI installs it the same way in its `cross` job and runs it there; the installed
# zig-gate runs it as section 9. A developer's own ~/.local/bin/cross-test is the
# same reviewed source, and nothing in this file depends on which copy ran. It
# discovers this file at ./cross-test.profile.sh and SOURCES it, as trusted bash
# and not as data, both in its own process and in every per-target phase worker.
# A profile in the tree therefore decides what a green run COVERS, so read this
# file before quoting a cross-target table as the project's coverage.
#
# What is set here, and only this: the execution budget, the concurrency, the
# five targets, the rows that have to have EXECUTED, and the PATH guard at the
# bottom. The build step is cross-test's own `zig build test`, its cache is its
# own, and CROSS_MATRIX is untouched - this file narrows which of the 56
# published Zig 0.17 targets run, it does not replace the table. Do not add `set -e`,
# traps, or a `cd` to this file: cross-test runs `set -uo pipefail` without `-e`
# and forbids a profile from changing shell options, traps, or the working
# directory.
#
# ---------------------------------------------------------------------------
# READ THIS BEFORE YOU BELIEVE A `status=fail`
# ---------------------------------------------------------------------------
# cross-test's one-line summary cannot tell a TIMEOUT from a WRONG ANSWER.
# Both print `run=FAIL reason=tests_failed`, and the `tests=348` on that line
# counts tests that RAN, not tests that passed, so it stays at 348 on a run
# that lost one. Thirty seconds, in order:
#
#   1. `timed out` in the per-target build log under --output means BUDGET,
#      not a break. That was the standing failure on this project: the heaviest
#      test takes 108 s NATIVELY (CROSS_TIMEOUT below), which does not fit the
#      harness default of 300 s once qemu_user is in the loop.
#   2. A failing assertion naming the test, with no `timed out`, is a REAL
#      failure. That is the only thing in a `status=fail` worth debugging
#      before reading the log.
#   3. `status=partial pass=4 fail=0 build_only=1` is this project's NORMAL
#      clean result: x86_64-windows has no runner here, so it is
#      reported build_only/runtime_unavailable and never counted as a pass. A
#      green default run says `partial`, not `pass`, and exit status is 0.
#      `--require-runners` would turn that into a failure and is NOT usable
#      here, because the Windows row legitimately has no runtime. The rows that
#      DO have one are named in CROSS_REQUIRED_RUN_TARGETS below, which the
#      installed zig-gate reads out of this file and enforces: each of the four
#      must show build=pass, run=pass and an executed-test count above zero in
#      that run's own summary.json, or section 9 is red. A green gate run
#      therefore means four Linux test suites actually executed. A bare
#      `cross-test` outside the gate says the same run as exit 0 and
#      `partial`, which is honest but is the weaker claim.
#
# A `status=fail` that shows the timeout again means the 900 s budget was
# overridden: `--timeout` on the command line beats this file.
#
# ---------------------------------------------------------------------------
# HOW TO RUN IT ON THIS CHECKOUT
# ---------------------------------------------------------------------------
#   export QUALITY_TOOLS_PREFIX=$HOME/quality        # where you installed
#   export PATH=$HOME/zigbin:$PATH                   # the real 0.17.0 zig
#   ZIG=$HOME/zigbin/zig \
#     "$QUALITY_TOOLS_PREFIX/bin/cross-test" --output $HOME/cross-out
#
# CI's `cross` job sets the same three things (QUALITY_TOOLS_PREFIX, ZIG, an
# absolute --output on the runner's local disk) and adds only its own run id.
#
# Put all three on a large LOCAL volume rather than on the system temporary
# directory: /tmp is normally a small RAM filesystem, and one run writes build
# output, artifacts and logs. `scripts/scratch.sh` resolves a suitable
# location for you if you would rather not write the paths out.
#
# `--output` is not optional here: a network filesystem rejects
# EINVAL, so a Zig build cannot keep a cache on the network mount. cross-test
# puts ITS cache under ZIG_GLOBAL_CACHE_DIR when that is set and under the state
# base it picks from TMPDIR when it is not, and holds either to the same rule
# before creating anything; `--output` is what moves the rest of the run onto
# local disk - prefix, artifacts, logs, both summaries. A run leaves
# `--output/runs/RUN_ID/{build,run}-TARGET.log` and the run-scoped
# `--output/runs/RUN_ID/summary.json`, plus `--output/cross-test-summary.json`
# as the atomically replaced pointer to the same document.
#
# cross-test also owns several options and refuses them outright
# (`cross-test manages this option: --cache-dir`, and likewise --prefix,
# -Dtarget, -j, --test-timeout). Do not pass them; change this file instead.
# Everything cross-test accepts is in `cross-test --help`.

# ---------------------------------------------------------------------------
# CROSS_TIMEOUT - the execution budget, in seconds. Default 300; 900 measured.
# ---------------------------------------------------------------------------
# This project's heaviest test takes 108 s NATIVELY on its own:
# `test.Vec: distance is never below the true Euclidean distance` sweeps
# 4,000,000 cases - the `norm_cases` constant in tests/vector_test.zig - and the
# whole 55-test vector binary also reports 108 s, so essentially all of that is
# that one loop. Natively it fits inside 300 s with room to spare. Under
# qemu_user it does not, and the run then dies inside `zig build` with
#
#   error: 'vector_test.test.Vec: distance is never below the true Euclidean
#          distance' timed out after 5m98.663ms
#   Build Summary: 25/27 steps succeeded (1 failed); 347/348 tests passed (1 timed out)
#
# which cross-test records as `build=pass run=FAIL reason=tests_failed` for
# aarch64-linux and s390x-linux: 347 of 348 tests passed and the harness calls
# the run a failure anyway.
#
# 900 is measured, not chosen for looks: re-run with `--timeout 900` and those
# same two targets report `run=pass tests=348 reason=tests_complete` and the
# run reports `status=pass`. The value reaches Zig as `zig build --test-timeout
# 900s` (cross-test:419), so it is the number the `timed out after 5m98.663ms`
# above is measured against; it is also the wall clock of the run phase for an
# artifact-mode profile (cross-test:603).
#
# CROSS_BUILD_TIMEOUT is deliberately NOT raised: its default of 900 seconds
# already covers compile and run for every target here, and that deadline never
# fired.
CROSS_TIMEOUT=900

# ---------------------------------------------------------------------------
# CROSS_JOBS / CROSS_BUILD_JOBS - the concurrency this project claims.
# ---------------------------------------------------------------------------
# cross-test resolves them as CROSS_JOBS=${CLI_JOBS:-${CROSS_JOBS:-${MAX_JOBS:-2}}}
# and CROSS_BUILD_JOBS=${CLI_BUILD_JOBS:-${CROSS_BUILD_JOBS:-${ZIG_JOBS:-1}}}: with
# nothing set here, an ambient MAX_JOBS or ZIG_JOBS silently becomes this
# project's concurrency. Both readers of the claim are worse than useless in
# that state - CI's guard expands ${CROSS_JOBS:-2}, which is the default and so
# passes vacuously, and its summary check compares target_jobs/jobs_per_build
# with 2 and 1 only after up to two hours of emulated runs. Pinning them here
# makes the claimed profile the effective one: two targets in flight, one build
# job each, whatever the surrounding shell exports. A --jobs or --build-jobs on
# the command line still wins, as CLI precedence says; change this file instead.
CROSS_JOBS=2
CROSS_BUILD_JOBS=1

# ---------------------------------------------------------------------------
# TARGETS - five of the 56, for an ordinary edit. The full table is one flag
# away and stays reachable; see the comment under the array.
# ---------------------------------------------------------------------------
#   x86_64-linux    native. The host itself, no emulator in the loop, and the
#                   only row where a wall-clock figure means what it looks like.
#   aarch64-linux   little-endian 64-bit foreign, qemu_user. AArch64 codegen:
#                   64-bit f64 in a different ABI, NEON-class vector sweeps.
#   riscv64-linux   the other little-endian 64-bit foreign target, and not a
#                   duplicate of the first: RISC-V has no NEON-class baseline,
#                   so its codegen and libcall paths differ from both the host
#                   and AArch64.
#   s390x-linux     BIG-ENDIAN, and the byte-order coverage in this gate table.
#                   Every other target in the table, including the host,
#                   is little-endian. The code a byte-order mistake would break
#                   is the oracle's own: src/rounding.zig:164-199 steps f64
#                   neighbours by u64 bit pattern and the NaN contract trap
#                   reads bit patterns (tests/nan_probe.zig). A green run on
#                   every other target is not evidence about s390x at all. CI's
#                   cross job runs this same profile with qemu-user present and
#                   asserts the runtime rows, so this row is the project's
#                   byte-order coverage in CI as well as here. Drop this row and
#                   the gate table has no byte-order coverage whatsoever.
#                   (`aarch64_be-linux` is big-endian too and has a runner
#                   wherever qemu-user is installed — the full 20-target sweep
#                   runs it 348/348 alongside s390x — but s390x-linux is the row
#                   the gate profile asserts on.)
#   x86_64-windows  build-only here, and that is why it is in the set: it is
#                   compile coverage of the Windows ABI and std paths - non-ELF
#                   object output, .exe naming, the win32 side of std - and
#                   nothing else. cross-test finds no wine, records the target
#                   build_only/runtime_unavailable, and never counts it as a
#                   pass; see the top of this file for what that does to the
#                   status line.
TARGETS=(
    x86_64-linux
    aarch64-linux
    riscv64-linux
    s390x-linux
    x86_64-windows
)

# ---------------------------------------------------------------------------
# CROSS_REQUIRED_RUN_TARGETS - the rows that must have EXECUTED, not compiled.
# ---------------------------------------------------------------------------
# Exactly the four Linux rows above, and deliberately NOT x86_64-windows: on a
# host with no wine that row is compile coverage, and naming it would turn every
# honest green run red.
#
# Read by the installed zig-gate (section 9) straight out of this file, as text,
# in one space-separated list on ONE line; cross-test itself does not read it.
# For every name the gate requires, in the summary.json of the run the gate
# itself bound by CROSS_RUN_ID and nothing older: build=pass, run=pass,
# status=pass, and an executed-test count above zero. A build_only row, a row
# that ran nothing, and a row missing from the summary all fail the section.
#
# That check exists because `fail=0` alone cannot tell a test run from a compile:
# with qemu_user absent every Linux row degrades to build_only/runtime_unavailable
# and an exit-0 cross-test then reports pass=0 with nothing executed anywhere.
# Keep this list and TARGETS in step, keep it on one line, and keep the names
# exactly as cross-test prints them (`cross-test --no-profile --list` is where
# they come from).
CROSS_REQUIRED_RUN_TARGETS='x86_64-linux aarch64-linux riscv64-linux s390x-linux'

# The full table: this profile narrows the SET and leaves CROSS_MATRIX alone,
# so `--targets` still selects from all 56. A release sweep is the same command
# with the list swapped:
#
#   cross-test --targets 'x86_64-linux aarch64-linux riscv64-linux s390x-linux \
#                       aarch64_be-linux powerpc64-linux mips64-linux ...' \
#               --output $HOME/cross-out
#
# For compilation-only coverage of all 56, use the separate profile instead:
#   cross-test --profile ./cross-compile.profile.sh \
#               --output $HOME/compile-out
# That builds the library, all 11 test binaries and the NaN probe through
# `test-compile`, executes none of them and reports build_only=56.
#
# `cross-test --no-profile --list` prints every platform in the table with the
# runner detected for it on the current machine, and is where those names come
# from. Note what `--no-profile` costs: it drops this file, so the 900 s budget,
# the pinned concurrency and the required-run set all go with it - pass
# `--timeout 900`, `--jobs 2 --build-jobs 1` too, and note that the gate cannot
# read a declaration out of a profile it is not given.

# ---------------------------------------------------------------------------
# Nested-build compiler: make the fixture's `zig` the same binary as ours.
# ---------------------------------------------------------------------------
# The `consumer` step in build.zig runs a SECOND `zig build run` for the
# external consumer fixture, and it resolves a BARE `zig` from PATH. So the
# fixture's compiler is picked by a PATH search while cross-test picked one by
# probing `zig env`, and the two can differ: a PATH `zig` is often a shim that
# chooses a compiler version from whatever `.minimum_zig_version` it finds in
# the working directory, and this child runs in fixture/ - a different project.
# It agrees with the outer build today only because fixture/build.zig.zon pins
# the same 0.16.0, which is a coincidence between two files rather than a
# property of the build.
#
# This IS fixable from a profile, and is fixed here. By the time a phase worker
# runs, cross-test has resolved the compiler it is about to execute and exports
# it as ZIG_COMMAND[0]; putting that compiler's own directory first on PATH
# makes the nested build run the SAME binary as the outer one, whatever PATH
# happens to hold. Workers are forked from the parent process, so the one export
# below covers every target and both phases.
#
# What it does NOT fix: which compiler cross-test itself uses. It probes and
# resolves AFTER this file is sourced (cross-test:684), so ZIG_COMMAND is
# still empty in the parent and this guard is a no-op there. Pin the outer
# compiler from the command line with ZIG=, as the invocation above does.
if [[ -n ${ZIG_COMMAND[0]:-} ]]; then
    _xt_zig_dir=${ZIG_COMMAND[0]%/*}
    if [[ ${ZIG_COMMAND[0]} == /* && -n $_xt_zig_dir && -x $_xt_zig_dir/zig ]]; then
        export PATH=$_xt_zig_dir:$PATH
    fi
    unset _xt_zig_dir
fi
