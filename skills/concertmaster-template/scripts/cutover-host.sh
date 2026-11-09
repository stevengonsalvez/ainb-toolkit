#!/usr/bin/env bash
# cutover-host.sh: move the Claude lanes of ONE host from Orca terminals to Plugly terminals, one lane at a time.
#
#   scripts/cutover-host.sh <host> [--apply] [--lane <worker-id>]... [--except <worker-id>]... [--wait-idle-s N] [--skip-census]
#
# <host> is "local" for this machine, else the environment name (the same words cm_cli_host takes).
# DEFAULT IS A DRY RUN: it reads (host lists, worktree ps, terminal lists, live-agent, the ledger) and prints the
# pre-check lines and the plan table, and changes nothing: no terminal create, close or send, no ledger, handle
# file or journal write, no lock. --apply acts. The first real use is on one host after a deploy window, driven by
# the concertmaster, canary first: --lane <one worker>. references/cutover.md has the procedure.
#
# Plan table, one row per ledger worker on the host (the handle is resolved from the LIVE agent through
# live-agent.sh, never copied from the ledger): lane, worker, worktree, terminal handle, agent, state, action.
#   cutover       claude, one live agent, on an Orca terminal: this script moves it
#   manual        the agent is not claude (codex, agy): never restarted with `claude --continue`; by hand
#   duplicate     two live agents in one tree (or two ledger rows on one path): ask the owner; --apply refuses
#                 while one is selected
#   dead          no live agent: resume.sh, not this script
#   skip: <why>   self (the terminal running this script), already on plugly, not selected (--lane, --except), no handle,
#                 live check could not run, the live model cannot be read from the pane (listed under `look:`), the
#                 ledger model or effort disagrees with the live pane (model mismatch, effort mismatch)
#
# The dry run prints, after the table, a `rows:` line (counts by plan row kind) and a `look:` list of the selected lanes whose
# live model could not be read.
#
# Pre-checks, each a named line, all must pass (exit 1 otherwise, in a dry run too): ledger-readable,
# plugly-host-registered (the host is in `plugly host list`), plugly-terminals (the plugly runtime answers),
# orca-host-reachable, claude-binary (spawn-verify.sh resolve; for a remote host over ssh to cm_ssh_target: $CM_SSH_TARGET, else a
# ledger hostname that is an address, else the host name as an ssh alias), no-cutover-lock ($CM_HOME/cutover-host.lock), no-resume-lock (resume.sh is not mid-run).
#
# --apply, per lane, in this order: workers first, then standing lanes (ledger standing: true, or a lane-shaped
# name), the pr-sweeper LAST (it merges and relays reviews: it stays on its old terminal until every other lane
# has moved, and a failed run leaves it untouched). Never in parallel. A lane that is a duplicate refuses the run.
#   a  wait for an idle Claude prompt (no menu, no running tool, no background shell, Monitor or subagent), up to
#      --wait-idle-s (300): then `skip: busy`
#      and on to the next lane (re-run later). A lane is NEVER force-closed.
#   b  journal entry `cm:handover cutover to plugly <UTC time>` (lane-journal.sh): the lane journal records why
#   c  close the Orca terminal by its EXACT handle: re-resolved through lane-handles.sh after the idle wait, and the
#      terminal list must carry that handle on THIS worktree as a claude terminal (else the lane is skipped)
#   d  create a Plugly terminal in the SAME worktree path: `<claude> --continue --model <m> --effort <e>` with the
#      model and effort the lane's CURRENT pane shows (read by spawn-verify.sh read, the parser `check` uses; the plan
#      row, and again right before the close). The ledger model is "" for standing lanes and a bare alias for a worker on
#      the real fleet, so it is never the source: when it IS a full claude-<family>-<n>-<m> (or the ledger effort a level)
#      it must agree with the pane or the lane is skipped; a bare alias is ignored;
#      <claude> is the absolute path from spawn-verify.sh resolve. A create that fails, times out or answers in a
#      shape the parser does not read may still have made a terminal: the plugly list is compared with the one taken
#      before the close and every new terminal on the worktree is closed by exact handle before anything else starts
#   e  spawn-verify.sh check on the new terminal must exit 0 for THAT model and effort (a plain shell prompt is not proof)
#   f  rewrite the handle: lane-handles.sh --worker <id> (handle file and ledger), then cm_worker_set_handle
#   g  re-arm the /loop with the nudge text boot-sweep.sh uses (lib.sh CM_NUDGE_TICK) and wait for a turn
# Any failure in c..g ROLLS BACK that lane: the new Plugly terminal is closed by its exact handle, an Orca terminal
# running `claude --continue --model <m> --effort <e>` is created in the same path (resume.sh's call, with the live model and effort) and verified, the handle is
# refreshed, `cutover failed: <step>` goes in the lane journal, and the run STOPS (exit 1) with a report of the
# lanes done, failed and untouched. A rollback that cannot recreate the terminal says LANE DOWN (exit 3): resume.sh.
#
# After the last lane (unless --skip-census): the orphan check, under the plugly CLI, for the lanes this run owns
# (cut over now, or already on plugly). An orphan is a live agent whose terminal is not the ledger handle, a ledger
# handle that is not a live terminal in plugly, or an Orca terminal still open on a cut-over worktree. Any orphan:
# list them, exit 1.
#
# --lane may repeat; it limits the run to those workers (a canary). --except may repeat; it leaves those workers out (the
# concertmaster's own lane when this script runs from an operator shell: only the terminal RUNNING the script is `skip: self`,
# so the concertmaster's row plans as `cutover` there unless it is left out). --except wins over --lane. --skip-census skips the orphan check and exists
# for the test: with --apply it is refused unless CM_CUTOVER_TEST=1.
#
# The caller's own terminal is never closed: a lane whose terminal is $ORCA_TERMINAL_HANDLE or
# $PLUGLY_TERMINAL_HANDLE is `skip: self`. Run the script from outside the lanes.
#
# Exit: 0 every selected lane is on plugly (or the dry run is clean); 1 refused, a lane failed (rolled back), or
# orphans; 2 usage (also --apply on a remote host: the turn check reads this machine's transcripts); 3 a lane has no
# terminal (LANE DOWN), or is STRANDED on a plugly terminal that would not close, or the run was interrupted mid-lane;
# 4 finished, but a lane was skipped (busy, changed since the plan, journal failed) or a selected lane is one this
# script does not move (manual, dead, self, ...): re-run later or see the plan.
# resume.sh refuses to act (exit 4) while this script holds its lock, so a tick cannot start a second agent in the gap.
# Env: CM_HOME, CM_CLI_KIND is NOT read (both CLIs are driven explicitly: ORCA_CLI_COMMAND / PLUGLY_CLI_COMMAND),
#      CM_CUTOVER_POLL_S (3), CM_CUTOVER_VERIFY_WAIT_S (45), CM_CUTOVER_CALL_S (60), CM_CUTOVER_EXIT_WAIT_S (15,
#      how long the old agent may take to exit after the close), CM_BOOT_CONFIRM_S (60, the
#      turn-started wait), CM_TICK_NUDGE (nudge text), CM_CUTOVER_TEST=1 (test only: allows --skip-census with
#      --apply), CM_TEST=1 with CM_LIVE_AGENT / CM_LANE_HANDLES (test seams, as in lane-handles.sh).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

usage() { awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0" >&2; exit 2; }

HOST=""; APPLY=0; SKIP_CENSUS=0; WAIT_IDLE_S=300; LANES=(); EXCEPT=()
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --skip-census) SKIP_CENSUS=1 ;;
    --lane)
      [ $# -ge 2 ] && [ -n "$2" ] || { cm_warn "cutover-host.sh: --lane needs a worker id"; exit 2; }
      case "$2" in .*|*[!A-Za-z0-9._-]*) cm_warn "cutover-host.sh: \"$2\" is not a worker id"; exit 2 ;; esac
      LANES+=("$2"); shift ;;
    --except)
      [ $# -ge 2 ] && [ -n "$2" ] || { cm_warn "cutover-host.sh: --except needs a worker id"; exit 2; }
      case "$2" in .*|*[!A-Za-z0-9._-]*) cm_warn "cutover-host.sh: \"$2\" is not a worker id"; exit 2 ;; esac
      EXCEPT+=("$2"); shift ;;
    --wait-idle-s)
      [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]] || { cm_warn "cutover-host.sh: --wait-idle-s takes whole seconds"; exit 2; }
      WAIT_IDLE_S=$((10#$2)); shift ;;
    -h|--help) awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    -*) cm_warn "cutover-host.sh: unknown arg: $1"; usage ;;
    *) [ -z "$HOST" ] || { cm_warn "cutover-host.sh: one host only (got \"$HOST\" and \"$1\")"; exit 2; }; HOST="$1" ;;
  esac
  shift
