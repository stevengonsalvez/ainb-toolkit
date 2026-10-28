#!/usr/bin/env bash
# digest.sh: build the twice-daily digest text. Prints to stdout only; sending
# (config messaging.owner_digest) is the concertmaster's job, see SKILL.md.
#
#   scripts/digest.sh [--full] [--ledger <path>] [--since-hours <n>]
#
# Default output is the text for a chat group: terse "- " bullets, no greeting. Sections:
# merged, deployed (and stopped deploys). Nothing in it names a host or a worker.
# --full adds the rest, for the concertmaster's terminal report and never for a group:
# needs <owner>, stuck, and a one-line fleet footer (running, hosts, open PRs).
# Window: --since-hours <n>, else the time since ledger digests.lastSentAt, else 12h
# (a lastSentAt that is missing, unparseable or in the future counts as missing). The
# window starts exactly there: a PR merged before lastSentAt is not listed twice; the header
# shows the gap in hours, rounded up.
# Merged and the open PR count come from GitHub (gh), NOT the ledger: a ledger can lose
# rows and a ledger zero would read as fact. gh is asked for the main repo
# ($CM_ORG/$CM_REPO), under a CM_DIGEST_GH_TIMEOUT (default 30s) timeout. When gh fails
# (auth, rate limit, offline, timeout, garbage) the digest says "Merged: unknown (gh
# failed)" and "open PRs: unknown (gh failed)", never a zero. At most 100 merged PRs are
# listed (the heading then reads "100+"), at most 1000 open PRs are counted.
# The other sections still read the ledger. Default ledger: $CM_HOME/ledger.json. Times
# print in config schedule.timezone (CM_TZ), labelled schedule.timezone_label. Plain
# text, chat friendly, no em-dashes. Read-only: it never writes the ledger (the
# digests.lastSentAt write after a send is the concertmaster's).
# --full also lists forbidden agents (host, worktree and handle, so never for a group), only when
# ledger.violations has rows or ledger.violationCheck is incomplete.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

LEDGER="$CM_HOME/ledger.json"
SINCE_H=""
FULL=false
GH_TIMEOUT="${CM_DIGEST_GH_TIMEOUT:-30}"
MERGED_LIMIT=100
OPEN_LIMIT=1000
while [ $# -gt 0 ]; do
  case "$1" in
    --ledger) LEDGER="$2"; shift 2 ;;
    --since-hours) SINCE_H="${2:-}"; shift 2 ;;
    --full) FULL=true; shift ;;
    -h|--help) sed -n '2,/^set -euo/{/^#/p;}' "$0"; exit 0 ;;
    *) cm_warn "unknown arg: $1"; exit 2 ;;
  esac
done
[ -r "$LEDGER" ] || { cm_warn "no ledger at $LEDGER"; exit 1; }
if [ -n "$SINCE_H" ] && ! printf '%s' "$SINCE_H" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; then
  cm_warn "--since-hours needs a number"; exit 2
fi

