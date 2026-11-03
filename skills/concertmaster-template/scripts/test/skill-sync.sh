#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# shellcheck disable=SC2015  # pass() always succeeds, so A && pass || fail is if-then-else here
# skill-sync.sh (test): how a merged skill change reaches the live concertmaster worktree, hermetic. A bare
# "origin" and a clone ("the concertmaster worktree") in a temp dir, synthetic files, no network, no signing.
# Covers: clean and behind with the skill directory changed (pulled, journal line, re-read order); behind but only
# other paths changed (no-op); dirty tracked file (blocked, file kept, HEAD unchanged); diverged with the skill
# directory changed upstream (blocked, no merge commit, no rebase); diverged but the directory unchanged (no-op);
# an untracked file in the way of the fast-forward (blocked, nothing changed); up to date; ahead only; fetch fails
# (blocked); --dry-run pulls nothing; never forced (no stash, no reset: HEAD only moves on a clean fast-forward);
# a second run after the pull is a no-op; the repo and path read from config or the environment, a flag wins.
#
#   scripts/test/skill-sync.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/.."
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-skillsync.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then echo "temp dir missing" >&2; exit 1; fi
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0
export CM_HOME="$ROOT/home"; mkdir -p "$CM_HOME"
cat > "$ROOT/config.yaml" <<'CFG'
schema: concertmaster.config/v1
worktrees: { self_name: concertmaster }
CFG
export CM_CONFIG="$ROOT/config.yaml"
unset CM_ORG CM_REPO CM_PATH_MATCH CM_ORCA_REPO CM_NEVER_TOUCH
SK=".agents/skills/concertmaster"
X="$S/skill-sync.sh"

gi() { git -c commit.gpgsign=false -C "$1" "${@:2}"; }
commit() { # <dir> <file> <content> <msg>
  mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "$3" > "$1/$2"; gi "$1" add "$2"; gi "$1" commit -q -m "$4"
}
mkrepo() { # <name>: origin bare + upstream work clone + the concertmaster clone
  local n="$1"
  git init -q --bare -b main "$ROOT/$n.git"
  git init -q -b main "$ROOT/$n-up"
  commit "$ROOT/$n-up" "$SK/SKILL.md" "v1" "seed"
  commit "$ROOT/$n-up" "src/app.txt" "app1" "seed app"
  gi "$ROOT/$n-up" remote add origin "$ROOT/$n.git"; gi "$ROOT/$n-up" push -q origin main
  git clone -q "$ROOT/$n.git" "$ROOT/$n-cm"
}
head_of() { git -C "$1" rev-parse HEAD; }
run() { "$X" --repo "$1" --path "$SK" "${@:2}" 2>&1; }

# ---- 1. clean and behind, skill dir changed: pulled ----
mkrepo a
commit "$ROOT/a-up" "$SK/SKILL.md" "v2" "skill change"; gi "$ROOT/a-up" push -q origin main
OLD="$(head_of "$ROOT/a-cm")"; NEW="$(head_of "$ROOT/a-up")"
OUT="$(run "$ROOT/a-cm")"; RC=$?
[ "$RC" = 0 ] && [ "$(head_of "$ROOT/a-cm")" = "$NEW" ] && [ "$(cat "$ROOT/a-cm/$SK/SKILL.md")" = v2 ] && pass "clean and behind, skill dir changed: fast-forwarded, the new SKILL.md is on disk" || fail "pull" "rc=$RC $OUT"
grep -q "skill-sync: pulled ${OLD:0:12}..${NEW:0:12} (1 file(s) under $SK)" <<<"$OUT" && grep -q "re-read $SK/SKILL.md now" <<<"$OUT" && pass "it names the move and orders a re-read of SKILL.md" || fail "pull text" "$OUT"
JL="$("$S/lane-journal.sh" tail concertmaster 5)"
grep -q "skill-sync: pulled ${OLD:0:12}..${NEW:0:12}" <<<"$JL" && pass "one journal line in the concertmaster lane" || fail "journal" "$JL"
OUT="$(run "$ROOT/a-cm")"; RC=$?
[ "$RC" = 0 ] && grep -q 'up to date' <<<"$OUT" && [ "$(wc -l < "$CM_HOME/lanes/concertmaster/journal.md" | tr -d ' ')" = 1 ] && pass "a second run is a no-op (up to date, no second journal line)" || fail "second" "rc=$RC $OUT"

# ---- 2. behind, but only other paths changed ----
mkrepo b
commit "$ROOT/b-up" "src/app.txt" "app2" "app change"; gi "$ROOT/b-up" push -q origin main
OLD="$(head_of "$ROOT/b-cm")"
OUT="$(run "$ROOT/b-cm")"; RC=$?
[ "$RC" = 0 ] && [ "$(head_of "$ROOT/b-cm")" = "$OLD" ] && grep -q "unchanged on origin/main" <<<"$OUT" && pass "behind but the skill dir is unchanged upstream: no-op, HEAD stays" || fail "unchanged" "rc=$RC $OUT"

