#!/bin/bash
# Turns an unstripped KIND=gcc install into .debs, Debian style:
#
#   <PKG_NAME>                  GCC + binutils from $PREFIX            (stripped)
#   <PKG_NAME>-libstdc++-dbg    -O0 debug build of libstdc++           (unstripped)
#   <PKG_NAME>-dbgsym           debug info for <PKG_NAME>, in /usr/lib/debug/.build-id
#
# Inputs (left by build-gcc.sh, or restored by `make repackage`):
#   $PREFIX            GCC + binutils, installed unstripped
#   $WORK/BUILDINFO    build description
set -euo pipefail
. /src/repo/scripts/env.sh
trap finish EXIT

# The toolchain's own binutils, which know every section the new GCC emits.
OBJCOPY="$PREFIX/bin/objcopy"
STRIP="$PREFIX/bin/strip"
READELF="$PREFIX/bin/readelf"
. /src/repo/scripts/package-lib.sh

LIBDBG_PKG="$PKG_NAME-libstdc++-dbg"
TPL=/src/repo/debian/templates
MAIN="$PKG/debian/$PKG_NAME"
MAIN_DBG="$PKG/debian/$PKG_NAME-dbgsym"
LIBDBG="$PKG/debian/$LIBDBG_PKG"

mkdir -p "$MAIN$(dirname "$PREFIX")"
cp -a "$PREFIX" "$MAIN$PREFIX"
rm -f "$MAIN$PREFIX/share/info/dir"

# libstdc++ installs its gdb pretty-printer hook next to the library, where
# gdb's auto-load safe-path refuses it. Move it to the system auto-load
# directory, keyed by the library's full path (as Debian does). Every gdb
# looks there: this repository's gdb-N-opt and the distribution's gdb.
AUTOLOAD="$MAIN/usr/share/gdb/auto-load$PREFIX/lib64"
for py in "$MAIN$PREFIX"/lib64/libstdc++.so.*-gdb.py; do
    [ -e "$py" ] || continue
    mkdir -p "$AUTOLOAD"
    mv "$py" "$AUTOLOAD/"
done

# The -O0 debug build of libstdc++ (lib64/debug) goes to its own package and
# keeps its DWARF in place: it exists to be stepped through in a debugger.
if [ ! -d "$MAIN$PREFIX/lib64/debug" ]; then
    echo "error: $PREFIX/lib64/debug missing; was GCC configured with --enable-libstdcxx-debug?" >&2
    exit 1
fi
mkdir -p "$LIBDBG$PREFIX/lib64"
mv "$MAIN$PREFIX/lib64/debug" "$LIBDBG$PREFIX/lib64/debug"
rm -f "$LIBDBG$PREFIX/lib64/debug/"*-gdb.py "$LIBDBG$PREFIX/lib64/debug/"*.la
# Same pretty-printer hook, but its libdir must name the debug directory:
# the hook derives the printers' location from it relative to the library.
for py in "$AUTOLOAD"/libstdc++.so.*-gdb.py; do
    [ -e "$py" ] || continue
    dst="$LIBDBG/usr/share/gdb/auto-load$PREFIX/lib64/debug"
    mkdir -p "$dst"
    sed "s|^libdir = .*|libdir = '$PREFIX/lib64/debug'|" "$py" > "$dst/$(basename "$py")"
done

# No links in /usr/bin: names like gcc-15 belong to the distribution's own
# gcc-N packages, and dpkg would refuse to install both. Use $PREFIX/bin.

mapfile -t lic < <(licence_files "/src/sources/gcc-$GCC_VERSION.tar.xz" "gcc-$GCC_VERSION")
add_doc "$MAIN" "$PKG_NAME" "$TPL/gcc.copyright" "${lic[@]}"

echo "==> $(date -u +%H:%M:%S) split-debug $PKG_NAME" >&2
split_debug "$MAIN" "$MAIN_DBG" "$PKG/build-ids.$PKG_NAME"

SHLIBS_DEPENDS=$(shlibs_depends "$PKG_NAME" "$MAIN")
add_pycache_cleanup "$MAIN" "$PREFIX/share/gcc-$GCC_VERSION/python"
build_deb "$MAIN" "$(subst "$TPL/gcc.control")"

# Nothing in the debug libstdc++ tree is stripped.
link_doc "$LIBDBG" "$LIBDBG_PKG" "$PKG_NAME"
build_deb "$LIBDBG" "$(subst "$TPL/gcc-libstdcxx-dbg.control")"

build_dbgsym "$PKG_NAME" "$MAIN_DBG" "$PKG/build-ids.$PKG_NAME"
finish_packaging
