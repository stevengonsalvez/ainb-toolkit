#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# shellcheck disable=SC2016,SC2034  # check bodies are single-quoted on purpose (eval-ed later) and read variables set outside them
# lane-handles.sh (test): behaviour tests for scripts/lane-handles.sh and the lib.sh reader
# (cm_lane_handle, cm_lane_for_path, cm_lane_handle_write). Covers: a refresh writes the LIVE handle;
# a stale ledger handle is ignored; no live agent marks the file dead (not removed, so a send cannot fall
# back to the ledger); two agents, a hand-started one and an inherited handle another lane holds are
# marked dead; an undecidable check leaves the file; a stale, missing or empty file is re-checked before a
# send and never trusted, and the ledger handle is never a fallback; a failed write never leaves the old
# handle to be served; ids and fields that would forge a row are refused; the file holds the observation
# time; an installed copy carries the helper scripts; concurrent refreshes leave one whole line.
# The handle is read from PLUGLY_TERMINAL_HANDLE first, else ORCA_TERMINAL_HANDLE, in the pid check too: both
# orders, empty, hostile and repeated names.
# Fake /proc via CM_PROC_ROOT, as in test/live-agent.sh. Touches nothing outside a mktemp dir.
#
#   scripts/test/lane-handles.sh       # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
SKILL="$(cd "$SCRIPTS/.." && pwd)"
export CM_CONFIG="$HERE/fixtures/config.test.yaml"
unset CM_ORG CM_REPO CM_PROJECT CM_OWNER_NAME CM_OWNER_ID CM_TZ CM_TZ_LABEL CM_EXCLUDE_REPOS CM_PATH_MATCH CM_SELF_WORKTREE CM_SSH_TARGET CM_LEDGER CM_LANE_HANDLES CM_LIVE_AGENT
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-lane-handles.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }
export HOME="$ROOT/home" CM_HOME="$ROOT/cm" CM_TEST=1
mkdir -p "$HOME" "$CM_HOME"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { if (eval "$2"); then ok "$1"; else bad "$1"; fi; }

LH="$SCRIPTS/lane-handles.sh"
WT="$ROOT/wt/lane-a"; WT2="$ROOT/wt/lane-b"
mkdir -p "$WT" "$WT2"
P="$ROOT/proc"
PSTATE=S; PTTY=34816
mkproc() {
  local pid="$1" cwd="$2" env="$3"; shift 3
  mkdir -p "$P/$pid"
  printf '%s (claude) %s 1 %s %s %s -1 4194560\n' "$pid" "$PSTATE" "$pid" "$pid" "$PTTY" > "$P/$pid/stat"
  ln -sfn "$cwd" "$P/$pid/cwd"
  printf '%s\0' "$@" > "$P/$pid/cmdline"
  if [ -n "$env" ]; then printf 'HOME=/h/x\0%s\0' "$env" > "$P/$pid/environ"; else printf 'HOME=/h/x\0' > "$P/$pid/environ"; fi
}
reset_proc() { rm -rf -- "${P:?}"; mkdir -p "$P"; }
export CM_PROC_ROOT="$P"   # the reader's pid check (_cm_lane_agent_alive) reads the same fake /proc as live-agent.sh
lh() { CM_PROC_ROOT="$P" "$LH" "$@"; }
file() { printf '%s/lanes/%s/handle' "$CM_HOME" "$1"; }
field() { cut -f"$2" "$(file "$1")" 2>/dev/null; }
mkledger() {
  jq -n --arg a "$WT" --arg b "$WT2" '{schema: "concertmaster.ledger/v1", updatedAt: "2000-01-01T00:00:00Z",
    workers: {"w-one": {lane: "lane-a", host: "local", agent: "claude", path: $a, state: "running", terminal: "term_stale"},
              "w-two": {lane: "lane-b", host: "local", agent: "claude", path: $b, state: "running", terminal: "term_dev_old"}}}' > "$CM_HOME/ledger.json"
}
# an old file: the same line with a written-at far in the past
age_file() { local f; f="$(file "$1")"; printf '%s\t%s\t%s\t%s\t2020-01-01T00:00:00Z\n' "$(field "$1" 1)" local claude - > "$f"; }
. "$SCRIPTS/lib.sh"

echo "--- refresh: the file comes from the live process"
mkledger; reset_proc
mkproc 101 "$WT" "ORCA_TERMINAL_HANDLE=term_live_1" /usr/local/bin/claude
OUT="$(lh)"; RC=$?
check "live agent: the file holds its handle (not the ledger's stale one), exit 0" '[ "$RC" = 0 ] && [ "$(field w-one 1)" = term_live_1 ]'
check "the line is handle, host, agent, pid, written-at UTC (5 tab fields)" '[ "$(awk -F"\t" "{print NF}" "$(file w-one)")" = 5 ] && [ "$(field w-one 2)" = local ] && [ "$(field w-one 3)" = claude ] && [ "$(field w-one 4)" = 101 ] && field w-one 5 | grep -Eq "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"'
check "one line, mode 600, nothing in it but the five fields (no token-shaped text)" '[ "$(wc -l < "$(file w-one)" | tr -d " ")" = 1 ] && [ "$(stat -c %a "$(file w-one)" 2>/dev/null || stat -f %Lp "$(file w-one)")" = 600 ] && ! grep -Eqi "sbp_|sk_|ghp_|eyJ|bearer" "$(file w-one)"'
check "the table row says refreshed and names the ledger terminal brought into line" 'grep -Eq "^w-one	term_live_1	refreshed	.*ledger terminal term_stale brought to term_live_1" <<<"$OUT"'
check "the ledger terminal now matches the live handle" '[ "$(jq -r ".workers[\"w-one\"].terminal" "$CM_HOME/ledger.json")" = term_live_1 ]'
check "the other lane (no agent) is marked dead, not removed" '[ "$(field w-two 1)" = "-" ] && grep -Eq "^w-two	-	none" <<<"$OUT"'

echo "--- reader: a stale ledger handle is ignored"
mkledger
cm_lane_handle w-one 2>/dev/null >"$ROOT/out"; RC=$?
check "file fresh: the reader prints the LIVE handle, not the ledger's term_stale" '[ "$RC" = 0 ] && [ "$(cat "$ROOT/out")" = term_live_1 ]'
check "the same through the CLI: lane-handles.sh --get" '[ "$(lh --get w-one 2>/dev/null)" = term_live_1 ]'

echo "--- no live agent: marked dead, never the ledger handle"
reset_proc; mkledger
lh --quiet
cm_lane_handle w-one 2>"$ROOT/err" >"$ROOT/out"; RC=$?
check "no agent: the file says dead and the reader refuses (exit 1), prints nothing" '[ "$(field w-one 1)" = "-" ] && [ "$RC" = 1 ] && [ ! -s "$ROOT/out" ] && grep -q "no usable live agent" "$ROOT/err"'
check "...even though the ledger still holds a handle for the lane (no fallback to it)" '[ "$(jq -r ".workers[\"w-one\"].terminal" "$CM_HOME/ledger.json")" = term_stale ]'
mkproc 102 "$WT" "ORCA_TERMINAL_HANDLE=term_back" claude
lh --quiet
check "the agent comes back: the next refresh replaces the dead mark" '[ "$(cm_lane_handle w-one 2>/dev/null)" = term_back ]'

echo "--- duplicates, hand-started agents, inherited handles"
reset_proc; mkledger
mkproc 103 "$WT" "ORCA_TERMINAL_HANDLE=term_a" claude
mkproc 104 "$WT" "ORCA_TERMINAL_HANDLE=term_b" claude
OUT="$(lh)"
check "two agents with different handles: marked dead (send to neither)" '[ "$(field w-one 1)" = "-" ] && grep -Eq "^w-one	-	duplicate" <<<"$OUT"'
reset_proc; mkledger
mkproc 105 "$WT" "ORCA_TERMINAL_HANDLE=term_a" claude
mkproc 106 "$WT" "" claude
OUT="$(lh)"
check "an Orca agent plus a hand-started one (no handle): marked dead" '[ "$(field w-one 1)" = "-" ] && grep -Eq "^w-one	-	duplicate" <<<"$OUT"'
reset_proc; mkledger
mkproc 107 "$WT" "" claude
OUT="$(lh)"
check "a lone hand-started agent has no handle to send to: marked dead (no-handle)" '[ "$(field w-one 1)" = "-" ] && grep -Eq "^w-one	-	no-handle" <<<"$OUT"'
reset_proc; mkledger
mkproc 108 "$WT" "ORCA_TERMINAL_HANDLE=term_dev_old" claude
OUT="$(lh)"
check "a live handle that is ANOTHER lane's ledger terminal (an inherited variable): marked dead, ledger untouched" '[ "$(field w-one 1)" = "-" ] && grep -Eq "^w-one	-	held" <<<"$OUT" && [ "$(jq -r ".workers[\"w-one\"].terminal" "$CM_HOME/ledger.json")" = term_stale ]'

echo "--- an undecidable check leaves the file; a stale file is never trusted"
reset_proc; mkledger
mkproc 109 "$WT" "ORCA_TERMINAL_HANDLE=term_keep" claude
lh --quiet
before="$(cat "$(file w-one)")"
OUT="$(CM_PROC_ROOT="$ROOT/no-such-proc" "$LH")"
check "no /proc (live-agent exit 3): the file is left exactly as it was, row says unknown" '[ "$(cat "$(file w-one)")" = "$before" ] && grep -Eq "^w-one	.*	unknown" <<<"$OUT"'
age_file w-one
CM_PROC_ROOT="$ROOT/no-such-proc" cm_lane_handle w-one 2>"$ROOT/err" >"$ROOT/out"; RC=$?
check "stale file + the live check cannot run: no send (exit 3), nothing printed, NOT the ledger handle" '[ "$RC" = 3 ] && [ ! -s "$ROOT/out" ] && grep -q "no fresh handle" "$ROOT/err"'
age_file w-one
CM_PROC_ROOT="$P" cm_lane_handle w-one 2>"$ROOT/err" >"$ROOT/out"; RC=$?
check "stale file + agent still there: re-checked first, the reader prints the fresh live handle" '[ "$RC" = 0 ] && [ "$(cat "$ROOT/out")" = term_keep ] && field w-one 5 | grep -vq "^2020" && grep -q "re-checking" "$ROOT/err"'
age_file w-one
reset_proc
CM_PROC_ROOT="$P" cm_lane_handle w-one 2>/dev/null >"$ROOT/out"; RC=$?
check "stale file + the agent is gone: re-checked, marked dead, no send (exit 1)" '[ "$RC" = 1 ] && [ ! -s "$ROOT/out" ] && [ "$(field w-one 1)" = "-" ]'
printf 'term_x\tlocal\tclaude\t1\tnot-a-date\n' > "$(file w-one)"
CM_PROC_ROOT="$P" cm_lane_handle w-one 2>/dev/null >"$ROOT/out"; RC=$?
check "a file whose written-at does not parse is treated as stale, never trusted" '[ "$RC" = 1 ] && [ "$(cat "$ROOT/out" 2>/dev/null)" != term_x ]'
printf 'term_x\tlocal\tclaude\t1\t2099-01-01T00:00:00Z\n' > "$(file w-one)"
CM_PROC_ROOT="$P" cm_lane_handle w-one 2>/dev/null >"$ROOT/out"; RC=$?
check "a file dated in the future is stale too" '[ "$(cat "$ROOT/out" 2>/dev/null)" != term_x ]'

