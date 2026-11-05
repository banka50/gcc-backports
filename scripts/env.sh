# Shared setup for the scripts that run inside the build container.
# Sourced, not executed. Needs DIST and TOOLCHAIN in the environment:
#
#   DIST       a directory under dists/       (buster, trixie, ...)
#   TOOLCHAIN  a file under toolchains/, without .env  (gcc-16, gdb-18, ...)

: "${DIST:?DIST must name a directory under dists/}"
: "${TOOLCHAIN:?TOOLCHAIN must name a file under toolchains/}"
. /src/repo/mirrors.env
. "/src/repo/dists/$DIST/dist.env"
. "/src/repo/toolchains/$TOOLCHAIN.env"
export SOURCE_DATE_EPOCH

JOBS=${JOBS:-$(nproc)}
# Not called MAINTAINER: GCC's and binutils' Makefiles have a variable of that
# name, and make would pick it up from the environment.
PKG_MAINTAINER=${PKG_MAINTAINER:-gcc-backports <gcc-backports@users.noreply.github.com>}
unset MAINTAINER
HOST_UID=${HOST_UID:-0}
HOST_GID=${HOST_GID:-0}

TRIPLET=x86_64-linux-gnu
MAJOR=${UPSTREAM_VERSION%%.*}
DEB_VERSION="$UPSTREAM_VERSION-$PKG_REVISION$DIST_SUFFIX"
DIST_PRETTY="$DIST_OS $DIST_VERSION ($DIST_CODENAME)"

# Fixed paths: they end up in a few places inside the binaries, so keeping
# them constant is part of making the build repeatable.
WORK=/build
LOGS=/out/logs
mkdir -p "$WORK" "$LOGS"
umask 022

finish() {
    local rc=$?
    if [ $rc -ne 0 ]; then
        # Keep config.log files of a failed build next to the step logs.
        find "$WORK" -name config.log 2>/dev/null | while read -r f; do
            cp "$f" "$LOGS/$(echo "${f#$WORK/}" | tr / _)" 2>/dev/null || true
        done
        echo "FAILED (exit $rc); logs are in out/$DIST/$TOOLCHAIN/logs/" >&2
    fi
    chown -R "$HOST_UID:$HOST_GID" /out || true
}

step() {  # step <name> <command...>: run a build step with its output logged
    local name=$1; shift
    echo "==> $(date -u +%H:%M:%S) $name" >&2
    # Our own settings stay out of the environment of configure and make,
    # which would otherwise see them as (Makefile) variables.
    if ! env -u DIST -u TOOLCHAIN -u KEEP_STAGE -u JOBS -u PKG_MAINTAINER \
             -u HOST_UID -u HOST_GID -u RUN_GCC_TESTSUITE \
             "$@" > "$LOGS/$name.log" 2>&1; then
        echo "--- last 40 lines of $LOGS/$name.log:" >&2
        tail -n 40 "$LOGS/$name.log" >&2
        return 1
    fi
}

# Header of the BUILDINFO file every toolchain writes.
buildinfo_header() {
    echo "$PKG_NAME $DEB_VERSION"
    echo
    echo "toolchain $TOOLCHAIN"
    echo "dist      $DIST_PRETTY"
    echo "image     $DIST_IMAGE"
    echo "prefix    $PREFIX"
    echo "apt:"
    grep -v '^#' "/src/repo/dists/$DIST/sources.list" | sed 's/^/  /'
}

buildinfo_footer() {
    echo "source checksums (sha256):"
    sed 's/^/  /' /src/repo/sources.sha256
    echo
    echo "build environment packages:"
    sed 's/^/  /' /build-env-packages.txt
}

# save_stage <paths...>: snapshot of the unstripped install, so packaging can
# be redone with `make repackage` without another build.
save_stage() {
    if [ "${KEEP_STAGE:-0}" = 1 ]; then
        mkdir -p /out/stage
        step stage-save tar -C / -cf /out/stage/install.tar "$@"
    fi
}
