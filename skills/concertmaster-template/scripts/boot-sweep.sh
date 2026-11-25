#!/usr/bin/env bash
# boot-sweep.sh: after a VM restart, nudge the standing lanes on THIS host that orca-resume reopened
# but that have not done anything since boot, so they re-arm their /loop.
#
#   scripts/boot-sweep.sh              # wait for Orca, settle, sweep, nudge, confirm, write the inbox note
#   scripts/boot-sweep.sh --dry-run    # same decisions, nothing sent, nothing written
#   scripts/boot-sweep.sh --no-wait    # skip the Orca wait and the settle delay (tests, manual runs)
#   scripts/boot-sweep.sh --since <epoch> [--lanes <path,path>]
#                                      # tick mode (scripts/runtime-check.sh): the SAME decision and nudge core with
#                                      # "since" = a lane's expected wake time instead of boot time, for an Orca
#                                      # RUNTIME restart. No Orca wait, no settle, no inbox note, "Orca restarted"
#                                      # text (CM_TICK_NUDGE), attempts kept per transcript in runtime-sweep.tsv;
#                                      # --lanes keeps only those worktree paths. Without --since nothing changes.
#
# Why: a host-level resume unit (if the host has one) reopens dead sessions and sends ONE generic
# nudge, but such nudges can come back UNCONFIRMED (input accepted, no turn started) and the text
# never tells a lane to re-arm the /loop timer the restart killed.
#
# Positive signal, not stale screen text: a lane needs a nudge only when its Claude transcript has
# NOT been written since boot (no turn ran after the restart). A lane that orca-resume already got
# going has a newer transcript and is skipped, so it never gets a second /loop chain.
#
# Per lane, all fail closed (see resume.sh for the same rules):
#   host is THIS machine only (a remote host runs its own sweep)
#   no readable screen, a question menu, a shell prompt or no sign of Claude at the bottom: not sent
#   mid-turn ("esc to interrupt"): not sent
#   duplicate live agents in one worktree: not sent (resume.sh and the concertmaster own that)
#   the concertmaster session itself IS nudged (worktree path ending /<worktrees.self_name>, or the
#   ledger row workers.<worktrees.self_name> with standing true), with the exact text "/loop /concertmaster tick"
#   instead of the generic lane text, under every check and cap above; if it cannot be re-armed the
#   unit log and the top of the inbox note say so for a human
#   at most TWO nudges per lane per boot; a nudge counts as done only when the transcript advances
#   within CM_BOOT_CONFIRM_S (60 s); otherwise it is reported `unconfirmed` and retried once later
# Boot also runs scripts/cm-worktree-sync.sh (the concertmaster worktree level with its remote, hard rule 30; CM_WORKTREE_SYNC replaces
# the script, tests): its one status line becomes a `(worktree-sync)` report row, and a blocker (exit 1) is repeated in the unit log
# and at the top of the inbox note. Silent when the worktree is level. Not run in tick mode (the tick runs it in step 1).
# Boot also runs scripts/capacity-check.sh --no-candidates (agent terminals per host against the host cap; CM_CAPACITY_CHECK
# replaces the script, tests): one `(capacity)` row when a host is over its cap or unread, silent otherwise. Not run in tick mode
# (the tick runs it in step 2 and lists the teardown candidates; nothing is ever removed here).
# Output: TSV on stdout and $CM_HOME/inbox/boot-sweep-<UTC with seconds>.md. Exit 0 always except
# bad usage (2): a failed sweep must never fail the boot. Install: references/boot-sweep.md.
# Env: CM_HOME, CM_TICK_NUDGE (tick mode text), CM_BOOT_SETTLE_S (45), CM_BOOT_ORCA_WAIT_S (300), CM_BOOT_CONFIRM_S (60),
#      CM_BOOT_NUDGE (text), CM_SELF_PATH_RE (concertmaster worktree path regex, default built from
#      worktrees.self_name), CM_BOOT_EPOCH (test hook), CM_CLAUDE_PROJECTS (default ~/.claude/projects).
# Scope: terminals whose worktree path matches config worktrees.path_match (CM_PATH_MATCH).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

