#!/usr/bin/env bash
# Project scratch space, resolved through the harness's own scratch contract.
#
# Rechnerbetriebsgruppe (2026-10-01) asked that processes stop filling local
# /tmp and /var/tmp: on a buildhost host both are small local ext4 volumes, /tmp is
# 10 G. `~/.local/lib/host-scratch.sh` is the machine-wide answer to that - it
# runs only on buildhost*, requires the candidate to be a real mountpoint with a
# writable path and at least 100 GiB free, refuses symlinked or foreign-owned
# directories, and exports HOST_SCRATCH_ROOT, buildhost_CACHE_ROOT, TMPDIR,
# XDG_CACHE_HOME and ZIG_GLOBAL_CACHE_DIR. That policy is the thing to use, and
# it is still sourced when it is there.
#
# WHY THIS FILE IS NOW A THIN WRAPPER. It used to carry its own copy of the
# rule: a hardcoded list of volumes, its own "is this a real local directory"
# test, and `~/.local/lib/host-scratch.sh` as a hard prerequisite. Three homes
# for one policy, and they had already drifted - the harness resolves scratch
# through tools/quality/harness/lib/cross-test/scratch-contract.sh, which
# enforces the same rules with no prerequisite at all. Two copies of a rule is
# one too many the first time an administrator changes either.
#
# So the decision left here is the one only THIS file can make: which
# candidates to offer. What counts as local, how much free space a volume needs,
# symlinks, ownership, the NFS refusal and the machine-wide policy are all asked
# of the contract - the same helper the installed zig-gate and cross-test use,
# from the same file, so this repository has one implementation of the rule and
# three callers of it.
#
# WHAT IT STILL REFUSES TO DO, on purpose:
#
#   * Fall back to /tmp. That is the volume the cluster asked to keep clear.
#     `TMPDIR` is honoured when the ENVIRONMENT names it, because that is
#     somebody's decision rather than this file's, but an unnamed /tmp is never
#     chosen here. The contract's portable mode accepts /tmp, and it is right
#     to: on a CI runner it is the only sane scratch. It is the wrong default
#     for this file's job.
#   * Create, edit or depend on a machine-wide policy, and clean up after
#     itself. It resolves a path; nothing else.
#
# One constraint, specific to this project: a Zig build cache must be on LOCAL
# storage. The repository itself lives on an NFS mount that rejects renameat2
# with EINVAL, and every build command in docs/performance-handover.md passes
# --cache-dir explicitly for that reason. The host policy will happily offer
# /vol/tmp and /vol/tmp2, which are NFS and are the sanctioned volumes on every
# buildhost; pointing a build cache there fails with
# `programmer bug caused syscall error: INVAL` before a single file is written.
#
# So NFS candidates are filtered OUT here, not because they are unsanctioned -
# they are not - but because they do not work for this one thing. That is the
# contract's test, not a second list here, so a volume somebody adds to the
# policy is judged by one rule rather than two.

# shellcheck shell=bash
_scratch_here=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
_scratch_contract="$_scratch_here/../tools/quality/harness/lib/cross-test/scratch-contract.sh"

_scratch_bail() {
    printf 'scratch.sh: %s\n' "$1" >&2
    return 1 2>/dev/null || exit 1
}

if [ ! -r "$_scratch_contract" ]; then
    _scratch_bail "cannot read the scratch contract at $_scratch_contract
       it ships with the quality harness under tools/quality/; without it there is no policy to ask."
fi
# shellcheck source=../tools/quality/harness/lib/cross-test/scratch-contract.sh
. "$_scratch_contract" || _scratch_bail "cannot load the scratch contract $_scratch_contract"
unset _scratch_here _scratch_contract

