#!/usr/bin/env bash
# pane-stalls.sh: find agent panes that sit on a permission prompt ("Do you want to proceed?"), on every host.
#
#   scripts/pane-stalls.sh          # rows: STALL|UNREAD <TAB> lane <TAB> host <TAB> handle <TAB> matched line; one count line
#   scripts/pane-stalls.sh --json   # the same as one JSON document
#
# Why this script exists: review subagents of a sweeper lane sat for hours on a Claude Code "Dangerous rm operation"
# approval prompt raised by a test harness. A subagent prompt NEVER shows in a worktree comment, so the comment-based
# checks (asks.sh, the census) saw a lane that looked busy and alive. The only place the prompt is visible is the
# pane, so the tick reads the panes.
#
# Scope: every agent terminal (a standing lane or a worker) whose worktree path matches worktrees.path_match, on every
# host, except worktrees.never_touch. Handles are re-resolved from the worktree path on every run
# (`orca terminal list`), never cached. Each pane is read with `orca terminal read --screen` and only its last
# CM_STALL_LINES (default 25) non-empty lines are judged, so old scrollback never counts.
# The match is the extended regex in config `stalls.regex` (env CM_STALL_REGEX), default "Do you want to proceed".
#
# Output: one STALL row per pane that matches. One UNREAD row per pane that could not be read, per host whose terminals
# could not be listed, and per host the fleet reader could not reach: an unread pane is "unknown", never "clean".
# A matched line that looks like a credential is replaced by a marker. A quiet fleet prints exactly one line,
# "pane-stalls: 0 stalls, N panes read". Read only: it never sends a key, answers a prompt or closes a pane.
#
# Exit: 0 when it ran (stalls and unread panes are listed, not an error), 2 usage.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"
# shellcheck source=SCRIPTDIR/fleet-read.sh
. "$HERE/fleet-read.sh"
# shellcheck source=SCRIPTDIR/secret-shape.sh
. "$HERE/secret-shape.sh"

JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1 ;;
    -h|--help) sed -n '2,/^set -uo/{/^#/p;}' "$0"; exit 0 ;;
    *) cm_warn "pane-stalls.sh: unknown arg: $1"; exit 2 ;;
  esac
  shift
done

[ -n "${CM_PATH_MATCH:-}" ] || { cm_warn "pane-stalls.sh: set worktrees.path_match in config (or CM_PATH_MATCH)"; exit 2; }
ORCA="$(cm_orca)"
SAN="$HERE/jsanitize"
NEVER="${CM_NEVER_TOUCH:-$(cm_cfg .worktrees.never_touch)}"
RE="${CM_STALL_REGEX:-$(cm_cfg .stalls.regex "Do you want to proceed")}"
[ -n "$RE" ] || RE="Do you want to proceed"
LINES_N="${CM_STALL_LINES:-25}"
case "$LINES_N" in ''|*[!0-9]*) LINES_N=25 ;; esac
TOUT="${CM_HOST_TIMEOUT:-30}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cm-pstall.XXXXXX")" || { cm_warn "pane-stalls.sh: cannot create a temp dir"; exit 1; }
trap 'rm -rf -- "${TMP:?}"' EXIT
: > "$TMP/rows.ndjson"
# shellcheck disable=SC2086  # NEVER is a space-joined list on purpose
printf '%s\n' $NEVER | tr '[:upper:]' '[:lower:]' | grep . | jq -R . | jq -sc . > "$TMP/never.json" 2>/dev/null || printf '[]\n' > "$TMP/never.json"
NREAD=0

# Hosts and their worktree lists (names for the lane column): the shared fleet reader.
mkdir -p "$TMP/fleet"
cm_fleet_worktrees "$TMP/fleet"
while IFS= read -r u; do
  [ -n "$u" ] || continue
  jq -c '{kind: "UNREAD", lane: "-", host: .host, handle: "-", line: ("host not read: " + (.error | tostring | .[0:120]))}' <<<"$u" >> "$TMP/rows.ndjson"
done < "$TMP/fleet/unreach.ndjson"

