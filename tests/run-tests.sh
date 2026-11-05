#!/bin/bash
# Smoke test for one distribution: installs every toolchain built for it
# (out/<dist>/<toolchain>/, mounted at /out) side by side into a pristine
# container and checks, for each gcc-N-opt: C, C++, Fortran, OpenMP, LTO,
# sanitizers, the bundled binutils, libstdc++_pic.a, the debug libstdc++ and
# the -dbgsym package; for gdb-N-opt: Python, DWARF 5, pretty-printers of
# every GCC, its own -dbgsym. Finally everything must purge cleanly and the
# distribution's C/C++ runtime must be exactly as before.
set -euo pipefail

: "${DIST:?DIST must name a directory under dists/}"
. "/src/repo/dists/$DIST/dist.env"
T=/src/repo/tests

sh /src/repo/docker/setup-apt.sh "/src/repo/dists/$DIST/sources.list"
apt-get update -qq
# snapshot.debian.org drops connections now and then: retry before failing.
apt_install() {
    local i
    for i in 1 2 3; do
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" > /dev/null && return 0
        echo "apt-get install failed (attempt $i), retrying" >&2
        sleep 10
    done
    return 1
}

runtime_state() { { dpkg-query -W -f '${Package}=${Version}\n' 'libstdc++6' 'libgcc-s1' 'libgcc1' 2>/dev/null || true; } | sort; }
RUNTIME_BEFORE=$(runtime_state)

W=$(mktemp -d)
cd "$W"
pass=0
check() {  # check <description> <command...>
    local what=$1; shift
    if out=$("$@" 2>&1); then
        echo "ok    $what"
        pass=$((pass + 1))
    else
        echo "FAIL  $what"
        echo "$out" | sed 's/^/      /'
        exit 1
    fi
}

# load <toolchain>: its settings, plus the derived names used below.
load() {
    unset GCC_VERSION BINUTILS_VERSION GDB_VERSION
    . "/src/repo/toolchains/$1.env"
    M=${UPSTREAM_VERSION%%.*}
    V="$UPSTREAM_VERSION-$PKG_REVISION$DIST_SUFFIX"
    DEB_MAIN="/out/$1/${PKG_NAME}_${V}_amd64.deb"
    DEB_DBGSYM="/out/$1/${PKG_NAME}-dbgsym_${V}_amd64.deb"
    LIBDBG_PKG="$PKG_NAME-libstdc++-dbg"
    DEB_LIBDBG="/out/$1/${LIBDBG_PKG}_${V}_amd64.deb"
    RPATH="-Wl,-rpath,$PREFIX/lib64"
    GCC=$PREFIX/bin/gcc GXX=$PREFIX/bin/g++ GFORTRAN=$PREFIX/bin/gfortran CPP=$PREFIX/bin/cpp
}

