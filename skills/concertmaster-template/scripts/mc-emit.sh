#!/usr/bin/env bash
# mc-emit.sh: queue an event for the telemetry sink (a mission-control style
# dashboard), then try to flush the queue. Optional: with no base URL or
# tenant configured, lines are queued and never sent.
#
#   mc-emit.sh <type> <message> [metadata-json]
#   mc-emit.sh --fleet-upsert <agentId> <name> <status> <currentTask> <workspace> [hiddenFromUI]
#   mc-emit.sh --tick <fleetSummaryJson>     # PROVISIONAL type, see below
#   mc-emit.sh --issue-state <issue> <state> [pr]   # PROVISIONAL type, see below
#   mc-emit.sh --flush                      # retry queued lines only
#   mc-emit.sh --requeue-dead [--any-tenant] # move tenant-less (or any) 400 lines back
#   mc-emit.sh --version                    # MC_EMIT_VERSION of this copy
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
# No tenant configured: a flush sends NOTHING and lines stay queued, up to the
# MC_OUTBOX_MAX cap (one warning per call),
# because the sink answers 400 to tenantId null and that would
# dead-letter the line for a config reason. Lines queued without a tenant get
# the configured one filled in when they are sent. --requeue-dead moves dead
# lines with deadCode 400 and body.tenantId null back into the outbox with the
# tenant set (deadCode dropped), after a timestamped backup of the dead file
# (the newest 5 backups are kept). They go IN FRONT of the queued lines,
# oldest first; a fleet upsert superseded by a newer one for the same agentId
# (requeued or queued) is dropped, so replay never reverts fleet state. It
# refuses when no tenant is configured or when the result would pass the cap
# (flush first), and moves nothing on a second run. A requeued /api/events
# line also gets the configured projectId when it has none, and an eventId
# when it has none: "rq-" plus a sha256 of its body (tenantId and projectId
# left out), queuedAt and its line number in the dead file, so requeueing the
# same dead file twice yields the same ids and the sink dedupes the replay.
# A dead line naming a projectId other than the configured one is never
# picked, and neither is a fleet upsert while a project id is set.
#
# Cap: the outbox never holds more than MC_OUTBOX_MAX lines. Over the cap it
# is trimmed to 90% (oldest dropped), so a full outbox is not rewritten on
# every call; each trim is a line in $CM_HOME/outbox.dropped (written even
# with MC_QUIET=1; its newest 200 lines are kept). The dead file keeps its
# newest MC_OUTBOX_MAX lines. Rewrites of the outbox (cap, requeue) and every
# enqueue take the short write lock outbox.wlock, so no append is lost.
#
# Fleet order: $CM_HOME/fleet.sent.json records, per agentId, the queuedAt
# of the newest fleet upsert the sink accepted. A flush or requeue
# never sends an upsert older than that, and lines a flush could not send go
# back IN FRONT of the outbox, so a backlog never overwrites newer state.
# MC_NO_FLUSH=1 queues without flushing (one flush at the end of a tick).
# Draining a large backlog: MC_FLUSH_BATCH=500 MC_FLUSH_SECS=300 --flush,
# repeated while `wc -l outbox.jsonl` falls; it stops on 401/403/408/429.
#
# Installed copies (~/.concertmaster/bin, references/hooks-install.md) share
# this outbox. A copy older than MC_EMIT_VERSION 2 POSTs tenantId null and
# dead-letters lines this copy kept; one older than 3 never sends a projectId,
# so a project-bound token answers 400 to every event it flushes. This copy
# warns when it finds one. Re-copy on every host; --requeue-dead recovers
# what an old copy killed.
#
# PROVISIONAL: --tick and --issue-state post to /api/events with the types in
# TYPE_TICK and TYPE_ISSUE_STATE. The real contract belongs to your sink and
# may differ: change the constant, not callers.
#
# Endpoints (base $MC_BASE_URL, else config telemetry.base_url; no default):
#   POST /api/events        {tenantId,type,message,metadata,timestamp[,projectId][,eventId]}
#   POST /api/fleet/upsert  {tenantId,agentId,name,status,currentTask,workspace,hiddenFromUI}
#
# Project-bound tokens: MC_PROJECT_ID, else a MC_PROJECT_ID= line in mc.env,
# else config telemetry.project_id. A token bound to projects may call only
# /api/events and must name one of its projects on every write, so with a
# project id set every /api/events body carries projectId (lines queued
# before it was set get it filled in when sent, like the tenant; an existing
# projectId is never rewritten). A value that does not match
# ^p_[a-z0-9][a-z0-9-]{0,38}$ is not sent, with one warning per call; empty
# or invalid means no projectId at all (never null: the sink answers 400).
# With a project id set, --fleet-upsert queues nothing and logs one line
# (the sink refuses /api/fleet/upsert to a bound token; $CM_HOME/fleet.skipped
# holds the latest skip, even with MC_QUIET=1); see fleet_event.
# A 403 on /api/fleet/upsert is a route refusal, not a token one (a bad token
# is 401), so that line is dead-lettered with deadCode 403 instead of
# blocking the queue.
#
# Auth: header X-MC-Token read from $MC_TOKEN_FILE (else config
# telemetry.token_file, else ~/.secrets/mc-auth-token). The token never touches argv: it goes into a
# 0600 header file passed as `-H @file`. No token file: lines stay queued.
#
# --requeue-dead --any-tenant also picks 400 lines that carried a tenant (a
# typo'd tenant dead-letters the backlog) and sets the configured one.
#
# Config: MC_TENANT_ID, else config telemetry.tenant_id (unset: nothing is
# sent, lines stay queued). Also read, without executing, from $CM_HOME/mc.env
# lines MC_TENANT_ID=... and
# MC_BASE_URL=... (an `export ` prefix, quotes, CR and edge spaces are
# stripped). A tenant holding `<`, `>`, a quote or whitespace (an unfilled
# `<...>` placeholder, say) is treated as unset, with a warning and the
# marker file $CM_HOME/mc-emit.tenant-rejected (visible to quiet hooks).
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

