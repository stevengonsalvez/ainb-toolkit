#!/usr/bin/env bash
# One entry point for every orchestrate verb. Transport is Orca only: there is
# no ssh path, no force-push path and no bulk-kill path anywhere in this plugin.
#
#   orchestrate.sh init      <programme> [--trunk B] [--never-merge-into B,B]
#   orchestrate.sh discover  [--environment E]...
#   orchestrate.sh adopt     <programme> [--dry-run] [--environment E]...
#   orchestrate.sh status    <programme>
#   orchestrate.sh read      <programme> <lane> [lines]
#   orchestrate.sh send      <programme> <lane> <pr|-> <text>
#   orchestrate.sh pr        <programme> <pr> <lane>
#   orchestrate.sh mark      <programme> <lane> <working|idle|asking|done|dead>
#   orchestrate.sh owed      <programme>
#   orchestrate.sh merge     <programme> <pr> [expected-sha]
#   orchestrate.sh post      <programme> <pr> <report.md>
#   orchestrate.sh scrub     <programme> <file.md> [out.md]
#   orchestrate.sh tick      <programme> [--once]
#   orchestrate.sh loop      <programme> [--every 20m] [--max-ticks N] [--max-hours N] [--tmux]
#   orchestrate.sh handover  <programme> [reason]
#   orchestrate.sh takeover  <programme> [--takeover]
#   orchestrate.sh retire    <programme> <lane>
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(dirname "$HERE")"
# shellcheck source=./lib.sh
. "$HERE/lib.sh"

usage() { sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ----------------------------------------------------------------- init

v_init() {
  local programme="${1:-}"; shift || true
  [ -n "$programme" ] || die "init needs a programme name" 2
  local dir="$ORCHESTRATE_HOME/$programme" trunk="" never=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --trunk) trunk="${2:-}"; shift 2 ;;
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
  printf '%s\n' "$dir"
  printf 'edit programme.yaml (autonomy must be set deliberately) and ORCHESTRATION.md, then run adopt\n'
}

# ----------------------------------------------------------------- discover

# Ask Orca, never ssh (lesson 2: an ssh probe raised a false outage). Liveness
# is never inferred from a terminal listing alone; adopt reads each handle.
v_discover() {
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
    wts="$(timeout "$ORCA_TIMEOUT" "$ORCA" worktree list "${ORCA_ENV_ARGS[@]}" --json 2>/dev/null)"
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
  local dry=0
  local -a envs=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      --environment) envs+=("${2:-}"); shift 2 ;;
      *) shift ;;
    esac
  done
  prog_open "$programme"
  [ "${#envs[@]}" -gt 0 ] || envs=(local)

  printf 'lane\tenv\tworktree\tagent\thandle\tstatus\tctx\n'
  local lane env wt handle kind text st ctx known
  while IFS=$'\t' read -r lane env wt handle kind; do
    [ -n "$lane" ] || continue
    text="$(orca_screen "$handle" "$env")"
    if [ -z "$text" ]; then
      known="$(lane_reresolve "$lane")"
      if [ -n "$known" ] && [ "$known" != "$handle" ]; then
        handle="$known"; text="$(orca_screen "$handle" "$env")"
      fi
    fi
    st="$(classify "$kind" "$text")"
    [ -n "$text" ] || st=dead
    case "$(lane_field "$lane" status)" in
      done|retired) [ "$st" = "idle" ] || [ "$st" = unknown ] && st="$(lane_field "$lane" status)" ;;
    esac
    ctx="$(ctx_pct "$kind" "$text")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$lane" "$env" "$wt" "$kind" "$handle" "$st" "${ctx:--}"
    [ "$dry" = 1 ] && continue
    lane_upsert "$(jq -nc --arg lane "$lane" --arg env "$env" --arg handle "$handle" --arg wt "$wt" \
      --arg agent "$kind" --arg st "$st" --arg ctx "$ctx" --arg t "$(now)" \
      '{lane: $lane, env: $env, handle: $handle, worktree: $wt, branch: "", agent: $agent, goal: "",
        exclusive: [], status: $st, ctx_pct: $ctx, last_seen: $t}')"
    ev adopt lane "$lane" env "$env" worktree "$wt" agent "$kind" status "$st"
  done < <(adopt_candidates "${envs[@]}")
}

