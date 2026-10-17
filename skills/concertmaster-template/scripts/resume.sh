#!/usr/bin/env bash
# resume.sh: bring lanes back after a restart, from $CM_HOME/roster.yaml.
#
#   scripts/resume.sh                          # act on every roster row, print the table
#   scripts/resume.sh --dry-run                # same decisions, no orca create or send
#   scripts/resume.sh --host <h> --worktree-id <id> --path <wt>
#                                              # one row only (what the tick's standing-dead uses)
#   scripts/resume.sh --lane <label>           # one row only, by lane label
#
# A full run can take minutes (each dead row waits for its TUI): run it in the
# background or with a 600000 ms Bash timeout. Rows are streamed to stderr as
# they are decided; the table is printed at the end. CM_RESUME_BUDGET_S (540)
# caps the acting time: a row only starts when its worst case (CM_RESUME_ROW_MAX_S,
# derived from the timeouts, 385 s by default) still fits, the rest are `deferred`.
#
# Per roster row (procedure and safety rules: references/resume.md):
#   host unreachable            offline    skip, retry next tick
#   worktree not on the host    missing    leave alone, ask the owner
#   2+ live agents in the tree  duplicate  send to neither, ask the owner
#   2+ roster rows, one tree    duplicate  same: one decision, no create
#   1 live agent                live       leave alone
#   no live agent               dead       claude --continue [--model m] in the
#                                          SAME worktree after a fresh re-check, then
#                                          ONE nudge naming `current`
#   resumed, nudge not sent     held       the terminal is open; the concertmaster reads
#                                          the pane and sends the nudge itself
#   dead, agent not claude      manual     resume by hand (also when agent is unset)
#   any input unreadable        unknown    left alone: no live count, no liveTerminalCount
#                                          and no agent entry, a remote terminal with no
#                                          agent entry, a truncated census, no host, or no
#                                          process check
#   resume could not start      failed     re-census, then a handover respawn
#
# "Live" needs an agent entry plus a live terminal (liveTerminalCount > 0), or a
# live-state agent when the count is absent, or, on the local host, a claude
# process of this user whose cwd is the worktree or inside it. Orca's explicit
# liveTerminalCount of 0 means dead (agent entries go stale after a restart).
# Every unreadable input fails closed, never toward a second agent. The process
# backstop is local only. The roster is rewritten from the ledger on every run
# (roster.sh) so a row the tick just retired is never resumed; no readable ledger:
# the roster is used as is. One acting run at a time per CM_HOME (lock dir).
#
# Env: CM_HOME, CM_HOST_TIMEOUT (25s), CM_TERM_WAIT_MS (60000), CM_RESUME_BUDGET_S,
# CM_RESUME_ROW_MAX_S, CM_TEST=1 with CM_TEST_CLAUDE_CWDS_CMD (tests only: replaces the process check).
# Exit 0 when every row is live, resumed or offline; 3 when any row needs attention
# (failed, held, missing, unknown, manual, duplicate); 6 when rows were deferred
# (run again); 5 when a filter matched no row (respawn that lane by hand); 1 when no
# roster could be had; 4 when another run holds the lock (resume is in progress:
# do nothing for that lane this tick).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

DRY=0; F_LANE=""; F_PATH=""; F_HOST=""; F_WID=""
need() { [ -n "${2:-}" ] || { cm_warn "resume.sh: $1 needs a value"; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --lane) need "$1" "${2:-}"; F_LANE="$2"; shift ;;
    --path) need "$1" "${2:-}"; F_PATH="$2"; shift ;;
    --host) need "$1" "${2:-}"; F_HOST="$2"; shift ;;
    --worktree-id) need "$1" "${2:-}"; F_WID="$2"; shift ;;
    -h|--help) sed -n '2,47p' "$0"; exit 0 ;;
    *) cm_warn "resume.sh: unknown arg: $1"; exit 2 ;;
  esac
  shift
done
command -v jq >/dev/null 2>&1 || { cm_warn "resume.sh: missing dependency: jq"; exit 1; }