MC_EMIT_VERSION=3

# trim: drop CR, edge spaces and one pair of surrounding quotes.
trim() { printf '%s' "$1" | tr -d '\r' | sed "s/^[[:space:]]*//; s/[[:space:]]*\$//; s/^[\"']//; s/[\"']\$//"; }
# Values from mc.env, parsed (never sourced). Env wins over the file.
cfg() {
  [ -f "$CM_HOME/mc.env" ] || return 0
  trim "$(sed -n "s/^[[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}$1=//p" "$CM_HOME/mc.env" | tail -n 1)"
}
TENANT="$(trim "${MC_TENANT_ID:-$(cfg MC_TENANT_ID)}")"
BASE="${MC_BASE_URL:-$(cfg MC_BASE_URL)}"
# Config fallbacks (config.yaml, when lib.sh found one). The base URL and the
# tenant are required config values: there is no built-in default for either.
if [ -z "$BASE" ] && command -v cm_cfg >/dev/null 2>&1; then BASE="$(cm_cfg .telemetry.base_url)"; fi
if [ -z "$TENANT" ] && command -v cm_cfg >/dev/null 2>&1; then TENANT="$(trim "$(cm_cfg .telemetry.tenant_id)")"; fi
PROJECT="$(trim "${MC_PROJECT_ID:-$(cfg MC_PROJECT_ID)}")"
if [ -z "$PROJECT" ] && command -v cm_cfg >/dev/null 2>&1; then PROJECT="$(trim "$(cm_cfg .telemetry.project_id)")"; fi
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
SENT="$CM_HOME/fleet.sent.json"
TYPE_TICK="concertmaster.tick"    # PROVISIONAL: your sink's contract
TYPE_ISSUE_STATE="issue.state"    # PROVISIONAL: your sink's contract

warn() { [ "${MC_QUIET:-0}" = 1 ] || printf 'mc-emit: %s\n' "$*" >&2; }

command -v jq >/dev/null 2>&1 || { warn "jq missing: event dropped"; exit 0; }
mkdir -p "$CM_HOME" 2>/dev/null || { warn "cannot create $CM_HOME"; exit 0; }
case "$TENANT" in
  '') ;;
  *'<'*|*'>'*|*'"'*|*"'"*|*[[:space:]]*)
    warn "MC_TENANT_ID '$TENANT' is not a tenant id: treated as unset"
    printf 'MC_TENANT_ID %s rejected at %s: placeholder, quote or whitespace\n' "$TENANT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      > "$CM_HOME/mc-emit.tenant-rejected" 2>/dev/null
    TENANT="" ;;
  *) rm -f "$CM_HOME/mc-emit.tenant-rejected" ;;
esac
# The sink's PROJECT_ID_PATTERN, ^p_[a-z0-9][a-z0-9-]{0,38}$, spelled out as
# case sets so no locale or regex flavour can widen [a-z].
valid_project() {
  case "$1" in p_[abcdefghijklmnopqrstuvwxyz0123456789]*) ;; *) return 1 ;; esac
  case "${1#p_}" in *[!abcdefghijklmnopqrstuvwxyz0123456789-]*) return 1 ;; esac
  [ "${#1}" -le 41 ]
}
if [ -n "$PROJECT" ] && ! valid_project "$PROJECT"; then
  warn "project id '$PROJECT' is not a p_<owner> id: no projectId sent"
  PROJECT=""
fi

NOW_MS="$(date +%s)000"
HOSTNAME_S="$(hostname 2>/dev/null | cut -d. -f1)"

