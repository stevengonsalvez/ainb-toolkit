#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# shellcheck disable=SC2016  # check bodies are single-quoted on purpose: they are eval-ed later
# abrupt-duplicate.sh (test): the DUPLICATE live agents check of scripts/abrupt.sh, hermetic.
# Root cause pinned: one `pgrep -x claude` sample flagged a worktree for a short-lived claude
# (a hook, a `claude -p` child) and the alarm was false twice. Covers: two pids that persist (flagged, pid
# list); one pid plus a pid that exits before the second sample (not flagged); one long-lived plus a `-p`,
# `--print` or `--print=json` child (not flagged); two worktrees with one agent each (not flagged); a pid
# whose cwd changes between samples (not counted); an out-of-scope worktree (not flagged); resample 0 keeps
# the one-sample behaviour (and the -p filter); the wait is CM_ABRUPT_RESAMPLE seconds, default 3, a bad
# value (or one of 10+ seconds) falls back to 3; no wait when the first sample holds no shared cwd; a pid replaced
# in the same cwd; a pid that vanishes mid-scan leaves stderr empty; CM_PROC_ROOT is ignored without CM_TEST=1.
# Root cause: pgrep -x claude matches comm, and Claude Code's Bash tool re-executes the claude
# binary as its embedded ugrep/bfs helper (comm claude, argv[0] ugrep, 2 to 3 s, the cwd of the lane that ran the
# grep). cm_claude_pids counts a pid only when argv[0] has basename claude: helper not counted, real agents counted
# (plain, full path, path with spaces, process title), empty cmdline dropped, unreadable one kept, the agent-gone
# live check and resume.sh claude_cwds use it too.
# Evidence capture: each flagged pid also gets a `DUPLICATE detail:` row (ppid, parent and
# grandparent comm and cmdline, age, tty, own cmdline; control characters stripped, 200 chars) and a timestamped
# line in $CM_HOME/abrupt-duplicates.log (0600, capped ~200 KB, best effort, never fatal); the DUPLICATE row and
# the counting rules are unchanged (the cases above compare only the non-detail rows).
# A fake pgrep, ps and sleep on PATH, a fake /proc root, a stub Orca with no sessions, synthetic paths under
# /acme/, a mktemp dir. No real process, no real wait, nothing else touched.
#
#   scripts/test/abrupt-duplicate.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ABRUPT="$HERE/../abrupt.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-abrupt-dup.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n%s\n' "$1" "${2:-}"; }
check() { if (eval "$2"); then ok "$1"; else bad "$1" "${3:-}"; fi; }
export HOME="$ROOT/home" CM_HOME="$ROOT/cm"
mkdir -p "$HOME" "$CM_HOME"

