#!/usr/bin/env bash
# Compilation-only coverage of the pinned harness's complete Zig 0.17.0 matrix.
# Run from this repository with the installed cross-test:
#   ZIG=/absolute/path/to/zig cross-test --profile ./cross-compile.profile.sh \
#     --output /absolute/local/scratch/compile-out
# The normal cross-test.profile.sh retains its five-target runtime coverage.

# Reuse the published table, validating the selected compiler version before
# replacing runner policies. Never duplicate or narrow the target list here.
cross_default_matrix "$("${ZIG:-zig}" version)" || return
for i in "${!CROSS_MATRIX[@]}"; do
    CROSS_MATRIX[$i]="${CROSS_MATRIX[$i]%%|*}|skip"
done
unset i
# The default sweep is complete even if the caller exported a runtime subset.
# An explicit cross-test --targets option still selects a diagnostic subset.
unset TARGETS

CROSS_JOBS=2
CROSS_BUILD_JOBS=1
CROSS_BUILD_TIMEOUT=900
CROSS_REQUIRE_RUNNERS=0

cross_artifact() {
    case "$1" in
        *-windows) printf '%s/%s/lib/interval.lib\n' "$CROSS_PREFIX" "$1" ;;
        *) printf '%s/%s/lib/libinterval.a\n' "$CROSS_PREFIX" "$1" ;;
    esac
}

cross_build_command() {
    CROSS_COMMAND=("${ZIG_COMMAND[@]}" build test-compile "-Dtarget=$1"
        "-j$CROSS_BUILD_JOBS" --prefix "$CROSS_PREFIX/$1"
        --cache-dir "$CROSS_CACHE_DIR" --summary all --color off
        "${CROSS_BUILD_ARGS[@]}")
}
