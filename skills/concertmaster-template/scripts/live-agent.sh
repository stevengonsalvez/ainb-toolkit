#!/usr/bin/env bash
# live-agent.sh: is an agent process alive in this worktree, whatever the ledger says?
#
#   scripts/live-agent.sh <worktree-path> [--host <h>]
#
# The respawn guard. A ledger terminal handle and Orca's census can both be stale after a restart: a
# stale handle made a live standing lane look dead, and a second agent was started in the same worktree.
# A process whose cwd is the worktree cannot be stale. lane-handles.sh runs this for every worker; a
# caller about to respawn a lane runs it first and never respawns when it exits 0.
#
# Per match one line on stdout, tab separated: pid, handle, agent.
#   pid     the process id on the host that was scanned
#   handle  PLUGLY_TERMINAL_HANDLE from the process environment when present and non-empty,
#           else ORCA_TERMINAL_HANDLE (the REAL terminal handle; PLUGLY wins when both are set),
#           empty when the process was not started by a Plugly or Orca terminal or its environ
#           is unreadable
#   agent   the configured agent name the command line matched (claude, codex, agy, ...)
#
# A match is a process of this user that is not a zombie, runs on a terminal (an Orca agent
# always does; a tty-less daemon such as the Codex app-server broker is not a lane), whose
# cwd is the worktree or inside it (never a sibling that only shares a path prefix: /w/dev
# does not match /w/dev2), and whose command basename (argv[0], or the first non-option
# argument behind an interpreter such as node) is a configured agent name. A shell, an
# editor or any other command in the worktree is not a match.
#
# Agent names: respawn.live_agents in the config (cm_cfg), default "claude codex agy"; an
# empty list is refused (exit 2). A match is on argv, or on the kernel process name (comm).
#
# Linux /proc only. CM_PROC_ROOT replaces /proc (tests only: it needs CM_TEST=1). A remote
# --host is scanned over ssh to cm_ssh_target (lib.sh): $CM_SSH_TARGET, else the ledger's
# hosts.<h>.sshTarget, else hosts.<h>.hostname when it is an address, else the host name;
# this script is streamed to bash there.
# The remote `hostname -s` must equal $CM_SSH_EXPECT_HOSTNAME, else the ledger's
# hosts.<h>.hostname, else the host name (as teardown.sh checks); a mismatch is exit 3, so a
# CM_SSH_TARGET meant for one host never answers for another.
#
# Exit 0 a live agent was found (rows printed); 1 none found; 2 usage or a bad agent list; 3 the
# check could not be done (no /proc on that host, ssh failed, wrong host, an unreadable agent
# entry). 2 and 3 are never "no agent": the caller leaves the lane alone and reports it for a
# hand check, it never respawns on them.
set -uo pipefail

PROC=/proc
if [ -n "${CM_PROC_ROOT:-}" ]; then
  if [ "${CM_TEST:-}" = 1 ]; then PROC="$CM_PROC_ROOT"; else printf 'live-agent: CM_PROC_ROOT ignored (it needs CM_TEST=1)\n' >&2; fi
fi
WT=""; HOST="local"; AGENTS=""; LOCAL_ONLY=0; EXPECT=""

warn() { printf 'live-agent: %s\n' "$*" >&2; }
usage() { sed -n '2,5p' "$0" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --host) [ $# -ge 2 ] && [ -n "$2" ] || { warn "--host needs a value"; usage; }; HOST="$2"; shift ;;
    --local) LOCAL_ONLY=1 ;;                       # internal: the remote side of an ssh run
    --agents) [ $# -ge 2 ] || usage; AGENTS="$2"; shift ;;   # internal: names resolved by the caller
    --expect-hostname) [ $# -ge 2 ] || usage; EXPECT="$2"; shift ;;   # internal: the remote side checks it is the right machine
    -h|--help) awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    -*) warn "unknown arg: $1"; usage ;;
    *) [ -z "$WT" ] || { warn "one worktree path only"; usage; }; WT="$1" ;;
  esac
  shift
