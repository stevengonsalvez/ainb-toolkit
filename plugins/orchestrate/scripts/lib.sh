#!/usr/bin/env bash
# Shared library for every orchestrate verb. Source it, never execute it.
# Runs under bash even when the caller's shell is zsh: every argument is read
# explicitly and no value is ever left to word splitting.
set -uo pipefail

ORCA="${ORCA_BIN:-orca-ide}"
ORCHESTRATE_HOME="${ORCHESTRATE_HOME:-$HOME/.claude/orchestrator}"
# Set at prog_open from, in order: an explicit ORCHESTRATE_SESSION, the identity
# persisted when this programme's lock was claimed, or a fresh one. It must NOT
# be per process: the orchestrator runs one verb per invocation, and a per-pid
# identity means a takeover refuses its own next tick.
ORCHESTRATE_SESSION="${ORCHESTRATE_SESSION:-}"
ORCHESTRATE_HARNESS="${ORCHESTRATE_HARNESS:-unknown}"
ORCA_TIMEOUT="${ORCA_TIMEOUT:-25}"
TIMEOUT_BIN="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
SEND_MAX_CHARS_DEFAULT=2000

# The index holds message text, decisions and host readings. Nothing here is a
# secret, but none of it is anyone else's business either.
umask 077

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

# run_bounded <seconds> <command...>
# `timeout` is GNU coreutils and a stock macOS host has neither it nor
# `gtimeout`. Without a fallback every Orca call there returns empty with its
# stderr discarded, which reads as "every lane is dead" and triggers a mass
# restart. The watchdog kills exactly one pid it started, never a name.
run_bounded() {
  local secs="$1"; shift
  if [ -n "$TIMEOUT_BIN" ] && [ -z "${ORCHESTRATE_FORCE_WATCHDOG:-}" ]; then
    "$TIMEOUT_BIN" "$secs" "$@"
    return $?
  fi
  "$@" &
  local pid=$! i=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge "$secs" ]; then
      kill -TERM "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 1; i=$((i + 1))
  done
  wait "$pid"
}

orca_call() { run_bounded "$ORCA_TIMEOUT" "$ORCA" "$@"; }

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
  SESSION_FILE="$PROG/.session"
  CFG_FLAT=""
  AGENTS_FLAT=""
  [ -d "$PROG" ] || die "no programme dir at $PROG (run: orchestrate.sh init $PROGRAMME)" 2
  # Every gh call in every verb must address the programme's repository, not
  # whatever directory the agent happened to start in.
  local gh_repo; gh_repo="$(cfg gh_repo)"
  [ -z "$gh_repo" ] && gh_repo="$(gh_repo_from_origin)"
  [ -n "$gh_repo" ] && export GH_REPO="$gh_repo"
  touch "$LANES" "$EVENTS" "$HOSTS"
  mkdir -p "$REVIEWS"
  chmod 700 "$PROG" 2>/dev/null
  session_resolve
}

# ----------------------------------------------------------------- tiny yaml

