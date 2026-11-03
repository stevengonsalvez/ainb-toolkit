#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# shellcheck disable=SC2016,SC2015  # test commands are single-quoted on purpose (unexpanded variables); "A && ok || bad": ok never fails
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
# deny: raw orca worktree removal (the teardown gates live in scripts/teardown.sh)
want deny 'orca worktree rm --worktree id:abc --json'
want deny 'orca worktree remove --worktree id:abc'
want deny 'orca worktree rm --force --worktree id:abc'
want deny 'orca worktree rm --worktree path:/home/user/orca/workspaces/acme-app/x --force'
want deny 'git status && orca worktree rm --worktree id:abc'
want deny 'ls | orca worktree rm --worktree id:abc'
want deny 'cd /tmp; orca worktree remove --worktree id:abc'
want deny 'for w in a b; do orca worktree rm --worktree id:$w; done'
want deny 'orca --json worktree rm --worktree id:abc'
want deny 'ssh -o BatchMode=yes host-a orca worktree rm --worktree id:abc'
want deny 'ssh -i /k/id_ed25519 -p 2222 host-a orca-ide worktree remove --worktree id:abc'
want deny 'ssh -o ConnectTimeout=5 -o BatchMode=yes host-a "orca worktree rm --worktree id:abc"'
want deny 'ssh -t host-a orca worktree rm --worktree id:abc'
want deny "ssh host-a 'if true; then orca worktree rm --worktree id:abc; fi'"
want deny "bash -c 'for w in a b; do orca-ide worktree remove --worktree id:\$w; done'"
want deny "bash -c 'if ! orca worktree rm --worktree id:abc; then echo no; fi'"
want allow "ssh host-a 'if true; then orca worktree list --json; fi'"
# separators inside a quoted argument of a nested command are not boundaries
want allow "bash -c 'echo \"done; orca worktree rm now\"'"
want allow "ssh host-a 'echo \"see; orca worktree rm --worktree id:abc\"'"
want allow "ssh host-a 'orca worktree set --worktree active --comment \"done; orca worktree rm later\"'"
want deny "bash -c 'echo hi; orca worktree rm --worktree id:abc'"
want deny "ssh host-a 'echo \"x\"; orca worktree rm --worktree id:abc'"
want deny "bash -c \"echo \\\"x\\\" && orca worktree rm --worktree id:abc\""
want deny "ssh host-a 'echo \$(orca worktree rm --worktree id:abc)'"
# flags between worktree and the subcommand
want deny 'orca worktree --json rm --worktree id:abc --force'
want deny 'orca-ide worktree --environment host-a remove --worktree id:abc'
want deny "ssh host-a 'orca worktree --json rm --worktree id:abc'"
want allow 'orca worktree --json list'
want deny "bash -ce 'orca worktree rm --worktree id:abc'"
want deny "bash -ceu 'orca-ide worktree rm --worktree id:abc'"
want deny "2>/dev/null orca worktree rm --worktree id:abc"
want deny "orca worktree 2>/dev/null rm --worktree id:abc"
want deny "2>&1 orca worktree rm --worktree id:abc"
want deny "orca worktree 2>&1 rm --worktree id:abc"
want deny "cat <(orca worktree rm --worktree id:abc)"
want deny "find . -exec bash -c 'orca worktree rm --worktree id:abc' \\;"
want allow "find . -exec bash -c 'orca worktree list' \\;"
want deny "find . -type d -name stale -exec echo {} \; -exec orca worktree rm --worktree id:abc \;"
want deny "find . -exec echo {} \; -exec bash -c 'orca-ide worktree rm --worktree id:abc' \;"
want allow "find . -exec echo {} \; -exec ls {} \;"
# heredoc detector: a "<<" only opens a body as a real operator (round 2)
want deny $'x=$((1<<n))\norca worktree rm --worktree id:abc'
want deny $'grep -n "<<EOF" f\norca worktree rm --worktree id:abc'
want deny $'grep -n \'<<EOF\' f\norca worktree rm --worktree id:abc'
want deny $'echo "<<EOF"\norca worktree rm --worktree id:abc'
want deny $'ls #<<EOF\norca worktree rm --worktree id:abc'
want deny $'(( y = 1<<3 ))\norca worktree rm --worktree id:abc'
want deny $'echo $[1<<2]\norca worktree rm --worktree id:abc'
want deny $'echo "$(cat <<EOF\nhi\nEOF\n)"\norca worktree rm --worktree id:abc'
want deny $'cat <<A <<B\nx\nA\nB\norca worktree rm --worktree id:abc'
want allow $'git commit -m "$(cat <<\'EOF\'\nnote: orca worktree rm is forbidden\nEOF\n)"'
want allow $'cat <<-\'EOF\'\n\torca worktree rm --worktree id:abc\n\tEOF'
want deny $'# worker\'s cleanup\norca worktree remove --worktree id:abc'
want deny $'ls # don\'t\norca worktree rm --worktree id:abc'
want deny $'cat <<\'END-DOC\'\nx\nEND-DOC\norca worktree rm --worktree id:abc'
want deny $'cat <<END.DOC\nx\nEND.DOC\norca worktree rm --worktree id:abc'
want allow $'cat <<\'END-DOC\'\norca worktree rm --worktree id:abc\nEND-DOC'
want allow 'echo hi # orca worktree rm --worktree id:abc'
want allow $'# orca worktree rm --worktree id:abc\nls'
want allow 'echo "${#x} $# a#b"; orca worktree list'
# round 3: a comment inside a quoted multi-line payload, ${ }, backticks, odd tags, more wrappers
want deny "ssh host-a '"$'\n'"# clean up"$'\n'"orca worktree rm --worktree id:abc"$'\n'"'"
want deny "bash -c 'ls #c"$'\n'"orca worktree rm --worktree id:abc'"
want deny "ssh h \"cd /x # go"$'\n'"orca worktree rm --worktree id:abc\""
want deny $'echo ${x#<<EOF}\norca worktree rm --worktree id:abc'
want deny $'x=`cat <<EOF`\norca worktree rm --worktree id:abc'
want deny $'cat <<E\\OF\nx\nEOF\norca worktree rm --worktree id:abc'
want allow $'cat <<E\\OF\norca worktree rm --worktree id:abc\nEOF'
want deny $'cat <<EOF\n$(\norca worktree rm --worktree id:abc\n)\nEOF'
want deny "\"bash\" -c \"orca worktree rm --worktree id:abc\""
want deny "'ssh' host-a 'orca worktree rm --worktree id:abc'"
want allow $'cat <<EOF\nhello\nEOF\nls'
want deny 'orca worktree>/dev/null rm --worktree id:abc'
want deny 'orca worktree 2>/dev/null rm --worktree id:abc'
want deny "bash -c \"orca\"\" worktree rm --worktree id:abc\""
want deny "bash -c 'orca'' worktree rm --worktree id:abc'"
want allow "bash -c 'orca worktree list' orca worktree rm"
# round 4: a redirection next to ; or a newline inside a payload keeps the boundary
want deny "ssh host-a 'cd /x >/dev/null; orca worktree rm --worktree id:abc'"
want deny "bash -c 'echo start >&2; orca worktree rm --worktree id:abc'"
want deny "eval 'ls >/dev/null; orca worktree rm --worktree id:abc'"
want deny "ssh host-a \"tee /tmp/log </dev/null; orca worktree rm --worktree id:abc\""
want deny "ssh host-a 'cd /x > /dev/null; orca worktree rm --worktree id:abc'"
want deny "ssh host-a 'set -e"$'\n'"orca worktree list >/tmp/l"$'\n'"orca worktree rm --worktree id:abc'"
want deny "ssh h '# cat <EOF"$'\n'"orca worktree rm --worktree id:abc'"
want deny 'orca worktree &>/dev/null rm --worktree id:abc'
want deny $'ls # a \\\norca worktree rm --worktree id:abc'
want allow $'ls \\\n-l'
want deny $'cat <<\'E\'OF\nx\nEOF\norca worktree rm --worktree id:abc'
want deny $'cat <<"EOF"x\nx\nEOFx\norca worktree rm --worktree id:abc'
want deny $'cat <<$\'EOF\'\nx\nEOF\norca worktree rm --worktree id:abc'
# round 5: a heredoc tag with whitespace closes in bash on the line that carries the same whitespace
want deny $'cat <<"EOF "\nx\nEOF \norca worktree rm --worktree id:abc'
want deny $'cat <<\'EOF\t\'\nx\nEOF\t\norca worktree rm --worktree id:abc'
want deny $'cat <<\\ EOF\nx\n EOF\norca worktree rm --worktree id:abc'
want deny $'cat <<EOF\\ \nx\nEOF \norca worktree rm --worktree id:abc'
want allow $'cat <<"EOF "\norca worktree rm --worktree id:abc\nEOF \necho done'
# round 5: an escaped backslash before a newline is not a join: the next line runs
want deny $'echo a\\\\\norca worktree rm --worktree id:abc'
want deny $'echo a\\\\\\\\\norca worktree rm --worktree id:abc'
want deny $'echo "a\\\\\norca worktree rm --worktree id:abc"; orca worktree rm --worktree id:abc'
want allow $'echo a\\\norca worktree list'
want deny 'echo $(echo $(echo $(echo $(orca worktree rm --worktree id:abc))))'
want deny 'exec -a name orca worktree rm --worktree id:abc'
want deny 'sudo --user x orca worktree rm --worktree id:abc'
want deny 'taskset -c 0 orca worktree rm --worktree id:abc'
want deny "echo x$(printf '\002')#; orca worktree rm --worktree id:abc"
want allow "ssh host-a 'cd /x >/dev/null; orca worktree list'"
want deny 'sudo -iu user-a orca worktree rm --worktree id:abc'
want deny 'doas -u user-a orca worktree rm --worktree id:abc'
want deny 'chrt -f 10 orca worktree rm --worktree id:abc'
want deny 'ionice -c 3 orca worktree rm --worktree id:abc'
want deny 'flock -n /tmp/l orca worktree rm --worktree id:abc'
want deny '/usr/bin/env FOO=1 orca worktree rm --worktree id:abc'
want allow 'sudo -iu user-a orca worktree list'
# here-strings fed to a shell are scripts (round 2)
want deny 'bash <<< "orca worktree rm --worktree id:abc"'
want deny "bash <<< 'orca worktree rm --worktree id:abc'"
want deny "bash -s <<< 'orca worktree rm --worktree id:abc'"
want deny "ssh host-a bash -s <<< 'orca worktree rm --worktree id:abc'"
want deny "/bin/bash<<<'orca-ide worktree rm --worktree id:abc'"
want allow "bash <<< 'orca worktree list'"
want allow "grep -c x <<< 'orca worktree rm --worktree id:abc'"
# more spellings (round 2)
want deny 'or\ca worktree rm --worktree id:abc'
want deny 'orca worktree r\m --worktree id:abc'
want deny "dash -c 'orca worktree rm --worktree id:abc'"
want deny "ksh -c 'orca worktree rm --worktree id:abc'"
want deny "setsid orca worktree rm --worktree id:abc"
want deny "stdbuf -oL orca worktree rm --worktree id:abc"
want deny "watch -n 5 orca worktree rm --worktree id:abc"
want deny '$(command -v orca) worktree rm --worktree id:abc'
want deny '${CLI:-orca} worktree rm --worktree id:abc'
want deny 'cm_orca worktree rm --worktree id:abc'
want deny "/usr/bin/rm$(printf '\t')-rf \"\$DIR\""
want deny "/bin/rm$(printf '\t')-rf \$DIR"
want deny "bash -c \$'orca worktree rm --worktree id:abc'"
want deny "eval \$'orca worktree rm --worktree id:abc'"
want deny "ssh host-a \$'orca worktree rm --worktree id:abc'"
want deny "cat <<EOF
'\$(orca worktree rm --worktree id:abc)'
EOF"
want deny "result=\"\$(printf ')'; orca worktree rm --worktree id:abc)\""
want deny "bash<<'EOF'
orca worktree rm --worktree id:abc
EOF"
want allow "result=\"\$(printf ')'; orca worktree list)\""
want deny "tee >(orca-ide worktree rm --worktree id:abc) </dev/null"
want deny "diff <(ls) <(ssh host-a 'orca worktree rm --worktree id:abc')"
want allow "diff <(ls) <(orca worktree list --json)"
want allow "echo '<(orca worktree rm --worktree id:abc)'"
want deny "/bin/bash <<EOF
orca worktree rm --worktree id:abc
EOF"
want deny "/usr/bin/env bash <<EOF
orca worktree rm --worktree id:abc
EOF"
want deny "orca worktree rm --worktree id:abc >&2"
want deny "orca worktree rm --worktree id:abc &>/dev/null"
want allow "cat <<'EOF' # bash script
rm -rf \"\$DIR\"
EOF"
want deny "cmd 2>&1 | orca worktree rm --worktree id:abc"
want deny "ssh host-a '2>/dev/null orca worktree rm --worktree id:abc'"
want deny "cat <<EOF
\$(orca worktree rm --worktree id:abc)
EOF"
want allow "cat <<'EOF'
\$(orca worktree rm --worktree id:abc)
EOF"
want allow "cat <<EOF
orca worktree rm is how you remove one
EOF"
want allow "orca worktree list 2>/dev/null"
want deny "ssh host-a \"bash -ce 'orca worktree rm --worktree id:abc'\""
want deny "bash -o pipefail -c 'orca worktree rm --worktree id:abc'"
want deny 'ssh host "cd /w && orca worktree rm --worktree id:abc" 2>/dev/null'
want deny "ssh host 'cd /w; orca-ide worktree rm --worktree id:abc' > /tmp/out 2>&1 # cleanup"
want deny 'ssh host "cd /w && orca worktree rm --worktree id:abc" </dev/null'
want allow 'ssh host "echo done; orca worktree list" 2>/dev/null'
want allow "ssh host 'echo \"see; orca worktree rm\"' 2>/dev/null"
want deny "$(printf "ssh host-a <<'EOF'\ncd /w\norca worktree rm --worktree id:abc\nEOF")"
want deny "$(printf "bash <<EOF\norca-ide worktree rm --worktree id:abc\nEOF")"
want allow "$(printf "ssh host-a <<'EOF'\ncd /w\norca worktree list\nEOF")"
want deny 'ssh host-a "echo \$(orca worktree rm --worktree id:abc)"'
want deny "eval 'echo ready; orca worktree rm --worktree id:abc'"
want deny "ssh host-a \"eval 'cd /w; orca-ide worktree rm --worktree id:abc'\""
want allow "eval 'echo ready; orca worktree list'"
want allow 'bash -c "echo \\\$(orca worktree rm --worktree id:abc)"'
want deny 'orca worktree rm</dev/null --worktree id:abc --force'
want deny 'orca-ide worktree remove>/tmp/o 2>&1 --worktree id:abc'
want deny "sudo -u user-a bash -c 'orca worktree rm --worktree id:abc'"
want deny "timeout -k 5 30 bash -c 'orca-ide worktree rm --worktree id:abc'"
want deny "ssh host-a 'sudo -n -u user-a bash -c \"orca worktree rm --worktree id:abc\"'"
want deny 'echo "$('"'"'orca'"'"' worktree rm --worktree id:abc)"'
want allow 'echo "$(date); orca worktree rm is prohibited"'
want deny 'echo "$(date; orca worktree rm --worktree id:abc) done"'
want deny 'echo "$(echo $(orca worktree rm --worktree id:abc))"'
want allow "echo 'prints \$(orca worktree rm --worktree id:abc) literally'"
want allow 'gh pr comment 123 --body "Use \`orca worktree rm --worktree id:abc\` only after validation"'
want deny "$(for i in $(seq 1 59); do printf 'rm -f /tmp/nonexistent; '; done)"'rm -rf $DIR'
want deny "$(for i in $(seq 1 70); do printf 'rm -rf $D%d; ' "$i"; done)echo"
want deny 'result="$(ssh host-a orca worktree rm --worktree id:abc)"'
want deny 'echo "$(cd /w && orca worktree rm --worktree id:abc)"'
want deny 'x=$(sudo -u user-a orca-ide worktree rm --worktree id:abc; echo done)'
want deny 'echo id:abc | xargs -I {} orca worktree rm --worktree {}'
want deny "eval 'orca worktree rm --worktree id:abc'"
# a long chain still gets the orca check at its end, inside the 5 s hook timeout (installed in prompt-stalls.md)
t0=$(date +%s); out="$(run "$(for i in $(seq 1 400); do printf 'rm -rf /tmp/f%d; ' "$i"; done)orca worktree rm --worktree id:abc")"; t1=$(date +%s)
[ -n "$out" ] && [ $((t1 - t0)) -le 4 ] && echo "ok   400 rm -rf then a raw orca removal: denied in $((t1 - t0)) s" || { echo "FAIL long chain: denied=[${out:+yes}] in $((t1 - t0)) s"; fail=1; }
want deny "$(for i in $(seq 1 400); do printf 'rm -rf /tmp/f%d; ' "$i"; done)orca worktree rm --worktree id:abc"
# the other documented binaries, variable forms, wrappers with option values, substitutions, find -exec
want deny 'orca-dev worktree rm --worktree id:abc'
want deny '"$ORCA_CLI_COMMAND" worktree rm --worktree id:abc'
want deny '$ORCA worktree rm --worktree id:abc'
want deny '${ORCA_CLI} worktree rm --worktree id:abc'
want deny '\orca worktree rm --worktree id:abc'
want deny 'sudo -u user-a orca worktree rm --worktree id:abc'
want deny 'timeout -k 5 30 orca worktree rm --worktree id:abc'
want deny 'env -u FOO orca-ide worktree rm --worktree id:abc'
want deny 'echo $(orca worktree rm --worktree id:abc)'
want deny 'x=`orca worktree rm --worktree id:abc`'
want deny 'find . -exec orca worktree rm --worktree id:abc \;'
want deny 'bash ./teardown.sh x "$(orca worktree rm --worktree id:abc)"'
want allow "echo '\$(orca worktree rm --worktree id:abc)'"
want allow 'sudo -u user-a orca worktree list'
want allow 'find . -name x -exec echo {} \;'
want allow 'git worktree remove --force /home/user/orca/workspaces/acme-app/scratch'
want deny "bash -c 'echo hi; orca worktree rm --worktree id:abc' _"
want deny "bash -c 'orca worktree rm --worktree \$1' _ id:abc"
want deny 'sh -c "echo hi; orca-ide worktree rm --worktree id:abc" name arg'
want allow "bash -c 'echo hi' _ orca worktree rm"
want deny 'ssh host-a "orca" worktree rm --worktree id:abc'
want deny "ssh host-a 'orca' worktree remove --worktree id:abc"
want deny 'ssh -l user-a host-a orca worktree rm --worktree id:abc'
want allow "bash -c 'echo \"\\\$(orca worktree rm --worktree id:abc)\"'"
want deny 'orca worktree --worktree id:abc rm; echo done'
want deny 'orca worktree --worktree id:abc remove&& echo done'
want allow 'orca worktree --json set --worktree active --comment "remove after validation"'
want allow 'orca-ide worktree --json show --worktree id:abc'
want deny 'orca "worktree" rm --worktree id:abc'
want deny "orca worktree 'rm' --worktree id:abc"
want deny 'orca-ide "worktree" "remove" --worktree id:abc'
want allow 'bash -c "echo \"done; orca worktree rm later\""'
want allow 'ssh host-a "echo \"see; orca worktree rm now\""'
want deny 'ssh -o "BatchMode yes" host-a orca worktree rm --worktree id:abc'
want deny "ssh -o 'ProxyCommand ssh -W %h:%p jump' host-a orca-ide worktree rm --worktree id:abc"
want allow 'ssh -o "BatchMode yes" host-a orca worktree list --json'
want deny "ssh host-a 'cd /w; bash -c \"orca worktree rm --worktree id:abc\"'"
want deny "ssh host-a 'if true; then sudo bash -c \"orca worktree rm --worktree id:abc\"; fi'"
want deny "ssh host-a 'cd /w && ssh host-b orca worktree rm --worktree id:abc'"
want allow "ssh host-a 'cd /w; bash -c \"orca worktree list\"'"
want allow 'ssh -o BatchMode=yes host-a orca worktree list --json'
want allow 'ssh -o BatchMode=yes host-a echo orca worktree rm in the docs'
want deny "$(printf "ssh host-a 'cd /w\norca worktree rm --worktree id:abc'")"
want deny "$(printf "bash -c 'set -e\n  orca-ide --environment host-a worktree rm --worktree id:abc\n'")"
want allow "$(printf "ssh host-a 'cd /w\norca worktree list --json'")"
want deny "$(printf 'orca worktree \\\nremove --worktree id:abc')"
want deny "$(printf 'orca-ide --environment host-a worktree \\\n  rm --worktree id:abc')"
want deny '/usr/local/bin/orca worktree rm --worktree id:abc'
want deny 'sudo orca worktree rm --worktree id:abc'
want deny 'scripts/teardown.sh h /p --apply && orca worktree rm --worktree id:abc'
want deny "ssh host-a 'orca worktree rm --worktree id:abc'"
want deny 'bash -c "orca worktree rm --worktree id:abc"'
want deny 'eval orca worktree rm --worktree id:abc'
want deny '/bin/bash -c "orca worktree rm --worktree id:abc"'
want deny 'ls | xargs -I{} orca worktree rm --worktree id:{}'
want deny '(orca worktree rm --worktree id:abc)'
want deny "ssh host-a 'cd /w && orca worktree rm --worktree id:abc'"
want deny "sh -c 'ls; orca --json worktree remove --worktree id:abc'"
want deny 'eval "orca worktree rm --worktree id:abc"'
want deny "eval 'orca worktree rm --worktree id:abc'"
want deny 'ssh host-a orca worktree rm --worktree id:abc'
want deny 'ssh -t host-a orca worktree rm --worktree id:abc'
want deny 'ssh -p 2222 host-a orca worktree remove --worktree id:abc'
want deny 'ssh host-a "sudo orca worktree rm --worktree id:abc"'
want deny 'ssh host-a "env X=1 orca worktree rm --worktree id:abc"'
want deny 'ssh host-a "timeout 30 orca worktree rm --worktree id:abc"'
want deny "bash -c 'nohup orca worktree rm --worktree id:abc'"
# allow: prose inside an ssh / bash -c string is not a command
want allow "bash -c 'echo orca worktree rm now'"
want allow "ssh host-a 'echo see orca worktree rm in the docs'"
# the Linux CLI name, and quoted prose inside a nested shell string
want deny 'orca-ide worktree rm --worktree id:abc'
want deny '/usr/local/bin/orca-ide worktree remove --worktree id:abc'
want deny 'ssh host-a orca-ide worktree rm --worktree id:abc'
want deny "bash -c 'orca-ide worktree rm --worktree id:abc'"
want allow 'orca-ide worktree list --json'
want allow "ssh host-a 'echo \"orca worktree rm --worktree id:abc\"'"
want allow "bash -c 'printf \"%s\" \"orca worktree rm now\"'"
want deny "bash -ec 'orca worktree rm --worktree id:abc'"
want deny 'orca --environment host-a worktree rm --worktree id:abc'
want deny 'orca-ide --environment host-a --json worktree remove --worktree id:abc'
want deny "ssh host-a 'orca --environment local worktree rm --worktree id:abc'"
want deny 'orca --json worktree rm --worktree id:abc'
want allow 'orca --environment host-a worktree list --json'
want allow 'orca --environment host-a worktree set --worktree active --comment "rm later"'
want deny "ssh host-a \"bash -c 'orca worktree rm --worktree id:abc'\""
[ -n "$(env -u ORCA_CLI_COMMAND bash -c 'jq -n --arg c "rm -rf \$S/x" --arg w "$1" "{tool_name:\"Bash\",cwd:\$w,tool_input:{command:\$c}}" | "$2"' _ "$CWD" "$HOOK")" ] && echo "ok   unset ORCA_CLI_COMMAND does not crash the hook" || { echo "FAIL unset ORCA_CLI_COMMAND crashes the hook"; fail=1; }
[ -n "$(ORCA_CLI_COMMAND=/opt/x/orca-custom run 'orca-custom worktree rm --worktree id:abc')" ] && echo "ok   ORCA_CLI_COMMAND basename denied" || { echo "FAIL ORCA_CLI_COMMAND basename"; fail=1; }
# allow: teardown.sh itself, other orca worktree commands, prose
want allow 'scripts/teardown.sh local /home/user/orca/workspaces/acme-app/x'
want allow 'skills/concertmaster-template/scripts/teardown.sh host-a /home/u/orca/workspaces/acme-app/x --apply --salvage'
want allow 'bash scripts/teardown.sh local /p --apply --salvage --close-handle h'
want allow 'orca worktree list --json'
want allow 'orca worktree set --worktree active --comment "cm:done rm later"'
want allow 'orca worktree show --worktree id:abc'
want allow 'echo "orca worktree rm --worktree id:abc"'
want allow 'git commit -m "docs: never orca worktree rm by hand"'
want allow 'gh pr comment 1 --body "run orca worktree rm; then done"'
want allow "$(printf "cat > f <<'EOF'\norca worktree rm --worktree id:abc\nEOF")"
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
# the raw worktree removal rule follows the same scope: other projects untouched
[ -z "$(CWD=/home/user/other-project run 'orca worktree rm --worktree id:abc --force')" ] && echo "ok   raw worktree rm outside scope untouched" || { echo "FAIL raw rm other project"; fail=1; }
# ...but a command that names a path in the match is in scope whatever the cwd
[ -n "$(CWD=/home/user/other-project run 'orca worktree rm --worktree path:/home/user/orca/workspaces/acme-app/x')" ] && echo "ok   raw worktree rm of an in-scope target denied from another cwd" || { echo "FAIL raw rm target scope"; fail=1; }
# the rm rule still needs the cwd in scope (a path in the command alone does not turn it on)
[ -z "$(CWD=/home/user/other-project run 'rm -rf $S/acme-app/x')" ] && echo "ok   plain rm rule keeps the cwd scope" || { echo "FAIL rm scope"; fail=1; }
# the deny reason points at teardown.sh
out="$(run 'orca worktree rm --worktree id:abc')"
case "$out" in *teardown.sh*) echo "ok   raw worktree rm reason names teardown.sh" ;; *) echo "FAIL reason"; fail=1 ;; esac
# a checkout whose git origin is a repo of the configured org is in scope without a path match
GT="$(mktemp -d "${TMPDIR:-/tmp}/cm-rmguard.XXXXXX")" || exit 1
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $GT" >&2 || rm -rf -- "${GT:?}"' EXIT
git -C "$GT" init -q && git -C "$GT" remote add origin https://github.com/acme/other-name.git
[ -n "$(CWD="$GT" run 'rm -rf $S/x')" ] && echo "ok   org origin is in scope" || { echo "FAIL org origin"; fail=1; }
git -C "$GT" remote set-url origin https://github.com/someone-else/x.git
[ -z "$(CWD="$GT" run 'rm -rf $S/x')" ] && echo "ok   foreign origin untouched" || { echo "FAIL foreign origin"; fail=1; }
# a git checkout with NO origin, and a plain non-git directory, both outside the path match, stay out
# of the way (an empty origin URL must not put a directory in scope: the global hook must not change
# other projects)
NG="$(mktemp -d "${TMPDIR:-/tmp}/cm-rmguard-nogit.XXXXXX")" || exit 1
NO="$(mktemp -d "${TMPDIR:-/tmp}/cm-rmguard-noorigin.XXXXXX")" || exit 1
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $GT $NG $NO" >&2 || rm -rf -- "${GT:?}" "${NG:?}" "${NO:?}"' EXIT
git -C "$NO" init -q
if [ -z "$(CWD="$NG" run 'rm -rf $S/x')" ]; then echo "ok   non-git dir outside the path match untouched"; else echo "FAIL non-git dir"; fail=1; fi
if [ -z "$(CWD="$NO" run 'rm -rf $S/x')" ]; then echo "ok   git dir with no origin untouched"; else echo "FAIL no-origin dir"; fail=1; fi
# 100 and 300 ssh pieces then a raw removal: both refused by the 20-piece budget, so the 300 case must not take
# longer than the 100 case (it took 35 s against 12 s before the budget)
mk() { for i in $(seq 1 "$1"); do printf 'ssh h%s orca worktree list; ' "$i"; done; printf 'orca worktree rm --worktree id:abc'; }
t0=$(date +%s); o1="$(run "$(mk 100)")"; t1=$(date +%s); o2="$(run "$(mk 300)")"; t2=$(date +%s)
case "$o1$o2" in *"More than 20"*"More than 20"*) bud=1 ;; *) bud=0 ;; esac
[ "$bud" = 1 ] && [ -n "$o1" ] && [ -n "$o2" ] && [ $(( (t2 - t1) - (t1 - t0) )) -le 3 ] && echo "ok   ssh pieces over budget: denied, 300 took $((t2 - t1)) s against $((t1 - t0)) s for 100" || { echo "FAIL ssh budget: 100=[${o1:+yes}] $((t1 - t0)) s, 300=[${o2:+yes}] $((t2 - t1)) s"; fail=1; }
big="$(for i in $(seq 1 15); do printf 'ssh h%s orca worktree list; ' "$i"; done)echo done"
[ -z "$(run "$big")" ] && echo "ok   15 ssh pieces without a removal allowed" || { echo "FAIL 15 ssh pieces denied"; fail=1; }
# 100 and 300 command substitutions then a raw removal are refused by the same budget
mk2() { for i in $(seq 1 "$1"); do printf 'x=$(orca worktree list --json); '; done; printf 'orca worktree rm --worktree id:abc'; }
t0=$(date +%s); o1="$(run "$(mk2 100)")"; t1=$(date +%s)
case "$o1" in *"More than 20"*) echo "ok   100 substitutions then a raw removal: refused by the piece budget" ;; *) echo "FAIL 100 substitutions: not refused by the budget"; fail=1 ;; esac
# round 5: the substitution budget counts every $( , backtick pair and <( in the body, not one per piece: 400 of them
# in one command must be refused up front, well inside the 5 s hook timeout
chk() { # $1 = label, $2 = command, $3 = reason text it must carry
  local t0 t1 o; t0=$(date +%s); o="$(run "$2")"; t1=$(date +%s)
  case "$o" in *"$3"*) [ $((t1 - t0)) -le 3 ] && echo "ok   $1: refused by the budget in $((t1 - t0)) s" || { echo "FAIL $1: refused but took $((t1 - t0)) s"; fail=1; } ;; *) echo "FAIL $1: not refused by the budget"; fail=1 ;; esac
}
sub400="$(for i in $(seq 1 400); do printf 'echo worktree $(true) x; '; done)orca worktree rm --worktree id:abc"
chk "400 \$( in one body" "$sub400" "More than 20"
bt400="$(for i in $(seq 1 400); do printf 'echo worktree `true` x; '; done)orca worktree rm --worktree id:abc"
chk "400 backtick pairs in one body" "$bt400" "More than 20"
ps400="$(for i in $(seq 1 400); do printf 'echo worktree <(true) x; '; done)orca worktree rm --worktree id:abc"
chk "400 <( in one body" "$ps400" "More than 20"
one="echo worktree$(for i in $(seq 1 400); do printf ' $(true)'; done); orca worktree rm --worktree id:abc"
chk "400 \$( inside one piece" "$one" "More than 20"
few="$(for i in $(seq 1 8); do printf 'echo worktree $(true) x; '; done)echo done"
[ -z "$(run "$few")" ] && echo "ok   8 substitutions without a removal allowed" || { echo "FAIL 8 substitutions denied"; fail=1; }
# 600 pieces naming worktree (the hook only reads a command that also says rm or remove): the piece budget, with its own reason (it is not an ssh count)
pieces600="$(for i in $(seq 1 600); do printf 'echo worktree rm %s; ' "$i"; done)echo done"
chk "600 pieces naming worktree" "$pieces600" "More than 500 command pieces"
# the 20-ssh worst case reads every piece: it must stay well inside the 5 s hook timeout
ssh20="$(for i in $(seq 1 20); do printf 'ssh h%s orca worktree list; ' "$i"; done)echo done"
t0=$(date +%s); o="$(run "$ssh20")"; t1=$(date +%s)
[ -z "$o" ] && [ $((t1 - t0)) -le 4 ] && echo "ok   20 ssh pieces read in $((t1 - t0)) s" || { echo "FAIL 20 ssh pieces: out=[${o:+deny}] $((t1 - t0)) s"; fail=1; }
# a malformed payload and a missing command never block
[ -z "$(printf 'not json' | "$HOOK")" ] && echo "ok   garbage input allowed" || { echo "FAIL garbage input"; fail=1; }
# the deny output is valid hook JSON with a reason
out="$(run 'rm -rf $S/x')"
[ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ] && echo "ok   deny JSON shape" || { echo "FAIL deny JSON shape"; fail=1; }
exit $fail
