#!/usr/bin/env bash
# classify-standing.sh: behaviour tests for classify's ledger-only standing
# rules. Feeds a synthetic discover document and ledger to classify.sh and
# checks each item's class and suggest. Touches nothing outside a mktemp dir.
#
#   scripts/test/classify-standing.sh         # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# Hermetic config: never the project config.yaml next to scripts/.
export CM_CONFIG="$HERE/fixtures/config.test.yaml"
unset CM_ORG CM_REPO CM_PROJECT CM_OWNER_NAME CM_OWNER_ID CM_TZ CM_TZ_LABEL CM_EXCLUDE_REPOS CM_PATH_MATCH CM_SELF_WORKTREE
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-classify.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap 'rm -rf -- "${ROOT:?}"' EXIT
export CM_HOME="$ROOT"
cat > "$ROOT/ledger.json" <<'J'
{"lanes": {"dev-sweeper": {"lead": "w-lead"}, "pr-sweeper": "running"},
 "workers": {
  "w-lead":   {"host": "local", "path": "/x/dev-lane"},
  "w-sweep":  {"host": "local", "path": "/x/pr-sweep/", "standing": true},
  "w-single": {"host": "local", "path": "/x/research-ota-cost", "standing": false},
  "w-epic":   {"host": "local", "path": "/x/ops-e", "standing": false, "beadsEpic": "t-ep1"},
  "w-null":   {"host": "local", "path": "/x/ops-null", "standing": null},
  "w-ldm":    {"host": "local", "path": "/elsewhere", "worktreeId": "repo::ldm", "standing": true, "beadsEpic": "acme-epic1"},
  "w-old":    {"host": "local", "path": "/x/reused", "standing": true, "state": "gone"},
  "w-new":    {"host": "local", "path": "/x/reused", "standing": false},
  "w-hung":   {"host": "local", "path": "/x/hung-lead", "standing": true},
  "w-dead":   {"host": "local", "path": "/x/dead-lead", "standing": true},
  "w-deadpr": {"host": "local", "path": "/x/dead-pr", "standing": true},
  "w-orphan": {"host": "local", "path": "/x/orphan-lead", "standing": true},
  "w-keptlane": {"host": "local", "path": "/x/kept-lane", "standing": true},
  "w-retlane": {"host": "local", "path": "/x/ret-lane", "standing": true},
  "w-keepalive": {"host": "local", "path": "/x/keepalive", "standing": false},
  "w-retlive": {"host": "local", "path": "/x/ret-live", "standing": false},
  "w-retired": {"host": "local", "path": "/x/retired", "standing": false}}}
J
NOW=1791600000000; OLD=$((NOW - 3600000))
item() { # item <path> <name> <status> <agent-state> <comment> <pr-state> [worktreeId] [source]
  jq -cn --arg p "$1" --arg n "$2" --arg s "$3" --arg a "$4" --arg c "$5" --arg pr "$6" \
    --arg id "${7:-}" --arg src "${8:-orca}" --argjson old "$OLD" '
    {host: "local", path: $p, displayName: $n, status: $s, comment: $c, source: $src,
     worktreeId: (if $id == "" then null else $id end), isMainWorktree: false, childWorktreeIds: [],
     agents: (if $a == "" then [] else [{state: $a, paneKey: "p1", updatedAt: $old}] end),
     lastOutputAt: $old, lastActivityAt: $old,
     git: {exists: true, statusOk: true, dirty: 0, unpushed: 0},
     pr: (if $pr == "" then null else {number: 7, state: $pr} end)}'
}
{
  item /x/pr-sweep pr-sweep idle "done" "" MERGED
  item /x/dev-lane dev-lane waiting waiting "cm:idle 0 open beads" ""
  item /x/hung-lead hung-lead working working "cm:idle 0 open beads" ""
  item /x/research-ota-cost research-ota-cost idle "done" "" MERGED
  item /x/ops-e ops-e idle "done" "" MERGED
  item /x/ops-null ops-null idle "done" "" MERGED
  item /x/unknown-sweeper unknown-sweeper idle "done" "" MERGED
  item /x/ldm feature-demo-sweeper idle "done" "cm:done all picked items" OPEN repo::ldm
  item /x/reused reused idle "done" "" MERGED
  item /x/dead-lead dead-lead idle "" "cm:idle 0 open beads" ""
  item /x/dead-pr dead-pr idle "" "" OPEN
  item /x/orphan-lead orphan-lead idle "" "" "" "" git
  item /x/retired retired idle "" "cm:retire helper finished" ""
  item /x/kept-lane kept-lane idle "" "cm:keep paused until 2026-11-01" ""
  item /x/ret-lane ret-lane idle "" "cm:retire stale marker" ""
  item /x/keepalive keepalive idle "" "cm:keepalive ping" ""
  item /x/ret-live ret-live working working "cm:retire early" ""
  item /x/kept kept idle "" "cm:keep waiting on pr 7 until 2026-11-01" ""
} | jq -s --argjson now "$NOW" '{generatedAtMs: $now, generatedAt: "t",
      hosts: [{name: "local", reachable: true}], worktrees: .}' > "$ROOT/discover.json"
