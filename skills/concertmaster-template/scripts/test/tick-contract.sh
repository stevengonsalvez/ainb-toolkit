#!/usr/bin/env bash
# shellcheck disable=SC2015  # pass() always succeeds, so A && pass || fail is if-then-else here
# tick-contract.sh (test): SKILL.md carries the "no light ticks" contract in BOTH places that govern a tick
# (§ The tick and § Reporting) in the same words, and no sentence still lets a tick skip the table.
# A text lint, so the two sections cannot drift apart. Reads SKILL.md only.
#
#   scripts/test/tick-contract.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SK="$HERE/../../SKILL.md"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }
RULE='No light ticks: every tick runs discover + classify + programme-rollup + asks scan and prints the programme table, the census problems line, blockers and the thread table.'
sect() { awk -v h="$1" '$0 ~ "^## " h "$" {on=1; next} /^## / {on=0} on' "$SK"; }   # the text of one "## <heading>" section

[ -r "$SK" ] || { echo "no SKILL.md at $SK" >&2; exit 1; }
tick="$(sect 'The tick')"; rep="$(sect 'Reporting')"
[ -n "$tick" ] && [ -n "$rep" ] && pass "both sections are found" || fail "sections" "tick=$(printf '%s' "$tick" | wc -c) reporting=$(printf '%s' "$rep" | wc -c) bytes"
grep -qF "$RULE" <<<"$tick" && pass "§ The tick carries the rule word for word" || fail "tick rule" "missing"
grep -qF "$RULE" <<<"$rep" && pass "§ Reporting carries the rule word for word" || fail "reporting rule" "missing"
! grep -qiE 'only a full tick|any other tick turn just re-arms' <<<"$tick$rep" && pass "no sentence says only some ticks print the table" || fail "old wording" "$(grep -niE 'only a full tick|any other tick turn just re-arms' <<<"$tick$rep")"
scans_ok=1
for cmd in scripts/discover.sh scripts/classify.sh scripts/programme-rollup.sh scripts/asks.sh; do
  if grep -qF "$cmd" <<<"$tick" && [ -x "$HERE/../$(basename "$cmd")" ]; then :; else fail "step script" "$cmd not named in the tick or not executable"; scans_ok=0; fi
done
[ "$scans_ok" = 1 ] && pass "the four scans the rule names are named in the tick and exist"

# the pane-stall scan is a tick step and a reported row, and its script exists and runs
grep -qF 'scripts/pane-stalls.sh' <<<"$tick" && [ -x "$HERE/../pane-stalls.sh" ] && pass "§ The tick runs scripts/pane-stalls.sh and it is executable" || fail "pane-stalls step" "not named in the tick or not executable"
grep -qiE 'stall rows?.*pane-stalls\.sh' <<<"$rep" && pass "§ Reporting prints the stall rows under the census problems line" || fail "pane-stalls report" "missing"

# a STALL permission prompt is never approved by the concertmaster
grep -qE 'NEVER approve' <<<"$tick" && pass "§ The tick says a stall prompt is never approved" || fail "never approve" "missing"

printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