DRY=0; WAIT=1; SINCE=""; LANES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --no-wait) WAIT=0 ;;
    --since) [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]] || { cm_warn "boot-sweep.sh: --since takes an epoch"; exit 2; }; SINCE="$2"; shift ;;
    --lanes) [ $# -ge 2 ] || { cm_warn "boot-sweep.sh: --lanes takes comma-separated worktree paths"; exit 2; }; LANES="$2"; shift ;;
    -h|--help) sed -n '2,39p' "$0"; exit 0 ;;
    *) cm_warn "boot-sweep.sh: unknown arg: $1"; exit 2 ;;
  esac
  shift
done
command -v jq >/dev/null 2>&1 || { cm_warn "boot-sweep.sh: missing dependency: jq"; exit 0; }

# Fail closed: with no path match configured there is no way to tell this project's lanes
# from anyone else's on a shared host.
[ -n "$CM_PATH_MATCH" ] || { cm_warn "boot-sweep.sh: set worktrees.path_match in config.yaml (or CM_PATH_MATCH)"; exit 0; }

ORCA="$(cm_cli)" || exit 2
SETTLE="${CM_BOOT_SETTLE_S:-45}"
WAIT_MAX="${CM_BOOT_ORCA_WAIT_S:-300}"
CONFIRM_S="${CM_BOOT_CONFIRM_S:-60}"
NUDGE="${CM_BOOT_NUDGE:-$CM_NUDGE_BOOT}"
NUDGE_CM="/loop /concertmaster tick"   # the concertmaster re-arms by running its own loop, not by being told to
# the concertmaster's own worktree: a path ending /<worktrees.self_name> (ERE metacharacters escaped)
CM_PATH_RE="${CM_SELF_PATH_RE:-/$(printf '%s' "$CM_SELF_WORKTREE" | sed 's#[][\\.^$*+?(){}|]#\\&#g')/*\$}"
STATE_DIR="$CM_HOME/cache"
TICK=0
if [ -n "$SINCE" ]; then
  # tick mode (runtime restart): "boot" is the lane's expected wake time, the attempts file is its own
  TICK=1; WAIT=0; boot="$SINCE"
  NUDGE="${CM_TICK_NUDGE:-$CM_NUDGE_TICK}"
  STATE="$STATE_DIR/runtime-sweep.tsv"   # handle<TAB>attempts<TAB>transcript mtime of that episode
  HIST="$STATE_DIR/runtime-sweep-history.tsv"   # handle<TAB>epoch of each accepted nudge (3 in 6 h = gave-up)
else
  boot="${CM_BOOT_EPOCH:-$(awk '$1=="btime"{print $2; exit}' /proc/stat 2>/dev/null)}"
  if [ -z "$boot" ]; then cm_warn "boot-sweep.sh: cannot read boot time, nothing to do"; exit 0; fi
  STATE="$STATE_DIR/boot-sweep-$boot.tsv"   # handle<TAB>attempts
fi
if [ "$DRY" = 0 ]; then mkdir -p "$STATE_DIR" "$CM_HOME/inbox" 2>/dev/null; touch "$STATE" 2>/dev/null; fi

now_s() { date +%s; }
early_note() { # an early exit must never be silent: leave a note the concertmaster tick reads
  [ "$DRY" = 1 ] && return
  [ "$TICK" = 1 ] && { cm_warn "boot-sweep (tick mode): $1"; return; }
  mkdir -p "$CM_HOME/inbox" 2>/dev/null
  printf '# boot-sweep %s (boot %s): NOT RUN\n\n%s\n' "$(date -u +%FT%TZ)" "$boot" "$1" > "$CM_HOME/inbox/boot-sweep-$(date -u +%Y%m%dT%H%M%SZ)-$$.md" 2>/dev/null
}
if [ "$WAIT" = 1 ]; then
  start="$(now_s)"
  until cm_timeout 20 "$ORCA" worktree ps --json </dev/null >/dev/null 2>&1; do
    if [ $(( $(now_s) - start )) -ge "$WAIT_MAX" ]; then
      cm_warn "boot-sweep: Orca not answering after ${WAIT_MAX}s, giving up"
      early_note "Orca did not answer within ${WAIT_MAX}s of boot (CLI: $ORCA, PATH=$PATH). No lane was checked or nudged."; exit 0
    fi
    sleep 5
  done
  sleep "$SETTLE"
fi

