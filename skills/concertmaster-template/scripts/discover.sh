#!/usr/bin/env bash
# discover.sh: one read-only census of every configured-org worktree, session
# and open PR across all Orca hosts. Prints ONE JSON document to stdout.
#
#   scripts/discover.sh [--no-prs] > discover.json
#   scripts/discover.sh | scripts/classify.sh --table
#
# Sources, per tick:
#   orca host list --json                        every host, never hardcoded
#   orca worktree ps [--environment h] --json    per host, with a timeout
#   git worktree list --porcelain                local org checkouts only
#                                                (catches git-only worktrees)
#   gh pr list                                   open PRs + branch PR state
#
# Filtered to repos of config github.org (github.exclude_repo_patterns left
# out). The org repo list comes from `gh repo list $CM_ORG`, cached 24h in $CM_HOME/cache.
# An unreachable host is reported as reachable=false, never as empty data.
# If `orca host list` itself fails, the hosts named in the ledger are listed
# as reachable=false (only the local host is queried), so they never vanish.
#
# Git state (dirty, unpushed) is collected for LOCAL rows only and keyed by
# host + path; remote rows carry git:null (unknown). Known gap: git-only
# worktrees on remote hosts are not discovered (SKILL.md § Open config).
# A failed git check is recorded as null with statusOk:false, never as clean.
#
# Env: CM_HOME (~/.concertmaster), CM_HOST_TIMEOUT (25s), CM_ORG, CM_REPO
# (default from config github.org, github.main_repo).
# Writes nothing except the org-repo cache. Exit 0 whenever a document was
# printed; 1 only when even the host list could not be read and no doc built.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

WITH_PRS=1
case "${1:-}" in
  --no-prs) WITH_PRS=0 ;;
  -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
  '') ;;
  *) cm_warn "unknown arg: $1"; exit 2 ;;
esac

for dep in jq git; do
  command -v "$dep" >/dev/null 2>&1 || { cm_warn "missing dependency: $dep"; exit 1; }
done

[ -n "$CM_ORG" ] && [ -n "$CM_REPO" ] || {
  cm_warn "set github.org and github.main_repo in config.yaml (or CM_ORG, CM_REPO)"; exit 1; }

ORCA="$(cm_orca)"
HOST_TIMEOUT="${CM_HOST_TIMEOUT:-25}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cm-discover.XXXXXX")" || { cm_warn "discover: cannot create a temp dir"; exit 1; }
trap 'rm -rf -- "${TMP:?}"' EXIT
: > "$TMP/errors.ndjson"
: > "$TMP/hosts.ndjson"
: > "$TMP/rows.ndjson"
: > "$TMP/git.ndjson"
: > "$TMP/gitonly.ndjson"
: > "$TMP/prs-all.ndjson"

err() { jq -cn --arg where "$1" --arg msg "$2" '{where:$where, message:$msg}' >> "$TMP/errors.ndjson"; }

# ---- org repo list (24h cache) ----------------------------------------------
CACHE="$CM_HOME/cache/org-repos.json"
mkdir -p "$CM_HOME/cache" 2>/dev/null || true
if ! cm_file_fresh "$CACHE" 1440; then
  if command -v gh >/dev/null 2>&1 && cm_timeout 30 gh repo list "$CM_ORG" --limit 500 --json name,isArchived > "$TMP/repos.json" 2>/dev/null \
     && jq -e 'type == "array" and length > 0' "$TMP/repos.json" >/dev/null 2>&1; then
    cp "$TMP/repos.json" "$CACHE"
  elif [ -s "$CACHE" ]; then
    err "org-repos" "gh repo list failed; using stale cache"
  else
    err "org-repos" "gh repo list failed and no cache; nothing can match"
    printf '[]\n' > "$CACHE.tmp" && mv "$CACHE.tmp" "$CACHE"
  fi
fi
# name list without excluded repos (config github.exclude_repo_patterns),
# keyed lowercase for matching Orca display names.
jq -r '.[].name' "$CACHE" 2>/dev/null | while IFS= read -r n; do
  if [ -n "$n" ] && ! cm_repo_excluded "$n"; then printf '%s\n' "$n"; fi
done | jq -R . | jq -sc . > "$TMP/org.json" 2>/dev/null || printf '[]\n' > "$TMP/org.json"

