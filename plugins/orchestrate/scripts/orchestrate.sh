#!/usr/bin/env bash
# One entry point for every orchestrate verb. Transport is Orca only: there is
# no ssh path, no force-push path and no bulk-kill path anywhere in this plugin.
#
#   orchestrate.sh init      <programme> [--trunk B] [--never-merge-into B,B] [--repo DIR]
#   orchestrate.sh discover  [--environment E]...
#   orchestrate.sh adopt     <programme> [--dry-run] [--include-new] [--environment E]...
#   orchestrate.sh status    <programme>
#   orchestrate.sh read      <programme> <lane> [lines]
#   orchestrate.sh send      <programme> <lane> <pr|-> <text> [--observe]
#   orchestrate.sh pr        <programme> <pr> <lane>
#   orchestrate.sh mark      <programme> <lane> <working|idle|asking|done|dead>
#   orchestrate.sh owed      <programme>
#   orchestrate.sh merge     <programme> <pr> [expected-sha]
#   orchestrate.sh post      <programme> <pr> <report.md>
#   orchestrate.sh scrub     <programme> <file.md> [out.md]
#   orchestrate.sh tick      <programme> [--observe]
#   orchestrate.sh loop      <programme> [--every 20m] [--max-ticks N] [--max-hours N]
#                            [--tick-timeout S] [--agent-cmd CMD] [--observe] [--tmux]
#   any verb also takes       [--session <token>] [--harness <name>]
#   orchestrate.sh handover  <programme> [reason]
#   orchestrate.sh takeover  <programme> [--takeover]
#   orchestrate.sh retire    <programme> <lane>
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(dirname "$HERE")"
# shellcheck source=./lib.sh
. "$HERE/lib.sh"

usage() { sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ----------------------------------------------------------------- init

v_init() {
  local programme="${1:-}"; shift || true
  [ -n "$programme" ] || die "init needs a programme name" 2
  local dir="$ORCHESTRATE_HOME/$programme" trunk="" never="" repo=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --trunk) trunk="${2:-}"; shift 2 ;;
      --repo) repo="${2:-}"; shift 2 ;;
      --never-merge-into) never="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  mkdir -p "$dir/reviews" || die "cannot create $dir"
  local f
  for f in programme.yaml ORCHESTRATION.md agents.yaml; do
    [ -f "$dir/$f" ] || cp "$PLUGIN_ROOT/assets/$f" "$dir/$f"
  done
  touch "$dir/lanes.jsonl" "$dir/events.jsonl" "$dir/hosts.jsonl"
  [ -n "$trunk" ] && sed -i.bak -E "s#^trunk:.*#trunk: $trunk#" "$dir/programme.yaml" && rm -f "$dir/programme.yaml.bak"
  [ -n "$never" ] && sed -i.bak -E "s#^never_merge_into:.*#never_merge_into: [${never//,/, }]#" "$dir/programme.yaml" && rm -f "$dir/programme.yaml.bak"
  [ -n "$repo" ] && sed -i.bak -E "s#^repo:.*#repo: $repo#" "$dir/programme.yaml" && rm -f "$dir/programme.yaml.bak"
  printf '%s\n' "$dir"
  printf 'edit programme.yaml (autonomy and repo must both be set deliberately), then claim it:\n'
  printf '  orchestrate.sh takeover %s\n' "$programme"
  printf 'That prints the ownership token once. Export it; every verb that writes needs it.\n'
}

# ----------------------------------------------------------------- discover

# Ask Orca, never ssh (lesson 2: an ssh probe raised a false outage). Liveness
# is never inferred from a terminal listing alone; adopt reads each handle.
v_discover() {
  # shellcheck disable=SC2034  # read by lib.sh, which this script sources
  ORCHESTRATE_RO=1
  local -a envs=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --environment) envs+=("${2:-}"); shift 2 ;;
      *) shift ;;
    esac
  done
  [ "${#envs[@]}" -gt 0 ] || envs=(local)
  local e wts
  for e in "${envs[@]}"; do
    orca_env_args "$e"
    wts="$(orca_call worktree list "${ORCA_ENV_ARGS[@]}" --json 2>/dev/null)"
    if [ -z "$wts" ] || [ "$(printf '%s' "$wts" | jq -r '.result.worktrees | length' 2>/dev/null)" = "" ]; then
      printf '%s\tUNREACHABLE\t-\t-\n' "$e"
      continue
    fi
    printf '%s' "$wts" | jq -r --arg e "$e" '.result.worktrees[]? | "\($e)\tok\t\(.id | split("/") | last)\t\(.id)"'
  done
}

