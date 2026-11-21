#!/usr/bin/env bash
# codemode-recover.sh: close the Claude Code "Code Mode" opt-in dialog that stops a lane after a host reboot, then re-arm it.
#
#   scripts/codemode-recover.sh --terminal <handle> --lane <worker id> --text <nudge> [--host <host>] [--dry-run]
#
# Why: after a host reboot the resumer reopens every lane with "claude --resume", and every lane
# stops on the Claude Code "Code Mode" opt-in dialog ("Enter to confirm", "Esc to start without it"). runtime-check.sh, boot-sweep.sh
# and resume.sh read that screen as a question menu and never type into one, so the lanes stayed stale for hours. The default of the dialog is "start without it", which is the Esc key.
#
# One terminal per call, local or remote (--host is the environment name, sent as --environment; the same CLI path resume.sh and
# spawn-verify.sh use, no new transport). Steps, each one fails closed:
#   1. read the pane. The dialog is matched NARROWLY (codemode_dialog below): the LAST footer line "Esc to start without it" that begins
#      (after border characters) with "Enter to confirm" or "Esc to start without it", with "Enter to confirm" on it or starting the line
#      above, the words "Code Mode" within 8 lines above it and not past the top border of the dialog, and NOTHING but blank lines and
#      border characters below it. A sentence that quotes the
#      words, a permission prompt, a model picker, a trust dialog and every other menu fail that match and are never touched; so does old
#      dialog text that scrolled up under a live prompt. No match: prints "none", sends nothing;
#   2. resume.lock (scripts/resume.sh is running): nothing is sent ("held"), checked here, again right before the Esc and again before the
#      nudge;
#   3. the send goes to the handle cm_lane_handle returns for --lane (the lane handle file; a missing or stale file is re-checked against
#      the live agent by lane-handles.sh --worker first). Only a fresh handle that IS this terminal, on THIS host, is accepted; a dead (-),
#      still-stale, other-terminal or other-host file is "held". This script never writes a lane handle (lane-handles.sh and resume.sh own
#      that). ONE recovery per terminal runs at a time, from the last read through the nudge (a mkdir lock with the owner pid, released at
#      exit; a second run for the same terminal is "held");
#   4. the Esc is reserved against the cap, THEN the pane is read once more and the lock checked once more right before the key (a dialog
#      that is gone or a lock that appeared, or a lane handle or host that changed, gives the count back (the 6 h window keeps the reservation
#      time) and sends nothing; a count whose Esc was never sent because the refund failed or the run was cut stays spent, so the cap errs
#      toward fewer keys). The cap: at most 2
#      per terminal in 6 hours counted from the last one, kept in cache/codemode-recover.tsv through a recovery, written under a mkdir lock
#      with a unique temp file and read back. A dialog that survives them is "menu", left to a person. A count that cannot be recorded
#      (also a state path that is not a regular file) means no Esc ("held"). Then ONE Esc (a single key, text only, no Enter), and the pane
#      is read again up to CM_CODEMODE_POLLS times, CM_CODEMODE_SETTLE_S apart. The dialog still showing after the last read is "menu"
#      (reported once, not retried, no nudge, no loop);
#   5. only with the dialog gone AND a Claude footer as the last line AND no menu and no mid-turn marker on a fresh read right before
#      the send, the lane handle unchanged and no resume.lock: send --text and Enter, once ("recovered"). Anything else is "closed" or
#      "held" with the reason, and nothing more is sent.
# --text is ONE LINE OF PLAIN TEXT: a control byte in it is refused with nothing read or sent (gsend.sh's rule). This is the one script
# that sends an Escape to a Code Mode dialog (the tick's Escape to a menu in no-human mode, and to the autocompact prompt, are other
# rules: SKILL.md hard rules and references/prompt-stalls.md); every other send in the skill refuses it.
# Output: one line, result TAB detail. Results: none, would-recover (--dry-run), recovered, closed, menu, held, unreadable, send-failed.
# Exit 0 for every result; 2 for bad usage.
# Env: CM_CODEMODE_SETTLE_S (2), CM_CODEMODE_POLLS (5), CM_CODEMODE_MAX_ESC (2 per 6 h), CM_HOME, CM_CLI_KIND.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

