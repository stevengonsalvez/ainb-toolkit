#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # check bodies are single-quoted on purpose (eval-ed later) and read variables set outside them
# lane-journal.sh (test): behaviour tests for scripts/lane-journal.sh, the per-lane journal at
# $CM_HOME/lanes/<lane>/journal.md. Covers: append writes one stamped line, the directory is 0700 and the
# file 0600; newlines and control characters become spaces; an entry is capped; stdin works; tail returns
# the last n and nothing for a lane with no journal; text that looks like a secret is refused and nothing
# is written (a 40-hex commit id is allowed); a lane name outside [a-z0-9._-] (slash, "..", upper case,
# colon, a leading dot, too long) is refused and nothing is created outside lanes/; a symlinked lane
# directory or journal is refused; 30 concurrent appends give 30 whole lines; rotate drops entries older
# than journal.keep_days and keeps the last journal.keep_lines, keeps an unstamped line, leaves an empty
# journal and not a missing one, and takes one lane with --lane;
# `name` maps a lane label; no script but lane-journal.sh and resume.sh reads a journal (nothing is sent
# to a group). Touches nothing outside a mktemp dir.
#
#   scripts/test/lane-journal.sh       # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
SKILL="$(cd "$SCRIPTS/.." && pwd)"
unset CM_ORG CM_REPO CM_PROJECT CM_OWNER_NAME CM_OWNER_ID CM_TZ CM_TZ_LABEL CM_EXCLUDE_REPOS CM_PATH_MATCH CM_SELF_WORKTREE CM_SSH_TARGET CM_LEDGER CM_LEDGER_BAK
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-lane-journal.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap 'rm -rf -- "${ROOT:?}"' EXIT
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { echo "missing dependency: yq" >&2; exit 1; }
export HOME="$ROOT/home" CM_HOME="$ROOT/cm"
mkdir -p "$HOME" "$CM_HOME"
# a hermetic config: the test fixture plus small journal limits
CFG="$ROOT/config.yaml"
{ cat "$HERE/fixtures/config.test.yaml"; printf 'journal:\n  tail_lines: 5\n  max_chars: 80\n  keep_lines: 4\n  keep_days: 30\n'; } > "$CFG"
export CM_CONFIG="$CFG"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { if (eval "$2"); then ok "$1"; else bad "$1"; fi; }

J="$SCRIPTS/lane-journal.sh"
LANES="$CM_HOME/lanes"
jf() { printf '%s/%s/journal.md' "$LANES" "$1"; }
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
STAMP='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z '

echo "--- append and tail"
"$J" append lane-a "relayed #12 to merge-ready"; RC=$?
check "append exits 0 and writes one stamped line" '[ "$RC" = 0 ] && [ "$(wc -l < "$(jf lane-a)" | tr -d " ")" = 1 ] && grep -Eq "${STAMP}relayed #12 to merge-ready$" "$(jf lane-a)"'
check "lane directory is 0700, journal 0600" '[ "$(mode "$LANES/lane-a")" = 700 ] && [ "$(mode "$(jf lane-a)")" = 600 ]'
"$J" append lane-a second entry
"$J" append lane-a third entry
check "append never replaces: three entries, in order" '[ "$(wc -l < "$(jf lane-a)" | tr -d " ")" = 3 ] && [ "$(sed -n 3p "$(jf lane-a)" | cut -d" " -f2-)" = "third entry" ]'
check "tail <lane> <n> prints the last n" '[ "$("$J" tail lane-a 2 | wc -l | tr -d " ")" = 2 ] && "$J" tail lane-a 1 | grep -q "third entry$"'
for i in 1 2 3 4 5 6 7; do "$J" append lane-a "entry $i"; done
check "tail with no n uses journal.tail_lines (5)" '[ "$("$J" tail lane-a | wc -l | tr -d " ")" = 5 ] && "$J" tail lane-a | tail -n 1 | grep -q "entry 7$"'
check "tail n=0 or junk falls back to the default, never errors" '[ "$("$J" tail lane-a 0 | wc -l | tr -d " ")" = 5 ] && [ "$("$J" tail lane-a abc | wc -l | tr -d " ")" = 5 ]'
"$J" tail never-written > "$ROOT/out"; RC=$?
check "tail of a lane with no journal: nothing, exit 0, nothing created" '[ "$RC" = 0 ] && [ ! -s "$ROOT/out" ] && [ ! -e "$LANES/never-written" ]'
"$J" append multi $'line one\nline two\tTabbed\r\x01end'
check "newline, tab, CR and control characters become spaces: still one line" '[ "$(wc -l < "$(jf multi)" | tr -d " ")" = 1 ] && grep -Eq "${STAMP}line one line two Tabbed end$" "$(jf multi)"'
printf 'from stdin\nsecond line\n' | "$J" append stdin-lane -
check "text - reads stdin" 'grep -Eq "${STAMP}from stdin second line$" "$(jf stdin-lane)"'
"$J" append capped "$(printf 'word %.0s' $(seq 1 60))"
check "an entry is cut at journal.max_chars (80) with a mark" 'l="$(cut -d" " -f2- "$(jf capped)")"; [ "${#l}" -le 86 ] && printf "%s" "$l" | grep -q " \[cut\]$"'
"$J" append x >/dev/null 2>&1; RC=$?
"$J" append emptyone "   " >/dev/null 2>&1; RC2=$?
check "an empty entry is refused (usage), nothing created" '[ "$RC2" = 2 ] && [ ! -e "$LANES/emptyone" ] && [ "$RC" = 2 ]'

