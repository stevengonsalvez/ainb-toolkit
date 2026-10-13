#!/usr/bin/env bash
# mc-emit.sh: queue an event for the telemetry sink (a mission-control style
# dashboard), then try to flush the queue. Optional: with no base URL
# configured, lines are queued and never sent.
#
#   mc-emit.sh <type> <message> [metadata-json]
#   mc-emit.sh --fleet-upsert <agentId> <name> <status> <currentTask> <workspace> [hiddenFromUI]
#   mc-emit.sh --flush                      # retry queued lines only
#
# Every call appends ONE line to $CM_HOME/outbox.jsonl first, so nothing is
# lost when the sink is down. A flush POSTs each line with
# `curl --max-time 5` and drops a line only after a 2xx. A flush sends at most
# 10 lines and runs at most 30s (MC_FLUSH_BATCH, MC_FLUSH_SECS); after the
# first network failure the rest waits for the next call. A 4xx other than
# 401/403/408/429 can never succeed, so that line moves to outbox.dead.jsonl
# with its code instead of being retried forever. An interrupted flush
# requeues its lines and removes the header file (trap).
#
# Endpoints (base $MC_BASE_URL, else config telemetry.base_url; no default):
#   POST /api/events        {tenantId,type,message,metadata,timestamp}
#   POST /api/fleet/upsert  {tenantId,agentId,name,status,currentTask,workspace,hiddenFromUI}
#
# Auth: header X-MC-Token read from $MC_TOKEN_FILE (else config
# telemetry.token_file, else ~/.secrets/mc-auth-token). The token never touches argv: it goes into a
# 0600 header file passed as `-H @file`. No token file: lines stay queued.
#
# Config: MC_TENANT_ID (warns when unset), else config telemetry.tenant_id.
# Also read, without executing, from $CM_HOME/mc.env lines MC_TENANT_ID=...
# and MC_BASE_URL=...
#
# Always exits 0: a hook or tick must never fail because of telemetry.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$HERE/lib.sh" ]; then
  # shellcheck source=SCRIPTDIR/lib.sh
  . "$HERE/lib.sh"
else
  CM_HOME="${CM_HOME:-$HOME/.concertmaster}"
fi

# Values from mc.env, parsed (never sourced). Env wins over the file.
cfg() {
  [ -f "$CM_HOME/mc.env" ] || return 0
  sed -n "s/^[[:space:]]*$1=//p" "$CM_HOME/mc.env" | tail -n 1 | sed 's/^"//; s/"$//'
}
TENANT="${MC_TENANT_ID:-$(cfg MC_TENANT_ID)}"
BASE="${MC_BASE_URL:-$(cfg MC_BASE_URL)}"
if [ -z "$BASE" ] && command -v cm_cfg >/dev/null 2>&1; then BASE="$(cm_cfg .telemetry.base_url)"; fi
if [ -z "$TENANT" ] && command -v cm_cfg >/dev/null 2>&1; then TENANT="$(cm_cfg .telemetry.tenant_id)"; fi
TOKEN_FILE="${MC_TOKEN_FILE:-}"
if [ -z "$TOKEN_FILE" ] && command -v cm_cfg >/dev/null 2>&1; then TOKEN_FILE="$(cm_cfg .telemetry.token_file)"; fi
TOKEN_FILE="${TOKEN_FILE:-$HOME/.secrets/mc-auth-token}"
# shellcheck disable=SC2088
case "$TOKEN_FILE" in "~/"*) TOKEN_FILE="$HOME/${TOKEN_FILE#\~/}" ;; esac
OUTBOX="$CM_HOME/outbox.jsonl"
MAX_LINES="${MC_OUTBOX_MAX:-5000}"
BATCH="${MC_FLUSH_BATCH:-10}"
MAX_SECS="${MC_FLUSH_SECS:-30}"
DEAD="$CM_HOME/outbox.dead.jsonl"

warn() { [ "${MC_QUIET:-0}" = 1 ] || printf 'mc-emit: %s\n' "$*" >&2; }

