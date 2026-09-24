#!/usr/bin/env bash
#
# rename.sh — rename the current Herdr tab. A silent no-op outside Herdr.
#
# Usage: rename.sh <name>
#
# Herdr marks every managed pane with HERDR_ENV=1 and injects the caller's
# tab as HERDR_TAB_ID; the rename goes through `herdr tab rename`.
#
# Exit codes: 0 renamed, or not inside Herdr · 4 no name given · 6 rename impossible/failed

set -euo pipefail
err() { printf '%s\n' "$*" >&2; }

name="${1:-}"
[ -n "$name" ] || { err "Usage: rename.sh <name>"; exit 4; }

[ "${HERDR_ENV:-}" = 1 ] || exit 0

tab="${HERDR_TAB_ID:-}"
[ -n "$tab" ] || { err "HERDR_ENV=1 but HERDR_TAB_ID is unset — cannot resolve the current tab."; exit 6; }
command -v herdr >/dev/null 2>&1 || { err "herdr binary not found in PATH — tab not renamed."; exit 6; }

rc=0
out="$(herdr tab rename "$tab" "$name" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] || printf '%s' "$out" | grep -q '"error"'; then
  err "herdr tab rename failed: ${out:-exit $rc}"
  exit 6
fi
printf 'Herdr tab %s renamed to "%s"\n' "$tab" "$name"
