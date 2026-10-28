#!/usr/bin/env bash
# followups.sh: behaviour tests for scripts/followups.sh (reconcile, close, open, report, comment-open) on a
# temp CM_HOME. Never touches the live ledger. The teardown refusals are in teardown-gates.sh.
#
#   scripts/test/followups.sh            # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export CM_CONFIG="$HERE/fixtures/config.test.yaml"
unset CM_ORG CM_REPO CM_PROJECT CM_OWNER_NAME CM_OWNER_ID CM_TZ CM_TZ_LABEL CM_EXCLUDE_REPOS CM_PATH_MATCH CM_SELF_WORKTREE CM_LEDGER
FU="$HERE/../followups.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-followups.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap 'rm -rf -- "${ROOT:?}"' EXIT
export CM_HOME="$ROOT/cmhome"
mkdir -p "$CM_HOME"
L="$CM_HOME/ledger.json"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n%s\n' "$1" "${2:-}"; }
# check <label> <jq filter> [expected]: the ledger filter prints the expected text (default true)
check() {
  local got
  got="$(jq -r "$2" "$L" 2>&1)"
  if [ "$got" = "${3:-true}" ]; then ok "$1"; else bad "$1" "got: $got want: ${3:-true}"; fi
}
baks() { find "$CM_HOME/ledger.bak" -type f 2>/dev/null | wc -l | tr -d ' '; }

# census <name:comment>... : a discover document; the comment may hold \n
census() {
  local rows="" a name c
  for a in "$@"; do
    name="${a%%:*}"; c="${a#*:}"
    rows="$rows$(jq -cn --arg p "/w/$name" --arg c "$c" '{host:"local", path:$p, worktreeId:null, comment:$c}'),"
  done
  printf '{"worktrees":[%s]}' "${rows%,}"
}
seed() { printf '%s' '{"workers":{
  "w-lead":{"host":"local","path":"/w/lead-a","lane":"lane-a","state":"running","standing":true},
  "w-iso":{"host":"local","path":"/w/child-a","lane":"lane-a","state":"running","standing":false},
  "w-other":{"host":"local","path":"/w/lead-b","lane":"lane-b","state":"running","standing":true}},
  "lanes":{"lane-a":{"lead":"w-lead","state":"running"},"lane-b":{"lead":"w-other","state":"running"}},
  "asks":[]}' > "$L"; }
rec() { census "$@" | "$FU" reconcile >/dev/null 2>&1; }

echo "== reconcile: child, follow-up, owner ask"
seed
census "lead-a:cm:running 2 workers
cm:child child-a
cm:followup check-report owner=lane-a re-run the checks after the batch
cm:followup pick-option owner=owner choose option a or b" \
  "child-a:cm:done" > "$ROOT/d1.json"
"$FU" reconcile --discover "$ROOT/d1.json" >/dev/null 2>&1
check "cm:child sets workers.<child>.parent"             '.workers["w-iso"].parent == "w-lead"'
check "cm:followup opens a row"                          '[.followUps[] | select(.state == "open")] | length == 2'
check "row carries worker, lane, owner, text"            '.followUps[] | select(.id == "check-report") | .worker == "w-lead" and .lane == "lane-a" and .owner == "lane-a" and .text == "re-run the checks after the batch" and .closedAt == null and (.openedAt | length > 0)'
check "an item owned by the project owner also becomes an asks[] row"          '[.asks[] | select(.kind == "owner" and .state == "open" and .id == "fu-lane-a-pick-option")] | length == 1'
check "an owner that is a lane gets no ask"              '[.asks[] | select(.id == "fu-lane-a-check-report")] | length == 0'

echo "== reconcile: idempotent (d)"
cp "$L" "$ROOT/before.json"; B1="$(baks)"
"$FU" reconcile --discover "$ROOT/d1.json" >/dev/null 2>&1
if cmp -s "$L" "$ROOT/before.json"; then ok "second run leaves the ledger byte-identical"; else bad "second run changed the ledger" "$(diff "$ROOT/before.json" "$L")"; fi
if [ "$(baks)" = "$B1" ]; then ok "second run writes no backup (no write at all)"; else bad "second run wrote a backup"; fi
"$FU" reconcile --discover "$ROOT/d1.json" >/dev/null 2>&1
if cmp -s "$L" "$ROOT/before.json"; then ok "third run still identical"; else bad "third run changed the ledger"; fi