# ----------------------------------------------------------------- adopt

# Propose one lanes.jsonl row per live terminal. Each indexed handle is READ,
# because a remote terminal list has come back empty while lanes were alive.
v_adopt() {
  local programme="${1:-}"; shift || true
  local dry=0 include_new=0
  local -a envs=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      --include-new) include_new=1; shift ;;
      --environment) envs+=("${2:-}"); shift 2 ;;
      *) shift ;;
    esac
  done
  # A dry run reports; it does not act. No event, no index rewrite, no terminal.
  # shellcheck disable=SC2034  # read by lib.sh, which this script sources
  [ "$dry" = 1 ] && ORCHESTRATE_RO=1
  prog_open "$programme"
  [ "$dry" = 1 ] || owner_ensure >/dev/null || return 3
  [ "${#envs[@]}" -gt 0 ] || envs=(local)

  printf 'lane\tenv\tworktree\tagent\thandle\tstatus\tctx\n'
  local lane env wt handle kind text st ctx known new
  while IFS=$'\t' read -r lane env wt handle kind new; do
    [ -n "$lane" ] || continue
    text="$(orca_screen "$handle" "$env")"
    if [ -z "$text" ] && [ "$new" != new ]; then
      known="$(lane_reresolve "$lane")"
      if [ -n "$known" ] && [ "$known" != "$handle" ]; then
        handle="$known"; text="$(orca_screen "$handle" "$env")"
      fi
    fi
    st="$(classify "$kind" "$text")"
    [ -n "$text" ] || st=dead
    case "$(lane_field "$lane" status)" in
      done|retired|needs-rebind) [ "$st" = "idle" ] || [ "$st" = unknown ] && st="$(lane_field "$lane" status)" ;;
    esac
    ctx="$(ctx_pct "$kind" "$text")"
    if [ "$new" = new ]; then
      # The terminal's own title goes in the lane column: without it two
      # terminals in one worktree are indistinguishable proposals.
      printf 'UNINDEXED/%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$lane" "$env" "$wt" "$kind" "$handle" "$st" "${ctx:--}"
      { [ "$dry" = 1 ] || [ "$include_new" = 0 ]; } && continue
    else
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$lane" "$env" "$wt" "$kind" "$handle" "$st" "${ctx:--}"
      [ "$dry" = 1 ] && continue
    fi
    # Merge, never replace. branch, goal, exclusive and title are the
    # operator's, and a re-verify pass that blanks them disarms the retirement
    # guard, which only checks open PRs when it knows the branch.
    lane_upsert "$(jq -nc --argjson old "$(lane_row "$lane")" \
      --arg lane "$lane" --arg env "$env" --arg handle "$handle" --arg wt "$wt" \
      --arg agent "$kind" --arg st "$st" --arg ctx "$ctx" --arg t "$(now)" \
      '{branch: "", goal: "", exclusive: [], title: ""} + $old
       + {lane: $lane, env: $env, handle: $handle, worktree: $wt, agent: $agent,
          status: $st, ctx_pct: $ctx, last_seen: $t}')"
    ev adopt lane "$lane" env "$env" worktree "$wt" agent "$kind" status "$st"
  done < <(adopt_candidates "${envs[@]}")
}

# Candidates are the indexed lanes AND anything live that is not indexed. A lane
# started by hand and never registered is the failure adopt exists to prevent,
# so discovery runs every time, not only on an empty index.
adopt_candidates() {
  local -a envs=("$@")
  local indexed=""
  if [ -s "$LANES" ]; then
    indexed="$(jq -r '.handle' "$LANES" 2>/dev/null)"
    jq -r '[.lane, .env, .worktree, .handle, .agent, ""] | @tsv' "$LANES"
  fi
  local e id wt handle title rows
  for e in "${envs[@]}"; do
    orca_env_args "$e"
    while read -r id; do
      [ -n "$id" ] || continue
      wt="${id##*/}"
      rows="$(orca_call terminal list --worktree "id:$id" "${ORCA_ENV_ARGS[@]}" --json 2>/dev/null \
        | jq -r '.result.terminals[]? | [.handle, (.title // "")] | @tsv')"
      [ -n "$rows" ] || continue
      while IFS=$'\t' read -r handle title; do
        [ -n "$handle" ] || continue
        printf '%s\n' "$indexed" | grep -qxF -- "$handle" && continue
        printf '%s\t%s\t%s\t%s\t%s\tnew\n' "${title:-$wt}" "$e" "$wt" "$handle" "$(cfg default_agent claude)"
      done <<< "$rows"
    done < <(orca_call worktree list "${ORCA_ENV_ARGS[@]}" --json 2>/dev/null | jq -r '.result.worktrees[]?.id')
  done
}

