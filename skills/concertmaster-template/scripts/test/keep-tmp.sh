#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# Every test script that cleans its temp dir in an EXIT trap says so (header line "# cm-test: rm-cleanup") and skips that
# rm -rf when CM_TEST_KEEP_TMP=1, so a reviewer can run it without executing an rm the permission layer cannot check
# (references/prompt-stalls.md, sixth wave). Static check of every script, plus two run both ways. Nothing outside mktemp dirs.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-keeptmp.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n%s\n' "$1" "${2:-}"; }

# 1. every script with a trap that runs rm (indented or not, any flag order) carries the marker in its first three lines and keeps
# its dir only when CM_TEST_KEEP_TMP is exactly 1 (a 0 or an empty value is off), on that same line
n=0; missing=""; noswitch=""; stray=""
for f in "$HERE"/*.sh; do
  b="$(basename "$f")"
  traps="$(grep -E '^[[:space:]]*trap .*\brm\b' "$f" || true)"
  marked=0; head -n 3 "$f" | grep -q '^# cm-test: rm-cleanup' && marked=1
  if [ -n "$traps" ]; then
    n=$((n + 1))
    [ "$marked" = 1 ] || missing="$missing $b"
    # every such trap line, not just one of them
    while IFS= read -r l; do case "$l" in *'"${CM_TEST_KEEP_TMP:-}" = 1'*) ;; *) noswitch="$noswitch $b" ;; esac; done <<<"$traps"
  elif [ "$marked" = 1 ]; then stray="$stray $b"; fi
done
[ "$n" -ge 40 ] && ok "found $n scripts with an rm -rf EXIT trap" || bad "script count" "only $n"
[ -z "$missing" ] && ok "each carries the marker line" || bad "marker missing" "$missing"
[ -z "$noswitch" ] && ok "each trap line keeps its dir only for CM_TEST_KEEP_TMP=1" || bad "switch missing" "$noswitch"
[ -z "$stray" ] && ok "no script carries the marker without such a trap" || bad "stray marker" "$stray"

# 2. run a script against a private TMPDIR. The keep case always runs. The cases that let a child clean up (the default and the
# empty value) execute an rm -rf of the child's own temp dir, so they are skipped when this test itself runs under
# CM_TEST_KEEP_TMP=1, the invocation a reviewer uses to run no rm at all.
S="$HERE/config-check.sh"
mkdir -p "$ROOT/keep" "$ROOT/gone" "$ROOT/empty"
out="$(env -u ORCA_CLI_COMMAND TMPDIR="$ROOT/keep" CM_TEST_KEEP_TMP=1 bash "$S" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "config-check.sh with CM_TEST_KEEP_TMP=1 still passes" || bad "keep rc" "rc=$rc"
left="$(find "$ROOT/keep" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
[ "$left" = 1 ] && ok "and leaves its temp dir" || bad "keep dir" "left=$left"
case "$out" in *"CM_TEST_KEEP_TMP set, kept "*) ok "and says which dir it kept" ;; *) bad "keep message" "$out" ;; esac
if [ "${CM_TEST_KEEP_TMP:-}" = 1 ]; then
  printf 'SKIP the default and empty-value cleanup cases (this run keeps its temp dirs: CM_TEST_KEEP_TMP is set)\n'
else
  env -u ORCA_CLI_COMMAND -u CM_TEST_KEEP_TMP TMPDIR="$ROOT/gone" bash "$S" >/dev/null 2>&1; rc=$?
  left="$(find "$ROOT/gone" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
  [ "$rc" = 0 ] && [ "$left" = 0 ] && ok "without the switch the temp dir is removed as before" || bad "default cleanup" "rc=$rc left=$left"
  env -u ORCA_CLI_COMMAND TMPDIR="$ROOT/empty" CM_TEST_KEEP_TMP= bash "$S" >/dev/null 2>&1
  left="$(find "$ROOT/empty" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
  [ "$left" = 0 ] && ok "an empty CM_TEST_KEEP_TMP is off" || bad "empty value" "left=$left"
  mkdir -p "$ROOT/zero"
  env -u ORCA_CLI_COMMAND TMPDIR="$ROOT/zero" CM_TEST_KEEP_TMP=0 bash "$S" >/dev/null 2>&1
  left="$(find "$ROOT/zero" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
  [ "$left" = 0 ] && ok "CM_TEST_KEEP_TMP=0 is off" || bad "zero value" "left=$left"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
