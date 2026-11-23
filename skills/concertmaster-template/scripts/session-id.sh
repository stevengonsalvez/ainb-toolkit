#!/usr/bin/env bash
# session-id.sh: the ONE full Claude session id of a lane's worktree, or the reason there is none. Never a guess.
#
#   scripts/session-id.sh <worktree-path> [--host <h>] [--pids "<pid> <pid> ..."] [--live-only]
#
# cutover-host.sh relaunches a lane with `claude --dangerously-skip-permissions --resume <id>`, so the id must be the
# lane's own session. Sources, in this order of trust:
#   live    the `--resume <id>` (or `--resume=<id>`, `-r <id>`, `--session-id <id>`: a lane pinned at spawn) argument of the live agent processes in --pids (the pids
#           live-agent.sh printed for the worktree), read from <proc>/<pid>/cmdline on the host that runs them
#   file    the newest transcript of the worktree: ~/.claude/projects/<path with every non-alphanumeric as "-">/*.jsonl,
#           basename without .jsonl (CM_CLAUDE_PROJECTS replaces ~/.claude/projects)
# The answer is the newest transcript's id, and it must be a full lowercase UUID. When a live process names an id it must
# be that same id.
#
# Refused (exit 1, one line `refused: <why>` on stdout, nothing else printed):
#   - two live processes name different ids
#   - a live id that is not the newest transcript's id (or has no transcript at all)
#   - no transcript at all
#   - two transcripts share the newest modification second (which one is live cannot be told)
#   - the id is not a full UUID (a title, a short prefix, a name)
#   - a pid in --pids whose command line cannot be read
# --live-only (the spawn check, spawn-verify.sh one): answer from the live process alone and skip the transcript, which does not
# exist until the first message. Exactly one live id is needed; none is refused.
# Exit 0 prints the id and nothing else. Exit 2 usage. Exit 3 the check could not be done (ssh failed, wrong host, no /proc).
#
# A remote --host is checked over ssh to cm_ssh_target (lib.sh), this script streamed to bash there, exactly as
# live-agent.sh does; the remote `hostname -s` must equal $CM_SSH_EXPECT_HOSTNAME, else the ledger's hosts.<h>.hostname,
# else the host name (exit 3 on a mismatch). Linux /proc only. CM_PROC_ROOT replaces /proc (tests only: needs CM_TEST=1).
set -uo pipefail

PROC=/proc
if [ -n "${CM_PROC_ROOT:-}" ]; then
  if [ "${CM_TEST:-}" = 1 ]; then PROC="$CM_PROC_ROOT"; else printf 'session-id: CM_PROC_ROOT ignored (it needs CM_TEST=1)\n' >&2; fi
fi
WT=""; HOST="local"; PIDS=""; LOCAL_ONLY=0; EXPECT=""; LIVE_ONLY=0
warn() { printf 'session-id: %s\n' "$*" >&2; }
usage() { sed -n '2,4p' "$0" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --host) [ $# -ge 2 ] && [ -n "$2" ] || { warn "--host needs a value"; usage; }; HOST="$2"; shift ;;
    --pids) [ $# -ge 2 ] || usage; PIDS="$2"; shift ;;
    --live-only) LIVE_ONLY=1 ;;
    --local) LOCAL_ONLY=1 ;;                       # internal: the remote side of an ssh run
    --expect-hostname) [ $# -ge 2 ] || usage; EXPECT="$2"; shift ;;   # internal
    -h|--help) awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    -*) warn "unknown arg: $1"; usage ;;
    *) [ -z "$WT" ] || { warn "one worktree path only"; usage; }; WT="$1" ;;
  esac
  shift
