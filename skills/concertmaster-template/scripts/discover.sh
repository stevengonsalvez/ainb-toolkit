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
#   orca terminal list [--environment h] --json  per reachable host, only when config
#                                                agents.forbidden is set (the forbidden-agent check)
#
# Filtered to repos of config github.org (github.exclude_repo_patterns left
# out). The org repo list comes from `gh repo list $CM_ORG`, cached 24h in $CM_HOME/cache.
# An unreachable host is reported as reachable=false, never as empty data.
# If `orca host list` itself fails, the hosts named in the ledger are listed
# as reachable=false (only the local host is queried), so they never vanish.
#
# Terminals under config worktrees.path_match are listed in `terminals` with their
# agentIdentity when agents.forbidden is set; classify.sh turns every one running a
# forbidden agent into a VIOLATION row. A terminal list that failed or was cut off
# (truncated) is recorded in `terminalScope.hosts` with ok:false, never as "no
# terminals"; classify reports it as an incomplete check.
#
# Git state (dirty, unpushed) is keyed by host + path. Local rows: git runs here. Remote rows:
# one short-lived `orca terminal create --environment <host>` per host (hosts in parallel) runs
# a one-line sh script that lists the repo's worktrees and prints raw facts; the terminal is
# read until its end marker (CM_GIT_TIMEOUT, 30s) and closed by its exact handle. When Orca
# cannot do it, ssh is tried (the ledger's hosts.<h>.hostname, else the host name). Only when
# both fail is a remote row's git null, and `gitScope.hosts[]` names the host and both errors,
# so classify reports unknown-git with the reason: a timeout is listed, never clean, never gone.
# Untracked tool scratch (census.ignore_untracked) is counted in git.ignoredUntracked, not dirty.
# Supabase stacks: per reachable host, `supabaseScope.hosts[]` = the running stacks (docker label
# com.supabase.cli.project: project id, container count, bind mounts) and the project_id of every Orca
# worktree there; classify.sh turns it into orphan stacks. docker missing or silent, a failed ssh and a
# cut-off worktree list are recorded, never read as "no stacks".
# Known gap: git-only worktrees on remote hosts are not discovered (SKILL.md § Open config).
# A failed git check is recorded as null with statusOk:false, never as clean.
#
# Env: CM_HOME (~/.concertmaster), CM_HOST_TIMEOUT (25s), CM_GIT_TIMEOUT (30s), CM_ORG, CM_REPO
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
  -h|--help) sed -n '2,/^set -uo/{/^#/p;}' "$0"; exit 0 ;;
  '') ;;
  *) cm_warn "unknown arg: $1"; exit 2 ;;
esac

for dep in jq git; do
  command -v "$dep" >/dev/null 2>&1 || { cm_warn "missing dependency: $dep"; exit 1; }
done

[ -n "$CM_ORG" ] && [ -n "$CM_REPO" ] || {
  cm_warn "set github.org and github.main_repo in config.yaml (or CM_ORG, CM_REPO)"; exit 1; }

ORCA="$(cm_cli)" || exit 2
HOST_TIMEOUT="${CM_HOST_TIMEOUT:-25}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cm-discover.XXXXXX")" || { cm_warn "discover: cannot create a temp dir"; exit 1; }
trap 'rm -rf -- "${TMP:?}"' EXIT
: > "$TMP/errors.ndjson"
: > "$TMP/hosts.ndjson"
: > "$TMP/rows.ndjson"
: > "$TMP/git.ndjson"
: > "$TMP/gitonly.ndjson"
: > "$TMP/prs-all.ndjson"
: > "$TMP/terminals.ndjson"
: > "$TMP/termhosts.ndjson"
: > "$TMP/gitscope.ndjson"
: > "$TMP/sbscope.ndjson"

err() { jq -cn --arg where "$1" --arg msg "$2" '{where:$where, message:$msg}' >> "$TMP/errors.ndjson"; }

