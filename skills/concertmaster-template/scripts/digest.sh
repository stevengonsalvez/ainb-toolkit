#!/usr/bin/env bash
# digest.sh: build the twice-daily digest text from the ledger. Prints to
# stdout only; sending (config messaging.owner_digest) is the concertmaster's
# job, see SKILL.md.
#
#   scripts/digest.sh [--ledger <path>] [--since-hours <n>]
#
# Sections: merged, deployed (and stopped deploys), needs <owner>, stuck, then
# a one-line fleet footer, plus a queue line when work is queued. Default
# window: 12h. Default ledger: $CM_HOME/ledger.json. Times print in config
# schedule.timezone (CM_TZ), labelled schedule.timezone_label. Plain text, chat friendly, no em-dashes.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

LEDGER="$CM_HOME/ledger.json"
SINCE_H=12
while [ $# -gt 0 ]; do
  case "$1" in
    --ledger) LEDGER="$2"; shift 2 ;;
    --since-hours) SINCE_H="$2"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) cm_warn "unknown arg: $1"; exit 2 ;;
  esac
done
[ -r "$LEDGER" ] || { cm_warn "no ledger at $LEDGER"; exit 1; }

TZ="$CM_TZ" jq -r --argjson sinceH "$SINCE_H" --arg project "$CM_PROJECT" --arg owner "$CM_OWNER_NAME" --arg tzl "$CM_TZ_LABEL" '
  def ts: if . == null then null
          else (tostring | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | try fromdateiso8601 catch null) end;
  def uk: if . == null then "?" else (localtime | strflocaltime("%a %H:%M")) end;
  def recent: (ts) as $t | $t != null and $t >= (now - $sinceH * 3600);
  def ago: (ts) as $t | if $t == null then "?" else
             ((now - $t) / 60 | floor) as $m
             | if $m >= 60 then "\($m / 60 | floor)h\($m % 60)m" else "\($m)m" end end;
  def section($title; $lines): ("\($title) (\($lines | length))"),
    (if ($lines | length) == 0 then "  none" else ($lines[] | "  " + .) end), "";

  (.prs // {} | to_entries | map(.value)) as $prs
  | (.workers // {} | to_entries | map(.value + {id: .key})) as $workers
  | (.deployWindows // []) as $wins
  | (.asks // []) as $asks
  | (.hosts // {}) as $hosts
  | "\($project) concertmaster digest, \(now | uk) \($tzl) (last \($sinceH)h)",
    "",
    section("Merged"; [ $prs[] | select(.mergedAt | recent)
        | "#\(.number) \(.title // "" | .[0:60]) (\(.author // "?"))" ]),
    section("Deployed"; [ $wins[] | select(.state == "done" and (.finishedAt | recent))
        | "\(.tag // "?") at \(.finishedAt | ts | uk): \((.prs // []) | map("#\(.)") | join(" "))" ]
      + [ $wins[] | select(.state == "stopped" and ((.finishedAt // .at) | recent))
        | "STOPPED \(.id): \(.blockedReason // "no reason recorded")" ]),
    section("Needs \($owner)"; [ $workers[] | select(.state == "blocked-on-owner")
        | "\(.lane // "-") \(.task // .id | .[0:60]): \(.blockedQuestion // "see concertmaster")" ]
      + [ $asks[] | select(.state == "open") | "ask: \(.question | .[0:80]) (open \(.askedAt | ago))" ]),
    section("Stuck"; [ $workers[] | select(.state == "stuck")
        | "\(.task // .id | .[0:50]) on \(.host // "?"), idle \(.lastOutputAt | ago), nudges \(.nudges // 0)/2" ]),
    ( [ $workers[] | select(.state == "running") ] as $run
      | ($run | group_by(.host) | map("\(.[0].host) \(length)") | join(", ")) as $byHost
      | ([ $hosts | to_entries[] | select(.value.reachable == false) | .key ]) as $off
      | ([ $prs[] | select(.state == "OPEN") ] | length) as $open
      | "Fleet: \($run | length) running\(if $byHost != "" then " (" + $byHost + ")" else "" end), \($open) open PRs tracked\(if ($off | length) > 0 then ", offline: " + ($off | join(" ")) else "" end)" ),
    ( [ (.queue.items // [])[] | select(.state == "queued") ]
      | sort_by(({"P0": 0, "urgent": 1}[.priority // "normal"] // 2), (.addedAt // ""))
      | if length == 0 then empty
        else "Queue: \(length) waiting, next \(.[0:3] | map("#\(.issue) \(.lane) \(.priority // "normal")") | join(", "))" end )
' "$LEDGER"
