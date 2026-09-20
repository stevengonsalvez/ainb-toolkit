#!/usr/bin/env bash
# Shared library for every orchestrate verb. Source it, never execute it.
# Runs under bash even when the caller's shell is zsh: every argument is read
# explicitly and no value is ever left to word splitting.
set -uo pipefail

ORCA="${ORCA_BIN:-orca-ide}"
ORCHESTRATE_HOME="${ORCHESTRATE_HOME:-$HOME/.claude/orchestrator}"
ORCHESTRATE_SESSION="${ORCHESTRATE_SESSION:-$$@$(uname -n 2>/dev/null || echo host)}"
ORCHESTRATE_HARNESS="${ORCHESTRATE_HARNESS:-unknown}"
ORCA_TIMEOUT="${ORCA_TIMEOUT:-25}"

now() { date -u +%FT%TZ; }
epoch() { date -u +%s; }

# Seconds since an ISO-8601 UTC stamp. Works on GNU date and on BSD date.
iso_epoch() {
  local s="$1" out
  out="$(date -u -d "$s" +%s 2>/dev/null)" && { printf '%s' "$out"; return 0; }
  out="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$s" +%s 2>/dev/null)" && { printf '%s' "$out"; return 0; }
  printf '0'
}

# "20m", "2h", "90s", "600" all become seconds.
dur_s() {
  local v="${1:-}" n u
  [ -n "$v" ] || { printf '0'; return 0; }
  n="${v%[smhSMH]}"; u="${v#"$n"}"
  case "$u" in
    s|S|'') printf '%s' "$n" ;;
    m|M) printf '%s' "$(( n * 60 ))" ;;
    h|H) printf '%s' "$(( n * 3600 ))" ;;
    *) printf '0' ;;
  esac
}

die() { printf 'orchestrate: %s\n' "$1" >&2; exit "${2:-1}"; }

# ---------------------------------------------------------------- programme dir

# shellcheck disable=SC2034  # these are read by the verb scripts that source this file
prog_open() {
  PROGRAMME="${1:-${ORCHESTRATE_PROGRAMME:-}}"
  [ -n "$PROGRAMME" ] || die "no programme named (pass one, or set ORCHESTRATE_PROGRAMME)" 2
  PROG="$ORCHESTRATE_HOME/$PROGRAMME"
  CFG="$PROG/programme.yaml"
  RULES="$PROG/ORCHESTRATION.md"
  AGENTS="$PROG/agents.yaml"
  LANES="$PROG/lanes.jsonl"
  HOSTS="$PROG/hosts.jsonl"
  EVENTS="$PROG/events.jsonl"
  OWNER="$PROG/owner.json"
  STOP="$PROG/STOP"
  HANDOVER="$PROG/HANDOVER.md"
  REVIEWS="$PROG/reviews"
  CFG_FLAT=""
  AGENTS_FLAT=""
  [ -d "$PROG" ] || die "no programme dir at $PROG (run: orchestrate.sh init $PROGRAMME)" 2
  touch "$LANES" "$EVENTS" "$HOSTS"
  mkdir -p "$REVIEWS"
}

# ----------------------------------------------------------------- tiny yaml