# Candidates come from the existing index when there is one (adopt is also the
# re-verify pass), otherwise from discovery, one row per live terminal.
adopt_candidates() {
  local -a envs=("$@")
  if [ -s "$LANES" ]; then
    jq -r '[.lane, .env, .worktree, .handle, .agent] | @tsv' "$LANES"
    return 0
  fi
  local e n=0 id wt handle
  for e in "${envs[@]}"; do
    orca_env_args "$e"
    while read -r id; do
      [ -n "$id" ] || continue
      wt="${id##*/}"
      handle="$(timeout "$ORCA_TIMEOUT" "$ORCA" terminal list --worktree "id:$id" "${ORCA_ENV_ARGS[@]}" --json 2>/dev/null \
        | jq -r '.result.terminals[]? | .handle' | head -1)"
      [ -n "$handle" ] || continue
      n=$((n + 1))
      printf '%s\t%s\t%s\t%s\t%s\n' "L$n" "$e" "$wt" "$handle" "$(cfg default_agent claude)"
    done < <(timeout "$ORCA_TIMEOUT" "$ORCA" worktree list "${ORCA_ENV_ARGS[@]}" --json 2>/dev/null | jq -r '.result.worktrees[]?.id')
  done
}

# ----------------------------------------------------------------- status

v_status() {
  prog_open "${1:-}"
  printf '== lanes\n'
  jq -r '[.lane, .env, .worktree, .agent, .status, (.ctx_pct // "-"), (.last_seen // "-")] | @tsv' "$LANES" \
    | column -t -s"$(printf '\t')" 2>/dev/null || cat
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
  prog_open "${1:-}"
  lane_screen "${2:-}" | tail -"${3:-12}" | cut -c1-180
}

v_send() {
  prog_open "${1:-}"
  owner_require || return 3
  lane_send "${2:-}" "${3:--}" "${4:-}"
}

v_pr() {
  prog_open "${1:-}"
  ev pr pr "${2:-}" lane "${3:-}"
}