# ---- remote git state ----------------------------------------------------------
# Runs on the remote host (sh -c, one line: it is typed into an Orca terminal, so no single quote,
# no tab, no "!" in it). For each repo path given it lists that repo's worktrees and prints raw
# facts, one per line, behind a marker built at run time so the echoed command never matches it.
# The filtering (census.ignore_untracked) happens here, on the concertmaster host, in cm_status_dirt.
# shellcheck disable=SC2016  # single quotes on purpose: the text runs on the remote host
REMOTE_GIT_SH='m="@@""CMG@@"; for r in "$@"; do git -C "$r" worktree list --porcelain 2>/dev/null | sed -n "s/^worktree //p" | while IFS= read -r p; do echo "$m P $p"; [ -d "$p" ] || { echo "$m GONE"; continue; }; if s=$(git --no-optional-locks -C "$p" status --porcelain --untracked-files=all 2>/dev/null); then echo "$m SOK"; [ -z "$s" ] || printf "%s\n" "$s" | sed "s/^/$m S /"; else echo "$m SERR"; fi; if u=$(git -C "$p" rev-list --count HEAD --not --remotes 2>/dev/null); then echo "$m U $u"; else echo "$m UERR"; fi; echo "$m B $(git -C "$p" branch --show-current 2>/dev/null)"; echo "$m H $(git -C "$p" rev-parse HEAD 2>/dev/null)"; done; done; echo "$m END"'
GIT_TIMEOUT="${CM_GIT_TIMEOUT:-30}"
case "$GIT_TIMEOUT" in ''|*[!0-9]*|0) GIT_TIMEOUT=30 ;; esac

# sq <string>: single-quote it for a POSIX shell.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# rgit_orca <host> <i> <root-tsv> <outfile>: git facts through a short-lived Orca terminal on the
# host. The terminal is always closed by its exact handle. Sets RGIT_ERR on failure.
rgit_orca() {
  local h="$1" i="$2" roots="$3" outf="$4" cmd path wid sel resp handle t deadline got=0 msg title stray
  local -a hsel
  cm_cli_host_into hsel "$h"
  title="cm-git-census-$$-$i"   # unique per run and host, so a sweep never closes anyone else's terminal
  cmd="sh -c $(sq "$REMOTE_GIT_SH") sh"
  while IFS="$(printf '\t')" read -r path wid; do cmd="$cmd $(sq "$path")"; done < "$roots"
  IFS="$(printf '\t')" read -r path wid < "$roots"
  if [ -n "$wid" ]; then sel="id:$wid"; else sel="path:$path"; fi
  resp="$(cm_timeout 20 "$ORCA" terminal create ${hsel[@]+"${hsel[@]}"} --worktree "$sel" --title "$title" --command "$cmd" --json </dev/null 2>"$TMP/rgit-$i.err" | "$HERE/jsanitize")"
  handle="$(printf '%s' "$resp" | jq -r '.result.terminal.handle // .result.handle // .result.startupTerminal.handle // empty' 2>/dev/null)"
  if [ -z "$handle" ]; then
    msg="$(printf '%s' "$resp" | jq -r '.error.message? // empty' 2>/dev/null)"
    RGIT_ERR="terminal create failed: ${msg:-$(head -c 160 "$TMP/rgit-$i.err" | tr '\n' ' ')}"
    # A create that timed out may still have made the terminal: close any carrying this run's unique title.
    for stray in $(cm_timeout 15 "$ORCA" terminal list ${hsel[@]+"${hsel[@]}"} --json </dev/null 2>/dev/null | "$HERE/jsanitize" \
        | jq -r --arg t "$title" '.result.terminals[]? | select((.title // "") == $t) | .handle // empty' 2>/dev/null); do
      cm_timeout 15 "$ORCA" terminal close --terminal "$stray" ${hsel[@]+"${hsel[@]}"} --json </dev/null >/dev/null 2>&1 \
        || err "git census $h" "could not close terminal $stray; close it by hand ($ORCA terminal close --terminal $stray ${hsel[*]-})"
    done
    return 1
  fi
  deadline=$((SECONDS + GIT_TIMEOUT))
  : > "$outf"
  while :; do
    t="$(cm_timeout 15 "$ORCA" terminal read --terminal "$handle" ${hsel[@]+"${hsel[@]}"} --limit 5000 --json </dev/null 2>/dev/null | "$HERE/jsanitize" \
        | jq -r '(.result.terminal.tail // .result.tail // .result.text // .result.output // .result.screen // "") | if type == "array" then join("\n") else tostring end' 2>/dev/null)" || t=""
    printf '%s\n' "$t" | tr -d '\r' | sed -n 's/^[^@]*@@CMG@@ //p' > "$outf"
    if grep -qx 'END' "$outf"; then got=1; break; fi
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 1
  done
  if ! cm_timeout 15 "$ORCA" terminal close --terminal "$handle" ${hsel[@]+"${hsel[@]}"} --json </dev/null >/dev/null 2>&1; then
    err "git census $h" "could not close terminal $handle; close it by hand ($ORCA terminal close --terminal $handle ${hsel[*]-})"
  fi
  if [ "$got" -ne 1 ]; then
    RGIT_ERR="timed out after ${GIT_TIMEOUT}s waiting for git output"
    return 1
  fi
  return 0
}

