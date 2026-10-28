#!/usr/bin/env bash
# salv3.sh test: fixture git repos in a mktemp dir, no network. Asserts: the RESULT line for a clean and a
# dirty worktree, what lands in the salvage (untracked files, a tracked diff, the commits ahead of
# origin/main as a bundle, gitignored env files), that credential paths are never copied (defaults and
# CM_SALVAGE_EXCLUDE, including inside an ignored directory git lists whole), mode 700, ABSENT and NO-BASE
# with exit 1, bad usage with exit 2, and the streamed form `bash -s -- <name> < salv3.sh`.
#
#   scripts/test/salv3.sh        # exit 0 when every case passes
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/salv3.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-salv3.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap 'rm -rf -- "${ROOT:?}"' EXIT
if ! tar --version 2>/dev/null | grep -q GNU; then echo "skip: GNU tar needed"; exit 0; fi
export HOME="$ROOT/home" CM_HOME="$ROOT/cm" GIT_CONFIG_GLOBAL="$ROOT/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
mkdir -p "$HOME"
printf '[user]\n\tname = Fixture\n\temail = fixture@example.com\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$3' got '$2'"; fail=1; fi; }

git init -q --bare "$ROOT/origin.git"
git clone -q "$ROOT/origin.git" "$ROOT/seed" 2>/dev/null
( cd "$ROOT/seed" && printf 'one\n' > a.txt && printf 'conf/\n.env.local\n.keys/\nprivate/\n' > .gitignore \
  && git add -A && git commit -q -m init && git push -q origin main )
mkdir -p "$ROOT/wts"
git clone -q "$ROOT/origin.git" "$ROOT/wts/clean"
git clone -q "$ROOT/origin.git" "$ROOT/wts/dirty"
D="$ROOT/wts/dirty"
printf 'two\n' >> "$D/a.txt"
printf 'new\n' > "$D/new.txt"
( cd "$D" && printf 'x\n' > b.txt && git add b.txt && git commit -q -m local-commit )
printf 'KEY=1\n' > "$D/.env.local"
mkdir -p "$D/conf" "$D/.keys" "$D/private"
printf 'ok\n' > "$D/conf/app.conf"; printf 'pw\n' > "$D/conf/password"
printf 'k\n' > "$D/.keys/ed25519"; printf 'p\n' > "$D/private/note"

OUT="$(CM_WORKTREE_BASE="$ROOT/wts" "$SCRIPT" clean)"; RC=$?
check "clean worktree: exit 0" "$RC" "0"
check "clean worktree: RESULT line" "$(printf '%s\n' "$OUT" | sed 's/ salvage=.*//')" "RESULT clean branch=main dirty=0 ahead_main=0 unpushed_vs_remote=0"

OUT="$(CM_WORKTREE_BASE="$ROOT/wts" CM_SALVAGE_EXCLUDE="private" "$SCRIPT" dirty)"; RC=$?
check "dirty worktree: exit 0" "$RC" "0"
check "dirty worktree: RESULT counts" "$(printf '%s\n' "$OUT" | sed 's/ salvage=.*//')" \
  "RESULT dirty branch=main dirty=2 ahead_main=1 unpushed_vs_remote=1"
S="${OUT##*salvage=}"
check "salvage under CM_HOME/salvage" "$(case "$S" in "$CM_HOME"/salvage/*) echo yes ;; *) echo no ;; esac)" "yes"
check "salvage directory is mode 700" "$(stat -c %a "$S" 2>/dev/null || stat -f %Lp "$S")" "700"
check "untracked file archived" "$(tar -tzf "$S/untracked.tgz" | grep -c '^new.txt$')" "1"
check "tracked change in dirty.diff" "$(grep -c '^+two$' "$S/dirty.diff")" "1"
check "commits ahead kept as a bundle" "$(git -C "$D" bundle verify "$S/branch.bundle" >/dev/null 2>&1 && echo ok)" "ok"
check "gitignored env file kept" "$(tar -tzf "$S/ignored.tgz" | grep -c '\.env\.local$')" "1"
check "ignored directory content kept" "$(tar -tzf "$S/ignored.tgz" | grep -c 'conf/app.conf$')" "1"
check "password file inside an ignored directory: not copied" "$(tar -tzf "$S/ignored.tgz" | grep -c 'password$')" "0"
check "signing keys directory: not copied" "$(tar -tzf "$S/ignored.tgz" | grep -c '\.keys')" "0"
check "CM_SALVAGE_EXCLUDE path: not copied" "$(tar -tzf "$S/ignored.tgz" | grep -c 'private')" "0"

OUT="$(CM_WORKTREE_BASE="$ROOT/wts" "$SCRIPT" dirty)"
S2="${OUT##*salvage=}"
check "without CM_SALVAGE_EXCLUDE the extra path is copied" "$(tar -tzf "$S2/ignored.tgz" | grep -c 'private/note$')" "1"

OUT="$(CM_WORKTREE_BASE="$ROOT/wts" "$SCRIPT" nope clean 2>&1)"; RC=$?
check "absent worktree: ABSENT line, exit 1" "$(printf '%s\n' "$OUT" | grep -c '^RESULT nope ABSENT')" "1"
check "absent worktree: the others still run" "$(printf '%s\n' "$OUT" | grep -c '^RESULT clean branch=')" "1"
check "absent worktree: exit 1" "$RC" "1"
check "absolute path accepted" "$("$SCRIPT" "$ROOT/wts/clean" | grep -c "^RESULT $ROOT/wts/clean branch=")" "1"
check "no arguments: exit 2" "$("$SCRIPT" >/dev/null 2>&1; echo $?)" "2"

mkdir -p "$ROOT/elsewhere"; cp "$SCRIPT" "$ROOT/elsewhere/salv3.sh"
OUT="$(cd "$ROOT/elsewhere" && bash ./salv3.sh clean 2>&1)"; RC=$?
check "bare name with no base: NO-BASE, exit 1" "$(printf '%s\n' "$OUT" | grep -c '^RESULT clean NO-BASE')" "1"
check "NO-BASE exits 1" "$RC" "1"
OUT="$(cd "$ROOT/elsewhere" && CM_WORKTREE_BASE="$ROOT/wts" bash -s -- clean < "$SCRIPT" 2>&1)"; RC=$?
check "streamed over stdin: RESULT line, exit 0" "$(printf '%s\n' "$OUT" | grep -c '^RESULT clean branch=main dirty=0')" "1"
check "streamed over stdin: exit 0" "$RC" "0"
[ "$fail" = 0 ]
