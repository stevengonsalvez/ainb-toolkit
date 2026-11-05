#!/usr/bin/env bash
# shellcheck shell=bash
# fleet-read.sh: read every Orca host's worktree list. Sourced after lib.sh, never executed.
# Used by asks.sh, lessons-recon.sh and fleet-state.sh: one host loop, one meaning of "unreachable".
#
#   cm_fleet_worktrees <outdir>
#
# Writes into <outdir> (which must exist):
#   hosts.ndjson    one line per host that answered:  {"host":"<name|local>","file":"<outdir>/wl-N.json"}
#   unreach.ndjson  one line per host (or the host list) that failed: {"host":...,"error":...}
#   wl-N.json       that host's `orca worktree list --json` reply (sanitized)
# An unreachable, timed-out or garbage host is LISTED, never treated as empty or gone. A list cut off at
# the limit is read and also listed. A failed host list still reads the local host, and says so.
# One failure is not a failure: a reachable host that answers the project-scoped list with
# {"ok":false,"error":{"code":"repo_not_found"}} (exit 1) may simply have no worktrees of this project. It is
# read as complete, with an empty list, ONLY IF all three hold (cm_fleet_repo_absent): (a) `orca repo list`
# on that host answers (ok, .result.repos an array), (b) no repo in it has a path matching
# worktrees.path_match and none is named like the project, (c) an UNSCOPED `orca worktree list` on that host is ok, not truncated, and no
# worktree path in it matches path_match (a list of exactly the row limit, CM_FLEET_LIMIT default 500, counts as cut off). Any match, any failed or garbled call, any other error code, a
# timeout, or an unset path_match: the host is listed unreachable, with the reason (fail closed).
# Env: CM_HOST_TIMEOUT (default 30 s per call), CM_FLEET_LIMIT (rows per list, default 500), CM_ORCA_REPO (else worktrees.orca_repo).
# Runs with pipefail on (restored on return), whatever the caller set.
# Returns 0 whenever it ran.

# cm_fleet_is_repo_not_found <exit code> <sanitised reply>: true for the one answer the proof applies to,
# `{"ok":false,"error":{"code":"repo_not_found"}}` with exit 1. Every caller that scopes a list asks this.
cm_fleet_is_repo_not_found() {
  [ "$1" -eq 1 ] && jq -e '.ok == false and .error.code == "repo_not_found"' <<<"$2" >/dev/null 2>&1
}

