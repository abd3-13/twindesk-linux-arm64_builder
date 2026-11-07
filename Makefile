# TwinDesk arm64 builder — convenience targets.
#
# The scripts are the source of truth; these targets only call them.
SHELL := /bin/bash
.DEFAULT_GOAL := help

# Generated state lives in WORKSPACE (repository root by default, or the
# parent directory when the clone sits inside an existing build workspace).
# Override on the command line: make WORKSPACE=/srv/twindesk all
WORKSPACE ?= $(shell bash -c '. ./config.sh && printf "%s" "$$WORKSPACE"')
export WORKSPACE

.PHONY: help all fetch prep toolchain build verify clean distclean lint

help:
	@printf '%s\n' \
	  'TwinDesk arm64 builder' \
	  '' \
	  'Targets:' \
	  '  make all        fetch + prep + toolchain + build + verify' \
	  '  make fetch      clone the TwinDesk source into repo/' \
	  '  make prep       create swap + Debian arm64 chroot + toolchain' \
	  '  make toolchain  install Node.js, Rust and fpm inside the chroot' \
	  '  make build      patch, npm install, npm run dist, collect the .deb' \
	  '  make verify     inspect the produced .deb' \
	  '  make lint       bash -n every script' \
	  '  make clean      unmount and delete chroot + swap (keeps the .deb)' \
	  '  make distclean  clean, then remove repo/, build.log and .verify/' \
	  '' \
	  'Configuration lives in config.sh; every value can be overridden:' \
	  '  TWINDESK_VERSION=2.6.0 make all' \
	  '  SUITE=bookworm make prep'

all: fetch prep toolchain build verify

fetch:
	bash scripts/00-fetch.sh

prep:
	bash scripts/00-prep.sh

toolchain:
	bash scripts/01-toolchain.sh

build:
	bash scripts/02-build.sh

verify:
	bash scripts/03-verify.sh

lint:
	@for f in scripts/*.sh config.sh; do bash -n "$$f" && echo "OK $$f"; done

clean:
	bash scripts/99-cleanup.sh

distclean: clean
	rm -rf $(WORKSPACE)/repo $(WORKSPACE)/.verify $(WORKSPACE)/build.log
