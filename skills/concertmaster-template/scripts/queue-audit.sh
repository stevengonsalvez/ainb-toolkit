#!/usr/bin/env bash
# queue-audit.sh: flag granted or queued work items that show no progress.
#
#   scripts/queue-audit.sh        # one line per open queue item
#
# For each item in the ledger queue (state granted or queued) it counts the pull
# requests created since the grant that name the issue, and the worktree comments
# (every host) that name it. STALLED = neither one after 30 minutes
# (CM_QUEUE_STALL_MIN). A fresh-looking lane comment is not proof of progress
# (references/queue.md).
#
#   OK          <id> <lane> <state> age=<min>m prs=<n> worktrees=<n>
#   STALLED     <id> <lane> <state> age=<min>m prs=0 worktrees=0
#   UNKNOWN-AGE no parseable grantedAt or addedAt: age cannot be judged, never OK or STALLED
#   NO-ISSUE    the item has no issue number: progress cannot be matched, never OK or STALLED
#   UNVERIFIED  would be STALLED but a host was not read this run (its work may be there)
# If the gh call fails (rate limit, network) it prints `STALE gh call failed, no verdicts`
# and exits 3: a tick must never read "no PRs" as "no progress". Run it only after the tick's
# rate-limit check (SKILL.md, The tick). Hosts that could not be read are listed on stderr
# as `unread: <host>`.
#
# Read-only. Network use: ONE gh call plus one Orca worktree list per host.
# Needs: gh, jq, the Orca CLI. Scope comes from config (github.org/main_repo,
# worktrees.orca_repo, worktrees.path_match) through lib.sh.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"
[ -n "$CM_ORG" ] && [ -n "$CM_REPO" ] || { cm_warn "queue-audit.sh: set github.org and github.main_repo in config"; exit 2; }
[ -n "$CM_PATH_MATCH" ] || { cm_warn "queue-audit.sh: set worktrees.path_match in config (or CM_PATH_MATCH)"; exit 2; }
ORCA="$(cm_orca)"
L="$CM_HOME/ledger.json"
[ -r "$L" ] || { cm_warn "queue-audit.sh: no ledger at $L"; exit 2; }
STALL_MIN="${CM_QUEUE_STALL_MIN:-30}"
ORCA_REPO="$(cm_cfg .worktrees.orca_repo)"

now=$(date -u +%s)
# Portable ISO-8601 to epoch (no GNU date): jq parses it, fractions dropped.
epoch() {
  jq -nr --arg t "$1" '$t | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | sub("T(?<h>[0-9]{2}:[0-9]{2})Z$"; "T\(.h):00Z") | fromdateiso8601' 2>/dev/null || true
}
since=$(jq -nr --argjson e $((now - 3 * 86400)) '$e | strftime("%Y-%m-%d")')

if ! prs=$(gh pr list -R "$CM_ORG/$CM_REPO" --state all --limit 150 --search "updated:>=$since" \
  --json number,title,body,state,createdAt 2>/dev/null) || ! jq -e 'type == "array"' <<<"$prs" >/dev/null 2>&1; then
  echo "STALE gh call failed, no verdicts"
  exit 3
fi

# Every worktree comment on every host, one "name :: comment" line each.
cm=""
hosts="local"
for e in $("$ORCA" host list --json 2>/dev/null </dev/null | jq -r '.result.hosts[]? | select(.name != "this machine") | .name'); do
  hosts="$hosts $e"
done
unread=""
for h in $hosts; do
  args=()
  [ "$h" = local ] || args=(--environment "$h")
  [ -n "$ORCA_REPO" ] && args+=(--repo "name:$ORCA_REPO")
  raw=$(cm_timeout 30 "$ORCA" worktree list ${args[@]+"${args[@]}"} --limit 500 --json 2>/dev/null </dev/null)
  if ! jq -e '.result.worktrees | type == "array"' <<<"$raw" >/dev/null 2>&1; then
    unread="$unread $h"; echo "unread: $h" >&2; continue
  fi
  cm+=$(jq -r --arg re "$CM_PATH_MATCH" '.result.worktrees[]? | select((.path // "") | test($re)) | "\((.path | split("/") | last)) :: \((.comment // "") | gsub("\n"; " "))"' <<<"$raw")$'\n'
done

jq -r '.queue.items[]? | select(.state == "granted" or .state == "queued")
  | [.id, (.issue // "" | tostring), (.lane // "-"), (.grantedAt // .addedAt // ""), .state] | join("|")' "$L" \
| while IFS='|' read -r id iss lane at st; do   # '|' not tab: tab is whitespace and collapses empty fields
    t=""; [ -n "$at" ] && t=$(epoch "$at")
    if [ -z "$t" ]; then
      printf '%-11s %-20s %-18s %-8s age=?\n' UNKNOWN-AGE "$id" "$lane" "$st"; continue
    fi
    age=$(( (now - t) / 60 ))
    if [ -z "$iss" ] || [ "$iss" = null ]; then
      printf '%-11s %-20s %-18s %-8s age=%4sm\n' NO-ISSUE "$id" "$lane" "$st" "$age"; continue
    fi
    npr=$(jq --arg i "#$iss" --arg at "$at" '[.[] | select(.createdAt >= $at) | select((.title + " " + (.body // "")) | test($i + "([^0-9]|$)"))] | length' <<<"$prs")
    nwt=$(grep -cE -- "(^|[^0-9])#?$iss([^0-9]|$)" <<<"$cm" || true)
    flag=OK
    if [ "$npr" -eq 0 ] && [ "$nwt" -eq 0 ] && [ "$age" -ge "$STALL_MIN" ]; then
      if [ -n "$unread" ]; then flag=UNVERIFIED; else flag=STALLED; fi
    fi
    printf '%-11s %-20s %-18s %-8s age=%4sm prs=%s worktrees=%s\n' "$flag" "$id" "$lane" "$st" "$age" "$npr" "$nwt"
  done