# Flatten a small YAML file to "dotted.key<TAB>value" lines. Understands nested
# blocks, inline maps and inline lists, which is every shape programme.yaml and
# agents.yaml use. List blocks ("- ...") are skipped: they carry review classes,
# which the agent reads as text, not the scripts.
yaml_flat() {
  [ -f "$1" ] || return 0
  awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function unq(s,   q) {
      s = trim(s)
      if (length(s) < 2) return s
      q = substr(s, 1, 1)
      if ((q == "\"" || q == "'"'"'") && substr(s, length(s), 1) == q) return substr(s, 2, length(s) - 2)
      return s
    }
    function delist(s) { s = substr(s, 2, length(s) - 2); gsub(/,/, " ", s); gsub(/["'"'"']/, "", s); gsub(/[ ]+/, " ", s); return trim(s) }
    function strip_comment(s,   i, c, inq, out) {
      inq = 0; out = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\"") inq = !inq
        if (!inq && c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t]/)) break
        out = out c
      }
      return out
    }
    function emitpair(path, kv,   p, k, v) {
      p = index(kv, ":")
      if (p == 0) return
      k = unq(substr(kv, 1, p - 1)); v = trim(substr(kv, p + 1))
      if (k == "") return
      if (substr(v, 1, 1) == "[") v = delist(v); else v = unq(v)
      print path "." k "\t" v
    }
    function emitinline(path, s,   i, c, depth, inq, buf) {
      s = substr(s, 2, length(s) - 2)
      depth = 0; inq = 0; buf = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\"") inq = !inq
        if (!inq && (c == "[" || c == "{")) depth++
        if (!inq && (c == "]" || c == "}")) depth--
        if (!inq && depth == 0 && c == ",") { emitpair(path, buf); buf = ""; continue }
        buf = buf c
      }
      if (trim(buf) != "") emitpair(path, buf)
    }
    {
      line = strip_comment($0)
      if (trim(line) == "") next
      if (line ~ /^[ \t]*-[ \t]/) next
      match(line, /^[ ]*/); ind = RLENGTH
      if (match(line, /^[ ]*[A-Za-z0-9_.-]+:/) == 0) next
      p = index(line, ":")
      key = trim(substr(line, 1, p - 1))
      rest = trim(substr(line, p + 1))
      while (top > 0 && lev[top] >= ind) top--
      path = ""
      for (i = 1; i <= top; i++) path = (path == "" ? keys[i] : path "." keys[i])
      path = (path == "" ? key : path "." key)
      if (rest == "") { top++; lev[top] = ind; keys[top] = key; next }
      if (substr(rest, 1, 1) == "{") { emitinline(path, rest); next }
      if (substr(rest, 1, 1) == "[") { print path "\t" delist(rest); next }
      print path "\t" unq(rest)
    }
  ' "$1"
}

# cfg <dotted.key> [default] : read programme.yaml
cfg() {
  [ -n "$CFG_FLAT" ] || CFG_FLAT="$(yaml_flat "$CFG")"
  local v
  v="$(printf '%s\n' "$CFG_FLAT" | awk -F'\t' -v k="$1" '$1 == k { print $2; exit }')"
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "${2:-}"
}

# agent_cfg <kind> <field> [default] : read agents.yaml, falling back to the
# "default" profile so an unknown agent kind still has a resume command.
agent_cfg() {
  [ -n "$AGENTS_FLAT" ] || AGENTS_FLAT="$(yaml_flat "$AGENTS")"
  local kind="${1:-default}" field="$2" v
  kind="${kind%% *}"
  v="$(printf '%s\n' "$AGENTS_FLAT" | awk -F'\t' -v k="$kind.$field" '$1 == k { print $2; exit }')"
  [ -n "$v" ] || v="$(printf '%s\n' "$AGENTS_FLAT" | awk -F'\t' -v k="default.$field" '$1 == k { print $2; exit }')"
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "${3:-}"
}

cadence_s() { dur_s "$(cfg loop.every 20m)"; }

# ------------------------------------------------------------------- events

# ev <name> [key value]... : append one event, every value a string.
ev() {
  local name="$1"; shift
  local filter='{t: $t, ev: $ev}'
  local args=(-nc --arg t "$(now)" --arg ev "$name")
  local i=0 k
  while [ "$#" -ge 2 ]; do
    i=$((i + 1)); k="v$i"
    args+=(--arg "$k" "$2")
    filter="$filter + {\"$1\": \$$k}"
    shift 2
  done
  jq "${args[@]}" "$filter" >> "$EVENTS"
}

# ev_json <name> <json-object> : append an event with nested fields.
ev_json() {
  jq -nc --arg t "$(now)" --arg ev "$1" --argjson body "$2" '{t: $t, ev: $ev} + $body' >> "$EVENTS"
}

