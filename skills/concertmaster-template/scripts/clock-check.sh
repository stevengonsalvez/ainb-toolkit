#!/usr/bin/env bash
# clock-check.sh: the clock and the deploy state, for the two rules of references/standing-rules.md section 3
# (no owner picker inside 2 hours of a deploy window until its deploy is pinned, checked and its worker spawned; check the
# clock right before any message that names a deploy time or a release). Read-only. Exit 0 always: a line it cannot fill
# says why, and every doubt answers "WAITING-row-only" (never "allowed").
#
#   scripts/clock-check.sh                       # key: value lines
#   CM_TEST=1 CM_NOW=2000-01-01T10:30:00Z scripts/clock-check.sh   # a stubbed clock (tests only: CM_NOW needs CM_TEST=1)
#
#   now:           UTC now (names CM_NOW when the clock is stubbed)
#   window:        the first window that matters: the ledger deployWindows[].id (local date T HH:MM), then its UTC
#                  time; the next window when none is past-and-unfinished or inside 2 hours; or none
#   minutes:       minutes from now to it (negative: it has passed)
#   row:           that window row's state, tag and prod run id, or none (what a message may say about the release)
#   deploy-worker: that row's worker and its state in the ledger workers, none, or unknown (ledger unreadable or missing)
#   state:         upcoming (more than 2h away), inside-2h, in-flight (a live deploy worker is on it), worker-dead
#                  (the row names a worker the ledger does not list live), missed (it has passed and no deploy worker
#                  or outcome is on record), none (no window configured), unknown (see the other lines; also a past
#                  window while the ledger cannot be read: whether it shipped is not known)
#   window-check:  one line per window that matters: <id> <state> worker <id or none> live|not live
#   picker:        allowed, or WAITING-row-only. Allowed only when EVERY window that is past-and-unfinished or within 2h
#                  has ITS OWN live deploy worker (the worker its own row names; one worker never covers another
#                  window). A wake still has to be armed before any picker.
#
# Windows come from cfg.schedule.deploy_windows in the zone CM_TZ (lib.sh: else cfg.schedule.timezone, else UTC),
# for yesterday, today and tomorrow, plus every unfinished deployWindows[] row of the ledger (its at is read as UTC). A window matters when it has no finished outcome (done, skipped, stopped) and is
# either inside 2 hours or already past (missed, in flight, or its worker died). A past window with no live worker
# stops mattering after 12 hours; one with a live worker matters however old. A worker is live while the ledger lists it
# spawning, running or blocked-on-owner (stuck does not count: it needs the loop, and a picker stops the loop; a row
# with no state does not count), and only while a single unfinished window row names it: a worker named by two unfinished
# rows covers neither. Answers unknown, with WAITING-row-only, when: the config file is missing, empty or
# unparseable or has no deploy_windows key (an empty list is "none"); no deploy_windows entry is usable; a window time
# does not exist on its day (clocks going forward; known limit: it looks at yesterday, today and tomorrow, so the answer is
# unknown for all of those days, safe but wider than the one day with the gap); the zone is not on the host (checked against /usr/share/zoneinfo
# when that exists); the clock cannot be read. An entry that is not H:MM or HH:MM, or is out of range, is reported and
# skipped. It reads the ledger only: a release shipped by a tag push that left no deployWindows[] row reads as missed,
# which is the safe side (WAITING row). Needs GNU date (date -d), like the other Linux-only parts of the kit.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"
case "${1:-}" in -h|--help) awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

unknown() { echo "window: none ($1)"; echo "state: unknown"; echo "picker: WAITING-row-only"; exit 0; }

tz="$CM_TZ"   # lib.sh: CM_TZ, else schedule.timezone, else UTC (the zone every other script uses)
# CM_NOW stubs the clock only under CM_TEST=1 (as the other test seams do): a leaked CM_NOW must never decide a real send
stub=0
if [ -n "${CM_NOW:-}" ]; then
  if [ "${CM_TEST:-}" = 1 ]; then stub=1; else echo "warning: CM_NOW is set but CM_TEST is not 1: the real clock is used"; fi
fi
if [ "$stub" = 1 ]; then now="$(date -u -d "$CM_NOW" +%s 2>/dev/null)"; else now="$(date -u +%s)"; fi
case "$now" in ''|*[!0-9]*) echo "now: unknown (CM_NOW is not a time GNU date reads)"; echo "state: unknown"; echo "picker: WAITING-row-only"; exit 0 ;; esac
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
if [ -z "$cands" ]; then
  if [ "$(printf '%s' "$wins" | jq 'length' 2>/dev/null)" = 0 ]; then echo "window: none"; echo "state: none"; echo "picker: allowed"; exit 0; fi
  unknown "schedule.deploy_windows has no usable HH:MM entry"
fi
# an unfinished ledger row that no configured window made (an old window, an ad-hoc or moved one) matters too
if [ "$ledger_ok" = 1 ]; then
  while IFS=$'\t' read -r rid rat; do
    case "$rid" in ''|*[!A-Za-z0-9:_-]*) continue ;; esac
    [ -n "$rat" ] || continue
    printf '%s' "$cands" | awk -v i="$rid" '$2 == i { f = 1 } END { exit !f }' && continue
    e="$(date -u -d "$rat" +%s 2>/dev/null)" || continue
    cands="$cands$e $rid"$'\n'
  done < <(jq -r '.deployWindows[]? | select(((.state // "") | IN("done", "skipped", "stopped") | not) and ((.at // "") != "")) | [(.id // ""), .at] | @tsv' "$led" 2>/dev/null)
