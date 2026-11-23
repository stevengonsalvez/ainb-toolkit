#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
# shellcheck disable=SC2015,SC2016,SC2034  # pass() always succeeds; check bodies are single-quoted on purpose
# cm-worktree-sync.sh (test): the concertmaster worktree is held level with origin/main, hermetic. A bare local
# "origin", an upstream work clone and the "concertmaster worktree" clone in a temp dir; synthetic files, no network, no signing.
# Covers: equal (silent, exit 0, nothing touched); behind on other paths only (silent); behind and clean (fast-forwarded, one
# status line); behind and dirty (BLOCKED reason=dirty with the commits-behind count, HEAD and the file kept);
# an untracked tool-scratch file does not count as dirty; diverged (BLOCKED, no merge commit); a fetch that fails (BLOCKED
# reason=fetch); the index.lock cases: stale empty old and unheld (removed, reported on the line, fast-forwarded), young empty
# (kept, BLOCKED), old empty but held by a live process (kept, the holder named, also with only the /proc scan), old but not
# empty (kept), a holder nobody can read (no fuser, no lsof, no /proc: holder=unknown, kept), a lock with the worktree level
# (silent, lock untouched), --dry-run (changes nothing); usage exits 2. Mutants on a scratch copy: the dirty check, the held
# check, the age check, the empty check and the unknown-holder guard each removed must fail a case.
#
#   scripts/test/cm-worktree-sync.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/.."
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-wtsync-test.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then echo "temp dir missing" >&2; exit 1; fi
HOLDERS=""
trap 'for p in $HOLDERS; do kill "$p" 2>/dev/null; done; [ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s: %s\n' "$1" "${2:-}"; }
check() { if (eval "$2"); then pass "$1"; else fail "$1" "${3:-}"; fi; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=tester GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=tester
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0
export CM_HOME="$ROOT/home"; mkdir -p "$CM_HOME"
cat > "$ROOT/config.yaml" <<'CFG'
schema: concertmaster.config/v1
worktrees: { self_name: concertmaster }
skill_sync: { path: .agents/skills/concertmaster }
CFG
export CM_CONFIG="$ROOT/config.yaml"
unset CM_ORG CM_REPO CM_PATH_MATCH CM_ORCA_REPO CM_NEVER_TOUCH CM_SELF_PATH CM_IGNORE_UNTRACKED CM_PROC_ROOT
SK=".agents/skills/concertmaster"
X="$S/cm-worktree-sync.sh"

gi() { git -c commit.gpgsign=false -C "$1" "${@:2}"; }
commit() { mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "$3" > "$1/$2"; gi "$1" add "$2"; gi "$1" commit -q -m "$4"; }
mkrepo() { # <name>: origin bare + upstream clone + the concertmaster clone
  local n="$1"
  git init -q --bare -b main "$ROOT/$n.git"
  git init -q -b main "$ROOT/$n-up"
  commit "$ROOT/$n-up" "$SK/SKILL.md" "v1" "seed"
  commit "$ROOT/$n-up" "src/app.txt" "app1" "seed app"
  gi "$ROOT/$n-up" remote add origin "$ROOT/$n.git"; gi "$ROOT/$n-up" push -q origin main
  git clone -q "$ROOT/$n.git" "$ROOT/$n-cm"
}
upstream() { commit "$ROOT/$1-up" "$SK/SKILL.md" "$2" "skill $2"; gi "$ROOT/$1-up" push -q origin main; }   # origin moves the skill dir
head_of() { git -C "$1" rev-parse HEAD; }
age_lock() { touch -d "@$(( $(date +%s) - ${2:-7200} ))" "$1/.git/index.lock"; }   # make the lock <secs> old
run() { # <name> [args]: RC, OUT
  local n="$1"; shift
  OUT="$("$X" --repo "$ROOT/$n-cm" --path "$SK" "$@" 2>&1)"; RC=$?
}
hold() { # <lockfile>: a live process holds the file open; sets HP
  bash -c 'exec 9>>"$1"; exec sleep 120' _ "$1" & HP=$!; HOLDERS="$HOLDERS $HP"; sleep 1
}
release() { kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null; HOLDERS="${HOLDERS/ $HP/}"; }

# ---- 1. equal: silent ----
mkrepo a
OLD="$(head_of "$ROOT/a-cm")"
run a
check "equal: no output, exit 0, HEAD unchanged" '[ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$(head_of "$ROOT/a-cm")" = "$OLD" ]' "rc=$RC out=$OUT"
commit "$ROOT/a-up" "src/app.txt" "app2" "app change"; gi "$ROOT/a-up" push -q origin main
run a
check "behind on other paths only (skill dir unchanged upstream): silent, nothing pulled" '[ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$(head_of "$ROOT/a-cm")" = "$OLD" ]' "rc=$RC out=$OUT"

# ---- 2. behind and clean: fast-forwarded ----
upstream a v2
NEW="$(head_of "$ROOT/a-up")"
run a
check "behind and clean: fast-forwarded to origin/main, exit 0" '[ "$RC" = 0 ] && [ "$(head_of "$ROOT/a-cm")" = "$NEW" ] && [ "$(cat "$ROOT/a-cm/$SK/SKILL.md")" = v2 ]' "rc=$RC out=$OUT"
check "its ONE status line names the move and the commits behind, and orders a re-read" 'grep -q "^cm-worktree-sync: ff ${OLD:0:12}..${NEW:0:12} behind=2 | re-read $SK/SKILL.md now" <<<"$OUT" && [ "$(wc -l <<<"$OUT" | tr -d " ")" = 1 ]' "$OUT"
run a
check "a second run is silent" '[ "$RC" = 0 ] && [ -z "$OUT" ]' "$OUT"

# ---- 3. behind and dirty: a blocker, nothing touched ----
mkrepo b
upstream b v2; upstream b v3
OLD="$(head_of "$ROOT/b-cm")"
printf 'local edit\n' > "$ROOT/b-cm/$SK/SKILL.md"
run b
check "behind and dirty: exit 1, BLOCKED reason=dirty with the count behind and the cm:blocked line" '[ "$RC" = 1 ] && grep -q "^cm-worktree-sync: BLOCKED reason=dirty behind=2 ahead=0 | cm:blocked cm-worktree-sync worktree has 1 uncommitted change(s)" <<<"$OUT" && grep -q "(2 commits behind origin/main)" <<<"$OUT"' "rc=$RC out=$OUT"
check "the file and HEAD are untouched, the output is one line" '[ "$(head_of "$ROOT/b-cm")" = "$OLD" ] && [ "$(cat "$ROOT/b-cm/$SK/SKILL.md")" = "local edit" ] && [ "$(wc -l <<<"$OUT" | tr -d " ")" = 1 ]' "$OUT"
printf 'x\n' > "$ROOT/b-cm/new-untracked.txt"; gi "$ROOT/b-cm" checkout -q -- "$SK/SKILL.md"
run b
check "an untracked source file is dirt too (BLOCKED reason=dirty)" '[ "$RC" = 1 ] && grep -q "reason=dirty" <<<"$OUT"' "$OUT"
rm -f -- "$ROOT/b-cm/new-untracked.txt"
mkdir -p "$ROOT/b-cm/.agents/scratch"; printf 'tool scratch\n' > "$ROOT/b-cm/.agents/scratch/notes.txt"
run b
check "an untracked tool-scratch file on the census ignore list is not dirt: fast-forwarded" '[ "$RC" = 0 ] && [ "$(head_of "$ROOT/b-cm")" = "$(head_of "$ROOT/b-up")" ]' "rc=$RC $OUT"

# ---- 4. diverged ----
mkrepo c
commit "$ROOT/c-cm" "local.txt" "mine" "local only"
upstream c v2
LOC="$(head_of "$ROOT/c-cm")"
run c
check "diverged with the skill dir changed upstream: BLOCKED reason=diverged, no merge commit, HEAD unchanged" '[ "$RC" = 1 ] && grep -q "reason=diverged behind=1 ahead=1" <<<"$OUT" && [ "$(head_of "$ROOT/c-cm")" = "$LOC" ]' "rc=$RC $OUT"
mkrepo c2
commit "$ROOT/c2-cm" "local.txt" "mine" "local only"
run c2
check "only ahead: silent" '[ "$RC" = 0 ] && [ -z "$OUT" ]' "$OUT"

# ---- 5. fetch fails ----
mkrepo d
upstream d v2
git -C "$ROOT/d-cm" remote set-url origin "$ROOT/does-not-exist.git"
run d
check "a fetch that fails: BLOCKED reason=fetch, exit 1" '[ "$RC" = 1 ] && grep -q "reason=fetch" <<<"$OUT"' "rc=$RC $OUT"

# ---- 6. index.lock ----
mkrepo e
upstream e v2
OLD="$(head_of "$ROOT/e-cm")"; NEW="$(head_of "$ROOT/e-up")"
: > "$ROOT/e-cm/.git/index.lock"; age_lock "$ROOT/e-cm" 700000
run e
check "a stale empty old unheld lock (8 days): removed, reported on the line, fast-forwarded" '[ "$RC" = 0 ] && [ ! -e "$ROOT/e-cm/.git/index.lock" ] && [ "$(head_of "$ROOT/e-cm")" = "$NEW" ] && grep -q "^cm-worktree-sync: ff ${OLD:0:12}..${NEW:0:12} behind=1 lock=removed(age 7[0-9]*s) | re-read" <<<"$OUT"' "rc=$RC $OUT"

mkrepo f
upstream f v2
OLD="$(head_of "$ROOT/f-cm")"
: > "$ROOT/f-cm/.git/index.lock"
run f
check "a young empty lock (just made): kept, BLOCKED reason=index-lock, nothing fast-forwarded" '[ "$RC" = 1 ] && [ -e "$ROOT/f-cm/.git/index.lock" ] && [ "$(head_of "$ROOT/f-cm")" = "$OLD" ] && grep -q "reason=index-lock" <<<"$OUT" && grep -q "younger than 600s" <<<"$OUT"' "rc=$RC $OUT"
check "the blocker line carries the lock age, size and holder and the commits behind" 'grep -q "lock=index.lock(age [0-9]*s,size 0,holder=none)" <<<"$OUT" && grep -q "behind=1" <<<"$OUT"' "$OUT"

mkrepo g
upstream g v2
OLD="$(head_of "$ROOT/g-cm")"
: > "$ROOT/g-cm/.git/index.lock"; age_lock "$ROOT/g-cm" 7200
hold "$ROOT/g-cm/.git/index.lock"; age_lock "$ROOT/g-cm" 7200
run g
check "an old empty lock HELD by a live process: kept, the holder pid named, nothing fast-forwarded" '[ "$RC" = 1 ] && [ -e "$ROOT/g-cm/.git/index.lock" ] && [ "$(head_of "$ROOT/g-cm")" = "$OLD" ] && grep -q "holder=[^ ]*$HP:" <<<"$OUT" && grep -q "holder is " <<<"$OUT"' "rc=$RC hp=$HP $OUT"
# the same with only the /proc scan: no fuser and no lsof on PATH
mkdir -p "$ROOT/nopath"
for t in git bash env sed grep head tr cat mktemp rm dirname uname awk date timeout perl yq jq stat wc readlink sleep cut sort tail find ls touch kill basename mkdir; do p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$ROOT/nopath/$t"; done
OUT="$(PATH="$ROOT/nopath" "$X" --repo "$ROOT/g-cm" --path "$SK" 2>&1)"; RC=$?
check "held lock, no fuser and no lsof: the /proc fd scan still finds the holder, lock kept" '[ "$RC" = 1 ] && [ -e "$ROOT/g-cm/.git/index.lock" ] && grep -q "holder=[^ ]*$HP:" <<<"$OUT"' "rc=$RC $OUT"
release
run g
check "the same lock once the holder is gone: removed, fast-forwarded" '[ "$RC" = 0 ] && [ ! -e "$ROOT/g-cm/.git/index.lock" ] && [ "$(head_of "$ROOT/g-cm")" = "$(head_of "$ROOT/g-up")" ]' "rc=$RC $OUT"

mkrepo h
upstream h v2
OLD="$(head_of "$ROOT/h-cm")"
printf 'pid 123\n' > "$ROOT/h-cm/.git/index.lock"; age_lock "$ROOT/h-cm" 7200
run h
check "an old lock that is NOT empty: kept, BLOCKED, never removed" '[ "$RC" = 1 ] && [ -e "$ROOT/h-cm/.git/index.lock" ] && grep -q "not empty" <<<"$OUT" && [ "$(head_of "$ROOT/h-cm")" = "$OLD" ]' "rc=$RC $OUT"

mkrepo i
upstream i v2
OLD="$(head_of "$ROOT/i-cm")"
: > "$ROOT/i-cm/.git/index.lock"; age_lock "$ROOT/i-cm" 7200
mkdir -p "$ROOT/emptyproc"
OUT="$(PATH="$ROOT/nopath" CM_TEST=1 CM_PROC_ROOT="$ROOT/emptyproc" "$X" --repo "$ROOT/i-cm" --path "$SK" 2>&1)"; RC=$?
check "nobody can tell who holds it (no fuser, no lsof, no /proc): holder=unknown, lock kept, BLOCKED" '[ "$RC" = 1 ] && [ -e "$ROOT/i-cm/.git/index.lock" ] && grep -q "holder=unknown" <<<"$OUT" && [ "$(head_of "$ROOT/i-cm")" = "$OLD" ]' "rc=$RC $OUT"

mkrepo j
upstream j v2
OLD="$(head_of "$ROOT/j-cm")"
: > "$ROOT/j-cm/.git/index.lock"; age_lock "$ROOT/j-cm" 7200
run j --dry-run
check "--dry-run with a stale lock: says what it would do, removes nothing, moves nothing" '[ "$RC" = 0 ] && grep -q "dry-run would remove the stale empty" <<<"$OUT" && [ -e "$ROOT/j-cm/.git/index.lock" ] && [ "$(head_of "$ROOT/j-cm")" = "$OLD" ]' "rc=$RC $OUT"

mkrepo k
: > "$ROOT/k-cm/.git/index.lock"; age_lock "$ROOT/k-cm" 7200
run k
check "a stale lock while the worktree is level: silent, the lock is left alone (it blocks nothing yet)" '[ "$RC" = 0 ] && [ -z "$OUT" ] && [ -e "$ROOT/k-cm/.git/index.lock" ]' "rc=$RC $OUT"

# ---- usage ----
OUT="$("$X" --bogus 2>&1)"; RC=$?
check "an unknown argument exits 2" '[ "$RC" = 2 ]' "rc=$RC $OUT"
OUT="$("$X" --repo 2>&1)"; RC=$?
check "--repo with no value exits 2" '[ "$RC" = 2 ]' "rc=$RC $OUT"
OUT="$("$X" --repo "$ROOT/nope" 2>&1)"; RC=$?
check "a missing directory exits 2" '[ "$RC" = 2 ]' "rc=$RC $OUT"
OUT="$("$X" --repo "$ROOT/a-cm" --remote nosuch 2>&1)"; RC=$?
check "a missing remote exits 2" '[ "$RC" = 2 ]' "rc=$RC $OUT"

# ---- 7. a rebase, merge, cherry-pick or bisect in progress: never fast-forwarded under it ----
mkrepo r
commit "$ROOT/r-up" "src/more1.txt" "m1" "more 1"; commit "$ROOT/r-up" "src/more2.txt" "m2" "more 2"; gi "$ROOT/r-up" push -q origin main
git -C "$ROOT/r-cm" pull -q --ff-only
(cd "$ROOT/r-cm" && GIT_SEQUENCE_EDITOR="sed -i '1s/^pick/edit/'" git -c commit.gpgsign=false rebase -i HEAD~2 >/dev/null 2>&1)
upstream r v2
OLD="$(head_of "$ROOT/r-cm")"
check "the repro really is mid-rebase (rebase-merge in the git dir)" '[ -d "$ROOT/r-cm/.git/rebase-merge" ] || [ -d "$ROOT/r-cm/.git/rebase-apply" ]'
run r
check "mid-rebase with origin ahead: BLOCKED reason=in-progress, exit 1, HEAD unmoved" '[ "$RC" = 1 ] && grep -q "reason=in-progress" <<<"$OUT" && grep -q "rebase-merge\|rebase-apply" <<<"$OUT" && [ "$(head_of "$ROOT/r-cm")" = "$OLD" ]' "rc=$RC $OUT HEAD=$(head_of "$ROOT/r-cm")"
git -C "$ROOT/r-cm" rebase --abort >/dev/null 2>&1
run r
check "after the rebase is aborted the same worktree is fast-forwarded" '[ "$RC" = 0 ] && [ "$(head_of "$ROOT/r-cm")" = "$(head_of "$ROOT/r-up")" ]' "rc=$RC $OUT"
for mk in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
  n="p$(printf '%s' "$mk" | tr -dc '[:upper:]' | head -c 3)"; mkrepo "$n"; upstream "$n" v2; OLD="$(head_of "$ROOT/$n-cm")"
  git -C "$ROOT/$n-cm" rev-parse HEAD > "$ROOT/$n-cm/.git/$mk"
  run "$n"
  check "$mk present: BLOCKED reason=in-progress, HEAD unmoved" '[ "$RC" = 1 ] && grep -q "reason=in-progress" <<<"$OUT" && grep -q "$mk" <<<"$OUT" && [ "$(head_of "$ROOT/$n-cm")" = "$OLD" ]' "rc=$RC $OUT"
done

# ---- 8. an INSTALLED copy (in no git worktree, no worktrees.self_path): the worktree is found by name, else INFO, never a blocker ----
mkdir -p "$ROOT/inst/bin" "$ROOT/inst/stub"
cp "$S"/lib.sh "$S"/cm-worktree-sync.sh "$ROOT/inst/bin/"; cp "$S"/*.jq "$ROOT/inst/bin/" 2>/dev/null
cat > "$ROOT/inst/cli" <<'E'
#!/usr/bin/env bash
case "$1 $2" in
  "worktree list") [ -f "$STUB_WT" ] || { echo "no list" >&2; exit 1; }; cat "$STUB_WT" ;;
  *) echo '{"ok":false}'; exit 1 ;;
esac
E
chmod +x "$ROOT/inst/cli"
export STUB_WT="$ROOT/inst/stub/wt.json" ORCA_CLI_COMMAND="$ROOT/inst/cli" PLUGLY_CLI_COMMAND="$ROOT/inst/cli" CM_CLI_KIND=orca
wtrows() { printf '%s\n' "$@" | jq -R -s -c '{ok: true, result: {worktrees: (split("\n") | map(select(length > 0)) | map({path: ., displayName: (split("/") | last), isMainWorktree: false, isArchived: false})), totalCount: 1, truncated: false}}' > "$STUB_WT"; }
# shellcheck disable=SC2119,SC2120  # inst takes optional extra arguments
inst() { OUT="$(env CM_ORCA_REPO=acme-app CM_ORG="$(basename "$ROOT")" CM_REPO="${INST_REPO-a}" CM_PATH_MATCH='/acme-app/|/Extra-Repo/' CM_SYNC_LOOKUP_TIMEOUT=10 "${INST_BIN:-$ROOT/inst/bin}/cm-worktree-sync.sh" "$@" 2>&1)"; RC=$?; }
CMW="$ROOT/wt/acme-app/concertmaster"; mkdir -p "$ROOT/wt/acme-app"
git clone -q "$ROOT/a.git" "$CMW"
wtrows "$CMW" "$ROOT/wt/acme-app/dev-1"
upstream a v9
OLD="$(head_of "$CMW")"
inst
check "installed copy, no self_path: the worktree named worktrees.self_name, under the main repo dir, is found and fast-forwarded" '[ "$RC" = 0 ] && ! grep -q "not inside a git worktree" <<<"$OUT" && [ "$(head_of "$CMW")" = "$(head_of "$ROOT/a-up")" ] && [ "$(head_of "$CMW")" != "$OLD" ]' "rc=$RC $OUT"
wtrows "$ROOT/wt/acme-app/dev-1"
inst
check "installed copy, no worktree of that name: 'cm-worktree-sync: INFO not configured', exit 0, never BLOCKED" '[ "$RC" = 0 ] && grep -q "^cm-worktree-sync: INFO not configured" <<<"$OUT" && ! grep -q BLOCKED <<<"$OUT"' "rc=$RC $OUT"
wtrows "$CMW" "$ROOT/wt/acme-app/x/concertmaster"
inst
check "installed copy, two worktrees of that name in the main repo: INFO not configured (never a guess), exit 0" '[ "$RC" = 0 ] && grep -q "INFO not configured" <<<"$OUT"' "rc=$RC $OUT"
rm -f "$STUB_WT"
inst
check "installed copy, the fleet CLI cannot list: INFO not configured, exit 0" '[ "$RC" = 0 ] && grep -q "INFO not configured" <<<"$OUT" && ! grep -q BLOCKED <<<"$OUT"' "rc=$RC $OUT"

# path_match also covers the EXTRA repos, so a same-named worktree of another repo (Extra-Repo) must never be synced.
mkrepo sl; git clone -q "$ROOT/sl.git" "$ROOT/wt/Extra-Repo-tmp" && mkdir -p "$ROOT/wt/Extra-Repo" && mv "$ROOT/wt/Extra-Repo-tmp" "$ROOT/wt/Extra-Repo/concertmaster"
upstream sl v2
SLW="$ROOT/wt/Extra-Repo/concertmaster"; SLOLD="$(head_of "$SLW")"
wtrows "$SLW"
inst
check "THE REPRO: a worktree list holding only <x>/Extra-Repo/concertmaster (one behind its origin) is NOT synced: INFO not configured, rc 0, HEAD unmoved" '[ "$RC" = 0 ] && grep -q "INFO not configured" <<<"$OUT" && ! grep -q "ff " <<<"$OUT" && [ "$(head_of "$SLW")" = "$SLOLD" ]' "rc=$RC $OUT"
wtrows "$SLW" "$CMW"
upstream a v10; OLD="$(head_of "$CMW")"
inst
check "a same-named worktree in another repo next to the real one: only the main repo's is synced, the other is untouched" '[ "$RC" = 0 ] && [ "$(head_of "$CMW")" = "$(head_of "$ROOT/a-up")" ] && [ "$(head_of "$CMW")" != "$OLD" ] && [ "$(head_of "$SLW")" = "$SLOLD" ]' "rc=$RC $OUT"
# a row that names another repo is excluded even when its path sits under the main repo dir
jq -n --arg p "$ROOT/wt/acme-app/other/concertmaster" '{ok:true,result:{worktrees:[{path:$p,displayName:"concertmaster",repoName:"Extra-Repo",isArchived:false}]}}' > "$STUB_WT"
mkdir -p "$ROOT/wt/acme-app/other"; git clone -q "$ROOT/a.git" "$ROOT/wt/acme-app/other/concertmaster"
upstream a v11; OTH="$(head_of "$ROOT/wt/acme-app/other/concertmaster")"
inst
check "a row whose repoName is another repo is not this repo's worktree even under the main repo dir: INFO, unmoved" '[ "$RC" = 0 ] && grep -q "INFO not configured" <<<"$OUT" && [ "$(head_of "$ROOT/wt/acme-app/other/concertmaster")" = "$OTH" ]' "rc=$RC $OUT"
# the path is under the main repo dir, but the checkout's origin is another repository: never fetched or moved
mkrepo wr; mkdir -p "$ROOT/wt/acme-app/wrongremote"; git clone -q "$ROOT/wr.git" "$ROOT/wt/acme-app/wrongremote/concertmaster"; upstream wr v2
WRW="$ROOT/wt/acme-app/wrongremote/concertmaster"; WROLD="$(head_of "$WRW")"
wtrows "$WRW"
inst
check "a worktree whose origin is not github.org/github.main_repo: INFO not configured naming it, HEAD unmoved" '[ "$RC" = 0 ] && grep -q "INFO not configured" <<<"$OUT" && grep -q "does not match" <<<"$OUT" && [ "$(head_of "$WRW")" = "$WROLD" ]' "rc=$RC $OUT"
wtrows "$CMW"; upstream a v12; OLD="$(head_of "$CMW")"
INST_REPO="" inst
check "main repo not configured (no github.main_repo): a lookup-chosen worktree is never synced unverified" '[ "$RC" = 0 ] && grep -q "INFO not configured" <<<"$OUT" && [ "$(head_of "$CMW")" = "$OLD" ]' "rc=$RC $OUT"
# an explicit --repo (the operator's own choice) is not subject to the lookup rules
wtrows "$ROOT/wt/acme-app/dev-1"
inst --repo "$CMW" --path "$SK"
check "an explicit --repo is synced as before (the lookup rules apply to the lookup only)" '[ "$RC" = 0 ] && [ "$(head_of "$CMW")" = "$(head_of "$ROOT/a-up")" ]' "rc=$RC $OUT"

# EVERY resolved path is verified (repo + origin), not only the name lookup. A stale CM_SELF_PATH or a copy
# checked out of another repository is never fetched or fast-forwarded; only an explicit --repo is taken as given.
mkrepo fo; upstream fo v2                                  # another repository ("<root>/fo"), one commit behind its origin
FOW="$ROOT/fo-cm"; FOOLD="$(head_of "$FOW")"
CM_SELF_PATH="$FOW" inst
check "CM_SELF_PATH at a checkout of ANOTHER repo: INFO not configured naming it, exit 0, HEAD unmoved" '[ "$RC" = 0 ] && grep -q "^cm-worktree-sync: INFO not configured" <<<"$OUT" && grep -q "does not match" <<<"$OUT" && ! grep -q "ff " <<<"$OUT" && [ "$(head_of "$FOW")" = "$FOOLD" ]' "rc=$RC $OUT"
git clone -q "$ROOT/a.git" "$ROOT/copy-cm"; git -C "$ROOT/copy-cm" remote set-url origin "https://github.com/Foreign/other-repo.git"
upstream a v13; COPYOLD="$(head_of "$ROOT/copy-cm")"
CM_SELF_PATH="$ROOT/copy-cm" inst
check "CM_SELF_PATH at a copy of the checkout whose origin is a foreign url: INFO, exit 0, HEAD unmoved (and no fetch of the foreign url)" '[ "$RC" = 0 ] && grep -q "INFO not configured" <<<"$OUT" && [ "$(head_of "$ROOT/copy-cm")" = "$COPYOLD" ]' "rc=$RC $OUT"
mkdir -p "$ROOT/plain-dir/sub"; git init -q -b main "$ROOT/plain-dir"; git -C "$ROOT/plain-dir" remote add origin "$ROOT/a.git"
CM_SELF_PATH="$ROOT/plain-dir/sub" inst
check "CM_SELF_PATH at a SUBDIRECTORY of a checkout (not its toplevel): INFO, nothing moved" '[ "$RC" = 0 ] && grep -q "INFO not configured" <<<"$OUT"' "rc=$RC $OUT"
OLD="$(head_of "$CMW")"
CM_SELF_PATH="$CMW" inst
check "CM_SELF_PATH at the REAL checkout (origin is this repo): still fast-forwarded" '[ "$RC" = 0 ] && [ "$(head_of "$CMW")" = "$(head_of "$ROOT/a-up")" ] && [ "$(head_of "$CMW")" != "$OLD" ]' "rc=$RC $OUT"
# worktrees.self_path from config goes through the same check as CM_SELF_PATH
upstream fo v3; FOOLD="$(head_of "$FOW")"
printf 'schema: concertmaster.config/v1\nworktrees: { self_name: concertmaster, self_path: "%s" }\n' "$FOW" > "$ROOT/config-selfpath.yaml"
CM_CONFIG="$ROOT/config-selfpath.yaml" inst
check "worktrees.self_path (config) at another repo's checkout: INFO, HEAD unmoved" '[ "$RC" = 0 ] && grep -q "INFO not configured" <<<"$OUT" && [ "$(head_of "$FOW")" = "$FOOLD" ]' "rc=$RC $OUT"
# the script run from a worktree of ANOTHER repo (a copy of the skill checked out there): that worktree is not synced either
mkdir -p "$FOW/$SK/scripts-copy"; cp "$S"/lib.sh "$S"/cm-worktree-sync.sh "$FOW/$SK/scripts-copy/"; cp "$S"/*.jq "$FOW/$SK/scripts-copy/" 2>/dev/null
OUT="$(env CM_ORG="$(basename "$ROOT")" CM_REPO=a "$FOW/$SK/scripts-copy/cm-worktree-sync.sh" 2>&1)"; RC=$?
check "the script run from a checkout of another repo (no --repo, no CM_SELF_PATH): INFO, HEAD unmoved" '[ "$RC" = 0 ] && grep -q "INFO not configured" <<<"$OUT" && [ "$(head_of "$FOW")" = "$FOOLD" ]' "rc=$RC $OUT"
rm -rf -- "${FOW:?}/$SK/scripts-copy"

# ---- 9. the time budget (boot-sweep kills at 90 s): a slow fetch or merge never leaves a half-done fast-forward ----
mkdir -p "$ROOT/slow"
cat > "$ROOT/slow/git" <<'E'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    fetch) [ -z "${SLOW_FETCH:-}" ] || sleep "$SLOW_FETCH" ;;
    merge) [ -z "${SLOW_MERGE:-}" ] || sleep "$SLOW_MERGE" ;;
  esac
done
exec "$REAL_GIT" "$@"
E
chmod +x "$ROOT/slow/git"; REAL_GIT="$(command -v git)"; export REAL_GIT
mkrepo t; upstream t v2; TOLD="$(head_of "$ROOT/t-cm")"
OUT="$(PATH="$ROOT/slow:$PATH" SLOW_FETCH=3 CM_SYNC_BUDGET=6 CM_SYNC_MIN_FF=4 "$X" --repo "$ROOT/t-cm" --path "$SK" 2>&1)"; RC=$?
check "a fetch that eats the budget: DEFERRED time budget, exit 0 (not a blocker), nothing moved" '[ "$RC" = 0 ] && grep -q "^cm-worktree-sync: DEFERRED time budget" <<<"$OUT" && [ "$(head_of "$ROOT/t-cm")" = "$TOLD" ]' "rc=$RC $OUT"
OUT="$(PATH="$ROOT/slow:$PATH" SLOW_FETCH=0 CM_SYNC_BUDGET=60 CM_SYNC_MIN_FF=4 "$X" --repo "$ROOT/t-cm" --path "$SK" 2>&1)"; RC=$?
check "with budget left the same fast-forward is done" '[ "$RC" = 0 ] && [ "$(head_of "$ROOT/t-cm")" = "$(head_of "$ROOT/t-up")" ]' "rc=$RC $OUT"
mkrepo u; upstream u v2; UOLD="$(head_of "$ROOT/u-cm")"
OUT="$(PATH="$ROOT/slow:$PATH" SLOW_MERGE=5 CM_SYNC_MERGE_TIMEOUT=1 CM_SYNC_BUDGET=60 "$X" --repo "$ROOT/u-cm" --path "$SK" 2>&1)"; RC=$?
check "a merge that outlives its bound is cut: BLOCKED reason=ff-refused 'timed out', exit 1, within seconds" '[ "$RC" = 1 ] && grep -q "reason=ff-refused" <<<"$OUT" && grep -q "timed out" <<<"$OUT"' "rc=$RC $OUT"
mkrepo v; upstream v v2
OUT="$(PATH="$ROOT/slow:$PATH" SLOW_FETCH=8 CM_SYNC_FETCH_TIMEOUT=50 CM_SYNC_BUDGET=3 "$X" --repo "$ROOT/v-cm" --path "$SK" 2>&1)"; RC=$?
check "the fetch timeout is cut to the budget (a 3 s budget never waits for an 8 s fetch): BLOCKED reason=fetch" '[ "$RC" = 1 ] && grep -q "reason=fetch" <<<"$OUT"' "rc=$RC $OUT"

# ---- mutants on a scratch copy of the scripts: each guard removed must fail a case ----
mkdir -p "$ROOT/mut" && cp "$S"/*.sh "$ROOT/mut/" && cp "$S"/*.jq "$ROOT/mut/" 2>/dev/null
M="$ROOT/mut/cm-worktree-sync.sh"
mutant() { # <label> <perl substitution> <case: dirty|held|young|notempty|unknown>
  cp "$X" "$M"; perl -0pi -e "$2" "$M"
  if cmp -s "$X" "$M"; then fail "mutant $1" "the edit changed nothing"; return; fi
  local n="m$3" old
  mkrepo "$n"; upstream "$n" v2; old="$(head_of "$ROOT/$n-cm")"
  case "$3" in
    dirty) printf 'local edit\n' > "$ROOT/$n-cm/$SK/SKILL.md"; OUT="$("$M" --repo "$ROOT/$n-cm" --path "$SK" 2>&1)"; RC=$? ;;
    held) : > "$ROOT/$n-cm/.git/index.lock"; hold "$ROOT/$n-cm/.git/index.lock"; age_lock "$ROOT/$n-cm" 7200; OUT="$("$M" --repo "$ROOT/$n-cm" --path "$SK" 2>&1)"; RC=$?; release ;;
    young) : > "$ROOT/$n-cm/.git/index.lock"; OUT="$("$M" --repo "$ROOT/$n-cm" --path "$SK" 2>&1)"; RC=$? ;;
    notempty) printf 'pid 1\n' > "$ROOT/$n-cm/.git/index.lock"; age_lock "$ROOT/$n-cm" 7200; OUT="$("$M" --repo "$ROOT/$n-cm" --path "$SK" 2>&1)"; RC=$? ;;
    unknown) : > "$ROOT/$n-cm/.git/index.lock"; age_lock "$ROOT/$n-cm" 7200; OUT="$(PATH="$ROOT/nopath" CM_TEST=1 CM_PROC_ROOT="$ROOT/emptyproc" "$M" --repo "$ROOT/$n-cm" --path "$SK" 2>&1)"; RC=$? ;;
  esac
  # the guarded behaviour: a blocker (exit 1) for the RIGHT reason (git's own refusal to overwrite a dirty file is a second line,
  # so the reason is judged too) and HEAD never moved
  want=index-lock; [ "$3" = dirty ] && want=dirty
  if [ "$RC" = 1 ] && grep -q "reason=$want" <<<"$OUT" && [ "$(head_of "$ROOT/$n-cm")" = "$old" ]; then fail "mutant $1" "the mutated script still blocked"; else pass "mutant $1 is caught"; fi
}
mutant "dirty check removed" 's/if \[ "\$\{dirt:-0\}" -gt 0 \]; then blocked dirty/if false; then blocked dirty/' dirty
mutant "held-lock check removed" 's/elif \[ "\$hold" != none \]; then/elif false; then/' held
mutant "lock age check removed" 's/elif \[ "\$age" -lt "\$MINAGE" \]; then/elif false; then/' young
mutant "lock empty check removed" 's/if \[ "\$size" -ne 0 \]; then why=/if false; then why=/' notempty
mutant "unknown-holder guard removed" 's/elif \[ "\$known" = 1 \]; then printf none; else printf unknown; fi/else printf none; fi/' unknown

# 7 and 8 mutants: the in-progress guard and the INFO downgrade removed must change the answer
cp "$X" "$M"; perl -0pi -e 's/  if \[ -e "\$mp" \]; then blocked in-progress[^\n]*fi\n//' "$M"
if cmp -s "$X" "$M"; then fail "mutant in-progress guard" "the edit changed nothing"; else
  mkrepo mr; commit "$ROOT/mr-up" "src/more1.txt" "m1" "more 1"; commit "$ROOT/mr-up" "src/more2.txt" "m2" "more 2"; gi "$ROOT/mr-up" push -q origin main; git -C "$ROOT/mr-cm" pull -q --ff-only
  (cd "$ROOT/mr-cm" && GIT_SEQUENCE_EDITOR="sed -i '1s/^pick/edit/'" git -c commit.gpgsign=false rebase -i HEAD~2 >/dev/null 2>&1); upstream mr v2; old="$(head_of "$ROOT/mr-cm")"
  OUT="$("$M" --repo "$ROOT/mr-cm" --path "$SK" 2>&1)"; RC=$?
  if [ "$RC" = 1 ] && grep -q "reason=in-progress" <<<"$OUT" && [ "$(head_of "$ROOT/mr-cm")" = "$old" ]; then fail "mutant in-progress guard" "still blocked"; else pass "mutant in-progress guard removed is caught"; fi
fi
cp "$X" "$M"; perl -0pi -e 's/(\(set worktrees\.self_path[^\n]*\n)      exit 0/$1      exit 1/' "$M"
if cmp -s "$X" "$M"; then fail "mutant INFO downgrade" "the edit changed nothing"; else
  wtrows "$ROOT/wt/acme-app/dev-1"
  INST_BIN="$ROOT/mut" inst
  if [ "$RC" = 0 ]; then fail "mutant INFO downgrade" "still exit 0"; else pass "mutant INFO downgrade (exit 1 instead of 0) is caught"; fi
fi
# lookup, remote and budget mutants: each guard removed must make the bad case happen
lookup_mutant() { # <label> <perl> <case: orca|repoName|remote|norepo>
  cp "$X" "$M"; perl -0pi -e "$2" "$M"
  if cmp -s "$X" "$M"; then fail "mutant $1" "the edit changed nothing"; return; fi
  local w old
  case "$3" in
    orca) w="$SLW" ;; repoName) w="$ROOT/wt/acme-app/other/concertmaster" ;; remote|norepo) w="$WRW" ;;
  esac
  git -C "$w" fetch -q 2>/dev/null; git -C "$w" reset -q --hard "$(git -C "$w" rev-list --max-parents=0 HEAD | tail -1)" 2>/dev/null
  old="$(head_of "$w")"
  case "$3" in
    repoName) jq -n --arg p "$w" '{ok:true,result:{worktrees:[{path:$p,displayName:"concertmaster",repoName:"Extra-Repo",isArchived:false}]}}' > "$STUB_WT" ;;
    orca) wtrows "$w" ;;
    *) wtrows "$w" ;;
  esac
  # the origin of that checkout is its own repo, so the repo under test is told to be THAT one: only the guard under test stands in the way
  case "$3" in
    orca) INST_REPO=sl INST_BIN="$ROOT/mut" inst ;;
    remote) INST_REPO=a INST_BIN="$ROOT/mut" inst ;;
    repoName) INST_REPO=a INST_BIN="$ROOT/mut" inst ;;
  esac
  if [ "$(head_of "$w")" != "$old" ]; then pass "mutant $1 is caught (the other repo's worktree was moved)"; else fail "mutant $1" "the mutated script still left it alone"; fi
}
lookup_mutant "orca_repo path rule removed" 's/          \| select\(\(\$seg\[:-1\] \| map\(ascii_downcase\) \| index\(\$orca\)\) != null\)\n//' orca
lookup_mutant "repoName rule removed" 's/          \| select\(\(\(\(\.repoName[^\n]*\n//' repoName
lookup_mutant "origin check removed" 's/ \|\| ! remote_is_this_repo "\$REPO" "\$REMOTE"//' remote
# resolved-path verification removed: a stale CM_SELF_PATH at another repo's checkout must now be moved
cp "$X" "$M"; perl -0pi -e 's/if \[ "\$REPO_SRC" != explicit \]; then/if false; then/' "$M"
if cmp -s "$X" "$M"; then fail "mutant resolved-path check" "the edit changed nothing"; else
  mkrepo fm; upstream fm v2; FMOLD="$(head_of "$ROOT/fm-cm")"
  CM_SELF_PATH="$ROOT/fm-cm" INST_BIN="$ROOT/mut" inst
  if [ "$(head_of "$ROOT/fm-cm")" != "$FMOLD" ]; then pass "mutant resolved-path check removed is caught (the other repo's checkout was moved)"; else fail "mutant resolved-path check" "the mutated script still left it alone: $OUT"; fi
fi
# the budget mutants
cp "$X" "$M"; perl -0pi -e 's/if \[ "\$\(left\)" -lt "\$\{CM_SYNC_MIN_FF:-20\}" \]; then/if false; then/' "$M"
if cmp -s "$X" "$M"; then fail "mutant budget deferral" "the edit changed nothing"; else
  mkrepo w1; upstream w1 v2; W1="$(head_of "$ROOT/w1-cm")"
  OUT="$(PATH="$ROOT/slow:$PATH" SLOW_FETCH=3 CM_SYNC_BUDGET=6 CM_SYNC_MIN_FF=4 "$M" --repo "$ROOT/w1-cm" --path "$SK" 2>&1)"
  if [ "$(head_of "$ROOT/w1-cm")" != "$W1" ]; then pass "mutant budget deferral removed is caught (it fast-forwarded with the budget spent)"; else fail "mutant budget deferral" "still deferred"; fi
fi
cp "$X" "$M"; perl -0pi -e 's/rc=0; cm_timeout "\$MT" git -C/rc=0; git -C/' "$M"
if cmp -s "$X" "$M"; then fail "mutant merge bound" "the edit changed nothing"; else
  mkrepo w2; upstream w2 v2; S0=$SECONDS
  OUT="$(PATH="$ROOT/slow:$PATH" SLOW_MERGE=4 CM_SYNC_MERGE_TIMEOUT=1 CM_SYNC_BUDGET=60 "$M" --repo "$ROOT/w2-cm" --path "$SK" 2>&1)"; RC=$?
  if [ "$RC" = 0 ] && ! grep -q "timed out" <<<"$OUT"; then pass "mutant merge bound removed is caught (the slow merge ran to its end, unbounded)"; else fail "mutant merge bound" "still bounded: rc=$RC $OUT"; fi
fi

printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
