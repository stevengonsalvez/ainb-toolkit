#!/usr/bin/env bash
# msg-guard-hook.sh: Claude Code PreToolUse hook (matcher: SendMessage|Agent) that enforces the owner
# rule "leads and the concertmaster coordinate ONLY through the fleet CLI".
#
# Why: SendMessage to another session (a named peer, or a cc-socks unix socket) bypasses the
# fleet CLI, the worktree comment and the ledger, so nothing records it and a resumed or
# rebooted session loses it. A denial with the fix costs the agent one turn.
#
# Agent: a tool_input.name of the subagent shape (^[a-z0-9][a-z0-9_-]*$, lowercased and trimmed) is appended to this
# session's record, ${TMPDIR:-/tmp}/cm-msg-guard/<session_id>.names (the directory 0700 and ours, else nothing is
# recorded). The Agent call itself is never denied.
# SendMessage, deny by default (recipient lowercased and trimmed): any value holding ':', '/' or '*', cc-socks or .sock
# (a socket, path or URL form, or a broadcast: to "*", or type "broadcast" with no recipient), and every plain name
# that is not in this session's record. No record, an unreadable one, or no session_id: every plain name is denied.
# Allowed: an agent id, a name this session spawned, no recipient, any other tool, a payload that does not parse, a
# missing jq, a session outside this project's checkouts (same scope as rm-guard-hook.sh: worktrees.path_match, or a
# git origin in github.org), and CM_ALLOW_SENDMESSAGE=1 in the env.
#
# Install: references/prompt-stalls.md (section "The SendMessage guard"). Exit code is always 0;
# the verdict is the JSON.
set -u
input="$(cat 2>/dev/null || true)"
command -v jq >/dev/null 2>&1 || exit 0
tool="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"
case "$tool" in SendMessage|Agent) ;; *) exit 0 ;; esac
sid="$(printf '%s' "$input" | jq -r '.session_id // empty | tostring' 2>/dev/null)"
REC_DIR="${TMPDIR:-/tmp}/cm-msg-guard"
NAME_RE='^[a-z0-9][a-z0-9_-]{0,63}$'
lowtrim() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
# names_file: this session's record path, only for a plain session_id and a record directory that is ours, 0700, no symlink
names_file() {
  case "$sid" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  [ "${#sid}" -le 128 ] && [ -d "$REC_DIR" ] && [ ! -L "$REC_DIR" ] && [ -O "$REC_DIR" ] || return 1
  [ -n "$(find "$REC_DIR" -maxdepth 0 -perm 0700 2>/dev/null)" ] || return 1
  printf '%s/%s.names\n' "$REC_DIR" "$sid"
}
if [ "$tool" = Agent ]; then
  n="$(lowtrim "$(printf '%s' "$input" | jq -r '.tool_input.name // empty | tostring' 2>/dev/null)")"
  if printf '%s' "$n" | grep -qE "$NAME_RE"; then
    (umask 077; mkdir -p "$REC_DIR") 2>/dev/null
    f="$(names_file)" && printf '%s\n' "$n" >> "$f" 2>/dev/null
  fi
  exit 0
fi
[ "${CM_ALLOW_SENDMESSAGE:-0}" = 1 ] && exit 0
to="$(printf '%s' "$input" | jq -r '(.tool_input.to // .tool_input.recipient // .tool_input.target // empty) | tostring' 2>/dev/null)"
if [ -z "$to" ]; then
  # a broadcast carries type "broadcast" and no recipient: it reaches every session
  [ "$(printf '%s' "$input" | jq -r '.tool_input.type // empty' 2>/dev/null)" = broadcast ] && to='*'
fi
# compared lowercased and trimmed: UDS:..., " uds:...", padded names are the same recipient
low="$(lowtrim "$to")"
[ -n "$low" ] || exit 0
case "$low" in
  *[:/*]*|*cc-socks*|*.sock) ;;   # a socket, path or URL form (uds:..., /tmp/x.sock) or a broadcast: never a subagent
  *) printf '%s' "$low" | grep -qE '^(a?[0-9a-f]{8,}|a([a-z0-9_-]{1,63}-)?[0-9a-f]{16})$' && exit 0 ;;   # an agent id (plain or named): the caller's own subagent
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

# Deny by default: a plain name passes only when this session spawned it (it is in the session's record).
spawned() {
  local f
  printf '%s' "$low" | grep -qE "$NAME_RE" || return 1
  f="$(names_file)" && [ -f "$f" ] && [ -r "$f" ] || return 1
  grep -qxF -- "$low" "$f"
}
case "$low" in *[:/*]*|*cc-socks*|*.sock) ;; *) spawned && exit 0 ;; esac

reason="SendMessage to another session ('$to') is not allowed here (owner rule: leads and the concertmaster coordinate ONLY through the fleet CLI). Instead: send text to a lane with 'plugly terminal send --terminal <handle> --text \"<message>\" --enter' (the concertmaster skill's scripts/gsend.sh does the same with checks), and report up with a worktree comment: 'plugly worktree set --worktree active --comment \"cm:<state> <detail>\"'. Never SendMessage and never cc-socks."
jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