# ----------------------------------------------------------------- status

v_status() {
  # shellcheck disable=SC2034  # read by lib.sh, which this script sources
  ORCHESTRATE_RO=1
  prog_open "${1:-}"
  printf '== lanes\n'
  jq -r '[.lane, .env, .worktree, .agent, .status, (.ctx_pct // "-"), (.last_seen // "-")] | @tsv' "$LANES" \
    | column -t -s"$(printf '\t')" 2>/dev/null
  printf '\n== owner\n'
  if [ -s "$OWNER" ]; then jq -r '"\(.session) on \(.harness), last tick \(.last_tick)"' "$OWNER"; else printf 'released\n'; fi
  printf '\n== hosts\n'
  [ -s "$HOSTS" ] && tail -20 "$HOSTS" | jq -r '[.host, .src, (.disk_free_gb // "-" | tostring) + "G free", (.lanes | tostring) + " lanes", .t] | @tsv' \
    | sort -u -k1,1 | column -t -s"$(printf '\t')" 2>/dev/null
  printf '\n== prs seen\n'
  jq -r 'select(.ev == "pr") | "#\(.pr)\t\(.lane)"' "$EVENTS" 2>/dev/null | sort -u
  printf '\n== owed\n'
  owed_list | column -t -s"$(printf '\t')" 2>/dev/null
  printf '\n== last tick\n'
  jq -r 'select(.ev == "tick") | "\(.t) n=\(.n) open_prs=\(.open_prs) owed=\(.owed) gap=\(.gap_s)s"' "$EVENTS" 2>/dev/null | tail -1
}

# ----------------------------------------------------------------- messaging

v_read() {
  # shellcheck disable=SC2034  # read by lib.sh, which this script sources
  ORCHESTRATE_RO=1
  prog_open "${1:-}"
  lane_screen "${2:-}" | tail -"${3:-12}" | cut -c1-180
}

v_send() {
  local prog_arg="${1:-}" lane="${2:-}" pr="${3:--}" text="${4:-}"
  case "${5:-}" in
    --observe) ORCHESTRATE_OBSERVE=1 ;;
  esac
  prog_open "$prog_arg"
  owner_require || return 3
  lane_send "$lane" "$pr" "$text"
}

v_pr() {
  prog_open "${1:-}"
  owner_require || return 3
  ev pr pr "${2:-}" lane "${3:-}"
}

# `done` is a judgment, so the agent records it. Every other status comes off
# the screen at the next tick.
v_mark() {
  prog_open "${1:-}"
  owner_require || return 3
  local lane="${2:-}" st="${3:-}"
  case "$st" in
    working|idle|asking|done|dead) : ;;
    *) die "status must be one of working idle asking done dead" 2 ;;
  esac
  lane_set "$lane" status "$st"
  ev decision topic "lane $lane status" text "$st" source orchestrator
  printf '%s is %s\n' "$lane" "$st"
}

v_owed() {
  # shellcheck disable=SC2034  # read by lib.sh, which this script sources
  ORCHESTRATE_RO=1
  prog_open "${1:-}"
  local n=0
  while IFS=$'\t' read -r lane pr st; do
    [ -n "$lane" ] || continue
    n=$((n + 1))
    printf 'OWED: lane %s was never told #%s is %s\n' "$lane" "$pr" "$st"
  done < <(owed_list)
  printf '%s owed\n' "$n"
}

v_merge() {
  prog_open "${1:-}"
  owner_require || return 3
  merge_gate "${2:-}" "${3:-}"
}

v_post() {
  prog_open "${1:-}"
  owner_require || return 3
  local pr="${2:-}" f="${3:-}" clean
  clean="$(scrub "$f")" || return 3
  gh pr comment "$pr" --body-file "$clean" >/dev/null || return 1
  ev decision topic "review #$pr" text "posted $(basename "$clean")" source orchestrator
  printf 'posted #%s\n' "$pr"
}