# Helpers the template lib.sh may not carry: defined here only when lib.sh lacks them (same behaviour as the concertmaster skill lib.sh).
if ! declare -F cm_handle_ok >/dev/null; then
  cm_handle_ok() { [[ "${1-}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.:@=-]{0,127}$ ]]; }
fi
if ! declare -F cm_pane_last >/dev/null; then
  cm_pane_last() {
    printf '%s\n' "$1" | awk '
      { line[NR] = $0 }
      END {
        n = NR
        while (n > 0 && (line[n] ~ /^[ \t\r]*$/ || tolower(line[n]) ~ /^[[:space:]]*new task[?] \/clear to save/)) n--
        if (n > 0) print line[n]
      }'
  }
fi
if ! declare -F cm_menu_on_screen >/dev/null; then
  cm_menu_on_screen() {
    local n
    printf '%s\n' "$1" | grep -qiE "$CM_MENU_RE" && return 0
    n="$(printf '%s\n' "$1" | awk -v num='^[[:space:]│|]*(>|❯|›|▸)?[[:space:]]*[0-9]+[.)][[:space:]]' -v emp='^[[:space:]│|]*(>|❯)[[:space:]│|]*$' '$0 ~ emp { n = 0; next } $0 ~ num { n++ } END { print n + 0 }')" || true
    [[ "${n:-0}" =~ ^[0-9]+$ ]] && [ "${n:-0}" -ge 2 ]
  }
fi

usage() { awk 'NR > 1 { if (!/^#/) exit; print }' "$0"; }
TERM_H=""; TEXT=""; HAVE_TEXT=0; LANE=""; HOST=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --terminal) [ $# -ge 2 ] && [ -n "$2" ] || { usage >&2; exit 2; }; TERM_H="$2"; shift 2 ;;
    --text)     [ $# -ge 2 ] || { usage >&2; exit 2; }; TEXT="$2"; HAVE_TEXT=1; shift 2 ;;
    --lane)     [ $# -ge 2 ] && [ -n "$2" ] || { usage >&2; exit 2; }; LANE="$2"; shift 2 ;;
    --host)     [ $# -ge 2 ] && [ -n "$2" ] || { usage >&2; exit 2; }; HOST="$2"; shift 2 ;;
    --dry-run)  DRY=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) cm_warn "codemode-recover.sh: unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done
[ -n "$TERM_H" ] && [ -n "$LANE" ] && [ "$HAVE_TEXT" = 1 ] || { cm_warn "codemode-recover.sh: --terminal, --lane and --text are all required"; usage >&2; exit 2; }
if [[ "$TEXT" == *[[:cntrl:]]* ]]; then printf 'send-failed\t--text holds a control byte (one line of plain text is the contract): nothing was read or sent\n'; exit 0; fi
[ -n "${TEXT//[[:space:]]/}" ] || { cm_warn "codemode-recover.sh: --text must not be empty"; exit 2; }
cm_handle_ok "$TERM_H" || { cm_warn "codemode-recover.sh: bad terminal handle"; exit 2; }
[ -z "$HOST" ] || cm_handle_ok "$HOST" || { cm_warn "codemode-recover.sh: bad host"; exit 2; }
cm_lane_dir "$LANE" >/dev/null 2>&1 || { cm_warn "codemode-recover.sh: bad lane name"; exit 2; }
command -v jq >/dev/null 2>&1 || { cm_warn "codemode-recover.sh: missing dependency: jq"; exit 0; }

ORCA="$(cm_cli)" || exit 2
envargs=()
HOSTSEL="${HOST:-local}"
cm_cli_host_into envargs "$HOSTSEL" || exit 2
SETTLE="${CM_CODEMODE_SETTLE_S:-2}"; case "$SETTLE" in ''|*[!0-9]*) SETTLE=2 ;; esac
POLLS="${CM_CODEMODE_POLLS:-5}"; case "$POLLS" in ''|*[!0-9]*) POLLS=5 ;; esac; [ "$POLLS" -ge 1 ] || POLLS=1
MAXESC="${CM_CODEMODE_MAX_ESC:-2}"; case "$MAXESC" in ''|*[!0-9]*) MAXESC=2 ;; esac
STATE="$CM_HOME/cache/codemode-recover.tsv"   # host/handle <TAB> Esc keys sent <TAB> epoch of the last one
KEY="$HOSTSEL/$TERM_H"
out() { printf '%s\t%s\n' "$1" "$2"; exit 0; }