# ---- 3. dirty tracked file ----
mkrepo c
commit "$ROOT/c-up" "$SK/SKILL.md" "v2" "skill change"; gi "$ROOT/c-up" push -q origin main
printf 'local edit\n' > "$ROOT/c-cm/src/app.txt"
OLD="$(head_of "$ROOT/c-cm")"
OUT="$(run "$ROOT/c-cm")"; RC=$?
[ "$RC" = 1 ] && [ "$(head_of "$ROOT/c-cm")" = "$OLD" ] && [ "$(cat "$ROOT/c-cm/src/app.txt")" = "local edit" ] && grep -q '^BLOCKED: cm:blocked skill-sync worktree has 1 uncommitted' <<<"$OUT" \
  && pass "dirty tracked file: BLOCKED with the cm:blocked line, exit 1, file and HEAD untouched" || fail "dirty" "rc=$RC $OUT"
[ -z "$(git -C "$ROOT/c-cm" stash list)" ] && pass "never stashes" || fail "stash" "$(git -C "$ROOT/c-cm" stash list)"

# ---- 4. diverged, skill dir changed upstream ----
mkrepo d
commit "$ROOT/d-cm" "notes.txt" "local only" "local commit"
commit "$ROOT/d-up" "$SK/SKILL.md" "v2" "skill change"; gi "$ROOT/d-up" push -q origin main
OLD="$(head_of "$ROOT/d-cm")"
OUT="$(run "$ROOT/d-cm")"; RC=$?
[ "$RC" = 1 ] && [ "$(head_of "$ROOT/d-cm")" = "$OLD" ] && grep -q 'BLOCKED: cm:blocked skill-sync diverged from origin/main (ahead 1, behind 1)' <<<"$OUT" \
  && pass "diverged with the skill dir changed upstream: BLOCKED (ahead 1, behind 1), HEAD unchanged" || fail "diverged" "rc=$RC $OUT"
[ "$(git -C "$ROOT/d-cm" rev-list --merges --count HEAD)" = 0 ] && [ ! -d "$ROOT/d-cm/.git/rebase-merge" ] && pass "no merge commit and no rebase was started" || fail "no merge" "merge or rebase present"

# ---- 5. diverged but the skill dir unchanged upstream ----
mkrepo e
commit "$ROOT/e-cm" "notes.txt" "local only" "local commit"
commit "$ROOT/e-up" "src/app.txt" "app2" "app change"; gi "$ROOT/e-up" push -q origin main
OUT="$(run "$ROOT/e-cm")"; RC=$?
[ "$RC" = 0 ] && grep -q 'diverged (ahead 1, behind 1) but .* is unchanged' <<<"$OUT" && pass "diverged but the skill dir is not what moved: no-op, no alarm" || fail "diverged unchanged" "rc=$RC $OUT"

# ---- 6. untracked file in the way ----
mkrepo f
commit "$ROOT/f-up" "$SK/new-ref.md" "from upstream" "new reference"; gi "$ROOT/f-up" push -q origin main
mkdir -p "$ROOT/f-cm/$SK"; printf 'mine\n' > "$ROOT/f-cm/$SK/new-ref.md"
OLD="$(head_of "$ROOT/f-cm")"
OUT="$(run "$ROOT/f-cm")"; RC=$?
[ "$RC" = 1 ] && [ "$(head_of "$ROOT/f-cm")" = "$OLD" ] && [ "$(cat "$ROOT/f-cm/$SK/new-ref.md")" = mine ] && grep -q 'fast-forward to .* refused' <<<"$OUT" \
  && pass "an untracked file in the way: the fast-forward is refused, BLOCKED, the file is kept" || fail "untracked" "rc=$RC $OUT"

# ---- 7. up to date, and ahead only ----
mkrepo g
OUT="$(run "$ROOT/g-cm")"; RC=$?
[ "$RC" = 0 ] && grep -q 'up to date' <<<"$OUT" && pass "up to date: no-op" || fail "up to date" "rc=$RC $OUT"
commit "$ROOT/g-cm" "notes.txt" "local only" "local commit"
OUT="$(run "$ROOT/g-cm")"; RC=$?
[ "$RC" = 0 ] && grep -q 'ahead of origin/main, nothing to pull' <<<"$OUT" && pass "ahead only: no-op" || fail "ahead" "rc=$RC $OUT"

# ---- 8. fetch fails ----
mkrepo h
git -C "$ROOT/h-cm" remote set-url origin "$ROOT/does-not-exist.git"
OUT="$(run "$ROOT/h-cm")"; RC=$?
[ "$RC" = 1 ] && grep -q '^BLOCKED: cm:blocked skill-sync cannot fetch origin/main' <<<"$OUT" && pass "fetch fails: BLOCKED with the reason, nothing touched" || fail "fetch" "rc=$RC $OUT"

