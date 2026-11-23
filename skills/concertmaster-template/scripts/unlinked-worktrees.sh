#!/usr/bin/env bash
# unlinked-worktrees.sh: tick step 2, unlinked worktrees. Lists the live worktrees that have NO linked issue in the fleet CLI, so an unlinked
# worktree is visible in the tick report (hard rule 30, "no ticket, no spawn").
#
#   scripts/unlinked-worktrees.sh            # the census-style lines below, every host
#   scripts/unlinked-worktrees.sh --json     # {unlinked:[{host,name,path,branch,pr}], exempt:N, hosts:[{name,ok,error}], complete}
#
# Reads `<cli> worktree list --limit 500 --json` once per host of `host list` (the same hosts discover.sh reads; a failed host
# list reads the local host only) and keeps the rows of THIS project (path matches worktrees.path_match). A worktree is
# LINKED when the row's `linkedIssue` is a positive number, or `linkedItems` holds an item of type `issue`, or another issue tracker's
# issue is linked. A linked PR alone is NOT an issue link: the row is listed with its PR number (link the issue it closes).
#
# Exempt, and only these (stated in references/lanes.md Lead charter, Ticket link):
#   the concertmaster's own worktree (worktrees.self_name, and, when worktrees.orca_repo is set, only one under a /<orca_repo>/
#   directory: a same-named worktree of another repo is an ordinary worktree here); a standing lane's own worktree on POSITIVE evidence (a configured lane
#   or an ownership lead by name, or a ledger worker with standing:true at that path); a main checkout; an archived worktree; a
#   worktree with a path segment equal to a worktrees.never_touch name; and any path outside worktrees.path_match. A NAME SHAPE
#   alone (-lead, -sweeper, epic-) exempts nothing here: an exemption only hides this nag, so `dev-lead-time-fix` is listed like any
#   worker, and an unledgered lead is listed until it is recorded. Children of a lane are NOT exempt: every worker needs its own issue.
#
# Output (default), paste as printed under the census line:
#   unlinked-worktrees: <n> (target 0)[ (CHECK INCOMPLETE: <host>: <why>)]
#     UNLINKED <name> @ <host>: <path> pr=<n|none>     one row per worktree over 0
# A host that cannot be read is listed in the CHECK INCOMPLETE suffix and is never read as "all linked".
# A host whose worktree list came back truncated (`result.truncated: true`, or a `totalCount` above the rows returned) is a CHECK INCOMPLETE
# row too: the rows that were returned are still judged and listed, but the count is a lower bound, never "fewer worktrees".
# Time: ONE host list (CM_UNLINKED_LIST_TIMEOUT, 20 s) and then every host read IN PARALLEL, each cut to what is left of
# CM_UNLINKED_BUDGET (80 s), so the worst case is the list plus ONE read; a host that does not answer in time is a CHECK INCOMPLETE
# row ("not checked: time budget"), never silent. The tick calls it with a 600000 ms Bash timeout (SKILL.md, tick step 2, unlinked worktrees).
# Env: CM_HOST_TIMEOUT (default 60 s per call). Exit 0 always on the default and --json paths (a tick never fails here); 2 usage.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

MODE=text
case "${1:-}" in
  '') ;;
  --json) MODE=json ;;
  -h|--help) sed -n '2,/^set -uo/{/^#/p;}' "$0"; exit 0 ;;
  *) cm_warn "unlinked-worktrees.sh: unknown arg: $1"; exit 2 ;;
esac
[ $# -le 1 ] || { cm_warn "unlinked-worktrees.sh: too many arguments"; exit 2; }
command -v jq >/dev/null 2>&1 || { cm_warn "unlinked-worktrees.sh: missing dependency: jq"; echo "unlinked-worktrees: unknown (CHECK INCOMPLETE: jq missing)"; exit 0; }
if [ -z "$CM_PATH_MATCH" ]; then
  cm_warn "unlinked-worktrees.sh: set worktrees.path_match in config.yaml (or CM_PATH_MATCH)"
  echo "unlinked-worktrees: unknown (CHECK INCOMPLETE: no worktrees.path_match)"; exit 0
fi
CLI="$(cm_cli)" || { echo "unlinked-worktrees: unknown (CHECK INCOMPLETE: no fleet CLI)"; exit 0; }
HT="${CM_HOST_TIMEOUT:-60}"
BUDGET="${CM_UNLINKED_BUDGET:-80}"; LT="${CM_UNLINKED_LIST_TIMEOUT:-20}"; [ "$LT" -le "$HT" ] 2>/dev/null || LT="$HT"
T0="$(date +%s)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cm-unlinkedwt.XXXXXX")" || { cm_warn "unlinked-worktrees.sh: cannot create a temp dir"; echo "unlinked-worktrees: unknown (CHECK INCOMPLETE: no temp dir)"; exit 0; }
trap 'rm -rf -- "${TMP:?}"' EXIT