# Every hard refusal lands in events.jsonl. Exit code 3 means "refused", which
# is distinct from 1 (error) so a caller can tell them apart.
refuse() {
  ev refuse what "$1" detail "$2"
  printf 'REFUSED %s: %s\n' "$1" "$2" >&2
  return 3
}

# --------------------------------------------------------------------- lanes

lane_field() {
  jq -r --arg l "$1" --arg f "$2" 'select(.lane == $l) | .[$f] // ""' "$LANES" 2>/dev/null | tail -1
}

lane_set() {
  local lane="$1" field="$2" value="$3" tmp
  tmp="$(mktemp)" || return 1
  jq -c --arg l "$lane" --arg f "$field" --arg v "$value" \
    'if .lane == $l then .[$f] = $v else . end' "$LANES" > "$tmp" && mv "$tmp" "$LANES"
}

lane_upsert() {
  local row="$1" lane tmp
  lane="$(printf '%s' "$row" | jq -r .lane)"
  tmp="$(mktemp)" || return 1
  { jq -c --arg l "$lane" 'select(.lane != $l)' "$LANES" 2>/dev/null; printf '%s\n' "$row"; } > "$tmp" && mv "$tmp" "$LANES"
}

lanes() { jq -r '.lane' "$LANES" 2>/dev/null; }

# Orca takes --environment only for remote runtimes. Fill an array, never a
# string: a zsh caller would not word split it and a bash caller would split it
# in the wrong places.
orca_env_args() {
  ORCA_ENV_ARGS=()
  local e="${1:-local}"
  [ "$e" = local ] || [ -z "$e" ] || ORCA_ENV_ARGS=(--environment "$e")
}

# Screen tail of a terminal handle. Screen mode is what a Mac-hosted TUI needs:
# the scrollback read returns nothing there while the lane is alive.
orca_screen() {
  local handle="$1" env="${2:-local}"
  [ -n "$handle" ] || return 1
  orca_env_args "$env"
  timeout "$ORCA_TIMEOUT" "$ORCA" terminal read --terminal "$handle" "${ORCA_ENV_ARGS[@]}" --screen --json 2>/dev/null \
    | jq -r '.result.terminal.tail[]?' | grep -v '^[[:space:]]*$'
}

lane_screen() {
  local lane="$1"
  orca_screen "$(lane_field "$lane" handle)" "$(lane_field "$lane" env)"
}

# Re-resolve a lane's handle from its worktree. Lesson 3: a host restart leaves
# the indexed handle stale and every send then lands nowhere.
lane_reresolve() {
  local lane="$1" wt env sel handle
  wt="$(lane_field "$lane" worktree)"; env="$(lane_field "$lane" env)"
  [ -n "$wt" ] || return 1
  orca_env_args "$env"
  sel="$(timeout "$ORCA_TIMEOUT" "$ORCA" worktree list "${ORCA_ENV_ARGS[@]}" --json 2>/dev/null \
    | jq -r --arg w "$wt" '.result.worktrees[]? | select((.id | endswith("/" + $w)) or (.name // "") == $w) | .id' | head -1)"
  if [ -n "$sel" ]; then sel="id:$sel"; else sel="name:$wt"; fi
  handle="$(timeout "$ORCA_TIMEOUT" "$ORCA" terminal list --worktree "$sel" "${ORCA_ENV_ARGS[@]}" --json 2>/dev/null \
    | jq -r '.result.terminals[]? | .handle' | head -1)"
  [ -n "$handle" ] || return 1
  printf '%s' "$handle"
}

# ---------------------------------------------------------------- classify

# A lane's state comes from its own screen, matched against patterns that live
# in agents.yaml so a TUI change is a config edit, not a code edit.
classify() {
  local kind="$1" text="$2" pat
  pat="$(agent_cfg "$kind" shell_prompt)"
  if [ -n "$pat" ] && printf '%s\n' "$text" | tail -3 | grep -Eq -- "$pat"; then printf 'dead'; return 0; fi
  pat="$(agent_cfg "$kind" asking)"
  if [ -n "$pat" ] && printf '%s\n' "$text" | tail -25 | grep -Eq -- "$pat"; then printf 'asking'; return 0; fi
  pat="$(agent_cfg "$kind" busy)"
  if [ -n "$pat" ] && printf '%s\n' "$text" | tail -25 | grep -Eq -- "$pat"; then printf 'working'; return 0; fi
  pat="$(agent_cfg "$kind" idle)"
  if [ -n "$pat" ] && printf '%s\n' "$text" | tail -25 | grep -Eq -- "$pat"; then printf 'idle'; return 0; fi
  printf 'unknown'
}