echo "--- file missing or empty: re-checked, never the ledger handle"
rm -rf -- "${CM_HOME:?}/lanes"; mkledger; reset_proc
CM_PROC_ROOT="$P" cm_lane_handle w-one 2>"$ROOT/err" >"$ROOT/out"; RC=$?
check "missing file, no agent: re-checked, marked dead, refused (exit 1), NOT the ledger term_stale" '[ "$RC" = 1 ] && [ ! -s "$ROOT/out" ] && [ "$(field w-one 1)" = "-" ] && grep -q "re-checking" "$ROOT/err"'
rm -rf -- "${CM_HOME:?}/lanes"; mkproc 150 "$WT" "ORCA_TERMINAL_HANDLE=term_found" claude
CM_PROC_ROOT="$P" cm_lane_handle w-one 2>"$ROOT/err" >"$ROOT/out"; RC=$?
check "missing file, agent alive: the re-check finds it and the reader prints the LIVE handle" '[ "$RC" = 0 ] && [ "$(cat "$ROOT/out")" = term_found ]'
rm -rf -- "${CM_HOME:?}/lanes"; mkdir -p "$CM_HOME/lanes/w-one"; : > "$(file w-one)"; reset_proc
CM_PROC_ROOT="$P" cm_lane_handle w-one 2>"$ROOT/err" >"$ROOT/out"; RC=$?
check "empty file, no agent: re-checked and refused (exit 1), NOT the ledger handle" '[ "$RC" = 1 ] && [ ! -s "$ROOT/out" ] && [ "$(field w-one 1)" = "-" ]'
rm -rf -- "${CM_HOME:?}/lanes"
CM_PROC_ROOT="$ROOT/no-such-proc" cm_lane_handle w-one 2>"$ROOT/err" >"$ROOT/out"; RC=$?
check "never checked + the live check cannot run (exit 3, as with ssh down): refused (exit 3), every call, NOT the ledger handle" '[ "$RC" = 3 ] && [ ! -s "$ROOT/out" ] && grep -q "no fresh handle" "$ROOT/err"'
CM_PROC_ROOT="$ROOT/no-such-proc" cm_lane_handle w-one 2>/dev/null >"$ROOT/out"; RC=$?
check "...and again on the next call: nothing is cached as trusted" '[ "$RC" = 3 ] && [ ! -s "$ROOT/out" ] && [ ! -e "$(file w-one)" ]'
cm_lane_handle no-such-lane 2>"$ROOT/err" >"$ROOT/out"; RC=$?
check "a lane the ledger does not hold: nothing to re-check, exit 3, nothing printed" '[ "$RC" = 3 ] && [ ! -s "$ROOT/out" ]'
cm_lane_handle '../etc' 2>/dev/null >"$ROOT/out"; RC=$?
check "a lane name that is not a plain token is refused (exit 2)" '[ "$RC" = 2 ] && [ ! -s "$ROOT/out" ]'
cm_lane_handle 2>/dev/null; RC=$?
check "no lane: usage, exit 2" '[ "$RC" = 2 ]'

echo "--- lane lookup by path, writer guards, dry run"
mkledger
check "cm_lane_for_path finds the one lane (trailing slash normalised)" '[ "$(cm_lane_for_path local "$WT/")" = w-one ]'
check "cm_lane_for_path: no worker there, nothing" '! cm_lane_for_path local /no/such/wt >/dev/null'
jq --arg a "$WT" '.workers["w-twin"] = {lane: "twin", host: "local", path: $a, state: "running"}' "$CM_HOME/ledger.json" > "$ROOT/l.json" && mv "$ROOT/l.json" "$CM_HOME/ledger.json"
check "cm_lane_for_path: two workers at one path, nothing guessed" '! cm_lane_for_path local "$WT" >/dev/null'
mkledger
jq '.workers["w-one"].state = "gone"' "$CM_HOME/ledger.json" > "$ROOT/l.json" && mv "$ROOT/l.json" "$CM_HOME/ledger.json"
check "cm_lane_for_path ignores a dead record" '! cm_lane_for_path local "$WT" >/dev/null'
mkledger
cm_lane_handle_write w-one 'x;y' local claude 1 2>/dev/null; RC=$?
check "writer refuses a handle with a shell metacharacter" '[ "$RC" = 1 ]'
cm_lane_handle_write '../x' term_a local claude 1 2>/dev/null; RC=$?
check "writer refuses a lane that is not a plain token" '[ "$RC" = 1 ] && [ ! -e "$CM_HOME/lanes/../x" ]'
rm -rf -- "${CM_HOME:?}/lanes"; reset_proc; mkproc 110 "$WT" "ORCA_TERMINAL_HANDLE=term_dry" claude
OUT="$(lh --dry-run)"
check "--dry-run reports the refresh, writes no file and leaves the ledger alone" 'grep -q "refreshed" <<<"$OUT" && [ ! -e "$CM_HOME/lanes" ] && [ "$(jq -r ".workers[\"w-one\"].terminal" "$CM_HOME/ledger.json")" = term_stale ]'
OUT="$(lh --worker w-two)"
check "--worker limits the run to one worker" '[ "$(printf "%s\n" "$OUT" | wc -l | tr -d " ")" = 1 ] && grep -q "^w-two" <<<"$OUT"'
lh --bogus >/dev/null 2>&1; RC=$?
check "unknown flag: exit 2" '[ "$RC" = 2 ]'
rm -rf -- "${CM_HOME:?}/lanes"
mv "$CM_HOME/ledger.json" "$CM_HOME/ledger.off"
lh >/dev/null 2>&1; RC=$?
check "no ledger: exit 1, nothing written" '[ "$RC" = 1 ] && [ ! -e "$CM_HOME/lanes" ]'
mv "$CM_HOME/ledger.off" "$CM_HOME/ledger.json"
rm -rf -- "${CM_HOME:?}/lanes"
jq --arg a "$WT2" '.workers["W-ONE"] = {host: "local", path: $a, state: "running"}' "$CM_HOME/ledger.json" > "$ROOT/l.json" && mv "$ROOT/l.json" "$CM_HOME/ledger.json"
OUT="$(lh)"
check "two worker ids that differ only by case (one directory on a case-insensitive file system): ambiguous, both marked dead" 'printf "%s\n" "$OUT" | grep -Ec "	ambiguous	" | grep -qx 2 && [ "$(field w-one 1)" = "-" ]'

echo "--- real-ledger shapes: a lane is a group of workers; colons in lane names; dead records"
mkledger; rm -rf -- "${CM_HOME:?}/lanes"; reset_proc
jq --arg a "$WT2" '.workers["w-two"].lane = "epic:project-x" | .workers["w-one"].lane = "epic:project-x"' "$CM_HOME/ledger.json" > "$ROOT/l.json" && mv "$ROOT/l.json" "$CM_HOME/ledger.json"
mkproc 130 "$WT" "ORCA_TERMINAL_HANDLE=term_grp_a" claude
mkproc 131 "$WT2" "ORCA_TERMINAL_HANDLE=term_grp_b" claude
OUT="$(lh)"
check "two workers in ONE lane (colon in its name): each has its own file and handle, nothing ambiguous or invalid" '[ "$(field w-one 1)" = term_grp_a ] && [ "$(field w-two 1)" = term_grp_b ] && ! grep -Eq "	(ambiguous|invalid)	" <<<"$OUT"'
check "...and --get takes the worker id, so a child spawned into an occupied lane is reachable" '[ "$(lh --get w-two 2>/dev/null)" = term_grp_b ]'

