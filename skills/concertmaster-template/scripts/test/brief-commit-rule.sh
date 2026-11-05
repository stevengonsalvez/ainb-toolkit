#!/usr/bin/env bash
# shellcheck disable=SC2015  # pass() always succeeds, so A && pass || fail is if-then-else here
# brief-commit-rule.sh (test): every brief-shaped place in the skill carries the commit rule in the same
# words: commit only through /commit (named-path staging, pre-commit cleanup, signed), never a raw
# `git commit` or `git add -A` / `git add .`. A text lint, so a template edit cannot drop or reword it.
# Reads the skill's own files only; no network, no git.
#
#   scripts/test/brief-commit-rule.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SK="$HERE/../.."
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }
# shellcheck disable=SC2016  # the backticks are literal text in the rule
RULE='Commit ONLY through the /commit skill (named-path staging, pre-commit cleanup, signed); never a raw `git commit`, `git add -A` or `git add .`.'
# the text of one "## <heading prefix>" section of a file
sect() { awk -v h="$2" 'index($0, "## " h) == 1 {on=1; next} /^## / {on=0} on' "$1"; }
# the footer template itself holds a "## Rules for this session" line inside its fence, so it is cut by range
range() { awk -v a="$2" -v b="$3" 'index($0, "## " a) == 1 {on=1; next} index($0, "## " b) == 1 {on=0} on' "$1"; }

LANES="$SK/references/lanes.md"; SKILLMD="$SK/SKILL.md"; DEVFLOW="$SK/companions/dev-flow.md"
for f in "$LANES" "$SKILLMD" "$DEVFLOW"; do
  [ -r "$f" ] || { echo "cannot read $f" >&2; exit 1; }
done

has() { # has <label> <text> : the section text carries the rule
  [ -n "$2" ] || { fail "$1" "section not found or empty"; return; }
  grep -qF -- "$RULE" <<<"$2" && pass "$1" || fail "$1" "rule missing or reworded"
}

has "lanes.md common footer (the brief checklist) carries the rule" "$(range "$LANES" 'Common footer' 'Lead charter')"
has "lanes.md single-task worker brief carries the rule" "$(sect "$LANES" 'single-task worker')"
has "lanes.md release-tester brief carries the rule" "$(sect "$LANES" 'release-tester')"
has "SKILL.md § Spawn recipe (the brief text step) carries the rule" "$(sect "$SKILLMD" 'Spawn recipe')"
has "SKILL.md lessons loop (a PR the concertmaster opens) carries the rule" "$(grep -F '**Lessons loop (daily).**' "$SKILLMD")"
has "SKILL.md § Hard rules (the standing rule) carries the rule" "$(sect "$SKILLMD" 'Hard rules')"
has "companions/dev-flow.md implement step carries the rule" "$(cat "$DEVFLOW")"

# the footer is appended to every brief: the Spawn recipe must say so and the template must still be appended
grep -qF 'common footer' <<<"$(sect "$SKILLMD" 'Spawn recipe')" && pass "Spawn recipe names the common footer" || fail "footer named" "missing"

# the old half-statement must not come back next to (or instead of) the rule
! grep -qE 'staged by named path, conventional' "$LANES" && pass "lanes.md has no leftover half-rule" || fail "half-rule" "$(grep -nE 'staged by named path, conventional' "$LANES")"
! grep -qE 'go in signed commits' "$LANES" && pass "lanes.md evidence line has no leftover half-rule" || fail "evidence half-rule" "left"

# no brief template tells a worker to run a raw commit or a blanket add as an instruction
bad="$(grep -nE '`(git commit|git add -A|git add \.)' "$LANES" | grep -vF -- "$RULE" || true)"
[ -z "$bad" ] && pass "no brief template instructs a raw git commit or a blanket git add" || fail "raw commit instruction" "$bad"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