# newest transcript mtime for a worktree path, "unknown" when none is visible (lib.sh)
transcript_mtime() { cm_transcript_mtime "$1"; }
# Attempts per handle. Tick mode passes the lane's transcript mtime ($2/$3): attempts belong to ONE episode of
# silence, so a lane that got going starts fresh and one that did not stays capped. Boot mode passes none.
attempts_of() { awk -F'\t' -v h="$1" -v m="${2:-}" '$1==h && !f {f=1; if (m != "" && $3 != "" && $3 != m) print 0; else print $2} END{if(!f) print 0}' "$STATE" 2>/dev/null; }
set_attempts() { # $1 handle $2 n [$3 mtime] (awk, not grep: the handle is data, never a pattern)
  [ "$DRY" = 1 ] && return
  { awk -F'\t' -v h="$1" '$1 != h' "$STATE" 2>/dev/null; if [ -n "${3:-}" ]; then printf '%s\t%s\t%s\n' "$1" "$2" "$3"; else printf '%s\t%s\n' "$1" "$2"; fi; } > "$STATE.new" 2>/dev/null && mv "$STATE.new" "$STATE"
}

out=""; sent=0; kept=0; CM_HANDLES=""
add() { out="$out$1|$2|$3|$4"$'\n'; } # session | handle | result | detail

# Boot: the concertmaster worktree must not drift from its remote (a stale index.lock once left it far behind for days with nothing
# said). One status line, silent when level; a fast-forward done here applies from the next tick.
WS_BLOCK=""
if [ "$TICK" = 0 ]; then
  WS_SH="${CM_WORKTREE_SYNC:-$HERE/cm-worktree-sync.sh}"
  if [ -x "$WS_SH" ]; then
    ws_args=(); [ "$DRY" = 1 ] && ws_args=(--dry-run)
    ws_out="$(cm_timeout 90 "$WS_SH" ${ws_args[@]+"${ws_args[@]}"} </dev/null 2>&1)"; ws_rc=$?
    ws_line="$(printf '%s\n' "$ws_out" | grep -m1 '^cm-worktree-sync: ' | tr '\t\n|' '   ')"
    if [ "$ws_rc" -ne 0 ] || [ -n "$ws_line" ]; then
      [ -n "$ws_line" ] || ws_line="cm-worktree-sync: exited $ws_rc: $(printf '%s' "$ws_out" | head -c 160 | tr '\t\n|' '   ')"
      add "(worktree-sync)" - report "$ws_line"
      if [ "$ws_rc" -ne 0 ]; then WS_BLOCK="$ws_line"; printf 'boot-sweep: %s\n' "$ws_line" >&2; fi
    fi
  else
    add "(worktree-sync)" - report "$WS_SH is missing or not executable: the concertmaster worktree was not compared with its remote"
  fi
fi

# Boot: the agent terminals per host against the host cap (counts only; the tick lists the teardown candidates, SKILL.md tick step 2).
# Silent when every host is within its cap and read; an over-cap host is one `(capacity)` row naming it. Exit 1 is "over cap", not a failure.
if [ "$TICK" = 0 ]; then
  CC_SH="${CM_CAPACITY_CHECK:-$HERE/capacity-check.sh}"
  if [ -x "$CC_SH" ]; then
    cc_out="$(cm_timeout 90 "$CC_SH" --no-candidates </dev/null 2>&1)"; cc_rc=$?
    cc_line="$(printf '%s\n' "$cc_out" | grep -m1 '^capacity: ' | tr '\t\n|' '   ')"
    cc_over="$(printf '%s\n' "$cc_out" | grep '^  HOST .* OVER by ' | sed 's/^  HOST //' | tr '\t\n|' '   ;' | head -c 300)"
    if [ "$cc_rc" -gt 1 ] || [ -z "$cc_line" ] || [ "$cc_rc" = 1 ] || printf '%s' "$cc_line" | grep -q 'CHECK INCOMPLETE'; then
      [ -n "$cc_line" ] || cc_line="capacity-check: exited $cc_rc: $(printf '%s' "$cc_out" | head -c 160 | tr '\t\n|' '   ')"
      add "(capacity)" - report "$cc_line${cc_over:+: $cc_over}; teardown candidates are listed by the tick (step 2), never removed here"
    fi
  else
    add "(capacity)" - report "$CC_SH is missing or not executable: the agent terminals were not compared with the host caps"
  fi
