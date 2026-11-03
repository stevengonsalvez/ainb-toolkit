#!/usr/bin/env bash
# shellcheck disable=SC2015  # "A && ok || bad": ok never fails
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
  # shellcheck disable=SC2015  # ok and bad only print; neither fails, so the || branch cannot misfire
  "$FU" report | grep -q '^orphaned	x1' && ok "worker state $st counts as not alive" || bad "state $st not orphaned"
done
for st in spawning stuck blocked-on-owner idle; do
  seed; rec "child-a:cm:running
cm:followup x1 owner=lane-a t"
  jq --arg s "$st" '.workers["w-iso"].state = $s' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
  # shellcheck disable=SC2015  # ok and bad only print; neither fails, so the || branch cannot misfire
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

echo "== reconcile: new text on an escalated item is a new task"
seed
rec "lead-a:cm:running
cm:followup validate-codes owner=lane-a Codex validation after the load"
jq '(.followUps[] | select(.id == "validate-codes")) += {issue: 9, issueUrl: "https://github.com/AcmeOrg/acme-app/issues/9", escalatedAt: "2026-10-30T00:00:00Z"}' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
rec "lead-a:cm:running
cm:followup validate-codes owner=lane-a Codex validation after the load"
check "same text: the issue stays"                      '.followUps[] | select(.id == "validate-codes") | .issue == 9'
rec "lead-a:cm:running
cm:followup validate-codes owner=lane-a A different job now"
check "new text: the issue fields are cleared"          '.followUps[] | select(.id == "validate-codes") | (.issue // .issueUrl // .escalatedAt) == null and .text == "A different job now"'
# an escalate run holds a claim while gh runs; a text change in that window must leave the claim for the run to record against
rec "lead-a:cm:running
cm:followup validate-codes owner=lane-a A different job now"
jq '(.followUps[] | select(.id == "validate-codes")) += {escalatingAt: "tok-123"}' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
rec "lead-a:cm:running
cm:followup validate-codes owner=lane-a A third wording"
check "new text while a claim is held: the claim stays"  '.followUps[] | select(.id == "validate-codes") | .escalatingAt == "tok-123" and .text == "A third wording" and (.issue // .issueUrl // .escalatedAt) == null'

echo "== for-worktree: the open items of a worktree's worker and its children"
jq -n '{workers: {
  "w-p": {host: "local", path: "/w/ops-p", lane: "lane-a", state: "running"},
  "w-c": {host: "local", path: "/w/ops-c", lane: "lane-a", state: "running", parent: "w-p"},
  "w-x": {host: "local", path: "/w/ops-x", lane: "lane-a", state: "running", parent: "w-y"},
  "w-y": {host: "local", path: "/w/ops-y", lane: "lane-a", state: "running", parent: "w-x"},
  "w-z": {host: "local", path: "/w/other-z", lane: "lane-b", state: "running"}},
  followUps: [
    {id: "p-item", worker: "w-p", lane: "lane-a", owner: "w-p", text: "parent item", state: "open", openedAt: "2026-10-27T10:00:00Z"},
    {id: "c-item", worker: "w-c", lane: "lane-a", owner: "owner", text: "child\u001b[31m item\twith a tab", state: "open", openedAt: "2026-10-27T11:00:00Z"},
    {id: "p-done", worker: "w-p", lane: "lane-a", owner: "w-p", text: "closed", state: "done", openedAt: "2026-10-26T10:00:00Z"},
    {id: "x-item", worker: "w-x", lane: "lane-a", owner: "w-x", text: "in a parent cycle", state: "open", openedAt: "2026-10-27T12:00:00Z"},
    {id: "z-item", worker: "w-z", lane: "lane-b", owner: "w-z", text: "someone else", state: "open", openedAt: "2026-10-27T13:00:00Z"}]}' > "$L"
