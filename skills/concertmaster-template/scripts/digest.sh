#!/usr/bin/env bash
# digest.sh: build the twice-daily digest text. Prints to stdout only; sending
# (config messaging.owner_digest) is the concertmaster's job, see SKILL.md.
#
#   scripts/digest.sh [--full] [--ledger <path>] [--since-hours <n>]
#
# Default output is the text for a chat group: terse "- " bullets, no greeting. Sections:
# merged, deployed (and stopped deploys). Nothing in it names a host or a worker.
# --full adds the rest, for the concertmaster's terminal report and never for a group:
# needs <owner>, open follow-ups (ledger followUps[], scripts/followups.sh), stuck, and a
# one-line fleet footer (running, hosts, open PRs).
# Window: --since-hours <n>, else the time since ledger digests.lastSentAt, else 12h
# (a lastSentAt that is missing, unparseable or in the future counts as missing). The
# window starts exactly there: a PR merged before lastSentAt is not listed twice; the header
# shows the gap in hours, rounded up.
# Merged, Deployed and the open PR count come from GitHub (gh), NOT the ledger alone: a ledger
# can lose rows and a ledger zero would read as fact. gh is asked for the main repo
# ($CM_ORG/$CM_REPO), under a CM_DIGEST_GH_TIMEOUT (default 30s) timeout. When gh fails
# (auth, rate limit, offline, timeout, garbage) the digest says "Merged: unknown (gh
# failed)", "Deployed: unknown (gh failed)" and "open PRs: unknown (gh failed)", never a zero.
# At most 100 merged PRs are listed (the heading then reads "100+"), at most 1000 open PRs are counted.
# Deployed (config digest.deploy_workflow + digest.deploy_job; with neither set the ledger is the only
# source): the push-event runs of the deploy workflow that finished in the window, and per run the named
# deploy job. A release counts as deployed when that job concluded success: the run's own conclusion proves
# nothing (an advisory job that is cancelled or red turns the whole run "cancelled" or "failure" after prod
# shipped). A run in the window with no succeeded deploy job is listed as "ran, no prod deploy job
# succeeded" (or "still running, ..."), never hidden and never counted as deployed. The ledger deployWindows[]
# rows (state done) are merged in by tag (a leading "v" is ignored) so a release is listed once, with the PRs
# the ledger knows ("<tag> at <time>: #PR ..." else "<tag> at <time>"); STOPPED rows come from the ledger only.
# The heading counts deployed releases only. When the gh read fails the ledger rows still list under
# "Deployed: unknown (gh failed)".
# The other sections read the ledger. Default ledger: $CM_HOME/ledger.json. Times
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
RUN_LIMIT="${CM_DIGEST_RUN_LIMIT:-50}"
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
# gh_json <jq type> <gh args...>: gh's answer when it succeeds and is JSON of that type, else "null".
gh_json() {
  local type="$1" out; shift
  if [ -n "$CM_ORG" ] && [ -n "$CM_REPO" ] \
     && out="$(cm_timeout "$GH_TIMEOUT" gh "$@" 2>/dev/null)" \
     && printf '%s' "$out" | jq -e --arg t "$type" 'type == $t' >/dev/null 2>&1; then
    printf '%s' "$out"
  else
    printf 'null'
  fi
}
gh_prs() { gh_json array pr list -R "$GH_REPO" "$@"; }
MERGED_JSON="$(gh_prs --state merged --search "merged:>=$CUTOFF" --json number,title,mergedAt,author,url --limit "$MERGED_LIMIT")"
OPEN_JSON=null   # only the --full Fleet line shows the open PR count
$FULL && OPEN_JSON="$(gh_prs --state open --json number --limit "$OPEN_LIMIT")"

# Deployed: push-event runs of the deploy workflow that updated since the window start, each with its jobs.
# GH_DEPLOYS is a JSON array of {headBranch, status, updatedAt, jobs}, "[]" when no deploy workflow is
# configured (the ledger alone), or "null" when any gh read failed.
DEPLOY_WORKFLOW="$(cm_cfg_json '.digest.deploy_workflow' '""')"
DEPLOY_JOB="$(cm_cfg_json '.digest.deploy_job' '""')"
printf '%s' "$DEPLOY_WORKFLOW" | jq -e 'type == "string"' >/dev/null 2>&1 || { cm_warn "digest.deploy_workflow must be a string"; exit 2; }
printf '%s' "$DEPLOY_JOB" | jq -e 'type == "string"' >/dev/null 2>&1 || { cm_warn "digest.deploy_job must be a string"; exit 2; }
DEPLOY_WORKFLOW="$(jq -r '.' <<<"$DEPLOY_WORKFLOW")"
DEPLOY_JOB="$(jq -r '.' <<<"$DEPLOY_JOB")"
if [ -n "$DEPLOY_WORKFLOW" ] && [ -z "$DEPLOY_JOB" ]; then
  cm_warn "digest.deploy_workflow is set but digest.deploy_job is not: a run's own conclusion does not prove a prod deploy, name the job that does"; exit 2
