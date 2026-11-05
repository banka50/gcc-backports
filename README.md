# gcc-backports

Reproducible backports of current GCC toolchains and GDB to older Linux
distributions, packaged as `.deb`s that install into private prefixes:

| Toolchain | Contents | Prefix |
|---|---|---|
| `gcc-16` | GCC 16.2.0 (C, C++, Fortran, LTO) + GNU binutils 2.47 | `/opt/gcc-16` |
| `gcc-15` | GCC 15.3.0 (C, C++, Fortran, LTO) + GNU binutils 2.47 | `/opt/gcc-15` |
| `gdb-18` | GDB 18.1 + gdbserver | `/opt/gdb-18` |

Each toolchain also comes with a separate debug-symbol package. Every GCC
lives in its own prefix with its own runtime, so several versions can be
installed side by side. Nothing replaces the distribution's system compiler,
`libstdc++6`, `libgcc` or `gdb`, so the packages are safe on a production
host, and the host keeps receiving its normal updates.

## Supported distributions

| `DIST` | Distribution | Package version suffix | apt sources used for the build |
|---|---|---|---|
| `buster` | Debian 10 | `~deb10u1` | `archive.debian.org` (frozen, EOL) |
| `trixie` | Debian 13 | `~deb13u1` | `snapshot.debian.org`, 2026-11-04 |

To add a distribution, create `dists/<codename>/dist.env` and
`dists/<codename>/sources.list` (see the existing ones). To add a toolchain,
create `toolchains/<name>.env`. Then add either to the CI matrix.

## Packages

Shown with the trixie version suffix; buster uses `~deb10u1`.

| Package | Version | Contents |
|---|---|---|
| `gcc-16-opt` | 16.2.0-1~deb13u1 | GCC, runtime libraries, sanitizers, `libstdc++_pic.a`, binutils. In `/opt/gcc-16/bin`: `gcc`, `g++`, `gfortran`, `cpp`, ... |
| `gcc-16-opt-libstdc++-dbg` | 16.2.0-1~deb13u1 | A second libstdc++ built with `-g3 -O0 -D_GLIBCXX_ASSERTIONS`, unstripped, in `/opt/gcc-16/lib64/debug` (like Debian's `libstdc++6-N-dbg`) |
| `gcc-16-opt-dbgsym` | 16.2.0-1~deb13u1 | Debug info for everything in `gcc-16-opt` |
| `gcc-15-opt`, `-libstdc++-dbg`, `-dbgsym` | 15.3.0-1~deb13u1 | The same for GCC 15. In `/opt/gcc-15/bin`. |
| `gdb-18-opt` | 18.1-1~deb13u1 | GDB with Python, TUI and gdbserver. In `/opt/gdb-18/bin`: `gdb`, `gdbserver`, `gcore`, `gdb-add-index` |
| `gdb-18-opt-dbgsym` | 18.1-1~deb13u1 | Debug info for `gdb-18-opt` |

The `-dbgsym` packages work like Debian's own. Binaries are stripped and carry a
build-id; their DWARF lives in `/usr/lib/debug/.build-id/xx/yyyy.debug`.
gdb, perf and valgrind find it there automatically.

## Why a private prefix instead of replacing the system runtime?

Debian's own `gcc-N` packages, and backports built from them, ship
`libstdc++6` and `libgcc-s1`. Installing them replaces the runtime every C++
process on the host uses, `apt` included. On a stable release that means:

- **No more updates for the runtime.** Security and point-release updates for
  it stop arriving, because the distribution's versions are lower.
- **Builds stop running on stock hosts.** Binaries and `.deb`s built on the
  host start requiring the newer `GLIBCXX_*` symbol versions and fail there.
  `clang++` picks up the newest GCC headers too.
- **Rolling back is hard.** Downgrading the runtime means removing everything
  that depends on the new version first.

Here the runtime stays in `/opt/gcc-16/lib64`, and programs opt in to it
(see below). On older releases there is another reason too: packages built for
newer distributions don't run at all. Buster, for example, has glibc 2.28,
binutils 2.31 and gdb 8.2. These packages are built on each distribution
itself instead.

## How it is built

GCC is built with `make profiledbootstrap` and `--with-build-config=bootstrap-lto-lean`,
the same scheme Debian and Ubuntu use for their own gcc packages:

1. **stage1**: the distribution's gcc builds an unoptimised new GCC.
2. **stageprofile**: that GCC builds an instrumented copy of itself.
3. **stagetrain**: the instrumented compiler builds GCC's own sources to collect a profile.
4. **stagefeedback**: the new GCC builds itself again, optimised with that profile (PGO) and LTO.

Everything GCC installs comes from the final stage. That covers the compiler
binaries and all runtime libraries (`libstdc++`, `libgfortran`, `libgomp`, ...).
GMP, MPFR, MPC and ISL are built in-tree and linked statically into `cc1` & co.
PGO and LTO make the compiler itself faster; they don't change the code it
generates. Each GCC toolchain carries its own binutils, built first by the
distribution's gcc. They are needed for AVX10/APX on older distributions and
keep behaviour identical everywhere.

GDB is a toolchain of its own and is built by the distribution's compiler, so
it depends on no `gcc-N-opt` package and needs only the distribution's
libraries at run time. It looks for separate debug info in `/usr/lib/debug`
and auto-loads scripts from `/usr/share/gdb/auto-load`. That is where every
`gcc-N-opt` puts its libstdc++ pretty-printer hook, keyed by its own
prefix, so they never collide. The distribution's gdb finds them there too.

## Installing

Pick the toolchains you need; they can all be installed together:

```bash
sudo apt install ./gcc-16-opt_16.2.0-1~deb13u1_amd64.deb ./gcc-15-opt_15.3.0-1~deb13u1_amd64.deb \
                 ./gdb-18-opt_18.1-1~deb13u1_amd64.deb
# optional, only where you need them:
sudo apt install ./gcc-16-opt-dbgsym_*.deb ./gcc-16-opt-libstdc++-dbg_*.deb ./gdb-18-opt-dbgsym_*.deb
```

The packages put nothing into `/usr/bin`. Names like `gcc-15` belong to the
distribution's own `gcc-N` packages (from backports, testing or third-party
repositories), and dpkg refuses to install two packages owning the same
file. The tools live only in `/opt/gcc-16/bin`, `/opt/gcc-15/bin` and
`/opt/gdb-18/bin`.