out="$("$FU" for-worktree /w/ops-p 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | cut -f1 | sort | tr '\n' ' ')" = "c-item p-item " ]; then ok "for-worktree: the worker's and its child's open items, by path"; else bad "for-worktree by path" "rc=$rc $out"; fi
case "$out" in *p-done*|*z-item*|*x-item*) bad "for-worktree: closed or foreign item listed" "$out" ;; *) ok "for-worktree: closed and foreign items not listed" ;; esac
case "$out" in *$'\033'*) bad "for-worktree: control characters kept" "$out" ;; *) ok "for-worktree: control characters cleaned" ;; esac
[ "$("$FU" for-worktree ops-p | cut -f1 | sort | tr '\n' ' ')" = "c-item p-item " ] && ok "for-worktree: by directory name" || bad "for-worktree by name"
[ "$("$FU" for-worktree w-p | cut -f1 | sort | tr '\n' ' ')" = "c-item p-item " ] && ok "for-worktree: by worker id" || bad "for-worktree by id"
out="$("$FU" for-worktree ops-x 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | cut -f1 | sort | tr '\n' ' ')" = "x-item " ]; then ok "for-worktree: a parent cycle ends"; else bad "for-worktree cycle" "rc=$rc $out"; fi
"$FU" for-worktree /w/nowhere >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && ok "for-worktree: no ledger worker owns it, exit 3" || bad "for-worktree untracked" "rc=$rc"
"$FU" for-worktree op >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && ok "for-worktree: a name prefix matches nothing" || bad "for-worktree prefix" "rc=$rc"
"$FU" for-worktree >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "for-worktree: no argument, exit 2" || bad "for-worktree usage" "rc=$rc"
for led in '{"followUps":[]}' '{"workers":[],"followUps":[]}' '{"workers":"x"}'; do
  printf '%s' "$led" > "$ROOT/p.json"; cp "$L" "$ROOT/keep.json"; cp "$ROOT/p.json" "$L"
  "$FU" for-worktree /w/ops-p >/dev/null 2>&1; rc=$?
  [ "$rc" = 1 ] && ok "for-worktree: a ledger without a workers object is unusable (exit 1), not untracked: $led" || bad "for-worktree malformed $led" "rc=$rc"
  cp "$ROOT/keep.json" "$L"
done
# an item with a GitHub issue lives on there: not listed; a missing field prints empty, not "null"
jq '(.followUps[] | select(.id == "p-item")) += {issue: 7, issueUrl: "https://github.com/AcmeOrg/acme-app/issues/7"} | (.followUps[] | select(.id == "c-item")) |= del(.openedAt)' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
out="$("$FU" for-worktree /w/ops-p 2>&1)"
[ "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')" = "c-item " ] && ok "for-worktree: an escalated item is not listed" || bad "for-worktree escalated" "$out"
case "$out" in *null*) bad "for-worktree: a missing field printed as null" "$out" ;; *) ok "for-worktree: a missing field prints empty" ;; esac

echo "== child adoption (cm:child names a worktree with no ledger row)"
# lane-a posts its children; child rows carry their own comment, host-a style synthetic names
adoptseed() { printf '%s' '{"workers":{
  "lane-a":{"host":"local","path":"/w/lane-a","lane":"lane-a","state":"running","standing":true},
  "kept":{"host":"local","path":"/w/kept","lane":"lane-a","state":"running","standing":true,"beadsEpic":"ep-1","marker":"mine"},
  "old-gone":{"host":"local","path":"/w/old-gone","lane":"lane-a","state":"gone","standing":false}},
  "lanes":{"lane-a":{"lead":"lane-a","state":"running"}},"asks":[]}' > "$L"; }
adoptseed
census "lane-a:cm:running 3 workers
cm:child kid-run
cm:child kid-blocked
cm:child kid-fresh
cm:child kept
cm:child old-gone
cm:child nowhere" \
  "kid-run:cm:running fixing the thing" \
  "kid-blocked:cm:blocked need a decision | cm:ask which one" \
  "kid-fresh:" \
  "kept:cm:running" \
  "old-gone:cm:running" > "$ROOT/ad1.json"
