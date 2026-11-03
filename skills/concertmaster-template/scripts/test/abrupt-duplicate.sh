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
# A fake pgrep and sleep on PATH, a fake /proc root, a stub Orca with no sessions, synthetic paths under
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
chmod +x "$BIN/orca" "$BIN/pgrep" "$BIN/sleep"

N=0
fresh() { N=$((N + 1)); FX="$ROOT/case$N"; mkdir -p "$FX/proc" "$FX/wt/acme/one" "$FX/wt/acme/two" "$FX/wt/other/out"; }
# mkproc <pid> <cwd> <argv...>: one fake pid dir (cmdline NUL separated)
mkproc() { local pid="$1" cwd="$2"; shift 2; mkdir -p "$FX/proc/$pid"; ln -sfn "$cwd" "$FX/proc/$pid/cwd"; printf '%s\0' "$@" > "$FX/proc/$pid/cmdline"; }
# samples <list1> [list2]: what the first and the second pgrep call print
# shellcheck disable=SC2086  # the pid lists are split on purpose
samples() { printf '%s\n' $1 > "$FX/pgrep.1"; [ $# -ge 2 ] && printf '%s\n' $2 > "$FX/pgrep.2"; return 0; }
# run [VAR=value ...]: abrupt.sh against the fake root, stdout only
run() {
  env PATH="$BIN:$PATH" PGFX="$FX" CM_TEST=1 CM_PROC_ROOT="$FX/proc" CM_PATH_MATCH=/acme/ \
    CM_CONFIG="$HERE/fixtures/config.test.yaml" ORCA_CLI_COMMAND="$BIN/orca" "$@" bash "$ABRUPT" 2>"$FX/stderr"
}
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