# Percentage of context USED, read off the status line. A profile whose readout
# reports context LEFT is inverted here, so every caller compares the same way.
ctx_pct() {
  local kind="$1" text="$2" pat v
  pat="$(agent_cfg "$kind" ctx)"
  [ -n "$pat" ] || { printf ''; return 0; }
  v="$(printf '%s\n' "$text" | grep -Eo -- "$pat" | tail -1 | grep -Eo '[0-9]+' | tail -1)"
  [ -n "$v" ] || { printf ''; return 0; }
  [ "$(agent_cfg "$kind" ctx_means used)" = left ] && v=$(( 100 - v ))
  printf '%s' "$v"
}

# ----------------------------------------------------------------- send path

# One recorded path for every message. Refuses to type into a shell prompt,
# confirms delivery on the screen, and records delivered, unconfirmed or
# dead-shell either way.
lane_send() {
  local lane="$1" pr="$2" text="$3" retry="${4:-retry}"
  local handle env res probe
  handle="$(lane_field "$lane" handle)"
  [ -n "$handle" ] || { printf 'unknown lane %s\n' "$lane" >&2; return 2; }
  env="$(lane_field "$lane" env)"

  if printf '%s\n' "$(orca_screen "$handle" "$env")" | tail -3 \
     | grep -Eq -- "$(agent_cfg "$(lane_field "$lane" agent)" shell_prompt '\$ $')"; then
    ev notified lane "$lane" pr "$pr" result dead-shell msg "$(printf '%s' "$text" | cut -c1-160)"
    printf 'dead-shell -> %s\n' "$lane"
    [ "$retry" = retry ] || return 4
    lane_restart "$lane" || return 4
    lane_send "$lane" "$pr" "$text" noretry
    return $?
  fi

  orca_env_args "$env"
  timeout "$ORCA_TIMEOUT" "$ORCA" terminal send --terminal "$handle" "${ORCA_ENV_ARGS[@]}" \
    --text "$text" --enter --json >/dev/null 2>&1
  sleep "${SEND_SETTLE_S:-3}"
  probe="$(printf '%s' "$text" | cut -c1-40)"
  if printf '%s\n' "$(orca_screen "$handle" "$env")" | tail -60 | grep -qF -- "$probe"; then res=delivered; else res=unconfirmed; fi
  ev notified lane "$lane" pr "$pr" result "$res" msg "$(printf '%s' "$text" | cut -c1-160)"
  printf '%s -> %s\n' "$res" "$lane"
  [ "$res" = delivered ]
}

# Restart a lane in place: re-resolve the handle first, then send the agent
# kind's resume command. Never kills anything.
lane_restart() {
  local lane="$1" handle env kind resume
  env="$(lane_field "$lane" env)"; kind="$(lane_field "$lane" agent)"
  handle="$(lane_reresolve "$lane")"
  if [ -n "$handle" ] && [ "$handle" != "$(lane_field "$lane" handle)" ]; then
    lane_set "$lane" handle "$handle"
    ev restart lane "$lane" action rehandle handle "$handle"
  fi
  resume="$(agent_cfg "$kind" resume)"
  [ -n "$resume" ] || return 1
  orca_env_args "$env"
  timeout "$ORCA_TIMEOUT" "$ORCA" terminal send --terminal "$(lane_field "$lane" handle)" \
    "${ORCA_ENV_ARGS[@]}" --text "$resume" --enter --json >/dev/null 2>&1
  ev restart lane "$lane" action resume cmd "$resume"
  sleep "${RESUME_SETTLE_S:-5}"
}