echo "--- secrets are refused"
# Secret-shaped fixtures are built at run time from split pieces, so this file holds no literal
# token-shaped string (a secret scanner or push protection would trip on one).
GH="gh""p_"; SBS="sb_sec""ret_"; SBP="sb""p_"; SKL="sk_li""ve_"; JWT="ey""J"; PEM="-----BEGIN RSA PRI""VATE KEY-----"
ALPHA="abcdefghijklmnopqrstuvwxyz"; DIGS="0123456789"
# generic high-entropy shapes, also built at run time
HEX="0123456789abcdef"; H64="$(printf '%s' "$HEX$HEX$HEX$HEX")"; H40A="${H64:0:40}"; H40B="$(printf "%s" "$H64" | rev | cut -c1-40)"; LONG="${ALPHA}$(printf '%s' "$ALPHA" | tr a-z A-Z)${DIGS:0:4}"
for s in "token ${GH}${ALPHA}${DIGS}" "key ${SBS}abcdefgh12345678" "${SBP}0123456789abcdef" "jwt ${JWT}hbGciOiJIUzI1NiJ9.payload.sig" \
         "digest $H64" "run $LONG" \
         "$PEM" "aws AK""IAABCDEFGHIJKLMNOP" "stripe ${SKL}abc123"; do
  "$J" append secrets "$s" >/dev/null 2>&1; RC=$?
  check "secret refused (exit 3): ${s%% *} ..." '[ "$RC" = 3 ] && [ ! -e "$LANES/secrets" ]'
done
"$J" append secrets "$(printf 'tok %s' "${GH}${ALPHA}${DIGS}" | tr -s ' ')" 2>"$ROOT/err" >/dev/null
check "the refusal message never echoes the value" '! grep -q "${ALPHA:0:6}" "$ROOT/err"'
"$J" append shas "merged at $H40A (head $H40B)" >/dev/null 2>&1; RC=$?
check "a 40-hex commit id is allowed" '[ "$RC" = 0 ] && grep -q "$H40A" "$(jf shas)"'
"$J" append shas2 "heads $H40A $H40B $H40A" >/dev/null 2>&1; RC=$?
check "several commit ids one space apart are allowed" '[ "$RC" = 0 ]'
"$J" append shas3 "id ${H40A}${GH}${ALPHA}${DIGS}" >/dev/null 2>&1; RC=$?
check "a commit id glued to a token does not hide the token" '[ "$RC" = 3 ]'
"$J" append shas "branch acme/feature-x PR #13 #12 relayed" >/dev/null 2>&1; RC=$?
check "ordinary prose with branch names and PR numbers passes" '[ "$RC" = 0 ]'

echo "--- the lane name allowlist"
n_before="$(find "$ROOT" | wc -l | tr -d ' ')"
for bad_lane in '../escape' 'a/b' '..' '.hidden' 'Upper' 'epic:x' '' 'with space' 'semi;colon' "$(printf 'a%.0s' $(seq 1 65))"; do
  "$J" append "$bad_lane" "text" >/dev/null 2>&1; RC=$?
  "$J" tail "$bad_lane" >/dev/null 2>&1; RC2=$?
  check "bad lane name refused by append and tail (exit 2): '${bad_lane:0:20}'" '[ "$RC" = 2 ] && [ "$RC2" != 0 ]'
