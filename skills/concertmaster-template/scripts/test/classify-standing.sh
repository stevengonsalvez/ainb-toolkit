#!/usr/bin/env bash
# cm-test: rm-cleanup (its EXIT trap rm -rf-s its own mktemp dir; CM_TEST_KEEP_TMP=1 keeps it)
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
trap '[ "${CM_TEST_KEEP_TMP:-}" = 1 ] && echo "cm-test: CM_TEST_KEEP_TMP set, kept $ROOT" >&2 || rm -rf -- "${ROOT:?}"' EXIT
export CM_HOME="$ROOT"
cat > "$ROOT/ledger.json" <<'J'
{"lanes": {"dev-sweeper": {"lead": "w-lead"}, "pr-sweeper": "running", "unk-lane-label": {"lead": "w-unk-lane"}},
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
  "w-retired": {"host": "local", "path": "/x/retired", "standing": false},
  "w-unk-cap": {"host": "local", "path": "/x/unk-cap", "standing": true, "state": "Asleep"},
  "w-unk-pad": {"host": "local", "path": "/x/unk-pad", "standing": true, "state": "asleep "},
  "w-unk-false": {"host": "local", "path": "/x/unk-false", "standing": true, "state": false},
  "w-unk-num": {"host": "local", "path": "/x/unk-num", "standing": true, "state": 7},
  "w-unk-obj": {"host": "local", "path": "/x/unk-obj", "standing": true, "state": {}},
  "w-unk-lane": {"host": "local", "path": "/x/unk-lane", "state": "Asleep"},
  "w-unk-live": {"host": "local", "path": "/x/unk-live", "standing": true, "state": "Asleep"},
  "w-hb-a": {"host": "local", "path": "/x/host-bad", "standing": false},
  "w-hb-b": {"host": false, "path": "/x/host-bad", "standing": true},
  "w-hb2-a": {"host": "local", "path": "/x/host-bad2", "standing": false},
  "w-hb2-b": {"host": 7, "path": "/x/host-bad2", "standing": true}}}
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
  item /x/unk-cap unk-cap idle "" "" ""
  item /x/unk-pad unk-pad idle "" "" ""
  item /x/unk-false unk-false idle "" "" ""
  item /x/unk-num unk-num idle "" "" ""
  item /x/unk-obj unk-obj idle "" "" ""
  item /x/unk-lane unk-lane idle "" "" ""
  item /x/unk-live unk-live working working "cm:idle 0 open beads" ""
  item /x/host-bad host-bad idle "done" "" MERGED
  item /x/host-bad2 host-bad2 idle "done" "" MERGED
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
# A standing lead, no agent, whose state is not exactly a known state is shown as unknown and never suggested for a respawn.
# A live agent keeps its live class.
for u in unk-cap unk-pad unk-false unk-num unk-obj unk-lane; do
  expect "$u: standing-unknown-state, never respawn, resume, retire or teardown" /x/$u standing-unknown-state 'never respawn, resume, retire or teardown'
  got="$(printf '%s' "$OUT" | jq -r --arg p "/x/$u" '.items[] | select(.path == $p) | .suggest')"
  case "$got" in *"respawn in place"*) FAIL=$((FAIL + 1)); echo "FAIL $u: suggests a respawn: $got" ;; *) PASS=$((PASS + 1)); echo "PASS $u: no respawn suggested" ;; esac
done
expect "control: an unknown state with a live agent keeps its live class" /x/unk-live stuck 'respawn in place only'
# A standing worker whose host is unreadable (false, 7) still counts for its path, so a standing:false sibling on the
# same path never turns the worktree into a single-task teardown
expect "a standing row with host false beside a standing:false sibling: still standing, never teardown" /x/host-bad standing-idle 'never retire, teardown or respawn'
expect "the same with host 7" /x/host-bad2 standing-idle 'never retire, teardown or respawn'
# A live ledger row whose path or worktree id is not text (path false, worktreeId 7), or that is not an object at all, can be matched to no worktree, so it
# could be the row of ANY of them. It was dropped from the match as "a row for another path"; now every worktree reads standing-unknown (no retire, no teardown). Controls: the same
# ledger without the row tears the single-task worker down as before, and a dead record with a wrong-typed path is a dead record, not a hold.
CLS="$HERE/../classify.sh"
cp "$ROOT/ledger.json" "$ROOT/ledger.keep"
for patch in '.workers["w-wild"] = {host: "local", path: false, standing: true}' '.workers["w-wild"] = {host: "local", path: ["/x/ops-e"], standing: true}' \
             '.workers["w-wild"] = {host: "local", path: "/x/wild", worktreeId: 7, standing: true}' '.workers["w-wild"] = false' '.workers["w-wild"] = null'; do
  jq "$patch" "$ROOT/ledger.keep" > "$ROOT/ledger.json"
  OUT="$("$CLS" < "$ROOT/discover.json")" || { echo "classify.sh failed"; exit 1; }
  expect "typed boundary ($patch): a single-task worker is standing unknown, never torn down" /x/research-ota-cost done-merged 'standing unknown'
  expect "typed boundary ($patch): a worktree with no ledger row stays standing unknown" /x/unknown-sweeper done-merged 'standing unknown'
  expect "typed boundary ($patch): a standing lane found by its path keeps its class" /x/pr-sweep standing-idle 'never retire'