# ------------------------------------------------------------------- owner

owner_session() { [ -s "$OWNER" ] && jq -r '.session // ""' "$OWNER" || printf ''; }

owner_age_s() {
  [ -s "$OWNER" ] || { printf '999999'; return 0; }
  local last
  last="$(jq -r '.last_tick // .t // ""' "$OWNER")"
  [ -n "$last" ] || { printf '999999'; return 0; }
  printf '%s' "$(( $(epoch) - $(iso_epoch "$last") ))"
}

owner_write() {
  jq -nc --arg s "$ORCHESTRATE_SESSION" --arg h "$(uname -n 2>/dev/null || echo host)" \
    --arg a "$ORCHESTRATE_HARNESS" --arg t "$(now)" \
    '{session: $s, host: $h, harness: $a, t: $t, last_tick: $t}' > "$OWNER"
}

owner_touch() {
  [ -s "$OWNER" ] || return 0
  local tmp; tmp="$(mktemp)" || return 1
  jq --arg t "$(now)" '.last_tick = $t' "$OWNER" > "$tmp" && mv "$tmp" "$OWNER"
}

# One owner at a time (D13). A second orchestrator is refused unless the lock is
# stale past twice the cadence, or it asks for a takeover outright.
owner_claim() {
  local force="${1:-}" held age
  held="$(owner_session)"
  age="$(owner_age_s)"
  if [ -n "$held" ] && [ "$held" != "$ORCHESTRATE_SESSION" ]; then
    if [ "$force" != "--takeover" ] && [ "$age" -le "$(( 2 * $(cadence_s) ))" ]; then
      refuse owner-held "$held owns this programme, last tick ${age}s ago"
      return 3
    fi
    ev takeover outgoing "$held" incoming "$ORCHESTRATE_SESSION" harness "$ORCHESTRATE_HARNESS" \
      reason "$([ "$force" = --takeover ] && echo requested || echo "stale ${age}s")"
  fi
  owner_write
  printf 'owner %s\n' "$ORCHESTRATE_SESSION"
}

owner_require() {
  local held; held="$(owner_session)"
  if [ -z "$held" ] || [ "$held" = "$ORCHESTRATE_SESSION" ]; then return 0; fi
  refuse owner-held "$held owns this programme"
  return 3
}

# ---------------------------------------------------------------- scrubber

# Every outward post goes through here. Host paths are stripped, attribution
# words and U+2014 are refused outright: nothing is posted after a hit.
scrub() {
  local in="$1" out="${2:-${1%.md}-clean.md}" deny hits
  [ -f "$in" ] || { printf 'no such file: %s\n' "$in" >&2; return 1; }
  sed -E \
    -e 's#/(home|Users)/[A-Za-z0-9._-]+/#~/#g' \
    -e 's#/tmp/[A-Za-z0-9._-]+/[A-Za-z0-9._/-]*/scratchpad/##g' \
    -e 's#/(var|opt|srv)/[A-Za-z0-9._/-]*/(worktrees|workspaces)/##g' \
    "$in" > "$out"
  deny="$(cfg scrub.deny "$(cfg attribution_patterns 'co-authored-by|generated with|assisted by')")"
  hits="$(grep -Eic -- "$deny" "$out")"
  if [ "${hits:-0}" != 0 ]; then
    grep -Ein -- "$deny" "$out" | head -5 >&2
    refuse scrub-vendor "$hits vendor or attribution hits in $out"
    return 3
  fi
  if grep -q $'\xe2\x80\x94' "$out"; then
    refuse scrub-emdash "U+2014 present in $out"
    return 3
  fi
  printf '%s\n' "$out"
}

# --------------------------------------------------------------- merge gate