echo "== reconcile: absence and stale lines"
rec "child-a:cm:done"
check "worktree absent from the census closes nothing"   '[.followUps[] | select(.state == "open")] | length == 2'
check "no duplicate rows"                                '.followUps | length == 2'
rec "lead-a:cm:running
cm:followup bad id here
cm:followup NoCaps owner=x t
cm:followup noowner some text
cm:child"
check "malformed lines add nothing"                      '.followUps | length == 2'

echo "== reconcile: cm:followup-done closes"
rec "lead-a:cm:running
cm:followup check-report owner=lane-a re-run the checks after the batch
cm:followup-done check-report"
check "cm:followup-done closes the row"                  '.followUps[] | select(.id == "check-report") | .state == "done" and (.closedAt | length > 0)'
rec "lead-a:cm:running
cm:followup check-report owner=lane-a re-run the checks after the batch"
check "a stale cm:followup line does not reopen it"      '.followUps[] | select(.id == "check-report") | .state == "done"'
rec "lead-a:cm:running
cm:followup-done pick-option"
check "done closes the owner row"                       '.followUps[] | select(.id == "pick-option") | .state == "done"'
check "done answers the owner ask"                      '.asks[] | select(.id == "fu-lane-a-pick-option") | .state == "answered" and .decision == "followup-closed"'
check "every row is closed at this point"    '([.followUps[] | select(.state == "open")] | length) == 0'
seed
rec "lead-a:cm:running
cm:followup keep-me owner=owner text"
rec "lead-b:cm:running
cm:followup-done keep-me"
check "same id in another lane is not closed"            '.followUps[] | select(.id == "keep-me") | .state == "open"'

echo "== reconcile: parent rules"
seed
jq '.workers["w-iso"].parent = "w-other"' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
rec "lead-a:cm:running
cm:child child-a"
check "an existing parent is not overwritten"            '.workers["w-iso"].parent == "w-other"'
seed
rec "child-a:cm:running
cm:child lead-a" "lead-a:cm:running
cm:child child-a"
check "a parent cycle is refused"                        '[.workers[] | select(.parent != null)] | length == 1'
seed
OUT="$(census "lead-a:cm:child no-such-worktree" | "$FU" reconcile 2>&1)"
check "cm:child naming no ledger worker sets nothing"    '[.workers[] | select(.parent != null)] | length == 0'
if printf '%s\n' "$OUT" | grep -q 'followups: unmatched-child w-lead no-such-worktree'; then ok "and is reported as unmatched-child"; else bad "no unmatched-child line" "$OUT"; fi

echo "== reassign: another live worker posts the same id"
seed
rec "child-a:cm:running
cm:followup item-ids owner=lane-a check the output"
check "worker posts it"                                  '.followUps[0].worker == "w-iso"'
rec "child-a:cm:running
cm:followup item-ids owner=lane-a check the output" "lead-a:cm:running
cm:followup item-ids owner=lane-a check the output"
check "two live posters: the current worker keeps it"    '.followUps[0].worker == "w-iso"'
rec "lead-a:cm:running
cm:followup item-ids owner=lane-a check the output, now with the lead"
check "poster only absent (still live): the item stays put"  '.followUps[0].worker == "w-iso"'
jq '.workers["w-iso"].state = "gone"' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
rec "lead-a:cm:running
cm:followup item-ids owner=lane-a check the output, now with the lead"
check "poster gone, another posts: reassigned, text kept current" '.followUps[0].worker == "w-lead" and (.followUps[0].text | endswith("with the lead"))'

seed
rec "child-a:cm:running
cm:followup handoff owner=lane-a validate"
rec "child-a:cm:running" "lead-a:cm:running
cm:followup handoff owner=lane-a validate"
check "live poster present and dropped the line: handed over" '.followUps[0].worker == "w-lead"'

