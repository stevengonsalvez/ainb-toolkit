#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2119  # check bodies are single-quoted on purpose: they are eval-ed later
# census-untracked.sh (test): rule 2 of the census-to-zero work. Untracked tool scratch
# (census.ignore_untracked) is not dirt; tracked changes and untracked source files still are.
# Fixture git repos, stubbed orca, synthetic names (lane-a, lane-b ...). Touches only a mktemp dir.
#
#   scripts/test/census-untracked.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/fixtures/census-harness.sh
. "$HERE/fixtures/census-harness.sh"
census_init untracked

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { if (eval "$2"); then ok "$1"; else bad "$1"; fi; }

REPO="$ROOT/local/acme-app"
mkdir -p "$ROOT/local"
census_repo "$REPO"
for b in lane-a lane-b lane-c lane-d lane-e lane-f; do census_worktree "$REPO" "$ROOT/local/$b" "$b"; done
census_hosts
census_ps local "$(census_row acme-app "$REPO" main main)" \
  "$(census_row acme-app "$ROOT/local/lane-a" lane-a)" "$(census_row acme-app "$ROOT/local/lane-b" lane-b)" \
  "$(census_row acme-app "$ROOT/local/lane-c" lane-c)" "$(census_row acme-app "$ROOT/local/lane-d" lane-d)" \
  "$(census_row acme-app "$ROOT/local/lane-e" lane-e)" "$(census_row acme-app "$ROOT/local/lane-f" lane-f)"

# lane-a: only the five noise kinds (plus a nested log) -> clean
A="$ROOT/local/lane-a"
mkdir -p "$A/.beads" "$A/.agents/scratch" "$A/.orca" "$A/.wrangler/tmp" "$A/pkg"
printf 'x\n' > "$A/.beads/issues.jsonl"; printf 'x\n' > "$A/.agents/scratch/n.txt"; printf 'x\n' > "$A/.orca/state"
printf 'x\n' > "$A/.wrangler/tmp/c"; printf 'x\n' > "$A/run.log"; printf 'x\n' > "$A/pkg/deep.log"
# lane-b: noise plus an untracked source file -> dirty 1
B="$ROOT/local/lane-b"; mkdir -p "$B/src"; printf 'x\n' > "$B/run.log"; printf 'code\n' > "$B/src/new.ts"
# lane-c: noise plus a modified TRACKED file -> dirty 1 (tracked is never ignored)
C="$ROOT/local/lane-c"; printf 'x\n' > "$C/run.log"; printf 'two\n' >> "$C/tracked.txt"
# lane-d: a tracked .beads jsonl modified (tracked beats the ignore list) and a .jsonl outside .beads/ untracked
D="$ROOT/local/lane-d"; mkdir -p "$D/.beads" "$D/data"
printf 'a\n' > "$D/.beads/keep.jsonl"; git -C "$D" add .beads/keep.jsonl; git -C "$D" commit -q -m beads
git -C "$D" push -q origin lane-d 2>/dev/null
printf 'b\n' >> "$D/.beads/keep.jsonl"; printf 'x\n' > "$D/data/other.jsonl"
# lane-f: look-alikes of the tool paths deeper in the tree are real files, not noise
F="$ROOT/local/lane-f"; mkdir -p "$F/src/.orca" "$F/.beads/sub" "$F/pkg/.wrangler" "$F/docs/.agents/scratch"
printf 'x\n' > "$F/src/.orca/x.ts"; printf 'x\n' > "$F/.beads/sub/deep.jsonl"; printf 'x\n' > "$F/pkg/.wrangler/c.ts"; printf 'x\n' > "$F/docs/.agents/scratch/n.md"
# lane-e: nothing at all
DOC="$ROOT/doc.json"
census_discover > "$DOC" 2>"$ROOT/err" || { echo "discover.sh failed"; cat "$ROOT/err"; exit 1; }
g() { jq -r --arg n "$1" --arg f "$2" '.worktrees[] | select(.path | endswith("/" + $n)) | .git[$f] | tostring' "$DOC"; }

check "noise only (jsonl, scratch, .orca, .wrangler, nested log) is dirty 0" '[ "$(g lane-a dirty)" = 0 ]'
check "noise only is counted apart: ignoredUntracked 6" '[ "$(g lane-a ignoredUntracked)" = 6 ]'
check "untracked source file next to noise is dirty 1" '[ "$(g lane-b dirty)" = 1 ] && [ "$(g lane-b ignoredUntracked)" = 1 ]'
check "modified tracked file next to noise is dirty 1" '[ "$(g lane-c dirty)" = 1 ]'
check "tracked .beads jsonl change counts; untracked jsonl outside .beads counts" '[ "$(g lane-d dirty)" = 2 ]'
check "look-alikes deeper in the tree are real dirt (src/.orca, .beads/sub, pkg/.wrangler, docs/.agents/scratch)" '[ "$(g lane-f dirty)" = 4 ] && [ "$(g lane-f ignoredUntracked)" = 0 ]'
check "clean worktree is dirty 0, ignored 0" '[ "$(g lane-e dirty)" = 0 ] && [ "$(g lane-e ignoredUntracked)" = 0 ]'

CLS="$ROOT/cls.json"
"$SCRIPTS/classify.sh" < "$DOC" > "$CLS" 2>/dev/null || { echo "classify.sh failed"; exit 1; }
cls() { jq -r --arg n "$1" '.items[] | select(.path | endswith("/" + $n)) | .class' "$CLS"; }
check "classify: noise-only worktree is not dirty-or-unpushed" '[ "$(cls lane-a)" = idle ]'
check "classify: untracked source file is dirty-or-unpushed" '[ "$(cls lane-b)" = dirty-or-unpushed ]'
check "classify: tracked change is dirty-or-unpushed" '[ "$(cls lane-c)" = dirty-or-unpushed ]'

# The ignore list is a config key: a custom list replaces the default; [] ignores nothing.
cfgwith() { # cfgwith <name> <yaml-list>
  cp "$HERE/fixtures/config.test.yaml" "$ROOT/$1.yaml"; printf 'census:\n  ignore_untracked: %s\n' "$2" >> "$ROOT/$1.yaml"
}
cfgwith custom '["*.tmp"]'; cfgwith none '[]'
printf 'x\n' > "$A/x.tmp"
D1="$(CM_CONFIG="$ROOT/custom.yaml" census_discover 2>/dev/null | jq -r '.worktrees[] | select(.path | endswith("/lane-a")) | "\(.git.dirty) \(.git.ignoredUntracked)"')"
check "config key census.ignore_untracked replaces the default (only *.tmp ignored: 6 dirty, 1 ignored)" '[ "$D1" = "6 1" ]'
D2="$(CM_CONFIG="$ROOT/none.yaml" census_discover 2>/dev/null | jq -r '.worktrees[] | select(.path | endswith("/lane-a")) | "\(.git.dirty) \(.git.ignoredUntracked)"')"
check "empty list ignores nothing (all 7 untracked files are dirt)" '[ "$D2" = "7 0" ]'
D3="$(CM_IGNORE_UNTRACKED='*.tmp' census_discover 2>/dev/null | jq -r '.worktrees[] | select(.path | endswith("/lane-a")) | .git.dirty')"
check "env CM_IGNORE_UNTRACKED beats the config" '[ "$D3" = 6 ]'

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
