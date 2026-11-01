#!/usr/bin/env bash
# classify-other-project.sh (test): rule 3 of the census-to-zero work. Rows that are not this project
# get class other-project: another repo, or a never_touch name (exact, never a prefix). A row of THIS
# repo on that list is other-project only while its git is known and clean (dirty, unpushed or unknown
# git keeps its own class, so no work hides). A clean git-only worktree of this repo with no Orca row,
# ledger worker or PR is an untracked-lane, counted as an orphan. Synthetic names only; mktemp dir.
#
#   scripts/test/classify-other-project.sh     # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-otherproj.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap 'rm -rf -- "${ROOT:?}"' EXIT
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { echo "missing dependency: yq" >&2; exit 1; }
export CM_HOME="$ROOT"
unset CM_ORG CM_REPO CM_PROJECT CM_OWNER_NAME CM_OWNER_ID CM_TZ CM_TZ_LABEL CM_EXCLUDE_REPOS CM_PATH_MATCH CM_SELF_WORKTREE

cat > "$ROOT/scoped.yaml" <<'Y'
schema: concertmaster.config/v1
worktrees:
  orca_repo: acme-app
  self_name: concertmaster
  never_touch: [tool-x, tool-y, tool-z, tool-w, mc]
ownership:
  leads: { lead-a: lane-a }
  comment_markers: ["workers i own"]
  comment_stop_words: []
  prefixes: { lane-: lane-a }
Y
cat > "$ROOT/unscoped.yaml" <<'Y'
schema: concertmaster.config/v1
Y
cat > "$ROOT/ledger.json" <<'J'
{"workers": {"w-kept": {"host": "host-a", "path": "/w/git-kept", "standing": true}}}
J

NOW=1791600000000; OLD=$((NOW - 600000))
row() { # row <host> <name> <repo> <extra-json>
  jq -cn --arg h "$1" --arg n "$2" --arg repo "$3" --argjson x "${4:-{\}}" --argjson old "$OLD" '
    ({host: $h, path: ("/w/" + $n), displayName: $n, repo: $repo, status: "idle", comment: "", source: "orca",
      worktreeId: null, isMainWorktree: false, childWorktreeIds: [], inOrca: true, liveTerminalCount: 0,
      agents: [], lastOutputAt: $old, lastActivityAt: $old,
      git: {exists: true, statusOk: true, dirty: 0, unpushed: 0}, pr: null}) + $x'
}
UNK='{"git": null}'                    # remote host: git state not collected
DIRTY='{"git": {"exists": true, "statusOk": true, "dirty": 3, "unpushed": 0}}'
GITONLY='{"source": "git", "inOrca": false}'
{
  row host-a lane-a1 acme-app "$UNK"                        # in scope, unknown-git: stays unknown-git
  row host-a lane-b1 other-app "$UNK"                       # another repo
  row host-a other-dirty other-app "$DIRTY"                 # another repo, dirty
  row host-a tool-x-1 acme-app "$DIRTY"                     # only a PREFIX of a never_touch name: a normal lane, not exempt
  row host-a tool-x acme-app "$DIRTY"                       # never_touch exact, project repo, dirty: must stay visible
  row host-a tool-y acme-app "$UNK"                         # never_touch exact, project repo, git unknown: must stay visible
  row host-a tool-z acme-app                                # never_touch exact, project repo, clean: other-project
  row host-b mc acme-app                                    # never_touch exact, clean
  row host-a plain-wt acme-app "$GITONLY"                   # plain git worktree, nothing claims it
  row host-a git-kept acme-app "$GITONLY"                   # git-only but a ledger worker: stays a lane
  row host-a git-unpushed acme-app '{"source": "git", "inOrca": false, "git": {"exists": true, "statusOk": true, "dirty": 0, "unpushed": 2}}'
  row host-a git-dirty acme-app '{"source": "git", "inOrca": false, "git": {"exists": true, "statusOk": true, "dirty": 3, "unpushed": 0}}'
  row host-a git-unproven acme-app '{"source": "git", "inOrca": false, "git": {"exists": true, "statusOk": true, "dirty": 3, "unpushed": null}}'
  row host-a git-merged acme-app '{"source": "git", "inOrca": false, "pr": {"number": 8, "state": "MERGED"}}'
  row host-a git-pr acme-app '{"source": "git", "inOrca": false, "pr": {"number": 9, "state": "OPEN"}}'
  row host-a other-main other-app '{"isMainWorktree": true}'
  row host-a tool-w acme-app '{"liveTerminalCount": 1, "agents": [{"state": "working", "paneKey": "p2", "updatedAt": '"$((NOW - 60000))"'}], "git": {"exists": true, "statusOk": false, "dirty": null, "unpushed": null}}'   # never_touch exact, live agent, git unproven
  row host-a lane-live acme-app '{"liveTerminalCount": 1, "agents": [{"state": "working", "paneKey": "p1", "updatedAt": '"$((NOW - 60000))"'}]}'
} | jq -s --argjson now "$NOW" '{generatedAtMs: $now, generatedAt: "t",
      hosts: [{name: "host-a", reachable: true}, {name: "host-b", reachable: true}, {name: "host-c", reachable: false, error: "down"}], worktrees: .}' > "$ROOT/discover.json"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