# Flatten a small YAML file to "dotted.key<TAB>value" lines. Understands nested
# blocks, inline maps and inline lists, which is every shape programme.yaml and
# agents.yaml use. List blocks ("- ...") are skipped: they carry review classes,
# which the agent reads as text, not the scripts.
yaml_flat() {
  [ -f "$1" ] || return 0
  awk '
    function trim(s) { gsub(/\r/, "", s); sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function unq(s,   q) {
      s = trim(s)
      if (length(s) < 2) return s
      q = substr(s, 1, 1)
      if ((q == "\"" || q == "'"'"'") && substr(s, length(s), 1) == q) return substr(s, 2, length(s) - 2)
      return s
    }
    function delist(s) { sub(/^\[/, "", s); sub(/\]$/, "", s); gsub(/,/, " ", s); gsub(/["'"'"']/, "", s); gsub(/[ ]+/, " ", s); return trim(s) }
    function strip_comment(s,   i, c, inq, insq, out) {
      inq = 0; insq = 0; out = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\"") inq = !inq
        if (c == "'"'"'") insq = !insq
      if (!inq && !insq && c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t]/)) break
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
      gsub(/\t/, "  ", line)
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

# The identity of THIS orchestrator, stable across the many invocations one
# orchestrator makes. An explicit ORCHESTRATE_SESSION always wins; two
# orchestrators sharing one programme dir must set it, because a persisted file
# cannot tell them apart.
session_resolve() {
  [ -z "$ORCHESTRATE_SESSION" ] || return 0
  if [ -s "$SESSION_FILE" ]; then
    ORCHESTRATE_SESSION="$(head -1 "$SESSION_FILE")"
    return 0
  fi
  ORCHESTRATE_SESSION="orch-$(date -u +%Y%m%dT%H%M%SZ)-$$"
}

session_persist() {
  printf '%s\n' "$ORCHESTRATE_SESSION" > "$SESSION_FILE"
  chmod 600 "$SESSION_FILE" 2>/dev/null
}

cadence_s() { dur_s "$(cfg loop.every 20m)"; }

gh_repo_from_origin() {
  local repo url; repo="$(cfg repo)"
  [ -n "$repo" ] || return 0
  url="$(git -C "$repo" remote get-url origin 2>/dev/null)" || return 0
  case "$url" in
    *github.com[:/]*) printf '%s' "$url" | sed -E 's#^.*github\.com[:/]##; s#\.git$##' ;;
  esac
}

# ------------------------------------------------------------------- events

# ev <name> [key value]... : append one event, every value a string.
ev() {
  local name="$1"; shift
  local filter='{t: $t, ev: $ev}'
  local args=(-nc --arg t "$(now)" --arg ev "$name")
  local i=0
  while [ "$#" -ge 2 ]; do
    i=$((i + 1))
    args+=(--arg "k$i" "$1" --arg "v$i" "$2")
    filter="$filter + {(\$k$i): \$v$i}"
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

lane_row() {
  local row; row="$(jq -c --arg l "$1" 'select(.lane == $l)' "$LANES" 2>/dev/null | tail -1)"
  [ -n "$row" ] && printf '%s' "$row" || printf '{}'
}

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
  orca_call terminal read --terminal "$handle" "${ORCA_ENV_ARGS[@]}" --screen --json 2>/dev/null \
    | jq -r '.result.terminal.tail[]?' | grep -v '^[[:space:]]*$'
}

lane_screen() {
  local lane="$1"
  orca_screen "$(lane_field "$lane" handle)" "$(lane_field "$lane" env)"
}

# Re-resolve a lane's handle from its worktree. A host restart leaves the
# indexed handle stale and every send then lands nowhere.
#
# Taking the first terminal in the worktree is NOT good enough: several lanes
# can share one worktree, and binding them all to the first terminal sends every
# lane's message to one agent while recording each as delivered. So the binding
# is explicit. A single candidate binds; otherwise the lane's recorded title
# must name exactly one; otherwise this refuses and the lane is marked
# needs-rebind. "Cannot tell which of three terminals is this lane" is the
# correct answer.
lane_reresolve() {
  local lane="$1" wt env sel rows n handle title
  wt="$(lane_field "$lane" worktree)"; env="$(lane_field "$lane" env)"
  [ -n "$wt" ] || return 1
  orca_env_args "$env"
  sel="$(orca_call worktree list "${ORCA_ENV_ARGS[@]}" --json 2>/dev/null \
    | jq -r --arg w "$wt" '.result.worktrees[]? | select((.id | endswith("/" + $w)) or (.name // "") == $w) | .id' | head -1)"
  if [ -n "$sel" ]; then sel="id:$sel"; else sel="name:$wt"; fi
  rows="$(orca_call terminal list --worktree "$sel" "${ORCA_ENV_ARGS[@]}" --json 2>/dev/null \
    | jq -r '.result.terminals[]? | [.handle, (.title // "")] | @tsv')"
  [ -n "$rows" ] || return 1
  n="$(printf '%s\n' "$rows" | grep -c .)"
  if [ "$n" = 1 ]; then
    handle="$(printf '%s\n' "$rows" | head -1 | cut -f1)"
  else
    title="$(lane_field "$lane" title)"
    [ -n "$title" ] || title="$lane"
    handle="$(printf '%s\n' "$rows" | awk -F'\t' -v t="$title" '$2 == t { print $1 }')"
    if [ "$(printf '%s\n' "$handle" | grep -c .)" != 1 ]; then
      refuse rebind-ambiguous "$n terminals in worktree $wt, none uniquely titled for lane $lane" >/dev/null 2>&1
      lane_set "$lane" status needs-rebind
      return 1
    fi
  fi
  # A handle another lane already holds is never handed to this one.
  if jq -e --arg h "$handle" --arg l "$lane" 'select(.handle == $h and .lane != $l)' "$LANES" >/dev/null 2>&1; then
    refuse rebind-ambiguous "terminal $handle already belongs to another lane, not $lane" >/dev/null 2>&1
    lane_set "$lane" status needs-rebind
    return 1
  fi
  printf '%s' "$handle"
}

# ---------------------------------------------------------------- classify

# A lane's state comes from its own screen, matched against patterns that live
# in agents.yaml so a TUI change is a config edit, not a code edit.
# The window is deliberately short. A diff, a README or a PR body shown in a
# lane's terminal is CONTENT, and a wide window lets that content decide the
# lane's state: "Do you want" in a quoted file would mark a busy lane `asking`,
# and a shell prompt in a code sample would mark a live lane `dead`.
classify() {
  local kind="$1" text="$2" pat
  pat="$(agent_cfg "$kind" shell_prompt)"
  if [ -n "$pat" ] && printf '%s\n' "$text" | tail -2 | grep -Eq -- "$pat"; then printf 'dead'; return 0; fi
  pat="$(agent_cfg "$kind" asking)"
  if [ -n "$pat" ] && printf '%s\n' "$text" | tail -6 | grep -Eq -- "$pat"; then printf 'asking'; return 0; fi
  pat="$(agent_cfg "$kind" busy)"
  if [ -n "$pat" ] && printf '%s\n' "$text" | tail -6 | grep -Eq -- "$pat"; then printf 'working'; return 0; fi
  pat="$(agent_cfg "$kind" idle)"
  if [ -n "$pat" ] && printf '%s\n' "$text" | tail -6 | grep -Eq -- "$pat"; then printf 'idle'; return 0; fi
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
# A message is ONE literal line or it is not sent. The orchestrator composes
# messages out of lane screens, PR titles and review reports, all of which are
# content that something else wrote. A newline in that content is a second
# submission in the receiving agent, which runs without permission prompts, so
# multi-line text is refused rather than flattened: hand it over as a file the
# lane reads instead. Escape sequences are stripped, the line is capped, and
# what is recorded is what was actually typed.
#
# Only the ESC-introduced C1 forms are stripped, never raw bytes in 0x80-0x9f:
# those are the continuation bytes of ordinary UTF-8 text.
sanitise_line() {
  local text="$1" esc out max
  case "$text" in
    *$'\n'*|*$'\r'*) return 3 ;;
  esac
  case "$text" in
    -*) return 4 ;;
  esac
  esc="$(printf '\033')"
  out="$(printf '%s' "$text" \
    | LC_ALL=C sed -E "s#${esc}\\[[0-9;?]*[ -/]*[@-~]##g; s#${esc}[@-_]##g; s#${esc}##g" \
    | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177')"
  max="$(cfg send.max_chars "$SEND_MAX_CHARS_DEFAULT")"
  printf '%s' "$out" | cut -c1-"$max"
}

# One recorded path for every message. Refuses to type into a shell prompt,
# refuses anything that is not a single sanitised line, confirms delivery on the
# screen, and records the outcome either way.
lane_send() {
  local lane="$1" pr="$2" raw="$3" retry="${4:-retry}"
  local handle env res probe text rc resp
  handle="$(lane_field "$lane" handle)"
  [ -n "$handle" ] || { printf 'unknown lane %s\n' "$lane" >&2; return 2; }
  env="$(lane_field "$lane" env)"

  text="$(sanitise_line "$raw")"; rc=$?
  case "$rc" in
    3) refuse send-multiline "a message to $lane spans lines; hand multi-line content over as a file"; return 3 ;;
    4) refuse send-leading-dash "a message to $lane starts with a dash, which a CLI reads as a flag"; return 3 ;;
  esac
  case "$text" in
    *[![:space:]]*) : ;;
    *) refuse send-empty "a message to $lane is empty after sanitising"; return 3 ;;
  esac
  if [ "$(lane_field "$lane" status)" = needs-rebind ]; then
    refuse send-needs-rebind "lane $lane is not bound to a terminal; rebind it before sending"
    return 3
  fi

  if printf '%s\n' "$(orca_screen "$handle" "$env")" | tail -2 \
     | grep -Eq -- "$(agent_cfg "$(lane_field "$lane" agent)" shell_prompt '\$ $')"; then
    ev notified lane "$lane" pr "$pr" result dead-shell msg "$text"
    printf 'dead-shell -> %s\n' "$lane"
    [ "$retry" = retry ] || return 4
    lane_restart "$lane" || return 4
    lane_send "$lane" "$pr" "$raw" noretry
    return $?
  fi

  # The probe is built from the text itself and must be substantial: an empty
  # or near-empty pattern matches every screen, which reports delivery for a
  # message that never arrived.
  probe="$(printf '%s' "$text" | cut -c1-40)"
  if [ "${#probe}" -lt 6 ]; then
    refuse send-unverifiable "a message to $lane is too short to confirm on screen"
    return 3
  fi
  # Count it on the screen BEFORE sending, so old text cannot stand in for a
  # new arrival.
  local before after
  before="$(orca_screen "$handle" "$env" | grep -cF -- "$probe")"

  orca_env_args "$env"
  resp="$(orca_call terminal send --terminal "$handle" "${ORCA_ENV_ARGS[@]}" \
    --text "$text" --enter --json 2>/dev/null)"; rc=$?
  if [ "$rc" != 0 ] || printf '%s' "$resp" | jq -e '.ok == false' >/dev/null 2>&1; then
    ev notified lane "$lane" pr "$pr" result transport-error msg "$text"
    printf 'transport-error -> %s\n' "$lane"
    return 4
  fi
  sleep "${SEND_SETTLE_S:-3}"
  after="$(orca_screen "$handle" "$env" | grep -cF -- "$probe")"
  if [ "${after:-0}" -gt "${before:-0}" ]; then res=delivered; else res=unconfirmed; fi
  ev notified lane "$lane" pr "$pr" result "$res" msg "$text"
  printf '%s -> %s\n' "$res" "$lane"
  [ "$res" = delivered ]
}