# ---- 9. --dry-run ----
mkrepo i
commit "$ROOT/i-up" "$SK/SKILL.md" "v2" "skill change"; gi "$ROOT/i-up" push -q origin main
OLD="$(head_of "$ROOT/i-cm")"
OUT="$(run "$ROOT/i-cm" --dry-run)"; RC=$?
[ "$RC" = 0 ] && [ "$(head_of "$ROOT/i-cm")" = "$OLD" ] && grep -q 'would fast-forward' <<<"$OUT" && pass "--dry-run says what it would do and pulls nothing" || fail "dry" "rc=$RC $OUT"

# ---- 10. bad arguments, defaults ----
"$X" --repo "$ROOT/does-not-exist" >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && pass "a missing --repo directory is a usage error" || fail "usage repo" "rc=$RC"
"$X" --path /etc >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && pass "an absolute --path is refused" || fail "usage path" "rc=$RC"
"$X" --repo "$ROOT/a-cm" --remote --upload-pack --branch touch >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && pass "a remote name starting with '-' is refused (no git option smuggling)" || fail "dash remote" "rc=$RC"
"$X" --repo "$ROOT/a-cm" --remote nosuchremote >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && pass "a remote that does not exist is a usage error" || fail "no remote" "rc=$RC"
"$X" --bogus >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && pass "an unknown argument is a usage error" || fail "usage arg" "rc=$RC"

# ---- 11. run through the .claude/skills symlink: the skill path is the PHYSICAL one ----
mkrepo s
mkdir -p "$ROOT/s-up/$SK/scripts" "$ROOT/s-up/.claude"
cp "$S"/*.sh "$S"/*.jq "$ROOT/s-up/$SK/scripts/"
ln -s ../.agents/skills "$ROOT/s-up/.claude/skills"
gi "$ROOT/s-up" add "$SK/scripts" .claude/skills; gi "$ROOT/s-up" commit -q -m "scripts and symlink"; gi "$ROOT/s-up" push -q origin main
gi "$ROOT/s-cm" pull -q --ff-only origin main
commit "$ROOT/s-up" "$SK/SKILL.md" "v2" "skill change"; gi "$ROOT/s-up" push -q origin main
NEW="$(head_of "$ROOT/s-up")"
OUT="$("$ROOT/s-cm/.claude/skills/concertmaster/scripts/skill-sync.sh" 2>&1)"; RC=$?
[ "$RC" = 0 ] && [ "$(head_of "$ROOT/s-cm")" = "$NEW" ] && pass "run through the .claude/skills symlink with no --path: the change under the real directory is seen and pulled" || fail "symlink" "rc=$RC $OUT"

# ---- 12. the source repo and skill directory come from config (skill_sync:), flags win over config ----
mkrepo k
commit "$ROOT/k-up" "$SK/SKILL.md" "v2" "skill change"; gi "$ROOT/k-up" push -q origin main
NEW="$(head_of "$ROOT/k-up")"
cat > "$ROOT/config-sync.yaml" <<CFG
schema: concertmaster.config/v1
worktrees: { self_name: concertmaster }
skill_sync: { repo: "$ROOT/k-cm", path: "$SK", remote: origin, branch: main }
CFG
OUT="$(CM_CONFIG="$ROOT/config-sync.yaml" "$X" 2>&1)"; RC=$?
[ "$RC" = 0 ] && [ "$(head_of "$ROOT/k-cm")" = "$NEW" ] && pass "repo and path from config alone (no flags): pulled" || fail "config keys" "rc=$RC $OUT"
mkrepo m
commit "$ROOT/m-up" "$SK/SKILL.md" "v2" "skill change"; gi "$ROOT/m-up" push -q origin main
OLD="$(head_of "$ROOT/m-cm")"
OUT="$(CM_CONFIG="$ROOT/config-sync.yaml" "$X" --repo "$ROOT/m-cm" --dry-run 2>&1)"; RC=$?
[ "$RC" = 0 ] && [ "$(head_of "$ROOT/m-cm")" = "$OLD" ] && grep -q 'would fast-forward' <<<"$OUT" && pass "a --repo flag wins over the configured repo" || fail "flag over config" "rc=$RC $OUT"
OUT="$(CM_SKILL_SYNC_REPO="$ROOT/m-cm" CM_SKILL_SYNC_PATH="$SK" CM_CONFIG="$ROOT/config.yaml" "$X" --dry-run 2>&1)"; RC=$?
[ "$RC" = 0 ] && grep -q 'would fast-forward' <<<"$OUT" && pass "the environment (CM_SKILL_SYNC_REPO, CM_SKILL_SYNC_PATH) is read when no flag is given" || fail "env keys" "rc=$RC $OUT"

printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