# read_screen: the last lines of the pane as text, nothing when it cannot be read (live CLI: .result.terminal.tail is an array of
# lines; older shapes carry a text field, as in boot-sweep.sh)
read_screen() {
  cm_timeout 30 "$ORCA" terminal read --terminal "$TERM_H" --screen ${envargs[@]+"${envargs[@]}"} --json </dev/null 2>/dev/null \
    | jq -r 'if .ok == true then (((.result.terminal.tail // empty) | if type == "array" then join("\n") else tostring end | select(length > 0)) // .result.screen // .result.text // .result.output // "") | tostring else "" end' 2>/dev/null
}

# codemode_dialog <text>: success only when the bottom of the screen IS the Code Mode dialog (see the header, step 1). The footer is the
# anchor: the LAST line with "esc to start without it" that BEGINS (after border characters) with "enter to confirm" or "esc to start without
# it" and has "enter to confirm" on it or beginning the line above (a sentence that quotes the words does not match), "code mode" on or above
# it, and only blank or border lines below it. Scrollback that quotes the dialog above a live prompt has real lines below it and fails.
codemode_dialog() {
  printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | tail -n 30 | awk '
    { l[NR] = tolower($0) }
    END {
      f = 0
      for (i = NR; i >= 1; i--) if (l[i] ~ /esc to start without it/) { f = i; break }
      if (!f) exit 1
      s = l[f]; sub(/^([[:space:]]|│|┃|╰|╯|╭|╮|┌|┐|└|┘|─|━|═)+/, "", s)
      if (s !~ /^(enter to confirm|esc to start without it)/) exit 1          # a footer, not prose that quotes the words
      p = (f > 1) ? l[f - 1] : ""; sub(/^([[:space:]]|│|┃|╰|╯|╭|╮|┌|┐|└|┘|─|━|═)+/, "", p)
      if (!(s ~ /^enter to confirm/ && s ~ /esc to start without it/) && !(s ~ /^esc to start without it/ && p ~ /^enter to confirm/)) exit 1
      for (j = f + 1; j <= NR; j++) if (l[j] !~ /^([[:space:]]|│|┃|╰|╯|╭|╮|┌|┐|└|┘|─|━|═|-)*$/) exit 1
      # the heading must sit INSIDE this dialog: within 8 lines above the footer and not past the top border of the dialog (a different dialog
      # with the same footer, under a transcript that mentions Code Mode, is not this one)
      for (k = f; k >= 1 && f - k <= 8; k--) {
        if (l[k] ~ /code mode/) { h = 1; break }
        if (l[k] ~ /^[[:space:]]*(╭|┌)/) break
      }
      exit !h
    }'
}

# pane_state <text>: dialog | menu | busy | shell | nofooter | ready (the same bottom-12-lines tests boot-sweep.sh applies before a nudge)
pane_state() {
  local bottom
  if codemode_dialog "$1"; then echo dialog; return; fi
  bottom="$(printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | tail -n 12)"
  if cm_menu_on_screen "$bottom"; then echo menu; return; fi
  if grep -qE 'esc to interrupt' <<<"$bottom"; then echo busy; return; fi
  if tail -n 1 <<<"$bottom" | grep -qE '^[^[:space:]]*[$#%] *$'; then echo shell; return; fi
  if ! cm_pane_last "$bottom" | grep -qiE "$CM_FOOTER_RE"; then echo nofooter; return; fi
  echo ready
}

