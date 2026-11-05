#!/bin/bash
# Builds a KIND=gcc toolchain inside the build container (docker/Dockerfile):
# binutils into $PREFIX, then a profiled, LTO bootstrap of GCC into $PREFIX
# using those binutils, then hands the unstripped install to package-gcc.sh.
#
#   /src/repo     read-only: this repository
#   /src/sources  read-only: verified upstream tarballs
#   /out          writable:  .debs, logs and build metadata of this toolchain
set -euo pipefail
. /src/repo/scripts/env.sh
trap finish EXIT
[ "$KIND" = gcc ] || { echo "error: $TOOLCHAIN is KIND=$KIND, not gcc" >&2; exit 1; }

# ---------------------------------------------------------------- unpack
cd "$WORK"
tar xf "/src/sources/binutils-$BINUTILS_VERSION.tar.xz"
tar xf "/src/sources/gcc-$GCC_VERSION.tar.xz"
for p in "gmp-$GMP_VERSION.tar.bz2:gmp" "mpfr-$MPFR_VERSION.tar.bz2:mpfr" \
         "mpc-$MPC_VERSION.tar.gz:mpc" "isl-$ISL_VERSION.tar.bz2:isl"; do
    tarball=${p%%:*}; name=${p##*:}
    tar xf "/src/sources/$tarball"
    # GCC builds these in-tree and links them statically into cc1 & co,
    # so the compiler does not depend on the distribution's gmp/mpfr/mpc/isl.
    ln -s "../${tarball%.tar.*}" "gcc-$GCC_VERSION/$name"
done

# ---------------------------------------------------------------- binutils
# Older distributions' binutils (buster: 2.31) are too old for the
# instructions new GCCs can emit (AVX10, APX, ...), so every toolchain ships
# its own assembler and linker, which also keeps behaviour identical everywhere.
BINUTILS_CONFIGURE=(
    --prefix="$PREFIX"
    --build=$TRIPLET --host=$TRIPLET --target=$TRIPLET
    --enable-ld=default
    --enable-plugins
    --enable-deterministic-archives
    --enable-64-bit-bfd
    --disable-nls
    --disable-werror
    --disable-gdb --disable-gdbserver --disable-sim --disable-gprofng
    --without-debuginfod
    --without-zstd
    --with-system-zlib
    --with-pkgversion="$PKG_NAME $DEB_VERSION"
)
mkdir -p "$WORK/obj-binutils"
cd "$WORK/obj-binutils"
step binutils-configure "$WORK/binutils-$BINUTILS_VERSION/configure" "${BINUTILS_CONFIGURE[@]}"
step binutils-build make -j"$JOBS"
# Installed unstripped: package-gcc.sh splits the debug info into -dbgsym.
step binutils-install make install

# The rest of the build must use the new binutils (ar/ranlib included,
# which also makes target archives such as libstdc++.a deterministic).
export PATH="$PREFIX/bin:$PATH"

# ---------------------------------------------------------------- gcc
GCC_CONFIGURE=(
    --prefix="$PREFIX"
    --build=$TRIPLET --host=$TRIPLET --target=$TRIPLET
    --enable-languages=c,c++,fortran,lto
    --enable-bootstrap
    # LTO for the final (profile-feedback) stage only, as Debian/Ubuntu do;
    # see config/bootstrap-lto-lean.mk in the GCC sources.
    --with-build-config=bootstrap-lto-lean
    --enable-checking=release
    --disable-multilib
    --disable-nls
    --enable-shared
    --enable-threads=posix
    --enable-__cxa_atexit
    --enable-clocale=gnu
    --enable-default-pie
    --enable-gnu-unique-object
    --enable-linker-build-id
    --enable-lto
    --enable-plugin
    --enable-libstdcxx-time=yes
    # Extra libstdc++ built with -g3 -O0 -D_GLIBCXX_ASSERTIONS into lib64/debug
    # (package <PKG_NAME>-libstdc++-dbg), like Debian's libstdc++6-N-dbg.
    --enable-libstdcxx-debug
    --with-default-libstdcxx-abi=new
    --with-system-zlib
    --without-zstd
    --with-tune=generic
    --with-as="$PREFIX/bin/as"
    --with-ld="$PREFIX/bin/ld"
    --with-pkgversion="$PKG_NAME $DEB_VERSION"
)
mkdir -p "$WORK/obj-gcc"
cd "$WORK/obj-gcc"
step gcc-configure "$WORK/gcc-$GCC_VERSION/configure" "${GCC_CONFIGURE[@]}"
# profiledbootstrap: stage1 is built by the distribution's gcc; every later
# stage is built by the new GCC itself. The "train" stage compiles GCC's own
# sources to collect a profile, and the final "feedback" stage is optimised
# with that profile (PGO) plus LTO. Everything installed comes from it.
step gcc-bootstrap make -j"$JOBS" profiledbootstrap
step gcc-install make install

# libstdc++_pic.a: the PIC objects of libstdc++ (libtool's convenience
# archive) plus the symbol version script, for linking libstdc++ statically
# into a shared library. Same files Debian ships in libstdc++-N-pic.
GCC_LIBDIR="$PREFIX/lib/gcc/$TRIPLET/$GCC_VERSION"
LIBSTDCXX_OBJ="$WORK/obj-gcc/$TRIPLET/libstdc++-v3"
for f in "$LIBSTDCXX_OBJ/src/.libs/libstdc++convenience.a" "$LIBSTDCXX_OBJ/src/libstdc++-symbols.ver"; do
    if [ ! -f "$f" ]; then
        echo "error: $f not found; candidates:" >&2
        find "$LIBSTDCXX_OBJ" -name 'libstdc++convenience.a' -o -name 'libstdc++-symbols.ver' >&2
        exit 1
    fi
done
install -m 0644 "$LIBSTDCXX_OBJ/src/.libs/libstdc++convenience.a" "$GCC_LIBDIR/libstdc++_pic.a"
install -m 0644 "$LIBSTDCXX_OBJ/src/libstdc++-symbols.ver" "$GCC_LIBDIR/libstdc++_pic.map"

if [ "${RUN_GCC_TESTSUITE:-0}" = 1 ]; then
    # Optional and slow (hours); needs dejagnu in the image.
    step gcc-check make -k -j"$JOBS" check || true
fi

# ---------------------------------------------------------------- buildinfo
{
    buildinfo_header
    echo
    echo "gcc       $GCC_VERSION"
    echo "binutils  $BINUTILS_VERSION"
    echo "gmp       $GMP_VERSION (static, in-tree)"
    echo "mpfr      $MPFR_VERSION (static, in-tree)"
    echo "mpc       $MPC_VERSION (static, in-tree)"
    echo "isl       $ISL_VERSION (static, in-tree)"
    echo "bootstrap make profiledbootstrap (PGO) + bootstrap-lto-lean (LTO)"
    echo
    echo "binutils configure:"
    printf '  %s\n' "${BINUTILS_CONFIGURE[@]}"
    echo
    echo "gcc configure:"
    printf '  %s\n' "${GCC_CONFIGURE[@]}"
    echo
    buildinfo_footer
} > "$WORK/BUILDINFO"

save_stage "${PREFIX#/}" "${WORK#/}/BUILDINFO"

trap - EXIT
exec bash /src/repo/scripts/package-gcc.sh
