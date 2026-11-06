#!/usr/bin/env bash
# cutover-hold.sh: keep resume.sh standing down while a cutover runs on ANOTHER machine.
#
#   scripts/cutover-hold.sh start [--hours N]    # take the hold (default 4 hours, at most 24)
#   scripts/cutover-hold.sh release              # drop it
#   scripts/cutover-hold.sh status               # held / not held, with the holder's pid
#
# cutover-host.sh takes $CM_HOME/cutover-host.lock on the machine it runs on, and resume.sh stands down (exit 4) while
# that lock names a live process whose command line holds "cutover-host". A remote `cutover-host.sh local --apply` locks
# the REMOTE shell's CM_HOME, which the concertmaster host's resume.sh never reads, so a tick could start a second agent
# in a lane between its closed Orca terminal and its new Plugly agent. This script takes the same lock in THIS CM_HOME,
# with a stand-in process named cutover-host-hold. The stand-in runs in its own session (setsid, so a hangup or a process-group
# kill of the calling shell does not end it) and ignores SIGHUP. start waits for the stand-in to be running (a few seconds, at most
# about 10 on a loaded host); status checks it any time.
# It expires with the stand-in (--hours, default 4, at most 24; a host with many lanes can need hours): after that resume.sh runs
# again, so release it as soon as the remote run is done, and always on failure. Run it on the concertmaster host.
#
# start and release run one at a time: each holds an exclusive flock(1) on $CM_HOME/cutover-hold.claim.lock for its whole critical
# section, waited for up to CM_HOLD_CLAIM_WAIT_S seconds (default 20, at most 9999). The kernel drops that lock when the process
# ends, however it ends, so there is nothing stale to reap. Several starts at once leave exactly one holder; the others see its live
# hold and exit 1. flock(1) is required (Linux util-linux; the cutover kit is Linux-only already: live-agent.sh needs /proc). Without
# it start and release fail closed (exit 1) rather than run unserialized.
#
# While held, resume.sh stands down for EVERY host and cutover-host.sh on this machine fails its no-cutover-lock
# pre-check: dry-run before the hold or after the release.
# Exit codes:
#   0    done (status: held)
#   1    start: a hold exists already, resume.sh is running (retry when it ends), the claim is busy, flock is missing, or the stand-in
#        did not start. release: no hold of ours, or a lock left in place. status: not held or expired
#   2    usage
#   130  interrupted (INT, TERM or HUP, whenever it arrives; the shell's own 128+n for the signal is replaced by this one code).
#        start: nothing is held, nothing is left behind. release: it may be half done, run release again, then status.
#        A signal that arrives after the hold is recorded is ignored and the start ends `held` (0): after ANY interrupt run status.
#        A retry loop should stop on 130, not retry.
# An expired hold of ours is cleaned up by the next start or release.
# A lock that is NOT provably ours is never removed by this script: a pidless lock (a start killed -9 between mkdir and the pid
# write), or a lock naming a live unrelated pid (a real cutover, or a reused pid). Look at `ps` and $CM_HOME/cutover-host.lock/pid,
# and when nothing is running, remove the lock by hand: rm -f $CM_HOME/cutover-host.lock/pid; rmdir $CM_HOME/cutover-host.lock.
# Harmless leftovers: $CM_HOME/cutover-hold.claim.lock (the flock file, empty) and $CM_HOME/cutover-hold.pid.new.* (a killed start's).
# Env: CM_HOME, CM_HOLD_CLAIM_WAIT_S (whole seconds, 0 to 9999; start and release only).
set -uo pipefail
trap 'exit 130' INT TERM HUP    # before anything slow (sourcing lib.sh takes a moment under load): every interrupt exits 130
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

LOCK="$CM_HOME/cutover-host.lock"
PIDF="$CM_HOME/cutover-hold.pid"
CLAIMFILE="$CM_HOME/cutover-hold.claim.lock"
NAME=cutover-host-hold

usage() { awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0" >&2; exit 2; }

# holder_alive <pid>: a live process whose command line is our stand-in (a reused pid is not)
holder_alive() {
  [ -n "${1:-}" ] || return 1
  ps -p "$1" -o args= 2>/dev/null | grep -qE "^$NAME( |\$)"
}
# pid_exists <pid>: ps sees it, whoever owns it (kill -0 fails with EPERM for another user's process, which would read as gone)
# A zombie (killed or expired, not yet reaped) counts as gone.
pid_exists() {
  local state
  [ -n "${1:-}" ] || return 1
  state="$(ps -p "$1" -o stat= 2>/dev/null | tr -d ' ')"
  [ -n "$state" ] || return 1     # ps does not know the pid
  case "$state" in Z*) return 1 ;; esac
  return 0
}
# our_child <pid>: the stand-in, or the bash -c that is about to become it (its command line names our pid file)
our_child() { ps -p "${1:-0}" -o args= 2>/dev/null | grep -qE "^$NAME( |\$)|cutover-hold\.pid\.new"; }

