#!/usr/bin/env bash
# backup-stale.sh: report an off-host backup that has not succeeded for too long.
#
#   scripts/backup-stale.sh              # one check, update state, alert once per episode
#   scripts/backup-stale.sh --dry-run    # print the decision; no note, no state, no telemetry event
#
# backup-offhost.sh writes $CM_HOME/cache/backup-offhost.json {ok_at, generation, host, remote_dir} when a
# generation is finished (a dry run and a failed run write nothing). This script reads that stamp: no ssh,
# no network, one small file, so the tick can run it every time (SKILL.md tick step 4). Older than the limit
# (CM_BACKUP_MAX_AGE_HOURS, config backup.max_age_hours, default 50: one missed night is not an alarm, two are)
# is an alert. No stamp yet counts from the first time this script saw none, so a new setup has the limit to
# make its first backup. backup.host unset means the owner has not asked for a backup: it says so and stays quiet.
#
# Where the alert goes: an inbox note $CM_HOME/inbox/backup-stale-<alert|cleared>-<UTC seconds>-<pid>.md (ONE
# glob, backup-stale-*.md, is what the tick reads) AND a telemetry event via mc-emit.sh (backup.stale /
# backup.fresh). Once per episode: the next good backup sends one "cleared". State:
# $CM_HOME/cache/backup-stale.json {first_seen, alerted, host, cfgnote}, written atomically. A note that cannot be
# written is not counted as sent: the episode stays open and the next tick tries again. A bad limit (backup.max_age_hours
# that is not a whole number of hours, 1 or more) writes one backup-stale-config note per bad value and exits 2.
# Exit 0 always except bad usage or a bad limit (2).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
  "") ;;
  *) cm_warn "backup-stale.sh: unknown arg: $1"; exit 2 ;;
esac
command -v jq >/dev/null 2>&1 || { cm_warn "backup-stale.sh: missing jq"; exit 0; }
isint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

HOST="${CM_BACKUP_HOST:-$(cm_cfg .backup.host)}"
MAXH="${CM_BACKUP_MAX_AGE_HOURS:-$(cm_cfg .backup.max_age_hours 50)}"
NOW="${CM_NOW:-$(date +%s)}"
isint "$NOW" || { cm_warn "backup-stale.sh: the clock must be a whole number"; exit 2; }
[ -n "$HOST" ] || { echo "backup-stale: backup.host is not set, no off-host backup is expected"; exit 0; }

STAMP="$CM_HOME/cache/backup-offhost.json"
STATE="$CM_HOME/cache/backup-stale.json"
mkdir -p "$CM_HOME/cache" "$CM_HOME/inbox" 2>/dev/null
num() { local v; v="$(jq -r --arg k "$1" '.[$k] // 0' "$2" 2>/dev/null)"; isint "$v" && echo "$v" || echo 0; }
first_seen="$(num first_seen "$STATE")"
alerted="$(jq -r '.alerted // false' "$STATE" 2>/dev/null)"; [ "$alerted" = true ] || alerted=false
state_host="$(jq -r '.host // empty' "$STATE" 2>/dev/null)"; cfgnote="$(jq -r '.cfgnote // empty' "$STATE" 2>/dev/null)"
ok_at="$(num ok_at "$STAMP")"; gen="$(jq -r '.generation // empty' "$STAMP" 2>/dev/null)"
# a stamp for another host (backup.host was changed) says nothing about this one
stamp_host="$(jq -r '.host // empty' "$STAMP" 2>/dev/null)"
if [ "$ok_at" -gt 0 ] && [ "$stamp_host" != "$HOST" ]; then
  echo "backup-stale: the last stamp names host '$stamp_host', not '$HOST': ignored"; ok_at=0; gen=""
fi