screen="$(read_screen)"
[ -n "$(printf '%s' "$screen" | tr -d '[:space:]')" ] || out none "screen unreadable: nothing sent, the other checks still judge this lane"
if ! codemode_dialog "$screen"; then out none "no Code Mode dialog at the bottom of the screen"; fi
if [ "$DRY" = 1 ]; then out would-recover "Code Mode dialog on screen: would send Esc, confirm it closed, then nudge"; fi

# 2. resume.lock (resume.sh is running): nothing is sent, here, after the second read and again before the nudge
locked() { [ -e "$CM_HOME/resume.lock" ]; }
if locked; then out held "resume.lock exists (resume.sh is running): nothing sent"; fi

# 3. the handle the send uses: what cm_lane_handle returns for the lane (it re-checks a stale or missing file against the live agent through
# lane-handles.sh --worker). Only a fresh handle that IS this terminal, on THIS host, is accepted. A dead (-), stale-after-recheck,
# other-terminal or other-host file is "held": this script never writes a lane handle (lane-handles.sh and resume.sh own that).
send_h="$(cm_lane_handle "$LANE" 2>/dev/null)" || send_h=""
[ "$send_h" = "$TERM_H" ] || out held "the lane handle file does not confirm terminal $TERM_H: nothing sent; read the pane"
IFS=$'\t' read -r _lh lane_host _rest < "$(cm_lane_dir "$LANE")/handle" 2>/dev/null || true
[ "${lane_host:-local}" = "$HOSTSEL" ] || out held "the lane handle file names host ${lane_host:-local}, not $HOSTSEL: nothing sent"