done
[ -n "$WT" ] || { warn "a worktree path is required"; usage; }
case "$WT" in /*) ;; *) warn "the worktree path must be absolute: $WT"; usage ;; esac

# ---- remote host: stream this script over ssh ----------------------------------------
if [ "$LOCAL_ONLY" = 0 ] && [ "$HOST" != local ] && [ "$HOST" != "this machine" ]; then
  HERE="$(cd "$(dirname "$0")" && pwd)"
  # shellcheck source=SCRIPTDIR/lib.sh
  . "$HERE/lib.sh"
  AGENTS="${AGENTS:-$(cm_cfg .respawn.live_agents "claude codex agy")}"
  TARGET="$(cm_ssh_target "$HOST")"   # CM_SSH_TARGET, else a ledger hostname that is an address, else the host name (lib.sh)
  case "$TARGET" in -*|*[[:space:]]*|'') warn "invalid ssh target: '$TARGET'"; exit 3 ;; esac
  EXPECT="${CM_SSH_EXPECT_HOSTNAME:-}"
  if [ -z "$EXPECT" ] && [ -s "$(cm_ledger_path)" ]; then
    EXPECT="$(jq -r --arg h "$HOST" '.hosts[$h].hostname // empty' "$(cm_ledger_path)" 2>/dev/null)"
  fi
  EXPECT="${EXPECT:-$HOST}"
  case "$EXPECT" in *[!A-Za-z0-9._-]*|'') warn "invalid expected hostname: '$EXPECT'"; exit 3 ;; esac
  line="bash -s -- --local --agents $(printf '%q' "$AGENTS") --expect-hostname $(printf '%q' "$EXPECT") $(printf '%q' "$WT")"
  # The bound is whole seconds: a non-number would make perl's alarm 0 (no bound at all), so fall back to 20.
  SSH_S="${CM_LIVE_AGENT_SSH_S:-20}"
  case "$SSH_S" in ''|*[!0-9]*) SSH_S=0 ;; *) SSH_S=$((10#$SSH_S)) ;; esac   # 08 is a number, not bad octal; 00 is zero
  [ "$SSH_S" -gt 0 ] || { warn "CM_LIVE_AGENT_SSH_S='${CM_LIVE_AGENT_SSH_S:-}' is not a positive whole number of seconds: using 20"; SSH_S=20; }
  out="$(cm_timeout "$SSH_S" ssh -o BatchMode=yes -o ConnectTimeout=8 -- "$TARGET" "$line" < "$0")"
  rc=$?
  case "$rc" in
    0) printf '%s\n' "$out"; exit 0 ;;
    1) exit 1 ;;
    *) warn "cannot check $HOST over ssh ($TARGET): exit $rc"; exit 3 ;;
  esac
fi

# ---- local scan ------------------------------------------------------------------------
if [ -z "$AGENTS" ]; then
  if [ "$LOCAL_ONLY" = 0 ]; then
    HERE="$(cd "$(dirname "$0")" && pwd)"
    # shellcheck source=SCRIPTDIR/lib.sh
    . "$HERE/lib.sh"
    AGENTS="$(cm_cfg .respawn.live_agents "claude codex agy")"
  else
    AGENTS="claude codex agy"
  fi
fi
# Names reach a pattern match only: keep a plain word list, nothing else.
case "$AGENTS" in *[!A-Za-z0-9._\ -]*) warn "respawn.live_agents holds a character outside [A-Za-z0-9._ -]"; exit 2 ;; esac
# An empty list matches nothing and would read as "no agent": refuse it (exit 2, the caller leaves the lane alone).
[ -n "$(printf '%s' "$AGENTS" | tr -d ' ')" ] || { warn "respawn.live_agents is empty: refusing to report 'no agent'"; exit 2; }

if [ -n "$EXPECT" ]; then
  got="$(hostname -s 2>/dev/null || hostname)"; got="$(printf '%s' "${got%%.*}" | tr '[:upper:]' '[:lower:]')"
  if [ -z "${EXPECT%%.*}" ] || [ -z "$got" ]; then warn "empty host name (got '$got', expected '$EXPECT'): not the host asked about"; exit 3; fi
  # `hostname -s` is the short name, so the expected name (a ledger hostname may be a FQDN) is cut to it too.
  if [ "$got" != "$(printf '%s' "${EXPECT%%.*}" | tr '[:upper:]' '[:lower:]')" ]; then
    warn "this host answered as '$got', expected '$EXPECT': not the host asked about"; exit 3
  fi
fi
if [ ! -d "$PROC/self" ] && [ "$PROC" = /proc ]; then
  warn "no /proc on this host (Linux only): the live-agent check is not possible"; exit 3
fi
[ -d "$PROC" ] || { warn "$PROC is not a directory: the live-agent check is not possible"; exit 3; }

# Canonical worktree path: a symlinked or ./-laden path still compares equal to a cwd.
want="$WT"
if canon="$(cd "$WT" 2>/dev/null && pwd -P)"; then want="$canon"; fi
want="${want%/}"; [ -n "$want" ] || want="/"

# agent_of <comm> <argv...>: the configured agent name the command is, else nothing. The kernel's
# process name (comm) counts too, so a renamed or versioned path still matches. Behind an
# interpreter (node, bun, ...) the first argument that is not an option is the command.
agent_of() {
  local b a c="$1"
  shift
  for a in $AGENTS; do [ "$c" = "$a" ] && { printf '%s' "$a"; return; }; done
  b="${1##*/}"
  case "$b" in
    node|nodejs|bun|deno)
      shift
      # an option that takes a value (node -r pre.js, --import x) must not hand that value over as the command
      while [ $# -gt 0 ]; do
        case "$1" in
          -e|--eval|-p|--print) break ;;   # inline code: the words after it are its arguments, not a command
          -r|--require|--import|--loader|--experimental-loader|-C|--conditions) shift; [ $# -gt 0 ] && shift ;;
          -*) shift ;;
          *) b="${1##*/}"; break ;;
        esac
      done ;;
  esac
  for a in $AGENTS; do [ "$b" = "$a" ] && { printf '%s' "$a"; return; }; done
}

