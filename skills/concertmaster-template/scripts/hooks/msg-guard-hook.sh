#!/usr/bin/env bash
# msg-guard-hook.sh: Claude Code PreToolUse hook (matcher: SendMessage) that enforces the owner
# rule "leads and the concertmaster coordinate ONLY through the fleet CLI".
#
# Why: SendMessage to another session (a named peer, or a cc-socks unix socket) bypasses the
# fleet CLI, the worktree comment and the ledger, so nothing records it and a resumed or
# rebooted session loses it. A denial with the fix costs the agent one turn.
#
# Deny by default (recipient lowercased and trimmed): any value holding ':', '/' or '*', cc-socks or .sock (a socket,
# path or URL form, or a broadcast: to "*", or type "broadcast" with no recipient), and every plain name that is not a
# subagent name. A subagent name (one this session spawned with Agent(name: "reviewer")) matches ^[a-z0-9][a-z0-9_-]*$,
# is not lane-shaped (lib.sh CM_LANE_SHAPE_RE), not w-<anything>, does not hold the concertmaster's own name
# (worktrees.self_name), and is not a configured lane, ledger worker id or ledger lane, alone or with a -<suffix>; a
# ledger that exists but does not parse allows no name. Allowed: an agent id, a subagent name, no recipient, any other
# tool, a payload that does not parse, a missing jq, a session outside this project's checkouts (same scope as
# rm-guard-hook.sh: worktrees.path_match, or a git origin in github.org), and CM_ALLOW_SENDMESSAGE=1 in the env.
#
# Install: references/prompt-stalls.md (section "The SendMessage guard"). Exit code is always 0;
# the verdict is the JSON.
set -u
input="$(cat 2>/dev/null || true)"
command -v jq >/dev/null 2>&1 || exit 0
[ "$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)" = SendMessage ] || exit 0
[ "${CM_ALLOW_SENDMESSAGE:-0}" = 1 ] && exit 0
to="$(printf '%s' "$input" | jq -r '(.tool_input.to // .tool_input.recipient // .tool_input.target // empty) | tostring' 2>/dev/null)"
if [ -z "$to" ]; then
  # a broadcast carries type "broadcast" and no recipient: it reaches every session
  [ "$(printf '%s' "$input" | jq -r '.tool_input.type // empty' 2>/dev/null)" = broadcast ] && to='*'
fi
# compared lowercased and trimmed: UDS:..., " uds:...", padded names are the same recipient
low="$(printf '%s' "$to" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
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

# Deny by default. A plain name is allowed only as a subagent name: the strict shape, not lane-shaped, not w-<id>, not
# holding the concertmaster's own name, and not a configured lane, ledger worker id or ledger lane (alone or with a
# -<suffix>). A ledger that exists but cannot be parsed denies; a missing ledger file means no worker ids yet.
subagent_name() {
  local self ids n led
  printf '%s' "$low" | grep -qE '^[a-z0-9][a-z0-9_-]*$' || return 1
  printf '%s' "$low" | grep -qE -- "$CM_LANE_SHAPE_RE|^w-" && return 1
  self="$(cm_lower "${CM_SELF_WORKTREE:-concertmaster}")"
  [ -n "$self" ] && [ "${low#*"$self"}" != "$low" ] && return 1
  led="$(cm_ledger_path)"; ids=""
  if [ -e "$led" ]; then
    ids="$(jq -r '(.workers // {}) | to_entries[] | .key, (.value.lane // empty) | strings' "$led")" || return 1
  fi
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    case "$low" in "$n"|"$n"-*) return 1 ;; esac
  done <<NAMES
$(cm_lane_names)
$(printf '%s\n' "$ids" | tr '[:upper:]' '[:lower:]')
NAMES
  return 0
}
case "$low" in *[:/*]*|*cc-socks*|*.sock) ;; *) subagent_name && exit 0 ;; esac

reason="SendMessage to another session ('$to') is not allowed here (owner rule: leads and the concertmaster coordinate ONLY through the fleet CLI). Instead: send text to a lane with 'plugly terminal send --terminal <handle> --text \"<message>\" --enter' (the concertmaster skill's scripts/gsend.sh does the same with checks), and report up with a worktree comment: 'plugly worktree set --worktree active --comment \"cm:<state> <detail>\"'. Never SendMessage and never cc-socks."
jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