v_scrub() {
  prog_open "${1:-}"
  scrub "${2:-}" "${3:-}"
}

# ------------------------------------------------------------------- tick

# The mechanical half of the tick order. Steps that need judgment (answering a
# lane, reaching a verdict, deciding to merge) are the agent's, and the tick
# skill describes them. Everything here runs from the programme dir alone.
v_tick() {
  local prog_arg="${1:-}"; shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --observe) ORCHESTRATE_OBSERVE=1; shift ;;
      *) shift ;;
    esac
  done
  prog_open "$prog_arg"
  # Two ticks running together each rewrite lanes.jsonl, and the slower one
  # discards the faster one's updates. mkdir is the atomic test-and-set.
  if ! mkdir "$PROG/.tick.lock" 2>/dev/null; then
    refuse tick-running "a tick is already running for $PROGRAMME"
    return 3
  fi
  trap 'rmdir "$PROG/.tick.lock" 2>/dev/null' EXIT INT TERM
  owner_ensure || { rmdir "$PROG/.tick.lock" 2>/dev/null; return 3; }
  [ "$ORCHESTRATE_OBSERVE" = 1 ] && printf 'OBSERVE: classifying and measuring only, nothing will be sent, restarted or created\n'
  cfg_changed && printf 'CONFIG CHANGED: programme.yaml differs from the copy fingerprinted when the lock was claimed\n'

  # 1. watchdog: a gap past twice the cadence is the first thing reported.
  local last gap cad n
  last="$(jq -r 'select(.ev == "tick") | .t' "$EVENTS" 2>/dev/null | tail -1)"
  cad="$(cadence_s)"
  if [ -n "$last" ]; then gap=$(( $(epoch) - $(iso_epoch "$last") )); else gap=0; fi
  n="$(( $(jq -r 'select(.ev == "tick") | .n' "$EVENTS" 2>/dev/null | tail -1 | grep -Eo '^[0-9]+$' || echo 0) + 1 ))"
  local dupes; dupes="$(lanes | sort | uniq -d | tr '\n' ' ')"
  [ -n "$dupes" ] && printf 'DUPLICATE lane rows, the last one wins silently: %s\n' "$dupes"
  [ "$gap" -gt "$(( 2 * cad ))" ] && printf 'WATCHDOG: %ss since the last tick, cadence is %ss\n' "$gap" "$cad"

  # 2-4. read every indexed handle, classify, re-resolve what is stale, and
  # ask a full-context idle lane to compact.
  local lane env kind handle text st ctx thr
  local working=0 idle=0 asking=0 done_n=0 dead=0
  thr="$(cfg compact.at_pct 85)"
  printf 'lane\tenv\tagent\tstatus\tctx\tnote\n'
  while read -r lane; do
    [ -n "$lane" ] || continue
    env="$(lane_field "$lane" env)"; kind="$(lane_field "$lane" agent)"; handle="$(lane_field "$lane" handle)"
    local note=-
    text="$(orca_screen "$handle" "$env")"
    if [ -z "$text" ]; then
      local fresh; fresh="$(lane_reresolve "$lane")"
      if [ -n "$fresh" ] && [ "$fresh" != "$handle" ]; then
        lane_set "$lane" handle "$fresh"
        ev restart lane "$lane" action rehandle handle "$fresh"
        note=rehandled
        text="$(orca_screen "$fresh" "$env")"
      fi
    fi
    if [ -z "$text" ]; then
      st=dead
    else
      st="$(classify "$kind" "$text")"
    fi
    # `done` and `retired` are decisions, not screen states: a finished lane
    # sits at an idle prompt and must not be re-opened by a screen read.
    case "$(lane_field "$lane" status)" in
      done|retired) [ "$st" = "idle" ] || [ "$st" = unknown ] && st="$(lane_field "$lane" status)" ;;
    esac
    ctx="$(ctx_pct "$kind" "$text")"
    lane_set "$lane" status "$st"
    lane_set "$lane" ctx_pct "$ctx"
    lane_set "$lane" last_seen "$(now)"
    # Under observe the note says what a normal tick WOULD have done, which is
    # the whole point of reading one before acting.
    if [ "$st" = dead ]; then
      if [ "$ORCHESTRATE_OBSERVE" = 1 ]; then
        note="dead, would restart"
      else
        note="dead, restarting"
        lane_restart "$lane" >/dev/null 2>&1 && note="restarted"
      fi
    elif [ "$st" = "idle" ] && [ -n "$ctx" ] && [ "$ctx" -ge "$thr" ] 2>/dev/null; then
      if [ "$ORCHESTRATE_OBSERVE" = 1 ]; then
        note="would compact at ${ctx}%"
      else
        lane_send "$lane" - "$(agent_cfg "$kind" compact) $(cfg compact.keep 'keep the goal, the branch, the open PR and the last decision')" >/dev/null 2>&1
        note="compacted at ${ctx}%"
      fi
    fi
    case "$st" in
      working) working=$((working + 1)) ;;
      idle) idle=$((idle + 1)) ;;
      asking) asking=$((asking + 1)) ;;
      done) done_n=$((done_n + 1)) ;;
      *) dead=$((dead + 1)) ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$lane" "$env" "$kind" "$st" "${ctx:--}" "$note"
  done < <(lanes)

  local unknown_repo=0
  # 5. host pressure. Never delete under a live lane: report and let the agent
  # ask the owning lane to clean.
  local e free floor
  floor="$(cfg placement.floors.disk_free_gb 20)"
  while read -r e; do
    [ -n "$e" ] || continue
    free="$(host_disk "$e")"
    if [ -n "$free" ] && [ "$free" -lt "$floor" ] 2>/dev/null; then
      printf 'DISK: %s has %sG free, floor is %sG, ask its lanes to clean\n' "$e" "$free" "$floor"
    fi
  done < <(jq -r '.env' "$LANES" 2>/dev/null | sort -u)

  if [ "${GH_REPO_UNRESOLVED:-0}" = 1 ]; then
    printf 'DEGRADED: GH_REPO could not be resolved from programme.yaml, so every PR count is from whatever repository the caller is in\n'
    ev degraded reason "gh_repo unresolved" repo "$(cfg repo)"
    unknown_repo=1
  fi

  # 6. open PRs and owed notices. A counter that could not be read is unknown,
  # never zero: a network blip must not read as "nothing left to do".
  local open_prs owed_n unknown="${unknown_repo:-0}"
  open_prs="$(open_pr_count)" || { open_prs=""; unknown=1; }
  owed_n="$(owed_list | wc -l | tr -d ' ')"
  if owed_list | grep -q 'owed-unknown'; then unknown=1; fi
  [ "$owed_n" = 0 ] || v_owed_report
  if [ "$unknown" = 1 ]; then
    printf 'DEGRADED: a counter could not be read, so the exit condition is not evaluated this tick\n'
    ev degraded reason "counter unreadable" open_prs "${open_prs:-?}" owed "$owed_n"
  fi

  # 10. record the tick, then say whether the exit condition holds.
  ev_json tick "$(jq -nc --arg n "$n" --arg w "$working" --arg i "$idle" --arg a "$asking" \
    --arg d "$done_n" --arg x "$dead" --arg p "$open_prs" --arg o "$owed_n" --arg g "$gap" \
    --arg ob "$ORCHESTRATE_OBSERVE" \
    '{n: ($n | tonumber), lanes: {working: ($w | tonumber), idle: ($i | tonumber), asking: ($a | tonumber),
      done: ($d | tonumber), dead: ($x | tonumber)},
      open_prs: (if $p == "" then null else ($p | tonumber) end), owed: ($o | tonumber),
      gap_s: ($g | tonumber), observe: ($ob == "1")}')"
  owner_touch

  local verdict
  if [ "$unknown" = 1 ]; then
    verdict=undecidable
  else
    verdict="$(exit_eval "$(cfg exit)" "$open_prs" "$owed_n" "$done_n" "$(lanes | wc -l | tr -d ' ')")"
  fi
  printf '\ntick %s: working=%s idle=%s asking=%s done=%s dead=%s open_prs=%s owed=%s gap=%ss exit=%s\n' \
    "$n" "$working" "$idle" "$asking" "$done_n" "$dead" "${open_prs:-?}" "$owed_n" "$gap" "$verdict"
  rmdir "$PROG/.tick.lock" 2>/dev/null
  trap - EXIT INT TERM
  [ "$verdict" = true ] && return 10
  return 0
}