### Choosing a compiler

The most explicit way is the full path:

```bash
CC=/opt/gcc-16/bin/gcc CXX=/opt/gcc-16/bin/g++ cmake ..
# or, for a shell session:
export PATH=/opt/gcc-16/bin:$PATH
```

To make the plain `gcc`/`g++` names point at one of them, use
`update-alternatives` with links in `/usr/local/bin`. It comes before `/usr/bin` in
`PATH` and belongs to no package:

```bash
for v in 15 16; do
  sudo update-alternatives --install /usr/local/bin/gcc gcc /opt/gcc-$v/bin/gcc ${v}0 \
      --slave /usr/local/bin/g++      g++      /opt/gcc-$v/bin/g++ \
      --slave /usr/local/bin/cpp      cpp      /opt/gcc-$v/bin/cpp \
      --slave /usr/local/bin/gfortran gfortran /opt/gcc-$v/bin/gfortran \
      --slave /usr/local/bin/gcov     gcov     /opt/gcc-$v/bin/gcov
done
sudo update-alternatives --config gcc
```

Don't point `/usr/bin/gcc` at them. That symlink belongs to the
distribution's `gcc` package, which restores it on its next upgrade. DKMS and
kernel module builds also expect the compiler the kernel was built with.

### Running the programs you build

Programs built with GCC N need GCC N's runtime libraries (`libstdc++.so.6`,
`libgfortran.so.5`, ...), which are newer than the system's. Pick one of these:

```bash
# 1. Link the C++ runtime statically (simplest to deploy).
/opt/gcc-16/bin/g++ -O2 -static-libstdc++ -static-libgcc main.cpp -o app

# 2. Use the runtime from /opt/gcc-16 on the build machine.
/opt/gcc-16/bin/g++ -O2 -Wl,-rpath,/opt/gcc-16/lib64 main.cpp -o app
```

Plain C programs that don't use OpenMP or sanitizers need neither option.

### Stepping through the standard library

`gcc-N-opt-libstdc++-dbg` provides an unoptimised libstdc++ with full debug
info and `_GLIBCXX_ASSERTIONS` enabled. Point a program at it at run time;
no recompilation is needed:

```bash
LD_LIBRARY_PATH=/opt/gcc-16/lib64/debug /opt/gdb-18/bin/gdb ./app
# or bake it in for a debug build:
/opt/gcc-16/bin/g++ -g -O0 app.cpp -Wl,-rpath,/opt/gcc-16/lib64/debug -o app
```

This is different from `gcc-N-opt-dbgsym`, which carries the debug info for
the regular optimised `libstdc++`.

### Linking libstdc++ into a shared library

`libstdc++_pic.a` (in `$(/opt/gcc-16/bin/g++ -print-file-name=libstdc++_pic.a)`, like Debian's
`libstdc++-N-pic`) holds libstdc++'s position-independent objects. With it, a
`.so` can carry its own copy of the new C++ runtime and load on hosts with
the stock runtime. `libstdc++_pic.map` next to it is libstdc++'s symbol version script.

```bash
/opt/gcc-16/bin/g++ -O2 -fPIC -shared foo.cpp -o libfoo.so \
    -nostdlib++ "$(/opt/gcc-16/bin/g++ -print-file-name=libstdc++_pic.a)" -lm \
    -static-libgcc -Wl,--exclude-libs,ALL
```

## Building

You need Docker, GNU make, curl and about 25 GB of free disk space per GCC build.

```bash
make list                                 # supported distributions and toolchains
make DIST=trixie TOOLCHAIN=gcc-16         # one toolchain for one distribution
make DIST=trixie world                    # every toolchain for trixie
make DIST=trixie test                     # install everything built for trixie side by side
                                          # into a clean debian:13 container and smoke-test it
```

