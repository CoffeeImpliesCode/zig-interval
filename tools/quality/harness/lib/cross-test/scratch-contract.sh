#!/usr/bin/env bash
# Portable scratch contract for the distributed quality harness.
#
# Sourced by zig-gate, cross-test and the two harness regression scripts. It owns
# exactly one decision: which filesystem locations this harness is allowed to
# write caches, logs and build state to, and what counts as an acceptable one.
#
# WHY THIS FILE EXISTS AT ALL
#
# The scripts it serves were developed against a machine-wide policy in a
# developer's home, and two of them made that file a hard startup
# requirement. That is a developer-home dependency: a cold install with an
# isolated HOME, or any CI runner, has no such file and would exit 2 before
# doing any work. The requirement is removed here WITHOUT dropping the policy:
# the rules that policy enforces are enforced below, and a policy is still
# sourced first and still wins whenever QUALITY_HOST_SCRATCH_POLICY names a
# readable one. Nothing here is read out of $HOME any more: a host that wants
# a machine-wide policy names it, and a host that names nothing gets the rules
# in this file, which are the same ones.
#
# TWO MODES, AND THE ENVIRONMENT DECIDES WHICH ONE
#
#   managed   QUALITY_MANAGED_ROOTS is set and not empty. Somebody has named
#             the volumes this host is willing to build on, and the contract
#             holds every location to that list: the path has to be on one of
#             them, that volume has to be a real mountpoint with at least
#             QUALITY_MANAGED_MIN_FREE_GIB free, and the directory has to be
#             this user's. QUALITY_MANAGED_HOST_PATTERN, when set, narrows
#             managed mode further to hosts whose `hostname -s` matches it, so
#             one exported list can be shared by a profile without switching
#             the rule on wherever else that profile is read.
#             The small system volumes are refused outright, never as a last
#             resort. NFS is refused in both modes: every directory this
#             harness writes is either a Zig cache or is read back by one, and
#             an NFS mount rejects renameat2() with EINVAL, so a cache there
#             dies inside `zig build` with an error naming the syscall and not
#             the volume.
#             The ownership and writability rule this file applies to a state
#             directory is applied to cross-test's OUTPUT PREFIX too, once that
#             directory exists and before a lock file is opened inside it, and to
#             its inherited cache base before that base is created.
#             cross-test additionally refuses an output prefix that resolves
#             into a system temp volume, before it creates anything.
#
#   portable  Every host that has named no volumes, which is every host that
#             has not asked for managed mode -- a GitHub runner, a laptop, a
#             cold install. There is no volume list to honour and nothing to
#             guess, so the contract is explicit ownership: a path is accepted
#             when it is absolute, resolves through symlinks to a real
#             directory that is not itself a symlink, is writable, has at
#             least one gibibyte free, and is not on an NFS filesystem. A
#             system temp volume is ordinary here -- on a CI runner it is the
#             only sane scratch -- and $HOME is not special. When nothing is
#             named at all, $TMPDIR is used if set and /tmp otherwise; that is
#             the platform default, not a policy decision, and it is still
#             recorded in what the harness prints.
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

# The volumes a managed host is willing to build on, ordered most capable
# first, which is the order every candidate scan uses. EMPTY BY DEFAULT, and
# that default is the point: nothing named means nothing to honour and nothing
# to guess, so every host that has not asked for managed mode gets portable
# mode. No host name, no directory and no storage layout is assumed here; a
# host that wants managed mode names its own volumes and exports them.
: "${QUALITY_MANAGED_ROOTS:=}"

# Optional narrowing of managed mode to matching hosts: a shell glob, used as a
# case pattern against `hostname -s`. Empty means no narrowing, so a list
# exported by a shared profile applies wherever it is read unless a host
# deliberately scopes it with this.
: "${QUALITY_MANAGED_HOST_PATTERN:=}"

# Small system volumes. Refused outright in managed mode for anything this
# harness writes; named only so a refusal can explain itself.
: "${QUALITY_SYSTEM_TEMP_ROOTS:=/tmp /var/tmp /dev/shm}"

# The managed free-space floor, in gibibytes. A volume with less free than this
# is skipped rather than filled up, and that is preserved.
: "${QUALITY_MANAGED_MIN_FREE_GIB:=100}"

# The portable free-space floor, in kibibytes. One gibibyte: below it a volume
# counts as full and the next candidate is tried. A cross-test tree is measured
# in gigabytes, so this is a floor for "not obviously broken", not a sizing
# guarantee.
: "${QUALITY_PORTABLE_MIN_FREE_KIB:=1048576}"

