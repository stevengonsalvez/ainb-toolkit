#!/usr/bin/env bash
# tick-emit.sh: tick step 5's mission-control emits, every tick.
#
#   scripts/classify.sh < $CM_HOME/last-discover.json | scripts/tick-emit.sh
#   scripts/tick-emit.sh --classify <file> [--status active|idle|error] [--task <text>] [--extra <json-object>]
#
# Builds the fleet summary from the tick's classify JSON (concertmaster.classify/v1)
# and emits, in this order:
#   1. mc-emit.sh --tick <summary>       with MC_NO_FLUSH=1 (queue only)
#   2. mc-emit.sh --fleet-upsert         for the concertmaster itself; this last
#                                        emit flushes the outbox once
# Summary: {summary, at, tickId, discoverAt, discoverStale (older than 30 min),
# items, counts (class => n), offlineHosts[], unlinkedPrs, unlinkedStale} plus the --extra object's keys (a non-object
# --extra is dropped with a warning). unlinkedPrs comes from
# $CM_HOME/unlinked-prs.json (scripts/unlinked-prs.sh) when present. Unreadable
# classify input still emits, with summary "tick: classify unavailable".
# Status: --status, else active when any item is running or stuck, else idle.
# Agent id: CM_AGENT_ID (default <short hostname>:concertmaster); workspace:
# CM_WORKSPACE (default the git top level of $PWD, else $PWD).
#
# Never fails the tick: always exit 0. mc-emit runs quiet (MC_QUIET=1, stderr
# dropped, so no tenant value is ever printed); this script prints ONE line
# about its OWN two lines only (queued or dead-lettered), found by tickId and
# agentId in the shared outbox and dead file; "sent" is claimed only when
# fleet.sent.json shows mission-control accepted this tick's upsert. Stdin is
# read under a 10s timeout, so a pipe that never closes cannot hang the tick.
# Unsent tick events are not coalesced here: the outbox belongs to mc-emit.sh
# (cap 5000, oldest dropped), and --requeue-dead keeps the newest upsert only.
# Lines dead-lettered or left queued while the sink has no tenant for this
# project are expected: they wait for `mc-emit.sh --requeue-dead` once the
# tenant exists. Never prints the token.
# Fleet upsert refused by design: with a project id set mc-emit
# skips the upsert and records it in $CM_HOME/fleet.skipped, so this script
# flushes the tick itself and says so in its one line; a 403 on the upsert
# (route refused for this token) is dead-lettered by mc-emit and reported as
# a refusal, and for 24h after it no upsert is sent (one dead line a day, not
# one a tick). All still exit 0.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

EMIT="${CM_MC_EMIT:-$HERE/mc-emit.sh}"
SRC=-; STATUS=""; TASK=""; EXTRA='{}'
while [ $# -gt 0 ]; do
  case "$1" in
    --classify|--status|--task|--extra)
      [ $# -ge 2 ] || { cm_warn "tick-emit: $1 needs a value (ignored)"; break; } ;;
  esac
  case "$1" in
    --classify) SRC="${2:-}"; shift 2 ;;
    --status) STATUS="${2:-}"; shift 2 ;;
    --task) TASK="${2:-}"; shift 2 ;;
    --extra) EXTRA="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,37p' "$0"; exit 0 ;;
    *) cm_warn "tick-emit: unknown arg $1 (ignored)"; shift ;;
  esac
done
command -v jq >/dev/null 2>&1 || { cm_warn "tick-emit: jq missing, no emit this tick"; exit 0; }
[ -x "$EMIT" ] || { cm_warn "tick-emit: $EMIT not executable, no emit this tick"; exit 0; }
printf '%s' "$EXTRA" | jq -e 'type == "object"' >/dev/null 2>&1 \
  || { cm_warn "tick-emit: --extra is not a JSON object, dropped"; EXTRA='{}'; }
START_MS="$(date +%s)000"
TICK_ID="$START_MS-$$"
UNL="$CM_HOME/unlinked-prs.json"
if [ -s "$UNL" ] && jq -e '.prs | type == "array"' "$UNL" >/dev/null 2>&1; then
  EXTRA="$(jq -c --slurpfile u "$UNL" '{unlinkedPrs: ($u[0].prs | length), unlinkedStale: ($u[0].stale == true)} + .' <<<"$EXTRA")"
