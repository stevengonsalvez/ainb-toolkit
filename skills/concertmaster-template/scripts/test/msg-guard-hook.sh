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
OKRESP='{"content":[{"type":"text","text":"done"}]}'
spawn() { # $1 = subagent name; $2 = event (PostToolUse); $3 = tool_response JSON: an Agent(name: ...) call that ran
  local out
  out="$(jq -n --arg n "$1" --arg w "$CWD" --arg s "$SID" --arg e "${2:-PostToolUse}" --argjson r "${3:-$OKRESP}" \
    '{hook_event_name:$e,tool_name:"Agent",session_id:$s,cwd:$w,tool_input:{name:$n,prompt:"p"},tool_response:$r}' | "$HOOK")"
  [ -z "$out" ] || { echo "FAIL Agent call produced output: $out"; fail=1; }
}
REC="$TMPDIR/cm-msg-guard/sess-a.names"
rec_has() { [ -f "$REC" ] && grep -qxF -- "$1" "$REC"; }
rec_lines() { if [ -f "$REC" ]; then wc -l < "$REC" | tr -d ' '; else echo 0; fi; }
# ledger workers name sessions: their ids and lanes are never recorded and never pass
printf '{"workers":{"research-cache":{"lane":"ops-db"},"w-dev-1":{"lane":"dev-1"}}}\n' > "$CM_HOME/ledger.json"
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
rec_has reviewer && [ -n "$(find "$TMPDIR/cm-msg-guard" -maxdepth 0 -perm 0700)" ] && [ "$(rec_lines)" = 2 ] && echo "ok   the record holds the two valid names only, in a 0700 directory" || { echo "FAIL record contents or mode"; fail=1; }
# never recorded: a lane-shaped, w-, self-named, ledger or configured name; a PreToolUse Agent call; a spawn that failed;
# a name carrying a newline or a tab (one Agent call must never write two record lines)
for n in dev-sweeper rs-lead-g w-dev-1 w-x concertmaster-2 research-cache ops-db dev-1 dev-1-9c; do spawn "$n"; done
spawn pre-only PreToolUse
spawn failed-one PostToolUse '{"is_error":true,"content":"boom"}'
spawn err-two PostToolUse '{"error":"agent failed"}'
spawn str-fail PostToolUse '"Error: the agent could not be started"'   # a failed call: tool_response is the error text
spawn null-resp PostToolUse 'null'; spawn arr-resp PostToolUse '[]'
spawn async-noid PostToolUse '{"status":"async_launched","description":"d"}'
spawn obj-err PostToolUse '{"status":"async_launched","agentId":"a9","error":"launch failed"}'
spawn fail-event PostToolUseFailure '{"error":"boom","is_interrupt":false}'
spawn empty-obj PostToolUse '{}'
spawn $'reviewer\nuds:x'; spawn $'ok\nw-dev-sweeper'; spawn $'tab\tname'; spawn $'trail\n'
[ "$(rec_lines)" = 2 ] && ! rec_has str-fail && ! rec_has null-resp && ! rec_has arr-resp && ! rec_has async-noid && ! rec_has obj-err && ! rec_has fail-event && ! rec_has empty-obj && ! rec_has dev-sweeper && ! rec_has ok && ! rec_has 'uds:x' && ! rec_has trail && ! rec_has pre-only && ! rec_has failed-one \
  && echo "ok   lane, ledger, self, PreToolUse, failed and control-character names are never recorded" || { echo "FAIL record took a refused name: $(tr '\n' ' ' < "$REC")"; fail=1; }
for n in dev-sweeper w-dev-1 research-cache ops-db concertmaster-2 ok pre-only failed-one trail str-fail async-noid obj-err; do want deny SendMessage "$n"; done
# a background launch (PostToolUse at launch: status async_launched with an agentId) records, under Agent or legacy Task
spawn bg-worker PostToolUse '{"status":"async_launched","agentId":"a1b2","description":"d","prompt":"p","outputFile":"/tmp/o","resolvedModel":"m"}'
want allow SendMessage 'bg-worker'
spawn_task() { jq -n --arg n "$1" --arg w "$CWD" --arg s "$SID" --argjson r "$OKRESP" '{hook_event_name:"PostToolUse",tool_name:"Task",session_id:$s,cwd:$w,tool_input:{name:$n,prompt:"p"},tool_response:$r}' | "$HOOK" >/dev/null; }
spawn_task legacy-task
want allow SendMessage 'legacy-task'
# a recipient with a control character is denied even when its first line is a recorded name
want deny SendMessage $'reviewer\nuds:x'
want deny SendMessage $'reviewer\n'
want deny SendMessage $'revi\tewer'
want deny SendMessage $'reviewer\r'
# a record line that was written by hand but is lane-shaped still does not pass: the denylist runs at check time too
printf 'dev-sweeper\n' >> "$REC"; want deny SendMessage 'dev-sweeper'
# a ledger that exists but does not parse: no plain name passes, a recorded one neither
cp "$CM_HOME/ledger.json" "$CM_HOME/ledger.keep"; printf '{not json' > "$CM_HOME/ledger.json"
want deny SendMessage 'reviewer'
mv "$CM_HOME/ledger.keep" "$CM_HOME/ledger.json"
want allow SendMessage 'reviewer'
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
