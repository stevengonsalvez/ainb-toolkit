#!/usr/bin/env bash
# teardown.sh: safe teardown of ONE worktree. Dry-run by default.
#
#   scripts/teardown.sh <host> <worktree-path>            # dry run: checks + plan
#   scripts/teardown.sh <host> <worktree-path> --apply    # act
#   add --allow-no-pr for an approved kill-list item that never had a PR
#   add --salvage to copy precious ignored files out before removal
#   add --close-handle <h> (repeatable) to allow closing that agent terminal
#   add --force-standing <ask-id> ONLY for a standing-lane removal the owner
#     approved: the ledger ask must be {kind:"remove-standing",
#     decision:"approved", state:"answered"} naming this host and this path
#     or a ledger worker on it, and not yet used (no usedAt)
#   add --accept-unmerged-beads <ask-id> ONLY when the owner approved leaving
#     this worktree's unmerged open beads behind (kind "accept-unmerged-beads",
#     same binding); it never overrides the epic gate
#   add --beads-unreadable-ok <reason> ONLY when bd cannot read this worktree's
#     beads store (for example a store on an older schema than the installed bd,
#     which prints a pending-schema-migrations error) and a human agreed. The
#     unreadable store is UNKNOWN, never clean; the refusal lists it as such and
#     names this flag. The flag excuses ONLY the failed bd read: every other beads
#     source (origin/<default>, the worktree and redirect files) is still read and
#     still gates, and every other gate, a dirty or unpushed tree included, still
#     refuses. It also needs --salvage: the WHOLE .beads dir is copied out to
#     ~/.concertmaster/salvage/<host>/<branch>-<ts>/beads-whole/ first (verified),
#     and the reason is logged to $CM_HOME/teardown-beads-unreadable.log. The flag
#     stays an explicit override, but it says what it overrode: the gate reads the
#     open beads on a migrated COPY of the store (see the schema paragraph under
#     OPEN BEADS below) and records the count it found in the check line and the
#     log (openBeads; null when the copy-read failed). It never migrates the live
#     store and never runs a bd write command on it (bd runs --readonly --sandbox
#     from /, as above). Ignored by --retire-check.
#   add --owner <lead-worktree> [--owner-host <host>] for LEAD MODE: a lead on ANY host tears
#     down its OWN child. <lead-worktree> is the lead's worktree name or absolute path, read with
#     `orca worktree list` on --owner-host (default local, the host the lead runs on). The child
#     must be listed in that lead's comment (a `cm:child <name>` line or its `WORKERS I OWN:`
#     list); an unlisted child is refused, and when another worktree's comment lists it the
#     refusal names that one. A child on ANOTHER host than the lead's must be listed as
#     `<name>@<host>` (`cm:child <name>@<host>`, or `WORKERS I OWN: <name>@<host>, ...`): a bare
#     name only matches a child on the lead's own host, so a remote child listed bare is refused
#     as "not listed". Every safety gate still runs (PR merged or closed, clean tree,
#     nothing unpushed, no live agent, no open bead, no open follow-up in its comment, salvage);
#     they go through the child's own git (ssh) and Orca with --environment <host>. A child that
#     owns a beads epic is declared on its line as `cm:child <name> epic=<bead-id>` (or with
#     --epic <bead-id>, repeatable): the epic gate then runs on those ids exactly as in
#     concertmaster mode; with none declared only the unmerged-beads check runs. NO ledger
#     is read or written (not even the host name check): the concertmaster tick reconciles the
#     ledger from the comments afterwards. A standing lane (a configured lane name, an ownership
#     lead, or a lane-shaped name: cm_lane_shaped in lib.sh) or the lead's own worktree is
#     refused here: that needs concertmaster mode and the owner-approved path. RIVAL SCAN: before
#     any teardown action the comment of every OTHER worktree on EVERY host is read with the same
#     claim reader as classify.jq (claims.jq: markers, negation and comment boundaries, whole names
#     only, never substrings); one that claims the child's name refuses, and so does an incomplete
#     census (a host failed, answered garbage, was offline or was cut off at the limit, or the
#     lead's row is not in it). The scan runs again on the re-run after the terminals are closed.
#     Nothing authenticates who runs --owner; the other gates still run. Not combined with
#     --force-standing, --accept-unmerged-beads or --retire-check.
#     --allow-no-pr with --owner is the NO-PR RETIREMENT of a child that never had a PR, and only
#     when ALL hold (any one missing refuses): the child is proven owned and not standing (above);
#     the first line of ITS OWN comment is an anchored `cm:retire <reason>` with a reason that has a
#     letter or digit; the branch has no PR of any state; its terminals are already
#     closed (none listed, none named with --close-handle); the tree is clean and nothing is
#     unpushed; it is zero commits ahead of origin/<default> fetched now (a failed fetch or an
#     unreadable count is UNKNOWN and refuses). Every beads, process, follow-up and salvage gate
#     still runs. With a merged or closed PR the flag changes nothing.
#   add --retire-check to run only the ledger, standing, beads and follow-up gates (the
#     guard before retiring a worker's agent terminal); never acts, and
#     refuses unless the path resolved and a live ledger worker matched
#
# <host> is "local" or an Orca environment name (as listed by `orca host list`).
# Remote git checks run over `ssh $(cm_ssh_target <host>)` (lib.sh: $CM_SSH_TARGET, else the ledger's hosts.<host>.sshTarget, else hostname when an address, else the host name),
# and the remote `hostname -s` must equal $CM_SSH_EXPECT_HOSTNAME (default:
# the ledger's hosts.<host>.hostname, else the host name). If ssh is
# unavailable or lands on the wrong machine the teardown is refused.
#
# The path is canonicalised first (realpath, then git --show-toplevel); every
# later check and the Orca row match use the canonical path. Remote paths must
# be absolute.
#
# Refuses (exit 3) when ANY of these hold:
#   - path is not the root of a git worktree, or is a repo's main checkout
#   - path is this script's own worktree, or the concertmaster worktree
#   - origin is not a repo of config github.org (or matches
#     github.exclude_repo_patterns)
#   - tree is dirty, or HEAD has commits on no remote (unpushed), or any git
#     check itself failed (a failed check is never read as clean). Untracked
#     bd runtime state (.beads.gate.lock, .beads/dolt.gate.lock, .beads/embeddeddolt[.gate.lock],
#     .beads/backup[.lock]) is not dirt. Untracked or ignored, it is always
#     precious: it refuses without --salvage and is copied out with it. On
#     --apply the untracked paths are deleted after the salvage and git status
#     must then be empty
#   - a rebase, merge, cherry-pick, revert or bisect in progress
#   - detached HEAD, unless ALL of these hold (a review worktree is detached on purpose, there is no branch to
#     look a PR up by, so "no PR (detached)" is reported and never counts as a merged-PR proof). Each is its
#     own check line (detach-*), any miss refuses, and a check that cannot run is UNKNOWN and refuses:
#       1. the first line of the child's OWN Orca comment is an anchored `cm:retire <reason>` (same source in
#          lead mode and concertmaster mode; a worktree with no Orca row has no request to read and is refused)
#       2. no tracked change and no untracked file
#       3. no precious ignored path unless --salvage copies AND verifies it (the salvage flow is unchanged)
#       4. no stash entry at all: stashes are shared per repo, not per worktree, so none can be told apart
#       5. after a fresh bounded `git fetch origin` (a failed or timed-out fetch refuses; nothing is pruned, the
#          branch must still be listed by `git ls-remote --heads origin`) the HEAD commit is
#          contained in a remote-tracking ref of origin; the plan line names it. Otherwise "HEAD is not on
#          any remote ref"
#       6. no rebase, merge, cherry-pick, revert or bisect in progress
#   - git-ignored files that are not regenerable noise (.env.local,
#     .agents/research, plans, handover, .keys/, ...): removal would
#     delete them silently. --salvage copies them to
#     ~/.concertmaster/salvage/<host>/<branch>-<ts>/ on that host first.
#     Noise ignored: node_modules, dist, build, .vite, coverage, .turbo, *.log,
#     and any name in config worktrees.regenerable_ignored (e.g. deno.lock)
#   - the branch has an OPEN PR
#   - the branch has no MERGED or CLOSED PR (override: --allow-no-pr, only for
#     items the owner approved on the first-boot kill list)
#   - Orca shows a live agent (working/waiting/permission) or child worktrees
#   - a terminal hosts an agent, or a non-shell process has its cwd in the
#     worktree, unless every such terminal is named with --close-handle (a leftover
#     codex process and its children are the exception to the PROCESS check only: --apply
#     stops them by pid; a terminal that still hosts an agent is closed with --close-handle)
#   - PROJECT: $CM_HOME/ledger.json belongs to another project (its `project` field is not this
#     project's id, or it has none and sits outside this project's state dir; cm_ledger_guard in
#     lib.sh). It is refused BEFORE any read of it, naming both projects. Never reached with --owner,
#     which reads no ledger.
#   - (concertmaster mode only, never with --owner) LEDGER: $CM_HOME/ledger.json is missing, empty, not an object with a
#     workers object, or its paths cannot be canonicalised on the host; or no
#     live ledger worker (state not gone/repurposed) matches this host and path
#     (canonical path or Orca worktreeId). No override: adopt it first.
#   - STANDING LANE, from the ledger only: any live worker on the path has
#     "standing": true or is a lanes.<lane>.lead. A "standing" that is not a
#     boolean on any live worker refuses as "standing state unknown". Names are
#     never used to allow or refuse (the owner's rule); a sweeper-looking name
#     with standing:false only prints a note. --force-standing <ask-id>
#     overrides this one refusal and never the beads gate.
#   - OPEN FOLLOW-UPS: the worker, or a worker whose parent chain leads to it, has an
#     open followUps[] row (scripts/followups.sh); same refusal style as the beads gate
#   - OPEN BEADS: any live worker has beadsEpic (a non-string refuses) and any
#     child bead is not closed. Only closed and tombstone count as closed;
#     deferred, pinned, blocked and the rest are open work. Children: dotted
#     ids <epic>.N and parent-child dependencies, recursively. Each bead's
#     state is its latest record (epoch compare, ties open) across every
#     source, all of which must read: origin/<default branch> after a fresh
#     bounded git fetch (the branch named by origin/HEAD must be a plain
#     branch name), the worktree's .beads/issues.jsonl, the live .beads dir a
#     .beads/redirect points at (it must resolve to this repo's main checkout
#     .beads; a redirect also requires bd), and bd when installed (run
#     read-only from /: bd -C <wt> --readonly --sandbox list --all --json;
#     "no beads database found" counts as absent only when bd where --json
#     names no database_path, no store is on disk, config.yaml sets nothing,
#     metadata.json names the default db and BEADS_DIR/BEADS_DB are unset;
#     every other bd failure, and a timeout (CM_BD_SECS, default 90 per bd
#     call, enforced on the host too), refuses).
#     A store bd cannot read because its schema is OLDER than the installed bd (bd prints an
#     Error line, opens nothing) is excused without any flag only when ALL hold: no tracked change
#     under .beads versus the merge-base with origin/<default> (no untracked bead file either;
#     bd runtime files do not count); a read of the store on a COPY lists 0 open beads; AND the
#     epic gate below (or, with no epic, the unmerged beads check) passes on the other sources.
#     The tracked diff alone proves nothing about open beads: they live in the git-ignored
#     embedded Dolt store, which is the very thing bd could not read. So the gate copies .beads
#     into a mktemp -d dir under $CM_HOME/tmp (never the live store), runs bd migrate schema on
#     the copy (CM_BD_MIGRATE_SECS, default 300), lists every bead on the copy (anything not
#     closed or tombstone counts as open work) and removes the copy again (only a path under
#     $CM_HOME/tmp/beads-copy.*). It refuses when any open bead is found or any step fails: a
#     .beads/redirect (the store is elsewhere), a symlink inside .beads, a migrate or list
#     error or timeout (a store bd cannot open on the copy included), a list that is not a
#     JSON array, a metadata.json that names a Dolt server, a config.yaml with any option beyond
#     issue-prefix (an allowlist), a bd that reports talking to a server, a bd whose store
#     resolves outside the copy, or a bd that CREATED a database in the copy (a store it did not
#     find would otherwise list 0). The copy's bd
#     runs with its own empty HOME (no user-level config), no BEADS_*/BD_* env, the copied
#     dolt backups and remotes cleared and the copy's *.jsonl emptied (so it counts what the
#     store holds, not a re-import of the tracked issues.jsonl). Only a clean read of 0
#     open beads excuses. The live store is never migrated and never written (recovery.md still
#     covers the manual backup plus migrate path). --beads-unreadable-ok <reason> stays for the
#     remaining unreadable cases.
#     An epic found nowhere, or an open epic with no children, refuses.
#     With no epic: refuses when the worktree holds open beads newer than in
#     every other source (unmerged bead work; --accept-unmerged-beads).
#
# Acts (with --apply), in order:
#   Orca-tracked:  orca terminal close per handle (never --all), then the
#                  script re-runs itself so every check, the beads read and
#                  the salvage happen with those terminals closed (any
#                  refusal then stops it, terminals closed, nothing removed)
#   both:          stop leftover codex processes whose cwd is inside the worktree (a codex
#                  app-server and its children; .agents/scratch dirs are inside it) by EXACT pid,
#                  children first: TERM, a bounded wait (CM_TD_PROC_WAIT, default 10s), then KILL
#                  for survivors, each pid re-checked just before it is signalled. Never by name,
#                  never pkill. The pids stopped are printed; a process that survives KILL fails
#                  the teardown before anything is removed
#   both:          salvage, then stop the worktree's local Supabase stack: `supabase stop
#                  --project-id <id>` for the id in its supabase/config.toml (or a container
#                  with a bind mount inside it), only when no other live worktree carries that
#                  id or a mount proves it is this one's; the shared default id is otherwise
#                  warned about and left running. No --no-backup (data volumes are kept). No
#                  docker, an unreadable docker or no supabase CLI is a warning, never a refusal
#   both:          delete the untracked bd runtime files
#                  (allow-listed paths only; each must be gone and git status
#                  empty, else stop with the salvage kept)
#   Orca-tracked:  orca worktree rm (no --force;
#                  Orca deletes the branch only when it can prove it merged)
#   git-only:      git worktree remove (no --force), then git branch -d only
#                  when GitHub says the PR MERGED; -D only when the local tip
#                  equals the merged PR's head sha
# The codex and Supabase stops are not undone when a later step refuses or fails (the beads read, the bd
# runtime cleanup, the Orca or git removal): the worktree then stays, its processes and stack already
# stopped. Both are safe to repeat and leave nothing that blocks a re-run.
# Then emits a worktree.teardown event via mc-emit.sh (fire and forget).
#
# Exit: 0 plan ok / done, 2 usage, 3 refused, 4 an apply step failed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"
# shellcheck source=SCRIPTDIR/fleet-read.sh
. "$HERE/fleet-read.sh"

# ledger_guard: the ledger at $CM_HOME/ledger.json must be this project's (cm_ledger_guard, lib.sh).
# Asked before EVERY ledger read below, once (memoised); a foreign ledger is never read: the
# hostname lookup is skipped and the ledger gate refuses (exit 3) with the reason, which names the
# project the ledger belongs to and the one running.
LEDGER_GUARD_RC=""; LEDGER_GUARD_MSG=""
ledger_guard() {
  if [ -z "$LEDGER_GUARD_RC" ]; then
    LEDGER_GUARD_MSG="$(cm_ledger_guard "$CM_HOME/ledger.json" 2>&1)"; LEDGER_GUARD_RC=$?
    # An accepted legacy ledger warns (once); a refusal is printed by the ledger gate.
    if [ "$LEDGER_GUARD_RC" = 0 ] && [ -n "$LEDGER_GUARD_MSG" ]; then printf '%s\n' "$LEDGER_GUARD_MSG" >&2; fi
  fi
  return "$LEDGER_GUARD_RC"
}

usage() { sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d'; exit 2; }
[ $# -ge 2 ] || usage
ORIG_ARGS=("$@")
HOST="$1"; WT="$2"; shift 2
MODE=dry-run
ALLOW_NO_PR=0
SALVAGE=0
FORCE_STANDING=""
ACCEPT_BEADS=""
BEADS_OK_RAW=""
RETIRE_CHECK=0
OWNER=""
OWNER_HOST=local
OWNER_MODE=0
OWNER_EPICS=""
CLOSE_HANDLES=" "
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) MODE=apply ;;
    --allow-no-pr) ALLOW_NO_PR=1 ;;
    --salvage) SALVAGE=1 ;;
    --force-standing|--accept-unmerged-beads)
      [ $# -ge 2 ] || usage
      case "$2" in ''|-*|*[!A-Za-z0-9._:-]*) cm_warn "$1 needs an ask id"; usage ;; esac
      if [ "$1" = --force-standing ]; then FORCE_STANDING="$2"; else ACCEPT_BEADS="$2"; fi
      shift ;;
    --beads-unreadable-ok)
      [ $# -ge 2 ] || { cm_warn "--beads-unreadable-ok needs a reason"; usage; }
      case "$2" in ''|-*) cm_warn "--beads-unreadable-ok needs a reason"; usage ;; esac
      BEADS_OK_RAW="$2"; shift ;;
    --retire-check) RETIRE_CHECK=1 ;;
    --owner)
      [ $# -ge 2 ] || { cm_warn "--owner needs the lead's worktree name or path"; usage; }
      case "$2" in ''|-*) cm_warn "--owner needs the lead's worktree name or path"; usage ;; esac
      OWNER="$2"; shift ;;
    --epic)
      [ $# -ge 2 ] || { cm_warn "--epic needs a bead id"; usage; }
      case "$2" in ''|-*|*[!A-Za-z0-9._-]*|.*) cm_warn "--epic needs a bead id"; usage ;; esac
      OWNER_EPICS="$OWNER_EPICS$2
"; shift ;;
    --owner-host)
      [ $# -ge 2 ] || { cm_warn "--owner-host needs a host"; usage; }
      case "$2" in ''|-*|*[[:space:]]*) cm_warn "--owner-host needs a host"; usage ;; esac
      OWNER_HOST="$2"; shift ;;
    --close-handle) [ $# -ge 2 ] || usage; CLOSE_HANDLES="$CLOSE_HANDLES$2 "; shift ;;
    --dry-run) MODE=dry-run ;;
    -h|--help) usage ;;
    *) cm_warn "unknown arg: $1"; usage ;;
  esac
  shift
done
IN="$WT"
if [ -n "$OWNER_EPICS" ] && [ -z "$OWNER" ]; then cm_warn "--epic is only for --owner (lead mode)"; usage; fi
if [ -n "$OWNER" ]; then
  OWNER_MODE=1
  if [ -n "$FORCE_STANDING" ] || [ -n "$ACCEPT_BEADS" ] || [ "$RETIRE_CHECK" -eq 1 ]; then
    cm_warn "--owner cannot be combined with --force-standing, --accept-unmerged-beads or --retire-check"; usage
  fi
fi
case "$OWNER_HOST" in "this machine") OWNER_HOST=local ;; esac
# The reason is logged and printed: printable subset only, bounded.
BEADS_OK_REASON="$(printf '%s' "$BEADS_OK_RAW" | tr -cd 'A-Za-z0-9 ._:,()/=#@-' | cut -c 1-200)"
if [ -n "$BEADS_OK_RAW" ] && [ -z "$(printf '%s' "$BEADS_OK_REASON" | tr -d ' ')" ]; then
  cm_warn "--beads-unreadable-ok needs a reason with letters or digits"; usage
fi
[ "$RETIRE_CHECK" -eq 0 ] || BEADS_OK_REASON=""
case "$HOST" in "this machine") HOST=local ;; esac
# Re-run after --apply closed the named terminals: they no longer exempt
# anything, so an agent terminal or process that survived the close refuses.
TERMS_CLOSED="${CM_TD_TERMINALS_CLOSED:-0}"
[ "$MODE" = apply ] || TERMS_CLOSED=0
[ "$TERMS_CLOSED" != 1 ] || CLOSE_HANDLES=" "

ORCA="$(cm_cli)" || exit 2
SSH_TARGET="$(cm_ssh_target "$HOST")"   # lib.sh: CM_SSH_TARGET, ledger sshTarget, a ledger hostname that is an address, else the host name
case "$SSH_TARGET" in
  -*|*[[:space:]]*|'') cm_warn "invalid ssh target: '$SSH_TARGET'"; exit 2 ;;