# 0 when this host is one the environment manages. Two questions in order:
# has anybody named the approved volumes at all, and -- only when a host
# pattern is set -- does this host pass it. An empty list is never managed, so
# the unset-environment case is portable mode everywhere without an exception
# to remember, and the hostname probe only runs on a host that asked for it.
quality_scratch_managed() {
    [ -n "${QUALITY_MANAGED_ROOTS:-}" ] || return 1
    [ -n "${QUALITY_MANAGED_HOST_PATTERN:-}" ] || return 0
    case "$(hostname -s 2>/dev/null || uname -n 2>/dev/null)" in
        $QUALITY_MANAGED_HOST_PATTERN) return 0 ;;
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
    local p real root probe
    real=$(realpath -m -- "$1" 2>/dev/null) || real=$1
    p=$real
    if [ "$p" != "$1" ]; then
        printf 'it resolves through a symlink to %s, and a link is judged by where it lands\n' "$p"
        return 0
    fi
    for root in $QUALITY_SYSTEM_TEMP_ROOTS; do
        if [ "$p" = "$root" ] || [ "${p#"$root"/}" != "$p" ]; then
            if quality_scratch_managed; then
                printf 'it is a small system volume that managed mode is told to keep clear\n'
            else
                printf 'it is a system volume, and portable mode expects a directory you own for scratch\n'
            fi
            return 0
        fi
    done
    # NFS is a property of the FILESYSTEM, not of a list of directories, so it
    # is read off the mount the path lands on and named by that mount. Naming
    # particular volumes here would make the sentence a fact about one host's
    # storage layout, and would go stale the moment that layout changed.
    probe=$p
    while [ ! -d "$probe" ] && [ "$probe" != / ]; do probe=$(dirname -- "$probe"); done
    if [ -d "$probe" ]; then
        case "$(_quality_fs_type "$probe")" in
            nfs*)
                printf 'it is on an NFS filesystem (%s), and everything this harness writes feeds a Zig cache that needs renameat2()\n' \
                    "$probe"
                return 0
                ;;
        esac
    fi
    if quality_scratch_managed; then
        # This function is called to EXPLAIN a refusal, so the refusal happened
        # even though the path is on an approved volume: a volume that is not
        # really mounted, a volume below the free-space floor, or a directory
        # this user does not own. Saying "outside the approved volumes" about
        # <approved root>/<someone-else> sends the reader after the wrong thing, so
        # the two cases are separated and the second one names what it was.
        for root in $QUALITY_MANAGED_ROOTS; do
            if [ "$p" = "$root" ] || [ "${p#"$root"/}" != "$p" ]; then
                printf 'it is on the approved volume %s, which only takes scratch when it is really mounted and has %s GiB free\n' \
                    "$root" "$QUALITY_MANAGED_MIN_FREE_GIB"
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
            QUALITY_SCRATCH_WHY="$root is not a real mountpoint"
            return 1
        fi
        floor=$((QUALITY_MANAGED_MIN_FREE_GIB * 1024 * 1024))
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
# OWNERSHIP IS A MANAGED-MODE PROPERTY, AND THE DIFFERENCE IS THE POINT. In
# managed mode the contract is a per-user directory under an approved volume,
# so `[ -O ]` is a real check: it refuses another user's leftovers. In portable
# mode the intended directory may be a system temp volume, which is owned by
# root with the sticky bit set and is exactly where a CI runner wants to build.
# Test ownership there and the only correct answer is "refused", so portable
# mode requires writability -- which is the property that actually matters, and
# which honours ACLs and group permissions instead of reimplementing them.
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

# Source the machine-wide policy when one is named, then enforce the contract
# either way. On a managed host the policy's absence is not an error: the rules
# below are the policy's rules, so a cold install with an isolated HOME is
# enforced identically. A policy that IS present is still sourced first and its
# exports still win.
#
# NO POLICY IS LOOKED FOR, EVER. QUALITY_HOST_SCRATCH_POLICY names one, and an
# unset variable means there is none -- not "look under a developer's home
# next". The old default word built a path out of $HOME, which made a
# developer-home layout part of the contract: a container, a cron job, a
# hardened runner, or a home directory with a different policy filename in it
# silently got a different rule set, and every copy of this file had to
# agree with the host about the name of one file. A host that wants a
# machine-wide policy now says so in the environment, and a policy that is
# named but cannot be read is an error in BOTH modes: it is an operator asking
# for rules this run cannot apply, and the only honest answer to that is to
# stop rather than to build under different ones.
quality_scratch_load_policy() {
    local policy=${QUALITY_HOST_SCRATCH_POLICY:-}
    if [ -n "$policy" ] && [ -r "$policy" ]; then
        # shellcheck source=/dev/null
        . "$policy" || {
            printf 'scratch-contract: machine scratch policy %s failed\n' "$policy" >&2
            return 1
        }
        QUALITY_SCRATCH_POLICY_USED=$policy
    else
        QUALITY_SCRATCH_POLICY_USED=
        if [ -n "$policy" ]; then
            printf 'scratch-contract: QUALITY_HOST_SCRATCH_POLICY=%s is not readable\n' \
                "$policy" >&2
            return 1
        fi
    fi
    QUALITY_SCRATCH_MODE=$(quality_scratch_mode)
    return 0
}