umask 077
ORCA="$(cm_orca)"
HOST_TIMEOUT="${CM_HOST_TIMEOUT:-25}"
WAIT_MS="${CM_TERM_WAIT_MS:-60000}"
BUDGET="${CM_RESUME_BUDGET_S:-540}"
# worst case of one row: re-check, create, two waits (each + 15s margin), read, send
ROW_MAX="${CM_RESUME_ROW_MAX_S:-$((HOST_TIMEOUT + 60 + 3 * WAIT_MS / 1000 + 30 + 30 + 60))}"
RETRY_MIN="${CM_RESUME_RETRY_MIN:-30}"
ROSTER="$CM_HOME/roster.yaml"
LEDGER="$CM_HOME/ledger.json"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cm-resume.XXXXXX")" || { cm_warn "resume: cannot create a temp dir"; exit 1; }
LOCK="$CM_HOME/resume.lock"
HAVE_LOCK=0
START=$SECONDS
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
  # Lock first: nothing after it may stop the release.
  if [ "$HAVE_LOCK" = 1 ] && [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ]; then rm -rf -- "${LOCK:?}"; fi
  [ -z "$TMP" ] || rm -rf -- "${TMP:?}"
  return 0
}
trap cleanup EXIT
if [ -n "${CM_TEST_CLAUDE_CWDS_CMD:-}" ]; then
  if [ "${CM_TEST:-}" = 1 ]; then cm_warn "resume: CM_TEST_CLAUDE_CWDS_CMD is set, the real process check is replaced"
  else cm_warn "resume: CM_TEST_CLAUDE_CWDS_CMD ignored (it needs CM_TEST=1)"; unset CM_TEST_CLAUDE_CWDS_CMD; fi
fi

# ---- lock: one acting run at a time --------------------------------------------
# The tick's standing-dead call and the owner's /concertmaster resume must never
# both create an agent for one lane. The pid is written by temp + mv so a
# contender never sees a half-made lock; an empty pid on a young lock means
# "being made", not stale; the holder must still look like a resume run (pid reuse).
lock_pid() { cat "$1/pid" 2>/dev/null || true; }
lock_held() {
  local pid
  pid="$(lock_pid "$LOCK")"
  if [ -z "$pid" ]; then [ -n "$(find "$LOCK" -maxdepth 0 -mmin -1 2>/dev/null)" ]; return; fi
  kill -0 "$pid" 2>/dev/null || return 1
  ps -p "$pid" -o args= 2>/dev/null | grep -q resume || { ps -p "$pid" -o args= >/dev/null 2>&1 && return 1; }
  return 0
}
if [ "$DRY" = 0 ]; then
  mkdir -p "$CM_HOME"
  if ! mkdir "$LOCK" 2>/dev/null; then
    if lock_held; then cm_warn "resume: already running; nothing done"; exit 4; fi
    judged="$(lock_pid "$LOCK")"
    # stale: the rename is atomic, so only one reclaimer takes it. Afterwards check
    # that what we moved is the lock we judged stale, else put it back and stand down.
    if mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null; then
      if [ "$(lock_pid "$LOCK.stale.$$")" = "$judged" ]; then rm -rf -- "${LOCK:?}.stale.$$"
      else
        mv "$LOCK.stale.$$" "$LOCK" 2>/dev/null || rm -rf -- "${LOCK:?}.stale.$$"
        cm_warn "resume: lock changed while reclaiming; standing down"; exit 4
      fi
    else
      cm_warn "resume: lock reclaimed by another run"; exit 4
    fi
    mkdir "$LOCK" 2>/dev/null || { cm_warn "resume: cannot take $LOCK"; exit 4; }
  fi
  # The pid write can fail (another run reclaimed the directory under us): never
  # act on a lock we cannot prove is ours.
  { printf '%s\n' "$$" > "$LOCK/pid.$$" && mv "$LOCK/pid.$$" "$LOCK/pid"; } 2>/dev/null
  if [ "$(lock_pid "$LOCK")" != "$$" ]; then cm_warn "resume: lost the lock while taking it; standing down"; exit 4; fi
  HAVE_LOCK=1
fi
# owns_lock: still ours? Checked again right before every terminal create.
owns_lock() { [ "$DRY" = 1 ] || [ "$(lock_pid "$LOCK")" = "$$" ]; }

# ---- 1. roster: always rewritten from the ledger when it is readable ---------
# Cheap and atomic. A stale roster could still list a worker the tick retired a
# moment ago, and resuming it would revive a lane that was closed on purpose.
if [ -s "$LEDGER" ]; then
  if ! "$HERE/roster.sh"; then
    if [ -s "$ROSTER" ]; then cm_warn "resume: ledger unreadable; using the roster as is"
    else cm_warn "resume: no roster and no readable ledger; nothing to resume"; exit 1; fi
  fi