done
check "no file or directory appeared for any bad name" '[ "$(find "$ROOT" | wc -l | tr -d " ")" = "$n_before" ] && [ ! -e "$CM_HOME/escape" ] && [ ! -e "$ROOT/escape" ]'
"$J" rotate --lane '../x' >/dev/null 2>&1; RC=$?
check "rotate --lane with a bad name is refused" '[ "$RC" = 2 ]'
mkdir -p "$ROOT/elsewhere"; ln -s "$ROOT/elsewhere" "$LANES/linked"
"$J" append linked "text" >/dev/null 2>&1; RC=$?
check "a lane directory that is a symlink is refused, the target stays empty" '[ "$RC" = 1 ] && [ -z "$(ls -A "$ROOT/elsewhere")" ]'
mkdir -p "$LANES/lnk-file"; : > "$ROOT/elsewhere/target"; ln -s "$ROOT/elsewhere/target" "$LANES/lnk-file/journal.md"
"$J" append lnk-file "text" >/dev/null 2>&1; RC=$?
check "a journal that is a symlink is refused, the target stays empty" '[ "$RC" = 1 ] && [ ! -s "$ROOT/elsewhere/target" ]'

echo "--- multibyte text"
"$J" append utf8 "a$(printf 'é%.0s' $(seq 1 100))"; RC=$?
check "a cut never leaves half a multibyte character (valid UTF-8, within the cap)" '[ "$RC" = 0 ] && l="$(cut -d" " -f2- "$(jf utf8)")" && printf "%s" "$l" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 && [ "$(printf "%s" "$l" | LC_ALL=C wc -c | tr -d " ")" -le 86 ] && printf "%s" "$l" | grep -q " \[cut\]$"'

echo "--- concurrent appends"
for i in $(seq 1 30); do "$J" append busy "writer $i says hello" & done; wait
check "30 concurrent appends give 30 whole stamped lines" '[ "$(wc -l < "$(jf busy)" | tr -d " ")" = 30 ] && [ "$(grep -Ec "${STAMP}writer [0-9]+ says hello$" "$(jf busy)")" = 30 ] && [ "$(grep -o "writer [0-9]* says" "$(jf busy)" | sort -u | wc -l | tr -d " ")" = 30 ]'
check "no lock directory or temp file is left behind" '[ -z "$(find "$LANES/busy" -mindepth 1 ! -name journal.md)" ]'
mkdir "$LANES/busy/journal.lock"; touch -d '10 minutes ago' "$LANES/busy/journal.lock" 2>/dev/null || touch -t 202001010000 "$LANES/busy/journal.lock"
"$J" append busy "after a stale lock" >/dev/null 2>&1; RC=$?
check "a stale lock (older than 2 minutes) is stolen" '[ "$RC" = 0 ] && grep -q "after a stale lock$" "$(jf busy)"'