OUT="$("$FU" reconcile --discover "$ROOT/ad1.json" 2>&1)"
check "adopts a running child: standing false"          '.workers["kid-run"] | .standing == false and .state == "running" and .adopted == true'
check "adopted child: host, path and lane from census"  '.workers["kid-run"] | .host == "local" and .path == "/w/kid-run" and .lane == "lane-a"'
check "adopted child: parent is the poster"             '.workers["kid-run"].parent == "lane-a"'
check "adopted child: beadsEpic null"                   '.workers["kid-run"].beadsEpic == null'
check "state comes from the child own first line"       '.workers["kid-blocked"].state == "blocked-on-owner"'
check "a child with no comment yet is spawning"         '.workers["kid-fresh"].state == "spawning"'
check "lastComment holds the child first line"          '.workers["kid-run"].lastComment == "cm:running fixing the thing"'
check "an existing ledger worker is never overwritten"  '.workers.kept | .marker == "mine" and .standing == true and .beadsEpic == "ep-1" and .state == "running" and .host == "local" and .path == "/w/kept" and .lane == "lane-a"'
check "a dead row holding the id is not replaced"       '.workers["old-gone"].state == "gone" and (.workers["old-gone"] | has("adopted") | not)'
check "a child with no census row adds nothing"         '.workers | has("nowhere") | not'
if printf '%s' "$OUT" | grep -q 'followups: adopted kid-run (child of lane-a, standing false, state running)'; then ok "reports the adoption"; else bad "no adopted line" "$OUT"; fi
if printf '%s' "$OUT" | grep -q 'followups: adopt-skipped old-gone'; then ok "reports the skipped dead id"; else bad "no adopt-skipped line" "$OUT"; fi
if printf '%s' "$OUT" | grep -q 'followups: unmatched-child lane-a nowhere'; then ok "still reports a child with no worktree"; else bad "no unmatched-child line" "$OUT"; fi
echo "-- second run writes nothing"
B1="$(baks)"; M1="$(jq -c . "$L")"
"$FU" reconcile --discover "$ROOT/ad1.json" >/dev/null 2>&1
if [ "$(jq -c . "$L")" = "$M1" ] && [ "$(baks)" = "$B1" ]; then ok "adoption is idempotent: ledger and backups unchanged"; else bad "second run changed the ledger"; fi
echo "-- the ledger helper writes it (the newest backup is the ledger as it was before)"
adoptseed
"$FU" reconcile --discover "$ROOT/ad1.json" >/dev/null 2>&1
NEWEST="$(find "$CM_HOME/ledger.bak" -type f -name '[0-9]*T*Z*.json' | LC_ALL=C sort | tail -1)"
if [ -n "$NEWEST" ] && jq -e '(.workers | has("kept")) and (.workers | has("kid-run") | not)' "$NEWEST" >/dev/null 2>&1 \
   && jq -e '.workers | has("kid-run")' "$L" >/dev/null 2>&1; then ok "adoption went through cm_ledger_write (pre-write backup taken)"; else bad "no pre-write backup of the seeded ledger"; fi
