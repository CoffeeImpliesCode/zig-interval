#!/usr/bin/env bash
# Build MPFR and regenerate tests/corpus/elementary.txt.
#
# The corpus is COMMITTED and this script is not run by the test suite. That is
# deliberate: a gate that shells out to a C library, or that depends on a
# toolchain the host may not have, is not a gate. The committed file is the
# artefact; this is how it is reproduced, and the two should be regenerated
# together and committed together.
#
# Why MPFR is built here rather than taken from the system: the host carries
# libmpfr.so.6 but no mpfr.h, and without the header there is no way to call it
# correctly. That is not a theoretical concern - see the three interface facts
# at the top of gen_corpus.c, all three of which were got wrong before the
# header was available to check them against.
#
# Usage:  ./scripts/build_mpfr.sh && /tmp/gen_corpus > tests/corpus/elementary.txt

set -euo pipefail

# Resolve the script's own directory up front, before anything moves the shell.
# The build step below cds into the MPFR source tree, so a RELATIVE $0 - which is
# what `bash scripts/build_mpfr.sh` gives, and what the usage line documents -
# stops pointing at this file's neighbours and the compile step fails on a
# gen_corpus.c that exists. Two of the three interface facts in gen_corpus.c were
# only ever verified because someone compiled it; a script that cannot reach its
# own sources is a reproducibility claim with nothing behind it.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

MPFR_VERSION="${MPFR_VERSION:-4.2.1}"
PREFIX="${MPFR_PREFIX:-/tmp/mpfr-install}"
SRC="${MPFR_SRC:-/tmp/mpfr-$MPFR_VERSION}"

if [ ! -f "$PREFIX/include/mpfr.h" ]; then
    echo "building MPFR $MPFR_VERSION into $PREFIX"
    # In a subshell: the build leaves the shell inside the source tree, and every
    # path after this block is relative to the directory the caller was in.
    (
        cd "$(dirname "$SRC")"
        if [ ! -d "$SRC" ]; then
            tarball="mpfr-$MPFR_VERSION.tar.xz"
            [ -f "$tarball" ] || curl -sSLO "https://ftp.gnu.org/gnu/mpfr/$tarball"
            [ -d "mpfr-$MPFR_VERSION" ] || tar xf "$tarball"
            # tar lays the tree down under the TARBALL's name, which is the
            # requested $SRC only when MPFR_SRC is left at its default. Point at
            # what was actually unpacked, so MPFR_SRC names the source tree for
            # any value of it rather than only for the default.
            SRC="$(pwd)/mpfr-$MPFR_VERSION"
        fi
        cd "$SRC"
        ./configure --prefix="$PREFIX" --with-gmp=/usr
        make -j"$(nproc)"
        make install
    )
else
    echo "MPFR headers already present at $PREFIX/include/mpfr.h"
fi

# MPFR installs into lib64 on some hosts and lib on others; ask it rather than
# guessing, because guessing this produced a generator that linked nothing.
LIBDIR="$("$PREFIX/bin/mpfr-config" --libdir 2>/dev/null || echo "$PREFIX/lib")"
for cand in "$PREFIX/lib64" "$PREFIX/lib"; do
    [ -f "$cand/libmpfr.a" ] && LIBDIR="$cand" && break
done

echo "compiling gen_corpus against $LIBDIR"
gcc -O2 -I"$PREFIX/include" "$SCRIPT_DIR/gen_corpus.c" \
    -o /tmp/gen_corpus \
    -L"$LIBDIR" -lmpfr -lgmp -lm -Wl,-rpath,"$LIBDIR"

echo "built /tmp/gen_corpus; run it and redirect to tests/corpus/elementary.txt"