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
# Env: CM_HOST_TIMEOUT (default 30 s per call), CM_ORCA_REPO (else worktrees.orca_repo).
# Returns 0 whenever it ran.

cm_fleet_worktrees() {
  local out="$1" orca san repo timeout hl i kind name hname wl rc why
  local -a sel args
  orca="$(cm_orca)"
  # shellcheck disable=SC2154  # _cm_lib_dir is set by lib.sh, which every caller sources first
  san="$_cm_lib_dir/jsanitize"
  repo="${CM_ORCA_REPO:-$(cm_cfg .worktrees.orca_repo)}"
  timeout="${CM_HOST_TIMEOUT:-30}"
  : > "$out/hosts.ndjson"; : > "$out/unreach.ndjson"
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
    if [ "$kind" = local ]; then hname=local; sel=(); else hname="$name"; sel=(--environment "$name"); fi
    args=(worktree list --json --limit 500)
    [ -z "$repo" ] || args+=(--repo "name:$repo")
    wl="$out/wl-$i.json"; rc=0
    cm_timeout "$timeout" "$orca" "${args[@]}" ${sel[@]+"${sel[@]}"} </dev/null 2>"$out/wl-$i.err" | "$san" > "$wl" || rc=$?
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
  return 0
}