done
[ -n "$HOST" ] || { cm_warn "cutover-host.sh: a host is required (local, or the environment name)"; usage; }
case "$HOST" in -*|*[[:cntrl:]]*) cm_warn "cutover-host.sh: \"$HOST\" is not a host name"; exit 2 ;; esac
[ "$HOST" != "this machine" ] || HOST=local
if [ "$APPLY" = 1 ] && [ "$SKIP_CENSUS" = 1 ] && [ "${CM_CUTOVER_TEST:-}" != 1 ]; then
  cm_warn "cutover-host.sh: --skip-census with --apply is refused (the orphan check is the end of the run); it exists for the test (CM_CUTOVER_TEST=1)"; exit 2
fi
command -v jq >/dev/null 2>&1 || { cm_warn "cutover-host.sh: missing dependency: jq"; exit 2; }
if [ "$APPLY" = 1 ] && [ "$HOST" != local ]; then
  cm_warn "cutover-host.sh: --apply is refused for the remote host \"$HOST\": the turn check reads this machine's Claude transcripts, so a remote lane could never confirm its nudge. Run it ON that host (host local), or use the dry run"; exit 2
fi

# Both CLIs are driven by name, whatever CM_CLI_KIND says: the cutover reads and closes on Orca, creates on Plugly.
ORCA="$(CM_CLI_KIND=orca cm_cli)" || exit 2
PLUGLY="$(CM_CLI_KIND=plugly cm_cli)" || exit 2
# host selector words per CLI (both print the same today; asked per kind so a divergence stays one change in lib.sh)
host_into() { local k="$CM_CLI_KIND" rc; CM_CLI_KIND="$1"; cm_cli_host_into "$2" "$3"; rc=$?; CM_CLI_KIND="$k"; return "$rc"; }
OA=(); PA=()
host_into orca OA "$HOST" || exit 2
host_into plugly PA "$HOST" || exit 2
VENV=(); if [ "$HOST" != local ]; then VENV=(--environment "$HOST"); fi   # spawn-verify.sh takes --environment, nothing for local

# These reach $(( )) and sleep: whole seconds only (an unchecked value such as a[$(cmd)] would run a command in $(( ))).
for _v in CM_CUTOVER_CALL_S CM_CUTOVER_POLL_S CM_CUTOVER_VERIFY_WAIT_S CM_BOOT_CONFIRM_S CM_CUTOVER_EXIT_WAIT_S CM_CUTOVER_CREATE_GRACE_S; do
  case "${!_v:-0}" in *[!0-9]*) cm_warn "cutover-host.sh: $_v must be whole seconds, got \"${!_v}\""; exit 2 ;; esac
