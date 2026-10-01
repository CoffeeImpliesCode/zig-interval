#!/usr/bin/env bash
# Consumer-visible shell regressions. No compiler or emulator is needed here.
#
# Distributed copy: reviewed source, installed with cross-test. Provenance in
# tools/quality/PROVENANCE.md. The assertions are unchanged; what changed is
# that the harness regression suite finds its own command and its own scratch
# beside itself instead of requiring a developer's ~/.local layout, and that the
# system-temp expectations follow the scratch contract's mode rather than a
# hostname test of their own.
set -euo pipefail
LIB_DIR=$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")
source "$LIB_DIR/scratch-contract.sh"
quality_scratch_load_policy
COMMAND=${CROSS_TEST_COMMAND:-$LIB_DIR/../../bin/cross-test}
[ -x "$COMMAND" ] || { printf 'FAIL: cross-test not found at %s\n' "$COMMAND" >&2; exit 1; }
# The same state base cross-test itself would pick: TMPDIR when it verifies,
# otherwise the managed per-user directory, otherwise /tmp. A test harness that
# required an exported TMPDIR could only ever be run by someone who had already
# configured their shell.
if [[ -n ${TMPDIR:-} ]] && quality_scratch_make "$TMPDIR"; then
    BASE=$TMPDIR
elif BASE=$(quality_scratch_pick "${HOST_SCRATCH_ROOT:+$HOST_SCRATCH_ROOT/tmp}" \
    "/home/tmp2/$(id -un)/tmp" "/home/tmp/$(id -un)/tmp" /tmp); then
    :
else
    printf 'FAIL: no usable scratch directory for the regression suite\n' >&2
    exit 1
fi
ROOT=$(mktemp -d "$BASE/cross-test-regressions.XXXXXXXX")
trap 'rm -rf -- "$ROOT"' EXIT
cd "$ROOT"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
run_check() {
  local expected=$1; shift
  local rc=0
  "$COMMAND" "$@" > console.log 2>&1 || rc=$?
  [[ $rc == "$expected" ]] || { cat console.log >&2; fail "exit=$rc expected=$expected"; }
}
reason() { grep -q "\"reason\":\"$1\"" "$2/cross-test-summary.json" || fail "missing reason $1"; }

# quality_scratch_pick must return the candidate it was handed, not the volume
# above it. Bash scoping is dynamic, so one undeclared loop counter in the
# contract rewrote this caller's `candidate` with the matched managed root and
# handed back /home/tmp2 with exit 0: a per-user directory quietly becoming the
# world-shared sticky volume, which is what every rule above exists to prevent.
picked=$(quality_scratch_pick "$BASE") || fail 'quality_scratch_pick refused a usable scratch base'
[[ $picked == "$(realpath -m -- "$BASE")" ]] || fail "quality_scratch_pick returned $picked, not $BASE"

# A failed profile hook must not execute a partial command or remove an artifact.
cat > failed-hook.sh <<'PROFILE'
CROSS_MATRIX=('x86_64-linux|auto')
cross_build_command() { CROSS_COMMAND=(sh -c 'touch must-not-run'); return 7; }
cross_artifact() { printf '%s/sentinel\n' "$CROSS_PREFIX"; }
PROFILE
mkdir hook-out
printf 'keep\n' > hook-out/sentinel
run_check 1 --profile failed-hook.sh --output hook-out
[[ -f hook-out/sentinel && ! -e must-not-run ]] || fail 'failed hook caused side effects'
reason build_hook_failed hook-out

# An artifact outside the output prefix must survive. The command must not run.
cat > unsafe-artifact.sh <<'PROFILE'
CROSS_MATRIX=('x86_64-linux|auto')
cross_build_command() { CROSS_COMMAND=(sh -c 'touch must-not-run'); }
cross_artifact() { printf '%s\n' "$PWD/external-sentinel"; }
PROFILE
printf 'keep\n' > external-sentinel
run_check 1 --profile unsafe-artifact.sh --output unsafe-out
[[ -f external-sentinel && ! -e must-not-run ]] || fail 'unsafe artifact path caused side effects'
reason unsafe_artifact_path unsafe-out