GCCS=() GDBS=()
for d in /out/*/; do
    tc=$(basename "$d")
    [ -f "/src/repo/toolchains/$tc.env" ] || continue
    load "$tc"
    [ -f "$DEB_MAIN" ] || { echo "skip  $tc: $DEB_MAIN not built"; continue; }
    case "$KIND" in gcc) GCCS+=("$tc") ;; gdb) GDBS+=("$tc") ;; esac
done
echo "testing on $DIST_OS $DIST_VERSION ($DIST_CODENAME): ${GCCS[*]} ${GDBS[*]}"
[ ${#GCCS[@]} -gt 0 ] || { echo "no gcc toolchain built for $DIST" >&2; exit 1; }

GDB=
if [ ${#GDBS[@]} -gt 0 ]; then
    load "${GDBS[0]}"
    GDB="$PREFIX/bin/gdb" GDB_TC="${GDBS[0]}" GDB_PREFIX=$PREFIX GDB_VER=$GDB_VERSION
fi
LINE=$(grep -n 'break here' "$T/pp.cpp" | cut -d: -f1)

# ---------------------------------------------------------------- install side by side
mains=()
for tc in "${GCCS[@]}" "${GDBS[@]}"; do load "$tc"; mains+=("$DEB_MAIN"); done
check "install ${GCCS[*]} ${GDBS[*]} side by side" apt_install "${mains[@]}"
check "nothing installed into /usr/bin" \
      bash -c "[ -z \"\$(find /usr/bin /usr/local/bin -lname '/opt/*')\" ]"
check "system libstdc++6 / libgcc untouched" \
      bash -c "[ \"\$(dpkg-query -W -f '\${Package}=\${Version}\n' 'libstdc++6' 'libgcc-s1' 'libgcc1' 2>/dev/null | sort)\" = '$RUNTIME_BEFORE' ]"

# ---------------------------------------------------------------- each gcc
for tc in "${GCCS[@]}"; do
    load "$tc"
    echo "--- $tc"
    check "$GCC reports $GCC_VERSION"   bash -c "$GCC -dumpfullversion | grep -qx '$GCC_VERSION'"
    check "$GXX / $GFORTRAN / $CPP"     bash -c "$GXX --version && $GFORTRAN --version && $CPP --version"
    check "$GCC uses its bundled binutils $BINUTILS_VERSION" \
          bash -c "[ \"\$($GCC -print-prog-name=as)\" = '$PREFIX/bin/as' ] && $PREFIX/bin/as --version | grep -q ' $BINUTILS_VERSION'"
    check "C23 program"           bash -c "$GCC -std=c23 -Wall -Werror -O2 $T/hello.c -o c23-$M && ./c23-$M"
    check "C++23 program (std::print, std::expected, ranges)" \
          bash -c "$GXX -std=c++23 -Wall -Werror -O2 $T/hello.cpp -o cxx-$M $RPATH && ./cxx-$M"
    check "C++ with -static-libstdc++ needs no $PREFIX libs at run time" \
          bash -c "$GXX -std=c++23 -O2 -static-libstdc++ -static-libgcc $T/hello.cpp -o cxx-static-$M && ! ldd ./cxx-static-$M | grep -q '/opt/' && ./cxx-static-$M"
    check "Fortran 2018 program"  bash -c "$GFORTRAN -std=f2018 -O2 $T/hello.f90 -o f90-$M $RPATH && ./f90-$M"
    check "OpenMP"                bash -c "$GCC -fopenmp -O2 $T/omp.c -o omp-$M $RPATH && OMP_NUM_THREADS=4 ./omp-$M"
    check "LTO across two TUs"    bash -c "$GCC -flto -O2 $T/lto-main.c $T/lto-lib.c -o lto-$M && ./lto-$M"
    check "AddressSanitizer + UBSan" \
          bash -c "$GXX -std=c++23 -fsanitize=address,undefined -fno-sanitize-recover=all -g $T/hello.cpp -o asan-$M $RPATH && ./asan-$M"
    check "assembles AVX-512 / AVX10.2 / APX code (new binutils)" \
          bash -c "$GCC -O2 -march=diamondrapids -mprefer-vector-width=512 -c $T/isa.c -o isa-$M.o && $PREFIX/bin/objdump -d isa-$M.o | grep -q 'zmm'"
    PIC_A=$($GXX -print-file-name=libstdc++_pic.a)
    check "libstdc++_pic.a + .map are installed" bash -c "[ -f '$PIC_A' ] && [ -f '${PIC_A%.a}.map' ]"
    check "libstdc++_pic.a links into a .so that runs with the stock runtime" \
          bash -c "mkdir -p pic-$M && cd pic-$M && $GXX -std=c++23 -O2 -fPIC -shared $T/picfoo.cpp -o libpicfoo.so \
                       -nostdlib++ '$PIC_A' -lm -static-libgcc -Wl,--exclude-libs,ALL -Wl,-z,defs \
                   && ! ldd ./libpicfoo.so | grep -q 'libstdc++' \
                   && $GCC $T/picmain.c -L. -lpicfoo -Wl,-rpath,\\\$ORIGIN -o picmain && ./picmain"
    check "binaries are stripped, with a .gnu_debuglink" \
          bash -c "cc1plus=\$($GCC -print-prog-name=cc1plus) && ! $PREFIX/bin/readelf -S \"\$cc1plus\" | grep -q '\.debug_info' && $PREFIX/bin/readelf -S \"\$cc1plus\" | grep -q '\.gnu_debuglink'"
    check "$GCC emits DWARF 5"    bash -c "$GXX -g -O0 $T/pp.cpp -o pp-$M $RPATH && $PREFIX/bin/readelf --debug-dump=info pp-$M | grep -m1 -q 'Version: *5'"
done

# ---------------------------------------------------------------- gdb
if [ -n "$GDB" ]; then
    echo "--- $GDB_TC"
    check "$GDB reports $GDB_VER"  bash -c "$GDB --version | head -1 | grep -q ' $GDB_VER\$'"
    check "$GDB has Python"        bash -c "$GDB -batch -ex 'python print(\"py\", sys.version_info[0])' | grep -qx 'py 3'"
    for tc in "${GCCS[@]}"; do
        load "$tc"
        check "$GDB debugs a $GCC program, its libstdc++ pretty-printers load" \
              bash -c "out=\$($GDB -batch -ex 'break pp.cpp:$LINE' -ex run -ex 'print v' -ex 'print m' ./pp-$M 2>&1); \
                       echo \"\$out\"; grep -q 'std::vector of length 3' <<< \"\$out\" && grep -q '\[\"a\"\] = 1' <<< \"\$out\""
    done
else
    echo "skip  gdb checks: no gdb toolchain built for $DIST"
fi

# ---------------------------------------------------------------- libstdc++ debug builds
for tc in "${GCCS[@]}"; do
    load "$tc"
    echo "--- $LIBDBG_PKG"
    check "install $LIBDBG_PKG" apt_install "$DEB_LIBDBG"
    check "debug libstdc++ is built with -O0 and keeps its DWARF" \
          bash -c "$PREFIX/bin/readelf --debug-dump=info $PREFIX/lib64/debug/libstdc++.so.6 | grep -m1 DW_AT_producer | grep -q -- '-O0'"
    check "program runs against the debug libstdc++" \
          bash -c "$GXX -std=c++23 -g -O0 $T/pp.cpp -o pp-dbg-$M -Wl,-rpath,$PREFIX/lib64/debug \
                   && ldd ./pp-dbg-$M | grep -q '$PREFIX/lib64/debug/libstdc++.so.6' && ./pp-dbg-$M"
    if [ -n "$GDB" ]; then
        check "$GDB steps into the debug libstdc++, pretty-printers still load" \
              bash -c "out=\$($GDB -batch -ex 'break pp.cpp:$LINE' -ex run -ex 'info sharedlibrary' \
                              -ex 'print v' -ex 'info line std::__throw_bad_alloc' ./pp-dbg-$M 2>&1); echo \"\$out\"; \
                       grep -q '$PREFIX/lib64/debug/libstdc++.so.6' <<< \"\$out\" && grep -q 'std::vector of length 3' <<< \"\$out\" \
                       && grep -q 'functexcept.cc' <<< \"\$out\""
    fi
done

# ---------------------------------------------------------------- dbgsym
dbgsyms=()
for tc in "${GCCS[@]}" "${GDBS[@]}"; do load "$tc"; dbgsyms+=("$DEB_DBGSYM"); done
check "install all -dbgsym packages" apt_install "${dbgsyms[@]}"
if [ -n "$GDB" ]; then
    for tc in "${GCCS[@]}"; do
        load "$tc"
        check "$GDB finds cc1plus symbols in $PKG_NAME-dbgsym" \
              bash -c "$GDB -batch -ex 'info line toplev::main' \"\$($GCC -print-prog-name=cc1plus)\" | grep -q 'toplev.cc'"
        check "$GDB finds symbols of the prefix-independent binutils plugin" \
              bash -c "$GDB -batch -ex 'info line onload' $PREFIX/lib/bfd-plugins/libdep.so | grep -q 'libdep_plugin.c'"
        check "$GDB finds libstdc++ symbols in $PKG_NAME-dbgsym" \
              bash -c "$GDB -batch -ex 'info line std::__throw_bad_alloc' $PREFIX/lib64/libstdc++.so.6 | grep -q 'Line '"
    done
    check "$GDB finds its own symbols in its -dbgsym" \
          bash -c "$GDB -batch -ex 'info line main' $GDB_PREFIX/bin/gdb | grep -q 'gdb.c'"
fi

# ---------------------------------------------------------------- removal
pkgs=()
leftovers=()   # paths that must be gone afterwards
for tc in "${GCCS[@]}"; do
    load "$tc"; pkgs+=("$LIBDBG_PKG" "$PKG_NAME-dbgsym" "$PKG_NAME"); leftovers+=("$PREFIX")
done
for tc in "${GDBS[@]}"; do
    load "$tc"; pkgs+=("$PKG_NAME-dbgsym" "$PKG_NAME"); leftovers+=("$PREFIX")
done
leftovers+=(/usr/share/gdb/auto-load/opt)
check "all packages purge cleanly" \
      bash -c "apt-get purge -y -qq ${pkgs[*]} > /dev/null \
               && for p in ${leftovers[*]}; do [ ! -e \$p ] || { echo \"left: \$p\"; find \$p | head; exit 1; }; done \
               && [ -z \"\$(find /usr/lib/debug -type f 2>/dev/null)\" ]"
check "system libstdc++6 / libgcc still the distribution's" \
      bash -c "[ \"\$(dpkg-query -W -f '\${Package}=\${Version}\n' 'libstdc++6' 'libgcc-s1' 'libgcc1' 2>/dev/null | sort)\" = '$RUNTIME_BEFORE' ]"

echo "all $pass checks passed on $DIST_CODENAME (${GCCS[*]} ${GDBS[*]})"