# wlock_take / wlock_drop: the short write lock. Held only for one append or
# one outbox rewrite (milliseconds), never across network calls, so appends
# and rewrites never interleave. Waits up to 2s; a lock older than a minute
# (a crashed holder) is stolen. 1 when not taken.
wlock_take() {
  local w="$CM_HOME/outbox.wlock" i=0
  until mkdir "$w" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -le 40 ] || return 1
    # Stale (a crashed holder): steal it; a failed steal still counts a try.
    if [ -n "$(find "$w" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rmdir "$w" 2>/dev/null && continue; fi
    sleep 0.05
  done
  F_WLOCK="$w"
}
wlock_drop() { [ -z "$F_WLOCK" ] || rmdir "$F_WLOCK" 2>/dev/null; F_WLOCK=""; }

# prepend_outbox <file>: put the file's lines IN FRONT of the outbox (they are
# older than anything queued meanwhile), under the write lock. On any failure
# the lines are appended instead: out of order beats lost.
prepend_outbox() {
  [ -s "$1" ] || return 0
  local held=0
  wlock_take && held=1
  if [ "$held" = 1 ] && { cat "$1" && { [ ! -f "$OUTBOX" ] || cat "$OUTBOX"; }; } > "$OUTBOX.pre.$$" \
     && mv "$OUTBOX.pre.$$" "$OUTBOX"; then :
  else
    rm -f "$OUTBOX.pre.$$"; cat "$1" >> "$OUTBOX"
  fi
  [ "$held" = 0 ] || wlock_drop
}