v_owed_report() {
  while IFS=$'\t' read -r lane pr st; do
    [ -n "$lane" ] && printf 'OWED: lane %s was never told #%s is %s\n' "$lane" "$pr" "$st"
  done < <(owed_list)
}

# ------------------------------------------------------------------- loop

# The driver for harnesses with no native scheduler. Claude Code arms /loop
# instead. STOP ends it, and so do max-ticks, max-hours and the exit condition.
v_loop() {
  local programme="${1:-}"; shift || true
  local every="" max_ticks=0 max_hours=0 use_tmux=0 agent_cmd="" tick_timeout="" observe=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --every) every="${2:-}"; shift 2 ;;
      --max-ticks) max_ticks="${2:-0}"; shift 2 ;;
      --max-hours) max_hours="${2:-0}"; shift 2 ;;
      --agent-cmd) agent_cmd="${2:-}"; shift 2 ;;
      --tick-timeout) tick_timeout="${2:-}"; shift 2 ;;
      --observe) observe=1; shift ;;
      --tmux) use_tmux=1; shift ;;
      *) shift ;;
    esac
  done
  prog_open "$programme"
  owner_require || return 3
  [ -n "$every" ] || every="$(cfg loop.every 20m)"
  [ "$max_ticks" != 0 ] || max_ticks="$(cfg loop.max_ticks 0)"
  [ "$max_hours" != 0 ] || max_hours="$(cfg loop.max_hours 0)"
  if [ -f "$STOP" ]; then
    printf 'STOP present at %s, refusing to arm; remove it to start\n' "$STOP"
    return 0
  fi

  if [ "$use_tmux" = 1 ]; then
    # One named session, never a bulk or server-level kill. Stop it with the
    # STOP file, or with kill-session on exactly this name.
    local session="orchestrate-$PROGRAMME"
    tmux has-session -t "$session" 2>/dev/null && die "tmux session $session already exists; stop it with: tmux kill-session -t $session" 1
    local -a inner=("$HERE/orchestrate.sh" loop "$PROGRAMME" --every "$every" \
      --max-ticks "$max_ticks" --max-hours "$max_hours" --tick-timeout "$tick_timeout")
    [ "$observe" = 1 ] && inner+=(--observe)
    [ -n "$agent_cmd" ] && inner+=(--agent-cmd "$agent_cmd")
    tmux new-session -d -s "$session" -n loop \
      -e "ORCHESTRATE_HOME=$ORCHESTRATE_HOME" -e "ORCHESTRATE_LOOP_LOG=$PROG/loop.log" \
      -e "ORCHESTRATE_SESSION=$ORCHESTRATE_SESSION" \
      "${inner[@]}"
    printf 'loop armed in tmux session %s; stop it with: touch %s\n' "$session" "$STOP"
    return 0
  fi

  local interval deadline i=0 rc
  [ -z "${ORCHESTRATE_LOOP_LOG:-}" ] || exec >> "$ORCHESTRATE_LOOP_LOG" 2>&1
  interval="$(dur_s "$every")"
  [ "${interval:-0}" -gt 0 ] 2>/dev/null || interval=60
  # A tick with no bound hangs the loop, and STOP is only read between ticks, so
  # a wedged tick makes the documented stop mechanism inert.
  [ -n "$tick_timeout" ] || tick_timeout="$(cfg loop.tick_timeout "$(( interval * 2 ))")"
  [ "${tick_timeout:-0}" -gt 0 ] 2>/dev/null || tick_timeout=$(( interval * 2 ))
  deadline=0
  [ "$max_hours" != 0 ] && deadline=$(( $(epoch) + max_hours * 3600 ))
  ev loop action start every "$every" max_ticks "$max_ticks" max_hours "$max_hours"
  while :; do
    if [ -f "$STOP" ]; then ev loop action stop reason stop-file; printf 'STOP file present, loop ends\n'; break; fi
    if [ "$max_ticks" != 0 ] && [ "$i" -ge "$max_ticks" ]; then ev loop action stop reason max-ticks; printf 'max-ticks reached\n'; break; fi
    if [ "$deadline" != 0 ] && [ "$(epoch)" -ge "$deadline" ]; then ev loop action stop reason max-hours; printf 'max-hours reached\n'; break; fi
    i=$((i + 1))
    if [ -n "$agent_cmd" ]; then
      # The judgment half runs in a headless agent, fed the tick prompt.
      ORCHESTRATE_PROGRAMME="$PROGRAMME" run_bounded "$tick_timeout" \
        bash -c "$agent_cmd < '$PLUGIN_ROOT/assets/tick-prompt.md'"
      rc=$?
    else
      if [ "$observe" = 1 ]; then
        run_bounded "$tick_timeout" "$HERE/orchestrate.sh" tick "$PROGRAMME" --observe
      else
        run_bounded "$tick_timeout" "$HERE/orchestrate.sh" tick "$PROGRAMME"
      fi
      rc=$?
    fi
    if [ "$rc" = 124 ]; then
      ev tick-timeout n "$i" after "$tick_timeout"
      printf 'tick %s exceeded %ss and was stopped; continuing\n' "$i" "$tick_timeout"
      rmdir "$PROG/.tick.lock" 2>/dev/null
    fi
    if [ "$rc" = 10 ]; then ev loop action stop reason exit-condition; printf 'exit condition holds, loop ends\n'; break; fi
    [ -f "$STOP" ] && continue
    # Wait in slices so STOP is honoured during the gap, not only between ticks.
    local slept=0
    while [ "$slept" -lt "$interval" ]; do
      [ -f "$STOP" ] && break
      sleep 1; slept=$((slept + 1))
    done
  done
}

