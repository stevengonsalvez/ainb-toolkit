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
#   add --retire-check to run only the ledger, standing and beads gates (the
#     guard before retiring a worker's agent terminal); never acts, and
#     refuses unless the path resolved and a live ledger worker matched
#
# <host> is "local" or an Orca environment name (as listed by `orca host list`).
# Remote git checks run over `ssh $CM_SSH_TARGET` (default: the host name),
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
#     bd runtime state (.beads.gate.lock, .beads/embeddeddolt[.gate.lock],
#     .beads/backup[.lock]) is not dirt. Untracked or ignored, it is always
#     precious: it refuses without --salvage and is copied out with it. On
#     --apply the untracked paths are deleted after the salvage and git status
#     must then be empty
#   - detached HEAD, or a rebase, merge, cherry-pick, revert or bisect in progress
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
#     worktree, unless every such terminal is named with --close-handle
#   - LEDGER: $CM_HOME/ledger.json is missing, empty, not an object with a
#     workers object, or its paths cannot be canonicalised on the host; or no
#     live ledger worker (state not gone/repurposed) matches this host and path
#     (canonical path or Orca worktreeId). No override: adopt it first.
#   - STANDING LANE, from the ledger only: any live worker on the path has
#     "standing": true or is a lanes.<lane>.lead. A "standing" that is not a
#     boolean on any live worker refuses as "standing state unknown". Names are
#     never used to allow or refuse (the owner's rule); a sweeper-looking name
#     with standing:false only prints a note. --force-standing <ask-id>
#     overrides this one refusal and never the beads gate.
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
#     An epic found nowhere, or an open epic with no children, refuses.
#     With no epic: refuses when the worktree holds open beads newer than in
#     every other source (unmerged bead work; --accept-unmerged-beads).
#
# Acts (with --apply), in order:
#   Orca-tracked:  orca terminal close per handle (never --all), then the
#                  script re-runs itself so every check, the beads read and
#                  the salvage happen with those terminals closed (any
#                  refusal then stops it, terminals closed, nothing removed)
#   both:          salvage, then delete the untracked bd runtime files
#                  (allow-listed paths only; each must be gone and git status
#                  empty, else stop with the salvage kept)
#   Orca-tracked:  orca worktree rm (no --force;
#                  Orca deletes the branch only when it can prove it merged)
#   git-only:      git worktree remove (no --force), then git branch -d only
#                  when GitHub says the PR MERGED; -D only when the local tip
#                  equals the merged PR's head sha
# Then emits a worktree.teardown event via mc-emit.sh (fire and forget).
#
# Exit: 0 plan ok / done, 2 usage, 3 refused, 4 an apply step failed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

usage() { sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d'; exit 2; }
[ $# -ge 2 ] || usage
ORIG_ARGS=("$@")
HOST="$1"; WT="$2"; shift 2
MODE=dry-run
ALLOW_NO_PR=0
SALVAGE=0
FORCE_STANDING=""
ACCEPT_BEADS=""
RETIRE_CHECK=0
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
    --retire-check) RETIRE_CHECK=1 ;;
    --close-handle) [ $# -ge 2 ] || usage; CLOSE_HANDLES="$CLOSE_HANDLES$2 "; shift ;;
    --dry-run) MODE=dry-run ;;
    -h|--help) usage ;;
    *) cm_warn "unknown arg: $1"; usage ;;
  esac
  shift
done
IN="$WT"
case "$HOST" in "this machine") HOST=local ;; esac
# Re-run after --apply closed the named terminals: they no longer exempt
# anything, so an agent terminal or process that survived the close refuses.
TERMS_CLOSED="${CM_TD_TERMINALS_CLOSED:-0}"
[ "$MODE" = apply ] || TERMS_CLOSED=0
[ "$TERMS_CLOSED" != 1 ] || CLOSE_HANDLES=" "

ORCA="$(cm_orca)"
SSH_TARGET="${CM_SSH_TARGET:-$HOST}"
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
env_flag() { [ "$HOST" = local ] || printf -- '--environment\n%s\n' "$HOST"; }
orca_cmd() {
  # orca_cmd <args...>: runs Orca against the right host.
  if [ "$HOST" = local ]; then cm_timeout 30 "$ORCA" "$@"
  else cm_timeout 30 "$ORCA" "$@" --environment "$HOST"; fi
}

