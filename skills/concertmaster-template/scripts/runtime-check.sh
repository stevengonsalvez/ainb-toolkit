#!/usr/bin/env bash
# runtime-check.sh: the tick's runtime restart check (SKILL.md § Resume, after the discover step).
# An Orca RUNTIME restart (no VM reboot: scripts/boot-sweep.sh never runs) changes every terminal
# handle, resumes the sessions and silently kills the /loop wake of each standing lane. This
# finds those lanes on THIS host, refreshes their ledger handles by worktree path, and nudges
# them through boot-sweep.sh's own decision and nudge core (same safety checks, one nudge,
# transcript-advance confirm, then unconfirmed and gave-up), with "since" = the lane's expected
# wake time instead of boot time.
#
#   scripts/runtime-check.sh             # refresh ledger handles, then nudge stale lanes
#   scripts/runtime-check.sh --dry-run   # same decisions; nothing sent, nothing written
#
# Give the call a 600000 ms timeout (or run it in the background): each stale lane can wait
# up to CM_BOOT_CONFIRM_S (60 s) for its nudge to be confirmed. The ledger handles are written
# BEFORE any nudge, so a killed run still leaves them fresh. Details: references/runtime-check.md.
#
# For every standing local lane in the ledger (workers.<id>.standing true; never a gone, repurposed or
# asleep record, never the concertmaster itself):
#   handle     the lane's ONE Claude terminal, looked up by worktree PATH in `orca terminal list`
#              (never by the recorded handle). Exactly one: workers.<id>.terminal is rewritten
#              to it when it differs. None: `no-terminal` (resume.sh's job). More than one:
#              `duplicate`, untouched.
#   churn      the recorded handle is no longer in the list for that path (an Orca restart).
#   stale      the newest Claude transcript is older than 2 x the lane's loop interval:
#              workers.<id>.loopIntervalMin, else config lanes[<workers.<id>.lane>].loop_minutes,
#              else schedule.lane_loop_minutes (30). A churned lane is judged after ONE interval:
#              its wake is already missed.
#   nudge      stale lanes go to `boot-sweep.sh --since <now - limit> --lanes <path>`: nudged once
#              unless a menu, mid-turn, no Claude footer or a shell prompt is on screen. A churned
#              lane is told Orca restarted; a stale lane with no churn gets a NEUTRAL text (do
#              nothing if your loop is armed), because nothing proves its timer died. Attempts are
#              kept per transcript (a lane that got going starts fresh, one that did not is
#              `gave-up` after two nudges) and a lane nudged 3 times in 6 h is `gave-up` too.
#   resume.lock  while $CM_HOME/resume.lock exists (scripts/resume.sh holds it) nothing is sent: handles are
#              still refreshed and each stale lane is reported `resume-in-progress`.
# Output: TSV  lane  handle  age  result  detail   (one row per lane). Results: ok, refreshed,
# nudged, would-nudge, skipped, unconfirmed, gave-up, busy, menu, report, unreadable, send-failed,
# no-ledger, not-standing, unknown, no-terminal, duplicate, resume-in-progress. Exit 0 unless the
# ledger is unreadable (1) or usage is wrong (2). Churn persists: the refresh stamps
# workers.<id>.terminalChurnAt, and a lane stays "churned" (1 x limit, restart text) until its
# transcript is newer than that, so the first tick refreshing the handle never hides the restart.
# Code Mode dialog: after the ledger handles are written and before pass 2, for every live ledger worker on ANY host (standing or
# not; a remote host through --environment) whose worktree has exactly one Claude terminal, scripts/codemode-recover.sh closes the Claude
# Code "Code Mode" opt-in dialog a host reboot leaves lanes on (one Esc, then one re-arm nudge; any other menu is never touched). Rows:
# lane handle - recovered | closed | menu | held | unreadable | send-failed | would-recover (and one `skipped` row when the pass stops at
# CM_CODEMODE_BUDGET_S, default 300 s, so pass 2 keeps its time; one recovery is cut at what is left of it, 30 s up to CM_CODEMODE_LANE_MAX_S, default 180 s).
# Nothing is sent while resume.lock exists.
# The ledger is written under a mkdir lock (<ledger>.lock), atomically, keeping its file mode.
# Env: CM_HOME, CM_PATH_MATCH, CM_SELF_PATH_RE (default: the config worktrees.self_name directory),
#      CM_RUNTIME_SWEEP and CM_CODEMODE_RECOVER (stub scripts, tests, CM_TEST=1 only), CM_CODEMODE_BUDGET_S (300), CM_CLAUDE_PROJECTS,
#      CM_BOOT_CONFIRM_S (via boot-sweep.sh).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
  '') ;;
  *) cm_warn "runtime-check.sh: unknown arg: $1"; exit 2 ;;