# ours_lock <recorded pid>: the lock is ours: a recorded pid, equal to the lock's pid, and either our live stand-in or a pid that
# is gone altogether. A pid that is alive but is NOT the stand-in is a reused pid (a real cutover may hold the lock): not ours.
ours_lock() {
  [ -n "${1:-}" ] && [ "$(cat "$LOCK/pid" 2>/dev/null || true)" = "$1" ] || return 1
  holder_alive "$1" || ! pid_exists "$1"
}

# mkdir_immune <dir>: mkdir in a child that ignores INT, TERM and HUP (an ignored signal survives exec), so a signal delivered to the
# whole foreground group cannot kill mkdir after it made the directory but before this script has noted it
mkdir_immune() { ( trap '' INT TERM HUP; exec mkdir "$1" ) 2>/dev/null; }

# The claim: an exclusive flock on a descriptor of its own ($CLAIMFD), held for the whole critical section of start and release. With it held, nothing else in
# this script touches the lock or the hold file, so an expired hold is reclaimed in place and a racing start cannot displace another's
# lock. The stand-in is started with that descriptor closed, so it does not keep the claim for hours. (cutover-host.sh takes the lock
# with a plain mkdir, which stays atomic against ours.)
CLAIMED=0; PENDING=0; FLPID=""; CLAIMFD=""
# A signal that arrives while the lock is being made is DEFERRED, not dropped: the handler notes it and the code acts on it the
# moment the window closes (a cancelled start must not go on to take a 4 to 24 hour hold).
note_signal() { PENDING=1; }
check_wait_setting() {
  case "${CM_HOLD_CLAIM_WAIT_S:-20}" in
    [0-9]|[0-9][0-9]|[0-9][0-9][0-9]|[0-9][0-9][0-9][0-9]) ;;
    *) cm_warn "cutover-hold.sh: CM_HOLD_CLAIM_WAIT_S must be whole seconds, 0 to 9999"; exit 2 ;;
  esac
}
take_claim() {
  local wait_s="${CM_HOLD_CLAIM_WAIT_S:-20}"
  command -v flock >/dev/null 2>&1 || { cm_warn "cutover-hold.sh: flock(1) is not installed, so start and release cannot be serialized: failing closed (util-linux flock is required)"; exit 1; }
  [ -d "$CM_HOME" ] && [ -w "$CM_HOME" ] || { cm_warn "cutover-hold.sh: cannot write to $CM_HOME: no claim can be made"; exit 1; }   # the real cause
  exec {CLAIMFD}>"$CLAIMFILE" || { cm_warn "cutover-hold.sh: cannot open $CLAIMFILE"; exit 1; }   # bash picks a free descriptor: a caller's own descriptors (fd 9 included) are never touched
  # flock runs in the background and is waited for, so a signal ends the wait at once instead of after the whole timeout; the lock
  # belongs to the open file description on $CLAIMFD, so it is ours once the helper has it
  flock -w "$((10#$wait_s))" "$CLAIMFD" & FLPID=$!
  if wait "$FLPID"; then CLAIMED=1; FLPID=""; return 0; fi
  FLPID=""
  exec {CLAIMFD}>&-
  return 1
}
# the claim is released by closing $CLAIMFD (or by the process ending); a helper still waiting is stopped
drop_claim() {
  [ -z "$FLPID" ] || kill "$FLPID" 2>/dev/null
  if [ "$CLAIMED" = 1 ]; then CLAIMED=0; exec {CLAIMFD}>&-; fi
}
trap drop_claim EXIT

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  start)
    arm_cleanup() { trap 'cleanup_start; exit 130' INT TERM HUP; }
    hours=4
    while [ $# -gt 0 ]; do
      case "$1" in
        --hours) [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]{1,2}$ ]] || usage; hours=$((10#$2)); shift 2 ;;
        *) usage ;;
      esac
    done
    if [ "$hours" -lt 1 ] || [ "$hours" -gt 24 ]; then cm_warn "cutover-hold.sh: --hours takes 1 to 24"; exit 2; fi
    check_wait_setting
    mkdir -p "$CM_HOME"
    # resume.sh is running now: a create it has started could still land after "held". Refuse; the caller waits and starts again.
    if cm_resume_lock_held; then
      cm_warn "cutover-hold.sh: resume.sh is running ($CM_HOME/resume.lock): an agent create it started could still finish after the hold. Wait for it to end, then start again"
      exit 1
    fi
    pidtmp="$CM_HOME/cutover-hold.pid.new.$$"; spawn=""; pid=""; HAVE_LOCK=0
    cleanup_start() {   # a start that fails or is interrupted leaves nothing: no stand-in, and no lock if we made it
      [ "$CLAIMED" = 1 ] || return 0      # only the start that holds the claim owns the pid file, the lock and the stand-in
      [ -z "$spawn" ] || ! our_child "$spawn" || kill "$spawn" 2>/dev/null
      late="$(cat "$pidtmp" 2>/dev/null || true)"   # the pid our own child wrote, exec'd into the stand-in or not yet
      [ -z "$late" ] || ! our_child "$late" || kill "$late" 2>/dev/null
      [ -z "$pid" ] || ! our_child "$pid" || kill "$pid" 2>/dev/null
      rm -f "${pidtmp:?}"
      if [ "$HAVE_LOCK" = 1 ]; then
        if [ -n "$pid" ] && [ "$(cat "$LOCK/pid" 2>/dev/null || true)" = "$pid" ]; then rm -f "${LOCK:?}/pid"; fi
        if [ -n "$pid" ] && [ "$(cat "$PIDF" 2>/dev/null || true)" = "$pid" ]; then rm -f "${PIDF:?}"; fi
        rmdir "${LOCK:?}" 2>/dev/null
      fi
    }
    arm_cleanup
    if ! take_claim; then
      cm_warn "cutover-hold.sh: another start or release holds the claim (waited ${CM_HOLD_CLAIM_WAIT_S:-20} s): run it again"
      exit 1
    fi
    arm_cleanup    # from here a signal also cleans up what this start made
    PENDING=0; trap note_signal INT TERM HUP    # deferred from the first mkdir of the lock until HAVE_LOCK says so, whichever branch makes it
    if mkdir_immune "$LOCK"; then
      HAVE_LOCK=1
      arm_cleanup
    else
      # An EXPIRED hold of ours (the recorded stand-in is gone and the lock still names it) is reclaimed in place; the claim makes
      # that safe. Any other lock (a cutover, a hold we did not record, a reused pid, another start) is never touched.
      judged="$(cat "$LOCK/pid" 2>/dev/null || true)"; oldpid="$(cat "$PIDF" 2>/dev/null || true)"
      if [ -n "$judged" ] && [ "$judged" = "$oldpid" ] && ours_lock "$judged" && ! holder_alive "$judged"; then
        echo "the earlier hold expired (its stand-in is gone): cleaning it up"
        rm -f "${LOCK:?}/pid" "${PIDF:?}"; rmdir "${LOCK:?}" 2>/dev/null
        if mkdir_immune "$LOCK"; then
          HAVE_LOCK=1
          arm_cleanup
        else
          arm_cleanup
          [ "$PENDING" = 0 ] || exit 130
          cm_warn "cutover-hold.sh: $LOCK was taken again at once (a cutover?); nothing is held"; exit 1
        fi
      else
        arm_cleanup
        [ "$PENDING" = 0 ] || exit 130
        [ -d "$LOCK" ] || { cm_warn "cutover-hold.sh: cannot create $LOCK (disk full or $CM_HOME not writable?)"; exit 1; }   # the real cause, not "exists already"
        cm_warn "cutover-hold.sh: $LOCK exists already (pid $(cat "$LOCK/pid" 2>/dev/null || echo none)): a cutover, an earlier hold or a start that was killed. Check it, run 'cutover-hold.sh release' if it is ours, and start again"
        exit 1
      fi
    fi
    arm_cleanup
    if [ "$PENDING" = 1 ]; then cm_warn "cutover-hold.sh: interrupted while the lock was being made; nothing is held"; cleanup_start; exit 130; fi
    # With the lock made, look at resume.sh once more: one that started while this start waited for the claim (or between the first
    # check and the lock) has not seen the lock, and an agent create it started could still land. The lock is undone if it runs.
    if cm_resume_lock_held; then
      cm_warn "cutover-hold.sh: resume.sh started while this start waited; nothing is held. Wait for it to end, then start again"
      cleanup_start; exit 1
    fi
    # ONE spawn path: a bash that ignores SIGHUP, writes its own pid and becomes the stand-in (exec keeps the pid and the ignored
    # signal); in its own session when setsid exists; started with the claim descriptor closed. The pid file is per start, next to the hold file.
    rm -f "${pidtmp:?}"
    if command -v setsid >/dev/null 2>&1; then
      setsid bash -c 'trap "" HUP; printf "%s\n" "$$" > "$1" || exit 1; exec -a "$2" sleep "$3"' _ "$pidtmp" "$NAME" $((hours * 3600)) </dev/null >/dev/null 2>&1 {CLAIMFD}>&- &
    else
      bash -c 'trap "" HUP; printf "%s\n" "$$" > "$1" || exit 1; exec -a "$2" sleep "$3"' _ "$pidtmp" "$NAME" $((hours * 3600)) </dev/null >/dev/null 2>&1 {CLAIMFD}>&- &
    fi
    spawn=$!
    for _ in $(seq 1 25); do [ -s "$pidtmp" ] && break; sleep 0.2; done
    pid="$(cat "$pidtmp" 2>/dev/null || true)"
    if [ -n "$pid" ]; then for _ in $(seq 1 25); do holder_alive "$pid" && break; sleep 0.2; done; fi   # the exec that names the process can lag under load
    if ! holder_alive "$pid"; then
      cm_warn "cutover-hold.sh: the stand-in process did not start (ps does not show $NAME for pid ${pid:-none}); nothing is held"
      cleanup_start
      exit 1
    fi
    rm -f "${pidtmp:?}"
    printf '%s\n' "$pid" > "$LOCK/pid" && printf '%s\n' "$pid" > "$PIDF" || { cm_warn "cutover-hold.sh: cannot write the hold files; nothing is held"; cleanup_start; exit 1; }
    trap '' INT TERM HUP    # the hold is taken and recorded: a signal now must not turn a held start into a failed one
    echo "held: resume.sh stands down until 'cutover-hold.sh release' (stand-in pid $pid, expires in ${hours}h)"
    ;;
  release)
    check_wait_setting
    mkdir -p "$CM_HOME"
    if ! take_claim; then cm_warn "cutover-hold.sh: another start or release holds the claim (waited ${CM_HOLD_CLAIM_WAIT_S:-20} s): run it again"; exit 1; fi
    if [ ! -e "$PIDF" ]; then cm_warn "cutover-hold.sh: no hold of ours ($PIDF is missing); a lock without it is a cutover or another hold, not released"; exit 1; fi
    pid="$(cat "$PIDF" 2>/dev/null)"
    lockpid="$(cat "$LOCK/pid" 2>/dev/null || true)"
    ours=0; ours_lock "$pid" && ours=1
    if holder_alive "$pid"; then kill "$pid" 2>/dev/null; fi   # only our stand-in, never a reused pid
    # the lock is ours only while its pid is the one we recorded: a real cutover that holds it (the hold never started) is left alone
    if [ -d "$LOCK" ] && [ "$ours" = 1 ]; then
      rm -f "${LOCK:?}/pid"
      rmdir "${LOCK:?}" 2>/dev/null || cm_warn "cutover-hold.sh: $LOCK still holds other files; left in place"
    elif [ -d "$LOCK" ]; then
      cm_warn "cutover-hold.sh: $LOCK names pid ${lockpid:-none}, not our stand-in $pid: the lock is not ours and was left in place"
    fi
    if [ -d "$LOCK" ]; then cm_warn "cutover-hold.sh: NOT released: $LOCK is still in place (see the warning above; check ps and the header of this script before removing it by hand)"; exit 1; fi
    rm -f "${PIDF:?}"
    echo "released"
    ;;
  status)
    pid="$(cat "$PIDF" 2>/dev/null || true)"
    lockpid="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [ -d "$LOCK" ] && holder_alive "$pid" && [ "$lockpid" = "$pid" ]; then echo "held (stand-in pid $pid)"; exit 0; fi
    if [ -d "$LOCK" ] && ours_lock "$pid"; then echo "EXPIRED: the stand-in is gone but the lock is still ours ($LOCK): resume.sh is NOT held; 'release' cleans it up, 'start' takes a new hold"; exit 1; fi
    if [ -d "$LOCK" ]; then echo "NOT held by us: $LOCK names pid ${lockpid:-none}, our recorded stand-in is ${pid:-none}"; exit 1; fi
    echo "not held"; exit 1
    ;;
  -h|--help|help|'') usage ;;
  *) cm_warn "cutover-hold.sh: unknown command: $cmd"; usage ;;
esac