fi

terms="$(cm_timeout 60 "$ORCA" terminal list --json </dev/null 2>/dev/null | jq -r --arg re "$CM_PATH_MATCH" '.result.terminals[]? | select((.worktreePath // "") | test($re)) | select((.agentIdentity // "") == "claude") | "\(.handle)|\(.worktreePath)"' 2>/dev/null)"
if [ -n "$LANES" ] && [ -n "$terms" ]; then
  # keep only the named worktrees (comma-separated, compared after the same path normalisation)
  want="$(printf '%s' "$LANES" | tr ',' '\n' | sed -E 's#/\.(/|$)#/#g; s#//+#/#g; s#(.)/+$#\1#')"
  terms="$(printf '%s\n' "$terms" | while IFS='|' read -r th tw; do
    [ -n "$th" ] || continue
    np="$(printf '%s' "$tw" | sed -E 's#/\.(/|$)#/#g; s#//+#/#g; s#(.)/+$#\1#')"
    grep -qxF -- "$np" <<<"$want" && printf '%s|%s\n' "$th" "$tw"
  done)"
fi
if [ -z "$terms" ]; then
  [ "$DRY" = 1 ] || [ "$TICK" = 1 ] || printf '# boot-sweep %s (boot %s): no Claude terminals found for this project (or Orca did not answer)\n' "$(date -u +%FT%TZ)" "$boot" > "$CM_HOME/inbox/boot-sweep-$(date -u +%Y%m%dT%H%M%SZ)-$$.md" 2>/dev/null
  [ -z "$out" ] || printf '%s' "$out" | awk -F'|' '{printf "%s\t%s\t%s\t%s\n",$1,$2,$3,$4}'
  echo "boot-sweep: no Claude terminals found for this project"; exit 0
fi

# only STANDING lanes of this host (ledger rows with standing==true and host local/unset, never state asleep: a
# lead put to sleep stays asleep through a reboot) are ever nudged: a dev or epic worker has no standing /loop to re-arm. The concertmaster session is nudged too
# (below), by path or by its own ledger row. No readable ledger and no concertmaster terminal = send nothing.
LEDGER="$CM_HOME/ledger.json"
# The ledger must be ONE object whose workers is a map with no key written twice (lib.sh cm_workers_gate). A workers that is false or a list, a truncated file or a repeated key
# (jq keeps the last: standing false ... standing true) was read as "no row" or as a standing lane and a lane was nudged on it: now nothing is nudged and it is said.
LEDGER_HOLD=""
if [ -e "$LEDGER" ]; then LEDGER_HOLD="$(cm_workers_gate "$LEDGER")" || LEDGER_HOLD="${LEDGER_HOLD:-the ledger cannot be read}"; fi
# The typed boundary decides what a row is: cm_row_fields_ok (a field of the wrong type, a control character in a name) comes from lib.sh. A row that fails it, or that has a state this
# skill does not know, is never a standing lane to nudge, and it is REPORTED, never read as "no row". A host or path that is not text could be the row of ANY lane: cm_bs_wild.
BS_DEFS="$CM_JQ_STATE_DEFS $CM_JQ_NAME_DEFS"' def cm_bs_wild: cm_wild;'
BS_OK='type == "object" and cm_row_fields_ok and (.standing == true) and ((.state | cm_state_unknown) | not) and ((.state | cm_state_asleep) | not) and ((.host // "local") == "local")'
CM_LEDGER_PATH="$(jq -r --arg self "$CM_SELF_WORKTREE" "$BS_DEFS"' .workers[$self] // empty | select('"$BS_OK"') | (.path // .worktree // .worktreePath // empty) | select(cm_name_ok)' "$LEDGER" 2>/dev/null | sed -E 's#/\.(/|$)#/#g; s#//+#/#g; s#(.)/+$#\1#' )"
# The concertmaster row is nudged only when it reads standing true with a known state that is not asleep and every field of the right type. A row that is not an object, has a
# field of the wrong type (standing "true", host false, path false), an unknown state or is asleep is never nudged, whatever identified the worktree (its ledger row or its path):
# it is reported and the shout "CONCERTMASTER NOT RE-ARMED" stands.
CM_ROW_BAD="$(jq -r --arg self "$CM_SELF_WORKTREE" "$BS_DEFS"' .workers | if type == "object" then .[$self] else null end | select(. != null)
    | select((type != "object") or (cm_row_fields_ok | not) or (.state | cm_state_unknown) or (.state | cm_state_asleep)) | "bad"' "$LEDGER" 2>/dev/null | head -n 1)"
