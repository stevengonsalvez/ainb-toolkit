#!/usr/bin/env bash
# mc-worker-hook.sh: Claude Code hook (SessionStart, Stop, Notification) that
# reports a worker's lifecycle to the telemetry sink (mc-emit.sh).
#
# Reads the hook JSON from stdin. Exits 0 silently unless the session's cwd
# is inside a repo of config github.org (github.exclude_repo_patterns left out):
# global hooks fire for every repo on a shared host, and other repos must emit
# nothing. Needs lib.sh next to mc-emit.sh (and config.yaml in $CM_HOME when
# installed to ~/.concertmaster/bin).
#
# Fire and forget: the emit runs detached, stdout stays empty (SessionStart
# stdout would be injected into the session's context), and the hook never
# fails or blocks the agent.
#
# Emitter lookup: $CM_MC_EMIT, then ~/.concertmaster/bin/mc-emit.sh, then
# ../mc-emit.sh next to this file. Install: references/hooks-install.md.
set -u

input="$(cat 2>/dev/null || true)"
command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

field() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }
event="$(field .hook_event_name)"
cwd="$(field .cwd)"
session="$(field .session_id)"
[ -n "$cwd" ] && [ -d "$cwd" ] || exit 0

url="$(git -C "$cwd" remote get-url origin 2>/dev/null | tr '[:upper:]' '[:lower:]')" || exit 0

here="$(cd "$(dirname "$0")" && pwd)"
lib=""
for c in "$here/lib.sh" "$here/../lib.sh" "$HOME/.concertmaster/bin/lib.sh"; do
  if [ -r "$c" ]; then lib="$c"; break; fi
done
[ -n "$lib" ] || exit 0
# shellcheck source=SCRIPTDIR/../lib.sh
. "$lib" 2>/dev/null || exit 0
cm_org_slug "$url" >/dev/null 2>&1 || exit 0
emit="${CM_MC_EMIT:-}"
for c in "$emit" "$HOME/.concertmaster/bin/mc-emit.sh" "$here/../mc-emit.sh"; do
  if [ -n "$c" ] && [ -x "$c" ]; then emit="$c"; break; fi
  emit=""
done
[ -n "$emit" ] || exit 0

repo="${url##*/}"; repo="${repo%.git}"
top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$cwd")"
branch="$(git -C "$cwd" symbolic-ref --short -q HEAD 2>/dev/null || true)"
host="$(hostname 2>/dev/null | cut -d. -f1)"
wt="${top##*/}"
agent_id="${host}:${session:-unknown}"
name="${repo}/${wt}"

case "$event" in
  SessionStart) type=session.start;        status=active; task="session started (${branch:-detached})" ;;
  Stop)         type=session.stop;         status=idle;   task="turn ended (${branch:-detached})" ;;
  Notification) type=session.notification; status=idle;   task="$(field .message | cut -c1-200)" ;;
  *) exit 0 ;;
esac

meta="$(jq -cn --arg host "$host" --arg session "$session" --arg repo "$repo" --arg wt "$top" \
          --arg branch "$branch" --arg event "$event" --arg src "$(field .source)" \
  '{source:"worker-hook", host:$host, sessionId:$session, repo:$repo, worktree:$wt,
    branch:$branch, hookEvent:$event, startSource:$src}')"

(
  MC_QUIET=1 "$emit" "$type" "$name: $task" "$meta"
  MC_QUIET=1 "$emit" --fleet-upsert "$agent_id" "$name" "$status" "$task" "$top" false
) </dev/null >/dev/null 2>&1 &

exit 0
