#!/bin/bash
# TwinDesk arm64 — Stage: fetch source.
#
# Clones TwinDesk at $TWINDESK_TAG into <workspace>/repo if it is not there yet.
# Re-runnable: an existing clone is left untouched.
#
# Usage:  bash 00-fetch.sh
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../config.sh
. "$ROOT/config.sh"
REPO="$WORKSPACE/repo"

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

say "Stage fetch: TwinDesk $TWINDESK_TAG source"

if [ -d "$REPO/.git" ]; then
  say "Source already present at $REPO — reusing it"
else
  command -v git >/dev/null 2>&1 || die "git is required on the host"
  rm -rf "$REPO"
  say "Cloning (shallow) $TWINDESK_TAG into $REPO"
  if ! git clone --depth 1 --branch "$TWINDESK_TAG" "$TWINDESK_REPO" "$REPO"; then
    say "Tag $TWINDESK_TAG not available — cloning the default branch instead"
    rm -rf "$REPO"
    git clone --depth 1 "$TWINDESK_REPO" "$REPO"
  fi
fi

V=$(sed -n 's/^[[:space:]]*"version": "\([^"]*\)".*/\1/p' "$REPO/linux/package.json" | head -1)
COMMIT=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)
say "Source version: ${V:-unknown} (commit $COMMIT)"
[ "$V" = "$TWINDESK_VERSION" ] || printf 'WARNING: expected %s, found %s\n' "$TWINDESK_VERSION" "${V:-unknown}" >&2

say "Stage fetch complete"