ASLEEP="$(jq -r '.workers // {} | to_entries[] | .value | select(((.host // "local") == "local") and ((.state // "") == "asleep")) | (.path // .worktree // .worktreePath // empty)' "$LEDGER" 2>/dev/null | sed -E 's#/\.(/|$)#/#g; s#//+#/#g; s#(.)/+$#\1#' )"
STANDING="$(jq -r "$BS_DEFS"' .workers // {} | to_entries[] | .value | select('"$BS_OK"') | (.path // .worktree // .worktreePath // empty) | select(cm_name_ok)' "$LEDGER" 2>/dev/null | sed -E 's#/\.(/|$)#/#g; s#//+#/#g; s#(.)/+$#\1#' )"   # cm_name_ok: a standing path with a control character (a newline would forge a second standing path) is not a standing path, so its lane is never nudged
# a ledger row that is not readable (a field of the wrong type, a standing that is not a boolean, an unknown state) at a path that IS text: never nudged, and said so
STANDING_BAD="$(jq -r "$BS_DEFS"' .workers // {} | to_entries[] | .value | select(type == "object") | select(((cm_row_fields_ok | not) or (.standing == true and (.state | cm_state_unknown))) and ((.state | cm_state_asleep) | not) and (((.host // "local") == "local") or ((.host | type) == "string" and (.host | cm_strip) == "local"))) | (.path // .worktree // .worktreePath // empty) | select(type == "string" and cm_name_ok)' "$LEDGER" 2>/dev/null | sed -E 's#/\.(/|$)#/#g; s#//+#/#g; s#(.)/+$#\1#' )"
# a row whose host or path is not text, or that is not an object, and that is, or may be, a standing row: it could be the row of ANY lane, so a lane the ledger does not list as standing is reported against it
STANDING_WILD="$(jq -r "$BS_DEFS"' [.workers // {} | to_entries[] | .value | select((type != "object") or (cm_bs_wild and (.standing | cm_standing_any) and ((.state | cm_state_asleep) | not)))] | length' "$LEDGER" 2>/dev/null)"; STANDING_WILD="${STANDING_WILD:-0}"
if [ -z "$LEDGER_HOLD" ] && [ -z "$STANDING" ] && ! awk -F'|' '{print $2}' <<<"$terms" | grep -qE "$CM_PATH_RE"; then
  early_note "No standing local lanes found in $LEDGER (missing or unreadable ledger): nothing was nudged."
  echo "boot-sweep: no standing local lanes in the ledger, nothing to do"; exit 0
fi

# duplicate live agents in one worktree: send to neither
dups="$(printf '%s\n' "$terms" | awk -F'|' '{c[$2]++} END{for (p in c) if (c[p]>1) print p}')"