# `done` is a judgment, so the agent records it. Every other status comes off
# the screen at the next tick.
v_mark() {
  prog_open "${1:-}"
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
  prog_open "${1:-}"
  owner_require || return 3

  # 1. watchdog: a gap past twice the cadence is the first thing reported.
  local last gap cad n
  last="$(jq -r 'select(.ev == "tick") | .t' "$EVENTS" 2>/dev/null | tail -1)"
  cad="$(cadence_s)"
  if [ -n "$last" ]; then gap=$(( $(epoch) - $(iso_epoch "$last") )); else gap=0; fi
  n="$(( $(jq -r 'select(.ev == "tick") | .n' "$EVENTS" 2>/dev/null | tail -1 | grep -Eo '^[0-9]+$' || echo 0) + 1 ))"
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
    if [ "$st" = dead ]; then
      note="dead, restarting"
      lane_restart "$lane" >/dev/null 2>&1 && note="restarted"
    elif [ "$st" = "idle" ] && [ -n "$ctx" ] && [ "$ctx" -ge "$thr" ] 2>/dev/null; then
      lane_send "$lane" - "$(agent_cfg "$kind" compact) $(cfg compact.keep 'keep the goal, the branch, the open PR and the last decision')" >/dev/null 2>&1
      note="compacted at ${ctx}%"
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

  # 6. open PRs and owed notices.
  local open_prs owed_n
  open_prs="$(gh pr list --state open --json number --jq 'length' 2>/dev/null || echo 0)"
  owed_n="$(owed_list | wc -l | tr -d ' ')"
  [ "$owed_n" = 0 ] || v_owed_report

  # 10. record the tick, then say whether the exit condition holds.
  ev_json tick "$(jq -nc --arg n "$n" --arg w "$working" --arg i "$idle" --arg a "$asking" \
    --arg d "$done_n" --arg x "$dead" --arg p "$open_prs" --arg o "$owed_n" --arg g "$gap" \
    '{n: ($n | tonumber), lanes: {working: ($w | tonumber), idle: ($i | tonumber), asking: ($a | tonumber),
      done: ($d | tonumber), dead: ($x | tonumber)}, open_prs: ($p | tonumber), owed: ($o | tonumber),
      gap_s: ($g | tonumber)}')"
  owner_touch

  local verdict
  verdict="$(exit_eval "$(cfg exit)" "$open_prs" "$owed_n" "$done_n" "$(lanes | wc -l | tr -d ' ')")"
  printf '\ntick %s: working=%s idle=%s asking=%s done=%s dead=%s open_prs=%s owed=%s gap=%ss exit=%s\n' \
    "$n" "$working" "$idle" "$asking" "$done_n" "$dead" "$open_prs" "$owed_n" "$gap" "$verdict"
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
  local every="" max_ticks=0 max_hours=0 use_tmux=0 agent_cmd=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --every) every="${2:-}"; shift 2 ;;
      --max-ticks) max_ticks="${2:-0}"; shift 2 ;;
      --max-hours) max_hours="${2:-0}"; shift 2 ;;
      --agent-cmd) agent_cmd="${2:-}"; shift 2 ;;
      --tmux) use_tmux=1; shift ;;
      *) shift ;;
    esac
  done
  prog_open "$programme"
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
    ORCHESTRATE_AGENT_CMD="$agent_cmd" tmux new-session -d -s "$session" -n loop -e "ORCHESTRATE_HOME=$ORCHESTRATE_HOME" \
      "'$HERE/orchestrate.sh' loop '$PROGRAMME' --every '$every' --max-ticks '$max_ticks' --max-hours '$max_hours' 2>&1 | tee '$PROG/loop.log'"
    printf 'loop armed in tmux session %s; stop it with: touch %s\n' "$session" "$STOP"
    return 0
  fi

  local interval deadline i=0 rc
  [ -n "$agent_cmd" ] || agent_cmd="${ORCHESTRATE_AGENT_CMD:-}"
  interval="$(dur_s "$every")"
  [ "${interval:-0}" -gt 0 ] 2>/dev/null || interval=60
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
      ORCHESTRATE_PROGRAMME="$PROGRAMME" bash -c "$agent_cmd" < "$PLUGIN_ROOT/assets/tick-prompt.md"
      rc=$?
    else
      v_tick "$PROGRAMME"
      rc=$?
    fi
    if [ "$rc" = 10 ]; then ev loop action stop reason exit-condition; printf 'exit condition holds, loop ends\n'; break; fi
    [ -f "$STOP" ] && continue
    sleep "$interval"
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
  ev handover outgoing "$ORCHESTRATE_SESSION" harness "$ORCHESTRATE_HARNESS" reason "$reason"
  rm -f "$OWNER"
  printf '%s\n' "$HANDOVER"
  printf 'lock released; any harness resumes with: orchestrate:takeover %s\n' "$PROGRAMME"
}

v_takeover() {
  local programme="${1:-}" force="${2:-}"
  prog_open "$programme"
  owner_claim "$force" || return 3
  printf '\n== re-verifying every handle before any send\n'
  v_adopt "$programme" --dry-run | while IFS=$'\t' read -r a b c d e f g; do printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$a" "$b" "$c" "$d" "$f" "$g"; done
  printf '\n== one tick\n'
  v_tick "$programme"
  local rc=$?
  printf '\nNow arm the loop for this harness: Claude Code uses /loop, anything else runs\n'
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
  if [ -n "$branch" ]; then
    local open_n
    open_n="$(gh pr list --head "$branch" --state open --json number --jq 'length' 2>/dev/null || echo 0)"
    [ "${open_n:-0}" = 0 ] || { refuse retire-unmerged "lane $lane still has $open_n open PRs on $branch"; return 3; }
  fi
  dirty="$(orca_screen "$(lane_field "$lane" handle)" "$env" | tail -3)"
  if [ -n "$dirty" ] && ! printf '%s\n' "$dirty" | grep -Eq -- "$(agent_cfg "$(lane_field "$lane" agent)" shell_prompt '\$ $')"; then
    if [ "$st" != "done" ]; then refuse retire-live "lane $lane still has a live agent screen"; return 3; fi
  fi
  orca_env_args "$env"
  timeout "$ORCA_TIMEOUT" "$ORCA" worktree rm --worktree "name:$wt" "${ORCA_ENV_ARGS[@]}" --json >/dev/null 2>&1 \
    || { printf 'orca refused to remove %s\n' "$wt" >&2; return 1; }
  lane_set "$lane" status retired
  ev retire lane "$lane" worktree "$wt" env "$env"
  printf 'retired %s (%s)\n' "$lane" "$wt"
}

# -------------------------------------------------------------------- main

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
