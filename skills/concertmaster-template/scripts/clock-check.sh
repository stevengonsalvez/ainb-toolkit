#!/usr/bin/env bash
# clock-check.sh: the clock and the deploy state, for the two deploy-window ask rules of SKILL.md (The tick: No owner question before a deploy is spawned; Deploy windows)
# (no blocking owner picker unless every window that is past-and-unfinished and the first window still ahead is pinned and
# has its own live deploy worker; check the clock right before any message that names a deploy time or a release).
# Read-only. Exit 0 always: a line it cannot fill says why, and every doubt answers "WAITING-row-only" (never "allowed").
#
#   scripts/clock-check.sh                       # key: value lines
#   CM_TEST=1 CM_NOW=2000-01-01T10:30:00Z scripts/clock-check.sh   # a stubbed clock (tests only: CM_NOW needs CM_TEST=1)
#
#   now:           UTC now (names CM_NOW when the clock is stubbed)
#   window:        the first window that was checked: the ledger deployWindows[].id (local date T HH:MM), then its UTC
#                  time; or none
#   minutes:       minutes from now to it (negative: it has passed)
#   row:           that window row's state, tag and prod run id, or none (what a message may say about the release)
#   deploy-worker: that row's worker and its state in the ledger workers, none, or unknown (ledger unreadable or missing)
#   state:         upcoming (still ahead), in-flight (a live deploy worker is on it), worker-dead (the row names a
#                  worker the ledger does not list live), shared-worker (the worker is named by two unfinished rows
#                  and covers neither), missed (it has passed and no deploy worker or outcome is on
#                  record), none (no window configured), unknown (see the other lines; also a past window while the
#                  ledger cannot be read: whether it shipped is not known)
#   next-window:   the first unfinished window still ahead (the one to cite for "the next release"), with its UTC time
#                  and the minutes to it, or none; the `window:` line can be an older missed window
#   window-check:  one line per checked window: <id> <state> worker <id or none> live|not live pinned|not pinned
#   picker:        allowed only when EVERY checked window is pinned AND has ITS OWN live deploy worker (the worker its
#                  own row names; one worker never covers another window), or when no window is unfinished. Otherwise
#                  WAITING-row-only. A wake still has to be armed before any picker.
#
# Windows come from cfg.schedule.deploy_windows in the zone CM_TZ (lib.sh: else cfg.schedule.timezone, else UTC),
# for yesterday, today and tomorrow, plus every unfinished deployWindows[] row of the ledger (its at is read as UTC). The
# checked entries are every unfinished row, in time order, that is past and still counting (a past one with no live worker
# stops counting after 12 hours; one with a live worker counts however old), and all the rows at the instant of the FIRST
# unfinished window still ahead, whatever its distance (later instants ahead are not checked). A window is
# pinned when its row state is staging, validating or prod, or the row carries a sha (7 to 64 hex digits, the trigger sha); a worker is live
# while the ledger lists it spawning, running or blocked-on-owner (stuck does not count: it needs the loop, and a
# picker stops the loop; a row with no state does not count), and only while a single unfinished window row names it: a
# worker named by two unfinished rows covers neither. Answers unknown, with WAITING-row-only, when: the config file is
# missing, empty or unparseable or has no deploy_windows key (an empty list is "none"); no deploy_windows entry is
# usable; a window time does not exist on its day (clocks going forward; known limit: it looks at yesterday, today and
# tomorrow, so the answer is unknown for all of those days, safe but wider than the one day with the gap); the zone is not
# on the host (checked against /usr/share/zoneinfo when that exists); the clock cannot be read. An entry that is not H:MM
# or HH:MM, or is out of range, is reported and skipped. It reads the ledger only: a release shipped by a tag push that
# left no deployWindows[] row reads as missed, which is the safe side (WAITING row). Needs GNU date (date -d), like the
# other Linux-only parts of the kit.
# Rows: every deployWindows[] row is its own entry and is never merged with, or dropped for, another. A configured window
# is the rows that name it (the same id, or the same instant: a moved or renamed one is that window, not a second one). A finished row (done, skipped,
# stopped) never removes an unfinished row for the same instant or id; every unfinished row at an instant is checked, and
# the window is covered only if each of them is pinned with its own live worker. A window with only finished rows is
# finished; with no row at all it is checked as having nothing on record. An unfinished row that cannot be placed in time
# (no usable at and no configured window of its id) makes the answer unknown, with a warning naming the row; a finished
# row with a bad time is ignored. A time is read only as ISO 8601 (never "yesterday" or a bare HH:MM). A deployWindows
# that is not a list of objects is unknown. An unreadable or missing ledger is unknown even with an empty window list.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"
case "${1:-}" in -h|--help) awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

