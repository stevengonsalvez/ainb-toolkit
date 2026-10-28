#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016,SC2012,SC2329  # pass() always succeeds so A && pass || fail is if-then-else; jq filters are single-quoted on purpose; ls output is compared as text; date() is a stub the lib calls
# ledger-write.sh (test): behaviour tests for cm_ledger_write (scripts/lib.sh), the one way to write
# the ledger. The 25 Oct 2026 incident: a filter produced no output and an empty file replaced
# ledger.json. Covers: that exact filter (ledger untouched, non-zero), a non-object, an object
# without workers, several documents, output under half size, a jq error, a missing or empty
# ledger (and --init), a good write (ledger changes, backup of the OLD file), mode kept, the
# backup ring pruned to 20, restore with the printed command, atomicity (no temp or partial file
# left behind), set -e / set -u safety, parallel writers, and the lock (re-entrant, stale steal).
# CM_HOME and HOME live in a mktemp dir; the real ~/.concertmaster is never touched.
#
#   scripts/test/ledger-write.sh      # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../lib.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-ledger-write.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then echo "temp dir missing" >&2; exit 1; fi
trap 'rm -rf -- "${ROOT:?}"' EXIT
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }
unset CM_LEDGER CM_LEDGER_BAK CM_LEDGER_BAK_KEEP CM_ORG CM_REPO CM_PROJECT CM_EXCLUDE_REPOS CM_PATH_MATCH
export HOME="$ROOT/home" CM_HOME="$ROOT/cm" CM_CONFIG="$HERE/fixtures/config.test.yaml"
mkdir -p "$HOME" "$CM_HOME"
L="$CM_HOME/ledger.json"
BAK="$CM_HOME/ledger.bak"
# shellcheck source=SCRIPTDIR/../lib.sh
. "$LIB"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