# locks (mkdir, owner pid inside, released at exit): ONE recovery per terminal from the last read through the nudge (a second run for the
# same terminal is "held", never a second Esc into whatever the first one opened), and a short lock around the Esc-cap record
LOCKS_HELD=()
# drop_lock <dir>: removes the lock only while THIS process still owns it (its pid is inside); a lock another run took after ours was released, or
# one this run never acquired, is never touched
drop_lock() { local d="$1"; [ "$(cat -- "$d/pid" 2>/dev/null || true)" = "$$" ] || return 0; rm -f -- "${d:?}/pid" 2>/dev/null; rmdir "$d" 2>/dev/null; return 0; }
# shellcheck disable=SC2329
release_locks() { local d; for d in ${LOCKS_HELD[@]+"${LOCKS_HELD[@]}"}; do drop_lock "$d"; done; return 0; }
trap release_locks EXIT
# take_lock <dir> <tries of 0.1 s>: a lock whose owner is gone and that is over a minute old is reclaimed under a reclaim lock (see below);
# anything else fails closed
take_lock() {
  local d="$1" n="${2:-1}" i=0 pid rcl
  mkdir -p "$CM_HOME/cache" 2>/dev/null || return 1
  while :; do
    if mkdir "$d" 2>/dev/null; then printf '%s\n' "$$" > "$d/pid" 2>/dev/null; LOCKS_HELD+=("$d"); return 0; fi
    rcl=0
    # reclaim: ONE reclaimer at a time (a second mkdir lock, never waited for), and the staleness is judged AGAIN inside it. While it is held nothing
    # else can remove or replace a dead owner's lock (only the owner drops it, and it is dead), so what is removed is exactly what was judged
    if mkdir "$d.reclaim" 2>/dev/null; then
      printf '%s\n' "$$" > "$d.reclaim/pid" 2>/dev/null; LOCKS_HELD+=("$d.reclaim")
      pid="$(cat -- "$d/pid" 2>/dev/null || true)"
      if [ -d "$d" ] && [ -n "$(find "$d" -maxdepth 0 -mmin +1 2>/dev/null)" ] && { [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; }; then
        rm -f -- "${d:?}/pid" 2>/dev/null; rmdir "$d" 2>/dev/null && rcl=1
      fi
      drop_lock "$d.reclaim"
    fi
    [ "$rcl" = 1 ] && continue
    i=$((i + 1)); [ "$i" -lt "$n" ] || return 1
    sleep 0.1
  done
}
TERM_LOCK="$CM_HOME/cache/codemode-term.$(printf '%s' "$KEY" | tr -c 'A-Za-z0-9._-' '_').lock"
take_lock "$TERM_LOCK" 1 || out held "another recovery of this terminal is running (or a killed one left $TERM_LOCK): nothing sent"

# 4. the Esc is RESERVED against the cap (at most MAXESC per terminal in 6 hours counted from the last one, kept through a recovery) under the
# cap lock, with a unique temp file, and read back; an Esc that cannot be recorded is never sent (the cap must hold). Only AFTER the reservation
# (it can wait for the cap lock) is the pane read once more and the resume lock looked at once more, right before the key; an Esc that finds the
# dialog gone or the lock present gives its count back
STATE_LOCK="$CM_HOME/cache/codemode-recover.lock"
# esc_record reserve|refund: 0 done, 10 cap reached (reserve), 11 cannot be recorded
esc_record() {
  local op="$1" rd="" tries last now tmp new
  take_lock "$STATE_LOCK" 50 || return 11
  if [ -e "$STATE" ] && [ ! -f "$STATE" ]; then return 11; fi
  if [ -f "$STATE" ]; then rd="$(cat -- "$STATE" 2>/dev/null)" || return 11; fi
  now="$(date +%s)"
  read -r tries last < <(printf '%s\n' "$rd" | awk -F'\t' -v k="$KEY" '$1 == k { print $2, $3; f = 1; exit } END { if (!f) print "0 0" }')
  case "${tries:-0}" in ''|*[!0-9]*) tries=0 ;; esac; case "${last:-0}" in ''|*[!0-9]*) last=0 ;; esac
  if [ "$op" = reserve ]; then
    if [ $((now - last)) -gt 21600 ]; then tries=0; fi
    if [ "$tries" -ge "$MAXESC" ]; then RESERVED_TRIES="$tries"; return 10; fi
    new=$((tries + 1))
  else
    new=$((tries > 0 ? tries - 1 : 0)); now="$last"
  fi
  tmp="$(mktemp "$CM_HOME/cache/codemode-recover.XXXXXX" 2>/dev/null)" || return 11
  if { printf '%s\n' "$rd" | awk -F'\t' -v k="$KEY" 'NF && $1 != k'; printf '%s\t%s\t%s\n' "$KEY" "$new" "$now"; } > "$tmp" 2>/dev/null && mv -f -- "$tmp" "$STATE" 2>/dev/null \
     && [ "$(awk -F'\t' -v k="$KEY" '$1 == k { print $2 }' "$STATE" 2>/dev/null)" = "$new" ]; then
    return 0
  fi
  rm -f -- "${tmp:?}" 2>/dev/null || true
  return 11
}
# the cap lock is held only inside esc_record
cap_record() { local rc; esc_record "$1"; rc=$?; drop_lock "$STATE_LOCK"; return "$rc"; }
RESERVED_TRIES=0
cap_record reserve; rc=$?
case "$rc" in
  0) ;;
  10) out menu "$RESERVED_TRIES Esc keys already sent to this terminal in the last 6 h and the Code Mode dialog is on screen again: not sent again, answer it by hand" ;;
  *)  out held "the Esc count could not be recorded in $STATE: not sent (the cap must hold)" ;;