unknown() { echo "window: none ($1)"; echo "next-window: unknown"; echo "state: unknown"; echo "picker: WAITING-row-only"; exit 0; }

tz="$CM_TZ"   # lib.sh: CM_TZ, else schedule.timezone, else UTC (the zone every other script uses)
# CM_NOW stubs the clock only under CM_TEST=1 (as the other test seams do): a leaked CM_NOW must never decide a real send
stub=0
if [ -n "${CM_NOW:-}" ]; then
  if [ "${CM_TEST:-}" = 1 ]; then stub=1; else echo "warning: CM_NOW is set but CM_TEST is not 1: the real clock is used"; fi
fi
if [ "$stub" = 1 ]; then now="$(date -u -d "$CM_NOW" +%s 2>/dev/null)"; else now="$(date -u +%s)"; fi
case "$now" in ''|*[!0-9]*) echo "now: unknown (CM_NOW is not a time GNU date reads)"; echo "next-window: unknown"; echo "state: unknown"; echo "picker: WAITING-row-only"; exit 0 ;; esac
if [ "$stub" = 1 ]; then echo "now: $(date -u -d "@$now" +%FT%TZ) (stubbed by CM_NOW: not the real clock)"; else echo "now: $(date -u -d "@$now" +%FT%TZ)"; fi

# the config must have been read and must carry the key: a missing, empty or unparseable file falls back to {} in lib.sh
wins="$(cm_cfg_json .schedule.deploy_windows null)"
if [ "$wins" = null ] || [ "$(printf '%s' "$wins" | jq -r 'type' 2>/dev/null)" != array ]; then
  unknown "schedule.deploy_windows is not in the config: the file is missing, empty or unparseable (CM_CONFIG=${CM_CONFIG:-unset}) or the key is absent"
fi

led="$(cm_ledger_path)"
ledger_ok=0
if [ -s "$led" ] && jq -e 'type == "object"' "$led" >/dev/null 2>&1; then ledger_ok=1; fi
today="$(TZ="$tz" date -d "@$now" +%F 2>/dev/null)"
# an unreadable or missing ledger is unknown whatever the window list says (an empty list cannot excuse it)
if [ "$ledger_ok" != 1 ] && [ "$(printf '%s' "$wins" | jq 'length' 2>/dev/null)" = 0 ]; then
  unknown "the ledger cannot be read, so unfinished deployWindows[] rows cannot be ruled out"
fi
if [ -d /usr/share/zoneinfo ] && [ "$tz" != UTC ] && [ ! -e "/usr/share/zoneinfo/$tz" ]; then
  unknown "$tz is not a time zone on this host: GNU date would read it as UTC"
fi
[ -n "$today" ] || unknown "date -d with TZ=$tz failed: GNU date is needed"