BIN="$ROOT/bin"; mkdir -p "$BIN"
# stub orca: no worktrees, no terminals, no remote hosts
cat > "$BIN/orca" <<'STUB'
#!/usr/bin/env bash
printf '{"ok":true,"result":{"worktrees":[],"terminals":[],"hosts":[]}}\n'
STUB
# fake pgrep: call N prints $PGFX/pgrep.N (else the highest earlier one); $PGFX/hook.N runs first when present
cat > "$BIN/pgrep" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "$PGFX/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$PGFX/n"
[ -r "$PGFX/hook.$n" ] && . "$PGFX/hook.$n"
i=$n; while [ "$i" -ge 1 ]; do [ -r "$PGFX/pgrep.$i" ] && { cat "$PGFX/pgrep.$i"; exit 0; }; i=$((i - 1)); done
exit 1
STUB
# fake sleep: records its argument, never waits
cat > "$BIN/sleep" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$PGFX/sleep.log"
STUB
# fake ps: `ps -o etimes= -p PID` prints $PGFX/etimes.PID, `ps -o tty= -p PID` prints $PGFX/tty.PID (else nothing, exit 1)
cat > "$BIN/ps" <<'STUB'
#!/usr/bin/env bash
pid=""; what=etimes; while [ $# -gt 0 ]; do [ "$1" = -p ] && pid="$2"; [ "$1" = "tty=" ] && what=tty; shift; done
[ -r "$PGFX/$what.$pid" ] && { cat "$PGFX/$what.$pid"; exit 0; }
exit 1
STUB
chmod +x "$BIN/orca" "$BIN/pgrep" "$BIN/sleep" "$BIN/ps"

N=0
fresh() {
  N=$((N + 1)); FX="$ROOT/case$N"; mkdir -p "$FX/proc" "$FX/wt/acme/one" "$FX/wt/acme/two" "$FX/wt/other/out"
  export CM_HOME="$FX/cm"; mkdir -p "$CM_HOME"   # one state dir per case: the evidence log never carries over
}
# mkproc <pid> <cwd> <argv...>: one fake pid dir (cmdline NUL separated)
mkproc() { local pid="$1" cwd="$2"; shift 2; mkdir -p "$FX/proc/$pid"; ln -sfn "$cwd" "$FX/proc/$pid/cwd"; printf '%s\0' "$@" > "$FX/proc/$pid/cmdline"; }
# mkmeta <pid> <ppid> <tty_nr> [comm]: status and stat for a fake pid (the fields abrupt.sh reads)
mkmeta() {
  local pid="$1" pp="$2" tty="$3" comm="${4:-claude}"
  printf 'Name:\t%s\nState:\tS (sleeping)\nPid:\t%s\nPPid:\t%s\n' "$comm" "$pid" "$pp" > "$FX/proc/$pid/status"
  printf '%s (%s) S %s 1 1 %s -1 4194304 0 0\n' "$pid" "$comm" "$pp" "$tty" > "$FX/proc/$pid/stat"
}
# samples <list1> [list2]: what the first and the second pgrep call print
# shellcheck disable=SC2086  # the pid lists are split on purpose
samples() { printf '%s\n' $1 > "$FX/pgrep.1"; [ $# -ge 2 ] && printf '%s\n' $2 > "$FX/pgrep.2"; return 0; }
# run [VAR=value ...]: abrupt.sh against the fake root, stdout only
run() {
  env PATH="$BIN:$PATH" PGFX="$FX" CM_TEST=1 CM_PROC_ROOT="$FX/proc" CM_PATH_MATCH=/acme/ \
    CM_CONFIG="$HERE/fixtures/config.test.yaml" ORCA_CLI_COMMAND="$BIN/orca" "$@" bash "$ABRUPT" 2>"$FX/stderr" \
    | tee "$FX/full" | grep -v 'DUPLICATE detail:'
}
# full: every stdout row of the last run, detail rows included
full() { cat "$FX/full"; }
# fmode <file>: octal permission bits, GNU or BSD stat
fmode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
dups() { grep -c 'DUPLICATE live agents' <<<"$1" || true; }

echo "--- two samples, a pid counts only when it survives both"
fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude
samples "101 102" "101 102"
OUT="$(run)"
check "two persistent claudes in one worktree: flagged once, pid list" '[ "$(dups "$OUT")" = 1 ] && [ "$OUT" = "$(printf "local\tone\t-\tDUPLICATE live agents: 101 102")" ]' "$OUT"
check "two samples taken, one wait of 3 seconds by default" '[ "$(cat "$FX/n")" = 2 ] && [ "$(cat "$FX/sleep.log")" = 3 ]'

fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude
samples "101 102" "101"
OUT="$(run)"
check "one long-lived plus a pid that exits before the second sample: not flagged" '[ "$(dups "$OUT")" = 0 ] && [ -z "$OUT" ]' "$OUT"

fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude
samples "101 102" "101 102"
ln -sfn "$FX/wt/acme/two" "$FX/proc/102/cwd"
OUT="$(run)"
check "two claudes in two worktrees: not flagged" '[ "$(dups "$OUT")" = 0 ]' "$OUT"

fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude
samples "101 102" "101 102"
printf 'ln -sfn "%s" "$PGFX/proc/102/cwd"\n' "$FX/wt/acme/two" > "$FX/hook.2"
OUT="$(run)"
check "a pid whose cwd differs between the samples is not counted (pid reuse)" '[ "$(dups "$OUT")" = 0 ]' "$OUT"

fresh; W="$FX/wt/other/out"
mkproc 101 "$W" claude; mkproc 102 "$W" claude
samples "101 102" "101 102"
OUT="$(run)"
check "two claudes in a worktree outside path_match: not flagged" '[ "$(dups "$OUT")" = 0 ]' "$OUT"

fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude; mkproc 103 "$W" claude
samples "101 102 103" "101 103"
OUT="$(run)"
check "three at first, one exits: the two survivors are flagged, the leaver is not listed" '[ "$OUT" = "$(printf "local\tone\t-\tDUPLICATE live agents: 101 103")" ]' "$OUT"

fresh; W="$FX/wt/acme/with space"; mkdir -p "$W"
mkproc 101 "$W" claude; mkproc 102 "$W" claude
samples "101 102" "101 102"
OUT="$(run)"
check "a worktree path with a space: flagged whole, pid list intact" '[ "$OUT" = "$(printf "local\twith space\t-\tDUPLICATE live agents: 101 102")" ]' "$OUT"

fresh; W="$FX/wt/acme/back\\slash\\n"; mkdir -p "$W"
mkproc 101 "$W" claude; mkproc 102 "$W" claude
samples "101 102" "101 102"
OUT="$(run)"
check "a worktree path with backslashes: pid list intact (no awk escape handling)" '[ "$OUT" = "$(printf "local\t%s\t-\tDUPLICATE live agents: 101 102" "back\\slash\\n")" ]' "$OUT"

echo "--- headless one-shots (claude -p) are ignored"
for flag in -p --print --print=json; do
  fresh; W="$FX/wt/acme/one"
  mkproc 101 "$W" claude --dangerously-skip-permissions; mkproc 102 "$W" claude "$flag" "summarise this"
  samples "101 102" "101 102"
  OUT="$(run)"
  check "one long-lived plus a 'claude $flag' child that survives both samples: not flagged" '[ "$(dups "$OUT")" = 0 ]' "$OUT"
done
fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude "fix the -p flag"
samples "101 102" "101 102"
OUT="$(run)"
check "a -p inside a prompt argument is not a headless run: both counted" '[ "$(dups "$OUT")" = 1 ]' "$OUT"
fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude -p x; mkproc 103 "$W" claude
samples "101 102 103" "101 102 103"
OUT="$(run)"
check "two real claudes plus a -p child: flagged, the -p pid is not in the list" '[ "$OUT" = "$(printf "local\tone\t-\tDUPLICATE live agents: 101 103")" ]' "$OUT"

echo "--- CM_ABRUPT_RESAMPLE"
fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude
samples "101 102" "101"
OUT="$(run CM_ABRUPT_RESAMPLE=0)"
check "resample 0: one sample, the transient pid still counts (old behaviour), no wait" '[ "$(dups "$OUT")" = 1 ] && [ "$(cat "$FX/n")" = 1 ] && [ ! -e "$FX/sleep.log" ]' "$OUT"
fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude -p x
samples "101 102"
OUT="$(run CM_ABRUPT_RESAMPLE=0)"
check "resample 0 still ignores a -p child" '[ "$(dups "$OUT")" = 0 ]' "$OUT"
fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude
samples "101 102" "101 102"
OUT="$(run CM_ABRUPT_RESAMPLE=5)"
check "resample 5: waits 5 seconds between the samples" '[ "$(cat "$FX/sleep.log")" = 5 ] && [ "$(dups "$OUT")" = 1 ]' "$OUT"
for v in abc -1 "1e3" . 1.2.3 10 99 100 999 ""; do
  fresh; W="$FX/wt/acme/one"
  mkproc 101 "$W" claude; mkproc 102 "$W" claude
  samples "101 102" "101 102"
  OUT="$(run CM_ABRUPT_RESAMPLE="$v")"
  check "resample '$v': falls back to the default 3 seconds" '[ "$(cat "$FX/sleep.log")" = 3 ] && [ "$(dups "$OUT")" = 1 ]' "$OUT"
done

for v in 0 00 0.0; do
  fresh; W="$FX/wt/acme/one"
  mkproc 101 "$W" claude; mkproc 102 "$W" claude
  samples "101 102" "101"
  OUT="$(run CM_ABRUPT_RESAMPLE="$v")"
  check "resample '$v' is a zero wait: one sample, no sleep, the pair is flagged" '[ "$(cat "$FX/n")" = 1 ] && [ ! -e "$FX/sleep.log" ] && [ "$(dups "$OUT")" = 1 ]' "$OUT"
done
for v in 0.5 1.5 9 9.9; do
  fresh; W="$FX/wt/acme/one"
  mkproc 101 "$W" claude; mkproc 102 "$W" claude
  samples "101 102" "101 102"
  OUT="$(run CM_ABRUPT_RESAMPLE="$v")"
  check "resample '$v' is accepted as the wait" '[ "$(cat "$FX/sleep.log")" = "$v" ] && [ "$(dups "$OUT")" = 1 ]' "$OUT"
done

for v in abc 15 100; do
  fresh; W="$FX/wt/acme/one"
  mkproc 101 "$W" claude; mkproc 102 "$W" claude
  samples "101 102" "101 102"
  OUT="$(run CM_ABRUPT_RESAMPLE="$v")"
  check "resample '$v' rejected: stderr names the variable and the fallback" 'grep -q "CM_ABRUPT_RESAMPLE=.$v.*using 3" "$FX/stderr"' "$(cat "$FX/stderr")"
done
fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude
samples "101 102" "101 102"
OUT="$(run)"
check "no CM_ABRUPT_RESAMPLE set: no warning on stderr" '[ ! -s "$FX/stderr" ]' "$(cat "$FX/stderr")"

echo "--- the second sample is taken only when the first can hold a duplicate"
fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$FX/wt/acme/two" claude
samples "101 102" "101 102"
OUT="$(run)"
check "no shared cwd in the first sample: one pgrep, no wait, nothing flagged" '[ "$(cat "$FX/n")" = 1 ] && [ ! -e "$FX/sleep.log" ] && [ -z "$OUT" ]' "$OUT"
fresh; W="$FX/wt/other/out"
mkproc 101 "$W" claude; mkproc 102 "$W" claude
samples "101 102" "101 102"
OUT="$(run)"
check "a pair sharing a cwd outside path_match does not trigger the wait: one pgrep, no wait" '[ "$(cat "$FX/n")" = 1 ] && [ ! -e "$FX/sleep.log" ] && [ -z "$OUT" ]' "$OUT"
fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude; mkproc 103 "$W" claude
samples "101 102" "101 103"
OUT="$(run)"
check "a pid replaced by a new pid in the same cwd between the samples: only 101 survives, not flagged" '[ "$(dups "$OUT")" = 0 ]' "$OUT"

echo "--- a pid that vanishes mid-scan is silent"
fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude
samples "101 102 103" "101"
OUT="$(run)"
check "pids listed by pgrep with no /proc entry: no stderr, not flagged" '[ ! -s "$FX/stderr" ] && [ "$(dups "$OUT")" = 0 ]' "$(cat "$FX/stderr")"
fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude
samples "101 102 103" "101 102 103"
OUT="$(run)"
check "a vanished third pid next to a real pair: pair flagged, stderr empty" '[ ! -s "$FX/stderr" ] && [ "$OUT" = "$(printf "local\tone\t-\tDUPLICATE live agents: 101 102")" ]' "$OUT"

echo "--- evidence: DUPLICATE detail rows and the log"
# a tree: 1 init -> 200 bash (grandparent) -> 300 node (parent) -> 101 claude (tty) and 102 claude (no tty)
fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude --resume; mkproc 102 "$W" claude --dangerously-skip-permissions
mkproc 300 "$W" node /opt/agent/spawn.js --task x; mkproc 200 "$W" bash -lc "orca run"
mkmeta 101 300 34816 claude; mkmeta 102 300 0 claude; mkmeta 300 200 0 node; mkmeta 200 1 34817 bash
printf '125\n' > "$FX/etimes.101"; printf ' 63\n' > "$FX/etimes.102"
samples "101 102" "101 102"
OUT="$(run)"; FULL="$(full)"
check "stderr stays empty with the evidence capture" '[ ! -s "$FX/stderr" ]' "$(cat "$FX/stderr")"
check "first row unchanged and first; one detail row per pid after it" '[ "$(head -n 1 <<<"$FULL")" = "$(printf "local\tone\t-\tDUPLICATE live agents: 101 102")" ] && [ "$(wc -l <<<"$FULL" | tr -d " ")" = 3 ] && [ "$(grep -c "DUPLICATE detail:" <<<"$FULL")" = 2 ]' "$FULL"
check "every row has exactly four tab-separated columns" '[ "$(awk -F"\t" "NF != 4" <<<"$FULL" | wc -l | tr -d " ")" = 0 ]' "$FULL"
D1="$(grep 'pid=101 ' <<<"$FULL")"; D2="$(grep 'pid=102 ' <<<"$FULL")"
check "pid 101: ppid, age, tty set, comm and cmdline" 'grep -qF "pid=101 ppid=300 age=125s tty=set:34816 comm=[claude] cmd=[claude --resume]" <<<"$D1"' "$D1"
check "pid 102: no controlling tty, its own age and cmdline" 'grep -qF "pid=102 ppid=300 age=63s tty=none comm=[claude] cmd=[claude --dangerously-skip-permissions]" <<<"$D2"' "$D2"
check "parent and grandparent: pid, comm and cmdline" 'grep -qF "parent=[300:node:node /opt/agent/spawn.js --task x] grandparent=[200:bash:bash -lc orca run]" <<<"$D1"' "$D1"
check "detail row names the worktree and keeps the DUPLICATE detail: marker" '[ "$(cut -f1-3 <<<"$D1")" = "$(printf "local\tone\t-")" ] && [ "$(cut -f4 <<<"$D1" | cut -c1-17)" = "DUPLICATE detail:" ]' "$D1"
LOG="$CM_HOME/abrupt-duplicates.log"
check "log written: one timestamped line per pid, worktree path and the detail text" '[ "$(wc -l < "$LOG" | tr -d " ")" = 2 ] && grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z	local	$FX/wt/acme/one	DUPLICATE detail: pid=101 ppid=300 age=125s" "$LOG"' "$(cat "$LOG" 2>/dev/null)"
check "log is owner-only (0600)" '[ "$(fmode "$LOG")" = 600 ]' "$(fmode "$LOG")"
OUT="$(run)"
check "a second run for the same pids logs nothing new (a persistent pair does not flood the log), rows still printed" '[ "$(wc -l < "$LOG" | tr -d " ")" = 2 ] && [ "$(grep -c "DUPLICATE detail:" <<<"$(full)")" = 2 ]' "$(cat "$LOG")"
mkproc 103 "$W" claude; mkmeta 103 300 0 claude; samples "101 102 103" "101 102 103"
OUT="$(run)"
check "a third pid in the same worktree is logged on its own (3 lines)" '[ "$(wc -l < "$LOG" | tr -d " ")" = 3 ] && tail -n 1 "$LOG" | grep -qF "pid=103 "' "$(cat "$LOG")"

echo "--- evidence: missing pieces, hostile cmdlines"
fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude
mkmeta 101 999 0 claude; mkmeta 102 1 0 claude
samples "101 102" "101 102"
OUT="$(run)"; FULL="$(full)"
check "parent pid with no /proc entry: parent=[999:gone], no grandparent, no ps age = ?" 'grep -qF "pid=101 ppid=999 age=?s tty=none comm=[claude] cmd=[claude] parent=[999:gone] grandparent=[?:gone]" <<<"$FULL"' "$FULL"
check "parent init (pid 1) with no /proc entry: parent=[1:gone]" 'grep -qF "pid=102 ppid=1 age=?s" <<<"$FULL" && grep -qF "parent=[1:gone]" <<<"$FULL"' "$FULL"
check "no stderr for the missing pieces" '[ ! -s "$FX/stderr" ]' "$(cat "$FX/stderr")"

fresh; W="$FX/wt/acme/one"
LONG="$(printf 'x%.0s' $(seq 1 400))"
mkproc 101 "$W" claude "$LONG"; mkproc 102 "$W" claude "$(printf 'a\tb\033[31mred\rend')" "tail"
mkmeta 101 1 0 claude; mkmeta 102 1 0 claude
samples "101 102" "101 102"
OUT="$(run)"; FULL="$(full)"
check "a 400-char cmdline is cut to 200 characters" '[ "$(grep "pid=101 " <<<"$FULL" | sed "s/.* cmd=\[\(.*\)\] parent=.*/\1/" | tr -d "\n" | wc -c | tr -d " ")" = 200 ]' "$(grep 'pid=101 ' <<<"$FULL" | cut -c1-120)"
check "tab, ESC and CR in a cmdline are stripped: still four columns, no control character in any row" '[ "$(awk -F"\t" "NF != 4" <<<"$FULL" | wc -l | tr -d " ")" = 0 ] && ! grep -q "[[:cntrl:]]" <<<"$(tr -d "\t" <<<"$FULL")" && grep -qF "cmd=[claude ab[31mredend tail]" <<<"$FULL"' "$(cat -v <<<"$FULL")"
check "the stripped cmdline reaches the log without control characters either" '! grep -q "[[:cntrl:]]" <<<"$(tr -d "\t" < "$CM_HOME/abrupt-duplicates.log")"' "$(cat -v "$CM_HOME/abrupt-duplicates.log")"

echo "--- evidence: secrets in an argv are redacted, a detail row names the full worktree path"
fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude bash -lc "ANTHROPIC_API_""KEY=abc123 claude --token hunter2 --api-key=zzz9 --resume"
mkproc 102 "$W" claude node server.js --password hunter3 GH_TOKEN=ghx
mkmeta 101 1 0 bash; mkmeta 102 1 0 node
samples "101 102" "101 102"
OUT="$(run)"; FULL="$(full)"
check "NAME=value and --token/--api-key/--password values are redacted; the rest of the argv stays" 'grep -qF "cmd=[claude bash -lc ANTHROPIC_API_KEY=<redacted> claude --token <redacted> --api-key=<redacted> --resume]" <<<"$FULL" && grep -qF "cmd=[claude node server.js --password <redacted> GH_TOKEN=<redacted>]" <<<"$FULL"' "$FULL"
check "no secret value reaches the rows or the log" '! grep -qE "abc123|hunter2|hunter3|zzz9" <<<"$FULL" && ! grep -qE "abc123|hunter2|hunter3|zzz9" "$CM_HOME/abrupt-duplicates.log"' "$FULL"

fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude sh -c "curl --access-token t0k1 --auth-token a1 -H Authorization:Bearer-b2 -H 'Authorization: Bearer b3' --password 'p w9' http://h/x"
mkmeta 101 1 0 claude; mkmeta 102 1 0 sh
samples "101 102" "101 102"
OUT="$(run)"; FULL="$(full)"
check "--access-token, --auth-token, Authorization/Bearer and a quoted --password value are redacted" '! grep -qE "t0k1|a1 |b2|b3|p w9| w9" <<<"$FULL" && grep -qF -- "--access-token <redacted>" <<<"$FULL" && grep -qF "Authorization: <redacted> <redacted>" <<<"$FULL"' "$FULL"
fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude sh -c "export DB=postgres://usr:pw0rd@db/x; claude"
mkmeta 101 1 0 claude; mkmeta 102 1 0 sh
samples "101 102" "101 102"
OUT="$(run)"; FULL="$(full)"
check "a URL with user:pass@ is redacted, the rest of the cmdline stays" 'grep -qF "cmd=[claude sh -c export DB=<redacted>; claude]" <<<"$FULL" && ! grep -q pw0rd <<<"$FULL"' "$FULL"

fresh; W="$FX/wt/acme/one"
FAKE_TOK="gh""p_""0123456789abcdef""ghijklmnop""qrstuvwxyz01"   # built at run time: no token-shaped literal in the file
mkproc 101 "$W" claude; mkproc 102 "$W" claude sh -c "curl -H x $FAKE_TOK https://x"
mkmeta 101 1 0 claude; mkmeta 102 1 0 sh
samples "101 102" "101 102"
OUT="$(run)"; FULL="$(full)"
check "a named credential shape (ghp_...) is redacted, the rest of the cmdline stays" 'grep -qF "comm=[sh] cmd=[claude sh -c curl -H x <redacted> https://x]" <<<"$FULL" && ! grep -q "ghp_0123" <<<"$FULL"' "$FULL"

fresh; A="$FX/wt/acme/a/app"; B="$FX/wt/acme/b/app"; mkdir -p "$A" "$B"
mkproc 101 "$A" claude; mkproc 102 "$A" claude; mkproc 103 "$B" claude; mkproc 104 "$B" claude
samples "101 102 103 104" "101 102 103 104"
OUT="$(run)"; FULL="$(full)"
check "two worktrees with one leaf name: each detail row ends with its own full path" 'grep "pid=101 " <<<"$FULL" | grep -qF "wt=[$A]" && grep "pid=104 " <<<"$FULL" | grep -qF "wt=[$B]"' "$FULL"

echo "--- evidence: a pid gone by flag time keeps its first-sample evidence"
# fake paste (called between the second sample and the detail read) moves pid 102 out of the fake /proc once
cat > "$BIN/paste" <<'STUB'
#!/usr/bin/env bash
[ -e "$PGFX/vanish" ] && [ -d "$PGFX/proc/102" ] && mv "$PGFX/proc/102" "$PGFX/gone-102"
exec /usr/bin/paste "$@"
STUB
chmod +x "$BIN/paste"
fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude --resume; mkproc 300 "$W" node spawn.js
mkmeta 101 300 0 claude; mkmeta 102 300 0 claude; mkmeta 300 1 0 node
printf '9\n' > "$FX/etimes.102"
samples "101 102" "101 102"; : > "$FX/vanish"
OUT="$(run)"; FULL="$(full)"
check "pid 102 exits after the second sample: still in the DUPLICATE row, detail from the first sample, marked exited-before-flag=1" '[ "$(dups "$OUT")" = 1 ] && grep "pid=102 " <<<"$FULL" | grep -qF "ppid=300 age=9s" && grep "pid=102 " <<<"$FULL" | grep -qF "parent=[300:node:node spawn.js]" && grep "pid=102 " <<<"$FULL" | grep -qF "exited-before-flag=1"' "$FULL"
check "the snapshot detail is logged too" 'grep -qF "exited-before-flag=1" "$CM_HOME/abrupt-duplicates.log"'
fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude --resume
mkmeta 101 1 0 claude; mkmeta 102 1 0 claude
samples "101 102" "101 102"
OUT="$(run)"; FULL="$(full)"
check "control: a pid still alive at flag time is not marked exited-before-flag" '! grep -qF "exited-before-flag" <<<"$FULL"' "$FULL"

fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude --author-mode "long inline prompt" --keyboard us -u admin:hunter9 caf$'\xc3\xa9'
mkmeta 101 1 0 claude; mkmeta 102 1 0 claude
samples "101 102" "101 102"
OUT="$(run)"; FULL="$(full)"
check "a flag that only contains a keyword (--author-mode, --keyboard) keeps its value; -u user:pass is redacted; non-ASCII becomes ?" 'grep -qF -- "--author-mode long inline prompt --keyboard us -u <redacted> caf??" <<<"$FULL" && ! grep -q hunter9 <<<"$FULL"' "$FULL"
fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude; mkmeta 101 1 0 claude; mkmeta 102 1 0 claude
samples "101 102"; : > "$FX/vanish"
OUT="$(run CM_ABRUPT_RESAMPLE=0)"
check "a pid that vanishes with no snapshot (one sample): reported gone=1" 'grep -qF "pid=102 gone=1 wt=[" <<<"$(full)"' "$(full)"
mv "$FX/gone-102" "$FX/proc/102"
OUT="$(run CM_ABRUPT_RESAMPLE=0)"
check "a gone pid line (no age) is logged once, not on every tick" '[ "$(grep -c "pid=102 gone=1" "$CM_HOME/abrupt-duplicates.log")" = 1 ]' "$(cat "$CM_HOME/abrupt-duplicates.log")"

fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude --note "x gone=1 y"; mkproc 102 "$W" claude sh -c "curl -H 'X-Api-Key: sk9' -e TOKEN='abc def" 
mkmeta 101 1 0 claude; mkmeta 102 1 0 sh
samples "101 102" "101 102"
OUT="$(run)"; FULL="$(full)"
check "a live pid whose argv says gone=1 is not taken for an exited pid" '! grep -qF "exited-before-flag" <<<"$FULL" && grep -qF "cmd=[claude --note x gone=1 y]" <<<"$FULL"' "$FULL"
check "header-style secret (X-Api-Key: v) and an unterminated quote are redacted to the end" '! grep -qE "sk9|abc|def" <<<"$FULL" && grep -qF "X-Api-Key: <redacted>" <<<"$FULL"' "$FULL"
fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude node /opt/foo-auth /workspace --keyboard
mkmeta 101 1 0 claude; mkmeta 102 1 0 node
samples "101 102" "101 102"
OUT="$(run)"; FULL="$(full)"
check "a keyword inside a path (/opt/foo-auth) does not redact the next word" 'grep -qF "cmd=[claude node /opt/foo-auth /workspace --keyboard]" <<<"$FULL"' "$FULL"

fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude wrapper --password "my secret pass" -H "Authorization: token abc9" --author=Bob\ Smith --note=free --db-url "x y" -u "ad min" MY_API_KEY=k8
mkmeta 101 1 34816 claude; mkmeta 102 1 0 wrapper; printf ' pts/3\n' > "$FX/tty.101"
samples "101 102" "101 102"
OUT="$(run)"; FULL="$(full)"
check "an argument after --password / -u stays whole when it has spaces; an Authorization: header argument is redacted to its end" '! grep -qE "secret pass|abc9|ad min|k8" <<<"$FULL" && grep -qF "wrapper --password <redacted> -H Authorization: <redacted> --author=Bob Smith --note=free --db-url x y -u <redacted> MY_API_KEY=<redacted>" <<<"$FULL"' "$FULL"
check "tty shows the terminal name when ps has one" 'grep -qF "pid=101 ppid=1 age=?s tty=set:34816/pts/3 " <<<"$FULL"' "$FULL"

fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude node srv --api_key SECRETVALUE1 --apikey XYZ99 --accesstoken T0K --monkey-business ok
mkmeta 101 1 0 claude; mkmeta 102 1 0 node
samples "101 102" "101 102"
OUT="$(run)"; FULL="$(full)"
check "underscore and joined flag spellings (--api_key, --apikey, --accesstoken) redact the next argument" '! grep -qE "SECRETVALUE1|XYZ99|T0K" <<<"$FULL" && grep -qF "node srv --api_key <redacted> --apikey <redacted> --accesstoken <redacted> --monkey-business ok" <<<"$FULL"' "$FULL"
fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude runner --session "$(printf 'ab%.0s' $(seq 1 32))" --who ci
mkmeta 101 1 0 claude; mkmeta 102 1 0 runner
samples "101 102" "101 102"
OUT="$(run)"; FULL="$(full)"
check "a 64-hex id inside a cmdline is redacted alone; the spawner and its other arguments stay" 'grep -qF "cmd=[claude runner --session <redacted> --who ci]" <<<"$FULL"' "$FULL"

fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude --no-auth /opt/spawner.sh --skip-key a.sh "Basic setup of the lane"
mkmeta 101 1 0 claude; mkmeta 102 1 0 claude
samples "101 102" "101 102"
OUT="$(run)"; FULL="$(full)"
check "a --no-auth / --skip-key switch keeps the next argument (the spawner); the word Basic inside a sentence is not a credential" 'grep -qF "cmd=[claude --no-auth /opt/spawner.sh --skip-key a.sh Basic setup of the lane]" <<<"$FULL"' "$FULL"

echo "--- evidence: no flag, no log; the log never breaks the tick"
fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude
samples "101 102" "101"
OUT="$(run)"
check "a pid that exits before the second sample: no detail row, nothing logged" '[ -z "$(full)" ] && [ ! -s "$CM_HOME/abrupt-duplicates.log" ]' "$(full)"

fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude
samples "101 102" "101 102"
BADHOME="$FX/cm-is-a-file"; : > "$BADHOME"
OUT="$(run CM_HOME="$BADHOME")"
check "CM_HOME is a file (log cannot be written): rows still printed, stderr empty" '[ "$(dups "$OUT")" = 1 ] && [ "$(grep -c "DUPLICATE detail:" <<<"$(full)")" = 2 ] && [ ! -s "$FX/stderr" ]' "$(cat "$FX/stderr")"
fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude
samples "101 102" "101 102"
env PATH="$BIN:$PATH" PGFX="$FX" CM_TEST=1 CM_PROC_ROOT="$FX/proc" CM_PATH_MATCH=/acme/ CM_HOME="$BADHOME" \
  CM_CONFIG="$HERE/fixtures/config.test.yaml" ORCA_CLI_COMMAND="$BIN/orca" bash "$ABRUPT" >/dev/null 2>&1
RC=$?
check "an unwritable log leaves the exit status 0" '[ "$RC" -eq 0 ]' "rc=$RC"

fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude
samples "101 102" "101 102"
ln -sfn "$FX/elsewhere" "$CM_HOME/abrupt-duplicates.log"; : > "$FX/elsewhere"
OUT="$(run)"
check "a symlinked log is not followed: target untouched, rows still printed" '[ ! -s "$FX/elsewhere" ] && [ "$(dups "$OUT")" = 1 ]' "$(cat "$FX/elsewhere")"

echo "--- evidence: the log is capped near 200 KB, oldest lines dropped"
fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude
samples "101 102" "101 102"
CAPLOG="$ROOT/cap-home"; mkdir -p "$CAPLOG"
awk 'BEGIN { for (i = 1; i <= 3000; i++) printf "2026-01-01T00:00:00Z\told-line-%05d %0100d\n", i, 0 }' > "$CAPLOG/abrupt-duplicates.log"
BEFORE=$(wc -c < "$CAPLOG/abrupt-duplicates.log")
OUT="$(run CM_HOME="$CAPLOG")"
AFTER=$(wc -c < "$CAPLOG/abrupt-duplicates.log")
check "seed log was over the cap" '[ "$BEFORE" -gt 204800 ]' "$BEFORE"
check "log trimmed to under 200 KB" '[ "$AFTER" -le 204800 ] && [ "$AFTER" -gt 100000 ]' "$AFTER"
check "oldest lines dropped, newest kept, first line whole, new lines present" '! grep -q "old-line-00001 " "$CAPLOG/abrupt-duplicates.log" && grep -q "old-line-03000 " "$CAPLOG/abrupt-duplicates.log" && head -n 1 "$CAPLOG/abrupt-duplicates.log" | grep -q "^2026-01-01T00:00:00Z	old-line-" && [ "$(grep -c "DUPLICATE detail:" "$CAPLOG/abrupt-duplicates.log")" = 2 ]' "$(head -c 200 "$CAPLOG/abrupt-duplicates.log")"
check "trimmed log is still owner-only" '[ "$(fmode "$CAPLOG/abrupt-duplicates.log")" = 600 ]'

echo "--- only real claude agents count (cm_claude_pids): the embedded ugrep/bfs helper is not an agent"
# pgrep -x claude lists a pid by comm; Claude Code's Bash tool re-executes the claude binary as ugrep or bfs,
# so comm is claude but argv[0] is not. The fake pgrep below lists every such pid, as the real one does.
fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude --dangerously-skip-permissions; mkproc 102 "$W" ugrep -r --color=never needle .
samples "101 102" "101 102"
OUT="$(run)"
check "comm claude with argv[0] ugrep is not a second agent: nothing flagged, one pgrep, no wait" '[ -z "$OUT" ] && [ -z "$(full)" ] && [ "$(cat "$FX/n")" = 1 ] && [ ! -e "$FX/sleep.log" ]' "$(full)"
for helper in ugrep bfs /usr/lib/claude/ugrep "/opt/My Apps/bfs"; do
  fresh; W="$FX/wt/acme/one"
  mkproc 101 "$W" claude; mkproc 102 "$W" "$helper" -r x
  samples "101 102" "101 102"
  OUT="$(run)"
  check "argv[0] '$helper' (embedded helper) is not counted" '[ "$(dups "$OUT")" = 0 ]' "$(full)"
done
fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" ugrep x; mkproc 103 "$W" bfs y
samples "101 102 103" "101 102 103"
OUT="$(run)"
check "one real claude plus two helpers: not flagged" '[ "$(dups "$OUT")" = 0 ]' "$(full)"
fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude; mkproc 103 "$W" ugrep x
samples "101 102 103" "101 102 103"
OUT="$(run)"
check "two real claudes plus a helper: flagged, the helper pid is not in the list" '[ "$OUT" = "$(printf "local\tone\t-\tDUPLICATE live agents: 101 102")" ]' "$OUT"
for real in "claude" "/opt/acme/bin/claude" "/opt/acme apps/claude" "claude --resume abc" "/opt/my tools/claude --resume x"; do
  fresh; W="$FX/wt/acme/one"
  mkproc 101 "$W" claude; mkproc 102 "$W" "$real"
  samples "101 102" "101 102"
  OUT="$(run)"
  check "argv[0] '$real' is a real agent: counted" '[ "$(dups "$OUT")" = 1 ]' "$(full)"
done
fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude; : > "$FX/proc/102/cmdline"
samples "101 102" "101 102"
OUT="$(run)"
check "an empty cmdline (zombie) is not counted" '[ "$(dups "$OUT")" = 0 ]' "$(full)"
fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude; chmod 000 "$FX/proc/102/cmdline"
samples "101 102" "101 102"
OUT="$(run)"
check "an unreadable cmdline keeps the pid (cannot be told apart): counted" '[ "$(dups "$OUT")" = 1 ]' "$(full)"
chmod 600 "$FX/proc/102/cmdline"

# the agent-gone live check of abrupt.sh: a stub Orca with one claude terminal sitting at a bare prompt
agent_stub() {
  cat > "$FX/orca" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "worktree ps") printf '{"ok":true,"result":{"worktrees":[{"path":"$W","displayName":"one"}]}}\n' ;;
  "terminal list") printf '{"ok":true,"result":{"terminals":[{"handle":"h1","worktreePath":"$W","agentIdentity":"claude"}]}}\n' ;;
  "terminal read") printf '{"ok":true,"result":{"text":"❯ "}}\n' ;;
  "host list") printf '{"ok":true,"result":{"hosts":[]}}\n' ;;
