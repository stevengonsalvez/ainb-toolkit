#!/usr/bin/env bash
# Hook wrapper for sync.sh: threads the firing session's own session_id from
# the hook event into GODMODE_SESSION_ID.
#
# Why this exists: Stop and PreCompact hooks fire in EVERY session in the
# checkout, not just the driver's. Without the session id, sync.sh fell back to
# a checkout-global token file, so a co-located bystander session heartbeated
# the driver's lease under the driver's identity — keeping a CRASHED driver's
# lease alive forever and blocking the foreign takeover the lease exists for
# (spec A2). The session id is always on hook stdin; use it.
#
# usage: sync-hook.sh <sync.sh args...>   (hook event JSON on stdin)
set -uo pipefail

IN="$(cat 2>/dev/null || true)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SID="$(printf '%s' "$IN" | jq -r '.session_id // empty' 2>/dev/null || true)"
CWD="$(printf '%s' "$IN" | jq -r '.cwd // empty' 2>/dev/null || true)"

GODMODE_SESSION_ID="$SID" GODMODE_REPO="${GODMODE_REPO:-${CWD:-$PWD}}" \
  "$SCRIPT_DIR/sync.sh" "$@" >/dev/null 2>&1 || true
exit 0