done
jq '.workers["w-wild"] = {host: "local", path: false, standing: true, state: "gone"}' "$ROOT/ledger.keep" > "$ROOT/ledger.json"
OUT="$("$CLS" < "$ROOT/discover.json")" || { echo "classify.sh failed"; exit 1; }
expect "typed boundary control: a gone record with a path of the wrong type holds nothing" /x/research-ota-cost done-merged '^teardown$'
cp "$ROOT/ledger.keep" "$ROOT/ledger.json"
OUT="$("$CLS" < "$ROOT/discover.json")" || { echo "classify.sh failed"; exit 1; }
expect "typed boundary control: with no wrong-typed row the worker is torn down" /x/research-ota-cost done-merged '^teardown$'
# A workers that is false or a list, or a key written twice under workers, cannot say which lane stands: every item reads standing unknown AND classify.sh says so on stderr.
DUPCL="$(jq -c . "$ROOT/ledger.keep" | sed 's/"standing":true/"standing":false,"standing":true/')"
if [ "$(grep -c '"standing":false,"standing":true' <<<"$DUPCL")" -ge 1 ]; then PASS=$((PASS + 1)); echo "PASS the repeated-key fixture really has a key written twice"; else FAIL=$((FAIL + 1)); echo "FAIL the repeated-key fixture has no repeated key"; fi
for c in 'workers false|{"workers":false}' 'workers []|{"workers":[]}' 'repeated key|'"$DUPCL"; do
  printf '%s\n' "${c#*|}" > "$ROOT/ledger.json"
  OUT="$("$CLS" < "$ROOT/discover.json" 2>"$ROOT/cls.err")" || { echo "classify.sh failed"; exit 1; }
  expect "ledger gate (${c%%|*}): a single-task worker is standing unknown, never torn down" /x/research-ota-cost done-merged 'standing unknown'
  if [ "$(grep -c 'cannot be read as a worker map' "$ROOT/cls.err")" = 1 ]; then PASS=$((PASS + 1)); echo "PASS ledger gate (${c%%|*}): classify.sh says the ledger cannot be read as a worker map"; else FAIL=$((FAIL + 1)); echo "FAIL ledger gate (${c%%|*}): classify.sh did not say it"; fi
done
cp "$ROOT/ledger.keep" "$ROOT/ledger.json"
# mutant for the ledger gate itself: a copy (cp -R, so scripts/jdupkeys comes along) in which classify.sh reads the ledger without cm_workers_gate. jq keeps the last of two equal keys, so a ledger the
# gate holds on reads as an ordinary one and the single-task worker is TORN DOWN (the harm), and the repeated-key case above is caught. (A workers that is false or a list is held a second time by classify.jq itself,
# so only the repeated key shows the gate's own effect.)
mkdir -p "$ROOT/mut-gate" && cp -R "$HERE"/../. "$ROOT/mut-gate"/
perl -pi -e 's/if LEDGER_WHY="\$\(cm_workers_gate "\$LEDGER"\)"; then LEDGER_ARGS/if LEDGER_WHY=""; then LEDGER_ARGS/' "$ROOT/mut-gate/classify.sh"
if ! cmp -s "$HERE/../classify.sh" "$ROOT/mut-gate/classify.sh"; then
  printf '%s\n' "$DUPCL" > "$ROOT/ledger.json"
  OUT="$("$ROOT/mut-gate/classify.sh" < "$ROOT/discover.json" 2>/dev/null)" || { echo "mutant classify.sh failed"; exit 1; }
  expect "ledger gate mutant (repeated key): without the gate the single-task worker is torn down (the harm, caught)" /x/research-ota-cost done-merged '^teardown$'
else FAIL=$((FAIL + 1)); echo "FAIL ledger gate mutant: the perl edit no longer matches classify.sh"; fi
cp "$ROOT/ledger.keep" "$ROOT/ledger.json"
# mutant: a copy of classify.jq without the wrong-typed-row hold reads the row as one for another path, and the case is caught
MUT="$ROOT/mut-cls"; mkdir -p "$MUT/skill"; cp -R "$HERE/.." "$MUT/skill/scripts"
sed -i 's/ or \$wildRows or / or /' "$MUT/skill/scripts/classify.jq"
if ! cmp -s "$HERE/../classify.jq" "$MUT/skill/scripts/classify.jq"; then
  jq '.workers["w-wild"] = {host: "local", path: false, standing: true}' "$ROOT/ledger.keep" > "$ROOT/ledger.json"
  MOUT="$("$MUT/skill/scripts/classify.sh" < "$ROOT/discover.json")"
  mgot="$(printf '%s' "$MOUT" | jq -r '.items[] | select(.path == "/x/research-ota-cost") | .suggest')"
  case "$mgot" in *'standing unknown'*) FAIL=$((FAIL + 1)); echo "FAIL mutant: the wrong-typed-row hold is off and the case still passes" ;; *) PASS=$((PASS + 1)); echo "PASS mutant: with the hold off the worker is no longer standing unknown, the case is caught" ;; esac
else FAIL=$((FAIL + 1)); echo "FAIL mutant: the sed no longer matches classify.jq (update this test)"; fi
cp "$ROOT/ledger.keep" "$ROOT/ledger.json"
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
