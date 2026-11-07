#!/bin/bash
# TwinDesk arm64 — cleanup: unmount and remove the chroot and the temporary swap.
#
# Keeps: the source clone (repo/), the produced .deb, the scripts and build.log.
# Removes: chroot/, build.swap, .verify/.
#
# Usage:  bash 99-cleanup.sh
#         KEEP_CHROOT=1 bash 99-cleanup.sh   # keep the chroot for debugging
#         KEEP_SWAP=1   bash 99-cleanup.sh   # keep the swap file enabled
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../config.sh
. "$ROOT/config.sh"
C="$ROOT/chroot"
SWAP="$ROOT/build.swap"

say() { printf '\n==> %s\n' "$*"; }

say "Cleanup"

if [ -d "$C" ] && [ "${KEEP_CHROOT:-0}" != "1" ]; then
  say "Unmounting chroot filesystems"
  for m in dev/pts dev sys proc; do
    if mountpoint -q "$C/$m" 2>/dev/null; then
      sudo umount "$C/$m" || sudo umount -l "$C/$m" || true
    fi
  done
  say "Deleting $C"
  sudo rm -rf "$C"
else
  say "Keeping chroot (KEEP_CHROOT=1)" 
fi

if [ -f "$SWAP" ] && [ "${KEEP_SWAP:-0}" != "1" ]; then
  say "Disabling and deleting temporary swap"
  sudo swapoff "$SWAP" 2>/dev/null || true
  sudo rm -f "$SWAP"
else
  say "Keeping swap file (KEEP_SWAP=1 or not present)"
fi

rm -rf "$ROOT/.verify"

say "Remaining files in $ROOT"
ls -lh "$ROOT"
say "Cleanup complete — the .deb and repo/ were kept"