fi
GH_DEPLOYS='[]'
RUNS_TRUNC=false
if [ -n "$DEPLOY_WORKFLOW" ]; then
  RUNS_JSON="$(gh_json array run list -R "$GH_REPO" --workflow "$DEPLOY_WORKFLOW" --event push \
    --json databaseId,headBranch,status,conclusion,createdAt,updatedAt --limit "$RUN_LIMIT")"
  if [ "$RUNS_JSON" = null ]; then
    GH_DEPLOYS=null
  else
    # A full page whose oldest run is still inside the window may hide older releases: the heading says "N+".
    RUNS_TRUNC="$(jq -r --argjson e "$SINCE_EPOCH" --argjson n "$RUN_LIMIT" 'length >= $n and (map(.updatedAt // "" | tostring | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch 0) | min) >= $e' <<<"$RUNS_JSON" 2>/dev/null || echo false)"
    # A filter that fails on a malformed row is a failed read, not an empty window.
    # Runs are fetched from 2h before the window: the ledger stamps finishedAt after gh's job finished, and a release gh
    # placed just before the window must not be listed again for its later ledger time.
    if CAND="$(jq -c --argjson e "$(( SINCE_EPOCH - 7200 ))" '[.[] | select((.updatedAt // "" | tostring | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch 0) >= $e)] | .[]' <<<"$RUNS_JSON" 2>/dev/null)"; then
      while IFS= read -r run; do
        [ -n "$run" ] || continue
        view="$(gh_json object run view "$(jq -r '.databaseId' <<<"$run")" -R "$GH_REPO" --json jobs)"
        if [ "$view" = null ]; then GH_DEPLOYS=null; break; fi
        GH_DEPLOYS="$(jq -c --argjson r "$run" --argjson v "$view" '. + [$r + {jobs: ($v.jobs // [])}]' <<<"$GH_DEPLOYS")" || { GH_DEPLOYS=null; break; }
      done <<<"$CAND"
    else
      GH_DEPLOYS=null
    fi
  fi
fi

