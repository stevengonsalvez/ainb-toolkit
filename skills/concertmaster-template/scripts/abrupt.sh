#!/usr/bin/env bash
# abrupt.sh: list in-scope sessions that were cut off by a restart: background
# work that "didn't finish before the previous session ended", a stale /loop
# resume line with no tick after it, or an agent terminal that fell back to a
# shell. Also flags two live claude processes in one worktree (one
# conversation forked by a resume): a pid counts only when alive in two samples
# CM_ABRUPT_RESAMPLE seconds apart (default 3, 0 = one sample), `claude -p` ignored.
#
#   scripts/abrupt.sh        # TSV: host  orca-session-name  handle  reason
#
# Scope: worktree paths matching config worktrees.path_match (CM_PATH_MATCH,
# an extended regex such as "/acme/"). Read-only: it never sends or closes.
# Run it every tick; nudge or resume what it lists (SKILL.md § Stuck rule,
# § Resume), never while resume.lock exists.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"
[ -n "$CM_PATH_MATCH" ] || { cm_warn "abrupt.sh: set worktrees.path_match in config (or CM_PATH_MATCH)"; exit 2; }
ORCA="$(cm_orca)"
# Remote Orca JSON can carry lone UTF-16 surrogates and raw control characters that make
# jq fail and silently hide the session: sanitize before jq, flatten pane text with jstrings.
SAN="$HERE/jsanitize"; STR="$HERE/jstrings"
export ORCA SAN STR CM_PATH_MATCH

scan() {
  local host=$1; shift
  local names; names=$("$ORCA" worktree ps "$@" --json 2>/dev/null </dev/null | "$SAN" | jq -c '[.result.worktrees[]? | {key:.path, value:(.displayName // (.path|split("/")|last))}] | from_entries')
  "$ORCA" terminal list "$@" --json 2>/dev/null </dev/null | "$SAN" \
    | jq -r --arg re "$CM_PATH_MATCH" '.result.terminals[]? | select((.worktreePath//"")|test($re)) | "\(.handle)\t\(.worktreePath)\t\(.agentIdentity // "")"' \
    | while IFS=$'\t' read -r h wt agent; do
        s=$("$ORCA" terminal read --terminal "$h" "$@" --json 2>/dev/null </dev/null | "$STR" | grep -v '^\s*$' | tail -40)
        name=$(jq -r --arg p "$wt" '.[$p] // ($p|split("/")|last)' <<<"$names")
        r=""
        grep -qE "didn't finish before the previous session ended" <<<"$s" && r="background work cut off by restart"
        if [ -z "$r" ] && grep -qE 'Claude resuming /loop wakeup' <<<"$s" && ! grep -qE '✻ .*· done' <<<"$(grep -A50 'Claude resuming /loop wakeup' <<<"$s" | tail -n +2)" && ! grep -qE '… \(|esc to interrupt' <<<"$(tail -12 <<<"$s")"; then r="loop resume pending"; fi
        # A worktree can hold a shell tab next to the live agent tab; only call it
        # "agent gone" when no claude process (local scan) has its cwd in the worktree.
        if [ -z "$r" ] && [ "$agent" = "claude" ] && ! grep -qE 'bypass permissions|ctx \[|✻|esc to interrupt' <<<"$s" && grep -qE '❯\s*$' <<<"$s"; then
          live=0
          if [ "$host" = local ]; then
            for p in $(pgrep -x claude 2>/dev/null); do [ "$(readlink /proc/"$p"/cwd 2>/dev/null)" = "$wt" ] && { live=1; break; }; done
          fi
          [ $live -eq 0 ] && r="agent gone, bare shell"
        fi
        [ -n "$r" ] && printf '%s\t%s\t%s\t%s\n' "$host" "$name" "$h" "$r"
      done
}

scan local
for e in $("$ORCA" host list --json 2>/dev/null </dev/null | "$SAN" | jq -r '.result.hosts[]? | select(.name!="this machine") | .name'); do
  cm_timeout 90 bash -c "$(declare -f scan); scan \"\$1\" --environment \"\$1\"" _ "$e" 2>/dev/null
