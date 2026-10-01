#!/usr/bin/env bash
# Portable scratch contract for the distributed quality harness.
#
# Sourced by zig-gate, cross-test and the two harness regression scripts. It owns
# exactly one decision: which filesystem locations this harness is allowed to
# write caches, logs and build state to, and what counts as an acceptable one.
#
# WHY THIS FILE EXISTS AT ALL
#
# The scripts it serves were developed against a machine-wide policy at
# ~/.local/lib/host-scratch.sh, and two of them made that file a hard startup
# requirement. That is a developer-home dependency: a cold install with an
# isolated HOME, or any CI runner, has no such file and would exit 2 before
# doing any work. The requirement is removed here WITHOUT dropping the policy:
# the rules that policy enforces are enforced below, and the policy itself is
# still sourced first and still wins whenever it is present.
#
# TWO MODES, CHOSEN BY THE HOST AND NOT BY THE CALLER
#
#   managed   `hostname -s` matches buildhost*. The HU cluster volumes. Here the
#             sanctioned list is a short, deliberate one -- /home/tmp2 and
#             /home/tmp, which are real mounted local ext4 volumes with
#             terabytes behind them -- and the floor is the policy's own 100 GiB
#             (buildhost_STORAGE_MIN_FREE_GIB). /vol/tmp and /vol/tmp2 are
#             sanctioned for scratch but are NFS, and every directory this
#             harness writes is either a Zig cache or is read back by one; an
#             NFS mount rejects renameat2() with EINVAL, so a cache there dies
# inside `zig build` with an error naming the syscall and not the
# volume. They are therefore refused, with that reason named.
#             The ownership and writability rule this file applies to a state
#             directory is applied to cross-test's OUTPUT PREFIX too, once that
#             directory exists and before a lock file is opened inside it, and to
#             its inherited cache base before that base is created.
#             cross-test additionally refuses an output prefix that resolves
#             into /tmp, /var/tmp or /dev/shm, before it creates anything.
#
#   portable  Every other host, including a GitHub runner and a laptop. There
#             is no cluster volume list to honour and nothing to guess, so the
#             contract is explicit ownership: a path is accepted when it is
#             absolute, resolves through symlinks to a real directory that is
#             not itself a symlink, is owned by the calling user, is writable,
#             has at least one gibibyte free, and is not on an NFS filesystem.
#             /tmp is ordinary here -- on a CI runner it is the only sane
#             scratch -- and $HOME is not special. When nothing is named at
#             all, $TMPDIR is used if set and /tmp otherwise; that is the
#             platform default, not a policy decision, and it is still recorded
#             in what the harness prints.
#
# NAMED IS NOT TRUSTED, IN BOTH MODES
#
# An inherited TMPDIR, an inherited cache variable and an explicit flag are all
# validated the same way, because one of them that resolves to a filesystem
# which cannot host a Zig cache moves the exact failure this harness exists to
# prevent into the run it was supposed to check. Validation is destructive-free:
# nothing is created until a candidate has passed.
#
# Not a general library. The callers are bash, and the diagnostics are sentences
# a human reads, not machine codes. Failures are reported through a non-zero
# return and QUALITY_SCRATCH_WHY; no caller has to parse the message.
#
# EVERY variable these functions write is `local`, loop variables included, and
# that is not a style preference: bash scoping is dynamic, so an undeclared loop
# counter here is a global that a nested call silently rewrites in the NEAREST
# CALLER's frame. One missing `local candidate` in quality_scratch_path_ok is
# how quality_scratch_pick returned the matched VOLUME instead of the caller's
# candidate -- a per-user directory quietly becoming the world-shared sticky
# volume above it, with an exit status of 0.
#
# Vendored dependency. Provenance in tools/quality/PROVENANCE.md.

# The cluster's sanctioned list, and only for the cluster. Ordered most capable
# first, which is the order every candidate scan uses.
: "${QUALITY_MANAGED_ROOTS:=/home/tmp2 /home/tmp}"