done
[ -n "$WT" ] || { warn "a worktree path is required"; usage; }
case "$WT" in /*) ;; *) warn "the worktree path must be absolute: $WT"; usage ;; esac
case "$PIDS" in *[!0-9\ ]*) warn "--pids takes process ids only"; exit 2 ;; esac

# ---- remote host: stream this script over ssh ----------------------------------------
if [ "$LOCAL_ONLY" = 0 ] && [ "$HOST" != local ] && [ "$HOST" != "this machine" ]; then
  HERE="$(cd "$(dirname "$0")" && pwd)"
  # shellcheck source=SCRIPTDIR/lib.sh
  . "$HERE/lib.sh"
  TARGET="$(cm_ssh_target "$HOST")"
  case "$TARGET" in -*|*[[:space:]]*|'') warn "invalid ssh target: '$TARGET'"; exit 3 ;; esac
  EXPECT="${CM_SSH_EXPECT_HOSTNAME:-}"
  if [ -z "$EXPECT" ] && [ -s "$(cm_ledger_path)" ]; then
    EXPECT="$(jq -r --arg h "$HOST" '.hosts[$h].hostname // empty' "$(cm_ledger_path)" 2>/dev/null)"
  fi
  EXPECT="${EXPECT:-$HOST}"
  case "$EXPECT" in *[!A-Za-z0-9._-]*|'') warn "invalid expected hostname: '$EXPECT'"; exit 3 ;; esac
  line="bash -s -- --local $([ "$LIVE_ONLY" = 1 ] && printf '%s' --live-only) --pids $(printf '%q' "$PIDS") --expect-hostname $(printf '%q' "$EXPECT") $(printf '%q' "$WT")"
  out="$(cm_timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=8 -- "$TARGET" "$line" < "$0")"
  rc=$?
  case "$rc" in
    0|1) printf '%s\n' "$out"; exit "$rc" ;;
    *) warn "cannot check $HOST over ssh ($TARGET): exit $rc"; exit 3 ;;
  esac
fi

# ---- local ------------------------------------------------------------------------------
if [ -n "$EXPECT" ]; then
  got="$(hostname -s 2>/dev/null || hostname)"; got="$(printf '%s' "${got%%.*}" | tr '[:upper:]' '[:lower:]')"
  if [ -z "${EXPECT%%.*}" ] || [ -z "$got" ]; then warn "empty host name (got '$got', expected '$EXPECT'): not the host asked about"; exit 3; fi
  if [ "$got" != "$(printf '%s' "${EXPECT%%.*}" | tr '[:upper:]' '[:lower:]')" ]; then
    warn "this host answered as '$got', expected '$EXPECT': not the host asked about"; exit 3
  fi
fi
if [ -n "$PIDS" ]; then
  if [ ! -d "$PROC/self" ] && [ "$PROC" = /proc ]; then warn "no /proc on this host (Linux only)"; exit 3; fi
  [ -d "$PROC" ] || { warn "$PROC is not a directory"; exit 3; }
fi

refuse() { printf 'refused: %s\n' "$*"; exit 1; }
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

# live ids: every --resume value on a live agent's command line
live=""   # newline-separated, distinct
for pid in $PIDS; do
  argv=()
  while IFS= read -r -d '' arg || [ -n "$arg" ]; do argv+=("$arg"); done < "$PROC/$pid/cmdline" 2>/dev/null || true
  [ "${#argv[@]}" -gt 0 ] || refuse "the command line of live process $pid cannot be read"
  i=0
  while [ "$i" -lt "${#argv[@]}" ]; do
    a="${argv[$i]}"; v=""; has=0
    case "$a" in
      --resume=*) v="${a#--resume=}"; has=1 ;;
      --session-id=*) v="${a#--session-id=}"; has=1 ;;
      --resume|-r|--session-id)
        # a following word that is an option means `--resume` with no value (the picker): no id from this process
        if [ $((i + 1)) -lt "${#argv[@]}" ]; then
          case "${argv[$((i + 1))]}" in -*) ;; *) v="${argv[$((i + 1))]}"; has=1 ;; esac
        fi ;;
    esac
    if [ "$has" = 1 ]; then
      [[ "$v" =~ $UUID_RE ]] || refuse "live process $pid was started with --resume \"$(printf '%s' "$v" | tr -cd 'A-Za-z0-9._-' | cut -c1-40)\", which is not a full session id"
      case "
$live
" in *"
$v
"*) ;; *) live="${live:+$live
}$v" ;; esac
    fi
    i=$((i + 1))
  done
done
nlive=0; [ -z "$live" ] || nlive="$(printf '%s\n' "$live" | grep -c .)"
[ "$nlive" -le 1 ] || refuse "live processes name $nlive different session ids"

if [ "$LIVE_ONLY" = 1 ]; then
  [ "$nlive" = 1 ] || refuse "no live process names a session id"
  printf '%s\n' "$live"; exit 0
fi

# newest transcript
dir="${CM_CLAUDE_PROJECTS:-$HOME/.claude/projects}/$(printf '%s' "$WT" | sed 's#[^A-Za-z0-9]#-#g')"
best=""; bestm=-1; ties=0
for f in "$dir"/*.jsonl; do
  [ -e "$f" ] || continue
  m="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)"
  if [ "$m" -gt "$bestm" ]; then best="$f"; bestm="$m"; ties=0
  elif [ "$m" = "$bestm" ]; then ties=$((ties + 1)); fi
done
if [ -z "$best" ]; then
  [ -z "$live" ] || refuse "live process names session $live but the worktree has no transcript"
  refuse "no transcript for this worktree under $dir"
fi
[ "$ties" = 0 ] || refuse "two transcripts of this worktree share the newest modification time: the live session cannot be told apart"
id="$(basename "$best" .jsonl)"
[[ "$id" =~ $UUID_RE ]] || refuse "the newest transcript \"$(printf '%s' "$id" | tr -cd 'A-Za-z0-9._-' | cut -c1-40)\" is not named by a full session id"
if [ -n "$live" ] && [ "$live" != "$id" ]; then refuse "the live process names session $live but the newest transcript is $id"; fi
printf '%s\n' "$id"
exit 0