esac
command -v jq >/dev/null 2>&1 || { cm_warn "runtime-check.sh: missing dependency: jq"; exit 0; }
[ -n "$CM_PATH_MATCH" ] || { cm_warn "runtime-check.sh: set worktrees.path_match in config.yaml (or CM_PATH_MATCH)"; exit 0; }
LEDGER="$CM_HOME/ledger.json"
if ! [ -r "$LEDGER" ] || ! jq -e 'type == "object"' "$LEDGER" >/dev/null 2>&1; then
  cm_warn "runtime-check.sh: ledger $LEDGER missing or unreadable: nothing checked"; exit 1
fi

ORCA="$(cm_cli)" || exit 2
SWEEP="${CM_RUNTIME_SWEEP:-$HERE/boot-sweep.sh}"
DEFAULT_MIN="$(cm_cfg .schedule.lane_loop_minutes 30)"
{ [[ "$DEFAULT_MIN" =~ ^[0-9]+$ ]] && [ "$DEFAULT_MIN" -gt 0 ]; } || DEFAULT_MIN=30
CM_PATH_RE="${CM_SELF_PATH_RE:-/${CM_SELF_WORKTREE}/*\$}"
NOW="$(date +%s)"
US=$'\037'   # unit separator: a non-whitespace IFS keeps empty fields (a tab would swallow them)
LOCKED=0; [ -e "$CM_HOME/resume.lock" ] && LOCKED=1

NUDGE_CHURN="Orca restarted. Any /loop or ScheduleWakeup timer you had died with it. Check git status and your worktree comment, re-arm your standing /loop now with the same prompt as before (your brief under $CM_HOME/briefs lists it if you lost it), and carry on."
NUDGE_QUIET="Status check from the concertmaster: you have had no turn for longer than your loop interval. If your standing /loop or wake is armed, do nothing special: carry on with your next step. If it is not armed, re-arm it now with the same prompt as before (your brief under $CM_HOME/briefs lists it), then carry on."

norm() { sed -E 's#/\.(/|$)#/#g; s#//+#/#g; s#(.)/+$#\1#'; }
row() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"; } # lane handle age result detail

tl="$(cm_timeout 60 "$ORCA" terminal list --json </dev/null 2>/dev/null)"
if ! printf '%s' "$tl" | jq -e '.result.terminals | type == "array"' >/dev/null 2>&1; then
  cm_warn "runtime-check.sh: terminal list unreadable: no lane checked, nothing changed"
  row - - - unreadable "orca terminal list failed; nothing checked this tick"; exit 0
fi
terms="$(printf '%s' "$tl" | jq -r --arg re "$CM_PATH_MATCH" '.result.terminals[]? | select((.worktreePath // "") | test($re)) | select((.agentIdentity // "") == "claude") | [.handle, .worktreePath] | @tsv')"