echo "-- a poster that is not a live ledger worker adopts nothing"
adoptseed
census "stranger:cm:running
cm:child kid-run" "kid-run:cm:running" > "$ROOT/ad2.json"
"$FU" reconcile --discover "$ROOT/ad2.json" >/dev/null 2>&1
check "an unknown poster adopts nothing"                '.workers | has("kid-run") | not'
echo "-- a hostile child name is not adopted"
adoptseed
census "lane-a:cm:running
cm:child ../etc" "../etc:cm:running" > "$ROOT/ad3.json"
"$FU" reconcile --discover "$ROOT/ad3.json" >/dev/null 2>&1
check "a path-like child name adds nothing"             '.workers | keys == ["kept","lane-a","old-gone"]'
echo "-- two posters claim one child: adopted once, parent conflict reported, none set"
adoptseed
jq '.workers["lane-b"] = {"host":"local","path":"/w/lane-b","lane":"lane-b","state":"running","standing":true}' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
census "lane-a:cm:running
cm:child kid-run" "lane-b:cm:running
cm:child kid-run" "kid-run:cm:running" > "$ROOT/ad4.json"
OUT="$("$FU" reconcile --discover "$ROOT/ad4.json" 2>&1)"
check "adopted once with no parent chosen"              '.workers["kid-run"] | .standing == false and .parent == null'
if printf '%s' "$OUT" | grep -q 'followups: parent-conflict kid-run lane-a,lane-b'; then ok "reports the parent conflict"; else bad "no parent-conflict line" "$OUT"; fi
echo "-- the adopted child passes the standing gate teardown reads"
adoptseed
"$FU" reconcile --discover "$ROOT/ad1.json" >/dev/null 2>&1
check "teardown sees standing:false (not unknown)"       '.workers["kid-run"].standing == false'

echo "-- a declared epic (epic=<bead-id> on the cm:child line) is kept on the adopted worker"
adoptseed
census "lane-a:cm:running
cm:child kid-epic epic=ep-1
cm:child kid-noepic
cm:child kid-odd epic=a;b" "kid-epic:cm:running" "kid-noepic:cm:running" "kid-odd:cm:running" > "$ROOT/ad5.json"
"$FU" reconcile --discover "$ROOT/ad5.json" >/dev/null 2>&1
check "epic=ep-1 becomes beadsEpic"                     '.workers["kid-epic"].beadsEpic == "ep-1"'
check "no epic token: beadsEpic stays null"             '.workers["kid-noepic"].beadsEpic == null'
check "a hostile epic token is cut at the first bad character" '.workers["kid-odd"].beadsEpic == "a"'
check "the epic child is still adopted as non-standing" '.workers["kid-epic"] | .standing == false and .adopted == true and .parent == "lane-a"'