while IFS='|' read -r handle wt; do
  [ -n "$handle" ] || continue
  name="$(basename "$wt")"
  if grep -qxF -- "$wt" <<<"$dups"; then add "$name" "$handle" report "duplicate terminals in one worktree: left to resume.sh and the concertmaster"; kept=$((kept+1)); continue; fi
  normwt="$(printf '%s' "$wt" | sed -E 's#/\.(/|$)#/#g; s#//+#/#g; s#(.)/+$#\1#')"
  # a session put to sleep on purpose (lane-health.sh sleep) is never nudged, the concertmaster's own row included
  if [ -n "$ASLEEP" ] && grep -qxF -- "$normwt" <<<"$ASLEEP"; then add "$name" "$handle" asleep "ledger state asleep: never nudged"; continue; fi
  is_cm=0; text="$NUDGE"
  if [ -n "$CM_LEDGER_PATH" ] && [ "$normwt" = "$CM_LEDGER_PATH" ] || grep -qE "$CM_PATH_RE" <<<"$normwt"; then is_cm=1; text="$NUDGE_CM"; fi
  [ "$is_cm" = 1 ] && CM_HANDLES="$CM_HANDLES $handle"
  if [ -n "$LEDGER_HOLD" ]; then add "$name" "$handle" report "the ledger cannot be read ($LEDGER_HOLD): not nudged, fix the ledger"; kept=$((kept+1)); continue; fi
  if [ "$is_cm" = 1 ] && [ -n "$CM_ROW_BAD" ]; then add "$name" "$handle" report "the concertmaster ledger row is asleep, has an unknown state or a standing that is not a boolean: not nudged, fix the ledger row"; kept=$((kept+1)); continue; fi
  if [ "$is_cm" = 0 ] && [ -z "$STANDING" ]; then add "$name" "$handle" no-ledger "ledger missing or unreadable: lane not considered, restore $LEDGER"; continue; fi
  if [ "$is_cm" = 0 ] && [ -n "$STANDING_BAD" ] && grep -qxF -- "$normwt" <<<"$STANDING_BAD"; then add "$name" "$handle" report "ledger standing is not a boolean, or its state is not a known state: lane not nudged, fix the ledger row"; continue; fi
  if [ "$is_cm" = 0 ] && [ "$STANDING_WILD" != 0 ] && ! grep -qxF -- "$normwt" <<<"$STANDING"; then add "$name" "$handle" report "a ledger row has a host or path that is not text, so it could be this lane: not nudged, fix the ledger row"; continue; fi
  if [ "$is_cm" = 0 ] && ! grep -qxF -- "$normwt" <<<"$STANDING"; then add "$name" "$handle" not-standing "not a standing lane in the ledger: never nudged"; continue; fi
  m="$(transcript_mtime "$normwt")"
  if [ "$m" = unknown ]; then add "$name" "$handle" unknown "no Claude transcript visible for this worktree: not nudged"; kept=$((kept+1)); continue; fi
  if [ "$m" -ge "$boot" ]; then add "$name" "$handle" skipped "$([ "$TICK" = 1 ] && echo "active since the expected wake" || echo "active since boot")"; continue; fi
  ep=""; [ "$TICK" = 1 ] && ep="$m"
  tries="$(attempts_of "$handle" "$ep")"; tries="${tries:-0}"
  if [ "$tries" -ge 2 ]; then add "$name" "$handle" gave-up "two nudges sent, no turn since $([ "$TICK" = 1 ] && echo "the expected wake" || echo boot): left to the concertmaster tick"; kept=$((kept+1)); continue; fi
  # live CLI: .result.terminal.tail (array of lines); older shapes carry a text field
  screen="$(cm_timeout 30 "$ORCA" terminal read --terminal "$handle" --screen --json </dev/null 2>/dev/null | jq -r 'if .ok == true then (((.result.terminal.tail // empty) | if type == "array" then join("\n") else tostring end | select(length > 0)) // .result.screen // .result.text // .result.output // "") | tostring else "" end' 2>/dev/null)"
  bottom="$(printf '%s\n' "$screen" | grep -v '^[[:space:]]*$' | tail -n 12)"
  if [ -z "$bottom" ]; then add "$name" "$handle" unreadable "screen unreadable"; kept=$((kept+1)); continue; fi
  if grep -qiE "$CM_MENU_RE" <<<"$bottom"; then add "$name" "$handle" menu "question menu showing, not typed into"; kept=$((kept+1)); continue; fi
  if tail -n 1 <<<"$bottom" | grep -qE '^[^[:space:]]*[$#%] *$'; then add "$name" "$handle" report "shell prompt, agent gone: resume.sh respawns it"; kept=$((kept+1)); continue; fi
  if ! grep -qiE "$CM_CLAUDE_RE" <<<"$bottom"; then add "$name" "$handle" unreadable "no sign of Claude at the prompt"; kept=$((kept+1)); continue; fi
  if grep -qE 'esc to interrupt' <<<"$bottom"; then add "$name" "$handle" busy "mid-turn"; kept=$((kept+1)); continue; fi
  if [ "$TICK" = 1 ]; then
    # tick mode runs every few minutes against lanes that may be dead: type only into a pane whose LAST line
    # is a Claude footer (a zsh prompt under Claude scrollback passes the looser checks above)
    if ! tail -n 1 <<<"$bottom" | grep -qiE "$CM_FOOTER_RE"; then add "$name" "$handle" report "last screen line is not a Claude footer (shell prompt or exited): resume.sh respawns it"; kept=$((kept+1)); continue; fi
    # a lane that takes a turn after each nudge but never re-arms its loop is capped across episodes
    if [ "$(awk -F'\t' -v h="$handle" -v s="$(( $(now_s) - 21600 ))" '$1==h && $2>=s' "$HIST" 2>/dev/null | wc -l | tr -d ' ')" -ge 3 ]; then
      add "$name" "$handle" gave-up "nudged 3 times in 6 h and still not re-arming: left to the concertmaster tick (resume.sh, handover)"; kept=$((kept+1)); continue
    fi
  fi
  if [ "$DRY" = 1 ]; then add "$name" "$handle" would-nudge "no turn since $([ "$TICK" = 1 ] && echo "the expected wake" || echo boot) (transcript $((boot - m))s before $([ "$TICK" = 1 ] && echo "it" || echo "boot"))"; continue; fi
  t0="$(now_s)"
  resp="$(cm_timeout 60 "$ORCA" terminal send --terminal "$handle" --text "$text" --enter --json </dev/null 2>/dev/null)"
  if [ "$(printf '%s' "$resp" | jq -r '.ok // false' 2>/dev/null)" != true ]; then add "$name" "$handle" send-failed "orca did not accept the input"; kept=$((kept+1)); continue; fi
  set_attempts "$handle" $((tries + 1)) "$ep"
  [ "$TICK" = 1 ] && printf '%s\t%s\n' "$handle" "$(now_s)" >> "$HIST" 2>/dev/null   # every accepted send counts toward the 6 h cap
  ok=0; waited=0
  while [ "$waited" -lt "$CONFIRM_S" ]; do
    sleep 3; waited=$((waited + 3))
    cur="$(transcript_mtime "$normwt")"; [ "$cur" != unknown ] && [ "$cur" -ge "$t0" ] && { ok=1; break; }
  done
  if [ "$ok" = 1 ]; then add "$name" "$handle" nudged "turn started ${waited}s after the nudge"; sent=$((sent+1))
  else add "$name" "$handle" unconfirmed "input accepted, no turn within ${CONFIRM_S}s: one retry on the next sweep"; kept=$((kept+1)); fi
