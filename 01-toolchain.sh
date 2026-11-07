#!/bin/bash
# TwinDesk arm64 — Stage 1: Node.js + Rust inside the chroot.
#
# Nothing is installed on the host. Re-runnable: existing installs are detected
# and skipped, so this is also the "resume after a failure" step for the toolchain.
#
# Usage:  bash 01-toolchain.sh
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
C="$ROOT/chroot"
# Electron 44 declares "node >= 22.12.0"; use the current Node 22 LTS.
NODE_VER=${NODE_VER:-v22.23.4}
NODE_TAR="node-${NODE_VER}-linux-arm64.tar.xz"
NODE_MIN_MAJOR=22
RUST_VER=${RUST_VER:-1.99.1}

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -x "$C/usr/bin/apt-get" ] || die "chroot not found; run 00-prep.sh first"

# Mounts may have gone away after a reboot.
for m in proc sys dev; do
  mountpoint -q "$C/$m" || sudo mount --bind "/$m" "$C/$m"
done
mountpoint -q "$C/dev/pts" || sudo mount --bind /dev/pts "$C/dev/pts"

say "Stage 1: Node.js $NODE_VER + Rust $RUST_VER inside $C"

NODE_MAJOR=$(sudo chroot "$C" /bin/bash -lc 'node -p "process.versions.node.split(\".\")[0]"' 2>/dev/null || echo 0)
if [ "${FORCE_NODE:-0}" = "1" ] || [ "${NODE_MAJOR:-0}" -lt "$NODE_MIN_MAJOR" ]; then
  say "Installing Node.js $NODE_VER (current major: ${NODE_MAJOR:-none}; need >= $NODE_MIN_MAJOR)"
  say "Downloading Node.js $NODE_VER with progress"
  sudo chroot "$C" /bin/bash -lc "cd /tmp && curl -fL --progress-bar https://nodejs.org/dist/${NODE_VER}/${NODE_TAR} -o ${NODE_TAR}"
  # Wipe the old install first: extracting over it leaves stale nested modules
  # (e.g. an old minipass inside npm's minizlib) and npm then crashes on load.
  say "Removing the previous Node.js install from /usr/local"
  sudo chroot "$C" /bin/bash -lc 'rm -rf /usr/local/*'
  say "Installing Node.js $NODE_VER to /usr/local"
  sudo chroot "$C" /bin/bash -lc "tar -xJf /tmp/${NODE_TAR} -C /usr/local --strip-components=1 && rm -f /tmp/${NODE_TAR}"
else
  say "Node.js major $NODE_MAJOR already installed — skipping (FORCE_NODE=1 to reinstall)"
fi

say "Node/npm versions"
sudo chroot "$C" /bin/bash -lc 'export HOME=/root; node --version; npm --version; node -p "process.arch + \" / \" + process.platform"'

# npm's default 2 retries are too few on a lossy link; persist generous settings.
say "Configuring npm retries/timeouts"
sudo chroot "$C" /bin/bash -lc 'export HOME=/root
  npm config set fetch-retries 10
  npm config set fetch-retry-mintimeout 20000
  npm config set fetch-retry-maxtimeout 180000
  npm config set fetch-timeout 900000
  npm config set maxsockets 4
  npm config get fetch-retries'

if ! sudo chroot "$C" /bin/bash -lc 'test -x /root/.cargo/bin/rustc'; then
  say "Downloading rustup-init (20 MB) with progress"
  sudo chroot "$C" /bin/bash -lc 'cd /tmp && curl -fL --progress-bar https://static.rust-lang.org/rustup/dist/aarch64-unknown-linux-gnu/rustup-init -o rustup-init && chmod +x rustup-init'
  say "Installing Rust $RUST_VER (minimal profile; downloads ~106 MB)"
  sudo chroot "$C" /bin/bash -lc "export RUSTUP_HOME=/root/.rustup CARGO_HOME=/root/.cargo; \
    /tmp/rustup-init -y --profile minimal --default-toolchain ${RUST_VER}; \
    rm -f /tmp/rustup-init"
else
  say "Rust already installed — skipping"
fi

say "Rust versions"
sudo chroot "$C" /bin/bash -lc 'export PATH=/root/.cargo/bin:$PATH; rustc -Vv; cargo -V'

say "Disk usage inside the chroot"
sudo du -sh "$C/root/.rustup" "$C/root/.cargo" "$C/usr/local" 2>/dev/null || true

say "Stage 1 complete"