# Small system volumes. Refused outright in managed mode for anything this
# harness writes; named only so a refusal can explain itself.
: "${QUALITY_SYSTEM_TEMP_ROOTS:=/tmp /var/tmp /dev/shm}"

# The managed free-space floor, in gibibytes, under the machine policy's own
# variable name so one setting governs both copies. The policy skips a volume
# with less than this free rather than filling it up, and that is preserved.
: "${buildhost_STORAGE_MIN_FREE_GIB:=100}"

# The portable free-space floor, in kibibytes. One gibibyte: below it a volume
# counts as full and the next candidate is tried. A cross-test tree is measured
# in gigabytes, so this is a floor for "not obviously broken", not a sizing
# guarantee.
: "${QUALITY_PORTABLE_MIN_FREE_KIB:=1048576}"

# hostname -s is the same probe the machine policy uses to decide whether it
# applies at all, so the distributed copies cannot disagree with it about which
# host this is.
_quality_host_name() { hostname -s 2>/dev/null || uname -n 2>/dev/null || printf 'unknown\n'; }

# 0 when this host is one the cluster policy manages.
quality_scratch_managed() {
    case "$(_quality_host_name)" in
        buildhost*) return 0 ;;
        *) return 1 ;;
    esac
}

quality_scratch_mode() { if quality_scratch_managed; then printf 'managed\n'; else printf 'portable\n'; fi; }

# Free kibibytes at a path, or non-zero when it cannot be read as an integer.
_quality_free_kib() {
    local kib
    kib=$(df -P -k -- "$1" 2>/dev/null | awk 'NR == 2 { print $4 }') || return 1
    case "$kib" in '' | *[!0-9]*) return 1 ;; esac
    printf '%s\n' "$kib"
}

# Filesystem type at a path, lowercased. Used to reject NFS, which is the one
# filesystem property that changes an otherwise working path into a failing
# build. An unreadable type is NOT silently treated as "local": it is refused,
# with its own message, because "we could not tell" and "it is fine" are
# different answers and only one of them is safe to act on.
_quality_fs_type() { stat -f -c %T -- "$1" 2>/dev/null | tr '[:upper:]' '[:lower:]'; }

_quality_fs_ok() {
    case "$(_quality_fs_type "$1")" in
        '') return 2 ;;
        nfs*) return 1 ;;
        *) return 0 ;;
    esac
}

# Why a path was refused, as a sentence a human reads. One implementation, so
# zig-gate and cross-test cannot drift into explaining the same rule differently.
quality_scratch_why() {
    local p real root
    real=$(realpath -m -- "$1" 2>/dev/null) || real=$1
    p=$real
    if [ "$p" != "$1" ]; then
        printf 'it resolves through a symlink to %s, and a link is judged by where it lands\n' "$p"
        return 0
    fi
    for root in $QUALITY_SYSTEM_TEMP_ROOTS; do
        if [ "$p" = "$root" ] || [ "${p#"$root"/}" != "$p" ]; then
            if quality_scratch_managed; then
                printf 'it is a small system volume the cluster asks processes to keep clear\n'
            else
                printf 'it is a system volume, and portable mode expects a directory you own for scratch\n'
            fi
            return 0
        fi
    done
    for root in /vol/tmp /vol/tmp2; do
        if [ "$p" = "$root" ] || [ "${p#"$root"/}" != "$p" ]; then
            printf 'it is NFS, and everything this harness writes feeds a Zig cache that needs renameat2()\n'
            return 0
        fi
    done
    if quality_scratch_managed; then
        # This function is called to EXPLAIN a refusal, so the refusal happened
        # even though the path is on an approved volume: a volume that is not
        # really mounted, a volume below the free-space floor, or a directory
        # this user does not own. Saying "outside the approved volumes" about
        # /home/tmp2/<someone-else> sends the reader after the wrong thing, so
        # the two cases are separated and the second one names what it was.
        for root in $QUALITY_MANAGED_ROOTS; do
            if [ "$p" = "$root" ] || [ "${p#"$root"/}" != "$p" ]; then
                printf 'it is on the approved volume %s, which only takes scratch when it is really mounted and has %s GiB free\n' \
                    "$root" "$buildhost_STORAGE_MIN_FREE_GIB"
                return 0
            fi
        done
        printf 'it is outside the approved physical volumes %s\n' "$QUALITY_MANAGED_ROOTS"
    else
        printf 'it is not a local path this user can create or write to\n'
    fi
}