command -v jq >/dev/null 2>&1 || { warn "jq missing: event dropped"; exit 0; }
mkdir -p "$CM_HOME" 2>/dev/null || { warn "cannot create $CM_HOME"; exit 0; }
[ -n "$TENANT" ] || warn "MC_TENANT_ID unset: tenantId sent as null"

NOW_MS="$(date +%s)000"
HOSTNAME_S="$(hostname 2>/dev/null | cut -d. -f1)"

enqueue() {
  # enqueue <endpoint> <body-json>
  jq -cn --arg ep "$1" --argjson body "$2" --argjson q "$NOW_MS" \
    '{endpoint:$ep, body:$body, queuedAt:$q}' >> "$OUTBOX" 2>/dev/null \
    || warn "could not queue line"
}

# State shared with the cleanup trap, so an interrupted flush never leaks the
# header file or loses queued lines (at-least-once: a line in flight may be
# sent twice, never dropped).
F_HDR=""
F_WORK=""
F_KEEP=""
F_LOCK=""
F_POS=0

flush_cleanup() {
  [ -n "$F_HDR" ] && rm -f "$F_HDR"
  if [ -n "$F_WORK" ] && [ -f "$F_WORK" ]; then
    [ -n "$F_KEEP" ] && [ -s "$F_KEEP" ] && cat "$F_KEEP" >> "$OUTBOX"
    if [ "$F_POS" -gt 0 ]; then tail -n +"$F_POS" "$F_WORK" >> "$OUTBOX"
    else cat "$F_WORK" >> "$OUTBOX"; fi
    rm -f "$F_WORK"
  fi
  [ -n "$F_KEEP" ] && rm -f "$F_KEEP"
  [ -n "$F_LOCK" ] && rmdir "$F_LOCK" 2>/dev/null
  F_HDR=""; F_WORK=""; F_KEEP=""; F_LOCK=""
}
trap flush_cleanup EXIT
trap 'flush_cleanup; exit 0' INT TERM HUP