found=0; unreadable=0
for d in "$PROC"/[0-9]*; do
  [ -d "$d" ] || continue
  pid="${d##*/}"
  case "$pid" in ''|*[!0-9]*) continue ;; esac
  [ -O "$d" ] || continue                        # our agents are ours; another user's entry is not
  # State and terminal from stat, read past the last ")" (the command name may hold spaces and
  # parens): skip a zombie or dead entry, and a process with no terminal (a daemon such as the
  # Codex app-server broker keeps the lane's handle in its environment but is not the lane).
  if ! stat="$(cat "$d/stat" 2>/dev/null)"; then [ -e "$d" ] && unreadable=1; continue; fi
  rest="${stat##*) }"
  read -r state _ _ _ tty _ <<< "$rest"
  case "$state" in Z|X|x) continue ;; esac
  case "$tty" in ''|*[!0-9]*) unreadable=1; continue ;; 0) continue ;; esac
  # Name the process BEFORE anything else is read: an unreadable entry only matters when the process
  # could be an agent, so one unrelated process (a hardened or non-dumpable one) cannot make every
  # row on the host exit 3.
  argv=()
  # `|| [ -n "$arg" ]` keeps a last word that has no closing NUL (read returns 1 for it but has filled the variable)
  while IFS= read -r -d '' arg || [ -n "$arg" ]; do argv+=("$arg"); done < "$d/cmdline" 2>/dev/null || true
  if [ "${#argv[@]}" -eq 0 ]; then [ -r "$d/cmdline" ] || { [ -e "$d" ] && unreadable=1; }; continue; fi
  comm=""; [ -r "$d/comm" ] && IFS= read -r comm < "$d/comm" 2>/dev/null
  agent="$(agent_of "$comm" "${argv[@]}")"
  [ -n "$agent" ] || continue
  cwd="$(readlink "$d/cwd" 2>/dev/null)" || { [ -e "$d" ] && unreadable=1; continue; }   # a vanished pid is fine
  cwd="${cwd%/}"; [ -n "$cwd" ] || cwd="/"
  if [ "$cwd" != "$want" ]; then
    case "$cwd" in "$want"/*) ;; *) continue ;; esac
  fi
  handle=""
  if [ -r "$d/environ" ]; then
    # Read the WHOLE environ before choosing: the two names come in either order. PLUGLY_TERMINAL_HANDLE is
    # the handle when present and non-empty (a Plugly daemon started from an Orca shell inherits that
    # shell's ORCA_TERMINAL_HANDLE, and PLUGLY wins); otherwise ORCA_TERMINAL_HANDLE. The first occurrence of a name counts.
    h_plugly=""; h_orca=""; seen_plugly=0; seen_orca=0
    while IFS= read -r -d '' kv || [ -n "$kv" ]; do
      case "$kv" in
        PLUGLY_TERMINAL_HANDLE=*) if [ "$seen_plugly" = 0 ]; then seen_plugly=1; h_plugly="${kv#PLUGLY_TERMINAL_HANDLE=}"; fi ;;
        ORCA_TERMINAL_HANDLE=*)   if [ "$seen_orca" = 0 ]; then seen_orca=1; h_orca="${kv#ORCA_TERMINAL_HANDLE=}"; fi ;;
      esac
    done < "$d/environ"
    if [ -n "$h_plugly" ]; then handle="$h_plugly"; else handle="$h_orca"; fi
  fi
  # The handle is written to the ledger and into commands later: a plain token only.
  case "$handle" in -*|*[!A-Za-z0-9._:-]*) handle="" ;; esac   # a leading "-" would read as an option wherever the handle is used
  printf '%s\t%s\t%s\n' "$pid" "$handle" "$agent"
  found=1
done

if [ "$found" = 1 ]; then exit 0; fi
# Nothing found but an entry we could not read: that proves nothing, so say so.
if [ "$unreadable" = 1 ]; then warn "a process entry in $PROC was unreadable: the check is incomplete"; exit 3; fi
exit 1