echo "-- an epic= added after the child was adopted still reaches the ledger"
adoptseed
census "lane-a:cm:running
cm:child kid-late
cm:child kid-set epic=ep-1" "kid-late:cm:running" "kid-set:cm:running" > "$ROOT/ad5a.json"
"$FU" reconcile --discover "$ROOT/ad5a.json" >/dev/null 2>&1
check "first reconcile: kid-late adopted with no epic"      '.workers["kid-late"].beadsEpic == null and .workers["kid-set"].beadsEpic == "ep-1"'
census "lane-a:cm:running
cm:child kid-late epic=ep-open
cm:child kid-set epic=ep-2" "kid-late:cm:running" "kid-set:cm:running" > "$ROOT/ad5b.json"
"$FU" reconcile --discover "$ROOT/ad5b.json" >/dev/null 2>&1
check "epic=ep-open added later becomes beadsEpic"          '.workers["kid-late"].beadsEpic == "ep-open"'
check "an epic already set is never replaced"               '.workers["kid-set"].beadsEpic == "ep-1"'
check "a different epic declared against a set one is a recorded conflict" '.workers["kid-set"].epicConflict == ["ep-1","ep-2"]'
census "lane-a:cm:running
cm:child kid-late epic=ep-open
cm:child kid-set epic=ep-1" "kid-late:cm:running" "kid-set:cm:running" > "$ROOT/ad5f.json"
"$FU" reconcile --discover "$ROOT/ad5f.json" >/dev/null 2>&1
check "the declaration agrees with the set epic again: conflict cleared" '.workers["kid-set"] | .beadsEpic == "ep-1" and (has("epicConflict") | not)'
check "the late fill leaves the other worker fields alone"  '.workers["kid-late"] | .standing == false and .adopted == true and .parent == "lane-a" and .state == "running"'
adoptseed
jq '.workers["lane-b"] = {"host":"local","path":"/w/lane-b","lane":"lane-b","state":"running","standing":true}' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
census "lane-a:cm:running
cm:child kid-late2" "kid-late2:cm:running" > "$ROOT/ad5c.json"
"$FU" reconcile --discover "$ROOT/ad5c.json" >/dev/null 2>&1
census "lane-a:cm:running
cm:child kid-late2 epic=ep-1" "lane-b:cm:running
cm:child kid-late2 epic=ep-8" "kid-late2:cm:running" > "$ROOT/ad5d.json"
OUT="$("$FU" reconcile --discover "$ROOT/ad5d.json" 2>&1)"
check "two different epics added later: none is filled in"  '.workers["kid-late2"].beadsEpic == null'
check "the late conflict is recorded on the worker"         '.workers["kid-late2"].epicConflict == ["ep-1","ep-8"]'
if printf '%s' "$OUT" | grep -q 'followups: epic-conflict kid-late2'; then ok "reports the late epic-conflict"; else bad "no epic-conflict line" "$OUT"; fi
census "lane-a:cm:running
cm:child kid-late2 epic=ep-1" "kid-late2:cm:running" > "$ROOT/ad5g.json"
"$FU" reconcile --discover "$ROOT/ad5g.json" >/dev/null 2>&1
check "one claimant read, the other host unreadable: conflict stays" '.workers["kid-late2"] | .beadsEpic == null and .epicConflict == ["ep-1","ep-8"]'
census "kid-late2:cm:running" > "$ROOT/ad5h.json"
"$FU" reconcile --discover "$ROOT/ad5h.json" >/dev/null 2>&1
check "empty census: conflict stays"                        '.workers["kid-late2"].epicConflict == ["ep-1","ep-8"]'
census "lane-a:cm:running
cm:child kid-late2 epic=ep-1" "lane-b:cm:running
cm:child kid-late2 epic=ep-1" "kid-late2:cm:running" > "$ROOT/ad5e.json"
"$FU" reconcile --discover "$ROOT/ad5e.json" >/dev/null 2>&1
check "leads agree later: epic filled, conflict cleared"    '.workers["kid-late2"] | .beadsEpic == "ep-1" and (has("epicConflict") | not)'

echo "-- a child that declares a grandchild: both are adopted in one reconcile and the follow-up is seen"
adoptseed
census "lane-a:cm:running
cm:child kid-top" "kid-top:cm:done finished
cm:child kid-gk" "kid-gk:cm:running
cm:followup gk-fu owner=owner-b keep this alive" > "$ROOT/ad9.json"
"$FU" reconcile --discover "$ROOT/ad9.json" >/dev/null 2>&1
check "the grandchild is adopted too"                       '.workers["kid-gk"] | .adopted == true and .standing == false and .parent == "kid-top"'
check "the grandchild's open follow-up is in the ledger"    '[.followUps[] | select(.id == "gk-fu" and .state == "open")] | length == 1'

echo "-- one worktree named by its display name and its folder is adopted once"
adoptseed
printf '{"worktrees":[{"host":"local","path":"/w/lane-a","comment":"cm:running\\ncm:child friendly\\ncm:child kid-dir"},{"host":"local","path":"/w/kid-dir","displayName":"friendly","comment":"cm:running"}]}' > "$ROOT/ad10.json"
OUT="$("$FU" reconcile --discover "$ROOT/ad10.json" 2>&1)"
check "one ledger worker for the two names"                 '[.workers | to_entries[] | select(.value.path == "/w/kid-dir")] | length == 1'
check "it is keyed by its folder name"                      '.workers | has("kid-dir") and (has("friendly") | not)'
echo "-- two leads claim one child by its display name and its folder name: a parent conflict, not one winner"
adoptseed
jq '.workers["lane-b"] = {"host":"local","path":"/w/lane-b","lane":"lane-b","state":"running","standing":true}' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
printf '{"worktrees":[{"host":"local","path":"/w/lane-a","comment":"cm:running\\ncm:child pretty-child"},{"host":"local","path":"/w/lane-b","comment":"cm:running\\ncm:child folder-child"},{"host":"local","path":"/w/folder-child","displayName":"pretty-child","comment":"cm:running"}]}' > "$ROOT/ad13.json"
OUT="$("$FU" reconcile --discover "$ROOT/ad13.json" 2>&1)"
check "adopted once under the folder name, no parent chosen"  '.workers["folder-child"] | .adopted == true and .parent == null'
if printf '%s' "$OUT" | grep -q 'followups: parent-conflict folder-child lane-a,lane-b'; then ok "reports the parent conflict across the two names"; else bad "alias claimant dropped" "$OUT"; fi