# Walls that config cannot lift: the base must be the declared trunk, must not
# be a never_merge_into branch, and no commit may be unsigned or attributed.
# There is no force-push path anywhere in this plugin.
merge_gate() {
  local pr="$1" want_sha="${2:-}" trunk base head branch never unsigned attributed pat repo
  trunk="$(cfg trunk)"
  [ -n "$trunk" ] || { printf 'programme.yaml has no trunk\n' >&2; return 1; }
  # The gate runs from the programme dir, so the checkout it gates is named in
  # programme.yaml rather than inferred from the caller's cwd.
  repo="$(cfg repo .)"
  [ -d "$repo/.git" ] || [ -d "$repo" ] || { printf 'programme.yaml repo is not a checkout: %s\n' "$repo" >&2; return 1; }
  local gh_repo; gh_repo="$(cfg gh_repo)"
  [ -n "$gh_repo" ] && export GH_REPO="$gh_repo"

  local view
  view="$(gh pr view "$pr" --json baseRefName,headRefName,headRefOid,state 2>/dev/null)"
  [ -n "$view" ] || { printf 'cannot read PR #%s\n' "$pr" >&2; return 1; }
  base="$(printf '%s' "$view" | jq -r .baseRefName)"
  branch="$(printf '%s' "$view" | jq -r .headRefName)"
  head="$(printf '%s' "$view" | jq -r .headRefOid)"

  never="$(cfg never_merge_into)"
  local -a never_list=()
  read -r -a never_list <<< "$never"
  local b
  for b in "${never_list[@]:-}"; do
    [ -n "$b" ] || continue
    [ "$base" = "$b" ] && { refuse merge-never-base "#$pr targets $base, which is on never_merge_into"; return 3; }
  done
  [ "$base" = "$trunk" ] || { refuse merge-wrong-base "#$pr targets $base, trunk is $trunk"; return 3; }
  if [ -n "$want_sha" ] && [ "$want_sha" != "-" ] && [ "${head#"$want_sha"}" = "$head" ]; then
    refuse merge-head-moved "#$pr head is $head, the verdict was on $want_sha"
    return 3
  fi

  git -C "$repo" fetch -q origin "$branch" "$trunk" 2>/dev/null
  if ! git -C "$repo" merge-tree --write-tree "origin/$trunk" "origin/$branch" >/dev/null 2>&1; then
    refuse merge-conflict "#$pr does not merge cleanly into $trunk"
    return 3
  fi
  if [ "$(cfg signing.required true)" = true ]; then
    unsigned="$(git -C "$repo" log --format='%G?' "origin/$trunk..origin/$branch" 2>/dev/null | grep -vc '^[GU]$')"
    [ "${unsigned:-0}" = 0 ] || { refuse merge-unsigned "#$pr has $unsigned unsigned commits"; return 3; }
  fi
  if [ "$(cfg attribution_guard true)" = true ]; then
    pat="$(cfg attribution_patterns 'co-authored-by|generated with|assisted by')"
    attributed="$(git -C "$repo" log --format='%B' "origin/$trunk..origin/$branch" 2>/dev/null | grep -Eic -- "$pat")"
    [ "${attributed:-0}" = 0 ] || { refuse merge-attributed "#$pr has $attributed attribution lines"; return 3; }
  fi

  if [ "$(cfg autonomy merge_on_verdict)" != merge_on_verdict ]; then
    printf 'ASK: #%s passes the gate, autonomy is %s, so ask before merging\n' "$pr" "$(cfg autonomy)"
    ev decision topic "merge #$pr" text "gate passed, autonomy requires asking" source gate
    return 4
  fi
  gh pr ready "$pr" >/dev/null 2>&1
  if gh pr merge "$pr" --merge >/dev/null 2>&1; then
    ev merged pr "$pr" branch "$branch" base "$trunk" sha "$head"
    printf '#%s merged into %s\n' "$pr" "$trunk"
    return 0
  fi
  printf '#%s merge call failed\n' "$pr" >&2
  return 1
}

# ------------------------------------------------------------------- owed

