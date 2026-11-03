#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# shellcheck disable=SC2015  # "A && ok || bad": ok never fails
# salv3-followups.sh: behaviour tests for the follow-up part of scripts/salv3.sh (remote salvage before a worktree
# is removed): the open follow-ups of the worktree's ledger worker and its children are written into the
# salvage and printed, so nothing that outlives the worker is lost. Runs on scratch git repos and a temp
# CM_HOME; no network (the repos have no origin), never touches a live ledger or worktree.
#
#   scripts/test/salv3-followups.sh   # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export CM_CONFIG="$HERE/fixtures/config.test.yaml"
unset CM_ORG CM_REPO CM_PROJECT CM_OWNER_NAME CM_OWNER_ID CM_TZ CM_TZ_LABEL CM_EXCLUDE_REPOS CM_PATH_MATCH CM_SELF_WORKTREE CM_LEDGER
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }
tar --version 2>/dev/null | grep -q GNU || { echo "SKIP: salv3.sh needs GNU tar"; exit 0; }
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-salv3.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
export CM_HOME="$ROOT/cmhome" HOME="$ROOT/home"
mkdir -p "$CM_HOME" "$HOME" "$ROOT/skill/scripts" "$ROOT/wt"
cp "$HERE/../salv3.sh" "$HERE/../followups.sh" "$HERE/../lib.sh" "$ROOT/skill/scripts/"
SALV="$ROOT/skill/scripts/salv3.sh"
export CM_WORKTREE_BASE="$ROOT/wt"
L="$CM_HOME/ledger.json"
git config --global user.email t@example.invalid; git config --global user.name t; git config --global init.defaultBranch main
mkwt() { mkdir -p "$ROOT/wt/$1" && git -C "$ROOT/wt/$1" init -q && echo x > "$ROOT/wt/$1/f" && git -C "$ROOT/wt/$1" add f && git -C "$ROOT/wt/$1" commit -q -m init; }
mkwt ops-a; mkwt ops-b; mkwt ops-lonely; mkwt ops-kid

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n%s\n' "$1" "${2:-}"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want [$3] in: $2" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "unexpected [$3] in: $2" ;; *) ok "$1" ;; esac; }

# 1. no helper ledger yet: followups=unavailable, the salvage still succeeds
rm -f "$L"
out="$("$SALV" ops-a 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "no ledger: salvage succeeds" || bad "no ledger rc" "rc=$rc $out"
has "no ledger: followups=unavailable" "$out" "followups=unavailable"

# 2. ledger with an open follow-up on the worktree's worker, one on its child, one closed, one elsewhere
jq -n --arg a "$ROOT/wt/ops-a" --arg b "$ROOT/wt/ops-b" --arg k "$ROOT/wt/ops-kid" '{
  workers: {
    "w-a": {host: "local", path: $a, lane: "lane-a", state: "running"},
    "w-b": {host: "local", path: $b, lane: "lane-a", state: "running"},
    "w-kid": {host: "local", path: $k, lane: "lane-a", state: "running", parent: "w-a"}},
  followUps: [
    {id: "validate-codes", worker: "w-a", lane: "lane-a", owner: "lane-a", text: "validate the codes after load", state: "open", openedAt: "2026-10-27T10:00:00Z"},
    {id: "kid-item", worker: "w-kid", lane: "lane-a", owner: "owner", text: "owner decision on the kid", state: "open", openedAt: "2026-10-27T11:00:00Z"},
    {id: "old-item", worker: "w-a", lane: "lane-a", owner: "w-a", text: "already closed", state: "done", openedAt: "2026-10-26T10:00:00Z", closedAt: "2026-10-26T12:00:00Z"},
    {id: "b-item", worker: "w-b", lane: "lane-a", owner: "w-b", text: "belongs to b", state: "open", openedAt: "2026-10-27T12:00:00Z"}]}' > "$L"