esac
REFUSALS=""
PLAN=""
refuse() {
  case "$REFUSALS" in *"  - $*
"*) return 0 ;; esac
  REFUSALS="${REFUSALS}  - $*
"
}
GATE_REFUSALS=""
# gate <reason>: a ledger, standing or beads refusal; also counts for --retire-check.
gate() {
  refuse "$@"
  case "$GATE_REFUSALS" in *"  - $*
"*) return 0 ;; esac
  GATE_REFUSALS="${GATE_REFUSALS}  - $*
"
}
plan() { PLAN="${PLAN}  $*
"; }
check() { printf '  %-14s %s\n' "$1" "$2"; }
UNPUSHED_DEFER=0  # commits on no known remote ref of a detached HEAD: judged again after the detached fetch
DETACHED=0     # 1 when HEAD is detached: judged by the detached HEAD section, after the Orca row is read
ROW=""         # the child's Orca row; set by the Orca state section
# origin_default_branch: the branch origin/HEAD names, else main. It is repo data: judge it with branch_name_ok.
origin_default_branch() {
  local b
  b="$(g symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  b="${b#origin/}"
  printf '%s' "${b:-main}"
}
# branch_name_ok <name>: a plain branch name that git cannot read as an option or a revision range.
branch_name_ok() {
  case "$1" in ''|-*|/*|*/|*//*|*..*|*.lock|*@\{*|*[!A-Za-z0-9._/-]*) return 1 ;; esac
  return 0
}
# dt_refuse <reason>: a detached HEAD refusal; also marks that one detached check failed (refuse() dedupes, so
# the refusal text itself is not a reliable signal).
DT_FAILED=0
dt_refuse() { DT_FAILED=1; refuse "$@"; }
# child_retire_request: the child's OWN Orca comment must START with an anchored `cm:retire <reason>` (the reason
# holds a letter or digit). Sets RETIRE_WHY and RETIRE_ST: ok, none (no such request), unreadable, norow.
child_retire_request() {
  RETIRE_WHY=""; RETIRE_ST=ok
  if [ -z "$ROW" ]; then RETIRE_ST=norow; return 0; fi
  # shellcheck disable=SC2016  # jq program
  if ! RETIRE_WHY="$(printf '%s' "$ROW" | jq -r -L "$HERE" 'include "comment-segs";
        (.comment | comment_segs | first // "") | capture("^cm:retire\\s+(?<r>.*)$") | .r | select(test("[A-Za-z0-9]"))' 2>/dev/null)"; then
    RETIRE_WHY=""; RETIRE_ST=unreadable
  elif [ -z "$RETIRE_WHY" ]; then
    RETIRE_ST=none
  fi
  return 0
}

# rrun <fixed-script> [args...]: run a FIXED bash script on the target host
# with every variable passed as a positional argument ($1, $2, ...). No path,
# branch or host value is ever spliced into script text: locally the args go
# straight to bash -c; over ssh each word is printf %q quoted, so the remote
# shell sees literals only. stdin is passed through. Over ssh the call is
# bounded by RRUN_SECS (default 20).
rrun() {
  local script="$1" line a
  shift
  if [ "$HOST" = local ]; then
    bash -c "$script" cm-rrun "$@"
  else
    line="bash -c $(printf '%q' "$script") cm-rrun"
    for a in "$@"; do line="$line $(printf '%q' "$a")"; done
    cm_timeout "${RRUN_SECS:-20}" ssh -o BatchMode=yes -o ConnectTimeout=8 -- "$SSH_TARGET" "$line"
  fi
}
# SALVAGE_VERIFY_FN: shell text prepended to the salvage copy scripts (rrun passes it with the
# script, so it also runs on a remote host). cm_same <source> <copy> succeeds only when the copy
# matches the source WITHOUT following symlinks: diff -rq follows a link and reports a false
# mismatch on a dangling one. Links are compared by target text (find -type l plus readlink,
# sorted, so a changed, missing or extra link is a mismatch); everything else by entry list and
# cmp per regular file. POSIX find, sort, readlink and cmp only: the same on GNU and BSD tools.
# The text holds no single quote, so it nests in a single-quoted script.
SALVAGE_VERIFY_FN='cm_links() { (cd -- "$1" && find . -type l | LC_ALL=C sort | while IFS= read -r l; do printf "%s\t%s\n" "$l" "$(readlink "$l")"; done); }
cm_ents() { (cd -- "$1" && find . ! -type l | LC_ALL=C sort); }
cm_same() {
  if [ -L "$1" ] || [ -L "$2" ]; then
    [ -L "$1" ] && [ -L "$2" ] && [ "$(readlink "$1")" = "$(readlink "$2")" ]
    return
  fi
  if [ -f "$1" ]; then [ -f "$2" ] && cmp -s "$1" "$2"; return; fi
  [ -d "$1" ] && [ -d "$2" ] || return 1
  cs_d=$(cd -- "$2" && pwd -P) || return 1
  cs_a=$(cm_links "$1") || return 1
  cs_b=$(cm_links "$cs_d") || return 1
  [ "$cs_a" = "$cs_b" ] || return 1
  cs_a=$(cm_ents "$1") || return 1
  cs_b=$(cm_ents "$cs_d") || return 1
  [ "$cs_a" = "$cs_b" ] || return 1
  (cd -- "$1" && find . -type f | while IFS= read -r f; do cmp -s "$f" "$cs_d/$f" || exit 1; done)
}
'
# g <git args...>: git in the worktree, locally or over ssh.
g() {
  if [ "$HOST" = local ]; then
    git -C "$WT" "$@"
  else
    # shellcheck disable=SC2016
    rrun 'd=$1; shift; exec git -C "$d" "$@"' "$WT" "$@"
  fi
}
# canon_paths: stdin paths -> "path<TAB>physical path" (empty when missing).
canon_paths() {
  # shellcheck disable=SC2016
  rrun 'while IFS= read -r p; do c=$(cd -- "$p" 2>/dev/null && pwd -P); printf "%s\t%s\n" "$p" "$c"; done'
}
# cm_safe_name <text>: one path component of [A-Za-z0-9._-] only, never . or ..
cm_safe_name() {
  local n
  n="$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
  case "$n" in ''|.|..|...) n="_$n" ;; esac
  printf '%s' "$n"
}
env_flag() { cm_cli_host "$HOST"; }
orca_cmd() {
  # orca_cmd <args...>: runs the CLI against the right host.
  local -a hsel
  cm_cli_host_into hsel "$HOST" || return 2
  cm_timeout 30 "$ORCA" "$@" ${hsel[@]+"${hsel[@]}"}
}

# Git-ignored file names the project regenerates (config
# worktrees.regenerable_ignored, e.g. deno.lock): never counted as precious.
REGEN_RE=""
for _rn in $(cm_cfg .worktrees.regenerable_ignored); do
  # shellcheck disable=SC2016
  REGEN_RE="$REGEN_RE|(^|/)$(printf '%s' "$_rn" | sed 's/[].[\*^$()+?{|]/\\&/g')\$"
done
# bd runtime paths (relative to the worktree root): the embedded Dolt store,
# its backups and the gate locks bd 1.3 takes around them. Keep in step with
# CM_IGNORE_UNTRACKED_DEFAULT in lib.sh (the census ignore list) and the allow-list in RM_BDRT_SCRIPT.
BD_RUNTIME_PATH_RE='^(\.beads\.gate\.lock|\.beads/dolt\.gate\.lock|\.beads/embeddeddolt\.gate\.lock|\.beads/backup\.lock|\.beads/(embeddeddolt|backup)(/.*)?)$'
BDRT=""

printf 'teardown %s on %s (%s)\n' "$IN" "$HOST" "$MODE"
printf 'checks:\n'

# ---- remote identity ---------------------------------------------------------
if [ "$HOST" != local ]; then
  EXPECT="${CM_SSH_EXPECT_HOSTNAME:-}"
  if [ -z "$EXPECT" ] && [ "$OWNER_MODE" -eq 0 ] && ledger_guard && [ -r "$CM_HOME/ledger.json" ]; then
    EXPECT="$(jq -r --arg h "$HOST" '.hosts[$h].hostname // empty' "$CM_HOME/ledger.json" 2>/dev/null)"
  fi
  # The configured hostname (hosts.per_host.<host>.hostname) is the next source; it is read in lead mode
  # too, where the ledger stays untouched. A host with none is expected to answer as its own alias.
  if [ -z "$EXPECT" ]; then
    EXPECT="$(printf '%s' "$CM_CFG_JSON" | jq -r --arg h "$HOST" '.hosts.per_host[$h].hostname // empty' 2>/dev/null || true)"
  fi
  EXPECT="${EXPECT:-$HOST}"
  GOT="$(rrun 'hostname -s 2>/dev/null || hostname' 2>/dev/null | head -n 1 | cut -d. -f1)"
  if [ "$(cm_lower "$GOT")" != "$(cm_lower "$EXPECT")" ]; then
    check ssh "$SSH_TARGET answered as '${GOT:-nothing}', expected '$EXPECT'"
    gate "ssh target is not host $HOST (set hosts.$HOST.hostname or CM_SSH_EXPECT_HOSTNAME)"
  else
    check ssh "$SSH_TARGET is $GOT"
  fi
  case "$IN" in /*) ;; *) gate "remote paths must be absolute: $IN" ;; esac
fi

# ---- canonical path ----------------------------------------------------------
GITOK=0
WT=""
REAL="$(printf '%s\n' "$IN" | canon_paths 2>/dev/null | cut -f2)"
if [ -z "$REAL" ]; then
  check path "NOT found: $IN"
  refuse "path does not exist on $HOST (or host unreachable)"
else
  TOP="$(WT="$REAL"; g rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -z "$TOP" ]; then
    check path "$REAL is not inside a git worktree"
    refuse "not a git worktree"
  elif [ "$TOP" != "$REAL" ]; then
    check path "$REAL is inside worktree $TOP, not its root"
    refuse "path is not a worktree root (did you mean $TOP?)"
  else
    WT="$REAL"
    GITOK=1
    check path "$WT"
  fi
fi

# Never the caller's own worktree, never the concertmaster's.
if [ "$GITOK" -eq 1 ]; then
  SELF_TOP="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ "$HOST" = local ] && [ -n "$SELF_TOP" ] && [ "$(cd "$SELF_TOP" && pwd -P)" = "$WT" ]; then
    refuse "this is the worktree running teardown.sh"
  fi
  if [ "${WT##*/}" = "$CM_SELF_WORKTREE" ]; then
    refuse "the concertmaster worktree is never torn down"
  fi
fi

if [ "$GITOK" -eq 1 ]; then
  GITDIR="$(g rev-parse --path-format=absolute --git-dir 2>/dev/null)"
  COMMON="$(g rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [ "$GITDIR" = "$COMMON" ]; then
    check worktree "MAIN checkout ($GITDIR)"
    refuse "main checkout: never torn down"
  else
    check worktree "linked worktree (common dir $COMMON)"
  fi
  MAINDIR="${COMMON%/.git}"

  URL="$(g remote get-url origin 2>/dev/null || true)"
  SLUG="$(cm_org_slug "$URL" || true)"
  if [ -z "$SLUG" ]; then
    check repo "NOT a $CM_ORG org repo ($URL)"
    refuse "origin is not a $CM_ORG repo: never touched"
  else
    check repo "$SLUG"
    # Lead mode proves ownership from a listing cut to ONE repo: the target must be a worktree of that repo too,
    # not just any repo of the organization whose worktree happens to carry the listed name.
    if [ "$OWNER_MODE" -eq 1 ] && [ -n "${CM_REPO:-}" ] && [ "$(cm_lower "${SLUG#*/}")" != "$(cm_lower "$CM_REPO")" ]; then
      refuse "lead mode tears down only $CM_REPO worktrees: this origin is $SLUG (a listing in the lead's comment names a worktree, not a repository)"
    fi
  fi

  # A failed check is UNKNOWN and refuses; it is never read as clean.
  # bd runtime state (the embedded Dolt store, its backups and gate locks) is
  # untracked on branches older than the .gitignore entries for it. Exactly
  # those untracked paths are not dirt: they join the ignored files below, so
  # they always refuse without --salvage and are copied out with it, and on
  # --apply they are deleted after the salvage so git sees a clean tree.
  # Anything else, and any tracked change to them, stays dirty.
  BD_RUNTIME_RE="^\\?\\? ${BD_RUNTIME_PATH_RE#^}"
  BDRT=""
  if ST="$(g --no-optional-locks status --porcelain 2>/dev/null)"; then
    BDRT="$(printf '%s\n' "$ST" | sed -n 's/^?? //p' | sed 's:/$::' | grep -E "$BD_RUNTIME_PATH_RE" || true)"
    DIRTY="$(printf '%s\n' "$ST" | grep -vE "$BD_RUNTIME_RE" | grep -c . || true)"
    if [ "$DIRTY" != 0 ]; then
      check dirty "YES ($DIRTY paths)"
      refuse "dirty tree ($DIRTY paths): save with git diff before anything"
    elif [ -n "$BDRT" ]; then
      check dirty "clean (untracked bd runtime only: $(printf '%s\n' "$BDRT" | tr '\n' ' '); always salvaged)"
    else
      check dirty "clean"
    fi
  else
    check dirty "UNKNOWN (git status failed)"
    refuse "git status failed: state unknown"
  fi

  if UNPUSHED="$(g rev-list --count HEAD --not --remotes 2>/dev/null)" && [ -n "$UNPUSHED" ]; then
    if [ "$UNPUSHED" != 0 ]; then
      # A detached HEAD (git's rc 1 for "not a symbolic ref") may sit on a remote branch this checkout has not
      # fetched yet, as a review worktree made from a PR head sha does: it is judged again after the fresh fetch
      # in the detached HEAD section, where the commit must be on a live remote ref. A branch is refused now.
      g symbolic-ref -q HEAD >/dev/null 2>&1; SYMREF_RC=$?
      if [ "$SYMREF_RC" -eq 1 ]; then
        UNPUSHED_DEFER="$UNPUSHED"
        check unpushed "$UNPUSHED commit(s) on no known remote ref (detached HEAD: judged again after the fresh fetch)"
      else
        check unpushed "YES ($UNPUSHED commits on no remote)"
        refuse "unpushed commits ($UNPUSHED)"
      fi
    else
      check unpushed "none"
    fi
  else
    check unpushed "UNKNOWN (git rev-list failed)"
    refuse "unpushed check failed: state unknown"
  fi

  # In-progress operations live in the per-worktree git dir.
  INPROG_ST=unknown
  # shellcheck disable=SC2016
  if ! INPROG="$(rrun 'cd -- "$1" 2>/dev/null || exit 3
for f in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do [ -e "$f" ] && printf "%s " "$f"; done
exit 0' "$GITDIR" 2>/dev/null)"; then
    check inprogress "UNKNOWN (cannot read git dir $GITDIR)"
    refuse "in-progress check failed: state unknown"
  elif [ -n "$INPROG" ]; then
    INPROG_ST=yes
    check inprogress "YES: $INPROG"
    refuse "git operation in progress ($INPROG): finish or abort it first"
  else
    INPROG_ST=none
    check inprogress "none"
  fi

  # Ignored files: worktree removal deletes them silently.
  PRECIOUS=""
  IGN_OK=0
  if IGN="$(g --no-optional-locks status --ignored --porcelain 2>/dev/null)"; then
    IGN_OK=1
    PRECIOUS="$(printf '%s\n' "$IGN" | sed -n 's/^!! //p' | sed 's/^"//; s/"$//; s:/$::' \
      | grep -vE "(^|/)(node_modules|dist|build|\\.vite|coverage|\\.turbo)(/|\$)|\\.log\$${REGEN_RE}" || true)"
    # Untracked bd runtime is precious like the ignored kind (never skipped).
    if [ -n "$BDRT" ]; then
      PRECIOUS="$(printf '%s\n%s\n' "$PRECIOUS" "$BDRT" | grep . || true)"
    fi
    if [ -z "$PRECIOUS" ]; then
      check ignored "only regenerable noise"
    else
      NPREC="$(printf '%s\n' "$PRECIOUS" | grep -c . || true)"
      check ignored "$NPREC precious: $(printf '%s\n' "$PRECIOUS" | head -n 5 | tr '\n' ' ')"
      if [ "$SALVAGE" -eq 0 ]; then
        refuse "ignored files would be deleted ($NPREC: $(printf '%s\n' "$PRECIOUS" | head -n 3 | tr '\n' ' ')): re-run with --salvage"
      fi
    fi
  else
    check ignored "UNKNOWN (git status --ignored failed)"
    refuse "ignored-file check failed: state unknown"
  fi

  HEADSHA="$(g rev-parse HEAD 2>/dev/null || true)"
  BRANCH="$(g symbolic-ref --short -q HEAD 2>/dev/null)"; BRANCH_RC=$?
  check branch "${BRANCH:-(detached)} at ${HEADSHA:0:12}"
  if [ -z "$BRANCH" ]; then
    # rc 1 is git's "not a symbolic ref" (detached); anything else is a failed check, never read as detached.
    # A detached HEAD is judged by the detached HEAD section below, once the Orca row (the cm:retire request) is read.
    if [ "$BRANCH_RC" -eq 1 ] && [ -n "$HEADSHA" ]; then
      DETACHED=1
    else
      [ "$UNPUSHED_DEFER" = 0 ] || refuse "unpushed commits ($UNPUSHED_DEFER)"
      refuse "branch check failed: HEAD is neither a branch nor a readable detached commit (state unknown)"
    fi
  fi
  case "$BRANCH" in */concertmaster|concertmaster) refuse "concertmaster branch: never torn down" ;; esac
fi

# ---- PR state --------------------------------------------------------------
MERGED_PR=""
MERGED_HEAD=""
CLOSED_PR=""
NOPR_LEAD=0   # 1 when lead mode uses --allow-no-pr because the branch really has no PR
if [ "$GITOK" -eq 1 ] && [ -n "${SLUG:-}" ] && [ -n "${BRANCH:-}" ]; then
  if PRS="$(cm_timeout 30 gh pr list -R "$SLUG" --head "$BRANCH" --state all --limit 10 \
            --json number,state,headRefOid 2>/dev/null)"; then
    OPEN="$(printf '%s' "$PRS" | jq -r '[.[] | select(.state == "OPEN") | "#\(.number)"] | join(" ")')"
    MERGED_PR="$(printf '%s' "$PRS" | jq -r '[.[] | select(.state == "MERGED")] | sort_by(.number) | last | .number // empty')"
    MERGED_HEAD="$(printf '%s' "$PRS" | jq -r '[.[] | select(.state == "MERGED")] | sort_by(.number) | last | .headRefOid // empty')"
    CLOSED_PR="$(printf '%s' "$PRS" | jq -r '[.[] | select(.state == "CLOSED")] | sort_by(.number) | last | .number // empty')"
    if [ -n "$OPEN" ]; then
      check pr "OPEN $OPEN"
      refuse "open PR $OPEN: hand it to pr-sweeper instead"
    elif [ -n "$MERGED_PR" ]; then
      check pr "#$MERGED_PR MERGED (head ${MERGED_HEAD:0:12})"
    elif [ -n "$CLOSED_PR" ]; then
      check pr "#$CLOSED_PR CLOSED (unmerged: branch kept)"
    elif [ "$ALLOW_NO_PR" -eq 1 ] && [ "$OWNER_MODE" -eq 1 ]; then
      check pr "none (--allow-no-pr, lead mode: needs the child's cm:retire request, see nopr below)"
      NOPR_LEAD=1
    elif [ "$ALLOW_NO_PR" -eq 1 ]; then
      check pr "none (--allow-no-pr: approved kill-list item)"
    else
      check pr "none"
      refuse "no merged/closed PR: needs --allow-no-pr after the owner approves"
    fi
  else
    check pr "UNKNOWN (gh failed)"
    refuse "could not read PR state from GitHub"
  fi
fi

# ---- Orca state ------------------------------------------------------------
ROW=""
TERMS_READ=0   # 1 only when the terminal list was read and parsed
if [ -z "$WT" ]; then
  check orca "skipped (no canonical path)"
elif PS="$(orca_cmd worktree ps --limit 500 --json 2>/dev/null)"; then
  # Match on the canonical path: every Orca row path is canonicalised on the
  # host too, so a relative or symlinked input cannot miss its row.
  MATCH="$(printf '%s' "$PS" | jq -r '.result.worktrees[]?.path // empty' | canon_paths 2>/dev/null \
           | CM_WT="$WT" awk -F '\t' '$2 == ENVIRON["CM_WT"] || $1 == ENVIRON["CM_WT"] { print $1; exit }')"
  if [ -n "$MATCH" ]; then
    ROW="$(printf '%s' "$PS" | jq -c --arg p "$MATCH" '[.result.worktrees[]? | select(.path == $p)][0] // empty')"
  fi
  if [ -z "$ROW" ]; then
    check orca "not tracked (git-only worktree)"
  else
    WID="$(printf '%s' "$ROW" | jq -r '.worktreeId')"
    LIVE="$(printf '%s' "$ROW" | jq -r '[.agents[]? | select(.state as $s | ["working","waiting","permission","blocked","running"] | index($s)) | "\(.agentType):\(.state)"] | join(" ")')"
    STATUS="$(printf '%s' "$ROW" | jq -r '.status // "?"')"
    KIDS="$(printf '%s' "$ROW" | jq -r '(.childWorktreeIds // []) | length')"
    TERMS="$(printf '%s' "$ROW" | jq -r '.liveTerminalCount // 0')"
    check orca "tracked $WID, status=$STATUS, terminals=$TERMS"
    if [ "$(printf '%s' "$ROW" | jq -r '.displayName // ""')" = "$CM_SELF_WORKTREE" ]; then
      refuse "the concertmaster worktree is never torn down"
    fi
    if [ -n "$LIVE" ] || [ "$STATUS" = working ] || [ "$STATUS" = permission ] || [ "$STATUS" = waiting ]; then
      check agents "LIVE ${LIVE:-status $STATUS}"
      refuse "live agent in worktree: read its pane first"
    fi
    if [ "$KIDS" != 0 ]; then
      check children "$KIDS child worktree(s)"
      refuse "has child worktrees: tear those down first"
    fi
    # Per-terminal: an agent terminal closes only when named via --close-handle.
    TLIST="$(orca_cmd terminal list --worktree "id:$WID" --json 2>/dev/null)" || TLIST=""
    if [ -z "$TLIST" ] || ! printf '%s' "$TLIST" | jq -e '.result.terminals | type == "array"' >/dev/null 2>&1; then
      check terminals "UNKNOWN (terminal list failed)"
      refuse "could not list terminals: state unknown"
      HANDLES=""
    else
      HANDLES="$(printf '%s' "$TLIST" | jq -r '.result.terminals[].handle')"
      TERMS_READ=1
      if [ "$TERMS_CLOSED" = 1 ] && [ -n "$HANDLES" ]; then
        refuse "terminal(s) still open after closing: $(printf '%s\n' "$HANDLES" | tr '\n' ' ')"
      fi
      for h in $HANDLES; do
        AG="$(printf '%s' "$TLIST" | jq -r --arg h "$h" '.result.terminals[] | select(.handle == $h) | .agentIdentity // empty')"
        case "$CLOSE_HANDLES" in *" $h "*) continue ;; esac
        [ -z "$AG" ] || refuse "terminal $h runs agent '$AG': pass --close-handle $h to close it"
      done
      check terminals "$(printf '%s' "$TLIST" | jq -r '[.result.terminals[] | "\(.handle)=\(.agentIdentity // "shell")"] | join(" ") | if . == "" then "none" else . end')"
    fi
  fi
else
  check orca "UNREACHABLE on $HOST"
  refuse "Orca host $HOST unreachable: host-offline, no teardown"
fi

# ---- detached HEAD -----------------------------------------------------------------
# A review worktree is created detached on purpose (a reviewer checks out a PR head sha), so there is no branch to
# look a PR up by: that is reported as "no PR (detached)" and never counts as a merged-PR proof. The commit itself
# is the proof instead. A detached HEAD is accepted ONLY when every check below holds, each on its own detach-*
# line (any miss refuses; a check that cannot run is UNKNOWN and refuses). A branch worktree never reaches this.
# Every other gate (live process, codex leftovers, terminals, owner listing, beads) runs as for any worktree.
DT_REFS=""
if [ "$GITOK" -eq 1 ] && [ "$DETACHED" -eq 1 ]; then
  check nopr "no PR (detached): no branch to look up, never a merged-PR proof; the commit on a remote ref is the proof"
  # 1. the child's own request, from the Orca row comment (the one source lead mode and concertmaster mode share)
  child_retire_request
  case "$RETIRE_ST" in
    ok) check detach-retire "cm:retire request: $(printf '%s' "$RETIRE_WHY" | tr -cd 'A-Za-z0-9 ._:,()/=#@-' | cut -c 1-120)" ;;
    norow)
      check detach-retire "no Orca row: no cm:retire request to read"
      dt_refuse "detached HEAD: needs the child's cm:retire request in its Orca comment, and this worktree has no Orca row" ;;
    unreadable)
      check detach-retire "UNKNOWN (the child's comment could not be read)"
      dt_refuse "detached HEAD: child comment unreadable, the cm:retire request cannot be proven" ;;
    none)
      check detach-retire "NO cm:retire request: the first line of the child's comment is not 'cm:retire <reason>'"
      dt_refuse "detached HEAD: needs the child's comment to start with 'cm:retire <reason>' (a reason with a letter or digit); a cm:retire later in the comment, or with a blank reason, does not count" ;;
    *)
      check detach-retire "UNKNOWN (retire state '$RETIRE_ST')"
      dt_refuse "detached HEAD: the cm:retire request state is unknown" ;;
  esac
  # 2. no tracked change, no untracked file (judged by the dirty check above; this line reports it for the detached path)
  if [ -z "${DIRTY:-}" ]; then
    check detach-clean "UNKNOWN (git status failed)"
    dt_refuse "detached HEAD: tree state unknown"
  elif [ "$DIRTY" != 0 ]; then
    check detach-clean "NO ($DIRTY changed or untracked paths)"
    dt_refuse "detached HEAD: the tree is not clean ($DIRTY changed or untracked paths)"
  else
    check detach-clean "no tracked change, no untracked file (bd runtime files count under detach-ignored)"
  fi
  # 3. nothing precious ignored unless the existing --salvage flow copies and verifies it
  if [ "$IGN_OK" -ne 1 ]; then
    check detach-ignored "UNKNOWN (git status --ignored failed)"
    dt_refuse "detached HEAD: ignored-file state unknown"
  elif [ -z "${PRECIOUS:-}" ]; then
    check detach-ignored "no precious ignored path (regenerable noise only)"
  else
    DT_NPREC="$(printf '%s\n' "$PRECIOUS" | grep -c . || true)"
    if [ "$SALVAGE" -eq 1 ]; then
      check detach-ignored "$DT_NPREC precious path(s), accepted only because --salvage copies and verifies them first"
    else
      check detach-ignored "$DT_NPREC precious path(s) and no --salvage"
      dt_refuse "detached HEAD: ignored files would be deleted ($DT_NPREC: $(printf '%s\n' "$PRECIOUS" | head -n 3 | tr '\n' ' ')): a detached worktree should hold nothing precious, re-run with --salvage to copy them out and verify the copy"
    fi
  fi
  # 4. no stash entry at all: refs/stash is shared by every worktree of the repo, so no entry can be told from this one's
  if DT_STASH="$(g stash list 2>/dev/null)"; then
    if [ -z "$DT_STASH" ]; then
      check detach-stash "none in the repo"
    else
      DT_NSTASH="$(printf '%s\n' "$DT_STASH" | grep -c . || true)"
      check detach-stash "$DT_NSTASH entr(y/ies) in the repo (stashes are shared per repo, not per worktree)"
      dt_refuse "detached HEAD: the repo has $DT_NSTASH stash entr(y/ies); stashes are shared per repo, not per worktree, so none can be proven not to hold this worktree's work: find out who owns them, never drop another session's stash, and keep this worktree until they are gone"
    fi
  else
    check detach-stash "UNKNOWN (git stash list failed)"
    dt_refuse "detached HEAD: stash state unknown"
  fi
  # 5. HEAD must sit on a remote-tracking ref of origin after a fresh fetch (bounded, never prompts), and that
  # branch must still exist on origin: a plain fetch keeps the tracking ref of a branch deleted there, so the live
  # branch list (git ls-remote --heads) is read in the same bounded call. Nothing is pruned: a dry run changes no
  # ref other than the ordinary fetch update. The fetch is skipped when an earlier detached check already refuses.
  # shellcheck disable=SC2016
  DT_FETCH_SCRIPT='GIT_TERMINAL_PROMPT=0 git -C "$1" fetch -q --no-tags -- origin || exit 1