# ---- hosts -------------------------------------------------------------------
if ! cm_timeout "$HOST_TIMEOUT" "$ORCA" host list --json > "$TMP/hostlist.json" 2>"$TMP/hostlist.err" \
   || ! jq -e '.ok == true' "$TMP/hostlist.json" >/dev/null 2>&1; then
  err "orca host list" "$(head -c 300 "$TMP/hostlist.err")"
  # Query only the local host; every other host the ledger knows is listed
  # as unreachable so its workers are never assumed gone.
  printf '{"result":{"hosts":[{"kind":"local","name":"this machine","id":"local"}]}}\n' > "$TMP/hostlist.json"
  if [ -r "$CM_HOME/ledger.json" ]; then
    jq -c '(.hosts // {}) | to_entries[] | select(.key != "local")
           | {name: .key, kind: (.value.kind // "environment"),
              selector: (.value.selector // ("--environment " + .key)), reachable: false,
              error: "orca host list failed; host taken from ledger, not queried",
              orcaRowCount: null, truncated: null}' "$CM_HOME/ledger.json" >> "$TMP/hosts.ndjson" 2>/dev/null \
      || err "ledger" "could not read ledger hosts for fallback"
  else
    err "ledger" "no ledger: remote hosts unknown this run"
  fi
fi

jq -r '.result.hosts[] | [.kind, .name] | @tsv' "$TMP/hostlist.json" > "$TMP/hosts.tsv"
i=0
while IFS="$(printf '\t')" read -r kind name; do
  i=$((i + 1))
  if [ "$kind" = "local" ]; then
    hname="local"
    set -- "$ORCA" worktree ps --limit 500 --json
  else
    hname="$name"
    set -- "$ORCA" worktree ps --environment "$name" --limit 500 --json
  fi
  ps="$TMP/ps-$i.json"
  rc=0
  cm_timeout "$HOST_TIMEOUT" "$@" > "$ps" 2>"$TMP/ps-$i.err" || rc=$?
  if [ "$rc" -eq 0 ] && jq -e '.ok == true and (.result.worktrees | type == "array")' "$ps" >/dev/null 2>&1; then
    reachable=true
    msg=""
  else
    reachable=false
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 142 ]; then msg="timeout after ${HOST_TIMEOUT}s"
    else msg="rc=$rc $(jq -r '.error.message? // empty' "$ps" 2>/dev/null) $(head -c 200 "$TMP/ps-$i.err")"; fi
  fi
  jq -cn --arg name "$hname" --arg kind "$kind" --argjson reachable "$reachable" --arg error "$msg" \
    --arg selector "$([ "$kind" = local ] && printf '' || printf -- '--environment %s' "$name")" \
    --argjson total "$( [ "$reachable" = true ] && jq '.result.totalCount // (.result.worktrees|length)' "$ps" || echo null)" \
    --argjson truncated "$( [ "$reachable" = true ] && jq '.result.truncated // false' "$ps" || echo null)" \
    '{name:$name, kind:$kind, selector:$selector, reachable:$reachable,
      error:(if $error == "" then null else $error end), orcaRowCount:$total, truncated:$truncated}' >> "$TMP/hosts.ndjson"
  [ "$reachable" = true ] || continue

  # Normalise rows; keep only configured-org repos (matched on Orca's repo
  # display name, case-insensitive). Null-safe: remote rows often lack
  # lastOutputAt / createdAt.
  jq -c --arg host "$hname" --slurpfile org "$TMP/org.json" '
    ($org[0] | map(ascii_downcase)) as $keys
    | ($org[0] | map({key: ascii_downcase, value: .}) | from_entries) as $canon
    | .result.worktrees[]
    | ((.repo // "") | ascii_downcase) as $rk
    | select($keys | index($rk))
    | {
        host: $host,
        source: "orca",
        inOrca: true,
        worktreeId: (.worktreeId // null),
        repoId: (.repoId // null),
        repo: $canon[$rk],
        path: (.path // null),
        branch: ((.branch // "") | sub("^refs/heads/"; "") | if . == "" then null else . end),
        displayName: (.displayName // null),
        isMainWorktree: (.isMainWorktree // false),
        isArchived: (.isArchived // false),
        status: (.status // null),
        workspaceStatus: (.workspaceStatus // null),
        comment: (.comment // ""),
        liveTerminalCount: (.liveTerminalCount // 0),
        hasAttachedPty: (.hasAttachedPty // false),
        parentWorktreeId: (.parentWorktreeId // null),
        childWorktreeIds: (.childWorktreeIds // []),
        linkedPR: (.linkedPR // null),
        lastOutputAt: (.lastOutputAt // null),
        lastActivityAt: (.lastActivityAt // null),
        createdAt: (.createdAt // null),
        agents: [ (.agents // [])[] | {
          paneKey: (.paneKey // null),
          parentPaneKey: (.parentPaneKey // null),
          agentType: (.agentType // null),
          state: (.state // null),
          interrupted: (.interrupted // false),
          toolName: (.toolName // null),
          stateStartedAt: (.stateStartedAt // null),
          updatedAt: (.updatedAt // null),
          lastAssistantTail: ((.lastAssistantMessage // "") | .[-300:])
        } ],
        git: null,
        pr: null
      }' "$ps" >> "$TMP/rows.ndjson" 2>/dev/null || err "normalise $hname" "jq failed on worktree ps output"
done < "$TMP/hosts.tsv"

# ---- local git state + git-only worktrees ------------------------------------
# git_state <path>: one JSON object; never mutates (no optional index locks).
git_state() {
  local p="$1" st dirty=null unpushed=null ok=true head url slug
  if ! git -C "$p" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    jq -cn --arg path "$p" '{host:"local", path:$path, exists:false, statusOk:false, dirty:null, unpushed:null}'
    return
  fi
  if st="$(git --no-optional-locks -C "$p" status --porcelain 2>/dev/null)"; then
    dirty="$(printf '%s' "$st" | grep -c . || true)"
  else
    ok=false
  fi
  if unpushed="$(git -C "$p" rev-list --count HEAD --not --remotes 2>/dev/null)" && [ -n "$unpushed" ]; then :
  else unpushed=null; ok=false; fi
  head="$(git -C "$p" rev-parse HEAD 2>/dev/null || echo '')"
  url="$(git -C "$p" remote get-url origin 2>/dev/null || echo '')"
  slug="$(cm_org_slug "$url" || true)"
  jq -cn --arg path "$p" --argjson dirty "$dirty" --argjson unpushed "$unpushed" --argjson ok "$ok" \
    --arg head "$head" --arg slug "$slug" \
    '{host:"local", path:$path, exists:true, statusOk:$ok, dirty:$dirty, unpushed:$unpushed,
      head:(if $head == "" then null else $head end),
      slug:(if $slug == "" then null else $slug end)}'
}

# Local Orca rows: git state per path, and the set of org repo checkouts.
jq -r 'select(.host == "local") | .path // empty' "$TMP/rows.ndjson" | sort -u > "$TMP/local-paths.txt"
: > "$TMP/common.txt"
while IFS= read -r p; do
  [ -d "$p" ] || continue
  git_state "$p" >> "$TMP/git.ndjson"
  cd_common="$(git -C "$p" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [ -n "$cd_common" ] && printf '%s\t%s\n' "$cd_common" "$p" >> "$TMP/common.txt"
done < "$TMP/local-paths.txt"

# One `git worktree list` per distinct org repo (by common git dir).
sort -u -k1,1 "$TMP/common.txt" | while IFS="$(printf '\t')" read -r _common p; do
  repo="$(jq -r --arg p "$p" 'select(.host == "local" and .path == $p) | .repo' "$TMP/rows.ndjson" | head -n 1)"
  git -C "$p" worktree list --porcelain 2>/dev/null | awk -v repo="$repo" '
    function flush() { if (wt != "") printf "%s\t%s\t%s\t%s\t%s\n", repo, wt, head, br, (n == 1 ? "main" : "linked") }
    /^worktree / { flush(); n++; wt = substr($0, 10); head = ""; br = "" }
    /^HEAD /     { head = substr($0, 6) }
    /^branch /   { br = substr($0, 8); sub(/^refs\/heads\//, "", br) }
    END          { flush() }'
done > "$TMP/gitlist.tsv"

while IFS="$(printf '\t')" read -r repo wt head br kind; do
  grep -qxF "$wt" "$TMP/local-paths.txt" && continue   # already an Orca row
  git_state "$wt" >> "$TMP/git.ndjson"
  jq -cn --arg repo "$repo" --arg path "$wt" --arg head "$head" --arg br "$br" --arg kind "$kind" '
    {host:"local", source:"git", inOrca:false, worktreeId:null, repoId:null, repo:$repo,
     path:$path, branch:(if $br == "" then null else $br end), displayName:($path | split("/") | last),
     isMainWorktree:($kind == "main"), isArchived:false, status:null, workspaceStatus:null,
     comment:"", liveTerminalCount:0, hasAttachedPty:false, parentWorktreeId:null,
     childWorktreeIds:[], linkedPR:null, lastOutputAt:null, lastActivityAt:null, createdAt:null,
     agents:[], git:null, pr:null}' >> "$TMP/gitonly.ndjson"
done < "$TMP/gitlist.tsv"

# ---- PRs ---------------------------------------------------------------------
MAIN_SLUG="$CM_ORG/$(jq -r --arg r "$CM_REPO" '[.[] | select(ascii_downcase == ($r | ascii_downcase))][0] // $r' "$TMP/org.json")"
printf '[]\n' > "$TMP/open.json"
if [ "$WITH_PRS" -eq 1 ] && command -v gh >/dev/null 2>&1; then
  cm_timeout 60 gh pr list -R "$MAIN_SLUG" --state open --limit 300 \
    --json number,title,author,headRefName,headRefOid,isDraft,createdAt,updatedAt,url \
    > "$TMP/open.json" 2>"$TMP/open.err" || { err "gh pr list open" "$(head -c 200 "$TMP/open.err")"; printf '[]\n' > "$TMP/open.json"; }

  # Branch -> PR state, one bulk query per GitHub repo that has non-main
  # worktrees, then a per-branch fallback for branches older than the window.
  cat "$TMP/rows.ndjson" "$TMP/gitonly.ndjson" \
    | jq -r 'select(.isMainWorktree | not) | select(.branch != null) | [.repo, .branch] | @tsv' | sort -u > "$TMP/branches.tsv"
  cut -f1 "$TMP/branches.tsv" | sort -u | while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    cm_timeout 60 gh pr list -R "$CM_ORG/$repo" --state all --limit 300 \
      --json number,state,headRefName,headRefOid,mergedAt,closedAt,updatedAt,url,author,isDraft 2>/dev/null \
      | jq -c --arg repo "$repo" '.[] | . + {repo:$repo}' >> "$TMP/prs-all.ndjson" || err "gh pr list $repo" "bulk query failed"
  done
  while IFS="$(printf '\t')" read -r repo br; do
    if ! jq -e --arg r "$repo" --arg b "$br" 'select(.repo == $r and .headRefName == $b)' "$TMP/prs-all.ndjson" 2>/dev/null | grep -q .; then
      cm_timeout 30 gh pr list -R "$CM_ORG/$repo" --head "$br" --state all --limit 1 \
        --json number,state,headRefName,headRefOid,mergedAt,closedAt,updatedAt,url,author,isDraft 2>/dev/null \
        | jq -c --arg repo "$repo" '.[] | . + {repo:$repo}' >> "$TMP/prs-all.ndjson" || true
    fi
  done < "$TMP/branches.tsv"
fi

# ---- assemble ----------------------------------------------------------------
cat "$TMP/rows.ndjson" "$TMP/gitonly.ndjson" > "$TMP/all.ndjson"
jq -n \
  --arg org "$CM_ORG" \
  --arg mainSlug "$MAIN_SLUG" \
  --slurpfile orgRepos "$TMP/org.json" \
  --slurpfile hosts "$TMP/hosts.ndjson" \
  --slurpfile rows "$TMP/all.ndjson" \
  --slurpfile git "$TMP/git.ndjson" \
  --slurpfile prsAll "$TMP/prs-all.ndjson" \
  --slurpfile open "$TMP/open.json" \
  --slurpfile errors "$TMP/errors.ndjson" '
  ($git | map({key: (.host + "\u0000" + .path), value: (del(.path, .host))}) | from_entries) as $g
  | ($prsAll | group_by([.repo, .headRefName])
      | map({key: (.[0].repo + "\u0000" + .[0].headRefName),
             value: (sort_by(.number) | last
                     | {number, state, url, mergedAt, closedAt, updatedAt, headRefOid,
                        isDraft, author: (.author.login // null)})})
      | from_entries) as $pr
  | {
      schema: "concertmaster.discover/v1",
      generatedAt: (now | todate),
      generatedAtMs: (now * 1000 | floor),
      org: $org,
      mainRepo: $mainSlug,
      orgRepos: $orgRepos[0],
      hosts: $hosts,
      worktrees: [ $rows[]
        | . as $r
        | .git = ($g[$r.host + "\u0000" + ($r.path // "")] // null)
        | .pr = (if $r.branch == null or $r.isMainWorktree then null
                 else ($pr[$r.repo + "\u0000" + $r.branch] // null) end) ],
      prs: { open: [ $open[0][] | {number, title, isDraft, createdAt, updatedAt, url,
                                   headRefName, headRefOid, author: (.author.login // null)} ] },
      errors: $errors
    }'