done <<<"$terms"

# the concertmaster tick reads the inbox, and a concertmaster that failed to re-arm is the one reader
# that is dead: say so in the unit log and at the top of the note, for a human
cm_bad=""
for h in $CM_HANDLES; do
  r="$(printf '%s' "$out" | awk -F'|' -v h="$h" '$2==h{print $3}' | tail -n 1)"
  case "$r" in nudged|skipped|would-nudge) ;; *) cm_bad="$cm_bad $h($r)" ;; esac
done
[ -n "$cm_bad" ] && cm_warn "boot-sweep: CONCERTMASTER NOT RE-ARMED:$cm_bad: a human must run /loop /concertmaster tick in that session"
printf '%s' "$out" | awk -F'|' '{printf "%s\t%s\t%s\t%s\n",$1,$2,$3,$4}'
if [ "$DRY" = 0 ] && [ "$TICK" = 0 ]; then
  note="$CM_HOME/inbox/boot-sweep-$(date -u +%Y%m%dT%H%M%SZ)-$$.md"
  {
    printf '# boot-sweep %s (boot %s): %s nudged, %s not nudged\n\n' "$(date -u +%FT%TZ)" "$boot" "$sent" "$kept"
    [ -n "$WS_BLOCK" ] && printf '**BLOCKER: the concertmaster worktree is not level with its remote: %s**\n\n' "$WS_BLOCK"
    # shellcheck disable=SC2016  # the backticks are markdown, not command substitution
    [ -n "$cm_bad" ] && printf '**NEEDS A HUMAN: the concertmaster loop was not re-armed (%s). Run `/loop /concertmaster tick` in the concertmaster session.**\n\n' "${cm_bad# }"
    # shellcheck disable=SC2016
    [ -z "$STANDING" ] && printf '**Ledger missing or unreadable (%s): only the concertmaster was considered, every other lane is `no-ledger`.**\n\n' "$LEDGER"
    printf 'session | terminal | result | detail\n--- | --- | --- | ---\n'
    printf '%s' "$out" | awk -F'|' '{printf "%s | %s | %s | %s\n",$1,$2,$3,$4}'
  } > "$note" 2>/dev/null
fi
exit 0
