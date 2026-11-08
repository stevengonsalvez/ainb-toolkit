#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# teardown-codex-procs.sh: behaviour tests for teardown.sh stopping leftover codex processes by exact pid.
# Hermetic: a throwaway repo whose origin is a local bare repo, linked worktrees, a stubbed orca, gh,
# docker and supabase (PATH stubs, nothing real is read), and FAKE processes: a stub script named `codex`
# (a shell that runs `sleep` as its child) and plain `sleep`, each started with a controlled cwd. Every
# process the test starts is recorded and stopped by its exact pid at the end; nothing else is signalled.
# Lead mode (--owner), so no ledger. Synthetic names only.
#
#   scripts/test/teardown-codex-procs.sh      # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export CM_CONFIG="$HERE/fixtures/config.test.yaml"
unset CM_ORG CM_REPO CM_PROJECT CM_OWNER_NAME CM_OWNER_ID CM_TZ CM_TZ_LABEL CM_EXCLUDE_REPOS CM_PATH_MATCH CM_SELF_WORKTREE
TD="$HERE/../teardown.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-codexprocs.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
STARTED="$ROOT/started"   # every pid this test starts, one per line (a file: spawns run in subshells); stopped by exact pid on exit
: > "$STARTED"
killstarted() { local p; while read -r p; do [ -z "$p" ] || kill -KILL "$p" 2>/dev/null; done < "$STARTED"; }
trap 'killstarted; chmod -R u+rwx "$ROOT" 2>/dev/null; [ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
export CM_HOME="$ROOT/cmhome"
mkdir -p "$CM_HOME" "$ROOT/bin" "$ROOT/stub-term" "$ROOT/stub-stubborn" "$ROOT/sb"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export MC_TOKEN_FILE="$ROOT/no-mc-token" MC_QUIET=1
export CM_BD_CMD=cm-no-such-bd CM_TD_PROC_WAIT=2

BARE="$ROOT/github.com/AcmeOrg/acme-app.git"
git init -q --bare -b main "$BARE"
M="$ROOT/main"
git init -q -b main "$M"
git -C "$M" remote add origin "$BARE"
mkdir -p "$M/.beads"
printf '{"id":"t-x1","status":"closed","updated_at":"2026-10-01T00:00:00Z"}\n' > "$M/.beads/issues.jsonl"
printf 'redirect\n' > "$M/.beads/.gitignore"
git -C "$M" add .beads
git -C "$M" commit -qm init --no-gpg-sign
git -C "$M" push -q origin main
git -C "$M" remote set-head origin main >/dev/null 2>&1 || true
SHA="$(git -C "$M" rev-parse HEAD)"
mkwt() {
  git -C "$M" worktree add -q -b "b-$1" "$ROOT/wt/$1" main >/dev/null 2>&1
  git -C "$ROOT/wt/$1" push -q origin "b-$1" >/dev/null 2>&1
  (cd "$ROOT/wt/$1" && pwd -P)
}

cat > "$ROOT/bin/gh" <<G
#!/usr/bin/env bash
echo '[{"number":1,"state":"MERGED","headRefOid":"$SHA"}]'
G
# orca: worktree rm logs whether the watched pid (STUB_WATCH) is still alive at that moment.
cat > "$ROOT/bin/orca-stub" <<'O'
#!/usr/bin/env bash
case "$1 $2" in
  "host list") jq -cn '{ok:true,result:{hosts:[{kind:"local",name:"this machine"}]}}' ;;
  "worktree ps")
    jq -cn --arg p "$STUB_PATH" --arg n "${STUB_NAME:-x}" \
      '{ok:true,result:{worktrees:[{path:$p,worktreeId:("r::" + $n),displayName:$n,comment:"",status:"idle",agents:[],childWorktreeIds:[],liveTerminalCount:0}]}}' ;;
  "worktree list") jq -c '. + {ok:true}' "$STUB_LIST" ;;
  "terminal list") if [ -f "${STUB_TERMS:-/nonexistent}" ]; then cat "$STUB_TERMS"; else echo '{"result":{"terminals":[]}}'; fi ;;
  "terminal close") : ;;
  "worktree rm")
    w="alive"; for p in ${STUB_WATCH:-}; do kill -0 "$p" 2>/dev/null && [ "$(ps -o stat= -p "$p" 2>/dev/null | cut -c1)" != Z ] || w="dead"; done
    printf 'orca worktree rm (watched pids %s)\n' "$w" >> "${STUB_LOG:-/dev/null}"; exit 0 ;;