echo "== report: orphaned rows (e1, e2)"
seed
rec "child-a:cm:running
cm:followup item-ids owner=lane-a check the output"
"$FU" report > "$ROOT/report.tsv"
if ! grep -q '^orphaned' "$ROOT/report.tsv"; then ok "a running worker's item is not orphaned"; else bad "running worker listed as orphan" "$(cat "$ROOT/report.tsv")"; fi
jq '.workers["w-iso"].state = "gone"' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
"$FU" report > "$ROOT/report.tsv"
if grep -q '^orphaned	item-ids	w-iso	lane-a	lane-a	gone	check the output' "$ROOT/report.tsv"; then ok "e1: report lists an orphan for a gone worker"; else bad "e1 gone" "$(cat "$ROOT/report.tsv")"; fi
jq '.workers["w-iso"].state = "teardown"' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
"$FU" report > "$ROOT/report.tsv"
if grep -q '^orphaned	item-ids	w-iso	lane-a	lane-a	teardown' "$ROOT/report.tsv"; then ok "e1: report lists an orphan for a teardown worker"; else bad "e1 teardown" "$(cat "$ROOT/report.tsv")"; fi
jq 'del(.workers["w-iso"])' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
"$FU" report > "$ROOT/report.tsv"
if grep -q '^orphaned	item-ids	w-iso	lane-a	lane-a	missing' "$ROOT/report.tsv"; then ok "e1: report lists an orphan for a missing worker"; else bad "e1 missing" "$(cat "$ROOT/report.tsv")"; fi
check "a state is never stored for it"                   '[.workers[] | select(.state == "orphaned-followups")] | length == 0'
cp "$L" "$ROOT/keep.json"
rec "lead-a:cm:running
cm:followup item-ids owner=lane-a check the output"
"$FU" report > "$ROOT/report.tsv"
if ! grep -q '^orphaned' "$ROOT/report.tsv"; then ok "e2: another live worker posts it: the row is gone"; else bad "e2 reassign" "$(cat "$ROOT/report.tsv")"; fi
cp "$ROOT/keep.json" "$L"
"$FU" close item-ids >/dev/null 2>&1
"$FU" report > "$ROOT/report.tsv"
if ! grep -q 'item-ids' "$ROOT/report.tsv"; then ok "e2: closing removes the row"; else bad "e2 close" "$(cat "$ROOT/report.tsv")"; fi
for st in "done" retired queued; do
  seed; rec "child-a:cm:running
cm:followup x1 owner=lane-a t"
  jq --arg s "$st" '.workers["w-iso"].state = $s' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
  "$FU" report | grep -q '^orphaned	x1' && ok "worker state $st counts as not alive" || bad "state $st not orphaned"
done
for st in spawning stuck blocked-on-owner idle; do
  seed; rec "child-a:cm:running
cm:followup x1 owner=lane-a t"
  jq --arg s "$st" '.workers["w-iso"].state = $s' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
  "$FU" report | grep -q '^orphaned' && bad "state $st wrongly orphaned" || ok "worker state $st is alive"
done

echo "== report: owner-answered, malformed, unmatched, parentWorktreeId, open --lane"
seed
rec "lead-a:cm:running
cm:followup pick-option owner=Owner choose option a or b"
check "owner is lowercased"                              '.followUps[0].owner == "owner"'
"$FU" report > "$ROOT/report.tsv"
if ! grep -q 'pick-option' "$ROOT/report.tsv"; then ok "owner-id item with an open ask: no row"; else bad "owner-id row too early" "$(cat "$ROOT/report.tsv")"; fi
jq '.asks[0].state = "answered"' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
"$FU" report > "$ROOT/report.tsv"
if grep -q '^followup	pick-option	w-lead	lane-a	owner	owner-answered' "$ROOT/report.tsv"; then ok "answered ask: row with owner state owner-answered"; else bad "owner-answered" "$(cat "$ROOT/report.tsv")"; fi
check "an answered ask does not close the item"          '.followUps[0].state == "open"'
OUT="$(census "lead-a:cm:running
cm:followup Bad_Id owner=x t
cm:followup noowner some text
cm:followup-done
cm:child
cm:followup ok-id owner=lane-a fine" "nobody:cm:followup lost-one owner=x t
cm:child kid" | "$FU" reconcile 2>&1)"
for want in 'followups: malformed w-lead cm:followup Bad_Id owner=x t' 'followups: malformed w-lead cm:followup noowner some text' 'followups: malformed w-lead cm:followup-done' 'followups: malformed w-lead cm:child$' 'followups: unmatched local:/w/nobody lost-one,child:kid'; do
  if printf '%s\n' "$OUT" | grep -q -- "$want"; then ok "reconcile prints: ${want:0:50}"; else bad "missing line: $want" "$OUT"; fi
