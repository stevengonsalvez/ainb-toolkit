#!/usr/bin/env bash
# cm-worktree-sync.sh: keep the concertmaster's OWN worktree level with origin/main (hard rule 30).
# Runs at boot (scripts/boot-sweep.sh) and at tick step 1. The failure it exists for: a worktree ran hundreds of skill
# commits behind main for days because a stale, empty `.git/.../index.lock` blocked the fast-forward and nothing noticed.
#
#   scripts/cm-worktree-sync.sh [--dry-run] [--repo <dir>] [--path <skill dir in the repo>] [--remote origin] [--branch main]
#
# Compares the skill directory (--path, else `skill_sync.path`, else the directory this script sits in) of the concertmaster worktree with origin/main (git fetch, bounded by
# CM_SYNC_FETCH_TIMEOUT, default 50 s). Time budget (CM_SYNC_BUDGET, default 80 s, under boot-sweep's 90 s kill): the lookup (15 s),
# the fetch (50 s) and the merge (CM_SYNC_MERGE_TIMEOUT, 30 s) all count against it, and a fast-forward is not STARTED with under
# CM_SYNC_MIN_FF (20 s) of it left: `cm-worktree-sync: DEFERRED time budget ...`, exit 0, nothing moved, the next tick retries. A
# merge that exceeds its bound is BLOCKED reason=ff-refused (check `git status` by hand), never left to a caller's kill. Which worktree: --repo, else CM_SELF_PATH, else
# `worktrees.self_path` in config, else the worktree holding this script (the concertmaster runs its scripts from it), else, for
# an INSTALLED copy (~/.concertmaster/bin, in no git worktree), the one live worktree of the fleet CLI's `worktree list` whose
# name is `worktrees.self_name`, that sits under a /<worktrees.orca_repo>/ directory of the MAIN repo (never an extra managed repo such
# as Extra-Repo) and whose `origin` url is github.org/github.main_repo (else INFO not configured, nothing fetched or moved). When none or several qualify the worktree is "not
# configured": one INFO line, exit 0, never a blocker (a host that does not run the concertmaster has no such worktree).
# EVERY path that was resolved (CM_SELF_PATH, worktrees.self_path, the worktree holding this script, the lookup; not an explicit --repo)
# must be a git toplevel whose `origin` is github.org/github.main_repo before anything is fetched: a stale CM_SELF_PATH or a copy checked
# out of another repository is INFO not configured, nothing fetched, moved, reset or deleted.
#
#   equal (the skill dir is the same, or origin has nothing new there, or this branch is only ahead)
#                              prints NOTHING, exit 0
#   behind and clean, no lock  git merge --ff-only origin/main (never reset, checkout -f or stash),
#                              prints `cm-worktree-sync: ff <old>..<new> behind=<n> | re-read SKILL.md now`, exit 0
#   behind and dirty           BLOCKED reason=dirty, exit 1, nothing touched (dirty = real tracked or untracked changes;
#                              the census ignore list `census.ignore_untracked` is honoured, as in the tick census)
#   diverged (local commits and origin moved the skill dir)   BLOCKED reason=diverged, exit 1, nothing touched
#   fetch failed or timed out  BLOCKED reason=fetch, exit 1
#   an index.lock in the worktree's git dir while a fast-forward is due:
#       removed ONLY when it is empty AND older than CM_SYNC_LOCK_MIN_AGE (default 600 s) AND no live process holds it
#       (fuser, else lsof, else a scan of /proc/*/fd, plus any git process whose command line names the worktree); the run
#       then goes on and says `lock=removed(age <s>s)` on its line. Otherwise BLOCKED reason=index-lock with the age, the
#       size and the holder (`holder=<pid:comm,...>`, `holder=none` or `holder=unknown`), exit 1, the lock left alone.
#       When no tool can tell who holds it (holder=unknown) it is never removed.
#   mid-rebase / merge / cherry-pick / bisect (rebase-merge, rebase-apply, MERGE_HEAD, CHERRY_PICK_HEAD, REVERT_HEAD or BISECT_LOG in
#       the git dir): BLOCKED reason=in-progress, exit 1, nothing touched, never fast-forwarded
#   no worktree resolvable   `cm-worktree-sync: INFO not configured: <why>`, exit 0
# One line each time, machine-friendly:
#   cm-worktree-sync: BLOCKED reason=<dirty|diverged|in-progress|fetch|index-lock|ff-refused|git> behind=<n> ahead=<n> [lock=...] | cm:blocked cm-worktree-sync <why>
# The text after `| ` is the line to carry in the concertmaster's own comment and a blocker row of the tick table.
# --dry-run changes nothing (no fast-forward, no lock removal) and says what it would do.
# Env: CM_SYNC_BUDGET (80), CM_SYNC_MIN_FF (20), CM_SYNC_MERGE_TIMEOUT (30), CM_SYNC_LOOKUP_TIMEOUT (15), CM_SYNC_FETCH_TIMEOUT, CM_SYNC_LOCK_MIN_AGE, CM_SELF_PATH (the worktree), CM_PROC_ROOT (tests only, with CM_TEST=1).
# Exit: 0 level or fast-forwarded; 1 blocker; 2 usage.
set -uo pipefail
T0="$(date +%s)"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