CFG_LANES="$(printf '%s' "$CM_CFG_JSON" | jq -c '[(.lanes // [])[]? | select(type == "object") | {name, loop_minutes}]' 2>/dev/null || echo '[]')"
lanes="$(jq -r --argjson cfg "$CFG_LANES" '.workers // {} | to_entries[] | select(.value | type == "object")
    | select(.value.standing == true and ((.value.host // "local") == "local") and (((.value.state // "") | IN("gone", "repurposed", "asleep")) | not))
    | .value as $w
    | .key as $k
    | ((($w.loopIntervalMin // ([$cfg[] | select(.name == ($w.lane // $k) or .name == $k or .name == ($k | sub("^w-"; ""))) | .loop_minutes][0]) // "") | tostring)) as $iv
    | ((try ($w.terminalChurnAt | fromdateiso8601) catch 0) // 0 | tostring) as $ca
    | [$k, ($w.path // $w.worktree // $w.worktreePath // ""), ($w.terminal // ""), $iv, $ca] | join("\u001f")' "$LEDGER")"

# rc_ledger_write <jq filter> [jq args...]: rewrite the ledger through the filter. Uses lib.sh's cm_ledger_write
# when it exists; otherwise the same safe sequence inline (mkdir lock with stale steal, temp file, refuse a
# result that is not exactly one JSON document, keep the file mode, atomic mv).
rc_ledger_write() {
  if declare -F cm_ledger_write >/dev/null; then CM_LEDGER="$LEDGER" cm_ledger_write "$@"; return; fi
  local lock="$LEDGER.lock" i=0 tmp rc=1
  while :; do
    if mkdir "$lock" 2>/dev/null; then break; fi
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +2 2>/dev/null)" ] && mv "$lock" "$lock.stale.$$" 2>/dev/null; then rm -rf -- "${lock:?}.stale.$$"; continue; fi
    i=$((i + 1)); [ "$i" -le 50 ] || { cm_warn "runtime-check.sh: ledger lock $lock busy"; return 1; }
    sleep 0.1
  done
  tmp="$LEDGER.tmp.$$"
  if jq "$@" "$LEDGER" > "$tmp" 2>/dev/null && [ "$(jq -s 'length' "$tmp" 2>/dev/null)" = 1 ]; then
    chmod "$(stat -L -c %a "$LEDGER" 2>/dev/null || stat -L -f %Lp "$LEDGER" 2>/dev/null || echo 600)" "$tmp" 2>/dev/null
    mv "$tmp" "$LEDGER" && rc=0
  else
    rm -f -- "${tmp:?}"
  fi
  rmdir "$lock" 2>/dev/null
  return "$rc"
}

# ---- Code Mode dialog recovery, run after the ledger handles are written -----------------------------------------------------------
# After a HOST reboot the resumer reopens each lane with "claude --resume" and every lane stops on the Claude Code Code Mode opt-in
# dialog. boot-sweep.sh reads that dialog as a question menu and never types into it, so the lane stayed stale for hours. For every
# live ledger worker (local OR on another host, standing or not) whose worktree has exactly ONE Claude terminal, scripts/codemode-recover.sh
# reads the pane and, only when the bottom of it is that dialog, sends Esc ("start without it"), confirms it closed and sends one re-arm
# nudge. Every other pane, every other menu included, is left to the existing passes. A lane it handled is listed in $handled and is taken out of the stale plan, so pass 2 does not nudge
# it again this tick (a fresh lane on the dialog keeps its pass 1 row and gets the recovery row). Remote hosts go through the same fleet CLI with --environment (cm_cli_host_into), a terminal list per host.
# resume.lock: nothing is sent. Output rows: lane handle - result detail (recovered, closed, menu, held, unreadable, send-failed, would-recover).
# cm_unreadable_host <host> <why>: a host whose terminal list cannot be read has its in-scope ledger workers reported as unreadable (one row each),
# not silently dropped: no local pass looks at a remote worker, so without these rows the lanes would vanish from the report. Uses the caller's $rows
cm_unreadable_host() {
  local i2 hp2 p2 _s2 n2
  while IFS="$US" read -r i2 hp2 p2 _s2; do
    [ "$hp2" = "$1" ] && [ -n "$i2" ] || continue
    n2="$(printf '%s' "$p2" | norm)"; [ -n "$n2" ] || continue
    if [ "$i2" = concertmaster ] || grep -qE "$CM_PATH_RE" <<<"$n2"; then continue; fi
    grep -qE "$CM_PATH_MATCH" <<<"$n2" || continue
    row "$i2" - - unreadable "$2"
  done <<<"$rows"
}
codemode_pass() {
  local rows host hosts hsel hl id path h res result detail text hp np standing args cm_started cm_budget cm_to cm_max cmout cmrc
  handled="$US"   # unit-separator joined ids ($US id $US id $US), no newline: portable through awk -v
  cm_started="$(date +%s)"; cm_budget="${CM_CODEMODE_BUDGET_S:-300}"; case "$cm_budget" in ''|*[!0-9]*) cm_budget=300 ;; esac
  [ -e "$CM_HOME/resume.lock" ] && return 0
  [ -x "$CODEMODE" ] || { cm_warn "runtime-check.sh: $CODEMODE is missing or not executable: Code Mode dialogs not checked"; return 0; }
  rows="$(jq -r '.workers // {} | to_entries[] | select(.value | type == "object")
      | select((((.value.state // "") | IN("gone", "torn-down", "repurposed", "asleep")) | not))
      | .value as $w | [.key, ($w.host // "local"), ($w.path // $w.worktree // $w.worktreePath // ""), (if $w.standing == true then "1" else "0" end)]
      | join("\u001f")' "$LEDGER" 2>/dev/null)"
  [ -n "$rows" ] || return 0
  hosts="$(printf '%s\n' "$rows" | awk -F"$US" 'NF >= 3 && !seen[$2]++ { print $2 }')"
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    if [ "$host" = local ]; then hl="$tl"
    else
      # a remote terminal list can take 60 s: the budget is checked before each one as well as before each lane
      if [ $(($(date +%s) - cm_started)) -ge "$cm_budget" ]; then
        row - - - skipped "Code Mode pass stopped after ${cm_budget}s: the remaining hosts and lanes are checked next tick"
        return 0
      fi
      cm_cli_host_into hsel "$host" || { cm_unreadable_host "$host" "host $host has no usable --environment: its Code Mode dialogs were not checked"; continue; }
      hl="$(cm_timeout 60 "$ORCA" terminal list "${hsel[@]}" --json </dev/null 2>/dev/null)"
      printf '%s' "$hl" | jq -e '.result.terminals | type == "array"' >/dev/null 2>&1 || { cm_warn "runtime-check.sh: terminal list of host $host unreadable: its Code Mode dialogs not checked"; cm_unreadable_host "$host" "terminal list of host $host unreadable: its Code Mode dialogs were not checked"; continue; }
    fi
    while IFS="$US" read -r id hp path standing; do
      [ "$hp" = "$host" ] && [ -n "$id" ] || continue
      [ -e "$CM_HOME/resume.lock" ] && return 0   # resume.sh may start while this pass runs: checked per lane, as pass 2 does
      # the tick call has a 600 s budget and pass 2 still has to run: a pass over many lanes stops here and the rest wait for the next tick
      if [ $(($(date +%s) - cm_started)) -ge "$cm_budget" ]; then
        row - - - skipped "Code Mode pass stopped after ${cm_budget}s: the remaining lanes are checked next tick"
        return 0
      fi
      np="$(printf '%s' "$path" | norm)"
      [ -n "$np" ] || continue
      if [ "$id" = concertmaster ] || grep -qE "$CM_PATH_RE" <<<"$np"; then continue; fi
      grep -qE "$CM_PATH_MATCH" <<<"$np" || continue
      h="$(printf '%s' "$hl" | jq -r --arg p "$np" '[.result.terminals[]? | select((.agentIdentity // "") == "claude") | select(((.worktreePath // "") | sub("/+$"; "")) == $p) | .handle] | if length == 1 then .[0] else empty end' 2>/dev/null)"
      [ -n "$h" ] || continue   # none, or two Claude terminals in one worktree: pass 1 and resume.sh own that
      if [ "$standing" = 1 ]; then text="$NUDGE_CODEMODE_LANE"; else text="$NUDGE_CODEMODE_WORKER"; fi
      args=(--terminal "$h" --lane "$id" --host "$host" --text "$text"); [ "$DRY" = 1 ] && args+=(--dry-run)
      # one recovery waits for the pane a few times and sends two keys: it is bounded by what is left of the budget (30 s at least, 180 s at most),
      # so the pass cannot run on far past its budget and starve pass 2
      cm_to=$((cm_budget - ($(date +%s) - cm_started))); [ "$cm_to" -lt 30 ] && cm_to=30; cm_max="${CM_CODEMODE_LANE_MAX_S:-180}"; case "$cm_max" in ''|*[!0-9]*|0) cm_max=180 ;; esac; [ "$cm_to" -gt "$cm_max" ] && cm_to="$cm_max"
      cmout="$(cm_timeout "$cm_to" "$CODEMODE" "${args[@]}" </dev/null 2>/dev/null)"; cmrc=$?
      res="$(printf '%s\n' "$cmout" | tail -n 1)"
      result="${res%%$'\t'*}"; detail="${res#*$'\t'}"
      if [ "$cmrc" = 124 ] || [ "$cmrc" = 137 ] || [ "$cmrc" = 142 ] || [ "$cmrc" = 143 ] || [ "$cmrc" = 129 ] || [ "$cmrc" = 130 ]; then result=unreadable; detail="codemode-recover.sh ran past its ${cm_to}s limit: an Esc may have been sent, read the pane"
      elif [ "$cmrc" != 0 ]; then result=unreadable; detail="codemode-recover.sh exited $cmrc (usage or setup error): nothing was judged, read the pane"; fi
      case "$result" in
        none) continue ;;
        '') result=unreadable; detail="codemode-recover.sh printed nothing (exit $cmrc): an Esc may have been sent, read the pane" ;;
        recovered|closed|menu|held|unreadable|send-failed|would-recover) ;;
        *) result=unreadable; detail="codemode-recover.sh answered something unexpected" ;;
      esac
      row "$id" "$h" - "$result" "$detail"
      handled="$handled$id$US"   # pass 2 must not nudge this lane again in the same tick (its screen was just handled here)
    done <<<"$rows"
  done <<<"$hosts"
}
handled="$US"
CODEMODE="$HERE/codemode-recover.sh"
[ "${CM_TEST:-}" = 1 ] && [ -n "${CM_CODEMODE_RECOVER:-}" ] && CODEMODE="$CM_CODEMODE_RECOVER"   # a stub sender only under the test switch
NUDGE_CODEMODE_LANE="Status check from the concertmaster after a restart: your session stopped at the Claude Code start-up dialog and it has been closed. Any /loop or ScheduleWakeup timer you had died with the restart. Check git status and your worktree comment, re-arm your standing /loop now with the same prompt as before (your brief under $CM_HOME/briefs lists it if you lost it), and carry on."
NUDGE_CODEMODE_WORKER="Status check from the concertmaster after a restart: your session stopped at the Claude Code start-up dialog and it has been closed. Check git status and your worktree comment, then carry on from where you stopped and set cm:running with the next step."

# ---- pass 1: decide per lane, collect handle refreshes ----------------------------------------
plan="$(mktemp "${TMPDIR:-/tmp}/cm-runtime.XXXXXX")" || exit 0
trap 'rm -f -- "${plan:?}"; if declare -F cm_ledger_unlock >/dev/null; then cm_ledger_unlock; fi' EXIT
refresh=""   # id<TAB>handle lines for the ledger write
while IFS="$US" read -r id path rec interval churnat; do
  [ -n "$id" ] || continue
  np="$(printf '%s' "$path" | norm)"
  [ -n "$np" ] || { row "$id" - - unknown "ledger row has no worktree path"; continue; }
  if [ "$id" = concertmaster ] || grep -qE "$CM_PATH_RE" <<<"$np"; then continue; fi   # the tick itself, never nudged from here
  cur="$(printf '%s\n' "$terms" | awk -F'\t' -v p="$np" '{q = $2; sub(/\/+$/, "", q); if (q == p) print $1}')"
  n="$(printf '%s' "$cur" | grep -c . || true)"
  if [ "$n" = 0 ]; then row "$id" "${rec:--}" - no-terminal "no Claude terminal in that worktree: resume.sh's job"; continue; fi
  if [ "$n" -gt 1 ]; then row "$id" "${rec:--}" - duplicate "$n Claude terminals in one worktree: left to resume.sh and the tick"; continue; fi
  note=""; churn=0; fresh_churn=0
  if [ "$rec" != "$cur" ]; then
    if [ -n "$rec" ]; then churn=1; fresh_churn=1; note="handle churn $rec -> $cur"; else note="handle set $cur"; fi
    refresh="$refresh$id"$'\t'"$cur"$'\t'"$fresh_churn"$'\n'
  fi
  m="$(cm_transcript_mtime "$np")"
  # churn persists until the lane takes a turn: the ledger remembers when the handle changed (terminalChurnAt),
  # so a later tick still knows the restart killed this lane's timer after the first tick refreshed the handle
  if [ "$churn" = 0 ] && [[ "${churnat:-0}" =~ ^[0-9]+$ ]] && [ "${churnat:-0}" -gt 0 ] && [ "$m" != unknown ] && [ "$churnat" -gt "$m" ]; then
    churn=1; note="Orca restart seen at $(date -u -d "@$churnat" +%FT%TZ 2>/dev/null || echo "$churnat"), no turn since"
  fi
  if [ "$m" = unknown ]; then row "$id" "$cur" - unknown "${note:+$note; }no Claude transcript visible: not nudged"; continue; fi
  { [[ "$interval" =~ ^[0-9]+$ ]] && [ "$interval" -gt 0 ]; } || interval="$DEFAULT_MIN"
  age=$((NOW - m)); mult=2; [ "$churn" = 1 ] && mult=1
  limit=$((mult * interval * 60)); amin=$((age / 60))
  if [ "$age" -le "$limit" ]; then
    row "$id" "$cur" "${amin}m" "$([ -n "$note" ] && echo refreshed || echo ok)" "${note:-transcript ${amin}m old, loop every ${interval}m}"
    continue
  fi
  # a stale lane: planned for pass 2 (fields joined by the unit separator; the note may hold spaces)
  printf '%s\n' "$id$US$cur$US$np$US$amin$US$mult$US$interval$US$limit$US$churn$US$note" >> "$plan"
done <<<"$lanes"

# ---- ledger handles first: a killed run still leaves them fresh ---------------------------------
if [ -n "$refresh" ] && [ "$DRY" = 0 ]; then
  map="$(printf '%s' "$refresh" | jq -Rn '[inputs | select(length > 0) | split("\t") | {key: .[0], value: {h: .[1], churn: (.[2] == "1")}}] | from_entries')"
  # shellcheck disable=SC2016  # jq program, not shell
  prog='reduce ($map | keys[]) as $k (.; if (.workers[$k] | type) == "object" then .workers[$k].terminal = $map[$k].h | .workers[$k].terminalRefreshedAt = $at | (if $map[$k].churn then .workers[$k].terminalChurnAt = $at else . end) else . end)'
  if ! rc_ledger_write "$prog" --argjson map "$map" --arg at "$(date -u +%FT%TZ)"; then
    cm_warn "runtime-check.sh: ledger write failed: handles not refreshed"
  fi
fi

# ---- Code Mode dialogs (after the ledger handles are written, before any nudge) ----------------------------------------
codemode_pass
# a lane the pass handled is not nudged again by pass 2 this tick (a fresh lane on the dialog keeps its pass 1 row and gets the recovery row)
# lanes the Code Mode pass handled are not nudged again (their handles and churn were refreshed above)
if [ "$handled" != "$US" ]; then plan_kept="$(awk -F"$US" -v h="$handled" -v u="$US" 'index(h, u $1 u) == 0' "$plan")"; printf '%s\n' "$plan_kept" > "$plan"; fi

# ---- pass 2: nudge the stale lanes -------------------------------------------------------------
while IFS="$US" read -r id cur np amin mult interval limit churn note; do
  [ -n "$id" ] || continue
  why="stale: no turn for ${amin}m, older than ${mult} x ${interval}m"
  [ -e "$CM_HOME/resume.lock" ] && LOCKED=1   # checked again per lane: resume.sh may start while we nudge
  if [ "$LOCKED" = 1 ]; then row "$id" "$cur" "${amin}m" resume-in-progress "${note:+$note; }$why; resume.lock exists, nothing sent"; continue; fi
  text="$NUDGE_QUIET"; [ "$churn" = 1 ] && text="$NUDGE_CHURN"
  args=(--since "$((NOW - limit))" --lanes "$np"); [ "$DRY" = 1 ] && args+=(--dry-run)
  res="$(CM_TICK_NUDGE="$text" "$SWEEP" "${args[@]}" 2>/dev/null | awk -F'\t' 'END{ if (NR) print $3 "\t" $4 }')"
  result="${res%%$'\t'*}"; detail="${res#*$'\t'}"
  [ -n "$result" ] || { result=unreadable; detail="the sweep returned nothing"; }
  row "$id" "$cur" "${amin}m" "$result" "${note:+$note; }$detail ($why)"
done < "$plan"
exit 0