# upsert_stale <line>: true when the line is a fleet upsert older than the
# newest upsert the sink already accepted for its agentId.
upsert_stale() {
  [ -s "$SENT" ] || return 1
  [ "$(printf '%s' "$1" | jq -r --slurpfile s "$SENT" \
        'if .endpoint == "/api/fleet/upsert"
         then ((.queuedAt // 0) < ($s[0][.body.agentId | tostring] // -1)) else false end' 2>/dev/null)" = true ]
}

# mark_sent <line>: record an accepted fleet upsert's queuedAt for its agentId.
mark_sent() {
  local id q
  id="$(printf '%s' "$1" | jq -r 'select(.endpoint == "/api/fleet/upsert") | .body.agentId | tostring' 2>/dev/null)"
  [ -n "$id" ] || return 0
  q="$(printf '%s' "$1" | jq -r '.queuedAt // 0' 2>/dev/null)"
  { [ -s "$SENT" ] && cat "$SENT" || echo '{}'; } \
    | jq -c --arg id "$id" --argjson q "${q:-0}" '.[$id] = ([(.[$id] // 0), $q] | max)' > "$SENT.$$" 2>/dev/null \
    && mv "$SENT.$$" "$SENT" || rm -f "$SENT.$$"
}

enqueue() {
  # enqueue <endpoint> <body-json>. No write lock in 2s: append anyway, a
  # line risked in a rare race beats a line surely dropped.
  local line
  line="$(jq -cn --arg ep "$1" --argjson body "$2" --argjson q "$NOW_MS" \
    '{endpoint:$ep, body:$body, queuedAt:$q}' 2>/dev/null)" || { warn "could not queue line"; return 0; }
  wlock_take || warn "write lock busy: appending without it"
  printf '%s\n' "$line" >> "$OUTBOX" 2>/dev/null || warn "could not queue line"
  wlock_drop
}

# trim_file <file> <keep-lines>: keep the newest lines; the caller holds the
# lock that guards the file. Prints how many lines were dropped.
trim_file() {
  local n
  n="$( (wc -l < "$1") 2>/dev/null | tr -d ' ')"
  if [ "${n:-0}" -gt "$2" ] && tail -n "$2" "$1" > "$1.trim.$$" && mv "$1.trim.$$" "$1"; then
    echo $((n - $2))
  else
    rm -f "$1.trim.$$"; echo 0
  fi
}

# take_lock: the single-flusher lock. mkdir is atomic on every platform; a
# lock older than 10 minutes (a crashed flusher) is stolen. 1 when held.
take_lock() {
  local lock="$CM_HOME/outbox.lock"
  if ! mkdir "$lock" 2>/dev/null; then
    [ -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ] || return 1
    rmdir "$lock" 2>/dev/null; mkdir "$lock" 2>/dev/null || return 1
  fi
  F_LOCK="$lock"
}

# cap_queue: over MAX_LINES, trim the outbox to 90% (at least one line) and
# record the drop in outbox.dropped (visible even when MC_QUIET hides the
# warning; its newest 200 lines kept), all in one write-lock hold. Needs no
# flush lock, so every call caps, whoever is flushing.
cap_queue() {
  local n low dropped=0
  n="$( (wc -l < "$OUTBOX") 2>/dev/null | tr -d ' ')"
  [ "${n:-0}" -gt "$MAX_LINES" ] || return 0
  wlock_take || return 0
  low=$((MAX_LINES * 9 / 10)); [ "$low" -ge 1 ] || low=1
  n="$( (wc -l < "$OUTBOX") 2>/dev/null | tr -d ' ')"
  if [ "${n:-0}" -gt "$MAX_LINES" ]; then
    dropped="$(trim_file "$OUTBOX" "$low")"
    if [ "$dropped" -gt 0 ]; then
      printf '{"at":%s,"dropped":%s,"cap":%s}\n' "$(date +%s)000" "$dropped" "$MAX_LINES" >> "$CM_HOME/outbox.dropped"
      trim_file "$CM_HOME/outbox.dropped" 200 >/dev/null
    fi
  fi
  wlock_drop
  [ "$dropped" -eq 0 ] || warn "outbox over $MAX_LINES lines: $dropped oldest dropped (see $CM_HOME/outbox.dropped)"
}

# cap_dead: with the flush lock held (only flush and requeue write the dead
# file), keep its newest MAX_LINES lines.
cap_dead() { [ ! -f "$DEAD" ] || trim_file "$DEAD" "$MAX_LINES" >/dev/null; }

# stale_install_check: warn when the installed hook copy predates this one.
stale_install_check() {
  local inst="${CM_INSTALLED_EMIT:-$HOME/.concertmaster/bin/mc-emit.sh}" v
  [ -f "$inst" ] || return 0
  [ "$(cd "$(dirname "$inst")" && pwd -P)/$(basename "$inst")" = "$HERE/$(basename "$0")" ] && return 0
  v="$(sed -n 's/^MC_EMIT_VERSION=\([0-9][0-9]*\).*/\1/p' "$inst" | head -n 1)"
  [ "${v:-0}" -ge "$MC_EMIT_VERSION" ] && return 0
  warn "$inst is MC_EMIT_VERSION ${v:-1}, older than $MC_EMIT_VERSION: it dead-letters tenant-less or project-less lines; re-copy it (references/hooks-install.md)"
}

# State shared with the cleanup trap, so an interrupted flush never leaks the
# header file or loses queued lines (at-least-once: a line in flight may be
# sent twice, never dropped).
F_HDR=""
F_WORK=""
F_KEEP=""
F_LOCK=""
F_WLOCK=""
F_POS=0
F_RQ_RAW=""; F_RQ_MOVE=""; F_RQ_KEEP=""; F_RQ_NEW=""; F_RQ_IDS=""; F_RQ_SUM=""   # requeue temp files

flush_cleanup() {
  [ -n "$F_HDR" ] && rm -f "$F_HDR"
  local t
  for t in "$F_RQ_RAW" "$F_RQ_MOVE" "$F_RQ_KEEP" "$F_RQ_NEW" "$F_RQ_IDS" "$F_RQ_SUM"; do [ -z "$t" ] || rm -f "$t"; done
  if [ -n "$F_WORK" ] && [ -f "$F_WORK" ]; then
    # Interrupted mid-flush: kept lines plus everything from the line in
    # flight on go back in front (the in-flight one may be sent twice).
    {
      [ -z "$F_KEEP" ] || [ ! -s "$F_KEEP" ] || cat "$F_KEEP"
      if [ "$F_POS" -gt 0 ]; then tail -n +"$F_POS" "$F_WORK"; else cat "$F_WORK"; fi
    } > "$F_WORK.back" 2>/dev/null
    prepend_outbox "$F_WORK.back"
    rm -f "$F_WORK" "$F_WORK.back"
  fi
  [ -n "$F_KEEP" ] && rm -f "$F_KEEP"
  wlock_drop
  [ -n "$F_LOCK" ] && rmdir "$F_LOCK" 2>/dev/null
  F_HDR=""; F_WORK=""; F_KEEP=""; F_LOCK=""
  F_RQ_RAW=""; F_RQ_MOVE=""; F_RQ_KEEP=""; F_RQ_NEW=""; F_RQ_IDS=""; F_RQ_SUM=""
}
trap flush_cleanup EXIT
trap 'flush_cleanup; exit 0' INT TERM HUP

flush() {
  [ -s "$OUTBOX" ] || return 0
  stale_install_check
  cap_queue
  # Single flusher. Held by another: it sends, nothing more to do here.
  take_lock || return 0
  # A flusher killed outright (SIGKILL) leaves outbox.flushing.<pid>: its
  # lines go back in front (some may be sent twice, none lost).
  local orphan opid
  for orphan in "$CM_HOME"/outbox.flushing.*; do
    [ -f "$orphan" ] || continue
    opid="${orphan##*.}"
    case "$opid" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$opid" 2>/dev/null && continue
    prepend_outbox "$orphan" && rm -f "$orphan" "$CM_HOME/outbox.keep.$opid"
  done
  [ -s "$OUTBOX" ] || { flush_cleanup; return 0; }
  # The sink answers 400 to tenantId null: sending would dead-letter
  # every line for a config reason, so send nothing until a tenant is set.
  # Nothing sent still means capped: the outbox never grows without bound.
  local why=""
  if [ -z "$BASE" ]; then why="no base URL (MC_BASE_URL or config telemetry.base_url): nothing sent"
  elif [ -z "$TENANT" ]; then why="MC_TENANT_ID unset: nothing sent"
  elif [ ! -r "$TOKEN_FILE" ]; then why="no token at $TOKEN_FILE"
  elif ! command -v curl >/dev/null 2>&1; then why="curl missing"; fi
  if [ -n "$why" ]; then
    cap_dead
    warn "$why, $(wc -l < "$OUTBOX" | tr -d ' ') line(s) stay queued"
    flush_cleanup; return 0
  fi

  local line ep body code="" sent=0 kept=0 dead=0 stale=0 net_down=0 n=0 token started
  F_WORK="$CM_HOME/outbox.flushing.$$"
  F_KEEP="$CM_HOME/outbox.keep.$$"
  wlock_take || true
  mv "$OUTBOX" "$F_WORK" 2>/dev/null || { flush_cleanup; return 0; }
  wlock_drop
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
    # A line queued before the tenant (or the project id) was configured
    # carries tenantId null (or no projectId). Only events take a projectId.
    body="$(printf '%s' "$line" | jq -c --arg t "$TENANT" --arg p "$PROJECT" --arg ep "$ep" \
              '.body // empty | if type == "object" then
                 (if (.tenantId // "") == "" then .tenantId = $t else . end)
                 | (if $ep == "/api/events" and $p != "" and (has("projectId") | not) then .projectId = $p else . end)
               else . end' 2>/dev/null)"
    # Only the two known endpoints: "$BASE$ep" with any other value could
    # send the token elsewhere (an "@host" endpoint rewrites the URL).
    case "$ep" in /api/events|/api/fleet/upsert) ;; *) ep="" ;; esac
    if [ -z "$ep" ] || [ -z "$body" ]; then
      printf '%s\n' "$line" >> "$DEAD"; dead=$((dead + 1)); continue
    fi
    # Older than an upsert already accepted for this agent: sending it would
    # revert the fleet board, so drop it.
    if upsert_stale "$line"; then stale=$((stale + 1)); continue; fi
    code="$(printf '%s' "$body" | curl -sS --max-time 5 -o /dev/null -w '%{http_code}' \
              -X POST -H "@$F_HDR" --data-binary @- "$BASE$ep" 2>/dev/null)" || code="${code:-000}"
    case "$code" in
      2??) sent=$((sent + 1)); mark_sent "$line" ;;
      000) net_down=1; kept=$((kept + 1)); printf '%s\n' "$line" >> "$F_KEEP" ;;
      # The sink refuses /api/fleet/upsert to a project-bound or shared token
      # with 403 every time: dead-letter it like a 400, the batch goes on.
      403) if [ "$ep" = /api/fleet/upsert ]; then
             dead=$((dead + 1)); jq -c --argjson b "$body" '.body = $b | . + {deadCode: 403}' <<<"$line" >> "$DEAD" 2>/dev/null \
               || printf '%s\n' "$line" >> "$DEAD"
           else net_down=1; kept=$((kept + 1)); printf '%s\n' "$line" >> "$F_KEEP"; fi ;;
      # Auth failure: every later line would fail too, so stop the batch now.
      401) net_down=1; kept=$((kept + 1)); printf '%s\n' "$line" >> "$F_KEEP" ;;
      # Timeout and rate limit are about the endpoint, not the line: keep it
      # and stop the batch, the next call retries.
      408|429) net_down=1; kept=$((kept + 1)); printf '%s\n' "$line" >> "$F_KEEP" ;;
      # Any other 4xx will never succeed: dead-letter it instead of retrying
      # forever. The record keeps the body as sent (tenant filled in), so a
      # 400 for any other reason never looks like a missing-tenant one.
      4??) dead=$((dead + 1)); jq -c --arg c "$code" --argjson b "$body" '.body = $b | . + {deadCode: ($c | tonumber)}' <<<"$line" >> "$DEAD" 2>/dev/null \
             || printf '%s\n' "$line" >> "$DEAD" ;;
      *)   kept=$((kept + 1)); printf '%s\n' "$line" >> "$F_KEEP" ;;
    esac
  done < "$F_WORK"
  rm -f "$F_HDR"; F_HDR=""
  # Survivors are older than anything queued meanwhile: back in front. Only
  # then forget the work file, so a signal in between can re-queue a line
  # twice but never lose one.
  prepend_outbox "$F_KEEP"; rm -f "$F_KEEP"; F_KEEP=""
  rm -f "$F_WORK"; F_WORK=""; F_POS=0
  cap_queue; cap_dead
  flush_cleanup
  [ "$kept" -eq 0 ] && [ "$dead" -eq 0 ] && [ "$stale" -eq 0 ] \
    || warn "sent=$sent kept=$kept dead=$dead stale=$stale (last http ${code:-none})"
  return 0
}

