#!/usr/bin/env bash
# msg-guard-hook.sh: Claude Code hook (PreToolUse matcher SendMessage, PostToolUse matcher Agent) that enforces the
# owner rule "leads and the concertmaster coordinate ONLY through the fleet CLI".
#
# Why: SendMessage to another session (a named peer, or a cc-socks unix socket) bypasses the
# fleet CLI, the worktree comment and the ledger, so nothing records it and a resumed or
# rebooted session loses it. A denial with the fix costs the agent one turn.
#
# PostToolUse Agent (a spawn that ran: tool_response present, no error): tool_input.name, lowercased and trimmed, is
# appended to this session's record, ${TMPDIR:-/tmp}/cm-msg-guard/<session_id>.names (the directory 0700 and ours),
# only when it is a plain name: no control character, the whole string ^[a-z0-9][a-z0-9_-]{0,63}$, and not a session
# name (lane-shaped, w-<anything>, the concertmaster's own name, a configured lane, a ledger worker id or lane). An
# Agent call is never denied, and PreToolUse Agent records nothing.
# PreToolUse SendMessage, deny by default (recipient lowercased and trimmed): a control character, any value holding
# ':', '/' or '*', cc-socks or .sock (a socket, path or URL form, or a broadcast: to "*", or type "broadcast" with no
# recipient), and every plain name that is not a plain name (same test) or not in this session's record (read line by
# line, exact). No record, an unreadable one, no session_id or an unparsable ledger: every plain name is denied.
# Allowed: an agent id, a recorded name, no recipient, any other tool, a payload that does not parse, a missing jq, a
# session outside this project's checkouts (same scope as rm-guard-hook.sh: worktrees.path_match, or a git origin in
# github.org), and CM_ALLOW_SENDMESSAGE=1 in the env.
#
# Install: references/prompt-stalls.md (section "The SendMessage guard"). Exit code is always 0;
# the verdict is the JSON.
set -u
input="$(cat 2>/dev/null || true)"
command -v jq >/dev/null 2>&1 || exit 0
# jfield <jq filter>: sets JV to the exact string (jq -j, then a sentinel, no $(...) around the result), so a trailing
# newline is kept and caught below
jfield() { JV="$(printf '%s' "$input" | jq -j "($1) // \"\" | tostring" 2>/dev/null; printf x)"; JV="${JV%x}"; }
jfield .tool_name; tool="$JV"; jfield .hook_event_name; event="$JV"
case "$tool" in SendMessage|Agent) ;; *) exit 0 ;; esac
jfield .session_id; sid="$JV"
REC_DIR="${TMPDIR:-/tmp}/cm-msg-guard"
NAME_RE='^[a-z0-9][a-z0-9_-]{0,63}$'
AGENT_ID_RE='^(a?[0-9a-f]{8,}|a([a-z0-9_-]{1,63}-)?[0-9a-f]{16})$'
lowtrim() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/^ *//; s/ *$//'; }
# names_file: this session's record path, only for a plain session_id and a record directory that is ours, 0700, no symlink
names_file() {
  case "$sid" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  [ "${#sid}" -le 128 ] && [ -d "$REC_DIR" ] && [ ! -L "$REC_DIR" ] && [ -O "$REC_DIR" ] || return 1
  [ -n "$(find "$REC_DIR" -maxdepth 0 -perm 0700 2>/dev/null)" ] || return 1
  printf '%s/%s.names\n' "$REC_DIR" "$sid"
}
load_lib() {
  local here c
  here="$(cd "$(dirname "$0")" && pwd)"
  for c in "$here/lib.sh" "$here/../lib.sh" "$HOME/.concertmaster/bin/lib.sh"; do
    # shellcheck source=SCRIPTDIR/../lib.sh
    if [ -r "$c" ]; then . "$c" 2>/dev/null; return; fi
  done
  return 1
}
# plain_name <lowercased name>: the subagent shape and none of the session names: not lane-shaped (lib.sh
# CM_LANE_SHAPE_RE), not w-<anything>, not holding the concertmaster's own name, not a configured lane, ledger worker
# id or ledger lane (alone or with a -<suffix>). A ledger that exists but does not parse fails; a missing one adds no
# names. Used both when a name is recorded and when SendMessage is checked.
plain_name() {
  local v="$1" self ids led n
  case "$v" in *[[:cntrl:]]*) return 1 ;; esac
  [[ $v =~ $NAME_RE ]] || return 1
  [[ $v =~ $CM_LANE_SHAPE_RE ]] && return 1
  case "$v" in w-*) return 1 ;; esac
  self="$(cm_lower "${CM_SELF_WORKTREE:-concertmaster}")"
  [ -n "$self" ] && [ "${v#*"$self"}" != "$v" ] && return 1
  led="$(cm_ledger_path)"; ids=""
  if [ -e "$led" ]; then ids="$(jq -r '(.workers // {}) | to_entries[] | .key, (.value.lane // empty) | strings' "$led")" || return 1; fi
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    case "$v" in "$n"|"$n"-*) return 1 ;; esac
  done <<NAMES
