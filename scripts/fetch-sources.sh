#!/bin/bash
# Download the upstream tarballs of every toolchain in toolchains/ (or only
# the ones named) into sources/ and verify them against the pinned SHA-256
# list in sources.sha256. Any mismatch fails the script, so a build never
# starts from unverified input.
#
#   scripts/fetch-sources.sh [--verify-gpg] [toolchain...]
#
# --verify-gpg first checks the upstream GPG signatures of GCC, binutils and
# GDB against the GNU keyring (this is how the pinned hashes were obtained),
# so it can be used to vet new tarballs before their hashes go into
# sources.sha256.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/mirrors.env"

VERIFY_GPG=0
if [ "${1:-}" = "--verify-gpg" ]; then VERIFY_GPG=1; shift; fi
if [ $# -eq 0 ]; then
    set -- $(cd "$ROOT/toolchains" && ls *.env | sed 's/\.env$//')
fi

SRC="$ROOT/sources"
mkdir -p "$SRC"
cd "$SRC"

fetch() {  # fetch <url>
    local f
    f=$(basename "$1")
    if [ -s "$f" ]; then
        echo "have   $f"
    else
        echo "fetch  $1"
        curl -fL --retry 5 --retry-delay 5 -o "$f.part" "$1"
        mv "$f.part" "$f"
    fi
}

declare -a urls=() signed=()
for tc in "$@"; do
    [ -f "$ROOT/toolchains/$tc.env" ] || { echo "error: no toolchains/$tc.env" >&2; exit 1; }
    (
        . "$ROOT/toolchains/$tc.env"
        case "$KIND" in
            gcc)
                echo "S $GNU_MIRROR/gcc/gcc-$GCC_VERSION/gcc-$GCC_VERSION.tar.xz"
                echo "S $GNU_MIRROR/binutils/binutils-$BINUTILS_VERSION.tar.xz"
                echo "U $GCC_INFRA_MIRROR/gmp-$GMP_VERSION.tar.bz2"
                echo "U $GCC_INFRA_MIRROR/mpfr-$MPFR_VERSION.tar.bz2"
                echo "U $GCC_INFRA_MIRROR/mpc-$MPC_VERSION.tar.gz"
                echo "U $GCC_INFRA_MIRROR/isl-$ISL_VERSION.tar.bz2"
                ;;
            gdb)
                echo "S $GNU_MIRROR/gdb/gdb-$GDB_VERSION.tar.xz"
                ;;
            *) echo "error: $tc: unknown KIND=$KIND" >&2; exit 1 ;;
        esac
    ) > "$SRC/.urls.$tc"
    while read -r kind url; do
        urls+=("$url")
        [ "$kind" = S ] && signed+=("$url")
    done < "$SRC/.urls.$tc"
    rm -f "$SRC/.urls.$tc"
done

mapfile -t urls < <(printf '%s\n' "${urls[@]}" | sort -u)
for u in "${urls[@]}"; do fetch "$u"; done

if [ "$VERIFY_GPG" = 1 ]; then
    fetch "$GNU_MIRROR/gnu-keyring.gpg"
    mapfile -t signed < <(printf '%s\n' "${signed[@]}" | sort -u)
    for u in "${signed[@]}"; do
        fetch "$u.sig"
        gpgv --keyring ./gnu-keyring.gpg "$(basename "$u").sig" "$(basename "$u")"
    done
fi

# Every tarball we need must be listed and match. Entries for tarballs of
# other toolchains are checked only if those files are present.
fail=0
for u in "${urls[@]}"; do
    f=$(basename "$u")
    line=$(awk -v f="$f" '$2 == f' "$ROOT/sources.sha256")
    if [ -z "$line" ]; then
        echo "$f: not listed in sources.sha256" >&2; fail=1; continue
    fi
    echo "$line" | sha256sum -c - || fail=1
done
if [ "$fail" != 0 ]; then
    echo "error: checksum mismatch or missing entry in sources.sha256; refusing to build" >&2
    exit 1
fi