echo "--- review fixes: dead record, shared handle"
mkledger; rm -rf -- "${CM_HOME:?}/lanes"
jq '.workers["w-one"].state = "gone" | .workers["w-one"].terminal = "term_OLD_DEAD"' "$CM_HOME/ledger.json" > "$ROOT/l.json" && mv "$ROOT/l.json" "$CM_HOME/ledger.json"
cm_lane_handle w-one 2>/dev/null >"$ROOT/out"; RC=$?
check "missing file + the worker's record is DEAD (gone) and still holds a handle: that handle is never used (exit 3)" '[ "$RC" = 3 ] && [ ! -s "$ROOT/out" ]'
mkledger; rm -rf -- "${CM_HOME:?}/lanes"; reset_proc
jq 'del(.workers[].host)' "$CM_HOME/ledger.json" > "$ROOT/l.json" && mv "$ROOT/l.json" "$CM_HOME/ledger.json"
mkproc 120 "$WT" "ORCA_TERMINAL_HANDLE=term_shared" claude
mkproc 121 "$WT2" "ORCA_TERMINAL_HANDLE=term_shared" claude
OUT="$(lh)"
check "two lanes (rows with no host field) whose agents carry ONE handle: both marked dead (held), neither can be sent to" '[ "$(field w-one 1)" = "-" ] && [ "$(field w-two 1)" = "-" ] && [ "$(printf "%s\n" "$OUT" | grep -c "	held	")" = 2 ]'
reset_proc; mkledger; rm -rf -- "${CM_HOME:?}/lanes"
mkproc 122 "$WT" "ORCA_TERMINAL_HANDLE=term_mine" claude
jq '.workers["other-lane"] = {host: "local", state: "running"}' "$CM_HOME/ledger.json" > "$ROOT/l.json" && mv "$ROOT/l.json" "$CM_HOME/ledger.json"   # a live record that is not looked at (no path)
mkdir -p "$CM_HOME/lanes/other-lane"; printf 'term_mine\tlocal\tclaude\t-\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$CM_HOME/lanes/other-lane/handle"
OUT="$(lh --worker w-one)"
check "--lane: a handle another lane's FRESH file already holds is held, even though that lane is not in this run" '[ "$(field w-one 1)" = "-" ] && grep -q "fresh handle file" <<<"$OUT"'
reset_proc; mkledger; rm -rf -- "${CM_HOME:?}/lanes"
# (a second pass of the lane-in-this-run rule: a worker looked at in this run is judged by this run, not by its old file)
mkproc 132 "$WT" "ORCA_TERMINAL_HANDLE=term_order" claude
mkdir -p "$CM_HOME/lanes/w-two"; printf 'term_order\tlocal\tclaude\t9\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$CM_HOME/lanes/w-two/handle"
OUT="$(lh)"
check "a fresh file of a worker that IS in this run does not decide: w-one refreshed whatever the ledger order" '[ "$(field w-one 1)" = term_order ] && grep -Eq "^w-one	term_order	refreshed" <<<"$OUT"'
echo "--- concurrent refresh"
mkledger; rm -rf -- "${CM_HOME:?}/lanes"; reset_proc
mkproc 111 "$WT" "ORCA_TERMINAL_HANDLE=term_race" claude
mkproc 112 "$WT2" "ORCA_TERMINAL_HANDLE=term_race2" claude
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do lh --quiet & done
bad_reads=0
for _ in $(seq 1 60); do
  for l in w-one w-two; do
    if [ -s "$(file "$l")" ]; then
      n="$(awk -F'\t' 'END { print NR ":" NF }' "$(file "$l")" 2>/dev/null)"
      [ "$n" = "1:5" ] || bad_reads=$((bad_reads + 1))
    fi
  done
done
wait
check "12 parallel refreshes: every read of the file during the race was one whole 5-field line" '[ "$bad_reads" = 0 ]'
check "...and the end state is the live handle for each lane, no temp files left behind" '[ "$(field w-one 1)" = term_race ] && [ "$(field w-two 1)" = term_race2 ] && [ -z "$(find "$CM_HOME/lanes" -name ".handle.*" 2>/dev/null)" ]'

# a finished (gone) record of another worker that still carries the live handle does not hold it
mkledger; reset_proc; rm -rf -- "${CM_HOME:?}/lanes"
jq '.workers["w-old"] = {lane: "lane-a", host: "local", state: "gone", terminal: "term_fin"}' "$CM_HOME/ledger.json" > "$ROOT/l.json" && mv "$ROOT/l.json" "$CM_HOME/ledger.json"
mkproc 140 "$WT" "ORCA_TERMINAL_HANDLE=term_fin" claude
OUT="$(lh)"
check "a finished record of another worker holds no handle: the live worker is refreshed, not held" '[ "$(field w-one 1)" = term_fin ] && grep -Eq "^w-one	term_fin	refreshed" <<<"$OUT"'

echo "--- a failed write never leaves the old handle to be served"
mkledger; rm -rf -- "${CM_HOME:?}/lanes"; reset_proc
mkproc 160 "$WT" "ORCA_TERMINAL_HANDLE=tFirst" claude
lh --quiet
check "setup: the first run wrote tFirst" '[ "$(field w-one 1)" = tFirst ]'
reset_proc
chmod 555 "$CM_HOME/lanes/w-one"
if [ -w "$CM_HOME/lanes/w-one" ]; then
  echo "SKIP failed-write cases: this user can write to a mode 555 directory (root)"
else
  OUT="$(lh)"
  check "a run that found no agent but could not write: the row says failed" 'grep -Eq "^w-one	-	failed" <<<"$OUT"'
  CM_PROC_ROOT="$ROOT/no-such-proc" cm_lane_handle w-one 2>"$ROOT/err" >"$ROOT/out"; RC=$?
  check "...and --get does NOT return the old tFirst (exit 3, nothing printed)" '[ "$RC" = 3 ] && [ ! -s "$ROOT/out" ]'
  CM_PROC_ROOT="$P" cm_lane_handle w-one 2>/dev/null >"$ROOT/out"; RC=$?
  check "...not even when the re-check can run but cannot write" '[ "$(cat "$ROOT/out")" != tFirst ] && [ "$RC" != 0 ]'
  chmod 755 "$CM_HOME/lanes/w-one"
  mkproc 161 "$WT" "ORCA_TERMINAL_HANDLE=tSecond" claude
  CM_PROC_ROOT="$P" cm_lane_handle w-one 2>/dev/null >"$ROOT/out"; RC=$?
  check "the directory is writable again: the next read re-checks, writes, and the failure marker is cleared" '[ "$RC" = 0 ] && [ "$(cat "$ROOT/out")" = tSecond ] && [ ! -e "$CM_HOME/lanes/.failed/w-one" ]'
fi
chmod 755 "$CM_HOME/lanes/w-one" 2>/dev/null || true
mkledger; rm -rf -- "${CM_HOME:?}/lanes"; reset_proc
mkproc 162 "$WT" "ORCA_TERMINAL_HANDLE=tOld" claude
lh --quiet
mkdir -p "$CM_HOME/lanes/.failed"; : > "$CM_HOME/lanes/.failed/w-one"
reset_proc
CM_PROC_ROOT="$P" cm_lane_handle w-one 2>/dev/null >"$ROOT/out"; RC=$?
check "a failure marker makes a fresh-looking file untrusted: re-checked (no agent now), not tOld" '[ "$(cat "$ROOT/out")" != tOld ] && [ "$RC" = 1 ] && [ ! -e "$CM_HOME/lanes/.failed/w-one" ]'

echo "--- ids and fields that would forge a row are refused"
reset_proc; rm -rf -- "${CM_HOME:?}/lanes"
jq -n --arg a "$WT" --arg b "$WT2" '{workers: {"x\nw-b": {host: "local", path: $a, state: "running"},
    "w-b": {host: "local", path: $b, state: "running"}}}' > "$CM_HOME/ledger.json"
mkproc 170 "$WT" "ORCA_TERMINAL_HANDLE=tEvil" claude
OUT="$(lh)"
check "a ledger key with a newline is refused, not split into a row for w-b" 'grep -Eq "^\"x\\\\nw-b\"	-	invalid" <<<"$OUT" && [ "$(field w-b 1)" = "-" ]'
check "...and w-b never holds the foreign agent's handle" '! grep -rq tEvil "$CM_HOME/lanes"'
CM_PROC_ROOT="$P" cm_lane_handle w-b 2>/dev/null >"$ROOT/out"; RC=$?
check "...--get w-b is refused (exit 1)" '[ "$RC" = 1 ] && [ ! -s "$ROOT/out" ]'
rm -rf -- "${CM_HOME:?}/lanes"
jq -n --arg a "$WT" --arg b "$WT2" '{workers: {"w-nl": {host: "local", path: ($a + "\nw-b\u001ftEvil"), state: "running"},
    "w-b": {host: "local", path: $b, state: "running"}}}' > "$CM_HOME/ledger.json"
OUT="$(lh)"
check "a path with a newline or a unit separator is refused too" 'grep -Eq "^\"w-nl\"	-	invalid" <<<"$OUT" && [ ! -e "$(file w-nl)" ] && [ "$(field w-b 1)" = "-" ]'
rm -rf -- "${CM_HOME:?}/lanes"
jq -n --arg a "$WT" '{workers: {".dot": {host: "local", path: $a, state: "running"}, "-lead": {host: "local", path: $a, state: "running"}}}' > "$CM_HOME/ledger.json"
OUT="$(lh)"
check "a leading dot is refused, a leading dash is a fine id" 'grep -Eq "^\".dot\"	-	invalid" <<<"$OUT" && [ ! -e "$CM_HOME/lanes/.dot" ]'

echo "--- the file holds the time the agent was SEEN, and an older look never overwrites a newer one"
mkledger; rm -rf -- "${CM_HOME:?}/lanes"; reset_proc
printf '#!/usr/bin/env bash\nif [ "${1##*/}" = lane-b ]; then sleep 3; fi\nprintf "7\\tterm_slow\\tclaude\\n"\n' > "$ROOT/slow-agent"; chmod +x "$ROOT/slow-agent"
t0="$(date +%s)"; CM_LIVE_AGENT="$ROOT/slow-agent" lh --quiet; t1="$(date +%s)"
at_ts="$(jq -rn --arg t "$(field w-one 5)" '$t | fromdateiso8601')"
check "setup: the run took at least 3 s (the second worker was slow)" '[ $((t1 - t0)) -ge 3 ]'
check "the first worker's file is stamped with when it was observed, not when phase 3 wrote it" '[ $((t1 - at_ts)) -ge 2 ]'
rm -rf -- "${CM_HOME:?}/lanes"
cm_lane_handle_write w-one tNewest local claude 1
cm_lane_handle_write w-one tOlderLook local claude 2 2020-01-01T00:00:00Z; RC=$?
check "a write carrying an OLDER observation does not replace a newer file, and says so (rc 3, not a failure: no failure marker)" '[ "$(field w-one 1)" = tNewest ] && [ "$RC" = 3 ] && [ ! -e "$CM_HOME/lanes/.failed/w-one" ]'
cm_lane_handle_write w-one tLater local claude 3 2099-01-01T00:00:00Z
check "...a write carrying a later one does" '[ "$(field w-one 1)" = tLater ]'
printf 'tFuture\tlocal\tclaude\t1\t2099-01-01T00:00:00Z\n' > "$(file w-one)"
cm_lane_handle_write w-one tReal local claude 4
check "a clock-skewed file dated in the far future never blocks a real write" '[ "$(field w-one 1)" = tReal ]'
cm_lane_handle_write w-one tBad local claude 5 yesterday; RC=$?
check "a non-time observed-at is refused" '[ "$RC" = 1 ]'