GIT_TERMINAL_PROMPT=0 exec git -C "$1" ls-remote --heads origin'
  DT_LIVE=""; DT_FETCH=failed
  if [ "$DT_FAILED" -eq 1 ]; then
    DT_FETCH=skipped
  elif [ "$HOST" = local ]; then
    if DT_LIVE="$(cm_timeout 60 bash -c "$DT_FETCH_SCRIPT" cm-fetch "$WT" 2>/dev/null)"; then DT_FETCH=ok; fi
  elif DT_LIVE="$(RRUN_SECS=60 rrun "$DT_FETCH_SCRIPT" "$WT" 2>/dev/null)"; then
    DT_FETCH=ok
  fi
  if [ "$DT_FETCH" = skipped ]; then
    check detach-remote "not checked (an earlier detached check already refuses, so no fetch was made)"
  elif [ "$DT_FETCH" != ok ]; then
    check detach-remote "UNKNOWN (git fetch or ls-remote of origin failed or timed out)"
    dt_refuse "detached HEAD: the fetch of origin failed or timed out, so whether HEAD is on a remote ref is unknown"
  elif ! DT_ALL="$(g for-each-ref --contains "$HEADSHA" --format='%(refname)' refs/remotes/origin/ 2>/dev/null)"; then
    check detach-remote "UNKNOWN (git for-each-ref --contains failed)"
    dt_refuse "detached HEAD: could not test which remote refs hold HEAD (state unknown)"
  else
    # origin/HEAD is only an alias of a real branch, never a ref of its own. Only branches that still exist on
    # origin count. The default branch is named first, so the plan line reads the same however many topic branches
    # hold the commit.
    DT_DEFB="$(origin_default_branch)"
    branch_name_ok "$DT_DEFB" || DT_DEFB=main
    DT_LIVE_NAMES="$(printf '%s\n' "$DT_LIVE" | awk -F '\t' 'NF >= 2 { n = $2; sub(/^refs\/heads\//, "", n); print "origin/" n }')"
    DT_REFS="$(printf '%s\n' "$DT_ALL" | grep -v '/HEAD$' | sed 's:^refs/remotes/::' | grep . \
      | grep -Fx -f <(printf '%s\n' "$DT_LIVE_NAMES") \
      | awk -v d="origin/$DT_DEFB" '$0 == d { print; next } { rest[++n] = $0 } END { for (i = 1; i <= n; i++) print rest[i] }' || true)"
    if [ -n "$DT_REFS" ]; then
      DT_REF_NAMES="$(printf '%s\n' "$DT_REFS" | head -n 3 | tr '\n' ' ' | sed 's/ $//')"
      DT_NREFS="$(printf '%s\n' "$DT_REFS" | grep -c . || true)"
      [ "$DT_NREFS" -le 3 ] || DT_REF_NAMES="$DT_REF_NAMES (+$((DT_NREFS - 3)) more)"
      check detach-remote "HEAD ${HEADSHA:0:12} is on $DT_REF_NAMES (after a fresh fetch, branch still on origin)"
    else
      check detach-remote "HEAD ${HEADSHA:0:12} is on no live remote-tracking ref of origin (after a fresh fetch)"
      dt_refuse "detached HEAD: HEAD is not on any remote ref: push the commit or keep the worktree"
    fi
  fi
  # 6. no operation in progress (refused above by the inprogress check; reported here for the detached path)
  case "${INPROG_ST:-unknown}" in
    none) check detach-inprog "none" ;;
    yes)
      check detach-inprog "YES: ${INPROG:-?}"
      dt_refuse "detached HEAD: git operation in progress (${INPROG:-?})" ;;
    *)
      check detach-inprog "UNKNOWN (git dir unreadable)"
      dt_refuse "detached HEAD: in-progress state unknown" ;;
  esac
fi

# ---- processes with cwd in the worktree --------------------------------------
# Scan cwds on the host (lsof, else /proc) and map each process to its Orca
# terminal through the ORCA_TERMINAL_HANDLE in its environment (/proc environ
# on Linux, ps eww on macOS). A non-shell process is exempt ONLY when its
# handle was named with --close-handle; with no handle (started outside an
# Orca terminal, or the mapping failed) it always refuses.
# Leftover codex processes. A codex app-server (and the node or shell children it spawned) outlives its
# terminal and keeps burning CPU after the worktree is gone. They are found by cwd and by tree, never by
# name alone, and stopped by EXACT pid on --apply, before the worktree is removed:
#   - the process cwd is the worktree or below it (a path boundary match: /x/foo never matches /x/foo-bar;
#     a scratch dir under .agents/scratch is below the worktree, so it matches too), AND
#   - it is a codex process (argv[0] is `codex` or `codex.js`, or an interpreter such as node or sh with a
#     PATH to a file named `codex` or `codex.js` among its first arguments: a bare word `codex` after a
#     script, as in `bash run.sh codex`, is an argument and does not count) or a descendant of one.
# Order: deepest descendants first. TERM, a bounded wait (CM_TD_PROC_WAIT seconds, default 10), then KILL
# for the survivors, each pid re-checked (still alive, cwd still inside) just before it is signalled so a
# reused pid is never hit. Never pkill, never by name, never this script or any ancestor of it. Every other
# non-shell process in the worktree still refuses below.
# shellcheck disable=SC2016
CODEX_SNAP_SH='wt=$1
echo "S $$"
if [ -d /proc/self ]; then
  ls -l /proc/[0-9]*/cwd 2>/dev/null | awk -v wt="$wt" "{ i = index(\$0, \" /proc/\"); s = substr(\$0, i + 1); split(s, a, \"/\"); j = index(s, \" -> \"); if (j == 0) next; c = substr(s, j + 4); if (c == wt || index(c, wt \"/\") == 1) print \"C \" a[3] }"
elif command -v lsof >/dev/null 2>&1; then
  lsof -w -d cwd -Fpn 2>/dev/null | awk -v wt="$wt" "/^p/{p=substr(\$0,2)} /^n/{n=substr(\$0,2); if (n == wt || index(n, wt \"/\") == 1) print \"C \" p}"
else
  echo "NOSCAN"
