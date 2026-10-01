#!/usr/bin/env bash
# install-quality-tools.sh -- build the pinned quality analyzers from source and
# install the reviewed gate harness beside them, into a prefix you name.
#
# WHY THIS EXISTS. The gate this repository runs (zig-gate, cross-test and the
# four analyzers it drives) lived in one developer's home directory, tracked by
# nothing. Cold CI had no reproducible source for that tool layout.
# tools/quality/ now holds reviewed harness sources and a manifest that pins every
# analyzer to a full upstream commit, the source patches that reproduce the
# effective local tool versions, and a sha256 for every file. See
# tools/quality/PROVENANCE.md for the reasoning and for what is NOT claimed.
#
# WHAT IT GUARANTEES, and what it does not:
#   * Every analyzer is built from an immutable 40-hex upstream commit, verified
#     after a shallow fetch with `git rev-parse FETCH_HEAD`, plus checked-in
#     patches each verified against a sha256 from the manifest before it is
#     applied. No mutable ref, no developer home, no unpinned download.
#   * Every analyzer is built by a NAMED recipe this installer implements --
#     dispatched from a fixed table, never eval'd and never run as a command out
#     of the manifest. zbc is built with `zig build cli`, its own named
#     install-only step; the other three with `zig build`. That separation
#     exists because zbc's build.zig leaves upstream's dogfood on the DEFAULT
#     step: `zbc src/` over its own source, with a CLI that returns 1 on ANY
#     finding. The dated pre-0005 run reported 75 self-findings; see PROVENANCE.md.
#     The upstream dogfood step stays
#     exactly as it is -- no rule, severity or finding is suppressed, lowered or
#     excluded to get a binary installed -- and the argv that ran, step and
#     optimize mode together, is recorded per install in the manifest.
#   * No binary and no build cache is committed; both are produced here.
#   * Nothing is written to $HOME and nothing is written to /tmp unless you name
#     those paths explicitly. There is no default for either --prefix or
#     --work-root, and both are required.
#   * It does NOT claim the built analyzers are byte-identical to a developer's.
#     They are source-equivalent to pin + patches. The optimizer is a flag and
#     is recorded in the installation manifest.
#   * Every payload file is hashed into $prefix/install-manifest.tsv together
#     with the licence it travels under: the four upstream analyser notices
#     beside their binaries, and harness.LICENSE -- this repository's own MIT --
#     beside the harness and helpers, which are first-party and are refused
#     without it. A prefix can therefore be re-verified byte for byte without
#     re-running the installer.
#
# Exit codes
#   0  success
#   1  a build or install step failed
#   2  usage error, missing prerequisite, manifest error, or checksum mismatch
#   130/143/129  propagated from a signal
#
# Deliberately not supported: --cache-dir, --scratch, --tool-cache, --src-dir,
# --offline. An offline mode would be a second, unpinned distribution path, and
# a separate cache flag would be a second place for the scratch policy to live.

set -uo pipefail
export LC_ALL=C

SELF=$(realpath -- "${BASH_SOURCE[0]}") || exit 2
SCRIPT_DIR=${SELF%/*}
REPO_ROOT=$(realpath -m -- "$SCRIPT_DIR/..") || exit 2
QUALITY_ROOT="$REPO_ROOT/tools/quality"

PROG=${0##*/}

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }
fatal() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
note() { printf '%s: %s\n' "$PROG" "$*"; }

usage() {
    cat <<'USAGE'
usage: install-quality-tools.sh --prefix ABS --work-root ABS --zig ABS
                                 [--only LIST] [--manifest PATH]
                                 [--optimize MODE] [--verify-only] [--list]
                                 [--force] [-h|--help]

Builds the pinned quality analyzers from upstream source plus the reviewed
patches in tools/quality/, and installs the reviewed gate harness next to them.

required
  --prefix ABS      install prefix. Absolute, created if absent. Nothing is ever
                    installed outside it.
  --work-root ABS   fetch, patch, build and cache root. Absolute, created if
                    absent. Safe to cache and reuse: a checkout is reused only
                    when all four of its recorded facts still hold. Three are
                    BOUND to this run's manifest row first -- the pinned
                    revision, the ordered patch hashes, the src source digest --
                    and the fourth is the BUILD INPUTS (build.zig, build.zig.zon,
                    @embedFile targets, top-level build files) re-hashed from
                    disk. A stamp that only agrees with its own checkout proves
                    nothing, so the binding comes before the disk check.
                    Anything short of that is re-fetched and re-patched, so a
                    stamp written by
                    an older installer costs one fetch rather than a build from
                    a tree nobody hashed.
  --zig ABS         path to a real Zig. Must report exactly 0.16.0.

optional
  --only LIST       comma-separated subset of:
                    zbc, ziglint, zlint, zwanzig, cross-test, zig-gate,
                    harness (= cross-test + zig-gate), analyzers (the four),
                    all (everything; the default)
                    `zig-gate` implies `cross-test`, because gate section 9
                    executes it, and the installer says so when it adds it.
                    An unknown name exits 2 and lists the valid set.
  --manifest PATH   alternative source manifest. Default tools/quality/manifest.tsv
  --optimize MODE   Zig optimize mode for the analyzer builds. Default ReleaseFast,
                    which is a build choice, not a property of the sources; pass
                    Debug to fall back to the upstream default. Recorded per tool
                    in the installation manifest.
  --verify-only     verify tools/quality/SHA256SUMS and the source manifest, then
                    stop. Creates NOTHING: no prefix, no work root, no temporary
                    file, so neither path has to exist and neither has to be a
                    legal scratch location for this run. It checks the CHECKED-IN
                    sources and stops there; it reads no installed file, so it is
                    not a statement about the contents of a prefix.
  --list            print the resolved plan and exit 0. Fetches nothing.
  --force           overwrite a prefix that already exists. Without it, a
                    non-empty existing prefix is refused rather than merged into.
  -h, --help        this text

installed layout
  $prefix/bin/{zig-gate,cross-test,ziglint,zlint,zbc,zwanzig}
  $prefix/lib/cross-test/{test.sh,test-zig.sh,run_policy.zig,zig-targets.sh,
                          scratch-contract.sh}
  $prefix/share/zig-interval-quality/{manifest.tsv,SHA256SUMS,PROVENANCE.md,
                                      licenses/,patches/}
  $prefix/install-manifest.tsv

  $prefix/share/zig-interval-quality/licenses/ carries the four upstream analyser
  licences and harness.LICENSE, which is this repository's own MIT text covering
  the harness sources and helpers. install-manifest.tsv records the licence each
  installed file travels under; a re-hash of a prefix against that manifest is
  what proves an install is intact, and --verify-only does not do it.

build recipes
  Each analyzer row in the source manifest names one recipe, and this installer
  dispatches that NAME from the fixed table below. It is never expanded, never
  eval'd and never run as a shell command; a name outside the table is refused
  with exit 2 rather than quietly built some other way, because the artifact
  that reached the prefix would then be one nothing in the distribution
  describes.

    default  the tool's own default step: `zig build` and nothing else.
    cli      the tool's named install-only step: `zig build cli`. It installs
             the executable and does not run the project's dogfood self-check,
             which is upstream behaviour on the DEFAULT step and is left there.
             zbc uses this: its default step runs `zbc src/` over its own src/,
             and its CLI returns 1 on ANY finding, so that self-check cannot
             pass for the patched pinned tree at any severity setting,
             upstream's included. The separation is in what the build RUNS,
             never in what it reports -- no rule, no severity and no finding is
             suppressed, downgraded or excluded to install a binary.

  The argv that actually ran is recorded per install in install-manifest.tsv's
  build_recipe column, so a prefix states which step produced each analyzer
  without anybody reading this script. `zig build --help` inside a checkout
  lists the steps that checkout offers.

prerequisites
  bash 4.4+, git, realpath, sha256sum, install, mktemp, df, stat, find, awk,
  sed, grep, tr, cut, sort, wc, cp, rm, mkdir, ln, and a C toolchain for the
  linker (cc or gcc). On a managed cluster host, mountpoint. Network access to
  github.com: one shallow fetch per analyzer, plus zlint's own build.zig.zon
  dependencies.
USAGE
}