echo "--- the reader and the ledger: finished workers keep no file; dead records hold no handle"
mkledger; rm -rf -- "${CM_HOME:?}/lanes"; reset_proc
mkdir -p "$CM_HOME/lanes/w-gone" "$CM_HOME/lanes/w-nobody"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'term_g\tlocal\tclaude\t1\t%s\n' "$now" > "$CM_HOME/lanes/w-gone/handle"
printf 'term_n\tlocal\tclaude\t1\t%s\n' "$now" > "$CM_HOME/lanes/w-nobody/handle"
jq '.workers["w-gone"] = {host: "local", path: "/x", state: "gone"}' "$CM_HOME/ledger.json" > "$ROOT/l.json" && mv "$ROOT/l.json" "$CM_HOME/ledger.json"
OUT="$(lh --dry-run)"
check "--dry-run names the files of finished workers and removes none" 'grep -Eq "^w-gone	-	gone" <<<"$OUT" && [ -e "$CM_HOME/lanes/w-gone/handle" ]'
OUT="$(lh)"
check "a full run removes the handle file of a gone worker and of an id the ledger never held" '[ ! -e "$CM_HOME/lanes/w-gone/handle" ] && [ ! -e "$CM_HOME/lanes/w-nobody/handle" ] && grep -Eq "^w-nobody	-	gone" <<<"$OUT"'
cm_lane_handle w-gone 2>/dev/null >"$ROOT/out"; RC=$?
check "...so a send to the finished worker is refused (exit 3)" '[ "$RC" = 3 ] && [ ! -s "$ROOT/out" ]'
mkledger
jq '.workers["w-old"] = {host: "local", state: "gone", terminal: "term_held"}' "$CM_HOME/ledger.json" > "$ROOT/l.json" && mv "$ROOT/l.json" "$CM_HOME/ledger.json"
cm_worker_set_handle w-one term_held 2>/dev/null; RC=$?
check "cm_worker_set_handle: a dead record no longer holds a handle (same rule as the lane refresh)" '[ "$RC" = 0 ] && [ "$(jq -r ".workers[\"w-one\"].terminal" "$CM_HOME/ledger.json")" = term_held ]'
jq '.workers["w-two"].terminal = "term_live_other"' "$CM_HOME/ledger.json" > "$ROOT/l.json" && mv "$ROOT/l.json" "$CM_HOME/ledger.json"
cm_worker_set_handle w-one term_live_other 2>/dev/null; RC=$?
check "...a LIVE record still does (exit 4)" '[ "$RC" = 4 ]'
mkledger; reset_proc
OUT="$(CM_PROC_ROOT="$ROOT/no-such-proc" "$LH")"
check "an undecidable check shows no handle in the table (the ledger terminal is not a usable handle)" 'grep -Eq "^w-one	-	unknown" <<<"$OUT" && ! grep -q term_stale <<<"$OUT"'

mkledger; rm -rf -- "${CM_HOME:?}/lanes"; reset_proc
mkproc 191 "$WT" "ORCA_TERMINAL_HANDLE=term_shared" claude
mkdir -p "$CM_HOME/lanes/w-old"; printf 'term_shared\tlocal\tclaude\t1\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$CM_HOME/lanes/w-old/handle"
jq '.workers["w-old"] = {host: "local", path: "/x", state: "gone"}' "$CM_HOME/ledger.json" > "$ROOT/l.json" && mv "$ROOT/l.json" "$CM_HOME/ledger.json"
OUT="$(lh --worker w-one)"
check "the fresh file of a GONE worker holds nothing: the live worker is refreshed, not held (also under --worker)" '[ "$(field w-one 1)" = term_shared ] && grep -Eq "^w-one	term_shared	refreshed" <<<"$OUT"'
mkdir -p "$CM_HOME/lanes/.failed"; : > "$CM_HOME/lanes/.failed/w-old"
lh --quiet
check "a full run removes the failure marker of a finished worker with its file" '[ ! -e "$CM_HOME/lanes/.failed/w-old" ] && [ ! -e "$CM_HOME/lanes/w-old/handle" ]'

echo "--- a fresh file is not enough: the agent behind it must still hold the terminal"
mkledger; rm -rf -- "${CM_HOME:?}/lanes"; reset_proc
cm_lane_handle_write w-one T1 local claude 99999
cm_lane_handle w-one 2>"$ROOT/err" >"$ROOT/out"; RC=$?
check "fresh file, its pid does not exist: treated as stale, re-checked, refused (exit 1), NOT T1" '[ "$RC" = 1 ] && [ ! -s "$ROOT/out" ] && grep -q "agent pid 99999 is gone" "$ROOT/err" && [ "$(field w-one 1)" = "-" ]'
rm -rf -- "${CM_HOME:?}/lanes"; mkproc 200 "$WT" "ORCA_TERMINAL_HANDLE=T2" claude
cm_lane_handle_write w-one T2 local claude 200
cm_lane_handle w-one 2>"$ROOT/err" >"$ROOT/out"; RC=$?
check "fresh file, its pid alive and holding the handle: served as is, no re-check" '[ "$RC" = 0 ] && [ "$(cat "$ROOT/out")" = T2 ] && ! grep -q "re-checking" "$ROOT/err"'
reset_proc; mkproc 200 "$WT" "ORCA_TERMINAL_HANDLE=T_OTHER" claude
cm_lane_handle w-one 2>"$ROOT/err" >"$ROOT/out"; RC=$?
check "fresh file, the pid now holds ANOTHER terminal (pid reuse): stale, re-checked, the live handle served" '[ "$RC" = 0 ] && [ "$(cat "$ROOT/out")" = T_OTHER ] && grep -q "does not carry terminal T2" "$ROOT/err"'
rm -rf -- "${CM_HOME:?}/lanes"; reset_proc
cm_lane_handle_write w-one T3 host-b claude 99999
cm_lane_handle w-one 2>/dev/null >"$ROOT/out"; RC=$?
check "a file for a REMOTE host is not judged by the local /proc" '[ "$RC" = 0 ] && [ "$(cat "$ROOT/out")" = T3 ]'
cm_lane_handle_write w-one T4 local claude -
cm_lane_handle w-one 2>/dev/null >"$ROOT/out"; RC=$?
check "a file with no pid (the dead mark path, or a screen-vouched write) is served while fresh" '[ "$RC" = 0 ] && [ "$(cat "$ROOT/out")" = T4 ]'

echo "--- a handle starting with a dash is never written, served or taken from a process"
rm -rf -- "${CM_HOME:?}/lanes"; mkledger; reset_proc
cm_lane_handle_write w-one --json local claude 1 2>/dev/null; RC=$?
check "the writer refuses --json" '[ "$RC" = 1 ] && [ ! -e "$(file w-one)" ]'
cm_lane_handle_write w-one -x local claude 1 2>/dev/null; RC=$?
check "the writer refuses -x too" '[ "$RC" = 1 ] && [ ! -e "$(file w-one)" ]'
cm_lane_handle_write w-one - local - - 2>/dev/null; RC=$?
check "...but the dead mark (a lone dash) is still written" '[ "$RC" = 0 ] && [ "$(field w-one 1)" = "-" ]'
mkdir -p "$CM_HOME/lanes/w-one"; printf -- '--json\tlocal\tclaude\t-\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$(file w-one)"
cm_lane_handle w-one 2>/dev/null >"$ROOT/out"; RC=$?
check "the reader never serves a hand-written --json: bad, re-checked, refused" '[ "$(cat "$ROOT/out")" != --json ] && [ "$RC" != 0 ]'
rm -rf -- "${CM_HOME:?}/lanes"; mkproc 201 "$WT" "ORCA_TERMINAL_HANDLE=-" claude
OUT="$(lh)"
check "live-agent.sh: ORCA_TERMINAL_HANDLE=- in an agent's environment is no handle (marked dead, ledger terminal not set to -)" 'grep -Eq "^w-one	-	no-handle" <<<"$OUT" && [ "$(jq -r ".workers[\"w-one\"].terminal" "$CM_HOME/ledger.json")" != "-" ]'
cm_worker_set_handle w-one -x 2>/dev/null; RC=$?
check "cm_worker_set_handle refuses a dash-led handle" '[ "$RC" = 1 ]'

echo "--- lane directories are 0700 and a symlinked one is refused"
rm -rf -- "${CM_HOME:?}/lanes"; mkledger; reset_proc
cm_lane_handle_write w-one T5 local claude -
check "lanes/ and the lane directory are created mode 700" '[ "$(stat -c %a "$CM_HOME/lanes" 2>/dev/null || stat -f %Lp "$CM_HOME/lanes")" = 700 ] && [ "$(stat -c %a "$CM_HOME/lanes/w-one" 2>/dev/null || stat -f %Lp "$CM_HOME/lanes/w-one")" = 700 ]'
rm -rf -- "${CM_HOME:?}/lanes"; mkdir -p "$CM_HOME/lanes" "$ROOT/elsewhere"; ln -s "$ROOT/elsewhere" "$CM_HOME/lanes/w-one"
cm_lane_handle_write w-one T7 local claude - 2>"$ROOT/err"; RC=$?
check "a symlinked lanes/<id> is refused: nothing written through the link" '[ "$RC" = 1 ] && [ -z "$(ls -A "$ROOT/elsewhere")" ] && grep -q "through a symlink" "$ROOT/err"'
cm_lane_handle w-one 2>/dev/null >"$ROOT/out"; RC=$?
check "...and the reader refuses it too (nothing printed)" '[ "$RC" != 0 ] && [ ! -s "$ROOT/out" ]'
rm -f -- "${CM_HOME:?}/lanes/w-one"; rm -rf -- "${CM_HOME:?}/lanes"

echo "--- review round 3: reasons, held_by, symlinks"
rm -rf -- "${CM_HOME:?}/lanes"; mkledger; reset_proc
mkproc 210 "$WT" "ORCA_TERMINAL_HANDLE=T_unr" claude
cm_lane_handle_write w-one T_unr local claude 210
chmod 000 "$P/210/environ"
if [ -r "$P/210/environ" ]; then echo "SKIP unreadable-environ case: this user reads a mode 000 file (root)"; else
  cm_lane_handle w-one 2>"$ROOT/err" >/dev/null
  check "an unreadable environ is named as such, not as a gone pid" 'grep -q "cannot be inspected (environ unreadable)" "$ROOT/err" && ! grep -q "is gone" "$ROOT/err"'
