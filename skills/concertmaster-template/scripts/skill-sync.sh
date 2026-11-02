#!/usr/bin/env bash
# skill-sync.sh: how a merged skill change reaches the LIVE concertmaster: the concertmaster worktree
# fast-forwards to the remote branch when that moved the skill directory. Why: a worktree that lags the
# branch means a merged fix does not run until someone pulls by hand.
#
#   scripts/skill-sync.sh [--dry-run] [--repo <dir>] [--path <skill dir in the repo>] [--remote origin] [--branch main]
#
# git fetch; then, when origin/main changed the skill directory since this worktree's merge base:
#   clean and strictly behind   git merge --ff-only origin/main (the same as `git pull --ff-only`, no second fetch),
#                               one lane-journal line, and the order to re-read SKILL.md
#   uncommitted tracked changes BLOCKED (exit 1), nothing touched
#   diverged (local commits)    BLOCKED (exit 1), nothing touched
#   fast-forward refused (an untracked file in the way) BLOCKED, nothing touched
#   directory unchanged, up to date, or only ahead   no-op (exit 0)
# Never force: no reset, no stash, no merge commit, no checkout. A BLOCKED run prints the line to carry in the
# concertmaster's own comment: `cm:blocked skill-sync <why>`. A pull in the middle of a tick applies from the NEXT
# tick; the running tick finishes on the text it already read.
#
# Where it looks, first match wins: the flag, then the environment, then config (`skill_sync:` keys), then the default.
#   --repo    CM_SKILL_SYNC_REPO    skill_sync.repo    the git worktree to keep current (default: the worktree holding this script)
#   --path    CM_SKILL_SYNC_PATH    skill_sync.path    the skill directory inside that repo, relative (default: the directory this script sits in)
#   --remote  CM_SKILL_SYNC_REMOTE  skill_sync.remote  default origin
#   --branch  CM_SKILL_SYNC_BRANCH  skill_sync.branch  default main
# Env: CM_GIT_TIMEOUT (default 60 s per git network call). Exit: 0 pulled or nothing to do; 1 blocked or git failed; 2 usage.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

DRY=0
REPO="${CM_SKILL_SYNC_REPO:-$(cm_cfg .skill_sync.repo)}"
SPATH="${CM_SKILL_SYNC_PATH:-$(cm_cfg .skill_sync.path)}"
REMOTE="${CM_SKILL_SYNC_REMOTE:-$(cm_cfg .skill_sync.remote origin)}"
BRANCH="${CM_SKILL_SYNC_BRANCH:-$(cm_cfg .skill_sync.branch main)}"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --repo) [ $# -ge 2 ] || { cm_warn "skill-sync.sh: --repo needs a directory"; exit 2; }; REPO="$2"; shift ;;
    --path) [ $# -ge 2 ] || { cm_warn "skill-sync.sh: --path needs a directory"; exit 2; }; SPATH="$2"; shift ;;
    --remote) [ $# -ge 2 ] || { cm_warn "skill-sync.sh: --remote needs a name"; exit 2; }; REMOTE="$2"; shift ;;
    --branch) [ $# -ge 2 ] || { cm_warn "skill-sync.sh: --branch needs a name"; exit 2; }; BRANCH="$2"; shift ;;
    -h|--help) sed -n '2,/^set -uo/{/^#/p;}' "$0"; exit 0 ;;
    *) cm_warn "skill-sync.sh: unknown arg: $1"; exit 2 ;;
  esac
  shift
done

if [ -z "$REPO" ]; then REPO="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null)" || { cm_warn "skill-sync.sh: not inside a git worktree"; exit 1; }; fi
[ -d "$REPO" ] || { cm_warn "skill-sync.sh: no such directory: $REPO"; exit 2; }
if [ -z "$SPATH" ]; then
  top="$(git -C "${REPO:-$HERE}" rev-parse --show-toplevel 2>/dev/null || true)"
  # the PHYSICAL path: run through the .claude/skills symlink, a logical path would make `git diff -- <path>` match nothing
  SPATH="$(cd "$HERE/.." && pwd -P)"; SPATH="${SPATH#"$(cd "$top" && pwd -P)"/}"
