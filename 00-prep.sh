#!/bin/bash
# TwinDesk arm64 — Stage 0: temporary swap + Debian 11 arm64 chroot + build toolchain.
#
# Nothing is installed on the host. The only host changes are:
#   * <workspace>/chroot         (a directory, deleted by 99-cleanup.sh)
#   * <workspace>/build.swap     (a 4 GB swap file, removed by 99-cleanup.sh)
#
# Re-runnable and resumable:
#   * an existing chroot is reused;
#   * the toolchain step is skipped once the marker file exists;
#   * RECREATE=1 deletes and rebuilds the chroot from scratch.
#
# Usage:  bash 00-prep.sh
#         RECREATE=1 bash 00-prep.sh
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
C="$ROOT/chroot"
SWAP="$ROOT/build.swap"
MIRROR=${MIRROR:-http://deb.debian.org/debian}
SUITE=${SUITE:-bullseye}
KEYRING=${KEYRING:-/usr/share/keyrings/debian-archive-keyring.gpg}
MARK="$C/root/.twindesk-stage0-done"
MIN_FREE_KB=8388608   # 8 GB

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

say "Stage 0: swap + $SUITE arm64 chroot"

# --- host checks -----------------------------------------------------------
[ "$(uname -m)" = "aarch64" ] || die "this build is native arm64 and must run on an aarch64 host (found $(uname -m))"
for cmd in sudo debootstrap mount chroot; do
  command -v "$cmd" >/dev/null 2>&1 || die "missing host command: $cmd"
done
[ -f "$KEYRING" ] || die "missing Debian keyring: $KEYRING"
sudo -v || die "sudo is required"
avail_kb=$(df -Pk "$ROOT" | awk 'NR==2{print $4}')
if [ "$avail_kb" -lt "$MIN_FREE_KB" ]; then
  printf 'WARNING: only %s MB free on %s; the build wants at least 8 GB.\n' \
    "$((avail_kb / 1024))" "$ROOT" >&2
fi
# The chroot must live on disk, never on a RAM-backed tmpfs.
case "$(df -PTk "$ROOT" | awk 'NR==2{print $2}')" in
  tmpfs|ramfs) die "$ROOT is on a RAM-backed filesystem; move the workspace to disk" ;;
esac

# --- temporary swap (4 GB) -------------------------------------------------
if ! swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAP"; then
  if [ ! -f "$SWAP" ]; then
    say "Creating 4 GB temporary swap file at $SWAP"
    sudo fallocate -l 4G "$SWAP" || sudo dd if=/dev/zero of="$SWAP" bs=1M count=4096 status=progress
    sudo chmod 600 "$SWAP"
    sudo mkswap "$SWAP"
  fi
  say "Enabling temporary swap"
  sudo swapon "$SWAP"
fi
say "Swap in use"
swapon --show
free -h

# --- optional recreate -----------------------------------------------------
if [ "${RECREATE:-0}" = "1" ] && [ -d "$C" ]; then
  say "RECREATE=1: unmounting and deleting $C"
  for m in dev/pts dev sys proc; do
    mountpoint -q "$C/$m" && sudo umount "$C/$m" || true
  done
  sudo rm -rf "$C"
fi

# --- debootstrap -----------------------------------------------------------
if [ ! -x "$C/usr/bin/apt-get" ]; then
  say "Running debootstrap $SUITE arm64 into $C (downloads ~36 MB, installs ~184 MB)"
  sudo rm -rf "$C"
  sudo debootstrap --variant=minbase --arch=arm64 --keyring="$KEYRING" "$SUITE" "$C" "$MIRROR"
else
  say "Existing chroot found — reusing $C (set RECREATE=1 to rebuild)"
fi

# --- bind mounts -----------------------------------------------------------
for m in proc sys dev; do
  mountpoint -q "$C/$m" || sudo mount --bind "/$m" "$C/$m"
done
mountpoint -q "$C/dev/pts" || sudo mount --bind /dev/pts "$C/dev/pts"
sudo cp -L /etc/resolv.conf "$C/etc/resolv.conf"

# --- apt + toolchain -------------------------------------------------------
if [ ! -f "$MARK" ]; then
  say "Configuring apt inside the chroot"
  sudo tee "$C/etc/apt/sources.list" >/dev/null <<EOF
deb $MIRROR $SUITE main
EOF
  sudo tee "$C/etc/apt/apt.conf.d/99twindesk-build" >/dev/null <<'EOF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::IndexTargets::deb::Contents-deb::DefaultEnabled "false";
Acquire::IndexTargets::deb::Contents-udeb::DefaultEnabled "false";
Acquire::IndexTargets::deb::Translation-en::DefaultEnabled "false";
Acquire::Retries "3";
EOF

  say "apt-get update"
  sudo chroot "$C" /bin/bash -lc 'export DEBIAN_FRONTEND=noninteractive; apt-get -o Dpkg::Progress-Fancy=1 update'

  say "Installing gcc/X11/GLib build toolchain (downloads ~85 MB, installs ~342 MB)"
  sudo chroot "$C" /bin/bash -lc 'export DEBIAN_FRONTEND=noninteractive; \
    apt-get -o Dpkg::Progress-Fancy=1 -y --no-install-recommends install \
      build-essential pkg-config curl ca-certificates xz-utils unzip file binutils \
      python3-minimal libx11-dev libxi-dev libxtst-dev libxext-dev libxrandr-dev \
      libxfixes-dev libglib2.0-dev'

  say "Cleaning apt archives inside the chroot"
  sudo chroot "$C" /bin/bash -lc 'apt-get clean; rm -rf /var/lib/apt/lists/*'
  sudo touch "$MARK"
else
  say "Build toolchain already installed (marker present) — skipping apt"
fi

# --- sanity checks ---------------------------------------------------------
say "Chroot sanity checks"
sudo chroot "$C" /bin/bash -lc 'gcc --version | head -1; pkg-config --modversion gio-2.0; uname -m; cat /etc/debian_version'

say "Stage 0 complete"