echo "-- a stale cm:child line never adopts a same-named worktree of another repo"
adoptseed
printf '{"worktrees":[{"host":"local","repo":"app","path":"/w/lane-a","comment":"cm:running\\ncm:child kid-x"},{"host":"local","repo":"other-app","path":"/w/kid-x","comment":"cm:running"}]}' > "$ROOT/ad14.json"
"$FU" reconcile --discover "$ROOT/ad14.json" >/dev/null 2>&1
check "a worktree of another repo is not adopted"            '.workers | has("kid-x") | not'
printf '{"worktrees":[{"host":"local","repo":"app","path":"/w/lane-a","comment":"cm:running\\ncm:child kid-x"},{"host":"local","repo":"app","path":"/w/kid-x","comment":"cm:running"}]}' > "$ROOT/ad15.json"
"$FU" reconcile --discover "$ROOT/ad15.json" >/dev/null 2>&1
check "the same name in the poster's repo is adopted"        '.workers["kid-x"].adopted == true'

echo "-- a display-name claim never reaches a live worker of another repo"
adoptseed
jq '.workers["otherw"] = {"host":"local","path":"/w/otherw","lane":"lane-x","state":"running","standing":false,"adopted":true}' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
printf '{"worktrees":[{"host":"local","repo":"app","path":"/w/lane-a","comment":"cm:running\\ncm:child friendly epic=ep-x"},{"host":"local","repo":"other-app","path":"/w/otherw","displayName":"friendly","comment":"cm:running"}]}' > "$ROOT/ad16.json"
"$FU" reconcile --discover "$ROOT/ad16.json" >/dev/null 2>&1
check "the other repo worker gets no parent"                '.workers["otherw"].parent == null'
check "the other repo worker gets no epic"                  '.workers["otherw"].beadsEpic == null'

echo "-- a folder-name claim never reaches a live worker of another repo, and the poster's own child is still adopted"
adoptseed
jq '.workers["kid-other"] = {"host":"local","path":"/w/other/kid","lane":"lane-x","state":"running","standing":false,"adopted":true}' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
printf '{"worktrees":[{"host":"local","repo":"app","path":"/w/lane-a","comment":"cm:running\\ncm:child kid epic=ep-x"},{"host":"local","repo":"other-app","path":"/w/other/kid","comment":"cm:running"},{"host":"local","repo":"app","path":"/w/app/kid","comment":"cm:running"}]}' > "$ROOT/ad17.json"
"$FU" reconcile --discover "$ROOT/ad17.json" >/dev/null 2>&1
check "the other repo worker gets no parent"                '.workers["kid-other"].parent == null'
check "the other repo worker gets no epic"                  '.workers["kid-other"].beadsEpic == null'
check "the poster repo child is adopted under the folder name" '.workers["kid"].adopted == true and .workers["kid"].path == "/w/app/kid"'