# Everything that can be decided about a path that DOES NOT EXIST YET: which
# volume it lands on, whether that volume is NFS, and whether it has room. This
# is the check a caller runs before mkdir, and it is separate on purpose:
# creating first and validating afterwards would leave a directory on the very
# volume the refusal is about. 0 when the location may host scratch, non-zero
# with QUALITY_SCRATCH_WHY set otherwise. Creates nothing.
quality_scratch_path_ok() {
    local p root free floor kib probe candidate
    QUALITY_SCRATCH_WHY=
    case "$1" in
        /*) ;;
        *)
            QUALITY_SCRATCH_WHY="it is not an absolute path"
            return 1
            ;;
    esac
    # realpath -m resolves symlinks before anything is judged, so a link that
    # points at /tmp is refused by where it lands and not by how it is spelled.
    p=$(realpath -m -- "$1") || {
        QUALITY_SCRATCH_WHY="it cannot be resolved"
        return 1
    }
    if quality_scratch_managed; then
        root=
        for candidate in $QUALITY_MANAGED_ROOTS; do
            if [ "$p" = "$candidate" ] || [ "${p#"$candidate"/}" != "$p" ]; then root=$candidate; break; fi
        done
        if [ -z "$root" ]; then
            QUALITY_SCRATCH_WHY="it is outside the approved physical volumes $QUALITY_MANAGED_ROOTS"
            return 1
        fi
        if ! command -v mountpoint >/dev/null 2>&1 || ! mountpoint -q -- "$root"; then
            QUALITY_SCRATCH_WHY="$root is not a real mountpoint on this host"
            return 1
        fi
        floor=$((buildhost_STORAGE_MIN_FREE_GIB * 1024 * 1024))
        probe=$root
    else
        root=$p
        floor=$QUALITY_PORTABLE_MIN_FREE_KIB
        probe=$p
    fi
    # The filesystem type and the free space are properties of the VOLUME, not
    # of the directory, so both are read from the nearest ancestor that exists.
    # That ancestor has to exist: a path whose whole parent chain is missing is
    # a typo, not a location to create four levels deep. Reading the filesystem
    # off a directory that is not there yet returns nothing at all, and treating
    # "no answer" as "NFS" would refuse every path this harness is about to
    # create -- including the correct answer on a healthy machine.
    while [ ! -d "$probe" ] && [ "$probe" != / ]; do probe=$(dirname -- "$probe"); done
    [ -d "$probe" ] || {
        QUALITY_SCRATCH_WHY="no part of its parent path exists"
        return 1
    }
    _quality_fs_ok "$probe"
    case $? in
        0) ;;
        2)
            QUALITY_SCRATCH_WHY="the filesystem type of $probe cannot be read, so it cannot be cleared for a Zig cache"
            return 1
            ;;
        *)
            QUALITY_SCRATCH_WHY="it is on an NFS filesystem ($probe), and a Zig cache there needs renameat2()"
            return 1
            ;;
    esac
    free=$(_quality_free_kib "$probe") || {
        QUALITY_SCRATCH_WHY="its free space cannot be read"
        return 1
    }
    kib=$free
    [ "$kib" -ge "$floor" ] 2>/dev/null || {
        QUALITY_SCRATCH_WHY="it has $kib KiB free and this host requires $floor KiB"
        return 1
    }
    return 0
}

# The full acceptance predicate: the location above, plus the directory itself
# being a real, writable, non-symlink directory. Creates nothing.
#
# OWNERSHIP IS A MANAGED-MODE PROPERTY, AND THE DIFFERENCE IS THE POINT. On a
# cluster host the contract is a per-user directory under /home/tmp{,2}, so
# `[ -O ]` is a real check: it refuses another user's leftovers. Off the cluster
# the intended directory may be /tmp, which is owned by root with the sticky
# bit set and is exactly where a CI runner wants to build. Test ownership there
# and the only correct answer is "refused", so portability mode requires
# writability -- which is the property that actually matters, and which honours
# ACLs and group permissions instead of reimplementing them.
quality_scratch_ok() {
    local p
    quality_scratch_path_ok "$1" || return 1
    p=$(realpath -m -- "$1")
    [ -d "$p" ] && [ ! -L "$p" ] && [ -w "$p" ] || {
        QUALITY_SCRATCH_WHY="it is not an existing writable directory"
        return 1
    }
    if quality_scratch_managed && [ ! -O "$p" ]; then
        QUALITY_SCRATCH_WHY="it is not a directory this user owns"
        return 1
    fi
    return 0
}

# Create a directory only after the location has been cleared, then clear it
# again as a directory. The two-step order is the point: a refusal leaves
# nothing behind on the volume the refusal is about.
quality_scratch_make() {
    quality_scratch_path_ok "$1" || return 1
    mkdir -p -- "$1" 2>/dev/null || {
        QUALITY_SCRATCH_WHY="it could not be created: $1"
        return 1
    }
    quality_scratch_ok "$1"
}

# First acceptable candidate, created if it does not exist yet. Prints the path.
# Candidate list order is the caller's; nothing is searched behind its back.
quality_scratch_pick() {
    local candidate
    for candidate in "$@"; do
        [ -n "$candidate" ] || continue
        # quality_scratch_make validates the location before it creates
        # anything, so a rejected candidate leaves no directory behind.
        if quality_scratch_make "$candidate"; then
            realpath -m -- "$candidate"
            return 0
        fi
    done
    return 1
}

# Source the machine-wide policy when there is one, then enforce the contract
# either way. On a managed host the policy's absence is not an error: the rules
# below are the policy's rules, so a cold install with an isolated HOME is
# enforced identically. A policy that IS present is still sourced first and its
# exports still win, which is what keeps this host's behaviour unchanged.
#
# A HOST WITH NO HOME IS A NORMAL HOST, and that is the whole of this function's
# only decision about it. Every caller runs under `set -u`, so the former
# default word expanded $HOME even when nobody had set it, and an unset HOME --
# a container, a cron job, a hardened runner, `env -u HOME` -- aborted the
# caller before it had parsed an argument. The home policy path is now built
# only from an explicit QUALITY_HOST_SCRATCH_POLICY, or from a NON-EMPTY HOME;
# an absent one simply means the policy is absent, and it can never turn into a
# bare /.local/lib/host-scratch.sh lookup.
quality_scratch_load_policy() {
    local policy=
    if [ -n "${QUALITY_HOST_SCRATCH_POLICY:-}" ]; then
        policy=$QUALITY_HOST_SCRATCH_POLICY
    elif [ -n "${HOME:-}" ]; then
        policy=$HOME/.local/lib/host-scratch.sh
    fi
    if [ -n "$policy" ] && [ -r "$policy" ]; then
        # shellcheck source=/dev/null
        . "$policy" || {
            printf 'scratch-contract: machine scratch policy %s failed\n' "$policy" >&2
            return 1
        }
        QUALITY_SCRATCH_POLICY_USED=$policy
    else
        QUALITY_SCRATCH_POLICY_USED=
        if quality_scratch_managed && [ -n "${QUALITY_HOST_SCRATCH_POLICY:-}" ]; then
            printf 'scratch-contract: QUALITY_HOST_SCRATCH_POLICY=%s is not readable\n' \
                "$QUALITY_HOST_SCRATCH_POLICY" >&2
            return 1
        fi
    fi
    QUALITY_SCRATCH_MODE=$(quality_scratch_mode)
    return 0
}
