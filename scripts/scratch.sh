#!/usr/bin/env bash
# Project scratch space, layered on the host's sanctioned storage policy.
#
# THE HOST POLICY IS NOT OURS TO REINVENT
#
# Rechnerbetriebsgruppe (2026-10-01) asked that processes stop filling local
# /tmp and /var/tmp: on a buildhost host both are small local ext4 volumes, /tmp is
# 10 G. `~/.local/lib/host-scratch.sh` is the machine-wide answer to that - it
# runs only on buildhost*, requires the candidate to be a real mountpoint with a
# writable path and at least 100 GiB free, refuses symlinked or foreign-owned
# directories, and exports HOST_SCRATCH_ROOT, buildhost_CACHE_ROOT, TMPDIR,
# XDG_CACHE_HOME and ZIG_GLOBAL_CACHE_DIR. That policy is the thing to use, so
# this file sources it rather than keeping a second list of volumes that would
# drift from it the first time an administrator changes it.
#
# WHAT THIS ADDS, AND WHY IT IS NOT REDUNDANT
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
# they are not - but because they do not work for this one thing. Everything
# else is the host policy's decision, and it is a better one than a hardcoded
# list would be.

# shellcheck shell=bash
scratch_root() {
    # 1. An explicit override always wins, including a deliberate one outside
    #    every list below. Validated rather than trusted, because a typo here
    #    silently recreates the original problem under a different name.
    if [ -n "${ZIG_INTERVAL_SCRATCH:-}" ]; then
        if [ ! -d "${ZIG_INTERVAL_SCRATCH}" ]; then
            echo "scratch.sh: ZIG_INTERVAL_SCRATCH=${ZIG_INTERVAL_SCRATCH} does not exist" >&2
            return 1
        fi
        printf '%s\n' "${ZIG_INTERVAL_SCRATCH%/}"
        return 0
    fi

    # 2. Ask the host policy, and prefer the LOCAL root it chose over any other
    #    local root. A root under /vol is NFS and is not usable for a build
    #    cache; a root under /home is local ext4 on every host seen so far.
    local host_policy="$HOME/.local/lib/host-scratch.sh"
    if [ -r "$host_policy" ]; then
        # shellcheck disable=SC1090
        . "$host_policy"
        # One variable, and its empty case named. The loop that used to be
        # here read two: the second, ZIG_INTERVAL_SCRATCH_ROOT, is exported by
        # nothing - not by this project, not by the host policy - so it always
        # expanded to the empty string, and the empty string matches NO
        # pattern in a `case`. A policy that therefore names no root fell
        # straight through to the `printf`, printed a blank line, and
        # returned 0: a successful empty root, which scratch_init then
        # turned into a directory under "/". An absent root is absent here,
        # and step 3 gets to decide instead.
        local root="${HOST_SCRATCH_ROOT:-}"
        case "$root" in
            "") ;;
            /home/*) [ -d "$root" ] && [ -w "$root" ] || root= ;;
            *) root= ;;   # NFS or unknown: not a build cache
        esac
        if [ -n "$root" ]; then
            printf '%s\n' "${root%/}"
            return 0
        fi
    fi

    # 3. Off a buildhost host, or with no shared policy installed: the local
    #    volumes, checked directly. Kept short on purpose - it is a fallback,
    #    not a second source of truth.
    local user="${USER:-$(id -un 2>/dev/null || echo unknown)}" d
    for d in "/home/tmp2/$user" "/home/tmp/$user"; do
        if [ -d "$d" ] && [ -w "$d" ]; then
            printf '%s\n' "$d"
            return 0
        fi
    done

    # 4. Say what was checked and what to do about it, instead of using /tmp.
    cat >&2 <<'EOF'
scratch.sh: no usable local scratch volume found.

Checked: $ZIG_INTERVAL_SCRATCH, then the root chosen by
~/.local/lib/host-scratch.sh, then /home/tmp2/$USER and /home/tmp/$USER.

/vol/tmp and /vol/tmp2 are deliberately not offered. They are sanctioned on every
buildhost, but both are NFS, and this project's builds fail there with renameat2
EINVAL - see docs/performance-handover.md. They are fine for bulk data and wrong
for a Zig build cache.

If this host genuinely has no large local volume, set the location yourself:

    export ZIG_INTERVAL_SCRATCH=/path/on/local/disk

Do not fall back to /tmp: that is the volume this file exists to keep clear.
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
