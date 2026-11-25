#!/usr/bin/env bash
# digest.sh: build the twice-daily digest text. Prints to stdout only; sending
# (config messaging.owner_digest) is the concertmaster's job, see SKILL.md.
#
#   scripts/digest.sh [--full] [--ledger <path>] [--since-hours <n>]
#
# Default output is the text for a chat group: terse "- " bullets, no greeting.
# Sections: Priorities FIRST (ledger .priorities, every state but done and dropped, lowest rank first, at most 10; the group text and --full), then merged, deployed (and stopped deploys), Open PRs, Lanes, Waiting on <name> x2, fleet health, plus a "Next" line
# when work is queued. Open PRs lists EVERY open PR (tooling too), see "In progress" below.
# The group text leaves the concertmaster's own tooling PRs out of Merged (title scope in
# digest.hide_scopes, default [concertmaster]; or every changed file under a prefix in
# digest.hide_paths, default [".agents/skills/concertmaster/"]) and says so in ONE line:
# "Tooling: N concertmaster PRs merged, M open" (the label names every hide_scope). The line prints whenever N or M
# is above zero, so an open tooling PR shows even when none merged in the window. Drafts count as open.
# --full lists every merged PR. A queue item with no
# issue shows as its id (and summary); the text never contains "#null".
# Fleet health (ledger .health from scripts/lane-health.sh --all): session counts per status word, restarts in the
# window and "concertmaster check missing" when the last check is older than 2 lane loops; no names in the group text.
# --full adds the rest, for the concertmaster's terminal report and never for the group:
# "Blocked on you" right after Priorities (only the owner's items, SKILL.md § Reporting: every open ledger ask that
# ask_owner_why in scripts/ask-deny.sh calls owner-only, the one definition scripts/stall.sh exempts as Blocked: every
# kind but the delegated release and deploy, and an own-scope code, design, test, scope or product ask that passes the
# ask-timeout.sh gates and the deny scan; secrets always, and a missing or unknown kind; every cm:blocked,
# cm:waiting-owner line in a lane's worktree comment on every host, and a cm:ask in the
# concertmaster's own worktree, worktrees.self_name; ledger workers blocked-on-owner. A host not read is not an owner
# item: it is listed under Fleet health, and the Blocked heading counts it, "(N, M hosts not read, see Fleet health)",
# so an unread host is never read as none), "Decided while you were away" (ledger decisions[], the self-unblocks scripts/stall.sh --act ... verdict
# records, from the earlier of the window start and 12 hours ago, so the 08:00 and 18:00 reports cover the last 12 hours
# and nothing since the last send is skipped), "Programmes" and "Census" (the programme table and census lines the tick
# writes to $CM_HOME/programmes.md and $CM_HOME/census.txt, printed as written with their age; a missing file says so),
# needs <owner>, open follow-ups (ledger followUps[], scripts/followups.sh), decided while <owner> was away (away-timeout verdicts, rule 16), stuck,
# forbidden agents on <project> work (only when ledger.violations has rows or ledger.violationCheck is
# incomplete), Supabase stacks without a worktree (only when
# ledger.supabaseStacks has orphans or is incomplete), and a one-line fleet footer (running, hosts, open PRs).
# In progress, always everything, in the group text and in --full: "Open PRs" lists EVERY open PR
# (tooling PRs too) grouped by area (the title's conventional-commit scope, else "other"), one plain-English line
# and its state each (draft, waiting for review, changes requested, approved); "Lanes" lists every active lane
# (the worktree comment's first cm: state: running, busy, merge-ready, queued, spawning, stuck, blocked, ask,
# waiting-owner) with that line, read from the worktree comments on every host through scripts/fleet-read.sh;
# then "Waiting on <name 1>" and "Waiting on <name 2>" (config digest.waiting_on, default [<owner name>, Reviewer]).
# Waiting on name 1: every cm:ask / cm:blocked / cm:waiting-owner line (a name found in the text moves it to that name),
# every open ledger ask and every blocked-on-owner lane. Waiting on name 2 also carries the open non-draft PRs that
# still need review (one line of numbers). An unreachable host or a failed gh read says so; it is never a silent zero.
# Window: --since-hours <n>, else the time since ledger digests.lastSentAt, else 12h
# (a lastSentAt that is missing, unparseable or in the future counts as missing). The
# window starts exactly there: a PR merged before lastSentAt is not listed twice; the header
# shows the gap in hours, rounded up.
# Merged, Deployed and the open PR count come from GitHub (gh), NOT the ledger alone: the ledger
# can lose rows and a ledger zero would read as fact. gh is asked for the main repo
# ($CM_ORG/$CM_REPO), under a CM_DIGEST_GH_TIMEOUT (default 30s) timeout. When gh fails
# (auth, rate limit, offline, timeout, garbage) the digest says "Merged: unknown (gh
# failed)", "Deployed: unknown (gh failed)" and "open PRs: unknown (gh failed)", never a zero. At most 100
# merged PRs are listed (the heading then reads "100+"), at most 1000 open PRs are counted.
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
# Sources: Merged and Open PRs from gh; Deployed from gh workflow jobs plus the ledger; Lanes from the worktree
# comments on every host (fleet CLI); Waiting on from the lanes, the ledger and gh; every other section from the
# ledger. Default ledger: $CM_HOME/ledger.json. Times
# print in config schedule.timezone (CM_TZ), labelled schedule.timezone_label. Plain
# text, chat friendly, no em-dashes. Read-only: it never writes the ledger (the
# digests.lastSentAt write after a send is the concertmaster's, through cm_ledger_write).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"
# shellcheck source=SCRIPTDIR/fleet-read.sh
. "$HERE/fleet-read.sh"
# shellcheck source=SCRIPTDIR/ask-deny.sh
. "$HERE/ask-deny.sh"
# shellcheck source=SCRIPTDIR/secret-shape.sh
. "$HERE/secret-shape.sh"

