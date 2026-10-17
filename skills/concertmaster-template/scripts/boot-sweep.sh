#!/usr/bin/env bash
# boot-sweep.sh: after a VM restart, nudge the standing lanes on THIS host that orca-resume reopened
# but that have not done anything since boot, so they re-arm their /loop.
#
#   scripts/boot-sweep.sh              # wait for Orca, settle, sweep, nudge, confirm, write the inbox note
#   scripts/boot-sweep.sh --dry-run    # same decisions, nothing sent, nothing written
#   scripts/boot-sweep.sh --no-wait    # skip the Orca wait and the settle delay (tests, manual runs)
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
#   at most TWO nudges per lane per boot; a nudge counts as done only when the transcript advances
#   within CM_BOOT_CONFIRM_S (60 s); otherwise it is reported `unconfirmed` and retried once later
# Output: TSV on stdout and $CM_HOME/inbox/boot-sweep-<UTC with seconds>.md. Exit 0 always except
# bad usage (2): a failed sweep must never fail the boot. Install: references/boot-sweep.md.
# Env: CM_HOME, CM_BOOT_SETTLE_S (45), CM_BOOT_ORCA_WAIT_S (300), CM_BOOT_CONFIRM_S (60),
#      CM_BOOT_NUDGE (text), CM_BOOT_EPOCH (test hook), CM_CLAUDE_PROJECTS (default ~/.claude/projects).
# Scope: terminals whose worktree path matches config worktrees.path_match (CM_PATH_MATCH).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

DRY=0; WAIT=1
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --no-wait) WAIT=0 ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) cm_warn "boot-sweep.sh: unknown arg: $1"; exit 2 ;;
  esac
  shift
done
command -v jq >/dev/null 2>&1 || { cm_warn "boot-sweep.sh: missing dependency: jq"; exit 0; }

# Fail closed: with no path match configured there is no way to tell this project's lanes
# from anyone else's on a shared host.
[ -n "$CM_PATH_MATCH" ] || { cm_warn "boot-sweep.sh: set worktrees.path_match in config.yaml (or CM_PATH_MATCH)"; exit 0; }

ORCA="$(cm_orca)"
SETTLE="${CM_BOOT_SETTLE_S:-45}"
WAIT_MAX="${CM_BOOT_ORCA_WAIT_S:-300}"
CONFIRM_S="${CM_BOOT_CONFIRM_S:-60}"
PROJECTS="${CM_CLAUDE_PROJECTS:-$HOME/.claude/projects}"
NUDGE="${CM_BOOT_NUDGE:-The VM restarted. Any /loop or ScheduleWakeup timer you had died with it. Check git status and your worktree comment, re-arm your standing /loop now with the same prompt as before (your brief under ~/.concertmaster/briefs lists it if you lost it), and carry on.}"
STATE_DIR="$CM_HOME/cache"
boot="${CM_BOOT_EPOCH:-$(awk '$1=="btime"{print $2; exit}' /proc/stat 2>/dev/null)}"
if [ -z "$boot" ]; then cm_warn "boot-sweep.sh: cannot read boot time, nothing to do"; exit 0; fi
STATE="$STATE_DIR/boot-sweep-$boot.tsv"   # handle<TAB>attempts
if [ "$DRY" = 0 ]; then mkdir -p "$STATE_DIR" "$CM_HOME/inbox" 2>/dev/null; touch "$STATE" 2>/dev/null; fi