ts() { jq -n --argjson t "$NOW" '$t | strftime("%Y-%m-%dT%H:%M:%SZ")'; }
# note <kind: alert|cleared|config> <event> <text> <meta json>: 0 only when the inbox note was written. The telemetry
# event is a copy and may fail quietly; the inbox note is what the tick reads, so its failure keeps the episode open.
note() {
  [ "$DRY" = 1 ] && return 0
  printf '# backup-stale %s %s\n\n%s\n' "$1" "$(ts)" "$3" > "$CM_HOME/inbox/backup-stale-$1-$(date -u +%Y%m%dT%H%M%SZ)-$$.md" 2>/dev/null || return 1
  local meta="${4:-}"; [ -n "$meta" ] || meta="{}"
  if [ -x "$HERE/mc-emit.sh" ]; then MC_NO_FLUSH=1 "$HERE/mc-emit.sh" "$2" "$3" "$meta" >/dev/null 2>&1 || true; fi   # queue only: this check stays local, the tick flushes
  return 0
}
save() {
  [ "$DRY" = 1 ] && return
  jq -n --argjson f "$first_seen" --argjson a "$alerted" --arg h "$HOST" --arg c "$cfgnote" '{first_seen:$f,alerted:$a,host:$h,cfgnote:$c}' > "$STATE.tmp.$$" 2>/dev/null && mv "$STATE.tmp.$$" "$STATE"
}

# a limit that is not a whole number of hours (a typo such as 36h) writes one note for that value, so the tick shows it
if ! isint "$MAXH" || [ "$MAXH" -lt 1 ]; then
  cm_warn "backup-stale.sh: backup.max_age_hours must be a whole number of hours, 1 or more (got '$MAXH')"
  if [ "$cfgnote" != "$MAXH" ] && note config backup.stale "backup-stale cannot run: backup.max_age_hours must be a whole number of hours, 1 or more (got '$(printf '%s' "$MAXH" | LC_ALL=C tr -c '[:print:]' '?' | cut -c1-40)'). No stale-backup alarm until it is fixed." "{}"; then cfgnote="$MAXH"; fi
  save; exit 2
fi
cfgnote=""

# the state belongs to one host: another host starts again (new grace period, no open episode)
if [ "$state_host" != "$HOST" ]; then first_seen=0; alerted=false; fi
if [ "$ok_at" -gt 0 ]; then
  ref="$ok_at"; what="last good backup ${gen:+($gen) }"
  first_seen=0   # the next time there is no stamp (deleted, or a new host) the grace period starts then, not at an old time
  [ "$NOW" -ge "$ok_at" ] || echo "backup-stale: the stamp is in the future (clock change?): counted as 0 h old"
else
  [ "$first_seen" -gt 0 ] || first_seen="$NOW"
  ref="$first_seen"; what="no good backup recorded since this check first ran, "
fi
age_h=$(( (NOW - ref) / 3600 )); [ "$age_h" -ge 0 ] || age_h=0
if [ "$age_h" -ge "$MAXH" ]; then
  echo "backup-stale: ${what}${age_h} h ago (limit ${MAXH} h)"
  if [ "$alerted" != true ]; then
    msg="ALERT: the off-host backup to $HOST is stale: ${what}${age_h} h ago, limit ${MAXH} h. Check the cron log (~/.concertmaster/backup-offhost.log) and run scripts/backup-offhost.sh --check (references/recovery.md)."
    echo "backup-stale: $msg"
    if note alert backup.stale "$msg" "{\"age_h\":$age_h,\"limit_h\":$MAXH}"; then alerted=true; else cm_warn "backup-stale.sh: the inbox note could not be written: the alert will be tried again next tick"; fi
  fi
else
  echo "backup-stale: ${what}${age_h} h ago (limit ${MAXH} h), fine"
  # only a stamp for this host ends an episode: the grace period of a new setup (or of a changed backup.host) is not a backup
  if [ "$alerted" = true ] && [ "$ok_at" -gt 0 ]; then
    msg="CLEARED: the off-host backup to $HOST is fresh again (${what}${age_h} h ago)."
    echo "backup-stale: $msg"
    if note cleared backup.fresh "$msg" "{\"age_h\":$age_h}"; then alerted=false; else cm_warn "backup-stale.sh: the inbox note could not be written: the cleared note will be tried again next tick"; fi
  fi
fi
save
exit 0