scratch_root() {
    local user d

    # 1. An explicit override always wins, including a deliberate one outside
    #    every list below. Validated rather than trusted, because a typo here
    #    silently recreates the original problem under a different name - and
    #    validated by the harness's own predicate, so an override that would
    #    fail a gate run fails here first, with the same reason.
    if [ -n "${ZIG_INTERVAL_SCRATCH:-}" ]; then
        if quality_scratch_ok "${ZIG_INTERVAL_SCRATCH%/}"; then
            printf '%s\n' "${ZIG_INTERVAL_SCRATCH%/}"
            return 0
        fi
        printf 'scratch.sh: ZIG_INTERVAL_SCRATCH=%s refused: %s\n' \
            "${ZIG_INTERVAL_SCRATCH}" "$QUALITY_SCRATCH_WHY" >&2
        return 1
    fi

    # The machine-wide policy, when there is one. NOT a prerequisite: on a
    # managed host its absence is not an error, because the rules below are the
    # policy's rules. Where it IS present it is sourced first and its exports
    # still win, which is what keeps this host's behaviour unchanged.
    quality_scratch_load_policy || {
        printf 'scratch.sh: cannot establish a scratch policy on this host\n' >&2
        return 1
    }

    # 2. Whatever the machine-wide policy chose, if it chose one. An input, not
    #    a decision: quality_scratch_pick clears every candidate it is given, so
    #    an NFS or too-small root is skipped rather than handed on. An empty
    #    root is absent here, exactly as it is in the policy's own case
    #    statement - a root that expands to the empty string matches no pattern,
    #    and accepting one is how this function used to print a blank line and
    #    return success.
    set -- ${HOST_SCRATCH_ROOT:+"$HOST_SCRATCH_ROOT"}

    if quality_scratch_managed; then
        # 3. This user's own directory under each approved volume, in the
        #    contract's order and most capable first. QUALITY_MANAGED_ROOTS is
        #    the contract's variable: the sanctioned list is named once, in the
        #    file that enforces it, and not restated here where it could drift.
        user=$(id -un 2>/dev/null || printf '%s' "${USER:-unknown}")
        for d in $QUALITY_MANAGED_ROOTS; do
            set -- "$@" "$d/$user"
        done
    else
        # 4. Off a managed host there is no cluster list to honour, and
        #    nothing worth inventing. An explicitly named TMPDIR is offered;
        #    an unnamed /tmp is not, which is the refusal stated at the top.
        set -- "$@" ${TMPDIR:+"$TMPDIR"}
    fi

    if quality_scratch_pick "$@"; then
        return 0
    fi

    # 5. Say what was checked and what to do about it, instead of choosing a
    #    volume on the caller's behalf.
    cat >&2 <<'EOF'
scratch.sh: no usable local scratch volume found.

Checked, in this order: $ZIG_INTERVAL_SCRATCH; the root the machine-wide
policy named (HOST_SCRATCH_ROOT), if it named one; then this user's own
directory under each approved local volume (/home/tmp2/$USER, /home/tmp/$USER
on a managed cluster host), or an explicitly set TMPDIR elsewhere.

Every candidate is cleared by the harness's own scratch contract before it is
offered, so a root that was refused is refused for a stated reason: not local,
not NFS, not a real mountpoint, not owned by you, or not enough free space.

/vol/tmp and /vol/tmp2 are deliberately not offered. They are sanctioned on
every buildhost, but both are NFS, and this project's builds fail there with
renameat2 EINVAL - see docs/performance-handover.md. They are fine for bulk
data and wrong for a Zig build cache.

If this host genuinely has no large local volume, name one yourself:

    export ZIG_INTERVAL_SCRATCH=/path/on/local/disk

It is validated, not trusted: an unusable path is refused with its reason.
EOF
    return 1
}

# For scripts that want a named subdirectory made and exported.
scratch_init() {
    SCRATCH_ROOT="$(scratch_root)" || return 1
    SCRATCH_DIR="${SCRATCH_ROOT%/}/$1"
    mkdir -p "$SCRATCH_DIR" || return 1
    export SCRATCH_ROOT SCRATCH_DIR
    return 0
}
