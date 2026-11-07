#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# shellcheck disable=SC2015  # pass() always succeeds, so A && pass || fail is if-then-else here
# tick-contract.sh (test): SKILL.md carries the "no light ticks" contract in BOTH places that govern a tick
# (§ The tick and § Reporting) in the same words, and no sentence still lets a tick skip the table.
# A text lint, so the two sections cannot drift apart. Reads SKILL.md only. It also pins the deploy-window ask rules
# (the phrases listed below), and proves each pin can fail.
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

# the tick runs the stale-backup check as its own instruction, not inside the description of a file pattern
bk="$(grep -F 'Backup check.' <<<"$tick")"
# shellcheck disable=SC2016  # the pattern holds literal backticks
case "$bk" in *'**Backup check.** Run `scripts/backup-stale.sh` every tick;'*) pass "§ The tick has a Backup check instruction that runs backup-stale.sh every tick" ;; *) fail "backup check" "$(printf '%s' "$bk" | head -c 200)" ;; esac
[ -x "$HERE/../backup-stale.sh" ] && pass "and the script it names exists and is executable" || fail "backup-stale.sh" "not executable"

# The deploy-window ask rules (§ The tick, "No owner question before a deploy is spawned"; § Deploy windows) and their pointers.
# What is pinned is the list of phrases below, each an exact substring of the (unwrapped) SKILL.md: the picker rule's
# headline and conditions (every past-and-unfinished window and the first one ahead pinned and with its own live worker, not
# stuck, a wake armed, a WAITING row otherwise, the rails ask, a missed window, the config key, one worker per window), the clock rule's headline and its
# parts, and the pointers in the no-blocking-ask paragraph, the Deploy windows intro and the digest. Rewording one of them
# fails this test on purpose; the other words of the rules are not pinned. Each pin is proved able to fail below: a scratch
# copy of the skill loses that one phrase and this test must fail on the copy.
flat() { tr '\n' ' ' | tr -s ' '; }   # the rule text is wrapped: compare it as one line
has() { grep -qF -- "$1" <<<"$2"; }
skflat="$(flat < "$SK")"
Q="'"
PINS=(
  "No owner question before a deploy is spawned."
  "is allowed only when EVERY window that is past and still unfinished AND the first unfinished window still ahead"
  "is pinned and has its own live deploy worker, and a wake is armed (\`ScheduleWakeup\` pending)"
  "Pinned means the window${Q}s \`deployWindows[]\` row is at \`staging\` or later"
  "A worker spawned long before its window does not open the picker by itself: the row must be pinned first."
  "listed in \`workers\` as spawning, running or blocked-on-owner; not \`stuck\`"
  "one worker never covers another window"
  "A window that is done, skipped or stopped is not unfinished."
  "the ask is a \`WAITING: <owner>, <question>, <age>\` row in the tick table"
  "the test is coverage, not distance"
  "A picker that is already open when the window arrives is the one exposure left."
  "With no windows configured a picker is allowed when the ledger is readable and every unfinished row on it is covered."
  "Before any blocking owner picker, at any distance from a window, and before a message that names a time or a release, run \`scripts/clock-check.sh\`"
  "and in the window${Q}s \`deployWindows[].sha\`"
  "never a second row for the same window"
  "A rails hit (Deploy windows step 2) or a migration-guard ask comes before the worker exists and is a WAITING row too"
  "stays checked until its outcome is recorded"
  "never a clock time written in a message"
  "This limits the concertmaster${Q}s own picker only"
  "Check the clock and the deploy state before any message that names a time or a release."
  "in the SAME turn, run \`scripts/clock-check.sh\` and rewrite a time that has passed"
  "Never send a time already in the past"
  "never \"ships tonight at <time>\" without the deploy worker${Q}s state"
  "The message text is written AFTER a picker returns, not before"
  "A blocking picker also waits until every past-and-unfinished window and the first window ahead is pinned and has its own live deploy worker and a wake is armed"
  "check any time or release it names against \`scripts/clock-check.sh\` in the same turn"
)
for ph in "${PINS[@]}"; do
  has "$ph" "$skflat" && pass "carries: ${ph:0:70}" || fail "pinned phrase" "missing: $ph"
done
[ -x "$HERE/../clock-check.sh" ] && pass "clock-check.sh exists and is executable" || fail "clock-check.sh" "missing or not executable"

# break on purpose: for each pin, a scratch copy of the skill without that one phrase must make this test fail
if [ -z "${TICK_CONTRACT_NESTED:-}" ]; then
  if command -v python3 >/dev/null 2>&1; then
    BR="$(mktemp -d "${TMPDIR:-/tmp}/cm-tick-contract.XXXXXX")" || BR=""
    if [ -n "$BR" ]; then
      trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $BR" >&2 || rm -rf -- "${BR:?}"' EXIT
      cp -R "$HERE/../.." "$BR/skill"
      brk=0; brn=0
      for ph in "${PINS[@]}"; do
        cp "$HERE/../../SKILL.md" "$BR/skill/SKILL.md"
        python3 - "$BR/skill/SKILL.md" "$ph" <<'PY'
import re, sys
p, ph = sys.argv[1:3]
s = open(p).read()
pat = r"\s+".join(re.escape(w) for w in ph.split())
s2, n = re.subn(pat, "", s, count=1)
if n != 1:
    sys.exit(3)
open(p, "w").write(s2)
PY
        [ "$?" = 0 ] || { fail "break on purpose" "could not find the phrase in SKILL.md to remove it: $ph"; continue; }
        brn=$((brn + 1))
        if TICK_CONTRACT_NESTED=1 bash "$BR/skill/scripts/test/tick-contract.sh" >/dev/null 2>&1; then
          fail "break on purpose" "the test still passes without: $ph"
        else brk=$((brk + 1)); fi
      done
      [ "$brk" = "$brn" ] && [ "$brn" -gt 0 ] && pass "break on purpose: each of the $brn pinned phrases, removed from a scratch copy of the skill, makes this test fail" || fail "break on purpose" "$brk of $brn pins failed the copy"
    else fail "break on purpose" "no scratch dir"; fi
  else echo "SKIP break on purpose: no python3"; fi
fi

printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