out="$("$SALV" ops-a 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "followups: salvage succeeds" || bad "followups rc" "rc=$rc $out"
has "followups: RESULT counts the worker's and its child's open items" "$out" "followups=2"
has "followups: the worker's item is printed" "$out" "FOLLOWUP ops-a validate-codes owner=lane-a validate the codes after load"
has "followups: the child's item is printed" "$out" "FOLLOWUP ops-a kid-item owner=owner owner decision on the kid"
lacks "followups: a closed item is not listed" "$out" "old-item"
lacks "followups: another worker's item is not listed" "$out" "b-item"
SALVDIR="$(printf '%s\n' "$out" | sed -n 's/.* salvage=//p' | tail -n 1)"
[ -s "$SALVDIR/followups.tsv" ] && ok "followups: followups.tsv is in the salvage dir" || bad "followups.tsv" "missing in $SALVDIR"
[ "$(wc -l < "$SALVDIR/followups.tsv" | tr -d ' ')" = 2 ] && ok "followups.tsv holds the two open rows" || bad "followups.tsv rows" "$(cat "$SALVDIR/followups.tsv")"
[ "$(stat -c %a "$SALVDIR/followups.tsv" 2>/dev/null || stat -f %Lp "$SALVDIR/followups.tsv")" = 600 ] && ok "followups.tsv is mode 600" || bad "followups.tsv mode" "not 600"

# 3. a worker with nothing open, a worktree no ledger worker owns, an absolute path
out="$("$SALV" ops-b 2>&1)"
has "an owned worktree with an item: counted" "$out" "followups=1"
jq 'del(.followUps[] | select(.worker == "w-b"))' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
out="$("$SALV" ops-b 2>&1)"
has "no open item: followups=none" "$out" "followups=none"
NONEDIR="$(printf '%s\n' "$out" | sed -n 's/.* salvage=//p' | tail -n 1)"
[ ! -e "$NONEDIR/followups.tsv" ] && ok "none: no followups.tsv written" || bad "none tsv" "written in $NONEDIR"
out="$("$SALV" ops-lonely 2>&1)"
has "a worktree with no ledger worker: followups=untracked" "$out" "followups=untracked"
out="$("$SALV" "$ROOT/wt/ops-a" 2>&1)"
has "an absolute path finds the same worker" "$out" "followups=2"

# 4. an unusable ledger never turns into a confident none
printf 'not json' > "$L"
out="$("$SALV" ops-a 2>&1)"; rc=$?
has "garbage ledger: followups=unavailable" "$out" "followups=unavailable"
[ "$rc" = 0 ] && ok "garbage ledger: the salvage itself still succeeds" || bad "garbage rc" "rc=$rc"
jq -n '{followUps: "oops", workers: {}}' > "$L"
has "followUps not an array: followups=unavailable" "$("$SALV" ops-a 2>&1)" "followups=unavailable"

# 5. the existing RESULT fields and a missing worktree are unchanged
has "RESULT keeps its fields" "$("$SALV" ops-a 2>&1)" "dirty=0 ahead_main="
out="$("$SALV" nope 2>&1)"; rc=$?
has "absent worktree: ABSENT" "$out" "RESULT nope ABSENT"
[ "$rc" = 1 ] && ok "absent worktree: exit 1" || bad "absent rc" "rc=$rc"
out="$("$SALV" 2>&1)"; rc=$?
[ "$rc" = 2 ] && ok "no argument: usage, exit 2" || bad "usage rc" "rc=$rc"

# 6. streamed over `bash -s` (as the remote salvage does): a followups.sh in the remote cwd is never run
mkdir -p "$ROOT/remote-cwd"
printf '#!/usr/bin/env bash\ntouch "%s/ROGUE-RAN"\n' "$ROOT" > "$ROOT/remote-cwd/followups.sh"; : > "$ROOT/remote-cwd/lib.sh"
out="$(cd "$ROOT/remote-cwd" && bash -s -- ops-a < "$SALV" 2>&1)"
has "bash -s: followups=unavailable" "$out" "followups=unavailable"
[ ! -e "$ROOT/ROGUE-RAN" ] && ok "bash -s: a followups.sh in the remote cwd is not run" || bad "rogue followups.sh ran" ""

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