OUT="$("$HERE/../classify.sh" < "$ROOT/discover.json")" || { echo "classify.sh failed"; exit 1; }

PASS=0; FAIL=0
expect() { # expect <label> <path> <class> <suggest-pattern>
  local got
  got="$(printf '%s' "$OUT" | jq -r --arg p "$2" '.items[] | select(.path == $p) | "\(.class)\t\(.suggest)"')"
  if [ "${got%%	*}" = "$3" ] && printf '%s' "${got#*	}" | grep -q -- "$4"; then
    PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL %s: got "%s"\n' "$1" "$got"
  fi
}
expect "standing:true, merged: standing-idle (trailing slash matched)" /x/pr-sweep standing-idle 'never retire'
expect "lane lead with cm:idle, waiting: standing-idle, not stuck"     /x/dev-lane standing-idle 'never retire'
expect "standing lead hung while working: stuck, respawn in place"    /x/hung-lead stuck 'respawn in place only'
expect "standing:false single-task: teardown"                         /x/research-ota-cost done-merged '^teardown$'
expect "epic owner: beads gate before teardown"                       /x/ops-e done-merged 'beads gate first'
expect "standing:null: unknown, no teardown"                          /x/ops-null done-merged 'standing unknown'
expect "no ledger row (name looks like a sweeper): unknown"           /x/unknown-sweeper done-merged 'standing unknown'
expect "matched by worktreeId, open PR kept for pr-sweeper"           /x/ldm standing-idle 'hand PR #7 to pr-sweeper'
expect "gone record on a reused path ignored"                         /x/reused done-merged '^teardown$'
expect "standing lane with no agent: standing-dead, respawn in place"  /x/dead-lead standing-dead 'respawn in place (claude --continue in its worktree)'
expect "dead standing lane keeps its open PR hand-off"                /x/dead-pr standing-dead 'hand PR #7 to pr-sweeper; respawn in place'
expect "git-only standing lane: standing-dead, never teardown"        /x/orphan-lead standing-dead 'never retire or teardown'
expect "cm:retire, no agent: done, retire like cm:done"               /x/retired done-selfreported 'retire worker'
expect "cm:keep, no agent: standing-idle, chase the owner"            /x/kept standing-idle 'chase the owner'
expect "cm:keep on a standing lane with no agent: still respawned"    /x/kept-lane standing-dead 'respawn in place'
expect "cm:retire on a standing lane: never retired"                  /x/ret-lane standing-dead 'never retire or teardown'
expect "cm:keepalive is not cm:keep"                                  /x/keepalive idle 'adopt or ask'
expect "cm:retire with a live agent keeps its live class"             /x/ret-live stuck 'nudge'
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
