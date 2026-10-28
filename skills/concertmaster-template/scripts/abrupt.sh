#!/usr/bin/env bash
# abrupt.sh: list in-scope sessions that were cut off by a restart: background
# work that "didn't finish before the previous session ended", a stale /loop
# resume line with no tick after it, or an agent terminal that fell back to a
# shell. Also flags two live claude processes in one worktree (one
# conversation forked by a resume).
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
for d in $(for p in $(pgrep -x claude 2>/dev/null); do readlink /proc/"$p"/cwd 2>/dev/null; done | grep -E "$CM_PATH_MATCH" | sort | uniq -d); do
  printf 'local\t%s\t-\tDUPLICATE live agents: %s\n' "$(basename "$d")" "$(for p in $(pgrep -x claude); do [ "$(readlink /proc/"$p"/cwd)" = "$d" ] && printf '%s ' "$p"; done)"
done
