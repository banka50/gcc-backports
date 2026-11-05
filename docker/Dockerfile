# check=skip=InvalidDefaultArgInFrom
# Build environment: a pristine distribution image plus the packages GCC,
# binutils and GDB need to build. The base image is pinned by digest and the
# apt sources are frozen (see dists/<codename>/), so this image comes out
# the same every time it is built.
#
# DIST_IMAGE deliberately has no default: the Makefile always passes the
# digest from dists/<codename>/dist.env, and a fallback image would let a
# bare `docker build` succeed on the wrong base. Hence the check skipped above.
ARG DIST_IMAGE
FROM ${DIST_IMAGE}

ARG DIST
COPY docker/setup-apt.sh /usr/local/sbin/setup-apt.sh
COPY dists/${DIST}/sources.list /etc/gcc-backports/sources.list
RUN sh /usr/local/sbin/setup-apt.sh /etc/gcc-backports/sources.list \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential \
        bzip2 \
        xz-utils \
        file \
        flex \
        bison \
        m4 \
        perl \
        python3 \
        texinfo \
        zlib1g-dev \
        dpkg-dev \
        pkg-config \
        python3-dev \
        libexpat1-dev \
        liblzma-dev \
        libncurses-dev \
        libgmp-dev \
        libmpfr-dev \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* \
 && dpkg-query -W -f '${Package}=${Version}\n' | sort > /build-env-packages.txt

ENV LC_ALL=C.UTF-8 \
    TZ=UTC