done
# read as decimal (10#): 08 and 010 are not octal, and a bad number inside $(( )) would drop the whole command after a close
CALL_S=$((10#${CM_CUTOVER_CALL_S:-60})); POLL_S=$((10#${CM_CUTOVER_POLL_S:-3})); VERIFY_S=$((10#${CM_CUTOVER_VERIFY_WAIT_S:-45}))
CONFIRM_S=$((10#${CM_BOOT_CONFIRM_S:-60})); EXIT_WAIT_S=$((10#${CM_CUTOVER_EXIT_WAIT_S:-15})); CREATE_GRACE_S=$((10#${CM_CUTOVER_CREATE_GRACE_S:-10}))
# a zero CALL_S turns the timeout off (a CLI call could hang); a zero POLL_S makes the two "clear" samples one sample (tests only)
if [ "$CALL_S" -lt 1 ]; then cm_warn "cutover-host.sh: CM_CUTOVER_CALL_S must be at least 1"; exit 2; fi
if [ "$POLL_S" -lt 1 ] && [ "${CM_TEST:-}" != 1 ]; then cm_warn "cutover-host.sh: CM_CUTOVER_POLL_S must be at least 1"; exit 2; fi
NUDGE="${CM_TICK_NUDGE:-$CM_NUDGE_TICK}"
NUDGE_FRAG="$(printf '%s' "$NUDGE" | grep -oE '[A-Za-z .,]{12,}' | awk 'length > m { m = length; b = $0 } END { print b }')"; [ -n "$NUDGE_FRAG" ] || NUDGE_FRAG="$NUDGE"
JSAN="$HERE/jsanitize"
SPAWN_VERIFY="$HERE/spawn-verify.sh"; LANE_JOURNAL="$HERE/lane-journal.sh"; LANE_HANDLES="$CM_LANE_HANDLES_SH"
LIVE_AGENT="$HERE/live-agent.sh"
if [ -n "${CM_LIVE_AGENT:-}" ]; then
  if [ "${CM_TEST:-}" = 1 ]; then LIVE_AGENT="$CM_LIVE_AGENT"; else cm_warn "cutover-host.sh: CM_LIVE_AGENT ignored (it needs CM_TEST=1)"; fi
fi
LOCK="$CM_HOME/cutover-host.lock"
LEDGER="$(cm_ledger_path)"
US=$'\037'

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cm-cutover-host.XXXXXX")" || { cm_warn "cutover-host.sh: cannot create a temp dir"; exit 2; }
OWN_LOCK=0
cleanup() {
  if [ "$OWN_LOCK" = 1 ]; then rm -f -- "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true; fi
  rm -rf -- "${TMP:?}"
}
trap cleanup EXIT
# A signal in the middle of a lane (after the close, before the lane is done) must not leave a lane with no terminal and
# no message: note it in the journal, say so, exit 3. Outside a lane it is a plain exit 130.
CUR_ID=""; CUR_JN=""; CUR_STAGE=""; CUR_EFF="high"; PL_BEFORE=""; STRANDED=0
on_signal() {
  if [ -n "$CUR_STAGE" ]; then
    "$LANE_JOURNAL" append "${CUR_JN:-$CUR_ID}" "cutover interrupted at $CUR_STAGE: the lane may have no terminal or two, run resume.sh and check for a stray plugly terminal" >/dev/null 2>&1
    printf 'cutover-host: interrupted at %s for %s: LANE DOWN? check its terminals now (resume.sh), a stray plugly terminal may exist\n' "$CUR_STAGE" "$CUR_ID"
    exit 3
  fi
  if [ -n "$CUR_JN" ]; then "$LANE_JOURNAL" append "$CUR_JN" "cutover postponed: interrupted before the close, nothing was closed" >/dev/null 2>&1; fi
  exit 130
}
trap on_signal INT TERM HUP

# ---- CLI calls: JSON on stdout, nothing on failure (callers test .ok) ---------------------------------------------
o_call() { cm_timeout "$CALL_S" "$ORCA" "$@" ${OA[@]+"${OA[@]}"} --json </dev/null 2>/dev/null | "$JSAN"; }
p_call() { cm_timeout "$CALL_S" "$PLUGLY" "$@" ${PA[@]+"${PA[@]}"} --json </dev/null 2>/dev/null | "$JSAN"; }
jok() { jq -e '.ok == true' >/dev/null 2>&1; }
norm_path() { printf '%s' "$1" | sed -E 's#/\.(/|$)#/#g; s#//+#/#g; s#(.)/+$#\1#'; }
plain_handle() { case "${1:-}" in ''|-*|*[!A-Za-z0-9._:-]*) return 1 ;; esac; }
now_s() { date +%s; }
say() { printf '%s\n' "$*"; }

# terminals_of <orca|plugly> <outfile>: handle<TAB>worktree path<TAB>agent, one per terminal. Returns 1 when the list failed.
terminals_of() {
  local kind="$1" out="$2" j
  if [ "$kind" = orca ]; then j="$(o_call terminal list)"; else j="$(p_call terminal list)"; fi
  printf '%s' "$j" | jok || return 1
  printf '%s' "$j" | jq -r '.result.terminals[]? | [(.handle // ""), (.worktreePath // ""), (.agentIdentity // "")] | @tsv' > "$out" 2>/dev/null || return 1
}
# in_terminals <file> <handle>: the handle is a terminal in that list
in_terminals() { awk -F'\t' -v h="$2" '$1 == h { f = 1 } END { exit !f }' "$1"; }
# listed_on <file> <handle> <lane path>: 0 the handle is listed exactly once, on that worktree, under claude (or no identity yet);
# 1 not listed; 2 listed elsewhere or under another agent (an inherited handle: another tree's terminal)
listed_on() {
  local hh hp ha n=0 good=0 np
  np="$(norm_path "$3")"
  while IFS=$'\t' read -r hh hp ha; do
    [ "$hh" = "$2" ] || continue
    n=$((n + 1))
    if [ "$(norm_path "$hp")" = "$np" ] && { [ -z "$ha" ] || [ "$ha" = claude ]; }; then good=$((good + 1)); fi
  done < "$1"
  [ "$n" -gt 0 ] || return 1
  if [ "$n" = 1 ] && [ "$good" = 1 ]; then return 0; fi
  return 2
}

# ---- 1. pre-checks ------------------------------------------------------------------------------------------------
CHECK_FAIL=0
check() { # <name> <ok|FAIL> <detail>
  [ "$2" = ok ] || CHECK_FAIL=$((CHECK_FAIL + 1))
  printf 'check %s: %s%s\n' "$1" "$2" "${3:+ ($3)}"
}

say "cutover-host: host $HOST, $([ "$APPLY" = 1 ] && echo APPLY || echo 'dry run (no changes)')"
if [ -s "$LEDGER" ] && jq -e 'type == "object"' "$LEDGER" >/dev/null 2>&1 && cm_ledger_guard "$LEDGER" 2>/dev/null; then
  check ledger-readable ok
else
  check ledger-readable FAIL "$LEDGER is missing, unreadable or another project's"
fi

hl="$(cm_timeout "$CALL_S" "$PLUGLY" host list --json </dev/null 2>/dev/null | "$JSAN")"
if ! printf '%s' "$hl" | jok; then
  check plugly-host-registered FAIL "plugly host list did not answer, so host \"$HOST\" cannot be confirmed"
elif printf '%s' "$hl" | jq -e --arg h "$HOST" '[.result.hosts[]? | select(($h == "local" and .kind == "local") or (.name == $h))] | length > 0' >/dev/null 2>&1; then
  check plugly-host-registered ok
else
  check plugly-host-registered FAIL "host \"$HOST\" is not in the plugly host list: register it in Plugly first"
fi

if terminals_of plugly "$TMP/plugly-terms.tsv"; then
  check plugly-terminals ok
else
  check plugly-terminals FAIL "plugly terminal list failed for host \"$HOST\""
  : > "$TMP/plugly-terms.tsv"
fi

if o_call worktree ps | jok && terminals_of orca "$TMP/orca-terms.tsv"; then
  check orca-host-reachable ok
else
  check orca-host-reachable FAIL "orca worktree ps / terminal list did not answer for host \"$HOST\""
  : > "$TMP/orca-terms.tsv"
fi

CLAUDE=""; SSH_BAD=""
SSH_ARGS=()
if [ "$HOST" != local ]; then
  tgt="$(cm_ssh_target "$HOST")"   # CM_SSH_TARGET, else a ledger hostname that is an address, else the host name as an ssh alias (lib.sh)
  SSH_ARGS=(--ssh "$tgt")
  case "$tgt" in ''|-*|*[[:space:]]*) SSH_ARGS=(--ssh "invalid-target"); SSH_BAD="$tgt" ;; esac   # never an ssh option or a word list
fi
if [ -n "$SSH_BAD" ]; then
  check claude-binary FAIL "the ssh target \"$SSH_BAD\" starts with a dash or holds whitespace: refused"
elif CLAUDE="$("$SPAWN_VERIFY" resolve ${SSH_ARGS[@]+"${SSH_ARGS[@]}"} 2>"$TMP/resolve.err")" && [ -n "$CLAUDE" ]; then
  if [[ "$CLAUDE" =~ ^/[A-Za-z0-9._/+-]+$ ]]; then check claude-binary ok "$CLAUDE"
  else check claude-binary FAIL "resolved path has characters that cannot be typed into a terminal safely"; fi
else
  check claude-binary FAIL "$(head -c 200 "$TMP/resolve.err" | tr '\n' ' ')"
fi

if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
  lp="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [ -n "$lp" ] && kill -0 "$lp" 2>/dev/null; then lw="held by pid $lp"; else lw="left by pid ${lp:-unknown}, not running: remove $LOCK by hand once nothing else is cutting over"; fi
  check no-cutover-lock FAIL "$LOCK $lw"
else
  check no-cutover-lock ok
fi

# resume.sh (the tick's standing-dead call, or the owner) must not be creating agents while lanes move. Checked here and
# again right after this run takes its own lock (a resume that started in between).
if cm_resume_lock_held; then check no-resume-lock FAIL "a resume.sh run holds $CM_HOME/resume.lock: wait for it to finish"; else check no-resume-lock ok; fi

if [ "$CHECK_FAIL" -gt 0 ]; then
  say "cutover-host: refused: $CHECK_FAIL pre-check(s) failed, nothing was changed"
  exit 1
fi

# the two plan reasons the summary lines look for: one definition, used where the reason is made and where it is counted
WHY_UNREAD="cannot read the live model"; WHY_NOTSEL="not selected"
# live_model <orca handle>: what the lane's CURRENT terminal shows it runs, read by `spawn-verify.sh read` (the parser `check`
# uses, so the plan and the later banner check cannot disagree about what a banner says). Prints "claude-<family>-<n>-<m>
# <effort>" and returns 0, or the reason and returns 1 (the banner scrolled off, another agent, a pane that does not answer).
# The ledger `model` is NOT consulted here: it is "" for standing lanes and a bare alias for workers on the real fleet.
live_model() {
  local out rc
  out="$(CM_CLI_KIND=orca "$SPAWN_VERIFY" read --terminal "$1" ${VENV[@]+"${VENV[@]}"} 2>/dev/null </dev/null)"; rc=$?   # stdout only: a warning on stderr must not spoil the match
  if [ "$rc" = 0 ] && [[ "$out" =~ ^live:\ ([a-z]+)-([0-9]+)\.([0-9]+)\ ([a-z]+)$ ]]; then
    printf 'claude-%s-%s-%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
    return 0
  fi
  printf '%s\n' "$(printf '%s' "${out:-no answer}" | tail -n 1 | sed 's/^read: FAIL //' | tr -cd 'A-Za-z0-9 .,:_/()=+-' | cut -c1-80)"
  return 1
}

# ---- 2. the plan --------------------------------------------------------------------------------------------------
# One row per ledger worker on this host with a worktree path, ordered: workers, standing lanes, pr-sweeper last.
SELF_H=()
[ -z "${ORCA_TERMINAL_HANDLE:-}" ] || SELF_H+=("$ORCA_TERMINAL_HANDLE")
[ -z "${PLUGLY_TERMINAL_HANDLE:-}" ] || SELF_H+=("$PLUGLY_TERMINAL_HANDLE")
is_self() { local s; for s in ${SELF_H[@]+"${SELF_H[@]}"}; do [ -n "$1" ] && [ "$s" = "$1" ] && return 0; done; return 1; }
selected() {
  local l
  for l in ${EXCEPT[@]+"${EXCEPT[@]}"}; do [ "$l" = "$1" ] && return 1; done
  [ "${#LANES[@]}" -gt 0 ] || return 0
  for l in "${LANES[@]}"; do [ "$l" = "$1" ] && return 0; done
  return 1
}

# shellcheck disable=SC2016  # a jq program: $h, $shape are jq variables bound by --arg
WORKERS_JQ="$CM_JQ_STATE_DEFS $CM_JQ_NORMP"'
  def rank: if ((.id | test("pr-sweeper")) or (.lane | test("pr-sweeper"))) then 2
            elif (.standing or (.id | test($shape)) or (.lane | test($shape))) then 1 else 0 end;
  [ (.workers // {}) | to_entries[] | select(.value | type == "object")
    | select((.value.state // "running") | cm_state_dead | not)
    | { id: .key, host: (.value.host // "local"), lane: ((.value.lane // .key) | tostring),
        path: ((.value.path // .value.worktree // .value.worktreePath // "") | tostring),
        term: ((.value.terminal // "") | tostring), model: ((.value.model // "") | tostring),
        standing: (.value.standing == true), state: ((.value.state // "running") | tostring),
        effort: (if (.value | has("effort")) then ((.value.effort // "") | tostring | if . == "" then "-" else . end) else "" end) }
    | select(.host == $h and .path != "") ]
  | map(. + { np: (.path | normp) }) | (group_by(.np) | map(select(length > 1) | .[0].np)) as $dupp
  | map(. + { dupPath: (.np | IN($dupp[])),
              ok: (((.id | type) == "string") and (.id | test("\\A[A-Za-z0-9_-][A-Za-z0-9._-]*\\z"))
                   and (.path | startswith("/")) and ([.lane, .path, .term, .model, .state, .effort] | all(test("[[:cntrl:]]") | not))) })
  | sort_by([rank, .id]) | .[]
  | if .ok then [ rank, .id, .lane, .path, .term, .model, (.standing | tostring), .state, (.dupPath | tostring), "true", .effort ] | join("\u001f")
    else "BAD\u001f" + (.id | @json) end'
jq -r --arg h "$HOST" --arg shape "$CM_LANE_SHAPE_RE" "$WORKERS_JQ" "$LEDGER" > "$TMP/workers.us" 2>/dev/null \
  || { cm_warn "cutover-host.sh: cannot read the workers in $LEDGER"; exit 1; }

: > "$TMP/plan.us"
# plan_row: rank id lane path ledger-term model standing state live-handle live-agent action reason selected platform effort
plan_row() { local IFS="$US"; printf '%s\n' "$*" >> "$TMP/plan.us"; }
while IFS="$US" read -r rank id lane path term model standing state dupp ok eff; do
  [ -n "$id" ] || continue
  if [ "$rank" = BAD ]; then   # a row that cannot be trusted is never split into fields: only its quoted id is shown
    plan_row 3 "$id" - - - - false - - - skip "ledger row is not usable (worker id, path or a field has a control character)" "$(selected "$id" && echo 1 || echo 0)" - -
    continue
  fi
  sel=1; selected "$id" || sel=0
  act=""; why=""; lh=""; la="-"; plat="-"; led_eff="$eff"; eff="-"   # the effort that is relaunched is the live one; a ledger value only has to agree
    out="$("$LIVE_AGENT" "$path" --host "$HOST" 2>/dev/null)"; rc=$?
    case "$rc" in
      0) ;;
      1) act=dead; why="no live agent: hand it to resume.sh" ;;
      *) act=skip; why="live check could not run (exit $rc)" ;;
    esac
    if [ -z "$act" ]; then
      nrows="$(printf '%s\n' "$out" | grep -c . || true)"
      handles="$(printf '%s\n' "$out" | cut -f2 | grep -v '^$' | sort -u)"
      nh="$(printf '%s' "$handles" | grep -c . || true)"
      blank=0; if printf '%s\n' "$out" | awk -F'\t' '$2 == "" { f = 1 } END { exit !f }'; then blank=1; fi
      first="$(printf '%s\n' "$out" | sort -n -k1,1 | head -n 1)"
      la="$(printf '%s' "$first" | cut -f3)"; la="${la:--}"
      lh="$(printf '%s' "$handles" | head -n 1)"
      if [ "$nh" -ge 2 ] || { [ "$nh" -ge 1 ] && [ "$blank" = 1 ]; }; then
        act=duplicate; why="$nrows live agent processes with $nh terminal handles in one worktree: ask the owner"
      elif [ "$dupp" = true ]; then
        act=duplicate; why="two ledger workers share this worktree path: ask the owner"
      elif [ "$nh" = 0 ]; then
        act=skip; why="live agent has no terminal handle (not started from a terminal)"
      elif ! plain_handle "$lh"; then
        act=skip; why="live handle is not a plain token"
      elif is_self "$lh" || is_self "$term"; then
        act=skip; why="self: this is the terminal running this script; run it from outside the lanes"
      elif [ "$la" != claude ]; then
        act=manual; why="agent is $la, never restarted with claude --continue; move it by hand"
      else
        inp=0; ino=0; listed_on "$TMP/plugly-terms.tsv" "$lh" "$path"; lp=$?; listed_on "$TMP/orca-terms.tsv" "$lh" "$path"; lo=$?
        [ "$lp" = 0 ] && inp=1
        [ "$lo" = 0 ] && ino=1
        if [ "$lp" = 2 ] || [ "$lo" = 2 ]; then
          act=manual; why="terminal $lh is listed on another worktree or under another agent (an inherited handle?): move this lane by hand"
        elif [ "$inp" = 1 ] && [ "$ino" = 1 ]; then act=skip; why="handle $lh is in both terminal lists: cannot tell the runtimes apart"
        elif [ "$inp" = 1 ]; then
          plat=plugly
          if [ "$term" = "$lh" ]; then act=onplugly; why="already on plugly"
          else act=skip; why="live terminal $lh is on plugly but the ledger holds ${term:-none}: run lane-handles.sh --worker $id"; fi
        elif [ "$ino" = 1 ]; then
          plat=orca
          # model and effort come from the LIVE pane, never from the ledger (empty for standing lanes, a bare alias for a worker)
          if [ "$sel" = 0 ]; then
            act=skip; why="live model not read"   # not selected: no pane read (a canary on a big host must not read every pane)
          elif ! lm="$(live_model "$lh")"; then
            act=skip; why="$WHY_UNREAD of $lh ($lm): look at the pane; nothing is relaunched on a guess"
          else
            lmodel="${lm% *}"; leff="${lm#* }"
            if [[ "$model" =~ ^claude-[a-z]+-[0-9]+-[0-9]+$ ]] && [ "$model" != "$lmodel" ]; then
              act=skip; why="model mismatch (ledger $model, live $lmodel)"
            elif [ -n "$led_eff" ] && [ "$led_eff" != "-" ] && ! [[ "$led_eff" =~ ^(low|medium|high|xhigh|max)$ ]]; then
              act=skip; why="ledger effort \"$led_eff\" is not a level (low, medium, high, xhigh, max): fix or remove workers.$id.effort"
            elif [[ "$led_eff" =~ ^(low|medium|high|xhigh|max)$ ]] && [ "$led_eff" != "$leff" ]; then
              act=skip; why="effort mismatch (ledger $led_eff, live $leff)"
            else act=cutover; why=""; model="$lmodel"; eff="$leff"; fi
          fi
        else act=skip; why="live terminal $lh is in neither terminal list"; fi
      fi
    fi
  if [ "$sel" = 0 ]; then why="$WHY_NOTSEL (--lane or --except); was: ${act}${why:+, $why}"; act=skip; fi
  plan_row "$rank" "$id" "$lane" "$path" "${term:--}" "${model:--}" "$standing" "$state" "${lh:--}" "$la" "$act" "$why" "$sel" "$plat" "$eff"
done < "$TMP/workers.us"

# the table: lane, worker, worktree, terminal handle (live), agent, state, action
say ""
{
  printf 'lane\tworker\tworktree\thandle\tagent\tstate\taction\n'
  while IFS="$US" read -r rank id lane path term model standing state lh la act why sel plat eff; do
    case "$act" in cutover) a=cutover ;; onplugly) a="skip: $why" ;; *) a="$act: $why" ;; esac
    case "$act" in manual|duplicate|dead) a="$act ($why)" ;; esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$lane" "$id" "$path" "$lh" "$la" "${state:--}" "$a"
  done < "$TMP/plan.us"
} > "$TMP/table.tsv"
if command -v column >/dev/null 2>&1; then column -t -s "$(printf '\t')" "$TMP/table.tsv"; else cat "$TMP/table.tsv"; fi
say ""

NCUT="$(awk -F"$US" '$11 == "cutover" { n++ } END { print n + 0 }' "$TMP/plan.us")"
say "plan: $NCUT lane(s) to cut over, in this order (workers, standing lanes, pr-sweeper last):"
awk -F"$US" '$11 == "cutover" { n++; print "  " n ". " $2 }' "$TMP/plan.us"
# counts by plan row kind (a skip is one kind), then the lanes whose live model could not be read: a person looks at those panes
say "rows: $(awk -F"$US" -v w="$WHY_NOTSEL" '{ k = ($11 == "skip" && $13 == 0 && index($12, w) == 1) ? "not-selected" : $11; n[k]++; t++ } END { printf "%d total", t; m = split("cutover onplugly manual duplicate dead skip not-selected", o, " "); for (i = 1; i <= m; i++) if (n[o[i]]) printf ", %s %d", o[i], n[o[i]] }' "$TMP/plan.us")"
NUNREAD="$(awk -F"$US" -v u="$WHY_UNREAD" '$11 == "skip" && index($12, u) == 1 { n++ } END { print n + 0 }' "$TMP/plan.us")"
if [ "$NUNREAD" -gt 0 ]; then
  say "look: $NUNREAD lane(s) whose live model could not be read (nothing is relaunched on a guess; open the pane, or re-run when the status line is on screen):"
  awk -F"$US" -v u="$WHY_UNREAD" '$11 == "skip" && index($12, u) == 1 { print "  " $2 ": " $12 }' "$TMP/plan.us"
fi
for l in ${LANES[@]+"${LANES[@]}"}; do
  awk -F"$US" -v l="$l" '$2 == l { f = 1 } END { exit !f }' "$TMP/plan.us" || { cm_warn "cutover-host.sh: --lane $l is not a worker on host $HOST in the ledger"; exit 2; }
done
for l in ${EXCEPT[@]+"${EXCEPT[@]}"}; do
  awk -F"$US" -v l="$l" '$2 == l { f = 1 } END { exit !f }' "$TMP/plan.us" || { cm_warn "cutover-host.sh: --except $l is not a worker on host $HOST in the ledger"; exit 2; }
done

if [ "$APPLY" = 0 ]; then
  say "dry run: nothing was changed. Re-run with --apply (canary first: --lane <one worker>)."
  exit 0
fi

# ---- 3. apply -----------------------------------------------------------------------------------------------------
DUPS="$(awk -F"$US" '$11 == "duplicate" && $13 == 1 { print $2 }' "$TMP/plan.us" | tr '\n' ' ')"
if [ -n "$DUPS" ]; then
  say "cutover-host: refused: duplicate row(s): ${DUPS}: ask the owner which agent owns the worktree, or leave them out with --except <worker> (or run only the others with --lane)"
  exit 1
fi
if [ "$NCUT" = 0 ]; then say "cutover-host: no lane to cut over"; fi

if ! mkdir "$LOCK" 2>/dev/null; then
  cm_warn "cutover-host.sh: $LOCK appeared since the pre-check: another run holds it"; exit 1
fi
OWN_LOCK=1
printf '%s\n' "$$" > "$LOCK/pid"
if cm_resume_lock_held; then
  say "cutover-host: refused: a resume.sh run started while the plan was being made ($CM_HOME/resume.lock); nothing was changed"
  exit 1
fi

DONE=(); FAILED=""; SKIPPED=(); UNTOUCHED=(); NOT_MOVED=()
# selected lanes the script does not move (manual, dead, self, no handle, model without a banner form ...): not "done"
while IFS= read -r nm; do [ -z "$nm" ] || NOT_MOVED+=("$nm"); done < <(awk -F"$US" '$13 == 1 && $11 != "cutover" && $11 != "onplugly" { print $2 }' "$TMP/plan.us")
journal_name() { # <lane label or worker id>
  "$LANE_JOURNAL" name "$1" 2>/dev/null
}
journal() { # <journal name> <text>: best effort for failure notes, the caller checks the handover entry
  "$LANE_JOURNAL" append "$1" "$2" >/dev/null 2>&1
}
clean_text() { printf '%s' "$1" | tr -cd 'A-Za-z0-9 .,:_/()=+-' | cut -c1-160; }

pane_text() { # <orca|plugly> <handle>: the screen, or nothing
  local j
  if [ "$1" = orca ]; then j="$(o_call terminal read --terminal "$2" --screen)"; else j="$(p_call terminal read --terminal "$2" --screen)"; fi
  printf '%s' "$j" | jq -r 'if .ok == true then (((.result.terminal.tail // empty) | if type == "array" then join("\n") else tostring end | select(length > 0)) // .result.screen // .result.text // .result.output // "") | tostring else "" end' 2>/dev/null
}
# What Claude Code's footer and task rows show while background work runs: shells, Monitors, background subagents and
# tasks ("1 shell", "2 background tasks", "ctrl+t to show tasks", a "◯" task row). A prompt with any of them reads idle
# to the other detectors (lib.sh CM_FOOTER_RE counts task rows as part of a healthy pane), but closing the terminal
# kills that work, so here they mean busy. Conservative on purpose: a false "busy" only skips the lane for a re-run.
CUTOVER_BG_RE='[0-9]+ (local |background |remote )?(shell|task|agent|monitor|subagent|bash)(e?s)?\b|in the background|ctrl\+t to (show|manage) (tasks|shells|agents)|to manage (tasks|shells)|background (task|shell|agent|monitor)'
# pane_state <text>: idle | busy | background | menu | unreadable | shell
pane_state() {
  local bottom
  bottom="$(printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | tail -n 12)"
  [ -n "$bottom" ] || { echo unreadable; return; }
  if printf '%s\n' "$bottom" | grep -qiE "$CM_MENU_RE"; then echo menu; return; fi
  if printf '%s\n' "$bottom" | grep -qE 'esc to interrupt'; then echo busy; return; fi
  if printf '%s\n' "$bottom" | tail -n 4 | grep -qiE "$CUTOVER_BG_RE" || printf '%s\n' "$bottom" | grep -qE '^[[:space:]]*◯'; then echo background; return; fi
  if printf '%s\n' "$bottom" | tail -n 1 | grep -qiE "$CM_FOOTER_RE"; then echo idle; return; fi
  if printf '%s\n' "$bottom" | tail -n 1 | grep -qE '^[^[:space:]]*[$#%] *$'; then echo shell; return; fi
  echo unreadable
}
wait_idle() { # <orca handle>: 0 idle within --wait-idle-s; 1 not, with IDLE_WHY set
  local end last="not read" st
  end=$(( $(now_s) + WAIT_IDLE_S ))
  while :; do
    st="$(pane_state "$(pane_text orca "$1")")"
    case "$st" in idle) return 0 ;; *) last="$st" ;; esac
    [ "$(now_s)" -lt "$end" ] || break
    sleep "$POLL_S"
  done
  IDLE_WHY="pane still $last after ${WAIT_IDLE_S}s"
  return 1
}

claude_cmd() { # <model> <effort>: the launch line; the model and effort flags are what the banner check then expects
  local c="$CLAUDE --continue"
  case "$1" in [A-Za-z]*) case "$1" in *[!A-Za-z0-9._-]*) ;; *) c="$c --model $1" ;; esac ;; esac
  case "$2" in [a-z]*) case "$2" in *[!a-z]*) ;; *) c="$c --effort $2" ;; esac ;; esac
  printf '%s' "$c"
}
verify_args() { # <model> <effort>: spawn-verify.sh flags in its display form (claude-sonnet-5-5 -> sonnet-5.5)
  if [[ "$1" =~ ^claude-([a-z]+)-([0-9]+)-([0-9]+)$ ]]; then printf -- '--model\n%s-%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"; fi
  if [[ "$2" =~ ^[a-z]+$ ]]; then printf -- '--effort\n%s\n' "$2"; fi
}
verify_pane() { # <orca|plugly> <handle> <model> <effort>: spawn-verify.sh check, exit status passed on
  local -a va=(); local line
  while IFS= read -r line; do [ -z "$line" ] || va+=("$line"); done < <(verify_args "$3" "$4")
  CM_CLI_KIND="$1" "$SPAWN_VERIFY" check --terminal "$2" ${VENV[@]+"${VENV[@]}"} --wait "$VERIFY_S" ${va[@]+"${va[@]}"} 2>&1
}
create_terminal() { # <orca|plugly> <path> <title> <cmd>: prints the handle, status 1 when there is none
  local j h
  if [ "$1" = orca ]; then j="$(o_call terminal create --worktree "path:$2" --title "$3" --command "$4")"
  else j="$(p_call terminal create --worktree "path:$2" --title "$3" --command "$4")"; fi
  h="$(printf '%s' "$j" | jq -r '.result.terminal.handle // .result.handle // .result.startupTerminal.handle // empty' 2>/dev/null)"
  plain_handle "$h" || return 1
  printf '%s\n' "$h"
}
ledger_terminal() { jq -r --arg id "$1" '.workers[$id].terminal // empty' "$LEDGER" 2>/dev/null; }

# ledger_clear_handle <id>: the ledger holds a terminal that is gone: clear it (cm_ledger_write, the lib helper)
# shellcheck disable=SC2016  # a jq program: $id, $now are jq variables bound by --arg
ledger_clear_handle() {
  cm_ledger_write '.workers[$id].terminal = "" | .workers[$id].terminalRefreshedAt = $now | .workers[$id].updatedAt = $now | .updatedAt = $now' \
    --arg id "$1" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1
}
# settle_handle <id> <path>: after a lane ends without a verified terminal, make the recorded handle true: the lane
# reader refreshes it from whatever agent is live; with no agent at all a ledger handle can only point at a dead terminal.
settle_handle() {
  local lr
  "$LANE_HANDLES" --worker "$1" --quiet </dev/null >/dev/null 2>&1 || true
  "$LIVE_AGENT" "$2" --host "$HOST" >/dev/null 2>&1; lr=$?
  if [ "$lr" = 1 ] && [ -n "$(ledger_terminal "$1")" ]; then
    if ledger_clear_handle "$1"; then say "  the ledger handle of $1 pointed at a dead terminal and was cleared"
    else say "  WARNING: the ledger handle of $1 still points at a dead terminal and could not be cleared: clear it by hand or run resume.sh"; fi
  fi
}
# sweep_plugly <path>: close, by exact handle, every plugly terminal on the worktree that was not there when the lane
# started (a create that timed out, or answered in a shape the parser does not know, may still have made one).
# 0 clean, 1 the list or a close could not be confirmed.
sweep_plugly() { # <path> [handle already closed and accepted: not closed again]
  local now="$TMP/plugly-sweep.tsv" h p a bad=0 np
  [ -n "$PL_BEFORE" ] || return 1   # no snapshot: cannot tell new from old, fail closed
  terminals_of plugly "$now" || return 1
  np="$(norm_path "$1")"
  while IFS=$'\t' read -r h p a; do
    [ -n "$h" ] || continue
    [ "$(norm_path "$p")" = "$np" ] || continue
    in_terminals "$PL_BEFORE" "$h" && continue
    [ "$h" != "${2:-}" ] || continue
    plain_handle "$h" || { bad=1; continue; }
    say "  closing the plugly terminal $h that appeared on this worktree during the cutover"
    p_call terminal close --terminal "$h" | jok || bad=1
  done < "$now"
  [ "$bad" = 0 ]
}
# strand <id> <jname> <path> <step> <why>: an agent may still be running without a verified terminal: create nothing
strand() {
  STRANDED=1
  journal "$2" "cutover failed: $4; $5: NOT creating a terminal, check the lane by hand"
  say "  LANE STRANDED: $5; not creating a terminal. Check $1 by hand"
  settle_handle "$1" "$3"
  return 2
}

# only_agent_is <path> <handle>: one live-agent sample; 0 when at least one agent runs and every one carries that handle
only_agent_is() {
  local rows lr
  rows="$("$LIVE_AGENT" "$1" --host "$HOST" 2>/dev/null)"; lr=$?
  [ "$lr" = 0 ] && [ -z "$(printf '%s\n' "$rows" | awk -F'\t' -v h="$2" 'NF && $2 != h')" ]
}
# strand_late <id> <jname> <oh> <step> <why>: the Orca terminal $oh is recreated and verified, but another agent is, or may
# be, running next to it. Point the ledger at $oh, create and send nothing more, and say exactly what to do.
strand_late() {
  STRANDED=1
  cm_worker_set_handle "$1" "$3" >/dev/null 2>&1 || true
  journal "$2" "cutover failed: $4; Orca terminal $3 was recreated and verified, but $5: close the agent that is not on $3 by hand, run lane-handles.sh --worker $1, then nudge the lane (the /loop was NOT re-armed)"
  say "  LANE STRANDED: Orca terminal $3 is verified, but $5. Close the agent that is not on $3 by hand, run lane-handles.sh --worker $1, then nudge the lane: its /loop was NOT re-armed"
  return 2
}

# rollback <id> <jname> <path> <model> <step> <detail> <old terminal state> <new plugly handle or ->
# Old terminal state: 0 never closed (its agent is verified alive), 1 closed and gone, 2 close refused and the agent
# state could not be read, 3 closed but its agent is still running.
# Closes the new Plugly terminal (and any other that appeared on the worktree) by exact handle, waits for every agent
# in the tree to be gone, recreates the Orca terminal, verifies it, refreshes the handle, re-arms the /loop, notes the
# failure. Returns 0 when the lane has a verified terminal again, 1 when it has none, 2 when an agent may still be
# running without a verified terminal (STRANDED: no second agent is started next to it).
rollback() {
  local id="$1" jn="$2" path="$3" model="$4" step="$5" detail="$6" closed="$7" newh="$8" oh="" note vo rc=0 send_h pl alive=0 xe lr clear=0 lt skip_h="" nag
  say "  ROLLBACK $id: failed at $step ($detail)"
  if [ "$newh" != - ]; then
    if p_call terminal close --terminal "$newh" | jok; then say "  closed the new plugly terminal $newh"; skip_h="$newh"
    else
      # not accepted: unless the terminal and its agent are both provably gone, a second agent next to it is worse than none
      pl="$TMP/plugly-rb.tsv"
      if ! terminals_of plugly "$pl" || in_terminals "$pl" "$newh"; then alive=1; fi
      if "$LIVE_AGENT" "$path" --host "$HOST" 2>/dev/null | cut -f2 | grep -qx "$newh"; then alive=1; fi
      if [ "$alive" = 1 ]; then
        strand "$id" "$jn" "$path" "$step" "the new plugly terminal $newh would not close and may still run an agent"; return 2
      fi
      say "  plugly terminal $newh is gone although the close was not accepted"
    fi
  fi
  case "$closed" in
    0)
      note="cutover failed: $step; the Orca terminal was never closed ($(clean_text "$detail"))"
      journal "$jn" "$note"; say "  the Orca terminal is still open; nothing to recreate"; return 0 ;;
    2) strand "$id" "$jn" "$path" "$step" "the close was refused and the agent state could not be read"; return 2 ;;
    3) strand "$id" "$jn" "$path" "$step" "the Orca terminal closed but its agent is still running"; return 2 ;;
  esac
  if ! sweep_plugly "$path" "$skip_h"; then strand "$id" "$jn" "$path" "$step" "a plugly terminal on the worktree could not be listed or closed"; return 2; fi
  # every agent in the tree must be gone before a second one starts, seen twice in a row (a Plugly shell can take a
  # moment to start claude after its terminal exists)
  xe=$(( $(now_s) + EXIT_WAIT_S ))
  while :; do
    "$LIVE_AGENT" "$path" --host "$HOST" >/dev/null 2>&1; lr=$?
    if [ "$lr" = 1 ]; then
      clear=$((clear + 1)); [ "$clear" -ge 2 ] && break
      sleep "$POLL_S"; continue   # the second sample is always taken: the deadline only judges an agent that is still there
    fi
    clear=0
    if [ "$(now_s)" -ge "$xe" ]; then
      strand "$id" "$jn" "$path" "$step" "an agent is still running in the tree (live check exit $lr)"; return 2
    fi
    sleep "$POLL_S"
  done
  if ! sweep_plugly "$path" "$skip_h"; then strand "$id" "$jn" "$path" "$step" "a plugly terminal on the worktree could not be listed or closed"; return 2; fi
  if oh="$(create_terminal orca "$path" resume "$(claude_cmd "$model" "$CUR_EFF")")"; then
    vo="$(verify_pane orca "$oh" "$model" "$CUR_EFF")"; rc=$?
    if [ "$rc" = 0 ]; then
      # a plugly create that finished late (the CLI call was cut off, the runtime was not) may have started a claude by now:
      # look once more, and count the agents in the tree
      if ! sweep_plugly "$path" "$skip_h"; then strand_late "$id" "$jn" "$oh" "$step" "a late plugly terminal on the worktree could not be listed or closed"; return 2; fi
      # exactly the recreated terminal's agent, seen twice in a row (a closed late claude can take seconds to exit); no agent at
      # all, a live check that cannot answer, or an agent with no readable handle, is not "clear"
      xe=$(( $(now_s) + EXIT_WAIT_S )); clear=0
      while :; do
        nag="$("$LIVE_AGENT" "$path" --host "$HOST" 2>/dev/null)"; lr=$?
        if [ "$lr" = 0 ] && [ -z "$(printf '%s\n' "$nag" | awk -F'\t' -v h="$oh" 'NF && $2 != h')" ]; then
          clear=$((clear + 1)); [ "$clear" -ge 2 ] && break
          sleep "$POLL_S"; continue
        fi
        clear=0
        if [ "$(now_s)" -ge "$xe" ]; then
          if [ "$lr" = 1 ]; then   # nothing runs at all: the recreated claude is gone
            journal "$jn" "cutover failed: $step; the recreated Orca terminal $oh has no agent running: lane lacks a working agent, needs resume.sh"
            say "  LANE DOWN: the recreated Orca terminal $oh passed its banner check but no agent is running in the tree"
            settle_handle "$id" "$path"; return 1
          fi
          strand_late "$id" "$jn" "$oh" "$step" "another agent is still running in the tree (live check exit $lr)"; return 2
        fi
        sleep "$POLL_S"
      done
      "$LANE_HANDLES" --worker "$id" --quiet </dev/null >/dev/null 2>&1 || true
      cm_worker_set_handle "$id" "$oh" >/dev/null 2>&1 || true
      lt="$(ledger_terminal "$id")"
      if [ "$lt" = "$oh" ]; then
        note="cutover failed: $step; rolled back to Orca terminal $oh ($(clean_text "$detail"))"
        journal "$jn" "$note"; say "  recreated and verified the Orca terminal $oh"
      else
        note="cutover failed: $step; Orca terminal $oh recreated and verified, but the ledger handle was NOT restored (it holds \"${lt:-none}\"): run lane-handles.sh --worker $id"
        journal "$jn" "$note"; say "  recreated and verified the Orca terminal $oh; WARNING: the ledger handle was NOT restored (it holds \"${lt:-none}\"): run lane-handles.sh --worker $id"
      fi
      # the old terminal took the lane's /loop with it: re-arm it here too, through the lane reader
      if send_h="$(cm_lane_handle "$id" 2>/dev/null)" && [ "$send_h" = "$oh" ] && o_call terminal send --terminal "$send_h" --text "$NUDGE" --enter | jok; then
        say "  /loop re-arm nudge sent to $oh"
      else
        journal "$jn" "cutover rollback: the /loop re-arm nudge was NOT sent to $oh; nudge this lane by hand"
        say "  WARNING: the /loop re-arm nudge was not sent to $oh: the lane has a terminal but no /loop; nudge it by hand"
      fi
      return 0
    fi
    note="cutover failed: $step; ROLLBACK terminal $oh did not verify ($(clean_text "$vo")): lane needs resume.sh"
    journal "$jn" "$note"; say "  LANE DOWN: recreated Orca terminal $oh did not verify ($vo); left open"; settle_handle "$id" "$path"; return 1
  fi
  note="cutover failed: $step; ROLLBACK could not create an Orca terminal: lane has none, needs resume.sh"
  journal "$jn" "$note"; say "  LANE DOWN: could not recreate an Orca terminal for $id"; settle_handle "$id" "$path"; return 1
}