# Lesson 1: a lane sat hours awaiting a verdict on a PR that was already merged.
# Every PR whose lane has no delivered notice is owed one.
owed_list() {
  local pr lane st
  jq -r 'select(.ev == "pr") | "\(.pr) \(.lane)"' "$EVENTS" 2>/dev/null | sort -u | while read -r pr lane; do
    [ -n "$pr" ] || continue
    jq -e --arg pr "$pr" 'select(.ev == "notified" and .pr == $pr and .result == "delivered")' "$EVENTS" >/dev/null 2>&1 && continue
    st="$(gh pr view "$pr" --json state --jq .state 2>/dev/null)"
    case "$st" in
      MERGED|CLOSED) printf '%s\t%s\t%s\n' "$lane" "$pr" "$st" ;;
    esac
  done
}

# ------------------------------------------------------------------ hosts

# Host metrics, cut 1 rung: an Orca probe terminal running df on the host.
# The Beszel rung is cut 2; hosts.jsonl records which rung answered.
host_disk() {
  local env="${1:-local}" wt th out free
  if [ "$env" = local ]; then
    free="$(df -P / 2>/dev/null | awk 'NR == 2 { printf "%.0f", $4 / 1048576 }')"
    [ -n "$free" ] && { host_record "$env" probe "$free"; printf '%s' "$free"; return 0; }
    host_record "$env" unknown ""; return 1
  fi
  wt="$(jq -r --arg e "$env" 'select(.env == $e) | .worktree' "$LANES" 2>/dev/null | head -1)"
  [ -n "$wt" ] || { host_record "$env" unknown ""; return 1; }
  orca_env_args "$env"
  th="$(timeout "$ORCA_TIMEOUT" "$ORCA" terminal create --worktree "name:$wt" "${ORCA_ENV_ARGS[@]}" \
    --title orchestrate-probe --command 'df -P / | tail -1' --json 2>/dev/null | jq -r '.result.terminal.handle // empty')"
  [ -n "$th" ] || { host_record "$env" unknown ""; return 1; }
  timeout "$ORCA_TIMEOUT" "$ORCA" terminal wait --terminal "$th" "${ORCA_ENV_ARGS[@]}" --for exit --timeout-ms 15000 --json >/dev/null 2>&1
  out="$(orca_screen "$th" "$env")"
  timeout "$ORCA_TIMEOUT" "$ORCA" terminal close --terminal "$th" "${ORCA_ENV_ARGS[@]}" --json >/dev/null 2>&1
  free="$(printf '%s\n' "$out" | awk '/^\// { printf "%.0f", $4 / 1048576; exit }')"
  [ -n "$free" ] || { host_record "$env" unknown ""; return 1; }
  host_record "$env" probe "$free"
  printf '%s' "$free"
}

host_record() {
  local env="$1" src="$2" free="$3" lanes
  lanes="$(jq -r --arg e "$env" 'select(.env == $e) | .lane' "$LANES" 2>/dev/null | wc -l | tr -d ' ')"
  jq -nc --arg host "$env" --arg env "$env" --arg src "$src" --arg d "$free" --arg l "$lanes" --arg t "$(now)" \
    '{host: $host, env: $env, src: $src, disk_free_gb: (if $d == "" then null else ($d | tonumber) end), lanes: ($l | tonumber), t: $t}' >> "$HOSTS"
}

# --------------------------------------------------------------- exit expr

# Evaluate a small exit expression over known counters. Anything it does not
# recognise makes the expression undecidable, never silently true.
exit_eval() {
  local expr="$1" open_prs="$2" owed="$3" lanes_done="$4" lanes_total="$5" scope_done
  [ -n "$expr" ] || { printf 'unset'; return 1; }
  scope_done=0; [ -f "$PROG/SCOPE_DONE" ] && scope_done=1
  local e="$expr"
  e="${e//open_prs/$open_prs}"
  e="${e//owed/$owed}"
  e="${e//lanes_done/$lanes_done}"
  e="${e//lanes_total/$lanes_total}"
  e="${e//scope_done/$scope_done}"
  if printf '%s' "$e" | grep -Eqv '^[0-9 ()&|!=<>+-]*$'; then
    printf 'undecidable'
    return 1
  fi
  if (( e )) 2>/dev/null; then printf 'true'; return 0; fi
  printf 'false'; return 1
}