# Git-ignored file names the project regenerates (config
# worktrees.regenerable_ignored, e.g. deno.lock): never counted as precious.
REGEN_RE=""
for _rn in $(cm_cfg .worktrees.regenerable_ignored); do
  # shellcheck disable=SC2016
  REGEN_RE="$REGEN_RE|(^|/)$(printf '%s' "$_rn" | sed 's/[].[\*^$()+?{|]/\\&/g')\$"
done
# bd runtime paths (relative to the worktree root): the embedded Dolt store,
# its backups and the gate locks bd 1.3 takes around them.
BD_RUNTIME_PATH_RE='^(\.beads\.gate\.lock|\.beads/embeddeddolt\.gate\.lock|\.beads/backup\.lock|\.beads/(embeddeddolt|backup)(/.*)?)$'
BDRT=""

printf 'teardown %s on %s (%s)\n' "$IN" "$HOST" "$MODE"
printf 'checks:\n'

# ---- remote identity ---------------------------------------------------------
if [ "$HOST" != local ]; then
  EXPECT="${CM_SSH_EXPECT_HOSTNAME:-}"
  if [ -z "$EXPECT" ] && [ -r "$CM_HOME/ledger.json" ]; then
    EXPECT="$(jq -r --arg h "$HOST" '.hosts[$h].hostname // empty' "$CM_HOME/ledger.json" 2>/dev/null)"
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
      check unpushed "YES ($UNPUSHED commits on no remote)"
      refuse "unpushed commits ($UNPUSHED)"
    else
      check unpushed "none"
    fi
  else
    check unpushed "UNKNOWN (git rev-list failed)"
    refuse "unpushed check failed: state unknown"
  fi

  # In-progress operations live in the per-worktree git dir.
  # shellcheck disable=SC2016
  if ! INPROG="$(rrun 'cd -- "$1" 2>/dev/null || exit 3
for f in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do [ -e "$f" ] && printf "%s " "$f"; done
exit 0' "$GITDIR" 2>/dev/null)"; then
    check inprogress "UNKNOWN (cannot read git dir $GITDIR)"
    refuse "in-progress check failed: state unknown"
  elif [ -n "$INPROG" ]; then
    check inprogress "YES: $INPROG"
    refuse "git operation in progress ($INPROG): finish or abort it first"
  else
    check inprogress "none"
  fi

  # Ignored files: worktree removal deletes them silently.
  PRECIOUS=""
  if IGN="$(g --no-optional-locks status --ignored --porcelain 2>/dev/null)"; then
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
  BRANCH="$(g symbolic-ref --short -q HEAD 2>/dev/null || true)"
  check branch "${BRANCH:-(detached)} at ${HEADSHA:0:12}"
  [ -n "$BRANCH" ] || refuse "detached HEAD: no branch, so no PR state to prove it safe"
  case "$BRANCH" in */concertmaster|concertmaster) refuse "concertmaster branch: never torn down" ;; esac
fi

# ---- PR state --------------------------------------------------------------
MERGED_PR=""
MERGED_HEAD=""
CLOSED_PR=""
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

# ---- processes with cwd in the worktree --------------------------------------
# Scan cwds on the host (lsof, else /proc) and map each process to its Orca
# terminal through the ORCA_TERMINAL_HANDLE in its environment (/proc environ
# on Linux, ps eww on macOS). A non-shell process is exempt ONLY when its
# handle was named with --close-handle; with no handle (started outside an
# Orca terminal, or the mapping failed) it always refuses.
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

