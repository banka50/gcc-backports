# Reproducible backports of GCC (with binutils) and GDB to older
# distributions, packaged as .debs that install into private prefixes.
#
# A build is one toolchain (toolchains/<name>.env) for one distribution
# (dists/<codename>/):
#
#   make DIST=trixie TOOLCHAIN=gcc-16        build the .debs into out/trixie/gcc-16/
#   make DIST=trixie world                   build every toolchain for trixie
#   make DIST=trixie test                    install everything built for trixie into a
#                                            clean container, side by side, and smoke-test it
#   make DIST=trixie TOOLCHAIN=gcc-16 clean  remove out/trixie/gcc-16/
#   make list                                supported distributions and toolchains
#   make fetch                               download + verify all upstream sources
#   make distclean                           remove out/, sources/ and the builder images
#
#   KEEP_STAGE=1          also keep the unstripped install in out/<dist>/<toolchain>/stage/
#   make ... repackage    redo only the packaging step from that snapshot
#
# Knobs: JOBS=<n> (default: all CPUs), MAINTAINER="Name <mail>".

include mirrors.env

SHELL       := /bin/bash
DISTS       := $(notdir $(wildcard dists/*))
TOOLCHAINS  := $(basename $(notdir $(wildcard toolchains/*.env)))
JOBS        ?= $(shell nproc)
MAINTAINER  ?= gcc-backports <gcc-backports@users.noreply.github.com>
KEEP_STAGE  ?= 0

ifdef DIST
  ifeq ($(filter $(DIST),$(DISTS)),)
    $(error unknown DIST=$(DIST); supported: $(DISTS))
  endif
  include dists/$(DIST)/dist.env
endif
ifdef TOOLCHAIN
  ifeq ($(filter $(TOOLCHAIN),$(TOOLCHAINS)),)
    $(error unknown TOOLCHAIN=$(TOOLCHAIN); supported: $(TOOLCHAINS))
  endif
  include toolchains/$(TOOLCHAIN).env
endif

OUT     := out/$(DIST)/$(TOOLCHAIN)
BUILDER := gcc-backports-builder:$(DIST)

DOCKER_BUILD_RUN = docker run --rm \
	    -v "$(CURDIR):/src/repo:ro" \
	    -v "$(CURDIR)/sources:/src/sources:ro" \
	    -v "$(CURDIR)/$(OUT):/out" \
	    -e DIST=$(DIST) -e TOOLCHAIN=$(TOOLCHAIN) \
	    -e JOBS=$(JOBS) \
	    -e PKG_MAINTAINER="$(MAINTAINER)" \
	    -e KEEP_STAGE=$(KEEP_STAGE) \
	    -e HOST_UID=$$(id -u) -e HOST_GID=$$(id -g) \
	    $(BUILDER)

.PHONY: all list need-dist need-toolchain fetch image deb world repackage test clean distclean

all: deb

list:
	@echo "dists:      $(DISTS)"
	@echo "toolchains: $(TOOLCHAINS)"

need-dist:
	@test -n "$(DIST)" || { echo "set DIST to one of: $(DISTS)" >&2; exit 1; }

need-toolchain: need-dist
	@test -n "$(TOOLCHAIN)" || { echo "set TOOLCHAIN to one of: $(TOOLCHAINS)" >&2; exit 1; }

fetch:
	scripts/fetch-sources.sh $(TOOLCHAIN)

image: need-dist
	docker build \
	    --build-arg DIST=$(DIST) \
	    --build-arg DIST_IMAGE=$(DIST_IMAGE) \
	    -f docker/Dockerfile -t $(BUILDER) .

deb: need-toolchain fetch image clean
	mkdir -p $(OUT)
	$(DOCKER_BUILD_RUN) bash /src/repo/scripts/build-$(KIND).sh
	@cat $(OUT)/SHA256SUMS

world: need-dist
	set -e; for t in $(TOOLCHAINS); do $(MAKE) DIST=$(DIST) TOOLCHAIN=$$t deb; done

repackage: need-toolchain image
	test -f $(OUT)/stage/install.tar || { echo "no $(OUT)/stage/install.tar; build with KEEP_STAGE=1" >&2; exit 1; }
	$(DOCKER_BUILD_RUN) bash -c 'tar -C / -xf /out/stage/install.tar && exec bash /src/repo/scripts/package-$(KIND).sh'
	@cat $(OUT)/SHA256SUMS

# Installs every toolchain that has been built for DIST, all at once.
test: need-dist
	@ls out/$(DIST)/*/*.deb > /dev/null 2>&1 || { echo "nothing built in out/$(DIST)/; run 'make DIST=$(DIST) world' first" >&2; exit 1; }
	docker run --rm --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
	    -v "$(CURDIR):/src/repo:ro" \
	    -v "$(CURDIR)/out/$(DIST):/out:ro" \
	    -e DIST=$(DIST) \
	    $(DIST_IMAGE) bash /src/repo/tests/run-tests.sh

# Removed through a container: a build that was killed hard leaves root-owned files.
clean: need-toolchain
	if [ -d $(OUT) ]; then docker run --rm -v "$(CURDIR)/out:/w" $(DIST_IMAGE) rm -rf /w/$(DIST)/$(TOOLCHAIN); fi

distclean:
	if [ -d out ]; then docker run --rm -v "$(CURDIR):/w" debian:stable-slim rm -rf /w/out; fi
	rm -rf sources
	-for d in $(DISTS); do docker rmi gcc-backports-builder:$$d; done
