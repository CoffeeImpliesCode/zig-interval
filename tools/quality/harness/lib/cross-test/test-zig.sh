#!/usr/bin/env bash
# Real build-graph regressions: native generators, unavailable OSes, and forced QEMU.
#
# Distributed copy: reviewed source, installed with cross-test. Provenance in
# tools/quality/PROVENANCE.md. The build-graph assertions are unchanged; the
# command and the scratch base are resolved beside this script instead of from a
# developer's ~/.local layout.
set -euo pipefail
LIB_DIR=$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")
source "$LIB_DIR/scratch-contract.sh"
source "$LIB_DIR/zig-targets.sh"
quality_scratch_load_policy
COMMAND=${CROSS_TEST_COMMAND:-$LIB_DIR/../../bin/cross-test}
[ -x "$COMMAND" ] || { printf 'FAIL: cross-test not found at %s\n' "$COMMAND" >&2; exit 1; }
CROSS_HOST_ARCH=$(uname -m)
CROSS_HOST_OS=linux
native=$(cross_tz_normalize_host_arch "$CROSS_HOST_ARCH")-linux
# Same state base cross-test itself would pick, for the reason given in test.sh.
if [[ -n ${TMPDIR:-} ]] && quality_scratch_make "$TMPDIR"; then
    BASE=$TMPDIR
else
    SCRATCH_CANDIDATES=()
    if [[ -n ${HOST_SCRATCH_ROOT:-} ]]; then SCRATCH_CANDIDATES+=("$HOST_SCRATCH_ROOT/tmp"); fi
    if quality_scratch_managed; then
        SCRATCH_USER=$(id -un)
        for SCRATCH_ROOT in $QUALITY_MANAGED_ROOTS; do
            SCRATCH_CANDIDATES+=("$SCRATCH_ROOT/$SCRATCH_USER/tmp")
        done
    fi
    SCRATCH_CANDIDATES+=(/tmp)
    if ! BASE=$(quality_scratch_pick "${SCRATCH_CANDIDATES[@]}"); then
        printf 'FAIL: no usable scratch directory for the regression suite\n' >&2
        exit 1
    fi
fi
ROOT=$(mktemp -d "$BASE/cross-test-zig-regressions.XXXXXXXX")
trap 'rm -rf -- "$ROOT"' EXIT
cd "$ROOT"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
run_check() {
  local expected=$1; shift
  local rc=0
  "$COMMAND" --no-profile --output "$ROOT/out" "$@" > console.log 2>&1 || rc=$?
  [[ $rc == "$expected" ]] || { cat console.log >&2; fail "exit=$rc expected=$expected"; }
}
# Executable-based checks must not require Zig's unit-test result protocol.
cat > build.zig <<'ZIG'
const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const checks = b.step("test", "Run executable checks");
    if (b.option(bool, "empty", "Do not execute any checks") orelse false) return;
    const module = b.createModule(.{
        .root_source_file = b.path("check.zig"),
        .target = target,
    });
    const options = b.addOptions();
    options.addOption(bool, "fail_run", b.option(bool, "fail-run", "Fail execution") orelse false);
    options.addOption(bool, "fail_compile", b.option(bool, "fail-compile", "Fail compilation") orelse false);
    module.addOptions("options", options);
    const executable = b.addExecutable(.{ .name = "behavior-check", .root_module = module });
    const run = b.addRunArtifact(executable);
    run.has_side_effects = true;
    checks.dependOn(&run.step);
    if (b.option(bool, "partial", "Also execute a host check") orelse false) {
        const host_module = b.createModule(.{
            .root_source_file = b.path("check.zig"),
            .target = b.graph.host,
        });
        host_module.addOptions("options", options);
        const host_check = b.addExecutable(.{ .name = "host-check", .root_module = host_module });
        const host_run = b.addRunArtifact(host_check);
        host_run.has_side_effects = true;
        checks.dependOn(&host_run.step);
    }
}
ZIG
cat > check.zig <<'ZIG'
const std = @import("std");
const options = @import("options");
comptime {
    if (options.fail_compile) @compileError("intentional executable compile failure");
}
pub fn main() void {
    if (options.fail_run) std.process.exit(23);
    std.debug.assert(std.mem.readInt(u32, &.{ 0x12, 0x34, 0x56, 0x78 }, .big) == 0x12345678);
    std.debug.print("EXECUTABLE_CHECK_COMPLETE\n", .{});
}
ZIG
selection="$native aarch64-freebsd"
qemu_target=
cross_detect_runner aarch64-linux
if [[ $CROSS_RUNNER_KIND == exec ]]; then qemu_target=aarch64-linux; selection+=" $qemu_target"; fi
run_check 0 --targets "$selection" --jobs 2
python3 - "$ROOT/out/cross-test-summary.json" "$native" "$qemu_target" <<'PY'
import json
from pathlib import Path
import sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
by_target = {entry["target"]: entry for entry in result["targets"]}
assert result["status"] == "partial", result
assert not result["bookkeeping_failure"], result
for target in filter(None, sys.argv[2:]):
    entry = by_target[target]
    assert entry["build"]["status"] == "pass", entry
    assert entry["run"]["status"] == "pass", entry
    assert entry["run"]["tests"] is None, entry
    assert "EXECUTABLE_CHECK_COMPLETE" in Path(entry["run"]["log"]).read_text(), entry
