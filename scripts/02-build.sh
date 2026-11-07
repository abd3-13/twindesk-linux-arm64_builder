#!/bin/bash
# TwinDesk arm64 — Stage 2: build the .deb inside the chroot.
#
# What it does:
#   1. re-creates the chroot bind mounts if needed;
#   2. applies patches/arm64.patch to the source (idempotent);
#   3. copies the source into <chroot>/build (keeps node_modules from earlier runs);
#   4. runs `npm install` and `npm run dist` as root inside the chroot;
#   5. copies the produced .deb back to the workspace.
#
# Re-runnable and resumable: npm/cargo caches and node_modules survive in the
# chroot, so a retry after a network or OOM failure does not start from zero.
#
# Usage:  bash 02-build.sh
# Tunables (environment):
#   CARGO_BUILD_JOBS=4          parallel Rust/C compile jobs
#   NODE_HEAP_MB=1536           Node.js old-space limit
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../config.sh
. "$ROOT/config.sh"
REPO="$ROOT/repo"
C="$ROOT/chroot"
PATCH="$ROOT/patches/arm64.patch"
JOBS=$CARGO_BUILD_JOBS
HEAP=$NODE_HEAP_MB
EXPECTED_DEB="TwinDesk-${TWINDESK_VERSION}-${DEB_ARCH}.deb"

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -d "$REPO/.git" ] || die "source missing; run 00-fetch.sh first"
[ -x "$C/usr/bin/apt-get" ] || die "chroot missing; run 00-prep.sh first"
[ -x "$C/usr/local/bin/node" ] || die "Node.js missing; run 01-toolchain.sh first"
# /root is mode 700 in the chroot, so this test must run as root.
sudo test -x "$C/root/.cargo/bin/cargo" || die "Rust missing; run 01-toolchain.sh first"

# --- mounts ----------------------------------------------------------------
for m in proc sys dev; do
  mountpoint -q "$C/$m" || sudo mount --bind "/$m" "$C/$m"
done
mountpoint -q "$C/dev/pts" || sudo mount --bind /dev/pts "$C/dev/pts"
sudo cp -L /etc/resolv.conf "$C/etc/resolv.conf"

# --- arm64 patch (idempotent) ---------------------------------------------
say "Checking the arm64 patch"
cd "$REPO"
if git apply --reverse --check "$PATCH" 2>/dev/null; then
  say "Patch already applied"
else
  git apply --check "$PATCH" || die "patch does not apply cleanly (source changed?); inspect $PATCH"
  git apply "$PATCH"
  say "Applied $PATCH"
fi
git --no-pager diff --stat -- linux/installer/build.js

# --- source into chroot ----------------------------------------------------
say "Copying source into $C/build"
sudo mkdir -p "$C/build"
# cp -a overlays the source; node_modules/target already inside the chroot are kept.
sudo cp -a "$REPO/." "$C/build/"

# The helper build uses these; make the cache/target paths explicit.
INNER_ENV='
  export HOME=/root
  export PATH=/root/.cargo/bin:/usr/local/bin:/usr/bin:/bin
  # Force electron-builder to use the apt/gem fpm; its auto-downloaded fpm
  # can be an x86-64 binary on arm64 and then fails while packaging the .deb.
  export USE_SYSTEM_FPM=true
  export CARGO_BUILD_JOBS='"$JOBS"'
  export CARGO_HOME=/root/.cargo
  export RUSTUP_HOME=/root/.rustup
  export NODE_OPTIONS=--max-old-space-size='"$HEAP"'
  export DEBIAN_FRONTEND=noninteractive
'

# --- npm install -----------------------------------------------------------
# The registry link drops connections occasionally; retry the whole install a
# few times. npm's own fetch retries (set in 01-toolchain.sh) handle the rest.
NPM_FLAGS="--unsafe-perm --no-audit --no-fund --foreground-scripts --loglevel=info \
  --fetch-retries=10 --fetch-retry-mintimeout=20000 --fetch-retry-maxtimeout=180000 \
  --fetch-timeout=900000 --maxsockets=4"
INSTALLED=0
for attempt in 1 2 3 4; do
  say "npm install (attempt $attempt/4; downloads Electron ~119 MB and electron-builder tooling)"
  if sudo chroot "$C" /bin/bash -lc "$INNER_ENV
    cd /build/linux
    npm install $NPM_FLAGS
  "; then
    INSTALLED=1
    break
  fi
  say "npm install failed on attempt $attempt — retrying in 15 s (cache is kept)"
  sleep 15
done
[ "$INSTALLED" = "1" ] || die "npm install failed after 4 attempts"

# --- build -----------------------------------------------------------------
# electron-builder downloads its own tooling (app-builder, fpm, Electron) on
# first use; retry a couple of times on a lossy connection.
# Remove a half-extracted app dir from an interrupted run: electron-builder
# then fails with ENOENT renaming electron -> twindesk.
say "Removing stale electron-builder output"
sudo rm -rf "$C/build/linux/dist/linux-arm64-unpacked"
BUILT=0
for attempt in 1 2 3; do
  say "npm run dist (attempt $attempt/3; helper + Rust lane + electron-builder -> .deb)"
  if sudo chroot "$C" /bin/bash -lc "$INNER_ENV
    cd /build/linux
    npm run dist
  "; then
    BUILT=1
    break
  fi
  say "npm run dist failed on attempt $attempt — retrying in 20 s (caches are kept)"
  sleep 20
done
[ "$BUILT" = "1" ] || die "npm run dist failed after 3 attempts"

# --- collect artifact ------------------------------------------------------
mapfile -t DEBS < <(find "$C/build/linux/dist" -maxdepth 1 -type f -name '*.deb' 2>/dev/null | sort)
[ "${#DEBS[@]}" -gt 0 ] || die "no .deb produced in $C/build/linux/dist"
DEB="${DEBS[-1]}"
BASE="$(basename "$DEB")"

say "Copying $BASE back to $ROOT"
sudo cp -f "$DEB" "$ROOT/$BASE"
sudo chown "$(id -u):$(id -g)" "$ROOT/$BASE"
ls -lh "$ROOT/$BASE"

if [ "$BASE" != "$EXPECTED_DEB" ]; then
  printf 'NOTE: artifact name is %s (expected %s)\n' "$BASE" "$EXPECTED_DEB" >&2
fi

sha256sum "$ROOT/$BASE"

say "Stage 2 complete: $ROOT/$BASE"