# The report carries untrusted text (ask questions and ids, worktree comment lines, lane, host and owner names, PR
# titles), and the group text leaves this host. Every output line that looks like a credential is withheld whole (the
# line analog of the per-field pass of scripts/stall.sh --json, which prints fields, where this prints lines): a token
# prefix or key block as written, or a long run with dashes read as spaces (so a long kebab-case lane name is not one),
# or a run of 40 or more mixed with upper case and digits as written. A "- " list line keeps its bullet.
DIGEST_WH='[withheld: looks like a credential]'
line_looks_secret() {
  { secret_shaped_prefix "$1" || secret_shaped "${1//-/ }"; } && return 0
  local r
  for r in $(printf '%s' "$1" | grep -oE '[A-Za-z0-9_-]{40,}'); do
    [[ "$r" =~ [A-Z] ]] && [[ "$r" =~ [0-9] ]] && return 0
  done
  return 1
}
# The same answer as line_looks_secret with no fork for almost every line (a report can carry 1000 PR lines, and the
# full check forks several times per line). DIGEST_WH_GATE: the full check can only say yes for a line that holds a
# token prefix, a run of 20 or more token characters, the start of a raw key or one of the words its phrase check reads
# (bearer, password, passwd, passphrase, login, sign-in, signin), in any case; every step of it only removes text (a
# dash read as a space, a 40-hex blanked), so a line outside the gate is never credential-shaped. DIGEST_WH_SLOW: a
# token prefix, a key block or a phrase word goes to the full check itself. Any other line through the gate is judged
# here by the two run rules of the full check, computed the same way: a run of 40 or more with dashes read as spaces
# that is not exactly 40 lower-case hex (a commit sha, which the full check blanks), or a run of 40 or more as written
# that mixes upper case and digits.
DIGEST_WH_WORDS='0\.[0-9A-Fa-f]{8}-|[Bb][Ee][Aa][Rr][Ee][Rr]|[Pp][Aa][Ss][Ss][WwPp]|[Ll][Oo][Gg][Ii][Nn]|[Ss][Ii][Gg][Nn]-?[Ii][Nn]'
DIGEST_WH_GATE="$_SS_PREFIX|[A-Za-z0-9_-]{20,}|$DIGEST_WH_WORDS"
DIGEST_WH_SLOW="$_SS_PREFIX|-----BEGIN|$DIGEST_WH_WORDS"
line_secret_fast() {
  local l="$1" t m
  [[ "$l" =~ $DIGEST_WH_GATE ]] || return 1
  t="${l//-/ }"
  if [[ "$l" =~ $DIGEST_WH_SLOW ]] || [[ "$t" =~ $_SS_PREFIX ]]; then line_looks_secret "$l"; return; fi
  while [[ "$t" =~ [A-Za-z0-9_]{40,} ]]; do
    m="${BASH_REMATCH[0]}"
    if [ "${#m}" -eq 40 ] && [[ "$m" =~ ^[0-9a-f]+$ ]]; then t="${t/"$m"/ }"; else return 0; fi
  done
  t="$l"
  while [[ "$t" =~ [A-Za-z0-9_-]{40,} ]]; do
    m="${BASH_REMATCH[0]}"
    [[ "$m" =~ [A-Z] ]] && [[ "$m" =~ [0-9] ]] && return 0
    t="${t/"$m"/ }"
  done
  return 1
}
digest_withhold() {
  local l
  while IFS= read -r l || [ -n "$l" ]; do
    if [ -n "$l" ] && line_secret_fast "$l"; then
      case "$l" in "- "*) printf -- '- %s\n' "$DIGEST_WH" ;; *) printf '%s\n' "$DIGEST_WH" ;; esac
    else
      printf '%s\n' "$l"
    fi
  done
}

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
jq -e 'type == "object"' "$LEDGER" >/dev/null 2>&1 || { cm_warn "digest: ledger $LEDGER is not a JSON object: no digest built"; exit 1; }
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
HIDE_SCOPES="$(cm_cfg_json '.digest.hide_scopes' '["concertmaster"]')"
HIDE_PATHS="$(cm_cfg_json '.digest.hide_paths' '[".agents/skills/concertmaster/"]')"
# Lists of non-empty strings: an empty prefix would match every file and hide every PR.
printf '%s' "$HIDE_SCOPES" | jq -e 'type == "array" and all(.[]; type == "string" and . != "")' >/dev/null 2>&1 || { cm_warn "digest.hide_scopes must be a list of non-empty strings"; exit 2; }
printf '%s' "$HIDE_PATHS" | jq -e 'type == "array" and all(.[]; type == "string" and . != "")' >/dev/null 2>&1 || { cm_warn "digest.hide_paths must be a list of non-empty strings"; exit 2; }
# internal: is this PR (title, files) the concertmaster's own tooling? When hide_paths is set and gh gave
# a file list, a visible file outside every prefix means product code (never hidden, even at gh's 100-file cap);
# a complete list (1 to 99 files) all under a prefix means tooling. Without hide_paths, or with no list or a cut-off
# list that is all under a prefix, the title scope decides: every scope in the title is a hidden scope.
# A scope alone never hides a PR whose files are known to include product code.
# shellcheck disable=SC2016 # a jq program, $vars are jq's
INTERNAL_DEF='
  def internal: (.title // "" | tostring) as $t
    | (.files // []) as $f
    | (def under: .path | type == "string" and (. as $p | $hidePaths | any(. as $h | $p | startswith($h)));
       if ($hidePaths | length) > 0 and ($f | any(.[]; under | not)) then false   # a visible file outside every prefix: product code
       elif ($hidePaths | length) > 0 and ($f | length) > 0 and ($f | length) < 100 then true   # all visible files under a prefix, list complete
       else "scope" end) as $by
    | if $by != "scope" then $by
      else ([ $t | capture("^[A-Za-z]+\\((?<s>[^)]*)\\)!?:") | .s | split(",") | map(gsub("^\\s+|\\s+$"; "") | ascii_downcase) | .[] ]) as $sc
        | (($sc | length) > 0 and ($sc | all(. as $x | $hideScopes | map(ascii_downcase) | index($x) != null))) end;'

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
# gh_prs <gh pr list args>: the PR rows of the one repository this digest reads (CM_ORG/CM_REPO), or null when the read failed:
# a repository that cannot be read is never shown as having no PRs. Only that one repository is read.
gh_prs() { gh_json array pr list -R "$GH_REPO" "$@"; }
# The group text also needs each PR's changed files (to tell tooling PRs from product ones); --full lists
# every PR, so it only needs the open count. The open list is always read: an open tooling PR must show
# even when none merged in the window.
if $FULL; then
  MERGED_FIELDS=number,title,mergedAt,author,url
  OPEN_FIELDS=number,title,isDraft,reviewDecision
else
  MERGED_FIELDS=number,title,mergedAt,author,url,files
  OPEN_FIELDS=number,title,isDraft,reviewDecision,files
fi
MERGED_JSON="$(gh_prs --state merged --search "merged:>=$CUTOFF" --json "$MERGED_FIELDS" --limit "$MERGED_LIMIT")"
OPEN_JSON="$(gh_prs --state open --json "$OPEN_FIELDS" --limit "$OPEN_LIMIT")"
# A row that is not an object with a numeric number is a malformed answer: a failed read, never a PR.
printf '%s' "$OPEN_JSON" | jq -e 'type == "array" and all(.[]; type == "object" and (.number | type == "number"))' >/dev/null 2>&1 || OPEN_JSON=null

# Waiting-on names: [owner who answers asks, reviewer who approves PRs], default [the owner's name, "Reviewer"].
WAIT_DEF="$(jq -nc --arg o "${CM_OWNER_NAME:-Owner}" '[$o, (if ($o | ascii_downcase) == "reviewer" then "Second reviewer" else "Reviewer" end)]')"
WAIT_NAMES="$(cm_cfg_json '.digest.waiting_on' "$WAIT_DEF")"
printf '%s' "$WAIT_NAMES" | jq -e 'type == "array" and length == 2 and all(.[]; type == "string" and (gsub("^\\s+|\\s+$"; "") != "") and (test("[[:cntrl:]]") | not)) and ((map(gsub("^\\s+|\\s+$"; "") | ascii_downcase) | unique | length) == 2)' >/dev/null 2>&1 || { cm_warn "digest.waiting_on must be a list of exactly two distinct non-empty names"; exit 2; }
WAIT_NAMES="$(printf '%s' "$WAIT_NAMES" | jq -c 'map(gsub("^\\s+|\\s+$"; ""))')"

# Lanes: every worktree comment on every host (scripts/fleet-read.sh, the reader asks.sh uses). LANES_JSON is
# {"hosts":[names read], "unreach":[{host,error}], "wts":[{host,lane,first:{tag,text}|null,waits:[{tag,text}]}]},
# or "null" when the fleet CLI cannot be resolved at all. An unreachable host is listed, never read as "no lanes".
LANES_JSON=null
DTMP="$(mktemp -d "${TMPDIR:-/tmp}/cm-digest.XXXXXX" 2>/dev/null || true)"
if [ -z "$DTMP" ] || [ ! -d "$DTMP" ]; then
  LANES_JSON='{"hosts":[],"unreach":[{"host":"digest","error":"could not create a temp dir to read the lanes"}],"wts":[]}'
else
  trap 'rm -rf -- "${DTMP:?}"' EXIT
  if cm_cli >/dev/null 2>&1; then
    mkdir -p "$DTMP/fleet"
    cm_fleet_worktrees "$DTMP/fleet" || true
    NEVER_L="${CM_NEVER_TOUCH:-$(cm_cfg .worktrees.never_touch)}"
    # shellcheck disable=SC2086  # NEVER_L is a space-joined list on purpose
    printf '%s\n' $NEVER_L | tr '[:upper:]' '[:lower:]' | grep . | jq -R . | jq -sc . > "$DTMP/never.json" 2>/dev/null || printf '[]\n' > "$DTMP/never.json"
    : > "$DTMP/wts.ndjson"
    li=0
    while IFS="$(printf '\t')" read -r hname wl; do
      li=$((li + 1))
      [ -n "$wl" ] || continue
      # shellcheck disable=SC2016  # jq program
      jq -c -L "$HERE" --arg host "$hname" --arg self "${CM_SELF_WORKTREE:-}" --slurpfile never "$DTMP/never.json" '
        include "comment-segs";
        def clean: tostring | gsub("[[:cntrl:]]+"; " ");
        # a worktree list that is not a list is a host not read (listed under Fleet health), never a host with no
        # lanes; a row that is not an object is dropped and the other rows of the host are still read
        (.result.worktrees | if type == "array" then .[] else error("worktree list is not a list") end) | select(type == "object")
        | . as $w
        | (($w.displayName | if type == "string" then . else null end) // (($w.path // "") | if type == "string" then split("/") | last else "" end) // "") as $n
        | select((($n | tostring | ascii_downcase) as $l | any($never[0][]; . == $l)) | not)
        | ([ ($w.comment | comment_segs[])
             | capture("^cm:(?<tag>[a-z][a-z-]*)(?::|\\s+|$)\\s*(?<text>.*)$")?
             | {tag, text: ((.text | tostring | .[0:600] | clean | sub("^\\s+"; "") | sub("\\s+$"; "")) | .[0:300])} ]) as $t
        | select(($t | length) > 0)
        | {host: $host, lane: ($n | clean | if . == "" then "(unnamed)" else . end), first: $t[0], waits: [ $t[] | select(.tag | IN("ask", "blocked", "waiting-owner")) ],
           self: ($self != "" and ($n | tostring | ascii_downcase) == ($self | ascii_downcase)),
           blk: [ $t[] | select(.tag | IN("blocked", "waiting-owner")) ]}
      ' "$wl" >> "$DTMP/wts.ndjson" 2>"$DTMP/jq-$li.err" || \
        jq -cn --arg h "$hname" --arg e "comments unreadable: $(head -c 120 "$DTMP/jq-$li.err")" '{host:$h, error:$e}' >> "$DTMP/fleet/unreach.ndjson"
    done < <(jq -r '[.host, .file] | @tsv' "$DTMP/fleet/hosts.ndjson")
    LANES_JSON="$(jq -cn --slurpfile h "$DTMP/fleet/hosts.ndjson" --slurpfile u "$DTMP/fleet/unreach.ndjson" --slurpfile w "$DTMP/wts.ndjson" \
      '{hosts: ($h | map(.host)), unreach: ($u | map({host: (.host // "?"), error: (.error // "?")})), wts: $w}' 2>/dev/null || echo null)"
  fi
fi

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
        # $view carries every job and step of the run: it goes in through process substitution, never argv.
        GH_DEPLOYS="$(jq -c --slurpfile r <(printf '%s' "$run") --slurpfile v <(printf '%s' "$view") '. + [$r[0] + {jobs: ($v[0].jobs // [])}]' <<<"$GH_DEPLOYS")" || { GH_DEPLOYS=null; break; }
      done <<<"$CAND"
    else
      GH_DEPLOYS=null
    fi
  fi
fi

# MERGED_JSON, OPEN_JSON and GH_DEPLOYS can each pass 128 KB, and Linux refuses one argv string that long
# (MAX_ARG_STRLEN: jq exits 126 "Argument list too long"). They go in through process substitution
# (--slurpfile reads /dev/fd/N, no temp file to clean up) and the program unwraps each one below.
# Only small scalars and the two config lists stay on --argjson.
# Fleet health is "missing" when the last lane-health.sh --all is older than 2 lane loops (schedule.lane_loop_minutes, 30).
HEALTH_STALE_S="$(cm_cfg .schedule.lane_loop_minutes 30)"
case "$HEALTH_STALE_S" in ''|*[!0-9]*) HEALTH_STALE_S=30 ;; esac
HEALTH_STALE_S=$((10#$HEALTH_STALE_S * 120))

# --full only: the programme table (tick step 5) and the census lines (tick step 3) the tick wrote, as {text, mtime},
# or null when the file is missing or unreadable. The tick report no longer prints them (SKILL.md § Reporting).
file_doc() {
  local f="$1" m
  if $FULL && [ -f "$f" ] && [ -r "$f" ]; then
    m="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)"
    case "$m" in ''|*[!0-9]*) m=0 ;; esac
    jq -Rs --argjson m "$m" '{text: ., mtime: $m}' < "$f" 2>/dev/null || printf 'null'
  else
    printf 'null'
  fi
}
PROG_DOC="$(file_doc "$CM_HOME/programmes.md")"
CENSUS_DOC="$(file_doc "$CM_HOME/census.txt")"

# The report is built in full before anything is printed: a failure (an input shape this program cannot read, or jq
# not started at all, such as an argument over the kernel limit) prints ONE line naming the first error line (itself
# withheld when it looks like a credential) and exits with the failing status, never half a digest.
REPORT_ERR=/dev/null
if [ -n "$DTMP" ] && [ -d "$DTMP" ]; then REPORT_ERR="$DTMP/report.err"; fi
REPORT_RC=0
# test seam (scripts/test/field-reads.sh): CM_TEST=1 with CM_TEST_JQ_FLAGS=--debug-dump-disasm puts the compiled jq program
# in front of the report, so a test can list every field the program reads
JQ_FLAGS=""; if [ "${CM_TEST:-}" = 1 ]; then JQ_FLAGS="${CM_TEST_JQ_FLAGS:-}"; fi
# shellcheck disable=SC2086  # JQ_FLAGS is empty or one flag word
REPORT="$(TZ="$CM_TZ" jq -r $JQ_FLAGS --argjson sinceH "$SINCE_H" --argjson since "$SINCE_EPOCH" \
  --slurpfile ghMergedF <(printf '%s' "$MERGED_JSON") --slurpfile ghOpenF <(printf '%s' "$OPEN_JSON") --slurpfile ghDeploysF <(printf '%s' "$GH_DEPLOYS") \
  --slurpfile lanesF <(printf '%s' "$LANES_JSON") --argjson waitNames "$WAIT_NAMES" \
  --slurpfile progF <(printf '%s' "$PROG_DOC") --slurpfile censusF <(printf '%s' "$CENSUS_DOC") \
  --argjson hideScopes "$HIDE_SCOPES" --argjson hidePaths "$HIDE_PATHS" --argjson runsTrunc "$RUNS_TRUNC" --arg deployJob "$DEPLOY_JOB" \
  --argjson healthStaleS "$HEALTH_STALE_S" --argjson full "$FULL" --argjson mergedLimit "$MERGED_LIMIT" --argjson openLimit "$OPEN_LIMIT" --arg project "$CM_PROJECT" --arg owner "$CM_OWNER_NAME" --arg tzl "$CM_TZ_LABEL" --arg verdictBy "${CM_VERDICT_BY:-$(cm_cfg .away.verdict_by verdict-agent)}" \
  --arg askDeny "$CM_ASK_DENY" --arg askCred "$CM_ASK_DENY_CRED" --arg askAsk "$CM_ASK_DELEGATED_ASK" --arg askSquash "$CM_ASK_SQUASH" --arg askAllow "$CM_ASK_ALLOW" --arg askNever "$CM_ASK_NEVER_PATHS" \
  "$CM_JQ_STATE_DEFS$INTERNAL_DEF$CM_ASK_DENY_DEFS"'
  def ts: if . == null then null
          else (tostring | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | try fromdateiso8601 catch null) end;
  def uk: if . == null then "?" else (localtime | strflocaltime("%a %H:%M")) end;
  def recent: (ts) as $t | $t != null and $t >= $since;
  def ago: (ts) as $t | if $t == null then "?" else
             ((now - $t) / 60 | floor) as $m
             | if $m >= 60 then "\($m / 60 | floor)h\($m % 60)m" else "\($m)m" end end;
  def ref: if . == null or . == "" then "?" else "#\(.)" end;
  # a PR row: #N (a row that carries a repo name is shown as Repo#N; the digest reads one repository, so none does today)
  def pref: (.number | ref) as $r | if (.repo // "") == "" then $r else "\(.repo)\($r)" end;
  def section($title; $lines): ("\($title) (\($lines | length))"),
    (if ($lines | length) == 0 then "- none" else ($lines[] | "- " + .) end), "";

  # In progress (always everything). area: the conventional-commit scope of the title, else "other". plain: the title without
  # its "type(scope):" prefix and trailing "(#N)". prstate: one plain-English state for an open PR.
  def clean: tostring | gsub("[[:cntrl:]]+"; " ");
  def parea: ((.title // "" | clean | capture("^[A-Za-z]+\\((?<s>[^)]*)\\)!?:")? | .s | split(",")[0] | gsub("^\\s+|\\s+$"; "") | ascii_downcase) // "")
             | if . == "" then "other" else . end;
  def plain: (.title // "" | clean | sub("^[A-Za-z]+(\\([^)]*\\))?!?:\\s*"; "") | sub("\\s*\\(#[0-9]+\\)\\s*$"; "") | .[0:90]);
  def prstate: if .isDraft == true then "draft"
               elif .reviewDecision == "APPROVED" then "approved"
               elif .reviewDecision == "CHANGES_REQUESTED" then "changes requested"
               elif .reviewDecision == "REVIEW_REQUIRED" then "waiting for review"
               else "open" end;
  # who: the first waiting-on name found in the text (case-insensitive), else the first name.
  def esc: gsub("(?<c>[\\\\.^$|?*+()\\[\\]{}])"; "\\\(.c)");
  def who($txt): ($txt // "" | tostring | ascii_downcase) as $t
    | ([ $waitNames[] as $n | ($n | ascii_downcase | esc) as $re
         | ([ $t | match("(?<![a-z0-9])" + $re + "(?![a-z0-9])"; "g") | .offset ] | .[0]) as $o
         | select($o != null) | {n: $n, o: $o} ] | sort_by(.o) | .[0].n) // $waitNames[0];

  def tagkey: (. // "" | tostring | ascii_downcase | ltrimstr("v"));
  def depline: "\(.tag) at \(.at | uk)\(if (.prs | length) > 0 then ": " + (.prs | map(ref) | join(" ")) else "" end)\(if .conflict == true then " (ledger says done, gh: no prod deploy job succeeded)" else "" end)";

  # ---- sanitise: every input is normalised once here, before anything reads it, so one value of the wrong shape (a
  # workers row that is a string, a deploy window prs that is a number, a gh author that is a string) drops that row or
  # field and the digest is still built. A wrong-typed value never becomes a null that defaults to a real one: a repo
  # becomes the never-matching "(invalid repo)", a deploy window tag becomes no tag (a key of its own), a gh run status
  # becomes no status (still running, never deployed), and an unreadable census record (violationCheck, violations,
  # supabaseStacks) becomes an incomplete one, so the report says CHECK INCOMPLETE, never a quiet none
  # the counters of the Fleet health summary line, in print order (the line and its type check both read this list)
  def d_sumkeys: ["running", "idle", "waiting on you", "stuck", "stopped", "asleep", "unknown"];
  def d_str: if type == "string" then . else null end;
  def d_obj: if type == "object" then . else {} end;
  def d_objs: if type == "array" then map(select(type == "object")) else [] end;
  def d_strs: if type == "array" then map(select(type == "string")) else [] end;
  def d_repo: if . == null or type == "string" then . else "(invalid repo)" end;
  def d_files: if type == "array" then map(select(type == "object")) else [] end;
  # a census record: absent stays absent, an object keeps what it has (a list or a flag of the wrong type marks it
  # incomplete with a gap naming it), anything else is an incomplete record
  def d_census($name; $list):
    if . == null then null
    elif type != "object" then {complete: false, gaps: ["ledger \($name) is unreadable"]}
    else ([ (if has("gaps") and (.gaps | type) != "array" then "\($name).gaps is unreadable" else empty end),
            (if has($list) and (.[$list] | type) != "array" then "\($name).\($list) is unreadable"
             elif has($list) and (.[$list] | any(.[]; type != "object")) then "\($name).\($list) has a row that is not an object" else empty end),
            (if has("complete") and (.complete | type) != "boolean" then "\($name).complete is unreadable" else empty end) ]) as $bad
      | (if has("gaps") then .gaps |= d_strs else . end)
      | (if has($list) then .[$list] |= d_objs else . end)
      | if ($bad | length) > 0 then . + {complete: false, gaps: ((.gaps // []) + $bad)} else . end end;
  def d_job: . + {name: (.name | d_str), conclusion: (.conclusion | d_str), completedAt: (.completedAt | d_str)};
  def d_run: . + {headBranch: (.headBranch | d_str), status: (.status | d_str), updatedAt: (.updatedAt | d_str),
                  jobs: (.jobs | d_objs | map(d_job))};
  # every printed line, last: cut first (a huge field never reaches a regex), then any control or line-separator
  # character becomes a space, so no field can start a report line of its own
  def d_line: tostring | .[0:4000] | gsub("[[:cntrl:]\u0085\u2028\u2029]+"; " ");
  (
  def d_pr: d_obj | . + {title: (.title | d_str), repo: (.repo | d_repo), files: (.files | d_files),
                         author: (.author | if type == "object" then {login: (.login | d_str)} else null end)};
  (if ($ghMergedF[0] | type) == "array" then [ $ghMergedF[0][] | select(type == "object") | d_pr ] else null end) as $ghMerged
  | (if ($ghOpenF[0] | type) == "array" then [ $ghOpenF[0][] | select(type == "object") | d_pr ] else null end) as $ghOpen
  | (if ($ghDeploysF[0] | type) == "array" then [ $ghDeploysF[0][] | select(type == "object") | d_run ] else null end) as $ghDeploys
  | d_obj
  # a whole list of the wrong type is unreadable, never an empty list: it is named in every section that reads it
  # (Blocked on you, Needs, Waiting on the owner, Open follow-ups), the way .priorities and .decisions say unreadable
  # and a census record says CHECK INCOMPLETE. Absent or null is an empty list and still prints none
  # a whole value or a MEMBER of the wrong type is unreadable, never "nothing there": d_row names a list member or a map
  # value that is not an object, and a field the report reads whose type is not one of $spec (a state that is not text,
  # a reachable that is not true or false). Null stays absent. At most 5 rows are named per group, then a count.
  # Every ask field the owner scan reads, every health.summary counter whatever its key (a number, never false or text), a
  # health.checkedAt and a state that is a known one in another case or padded (every state is matched exactly) are named the same
  # way, as is a workers key padded with white space. A map key that looks like a credential is never printed: the whole line is
  # withheld by the line check at the end. The exit stays 0 plus the notes plus one stderr line. The inventory of every field is
  # scripts/test/fixtures/digest-fields.tsv (class A = named here, class L = consciously left out), asserted by digest-fuzz.sh
  | def d_tn: if . == "array" then "a list" elif . == "object" then "an object" elif . == "string" then "text"
              elif . == "boolean" then "true or false" elif . == "number" then "a number" else . end;
    def d_row($path; $spec): if type != "object" then "unreadable (ledger \($path) is not an object)"
        else . as $o | $spec | to_entries[] | select($o[.key] != null and ((($o[.key] | type) as $t | .value | index($t)) == null))
             | "unreadable (ledger \($path).\(.key) is not \(.value | map(d_tn) | join(" or ")))" end;
    # an ask: every field ask_kind, ask_bad and ask_owner_why read to decide whether it belongs to the owner (scripts/ask-deny.sh):
    # a kind or scope, a PR, noCode or files of the wrong type would otherwise read as "not there" and hide an owner item
    ({state: ["string"], kind: ["string"], scope: ["string"], question: ["string"], topic: ["string"], lane: ["string"],
      worker: ["string"], path: ["string"], noCode: ["boolean"], pr: ["number", "string"], files: ["array"]}) as $askSpec
    | def d_nearv($where; $known): if type == "string" and (. as $x | $known | index($x) | not)
                                 then (if ((gsub("^\\s+|\\s+$"; "") | ascii_downcase) as $n | $known | index($n) != null)
                                       then "unreadable (ledger \($where) is a near miss of a known state: states are matched exactly)"
                                       else "unreadable (ledger \($where) is not a known state: an unknown state holds nothing)" end)
                                 else empty end;
    # a state that reads like a known one (another case, or padded with spaces) is matched exactly, so it would read as "not that
    # state": a near miss is unreadable, an unknown state that is no near miss is legal and unchanged
    def d_cap: if length > 5 then .[:5] + ["and \(length - 5) more unreadable ledger rows"] else . end;
    def d_rowsOf($name; $spec): [ if type == "array" then to_entries[] | .key as $i | .value | d_row(".\($name)[\($i)]"; $spec) else empty end ] | d_cap;
    def d_nearrows($name; $known): [ if type == "array" then to_entries[] | .key as $i | .value | select(type == "object") | .state
                                       | d_nearv(".\($name)[\($i)].state"; $known) else empty end ] | d_cap;
    def d_nearmap($name; $known): [ if type == "object" then to_entries[] | .key as $k | .value | select(type == "object") | .state
                                      | d_nearv(".\($name).\($k).state"; $known) else empty end ] | d_cap;
    def d_mapOf($name; $spec): [ if type == "object" then to_entries[] | .key as $k | .value | d_row(".\($name).\($k)"; $spec) else empty end ] | d_cap;
    ([ (.asks | type) as $t | select($t != "array" and $t != "null") | "unreadable (ledger .asks is not a list)" ]
     + [ (.workers | type) as $t | select($t != "object" and $t != "null") | "unreadable (ledger .workers is not an object)" ]
     + (.asks | d_rowsOf("asks"; $askSpec))
     + (.asks | d_nearrows("asks"; cm_ask_states))
     + (.workers | d_mapOf("workers"; {state: ["string"], pr: ["number", "string"]}))
     + (.workers | d_nearmap("workers"; cm_states_known))
     # an ask names its worker trimmed, and the row is found by that exact key: a padded key is never found
     + [ (.workers | if type == "object" then keys[] | select(. != gsub("^\\s+|\\s+$"; "")) | "unreadable (ledger .workers[\(tojson)] is a worker id with surrounding white space)" else empty end) ]) as $listBad
  | ([ (.followUps | type) as $t | select($t != "array" and $t != "null") | "unreadable (ledger .followUps is not a list)" ]
     + (.followUps | d_rowsOf("followUps"; {state: ["string"]}))
     + (.followUps | d_nearrows("followUps"; cm_followup_states))) as $fuBad
  # the same for the other whole values a section reads: a STOPPED deploy window, a restart, an attention row, an
  # offline host or a queued item must never vanish because its list has the wrong type
  | def d_bad($v; $want; $name): ($v | type) as $t
      | if $t == $want or $t == "null" then empty
        else "unreadable (ledger .\($name) is not \(if $want == "array" then "a list" else "an object" end))" end;
    ({deployWindows: ([ d_bad(.deployWindows; "array"; "deployWindows") ] + (.deployWindows | d_rowsOf("deployWindows"; {state: ["string"], tag: ["string"], prs: ["array"], finishedAt: ["string"], at: ["string"]}))
                       + (.deployWindows | d_nearrows("deployWindows"; cm_window_states))),
      health: ([ d_bad(.health; "object"; "health"),
                 (if (.health | type) == "object" then d_bad(.health.attention; "array"; "health.attention"),
                    d_bad(.health.summary; "object"; "health.summary"),
                    # a record with checkedAt set and no summary at all (absent or null) would print every counter as 0
                    (if .health.summary == null and .health.checkedAt != null then "unreadable (ledger .health.summary is missing: a counter is never read as 0)" else empty end),
                    # every counter of the summary line is a number: a text, true or false, a list or an object there would print
                    # as a count (corrupt running) or as zero (false), so the line is not printed at all
                    (.health.summary | if type == "object" then to_entries[] | select(.value != null and (.value | type) != "number")
                                       | "unreadable (ledger .health.summary.\(.key) is not a number)" else empty end),
                    # lane-health.sh always writes all seven counters: a summary with one missing (or {}) is a damaged record, and
                    # `// 0` would print the gap as "0 stuck": name it and print no line at all
                    (.health.summary | if type == "object" then d_sumkeys[] as $k | select(.[$k] == null) | "unreadable (ledger .health.summary.\($k) is missing: a counter is never read as 0)" else empty end),
                    (.health | .checkedAt | select(. != null and type != "string") | "unreadable (ledger .health.checkedAt is not text)")
                  else empty end),
                 d_bad(.hostEvents; "array"; "hostEvents") ]
               + (if (.health | type) == "object" then (.health.attention | d_rowsOf("health.attention"; {})) else [] end)
               + (.hostEvents | d_rowsOf("hostEvents"; {kind: ["string"], at: ["string", "number"], watched: ["boolean"]}))),
      hosts: ([ d_bad(.hosts; "object"; "hosts") ] + (.hosts | d_mapOf("hosts"; {reachable: ["boolean"]}))),
      queue: ([ d_bad(.queue; "object"; "queue"),
                (if (.queue | type) == "object" then d_bad(.queue.items; "array"; "queue.items") else empty end) ]
              + (if (.queue | type) == "object" then (.queue.items | d_rowsOf("queue.items"; {state: ["string"]})) + (.queue.items | d_nearrows("queue.items"; cm_queue_states)) else [] end))}) as $shapeBad
  | ((.violations | type) as $vt | if $vt == "null" or ($vt == "array" and all(.violations[]; type == "object")) then . else
       .violationCheck = ((.violationCheck | if type == "object" then . else {} end)
                          + {complete: false, gaps: (((.violationCheck | if type == "object" then .gaps else null end) | d_strs) + ["ledger violations is unreadable"])}) end)
  | . + {workersRaw: .workers, workers: (.workers | d_obj | with_entries(select(.value | type == "object"))),
         deployWindows: [ .deployWindows | d_objs[] | . + {tag: (.tag | d_str), prs: (.prs | if type == "array" then . else [] end)} ],
         asks: (.asks | d_objs), hosts: (.hosts | d_obj | with_entries(select(.value | type == "object"))),
         followUps: (.followUps | d_objs), hostEvents: (.hostEvents | d_objs),
         health: (.health | d_obj | . + {summary: (.summary | d_obj), attention: (.attention | d_objs)}),
         violations: (.violations | d_objs),
         violationCheck: (.violationCheck | d_census("violationCheck"; "none") // {}),
         supabaseStacks: (.supabaseStacks | d_census("supabaseStacks"; "orphans") // {}),
         queue: {items: [ .queue | d_obj | .items | d_objs[]
                          | . + {priority: (.priority | if . == null or type == "string" then . else "(invalid priority)" end)} ]}}
  | (.workers | to_entries | map(.value + {id: .key})) as $workers
  | (.deployWindows // []) as $wins
  | def txt($n; $d): ((. // "") | tostring | gsub("[[:cntrl:][:space:]\u2028\u2029\u200b-\u200f\u202a-\u202e\u00ad\u061c\u180e\u2060-\u206f\ufeff\ufff9-\ufffb\u034f\u115f\u1160\u3164\\x{e0000}-\\x{e007f}]+"; " ") | gsub("@"; "(at)") | gsub("^\\s+|\\s+$"; "") | .[0:$n]) | if . == "" then $d else . end;
    def rk: (if type == "number" then . elif type == "string" then (try tonumber catch null) else null end) | if . != null and (isnan or isinfinite) then null else . end;
    def prioline: ((.rank | rk) as $k | "- \(if $k == null then "?" else ($k | tostring | if length > 12 then .[0:12] + "+" else . end) end). \(.what | txt(120; "(no description)")) [\(.id | txt(40; "?")), owner \(.owner | txt(40; "unknown"))]\((.report | txt(160; "")) as $rp | if $rp == "" then "" else " - " + $rp end)");
    (if has("priorities") then .priorities else [] end) as $prRaw
  | ([ (if ($prRaw | type) == "array" then $prRaw[] else empty end) | select(type == "object")
       | select(((.state // "active") | tostring | ascii_downcase | gsub("^\\s+|\\s+$"; "")) as $st | $st != "done" and $st != "dropped") ]
     | sort_by([((.rank | rk) == null), ((.rank | rk) // 0), (.id // "" | tostring)])) as $prios
  | (if ($prRaw | type) == "array" then ([ $prRaw[] | select(type != "object") ] | length) else 0 end) as $prBad
  | (.asks // []) as $asks
  | (.hosts // {}) as $hosts
  # Merged and Tooling. $tool: merged PRs that are the concertmaster'"'"'s own (group text only). $openTool: open ones, null when unknown.
  | (($ghMerged // []) | map(select(.mergedAt | recent))) as $inWin
  | (if $full then [] else [ $inWin[] | select(internal) ] end) as $tool
  | (if $full or $ghOpen == null then null else ([ $ghOpen[] | select(internal) ] | length) end) as $openTool
  | ($hideScopes | join("/") | if . == "" then "tooling" else . end) as $label
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
    # Priorities come first: the ledger .priorities rows not done or dropped, lowest rank first,
    # at most 10 lines, text cleaned like every other agent-written line.
    ( if ($prRaw | type) != "array" then "Priorities: unreadable (ledger .priorities is not a list)"
      else "Priorities (\($prios | length))",
           (if ($prios | length) == 0 then (if $prBad > 0 then empty else "- none" end)
            else (($prios[:10][] | prioline), (if ($prios | length) > 10 then "- +\(($prios | length) - 10) more, see the ledger" else empty end)) end),
           (if $prBad > 0 then "- \($prBad) unreadable entries in the ledger" else empty end) end ),
    "",
    # Blocked on you (--full only, never the group text): the items of the owner, one "- <feature> | <what to do>" line each,
    # the rows of the "Blocked on you" table of the tick report (SKILL.md § Reporting). An ask goes to the owner exactly when
    # ask_owner_why (scripts/ask-deny.sh) says so: the definition scripts/stall.sh exempts as Blocked, never a second list.
    # A host not read is no row here (a fleet-health fact the concertmaster acts on, listed under Fleet health), but the
    # heading counts it, so a quiet list is never read as complete.
    ( if $full | not then empty else
      ["merged", "done", "closed", "abandoned", "retire", "retired"] as $fin
      | .workersRaw as $wobj
      | def cell: clean | gsub("\\|"; "/") | gsub("^\\s+|\\s+$"; "");
      ([ $asks[] | select(type == "object" and .state == "open")
         | select(ask_owner_why(ask_kind; $wobj; $askAllow; $askNever; $askDeny; $askSquash; $askCred; $askAsk) != null)
         | "\(if (.lane | type) == "string" then .lane elif .lane != null then "(invalid lane)"
               elif (.worker | type) == "string" then .worker elif .worker != null then "(invalid worker)"
               else "concertmaster" end | cell | .[0:40])\(if (.issue // null) != null then " #\(.issue | cell)" else "" end): ask \(.id // "?" | cell | .[0:40]) | answer: \(.question // "(no question recorded)" | tostring | .[0:320] | cell | .[0:160]) (\(ask_kind | if . == "" then "no kind" elif IN(ask_known_kinds[]) then cell else "unknown kind" end), open \(.askedAt | ago))" ]
       + [ ($lanesF[0].wts // [])[] | select(.first.tag | IN($fin[]) | not) | . as $w
           | ((.blk // []) + (if .self == true then [ (.waits // [])[] | select(.tag == "ask") ] else [] end))[]
           | "\($w.lane | cell) on \($w.host | cell) | cm:\(.tag): \(.text | cell | .[0:160])" | sub("\\s+$"; "") ]
       + [ $workers[] | select((.state | cm_state_norm) == "blocked-on-owner")
           | "\(.lane // "-" | cell) \(.task // .id | cell | .[0:60]) | \(.blockedQuestion // "see concertmaster" | tostring | .[0:320] | cell | .[0:160])" ]
       + $listBad) as $items
      | (if $lanesF[0] == null then "the fleet CLI" else ($lanesF[0].unreach | length | if . == 1 then "1 host" else "\(.) hosts" end) end) as $unread
      | ($lanesF[0] == null or ($lanesF[0].unreach | length) > 0) as $partial
      | "Blocked on you (\($items | length)\(if $partial then ", \($unread) not read, see Fleet health" else "" end))",
        (if ($items | length) > 0 then ($items[] | "- " + .) elif $partial then "- none read" else "- none" end),
        "" end ),
    ( if $ghMerged == null then "Merged: unknown (gh failed)"
      else ([ $inWin | map(select(. as $x | $tool | index($x) | not)) | sort_by(.mergedAt)[]
          | "\(pref) \(.title // "" | tostring | gsub("[[:cntrl:]]+"; " ") | .[0:60]) (\(.author.login // "?"))" ]) as $m
        | "Merged (\($m | length)\(if ($ghMerged | group_by(.repo // "") | any(.[]; length >= $mergedLimit)) then "+" else "" end))",
          (if ($m | length) == 0 then "- none" else ($m[] | "- " + .) end) end ),
    ( if $full then empty
      elif $ghMerged == null then
        (if ($openTool // 0) > 0 then "Tooling: merged unknown (gh failed), \($openTool) open" else empty end)
      elif ($tool | length) > 0 or ($openTool // 0) > 0 then
        "Tooling: \($tool | length) \($label) PRs merged, \(if $openTool == null then "open unknown (gh failed)" else "\($openTool) open" end)"
      else empty end ),
    "",
    ( if $gd == null then
        "Deployed: unknown (gh failed)",
        ((($ldIn | sort_by(.at) | map(depline)) + $stopped + $shapeBad.deployWindows)[] | "- " + .)
      else
        "Deployed (\($dep | length)\(if $runsTrunc then "+" else "" end))",
        (if ($dep | length) + ($unproven | length) + ($stopped | length) + ($drift | length) + ($shapeBad.deployWindows | length) == 0 then "- none"
         else ((($dep | map(depline)) + $unproven + $drift + $stopped + $shapeBad.deployWindows)[] | "- " + .) end) end ),
    "",
    # In progress: every open PR, every active lane, then who is waited on. Always everything, never headlines.
    ( if $ghOpen == null then "Open PRs: unknown (gh failed)"
      else "Open PRs (\($ghOpen | length)\(if ($ghOpen | group_by(.repo // "") | any(.[]; length >= $openLimit)) then "+" else "" end))",
           (if ($ghOpen | length) == 0 then "- none"
            else ($ghOpen | map(. + {a: parea}) | group_by(.a) | sort_by([-(length), .[0].a])[]
                  | "\(.[0].a) (\(length))", (sort_by([(.repo // ""), .number])[] | "- \(pref) \(plain) [\(prstate)]")) end) end ),
    "",
    ( ["running", "busy", "merge-ready", "queued", "spawning", "stuck", "blocked", "ask", "waiting-owner"] as $active
      | $lanesF[0] as $L
      | if $L == null then "Lanes: unknown (fleet CLI not available)"
        else ([ $L.wts[] | select(.first.tag | IN($active[])) ] | sort_by(.lane)) as $act
          | "Lanes (\($act | length))",
            (if ($act | length) == 0 then (if ($L.unreach | length) > 0 then "- none read" else "- none" end) else ($act[] | "- \(.lane) on \(.host): \(.first.tag) \(.first.text | .[0:140])" | sub("\\s+$"; "")) end),
            ($L.unreach[] | "- host not read: \(.host) (\(.error | clean | .[0:80])), its lanes are not listed") end ),
    "",
    ( [ ( ($lanesF[0].wts // [])[] | select(.first.tag | IN("merged", "done", "closed", "abandoned", "retire", "retired") | not) | .lane as $ln | .host as $h | .waits[] | {w: who(.text), t: "\($ln) on \($h): \(.tag) \(.text | .[0:120])"} ),
        ( $asks[] | select(.state == "open") | {w: who(.question), t: "ask: \(.question // "" | tostring | .[0:200] | clean | .[0:100]) (open \(.askedAt | ago))"} ),
        ( $workers[] | select((.state | cm_state_norm) == "blocked-on-owner")
          | {w: who(.blockedQuestion), t: "\(.lane // "-" | clean) \(.task // .id | clean | .[0:60]): \(.blockedQuestion // "see concertmaster" | tostring | .[0:200] | clean | .[0:100])"} ) ] as $wait
      | ( if $lanesF[0] == null then ["lane asks not read: the fleet CLI is not available"]
          else [ $lanesF[0].unreach[] | "lane asks not read on \(.host): \(.error | clean | .[0:80])" ] end ) as $unread
      | ( if $ghOpen == null then []
          else [ $ghOpen[] | select(.isDraft != true and (.reviewDecision == "REVIEW_REQUIRED" or ((.repo // "") == "" and (.reviewDecision == null or .reviewDecision == "")))) | pref ] end ) as $review
      | ( $waitNames | to_entries[] | .key as $k | .value as $name
          | ([ $wait[] | select(.w == $name) | .t ] + (if $k == 0 then $listBad + $unread else [] end) + (if $k == 1 and ($review | length) > 0 then ["\($review | length) open PRs still need review or approval: \($review | join(" "))"] else [] end)) as $items
          | "Waiting on \($name) (\($items | length))",
            (if ($items | length) == 0 then "- none" else ($items[] | "- " + .) end),
            "" ) ),
    # Fleet health (scripts/lane-health.sh --all writes ledger .health each tick). The group text carries counts only;
    # --full names each session that needs a look. A check older than 2 lane loops says the concertmaster check is missing.
    ( (.health // {}) as $hl | ($hl.checkedAt | ts) as $hc
      | "Fleet health",
        ($shapeBad.health[] | "- " + .),
        (if $hc == null and ($hl.checkedAt != null and ($hl.checkedAt | type) != "string") then empty
         elif $hc == null then "- not checked yet (scripts/lane-health.sh --all)"
         else ( ($hl.summary // {}) as $s
           | (if any($shapeBad.health[]; contains(".health.summary")) then empty
              else ("- " + (d_sumkeys | map("\($s[.] // 0) \(.)") | join(", "))) end),
             ( [ (.hostEvents // [])[] | select(((.at | ts) // 0) >= $since and (.watched != false) and (.kind | IN("reboot", "preemption", "daemon-restart"))) ] as $ev
               | if ($ev | length) > 0 then "- restarts in the window: \([$ev[] | select(.kind == "reboot")] | length) reboot(s), \([$ev[] | select(.kind == "preemption")] | length) preemption(s), \([$ev[] | select(.kind == "daemon-restart")] | length) daemon restart(s)" else empty end ),
             (if (now - $hc) > $healthStaleS then "- concertmaster check missing: last run \($hl.checkedAt | ago) ago" else empty end),
             (if $full then (($hl.attention // [])[] | "- \(.name // "?" | tostring) on \(.host // "?" | tostring): \(.word // "?" | tostring), \(.meaning // "" | tostring | gsub("[[:cntrl:]]+"; " ") | .[0:90])") else empty end) ) end),
        # --full only: a host whose worktree comments were not read (its cm:blocked lines are not in Blocked on you).
        # A fleet-health fact the concertmaster acts on (a Moved this tick row in the tick report), not an owner item.
        (if $full | not then empty
         elif $lanesF[0] == null then "- lane comments not read: the fleet CLI is not available, their cm:blocked lines are not listed"
         else ($lanesF[0].unreach[] | "- host not read: \(.host | clean | gsub("^\\s+|\\s+$"; "")) (\(.error | clean | gsub("^\\s+|\\s+$"; "") | .[0:80])), its cm:blocked lines are not listed") end),
        "" ),
    ( if $full | not then empty else .workersRaw as $wobj | section("Needs \($owner)"; [ $workers[] | select((.state | cm_state_norm) == "blocked-on-owner")
        | "\(.lane // "-" | clean) \(.task // .id | clean | .[0:60]): \(.blockedQuestion // "see concertmaster" | tostring | .[0:400] | clean)" ]
      + [ $asks[] | select(type == "object" and .state == "open")
          | select(ask_owner_why(ask_kind; $wobj; $askAllow; $askNever; $askDeny; $askSquash; $askCred; $askAsk) != null)
          | "ask: \(.question // "" | tostring | .[0:160] | clean | .[0:80]) (open \(.askedAt | ago))" ]
      + $listBad) end ),
    ( if $full | not then empty else section("Open follow-ups"; [ (.followUps // [])[] | select(.state != "done")
        | "\(.lane // "-")/\(.id) owner \(.owner // "?"), posted by \(.worker // "?"): \(.text // "" | tostring | .[0:160] | gsub("[[:cntrl:]]+"; " ") | .[0:80]) (open \(.openedAt | ago))" ] + $fuBad) end ),
    # Decided while you were away (--full only): the ledger decisions[] records (scripts/stall.sh --act ... verdict, the
    # self-unblocks of the drive authority, references/ledger.md), newest 20, from the earlier of the window start and 12h ago.
    ( if $full | not then empty else
      def cell: clean | gsub("^\\s+|\\s+$"; "");
      (if has("decisions") then .decisions else [] end) as $dRaw
      | ([$since, (now - 43200)] | min) as $dSince
      | (((now - $dSince) / 3600 + 0.5) | floor | if . < 1 then 1 else . end) as $dH
      | if ($dRaw | type) != "array" then "Decided while you were away: unreadable (ledger .decisions is not a list)", ""
        else
          ([ $dRaw[] | select(type == "object") | . + {t: (.at | ts)} ]) as $dObj
          | ([ $dObj[] | select(.t != null and .t >= $dSince) ] | sort_by(.t)) as $dIn
          | (($dRaw | length) - ([ $dObj[] | select(.t != null) ] | length)) as $dBad
          | "Decided while you were away (\($dIn | length), last \($dH)h)",
            (if ($dIn | length) > 20 then "- +\(($dIn | length) - 20) earlier, see ledger decisions[]" else empty end),
            (if ($dIn | length) == 0 then "- none"
             else ($dIn[-20:][] | (.subject | if type == "object" then . else {} end) as $s
               | "- \(.t | uk) \($s.kind // "?" | cell) \($s.name // "?" | cell | .[0:60])\(if ($s.host // "") != "" then " on " + ($s.host | cell) else "" end) (rung \(.rung // "?" | cell)): \(.text // "(no text recorded)" | tostring | .[0:480] | cell | .[0:240])") end),
            (if $dBad > 0 then "- \($dBad) unreadable entries in ledger decisions[]" else empty end),
            "" end end ),
    ( if $full | not then empty else section("Decided while you were away (\($verdictBy))";[ $asks[] | select(.decidedBy == $verdictBy and (.decidedAt | recent))
        | "#\(.issue // "?") \(.question // "" | tostring | .[0:160] | gsub("[[:cntrl:]]+"; " ") | .[0:80]): \(.verdictRef // "no link")" ]) end ),
    ( if $full | not then empty else section("Stuck"; [ $workers[] | select((.state | cm_state_norm) == "stuck")
        | "\(.task // .id | tostring | .[0:50]) on \(.host // "?"), idle \(.lastOutputAt | ago), nudges \(.nudges // 0)/2" ]) end ),
    ( def clean: tostring | gsub("[[:cntrl:]]+"; " ");
      (.violationCheck // {}) as $vc
      | ([ (.violations // [])[] | "\(.agent // "?" | clean) \(.host // "?" | clean) \(.worktree // "?" | clean) \(.handle // "-" | clean) \(.title // "-" | clean | .[0:40])" ]
         + (if $vc.complete == false then ["CHECK INCOMPLETE, not proof of none: \(($vc.gaps // []) | join("; ") | clean | .[0:600])"] else [] end)
         + (if ($vc.checkedAt | ts) != null then ["census \($vc.checkedAt | ago) old"] else [] end)) as $lines
      | if ($full | not) or ($vc.enabled == false) or ($lines | map(select(startswith("census ") | not)) | length) == 0 then empty
        else section("Forbidden agents on \($project) work"; $lines) end ),
    ( def clean: tostring | gsub("[[:cntrl:]]+"; " ");
      (.supabaseStacks // {}) as $sb
      | ([ ($sb.orphans // [])[] | "\(.host // "?" | clean) \(.projectId // "?" | clean): \(.containers // "?" | clean) containers, no live Orca worktree names it" ]
         + (if ($sb | length) == 0 then ["CHECK NOT RUN: the ledger has no supabaseStacks (tick step 3 writes it), not proof of none"] else [] end)
         + (if $sb.complete == false then ["CHECK INCOMPLETE, not proof of none: \(($sb.gaps // []) | join("; ") | clean | .[0:600])"] else [] end)
         + (if ($sb.checkedAt | ts) != null then ["census \($sb.checkedAt | ago) old"] else [] end)) as $lines
      | if ($full | not) or ($lines | map(select(startswith("census ") | not)) | length) == 0 then empty
        else section("Supabase stacks without a worktree"; $lines) end ),
    # Programmes and Census (--full only): what tick steps 5 and 3 wrote, as written, with the file age. The tick report
    # no longer prints them; a file older than 2 lane loops says stale, a missing one says so (never a silent gap).
    ( if $full | not then empty else
      def filesec($title; $doc; $what):
        if $doc == null then "\($title): not written yet (\($what))", ""
        else ((now - ($doc.mtime // 0)) / 60 | floor) as $m
          | "\($title) (written \(if $m >= 60 then "\($m / 60 | floor)h\($m % 60)m" else "\($m)m" end) ago\(if (now - ($doc.mtime // 0)) > $healthStaleS then ", stale" else "" end))",
            ($doc.text // "" | tostring | split("\n") | map(gsub("[[:cntrl:]]"; " ") | sub("\\s+$"; "") | select(test("\\S"))) | if length == 0 then ["- empty file"] else . end | .[]),
            "" end;
      filesec("Programmes"; $progF[0]; "tick step 5 writes programmes.md in the state dir"),
      filesec("Census"; $censusF[0]; "tick step 3 writes census.txt in the state dir") end ),
    ( if $full | not then empty else
      [ $workers[] | select((.state | cm_state_norm) == "running") ] as $run
      | ($run | group_by(.host) | map("\(.[0].host) \(length)") | join(", ")) as $byHost
      | ([ $hosts | to_entries[] | select(.value.reachable == false) | .key ]) as $off
      | (if $ghOpen == null then "unknown (gh failed)"
         else ($ghOpen | length) as $n | "\($n)\(if ($ghOpen | group_by(.repo // "") | any(.[]; length >= $openLimit)) then "+" else "" end)" end) as $open
      | "Fleet: \($run | length) running\(if $byHost != "" then " (" + $byHost + ")" else "" end), open PRs: \($open)\(if ($off | length) > 0 then ", offline: " + ($off | join(" ")) else "" end)",
        ($shapeBad.hosts[] | "- " + .) end ),
    ( if ($shapeBad.queue | length) > 0 then "Next: " + ($shapeBad.queue | join("; ")) else
      [ (.queue.items // [])[] | select(.state == "queued") ]
      | sort_by(({"P0": 0, "urgent": 1}[.priority // "normal"] // 2), (.addedAt // ""))
      | if length == 0 then empty
        else "Next: \(.[0:3] | map(def c: tostring | gsub("[[:cntrl:]]+"; " "); ((if (.summary // "") != "" then .summary else (.title // "") end) | c | .[0:40]) as $sum
            | "\(if .issue != null and .issue != "" then (.issue | ref) else "\(.id // "item" | c)\(if $sum != "" then " " + $sum else "" end)" end) \(.lane // "-" | c) \(.priority // "normal" | c)") | join(", ")) (\(length) waiting)" end end )
  ) | d_line
' "$LEDGER" 2>"$REPORT_ERR")" || REPORT_RC=$?
if [ "$REPORT_RC" -ne 0 ]; then
  why="$( { head -n 1 "$REPORT_ERR" 2>/dev/null || true; } | tr -d '[:cntrl:]' | cut -c1-200)"
  if [ -n "$why" ] && line_looks_secret "$why"; then why="$DIGEST_WH"; fi
  cm_warn "digest: the ledger or a gh answer has a shape this report cannot read: no digest built${why:+ ($why)}"
  exit "$REPORT_RC"
fi
# a ledger value the report could not read is named in its section; say so once on stderr too, so a caller that only
# reads the exit status and stderr still learns the report is partial (exit 0: the rest of the digest is still sent)
case "$REPORT" in *"unreadable (ledger ."*)
  cm_warn "digest: the ledger has values of the wrong type, named as unreadable in the report" ;; esac
printf '%s\n' "$REPORT" | digest_withhold