# fresh [pad]: a valid ledger; pad adds that many workers so the file has some bulk.
fresh() {
  rm -rf -- "${CM_HOME:?}"/*
  jq -n --argjson pad "${1:-3}" '{schema: "concertmaster.ledger/v1", n: 0,
    workers: ([range($pad)] | map({key: "w-\(.)", value: {state: "running", task: "issue #\(.) some task text to give the row bulk"}}) | from_entries)}' > "$L"
}
# leftovers: any temp, partial or lock file in the ledger dir or the ring.
leftovers() { find "$CM_HOME" \( -name '*.tmp*' -o -name '*.part' -o -name '*.lock*' \) 2>/dev/null; }
nbak() { find "$BAK" -maxdepth 1 -name '*.json' 2>/dev/null | grep -c . || true; }

# refuses <label> <stderr substring> <filter> [jq args...]: non-zero, ledger byte-identical, reason
# on stderr, no leftovers, no backup written.
refuses() {
  local label="$1" want="$2"; shift 2
  local before="$ROOT/before.json" err rc nb
  cp "$L" "$before"; nb="$(nbak)"
  err="$(cm_ledger_write "$@" 2>&1 >/dev/null)"; rc=$?
  if [ "$rc" = 0 ]; then fail "$label" "exit 0, expected a refusal"; return; fi
  if ! cmp -s "$before" "$L"; then fail "$label" "ledger changed"; return; fi
  case "$err" in *"$want"*) ;; *) fail "$label" "stderr lacks \"$want\": $err"; return ;; esac
  [ -z "$(leftovers)" ] || { fail "$label" "left behind: $(leftovers)"; return; }
  [ "$(nbak)" = "$nb" ] || { fail "$label" "a backup was written for a refused write"; return; }
  pass "$label"
}

# --- the incident and the other bad outputs ---------------------------------------------------
fresh 5
refuses "incident: a filter with no output is refused, ledger untouched" "no output" 'empty'
refuses "a filter output that is not an object (array)" "not an object" '[.workers | keys]'
refuses "a filter output that is not an object (string)" "not an object" '"x"'
refuses "an object without a workers key" "no workers key" 'del(.workers)'
refuses "several documents (a stray top-level comma)" "2 JSON documents" '., .'
refuses "output under half the old size" "under half" '{workers: {}}'
refuses "a jq runtime error" "jq failed" '.workers | error("boom")'
refuses "a jq syntax error" "jq failed" '.workers |||'
refuses "usage: empty filter" "usage" ''
[ "$(nbak)" = 0 ] && pass "refusals wrote no backups" || fail "refusal backups" "$(nbak) backups"

# --- missing and empty ledger, --init ---------------------------------------------------------
rm -f "$L"
err="$(cm_ledger_write '.n = 1' 2>&1 >/dev/null)"; rc=$?
[ "$rc" != 0 ] && [ ! -e "$L" ] && pass "a missing ledger is refused and not created" || fail "missing ledger" "rc=$rc exists=$([ -e "$L" ] && echo y || echo n)"
case "$err" in *"--init"*) pass "a missing ledger with no backups points at --init (first boot)" ;; *) fail "missing hint" "$err" ;; esac
: > "$L"
err="$(cm_ledger_write '.n = 1' 2>&1 >/dev/null)"; rc=$?
[ "$rc" != 0 ] && [ ! -s "$L" ] && pass "an empty ledger file is refused and stays empty" || fail "empty ledger" "rc=$rc size=$(wc -c < "$L")"
cm_ledger_write --init '{schema: "concertmaster.ledger/v1", workers: {}}' 2>/dev/null; rc=$?
[ "$rc" = 0 ] && jq -e 'type == "object" and has("workers")' "$L" >/dev/null 2>&1 && pass "--init builds a ledger over an empty file" || fail "--init over empty" "rc=$rc"
[ "$(nbak)" = 0 ] && pass "--init has no old file to back up" || fail "--init backup" "$(nbak)"
before="$(cat "$L")"
err="$(cm_ledger_write --init '{workers: {}}' 2>&1 >/dev/null)"; rc=$?
[ "$rc" != 0 ] && [ "$(cat "$L")" = "$before" ] && pass "--init refuses when a ledger already exists" || fail "--init over live" "rc=$rc"
rm -rf -- "${CM_HOME:?}"/*
cm_ledger_write --init '{n: 1}' 2>/dev/null; rc=$?
[ "$rc" != 0 ] && [ ! -s "$L" ] && [ -z "$(leftovers)" ] && pass "--init output is checked too (no workers: refused, no file)" || fail "--init bad output" "rc=$rc"
rm -rf -- "${CM_HOME:?}"
cm_ledger_write --init '{workers: {}}' 2>/dev/null; rc=$?
[ "$rc" = 0 ] && [ -s "$L" ] && pass "--init creates a missing ledger directory" || fail "--init mkdir" "rc=$rc"
mkdir -p "$CM_HOME"

# --- a lost ledger WITH backups is a restore, not a first boot ---------------------------------
fresh 4
cm_ledger_write '.n = 1' 2>/dev/null; cm_ledger_write '.n = 2' 2>/dev/null
: > "$L"   # the ledger is lost
err="$(cm_ledger_write '.n = 3' 2>&1 >/dev/null)"; rc=$?
[ "$rc" != 0 ] && [ ! -s "$L" ] && case "$err" in *"restore, not a first boot"*"cp \"\$(ls"*"ledger.bak"*) true ;; *) false ;; esac \
  && pass "a lost ledger with backups: refused, the message gives the restore command" || fail "lost with ring" "rc=$rc $err"
before="$(nbak)"
err="$(cm_ledger_write --init '{workers: {}}' 2>&1 >/dev/null)"; rc=$?
[ "$rc" != 0 ] && [ ! -s "$L" ] && [ "$(nbak)" = "$before" ] && case "$err" in *"restore"*) true ;; *) false ;; esac \
  && pass "--init is refused while the ring holds backups (it would push them out)" || fail "--init over ring" "rc=$rc $err"
CM_LEDGER_INIT_FORCE=1 cm_ledger_write --init '{workers: {}}' 2>/dev/null; rc=$?
[ "$rc" = 0 ] && [ -s "$L" ] && pass "CM_LEDGER_INIT_FORCE=1 lets --init through" || fail "init force" "rc=$rc"
: > "$L"; bash -c "$(cm_ledger_restore_hint)" && [ "$(jq -r .n "$L")" = 1 ] \
  && pass "the restore hint restores the newest timestamped backup" || fail "restore after force" "n=$(jq -r .n "$L")"
printf '{"workers":{}}\n' > "$BAK/pre-migration.json"
hint_pick="$(cm_ledger_restore_hint)"; : > "$L"; bash -c "$hint_pick"
[ -s "$L" ] && [ "$(jq -r '.workers | length' "$L")" != 0 ] && pass "a hand-copied file in the ring is never picked as newest" || fail "hand copy picked" "$(cat "$L")"
for i in $(seq 1 25); do cm_ledger_write '.n = $v' --argjson v "$i" 2>/dev/null; done
[ -f "$BAK/pre-migration.json" ] && pass "a hand-copied file in the ring is never pruned" || fail "hand copy pruned" "gone"
rm -f "$BAK/pre-migration.json"

# --- workers must be an object; keep 0 --------------------------------------------------------
fresh 5
refuses "workers: null is refused" "workers is a null" '.workers = null | .pad = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"'
refuses "workers: an array is refused" "workers is a array" '.workers = [.workers] '
CM_LEDGER_BAK_KEEP=0 cm_ledger_write '.n = 1' 2>/dev/null
[ "$(nbak)" = 1 ] && pass "CM_LEDGER_BAK_KEEP=0 still keeps the backup just written" || fail "keep 0" "$(nbak)"

# --- a good write -----------------------------------------------------------------------------
fresh 4
old="$ROOT/old.json"; cp "$L" "$old"
cm_ledger_write '.n = $v | .workers["w-new"] = {state: "running"}' --argjson v 7 2>/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(jq -r '.n' "$L")" = 7 ] && [ "$(jq -r '.workers["w-new"].state' "$L")" = running ] && pass "a good write changes the ledger (jq args are passed)" || fail "good write" "rc=$rc"
[ "$(nbak)" = 1 ] && cmp -s "$old" "$(find "$BAK" -name '*.json' | head -1)" && pass "the backup is a copy of the OLD ledger" || fail "backup content" "$(ls -la "$BAK" 2>&1)"
[ -z "$(leftovers)" ] && pass "a good write leaves no temp file or lock" || fail "good write leftovers" "$(leftovers)"
[ "$(jq -s 'length' "$L")" = 1 ] && pass "the ledger is still exactly one document" || fail "one doc" "$(jq -s length "$L")"
cm_ledger_write '.n += 1' 2>/dev/null && [ "$(jq -r '.n' "$L")" = 8 ] && pass "no jq args works" || fail "no jq args" "n=$(jq -r .n "$L")"

# --- mode kept --------------------------------------------------------------------------------
chmod 640 "$L"
cm_ledger_write '.n += 1' 2>/dev/null
mode="$(stat -L -c %a "$L" 2>/dev/null || stat -L -f %Lp "$L")"
[ "$mode" = 640 ] && pass "the ledger keeps its mode across a write" || fail "mode" "$mode"

# --- the ring: 25 writes keep 20 backups, newest first-out order ------------------------------
fresh 4
for i in $(seq 1 25); do cm_ledger_write '.n = $v' --argjson v "$i" 2>/dev/null || fail "ring write $i" "refused"; done
[ "$(nbak)" = 20 ] && pass "the ring is pruned to 20 backups" || fail "ring size" "$(nbak)"
newest="$(printf '%s\n' "$BAK"/*.json | LC_ALL=C sort | tail -1)"
oldest="$(printf '%s\n' "$BAK"/*.json | LC_ALL=C sort | head -1)"
[ "$(jq -r '.n' "$newest")" = 24 ] && pass "the newest backup is the ledger before the last write" || fail "newest backup" "n=$(jq -r .n "$newest")"
[ "$(jq -r '.n' "$oldest")" = 5 ] && pass "the oldest backups are the ones pruned" || fail "oldest backup" "n=$(jq -r .n "$oldest")"
[ -z "$(find "$BAK" -type f ! -name '*.json')" ] && pass "the ring holds only .json files" || fail "ring files" "$(find "$BAK" -type f ! -name '*.json')"
# 120 writes inside ONE second (the clock is pinned): the same-second names stay in write order even
# after pruning frees the oldest name of that second.
fresh 4
date() { if [ "${1:-}" = "-u" ] && [ "${2:-}" = "+%Y%m%dT%H%M%SZ" ]; then echo 20261026T000000Z; else command date "$@"; fi; }
for i in $(seq 1 120); do cm_ledger_write '.n = $v' --argjson v "$i" 2>/dev/null || fail "same-second write $i" "refused"; done
unset -f date
newest="$(printf '%s\n' "$BAK"/*.json | LC_ALL=C sort | tail -1)"
oldest="$(printf '%s\n' "$BAK"/*.json | LC_ALL=C sort | head -1)"
[ "$(nbak)" = 20 ] && [ "$(jq -r '.n' "$newest")" = 119 ] && [ "$(jq -r '.n' "$oldest")" = 100 ] \
  && pass "120 writes in one second (past _100): 20 kept, name order is write order" || fail "same-second ring" "count=$(nbak) newest=$(jq -r .n "$newest") oldest=$(jq -r .n "$oldest")"
CM_LEDGER_BAK_KEEP=3 cm_ledger_write '.n += 1' 2>/dev/null
[ "$(nbak)" = 3 ] && pass "CM_LEDGER_BAK_KEEP lowers the ring size" || fail "keep override" "$(nbak)"

# --- restore with the printed command ---------------------------------------------------------
fresh 4
cm_ledger_write '.n = 41' 2>/dev/null; cm_ledger_write '.n = 42' 2>/dev/null
: > "$L"   # the ledger is lost
hint="$(cm_ledger_restore_hint)"
case "$hint" in "cp "*"$BAK"*"\"$L\"") pass "the restore hint is one cp command naming the ring" ;; *) fail "restore hint" "$hint" ;; esac
bash -c "$hint" && [ "$(jq -r '.n' "$L")" = 41 ] && pass "the restore command puts the newest backup back" || fail "restore" "n=$(jq -r .n "$L" 2>&1)"

# --- atomicity --------------------------------------------------------------------------------
fresh 5
for f in 'empty' '[1]' 'del(.workers)' '{workers: {}}' '., .' '.x |||'; do cm_ledger_write "$f" >/dev/null 2>&1; done
[ -z "$(leftovers)" ] && [ "$(ls -A "$CM_HOME" | LC_ALL=C sort | tr '\n' ' ')" = "ledger.json " ] \
  && pass "refusals leave only ledger.json in the ledger dir (no temp, partial, lock or ring)" || fail "atomic" "$(ls -A "$CM_HOME" | tr '\n' ' ')"
# a write is a rename: the inode seen by a reader before the write is complete JSON after it
exec 3< "$L"
cm_ledger_write '.n = 99' 2>/dev/null
[ "$(jq -c . <&3 | jq -r '.n')" = 0 ] && [ "$(jq -r '.n' "$L")" = 99 ] && pass "a reader holding the old file still sees complete JSON (rename, not in-place)" || fail "rename" "reader/new disagree"
exec 3<&-

# --- set -e and set -u ------------------------------------------------------------------------
fresh 4
out="$(bash -euo pipefail -c '. "$1"; cm_ledger_write ".n = 5"; echo reached' _ "$LIB" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(jq -r .n "$L")" = 5 ] && case "$out" in *reached*) true ;; *) false ;; esac && pass "set -euo pipefail: a good write with no jq args" || fail "set -eu good" "rc=$rc $out"
out="$(bash -euo pipefail -c '. "$1"; cm_ledger_write empty; echo reached' _ "$LIB" 2>&1)"; rc=$?
case "$out" in *reached*) fail "set -e refusal" "script went on after a refusal" ;; *) [ "$rc" != 0 ] && [ "$(jq -r .n "$L")" = 5 ] && pass "set -e: a refusal stops the caller, ledger untouched" || fail "set -e refusal" "rc=$rc" ;; esac
out="$(bash -euo pipefail -c '. "$1"; cm_ledger_write empty || echo handled; echo reached' _ "$LIB" 2>&1)"
case "$out" in *handled*reached*) pass "set -e: '|| handler' catches a refusal, no unbound variable" ;; *) fail "set -eu handler" "$out" ;; esac
case "$out" in *"unbound"*) fail "set -u" "$out" ;; *) pass "set -u: no unbound variable on a refusal" ;; esac
out="$(bash -euo pipefail -c '. "$1"; cm_ledger_write ".n = \$a + \$b" --argjson a 1 --argjson b 2; echo reached' _ "$LIB" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(jq -r .n "$L")" = 3 ] && pass "set -euo pipefail: several jq args" || fail "set -eu args" "rc=$rc $out"

# --- parallel writers: the lock serialises read-modify-write ----------------------------------
fresh 4
for i in $(seq 1 10); do ( cm_ledger_write '.n += 1' 2>/dev/null ) & done
wait
[ "$(jq -r '.n' "$L")" = 10 ] && pass "10 parallel increments all land (no lost update)" || fail "parallel" "n=$(jq -r .n "$L")"
[ -z "$(leftovers)" ] && pass "parallel writers leave no temp file or lock" || fail "parallel leftovers" "$(leftovers)"

# --- the lock: re-entrant for its holder, stale steal, busy ------------------------------------
fresh 4
cm_ledger_lock && cm_ledger_write '.n = 1' 2>/dev/null; rc=$?
[ "$rc" = 0 ] && [ -d "$L.lock" ] && pass "a write inside the caller's lock does not deadlock or release it" || fail "reentrant" "rc=$rc lock=$([ -d "$L.lock" ] && echo held || echo gone)"
cm_ledger_unlock
[ ! -e "$L.lock" ] && pass "the holder's unlock removes the lock" || fail "unlock" "lock still there"
mkdir "$L.lock" && printf '999999\n' > "$L.lock/pid"
cm_ledger_unlock
[ -d "$L.lock" ] && pass "unlock never removes a lock another process holds" || fail "foreign unlock" "removed"
touch -t 202001010000 "$L.lock"
cm_ledger_write '.n = 2' 2>/dev/null; rc=$?
[ "$rc" = 0 ] && [ ! -e "$L.lock" ] && [ -z "$(find "$CM_HOME" -name 'ledger.json.lock.stale.*')" ] && [ "$(jq -r .n "$L")" = 2 ] \
  && pass "a stale lock (over 2 minutes) is stolen, the write lands, nothing left" || fail "stale steal" "rc=$rc $(ls -a "$CM_HOME")"
mkdir "$L.lock" && printf '999999\n' > "$L.lock/pid"
before="$(cat "$L")"
err="$(cm_ledger_write '.n = 3' 2>&1 >/dev/null)"; rc=$?
[ "$rc" != 0 ] && [ "$(cat "$L")" = "$before" ] && [ -d "$L.lock" ] && case "$err" in *busy*) true ;; *) false ;; esac \
  && pass "a fresh lock held by another process: busy, nothing written, lock kept" || fail "busy" "rc=$rc $err"
rm -rf -- "${L:?}.lock"

# a subshell of the holder is not the holder (bash 4+, $BASHPID): it waits for the lock, refuses when busy
if [ -n "${BASHPID:-}" ]; then
  fresh 4; cm_ledger_lock
  ( cm_ledger_write '.n += 1' 2>/dev/null ); rc=$?
  cm_ledger_unlock
  [ "$rc" != 0 ] && [ "$(jq -r .n "$L")" = 0 ] && pass "a subshell of the lock holder does not share its lock" || fail "subshell lock" "rc=$rc n=$(jq -r .n "$L")"
fi

# --- CM_LEDGER overrides the path; the ring sits next to it ------------------------------------
alt="$ROOT/alt"; mkdir -p "$alt"
jq -n '{workers: {a: {state: "running", task: "padding padding padding"}}}' > "$alt/other.json"
CM_LEDGER="$alt/other.json" cm_ledger_write '.n = 1' 2>/dev/null
[ "$(jq -r .n "$alt/other.json")" = 1 ] && [ -d "$alt/ledger.bak" ] && pass "CM_LEDGER writes that file and keeps its ring beside it" || fail "CM_LEDGER" "$(ls -A "$alt")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