flush() {
  [ -s "$OUTBOX" ] || return 0
  if [ -z "$BASE" ]; then
    warn "no telemetry base URL (MC_BASE_URL or config telemetry.base_url): lines stay queued"
    return 0
  fi
  if [ ! -r "$TOKEN_FILE" ]; then
    warn "no token at $TOKEN_FILE: $(wc -l < "$OUTBOX" | tr -d ' ') line(s) stay queued"
    return 0
  fi
  command -v curl >/dev/null 2>&1 || { warn "curl missing: lines stay queued"; return 0; }

  # Single flusher: mkdir is atomic on every platform. Steal a lock older
  # than 10 minutes (a crashed flusher).
  local lock="$CM_HOME/outbox.lock"
  if ! mkdir "$lock" 2>/dev/null; then
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
      rmdir "$lock" 2>/dev/null; mkdir "$lock" 2>/dev/null || return 0
    else
      return 0
    fi
  fi
  F_LOCK="$lock"

  local line ep body code="" sent=0 kept=0 dead=0 net_down=0 n=0 token started
  F_WORK="$CM_HOME/outbox.flushing.$$"
  F_KEEP="$CM_HOME/outbox.keep.$$"
  mv "$OUTBOX" "$F_WORK" 2>/dev/null || { flush_cleanup; return 0; }
  : > "$F_KEEP"
  F_HDR="$(umask 077; mktemp "${TMPDIR:-/tmp}/mc-hdr.XXXXXX")"
  IFS= read -r token < "$TOKEN_FILE" || true
  printf 'X-MC-Token: %s\nContent-Type: application/json\n' "$token" > "$F_HDR"
  token=""
  started="$(date +%s)"

  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1)); F_POS="$n"
    [ -n "$line" ] || continue
    # Bounded: BATCH lines and MAX_SECS seconds per run; the rest waits.
    if [ "$net_down" -eq 1 ] || [ "$sent" -ge "$BATCH" ] || [ $(( $(date +%s) - started )) -ge "$MAX_SECS" ]; then
      printf '%s\n' "$line" >> "$F_KEEP"; kept=$((kept + 1)); continue
    fi
    ep="$(printf '%s' "$line" | jq -r '.endpoint // empty' 2>/dev/null)"
    body="$(printf '%s' "$line" | jq -c '.body // empty' 2>/dev/null)"
    if [ -z "$ep" ] || [ -z "$body" ]; then
      printf '%s\n' "$line" >> "$DEAD"; dead=$((dead + 1)); continue
    fi
    code="$(printf '%s' "$body" | curl -sS --max-time 5 -o /dev/null -w '%{http_code}' \
              -X POST -H "@$F_HDR" --data-binary @- "$BASE$ep" 2>/dev/null)" || code="${code:-000}"
    case "$code" in
      2??) sent=$((sent + 1)) ;;
      000) net_down=1; kept=$((kept + 1)); printf '%s\n' "$line" >> "$F_KEEP" ;;
      # Auth failure: every later line would fail too, so stop the batch now.
      401|403) net_down=1; kept=$((kept + 1)); printf '%s\n' "$line" >> "$F_KEEP" ;;
      # Timeout and rate limit are about the endpoint, not the line: retry.
      408|429) kept=$((kept + 1)); printf '%s\n' "$line" >> "$F_KEEP" ;;
      # Any other 4xx will never succeed: dead-letter it instead of retrying forever.
      4??) dead=$((dead + 1)); jq -c --arg c "$code" '. + {deadCode: ($c | tonumber)}' <<<"$line" >> "$DEAD" 2>/dev/null \
             || printf '%s\n' "$line" >> "$DEAD" ;;
      *)   kept=$((kept + 1)); printf '%s\n' "$line" >> "$F_KEEP" ;;
    esac
  done < "$F_WORK"
  rm -f "$F_HDR" "$F_WORK"; F_HDR=""; F_WORK=""; F_POS=0

  # Survivors go back, appended after anything queued meanwhile; cap growth.
  if [ -s "$F_KEEP" ]; then
    cat "$F_KEEP" >> "$OUTBOX"
    if [ "$(wc -l < "$OUTBOX" | tr -d ' ')" -gt "$MAX_LINES" ]; then
      tail -n "$MAX_LINES" "$OUTBOX" > "$F_KEEP.cap" && mv "$F_KEEP.cap" "$OUTBOX"
      warn "outbox capped at $MAX_LINES lines (oldest dropped)"
    fi
  fi
  flush_cleanup
  [ "$kept" -eq 0 ] && [ "$dead" -eq 0 ] || warn "sent=$sent kept=$kept dead=$dead (last http ${code:-none})"
  return 0
}

case "${1:-}" in
  --flush)
    flush ;;
  --fleet-upsert)
    shift
    if [ $# -lt 5 ]; then warn "usage: --fleet-upsert <agentId> <name> <status> <currentTask> <workspace> [hiddenFromUI]"; exit 0; fi
    body="$(jq -cn --arg t "$TENANT" --arg a "$1" --arg n "$2" --arg s "$3" --arg c "$4" --arg w "$5" \
              --arg h "${6:-false}" \
      '{tenantId:(if $t == "" then null else $t end), agentId:$a, name:$n, status:$s,
        currentTask:$c, workspace:$w, hiddenFromUI:($h == "true")}')" \
      && enqueue /api/fleet/upsert "$body"
    flush ;;
  ''|-h|--help)
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" ;;
  *)
    type="$1"; msg="${2:-}"; meta="${3:-}"
    [ -n "$meta" ] || meta='{}'
    printf '%s' "$meta" | jq -e 'type == "object"' >/dev/null 2>&1 \
      || meta="$(jq -cn --arg raw "$meta" '{raw:$raw}')"
    body="$(jq -cn --arg t "$TENANT" --arg type "$type" --arg m "$msg" --argjson meta "$meta" \
              --arg host "$HOSTNAME_S" --argjson ts "$NOW_MS" \
      '{tenantId:(if $t == "" then null else $t end), type:$type, message:$m,
        metadata:({source:"concertmaster", host:$host} + $meta), timestamp:$ts}')" \
      && enqueue /api/events "$body"
    flush ;;
esac
exit 0