fi
case "$SPATH" in /*|*..*|'') cm_warn "skill-sync.sh: --path must be a relative directory inside the repo"; exit 2 ;; esac
case "$REMOTE$BRANCH" in *[!A-Za-z0-9._/-]*) cm_warn "skill-sync.sh: odd remote or branch name"; exit 2 ;; esac
# a name starting with "-" would be read by git as an option (--upload-pack runs a program): refuse it, and the remote must exist
case "$REMOTE" in -*) cm_warn "skill-sync.sh: the remote name must not start with '-'"; exit 2 ;; esac
case "$BRANCH" in -*) cm_warn "skill-sync.sh: the branch name must not start with '-'"; exit 2 ;; esac
git -C "$REPO" remote get-url -- "$REMOTE" >/dev/null 2>&1 || { cm_warn "skill-sync.sh: no such remote: $REMOTE"; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cm-skillsync.XXXXXX")" || { cm_warn "skill-sync.sh: cannot create a temp dir"; exit 1; }
trap 'rm -rf -- "${TMP:?}"' EXIT
g() { git -C "$REPO" "$@"; }
blocked() { echo "BLOCKED: cm:blocked skill-sync $*"; exit 1; }

if ! cm_timeout "${CM_GIT_TIMEOUT:-60}" git -C "$REPO" fetch --quiet "$REMOTE" "$BRANCH" </dev/null 2>"$TMP/fetch.err"; then
  why="$(head -c 160 "$TMP/fetch.err" 2>/dev/null | tr '\n' ' ')"
  blocked "cannot fetch $REMOTE/$BRANCH: ${why:-fetch failed}"
fi
TIP="$(g rev-parse --verify --quiet "$REMOTE/$BRANCH^{commit}")" || blocked "no $REMOTE/$BRANCH after the fetch"
HEAD_SHA="$(g rev-parse --verify --quiet "HEAD^{commit}")" || blocked "this worktree has no commit"

if [ "$HEAD_SHA" = "$TIP" ]; then echo "skill-sync: up to date at ${TIP:0:12}"; exit 0; fi
BASE="$(g merge-base HEAD "$TIP" 2>/dev/null)" || BASE=""
CHANGED=0
if [ -n "$BASE" ]; then CHANGED="$(g diff --name-only "$BASE" "$TIP" -- "$SPATH" | grep -c . || true)"; fi

if [ "$BASE" = "$TIP" ]; then
  echo "skill-sync: this worktree is ahead of $REMOTE/$BRANCH, nothing to pull"; exit 0
fi
if [ "$BASE" != "$HEAD_SHA" ]; then
  # diverged: local commits that origin does not have, and origin moved too
  ahead="$(g rev-list --count "$TIP..HEAD")"; behind="$(g rev-list --count "HEAD..$TIP")"
  if [ "$CHANGED" -eq 0 ]; then echo "skill-sync: diverged (ahead $ahead, behind $behind) but $SPATH is unchanged on $REMOTE/$BRANCH: no-op"; exit 0; fi
  blocked "diverged from $REMOTE/$BRANCH (ahead $ahead, behind $behind) and $SPATH changed upstream: rebase or reset by hand, never forced"
fi
# strictly behind from here
if [ "$CHANGED" -eq 0 ]; then echo "skill-sync: $SPATH unchanged on $REMOTE/$BRANCH (behind $(g rev-list --count "HEAD..$TIP") commits elsewhere): no-op"; exit 0; fi
dirty="$(g status --porcelain --untracked-files=no | grep -c . || true)"
if [ "$dirty" -gt 0 ]; then blocked "worktree has $dirty uncommitted tracked change(s) and $SPATH changed upstream ($CHANGED file(s)): commit or discard by hand, never forced"; fi
if [ "$DRY" -eq 1 ]; then echo "skill-sync: would fast-forward ${HEAD_SHA:0:12}..${TIP:0:12} ($CHANGED file(s) under $SPATH)"; exit 0; fi

if ! g merge --ff-only --quiet "$TIP" >/dev/null 2>"$TMP/ff.err"; then
  why="$(head -c 200 "$TMP/ff.err" 2>/dev/null | tr '\n' ' ')"
  blocked "fast-forward to ${TIP:0:12} refused: ${why:-unknown}"
fi
line="skill-sync: pulled ${HEAD_SHA:0:12}..${TIP:0:12} ($CHANGED file(s) under $SPATH); SKILL.md re-read, applies from the next tick"
echo "$line"
echo "skill-sync: re-read $SPATH/SKILL.md now"
jl="$("$HERE/lane-journal.sh" name "$CM_SELF_WORKTREE" 2>/dev/null)" || jl=""
if [ -n "$jl" ]; then "$HERE/lane-journal.sh" append "$jl" "$line" >/dev/null 2>&1 || cm_warn "skill-sync.sh: the journal line was not written"; fi
exit 0