# hosts: the same list discover.sh reads; when it fails only the local host is read, and the suffix says nothing is hidden
: > "$TMP/hosts.tsv"
if cm_timeout "$LT" "$CLI" host list --json </dev/null > "$TMP/hostlist.json" 2>/dev/null && jq -e '.ok == true and (.result.hosts | type == "array")' "$TMP/hostlist.json" >/dev/null 2>&1; then
  jq -r '.result.hosts[] | (if .kind == "local" then "local" else .name end)' "$TMP/hostlist.json" > "$TMP/hosts.tsv"
else
  echo local > "$TMP/hosts.tsv"
  printf '%s\t%s\n' "(host list)" "the host list failed, only the local host was read" > "$TMP/bad.tsv"
fi

# exemption inputs
# Data of ledger size is never a jq argument (one argument is capped at 128 KiB on Linux): these go to jq as files (--slurpfile).
cm_cfg '.worktrees.never_touch[]' 2>/dev/null | tr '[:upper:]' '[:lower:]' | jq -R . | jq -sc . > "$TMP/never.json" 2>/dev/null; [ -s "$TMP/never.json" ] || echo '[]' > "$TMP/never.json"
cm_lane_names | jq -R . | jq -sc . > "$TMP/lanes.json" 2>/dev/null; [ -s "$TMP/lanes.json" ] || echo '[]' > "$TMP/lanes.json"
LEDGER="${CM_LEDGER:-$CM_HOME/ledger.json}"
echo '[]' > "$TMP/stand.json"
if [ -r "$LEDGER" ]; then
  if jq -c '[(.workers // {}) | to_entries[] | .value | select(.standing == true) | (.path // .worktree // .worktreePath // empty) | select(type == "string") | sub("/+$"; "")]' "$LEDGER" > "$TMP/stand.new" 2>/dev/null && [ -s "$TMP/stand.new" ]; then mv -f "$TMP/stand.new" "$TMP/stand.json"
  else printf '%s\t%s\n' "(ledger)" "the ledger could not be parsed: ledger standing workers are not exempted" >> "$TMP/bad.tsv"; fi
fi