echo "-- a standing lane is never adopted as a single-task child"
adoptseed
printf '{"worktrees":[{"host":"local","path":"/w/lane-a","comment":"cm:running\\ncm:child pr-sweeper\\ncm:child dev-sweeper\\ncm:child release-sweeper-host-a\\ncm:child sweep-77\\ncm:child research-cost-model\\ncm:child plain-kid"},{"host":"local","path":"/w/pr-sweeper","comment":"cm:running"},{"host":"local","path":"/w/dev-sweeper","comment":"cm:running"},{"host":"local","path":"/w/release-sweeper-host-a","comment":"cm:running"},{"host":"local","path":"/w/sweep-77","comment":"cm:running"},{"host":"local","path":"/w/research-cost-model","comment":"cm:running"},{"host":"local","path":"/w/plain-kid","comment":"cm:running"}]}' > "$ROOT/ad18.json"
OUT="$("$FU" reconcile --discover "$ROOT/ad18.json" 2>&1)"
check "pr-sweeper is not adopted"                           '.workers | has("pr-sweeper") | not'
check "dev-sweeper is not adopted"                          '.workers | has("dev-sweeper") | not'
check "a release-sweeper-style name is not adopted"         '.workers | has("release-sweeper-host-a") | not'
check "sweep-<pr> is a single-task name and is adopted"     '.workers["sweep-77"].standing == false'
check "research-<slug> is a single-task name and is adopted" '.workers["research-cost-model"].standing == false'
check "an ordinary child beside them is still adopted"      '.workers["plain-kid"] | .adopted == true and .standing == false'
if printf '%s' "$OUT" | grep -q 'followups: adopt-skipped pr-sweeper (lane-shaped name'; then ok "the lane-shaped claim is reported as adopt-skipped"; else bad "no adopt-skipped line" "$OUT"; fi
{ cat "$HERE/fixtures/config.test.yaml"; printf 'lanes:\n  - { name: triage, standing: true }\nownership:\n  leads:\n    demo-weird-name: demo-lane\n'; } > "$ROOT/config-lanes.yaml"
adoptseed
printf '{"worktrees":[{"host":"local","path":"/w/lane-a","comment":"cm:running\\ncm:child triage\\ncm:child demo-weird-name"},{"host":"local","path":"/w/triage","comment":"cm:running"},{"host":"local","path":"/w/demo-weird-name","comment":"cm:running"}]}' > "$ROOT/ad19.json"
CM_CONFIG="$ROOT/config-lanes.yaml" "$FU" reconcile --discover "$ROOT/ad19.json" >/dev/null 2>&1
check "a configured lane name is not adopted"               '.workers | has("triage") | not'
check "a configured ownership lead is not adopted"          '.workers | has("demo-weird-name") | not'

echo "-- two unledgered worktrees with one name are ambiguous: neither is adopted"
adoptseed
printf '{"worktrees":[{"host":"local","path":"/w/lane-a","comment":"cm:running\\ncm:child twin"},{"host":"local","path":"/w/a/twin","comment":"cm:running"},{"host":"local","path":"/w/b/twin","comment":"cm:running"}]}' > "$ROOT/ad20.json"
OUT="$("$FU" reconcile --discover "$ROOT/ad20.json" 2>&1)"
check "neither twin is adopted"                             '.workers | has("twin") | not'
if printf '%s' "$OUT" | grep -q 'followups: adopt-ambiguous twin'; then ok "the ambiguous name is reported"; else bad "no adopt-ambiguous line" "$OUT"; fi

echo "-- an epic declared under the display name of an adopted child"
adoptseed
census "lane-a:cm:running
cm:child kid-dir" > /dev/null
printf '{"worktrees":[{"host":"local","path":"/w/lane-a","comment":"cm:running\\ncm:child kid-dir"},{"host":"local","path":"/w/kid-dir","displayName":"friendly","comment":"cm:running"}]}' > "$ROOT/ad11a.json"
"$FU" reconcile --discover "$ROOT/ad11a.json" >/dev/null 2>&1
printf '{"worktrees":[{"host":"local","path":"/w/lane-a","comment":"cm:running\\ncm:child friendly epic=ep-open"},{"host":"local","path":"/w/kid-dir","displayName":"friendly","comment":"cm:running"}]}' > "$ROOT/ad11b.json"
"$FU" reconcile --discover "$ROOT/ad11b.json" >/dev/null 2>&1
check "epic=ep-open declared under the display name reaches the worker" '.workers["kid-dir"].beadsEpic == "ep-open"'