foreign = by_target["aarch64-freebsd"]
assert foreign["build"]["status"] == "pass", foreign
assert foreign["run"]["status"] == "unavailable", foreign
assert foreign["run"]["tests"] is None, foreign
assert "EXECUTABLE_CHECK_COMPLETE" not in Path(foreign["run"]["log"]).read_text(), foreign
print("PASS: executable checks ran natively and via QEMU; unavailable execution is build-only")
PY
run_check 1 --targets aarch64-freebsd --require-runners
grep -q '"status":"incomplete"' "$ROOT/out/cross-test-summary.json" || fail 'strict executable coverage passed'
run_check 0 --targets aarch64-freebsd -- -Dpartial=true
python3 - "$ROOT/out/cross-test-summary.json" <<'PY'
import json
import sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
entry = result["targets"][0]
assert result["status"] == "partial", result
assert entry["build"]["status"] == "pass", entry
assert entry["run"]["status"] == "partial", entry
assert entry["run"]["tests"] is None, entry
PY
run_check 1 --targets aarch64-freebsd --require-runners -- -Dpartial=true
grep -q '"status":"incomplete"' "$ROOT/out/cross-test-summary.json" || fail 'strict partial executable coverage passed'
run_check 1 --targets "$native" -- -Dfail-run=true
python3 - "$ROOT/out/cross-test-summary.json" <<'PY'
import json
import sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
entry = result["targets"][0]
assert result["status"] == "fail", result
assert entry["build"]["status"] == "pass", entry
assert entry["run"]["status"] == "fail", entry
assert entry["run"]["exit"] != 0, entry
assert entry["run"]["tests"] is None, entry
PY
run_check 1 --targets aarch64-freebsd -- -Dfail-compile=true
grep -q '"build":{"status":"fail"' "$ROOT/out/cross-test-summary.json" || fail 'executable compile failure was hidden'
run_check 1 --targets "$native" -- -Dempty=true
grep -q '"status":"fail"' "$ROOT/out/cross-test-summary.json" || fail 'empty test step passed'
printf 'PASS: executable strict/partial coverage and compile/run failures\n'

cat > build.zig <<'ZIG'
const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const generator = b.addSystemCommand(&.{
        "sh", "-c", "printf 'pub const answer: u32 = 37;\\n' > \"$1\"", "generator",
    });
    const generated = generator.addOutputFileArg("config.zig");
    const module = b.createModule(.{
        .root_source_file = b.path("root.zig"),
        .target = target,
    });
    module.addImport("config", b.createModule(.{ .root_source_file = generated }));
    const tests = b.addTest(.{ .root_module = module });
    const run = b.addRunArtifact(tests);
    b.step("test", "Run behavior tests").dependOn(&run.step);
}
ZIG
cat > root.zig <<'ZIG'
const std = @import("std");
test "generated configuration" {
    try std.testing.expectEqual(@as(u32, 37), @import("config").answer);
}
test "big-endian decoding" {
    try std.testing.expectEqual(@as(u32, 0x12345678), std.mem.readInt(u32, &.{ 0x12, 0x34, 0x56, 0x78 }, .big));
}
test "checked addition" {
    try std.testing.expectError(error.Overflow, std.math.add(u8, 255, 1));
}
ZIG
selection="$native aarch64-freebsd"
qemu_target=
cross_detect_runner x86-linux
if [[ $CROSS_RUNNER_KIND == exec ]]; then qemu_target=x86-linux; selection+=" $qemu_target"; fi
run_check 0 --targets "$selection" --jobs 2
python3 - "$ROOT/out/cross-test-summary.json" "$native" "$qemu_target" <<'PY'
import json
import sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
by_target = {entry["target"]: entry for entry in result["targets"]}
assert result["status"] == "partial", result
assert not result["bookkeeping_failure"], result
for target in filter(None, sys.argv[2:]):
    assert by_target[target]["run"]["status"] == "pass", by_target[target]
    assert by_target[target]["run"]["tests"] == 3, by_target[target]