# rgit_ssh <host> <root-tsv> <outfile>: the same facts over ssh. Sets RGIT_ERR on failure.
rgit_ssh() {
  local h="$1" roots="$2" outf="$3" target args="" path wid rc raw errf
  errf="$TMP/rgit-ssh-$(printf '%s' "$h" | tr -c 'A-Za-z0-9._-' _).err"   # per host: hosts run in parallel
  target=""
  if [ -s "$CM_HOME/ledger.json" ] && cm_ledger_guard "$CM_HOME/ledger.json" 2>/dev/null; then target="$(jq -r --arg h "$h" '.hosts[$h].hostname // empty' "$CM_HOME/ledger.json" 2>/dev/null)"; fi
  target="${CM_SSH_TARGET:-${target:-$h}}"
  case "$target" in -*|*[[:space:]]*|'') RGIT_ERR="invalid ssh target '$target'"; return 1 ;; esac
  while IFS="$(printf '\t')" read -r path wid; do args="$args $(sq "$path")"; done < "$roots"
  rc=0
  raw="$(printf '%s\n' "$REMOTE_GIT_SH" | cm_timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=8 -- "$target" "sh -s --$args" 2>"$errf")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 142 ]; then RGIT_ERR="timed out after 20s"
    else RGIT_ERR="exit $rc $(head -c 160 "$errf" | tr '\n' ' ')"; fi
    return 1
  fi
  printf '%s\n' "$raw" | sed -n 's/^[^@]*@@CMG@@ //p' > "$outf"
  grep -qx 'END' "$outf" || { RGIT_ERR="ssh answered without an end marker"; return 1; }
  return 0
}

# rgit_parse <host> <via> <rawfile> <paths-file>: raw facts to git.ndjson-shaped lines on stdout.
# A row path the host did not list as a worktree is exists:false (unknown, never clean).
rgit_parse() {
  local h="$1" via="$2" raw="$3" paths="$4" line tag rest cur="" sok=0 u="" b="" hd="" st="" gone=0 seen
  seen="$raw.seen"
  : > "$seen"
  flush() {
    [ -n "$cur" ] || return 0
    printf '%s\n' "$cur" >> "$seen"
    if [ "$gone" = 1 ]; then
      jq -cn --arg h "$h" --arg p "$cur" --arg via "$via" '{host:$h, path:$p, exists:false, statusOk:false, dirty:null, unpushed:null, via:$via}'
    else
      local dirty=null noise=0 dn unp=null ok=true
      if [ "$sok" = 1 ]; then dn="$(printf '%s\n' "$st" | cm_status_dirt)"; dirty="${dn% *}"; noise="${dn#* }"; else ok=false; fi
      case "$u" in ''|*[!0-9]*) ok=false ;; *) unp="$u" ;; esac
      jq -cn --arg h "$h" --arg p "$cur" --arg via "$via" --argjson dirty "$dirty" --argjson noise "$noise" \
        --argjson unp "$unp" --argjson ok "$ok" --arg head "$hd" --arg br "$b" \
        '{host:$h, path:$p, exists:true, statusOk:$ok, dirty:$dirty, ignoredUntracked:$noise, unpushed:$unp,
          head:(if $head == "" then null else $head end), branch:(if $br == "" then null else $br end), via:$via}'
    fi
  }
  while IFS= read -r line; do
    tag="${line%% *}"; rest=""
    case "$line" in *' '*) rest="${line#* }" ;; esac   # a bare "B" (detached HEAD) has an empty value, not "B"
    case "$tag" in
      P) flush; cur="$rest"; sok=0; u=""; b=""; hd=""; st=""; gone=0 ;;
      GONE) gone=1 ;;
      SOK) sok=1 ;;
      S) st="$st$rest"$'\n' ;;
      U) u="$rest" ;;
      B) b="$rest" ;;
      H) hd="$rest" ;;
    esac
  done < "$raw"
  flush
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    grep -qxF -- "$line" "$seen" || jq -cn --arg h "$h" --arg p "$line" --arg via "$via" \
      '{host:$h, path:$p, exists:false, statusOk:false, dirty:null, unpushed:null, via:$via}'
  done < "$paths"
  rm -f -- "${seen:?}"
}