fi
EXTRA="$(jq -c --arg id "$TICK_ID" '. + {tickId: $id}' <<<"$EXTRA")"

if [ "$SRC" = - ] && [ -t 0 ]; then IN=""   # no input piped: never block the tick
elif [ "$SRC" = - ]; then IN="$(cm_timeout 10 cat 2>/dev/null)"; else IN="$(cat -- "$SRC" 2>/dev/null)"; fi
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if printf '%s' "$IN" | jq -e 'type == "object" and (.items | type == "array")' >/dev/null 2>&1; then
  SUMMARY="$(printf '%s' "$IN" | jq -c --arg now "$NOW" --argjson extra "$EXTRA" '
    (.summary // (.items | group_by(.class) | map({key: .[0].class, value: length}) | from_entries)) as $c
    | ([.items[] | select(.class == "host-offline") | .host] | unique) as $off
    | {summary: ("tick: \(.items | length) items; "
                 + ($c | to_entries | sort_by(.key) | map("\(.key)=\(.value)") | join(" "))
                 + (if ($off | length) > 0 then "; offline: " + ($off | join(",")) else "" end)),
       at: $now, discoverAt: (.generatedAt // null),
       discoverStale: ((.generatedAt // null) as $g | if $g == null then null
                       else ((try ($g | tostring | sub("\\.[0-9]+"; "") | fromdateiso8601) catch null) as $t
                             | if $t == null then null else ($now | fromdateiso8601) - $t > 1800 end) end),
       items: (.items | length), counts: $c, offlineHosts: $off} + $extra')"
  [ -n "$STATUS" ] || STATUS="$(printf '%s' "$IN" | jq -r \
    'if any(.items[]; .class == "running" or .class == "stuck") then "active" else "idle" end')"
else
  cm_warn "tick-emit: classify input unreadable, emitting a bare tick"
  SUMMARY="$(jq -cn --arg now "$NOW" --argjson extra "$EXTRA" '{summary: "tick: classify unavailable", at: $now} + $extra')"
  [ -n "$STATUS" ] || STATUS=error
fi
case "$STATUS" in active|idle|error) ;; *) STATUS=active ;; esac
[ -n "$TASK" ] || TASK="$(printf '%s' "$SUMMARY" | jq -r '.summary')"

AGENT_ID="${CM_AGENT_ID:-$(hostname 2>/dev/null | cut -d. -f1):concertmaster}"
WS="${CM_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# own <file>: how many of THIS tick's two lines the file holds: the tick event
# by tickId, the upsert by agentId queued since START_MS. Never the shared
# totals, which other hooks' lines and mc-emit's caps make meaningless here.
own() {
  { [ ! -f "$1" ] || jq -R --arg id "$TICK_ID" --arg a "$AGENT_ID" --argjson s "$START_MS" \
      'fromjson? | select(.body.metadata.fleet.tickId == $id
                          or (.endpoint == "/api/fleet/upsert" and .body.agentId == $a and (.queuedAt // 0) >= $s)) | 1' "$1"; } \
    2>/dev/null | grep -c . || true
}

MC_QUIET=1 MC_NO_FLUSH=1 "$EMIT" --tick "$SUMMARY" 2>/dev/null >/dev/null || true
# An upsert for this agent refused with 403 in the last 24h: the route is
# closed to this token, so do not send one a tick (each would add a dead line
# and, at the dead file's cap, push out lines waiting for --requeue-dead).
HELD="$( { [ ! -f "$CM_HOME/outbox.dead.jsonl" ] || jq -R --arg a "$AGENT_ID" --argjson s "$((START_MS - 86400000))" \
  'fromjson? | select(.endpoint == "/api/fleet/upsert" and .body.agentId == $a and (.queuedAt // 0) >= $s and .deadCode == 403) | 1' \
  "$CM_HOME/outbox.dead.jsonl"; } 2>/dev/null | grep -c . || true)"
if [ "$HELD" -eq 0 ]; then
  MC_NO_FLUSH=0 MC_QUIET=1 "$EMIT" --fleet-upsert "$AGENT_ID" concertmaster "$STATUS" "$TASK" "$WS" 2>/dev/null >/dev/null || true
fi
# Skipped upsert (project-bound token): nothing flushed, so flush the tick here.
# fleet.skipped is one slot for every agent (a worker hook may overwrite it
# between the upsert and this read), so any skip since tick start counts.
SKIPPED="$( { [ ! -s "$CM_HOME/fleet.skipped" ] || jq -r --argjson s "$START_MS" \
  '(.at // 0) >= $s' "$CM_HOME/fleet.skipped"; } 2>/dev/null)"
[ "$SKIPPED" != true ] && [ "$HELD" -eq 0 ] || MC_NO_FLUSH=0 MC_QUIET=1 "$EMIT" --flush 2>/dev/null >/dev/null || true

QUEUED="$(own "$CM_HOME/outbox.jsonl")"
DEAD="$(own "$CM_HOME/outbox.dead.jsonl")"
# This tick's upsert dead-lettered with 403: the route is refused to this token.
REFUSED="$( { [ ! -f "$CM_HOME/outbox.dead.jsonl" ] || jq -R --arg a "$AGENT_ID" --argjson s "$START_MS" \
  'fromjson? | select(.endpoint == "/api/fleet/upsert" and .body.agentId == $a and (.queuedAt // 0) >= $s and .deadCode == 403) | 1' \
  "$CM_HOME/outbox.dead.jsonl"; } 2>/dev/null | grep -c . || true)"
# The upsert is confirmed only by mc-emit's accepted-upsert record.
ACCEPTED="$( { [ ! -s "$CM_HOME/fleet.sent.json" ] || jq -r --arg a "$AGENT_ID" --argjson s "$START_MS" \
  --argjson e "$(date +%s)999" '((.[$a] // 0) as $q | $q >= $s and $q <= $e)' "$CM_HOME/fleet.sent.json"; } 2>/dev/null)"
# Say why from what mc-emit recorded, never re-deriving or printing the tenant.
# Held: no upsert sent, so a refused line counted here is an earlier one.
if [ "$HELD" -gt 0 ] && [ "$QUEUED" -eq 0 ] && [ "$DEAD" -eq "$REFUSED" ]; then
  cm_warn "tick-emit: tick sent; fleet upsert not sent (refused with 403 in the last 24h, see outbox.dead.jsonl)"
elif [ "$SKIPPED" = true ] && [ "$QUEUED" -eq 0 ] && [ "$DEAD" -eq 0 ]; then
  cm_warn "tick-emit: tick sent; fleet upsert skipped (project-bound token may not call /api/fleet/upsert, see fleet.skipped)"
elif [ "$REFUSED" -gt 0 ] && [ "$QUEUED" -eq 0 ] && [ "$DEAD" -eq "$REFUSED" ]; then
  cm_warn "tick-emit: tick sent; fleet upsert refused (403: this token may not call /api/fleet/upsert), dead-lettered, not retried"
elif [ "$QUEUED" -eq 0 ] && [ "$DEAD" -eq 0 ] && [ "$ACCEPTED" = true ]; then
  echo "tick-emit: tick + fleet upsert sent ($STATUS)"
elif [ "$QUEUED" -eq 0 ] && [ "$DEAD" -eq 0 ]; then
  cm_warn "tick-emit: this tick's 2 lines left the outbox but the upsert is not confirmed (lost append, or dropped by mc-emit's fleet-order guard)"
else
  if [ -f "$CM_HOME/mc-emit.tenant-rejected" ]; then WHY="MC_TENANT_ID is a placeholder, fix mc.env"
  elif [ "$DEAD" -gt 0 ]; then WHY="rejected by mission-control, expected until the sink has this project's tenant; recover with mc-emit.sh --requeue-dead"
  else WHY="kept queued by mc-emit: no tenant or token yet, endpoint down, or a backlog ahead; retried next tick"; fi
  cm_warn "tick-emit: queued=$QUEUED dead=$DEAD of this tick's 2 lines ($WHY)"
fi
exit 0