# every candidate: <at epoch> <id>, ascending. A time that does not exist on its day makes the answer unknown.
cands=""
for k in -1 0 1; do
  d="$(TZ="$tz" date -d "$today $k day" +%F)"
  while IFS= read -r hm; do
    [ -n "$hm" ] || continue
    case "$hm" in [0-9]:[0-9][0-9]) hm="0$hm" ;; esac
    case "$hm" in [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;; *) [ "$k" = 0 ] && echo "warning: deploy_windows entry '$hm' is not HH:MM, skipped"; continue ;; esac
    at="$(TZ="$tz" date -d "$d $hm" +%s 2>/dev/null)"
    # the round trip catches a time that falls in a clock change (01:30 on the day the clocks go forward)
    if [ -z "$at" ] || [ "$(TZ="$tz" date -d "@$at" +%H:%M 2>/dev/null)" != "$hm" ]; then
      unknown "the window time $hm does not exist on $d in $tz (a clock change): it cannot be trusted"
    fi
    cands="$cands$at ${d}T$hm"$'\n'
  done < <(printf '%s' "$wins" | jq -r '.[]? | tostring' 2>/dev/null)
done
if [ -z "$cands" ] && [ "$(printf '%s' "$wins" | jq 'length' 2>/dev/null)" != 0 ]; then
  unknown "schedule.deploy_windows has no usable HH:MM entry"
fi
# The ledger rows, one array slot each, in file order: a row is never merged with another and never dropped for another.
fin() { case "$1" in done|skipped|stopped) return 0 ;; esac; return 1; }
# the rows must be an array of objects: a string, an object of rows or a junk element is a ledger that cannot be trusted
if [ "$ledger_ok" = 1 ] && ! jq -e '(.deployWindows // []) | type == "array" and all(.[]; type == "object")' "$led" >/dev/null 2>&1; then
  unknown "deployWindows in the ledger is not a list of window rows: unfinished rows cannot be ruled out"