# ---- ledger -------------------------------------------------------------------
# The ledger is the only source of standing and beadsEpic. Every way it can be
# missing, malformed or silent about this worktree refuses (fail closed).
LEDGER="$CM_HOME/ledger.json"
LW=""          # merged view of the live ledger workers on this host + path
LEDGER_OK=0
if [ -n "$WT" ]; then
  if [ ! -s "$LEDGER" ]; then
    check ledger "MISSING or empty ($LEDGER)"
    gate "ledger missing or empty: standing and beads state unknown"
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
                  badEpic: [ $ws[] | select(.beadsEpic != null and ((.beadsEpic | type) != "string" or .beadsEpic == "")) | .id ],
                  epics: ([ $ws[] | .beadsEpic | select(type == "string" and . != "") ] | unique) }' 2>/dev/null)" \
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
if [ -n "$LW" ]; then
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
    case "$(cm_lower "${WT##*/} $DNAME")" in
      *sweep*|*-lead*|epic-*|*" epic-"*|research-*|*" research-"*)
        check standing "no (ledger standing:false; note: name looks like a lane, ledger wins)" ;;
      *) check standing "no (ledger standing:false, single-task worker)" ;;
    esac
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
  DEFB="$(g symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  DEFB="${DEFB#origin/}"
  [ -n "$DEFB" ] || DEFB=main
  case "$DEFB" in
    -*|/*|*/|*//*|*..*|*.lock|*@\{*|*[!A-Za-z0-9._/-]*)
      check beads "UNKNOWN (origin/HEAD names an invalid branch)"
      gate "origin/HEAD names an invalid branch name: refusing to pass it to git"
      DEFB=""; BFETCH=failed ;;
  esac
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
beads_failed() {
  case "$BFETCH $BWT_ST $BMAIN_ST $BRED_ST $BBD_ST" in *failed*) return 0 ;; esac
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
      gate "beadsEpic $EPIC set but a beads source failed ($BSRC): not done"
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
elif [ -n "$LW" ]; then
  # No epic owned: open beads this worktree holds that no other source has at
  # least as new are unmerged bead work.
  if [ "$BWT_ST" = absent ]; then
    check beads "no epic in ledger; no beads in worktree"
  elif beads_failed; then
    check beads "UNKNOWN (no epic in ledger; $BSRC)"
    gate "beads read failed ($BSRC): cannot prove the worktree holds no open bead work"
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
  printf 'retire-check: ok (ledger, standing and beads gates clean; nothing changed)\n'
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
SALVAGE_DIR=""
if [ -n "${PRECIOUS:-}" ] && [ "$SALVAGE" -eq 1 ]; then
  # Relative to ~/.concertmaster on the target host; every component sanitised.
  SALVAGE_REL="salvage/$(cm_safe_name "$HOST")/$(cm_safe_name "${BRANCH:-detached}")-$(date -u +%Y%m%dT%H%M%SZ)"
  # shellcheck disable=SC2088  # display only: the remote side expands $HOME
  SALVAGE_DIR="~/.concertmaster/$SALVAGE_REL"
  plan "salvage $(printf '%s\n' "$PRECIOUS" | grep -c .) ignored path(s) to $SALVAGE_DIR (on $HOST)"
fi
if [ -n "${BDRT:-}" ]; then
  BDRT_PLAN="remove untracked bd runtime files, then require git status clean: $(printf '%s\n' "$BDRT" | tr '\n' ' ')"
fi
if [ -n "$ROW" ]; then
  [ -z "${BDRT_PLAN:-}" ] || plan "$BDRT_PLAN"
  plan "$ORCA worktree rm --worktree id:$WID --json ${ENVF}"
  plan "(Orca deletes branch ${BRANCH:-n/a} only if it can prove it merged)"
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
if [ -n "$SALVAGE_DIR" ]; then
  # Fixed script; salvage dir, worktree and every path arrive as arguments.
  set --
  while IFS= read -r p; do [ -n "$p" ] && set -- "$@" "$p"; done <<EOF_PRECIOUS
$PRECIOUS
EOF_PRECIOUS
  # A copy of a Dolt store can take a while over ssh: 10 minutes, not 20s.
  # shellcheck disable=SC2016
  RRUN_SECS=600 rrun 'rel=$1; wt=$2; shift 2
dest="$HOME/.concertmaster/$rel"
mkdir -p -- "$dest" && cd -- "$wt" || exit 1
for p in "$@"; do
  mkdir -p -- "$dest/$(dirname -- "./$p")" && cp -Rp -- "./$p" "$dest/$p" || exit 1
done
for p in "$@"; do
  sn=$(find "./$p" -type f 2>/dev/null | wc -l); dn=$(find "$dest/$p" -type f 2>/dev/null | wc -l)
  [ "$sn" -eq "$dn" ] || { echo "count mismatch on $p: $sn vs $dn" >&2; exit 2; }
  diff -rq -- "./$p" "$dest/$p" >/dev/null || { echo "content mismatch on $p" >&2; exit 2; }
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
    .beads.gate.lock|.beads/embeddeddolt.gate.lock|.beads/backup.lock) ;;
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
if [ -n "$ROW" ]; then
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
