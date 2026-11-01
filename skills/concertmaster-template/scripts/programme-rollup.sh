#!/usr/bin/env bash
# programme-rollup.sh: the programme table of every tick report (SKILL.md § Reporting).
#
#   scripts/programme-rollup.sh                          # markdown table, five columns
#   scripts/programme-rollup.sh --classify FILE|-        # also read open PRs from classify.sh JSON
#   scripts/programme-rollup.sh --discover FILE          # also mark rows on a truncated or unreachable host
#   scripts/programme-rollup.sh --json                   # the rows as a JSON array
#
# A programme is a ledger lane: an epic (`epic:<name>`) or a standing lane (pr-sweeper,
# dev-sweeper, a feature sweeper). A lane in state `gone` is not listed. Columns:
#   programme   the lane label
#   lead + host the lead worker's Orca name and host; `none` when there is no live lead
#   state       first line of the lead's last worktree comment (ledger lastComment);
#               `no lead` when the lane has no live lead; `unparsed: <text>` when the
#               line does not start with `cm:`; `ledger:<state>` when there is no comment
#   open PRs    `#n #m (count)`: PRs driven by (ledger `prs[].driver`) or recorded on
#               (`workers.<id>.pr`) a worker of the programme, not MERGED or CLOSED. A worker
#               belongs to ONE programme: the lane it names in `lane` when that is a listed
#               programme, else the programme whose lead is an ancestor in its `parent` chain.
#               A worker that is done, retired or being torn down keeps its worktree, so its open
#               PRs stay listed; only gone and repurposed workers drop out. A worker PR with no repo
#               takes the repo of the one `prs` or classify entry with that number. Repo names
#               are compared by their last path part, lower-cased (`Acme/app` is `app`).
#               With --classify the PR state of every worktree is read this tick and wins over
#               the ledger, in every programme (OPEN adds to the programme that owns the
#               worktree, MERGED or CLOSED removes the PR wherever the ledger lists it)
#   --discover FILE adds the hosts that file lists as unreachable or truncated to the offline hosts,
#               marks a worker whose host the document does not list at all, and marks every open PRs cell when a GitHub PR lookup failed (`gh pr list`, `org-repos`).
#               A --discover file that is unreadable or not JSON marks every cell. A --classify input that is missing, empty or not JSON marks every open PRs cell too.
#   (last tick) appended to state, open PRs or waiting on when the worktree host did not answer
#               this tick (classify `host-offline` row, or the ledger marks the host unreachable),
#               so the value is the ledger's last one, not read now; --json has it in `stale`
#   waiting on  the first `cm:blocked`, `cm:followup <id> owner=<x>` or `cm:waiting-owner`
#               line in the lead's comment, then the children's; else `none`. A follow-up the
#               ledger `followUps[]` holds as done under the poster's lane (`lane`, else its id) is
#               skipped too. Comment lines are read as followups.sh reads them: a literal backslash-n
#               splits, markers are separated by any whitespace, ids are kebab-case
#
# Read-only: the ledger is read through lib.sh (cm_ledger_path) and never written.
# Exit 0 on success. Exit 1 when the ledger is missing or unreadable or the ledger cannot be
# rolled up: the table is still printed, with one `unknown (rollup failed)` row, so a
# redirect to a file never leaves an empty table. Exit 2 on a bad argument.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"


JSON=0
CLASSIFY=""
DISCOVER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1 ;;
    --classify)
      [ $# -ge 2 ] || { cm_warn "programme-rollup.sh: --classify needs a file or -"; exit 2; }
      CLASSIFY="$2"; shift ;;
    --discover)
      [ $# -ge 2 ] || { cm_warn "programme-rollup.sh: --discover needs a file"; exit 2; }
      DISCOVER="$2"; shift ;;
    -h|--help) sed -n '2,42p' "$0"; exit 0 ;;
    *) cm_warn "programme-rollup.sh: unknown arg: $1"; exit 2 ;;
  esac
  shift
done

