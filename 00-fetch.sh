#!/bin/bash
# TwinDesk arm64 — Stage: fetch source.
#
# Clones TwinDesk 2.5.3 into <workspace>/repo if it is not there yet.
# Re-runnable: an existing clone is left untouched.
#
# Usage:  bash 00-fetch.sh
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
REPO="$ROOT/repo"
VERSION=2.5.3
URL=https://github.com/InukaAsith/TwinDesk.git

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

say "Stage fetch: TwinDesk v$VERSION source"

if [ -d "$REPO/.git" ]; then
  say "Source already present at $REPO — reusing it"
else
  command -v git >/dev/null 2>&1 || die "git is required on the host"
  rm -rf "$REPO"
  say "Cloning (shallow) v$VERSION into $REPO"
  if ! git clone --depth 1 --branch "v$VERSION" "$URL" "$REPO"; then
    say "Tag v$VERSION not available — cloning the default branch instead"
    rm -rf "$REPO"
    git clone --depth 1 "$URL" "$REPO"
  fi
fi

V=$(sed -n 's/^[[:space:]]*"version": "\([^"]*\)".*/\1/p' "$REPO/linux/package.json" | head -1)
COMMIT=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)
say "Source version: ${V:-unknown} (commit $COMMIT)"
[ "$V" = "$VERSION" ] || printf 'WARNING: expected %s, found %s\n' "$VERSION" "${V:-unknown}" >&2

say "Stage fetch complete"
