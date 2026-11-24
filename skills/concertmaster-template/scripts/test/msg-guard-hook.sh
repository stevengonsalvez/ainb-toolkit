#!/usr/bin/env bash
# shellcheck disable=SC2015  # "A && ok || bad": ok never fails
# msg-guard-hook.sh test: feeds tool calls to the hook as Claude Code does and asserts deny
# (SendMessage to a named session, a cc-socks socket or a broadcast) or allow.
#
#   scripts/test/msg-guard-hook.sh        # exit 0 when every case passes
set -uo pipefail
HOOK="$(cd "$(dirname "$0")/../hooks" && pwd)/msg-guard-hook.sh"
fail=0
export CM_CONFIG=/nonexistent CM_PATH_MATCH="/acme-app/" CM_ORG=acme
unset CM_ALLOW_SENDMESSAGE CM_LEDGER CM_SELF_WORKTREE
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-msgguard.XXXXXX")" || exit 1
trap 'rm -rf -- "${ROOT:?}"' EXIT
# the per-session record of spawned subagent names lives under TMPDIR: a private one per run
export CM_HOME="$ROOT/home" TMPDIR="$ROOT/tmp"; mkdir -p "$CM_HOME" "$TMPDIR"
CWD="${CWD:-/home/user/orca/workspaces/acme-app/lane}"
SID=sess-a
run() { # $1 = tool, $2 = to, $3 = cwd
  jq -n --arg t "$1" --arg to "$2" --arg w "${3:-$CWD}" --arg s "$SID" '{tool_name:$t,session_id:$s,cwd:$w,tool_input:{to:$to,message:"hi"}}' | "$HOOK"
}
spawn() { # $1 = subagent name, as Claude Code sends PreToolUse for Agent(name: ...); the Agent call is never denied
  local out
  out="$(jq -n --arg n "$1" --arg w "$CWD" --arg s "$SID" '{tool_name:"Agent",session_id:$s,cwd:$w,tool_input:{name:$n,prompt:"p"}}' | "$HOOK")"
  [ -z "$out" ] || { echo "FAIL Agent call produced output: $out"; fail=1; }
}
want() { # $1 = deny|allow, $2 = tool, $3 = to, $4 = cwd (optional)
  local out got=allow
  out="$(run "$2" "$3" "${4:-}")"
  [ -n "$out" ] && got=deny
  if [ "$1" = deny ] && [ -n "$out" ] && [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" != deny ]; then got=malformed; fi
  if [ "$got" = "$1" ]; then echo "ok   $1 ($SID): $2 -> $3"; else echo "FAIL want $1 got $got ($SID): $2 -> $3"; fail=1; fi
}
# deny: named sessions, sockets, broadcast
want deny SendMessage 'rs-lead-g-4f'
want deny SendMessage 'sporthead-concertmaster-ec'
want deny SendMessage 'concertmaster-5b'
want deny SendMessage 'uds:/run/user/1000/cc-socks/20484.sock'
want deny SendMessage '/run/user/1000/cc-socks/20484.sock'
want deny SendMessage '*'
# allow: the caller's own subagent by agent id
want allow SendMessage 'af1bdeb37428c11e6'
want allow SendMessage 'a28db5b89b29c8c21'
want allow SendMessage '3f2a9c10b7e4'
want allow SendMessage 'acode-reviewer-0123456789abcdef'
want deny SendMessage 'a-lead-concertmaster'
# no record yet (nothing spawned): every plain name is denied, a lane-shaped one too
want deny SendMessage 'reviewer'
want deny SendMessage 'research-cache'
want deny SendMessage 'fix-login-482'
want deny SendMessage 'dev-sweeper'
want deny SendMessage 'w-dev-sweeper'
# a name this session spawned is allowed (any case or padding); one it did not spawn stays denied
spawn reviewer; spawn ' Test-Engineer '; spawn 'host:bad'; spawn 'two words'
want allow SendMessage 'reviewer'
want allow SendMessage ' Reviewer '
want allow SendMessage 'test-engineer'
want deny SendMessage 'research-cache'
want deny SendMessage 'host:bad'
want deny SendMessage 'two words'
check_rec() { grep -qxF "$1" "$TMPDIR/cm-msg-guard/sess-a.names" && [ -n "$(find "$TMPDIR/cm-msg-guard" -maxdepth 0 -perm 0700)" ]; }
check_rec reviewer && ! grep -q 'host:bad\|two words' "$TMPDIR/cm-msg-guard/sess-a.names" && echo "ok   the record holds valid names only, in a 0700 directory" || { echo "FAIL record contents or mode"; fail=1; }
# another session's spawned name is not this session's subagent
SID=sess-b
want deny SendMessage 'reviewer'
SID=sess-a
# an unreadable record, a record directory that is not 0700, or no session_id: denied
chmod 000 "$TMPDIR/cm-msg-guard/sess-a.names"
if [ "$(id -u)" != 0 ]; then want deny SendMessage 'reviewer'; fi
chmod 600 "$TMPDIR/cm-msg-guard/sess-a.names"
chmod 755 "$TMPDIR/cm-msg-guard"; want deny SendMessage 'reviewer'; chmod 700 "$TMPDIR/cm-msg-guard"
SID=''; want deny SendMessage 'reviewer'; SID=sess-a
SID='../sess-a'; want deny SendMessage 'reviewer'; SID=sess-a
rm -rf -- "${TMPDIR:?}/cm-msg-guard"; want deny SendMessage 'reviewer'
# deny: socket, path and URL forms whatever the case or padding
want deny SendMessage 'UDS:/run/user/1000/cc-socks/1.sock'
want deny SendMessage ' uds:/run/user/1000/x'
want deny SendMessage '/tmp/x.sock'
want deny SendMessage 'peer.sock'
want deny SendMessage 'team/reviewer'
want deny SendMessage 'https://example.test/session'
# allow: other tools, no recipient, a session outside the project
want allow Bash 'rs-lead-g-4f'
want allow SendMessage 'rs-lead-g-4f' /home/user/other-project
[ -z "$(jq -n --arg w "$CWD" '{tool_name:"SendMessage",cwd:$w,tool_input:{message:"hi"}}' | "$HOOK")" ] && echo "ok   allow: no recipient" || { echo "FAIL no recipient"; fail=1; }
# a broadcast payload has type "broadcast" and no recipient: denied in scope, allowed outside
bc() { jq -n --arg w "$1" '{tool_name:"SendMessage",cwd:$w,tool_input:{type:"broadcast",message:"hi"}}' | "$HOOK"; }
[ "$(bc "$CWD" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = deny ] && echo "ok   deny: type broadcast, no recipient" || { echo "FAIL broadcast type"; fail=1; }
[ -z "$(bc /home/user/other-project)" ] && echo "ok   allow: broadcast outside the project" || { echo "FAIL broadcast outside"; fail=1; }
# the env escape hatch
[ -z "$(CM_ALLOW_SENDMESSAGE=1 bash -c 'jq -n --arg w "$1" "{tool_name:\"SendMessage\",cwd:\$w,tool_input:{to:\"rs-lead-g-4f\"}}" | "$2"' _ "$CWD" "$HOOK")" ] && echo "ok   allow: CM_ALLOW_SENDMESSAGE=1" || { echo "FAIL env escape"; fail=1; }
# a malformed payload never blocks
[ -z "$(printf 'not json' | "$HOOK")" ] && echo "ok   garbage input allowed" || { echo "FAIL garbage input"; fail=1; }
# the deny output is valid hook JSON naming the fleet CLI
out="$(run SendMessage 'rs-lead-g-4f')"
[ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ] && printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q 'plugly terminal send' && echo "ok   deny JSON shape and fix hint" || { echo "FAIL deny JSON shape"; fail=1; }
exit $fail