now_s() { date +%s; }
early_note() { # an early exit must never be silent: leave a note the concertmaster tick reads
  [ "$DRY" = 1 ] && return
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

# newest transcript mtime (epoch) for a worktree path; prints "unknown" when the directory or any
# transcript is missing (a lane we cannot see is never treated as "no turn since boot")
transcript_mtime() {
  local dir; dir="$PROJECTS/$(printf '%s' "$1" | sed 's#[^A-Za-z0-9]#-#g')"
  [ -d "$dir" ] || { echo unknown; return; }
  local f newest=0 m found=0
  for f in "$dir"/*.jsonl; do
    [ -e "$f" ] || continue
    found=1
    m="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)"
    [ "$m" -gt "$newest" ] && newest="$m"
  done
  [ "$found" = 1 ] && echo "$newest" || echo unknown
}
attempts_of() { awk -F'\t' -v h="$1" '$1==h{print $2; f=1} END{if(!f) print 0}' "$STATE" 2>/dev/null; }
set_attempts() { # $1 handle $2 n  (awk, not grep: the handle is data, never a pattern)
  [ "$DRY" = 1 ] && return
  { awk -F'\t' -v h="$1" '$1 != h' "$STATE" 2>/dev/null; printf '%s\t%s\n' "$1" "$2"; } > "$STATE.new" 2>/dev/null && mv "$STATE.new" "$STATE"
}

out=""; sent=0; kept=0
add() { out="$out$1|$2|$3|$4"$'\n'; } # session | handle | result | detail

terms="$(cm_timeout 60 "$ORCA" terminal list --json </dev/null 2>/dev/null | jq -r --arg re "$CM_PATH_MATCH" '.result.terminals[]? | select((.worktreePath // "") | test($re)) | select((.agentIdentity // "") == "claude") | "\(.handle)|\(.worktreePath)"' 2>/dev/null)"
if [ -z "$terms" ]; then
  [ "$DRY" = 1 ] || printf '# boot-sweep %s (boot %s): no Claude terminals found for this project (or Orca did not answer)\n' "$(date -u +%FT%TZ)" "$boot" > "$CM_HOME/inbox/boot-sweep-$(date -u +%Y%m%dT%H%M%SZ)-$$.md" 2>/dev/null
  echo "boot-sweep: no Claude terminals found for this project"; exit 0
fi

# only STANDING lanes of this host (ledger rows with standing==true and host local/unset) are ever
# nudged: a dev or epic worker has no standing /loop to re-arm, and the concertmaster itself is not a lane.
# No readable ledger = send nothing.
LEDGER="$CM_HOME/ledger.json"
STANDING="$(jq -r '.workers // {} | to_entries[] | .value | select(.standing == true and ((.host // "local") == "local")) | (.path // .worktree // .worktreePath // empty)' "$LEDGER" 2>/dev/null | sed -E 's#/\.(/|$)#/#g; s#//+#/#g; s#(.)/+$#\1#' )"
if [ -z "$STANDING" ]; then
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
  if ! grep -qxF -- "$normwt" <<<"$STANDING"; then add "$name" "$handle" not-standing "not a standing lane in the ledger: never nudged"; continue; fi
  m="$(transcript_mtime "$wt")"
  if [ "$m" = unknown ]; then add "$name" "$handle" unknown "no Claude transcript visible for this worktree: not nudged"; kept=$((kept+1)); continue; fi
  if [ "$m" -ge "$boot" ]; then add "$name" "$handle" skipped "active since boot"; continue; fi
  tries="$(attempts_of "$handle")"; tries="${tries:-0}"
  if [ "$tries" -ge 2 ]; then add "$name" "$handle" gave-up "two nudges sent, no turn since boot: left to the concertmaster tick"; kept=$((kept+1)); continue; fi
  screen="$(cm_timeout 30 "$ORCA" terminal read --terminal "$handle" --screen --json </dev/null 2>/dev/null | jq -r 'if .ok == true then ((.result.screen // .result.text // .result.output // "") | tostring) else "" end' 2>/dev/null)"
  bottom="$(printf '%s\n' "$screen" | grep -v '^[[:space:]]*$' | tail -n 12)"
  if [ -z "$bottom" ]; then add "$name" "$handle" unreadable "screen unreadable"; kept=$((kept+1)); continue; fi
  if grep -qiE "$CM_MENU_RE" <<<"$bottom"; then add "$name" "$handle" menu "question menu showing, not typed into"; kept=$((kept+1)); continue; fi
  if tail -n 1 <<<"$bottom" | grep -qE '^[^[:space:]]*[$#%] *$'; then add "$name" "$handle" report "shell prompt, agent gone: resume.sh respawns it"; kept=$((kept+1)); continue; fi
  if ! grep -qiE "$CM_CLAUDE_RE" <<<"$bottom"; then add "$name" "$handle" unreadable "no sign of Claude at the prompt"; kept=$((kept+1)); continue; fi
  if grep -qE 'esc to interrupt' <<<"$bottom"; then add "$name" "$handle" busy "mid-turn"; kept=$((kept+1)); continue; fi
  if [ "$DRY" = 1 ]; then add "$name" "$handle" would-nudge "no turn since boot (transcript $((boot - m))s before boot)"; continue; fi
  t0="$(now_s)"
  resp="$(cm_timeout 60 "$ORCA" terminal send --terminal "$handle" --text "$NUDGE" --enter --json </dev/null 2>/dev/null)"
  if [ "$(printf '%s' "$resp" | jq -r '.ok // false' 2>/dev/null)" != true ]; then add "$name" "$handle" send-failed "orca did not accept the input"; kept=$((kept+1)); continue; fi
  set_attempts "$handle" $((tries + 1))
  ok=0; waited=0
  while [ "$waited" -lt "$CONFIRM_S" ]; do
    sleep 3; waited=$((waited + 3))
    cur="$(transcript_mtime "$wt")"; [ "$cur" != unknown ] && [ "$cur" -ge "$t0" ] && { ok=1; break; }
  done
  if [ "$ok" = 1 ]; then add "$name" "$handle" nudged "turn started ${waited}s after the nudge"; sent=$((sent+1))
  else add "$name" "$handle" unconfirmed "input accepted, no turn within ${CONFIRM_S}s: one retry on the next sweep"; kept=$((kept+1)); fi
done <<<"$terms"

printf '%s' "$out" | awk -F'|' '{printf "%s\t%s\t%s\t%s\n",$1,$2,$3,$4}'
if [ "$DRY" = 0 ]; then
  note="$CM_HOME/inbox/boot-sweep-$(date -u +%Y%m%dT%H%M%SZ)-$$.md"
  {
    printf '# boot-sweep %s (boot %s): %s nudged, %s not nudged\n\n' "$(date -u +%FT%TZ)" "$boot" "$sent" "$kept"
    printf 'session | terminal | result | detail\n--- | --- | --- | ---\n'
    printf '%s' "$out" | awk -F'|' '{printf "%s | %s | %s | %s\n",$1,$2,$3,$4}'
  } > "$note" 2>/dev/null
fi
exit 0