DRY=0; REPO=""; SPATH=""; REMOTE="$(cm_cfg .skill_sync.remote origin)"; BRANCH="$(cm_cfg .skill_sync.branch main)"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --repo) [ $# -ge 2 ] && [ -n "$2" ] || { cm_warn "cm-worktree-sync.sh: --repo needs a directory"; exit 2; }; REPO="$2"; shift ;;
    --path) [ $# -ge 2 ] && [ -n "$2" ] || { cm_warn "cm-worktree-sync.sh: --path needs a directory"; exit 2; }; SPATH="$2"; shift ;;
    --remote) [ $# -ge 2 ] && [ -n "$2" ] || { cm_warn "cm-worktree-sync.sh: --remote needs a name"; exit 2; }; REMOTE="$2"; shift ;;
    --branch) [ $# -ge 2 ] && [ -n "$2" ] || { cm_warn "cm-worktree-sync.sh: --branch needs a name"; exit 2; }; BRANCH="$2"; shift ;;
    -h|--help) sed -n '2,/^set -uo/{/^#/p;}' "$0"; exit 0 ;;
    *) cm_warn "cm-worktree-sync.sh: unknown arg: $1"; exit 2 ;;
  esac
  shift
done

# REPO_SRC: where the worktree path came from. Only an explicit --repo (the operator's own choice) is taken as given; every other
# source (CM_SELF_PATH, worktrees.self_path, the worktree holding this script, the fleet CLI lookup) is verified below.
REPO_SRC=explicit
if [ -z "$REPO" ]; then REPO="${CM_SELF_PATH:-$(cm_cfg .worktrees.self_path "")}"; REPO_SRC=configured; fi
# find_self_worktree: the path of the ONE live worktree of THIS repo named worktrees.self_name, from the fleet CLI; nothing when 0 or 2+
# qualify. This repo = the main Orca repo (worktrees.orca_repo, env CM_ORCA_REPO; the extra managed repos are NOT this repo): the path
# must sit under a /<orca_repo>/ directory (case-insensitive), and a row that names its repo (repoName or repo) must name that one.
# worktrees.path_match alone is not enough: it also covers the extra repos, and a same-named worktree there would be synced instead.
find_self_worktree() {
  local cli orca
  orca="${CM_ORCA_REPO:-$(cm_cfg .worktrees.orca_repo)}"; [ -n "$orca" ] || return 1
  cli="$(cm_cli 2>/dev/null)" || return 1
  cm_timeout "${CM_SYNC_LOOKUP_TIMEOUT:-15}" "$cli" worktree list --limit 500 --json </dev/null 2>/dev/null | cm_wt_dedupe 2>/dev/null \
    | jq -r --arg n "$(cm_lower "$CM_SELF_WORKTREE")" --arg re "$CM_PATH_MATCH" --arg orca "$(cm_lower "$orca")" '
        [ .result.worktrees[]? | select((.path | type) == "string" and .path != "") | select((.isArchived // false) | not)
          | select($re == "" or (.path | test($re)))
          | (.path | sub("/+$"; "") | split("/")) as $seg
          | select(($seg[:-1] | map(ascii_downcase) | index($orca)) != null)
          | select((((.repoName // .repo // "") | tostring | ascii_downcase) as $rp | $rp == "" or $rp == $orca))
          | select((($seg | last | ascii_downcase) == $n) or (((.displayName // "") | ascii_downcase) == $n))
          | .path | sub("/+$"; "") ] | unique | if length == 1 then .[0] else empty end' 2>/dev/null
}
# remote_is_this_repo <dir> <remote>: 0 when the remote url ends in <org>/<repo> (case-insensitive, .git optional) of the configured
# main repo (github.org + github.main_repo). Not configured or not equal: 1, so a lookup-chosen worktree is never synced unverified.
remote_is_this_repo() {
  local url tail
  [ -n "$CM_ORG" ] && [ -n "$CM_REPO" ] || return 1
  url="$(git -C "$1" remote get-url -- "$2" 2>/dev/null)" || return 1
  url="${url%/}"; url="${url%.git}"
  tail="$(printf '%s' "$url" | tr ':' '/' | awk -F/ 'NF >= 2 {print $(NF-1) "/" $NF}')"
  [ "$(cm_lower "$tail")" = "$(cm_lower "$CM_ORG/$CM_REPO")" ]
}
if [ -z "$REPO" ]; then
  REPO="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null)" || REPO=""
  REPO_SRC="the worktree holding this script"
  if [ -z "$REPO" ]; then
    REPO="$(find_self_worktree)" || REPO=""
    REPO_SRC="found by name"
    if [ -z "$REPO" ]; then
      echo "cm-worktree-sync: INFO not configured: no worktrees.self_path or CM_SELF_PATH, this copy is in no git worktree, and the fleet CLI lists no single worktree named '$CM_SELF_WORKTREE' (set worktrees.self_path, or run it from the concertmaster worktree)"
      exit 0
    fi
    [ -n "$SPATH" ] || SPATH="$(cm_cfg .skill_sync.path "")"
    [ -n "$SPATH" ] || { echo "cm-worktree-sync: INFO not configured: this copy is in no git worktree, so the skill directory inside the repo is unknown (set skill_sync.path): nothing compared"; exit 0; }
  fi
fi
[ -d "$REPO" ] || { cm_warn "cm-worktree-sync.sh: no such directory: $REPO"; exit 2; }
# A path that was RESOLVED (CM_SELF_PATH, worktrees.self_path, this script's own worktree, the lookup) rather than named with --repo
# must be a git toplevel whose remote is THIS repo before anything is fetched or moved: a stale CM_SELF_PATH, or a copy of the skill
# checked out of another repository, would otherwise be fast-forwarded. Nothing is ever reset or deleted either way.
if [ "$REPO_SRC" != explicit ]; then
  top="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)" || top=""
  if [ -z "$top" ] || [ "$(cd "$top" && pwd -P)" != "$(cd "$REPO" 2>/dev/null && pwd -P)" ] || ! remote_is_this_repo "$REPO" "$REMOTE"; then
    echo "cm-worktree-sync: INFO not configured: the worktree '$REPO' (${REPO_SRC/configured/CM_SELF_PATH or worktrees.self_path}) is not a checkout of $CM_ORG/$CM_REPO (its $REMOTE remote does not match, it is not a git toplevel, or github.org and github.main_repo are unset): not touched"
    exit 0
  fi
fi
if [ -z "$SPATH" ] && ! git -C "$HERE" rev-parse --show-toplevel >/dev/null 2>&1; then SPATH="$(cm_cfg .skill_sync.path "")"; fi
if [ -z "$SPATH" ] && [ "$REPO_SRC" != explicit ] && ! git -C "$HERE" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "cm-worktree-sync: INFO not configured: this copy is in no git worktree, so the skill directory inside the repo is unknown (set skill_sync.path or pass --path): nothing compared"
  exit 0
fi
if [ -z "$SPATH" ]; then
  top="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)"
  SPATH="$(cd "$HERE/.." && pwd -P)"; [ -n "$top" ] && SPATH="${SPATH#"$(cd "$top" && pwd -P)"/}"
fi
case "$SPATH" in /*|*..*|'') cm_warn "cm-worktree-sync.sh: --path must be a relative directory inside the repo"; exit 2 ;; esac
case "$REMOTE$BRANCH" in *[!A-Za-z0-9._/-]*) cm_warn "cm-worktree-sync.sh: odd remote or branch name"; exit 2 ;; esac
case "$REMOTE" in -*) cm_warn "cm-worktree-sync.sh: the remote name must not start with '-'"; exit 2 ;; esac
case "$BRANCH" in -*) cm_warn "cm-worktree-sync.sh: the branch name must not start with '-'"; exit 2 ;; esac
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { cm_warn "cm-worktree-sync.sh: not a git worktree: $REPO"; exit 2; }
git -C "$REPO" remote get-url -- "$REMOTE" >/dev/null 2>&1 || { cm_warn "cm-worktree-sync.sh: no such remote: $REMOTE"; exit 2; }
REPO="$(cd "$REPO" && pwd -P)"
g() { git -C "$REPO" "$@"; }
GITDIR="$(g rev-parse --absolute-git-dir 2>/dev/null)"
LOCK="$GITDIR/index.lock"
MINAGE="${CM_SYNC_LOCK_MIN_AGE:-600}"

BEHIND=0; AHEAD=0; LOCKNOTE=""
blocked() { # <reason> <why>
  printf 'cm-worktree-sync: BLOCKED reason=%s behind=%s ahead=%s%s | cm:blocked cm-worktree-sync %s (%s commits behind %s/%s)\n' \
    "$1" "$BEHIND" "$AHEAD" "${LOCKNOTE:+ $LOCKNOTE}" "$2" "$BEHIND" "$REMOTE" "$BRANCH"
  exit 1
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cm-wtsync.XXXXXX")" || { cm_warn "cm-worktree-sync.sh: cannot create a temp dir"; exit 1; }
trap 'rm -rf -- "${TMP:?}"' EXIT

left() { echo $(( ${CM_SYNC_BUDGET:-80} - ( $(date +%s) - T0 ) )); }   # seconds of the time budget still unspent
FT="${CM_SYNC_FETCH_TIMEOUT:-50}"; [ "$(left)" -ge "$FT" ] || FT="$(left)"; [ "$FT" -ge 1 ] || FT=1   # a fetch never outlives the budget
if ! cm_timeout "$FT" git -C "$REPO" fetch --quiet "$REMOTE" "$BRANCH" </dev/null 2>"$TMP/fetch.err"; then
  blocked fetch "cannot fetch $REMOTE/$BRANCH: $(head -c 140 "$TMP/fetch.err" 2>/dev/null | tr '\n|' '  ')"
fi
TIP="$(g rev-parse --verify --quiet "$REMOTE/$BRANCH^{commit}")" || blocked git "no $REMOTE/$BRANCH after the fetch"
HEAD_SHA="$(g rev-parse --verify --quiet "HEAD^{commit}")" || blocked git "this worktree has no commit"
[ "$HEAD_SHA" = "$TIP" ] && exit 0

BASE="$(g merge-base HEAD "$TIP" 2>/dev/null)" || BASE=""
BEHIND="$(g rev-list --count "HEAD..$TIP" 2>/dev/null || echo 0)"; AHEAD="$(g rev-list --count "$TIP..HEAD" 2>/dev/null || echo 0)"
CHANGED=0
if [ -n "$BASE" ]; then CHANGED="$(g diff --name-only "$BASE" "$TIP" -- "$SPATH" 2>/dev/null | grep -c . || true)"; fi
# level: nothing new upstream in the skill dir (also when only ahead, or behind on other paths)
[ "$BEHIND" -gt 0 ] && [ "$CHANGED" -gt 0 ] || exit 0

# a rebase, merge, cherry-pick, revert or bisect in progress: HEAD is mid-operation, a fast-forward now would corrupt it
for marker in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
  mp="$(g rev-parse --git-path "$marker" 2>/dev/null)"; [ -n "$mp" ] || continue
  case "$mp" in /*) ;; *) mp="$REPO/$mp" ;; esac
  if [ -e "$mp" ]; then blocked in-progress "a git operation is in progress here ($marker exists): finish or abort it by hand, never fast-forwarded under it"; fi
done
if [ "$AHEAD" -gt 0 ]; then blocked diverged "diverged from $REMOTE/$BRANCH (ahead $AHEAD) and $SPATH changed upstream ($CHANGED file(s)): rebase by hand, never forced"; fi
dirt="$(g status --porcelain --untracked-files=all 2>/dev/null | cm_status_dirt)"; dirt="${dirt%% *}"
if [ "${dirt:-0}" -gt 0 ]; then blocked dirty "worktree has $dirt uncommitted change(s) and $SPATH changed upstream ($CHANGED file(s)): commit or discard by hand, never forced"; fi

# ---- a lock in the way ----
holders() { # prints "pid:comm,..." of live processes holding the lock; "none"; or "unknown" when nothing can tell
  local out="" pid p="" root known=0 d l comm cwd cmd hit
  if command -v fuser >/dev/null 2>&1; then
    known=1; out="$(fuser "$LOCK" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' | tr '\n' ' ')"
    for pid in $out; do p="$p${p:+,}$pid:$(tr -d '\n' < "/proc/$pid/comm" 2>/dev/null || echo '?')"; done
  elif command -v lsof >/dev/null 2>&1; then
    known=1; out="$(lsof -t -- "$LOCK" 2>/dev/null | tr '\n' ' ')"
    for pid in $out; do p="$p${p:+,}$pid:$(tr -d '\n' < "/proc/$pid/comm" 2>/dev/null || echo '?')"; done
  fi
  root="$(cm_proc_root)"
  if compgen -G "$root/[0-9]*" >/dev/null 2>&1; then
    known=1
    # a process with the lock open: one find over every fd link (no per-process forks, the box may hold thousands)
    while IFS= read -r l; do
      pid="${l#"$root"/}"; pid="${pid%%/*}"
      case ",$p," in *",$pid:"*) ;; *) comm="?"; IFS= read -r comm < "$root/$pid/comm" 2>/dev/null; p="$p${p:+,}$pid:$comm" ;; esac
    done < <(find "$root"/[0-9]*/fd -maxdepth 1 -lname "$LOCK" 2>/dev/null)
    # any git process that works in this worktree (its cwd or its command line); comm is read with the builtin, no fork per pid
    for d in "$root"/[0-9]*; do
      comm=""; IFS= read -r comm < "$d/comm" 2>/dev/null || continue
      case "$comm" in git|git-*) ;; *) continue ;; esac
      pid="${d##*/}"; hit=0
      cwd="$(readlink "$d/cwd" 2>/dev/null)"; cmd="$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)"
      case "$cwd/" in "$REPO"/*) hit=1 ;; esac
      case "$cmd" in *"$REPO"*) hit=1 ;; esac
      if [ "$hit" = 1 ]; then case ",$p," in *",$pid:"*) ;; *) p="$p${p:+,}$pid:$comm" ;; esac; fi
    done
  fi
  if [ -n "$p" ]; then printf '%s' "$p"; elif [ "$known" = 1 ]; then printf none; else printf unknown; fi
}
if [ -e "$LOCK" ]; then
  size="$(wc -c < "$LOCK" 2>/dev/null | tr -d ' ')"; size="${size:-0}"
  mt="$(stat -c %Y "$LOCK" 2>/dev/null || stat -f %m "$LOCK" 2>/dev/null || echo 0)"; age=$(( $(date +%s) - mt )); [ "$age" -ge 0 ] || age=0
  hold="$(holders)"
  LOCKNOTE="lock=index.lock(age ${age}s,size ${size},holder=${hold})"
  why=""
  if [ "$size" -ne 0 ]; then why="not empty, so it may be a live git's work"
  elif [ "$age" -lt "$MINAGE" ]; then why="younger than ${MINAGE}s, a git command may be running"
  elif [ "$hold" != none ]; then why="holder is $hold"; fi
  if [ -n "$why" ]; then blocked index-lock "index.lock at $LOCK is $why: left alone, never deleted under a live git (age ${age}s, size ${size}, holder $hold)"; fi
  if [ "$DRY" -eq 1 ]; then printf 'cm-worktree-sync: dry-run would remove the stale empty %s (age %ss, no holder) and then fast-forward %s..%s behind=%s\n' "$LOCK" "$age" "${HEAD_SHA:0:12}" "${TIP:0:12}" "$BEHIND"; exit 0; fi
  # empty, old, nobody holds it: remove exactly that file
  if ! rm -f -- "$LOCK" 2>/dev/null || [ -e "$LOCK" ]; then blocked index-lock "stale empty index.lock at $LOCK could not be removed (age ${age}s)"; fi
  LOCKNOTE="lock=removed(age ${age}s)"
fi
if [ "$DRY" -eq 1 ]; then printf 'cm-worktree-sync: dry-run would fast-forward %s..%s behind=%s (%s file(s) under %s)\n' "${HEAD_SHA:0:12}" "${TIP:0:12}" "$BEHIND" "$CHANGED" "$SPATH"; exit 0; fi

# the budget: never START a fast-forward the caller's kill could cut in half (a killed checkout leaves a tree that reads as dirty)
if [ "$(left)" -lt "${CM_SYNC_MIN_FF:-20}" ]; then
  printf 'cm-worktree-sync: DEFERRED time budget (%ss of %ss left, a fast-forward needs %ss): nothing moved (behind=%s), the next tick retries\n' \
    "$(left)" "${CM_SYNC_BUDGET:-80}" "${CM_SYNC_MIN_FF:-20}" "$BEHIND"
  exit 0
fi
MT="${CM_SYNC_MERGE_TIMEOUT:-30}"; [ "$(left)" -ge "$MT" ] || MT="$(left)"
rc=0; cm_timeout "$MT" git -C "$REPO" merge --ff-only --quiet "$TIP" </dev/null >/dev/null 2>"$TMP/ff.err" || rc=$?
if [ "$rc" -ne 0 ]; then
  if [ "$rc" -eq 124 ]; then blocked ff-refused "fast-forward to ${TIP:0:12} timed out after ${MT}s: check git status in $REPO by hand"; fi
  blocked ff-refused "fast-forward to ${TIP:0:12} refused: $(head -c 160 "$TMP/ff.err" 2>/dev/null | tr '\n|' '  ')"
fi
printf 'cm-worktree-sync: ff %s..%s behind=%s%s | re-read %s/SKILL.md now (applies from the next tick)\n' "${HEAD_SHA:0:12}" "${TIP:0:12}" "$BEHIND" "${LOCKNOTE:+ $LOCKNOTE}" "$SPATH"
exit 0
