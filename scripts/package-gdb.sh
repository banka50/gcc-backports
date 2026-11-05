#!/bin/bash
# Turns an unstripped KIND=gdb install into .debs:
#
#   <PKG_NAME>          GDB + gdbserver in $PREFIX       (stripped)
#   <PKG_NAME>-dbgsym   debug info, in /usr/lib/debug/.build-id
#
# Inputs (left by build-gdb.sh, or restored by `make repackage`):
#   $WORK/dest$PREFIX   GDB, installed unstripped
#   $WORK/BUILDINFO     build description
set -euo pipefail
. /src/repo/scripts/env.sh
trap finish EXIT

# GDB is built by the distribution's compiler, so its binutils are enough.
OBJCOPY=objcopy
STRIP=strip
READELF=readelf
. /src/repo/scripts/package-lib.sh

TPL=/src/repo/debian/templates
MAIN="$PKG/debian/$PKG_NAME"
MAIN_DBG="$PKG/debian/$PKG_NAME-dbgsym"

mkdir -p "$MAIN"
cp -a "$WORK/dest/." "$MAIN/"
rm -f "$MAIN$PREFIX/share/info/dir"

# No links in /usr/bin, like the gcc toolchains: use $PREFIX/bin.

mapfile -t lic < <(licence_files "/src/sources/gdb-$GDB_VERSION.tar.xz" "gdb-$GDB_VERSION")
add_doc "$MAIN" "$PKG_NAME" "$TPL/gdb.copyright" "${lic[@]}"

echo "==> $(date -u +%H:%M:%S) split-debug $PKG_NAME" >&2
split_debug "$MAIN" "$MAIN_DBG" "$PKG/build-ids.$PKG_NAME"

SHLIBS_DEPENDS=$(shlibs_depends "$PKG_NAME" "$MAIN")
add_pycache_cleanup "$MAIN" "$PREFIX/share/gdb/python"
build_deb "$MAIN" "$(subst "$TPL/gdb.control")"

build_dbgsym "$PKG_NAME" "$MAIN_DBG" "$PKG/build-ids.$PKG_NAME"
finish_packaging
