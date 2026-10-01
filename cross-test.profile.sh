#!/usr/bin/env bash
# cross-test profile for zig-interval.
#
# cross-test is ~/.local/bin/cross-test: OUTSIDE this repository - not
# vendored, not a submodule, not on PATH by default, and nothing `jj status`
# will show it. It discovers this file at ./cross-test.profile.sh and SOURCES
# it, as trusted bash and not as data, both in its own process and in every
# per-target phase worker. A profile in the tree therefore decides what a green
# run COVERS, so read this file before quoting a cross-target table as the
# project's coverage.
#
# Nothing else is set here. The build step is cross-test's own `zig build test`,
# its cache is its own, its concurrency is its default, and CROSS_MATRIX is
# untouched - this file narrows which of the 53 published targets run, it does
# not replace the table. Do not add `set -e`, traps, or a `cd` to this file:
# cross-test runs `set -uo pipefail` without `-e` and forbids a profile from
# changing shell options, traps, or the working directory.
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
#      clean result: x86_64-windows has no runner on this host, so it is
#      reported build_only/runtime_unavailable and never counted as a pass. A
#      green default run says `partial`, not `pass`, and exit status is 0.
#      `--require-runners` would turn that into a failure and is NOT usable
#      here; judge the run by `fail=0` plus five target rows.
#
# A `status=fail` that shows the timeout again means the 900 s budget was
# overridden: `--timeout` on the command line beats this file.
#
# ---------------------------------------------------------------------------
# HOW TO RUN IT ON THIS CHECKOUT
# ---------------------------------------------------------------------------
#   export PATH=/tmp/zigbin:$PATH        # real 0.16.0; the PATH `zig` is an anyzig shim
#   ZIG=/tmp/zigbin/zig cross-test --output /tmp/cross-out
#
# `--output` is not optional here: /nfs rejects `renameat2` with
# EINVAL, so a Zig build cannot keep a cache on the network mount. cross-test
# puts ITS cache under TMPDIR by itself; `--output` is what moves the rest of
# the run - prefix, logs, cross-test-summary.json - onto local disk. Logs and
# the summary land in `--output/cross-test-summary.json` and
# `--output/runs/RUN_ID/build-TARGET.log`.
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
# 4,000,000 cases (`norm_cases`, tests/vector_test.zig:1673), and the whole
# 55-test vector binary also reports 108 s, so essentially all of that is that
# one loop. Natively it fits inside 300 s with room to spare. Under qemu_user
# it does not, and the run then dies inside `zig build` with
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
# 900s` (cross-test:365), so it is the number the `timed out after 5m98.663ms`
# above is measured against; it is also the wall clock of the run phase for an
# artifact-mode profile (cross-test:549).
#
# CROSS_BUILD_TIMEOUT is deliberately NOT raised: its default of 900 seconds
# already covers compile and run for every target here, and that deadline never
# fired.
CROSS_TIMEOUT=900

# ---------------------------------------------------------------------------
# TARGETS - five of the 53, for an ordinary edit. The full table is one flag
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
#   s390x-linux     BIG-ENDIAN, and the only byte-order coverage this project
#                   has. Every other target in the table, including the host,
#                   is little-endian. The code a byte-order mistake would break
#                   is the oracle's own: src/rounding.zig:164-199 steps f64
#                   neighbours by u64 bit pattern and the NaN contract trap
#                   reads bit patterns (tests/nan_probe.zig). A green run on
#                   every other target is not evidence about s390x at all, and
#                   nothing else in the repository runs a big-endian target -
#                   CI's cross job is compile-only. Drop this row and the
#                   project has no byte-order coverage whatsoever.
#                   (`aarch64_be-linux` is big-endian too and has a runner on
#                   this host, but s390x-linux is the row this project has
#                   actually run 348/348 on.)
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

# The full table: this profile narrows the SET and leaves CROSS_MATRIX alone,
# so `--targets` still selects from all 53. A release sweep is the same command
# with the list swapped:
#
#   cross-test --targets 'x86_64-linux aarch64-linux riscv64-linux s390x-linux \
#                       aarch64_be-linux powerpc64-linux mips64-linux ...' \
#               --output /tmp/cross-out
#
# `cross-test --no-profile --list` prints every platform in the table with the
# runner detected for it on this host, and is where those names come from. Note
# what `--no-profile` costs: it drops this file, so the 900 s budget above goes
# with it and the timeout trap comes straight back - pass `--timeout 900` too.

# ---------------------------------------------------------------------------
# Nested-build compiler: make the fixture's `zig` the same binary as ours.
# ---------------------------------------------------------------------------
# build.zig:270-279 runs a SECOND `zig build run` for the external consumer
# fixture, and it resolves a BARE `zig` from PATH. So the fixture's compiler is
# picked by a PATH search while cross-test picked one by probing `zig env`, and
# the two can differ: the PATH `zig` on this host is an anyzig shim that
# chooses a version from whatever `.minimum_zig_version` it finds in the
# working directory, and this child runs in fixture/ - a different project. It
# agrees with the outer build today only because fixture/build.zig.zon pins the
# same 0.16.0, which is a coincidence between two files rather than a property
# of the build.
#
# This IS fixable from a profile, and is fixed here. By the time a phase worker
# runs, cross-test has resolved the compiler it is about to execute and exports
# it as ZIG_COMMAND[0]; putting that compiler's own directory first on PATH
# makes the nested build run the SAME binary as the outer one, whatever PATH
# happens to hold. Workers are forked from the parent process, so the one export
# below covers every target and both phases.
#
# What it does NOT fix: which compiler cross-test itself uses. It probes and
# resolves AFTER this file is sourced (cross-test:602-630), so ZIG_COMMAND is
# still empty in the parent and this guard is a no-op there. Pin the outer
# compiler from the command line with ZIG=, as the invocation above does.
if [[ -n ${ZIG_COMMAND[0]:-} ]]; then
    _xt_zig_dir=${ZIG_COMMAND[0]%/*}
    if [[ ${ZIG_COMMAND[0]} == /* && -n $_xt_zig_dir && -x $_xt_zig_dir/zig ]]; then
        export PATH=$_xt_zig_dir:$PATH
    fi
    unset _xt_zig_dir
fi