elif [ ! -s "$ROSTER" ]; then
  cm_warn "resume: no roster and no ledger; nothing to resume"
  exit 1
fi

# One path normaliser for both sides of every comparison: /w/./dev, /w//dev and /w/dev/ are one path.
NORMP='def normp: gsub("/\\.(?=/|$)"; "") | gsub("//+"; "/") | sub("(?<=.)/+$"; "");'
normp() { jq -rn --arg p "$1" "$NORMP"' $p | normp'; }

# Parse our own roster format (roster.sh) into a JSON array; label disambiguates
# lanes that have more than one row.
if ! jq -R -s '
  def kv: capture("^(?<k>[A-Za-z]+): ?(?<v>.*)$") | {(.k): (.v | . as $raw | try fromjson catch $raw)};
  reduce (split("\n")[] | select(length > 0 and (startswith("#") | not))) as $l ([];
    if $l == "[]" then .
    elif ($l | startswith("- ")) then . + [($l[2:] | kv)]
    else .[-1] += ($l | ltrimstr("  ") | kv) end)
  | (map(.lane) | group_by(.) | map({key: (.[0] // ""), value: length}) | from_entries) as $n
  | map(. + {label: (if ($n[.lane // ""] // 0) > 1
                     then "\(.lane):\((.worktree // "?") | sub("/+$"; "") | split("/") | last)"
                     else (.lane // "?") end)})
  | to_entries | map(.value + {idx: .key})' "$ROSTER" > "$TMP/rows.json" 2>"$TMP/parse.err"; then
  cm_warn "resume: roster $ROSTER is not in the roster.sh format: $(head -c 200 "$TMP/parse.err")"
  exit 1
fi

# Rows that share one worktree on one host: one decision for the group, never a create.
# Computed before any filter so a --path run still sees its siblings.
jq -r "$NORMP"' [.[] | select((.host // "") != "" and (.worktree // "") != "")]
       | group_by([.host, (.worktree | normp)]) | map(select(length > 1)) | .[]
       | "\(.[0].host)\t\(.[0].worktree | normp)"' "$TMP/rows.json" > "$TMP/shared.tsv"
cp "$TMP/rows.json" "$TMP/rows.all.json"

NEEDS=0; DEFERRED=0
if [ -n "$F_LANE" ] || [ -n "$F_PATH" ] || [ -n "$F_HOST" ] || [ -n "$F_WID" ]; then
  if ! jq --arg l "$F_LANE" --arg p "${F_PATH%/}" --arg h "$F_HOST" --arg w "$F_WID" "$NORMP"'
      map(select(($l == "" or .label == $l or .lane == $l)
                 and ($h == "" or .host == $h)
                 and (($p == "" and $w == "")
                      or ($w != "" and .worktreeId == $w)
                      or ($p != "" and ((.worktree // "") | normp) == ($p | normp)))))' \
      "$TMP/rows.json" > "$TMP/rows.f" 2>/dev/null; then cm_warn "resume: filter failed"; exit 1; fi
  mv "$TMP/rows.f" "$TMP/rows.json"
  if [ "$(jq 'length' "$TMP/rows.json")" = 0 ]; then
    echo "no roster row matches the filter: nothing resumed, respawn by hand if the lane is dead"; exit 5
  fi
fi

# ---- 2. one worktree census per host -------------------------------------------
# fetch_ps <host> <file>: 0 and a valid document in <file>, else non-zero.
fetch_ps() {
  local rc
  if [ "$1" = local ]; then
    cm_timeout "$HOST_TIMEOUT" "$ORCA" worktree ps --limit 500 --json </dev/null > "$2" 2>"$2.err"
  else
    cm_timeout "$HOST_TIMEOUT" "$ORCA" worktree ps --environment "$1" --limit 500 --json </dev/null > "$2" 2>"$2.err"
  fi
  rc=$?
  [ "$rc" -eq 0 ] && jq -e '.ok == true and (.result.worktrees | type == "array")' "$2" >/dev/null 2>&1
}
: > "$TMP/hosts.tsv"
i=0
for host in $(jq -r '[.[].host | select(. != null and . != "")] | unique[]' "$TMP/rows.json"); do
  i=$((i + 1))
  ps="$TMP/ps-$i.json"
  up=0; why=""
  if fetch_ps "$host" "$ps"; then up=1; else why="$(head -c 60 "$ps.err" 2>/dev/null | tr '\t\n' '  ')"; fi
  printf '%s\t%s\t%s\t%s\n' "$host" "$ps" "$up" "$why" >> "$TMP/hosts.tsv"
done

# ---- 2b. resolve every roster row to the worktree Orca matched ------------------
# Rows are grouped by host plus the matched worktree (Orca id, else normalised Orca
# path), not by roster path: two rows that differ by path text, or by a stale ledger
# path, can still be one worktree. Siblings are resolved even under a filter. A group
# of two or more gets one decision and no create.
: > "$TMP/resolved.tsv"
find_wt() {
  jq -c --arg id "$2" --arg p "$3" "$NORMP"'
    ([.result.worktrees[] | select($id != "" and .worktreeId == $id)] | first)
    // ([.result.worktrees[] | select(((.path // "") | normp) == ($p | normp))] | first) // null' "$1"
}
rf() { printf '%s' "$1" | jq -r --arg k "$2" '.[$k] // "" | if type == "array" then map(tostring) | join(",") else tostring end'; }
wt_key() { # <wt-json>: a stable key for the matched worktree
  local k
  k="$(printf '%s' "$1" | jq -r '.worktreeId // empty')"
  if [ -n "$k" ]; then printf 'id:%s' "$k"; else printf 'path:%s' "$(normp "$(printf '%s' "$1" | jq -r '.path // ""')")"; fi
}
while IFS= read -r r <&4; do
  h="$(rf "$r" host)"; [ -n "$h" ] || continue
  hl="$(awk -F'\t' -v h="$h" '$1 == h' "$TMP/hosts.tsv" | head -n 1)"
  [ "$(printf '%s' "$hl" | cut -f3)" = 1 ] || continue
  w="$(find_wt "$(printf '%s' "$hl" | cut -f2)" "$(rf "$r" worktreeId)" "$(normp "$(rf "$r" worktree)")")"
  { [ "$w" != null ] && [ -n "$w" ]; } || continue
  printf '%s\t%s\t%s\n' "$(rf "$r" idx)" "$h" "$(wt_key "$w")" >> "$TMP/resolved.tsv"
done 4< <(jq -c '.[]' "$TMP/rows.all.json")
awk -F'\t' '{ c[$2 FS $3]++ } END { for (k in c) if (c[k] > 1) print k }' "$TMP/resolved.tsv" > "$TMP/groups.tsv"
: > "$TMP/created.tsv"

# ---- helpers --------------------------------------------------------------------
# Local claude processes of this user, their cwds one per line. Non-zero when the
# check could not be done (no pgrep, an unreadable /proc entry, no lsof, a failing
# override): then "no process" proves nothing and the caller must fail closed.
claude_cwds() {
  if [ -n "${CM_TEST_CLAUDE_CWDS_CMD:-}" ] && [ "${CM_TEST:-}" = 1 ]; then sh -c "$CM_TEST_CLAUDE_CWDS_CMD" </dev/null 2>/dev/null; return; fi
  command -v pgrep >/dev/null 2>&1 || return 1
  local pids rc p
  pids="$(pgrep -u "$(id -u)" -x claude 2>/dev/null)"; rc=$?
  [ "$rc" -le 1 ] || return 1                       # 1 = no process matched
  for p in $pids; do
    if [ -d /proc/self ]; then
      readlink "/proc/$p/cwd" 2>/dev/null || { [ -e "/proc/$p" ] && return 1; }   # a vanished pid is fine
    else
      command -v lsof >/dev/null 2>&1 || return 1
      lsof -a -p "$p" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'
    fi
  done
  return 0
}
# cwd_matches <canonical-path>: counts stdin lines equal to the path or inside it
cwd_matches() { awk -v p="$1" '{ c = $0; sub("/+$", "", c); if (c == p || index(c, p "/") == 1) n++ } END { print n + 0 }'; }
canon() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }
proc_has_cwd() { [ "$(claude_cwds 2>/dev/null | cwd_matches "$(canon "$1")")" -ge 1 ]; }


# short name for the action cell: the first #<n> in `current`, else its first 30 chars
short_current() {
  local m
  m="$(printf '%s' "$1" | grep -o '#[0-9][0-9]*' | head -n 1)"
  [ -n "$m" ] && { printf '%s' "$m"; return; }
  printf '%s' "$1" | cut -c1-30
}

CWDS=""; CWDS_DONE=0; CWDS_OK=1
# live_count <wt-json> <host> <path> <fresh 0|1>: sets LC_N (a number) or LC_ERR; also
# LC_TERMS and LC_ENTRIES. Every unreadable input leaves LC_N empty.
live_count() {
  local wt="$1" host="$2" path="$3" fresh="$4" verdict n_agents n_pid
  LC_N=""; LC_ERR=""; LC_TERMS=0; LC_ENTRIES=0
  verdict="$(printf '%s' "$wt" | jq -r '
    def live_states: ["working", "waiting", "permission", "blocked", "running"];
    (.agents // []) as $a
    | if ($a | map(select(type != "object")) | length) > 0 then error("agents not objects") else . end
    | ([ $a[] | select(.parentPaneKey == null) ]) as $top
    | ($top | map(.paneKey) | unique | length) as $panes
    | ([ $top[] | select(.state as $s | live_states | index($s)) ] | map(.paneKey) | unique | length) as $liveSt
    | .liveTerminalCount as $ltc
    | if ($ltc != null and ($ltc | type) != "number") then error("bad liveTerminalCount")
      elif $ltc != null then (if $ltc > 0 and ($a | length) > 0 then ([$panes, 1] | max) else 0 end | "n=\(.)")
      elif $liveSt > 0 then "n=\($liveSt)"
      elif ($a | length) > 0 then "unknown"
      else "empty" end' 2>/dev/null)"
  LC_TERMS="$(printf '%s' "$wt" | jq -r '.liveTerminalCount // 0' 2>/dev/null)"
  LC_ENTRIES="$(printf '%s' "$wt" | jq -r '(.agents // []) | length' 2>/dev/null)"
  case "$LC_TERMS$LC_ENTRIES" in ''|*[!0-9]*) verdict="" ;; esac
  n_agents=""
  case "$verdict" in
    n=[0-9]*) n_agents="${verdict#n=}" ;;
    empty) if [ "$host" = local ]; then n_agents=0; fi ;;   # remote rows often lack fields: unknown
  esac
  if [ -z "$n_agents" ]; then LC_ERR="live count unreadable, left alone"; return; fi
  n_pid=0
  if [ "$host" = local ]; then
    if [ "$fresh" = 1 ] || [ "$CWDS_DONE" = 0 ]; then
      if CWDS="$(claude_cwds)"; then CWDS_OK=1; else CWDS_OK=0; fi
      CWDS_DONE=1
    fi
    n_pid="$(printf '%s\n' "$CWDS" | cwd_matches "$(canon "$path")")"
  fi
  LC_N=$n_agents; [ "$n_pid" -gt "$LC_N" ] && LC_N=$n_pid
}
# zero_unsafe <host>: after live_count found no live agent, says why "dead" cannot be trusted
zero_unsafe() {
  if [ "$1" = local ] && [ "$CWDS_OK" = 0 ]; then echo "process check unavailable, left alone"; return; fi
  if [ "$1" != local ] && [ "$LC_TERMS" -gt 0 ] && [ "$LC_ENTRIES" -eq 0 ]; then echo "terminal open, no agent entry, check by hand"; return; fi
}

OUT="$TMP/out.tsv"; : > "$OUT"
ASKS="$TMP/asks.txt"; : > "$ASKS"
emit() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$OUT"; printf 'resume: %s %s %s\n' "$1" "$2" "$3" >&2
  case "$2" in failed|held|missing|unknown|manual|duplicate) NEEDS=1 ;; deferred) DEFERRED=1 ;; esac
}
MENU_RE='enter to select|enter to confirm|esc to cancel|arrow keys|tab/arrow'
CLAUDE_RE='claude code|\? for shortcuts|esc to interrupt|shift\+tab|bypass permissions|accept edits|auto-accept'

# resume_dead <row-json> <host> <wt-json>: sets RES_STATUS and RES_ACTION
resume_dead() {
  local row="$1" host="$2" wt="$3" path cur state wid sel h out attempt opath wkey wait_ok screen text bottom nudge short ms model cmd cur_s state_s why wt2 ok_chars
  local envargs=()
  path="$(normp "$(rf "$row" worktree)")"; cur="$(rf "$row" current)"; state="$(rf "$row" state)"
  wid="$(printf '%s' "$wt" | jq -r '.worktreeId // empty')"; opath="$(printf '%s' "$wt" | jq -r '.path // empty')"
  [ -z "$opath" ] || path="$(normp "$opath")"
  short="$(short_current "$cur")"
  # Ledger text reaches a terminal only through a character allow-list: no shell
  # metacharacter, backtick, dollar, quote, backslash, redirect or pipe survives.
  ok_chars='A-Za-z0-9 #:.,_/()+@=-'
  cur_s="$(printf '%s' "$cur" | tr -cd "$ok_chars")"; state_s="$(printf '%s' "$state" | tr -cd "$ok_chars")"
  [ "$host" = local ] || envargs=(--environment "$host")
  if [ -n "$wid" ]; then sel="id:$wid"; else sel="path:$path"; fi
  cmd="claude --continue"
  model="$(rf "$row" model)"
  case "$model" in [A-Za-z]*) case "$model" in *[!A-Za-z0-9._-]*) ;; *) cmd="$cmd --model $model" ;; esac ;; esac

  if [ "$DRY" = 1 ]; then
    RES_STATUS=dead; RES_ACTION="would $cmd, nudge (${short:-no current item})"; return
  fi
  # Re-check right before acting: the census is minutes old by the time a late row
  # is reached, and a lane may have been reopened by hand or by the tick since.
  if ! fetch_ps "$host" "$TMP/recheck.json"; then RES_STATUS=unknown; RES_ACTION="host stopped answering before the resume, left alone"; return; fi
  wt2="$(find_wt "$TMP/recheck.json" "$(rf "$row" worktreeId)" "$path")"
  if [ "$wt2" = null ] || [ -z "$wt2" ]; then RES_STATUS=unknown; RES_ACTION="worktree gone at the re-check, left alone"; return; fi
  opath="$(printf '%s' "$wt2" | jq -r '.path // empty')"; [ -z "$opath" ] || path="$(normp "$opath")"
  live_count "$wt2" "$host" "$path" 1
  if [ -z "$LC_N" ]; then RES_STATUS=unknown; RES_ACTION="$LC_ERR"; return; fi
  if [ "$LC_N" -ge 1 ]; then RES_STATUS=live; RES_ACTION="live agent appeared since the census, left alone"; return; fi
  why="$(zero_unsafe "$host")"
  if [ -n "$why" ]; then RES_STATUS=unknown; RES_ACTION="$why"; return; fi

  owns_lock || { RES_STATUS=unknown; RES_ACTION="lost the resume lock, left alone"; return; }
  wkey="$host $(wt_key "$wt2")"
  if grep -qxF "$wkey" "$TMP/created.tsv"; then RES_STATUS=unknown; RES_ACTION="a terminal was already created for this worktree in this run, left alone"; return; fi
  attempt="$CM_HOME/resume.attempts/$(printf '%s_%s' "$host" "$path" | tr -c 'A-Za-z0-9._-' '_')"
  if [ -n "$(find "$attempt" -mmin "-$RETRY_MIN" 2>/dev/null)" ]; then
    RES_STATUS=failed; RES_ACTION="resume already tried in the last $RETRY_MIN min ($(cat "$attempt" 2>/dev/null)); not repeating, read the pane or respawn by hand"; return
  fi
  printf 'resume: %s creating a terminal in %s\n' "$(rf "$row" label)" "$path" >&2
  out="$(cm_timeout 60 "$ORCA" terminal create --worktree "$sel" --title resume --command "$cmd" ${envargs[@]+"${envargs[@]}"} --json </dev/null 2>/dev/null)"
  h="$(printf '%s' "$out" | jq -r '.result.terminal.handle // .result.handle // .result.startupTerminal.handle // empty' 2>/dev/null)"
  printf '%s\n' "$wkey" >> "$TMP/created.tsv"
  mkdir -p "$CM_HOME/resume.attempts" && printf 'terminal %s' "${h:-none}" > "$attempt"
  if [ -z "$h" ]; then
    RES_STATUS=failed; RES_ACTION="claude --continue did not start; re-census, then respawn with a handover"; return
  fi
  wait_ok=0
  for ms in "$WAIT_MS" $((WAIT_MS * 2)); do
    out="$(cm_timeout $((ms / 1000 + 15)) "$ORCA" terminal wait --terminal "$h" --for tui-idle --timeout-ms "$ms" ${envargs[@]+"${envargs[@]}"} --json </dev/null 2>/dev/null)"
    if [ "$(printf '%s' "$out" | jq -r '(.result.wait.satisfied // .result.satisfied // .wait.satisfied // false) | tostring' 2>/dev/null)" = true ]; then wait_ok=1; break; fi
  done
  if [ "$wait_ok" = 0 ]; then
    RES_STATUS=failed; RES_ACTION="claude --continue never went idle (terminal $h left open), nudge not sent; re-census before any respawn"; return
  fi
  # Gate the send on the bottom of the screen (the replayed transcript above it
  # proves nothing), and fail closed: no readable screen, a question menu, a shell
  # prompt or no sign of Claude at the prompt means no send.
  screen="$(cm_timeout 30 "$ORCA" terminal read --terminal "$h" --screen ${envargs[@]+"${envargs[@]}"} --json </dev/null 2>/dev/null)"
  text="$(printf '%s' "$screen" | jq -r 'if .ok == true then ((.result.screen // .result.text // .result.output // "") | tostring) else "" end' 2>/dev/null)"
  bottom="$(printf '%s\n' "$text" | grep -v '^[[:space:]]*$' | tail -n 12)"
  if [ -z "$bottom" ]; then
    RES_STATUS=held; RES_ACTION="$cmd started in terminal $h, nudge not sent (screen unreadable); read the pane, then nudge"; return
  fi
  if printf '%s' "$bottom" | grep -qiE "$MENU_RE"; then
    RES_STATUS=held; RES_ACTION="$cmd started in terminal $h, nudge not sent (question menu showing); answer or cancel it, then nudge"; return
  fi
  if printf '%s\n' "$bottom" | tail -n 1 | grep -qE '^[^[:space:]]*[$#%] *$'; then
    RES_STATUS=failed; RES_ACTION="shell prompt on screen, not Claude (terminal $h left open), nudge not sent; re-census before any respawn"; return
  fi
  if ! printf '%s' "$bottom" | grep -qiE "$CLAUDE_RE"; then
    if [ "$host" != local ] || ! proc_has_cwd "$path"; then
      RES_STATUS=failed; RES_ACTION="no Claude prompt on screen (terminal $h left open), nudge not sent; re-census before any respawn"; return
    fi
  fi
  case "$state" in
    cm:idle*|cm:blocked*)
      nudge="Resumed after a restart. Your last status was: ${state_s}. Check git status, re-read your worktree comment and your beads, restore that status if nothing is running, and start new work only if there is any." ;;
    *)
      nudge="Resumed after a restart. You were on: ${cur_s:-your last item}. Last status: ${state_s:-unknown}. Check git status and your worktree comment, then carry on from where you stopped and set cm:running with the next step." ;;
  esac
  out="$(cm_timeout 60 "$ORCA" terminal send --terminal "$h" --text "$nudge" --enter ${envargs[@]+"${envargs[@]}"} --json </dev/null 2>/dev/null)"
  if [ "$(printf '%s' "$out" | jq -r '.ok // false | tostring' 2>/dev/null)" = true ]; then
    RES_STATUS=dead; RES_ACTION="$cmd, nudged (${short:-no current item})"; rm -f "$attempt"
  else
    RES_STATUS=held; RES_ACTION="$cmd started in terminal $h, nudge not accepted; read the pane, then nudge"
  fi
}

# ---- 3. decide and act, row by row -----------------------------------------------
while IFS= read -r row <&3; do
  label="$(rf "$row" label)"; host="$(rf "$row" host)"
  path="$(normp "$(rf "$row" worktree)")"
  if [ -z "$host" ]; then emit "$label" unknown "host unknown in the ledger, left alone"; continue; fi
  line="$(awk -F'\t' -v h="$host" '$1 == h' "$TMP/hosts.tsv" | head -n 1)"
  psf="$(printf '%s' "$line" | cut -f2)"; up="$(printf '%s' "$line" | cut -f3)"; why="$(printf '%s' "$line" | cut -f4)"
  if [ "$up" != 1 ]; then emit "$label" offline "retry next tick${why:+ ($why)}"; continue; fi

  if [ -n "$path" ] && grep -qxF "$(printf '%s\t%s' "$host" "$path")" "$TMP/shared.tsv"; then
    emit "$label" duplicate "roster rows share this worktree, sent to none, ask $CM_OWNER_NAME"
    printf '%s\n' "$label: several roster rows point at $path on $host; which lane owns it?" >> "$ASKS"
    continue
  fi
  wt="$(find_wt "$psf" "$(rf "$row" worktreeId)" "$path")"
  if [ "$wt" != null ] && [ -n "$wt" ] && grep -qxF "$(printf '%s\t%s' "$host" "$(wt_key "$wt")")" "$TMP/groups.tsv"; then
    emit "$label" duplicate "roster rows resolve to one worktree, sent to none, ask $CM_OWNER_NAME"
    printf '%s\n' "$label: several roster rows resolve to the same worktree on $host ($(printf '%s' "$wt" | jq -r '.path // "?"')); which lane owns it?" >> "$ASKS"
    continue
  fi
  if [ "$wt" = null ] || [ -z "$wt" ]; then
    if [ "$(jq -r '(.result.truncated == true) or ((.result.totalCount // 0) > (.result.worktrees | length)) | tostring' "$psf")" = true ]; then
      emit "$label" unknown "census truncated, worktree not seen, left alone"
    else
      emit "$label" missing "worktree not on host, left alone, ask $CM_OWNER_NAME"
      printf '%s\n' "$label: worktree $path not found on $host; confirm whether the lane still exists" >> "$ASKS"
    fi
    continue
  fi
  # From here on use the path of the worktree Orca matched: a ledger path can be stale
  # (matched by id), and the process check must look at the real directory.
  opath="$(printf '%s' "$wt" | jq -r '.path // empty')"; [ -z "$opath" ] || path="$(normp "$opath")"
  live_count "$wt" "$host" "$path" 0
  if [ -z "$LC_N" ]; then emit "$label" unknown "$LC_ERR"; continue; fi

  if [ "$LC_N" -ge 2 ]; then
    emit "$label" duplicate "sent to neither, ask $CM_OWNER_NAME"
    printf '%s\n' "$label: $LC_N live agents in $path; which one keeps going?" >> "$ASKS"
  elif [ "$LC_N" -eq 1 ]; then
    emit "$label" live "left alone"
  elif [ -n "$(zero_unsafe "$host")" ]; then
    # "no claude process" proves nothing when the check could not run, and a remote
    # terminal with no agent entry may be an agent Orca has not reported yet
    emit "$label" unknown "$(zero_unsafe "$host")"
  else
    agent="$(rf "$row" agent)"
    case "$agent" in
      claude)
        if [ "$DRY" = 0 ] && [ $((SECONDS - START + ROW_MAX)) -gt "$BUDGET" ]; then
          emit "$label" deferred "run budget used, retry next run"
        else
          resume_dead "$row" "$host" "$wt"; emit "$label" "$RES_STATUS" "$RES_ACTION"
        fi ;;
      '') emit "$label" manual "agent unknown (ledger has none), resume by hand" ;;
      *) emit "$label" manual "agent is $agent, claude --continue would start the wrong agent; resume by hand" ;;
    esac
  fi
done 3< <(jq -c '.[]' "$TMP/rows.json")

# ---- 4. table ----------------------------------------------------------------------
if [ ! -s "$OUT" ]; then echo "roster is empty: nothing to resume"; exit 0; fi
awk -F'\t' '{ if (length($1) > a) a = length($1); if (length($2) > b) b = length($2); r[NR] = $0 }
  END { for (i = 1; i <= NR; i++) { split(r[i], f, "\t"); printf "  %-*s  %-*s  %s\n", a, f[1], b, f[2], f[3] } }' "$OUT"
if [ -s "$ASKS" ]; then
  echo
  while IFS= read -r a; do printf 'ask %s: %s\n' "$CM_OWNER_NAME" "$a"; done < "$ASKS"
fi
[ "$NEEDS" = 0 ] || exit 3
[ "$DEFERRED" = 0 ] || exit 6
exit 0