# The turn check: a "user" line carrying the nudge text, stamped at or after the send, in a transcript written since the
# send. Old nudges in the history (a resumed or copied session file) carry older stamps and do not count; a startup write
# does not carry the text. A transcript without timestamps never confirms (the lane is rolled back, the safe side).
iso_utc() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%S; }
nudge_landed() { # <path> <send time, epoch seconds>
  local d f m t0i
  d="${CM_CLAUDE_PROJECTS:-$HOME/.claude/projects}/$(printf '%s' "$1" | sed 's#[^A-Za-z0-9]#-#g')"
  t0i="$(iso_utc "$2")"
  for f in "$d"/*.jsonl; do
    [ -e "$f" ] || continue
    m="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)"
    [ "$m" -ge $(( $2 - 1 )) ] || continue
    jq -R -e --arg t "$t0i" --arg frag "$NUDGE_FRAG" 'fromjson? | select(.type == "user") | select(((.timestamp // "")[0:19]) >= $t) | select(tostring | contains($frag))' "$f" >/dev/null 2>&1 && return 0
  done
  return 1
}

# judge_old_terminal <handle> <path>: the close was not accepted (refused, or timed out). Orca may still carry it out, so
# look at the terminal list AND the live agent until they settle (at most EXIT_WAIT_S), then say what is true:
# 0 still open with its agent, 1 gone with its agent, 2 cannot tell, 3 terminal gone but its agent still runs.
judge_old_terminal() {
  local end listed lr v
  end=$(( $(now_s) + EXIT_WAIT_S ))
  while :; do
    if terminals_of orca "$TMP/orca-judge.tsv"; then listed=0; in_terminals "$TMP/orca-judge.tsv" "$1" && listed=1; else listed=x; fi
    "$LIVE_AGENT" "$2" --host "$HOST" >/dev/null 2>&1; lr=$?
    if [ "$listed" = x ] || [ "$lr" -ge 2 ]; then v=2
    elif [ "$listed" = 0 ] && [ "$lr" = 1 ]; then echo 1; return
    elif [ "$listed" = 0 ]; then v=3
    elif [ "$lr" = 0 ]; then v=0
    else v=2; fi
    [ "$(now_s)" -lt "$end" ] || { echo "$v"; return; }
    sleep "$POLL_S"
  done
}

# cut_lane <id> <lane> <path> <model> <standing> <plan handle> <effort>: 0 done, 1 failed (rolled back; STOP), 3 failed and rolled back badly (LANE DOWN),
# 4 skipped (nothing was touched; go on)
cut_lane() {
  local id="$1" lane="$2" path="$3" model="$4" standing="$5" plan_h="$6" eff="$7" lm2 jl jn h2 h3 closed=0 newh="" nh2 t0 ok=0 j send_h IDLE_WHY="" vo cmd larc exit_end
  say "lane $id ($path)"
  CUR_EFF="$eff"; PL_BEFORE=""
  # re-resolve the handle from the live agent: the plan is minutes old, and a ledger handle is never a fallback
  "$LANE_HANDLES" --worker "$id" --quiet </dev/null >/dev/null 2>&1 || true
  if ! h2="$("$LANE_HANDLES" --get "$id" 2>/dev/null)" || [ -z "$h2" ]; then say "  skip: no verified live handle for $id now"; return 4; fi
  if [ "$h2" != "$plan_h" ]; then say "  skip: live handle is $h2, the plan had $plan_h: re-run"; return 4; fi
  if is_self "$h2"; then say "  skip: self"; return 4; fi
  # a. idle
  if ! wait_idle "$h2"; then say "  skip: busy ($IDLE_WHY): not closed; re-run later"; return 4; fi
  # the idle wait can take minutes: resolve the live handle again, and require the terminal list to carry that handle on THIS
  # worktree as a claude terminal (a handle inherited from another tree would otherwise close someone else's terminal)
  "$LANE_HANDLES" --worker "$id" --quiet </dev/null >/dev/null 2>&1 || true
  if ! h3="$("$LANE_HANDLES" --get "$id" 2>/dev/null)" || [ "$h3" != "$h2" ]; then say "  skip: the live handle changed during the idle wait (${h3:-none}, was $h2): not closed; re-run"; return 4; fi
  if ! terminals_of orca "$TMP/orca-now.tsv" || ! listed_on "$TMP/orca-now.tsv" "$h2" "$path"; then
    say "  skip: orca does not list $h2 on this worktree as a claude terminal: not closed"; return 4
  fi
  # the live model and effort again (a /model switch can happen between the plan and now): the relaunch uses exactly what the plan read
  if ! lm2="$(live_model "$h2")" || [ "$lm2" != "$model $eff" ]; then
    say "  skip: the live model of $h2 changed or cannot be read now (plan: $model $eff, now: $lm2): not closed; re-run"; return 4
  fi
  # the plugly terminals as they are now: whatever appears on this worktree later is this cutover's to close
  if ! terminals_of plugly "$TMP/plugly-before.tsv"; then say "  skip: cannot read the plugly terminals before the close: nothing touched"; return 4; fi
  PL_BEFORE="$TMP/plugly-before.tsv"
  # b. handover note
  jl="$id"; [ "$standing" != true ] || jl="$lane"
  if ! jn="$(journal_name "$jl")" || [ -z "$jn" ]; then say "  skip: no journal name for \"$jl\": nothing touched"; return 4; fi
  CUR_ID="$id"; CUR_JN="$jn"
  if ! "$LANE_JOURNAL" append "$jn" "cm:handover cutover to plugly $(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1; then
    say "  skip: could not write the handover note to the lane journal: nothing touched"; return 4
  fi
  # the lane may have woken up since the idle check: look once more right before the close
  if [ "$(pane_state "$(pane_text orca "$h2")")" != idle ]; then
    journal "$jn" "cutover postponed: the lane was busy again at the close, nothing was closed"
    say "  skip: busy again just before the close: not closed; re-run later"; return 4
  fi
  # c. close the Orca terminal by its exact handle
  say "  closing orca terminal $h2"
  CUR_STAGE=close
  if ! o_call terminal close --terminal "$h2" | jok; then
    # not accepted: Orca may still have closed it (a timed-out call), so judge from the list and the live agent, not the answer
    closed="$(judge_old_terminal "$h2" "$path")"
    rollback "$id" "$jn" "$path" "$model" close "terminal close was not accepted" "$closed" - && return 1 || return 3
  fi
  closed=1
  # the old agent must be gone before a second one starts in the tree
  exit_end=$(( $(now_s) + EXIT_WAIT_S ))
  while :; do
    "$LIVE_AGENT" "$path" --host "$HOST" >/dev/null 2>&1; larc=$?
    [ "$larc" = 1 ] && break
    if [ "$(now_s)" -ge "$exit_end" ]; then
      rollback "$id" "$jn" "$path" "$model" close "the old agent was still running after the close was accepted" 3 - && return 1 || return 3
    fi
    sleep "$POLL_S"
  done
  CUR_STAGE=create
  # d. create the plugly terminal in the same worktree path
  cmd="$(claude_cmd "$model" "$eff")"
  say "  creating plugly terminal: $cmd"
  if ! newh="$(create_terminal plugly "$path" cutover "$cmd")"; then
    # the call may have been cut off while the runtime goes on creating: give it time to land, so the sweep sees it
    [ "$CREATE_GRACE_S" -le 0 ] || { say "  plugly create gave no usable answer: waiting ${CREATE_GRACE_S}s for a late terminal"; sleep "$CREATE_GRACE_S"; }
    rollback "$id" "$jn" "$path" "$model" create "plugly terminal create returned no usable handle" 1 - && return 1 || return 3
  fi
  say "  new plugly terminal $newh"
  CUR_STAGE=verify
  # e. the banner
  if ! vo="$(verify_pane plugly "$newh" "$model" "$eff")"; then
    rollback "$id" "$jn" "$path" "$model" verify "$vo" 1 "$newh" && return 1 || return 3
  fi
  say "  $vo"
  CUR_STAGE=handle
  # f. rewrite the handle through the helpers, then prove both places agree
  "$LANE_HANDLES" --worker "$id" --quiet </dev/null >/dev/null 2>&1 || true
  nh2="$("$LANE_HANDLES" --get "$id" 2>/dev/null)" || nh2=""
  if [ "$nh2" != "$newh" ]; then
    rollback "$id" "$jn" "$path" "$model" handle "lane-handles.sh gives \"${nh2:-nothing}\", the new terminal is $newh" 1 "$newh" && return 1 || return 3
  fi
  cm_worker_set_handle "$id" "$newh" >/dev/null 2>&1 || true
  if [ "$(ledger_terminal "$id")" != "$newh" ]; then
    rollback "$id" "$jn" "$path" "$model" handle "ledger terminal is \"$(ledger_terminal "$id")\", not $newh" 1 "$newh" && return 1 || return 3
  fi
  # g. re-arm the /loop and wait for a turn
  CUR_STAGE=nudge
  if [ "$(pane_state "$(pane_text plugly "$newh")")" = menu ]; then
    rollback "$id" "$jn" "$path" "$model" nudge "a question menu is showing in the new terminal" 1 "$newh" && return 1 || return 3
  fi
  # the nudge goes to the handle the lane reader gives (lib.sh cm_lane_handle), and only if it is the terminal just verified
  if ! send_h="$(cm_lane_handle "$id" 2>/dev/null)" || [ "$send_h" != "$newh" ]; then
    rollback "$id" "$jn" "$path" "$model" nudge "lane handle \"${send_h:-none}\" is not the new terminal $newh" 1 "$newh" && return 1 || return 3
  fi
  t0="$(now_s)"
  j="$(p_call terminal send --terminal "$send_h" --text "$NUDGE" --enter)"
  if ! printf '%s' "$j" | jok; then
    rollback "$id" "$jn" "$path" "$model" nudge "plugly did not accept the nudge" 1 "$newh" && return 1 || return 3
  fi
  while :; do
    if nudge_landed "$path" "$t0"; then ok=1; break; fi
    [ "$(( $(now_s) - t0 ))" -lt "$CONFIRM_S" ] || break
    sleep "$POLL_S"
  done
  if [ "$ok" != 1 ]; then
    rollback "$id" "$jn" "$path" "$model" nudge "input accepted but the nudge never landed in the transcript within ${CONFIRM_S}s" 1 "$newh" && return 1 || return 3
  fi
  say "  nudged, turn started: $id is on plugly terminal $newh"
  return 0
}

STOP=0; RC=0; FAILED_PATH=""; FAILED_ID=""
while IFS="$US" read -r rank id lane path term model standing state lh la act why sel plat eff; do
  [ "$act" = cutover ] || continue
  if [ "$STOP" = 1 ]; then UNTOUCHED+=("$id"); continue; fi
  [ "$model" != - ] || model=""
  cut_lane "$id" "$lane" "$path" "$model" "$standing" "$lh" "$eff"; rc=$?
  CUR_STAGE=""; CUR_ID=""; CUR_JN=""
  case "$rc" in
    0) DONE+=("$id") ;;
    4) SKIPPED+=("$id") ;;
    1) FAILED="$id"; FAILED_PATH="$path"; FAILED_ID="$id"; STOP=1; RC=1 ;;
    *) FAILED="$id ($([ "$STRANDED" = 1 ] && echo STRANDED || echo LANE DOWN))"; STOP=1; RC=3 ;;
  esac
done < "$TMP/plan.us"

report() {
  say ""
  say "cutover-host: done:      ${DONE[*]:-none}"
  say "cutover-host: failed:    ${FAILED:-none}"
  say "cutover-host: skipped:   ${SKIPPED[*]:-none}$([ "${#SKIPPED[@]}" -gt 0 ] && echo ' (busy or changed: re-run later)')"
  say "cutover-host: untouched: ${UNTOUCHED[*]:-none}"
  say "cutover-host: not moved: ${NOT_MOVED[*]:-none}$([ "${#NOT_MOVED[@]}" -gt 0 ] && echo ' (selected lanes this script does not move: see the plan)')"
}
if [ "$STOP" = 1 ]; then
  # a plugly create can still land after a lane was rolled back: one last look, and close what is new on its worktree
  if [ "$RC" = 1 ] && [ -n "${FAILED_PATH:-}" ]; then
    if ! sweep_plugly "$FAILED_PATH"; then
      say "cutover-host: WARNING: a plugly terminal on $FAILED_PATH could not be listed or closed at the end: check that lane's terminals by hand"
    else
      # what the sweep closed may still be exiting: only the lane's own agent may be left, seen twice in a row
      fh="$(ledger_terminal "$FAILED_ID")"; fx=$(( $(now_s) + EXIT_WAIT_S )); fc=0
      while :; do
        if only_agent_is "$FAILED_PATH" "$fh"; then fc=$((fc + 1)); [ "$fc" -ge 2 ] && break; sleep "$POLL_S"; continue; fi
        fc=0
        if [ "$(now_s)" -ge "$fx" ]; then
          say "cutover-host: WARNING: more than the lane's own agent (or none) is running in $FAILED_PATH at the end: check $FAILED_ID by hand before anything else"; break
        fi
        sleep "$POLL_S"
      done
    fi
  fi
  report
  if [ "$RC" = 3 ] && [ "$STRANDED" = 1 ]; then say "cutover-host: a lane is STRANDED: an agent may still be running without a verified terminal (or a plugly terminal would not close): check that lane by hand before anything else"
  elif [ "$RC" = 3 ]; then say "cutover-host: a lane has no working, verified terminal: check it, and run scripts/resume.sh for it if it has none"; fi
  exit "$RC"
fi

# ---- 4. the orphan check, under the plugly CLI ------------------------------------------------------------------
if [ "$SKIP_CENSUS" = 1 ]; then
  say "cutover-host: orphan check skipped (--skip-census)"
else
  : > "$TMP/orphans.txt"
  if ! terminals_of plugly "$TMP/plugly-after.tsv" || ! terminals_of orca "$TMP/orca-after.tsv"; then
    say "cutover-host: orphan check could not read the terminal lists: treated as orphans"
    echo "terminal lists unreadable on host $HOST" >> "$TMP/orphans.txt"
  else
    LEDGER="$(cm_ledger_path)"
    # the lanes this run owns: cut over now, or selected and already on plugly
    while IFS="$US" read -r rank id lane path term model standing state lh la act why sel plat eff; do
      own=0
      for d in ${DONE[@]+"${DONE[@]}"}; do [ "$d" = "$id" ] && own=1; done
      [ "$act" = onplugly ] && own=1
      [ "$own" = 1 ] || continue
      lt="$(ledger_terminal "$id")"
      lo="$("$LIVE_AGENT" "$path" --host "$HOST" 2>/dev/null | cut -f2 | grep -v '^$' | sort -u | tr '\n' ' ')"; lo="${lo% }"
      if [ "$lo" != "$lt" ]; then echo "$id: live agent terminal \"${lo:-none}\" does not match the ledger handle \"${lt:-none}\"" >> "$TMP/orphans.txt"; fi
      if [ -z "$lt" ] || ! in_terminals "$TMP/plugly-after.tsv" "$lt"; then echo "$id: ledger handle \"${lt:-none}\" is not a live terminal in plugly" >> "$TMP/orphans.txt"; fi
      np="$(norm_path "$path")"
      while IFS=$'\t' read -r oh op oa; do
        [ -n "$oh" ] || continue
        # agent terminals only: a plain shell tab a lane keeps on its worktree is not an orphan
        [ -n "$oa" ] && [ "$(norm_path "$op")" = "$np" ] && echo "$id: Orca terminal $oh ($oa) is still open on the cut-over worktree" >> "$TMP/orphans.txt"
      done < "$TMP/orca-after.tsv"
    done < "$TMP/plan.us"
  fi
  if [ -s "$TMP/orphans.txt" ]; then
    say ""
    say "cutover-host: ORPHANS: $(grep -c . "$TMP/orphans.txt") (target 0)"
    sed 's/^/  /' "$TMP/orphans.txt"
    report
    say "cutover-host: refusing to finish with orphans"
    exit 1
  fi
  say "cutover-host: orphan check clean (0 orphans)"
fi
report
if [ "${#SKIPPED[@]}" -gt 0 ] || [ "${#NOT_MOVED[@]}" -gt 0 ]; then exit 4; fi
exit 0
