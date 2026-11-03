#!/usr/bin/env bash
# shellcheck disable=SC2015  # "A && ok || bad": ok never fails
# followups.sh escalate: behaviour tests with a stubbed gh on a temp CM_HOME. No network, never the live
# ledger. gh answers `api rate_limit` and `issue create`; every call is logged, nothing is really created.
#
#   scripts/test/followups-escalate.sh            # exit 0 when every case passes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
unset CM_ORG CM_REPO CM_PROJECT CM_OWNER_NAME CM_OWNER_ID CM_TZ CM_TZ_LABEL CM_EXCLUDE_REPOS CM_PATH_MATCH CM_SELF_WORKTREE CM_LEDGER
command -v jq >/dev/null 2>&1 || { echo "missing dependency: jq" >&2; exit 1; }
FU="$HERE/../followups.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cm-fu-escalate.XXXXXX")" || { echo "cannot create a temp dir" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "temp dir missing" >&2; exit 1; }
trap 'rm -rf -- "${ROOT:?}"' EXIT
mkdir -p "$ROOT/bin" "$ROOT/stub" "$ROOT/cmhome"
export CM_HOME="$ROOT/cmhome" STUB="$ROOT/stub" PATH="$ROOT/bin:$PATH" HOME="$ROOT/home"
mkdir -p "$HOME"
{ cat "$HERE/fixtures/config.test.yaml"; printf 'followups:\n  issue_labels: [follow-up, concertmaster]\n'; } > "$ROOT/config.yaml"
export CM_CONFIG="$ROOT/config.yaml" CM_FOLLOWUPS_FLOOR_S=0
L="$CM_HOME/ledger.json"

# gh stub: `api rate_limit ...` prints $STUB/remaining (default 4000, rc $STUB/rate.rc); `issue create ...`
# logs its args, saves the body file, prints an issue URL (counter in $STUB/next, default 100) or fails with $STUB/create.rc.
cat > "$ROOT/bin/gh" <<'S'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB/gh.log"
printf '%s\n' "$@" >> "$STUB/args.log"
[ -f "$STUB/rate.sleep" ] && [ "$1 $2" = "api rate_limit" ] && sleep "$(cat "$STUB/rate.sleep")"
[ -f "$STUB/rate.hook" ] && [ "$1 $2" = "api rate_limit" ] && "$(cat "$STUB/rate.hook")"
case "$1 $2" in
  "api rate_limit")
    [ -f "$STUB/rate.rc" ] && exit "$(cat "$STUB/rate.rc")"
    cat "$STUB/remaining" 2>/dev/null || echo 4000 ;;
  "issue list")
    [ -f "$STUB/list.rc" ] && { echo "gh: HTTP 502 stub" >&2; exit "$(cat "$STUB/list.rc")"; }
    cat "$STUB/list.out" 2>/dev/null || echo '[]' ;;
  "issue create")
    rc=0; [ -f "$STUB/create.rc" ] && rc="$(cat "$STUB/create.rc")"
    [ "$rc" != 0 ] && { if [ -f "$STUB/create.err" ]; then cat "$STUB/create.err" >&2; else echo "gh: HTTP 403 stub" >&2; fi; exit "$rc"; }
    [ -f "$STUB/create.out" ] && { cat "$STUB/create.out"; exit 0; }
    [ -f "$STUB/create.closes" ] && jq --arg id "$(cat "$STUB/create.closes")" '(.followUps[] | select(.id == $id) | .state) = "done"' "$CM_HOME/ledger.json" > "$CM_HOME/ledger.tmp" && mv "$CM_HOME/ledger.tmp" "$CM_HOME/ledger.json"
    next="$(cat "$STUB/next" 2>/dev/null || echo 100)"
    while [ $# -gt 0 ]; do [ "$1" = "--body-file" ] && cp "$2" "$STUB/body.$next"; shift; done
    echo $((next + 1)) > "$STUB/next"
    echo "https://github.com/AcmeOrg/acme-app/issues/$next" ;;
  *) echo "gh stub: unexpected call: $*" >&2; exit 64 ;;
esac
S
chmod +x "$ROOT/bin/gh"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n%s\n' "$1" "${2:-}"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "want [$3] in: $2" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "unexpected [$3] in: $2" ;; *) ok "$1" ;; esac; }
ago() { jq -nr --argjson h "$1" 'now - $h * 3600 | floor | todate'; }
fpof() { printf '%s\n%s' "$(jq -c --arg id "$1" '[.followUps[] | select(.id == $id)][0] | (.owner // "")' "$L")" "$(jq -c --arg id "$1" '[.followUps[] | select(.id == $id)][0] | (.text // "")' "$L")" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-10; }
creates() { local c; c="$(grep -c '^issue create' "$STUB/gh.log" 2>/dev/null || true)"; printf '%s\n' "${c:-0}"; }
fu_issue() { jq -r --arg id "$1" '[.followUps[] | select(.id == $id)][0].issue // "none"' "$L"; }