# Resolving a final symlink must not turn deletion of a link into deletion of its target.
cat > symlink-artifact.sh <<'PROFILE'
CROSS_MATRIX=('x86_64-linux|auto')
cross_build_command() { CROSS_COMMAND=(sh -c 'touch must-not-run'); }
cross_artifact() { printf '%s/link\n' "$CROSS_PREFIX"; }
PROFILE
mkdir symlink-out
printf 'keep\n' > symlink-out/protected
ln -s protected symlink-out/link
run_check 1 --profile symlink-artifact.sh --output symlink-out
[[ -f symlink-out/protected && -L symlink-out/link && ! -e must-not-run ]] || fail 'artifact symlink deleted its target'
reason unsafe_artifact_path symlink-out

# Control bytes in the output directory must not make invalid JSON.
output=$'json-\001-\b-\f-"-\\'
run_check 1 --profile failed-hook.sh --output "$output"
python3 -c 'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$output/cross-test-summary.json"

# A zero-length override must not produce a successful zero-target check.
cat > empty.sh <<'PROFILE'
CROSS_MATRIX=()
cross_build_command() { CROSS_COMMAND=(true); }
cross_artifact() { printf '%s/missing\n' "$CROSS_PREFIX"; }
PROFILE
run_check 2 --profile empty.sh --list

# Target strings are filenames: reject traversal before any build side effect.
cat > bad-target.sh <<'PROFILE'
CROSS_MATRIX=('../../escape|auto')
cross_build_command() { CROSS_COMMAND=(sh -c 'touch must-not-run'); }
cross_artifact() { printf '%s/missing\n' "$CROSS_PREFIX"; }
PROFILE
run_check 2 --profile bad-target.sh --output rejected-out
[[ ! -e must-not-run ]] || fail 'invalid target executed a command'

# A multiline selection must include every requested target.
cat > selection.sh <<'PROFILE'
CROSS_MATRIX=('x86_64-linux|auto' 'aarch64-linux|auto')
cross_build_command() { CROSS_COMMAND=(true); }
cross_artifact() { printf '%s/missing\n' "$CROSS_PREFIX"; }
PROFILE
run_check 0 --profile selection.sh --list --targets $'x86_64-linux\naarch64-linux'
grep -q '^aarch64-linux ' console.log || fail 'newline selection silently dropped a target'
run_check 2 --profile selection.sh --list --targets 'x86_64-linux x86_64-linux'
run_check 2 --profile selection.sh --ignored-option

# An explicitly empty array must not silently select the whole matrix.
cat > empty-selection.sh <<'PROFILE'
source "$PWD/selection.sh"
TARGETS=()
PROFILE
run_check 2 --profile empty-selection.sh --list

# A successful build that fails to create a fresh binary must not run stale output.
cat > missing.sh <<'PROFILE'
CROSS_MATRIX=('x86_64-linux|auto')
cross_build_command() { CROSS_COMMAND=(true); }
cross_artifact() { printf '%s/stale\n' "$CROSS_PREFIX"; }
PROFILE
mkdir missing-out
cp /bin/true missing-out/stale
run_check 1 --profile missing.sh --output missing-out
[[ ! -e missing-out/stale ]] || fail 'stale artifact was retained'
reason missing_binary missing-out

# A child exit 124 is not a timeout. A genuine TERM-resistant hang is a timeout.
cat > exits.sh <<'PROFILE'
CROSS_MATRIX=('x86_64-linux|auto')
cross_build_command() { CROSS_COMMAND=(cp /bin/sh "$CROSS_PREFIX/sh"); }
cross_artifact() { printf '%s/sh\n' "$CROSS_PREFIX"; }
cross_run_command() { CROSS_COMMAND=("$2" -c 'exit 124'); }
PROFILE
run_check 1 --profile exits.sh --output exits-out
reason runner_failed exits-out
cat > hangs.sh <<'PROFILE'
CROSS_MATRIX=('x86_64-linux|auto')
cross_build_command() { CROSS_COMMAND=(cp /bin/sh "$CROSS_PREFIX/sh"); }
cross_artifact() { printf '%s/sh\n' "$CROSS_PREFIX"; }
cross_run_command() { CROSS_COMMAND=("$2" -c 'trap "" TERM; sleep 60'); }
PROFILE
run_check 1 --profile hangs.sh --output hangs-out --timeout 1
reason per_run_timeout hangs-out