# requeue_dead: dead lines that failed only for want of a tenant go back, in
# front of the queue, oldest first, minus fleet upserts a newer upsert for the
# same agentId supersedes. Every step is checked; temp files are trapped.
# Order: backup, new outbox (under the write lock), new dead file. A failure
# before the new outbox changes nothing; one after it can only send a line
# twice. The picked and kept line counts must add up to the dead file's.
# Picked events get the project id and a deterministic eventId (stamp_ids).
requeue_dead() {
  local any=0
  [ "${1:-}" = "--any-tenant" ] && any=1
  if [ -z "$TENANT" ]; then
    warn "MC_TENANT_ID unset: nothing requeued (the lines would only fail again)"
    return 0
  fi
  if [ ! -s "$DEAD" ]; then echo "requeued 0 line(s)"; return 0; fi
  # Same lock as flush: a flush appends to the dead file and rewrites the outbox.
  take_lock || { warn "a flush holds $CM_HOME/outbox.lock: nothing requeued, try again"; return 0; }
  F_RQ_RAW="$DEAD.raw.$$"; F_RQ_MOVE="$DEAD.move.$$"; F_RQ_KEEP="$DEAD.keep.$$"; F_RQ_NEW="$OUTBOX.requeue.$$"
  F_RQ_IDS="$OUTBOX.ids.$$"; F_RQ_SUM="$DEAD.sum.$$"
  local total picked kept moved superseded queued stamp bak
  # Lines are read raw so one malformed line never blocks the rest.
  # shellcheck disable=SC2016  # jq programs: $o, $t, $newer, $sent are jq, not shell
  # A line naming another project stays dead (never rewritten), and so does a
  # fleet upsert while a project id is set (a bound token gets 403 there).
  local pick='(try fromjson catch null) as $o
    | ($o | type == "object") and $o.deadCode == 400
      and ($o.body | type == "object") and ($any or $o.body.tenantId == null)
      and (($o.body | has("projectId") | not) or $o.body.projectId == $p)
      and ($p == "" or $o.endpoint != "/api/fleet/upsert")'
  # shellcheck disable=SC2016
  # Newest per agentId only, none queued for it already, none older than one
  # the sink accepted (fleet.sent.json).
  local latest='($newer[0] // []) as $nw | ($sent[0] // {}) as $sn
    | sort_by(.queuedAt // 0) as $a
    | (reduce range(0; $a | length) as $i ({};
        if $a[$i].endpoint == "/api/fleet/upsert" then .[$a[$i].body.agentId | tostring] = $i else . end)) as $last
    | $a | to_entries[]
    | select(.value.endpoint != "/api/fleet/upsert"
             or ((.value.body.agentId | tostring) as $id
                 | $last[$id] == .key and (any($nw[]; . == $id) | not)
                   and (.value.queuedAt // 0) >= ($sn[$id] // -1)))
    | .value'
  # Queued upsert agentIds and the sent record go through files, not argv
  # (a long queue would pass the per-argument size limit).
  { [ ! -f "$OUTBOX" ] || jq -R -c 'fromjson? | select(.endpoint == "/api/fleet/upsert") | .body.agentId | tostring' "$OUTBOX"; } 2>/dev/null \
    | jq -s -c 'unique' > "$F_RQ_IDS" 2>/dev/null || echo '[]' > "$F_RQ_IDS"
  [ -s "$SENT" ] || echo '{}' > "$SENT"
  local anyj=false; [ "$any" = 0 ] || anyj=true
  if ! total="$(jq -R -n '[inputs] | length' "$DEAD" 2>/dev/null)"; then
    warn "could not read $DEAD: nothing requeued"; flush_cleanup; echo "requeued 0 line(s)"; return 0
  fi
  # Events: projectId when absent, and _idsrc (the eventId hash input: body
  # minus tenantId and projectId, queuedAt, dead-file line number) when the
  # line has no eventId; stamp_ids turns _idsrc into eventId.
  # shellcheck disable=SC2016
  local stamp='input_line_number as $n | select('"$pick"') | fromjson | del(.deadCode)
    | (.body | del(.tenantId, .projectId) | tojson) as $src | .body.tenantId = $t
    | if .endpoint != "/api/events" then .
      else (if $p != "" and (.body | has("projectId") | not) then .body.projectId = $p else . end)
        | (if .body | has("eventId") then . else ._idsrc = "\($src)|\(.queuedAt)|\($n)" end) end'
  if ! jq -R -c --arg t "$TENANT" --arg p "$PROJECT" --argjson any "$anyj" "$stamp" "$DEAD" > "$F_RQ_RAW" 2>/dev/null \
     || ! jq -R -r --arg p "$PROJECT" --argjson any "$anyj" "select(($pick) | not)" "$DEAD" > "$F_RQ_KEEP" 2>/dev/null \
     || ! stamp_ids; then
    warn "could not split $DEAD (disk full?): nothing requeued"; flush_cleanup; echo "requeued 0 line(s)"; return 0
  fi
  if ! jq -s -c --slurpfile newer "$F_RQ_IDS" --slurpfile sent "$SENT" "$latest" "$F_RQ_RAW" > "$F_RQ_MOVE" 2>/dev/null; then
    warn "could not order the picked lines: nothing requeued"; flush_cleanup; echo "requeued 0 line(s)"; return 0
  fi
  picked="$(wc -l < "$F_RQ_RAW" | tr -d ' ')"; kept="$(wc -l < "$F_RQ_KEEP" | tr -d ' ')"
  if [ $((picked + kept)) -ne "$total" ]; then
    warn "$DEAD: $picked picked + $kept kept != $total lines: nothing requeued"
    flush_cleanup; echo "requeued 0 line(s)"; return 0
  fi
  moved="$(wc -l < "$F_RQ_MOVE" | tr -d ' ')"; superseded=$((picked - moved))
  queued="$( (wc -l < "$OUTBOX") 2>/dev/null | tr -d ' ')"
  if [ "$picked" -gt 0 ] && [ $(( ${queued:-0} + moved )) -gt "$MAX_LINES" ]; then
    warn "$moved line(s) + ${queued:-0} queued would pass the $MAX_LINES-line cap: nothing requeued; run --flush until the outbox drains, then retry"
    moved=0
  elif [ "$picked" -gt 0 ]; then
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"; bak="$DEAD.bak.$stamp.$$"
    if ! cp -p "$DEAD" "$bak"; then
      warn "backup failed: nothing requeued"; moved=0
    elif ! wlock_take; then
      warn "write lock busy: nothing requeued, try again (backup: $bak)"; moved=0
    elif ! { cat "$F_RQ_MOVE" && { [ ! -f "$OUTBOX" ] || cat "$OUTBOX"; }; } > "$F_RQ_NEW" \
         || ! mv "$F_RQ_NEW" "$OUTBOX"; then
      wlock_drop
      warn "could not write the outbox: nothing requeued (backup: $bak)"; moved=0
    else
      wlock_drop
      echo "backup: $bak"
      [ "$superseded" -eq 0 ] || echo "dropped $superseded superseded or already-overtaken fleet upsert(s) (kept in the backup)"
      mv "$F_RQ_KEEP" "$DEAD" \
        || warn "dead file not rewritten: the $moved requeued line(s) may be sent twice (backup: $bak)"
      # Keep the newest 5 backups (names sort by their UTC stamp).
      find "$CM_HOME" -maxdepth 1 -name 'outbox.dead.jsonl.bak.*' 2>/dev/null | sort -r | tail -n +6 \
        | while IFS= read -r old; do rm -f -- "$old"; done
    fi
  fi
  flush_cleanup
  echo "requeued $moved line(s)"
}

# stamp_ids: in F_RQ_RAW, each line's _idsrc becomes body.eventId "rq-" + the
# first 40 hex of its sha256. One hasher run per such line.
stamp_ids() {
  local sha src h
  grep -q '"_idsrc"' "$F_RQ_RAW" || return 0
  if command -v sha256sum >/dev/null 2>&1; then sha="sha256sum"
  elif command -v shasum >/dev/null 2>&1; then sha="shasum -a 256"
  else warn "no sha256sum or shasum: cannot give requeued events an eventId"; return 1; fi
  jq -r '._idsrc // ""' "$F_RQ_RAW" | while IFS= read -r src; do
    if [ -z "$src" ]; then echo; else h="$(printf '%s' "$src" | $sha)"; printf '%s\n' "${h:0:40}"; fi
  done | jq -R . | jq -s -c . > "$F_RQ_SUM" || return 1
  jq -s -c --slurpfile h "$F_RQ_SUM" \
    'to_entries[] | ($h[0][.key] // "") as $x | .value
     | if $x == "" then . else del(._idsrc) | .body.eventId = ("rq-" + $x) end' "$F_RQ_RAW" > "$F_RQ_MOVE" \
    && mv "$F_RQ_MOVE" "$F_RQ_RAW"
}

# event_body <type> <message> <metadata-object-json>: one /api/events body,
# with projectId only when a valid project id is set (never null).
event_body() {
  jq -cn --arg t "$TENANT" --arg p "$PROJECT" --arg type "$1" --arg m "$2" --argjson meta "$3" \
        --arg host "$HOSTNAME_S" --argjson ts "$NOW_MS" \
    '{tenantId:(if $t == "" then null else $t end), type:$type, message:$m,
      metadata:({source:"concertmaster", host:$host} + $meta), timestamp:$ts}
     + (if $p == "" then {} else {projectId:$p} end)'
}

# fleet_event: the hook point for fleet state under a project-bound token.
# TODO(mission-control#533): post the typed fleet events (lane.state,
# issue.state, fleet.snapshot, each with an eventId) to /api/events once that
# contract is on the sink's main. Until then fleet state is not reported with a
# project id set: nothing is queued (a legacy upsert would only 403) and one
# line says so, on stderr and in $CM_HOME/fleet.skipped (the latest skip only,
# written even with MC_QUIET=1, which the worker hook sets).
fleet_event() {
  warn "project id set: fleet upsert for $1 not sent (bound tokens may not call /api/fleet/upsert; typed fleet events pending mission-control#533)"
  jq -cn --arg a "$1" --argjson at "$NOW_MS" \
    '{at:$at, agentId:$a, reason:"project-bound token: /api/fleet/upsert not called, typed fleet events pending mission-control#533"}' \
    > "$CM_HOME/fleet.skipped" 2>/dev/null
}

# as_object <json>: the value when it is a JSON object, else {raw:<text>}.
as_object() {
  if printf '%s' "$1" | jq -e 'type == "object"' >/dev/null 2>&1; then printf '%s' "$1"
  else jq -cn --arg raw "$1" '{raw:$raw}'; fi
}

case "${1:-}" in
  --version)
    echo "$MC_EMIT_VERSION" ;;
  --flush)
    flush ;;
  --requeue-dead)
    case "${2:-}" in ''|--any-tenant) requeue_dead "${2:-}" ;; *) warn "usage: --requeue-dead [--any-tenant]" ;; esac ;;
  --tick)
    summary="$(as_object "${2:-}")"
    msg="$(printf '%s' "$summary" | jq -r '.summary // "concertmaster tick" | tostring')"
    if body="$(event_body "$TYPE_TICK" "$msg" "$(jq -cn --argjson f "$summary" '{fleet:$f}')")"; then enqueue /api/events "$body"
    else warn "could not build the event: dropped"; fi
    [ "${MC_NO_FLUSH:-0}" = 1 ] || flush ;;
  --issue-state)
    shift
    issue="${1:-}"; issue="${issue#\#}"; pr="${3:-}"; pr="${pr#\#}"
    case "$issue" in ''|*[!0-9]*) warn "usage: --issue-state <issue> <state> [pr]"; exit 0 ;; esac
    case "$pr" in *[!0-9]*) warn "--issue-state: pr must be a number"; exit 0 ;; esac
    [ -n "${2:-}" ] || { warn "usage: --issue-state <issue> <state> [pr]"; exit 0; }
    meta="$(jq -cn --argjson i "$issue" --arg s "$2" --arg p "$pr" \
      '{issue:$i, state:$s, pr:(if $p == "" then null else ($p | tonumber) end)}')"
    if body="$(event_body "$TYPE_ISSUE_STATE" "#$issue $2" "$meta")"; then enqueue /api/events "$body"
    else warn "could not build the event: dropped"; fi
    [ "${MC_NO_FLUSH:-0}" = 1 ] || flush ;;
  --fleet-upsert)
    shift
    if [ $# -lt 5 ]; then warn "usage: --fleet-upsert <agentId> <name> <status> <currentTask> <workspace> [hiddenFromUI]"; exit 0; fi
    if [ -n "$PROJECT" ]; then fleet_event "$@"; exit 0; fi
    if body="$(jq -cn --arg t "$TENANT" --arg a "$1" --arg n "$2" --arg s "$3" --arg c "$4" --arg w "$5" \
              --arg h "${6:-false}" \
      '{tenantId:(if $t == "" then null else $t end), agentId:$a, name:$n, status:$s,
        currentTask:$c, workspace:$w, hiddenFromUI:($h == "true")}')"; then enqueue /api/fleet/upsert "$body"
    else warn "could not build the event: dropped"; fi
    [ "${MC_NO_FLUSH:-0}" = 1 ] || flush ;;
  ''|-h|--help)
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" ;;
  -*)
    warn "unknown option ${1}: nothing queued (see --help)" ;;
  *)
    meta="${3:-}"
    [ -n "$meta" ] || meta='{}'
    if body="$(event_body "$1" "${2:-}" "$(as_object "$meta")")"; then enqueue /api/events "$body"
    else warn "could not build the event: dropped"; fi
    [ "${MC_NO_FLUSH:-0}" = 1 ] || flush ;;
esac
exit 0