fi
chmod 644 "$P/210/environ"
reset_proc; mkproc 211 "$WT" "ORCA_TERMINAL_HANDLE=T_else" claude
cm_lane_handle_write w-one T_was local claude 211
cm_lane_handle w-one 2>"$ROOT/err" >/dev/null
check "a pid carrying another terminal is named as such" 'grep -q "agent pid 211 does not carry terminal T_was" "$ROOT/err"'
reset_proc
cm_lane_handle_write w-one T_gone local claude 99998
cm_lane_handle w-one 2>"$ROOT/err" >/dev/null
check "a gone pid is named as gone" 'grep -q "agent pid 99998 is gone" "$ROOT/err"'

mkledger; rm -rf -- "${CM_HOME:?}/lanes"; reset_proc
mkproc 220 "$WT" "ORCA_TERMINAL_HANDLE=term_reused" claude
mkdir -p "$CM_HOME/lanes/w-old2"; printf 'term_reused\tlocal\tclaude\t99997\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$CM_HOME/lanes/w-old2/handle"
jq '.workers["w-old2"] = {host: "local", state: "running"}' "$CM_HOME/ledger.json" > "$ROOT/l.json" && mv "$ROOT/l.json" "$CM_HOME/ledger.json"
OUT="$(lh --worker w-one)"
check "held_by: a fresh file whose agent pid is gone holds nothing: a reused terminal is not held by its dead former agent" '[ "$(field w-one 1)" = term_reused ] && grep -Eq "^w-one	term_reused	refreshed" <<<"$OUT"'
reset_proc; mkproc 221 "$WT" "ORCA_TERMINAL_HANDLE=term_reused" claude; mkproc 222 "$WT2" "ORCA_TERMINAL_HANDLE=term_reused" claude
printf 'term_reused\tlocal\tclaude\t222\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$CM_HOME/lanes/w-old2/handle"
OUT="$(lh --worker w-one)"
check "...but the same file with its agent ALIVE and carrying the terminal still holds it" '[ "$(field w-one 1)" = "-" ] && grep -q "fresh handle file" <<<"$OUT"'

mkledger; rm -rf -- "${CM_HOME:?}/lanes"; reset_proc
mkproc 230 "$WT" "ORCA_TERMINAL_HANDLE=term_two" claude; mkproc 229 "$WT" "ORCA_TERMINAL_HANDLE=term_two" claude; mkproc 231 "$WT" "ORCA_TERMINAL_HANDLE=term_two" claude
lh --quiet
check "several processes with one handle: the file records the lowest pid (the parent), not the first by string order" '[ "$(field w-one 4)" = 229 ]'

rm -rf -- "${CM_HOME:?}/lanes" "$ROOT/real-lanes"; mkledger; mkdir -p "$ROOT/real-lanes/w-one"; ln -s "$ROOT/real-lanes" "$CM_HOME/lanes"
printf 'planted\tlocal\tclaude\t-\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$ROOT/real-lanes/w-one/handle"
cm_lane_handle w-one 2>"$ROOT/err" >"$ROOT/out"; RC=$?
check "a symlinked lanes/ itself is refused: exit 3 (not verifiable), nothing printed, the planted file not served" '[ "$RC" = 3 ] && [ ! -s "$ROOT/out" ]'
OUT="$(lh)"
check "...and a full run neither writes nor deletes through it" '[ "$(cat "$ROOT/real-lanes/w-one/handle" | cut -f1)" = planted ]'
rm -f -- "${CM_HOME:?}/lanes"; mkdir -p "$CM_HOME/lanes" "$ROOT/real-dir"; ln -s "$ROOT/real-dir" "$CM_HOME/lanes/w-one"
printf 'planted2\tlocal\tclaude\t-\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$ROOT/real-dir/handle"
cm_lane_handle w-one 2>/dev/null >"$ROOT/out"; RC=$?
check "a symlinked lanes/<id>: exit 3, not 2 (usage)" '[ "$RC" = 3 ] && [ ! -s "$ROOT/out" ]'
lh --worker w-one >/dev/null 2>&1; RC=$?
check "--worker on a symlinked lanes/<id>: exit 3 (not verifiable), the same as --get, not 2 (usage)" '[ "$RC" = 3 ]'
lh --worker '../x' >/dev/null 2>&1; RC=$?
check "--worker with a bad id is still exit 2 (usage)" '[ "$RC" = 2 ]'
jq '.workers["w-gone9"] = {host: "local", state: "gone"}' "$CM_HOME/ledger.json" > "$ROOT/l.json" && mv "$ROOT/l.json" "$CM_HOME/ledger.json"
ln -s "$ROOT/real-dir" "$CM_HOME/lanes/w-gone9"
lh --quiet
check "phase 4 does not delete the handle file of a finished worker through a symlinked lane directory" '[ -e "$ROOT/real-dir/handle" ]'
rm -rf -- "${CM_HOME:?}/lanes"
# a symlinked lanes/.failed: the success-path marker removal and phase 4 must not delete through it
mkledger; mkdir -p "$CM_HOME/lanes" "$ROOT/real-failed"; : > "$ROOT/real-failed/w-one"; ln -s "$ROOT/real-failed" "$CM_HOME/lanes/.failed"
cm_lane_handle_write w-one T_ok local claude -
check "a symlinked lanes/.failed: a successful write does not delete w-one through it" '[ -e "$ROOT/real-failed/w-one" ]'
mkdir -p "$CM_HOME/lanes/w-ghost"; printf 'x\tlocal\tclaude\t-\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$CM_HOME/lanes/w-ghost/handle"; : > "$ROOT/real-failed/w-ghost"
lh --quiet
check "...and a full run leaves the files in it alone" '[ -e "$ROOT/real-failed/w-ghost" ]'
rm -rf -- "${CM_HOME:?}/lanes"
umask 022; mkledger; rm -rf -- "${CM_HOME:?}/lanes"; mkdir -p "$CM_HOME/lanes/w-one"; chmod 555 "$CM_HOME/lanes/w-one"
if [ -w "$CM_HOME/lanes/w-one" ]; then echo "SKIP marker mode case (root)"; else
  cm_lane_handle_write w-one T_m local claude - 2>/dev/null
  check "the failure marker and its directory are created private (700 / 600) whatever the caller's umask" '[ "$(stat -c %a "$CM_HOME/lanes/.failed" 2>/dev/null || stat -f %Lp "$CM_HOME/lanes/.failed")" = 700 ] && [ "$(stat -c %a "$CM_HOME/lanes/.failed/w-one" 2>/dev/null || stat -f %Lp "$CM_HOME/lanes/.failed/w-one")" = 600 ]'
fi
chmod 755 "$CM_HOME/lanes/w-one" 2>/dev/null; rm -rf -- "${CM_HOME:?}/lanes"


echo "--- the write is atomic: a reader running during writes never sees a partial line"
mkledger; reset_proc
cm_lane_handle_write w-one T_seed local claude -
( i=0; while [ "$i" -lt 120 ]; do i=$((i + 1)); cm_lane_handle_write w-one "T_atomic_$(printf '%0*d' $((i % 40 + 1)) "$i")" local claude - 2>/dev/null; done; : > "$ROOT/writer.done" ) &
wpid=$!
partial=0; reads=0
while [ ! -e "$ROOT/writer.done" ]; do
  content="$(cat "$(file w-one)" 2>/dev/null)"; reads=$((reads + 1))
  if [ "$(printf '%s\n' "$content" | awk -F"\t" 'NF == 5 && $5 ~ /Z$/ { n++ } END { print n + 0 }')" != 1 ] || [ "$(printf '%s' "$content" | wc -l | tr -d ' ')" != 0 ]; then partial=$((partial + 1)); fi
done
wait "$wpid"
check "the reader loop ran during the writes ($reads reads) and never saw an empty, torn or multi-line file" '[ "$reads" -ge 20 ] && [ "$partial" = 0 ]'

echo "--- an installed copy (lib.sh + the two helpers) still checks lanes"
BIN="$ROOT/bin"; mkdir -p "$BIN"
cp "$SCRIPTS/lib.sh" "$SCRIPTS/lane-handles.sh" "$SCRIPTS/live-agent.sh" "$BIN/"
mkledger; rm -rf -- "${CM_HOME:?}/lanes"; reset_proc; mkproc 180 "$WT" "ORCA_TERMINAL_HANDLE=term_inst" claude
# shellcheck disable=SC2031  # the subshell sources the installed copy of lib.sh on purpose; CM_HOME is exported at the top
(. "$BIN/lib.sh"; CM_PROC_ROOT="$P" cm_lane_handle w-one 2>/dev/null >"$ROOT/out"; echo $? > "$ROOT/rc")
check "installed copy WITH lane-handles.sh and live-agent.sh: a missing file is re-checked and the live handle served" '[ "$(cat "$ROOT/rc")" = 0 ] && [ "$(cat "$ROOT/out")" = term_inst ]'
BIN2="$ROOT/bin-old"; mkdir -p "$BIN2"; cp "$SCRIPTS/lib.sh" "$BIN2/"
# shellcheck disable=SC2031  # as above
rm -rf -- "${CM_HOME:?}/lanes"
# shellcheck disable=SC2031  # as above
(. "$BIN2/lib.sh"; CM_PROC_ROOT="$P" cm_lane_handle w-one 2>"$ROOT/err" >"$ROOT/out"; echo $? > "$ROOT/rc")
check "the OLD two-file copy fails closed (exit 3) and the log names the missing script" '[ "$(cat "$ROOT/rc")" = 3 ] && [ ! -s "$ROOT/out" ] && grep -q "lane-handles.sh is missing or not executable" "$ROOT/err"'

echo "--- round 5: empty id, per-lane lock, missing observer, debris, symlinked .failed"
mkledger; rm -rf -- "${CM_HOME:?}/lanes"; reset_proc
mkproc 101 "$WT" "ORCA_TERMINAL_HANDLE=term_live_1" claude
OUT="$("$LH" --get "" 2>/dev/null)"; RC=$?
check "--get with an empty id exits 2 and prints no table" '[ "$RC" = 2 ] && [ -z "$OUT" ]'
OUT="$("$LH" --worker "" 2>/dev/null)"; RC=$?
check "--worker with an empty id exits 2 and prints no table" '[ "$RC" = 2 ] && [ -z "$OUT" ]'
check "no lane file was written by either call" '[ ! -e "$CM_HOME/lanes" ] || [ -z "$(ls "$CM_HOME/lanes" 2>/dev/null)" ]'