# Compiling excluded runners is intentional: skip is build-only, not build-excluded.
cat > build-only.sh <<'PROFILE'
CROSS_MATRIX=('aarch64-macos|skip')
cross_build_command() { CROSS_COMMAND=(cp /bin/true "$CROSS_PREFIX/artifact"); }
cross_artifact() { printf '%s/artifact\n' "$CROSS_PREFIX"; }
PROFILE
ZIG="$ROOT/no-such-compiler" run_check 0 --profile build-only.sh --output only-out
[[ -f only-out/artifact ]] || fail 'build-only target did not compile'
reason runner_policy_skip only-out
run_check 1 --profile build-only.sh --output required-out --require-runners

# A compiler hang must not block the entire matrix.
cat > build-hang.sh <<'PROFILE'
CROSS_MATRIX=('x86_64-linux|auto')
cross_build_command() { CROSS_COMMAND=(sh -c 'sleep 60'); }
cross_artifact() { printf '%s/never-created\n' "$CROSS_PREFIX"; }
PROFILE
run_check 1 --profile build-hang.sh --output build-hang-out --build-timeout 1
reason per_build_timeout build-hang-out

# SIGTERM must stop grandchildren, finalize the summary, and release the output lock.
cat > interrupt.sh <<'PROFILE'
CROSS_MATRIX=('x86_64-linux|auto')
cross_build_command() { CROSS_COMMAND=(cp /bin/sh "$CROSS_PREFIX/sh"); }
cross_artifact() { printf '%s/sh\n' "$CROSS_PREFIX"; }
cross_run_command() { CROSS_COMMAND=("$2" -c 'sleep 60 & echo "$!" > child.pid; wait'); }
PROFILE
python3 - "$COMMAND" <<'PY'
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

command = sys.argv[1]
args = [command, "--profile", "interrupt.sh", "--output", "interrupt-out"]
proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
child = None
try:
    deadline = time.monotonic() + 10
    while not Path("child.pid").exists():
        if proc.poll() is not None or time.monotonic() >= deadline:
            raise AssertionError("worker did not reach the running child")
        time.sleep(0.02)
    child = int(Path("child.pid").read_text())
    before = json.loads(Path("interrupt-out/cross-test-summary.json").read_text())
    second = subprocess.run(args, capture_output=True, text=True, timeout=10)
    assert second.returncode == 2, second.stdout + second.stderr
    after = json.loads(Path("interrupt-out/cross-test-summary.json").read_text())
    assert before["run_id"] == after["run_id"], "contender overwrote the active run"
    proc.send_signal(signal.SIGTERM)
    output, _ = proc.communicate(timeout=10)
    assert proc.returncode == 143, output
    result = json.loads(Path("interrupt-out/cross-test-summary.json").read_text())
    assert result["status"] == "interrupted", result
    assert result["exit_code"] == 143, result
    assert result["targets"][0]["build"]["status"] == "pass", result
    stat = Path(f"/proc/{child}/stat")
    assert not stat.exists() or stat.read_text().split()[2] == "Z", "grandchild is still running"
    released = subprocess.run(
        [command, "--profile", "failed-hook.sh", "--output", "interrupt-out"],
        capture_output=True, text=True, timeout=10,
    )
    assert released.returncode == 1, released.stdout + released.stderr
finally:
    if proc.poll() is None:
        proc.terminate()
        proc.communicate(timeout=10)
    if child is not None:
        try:
            os.kill(child, signal.SIGKILL)
        except ProcessLookupError:
            pass
PY