fi
nrow=0
R_id=(); R_at=(); R_st=(); R_wk=(); R_tag=(); R_prod=(); R_sha=(); R_ep=()
if [ "$ledger_ok" = 1 ]; then
  rows_txt="$(jq -r '.deployWindows[]? | select(type == "object") | [(.id // "" | tostring | gsub("[\n\r\t\u001f]"; " ")), (.at // "" | tostring | gsub("[\n\r\t\u001f]"; " ")), (.state // "" | tostring | gsub("[\n\r\t\u001f]"; " ")), (.worker // "" | tostring | gsub("[\n\r\t\u001f]"; " ")), (.tag // "" | tostring | gsub("[\n\r\t\u001f]"; " ")), (.prodRunId // "" | tostring | gsub("[\n\r\t\u001f]"; " ")), (if ((.sha // "") | type) == "string" and ((.sha // "") | test("\\A[0-9a-fA-F]{7,64}\\z")) then .sha else "" end)] | join("\u001f")' "$led" 2>/dev/null)" || unknown "the deployWindows[] rows of the ledger could not be read"
  while IFS= read -r row_line; do
    # only a truly empty line is skipped (the here-string of an empty list); a row whose fields are all empty is a row
    [ -n "$row_line" ] || continue
    IFS=$'\037' read -r f_id f_at f_st f_wk f_tag f_prod f_sha <<<"$row_line"
    R_id[nrow]="$f_id"; R_at[nrow]="$f_at"; R_st[nrow]="$f_st"; R_wk[nrow]="$f_wk"; R_tag[nrow]="$f_tag"; R_prod[nrow]="$f_prod"; R_sha[nrow]="$f_sha"
    R_ep[nrow]=""
    # only an ISO 8601 time is read: date -d would also take "yesterday" or "11:00" relative to the REAL clock
    if [[ "$f_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[T\ ][0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?(Z|[+-][0-9]{2}:?[0-9]{2})?$ ]]; then
      R_ep[nrow]="$(date -u -d "$f_at" +%s 2>/dev/null || true)"
    fi
    nrow=$((nrow + 1))
  done <<<"$rows_txt"
fi
# Every configured window is matched to the rows that name it (the same id, or the same instant: a moved or renamed one). An
# UNFINISHED row for it is checked, and a finished row (done, skipped, stopped) never removes it; a window with only finished
# rows is finished; a window with no row at all is a virtual row (nothing is on record for it).
while read -r cat cid; do
  [ -n "$cat" ] || continue
  hit=0
  k=0
  while [ "$k" -lt "$nrow" ]; do
    if [ "${R_id[k]}" = "$cid" ] || [ "${R_ep[k]}" = "$cat" ]; then
      hit=1
      if ! fin "${R_st[k]}"; then [ -n "${R_ep[k]}" ] || R_ep[k]="$cat"; fi
    fi
    k=$((k + 1))
  done
  if [ "$hit" = 0 ]; then
    R_id[nrow]="$cid"; R_at[nrow]=""; R_st[nrow]=""; R_wk[nrow]=""; R_tag[nrow]=""; R_prod[nrow]=""; R_sha[nrow]=""; R_ep[nrow]="$cat"
    nrow=$((nrow + 1))
  fi
done <<<"$cands"
# a row no configured window made (an old window, an ad-hoc one) matters too; an UNFINISHED one that cannot be placed in time
# makes the answer unknown (a finished one with a bad time is ignored)
units=""
k=0
while [ "$k" -lt "$nrow" ]; do
  if fin "${R_st[k]}"; then k=$((k + 1)); continue; fi
  if [ -z "${R_ep[k]}" ]; then
    echo "warning: the unfinished window row '${R_id[k]:-(no id)}' has no usable time (at='${R_at[k]}'): give it an ISO at, or finish it (done, skipped, stopped)"
    unknown "an unfinished deployWindows[] row cannot be placed in time"
  fi
  units="$units${R_ep[k]} $k"$'\n'
  k=$((k + 1))
done
units="$(printf '%s' "$units" | sort -n -s -k1,1)"

# worker_rows <id>: how many unfinished deployWindows[] rows name that worker
worker_rows() {
  jq -r --arg w "$1" '[.deployWindows[]? | select(type == "object") | select(((.state // "") | IN("done", "skipped", "stopped") | not) and ((.worker // "" | tostring | gsub("[\n\r\t\u001f]"; " ")) == $w))] | length' "$led" 2>/dev/null || echo 99
}
# worker_live <id>: the ledger lists it spawning, running or blocked-on-owner (not stuck, queued, done, retired, teardown, gone ...)
# and no more than one unfinished window row names it (one worker never covers two windows)
worker_live() {
  [ "$ledger_ok" = 1 ] && [ -n "$1" ] && [ "$(worker_rows "$1")" -le 1 ] && jq -e --arg w "$1" '(.workers // {})[$w] | type == "object" and ((.state // "") | IN("spawning", "running", "blocked-on-owner"))' "$led" >/dev/null 2>&1
}

# the windows that are checked, in time order: every window that is unfinished and past and still counting (a past window
# with no live worker stops counting after 12 hours; one with a live worker counts however old), and the FIRST unfinished
# window still ahead, whatever its distance (later ones ahead are not checked). The picker is allowed only when EVERY
# checked window is pinned (its row state is staging, validating or prod, or the row carries a sha) AND has its own live
# worker. The first checked window is the one printed in full.
pw=""; pat=""; pworker=""; pst=""; ptag=""; pprod=""; plive=0; pstate=""
nchk=0; allok=1; checks=""; nxt="none"
firstahead=""
while read -r at i; do
  [ -n "$at" ] || continue
  # the rows at the instant of the first window ahead are all checked; the next instant is not
  if [ -n "$firstahead" ] && [ "$at" != "$firstahead" ]; then break; fi
  id="${R_id[i]:-(no id)}"; worker="${R_wk[i]}"; st="${R_st[i]}"; tag="${R_tag[i]}"; prod="${R_prod[i]}"; rsha="${R_sha[i]}"
  live=0; worker_live "$worker" && live=1
  # a past window with no live worker stops mattering after 12 hours
  if [ "$at" -le "$now" ] && [ "$live" = 0 ] && [ "$at" -lt $((now - 12 * 3600)) ]; then continue; fi
  if [ "$at" -gt "$now" ]; then wst="upcoming"
  elif [ "$live" = 1 ]; then wst="in-flight"
  elif [ -n "$worker" ] && [ "$(worker_rows "$worker")" -gt 1 ]; then wst="shared-worker"   # alive, but named by two unfinished rows: it covers neither
  elif [ -n "$worker" ]; then wst="worker-dead"
  elif [ "$ledger_ok" != 1 ]; then wst="unknown"   # the ledger could not be read: "missed" would claim no outcome is on record
  else wst="missed"; fi
  pin=0
  case "$st" in staging|validating|prod) pin=1 ;; esac
  [ -z "$rsha" ] || pin=1
  nchk=$((nchk + 1))
  if [ "$live" = 1 ]; then lv="live"; else lv="not live"; allok=0; fi
  if [ "$pin" = 1 ]; then pn="pinned"; else pn="not pinned"; allok=0; fi
  checks="$checks$id $wst worker ${worker:-none} $lv $pn"$'\n'
  if [ "$nchk" = 1 ]; then pw="$id"; pat="$at"; pworker="$worker"; pst="$st"; ptag="$tag"; pprod="$prod"; plive="$live"; pstate="$wst"; fi
  if [ "$at" -gt "$now" ] && [ -z "$firstahead" ]; then firstahead="$at"; nxt="$id at $(date -u -d "@$at" +%FT%TZ), $(( (at - now) / 60 )) minutes"; fi
done <<<"$units"

# nothing is unfinished (no window configured, or every candidate is finished or expired): nothing to cover
if [ -z "$pw" ]; then echo "window: none"; echo "next-window: none"; echo "state: none"; echo "picker: allowed"; exit 0; fi

diff=$((pat - now))
if [ "$diff" -ge 0 ]; then mins=$((diff / 60)); else mins=$((-(( -diff + 59) / 60))); fi   # floor: 30 seconds past is -1, not 0
echo "window: $pw at $(date -u -d "@$pat" +%FT%TZ)"
echo "minutes: $mins"
# what the window row says about the release, for a message that names one (the ledger only: a tag-push deploy can leave no row)
echo "row: state ${pst:-none}, tag ${ptag:-none}, prod run ${pprod:-none}"
if [ "$ledger_ok" != 1 ]; then
  echo "deploy-worker: unknown (ledger unreadable or missing)"
elif [ "$plive" = 1 ]; then
  echo "deploy-worker: $pworker ($(jq -r --arg w "$pworker" '.workers[$w].state // "unknown" | tostring' "$led" 2>/dev/null))"
elif [ -n "$pworker" ] && [ "$(worker_rows "$pworker")" -gt 1 ]; then
  echo "deploy-worker: $pworker (named by $(worker_rows "$pworker") unfinished window rows: one worker never covers two windows)"
elif [ -n "$pworker" ] && jq -e --arg w "$pworker" '(.workers // {})[$w] | type == "object"' "$led" >/dev/null 2>&1; then
  echo "deploy-worker: $pworker ($(jq -r --arg w "$pworker" '.workers[$w].state // "unknown" | tostring' "$led" 2>/dev/null), not a live worker)"
elif [ -n "$pworker" ]; then
  echo "deploy-worker: $pworker (named by the window row, not listed in workers)"
else
  echo "deploy-worker: none"
fi
echo "state: $pstate"
echo "next-window: $nxt"
printf '%s' "$checks" | while IFS= read -r l; do [ -n "$l" ] && echo "window-check: $l"; done
if [ "$allok" = 1 ]; then echo "picker: allowed"; else echo "picker: WAITING-row-only"; fi
# the script reads the ledger only: it cannot see a wake
if [ "$allok" = 1 ]; then echo "note: arm the wake (ScheduleWakeup) before any picker; the script cannot see it"; fi
exit 0