# the write is serialised per lane: a stale lock (dead writer) is taken over, a fresh one fails the write closed
rm -rf -- "${CM_HOME:?}/lanes"; mkdir -p "$CM_HOME/lanes/w-one/.lock"; touch -d '3 minutes ago' "$CM_HOME/lanes/w-one/.lock"
cm_lane_handle_write w-one T_lock local claude - 2>/dev/null; RC=$?
check "a stale lock (older than a minute) is taken over: the write lands and the lock is released" '[ "$RC" = 0 ] && [ "$(field w-one 1)" = T_lock ] && [ ! -e "$CM_HOME/lanes/w-one/.lock" ]'
rm -rf -- "${CM_HOME:?}/lanes"; mkdir -p "$CM_HOME/lanes/w-one/.lock"
cm_lane_handle_write w-one T_busy local claude - 2>"$ROOT/err"; RC=$?
check "a lock held by a live writer: exit 4, nothing written, the log says locked" '[ "$RC" = 4 ] && [ ! -e "$(file w-one)" ] && grep -q "locked by another writer" "$ROOT/err"'
# a busy lock is not a failed write: the existing good file is NOT removed and no failure marker is made
rm -rf -- "${CM_HOME:?}/lanes"; mkdir -p "$CM_HOME/lanes/w-one"
cm_lane_handle_write w-one T_keep local claude - 2>/dev/null
mkdir "$CM_HOME/lanes/w-one/.lock"
cm_lane_handle_write w-one T_other local claude - 2>/dev/null; RC=$?
check "lock busy: exit 4, the previous good file is kept and no .failed marker is made" '[ "$RC" = 4 ] && [ "$(field w-one 1)" = T_keep ] && [ ! -e "$CM_HOME/lanes/.failed/w-one" ]'
# a stale lock that cannot be moved (a non-empty directory under a read-only parent is not the case here: a stale regular file is) never spins
rm -rf -- "${CM_HOME:?}/lanes/w-one/.lock"; : > "$CM_HOME/lanes/w-one/.lock"; touch -d '5 minutes ago' "$CM_HOME/lanes/w-one/.lock"
SECONDS=0; timeout 20 bash -c '. "$1"; CM_HOME="$2"; cm_lane_handle_write w-one T_file local claude -' _ "$SCRIPTS/lib.sh" "$CM_HOME" 2>/dev/null; RC=$?
check "a stale lock that is a regular file is taken over by rename, not spun on (finishes well inside the bound)" '[ "$RC" = 0 ] && [ "$SECONDS" -lt 10 ] && [ "$(field w-one 1)" = T_file ]'
rm -rf -- "${CM_HOME:?}/lanes"
# the holder releases between the loser's failed mkdir and its look at the lock: deterministic stand-in for the race
# (the first lock mkdir fails and leaves no lock, as if the holder had just rmdir-ed). It must be retried, not failed.
rm -rf -- "${CM_HOME:?}/lanes"; mkdir -p "$CM_HOME/lanes/w-one"
check "a lock released between the failed mkdir and the existence test is retried: the write lands" '
  n=0; mkdir() { case "$1" in */.lock) n=$((n + 1)); [ "$n" = 1 ] && return 1 ;; esac; command mkdir "$@"; }
  cm_lane_handle_write w-one T_rel local claude - 2>/dev/null; RC=$?
  [ "$RC" = 0 ] && [ "$(field w-one 1)" = T_rel ] && [ ! -e "$CM_HOME/lanes/w-one/.lock" ]'
# a miss is a failed lock mkdir plus a failed retry mkdir with no lock on disk (2 calls). Two misses in a row (4 calls) are
# tolerated: the 5th call takes the lock. A third miss in a row (6 calls) is a real failure.
check "two lock misses in a row are tolerated: the next try takes the lock and the write lands" '
  n=0; mkdir() { case "$1" in */.lock) n=$((n + 1)); [ "$n" -le 4 ] && return 1 ;; esac; command mkdir "$@"; }
  cm_lane_handle_write w-one T_two local claude - 2>/dev/null; RC=$?
  [ "$RC" = 0 ] && [ "$(field w-one 1)" = T_two ] && [ ! -e "$CM_HOME/lanes/w-one/.lock" ]'
check "three lock misses in a row are a real failure: exit 1" '
  n=0; mkdir() { case "$1" in */.lock) n=$((n + 1)); [ "$n" -le 6 ] && return 1 ;; esac; command mkdir "$@"; }
  cm_lane_handle_write w-one T_three local claude - 2>/dev/null; RC=$?
  [ "$RC" = 1 ]'
# and a lock that never appears is still a real failure (exit 1, fail closed)
check "a lock mkdir that keeps failing with no lock present is a real failure: exit 1" '
  mkdir() { case "$1" in */.lock) return 1 ;; esac; command mkdir "$@"; }
  cm_lane_handle_write w-one T_nolock local claude - 2>/dev/null; RC=$?
  [ "$RC" = 1 ]'
rm -rf -- "${CM_HOME:?}/lanes"
# two writers racing: the file ends up holding the NEWER observation whichever mv lands last
RACE_OK=1
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  rm -rf -- "${CM_HOME:?}/lanes"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; older="$(date -u -d '30 seconds ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-30S +%Y-%m-%dT%H:%M:%SZ)"
  # a writer that finds the lane busy (exit 4, possible on a loaded host) tries again, as the next tick would
  ( for _ in 1 2 3 4 5; do cm_lane_handle_write w-one T_new local claude - "$now" 2>/dev/null; [ $? = 4 ] || break; done ) &
  ( for _ in 1 2 3 4 5; do cm_lane_handle_write w-one T_old local claude - "$older" 2>/dev/null; [ $? = 4 ] || break; done ) &
  wait
  [ "$(field w-one 1)" = T_new ] || RACE_OK=0
done
check "racing writers: the newer observation always wins (12 rounds)" '[ "$RACE_OK" = 1 ]'
rm -rf -- "${CM_HOME:?}/lanes"

# the observer script must exist: without it every worker would read unknown and --quiet would hide it
NOLA="$ROOT/no-observer"; mkdir -p "$NOLA"; cp "$SCRIPTS/lane-handles.sh" "$SCRIPTS/lib.sh" "$NOLA/"
mkledger
CM_PROC_ROOT="$P" "$NOLA/lane-handles.sh" --quiet 2>"$ROOT/err"; RC=$?
check "live-agent.sh missing next to lane-handles.sh: exit 1 even with --quiet, and the log names it" '[ "$RC" = 1 ] && grep -q "live-agent.sh is missing or not executable" "$ROOT/err"'

# debris of an interrupted write, and markers of finished workers, are swept by a full run
mkledger; rm -rf -- "${CM_HOME:?}/lanes"; reset_proc
mkproc 101 "$WT" "ORCA_TERMINAL_HANDLE=term_live_1" claude
mkdir -p "$CM_HOME/lanes/w-one" "$CM_HOME/lanes/.failed"
: > "$CM_HOME/lanes/w-one/.handle.OLD123"; touch -d '10 minutes ago' "$CM_HOME/lanes/w-one/.handle.OLD123"
: > "$CM_HOME/lanes/w-one/.handle.NEW456"
: > "$CM_HOME/lanes/.failed/w-ghost"
lh --quiet
check "a temp file older than 5 minutes is swept" '[ ! -e "$CM_HOME/lanes/w-one/.handle.OLD123" ]'
check "a fresh temp file (a write in flight) is left alone" '[ -e "$CM_HOME/lanes/w-one/.handle.NEW456" ]'
check "a failure marker of a worker that is not live is swept" '[ ! -e "$CM_HOME/lanes/.failed/w-ghost" ]'
: > "$CM_HOME/lanes/.failed/w-two"
lh --quiet
check "a failure marker of a live worker is kept (a full run does not erase a failed write on record)" '[ -e "$CM_HOME/lanes/.failed/w-two" ] || [ -e "$(file w-two)" ]'
rm -rf -- "${CM_HOME:?}/lanes"

# the reader fails closed when lanes/.failed is a symlink, even with a fresh file
mkledger; reset_proc
mkproc 101 "$WT" "ORCA_TERMINAL_HANDLE=term_live_1" claude
lh --quiet
cm_lane_handle w-one 2>/dev/null >"$ROOT/out"; RC=$?
check "baseline: a fresh file with a live agent is served" '[ "$RC" = 0 ] && [ "$(cat "$ROOT/out")" = term_live_1 ]'
mkdir -p "$ROOT/empty-failed"; ln -s "$ROOT/empty-failed" "$CM_HOME/lanes/.failed"
cm_lane_handle w-one 2>"$ROOT/err" >"$ROOT/out"; RC=$?
check "lanes/.failed a symlink: the reader refuses (exit 3, nothing printed)" '[ "$RC" = 3 ] && [ ! -s "$ROOT/out" ]'
rm -rf -- "${CM_HOME:?}/lanes"

echo "--- phase 4 and held_by: a ledger that cannot be read is never read as \"the worker is gone\""
# live_record has three answers: live, not live (a readable ledger says so), unknown (jq failed, the ledger is unreadable). Only "not live"
# removes a file. The ledger is made unreadable AFTER the start-up check by a live-agent stub (the ledger is rewritten mid-run), or jq is
# replaced by a shim that fails only for live_record's own filter (a PATH shim: every other jq call runs the real one).
REAL_JQ="$(command -v jq)"
mkdir -p "$ROOT/shim"
cat > "$ROOT/shim/jq" <<SHIM
#!/usr/bin/env bash
# fails only for live_record's filter; JQ_SHIM: exit1 (answers "false"), exit2 (an error), empty0 (exits 0 with no answer)
case "\$*" in
  *'lh_workers[\$id]'*)
    case "\${JQ_SHIM:-}" in exit1) exit 1 ;; exit2) exit 2 ;; empty0) exit 0 ;; esac ;;