# --------------------------------------------------------------- handover

# HANDOVER.md is generated from the index, never authored by hand: a brief that
# repeats a conversation is the thing that goes stale.
v_handover() {
  prog_open "${1:-}"
  local reason="${2:-requested}"
  {
    printf '# Handover: %s\n\n' "$PROGRAMME"
    printf 'Generated %s by %s on %s. Reason: %s.\n\n' "$(now)" "$ORCHESTRATE_SESSION" "$ORCHESTRATE_HARNESS" "$reason"
    printf 'Resume with: orchestrate:takeover %s\n\n' "$PROGRAMME"
    printf '## Lanes\n\n| lane | env | worktree | agent | status | ctx | last seen |\n|---|---|---|---|---|---|---|\n'
    jq -r '"| \(.lane) | \(.env) | \(.worktree) | \(.agent) | \(.status) | \(.ctx_pct // "-") | \(.last_seen // "-") |"' "$LANES" 2>/dev/null
    printf '\n## PRs seen, and who owns them\n\n'
    jq -r 'select(.ev == "pr") | "- #\(.pr): lane \(.lane)"' "$EVENTS" 2>/dev/null | sort -u
    printf '\n## Owed notices\n\n'
    if owed_list | grep -q .; then owed_list | awk -F'\t' '{ printf "- lane %s has not been told #%s is %s\n", $1, $2, $3 }'
    else printf 'none\n'; fi
    printf '\n## Reviews on disk\n\n'
    ls -1 "$REVIEWS" 2>/dev/null | sed 's#^#- reviews/#' | grep . || printf 'none\n'
    printf '\n## Decisions and steers, most recent last\n\n'
    jq -r 'select(.ev == "decision") | "- \(.t) \(.topic): \(.text) [\(.source // "-")]"' "$EVENTS" 2>/dev/null | tail -20 | grep . || printf 'none\n'
    printf '\n## Host pressure\n\n'
    tail -20 "$HOSTS" 2>/dev/null | jq -r '"- \(.host): \(.disk_free_gb // "?")G free via \(.src) at \(.t)"' | sort -u -k1,1 | grep . || printf 'none recorded\n'
    printf '\n## Next action\n\n'
    if owed_list | grep -q .; then printf 'Clear the owed notices above, then run one tick.\n'
    elif jq -e 'select(.ev == "tick")' "$EVENTS" >/dev/null 2>&1; then printf 'Run one tick and read the lanes marked asking.\n'
    else printf 'Run adopt to verify every handle, then one tick.\n'; fi
    printf '\n## House rules\n\n'
    printf 'Read ORCHESTRATION.md in this directory before answering any lane.\n'
  } > "$HANDOVER"
  ev handover outgoing "$(owner_session)" harness "$ORCHESTRATE_HARNESS" reason "$reason"
  # The token is spent. The next orchestrator claims through takeover, which is
  # recorded, rather than a tick silently picking the programme back up.
  date -u +%FT%TZ > "$PROG/.handed-over"
  rm -f "$OWNER"
  printf '%s\n' "$HANDOVER"
  printf 'lock released; any harness resumes with: orchestrate:takeover %s\n' "$PROGRAMME"
}

