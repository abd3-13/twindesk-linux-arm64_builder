#!/bin/bash
# TwinDesk arm64 — one-command build.
#
# Runs every stage in order and appends everything to <workspace>/build.log:
#   00-fetch.sh  -> 00-prep.sh -> 01-toolchain.sh -> 02-build.sh -> 03-verify.sh
#
# A failing stage stops the run. Re-running starts from the beginning but every
# stage is idempotent, so completed work (chroot, Node, Rust, node_modules,
# cargo cache) is reused.
#
# Usage:
#   bash build-scripts/run-all.sh
#   CLEANUP=1 bash build-scripts/run-all.sh     # run 99-cleanup.sh on success
#   RECREATE=1 bash build-scripts/run-all.sh    # rebuild the chroot from scratch
#
# Useful environment variables:
#   CARGO_BUILD_JOBS=4   NODE_HEAP_MB=1536   SUITE=bullseye
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../config.sh
. "$ROOT/config.sh"
LOG=${LOG:-"$WORKSPACE/build.log"}

printf 'TwinDesk arm64 build — %s\n' "$(date -Is)"
printf 'Workspace: %s\nLog: %s\n\n' "$WORKSPACE" "$LOG"

set -o pipefail
{
  printf '\n########## run %s ##########\n' "$(date -Is)"
  bash "$SCRIPT_DIR/00-fetch.sh"
  bash "$SCRIPT_DIR/00-prep.sh"
  bash "$SCRIPT_DIR/01-toolchain.sh"
  bash "$SCRIPT_DIR/02-build.sh"
  bash "$SCRIPT_DIR/03-verify.sh"
  if [ "${CLEANUP:-0}" = "1" ]; then
    bash "$SCRIPT_DIR/99-cleanup.sh"
  fi
} 2>&1 | tee -a "$LOG"
STATUS=${PIPESTATUS[0]}

if [ "$STATUS" -ne 0 ]; then
  printf '\nBUILD FAILED (exit %s). Full log: %s\n' "$STATUS" "$LOG" >&2
  printf 'Fix the cause, then re-run: bash %s/run-all.sh\n' "$SCRIPT_DIR" >&2
  exit "$STATUS"
fi

printf '\nBUILD OK. Artifact:\n'
ls -lh "$WORKSPACE"/TwinDesk-*-arm64.deb 2>/dev/null || true