esac
exec "$REAL_JQ" "\$@"
SHIM
chmod +x "$ROOT/shim/jq"
# a live-agent stub: no agent anywhere (exit 1), and the ledger is damaged on the first call, the way a rewrite or a failing disk would
mklacorrupt() { # <how: malformed|missing|chmod|empty|null|two|workersnull|workersarray>
  printf '#!/bin/sh\nL="%s/ledger.json"\ncase "%s" in malformed) printf "{ not json" > "$L" ;; missing) rm -f "$L" ;; chmod) chmod 000 "$L" ;; empty) printf "{}" > "$L" ;; null) printf "null" > "$L" ;; two) printf "{\\"workers\\":{}}{\\"workers\\":{}}" > "$L" ;; workersnull) printf "{\\"workers\\":null}" > "$L" ;; workersarray) printf "{\\"workers\\":[]}" > "$L" ;; esac\nexit 1\n' "$CM_HOME" "$1" > "$ROOT/la-corrupt"
  chmod +x "$ROOT/la-corrupt"
}
# four lane files: a live record without a path (so phase 1 does not look at it), dead records, an id the ledger never held
p4_setup() {
  mkledger; reset_proc; rm -rf -- "${CM_HOME:?}/lanes"
  mkdir -p "$CM_HOME/lanes/w-live" "$CM_HOME/lanes/w-gone" "$CM_HOME/lanes/w-rep" "$CM_HOME/lanes/w-absent"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for w in w-live w-gone w-rep w-absent; do printf 'term_%s\tlocal\tclaude\t1\t%s\n' "$w" "$now" > "$CM_HOME/lanes/$w/handle"; done
  jq '.workers["w-live"] = {host: "local", state: "running"} | .workers["w-gone"] = {host: "local", state: "gone"} | .workers["w-rep"] = {host: "local", state: "repurposed"}' \
    "$CM_HOME/ledger.json" > "$ROOT/l.json" && mv "$ROOT/l.json" "$CM_HOME/ledger.json"
}
kept4() { for w in w-live w-gone w-rep w-absent; do [ -e "$CM_HOME/lanes/$w/handle" ] || return 1; done; }
gone4() { for w in w-gone w-rep w-absent; do [ ! -e "$CM_HOME/lanes/$w/handle" ] || return 1; done; }

p4_setup
OUT="$(lh 2>"$ROOT/err")"; RC=$?
check "readable ledger: a live worker's file is kept, a gone and a repurposed worker's and an unknown id's are removed, exit 0" \
  '[ "$RC" = 0 ] && [ -e "$CM_HOME/lanes/w-live/handle" ] && gone4 && grep -Eq "^w-gone	-	gone" <<<"$OUT" && ! grep -q "^w-live	" <<<"$OUT"'
p4_setup
OUT="$(lh --dry-run 2>"$ROOT/err")"; RC=$?
check "readable ledger, --dry-run: the same rows, nothing removed, exit 0" '[ "$RC" = 0 ] && kept4 && grep -Eq "^w-absent	-	gone" <<<"$OUT"'
p4_setup; printf '{"workers":{}}' > "$CM_HOME/ledger.json"
OUT="$(lh 2>"$ROOT/err")"; RC=$?
check "readable ledger with an EMPTY workers object (a fleet with no workers): every file is gone, exit 0 (not unknown)" '[ "$RC" = 0 ] && [ ! -e "$CM_HOME/lanes/w-live/handle" ] && gone4 && ! grep -q "	kept	" <<<"$OUT"'

CAN_000=1; : > "$ROOT/m000"; chmod 000 "$ROOT/m000"; [ -r "$ROOT/m000" ] && CAN_000=0; chmod 600 "$ROOT/m000"
for HOW in malformed missing chmod empty null two workersnull workersarray; do
  if [ "$HOW" = chmod ] && [ "$CAN_000" = 0 ]; then echo "SKIP unreadable-ledger case (chmod 000): this user reads a mode 000 file (root)"; continue; fi
  p4_setup; mklacorrupt "$HOW"
  chmod 600 "$CM_HOME/ledger.json" 2>/dev/null
  OUT="$(CM_LIVE_AGENT="$ROOT/la-corrupt" lh 2>"$ROOT/err")"; RC=$?
  chmod 600 "$CM_HOME/ledger.json" 2>/dev/null
  check "ledger $HOW part way through the run: every worker file is KEPT (live, gone and unknown alike), nothing is guessed gone, the run exits 1" \
    '[ "$RC" = 1 ] && kept4 && ! grep -Eq "	gone	" <<<"$OUT"' "rc=$RC $(cat "$ROOT/err")"
  check "...one \"kept\" row per file, and stderr says the ledger could not be read (even with --quiet)" \
    '[ "$(printf "%s\n" "$OUT" | grep -c "	kept	")" = 4 ] && grep -q "ledger unreadable: the file is left as it is" <<<"$OUT" && grep -q "could not be read part way through the run: 4 worker(s) could not be judged" "$ROOT/err"'
done
p4_setup; mklacorrupt malformed
CM_LIVE_AGENT="$ROOT/la-corrupt" lh --quiet 2>"$ROOT/err" >"$ROOT/out"; RC=$?
check "--quiet: no rows, but the files are kept, the exit is 1 and stderr still says why" '[ "$RC" = 1 ] && [ ! -s "$ROOT/out" ] && kept4 && grep -q "could not be read part way" "$ROOT/err"'
p4_setup; mklacorrupt malformed
OUT="$(CM_LIVE_AGENT="$ROOT/la-corrupt" lh --dry-run 2>"$ROOT/err")"; RC=$?
check "--dry-run with an unreadable ledger reports kept too (nothing would be removed), exit 1" '[ "$RC" = 1 ] && kept4 && grep -q "	kept	" <<<"$OUT"'

# the failure markers of phase 4: kept when the ledger cannot be read, removed when a readable ledger says the worker is not live
p4_setup; mkdir -p "$CM_HOME/lanes/.failed"; : > "$CM_HOME/lanes/.failed/w-absent"; : > "$CM_HOME/lanes/.failed/w-live"
rm -f -- "$CM_HOME/lanes/w-absent/handle" "$CM_HOME/lanes/w-live/handle" "$CM_HOME/lanes/w-gone/handle" "$CM_HOME/lanes/w-rep/handle"
OUT="$(lh 2>"$ROOT/err")"; RC=$?
check "failure markers, readable ledger: the marker of an unknown id is removed, the marker of a live worker kept, exit 0" '[ "$RC" = 0 ] && [ ! -e "$CM_HOME/lanes/.failed/w-absent" ] && [ -e "$CM_HOME/lanes/.failed/w-live" ]'
p4_setup; mkdir -p "$CM_HOME/lanes/.failed"; : > "$CM_HOME/lanes/.failed/w-absent"
rm -f -- "$CM_HOME/lanes/w-absent/handle" "$CM_HOME/lanes/w-live/handle" "$CM_HOME/lanes/w-gone/handle" "$CM_HOME/lanes/w-rep/handle"
OUT="$(JQ_SHIM=exit2 PATH="$ROOT/shim:$PATH" lh 2>"$ROOT/err")"; RC=$?
check "failure markers, jq failing for live_record: the marker is KEPT and reported, exit 1" '[ "$RC" = 1 ] && [ -e "$CM_HOME/lanes/.failed/w-absent" ] && grep -q "w-absent	-	kept	ledger unreadable: the failure marker is left as it is" <<<"$OUT"'

# jq stubs (the ledger itself is fine)
p4_setup
OUT="$(JQ_SHIM=exit2 PATH="$ROOT/shim:$PATH" lh 2>"$ROOT/err")"; RC=$?
check "a jq that fails (exit 2) for the liveness question: every worker file is KEPT, the run exits 1, the rows say kept" \
  '[ "$RC" = 1 ] && kept4 && grep -Eq "^w-absent	-	kept	ledger unreadable" <<<"$OUT" && ! grep -q "	gone	" <<<"$OUT"' "rc=$RC"
p4_setup
OUT="$(JQ_SHIM=empty0 PATH="$ROOT/shim:$PATH" lh 2>"$ROOT/err")"; RC=$?
check "a jq that exits 0 with no answer at all is unknown too (files kept, exit 1)" '[ "$RC" = 1 ] && kept4'
p4_setup
OUT="$(JQ_SHIM=exit1 PATH="$ROOT/shim:$PATH" lh 2>"$ROOT/err")"; RC=$?
check "a jq that answers \"false\" (exit 1) is NOT live, as before: the files are removed, exit 0" '[ "$RC" = 0 ] && [ ! -e "$CM_HOME/lanes/w-live/handle" ] && gone4'

# held_by: another lane's fresh file with the very handle a live worker found. Readable ledger and a live record: held (as before).
# Unreadable ledger: unknown, so nothing is claimed about that file (the worker is NOT marked held on a guess), the file is kept, the run exits 1.
mklalive() { # the agent is found in $WT only; <corrupt: yes|no> damages the ledger on that call
  printf '#!/bin/sh\ncase "$1" in "%s") printf "301\\tterm_h\\tclaude\\n" ;; *) exit 1 ;; esac\n[ "%s" = yes ] && printf "{ not json" > "%s/ledger.json"\nexit 0\n' "$WT" "$1" "$CM_HOME" > "$ROOT/la-live"
  chmod +x "$ROOT/la-live"
}
held_setup() {
  mkledger; reset_proc; rm -rf -- "${CM_HOME:?}/lanes"
  jq '.workers["w-other"] = {host: "local", state: "running"}' "$CM_HOME/ledger.json" > "$ROOT/l.json" && mv "$ROOT/l.json" "$CM_HOME/ledger.json"
  mkdir -p "$CM_HOME/lanes/w-other"; printf 'term_h\tlocal\tclaude\t-\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$CM_HOME/lanes/w-other/handle"
}
held_setup; mklalive no
OUT="$(CM_LIVE_AGENT="$ROOT/la-live" lh 2>"$ROOT/err")"; RC=$?
check "held_by, readable ledger: a live worker whose handle another live worker's fresh file holds is marked held (as before)" '[ "$RC" = 0 ] && grep -Eq "^w-one	-	held" <<<"$OUT"'
held_setup; mklalive yes
OUT="$(CM_LIVE_AGENT="$ROOT/la-live" lh --worker w-one 2>"$ROOT/err")"; RC=$?   # --worker: no phase 4, so the exit 1 can only come from held_by
check "held_by, ledger unreadable: the worker gets an \"unknown\" row, its file is NOT written with the contested handle, the other lane's file is left, the run exits 1" \
  '[ "$RC" = 1 ] && grep -Eq "^w-one	-	unknown" <<<"$OUT" && ! grep -Eq "^w-one	.*(refreshed|held)" <<<"$OUT" && ! grep -qs term_h "$CM_HOME/lanes/w-one/handle" && [ -e "$CM_HOME/lanes/w-other/handle" ] && grep -q "could not be read part way through the run" "$ROOT/err"' "rc=$RC $(cat "$ROOT/err")"