echo "--- rotate"
mkdir -p "$LANES/old" && chmod 700 "$LANES/old"
{ printf '2020-01-01T00:00:00Z ancient entry\n'; printf 'a line with no stamp\n'
  for i in 1 2 3 4 5 6; do printf '%s recent %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$i"; done; } > "$(jf old)"
chmod 600 "$(jf old)"
"$J" rotate > "$ROOT/rot.out"; RC=$?
check "rotate exits 0 and reports each lane" '[ "$RC" = 0 ] && grep -q "^old	kept 4	dropped 4$" "$ROOT/rot.out"'
check "rotate drops the old stamp and keeps the last keep_lines (4): recent 3..6" '[ "$(wc -l < "$(jf old)" | tr -d " ")" = 4 ] && ! grep -q ancient "$(jf old)" && grep -q "recent 3$" "$(jf old)" && grep -q "recent 6$" "$(jf old)" && ! grep -q "recent 2$" "$(jf old)"'
check "rotate keeps the mode 0600 and leaves no temp file" '[ "$(mode "$(jf old)")" = 600 ] && [ -z "$(find "$LANES/old" -mindepth 1 ! -name journal.md)" ]'
if [ "$(id -u)" = 0 ]; then ok "rotate of an unreadable journal (skipped: root reads a mode 000 file)"; else
mkdir -p "$LANES/unreadable"; printf '%s still here\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$(jf unreadable)"; chmod 000 "$(jf unreadable)"
"$J" rotate --lane unreadable >/dev/null 2>"$ROOT/rot.err"; RC=$?
chmod 600 "$(jf unreadable)"
check "rotate of an unreadable journal leaves it intact and says so (never empties it)" 'grep -q "still here" "$(jf unreadable)" && grep -q "not rotated" "$ROOT/rot.err" && [ -z "$(find "$LANES/unreadable" -mindepth 1 ! -name journal.md)" ]'
fi
mkdir -p "$LANES/unstamped"; printf 'only an unstamped line\n' > "$(jf unstamped)"
"$J" rotate >/dev/null
check "an unstamped line is kept" 'grep -q "only an unstamped line" "$(jf unstamped)"'
mkdir -p "$LANES/allold"; printf '2020-01-01T00:00:00Z a\n2020-01-02T00:00:00Z b\n' > "$(jf allold)"
"$J" rotate --lane allold >/dev/null
check "everything expired: an empty journal, not a missing one" '[ -f "$(jf allold)" ] && [ ! -s "$(jf allold)" ]'
printf '2020-01-01T00:00:00Z keep me in other\n' > "$(jf unstamped)"; printf '2020-01-01T00:00:00Z a\n' > "$(jf allold)"
"$J" rotate --lane allold >/dev/null
check "rotate --lane touches that lane only" '[ ! -s "$(jf allold)" ] && grep -q "keep me in other" "$(jf unstamped)"'
mkdir -p "$LANES/no-journal"; : > "$ROOT/out"
"$J" rotate --lane no-journal > "$ROOT/out"; RC=$?
check "rotate on a lane with no journal: nothing, exit 0, no file made" '[ "$RC" = 0 ] && [ ! -s "$ROOT/out" ] && [ ! -e "$(jf no-journal)" ]'
mkdir -p "$LANES/Bad Name" "$LANES/.dot"; printf '2020-01-01T00:00:00Z z\n' > "$LANES/Bad Name/journal.md"; cp "$LANES/Bad Name/journal.md" "$LANES/.dot/journal.md"
"$J" rotate >/dev/null 2>&1
check "rotate ignores a directory whose name is outside the allowlist" '[ -s "$LANES/Bad Name/journal.md" ] && [ -s "$LANES/.dot/journal.md" ]'
"$J" rotate >/dev/null 2>&1; RC=$?
check "rotate is repeatable (second run exits 0)" '[ "$RC" = 0 ]'

# rotate swaps the file (temp + mv): without the lane lock an append between its read and its mv is lost
{ cat "$HERE/fixtures/config.test.yaml"; printf 'journal:\n  keep_lines: 1000\n  keep_days: 3650\n'; } > "$ROOT/config2.yaml"
mkdir -p "$LANES/race"
( for i in $(seq 1 60); do "$J" append race "racing entry $i"; done ) &
( for i in $(seq 1 25); do CM_CONFIG="$ROOT/config2.yaml" "$J" rotate --lane race >/dev/null 2>&1; done ) &
wait
check "appends racing a rotate lose nothing (60 entries survive)" '[ "$(grep -c "racing entry" "$(jf race)")" = 60 ]'

# a rotate killed mid-way removes its temp files, and a CM_HOME with a space never makes it delete another file
SPH="$ROOT/sp home"; mkdir -p "$SPH/lanes/killed" "$ROOT/bin-kill"; chmod 700 "$SPH/lanes/killed"
printf '%s old enough to keep\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$SPH/lanes/killed/journal.md"
: > "$ROOT/sp"   # the file a split at the first space would hit
printf '#!/bin/sh\nkill -TERM "$PPID"\nsleep 1\n' > "$ROOT/bin-kill/tail"; chmod +x "$ROOT/bin-kill/tail"
PATH="$ROOT/bin-kill:$PATH" CM_HOME="$SPH" "$J" rotate --lane killed >/dev/null 2>&1
check "rotate killed mid-way leaves no temp file, journal intact, and deletes nothing else (CM_HOME with a space)" '[ -z "$(find "$SPH/lanes/killed" -mindepth 1 ! -name journal.md ! -name journal.lock)" ] && grep -q "old enough to keep" "$SPH/lanes/killed/journal.md" && [ -e "$ROOT/sp" ]'

echo "--- name mapping"
check "name maps epic:Widget-Two to epic-widget-two" '[ "$("$J" name "epic:Widget-Two")" = epic-widget-two ] && [ "$("$J" name lane-a)" = lane-a ]'
"$J" name 'a/b' >/dev/null 2>&1; RC=$?
"$J" name 'has space' >/dev/null 2>&1; RC2=$?
check "name refuses a label that does not fit" '[ "$RC" = 2 ] && [ "$RC2" = 2 ]'

echo "--- nothing is sent to a group"
others="$(cd "$SCRIPTS" && grep -lE 'journal\.md|lane-journal' ./*.sh ./*.py ./hooks/* 2>/dev/null | grep -vE '^\./(lane-journal|resume)\.sh$' || true)"
check "no script but lane-journal.sh and resume.sh reads a journal (digest, mc-emit, intake, tick-emit and the rest do not)" '[ -z "$others" ]'
check "the digest and message senders never name the lanes directory" '! grep -nE "lanes/" "$SCRIPTS/digest.sh" "$SCRIPTS/mc-emit.sh" "$SCRIPTS/tick-emit.sh" "$SCRIPTS/intake.sh"'

echo
printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
