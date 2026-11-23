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
unset CM_ALLOW_SENDMESSAGE
CWD="${CWD:-/home/user/orca/workspaces/acme-app/lane}"
run() { # $1 = tool, $2 = to, $3 = cwd
  jq -n --arg t "$1" --arg to "$2" --arg w "${3:-$CWD}" '{tool_name:$t,cwd:$w,tool_input:{to:$to,message:"hi"}}' | "$HOOK"
}
want() { # $1 = deny|allow, $2 = tool, $3 = to, $4 = cwd (optional)
  local out got=allow
  out="$(run "$2" "$3" "${4:-}")"
  [ -n "$out" ] && got=deny
  if [ "$1" = deny ] && [ -n "$out" ] && [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" != deny ]; then got=malformed; fi
  if [ "$got" = "$1" ]; then echo "ok   $1: $2 -> $3"; else echo "FAIL want $1 got $got: $2 -> $3"; fail=1; fi
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
# allow: other tools, no recipient, a session outside the project
want allow Bash 'rs-lead-g-4f'
want allow SendMessage 'rs-lead-g-4f' /home/user/other-project
[ -z "$(jq -n --arg w "$CWD" '{tool_name:"SendMessage",cwd:$w,tool_input:{message:"hi"}}' | "$HOOK")" ] && echo "ok   allow: no recipient" || { echo "FAIL no recipient"; fail=1; }
# the env escape hatch
[ -z "$(CM_ALLOW_SENDMESSAGE=1 bash -c 'jq -n --arg w "$1" "{tool_name:\"SendMessage\",cwd:\$w,tool_input:{to:\"rs-lead-g-4f\"}}" | "$2"' _ "$CWD" "$HOOK")" ] && echo "ok   allow: CM_ALLOW_SENDMESSAGE=1" || { echo "FAIL env escape"; fail=1; }
# a malformed payload never blocks
[ -z "$(printf 'not json' | "$HOOK")" ] && echo "ok   garbage input allowed" || { echo "FAIL garbage input"; fail=1; }
# the deny output is valid hook JSON naming the fleet CLI
out="$(run SendMessage 'rs-lead-g-4f')"
[ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ] && printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q 'plugly terminal send' && echo "ok   deny JSON shape and fix hint" || { echo "FAIL deny JSON shape"; fail=1; }
exit $fail
