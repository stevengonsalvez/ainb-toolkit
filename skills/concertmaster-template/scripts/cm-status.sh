#!/usr/bin/env bash
# cm-status.sh: the /cm-status view. Every lead on every host, the sessions each lead owns, and whether each one is
# really running, in plain words. Read-only: it runs ONE fresh `lane-health.sh --no-write --json` pass and renders it.
#
#   scripts/cm-status.sh                  # attention box, then the tree (host, lead, the sessions it owns)
#   scripts/cm-status.sh --detail         # each row also gets pid, session id, handle, runtime, model, effort, last write,
#                                         # and the host events log (reboots, preemptions, daemon restarts) closes the view
#   scripts/cm-status.sh --lead <id>      # one lead's children only (what a lead runs on its own host)
#   scripts/cm-status.sh --from <file>    # render a saved `lane-health.sh --json` document instead of a fresh pass
#
# Layout (companions/cm-status.md):
#   NEEDS A LOOK (n)        every session that is not running, idle or asleep: mark, name, word, one-line meaning
#   <host> (Spot, rebooted HH:MM)
#     <lead>   ● running    <last task line>
#       ├ <worker>  ○ idle  <meaning or task>
#       └ <worker>  ✗ stopped <meaning>
#     (no lead)             sessions no lead owns
#   not in the ledger       unknown sessions, per host
# Marks: ● running, ○ idle, ? waiting on you, ⚠ stuck, ✗ stopped, z asleep, · unknown. Times in schedule.timezone.
# Exit 0 nothing needs a look; 3 something does; 1 the pass could not run; 2 usage.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

DETAIL=0; LEAD=""; FROM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --detail) DETAIL=1 ;;
    --lead) [ $# -ge 2 ] && [ -n "$2" ] || { cm_warn "cm-status.sh: --lead needs a worker id"; exit 2; }; LEAD="$2"; shift ;;
    --from) [ $# -ge 2 ] && [ -r "$2" ] || { cm_warn "cm-status.sh: --from needs a readable file"; exit 2; }; FROM="$2"; shift ;;
    -h|--help) awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    *) cm_warn "cm-status.sh: unknown arg: $1"; exit 2 ;;
  esac
  shift
done
command -v jq >/dev/null 2>&1 || { cm_warn "cm-status.sh: missing dependency: jq"; exit 1; }

if [ -n "$FROM" ]; then DOC="$(cat "$FROM")"
elif [ -n "$LEAD" ]; then DOC="$("$HERE/lane-health.sh" --lead "$LEAD" --no-write --json)"
else DOC="$("$HERE/lane-health.sh" --all --no-write --json)"; fi
printf '%s' "$DOC" | jq -e '.sessions | type == "array"' >/dev/null 2>&1 || { cm_warn "cm-status.sh: lane-health.sh gave no status document"; exit 1; }