# One background job per host, each writing only its own files under $TMP/h/<n>; joined in host order afterwards.
mkdir -p "$TMP/h"
read_host() { # <n> <host>
  local n="$1" host="$2" d="$TMP/h/$1" rc=0 why left ht hs=()
  mkdir -p "$d"; : > "$d/rows.ndjson"; : > "$d/bad.tsv"
  cm_cli_host_into hs "$host" || { printf '%s\t%s\n' "$host" "bad host name" >> "$d/bad.tsv"; return 0; }
  left=$(( BUDGET - ( $(date +%s) - T0 ) )); ht="$HT"; [ "$left" -ge "$ht" ] || ht="$left"; [ "$ht" -ge 1 ] || ht=1
  cm_timeout "$ht" "$CLI" worktree list ${hs[@]+"${hs[@]}"} --limit 500 --json </dev/null > "$d/wl.json" 2>"$d/wl.err" || rc=$?
  if [ "$rc" -eq 0 ]; then cm_wt_dedupe < "$d/wl.json" > "$d/wl.dd" 2>/dev/null && cat "$d/wl.dd" > "$d/wl.json" || rc=1; fi
  if [ "$rc" -ne 0 ] || ! jq -e '.ok == true and (.result.worktrees | type == "array")' "$d/wl.json" >/dev/null 2>&1; then
    why="rc=$rc $(head -c 120 "$d/wl.err" 2>/dev/null | tr '\t\n' '  ')"; [ "$rc" -eq 124 ] && why="not checked: time budget (timeout after ${ht}s)"
    printf '%s\t%s\n' "$host" "$why" >> "$d/bad.tsv"; return 0
  fi
  # a list cut off at the limit (truncated:true, or a totalCount above the rows returned, as fleet-read.sh reads it) holds only SOME of the
  # host's worktrees: the rows that are there are still judged, but the census is INCOMPLETE and never reads as fewer worktrees.
  if jq -e '.result.truncated == true or (((.result.totalCount // null) | type) == "number" and .result.totalCount > (.result.worktrees | length))' "$d/wl.json" >/dev/null 2>&1; then
    printf '%s\t%s\n' "$host" "worktree list truncated at the limit of 500: some worktrees are not listed, the count is a lower bound" >> "$d/bad.tsv"
  fi
  # shellcheck disable=SC2016  # the jq program is single-quoted on purpose
  jq -c --arg host "$host" --arg re "$CM_PATH_MATCH" --arg self "$(cm_lower "$CM_SELF_WORKTREE")" \
        --arg orca "$(cm_lower "${CM_ORCA_REPO:-$(cm_cfg .worktrees.orca_repo)}")" \
        --slurpfile neverf "$TMP/never.json" --slurpfile lanesf "$TMP/lanes.json" --slurpfile standf "$TMP/stand.json" '
    ($neverf[0]) as $never | ($lanesf[0]) as $lanes | ($standf[0]) as $stand |
    def linked: (((.linkedIssue | type) == "number") and .linkedIssue > 0)
                or any((.linkedItems // [])[]?; (.type // "") == "issue")
                or ((.linkedLinearIssue // null) != null) or ((.linkedGitLabIssue // null) != null);
    def base: (.path | sub("/+$"; "") | split("/") | last);
    def names: [(base | ascii_downcase), ((.displayName // "") | ascii_downcase)] | map(select(. != ""));
    def exempt_reason:
      if (.isMainWorktree // false) then "main checkout"
      elif (.isArchived // false) then "archived"
      elif any(names[]; . == $self) and ($orca == "" or ((.path | sub("/+$"; "") | split("/"))[:-1] | map(ascii_downcase) | index($orca)) != null) then "concertmaster worktree"
      elif any(names[]; . as $n | any($lanes[]; . == $n)) then "standing lane (configured)"
      elif (.path | sub("/+$"; "")) as $p | any($stand[]; . == $p) then "standing lane (ledger)"
      elif (.path | ascii_downcase | split("/")) as $segs | any($never[]; . as $n | any($segs[]; . == $n)) then "never_touch"
      else null end;
    .result.worktrees[]
    | select((.path | type) == "string" and .path != "" and (.path | test($re)))
    | {host: $host, name: base, path: .path, branch: ((.branch // "") | sub("^refs/heads/"; "")),
       pr: (if ((.linkedPR | type) == "number") then .linkedPR else null end),
       linked: linked, exempt: exempt_reason}' "$d/wl.json" >> "$d/rows.ndjson" 2>/dev/null \
    || { printf '%s\t%s\n' "$host" "the worktree list could not be parsed" >> "$d/bad.tsv"; : > "$d/rows.ndjson"; }
}
n=0; JOBS=()
while IFS= read -r host; do
  [ -n "$host" ] || continue
  n=$((n + 1)); read_host "$n" "$host" & JOBS+=("$!")
done < "$TMP/hosts.tsv"
for j in ${JOBS[@]+"${JOBS[@]}"}; do wait "$j" 2>/dev/null || true; done
: > "$TMP/rows.ndjson"
for ((i = 1; i <= n; i++)); do
  d="$TMP/h/$i"; [ -d "$d" ] || continue
  cat "$d/rows.ndjson" >> "$TMP/rows.ndjson" 2>/dev/null; cat "$d/bad.tsv" >> "$TMP/bad.tsv" 2>/dev/null
done

# an exempt reason wins over "unlinked"; a linked row is never listed
if ! jq -sc '{unlinked: [.[] | select(.linked | not) | select(.exempt == null) | {host, name, path, branch, pr}] | sort_by(.host, .path),
         exempt: ([.[] | select(.exempt != null)] | length), read: length}' "$TMP/rows.ndjson" > "$TMP/res.json" 2>/dev/null; then
  echo '{"unlinked":[],"exempt":0,"read":0}' > "$TMP/res.json"
  printf '%s\t%s\n' "(report)" "the rows could not be summarised" >> "$TMP/bad.tsv"
fi
BAD='[]'; [ -s "$TMP/bad.tsv" ] && BAD="$(jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {name: .[0], error: (.[1] // "")})' "$TMP/bad.tsv")"

printf '%s\n' "$BAD" > "$TMP/bad.json"
if [ "$MODE" = json ]; then
  jq -c --slurpfile badf "$TMP/bad.json" '$badf[0] as $bad | . + {hosts: $bad, complete: ($bad | length == 0)}' "$TMP/res.json"; exit 0
fi
n="$(jq -r '.unlinked | length' "$TMP/res.json")"
suffix=""
if [ "$(jq -r 'length' <<<"$BAD")" -gt 0 ]; then
  suffix=" (CHECK INCOMPLETE: $(jq -r 'map("\(.name): \(.error)") | join("; ")' <<<"$BAD"))"
fi
printf 'unlinked-worktrees: %s (target 0)%s\n' "$n" "$suffix"
jq -r '.unlinked[] | "  UNLINKED \(.name) @ \(.host): \(.path) pr=\(.pr // "none")"' "$TMP/res.json"
exit 0