# Window start, an exact epoch: --since-hours (now minus n hours), else digests.lastSentAt, else 12h
# ago (a lastSentAt that is missing, unparseable or in the future counts as missing). SINCE_H is
# only the header's hours: as given, else the gap rounded up (at least 1). Every section and the gh
# search use SINCE_EPOCH, so a PR merged before lastSentAt is never listed twice.
WIN="$(jq -r --arg h "$SINCE_H" 'def ts: try (tostring | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601) catch null;
  now as $n
  | (if $h != "" then $n - ($h | tonumber) * 3600
     else (((.digests.lastSentAt // null) | ts) as $t | if $t == null or $t > $n then $n - 12 * 3600 else $t end) end) as $e
  | "\($e | floor) \(if $h != "" then $h else ([(($n - $e) / 3600 | ceil), 1] | max) end)"' "$LEDGER" 2>/dev/null || true)"
if [ -n "$WIN" ]; then SINCE_EPOCH="${WIN% *}"; SINCE_H="${WIN#* }"; else SINCE_EPOCH=$(( $(date +%s) - 12 * 3600 )); SINCE_H=12; fi

# GitHub: merged PRs since the window start, and the open PR count. A failed read prints "null",
# which the filter turns into "unknown (gh failed)". Merged PRs are filtered again on mergedAt, so
# a loose search never lists a PR outside the window.
GH_REPO="$CM_ORG/$CM_REPO"
CUTOFF="$(jq -nr --argjson e "$SINCE_EPOCH" '$e | todate')"
# gh_json <gh pr list args...>: the answer when gh succeeds and it is a JSON array, else "null".
gh_json() {
  local out
  if [ -n "$CM_ORG" ] && [ -n "$CM_REPO" ] \
     && out="$(cm_timeout "$GH_TIMEOUT" gh pr list -R "$GH_REPO" "$@" 2>/dev/null)" \
     && printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf '%s' "$out"
  else
    printf 'null'
  fi
}
MERGED_JSON="$(gh_json --state merged --search "merged:>=$CUTOFF" --json number,title,mergedAt,author,url --limit "$MERGED_LIMIT")"
OPEN_JSON=null   # only the --full Fleet line shows the open PR count
$FULL && OPEN_JSON="$(gh_json --state open --json number --limit "$OPEN_LIMIT")"

TZ="$CM_TZ" jq -r --argjson sinceH "$SINCE_H" --argjson since "$SINCE_EPOCH" --argjson ghMerged "$MERGED_JSON" --argjson ghOpen "$OPEN_JSON" \
  --argjson full "$FULL" --argjson mergedLimit "$MERGED_LIMIT" --argjson openLimit "$OPEN_LIMIT" --arg project "$CM_PROJECT" --arg owner "$CM_OWNER_NAME" --arg tzl "$CM_TZ_LABEL" '
  def ts: if . == null then null
          else (tostring | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | try fromdateiso8601 catch null) end;
  def uk: if . == null then "?" else (localtime | strflocaltime("%a %H:%M")) end;
  def recent: (ts) as $t | $t != null and $t >= $since;
  def ago: (ts) as $t | if $t == null then "?" else
             ((now - $t) / 60 | floor) as $m
             | if $m >= 60 then "\($m / 60 | floor)h\($m % 60)m" else "\($m)m" end end;
  def section($title; $lines): ("\($title) (\($lines | length))"),
    (if ($lines | length) == 0 then "- none" else ($lines[] | "- " + .) end), "";

  (.workers // {} | to_entries | map(.value + {id: .key})) as $workers
  | (.deployWindows // []) as $wins
  | (.asks // []) as $asks
  | (.hosts // {}) as $hosts
  | "\($project) concertmaster digest, \(now | uk) \($tzl) (last \($sinceH)h)",
    "",
    ( if $ghMerged == null then "Merged: unknown (gh failed)", ""
      else ([ $ghMerged | map(select(.mergedAt | recent)) | sort_by(.mergedAt)[]
          | "#\(.number) \(.title // "" | tostring | gsub("[[:cntrl:]]+"; " ") | .[0:60]) (\(.author.login // "?"))" ]) as $m
        | "Merged (\($m | length)\(if ($ghMerged | length) >= $mergedLimit then "+" else "" end))",
          (if ($m | length) == 0 then "- none" else ($m[] | "- " + .) end), "" end ),
    section("Deployed"; [ $wins[] | select(.state == "done" and (.finishedAt | recent))
        | "\(.tag // "?") at \(.finishedAt | ts | uk): \((.prs // []) | map("#\(.)") | join(" "))" ]
      + [ $wins[] | select(.state == "stopped" and ((.finishedAt // .at) | recent))
        | "STOPPED \(.id): \(.blockedReason // "no reason recorded")" ]),
    ( if $full | not then empty else section("Needs \($owner)"; [ $workers[] | select(.state == "blocked-on-owner")
        | "\(.lane // "-") \(.task // .id | .[0:60]): \(.blockedQuestion // "see concertmaster")" ]
      + [ $asks[] | select(.state == "open") | "ask: \(.question | .[0:80]) (open \(.askedAt | ago))" ]) end ),
    ( if $full | not then empty else section("Stuck"; [ $workers[] | select(.state == "stuck")
        | "\(.task // .id | .[0:50]) on \(.host // "?"), idle \(.lastOutputAt | ago), nudges \(.nudges // 0)/2" ]) end ),
    ( if $full | not then empty else def clean: tostring | gsub("[[:cntrl:]]+"; " ");
      (.violationCheck // {}) as $vc
      | if $vc.enabled == false then empty else
        ([ (.violations // [])[] | "\(.agent // "?" | clean) \(.host // "?" | clean) \(.worktree // "?" | clean) \(.handle // "-" | clean) \(.title // "-" | clean | .[0:40])" ]
         + (if $vc.complete == false then ["CHECK INCOMPLETE, not proof of none: \(($vc.gaps // []) | join("; ") | clean | .[0:160])"] else [] end)
         + (if ($vc.checkedAt | ts) != null then ["census \($vc.checkedAt | ago) old"] else [] end)) as $lines
        | if ($lines | map(select(startswith("census ") | not)) | length) == 0 then empty
          else section("Forbidden agents on \($project) work"; $lines) end end end ),
    ( if $full | not then empty else
      [ $workers[] | select(.state == "running") ] as $run
      | ($run | group_by(.host) | map("\(.[0].host) \(length)") | join(", ")) as $byHost
      | ([ $hosts | to_entries[] | select(.value.reachable == false) | .key ]) as $off
      | (if $ghOpen == null then "unknown (gh failed)"
         else ($ghOpen | length) as $n | "\($n)\(if $n >= $openLimit then "+" else "" end)" end) as $open
      | "Fleet: \($run | length) running\(if $byHost != "" then " (" + $byHost + ")" else "" end), open PRs: \($open)\(if ($off | length) > 0 then ", offline: " + ($off | join(" ")) else "" end)" end )
' "$LEDGER"