# collect_remote_git <host> <i>: Orca first (it answers wherever the worktree list did), ssh when
# that fails. Writes $TMP/rgit-<i>.ndjson and one scope line. Both failing is the only way a
# remote row stays unknown-git, and the scope line says which failed and why.
collect_remote_git() {
  local h="$1" i="$2" via="" e1="" e2="" roots paths raw
  roots="$TMP/roots-$i.tsv"; paths="$TMP/rpaths-$i.txt"; raw="$TMP/rgit-$i.raw"
  RGIT_ERR=""
  if rgit_orca "$h" "$i" "$roots" "$raw"; then via=orca
  else
    e1="orca terminal: $RGIT_ERR"; RGIT_ERR=""
    if rgit_ssh "$h" "$roots" "$raw"; then via=ssh; else e2="ssh: $RGIT_ERR"; fi
  fi
  if [ -n "$via" ]; then
    rgit_parse "$h" "$via" "$raw" "$paths" > "$TMP/rgit-$i.ndjson"
    jq -cn --arg h "$h" --arg via "$via" --arg e "$e1" '{host:$h, ok:true, via:$via, error:(if $e == "" then null else ("fell back to ssh; " + $e) end)}' > "$TMP/rgitscope-$i.ndjson"
  else
    : > "$TMP/rgit-$i.ndjson"
    jq -cn --arg h "$h" --arg e "$e1; $e2" '{host:$h, ok:false, via:null, error:("git state not collected: " + $e)}' > "$TMP/rgitscope-$i.ndjson"
    err "git census $h" "$e1; $e2"
  fi
}

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
  if [ -r "$CM_HOME/ledger.json" ] && ! cm_ledger_guard "$CM_HOME/ledger.json" 2>"$TMP/guard.err"; then
    err "ledger" "refused, not this project's ledger (not read): $(head -c 300 "$TMP/guard.err")"
  elif [ -r "$CM_HOME/ledger.json" ]; then
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
RGIT_PIDS=""; RGIT_IDX=""
SB_PIDS=""; SB_IDX=""
while IFS="$(printf '\t')" read -r kind name; do
  i=$((i + 1))
  if [ "$kind" = "local" ]; then hname="local"; else hname="$name"; fi
  cm_cli_host_into hsel "$hname"
  set -- "$ORCA" worktree ps ${hsel[@]+"${hsel[@]}"} --limit 500 --json
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
    --arg selector "${hsel[*]-}" \
    --argjson total "$( [ "$reachable" = true ] && jq '.result.totalCount // (.result.worktrees|length)' "$ps" || echo null)" \
    --argjson truncated "$( [ "$reachable" = true ] && jq '.result.truncated // false' "$ps" || echo null)" \
    '{name:$name, kind:$kind, selector:$selector, reachable:$reachable,
      error:(if $error == "" then null else $error end), orcaRowCount:$total, truncated:$truncated}' >> "$TMP/hosts.ndjson"
  [ "$reachable" = true ] || continue

  # Terminals on this host, for the forbidden-agent check. A failed, cut-off or unparsable
  # list is ok:false (the check is incomplete), never "none".
  if [ -n "$CM_FORBIDDEN_AGENTS" ]; then
    if [ -z "$CM_PATH_MATCH" ]; then
      jq -cn --arg host "$hname" '{host:$host, ok:false, error:"worktrees.path_match unset"}' >> "$TMP/termhosts.ndjson"
    else
      set -- "$ORCA" terminal list ${hsel[@]+"${hsel[@]}"} --limit 500 --json
      tl="$TMP/term-$i.json"
      trc=0
      cm_timeout "$HOST_TIMEOUT" "$@" </dev/null 2>"$TMP/term-$i.err" | "$HERE/jsanitize" > "$tl" || trc=$?
      if [ "$trc" -eq 0 ] && jq -e '.ok == true and (.result.terminals | type == "array")' "$tl" >/dev/null 2>&1 \
         && jq -c --arg host "$hname" --arg re "$CM_PATH_MATCH" '
              .result.terminals[] | select((.worktreePath // "") | test($re))
              | {host: $host, handle: (.handle // null), worktreePath: .worktreePath,
                 worktreeId: (.worktreeId // null), title: (.title // null),
                 agentIdentity: (.agentIdentity // null)}' "$tl" >> "$TMP/terminals.ndjson" 2>/dev/null; then
        # Rows already listed are kept; a cut-off list makes the host incomplete, never clean.
        if jq -e '.result.truncated == true' "$tl" >/dev/null 2>&1; then
          jq -cn --arg host "$hname" '{host:$host, ok:false, error:"terminal list truncated at 500, some terminals not listed"}' >> "$TMP/termhosts.ndjson"
          err "terminal list $hname" "truncated; forbidden-agent check incomplete on this host"
        else
          jq -cn --arg host "$hname" '{host:$host, ok:true, error:null}' >> "$TMP/termhosts.ndjson"
        fi
      else
        jq -cn --arg host "$hname" --arg e "terminal list failed or unreadable rc=$trc $(head -c 200 "$TMP/term-$i.err")" \
          '{host:$host, ok:false, error:$e}' >> "$TMP/termhosts.ndjson"
        err "terminal list $hname" "forbidden-agent check incomplete on this host"
      fi
    fi
  fi

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

  # Running local Supabase stacks on this host, and the project_id in the config.toml of EVERY Orca
  # worktree on it (any repo, from the unfiltered worktree list), so classify can flag a stack no live
  # worktree names. Local: docker here. Remote: one bounded ssh (the git census above may have used
  # an Orca terminal, but a docker read needs a plain shell). A failed read is ok:false, never "none".
  SB_P=()
  while IFS= read -r _sp; do [ -z "$_sp" ] || SB_P+=("$_sp"); done < <(jq -r '.result.worktrees[]? | .path // empty' "$ps" 2>/dev/null)
  _sbt=""
  if [ "$kind" != "local" ]; then
    if [ -s "$CM_HOME/ledger.json" ] && cm_ledger_guard "$CM_HOME/ledger.json" 2>/dev/null; then _sbt="$(jq -r --arg h "$hname" '.hosts[$h].hostname // empty' "$CM_HOME/ledger.json" 2>/dev/null)"; fi
    _sbt="${CM_SSH_TARGET:-${_sbt:-$hname}}"
  fi
  # In the background, like the git census: hosts answer in parallel and each writes its own file.
  cm_sb_collect "$hname" "$kind" "$_sbt" "$(jq -r '((.result.truncated // false) or ((.result.totalCount // 0) > ((.result.worktrees // []) | length)))' "$ps" 2>/dev/null || echo false)" ${SB_P[@]+"${SB_P[@]}"} > "$TMP/sbscope-$i.ndjson" &
  SB_PIDS="$SB_PIDS $!"; SB_IDX="$SB_IDX $i"

  # Remote git state, in the background (hosts answer in parallel). One repo path per Orca repo on
  # the host (its main checkout when listed); the remote enumerates the repo's worktrees itself.
  if [ "$kind" = "local" ]; then
    jq -cn --arg h "$hname" '{host:$h, ok:true, via:"local", error:null}' >> "$TMP/gitscope.ndjson"
  else
    jq -r --arg h "$hname" 'select(.host == $h and .path != null) | .path' "$TMP/rows.ndjson" | sort -u > "$TMP/rpaths-$i.txt"
    jq -rs --arg h "$hname" '[.[] | select(.host == $h and .path != null)] | group_by(.repoId // .repo)
      | map((map(select(.isMainWorktree)) + .) | .[0]) | .[] | [.path, (.worktreeId // "")] | @tsv' "$TMP/rows.ndjson" > "$TMP/roots-$i.tsv" 2>/dev/null
    if [ -s "$TMP/roots-$i.tsv" ]; then
      collect_remote_git "$hname" "$i" &
      RGIT_PIDS="$RGIT_PIDS $!"
      RGIT_IDX="$RGIT_IDX $i"
    else
      jq -cn --arg h "$hname" '{host:$h, ok:true, via:"none", error:null}' >> "$TMP/gitscope.ndjson"
    fi
  fi
done < "$TMP/hosts.tsv"
for _pid in $RGIT_PIDS; do wait "$_pid" 2>/dev/null || true; done
for _pid in $SB_PIDS; do wait "$_pid" 2>/dev/null || true; done
for _i in $SB_IDX; do cat "$TMP/sbscope-$_i.ndjson" >> "$TMP/sbscope.ndjson" 2>/dev/null || true; done
for _i in $RGIT_IDX; do
  cat "$TMP/rgit-$_i.ndjson" >> "$TMP/git.ndjson" 2>/dev/null || true
  cat "$TMP/rgitscope-$_i.ndjson" >> "$TMP/gitscope.ndjson" 2>/dev/null || true
done

# ---- local git state + git-only worktrees ------------------------------------
# git_state <path>: one JSON object; never mutates (no optional index locks).
git_state() {
  local p="$1" st dirty=null noise=0 unpushed=null ok=true head url slug dn
  if ! git -C "$p" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    jq -cn --arg path "$p" '{host:"local", path:$path, exists:false, statusOk:false, dirty:null, unpushed:null}'
    return
  fi
  if st="$(git --no-optional-locks -C "$p" status --porcelain --untracked-files=all 2>/dev/null)"; then
    # Untracked tool scratch (census.ignore_untracked) is noise, not dirt: counted apart.
    dn="$(printf '%s\n' "$st" | cm_status_dirt)"
    dirty="${dn% *}"; noise="${dn#* }"
  else
    ok=false
  fi
  if unpushed="$(git -C "$p" rev-list --count HEAD --not --remotes 2>/dev/null)" && [ -n "$unpushed" ]; then :
  else unpushed=null; ok=false; fi
  head="$(git -C "$p" rev-parse HEAD 2>/dev/null || echo '')"
  url="$(git -C "$p" remote get-url origin 2>/dev/null || echo '')"
  slug="$(cm_org_slug "$url" || true)"
  jq -cn --arg path "$p" --argjson dirty "$dirty" --argjson noise "$noise" --argjson unpushed "$unpushed" --argjson ok "$ok" \
    --arg head "$head" --arg slug "$slug" \
    '{host:"local", path:$path, exists:true, statusOk:$ok, dirty:$dirty, ignoredUntracked:$noise, unpushed:$unpushed,
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
  --slurpfile terms "$TMP/terminals.ndjson" \
  --slurpfile termHosts "$TMP/termhosts.ndjson" \
  --slurpfile gitScope "$TMP/gitscope.ndjson" \
  --slurpfile sbScope "$TMP/sbscope.ndjson" \
  --argjson ignoreUntracked "$(jq -nc --arg s "$CM_IGNORE_UNTRACKED" '$s | split(" ") | map(select(length > 0))')" \
  --arg pathMatch "$CM_PATH_MATCH" \
  --arg forbidden "$CM_FORBIDDEN_AGENTS" \
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
      terminals: $terms,
      gitScope: {hosts: $gitScope, ignoreUntracked: $ignoreUntracked},
      terminalScope: {enabled: ($forbidden != ""),
                      pathMatch: (if $pathMatch == "" then null else $pathMatch end),
                      hosts: $termHosts},
      supabaseScope: {hosts: $sbScope},
      errors: $errors
    }'
