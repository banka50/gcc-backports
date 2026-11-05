#!/bin/bash
# Builds a KIND=gdb toolchain inside the build container, with the
# distribution's own compiler, so it needs nothing but the distribution's
# libraries at run time and does not depend on any gcc-N-opt package.
set -euo pipefail
. /src/repo/scripts/env.sh
trap finish EXIT
[ "$KIND" = gdb ] || { echo "error: $TOOLCHAIN is KIND=$KIND, not gdb" >&2; exit 1; }

# Separate debug info is looked up in /usr/lib/debug (the -dbgsym packages
# of this repository and of the distribution). Auto-load scripts, such as
# the libstdc++ pretty-printers every gcc-N-opt installs, are also taken
# from /usr/share/gdb/auto-load, where the distribution's gdb looks too.
GDB_CONFIGURE=(
    --prefix="$PREFIX"
    --build=$TRIPLET --host=$TRIPLET --target=$TRIPLET
    --with-python=/usr/bin/python3
    --with-expat
    --with-lzma
    --with-system-zlib
    --enable-tui
    --with-separate-debug-dir=/usr/lib/debug
    '--with-auto-load-dir=$debugdir:$datadir/auto-load:/usr/share/gdb/auto-load'
    '--with-auto-load-safe-path=$debugdir:$datadir/auto-load:/usr/share/gdb/auto-load'
    --without-zstd
    --without-debuginfod
    --without-guile
    --without-babeltrace
    --without-intel-pt
    --without-xxhash
    --disable-source-highlight
    --disable-sim
    --disable-nls
    --disable-werror
    --with-pkgversion="$PKG_NAME $DEB_VERSION"
    CFLAGS="-g -O2"
    CXXFLAGS="-g -O2"
)
cd "$WORK"
tar xf "/src/sources/gdb-$GDB_VERSION.tar.xz"
mkdir -p "$WORK/obj-gdb"
cd "$WORK/obj-gdb"
step gdb-configure "$WORK/gdb-$GDB_VERSION/configure" "${GDB_CONFIGURE[@]}"
step gdb-build make -j"$JOBS" all-gdb all-gdbserver
# Installed unstripped: package-gdb.sh splits the debug info into -dbgsym.
step gdb-install make install-gdb install-gdbserver DESTDIR="$WORK/dest"

{
    buildinfo_header
    echo "compiler  $(gcc --version | head -1) (the distribution's)"
    echo
    echo "gdb       $GDB_VERSION"
    echo
    echo "gdb configure:"
    printf '  %s\n' "${GDB_CONFIGURE[@]}"
    echo
    buildinfo_footer
} > "$WORK/BUILDINFO"

save_stage "${WORK#/}/dest" "${WORK#/}/BUILDINFO"

trap - EXIT
exec bash /src/repo/scripts/package-gdb.sh