# --output must not put a run's logs and artifacts on a small system temp
# volume on a managed cluster host, and the refusal must land before any
# directory, lock file or run directory exists. Expectations follow the host,
# not the flag: the same paths stay generic where the contract has no opinion.
# build-only.sh supplies a real artifact hook, so an accepted run really builds
# its artifact. The mode comes from the contract itself rather than a second
# hostname test, so the suite cannot disagree with the code it is testing.
MANAGED_HOST=0
quality_scratch_managed && MANAGED_HOST=1
SYSTEM_TEMP_NAME="cross-test-system-temp-${ROOT##*/}"
SYSTEM_TEMP_OUT=()
for root in $QUALITY_SYSTEM_TEMP_ROOTS; do SYSTEM_TEMP_OUT+=("$root/$SYSTEM_TEMP_NAME"); done
if ((MANAGED_HOST)); then
  for path in "${SYSTEM_TEMP_OUT[@]}"; do
    run_check 2 --profile build-only.sh --output "$path"
    [[ ! -e $path ]] || fail "refused output was still created: $path"
  done
  # A link is judged by where it lands, not by how it is spelled.
  ln -s /tmp system-temp-link
  run_check 2 --profile build-only.sh --output "$ROOT/system-temp-link/$SYSTEM_TEMP_NAME"
  [[ ! -e /tmp/$SYSTEM_TEMP_NAME ]] || fail 'a symlinked system temp output was created'
  # The same run against approved scratch still works, and produces its artifact.
  run_check 0 --profile build-only.sh --output approved-out
  [[ -f approved-out/artifact ]] || fail 'approved scratch output did not build'
else
  for path in "${SYSTEM_TEMP_OUT[@]}"; do
    run_check 0 --profile build-only.sh --output "$path"
    [[ -f $path/artifact ]] || fail "generic output was not used: $path"
    rm -rf -- "$path"
  done
fi

# A host with no HOME is a normal host. Every caller runs under `set -u`, and the
# policy lookup used to expand $HOME in its default word, so an unset HOME aborted
# cross-test with an unbound-variable error before it parsed a single argument --
# including --list and --help, on a container or a hardened runner with no home.
if env -u HOME "$COMMAND" --profile selection.sh --list > console.log 2>&1; then :; else
  cat console.log >&2; fail 'an unset HOME aborted cross-test before argument parsing'
fi
grep -q '^aarch64-linux ' console.log || fail 'an unset HOME changed the selected targets'

# An inherited ZIG_GLOBAL_CACHE_DIR is held to the same contract as TMPDIR and
# --output, and refused BEFORE it creates anything. It used to be mkdir'ed
# unvalidated, which turned a refusal into a renameat2 error inside every
# `zig build` of the run and left the directory behind. A relative name is the
# one value every host refuses, so the expectation does not depend on the mode.
#
# A readable machine policy would legitimately override this value and the run
# would then be ACCEPTED, which would be correct behaviour rather than a bug, so
# the case points QUALITY_HOST_SCRATCH_POLICY at an empty readable file first:
# what is under test is the caller's own value reaching the contract, not the
# host's policy winning, which is what it is for.
export QUALITY_HOST_SCRATCH_POLICY=/dev/null
export ZIG_GLOBAL_CACHE_DIR=refused-relative-cache
if run_check 2 --profile build-only.sh --output refused-cache-out; then :; fi
unset ZIG_GLOBAL_CACHE_DIR QUALITY_HOST_SCRATCH_POLICY
[[ ! -e refused-relative-cache ]] || fail 'a refused ZIG_GLOBAL_CACHE_DIR was created anyway'
# Nothing was created for the refused value, and no run was published. The run
# directory itself is created earlier in setup than the cache base is judged, so
# an empty runs/<id> may be there; the guarantee is that no cache was made and no
# summary was written, which is what "refused before mkdir" has to mean.
[[ ! -e refused-cache-out/cross-test-summary.json ]] ||
  fail 'a run was started with a refused cache base'
grep -q 'cannot host the cross-test cache' console.log ||
  fail 'a refused ZIG_GLOBAL_CACHE_DIR did not name the reason'

# The output prefix is judged as a directory and not only as a location, and the
# judgement lands before the lock file and the run directory. Skipped as root,
# where -w is true on a mode-500 directory and the refusal cannot exist.
if [[ $(id -u) != 0 ]]; then
  mkdir unwritable-out
  chmod 500 unwritable-out
  if run_check 2 --profile build-only.sh --output unwritable-out; then :; fi
  chmod 700 unwritable-out
  [[ ! -e unwritable-out/.cross-test.lock && ! -e unwritable-out/runs ]] ||
    fail 'a non-writable output prefix was written into'
fi

printf 'PASS: hook failures, path/symlink safety, JSON, validation, selection, stale artifacts, exit codes, build/run timeouts, build-only policy, locks, signals, grandchildren, system-temp output refusal, approved scratch, scratch-pick identity, an unset HOME, a refused cache base and a non-writable output prefix\n'
