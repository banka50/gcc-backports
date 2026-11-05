# Packaging helpers shared by package-gcc.sh and package-gdb.sh.
# Sourced after env.sh. The caller sets OBJCOPY, STRIP and READELF.

SHLIBS_DEPENDS=
PKG="$WORK/pkg"
rm -rf "$PKG"
mkdir -p "$PKG/debian"
# dpkg-shlibdeps insists on a debian/control in the current directory.
printf 'Source: %s\n\nPackage: %s\nArchitecture: amd64\n' "$PKG_NAME" "$PKG_NAME" > "$PKG/debian/control"
cd "$PKG"

elf_files() {  # elf_files <tree>: ELF executables and shared objects, sorted
    find "$1" -type f -print0 \
        | xargs -0 file -N -e text 2>/dev/null \
        | awk -F': ' '/ELF 64-bit LSB (pie executable|executable|shared object)/ {print $1}' \
        | LC_ALL=C sort
}

ar_files() {  # ar_files <tree>: static archives, sorted
    find "$1" -type f -name '*.a' | LC_ALL=C sort
}

# split_debug <tree> <dbgtree> <build-ids-out>
# Moves DWARF from every ELF in <tree> into <dbgtree>/usr/lib/debug/.build-id,
# strips the ELF and adds a .gnu_debuglink to it. Hard links are preserved.
# Static archives keep their symbols but lose DWARF, as in Debian.
split_debug() {
    local tree=$1 dbg=$2 idsfile=$3
    local -A first_of=()
    local -a relink=()
    local f ino id out pair
    : > "$idsfile"
    while read -r f; do
        ino=$(stat -c %i "$f")
        if [ -n "${first_of[$ino]:-}" ]; then
            relink+=("${first_of[$ino]}|$f")  # another name for an already handled file
            continue
        fi
        first_of[$ino]=$f
        id=$("$READELF" -n "$f" 2>/dev/null | awk '/Build ID:/ {print $3; exit}')
        out=
        if [ -n "$id" ]; then
            if grep -qaF -e "$PREFIX" -e "$PKG_NAME" "$f"; then
                # Mentions our prefix or package name (anything our GCC
                # compiled carries it in .comment; binutils in --version),
                # so its build-id is ours alone.
                out="$dbg/usr/lib/debug/.build-id/${id:0:2}/${id:2}.debug"
            else
                # Prefix-independent (e.g. binutils' bfd-plugins/libdep.so):
                # another toolchain can ship a byte-identical file with the
                # same build-id. Use the path-based location instead, which
                # gdb, perf and valgrind find through .gnu_debuglink.
                out="$dbg/usr/lib/debug${f#$tree}.debug"
            fi
            if [ ! -e "$out" ]; then
                mkdir -p "$(dirname "$out")"
                "$OBJCOPY" --only-keep-debug --compress-debug-sections=zlib "$f" "$out"
                if "$READELF" -S "$out" 2>/dev/null | grep -q '\.debug_info'; then
                    chmod 0644 "$out"
                    case "$out" in */.build-id/*) echo "$id" >> "$idsfile" ;; esac
                else
                    rm -f "$out"  # no DWARF in this file, nothing to ship
                fi
            fi
            [ -e "$out" ] || out=
        fi
        "$STRIP" --strip-unneeded --remove-section=.comment "$f"
        if [ -n "$out" ]; then
            "$OBJCOPY" --add-gnu-debuglink="$out" "$f"
        fi
    done < <(elf_files "$tree")

    # strip/objcopy rewrite files, which breaks hard links: restore them.
    for pair in "${relink[@]}"; do
        ln -f "${pair%%|*}" "${pair##*|}"
    done

    while read -r f; do
        "$STRIP" --strip-debug --enable-deterministic-archives "$f"
    done < <(ar_files "$tree")

    LC_ALL=C sort -o "$idsfile" "$idsfile"
}

subst() {  # subst <template>: fill @VARS@ in a control or copyright template
    sed -e "s|@PKG_NAME@|$PKG_NAME|g" \
        -e "s|@LIBDBG_PKG@|${LIBDBG_PKG:-}|g" \
        -e "s|@VERSION@|$DEB_VERSION|g" \
        -e "s|@MAJOR@|$MAJOR|g" \
        -e "s|@MAINTAINER@|$PKG_MAINTAINER|g" \
        -e "s|@SHLIBS_DEPENDS@|$SHLIBS_DEPENDS|g" \
        -e "s|@PREFIX@|$PREFIX|g" \
        -e "s|@PREFIX_REL@|${PREFIX#/}|g" \
        -e "s|@GCC_VERSION@|${GCC_VERSION:-}|g" \
        -e "s|@BINUTILS_VERSION@|${BINUTILS_VERSION:-}|g" \
        -e "s|@GDB_VERSION@|${GDB_VERSION:-}|g" \
        -e "s|@DIST_PRETTY@|$DIST_PRETTY|g" \
        "$1"
}

licence_files() {  # licence_files <tarball> <dir-in-tarball>: COPYING* extracted to a temp dir
    local d
    d=$(mktemp -d)
    tar -xJf "$1" -C "$d" --strip-components=1 --wildcards "$2/COPYING*"
    find "$d" -maxdepth 1 -name 'COPYING*' -type f | LC_ALL=C sort
}

# add_doc <tree> <pkgname> <copyright-template> <licence files...>
add_doc() {
    local tree=$1 name=$2 copyright=$3; shift 3
    local doc="$tree/usr/share/doc/$name"
    mkdir -p "$doc"
    subst "$copyright" > "$doc/copyright"
    for f in "$@"; do cp "$f" "$doc/"; done
    cp "$WORK/BUILDINFO" "$doc/BUILDINFO"
}

# link_doc <tree> <pkgname> <target-pkg>: /usr/share/doc/<pkg> -> <target-pkg>,
# for packages that strictly depend on the one holding the documentation.
link_doc() {
    mkdir -p "$1/usr/share/doc"
    ln -s "$3" "$1/usr/share/doc/$2"
}

# shlibs_depends <name> <tree>: Depends computed from the ELF files. Libraries
# that live inside the package's own prefix are provided by the package itself.
shlibs_depends() {
    local name=$1 tree=$2
    local -a elves
    mapfile -t elves < <(elf_files "$tree")
    [ ${#elves[@]} -gt 0 ] || return 0
    rm -f "$PKG/substvars.$name"
    step "shlibdeps-$name" dpkg-shlibdeps -T"$PKG/substvars.$name" \
        -l"$tree$PREFIX/lib64" -l"$tree$PREFIX/lib" \
        --ignore-missing-info "${elves[@]}"
    sed -n 's/^shlibs:Depends=//p' "$PKG/substvars.$name"
}

# add_pycache_cleanup <tree> <python-dir>: prerm that removes byte-code
# Python writes at run time (gdb loading pretty-printers), which dpkg does
# not own and would otherwise leave behind. Debian's py3clean does the same.
add_pycache_cleanup() {
    mkdir -p "$1/DEBIAN"
    cat > "$1/DEBIAN/prerm" <<EOF
#!/bin/sh
set -e
if [ -d "$2" ]; then
    find "$2" -depth -type d -name __pycache__ -exec rm -rf {} + || true
fi
EOF
    chmod 0755 "$1/DEBIAN/prerm"
}

# build_deb <tree> <control-file-content>
build_deb() {
    local tree=$1 control=$2 name version size deb
    name=$(sed -n 's/^Package: //p' <<< "$control")
    version=$(sed -n 's/^Version: //p' <<< "$control")
    mkdir -p "$tree/DEBIAN"
    printf '%s\n' "$control" | sed '/^Installed-Size:/d' > "$tree/DEBIAN/control"
    # Installed-Size goes right after Maintainer, like dpkg-gencontrol does.
    size=$(du -sk --apparent-size --exclude=DEBIAN "$tree" | cut -f1)
    sed -i "/^Maintainer:/a Installed-Size: $size" "$tree/DEBIAN/control"

    (cd "$tree" && find . -path ./DEBIAN -prune -o -type f -print0 \
        | LC_ALL=C sort -z | xargs -0 md5sum | sed 's|  \./|  |') > "$tree/DEBIAN/md5sums"

    # Normalise everything that would otherwise vary from build to build.
    find "$tree" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
    chmod -R u+rwX,go+rX,go-w "$tree"

    deb="/out/${name}_${version}_amd64.deb"
    step "dpkg-deb-$name" dpkg-deb --root-owner-group -Zxz -z9 --build "$tree" "$deb"
    dpkg-deb --info "$deb" > "$LOGS/$name.info.txt"
    dpkg-deb --contents "$deb" > "$LOGS/$name.contents.txt"
    echo "==> $(date -u +%H:%M:%S) built $(basename "$deb")" >&2
}

# build_dbgsym <for-package> <dbgtree> <build-ids-file>
build_dbgsym() {
    local name=$1 tree=$2 ids=$3
    link_doc "$tree" "$name-dbgsym" "$name"
    build_deb "$tree" "$(cat <<EOF
Package: $name-dbgsym
Version: $DEB_VERSION
Architecture: amd64
Maintainer: $PKG_MAINTAINER
Depends: $name (= $DEB_VERSION)
Section: debug
Priority: optional
Description: debug symbols for $name
 Detached DWARF debug information for the binaries in $name, installed under
 /usr/lib/debug/.build-id so gdb, perf and valgrind pick it up automatically.
Build-Ids: $(tr '\n' ' ' < "$ids" | sed 's/ $//')
EOF
)"
}

finish_packaging() {
    cp "$WORK/BUILDINFO" "/out/${PKG_NAME}_${DEB_VERSION}_amd64.buildinfo.txt"
    (cd /out && sha256sum ./*.deb | sed 's|  \./|  |' > SHA256SUMS)
    echo "==> $(date -u +%H:%M:%S) done" >&2
}