held_setup; mklalive no
OUT="$(JQ_SHIM=exit2 PATH="$ROOT/shim:$PATH" CM_LIVE_AGENT="$ROOT/la-live" lh --worker w-one 2>"$ROOT/err")"; RC=$?
check "held_by, jq failing for live_record: the same (an \"unknown\" row, no write, the ledger terminal untouched, exit 1)" '[ "$RC" = 1 ] && grep -Eq "^w-one	-	unknown" <<<"$OUT" && ! grep -Eq "^w-one	.*(refreshed|held)" <<<"$OUT" && ! grep -qs term_h "$CM_HOME/lanes/w-one/handle" && [ "$(jq -r ".workers[\"w-one\"].terminal" "$CM_HOME/ledger.json")" = term_stale ] && [ -e "$CM_HOME/lanes/w-other/handle" ]'
# the ledger-terminal holder (no lane file at all): a jq that fails on the first held_by question is unknown too, not "nobody holds it"
held_setup; rm -f -- "$CM_HOME/lanes/w-other/handle"
jq '.workers["w-other"].terminal = "term_h"' "$CM_HOME/ledger.json" > "$ROOT/l.json" && mv "$ROOT/l.json" "$CM_HOME/ledger.json"
mklalive no
OUT="$(CM_LIVE_AGENT="$ROOT/la-live" lh 2>"$ROOT/err")"; RC=$?
check "held_by, readable ledger: the holder is found by the ledger terminal alone (held, as before)" '[ "$RC" = 0 ] && grep -Eq "^w-one	-	held.*ledger terminal" <<<"$OUT"'
held_setup; rm -f -- "$CM_HOME/lanes/w-other/handle"
jq '.workers["w-other"].terminal = "term_h"' "$CM_HOME/ledger.json" > "$ROOT/l.json" && mv "$ROOT/l.json" "$CM_HOME/ledger.json"
mklalive yes
OUT="$(CM_LIVE_AGENT="$ROOT/la-live" lh 2>"$ROOT/err")"; RC=$?
check "held_by, ledger unreadable at the ledger-terminal question: not read as \"nobody holds it\" (an \"unknown\" row, no write of the contested handle, exit 1, stderr says why)" '[ "$RC" = 1 ] && grep -Eq "^w-one	-	unknown" <<<"$OUT" && ! grep -qs term_h "$CM_HOME/lanes/w-one/handle" && grep -q "could not be read part way through the run" "$ROOT/err"' "rc=$RC $(cat "$ROOT/err")"
mkledger; rm -rf -- "${CM_HOME:?}/lanes"

echo "--- the checks themselves"
# bash printf writes into a pipe one line per write(): when grep -q matches an early line and exits, the printf that still has lines to
# write dies of SIGPIPE, and under pipefail the check fails on a correct output (seen on a loaded host). A here-string has no writer.
PIPE_GREP_Q='printf [^|]*[|] *grep -[A-Za-z]*q'
check "no check pipes printf into grep -q (SIGPIPE under pipefail fails a correct output when the host is loaded): here-strings only" '! grep -nE "$PIPE_GREP_Q" "$HERE/lane-handles.sh"'

echo "--- the Plugly terminal handle: _cm_lane_agent_alive and lane-handles.sh read PLUGLY_TERMINAL_HANDLE first, else ORCA_TERMINAL_HANDLE"
# shellcheck disable=SC2059  # the format carries the NUL separators on purpose
penv() { local pid="$1" fmt="$2"; shift 2; printf "$fmt" "$@" > "$P/$pid/environ"; }
alive() { _cm_lane_agent_alive "$@" 2>/dev/null; echo $?; }
reset_proc; mkproc 401 "$WT" "" claude
penv 401 'HOME=/h\0PLUGLY_TERMINAL_HANDLE=term_plug\0'
check "plugly (a): only PLUGLY set: the file handle equal to it is alive (0)" '[ "$(alive 401 term_plug)" = 0 ]'
penv 401 'HOME=/h\0ORCA_TERMINAL_HANDLE=term_orca\0'
check "plugly (b): only ORCA set: alive (0) for it, 2 for another handle (unchanged)" '[ "$(alive 401 term_orca)" = 0 ] && [ "$(alive 401 term_other)" = 2 ]'
penv 401 'ORCA_TERMINAL_HANDLE=term_orca\0PLUGLY_TERMINAL_HANDLE=term_plug\0'
check "plugly (c1): both set and different, ORCA first: PLUGLY is 0, the ORCA handle is 2" '[ "$(alive 401 term_plug)" = 0 ] && [ "$(alive 401 term_orca)" = 2 ]'
penv 401 'PLUGLY_TERMINAL_HANDLE=term_plug\0ORCA_TERMINAL_HANDLE=term_orca\0'
check "plugly (c2): both set and different, PLUGLY first: PLUGLY is 0, the ORCA handle is 2" '[ "$(alive 401 term_plug)" = 0 ] && [ "$(alive 401 term_orca)" = 2 ]'
penv 401 'ORCA_TERMINAL_HANDLE=term_orca\0PLUGLY_TERMINAL_HANDLE=term_plug'
check "plugly (c3): PLUGLY last with no closing NUL: still wins" '[ "$(alive 401 term_plug)" = 0 ] && [ "$(alive 401 term_orca)" = 2 ]'
penv 401 'PLUGLY_TERMINAL_HANDLE=term_same\0ORCA_TERMINAL_HANDLE=term_same\0'
check "plugly (d): both set and equal: alive (0)" '[ "$(alive 401 term_same)" = 0 ]'
penv 401 'PLUGLY_TERMINAL_HANDLE=\0ORCA_TERMINAL_HANDLE=term_orca\0'
check "plugly (e1): PLUGLY set but empty, ORCA first or last, ORCA set: ORCA is the handle" '[ "$(alive 401 term_orca)" = 0 ] && [ "$(alive 401 term_plug)" = 2 ]'
penv 401 'ORCA_TERMINAL_HANDLE=term_orca\0PLUGLY_TERMINAL_HANDLE=\0'
check "plugly (e2): ORCA first, PLUGLY empty after it: ORCA is the handle" '[ "$(alive 401 term_orca)" = 0 ]'
penv 401 'PLUGLY_TERMINAL_HANDLE=\0HOME=/h\0'
check "plugly (e3): PLUGLY empty and no ORCA: 2 (an empty PLUGLY is not a terminal)" '[ "$(alive 401 term_orca)" = 2 ]'
penv 401 'PLUGLY_TERMINAL_HANDLE=bad;rm -rf\0ORCA_TERMINAL_HANDLE=term_orca\0'
check "plugly (f1): hostile PLUGLY never falls back to ORCA: the ORCA handle is 2" '[ "$(alive 401 term_orca)" = 2 ]'
penv 401 'ORCA_TERMINAL_HANDLE=term_orca\0PLUGLY_TERMINAL_HANDLE=-x\0'
check "plugly (f2): a hostile PLUGLY after ORCA still wins: the ORCA handle is 2" '[ "$(alive 401 term_orca)" = 2 ]'
penv 401 'PLUGLY_TERMINAL_HANDLE=term_first\0HOME=/h\0PLUGLY_TERMINAL_HANDLE=term_last\0'
check "plugly (dup): PLUGLY twice with different values: the FIRST counts (0 for it, 2 for the last)" '[ "$(alive 401 term_first)" = 0 ] && [ "$(alive 401 term_last)" = 2 ]'
penv 401 'ORCA_TERMINAL_HANDLE=term_first\0ORCA_TERMINAL_HANDLE=term_last\0'
check "plugly (dup): ORCA twice with different values and no PLUGLY: the FIRST counts" '[ "$(alive 401 term_first)" = 0 ] && [ "$(alive 401 term_last)" = 2 ]'
penv 401 'PLUGLY_TERMINAL_HANDLE=\0PLUGLY_TERMINAL_HANDLE=term_late\0ORCA_TERMINAL_HANDLE=term_orca\0'
check "plugly (dup): an empty first PLUGLY counts, a later non-empty one is ignored: ORCA is the handle" '[ "$(alive 401 term_orca)" = 0 ] && [ "$(alive 401 term_late)" = 2 ]'
penv 401 'HOME=/h\0'
check "plugly: neither set: 2 (carries no terminal), as before" '[ "$(alive 401 term_orca)" = 2 ]'
check "plugly: a gone pid is still 1" '[ "$(alive 99991 term_plug)" = 1 ]'
penv 401 'PLUGLY_TERMINAL_HANDLE=term_plug\0'; chmod 000 "$P/401/environ"
if [ -r "$P/401/environ" ]; then echo "SKIP unreadable-environ case: this user reads a mode 000 file (root)"; else
  check "plugly: an unreadable environ is still 3 (fail closed)" '[ "$(alive 401 term_plug)" = 3 ]'
fi
chmod 644 "$P/401/environ"
# end to end through lane-handles.sh: a lane already on Plugly (ORCA unset) is found and its file written
mkledger; rm -rf -- "${CM_HOME:?}/lanes"; reset_proc; mkproc 410 "$WT" "" claude
penv 410 'HOME=/h\0PLUGLY_TERMINAL_HANDLE=term_on_plugly\0'
lh --quiet
check "plugly: lane-handles.sh finds a lane that only has PLUGLY_TERMINAL_HANDLE and records its handle" '[ "$(field w-one 1)" = term_on_plugly ] && [ "$(field w-one 4)" = 410 ]'
cm_lane_handle w-one >"$ROOT/out" 2>/dev/null; RC=$?
check "plugly: ...and the reader serves it (the pid check agrees)" '[ "$RC" = 0 ] && [ "$(cat "$ROOT/out")" = term_on_plugly ]'
mkledger; rm -rf -- "${CM_HOME:?}/lanes"; reset_proc; mkproc 411 "$WT" "" claude
penv 411 'ORCA_TERMINAL_HANDLE=term_inherited\0PLUGLY_TERMINAL_HANDLE=term_real_plugly\0'
lh --quiet
check "plugly: an agent started from an Orca shell (both set, different): the file holds the PLUGLY handle, not the inherited ORCA one" '[ "$(field w-one 1)" = term_real_plugly ]'
rm -rf -- "${CM_HOME:?}/lanes"

echo
printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