row() { # <kind> <lane> <host> <handle> <line>
  jq -cn --arg k "$1" --arg l "$2" --arg h "$3" --arg t "$4" --arg x "$5" '{kind:$k, lane:$l, host:$h, handle:$t, line:$x}' >> "$TMP/rows.ndjson"
}

while IFS= read -r hrow; do
  [ -n "$hrow" ] || continue
  host="$(jq -r '.host' <<<"$hrow")"; wlf="$(jq -r '.file' <<<"$hrow")"
  envargs=(); [ "$host" = local ] || envargs=(--environment "$host")
  tl="$TMP/terminals-$host.json"
  if ! cm_timeout "$TOUT" "$ORCA" terminal list --json ${envargs[@]+"${envargs[@]}"} </dev/null 2>/dev/null | "$SAN" > "$tl" \
     || ! jq -e '.ok == true and (.result.terminals | type == "array")' "$tl" >/dev/null 2>&1; then
    row UNREAD "-" "$host" "-" "terminals not listed on this host: panes not read"
    continue
  fi
  # path -> lane name from this host's worktree list; agent terminals in scope, never_touch skipped
  while IFS=$'\t' read -r handle wpath; do
    [ -n "$handle" ] || continue
    lane="$(jq -r --arg p "$wpath" '[.result.worktrees[]? | select(.path == $p) | (.displayName // empty)] | first // ($p | split("/") | last)' "$wlf")"
    if jq -e --arg n "$lane" 'index($n | ascii_downcase) != null' "$TMP/never.json" >/dev/null 2>&1; then continue; fi
    scr="$(cm_timeout "$TOUT" "$ORCA" terminal read --terminal "$handle" --screen --json ${envargs[@]+"${envargs[@]}"} </dev/null 2>/dev/null | "$SAN" \
      | jq -r 'if .ok == true then ((.result.terminal.tail // .result.screen // .result.text // empty) | if type == "array" then join("\n") else tostring end) else empty end' 2>/dev/null)" || scr=""
    if [ -z "$(printf '%s' "$scr" | tr -d '[:space:]')" ]; then row UNREAD "$lane" "$host" "$handle" "pane not readable"; continue; fi
    NREAD=$((NREAD + 1))
    hit="$(printf '%s\n' "$scr" | LC_ALL=C tr -d '\000-\010\013-\037\177' | grep -v '^[[:space:]]*$' | tail -n "$LINES_N" | grep -E -- "$RE" | tail -n 1 | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | cut -c1-160)" || hit=""
    [ -n "$hit" ] || continue
    if secret_shaped "$hit"; then hit="[matched line withheld: credential-shaped]"; fi
    row STALL "$lane" "$host" "$handle" "$hit"
  done < <(jq -r --arg re "$CM_PATH_MATCH" '.result.terminals[]? | select((.worktreePath // "") | test($re)) | select((.agentIdentity // "") != "") | [.handle, .worktreePath] | @tsv' "$tl")
done < "$TMP/fleet/hosts.ndjson"

NSTALL="$(jq -s 'map(select(.kind == "STALL")) | length' "$TMP/rows.ndjson")"
NUNREAD="$(jq -s 'map(select(.kind == "UNREAD")) | length' "$TMP/rows.ndjson")"
if [ "$JSON" -eq 1 ]; then
  jq -s --argjson read "$NREAD" --argjson s "$NSTALL" --argjson u "$NUNREAD" '{stalls: map(select(.kind == "STALL")), unread: map(select(.kind == "UNREAD")), counts: {stalls: $s, unread: $u, panesRead: $read}}' "$TMP/rows.ndjson"
else
  jq -r '[.kind, .lane, .host, .handle, .line] | @tsv' "$TMP/rows.ndjson"
  if [ "$NUNREAD" -gt 0 ]; then echo "pane-stalls: $NSTALL stalls, $NUNREAD unread (unknown, not clean), $NREAD panes read"
  else echo "pane-stalls: $NSTALL stalls, $NREAD panes read"; fi
fi
exit 0