v_takeover() {
  local programme="${1:-}" force="${2:-}"
  prog_open "$programme"
  owner_takeover "$force" || return 3
  printf '\n== re-verifying every handle before any send\n'
  v_adopt "$programme" --dry-run | while IFS=$'\t' read -r a b c d e f g; do printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$a" "$b" "$c" "$d" "$f" "$g"; done
  # The first tick after a takeover observes. A lane misclassified from a stale
  # handle would otherwise have a resume command typed into a live session.
  printf '\n== one tick, observing only\n'
  v_tick "$programme" --observe
  local rc=$?
  printf '\nThat tick observed only. Read it, then run a tick that acts:\n'
  printf '  orchestrate.sh tick %s\n' "$programme"
  printf 'Then arm the loop for this harness: Claude Code uses /loop, anything else runs\n'
  printf '  orchestrate.sh loop %s --tmux\n' "$programme"
  return "$rc"
}

# ------------------------------------------------------------------ retire

# Only when merged, clean and idle. A worktree is never removed under a lane
# that still has work in it, and nothing here kills a process.
v_retire() {
  prog_open "${1:-}"
  owner_require || return 3
  local lane="${2:-}" env wt st branch dirty
  [ -n "$lane" ] || die "retire needs a lane" 2
  env="$(lane_field "$lane" env)"; wt="$(lane_field "$lane" worktree)"
  [ -n "$wt" ] || die "unknown lane $lane" 2
  st="$(lane_field "$lane" status)"
  case "$st" in
    done|idle) : ;;
    *) refuse retire-busy "lane $lane is $st, not idle"; return 3 ;;
  esac
  branch="$(lane_field "$lane" branch)"
  if [ -z "$branch" ]; then
    refuse retire-unknown-branch "lane $lane has no branch recorded, so nothing can say its work landed"
    return 3
  fi
  local open_n rc
  open_n="$(gh pr list --head "$branch" --base "$(cfg trunk)" --state open --json number --jq 'length' 2>/dev/null)"; rc=$?
  if [ "$rc" != 0 ] || ! printf '%s' "$open_n" | grep -Eq '^[0-9]+$'; then
    refuse retire-unknown-state "cannot read the PR state for $branch; not retiring on a guess"
    return 3
  fi
  [ "$open_n" = 0 ] || { refuse retire-unmerged "lane $lane still has $open_n open PRs on $branch"; return 3; }
  dirty="$(orca_screen "$(lane_field "$lane" handle)" "$env" | tail -3)"
  if [ -n "$dirty" ] && ! printf '%s\n' "$dirty" | grep -Eq -- "$(agent_cfg "$(lane_field "$lane" agent)" shell_prompt '\$ $')"; then
    if [ "$st" != "done" ]; then refuse retire-live "lane $lane still has a live agent screen"; return 3; fi
  fi
  orca_env_args "$env"
  orca_call worktree rm --worktree "name:$wt" "${ORCA_ENV_ARGS[@]}" --json >/dev/null 2>&1 \
    || { printf 'orca refused to remove %s\n' "$wt" >&2; return 1; }
  lane_set "$lane" status retired
  ev retire lane "$lane" worktree "$wt" env "$env"
  printf 'retired %s (%s)\n' "$lane" "$wt"
}