# --------------------------------------------------------------- arguments --

PREFIX=
WORK_ROOT=
ZIG=
ONLY=
MANIFEST=
OPTIMIZE=ReleaseFast
VERIFY_ONLY=0
LIST_ONLY=0
FORCE=0

while (($#)); do
    case $1 in
        --prefix | --work-root | --zig | --only | --manifest | --optimize)
            (($# >= 2)) && [[ -n $2 ]] || die "$1 needs a value"
            case $1 in
                --prefix) PREFIX=$2 ;;
                --work-root) WORK_ROOT=$2 ;;
                --zig) ZIG=$2 ;;
                --only) ONLY=$2 ;;
                --manifest) MANIFEST=$2 ;;
                --optimize) OPTIMIZE=$2 ;;
            esac
            shift 2
            ;;
        --verify-only) VERIFY_ONLY=1; shift ;;
        --list) LIST_ONLY=1; shift ;;
        --force) FORCE=1; shift ;;
        -h | --help)
            usage
            exit 0
            ;;
        --) shift; break ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done
(($# == 0)) || die "unexpected trailing argument: $1 (see --help)"

[[ -n $PREFIX ]] || die "--prefix is required; there is deliberately no default (see --help)"
[[ -n $WORK_ROOT ]] || die "--work-root is required; there is deliberately no default (see --help)"
[[ -n $ZIG ]] || die "--zig is required; there is deliberately no default (see --help)"
for pair in "--prefix:$PREFIX" "--work-root:$WORK_ROOT" "--zig:$ZIG"; do
    case ${pair#*:} in
        /*) ;;
        *) die "${pair%%:*} must be an absolute path, got ${pair#*:}" ;;
    esac
done
case $OPTIMIZE in
    Debug | ReleaseSafe | ReleaseFast | ReleaseSmall) ;;
    *) die "--optimize must be Debug, ReleaseSafe, ReleaseFast or ReleaseSmall, got $OPTIMIZE" ;;
esac
[[ -n ${MANIFEST:-} ]] || MANIFEST="$QUALITY_ROOT/manifest.tsv"
[[ -r $MANIFEST ]] || die "source manifest not readable: $MANIFEST"
MANIFEST=$(realpath -m -- "$MANIFEST") || die "cannot resolve the source manifest"
QUALITY_ROOT=$(realpath -m -- "$(dirname -- "$MANIFEST")") || die "cannot resolve tools/quality"

# ------------------------------------------------------------- selection --

ANALYZER_IDS=(zbc ziglint zlint zwanzig)
HARNESS_IDS=(zig-gate cross-test)
HELPER_FILES=(test.sh test-zig.sh run_policy.zig zig-targets.sh scratch-contract.sh)
HARNESS_BIN=(zig-gate cross-test)
VALID_IDS=(zbc ziglint zlint zwanzig cross-test zig-gate harness analyzers all)

# The licence every bin/ and lib/cross-test/ file travels under, recorded on
# each install-manifest row that installs one. The harness is first-party code
# in this repository, so its notice is this repository's own MIT, installed
# beside it as licenses/harness.LICENSE; the four analyzers keep their upstream
# notices and are labelled separately. One string, so a row cannot disagree with
# the file the notice actually lives in.
HARNESS_LICENSE='MIT (this repository; see share/zig-interval-quality/licenses/harness.LICENSE)'

WANT_ANALYZERS=()
WANT_HARNESS=()

want_id() {
    local id=$1 e
    for e in "${WANT_ANALYZERS[@]}" "${WANT_HARNESS[@]}"; do
        [[ $e == "$id" ]] && return 0
    done
    return 1
}

if [[ -n $ONLY ]]; then
    IFS=',' read -r -a _only_list <<<"$ONLY"
    for id in "${_only_list[@]}"; do
        id=${id#"${id%%[![:space:]]*}"}
        id=${id%"${id##*[![:space:]]}"}
        [[ -n $id ]] || continue
        case $id in
            all) WANT_ANALYZERS=("${ANALYZER_IDS[@]}"); WANT_HARNESS=("${HARNESS_BIN[@]}") ;;
            analyzers) WANT_ANALYZERS=("${ANALYZER_IDS[@]}") ;;
            harness) WANT_HARNESS=("${HARNESS_BIN[@]}") ;;
            zig-gate | cross-test) WANT_HARNESS+=("$id") ;;
            zbc | ziglint | zlint | zwanzig) WANT_ANALYZERS+=("$id") ;;
            *)
                die "unknown --only value: $id
       valid values: ${VALID_IDS[*]}"
                ;;
        esac
    done
else
    WANT_ANALYZERS=("${ANALYZER_IDS[@]}")
    WANT_HARNESS=("${HARNESS_BIN[@]}")
fi

# De-duplicate while preserving order, so a --list reads as a plan and not as an
# argument echoed back. A string membership test rather than an associative
# array: the values are a fixed set of identifiers, an unknown one has already
# been rejected above, and a fixed set is not worth a nameref.
dedupe() {
    local -a kept=()
    local v k found
    for v in "$@"; do
        [[ -n $v ]] || continue
        found=0
        for k in ${kept[@]+"${kept[@]}"}; do
            if [[ $k == "$v" ]]; then
                found=1
                break
            fi
        done
        ((found)) && continue
        kept+=("$v")
    done
    ((${#kept[@]})) && printf '%s\n' "${kept[@]}"
    return 0
}
mapfile -t WANT_ANALYZERS < <(dedupe ${WANT_ANALYZERS[@]+"${WANT_ANALYZERS[@]}"})
mapfile -t WANT_HARNESS < <(dedupe ${WANT_HARNESS[@]+"${WANT_HARNESS[@]}"})

((${#WANT_ANALYZERS[@]} + ${#WANT_HARNESS[@]} > 0)) ||
    die "--only selected nothing; valid values: ${VALID_IDS[*]}"

# zig-gate section 9 executes cross-test. Installing the gate without it would
# produce a prefix whose own gate cannot complete, so say so rather than let the
# first run discover it.
if [[ " ${WANT_HARNESS[*]:-} " == *" zig-gate "* &&
    " ${WANT_HARNESS[*]:-} " != *" cross-test "* ]]; then
    WANT_HARNESS+=(cross-test)
    note "adding cross-test: zig-gate section 9 executes it"
fi

# -------------------------------------------------------- prerequisites --

# The scratch contract, not a second copy of the rule. It is the same helper the
# installed gate and cross-test source, so the installer cannot end up enforcing
# a policy the harness would disagree with.
CONTRACT="$QUALITY_ROOT/harness/lib/cross-test/scratch-contract.sh"
[[ -r $CONTRACT ]] || die "missing scratch contract $CONTRACT"
# shellcheck source=../tools/quality/harness/lib/cross-test/scratch-contract.sh
. "$CONTRACT" || die "cannot load the scratch contract $CONTRACT"
quality_scratch_load_policy || die "cannot establish a scratch policy on this host"

for tool in git realpath sha256sum install mktemp df stat find awk sed grep tr \
    cut sort wc cp rm mkdir ln; do
    command -v "$tool" >/dev/null 2>&1 || die "required command not found: $tool"
done
if ! command -v mountpoint >/dev/null 2>&1 && quality_scratch_managed; then
    die "mountpoint is required on a managed cluster host and was not found"
fi
((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))) ||
    die "bash 4.4 or newer is required, found ${BASH_VERSION}"
[[ -x $ZIG ]] || die "--zig is not an executable file: $ZIG"
ZIG_VERSION=$("$ZIG" version 2>/dev/null) || die "cannot run --zig: $ZIG"
[[ $ZIG_VERSION == 0.16.0 ]] ||
    die "--zig reports $ZIG_VERSION; this harness is pinned to 0.16.0 (got $ZIG)"

# --prefix and --work-root are held to the SAME contract the harness uses. On a
# managed cluster host that means the approved physical volumes, and it is
# checked here rather than in a second implementation. Elsewhere it means a
# local directory this user can write, which is what lets a CI runner use /tmp.
#
# --verify-only is exempt, and the exemption is the point rather than a
# loophole: that mode writes nothing anywhere, so where the prefix WOULD have
# landed is not a fact about the run. Holding a read-only distribution check to
# the volume rules would refuse the verification on exactly the host where
# somebody most wants to find out whether the tree they hold is intact.
if ((VERIFY_ONLY == 0)); then
    for pair in "--prefix:$PREFIX" "--work-root:$WORK_ROOT"; do
        if ! quality_scratch_path_ok "${pair#*:}"; then
            die "${pair%%:*} ${pair#*:}
       refused: $QUALITY_SCRATCH_WHY
       mode=$(quality_scratch_mode); the rule is in tools/quality/harness/lib/cross-test/scratch-contract.sh"
        fi
    done
    if [[ $PREFIX == "$WORK_ROOT" || $WORK_ROOT == "$PREFIX"/* ]]; then
        die "--work-root must not be --prefix or inside it; the installer refuses to
       treat an install tree as a build tree"
    fi
fi

# ------------------------------------------------------- checked-in hashes --

# Two facts, both re-derived from disk: every file SHA256SUMS lists still hashes
# to what it claims, and every file under tools/quality/ is one SHA256SUMS
# lists. The second is the half that catches a committed binary.
#
# It runs entirely in pipes. It used to write two sorted listings into
# $WORK_ROOT and diff them, which made --verify-only a writer: a read-only
# distribution check left two files behind in the work root it had just been
# told it would not touch. `comm` and a string comparison both want their input
# as streams or values, and a process substitution supplies either, so there is
# nothing left that needs a path.
verify_checked_in() {
    local sums="$QUALITY_ROOT/SHA256SUMS" listed on_disk extra
    [[ -r $sums ]] || die "missing $sums; regenerate it from tools/quality/"
    # Every listed file, verified. --strict would also reject unlisted files,
    # which is wanted: a stray binary or cache in this directory is a defect,
    # not a harmless extra.
    (cd "$QUALITY_ROOT" && LC_ALL=C sha256sum --check --strict --quiet SHA256SUMS) ||
        die "tools/quality/SHA256SUMS does not match the files in tools/quality"
    listed=$(cd "$QUALITY_ROOT" && awk '{ sub(/^[^ ]+  /, ""); print }' SHA256SUMS |
        LC_ALL=C sort) || die "cannot read $sums"
    on_disk=$(cd "$QUALITY_ROOT" && find . -type f ! -name SHA256SUMS -printf '%P\n' |
        LC_ALL=C sort) || die "cannot list the files under $QUALITY_ROOT"
    if [[ $listed != "$on_disk" ]]; then
        printf '%s: %s\n' "$PROG" "tools/quality holds files SHA256SUMS does not list:" >&2
        extra=$(comm -13 <(printf '%s\n' "$listed") <(printf '%s\n' "$on_disk"))
        [[ -z $extra ]] || printf '%s\n' "$extra" | sed 's/^/            /' >&2
        die "remove them or list them; a committed binary or cache is not reviewable"
    fi
}

# ---------------------------------------------------------------- manifest --
#
# The manifest is tab separated, and tab is an IFS whitespace character, so the
# obvious `IFS=$'\t' read -r -a cols` collapses a run of tabs into one and
# strips the leading and trailing ones. Both parsers here used it, so they
# agreed with each other and disagreed with the file: an interior EMPTY column
# -- a blank build_recipe, say -- shifted every column after it left by one, and
# COL_RECIPE then read the install artifact, which turned the post-build
# `produced=` lookup into a filename that cannot exist. A confusing failure for
# what is a plainly malformed input, so the format is stated instead of
# tolerated: every row carries every column, and an absent value is written `-`.
MANIFEST_COLUMNS=14

# Exact split on TAB into the named array, empty fields preserved. Not an IFS
# read, and not `cut -f` either: this has to keep a TRAILING empty field, which
# is exactly the case the whitespace-collapsing split lost.
split_tsv() {
    local -n _out=$1
    local rest=$2 part
    _out=()
    [[ $rest == *$'\t'* ]] || { _out=("$rest"); return 0; }
    while [[ $rest == *$'\t'* ]]; do
        part=${rest%%$'\t'*}
        rest=${rest#*$'\t'}
        _out+=("$part")
    done
    _out+=("$rest")
}


# ROW_PATCHES/ROW_HASHES are keyed by analyzer id, which is why the -A matters:
# as an indexed array the subscript would be evaluated as arithmetic and the
# first id in the manifest would be reported as an unset variable.
declare -A ROW_PATCHES=() ROW_HASHES=()
declare -a MANIFEST_ROWS=()
read_manifest() {
    local -n _rows=$1
    local line id repo rev patches phashes ipath c n
    local -a p=() h=() cols=()
    local -A seen=()
    _rows=()
    n=0
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -n $line ]] || continue
        [[ ${line:0:1} != "#" ]] || continue
        n=$((n + 1))
        split_tsv cols "$line"
        ((${#cols[@]} == MANIFEST_COLUMNS)) ||
            die "manifest line $n has ${#cols[@]} of $MANIFEST_COLUMNS tab-separated columns;
       every row carries all of them, with '-' where a value does not apply"
        for c in "${cols[@]}"; do
            [[ -n $c ]] ||
                die "manifest line $n has an empty column; write '-' for an absent
       value, because an empty one silently shifts every column after it"
        done
        id=${cols[0]}
        repo=${cols[2]}
        rev=${cols[3]}
        patches=${cols[7]}
        phashes=${cols[8]}
        ipath=${cols[10]}
        [[ $rev =~ ^[0-9a-f]{40}$ ]] ||
            die "manifest row $id: revision must be a full 40-hex commit id, got '$rev'"
        [[ $repo =~ ^https?:// ]] ||
            die "manifest row $id: repo must be an https URL, got '$repo'"
        [[ -z ${seen[$id]:-} ]] || die "manifest row $id appears more than once"
        seen[$id]=1
        p=() h=()
        if [[ $patches != "-" ]]; then
            IFS=',' read -r -a p <<<"$patches"
            IFS=',' read -r -a h <<<"$phashes"
            ((${#p[@]} == ${#h[@]})) ||
                die "manifest row $id: ${#p[@]} patches but ${#h[@]} hashes"
        fi
        ROW_PATCHES[$id]=$(printf '%s\n' ${p[@]+"${p[@]}"})
        ROW_HASHES[$id]=$(printf '%s\n' ${h[@]+"${h[@]}"})
        # The row verbatim, not a re-join of the fields: re-joining is one more
        # place for a column to be normalised differently from the file, and
        # field() below reads the row the same way read_manifest just did.
        _rows+=("$line")
    done <"$MANIFEST"
    ((${#_rows[@]} > 0)) || die "no analyzer rows in $MANIFEST"
}

COL_ID=1 COL_KIND=2 COL_REPO=3 COL_REV=4 COL_RDATE=5 COL_TVER=6 COL_COMP=7
COL_PATCHES=8 COL_PHASH=9 COL_LIC=10 COL_IPATH=11 COL_RECIPE=12
COL_ARTIFACT=13 COL_SDIG=14

# --------------------------------------------------------------- recipes --
#
# The manifest's `build_recipe` column names one of the recipes below, and this
# installer dispatches that NAME from this fixed table. It is never expanded,
# never eval'd and never run as a shell command: a manifest is a checked-in
# text file, and a build that executes a command out of one has turned a pin
# into an execution surface. A name outside the table is a refusal, not a
# fallback to `zig build` -- the artifact that reached the prefix would then be
# one nothing in the distribution describes.
#
#   default  the tool's own default step: `zig build` and nothing else.
#   cli      the tool's named INSTALL-ONLY step: `zig build cli`. It installs
#            the executable and does not run the project's dogfood self-check,
#            which is upstream behaviour on the DEFAULT step and is left there.
#            zbc uses this: its build.zig puts `zbc src/` over its own src/ on
#            the default step, and the CLI returns 1 on ANY finding, so `zig
#            build` in that checkout exits 1 on the 75 findings that tree
#            reports about itself. That is a property of the pinned, patched
#            source at any severity setting, upstream's included, and not a
#            defect a different step fixes. `cli` installs the same executable
#            the default step would have installed and runs none of the
#            self-check.
#
# The separation is in what the build RUNS, never in what it REPORTS. The
# dogfood step is upstream's and stays unmodified; no rule, severity or finding
# is suppressed, downgraded, excluded or reinterpreted to get an artifact built.
#
# No mode appears in a recipe name, which is why the column cannot drift from
# the run: the mode that actually built a binary, with the step that was
# selected, is recorded per install in install-manifest.tsv's build_recipe.
SUPPORTED_RECIPES='default cli'

# The step name `zig build` is given for the recipe named in $1; nothing at all
# for a tool's default step, whose step is unnamed. Returns 1 for a name this
# installer does not implement, which is what both the validation pass and the
# build loop refuse on.
recipe_step() {
    case $1 in
        default) ;;
        cli) printf '%s\n' "$1" ;;
        *) return 1 ;;
    esac
    return 0
}

# Refuse a recipe this installer does not implement. $1 = the tool's id, for the
# message; $2 = the name the manifest carries. Called as a statement and never
# inside a command substitution, because `die` exits and an exit inside $( )
# would exit a subshell and leave this script running on past the error.
require_recipe() {
    recipe_step "$2" >/dev/null ||
        die "$1: build_recipe '$2' is not a recipe this installer implements
       supported recipes: $SUPPORTED_RECIPES
       the manifest names a build this installer does not run; nothing was installed"
}

row_field() { field "$1" "$2"; }

field() {
    # $1 = one row (tab separated), $2 = 1-based column number. Prints the
    # column, or fails when the row is shorter than that. Exact, for the reason
    # split_tsv documents: a whitespace-collapsing split converts one malformed
    # row into a row of plausible-looking wrong answers, and every reader here
    # would then act on them.
    local row=$1 want=$2 i
    local -a cols=()
    case $want in '' | *[!0-9]*) return 1 ;; esac
    split_tsv cols "$row"
    for ((i = 0; i < ${#cols[@]}; i++)); do
        if (((i + 1) == want)); then
            printf '%s\n' "${cols[i]}"
            return 0
        fi
    done
    return 1
}

# --------------------------------------------------------------- stamping --

source_digest() {
    # sha256 over the sorted `sha256  path` listing of src/**/*.zig, relative to
    # $1. This is the manifest's `source_digest` recipe, reproduced exactly, so
    # a reuse decision compares like with like.
    (cd "$1" && find src -name '*.zig' -type f 2>/dev/null | LC_ALL=C sort |
        xargs -r sha256sum | sha256sum | cut -d' ' -f1)
}

# sha256 over the files `zig build` itself READS from a checkout, on top of the
# src/**/*.zig listing above.
#
# The revision pin does not cover these, and neither did the source digest.
# revision + ordered patch hashes + src/**/*.zig say the ANALYSED SOURCE tree is
# the reviewed one -- and then the build is run by a script nothing checked. A
# cache restore, a stray edit or a half-applied patch that touches build.zig or
# build.zig.zon reuses cleanly and executes unpinned code with the pinned
# sources as its input, which is the whole thing the pin exists to prevent.
#
# The set is: build.zig and build.zig.zon when present, every path build.zig
# pulls in with @embedFile (an embedded file is a build input and its contents
# reach the build without ever touching src/), and every regular file at the
# top level, which is what covers a tool whose build is named Cargo.toml or
# package.json instead. Cost is a handful of sha256sums.
build_inputs_digest() {
    local dir=$1 list=
    list=$(cd "$dir" && {
            printf '%s\n' build.zig build.zig.zon
            [ -f build.zig ] &&
                sed -n 's/.*@embedFile\(Alloc\)\{0,1\}("\([^"]*\)").*/\2/p' build.zig
            find . -maxdepth 1 -type f -printf '%P\n'
        } | LC_ALL=C sort -u |
        while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done) || return 1
    # An empty set has no digest worth stamping: a constant that every tree
    # would match is not a check, so refuse instead of writing one.
    [[ -n $list ]] || return 1
    (cd "$dir" && printf '%s\n' "$list" | xargs -r sha256sum | sha256sum | cut -d' ' -f1)
}

# Is a cached checkout still the tree this manifest describes?
#
# Four independent things have to hold. The first three are BINDINGS: the
# stamp's revision, its ordered patch hashes and its source digest must be the
# ones THIS run's manifest row lists, which is what says which tree the stamp is
# allowed to be about. A stamp that only agrees with itself proves nothing --
# an unpatched tool whose pin has since moved keeps a stamp that matches its own
# checkout perfectly -- so the binding comes first and the stamp's own values
# are never read as the expectation.
#
# The fourth is the disk check, and all three of its values are re-derived
# rather than read back: the checked-out commit is the bound revision, the
# source digest over src/**/*.zig is the bound digest, and the build inputs on
# disk still hash to what the stamp recorded for them. Anything short of all
# four means the tree is not the pinned tree, and the answer is to re-fetch
# rather than to build from it -- a cache restore that silently hands back a
# half-patched checkout, or a checkout for a pin this manifest no longer names,
# is exactly the failure this refuses.
#
# A stamp written before the fourth field existed has none, and that is a
# non-match rather than a pass: the answer is a fresh fetch, which costs one
# network round trip and is the only outcome that cannot be wrong. A stamp
# written before the binding existed fails the same way, for the same reason.
#
stamp_matches() {
    local dir=$1 stamp=$2 want_rev want_hashes want_digest want_inputs
    local have_rev now now_inputs
    [[ -d $dir/.git && -r $stamp ]] || return 1
    want_rev=$(sed -n 's/^revision=//p' "$stamp")
    want_hashes=$(sed -n 's/^patch_sha256=//p' "$stamp")
    want_digest=$(sed -n 's/^source_digest=//p' "$stamp")
    want_inputs=$(sed -n 's/^build_inputs_digest=//p' "$stamp")
    [[ -n $want_rev && -n $want_digest && -n $want_inputs ]] || return 1
    # THE STAMP IS BOUND TO THE CURRENT MANIFEST ROW BEFORE ANYTHING IS READ
    # FROM DISK, and that binding is the whole point. Every field below is a
    # CLAIM the stamp makes about itself, so comparing a stamp only with the
    # disk proves the stamp is internally consistent and nothing more: an
    # unpatched tool whose pin moved to a new revision, or whose recorded
    # source digest was superseded, keeps a stamp that still agrees with its own
    # checkout perfectly and would have been reused. Only ROW_REV_CLAIM and
    # ROW_DIGEST_CLAIM, which come from the row this run is installing, say
    # WHICH tree the stamp must be about. `-` in the manifest's source_digest
    # column is the one "no claim to bind" case; every row in this distribution
    # carries a digest, so that branch is never taken here.
    [[ $want_rev == "$ROW_REV_CLAIM" ]] || return 1
    [[ $ROW_DIGEST_CLAIM == "-" || $want_digest == "$ROW_DIGEST_CLAIM" ]] || return 1
    [[ $want_hashes == "$ROW_HASHES_CLAIM" ]] || return 1
    have_rev=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || return 1
    [[ $have_rev == "$want_rev" ]] || return 1
    now=$(source_digest "$dir")
    [[ -n $now && $now == "$want_digest" ]] || return 1
    now_inputs=$(build_inputs_digest "$dir")
    [[ -n $now_inputs && $now_inputs == "$want_inputs" ]] || return 1
    return 0
}

# ------------------------------------------------------------------ plan --

print_plan() {
    local row id
    printf '%s: plan\n' "$PROG"
    printf '  prefix     %s\n' "$PREFIX"
    printf '  work-root  %s\n' "$WORK_ROOT"
    printf '  zig        %s (%s)\n' "$ZIG" "$ZIG_VERSION"
    printf '  optimize   %s\n' "$OPTIMIZE"
    printf '  manifest   %s\n' "$MANIFEST"
    printf '  scratch    mode=%s policy=%s\n' "$(quality_scratch_mode)" \
        "${QUALITY_SCRATCH_POLICY_USED:-builtin}"
    for id in ${WANT_ANALYZERS[@]+"${WANT_ANALYZERS[@]}"}; do
        for row in "${MANIFEST_ROWS[@]}"; do
            [[ $(row_field "$row" $COL_ID) == "$id" ]] || continue
            printf '  analyzer   %-8s %s  %s  v%s\n' "$id" \
                "$(row_field "$row" $COL_REV)" "$(row_field "$row" $COL_RDATE)" \
                "$(row_field "$row" $COL_TVER)"
            printf '             repo %s\n' "$(row_field "$row" $COL_REPO)"
            local p
            p=$(row_field "$row" $COL_PATCHES)
            if [[ $p != "-" ]]; then
                local -a pl=()
                IFS=',' read -r -a pl <<<"$p"
                printf '             patches %d: %s\n' "${#pl[@]}" "${pl[*]}"
            else
                printf '             patches none\n'
            fi
            printf '             installs %s\n' "$(row_field "$row" $COL_IPATH)"
            local rn rs
            rn=$(row_field "$row" $COL_RECIPE)
            # Resolved here rather than assumed: the plan names the recipe from
            # the manifest and says which `zig build` step it selects, so a
            # `--list` cannot print a plan whose recipe the installer would
            # later refuse.
            rs=$(recipe_step "$rn") || rs=
            printf '             recipe  %s%s\n' "$rn" "${rs:+ (zig build $rs)}"
            printf '             digest  %s\n' "$(row_field "$row" $COL_SDIG)"
        done
    done
    if ((${#WANT_HARNESS[@]} > 0)); then
        for id in "${WANT_HARNESS[@]}"; do
            printf '  harness    %s -> bin/%s\n' "$id" "$id"
        done
        printf '  helpers    lib/cross-test/{%s}\n' "${HELPER_FILES[*]}"
    fi
    if ((${#WANT_HARNESS[@]} > 0)); then
        printf '  license    %s/licenses/{zbc,ziglint,zlint,zwanzig}.LICENSE (upstream MIT)\n' \
            "$PREFIX/share/zig-interval-quality"
        printf '             %s/licenses/harness.LICENSE\n' \
            "$PREFIX/share/zig-interval-quality"
        printf '             (this repository'"'"'s own MIT; bin/ and lib/cross-test/ travel under it)\n'
    fi
    printf '  license    install-manifest.tsv records every payload file; it does not hash itself\n'
}

# ------------------------------------------------------------- validation --

[[ -d $QUALITY_ROOT/harness/bin ]] || die "missing $QUALITY_ROOT/harness/bin"
for h in "${HARNESS_BIN[@]}"; do
    [[ -r "$QUALITY_ROOT/harness/bin/$h" ]] || die "missing harness source harness/bin/$h"
done
for h in "${HELPER_FILES[@]}"; do
    [[ -r "$QUALITY_ROOT/harness/lib/cross-test/$h" ]] ||
        die "missing harness source harness/lib/cross-test/$h"
done
if ((${#WANT_HARNESS[@]} > 0)); then
    # The harness is first-party, so its licence is this repository's own MIT
    # text. It is required, not optional: an install that copies harness sources
    # into a prefix and no licence alongside them is exactly the "no licence
    # text, no attribution" state the file exists to prevent.
    [[ -r "$QUALITY_ROOT/licenses/harness.LICENSE" ]] ||
        die "missing $QUALITY_ROOT/licenses/harness.LICENSE; the harness and its
       helpers are redistributed under this repository's MIT and must ship with it"
fi

read_manifest MANIFEST_ROWS

for id in ${WANT_ANALYZERS[@]+"${WANT_ANALYZERS[@]}"}; do
    row=
    for r in "${MANIFEST_ROWS[@]}"; do
        [[ $(row_field "$r" $COL_ID) == "$id" ]] && row=$r
    done
    [[ -n $row ]] || die "--only asked for $id, which has no row in $MANIFEST"
    # The recipe is checked in the same pass, for the same reason this section
    # exists at all: everything here finishes before anything is created, and a
    # build_recipe this installer cannot run is exactly a manifest error.
    require_recipe "$id" "$(row_field "$row" $COL_RECIPE)"
done

if ((LIST_ONLY)); then
    print_plan
    exit 0
fi

# --verify-only ends HERE, before either directory is created and before
# verify_checked_in has any work root to write its scratch listings into. Both
# of those used to sit below it, which made a run documented as "creates no
# prefix" mkdir -p the prefix and the work root and leave two directories
# behind on the volume the caller named for a read-only check. --verify-only is
# now genuinely write-free: it hashes what is checked in, prints the plan, and
# leaves the filesystem exactly as it found it. It says nothing about the
# contents of a prefix, which is what install-manifest.tsv is for.
if ((VERIFY_ONLY)); then
    verify_checked_in
    note "verified tools/quality/SHA256SUMS and $MANIFEST; nothing was written"
    print_plan
    exit 0
fi

# Everything below this line may create directories. Everything above it is a
# read, so a usage or manifest error has provably written nothing.
if ! quality_scratch_make "$WORK_ROOT"; then
    die "cannot use --work-root $WORK_ROOT: $QUALITY_SCRATCH_WHY"
fi
if ! quality_scratch_make "$PREFIX"; then
    die "cannot use --prefix $PREFIX: $QUALITY_SCRATCH_WHY"
fi
verify_checked_in

if [[ -n $(ls -A -- "$PREFIX" 2>/dev/null) ]] && ((FORCE == 0)); then
    die "prefix $PREFIX is not empty; pass --force to overwrite it"
fi
CREATED_PREFIX=0
if [[ -z $(ls -A -- "$PREFIX" 2>/dev/null) ]]; then CREATED_PREFIX=1; fi

# ----------------------------------------------------------------- build --
declare -a INSTALLED_ANALYZERS=()
ROW_HASHES_CLAIM=
ROW_REV_CLAIM=
ROW_DIGEST_CLAIM=

STAGE="$WORK_ROOT/stage/prefix"
rm -rf -- "$STAGE" || die "cannot clear the staging tree $STAGE"
mkdir -p -- "$STAGE/bin" "$STAGE/lib/cross-test" \
    "$STAGE/share/zig-interval-quality/licenses" "$STAGE/share/zig-interval-quality/patches" ||
    die "cannot create the staging tree under $STAGE"

cleanup_on_failure() {
    local rc=$?
    if ((rc != 0)) && ((CREATED_PREFIX == 1)) && [[ -d $PREFIX ]]; then
        rm -rf -- "$PREFIX"
        printf '%s: removed the partially created prefix %s\n' "$PROG" "$PREFIX" >&2
    fi
}
trap cleanup_on_failure EXIT

for id in ${WANT_ANALYZERS[@]+"${WANT_ANALYZERS[@]}"}; do
    row=
    for r in "${MANIFEST_ROWS[@]}"; do
        [[ $(row_field "$r" $COL_ID) == "$id" ]] && row=$r
    done
    repo=$(row_field "$row" $COL_REPO)
    rev=$(row_field "$row" $COL_REV)
    tver=$(row_field "$row" $COL_TVER)
    comp=$(row_field "$row" $COL_COMP)
    rdate=$(row_field "$row" $COL_RDATE)
    lic=$(row_field "$row" $COL_LIC)
    ipath=$(row_field "$row" $COL_IPATH)
    artifact=$(row_field "$row" $COL_ARTIFACT)
    want_digest=$(row_field "$row" $COL_SDIG)
    patches_field=$(row_field "$row" $COL_PATCHES)
    hash_field=$(row_field "$row" $COL_PHASH)
    recipe=$(row_field "$row" $COL_RECIPE)
    # The recipe is re-checked here, not assumed from the validation pass, and
    # it is never downgraded to a plain `zig build`: the manifest would be
    # describing a build nobody ran, and the binary that reached the prefix
    # would be exactly the one nothing in the distribution describes.
    require_recipe "$id" "$recipe"
    step=$(recipe_step "$recipe")

    note "== $id $rev ($(row_field "$row" $COL_TVER), built with $comp, recipe $recipe)"

    # The argv that is run, and the argv that gets RECORDED. The step and the
    # optimize mode are the recipe; --prefix and the two cache directories are
    # where this run happened to put things and stay out of the column, so
    # install-manifest.tsv carries no work-root path that differs per host.
    if [[ -n $step ]]; then
        build_argv="zig build $step -Doptimize=$OPTIMIZE"
    else
        build_argv="zig build -Doptimize=$OPTIMIZE"
    fi

    # Patches are verified before a single byte is applied, so a tampered or
    # truncated patch is a refusal rather than a mystery compile error.
    mapfile -t plist < <(printf '%s\n' "${ROW_PATCHES[$id]:-}" | sed '/^$/d')
    mapfile -t hlist < <(printf '%s\n' "${ROW_HASHES[$id]:-}" | sed '/^$/d')
    ((${#plist[@]} == ${#hlist[@]})) ||
        fatal "$id: manifest lists ${#plist[@]} patches and ${#hlist[@]} hashes"
    for p in ${plist[@]+"${plist[@]}"}; do
        ppath="$QUALITY_ROOT/$p"
        [[ -r $ppath ]] || die "$id: patch $p is missing from $QUALITY_ROOT"
        actual=$(sha256sum -- "$ppath" | cut -d' ' -f1)
        matched=0
        for want in ${hlist[@]+"${hlist[@]}"}; do
            [[ $actual == "$want" ]] && matched=1
        done
        ((matched)) ||
            die "$id: patch $p has sha256 $actual
       expected one of: ${hlist[*]:-}
       the checked-in patch does not match tools/quality/manifest.tsv"
        note "   patch $p sha256 ok"
    done
    # The stamp check compares against the manifest's own hash list, so set the
    # claim the matcher compares a restored cache against.
    ROW_HASHES_CLAIM=$hash_field
    ROW_REV_CLAIM=$rev
    ROW_DIGEST_CLAIM=$want_digest

    src="$WORK_ROOT/src/$id"
    stamp="$WORK_ROOT/stamp/$id.stamp"
    mkdir -p -- "$WORK_ROOT/src" "$WORK_ROOT/stamp" "$WORK_ROOT/cache" ||
        die "cannot create the work-root layout under $WORK_ROOT"

    if [[ -d $src/.git ]] && stamp_matches "$src" "$stamp"; then
        note "   reusing verified checkout $src"
    else
        # A stamp that does not hold, or a checkout that is not one, is not
        # patched on top of. Remove it and start from the pinned commit, because
        # a half-applied patch series on top of an unknown tree is exactly the
        # state a cache restore can silently produce.
        if [[ -e $src ]]; then
            note "   discarding unusable checkout $src"
            rm -rf -- "$src" || die "cannot remove $src"
        fi
        mkdir -p -- "$src" || die "cannot create $src"
        git -C "$src" init -q || fatal "$id: cannot initialise $src"
        git -C "$src" remote add origin "$repo" ||
            fatal "$id: cannot add remote $repo"
        git -C "$src" fetch -q --depth 1 origin "$rev" ||
            fatal "$id: cannot fetch $rev from $repo"
        got=$(git -C "$src" rev-parse FETCH_HEAD) ||
            fatal "$id: cannot read FETCH_HEAD"
        if [[ $got != "$rev" ]]; then
            die "$id: fetched $got but the manifest pins $rev
       the remote no longer serves the pinned commit; refusing to build something else"
        fi
        git -C "$src" checkout -q --detach "$rev" ||
            fatal "$id: cannot check out $rev"
        for p in ${plist[@]+"${plist[@]}"}; do
            git -C "$src" apply --whitespace=nowarn -p1 "$QUALITY_ROOT/$p" ||
                fatal "$id: patch $p does not apply to $rev
       the pinned commit and the checked-in patch disagree; nothing was installed"
        done
        note "   applied ${#plist[@]} patch(es)"
        got_digest=$(source_digest "$src")
        if [[ -n $want_digest && $want_digest != "-" && $got_digest != "$want_digest" ]]; then
            die "$id: source digest is $got_digest but the manifest records $want_digest
       the patched tree is not the tree this pin describes; refusing to install"
        fi
        # The build inputs are hashed HERE, from the tree this run just built
        # the stamp for, and the stamp is what a later run compares against. A
        # stamp with no build-input field would be a stamp that cannot detect
        # the one edit it exists to catch, so its absence is refused rather than
        # papered over with a digest of nothing.
        got_inputs=$(build_inputs_digest "$src") ||
            die "$id: no build input to hash in $src; refusing to record a stamp
       that a later run could not check the build script against"
        mkdir -p -- "$(dirname -- "$stamp")"
        {
            printf 'id=%s\n' "$id"
            printf 'revision=%s\n' "$rev"
            printf 'patch_sha256=%s\n' "$hash_field"
            printf 'source_digest=%s\n' "$got_digest"
            printf 'build_inputs_digest=%s\n' "$got_inputs"
            printf 'captured_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        } >"$stamp" || die "cannot write $stamp"
    fi

    builddir="$WORK_ROOT/build/$id"
    rm -rf -- "$builddir" || die "cannot clear $builddir"
    mkdir -p -- "$builddir" || die "cannot create $builddir"
    note "   building $build_argv with $ZIG_VERSION"
    if ! (cd "$src" && "$ZIG" build ${step:+"$step"} "-Doptimize=$OPTIMIZE" \
        --prefix "$builddir" \
        --cache-dir "$WORK_ROOT/cache/local/$id" \
        --global-cache-dir "$WORK_ROOT/cache/global") \
        >"$builddir/build.log" 2>&1; then
        printf '%s: %s: build failed; last 40 lines of %s/build.log\n' "$PROG" "$id" "$builddir" >&2
        tail -40 "$builddir/build.log" >&2
        fatal "$id: build failed"
    fi
    produced="$builddir/${artifact#zig-out/}"
    [[ -f $produced && -x $produced ]] ||
        fatal "$id: expected $produced after a successful build, and it is not there"
    install -m 0755 -- "$produced" "$STAGE/$ipath" ||
        fatal "$id: cannot stage $ipath"
    note "   built $(row_field "$row" $COL_TVER) -> staged $ipath"
    INSTALLED_ANALYZERS+=("$id	$tver	$comp	$repo	$rev	$ipath	$lic	$build_argv	$hash_field	$want_digest")
done

# --------------------------------------------------------------- harness --

if ((${#WANT_HARNESS[@]} > 0)); then
    note "== harness (reviewed sources, no build step)"
    for h in "${HARNESS_BIN[@]}"; do
        want=0
        for w in "${WANT_HARNESS[@]}"; do [[ $w == "$h" ]] && want=1; done
        ((want)) || continue
        install -m 0755 -- "$QUALITY_ROOT/harness/bin/$h" "$STAGE/bin/$h" ||
            fatal "cannot stage bin/$h"
        note "   staged bin/$h"
    done
    # The two regression suites are run by hand, so they keep their executable
    # bit; the rest are sourced, so they do not need one. Recorded rather than
    # assumed: a helper installed non-executable is a file nothing complains
    # about until someone tries to run it.
    for h in "${HELPER_FILES[@]}"; do
        case $h in
            test.sh | test-zig.sh) mode=0755 ;;
            *) mode=0644 ;;
        esac
        install -m "$mode" -- "$QUALITY_ROOT/harness/lib/cross-test/$h" \
            "$STAGE/lib/cross-test/$h" || fatal "cannot stage lib/cross-test/$h"
    done
    note "   staged lib/cross-test/{$(IFS=,; echo "${HELPER_FILES[*]}")}"
fi

# ------------------------------------------------------- share/ and meta --

install -m 0644 -- "$MANIFEST" "$STAGE/share/zig-interval-quality/manifest.tsv" ||
    fatal "cannot stage the manifest"
install -m 0644 -- "$QUALITY_ROOT/SHA256SUMS" "$STAGE/share/zig-interval-quality/SHA256SUMS" ||
    fatal "cannot stage SHA256SUMS"
if [[ -r $QUALITY_ROOT/PROVENANCE.md ]]; then
    install -m 0644 -- "$QUALITY_ROOT/PROVENANCE.md" \
        "$STAGE/share/zig-interval-quality/PROVENANCE.md" ||
        fatal "cannot stage PROVENANCE.md"
fi
while IFS= read -r -d '' f; do
    mkdir -p -- "$STAGE/share/zig-interval-quality/$(dirname -- "$f")"
    install -m 0644 -- "$QUALITY_ROOT/$f" "$STAGE/share/zig-interval-quality/$f" ||
        fatal "cannot stage $f"
done < <(cd "$QUALITY_ROOT" && find licenses patches -type f -print0)

staged_hash() {
    [[ -f $1 ]] || return 1
    sha256sum -- "$1" | cut -d' ' -f1
}

# The installation manifest. Written last, after every file is in the staging
# tree, so its hashes describe what is actually about to be installed. It is
# written over what is staged rather than over what was asked for, because a
# --only subset is a legitimate install and a row for a file that was never
# copied would be a lie.
{
    printf '#name\tkind\ttool_version\tcompiler\tsource_url\tsource_revision\tinstall_path\tinstall_sha256\tlicense\tbuild_recipe\tpatch_sha256\tsource_digest\n'
    for rec in ${INSTALLED_ANALYZERS[@]+"${INSTALLED_ANALYZERS[@]}"}; do
        # Ten fields, read in the order the loop above appended them and in the
        # order this row prints them. It used to append ten and read nine, and
        # the two halves disagreed about which field was which: the manifest
        # row came out with the source digest under patch_sha256, the revision
        # under source_digest, and the real patch hashes dropped on the floor.
        # Nothing caught it because both columns are hex-ish strings and the
        # re-hash a prefix is verified with reads neither of them.
        IFS=$'\t' read -r r_id r_tver r_comp r_repo r_rev r_ipath r_lic \
            r_recipe r_ph r_sd <<<"$rec"
        sum=$(staged_hash "$STAGE/$r_ipath") || continue
        # build_recipe is the argv that ACTUALLY ran, not a fixed string: a
        # reader has to be able to tell `zig build` from `zig build cli`
        # without reading this script.
        printf '%s\tanalyzer\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$r_id" "$r_tver" "$r_comp" "$r_repo" "$r_rev" "$r_ipath" "$sum" \
            "$r_lic" "$r_recipe" "$r_ph" "$r_sd"
    done
    # bin/ and lib/cross-test/ are first-party: they ship under this
    # repository's own MIT, whose text is installed beside them as
    # harness.LICENSE. The column says that per row instead of leaving a reader
    # to infer it from a directory listing, and the four upstream notices below
    # are retained for the analyzers that actually carry them.
    for h in ${WANT_HARNESS[@]+"${WANT_HARNESS[@]}"}; do
        sum=$(staged_hash "$STAGE/bin/$h") || continue
        printf '%s\tharness\tsource\t-\ttools/quality/harness/bin/%s\t-\tbin/%s\t%s\t%s\tverbatim copy\t-\t-\n' \
            "$h" "$h" "$h" "$sum" "$HARNESS_LICENSE"
    done
    for h in "${HELPER_FILES[@]}"; do
        sum=$(staged_hash "$STAGE/lib/cross-test/$h") || continue
        printf '%s\thelper\tsource\t-\ttools/quality/harness/lib/cross-test/%s\t-\tlib/cross-test/%s\t%s\t%s\tverbatim copy\t-\t-\n' \
            "$h" "$h" "$h" "$sum" "$HARNESS_LICENSE"
    done
    while IFS= read -r -d '' p; do
        tool_name=${p#patches/}
        tool_name=${tool_name%%/*}
        sum=$(staged_hash "$STAGE/share/zig-interval-quality/$p") ||
            fatal "cannot hash staged patch $p"
        printf '%s\tpatch\t-\t-\t-\t-\tshare/zig-interval-quality/%s\t%s\tMIT (licenses/%s.LICENSE and licenses/harness.LICENSE)\tverbatim copy\t-\t-\n' \
            "$p" "$p" "$sum" "$tool_name"
    done < <(cd "$QUALITY_ROOT" && find patches -type f -print0)
    for l in zbc ziglint zlint zwanzig; do
        sum=$(staged_hash "$STAGE/share/zig-interval-quality/licenses/$l.LICENSE") || continue
        printf '%s.LICENSE\tlicense\t-\t-\t-\t-\tshare/zig-interval-quality/licenses/%s.LICENSE\t%s\tMIT (upstream)\tverbatim copy\t-\t-\n' \
            "$l" "$l" "$sum"
    done
    if sum=$(staged_hash "$STAGE/share/zig-interval-quality/licenses/harness.LICENSE"); then
        printf 'harness.LICENSE\tlicense\t-\t-\t-\t-\tshare/zig-interval-quality/licenses/harness.LICENSE\t%s\tMIT (this repository; see LICENSE)\tverbatim copy\t-\t-\n' \
            "$sum"
    fi
    # The distribution's own metadata is first-party too, so it is labelled as
    # such rather than left as `-`: every row in this file says what it travels
    # under, and a reader should not have to infer it from a directory name.
    if sum=$(staged_hash "$STAGE/share/zig-interval-quality/PROVENANCE.md"); then
        printf 'PROVENANCE.md\tprovenance\t-\t-\t-\t-\tshare/zig-interval-quality/PROVENANCE.md\t%s\tMIT (this repository)\tverbatim copy\t-\t-\n' "$sum"
    fi
    if sum=$(staged_hash "$STAGE/share/zig-interval-quality/manifest.tsv"); then
        printf 'manifest.tsv\tmanifest\t-\t-\t-\t-\tshare/zig-interval-quality/manifest.tsv\t%s\tMIT (this repository)\tverbatim copy\t-\t-\n' "$sum"
    fi
    if sum=$(staged_hash "$STAGE/share/zig-interval-quality/SHA256SUMS"); then
        printf 'SHA256SUMS\tmanifest\t-\t-\t-\t-\tshare/zig-interval-quality/SHA256SUMS\t%s\tMIT (this repository)\tverbatim copy\t-\t-\n' "$sum"
    fi
} >"$STAGE/install-manifest.tsv" || fatal "cannot write the installation manifest"

# A redirect creates the file with the caller's umask, and umask 077 is ordinary
# on a shared build host. Every other file in the staging tree was installed with
# an explicit mode; this one has to be given one too, or the installed prefix
# carries a 0600 file where a reader expects a readable one.
chmod 0644 -- "$STAGE/install-manifest.tsv" ||
    fatal "cannot set the mode on the installation manifest"

# ---------------------------------------------------------------- install --

# The staging tree is complete and every hash in it has been computed, so the
# remaining step is a file copy. A failure here removes a prefix this installer
# created rather than leaving one that is half a gate, and says so. A --force
# install over a pre-existing prefix is NOT undone: files already replaced stay
# replaced, and the diagnostic names where it stopped. That asymmetry is the
# honest one, and it is why --force is a separate decision from a cold install.
copy_into_prefix() {
    local rel dest
    while IFS= read -r rel; do
        dest="$PREFIX/$rel"
        if [[ -d $STAGE/$rel ]]; then
            mkdir -p -- "$dest" || {
                printf 'cannot create %s\n' "$dest" >&2
                return 1
            }
            continue
        fi
        mkdir -p -- "${dest%/*}" || {
            printf 'cannot create %s\n' "${dest%/*}" >&2
            return 1
        }
        # cp without --preserve creates a NEW file with the source mode masked by
        # the caller's umask, and a caller running with umask 077 gets a 0600
        # binary and a 0600 gate. The staging tree already carries the right
        # mode, so carry it over explicitly instead of depending on the umask in
        # effect at the moment of the copy.
        install -m "$(stat -c '%a' -- "$STAGE/$rel")" -- "$STAGE/$rel" "$dest" || {
            printf 'cannot install %s\n' "$dest" >&2
            return 1
        }
    done < <(cd "$STAGE" && find . -mindepth 1 -printf '%P\n' | LC_ALL=C sort)
}
copy_into_prefix ||
    fatal "install into $PREFIX failed; the staging tree is intact under $STAGE"
trap - EXIT

note ""
note "installed into $PREFIX"
for rec in ${INSTALLED_ANALYZERS[@]+"${INSTALLED_ANALYZERS[@]}"}; do
    IFS=$'\t' read -r r_id _rest <<<"$rec"
    note "  bin/$r_id"
done
for h in ${WANT_HARNESS[@]+"${WANT_HARNESS[@]}"}; do note "  bin/$h"; done
if [[ -f $PREFIX/lib/cross-test/scratch-contract.sh ]]; then
    note "  lib/cross-test/{$(IFS=,; echo "${HELPER_FILES[*]}")}"
fi
note "  install-manifest.tsv"
note ""
if [[ -f $PREFIX/share/zig-interval-quality/licenses/harness.LICENSE ]]; then
    note "every payload file is hashed in install-manifest.tsv (the manifest cannot hash itself); re-check with"
    note "  ( cd \"\$PREFIX\" && awk -F'\t' '!/^#/ {print \$8\"  \"\$7}' install-manifest.tsv | sha256sum --check --strict - )"
    note "the four upstream licences and harness.LICENSE are in share/zig-interval-quality/licenses/."
fi
note ""
note "the installed gate resolves its analyzers inside $PREFIX with no \$HOME and no"
note "PATH lookup; unset ZIG_GATE_PREFIX only if you mean to use the developer layout."
exit 0