# Restart a lane in place: re-resolve the handle first, then send the agent
# kind's resume command. Never kills anything. The command comes from
# agents.yaml and is sanitised like any other typed text.
lane_restart() {
  local lane="$1" handle env kind resume
  env="$(lane_field "$lane" env)"; kind="$(lane_field "$lane" agent)"
  handle="$(lane_reresolve "$lane")"
  if [ -n "$handle" ] && [ "$handle" != "$(lane_field "$lane" handle)" ]; then
    lane_set "$lane" handle "$handle"
    ev restart lane "$lane" action rehandle handle "$handle"
  fi
  resume="$(sanitise_line "$(agent_cfg "$kind" resume)")" || return 1
  [ -n "$resume" ] || return 1
  orca_env_args "$env"
  orca_call terminal send --terminal "$(lane_field "$lane" handle)" \
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

owner_json() {
  jq -nc --arg s "$ORCHESTRATE_SESSION" --arg h "$(uname -n 2>/dev/null || echo host)" \
    --arg a "$ORCHESTRATE_HARNESS" --arg t "$(now)" --arg p "$$" --arg c "$(cfg_fingerprint)" \
    '{session: $s, host: $h, harness: $a, pid: ($p | tonumber), t: $t, last_tick: $t, config: $c}'
}

# A fingerprint of the policy file, recorded when the lock is claimed. The walls
# live in programme.yaml, and anything running as this user can edit it, so an
# edit cannot be prevented here. It can be made visible, which is what a tick
# reports.
cfg_fingerprint() {
  [ -f "$CFG" ] || { printf 'none'; return 0; }
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$CFG" | cut -c1-16
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$CFG" | cut -c1-16
  else cksum "$CFG" | cut -d' ' -f1; fi
}

cfg_changed() {
  [ -s "$OWNER" ] || return 1
  local was; was="$(jq -r '.config // ""' "$OWNER")"
  [ -n "$was" ] || return 1
  [ "$was" != "$(cfg_fingerprint)" ]
}

# Atomic: noclobber makes the create fail rather than race, so two ticks cannot
# both believe they won.
owner_claim_new() {
  ( set -o noclobber; owner_json > "$OWNER" ) 2>/dev/null || return 1
  session_persist
  ev owner action claim session "$ORCHESTRATE_SESSION" harness "$ORCHESTRATE_HARNESS"
  printf 'owner %s\n' "$ORCHESTRATE_SESSION"
}

owner_touch() {
  [ -s "$OWNER" ] || return 0
  local tmp; tmp="$(mktemp)" || return 1
  jq --arg t "$(now)" '.last_tick = $t' "$OWNER" > "$tmp" && mv "$tmp" "$OWNER"
}

# An absent lock is NOT permission. It means nobody has claimed the programme,
# and a verb that writes must not proceed on that basis: two unowned sessions
# double-merge and double-message, which is the whole reason the lock exists.
owner_require() {
  if [ ! -s "$OWNER" ]; then
    refuse owner-unclaimed "no owner for $PROGRAMME; claim it with: orchestrate.sh takeover $PROGRAMME"
    return 3
  fi
  local held; held="$(owner_session)"
  [ "$held" = "$ORCHESTRATE_SESSION" ] && return 0
  refuse owner-held "$held owns this programme"
  return 3
}

# Claim it if it is free, otherwise require that it is already ours.
owner_ensure() {
  owner_claim_new >/dev/null 2>&1 && return 0
  owner_require
}

# Take a lock that is released, or one that is stale past twice the cadence, or
# one the caller explicitly asks for. Recorded either way.
owner_takeover() {
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
    local tmp; tmp="$(mktemp)" || return 1
    owner_json > "$tmp" && mv "$tmp" "$OWNER"
    session_persist
    printf 'owner %s\n' "$ORCHESTRATE_SESSION"
    return 0
  fi
  owner_claim_new && return 0
  owner_require
}

# ---------------------------------------------------------------- scrubber

# Secrets are REFUSED, never rewritten. A redacted secret is still a secret that
# reached a file, and a rewrite invites a report to be posted anyway.
ORCHESTRATE_SECRET_RE='gh[opsu]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9-]{10,}|Authorization:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9._~+/=-]{8,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}'

# Every outward post goes through here. Host paths are stripped; secrets,
# attribution words and U+2014 are refused outright, so nothing part-clean is
# ever posted.
scrub() {
  local in="$1" out="${2:-${1%.md}-clean.md}" deny hits dir tmp
  [ -f "$in" ] || { printf 'no such file: %s\n' "$in" >&2; return 1; }
  # Reports are written by reviewer lanes into shared worktrees, so the output
  # path is attacker-reachable: never follow a symlink and never clobber.
  if [ -L "$out" ]; then refuse scrub-unsafe-output "$out is a symlink"; return 3; fi
  dir="$(dirname "$out")"
  tmp="$(mktemp "$dir/.scrub.XXXXXX")" || return 1
  sed -E \
    -e 's#/private/tmp/[A-Za-z0-9._/-]*##g' \
    -e 's#/tmp/[A-Za-z0-9._-]+/[A-Za-z0-9._/-]*/scratchpad/##g' \
    -e 's#[A-Za-z]:\\Users\\[A-Za-z0-9._-]+\\#~\\#g' \
    -e 's#%2[Ff](home|Users)%2[Ff][A-Za-z0-9._-]+(%2[Ff])?#~%2F#g' \
    -e 's#/(home|Users)/[A-Za-z0-9._-]+#~#g' \
    -e 's#/(var|opt|srv)/[A-Za-z0-9._/-]*/(worktrees|workspaces)/##g' \
    "$in" > "$tmp"
  if grep -Eqi -- "$ORCHESTRATE_SECRET_RE" "$tmp"; then
    grep -Ein -- "$ORCHESTRATE_SECRET_RE" "$tmp" | cut -c1-60 | head -3 >&2
    rm -f "$tmp"
    refuse scrub-secret "credential-shaped string in $in"
    return 3
  fi
  deny="$(cfg scrub.deny "$(cfg attribution_patterns '^[[:space:]]*co-authored-by:[[:space:]]')")"
  hits="$(grep -Eic -- "$deny" "$tmp")"
  if [ "${hits:-0}" != 0 ]; then
    grep -Ein -- "$deny" "$tmp" | head -5 >&2
    rm -f "$tmp"
    refuse scrub-vendor "$hits vendor or attribution hits in $in"
    return 3
  fi
  if grep -q $'\xe2\x80\x94' "$tmp"; then
    rm -f "$tmp"
    refuse scrub-emdash "U+2014 present in $in"
    return 3
  fi
  mv -f "$tmp" "$out" || { rm -f "$tmp"; return 1; }
  printf '%s\n' "$out"
}

# --------------------------------------------------------------- merge gate

valid_pr() { printf '%s' "${1:-}" | grep -Eq '^[0-9]+$'; }
valid_sha() { printf '%s' "${1:-}" | grep -Eq '^[0-9a-f]{40}$'; }

# One commit's signature row: "%G?<tab>%GK". Only G counts. U is a good
# signature by an unknown key, which is no statement about who made the commit,
# so it is refused. When signing.key is set, the signer must be that key.
sig_row_ok() {
  local status="${1:-}" keyid="${2:-}" want="${3:-}"
  [ "$status" = G ] || return 1
  [ -n "$want" ] || return 0
  case "$want" in
    '<'*) return 0 ;;                       # an unedited template placeholder
  esac
  local a b
  a="$(printf '%s' "$keyid" | tr 'a-f' 'A-F')"
  b="$(printf '%s' "$want" | tr 'a-f' 'A-F')"
  [ "$a" = "$b" ] || [ "${a%"$b"}" != "$a" ]
}