TZ="$CM_TZ" jq -r --argjson sinceH "$SINCE_H" --argjson since "$SINCE_EPOCH" --argjson ghMerged "$MERGED_JSON" --argjson ghOpen "$OPEN_JSON" \
  --argjson ghDeploys "$GH_DEPLOYS" --argjson runsTrunc "$RUNS_TRUNC" --arg deployJob "$DEPLOY_JOB" \
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

  def tagkey: (. // "" | tostring | ascii_downcase | ltrimstr("v"));
  def depline: "\(.tag) at \(.at | uk)\(if (.prs | length) > 0 then ": " + (.prs | map("#\(.)") | join(" ")) else "" end)\(if .conflict == true then " (ledger says done, gh: no prod deploy job succeeded)" else "" end)";

  (.workers // {} | to_entries | map(.value + {id: .key})) as $workers
  | (.deployWindows // []) as $wins
  | (.asks // []) as $asks
  | (.hosts // {}) as $hosts
  # Deployed. $ld: ledger done rows. $gd: one row per gh run (null when gh failed); ok = the named deploy job succeeded.
  # A row with no tag has no key to merge on: it gets a key of its own, so two tagless releases stay two lines.
  | ([ $wins | to_entries[] | select(.value.state == "done") | .key as $i | .value
       | {k: (if (.tag // "") == "" then "\u0001l\($i)" else (.tag | tagkey) end), tag: (.tag // "?"), at: ((.finishedAt // .at) | ts), prs: ((.prs // []) | map(select(. != null)))} ]) as $ld
  | (if $ghDeploys == null then null else
      [ $ghDeploys | to_entries[] | .key as $i | .value | . as $r
        | ([ ($r.jobs // [])[] | select(.name == $deployJob and .conclusion == "success") ] | sort_by(.completedAt // "") | last) as $pj
        | {k: (if ($r.headBranch // "") == "" then "\u0001g\($i)" else ($r.headBranch | tagkey) end), tag: ($r.headBranch // "?"), ok: ($pj != null),
           hasJob: (($r.jobs // []) | any(.[]; .name == $deployJob)),
           started: (($r.jobs // []) | any(.[]; .conclusion == "success" or .conclusion == "failure")),
           at: (if $pj != null then (($pj.completedAt | ts) // ($r.updatedAt | ts)) else ($r.updatedAt | ts) end),
           live: (($r.status // "") != "completed")} ] end) as $gd
  # gh is the clock when it saw the deploy: the ledger finishedAt is stamped later (after validation), so a release gh
  # already placed outside the window is not listed again because of its ledger time.
  | (($gd // []) | map(select(.ok) | .k)) as $okKeys
  | ($ld | map(select(.at != null and .at >= $since and (.k as $k | $okKeys | index($k) | not)))) as $ldIn
  | (($gd // []) | map(select(.ok and .at != null and .at >= $since))) as $gdIn
  | ([ ($ldIn + $gdIn)[].k ] | unique) as $keys
  | ([ $keys[] as $k
       | ($gdIn | map(select(.k == $k)) | .[0]) as $g
       | ($ldIn | map(select(.k == $k)) | .[0]) as $l
       | {at: ($g.at // $l.at), tag: ($l.tag // $g.tag), prs: ([ $ld[] | select(.k == $k) | .prs[] ] | unique),
          conflict: (($gd // []) | (any(.[]; .k == $k) and (any(.[]; .k == $k and .ok) | not)))} ]
     | sort_by(.at)) as $dep
  | (($gd // []) | map(select((.ok | not) and .at != null and .at >= $since and (.k as $k | $keys | index($k) | not))) | sort_by(.at)
     | map("\(.tag) at \(.at | uk): \(if .live then "still running, no prod deploy job succeeded yet" elif .started then "ran, no prod deploy job succeeded" else "not started (cancelled or skipped), no prod deploy job succeeded" end)")) as $unproven
  | (($gd // []) | map(select(.live | not))) as $done
  | (if ($done | length) > 0 and ($done | any(.[]; .hasJob) | not)
     then ["check digest.deploy_job: none of the \($done | length) finished runs updated in the window has a job named \"\($deployJob)\""] else [] end) as $drift
  | ([ $wins[] | select(.state == "stopped" and ((.finishedAt // .at) | recent))
       | "STOPPED \(.id): \(.blockedReason // "no reason recorded")" ]) as $stopped
  | "\($project) concertmaster digest, \(now | uk) \($tzl) (last \($sinceH)h)",
    "",
    ( if $ghMerged == null then "Merged: unknown (gh failed)", ""
      else ([ $ghMerged | map(select(.mergedAt | recent)) | sort_by(.mergedAt)[]
          | "#\(.number) \(.title // "" | tostring | gsub("[[:cntrl:]]+"; " ") | .[0:60]) (\(.author.login // "?"))" ]) as $m
        | "Merged (\($m | length)\(if ($ghMerged | length) >= $mergedLimit then "+" else "" end))",
          (if ($m | length) == 0 then "- none" else ($m[] | "- " + .) end), "" end ),
    ( if $gd == null then
        "Deployed: unknown (gh failed)",
        ((($ldIn | sort_by(.at) | map(depline)) + $stopped)[] | "- " + .)
      else
        "Deployed (\($dep | length)\(if $runsTrunc then "+" else "" end))",
        (if ($dep | length) + ($unproven | length) + ($stopped | length) + ($drift | length) == 0 then "- none"
         else ((($dep | map(depline)) + $unproven + $drift + $stopped)[] | "- " + .) end) end ),
    "",
    ( if $full | not then empty else section("Needs \($owner)"; [ $workers[] | select(.state == "blocked-on-owner")
        | "\(.lane // "-") \(.task // .id | .[0:60]): \(.blockedQuestion // "see concertmaster")" ]
      + [ $asks[] | select(.state == "open") | "ask: \(.question | .[0:80]) (open \(.askedAt | ago))" ]) end ),
    ( if $full | not then empty else section("Open follow-ups"; [ (.followUps // [])[] | select(.state != "done")
        | "\(.lane // "-")/\(.id) owner \(.owner // "?"), posted by \(.worker // "?"): \(.text // "" | gsub("[[:cntrl:]]+"; " ") | .[0:80]) (open \(.openedAt | ago))" ]) end ),
    ( if $full | not then empty else section("Stuck"; [ $workers[] | select(.state == "stuck")
        | "\(.task // .id | .[0:50]) on \(.host // "?"), idle \(.lastOutputAt | ago), nudges \(.nudges // 0)/2" ]) end ),
    ( if $full | not then empty else def clean: tostring | gsub("[[:cntrl:]]+"; " ");
      (.violationCheck // {}) as $vc
      | if $vc.enabled == false then empty else
        ([ (.violations // [])[] | "\(.agent // "?" | clean) \(.host // "?" | clean) \(.worktree // "?" | clean) \(.handle // "-" | clean) \(.title // "-" | clean | .[0:40])" ]
         + (if $vc.complete == false then ["CHECK INCOMPLETE, not proof of none: \(($vc.gaps // []) | join("; ") | clean | .[0:600])"] else [] end)
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