done
if printf '%s\n' "$OUT" | grep -q 'ok-id\|malformed w-lead cm:followup ok-id'; then bad "a good line was reported" "$OUT"; else ok "a good line is not reported"; fi
OUT="$(census "lead-a:cm:running
- cm:followup prefixed owner=owner t
cm:Followup upper owner=owner t" | "$FU" reconcile 2>&1)"
if [ "$(printf '%s\n' "$OUT" | grep -c 'malformed w-lead')" = 2 ]; then ok "a prefixed or mis-cased cm:followup line is reported"; else bad "prefixed/mis-cased line not reported" "$OUT"; fi
check "good line beside bad ones still opens"            '[.followUps[] | select(.id == "ok-id")] | length == 1'
LONG="$(printf 'x%.0s' $(seq 1 120))"
OUT="$(census "lead-a:cm:followup Bad Id $LONG" | "$FU" reconcile 2>&1)"
LINE="$(printf '%s\n' "$OUT" | grep 'malformed' | head -1)"
PFX="followups: malformed w-lead "
if [ -n "$LINE" ] && [ "${#LINE}" -le $(( ${#PFX} + 80 )) ]; then ok "malformed line is cut to 80 chars"; else bad "malformed line not cut" "$LINE"; fi
OUT="$(census "lead-a:cm:running | cm:followup pipe-one owner=owner t | cm:followup-done pipe-two" | "$FU" reconcile 2>&1)"
check "single-line comment: ' | ' separates tags"        '[.followUps[] | select(.id == "pipe-one")] | length == 1'
OUT="$(census 'lead-a:cm:running\ncm:followup lit-nl owner=owner t' | "$FU" reconcile 2>&1)"
check "a literal \\n separates tags"                    '[.followUps[] | select(.id == "lit-nl")] | length == 1'
seed
printf '{"worktrees":[{"host":"local","path":"/w/lead-a","worktreeId":"r::lead","comment":"cm:running"},{"host":"local","path":"/w/child-a","worktreeId":"r::iso","parentWorktreeId":"r::lead","comment":"cm:running"}]}' > "$ROOT/dp.json"
jq '.workers["w-lead"].worktreeId = "r::lead" | .workers["w-iso"].worktreeId = "r::iso"' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
"$FU" reconcile --discover "$ROOT/dp.json" >/dev/null 2>&1
check "parentWorktreeId sets the parent"                 '.workers["w-iso"].parent == "w-lead"'
jq '.workers["w-iso"].parent = null | .workers["w-other"].worktreeId = "r::other"' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
rec "lead-a:cm:running
cm:child child-a" "lead-b:cm:child child-a"
check "two cm:child claimants: nothing set"              '.workers["w-iso"].parent == null'
OUT="$(census "lead-a:cm:child child-a" "lead-b:cm:child child-a" | "$FU" reconcile 2>&1)"
if printf '%s\n' "$OUT" | grep -q 'parent-conflict w-iso w-lead,w-other'; then ok "conflict is printed"; else bad "no conflict line" "$OUT"; fi
printf '{"worktrees":[{"host":"local","path":"/w/lead-a","worktreeId":"r::lead","parentWorktreeId":"r::iso","comment":"cm:running"},{"host":"local","path":"/w/child-a","worktreeId":"r::iso","parentWorktreeId":"r::lead","comment":"cm:running"}]}' > "$ROOT/dc.json"
seed; jq '.workers["w-lead"].worktreeId = "r::lead" | .workers["w-iso"].worktreeId = "r::iso"' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
"$FU" reconcile --discover "$ROOT/dc.json" >/dev/null 2>&1
check "parentWorktreeId cycle is refused"                '[.workers[] | select(.parent != null)] | length == 1'
seed
rec "lead-a:cm:running
cm:followup a1 owner=lane-a one" "lead-b:cm:followup b1 owner=lane-b two"
OUT="$("$FU" open --lane lane-a)"
if printf '%s\n' "$OUT" | grep -q '^a1	w-lead	lane-a	lane-a	' && ! printf '%s\n' "$OUT" | grep -q 'b1'; then ok "open --lane filters to the lane"; else bad "open --lane" "$OUT"; fi
if [ "$("$FU" open | wc -l | tr -d ' ')" = 2 ]; then ok "open lists every lane"; else bad "open without --lane"; fi

echo "== comment-open"
OUT="$(printf 'cm:running\ncm:followup a owner=x t\ncm:followup b owner=x t\ncm:followup-done b\n- cm:followup c owner=x t\ncm:followup D owner=x t' | "$FU" comment-open)"
if [ "$OUT" = "$(printf 'a\nbad:- cm:followup c owner=x t\nbad:cm:followup D owner=x t')" ]; then ok "comment-open: open ids, then bad: lines"; else bad "comment-open output" "$OUT"; fi
OUT="$(printf 'plain note' | "$FU" comment-open)"
if [ -z "$OUT" ]; then ok "comment-open: no tags, no output"; else bad "comment-open noise" "$OUT"; fi
rm -f "$L"; OUT="$(printf 'cm:followup a owner=x t' | "$FU" comment-open 2>&1)"
if [ "$OUT" = a ]; then ok "comment-open needs no ledger"; else bad "comment-open without ledger" "$OUT"; fi

echo "== reused id, tag spellings, owner round trip"
seed
rec "lead-a:cm:running
cm:followup v owner=ops first
cm:followup-done v"
OUT="$(census "lead-a:cm:running
cm:followup v owner=ops second pass, new item" | "$FU" reconcile 2>&1)"
if printf '%s\n' "$OUT" | grep -q 'followups: reused-id w-lead v'; then ok "a closed id posted with new text is reported as reused-id"; else bad "no reused-id line" "$OUT"; fi
check "and the closed row is not reopened" '.followUps[0].state == "done"'
OUT="$(census "lead-a:cm:running
cm:follow-up x owner=owner t
cm:CHILD kid" | "$FU" reconcile 2>&1)"
if [ "$(printf '%s\n' "$OUT" | grep -c 'followups: malformed w-lead')" = 2 ]; then ok "cm:follow-up and cm:CHILD are reported, not ignored"; else bad "spelling variants not reported" "$OUT"; fi
seed
rec "lead-a:cm:running
cm:followup rt owner=owner t"
rec "lead-a:cm:running
cm:followup rt owner=ops t"
rec "lead-a:cm:running
cm:followup rt owner=owner t"
check "owner, ops, owner again: the one ask is open again" '[.asks[] | select(.followUp == "rt")] | length == 1 and .[0].state == "open"'
"$FU" reconcile --discover >/dev/null 2>&1; RC=$?
if [ "$RC" = 2 ]; then ok "--discover without a file: usage error, rc 2"; else bad "--discover without a file rc=$RC"; fi

OUT="$(printf 'cm:running\ncm:followup a owner=x one\ncm:followup b owner=x two words' | "$FU" comment-open --texts)"
if [ "$OUT" = "$(printf 'a\tone\nb\ttwo words')" ]; then ok "comment-open --texts: id, tab, text"; else bad "comment-open --texts output" "$OUT"; fi
OUT="$(printf 'cm:running note; cm:followup a-b owner=x t\ncm:follow_up c owner=x t\nsee cm:child below' | "$FU" comment-open)"
if [ "$OUT" = "$(printf 'bad:cm:follow_up c owner=x t\nbad:cm:running note; cm:followup a-b owner=x t')" ]; then ok "a tag after a semicolon or spelled follow_up is bad, prose is not"; else bad "tag detection" "$OUT"; fi

echo "== owner case, child host"
seed
rec "lead-a:cm:followup own-case owner=LANE-A t"
jq '.lanes["lane-a"].state = "gone"' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
"$FU" report > "$ROOT/report.tsv"
if grep -q '^followup	own-case	w-lead	lane-a	lane-a	gone' "$ROOT/report.tsv"; then ok "report: owner matched case-insensitively"; else bad "owner case" "$(cat "$ROOT/report.tsv")"; fi
seed
jq 'del(.workers["w-lead"].host)' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
rec "lead-a:cm:child child-a"
check "poster with no host: child found on the row's host" '.workers["w-iso"].parent == "w-lead"'

echo "== ask keying"
seed
rec "lead-a:cm:followup q owner=owner ops question" "lead-b:cm:followup q owner=owner dev question"
"$FU" close q --lane lane-a >/dev/null 2>&1
check "close --lane answers only that lane's ask"        '([.asks[] | select(.lane == "lane-a" and .state == "answered")] | length) == 1 and ([.asks[] | select(.lane == "lane-b" and .state == "open")] | length) == 1'
seed
jq '.workers["w-lead"].lane = "a-b" | .workers["w-other"].lane = "a"' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
rec "lead-a:cm:followup c owner=owner first" "lead-b:cm:followup b-c owner=owner second"
check "ids that join to the same string get two asks"    '([.asks[] | select(.kind == "owner")] | length == 2) and (([.asks[].id] | unique | length) == 2)'

echo "== close and report"
seed
rec "child-a:cm:running
cm:followup a-one owner=w-other first
cm:followup b-two owner=ghost second
cm:followup c-three owner=owner third"
"$FU" report > "$ROOT/report.tsv"
if grep -q '^followup	b-two	w-iso	lane-a	ghost	missing' "$ROOT/report.tsv"; then ok "report row: owner that is missing"; else bad "report misses the missing owner" "$(cat "$ROOT/report.tsv")"; fi
if ! grep -q 'a-one' "$ROOT/report.tsv"; then ok "report omits an owner that is running"; else bad "report lists a running owner"; fi
if ! grep -q 'c-three' "$ROOT/report.tsv"; then ok "report omits an owner-id item (already in asks)"; else bad "report lists an owner-id item"; fi
jq '.workers["w-other"].state = "gone"' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
"$FU" report > "$ROOT/report.tsv"
if grep -q '^followup	a-one	w-iso	lane-a	w-other	gone' "$ROOT/report.tsv"; then ok "report row: owner worker is gone"; else bad "report misses the gone owner" "$(cat "$ROOT/report.tsv")"; fi
"$FU" close b-two >/dev/null 2>&1
check "close <id> closes the row"                        '.followUps[] | select(.id == "b-two") | .state == "done"'
"$FU" close nope >/dev/null 2>&1; rc=$?
if [ "$rc" != 0 ]; then ok "close of an unknown id fails"; else bad "close of an unknown id returned 0"; fi
"$FU" close c-three >/dev/null 2>&1
check "close answers the owner ask"                     '.asks[] | select(.id == "fu-lane-a-c-three") | .state == "answered"'

echo "== digest --full lists open follow-ups"
OUT="$(CM_DIGEST_GH_TIMEOUT=1 "$HERE/../digest.sh" --full --ledger "$L" 2>/dev/null)"
if printf '%s' "$OUT" | grep -q 'Open follow-ups (1)' && printf '%s' "$OUT" | grep -q 'lane-a/a-one'; then ok "--full has the section"; else bad "--full lacks the section" "$OUT"; fi
OUT="$(CM_DIGEST_GH_TIMEOUT=1 "$HERE/../digest.sh" --ledger "$L" 2>/dev/null)"
if ! printf '%s' "$OUT" | grep -q 'follow-up'; then ok "the group digest omits follow-ups"; else bad "group digest shows follow-ups" "$OUT"; fi

echo "== bad input"
seed
printf 'not json' | "$FU" reconcile >/dev/null 2>&1; rc=$?
if [ "$rc" != 0 ]; then ok "a bad discover document fails"; else bad "bad discover returned 0"; fi
jq '.followUps = {"x":1}' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
census "lead-a:cm:followup z owner=x t" | "$FU" reconcile >/dev/null 2>&1; rc=$?
if [ "$rc" != 0 ] && jq -e '.followUps | type == "object"' "$L" >/dev/null; then ok "followUps that is not an array: refused, ledger untouched"; else bad "non-array followUps was rewritten"; fi

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
