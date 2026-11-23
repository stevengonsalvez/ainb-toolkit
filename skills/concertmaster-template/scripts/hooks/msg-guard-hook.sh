#!/usr/bin/env bash
# msg-guard-hook.sh: Claude Code PreToolUse hook (matcher: SendMessage) that enforces the owner
# rule "leads and the concertmaster coordinate ONLY through the fleet CLI".
#
# Why: SendMessage to another session (a named peer, or a cc-socks unix socket) bypasses the
# fleet CLI, the worktree comment and the ledger, so nothing records it and a resumed or
# rebooted session loses it. A denial with the fix costs the agent one turn.
#
# Denies SendMessage when the recipient is anything but an agent id: a named session
# (rs-lead-g-4f), a uds:/run/user/<uid>/cc-socks/<pid>.sock target, or a broadcast (*).
# Allowed: an agent id (continuing one's own subagent), no recipient, any other tool, any parse
# doubt, a missing jq, a session outside this project's checkouts (same scope as rm-guard-hook.sh:
# worktrees.path_match, or a git origin in github.org), and CM_ALLOW_SENDMESSAGE=1 in the env.
#
# Install: references/prompt-stalls.md (section "The SendMessage guard"). Exit code is always 0;
# the verdict is the JSON.
set -u
input="$(cat 2>/dev/null || true)"
command -v jq >/dev/null 2>&1 || exit 0
[ "$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)" = SendMessage ] || exit 0
[ "${CM_ALLOW_SENDMESSAGE:-0}" = 1 ] && exit 0
to="$(printf '%s' "$input" | jq -r '(.tool_input.to // .tool_input.recipient // .tool_input.target // empty) | tostring' 2>/dev/null)"
[ -n "$to" ] || exit 0
case "$to" in
  uds:*|*cc-socks*) ;;
  *) printf '%s' "$to" | grep -qE '^a?[0-9a-f]{8,}$' && exit 0 ;;   # an agent id: the caller's own subagent
esac

# Scope: this project's checkouts only (a global hook must not change other projects).
here="$(cd "$(dirname "$0")" && pwd)"
lib=""
for c in "$here/lib.sh" "$here/../lib.sh" "$HOME/.concertmaster/bin/lib.sh"; do
  if [ -r "$c" ]; then lib="$c"; break; fi
done
[ -n "$lib" ] || exit 0
# shellcheck source=SCRIPTDIR/../lib.sh
. "$lib" 2>/dev/null || exit 0
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
in_scope=0
if [ -n "${CM_PATH_MATCH:-}" ] && [ -n "$cwd" ]; then
  shopt -s nocasematch
  [[ "$cwd/" =~ $CM_PATH_MATCH ]] && in_scope=1
  shopt -u nocasematch
fi
if [ "$in_scope" = 0 ] && [ -n "$cwd" ] && [ -d "$cwd" ] && command -v git >/dev/null 2>&1; then
  url="$(git -C "$cwd" remote get-url origin 2>/dev/null || true)"
  if [ -n "$url" ] && cm_org_slug "$url" >/dev/null 2>&1; then in_scope=1; fi
fi
[ "$in_scope" = 1 ] || exit 0

reason="SendMessage to another session ('$to') is not allowed here (owner rule: leads and the concertmaster coordinate ONLY through the fleet CLI). Instead: send text to a lane with 'plugly terminal send --terminal <handle> --text \"<message>\" --enter' (the concertmaster skill's scripts/gsend.sh does the same with checks), and report up with a worktree comment: 'plugly worktree set --worktree active --comment \"cm:<state> <detail>\"'. Never SendMessage and never cc-socks."
jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
