#!/usr/bin/env bash
# spawn-guard.sh: "no ticket, no spawn" (hard rule 30). The spawn path calls this BEFORE it
# creates any worktree or terminal; a non-zero exit means: spawn nothing.
#
#   scripts/spawn-guard.sh --issue <n> [--repo <owner/name>]
#
# Exit 0   the issue number is a positive integer and, when gh can be asked, the issue exists and is OPEN. When gh is missing or cannot be reached
#          (network, auth, timeout) the existence check is skipped with a `spawn-guard: unverified` warning on stderr
#          and the spawn goes on: an outage is not a verdict. A line `spawn-guard: ok issue #<n> ...` is printed.
# Exit 1   REFUSED, with the reason on stderr: no --issue (or an empty value), a value that is not a positive integer
#          (no leading zeros, no "#", no URL), gh answered that the issue does not exist in the repo, the number is a PULL
#          REQUEST (gh issue view answers for a PR number too; its url holds /pull/), or the issue is CLOSED or MERGED
#          (reopen it, or open a new ticket if this is new work: a ticket that is already finished is not a ticket to spawn on).
# Exit 2   bad usage: an unknown argument, or --issue / --repo without a value token.
#
# Why: workers and leads were started with no ticket, so work was duplicated and a worktree could not be traced to its
# issue. Look first (open and closed issues, worktrees, PRs), reuse what exists, open a ticket only when none does, then
# pass its number here. The spawn then links it in the fleet CLI (`worktree create --issue <n>`, and later `worktree set --pr <n>`).
#
# Repo: --repo, else CM_SPAWN_REPO, else $CM_ORG/$CM_REPO from config. Env: CM_GH_TIMEOUT (default 20 s per gh call).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

ISSUE=""; HAVE_ISSUE=0; REPO="${CM_SPAWN_REPO:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --issue) [ $# -ge 2 ] || { cm_warn "spawn-guard.sh: --issue needs a value"; exit 2; }; ISSUE="$2"; HAVE_ISSUE=1; shift ;;
    --repo)  [ $# -ge 2 ] && [ -n "$2" ] || { cm_warn "spawn-guard.sh: --repo needs owner/name"; exit 2; }; REPO="$2"; shift ;;
    -h|--help) sed -n '2,/^set -uo/{/^#/p;}' "$0"; exit 0 ;;
    *) cm_warn "spawn-guard.sh: unknown arg: $1"; exit 2 ;;
  esac
  shift
done

refuse() { cm_warn "spawn-guard: REFUSED, $*. No ticket, no spawn: find the existing issue (open and closed), worktree or PR first and reuse it; open a ticket only if none exists, then pass --issue <n>."; exit 1; }

[ "$HAVE_ISSUE" = 1 ] && [ -n "$ISSUE" ] || refuse "no issue number given (--issue is required)"
[[ "$ISSUE" =~ ^[1-9][0-9]{0,8}$ ]] || refuse "'$ISSUE' is not a positive issue number (digits only, no '#', no leading zero)"

[ -n "$REPO" ] || { [ -n "$CM_ORG" ] && [ -n "$CM_REPO" ] && REPO="$CM_ORG/$CM_REPO"; }
case "$REPO" in
  */*) ;;
  *) cm_warn "spawn-guard: unverified, no repo to ask gh about (set github.org and github.main_repo, or pass --repo): issue #$ISSUE accepted on its number alone"
     echo "spawn-guard: ok issue #$ISSUE (unverified)"; exit 0 ;;
esac
case "$REPO" in -*|*[!A-Za-z0-9._/-]*) cm_warn "spawn-guard.sh: odd repo name: $REPO"; exit 2 ;; esac

if ! command -v gh >/dev/null 2>&1; then
  cm_warn "spawn-guard: unverified, gh is not installed: issue #$ISSUE accepted on its number alone"
  echo "spawn-guard: ok issue #$ISSUE (unverified)"; exit 0
fi

ERR="$(mktemp "${TMPDIR:-/tmp}/cm-spawnguard.XXXXXX")" || { cm_warn "spawn-guard: unverified, cannot create a temp file"; echo "spawn-guard: ok issue #$ISSUE (unverified)"; exit 0; }
trap 'rm -f -- "${ERR:?}"' EXIT
rc=0
OUT="$(cm_timeout "${CM_GH_TIMEOUT:-20}" gh issue view "$ISSUE" --repo "$REPO" --json number,state,url </dev/null 2>"$ERR")" || rc=$?
if [ "$rc" -eq 0 ]; then
  STATE="$(printf '%s' "$OUT" | jq -r '.state // empty' 2>/dev/null)"
  NUM="$(printf '%s' "$OUT" | jq -r '.number // empty' 2>/dev/null)"
  if [ -z "$STATE" ] || [ "$NUM" != "$ISSUE" ]; then
    cm_warn "spawn-guard: unverified, gh answered something unreadable for #$ISSUE"
    echo "spawn-guard: ok issue #$ISSUE (unverified)"; exit 0
  fi
  URL="$(printf '%s' "$OUT" | jq -r '.url // empty' 2>/dev/null)"
  case "$URL" in
    */pull/*) refuse "#$ISSUE in $REPO is a pull request ($URL), not an issue: pass the ticket's issue number" ;;
  esac
  case "$STATE" in
    OPEN) ;;
    CLOSED|MERGED) refuse "issue #$ISSUE in $REPO is $STATE: reopen it, or open a new ticket if this is new work" ;;
    *) cm_warn "spawn-guard: unverified, gh answered an unknown state '$STATE' for #$ISSUE"
       echo "spawn-guard: ok issue #$ISSUE (unverified)"; exit 0 ;;
  esac
  echo "spawn-guard: ok issue #$ISSUE in $REPO ($STATE)"; exit 0
fi
# a failed call: only an explicit "no such issue" answer is a verdict; a timeout, auth or network error is not
if [ "$rc" -ne 124 ] && grep -qiE 'could not resolve to an issue|no issue found|issue .*not found|http 404|not found' "$ERR" 2>/dev/null; then
  refuse "issue #$ISSUE does not exist in $REPO"
fi
cm_warn "spawn-guard: unverified, gh could not be reached for #$ISSUE (rc=$rc $(head -c 120 "$ERR" 2>/dev/null | tr '\n' ' ')): accepted on its number alone"
echo "spawn-guard: ok issue #$ISSUE (unverified)"
exit 0
