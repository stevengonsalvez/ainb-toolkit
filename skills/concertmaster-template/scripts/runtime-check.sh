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
# For every standing local lane in the ledger (workers.<id>.standing true; never a gone or
# repurposed record, never the concertmaster itself):
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
# The ledger is written under a mkdir lock (<ledger>.lock), atomically, keeping its file mode.
# Env: CM_HOME, CM_PATH_MATCH, CM_SELF_PATH_RE (default: the config worktrees.self_name directory),
#      CM_RUNTIME_SWEEP (the sweep script, tests), CM_CLAUDE_PROJECTS, CM_BOOT_CONFIRM_S (via boot-sweep.sh).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  -h|--help) sed -n '2,44p' "$0"; exit 0 ;;
  '') ;;
  *) cm_warn "runtime-check.sh: unknown arg: $1"; exit 2 ;;
esac
command -v jq >/dev/null 2>&1 || { cm_warn "runtime-check.sh: missing dependency: jq"; exit 0; }
[ -n "$CM_PATH_MATCH" ] || { cm_warn "runtime-check.sh: set worktrees.path_match in config.yaml (or CM_PATH_MATCH)"; exit 0; }
LEDGER="$CM_HOME/ledger.json"
if ! [ -r "$LEDGER" ] || ! jq -e 'type == "object"' "$LEDGER" >/dev/null 2>&1; then
  cm_warn "runtime-check.sh: ledger $LEDGER missing or unreadable: nothing checked"; exit 1
fi

ORCA="$(cm_orca)"
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
    | select(.value.standing == true and ((.value.host // "local") == "local") and (((.value.state // "") | IN("gone", "repurposed")) | not))
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