fi
ps -eo pid=,ppid=,args= 2>/dev/null | awk "{p=\$1; q=\$2; sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, \"\"); print \"P \" p \" \" q \" \" \$0}"
echo END'
# codex_targets: sets CODEX_LINES (one "pid depth name" per line, deepest first, the order to signal) and
# CODEX_PIDS (the pids, space separated, same order). CODEX_OK=0 when the host could not be read.
codex_targets() {
  local snap
  CODEX_LINES=""; CODEX_PIDS=""; CODEX_OK=1
  if ! snap="$(RRUN_SECS=60 rrun "$CODEX_SNAP_SH" "$WT" 2>/dev/null)" || ! printf '%s\n' "$snap" | grep -qx 'END' || printf '%s\n' "$snap" | grep -qx 'NOSCAN'; then
    CODEX_OK=0; return 0
  fi
  CODEX_LINES="$(printf '%s\n' "$snap" | awk '
    function base(t) { sub(/.*\//, "", t); return t }
    function iscodex(a,   n, t, i, b0) {
      n = split(a, t, " "); b0 = base(t[1])
      if (b0 ~ /^codex(\.m?js)?$/) return 1
      if (b0 ~ /^(node|nodejs|sh|bash|dash|zsh|python|python3)$/) {
        for (i = 2; i <= n && i <= 8; i++) { if (t[i] ~ /\// && t[i] !~ /^-/ && base(t[i]) ~ /^codex(\.m?js)?$/) return 1 }
        return 0
      }
      return 0
    }
    function nm(a,   n, t, i, b0) {
      n = split(a, t, " "); b0 = base(t[1])
      if (b0 ~ /^(node|nodejs|sh|bash|dash|zsh|python|python3)$/) for (i = 2; i <= n && i <= 8; i++) { if (t[i] ~ /\// && t[i] !~ /^-/ && base(t[i]) ~ /^codex(\.m?js)?$/) return base(t[i]) }
      return b0
    }
    $1 == "S" { self = $2 }
    $1 == "C" { inside[$2] = 1 }
    $1 == "P" { pid = $2; par[pid] = $3; a = $0; sub(/^P [0-9]+ [0-9]+ ?/, "", a); args[pid] = a; ids[++n] = pid }
    END {
      for (i = 1; i <= n; i++) if (iscodex(args[ids[i]])) { depth[ids[i]] = 0; cx[ids[i]] = 1 }
      rounds = 0
      do { ch = 0; rounds++
        for (i = 1; i <= n; i++) { p = ids[i]
          if (par[p] in depth) { nd = depth[par[p]] + 1
            if (!(p in depth) || depth[p] < nd) { depth[p] = nd; ch = 1 } } }
      } while (ch && rounds < 64)   # depth is the real distance from the top codex, also for a codex under a codex
      for (p = self; p != "" && p != 0 && !(p in anc); p = par[p]) anc[p] = 1
      m = 0
      for (i = 1; i <= n; i++) { p = ids[i]
        if ((p in depth) && (p in inside) && !(p in anc)) { m++; tp[m] = p } }
      for (i = 1; i <= m; i++) for (j = i + 1; j <= m; j++)
        if (depth[tp[j]] > depth[tp[i]] || (depth[tp[j]] == depth[tp[i]] && tp[j] + 0 > tp[i] + 0)) { t = tp[i]; tp[i] = tp[j]; tp[j] = t }
      for (i = 1; i <= m; i++) print tp[i], depth[tp[i]], nm(args[tp[i]])
    }')"
  CODEX_PIDS="$(printf '%s\n' "$CODEX_LINES" | awk 'NF { printf "%s ", $1 }' | sed 's/ $//')"
}
CODEX_LINES=""; CODEX_PIDS=""; CODEX_OK=1
CODEX_WAIT="${CM_TD_PROC_WAIT:-10}"
case "$CODEX_WAIT" in ''|*[!0-9]*|0) CODEX_WAIT=10 ;; esac
if [ -n "$WT" ] && [ "$RETIRE_CHECK" -eq 0 ]; then   # --retire-check never acts, so it exempts nothing
  codex_targets
  if [ "$CODEX_OK" -eq 0 ]; then
    check codex "WARNING could not read the process list on $HOST: leftover codex processes not checked"
  elif [ -n "$CODEX_PIDS" ]; then
    check codex "leftover codex processes in the worktree, to stop by pid on --apply (children first): $(printf '%s\n' "$CODEX_LINES" | awk 'NF { printf "%s:%s ", $1, $3 }' | sed 's/ $//')"
  else
    check codex "no leftover codex process in the worktree"
  fi
fi

NONSHELL=""
if [ -n "$WT" ]; then
  # shellcheck disable=SC2016
  SCAN='wt=$1
handle_of() {
  if [ -r "/proc/$1/environ" ]; then
    tr "\000" "\n" < "/proc/$1/environ" 2>/dev/null | sed -n "s/^ORCA_TERMINAL_HANDLE=//p" | head -n 1
  else
    ps eww -o command= -p "$1" 2>/dev/null | tr " " "\n" | sed -n "s/^ORCA_TERMINAL_HANDLE=//p" | head -n 1
  fi
}
list() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -w -d cwd -Fpcn 2>/dev/null | CMWT="$wt" awk '"'"'BEGIN{wt=ENVIRON["CMWT"]} /^p/{p=substr($0,2)} /^c/{c=substr($0,2)} /^n/{n=substr($0,2); if (n == wt || index(n, wt "/") == 1) print p " " c}'"'"'
  elif [ -d /proc/self ]; then
    for d in /proc/[0-9]*; do c=$(readlink "$d/cwd" 2>/dev/null) || continue
      case "$c" in "$wt"|"$wt"/*) printf "%s %s\n" "${d#/proc/}" "$(cat "$d/comm" 2>/dev/null)" ;; esac
    done
  else
    echo "0 scan-unavailable"
  fi
}
list | while read -r pid comm; do printf "%s:%s:%s\n" "$pid" "$comm" "$(handle_of "$pid")"; done'
  EXEMPT=""
  if PROCS="$(rrun "$SCAN" "$WT" 2>/dev/null)"; then
    NONSHELL=""
    while IFS= read -r pl; do
      [ -n "$pl" ] || continue
      ph="${pl##*:}"; pc="${pl%:*}"; pc="${pc#*:}"
      case "$pc" in bash|zsh|sh|dash|fish|login|tmux|-bash|-zsh|-sh) continue ;; esac
      # a leftover codex process (or its child) is stopped by pid on --apply, so it does not block
      # unless it still belongs to a LIVE terminal of this worktree that --close-handle does not name: that is
      # a running session, not a leftover, and it refuses like any other process.
      case " $CODEX_PIDS " in *" ${pl%%:*} "*)
        if [ -z "$ph" ] || ! printf '%s\n' "${HANDLES:-}" | grep -qxF -- "$ph"; then continue; fi
        case "$CLOSE_HANDLES" in *" $ph "*) continue ;; esac ;;
      esac
      if [ -n "$ph" ]; then
        case "$CLOSE_HANDLES" in *" $ph "*) EXEMPT="$EXEMPT ${pl%%:*}:$pc@$ph"; continue ;; esac
      fi
      NONSHELL="$NONSHELL ${pl%%:*}:$pc@${ph:-no-terminal}"
    done <<EOF_PROCS
$PROCS
EOF_PROCS
  else
    NONSHELL="scan-failed"
  fi
  [ -z "$EXEMPT" ] || check processes "closing with named terminals:$EXEMPT"
  if [ -z "$NONSHELL" ]; then
    check processes "no other non-shell process"
  else
    check processes "BLOCKING:$NONSHELL"
    refuse "non-shell processes run in the worktree:$NONSHELL (stop them first)"
  fi
fi

# ---- local Supabase stack ------------------------------------------------------
# A worker that ran `supabase start` in this worktree leaves its containers running when the worktree
# goes: the stack is keyed by its project id (config.toml project_id; a --project-id the worker passed on the
# command line is not written anywhere teardown can read, so such a stack is left alone), not by the path. Before the worktree is removed, --apply runs `supabase stop --project-id
# <id>` for the stack that is provably this worktree's. The CLI labels every
# container `com.supabase.cli.project=<id>` and nothing more (no path label, named volumes, no bind
# mount into the worktree), so the id comes from (a) this worktree's supabase/config.toml and (b) any
# container with a bind mount inside this worktree (a path boundary match, kept for stacks that do
# have one). The checked-in default id is shared by every worktree that does not override it, so an id
# is stopped only when NO other live worktree (Orca rows and git worktrees of this repo, on this host)
# carries it and the list of them was read in full; a mount (b) never overrides that. Otherwise it is
# warned about and left running. Only containers
# labelled as a Supabase CLI project are ever looked at, and never by name. No docker, an unreadable
# docker, or no supabase CLI is a warning, never a refusal: the host may simply have none.
# Skipped with --retire-check (it never acts).
SB_STOP=""      # project ids to stop on --apply, one per line
SB_IDS_DESC=""  # "<id> (<n> containers)" for the plan, one per line
if [ -n "$WT" ] && [ "$RETIRE_CHECK" -eq 0 ]; then
  SB_PARTIAL=0
  # The git list is read on its own: a failed read (ssh blip, git error, lock) is a partial view, never an empty one.
  SB_GITLIST=""; SB_GITLIST="$(g worktree list --porcelain 2>/dev/null)" || SB_PARTIAL=1
  SB_OTHERS="$({ [ -z "${PS:-}" ] || printf '%s' "$PS" | jq -r '.result.worktrees[]?.path // empty' 2>/dev/null
                 printf '%s\n' "$SB_GITLIST" | sed -n 's/^worktree //p'; } \
               | canon_paths 2>/dev/null | CM_WT="$WT" awk -F '\t' '$2 != "" && $2 != ENVIRON["CM_WT"] { print $2 }' | sort -u)"
  [ -n "${PS:-}" ] || SB_PARTIAL=1   # no Orca list (the call failed): the other Orca worktrees are unknown
  [ -z "${PS:-}" ] || ! printf '%s' "$PS" | jq -e '(.result.truncated == true) or ((.result.totalCount // 0) > ((.result.worktrees // []) | length))' >/dev/null 2>&1 || SB_PARTIAL=1
  # This worktree is a linked one, so `git worktree list` always names at least the main checkout: an empty
  # list of OTHER worktrees means a source failed (ssh timeout, git error), and "nobody else has this id" can
  # not be proved from it.
  [ -n "$SB_OTHERS" ] || SB_PARTIAL=1
  SB_ARGS=("$WT")
  while IFS= read -r _p; do [ -z "$_p" ] || SB_ARGS+=("$_p"); done <<<"$SB_OTHERS"
  if SB_RAW="$(RRUN_SECS=60 rrun "$CM_SB_SCAN_SH" "${SB_ARGS[@]}" 2>/dev/null)" \
     && SB_JSON="$(printf '%s\n' "$SB_RAW" | cm_sb_parse 2>/dev/null)" && [ -n "$SB_JSON" ]; then
    SB_DOCKER="$(printf '%s' "$SB_JSON" | jq -r '.docker')"
    if [ "$SB_DOCKER" != ok ] || [ "$(printf '%s' "$SB_JSON" | jq -r '.complete')" != true ]; then
      case "$SB_DOCKER" in
        nodocker) check supabase "WARNING docker is not installed on $HOST: local Supabase stacks not checked" ;;
        *) check supabase "WARNING docker did not answer on $HOST (or the scan was cut off): local Supabase stacks not checked" ;;
      esac
    else
      SB_CANDS="$(printf '%s' "$SB_JSON" | jq -c --arg wt "$WT" '
        (.worktrees | map(select(.path == $wt)) | .[0].projectId // "") as $mine
        | (.worktrees | map(select(.path != $wt and .projectId != ""))) as $others
        | .stacks[] | . as $s
        | ($s.mounts | map(select(. == $wt or startswith($wt + "/"))) | length > 0) as $proven
        | select($proven or ($mine != "" and $s.projectId == $mine))
        | {id: $s.projectId, containers: $s.containers, proven: $proven,
           sharedWith: [$others[] | select(.projectId == $s.projectId) | .path]}')"
      if [ -z "$SB_CANDS" ]; then
        check supabase "no running Supabase stack for this worktree"
      else
        SB_HAVE_CLI=0; [ "$(printf '%s' "$SB_JSON" | jq -r '.supabaseCli')" != true ] || SB_HAVE_CLI=1
        while IFS= read -r sc; do
          [ -n "$sc" ] || continue
          sid="$(printf '%s' "$sc" | jq -r '.id')"; sn="$(printf '%s' "$sc" | jq -r '.containers')"
          sproven="$(printf '%s' "$sc" | jq -r '.proven')"; sshared="$(printf '%s' "$sc" | jq -r '.sharedWith | map(split("/") | last) | join(", ")')"
          if ! cm_sb_id_ok "$sid"; then
            check supabase "WARNING stack id '$sid' is not a plain project id: left running"
          elif [ "$sproven" = true ] && [ -z "$sshared" ] && [ "$SB_PARTIAL" -eq 0 ]; then
            if [ "$SB_HAVE_CLI" -eq 1 ]; then check supabase "stack $sid ($sn containers): a mount is inside this worktree, will stop"; SB_STOP="$SB_STOP$sid
"; SB_IDS_DESC="$SB_IDS_DESC$sid ($sn containers)
"
            else check supabase "WARNING stack $sid ($sn containers) is this worktree's but the supabase CLI is not on $HOST: left running"; fi
          elif [ -n "$sshared" ]; then
            check supabase "WARNING stack $sid ($sn containers) NOT stopped: the id is also the config id of live worktree(s) $sshared (a shared id is never stopped, a mount inside this worktree does not override that)"
          elif [ "$SB_PARTIAL" -eq 1 ]; then
            check supabase "WARNING stack $sid ($sn containers) NOT stopped: the worktree list was cut off, so another live worktree may use this id (a mount inside this worktree does not override that)"
          elif [ "$SB_HAVE_CLI" -eq 1 ]; then
            check supabase "stack $sid ($sn containers): config id of this worktree, no other live worktree has it, will stop"
            SB_STOP="$SB_STOP$sid
"; SB_IDS_DESC="$SB_IDS_DESC$sid ($sn containers)
"
          else
            check supabase "WARNING stack $sid ($sn containers) is this worktree's but the supabase CLI is not on $HOST: left running"
          fi
        done <<EOF_SBC
$SB_CANDS
EOF_SBC
      fi
    fi
  else
    check supabase "WARNING could not scan $HOST for local Supabase stacks (host unreachable or scan failed)"
  fi
fi

# ---- lead mode: ownership proof ----------------------------------------------
# --owner: the lead's own comment is the proof, read now with `orca worktree list` on the
# lead's host. No ledger. The child must be listed (cm:child <name> or WORKERS I OWN: ...).
owner_orca() {
  local -a hsel
  cm_cli_host_into hsel "$OWNER_HOST" || return 2
  cm_timeout 30 "$ORCA" "$@" ${hsel[@]+"${hsel[@]}"}
}
# A listing names the child as <name> (a child on the lead's own host) or <name>@<host> (any other host);
# it only proves ownership of the child on THAT host, so two same-named worktrees on different hosts are
# never confused. $th is the target child's host, $oh the lead's host (both "local" for this machine).
# shellcheck disable=SC2016  # jq program
OWNER_JQ='
def segs: (. // "") | tostring | gsub("\\\\n"; "\n")
  | [ split("\n")[] | split(" | ")[] | sub("^\\s+"; "") | sub("\\s+$"; "") | select(length > 0) ];
def hn: if . == "this machine" then "local" else . end;
def listed: [ segs[]
  | ( (capture("^cm:child\\s+(?<n>[^\\s,@]+)(?:@(?<h>[^\\s,]+))?") | {n, h}),
      (capture("^workers i own:\\s*(?<l>.*)$"; "i") | .l | split(",")[] | sub("^\\s+"; "")
        | capture("^(?<n>[^\\s(,@]+)(?:@(?<h>[^\\s(,]+))?") | {n, h}) )
  | .n + "@" + ((.h // $oh) | hn) ];
.result.worktrees as $rows
| [ $rows[] | select(.path == $owner or .displayName == $owner or ((.path // "") | split("/") | last) == $owner) ] as $o
| if ($o | length) != 1 then "no-owner \($o | length)"
  else $o[0] as $or
  | ([ $rows[] | select(.path != $or.path) | . as $r
        | select(any($names[]; . as $n | ($r.comment | listed) | index($n + "@" + $th))) | ($r.displayName // $r.path) ] | first) as $rival
  | if ($th == $oh) and ($or.path == $wt or any($names[]; . == ($or.displayName // ""))) then "self"
    elif any($names[]; . as $n | ($or.comment | listed) | index($n + "@" + $th)) then
      # the same name on the lead host more than once is not a proof of which one the lead owns
      if ($th == $oh) and ([ $rows[] | select(.path != $or.path) | . as $r
            | select(any($names[]; . == ($r.displayName // "")) or any($names[]; . == (($r.path // "") | split("/") | last)))
          ] | length) > 1 then "ambiguous"
      # another lead lists the same child too: two owners, so no lead may remove it alone (their epic=
      # restrictions differ, and with no ledger there is nowhere to merge them)
      elif $rival != null then "contested \($rival)"
      else "listed" end
    elif $rival != null then "elsewhere \($rival)"
    else "unlisted" end
  end'
# shellcheck disable=SC2016  # jq program
OWNER_EPIC_JQ='
def segs: (. // "") | tostring | gsub("\\\\n"; "\n")
  | [ split("\n")[] | split(" | ")[] | sub("^\\s+"; "") | sub("\\s+$"; "") | select(length > 0) ];
def hn: if . == "this machine" then "local" else . end;
.result.worktrees as $rows
| ([ $rows[] | select(.path == $owner or .displayName == $owner or ((.path // "") | split("/") | last) == $owner) ] | first) as $or
| [ ($or.comment | segs)[] | capture("^cm:child\\s+(?<n>[^\\s,@]+)(?:@(?<h>[^\\s,]+))?(?<r>.*)$")
    | select(.n as $x | $names | index($x))
    | select(((.h // $oh) | hn) == $th)
    | .r | scan("(?:^|\\s)epic=([A-Za-z0-9._-]+)") | .[0] ] | unique[]'
# ---- lead mode: cross-host rival-claim scan -----------------------------------
# One lead's listing proves ownership only if no OTHER worktree, on ANY host, claims the same child name. The
# claim reader is claims.jq, the one classify.jq uses (markers from config ownership.comment_markers plus the two
# that lead mode itself reads, cm:child and "workers i own"; negation, comment boundaries, whole names only, never
# substrings). Every worktree comment of the project on every host is read through cm_fleet_worktrees
# (fleet-read.sh); the lead's own row and the child's row are skipped. The census must be COMPLETE: the host
# list, every host's worktree list and the lead's row must all have been read, none cut off at the limit.
# rival_scan sets RIVAL_MSG and returns 0 (no rival, census complete), 1 (a rival claims the name) or 2 (the
# census is incomplete or unreadable, so absence of a rival proves nothing).
RIVAL_MSG=""
# shellcheck disable=SC2016  # jq program
RIVAL_JQ='include "claims";
def isowner: $h == $oh and (.path == $owner or .displayName == $owner or ((.path // "") | split("/") | last) == $owner);
def ischild: $h == $th and (.path == $wt or ($wid != "" and .worktreeId == $wid));
.result.worktrees[]
| if isowner then "owner"
  elif ischild then empty
  else . as $r
    | claims(($r.comment | if type == "string" then . else "" end); $mk; $stop; $names) as $c
    | select(($c | length) > 0)
    | "rival:\($r.displayName // $r.path // "?" | tostring | gsub("[\\n\\t]"; " "))"
  end'
rival_scan() {
  local d rc
  RIVAL_MSG=""
  d="$(mktemp -d "${TMPDIR:-/tmp}/cm-rival.XXXXXX" 2>/dev/null)" || d=""
  if [ -z "$d" ] || [ ! -d "$d" ]; then RIVAL_MSG="cannot create a temp dir for the census"; return 2; fi
  rival_read "$d"; rc=$?
  rm -rf -- "${d:?}"
  return "$rc"
}
rival_read() {
  local d="$1" f h out rc gaps hosts nowner=0 rivals=""
  cm_fleet_worktrees "$d"
  if [ -s "$d/unreach.ndjson" ]; then
    gaps="$(jq -r '"\(.host // "?"): \(.error // "?")"' "$d/unreach.ndjson" 2>/dev/null | head -n 3 | tr '\n' ';')"
    RIVAL_MSG="the census of all hosts is incomplete (${gaps:-unreadable})"; return 2
  fi
  hosts="$(jq -r '.host' "$d/hosts.ndjson" 2>/dev/null | tr '\n' ' ')"
  case " $hosts " in *" $HOST "*) ;; *) RIVAL_MSG="host $HOST is not in the census (read: ${hosts:-none})"; return 2 ;; esac
  case " $hosts " in *" $OWNER_HOST "*) ;; *) RIVAL_MSG="the lead's host $OWNER_HOST is not in the census (read: ${hosts:-none})"; return 2 ;; esac
  while IFS="$(printf '\t')" read -r h f; do
    [ -n "$f" ] || continue
    out="$(jq -r -L "$HERE" --arg h "$h" --arg oh "$OWNER_HOST" --arg th "$HOST" --arg wt "$WT" --arg wid "${WID:-}" --arg owner "$OWNER" \
          --argjson names "$NAMES_LC" --argjson mk "$RIVAL_MK" --argjson stop "$RIVAL_STOP" "$RIVAL_JQ" "$f" 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ]; then RIVAL_MSG="the comments on $h could not be read"; return 2; fi
    nowner=$((nowner + $(printf '%s\n' "$out" | grep -c '^owner$' || true)))
    rivals="$rivals$(printf '%s\n' "$out" | grep '^rival:' | cut -c 7- | while IFS= read -r r; do printf ' %s@%s' "$r" "$h"; done)"
  done < <(jq -r '[.host, .file] | @tsv' "$d/hosts.ndjson")
  if [ "$nowner" -lt 1 ]; then RIVAL_MSG="the lead '$OWNER' has no row in the census of $OWNER_HOST"; return 2; fi
  if [ -n "$rivals" ]; then RIVAL_MSG="claimed by${rivals}"; return 1; fi
  return 0
}

if [ "$OWNER_MODE" -eq 1 ] && [ -n "$WT" ]; then
  NAMES="$(jq -cn --arg a "${WT##*/}" --arg b "$([ -z "$ROW" ] || printf '%s' "$ROW" | jq -r '.displayName // ""')" \
          '[$a, $b] | map(select(. != "")) | unique')"
  NAMES_LC="$(printf '%s' "$NAMES" | jq -c 'map(ascii_downcase) | unique')"
  # markers and stop words for the rival scan: the configured ones, then the two lead mode reads itself.
  RIVAL_MK="$(printf '%s' "${CM_CFG_JSON:-}" | jq -c '((.ownership.comment_markers // []) | map(select(type == "string" and length > 0))) as $m
        | $m + (["cm:child", "workers i own"] | map(select(. as $x | ($m | map(ascii_downcase) | index($x)) == null)))' 2>/dev/null)" || RIVAL_MK=""
  [ -n "$RIVAL_MK" ] || RIVAL_MK='["cm:child","workers i own"]'
  RIVAL_STOP="$(printf '%s' "${CM_CFG_JSON:-}" | jq -c '(.ownership.comment_stop_words // []) | map(select(type == "string" and length > 0))' 2>/dev/null)" || RIVAL_STOP=""
  [ -n "$RIVAL_STOP" ] || RIVAL_STOP='[]'
  # Only this project's worktrees can prove ownership: the lead list is cut to the configured Orca repo, so a
  # lead of another project on the same host never authorizes a teardown here.
  OREPO="${CM_ORCA_REPO:-$(cm_cfg .worktrees.orca_repo)}"
  OLARGS=(worktree list --json --limit 500)
  [ -z "$OREPO" ] || OLARGS+=(--repo "name:$OREPO")
  if ! OL="$(owner_orca "${OLARGS[@]}" 2>/dev/null)" \
     || ! printf '%s' "$OL" | jq -e '.result.worktrees | type == "array"' >/dev/null 2>&1; then
    check owner "UNREACHABLE: cannot read the lead's comment on $OWNER_HOST"
    refuse "owner host $OWNER_HOST unreachable or its worktree list unreadable: ownership unproven, nothing torn down"
  elif printf '%s' "$OL" | jq -e '.result.truncated == true or ((.result.totalCount // 0) > (.result.worktrees | length))' >/dev/null 2>&1; then
    check owner "INCOMPLETE: the worktree list on $OWNER_HOST was cut off"
    refuse "the worktree list on $OWNER_HOST was truncated: the lead and the child's name cannot be proven unique, ownership unproven"
  else
    OV="$(printf '%s' "$OL" | jq -r --arg owner "$OWNER" --arg wt "$WT" --arg th "$HOST" --arg oh "$OWNER_HOST" --argjson names "$NAMES" "$OWNER_JQ" 2>/dev/null)" || OV="error"
    case "$OV" in
      listed) check owner "listed in the comment of $OWNER on $OWNER_HOST"
            # The listing names a child, not a path: if two worktrees on the CHILD's host carry that name,
            # the lead has not said which it owns, so nothing is torn down (the lead host was checked above).
            if printf '%s' "${PS:-}" | jq -e '.result.truncated == true or ((.result.totalCount // 0) > (.result.worktrees | length))' >/dev/null 2>&1; then
              check owner "INCOMPLETE: the worktree census on $HOST was cut off"
              refuse "the worktree census on $HOST was truncated: the child's name cannot be proven unique there, ownership unproven"
            fi
            AMB="$(printf '%s' "${PS:-}" | jq -r --argjson names "$NAMES" '[.result.worktrees[]? | . as $r
                  | select(any($names[]; . == ($r.displayName // "")) or any($names[]; . == (($r.path // "") | split("/") | last)))] | length' 2>/dev/null)" || AMB=0
            case "${AMB:-0}" in ''|*[!0-9]*) AMB=0 ;; esac
            # The census lists Orca-tracked worktrees only. A target with no row of its own (git-only) whose name a
            # tracked worktree already carries is a different worktree: the lead's listing cannot be this one.
            if [ -z "$ROW" ] && [ "$AMB" -ge 1 ]; then AMB=$((AMB + 1)); fi
            if [ "$AMB" -gt 1 ]; then
              check owner "AMBIGUOUS: $AMB worktrees on $HOST have this name"
              refuse "more than one worktree on $HOST is named like '$WT' ($AMB): the lead's listing does not say which it owns (use a unique name)"
            fi
            # Rival scan across ALL hosts (see rival_scan above): a claim by another lead, or an incomplete
            # census, refuses before any terminal is closed or anything is removed.
            rival_scan; RV=$?
            case "$RV" in
              0) check rival "no other worktree on any host claims this name (census complete)" ;;
              1) check rival "RIVAL: $RIVAL_MSG"
                 refuse "$HOST:$WT is also claimed by another lead on ${RIVAL_MSG#claimed by }: two owners, so no lead removes it alone (make one cm:child line, or let the concertmaster decide)" ;;
              *) check rival "UNKNOWN: $RIVAL_MSG"
                 refuse "cannot rule out a rival claim on '${WT##*/}' on another host: $RIVAL_MSG (nothing torn down)" ;;
            esac
            # An epic the child owns is declared on its cm:child line as epic=<id> (or with --epic): lead
            # mode has no ledger beadsEpic, so the epic gate below runs on exactly those ids.
            OWNER_EPICS="$OWNER_EPICS$(printf '%s' "$OL" | jq -r --arg owner "$OWNER" --arg th "$HOST" --arg oh "$OWNER_HOST" --argjson names "$NAMES" "$OWNER_EPIC_JQ" 2>/dev/null)
" ;;
      contested*) check owner "CONTESTED: also listed by ${OV#contested }"
            refuse "$HOST:$WT is listed by both '$OWNER' and '${OV#contested }': two owners, so no lead removes it alone (make one cm:child line, or let the concertmaster decide)" ;;
      ambiguous) check owner "AMBIGUOUS: more than one worktree on $OWNER_HOST has this name"
            refuse "more than one worktree on $OWNER_HOST is named like '$WT': the lead's listing does not say which it owns (use a unique name)" ;;
      self) check owner "the child IS the lead's own worktree"
            refuse "--owner $OWNER is this worktree: a lead is never torn down in lead mode" ;;
      no-owner*) check owner "lead $OWNER not found (or ambiguous) on $OWNER_HOST"
            refuse "lead worktree '$OWNER' not found, or not unique, on $OWNER_HOST: ownership unproven" ;;
      elsewhere*) check owner "NOT listed by $OWNER; listed by ${OV#elsewhere }"
            refuse "$HOST:$WT is not in the comment of '$OWNER' (cm:child / WORKERS I OWN); it is listed by '${OV#elsewhere }': that lead tears it down" ;;
      unlisted) check owner "NOT listed in the comment of $OWNER"
            refuse "$HOST:$WT is not listed in the comment of '$OWNER' (no cm:child line, not in WORKERS I OWN): refused" ;;
      *) check owner "UNKNOWN (could not evaluate the lead's comment)"
            refuse "could not evaluate the lead's comment on $OWNER_HOST: ownership unproven" ;;
    esac
  fi