esac
STUB
  chmod +x "$FX/orca"
}
fresh; W="$FX/wt/acme/one"; agent_stub
mkproc 101 "$W" ugrep -r needle .
samples "101"
OUT="$(run ORCA_CLI_COMMAND="$FX/orca")"
check "bare prompt and only an embedded helper has the cwd: agent gone, bare shell" '[ "$OUT" = "$(printf "local\tone\th1\tagent gone, bare shell")" ]' "$OUT"
fresh; W="$FX/wt/acme/one"; agent_stub
mkproc 101 "$W" claude
samples "101"
OUT="$(run ORCA_CLI_COMMAND="$FX/orca")"
check "control: a real claude holds the cwd: no row" '[ -z "$OUT" ]' "$OUT"

# resume.sh claude_cwds (the respawn guard input) takes the same helper
fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$FX/wt/acme/two" ugrep -r x; mkproc 103 "$FX/wt/acme/two" claude
samples "101 102 103 104"
CW="$(env PATH="$BIN:$PATH" PGFX="$FX" CM_TEST=1 CM_PROC_ROOT="$FX/proc" CM_CONFIG="$HERE/fixtures/config.test.yaml" bash -c '
  . "$1/lib.sh"; eval "$(sed -n "/^claude_cwds()/,/^}/p" "$1/resume.sh")"; claude_cwds; echo "rc=$?"' _ "$HERE/.." 2>"$FX/stderr")"
check "resume.sh claude_cwds lists the cwds of real claudes only (helper and vanished pid left out)" '[ "$CW" = "$(printf "%s\n%s\nrc=0" "$W" "$FX/wt/acme/two")" ]' "$CW / $(cat "$FX/stderr")"

echo "--- the /proc seam"
fresh; W="$FX/wt/acme/one"
mkproc 101 "$W" claude; mkproc 102 "$W" claude
samples "101 102" "101 102"
OUT="$(run)"
check "control: the same fake root with CM_TEST=1 flags the pair (so the next case is not vacuous)" '[ "$(dups "$OUT")" = 1 ]' "$OUT"
OUT="$(env PATH="$BIN:$PATH" PGFX="$FX" CM_PROC_ROOT="$FX/proc" CM_PATH_MATCH=/acme/ CM_CONFIG="$HERE/fixtures/config.test.yaml" ORCA_CLI_COMMAND="$BIN/orca" bash "$ABRUPT" 2>"$FX/stderr")"
check "CM_PROC_ROOT without CM_TEST=1 is ignored: not flagged, and stderr says why" '[ "$(dups "$OUT")" = 0 ] && grep -q "CM_PROC_ROOT ignored" "$FX/stderr"' "$OUT / $(cat "$FX/stderr")"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
