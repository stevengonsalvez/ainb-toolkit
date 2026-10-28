#!/usr/bin/env bash
# waiting.sh: list in-scope agent sessions blocked on a question menu for the
# owner (an AskUserQuestion showing in the pane).
#
#   scripts/waiting.sh       # TSV: host  orca-session-name  handle  minutes_since_last_output  question
#
# Scope: worktree paths matching config worktrees.path_match (CM_PATH_MATCH).
# Read-only. Every tick table lists each row with its wait time; the
# concertmaster never types into a menu (SKILL.md hard rule 3).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"
[ -n "$CM_PATH_MATCH" ] || { cm_warn "waiting.sh: set worktrees.path_match in config (or CM_PATH_MATCH)"; exit 2; }
ORCA="$(cm_orca)"
# Remote Orca JSON can carry lone UTF-16 surrogates and raw control characters that make
# jq fail and silently hide the session: sanitize before jq, flatten pane text with jstrings.
# Every Orca read has stdin closed (</dev/null) so none of them can swallow the loop's own input.
SAN="$HERE/jsanitize"; STR="$HERE/jstrings"
now=$(date -u +%s)
export ORCA SAN STR CM_PATH_MATCH now

scan() { # $1=host label, $2.. = extra orca args
  local host=$1; shift
  local names; names=$("$ORCA" worktree ps "$@" --json 2>/dev/null </dev/null | "$SAN" | jq -c '[.result.worktrees[]? | {key:.path, value:(.displayName // (.path|split("/")|last))}] | from_entries')
  "$ORCA" terminal list "$@" --json 2>/dev/null </dev/null | "$SAN" \
    | jq -r --arg re "$CM_PATH_MATCH" '.result.terminals[]? | select((.worktreePath//"")|test($re)) | "\(.handle)\t\(.worktreePath)\t\((.lastOutputAt//0)/1000|floor)"' \
    | while IFS=$'\t' read -r h wt last; do
        screen=$("$ORCA" terminal read --terminal "$h" "$@" --json 2>/dev/null </dev/null | "$STR" | tail -40)
        if grep -qiE 'enter to select|arrow keys to navigate|to navigate · esc' <<<"$screen"; then
          q=$(grep -E '^\s*│' <<<"$screen" | head -4 | sed 's/^\s*│\s*//' | tr '\n' ' ' | cut -c1-110)
          [ -z "$q" ] && q=$(grep -E '\?\s*$' <<<"$screen" | tail -1 | cut -c1-110)
          printf '%s\t%s\t%s\t%s\t%s\n' "$host" "$(jq -r --arg p "$wt" '.[$p] // ($p|split("/")|last)' <<<"$names")" "$h" "$(( (now-last)/60 ))" "$q"
        fi
      done
}

scan local
for e in $("$ORCA" host list --json 2>/dev/null </dev/null | "$SAN" | jq -r '.result.hosts[]? | select(.name!="this machine") | .name'); do
  cm_timeout 60 bash -c "$(declare -f scan); scan \"\$1\" --environment \"\$1\"" _ "$e" 2>/dev/null
done