echo "-- two leads claim one child: a declared epic is kept, different epics are a conflict"
adoptseed
jq '.workers["lane-b"] = {"host":"local","path":"/w/lane-b","lane":"lane-b","state":"running","standing":true}' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
census "lane-a:cm:running
cm:child kid-ep1
cm:child kid-ep2 epic=ep-1
cm:child kid-ep3" "lane-b:cm:running
cm:child kid-ep1 epic=ep-9
cm:child kid-ep2
cm:child kid-ep3 epic=ep-8" "kid-ep1:cm:running" "kid-ep2:cm:running" "kid-ep3:cm:running" > "$ROOT/ad6.json"
OUT="$("$FU" reconcile --discover "$ROOT/ad6.json" 2>&1)"
check "one claim without epic, one with: the epic is kept"  '.workers["kid-ep1"].beadsEpic == "ep-9"'
check "the epic survives whichever lead is read first"      '.workers["kid-ep2"].beadsEpic == "ep-1"'
adoptseed
jq '.workers["lane-b"] = {"host":"local","path":"/w/lane-b","lane":"lane-b","state":"running","standing":true}' "$L" > "$ROOT/p.json" && mv "$ROOT/p.json" "$L"
census "lane-a:cm:running
cm:child kid-ep3 epic=ep-1" "lane-b:cm:running
cm:child kid-ep3 epic=ep-8" "kid-ep3:cm:running" > "$ROOT/ad7.json"
OUT="$("$FU" reconcile --discover "$ROOT/ad7.json" 2>&1)"
check "two different epics: not adopted"                    '.workers | has("kid-ep3") | not'
if printf '%s' "$OUT" | grep -q 'followups: adopt-conflict kid-ep3'; then ok "reports the adopt-conflict"; else bad "no adopt-conflict line" "$OUT"; fi

echo "-- two epic= tokens on one cm:child line are a conflict, not the first one"
adoptseed
census "lane-a:cm:running
cm:child kid-twice epic=ep-closed epic=ep-open" "kid-twice:cm:running" > "$ROOT/ad12.json"
OUT="$("$FU" reconcile --discover "$ROOT/ad12.json" 2>&1)"
check "a child declaring two different epics is not adopted" '.workers | has("kid-twice") | not'
if printf '%s' "$OUT" | grep -q 'followups: adopt-conflict kid-twice'; then ok "reports the adopt-conflict for two tokens"; else bad "no adopt-conflict for two tokens" "$OUT"; fi

echo "-- a host-qualified cm:child (name@host) adopts the child on that host"
adoptseed
printf '%s' '{"worktrees":[
 {"host":"local","path":"/w/lane-a","comment":"cm:running\ncm:child kid-far@host-b epic=ep-3\ncm:child kid-near"},
 {"host":"host-b","path":"/w/kid-far","comment":"cm:running far"},
 {"host":"local","path":"/w/kid-far","comment":"cm:running same name, other host"},
 {"host":"local","path":"/w/kid-near","comment":"cm:running near"}]}' > "$ROOT/ad8.json"
OUT="$("$FU" reconcile --discover "$ROOT/ad8.json" 2>&1)"
check "name@host adopts the row on host-b"               '.workers["kid-far"] | .host == "host-b" and .path == "/w/kid-far" and .beadsEpic == "ep-3" and .parent == "lane-a"'
check "the same name on the poster's host is not taken"   '.workers["kid-far"].host == "host-b"'
check "an unqualified name still means the poster's host" '.workers["kid-near"] | .host == "local" and .standing == false'

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