done

# Duplicate live claude agents in one worktree (Linux /proc; local host only).
# One pgrep sample is not enough: a hook or a `claude -p` child lives a few seconds and made a
# false DUPLICATE alarm more than once. A pid counts only when it is alive, with the same cwd,
# in two samples CM_ABRUPT_RESAMPLE seconds apart (default 3, under 10; 0 = one sample, the old
# behaviour; the wait and second sample run only when the first holds a shared cwd),
# and a headless one-shot (`claude -p`, `claude --print`) is never counted. A worktree is reported
# only when two or more counted pids share its cwd. CM_PROC_ROOT replaces /proc (tests only, it
# needs CM_TEST=1).
export LC_ALL=C   # sort, comm and uniq must agree on one byte order
PROC=/proc
if [ -n "${CM_PROC_ROOT:-}" ]; then
  if [ "${CM_TEST:-}" = 1 ]; then PROC="$CM_PROC_ROOT"; else cm_warn "abrupt.sh: CM_PROC_ROOT ignored (it needs CM_TEST=1)"; fi
fi
RESAMPLE="${CM_ABRUPT_RESAMPLE:-3}"
case "$RESAMPLE" in ''|*[!0-9.]*|*.*.*|.|[1-9][0-9]|[1-9][0-9][0-9.]*|[0-9][0-9][0-9]*)   # a bad value or 10+ seconds (a stalled tick) is the default, said on stderr
    [ -z "${CM_ABRUPT_RESAMPLE:-}" ] || cm_warn "abrupt.sh: CM_ABRUPT_RESAMPLE='$CM_ABRUPT_RESAMPLE' is not a wait under 10 seconds: using 3"
    RESAMPLE=3 ;;
esac

# claude_samples: one line per counted pid, "pid<TAB>cwd", sorted. Skips a pid with no readable cwd
# (it exited) and a headless one-shot (-p, --print or --print=... among its arguments).
claude_samples() {
  local p cwd arg headless
  for p in $(pgrep -x claude 2>/dev/null); do
    headless=0
    # the group, not the redirect, carries 2>/dev/null: a pid that exits between pgrep and this
    # read must not leak "No such file or directory" into the tick output
    { while IFS= read -r -d '' arg || [ -n "$arg" ]; do
        case "$arg" in -p|--print|--print=*) headless=1; break ;; esac
      done < "$PROC/$p/cmdline"; } 2>/dev/null
    [ $headless -eq 1 ] && continue
    cwd=$(readlink "$PROC/$p/cwd" 2>/dev/null) || continue
    [ -n "$cwd" ] && printf '%s\t%s\n' "$p" "$cwd"
  done | sort
}

first=$(claude_samples)
# The wait and the second sample run only when the first sample holds an in-scope cwd (path_match)
# shared by two pids (almost never): an ordinary tick pays no delay. A zero wait (0, 00, 0.0) is one sample.
if [ -n "${RESAMPLE//[0.]/}" ] && [ -n "$(printf '%s\n' "$first" | awk -F'\t' 'NF == 2 { print $2 }' | grep -E "$CM_PATH_MATCH" | sort | uniq -d)" ]; then
  sleep "$RESAMPLE"
  second=$(claude_samples)
  agents=$(comm -12 <(printf '%s\n' "$first") <(printf '%s\n' "$second"))
else
  agents="$first"
fi
printf '%s\n' "$agents" | awk -F'\t' 'NF == 2 { print $2 }' | grep -E "$CM_PATH_MATCH" | sort | uniq -d \
  | while IFS= read -r d; do
      # the path goes in through ENVIRON: awk -v would turn a backslash in it into an escape
      printf 'local\t%s\t-\tDUPLICATE live agents: %s\n' "$(basename "$d")" \
        "$(printf '%s\n' "$agents" | D="$d" awk -F'\t' '$2 == ENVIRON["D"] { print $1 }' | sort -n | paste -sd' ' -)"
    done