esac
O
# docker and supabase: nothing real is ever read or stopped (an empty, healthy docker)
printf '#!/usr/bin/env bash\nexit 0\n' > "$ROOT/bin/docker"
printf '#!/usr/bin/env bash\nexit 0\n' > "$ROOT/bin/supabase"
chmod +x "$ROOT/bin/gh" "$ROOT/bin/orca-stub" "$ROOT/bin/docker" "$ROOT/bin/supabase"
export PATH="$ROOT/bin:$PATH" ORCA_CLI_COMMAND="$ROOT/bin/orca-stub"

# Fake codex: a shell script NAMED codex that runs `sleep` as its child (so the tree is codex -> sleep).
# stub-term answers TERM; stub-stubborn ignores TERM and only dies to KILL.
printf '#!/bin/sh\nsleep 300 &\nwait\n' > "$ROOT/stub-term/codex"
printf '#!/bin/sh\ntrap "" TERM\nsleep 300 &\nwhile :; do wait; done\n' > "$ROOT/stub-stubborn/codex"
chmod +x "$ROOT/stub-term/codex" "$ROOT/stub-stubborn/codex"

LIST="$ROOT/list.json"
export STUB_LIST="$LIST" STUB_SB_DIR="$ROOT/sb"
lists() { jq -cn --arg c "$1" '{result:{worktrees:[{path:"/lead/lane-a",displayName:"lane-a",comment:$c}]}}' > "$LIST"; }

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n%s\n' "$1" "${2:-}"; }
# alive <pid>: running (a zombie is not alive)
alive() { kill -0 "$1" 2>/dev/null && [ "$(ps -o stat= -p "$1" 2>/dev/null | cut -c1)" != Z ]; }
# spawn_codex <stub dir> <cwd>: the fake codex app-server with that cwd; prints its pid
spawn_codex() {
  (cd "$2" && exec "$1/codex" app-server) >/dev/null 2>&1 &
  echo "$!" >> "$STARTED"; printf '%s' "$!"
}
# spawn_sleep <cwd>: a plain sleep with that cwd; prints its pid
spawn_sleep() { (cd "$1" && exec sleep 300) >/dev/null 2>&1 & echo "$!" >> "$STARTED"; printf '%s' "$!"; }
# child_of <pid>: the pid of its first child (waits briefly for the fake to fork it)
child_of() {
  local c
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    c="$(ps -eo pid=,ppid= | awk -v p="$1" '$2 == p { print $1; exit }')"
    [ -z "$c" ] || { echo "$c" >> "$STARTED"; printf '%s' "$c"; return 0; }
    sleep 0.3
  done
  return 1
}
OUT=""; rc=0
# td <wt> [env assignments...] -- [teardown args]
td() {
  local p="$1"; shift
  local -a envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" != -- ] || shift
  OUT="$(env STUB_PATH="$p" STUB_NAME="${p##*/}" "${envs[@]}" "$TD" local "$p" --owner lane-a "$@" 2>&1)"; rc=$?
}
has() { grep -qF -- "$1" <<<"$OUT"; }

echo "== codex app-server and its child in the worktree: planned, then stopped children first, before the rm"
A="$(mkwt cx-a)"
lists $'cm:running\ncm:child cx-a'
CP="$(spawn_codex "$ROOT/stub-term" "$A")"; sleep 0.5; CC="$(child_of "$CP")"
OUTSIDE="$(spawn_codex "$ROOT/stub-term" "$ROOT")"; sleep 0.5; OC="$(child_of "$OUTSIDE")"
mkdir -p "$A-bar"
BOUND="$(spawn_codex "$ROOT/stub-term" "$A-bar")"; sleep 0.5; BC="$(child_of "$BOUND")"
PLAIN="$(spawn_sleep "$ROOT")"
if [ -n "$CC" ] && [ -n "$OC" ] && [ -n "$BC" ]; then ok "fixture: three fake trees started (codex -> sleep)"; else bad "fixture processes did not start" "$CP/$CC $OUTSIDE/$OC $BOUND/$BC"; fi
td "$A"
if [ "$rc" = 0 ] && has "leftover codex processes in the worktree" && has "$CC:sleep $CP:codex" && has "stop leftover codex processes on local by exact pid, children first"; then
  ok "dry-run names the pids, child before parent"; else bad "dry-run" "$OUT"; fi
if alive "$CP" && alive "$CC"; then ok "dry-run signals nothing"; else bad "dry-run killed a process"; fi
LOG="$ROOT/log-a"; : > "$LOG"
td "$A" STUB_LOG="$LOG" STUB_WATCH="$CP $CC" -- --apply
if [ "$rc" = 0 ] && has "stopped codex processes on local by pid (TERM): $CC $CP"; then ok "apply prints the pids stopped, child first"; else bad "apply output" "$OUT"; fi
sleep 0.5
if ! alive "$CP" && ! alive "$CC"; then ok "the codex app-server and its child are gone"; else bad "target survived"; fi
if grep -q 'orca worktree rm (watched pids dead)' "$LOG"; then ok "they were gone BEFORE orca worktree rm ran"; else bad "ordering" "$(cat "$LOG")"; fi
if alive "$OUTSIDE" && alive "$OC"; then ok "a codex tree whose cwd is outside the worktree survives"; else bad "outside process was killed"; fi
if alive "$BOUND" && alive "$BC"; then ok "boundary: a codex tree in <worktree>-bar survives"; else bad "boundary process was killed"; fi
if alive "$PLAIN"; then ok "an unrelated sleep survives (nothing is killed by name)"; else bad "plain sleep was killed"; fi

echo "== a stubborn codex (ignores TERM) is killed after the bounded wait"
B="$(mkwt cx-b)"
lists $'cm:running\ncm:child cx-b'
SP="$(spawn_codex "$ROOT/stub-stubborn" "$B")"; sleep 0.5; SC="$(child_of "$SP")"
LOG="$ROOT/log-b"; : > "$LOG"
td "$B" STUB_LOG="$LOG" STUB_WATCH="$SP" -- --apply
if [ "$rc" = 0 ] && grep -E "^stopped codex processes on local by pid \(KILL after 2s\): .*$SP( |$)" <<<"$OUT" >/dev/null; then ok "the stubborn parent is reported killed after 2s"; else bad "stubborn output" "$OUT"; fi
sleep 0.5
if ! alive "$SP" && ! alive "$SC" && grep -q 'watched pids dead' "$LOG"; then ok "gone before the rm"; else bad "stubborn survived" "$(cat "$LOG")"; fi

echo "== a non-codex process in the worktree still blocks the teardown"
C="$(mkwt cx-c)"
lists $'cm:running\ncm:child cx-c'
NS="$(spawn_sleep "$C")"
td "$C"
if [ "$rc" = 3 ] && has "non-shell processes run in the worktree" && has "$NS:sleep" && has "no leftover codex process in the worktree"; then ok "refused, the plain sleep is named, no codex pid claimed"; else bad "non-codex process" "$OUT"; fi
if alive "$NS"; then ok "and it was not touched"; else bad "plain process killed"; fi

echo "== a codex process in a scratch dir under the worktree is covered"
D="$(mkwt cx-d)"
mkdir -p "$D/.agents/scratch/run1"
lists $'cm:running\ncm:child cx-d'
SD="$(spawn_codex "$ROOT/stub-term" "$D/.agents/scratch/run1")"; sleep 0.5; SDC="$(child_of "$SD")"
LOG="$ROOT/log-d"; : > "$LOG"
td "$D" STUB_LOG="$LOG" STUB_WATCH="$SD" -- --apply
sleep 0.5
if [ "$rc" = 0 ] && ! alive "$SD" && ! alive "$SDC"; then ok "a codex process whose cwd is .agents/scratch/<dir> is stopped"; else bad "scratch process" "$OUT"; fi

echo "== an interpreter running codex.js with option arguments is found; the stop comes before the salvage"
G="$(mkwt cx-g)"
mkdir -p "$ROOT/stub-js"
printf 'sleep 300 &\nwait\n' > "$ROOT/stub-js/codex.js"
printf '.env.local\n' >> "$(git -C "$G" rev-parse --git-common-dir)/info/exclude"
printf 'KEY=1\n' > "$G/.env.local"
lists $'cm:running\ncm:child cx-g'
(cd "$G" && exec sh -e "$ROOT/stub-js/codex.js" --max-old-space-size 4096 app-server) >/dev/null 2>&1 &
JP=$!; echo "$JP" >> "$STARTED"; sleep 0.5; JC="$(child_of "$JP")"
mkdir -p "$ROOT/home"
td "$G" HOME="$ROOT/home" -- --apply --salvage
sleep 0.5
STOP_LN="$(grep -n '^stopped codex processes' <<<"$OUT" | head -1 | cut -d: -f1)"; SALV_LN="$(grep -n '^salvaged to' <<<"$OUT" | head -1 | cut -d: -f1)"
if [ "$rc" = 0 ] && ! alive "$JP" && ! alive "$JC"; then ok "sh running codex.js (with an option and its value before app-server) is stopped"; else bad "codex.js case" "$OUT"; fi
if [ -n "$STOP_LN" ] && [ -n "$SALV_LN" ] && [ "$STOP_LN" -lt "$SALV_LN" ]; then ok "the codex stop is printed before the salvage copy"; else bad "stop vs salvage order ($STOP_LN, $SALV_LN)" "$OUT"; fi

echo "== a bare word codex after a script is an argument, not a codex process"
H="$(mkwt cx-h)"
lists $'cm:running\ncm:child cx-h'
(cd "$H" && exec bash -c 'sleep 300 & wait' run.sh codex) >/dev/null 2>&1 &
HP=$!; echo "$HP" >> "$STARTED"; sleep 0.5; HC="$(child_of "$HP")"
td "$H"
if [ "$rc" = 3 ] && has "no leftover codex process in the worktree" && has "non-shell processes run in the worktree"; then ok "bash run.sh codex is not matched: refused as an ordinary process"; else bad "loose argv match" "$OUT"; fi
if alive "$HP" && alive "$HC"; then ok "and it was not touched"; else bad "unrelated script killed"; fi

echo "== a codex process that belongs to a live terminal not named by --close-handle is not exempt"
I="$(mkwt cx-i)"
lists $'cm:running\ncm:child cx-i'
printf '{"result":{"terminals":[{"handle":"term_live_1","title":"shell"}]}}\n' > "$ROOT/terms.json"
(cd "$I" && exec env ORCA_TERMINAL_HANDLE=term_live_1 "$ROOT/stub-term/codex" app-server) >/dev/null 2>&1 &
IP=$!; echo "$IP" >> "$STARTED"; sleep 0.5; IC="$(child_of "$IP")"
td "$I" STUB_TERMS="$ROOT/terms.json" -- --apply
if [ "$rc" = 3 ] && has "non-shell processes run in the worktree" && alive "$IP" && alive "$IC"; then ok "live-terminal codex refuses and is not touched"; else bad "live terminal codex" "$OUT"; fi
td "$I" STUB_TERMS="$ROOT/terms.json" -- --close-handle term_live_1
if [ "$rc" = 0 ] && has "stop leftover codex processes"; then ok "named by --close-handle it is planned for the pid stop (dry run)"; else bad "close-handle exempts it" "$OUT"; fi

echo "== the terminal is read from PLUGLY_TERMINAL_HANDLE first (a Plugly lane, or a Plugly daemon started from an Orca shell)"
J="$(mkwt cx-j)"
lists $'cm:running\ncm:child cx-j'
(cd "$J" && exec env -u ORCA_TERMINAL_HANDLE PLUGLY_TERMINAL_HANDLE=term_live_1 "$ROOT/stub-term/codex" app-server) >/dev/null 2>&1 &
JP=$!; echo "$JP" >> "$STARTED"; sleep 0.5; JC="$(child_of "$JP")"
td "$J" STUB_TERMS="$ROOT/terms.json" -- --apply
if [ "$rc" = 3 ] && has "non-shell processes run in the worktree" && alive "$JP" && alive "$JC"; then ok "plugly: only PLUGLY_TERMINAL_HANDLE set: the live terminal still refuses"; else bad "plugly only" "$OUT"; fi
td "$J" STUB_TERMS="$ROOT/terms.json" -- --close-handle term_live_1
if [ "$rc" = 0 ] && has "stop leftover codex processes"; then ok "plugly: named by --close-handle it is planned for the pid stop"; else bad "plugly close-handle" "$OUT"; fi
K="$(mkwt cx-k)"
lists $'cm:running\ncm:child cx-k'
(cd "$K" && exec env ORCA_TERMINAL_HANDLE=term_inherited PLUGLY_TERMINAL_HANDLE=term_live_1 "$ROOT/stub-term/codex" app-server) >/dev/null 2>&1 &
KP=$!; echo "$KP" >> "$STARTED"; sleep 0.5; KC="$(child_of "$KP")"
td "$K" STUB_TERMS="$ROOT/terms.json" -- --apply
if [ "$rc" = 3 ] && has "non-shell processes run in the worktree" && alive "$KP" && alive "$KC"; then ok "plugly: both set and different: PLUGLY wins (the live terminal), the inherited ORCA handle is ignored: refuses"; else bad "plugly wins over inherited orca" "$OUT"; fi

# a real process whose environ holds PLUGLY_TERMINAL_HANDLE twice (env(1) cannot make a duplicate, so execve is called through ctypes)
if command -v python3 >/dev/null 2>&1; then
  M="$(mkwt cx-m)"
  lists $'cm:running\ncm:child cx-m'
  (cd "$M" && exec python3 -c 'import ctypes,sys
l=ctypes.CDLL(None); p=sys.argv[1].encode()
a=(ctypes.c_char_p*3)(p,b"app-server",None)
e=(ctypes.c_char_p*4)(b"PLUGLY_TERMINAL_HANDLE=term_live_1",b"PATH=/usr/bin:/bin",b"PLUGLY_TERMINAL_HANDLE=term_other",None)
l.execve(p,a,e)' "$ROOT/stub-term/codex") >/dev/null 2>&1 &
  MP=$!; echo "$MP" >> "$STARTED"; sleep 0.5; MC="$(child_of "$MP")"
  td "$M" STUB_TERMS="$ROOT/terms.json" -- --apply
  if [ "$rc" = 3 ] && has "non-shell processes run in the worktree" && alive "$MP" && alive "$MC"; then ok "plugly (dup): PLUGLY twice, the FIRST (a live terminal) counts: refuses"; else bad "plugly dup first" "$OUT"; fi
  td "$M" STUB_TERMS="$ROOT/terms.json" -- --close-handle term_live_1
  if [ "$rc" = 0 ] && has "stop leftover codex processes"; then ok "plugly (dup): --close-handle of the FIRST value exempts it"; else bad "plugly dup close-handle" "$OUT"; fi
else
  echo "SKIP plugly (dup): no python3"
fi

# a hostile PLUGLY_TERMINAL_HANDLE value (a newline at its start or end, or a forged ORCA_TERMINAL_HANDLE= line inside it) never falls
# back to ORCA and never yields a handle: the process counts as having no terminal, so a leftover codex is planned for the pid stop
# (a live-terminal handle would refuse). Each case runs with a real ORCA_TERMINAL_HANDLE naming the live terminal and without one.
# env(1) cannot hold a newline-bearing name=value reliably across shells, so execve is called through ctypes with the exact entries.
PYEXEC='import ctypes,sys
l=ctypes.CDLL(None); p=sys.argv[1].encode()
a=(ctypes.c_char_p*3)(p,b"app-server",None)
ents=[x.encode() for x in sys.argv[2:]]+[b"PATH=/usr/bin:/bin"]
e=(ctypes.c_char_p*(len(ents)+1))(*ents,None)
l.execve(p,a,e)'
hostile_case() {   # hostile_case <label> <dir-name> <PLUGLY value> [ORCA entry]
  local label="$1" name="$2" val="$3" W HP HC
  local -a ents=("PLUGLY_TERMINAL_HANDLE=$val")
  [ -z "${4:-}" ] || ents+=("$4")
  W="$(mkwt "$name")"
  lists $'cm:running\ncm:child '"$name"
  (cd "$W" && exec python3 -c "$PYEXEC" "$ROOT/stub-term/codex" "${ents[@]}") >/dev/null 2>&1 &
  HP=$!; echo "$HP" >> "$STARTED"; sleep 0.5; HC="$(child_of "$HP")"
  td "$W" STUB_TERMS="$ROOT/terms.json"
  if [ "$rc" = 0 ] && has "stop leftover codex processes" && ! has "non-shell processes run in the worktree"; then ok "$label: no handle, not taken for the live terminal"; else bad "$label" "$OUT"; fi
  if alive "$HP" && alive "$HC"; then ok "$label: and a dry run did not touch it"; else bad "$label: touched"; fi
}
live_case() {   # live_case <label> <dir-name> <env entry>...: the process is taken for the live terminal, so a dry run refuses
  local label="$1" name="$2" W HP HC; shift 2
  W="$(mkwt "$name")"
  lists $'cm:running\ncm:child '"$name"
  (cd "$W" && exec python3 -c "$PYEXEC" "$ROOT/stub-term/codex" "$@") >/dev/null 2>&1 &
  HP=$!; echo "$HP" >> "$STARTED"; sleep 0.5; HC="$(child_of "$HP")"
  td "$W" STUB_TERMS="$ROOT/terms.json"
  if [ "$rc" = 3 ] && has "non-shell processes run in the worktree"; then ok "$label: taken for the live terminal, refuses"; else bad "$label" "$OUT"; fi
  if alive "$HP" && alive "$HC"; then ok "$label: and not touched"; else bad "$label: touched"; fi
}
if command -v python3 >/dev/null 2>&1; then
  hostile_case "plugly hostile (leading newline), real ORCA" cx-n1 $'\nx' ORCA_TERMINAL_HANDLE=term_live_1
  hostile_case "plugly hostile (leading newline), no ORCA" cx-n2 $'\nx'
  hostile_case "plugly hostile (trailing newline), real ORCA" cx-n3 $'term_live_1\n' ORCA_TERMINAL_HANDLE=term_live_1
  hostile_case "plugly hostile (trailing newline), no ORCA" cx-n4 $'term_live_1\n'
  hostile_case "plugly hostile (forged ORCA line inside), real ORCA" cx-n5 $'\nORCA_TERMINAL_HANDLE=term_live_1' ORCA_TERMINAL_HANDLE=term_live_1
  hostile_case "plugly hostile (forged ORCA line inside), no ORCA" cx-n6 $'\nORCA_TERMINAL_HANDLE=term_live_1'
  hostile_case "plugly hostile (leading dash), real ORCA" cx-n7 '-term_live_1' ORCA_TERMINAL_HANDLE=term_live_1
  # a ":" is a legal handle character, so the scan line must not let it move the fields (it is parsed from a TAB separated line)
  hostile_case "plugly value x:term_live_1 (a colon)" cx-n8 'x:term_live_1'
  # the positive paths still work after the rewrite
  live_case "plugly empty, real ORCA after it" cx-p1 PLUGLY_TERMINAL_HANDLE= ORCA_TERMINAL_HANDLE=term_live_1
  live_case "ORCA first, plugly empty after it" cx-p2 ORCA_TERMINAL_HANDLE=term_live_1 PLUGLY_TERMINAL_HANDLE=
  live_case "ORCA before PLUGLY, both term_live_1" cx-p3 ORCA_TERMINAL_HANDLE=term_live_1 PLUGLY_TERMINAL_HANDLE=term_live_1
else
  echo "SKIP plugly hostile: no python3"
fi

echo "== no codex process: nothing to stop"
E="$(mkwt cx-e)"
lists $'cm:running\ncm:child cx-e'
td "$E" -- --apply
if [ "$rc" = 0 ] && has "no leftover codex process in the worktree" && ! has "stopped codex processes"; then ok "clean teardown, no stop line"; else bad "no process case" "$OUT"; fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