# The checkout the gate reads its evidence from. Required: defaulting it to the
# caller's cwd means the signatures checked and the PR merged can be different
# repositories.
gate_repo() {
  local repo; repo="$(cfg repo)"
  if [ -z "$repo" ]; then
    refuse merge-repo "programme.yaml has no repo; the gate needs the checkout it must read"
    return 3
  fi
  if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    refuse merge-repo "programme.yaml repo is not a git checkout: $repo"
    return 3
  fi
  printf '%s' "$repo"
}

# Checks are read for the PR whose head is already pinned to the reviewed sha,
# so a green run on an older commit cannot stand in for this one.
ci_gate() {
  local pr="$1" s bad
  s="$(gh pr checks "$pr" --json name,bucket 2>/dev/null)"
  if [ -z "$s" ] || [ "$(printf '%s' "$s" | jq -r 'length' 2>/dev/null)" = "" ]; then
    refuse merge-ci "#$pr has no check data and ci is set to gate"
    return 3
  fi
  bad="$(printf '%s' "$s" | jq -r '[.[] | select(.bucket != "pass" and .bucket != "skipping") | "\(.bucket):\(.name)"] | join(" ")')"
  [ -z "$bad" ] || { refuse merge-ci "#$pr checks are not green: $bad"; return 3; }
}

