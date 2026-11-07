#!/bin/bash
# TwinDesk arm64 — Stage 3: verify the produced .deb.
#
# Checks, all read-only:
#   * control fields: Package, Version, Architecture = arm64, Installed-Size;
#   * Depends contains the Electron runtime libraries added by the patch;
#   * Recommends contains adb;
#   * the package does NOT contain the x86-64 bundled adb;
#   * helper binaries are ARM aarch64 ELF and need glibc <= 2.31 (bullseye);
#   * ldd resolves every library inside the chroot (when the chroot still exists);
#   * SHA-256 of the artifact.
#
# Usage:  bash 03-verify.sh [path/to/file.deb]
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../config.sh
. "$ROOT/config.sh"
C="$ROOT/chroot"
FAIL=0
WARN=0

say() { printf '\n==> %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
warn() { printf 'WARN: %s\n' "$*" >&2; WARN=$((WARN + 1)); }

if [ "${1:-}" != "" ]; then
  DEB="$1"
else
  DEB=$(find "$ROOT" -maxdepth 1 -type f -name 'TwinDesk-*-arm64.deb' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)
fi
[ -n "${DEB:-}" ] && [ -f "$DEB" ] || {
  printf 'usage: %s <file.deb>\n' "$(basename "$0")" >&2
  exit 1
}

say "Verifying $DEB"
command -v dpkg-deb >/dev/null 2>&1 || { echo "dpkg-deb is required on the host" >&2; exit 1; }

# --- control ---------------------------------------------------------------
PKG=$(dpkg-deb -f "$DEB" Package)
VER=$(dpkg-deb -f "$DEB" Version)
ARCH=$(dpkg-deb -f "$DEB" Architecture)
SIZE=$(dpkg-deb -f "$DEB" Installed-Size)
DEP=$(dpkg-deb -f "$DEB" Depends || true)
REC=$(dpkg-deb -f "$DEB" Recommends || true)
printf 'Package:         %s\nVersion:         %s\nArchitecture:    %s\nInstalled-Size:  %s KB\n' \
  "$PKG" "$VER" "$ARCH" "$SIZE"
printf 'Depends:         %s\nRecommends:      %s\n' "$DEP" "$REC"
[ "$ARCH" = "arm64" ] || fail "Architecture is '$ARCH', expected arm64"

# --- dependency checks -----------------------------------------------------
for p in libgbm1 libxkbcommon0 libxcomposite1 libxdamage1 libudev1; do
  grep -q -- "$p" <<<"$DEP" || fail "Depends is missing $p"
done
for p in libasound2 libcups2; do
  grep -q -- "$p" <<<"$DEP" || fail "Depends is missing $p (or its t64 alternative)"
done
grep -Eq '(^|[ ,])adb([ ,]|$)' <<<"$REC" || fail "Recommends is missing adb"

# --- contents --------------------------------------------------------------
say "Package contents (vendor + helpers)"
CONTENTS=$(dpkg-deb -c "$DEB")
if grep -q 'vendor/adb' <<<"$CONTENTS"; then
  fail "package contains bundled vendor/adb (x86-64 binary)"
else
  echo "OK: no bundled vendor/adb"
fi
grep -q 'vendor/scrcpy-server' <<<"$CONTENTS" && echo "OK: scrcpy-server present" || warn "scrcpy-server not found in package"
HELPER_COUNT=$(grep -c 'linux-helper/bin/' <<<"$CONTENTS" || true)
echo "helper files in package: $HELPER_COUNT"
[ "$HELPER_COUNT" -gt 0 ] || fail "no linux-helper/bin files in package"

# --- extract for ELF checks -----------------------------------------------
VERIFY="$ROOT/.verify"
say "Extracting to $VERIFY for ELF checks"
rm -rf "$VERIFY"
mkdir -p "$VERIFY"
dpkg-deb -x "$DEB" "$VERIFY"

shopt -s nullglob
BINS=("$VERIFY"/opt/*/resources/app/linux-helper/bin/* "$VERIFY"/opt/*/linux-helper/bin/*)
if [ "${#BINS[@]}" -eq 0 ]; then
  mapfile -t BINS < <(find "$VERIFY" -type f -path '*linux-helper/bin/*')
fi

say "Helper binaries"
for f in "${BINS[@]}"; do
  [ -f "$f" ] || continue
  B=$(basename "$f")
  DESC=$(file -b "$f")
  MAXG=$(objdump -T "$f" 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1 || true)
  printf '  %-32s %s | max %s\n' "$B" "$DESC" "${MAXG:-none}"
  grep -q 'ARM aarch64' <<<"$DESC" || fail "$B is not an ARM aarch64 binary"
  if [ -n "$MAXG" ]; then
    NEWER=$(printf '%s\nGLIBC_2.31\n' "$MAXG" | sort -V | tail -1)
    [ "$NEWER" = "GLIBC_2.31" ] || fail "$B requires $MAXG (newer than bullseye's GLIBC_2.31)"
  fi
done

# --- Electron binary -------------------------------------------------------
ELEC=$(find "$VERIFY" -type f -name twindesk -perm -u+x | head -1 || true)
if [ -n "$ELEC" ]; then
  say "Electron executable"
  file -b "$ELEC"
  ELEC_MAX=$(objdump -T "$ELEC" 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1 || true)
  echo "max glibc: ${ELEC_MAX:-unknown}"
fi

# --- ldd inside the chroot -------------------------------------------------
if [ -x "$C/usr/bin/apt-get" ]; then
  say "ldd inside the chroot (library resolution)"
  H="$C/root/.verify"
  sudo rm -rf "$H"
  sudo mkdir -p "$H"
  sudo dpkg-deb -x "$DEB" "$H"
  BIN=$(find "$H" -type f -path '*linux-helper/bin/macshare-linuxhelper' | head -1 || true)
  if [ -n "$BIN" ]; then
    REL=${BIN#"$C"}
    if sudo chroot "$C" /bin/bash -lc "ldd '$REL'"; then
      echo "OK: all libraries resolved"
    else
      fail "ldd reported missing libraries"
    fi
  else
    warn "macshare-linuxhelper not found in package"
  fi
  sudo rm -rf "$H"
else
  warn "chroot not present; skipping ldd (cleaned up already?)"
fi

# --- checksum --------------------------------------------------------------
say "Checksum"
sha256sum "$DEB"

say "Result"
if [ "$FAIL" -ne 0 ]; then
  printf 'FAILED: %d check(s) failed, %d warning(s)\n' "$FAIL" "$WARN" >&2
  exit 1
fi
printf 'OK: all checks passed (%d warning(s))\n' "$WARN"

# Keep the extracted tree only if asked.
if [ "${KEEP_VERIFY:-0}" != "1" ]; then
  rm -rf "$VERIFY"
fi