LEAK="use the token gh""p_ABCDEFGHIJKLMNOPQRSTUVWX1234 to retry"   # split so no scanner sees a key
seed() {
  rm -rf -- "${STUB:?}"/* "${CM_HOME:?}"/.followups-escalate.stamp
  jq -n --arg leak "$LEAK" --arg pathleak "see /ho""me/x/.secrets/creds" --arg o30 "$(ago 30)" --arg o2 "$(ago 2)" --arg o1 "$(ago 1)" '{
    workers: {
      "w-a": {host: "local", path: "/w/wt-a", lane: "lane-a", state: "running"},
      "w-b": {host: "local", path: "/w/wt-b", lane: "lane-b", state: "running"}},
    lanes: {"lane-a": {lead: "w-a", state: "running"}, "lane-b": {lead: "w-b", state: "running"}},
    followUps: [
      {id: "young-same", worker: "w-a", lane: "lane-a", owner: "lane-a", text: "fresh and same lane", state: "open", openedAt: $o2},
      {id: "old-same", worker: "w-a", lane: "lane-a", owner: "w-a", text: "validate the codes after load", state: "open", openedAt: $o30},
      {id: "cross-lane", worker: "w-a", lane: "lane-a", owner: "lane-b", text: "needs the dev lane", state: "open", openedAt: $o1},
      {id: "cross-worker", worker: "w-a", lane: "lane-a", owner: "w-b", text: "needs worker b", state: "open", openedAt: $o1},
      {id: "owner-young", worker: "w-a", lane: "lane-a", owner: "owner", text: "owner decision", state: "open", openedAt: $o1},
      {id: "old-done", worker: "w-a", lane: "lane-a", owner: "w-a", text: "closed already", state: "done", openedAt: $o30, closedAt: $o2},
      {id: "has-issue", worker: "w-a", lane: "lane-a", owner: "w-a", text: "already escalated", state: "open", openedAt: $o30, issue: 77},
      {id: "leaky", worker: "w-a", lane: "lane-a", owner: "w-a", text: $leak, state: "open", openedAt: $o30},
      {id: "path-leak", worker: "w-a", lane: "lane-a", owner: "w-a", text: $pathleak, state: "open", openedAt: $o30}]}' > "$L"
}

# 1. dry run (the default): says what it would create, creates and writes nothing
seed; cp "$L" "$ROOT/before.json"
out="$("$FU" escalate 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok "dry run: exit 1 (the seed holds one refused text)" || bad "dry run rc" "$rc $out"
has "dry run: old same-lane item would be created" "$out" "would create: [lane-a/old-same] follow-up old-same: validate the codes after load"
has "dry run: owner in another lane would be created" "$out" "[lane-a/cross-lane]"
has "dry run: owner worker of another lane would be created" "$out" "[lane-a/cross-worker]"
has "dry run: reason names the cross-lane owner" "$out" "owner lane lane-b differs from the posting lane lane-a"
has "dry run: labels shown" "$out" "labels: follow-up concertmaster"
lacks "dry run: a young same-lane item is skipped" "$out" "young-same"
lacks "dry run: a young item owned by the project owner is skipped" "$out" "owner-young"
lacks "dry run: a closed item is skipped" "$out" "old-done"
lacks "dry run: an item with an issue is skipped" "$out" "has-issue"
has "dry run: a credential-looking text is refused" "$out" "escalate refused lane-a/leaky"
has "dry run: a private path is refused" "$out" "escalate refused lane-a/path-leak"
lacks "dry run: the refused text is never printed" "$out" "gh""p_ABCDEF"
[ ! -e "$STUB/gh.log" ] && ok "dry run: gh is not called at all" || bad "dry run gh" "$(cat "$STUB/gh.log")"
cmp -s "$ROOT/before.json" "$L" && ok "dry run: the ledger is untouched" || bad "dry run ledger" "changed"

# 2. --create: one issue each for the three eligible items, number recorded, body has owner, worktree and age
out="$("$FU" escalate --create --all-candidates 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok "create: exit 1 (the seed holds one refused text), the others are created" || bad "create rc" "$rc $out"
[ "$(creates)" = 3 ] && ok "create: three issues made (old, cross-lane, cross-worker)" || bad "create count" "$(creates): $(cat "$STUB/gh.log")"
has "create: repo from config" "$(cat "$STUB/gh.log")" "-R AcmeOrg/acme-app"
has "create: labels from config" "$(cat "$STUB/gh.log")" "--label follow-up --label concertmaster"
has "create: title from id and text" "$(cat "$STUB/gh.log")" "--title follow-up old-same: validate the codes after load"
[ "$(fu_issue old-same)" = 100 ] && ok "create: the issue number is on the follow-up" || bad "old-same issue" "$(fu_issue old-same)"
[ "$(jq -r '[.followUps[] | select(.id == "old-same")][0].issueUrl' "$L")" = "https://github.com/AcmeOrg/acme-app/issues/100" ] && ok "create: the issue url is recorded" || bad "issueUrl" ""
[ "$(fu_issue cross-lane)" != none ] && [ "$(fu_issue cross-worker)" != none ] && ok "create: cross-lane items marked too" || bad "cross marked" ""
[ "$(fu_issue young-same)" = none ] && [ "$(fu_issue leaky)" = none ] && [ "$(fu_issue path-leak)" = none ] && ok "create: skipped and refused items stay unmarked" || bad "unmarked" ""
body="$(cat "$STUB/body.100")"
has "body: owner" "$body" "owner: w-a"
has "body: source worktree name, no path" "$body" "source worktree: wt-a"
lacks "body: no path" "$body" "/w/"
has "body: age" "$body" "(30h)"
has "body: the text" "$body" "validate the codes after load"
[ "$(jq -r '.followUps | length' "$L")" = 9 ] && ok "create: no follow-up added or dropped" || bad "count" ""

# 3. a second run does not duplicate
: > "$STUB/gh.log"
out="$("$FU" escalate --create --all-candidates 2>&1)"
[ "$(creates)" = 0 ] && ok "second run: no second issue" || bad "second run" "$(cat "$STUB/gh.log")"
has "second run: refused ones are still reported" "$out" "refused lane-a/leaky"
# a reconcile after the escalation keeps the recorded issue
printf '{"worktrees":[{"host":"local","path":"/w/wt-a","worktreeId":null,"comment":"cm:followup old-same owner=w-a validate the codes after load"}]}' | "$FU" reconcile >/dev/null 2>&1
[ "$(fu_issue old-same)" = 100 ] && ok "reconcile keeps the recorded issue" || bad "reconcile" "$(fu_issue old-same)"

# 4. gh failure leaves the follow-up unmarked, stops the run (no retry loop), exits non-zero
seed; echo 1 > "$STUB/create.rc"
out="$("$FU" escalate --create --all-candidates 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok "gh failure: non-zero exit" || bad "gh failure rc" "$rc"
[ "$(creates)" = 1 ] && ok "gh failure: one attempt, then the run stops" || bad "gh failure attempts" "$(creates)"
[ "$(jq '[.followUps[] | select(.issue != null)] | length' "$L")" = 1 ] && ok "gh failure: nothing marked (only the pre-existing issue)" || bad "gh failure marks" "$(jq -c '[.followUps[] | .issue]' "$L")"
has "gh failure: says it left the item unmarked" "$out" "left unmarked"
rm -f "$STUB/create.rc"; : > "$STUB/gh.log"
"$FU" escalate --create --all-candidates >/dev/null 2>&1
[ "$(creates)" = 3 ] && ok "after the failure: the next run creates them" || bad "retry" "$(creates)"
# 4d. reconcile changes the follow-up between the candidate read and the claim: no issue is made from the old text
seed
cat > "$ROOT/edit-ledger.sh" <<EDIT
#!/usr/bin/env bash
jq '(.followUps[] | select(.id == "old-same") | .text) = "a different text now"' "$L" > "$L.tmp" && mv "$L.tmp" "$L"
EDIT
chmod +x "$ROOT/edit-ledger.sh"; echo "$ROOT/edit-ledger.sh" > "$STUB/rate.hook"
out="$("$FU" escalate --create --all-candidates 2>&1)"
if grep -q 'follow-up old-same' "$STUB/gh.log"; then bad "changed after the read: no issue from the old text" "$(grep 'old-same' "$STUB/gh.log")"; else ok "changed after the read: no issue from the old text"; fi
has "changed after the read: says it will retry next run" "$out" "changed since it was read"
rm -f "$STUB/rate.hook"
# 4c. the follow-up is closed while gh runs: the issue is still recorded against the claim
seed; echo old-same > "$STUB/create.closes"
out="$("$FU" escalate --create --all-candidates 2>&1)"; rc=$?
[ "$(jq -r '[.followUps[] | select(.id == "old-same")][0] | "\(.state) \(.issue // "none") \(.escalatingAt // "clear")"' "$L")" = "done 100 clear" ] && ok "closed during gh: the issue is recorded, the state kept" || bad "closed during gh" "$(jq -c '[.followUps[] | select(.id == "old-same")]' "$L") :: $out"
rm -f "$STUB/create.closes"
# a closed item that kept a claim can still be resolved
seed; echo 124 > "$STUB/create.rc"; "$FU" escalate --create --all-candidates >/dev/null 2>&1; rm -f "$STUB/create.rc"
jq '(.followUps[] | select(.id == "old-same") | .state) = "done"' "$L" > "$L.tmp" && mv "$L.tmp" "$L"
"$FU" escalate --resolve lane-a/old-same 321 >/dev/null 2>&1
[ "$(fu_issue old-same)" = 321 ] && ok "--resolve works on a closed item that kept a claim" || bad "resolve closed" "$(fu_issue old-same)"
# 4b. exit 1 with no refusal (dropped connection, 5xx): GitHub may have made the issue, so the claim stays
seed; echo 1 > "$STUB/create.rc"; echo "error connecting to api.github.com" > "$STUB/create.err"
out="$("$FU" escalate --create --all-candidates 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok "ambiguous exit 1: non-zero exit" || bad "ambiguous rc" "$rc"
has "ambiguous exit 1: says the issue may exist" "$out" "the issue may exist"
[ "$(jq -r '[.followUps[] | select(.id == "old-same")][0].escalatingAt // "none"' "$L")" != none ] && ok "ambiguous exit 1: the claim stays" || bad "ambiguous claim" ""
echo "HTTP 502: Bad Gateway" > "$STUB/create.err"; seed; echo 1 > "$STUB/create.rc"; echo "HTTP 502: Bad Gateway" > "$STUB/create.err"
"$FU" escalate --create --all-candidates >/dev/null 2>&1
[ "$(jq -r '[.followUps[] | select(.id == "old-same")][0].escalatingAt // "none"' "$L")" != none ] && ok "HTTP 5xx: the claim stays" || bad "5xx claim" ""
rm -f "$STUB/create.err" "$STUB/create.rc"

# 5. budget and poll floor
seed; echo 700 > "$STUB/remaining"
out="$("$FU" escalate --create --all-candidates 2>&1)"
has "budget under 800: skipped" "$out" "budget low (700 calls left"
[ "$(creates)" = 0 ] && ok "budget under 800: nothing created" || bad "budget create" "$(creates)"
seed; echo 1 > "$STUB/rate.rc"
out="$("$FU" escalate --create --all-candidates 2>&1)"
has "budget unreadable: skipped, never assumed" "$out" "budget could not be read"
[ "$(creates)" = 0 ] && ok "budget unreadable: nothing created" || bad "unreadable create" "$(creates)"
seed
out="$(CM_FOLLOWUPS_FLOOR_S=180 "$FU" escalate --create --all-candidates 2>&1)"
[ "$(creates)" = 3 ] && ok "poll floor: the first run goes" || bad "floor first" "$(creates)"
seed; mkdir -p "$CM_HOME"; : > "$CM_HOME/.followups-escalate.stamp"
out="$(CM_FOLLOWUPS_FLOOR_S=180 "$FU" escalate --create --all-candidates 2>&1)"
has "poll floor: a run inside 180 s of the last one does nothing" "$out" "poll floor"
[ ! -e "$STUB/gh.log" ] && ok "poll floor: gh not called" || bad "floor gh" "$(cat "$STUB/gh.log")"
seed; out="$("$FU" escalate 2>&1)"
[ ! -e "$STUB/gh.log" ] && ok "dry run never spends a gh call (not even rate_limit)" || bad "dry gh" ""

# 6. limits and arguments
seed; "$FU" escalate --create --all-candidates --max 1 >/dev/null 2>&1
[ "$(creates)" = 1 ] && ok "--max 1: one issue" || bad "--max" "$(creates)"
seed; out="$("$FU" escalate --after-hours 100 2>&1)"
lacks "--after-hours 100: the 30h item is no longer old" "$out" "old-same"
has "--after-hours 100: cross-lane items still escalate" "$out" "[lane-a/cross-lane]"
seed; out="$("$FU" escalate --after-hours abc 2>&1)"; rc=$?
[ "$rc" = 2 ] && ok "bad --after-hours: usage, exit 2" || bad "after rc" "$rc"
out="$("$FU" escalate --bogus 2>&1)"; rc=$?
[ "$rc" = 2 ] && ok "unknown flag: exit 2" || bad "flag rc" "$rc"
jq 'del(.followUps)' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
has "no follow-ups: a calm line, exit 0" "$("$FU" escalate 2>&1)" "nothing old or cross-lane"
printf '{"followUps":"oops"}' > "$L"
out="$("$FU" escalate 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok "followUps not an array: exit 1" || bad "bad ledger rc" "$rc"


# 7. dedupe holes (claim before gh; a claim is never released by a timeout; two runs at once)
seed; echo 124 > "$STUB/create.rc"
out="$("$FU" escalate --create --all-candidates 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok "gh timeout: non-zero exit" || bad "timeout rc" "$rc"
has "gh timeout: says the issue may exist" "$out" "the issue may exist"
[ "$(jq -r '[.followUps[] | select(.id == "old-same")][0].escalatingAt // "none"' "$L")" != none ] && ok "gh timeout: the claim stays on the follow-up" || bad "timeout claim" ""
rm -f "$STUB/create.rc"; : > "$STUB/gh.log"
out="$("$FU" escalate --create --all-candidates 2>&1)"
has "after a timeout: the claimed item is reported verify-by-hand" "$out" "verify by hand lane-a/old-same"
if grep -q 'follow-up old-same' "$STUB/gh.log"; then bad "after a timeout: no second create for the claimed item" "$(cat "$STUB/gh.log")"; else ok "after a timeout: no second create for the claimed item"; fi
seed; echo 1 > "$STUB/create.rc"; "$FU" escalate --create --all-candidates >/dev/null 2>&1
[ "$(jq -r '[.followUps[] | select(.escalatingAt != null)] | length' "$L")" = 0 ] && ok "plain gh failure: the claim is released" || bad "release" "$(jq -c '[.followUps[] | .escalatingAt]' "$L")"

seed; echo 1 > "$STUB/rate.sleep"
( "$FU" escalate --create --all-candidates >"$ROOT/r1.out" 2>&1 & "$FU" escalate --create --all-candidates >"$ROOT/r2.out" 2>&1 & wait )
n="$(grep -c '^issue create' "$STUB/gh.log" 2>/dev/null || true)"
[ "$n" = 3 ] && ok "two runs at once: three issues in all, none twice" || bad "concurrent" "creates=$n $(cat "$STUB/gh.log")"
[ "$(jq -r '[.followUps[] | select(.issue != null)] | map(.issue) | unique | length' "$L")" = 4 ] && ok "two runs at once: every number recorded once" || bad "concurrent numbers" "$(jq -c '[.followUps[] | .issue]' "$L")"

# rows that cannot be keyed are skipped, never "created" without a record
seed; jq '.followUps += [{id: 5, worker: "w-a", lane: "lane-a", owner: "w-a", text: "numeric id", state: "open", openedAt: (now - 90000 | todate)},
  {id: "nolane", worker: "w-a", lane: null, owner: "w-a", text: "null lane", state: "open", openedAt: (now - 90000 | todate)},
  {id: "noworker", worker: null, lane: "lane-a", owner: "w-a", text: "null worker", state: "open", openedAt: (now - 90000 | todate)}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
out="$("$FU" escalate --create --all-candidates 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok "odd rows: the run still works (exit 1: the seed holds refused texts)" || bad "odd rows rc" "$rc $out"
lacks "odd rows: numeric id and null lane are not created" "$out" "numeric id"
has "odd rows: a null worker still gets its issue" "$out" "created: [lane-a/noworker]"

# the guard: more key shapes, private paths; ordinary text passes
for t in 'key sk''-ant-api03-abcdefghijklmnop' 'key sk''-proj-abcdefghijklmnopqrst' 'sk_li''ve_abcdefgh12345' 'whs''ec_abcdefgh12345' 'sb_sec''ret_abcdefgh1234' \
         'sb''p_abcdefghijkl1234' 'jwt ey''JhbGciOiJIUzI1.ey''JzdWIiOiIxMjM0.abc' 'xo''xb-12345678-abcdefgh' 'AI''zaSyA-abcdefghijklmnopqrstu' 'tok''en: abcdef123456' \
         'pass''word = hunter22xy' 'look in /ro''ot/.ssh/x' 'edit the .env file' 'gh''p_ABCDEFGHIJKLMNOPQRSTUV1234'; do
  seed; jq --arg t "$t" '.followUps += [{id: "g1", worker: "w-a", lane: "lane-a", owner: "w-a", text: $t, state: "open", openedAt: (now - 90000 | todate)}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
  out="$("$FU" escalate 2>&1)"
  has "guard refuses: $t" "$out" "refused lane-a/g1"
done
for t in 'token:refresh must run after the deploy' 'see the /ho''me route and the token flow' 'add a .envelope field'; do
  seed; jq --arg t "$t" '.followUps += [{id: "g2", worker: "w-a", lane: "lane-a", owner: "w-a", text: $t, state: "open", openedAt: (now - 90000 | todate)}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
  out="$("$FU" escalate 2>&1)"
  has "guard allows ordinary text: $t" "$out" "would create: [lane-a/g2]"
done

# labels are one argument each (spaces and globs survive); the body shows an @name and #n inside a code block
cat "$HERE/fixtures/config.test.yaml" > "$ROOT/config2.yaml"; printf 'followups:\n  issue_labels: ["good first issue", "*"]\n' >> "$ROOT/config2.yaml"
seed; CM_CONFIG="$ROOT/config2.yaml" "$FU" escalate --create --all-candidates >/dev/null 2>&1
has "labels: a label with spaces is one argument" "$(cat "$STUB/args.log")" $'--label\ngood first issue'
has "labels: a glob stays literal" "$(cat "$STUB/args.log")" $'--label\n*'
seed; jq '.followUps[1].text = "ping @someone about #12"' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
"$FU" escalate --create --all-candidates >/dev/null 2>&1
has "body: the follow-up text sits in an indented block" "$(cat "$STUB/body.100")" "    ping @someone about #12"

# arguments
"$FU" escalate --max >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "--max with no value: exit 2" || bad "--max empty rc" "$rc"
"$FU" escalate --after-hours >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "--after-hours with no value: exit 2" || bad "--after empty rc" "$rc"

# the project owner id is not a lane: even a lane named like it does not make an item cross-lane
seed; jq '.lanes.owner = {lead: "w-b", state: "running"}' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
lacks "project owner id: not cross-lane even when a lane has that name" "$("$FU" escalate 2>&1)" "owner-young"

# an owner that is a worker with no lane counts as its own lane (reconcile uses lane // id)
seed; jq '.workers["w-nolane"] = {host: "local", path: "/w/x", state: "running"} | .followUps += [{id: "to-nolane", worker: "w-a", lane: "lane-a", owner: "w-nolane", text: "x", state: "open", openedAt: (now - 600 | todate)}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
has "owner worker without a lane: cross-lane" "$("$FU" escalate 2>&1)" "[lane-a/to-nolane]"


# 8. review round 2: ambiguous exits, unreadable answers, --resolve, guard boundaries
seed; echo 142 > "$STUB/create.rc"; "$FU" escalate --create --all-candidates >/dev/null 2>&1
[ "$(jq -r '[.followUps[] | select(.id == "old-same")][0].escalatingAt // "none"' "$L")" != none ] && ok "exit 142 (perl alarm): the claim stays" || bad "142 claim" ""
rm -f "$STUB/create.rc"; : > "$STUB/gh.log"; "$FU" escalate --create --all-candidates >/dev/null 2>&1
if grep -q 'follow-up old-same' "$STUB/gh.log"; then bad "exit 142: no second issue" "$(cat "$STUB/gh.log")"; else ok "exit 142: no second issue for the claimed item"; fi

seed; echo "ok" > "$STUB/create.out"
out="$("$FU" escalate --create --all-candidates 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok "unreadable answer: non-zero exit" || bad "unreadable rc" "$rc"
has "unreadable answer: tells how to resolve" "$out" "escalate --resolve lane-a/old-same"
[ "$(jq -r '[.followUps[] | select(.id == "old-same")][0] | "\(.escalatingAt != null) \(.issueUrl // "none") \(.issue // "none")"' "$L")" = "true none none" ] && ok "unreadable answer: claim kept, no url or number stored" || bad "unreadable state" "$(jq -c '.followUps[] | select(.id == "old-same")' "$L")"
rm -f "$STUB/create.out"; : > "$STUB/gh.log"
out="$("$FU" escalate 2>&1)"
has "unreadable answer: reported verify by hand every run" "$out" "verify by hand lane-a/old-same"

"$FU" escalate --resolve lane-a/old-same 321 >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(fu_issue old-same)" = 321 ] && ok "--resolve <n>: number recorded" || bad "resolve n" "rc=$rc $(fu_issue old-same)"
[ "$(jq -r '[.followUps[] | select(.id == "old-same")][0] | "\(.escalatingAt // "none") \(.issueUrl)"' "$L")" = "none https://github.com/AcmeOrg/acme-app/issues/321" ] && ok "--resolve <n>: claim cleared, url built from config" || bad "resolve url" ""
"$FU" escalate --resolve lane-a/old-same 5 >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "--resolve with no open claim: exit 1" || bad "resolve none" "rc=$rc"
seed; echo 124 > "$STUB/create.rc"; "$FU" escalate --create --all-candidates >/dev/null 2>&1; rm -f "$STUB/create.rc"
"$FU" escalate --resolve lane-a/old-same release >/dev/null 2>&1
[ "$(jq -r '[.followUps[] | select(.id == "old-same")][0].escalatingAt // "none"' "$L")" = none ] && ok "--resolve release: claim cleared" || bad "resolve release" ""
: > "$STUB/gh.log"; "$FU" escalate --create --all-candidates >/dev/null 2>&1
grep -q 'follow-up old-same' "$STUB/gh.log" && ok "--resolve release: the next run may create it" || bad "after release" "$(cat "$STUB/gh.log")"
"$FU" escalate --resolve badform 1 >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "--resolve bad form: exit 2" || bad "resolve form" "rc=$rc"
"$FU" escalate --resolve lane-a/old-same abc >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "--resolve bad number: exit 2" || bad "resolve num" "rc=$rc"

for id in ask-owner-about-billing-copy task-list-refactor-v2 risk-assessment-follow-up DISK-USAGE-DASHBOARD-WIDGET; do
  seed; jq --arg id "$id" '.followUps += [{id: $id, worker: "w-a", lane: "lane-a", owner: "w-a", text: "plain text", state: "open", openedAt: (now - 90000 | todate)}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
  has "guard allows the id $id" "$("$FU" escalate 2>&1)" "would create: [lane-a/$id]"
done
seed; jq '.followUps += [{id: "g3", worker: "w-a", lane: "lane-a", owner: "w-a", text: "read process.env.NODE_ENV and import.meta.env", state: "open", openedAt: (now - 90000 | todate)}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
has "guard allows process.env and import.meta.env" "$("$FU" escalate 2>&1)" "would create: [lane-a/g3]"
seed; jq '.followUps += [{id: "g4", worker: "w-a", lane: "lane-a", owner: "w-a", text: "copy .env.local over", state: "open", openedAt: (now - 90000 | todate)}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
has "guard refuses a .env.local file name" "$("$FU" escalate 2>&1)" "refused lane-a/g4"

# 9. the shared credential check (lib.sh cm_text_looks_secret): shapes the first version missed; fakes built at run time
rep() { printf '%*s' "$1" '' | tr ' ' "$2"; }
fake() { # one fake secret-looking text per shape, built here so no literal token shape sits in this file
  case "$1" in
    dburl)    printf '%s' "restore from po""stgres://admin:$(rep 3 Q)hunter$(rep 4 7)@db.internal/app" ;;
    gitlab)   printf '%s' "use gl""pat-$(rep 20 a)1 for the mirror" ;;
    npm)      printf '%s' "//registry.example.org/:_auth""Token=np""m_$(rep 24 b)" ;;
    asia)     printf '%s' "session key AS""IA$(rep 16 C)" ;;
    sentence) printf '%s' "the pass""word is $(rep 6 k)$(rep 4 3)" ;;
    slack)    printf '%s' "use xa""pp-1-$(rep 12 D)" ;;
    runner)   printf '%s' "gh""r_$(rep 20 e)" ;;
    # round 2: shapes scan-secrets.sh counts that the first gate missed
    longtitle) printf '%s' "routine $(rep 120 x) then DB_PASS""WORD=supersecretvalue" ;;
    pguser)   printf '%s' "connect post""gres://u:pw@host/db" ;;
    redis)    printf '%s' "cache re""dis://:hunter22@cache" ;;
    acctok)   printf '%s' "ACCESS_TO""KEN=$(rep 20 a)" ;;
    apikey)   printf '%s' "api_""key: '$(rep 16 b)'" ;;
    pwd)      printf '%s' "p""wd=$(rep 12 c)" ;;
    csecret)  printf '%s' "client_""secret=$(rep 15 d)" ;;
    keynl)    printf 'key\nsk-a''nt-%s' "$(rep 20 e)" ;;
    pctsk)    printf '%s' "x%3Dsk-""or-$(rep 20 f)" ;;
    # round 2: an invisible or combining character inside the key
    shy)      printf 'g\302\255hp_%s' "$(rep 24 g)" ;;
    fe0f)     printf 'glp\357\270\217at-%s' "$(rep 20 h)" ;;
    cgj)      printf 'AS\315\217IA%s' "$(rep 16 C)" ;;
  esac
    # round 3: the Stripe-style prefixes behind a JSON or URL escape, which ends in a letter (a letter alone means a longer word)
    skn)      printf '%s' "note:\\n""sk_li""ve_$(rep 24 m)" ;;
    skt)      printf '%s' "tab\\t""sk_te""st_$(rep 24 n)" ;;
    skd)      printf '%s' "key%3D""rk_li""ve_$(rep 24 p)" ;;
    ska)      printf '%s' "k%3A""rk_te""st_$(rep 24 q)" ;;
    skdig)    printf '%s' "id9""sk_li""ve_$(rep 24 r)" ;;
}
for k in dburl gitlab npm asia sentence slack runner longtitle pguser redis acctok apikey pwd csecret keynl pctsk shy fe0f cgj skn skt skd ska skdig; do
  txt="$(fake "$k")"
  seed; jq --arg id "fake-$k" --arg t "$txt" '.followUps += [{id: $id, worker: "w-a", lane: "lane-a", owner: "w-a", text: $t, state: "open", openedAt: (now - 90000 | todate)}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
  out="$("$FU" escalate 2>&1)"
  has "shared check refuses the $k shape" "$out" "refused lane-a/fake-$k"
  lacks "shared check: the $k text never reaches a would-create line" "$out" "$txt"
done
for t in "the password is stale, rotate it" "see https://example.com/a/b and http://host:8080/x" "asia pacific rollout, issue #12"; do
  seed; jq --arg t "$t" '.followUps += [{id: "plain-text", worker: "w-a", lane: "lane-a", owner: "w-a", text: $t, state: "open", openedAt: (now - 90000 | todate)}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
  has "shared check allows: $t" "$("$FU" escalate 2>&1)" "would create: [lane-a/plain-text]"
done

# a refused text makes the run exit 1 (SKILL.md says so), also with two of them
seed; jq --arg t "$(fake pguser)" --arg u "$(fake acctok)" '.followUps += [{id: "r1", worker: "w-a", lane: "lane-a", owner: "w-a", text: $t, state: "open", openedAt: (now - 90000 | todate)}, {id: "r2", worker: "w-a", lane: "lane-a", owner: "w-a", text: $u, state: "open", openedAt: (now - 90000 | todate)}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
out="$("$FU" escalate 2>&1)"; rc=$?
[ "$rc" = 1 ] && has "two refused texts: both named" "$out" "refused lane-a/r2" && ok "two refused texts: exit 1" || bad "refusal exit" "rc=$rc"
# the approve line is shell-quoted: an id from a hand-edited ledger cannot print as a runnable command
seed; jq '.followUps += [{id: "q$(echo hi)", worker: "w-a", lane: "lane-a", owner: "w-a", text: "validate the nightly run", state: "open", openedAt: (now - 90000 | todate)}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
out="$("$FU" escalate 2>&1)"
line="$(printf '%s\n' "$out" | grep 'to create exactly')"
# shellcheck disable=SC2016  # the literal text of a command substitution
case "$line" in *'q$(echo'*) bad "approve line quotes the id" "$line" ;; *'q\$\(echo'*) ok "approve line quotes the id" ;; *) bad "approve line shape" "$line" ;; esac

# 10. --create works from the approved list
seed; cp "$L" "$ROOT/before.json"
out="$("$FU" escalate --create 2>&1)"; rc=$?
[ "$rc" = 2 ] && ok "--create with no list: exit 2" || bad "create no list rc" "$rc"
has "--create with no list: names --only and --all-candidates" "$out" "--only"
[ "$(creates)" = 0 ] && ok "--create with no list: nothing created" || bad "create no list" "$(creates)"
out="$("$FU" escalate 2>&1)"
has "dry run prints the exact --only line" "$out" "escalate --create --only "
has "dry run --only line lists an approvable id" "$out" "lane-a/old-same"
lacks "dry run --only line leaves out a refused id" "$(printf '%s\n' "$out" | grep 'to create exactly')" "lane-a/leaky"
seed
out="$("$FU" escalate --create --only "lane-a/old-same@$(fpof old-same)" 2>&1)"
has "--only: the approved id is created" "$out" "created: [lane-a/old-same]"
[ "$(creates)" = 1 ] && ok "--only: only the approved id is created" || bad "only count" "$(creates)"
[ "$(fu_issue cross-lane)" = none ] && ok "--only: another candidate stays unmarked" || bad "only other" "$(fu_issue cross-lane)"
seed
out="$("$FU" escalate --create --only "lane-a/nope@$(fpof nope),lane-a/young-same@$(fpof young-same)" 2>&1)"
has "--only: an id that is not a candidate is reported" "$out" "--only lane-a/nope is not a candidate"
has "--only: a young same-lane item is not a candidate" "$out" "--only lane-a/young-same is not a candidate"
[ "$(creates)" = 0 ] && ok "--only: nothing created for ids that are not candidates" || bad "only none" "$(creates)"
# an item that becomes a candidate after the dry run is not created
seed; out0="$("$FU" escalate 2>&1)"; ids="$(printf '%s\n' "$out0" | sed -n 's/.*escalate --create --only //p')"
jq '.followUps += [{id: "late-arrival", worker: "w-a", lane: "lane-a", owner: "w-b", text: "posted after the dry run", state: "open", openedAt: (now | todate)}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
"$FU" escalate --create --only "$ids" >/dev/null 2>&1
[ "$(fu_issue late-arrival)" = none ] && ok "an item that became a candidate after the dry run is not created" || bad "late arrival" "$(fu_issue late-arrival)"
# the dry run caps the bodies it prints
seed; out="$("$FU" escalate --show 1 2>&1)"
[ "$(printf '%s\n' "$out" | grep -c 'Follow-up `')" = 1 ] && ok "--show 1: one body printed" || bad "show cap" "$(printf '%s\n' "$out" | grep -c 'Follow-up `')"
has "--show 1: the rest are one-line titles" "$out" "body not shown"

# an --only entry without the fingerprint is refused; a follow-up changed since the dry run is not created
seed; out="$("$FU" escalate --create --only lane-a/old-same 2>&1)"; rc=$?
[ "$rc" = 2 ] && ok "--only without a fingerprint: exit 2" || bad "bare only rc" "$rc"
[ "$(creates)" = 0 ] && ok "--only without a fingerprint: nothing created" || bad "bare only" "$(creates)"
seed; ids="$("$FU" escalate 2>&1 | sed -n 's/.*escalate --create --only //p')"
jq '(.followUps[] | select(.id == "old-same") | .text) = "reworded after the owner read the dry run"' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
out="$("$FU" escalate --create --only "$ids" 2>&1)"
has "changed after the dry run: refused with a reason" "$out" "lane-a/old-same changed since the dry run"
[ "$(fu_issue old-same)" = none ] && ok "changed after the dry run: not created" || bad "changed text created" "$(fu_issue old-same)"
[ "$(creates)" = 2 ] && ok "changed after the dry run: the unchanged approved ones are created" || bad "unchanged created" "$(creates)"
# a key split by an invisible character is checked as it will go out
ZW="$(printf '\342\200\213')"
seed; jq --arg t "ke""y s""k-${ZW}$(rep 24 q) end" '.followUps += [{id: "zw-key", worker: "w-a", lane: "lane-a", owner: "w-a", text: $t, state: "open", openedAt: (now - 90000 | todate)}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
has "a key split by a zero-width character is refused" "$("$FU" escalate 2>&1)" "refused lane-a/zw-key"
# a search that fills its page proves nothing
seed; jq -n '[range(0; 100) | {number: (. + 1000), title: "follow-up other-\(.): x", url: "u", body: "b"}]' > "$STUB/list.out"
out="$("$FU" escalate --create --only "lane-a/old-same@$(fpof old-same)" 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ "$(creates)" = 0 ] && ok "a full search page: nothing created, non-zero exit" || bad "full page" "rc=$rc creates=$(creates)"
has "a full search page: says so" "$out" "100-result limit"
[ "$(jq -r '[.followUps[] | select(.id == "old-same")][0].escalatingAt // "none"' "$L")" != none ] && ok "a full search page: the claim stays for --resolve" || bad "full page claim" ""
"$FU" escalate --resolve lane-a/old-same 555 >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(fu_issue old-same)" = 555 ] && ok "a full search page: --resolve records the number found by hand" || bad "full page resolve" "rc=$rc $(fu_issue old-same)"
# 11. title and body hygiene, openedAt offsets
BIDI="$(printf '\342\200\256')"
seed; jq --arg t "ping @team and @someone about #12 ${BIDI}gnp.exe" '.followUps += [{id: "mention-text", worker: "w-a", lane: "lane-a", owner: "w-a", text: $t, state: "open", openedAt: (now - 90000 | todate)}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
"$FU" escalate --create --only "lane-a/mention-text@$(fpof mention-text)" >/dev/null 2>&1
args="$(cat "$STUB/args.log")"
case "$args" in *"follow-up mention-text: ping (at)team and (at)someone about (no.)12 gnp.exe"*) ok "title: @ and # neutralised, bidi control removed" ;; *) bad "title hygiene" "$args" ;; esac
case "$args" in *"$BIDI"*) bad "bidi control left in an argument" "" ;; *) ok "no bidi control reaches gh" ;; esac
body="$(cat "$STUB"/body.* 2>/dev/null)"
has "body: owner is inside the indented block" "$body" "    owner: w-a"
has "body: source worktree is inside the indented block" "$body" "    source worktree: wt-a"
lacks "body: no list item outside the code block" "$body" "- owner:"
has "body: the close hint says the ledger item is closed, not the issue" "$body" "does not close the ledger item"
has "body: the close hint carries --lane" "$body" "close mention-text --lane lane-a"
seed; jq '.followUps += [{id: "offset-time", worker: "w-a", lane: "lane-a", owner: "w-a", text: "opened in a +01:00 zone", state: "open", openedAt: (((now - 30*3600 + 3600) | todate | sub("Z$"; "")) + "+01:00")}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
has "openedAt with a +01:00 offset ages out" "$("$FU" escalate 2>&1)" "would create: [lane-a/offset-time]"
seed; jq '.followUps += [{id: "offset-young", worker: "w-a", lane: "lane-a", owner: "w-a", text: "young in a -0500 zone", state: "open", openedAt: (((now - 2*3600 - 18000) | todate | sub("Z$"; "")) + "-0500")}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
lacks "openedAt 2 h ago in a -0500 zone is not old" "$("$FU" escalate 2>&1)" "[lane-a/offset-young]"

# 12. an issue that already exists is linked, not made again; one --create run at a time
seed
# shellcheck disable=SC2016  # backticks are markdown in the stubbed issue body
echo '[{"number": 55, "title": "follow-up old-same: validate the codes after load", "url": "https://github.com/AcmeOrg/acme-app/issues/55", "body": "Follow-up `old-same` raised by lane `lane-a`."}]' > "$STUB/list.out"
out="$("$FU" escalate --create --only "lane-a/old-same@$(fpof old-same)" 2>&1)"; rc=$?
has "existing issue: linked, none created" "$out" "linked: [lane-a/old-same] https://github.com/AcmeOrg/acme-app/issues/55"
[ "$(creates)" = 0 ] && [ "$(fu_issue old-same)" = 55 ] && ok "existing issue: number recorded, no create call" || bad "existing issue" "creates=$(creates) issue=$(fu_issue old-same)"
seed
# shellcheck disable=SC2016  # backticks are markdown in the stubbed issue body
echo '[{"number": 56, "title": "follow-up old-same: validate the codes after load", "url": "u", "body": "Follow-up `old-same` raised by lane `lane-b`."}]' > "$STUB/list.out"
"$FU" escalate --create --only "lane-a/old-same@$(fpof old-same)" >/dev/null 2>&1
[ "$(creates)" = 1 ] && ok "same id in another lane is not a match: created" || bad "other lane id" "$(creates)"
seed; echo 1 > "$STUB/list.rc"
out="$("$FU" escalate --create --only "lane-a/old-same@$(fpof old-same)" 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ "$(creates)" = 0 ] && ok "search fails: nothing created, non-zero exit" || bad "search fail" "rc=$rc creates=$(creates)"
[ "$(jq -r '[.followUps[] | select(.escalatingAt != null)] | length' "$L")" = 0 ] && ok "search fails: the claim is released" || bad "search claim" ""
seed; sleep 60 & LIVE=$!
mkdir "$CM_HOME/.followups-escalate.lock"; echo "$LIVE" > "$CM_HOME/.followups-escalate.lock/pid"
out="$("$FU" escalate --create --only "lane-a/old-same@$(fpof old-same)" 2>&1)"; rc=$?
has "another --create run holds the lock: skipped" "$out" "another --create run is in progress"
[ "$(creates)" = 0 ] && ok "locked: nothing created" || bad "locked create" "$(creates)"
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null
seed; rm -rf -- "${CM_HOME:?}/.followups-escalate.lock"; mkdir "$CM_HOME/.followups-escalate.lock"
out="$("$FU" escalate --create --only "lane-a/old-same@$(fpof old-same)" 2>&1)"
has "a fresh lock with no pid yet is a run starting: skipped" "$out" "another --create run is starting"
[ "$(creates)" = 0 ] && ok "no pid yet: nothing created" || bad "no pid create" "$(creates)"
rm -rf -- "${CM_HOME:?}/.followups-escalate.lock"
seed
out="$("$FU" escalate --create --only "lane-a/old-same@$(fpof old-same)" 2>&1)"
has "the lock of a dead run is taken over" "$out" "created: [lane-a/old-same]"
[ ! -d "$CM_HOME/.followups-escalate.lock" ] && ok "the lock is removed when the run ends" || bad "lock left" ""

# 13. text is not re-wrapped, so a multibyte character is never cut
seed; jq --arg t "$(rep 99 a)é end" '.followUps += [{id: "wide-char", worker: "w-a", lane: "lane-a", owner: "w-a", text: $t, state: "open", openedAt: (now - 90000 | todate)}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
"$FU" escalate --create --only "lane-a/wide-char@$(fpof wide-char)" >/dev/null 2>&1
if iconv -f UTF-8 -t UTF-8 "$STUB"/body.* >/dev/null 2>&1 && grep -q "é end" "$STUB"/body.*; then ok "body keeps a multibyte character whole"; else bad "multibyte body" "$(cat "$STUB"/body.* 2>/dev/null | head -3)"; fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
# 14. escalate minors: --resolve, exit 126/127, the sk_test_ boundary, the stale-lock takeover, a relink after a text change
LOCK="$CM_HOME/.followups-escalate.lock"
claim() { jq --arg id "$1" --arg tok "$2" '(.followUps[] | select(.id == $id) | .escalatingAt) = $tok' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"; }
claimed() { jq -r --arg id "$1" '[.followUps[] | select(.id == $id)][0].escalatingAt // "none"' "$L"; }
# --resolve release while the run that made the claim is still alive: refused, the claim stays
seed; sleep 60 & LIVE=$!
claim old-same "$(date -u +%FT%TZ)-$LIVE"
out="$("$FU" escalate --resolve lane-a/old-same release 2>&1)"; rc=$?
[ "$rc" = 1 ] && [ "$(claimed old-same)" != none ] && has "release on a live claim: refused, claim kept" "$out" "still alive (pid $LIVE)" || bad "release live" "rc=$rc claim=$(claimed old-same) $out"
"$FU" escalate --resolve lane-a/old-same 612 >/dev/null 2>&1
[ "$(fu_issue old-same)" = 612 ] && ok "a number can still be recorded on a live claim" || bad "number on live claim" "$(fu_issue old-same)"
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null
seed; claim old-same "2026-11-02T00:00:00Z-$LIVE"
"$FU" escalate --resolve lane-a/old-same release >/dev/null 2>&1
[ "$(claimed old-same)" = none ] && ok "release once that run has ended: claim cleared" || bad "release dead" "$(claimed old-same)"
# a live pid on a claim over an hour old is a reused pid: release goes ahead
seed; sleep 60 & LIVE=$!
claim old-same "2026-11-02T00:00:00Z-$LIVE"
"$FU" escalate --resolve lane-a/old-same release >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(claimed old-same)" = none ] && ok "release on an old claim whose pid is alive (reused): goes ahead" || bad "release reused pid" "rc=$rc claim=$(claimed old-same)"
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null
# a "/" in the lane or the id cannot move the split: the claim is found by its whole lane/id name
seed; jq '.followUps += [{id: "pr/12", worker: "w-a", lane: "lane-a", owner: "w-a", text: "slash in the id", state: "open", openedAt: (now - 90000 | todate), escalatingAt: "t-1"},
  {id: "x", worker: "w-a", lane: "team/ops", owner: "w-a", text: "slash in the lane", state: "open", openedAt: (now - 90000 | todate), escalatingAt: "t-1"}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
"$FU" escalate --resolve lane-a/pr/12 91 >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(fu_issue pr/12)" = 91 ] && ok "--resolve: a slash in the id" || bad "resolve id slash" "rc=$rc $(fu_issue pr/12)"
"$FU" escalate --resolve team/ops/x 92 >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(fu_issue x)" = 92 ] && ok "--resolve: a slash in the lane" || bad "resolve lane slash" "rc=$rc $(fu_issue x)"
seed; jq '.followUps += [{id: "b/c", worker: "w-a", lane: "a", owner: "w-a", text: "one", state: "open", openedAt: (now - 90000 | todate), escalatingAt: "t-1"},
  {id: "c", worker: "w-a", lane: "a/b", owner: "w-a", text: "two", state: "open", openedAt: (now - 90000 | todate), escalatingAt: "t-1"}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
"$FU" escalate --resolve a/b/c 93 >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$(fu_issue c)" = none ] && [ "$(fu_issue b/c)" = none ] && ok "--resolve: a name two claims share resolves neither" || bad "resolve ambiguous" "rc=$rc"
# --resolve <n> needs the repository config for the url; release does not; and the order of the checks is right
printf 'followups:\n  issue_labels: []\n' > "$ROOT/noorg.yaml"
sleep 0.2 & DEAD=$!; wait "$DEAD" 2>/dev/null   # a pid that surely no longer exists (pid 1 is alive, and kill -0 1 succeeds as root)
seed; claim old-same "t-$DEAD"
out="$(CM_CONFIG="$ROOT/noorg.yaml" "$FU" escalate --resolve lane-a/old-same 5 2>&1)"; rc=$?
[ "$rc" = 1 ] && [ "$(claimed old-same)" = "t-$DEAD" ] && has "--resolve <n> without github.org: refused, no url built, claim kept" "$out" "not configured" || bad "resolve no org" "rc=$rc $out"
CM_CONFIG="$ROOT/noorg.yaml" "$FU" escalate --resolve lane-a/old-same release >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(claimed old-same)" = none ] && ok "--resolve release works without github.org" || bad "release no org" "rc=$rc"
# gh exit 126 and 127: it never ran, so nothing was made and the claim goes back
for code in 126 127; do
  seed; echo "$code" > "$STUB/create.rc"; echo "gh: command not found" > "$STUB/create.err"
  out="$("$FU" escalate --create --only "lane-a/old-same@$(fpof old-same)" 2>&1)"; rc=$?
  [ "$rc" = 1 ] && [ "$(claimed old-same)" = none ] && has "gh exit $code: claim released, run fails" "$out" "gh could not be run" || bad "gh $code" "rc=$rc claim=$(claimed old-same) $out"
done
# the Stripe-style prefixes: a letter before sk_test_ means the tail of a longer word, anything else does not
seed
jq --arg a "the task_te""st_$(rep 20 x) fixtures" --arg b "stripe key sk_te""st_$(rep 20 y)" --arg c "STRIPE=rk_li""ve_$(rep 20 z)" '.followUps += [
  {id: "snake", worker: "w-a", lane: "lane-a", owner: "w-a", text: $a, state: "open", openedAt: (now - 90000 | todate)},
  {id: "real-sk", worker: "w-a", lane: "lane-a", owner: "w-a", text: $b, state: "open", openedAt: (now - 90000 | todate)},
  {id: "real-rk", worker: "w-a", lane: "lane-a", owner: "w-a", text: $c, state: "open", openedAt: (now - 90000 | todate)}]' "$L" > "$ROOT/l.json" && mv "$ROOT/l.json" "$L"
out="$("$FU" escalate 2>&1)"
has "snake_case text that ends in sk_test_ shape: not refused" "$out" "would create: [lane-a/snake]"
has "a real sk_test_ key after a space: refused" "$out" "escalate refused lane-a/real-sk"
has "a real rk_live_ key after =: refused" "$out" "escalate refused lane-a/real-rk"
# the stale-lock takeover happens under its own lock and looks again inside it
only="lane-a/old-same@$(fpof old-same)"
seed; mkdir "$LOCK"; echo 999999 > "$LOCK/pid"; mkdir "$LOCK.takeover"
out="$("$FU" escalate --create --only "$only" 2>&1)"
has "another run is taking over the stale lock: skipped" "$out" "taking over the stale lock"
[ "$(creates)" = 0 ] && [ -d "$LOCK" ] && ok "takeover held by another run: nothing created, the lock stays" || bad "takeover held" "creates=$(creates)"
rm -rf -- "$LOCK" "$LOCK.takeover"
seed; mkdir "$LOCK"; echo 999999 > "$LOCK/pid"; mkdir "$LOCK.takeover"; touch -t 202001010000 "$LOCK.takeover"
out="$("$FU" escalate --create --only "$only" 2>&1)"
has "a takeover lock left by a dead run clears after a minute" "$out" "created: [lane-a/old-same]"
[ ! -d "$LOCK" ] && [ ! -d "$LOCK.takeover" ] && ok "takeover: neither lock is left behind" || bad "takeover left" "$(ls -d "$LOCK"* 2>&1)"
# the window itself: the holder looked dead when this run first read the pid, and a fresh run took the lock before the second read.
# A cat shim makes that happen on the first read of the lock's pid file.
seed; mkdir "$LOCK"; echo 999999 > "$LOCK/pid"; sleep 60 & LIVE=$!
cat > "$ROOT/bin/cat" <<S
#!/bin/sh
if [ "\$1" = "$LOCK/pid" ] && [ ! -e "$STUB/cat.done" ]; then
  : > "$STUB/cat.done"; /bin/cat "\$1"; rm -rf "$LOCK"; mkdir "$LOCK"; echo $LIVE > "$LOCK/pid"; exit 0
fi
exec /bin/cat "\$@"
S
chmod +x "$ROOT/bin/cat"
out="$("$FU" escalate --create --only "$only" 2>&1)"
rm -f "$ROOT/bin/cat"
has "a fresh run took the lock between the two reads: this run stands down" "$out" "another --create run is in progress (pid $LIVE)"
[ "$(creates)" = 0 ] && [ "$(/bin/cat "$LOCK/pid" 2>/dev/null)" = "$LIVE" ] && ok "and the fresh run's lock is still its own" || bad "fresh lock" "creates=$(creates) pid=$(/bin/cat "$LOCK/pid" 2>&1)"
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null; rm -rf -- "$LOCK" "$LOCK.takeover"
# a live pid on a lock older than an hour is a reused pid, not a run
seed; sleep 60 & LIVE=$!; mkdir "$LOCK"; echo "$LIVE" > "$LOCK/pid"; touch -t 202001010000 "$LOCK"
out="$("$FU" escalate --create --only "$only" 2>&1)"
has "a live pid on a lock over an hour old: taken over" "$out" "created: [lane-a/old-same]"
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null; rm -rf -- "$LOCK" "$LOCK.takeover"
# an older issue for the same lane and id is linked after the text was reworded: the match is the id and the lane, not the words
# shellcheck disable=SC2016  # backticks are markdown in the stubbed issue body
seed; echo '[{"number": 58, "title": "follow-up old-same: the first wording of this text", "url": "https://github.com/AcmeOrg/acme-app/issues/58", "body": "Follow-up `old-same` raised by lane `lane-a`."}]' > "$STUB/list.out"
out="$("$FU" escalate --create --only "$only" 2>&1)"
has "an old issue with other wording is linked by lane and id" "$out" "linked: [lane-a/old-same] https://github.com/AcmeOrg/acme-app/issues/58"
[ "$(creates)" = 0 ] && [ "$(fu_issue old-same)" = 58 ] && ok "and no second issue is made" || bad "relink" "creates=$(creates) issue=$(fu_issue old-same)"

[ "$FAIL" = 0 ]