Each build goes to `out/<dist>/<toolchain>/`:

- the toolchain's `.deb`s
- `<package>_<version>_amd64.buildinfo.txt`: versions, configure flags, apt
  sources, source hashes, build environment
- `SHA256SUMS`
- `logs/`: one log per build step, plus `dpkg-deb --info/--contents` of every package

On a 28-core machine a GCC build takes 28–33 minutes, of which 24–29 go to
the bootstrap; expect several hours on 4 cores. GDB takes about 3 minutes.
Package sizes (similar on both distributions):

| | `gcc-16-opt` | `gcc-15-opt` | `gdb-18-opt` |
|---|---|---|---|
| main package | 68 MB | 60 MB | 5 MB |
| `-libstdc++-dbg` | 18 MB | 16 MB | – |
| `-dbgsym` | 767 MB | 698 MB | 86–117 MB |

Useful knobs:

- `JOBS=<n>`: number of parallel build jobs.
- `MAINTAINER="Name <mail>"`: the package maintainer field.
- `KEEP_STAGE=1`: also keeps the unstripped install in `out/<dist>/<toolchain>/stage/`.
  Then `make DIST=<dist> TOOLCHAIN=<toolchain> repackage` redoes only the
  packaging step, in a few minutes instead of a full build.

## What makes it reproducible

- **Pinned inputs.** Every toolchain's versions are in `toolchains/<name>.env`, and every upstream
  tarball is checked against [`sources.sha256`](sources.sha256) before use. Those hashes
  were taken from tarballs whose GNU GPG signatures were verified. You can
  re-check the signatures with `scripts/fetch-sources.sh --verify-gpg`.
  GMP/MPFR/MPC/ISL also match the SHA-512 list shipped in GCC's own
  `contrib/prerequisites.sha512`.
- **Pinned build environment.** Each distribution's base image is referenced by
  digest in `dists/<codename>/dist.env`. apt uses frozen sources:
  `archive.debian.org` for EOL releases, a `snapshot.debian.org` timestamp
  for live ones. The exact package set of the build container is recorded in
  the buildinfo file.
- **Fixed paths and timestamps.** The build always runs in `/build` inside the container
  and installs to the toolchain's fixed prefix. Every file in the `.deb`s gets the
  toolchain's `SOURCE_DATE_EPOCH` mtime (its upstream release date), owners are
  root:root, and static archives are created and stripped in binutils'
  deterministic mode.

Packaging the same install twice (`make repackage`) gives bit-identical `.deb`s.
Two complete builds from scratch have not been systematically compared yet.
Data points so far: across two independent full trixie builds of `gcc-16`,
`gcc-16-opt-libstdc++-dbg` (built at `-O0`, without PGO) came out
bit-identical, while the PGO + LTO compiler binaries did not. Profile
collection and LTO partitioning are the likely sources of the difference.

## Layout

```
toolchains/<name>.env           versions, package name, prefix of one toolchain
mirrors.env                     upstream download locations
sources.sha256                  pinned hashes of all upstream tarballs
dists/<codename>/dist.env       base image digest, version suffix, names
dists/<codename>/sources.list   frozen apt sources for the build and the tests
scripts/fetch-sources.sh        download + verify (optionally GPG)
docker/Dockerfile               build environment, one image per distribution
docker/setup-apt.sh             installs the frozen apt sources into a container
scripts/env.sh                  shared setup for the in-container scripts
scripts/build-gcc.sh            binutils → GCC profiled bootstrap
scripts/build-gdb.sh            GDB with the distribution's compiler
scripts/package-lib.sh          debug-info split, strip, .deb helpers
scripts/package-gcc.sh          gcc-N-opt, -libstdc++-dbg, -dbgsym
scripts/package-gdb.sh          gdb-N-opt, -dbgsym
debian/templates/               control and copyright templates
tests/                          smoke tests run by `make test`
.github/workflows/build.yml     CI: build dist × toolchain, test per dist, attach .debs to v* releases
```

## Updating or adding a toolchain

1. Edit `toolchains/<name>.env`, or copy one for a new major version (new
   `PKG_NAME` and `PREFIX`). For GCC, take the GMP/MPFR/MPC/ISL versions from
   its `contrib/download_prerequisites`. Set `SOURCE_DATE_EPOCH` to the
   release date.
2. Run `scripts/fetch-sources.sh --verify-gpg <name>`. It downloads the new
   tarballs and checks their GPG signatures first. The hash check that
   follows fails for tarballs not yet in `sources.sha256`. Once the
   signatures are good, add their `sha256sum` lines.
3. Bump `PKG_REVISION` if only the packaging changed.

To move a live distribution to newer packages, bump the snapshot timestamp in
its `sources.list` (and the image digest in `dist.env`), then rebuild.

## Licence

The build scripts, templates and tests in this repository are MIT-licensed; see
[`LICENSE`](LICENSE).

The packages they produce contain GCC, binutils and GDB, which are
GPL-3.0-or-later; GCC's runtime libraries carry the GCC Runtime Library
Exception. See `/usr/share/doc/<package>/copyright` in each package.