esac
screen="$(read_screen)"
if [ -z "$(printf '%s' "$screen" | tr -d '[:space:]')" ]; then cap_record refund || true; out unreadable "the screen could not be read after the Esc was reserved: nothing sent, read the pane"; fi
if ! codemode_dialog "$screen"; then cap_record refund || true; out none "the Code Mode dialog is gone from the screen: nothing sent"; fi
if locked; then cap_record refund || true; out held "resume.lock appeared (resume.sh started): nothing sent"; fi
# the lane handle is still this terminal on this host right before the key (the reservation and the read can take a while)
if [ "$(cm_lane_handle "$LANE" 2>/dev/null)" != "$send_h" ]; then cap_record refund || true; out held "the lane handle changed before the Esc: nothing sent"; fi
lane_host=""; IFS=$'\t' read -r _lh lane_host _rest < "$(cm_lane_dir "$LANE")/handle" 2>/dev/null || true
if [ "${lane_host:-local}" != "$HOSTSEL" ]; then cap_record refund || true; out held "the lane handle file names another host before the Esc: nothing sent"; fi
ESC=$'\033'
resp="$(cm_timeout 60 "$ORCA" terminal send --terminal "$send_h" --text "$ESC" ${envargs[@]+"${envargs[@]}"} --json </dev/null 2>/dev/null)" || resp=""
[ "$(printf '%s' "$resp" | jq -r '.ok // false | tostring' 2>/dev/null)" = true ] || out send-failed "the Esc to $send_h was not accepted: nothing else sent; read the pane"
state=dialog; i=0
while [ "$i" -lt "$POLLS" ]; do
  [ "$SETTLE" -gt 0 ] && sleep "$SETTLE"
  screen="$(read_screen)"
  if [ -z "$(printf '%s' "$screen" | tr -d '[:space:]')" ]; then state=unreadable; else state="$(pane_state "$screen")"; fi
  case "$state" in dialog|nofooter|unreadable) i=$((i + 1)); continue ;; esac
  break
done
case "$state" in
  dialog)     out menu "Code Mode dialog still open after Esc (read $POLLS times): not retried, no nudge; answer it by hand" ;;
  unreadable) out unreadable "Esc sent, then the screen could not be read: no nudge" ;;
  nofooter)   if [ "$HOSTSEL" = local ]; then out closed "dialog closed, no Claude footer on screen yet: no nudge, the next tick judges the lane"
              else out closed "dialog closed, no Claude footer on screen yet: no nudge, and no later pass covers a remote lane: send the re-arm nudge by hand"; fi ;;
  menu)       out menu "dialog closed, but another menu is showing now: not typed into" ;;
  shell)      out closed "dialog closed, but a shell prompt is on screen (agent gone): resume.sh respawns it" ;;
  busy)       out closed "dialog closed and the lane is mid-turn: no nudge needed" ;;
esac
# the dialog is gone and the pane looks idle: a fresh read right before the send, the same tests again (gsend.sh step 3)
screen="$(read_screen)"
[ "$(pane_state "$screen")" = ready ] || out closed "dialog closed, but the pane changed before the nudge: not sent"
[ "$(cm_lane_handle "$LANE" 2>/dev/null)" = "$send_h" ] || out held "the lane handle changed before the nudge: not sent"
lane_host=""; IFS=$'\t' read -r _lh lane_host _rest < "$(cm_lane_dir "$LANE")/handle" 2>/dev/null || true
[ "${lane_host:-local}" = "$HOSTSEL" ] || out held "the lane handle file names host ${lane_host:-local}, not $HOSTSEL, before the nudge: not sent"
if locked; then out held "resume.lock appeared (resume.sh started): Esc sent, dialog closed, nudge not sent"; fi
resp="$(cm_timeout 60 "$ORCA" terminal send --terminal "$send_h" --text "$TEXT" --enter ${envargs[@]+"${envargs[@]}"} --json </dev/null 2>/dev/null)" || resp=""
[ "$(printf '%s' "$resp" | jq -r '.ok // false | tostring' 2>/dev/null)" = true ] || out send-failed "dialog closed, the nudge to $send_h was not accepted: read the pane"
out recovered "Code Mode dialog closed with Esc, then nudged once"