fi
cands="$(printf '%s' "$cands" | sort -n)"

# worker_rows <id>: how many unfinished deployWindows[] rows name that worker
worker_rows() {
  jq -r --arg w "$1" '[.deployWindows[]? | select(((.state // "") | IN("done", "skipped", "stopped") | not) and .worker == $w)] | length' "$led" 2>/dev/null || echo 99
}
# worker_live <id>: the ledger lists it spawning, running or blocked-on-owner (not stuck, queued, done, retired, teardown, gone ...)
# and no more than one unfinished window row names it (one worker never covers two windows)
worker_live() {
  [ "$ledger_ok" = 1 ] && [ -n "$1" ] && [ "$(worker_rows "$1")" -le 1 ] && jq -e --arg w "$1" '(.workers // {})[$w] | type == "object" and ((.state // "") | IN("spawning", "running", "blocked-on-owner"))' "$led" >/dev/null 2>&1
}

# the windows that matter, in time order, and the first window after them (shown when none matters)
nrel=0; allok=1; checks=""; nxt=""
pw=""; pat=""; pworker=""; pst=""; ptag=""; pprod=""; plive=0; pstate=""   # the first window that matters
while read -r at id; do
  [ -n "$at" ] || continue
  worker=""; st=""; tag=""; prod=""
  if [ "$ledger_ok" = 1 ]; then
    row="$(jq -r --arg id "$id" '[.deployWindows[]? | select(.id == $id)][0] | [(.worker // ""), (.state // ""), (.tag // ""), (.prodRunId // "" | tostring)] | join("|")' "$led" 2>/dev/null)"
    IFS='|' read -r worker st tag prod <<<"$row"
  fi
  live=0; worker_live "$worker" && live=1
  case "$st" in done|skipped|stopped) continue ;; esac
  if [ "$at" -gt "$now" ] && [ $((at - now)) -gt 7200 ]; then
    [ -n "$nxt" ] || nxt="$at|$id|$worker|$st|$tag|$prod|$live"
    continue
  fi
  # a past window with no live worker stops mattering after 12 hours
  if [ "$at" -le "$now" ] && [ "$live" = 0 ] && [ "$at" -lt $((now - 12 * 3600)) ]; then continue; fi
  nrel=$((nrel + 1))
  if [ "$at" -gt "$now" ]; then wst="inside-2h"
  elif [ "$live" = 1 ]; then wst="in-flight"
  elif [ -n "$worker" ]; then wst="worker-dead"
  elif [ "$ledger_ok" != 1 ]; then wst="unknown"   # the ledger could not be read: "missed" would claim no outcome is on record
  else wst="missed"; fi
  if [ "$live" = 1 ]; then lv="live"; else lv="not live"; allok=0; fi
  checks="$checks$id $wst worker ${worker:-none} $lv"$'\n'
  if [ "$nrel" = 1 ]; then pw="$id"; pat="$at"; pworker="$worker"; pst="$st"; ptag="$tag"; pprod="$prod"; plive="$live"; pstate="$wst"; fi
done <<<"$cands"

if [ "$nrel" = 0 ]; then
  if [ -z "$nxt" ]; then echo "window: none"; echo "state: none"; echo "picker: allowed"; exit 0; fi
  IFS='|' read -r pat pw pworker pst ptag pprod plive <<<"$nxt"
  pstate="upcoming"
fi

diff=$((pat - now))
if [ "$diff" -ge 0 ]; then mins=$((diff / 60)); else mins=$((-(( -diff + 59) / 60))); fi   # floor: 30 seconds past is -1, not 0
echo "window: $pw at $(date -u -d "@$pat" +%FT%TZ)"
echo "minutes: $mins"
# what the window row says about the release, for a message that names one (the ledger only: a tag-push deploy can leave no row)
echo "row: state ${pst:-none}, tag ${ptag:-none}, prod run ${pprod:-none}"
if [ "$ledger_ok" != 1 ]; then
  echo "deploy-worker: unknown (ledger unreadable or missing)"
elif [ "$plive" = 1 ]; then
  echo "deploy-worker: $pworker ($(jq -r --arg w "$pworker" '.workers[$w].state // "unknown"' "$led" 2>/dev/null))"
elif [ -n "$pworker" ] && [ "$(worker_rows "$pworker")" -gt 1 ]; then
  echo "deploy-worker: $pworker (named by $(worker_rows "$pworker") unfinished window rows: one worker never covers two windows)"
elif [ -n "$pworker" ] && jq -e --arg w "$pworker" '(.workers // {})[$w] | type == "object"' "$led" >/dev/null 2>&1; then
  echo "deploy-worker: $pworker ($(jq -r --arg w "$pworker" '.workers[$w].state // "unknown"' "$led" 2>/dev/null), not a live worker)"
elif [ -n "$pworker" ]; then
  echo "deploy-worker: $pworker (named by the window row, not listed in workers)"
else
  echo "deploy-worker: none"
fi
echo "state: $pstate"
printf '%s' "$checks" | while IFS= read -r l; do [ -n "$l" ] && echo "window-check: $l"; done
if [ "$nrel" = 0 ] || [ "$allok" = 1 ]; then echo "picker: allowed"; else echo "picker: WAITING-row-only"; fi
# the script reads the ledger only: it cannot see a wake, or whether the deploy is pinned and checked
if [ "$nrel" != 0 ] && [ "$allok" = 1 ]; then echo "note: arm the wake (ScheduleWakeup) and confirm the deploy is pinned and checked (the row state above) before any picker"; fi
exit 0
