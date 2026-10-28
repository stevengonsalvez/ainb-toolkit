#!/usr/bin/env bash
# markers.py test: Orca worktree-list replies as fixtures. Asserts which comments yield a
# (worktree, #pr, sha) pair and which are rejected: the marker must start the comment or follow " | ",
# the first pair may follow prose before the next cm: token, further pairs only across whitespace, "|",
# commas and parenthesised notes, a bare or reworded marker never counts, and bad input prints nothing.
#
#   scripts/test/markers.sh        # exit 0 when every case passes
set -uo pipefail
PY="$(cd "$(dirname "$0")/.." && pwd)/markers.py"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$3' got '$2'"; fail=1; fi; }
run() { # run <comment>: one worktree named wt-a with that comment
  jq -n --arg c "$1" '{result: {worktrees: [{path: "/w/acme-app/wt-a/", comment: $c}]}}' | python3 "$PY" | tr '\t\n' ' ' | sed 's/ $//'
}
check "marker at the start" "$(run 'cm:merge-ready #90101 abc1234')" "wt-a #90101 abc1234"
check "marker after a pipe" "$(run 'cm:running 3 open | cm:merge-ready #90101 abc1234def56')" "wt-a #90101 abc1234def56"
check "prose before the first pair" "$(run 'cm:merge-ready for after the freeze (x): #90830 deadbeef')" "wt-a #90830 deadbeef"
check "second pair across a comma" "$(run 'cm:merge-ready #90101 abc1234, #90102 def5678')" "wt-a #90101 abc1234 wt-a #90102 def5678"
check "second pair across a parenthesised note" "$(run 'cm:merge-ready #90101 abc1234 (rebased) #90102 def5678')" "wt-a #90101 abc1234 wt-a #90102 def5678"
check "other prose ends the list" "$(run 'cm:merge-ready #90101 abc1234 in review: #90914 0123456')" "wt-a #90101 abc1234"
check "marker mid-sentence is not a marker" "$(run 'converting to cm:merge-ready per PR #90101 abc1234')" ""
check "cm:merge-ready-pending is not a marker" "$(run 'cm:merge-ready-pending #90101 abc1234')" ""
check "a pair after the next cm: token is not taken" "$(run 'cm:merge-ready cm:running #90101 abc1234')" ""
check "no pair, no output" "$(run 'cm:merge-ready')" ""
check "sha too short" "$(run 'cm:merge-ready #90101 abc12')" ""
check "newlines in the comment" "$(run $'cm:merge-ready\n#90101 abc1234')" "wt-a #90101 abc1234"
check "not JSON: no output, exit 0" "$(printf 'garbage' | python3 "$PY"; echo "rc=$?")" "rc=0"
check "bare list reply accepted" "$(printf '[{"path":"/w/x/wt-b","comment":"cm:merge-ready #90103 aaaaaaa"}]' | python3 "$PY" | tr '\t' ' ')" "wt-b #90103 aaaaaaa"
[ "$fail" = 0 ]
