#!/usr/bin/env bash
# Copilot userPromptSubmitted hook: one line when the programme's lease
# heartbeat is stale, else silent. Read-only.
set -uo pipefail

REPO="${GODMODE_REPO:-$PWD}"
SCRATCH="$REPO/.agents/scratch"
STATE="$(ls "$SCRATCH"/*-state.json 2>/dev/null | head -1 || true)"
[ -n "$STATE" ] || exit 0
SLUG="$(basename "$STATE" | sed 's/-state\.json$//')"
LEASE="$SCRATCH/.godmode-sync/$SLUG/lease.json"
[ -f "$LEASE" ] || exit 0

HB="$(jq -r '.heartbeat_ts // empty' "$LEASE" 2>/dev/null || true)"
[ -n "$HB" ] || exit 0
E="$(date -j -u -f %Y-%m-%dT%H:%M:%SZ "$HB" +%s 2>/dev/null || date -u -d "$HB" +%s 2>/dev/null || echo 0)"
AGE=$(( $(date -u +%s) - E ))
TTL="${GODMODE_LEASE_TTL:-1800}"
if [ "$AGE" -gt "$TTL" ]; then
  echo "godmode: programme '$SLUG' lease heartbeat is ${AGE}s old (stale > ${TTL}s); driver may be down. /godmode status for details."
fi
exit 0