$(cm_lane_names)
$(printf '%s\n' "$ids" | tr '[:upper:]' '[:lower:]')
NAMES
  return 0
}

# Agent: record the name only after a spawn that ran (PostToolUse with a tool_response and no error), never on
# PreToolUse, where a later hook or the user can still refuse the call.
if [ "$tool" = Agent ]; then
  [ "$event" = PostToolUse ] || exit 0
  printf '%s' "$input" | jq -e '(.tool_response // null) as $r | $r != null
      and (($r | type) != "object" or (($r.is_error // false) != true and ($r.error // null) == null))' >/dev/null 2>&1 || exit 0
  jfield .tool_input.name; n="$JV"
  case "$n" in *[[:cntrl:]]*) exit 0 ;; esac
  n="$(lowtrim "$n")"
  load_lib || exit 0
  plain_name "$n" || exit 0
  (umask 077; mkdir -p "$REC_DIR") 2>/dev/null
  f="$(names_file)" && printf '%s\n' "$n" >> "$f" 2>/dev/null
  exit 0
fi
[ "$event" = "" ] || [ "$event" = PreToolUse ] || exit 0
[ "${CM_ALLOW_SENDMESSAGE:-0}" = 1 ] && exit 0
jfield '.tool_input.to // .tool_input.recipient // .tool_input.target'; to="$JV"
if [ -z "$to" ]; then
  # a broadcast carries type "broadcast" and no recipient: it reaches every session
  jfield .tool_input.type; [ "$JV" = broadcast ] && to='*'
fi
[ -n "$to" ] || exit 0
# compared lowercased and trimmed: UDS:..., " uds:...", padded names are the same recipient; a control character
# (newline, tab, ...) is never a subagent name
case "$to" in *[[:cntrl:]]*) low='*' ;; *) low="$(lowtrim "$to")" ;; esac
[ -n "$low" ] || exit 0
case "$low" in
  *[:/*]*|*cc-socks*|*.sock) ;;   # a socket, path or URL form (uds:..., /tmp/x.sock) or a broadcast: never a subagent
  *) [[ $low =~ $AGENT_ID_RE ]] && exit 0 ;;   # an agent id (plain or named): the caller's own subagent
esac

# Scope: this project's checkouts only (a global hook must not change other projects).
load_lib || exit 0
jfield .cwd; cwd="$JV"
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

# Deny by default: a plain name passes only when it is still a plain name (the same denylist as at record time) and
# this session's record holds it, compared line by line, exactly.
spawned() {
  local f line
  plain_name "$low" || return 1
  f="$(names_file)" && [ -f "$f" ] && [ -r "$f" ] || return 1
  while IFS= read -r line; do [ "$line" = "$low" ] && return 0; done < "$f"
  return 1
}
case "$low" in *[:/*]*|*cc-socks*|*.sock) ;; *) spawned && exit 0 ;; esac

reason="SendMessage to another session ('$to') is not allowed here (owner rule: leads and the concertmaster coordinate ONLY through the fleet CLI). Instead: send text to a lane with 'plugly terminal send --terminal <handle> --text \"<message>\" --enter' (the concertmaster skill's scripts/gsend.sh does the same with checks), and report up with a worktree comment: 'plugly worktree set --worktree active --comment \"cm:<state> <detail>\"'. Never SendMessage and never cc-socks."
jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