foreign = by_target["aarch64-freebsd"]
assert foreign["build"]["status"] == "pass", foreign
assert foreign["run"]["status"] == "unavailable", foreign
assert foreign["command_exit"] == 0, foreign
print("PASS: native generator and foreign build-only behavior; QEMU target:", sys.argv[3] or "none available")
PY
# The same output directory must not reuse cached native test results.
run_check 0 --targets "$native"
python3 - "$ROOT/out/cross-test-summary.json" <<'PY'
import json
import sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
assert result["status"] == "pass", result
assert result["targets"][0]["run"]["tests"] == 3, result
PY
# Replacing the matrix must not remove the compiler argv used by artifact hooks.
compiler=$(python3 - "$ROOT/out/cross-test-summary.json" <<'PY'
import json
from pathlib import Path
import shlex
import sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
log = Path(result["targets"][0]["build"]["log"]).read_text()
command = next(line.removeprefix("command=") for line in log.splitlines() if line.startswith("command="))
print(shlex.split(command)[0])
PY
)
cat > profile-tests.zig <<'ZIG'
const std = @import("std");
test "big-endian encoding" {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, 0x12345678, .big);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x56, 0x78 }, &bytes);
}
test "checked multiplication" {
    try std.testing.expectError(error.Overflow, std.math.mul(u8, 128, 2));
}
ZIG
printf 'CROSS_MATRIX=(%q)\n' "$native|auto" > artifact-profile.sh
cat >> artifact-profile.sh <<'PROFILE'
cross_artifact() { printf '%s/tests-%s\n' "$CROSS_PREFIX" "$1"; }
cross_build_command() {
  local artifact
  artifact=$(cross_artifact "$1") || return
  CROSS_COMMAND=("${ZIG_COMMAND[@]}" test profile-tests.zig -target "$1"
    --test-no-exec "-femit-bin=$artifact" --cache-dir "$CROSS_CACHE_DIR"
    "${CROSS_BUILD_ARGS[@]}")
}
PROFILE
rc=0
ZIG="$compiler" "$COMMAND" --profile artifact-profile.sh --output "$ROOT/profile-out" > profile-console.log 2>&1 || rc=$?
[[ $rc == 0 ]] || { cat profile-console.log >&2; fail "artifact profile with explicit matrix failed: exit=$rc"; }
python3 - "$ROOT/profile-out/cross-test-summary.json" <<'PY'
import json
import sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
assert result["status"] == "pass", result
entry = result["targets"][0]
assert entry["build"]["status"] == "pass", entry
assert entry["run"]["status"] == "pass", entry
assert entry["run"]["tests"] == 2, entry
print("PASS: artifact profile matrix override compiled and ran two real tests")
PY
run_check 1 --targets aarch64-freebsd --require-runners
grep -q '"status":"incomplete"' "$ROOT/out/cross-test-summary.json" || fail 'strict runner policy passed'
# Unavailable execution must not hide an actual compile error.
cat > root.zig <<'ZIG'
comptime { @compileError("intentional compile failure"); }
ZIG
run_check 1 --targets aarch64-freebsd
grep -q '"build":{"status":"fail"' "$ROOT/out/cross-test-summary.json" || fail 'compile failure was hidden'
cat > root.zig <<'ZIG'
const std = @import("std");
test "intentional failed assertion" {
    try std.testing.expectEqual(@as(u32, 7), @as(u32, 3));
}
ZIG
run_check 1 --targets "$native"
grep -q '"reason":"tests_failed"' "$ROOT/out/cross-test-summary.json" || fail 'test failure was hidden'
# A compiled Zig test binary with zero tests is not an executable check.
cat > root.zig <<'ZIG'
pub const answer: u32 = 37;
ZIG
run_check 1 --targets "$native"
grep -q '"reason":"no_test_results"' "$ROOT/out/cross-test-summary.json" || fail 'zero-test binary passed'
cat > root.zig <<'ZIG'
const std = @import("std");
test "the configured deadline reaches the test runner" {
    try std.Io.sleep(std.testing.io, .fromSeconds(2), .awake);
}
ZIG
run_check 1 --targets "$native" --timeout 1
grep -q 'timed out' "$ROOT/out/runs/"*/build-"$native".log ||
  fail 'the selected compiler ignored the configured test deadline'
printf 'PASS: fresh repeated execution, strict coverage, compiler errors, and failed tests\n'