# Walls that config cannot lift: the base must be the declared trunk and must
# not be a never_merge_into branch. Evidence is bound to the commit the PR
# actually proposes, fetched from refs/pull/<n>/head, never to a branch name a
# fork can also carry. There is no force-push path anywhere in this plugin.
merge_gate() {
  local pr="${1:-}" want="${2:-}"
  valid_pr "$pr" || { refuse merge-pr-format "a PR number must be digits, got: $pr"; return 3; }
  if [ -z "$want" ] || [ "$want" = "-" ]; then
    refuse merge-sha-required "#$pr needs the sha the verdict was reached on; an unpinned merge is not reviewed"
    return 3
  fi
  valid_sha "$want" || { refuse merge-sha-format "a reviewed sha must be 40 hex characters, got: $want"; return 3; }

  local trunk repo
  trunk="$(cfg trunk)"
  [ -n "$trunk" ] || { printf 'programme.yaml has no trunk\n' >&2; return 1; }
  repo="$(gate_repo)" || return 3
  local gh_repo; gh_repo="$(cfg gh_repo)"
  [ -n "$gh_repo" ] && export GH_REPO="$gh_repo"

  local view state draft fork base branch head
  view="$(gh pr view "$pr" --json state,isDraft,isCrossRepository,baseRefName,headRefName,headRefOid 2>/dev/null)"
  [ -n "$view" ] || { printf 'cannot read PR #%s\n' "$pr" >&2; return 1; }
  state="$(printf '%s' "$view" | jq -r '.state // ""')"
  draft="$(printf '%s' "$view" | jq -r '.isDraft // false')"
  fork="$(printf '%s' "$view" | jq -r '.isCrossRepository // false')"
  base="$(printf '%s' "$view" | jq -r '.baseRefName // ""')"
  branch="$(printf '%s' "$view" | jq -r '.headRefName // ""')"
  head="$(printf '%s' "$view" | jq -r '.headRefOid // ""')"

  [ "$state" = OPEN ] || { refuse merge-not-open "#$pr is $state"; return 3; }
  # Draft is the author saying "not ready". The gate reads it, it does not clear it.
  [ "$draft" != true ] || { refuse merge-draft "#$pr is a draft; the author has not marked it ready"; return 3; }
  if [ "$fork" = true ] && [ "$(cfg allow_fork_prs false)" != true ]; then
    refuse merge-fork "#$pr comes from a fork; set allow_fork_prs to accept those deliberately"
    return 3
  fi
  [ "$head" = "$want" ] || { refuse merge-sha-mismatch "#$pr head is $head, the verdict was on $want"; return 3; }

  local never
  never="$(cfg never_merge_into)"
  local -a never_list=()
  read -r -a never_list <<< "$never"
  local b
  for b in "${never_list[@]:-}"; do
    [ -n "$b" ] || continue
    [ "$base" = "$b" ] && { refuse merge-never-base "#$pr targets $base, which is on never_merge_into"; return 3; }
  done
  [ "$base" = "$trunk" ] || { refuse merge-wrong-base "#$pr targets $base, trunk is $trunk"; return 3; }

  # Evidence follows the head commit, not the branch name.
  local ref="refs/orchestrate/pr/$pr" fetched
  if ! git -C "$repo" fetch -q --no-tags origin "+refs/pull/$pr/head:$ref" 2>/dev/null; then
    refuse merge-no-head-ref "#$pr head commit could not be fetched from refs/pull/$pr/head"
    return 3
  fi
  fetched="$(git -C "$repo" rev-parse "$ref" 2>/dev/null)"
  [ "$fetched" = "$head" ] || { refuse merge-head-mismatch "#$pr head is $head, refs/pull/$pr/head is $fetched"; return 3; }

  if ! git -C "$repo" fetch -q --no-tags origin "+refs/heads/$trunk:refs/remotes/origin/$trunk" 2>/dev/null; then
    refuse merge-fetch "cannot fetch $trunk from origin"
    return 3
  fi
  local base_sha mb n
  base_sha="$(git -C "$repo" rev-parse "origin/$trunk" 2>/dev/null)"
  [ -n "$base_sha" ] || { refuse merge-fetch "cannot resolve origin/$trunk"; return 3; }
  mb="$(git -C "$repo" merge-base "$base_sha" "$head" 2>/dev/null)"
  [ -n "$mb" ] || { refuse merge-unrelated "#$pr shares no history with $trunk"; return 3; }
  n="$(git -C "$repo" rev-list --count "$mb..$head" 2>/dev/null)"
  # An empty range satisfies every "no bad commits" check vacuously.
  [ "${n:-0}" -gt 0 ] || { refuse merge-empty-range "#$pr adds no commits over $trunk"; return 3; }

  if ! git -C "$repo" merge-tree --write-tree "$base_sha" "$head" >/dev/null 2>&1; then
    refuse merge-conflict "#$pr does not merge cleanly into $trunk"
    return 3
  fi

  if [ "$(cfg signing.required true)" = true ]; then
    local want_key st kid bad=0
    want_key="$(cfg signing.key)"
    while IFS="$(printf '\t')" read -r st kid; do
      [ -n "$st" ] || continue
      sig_row_ok "$st" "$kid" "$want_key" || bad=$((bad + 1))
    done < <(git -C "$repo" log --format='%G?%x09%GK' "$mb..$head" 2>/dev/null)
    [ "$bad" = 0 ] || { refuse merge-unsigned "#$pr has $bad commits without a good signature from the configured key"; return 3; }
  fi
  if [ "$(cfg attribution_guard true)" = true ]; then
    local pat attributed
    pat="$(cfg attribution_patterns '^[[:space:]]*co-authored-by:[[:space:]]')"
    attributed="$(git -C "$repo" log --format='%B' "$mb..$head" 2>/dev/null | grep -Eic -- "$pat")"
    [ "${attributed:-0}" = 0 ] || { refuse merge-attributed "#$pr has $attributed attribution lines"; return 3; }
  fi

  [ "$(cfg ci ignore)" != gate ] || ci_gate "$pr" || return 3

  local autonomy; autonomy="$(cfg autonomy)"
  if [ -z "$autonomy" ]; then
    refuse merge-autonomy-unset "programme.yaml sets no autonomy; a missing key is not permission to merge"
    return 3
  fi
  if [ "$autonomy" != merge_on_verdict ]; then
    printf 'ASK: #%s passes the gate, autonomy is %s, so ask before merging\n' "$pr" "$autonomy"
    ev decision topic "merge #$pr" text "gate passed, autonomy requires asking" source gate
    return 4
  fi

  # The owning lane can push at any moment. Re-read immediately before merging
  # and pin the merge to the commit that was actually reviewed.
  local view2
  view2="$(gh pr view "$pr" --json state,baseRefName,headRefOid 2>/dev/null)"
  if [ "$(printf '%s' "$view2" | jq -r '.headRefOid // ""')" != "$head" ] \
     || [ "$(printf '%s' "$view2" | jq -r '.baseRefName // ""')" != "$base" ] \
     || [ "$(printf '%s' "$view2" | jq -r '.state // ""')" != OPEN ]; then
    refuse merge-moved "#$pr changed between the gate and the merge"
    return 3
  fi
  if gh pr merge "$pr" --merge --match-head-commit "$head" >/dev/null 2>&1; then
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
# A PR whose state could not be read is owed-unknown, NEVER dropped. The audit
# exists because a lane waited hours on a merged PR; reporting zero owed because
# the network was down is the same failure wearing a success.
owed_list() {
  local pr lane st rc
  jq -r 'select(.ev == "pr") | "\(.pr) \(.lane)"' "$EVENTS" 2>/dev/null | sort -u | while read -r pr lane; do
    [ -n "$pr" ] || continue
    jq -e --arg pr "$pr" 'select(.ev == "notified" and .pr == $pr and .result == "delivered")' "$EVENTS" >/dev/null 2>&1 && continue
    st="$(gh pr view "$pr" --json state --jq .state 2>/dev/null)"; rc=$?
    if [ "$rc" != 0 ] || [ -z "$st" ]; then
      printf '%s\t%s\t%s\n' "$lane" "$pr" "owed-unknown"
      continue
    fi
    case "$st" in
      MERGED|CLOSED) printf '%s\t%s\t%s\n' "$lane" "$pr" "$st" ;;
    esac
  done
}

# Open PR count, or the empty string when GitHub could not be asked.
open_pr_count() {
  local n rc
  n="$(gh pr list --state open --json number --jq 'length' 2>/dev/null)"; rc=$?
  { [ "$rc" = 0 ] && printf '%s' "$n" | grep -Eq '^[0-9]+$'; } || { printf ''; return 1; }
  printf '%s' "$n"
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
  th="$(orca_call terminal create --worktree "name:$wt" "${ORCA_ENV_ARGS[@]}" \
    --title orchestrate-probe --command 'df -P / | tail -1' --json 2>/dev/null | jq -r '.result.terminal.handle // empty')"
  [ -n "$th" ] || { host_record "$env" unknown ""; return 1; }
  orca_call terminal wait --terminal "$th" "${ORCA_ENV_ARGS[@]}" --for exit --timeout-ms 15000 --json >/dev/null 2>&1
  out="$(orca_screen "$th" "$env")"
  orca_call terminal close --terminal "$th" "${ORCA_ENV_ARGS[@]}" --json >/dev/null 2>&1
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