fi


# ---- ledger -------------------------------------------------------------------
# The ledger is the only source of standing and beadsEpic. Every way it can be
# missing, malformed or silent about this worktree refuses (fail closed).
LEDGER="$CM_HOME/ledger.json"
LW=""          # merged view of the live ledger workers on this host + path
LEDGER_OK=0
if [ "$OWNER_MODE" -eq 1 ]; then
  check ledger "not used (--owner: no ledger is read or written; the concertmaster reconciles it from comments)"
elif [ -n "$WT" ]; then
  if ! ledger_guard; then
    check ledger "REFUSED (not this project's ledger, not read)"
    gate "${LEDGER_GUARD_MSG#concertmaster: }"
  elif [ ! -s "$LEDGER" ]; then
    check ledger "MISSING or empty ($LEDGER)"
    # The ledger lives only on the concertmaster host. A lead running this anywhere else lands here,
    # so the refusal names the way through: ask the concertmaster, do not hunt for a ledger.
    gate "ledger missing or empty: standing and beads state unknown. Backup ring: $(CM_LEDGER="$LEDGER" cm_ledger_bak_dir)/ (newest copy is the ledger before the last write). Restore: $(CM_LEDGER="$LEDGER" cm_ledger_restore_hint)"
    gate "not the concertmaster host? The ledger exists only there; do not copy or build one here. A lead tears down its own child from ANY host with: teardown.sh $HOST $WT --owner <your-worktree> (add --owner-host <host> when you run on another host; plan first, then --apply). Only a lead that cannot reach the child's host posts cm:retire on the child's comment as a fallback request; the concertmaster then runs teardown.sh from its host."
  elif ! jq -se 'length == 1 and (.[0] | type == "object" and ((.workers // null) | type) == "object")' "$LEDGER" >/dev/null 2>&1; then
    check ledger "UNKNOWN ($LEDGER is not an object with a workers object)"
    gate "ledger unreadable or malformed: standing and beads state unknown"
  elif ! CANDS="$(jq -r --arg h "$HOST" '.workers | to_entries[]
          | select(.value | type == "object")
          | select(.value.host == null or .value.host == $h)
          | select(((.value.state // "") | IN("gone", "repurposed")) | not)
          | "\(.value.path // "")\t\(.key)\t\(.value.worktreeId // "")"' "$LEDGER" 2>/dev/null)"; then
    check ledger "UNKNOWN (jq could not read $LEDGER)"
    gate "ledger unreadable: standing and beads state unknown"
  else
    LIDS=""
    LMATCH_OK=1
    if [ -n "$CANDS" ]; then
      # canon_paths answers one line per input line, in order; a failure or a
      # short answer is UNKNOWN, never "no worker for this path".
      if CANON="$(printf '%s\n' "$CANDS" | cut -f1 | canon_paths 2>/dev/null)" \
         && [ "$(printf '%s\n' "$CANON" | grep -c '')" = "$(printf '%s\n' "$CANDS" | grep -c '')" ]; then
        LIDS="$(paste "/dev/fd/3" "/dev/fd/4" 3<<EOF_C 4<<EOF_K | CM_WT="$WT" CM_IN="$IN" CM_WID="${WID:-}" awk -F '\t' \
          '($1 != "" && ($1 == ENVIRON["CM_WT"] || $1 == ENVIRON["CM_IN"] || $5 == ENVIRON["CM_WT"])) || ($3 != "" && $3 == ENVIRON["CM_WID"]) { print $2 }'
$CANDS
EOF_C
$CANON
EOF_K
)"
      else
        LMATCH_OK=0
        check ledger "UNKNOWN (could not canonicalise ledger paths on $HOST)"
        gate "ledger path match failed on $HOST: standing and beads state unknown"
      fi
    fi
    if [ "$LMATCH_OK" -eq 1 ]; then
      if [ -z "$LIDS" ]; then
        check ledger "no live worker for this path"
        gate "standing state unknown: no live ledger worker for $HOST:$WT (adopt it with standing true or false first)"
      elif LW="$(printf '%s\n' "$LIDS" | jq -R . | jq -cs --slurpfile L "$LEDGER" '
              (. | unique) as $ids | $L[0] as $r
              | [ $ids[] as $k | $r.workers[$k] + {id: $k} ] as $ws
              | [ ($r.lanes // {})[]? | .lead? // empty ] as $leads
              | { ids: [ $ws[].id ],
                  standingTrue: [ $ws[] | select(.standing == true) | .id ],
                  standingUnknown: [ $ws[] | select((.standing | type) != "boolean") | .id ],
                  lead: [ $ws[].id as $k | $k | select($leads | index($k)) ],
                  epicConflict: [ $ws[] | select(((.epicConflict // []) | length) > 0) | .id ],
                  badEpic: [ $ws[] | select(.beadsEpic != null and ((.beadsEpic | type) != "string" or .beadsEpic == "")) | .id ],
                  epics: ([ $ws[] | .beadsEpic | select(type == "string" and . != "") ] | unique),
                  lanes: [ $ws[] | (.lane // .id) ],
                  wids: [ $ws[] | .worktreeId | select(type == "string" and . != "") ],
                  fuBad: ((($r.followUps // []) | type) != "array" or any(($r.followUps // [])[]; type != "object")),
                  fuOpen: (if ((($r.followUps // []) | type) != "array") then [] else
                      ( {seen: $ids, frontier: $ids}
                        | until(.frontier | length == 0;
                            .seen as $s | .frontier as $f
                            | ([ $r.workers | to_entries[] | select((.value | type) == "object")
                                 | select(.value.parent as $p | ($p | type) == "string" and ($f | index($p)) != null) | .key ] | unique - $s) as $new
                            | {seen: ($s + $new), frontier: $new})
                        | .seen ) as $fam
                      | [ ($r.followUps // [])[] | select(type == "object" and .state != "done" and ((.issue // .issueUrl) == null) and (.worker as $w | $fam | index($w)) != null)
                          | "\(.worker):\(.id)" ] end) }' 2>/dev/null)" \
           && [ -n "$LW" ]; then
        LEDGER_OK=1
        check ledger "live worker(s) $(printf '%s' "$LW" | jq -r '.ids | join(",")')"
      else
        LW=""
        check ledger "UNKNOWN (cannot read workers $(printf '%s' "$LIDS" | tr '\n' ' '))"
        gate "ledger workers unreadable: standing and beads state unknown"
      fi
    fi
  fi
fi

# lw <jq filter>: read the merged ledger view.
lw() { printf '%s' "$LW" | jq -r "$1"; }
# ask_ok <ask-id> <kind>: the ledger holds that ask, answered and approved,
# of that kind, for this host and this path (or a live worker on it), unused.
ask_ok() {
  [ "$LEDGER_OK" -eq 1 ] || return 1
  [ "$(jq -r --arg a "$1" --arg k "$2" --arg h "$HOST" --arg wt "$WT" \
        --argjson ids "$(lw '.ids')" '
      any((.asks // [])[]?; .id == $a and .kind == $k and .state == "answered"
          and .decision == "approved" and (.usedAt // null) == null and .host == $h
          and (.path == $wt or ((.worker // null) as $w | $w != null and ($ids | index($w)))))' \
      "$LEDGER" 2>/dev/null)" = true ]
}

# ---- standing lane ------------------------------------------------------------
# Sweepers and lane leads are long-lived: more work will be assigned, so an
# idle lead is idle, not done. Only single-task workers are torn down.
if [ "$OWNER_MODE" -eq 1 ]; then
  # No ledger, so standing comes from the config lane names and the lane-lead name shapes; a name
  # that looks like a lane is refused (a refusal is the safe side: concertmaster mode decides it).
  # A child a lead lists in cm:child / WORKERS I OWN is a single-task worker by contract.
  if [ -n "$WT" ]; then
    # configured lane names, configured ownership leads and lane-shaped names: cm_lane_shaped (lib.sh), the
    # same predicate followups.sh adoption and concertmaster mode use
    SDN=""
    [ -z "$ROW" ] || SDN="$(printf '%s' "$ROW" | jq -r '.displayName // ""')"
    SHIT=""
    for _sn in "${WT##*/}" "$SDN"; do
      [ -n "$_sn" ] || continue
      if _why="$(cm_lane_reason "$_sn")"; then SHIT="${SHIT:-$_sn ($_why)}"; fi
    done
    if [ -n "$SHIT" ]; then
      check standing "YES? ($SHIT)"
      gate "standing lane ($SHIT): refused in lead mode; a standing lane is never torn down by a lead (concertmaster mode, owner-approved path only)"
    else
      check standing "no (listed as a child of $OWNER; not a configured or lane-shaped name)"
    fi
  fi
elif [ -n "$LW" ]; then
  WHY=""
  ST_TRUE="$(lw '.standingTrue | join(",")')"
  ST_UNK="$(lw '.standingUnknown | join(",")')"
  LEADS="$(lw '.lead | join(",")')"
  [ -z "$ST_TRUE" ] || WHY="ledger standing:true ($ST_TRUE)"
  [ -z "$LEADS" ] || WHY="${WHY:+$WHY, }ledger lane lead $LEADS"
  if [ -z "$WHY" ] && [ -n "$ST_UNK" ]; then
    check standing "UNKNOWN (standing not true/false on $ST_UNK)"
    gate "standing state unknown on ledger worker(s) $ST_UNK: record standing true or false first"
  elif [ -z "$WHY" ]; then
    DNAME=""
    [ -z "$ROW" ] || DNAME="$(printf '%s' "$ROW" | jq -r '.displayName // ""')"
    if cm_lane_shaped "${WT##*/}" || { [ -n "$DNAME" ] && cm_lane_shaped "$DNAME"; }; then
      check standing "no (ledger standing:false; note: name looks like a lane, ledger wins)"
    else
      check standing "no (ledger standing:false, single-task worker)"
    fi
  elif [ -n "$FORCE_STANDING" ] && ask_ok "$FORCE_STANDING" remove-standing; then
    check standing "YES ($WHY): --force-standing, $CM_OWNER_NAME approved in ask $FORCE_STANDING"
    plan "concertmaster: set asks[$FORCE_STANDING].usedAt (single use)"
  elif [ -n "$FORCE_STANDING" ]; then
    check standing "YES ($WHY)"
    gate "--force-standing $FORCE_STANDING is not an unused, approved remove-standing ask for $HOST:$WT: standing lane kept"
  else
    check standing "YES ($WHY)"
    gate "standing lane ($WHY): idle is not done, never torn down (--force-standing <ask-id> only after $CM_OWNER_NAME approves)"
  fi
elif [ -n "$WT" ]; then
  check standing "UNKNOWN (no ledger answer)"
fi

# ---- beads gate ---------------------------------------------------------------
# A worker that owns a beads epic is done only when every bead under the epic
# is closed. Sources: origin/<default> (fetched now), the worktree copy, the
# live .beads dir behind a redirect, and bd when installed. Every source must
# read; "absent" is only an explicit exit 5. Latest record per bead wins.
# shellcheck disable=SC2016
BEADS_JQ='
def epoch:
  if type != "string" or length < 19 then 0 else
    ((.[0:19] + "Z") | (try fromdateiso8601 catch 0)) as $b
    | ([capture("(?<s>[+-])(?<h>[0-9]{2}):(?<m>[0-9]{2})$")] | first) as $o
    | if $o == null then $b
      else $b - ((if $o.s == "-" then -1 else 1 end) * (($o.h | tonumber) * 3600 + ($o.m | tonumber) * 60)) end
  end;
def isopen: (.status != "closed" and .status != "tombstone");
def parents: [ .dependencies[]? | select(type == "object" and .type == "parent-child") | .depends_on_id | select(type == "string") ];
def latest: group_by(.id) | map(
    (map(.updated_at | epoch) | max) as $m
    | [ .[] | select((.updated_at | epoch) == $m) ] as $top
    | (([ $top[] | select(isopen) ] | first) // $top[0])
      + { parentIds: ([ .[] | parents[] ] | unique) });
[ .[] | select(type == "object" and (.id | type) == "string") ] as $all
| if $mode == "epic" then
    ($all | latest) as $n
    | { seen: [$e], frontier: [$e] }
    | until(.frontier | length == 0;
        .seen as $seen
        | ([ .frontier[] as $p | $n[]
             | select((.id | startswith($p + ".")) or (.parentIds | index($p)))
             | .id ] | unique - $seen) as $new
        | .seen += $new | .frontier = $new)
    | (.seen - [$e]) as $kids
    | [ $n[] | select(.id as $i | $kids | index($i)) ] as $kn
    | [ $kn[] | select(isopen) | .id ] as $open
    | ([ $n[] | select(.id == $e) ] | first) as $ep
    | "\($ep != null or ($kids | length) > 0) \(if $ep == null then "unknown" elif ($ep | isopen) then "open" else "closed" end) \($kids | length) \($open | length) \($open[:5] | join(","))"
  else
    ([ $all[] | select(.src != "wt") ] | latest | map({ key: .id, value: (.updated_at | epoch) }) | from_entries) as $elsewhere
    | [ $all[] | select(.src == "wt") ] | latest
    | [ .[] | select(isopen) | select(($elsewhere[.id] // -1) < (.updated_at | epoch)) | .id ] as $u
    | "\($u | length) \($u[:5] | join(","))"
  end'
EPICS=""
BAD_EPIC=""
if [ -n "$LW" ]; then
  EPICS="$(lw '.epics[]')"
  BAD_EPIC="$(lw '.badEpic | join(",")')"
elif [ "$OWNER_MODE" -eq 1 ]; then
  EPICS="$(printf '%s\n' "$OWNER_EPICS" | grep . | sort -u || true)"
fi
EPIC_CONFLICT=""
[ -z "$LW" ] || EPIC_CONFLICT="$(lw '.epicConflict | join(",")')"
if [ -n "$EPIC_CONFLICT" ]; then
  check beads "UNKNOWN (cm:child lines declare different epic= ids for $EPIC_CONFLICT)"
  gate "leads declare different epic= ids for $EPIC_CONFLICT: which epic gates this teardown is unknown, make the cm:child lines agree and reconcile"
fi
if [ -n "$BAD_EPIC" ]; then
  check beads "UNKNOWN (beadsEpic is not a string on $BAD_EPIC)"
  gate "ledger beadsEpic on $BAD_EPIC is not a bead id: beads state unknown"
fi
BWT=""; BMAIN=""; BRED=""; BBD=""; BBD_ERR=""
BWT_ST=absent; BMAIN_ST=absent; BRED_ST=absent; BBD_ST=absent; BFETCH=skipped
DEF=refs/remotes/origin/main
if [ -n "$WT" ] && [ "$GITOK" -eq 1 ]; then
  # Default branch from origin/HEAD. It is repo data, so it is validated as a
  # plain branch name before it reaches git, and only ever passed after "--"
  # or inside a full refs/... name: a value like "--upload-pack=x" never runs.
  DEFB="$(origin_default_branch)"
  if ! branch_name_ok "$DEFB"; then
    check beads "UNKNOWN (origin/HEAD names an invalid branch)"
    gate "origin/HEAD names an invalid branch name: refusing to pass it to git"
    DEFB=""; BFETCH=failed
  fi
  if [ -n "$DEFB" ]; then
    DEF="refs/remotes/origin/$DEFB"
    # Fetched now so new beads are visible; bounded, never prompts.
    # shellcheck disable=SC2016
    FETCH_SCRIPT='GIT_TERMINAL_PROMPT=0 exec git -C "$1" fetch -q -- origin "$2"'
    BFETCH=failed
    if [ "$HOST" = local ]; then
      if cm_timeout 60 bash -c "$FETCH_SCRIPT" cm-fetch "$WT" "+refs/heads/$DEFB:$DEF" >/dev/null 2>&1; then BFETCH=ok; fi
    elif rrun "$FETCH_SCRIPT" "$WT" "+refs/heads/$DEFB:$DEF" >/dev/null 2>&1; then
      BFETCH=ok
    fi
  fi
  # Worktree copy. Exit 5 is the ONLY "absent"; an unreadable .beads is a failure.
  # shellcheck disable=SC2016
  BWT="$(rrun 'd="$1/.beads"
if [ -e "$d" ] || [ -L "$d" ]; then { [ -r "$d" ] && [ -x "$d" ]; } || exit 6; fi
[ -e "$d/issues.jsonl" ] || exit 5
cat -- "$d/issues.jsonl"' "$WT" 2>/dev/null)"
  case $? in 0) BWT_ST=ok ;; 5) BWT_ST=absent; BWT="" ;; *) BWT_ST=failed; BWT="" ;; esac
  if [ "$BFETCH" = ok ]; then
    if ! BLS="$(g ls-tree --name-only "$DEF" -- .beads/issues.jsonl 2>/dev/null)"; then
      BMAIN_ST=failed
    elif [ -n "$BLS" ]; then
      if BMAIN="$(g show "$DEF:.beads/issues.jsonl" 2>/dev/null)"; then BMAIN_ST=ok
      else BMAIN_ST=failed; BMAIN=""; fi
    fi
  else
    BMAIN_ST=failed
  fi
  # Live copy behind .beads/redirect (first non-comment line; relative to the
  # worktree root, as bd resolves it). The target must resolve to this repo's
  # main checkout .beads dir and nothing else: a redirect elsewhere (another
  # dir, the worktree's own .beads) is a failure, as is an unreadable target.
  REDIR_WANT="$(printf '%s\n' "${MAINDIR:-}/.beads" | canon_paths 2>/dev/null | cut -f2)"
  # shellcheck disable=SC2016
  BRED="$(rrun 'r="$1/.beads/redirect"
[ -e "$r" ] || [ -L "$r" ] || exit 5
[ -r "$r" ] || exit 6
t=$(sed -e "s/^[[:space:]]*//" -e "s/[[:space:]]*$//" < "$r" | grep -v -e "^#" -e "^$" | head -n 1)
[ -n "$t" ] || exit 6
case "$t" in /*) ;; *) t="$1/$t" ;; esac
c=$(cd -- "$t" 2>/dev/null && pwd -P) || exit 6
[ -n "$2" ] && [ "$c" = "$2" ] || exit 7
[ -r "$c/issues.jsonl" ] || exit 6
cat -- "$c/issues.jsonl"' "$WT" "${REDIR_WANT:-}" 2>/dev/null)"
  case $? in
    0) BRED_ST=ok ;;
    5) BRED_ST=absent; BRED="" ;;
    7) BRED_ST=failed-outside-main-checkout; BRED="" ;;
    *) BRED_ST=failed; BRED="" ;;
  esac
  # bd, when installed on the host: it honours the redirect and reads the DB.
  # Read-only: started from / (never with its cwd in the worktree), pointed at
  # the worktree with -C, with --readonly (writes blocked) and --sandbox (no
  # auto-push). A bd too old for these flags fails, and the gate refuses.
  # CM_BD_CMD names the bd binary (default bd), like ORCA_CLI_COMMAND for orca.
  BD_CMD="${CM_BD_CMD:-bd}"
  case "$BD_CMD" in *[!A-Za-z0-9._/-]*|-*|'') cm_warn "invalid CM_BD_CMD"; BD_CMD=bd ;; esac
  # A worktree whose bd never opened a store has no database: bd exits 1 and
  # says "no beads database found". bd gives that no distinct exit code, so the
  # script only collects facts (exit 4) and the verdict is made here: absent
  # only when bd where --json parses (jq) as an object with a path and no
  # database_path, no store exists on disk (.beads/embeddeddolt, .beads/dolt,
  # .beads/*.db), .beads/config.yaml sets nothing, .beads/metadata.json names
  # the default database (or is missing), and BEADS_DIR/BEADS_DB are unset.
  # Anything else, including a store with pending schema migrations that
  # --readonly will not apply, stays failed with bd's first Error line.
  # Each bd call is bounded by CM_BD_SECS (default 90) on the host itself when
  # it has timeout/gtimeout, and the whole read by twice that plus 10s from
  # here (which over ssh only stops the ssh client). Any timeout, including
  # the perl alarm fallback (SIGALRM, exit 142), is reported as a timeout.
  BD_SECS="${CM_BD_SECS:-90}"
  case "$BD_SECS" in ''|*[!0-9]*|0*) BD_SECS=90 ;; esac
  BD_ALL_SECS=$((BD_SECS * 2 + 10))
  # shellcheck disable=SC2016
  BD_SCRIPT='command -v "$2" >/dev/null 2>&1 || exit 5
cd / || exit 6
t=$(mktemp 2>/dev/null) || exit 6
u=$(mktemp 2>/dev/null) || { rm -f -- "$t"; exit 6; }
p=""
trap "rm -f -- \"$t\" \"$u\"" EXIT
trap "[ -z \"\$p\" ] || kill \"\$p\" 2>/dev/null; exit 143" HUP INT TERM
trap "[ -z \"\$p\" ] || kill \"\$p\" 2>/dev/null; exit 142" ALRM
if command -v timeout >/dev/null 2>&1; then to="timeout $3"
elif command -v gtimeout >/dev/null 2>&1; then to="gtimeout $3"
else to=""; fi
runbd() { $to "$@" & p=$!; wait "$p"; }
runbd "$2" -C "$1" --readonly --sandbox list --all --limit 0 --json 2>"$t" && exit 0
rc=$?
case $rc in 124|137|142|143) printf "\ncm-bd-error: timeout after %ss\n" "$3"; exit 1 ;; esac
e=$(grep -m 1 "^Error" "$t")
printf "\ncm-bd-error: %s\n" "${e:-exit $rc}"
grep -q "no beads database found" "$t" || exit 1
if runbd "$2" -C "$1" --readonly --sandbox where --json >"$u" 2>/dev/null; then printf "cm-bd-where: %s\n" "$(tr -d "\n" < "$u")"; fi
for f in "$1/.beads/embeddeddolt" "$1/.beads/dolt" "$1"/.beads/*.db; do
  if [ -e "$f" ] || [ -L "$f" ]; then printf "cm-bd-store: %s\n" "${f##*/}"; fi
done
c="$1/.beads/config.yaml"
if [ -e "$c" ] && { [ ! -r "$c" ] || grep -v -e "^[[:space:]]*#" -e "^[[:space:]]*$" "$c" | grep -q .; }; then printf "cm-bd-config: set\n"; fi
m="$1/.beads/metadata.json"
if [ -e "$m" ]; then printf "cm-bd-meta: %s\n" "$(tr -d "\n" < "$m" 2>/dev/null || echo unreadable)"; fi
if [ -n "${BEADS_DIR:-}${BEADS_DB:-}" ]; then printf "cm-bd-env: set\n"; fi
exit 4'
  if [ "$HOST" = local ]; then
    BBD="$(cm_timeout "$BD_ALL_SECS" bash -c "$BD_SCRIPT" cm-bd "$WT" "$BD_CMD" "$BD_SECS" 2>/dev/null)"
  else
    BBD="$(RRUN_SECS="$BD_ALL_SECS" rrun "$BD_SCRIPT" "$WT" "$BD_CMD" "$BD_SECS" 2>/dev/null)"
  fi
  BBD_RC=$?
  bdline() { printf '%s\n' "$BBD" | sed -n "s/^cm-bd-$1: //p" | tail -n 1; }
  case $BBD_RC in
    0) BBD_ST=ok ;;
    5) BBD_ST=absent; BBD="" ;;
    124|137|142|143) BBD_ST=failed; BBD_ERR="$(bdline error)"; BBD_ERR="${BBD_ERR:-timeout after ${BD_ALL_SECS}s}"; BBD="" ;;
    4)
      if bdline where | jq -e 'type == "object" and (.path | type == "string")
                                and ((.database_path // "") == "")' >/dev/null 2>&1 \
         && [ -z "$(bdline store)" ] && [ -z "$(bdline config)" ] && [ -z "$(bdline env)" ] \
         && { [ -z "$(bdline meta)" ] \
              || bdline meta | jq -e 'type == "object" and ((.database // "beads.db") == "beads.db")' >/dev/null 2>&1; }; then
        BBD_ST=absent
      else
        BBD_ST=failed
        BBD_ERR="$(bdline error) (no database, but a database may be configured or on disk)"
      fi
      BBD="" ;;
    *) BBD_ST=failed; BBD_ERR="$(bdline error)"; BBD="" ;;
  esac
  BBD_ERR="$(printf '%s' "$BBD_ERR" | tr -cd 'A-Za-z0-9 ._:,()/="-' | cut -c 1-200)"
  # A redirect means the live DB lives behind bd; without bd it cannot be read.
  if [ "$BRED_ST" != absent ] && [ "$BBD_ST" = absent ]; then BBD_ST=failed-missing-with-redirect; fi
fi
BSRC="fetch:$BFETCH ${DEF}:$BMAIN_ST worktree:$BWT_ST redirect:$BRED_ST bd:$BBD_ST"
[ -z "$BBD_ERR" ] || BSRC="$BSRC (bd said: $BBD_ERR)"
# bd could not read the store (older schema than the installed bd, a timeout, a
# failure): that source is UNKNOWN. The refusal says so and names the safe path;
# with --beads-unreadable-ok <reason> it is excused, and ONLY it (the other beads
# sources still gate). The store is never migrated and never written to.
# Only the case the flag exists for: bd ran, opened nothing and printed an Error line
# (a schema older than bd, say). A timeout, bd missing behind a redirect, and "no
# database, but one may be configured elsewhere" mean the real store may live outside
# this worktree's .beads, so the copy would not be the store: those stay hard refusals.
BEADS_UNREAD=0
if [ "$BBD_ST" = failed ] && [ -n "$BBD_ERR" ]; then
  case "$BBD_ERR" in timeout*|*"no database, but"*|"exit "*) ;; *) BEADS_UNREAD=1 ;; esac
fi
# Gap (a): a store bd cannot read (older schema) on a worktree that never changed a tracked bead
# file is not a refusal. Excused when NO tracked .beads path differs from the merge-base with the
# default branch (and no untracked bead file exists; bd runtime paths are not bead files), with the
# other sources readable. The epic / unmerged-beads checks below still run on those sources, so open
# beads still refuse. The live store is never migrated or written: the excusal reads a migrated COPY
# (under the state dir of the host that holds the worktree, local or remote) and refuses unless it lists 0 open beads.
# Only an error that says the SCHEMA is older (migration pending, a column the new bd expects is
# missing) is excused on its own, matched on those phrases and not on the bare word 'schema': any other
# bd Error (a refused connection to a configured external database, a store schema NEWER than bd, an
# error that merely names a schema) leaves the store state unknown and keeps the hard refusal and the flag.
BEADS_SCHEMA_ERR=0
case "$(cm_lower "$BBD_ERR")" in
  *"pending schema migration"*|*"pending migration"*|*"migrate: pending"*|*"older schema"*|*"schema is older"*|*"schema older"*|*"does not have column"*|*"no such column"*|*"unknown column"*) BEADS_SCHEMA_ERR=1 ;;
esac
# The tracked-file diff cannot see open beads: they live in the git-ignored embedded Dolt store, the
# very thing bd could not read. So the excusal also READS that store, on a COPY. beads_copy_read copies
# .beads into a fresh mktemp dir under $CM_HOME/tmp, runs bd migrate schema there, lists the beads on the
# copy and removes the copy. The live store is never migrated, never written. Only a clean migrated read
# of 0 open beads excuses; open beads, or any failed step, refuse. A copy of a store whose .beads/redirect
# points elsewhere is not the store, so that case fails too (as does a symlink inside .beads).
# CM_BD_MIGRATE_SECS (default 300) bounds the migrate; CM_BD_SECS bounds each other bd call.
BD_MIG_SECS="${CM_BD_MIGRATE_SECS:-300}"
case "$BD_MIG_SECS" in ''|*[!0-9]*|0*) BD_MIG_SECS=300 ;; esac
BCOPY_ST=""; BCOPY_OPEN=""; BCOPY_ERR=""
# shellcheck disable=SC2016
BCOPY_SCRIPT='bd=$2; secs=$3; msecs=$4; base=${5:-$HOME/.concertmaster}; c=""; p=""
cd / || exit 6
for v in $(env | sed -n "s/^\(BEADS_[A-Za-z0-9_]*\)=.*/\1/p; s/^\(BD_[A-Za-z0-9_]*\)=.*/\1/p; s/^\(DOLT_[A-Za-z0-9_]*\)=.*/\1/p"); do unset "$v"; done
cleanup() {
  # p is the pid of this script own bd child (set by runbd), killed by exact pid, never by name
  [ -z "$p" ] || kill "$p" 2>/dev/null
  case "$c" in "$base"/tmp/beads-copy.?*) chmod -R u+rwx -- "$c" 2>/dev/null; rm -rf -- "${c:?}" ;; esac
}
trap cleanup EXIT
trap "exit 143" HUP INT TERM ALRM
fail() { printf "cm-copy-error: %s\n" "$1"; exit 1; }
command -v "$bd" >/dev/null 2>&1 || fail "bd not found on this host"
command -v jq >/dev/null 2>&1 || fail "jq not found on this host"
src="$1/.beads"
[ -d "$src" ] && [ ! -L "$src" ] || fail "no .beads dir in the worktree"
[ ! -e "$src/redirect" ] && [ ! -L "$src/redirect" ] || fail ".beads/redirect puts the store outside this worktree, so a copy is not the store"
case "$base" in /*) ;; *) fail "state dir is not an absolute path" ;; esac
case "$base" in *[[:space:]]*) fail "state dir has whitespace in its path" ;; esac
mkdir -p -- "$base/tmp" 2>/dev/null || fail "cannot create $base/tmp"
base=$(cd -- "$base" 2>/dev/null && pwd -P) || fail "cannot resolve the state dir"
d=$(mktemp -d "$base/tmp/beads-copy.XXXXXX" 2>/dev/null) || fail "mktemp -d failed under $base/tmp"
c=$d
case "$c" in "$base"/tmp/beads-copy.?*) ;; *) c=""; fail "unexpected temp dir" ;; esac
# no -quit (BSD find lacks it) and a failing find is a refusal, never an empty answer
find "$src" -type l -print >"$c/links" 2>/dev/null || fail "cannot scan .beads for symlinks"
[ ! -s "$c/links" ] || fail "a symlink inside .beads: a copy could write through it"
need=$(du -sk -- "$src" 2>/dev/null | cut -f1); avail=$(df -Pk -- "$base/tmp" 2>/dev/null | awk "NR==2 {print \$4}")
case "$need$avail" in ""|*[!0-9]*) fail "cannot size the store or the free space under $base/tmp" ;; esac
[ "$need" -ge 1 ] || need=1
[ "$avail" -ge $((need * 3 + 1024)) ] || fail "not enough free space under $base/tmp for a copy of the store (${need}K store, ${avail}K free)"
cp -a -- "$src" "$c/.beads" 2>/dev/null || fail "copy of .beads failed"
find "$c/.beads" -type l -print >"$c/links" 2>/dev/null || fail "cannot scan the copy of .beads for symlinks"
[ ! -s "$c/links" ] || fail "a symlink inside the copy of .beads: a copy could write through it"
# runtime files of a Dolt server: a store that was ever served may still point bd at a live server
for f in "$c"/.beads/dolt-server*; do
  if [ -e "$f" ] || [ -L "$f" ]; then fail "a Dolt server runtime file in .beads: bd on the copy could reach a live server"; fi
done
m="$c/.beads/metadata.json"
if [ -e "$m" ]; then
  jq -e "type == \"object\" and ((.dolt_mode // \"embedded\") == \"embedded\") and ((keys - [\"dolt_server_host\", \"dolt_server_port\", \"dolt_data_dir\", \"shared_server\"]) == keys)" "$m" >/dev/null 2>&1 \
    || fail "metadata.json names a server or an external data dir: a copy would not be the store"
fi
# config.yaml: an ALLOWLIST. Any key other than a plain issue-prefix (a server, a remote, backup.*, export.*,
# git-repo, sync options, nested or quoted keys) could send bd on the copy somewhere outside the copy.
y="$c/.beads/config.yaml"
if [ -e "$y" ]; then
  # Only tab, CR, LF and printable ASCII: NUL, high bytes and the Unicode line breaks make grep and the YAML
  # parser disagree about where a line ends. A lone CR is a YAML line break too, so it becomes LF before the filter.
  [ "$(LC_ALL=C tr -d "\t\r\n -~" <"$y" | wc -c | tr -d " ")" = 0 ] || fail "config.yaml has bytes beyond printable ASCII: it cannot be screened"
  if [ -n "$(LC_ALL=C tr "\r" "\n" <"$y" | LC_ALL=C grep -a -Ev "^[[:space:]]*(#|$)" | LC_ALL=C grep -a -Ev "^(issue-prefix|issue_prefix):[[:space:]]*[A-Za-z0-9._\"-]*[[:space:]]*$")" ]; then
    fail "config.yaml sets options beyond issue-prefix: a copy could reach a server, a remote or a backup target"
  fi
fi
# bd also reads user-level config (~/.config/bd, ~/.beads) that can switch it to a shared server: give the copy
# its own empty HOME. And never let the copy re-import the tracked issues.jsonl: the list must show only
# what the store itself holds, not every bead the project has.
mkdir -- "$c/home" 2>/dev/null || fail "cannot create the copy home"
export HOME="$c/home"
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
for f in "$c"/.beads/*.jsonl; do
  if [ -e "$f" ]; then : >"$f" || fail "cannot empty $f in the copy"; fi
done
# The copied dolt repo state names the live backup dir and any remote by absolute path: drop both, so a
# migrate on the copy cannot export or push into the live worktree.
# NUL separated list in a file, read without a subshell: a name with a space or a glob character stays one path.
find "$c/.beads" -name repo_state.json -type f -print0 >"$c/rs.list" 2>/dev/null || fail "cannot list the copied dolt repo state"
while IFS= read -r -d "" f; do
  case "$f" in "$c"/.beads/*) ;; *) fail "repo_state.json path outside the copy" ;; esac
  jq ".backups = {} | .remotes = {}" "$f" >"$f.new" 2>/dev/null && mv -f -- "$f.new" "$f" || fail "cannot neutralise backups and remotes in the copied dolt repo state"
done <"$c/rs.list"
tmo=""
if command -v timeout >/dev/null 2>&1; then tmo=timeout; elif command -v gtimeout >/dev/null 2>&1; then tmo=gtimeout; fi
runbd() {
  s=$1; shift
  if [ -n "$tmo" ]; then "$tmo" "$s" "$bd" -C "$c" --sandbox "$@" & p=$!
  else "$bd" -C "$c" --sandbox "$@" & p=$!; fi
  wait "$p"; r=$?; p=""; return "$r"
}
runbd "$secs" --readonly where --json >"$c/where.json" 2>/dev/null || fail "bd where failed on the copy"
jq -e --arg c "$c/" "type == \"object\" and ((.path // \"\") | startswith(\$c)) and (((.database_path // \"\") == \"\") or ((.database_path | startswith(\$c))))" "$c/where.json" >/dev/null 2>&1 \
  || fail "bd on the copy resolves a store outside the copy"
dbs() { find "$c/.beads/embeddeddolt" "$c/.beads/dolt" -mindepth 1 -maxdepth 1 2>/dev/null | LC_ALL=C sort | tr "\n" " "; }
dbs0=$(dbs)
runbd "$secs" dolt commit >"$c/out" 2>"$c/err" || true
if cat "$c/out" "$c/err" | grep -Eiq "shared.server|dolt server|server mode"; then fail "bd on the copy talked to a Dolt server"; fi
r=0; runbd "$msecs" migrate schema >"$c/out" 2>"$c/err" || r=$?
if [ "$r" != 0 ]; then
  case $r in 124|137|142|143) fail "bd migrate schema timed out on the copy after ${msecs}s" ;; esac
  fail "bd migrate schema failed on the copy: $(grep -m 1 "^Error" "$c/err" || echo "exit $r")"
fi
if grep -Eiq "shared.server|dolt server|server mode" "$c/err"; then fail "bd migrate on the copy talked to a Dolt server"; fi
r=0; runbd "$secs" --readonly list --all --include-gates --include-infra --include-ephemeral --include-templates --limit 0 --json >"$c/out" 2>"$c/err" || r=$?
if [ "$r" != 0 ]; then
  case $r in 124|137|142|143) fail "bd list timed out on the migrated copy after ${secs}s" ;; esac
  fail "bd list failed on the migrated copy: $(grep -m 1 "^Error" "$c/err" || echo "exit $r")"
fi
if grep -Eiq "shared.server|dolt server|server mode" "$c/err"; then fail "bd on the migrated copy talked to a Dolt server"; fi
# A database bd could not find is CREATED empty by the first write, and an empty database lists 0 beads: refuse
# when the set of databases under the copy changed, so a missing store never reads as 0 open.
[ "$(dbs)" = "$dbs0" ] || fail "bd created a new database in the copy: the store it was asked about was not found"
n=$(jq -e "if type == \"array\" then [.[] | select((.status // \"\") as \$s | \$s != \"closed\" and \$s != \"tombstone\")] | length else error(\"not an array\") end" "$c/out" 2>/dev/null) \
  || fail "bd list on the migrated copy did not print a JSON array"
case "$n" in ""|*[!0-9]*) fail "open-bead count unreadable" ;; esac
printf "cm-copy-open: %s\n" "$n"'
beads_copy_read() {
  [ -z "$BCOPY_ST" ] || return 0
  local out rc total
  total=$((BD_SECS * 3 + BD_MIG_SECS + 60))
  if [ "$HOST" = local ]; then
    out="$(cm_timeout "$total" bash -c "$BCOPY_SCRIPT" cm-copy "$WT" "$BD_CMD" "$BD_SECS" "$BD_MIG_SECS" "$CM_HOME" 2>/dev/null)"; rc=$?
  else
    out="$(RRUN_SECS="$total" rrun "$BCOPY_SCRIPT" "$WT" "$BD_CMD" "$BD_SECS" "$BD_MIG_SECS" "" 2>/dev/null)"; rc=$?
  fi
  BCOPY_OPEN="$(printf '%s\n' "$out" | sed -n 's/^cm-copy-open: //p' | tail -n 1)"
  if [ "$rc" = 0 ]; then
    case "$BCOPY_OPEN" in
      ''|*[!0-9]*) BCOPY_ST=failed; BCOPY_OPEN=""; BCOPY_ERR="open-bead count unreadable" ;;
      *) BCOPY_ST=ok ;;
    esac
  else
    BCOPY_ST=failed; BCOPY_OPEN=""
    BCOPY_ERR="$(printf '%s\n' "$out" | sed -n 's/^cm-copy-error: //p' | tail -n 1)"
    case $rc in 124|137|142|143) BCOPY_ERR="${BCOPY_ERR:-timed out after ${total}s}" ;; esac
    BCOPY_ERR="${BCOPY_ERR:-exit $rc}"
  fi
  BCOPY_ERR="$(printf '%s' "$BCOPY_ERR" | tr -cd 'A-Za-z0-9 ._:,()/="-' | cut -c 1-200)"
}
BEADS_AUTO=0
if [ "$BEADS_UNREAD" = 1 ] && [ "$BEADS_SCHEMA_ERR" = 1 ] && [ -z "$BEADS_OK_REASON" ] && [ "$GITOK" -eq 1 ] && [ "$BFETCH" = ok ] \
   && [ "$BWT_ST" != failed ] && [ "$BMAIN_ST" != failed ] && [ "$BRED_ST" != failed ] && [ "$BRED_ST" != failed-outside-main-checkout ]; then
  if BMB="$(g merge-base HEAD "$DEF" 2>/dev/null)" && [ -n "$BMB" ] \
     && BTCH="$(g diff --name-only "$BMB" -- .beads 2>/dev/null; echo "rc=$?")" && [ "$BTCH" = "rc=0" ] \
     && BUNT="$(g ls-files --others --exclude-standard -- .beads 2>/dev/null; echo "rc=$?")" \
     && [ -z "$(printf '%s\n' "$BUNT" | grep -v '^rc=' | grep -Ev "$BD_RUNTIME_PATH_RE" || true)" ] \
     && [ "${BUNT##*rc=}" = 0 ]; then
    beads_copy_read
    if [ "$BCOPY_ST" = ok ] && [ "$BCOPY_OPEN" = 0 ]; then
      BEADS_AUTO=1
      check beads-unread "bd cannot read the store (UNKNOWN, likely an older schema): excused, no tracked .beads change vs $DEF and a migrated COPY of the store lists 0 open beads (live store untouched); epic and open-bead checks still read the other sources"
    fi
  fi
fi
BD_HINT=""
if [ "$BEADS_UNREAD" = 1 ] && [ "$BEADS_AUTO" = 0 ] && [ -z "$BEADS_OK_REASON" ] \
   && [ "$BFETCH" != failed ] && [ "$BWT_ST" != failed ] && [ "$BMAIN_ST" != failed ] && [ "$BRED_ST" != failed ] \
   && [ "$BRED_ST" != failed-outside-main-checkout ]; then
  if [ "$BCOPY_ST" = ok ] && [ "$BCOPY_OPEN" != 0 ]; then
    BD_HINT=" | bd cannot read this beads store, and a migrated COPY of it lists $BCOPY_OPEN open or in-progress bead(s): finish, close or hand over that work first; the live store is untouched (to migrate it by hand see references/recovery.md); do not override this with --beads-unreadable-ok"
  else
    BD_HINT=" | bd cannot read this beads store: its state is UNKNOWN (for example a store schema older than the installed bd). If the tree is otherwise clean and pushed and $CM_OWNER_NAME agrees, re-run with --salvage --beads-unreadable-ok '<reason>'; never migrate the store or run bd writes on this worktree"
    [ "$BCOPY_ST" != failed ] || BD_HINT="$BD_HINT | the read of a migrated copy failed ($BCOPY_ERR), so open beads could not be ruled out"
  fi
fi
# A store BEHIND the installed bd ("schema version mismatch: database is at vN, binary
# expects vM", N < M) has a sanctioned manual fix. This script still only refuses and
# never migrates; the hint names the recovery steps so the refusal is not a dead end.
# A store NEWER than bd (N >= M), or a message whose versions cannot be read, gets no hint:
# migrating with the older binary is wrong, so fail closed. It also gets none where the general
# hint above is held back (another source failed, or the flag was given): the store may not be
# this worktree's own.
case "$([ -n "$BD_HINT" ] && cm_lower "$BBD_ERR")" in
  *"schema version mismatch"*)
    SVM="$(printf '%s' "$(cm_lower "$BBD_ERR")" | sed -n 's/.*database is at v\([0-9][0-9]*\), binary expects v\([0-9][0-9]*\).*/\1 \2/p')"
    if [ -n "$SVM" ] && [ "${SVM% *}" -lt "${SVM#* }" ]; then
      BD_HINT="${BD_HINT//; never migrate the store or run bd writes on this worktree/}"
      BD_HINT="$BD_HINT | schema version mismatch: this script never migrates; fix it by hand, see references/recovery.md, section 'Beads schema version mismatch at teardown': back up .beads, then bd migrate schema, only with no live agent in the worktree, never wipe or recreate the store"
    fi ;;
esac
if [ "$BEADS_UNREAD" = 1 ] && [ -n "$BEADS_OK_REASON" ]; then
  # The flag stays an explicit override, but it says what it overrode: the same copy-read as the
  # automatic excusal, whose result (open-bead count, or why it failed) goes to the check line and the log.
  [ "$SALVAGE" -eq 1 ] || refuse "--beads-unreadable-ok needs --salvage: the whole .beads dir is copied out before anything is removed"
  beads_copy_read
  case "$BCOPY_ST:$BCOPY_OPEN" in
    ok:0) BCOPY_NOTE="a migrated copy of the store lists 0 open beads" ;;
    ok:*) BCOPY_NOTE="OVERRIDING $BCOPY_OPEN open or in-progress bead(s) found on a migrated copy of the store" ;;
    *) BCOPY_NOTE="open beads UNKNOWN, the migrated-copy read failed ($BCOPY_ERR)" ;;
  esac
  check beads-unread "bd cannot read the store: UNKNOWN, accepted by --beads-unreadable-ok ($BEADS_OK_REASON); $BCOPY_NOTE; the other beads sources are still checked"
fi
beads_failed() {
  local bd="$BBD_ST"
  if [ "$BEADS_UNREAD" = 1 ] && { [ -n "$BEADS_OK_REASON" ] || [ "$BEADS_AUTO" = 1 ]; }; then bd=accepted-unknown; fi
  case "$BFETCH $BWT_ST $BMAIN_ST $BRED_ST $bd" in *failed*) return 0 ;; esac
  return 1
}
# Tag each record with its source so one parse serves both modes. bd prints
# an array; the jsonl sources print one object per line.
beads_stream() {
  printf '%s\n' "$BWT" | jq -c '. + {src: "wt"}' 2>/dev/null || return 1
  printf '%s\n' "$BMAIN" | jq -c '. + {src: "main"}' 2>/dev/null || return 1
  printf '%s\n' "$BRED" | jq -c '. + {src: "live"}' 2>/dev/null || return 1
  printf '%s\n' "$BBD" | jq -c 'if type == "array" then .[] else . end | . + {src: "bd"}' 2>/dev/null || return 1
}
if [ -n "$EPICS" ]; then
  while IFS= read -r EPIC; do
    [ -n "$EPIC" ] || continue
    case "$EPIC" in
      *[!A-Za-z0-9._-]*|.*|-*)
        check beads "UNKNOWN (invalid beadsEpic '$EPIC')"
        gate "ledger beadsEpic '$EPIC' is not a bead id: beads state unknown"
        continue ;;
    esac
    if beads_failed; then
      check beads "UNKNOWN ($BSRC)"
      gate "beadsEpic $EPIC set but a beads source failed ($BSRC): not done$BD_HINT"
      continue
    fi
    if ! BSTREAM="$(beads_stream)" \
       || ! BSUM="$(printf '%s\n' "$BSTREAM" | jq -rs --arg e "$EPIC" --arg mode epic "$BEADS_JQ" 2>/dev/null)" \
       || [ -z "$BSUM" ]; then
      check beads "UNKNOWN (beads did not parse; $BSRC)"
      gate "beadsEpic $EPIC set but beads unreadable: not done"
      continue
    fi
    # BSUM: "<found> <epic state> <children> <open> <first open ids>"
    BFOUND="${BSUM%% *}"; BREST="${BSUM#* }"
    BEPST="${BREST%% *}"; BREST="${BREST#* }"
    BTOTAL="${BREST%% *}"; BREST="${BREST#* }"
    BOPEN="${BREST%% *}"; BIDS="${BREST#* }"
    if [ "$BFOUND" != true ]; then
      check beads "UNKNOWN (epic $EPIC not found; $BSRC)"
      gate "beadsEpic $EPIC not found in any beads source ($BSRC): cannot prove done"
    elif [ "$BOPEN" != 0 ]; then
      check beads "$BOPEN of $BTOTAL open under $EPIC ($BSRC): ${BIDS}"
      gate "$BOPEN open bead(s) under epic $EPIC: work not done, nudge the lane to continue"
    elif [ "$BTOTAL" = 0 ] && [ "$BEPST" != closed ]; then
      check beads "UNKNOWN (epic $EPIC is $BEPST with no children found; $BSRC)"
      gate "epic $EPIC is $BEPST with no children found by id or parent link: cannot prove done"
    else
      check beads "all $BTOTAL closed under $EPIC, epic $BEPST ($BSRC)"
    fi
  done <<EOF_EPICS
$EPICS
EOF_EPICS
elif [ -n "$LW" ] || [ "$OWNER_MODE" -eq 1 ]; then
  # No epic owned: open beads this worktree holds that no other source has at
  # least as new are unmerged bead work.
  if [ "$BWT_ST" = absent ]; then
    check beads "no epic in ledger; no beads in worktree"
  elif beads_failed; then
    check beads "UNKNOWN (no epic in ledger; $BSRC)"
    gate "beads read failed ($BSRC): cannot prove the worktree holds no open bead work$BD_HINT"
  elif ! BSTREAM="$(beads_stream)" \
       || ! BSUM="$(printf '%s\n' "$BSTREAM" | jq -rs --arg e "" --arg mode worktree "$BEADS_JQ" 2>/dev/null)" \
       || [ -z "$BSUM" ]; then
    check beads "UNKNOWN (no epic in ledger; beads did not parse)"
    gate "beads unreadable: cannot prove the worktree holds no open bead work"
  elif [ "${BSUM%% *}" = 0 ]; then
    check beads "no epic in ledger (epic gate skipped); no unmerged open beads ($BSRC)"
  elif [ -n "$ACCEPT_BEADS" ] && ask_ok "$ACCEPT_BEADS" accept-unmerged-beads; then
    check beads "${BSUM%% *} unmerged open bead(s): ${BSUM#* } accepted in ask $ACCEPT_BEADS"
    plan "concertmaster: set asks[$ACCEPT_BEADS].usedAt (single use)"
  else
    check beads "no epic in ledger; ${BSUM%% *} open bead(s) newer here than anywhere else: ${BSUM#* }"
    if [ -n "$ACCEPT_BEADS" ]; then
      gate "--accept-unmerged-beads $ACCEPT_BEADS is not an unused, approved accept-unmerged-beads ask for $HOST:$WT"
    else
      gate "${BSUM%% *} open bead(s) changed in this worktree and nowhere else: unmerged bead work (--accept-unmerged-beads <ask-id> after $CM_OWNER_NAME approves)"
    fi
  fi
fi

# ---- no-PR retirement (lead mode, --allow-no-pr) -------------------------------
# A lead's own child that never had a PR may be retired only on an explicit request in the child's OWN comment,
# with nothing left to lose. Only reached when the branch has no PR of any state (an open PR already refused; a
# merged or closed PR proves itself and the flag changes nothing). The ownership proof, the not-standing check,
# the clean/unpushed checks and every beads, process, follow-up and salvage gate are the ones above and below.
# What this adds: (1) the request, (2) terminals already closed, (3) zero commits ahead of origin/<default> as
# fetched by the beads gate just now. Anything unknown refuses.
if [ "$NOPR_LEAD" -eq 1 ]; then
  child_retire_request
  case "$RETIRE_ST" in
    norow)
      check nopr "no Orca row: no cm:retire request to read"
      refuse "no-PR retirement needs the child's cm:retire request in its Orca comment, and this worktree has no Orca row" ;;
    unreadable)
      check nopr "UNKNOWN (the child's comment could not be read)"
      refuse "child comment unreadable: the cm:retire request cannot be proven" ;;
    none)
      check nopr "NO cm:retire request: the first line of the child's comment is not 'cm:retire <reason>'"
      refuse "no-PR retirement needs the child's comment to start with 'cm:retire <reason>' (a reason with a letter or digit); a cm:retire later in the comment, or with a blank reason, does not count" ;;
    ok)
      check nopr "cm:retire request: $(printf '%s' "$RETIRE_WHY" | tr -cd 'A-Za-z0-9 ._:,()/=#@-' | cut -c 1-120)" ;;
    *)
      check nopr "UNKNOWN (retire state '$RETIRE_ST')"
      refuse "no-PR retirement: the cm:retire request state is unknown" ;;
  esac
  if [ "$TERMS_READ" -ne 1 ]; then
    check nopr-terms "UNKNOWN (terminals not read)"
    refuse "no-PR retirement needs the terminals proven closed, and the terminal list was not read"
  elif [ -n "${HANDLES:-}" ]; then
    check nopr-terms "OPEN: $(printf '%s\n' "$HANDLES" | tr '\n' ' ')"
    refuse "no-PR retirement needs the terminals already closed (open: $(printf '%s\n' "$HANDLES" | tr '\n' ' ')): close them first, --close-handle does not apply here"
  else
    check nopr-terms "none open"
  fi
  if [ "$GITOK" -ne 1 ] || [ "$BFETCH" != ok ]; then
    check nopr-ahead "UNKNOWN (fetch of origin/${DEFB:-?} $BFETCH)"
    refuse "no-PR retirement needs a fresh fetch of origin/${DEFB:-main}: commits ahead of it are unknown"
  elif AHEAD="$(g rev-list --count HEAD --not "$DEF" 2>/dev/null)" && [ -n "$AHEAD" ] && [ -z "${AHEAD//[0-9]/}" ]; then
    if [ "$AHEAD" = 0 ]; then
      check nopr-ahead "0 commits ahead of $DEF"
    else
      check nopr-ahead "$AHEAD commit(s) ahead of $DEF"
      refuse "no-PR retirement: $AHEAD commit(s) ahead of origin/$DEFB with no PR would be lost: open a PR or merge them first"
    fi
  else
    check nopr-ahead "UNKNOWN (git rev-list against $DEF failed)"
    refuse "no-PR retirement needs the commits ahead of origin/$DEFB counted, and the count failed"
  fi
fi

# ---- follow-up gate -----------------------------------------------------------
# An open followUps[] row (references/ledger.md) on this worker, or on any worker
# whose parent chain leads to it, is work that must outlive the worker: not done.
if [ "$OWNER_MODE" -eq 1 ]; then
  # No ledger: the child's own comment is the whole record. Any cm:followup line still open in it
  # (no cm:followup-done for the same id in the same comment) is work that outlives the worker.
  if [ -n "$ROW" ]; then
    if ! OW_RAW="$(printf '%s' "$ROW" | jq -r '.comment // ""' | "$HERE/followups.sh" comment-open 2>/dev/null)"; then
      check followups "UNKNOWN (the child's comment could not be read)"
      gate "child comment unreadable: open follow-up state unknown"
    elif [ -n "$OW_RAW" ]; then
      check followups "OPEN in the child's comment: $(printf '%s' "$OW_RAW" | tr '\n' ' ')"
      gate "open follow-up(s) in the child's comment ($(printf '%s' "$OW_RAW" | tr '\n' ' ')): finish them, hand them to another owner, or post cm:followup-done <id> first"
    else
      check followups "none open in the child's comment"
    fi
    # A child that itself declares children (cm:child / WORKERS I OWN in its comment) owns work this run cannot
    # see: spawn uses --no-parent, so Orca's own child check does not catch it, and the ledger's descendant
    # follow-up walk is not available here. Refuse until those are torn down (their lines removed).
    # shellcheck disable=SC2016  # jq program
    if ! GK="$(printf '%s' "$ROW" | jq -r '
        def segs: (.comment // "") | tostring | gsub("\\\\n"; "\n")
          | [ split("\n")[] | split(" | ")[] | sub("^\\s+"; "") | sub("\\s+$"; "") | select(length > 0) ];
        [ segs[]
          | ( (capture("^cm:child\\s+(?<n>[^\\s,@]+)") | .n),
              (capture("^workers i own:\\s*(?<l>.*)$"; "i") | .l | split(",")[] | sub("^\\s+"; "")
                | capture("^(?<n>[^\\s(,@]+)") | .n) )
          | select(. != "none" and . != "-") ] | unique | join(", ")' 2>/dev/null)"; then
      check descendants "UNKNOWN (the child's comment could not be read for its own children)"
      gate "child comment unreadable: its own children unknown"
    elif [ -n "$GK" ]; then
      check descendants "the child declares its own children: $GK"
      gate "the child declares its own children ($GK): tear those down and remove their cm:child lines first, their follow-ups are not checked here"
    else
      check descendants "the child declares no children"
    fi
  elif [ -n "$WT" ]; then
    # No row is "git-only, no comment" only when the census was complete; a census cut off at the limit
    # proves nothing about this worktree, and its comment may hold an open follow-up.
    if printf '%s' "${PS:-}" | jq -e '.result.truncated == true or ((.result.totalCount // 0) > (.result.worktrees | length))' >/dev/null 2>&1; then
      check followups "UNKNOWN (the Orca census was cut off and has no row for this worktree: comment unread)"
      gate "Orca census truncated and this worktree's row is missing: open follow-up state unknown"
    else
      check followups "no Orca row: no comment to read"
    fi
  fi
elif [ -n "$LW" ]; then
  FU_OPEN="$(lw '.fuOpen | join(", ")')"
  if [ "$(lw '.fuBad')" = true ]; then
    check followups "UNKNOWN (ledger followUps is not an array of objects)"
    gate "ledger followUps is not an array of objects: follow-up state unknown"
  elif [ -n "$FU_OPEN" ]; then
    check followups "OPEN: $FU_OPEN"
    gate "open follow-up(s) ($FU_OPEN): finish them, hand them to another owner, or close with cm:followup-done <id> (scripts/followups.sh close <id>) before teardown"
  else
    check followups "none open (worker and its children)"
  fi
  # The live comment can hold an item the last reconcile has not folded in yet (a lead posts it, then
  # this runs in the same tick): every open tag in it must already be done in the ledger for this lane.
  if [ -z "$ROW" ] && [ -n "$(lw '.wids | join("")')" ]; then
    check followups "UNKNOWN (Orca row missing for a worker with a worktreeId: comment unread)"
    gate "Orca row missing for $HOST:$WT: live comment unknown, cannot prove no open follow-up"
  elif [ -n "$ROW" ]; then
    if ! LIVE_RAW="$(printf '%s' "$ROW" | jq -r '.comment // ""' | "$HERE/followups.sh" comment-open --texts 2>/dev/null)"; then
      check followups "UNKNOWN (live comment could not be read)"
      gate "live comment unreadable: open follow-up state unknown"
    elif [ -n "$LIVE_RAW" ]; then
      LIVE_BAD="$(printf '%s\n' "$LIVE_RAW" | grep '^bad:' | tr '\n' ';' || true)"
      LIVE_RAW="$(printf '%s\n' "$LIVE_RAW" | grep -v '^bad:' || true)"
      if [ -n "$LIVE_BAD" ]; then
        check followups "MALFORMED in the live comment: ${LIVE_BAD%;}"
        gate "malformed follow-up line in live comment (${LIVE_BAD%;}): fix it (cm:followup <id> owner=<o> <text>) or remove it"
      fi
      # id<TAB>text lines. An id counts as done only when a closed row of this worker's lane holds the SAME text:
      # a closed id posted again for a new item is still open work held nowhere else.
      LIVE_IDS="$(printf '%s\n' "$LIVE_RAW" | grep . | jq -R 'split("\t") | {id: .[0], text: (.[1] // "")}' | jq -cs . 2>/dev/null)" || LIVE_IDS=""
      if [ -z "$LIVE_IDS" ]; then
        check followups "UNKNOWN (live comment ids could not be read)"
        gate "live comment ids unreadable: open follow-up state unknown"
      elif LIVE_OPEN="$(jq -r --argjson ids "$LIVE_IDS" --argjson lanes "$(lw '.lanes')" '
          . as $L | [ $ids[] | . as $x | select(any(($L.followUps // [])[]?; type == "object" and .id == $x.id and (.state == "done" or (.issue // .issueUrl) != null) and (.text // "") == $x.text and (.lane as $l | $lanes | index($l)) != null) | not) | .id ] | join(", ")' "$LEDGER" 2>/dev/null)"; then
        if [ -n "$LIVE_OPEN" ]; then
          check followups "OPEN in the live comment: $LIVE_OPEN"
          gate "open follow-up(s) in live comment ($LIVE_OPEN): not in the ledger as done (or escalated to a GitHub issue) with the same text (a closed id reused for a new item counts as open); run scripts/followups.sh reconcile, then finish or close them, and post a new item under a new id"
        fi
      else
        check followups "UNKNOWN (ledger unreadable for the live comment check)"
        gate "ledger unreadable: open follow-up state unknown"
      fi
    fi
  fi
fi

if [ "$RETIRE_CHECK" -eq 1 ]; then
  # Nothing proven is nothing allowed: an unresolved path, an unreachable or
  # wrong host, or no live ledger worker is never "ok".
  if [ -z "$WT" ] || [ "$LEDGER_OK" -ne 1 ]; then
    gate "path unresolved or no live ledger worker on $HOST for $IN: retire state unknown"
  fi
  if [ -n "$GATE_REFUSALS" ]; then
    printf 'RETIRE REFUSED:\n%s' "$GATE_REFUSALS"
    exit 3
  fi
  printf 'retire-check: ok (ledger, standing, beads and follow-up gates clean; nothing changed)\n'
  exit 0
fi

# ---- plan --------------------------------------------------------------------
ENVF="$(env_flag | tr '\n' ' ' | sed 's/ $//')"
CLOSE_FIRST=""
if [ -n "$ROW" ] && [ -n "${HANDLES:-}" ]; then
  for h in $HANDLES; do plan "$ORCA terminal close --terminal $h --json ${ENVF}"; done
  plan "re-run every check (beads read included) with those terminals closed; any refusal stops here"
  CLOSE_FIRST=1
fi
if [ "$DETACHED" -eq 1 ] && [ -n "$DT_REFS" ]; then
  plan "detached HEAD ${HEADSHA:0:12} is contained in remote ref ${DT_REF_NAMES}: no commit is unique to this worktree (no PR (detached): not a merged-PR proof)"
fi
SALVAGE_DIR=""
BEADS_WHOLE=0
[ "$BEADS_UNREAD" = 1 ] && [ -n "$BEADS_OK_REASON" ] && BEADS_WHOLE=1
if { [ -n "${PRECIOUS:-}" ] || [ "$BEADS_WHOLE" -eq 1 ]; } && [ "$SALVAGE" -eq 1 ]; then
  # Relative to ~/.concertmaster on the target host; every component sanitised.
  SALVAGE_REL="salvage/$(cm_safe_name "$HOST")/$(cm_safe_name "${BRANCH:-detached-${WT##*/}-${HEADSHA:0:12}}")-$(date -u +%Y%m%dT%H%M%SZ)"
  # shellcheck disable=SC2088  # display only: the remote side expands $HOME
  SALVAGE_DIR="~/.concertmaster/$SALVAGE_REL"
  [ "$BEADS_WHOLE" -eq 0 ] || plan "copy the WHOLE .beads dir to $SALVAGE_DIR/beads-whole (on $HOST), verified, before anything is removed; log '$BEADS_OK_REASON' and the open-bead count of a migrated copy ($([ "$BCOPY_ST" = ok ] && echo "$BCOPY_OPEN" || echo "unknown")) to $CM_HOME/teardown-beads-unreadable.log"
  [ -z "${PRECIOUS:-}" ] || plan "salvage $(printf '%s\n' "$PRECIOUS" | grep -c .) ignored path(s) to $SALVAGE_DIR (on $HOST)"
fi
if [ -n "${BDRT:-}" ]; then
  BDRT_PLAN="remove untracked bd runtime files, then require git status clean: $(printf '%s\n' "$BDRT" | tr '\n' ' ')"
fi
if [ -n "$CODEX_PIDS" ]; then
  plan "stop leftover codex processes on $HOST by exact pid, children first (TERM, wait up to ${CODEX_WAIT}s, then KILL): $CODEX_PIDS"
fi
if [ -n "$SB_STOP" ]; then
  while IFS= read -r _s; do
    [ -z "$_s" ] || plan "supabase stop --project-id ${_s%% *} on $HOST, before the worktree is removed (stack $_s; data volumes are kept)"
  done <<<"$SB_IDS_DESC"
fi
if [ -n "$ROW" ]; then
  [ -z "${BDRT_PLAN:-}" ] || plan "$BDRT_PLAN"
  plan "$ORCA worktree rm --worktree id:$WID --json ${ENVF}"
  if [ "$DETACHED" -eq 1 ]; then plan "(detached: no branch to delete)"; else plan "(Orca deletes branch ${BRANCH:-n/a} only if it can prove it merged)"; fi
elif [ "$GITOK" -eq 1 ]; then
  [ -z "${BDRT_PLAN:-}" ] || plan "$BDRT_PLAN"
  plan "git -C ${MAINDIR:-?} worktree remove $WT"
  if [ -n "${BRANCH:-}" ] && [ -n "$MERGED_PR" ]; then
    if [ "$HEADSHA" = "$MERGED_HEAD" ]; then
      plan "git -C ${MAINDIR:-?} branch -d $BRANCH  (fallback -D: tip equals merged PR #$MERGED_PR head)"
    else
      plan "git -C ${MAINDIR:-?} branch -d $BRANCH  (no -D fallback: tip differs from merged PR head)"
    fi
  else
    plan "keep branch ${BRANCH:-(detached)}: no merged PR"
  fi
fi
[ "$HOST" = local ] || [ -n "$ROW" ] || plan "(git steps run over: ssh $SSH_TARGET)"
[ "$DETACHED" -ne 1 ] || plan "(detached HEAD retired on the child's own cm:retire request; clean tree, no stash, nothing precious unsalvaged)"
[ "$NOPR_LEAD" -ne 1 ] || plan "(no PR: retired on the child's own cm:retire request, 0 commits ahead of origin/${DEFB:-main})"
[ "$OWNER_MODE" -ne 1 ] || [ -z "$CLOSE_FIRST" ] || plan "(the rival scan repeats on the re-run after the terminals close; a claim then stops it before anything is removed)"
plan "mc-emit.sh worktree.teardown \"$HOST:$WT\""

if [ -n "$REFUSALS" ]; then
  printf 'REFUSED:\n%s' "$REFUSALS"
  exit 3
fi
printf 'plan:\n%s' "$PLAN"
if [ "$MODE" = dry-run ]; then
  printf 'dry-run: nothing changed. Re-run with --apply to act.\n'
  exit 0
fi

# ---- apply -------------------------------------------------------------------
fail() { printf 'APPLY FAILED at: %s\n' "$*" >&2; exit 4; }
# Agent terminals close BEFORE the proof that counts: close them, then re-run
# this script with them closed, so the beads read, every gate and the salvage
# copy see a worktree no agent can still write to. The re-run refuses (exit 3)
# if a terminal or a non-shell process survived the close; nothing is removed.
if [ -n "$CLOSE_FIRST" ]; then
  [ "$TERMS_CLOSED" != 1 ] || fail "terminals still listed on the re-run after closing them"
  for h in $HANDLES; do
    orca_cmd terminal close --terminal "$h" --json >/dev/null || fail "terminal close $h (nothing removed)"
  done
  printf 'closed terminals: %s; re-checking with them closed\n' "$(printf '%s\n' "$HANDLES" | tr '\n' ' ')"
  sleep 2
  CM_TD_TERMINALS_CLOSED=1 exec bash "$HERE/$(basename -- "$0")" "${ORIG_ARGS[@]}"
fi
# Stop the leftover codex processes (chosen above, re-read now) by exact pid while the worktree still
# exists, BEFORE the salvage copy so nothing they write after it is lost (and before the beads read of the
# apply run, which happens on the re-run with the terminals closed): children first, TERM, a bounded wait, then KILL for the survivors. Fixed script, the worktree and
# the pids arrive as arguments; each pid is re-checked (alive, cwd still inside the worktree) right before
# it is signalled, so a pid reused since the scan is left alone. A process that survives KILL fails the
# teardown before anything is removed.
# shellcheck disable=SC2016
CODEX_STOP_SH='wt=$1; wait=$2; shift 2
alive() { s=$(ps -o stat= -p "$1" 2>/dev/null) || return 1; case "$s" in ""|Z*) return 1 ;; esac; return 0; }
inside() {
  if [ -d /proc/self ]; then c=$(readlink "/proc/$1/cwd" 2>/dev/null) || return 1
  else c=$(lsof -a -w -p "$1" -d cwd -Fn 2>/dev/null | sed -n "s/^n//p" | head -n 1); fi
  case "$c" in "$wt"|"$wt"/*) return 0 ;; esac
  return 1
}
sent=""; exited=""
for p in "$@"; do
  if ! alive "$p"; then exited="$exited $p"   # gone already (a parent that left with its child): nothing to signal
  elif inside "$p"; then kill -TERM "$p" 2>/dev/null; sent="$sent $p"; fi
done
i=0
while [ "$i" -lt "$wait" ]; do
  left=""; for p in $sent; do alive "$p" && left="$left $p"; done
  [ -n "$left" ] || break
  sleep 1; i=$((i + 1))
done
killed=""
for p in $sent; do alive "$p" && inside "$p" && { kill -KILL "$p" 2>/dev/null; killed="$killed $p"; }; done
j=0
while [ -n "$killed" ] && [ "$j" -lt 5 ]; do
  left=""; for p in $killed; do alive "$p" && left="$left $p"; done
  [ -n "$left" ] || break
  sleep 1; j=$((j + 1))
done
for p in "$@"; do
  case " $exited " in *" $p "*) echo "TERMED $p"; continue ;; esac
  case " $sent " in *" $p "*) ;; *) continue ;; esac
  if alive "$p"; then echo "SURVIVED $p"
  else case " $killed " in *" $p "*) echo "KILLED $p" ;; *) echo "TERMED $p" ;; esac; fi
done'
stop_codex_leftovers() {
  [ "$CODEX_OK" -eq 1 ] || return 0
  local planned="$CODEX_PIDS"
  codex_targets
  if [ "$CODEX_OK" -eq 0 ]; then
    # The plan exempted these pids from the process gate on the strength of the stop: if it cannot run, nothing is removed.
    [ -z "$planned" ] || fail "could not re-read the process list on $HOST to stop leftover codex processes ($planned; nothing removed)"
    cm_warn "teardown: could not re-read the process list on $HOST; leftover codex processes not stopped"; return 0
  fi
  [ -n "$CODEX_PIDS" ] || return 0
  local out rc=0 termed="" killed="" surv="" pass t k
  # Two passes: a codex parent can fork a helper after the first snapshot, so the list is read again once the
  # first stop is done and anything new is stopped the same way. A pid left after the second pass is a survivor.
  for pass in 1 2; do
    rc=0   # per pass: a failed first call must not fail the teardown when the second pass stopped everything
    # shellcheck disable=SC2086  # CODEX_PIDS is a list of numeric pids
    out="$(RRUN_SECS=$((CODEX_WAIT + 40)) rrun "$CODEX_STOP_SH" "$WT" "$CODEX_WAIT" $CODEX_PIDS 2>/dev/null)" || rc=$?
    t="$(printf '%s\n' "$out" | awk '$1 == "TERMED" { printf "%s ", $2 }' | sed 's/ $//')"
    k="$(printf '%s\n' "$out" | awk '$1 == "KILLED" { printf "%s ", $2 }' | sed 's/ $//')"
    surv="$(printf '%s\n' "$out" | awk '$1 == "SURVIVED" { printf "%s ", $2 }' | sed 's/ $//')"
    termed="${termed:+$termed }$t"; killed="${killed:+$killed }$k"
    [ -z "$surv" ] || break
    [ "$pass" -eq 1 ] || break
    codex_targets
    # Nothing left on the re-read: whatever the first call reported, there is nothing to fail about.
    if [ "$CODEX_OK" -eq 1 ] && [ -z "$CODEX_PIDS" ]; then rc=0; break; fi
    [ "$CODEX_OK" -eq 1 ] || break
  done
  termed="${termed% }"; killed="${killed% }"
  [ -z "$termed" ] || printf 'stopped codex processes on %s by pid (TERM): %s\n' "$HOST" "$termed"
  [ -z "$killed" ] || printf 'stopped codex processes on %s by pid (KILL after %ss): %s\n' "$HOST" "$CODEX_WAIT" "$killed"
  [ -z "$surv" ] || fail "codex process(es) still running after KILL: $surv (nothing removed)"
  [ "$rc" -eq 0 ] || fail "stopping codex processes (rc=$rc; nothing removed)"
  return 0
}
stop_codex_leftovers

if [ "$BEADS_WHOLE" -eq 1 ] && [ -n "$SALVAGE_DIR" ]; then
  # The store bd could not read is copied out WHOLE (its Dolt dir, backups, config,
  # issues.jsonl), then compared, so a later migration or an old bd can still read it.
  # Plain cp and diff only: nothing here opens the store, nothing writes to it.
  # shellcheck disable=SC2016
  BW_OUT="$(RRUN_SECS=600 rrun "$SALVAGE_VERIFY_FN"'rel=$1; wt=$2
[ -L "$wt/.beads" ] && exit 3
[ -d "$wt/.beads" ] || { echo none; exit 0; }
dest="$HOME/.concertmaster/$rel/beads-whole"
mkdir -p -- "$dest" && cp -Rp -- "$wt/.beads/." "$dest/" || exit 1
sn=$(find "$wt/.beads" -type f 2>/dev/null | wc -l); dn=$(find "$dest" -type f 2>/dev/null | wc -l)
[ "$sn" -eq "$dn" ] || { echo "count mismatch on .beads: $sn vs $dn" >&2; exit 2; }
cm_same "$wt/.beads" "$dest" || { echo "content mismatch on .beads" >&2; exit 2; }
echo copied' "$SALVAGE_REL" "$WT")" \
    || fail "whole .beads copy or verification (nothing removed)"
  BW_DIR="$SALVAGE_DIR/beads-whole"
  if [ "$BW_OUT" = copied ]; then
    printf 'salvaged the whole .beads dir to %s on %s\n' "$BW_DIR" "$HOST"
  else
    BW_DIR=""
    printf 'no .beads dir in the worktree: nothing to copy out\n'
  fi
  BLOG="$CM_HOME/teardown-beads-unreadable.log"
  ( umask 077 && mkdir -p -- "$CM_HOME" && jq -cn --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg host "$HOST" --arg path "$WT" \
      --arg branch "${BRANCH:-}" --arg reason "$BEADS_OK_REASON" --arg bd "$BBD_ERR" --arg salvage "$BW_DIR" \
      --arg copy "${BCOPY_ST:-not-run}" --arg open "$BCOPY_OPEN" --arg cerr "$BCOPY_ERR" \
      '{at:$at, host:$host, path:$path, branch:$branch, reason:$reason, bdError:$bd, salvage:$salvage,
        copyRead:$copy, openBeads:(if $open == "" then null else ($open | tonumber) end), copyReadError:$cerr}' >> "$BLOG" ) \
    || fail "log write to $BLOG (nothing removed; the .beads copy is kept at ${BW_DIR:-n/a} on $HOST)"
  printf 'logged --beads-unreadable-ok reason (open beads on a migrated copy: %s) to %s\n' "${BCOPY_OPEN:-unknown}" "$BLOG"
fi
if [ -n "$SALVAGE_DIR" ] && [ -n "${PRECIOUS:-}" ]; then
  # Fixed script; salvage dir, worktree and every path arrive as arguments.
  set --
  while IFS= read -r p; do [ -n "$p" ] && set -- "$@" "$p"; done <<EOF_PRECIOUS
$PRECIOUS
EOF_PRECIOUS
  # A copy of a Dolt store can take a while over ssh: 10 minutes, not 20s.
  # shellcheck disable=SC2016
  RRUN_SECS=600 rrun "$SALVAGE_VERIFY_FN"'rel=$1; wt=$2; shift 2
dest="$HOME/.concertmaster/$rel"
mkdir -p -- "$dest" && cd -- "$wt" || exit 1
for p in "$@"; do
  mkdir -p -- "$dest/$(dirname -- "./$p")" && cp -Rp -- "./$p" "$dest/$p" || exit 1
done
for p in "$@"; do
  sn=$(find "./$p" -type f 2>/dev/null | wc -l); dn=$(find "$dest/$p" -type f 2>/dev/null | wc -l)
  [ "$sn" -eq "$dn" ] || { echo "count mismatch on $p: $sn vs $dn" >&2; exit 2; }
  cm_same "./$p" "$dest/$p" || { echo "content mismatch on $p" >&2; exit 2; }
done' "$SALVAGE_REL" "$WT" "$@" || fail "salvage copy or verification (nothing removed)"
  printf 'salvaged to %s on %s\n' "$SALVAGE_DIR" "$HOST"
fi
# Untracked bd runtime files make git (and Orca, without --force) refuse to
# remove the worktree. They are always salvaged first (the refusal above
# guarantees it), and the agent terminals are already closed. Delete exactly
# those paths, re-validated against the allow-list on the host, with the bd
# budget over ssh; then every path must be gone and git status empty. A
# partial delete stops loudly, worktree left in place, salvage kept.
rm_bd_runtime() {
  [ -n "${BDRT:-}" ] || return 0
  set --
  while IFS= read -r p; do [ -n "$p" ] && set -- "$@" "$p"; done <<EOF_BDRT
$BDRT
EOF_BDRT
  # shellcheck disable=SC2016
  RM_BDRT_SCRIPT='wt=$1; shift
cd -- "$wt" || exit 1
[ -L .beads ] && exit 3
for p in "$@"; do
  case "$p" in *..*) exit 2 ;; esac
  case "$p" in
    .beads.gate.lock|.beads/dolt.gate.lock|.beads/embeddeddolt.gate.lock|.beads/backup.lock) ;;
    .beads/embeddeddolt|.beads/backup|.beads/embeddeddolt/*|.beads/backup/*) ;;
    *) exit 2 ;;
  esac
done
rc=0
for p in "$@"; do rm -rf -- "./${p:?}" || rc=1; done
for p in "$@"; do if [ -e "./$p" ] || [ -L "./$p" ]; then printf "%s\n" "$p"; rc=1; fi; done
exit "$rc"'
  [ -n "$SALVAGE_DIR" ] || fail "bd runtime files present but not salvaged (nothing removed)"
  LEFT="$(RRUN_SECS="${BD_SECS:-90}" rrun "$RM_BDRT_SCRIPT" "$WT" "$@" 2>/dev/null)"
  case $? in
    0) ;;
    2|3) fail "bd runtime path refused by the allow-list on $HOST (nothing removed)" ;;
    *) fail "bd runtime files only partly removed (still present: $(printf '%s\n' "$LEFT" | tr '\n' ' ')); worktree left in place, salvage kept at $SALVAGE_DIR on $HOST" ;;
  esac
  LEFT="$(g --no-optional-locks status --porcelain 2>/dev/null)" || fail "git status after removing bd runtime files (salvage kept at $SALVAGE_DIR)"
  [ -z "$LEFT" ] || fail "tree not clean after removing bd runtime files: $(printf '%s\n' "$LEFT" | head -n 3 | tr '\n' ' ') (salvage kept at $SALVAGE_DIR)"
  printf 'removed untracked bd runtime files: %s\n' "$(printf '%s\n' "$BDRT" | tr '\n' ' ')"
}
# Stop this worktree's local Supabase stack(s) (chosen in the checks above) while the worktree still
# exists. `supabase stop` WITHOUT --no-backup: that flag also deletes the data volumes, an irreversible
# step the leak does not need. The leak is the running containers (CPU, ports, memory); stopping them
# fixes it and keeps the volumes, so a stack stopped by mistake can be started again. Data loss cannot
# be shown to be irrelevant here (a shared default id keys its volume by that id), so the volumes stay.
# Run from / so nothing holds the worktree as a cwd. A failed stop is a warning, never a failed
# teardown: the worktree is still safe to remove and the census flags a stack left behind.
stop_sb_stacks() {
  local sid left
  [ -n "$SB_STOP" ] || return 0
  while IFS= read -r sid; do
    [ -n "$sid" ] || continue
    # shellcheck disable=SC2016
    if RRUN_SECS=180 rrun "$CM_REMOTE_PATH_FIX"'; cd / && exec supabase stop --project-id "$1"' "$sid" >/dev/null 2>&1; then
      printf 'stopped supabase stack %s on %s\n' "$sid" "$HOST"
      # Exit 0 is not proof: look for containers of that id still running, and say so (the census is the backstop).
      left="$(RRUN_SECS=60 rrun "$CM_REMOTE_PATH_FIX"'; docker ps -q --filter "label=com.supabase.cli.project=$1" 2>/dev/null | head -n 1' "$sid" 2>/dev/null)" || left=""
      [ -z "$left" ] || printf 'WARNING supabase stack %s still has running containers on %s after the stop\n' "$sid" "$HOST"
    else
      cm_warn "teardown: supabase stop --project-id $sid failed on $HOST; the stack may still be running"
      printf 'WARNING supabase stack %s may still be running on %s (stop failed)\n' "$sid" "$HOST"
    fi
  done <<<"$SB_STOP"
}
stop_sb_stacks
if [ -n "$ROW" ]; then
  # Keep the comment (open follow-up lines, notes): Orca drops it with the worktree.
  CMT="$(printf '%s' "$ROW" | jq -r '.comment // ""')"
  if [ -n "$CMT" ]; then
    CMT_NAME="$(printf '%s' "$ROW" | jq -r '.displayName // empty')"
    [ -n "$CMT_NAME" ] || CMT_NAME="${WT##*/}"
    CMT_DIR="$CM_HOME/salvage/comments/$(cm_safe_name "$HOST")"
    CMT_FILE="$CMT_DIR/$(cm_safe_name "${CMT_NAME:0:100}")-$(date -u +%Y%m%dT%H%M%SZ)-$$.txt"
    ( umask 077 && mkdir -p -- "$CMT_DIR" && set -C && printf '%s\n' "$CMT" > "$CMT_FILE" ) 2>/dev/null \
      && chmod 600 "$CMT_FILE" 2>/dev/null \
      || fail "comment archive (nothing removed)"
  fi
  rm_bd_runtime
  orca_cmd worktree rm --worktree "id:$WID" --json || fail "orca worktree rm"
else
  rm_bd_runtime
  if [ "$HOST" = local ]; then
    git -C "$MAINDIR" worktree remove "$WT" || fail "git worktree remove"
    if [ -n "${BRANCH:-}" ] && [ -n "$MERGED_PR" ]; then
      git -C "$MAINDIR" branch -d "$BRANCH" 2>/dev/null \
        || { [ "$HEADSHA" = "$MERGED_HEAD" ] && git -C "$MAINDIR" branch -D "$BRANCH"; } \
        || printf 'note: kept branch %s (git refused -d and tip != merged head)\n' "$BRANCH"
    fi
  else
    WT_KEEP="$WT"; WT="$MAINDIR"
    g worktree remove "$WT_KEEP" || fail "git worktree remove (ssh)"
    if [ -n "${BRANCH:-}" ] && [ -n "$MERGED_PR" ]; then
      g branch -d "$BRANCH" 2>/dev/null \
        || { [ "$HEADSHA" = "$MERGED_HEAD" ] && g branch -D "$BRANCH"; } \
        || printf 'note: kept branch %s\n' "$BRANCH"
    fi
    WT="$WT_KEEP"
  fi
fi
"$HERE/mc-emit.sh" worktree.teardown "teardown $HOST:$WT" \
  "$(jq -cn --arg host "$HOST" --arg path "$WT" --arg branch "${BRANCH:-}" --arg pr "$MERGED_PR" \
      '{host:$host, path:$path, branch:$branch, mergedPr:$pr}')" >/dev/null 2>&1 || true
printf 'done: %s on %s torn down\n' "$WT" "$HOST"