# -------------------------------------------------------------------- main

# --session <token> anywhere in the line is equivalent to the environment
# variable, for a harness that cannot set one.
ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session) ORCHESTRATE_SESSION="${2:-}"; export ORCHESTRATE_SESSION; shift 2 ;;
    --harness) ORCHESTRATE_HARNESS_SET="${2:-}"; export ORCHESTRATE_HARNESS_SET; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
[ "${#ARGS[@]}" -gt 0 ] && set -- "${ARGS[@]}"

verb="${1:-help}"; shift || true
case "$verb" in
  init) v_init "$@" ;;
  discover) v_discover "$@" ;;
  adopt) v_adopt "$@" ;;
  status) v_status "$@" ;;
  read) v_read "$@" ;;
  send) v_send "$@" ;;
  pr) v_pr "$@" ;;
  mark) v_mark "$@" ;;
  owed) v_owed "$@" ;;
  merge) v_merge "$@" ;;
  post) v_post "$@" ;;
  scrub) v_scrub "$@" ;;
  tick) v_tick "$@" ;;
  loop) v_loop "$@" ;;
  handover) v_handover "$@" ;;
  takeover) v_takeover "$@" ;;
  retire) v_retire "$@" ;;
  help|-h|--help) usage ;;
  *) usage; exit 2 ;;
esac