HEADER='| programme | lead + host | state | open PRs | waiting on |'
SEP='|-----------|-------------|-------|----------|------------|'
# fail <reason>: warn, print the table shell with one unknown row (or [] for --json), exit 1
fail() {
  cm_warn "programme-rollup.sh: $1"
  if [ "$JSON" = 1 ]; then printf '[]\n'; else
    printf '%s\n%s\n%s\n' "$HEADER" "$SEP" "| unknown (rollup failed) | unknown | unknown | unknown | unknown |"
  fi
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "missing dependency: jq"

LEDGER="$(cm_ledger_path)"
{ [ -s "$LEDGER" ] && jq -e 'type == "object"' "$LEDGER" >/dev/null 2>&1; } || fail "ledger $LEDGER missing or unreadable"

# The classify document is optional data: one that is missing, empty or not JSON is warned about and
# dropped, never fatal. Only each item's host, path, repo and pr are read. Several JSON documents
# are merged (jq -s).
ITEMS='{"prs":[],"offline":[]}'
CFAIL=false
if [ -n "$CLASSIFY" ]; then
  DOC=""
  if [ "$CLASSIFY" = "-" ]; then DOC="$(cat)"
  elif [ -r "$CLASSIFY" ]; then DOC="$(cat "$CLASSIFY")"
  else cm_warn "programme-rollup.sh: classify file $CLASSIFY not readable; open PRs from the ledger only"; CFAIL=true; fi
  if [ -z "$DOC" ]; then
    cm_warn "programme-rollup.sh: classify input is empty; open PRs from the ledger only"; CFAIL=true
  elif ! ITEMS="$(printf '%s' "$DOC" | jq -sce '[ .[] | objects | (.items // [])[] | select(type == "object") ] as $it
        | { prs: [ $it[] | select((.pr | type) == "object") | {host, path, repo, number: .pr.number, state: .pr.state} ],
            offline: [ $it[] | select(.class == "host-offline" and (.host | type) == "string") | .host ] | unique }' 2>/dev/null)"; then
    ITEMS='{"prs":[],"offline":[]}'; cm_warn "programme-rollup.sh: classify input is not JSON; open PRs from the ledger only"; CFAIL=true
  fi
fi

# Hosts the census did not see in full this tick: unreachable, or reachable with a truncated worktree list.
# The discover document is optional data like classify: unreadable or not JSON is warned about and dropped.
DOFF='{"hosts":[],"known":null,"prFailed":false,"failed":false}'
if [ -n "$DISCOVER" ]; then
  if [ ! -r "$DISCOVER" ]; then cm_warn "programme-rollup.sh: discover file $DISCOVER not readable; every row is marked (last tick)"; DOFF='{"hosts":[],"known":null,"prFailed":true,"failed":true}'
  elif ! DOFF="$(jq -ce '{ known: ((if (.hosts | type) == "array" then [ .hosts[] | select(type == "object" and (.name | type) == "string") | .name ] else [] end) | if length == 0 then null else . end),
                          hosts: ([ (.hosts // [])[] | select(type == "object" and (.name | type) == "string" and (.reachable == false or .truncated == true)) | .name ] | unique),
                          failed: false,
                          prFailed: ((.errors // []) | map(select(type == "object" and (.where | type) == "string" and (.where | test("^(gh pr list|org-repos)")))) | length > 0) }' "$DISCOVER" 2>/dev/null)"; then
    DOFF='{"hosts":[],"known":null,"prFailed":true,"failed":true}'; cm_warn "programme-rollup.sh: discover input is not JSON; every row is marked (last tick)"
  fi
fi

# Worker states: gone and repurposed are dead (the same list followups.sh uses).
# shellcheck disable=SC2016  # jq program text, not shell
STATE_DEFS='def cm_state_norm: .; def cm_state_dead: cm_state_norm as $s | ($s | type) == "string" and ($s | IN("gone", "repurposed")); '

ROWS="$(jq -c --argjson doff "$DOFF" --argjson cfail "$CFAIL" --slurpfile items <(printf '%s' "$ITEMS") "$STATE_DEFS"'
  def obj: if type == "object" then . else {} end;
  def str: if type == "string" then . else "" end;
  def scrub: if type == "string"
    then gsub("(sbp_|sk_live_|sk_test_|ghp_|gho_|github_pat_|sb_secret_|sb_publishable_|whsec_|rk_live_|rk_test_|ghs_|ghu_|ghr_|glpat-|xapp-|xoxa-|xoxe-|AKIA|AIza|eyJ)[A-Za-z0-9_.-]{8,}|\\bBearer +[A-Za-z0-9_.=-]{12,}|\\bsk-[A-Za-z0-9_-]{16,}|\\bxox[bp]-[A-Za-z0-9-]{8,}"; "[redacted]")
    else . end;
  # one table cell: no pipe, no control character, no line break, trimmed, cut to n
  def cell($n): if type == "string"
    then scrub | gsub("[\u0001-\u001f\u007f]+"; " ") | gsub("[|]"; "/") | gsub("^ +| +$"; "") | .[0:$n]
    else "" end;
  def lines: if type == "string" then [gsub("\\\\n"; "\n") | split("\n")[] | split(" | ")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0)] else [] end;
  def np: str | sub("/+$"; "");
  def rn: str | split("/") | last // "" | ascii_downcase;
  def closed: (.state | str | ascii_upcase) | IN("MERGED", "CLOSED");
  def prkey: ((.repo | str) + "#" + (.number | tostring));
  def dead2: cm_state_dead or (cm_state_norm | IN("done", "retired", "teardown"));

  . as $L
  | (.workers | obj) as $W
  | (.prs | obj | [ .[] | select(type == "object" and (.number | type) == "number") ]) as $P
  | ($items[0] // {}) as $IT
  | ($IT.prs | if type == "array" then . else [] end) as $I
  | ([ ($IT.offline | if type == "array" then .[] else empty end | str),
       ($doff.hosts[] | str),
       ((.hosts | obj) | to_entries[] | select((.value | type) == "object" and (.value.reachable == false or (.value.offlineSince | type) == "string")) | .key) ]) as $OFF
  | def offh: (.host | str) as $h | $h != "" and (($OFF | index($h) != null) or ($doff.known != null and ($doff.known | index($h) == null)));
    ([ ($P[] | {repo: (.repo | rn), n: .number, closed: closed}), ($I[] | select(type == "object" and (.number | type) == "number") | {repo: (.repo | rn), n: .number, closed: closed}) ]) as $G
  | (.followUps | if type == "array" then [ .[] | select(type == "object" and .state == "done") ] else [] end) as $FD
  | ((.lanes | obj) | with_entries(select((.value | type) == "object" and ((.value.state // "") != "gone")))) as $LN
  # a lane lead owns its programme while its worker row exists and is not dead (gone or repurposed); it is a
  # LIVE lead only when it is also not done, retired or being torn down (a finished lead still owns its PRs)
  | (reduce ($LN | to_entries[]) as $e ({}; ($e.value.lead) as $ld
        | if ($ld | type) == "string" and ($W[$ld] | type) == "object" and (($W[$ld].state // "running") | cm_state_dead | not)
          then . + {($ld): $e.key} else . end)) as $leadOf
  # each live worker belongs to ONE programme: its own lead row, else the listed lane it names, else the
  # programme whose lead is the nearest ancestor in its parent chain (at most 12 hops)
  | def home($id; $n): ($W[$id] | obj) as $w
      | if $leadOf[$id] != null then $leadOf[$id]
        elif ($w.lane | type) == "string" and ($LN[$w.lane] != null) then $w.lane
        elif $n == 0 or ($w.parent | type) != "string" then null
        else home($w.parent; $n - 1) end;
    ([ $W | to_entries[] | select((.value | type) == "object" and ((.value.state // "running") | cm_state_dead | not))
       | {id: .key, w: .value, live: ((.value.state // "running") | dead2 | not), lane: home(.key; 12)} | select(.lane != null) ]) as $members
  | [ $LN | to_entries[]
      | .key as $lane | .value as $ln
      | (if $leadOf[($ln.lead | str)] != null then $ln.lead else null end) as $lid
      | ($W[$lid // ""] // null) as $lead
      | ($lead != null and (($lead.state // "running") | dead2 | not)) as $llive
      | ([ $members[] | select(.lane == $lane and .id != $lid) ]) as $kids
      | ([ (if $lid != null then [{id: $lid, w: $lead, live: $llive}] else [] end)[], $kids[] ]) as $team
      | ($team | map(.id)) as $ids
      # open PRs. The state of a PR comes from the global table $G (ledger entries, then this tick'"'"'s classify
      # observations, which win), so a MERGED or CLOSED observation clears it in every programme. This programme
      # owns a PR when a team member drives it (prs[].driver), records it (workers.<id>.pr) or has its worktree
      # in classify. A worker.pr with no repo takes the repo of a PR the team drives, else the one classify saw
      # on the team'"'"'s worktrees, else the only repo the ledger holds with that number.
      | ($team | map(.w | {host: (.host | str), path: (.path | np)})) as $wts
      | ([ $I[] | select(type == "object" and (.number | type) == "number") | . as $i
           | select($wts | any(.host == ($i.host | str) and .path == ($i.path | np))) ]) as $fresh
      | ([ $P[] | select(.driver as $d | $ids | index($d)) | {repo: (.repo | rn), n: .number} ]) as $own
      | ([ $fresh[] | {repo: (.repo | rn), n: .number} ]) as $fr
      | ([ $team[] | .w.pr? | (if type == "number" then . elif type == "object" and (.number | type) == "number" then .number else empty end) as $n
           | ([ $own[] | select(.n == $n) | .repo ] | unique) as $r1
           | ([ $fr[] | select(.n == $n) | .repo ] | unique) as $r2
           | ([ $P[] | select(.number == $n) | (.repo | rn) ] | unique) as $r3
           | {repo: (if ($r1 | length) == 1 then $r1[0]
                     elif ($r1 | length) == 0 and ($r2 | length) == 1 then $r2[0]
                     elif ($r1 | length) == 0 and ($r2 | length) == 0 and ($r3 | length) == 1 then $r3[0]
                     else "" end), n: $n} ]) as $wp
      | ($own + $fr + $wp | unique) as $keys
      | ($keys | map(select(.repo != "" or (.n as $n | $keys | any(.n == $n and .repo != "") | not)))
         | map(. as $k | ([ $G[] | select(.repo == $k.repo and .n == $k.n) ]) as $x
               | (if ($x | length) > 0 then $x[-1].closed
                  elif $k.repo != "" then false
                  else ([ $G[] | select(.n == $k.n) ] | length > 0 and (any(.[]; .closed | not) | not)) end) as $c
               | $k + {closed: $c})
         | map(select(.closed | not) | {repo, n})) as $open
      | ($open | sort_by(.n)) as $pl
      | (if $llive | not then "no lead"
         else ($lead.lastComment | if type == "string" then lines | first // null else null end) as $l1
           | if $l1 == null then "ledger:" + (($lead.state // "unknown") | tostring | cell(40))
             elif ($l1 | startswith("cm:")) then $l1 | cell(70)
             else "unparsed: " + ($l1 | cell(50)) end
         end) as $state
      | (first(
          $team[] | select(.live) | .id as $wid | .w as $w | ($w.lastComment | lines) as $ls
          | ([ $ls[] | (capture("^cm:followup-done\\s+(?<id>[a-z0-9][a-z0-9-]{0,39})(?:\\s.*)?$") // empty) | .id ]
             + [ $FD[] | select(.lane == ($w.lane // $wid)) | .id | str ]) as $done
          | $ls[]
          | (if test("^cm:blocked(\\s|$)") then "blocked" + (sub("^cm:blocked\\s*"; "") | cell(90) | if . == "" then "" else ": " + . end)
             elif test("^cm:waiting-owner(\\s|$)") then "waiting-owner" + (sub("^cm:waiting-owner\\s*"; "") | cell(90) | if . == "" then "" else ": " + . end)
             elif test("^cm:followup\\s") then
               (capture("^cm:followup\\s+(?<id>[a-z0-9][a-z0-9-]{0,39})\\s+owner=(?<owner>[A-Za-z0-9._:-]{1,40})(?:\\s+(?<text>.*))?$") // null)
               | if . == null or (.id | IN($done[])) then empty
                 else "followup owner=\(.owner | ascii_downcase | cell(40)): \((.text // "") | cell(90))" end
             else empty end)
          ) // "none") as $wait
      | { programme: ($lane | cell(60)),
          lead: (if $llive | not then null
                 else (($lead.path | str) | split("/") | map(select(. != "")) | last // null) // $lid | cell(60) end),
          host: (if $llive | not then null else ($lead.host | if type == "string" and length > 0 then cell(40) else null end) end),
          state: $state,
          prs: ($pl | map(.n)),
          prLabels: ($pl | map(.n as $n | if ($pl | map(select(.n == $n)) | length) > 1 and .repo != ""
                                           then "\(.repo | split("/") | last)#\($n)" else "#\($n)" end)),
          prCount: ($pl | length),
          waitingOn: $wait,
          stale: { state: ($llive and ($doff.failed or ($lead | offh))),
                   prs: ($doff.prFailed or $cfail or ($team | any(.w | offh))),
                   waiting: ($doff.failed or ($team | any(.live and (.w | offh)))) } } ]
  | sort_by(.programme)' "$LEDGER" 2>&1)" || fail "ledger $LEDGER could not be rolled up: $(printf '%s' "$ROWS" | head -1 | cut -c1-120)"

if [ "$JSON" = 1 ]; then
  printf '%s\n' "$ROWS" | jq 'map(del(.prLabels))'
  exit 0
fi

printf '%s\n%s\n' "$HEADER" "$SEP"
printf '%s\n' "$ROWS" | jq -r '
  if length == 0 then "| none | none | none | none | none |"
  else .[] |
    def lt($stale): if $stale then " (last tick)" else "" end;
    "| \(.programme) | \(if .lead == null then "none" else "\(.lead) @ \(.host // "?")" end) | \(.state)\(lt(.stale.state)) | \(
        if .prCount == 0 then "0" else "\(.prLabels | join(" ")) (\(.prCount))" end)\(lt(.stale.prs)) | \(.waitingOn)\(lt(.stale.waiting)) |"
  end'