cls() { jq -r --arg n "$1" '.items[] | select(.path == ("/w/" + $n)) | .class' <<< "$OUT"; }
flag() { jq -r --arg n "$1" --arg f "$2" '.items[] | select(.path == ("/w/" + $n)) | (.flags | index($f) != null) | tostring' <<< "$OUT"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2' want '$3'"; fi; }

OUT="$(CM_CONFIG="$ROOT/scoped.yaml" "$HERE/../classify.sh" < "$ROOT/discover.json" 2>/dev/null)" || { echo "classify.sh failed"; exit 1; }
eq "in-scope remote row with no git is still unknown-git"             "$(cls lane-a1)" unknown-git
eq "another repo is other-project (even with unknown git)"            "$(cls lane-b1)" other-project
eq "another repo, dirty tree, is other-project not dirty-or-unpushed" "$(cls other-dirty)" other-project
eq "a never_touch PREFIX (tool-x-1) is not exempt: dirty stays visible"   "$(cls tool-x-1)" dirty-or-unpushed
eq "never_touch exact, project repo, dirty: dirty-or-unpushed (not hidden)" "$(cls tool-x)" dirty-or-unpushed
eq "never_touch exact, project repo, git unknown: unknown-git (not hidden)"  "$(cls tool-y)" unknown-git
eq "never_touch exact, live agent, git unproven: stays running, not hidden" "$(cls tool-w)" running
eq "never_touch exact, project repo, clean: other-project"                    "$(cls tool-z)" other-project
eq "never_touch exact name (mc), clean: other-project"                      "$(cls mc)" other-project
eq "plain git worktree, no Orca row, no ledger, no PR: untracked-lane"      "$(cls plain-wt)" untracked-lane
eq "untracked-lane is counted as an orphan"                                  "$(flag plain-wt ORPHAN)" true
eq "git-only worktree with a MERGED PR stays a teardown candidate"          "$(cls git-merged)" done-merged
eq "git-only worktree with a ledger worker is not other-project"      "$(cls git-kept)" standing-dead
eq "git-only worktree with unpushed commits stays visible (dirty-or-unpushed)" "$(cls git-unpushed)" dirty-or-unpushed
eq "git-only worktree with unpushed commits is flagged ORPHAN"        "$(flag git-unpushed ORPHAN)" true
eq "git-only worktree with a dirty tree stays visible (dirty-or-unpushed)" "$(cls git-dirty)" dirty-or-unpushed
eq "git-only worktree whose git check failed is unknown-git, not other-project" "$(cls git-unproven)" unknown-git
eq "git-only worktree with an open PR is not other-project"           "$(cls git-pr)" orphan-git-only
eq "another repo's main checkout stays main-checkout"                 "$(cls other-main)" main-checkout
eq "a live in-scope worktree is untouched"                            "$(cls lane-live)" running
eq "other-project is never flagged ORPHAN (another repo)"             "$(flag lane-b1 ORPHAN)" false
eq "an offline host still yields its host-offline row"                "$(jq -r '[.items[] | select(.class == "host-offline")] | length' <<< "$OUT")" 1
eq "ownership orphans leave other-project out (lane-a1, git-pr, lane-live are the only in-scope unowned or owned rows)" \
   "$(jq -r '.items | map(select(.class == "other-project" and (.flags | index("ORPHAN")))) | length' <<< "$OUT")" 0
eq "summary counts other-project apart (4 rows)"                      "$(jq -r '.summary["other-project"]' <<< "$OUT")" 4
TABLE="$(CM_CONFIG="$ROOT/scoped.yaml" "$HERE/../classify.sh" --table < "$ROOT/discover.json" 2>/dev/null)"
case "$TABLE" in *other-project*) ok "--table lists the other-project rows" ;; *) bad "--table lists the other-project rows" ;; esac

# Without the scope keys nothing is declared out of scope by repo or name; the git-only rule needs ownership.
OUT="$(CM_CONFIG="$ROOT/unscoped.yaml" "$HERE/../classify.sh" < "$ROOT/discover.json" 2>/dev/null)" || { echo "classify.sh failed"; exit 1; }
eq "no scope config: another repo is not reclassified"                "$(cls lane-b1)" unknown-git
eq "no ownership config: a plain git worktree stays orphan-git-only"  "$(cls plain-wt)" orphan-git-only

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
