#!/usr/bin/env bash
# Stop hook: the explainer gate. Blocks the DRIVER session's stop when a
# transition phase (…_SHIP, HUMAN_GATE, DONE) has no published explainer
# receipt. Fails OPEN on every infra problem; scoped so bystander sessions and
# subagents are never gated and cannot burn the block-once marker.
set -uo pipefail

IN="$(cat 2>/dev/null || true)"
[ -n "$IN" ] || exit 0
J() { printf '%s' "$IN" | jq -r "$1 // empty" 2>/dev/null || true; }

[ "$(J .hook_event_name)" = "Stop" ] || exit 0        # SubagentStop etc: never gate
[ -z "$(J .agent_id)" ] || exit 0                      # subagents: never gate
[ "$(J .stop_hook_active)" = "true" ] && exit 0        # loop guard (belt)

CWD="$(J .cwd)"
REPO="${GODMODE_REPO:-${CWD:-$PWD}}"
SCRATCH="$REPO/.agents/scratch"
# Pick the first GODMODE-SIGNED state file (.agents/scratch is shared with
# other tools; a foreign *-state.json must not gate a bystander's stop).
STATE=""
for _s in "$SCRATCH"/*-state.json; do
  [ -f "$_s" ] || continue
  jq -e '.phase and (.epics or .dashboard_slug)' "$_s" >/dev/null 2>&1 || continue
  STATE="$_s"; break
done
[ -n "$STATE" ] || exit 0                              # no programme: inert
SLUG="$(basename "$STATE" | sed 's/-state\.json$//')"

DRIVER="$(jq -r '.driver_session_id // empty' "$STATE" 2>/dev/null || true)"
SESS="$(J .session_id)"
[ -n "$DRIVER" ] && [ -n "$SESS" ] && [ "$SESS" = "$DRIVER" ] || exit 0   # driver only

[ -f "$SCRATCH/$SLUG-publish.pending" ] && exit 0      # machinery broken: fail open

PHASE="$(jq -r '.phase // empty' "$STATE" 2>/dev/null || true)"
case "$PHASE" in
  *_SHIP|HUMAN_GATE|DONE) ;;
  *) exit 0 ;;                                          # not a transition phase
esac

RECEIPTS="$SCRATCH/$SLUG-explainer-receipts.json"
if jq -e --arg p "$PHASE" 'map(select(.phase == $p)) | length > 0' \
     "$RECEIPTS" >/dev/null 2>&1; then
  exit 0                                                # explainer already published
fi

MARK="$SCRATCH/$SLUG-gate-blocked.$SESS.$PHASE"
[ -f "$MARK" ] && exit 0                                # one block per session+phase (braces)
touch "$MARK" 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
printf '{"decision":"block","reason":"Phase %s shipped without its explainer. Write the phase explainer and publish via %s/explainer-publish.sh <html> %s %s <publisher args>, then stop."}\n' \
  "$PHASE" "$SCRIPT_DIR" "$SLUG" "$PHASE"
exit 0
