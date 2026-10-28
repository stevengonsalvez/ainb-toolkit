#!/usr/bin/env bash
# shellcheck disable=SC2016  # test commands are single-quoted on purpose: they hold unexpanded variables
# rm-guard-hook.sh test: feeds Bash commands to the hook as Claude Code does and
# asserts deny (unguarded variable under a recursive/force/glob rm) or allow.
#
#   scripts/test/rm-guard-hook.sh         # exit 0 when every case passes
set -uo pipefail
HOOK="$(cd "$(dirname "$0")/../hooks" && pwd)/rm-guard-hook.sh"
fail=0
export CM_CONFIG=/nonexistent CM_PATH_MATCH="/acme-app/" CM_ORG=acme
CWD="${CWD:-/home/user/orca/workspaces/acme-app/lane}"
run() { jq -n --arg c "$1" --arg w "$CWD" '{tool_name:"Bash",cwd:$w,tool_input:{command:$c}}' | "$HOOK"; }
want() { # $1 = deny|allow, $2 = command
  local out; out="$(run "$2")"
  local got=allow; [ -n "$out" ] && got=deny
  if [ "$1" = deny ] && [ -n "$out" ] && [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" != deny ]; then got=malformed; fi
  if [ "$got" = "$1" ]; then echo "ok   $1: $2"; else echo "FAIL want $1 got $got: $2"; fail=1; fi
}
# deny
want deny 'rm -rf $S/x'
want deny 'rm -rf "$S"/x'
want deny 'rm -rf $S/*'
want deny 'cd /tmp && rm -rf "$DIR"'
want deny 'rm -fr $TMP'
want deny 'echo a; rm -r ${S}/y'
want deny 'rm -rf "${S:-}/x"'
want deny 'sudo rm -rf $X'
want deny 'ls | xargs rm -rf $S'
# deny: loop, conditional, group, wrapper, background and xargs-option forms
want deny 'for d in a b; do rm -rf "$d"; done'
want deny 'if true; then rm -rf $S/y; fi'
want deny '{ rm -rf $S/x; }'
want deny '( rm -rf $S/x )'
want deny 'nohup rm -rf $S/x'
want deny 'timeout 5 rm -rf $S/x'
want deny 'sleep 1 & rm -rf $S/x'
want deny 'ls | xargs -n 1 rm -rf $S'
want deny 'nice -n 10 rm -rf $S/x'
want deny 'env FOO=1 rm -rf $S/x'
want deny 'false || rm -rf $S/x'
# allow: separators and rm text inside quotes are prose, not commands
want allow 'gh pr comment 1 --body "fixed; rm -rf $S/x done"'
want allow 'echo "a | rm -rf $S"'
want allow 'git commit -m "x; rm -rf $S"'
want allow 'rm -rf "${S:?}/a" && ls'
want allow 'terraform apply $PLAN'
want allow 'perform $S'
# second review: multi-line quotes, -f alone, absolute/escaped rm, tabs, positional args, continuations
want allow "$(printf "gh pr comment 1 --body 'Root cause:\nrm -rf \$S/x prompted'")"
want allow "$(printf 'git commit -m "first line\nguard it; rm -rf $S/x"')"
want deny  "$(printf "echo 'ok'\nrm -rf \$S/x")"
want allow 'rm -f "$x"'
want allow 'rm -f $S/plain-file'
want deny '/bin/rm -rf $S/x'
want deny '\rm -rf $S/x'
want deny "$(printf 'rm\t-rf\t$S/x')"
want deny 'rm -rf $1/x'
want deny 'rm -rf "$@"'
want deny "$(printf 'echo start \\\n && rm -rf $S/x')"
want deny 'while true; do rm -rf $S/x; done'
want deny 'until false; do rm -rf $S/x; done'
want allow 'cat <<< "rm -rf $S/x"'
want allow 'echo x | xargs echo rm -rf'
# allow
want allow "$(printf 'cat > f <<EOF\nrm -rf $S/x\nEOF')"
want allow "$(printf "cat > f <<'EOF'\nrm -rf \"\$DIR\"\nEOF")"
want deny "$(printf 'cat > f <<EOF\nok\nEOF\nrm -rf $S/x')"
want allow 'rm -rf "${S:?}"/x'
want allow 'rm -rf /tmp/literal/x'
want allow 'rm "$file"'
want allow 'ls $S'
want allow 'git rm -r $X'
want allow 'echo "rm -rf $S"'
want allow 'rm -rf "${S:?scratch unset}"/a "${S:?}"/b'
want allow ''
# scope is case-insensitive and also accepts a path match
[ -n "$(CWD=/home/user/ORCA/Acme-App/x run 'rm -rf $S/x')" ] && echo "ok   scope is case-insensitive" || { echo "FAIL scope case"; fail=1; }
# outside this project's worktrees the hook stays out of the way
[ -z "$(CWD=/home/user/other-project run 'rm -rf $S/x')" ] && echo "ok   other project untouched" || { echo "FAIL other project"; fail=1; }
# a checkout whose git origin is a repo of the configured org is in scope without a path match
GT="$(mktemp -d "${TMPDIR:-/tmp}/cm-rmguard.XXXXXX")" || exit 1
trap 'rm -rf -- "${GT:?}"' EXIT
git -C "$GT" init -q && git -C "$GT" remote add origin https://github.com/acme/other-name.git
[ -n "$(CWD="$GT" run 'rm -rf $S/x')" ] && echo "ok   org origin is in scope" || { echo "FAIL org origin"; fail=1; }
git -C "$GT" remote set-url origin https://github.com/someone-else/x.git
[ -z "$(CWD="$GT" run 'rm -rf $S/x')" ] && echo "ok   foreign origin untouched" || { echo "FAIL foreign origin"; fail=1; }
# a git checkout with NO origin, and a plain non-git directory, both outside the path match, stay out
# of the way (an empty origin URL must not put a directory in scope: the global hook must not change
# other projects)
NG="$(mktemp -d "${TMPDIR:-/tmp}/cm-rmguard-nogit.XXXXXX")" || exit 1
NO="$(mktemp -d "${TMPDIR:-/tmp}/cm-rmguard-noorigin.XXXXXX")" || exit 1
trap 'rm -rf -- "${GT:?}" "${NG:?}" "${NO:?}"' EXIT
git -C "$NO" init -q
if [ -z "$(CWD="$NG" run 'rm -rf $S/x')" ]; then echo "ok   non-git dir outside the path match untouched"; else echo "FAIL non-git dir"; fail=1; fi
if [ -z "$(CWD="$NO" run 'rm -rf $S/x')" ]; then echo "ok   git dir with no origin untouched"; else echo "FAIL no-origin dir"; fail=1; fi
# a malformed payload and a missing command never block
[ -z "$(printf 'not json' | "$HOOK")" ] && echo "ok   garbage input allowed" || { echo "FAIL garbage input"; fail=1; }
# the deny output is valid hook JSON with a reason
out="$(run 'rm -rf $S/x')"
[ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ] && echo "ok   deny JSON shape" || { echo "FAIL deny JSON shape"; fail=1; }
exit $fail