printf '%s' "$DOC" | TZ="$CM_TZ" jq -r --argjson detail "$DETAIL" --arg tzl "$CM_TZ_LABEL" '
  def ep: if . == null then null elif type == "number" then . else (tostring | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch null) end;
  def hhmm: ep | if . == null then "?" else (localtime | strflocaltime("%H:%M")) end;
  def ago: ep | if . == null then "?" else ((now - .) / 60 | floor) as $m | if $m >= 1440 then "\($m / 1440 | floor)d ago" elif $m >= 60 then "\($m / 60 | floor)h\($m % 60)m ago" else "\($m)m ago" end end;
  def pad($n): tostring | if length >= $n then . + " " else . + (" " * ($n - length)) end;
  def say: if .word | IN("running") then (.task // "") else (.meaning // .task // "") end | tostring | gsub("[[:cntrl:]]+"; " ") | .[0:110];
  def det($ind): if $detail == 1 then
      "\($ind)pid \(.live.pid // "-") · session \(.live.sessionId // "-") · handle \(.live.handle // "-") · \(.live.runtime // "runtime ?") · model \(.live.model // "-") · effort \(.live.effort // "-") · last write \(.live.lastTranscriptAt | ago)"
    else empty end;
  def line($ind; $w): "\($ind)\(.name | pad($w)) \(.mark) \(.word | pad(15))\(say)", det(($ind | gsub("├"; "│") | gsub("└"; " ")) + "    ");
  . as $d
  | ($d.sessions | map(select(.unknown | not))) as $known
  | ($d.sessions | map(select(.unknown // false))) as $unk
  | ($known | map(select(.isLead)) | map(.key)) as $leadKeys
  | ([$d.sessions[] | .name | length] + [10] | max + 2) as $w
  | ($d.sessions | map(select(.word | IN("running", "idle", "asleep") | not))) as $att
  | "NEEDS A LOOK (\($att | length))\(if ($att | length) == 0 then ": all clear" else "" end)",
    ($att[] | "  \(.mark) \(.name | pad($w)) \(.word | pad(15))\(.meaning // "" | tostring | .[0:110])"),
    "",
    ( ([$d.hosts[].host] + [$d.sessions[].host] | unique | sort_by(if . == "local" then "" else . end))[] as $h
      | ($d.hosts | map(select(.host == $h)) | first) as $hi
      | ($known | map(select(.host == $h and .isLead))) as $leads
      | ($known | map(select(.host == $h and (.isLead | not) and (.parent as $pp | $pp == null or ($leadKeys | index($pp)) == null)))) as $loose
      | ($unk | map(select(.host == $h))) as $hu
      | select(($leads | length) + ($loose | length) + ($hu | length) > 0)
      | "\($h)\([ (if $hi == null then empty elif ($hi.ok | not) then "down: " + ($hi.error // "no answer" | tostring | .[0:60]) else empty end),
                  (if $hi.spot then "Spot" else empty end),
                  (if $hi.bootAt != null and ((now - ($hi.bootAt | ep)) < 86400) then "rebooted \($hi.bootAt | hhmm)" else empty end),
                  (if $hi.daemonAt != null and ((now - ($hi.daemonAt | ep)) < 86400) then "daemon restarted \($hi.daemonAt | hhmm)" else empty end) ]
                | if length > 0 then " (" + join(", ") + ")" else "" end)",
        ( $leads[] | . as $l | line("  "; $w),
          ( ($known | map(select(.parent == $l.key))) as $kids
            | $kids | to_entries[] | .key as $i | .value
            | (if $i == (($kids | length) - 1) then "└ " else "├ " end) as $b
            | (. + {name: (.name + (if .host != $l.host then "@" + .host else "" end))}) | line("    " + $b; $w - 4) ) ),
        ( if ($loose | length) > 0 then "  (no lead)", ($loose[] | line("    "; $w - 2)) else empty end ),
        ( if ($hu | length) > 0 then "  not in the ledger", ($hu[] | line("    "; $w - 2)) else empty end ),
        "" ),
    ( if $detail == 1 then
        "Host events (newest first)",
        (if (($d.hostEvents // []) | length) == 0 then "  none recorded"
         else (($d.hostEvents // []) | sort_by(.at) | reverse | .[0:20][]
               | "  \(.at | ep | localtime | strflocaltime("%m-%d %H:%M")) \(.at | ago | pad(10)) \(.host | pad(14)) \(.kind | pad(15)) \(.evidence // "" | tostring | .[0:100])") end),
        ""
      else empty end ),
    "checked \($d.generatedAt | hhmm) \($tzl)\(if $d.mode == "lead" then ", lead " + ($d.lead // "?") else "" end); scripts/cm-status.sh --detail for pids, sessions and host events"'
NEED="$(printf '%s' "$DOC" | jq -r '[.sessions[] | select(.word | IN("running", "idle", "asleep") | not)] | length')"
[ "$NEED" = 0 ] || exit 3
exit 0
