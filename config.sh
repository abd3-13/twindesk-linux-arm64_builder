# shellcheck shell=bash
# Central configuration for the TwinDesk arm64 builder.
#
# Every value can be overridden from the environment, for example:
#   TWINDESK_VERSION=2.6.0 bash scripts/run-all.sh
#   SUITE=bookworm bash scripts/00-prep.sh
#
# When bumping TwinDesk, update TWINDESK_VERSION/TWINDESK_TAG and check that
# patches/arm64.patch still applies to the new linux/installer/build.js.

: "${TWINDESK_VERSION:=2.5.3}"
: "${TWINDESK_TAG:=v${TWINDESK_VERSION}}"
: "${TWINDESK_REPO:=https://github.com/InukaAsith/TwinDesk.git}"
: "${DEB_ARCH:=arm64}"

# Build chroot (Debian release + mirror).
: "${SUITE:=bullseye}"
: "${MIRROR:=http://deb.debian.org/debian}"

# Toolchain installed inside the chroot.
# Electron 44 declares node >= 22.12.0, so Node 22 LTS is required.
: "${NODE_VER:=v22.23.4}"
: "${RUST_VER:=1.99.1}"

# Build tuning.
: "${CARGO_BUILD_JOBS:=4}"
: "${NODE_HEAP_MB:=1536}"

export TWINDESK_VERSION TWINDESK_TAG TWINDESK_REPO DEB_ARCH
export SUITE MIRROR NODE_VER RUST_VER CARGO_BUILD_JOBS NODE_HEAP_MB