# cm_fleet_repo_absent <timeout> <orca> <san> [<selector arg>...]
# Called only after a project-scoped worktree list answered repo_not_found. Returns 0 when this host
# provably has no worktree of the project (parts a, b and c above), else 1; CM_FLEET_WHY then holds the
# reason, naming the matching path when there is one. <selector arg>... is empty for the local host,
# `--environment <name>` for another. Keeps both answers in variables: no files, no temp dir.
cm_fleet_repo_absent() {
  local timeout="$1" orca="$2" san="$3" rl ul rc hit lim="${CM_FLEET_LIMIT:-500}"
  shift 3
  CM_FLEET_WHY=""
  if [ -z "${CM_PATH_MATCH:-}" ]; then
    CM_FLEET_WHY="repo_not_found, but worktrees.path_match is unset: cannot rule out the project under another name"; return 1
  fi
  # An invalid regex never errors over an empty list, which would read as "no match": refuse it up front.
  if ! jq -n --arg re "$CM_PATH_MATCH" '"" | test($re)' >/dev/null 2>&1; then
    CM_FLEET_WHY="repo_not_found, but worktrees.path_match is not a valid regex: cannot rule out the project under another name"; return 1
  fi
  rc=0
  rl="$(cm_timeout "$timeout" "$orca" repo list --json "$@" </dev/null 2>/dev/null | "$san")" || rc=$?
  if [ "$rc" -ne 0 ] || ! jq -e '.ok == true and (.result.repos | type == "array")' <<<"$rl" >/dev/null 2>&1; then
    CM_FLEET_WHY="repo_not_found, but orca repo list failed or was not a complete repo list (exit $rc): cannot rule out the project under another name"; return 1
  fi
  hit="$(jq -r --arg re "$CM_PATH_MATCH" '[.result.repos[] | if (.path | type) != "string" or .path == "" then "(row without a path)" elif (.path | test($re)) or ((.path + "/") | test($re)) then .path else empty end] | first // empty' <<<"$rl" 2>/dev/null)" \
    || { CM_FLEET_WHY="repo_not_found, but the repo list could not be matched against worktrees.path_match"; return 1; }
  if [ -n "$hit" ]; then
    CM_FLEET_WHY="repo_not_found, but a registered repo matches path_match under another name: $hit"; return 1
  fi
  rc=0
  # A repo registered here under the very name that was asked for contradicts repo_not_found: trust neither.
  if [ -n "${CM_FLEET_REPO:-}" ]; then
    hit="$(jq -r --arg n "$CM_FLEET_REPO" '[.result.repos[] | select(((.displayName // "") | tostring | ascii_downcase) == ($n | ascii_downcase)) | ((.path // .displayName // "") | tostring | if . == "" then "(row without a path)" else . end)] | first // empty' <<<"$rl" 2>/dev/null)" \
      || { CM_FLEET_WHY="repo_not_found, but the repo list could not be matched against the project name"; return 1; }
    if [ -n "$hit" ]; then
      CM_FLEET_WHY="repo_not_found, but a registered repo is named like the project: $hit"; return 1
    fi
  fi
  ul="$(cm_timeout "$timeout" "$orca" worktree list --json --limit "$lim" "$@" </dev/null 2>/dev/null | "$san")" || rc=$?
  if [ "$rc" -ne 0 ] || ! jq -e '.ok == true and (.result.worktrees | type == "array")
       and (.result.truncated != true) and ((.result.totalCount // 0) <= (.result.worktrees | length))
       and ((.result.worktrees | length) < $lim)' --argjson lim "$lim" <<<"$ul" >/dev/null 2>&1; then
    CM_FLEET_WHY="repo_not_found, but the unscoped worktree list failed, was cut off or was not a list (exit $rc): cannot rule out the project under another name"; return 1
  fi
  # The page must cover the host that was asked (result.hostScope.hostIds non-empty; a CLI that sends no scope is
  # taken as covering it). Hosts it lists as omitted (a paired server's own ssh targets and runtimes, selector null)
  # are outside this host's census exactly as they are for the normal scoped read, so they do not block the proof:
  # requiring them empty would leave every such host unreachable.
  if ! jq -e '(.result.hostScope.hostIds // ["local"]) | length > 0' <<<"$ul" >/dev/null 2>&1; then
    CM_FLEET_WHY="repo_not_found, but the unscoped worktree list did not cover the host it was asked about: cannot rule out the project there"; return 1
  fi
  hit="$(jq -r --arg re "$CM_PATH_MATCH" '[.result.worktrees[] | if (.path | type) != "string" or .path == "" then "(row without a path)" elif (.path | test($re)) or ((.path + "/") | test($re)) then .path else empty end] | first // empty' <<<"$ul" 2>/dev/null)" \
    || { CM_FLEET_WHY="repo_not_found, but the unscoped worktree list could not be matched against worktrees.path_match"; return 1; }
  if [ -n "$hit" ]; then
    CM_FLEET_WHY="repo_not_found, but a worktree matches path_match: $hit"; return 1
  fi
  return 0
}

cm_fleet_worktrees() {
  local out="$1" orca san repo timeout hl i kind name hname wl rc why restore_pf
  local -a sel args
  orca="$(cm_cli)" || return 2
  # shellcheck disable=SC2154  # _cm_lib_dir is set by lib.sh, which every caller sources first
  san="$_cm_lib_dir/jsanitize"
  repo="${CM_ORCA_REPO:-$(cm_cfg .worktrees.orca_repo)}"
  timeout="${CM_HOST_TIMEOUT:-30}"
  : > "$out/hosts.ndjson"; : > "$out/unreach.ndjson"
  # The exit code of `orca ... | $san` is orca's only under pipefail: turn it on for this reader and restore the
  # caller's setting before returning, so no caller needs to have set it.
  restore_pf="$(set +o | grep -E ' pipefail$')"; set -o pipefail
  hl="$out/hostlist.json"
  if cm_timeout "$timeout" "$orca" host list --json </dev/null 2>"$out/hl.err" | "$san" > "$hl" \
     && jq -e '.result.hosts | type == "array"' "$hl" >/dev/null 2>&1; then
    :
  else
    jq -cn --arg e "$(head -c 200 "$out/hl.err" 2>/dev/null)" '{host:"host list", error:("orca host list failed: " + $e + "; only the local host was read")}' >> "$out/unreach.ndjson"
    printf '{"result":{"hosts":[{"kind":"local","name":"this machine"}]}}\n' > "$hl"
  fi
  i=0
  while IFS="$(printf '\t')" read -r kind name; do
    i=$((i + 1))
    [ -n "$name" ] || continue
    if [ "$kind" = local ]; then hname=local; else hname="$name"; fi
    cm_cli_host_into sel "$hname"
    args=(worktree list --json --limit "${CM_FLEET_LIMIT:-500}")
    [ -z "$repo" ] || args+=(--repo "name:$repo")
    wl="$out/wl-$i.json"; rc=0
    cm_timeout "$timeout" "$orca" "${args[@]}" ${sel[@]+"${sel[@]}"} </dev/null 2>"$out/wl-$i.err" | "$san" > "$wl" || rc=$?
    # repo_not_found (ok:false, exit 1, scoped list only): a host with no worktrees of this project, if provable.
    if [ -n "$repo" ] && cm_fleet_is_repo_not_found "$rc" "$(cat "$wl")"; then
      if CM_FLEET_REPO="$repo" cm_fleet_repo_absent "$timeout" "$orca" "$san" ${sel[@]+"${sel[@]}"}; then
        printf '{"ok":true,"result":{"worktrees":[],"inferredEmpty":"repo_not_found"}}\n' > "$wl"
        jq -cn --arg h "$hname" --arg f "$wl" '{host:$h, file:$f}' >> "$out/hosts.ndjson"
      else
        jq -cn --arg h "$hname" --arg e "$CM_FLEET_WHY" '{host:$h, error:$e}' >> "$out/unreach.ndjson"
      fi
      continue
    fi
    if [ "$rc" -ne 0 ] || ! jq -e '.ok == true and (.result.worktrees | type == "array")' "$wl" >/dev/null 2>&1; then
      why="not a worktree list"
      [ "$rc" -eq 0 ] || why="orca worktree list failed (exit $rc)"
      [ -s "$out/wl-$i.err" ] && why="$(head -c 160 "$out/wl-$i.err" | tr '\n' ' ')"
      jq -cn --arg h "$hname" --arg e "$why" '{host:$h, error:$e}' >> "$out/unreach.ndjson"
      continue
    fi
    jq -cn --arg h "$hname" --arg f "$wl" '{host:$h, file:$f}' >> "$out/hosts.ndjson"
    if jq -e '.result.truncated == true or ((.result.totalCount // 0) > (.result.worktrees | length))' "$wl" >/dev/null 2>&1; then
      jq -cn --arg h "$hname" '{host:$h, error:"worktree list truncated at the limit: some comments may not be read"}' >> "$out/unreach.ndjson"
    fi
  done < <(jq -r '.result.hosts[] | [((.kind // "") | if . == "" then "-" else . end), (.name // "")] | @tsv' "$hl")
  eval "$restore_pf"
  return 0
}
